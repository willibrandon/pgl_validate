param(
    [ValidateSet(15, 16, 17, 18)]
    [int] $PgMajor = 18,

    [switch] $KeepData,

    [ValidateRange(1, 86400)]
    [int] $TimeoutSeconds = 180
)

$ErrorActionPreference = 'Stop'

$common = Join-Path $PSScriptRoot 'pgrx-common.ps1'
. $common

$root = Split-Path -Parent $PSScriptRoot
$target = Join-Path $root 'target'
$data = Join-Path $target "async-worker-test-pgdata-$PgMajor"
$log = Join-Path $target "async-worker-test-pg$PgMajor.log"
$runner = Join-Path $PSScriptRoot 'pgrx-vs.ps1'

function Write-Step {
    param([string] $Message)

    Write-Output "[$(Get-Date -Format o)] $Message"
}

function Assert-UnderRoot {
    param(
        [string] $Path,
        [string] $Root
    )

    $resolvedRoot = (Resolve-Path -LiteralPath $Root).Path
    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    if (-not $resolvedPath.StartsWith($resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to operate on path outside workspace: $resolvedPath"
    }
}

function Stop-ProcessTree {
    param([int] $ProcessId)

    Stop-PglProcessTree -ProcessId $ProcessId
}

function Invoke-CheckedProcess {
    param(
        [string] $FilePath,
        [string[]] $Arguments,
        [int] $TimeoutSeconds = 60,
        [switch] $AllowFailure
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    foreach ($argument in $Arguments) {
        [void] $startInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::Start($startInfo)
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        Stop-ProcessTree -ProcessId $process.Id
        throw "$FilePath timed out after ${TimeoutSeconds}s."
    }

    $process.Refresh()
    if ($process.ExitCode -ne 0 -and -not $AllowFailure) {
        throw "$FilePath exited with code $($process.ExitCode)."
    }

    return $process.ExitCode
}

function ConvertTo-EncodedCommand {
    param([string] $Script)

    $bytes = [System.Text.Encoding]::Unicode.GetBytes($Script)
    return [Convert]::ToBase64String($bytes)
}

function Stop-TestCluster {
    param(
        [string] $Data,
        [string] $PgCtl
    )

    if (Test-Path -LiteralPath $Data) {
        try {
            Invoke-CheckedProcess `
                -FilePath $PgCtl `
                -Arguments @('stop', '-D', $Data, '-m', 'fast', '-w', '-t', '30') `
                -TimeoutSeconds 40 `
                -AllowFailure | Out-Null
        }
        catch {
            Write-Warning "pg_ctl stop failed; falling back to process cleanup: $_"
        }
    }

    & (Join-Path $PSScriptRoot 'stop-pgrx-test-clusters.ps1') -Root $root
    Start-Sleep -Milliseconds 500
}

function Remove-TestData {
    param([string] $Data)

    if (Test-Path -LiteralPath $Data) {
        Assert-UnderRoot -Path $Data -Root $root
        for ($attempt = 1; $attempt -le 20; $attempt++) {
            try {
                Remove-Item -LiteralPath $Data -Recurse -Force
                return
            }
            catch {
                if ($attempt -eq 20) {
                    throw
                }

                Start-Sleep -Milliseconds 500
            }
        }
    }
}

function Start-CleanupWatchdog {
    param(
        [int] $ParentPid,
        [switch] $RemoveData
    )

    $powershell = Get-PglPowerShellExecutable
    $cleanupScript = Join-Path $PSScriptRoot 'stop-pgrx-test-clusters.ps1'
    $removeFlag = if ($RemoveData) { '$true' } else { '$false' }
    $watchdogScript = @"
`$ErrorActionPreference = 'SilentlyContinue'
`$parentPid = $ParentPid
`$root = '$($root.Replace("'", "''"))'
`$cleanupScript = '$($cleanupScript.Replace("'", "''"))'
`$removeData = $removeFlag
while (Get-Process -Id `$parentPid -ErrorAction SilentlyContinue) {
    Start-Sleep -Seconds 2
}
if (`$removeData) {
    & `$cleanupScript -Root `$root -RemoveData
}
else {
    & `$cleanupScript -Root `$root
}
"@

    $encoded = ConvertTo-EncodedCommand -Script $watchdogScript
    return Start-PglHiddenProcess `
        -FilePath $powershell `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded)
}

function New-FreePort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try {
        return ([System.Net.IPEndPoint] $listener.LocalEndpoint).Port
    }
    finally {
        $listener.Stop()
    }
}

function Invoke-Sql {
    param(
        [string] $Sql,
        [switch] $Quiet
    )

    $output = & $script:Psql -X -w -h localhost -p $script:Port -U postgres -d postgres `
        -v ON_ERROR_STOP=1 -Atq -c $Sql 2>&1
    if ($LASTEXITCODE -ne 0) {
        if (Test-Path -LiteralPath $log) {
            $tail = (Get-Content -LiteralPath $log -Tail 120) -join [Environment]::NewLine
            throw "psql failed: $($output -join [Environment]::NewLine)$([Environment]::NewLine)PostgreSQL log tail:$([Environment]::NewLine)$tail"
        }

        throw "psql failed: $($output -join [Environment]::NewLine)"
    }

    $text = ($output -join "`n").Trim()
    if (-not $Quiet -and $text) {
        Write-Output $text
    }

    return $text
}

function Wait-AsyncRunComplete {
    param(
        [string] $RunId,
        [int] $TimeoutSeconds
    )

    $deadline = [DateTimeOffset]::Now.AddSeconds($TimeoutSeconds)
    $last = ''

    while ([DateTimeOffset]::Now -lt $deadline) {
        $last = Invoke-Sql -Quiet -Sql @"
SELECT r.status || '|' ||
       wt.status || '|' ||
       COALESCE(tr.verdict, '<none>') || '|' ||
       (wt.worker_pid IS NOT NULL)::text || '|' ||
       COALESCE(wt.error, '')
FROM pgl_validate.run r
JOIN pgl_validate.worker_task wt USING (run_id)
LEFT JOIN pgl_validate.table_result tr USING (run_id)
WHERE r.run_id = $RunId::bigint;
"@

        if ($last -like 'completed|completed|match|true|*') {
            return $last
        }

        if ($last -like 'failed|*') {
            throw "async validation failed for run ${RunId}: $last"
        }

        Start-Sleep -Milliseconds 100
    }

    if (Test-Path -LiteralPath $log) {
        $tail = (Get-Content -LiteralPath $log -Tail 120) -join [Environment]::NewLine
        throw "timed out waiting for async validation run ${RunId}; last state: $last$([Environment]::NewLine)PostgreSQL log tail:$([Environment]::NewLine)$tail"
    }

    throw "timed out waiting for async validation run ${RunId}; last state: $last"
}

function Wait-AsyncRunStatus {
    param(
        [string] $RunId,
        [string] $ExpectedStatus,
        [int] $TimeoutSeconds
    )

    $deadline = [DateTimeOffset]::Now.AddSeconds($TimeoutSeconds)
    $last = ''

    while ([DateTimeOffset]::Now -lt $deadline) {
        $last = Invoke-Sql -Quiet -Sql @"
SELECT r.status || '|' ||
       wt.status || '|' ||
       COALESCE(wt.error, '') || '|' ||
       (
           SELECT count(*)::text
           FROM pgl_validate.table_result tr
           WHERE tr.run_id = r.run_id
             AND tr.verdict = 'match'
       )
FROM pgl_validate.run r
JOIN pgl_validate.worker_task wt USING (run_id)
WHERE r.run_id = $RunId::bigint;
"@

        if ($last -like "$ExpectedStatus|*") {
            return $last
        }

        if ($ExpectedStatus -ne 'failed' -and $last -like 'failed|*') {
            throw "async validation failed for run ${RunId}: $last"
        }

        Start-Sleep -Milliseconds 100
    }

    if (Test-Path -LiteralPath $log) {
        $tail = (Get-Content -LiteralPath $log -Tail 120) -join [Environment]::NewLine
        throw "timed out waiting for async validation run ${RunId} to reach ${ExpectedStatus}; last state: $last$([Environment]::NewLine)PostgreSQL log tail:$([Environment]::NewLine)$tail"
    }

    throw "timed out waiting for async validation run ${RunId} to reach ${ExpectedStatus}; last state: $last"
}

$pgConfig = Get-PglPgrxPgConfig -PgMajor $PgMajor
$script:InitDb = Get-PglToolPath -PgConfig $pgConfig -Name 'initdb'
$script:PgCtl = Get-PglToolPath -PgConfig $pgConfig -Name 'pg_ctl'
$script:Psql = Get-PglToolPath -PgConfig $pgConfig -Name 'psql'
$script:Port = New-FreePort
$extensionSql = Get-PglExtensionSqlPath -Root $root -PgConfig $pgConfig
$watchdog = Start-CleanupWatchdog -ParentPid $PID -RemoveData:(-not $KeepData)

try {
    Write-Step "Cleaning prior async worker test cluster"
    Stop-TestCluster -Data $data -PgCtl $script:PgCtl
    if (-not $KeepData) {
        Remove-TestData -Data $data
    }
    if (Test-Path -LiteralPath $log) {
        Remove-Item -LiteralPath $log -Force
    }

    Write-Step "Installing pgl_validate for pg$PgMajor"
    & $runner cargo pgrx install --pg-config $pgConfig --no-default-features --features "pg$PgMajor"
    if ($LASTEXITCODE -ne 0) {
        throw "cargo pgrx install failed for pg$PgMajor."
    }

    Write-Step "Generating extension SQL at $extensionSql"
    & $runner cargo pgrx schema --pg-config $pgConfig --no-default-features --features "pg$PgMajor" --out $extensionSql
    if ($LASTEXITCODE -ne 0) {
        throw "cargo pgrx schema failed while preparing $extensionSql."
    }

    Write-Step "Initializing async worker test cluster at $data"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $data) | Out-Null
    Invoke-CheckedProcess `
        -FilePath $script:InitDb `
        -Arguments @('--locale=C', '--auth=trust', '--username=postgres', '-D', $data) `
        -TimeoutSeconds 120 | Out-Null

    Write-Step "Starting async worker test cluster on port $script:Port"
    $socketOption = Get-PglUnixSocketOption -Directory $target
    $serverOptions = (@(
        "-p $script:Port",
        '-h localhost',
        $socketOption,
        '-c max_worker_processes=20'
    ) | Where-Object { $_ }) -join ' '
    Invoke-CheckedProcess `
        -FilePath $script:PgCtl `
        -Arguments @('start', '-D', $data, '-l', $log, '-o', $serverOptions, '-w', '-t', '30') `
        -TimeoutSeconds 45 | Out-Null

    Write-Step 'Creating extension and test table'
    Invoke-Sql -Quiet -Sql @"
CREATE EXTENSION pgl_validate;
CREATE TABLE public.async_target(id int PRIMARY KEY, value text);
INSERT INTO public.async_target VALUES (1, 'same');
"@ | Out-Null

    Write-Step 'Launching compare_async through a real dynamic background worker'
    $runId = Invoke-Sql -Quiet -Sql "SELECT pgl_validate.compare_async(ARRAY['public.async_target'::regclass])::text;"
    if (-not $runId) {
        throw 'compare_async did not return a run id.'
    }

    Write-Step "Waiting for async run $runId to complete"
    $state = Wait-AsyncRunComplete -RunId $runId -TimeoutSeconds $TimeoutSeconds
    Write-Output "async worker validation passed on pg${PgMajor}: run_id=$runId state=$state"

    Write-Step 'Launching scheduled async validation through run_schedule'
    Invoke-Sql -Quiet -Sql @"
SELECT (pgl_validate.put_schedule(
    'async_worker_smoke',
    '* * * * *',
    ARRAY['public.async_target'],
    NULL,
    NULL,
    '{}'::jsonb,
    true
)).name;
"@ | Out-Null
    $scheduledRunId = Invoke-Sql -Quiet -Sql "SELECT pgl_validate.run_schedule('async_worker_smoke')::text;"
    if (-not $scheduledRunId) {
        throw 'run_schedule did not return a run id.'
    }

    Write-Step "Waiting for scheduled async run $scheduledRunId to complete"
    $scheduledState = Wait-AsyncRunComplete -RunId $scheduledRunId -TimeoutSeconds $TimeoutSeconds
    $lastScheduleRun = Invoke-Sql -Quiet -Sql "SELECT last_run_id::text FROM pgl_validate.schedule WHERE name = 'async_worker_smoke';"
    if ($lastScheduleRun -ne $scheduledRunId) {
        throw "schedule last_run_id was $lastScheduleRun, expected $scheduledRunId."
    }

    Write-Output "scheduled async validation passed on pg${PgMajor}: run_id=$scheduledRunId state=$scheduledState"

    Write-Step 'Creating paused async task and resuming it through a replacement worker'
    $resumeSeed = Invoke-Sql -Quiet -Sql @"
WITH run AS (
    INSERT INTO pgl_validate.run(status, options, tables_total)
    VALUES ('paused', '{"async": true, "resume_smoke": true}'::jsonb, 1)
    RETURNING run_id
),
task AS (
    INSERT INTO pgl_validate.worker_task(
        run_id, task_kind, request, status, database_name
    )
    SELECT
        run_id,
        'compare',
        jsonb_build_object(
            'tables', jsonb_build_array('public.async_target'),
            'repset', NULL,
            'peers', NULL,
            'reference', NULL,
            'options', '{}'::jsonb
        ),
        'paused',
        current_database()
    FROM run
    RETURNING run_id, task_id
)
SELECT run_id::text || ';' || task_id::text
FROM task;
"@
    $resumeParts = $resumeSeed.Split(';', 2)
    if ($resumeParts.Count -ne 2) {
        throw "unexpected paused task seed result: $resumeSeed"
    }
    $resumeRunId = $resumeParts[0]

    $resumed = Invoke-Sql -Quiet -Sql "SELECT pgl_validate.resume($resumeRunId::bigint)::text;"
    if ($resumed -ne 'true') {
        throw "resume returned $resumed for paused async run $resumeRunId."
    }

    Write-Step "Waiting for resumed async run $resumeRunId to complete"
    $resumedState = Wait-AsyncRunComplete -RunId $resumeRunId -TimeoutSeconds $TimeoutSeconds
    Write-Output "resumed async validation passed on pg${PgMajor}: run_id=$resumeRunId state=$resumedState"

    Write-Step 'Validating explicit-table async resume preserves committed table progress'
    Invoke-Sql -Quiet -Sql @"
CREATE TABLE public.async_resume_a(id int PRIMARY KEY, value text);
CREATE TABLE public.async_resume_b(id int PRIMARY KEY, value text);
INSERT INTO public.async_resume_a VALUES (1, 'same');
INSERT INTO public.async_resume_b VALUES (1, 'same');
"@ | Out-Null

    $partialRunId = Invoke-Sql -Quiet -Sql @"
SELECT pgl_validate.compare_async(
    ARRAY[
        'public.async_resume_a'::regclass,
        'public.async_resume_b'::regclass
    ],
    NULL,
    NULL,
    NULL,
    '{"_pgl_validate_worker_fail_once_after_tables":1}'::jsonb
)::text;
"@
    if (-not $partialRunId) {
        throw 'partial explicit-table compare_async did not return a run id.'
    }

    $failedState = Wait-AsyncRunStatus -RunId $partialRunId -ExpectedStatus 'failed' -TimeoutSeconds $TimeoutSeconds
    if ($failedState -notlike 'failed|failed|worker task execution failed after committing 1 table(s)|1') {
        throw "unexpected failed explicit-table async state: $failedState"
    }

    $partialShape = Invoke-Sql -Quiet -Sql @"
SELECT
    (SELECT count(*)::text
     FROM pgl_validate.table_result tr
     WHERE tr.run_id = $partialRunId::bigint
       AND tr.table_name = 'async_resume_a'
       AND tr.verdict = 'match') || ';' ||
    (SELECT count(*)::text
     FROM pgl_validate.table_result tr
     WHERE tr.run_id = $partialRunId::bigint
       AND tr.table_name = 'async_resume_b') || ';' ||
    (
        SELECT (wt.request->'options' ? '_pgl_validate_worker_fail_once_after_tables')::text
        FROM pgl_validate.worker_task wt
        WHERE wt.run_id = $partialRunId::bigint
    );
"@
    if ($partialShape -ne '1;0;false') {
        throw "unexpected partial explicit-table async shape: $partialShape"
    }

    $partialResumed = Invoke-Sql -Quiet -Sql "SELECT pgl_validate.resume($partialRunId::bigint)::text;"
    if ($partialResumed -ne 'true') {
        throw "resume returned $partialResumed for interrupted explicit-table async run $partialRunId."
    }

    $partialCompleted = Wait-AsyncRunStatus -RunId $partialRunId -ExpectedStatus 'completed' -TimeoutSeconds $TimeoutSeconds
    if ($partialCompleted -notlike 'completed|completed||2') {
        throw "unexpected completed explicit-table async state: $partialCompleted"
    }

    $finalShape = Invoke-Sql -Quiet -Sql @"
SELECT r.tables_total::text || ';' ||
       r.tables_matched::text || ';' ||
       r.tables_differ::text || ';' ||
       string_agg(tr.table_name || ':' || tr.verdict, ',' ORDER BY tr.table_name)
FROM pgl_validate.run r
JOIN pgl_validate.table_result tr USING (run_id)
WHERE r.run_id = $partialRunId::bigint
GROUP BY r.run_id;
"@
    if ($finalShape -ne '2;2;0;async_resume_a:match,async_resume_b:match') {
        throw "unexpected resumed explicit-table async final shape: $finalShape"
    }

    Write-Output "explicit-table async resume preserved committed progress on pg${PgMajor}: run_id=$partialRunId state=$partialCompleted"
}
catch {
    if (Test-Path -LiteralPath $log) {
        Write-Output '--- async worker test log tail ---'
        Get-Content -LiteralPath $log -Tail 120
    }
    throw
}
finally {
    Stop-TestCluster -Data $data -PgCtl $script:PgCtl

    if (-not $KeepData) {
        Remove-TestData -Data $data
        if (Test-Path -LiteralPath $log) {
            Remove-Item -LiteralPath $log -Force
        }
    }

    if ($watchdog -and -not $watchdog.HasExited) {
        Stop-Process -Id $watchdog.Id -Force -ErrorAction SilentlyContinue
    }
}
