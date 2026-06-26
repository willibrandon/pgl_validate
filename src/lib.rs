//! PostgreSQL extension entry points for `pgl_validate`.
//!
//! The Rust surface owns low-level digest primitives and pgrx bindings; the
//! SQL files own the catalog and coordinator-facing stored procedures.
#![deny(missing_docs)]

use pgrx::prelude::*;
use pgrx::{GucContext, GucFlags, GucRegistry, GucSetting};
use std::ffi::CString;

mod digest;
mod sql_api;
mod transport;
mod worker;

pgrx::pg_module_magic!(name, version);

extension_sql_file!(
    "../sql/bootstrap/001_catalog.sql",
    name = "bootstrap_catalog",
    bootstrap
);
extension_sql_file!(
    "../sql/bootstrap/010_contracts.sql",
    name = "bootstrap_contracts",
    requires = ["bootstrap_catalog"]
);
extension_sql_file!(
    "../sql/bootstrap/020_barriers.sql",
    name = "bootstrap_barriers",
    requires = ["bootstrap_contracts"]
);
extension_sql_file!(
    "../sql/bootstrap/030_fencing.sql",
    name = "bootstrap_fencing",
    requires = ["bootstrap_barriers"]
);
extension_sql_file!(
    "../sql/bootstrap/040_planning.sql",
    name = "bootstrap_planning",
    requires = ["bootstrap_fencing"]
);
extension_sql_file!(
    "../sql/bootstrap/050_compare.sql",
    name = "bootstrap_compare",
    requires = ["bootstrap_planning"]
);
extension_sql_file!(
    "../sql/bootstrap/060_repair.sql",
    name = "bootstrap_repair",
    requires = ["bootstrap_compare"]
);
extension_sql_file!(
    "../sql/bootstrap/070_reporting.sql",
    name = "bootstrap_reporting",
    requires = ["bootstrap_repair"]
);
extension_sql_file!(
    "../sql/bootstrap/080_fence_maintenance.sql",
    name = "bootstrap_fence_maintenance",
    requires = ["bootstrap_reporting"]
);
extension_sql_file!("../sql/comments.sql", name = "comments", finalize);

static PARANOID_CONFIRM: GucSetting<bool> = GucSetting::<bool>::new(false);
static PARANOID_CONFIRM_MAX_ROWS: GucSetting<i32> = GucSetting::<i32>::new(1000);
static HASH_ALGORITHM: GucSetting<Option<CString>> =
    GucSetting::<Option<CString>>::new(Some(c"blake3_256"));
static ALLOW_APPROXIMATE_FILTERS: GucSetting<bool> = GucSetting::<bool>::new(false);
static ALLOW_DEGRADED_FENCE: GucSetting<bool> = GucSetting::<bool>::new(false);
static CHUNK_TARGET_ROWS: GucSetting<i32> = GucSetting::<i32>::new(50000);
static CHUNK_MAX_DURATION: GucSetting<Option<CString>> =
    GucSetting::<Option<CString>>::new(Some(c"2s"));
static LOCALIZE_THRESHOLD: GucSetting<i32> = GucSetting::<i32>::new(1000);
static MAX_PARALLEL_CHUNKS: GucSetting<i32> = GucSetting::<i32>::new(4);
static RECHECK_PASSES: GucSetting<i32> = GucSetting::<i32>::new(3);
static MAX_SNAPSHOT_AGE: GucSetting<Option<CString>> =
    GucSetting::<Option<CString>>::new(Some(c"5min"));
static STATEMENT_TIMEOUT_PER_CHUNK: GucSetting<Option<CString>> =
    GucSetting::<Option<CString>>::new(Some(c"30s"));
static THROTTLE_MAX_LAG: GucSetting<Option<CString>> =
    GucSetting::<Option<CString>>::new(Some(c"off"));
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
        c"pgl_validate.paranoid_confirm_max_rows",
        c"Rows per paranoid set confirmation.",
        c"Bounds the sorted hash_digest_array input used for cryptographic clean-chunk confirmation.",
        &PARANOID_CONFIRM_MAX_ROWS,
        1,
        i32::MAX,
        GucContext::Userset,
        flags,
    );
    GucRegistry::define_string_guc(
        c"pgl_validate.hash_algorithm",
        c"Row digest hash algorithm.",
        c"Algorithm contract for row digests. Currently blake3_256 is implemented; other design algorithms are rejected until implemented.",
        &HASH_ALGORITHM,
        GucContext::Userset,
        flags,
    );
    GucRegistry::define_bool_guc(
        c"pgl_validate.allow_approximate_filters",
        c"Allow approximate row-filter diagnostics.",
        c"Permit explicit approximate validation of session-sensitive row filters; results are never exact.",
        &ALLOW_APPROXIMATE_FILTERS,
        GucContext::Userset,
        flags,
    );
    GucRegistry::define_bool_guc(
        c"pgl_validate.allow_degraded_fence",
        c"Allow degraded pglogical fences.",
        c"Permit explicit best-effort fencing when a pglogical edge cannot carry barrier tokens; results are never exact.",
        &ALLOW_DEGRADED_FENCE,
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
    GucRegistry::define_string_guc(
        c"pgl_validate.chunk_max_duration",
        c"Maximum planned chunk duration.",
        c"Design knob for adaptive split-and-retry chunk sizing. The current SQL engine validates the setting and records it in run options.",
        &CHUNK_MAX_DURATION,
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
        c"pgl_validate.max_parallel_chunks",
        c"Maximum parallel chunk workers.",
        c"Upper bound for concurrent chunk subtrees when the async fan-out executor schedules chunk work.",
        &MAX_PARALLEL_CHUNKS,
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
    GucRegistry::define_string_guc(
        c"pgl_validate.max_snapshot_age",
        c"Maximum validation snapshot age.",
        c"Design knob for refencing long-running table validation snapshots to bound vacuum impact.",
        &MAX_SNAPSHOT_AGE,
        GucContext::Userset,
        flags,
    );
    GucRegistry::define_string_guc(
        c"pgl_validate.statement_timeout_per_chunk",
        c"Statement timeout per checksum chunk.",
        c"Hard timeout applied to checksum and localization statements generated for a validation chunk.",
        &STATEMENT_TIMEOUT_PER_CHUNK,
        GucContext::Userset,
        flags,
    );
    GucRegistry::define_string_guc(
        c"pgl_validate.throttle_max_lag",
        c"Maximum tolerated replication lag before throttling.",
        c"Design knob for lag-aware validation throttling. Use off to disable lag throttling.",
        &THROTTLE_MAX_LAG,
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

#[cfg(any(test, feature = "pg_test"))]
mod pg_tests;

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
