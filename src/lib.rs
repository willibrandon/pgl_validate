//! PostgreSQL extension entry points for `pgl_validate`.
//!
//! The Rust surface owns low-level digest primitives and pgrx bindings; the
//! SQL files own the catalog and coordinator-facing stored procedures.
#![deny(missing_docs)]

use pgrx::prelude::*;
use pgrx::{GucContext, GucFlags, GucRegistry, GucSetting};

mod digest;
mod transport;

pgrx::pg_module_magic!(name, version);

extension_sql_file!("../sql/bootstrap.sql", name = "bootstrap", bootstrap);
extension_sql_file!("../sql/comments.sql", name = "comments", finalize);

static PARANOID_CONFIRM: GucSetting<bool> = GucSetting::<bool>::new(false);
static CHUNK_TARGET_ROWS: GucSetting<i32> = GucSetting::<i32>::new(50000);
static LOCALIZE_THRESHOLD: GucSetting<i32> = GucSetting::<i32>::new(1000);
static RECHECK_PASSES: GucSetting<i32> = GucSetting::<i32>::new(3);
static FENCE_TIMEOUT_MS: GucSetting<i32> = GucSetting::<i32>::new(300000);
static FENCE_POLL_INTERVAL_MS: GucSetting<i32> = GucSetting::<i32>::new(100);
static SEQUENCE_BUFFER_MULTIPLIER: GucSetting<i32> = GucSetting::<i32>::new(2);
static CORRELATE_CONFLICT_HISTORY: GucSetting<bool> = GucSetting::<bool>::new(true);
static CONFLICT_HISTORY_MAX_ROWS: GucSetting<i32> = GucSetting::<i32>::new(1000);

/// Register `pgl_validate.*` settings with PostgreSQL.
#[pg_guard]
pub extern "C-unwind" fn _PG_init() {
    let flags = GucFlags::default();

    GucRegistry::define_bool_guc(
        c"pgl_validate.paranoid_confirm",
        c"Confirm clean chunks cryptographically.",
        c"Run hash_digest_array confirmation for clean chunks in addition to LtHash.",
        &PARANOID_CONFIRM,
        GucContext::Userset,
        flags,
    );
    GucRegistry::define_int_guc(
        c"pgl_validate.chunk_target_rows",
        c"Target rows per checksum chunk.",
        c"Controls planner-visible key-range chunk sizing for table validation.",
        &CHUNK_TARGET_ROWS,
        1,
        i32::MAX,
        GucContext::Userset,
        flags,
    );
    GucRegistry::define_int_guc(
        c"pgl_validate.localize_threshold",
        c"Rows per range while localizing divergence.",
        c"Controls the smaller chunk size used after a table-level checksum mismatch.",
        &LOCALIZE_THRESHOLD,
        1,
        i32::MAX,
        GucContext::Userset,
        flags,
    );
    GucRegistry::define_int_guc(
        c"pgl_validate.recheck_passes",
        c"Digest-stability recheck pass limit.",
        c"Maximum later barrier-converged epochs before a continuously hot key becomes indeterminate.",
        &RECHECK_PASSES,
        1,
        i32::MAX,
        GucContext::Userset,
        flags,
    );
    GucRegistry::define_int_guc(
        c"pgl_validate.fence_timeout_ms",
        c"Fence wait timeout in milliseconds.",
        c"Maximum time to wait for pglogical origin progress or standby replay convergence.",
        &FENCE_TIMEOUT_MS,
        1,
        i32::MAX,
        GucContext::Userset,
        flags,
    );
    GucRegistry::define_int_guc(
        c"pgl_validate.fence_poll_interval_ms",
        c"Fence polling interval in milliseconds.",
        c"Interval between convergence checks while waiting for pglogical or standby fences.",
        &FENCE_POLL_INTERVAL_MS,
        1,
        i32::MAX,
        GucContext::Userset,
        flags,
    );
    GucRegistry::define_int_guc(
        c"pgl_validate.sequence_buffer_multiplier",
        c"Sequence cache tolerance multiplier.",
        c"Allowed sequence-ahead window expressed as cache_size multiplied by this value.",
        &SEQUENCE_BUFFER_MULTIPLIER,
        1,
        i32::MAX,
        GucContext::Userset,
        flags,
    );
    GucRegistry::define_bool_guc(
        c"pgl_validate.correlate_conflict_history",
        c"Correlate pglogical conflict history.",
        c"Attach pglogical conflict-history rows to confirmed divergences when available.",
        &CORRELATE_CONFLICT_HISTORY,
        GucContext::Userset,
        flags,
    );
    GucRegistry::define_int_guc(
        c"pgl_validate.conflict_history_max_rows",
        c"Maximum conflict-history rows per divergence lookup.",
        c"Bounds pglogical conflict-history correlation work per validation run.",
        &CONFLICT_HISTORY_MAX_ROWS,
        1,
        i32::MAX,
        GucContext::Userset,
        flags,
    );
}

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

#[cfg(any(test, feature = "pg_test"))]
#[pg_schema]
mod tests {
    use pgrx::prelude::*;

    fn sql_literal(value: &str) -> String {
        format!("'{}'", value.replace('\'', "''"))
    }

    fn identifier(value: &str) -> String {
        assert!(
            value.chars().all(|c| c.is_ascii_alphanumeric() || c == '_'),
            "test identifier contains unsafe characters: {value}"
        );
        value.to_string()
    }

    fn local_dsn() -> String {
        let port = Spi::get_one::<i32>("SELECT inet_server_port()")
            .unwrap()
            .unwrap();
        let dbname = Spi::get_one::<String>("SELECT current_database()::text")
            .unwrap()
            .unwrap();
        let user = Spi::get_one::<String>("SELECT current_user::text")
            .unwrap()
            .unwrap();

        format!(
            "host=localhost port={port} dbname={dbname} user={user} connect_timeout=5 application_name=pgl_validate_test options='-c statement_timeout=10000 -c lock_timeout=10000'"
        )
    }

    fn peer_dsn(dbname: &str) -> String {
        let port = Spi::get_one::<i32>("SELECT inet_server_port()")
            .unwrap()
            .unwrap();
        let user = Spi::get_one::<String>("SELECT current_user::text")
            .unwrap()
            .unwrap();

        format!(
            "host=localhost port={port} dbname={dbname} user={user} connect_timeout=5 application_name=pgl_validate_test options='-c statement_timeout=10000 -c lock_timeout=10000'"
        )
    }

    #[pg_test]
    fn hash_digest_array_is_order_sensitive_by_contract() {
        let first = Spi::get_one::<Vec<u8>>(
            "SELECT pgl_validate.hash_digest_array(ARRAY['\\x01'::bytea, '\\x02'::bytea])",
        )
        .unwrap()
        .unwrap();
        let second = Spi::get_one::<Vec<u8>>(
            "SELECT pgl_validate.hash_digest_array(ARRAY['\\x02'::bytea, '\\x01'::bytea])",
        )
        .unwrap()
        .unwrap();
        assert_ne!(first, second);
    }

    #[pg_test]
    fn row_digest_distinguishes_null_from_empty_text() {
        let null_digest =
            Spi::get_one::<Vec<u8>>("SELECT pgl_validate.row_digest(ARRAY[2], NULL::text)")
                .unwrap()
                .unwrap();
        let empty_digest =
            Spi::get_one::<Vec<u8>>("SELECT pgl_validate.row_digest(ARRAY[2], ''::text)")
                .unwrap()
                .unwrap();
        assert_ne!(null_digest, empty_digest);
    }

    #[pg_test]
    fn row_digest_supports_send_mode() {
        let one = Spi::get_one::<Vec<u8>>("SELECT pgl_validate.row_digest(ARRAY[1], 1::int4)")
            .unwrap()
            .unwrap();
        let another_one =
            Spi::get_one::<Vec<u8>>("SELECT pgl_validate.row_digest(ARRAY[1], 1::int4)")
                .unwrap()
                .unwrap();
        let two = Spi::get_one::<Vec<u8>>("SELECT pgl_validate.row_digest(ARRAY[1], 2::int4)")
            .unwrap()
            .unwrap();

        assert_eq!(one, another_one);
        assert_ne!(one, two);
    }

    #[pg_test]
    fn lthash_aggregate_is_order_independent_and_duplicate_sensitive() {
        Spi::run(
            r#"
            CREATE TEMP TABLE digest_rows(ord int, rd bytea);
            INSERT INTO digest_rows
            VALUES
                (1, pgl_validate.row_digest(ARRAY[1], 1::int4)),
                (2, pgl_validate.row_digest(ARRAY[1], 2::int4));
            "#,
        )
        .unwrap();

        let forward = Spi::get_one::<String>(
            "SELECT pgl_validate.lthash(rd)::text FROM (SELECT rd FROM digest_rows ORDER BY ord) s",
        )
        .unwrap()
        .unwrap();
        let reverse = Spi::get_one::<String>(
            "SELECT pgl_validate.lthash(rd)::text FROM (SELECT rd FROM digest_rows ORDER BY ord DESC) s",
        )
        .unwrap()
        .unwrap();
        let duplicate = Spi::get_one::<String>(
            "SELECT pgl_validate.lthash(rd)::text FROM (
                SELECT rd FROM digest_rows
                UNION ALL
                SELECT rd FROM digest_rows WHERE ord = 1
             ) s",
        )
        .unwrap()
        .unwrap();

        assert_eq!(forward, reverse);
        assert_ne!(forward, duplicate);
    }

    #[pg_test]
    fn plan_chunk_sql_sorts_columns_and_uses_variadic_row_digest() {
        Spi::run(
            r#"
            CREATE TEMP TABLE plan_target(
                status text,
                id int PRIMARY KEY,
                amount numeric
            );
            INSERT INTO plan_target VALUES
                ('before', 1, 9.50),
                ('inside-low', 2, 10.25),
                ('inside-high', 9, 11.50),
                ('after', 10, 12.00);
            "#,
        )
        .unwrap();

        let sql = Spi::get_one::<String>(
            r#"
            SELECT pgl_validate.plan_chunk_sql(
                'plan_target'::regclass,
                ARRAY['id'],
                NULL,
                NULL,
                ARRAY['status','id','amount']
            )
            "#,
        )
        .unwrap()
        .unwrap();

        assert!(sql.contains("count(*)::bigint AS n_rows"));
        assert!(sql.contains("pgl_validate.lthash_bytes(pgl_validate.lthash("));
        assert!(sql.contains("NULL::bytea AS set_hash"));
        assert!(
            sql.contains("pgl_validate.row_digest('{2,1,1}'::int[], t.amount, t.id, t.status)")
        );
        assert!(!sql.contains("ARRAY[t."));

        let confirm_sql = Spi::get_one::<String>(
            r#"
            SELECT pgl_validate.plan_chunk_sql(
                'plan_target'::regclass,
                ARRAY['id'],
                NULL,
                NULL,
                ARRAY['status','id','amount'],
                NULL,
                NULL,
                true
            )
            "#,
        )
        .unwrap()
        .unwrap();

        assert!(confirm_sql.contains("pgl_validate.hash_digest_array"));
        assert!(confirm_sql.contains("array_agg(rd ORDER BY rd)"));

        let bounded_sql = Spi::get_one::<String>(
            r#"
            SELECT pgl_validate.plan_chunk_sql(
                'plan_target'::regclass,
                ARRAY['id'],
                convert_to('{"id":2}', 'UTF8'),
                convert_to('{"id":10}', 'UTF8'),
                ARRAY['status','id','amount']
            )
            "#,
        )
        .unwrap()
        .unwrap();
        assert!(bounded_sql.contains("t.id >= '2'::integer"));
        assert!(bounded_sql.contains("t.id < '10'::integer"));

        let bounded_count =
            Spi::get_one::<i64>(&format!("SELECT n_rows FROM ({bounded_sql}) AS q"))
                .unwrap()
                .unwrap();
        assert_eq!(bounded_count, 2);

        let planned_ranges = Spi::get_one::<String>(
            r#"
            SELECT string_agg(
                       chunk_id::text || ':' ||
                       COALESCE(convert_from(lo, 'UTF8')::jsonb->>'id', '<null>') || ':' ||
                       COALESCE(convert_from(hi, 'UTF8')::jsonb->>'id', '<null>') || ':' ||
                       n_rows::text,
                       ',' ORDER BY chunk_id
                   )
            FROM pgl_validate.plan_key_ranges(
                'plan_target'::regclass,
                ARRAY['id'],
                NULL,
                NULL,
                2
            )
            "#,
        )
        .unwrap()
        .unwrap();
        assert_eq!(planned_ranges, "1:<null>:9:2,2:9:<null>:2");

        Spi::run(
            r#"
            CREATE TEMP TABLE plan_composite(
                part int NOT NULL,
                code text NOT NULL,
                amount int,
                PRIMARY KEY (part, code)
            );
            INSERT INTO plan_composite VALUES
                (1, 'a', 10),
                (1, 'b', 20),
                (2, 'a', 30),
                (2, 'b', 40);
            "#,
        )
        .unwrap();

        let composite_sql = Spi::get_one::<String>(
            r#"
            SELECT pgl_validate.plan_chunk_sql(
                'plan_composite'::regclass,
                ARRAY['part','code'],
                convert_to('{"part":1,"code":"b"}', 'UTF8'),
                convert_to('{"part":2,"code":"b"}', 'UTF8'),
                ARRAY['part','code','amount']
            )
            "#,
        )
        .unwrap()
        .unwrap();
        assert!(composite_sql.contains("(t.part, t.code) >= ('1'::integer, 'b'::text)"));
        assert!(composite_sql.contains("(t.part, t.code) < ('2'::integer, 'b'::text)"));

        let composite_count =
            Spi::get_one::<i64>(&format!("SELECT n_rows FROM ({composite_sql}) AS q"))
                .unwrap()
                .unwrap();
        assert_eq!(composite_count, 2);

        let localize_sql = Spi::get_one::<String>(
            r#"
            SELECT pgl_validate.plan_localize_sql(
                'plan_composite'::regclass,
                ARRAY['part','code'],
                convert_to('{"part":1,"code":"b"}', 'UTF8'),
                convert_to('{"part":2,"code":"b"}', 'UTF8'),
                ARRAY['part','code','amount']
            )
            "#,
        )
        .unwrap()
        .unwrap();
        assert!(localize_sql.contains("(t.part, t.code) >= ('1'::integer, 'b'::text)"));
        assert!(localize_sql.contains("(t.part, t.code) < ('2'::integer, 'b'::text)"));

        let localized_count =
            Spi::get_one::<i64>(&format!("SELECT count(*) FROM ({localize_sql}) AS q"))
                .unwrap()
                .unwrap();
        assert_eq!(localized_count, 2);

        let composite_ranges = Spi::get_one::<String>(
            r#"
            WITH ranges AS (
                SELECT
                    chunk_id,
                    convert_from(lo, 'UTF8')::jsonb AS lo_doc,
                    convert_from(hi, 'UTF8')::jsonb AS hi_doc,
                    n_rows
                FROM pgl_validate.plan_key_ranges(
                    'plan_composite'::regclass,
                    ARRAY['part','code'],
                    convert_to('{"part":1,"code":"b"}', 'UTF8'),
                    convert_to('{"part":2,"code":"b"}', 'UTF8'),
                    1
                )
            )
            SELECT string_agg(
                       chunk_id::text || ':' ||
                       (lo_doc->>'part') || '/' || (lo_doc->>'code') || ':' ||
                       (hi_doc->>'part') || '/' || (hi_doc->>'code') || ':' ||
                       n_rows::text,
                       ',' ORDER BY chunk_id
                   )
            FROM ranges
            "#,
        )
        .unwrap()
        .unwrap();
        assert_eq!(composite_ranges, "1:1/b:2/a:1,2:2/a:2/b:1");
    }

    #[pg_test]
    fn compare_table_records_local_match_result() {
        Spi::run(
            r#"
            CREATE TEMP TABLE compare_target(
                id int PRIMARY KEY,
                amount numeric,
                status text
            );
            INSERT INTO compare_target VALUES
                (1, 10.25, 'open'),
                (2, 11.50, 'closed');
            "#,
        )
        .unwrap();

        let verdict = Spi::get_one::<String>(
            "SELECT (pgl_validate.compare_table('compare_target'::regclass)).verdict",
        )
        .unwrap()
        .unwrap();
        assert_eq!(verdict, "match");

        let node_rows = Spi::get_one::<i64>(
            "SELECT n_rows FROM pgl_validate.table_node_result WHERE table_name = 'compare_target'",
        )
        .unwrap()
        .unwrap();
        assert_eq!(node_rows, 2);

        let lthash_present = Spi::get_one::<bool>(
            "SELECT lthash IS NOT NULL FROM pgl_validate.table_node_result WHERE table_name = 'compare_target'",
        )
        .unwrap()
        .unwrap();
        assert!(lthash_present);

        let root_chunk = Spi::get_one::<String>(
            "
            SELECT cr.state || ';' || cnr.n_rows::text || ';' || (cnr.lthash IS NOT NULL)::text
            FROM pgl_validate.chunk_result cr
            JOIN pgl_validate.chunk_node_result cnr
              USING (run_id, schema_name, table_name, chunk_id)
            WHERE cr.table_name = 'compare_target'
              AND cr.chunk_id = 1
              AND cnr.node = 'local'
            ",
        )
        .unwrap()
        .unwrap();
        assert_eq!(root_chunk, "clean;2;true");
    }

    #[pg_test]
    fn compare_table_persists_planned_key_range_chunks() {
        Spi::run(
            r#"
            DELETE FROM pgl_validate.peer;
            CREATE TEMP TABLE range_compare_target(
                id int PRIMARY KEY,
                value text
            );
            INSERT INTO range_compare_target
            SELECT g, 'value-' || g::text
            FROM generate_series(1, 5) AS g;
            "#,
        )
        .unwrap();

        let run_id = Spi::get_one::<i64>(
            r#"
            SELECT (pgl_validate.compare_table(
                'range_compare_target'::regclass,
                ARRAY[]::text[],
                '{"chunk_target_rows":2}'::jsonb
            )).run_id
            "#,
        )
        .unwrap()
        .unwrap();

        let chunk_shape = Spi::get_one::<String>(&format!(
            "
            SELECT string_agg(
                       chunk_id::text || ':' || state || ':' ||
                       COALESCE(convert_from(lo, 'UTF8')::jsonb->>'id', '<null>') || ':' ||
                       COALESCE(convert_from(hi, 'UTF8')::jsonb->>'id', '<null>'),
                       ',' ORDER BY chunk_id
                   )
            FROM pgl_validate.chunk_result
            WHERE run_id = {run_id}
              AND table_name = 'range_compare_target'
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(
            chunk_shape,
            "1:split:<null>:<null>,2:clean:<null>:3,3:clean:3:5,4:clean:5:<null>"
        );

        let node_rows = Spi::get_one::<String>(&format!(
            "
            SELECT string_agg(chunk_id::text || ':' || n_rows::text, ',' ORDER BY chunk_id)
            FROM pgl_validate.chunk_node_result
            WHERE run_id = {run_id}
              AND table_name = 'range_compare_target'
              AND node = 'local'
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(node_rows, "1:5,2:2,3:2,4:1");

        let progress = Spi::get_one::<String>(&format!(
            "
            SELECT chunks_done::text || '/' || chunks_total::text
            FROM pgl_validate.run_progress
            WHERE run_id = {run_id}
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(progress, "3/3");
    }

    #[pg_test]
    fn compare_uses_guc_defaults_with_option_overrides() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let peer_db = identifier(&format!("pgl_validate_guc_peer_{backend_pid}"));
        let table_name = identifier(&format!("pgl_validate_guc_target_{backend_pid}"));
        let sequence_name = identifier(&format!("pgl_validate_guc_seq_{backend_pid}"));
        let local_dsn = local_dsn();
        let remote_dsn = peer_dsn(&peer_db);

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
        crate::transport::libpq::execute_command(&local_dsn, &format!("CREATE DATABASE {peer_db}"))
            .unwrap();
        crate::transport::libpq::execute_command(
            &remote_dsn,
            &format!(
                "CREATE EXTENSION pgl_validate;
                 CREATE TABLE public.{table_name}(id int PRIMARY KEY, value text);
                 INSERT INTO public.{table_name}
                 SELECT g, 'value-' || g::text
                 FROM generate_series(1, 5) AS g;
                 CREATE SEQUENCE public.{sequence_name} CACHE 5;
                 DO $pgl_validate_guc$
                 BEGIN
                     PERFORM setval('public.{sequence_name}'::regclass, 17, true);
                 END
                 $pgl_validate_guc$;"
            ),
        )
        .unwrap();

        Spi::run(&format!(
            "
            SET LOCAL pgl_validate.chunk_target_rows = 2;
            SET LOCAL pgl_validate.recheck_passes = 2;
            SET LOCAL pgl_validate.sequence_buffer_multiplier = 1;
            DELETE FROM pgl_validate.peer;
            CREATE TABLE public.{table_name}(id int PRIMARY KEY, value text);
            INSERT INTO public.{table_name}
            SELECT g, 'value-' || g::text
            FROM generate_series(1, 5) AS g;
            CREATE SEQUENCE public.{sequence_name} CACHE 5;
            SELECT setval('public.{sequence_name}'::regclass, 10, true);
            INSERT INTO pgl_validate.peer(name, dsn, backend)
            VALUES ('remote_guc', {remote_dsn}, 'native');
            ",
            remote_dsn = sql_literal(&remote_dsn)
        ))
        .unwrap();

        let guc_run_id = Spi::get_one::<i64>(&format!(
            "SELECT (pgl_validate.compare_table('public.{table_name}'::regclass)).run_id"
        ))
        .unwrap()
        .unwrap();
        let guc_chunks = Spi::get_one::<i64>(&format!(
            "
            SELECT count(*)
            FROM pgl_validate.chunk_result
            WHERE run_id = {guc_run_id}
              AND table_name = {table_name}
              AND state <> 'split'
            ",
            table_name = sql_literal(&table_name)
        ))
        .unwrap()
        .unwrap();
        assert_eq!(guc_chunks, 3);

        let override_run_id = Spi::get_one::<i64>(&format!(
            "
            SELECT (pgl_validate.compare_table(
                'public.{table_name}'::regclass,
                ARRAY['remote_guc'],
                '{{\"chunk_target_rows\":10}}'::jsonb
            )).run_id
            "
        ))
        .unwrap()
        .unwrap();
        let override_chunks = Spi::get_one::<i64>(&format!(
            "
            SELECT count(*)
            FROM pgl_validate.chunk_result
            WHERE run_id = {override_run_id}
              AND table_name = {table_name}
              AND state <> 'split'
            ",
            table_name = sql_literal(&table_name)
        ))
        .unwrap()
        .unwrap();
        assert_eq!(override_chunks, 1);

        let recheck_setting = Spi::get_one::<String>("SHOW pgl_validate.recheck_passes")
            .unwrap()
            .unwrap();
        assert_eq!(recheck_setting, "2");

        Spi::run(&format!(
            r#"
            DO $pgl_validate_recheck$
            DECLARE
                rejected boolean := false;
            BEGIN
                BEGIN
                    PERFORM pgl_validate.compare_table(
                        'public.{table_name}'::regclass,
                        ARRAY['remote_guc'],
                        '{{"recheck_passes":0}}'::jsonb
                    );
                EXCEPTION WHEN others THEN
                    IF SQLERRM = 'recheck_passes must be greater than zero' THEN
                        rejected := true;
                    ELSE
                        RAISE;
                    END IF;
                END;

                IF NOT rejected THEN
                    RAISE EXCEPTION 'expected compare_table to reject recheck_passes=0';
                END IF;
            END
            $pgl_validate_recheck$;
            "#
        ))
        .unwrap();

        let guc_sequence = Spi::get_one::<String>(&format!(
            "
            SELECT verdict || ';' || within_contract::text
            FROM pgl_validate.compare_sequence(
                'public.{sequence_name}'::regclass,
                ARRAY['remote_guc']
            )
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(guc_sequence, "ahead_of_window;false");

        let override_sequence = Spi::get_one::<String>(&format!(
            "
            SELECT verdict || ';' || within_contract::text
            FROM pgl_validate.compare_sequence(
                'public.{sequence_name}'::regclass,
                ARRAY['remote_guc'],
                '{{\"sequence_buffer_multiplier\":2}}'::jsonb
            )
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(override_sequence, "match;true");

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
    }

    #[pg_test]
    fn compare_table_localizes_only_divergent_key_ranges() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let peer_db = identifier(&format!("pgl_validate_range_peer_{backend_pid}"));
        let table_name = identifier(&format!("range_diff_target_{backend_pid}"));
        let local_dsn = local_dsn();
        let remote_dsn = peer_dsn(&peer_db);

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
        crate::transport::libpq::execute_command(&local_dsn, &format!("CREATE DATABASE {peer_db}"))
            .unwrap();
        crate::transport::libpq::execute_command(
            &remote_dsn,
            &format!(
                "CREATE EXTENSION pgl_validate;
                 CREATE TABLE public.{table_name}(id int PRIMARY KEY, value text);
                 INSERT INTO public.{table_name}
                 SELECT g, CASE WHEN g = 4 THEN 'remote-diff' ELSE 'same-' || g::text END
                 FROM generate_series(1, 5) AS g;"
            ),
        )
        .unwrap();

        Spi::run(&format!(
            "
            DELETE FROM pgl_validate.peer;
            CREATE TABLE public.{table_name}(id int PRIMARY KEY, value text);
            INSERT INTO public.{table_name}
            SELECT g, 'same-' || g::text
            FROM generate_series(1, 5) AS g;
            INSERT INTO pgl_validate.peer(name, dsn, backend)
            VALUES ('remote_range_diff', {remote_dsn}, 'native');
            ",
            remote_dsn = sql_literal(&remote_dsn)
        ))
        .unwrap();

        let run_id = Spi::get_one::<i64>(&format!(
            "
            SELECT (pgl_validate.compare_table(
                {table_name}::regclass,
                ARRAY['remote_range_diff'],
                '{{\"chunk_target_rows\":2,\"localize_threshold\":2}}'::jsonb
            )).run_id
            ",
            table_name = sql_literal(&format!("public.{table_name}"))
        ))
        .unwrap()
        .unwrap();

        let chunk_states = Spi::get_one::<String>(&format!(
            "
            SELECT string_agg(chunk_id::text || ':' || state, ',' ORDER BY chunk_id)
            FROM pgl_validate.chunk_result
            WHERE run_id = {run_id}
              AND table_name = {table_name}
            ",
            table_name = sql_literal(&table_name)
        ))
        .unwrap()
        .unwrap();
        assert_eq!(chunk_states, "1:split,2:clean,3:divergent,4:clean");

        let divergence_keys = Spi::get_one::<String>(&format!(
            "
            SELECT string_agg(key_text || ':' || classification || ':' || status, ',' ORDER BY key_text)
            FROM pgl_validate.divergence
            WHERE run_id = {run_id}
              AND node = 'remote_range_diff'
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(divergence_keys, "{\"id\": 4}:differs:confirmed");

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
    }

    #[pg_test]
    fn comparison_key_cols_prefers_replica_identity_and_safe_unique_indexes() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let identity_table = identifier(&format!("pgl_validate_identity_key_{backend_pid}"));
        let identity_index = identifier(&format!("pgl_validate_identity_idx_{backend_pid}"));
        let unique_table = identifier(&format!("pgl_validate_unique_key_{backend_pid}"));
        let unique_index = identifier(&format!("pgl_validate_unique_idx_{backend_pid}"));

        Spi::run(&format!(
            "
            CREATE TABLE public.{identity_table}(
                id int PRIMARY KEY,
                code text NOT NULL,
                value text
            );
            CREATE UNIQUE INDEX {identity_index} ON public.{identity_table}(code);
            ALTER TABLE public.{identity_table} REPLICA IDENTITY USING INDEX {identity_index};

            CREATE TABLE public.{unique_table}(
                code text NOT NULL,
                payload text
            );
            CREATE UNIQUE INDEX {unique_index} ON public.{unique_table}(code) INCLUDE (payload);
            "
        ))
        .unwrap();

        let key_summary = Spi::get_one::<String>(&format!(
            "
            SELECT array_to_string(pgl_validate.comparison_key_cols('public.{identity_table}'::regclass), ',') ||
                   ';' ||
                   array_to_string(pgl_validate.comparison_key_cols('public.{unique_table}'::regclass), ',')
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(key_summary, "code;code");
    }

    #[pg_test]
    fn compare_records_multiple_tables_under_one_parent_run() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let first_table = identifier(&format!("pgl_validate_compare_a_{backend_pid}"));
        let second_table = identifier(&format!("pgl_validate_compare_b_{backend_pid}"));
        let peer_name = format!("self_parent_{backend_pid}");
        let dsn = local_dsn();

        let _ = crate::transport::libpq::execute_command(
            &dsn,
            &format!("DROP TABLE IF EXISTS public.{first_table}, public.{second_table}"),
        );
        crate::transport::libpq::execute_command(
            &dsn,
            &format!(
                "CREATE TABLE public.{first_table}(id int PRIMARY KEY, value text);
                 CREATE TABLE public.{second_table}(id int PRIMARY KEY, value text);
                 INSERT INTO public.{first_table} VALUES (1, 'same');
                 INSERT INTO public.{second_table} VALUES (1, 'same');"
            ),
        )
        .unwrap();

        Spi::run(&format!(
            "
            DELETE FROM pgl_validate.peer;
            INSERT INTO pgl_validate.peer(name, dsn, backend)
            VALUES ({peer_name}, {dsn}, 'native');
            ",
            peer_name = sql_literal(&peer_name),
            dsn = sql_literal(&dsn)
        ))
        .unwrap();

        let run_id = Spi::get_one::<i64>(&format!(
            "
            SELECT pgl_validate.compare(
                ARRAY[
                    'public.{first_table}'::regclass,
                    'public.{second_table}'::regclass
                ],
                peers => ARRAY[{peer_name}]
            )
            ",
            peer_name = sql_literal(&peer_name)
        ))
        .unwrap()
        .unwrap();

        let run_shape = Spi::get_one::<String>(&format!(
            "
            SELECT r.status || ';' ||
                   r.tables_total::text || ';' ||
                   r.tables_matched::text || ';' ||
                   count(tr.*)::text || ';' ||
                   (SELECT count(*)::text
                    FROM pgl_validate.run_participant rp
                    WHERE rp.run_id = r.run_id) || ';' ||
                   jsonb_array_length(pgl_validate.report(r.run_id)->'tables')::text || ';' ||
                   (SELECT chunks_done::text || '/' || chunks_total::text
                    FROM pgl_validate.run_progress rp
                    WHERE rp.run_id = r.run_id)
            FROM pgl_validate.run r
            JOIN pgl_validate.table_result tr ON tr.run_id = r.run_id
            WHERE r.run_id = {run_id}
            GROUP BY r.run_id, r.status, r.tables_total, r.tables_matched
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(run_shape, "completed;2;2;2;2;2;2/2");

        let _ = crate::transport::libpq::execute_command(
            &dsn,
            &format!("DROP TABLE IF EXISTS public.{first_table}, public.{second_table}"),
        );
    }

    #[pg_test]
    fn remote_checksum_reads_over_libpq() {
        let dsn = local_dsn();
        let checksum_sql = "SELECT 7::bigint AS n_rows, decode('010203', 'hex') AS lthash, decode('040506', 'hex') AS set_hash";
        let sql = format!(
            "SELECT n_rows FROM pgl_validate.remote_checksum({}, {})",
            sql_literal(&dsn),
            sql_literal(checksum_sql)
        );

        let n_rows = Spi::get_one::<i64>(&sql).unwrap().unwrap();
        assert_eq!(n_rows, 7);

        let sql = format!(
            "SELECT lthash FROM pgl_validate.remote_checksum({}, {})",
            sql_literal(&dsn),
            sql_literal(checksum_sql)
        );
        let lthash = Spi::get_one::<Vec<u8>>(&sql).unwrap().unwrap();
        assert_eq!(lthash, vec![0x01, 0x02, 0x03]);

        let sql = format!(
            "SELECT set_hash FROM pgl_validate.remote_checksum({}, {})",
            sql_literal(&dsn),
            sql_literal(checksum_sql)
        );
        let set_hash = Spi::get_one::<Vec<u8>>(&sql).unwrap().unwrap();
        assert_eq!(set_hash, vec![0x04, 0x05, 0x06]);
    }

    #[pg_test]
    fn remote_inject_barrier_returns_visible_token_and_lsn() {
        let dsn = local_dsn();
        let sql = format!(
            "
            SELECT token::text || ';' || barrier_end_lsn::text
            FROM pgl_validate.remote_inject_barrier({})
            ",
            sql_literal(&dsn)
        );
        let injected = Spi::get_one::<String>(&sql).unwrap().unwrap();
        let (token, barrier_end_lsn) = injected
            .split_once(';')
            .expect("barrier result should contain token and LSN");

        let visible_sql = format!(
            "
            SELECT EXISTS (
                       SELECT 1
                       FROM pgl_validate.fence_barrier
                       WHERE token = {}::uuid
                   )
                   AND {}::pg_lsn <= pg_current_wal_lsn()
            ",
            sql_literal(token),
            sql_literal(barrier_end_lsn)
        );
        let valid = Spi::get_one::<bool>(&visible_sql).unwrap().unwrap();
        assert!(valid);
    }

    #[pg_test]
    fn record_barrier_fence_persists_epoch_edge_and_protected_token() {
        let dsn = local_dsn();
        let sql = format!(
            "
            WITH run AS (
                INSERT INTO pgl_validate.run(status)
                VALUES ('fencing')
                RETURNING run_id
            ), edge AS (
                INSERT INTO pgl_validate.run_edge(
                    run_id, edge_id, provider_node, target_node, backend,
                    subscription, slot_name, origin_name, repsets
                )
                SELECT run_id, 1, 'origin', 'target', 'pglogical',
                       'sub', 'slot', 'origin_name', ARRAY['default']
                FROM run
                RETURNING run_id, edge_id
            ), injected AS (
                SELECT * FROM pgl_validate.remote_inject_barrier({})
            ), recorded AS (
                SELECT pgl_validate.record_barrier_fence(
                    edge.run_id,
                    1,
                    edge.edge_id,
                    injected.token,
                    'origin',
                    injected.barrier_end_lsn
                )
                FROM edge, injected
            )
            SELECT edge.run_id::text || ';' ||
                   injected.token::text || ';' ||
                   injected.barrier_end_lsn::text
            FROM edge, injected, recorded
            ",
            sql_literal(&dsn)
        );
        let recorded_values = Spi::get_one::<String>(&sql).unwrap().unwrap();
        let mut parts = recorded_values.split(';');
        let run_id = parts.next().expect("run id should be present");
        let token = parts.next().expect("token should be present");
        let barrier_end_lsn = parts.next().expect("barrier LSN should be present");

        let verify_sql = format!(
            "
            SELECT EXISTS (
                       SELECT 1
                       FROM pgl_validate.fence_edge
                       WHERE run_id = {}
                         AND fence_kind = 'barrier'
                         AND barrier_token = {}::uuid
                         AND barrier_end_lsn = {}::pg_lsn
                   )
                   AND {}::uuid = ANY (pgl_validate.protected_barrier_tokens())
            ",
            run_id,
            sql_literal(token),
            sql_literal(barrier_end_lsn),
            sql_literal(token)
        );
        let recorded = Spi::get_one::<bool>(&verify_sql).unwrap().unwrap();
        assert!(recorded);
    }

    #[pg_test]
    fn remote_observe_barrier_reports_origin_progress_and_token_visibility() {
        let dsn = local_dsn();
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let origin_name = identifier(&format!("pgl_validate_origin_{backend_pid}"));

        let injected_sql = format!(
            "
            SELECT token::text || ';' || barrier_end_lsn::text
            FROM pgl_validate.remote_inject_barrier({})
            ",
            sql_literal(&dsn)
        );
        let injected = Spi::get_one::<String>(&injected_sql).unwrap().unwrap();
        let (token, barrier_end_lsn) = injected
            .split_once(';')
            .expect("barrier result should contain token and LSN");

        crate::transport::libpq::execute_command(
            &dsn,
            &format!(
                "DO $$ BEGIN PERFORM pg_replication_origin_create({}); END $$",
                sql_literal(&origin_name)
            ),
        )
        .unwrap();
        crate::transport::libpq::execute_command(
            &dsn,
            &format!(
                "DO $$ BEGIN PERFORM pg_replication_origin_advance({}, {}::pg_lsn); END $$",
                sql_literal(&origin_name),
                sql_literal(barrier_end_lsn)
            ),
        )
        .unwrap();

        let observe_sql = format!(
            "
            SELECT token_visible::text || ';' ||
                   converged::text || ';' ||
                   (origin_progress_lsn >= {}::pg_lsn)::text
            FROM pgl_validate.remote_observe_barrier(
                {},
                {},
                {}::uuid,
                {}::pg_lsn
            )
            ",
            sql_literal(barrier_end_lsn),
            sql_literal(&dsn),
            sql_literal(&origin_name),
            sql_literal(token),
            sql_literal(barrier_end_lsn)
        );
        let observed = Spi::get_one::<String>(&observe_sql).unwrap().unwrap();
        assert_eq!(observed, "true;true;true");

        let _ = crate::transport::libpq::execute_command(
            &dsn,
            &format!(
                "DO $$ BEGIN PERFORM pg_replication_origin_drop({}); END $$",
                sql_literal(&origin_name)
            ),
        );
    }

    #[pg_test]
    fn remote_standby_replay_status_reports_primary_not_in_recovery() {
        let dsn = local_dsn();
        let status = Spi::get_one::<String>(&format!(
            "
            SELECT (pg_version > 0)::text || ';' ||
                   in_recovery::text || ';' ||
                   replay_lsn::text || ';' ||
                   replay_paused::text
            FROM pgl_validate.remote_standby_replay_status({})
            ",
            sql_literal(&dsn)
        ))
        .unwrap()
        .unwrap();

        assert_eq!(status, "true;false;0/0;false");
    }

    #[pg_test]
    fn fence_standby_edge_rejects_primary_peer() {
        let dsn = local_dsn();
        let sql = format!(
            "
            DO $$
            DECLARE
                run_id bigint;
            BEGIN
                INSERT INTO pgl_validate.run(status)
                VALUES ('fencing')
                RETURNING pgl_validate.run.run_id INTO run_id;

                BEGIN
                    PERFORM pgl_validate.fence_standby_edge(
                        run_id,
                        1,
                        1,
                        'local',
                        'primary_peer',
                        {},
                        pg_current_wal_lsn(),
                        10,
                        10000,
                        10000,
                        100,
                        10
                    );
                    RAISE EXCEPTION 'expected primary peer to be rejected';
                EXCEPTION WHEN SQLSTATE '0A000' THEN
                    IF SQLERRM <> 'standby peer primary_peer is not in recovery' THEN
                        RAISE;
                    END IF;
                END;
            END
            $$;
            ",
            sql_literal(&dsn)
        );

        Spi::run(&sql).unwrap();
    }

    #[pg_test]
    fn compare_table_autodetects_standby_backend_and_fails_closed_on_primary_peer() {
        let dsn = local_dsn();
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let table_name = identifier(&format!("pgl_validate_standby_detect_{backend_pid}"));

        Spi::run(&format!(
            "
            CREATE TABLE public.{table_name}(id int PRIMARY KEY, value text);
            INSERT INTO public.{table_name} VALUES (1, 'same');
            DELETE FROM pgl_validate.peer;
            INSERT INTO pgl_validate.peer(name, dsn, backend)
            VALUES ('standby_primary', {}, 'standby');
            ",
            sql_literal(&dsn)
        ))
        .unwrap();

        let compare_sql = format!(
            "
            DO $$
            BEGIN
                BEGIN
                    PERFORM pgl_validate.compare_table('public.{table_name}'::regclass);
                    RAISE EXCEPTION 'expected standby peer to require replay fencing';
                EXCEPTION WHEN SQLSTATE '0A000' THEN
                    IF SQLERRM <> 'standby peer standby_primary is not in recovery' THEN
                        RAISE;
                    END IF;
                END;
            END
            $$;
            "
        );
        Spi::run(&compare_sql).unwrap();

        Spi::run("DELETE FROM pgl_validate.peer WHERE name = 'standby_primary'").unwrap();
    }

    #[pg_test]
    fn record_fence_attempt_derives_converged_and_waiting_statuses() {
        let converged = Spi::get_one::<bool>(
            r#"
            WITH run AS (
                INSERT INTO pgl_validate.run(status)
                VALUES ('fencing')
                RETURNING run_id
            ), edge AS (
                INSERT INTO pgl_validate.run_edge(
                    run_id, edge_id, provider_node, target_node, backend,
                    subscription, slot_name, origin_name, repsets
                )
                SELECT run_id, 1, 'origin', 'target', 'pglogical',
                       'sub', 'slot', 'origin_name', ARRAY['default']
                FROM run
                RETURNING run_id, edge_id
            ), fence AS (
                INSERT INTO pgl_validate.fence_epoch(run_id, epoch_seq)
                SELECT run_id, 1 FROM run
                RETURNING run_id, epoch_seq
            ), fence_edge AS (
                INSERT INTO pgl_validate.fence_edge(
                    run_id, epoch_seq, edge_id, fence_kind, barrier_token, barrier_end_lsn
                )
                SELECT edge.run_id, 1, edge.edge_id, 'barrier',
                       '66666666-6666-6666-6666-666666666666'::uuid,
                       '0/20'::pg_lsn
                FROM edge
                RETURNING run_id, epoch_seq, edge_id
            ), attempt AS (
                SELECT pgl_validate.record_fence_attempt(
                    run_id, epoch_seq, edge_id,
                    '0/20'::pg_lsn,
                    '0/20'::pg_lsn,
                    true,
                    '0/20'::pg_lsn
                ) AS row
                FROM fence_edge
            )
            SELECT ((row).status = 'converged' AND (row).converged_at IS NOT NULL)
            FROM attempt
            "#,
        )
        .unwrap()
        .unwrap();
        assert!(converged);

        let waiting = Spi::get_one::<bool>(
            r#"
            WITH latest AS (
                SELECT run_id, epoch_seq, edge_id
                FROM pgl_validate.fence_edge
                WHERE barrier_token = '66666666-6666-6666-6666-666666666666'::uuid
            ), attempt AS (
                SELECT pgl_validate.record_fence_attempt(
                    run_id, epoch_seq, edge_id,
                    '0/20'::pg_lsn,
                    '0/10'::pg_lsn,
                    true,
                    '0/20'::pg_lsn
                ) AS row
                FROM latest
            )
            SELECT ((row).status = 'waiting' AND (row).converged_at IS NULL)
            FROM attempt
            "#,
        )
        .unwrap()
        .unwrap();
        assert!(waiting);
    }

    #[pg_test]
    fn native_contract_uses_publication_columns_filters_and_actions() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let table_name = identifier(&format!("native_contract_target_{backend_pid}"));
        let publication_name = identifier(&format!("pgl_validate_native_pub_{backend_pid}"));

        Spi::run(&format!(
            "
            CREATE TABLE public.{table_name}(
                id int PRIMARY KEY,
                kept text,
                ignored text
            );
            CREATE PUBLICATION {publication_name}
            FOR TABLE public.{table_name} (id, kept)
            WHERE (id > 0);
            "
        ))
        .unwrap();

        let contract = Spi::get_one::<String>(&format!(
            "
            SELECT array_to_string(att_list, ',') || ';' ||
                   validated_property || ';' ||
                   exact_comparable::text || ';' ||
                   has_row_filter::text || ';' ||
                   repl_insert::text || ';' ||
                   repl_update::text || ';' ||
                   repl_delete::text || ';' ||
                   repl_truncate::text
            FROM pgl_validate.native_table_contract(
                'public.{table_name}'::regclass,
                ARRAY[{publication}]
            )
            ",
            publication = sql_literal(&publication_name)
        ))
        .unwrap()
        .unwrap();

        assert_eq!(contract, "id,kept;full;true;true;true;true;true;true");
    }

    #[pg_test]
    fn native_contract_skips_incompatible_column_lists() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let table_name = identifier(&format!("native_column_conflict_{backend_pid}"));
        let first_publication = identifier(&format!("pgl_validate_native_cols_a_{backend_pid}"));
        let second_publication = identifier(&format!("pgl_validate_native_cols_b_{backend_pid}"));

        Spi::run(&format!(
            "
            CREATE TABLE public.{table_name}(
                id int PRIMARY KEY,
                kept_a text,
                kept_b text
            );
            CREATE PUBLICATION {first_publication}
            FOR TABLE public.{table_name} (id, kept_a);
            CREATE PUBLICATION {second_publication}
            FOR TABLE public.{table_name} (id, kept_b);
            "
        ))
        .unwrap();

        let contract = Spi::get_one::<String>(&format!(
            "
            SELECT validated_property || ';' ||
                   exact_comparable::text || ';' ||
                   (reason LIKE '%incompatible column lists%')::text
            FROM pgl_validate.native_table_contract(
                'public.{table_name}'::regclass,
                ARRAY[{first_publication},{second_publication}]
            )
            ",
            first_publication = sql_literal(&first_publication),
            second_publication = sql_literal(&second_publication)
        ))
        .unwrap()
        .unwrap();

        assert_eq!(contract, "skipped;false;true");
    }

    #[pg_test]
    fn compare_table_uses_registered_remote_peer_match() {
        let dsn = local_dsn();
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let table_name = identifier(&format!("self_compare_target_{backend_pid}"));

        let _ = crate::transport::libpq::execute_command(
            &dsn,
            &format!("DROP TABLE IF EXISTS public.{table_name}"),
        );
        crate::transport::libpq::execute_command(
            &dsn,
            &format!(
                "CREATE TABLE public.{table_name}(id int PRIMARY KEY, value text);
                 INSERT INTO public.{table_name} VALUES (1, 'same');"
            ),
        )
        .unwrap();

        Spi::run(&format!(
            "INSERT INTO pgl_validate.peer(name, dsn, backend)
             VALUES ('self_peer', {}, 'native')",
            sql_literal(&dsn)
        ))
        .unwrap();

        let result_sql = format!(
            "SELECT (r).run_id::text || ';' || (r).verdict FROM (
                SELECT pgl_validate.compare_table(
                    {}::regclass,
                    NULL,
                    '{{\"paranoid_confirm\":true}}'::jsonb
                ) AS r
             ) s",
            sql_literal(&format!("public.{table_name}"))
        );
        let result = Spi::get_one::<String>(&result_sql).unwrap().unwrap();
        let (run_id, verdict) = result
            .split_once(';')
            .expect("compare_table result should include run id and verdict");
        assert_eq!(verdict, "match");

        let participants = Spi::get_one::<i64>(
            "SELECT count(*) FROM pgl_validate.run_participant WHERE node IN ('local', 'self_peer')",
        )
        .unwrap()
        .unwrap();
        assert_eq!(participants, 2);

        let confirmed_nodes = Spi::get_one::<i64>(&format!(
            "
            SELECT count(*)
            FROM pgl_validate.table_node_result
            WHERE run_id = {run_id}
              AND node IN ('local', 'self_peer')
              AND set_hash IS NOT NULL
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(confirmed_nodes, 2);
    }

    #[pg_test]
    fn compare_table_refuses_unfenced_pglogical_peer() {
        Spi::run(
            "
            CREATE TABLE unfenced_pglogical_peer(id int PRIMARY KEY, value text);
            INSERT INTO unfenced_pglogical_peer VALUES (1, 'same');
            INSERT INTO pgl_validate.peer(name, dsn, backend, subscription_name)
            VALUES ('pglogical_without_provider', 'dbname=' || current_database(), 'pglogical', 'sub');
            ",
        )
        .unwrap();

        Spi::run(
            r#"
            DO $$
            DECLARE
                rejected boolean := false;
            BEGIN
                BEGIN
                    PERFORM pgl_validate.compare_table('unfenced_pglogical_peer'::regclass);
                EXCEPTION WHEN others THEN
                    IF SQLERRM = 'options.provider_dsn is required when comparing pglogical peers' THEN
                        rejected := true;
                    ELSE
                        RAISE;
                    END IF;
                END;

                IF NOT rejected THEN
                    RAISE EXCEPTION 'expected compare_table to reject an unfenced pglogical peer';
                END IF;
            END
            $$;
            "#,
        )
        .unwrap();
    }

    #[pg_test]
    fn compare_table_reports_registered_remote_peer_difference() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let peer_db = identifier(&format!("pgl_validate_peer_{backend_pid}"));
        let table_name = identifier(&format!("remote_compare_target_{backend_pid}"));
        let local_dsn = local_dsn();
        let remote_dsn = peer_dsn(&peer_db);

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
        crate::transport::libpq::execute_command(&local_dsn, &format!("CREATE DATABASE {peer_db}"))
            .unwrap();
        crate::transport::libpq::execute_command(
            &remote_dsn,
            &format!(
                "CREATE EXTENSION pgl_validate;
                 CREATE TABLE public.{table_name}(id int PRIMARY KEY, value text);
                 INSERT INTO public.{table_name} VALUES
                     (1, 'remote'),
                     (2, 'remote-only');"
            ),
        )
        .unwrap();

        Spi::run(&format!(
            "CREATE TABLE public.{table_name}(id int PRIMARY KEY, value text);
             INSERT INTO public.{table_name} VALUES
                 (1, 'local'),
                 (3, 'local-only');
             INSERT INTO pgl_validate.peer(name, dsn, backend)
             VALUES ('remote_diff', {}, 'native');",
            sql_literal(&remote_dsn)
        ))
        .unwrap();

        let run_sql = format!(
            "SELECT (pgl_validate.compare_table({}::regclass)).run_id",
            sql_literal(&format!("public.{table_name}"))
        );
        let run_id = Spi::get_one::<i64>(&run_sql).unwrap().unwrap();

        let verdict = Spi::get_one::<String>(&format!(
            "SELECT verdict FROM pgl_validate.table_result WHERE run_id = {run_id}"
        ))
        .unwrap()
        .unwrap();
        assert_eq!(verdict, "differ");

        let remote_rows = Spi::get_one::<i64>(
            "SELECT n_rows FROM pgl_validate.table_node_result WHERE node = 'remote_diff'",
        )
        .unwrap()
        .unwrap();
        assert_eq!(remote_rows, 2);

        let root_chunk = Spi::get_one::<String>(&format!(
            "
            SELECT cr.state || ';' || count(cnr.*)::text
            FROM pgl_validate.chunk_result cr
            JOIN pgl_validate.chunk_node_result cnr
              USING (run_id, schema_name, table_name, chunk_id)
            WHERE cr.run_id = {run_id}
              AND cr.table_name = {table_name}
              AND cr.chunk_id = 1
            GROUP BY cr.state
            ",
            table_name = sql_literal(&table_name)
        ))
        .unwrap()
        .unwrap();
        assert_eq!(root_chunk, "divergent;2");

        let divergence_summary = Spi::get_one::<String>(&format!(
            "
            SELECT string_agg(classification || ':' || status, ',' ORDER BY classification)
            FROM pgl_validate.divergence
            WHERE run_id = {run_id}
              AND node = 'remote_diff'
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(
            divergence_summary,
            "differs:confirmed,extra_on:confirmed,missing_on:confirmed"
        );

        let tuple_values = Spi::get_one::<String>(&format!(
            "
            SELECT (d.tuple->'local'->>'value') || ';' || (d.tuple->'peer'->>'value')
            FROM pgl_validate.divergence d
            WHERE d.run_id = {run_id}
              AND d.classification = 'differs'
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(tuple_values, "local;remote");

        let repair_batch = Spi::get_one::<String>(&format!(
            "
            SELECT string_agg(stmt, E'\\n' ORDER BY stmt)
            FROM pgl_validate.generate_repair({run_id}, 'local') AS stmt
            "
        ))
        .unwrap()
        .unwrap();
        assert!(repair_batch.contains("/* target: 'remote_diff' */ UPDATE"));
        assert!(repair_batch.contains("/* target: 'remote_diff' */ INSERT"));
        assert!(repair_batch.contains("/* target: 'remote_diff' */ DELETE"));

        let repair_status = Spi::get_one::<String>(&format!(
            "
            SELECT repair_id::text || ';' || status
            FROM pgl_validate.apply_repair({run_id}, 'local', 'remote_diff', 'remote_diff')
            "
        ))
        .unwrap()
        .unwrap();
        let (repair_id, repair_status) = repair_status
            .split_once(';')
            .expect("repair status should include id");
        assert_eq!(repair_status, "revalidated");

        let repair_actions = Spi::get_one::<String>(&format!(
            "
            SELECT string_agg(action, ',' ORDER BY action)
            FROM pgl_validate.repair_result
            WHERE repair_id = {repair_id}
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(repair_actions, "delete,insert,update");

        let repaired_verdict_sql = format!(
            "SELECT (pgl_validate.compare_table({}::regclass)).verdict",
            sql_literal(&format!("public.{table_name}"))
        );
        let repaired_verdict = Spi::get_one::<String>(&repaired_verdict_sql)
            .unwrap()
            .unwrap();
        assert_eq!(repaired_verdict, "match");

        crate::transport::libpq::execute_command(
            &remote_dsn,
            &format!("INSERT INTO public.{table_name} VALUES (5, 'remote-added')"),
        )
        .unwrap();

        Spi::run(&format!(
            "
            UPDATE public.{table_name}
            SET value = 'local-stale'
            WHERE id = 1;
            INSERT INTO public.{table_name}
            VALUES (4, 'local-extra');
            "
        ))
        .unwrap();

        let local_drift_run_id = Spi::get_one::<i64>(&run_sql).unwrap().unwrap();
        let local_drift_verdict = Spi::get_one::<String>(&format!(
            "SELECT verdict FROM pgl_validate.table_result WHERE run_id = {local_drift_run_id}"
        ))
        .unwrap()
        .unwrap();
        assert_eq!(local_drift_verdict, "differ");

        let local_repair_status = Spi::get_one::<String>(&format!(
            "
            SELECT repair_id::text || ';' || status
            FROM pgl_validate.apply_repair(
                {local_drift_run_id},
                'remote_diff',
                'local',
                'local'
            )
            "
        ))
        .unwrap()
        .unwrap();
        let (local_repair_id, local_repair_status) = local_repair_status
            .split_once(';')
            .expect("local repair status should include id");
        assert_eq!(local_repair_status, "revalidated");

        let local_repair_actions = Spi::get_one::<String>(&format!(
            "
            SELECT string_agg(action || ':' || post_verdict, ',' ORDER BY action)
            FROM pgl_validate.repair_result
            WHERE repair_id = {local_repair_id}
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(
            local_repair_actions,
            "delete:match,insert:match,update:match"
        );

        let origin_reset =
            Spi::get_one::<bool>("SELECT NOT pg_replication_origin_session_is_setup()")
                .unwrap()
                .unwrap();
        assert!(origin_reset);

        let local_repaired_verdict = Spi::get_one::<String>(&repaired_verdict_sql)
            .unwrap()
            .unwrap();
        assert_eq!(local_repaired_verdict, "match");

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
    }

    #[pg_test]
    fn compare_table_records_keyless_contract_without_repair_rows() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let peer_db = identifier(&format!("pgl_validate_keyless_peer_{backend_pid}"));
        let table_name = identifier(&format!("remote_keyless_target_{backend_pid}"));
        let peer_name = identifier(&format!("remote_keyless_{backend_pid}"));
        let local_dsn = local_dsn();
        let remote_dsn = peer_dsn(&peer_db);

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
        crate::transport::libpq::execute_command(&local_dsn, &format!("CREATE DATABASE {peer_db}"))
            .unwrap();
        crate::transport::libpq::execute_command(
            &remote_dsn,
            &format!(
                "CREATE EXTENSION pgl_validate;
                 CREATE TABLE public.{table_name}(id int, value text);
                 INSERT INTO public.{table_name} VALUES
                     (1, 'same'),
                     (1, 'same'),
                     (2, 'same');"
            ),
        )
        .unwrap();

        Spi::run(&format!(
            "CREATE TABLE public.{table_name}(id int, value text);
             INSERT INTO public.{table_name} VALUES
                 (1, 'same'),
                 (1, 'same'),
                 (2, 'same');
             INSERT INTO pgl_validate.peer(name, dsn, backend)
             VALUES ({peer_name}, {remote_dsn}, 'native');",
            peer_name = sql_literal(&peer_name),
            remote_dsn = sql_literal(&remote_dsn)
        ))
        .unwrap();

        let run_sql = format!(
            "SELECT (pgl_validate.compare_table({}::regclass)).run_id",
            sql_literal(&format!("public.{table_name}"))
        );
        let match_run_id = Spi::get_one::<i64>(&run_sql).unwrap().unwrap();
        let match_contract = Spi::get_one::<String>(&format!(
            "
            SELECT tr.verdict || ';' ||
                   tp.validated_property || ';' ||
                   (tr.reason LIKE '%validated_property=keyless%')::text
            FROM pgl_validate.table_result tr
            JOIN pgl_validate.table_plan tp USING (run_id, schema_name, table_name)
            WHERE tr.run_id = {match_run_id}
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(match_contract, "match;keyless;true");

        crate::transport::libpq::execute_command(
            &remote_dsn,
            &format!(
                "UPDATE public.{table_name}
                 SET value = 'remote-drift'
                 WHERE id = 2"
            ),
        )
        .unwrap();

        let differ_run_id = Spi::get_one::<i64>(&run_sql).unwrap().unwrap();
        let differ_contract = Spi::get_one::<String>(&format!(
            "
            SELECT tr.verdict || ';' ||
                   tp.validated_property || ';' ||
                   (tr.reason LIKE '%whole-relation checksum/count differ%')::text || ';' ||
                   (SELECT count(*)::text
                    FROM pgl_validate.divergence d
                    WHERE d.run_id = tr.run_id) || ';' ||
                   (SELECT count(*)::text
                    FROM pgl_validate.generate_repair(tr.run_id, 'local'))
            FROM pgl_validate.table_result tr
            JOIN pgl_validate.table_plan tp USING (run_id, schema_name, table_name)
            WHERE tr.run_id = {differ_run_id}
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(differ_contract, "differ;keyless;true;0;0");

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
    }

    #[pg_test]
    fn compare_table_uses_native_publication_column_projection() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let peer_db = identifier(&format!(
            "pgl_validate_native_projection_peer_{backend_pid}"
        ));
        let table_name = identifier(&format!("native_projection_target_{backend_pid}"));
        let publication_name = identifier(&format!("pgl_validate_native_projection_{backend_pid}"));
        let local_dsn = local_dsn();
        let remote_dsn = peer_dsn(&peer_db);
        let options_json = format!(
            "'{{\"backend\":\"native\",\"publications\":[\"{publication_name}\"]}}'::jsonb"
        );

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
        crate::transport::libpq::execute_command(&local_dsn, &format!("CREATE DATABASE {peer_db}"))
            .unwrap();
        crate::transport::libpq::execute_command(
            &remote_dsn,
            &format!(
                "CREATE EXTENSION pgl_validate;
                 CREATE TABLE public.{table_name}(
                     id int PRIMARY KEY,
                     kept text,
                     ignored text
                 );
                 INSERT INTO public.{table_name}
                 VALUES (1, 'same', 'remote-only');"
            ),
        )
        .unwrap();

        Spi::run(&format!(
            "
            CREATE TABLE public.{table_name}(
                id int PRIMARY KEY,
                kept text,
                ignored text
            );
            INSERT INTO public.{table_name}
            VALUES (1, 'same', 'local-only');
            CREATE PUBLICATION {publication_name}
            FOR TABLE public.{table_name} (id, kept);
            INSERT INTO pgl_validate.peer(name, dsn, backend, replication_sets)
            VALUES ('remote_native_projection', {remote_dsn}, 'native', ARRAY[{publication}]);
            ",
            remote_dsn = sql_literal(&remote_dsn),
            publication = sql_literal(&publication_name)
        ))
        .unwrap();

        let run_id = Spi::get_one::<i64>(&format!(
            "
            SELECT (pgl_validate.compare_table(
                'public.{table_name}'::regclass,
                ARRAY['remote_native_projection'],
                {options_json}
            )).run_id
            "
        ))
        .unwrap()
        .unwrap();

        let plan = Spi::get_one::<String>(&format!(
            "
            SELECT tr.verdict || ';' ||
                   tp.validated_property || ';' ||
                   array_to_string(tp.att_list, ',')
            FROM pgl_validate.table_result tr
            JOIN pgl_validate.table_plan tp USING (run_id, schema_name, table_name)
            WHERE tr.run_id = {run_id}
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(plan, "match;full;id,kept");

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
    }

    #[pg_test]
    fn compare_table_confirms_native_filtered_presence_differences() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let peer_db = identifier(&format!("pgl_validate_native_filter_peer_{backend_pid}"));
        let table_name = identifier(&format!("native_filtered_target_{backend_pid}"));
        let publication_name = identifier(&format!("pgl_validate_native_filter_{backend_pid}"));
        let local_dsn = local_dsn();
        let remote_dsn = peer_dsn(&peer_db);
        let options_json = format!(
            "'{{\"backend\":\"native\",\"publications\":[\"{publication_name}\"]}}'::jsonb"
        );

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
        crate::transport::libpq::execute_command(&local_dsn, &format!("CREATE DATABASE {peer_db}"))
            .unwrap();
        crate::transport::libpq::execute_command(
            &remote_dsn,
            &format!(
                "CREATE EXTENSION pgl_validate;
                 CREATE TABLE public.{table_name}(id int PRIMARY KEY, kept text);
                 INSERT INTO public.{table_name} VALUES
                     (5, 'remote-extra-outside-filter'),
                     (11, 'same');"
            ),
        )
        .unwrap();

        Spi::run(&format!(
            "
            CREATE TABLE public.{table_name}(id int PRIMARY KEY, kept text);
            INSERT INTO public.{table_name} VALUES
                (5, 'local-outside-filter'),
                (11, 'same'),
                (12, 'local-filtered-missing');
            CREATE PUBLICATION {publication_name}
            FOR TABLE public.{table_name}
            WHERE (id > 10);
            INSERT INTO pgl_validate.peer(name, dsn, backend, replication_sets)
            VALUES ('remote_native_filtered', {remote_dsn}, 'native', ARRAY[{publication}]);
            ",
            remote_dsn = sql_literal(&remote_dsn),
            publication = sql_literal(&publication_name)
        ))
        .unwrap();

        let run_id = Spi::get_one::<i64>(&format!(
            "
            SELECT (pgl_validate.compare_table(
                'public.{table_name}'::regclass,
                ARRAY['remote_native_filtered'],
                {options_json}
            )).run_id
            "
        ))
        .unwrap()
        .unwrap();

        let divergence = Spi::get_one::<String>(&format!(
            "
            SELECT string_agg(classification || ':' || status, ',' ORDER BY classification)
            FROM pgl_validate.divergence
            WHERE run_id = {run_id}
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(divergence, "extra_on:confirmed,missing_on:confirmed");

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
    }

    #[pg_test]
    fn apply_repair_orders_inserts_by_foreign_key() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let peer_db = identifier(&format!("pgl_validate_fk_peer_{backend_pid}"));
        let parent_table = identifier(&format!("z_repair_parent_{backend_pid}"));
        let child_table = identifier(&format!("a_repair_child_{backend_pid}"));
        let local_dsn = local_dsn();
        let remote_dsn = peer_dsn(&peer_db);

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
        crate::transport::libpq::execute_command(&local_dsn, &format!("CREATE DATABASE {peer_db}"))
            .unwrap();
        crate::transport::libpq::execute_command(
            &remote_dsn,
            &format!(
                "CREATE EXTENSION pgl_validate;
                 CREATE TABLE public.{parent_table}(id int PRIMARY KEY, value text);
                 CREATE TABLE public.{child_table}(
                     id int PRIMARY KEY,
                     parent_id int NOT NULL REFERENCES public.{parent_table}(id),
                     value text
                 );"
            ),
        )
        .unwrap();

        Spi::run(&format!(
            "
            CREATE TABLE public.{parent_table}(id int PRIMARY KEY, value text);
            CREATE TABLE public.{child_table}(
                id int PRIMARY KEY,
                parent_id int NOT NULL REFERENCES public.{parent_table}(id),
                value text
            );
            INSERT INTO public.{parent_table} VALUES (1, 'parent');
            INSERT INTO public.{child_table} VALUES (10, 1, 'child');
            INSERT INTO pgl_validate.peer(name, dsn, backend)
            VALUES ('remote_fk', {remote_dsn}, 'native');
            ",
            remote_dsn = sql_literal(&remote_dsn)
        ))
        .unwrap();

        let run_id = Spi::get_one::<i64>(&format!(
            "
            SELECT pgl_validate.compare(
                ARRAY[
                    'public.{child_table}'::regclass,
                    'public.{parent_table}'::regclass
                ],
                peers => ARRAY['remote_fk']
            )
            "
        ))
        .unwrap()
        .unwrap();

        let repair_status = Spi::get_one::<String>(&format!(
            "
            SELECT repair_id::text || ';' || status
            FROM pgl_validate.apply_repair({run_id}, 'local', 'remote_fk', 'remote_fk')
            "
        ))
        .unwrap()
        .unwrap();
        let (repair_id, repair_status) = repair_status
            .split_once(';')
            .expect("FK repair status should include id");
        assert_eq!(repair_status, "revalidated");

        let repair_audit = Spi::get_one::<String>(&format!(
            "
            SELECT string_agg(table_name || ':' || action || ':' || post_verdict, ',' ORDER BY table_name)
            FROM pgl_validate.repair_result
            WHERE repair_id = {repair_id}
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(
            repair_audit,
            format!("{child_table}:insert:match,{parent_table}:insert:match")
        );

        let repaired_run_id = Spi::get_one::<i64>(&format!(
            "
            SELECT pgl_validate.compare(
                ARRAY[
                    'public.{child_table}'::regclass,
                    'public.{parent_table}'::regclass
                ],
                peers => ARRAY['remote_fk']
            )
            "
        ))
        .unwrap()
        .unwrap();
        let repaired_verdicts = Spi::get_one::<String>(&format!(
            "
            SELECT string_agg(verdict, ',' ORDER BY table_name)
            FROM pgl_validate.table_result
            WHERE run_id = {repaired_run_id}
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(repaired_verdicts, "match,match");

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
    }

    #[pg_test]
    fn fence_barrier_accepts_duplicate_tokens() {
        Spi::run(
            r#"
            INSERT INTO pgl_validate.fence_barrier(token)
            VALUES
                ('11111111-1111-1111-1111-111111111111'),
                ('11111111-1111-1111-1111-111111111111');
            "#,
        )
        .unwrap();

        let count = Spi::get_one::<i64>(
            "SELECT count(*) FROM pgl_validate.fence_barrier
             WHERE token = '11111111-1111-1111-1111-111111111111'",
        )
        .unwrap()
        .unwrap();
        assert_eq!(count, 2);
    }

    #[pg_test]
    fn fence_attempt_accepts_truthful_converged_status() {
        let run_id = Spi::get_one::<i64>(
            r#"
            WITH r AS (
                INSERT INTO pgl_validate.run(status) VALUES ('fencing')
                RETURNING run_id
            ), epoch AS (
                INSERT INTO pgl_validate.fence_epoch(run_id, epoch_seq)
                SELECT run_id, 1 FROM r
            ), edge AS (
                INSERT INTO pgl_validate.run_edge(
                    run_id, edge_id, provider_node, target_node, backend,
                    subscription, slot_name, origin_name, repsets)
                SELECT run_id, 1, 'a', 'b', 'pglogical', 'sub', 'slot', 'origin', ARRAY['default']
                FROM r
            ), fence AS (
                INSERT INTO pgl_validate.fence_edge(
                    run_id, epoch_seq, edge_id, fence_kind, barrier_token, barrier_end_lsn)
                SELECT run_id, 1, 1, 'barrier', '22222222-2222-2222-2222-222222222222', '0/20'
                FROM r
            )
            SELECT run_id FROM r;
            "#,
        )
        .unwrap()
        .unwrap();

        Spi::run(&format!(
            r#"
            INSERT INTO pgl_validate.fence_attempt(
                run_id, epoch_seq, edge_id, barrier_end_lsn, origin_progress_lsn, token_visible, status)
            VALUES ({run_id}, 1, 1, '0/20', '0/20', true, 'converged');
            "#,
        ))
        .unwrap();
    }

    #[pg_test(
        error = "new row for relation \"fence_attempt\" violates check constraint \"fence_attempt_converged_truth\""
    )]
    fn fence_attempt_rejects_untruthful_converged_status() {
        let run_id = Spi::get_one::<i64>(
            r#"
            WITH r AS (
                INSERT INTO pgl_validate.run(status) VALUES ('fencing')
                RETURNING run_id
            ), epoch AS (
                INSERT INTO pgl_validate.fence_epoch(run_id, epoch_seq)
                SELECT run_id, 1 FROM r
            ), edge AS (
                INSERT INTO pgl_validate.run_edge(
                    run_id, edge_id, provider_node, target_node, backend,
                    subscription, slot_name, origin_name, repsets)
                SELECT run_id, 1, 'a', 'b', 'pglogical', 'sub', 'slot', 'origin', ARRAY['default']
                FROM r
            ), fence AS (
                INSERT INTO pgl_validate.fence_edge(
                    run_id, epoch_seq, edge_id, fence_kind, barrier_token, barrier_end_lsn)
                SELECT run_id, 1, 1, 'barrier', '55555555-5555-5555-5555-555555555555', '0/20'
                FROM r
            )
            SELECT run_id FROM r;
            "#,
        )
        .unwrap()
        .unwrap();

        Spi::run(&format!(
            r#"
            INSERT INTO pgl_validate.fence_attempt(
                run_id, epoch_seq, edge_id, barrier_end_lsn, origin_progress_lsn, token_visible, status)
            VALUES ({run_id}, 1, 1, '0/20', '0/10', true, 'converged');
            "#,
        ))
        .unwrap();
    }

    #[pg_test]
    fn barrier_cleanup_protects_unfinished_runs() {
        Spi::run(
            r#"
            WITH r AS (
                INSERT INTO pgl_validate.run(status) VALUES ('running')
                RETURNING run_id
            ), epoch AS (
                INSERT INTO pgl_validate.fence_epoch(run_id, epoch_seq)
                SELECT run_id, 1 FROM r
            ), edge AS (
                INSERT INTO pgl_validate.run_edge(
                    run_id, edge_id, provider_node, target_node, backend,
                    subscription, slot_name, origin_name, repsets)
                SELECT run_id, 1, 'a', 'b', 'pglogical', 'sub', 'slot', 'origin', ARRAY['default']
                FROM r
            ), barrier_rows AS (
                INSERT INTO pgl_validate.fence_barrier(token, injected_at)
                VALUES
                    ('33333333-3333-3333-3333-333333333333', now() - interval '2 hours'),
                    ('44444444-4444-4444-4444-444444444444', now() - interval '2 hours')
            )
            INSERT INTO pgl_validate.fence_barrier_run(
                token, run_id, epoch_seq, edge_id, origin_node, barrier_end_lsn)
            SELECT '33333333-3333-3333-3333-333333333333', run_id, 1, 1, 'a', '0/20'
            FROM r;
            "#,
        )
        .unwrap();

        let deleted =
            Spi::get_one::<i64>("SELECT pgl_validate.cleanup_fence_barriers(interval '1 hour')")
                .unwrap()
                .unwrap();
        assert_eq!(deleted, 1);

        let protected_remaining = Spi::get_one::<bool>(
            "SELECT EXISTS (
                SELECT 1 FROM pgl_validate.fence_barrier
                WHERE token = '33333333-3333-3333-3333-333333333333'
             )",
        )
        .unwrap()
        .unwrap();
        let garbage_remaining = Spi::get_one::<bool>(
            "SELECT EXISTS (
                SELECT 1 FROM pgl_validate.fence_barrier
                WHERE token = '44444444-4444-4444-4444-444444444444'
             )",
        )
        .unwrap()
        .unwrap();

        assert!(protected_remaining);
        assert!(!garbage_remaining);
    }

    #[pg_test]
    fn run_control_transitions_only_active_runs() {
        let running_run = Spi::get_one::<i64>(
            "INSERT INTO pgl_validate.run(status) VALUES ('running') RETURNING run_id",
        )
        .unwrap()
        .unwrap();
        let completed_run = Spi::get_one::<i64>(
            "INSERT INTO pgl_validate.run(status, finished_at)
             VALUES ('completed', now() - interval '1 hour')
             RETURNING run_id",
        )
        .unwrap()
        .unwrap();

        let paused = Spi::get_one::<bool>(&format!("SELECT pgl_validate.pause({running_run})"))
            .unwrap()
            .unwrap();
        let resumed = Spi::get_one::<bool>(&format!("SELECT pgl_validate.resume({running_run})"))
            .unwrap()
            .unwrap();
        let canceled = Spi::get_one::<bool>(&format!("SELECT pgl_validate.cancel({running_run})"))
            .unwrap()
            .unwrap();
        let completed_pause =
            Spi::get_one::<bool>(&format!("SELECT pgl_validate.pause({completed_run})"))
                .unwrap()
                .unwrap();
        let final_state = Spi::get_one::<String>(&format!(
            "
            SELECT status || ';' || (finished_at IS NOT NULL)::text
            FROM pgl_validate.run
            WHERE run_id = {running_run}
            "
        ))
        .unwrap()
        .unwrap();

        assert!(paused);
        assert!(resumed);
        assert!(canceled);
        assert!(!completed_pause);
        assert_eq!(final_state, "canceled;true");
    }

    #[pg_test]
    fn purge_removes_terminal_runs_and_unprotected_barriers() {
        let active_run = Spi::get_one::<i64>(
            "INSERT INTO pgl_validate.run(status, started_at)
             VALUES ('running', now() - interval '2 days')
             RETURNING run_id",
        )
        .unwrap()
        .unwrap();
        let old_done = Spi::get_one::<i64>(
            "INSERT INTO pgl_validate.run(status, started_at, finished_at)
             VALUES ('completed', now() - interval '3 days', now() - interval '2 days')
             RETURNING run_id",
        )
        .unwrap()
        .unwrap();
        let recent_done = Spi::get_one::<i64>(
            "INSERT INTO pgl_validate.run(status, started_at, finished_at)
             VALUES ('completed', now() - interval '10 minutes', now() - interval '5 minutes')
             RETURNING run_id",
        )
        .unwrap()
        .unwrap();

        Spi::run(&format!(
            "
            INSERT INTO pgl_validate.fence_epoch(run_id, epoch_seq)
            VALUES ({active_run}, 1);
            INSERT INTO pgl_validate.run_edge(
                run_id, edge_id, provider_node, target_node, backend,
                subscription, slot_name, origin_name, repsets)
            VALUES ({active_run}, 1, 'a', 'b', 'pglogical', 'sub', 'slot', 'origin', ARRAY['default']);
            INSERT INTO pgl_validate.fence_barrier(token, injected_at)
            VALUES
                ('55555555-5555-5555-5555-555555555555', now() - interval '2 hours'),
                ('66666666-6666-6666-6666-666666666666', now() - interval '2 hours');
            INSERT INTO pgl_validate.fence_barrier_run(
                token, run_id, epoch_seq, edge_id, origin_node, barrier_end_lsn)
            VALUES ('55555555-5555-5555-5555-555555555555', {active_run}, 1, 1, 'a', '0/30');
            "
        ))
        .unwrap();

        let purged = Spi::get_one::<i64>("SELECT pgl_validate.purge(now() - interval '1 hour')")
            .unwrap()
            .unwrap();

        let outcome = Spi::get_one::<String>(&format!(
            "
            SELECT EXISTS (SELECT 1 FROM pgl_validate.run WHERE run_id = {old_done})::text || ';' ||
                   EXISTS (SELECT 1 FROM pgl_validate.run WHERE run_id = {recent_done})::text || ';' ||
                   EXISTS (SELECT 1 FROM pgl_validate.run WHERE run_id = {active_run})::text || ';' ||
                   EXISTS (
                       SELECT 1 FROM pgl_validate.fence_barrier
                       WHERE token = '55555555-5555-5555-5555-555555555555'
                   )::text || ';' ||
                   EXISTS (
                       SELECT 1 FROM pgl_validate.fence_barrier
                       WHERE token = '66666666-6666-6666-6666-666666666666'
                   )::text
            "
        ))
        .unwrap()
        .unwrap();

        assert_eq!(purged, 1);
        assert_eq!(outcome, "false;true;true;true;false");
    }

    #[pg_test]
    fn pglogical_accepts_insert_only_barrier_repset() {
        Spi::run(
            r#"
            CREATE EXTENSION pglogical;
            SELECT pglogical.create_node(
                'pgl_validate_test',
                'dbname=' || current_database()
            );
            SELECT pgl_validate.ensure_pglogical_barrier_repset();
            SELECT pgl_validate.ensure_pglogical_barrier_repset();
            "#,
        )
        .unwrap();

        let has_row_filter = Spi::get_one::<bool>(
            r#"
            SELECT has_row_filter
            FROM pglogical.show_repset_table_info(
                'pgl_validate.fence_barrier'::regclass,
                ARRAY['pgl_validate_barrier']
            )
            "#,
        )
        .unwrap()
        .unwrap();

        let att_count = Spi::get_one::<i32>(
            r#"
            SELECT cardinality(att_list)
            FROM pglogical.show_repset_table_info(
                'pgl_validate.fence_barrier'::regclass,
                ARRAY['pgl_validate_barrier']
            )
            "#,
        )
        .unwrap()
        .unwrap();

        assert!(!has_row_filter);
        assert_eq!(att_count, 3);
    }

    #[pg_test]
    fn pglogical_barrier_repset_rejects_extra_tables() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let table_name = identifier(&format!("pglogical_barrier_extra_{backend_pid}"));
        let node_name = identifier(&format!("pgl_validate_barrier_node_{backend_pid}"));

        Spi::run(&format!(
            "
            CREATE EXTENSION pglogical;
            SELECT pglogical.create_node({node}, 'dbname=' || current_database());
            CREATE TABLE public.{table_name}(id int PRIMARY KEY);
            SELECT pgl_validate.ensure_pglogical_barrier_repset();
            SELECT pglogical.replication_set_add_table(
                'pgl_validate_barrier',
                'public.{table_name}'::regclass,
                false
            );
            ",
            node = sql_literal(&node_name),
        ))
        .unwrap();

        Spi::run(
            r#"
            DO $$
            DECLARE
                rejected boolean := false;
            BEGIN
                BEGIN
                    PERFORM pgl_validate.ensure_pglogical_barrier_repset();
                EXCEPTION WHEN others THEN
                    IF SQLERRM = 'pglogical replication set pgl_validate_barrier must contain only pgl_validate.fence_barrier' THEN
                        rejected := true;
                    ELSE
                        RAISE;
                    END IF;
                END;

                IF NOT rejected THEN
                    RAISE EXCEPTION 'expected pgl_validate_barrier to reject extra tables';
                END IF;
            END
            $$;
            "#,
        )
        .unwrap();
    }

    #[pg_test]
    fn pglogical_contract_uses_effective_column_list_and_action_mask() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let table_name = identifier(&format!("pglogical_contract_cols_{backend_pid}"));
        let repset_name = identifier(&format!("pgl_validate_contract_cols_{backend_pid}"));
        let node_name = identifier(&format!("pgl_validate_contract_node_{backend_pid}"));

        Spi::run(&format!(
            "
            CREATE EXTENSION pglogical;
            SELECT pglogical.create_node({node}, 'dbname=' || current_database());
            CREATE TABLE public.{table_name}(
                id int PRIMARY KEY,
                kept text,
                ignored text
            );
            SELECT pglogical.create_replication_set({repset}, true, false, true, true);
            SELECT pglogical.replication_set_add_table(
                {repset},
                'public.{table_name}'::regclass,
                false,
                ARRAY['id','kept']
            );
            ",
            node = sql_literal(&node_name),
            repset = sql_literal(&repset_name)
        ))
        .unwrap();

        let contract_sql = format!(
            "
            SELECT array_to_string(att_list, ',') || ';' ||
                   validated_property || ';' ||
                   repl_update::text
            FROM pgl_validate.pglogical_table_contract(
                'public.{table_name}'::regclass,
                ARRAY[{repset}]
            )
            ",
            repset = sql_literal(&repset_name)
        );
        let contract = Spi::get_one::<String>(&contract_sql).unwrap().unwrap();

        assert_eq!(contract, "id,kept;keys_only;false");
    }

    #[pg_test]
    fn compare_expands_pglogical_repset_into_parent_run() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let peer_db = identifier(&format!("pgl_validate_repset_peer_{backend_pid}"));
        let first_table = identifier(&format!("pgl_validate_repset_a_{backend_pid}"));
        let second_table = identifier(&format!("pgl_validate_repset_b_{backend_pid}"));
        let sequence_name = identifier(&format!("pgl_validate_repset_seq_{backend_pid}"));
        let repset_name = identifier(&format!("pgl_validate_compare_repset_{backend_pid}"));
        let node_name = identifier(&format!("pgl_validate_compare_node_{backend_pid}"));
        let local_dsn = local_dsn();
        let remote_dsn = peer_dsn(&peer_db);

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
        crate::transport::libpq::execute_command(&local_dsn, &format!("CREATE DATABASE {peer_db}"))
            .unwrap();
        crate::transport::libpq::execute_command(
            &remote_dsn,
            &format!(
                "CREATE EXTENSION pgl_validate;
                 CREATE TABLE public.{first_table}(id int PRIMARY KEY, value text);
                 CREATE TABLE public.{second_table}(id int PRIMARY KEY, value text);
                 CREATE SEQUENCE public.{sequence_name} CACHE 5;
                 INSERT INTO public.{first_table} VALUES (1, 'same');
                 INSERT INTO public.{second_table} VALUES (1, 'same');
                 DO $$
                 BEGIN
                     PERFORM setval('public.{sequence_name}'::regclass, 12, true);
                 END
                 $$;"
            ),
        )
        .unwrap();

        Spi::run(&format!(
            "
            DELETE FROM pgl_validate.peer;
            CREATE EXTENSION pglogical;
            SELECT pglogical.create_node({node}, 'dbname=' || current_database());
            CREATE TABLE public.{first_table}(id int PRIMARY KEY, value text);
            CREATE TABLE public.{second_table}(id int PRIMARY KEY, value text);
            CREATE SEQUENCE public.{sequence_name} CACHE 5;
            INSERT INTO public.{first_table} VALUES (1, 'same');
            INSERT INTO public.{second_table} VALUES (1, 'same');
            SELECT setval('public.{sequence_name}'::regclass, 10, true);
            SELECT pglogical.create_replication_set({repset}, true, true, true, true);
            SELECT pglogical.replication_set_add_table(
                {repset},
                'public.{first_table}'::regclass,
                false
            );
            SELECT pglogical.replication_set_add_table(
                {repset},
                'public.{second_table}'::regclass,
                false
            );
            SELECT pglogical.replication_set_add_sequence(
                {repset},
                'public.{sequence_name}'::regclass,
                false
            );
            INSERT INTO pgl_validate.peer(name, dsn, backend)
            VALUES ('repset_peer', {remote_dsn}, 'native');
            ",
            node = sql_literal(&node_name),
            repset = sql_literal(&repset_name),
            remote_dsn = sql_literal(&remote_dsn)
        ))
        .unwrap();

        let run_id = Spi::get_one::<i64>(&format!(
            "
            SELECT pgl_validate.compare(
                NULL::regclass[],
                {repset},
                ARRAY['repset_peer'],
                NULL::text,
                '{{\"sequence_buffer_multiplier\":2}}'::jsonb
            )
            ",
            repset = sql_literal(&repset_name)
        ))
        .unwrap()
        .unwrap();

        let planned = Spi::get_one::<String>(&format!(
            "
            SELECT r.status || ';' ||
                   count(tp.*)::text || ';' ||
                   bool_and(tp.repsets = ARRAY[{repset}]::text[])::text || ';' ||
                   (SELECT count(*)::text
                    FROM pgl_validate.sequence_result sr
                    WHERE sr.run_id = r.run_id
                      AND sr.seq_name = {sequence_name}) || ';' ||
                   (SELECT bool_and(sr.verdict = 'match' AND sr.within_contract)::text
                    FROM pgl_validate.sequence_result sr
                    WHERE sr.run_id = r.run_id
                      AND sr.seq_name = {sequence_name})
            FROM pgl_validate.run r
            JOIN pgl_validate.table_plan tp ON tp.run_id = r.run_id
            WHERE r.run_id = {run_id}
            GROUP BY r.run_id, r.status
            ",
            repset = sql_literal(&repset_name),
            sequence_name = sql_literal(&sequence_name)
        ))
        .unwrap()
        .unwrap();
        assert_eq!(planned, "completed;2;true;1;true");

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
    }

    #[pg_test]
    fn pglogical_contract_deparses_exact_row_filter() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let table_name = identifier(&format!("pglogical_filter_contract_{backend_pid}"));
        let repset_name = identifier(&format!("pgl_validate_filter_contract_{backend_pid}"));
        let node_name = identifier(&format!("pgl_validate_filter_node_{backend_pid}"));

        Spi::run(&format!(
            "
            CREATE EXTENSION pglogical;
            SELECT pglogical.create_node({node}, 'dbname=' || current_database());
            CREATE TABLE public.{table_name}(
                id int PRIMARY KEY,
                kept text
            );
            SELECT pglogical.create_replication_set({repset}, true, true, true, true);
            SELECT pglogical.replication_set_add_table(
                {repset},
                'public.{table_name}'::regclass,
                false,
                NULL,
                'id > 0 AND lower(kept) = kept'
            );
            ",
            node = sql_literal(&node_name),
            repset = sql_literal(&repset_name)
        ))
        .unwrap();

        let contract_sql = format!(
            "
            SELECT validated_property || ';' ||
                   exact_comparable::text || ';' ||
                   row_filter_exact::text || ';' ||
                   (row_filter_sql IS NOT NULL)::text
            FROM pgl_validate.pglogical_table_contract(
                'public.{table_name}'::regclass,
                ARRAY[{repset}]
            )
            ",
            repset = sql_literal(&repset_name)
        );
        let contract = Spi::get_one::<String>(&contract_sql).unwrap().unwrap();

        assert_eq!(contract, "filtered_intersection;true;true;true");
    }

    #[pg_test]
    fn pglogical_contract_skips_session_sensitive_row_filter() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let table_name = identifier(&format!("pglogical_filter_session_{backend_pid}"));
        let repset_name = identifier(&format!("pgl_validate_filter_session_{backend_pid}"));
        let node_name = identifier(&format!("pgl_validate_filter_session_node_{backend_pid}"));

        Spi::run(&format!(
            "
            CREATE EXTENSION pglogical;
            SELECT pglogical.create_node({node}, 'dbname=' || current_database());
            CREATE TABLE public.{table_name}(id int PRIMARY KEY);
            SELECT pglogical.create_replication_set({repset}, true, true, true, true);
            SELECT pglogical.replication_set_add_table(
                {repset},
                'public.{table_name}'::regclass,
                false,
                NULL,
                'id > 0 AND current_user = current_user'
            );
            ",
            node = sql_literal(&node_name),
            repset = sql_literal(&repset_name)
        ))
        .unwrap();

        let contract_sql = format!(
            "
            SELECT validated_property || ';' ||
                   exact_comparable::text || ';' ||
                   row_filter_exact::text
            FROM pgl_validate.pglogical_table_contract(
                'public.{table_name}'::regclass,
                ARRAY[{repset}]
            )
            ",
            repset = sql_literal(&repset_name)
        );
        let contract = Spi::get_one::<String>(&contract_sql).unwrap().unwrap();

        assert_eq!(contract, "skipped;false;false");

        let run_id = Spi::get_one::<i64>(&format!(
            "
            SELECT (pgl_validate.compare_table(
                'public.{table_name}'::regclass,
                ARRAY[]::text[],
                jsonb_build_object('repsets', jsonb_build_array({repset}))
            )).run_id
            ",
            repset = sql_literal(&repset_name)
        ))
        .unwrap()
        .unwrap();
        let issue = Spi::get_one::<String>(&format!(
            "
            SELECT tr.verdict || ';' || si.issue_code
            FROM pgl_validate.table_result tr
            JOIN pgl_validate.schema_issue si
              ON si.run_id = tr.run_id
             AND si.schema_name = tr.schema_name
             AND si.table_name = tr.table_name
            WHERE tr.run_id = {run_id}
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(issue, "skipped;NONDETERMINISTIC_ROW_FILTER");
    }

    #[pg_test]
    fn compare_table_uses_pglogical_column_projection() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let peer_db = identifier(&format!("pgl_validate_contract_peer_{backend_pid}"));
        let table_name = identifier(&format!("pglogical_projection_target_{backend_pid}"));
        let repset_name = identifier(&format!("pgl_validate_projection_{backend_pid}"));
        let node_name = identifier(&format!("pgl_validate_projection_node_{backend_pid}"));
        let local_dsn = local_dsn();
        let remote_dsn = peer_dsn(&peer_db);

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
        crate::transport::libpq::execute_command(&local_dsn, &format!("CREATE DATABASE {peer_db}"))
            .unwrap();
        crate::transport::libpq::execute_command(
            &remote_dsn,
            &format!(
                "CREATE EXTENSION pgl_validate;
                 CREATE TABLE public.{table_name}(
                     id int PRIMARY KEY,
                     kept text,
                     ignored text
                 );
                 INSERT INTO public.{table_name} VALUES (1, 'same', 'remote-only');"
            ),
        )
        .unwrap();

        Spi::run(&format!(
            "
            CREATE EXTENSION pglogical;
            SELECT pglogical.create_node({node}, 'dbname=' || current_database());
            CREATE TABLE public.{table_name}(
                id int PRIMARY KEY,
                kept text,
                ignored text
            );
            INSERT INTO public.{table_name} VALUES (1, 'same', 'local-only');
            SELECT pglogical.create_replication_set({repset}, true, true, true, true);
            SELECT pglogical.replication_set_add_table(
                {repset},
                'public.{table_name}'::regclass,
                false,
                ARRAY['id','kept']
            );
            INSERT INTO pgl_validate.peer(name, dsn, backend, replication_sets)
            VALUES ('remote_projection', {remote_dsn}, 'native', ARRAY[{repset}]);
            ",
            node = sql_literal(&node_name),
            repset = sql_literal(&repset_name),
            remote_dsn = sql_literal(&remote_dsn)
        ))
        .unwrap();

        let verdict_sql = format!(
            "
            SELECT (pgl_validate.compare_table(
                'public.{table_name}'::regclass,
                ARRAY['remote_projection'],
                '{{\"repsets\":[{repset_json}]}}'::jsonb
            )).verdict
            ",
            repset_json = sql_literal(&repset_name).replace('\'', "\"")
        );
        let verdict = Spi::get_one::<String>(&verdict_sql).unwrap().unwrap();
        assert_eq!(verdict, "match");

        let planned_cols_sql = format!(
            "SELECT array_to_string(att_list, ',')
             FROM pgl_validate.table_plan
             WHERE table_name = {}
             ORDER BY run_id DESC
             LIMIT 1",
            sql_literal(&table_name)
        );
        let planned_cols = Spi::get_one::<String>(&planned_cols_sql).unwrap().unwrap();
        assert_eq!(planned_cols, "id,kept");

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
    }

    #[pg_test]
    fn compare_table_marks_filtered_presence_difference_advisory() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let peer_db = identifier(&format!("pgl_validate_filter_peer_{backend_pid}"));
        let table_name = identifier(&format!("pglogical_filtered_target_{backend_pid}"));
        let repset_name = identifier(&format!("pgl_validate_filtered_{backend_pid}"));
        let node_name = identifier(&format!("pgl_validate_filtered_node_{backend_pid}"));
        let local_dsn = local_dsn();
        let remote_dsn = peer_dsn(&peer_db);

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
        crate::transport::libpq::execute_command(&local_dsn, &format!("CREATE DATABASE {peer_db}"))
            .unwrap();
        crate::transport::libpq::execute_command(
            &remote_dsn,
            &format!(
                "CREATE EXTENSION pgl_validate;
                 CREATE TABLE public.{table_name}(
                     id int PRIMARY KEY,
                     include_row boolean NOT NULL,
                     value text
                 );
                 INSERT INTO public.{table_name} VALUES
                     (1, true, 'same');"
            ),
        )
        .unwrap();

        Spi::run(&format!(
            "
            CREATE EXTENSION pglogical;
            SELECT pglogical.create_node({node}, 'dbname=' || current_database());
            CREATE TABLE public.{table_name}(
                id int PRIMARY KEY,
                include_row boolean NOT NULL,
                value text
            );
            INSERT INTO public.{table_name} VALUES
                (1, true, 'same'),
                (6, true, 'entered-filter-locally');
            SELECT pglogical.create_replication_set({repset}, true, true, true, true);
            SELECT pglogical.replication_set_add_table(
                {repset},
                'public.{table_name}'::regclass,
                false,
                NULL,
                'include_row'
            );
            INSERT INTO pgl_validate.peer(name, dsn, backend, replication_sets)
            VALUES ('remote_filtered', {remote_dsn}, 'native', ARRAY[{repset}]);
            ",
            node = sql_literal(&node_name),
            repset = sql_literal(&repset_name),
            remote_dsn = sql_literal(&remote_dsn)
        ))
        .unwrap();

        let verdict_sql = format!(
            "
            SELECT (pgl_validate.compare_table(
                'public.{table_name}'::regclass,
                ARRAY['remote_filtered'],
                '{{\"repsets\":[{repset_json}]}}'::jsonb
            )).verdict
            ",
            repset_json = sql_literal(&repset_name).replace('\'', "\"")
        );
        let verdict = Spi::get_one::<String>(&verdict_sql).unwrap().unwrap();
        assert_eq!(verdict, "match");

        let divergence_sql = format!(
            "
            SELECT classification || ';' || status || ';' || node
            FROM pgl_validate.divergence
            WHERE table_name = {table_name_lit}
            ORDER BY detected_at DESC
            LIMIT 1
            ",
            table_name_lit = sql_literal(&table_name)
        );
        let divergence = Spi::get_one::<String>(&divergence_sql).unwrap().unwrap();
        assert_eq!(divergence, "missing_on;advisory;remote_filtered");

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
    }

    #[pg_test]
    fn compare_sequence_applies_pglogical_buffer_window() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let peer_db = identifier(&format!("pgl_validate_sequence_peer_{backend_pid}"));
        let sequence_name = identifier(&format!("pgl_validate_sequence_{backend_pid}"));
        let local_dsn = local_dsn();
        let remote_dsn = peer_dsn(&peer_db);

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
        crate::transport::libpq::execute_command(&local_dsn, &format!("CREATE DATABASE {peer_db}"))
            .unwrap();
        crate::transport::libpq::execute_command(
            &remote_dsn,
            &format!(
                "CREATE EXTENSION pgl_validate;
                 CREATE SEQUENCE public.{sequence_name} CACHE 5;
                 DO $$
                 BEGIN
                     PERFORM setval('public.{sequence_name}'::regclass, 12, true);
                 END
                 $$;"
            ),
        )
        .unwrap();

        Spi::run(&format!(
            "
            CREATE SEQUENCE public.{sequence_name} CACHE 5;
            SELECT setval('public.{sequence_name}'::regclass, 10, true);
            INSERT INTO pgl_validate.peer(name, dsn, backend)
            VALUES ('remote_sequence', {remote_dsn}, 'native');
            ",
            remote_dsn = sql_literal(&remote_dsn)
        ))
        .unwrap();

        let compare_sql = format!(
            "
            SELECT verdict || ';' || within_contract::text
            FROM pgl_validate.compare_sequence(
                'public.{sequence_name}'::regclass,
                ARRAY['remote_sequence'],
                '{{\"sequence_buffer_multiplier\":2}}'::jsonb
            )
            "
        );
        let matched = Spi::get_one::<String>(&compare_sql).unwrap().unwrap();
        assert_eq!(matched, "match;true");

        crate::transport::libpq::execute_command(
            &remote_dsn,
            &format!(
                "DO $$
                 BEGIN
                     PERFORM setval('public.{sequence_name}'::regclass, 9, true);
                 END
                 $$;"
            ),
        )
        .unwrap();
        let behind_sql = format!(
            "
            SELECT run_id::text || ';' || verdict || ';' || within_contract::text
            FROM pgl_validate.compare_sequence(
                'public.{sequence_name}'::regclass,
                ARRAY['remote_sequence'],
                '{{\"sequence_buffer_multiplier\":2}}'::jsonb
            )
            "
        );
        let behind = Spi::get_one::<String>(&behind_sql).unwrap().unwrap();
        let (behind_run_id, behind_result) = behind
            .split_once(';')
            .expect("sequence result should include run id");
        assert_eq!(behind_result, "behind;false");

        let sequence_repair = Spi::get_one::<String>(&format!(
            "
            SELECT string_agg(stmt, E'\\n' ORDER BY stmt)
            FROM pgl_validate.generate_repair({behind_run_id}::bigint, 'local') AS stmt
            "
        ))
        .unwrap()
        .unwrap();
        assert!(
            sequence_repair.contains("/* target: 'remote_sequence' */ DO $pgl_validate_repair$")
        );
        assert!(sequence_repair.contains(", 10, true)"));

        let repair_status = Spi::get_one::<String>(&format!(
            "
            SELECT repair_id::text || ';' || status
            FROM pgl_validate.apply_repair(
                {behind_run_id}::bigint,
                'local',
                'remote_sequence',
                'remote_sequence'
            )
            "
        ))
        .unwrap()
        .unwrap();
        let (repair_id, repair_status) = repair_status
            .split_once(';')
            .expect("sequence repair status should include id");
        assert_eq!(repair_status, "revalidated");

        let sequence_repair_action = Spi::get_one::<String>(&format!(
            "
            SELECT action || ':' || post_verdict
            FROM pgl_validate.repair_result
            WHERE repair_id = {repair_id}
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(sequence_repair_action, "setval:match");

        let repaired_sequence = Spi::get_one::<String>(&compare_sql).unwrap().unwrap();
        assert_eq!(repaired_sequence, "match;true");

        crate::transport::libpq::execute_command(
            &remote_dsn,
            &format!(
                "DO $$
                 BEGIN
                     PERFORM setval('public.{sequence_name}'::regclass, 9, true);
                 END
                 $$;"
            ),
        )
        .unwrap();
        let behind = Spi::get_one::<String>(&compare_sql).unwrap().unwrap();
        assert_eq!(behind, "behind;false");

        crate::transport::libpq::execute_command(
            &remote_dsn,
            &format!(
                "DO $$
                 BEGIN
                     PERFORM setval('public.{sequence_name}'::regclass, 21, true);
                 END
                 $$;"
            ),
        )
        .unwrap();
        let ahead = Spi::get_one::<String>(&compare_sql).unwrap().unwrap();
        assert_eq!(ahead, "ahead_of_window;false");

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
    }

    #[pg_test]
    fn conflict_history_correlation_attaches_key_evidence() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let peer_db = identifier(&format!("pgl_validate_conflict_peer_{backend_pid}"));
        let table_name = identifier(&format!("pgl_validate_conflict_{backend_pid}"));
        let local_dsn = local_dsn();
        let remote_dsn = peer_dsn(&peer_db);

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
        crate::transport::libpq::execute_command(&local_dsn, &format!("CREATE DATABASE {peer_db}"))
            .unwrap();
        crate::transport::libpq::execute_command(
            &remote_dsn,
            &format!(
                "
                CREATE SCHEMA pglogical;
                CREATE TABLE pglogical.conflict_history (
                    id bigserial,
                    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
                    sub_id oid NOT NULL,
                    sub_name name,
                    conflict_type text NOT NULL,
                    resolution text NOT NULL,
                    schema_name name NOT NULL,
                    table_name name NOT NULL,
                    index_name name,
                    local_tuple jsonb,
                    local_xid xid,
                    local_origin integer,
                    local_commit_ts timestamptz,
                    remote_tuple jsonb,
                    remote_origin integer NOT NULL,
                    remote_commit_ts timestamptz NOT NULL,
                    remote_commit_lsn pg_lsn NOT NULL,
                    has_before_triggers boolean NOT NULL DEFAULT false
                );
                INSERT INTO pglogical.conflict_history(
                    recorded_at, sub_id, sub_name, conflict_type, resolution,
                    schema_name, table_name, index_name, local_tuple, remote_tuple,
                    remote_origin, remote_commit_ts, remote_commit_lsn
                )
                VALUES
                    (
                        now(), '1'::oid, 'sub', 'update_update', 'keep_local',
                        'public', {table_name}, {index_name},
                        '{{\"id\": 1, \"value\": \"local\"}}'::jsonb,
                        '{{\"id\": 1, \"value\": \"remote\"}}'::jsonb,
                        1, now(), '0/16B6C50'::pg_lsn
                    ),
                    (
                        now(), '1'::oid, 'sub', 'update_update', 'keep_local',
                        'public', {table_name}, {index_name},
                        '{{\"id\": 2, \"value\": \"local\"}}'::jsonb,
                        '{{\"id\": 2, \"value\": \"remote\"}}'::jsonb,
                        1, now(), '0/16B6C60'::pg_lsn
                    );
                ",
                table_name = sql_literal(&table_name),
                index_name = sql_literal(&format!("{table_name}_pkey"))
            ),
        )
        .unwrap();

        Spi::run(&format!(
            "
            CREATE TABLE public.{table_name}(id int PRIMARY KEY, value text);
            INSERT INTO pgl_validate.peer(name, dsn, backend, subscription_name)
            VALUES ('target_history', {remote_dsn}, 'pglogical', 'sub');
            ",
            remote_dsn = sql_literal(&remote_dsn)
        ))
        .unwrap();

        let fetched_conflicts = Spi::get_one::<i64>(&format!(
            "
            SELECT count(*)
            FROM pgl_validate.remote_pglogical_conflict_history(
                {remote_dsn},
                'sub',
                'public',
                {table_name},
                (now() - interval '24 hours')::text,
                10
            )
            ",
            remote_dsn = sql_literal(&remote_dsn),
            table_name = sql_literal(&table_name)
        ))
        .unwrap()
        .unwrap();
        assert_eq!(fetched_conflicts, 2);

        let run_id = Spi::get_one::<i64>(&format!(
            "
            WITH run AS (
                INSERT INTO pgl_validate.run(status, started_at)
                VALUES ('completed', now() - interval '1 hour')
                RETURNING run_id
            ), epoch AS (
                INSERT INTO pgl_validate.fence_epoch(run_id, epoch_seq)
                SELECT run_id, 1 FROM run
                RETURNING run_id
            ), plan AS (
                INSERT INTO pgl_validate.table_plan(
                    run_id, schema_name, table_name, key_cols, att_list,
                    validated_property
                )
                SELECT run_id, 'public', {table_name}, ARRAY['id'], ARRAY['id','value'], 'full'
                FROM run
                RETURNING run_id
            ), divergence AS (
                INSERT INTO pgl_validate.divergence(
                    run_id, schema_name, table_name, key_text, key_bytes,
                    classification, node, status, detected_epoch, tuple
                )
                SELECT run_id, 'public', {table_name},
                       '{{\"id\": 1}}',
                       decode('01', 'hex'),
                       'differs',
                       'target_history',
                       'confirmed',
                       1,
                       '{{\"local\": {{\"id\": 1, \"value\": \"local\"}},
                          \"peer\": {{\"id\": 1, \"value\": \"remote\"}}}}'::jsonb
                FROM run
            )
            SELECT run_id
            FROM run
            ",
            table_name = sql_literal(&table_name)
        ))
        .unwrap()
        .unwrap();
        let evidence_count = Spi::get_one::<i64>(&format!(
            "SELECT pgl_validate.correlate_conflict_history({run_id}, interval '24 hours', 10)::bigint"
        ))
        .unwrap()
        .unwrap();
        assert_eq!(evidence_count, 1);

        let evidence = Spi::get_one::<String>(&format!(
            "
            SELECT count(*)::text || ';' ||
                   min(conflict_type) || ';' ||
                   min(resolution) || ';' ||
                   bool_or('local_tuple_key' = ANY(matched_on))::text || ';' ||
                   bool_or('remote_tuple_key' = ANY(matched_on))::text
            FROM pgl_validate.conflict_evidence({run_id})
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(evidence, "1;update_update;keep_local;true;true");

        let report_has_evidence = Spi::get_one::<bool>(&format!(
            "
            SELECT jsonb_array_length(
                pgl_validate.report({run_id})
                    -> 'tables' -> 0
                    -> 'divergences' -> 0
                    -> 'conflict_evidence'
            ) = 1
            "
        ))
        .unwrap()
        .unwrap();
        assert!(report_has_evidence);

        let _ = crate::transport::libpq::execute_command(
            &local_dsn,
            &format!("DROP DATABASE IF EXISTS {peer_db} WITH (FORCE)"),
        );
    }

    #[pg_test]
    fn report_and_metrics_include_validation_state() {
        let backend_pid = Spi::get_one::<i32>("SELECT pg_backend_pid()")
            .unwrap()
            .unwrap();
        let table_name = identifier(&format!("pgl_validate_report_{backend_pid}"));

        Spi::run(&format!(
            "
            CREATE TABLE public.{table_name}(id int PRIMARY KEY, value text);
            INSERT INTO public.{table_name} VALUES (1, 'same');
            "
        ))
        .unwrap();

        let run_id = Spi::get_one::<i64>(&format!(
            "
            SELECT (pgl_validate.compare_table('public.{table_name}'::regclass)).run_id
            "
        ))
        .unwrap()
        .unwrap();

        let report_shape = Spi::get_one::<String>(&format!(
            "
            WITH report AS (
                SELECT pgl_validate.report({run_id}) AS doc
            )
            SELECT concat_ws(
                ';',
                (doc ? 'run')::text,
                (doc ? 'tables')::text,
                (doc ? 'participants')::text,
                (doc ? 'fence')::text,
                jsonb_array_length(doc->'tables')::text,
                COALESCE(doc->'tables'->0->'result'->>'verdict', '<null>')
            )
            FROM report
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(report_shape, "true;true;true;true;1;match");

        let missing_report =
            Spi::get_one::<String>("SELECT pgl_validate.report(-9223372036854775808)->>'error'")
                .unwrap()
                .unwrap();
        assert_eq!(missing_report, "run not found");

        let metrics_ok = Spi::get_one::<bool>(
            "
            SELECT pgl_validate.metrics() ? 'runs'
               AND pgl_validate.metrics() ? 'tables'
               AND pgl_validate.metrics()->'tables'->'by_verdict' ? 'match'
            ",
        )
        .unwrap()
        .unwrap();
        assert!(metrics_ok);
    }
}

#[cfg(test)]
/// pgrx test-cluster hooks used by `cargo pgrx test`.
pub mod pg_test {
    /// Initialize per-test state before pgrx invokes a pg_test function.
    pub fn setup(_options: Vec<&str>) {}

    /// Return PostgreSQL settings required by pglogical-backed tests.
    pub fn postgresql_conf_options() -> Vec<&'static str> {
        vec![
            "shared_preload_libraries = 'pglogical'",
            "wal_level = logical",
            "max_worker_processes = 20",
            "max_replication_slots = 10",
            "max_wal_senders = 10",
        ]
    }
}
