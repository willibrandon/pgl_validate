param(
    [string] $Root = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'

$workspace = (Resolve-Path -LiteralPath $Root).Path
$commentsPath = Join-Path $workspace 'sql/comments.sql'
if (-not (Test-Path -LiteralPath $commentsPath)) {
    throw "Missing SQL comments file: $commentsPath"
}

$commentsText = Get-Content -LiteralPath $commentsPath -Raw
$failures = New-Object System.Collections.Generic.List[string]

function Add-Failure {
    param([string] $Message)

    [void] $failures.Add($Message)
}

function Test-RustDocComment {
    param(
        [string[]] $Lines,
        [int] $LineIndex
    )

    for ($i = $LineIndex - 1; $i -ge 0; $i--) {
        $line = $Lines[$i].Trim()
        if ($line -eq '') {
            continue
        }

        if ($line.StartsWith('///') -or $line.StartsWith('/**') -or $line.StartsWith('#[doc')) {
            return $true
        }

        if ($line.StartsWith('#[')) {
            continue
        }

        return $false
    }

    return $false
}

$rustFiles = Get-ChildItem -LiteralPath (Join-Path $workspace 'src') -Filter '*.rs' -Recurse -File
foreach ($file in $rustFiles) {
    $lines = Get-Content -LiteralPath $file.FullName
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $line = $lines[$index]
        if ($line -match '^\s*pub\s+(extern\s+"[^"]+"\s+)?(async\s+)?(unsafe\s+)?(fn|struct|enum|trait|mod|const|static)\b' -and
            $line -notmatch '^\s*pub\s*\(') {
            if (-not (Test-RustDocComment -Lines $lines -LineIndex $index)) {
                $relative = [IO.Path]::GetRelativePath($workspace, $file.FullName)
                Add-Failure "${relative}:$($index + 1) public Rust item is missing rustdoc."
            }
        }
    }
}

$sqlFiles = @()
$sqlFiles += Get-ChildItem -LiteralPath (Join-Path $workspace 'sql/bootstrap') -Filter '*.sql' -File
$sqlFiles += Get-ChildItem -LiteralPath (Join-Path $workspace 'src') -Filter '*.rs' -Recurse -File

$sqlObjectPatterns = @(
    @{
        Kind = 'SCHEMA'
        CreatePattern = '(?im)^\s*CREATE\s+SCHEMA(?:\s+IF\s+NOT\s+EXISTS)?\s+pgl_validate\b'
        NamePattern = { 'pgl_validate' }
    },
    @{
        Kind = 'TABLE'
        CreatePattern = '(?im)^\s*CREATE\s+TABLE\s+pgl_validate\.([a-zA-Z_][a-zA-Z0-9_]*)\b'
        NamePattern = { param($match) "pgl_validate.$($match.Groups[1].Value)" }
    },
    @{
        Kind = 'VIEW'
        CreatePattern = '(?im)^\s*CREATE(?:\s+OR\s+REPLACE)?\s+VIEW\s+pgl_validate\.([a-zA-Z_][a-zA-Z0-9_]*)\b'
        NamePattern = { param($match) "pgl_validate.$($match.Groups[1].Value)" }
    },
    @{
        Kind = 'TYPE'
        CreatePattern = '(?im)^\s*CREATE\s+TYPE\s+pgl_validate\.([a-zA-Z_][a-zA-Z0-9_]*)\b'
        NamePattern = { param($match) "pgl_validate.$($match.Groups[1].Value)" }
    },
    @{
        Kind = 'FUNCTION'
        CreatePattern = '(?im)^\s*CREATE\s+FUNCTION\s+pgl_validate\.([a-zA-Z_][a-zA-Z0-9_]*)\s*\('
        NamePattern = { param($match) "pgl_validate.$($match.Groups[1].Value)" }
    },
    @{
        Kind = 'AGGREGATE'
        CreatePattern = '(?im)^\s*CREATE\s+AGGREGATE\s+pgl_validate\.([a-zA-Z_][a-zA-Z0-9_]*)\s*\('
        NamePattern = { param($match) "pgl_validate.$($match.Groups[1].Value)" }
    }
)

$seen = @{}
foreach ($file in $sqlFiles) {
    $text = Get-Content -LiteralPath $file.FullName -Raw
    foreach ($pattern in $sqlObjectPatterns) {
        foreach ($match in [regex]::Matches($text, $pattern.CreatePattern)) {
            $name = & $pattern.NamePattern $match
            $key = "$($pattern.Kind) $name"
            if ($seen.ContainsKey($key)) {
                continue
            }
            $seen[$key] = $true

            $commentPattern = "(?im)^\s*COMMENT\s+ON\s+$($pattern.Kind)\s+$([regex]::Escape($name))(\s|\(|$)"
            if ($commentsText -notmatch $commentPattern) {
                $relative = [IO.Path]::GetRelativePath($workspace, $file.FullName)
                Add-Failure "$relative`: missing COMMENT ON $($pattern.Kind) for $name."
            }
        }
    }
}

if ($failures.Count -gt 0) {
    $failures | Sort-Object | ForEach-Object { Write-Output $_ }
    throw "Public comment checks found $($failures.Count) issue(s)."
}

Write-Output 'Public comment checks passed.'
