<#
.SYNOPSIS
Checks that design contract sections mirror installable sources.

.DESCRIPTION
The design document names Appendix A as the catalog DDL reference. This check
keeps that appendix synchronized with sql/bootstrap/001_catalog.sql while
ignoring platform line-ending differences. It also verifies that the §19.1 GUC
table lists exactly the `pgl_validate.*` GUCs registered by src/lib.rs.
#>
[CmdletBinding()]
param(
    [string] $DesignPath = (Join-Path $PSScriptRoot '..' 'docs/design.md'),
    [string] $CatalogPath = (Join-Path $PSScriptRoot '..' 'sql/bootstrap/001_catalog.sql'),
    [string] $LibPath = (Join-Path $PSScriptRoot '..' 'src/lib.rs')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$fence = ([string] [char] 96) * 3
$design = [IO.File]::ReadAllText((Resolve-Path $DesignPath))
$catalog = [IO.File]::ReadAllText((Resolve-Path $CatalogPath))
$lib = [IO.File]::ReadAllText((Resolve-Path $LibPath))

$design = ($design -replace "`r`n", "`n") -replace "`r", "`n"
$catalog = (($catalog -replace "`r`n", "`n") -replace "`r", "`n").TrimEnd("`n")

$appendixStart = $design.IndexOf('## Appendix A: Catalog DDL', [StringComparison]::Ordinal)
if ($appendixStart -lt 0) {
    Write-Error 'docs/design.md is missing Appendix A: Catalog DDL.'
}

$openFence = $design.IndexOf($fence + 'sql', $appendixStart, [StringComparison]::Ordinal)
if ($openFence -lt 0) {
    Write-Error 'Appendix A is missing a SQL code fence.'
}

$bodyStart = $openFence + ($fence + 'sql').Length
if ($bodyStart -ge $design.Length -or $design[$bodyStart] -ne "`n") {
    Write-Error 'Appendix A SQL code fence must be followed by a newline.'
}
$bodyStart += 1

$closeFence = $design.IndexOf($fence, $bodyStart, [StringComparison]::Ordinal)
if ($closeFence -lt 0) {
    Write-Error 'Appendix A SQL code fence is not closed.'
}

$appendixDdl = $design.Substring($bodyStart, $closeFence - $bodyStart).TrimEnd("`n")
if ($appendixDdl -cne $catalog) {
    Write-Error 'docs/design.md Appendix A does not match sql/bootstrap/001_catalog.sql. Update Appendix A from the install DDL.'
}

Write-Output 'docs/design.md Appendix A matches sql/bootstrap/001_catalog.sql.'

$gucSection = [regex]::Match($design, '(?s)### 19\.1 GUCs(.*?)### 19\.2 Governance')
if (-not $gucSection.Success) {
    Write-Error 'docs/design.md is missing the §19.1 GUCs section.'
}

$registeredGucs = [regex]::Matches($lib, 'c"(pgl_validate\.[^"]+)"') |
    ForEach-Object { $_.Groups[1].Value } |
    Sort-Object -Unique
$documentedGucs = [regex]::Matches($gucSection.Groups[1].Value, '\| `([^`]+)` \|') |
    ForEach-Object { "pgl_validate.$($_.Groups[1].Value)" } |
    Sort-Object -Unique

$missingGucs = $registeredGucs | Where-Object { $documentedGucs -notcontains $_ }
$extraGucs = $documentedGucs | Where-Object { $registeredGucs -notcontains $_ }
if ($missingGucs -or $extraGucs) {
    if ($missingGucs) {
        Write-Error "docs/design.md §19.1 is missing registered GUCs: $($missingGucs -join ', ')"
    }
    if ($extraGucs) {
        Write-Error "docs/design.md §19.1 lists unregistered GUCs: $($extraGucs -join ', ')"
    }
}

Write-Output 'docs/design.md §19.1 GUC table matches src/lib.rs.'
