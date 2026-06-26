param(
    [string] $Root = (Split-Path -Parent $PSScriptRoot),
    [switch] $RemoveData
)

$ErrorActionPreference = 'Stop'

$common = Join-Path $PSScriptRoot 'pgrx-common.ps1'
. $common

$workspace = (Resolve-Path -LiteralPath $Root).Path
$targetRoot = Join-Path $workspace 'target'
$configuredTargets = @(
    'test-pgdata',
    'pglogical-test-pgdata',
    'native-test-pgdata',
    'standby-primary-pgdata',
    'standby-replica-pgdata',
    'diag-pgdata'
) | ForEach-Object { Join-Path $targetRoot $_ }

function Assert-WorkspaceTargetPath {
    param([string] $Path)

    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    $targetRoot = Join-Path $workspace 'target'
    $resolvedTargetRoot = (Resolve-Path -LiteralPath $targetRoot -ErrorAction SilentlyContinue).Path
    if (-not $resolvedTargetRoot) {
        $resolvedTargetRoot = $targetRoot
    }

    if (-not $resolvedPath.StartsWith($resolvedTargetRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to operate on path outside workspace target directory: $resolvedPath"
    }

    return $resolvedPath
}

function Stop-ProcessTree {
    param([int] $ProcessId)

    Stop-PglProcessTree -ProcessId $ProcessId
}

function Get-DataDirectoryPid {
    param([string] $DataDirectory)

    $pidFile = Join-Path $DataDirectory 'postmaster.pid'
    if (-not (Test-Path -LiteralPath $pidFile)) {
        return $null
    }

    $firstLine = Get-Content -LiteralPath $pidFile -TotalCount 1 -ErrorAction SilentlyContinue
    $parsedPid = 0
    if ([int]::TryParse($firstLine, [ref] $parsedPid)) {
        return $parsedPid
    }

    return $null
}

function Get-DataDirectoryMajor {
    param([string] $DataDirectory)

    $versionFile = Join-Path $DataDirectory 'PG_VERSION'
    if (-not (Test-Path -LiteralPath $versionFile)) {
        return $null
    }

    $version = (Get-Content -LiteralPath $versionFile -TotalCount 1).Trim()
    if (-not $version) {
        return $null
    }

    return $version.Split('.')[0]
}

function Get-PgCtl {
    param([string] $DataDirectory)

    $major = Get-DataDirectoryMajor -DataDirectory $DataDirectory
    if ($major) {
        try {
            $pgConfig = Get-PglPgrxPgConfig -PgMajor ([int] $major)
            return Get-PglToolPath -PgConfig $pgConfig -Name 'pg_ctl'
        }
        catch {
        }
    }

    $fromPath = Get-PglCommandSource -Name 'pg_ctl'
    if ($fromPath) {
        return $fromPath
    }

    return $null
}

function Stop-DataDirectoryCluster {
    param([string] $DataDirectory)

    if (-not (Test-Path -LiteralPath $DataDirectory)) {
        return
    }

    $postmasterPid = Get-DataDirectoryPid -DataDirectory $DataDirectory
    $pgCtl = Get-PgCtl -DataDirectory $DataDirectory

    if ($pgCtl) {
        & $pgCtl stop -D $DataDirectory -m fast -w -t 30 2>$null
    }

    if ($postmasterPid -and (Get-Process -Id $postmasterPid -ErrorAction SilentlyContinue)) {
        Stop-ProcessTree -ProcessId $postmasterPid
    }
}

function Get-RepoClusterDataDirectories {
    $known = @($configuredTargets | Where-Object { Test-Path -LiteralPath $_ })

    $mixedMajorTargets = @()
    if (Test-Path -LiteralPath $targetRoot) {
        $mixedMajorTargets = Get-ChildItem -LiteralPath $targetRoot -Directory -Force -Filter 'pglogical-mixed-*-pg*' -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'PG_VERSION') } |
            ForEach-Object { $_.FullName }
    }

    $discovered = @()
    if (Test-Path -LiteralPath $targetRoot) {
        $discovered = Get-ChildItem -LiteralPath $targetRoot -Recurse -Force -File -Filter 'postmaster.pid' -ErrorAction SilentlyContinue |
            ForEach-Object {
                $dataDirectory = $_.Directory.FullName
                if (Test-Path -LiteralPath (Join-Path $dataDirectory 'PG_VERSION')) {
                    $dataDirectory
                }
            }
    }

    $allTargets = @()
    $allTargets += @($known)
    $allTargets += @($mixedMajorTargets)
    $allTargets += @($discovered)

    $allTargets |
        Where-Object { $_ } |
        ForEach-Object { Assert-WorkspaceTargetPath -Path $_ } |
        Sort-Object -Unique
}

$targets = Get-RepoClusterDataDirectories

foreach ($target in $targets) {
    Stop-DataDirectoryCluster -DataDirectory $target
}

$patterns = foreach ($target in $targets) {
    [regex]::Escape(($target -replace '\\', '/'))
    [regex]::Escape(($target -replace '/', '\'))
}
$patterns += @(
    'target[/\\]test-pgdata',
    'target[/\\]pglogical-test-pgdata',
    'target[/\\]pglogical-mixed-[^/\\]+-pg\d+',
    'target[/\\]native-test-pgdata',
    'target[/\\]standby-primary-pgdata',
    'target[/\\]standby-replica-pgdata',
    'target[/\\]diag-pgdata'
)

$processNames = if (Test-PglWindows) {
    @('postgres.exe', 'pg_ctl.exe', 'cmd.exe', 'psql.exe', 'initdb.exe', 'pg_basebackup.exe')
}
else {
    @('postgres', 'pg_ctl', 'psql', 'initdb', 'pg_basebackup')
}
$procs = Get-PglProcessInfo | Where-Object {
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
    $removalCandidates = @()
    $removalCandidates += @($configuredTargets)
    $removalCandidates += @($targets)

    $removalTargets = $removalCandidates |
        Where-Object { Test-Path -LiteralPath $_ } |
        ForEach-Object { Assert-WorkspaceTargetPath -Path $_ } |
        Sort-Object -Unique |
        Sort-Object Length

    foreach ($target in $removalTargets) {
        if (Test-Path -LiteralPath $target) {
            for ($attempt = 1; $attempt -le 20; $attempt++) {
                try {
                    Remove-Item -LiteralPath $target -Recurse -Force
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

$global:LASTEXITCODE = 0
