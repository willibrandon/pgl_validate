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
    fn compare_table_uses_registered_remote_peer_match() {
        let dsn = local_dsn();
        Spi::run(&format!(
            "INSERT INTO pgl_validate.peer(name, dsn) VALUES ('self_peer', {})",
            sql_literal(&dsn)
        ))
        .unwrap();

        let verdict = Spi::get_one::<String>(
            "SELECT (pgl_validate.compare_table('pgl_validate.fence_barrier'::regclass)).verdict",
        )
        .unwrap()
        .unwrap();
        assert_eq!(verdict, "match");

        let participants = Spi::get_one::<i64>(
            "SELECT count(*) FROM pgl_validate.run_participant WHERE node IN ('local', 'self_peer')",
        )
        .unwrap()
        .unwrap();
        assert_eq!(participants, 2);
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
                 INSERT INTO public.{table_name} VALUES (1, 'remote');"
            ),
        )
        .unwrap();

        Spi::run(&format!(
            "CREATE TABLE public.{table_name}(id int PRIMARY KEY, value text);
             INSERT INTO public.{table_name} VALUES (1, 'local');
             INSERT INTO pgl_validate.peer(name, dsn) VALUES ('remote_diff', {});",
            sql_literal(&remote_dsn)
        ))
        .unwrap();

        let verdict_sql = format!(
            "SELECT (pgl_validate.compare_table({}::regclass)).verdict",
            sql_literal(&format!("public.{table_name}"))
        );
        let verdict = Spi::get_one::<String>(&verdict_sql).unwrap().unwrap();
        assert_eq!(verdict, "differ");

        let remote_rows = Spi::get_one::<i64>(
            "SELECT n_rows FROM pgl_validate.table_node_result WHERE node = 'remote_diff'",
        )
        .unwrap()
        .unwrap();
        assert_eq!(remote_rows, 1);

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
            SELECT pglogical.create_replication_set(
                'pgl_validate_barrier',
                true, false, false, false
            );
            SELECT pglogical.replication_set_add_table(
                'pgl_validate_barrier',
                'pgl_validate.fence_barrier'::regclass,
                false
            );
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
