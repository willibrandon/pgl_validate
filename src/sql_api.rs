//! SQL-callable pgrx bindings exposed by `pgl_validate`.

use crate::digest;
use crate::transport;
use pgrx::prelude::*;

/// Compute the canonical BLAKE3 row digest for a heterogeneous tuple.
///
/// The first argument is the coordinator-selected encoding mode array; the
/// remaining VARIADIC arguments are the row values in sorted column-name order.
#[pg_extern(
    stable,
    parallel_safe,
    sql = r#"
CREATE FUNCTION pgl_validate.row_digest(enc int[], VARIADIC "any")
RETURNS bytea
LANGUAGE c
STABLE
PARALLEL SAFE
AS 'MODULE_PATHNAME', 'row_digest_wrapper';
"#
)]
fn row_digest(fcinfo: pg_sys::FunctionCallInfo) -> Vec<u8> {
    unsafe { digest::row_digest::row_digest_fcinfo(fcinfo) }
}

/// Return this backend's `XactLastCommitEnd` as a `pg_lsn`.
///
/// The coordinator calls this immediately after committing a barrier insert in
/// the same session, making the returned LSN the exact barrier commit end.
#[pg_extern(
    volatile,
    sql = r#"
CREATE FUNCTION pgl_validate.last_commit_lsn()
RETURNS pg_lsn
LANGUAGE c
VOLATILE
AS 'MODULE_PATHNAME', 'last_commit_lsn_wrapper';
"#
)]
fn last_commit_lsn() -> i64 {
    unsafe { pg_sys::XactLastCommitEnd as i64 }
}

#[pg_schema]
mod pgl_validate {
    use super::digest;
    use super::transport;
    use pgrx::StringInfo;
    use pgrx::aggregate::*;
    use pgrx::prelude::*;
    use serde::{Deserialize, Serialize};
    use std::ffi::CString;

    const LANE_BLOCKS: usize = 32;
    const LANES_PER_BLOCK: usize = 32;

    /// PostgreSQL varlena representation of the 1024-lane LtHash accumulator.
    #[derive(Copy, Clone, PostgresType, Serialize, Deserialize, AggregateName)]
    #[aggregate_name = "lthash"]
    #[pgvarlena_inoutfuncs]
    #[derive(Default)]
    #[allow(non_camel_case_types)]
    pub struct lthash_state {
        lane_blocks: [[u16; LANES_PER_BLOCK]; LANE_BLOCKS],
    }

    impl lthash_state {
        fn from_core(core: digest::lthash::LtHashCore) -> Self {
            let mut lane_blocks = [[0u16; LANES_PER_BLOCK]; LANE_BLOCKS];
            for (dst, src) in lane_blocks.iter_mut().flatten().zip(core.lanes.into_iter()) {
                *dst = src;
            }
            Self { lane_blocks }
        }

        fn to_core(self) -> digest::lthash::LtHashCore {
            let mut lanes = [0u16; digest::lthash::LANES];
            for (dst, src) in lanes.iter_mut().zip(self.lane_blocks.into_iter().flatten()) {
                *dst = src;
            }
            digest::lthash::LtHashCore { lanes }
        }
    }

    impl PgVarlenaInOutFuncs for lthash_state {
        fn input(input: &core::ffi::CStr) -> PgVarlena<Self> {
            let text = input.to_str().expect("lthash_state input must be UTF-8");
            let core = digest::lthash::LtHashCore::parse_text(text)
                .expect("invalid lthash_state text representation");
            let mut out = PgVarlena::<Self>::new();
            out.lane_blocks = Self::from_core(core).lane_blocks;
            out
        }

        fn output(&self, buffer: &mut StringInfo) {
            buffer.push_str(&self.to_core().to_hex());
        }
    }

    /// Hash an already sorted array of per-row digests into a cryptographic
    /// confirmation digest.
    #[pg_extern(immutable, parallel_safe)]
    fn hash_digest_array(digests: Array<&[u8]>) -> Vec<u8> {
        let refs = digests
            .iter()
            .filter_map(|digest| digest)
            .collect::<Vec<&[u8]>>();
        digest::lthash::hash_digest_array(&refs).to_vec()
    }

    /// Return true when a serialized PostgreSQL expression tree contains only
    /// immutable functions.
    #[pg_extern(stable, parallel_safe)]
    fn row_filter_tree_is_immutable(filter_tree: &str) -> bool {
        let c_filter_tree = CString::new(filter_tree)
            .unwrap_or_else(|_| pgrx::error!("row filter expression tree contains embedded NUL"));
        let node = unsafe { pg_sys::stringToNode(c_filter_tree.as_ptr()) };
        if node.is_null() {
            pgrx::error!("could not parse row filter expression tree");
        }

        !unsafe { pg_sys::contain_mutable_functions(node.cast::<pg_sys::Node>()) }
    }

    /// Combine two LtHash states for parallel aggregate execution and tests.
    #[pg_extern(immutable, parallel_safe)]
    fn lthash_combine(
        left: PgVarlena<lthash_state>,
        right: PgVarlena<lthash_state>,
    ) -> PgVarlena<lthash_state> {
        let combined = digest::lthash::combine(left.to_core(), right.to_core());
        let mut out = PgVarlena::<lthash_state>::new();
        out.lane_blocks = lthash_state::from_core(combined).lane_blocks;
        out
    }

    /// Return the canonical byte representation used to persist an LtHash
    /// aggregate result in `pgl_validate.table_node_result`.
    #[pg_extern(immutable, parallel_safe)]
    fn lthash_bytes(state: PgVarlena<lthash_state>) -> Vec<u8> {
        state.to_core().to_bytes()
    }

    /// Execute generated checksum SQL on a remote peer over libpq.
    #[pg_extern(volatile, parallel_unsafe)]
    fn remote_checksum(
        dsn: &str,
        checksum_sql: &str,
        connect_timeout_seconds: default!(i32, 10),
        statement_timeout_ms: default!(i32, 600000),
        lock_timeout_ms: default!(i32, 30000),
    ) -> TableIterator<
        'static,
        (
            name!(pg_version, i32),
            name!(n_rows, i64),
            name!(lthash, Vec<u8>),
            name!(set_hash, Option<Vec<u8>>),
        ),
    > {
        let checksum = transport::libpq::fetch_checksum(
            dsn,
            checksum_sql,
            connect_timeout_seconds,
            statement_timeout_ms,
            lock_timeout_ms,
        )
        .unwrap_or_else(|err| pgrx::error!("{err}"));

        TableIterator::once((
            checksum.pg_version,
            checksum.n_rows,
            checksum.lthash,
            checksum.set_hash,
        ))
    }

    /// Execute generated schema-signature SQL on a remote peer over libpq.
    #[pg_extern(volatile, parallel_unsafe)]
    fn remote_schema_signature(
        dsn: &str,
        signature_sql: &str,
        connect_timeout_seconds: default!(i32, 10),
        statement_timeout_ms: default!(i32, 600000),
        lock_timeout_ms: default!(i32, 30000),
    ) -> TableIterator<'static, (name!(pg_version, i32), name!(signature, String))> {
        let signature = transport::libpq::fetch_schema_signature(
            dsn,
            signature_sql,
            connect_timeout_seconds,
            statement_timeout_ms,
            lock_timeout_ms,
        )
        .unwrap_or_else(|err| pgrx::error!("{err}"));

        TableIterator::once((signature.pg_version, signature.signature))
    }

    /// Execute generated row-localization SQL on a remote peer over libpq.
    #[pg_extern(volatile, parallel_unsafe)]
    fn remote_localize_rows(
        dsn: &str,
        localization_sql: &str,
        connect_timeout_seconds: default!(i32, 10),
        statement_timeout_ms: default!(i32, 600000),
        lock_timeout_ms: default!(i32, 30000),
    ) -> TableIterator<
        'static,
        (
            name!(key_text, String),
            name!(key_bytes, Vec<u8>),
            name!(row_digest, Vec<u8>),
            name!(row_json, String),
        ),
    > {
        let rows = transport::libpq::fetch_localized_rows(
            dsn,
            localization_sql,
            connect_timeout_seconds,
            statement_timeout_ms,
            lock_timeout_ms,
        )
        .unwrap_or_else(|err| pgrx::error!("{err}"));

        TableIterator::new(
            rows.into_iter()
                .map(|row| (row.key_text, row.key_bytes, row.row_digest, row.row_json)),
        )
    }

    /// Execute generated sequence SQL on a remote peer over libpq.
    #[pg_extern(volatile, parallel_unsafe)]
    fn remote_sequence_value(
        dsn: &str,
        sequence_sql: &str,
        connect_timeout_seconds: default!(i32, 10),
        statement_timeout_ms: default!(i32, 600000),
        lock_timeout_ms: default!(i32, 30000),
    ) -> TableIterator<'static, (name!(pg_version, i32), name!(last_value, i64))> {
        let value = transport::libpq::fetch_sequence_value(
            dsn,
            sequence_sql,
            connect_timeout_seconds,
            statement_timeout_ms,
            lock_timeout_ms,
        )
        .unwrap_or_else(|err| pgrx::error!("{err}"));

        TableIterator::once((value.pg_version, value.last_value))
    }

    /// Execute one generated SQL command batch on a remote peer over libpq.
    #[pg_extern(volatile, parallel_unsafe)]
    fn remote_execute(
        dsn: &str,
        sql: &str,
        connect_timeout_seconds: default!(i32, 10),
        statement_timeout_ms: default!(i32, 600000),
        lock_timeout_ms: default!(i32, 30000),
    ) {
        transport::libpq::execute_command_with_timeouts(
            dsn,
            sql,
            connect_timeout_seconds,
            statement_timeout_ms,
            lock_timeout_ms,
        )
        .unwrap_or_else(|err| pgrx::error!("{err}"));
    }

    /// Insert a barrier token on a remote origin and return its exact end LSN.
    #[pg_extern(
        volatile,
        parallel_unsafe,
        sql = r#"
CREATE FUNCTION pgl_validate.remote_inject_barrier(
    dsn text,
    connect_timeout_seconds integer DEFAULT 10,
    statement_timeout_ms integer DEFAULT 600000,
    lock_timeout_ms integer DEFAULT 30000
)
RETURNS TABLE (token uuid, barrier_end_lsn pg_lsn)
LANGUAGE c
STRICT
VOLATILE
PARALLEL UNSAFE
AS 'MODULE_PATHNAME', 'remote_inject_barrier_wrapper';
"#
    )]
    fn remote_inject_barrier(
        dsn: &str,
        connect_timeout_seconds: default!(i32, 10),
        statement_timeout_ms: default!(i32, 600000),
        lock_timeout_ms: default!(i32, 30000),
    ) -> TableIterator<'static, (name!(token, pgrx::Uuid), name!(barrier_end_lsn, i64))> {
        let injection = transport::libpq::inject_barrier(
            dsn,
            connect_timeout_seconds,
            statement_timeout_ms,
            lock_timeout_ms,
        )
        .unwrap_or_else(|err| pgrx::error!("{err}"));

        TableIterator::once((
            pgrx::Uuid::from_bytes(injection.token),
            injection.barrier_end_lsn as i64,
        ))
    }

    /// Wait for a pglogical provider slot to confirm flushing a barrier LSN.
    #[pg_extern(
        volatile,
        parallel_unsafe,
        sql = r#"
CREATE FUNCTION pgl_validate.remote_wait_slot_confirm_lsn(
    dsn text,
    slot_name text,
    barrier_end_lsn pg_lsn,
    connect_timeout_seconds integer DEFAULT 10,
    statement_timeout_ms integer DEFAULT 600000,
    lock_timeout_ms integer DEFAULT 30000
)
RETURNS pg_lsn
LANGUAGE c
STRICT
VOLATILE
PARALLEL UNSAFE
AS 'MODULE_PATHNAME', 'remote_wait_slot_confirm_lsn_wrapper';
"#
    )]
    fn remote_wait_slot_confirm_lsn(
        dsn: &str,
        slot_name: &str,
        barrier_end_lsn: i64,
        connect_timeout_seconds: default!(i32, 10),
        statement_timeout_ms: default!(i32, 600000),
        lock_timeout_ms: default!(i32, 30000),
    ) -> i64 {
        let barrier_end_lsn =
            u64::try_from(barrier_end_lsn).unwrap_or_else(|_| pgrx::error!("pg_lsn is negative"));
        let confirmation = transport::libpq::wait_slot_confirm_lsn(
            dsn,
            slot_name,
            barrier_end_lsn,
            connect_timeout_seconds,
            statement_timeout_ms,
            lock_timeout_ms,
        )
        .unwrap_or_else(|err| pgrx::error!("{err}"));

        confirmation.confirmed_flush_lsn as i64
    }

    /// Fetch a provider logical slot's current confirmed flush LSN.
    #[pg_extern(
        volatile,
        parallel_unsafe,
        sql = r#"
CREATE FUNCTION pgl_validate.remote_slot_confirmed_flush_lsn(
    dsn text,
    slot_name text,
    connect_timeout_seconds integer DEFAULT 10,
    statement_timeout_ms integer DEFAULT 600000,
    lock_timeout_ms integer DEFAULT 30000
)
RETURNS pg_lsn
LANGUAGE c
STRICT
VOLATILE
PARALLEL UNSAFE
AS 'MODULE_PATHNAME', 'remote_slot_confirmed_flush_lsn_wrapper';
"#
    )]
    fn remote_slot_confirmed_flush_lsn(
        dsn: &str,
        slot_name: &str,
        connect_timeout_seconds: default!(i32, 10),
        statement_timeout_ms: default!(i32, 600000),
        lock_timeout_ms: default!(i32, 30000),
    ) -> i64 {
        let lsn = transport::libpq::fetch_slot_confirmed_flush_lsn(
            dsn,
            slot_name,
            connect_timeout_seconds,
            statement_timeout_ms,
            lock_timeout_ms,
        )
        .unwrap_or_else(|err| pgrx::error!("{err}"));

        lsn as i64
    }

    /// Fetch a provider's current WAL LSN for an explicitly degraded fence.
    #[pg_extern(
        volatile,
        parallel_unsafe,
        sql = r#"
CREATE FUNCTION pgl_validate.remote_current_wal_lsn(
    dsn text,
    connect_timeout_seconds integer DEFAULT 10,
    statement_timeout_ms integer DEFAULT 600000,
    lock_timeout_ms integer DEFAULT 30000
)
RETURNS pg_lsn
LANGUAGE c
STRICT
VOLATILE
PARALLEL UNSAFE
AS 'MODULE_PATHNAME', 'remote_current_wal_lsn_wrapper';
"#
    )]
    fn remote_current_wal_lsn(
        dsn: &str,
        connect_timeout_seconds: default!(i32, 10),
        statement_timeout_ms: default!(i32, 600000),
        lock_timeout_ms: default!(i32, 30000),
    ) -> i64 {
        let lsn = transport::libpq::fetch_current_wal_lsn(
            dsn,
            connect_timeout_seconds,
            statement_timeout_ms,
            lock_timeout_ms,
        )
        .unwrap_or_else(|err| pgrx::error!("{err}"));

        lsn as i64
    }

    /// Observe target-side origin progress and token visibility for a barrier.
    #[pg_extern(
        volatile,
        parallel_unsafe,
        sql = r#"
CREATE FUNCTION pgl_validate.remote_observe_barrier(
    dsn text,
    origin_name text,
    token uuid,
    barrier_end_lsn pg_lsn,
    connect_timeout_seconds integer DEFAULT 10,
    statement_timeout_ms integer DEFAULT 600000,
    lock_timeout_ms integer DEFAULT 30000
)
RETURNS TABLE (
    origin_progress_lsn pg_lsn,
    token_visible boolean,
    converged boolean
)
LANGUAGE c
STRICT
VOLATILE
PARALLEL UNSAFE
AS 'MODULE_PATHNAME', 'remote_observe_barrier_wrapper';
"#
    )]
    fn remote_observe_barrier(
        dsn: &str,
        origin_name: &str,
        token: pgrx::Uuid,
        barrier_end_lsn: i64,
        connect_timeout_seconds: default!(i32, 10),
        statement_timeout_ms: default!(i32, 600000),
        lock_timeout_ms: default!(i32, 30000),
    ) -> TableIterator<
        'static,
        (
            name!(origin_progress_lsn, i64),
            name!(token_visible, bool),
            name!(converged, bool),
        ),
    > {
        let barrier_end_lsn =
            u64::try_from(barrier_end_lsn).unwrap_or_else(|_| pgrx::error!("pg_lsn is negative"));
        let observation = transport::libpq::observe_barrier(
            dsn,
            origin_name,
            *token.as_bytes(),
            barrier_end_lsn,
            connect_timeout_seconds,
            statement_timeout_ms,
            lock_timeout_ms,
        )
        .unwrap_or_else(|err| pgrx::error!("{err}"));

        TableIterator::once((
            observation.origin_progress_lsn as i64,
            observation.token_visible,
            observation.converged,
        ))
    }

    /// Fetch physical-standby replay status from a remote participant.
    #[pg_extern(
        volatile,
        parallel_unsafe,
        sql = r#"
CREATE FUNCTION pgl_validate.remote_standby_replay_status(
    dsn text,
    connect_timeout_seconds integer DEFAULT 10,
    statement_timeout_ms integer DEFAULT 600000,
    lock_timeout_ms integer DEFAULT 30000
)
RETURNS TABLE (
    pg_version integer,
    in_recovery boolean,
    replay_lsn pg_lsn,
    replay_paused boolean
)
LANGUAGE c
STRICT
VOLATILE
PARALLEL UNSAFE
AS 'MODULE_PATHNAME', 'remote_standby_replay_status_wrapper';
"#
    )]
    fn remote_standby_replay_status(
        dsn: &str,
        connect_timeout_seconds: default!(i32, 10),
        statement_timeout_ms: default!(i32, 600000),
        lock_timeout_ms: default!(i32, 30000),
    ) -> TableIterator<
        'static,
        (
            name!(pg_version, i32),
            name!(in_recovery, bool),
            name!(replay_lsn, i64),
            name!(replay_paused, bool),
        ),
    > {
        let status = transport::libpq::fetch_standby_replay_status(
            dsn,
            connect_timeout_seconds,
            statement_timeout_ms,
            lock_timeout_ms,
        )
        .unwrap_or_else(|err| pgrx::error!("{err}"));

        TableIterator::once((
            status.pg_version,
            status.in_recovery,
            status.replay_lsn as i64,
            status.replay_paused,
        ))
    }

    /// Fetch pglogical subscription status from a remote target node.
    #[pg_extern(
        volatile,
        parallel_unsafe,
        sql = r#"
CREATE FUNCTION pgl_validate.remote_pglogical_subscription_status(
    dsn text,
    subscription_name text,
    connect_timeout_seconds integer DEFAULT 10,
    statement_timeout_ms integer DEFAULT 600000,
    lock_timeout_ms integer DEFAULT 30000
)
RETURNS TABLE (
    status text,
    provider_node text,
    provider_dsn text,
    slot_name text,
    replication_sets_json text,
    forward_origins_json text
)
LANGUAGE c
STRICT
VOLATILE
PARALLEL UNSAFE
AS 'MODULE_PATHNAME', 'remote_pglogical_subscription_status_wrapper';
"#
    )]
    fn remote_pglogical_subscription_status(
        dsn: &str,
        subscription_name: &str,
        connect_timeout_seconds: default!(i32, 10),
        statement_timeout_ms: default!(i32, 600000),
        lock_timeout_ms: default!(i32, 30000),
    ) -> TableIterator<
        'static,
        (
            name!(status, String),
            name!(provider_node, String),
            name!(provider_dsn, String),
            name!(slot_name, String),
            name!(replication_sets_json, String),
            name!(forward_origins_json, String),
        ),
    > {
        let status = transport::libpq::fetch_subscription_status(
            dsn,
            subscription_name,
            connect_timeout_seconds,
            statement_timeout_ms,
            lock_timeout_ms,
        )
        .unwrap_or_else(|err| pgrx::error!("{err}"));

        TableIterator::once((
            status.status,
            status.provider_node,
            status.provider_dsn,
            status.slot_name,
            status.replication_sets_json,
            status.forward_origins_json,
        ))
    }

    /// Fetch native logical subscription status from a remote target node.
    #[pg_extern(
        volatile,
        parallel_unsafe,
        sql = r#"
CREATE FUNCTION pgl_validate.remote_native_subscription_status(
    dsn text,
    subscription_name text,
    connect_timeout_seconds integer DEFAULT 10,
    statement_timeout_ms integer DEFAULT 600000,
    lock_timeout_ms integer DEFAULT 30000
)
RETURNS TABLE (
    enabled boolean,
    subid bigint,
    slot_name text,
    publications_json text,
    origin_name text
)
LANGUAGE c
STRICT
VOLATILE
PARALLEL UNSAFE
AS 'MODULE_PATHNAME', 'remote_native_subscription_status_wrapper';
"#
    )]
    fn remote_native_subscription_status(
        dsn: &str,
        subscription_name: &str,
        connect_timeout_seconds: default!(i32, 10),
        statement_timeout_ms: default!(i32, 600000),
        lock_timeout_ms: default!(i32, 30000),
    ) -> TableIterator<
        'static,
        (
            name!(enabled, bool),
            name!(subid, i64),
            name!(slot_name, Option<String>),
            name!(publications_json, String),
            name!(origin_name, String),
        ),
    > {
        let status = transport::libpq::fetch_native_subscription_status(
            dsn,
            subscription_name,
            connect_timeout_seconds,
            statement_timeout_ms,
            lock_timeout_ms,
        )
        .unwrap_or_else(|err| pgrx::error!("{err}"));

        TableIterator::once((
            status.enabled,
            status.subid,
            status.slot_name,
            status.publications_json,
            status.origin_name,
        ))
    }

    /// Fetch pglogical per-table synchronization state from a remote subscriber.
    #[pg_extern(
        volatile,
        parallel_unsafe,
        sql = r#"
CREATE FUNCTION pgl_validate.remote_pglogical_table_sync_status(
    dsn text,
    subscription_name text,
    schema_name text,
    table_name text,
    connect_timeout_seconds integer DEFAULT 10,
    statement_timeout_ms integer DEFAULT 600000,
    lock_timeout_ms integer DEFAULT 30000
)
RETURNS TABLE (
    sync_status text,
    sync_status_lsn pg_lsn
)
LANGUAGE c
STRICT
VOLATILE
PARALLEL UNSAFE
AS 'MODULE_PATHNAME', 'remote_pglogical_table_sync_status_wrapper';
"#
    )]
    fn remote_pglogical_table_sync_status(
        dsn: &str,
        subscription_name: &str,
        schema_name: &str,
        table_name: &str,
        connect_timeout_seconds: default!(i32, 10),
        statement_timeout_ms: default!(i32, 600000),
        lock_timeout_ms: default!(i32, 30000),
    ) -> TableIterator<
        'static,
        (
            name!(sync_status, Option<String>),
            name!(sync_status_lsn, Option<i64>),
        ),
    > {
        let status = transport::libpq::fetch_pglogical_table_sync_status(
            dsn,
            subscription_name,
            schema_name,
            table_name,
            connect_timeout_seconds,
            statement_timeout_ms,
            lock_timeout_ms,
        )
        .unwrap_or_else(|err| pgrx::error!("{err}"));

        TableIterator::once((
            status.sync_status,
            status.sync_status_lsn.map(|lsn| lsn as i64),
        ))
    }

    /// Fetch native logical per-table synchronization state from a remote subscriber.
    #[pg_extern(
        volatile,
        parallel_unsafe,
        sql = r#"
CREATE FUNCTION pgl_validate.remote_native_table_sync_status(
    dsn text,
    subscription_name text,
    schema_name text,
    table_name text,
    connect_timeout_seconds integer DEFAULT 10,
    statement_timeout_ms integer DEFAULT 600000,
    lock_timeout_ms integer DEFAULT 30000
)
RETURNS TABLE (
    sync_status text,
    sync_status_lsn pg_lsn
)
LANGUAGE c
STRICT
VOLATILE
PARALLEL UNSAFE
AS 'MODULE_PATHNAME', 'remote_native_table_sync_status_wrapper';
"#
    )]
    fn remote_native_table_sync_status(
        dsn: &str,
        subscription_name: &str,
        schema_name: &str,
        table_name: &str,
        connect_timeout_seconds: default!(i32, 10),
        statement_timeout_ms: default!(i32, 600000),
        lock_timeout_ms: default!(i32, 30000),
    ) -> TableIterator<
        'static,
        (
            name!(sync_status, Option<String>),
            name!(sync_status_lsn, Option<i64>),
        ),
    > {
        let status = transport::libpq::fetch_native_table_sync_status(
            dsn,
            subscription_name,
            schema_name,
            table_name,
            connect_timeout_seconds,
            statement_timeout_ms,
            lock_timeout_ms,
        )
        .unwrap_or_else(|err| pgrx::error!("{err}"));

        TableIterator::once((
            status.sync_status,
            status.sync_status_lsn.map(|lsn| lsn as i64),
        ))
    }

    /// Fetch enabled downstream subscriptions that would forward all origins.
    #[pg_extern(volatile, parallel_unsafe)]
    fn remote_pglogical_forwarding_subscriptions(
        dsn: &str,
        provider_node: &str,
        connect_timeout_seconds: default!(i32, 10),
        statement_timeout_ms: default!(i32, 600000),
        lock_timeout_ms: default!(i32, 30000),
    ) -> TableIterator<'static, (name!(subscription_name, String),)> {
        let subscriptions = transport::libpq::fetch_forwarding_subscriptions(
            dsn,
            provider_node,
            connect_timeout_seconds,
            statement_timeout_ms,
            lock_timeout_ms,
        )
        .unwrap_or_else(|err| pgrx::error!("{err}"));

        TableIterator::new(
            subscriptions
                .into_iter()
                .map(|subscription| (subscription.subscription_name,)),
        )
    }

    /// Fetch pglogical conflict-history rows from a remote subscriber.
    #[pg_extern(
        volatile,
        parallel_unsafe,
        sql = r#"
CREATE FUNCTION pgl_validate.remote_pglogical_conflict_history(
    dsn text,
    subscription_name text,
    schema_name text,
    table_name text,
    since_text text,
    max_rows integer DEFAULT 1000,
    connect_timeout_seconds integer DEFAULT 10,
    statement_timeout_ms integer DEFAULT 600000,
    lock_timeout_ms integer DEFAULT 30000
)
RETURNS TABLE (
    conflict_id bigint,
    recorded_at_text text,
    subscription_name text,
    conflict_type text,
    resolution text,
    index_name text,
    local_tuple_json text,
    local_xid text,
    local_origin integer,
    local_commit_ts_text text,
    remote_tuple_json text,
    remote_origin integer,
    remote_commit_ts_text text,
    remote_commit_lsn_text text,
    has_before_triggers boolean
)
LANGUAGE c
STRICT
VOLATILE
PARALLEL UNSAFE
AS 'MODULE_PATHNAME', 'remote_pglogical_conflict_history_wrapper';
"#
    )]
    fn remote_pglogical_conflict_history(
        dsn: &str,
        subscription_name: &str,
        schema_name: &str,
        table_name: &str,
        since_text: &str,
        max_rows: default!(i32, 1000),
        connect_timeout_seconds: default!(i32, 10),
        statement_timeout_ms: default!(i32, 600000),
        lock_timeout_ms: default!(i32, 30000),
    ) -> TableIterator<
        'static,
        (
            name!(conflict_id, i64),
            name!(recorded_at_text, String),
            name!(subscription_name, Option<String>),
            name!(conflict_type, String),
            name!(resolution, String),
            name!(index_name, Option<String>),
            name!(local_tuple_json, Option<String>),
            name!(local_xid, Option<String>),
            name!(local_origin, Option<i32>),
            name!(local_commit_ts_text, Option<String>),
            name!(remote_tuple_json, Option<String>),
            name!(remote_origin, i32),
            name!(remote_commit_ts_text, String),
            name!(remote_commit_lsn_text, String),
            name!(has_before_triggers, bool),
        ),
    > {
        let rows = transport::libpq::fetch_conflict_history(
            dsn,
            subscription_name,
            schema_name,
            table_name,
            since_text,
            max_rows,
            connect_timeout_seconds,
            statement_timeout_ms,
            lock_timeout_ms,
        )
        .unwrap_or_else(|err| pgrx::error!("{err}"));

        TableIterator::new(rows.into_iter().map(|row| {
            (
                row.conflict_id,
                row.recorded_at,
                row.subscription_name,
                row.conflict_type,
                row.resolution,
                row.index_name,
                row.local_tuple_json,
                row.local_xid,
                row.local_origin,
                row.local_commit_ts,
                row.remote_tuple_json,
                row.remote_origin,
                row.remote_commit_ts,
                transport::libpq::format_lsn(row.remote_commit_lsn),
                row.has_before_triggers,
            )
        }))
    }

    #[pg_aggregate]
    impl Aggregate<lthash_state> for lthash_state {
        type State = PgVarlena<Self>;
        type Args = pgrx::name!(row_digest, Option<Vec<u8>>);
        type Finalize = PgVarlena<lthash_state>;

        const INITIAL_CONDITION: Option<&'static str> = Some("0");
        const PARALLEL: Option<ParallelOption> = Some(ParallelOption::Safe);

        #[pgrx(immutable, parallel_safe)]
        fn state(
            current: Self::State,
            row_digest: Self::Args,
            _fcinfo: pg_sys::FunctionCallInfo,
        ) -> Self::State {
            let mut core = current.to_core();
            if let Some(row_digest) = row_digest {
                digest::lthash::add_row_digest(&mut core, &row_digest);
            }
            let mut out = PgVarlena::<Self>::new();
            out.lane_blocks = Self::from_core(core).lane_blocks;
            out
        }

        fn finalize(
            current: Self::State,
            _direct_args: Self::OrderedSetArgs,
            _fcinfo: pg_sys::FunctionCallInfo,
        ) -> Self::Finalize {
            current
        }

        fn combine(
            current: Self::State,
            other: Self::State,
            _fcinfo: pg_sys::FunctionCallInfo,
        ) -> Self::State {
            let combined = digest::lthash::combine(current.to_core(), other.to_core());
            let mut out = PgVarlena::<Self>::new();
            out.lane_blocks = Self::from_core(combined).lane_blocks;
            out
        }
    }
}
