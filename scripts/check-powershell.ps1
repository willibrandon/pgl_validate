param(
    [string] $Path = (Join-Path $PSScriptRoot '.')
)

$ErrorActionPreference = 'Stop'

$module = Get-Module -ListAvailable -Name PSScriptAnalyzer | Select-Object -First 1
if (-not $module) {
    throw 'PSScriptAnalyzer is required. Install it with: Install-Module PSScriptAnalyzer -Scope CurrentUser'
}

$tokens = $null
$parseErrors = @()
foreach ($script in Get-ChildItem -LiteralPath $Path -Filter '*.ps1' -File -Recurse) {
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $script.FullName,
        [ref] $tokens,
        [ref] $errors
    ) | Out-Null

    foreach ($errorRecord in $errors) {
        $parseErrors += [pscustomobject]@{
            ScriptName = $script.Name
            Line       = $errorRecord.Extent.StartLineNumber
            Column     = $errorRecord.Extent.StartColumnNumber
            RuleName   = 'ParseError'
            Message    = $errorRecord.Message
        }
    }
}

$diagnostics = @(Invoke-ScriptAnalyzer -Path $Path -Recurse -Severity Warning,Error)
$failures = @($parseErrors) + @($diagnostics)
if ($failures.Count -gt 0) {
    $failures |
        Sort-Object ScriptName, Line, RuleName |
        Format-Table ScriptName, Line, Column, RuleName, Message -Wrap
    throw "PowerShell script checks found $($failures.Count) issue(s)."
}

Write-Output 'PowerShell script checks passed.'
