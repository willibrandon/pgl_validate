<#
.SYNOPSIS
Checks that prepared release assets match the supported package matrix.

.DESCRIPTION
The release workflow gathers artifacts from many matrix jobs before publishing
them to GitHub. This guard verifies that the gathered files are exactly the
expected PostgreSQL-major/platform artifacts, with Unix packages as tarballs,
Windows packages as ZIP files, Windows x64 MSI installers, and checksums that
match the files being published.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $AssetDirectory,

    [Parameter(Mandatory)]
    [string] $Version,

    [int[]] $PgMajor = @(15, 16, 17, 18),

    [string[]] $Platform = @(
        'linux-x64',
        'linux-arm64',
        'windows-x64',
        'windows-arm64-hosted-x64',
        'macos-arm64'
    ),

    [switch] $RequireChecksums
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-PglNormalizedReleaseVersion {
    <#
    .SYNOPSIS
        Removes an optional leading v from a release version.
    #>
    param([string] $InputVersion)

    $normalized = $InputVersion.Trim()
    if ($normalized.StartsWith('v', [StringComparison]::OrdinalIgnoreCase)) {
        $normalized = $normalized.Substring(1)
    }

    if ($normalized -notmatch '^\d+\.\d+\.\d+([-.+][0-9A-Za-z.-]+)?$') {
        throw "Release version must look like v0.1.0 or 0.1.0, got '$InputVersion'."
    }

    return $normalized
}

function Get-PglExpectedReleaseAssetName {
    <#
    .SYNOPSIS
        Returns the expected archive names for the supported release matrix.
    #>
    param(
        [string] $ReleaseVersion,
        [int[]] $PgMajor,
        [string[]] $Platform
    )

    $expected = [System.Collections.Generic.List[string]]::new()
    foreach ($major in $PgMajor) {
        foreach ($target in $Platform) {
            $prefix = "pgl_validate-$ReleaseVersion-pg$major-$target"
            if ($target.StartsWith('windows-', [StringComparison]::OrdinalIgnoreCase)) {
                $expected.Add("$prefix.zip")
            }
            elseif (
                $target.StartsWith('linux-', [StringComparison]::OrdinalIgnoreCase) -or
                $target.StartsWith('macos-', [StringComparison]::OrdinalIgnoreCase)
            ) {
                $expected.Add("$prefix.tar.gz")
            }
            else {
                throw "Unsupported release platform '$target'."
            }
        }

        if ($Platform -contains 'windows-x64') {
            $expected.Add("pgl_validate-$ReleaseVersion-pg$major-windows-x64.msi")
        }
    }

    return $expected
}

function Test-PglReleaseChecksumFile {
    <#
    .SYNOPSIS
        Verifies checksums.txt names and hashes every expected release asset.
    #>
    param(
        [string] $AssetDirectory,
        [string[]] $ExpectedAssetName
    )

    $checksumPath = Join-Path $AssetDirectory 'checksums.txt'
    if (-not (Test-Path -LiteralPath $checksumPath -PathType Leaf)) {
        throw 'checksums.txt is required but was not found.'
    }

    $checksumByName = @{}
    foreach ($line in Get-Content -LiteralPath $checksumPath) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $match = [regex]::Match($line, '^([0-9a-f]{64})  (.+)$')
        if (-not $match.Success) {
            throw "Invalid checksums.txt line: $line"
        }

        $name = $match.Groups[2].Value
        if ($name -eq 'checksums.txt') {
            throw 'checksums.txt must not contain a checksum for itself.'
        }
        if ($checksumByName.ContainsKey($name)) {
            throw "checksums.txt contains duplicate entries for $name."
        }

        $checksumByName[$name] = $match.Groups[1].Value
    }

    foreach ($name in $ExpectedAssetName) {
        if (-not $checksumByName.ContainsKey($name)) {
            throw "checksums.txt is missing $name."
        }

        $path = Join-Path $AssetDirectory $name
        $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
        if ($checksumByName[$name] -ne $actualHash) {
            throw "checksums.txt hash for $name is $($checksumByName[$name]); expected $actualHash."
        }
    }

    $unexpectedChecksum = @($checksumByName.Keys | Where-Object { $_ -notin $ExpectedAssetName } | Sort-Object)
    if ($unexpectedChecksum.Count -gt 0) {
        throw "checksums.txt contains unexpected asset(s): $($unexpectedChecksum -join ', ')."
    }
}

$releaseVersion = Get-PglNormalizedReleaseVersion -InputVersion $Version
$assetRoot = (Resolve-Path $AssetDirectory).Path
$expectedAssets = @(
    Get-PglExpectedReleaseAssetName `
        -ReleaseVersion $releaseVersion `
        -PgMajor $PgMajor `
        -Platform $Platform
)

if ($RequireChecksums) {
    $expectedFiles = @($expectedAssets + 'checksums.txt')
}
else {
    $expectedFiles = $expectedAssets
}

$actualFiles = @(
    Get-ChildItem -LiteralPath $assetRoot -File |
        Select-Object -ExpandProperty Name |
        Sort-Object
)

$missing = @($expectedFiles | Where-Object { $_ -notin $actualFiles } | Sort-Object)
$unexpected = @($actualFiles | Where-Object { $_ -notin $expectedFiles } | Sort-Object)

if ($missing.Count -gt 0) {
    throw "Release asset directory is missing: $($missing -join ', ')."
}
if ($unexpected.Count -gt 0) {
    throw "Release asset directory has unexpected file(s): $($unexpected -join ', ')."
}

$unixZip = @($actualFiles | Where-Object { $_ -match '-(linux|macos)-.+\.zip$' })
if ($unixZip.Count -gt 0) {
    throw "Linux and macOS release assets must be .tar.gz, not .zip: $($unixZip -join ', ')."
}

$windowsTarball = @($actualFiles | Where-Object { $_ -match '-windows-.+\.tar\.gz$' })
if ($windowsTarball.Count -gt 0) {
    throw "Windows release package assets must be .zip, not .tar.gz: $($windowsTarball -join ', ')."
}

if ($RequireChecksums) {
    Test-PglReleaseChecksumFile -AssetDirectory $assetRoot -ExpectedAssetName $expectedAssets
}

Write-Output "Release assets match $releaseVersion package contract: $($expectedAssets.Count) package/installer file(s)."
