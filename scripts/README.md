# Scripts

These scripts are the supported way to build, test, package, and clean local
`pgl_validate` development environments. They are PowerShell scripts intended
to run on Windows, Linux, and macOS.

On Windows, prefer running commands through `pgrx-vs.ps1`. It loads the Visual
Studio C++ environment before invoking Rust, pgrx, or PostgreSQL tools:

```powershell
.\scripts\pgrx-vs.ps1 cargo pgrx schema pg18 --no-default-features --features pg18
```

`pgrx-common.ps1` is a shared helper loaded by the setup, test, and packaging
scripts; invoke the task scripts directly rather than running it by hand.

## Setup

- `ci-setup.ps1` installs or initializes the selected PostgreSQL major for pgrx.
- `install-pglogical-release.ps1` installs pglogical for pglogical test and
  packaging jobs. It does not depend on a local pglogical clone.

## Tests

- `test-pgrx.ps1` runs the pgrx `#[pg_test]` suite and cleans pgrx test clusters.
- `test-pgrx-regress.ps1` runs the SQL regression suite.
- `test-pglogical-fence.ps1` runs the real pglogical multi-node harness.
- `test-pglogical-mixed-major.ps1` runs the pg15-to-pg18 mixed-major harness.
- `test-native-logical-fence.ps1` runs the native logical replication harness.
- `test-physical-standby-fence.ps1` runs the physical standby harness.
- `test-async-worker.ps1` runs async worker and scheduler smoke coverage.

Use `stop-pgrx-test-clusters.ps1 -RemoveData` when a local run is interrupted.

## Packaging

- `package-pgrx.ps1` builds the release zip from `cargo pgrx package`.
- `package-windows-msi.ps1` builds the Windows x64 MSI from the pgrx package
  directory using WiX v5. Use `-VerifyInstall` to run a silent per-user
  install/uninstall into a temporary PostgreSQL root; it refuses to run when
  the same PostgreSQL-major MSI is already installed.
- `check-release-version.ps1` verifies that a release tag matches `Cargo.toml`
  and `pgl_validate.control`.

Generated packages are written under `target` and are ignored by git.

## Design Checks

`check-design-catalog-ddl.ps1` verifies that Appendix A in `docs/design.md`
matches the authoritative catalog DDL in `sql/bootstrap/001_catalog.sql`.

`check-powershell.ps1` parses every script and runs PSScriptAnalyzer with
warnings treated as failures.
