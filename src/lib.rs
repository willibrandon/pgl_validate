//! PostgreSQL extension entry points for `pgl_validate`.
//!
//! The Rust surface owns low-level digest primitives and pgrx bindings; the
//! SQL files own the catalog and coordinator-facing stored procedures.
#![deny(missing_docs)]

use pgrx::prelude::*;

mod digest;
mod transport;

pgrx::pg_module_magic!(name, version);

extension_sql_file!("../sql/bootstrap.sql", name = "bootstrap", bootstrap);
extension_sql_file!("../sql/comments.sql", name = "comments", finalize);

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

        TableIterator::once((checksum.pg_version, checksum.n_rows, checksum.lthash))
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
        assert!(
            sql.contains("pgl_validate.row_digest('{2,1,1}'::int[], t.amount, t.id, t.status)")
        );
        assert!(!sql.contains("ARRAY[t."));
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
                   jsonb_array_length(pgl_validate.report(r.run_id)->'tables')::text
            FROM pgl_validate.run r
            JOIN pgl_validate.table_result tr ON tr.run_id = r.run_id
            WHERE r.run_id = {run_id}
            GROUP BY r.run_id, r.status, r.tables_total, r.tables_matched
            "
        ))
        .unwrap()
        .unwrap();
        assert_eq!(run_shape, "completed;2;2;2;2;2");

        let _ = crate::transport::libpq::execute_command(
            &dsn,
            &format!("DROP TABLE IF EXISTS public.{first_table}, public.{second_table}"),
        );
    }

    #[pg_test]
    fn remote_checksum_reads_over_libpq() {
        let dsn = local_dsn();
        let checksum_sql = "SELECT 7::bigint AS n_rows, decode('010203', 'hex') AS lthash";
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

        let verdict_sql = format!(
            "SELECT (pgl_validate.compare_table({}::regclass)).verdict",
            sql_literal(&format!("public.{table_name}"))
        );
        let verdict = Spi::get_one::<String>(&verdict_sql).unwrap().unwrap();
        assert_eq!(verdict, "match");

        let participants = Spi::get_one::<i64>(
            "SELECT count(*) FROM pgl_validate.run_participant WHERE node IN ('local', 'self_peer')",
        )
        .unwrap()
        .unwrap();
        assert_eq!(participants, 2);
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

        crate::transport::libpq::execute_command(&remote_dsn, &repair_batch).unwrap();

        let repaired_verdict_sql = format!(
            "SELECT (pgl_validate.compare_table({}::regclass)).verdict",
            sql_literal(&format!("public.{table_name}"))
        );
        let repaired_verdict = Spi::get_one::<String>(&repaired_verdict_sql)
            .unwrap()
            .unwrap();
        assert_eq!(repaired_verdict, "match");

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
        crate::transport::libpq::execute_command(&remote_dsn, &sequence_repair).unwrap();

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
