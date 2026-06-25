param(
    [string] $Root = (Split-Path -Parent $PSScriptRoot),
    [switch] $RemoveData
)

$ErrorActionPreference = 'Stop'

$workspace = (Resolve-Path -LiteralPath $Root).Path
$target = Join-Path $workspace 'target\test-pgdata'
$targetSlash = $target -replace '\\', '/'
$targetBackslash = $target -replace '/', '\'

$patterns = @(
    [regex]::Escape($targetSlash),
    [regex]::Escape($targetBackslash),
    'target[/\\]test-pgdata'
)

$processNames = @('postgres.exe', 'pg_ctl.exe', 'cmd.exe')
$procs = Get-CimInstance Win32_Process | Where-Object {
    $commandLine = $_.CommandLine
    ($_.Name -in $processNames) -and
    ($null -ne $commandLine) -and
    (($patterns | Where-Object { $commandLine -match $_ }).Count -gt 0)
}

foreach ($proc in $procs) {
    Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
}

if ($RemoveData -and (Test-Path -LiteralPath $target)) {
    $resolvedTarget = (Resolve-Path -LiteralPath $target).Path
    if (-not $resolvedTarget.StartsWith($workspace, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove path outside workspace: $resolvedTarget"
    }

    Remove-Item -LiteralPath $resolvedTarget -Recurse -Force
}
