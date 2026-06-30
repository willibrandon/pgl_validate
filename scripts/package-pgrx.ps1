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

    Get-PglPackageSharedLibrary -PackageDirectory $PackageDirectory | Out-Null

    foreach ($rootFile in @('LICENSE', 'README.md')) {
        $path = Join-Path $PackageDirectory $rootFile
        if (-not (Test-Path -LiteralPath $path)) {
            throw "Package is missing $path."
        }
    }
}

<#
.SYNOPSIS
Returns the single pgl_validate shared library from a package directory.
#>
function Get-PglPackageSharedLibrary {
    param([string] $PackageDirectory)

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

    return $libraries[0]
}

<#
.SYNOPSIS
Returns true when loader metadata still points at a build-time pgrx installation.
#>
function Test-PglBuildPathLeak {
    param([string] $Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }

    return $Text -match '(/Users/runner|/home/runner|\.pgrx|pgrx-install)'
}

function Get-PglMacOSDependencyInstallNames {
    param([string[]] $LoadCommands)

    return @(
        $LoadCommands |
            Select-Object -Skip 1 |
            ForEach-Object {
                $line = $_.Trim()
                if (-not [string]::IsNullOrWhiteSpace($line)) {
                    ($line -split '\s+', 2)[0]
                }
            } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function Get-PglMacOSDylibId {
    param([string[]] $DylibId)

    $id = $DylibId |
        Select-Object -Skip 1 |
        ForEach-Object { $_.Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -First 1

    if (-not [string]::IsNullOrWhiteSpace($id)) {
        return $id
    }

    return $null
}

function Get-PglMacOSRpaths {
    param([string[]] $LoaderMetadata)

    return @(
        $LoaderMetadata |
            Where-Object { $_ -match '^\s*path\s+(.+?)\s+\(offset\s+\d+\)' } |
            ForEach-Object { $Matches[1] }
    )
}

function Get-PglMacOSLoadCommandValues {
    param(
        [string[]] $LoadCommands,
        [string[]] $DylibId,
        [string[]] $LoaderMetadata
    )

    $values = @(
        Get-PglMacOSDependencyInstallNames -LoadCommands $LoadCommands
        Get-PglMacOSDylibId -DylibId $DylibId
        Get-PglMacOSRpaths -LoaderMetadata $LoaderMetadata
    )

    return @(
        $values |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )
}

<#
.SYNOPSIS
Rewrites macOS package load commands so libpq is resolved from the installed PostgreSQL library directory.
#>
function Invoke-PglMacOSPackageLoadCommandFixup {
    param([string] $LibraryPath)

    $otool = Get-PglCommandSource -Name 'otool'
    $installNameTool = Get-PglCommandSource -Name 'install_name_tool'
    $codesign = Get-PglCommandSource -Name 'codesign'
    foreach ($tool in @(@{ Name = 'otool'; Path = $otool }, @{ Name = 'install_name_tool'; Path = $installNameTool }, @{ Name = 'codesign'; Path = $codesign })) {
        if (-not $tool.Path) {
            throw "$($tool.Name) is required to package macOS release artifacts."
        }
    }

    $changed = $false
    $loadCommands = @(& $otool -L $LibraryPath)
    if ($LASTEXITCODE -ne 0) {
        throw "otool -L exited with code $LASTEXITCODE for $LibraryPath."
    }

    $libpqInstallNames = @(
        Get-PglMacOSDependencyInstallNames -LoadCommands $loadCommands |
            Where-Object { $_ -and ($_.EndsWith('/libpq.5.dylib', [StringComparison]::Ordinal) -or $_ -eq 'libpq.5.dylib') } |
            Sort-Object -Unique
    )

    foreach ($installName in $libpqInstallNames) {
        if ($installName -ne '@rpath/libpq.5.dylib') {
            & $installNameTool -change $installName '@rpath/libpq.5.dylib' $LibraryPath
            if ($LASTEXITCODE -ne 0) {
                throw "install_name_tool -change exited with code $LASTEXITCODE for $installName."
            }
            $changed = $true
        }
    }

    $dylibId = @(& $otool -D $LibraryPath)
    if ($LASTEXITCODE -ne 0) {
        throw "otool -D exited with code $LASTEXITCODE for $LibraryPath."
    }
    if (($dylibId | Select-Object -Skip 1 | Select-Object -First 1) -ne '@rpath/pgl_validate.dylib') {
        & $installNameTool -id '@rpath/pgl_validate.dylib' $LibraryPath
        if ($LASTEXITCODE -ne 0) {
            throw "install_name_tool -id exited with code $LASTEXITCODE for $LibraryPath."
        }
        $changed = $true
    }

    $loaderMetadata = @(& $otool -l $LibraryPath)
    if ($LASTEXITCODE -ne 0) {
        throw "otool -l exited with code $LASTEXITCODE for $LibraryPath."
    }

    $rpaths = @(Get-PglMacOSRpaths -LoaderMetadata $loaderMetadata)
    foreach ($rpath in $rpaths) {
        if (Test-PglBuildPathLeak -Text $rpath) {
            & $installNameTool -delete_rpath $rpath $LibraryPath
            if ($LASTEXITCODE -ne 0) {
                throw "install_name_tool -delete_rpath exited with code $LASTEXITCODE for $rpath."
            }
            $changed = $true
        }
    }

    if ($rpaths -notcontains '@loader_path') {
        & $installNameTool -add_rpath '@loader_path' $LibraryPath
        if ($LASTEXITCODE -ne 0) {
            throw "install_name_tool -add_rpath exited with code $LASTEXITCODE for $LibraryPath."
        }
        $changed = $true
    }

    if ($changed) {
        & $codesign --force --sign - $LibraryPath
        if ($LASTEXITCODE -ne 0) {
            throw "codesign exited with code $LASTEXITCODE for $LibraryPath."
        }
    }

    $verifiedLoadCommands = @(& $otool -L $LibraryPath)
    if ($LASTEXITCODE -ne 0) {
        throw "otool -L exited with code $LASTEXITCODE while verifying $LibraryPath."
    }
    $verifiedId = @(& $otool -D $LibraryPath)
    if ($LASTEXITCODE -ne 0) {
        throw "otool -D exited with code $LASTEXITCODE while verifying $LibraryPath."
    }
    $verifiedLoaderMetadata = @(& $otool -l $LibraryPath)
    if ($LASTEXITCODE -ne 0) {
        throw "otool -l exited with code $LASTEXITCODE while verifying $LibraryPath."
    }

    $verifiedLoadCommandValues = Get-PglMacOSLoadCommandValues `
        -LoadCommands $verifiedLoadCommands `
        -DylibId $verifiedId `
        -LoaderMetadata $verifiedLoaderMetadata
    $leakedLoadCommandValues = @($verifiedLoadCommandValues | Where-Object { Test-PglBuildPathLeak -Text $_ })
    if ($leakedLoadCommandValues.Count -gt 0) {
        throw "macOS package library still references build-time pgrx path(s) in load command values for $LibraryPath`: $($leakedLoadCommandValues -join ', ')."
    }
    if ($verifiedLoadCommandValues -notcontains '@rpath/libpq.5.dylib') {
        throw "macOS package library does not load libpq through @rpath: $LibraryPath."
    }
    if ((Get-PglMacOSRpaths -LoaderMetadata $verifiedLoaderMetadata) -notcontains '@loader_path') {
        throw "macOS package library is missing @loader_path LC_RPATH: $LibraryPath."
    }
}

<#
.SYNOPSIS
Verifies Linux package loader metadata does not contain build-runner paths.
#>
function Test-PglLinuxPackageLoadCommand {
    param([string] $LibraryPath)

    $readelf = Get-PglCommandSource -Name 'readelf'
    if (-not $readelf) {
        throw 'readelf is required to verify Linux release artifacts.'
    }

    $dynamicSection = @(& $readelf -d $LibraryPath)
    if ($LASTEXITCODE -ne 0) {
        throw "readelf -d exited with code $LASTEXITCODE for $LibraryPath."
    }
    $dynamicText = ($dynamicSection -join "`n")
    if (Test-PglBuildPathLeak -Text $dynamicText) {
        throw "Linux package library references a build-time pgrx path: $LibraryPath."
    }
}

<#
.SYNOPSIS
Normalizes platform-specific shared-library metadata before archiving a package.
#>
function Invoke-PglPackageLoadCommandFixup {
    param(
        [string] $PackageDirectory,
        [string] $PackagePlatform
    )

    $library = Get-PglPackageSharedLibrary -PackageDirectory $PackageDirectory
    if ($PackagePlatform.StartsWith('macos-', [StringComparison]::OrdinalIgnoreCase)) {
        Invoke-PglMacOSPackageLoadCommandFixup -LibraryPath $library.FullName
        return
    }
    if ($PackagePlatform.StartsWith('linux-', [StringComparison]::OrdinalIgnoreCase)) {
        Test-PglLinuxPackageLoadCommand -LibraryPath $library.FullName
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
Invoke-PglPackageLoadCommandFixup -PackageDirectory $packageDirectory -PackagePlatform $packagePlatform
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
