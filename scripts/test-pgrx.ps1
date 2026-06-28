param(
    [ValidateSet(15, 16, 17, 18)]
    [int] $PgMajor = 18,

    [switch] $KeepData,

    [ValidateRange(1, 86400)]
    [int] $BuildTimeoutSeconds = 600,

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
    [CmdletBinding(SupportsShouldProcess)]
    param([int] $ProcessId)

    if (-not $PSCmdlet.ShouldProcess($MyInvocation.MyCommand.Name, 'Run')) {
        return
    }

    Stop-PglProcessTree -ProcessId $ProcessId
}

function Add-PglPgTestFeature {
    <#
    .SYNOPSIS
        Adds pgrx's pg_test feature to a cargo-compatible feature argument list.
    #>
    param([string[]] $Arguments)

    $updated = @()
    $sawFeatures = $false
    for ($index = 0; $index -lt $Arguments.Count; $index++) {
        $argument = $Arguments[$index]
        if ($argument -eq '--features' -and ($index + 1) -lt $Arguments.Count) {
            $sawFeatures = $true
            $features = $Arguments[$index + 1]
            if ($features -notmatch '(^|[,\s])pg_test([,\s]|$)') {
                $features = "$features pg_test"
            }
            $updated += @($argument, $features)
            $index++
            continue
        }

        if ($argument.StartsWith('--features=', [StringComparison]::Ordinal)) {
            $sawFeatures = $true
            $features = $argument.Substring('--features='.Length)
            if ($features -notmatch '(^|[,\s])pg_test([,\s]|$)') {
                $features = "$features pg_test"
            }
            $updated += "--features=$features"
            continue
        }

        $updated += $argument
    }

    if (-not $sawFeatures) {
        $updated += @('--features', "pg$PgMajor pg_test")
    }

    return $updated
}

function Invoke-PglTimedProcess {
    <#
    .SYNOPSIS
        Runs a child process with a bounded wall-clock timeout and process-tree cleanup.
    #>
    param(
        [string] $FilePath,
        [string[]] $ArgumentList,
        [string] $Context,
        [int] $Seconds
    )

    $startArgs = @{
        FilePath = $FilePath
        ArgumentList = ($ArgumentList | ForEach-Object { ConvertTo-CommandLineArgument $_ }) -join ' '
        WorkingDirectory = $root
        PassThru = $true
    }
    if (Test-PglWindows) {
        $startArgs.NoNewWindow = $true
    }

    $process = Start-Process @startArgs
    if (-not $process.WaitForExit($Seconds * 1000)) {
        Write-Output "$Context exceeded ${Seconds}s; stopping the process tree."
        Stop-ProcessTree -ProcessId $process.Id
        return 124
    }

    $process.Refresh()
    return $process.ExitCode
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
    $pgConfig = Get-PgrxPgConfig -PgMajor $PgMajor
    $extensionSql = Get-ExtensionSqlPath -Root $root -PgConfig $pgConfig
    Assert-PglogicalInstalled -PgConfig $pgConfig -PgMajor $PgMajor

    & $runner cargo pgrx schema "pg$PgMajor" --no-default-features --features "pg$PgMajor" --out $extensionSql
    if ($LASTEXITCODE -ne 0) {
        throw "cargo pgrx schema failed while preparing $extensionSql."
    }

    $powershell = Get-PglPowerShellExecutable
    $prebuildCargoArgs = Add-PglPgTestFeature -Arguments $CargoPgrxArgs
    $prebuildCommand = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runner) +
        @('cargo', 'test', '--lib', '--no-run') +
        $prebuildCargoArgs
    $exitCode = Invoke-PglTimedProcess `
        -FilePath $powershell `
        -ArgumentList $prebuildCommand `
        -Context "cargo test --no-run pg$PgMajor" `
        -Seconds $BuildTimeoutSeconds
    if ($exitCode -ne 0) {
        throw "cargo test --no-run pg$PgMajor exited with code $exitCode."
    }

    $testCommand = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runner) +
        @('cargo', 'pgrx', 'test', "pg$PgMajor") +
        $CargoPgrxArgs
    Push-Location $root
    try {
        & $powershell @testCommand
        $exitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
    if ($exitCode -ne 0) {
        throw "cargo pgrx test pg$PgMajor exited with code $exitCode."
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
