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

`scripts\test-pgrx.ps1` always stops repo-local pgrx test clusters in
`target\test-pgdata`, `target\pglogical-test-pgdata`, and
`target\diag-pgdata`, even when a pg_test fails.

pglogical is a required part of the test environment. Install the packaged
release into the target pgrx PostgreSQL; do not build from a local pglogical
checkout:

```powershell
.\scripts\install-pglogical-release.ps1 -PgMajor 18
```

If `cargo check` is launched by an editor, start that editor from a Visual
Studio developer shell, or use the checked-in VS Code workspace settings. They
route rust-analyzer flycheck through `scripts\pgrx-vs.ps1`, which loads the
Visual Studio C++ environment before running `cargo check`. The `crtdefs.h`
bindgen error means that environment is missing from the cargo process.

## Status

The repository is being built from the design outward. The current slice covers
catalog DDL, row digest framing, LtHash state, pglogical contract discovery,
edge-specific barrier fencing, pglogical row-filter intersection semantics,
sequence-window validation, multi-table and replication-set compare
orchestration, structured JSON reports, reviewable repair generation, audited
repair application, run-control and retention APIs, and fenced paths exercised
against a real pglogical subscription.
