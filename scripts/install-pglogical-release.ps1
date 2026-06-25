param(
    [ValidateSet('15', '16', '17', '18')]
    [string] $PgMajor = '18',

    [string] $Version = '2.5.3',

    [string] $PgConfig
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Find-PgConfig {
    param([string] $Major)

    $envName = "PG${Major}_PG_CONFIG"
    $envValue = [Environment]::GetEnvironmentVariable($envName)
    if ($envValue -and (Test-Path $envValue)) {
        return (Resolve-Path $envValue).Path
    }

    $configPath = Join-Path $env:USERPROFILE '.pgrx\config.toml'
    if (Test-Path $configPath) {
        $line = Get-Content $configPath |
            Where-Object { $_ -match "^\s*pg$Major\s*=\s*'([^']+)'" } |
            Select-Object -First 1
        if ($line -and $Matches[1] -and (Test-Path $Matches[1])) {
            return (Resolve-Path $Matches[1]).Path
        }
    }

    $candidate = Get-ChildItem -Path (Join-Path $env:USERPROFILE '.pgrx') `
            -Filter pg_config.exe -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match "\\$Major\.[^\\]+\\bin\\pg_config\.exe$" } |
        Sort-Object FullName -Descending |
        Select-Object -First 1
    if ($candidate) {
        return $candidate.FullName
    }

    $fromPath = Get-Command pg_config.exe -ErrorAction SilentlyContinue
    if ($fromPath) {
        $version = & $fromPath.Source --version
        if ($version -match "PostgreSQL\s+$Major\.") {
            return $fromPath.Source
        }
    }

    throw "Could not find pg_config for PostgreSQL $Major. Run cargo pgrx init --pg$Major download, or pass -PgConfig."
}

if (-not $PgConfig) {
    $PgConfig = Find-PgConfig -Major $PgMajor
}
$PgConfig = (Resolve-Path $PgConfig).Path

$pgVersion = & $PgConfig --version
if ($pgVersion -notmatch "PostgreSQL\s+$PgMajor\.") {
    throw "$PgConfig reports '$pgVersion', not PostgreSQL $PgMajor.x"
}

$asset = "pglogical-$Version-pg$PgMajor-windows-x64.zip"
$baseUri = "https://github.com/willibrandon/pglogical/releases/download/v$Version"
$workDir = Join-Path ([IO.Path]::GetTempPath()) "pgl_validate-pglogical-$([guid]::NewGuid())"
$zipPath = Join-Path $workDir $asset
$checksumsPath = Join-Path $workDir 'checksums.txt'
$extractDir = Join-Path $workDir 'extract'

New-Item -ItemType Directory -Path $workDir, $extractDir | Out-Null

try {
    Invoke-WebRequest -Uri "$baseUri/$asset" -OutFile $zipPath
    Invoke-WebRequest -Uri "$baseUri/checksums.txt" -OutFile $checksumsPath

    $checksumPattern = "([0-9a-fA-F]{64}).*$([regex]::Escape($asset))"
    $checksumLine = Get-Content $checksumsPath |
        Where-Object { $_ -match $checksumPattern } |
        Select-Object -First 1
    if (-not $checksumLine) {
        throw "checksums.txt does not contain $asset"
    }
    if ($checksumLine -notmatch $checksumPattern) {
        throw "Could not parse checksum line for $asset"
    }

    $expectedHash = $Matches[1].ToUpperInvariant()
    $actualHash = (Get-FileHash -Algorithm SHA256 $zipPath).Hash.ToUpperInvariant()
    if ($actualHash -ne $expectedHash) {
        throw "SHA256 mismatch for $asset. Expected $expectedHash, got $actualHash."
    }

    Expand-Archive -Path $zipPath -DestinationPath $extractDir

    $pkglibDir = & $PgConfig --pkglibdir
    $sharedDir = & $PgConfig --sharedir
    $binDir = & $PgConfig --bindir
    $extensionDir = Join-Path $sharedDir 'extension'

    $libSource = Get-ChildItem $extractDir -Directory -Recurse |
        Where-Object { $_.Name -eq 'lib' } |
        Select-Object -First 1
    $extensionSource = Get-ChildItem $extractDir -Directory -Recurse |
        Where-Object { $_.Name -eq 'extension' -and $_.Parent.Name -eq 'share' } |
        Select-Object -First 1
    $binSource = Get-ChildItem $extractDir -Directory -Recurse |
        Where-Object { $_.Name -eq 'bin' } |
        Select-Object -First 1

    if (-not $libSource) {
        throw "Archive does not contain a lib directory."
    }
    if (-not $extensionSource) {
        throw "Archive does not contain a share\extension directory."
    }

    Copy-Item -Path (Join-Path $libSource.FullName 'pglogical*.dll') -Destination $pkglibDir -Force
    Copy-Item -Path (Join-Path $extensionSource.FullName 'pglogical*') -Destination $extensionDir -Force
    if ($binSource) {
        Copy-Item -Path (Join-Path $binSource.FullName '*') -Destination $binDir -Force
    }

    $controlPath = Join-Path $extensionDir 'pglogical.control'
    $dllPath = Join-Path $pkglibDir 'pglogical.dll'
    if (-not (Test-Path $controlPath)) {
        throw "Install verification failed: $controlPath was not found."
    }
    if (-not (Test-Path $dllPath)) {
        throw "Install verification failed: $dllPath was not found."
    }

    Write-Host "Installed pglogical $Version for $pgVersion"
    Write-Host "pg_config: $PgConfig"
} finally {
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
}
