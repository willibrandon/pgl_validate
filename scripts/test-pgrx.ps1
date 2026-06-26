param(
    [ValidateSet(15, 16, 17, 18)]
    [int] $PgMajor = 18,

    [switch] $KeepData,

    [ValidateRange(1, 86400)]
    [int] $TimeoutSeconds = 900,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $CargoPgrxArgs = @()
)

$ErrorActionPreference = 'Stop'

$common = Join-Path $PSScriptRoot 'pgrx-common.ps1'
. $common

$root = Split-Path -Parent $PSScriptRoot
$stopArgs = @{ Root = $root }
if (-not $KeepData) {
    $stopArgs.RemoveData = $true
}
if (-not $CargoPgrxArgs -or $CargoPgrxArgs.Count -eq 0) {
    $CargoPgrxArgs = @('--no-default-features', '--features', "pg$PgMajor")
}

# pg_tests share one PostgreSQL cluster and several extension catalog tables.
# Running them in parallel makes catalog-visible repair and peer state flaky.
$env:RUST_TEST_THREADS = '1'

function Stop-ProcessTree {
    param([int] $ProcessId)

    Stop-PglProcessTree -ProcessId $ProcessId
}

function ConvertTo-CommandLineArgument {
    param([string] $Argument)

    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }

    return '"' + ($Argument -replace '"', '\"') + '"'
}

function Get-PgrxPgConfig {
    param(
        [string] $Root,
        [int] $PgMajor
    )

    return Get-PglPgrxPgConfig -PgMajor $PgMajor
}

function Get-ExtensionSqlPath {
    param(
        [string] $Root,
        [string] $PgConfig
    )

    return Get-PglExtensionSqlPath -Root $Root -PgConfig $PgConfig
}

function Assert-PglogicalInstalled {
    param(
        [string] $PgConfig,
        [int] $PgMajor
    )

    $pkglibDir = & $PgConfig --pkglibdir
    $sharedDir = & $PgConfig --sharedir
    $extensionDir = Join-Path $sharedDir 'extension'
    $controlPath = Join-Path $extensionDir 'pglogical.control'
    $library = Get-ChildItem -LiteralPath $pkglibDir -File -Filter 'pglogical*' -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in @('.dll', '.so', '.dylib') } |
        Select-Object -First 1

    if ((Test-Path -LiteralPath $controlPath) -and $library) {
        return
    }

    throw "pglogical is required for cargo pgrx test because pg_tests preload it. Run scripts\install-pglogical-release.ps1 -PgMajor $PgMajor before scripts\test-pgrx.ps1."
}

$exitCode = 0
try {
    & (Join-Path $PSScriptRoot 'stop-pgrx-test-clusters.ps1') @stopArgs

    $runner = Join-Path $PSScriptRoot 'pgrx-vs.ps1'
    $pgConfig = Get-PgrxPgConfig -Root $root -PgMajor $PgMajor
    $extensionSql = Get-ExtensionSqlPath -Root $root -PgConfig $pgConfig
    Assert-PglogicalInstalled -PgConfig $pgConfig -PgMajor $PgMajor

    & $runner cargo pgrx schema "pg$PgMajor" --no-default-features --features "pg$PgMajor" --out $extensionSql
    if ($LASTEXITCODE -ne 0) {
        throw "cargo pgrx schema failed while preparing $extensionSql."
    }

    $command = @('cargo', 'pgrx', 'test', "pg$PgMajor") + $CargoPgrxArgs
    $powershell = Get-PglPowerShellExecutable

    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runner) + $command
    $argumentLine = ($arguments | ForEach-Object { ConvertTo-CommandLineArgument $_ }) -join ' '
    $startArgs = @{
        FilePath = $powershell
        ArgumentList = $argumentLine
        PassThru = $true
    }
    if (Test-PglWindows) {
        $startArgs.NoNewWindow = $true
    }
    $process = Start-Process @startArgs

    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        Write-Warning "cargo pgrx test pg$PgMajor exceeded ${TimeoutSeconds}s; terminating the process tree and cleaning pgrx test clusters."
        Stop-ProcessTree -ProcessId $process.Id
        $exitCode = 124
    }
    else {
        $process.Refresh()
        $exitCode = $process.ExitCode
    }
}
catch {
    Write-Error $_
    $exitCode = 1
}
finally {
    & (Join-Path $PSScriptRoot 'stop-pgrx-test-clusters.ps1') @stopArgs
}

exit $exitCode
