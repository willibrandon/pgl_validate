param(
    [ValidateSet('15', '16', '17', '18')]
    [string] $PgMajor = '18',

    [string] $Version = '2.5.3',

    [string] $PgConfig,

    [ValidateSet('auto', 'package', 'source')]
    [string] $InstallMode = 'auto'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$common = Join-Path $PSScriptRoot 'pgrx-common.ps1'
. $common

function Find-PgConfig {
    param([string] $Major)

    return Get-PglPgrxPgConfig -PgMajor ([int] $Major)
}

function Get-PglogicalPackageAsset {
    param(
        [string] $Version,
        [string] $Major
    )

    $architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    if ((Test-PglWindows) -and $env:PGL_VALIDATE_MSVC_ARCH) {
        $architecture = switch ($env:PGL_VALIDATE_MSVC_ARCH.ToLowerInvariant()) {
            'x64' { 'X64' }
            'arm64' { 'Arm64' }
            default { $architecture }
        }
    }

    if ((Test-PglWindows) -and $architecture -eq 'X64') {
        return "pglogical-$Version-pg$Major-windows-x64.zip"
    }
    if ((Test-PglLinux) -and $architecture -eq 'X64') {
        return "pglogical-$Version-pg$Major-linux-x64.tar.gz"
    }
    if ((Test-PglMacOS) -and $architecture -eq 'Arm64') {
        return "pglogical-$Version-pg$Major-macos-arm64.tar.gz"
    }

    return $null
}

function Save-CheckedReleaseAsset {
    param(
        [string] $BaseUri,
        [string] $Asset,
        [string] $Destination,
        [string] $ChecksumsPath
    )

    Invoke-WebRequest -Uri "$BaseUri/$Asset" -OutFile $Destination

    $checksumPattern = "([0-9a-fA-F]{64}).*$([regex]::Escape($Asset))"
    $checksumLine = Get-Content $ChecksumsPath |
        Where-Object { $_ -match $checksumPattern } |
        Select-Object -First 1
    if (-not $checksumLine) {
        throw "checksums.txt does not contain $Asset"
    }
    if ($checksumLine -notmatch $checksumPattern) {
        throw "Could not parse checksum line for $Asset"
    }

    $expectedHash = $Matches[1].ToUpperInvariant()
    $actualHash = (Get-FileHash -Algorithm SHA256 $Destination).Hash.ToUpperInvariant()
    if ($actualHash -ne $expectedHash) {
        throw "SHA256 mismatch for $Asset. Expected $expectedHash, got $actualHash."
    }
}

function Expand-ReleaseAsset {
    param(
        [string] $ArchivePath,
        [string] $ExtractDir
    )

    if ($ArchivePath.EndsWith('.zip', [StringComparison]::OrdinalIgnoreCase)) {
        Expand-Archive -Path $ArchivePath -DestinationPath $ExtractDir
        return
    }

    $tar = Get-PglCommandSource -Name 'tar'
    if (-not $tar) {
        throw "tar is required to extract $ArchivePath."
    }

    & $tar -xzf $ArchivePath -C $ExtractDir
    if ($LASTEXITCODE -ne 0) {
        throw "tar failed while extracting $ArchivePath."
    }
}

function Install-PglogicalPackage {
    param(
        [string] $ExtractDir,
        [string] $PgConfig
    )

    $pkglibDir = & $PgConfig --pkglibdir
    $sharedDir = & $PgConfig --sharedir
    $binDir = & $PgConfig --bindir
    $extensionDir = Join-Path $sharedDir 'extension'
    New-Item -ItemType Directory -Force -Path $pkglibDir, $extensionDir, $binDir | Out-Null

    $libSource = Get-ChildItem $ExtractDir -Directory -Recurse |
        Where-Object { $_.Name -eq 'lib' } |
        Select-Object -First 1
    $extensionSource = Get-ChildItem $ExtractDir -Directory -Recurse |
        Where-Object { $_.Name -eq 'extension' -and $_.Parent.Name -eq 'share' } |
        Select-Object -First 1
    $binSource = Get-ChildItem $ExtractDir -Directory -Recurse |
        Where-Object { $_.Name -eq 'bin' } |
        Select-Object -First 1

    if (-not $libSource) {
        throw 'Archive does not contain a lib directory.'
    }
    if (-not $extensionSource) {
        throw 'Archive does not contain a share/extension directory.'
    }

    $libFiles = Get-ChildItem -LiteralPath $libSource.FullName -File -Filter 'pglogical*'
    if (-not $libFiles) {
        throw "Archive lib directory does not contain pglogical libraries."
    }
    foreach ($file in $libFiles) {
        Copy-Item -LiteralPath $file.FullName -Destination $pkglibDir -Force
    }

    foreach ($file in Get-ChildItem -LiteralPath $extensionSource.FullName -File -Filter 'pglogical*') {
        Copy-Item -LiteralPath $file.FullName -Destination $extensionDir -Force
    }

    if ($binSource) {
        foreach ($file in Get-ChildItem -LiteralPath $binSource.FullName -File) {
            Copy-Item -LiteralPath $file.FullName -Destination $binDir -Force
        }
    }
}

function Install-PglogicalSource {
    param(
        [string] $ExtractDir,
        [string] $PgConfig
    )

    $sourceRoot = Get-ChildItem -LiteralPath $ExtractDir -Directory |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'Makefile') } |
        Select-Object -First 1
    if (-not $sourceRoot) {
        $sourceRoot = Get-ChildItem -LiteralPath $ExtractDir -Directory -Recurse |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'Makefile') } |
            Select-Object -First 1
    }
    if (-not $sourceRoot) {
        throw 'Source archive does not contain a Makefile.'
    }

    if (Test-PglWindows) {
        $cmakeLists = Join-Path $sourceRoot.FullName 'CMakeLists.txt'
        if (-not (Test-Path -LiteralPath $cmakeLists)) {
            throw 'Source archive does not contain CMakeLists.txt for a Windows build.'
        }

        $cmake = Get-PglCommandSource -Name 'cmake'
        if (-not $cmake) {
            throw 'cmake is required to build pglogical from source on Windows.'
        }

        $buildRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'target'
        New-Item -ItemType Directory -Force -Path $buildRoot | Out-Null
        $buildDir = Join-Path $buildRoot "pglogical-cmake-$([guid]::NewGuid())"
        $ninja = Get-PglCommandSource -Name 'ninja'
        $configureArgs = @(
            '-S', $sourceRoot.FullName,
            '-B', $buildDir,
            "-DPG_CONFIG=$PgConfig",
            '-DCMAKE_BUILD_TYPE=Release'
        )
        if ($ninja) {
            $configureArgs = @('-G', 'Ninja') + $configureArgs
        }

        try {
            $env:PG_CONFIG = $PgConfig
            & $cmake @configureArgs
            if ($LASTEXITCODE -ne 0) {
                throw 'pglogical CMake configure failed.'
            }

            & $cmake --build $buildDir --config Release --target install
            if ($LASTEXITCODE -ne 0) {
                throw 'pglogical CMake install failed.'
            }
        }
        finally {
            Remove-Item -LiteralPath $buildDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        return
    }

    $make = Get-PglCommandSource -Name 'make'
    if (-not $make) {
        throw 'make is required to build pglogical from source.'
    }

    Push-Location $sourceRoot.FullName
    try {
        & $make "PG_CONFIG=$PgConfig" install
        if ($LASTEXITCODE -ne 0) {
            throw 'pglogical source install failed.'
        }
    }
    finally {
        Pop-Location
    }
}

function Assert-PglogicalInstalled {
    param([string] $PgConfig)

    $pkglibDir = & $PgConfig --pkglibdir
    $sharedDir = & $PgConfig --sharedir
    $extensionDir = Join-Path $sharedDir 'extension'

    $controlPath = Join-Path $extensionDir 'pglogical.control'
    $library = Get-ChildItem -LiteralPath $pkglibDir -File -Filter 'pglogical*' -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in @('.dll', '.so', '.dylib') } |
        Select-Object -First 1
    if (-not (Test-Path $controlPath)) {
        throw "Install verification failed: $controlPath was not found."
    }
    if (-not $library) {
        throw "Install verification failed: no pglogical library was found in $pkglibDir."
    }
}

if (-not $PgConfig) {
    $PgConfig = Find-PgConfig -Major $PgMajor
}
$PgConfig = (Resolve-Path $PgConfig).Path

$pgVersion = & $PgConfig --version
if ($pgVersion -notmatch "PostgreSQL\s+$PgMajor\.") {
    throw "$PgConfig reports '$pgVersion', not PostgreSQL $PgMajor.x"
}

$baseUri = "https://github.com/willibrandon/pglogical/releases/download/v$Version"
$workDir = Join-Path ([IO.Path]::GetTempPath()) "pgl_validate-pglogical-$([guid]::NewGuid())"
$checksumsPath = Join-Path $workDir 'checksums.txt'
$extractDir = Join-Path $workDir 'extract'

New-Item -ItemType Directory -Path $workDir, $extractDir | Out-Null

try {
    Invoke-WebRequest -Uri "$baseUri/checksums.txt" -OutFile $checksumsPath

    $asset = if ($InstallMode -eq 'source') {
        $null
    }
    else {
        Get-PglogicalPackageAsset -Version $Version -Major $PgMajor
    }

    if ($asset) {
        $archivePath = Join-Path $workDir $asset
        Save-CheckedReleaseAsset -BaseUri $baseUri -Asset $asset -Destination $archivePath -ChecksumsPath $checksumsPath
        Expand-ReleaseAsset -ArchivePath $archivePath -ExtractDir $extractDir
        Install-PglogicalPackage -ExtractDir $extractDir -PgConfig $PgConfig
        Write-Host "Installed pglogical $Version package $asset for $pgVersion"
    }
    elseif ($InstallMode -eq 'package') {
        $architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture
        throw "No pglogical $Version package is published for this host (OS=$([Runtime.InteropServices.RuntimeInformation]::OSDescription), Architecture=$architecture)."
    }
    else {
        $asset = "pglogical-$Version-source.tar.gz"
        $archivePath = Join-Path $workDir $asset
        Save-CheckedReleaseAsset -BaseUri $baseUri -Asset $asset -Destination $archivePath -ChecksumsPath $checksumsPath
        Expand-ReleaseAsset -ArchivePath $archivePath -ExtractDir $extractDir
        Install-PglogicalSource -ExtractDir $extractDir -PgConfig $PgConfig
        Write-Host "Built and installed pglogical $Version from source for $pgVersion"
    }

    Assert-PglogicalInstalled -PgConfig $PgConfig
    Write-Host "pg_config: $PgConfig"
} finally {
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
}
