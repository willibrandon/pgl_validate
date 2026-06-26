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
$primaryData = Join-Path $target 'standby-primary-pgdata'
$standbyData = Join-Path $target 'standby-replica-pgdata'
$primaryLog = Join-Path $target 'standby-primary.log'
$standbyLog = Join-Path $target 'standby-replica.log'
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

function Get-PgrxPgConfig {
    param([int] $PgMajor)

    return Get-PglPgrxPgConfig -PgMajor $PgMajor
}

function Get-ExtensionSqlPath {
    param([string] $PgConfig)

    return Get-PglExtensionSqlPath -Root $root -PgConfig $PgConfig
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
            Write-Warning "pg_ctl stop failed for ${Data}; falling back to process cleanup: $_"
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

function Sql-Literal {
    param([string] $Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

function Invoke-Sql {
    param(
        [string] $Database,
        [string] $Sql,
        [int] $Port = $script:PrimaryPort
    )

    $output = & $script:Psql -X -w -h localhost -p $Port -U postgres -d $Database `
        -v ON_ERROR_STOP=1 -Atq -c $Sql 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "psql failed on port ${Port}, database ${Database}: $($output -join [Environment]::NewLine)"
    }

    return ($output -join "`n").Trim()
}

function Wait-SqlEquals {
    param(
        [string] $Database,
        [string] $Sql,
        [string] $Expected,
        [int] $Port = $script:PrimaryPort,
        [int] $TimeoutSeconds
    )

    $deadline = [DateTimeOffset]::Now.AddSeconds($TimeoutSeconds)
    $last = ''

    while ([DateTimeOffset]::Now -lt $deadline) {
        $last = Invoke-Sql -Database $Database -Port $Port -Sql $Sql
        if ($last -eq $Expected) {
            return
        }

        Start-Sleep -Milliseconds 250
    }

    throw "timed out waiting for SQL result '$Expected' on port ${Port}, database ${Database}; last result: $last"
}

$pgConfig = Get-PgrxPgConfig -PgMajor $PgMajor
$script:InitDb = Get-PglToolPath -PgConfig $pgConfig -Name 'initdb'
$script:PgCtl = Get-PglToolPath -PgConfig $pgConfig -Name 'pg_ctl'
$script:PgBaseBackup = Get-PglToolPath -PgConfig $pgConfig -Name 'pg_basebackup'
$script:Psql = Get-PglToolPath -PgConfig $pgConfig -Name 'psql'
$script:PrimaryPort = New-FreePort
$script:StandbyPort = New-FreePort
$extensionSql = Get-ExtensionSqlPath -PgConfig $pgConfig
$watchdog = Start-CleanupWatchdog -ParentPid $PID -RemoveData:(-not $KeepData)

try {
    Write-Step 'Cleaning prior physical standby test clusters'
    Stop-TestCluster -Data $standbyData -PgCtl $script:PgCtl
    Stop-TestCluster -Data $primaryData -PgCtl $script:PgCtl
    if (-not $KeepData) {
        Remove-TestData -Data $standbyData
        Remove-TestData -Data $primaryData
    }
    foreach ($log in @($primaryLog, $standbyLog)) {
        if (Test-Path -LiteralPath $log) {
            Remove-Item -LiteralPath $log -Force
        }
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

    Write-Step "Initializing primary physical-replication cluster at $primaryData"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $primaryData) | Out-Null
    Invoke-CheckedProcess `
        -FilePath $script:InitDb `
        -Arguments @('--locale=C', '--auth=trust', '--username=postgres', '-D', $primaryData) `
        -TimeoutSeconds 120 | Out-Null

    Add-Content -LiteralPath (Join-Path $primaryData 'pg_hba.conf') -Value @(
        'host replication all 127.0.0.1/32 trust',
        'host replication all ::1/128 trust',
        'host all all 127.0.0.1/32 trust',
        'host all all ::1/128 trust'
    )

    Write-Step "Starting primary on port $script:PrimaryPort"
    $primaryOptions = "-p $script:PrimaryPort -h localhost -c wal_level=replica -c hot_standby=on -c max_wal_senders=10 -c max_replication_slots=10"
    Invoke-CheckedProcess `
        -FilePath $script:PgCtl `
        -Arguments @('start', '-D', $primaryData, '-l', $primaryLog, '-o', $primaryOptions, '-w', '-t', '30') `
        -TimeoutSeconds 45 | Out-Null

    $primaryDsn = "host=localhost port=$script:PrimaryPort dbname=postgres user=postgres connect_timeout=5 application_name=pgl_validate_standby_primary"
    $standbyDsn = "host=localhost port=$script:StandbyPort dbname=postgres user=postgres connect_timeout=5 application_name=pgl_validate_standby_replica"
    $standbyDsnSql = Sql-Literal $standbyDsn

    Write-Step 'Creating extension, test table, standby peer metadata, and physical slot on primary'
    Invoke-Sql -Database 'postgres' -Sql @"
CREATE EXTENSION pgl_validate;
CREATE TABLE public.accounts(id int PRIMARY KEY, value text);
INSERT INTO public.accounts VALUES (1, 'basebackup-visible');
INSERT INTO pgl_validate.peer(name, dsn, backend)
VALUES ('standby', $standbyDsnSql, 'standby');
SELECT pg_create_physical_replication_slot('pgl_validate_standby_slot');
"@ | Out-Null

    Write-Step "Taking base backup for standby at $standbyData"
    Invoke-CheckedProcess `
        -FilePath $script:PgBaseBackup `
        -Arguments @(
            '-h', 'localhost',
            '-p', "$script:PrimaryPort",
            '-U', 'postgres',
            '-D', $standbyData,
            '-Fp',
            '-Xs',
            '-R',
            '-S', 'pgl_validate_standby_slot'
        ) `
        -TimeoutSeconds 180 | Out-Null

    Write-Step "Starting physical standby on port $script:StandbyPort"
    $standbyOptions = "-p $script:StandbyPort -h localhost -c hot_standby=on"
    Invoke-CheckedProcess `
        -FilePath $script:PgCtl `
        -Arguments @('start', '-D', $standbyData, '-l', $standbyLog, '-o', $standbyOptions, '-w', '-t', '45') `
        -TimeoutSeconds 60 | Out-Null

    Write-Step 'Waiting for standby recovery and streaming replay'
    Wait-SqlEquals `
        -Database 'postgres' `
        -Port $script:StandbyPort `
        -Sql 'SELECT pg_is_in_recovery()::text' `
        -Expected 'true' `
        -TimeoutSeconds $TimeoutSeconds
    Wait-SqlEquals `
        -Database 'postgres' `
        -Sql "SELECT count(*)::text FROM pg_stat_replication WHERE state IN ('streaming','catchup')" `
        -Expected '1' `
        -TimeoutSeconds $TimeoutSeconds

    Write-Step 'Replicating a post-basebackup row to prove live physical replay'
    Invoke-Sql -Database 'postgres' -Sql "INSERT INTO public.accounts VALUES (2, 'streamed')" | Out-Null
    Wait-SqlEquals `
        -Database 'postgres' `
        -Port $script:StandbyPort `
        -Sql "SELECT count(*)::text FROM public.accounts WHERE id = 2 AND value = 'streamed'" `
        -Expected '1' `
        -TimeoutSeconds $TimeoutSeconds

    Write-Step 'Fencing primary->standby edge through replay LSN convergence'
    $observed = Invoke-Sql -Database 'postgres' -Sql @"
WITH r AS (
    INSERT INTO pgl_validate.run(status)
    VALUES ('fencing')
    RETURNING run_id
), a AS (
    SELECT pgl_validate.fence_standby_edge(
        r.run_id,
        1,
        1,
        'primary',
        'standby',
        $standbyDsnSql,
        NULL,
        10,
        30000,
        30000,
        30000,
        100
    ) AS attempt
    FROM r
)
SELECT (attempt).status || ';' ||
       ((attempt).origin_progress_lsn >= (attempt).barrier_end_lsn)::text || ';' ||
       (attempt).token_visible::text
FROM a
"@
    if ($observed -ne 'converged;true;true') {
        throw "unexpected standby fence result: $observed"
    }

    $recorded = Invoke-Sql -Database 'postgres' -Sql @"
SELECT EXISTS (
    SELECT 1
    FROM pgl_validate.run_edge re
    JOIN pgl_validate.fence_edge fe USING (run_id, edge_id)
    JOIN pgl_validate.fence_attempt fa USING (run_id, epoch_seq, edge_id)
    WHERE re.backend = 'standby'
      AND fe.fence_kind = 'standby_replay'
      AND fe.barrier_token IS NULL
      AND fa.status = 'converged'
      AND fa.token_visible
)::text
"@
    if ($recorded -ne 'true') {
        throw 'standby replay fence catalog rows were not recorded'
    }

    Write-Step 'Running compare_table through real physical-standby fencing'
    $compareResult = Invoke-Sql -Database 'postgres' -Sql @"
SELECT (r).run_id::text || ';' || (r).verdict
FROM (
    SELECT pgl_validate.compare_table(
        'public.accounts'::regclass,
        ARRAY['standby'],
        jsonb_build_object(
            'backend', 'standby',
            'provider_node', 'primary',
            'fence_timeout_ms', 30000,
            'fence_poll_interval_ms', 100
        )
    ) AS r
) s
"@
    $compareParts = $compareResult.Split(';', 2)
    if ($compareParts.Count -ne 2) {
        throw "unexpected standby compare_table result: $compareResult"
    }
    $compareRunId = $compareParts[0]
    $compareVerdict = $compareParts[1]
    if ($compareVerdict -ne 'match') {
        throw "unexpected standby compare_table verdict: $compareVerdict"
    }

    $compareCatalog = Invoke-Sql -Database 'postgres' -Sql @"
SELECT tp.validated_property || ';' ||
       tr.verdict || ';' ||
       fe.fence_kind || ';' ||
       fa.status
FROM pgl_validate.table_plan tp
JOIN pgl_validate.table_result tr USING (run_id, schema_name, table_name)
JOIN pgl_validate.run_edge re ON re.run_id = tp.run_id
JOIN pgl_validate.fence_edge fe
  ON fe.run_id = re.run_id
 AND fe.edge_id = re.edge_id
JOIN pgl_validate.fence_attempt fa
  ON fa.run_id = fe.run_id
 AND fa.epoch_seq = fe.epoch_seq
 AND fa.edge_id = fe.edge_id
WHERE tp.run_id = $compareRunId
  AND re.backend = 'standby'
ORDER BY fe.epoch_seq
LIMIT 1
"@
    if ($compareCatalog -ne 'full;match;standby_replay;converged') {
        throw "standby compare_table did not record full replay-fenced match: $compareCatalog"
    }

    Write-Step 'Rejecting compare_table when coordinated from a physical standby'
    Invoke-Sql -Database 'postgres' -Port $script:StandbyPort -Sql @"
DO `$`$
BEGIN
    BEGIN
        PERFORM (pgl_validate.compare_table(
            'public.accounts'::regclass,
            ARRAY['standby'],
            jsonb_build_object('backend', 'standby')
        )).verdict;
        RAISE EXCEPTION 'expected standby coordinator rejection';
    EXCEPTION WHEN others THEN
        IF SQLERRM <> 'backend=standby requires the coordinator to be a primary' THEN
            RAISE;
        END IF;
    END;
END
`$`$;
"@ | Out-Null

    Write-Output "physical standby fence and compare_table tests passed on pg$PgMajor using primary port $script:PrimaryPort and standby port $script:StandbyPort"
}
finally {
    Stop-TestCluster -Data $standbyData -PgCtl $script:PgCtl
    Stop-TestCluster -Data $primaryData -PgCtl $script:PgCtl
    if (-not $KeepData) {
        Remove-TestData -Data $standbyData
        Remove-TestData -Data $primaryData
    }

    if ($watchdog -and -not $watchdog.HasExited) {
        Stop-Process -Id $watchdog.Id -Force -ErrorAction SilentlyContinue
    }
}
