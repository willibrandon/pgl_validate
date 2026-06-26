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
$data = Join-Path $target 'pglogical-test-pgdata'
$log = Join-Path $target 'pglogical-test.log'
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
        [string] $Data,
        [string] $PgCtl,
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

function ConvertTo-SqlLiteral {
    param([string] $Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

function Invoke-Sql {
    param(
        [string] $Database,
        [string] $Sql
    )

    $output = & $script:Psql -X -w -h localhost -p $script:Port -U postgres -d $Database `
        -v ON_ERROR_STOP=1 -Atq -c $Sql 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "psql failed on database ${Database}: $($output -join [Environment]::NewLine)"
    }

    return ($output -join "`n").Trim()
}

function Start-AsyncSql {
    param(
        [string] $Database,
        [string] $Sql
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $script:Psql
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @(
        '-X',
        '-w',
        '-h',
        'localhost',
        '-p',
        "$script:Port",
        '-U',
        'postgres',
        '-d',
        $Database,
        '-v',
        'ON_ERROR_STOP=1',
        '-Atq',
        '-c',
        $Sql
    )) {
        [void] $startInfo.ArgumentList.Add($argument)
    }

    return [System.Diagnostics.Process]::Start($startInfo)
}

function Wait-AsyncSql {
    param(
        [System.Diagnostics.Process] $Process,
        [int] $TimeoutSeconds,
        [string] $Context
    )

    if (-not $Process.WaitForExit($TimeoutSeconds * 1000)) {
        Stop-ProcessTree -ProcessId $Process.Id
        throw "$Context timed out after ${TimeoutSeconds}s."
    }

    $stdout = $Process.StandardOutput.ReadToEnd().Trim()
    $stderr = $Process.StandardError.ReadToEnd().Trim()
    $Process.Refresh()
    if ($Process.ExitCode -ne 0) {
        throw "$Context exited with code $($Process.ExitCode): $stderr $stdout"
    }

    return $stdout
}

function Wait-SubscriptionReady {
    param(
        [string] $SubscriberDatabase = 'target',
        [string] $SubscriptionName = 'sub',
        [string] $ProviderDatabase = 'provider',
        [int] $TimeoutSeconds
    )

    $deadline = [DateTimeOffset]::Now.AddSeconds($TimeoutSeconds)
    $last = ''

    while ([DateTimeOffset]::Now -lt $deadline) {
        $status = Invoke-Sql -Database $SubscriberDatabase -Sql @"
SELECT COALESCE((
    SELECT status || '|' || slot_name
    FROM pglogical.show_subscription_status($(ConvertTo-SqlLiteral $SubscriptionName)::name)
), '<missing>|')
"@
        $parts = $status.Split('|', 2)
        $statusValue = $parts[0]
        $slotName = if ($parts.Count -gt 1) { $parts[1] } else { '' }
        $sync = Invoke-Sql -Database $SubscriberDatabase -Sql @"
SELECT COALESCE(
    string_agg(
        sync_kind::text || ':' || sync_status::text || ':' || sync_statuslsn::text,
        ',' ORDER BY sync_kind, sync_nspname, sync_relname
    ),
    '<none>'
)
FROM pglogical.local_sync_status
"@
        $syncReady = Invoke-Sql -Database $SubscriberDatabase -Sql @"
SELECT (NOT EXISTS (
    SELECT 1
    FROM pglogical.local_sync_status
    WHERE sync_status <> 'r'
))::text
"@
        $slotStatus = '<no-slot>'
        if ($slotName) {
            $slotStatus = Invoke-Sql -Database $ProviderDatabase -Sql @"
SELECT COALESCE((
    SELECT active::text || ':' || confirmed_flush_lsn::text
    FROM pg_replication_slots
    WHERE slot_name = $(ConvertTo-SqlLiteral $slotName)
), '<missing>')
"@
        }

        $last = "status=$statusValue slot=$slotName sync=$sync sync_ready=$syncReady provider_slot=$slotStatus"
        if ($statusValue -eq 'replicating' -and $syncReady -eq 'true' -and $slotStatus.StartsWith('true:')) {
            return $slotName
        }

        Start-Sleep -Milliseconds 250
    }

    throw "timed out waiting for pglogical subscription $SubscriptionName readiness on ${SubscriberDatabase}: $last"
}

function Wait-SqlEquals {
    param(
        [string] $Database,
        [string] $Sql,
        [string] $Expected,
        [int] $TimeoutSeconds
    )

    $deadline = [DateTimeOffset]::Now.AddSeconds($TimeoutSeconds)
    $last = ''

    while ([DateTimeOffset]::Now -lt $deadline) {
        $last = Invoke-Sql -Database $Database -Sql $Sql
        if ($last -eq $Expected) {
            return
        }

        Start-Sleep -Milliseconds 250
    }

    throw "timed out waiting for SQL result '$Expected' on ${Database}; last result: $last"
}

function Wait-AdvisoryLockHeld {
    param(
        [string] $Database,
        [int] $ClassId,
        [int] $ObjectId,
        [int] $TimeoutSeconds
    )

    Wait-SqlEquals `
        -Database $Database `
        -Sql "SELECT EXISTS (SELECT 1 FROM pg_locks WHERE locktype = 'advisory' AND classid = $ClassId AND objid = $ObjectId AND granted)::text" `
        -Expected 'true' `
        -TimeoutSeconds $TimeoutSeconds
}

$pgConfig = Get-PgrxPgConfig -PgMajor $PgMajor
$script:InitDb = Get-PglToolPath -PgConfig $pgConfig -Name 'initdb'
$script:PgCtl = Get-PglToolPath -PgConfig $pgConfig -Name 'pg_ctl'
$script:Psql = Get-PglToolPath -PgConfig $pgConfig -Name 'psql'
$script:Port = New-FreePort
$extensionSql = Get-ExtensionSqlPath -PgConfig $pgConfig
$watchdog = Start-CleanupWatchdog -ParentPid $PID -Data $data -PgCtl $script:PgCtl -RemoveData:(-not $KeepData)

try {
    Write-Step "Cleaning prior pglogical fence test cluster"
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

    Write-Step "Initializing test cluster at $data"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $data) | Out-Null
    Invoke-CheckedProcess `
        -FilePath $script:InitDb `
        -Arguments @('--locale=C', '--auth=trust', '--username=postgres', '-D', $data) `
        -TimeoutSeconds 120 | Out-Null

    Write-Step "Starting pglogical-enabled test cluster on port $script:Port"
    $socketOption = Get-PglUnixSocketOption -Directory $target
    $serverOptions = (@(
        "-p $script:Port",
        '-h localhost',
        $socketOption,
        '-c shared_preload_libraries=pglogical',
        '-c wal_level=logical',
        '-c max_worker_processes=20',
        '-c max_replication_slots=20',
        '-c max_wal_senders=20'
    ) | Where-Object { $_ }) -join ' '
    Invoke-CheckedProcess `
        -FilePath $script:PgCtl `
        -Arguments @('start', '-D', $data, '-l', $log, '-o', $serverOptions, '-w', '-t', '30') `
        -TimeoutSeconds 45 | Out-Null

    Write-Step 'Creating coordinator/provider/target databases and extensions'
    Invoke-Sql -Database 'postgres' -Sql 'CREATE DATABASE provider' | Out-Null
    Invoke-Sql -Database 'postgres' -Sql 'CREATE DATABASE target' | Out-Null
    Invoke-Sql -Database 'postgres' -Sql 'CREATE DATABASE degraded' | Out-Null
    Invoke-Sql -Database 'postgres' -Sql 'CREATE DATABASE cascade' | Out-Null
    Invoke-Sql -Database 'postgres' -Sql 'CREATE EXTENSION pgl_validate' | Out-Null

    $providerDsn = "host=localhost port=$script:Port dbname=provider user=postgres connect_timeout=5 application_name=pgl_validate_pglogical"
    $targetDsn = "host=localhost port=$script:Port dbname=target user=postgres connect_timeout=5 application_name=pgl_validate_pglogical"
    $degradedDsn = "host=localhost port=$script:Port dbname=degraded user=postgres connect_timeout=5 application_name=pgl_validate_pglogical"
    $cascadeDsn = "host=localhost port=$script:Port dbname=cascade user=postgres connect_timeout=5 application_name=pgl_validate_pglogical"
    $sequenceProviderDsn = "host=localhost port=$script:Port dbname=seq_provider user=postgres connect_timeout=5 application_name=pgl_validate_pglogical"
    $sequenceTargetDsn = "host=localhost port=$script:Port dbname=seq_target user=postgres connect_timeout=5 application_name=pgl_validate_pglogical"
    $providerDsnSql = ConvertTo-SqlLiteral $providerDsn
    $targetDsnSql = ConvertTo-SqlLiteral $targetDsn
    $degradedDsnSql = ConvertTo-SqlLiteral $degradedDsn
    $cascadeDsnSql = ConvertTo-SqlLiteral $cascadeDsn
    $sequenceProviderDsnSql = ConvertTo-SqlLiteral $sequenceProviderDsn
    $sequenceTargetDsnSql = ConvertTo-SqlLiteral $sequenceTargetDsn

    Write-Step 'Creating pglogical provider node and barrier replication set'
    Invoke-Sql -Database 'provider' -Sql 'CREATE EXTENSION pgl_validate' | Out-Null
    Invoke-Sql -Database 'provider' -Sql 'CREATE EXTENSION pglogical' | Out-Null
    Invoke-Sql -Database 'provider' -Sql "SELECT pglogical.create_node('provider', $providerDsnSql)" | Out-Null
    Invoke-Sql -Database 'provider' -Sql 'SELECT pgl_validate.ensure_pglogical_barrier_repset()' | Out-Null
    Invoke-Sql -Database 'provider' -Sql @"
CREATE TABLE public.accounts(id int PRIMARY KEY, value text);
SELECT pglogical.replication_set_add_table('default', 'public.accounts'::regclass, false);
CREATE TABLE public.truncate_accounts(id int PRIMARY KEY, value text);
SELECT pglogical.create_replication_set('pgl_validate_no_truncate', true, true, true, false);
SELECT pglogical.replication_set_add_table(
    'pgl_validate_no_truncate',
    'public.truncate_accounts'::regclass,
    false
);
"@ | Out-Null

    Write-Step 'Creating pglogical target node and subscription'
    Invoke-Sql -Database 'target' -Sql 'CREATE EXTENSION pgl_validate' | Out-Null
    Invoke-Sql -Database 'target' -Sql 'CREATE EXTENSION pglogical' | Out-Null
    Invoke-Sql -Database 'target' -Sql 'CREATE TABLE public.accounts(id int PRIMARY KEY, value text)' | Out-Null
    Invoke-Sql -Database 'target' -Sql 'CREATE TABLE public.truncate_accounts(id int PRIMARY KEY, value text)' | Out-Null
    Invoke-Sql -Database 'target' -Sql "SELECT pglogical.create_node('target', $targetDsnSql)" | Out-Null
    Invoke-Sql -Database 'target' -Sql @"
SELECT pglogical.create_subscription(
    'sub',
    $providerDsnSql,
    ARRAY['default','pgl_validate_barrier','pgl_validate_no_truncate'],
    false,
    false,
    ARRAY[]::text[]
)
"@ | Out-Null

    Write-Step 'Waiting for pglogical subscription readiness'
    $slotName = Wait-SubscriptionReady -TimeoutSeconds $TimeoutSeconds
    $slotNameSql = ConvertTo-SqlLiteral $slotName

    Write-Step 'Creating degraded pglogical target without the barrier repset'
    Invoke-Sql -Database 'degraded' -Sql 'CREATE EXTENSION pgl_validate' | Out-Null
    Invoke-Sql -Database 'degraded' -Sql 'CREATE EXTENSION pglogical' | Out-Null
    Invoke-Sql -Database 'degraded' -Sql 'CREATE TABLE public.accounts(id int PRIMARY KEY, value text)' | Out-Null
    Invoke-Sql -Database 'degraded' -Sql "SELECT pglogical.create_node('degraded', $degradedDsnSql)" | Out-Null
    Invoke-Sql -Database 'degraded' -Sql @"
SELECT pglogical.create_subscription(
    'sub_degraded',
    $providerDsnSql,
    ARRAY['default'],
    false,
    false,
    ARRAY[]::text[]
)
"@ | Out-Null
    $null = Wait-SubscriptionReady `
        -SubscriberDatabase 'degraded' `
        -SubscriptionName 'sub_degraded' `
        -ProviderDatabase 'provider' `
        -TimeoutSeconds $TimeoutSeconds

    Write-Step 'Replicating user table row for compare_table validation'
    Invoke-Sql -Database 'provider' -Sql "INSERT INTO public.accounts VALUES (1, 'same')" | Out-Null
    Wait-SqlEquals `
        -Database 'target' `
        -Sql 'SELECT count(*)::text FROM public.accounts WHERE id = 1 AND value = ''same''' `
        -Expected '1' `
        -TimeoutSeconds $TimeoutSeconds
    Wait-SqlEquals `
        -Database 'degraded' `
        -Sql 'SELECT count(*)::text FROM public.accounts WHERE id = 1 AND value = ''same''' `
        -Expected '1' `
        -TimeoutSeconds $TimeoutSeconds

    Write-Step "Fencing provider->target edge through slot $slotName"
    $observed = Invoke-Sql -Database 'postgres' -Sql @"
WITH r AS (
    INSERT INTO pgl_validate.run(status)
    VALUES ('fencing')
    RETURNING run_id
), a AS (
    SELECT pgl_validate.fence_pglogical_edge(
        r.run_id,
        1,
        1,
        'provider',
        'target',
        $providerDsnSql,
        $targetDsnSql,
        'sub',
        $slotNameSql,
        $slotNameSql,
        ARRAY['pgl_validate_barrier'],
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
        throw "unexpected fence result: $observed"
    }

    $recorded = Invoke-Sql -Database 'postgres' -Sql @"
SELECT EXISTS (
    SELECT 1
    FROM pgl_validate.fence_edge fe
    JOIN pgl_validate.fence_attempt fa USING (run_id, epoch_seq, edge_id)
    JOIN pgl_validate.fence_barrier_run br USING (run_id, epoch_seq, edge_id)
    WHERE fe.fence_kind = 'barrier'
      AND fa.status = 'converged'
      AND br.origin_node = 'provider'
)::text
"@
    if ($recorded -ne 'true') {
        throw "fence catalog rows were not recorded"
    }

    Write-Step 'Running compare_table through real pglogical fencing'
    Invoke-Sql -Database 'provider' -Sql @"
INSERT INTO pgl_validate.peer(name, dsn, backend, subscription_name, replication_sets)
VALUES ('target', $targetDsnSql, 'pglogical', 'sub', ARRAY['default'])
"@ | Out-Null
    $compareVerdict = Invoke-Sql -Database 'provider' -Sql @"
SELECT (pgl_validate.compare_table(
    'public.accounts'::regclass,
    ARRAY['target'],
    jsonb_build_object(
        'provider_dsn', $providerDsnSql,
        'provider_node', 'provider',
        'repsets', jsonb_build_array('default'),
        'fence_timeout_ms', 30000,
        'fence_poll_interval_ms', 100
    )
)).verdict
"@
    if ($compareVerdict -ne 'match') {
        throw "unexpected compare_table verdict: $compareVerdict"
    }

    $compareFenceRecorded = Invoke-Sql -Database 'provider' -Sql @"
SELECT EXISTS (
    SELECT 1
    FROM pgl_validate.table_result tr
    JOIN pgl_validate.fence_attempt fa USING (run_id)
    WHERE tr.schema_name = 'public'
      AND tr.table_name = 'accounts'
      AND tr.verdict = 'match'
      AND fa.status = 'converged'
)::text
"@
    if ($compareFenceRecorded -ne 'true') {
        throw 'compare_table did not record a converged fence'
    }

    Write-Step 'Re-fencing the recorded pglogical edge vector'
    Invoke-Sql -Database 'provider' -Sql @"
DO `$pgl_validate_re_fence`$
DECLARE
    v_run_id bigint;
    v_epoch int;
    v_edges int;
BEGIN
    SELECT tr.run_id
    INTO v_run_id
    FROM pgl_validate.table_result tr
    WHERE tr.schema_name = 'public'
      AND tr.table_name = 'accounts'
      AND tr.verdict = 'match'
    ORDER BY tr.run_id DESC
    LIMIT 1;

    SELECT COALESCE(max(fe.epoch_seq), 0) + 1
    INTO v_epoch
    FROM pgl_validate.fence_epoch fe
    WHERE fe.run_id = v_run_id;

    SELECT pgl_validate.re_fence_run_edges(
        v_run_id,
        v_epoch,
        'provider',
        $providerDsnSql,
        NULL,
        30000,
        100
    )
    INTO v_edges;

    IF v_edges <> 1 THEN
        RAISE EXCEPTION 'expected one pglogical edge to be re-fenced, got %', v_edges;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pgl_validate.fence_attempt fa
        WHERE fa.run_id = v_run_id
          AND fa.epoch_seq = v_epoch
          AND fa.status = 'converged'
    ) THEN
        RAISE EXCEPTION 're-fenced pglogical edge did not converge';
    END IF;
END
`$pgl_validate_re_fence`$;
"@ | Out-Null

    Write-Step 'Validating pglogical non-replicated TRUNCATE semantics'
    Invoke-Sql -Database 'provider' -Sql "INSERT INTO public.truncate_accounts VALUES (1, 'left-behind')" | Out-Null
    Wait-SqlEquals `
        -Database 'target' `
        -Sql "SELECT count(*)::text FROM public.truncate_accounts WHERE id = 1 AND value = 'left-behind'" `
        -Expected '1' `
        -TimeoutSeconds $TimeoutSeconds
    Invoke-Sql -Database 'provider' -Sql 'TRUNCATE public.truncate_accounts' | Out-Null
    Wait-SqlEquals `
        -Database 'provider' `
        -Sql 'SELECT count(*)::text FROM public.truncate_accounts' `
        -Expected '0' `
        -TimeoutSeconds $TimeoutSeconds
    Wait-SqlEquals `
        -Database 'target' `
        -Sql 'SELECT count(*)::text FROM public.truncate_accounts' `
        -Expected '1' `
        -TimeoutSeconds $TimeoutSeconds

    $truncateResult = Invoke-Sql -Database 'provider' -Sql @"
SELECT run_id::text || ';' || verdict
FROM pgl_validate.compare_table(
    'public.truncate_accounts'::regclass,
    ARRAY['target'],
    jsonb_build_object(
        'provider_dsn', $providerDsnSql,
        'provider_node', 'provider',
        'repsets', jsonb_build_array('pgl_validate_no_truncate'),
        'fence_timeout_ms', 30000,
        'fence_poll_interval_ms', 100
    )
)
"@
    $truncateParts = $truncateResult.Split(';', 2)
    if ($truncateParts.Count -ne 2) {
        throw "unexpected no-truncate compare_table result: $truncateResult"
    }
    $truncateRunId = $truncateParts[0]
    $truncateVerdict = $truncateParts[1]
    if ($truncateVerdict -ne 'match') {
        throw "unexpected no-truncate compare_table verdict: $truncateVerdict"
    }

    $truncateAdvisory = Invoke-Sql -Database 'provider' -Sql @"
SELECT tp.validated_property || ';' ||
       tp.repl_truncate::text || ';' ||
       d.classification || ';' ||
       d.status || ';' ||
       tr.verdict
FROM pgl_validate.table_plan tp
JOIN pgl_validate.table_result tr USING (run_id, schema_name, table_name)
JOIN pgl_validate.divergence d USING (run_id, schema_name, table_name)
WHERE tp.run_id = $truncateRunId
  AND d.node = 'target'
"@
    if ($truncateAdvisory -ne 'superset;false;extra_on;advisory;match') {
        throw "pglogical non-replicated TRUNCATE extra row was not advisory: $truncateAdvisory"
    }

    Write-Step 'Validating bidirectional pglogical fence vector'
    Invoke-Sql -Database 'target' -Sql 'SELECT pgl_validate.ensure_pglogical_barrier_repset()' | Out-Null
    Invoke-Sql -Database 'provider' -Sql @"
CREATE TABLE public.bidir_accounts(id int PRIMARY KEY, value text);
SELECT pglogical.create_replication_set('pgl_validate_bidir');
SELECT pglogical.replication_set_add_table('pgl_validate_bidir', 'public.bidir_accounts'::regclass, false);
"@ | Out-Null
    Invoke-Sql -Database 'target' -Sql @"
CREATE TABLE public.bidir_accounts(id int PRIMARY KEY, value text);
SELECT pglogical.create_replication_set('pgl_validate_bidir');
SELECT pglogical.replication_set_add_table('pgl_validate_bidir', 'public.bidir_accounts'::regclass, false);
SELECT pglogical.alter_subscription_add_replication_set('sub', 'pgl_validate_bidir');
"@ | Out-Null
    Invoke-Sql -Database 'provider' -Sql @"
SELECT pglogical.create_subscription(
    'sub_from_target',
    $targetDsnSql,
    ARRAY['pgl_validate_bidir','pgl_validate_barrier'],
    false,
    true,
    ARRAY[]::text[]
)
"@ | Out-Null
    $reverseSlotName = Wait-SubscriptionReady `
        -SubscriberDatabase 'provider' `
        -SubscriptionName 'sub_from_target' `
        -ProviderDatabase 'target' `
        -TimeoutSeconds $TimeoutSeconds
    Wait-SqlEquals `
        -Database 'provider' `
        -Sql "SELECT COALESCE((SELECT left(status, 1) FROM pglogical.show_subscription_table('sub_from_target'::name, 'public.bidir_accounts'::regclass)), '<missing>')" `
        -Expected 'r' `
        -TimeoutSeconds $TimeoutSeconds

    Invoke-Sql -Database 'provider' -Sql @"
UPDATE pgl_validate.peer
SET replication_sets = ARRAY['pgl_validate_bidir'],
    reverse_subscription_name = 'sub_from_target'
WHERE name = 'target'
"@ | Out-Null
    $bidirectionalResult = Invoke-Sql -Database 'provider' -Sql @"
SELECT run_id::text || ';' || verdict
FROM pgl_validate.compare_table(
    'public.bidir_accounts'::regclass,
    ARRAY['target'],
    jsonb_build_object(
        'provider_dsn', $providerDsnSql,
        'provider_node', 'provider',
        'repsets', jsonb_build_array('pgl_validate_bidir'),
        'fence_timeout_ms', 30000,
        'fence_poll_interval_ms', 100
    )
)
"@
    $bidirectionalParts = $bidirectionalResult.Split(';', 2)
    if ($bidirectionalParts.Count -ne 2) {
        throw "unexpected bidirectional compare_table result: $bidirectionalResult"
    }
    $bidirectionalRunId = $bidirectionalParts[0]
    $bidirectionalVerdict = $bidirectionalParts[1]
    if ($bidirectionalVerdict -ne 'match') {
        throw "unexpected bidirectional compare_table verdict: $bidirectionalVerdict"
    }

    $bidirectionalFenceShape = Invoke-Sql -Database 'provider' -Sql @"
SELECT
    count(*) FILTER (
        WHERE re.provider_node = 'provider'
          AND re.target_node = 'target'
          AND fa.status = 'converged'
    )::text || ';' ||
    count(*) FILTER (
        WHERE re.provider_node = 'target'
          AND re.target_node = 'provider'
          AND fa.status = 'converged'
    )::text || ';' ||
    count(*) FILTER (
        WHERE br.origin_node = 'target'
    )::text
FROM pgl_validate.run_edge re
JOIN pgl_validate.fence_attempt fa USING (run_id, edge_id)
LEFT JOIN pgl_validate.fence_barrier_run br USING (run_id, epoch_seq, edge_id)
WHERE re.run_id = $bidirectionalRunId
  AND re.backend = 'pglogical'
  AND fa.epoch_seq = 1
"@
    if ($bidirectionalFenceShape -ne '1;1;1') {
        throw "bidirectional pglogical fence vector was not recorded: $bidirectionalFenceShape using reverse slot $reverseSlotName"
    }
    Invoke-Sql -Database 'provider' -Sql @"
UPDATE pgl_validate.peer
SET replication_sets = ARRAY['default'],
    reverse_subscription_name = NULL
WHERE name = 'target'
"@ | Out-Null

    Write-Step 'Validating pglogical mid-sync table is skipped before fencing'
    $pglogicalOriginalSync = Invoke-Sql -Database 'target' -Sql @"
SELECT COALESCE((
    SELECT sync_status::text
    FROM pglogical.local_sync_status lss
    JOIN pglogical.subscription s ON s.sub_id = lss.sync_subid
    WHERE s.sub_name = 'sub'::name
      AND lss.sync_nspname = 'public'::name
      AND lss.sync_relname = 'accounts'::name
), '<missing>')
"@
    $pglogicalSyncMarked = Invoke-Sql -Database 'target' -Sql @"
WITH sub AS (
    SELECT sub_id
    FROM pglogical.subscription
    WHERE sub_name = 'sub'::name
), upserted AS (
    INSERT INTO pglogical.local_sync_status(
        sync_kind,
        sync_subid,
        sync_nspname,
        sync_relname,
        sync_status,
        sync_statuslsn
    )
    SELECT
        'd'::"char",
        sub_id,
        'public'::name,
        'accounts'::name,
        'd'::"char",
        pg_current_wal_lsn()
    FROM sub
    ON CONFLICT (sync_subid, sync_nspname, sync_relname)
    DO UPDATE
    SET sync_status = 'd'::"char",
        sync_statuslsn = EXCLUDED.sync_statuslsn
    RETURNING 1
)
SELECT count(*)::text FROM upserted
"@
    if ($pglogicalSyncMarked -ne '1') {
        throw "could not mark pglogical table sync status as d: $pglogicalSyncMarked"
    }

    $midSyncResult = Invoke-Sql -Database 'provider' -Sql @"
SELECT run_id::text || ';' || verdict || ';' || reason
FROM pgl_validate.compare_table(
    'public.accounts'::regclass,
    ARRAY['target'],
    jsonb_build_object(
        'provider_dsn', $providerDsnSql,
        'provider_node', 'provider',
        'repsets', jsonb_build_array('default'),
        'fence_timeout_ms', 30000,
        'fence_poll_interval_ms', 100
    )
)
"@
    $midSyncParts = $midSyncResult.Split(';', 3)
    if ($midSyncParts.Count -ne 3) {
        throw "unexpected pglogical mid-sync compare_table result: $midSyncResult"
    }
    $midSyncRunId = $midSyncParts[0]
    $midSyncVerdict = $midSyncParts[1]
    $midSyncReason = $midSyncParts[2]
    if ($midSyncVerdict -ne 'partial' -or -not $midSyncReason.Contains('sync_status=d')) {
        throw "pglogical mid-sync table was not reported as partial/skipped: $midSyncResult"
    }

    $pglogicalSyncEvidence = Invoke-Sql -Database 'provider' -Sql @"
SELECT
    EXISTS (
        SELECT 1
        FROM pgl_validate.run_participant
        WHERE run_id = $midSyncRunId
          AND node = 'target'
          AND status = 'skipped'
    )::text || ';' ||
    EXISTS (
        SELECT 1
        FROM pgl_validate.schema_issue
        WHERE run_id = $midSyncRunId
          AND node = 'target'
          AND issue_code = 'SYNC_NOT_READY'
          AND detail LIKE '%sync_status=d%'
    )::text || ';' ||
    EXISTS (
        SELECT 1
        FROM pgl_validate.table_result
        WHERE run_id = $midSyncRunId
          AND verdict = 'partial'
          AND reason LIKE '%sync_status=d%'
    )::text
"@
    if ($pglogicalSyncEvidence -ne 'true;true;true') {
        throw "pglogical mid-sync skip evidence was incomplete: $pglogicalSyncEvidence"
    }

    if ($pglogicalOriginalSync -eq '<missing>') {
        Invoke-Sql -Database 'target' -Sql @"
DELETE FROM pglogical.local_sync_status lss
USING pglogical.subscription s
WHERE s.sub_id = lss.sync_subid
  AND s.sub_name = 'sub'::name
  AND lss.sync_nspname = 'public'::name
  AND lss.sync_relname = 'accounts'::name
"@ | Out-Null
    } else {
        Invoke-Sql -Database 'target' -Sql @"
UPDATE pglogical.local_sync_status lss
SET sync_status = 'r'
FROM pglogical.subscription s
WHERE s.sub_id = lss.sync_subid
  AND s.sub_name = 'sub'::name
  AND lss.sync_nspname = 'public'::name
  AND lss.sync_relname = 'accounts'::name
"@ | Out-Null
    }

    Write-Step 'Validating explicit degraded pglogical fence path'
    Invoke-Sql -Database 'provider' -Sql @"
INSERT INTO pgl_validate.peer(name, dsn, backend, subscription_name, replication_sets)
VALUES ('degraded', $degradedDsnSql, 'pglogical', 'sub_degraded', ARRAY['default'])
"@ | Out-Null
    $degradedResult = Invoke-Sql -Database 'provider' -Sql @"
SELECT run_id::text || ';' || verdict
FROM pgl_validate.compare_table(
    'public.accounts'::regclass,
    ARRAY['degraded'],
    jsonb_build_object(
        'provider_dsn', $providerDsnSql,
        'provider_node', 'provider',
        'repsets', jsonb_build_array('default'),
        'allow_degraded_fence', true,
        'fence_timeout_ms', 30000,
        'fence_poll_interval_ms', 100
    )
)
"@
    $degradedParts = $degradedResult.Split(';', 2)
    if ($degradedParts.Count -ne 2) {
        throw "unexpected degraded compare_table result: $degradedResult"
    }
    $degradedRunId = $degradedParts[0]
    $degradedVerdict = $degradedParts[1]
    if ($degradedVerdict -ne 'degraded') {
        throw "unexpected degraded compare_table verdict: $degradedVerdict"
    }

    $degradedFenceRecorded = Invoke-Sql -Database 'provider' -Sql @"
SELECT EXISTS (
    SELECT 1
    FROM pgl_validate.fence_edge fe
    JOIN pgl_validate.fence_attempt fa USING (run_id, epoch_seq, edge_id)
    WHERE fe.run_id = $degradedRunId
      AND fe.fence_kind = 'degraded'
      AND fa.status = 'degraded'
      AND fa.confirmed_flush_lsn >= fa.barrier_end_lsn
)::text
"@
    if ($degradedFenceRecorded -ne 'true') {
        throw 'degraded fence catalog rows were not recorded'
    }
    Invoke-Sql -Database 'degraded' -Sql "SELECT pglogical.alter_subscription_disable('sub_degraded', true)" | Out-Null

    Write-Step 'Validating pglogical row-filter intersection semantics'
    Invoke-Sql -Database 'provider' -Sql @"
CREATE TABLE public.filtered_accounts(
    id int PRIMARY KEY,
    include_row boolean NOT NULL,
    value text
);
SELECT pglogical.replication_set_add_table(
    'default',
    'public.filtered_accounts'::regclass,
    false,
    NULL,
    'include_row'
);
"@ | Out-Null
    Invoke-Sql -Database 'target' -Sql @"
CREATE TABLE public.filtered_accounts(
    id int PRIMARY KEY,
    include_row boolean NOT NULL,
    value text
)
"@ | Out-Null
    Invoke-Sql -Database 'provider' -Sql @"
INSERT INTO public.filtered_accounts VALUES
    (1, true, 'same'),
    (6, false, 'outside-filter');
UPDATE public.filtered_accounts
SET include_row = true,
    value = 'entered-filter'
WHERE id = 6;
"@ | Out-Null
    Wait-SqlEquals `
        -Database 'target' `
        -Sql 'SELECT count(*)::text FROM public.filtered_accounts WHERE id = 1 AND include_row AND value = ''same''' `
        -Expected '1' `
        -TimeoutSeconds $TimeoutSeconds

    $filteredVerdict = Invoke-Sql -Database 'provider' -Sql @"
SELECT (pgl_validate.compare_table(
    'public.filtered_accounts'::regclass,
    ARRAY['target'],
    jsonb_build_object(
        'provider_dsn', $providerDsnSql,
        'provider_node', 'provider',
        'repsets', jsonb_build_array('default'),
        'fence_timeout_ms', 30000,
        'fence_poll_interval_ms', 100
    )
)).verdict
"@
    if ($filteredVerdict -ne 'match') {
        throw "unexpected filtered compare_table verdict: $filteredVerdict"
    }

    $filteredAdvisory = Invoke-Sql -Database 'provider' -Sql @"
SELECT EXISTS (
    SELECT 1
    FROM pgl_validate.divergence d
    JOIN pgl_validate.table_result tr USING (run_id, schema_name, table_name)
    WHERE d.schema_name = 'public'
      AND d.table_name = 'filtered_accounts'
      AND d.node = 'target'
      AND d.classification = 'missing_on'
      AND d.status = 'advisory'
      AND tr.verdict = 'match'
)::text
"@
    if ($filteredAdvisory -ne 'true') {
        throw 'pglogical filtered-table presence difference was not recorded as advisory'
    }

    Write-Step 'Validating post-fence provider UPDATE is cleared by digest-stability recheck'
    $clearedTimeoutSeconds = [Math]::Min($TimeoutSeconds, 30)
    Invoke-Sql -Database 'provider' -Sql @"
CREATE FUNCTION public.pgl_validate_recheck_gate(i int)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
AS `$pgl_validate_gate`$
DECLARE
    app_name text := current_setting('application_name', true);
    call_no int;
    lock_object int;
    trigger_call int;
BEGIN
    SELECT signal_lock, signal_call
    INTO lock_object, trigger_call
    FROM (VALUES
        ('pgl_validate_recheck_update'::text, 2, 2),
        ('pgl_validate_recheck_delete'::text, 3, 3)
    ) AS locks(name, signal_lock, signal_call)
    WHERE name = app_name;

    IF lock_object IS NULL THEN
        RETURN true;
    END IF;

    call_no := COALESCE(NULLIF(current_setting('pgl_validate.recheck_gate_calls', true), '')::int, 0) + 1;
    PERFORM set_config('pgl_validate.recheck_gate_calls', call_no::text, false);
    IF call_no = trigger_call THEN
        PERFORM pg_advisory_lock(76422, lock_object);
        PERFORM pg_sleep(4);
        PERFORM pg_advisory_unlock(76422, lock_object);
    END IF;
    RETURN true;
END
`$pgl_validate_gate`$;
CREATE TABLE public.post_fence_update_accounts(
    id int PRIMARY KEY,
    value text
);
SELECT pglogical.replication_set_add_table(
    'default',
    'public.post_fence_update_accounts'::regclass,
    false,
    NULL,
    'public.pgl_validate_recheck_gate(id)'
);
"@ | Out-Null
    Invoke-Sql -Database 'target' -Sql @"
CREATE TABLE public.post_fence_update_accounts(
    id int PRIMARY KEY,
    value text
)
"@ | Out-Null
    Invoke-Sql -Database 'provider' -Sql "INSERT INTO public.post_fence_update_accounts VALUES (1, 'before-update')" | Out-Null
    Wait-SqlEquals `
        -Database 'target' `
        -Sql "SELECT value FROM public.post_fence_update_accounts WHERE id = 1" `
        -Expected 'before-update' `
        -TimeoutSeconds $TimeoutSeconds
    Invoke-Sql -Database 'target' -Sql "UPDATE public.post_fence_update_accounts SET value = 'after-update' WHERE id = 1" | Out-Null

    $clearedCompareSql = @"
SET application_name = 'pgl_validate_recheck_update';
SET pgl_validate.recheck_gate_calls = '0';
SELECT run_id::text || ';' || verdict
FROM pgl_validate.compare_table(
    'public.post_fence_update_accounts'::regclass,
    ARRAY['target'],
    jsonb_build_object(
        'provider_dsn', $providerDsnSql,
        'provider_node', 'provider',
        'repsets', jsonb_build_array('default'),
        'recheck_passes', 2,
        'fence_timeout_ms', 30000,
        'fence_poll_interval_ms', 100
    )
)
"@
    $clearedProcess = Start-AsyncSql -Database 'provider' -Sql $clearedCompareSql
    try {
        Wait-AdvisoryLockHeld `
            -Database 'provider' `
            -ClassId 76422 `
            -ObjectId 2 `
            -TimeoutSeconds $clearedTimeoutSeconds

        Invoke-Sql -Database 'provider' -Sql "UPDATE public.post_fence_update_accounts SET value = 'after-update' WHERE id = 1" | Out-Null
        Wait-SqlEquals `
            -Database 'target' `
            -Sql "SELECT value FROM public.post_fence_update_accounts WHERE id = 1" `
            -Expected 'after-update' `
            -TimeoutSeconds $clearedTimeoutSeconds

        $clearedResult = Wait-AsyncSql `
            -Process $clearedProcess `
            -TimeoutSeconds $clearedTimeoutSeconds `
            -Context 'post-fence UPDATE compare_table'
    }
    finally {
        if ($clearedProcess -and -not $clearedProcess.HasExited) {
            Stop-ProcessTree -ProcessId $clearedProcess.Id
        }
    }

    $clearedParts = $clearedResult.Split(';', 2)
    if ($clearedParts.Count -ne 2) {
        throw "unexpected post-fence UPDATE compare_table result: $clearedResult"
    }
    $clearedRunId = $clearedParts[0]
    $clearedVerdict = $clearedParts[1]
    if ($clearedVerdict -ne 'match') {
        throw "post-fence UPDATE should clear to match after recheck, saw: $clearedResult"
    }

    $clearedEvidence = Invoke-Sql -Database 'provider' -Sql @"
SELECT d.classification || ';' ||
       d.status || ';' ||
       dr.outcome || ';' ||
       tr.verdict || ';' ||
       tp.validated_property
FROM pgl_validate.divergence d
JOIN pgl_validate.divergence_recheck dr USING (run_id, schema_name, table_name, key_bytes, node)
JOIN pgl_validate.table_result tr USING (run_id, schema_name, table_name)
JOIN pgl_validate.table_plan tp USING (run_id, schema_name, table_name)
WHERE d.run_id = $clearedRunId
  AND d.schema_name = 'public'
  AND d.table_name = 'post_fence_update_accounts'
  AND d.node = 'target'
"@
    if ($clearedEvidence -ne 'differs;cleared;cleared;match;filtered_intersection') {
        throw "post-fence UPDATE did not persist a cleared recheck outcome: $clearedEvidence"
    }

    Write-Step 'Validating post-fence provider DELETE is cleared by digest-stability recheck'
    Invoke-Sql -Database 'provider' -Sql @"
CREATE TABLE public.post_fence_delete_accounts(
    id int PRIMARY KEY,
    value text
);
SELECT pglogical.replication_set_add_table(
    'default',
    'public.post_fence_delete_accounts'::regclass,
    false,
    NULL,
    'public.pgl_validate_recheck_gate(id)'
);
"@ | Out-Null
    Invoke-Sql -Database 'target' -Sql @"
CREATE TABLE public.post_fence_delete_accounts(
    id int PRIMARY KEY,
    value text
)
"@ | Out-Null
    Invoke-Sql -Database 'provider' -Sql "INSERT INTO public.post_fence_delete_accounts VALUES (1, 'before-delete')" | Out-Null
    Wait-SqlEquals `
        -Database 'target' `
        -Sql "SELECT value FROM public.post_fence_delete_accounts WHERE id = 1" `
        -Expected 'before-delete' `
        -TimeoutSeconds $TimeoutSeconds
    Invoke-Sql -Database 'target' -Sql "UPDATE public.post_fence_delete_accounts SET value = 'target-delete-drift' WHERE id = 1" | Out-Null

    $deleteCompareSql = @"
SET application_name = 'pgl_validate_recheck_delete';
SET pgl_validate.recheck_gate_calls = '0';
SELECT run_id::text || ';' || verdict
FROM pgl_validate.compare_table(
    'public.post_fence_delete_accounts'::regclass,
    ARRAY['target'],
    jsonb_build_object(
        'provider_dsn', $providerDsnSql,
        'provider_node', 'provider',
        'repsets', jsonb_build_array('default'),
        'recheck_passes', 2,
        'fence_timeout_ms', 30000,
        'fence_poll_interval_ms', 100
    )
)
"@
    $deleteProcess = Start-AsyncSql -Database 'provider' -Sql $deleteCompareSql
    try {
        Wait-AdvisoryLockHeld `
            -Database 'provider' `
            -ClassId 76422 `
            -ObjectId 3 `
            -TimeoutSeconds $clearedTimeoutSeconds

        Invoke-Sql -Database 'provider' -Sql "DELETE FROM public.post_fence_delete_accounts WHERE id = 1" | Out-Null
        Wait-SqlEquals `
            -Database 'target' `
            -Sql "SELECT count(*)::text FROM public.post_fence_delete_accounts WHERE id = 1" `
            -Expected '0' `
            -TimeoutSeconds $clearedTimeoutSeconds

        $deleteResult = Wait-AsyncSql `
            -Process $deleteProcess `
            -TimeoutSeconds $clearedTimeoutSeconds `
            -Context 'post-fence DELETE compare_table'
    }
    finally {
        if ($deleteProcess -and -not $deleteProcess.HasExited) {
            Stop-ProcessTree -ProcessId $deleteProcess.Id
        }
    }

    $deleteParts = $deleteResult.Split(';', 2)
    if ($deleteParts.Count -ne 2) {
        throw "unexpected post-fence DELETE compare_table result: $deleteResult"
    }
    $deleteRunId = $deleteParts[0]
    $deleteVerdict = $deleteParts[1]
    if ($deleteVerdict -ne 'match') {
        throw "post-fence DELETE should clear to match after recheck, saw: $deleteResult"
    }

    $deleteCleared = Invoke-Sql -Database 'provider' -Sql @"
SELECT EXISTS (
    SELECT 1
    FROM pgl_validate.divergence d
    JOIN pgl_validate.divergence_recheck dr USING (run_id, schema_name, table_name, key_bytes, node)
    JOIN pgl_validate.table_result tr USING (run_id, schema_name, table_name)
    JOIN pgl_validate.table_plan tp USING (run_id, schema_name, table_name)
    WHERE d.run_id = $deleteRunId
      AND d.schema_name = 'public'
      AND d.table_name = 'post_fence_delete_accounts'
      AND d.node = 'target'
      AND d.classification IN ('differs', 'missing_on')
      AND d.status = 'cleared'
      AND tr.verdict = 'match'
      AND tp.validated_property = 'filtered_intersection'
    GROUP BY d.run_id, d.schema_name, d.table_name, d.key_bytes, d.node
    HAVING bool_or(dr.outcome = 'cleared')
)::text
"@
    if ($deleteCleared -ne 'true') {
        $deleteEvidence = Invoke-Sql -Database 'provider' -Sql @"
SELECT d.classification || ';' ||
       d.status || ';' ||
       dr.outcome || ';' ||
       tr.verdict || ';' ||
       tp.validated_property
FROM pgl_validate.divergence d
JOIN pgl_validate.divergence_recheck dr USING (run_id, schema_name, table_name, key_bytes, node)
JOIN pgl_validate.table_result tr USING (run_id, schema_name, table_name)
JOIN pgl_validate.table_plan tp USING (run_id, schema_name, table_name)
WHERE d.run_id = $deleteRunId
  AND d.schema_name = 'public'
  AND d.table_name = 'post_fence_delete_accounts'
  AND d.node = 'target'
"@
        throw "post-fence DELETE did not persist a cleared recheck outcome: $deleteEvidence"
    }

    Write-Step 'Creating subscriber-side drift and applying audited pglogical repair'
    Invoke-Sql -Database 'target' -Sql "UPDATE public.accounts SET value = 'target-drift' WHERE id = 1" | Out-Null
    Invoke-Sql -Database 'target' -Sql @"
SELECT pglogical.conflict_history_ensure_partition(CURRENT_DATE);
INSERT INTO pglogical.conflict_history(
    sub_id, sub_name, conflict_type, resolution,
    schema_name, table_name, index_name,
    local_tuple, remote_tuple,
    remote_origin, remote_commit_ts, remote_commit_lsn
)
SELECT
    s.sub_id,
    s.sub_name,
    'update_update',
    'keep_local',
    'public',
    'accounts',
    'accounts_pkey',
    '{"id": 1, "value": "target-drift"}'::jsonb,
    '{"id": 1, "value": "same"}'::jsonb,
    1,
    now(),
    pg_current_wal_lsn()
FROM pglogical.subscription AS s
WHERE s.sub_name = 'sub';
"@ | Out-Null
    $repairableDriftResult = Invoke-Sql -Database 'provider' -Sql @"
SELECT run_id::text || ';' || verdict
FROM pgl_validate.compare_table(
    'public.accounts'::regclass,
    ARRAY['target'],
    jsonb_build_object(
        'provider_dsn', $providerDsnSql,
        'provider_node', 'provider',
        'repsets', jsonb_build_array('default'),
        'fence_timeout_ms', 30000,
        'fence_poll_interval_ms', 100
    )
)
"@
    $repairableDriftParts = $repairableDriftResult.Split(';', 2)
    if ($repairableDriftParts.Count -ne 2) {
        throw "unexpected repairable drift compare_table result: $repairableDriftResult"
    }
    $repairableDriftRunId = $repairableDriftParts[0]
    $repairableDriftVerdict = $repairableDriftParts[1]
    if ($repairableDriftVerdict -ne 'differ') {
        throw "unexpected repairable drift compare_table verdict: $repairableDriftVerdict"
    }

    $conflictEvidence = Invoke-Sql -Database 'provider' -Sql @"
SELECT count(*)::text || ';' ||
       COALESCE(min(conflict_type), '<none>') || ';' ||
       COALESCE(min(resolution), '<none>') || ';' ||
       COALESCE(bool_or('local_tuple_key' = ANY(matched_on))::text, 'false') || ';' ||
       COALESCE(bool_or('remote_tuple_key' = ANY(matched_on))::text, 'false')
FROM pgl_validate.conflict_evidence($repairableDriftRunId)
WHERE node = 'target'
"@
    if ($conflictEvidence -ne '1;update_update;keep_local;true;true') {
        throw "unexpected pglogical conflict-history evidence: $conflictEvidence"
    }

    $reportConflictEvidence = Invoke-Sql -Database 'provider' -Sql @"
SELECT (jsonb_array_length(
    pgl_validate.report($repairableDriftRunId)
        -> 'tables' -> 0
        -> 'divergences' -> 0
        -> 'conflict_evidence'
) = 1)::text
"@
    if ($reportConflictEvidence -ne 'true') {
        throw "pglogical conflict-history evidence was not included in report()"
    }

    $repairResult = Invoke-Sql -Database 'provider' -Sql @"
SELECT repair_id::text || ';' || status
FROM pgl_validate.apply_repair($repairableDriftRunId, 'local', 'target', 'target')
"@
    $repairParts = $repairResult.Split(';', 2)
    if ($repairParts.Count -ne 2) {
        throw "unexpected repair result: $repairResult"
    }
    $repairId = $repairParts[0]
    $repairStatus = $repairParts[1]
    if ($repairStatus -ne 'revalidated') {
        throw "unexpected repair status: $repairResult"
    }

    $repairAudit = Invoke-Sql -Database 'provider' -Sql @"
SELECT COALESCE(string_agg(action || ':' || post_verdict, ',' ORDER BY action), '<none>')
FROM pgl_validate.repair_result
WHERE repair_id = $repairId
"@
    if ($repairAudit -ne 'update:match') {
        throw "unexpected repair audit actions: $repairAudit"
    }

    $repairedVerdict = Invoke-Sql -Database 'provider' -Sql @"
SELECT (pgl_validate.compare_table(
    'public.accounts'::regclass,
    ARRAY['target'],
    jsonb_build_object(
        'provider_dsn', $providerDsnSql,
        'provider_node', 'provider',
        'repsets', jsonb_build_array('default'),
        'fence_timeout_ms', 30000,
        'fence_poll_interval_ms', 100
    )
)).verdict
"@
    if ($repairedVerdict -ne 'match') {
        throw "unexpected post-repair compare_table verdict: $repairedVerdict"
    }

    Write-Step 'Creating subscriber-side drift and confirming key-level divergence'
    Invoke-Sql -Database 'target' -Sql "UPDATE public.accounts SET value = 'target-drift' WHERE id = 1" | Out-Null
    $driftResult = Invoke-Sql -Database 'provider' -Sql @"
SELECT run_id::text || ';' || verdict
FROM pgl_validate.compare_table(
    'public.accounts'::regclass,
    ARRAY['target'],
    jsonb_build_object(
        'provider_dsn', $providerDsnSql,
        'provider_node', 'provider',
        'repsets', jsonb_build_array('default'),
        'fence_timeout_ms', 30000,
        'fence_poll_interval_ms', 100
    )
)
"@
    $driftParts = $driftResult.Split(';', 2)
    if ($driftParts.Count -ne 2) {
        throw "unexpected drift compare_table result: $driftResult"
    }
    $driftRunId = $driftParts[0]
    $driftVerdict = $driftParts[1]
    if ($driftVerdict -ne 'differ') {
        throw "unexpected drift compare_table verdict: $driftVerdict"
    }

    $confirmedDrift = Invoke-Sql -Database 'provider' -Sql @"
SELECT EXISTS (
    SELECT 1
    FROM pgl_validate.divergence d
    JOIN pgl_validate.table_result tr USING (run_id, schema_name, table_name)
    JOIN pgl_validate.divergence_recheck dr USING (run_id, schema_name, table_name, key_bytes, node)
    WHERE d.schema_name = 'public'
      AND d.table_name = 'accounts'
      AND d.run_id = $driftRunId
      AND d.node = 'target'
      AND d.classification = 'differs'
      AND d.status = 'confirmed'
      AND dr.outcome = 'still_differs'
      AND tr.verdict = 'differ'
)::text
"@
    if ($confirmedDrift -ne 'true') {
        throw 'subscriber-side drift was not persisted as a confirmed divergence'
    }

    $driftRecheckShape = Invoke-Sql -Database 'provider' -Sql @"
SELECT count(*)::text || ';' || min(epoch_seq)::text || ';' || max(epoch_seq)::text
FROM pgl_validate.divergence_recheck
WHERE run_id = $driftRunId
  AND schema_name = 'public'
  AND table_name = 'accounts'
  AND node = 'target'
"@
    if ($driftRecheckShape -ne '1;2;2') {
        throw "stable drift should confirm after one recheck epoch, saw: $driftRecheckShape"
    }

    Write-Step 'Creating pglogical cascade node with forward_origins={all} for repair guard validation'
    Invoke-Sql -Database 'target' -Sql 'SELECT pgl_validate.ensure_pglogical_barrier_repset()' | Out-Null
    Invoke-Sql -Database 'target' -Sql "SELECT pglogical.replication_set_add_table('default', 'public.accounts'::regclass, false)" | Out-Null
    Invoke-Sql -Database 'cascade' -Sql 'CREATE EXTENSION pgl_validate' | Out-Null
    Invoke-Sql -Database 'cascade' -Sql 'CREATE EXTENSION pglogical' | Out-Null
    Invoke-Sql -Database 'cascade' -Sql 'CREATE TABLE public.accounts(id int PRIMARY KEY, value text)' | Out-Null
    Invoke-Sql -Database 'cascade' -Sql "INSERT INTO public.accounts VALUES (1, 'target-drift')" | Out-Null
    Invoke-Sql -Database 'cascade' -Sql "SELECT pglogical.create_node('cascade', $cascadeDsnSql)" | Out-Null
    Invoke-Sql -Database 'cascade' -Sql @"
SELECT pglogical.create_subscription(
    'sub_from_target',
    $targetDsnSql,
    ARRAY['default','pgl_validate_barrier'],
    false,
    false,
    ARRAY['all']
)
"@ | Out-Null
    $null = Wait-SubscriptionReady `
        -SubscriberDatabase 'cascade' `
        -SubscriptionName 'sub_from_target' `
        -ProviderDatabase 'target' `
        -TimeoutSeconds $TimeoutSeconds

    Invoke-Sql -Database 'provider' -Sql @"
INSERT INTO pgl_validate.peer(name, dsn, backend, subscription_name, replication_sets)
VALUES ('cascade', $cascadeDsnSql, 'pglogical', 'sub_from_target', ARRAY['default'])
"@ | Out-Null

    Write-Step 'Refusing local_only repair while a forward_origins={all} cascade subscription is enabled'
    $blockedRepairResult = Invoke-Sql -Database 'provider' -Sql @"
SELECT repair_id::text || ';' || status
FROM pgl_validate.apply_repair($driftRunId, 'local', 'target', 'target')
"@
    $blockedRepairParts = $blockedRepairResult.Split(';', 2)
    if ($blockedRepairParts.Count -ne 2) {
        throw "unexpected blocked repair result: $blockedRepairResult"
    }
    $blockedRepairId = $blockedRepairParts[0]
    $blockedRepairStatus = $blockedRepairParts[1]
    if ($blockedRepairStatus -ne 'failed') {
        throw "local_only repair was not blocked by downstream forward_origins={all}: $blockedRepairResult"
    }

    $blockedRepairError = Invoke-Sql -Database 'provider' -Sql @"
SELECT COALESCE(error, '<null>')
FROM pgl_validate.repair_run
WHERE repair_id = $blockedRepairId
"@
    if (-not $blockedRepairError.Contains('cascade:sub_from_target')) {
        throw "blocked repair did not identify the forwarding cascade subscription: $blockedRepairError"
    }

    $targetStillDrifted = Invoke-Sql -Database 'target' -Sql "SELECT value FROM public.accounts WHERE id = 1"
    if ($targetStillDrifted -ne 'target-drift') {
        throw "blocked repair unexpectedly modified target row: $targetStillDrifted"
    }

    Write-Step 'Validating pglogical sequence buffer-window semantics in an isolated topology'
    Invoke-Sql -Database 'postgres' -Sql 'CREATE DATABASE seq_provider' | Out-Null
    Invoke-Sql -Database 'postgres' -Sql 'CREATE DATABASE seq_target' | Out-Null
    Invoke-Sql -Database 'seq_provider' -Sql 'CREATE EXTENSION pgl_validate' | Out-Null
    Invoke-Sql -Database 'seq_provider' -Sql 'CREATE EXTENSION pglogical' | Out-Null
    Invoke-Sql -Database 'seq_provider' -Sql "SELECT pglogical.create_node('seq_provider', $sequenceProviderDsnSql)" | Out-Null
    Invoke-Sql -Database 'seq_provider' -Sql 'SELECT pgl_validate.ensure_pglogical_barrier_repset()' | Out-Null
    Invoke-Sql -Database 'seq_provider' -Sql @"
CREATE SEQUENCE public.account_seq CACHE 5;
SELECT pglogical.replication_set_add_sequence(
    'default',
    'public.account_seq'::regclass,
    true
);
"@ | Out-Null
    Invoke-Sql -Database 'seq_target' -Sql 'CREATE EXTENSION pgl_validate' | Out-Null
    Invoke-Sql -Database 'seq_target' -Sql 'CREATE EXTENSION pglogical' | Out-Null
    Invoke-Sql -Database 'seq_target' -Sql 'CREATE SEQUENCE public.account_seq CACHE 5' | Out-Null
    Invoke-Sql -Database 'seq_target' -Sql "SELECT pglogical.create_node('seq_target', $sequenceTargetDsnSql)" | Out-Null
    Invoke-Sql -Database 'seq_target' -Sql @"
SELECT pglogical.create_subscription(
    'seq_sub',
    $sequenceProviderDsnSql,
    ARRAY['default','pgl_validate_barrier'],
    false,
    false,
    ARRAY[]::text[]
)
"@ | Out-Null
    $null = Wait-SubscriptionReady `
        -SubscriberDatabase 'seq_target' `
        -SubscriptionName 'seq_sub' `
        -ProviderDatabase 'seq_provider' `
        -TimeoutSeconds $TimeoutSeconds
    Invoke-Sql -Database 'seq_provider' -Sql @"
INSERT INTO pgl_validate.peer(name, dsn, backend, subscription_name, replication_sets)
VALUES ('seq_target', $sequenceTargetDsnSql, 'pglogical', 'seq_sub', ARRAY['default'])
"@ | Out-Null
    Invoke-Sql -Database 'seq_provider' -Sql @"
SELECT setval('public.account_seq'::regclass, 10, true);
SELECT pglogical.synchronize_sequence('public.account_seq'::regclass);
"@ | Out-Null
    Wait-SqlEquals `
        -Database 'seq_target' `
        -Sql 'SELECT (last_value >= 10)::text FROM public.account_seq' `
        -Expected 'true' `
        -TimeoutSeconds $TimeoutSeconds

    $sequenceVerdict = Invoke-Sql -Database 'seq_provider' -Sql @"
SELECT verdict || ';' || within_contract::text
FROM pgl_validate.compare_sequence(
    'public.account_seq'::regclass,
    ARRAY['seq_target'],
    jsonb_build_object(
        'provider_dsn', $sequenceProviderDsnSql,
        'provider_node', 'seq_provider',
        'fence_timeout_ms', 30000,
        'fence_poll_interval_ms', 100
    )
)
"@
    if ($sequenceVerdict -ne 'match;true') {
        throw "unexpected sequence compare result: $sequenceVerdict"
    }

    Invoke-Sql -Database 'seq_target' -Sql "SELECT setval('public.account_seq'::regclass, 1, true)" | Out-Null
    $sequenceBehind = Invoke-Sql -Database 'seq_provider' -Sql @"
SELECT verdict || ';' || within_contract::text
FROM pgl_validate.compare_sequence(
    'public.account_seq'::regclass,
    ARRAY['seq_target'],
    jsonb_build_object(
        'provider_dsn', $sequenceProviderDsnSql,
        'provider_node', 'seq_provider',
        'fence_timeout_ms', 30000,
        'fence_poll_interval_ms', 100
    )
)
"@
    if ($sequenceBehind -ne 'behind;false') {
        throw "subscriber-behind sequence drift was not detected: $sequenceBehind"
    }

    Write-Output "pglogical fence, compare_table, divergence recheck, audited repair, and cascade repair guard tests passed on pg$PgMajor using slot $slotName"
}
catch {
    if (Test-Path -LiteralPath $log) {
        Write-Output '--- pglogical test log tail ---'
        Get-Content -LiteralPath $log -Tail 120
    }
    throw
}
finally {
    Stop-TestCluster -Data $data -PgCtl $script:PgCtl
    if (-not $KeepData) {
        Remove-TestData -Data $data
    }
    if ($watchdog -and -not $watchdog.HasExited) {
        Stop-ProcessTree -ProcessId $watchdog.Id
    }
}

$global:LASTEXITCODE = 0
