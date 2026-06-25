param(
    [string] $Root = (Split-Path -Parent $PSScriptRoot),
    [switch] $RemoveData
)

$ErrorActionPreference = 'Stop'

$workspace = (Resolve-Path -LiteralPath $Root).Path
$targets = @(
    'target\test-pgdata',
    'target\pglogical-test-pgdata',
    'target\diag-pgdata'
) | ForEach-Object { Join-Path $workspace $_ }

$patterns = foreach ($target in $targets) {
    [regex]::Escape(($target -replace '\\', '/'))
    [regex]::Escape(($target -replace '/', '\'))
}
$patterns += @(
    'target[/\\]test-pgdata',
    'target[/\\]pglogical-test-pgdata',
    'target[/\\]diag-pgdata'
)

$processNames = @('postgres.exe', 'pg_ctl.exe', 'cmd.exe', 'psql.exe', 'initdb.exe')
$procs = Get-CimInstance Win32_Process | Where-Object {
    $commandLine = $_.CommandLine
    ($_.Name -in $processNames) -and
    ($null -ne $commandLine) -and
    (($patterns | Where-Object { $commandLine -match $_ }).Count -gt 0)
}

foreach ($proc in $procs) {
    Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
}

Start-Sleep -Milliseconds 500

if ($RemoveData) {
    foreach ($target in $targets) {
        if (Test-Path -LiteralPath $target) {
            $resolvedTarget = (Resolve-Path -LiteralPath $target).Path
            if (-not $resolvedTarget.StartsWith($workspace, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Refusing to remove path outside workspace: $resolvedTarget"
            }

            for ($attempt = 1; $attempt -le 20; $attempt++) {
                try {
                    Remove-Item -LiteralPath $resolvedTarget -Recurse -Force
                    break
                }
                catch {
                    if ($attempt -eq 20) {
                        throw
                    }

                    Start-Sleep -Milliseconds 500
                }
            }
        }
    }
}
