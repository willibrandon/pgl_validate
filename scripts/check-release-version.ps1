<#
.SYNOPSIS
Checks that the requested release version matches project metadata.

.DESCRIPTION
Release artifacts are named from the extension control file. This guard keeps
Git tags, Cargo metadata, and PostgreSQL extension metadata from drifting.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $Version,

    [string] $Root = (Join-Path $PSScriptRoot '..')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-PglControlVersion {
    <#
    .SYNOPSIS
        Reads default_version from the extension control file.
    #>
    param([string] $ProjectRoot)

    $control = Get-ChildItem -LiteralPath $ProjectRoot -Filter '*.control' | Select-Object -First 1
    if (-not $control) {
        throw "No extension control file was found under $ProjectRoot."
    }

    $controlText = Get-Content -LiteralPath $control.FullName -Raw
    $match = [regex]::Match($controlText, "(?m)^\s*default_version\s*=\s*'([^']+)'\s*$")
    if (-not $match.Success) {
        throw "Could not read default_version from $($control.FullName)."
    }

    return $match.Groups[1].Value
}

function Get-PglCargoVersion {
    <#
    .SYNOPSIS
        Reads package.version from Cargo.toml.
    #>
    param([string] $ProjectRoot)

    $cargoToml = Join-Path $ProjectRoot 'Cargo.toml'
    $cargoText = Get-Content -LiteralPath $cargoToml -Raw
    $match = [regex]::Match($cargoText, "(?m)^\s*version\s*=\s*`"([^`"]+)`"\s*$")
    if (-not $match.Success) {
        throw "Could not read package version from $cargoToml."
    }

    return $match.Groups[1].Value
}

$normalized = $Version.Trim()
if ($normalized.StartsWith('v', [StringComparison]::OrdinalIgnoreCase)) {
    $normalized = $normalized.Substring(1)
}
if ($normalized -notmatch '^\d+\.\d+\.\d+([-.+][0-9A-Za-z.-]+)?$') {
    throw "Release version must look like v0.1.0 or 0.1.0, got '$Version'."
}

$projectRoot = (Resolve-Path $Root).Path
$controlVersion = Get-PglControlVersion -ProjectRoot $projectRoot
$cargoVersion = Get-PglCargoVersion -ProjectRoot $projectRoot

if ($controlVersion -ne $normalized) {
    throw "Release version $normalized does not match pgl_validate.control default_version $controlVersion."
}
if ($cargoVersion -ne $normalized) {
    throw "Release version $normalized does not match Cargo.toml package version $cargoVersion."
}

Write-Output "Release version $normalized matches Cargo.toml and pgl_validate.control."
