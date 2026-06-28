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
        Kind = 'SEQUENCE'
        CreatePattern = '(?im)^\s*CREATE\s+SEQUENCE\s+pgl_validate\.([a-zA-Z_][a-zA-Z0-9_]*)\b'
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

$roleSourceFiles = @()
$roleSourceFiles += Get-Item -LiteralPath $commentsPath
$roleSourceFiles += Get-ChildItem -LiteralPath (Join-Path $workspace 'sql/bootstrap') -Filter '*.sql' -File

$seenRoles = @{}
foreach ($file in $roleSourceFiles) {
    $text = Get-Content -LiteralPath $file.FullName -Raw
    foreach ($match in [regex]::Matches($text, '(?im)^\s*CREATE\s+ROLE\s+([a-zA-Z_][a-zA-Z0-9_]*)\b')) {
        $roleName = $match.Groups[1].Value
        if ($seenRoles.ContainsKey($roleName)) {
            continue
        }
        $seenRoles[$roleName] = $true

        $commentPattern = "(?im)^\s*COMMENT\s+ON\s+ROLE\s+$([regex]::Escape($roleName))\b"
        if ($commentsText -notmatch $commentPattern) {
            $relative = [IO.Path]::GetRelativePath($workspace, $file.FullName)
            Add-Failure "$relative`: missing COMMENT ON ROLE for $roleName."
        }
    }
}

$commentedColumns = @{}
foreach ($match in [regex]::Matches($commentsText, "\('([^']+)'\s*,\s*'([^']+)'\s*,\s*'[^']*'\)")) {
    $commentedColumns["$($match.Groups[1].Value).$($match.Groups[2].Value)"] = $true
}
foreach ($match in [regex]::Matches($commentsText, '(?im)^\s*COMMENT\s+ON\s+COLUMN\s+pgl_validate\.([a-zA-Z_][a-zA-Z0-9_]*)\.([a-zA-Z_][a-zA-Z0-9_]*)\b')) {
    $commentedColumns["$($match.Groups[1].Value).$($match.Groups[2].Value)"] = $true
}

$catalogPath = Join-Path $workspace 'sql/bootstrap/001_catalog.sql'
$catalogText = Get-Content -LiteralPath $catalogPath -Raw
$catalogTableColumns = @{}
foreach ($tableMatch in [regex]::Matches($catalogText, '(?ims)^\s*CREATE\s+TABLE\s+pgl_validate\.([a-zA-Z_][a-zA-Z0-9_]*)\s*\((.*?)^\s*\);')) {
    $tableName = $tableMatch.Groups[1].Value
    $body = $tableMatch.Groups[2].Value
    $tableColumns = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($body -split "`r?`n")) {
        if ($line -notmatch '^\s+([a-zA-Z_][a-zA-Z0-9_]*)\s+') {
            continue
        }

        $columnName = $Matches[1]
        if ($columnName -cne $columnName.ToLowerInvariant()) {
            continue
        }

        if ($columnName -in @('CHECK', 'CONSTRAINT', 'EXCLUDE', 'FOREIGN', 'PRIMARY', 'UNIQUE')) {
            continue
        }

        [void] $tableColumns.Add($columnName)
        if (-not $commentedColumns.ContainsKey("$tableName.$columnName")) {
            Add-Failure "sql/bootstrap/001_catalog.sql: missing COMMENT ON COLUMN for pgl_validate.$tableName.$columnName."
        }

        if ($line -match '\bGENERATED\s+(ALWAYS|BY\s+DEFAULT)\s+AS\s+IDENTITY\b') {
            $sequenceName = "pgl_validate.${tableName}_${columnName}_seq"
            $commentPattern = "(?im)^\s*COMMENT\s+ON\s+SEQUENCE\s+$([regex]::Escape($sequenceName))(\s|$)"
            if ($commentsText -notmatch $commentPattern) {
                Add-Failure "sql/bootstrap/001_catalog.sql: missing COMMENT ON SEQUENCE for $sequenceName."
            }
        }
    }
    $catalogTableColumns[$tableName] = $tableColumns
}

foreach ($copyMatch in [regex]::Matches($commentsText, "\('([^']+)'\s*,\s*'([^']+)'\)")) {
    $viewName = $copyMatch.Groups[1].Value
    $sourceTableName = $copyMatch.Groups[2].Value
    if (-not $catalogTableColumns.ContainsKey($sourceTableName)) {
        continue
    }

    foreach ($columnName in $catalogTableColumns[$sourceTableName]) {
        $commentedColumns["$viewName.$columnName"] = $true
    }
}

foreach ($viewMatch in [regex]::Matches($catalogText, '(?ims)^\s*CREATE\s+OR\s+REPLACE\s+VIEW\s+pgl_validate\.([a-zA-Z_][a-zA-Z0-9_]*)\s+AS\s+SELECT\s+\*\s+FROM\s+pgl_validate\.([a-zA-Z_][a-zA-Z0-9_]*)\s*;')) {
    $viewName = $viewMatch.Groups[1].Value
    $sourceTableName = $viewMatch.Groups[2].Value
    if (-not $catalogTableColumns.ContainsKey($sourceTableName)) {
        Add-Failure "sql/bootstrap/001_catalog.sql: view pgl_validate.$viewName selects from unknown table pgl_validate.$sourceTableName."
        continue
    }

    foreach ($columnName in $catalogTableColumns[$sourceTableName]) {
        if (-not $commentedColumns.ContainsKey("$viewName.$columnName")) {
            Add-Failure "sql/bootstrap/001_catalog.sql: missing COMMENT ON COLUMN for pgl_validate.$viewName.$columnName."
        }
    }
}

foreach ($viewMatch in [regex]::Matches($catalogText, '(?ims)^\s*CREATE\s+OR\s+REPLACE\s+VIEW\s+pgl_validate\.run_progress\s+AS\s+.*?^SELECT\s+(.*?)^FROM\s+pgl_validate\.run\s+r', 'Multiline')) {
    $selectList = $viewMatch.Groups[1].Value
    $viewColumns = New-Object System.Collections.Generic.HashSet[string]
    foreach ($columnMatch in [regex]::Matches($selectList, '(?m)^\s*[a-zA-Z_][a-zA-Z0-9_]*\.([a-zA-Z_][a-zA-Z0-9_]*)\s*,?\s*$')) {
        [void] $viewColumns.Add($columnMatch.Groups[1].Value)
    }
    foreach ($aliasMatch in [regex]::Matches($selectList, '(?im)\bAS\s+([a-zA-Z_][a-zA-Z0-9_]*)\s*,?\s*$')) {
        [void] $viewColumns.Add($aliasMatch.Groups[1].Value)
    }

    foreach ($columnName in $viewColumns) {
        if (-not $commentedColumns.ContainsKey("run_progress.$columnName")) {
            Add-Failure "sql/bootstrap/001_catalog.sql: missing COMMENT ON COLUMN for pgl_validate.run_progress.$columnName."
        }
    }
}

if ($failures.Count -gt 0) {
    $failures | Sort-Object | ForEach-Object { Write-Output $_ }
    throw "Public comment checks found $($failures.Count) issue(s)."
}

Write-Output 'Public comment checks passed.'
