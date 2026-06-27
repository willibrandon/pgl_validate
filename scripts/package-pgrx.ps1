param(
    [ValidateSet(15, 16, 17, 18)]
    [int] $PgMajor = 18,

    [string] $Platform = '',

    [string] $OutDir = '',

    [string] $ArtifactDir = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:PackagePlatformOverride = $Platform

$common = Join-Path $PSScriptRoot 'pgrx-common.ps1'
. $common

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $OutDir = Join-Path (Join-Path $root 'target') 'package'
}
if ([string]::IsNullOrWhiteSpace($ArtifactDir)) {
    $ArtifactDir = Join-Path (Join-Path $root 'target') 'package-artifacts'
}

function ConvertTo-PglPackageArchitecture {
    param([System.Runtime.InteropServices.Architecture] $Architecture)

    switch ($Architecture) {
        'X64' { return 'x64' }
        'Arm64' { return 'arm64' }
        'X86' { return 'x86' }
        default { return $Architecture.ToString().ToLowerInvariant() }
    }
}

function Get-PglPackagePlatform {
    if (-not [string]::IsNullOrWhiteSpace($script:PackagePlatformOverride)) {
        return $script:PackagePlatformOverride
    }

    $architecture = ConvertTo-PglPackageArchitecture -Architecture ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture)
    if (Test-PglWindows) {
        return "windows-$architecture"
    }
    if (Test-PglMacOS) {
        return "macos-$architecture"
    }
    if (Test-PglLinux) {
        return "linux-$architecture"
    }

    return "unknown-$architecture"
}

function Get-PglExtensionVersion {
    $control = Get-ChildItem -LiteralPath $root -Filter '*.control' | Select-Object -First 1
    if (-not $control) {
        throw "No extension control file was found under $root."
    }

    $controlText = Get-Content -LiteralPath $control.FullName -Raw
    $versionMatch = [regex]::Match($controlText, "(?m)^\s*default_version\s*=\s*'([^']+)'\s*$")
    if (-not $versionMatch.Success) {
        throw "Could not read default_version from $($control.FullName)."
    }

    return $versionMatch.Groups[1].Value
}

function Test-PglPathUnderRoot {
    param(
        [string] $Path,
        [string] $AllowedRoot
    )

    $rootFull = [IO.Path]::GetFullPath($AllowedRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $pathFull = [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $prefix = "$rootFull$([IO.Path]::DirectorySeparatorChar)"

    if ($pathFull -eq $rootFull -or $pathFull.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    throw "Refusing to remove or overwrite $pathFull because it is outside $rootFull."
}

function Invoke-PglPackage {
    param(
        [string] $PgConfig,
        [string] $PackageDirectory
    )

    $arguments = @(
        'pgrx',
        'package',
        '--pg-config',
        $PgConfig,
        '--out-dir',
        $PackageDirectory,
        '--no-default-features',
        '--features',
        "pg$PgMajor"
    )

    if ($env:PGL_VALIDATE_RUST_TOOLCHAIN -and
        ($arguments.Count -eq 0 -or -not $arguments[0].StartsWith('+', [StringComparison]::Ordinal))) {
        $arguments = @("+$env:PGL_VALIDATE_RUST_TOOLCHAIN") + $arguments
    }

    cargo @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "cargo pgrx package exited with code $LASTEXITCODE."
    }
}

function Test-PglPackageLayout {
    param(
        [string] $PackageDirectory,
        [string] $Version
    )

    $controlMatches = @(
        Get-ChildItem -LiteralPath $PackageDirectory -Recurse -Force -File -Filter 'pgl_validate.control' -ErrorAction SilentlyContinue
    )
    if ($controlMatches.Count -eq 0) {
        throw "Package is missing pgl_validate.control under $PackageDirectory."
    }
    if ($controlMatches.Count -gt 1) {
        throw "Package contains multiple pgl_validate.control files: $($controlMatches.FullName -join ', ')."
    }

    $extensionDirectory = Split-Path -Parent $controlMatches[0].FullName
    $sql = Join-Path $extensionDirectory "pgl_validate--$Version.sql"
    if (-not (Test-Path -LiteralPath $sql)) {
        throw "Package is missing the generated extension SQL $sql."
    }

    $libraries = @(
        Get-ChildItem -LiteralPath $PackageDirectory -Recurse -Force -File -Filter 'pgl_validate.*' -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in @('.dll', '.so', '.dylib') }
    )
    if ($libraries.Count -eq 0) {
        throw "Package is missing the pgl_validate shared library under $PackageDirectory."
    }
    if ($libraries.Count -gt 1) {
        throw "Package contains multiple pgl_validate shared libraries: $($libraries.FullName -join ', ')."
    }

    foreach ($rootFile in @('LICENSE', 'README.md')) {
        $path = Join-Path $PackageDirectory $rootFile
        if (-not (Test-Path -LiteralPath $path)) {
            throw "Package is missing $path."
        }
    }
}

function Get-PglPackageArchivePath {
    param(
        [string] $ArchiveDirectory,
        [string] $PackagePlatform
    )

    if ($PackagePlatform.StartsWith('windows-', [StringComparison]::OrdinalIgnoreCase)) {
        return "$ArchiveDirectory.zip"
    }

    return "$ArchiveDirectory.tar.gz"
}

<#
.SYNOPSIS
Creates a ZIP archive for Windows packages.
#>
function New-PglZipPackageArchive {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string] $PackageDirectory,
        [string] $PackageName,
        [string] $ArchivePath
    )

    if (-not $PSCmdlet.ShouldProcess($ArchivePath, 'Create package archive')) {
        return
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $packageRoot = [IO.Path]::GetFullPath($PackageDirectory).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
    $archive = [IO.Compression.ZipFile]::Open($ArchivePath, [IO.Compression.ZipArchiveMode]::Create)
    try {
        Get-ChildItem -LiteralPath $PackageDirectory -Recurse -Force -File |
            Sort-Object FullName |
            ForEach-Object {
                $relativePath = [IO.Path]::GetRelativePath($packageRoot, $_.FullName)
                $entryName = "$PackageName/$relativePath".Replace('\', '/')
                [IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                    $archive,
                    $_.FullName,
                    $entryName,
                    [IO.Compression.CompressionLevel]::Optimal
                ) | Out-Null
            }
    }
    finally {
        $archive.Dispose()
    }
}

<#
.SYNOPSIS
Creates a compressed tar archive for Linux and macOS packages.
#>
function New-PglTarGzipPackageArchive {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string] $PackageDirectory,
        [string] $PackageName,
        [string] $ArchivePath
    )

    if (-not $PSCmdlet.ShouldProcess($ArchivePath, 'Create package archive')) {
        return
    }

    $tar = Get-PglCommandSource -Name 'tar'
    if (-not $tar) {
        throw 'tar is required to build Linux and macOS release archives.'
    }

    $parent = Split-Path -Parent $PackageDirectory
    & $tar -czf $ArchivePath -C $parent $PackageName
    if ($LASTEXITCODE -ne 0) {
        throw "tar exited with code $LASTEXITCODE while creating $ArchivePath."
    }
}

function New-PglPackageArchive {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string] $PackageDirectory,
        [string] $PackageName,
        [string] $PackagePlatform,
        [string] $ArchivePath
    )

    if ($PackagePlatform.StartsWith('windows-', [StringComparison]::OrdinalIgnoreCase)) {
        New-PglZipPackageArchive `
            -PackageDirectory $PackageDirectory `
            -PackageName $PackageName `
            -ArchivePath $ArchivePath
        return
    }

    New-PglTarGzipPackageArchive `
        -PackageDirectory $PackageDirectory `
        -PackageName $PackageName `
        -ArchivePath $ArchivePath
}

<#
.SYNOPSIS
Verifies that a ZIP release archive contains the extension files users need.
#>
function Test-PglZipPackageArchive {
    param(
        [string] $ArchivePath,
        [string] $Version
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        $entries = @($archive.Entries | Where-Object { $_.Length -gt 0 })
        foreach ($rootFile in @('LICENSE', 'README.md')) {
            if (-not ($entries | Where-Object { $_.FullName -match "/$([regex]::Escape($rootFile))$" })) {
                throw "Archive is missing $rootFile."
            }
        }

        if (-not ($entries | Where-Object { $_.FullName -match '/pgl_validate\.control$' })) {
            throw 'Archive is missing pgl_validate.control.'
        }
        if (-not ($entries | Where-Object { $_.FullName -match "/pgl_validate--$([regex]::Escape($Version))\.sql$" })) {
            throw "Archive is missing pgl_validate--$Version.sql."
        }
        if (-not ($entries | Where-Object { $_.FullName -match '/pgl_validate\.(dll|so|dylib)$' })) {
            throw 'Archive is missing the pgl_validate shared library.'
        }
    }
    finally {
        $archive.Dispose()
    }
}

<#
.SYNOPSIS
Verifies that a compressed tar release archive contains the extension files users need.
#>
function Test-PglTarGzipPackageArchive {
    param(
        [string] $ArchivePath,
        [string] $Version
    )

    $tar = Get-PglCommandSource -Name 'tar'
    if (-not $tar) {
        throw 'tar is required to verify Linux and macOS release archives.'
    }

    $entries = @(& $tar -tzf $ArchivePath)
    if ($LASTEXITCODE -ne 0) {
        throw "tar exited with code $LASTEXITCODE while reading $ArchivePath."
    }

    foreach ($rootFile in @('LICENSE', 'README.md')) {
        if (-not ($entries | Where-Object { $_ -match "/$([regex]::Escape($rootFile))$" })) {
            throw "Archive is missing $rootFile."
        }
    }

    if (-not ($entries | Where-Object { $_ -match '/pgl_validate\.control$' })) {
        throw 'Archive is missing pgl_validate.control.'
    }
    if (-not ($entries | Where-Object { $_ -match "/pgl_validate--$([regex]::Escape($Version))\.sql$" })) {
        throw "Archive is missing pgl_validate--$Version.sql."
    }
    if (-not ($entries | Where-Object { $_ -match '/pgl_validate\.(so|dylib)$' })) {
        throw 'Archive is missing the pgl_validate shared library.'
    }
}

function Test-PglPackageArchive {
    param(
        [string] $ArchivePath,
        [string] $PackagePlatform,
        [string] $Version
    )

    if ($PackagePlatform.StartsWith('windows-', [StringComparison]::OrdinalIgnoreCase)) {
        Test-PglZipPackageArchive -ArchivePath $ArchivePath -Version $Version
        return
    }

    Test-PglTarGzipPackageArchive -ArchivePath $ArchivePath -Version $Version
}

$pgConfig = Get-PglPgrxPgConfig -PgMajor $PgMajor
$version = Get-PglExtensionVersion
$packagePlatform = Get-PglPackagePlatform
$packageName = "pgl_validate-$version-pg$PgMajor-$packagePlatform"
$packageDirectory = Join-Path $OutDir $packageName
$archiveDirectory = Join-Path $ArtifactDir $packageName
$archivePath = Get-PglPackageArchivePath -ArchiveDirectory $archiveDirectory -PackagePlatform $packagePlatform

Test-PglPathUnderRoot -Path $packageDirectory -AllowedRoot $root | Out-Null
Test-PglPathUnderRoot -Path $archivePath -AllowedRoot $root | Out-Null

if (Test-Path -LiteralPath $packageDirectory) {
    Remove-Item -LiteralPath $packageDirectory -Recurse -Force
}
if (Test-Path -LiteralPath $archivePath) {
    Remove-Item -LiteralPath $archivePath -Force
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
New-Item -ItemType Directory -Force -Path $ArtifactDir | Out-Null

Invoke-PglPackage -PgConfig $pgConfig -PackageDirectory $packageDirectory
Copy-Item -LiteralPath (Join-Path $root 'LICENSE') -Destination (Join-Path $packageDirectory 'LICENSE') -Force
Copy-Item -LiteralPath (Join-Path $root 'README.md') -Destination (Join-Path $packageDirectory 'README.md') -Force
Test-PglPackageLayout -PackageDirectory $packageDirectory -Version $version
New-PglPackageArchive `
    -PackageDirectory $packageDirectory `
    -PackageName $packageName `
    -PackagePlatform $packagePlatform `
    -ArchivePath $archivePath
Test-PglPackageArchive -ArchivePath $archivePath -PackagePlatform $packagePlatform -Version $version

if ($env:GITHUB_OUTPUT) {
    "artifact_name=$packageName" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
    "artifact_path=$archivePath" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
    "package_name=$packageName" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
    "package_dir=$packageDirectory" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
}

Write-Information -MessageData "Packaged $packageName" -InformationAction Continue
Write-Information -MessageData "Archive: $archivePath" -InformationAction Continue
