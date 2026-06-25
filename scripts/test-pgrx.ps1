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

$exitCode = 0
try {
    & (Join-Path $PSScriptRoot 'stop-pgrx-test-clusters.ps1') @stopArgs

    $command = @('cargo', 'pgrx', 'test', "pg$PgMajor") + $CargoPgrxArgs
    $runner = Join-Path $PSScriptRoot 'pgrx-vs.ps1'
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
