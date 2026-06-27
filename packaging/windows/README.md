# Windows Packaging

The release workflow builds one MSI per supported PostgreSQL major for the
Windows x64 target.

The MSI installs:

- `lib\pgl_validate.dll`
- `share\extension\pgl_validate.control`
- `share\extension\pgl_validate--*.sql`

The installer looks for PostgreSQL in the standard registry locations used by
the Windows PostgreSQL installers. If detection fails, the UI lets the user
select the PostgreSQL root directory. A silent install can pass
`POSTGRESQLDIR=...`; explicit paths are honored before registry detection.

Each PostgreSQL major has a stable UpgradeCode, so `pgl_validate` can be
upgraded per major while pg15, pg16, pg17, and pg18 installers remain
side-by-side.

Install:

```powershell
msiexec /i pgl_validate-0.1.0-pg18-windows-x64.msi /qn /norestart
```

Silent installs must run from an elevated shell.

Install into an explicit PostgreSQL root:

```powershell
msiexec /i pgl_validate-0.1.0-pg18-windows-x64.msi `
  POSTGRESQLDIR="$env:USERPROFILE\.pgrx\18.4" `
  WIXUI_DONTSETPATH=1 ALLUSERS=1 `
  /qn /norestart
```
