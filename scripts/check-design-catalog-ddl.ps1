<#
.SYNOPSIS
Checks that the catalog DDL appendix mirrors the install DDL.

.DESCRIPTION
The design document names Appendix A as the catalog DDL reference. This check
keeps that appendix synchronized with sql/bootstrap/001_catalog.sql while
ignoring platform line-ending differences.
#>
[CmdletBinding()]
param(
    [string] $DesignPath = (Join-Path $PSScriptRoot '..' 'docs/design.md'),
    [string] $CatalogPath = (Join-Path $PSScriptRoot '..' 'sql/bootstrap/001_catalog.sql')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$fence = ([string] [char] 96) * 3
$design = [IO.File]::ReadAllText((Resolve-Path $DesignPath))
$catalog = [IO.File]::ReadAllText((Resolve-Path $CatalogPath))

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
