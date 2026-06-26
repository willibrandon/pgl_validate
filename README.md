# pgl_validate

`pgl_validate` is a PostgreSQL extension for validating table contents across
pglogical and logical-replication topologies. The primary target is
bidirectional replication, where validation must distinguish real divergence
from replication lag, filtered replication contracts, and expected sequence
windows.

The design is in [docs/design.md](docs/design.md). Implementation should keep
the database-facing contract exact: barrier-converged epochs, edge-specific
origin progress, planner-visible checksum SQL, and pglogical-aware validation
strength.

## Build

Use the same pgrx version as the crate:

```powershell
rustup default stable
cargo install --locked cargo-pgrx
```

The default target is PostgreSQL 18, the latest stable major. PostgreSQL 19 is
currently beta, so it is not the default build target.

On Windows, run pgrx commands from a Visual Studio developer environment so
bindgen can find the MSVC and Windows SDK headers:

```powershell
.\scripts\pgrx-vs.ps1 cargo pgrx schema --features pg18
```

For quick Rust-only feedback:

```powershell
.\scripts\pgrx-vs.ps1 cargo check --features pg18
.\scripts\pgrx-vs.ps1 cargo test --lib --features pg18
```

For extension validation, use pgrx:

```powershell
.\scripts\pgrx-vs.ps1 cargo pgrx schema --features pg18
.\scripts\test-pgrx.ps1
```

The scripts are PowerShell, but they are intended to run on Windows, Linux, and
macOS. On Windows, `scripts\pgrx-vs.ps1` loads the Visual Studio C++
environment; on other platforms it runs the command directly.

`scripts\test-pgrx.ps1` always stops repo-local pgrx test clusters in
`target\test-pgdata`, `target\pglogical-test-pgdata`,
`target\native-test-pgdata`, `target\standby-primary-pgdata`,
`target\standby-replica-pgdata`, and `target\diag-pgdata`, even when a pg_test
fails. It also runs pg_tests serially because they share one PostgreSQL cluster
and extension catalog state.

pglogical is a required part of the test environment. Install the packaged
release into the target pgrx PostgreSQL; do not build from a local pglogical
checkout. Repeat this for each PostgreSQL major you run locally:

```powershell
.\scripts\install-pglogical-release.ps1 -PgMajor 18
```

The installer verifies the release checksum and installs a packaged artifact
when one exists. If a package is not published for the host architecture, it
builds the source release against the selected `pg_config`.

CI runs PostgreSQL 15, 16, 17, and 18 across Linux x64/arm64, Windows x64,
Windows ARM64-hosted x64, and macOS ARM64 runners. Intel macOS is intentionally
excluded. Native Windows ARM64 PostgreSQL is not scheduled because PostgreSQL
15-18 do not ship a supported native Windows ARM64 CI build path here. The pgrx
pg_test and pglogical integration jobs install the fork release package or
source release for each target.

Native logical replication coverage uses PostgreSQL's built-in publication and
subscription machinery:

```powershell
.\scripts\test-native-logical-fence.ps1 -PgMajor 18
```

Physical standby coverage uses PostgreSQL streaming replication and validates
the replay-LSN fence path against a real read-only standby:

```powershell
.\scripts\test-physical-standby-fence.ps1 -PgMajor 18
```

If `cargo check` is launched by an editor, start that editor from a Visual
Studio developer shell, or use the checked-in VS Code workspace settings. They
route rust-analyzer flycheck through `scripts\pgrx-vs.ps1`, which loads the
Visual Studio C++ environment before running `cargo check`. The `crtdefs.h`
bindgen error means that environment is missing from the cargo process.

## Configuration

Per-run `options` override PostgreSQL settings. Implemented settings are:

```sql
SET pgl_validate.chunk_target_rows = 50000;
SET pgl_validate.localize_threshold = 1000;
SET pgl_validate.recheck_passes = 3;
SET pgl_validate.fence_timeout_ms = 300000;
SET pgl_validate.fence_poll_interval_ms = 100;
-- compare_table option: "on_fence_timeout": "abort_run" | "skip_peer"
SET pgl_validate.sequence_buffer_multiplier = 2;
SET pgl_validate.paranoid_confirm = off;
SET pgl_validate.paranoid_confirm_max_rows = 1000;
SET pgl_validate.max_reported_tuple_bytes = 8192;
SET pgl_validate.max_reported_divergences = 1000;
SET pgl_validate.hash_algorithm = 'blake3_256'; -- or blake3_512
SET pgl_validate.chunk_max_duration = '2s';
SET pgl_validate.max_parallel_chunks = 4;
SET pgl_validate.max_snapshot_age = '5min';
SET pgl_validate.statement_timeout_per_chunk = '30s';
SET pgl_validate.throttle_max_lag = 'off';
SET pgl_validate.allow_approximate_filters = off;
SET pgl_validate.allow_degraded_fence = off;
SET pgl_validate.correlate_conflict_history = on;
SET pgl_validate.conflict_history_max_rows = 1000;
```

For bidirectional pglogical validation, set `pgl_validate.peer.reverse_subscription_name`
to the local subscription that replicates from that peer back to the coordinator.

## Security

The extension installs four NOLOGIN tier roles: `pgl_validate_validate`,
`pgl_validate_discover`, `pgl_validate_orchestrate`, and `pgl_validate_repair`.
Default PUBLIC access is revoked. Grant the narrowest role to the operators or
service accounts that need it; ordinary table privileges are still required
because validation functions run as invoker.

## Status

The repository is being built from the design outward. The current slice covers
catalog DDL, row digest framing, LtHash state, pglogical contract discovery,
native publication contract discovery, native barrier fencing, cryptographic
set confirmation, edge-specific barrier fencing, pglogical row-filter
intersection semantics, bidirectional pglogical reverse-edge fencing,
physical-standby replay fence plumbing, sequence-window validation, keyless
whole-relation validation, multi-table and replication-set compare
orchestration, structured JSON reports, reviewable repair generation, audited
repair application, conflict-history evidence correlation, run-control and
retention APIs, durable schedule definitions with explicit async dispatch,
dynamic-worker async run orchestration with durable paused-task resume, and
fenced paths exercised against real pglogical, native logical, and physical
standby replication.
