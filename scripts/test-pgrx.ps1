param(
    [ValidateSet(15, 16, 17, 18)]
    [int] $PgMajor = 18,

    [switch] $KeepData,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $CargoPgrxArgs = @()
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$stopArgs = @{ Root = $root }
if (-not $KeepData) {
    $stopArgs.RemoveData = $true
}

$exitCode = 0
try {
    & (Join-Path $PSScriptRoot 'stop-pgrx-test-clusters.ps1') @stopArgs

    $command = @('cargo', 'pgrx', 'test', "pg$PgMajor") + $CargoPgrxArgs
    & (Join-Path $PSScriptRoot 'pgrx-vs.ps1') @command
    $exitCode = $LASTEXITCODE
}
catch {
    Write-Error $_
    $exitCode = 1
}
finally {
    & (Join-Path $PSScriptRoot 'stop-pgrx-test-clusters.ps1') @stopArgs
}

exit $exitCode
