param(
    [ValidateSet(15, 16, 17, 18)]
    [int] $PgMajor = 18,

    [switch] $KeepData,

    [ValidateRange(1, 86400)]
    [int] $TimeoutSeconds = 900,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $CargoPgrxArgs = @()
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$stopArgs = @{ Root = $root }
if (-not $KeepData) {
    $stopArgs.RemoveData = $true
}

function Stop-ProcessTree {
    param([int] $ProcessId)

    $children = Get-CimInstance Win32_Process | Where-Object { $_.ParentProcessId -eq $ProcessId }
    foreach ($child in $children) {
        Stop-ProcessTree -ProcessId $child.ProcessId
    }

    Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
}

function ConvertTo-CommandLineArgument {
    param([string] $Argument)

    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }

    return '"' + ($Argument -replace '"', '\"') + '"'
}

function Get-PgrxPgConfig {
    param(
        [string] $Root,
        [int] $PgMajor
    )

    $configPath = Join-Path $env:USERPROFILE '.pgrx\config.toml'
    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "pgrx config was not found at $configPath. Run cargo pgrx init for pg$PgMajor."
    }

    $configText = Get-Content -LiteralPath $configPath -Raw
    $label = "pg$PgMajor"
    $pattern = "(?m)^\s*$label\s*=\s*['""]([^'""]+)['""]\s*$"
    $match = [regex]::Match($configText, $pattern)
    if (-not $match.Success) {
        throw "pgrx config does not define $label in $configPath."
    }

    $pgConfig = $match.Groups[1].Value
    if (-not (Test-Path -LiteralPath $pgConfig)) {
        throw "Configured pg_config for $label does not exist: $pgConfig"
    }

    return $pgConfig
}

function Get-ExtensionSqlPath {
    param(
        [string] $Root,
        [string] $PgConfig
    )

    $control = Get-ChildItem -LiteralPath $Root -Filter '*.control' | Select-Object -First 1
    if (-not $control) {
        throw "No extension control file was found under $Root."
    }

    $controlText = Get-Content -LiteralPath $control.FullName -Raw
    $versionMatch = [regex]::Match($controlText, "(?m)^\s*default_version\s*=\s*'([^']+)'\s*$")
    if (-not $versionMatch.Success) {
        throw "Could not read default_version from $($control.FullName)."
    }

    $shareDir = & $PgConfig --sharedir
    if ($LASTEXITCODE -ne 0 -or -not $shareDir) {
        throw "pg_config failed to report --sharedir for $PgConfig."
    }

    $extensionDir = Join-Path $shareDir 'extension'
    New-Item -ItemType Directory -Force -Path $extensionDir | Out-Null
    return Join-Path $extensionDir "$($control.BaseName)--$($versionMatch.Groups[1].Value).sql"
}

$exitCode = 0
try {
    & (Join-Path $PSScriptRoot 'stop-pgrx-test-clusters.ps1') @stopArgs

    $runner = Join-Path $PSScriptRoot 'pgrx-vs.ps1'
    $pgConfig = Get-PgrxPgConfig -Root $root -PgMajor $PgMajor
    $extensionSql = Get-ExtensionSqlPath -Root $root -PgConfig $pgConfig

    & $runner cargo pgrx schema "pg$PgMajor" --no-default-features --features "pg$PgMajor" --out $extensionSql
    if ($LASTEXITCODE -ne 0) {
        throw "cargo pgrx schema failed while preparing $extensionSql."
    }

    $command = @('cargo', 'pgrx', 'test', "pg$PgMajor") + $CargoPgrxArgs
    $powershell = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
    if (-not $powershell) {
        $powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
    }

    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runner) + $command
    $argumentLine = ($arguments | ForEach-Object { ConvertTo-CommandLineArgument $_ }) -join ' '
    $process = Start-Process -FilePath $powershell -ArgumentList $argumentLine -NoNewWindow -PassThru

    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        Write-Warning "cargo pgrx test pg$PgMajor exceeded ${TimeoutSeconds}s; terminating the process tree and cleaning pgrx test clusters."
        Stop-ProcessTree -ProcessId $process.Id
        $exitCode = 124
    }
    else {
        $process.Refresh()
        $exitCode = $process.ExitCode
    }
}
catch {
    Write-Error $_
    $exitCode = 1
}
finally {
    & (Join-Path $PSScriptRoot 'stop-pgrx-test-clusters.ps1') @stopArgs
}

exit $exitCode
