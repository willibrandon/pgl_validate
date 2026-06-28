# pgl_validate

`pgl_validate` is a PostgreSQL extension for validating table contents across
pglogical and PostgreSQL logical-replication topologies. The primary target is
bidirectional replication, where validation must distinguish real divergence
from replication lag, filtered replication contracts, and expected sequence
windows. Physical standbys are supported with a standby-specific fence.

## Supported Scope

- PostgreSQL 15, 16, 17, and 18.
- pglogical validation, including bidirectional topologies.
- Native logical replication validation.
- Physical standby validation.
- Windows, Linux, and macOS builds.
- Linux and macOS `.tar.gz` packages for each supported PostgreSQL major.
- Windows `.zip` packages for each supported PostgreSQL major.
- Windows x64 MSI installers for each supported PostgreSQL major.

pglogical support is first-class and release-gated. It is not a runtime
prerequisite for native logical replication or physical standby validation.
Full CI installs pglogical because the test suite exercises pglogical code
paths. Production installations need pglogical only on pglogical participants.

CI covers the Windows-capable pglogical fork and vanilla upstream pglogical
where upstream has a normal source-build path. Fork-only queryable conflict
history is used only as report enrichment; validation does not depend on it.

## Quick Start

Install with pgrx against the PostgreSQL major you want to use. Replace
`/path/to/pg_config` with the `pg_config` for that PostgreSQL installation:

```sh
cargo pgrx install \
  --pg-config /path/to/pg_config \
  --no-default-features \
  --features pg18
```

Then, in the target database:

```sql
CREATE EXTENSION pgl_validate;

SELECT *
FROM pgl_validate.compare_table('public.accounts'::regclass);
```

For pglogical validation, register the databases you want to compare. The
helper is safe to rerun.

```sql
SELECT *
FROM pgl_validate.register_pglogical_peer(
    p_peer_name => 'node_beta',
    p_peer_dsn  => 'host=localhost port=5432 dbname=db_beta user=postgres'
);

SELECT *
FROM pgl_validate.compare_table('public.accounts'::regclass, ARRAY['node_beta']);
```

Two pglogical nodes may live in separate databases on the same PostgreSQL
instance. The DSN still identifies the peer because `dbname` is part of the
endpoint.

On Windows, run the same command through `scripts\pgrx-vs.ps1` so bindgen sees
the Visual Studio C++ and Windows SDK headers.

## Development

Use Rust stable with `cargo-pgrx` 0.19.1.

```sh
rustup default stable
cargo install --locked cargo-pgrx --version 0.19.1
```

Common checks:

```sh
pwsh -NoProfile -File scripts/check-powershell.ps1
pwsh -NoProfile -File scripts/check-design-catalog-ddl.ps1
pwsh -NoProfile -File scripts/test-pgrx.ps1 -PgMajor 18
pwsh -NoProfile -File scripts/test-pglogical-fence.ps1 -PgMajor 18
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
