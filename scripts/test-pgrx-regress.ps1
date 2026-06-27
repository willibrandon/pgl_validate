param(
    [ValidateSet(15, 16, 17, 18)]
    [int] $PgMajor = 18,

    [switch] $KeepData,

    [ValidateRange(1, 86400)]
    [int] $TimeoutSeconds = 300,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $CargoPgrxArgs = @()
)

$ErrorActionPreference = 'Stop'

$common = Join-Path $PSScriptRoot 'pgrx-common.ps1'
. $common

$root = Split-Path -Parent $PSScriptRoot
$databaseName = 'pgl_validate_regress'
$regressDirectory = Join-Path (Join-Path $root 'tests') 'pg_regress'
$launcherDirectory = Join-Path (Join-Path $root 'target') 'pg_regress-launcher'
$stopArgs = @{ Root = $root }
if (-not $KeepData) {
    $stopArgs.RemoveData = $true
}
if (-not $CargoPgrxArgs -or $CargoPgrxArgs.Count -eq 0) {
    $CargoPgrxArgs = @('--no-default-features', '--features', "pg$PgMajor")
}

function Stop-ProcessTree {
    param([int] $ProcessId)

    Stop-PglProcessTree -ProcessId $ProcessId
}

function Invoke-PglTimedProcess {
    param(
        [string] $FilePath,
        [string[]] $ArgumentList,
        [string] $WorkingDirectory = $root,
        [int] $Seconds = $TimeoutSeconds
    )

    $startArgs = @{
        FilePath = $FilePath
        ArgumentList = ($ArgumentList | ForEach-Object { ConvertTo-CommandLineArgument $_ }) -join ' '
        WorkingDirectory = $WorkingDirectory
        PassThru = $true
    }
    if (Test-PglWindows) {
        $startArgs.NoNewWindow = $true
    }

    $process = Start-Process @startArgs
    if (-not $process.WaitForExit($Seconds * 1000)) {
        Write-Warning "$FilePath exceeded ${Seconds}s; terminating the process tree."
        Stop-ProcessTree -ProcessId $process.Id
        return 124
    }

    $process.Refresh()
    return $process.ExitCode
}

function Remove-PglPgrxAutoConfSetting {
    <#
    .SYNOPSIS
        Removes a generated ALTER SYSTEM setting from the pgrx test cluster.
    #>
    param(
        [int] $PgMajor,
        [string] $Name
    )

    $dataDirectory = Join-Path (Get-PglPgrxHome) "data-$PgMajor"
    $autoConf = Join-Path $dataDirectory 'postgresql.auto.conf'
    if (-not (Test-Path -LiteralPath $autoConf)) {
        return
    }

    $lines = @(Get-Content -LiteralPath $autoConf)
    $pattern = "^\s*$([regex]::Escape($Name))\s*="
    $filtered = @($lines | Where-Object { $_ -notmatch $pattern })
    if ($filtered.Count -eq $lines.Count) {
        return
    }

    Set-Content -LiteralPath $autoConf -Value $filtered -Encoding ascii
}

function ConvertTo-CommandLineArgument {
    param([string] $Argument)

    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }

    return '"' + ($Argument -replace '"', '\"') + '"'
}

function Get-PglPgRegressPath {
    param([string] $PgConfig)

    $pgxs = & $PgConfig --pgxs
    if ($LASTEXITCODE -ne 0 -or -not $pgxs) {
        throw "pg_config failed to report --pgxs for $PgConfig."
    }

    $pgxsDirectory = Split-Path -Parent $pgxs
    $pgxsSourceDirectory = Split-Path -Parent $pgxsDirectory
    $pgRegress = Join-Path (Join-Path (Join-Path $pgxsSourceDirectory 'test') 'regress') 'pg_regress'
    if (Test-PglWindows) {
        $pgRegress = "$pgRegress.exe"
    }

    if (Test-Path -LiteralPath $pgRegress) {
        return (Resolve-Path -LiteralPath $pgRegress).Path
    }

    return Get-PglToolPath -PgConfig $PgConfig -Name 'pg_regress'
}

function New-PglRegressLauncher {
    param(
        [string] $PsqlPath,
        [string] $Directory
    )

    New-Item -ItemType Directory -Force -Path $Directory | Out-Null

    if (Test-PglWindows) {
        $sourcePath = Join-Path $Directory "pg_regress_launcher_pg$PgMajor.rs"
        $launcherPath = Join-Path $Directory "pg_regress_launcher_pg$PgMajor.exe"
        $source = @'
use std::env;
use std::ffi::OsString;
use std::process::{exit, Command};

fn main() {
    let Some(psql) = env::var_os("PGL_VALIDATE_REAL_PSQL") else {
        eprintln!("PGL_VALIDATE_REAL_PSQL is not set.");
        exit(2);
    };

    let mut args: Vec<OsString> = env::args_os().skip(2).collect();
    args.push(OsString::from("-v"));
    args.push(OsString::from("VERBOSITY=terse"));

    let status = match Command::new(psql).args(args).status() {
        Ok(status) => status,
        Err(error) => {
            eprintln!("failed to launch psql: {error}");
            exit(2);
        }
    };

    exit(status.code().unwrap_or(1));
}
'@
        Set-Content -LiteralPath $sourcePath -Value $source -Encoding ascii

        $rustc = Get-PglCommandSource -Name 'rustc'
        if (-not $rustc) {
            throw 'rustc was not found on PATH.'
        }

        $compileCommand = @()
        if ($env:PGL_VALIDATE_RUST_TOOLCHAIN) {
            $compileCommand += "+$env:PGL_VALIDATE_RUST_TOOLCHAIN"
        }
        $compileCommand += @($sourcePath, '-O', '-o', $launcherPath)
        $compileExit = Invoke-PglTimedProcess -FilePath $rustc -ArgumentList $compileCommand -Seconds 120
        if ($compileExit -ne 0) {
            throw "rustc failed to compile the pg_regress launcher with code $compileExit."
        }

        return (Resolve-Path -LiteralPath $launcherPath).Path
    }

    $launcherPath = Join-Path $Directory "pg_regress_launcher_pg$PgMajor.sh"
    $script = @'
#!/usr/bin/env sh
shift
exec "$PGL_VALIDATE_REAL_PSQL" "$@" -v VERBOSITY=terse
'@
    Set-Content -LiteralPath $launcherPath -Value $script -Encoding ascii
    $chmod = Get-PglCommandSource -Name 'chmod'
    if ($chmod) {
        & $chmod 700 $launcherPath
        if ($LASTEXITCODE -ne 0) {
            throw "chmod failed for $launcherPath."
        }
    }
    return (Resolve-Path -LiteralPath $launcherPath).Path
}

function Get-PglRegressTests {
    param([string] $Directory)

    $sqlDirectory = Join-Path $Directory 'sql'
    if (-not (Test-Path -LiteralPath $sqlDirectory)) {
        throw "pg_regress SQL directory was not found: $sqlDirectory"
    }

    $tests = Get-ChildItem -LiteralPath $sqlDirectory -Filter '*.sql' |
        Sort-Object Name |
        ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name) }
    if (-not $tests) {
        throw "No pg_regress SQL tests were found in $sqlDirectory."
    }

    $ordered = @()
    if ($tests -contains 'setup') {
        $ordered += 'setup'
    }
    $ordered += @($tests | Where-Object { $_ -ne 'setup' })

    return $ordered
}

function New-PglRegressSchedule {
    param(
        [string[]] $Tests,
        [string] $Directory
    )

    New-Item -ItemType Directory -Force -Path $Directory | Out-Null
    $schedulePath = Join-Path $Directory "pg_regress_schedule_pg$PgMajor"
    $schedule = $Tests | ForEach-Object { "test: $_" }
    Set-Content -LiteralPath $schedulePath -Value $schedule -Encoding ascii
    return (Resolve-Path -LiteralPath $schedulePath).Path
}

function Write-PglRegressDiffs {
    $diffsPath = Join-Path $regressDirectory 'regression.diffs'
    if (Test-Path -LiteralPath $diffsPath) {
        Write-Host ''
        Write-Host "----- regression.diffs -----"
        Get-Content -LiteralPath $diffsPath
        Write-Host "----- end regression.diffs -----"
    }
}

$exitCode = 0
$previousPath = $env:PATH
$pathWasAdjusted = $false
try {
    & (Join-Path $PSScriptRoot 'stop-pgrx-test-clusters.ps1') @stopArgs

    $runner = Join-Path $PSScriptRoot 'pgrx-vs.ps1'
    $powershell = Get-PglPowerShellExecutable
    Remove-PglPgrxAutoConfSetting -PgMajor $PgMajor -Name 'shared_preload_libraries'

    if (-not (Test-PglWindows)) {
        $regressCommand = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runner) +
            @('cargo', 'pgrx', 'regress', "pg$PgMajor", '--resetdb', '--psql-verbosity', 'terse') +
            $CargoPgrxArgs
        $exitCode = Invoke-PglTimedProcess -FilePath $powershell -ArgumentList $regressCommand
        if ($exitCode -ne 0) {
            Write-PglRegressDiffs
            throw "cargo pgrx regress exited with code $exitCode."
        }

        return
    }

    $pgConfig = Get-PglPgrxPgConfig -PgMajor $PgMajor
    $pgBin = Split-Path -Parent $pgConfig
    $pgLib = & $pgConfig --libdir
    if ($LASTEXITCODE -ne 0 -or -not $pgLib) {
        throw "pg_config failed to report --libdir for $pgConfig."
    }

    $pathEntries = @($pgBin, $pgLib) |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) } |
        ForEach-Object { (Resolve-Path -LiteralPath $_).Path }
    if ($pathEntries) {
        $env:PATH = ($pathEntries + @($env:PATH)) -join [IO.Path]::PathSeparator
        $pathWasAdjusted = $true
    }

    $pgRegress = Get-PglPgRegressPath -PgConfig $pgConfig
    $psql = Get-PglToolPath -PgConfig $pgConfig -Name 'psql'
    $dropdb = Get-PglToolPath -PgConfig $pgConfig -Name 'dropdb'
    $createdb = Get-PglToolPath -PgConfig $pgConfig -Name 'createdb'
    $port = 28800 + $PgMajor
    $launcher = New-PglRegressLauncher -PsqlPath $psql -Directory $launcherDirectory
    $tests = Get-PglRegressTests -Directory $regressDirectory
    $schedule = New-PglRegressSchedule -Tests $tests -Directory $launcherDirectory
    $databaseUser = [Environment]::UserName
    Remove-Item -LiteralPath Env:PGDATABASE -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Env:PGHOST -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Env:PGPORT -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Env:PGUSER -ErrorAction SilentlyContinue

    $initialStopCommand = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runner) +
        @('cargo', 'pgrx', 'stop', "pg$PgMajor")
    $exitCode = Invoke-PglTimedProcess -FilePath $powershell -ArgumentList $initialStopCommand -Seconds 60
    if ($exitCode -ne 0) {
        throw "cargo pgrx stop exited with code $exitCode."
    }

    $installCommand = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runner) +
        @('cargo', 'pgrx', 'install', '--pg-config', $pgConfig) +
        $CargoPgrxArgs
    $exitCode = Invoke-PglTimedProcess -FilePath $powershell -ArgumentList $installCommand
    if ($exitCode -ne 0) {
        throw "cargo pgrx install exited with code $exitCode."
    }

    $startCommand = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runner) +
        @('cargo', 'pgrx', 'start', "pg$PgMajor", '--postgresql-conf', 'client_min_messages=warning')
    $exitCode = Invoke-PglTimedProcess -FilePath $powershell -ArgumentList $startCommand
    if ($exitCode -ne 0) {
        throw "cargo pgrx start exited with code $exitCode."
    }

    $exitCode = Invoke-PglTimedProcess -FilePath $dropdb -ArgumentList @('--if-exists', '-h', 'localhost', '-p', "$port", '-U', $databaseUser, $databaseName) -Seconds 60
    if ($exitCode -ne 0) {
        throw "dropdb exited with code $exitCode."
    }

    $exitCode = Invoke-PglTimedProcess -FilePath $createdb -ArgumentList @('-h', 'localhost', '-p', "$port", '-U', $databaseUser, $databaseName) -Seconds 60
    if ($exitCode -ne 0) {
        throw "createdb exited with code $exitCode."
    }

    $env:PGL_VALIDATE_REAL_PSQL = $psql
    $regressArgs = @(
        '--host', 'localhost',
        '--port', "$port",
        '--user', $databaseUser,
        '--use-existing',
        "--dbname=$databaseName",
        "--inputdir=$regressDirectory",
        "--outputdir=$regressDirectory",
        "--launcher=$launcher",
        "--schedule=$schedule"
    )
    $exitCode = Invoke-PglTimedProcess -FilePath $pgRegress -ArgumentList $regressArgs -WorkingDirectory $regressDirectory
    if ($exitCode -ne 0) {
        Write-PglRegressDiffs
        throw "pg_regress exited with code $exitCode."
    }
}
catch {
    Write-Error $_
    if ($exitCode -eq 0) {
        $exitCode = 1
    }
}
finally {
    $stopCommand = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'pgrx-vs.ps1')) +
        @('cargo', 'pgrx', 'stop', "pg$PgMajor")
    Invoke-PglTimedProcess -FilePath (Get-PglPowerShellExecutable) -ArgumentList $stopCommand -Seconds 60 | Out-Null
    & (Join-Path $PSScriptRoot 'stop-pgrx-test-clusters.ps1') @stopArgs
    Remove-Item -LiteralPath Env:PGL_VALIDATE_REAL_PSQL -ErrorAction SilentlyContinue
    if ($pathWasAdjusted) {
        $env:PATH = $previousPath
    }
}

exit $exitCode
