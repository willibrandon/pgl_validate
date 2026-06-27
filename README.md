# pgl_validate

`pgl_validate` validates table contents across PostgreSQL replication
topologies. It is built for pglogical first, especially bidirectional
replication, and also supports native logical replication and physical
standbys.

The extension compares data only after a replication-aware fence proves the
right state is visible. That matters: a validator that cannot tell lag from
divergence is worse than noisy.

## Supported Scope

- PostgreSQL 15, 16, 17, and 18.
- pglogical validation, including bidirectional topologies.
- Native logical replication validation.
- Physical standby validation.
- Windows, Linux, and macOS builds.
- Release zip packages for each supported PostgreSQL major.
- Windows x64 MSI installers for each supported PostgreSQL major.

pglogical is mandatory, not optional. CI covers the Windows-capable pglogical
fork and vanilla upstream pglogical where upstream has a normal source-build
path. Fork-only queryable conflict history is used only as report enrichment;
validation does not depend on it.

## Quick Start

Install with pgrx against the PostgreSQL major you want to use:

```powershell
.\scripts\pgrx-vs.ps1 cargo pgrx install `
  --pg-config C:\path\to\pg_config.exe `
  --no-default-features `
  --features pg18
```

Then, in the target database:

```sql
CREATE EXTENSION pgl_validate;

SELECT *
FROM pgl_validate.compare_table('public.accounts'::regclass);
```

On Windows, run pgrx commands through `scripts\pgrx-vs.ps1` so bindgen sees
the Visual Studio C++ and Windows SDK headers.

## Development

Use Rust stable with `cargo-pgrx` 0.19.1.

```powershell
rustup default stable
cargo install --locked cargo-pgrx --version 0.19.1
```

Common checks:

```powershell
.\scripts\check-powershell.ps1
.\scripts\check-design-catalog-ddl.ps1
.\scripts\test-pgrx.ps1 -PgMajor 18
.\scripts\test-pglogical-fence.ps1 -PgMajor 18
```

Script details live in [scripts/README.md](scripts/README.md). The design
contract lives in [docs/design.md](docs/design.md).

## Releases

The first release line starts at `v0.1.0`.

Release packages are produced with `cargo pgrx package` through
`scripts/package-pgrx.ps1`. Windows MSI installers are produced with
`scripts/package-windows-msi.ps1`.

## License

MIT. See [LICENSE](LICENSE).
