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
$data = Join-Path $target 'native-test-pgdata'
$log = Join-Path $target 'native-test.log'
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
    [CmdletBinding(SupportsShouldProcess)]
    param([int] $ProcessId)

    if (-not $PSCmdlet.ShouldProcess($MyInvocation.MyCommand.Name, 'Run')) {
        return
    }

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
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string] $Data,
        [string] $PgCtl
    )

    if (-not $PSCmdlet.ShouldProcess($MyInvocation.MyCommand.Name, 'Run')) {
        return
    }

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
    [CmdletBinding(SupportsShouldProcess)]
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
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [int] $ParentPid,
        [switch] $RemoveData
    )

    if (-not $PSCmdlet.ShouldProcess($MyInvocation.MyCommand.Name, 'Run')) {
        return
    }

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
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if (-not $PSCmdlet.ShouldProcess($MyInvocation.MyCommand.Name, 'Run')) {
        return
    }

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

function Wait-NativeSubscriptionReady {
    param(
        [string] $SubscriberDatabase,
        [string] $SubscriptionName,
        [string] $ProviderDatabase,
        [int] $MinReadyRelations,
        [int] $TimeoutSeconds
    )

    $deadline = [DateTimeOffset]::Now.AddSeconds($TimeoutSeconds)
    $last = ''

    while ([DateTimeOffset]::Now -lt $deadline) {
        $status = Invoke-Sql -Database $SubscriberDatabase -Sql @"
SELECT COALESCE((
    SELECT subenabled::text || '|' || COALESCE(subslotname::text, '') || '|' || oid::text
    FROM pg_subscription
    WHERE subname = $(ConvertTo-SqlLiteral $SubscriptionName)::name
), '<missing>||')
"@
        $parts = $status.Split('|', 3)
        $enabled = $parts[0]
        $slotName = if ($parts.Count -gt 1) { $parts[1] } else { '' }
        $subid = if ($parts.Count -gt 2) { $parts[2] } else { '' }
        $sync = Invoke-Sql -Database $SubscriberDatabase -Sql @"
SELECT count(*)::text || ':' ||
       COALESCE(bool_and(sr.srsubstate = 'r')::text, 'false')
FROM pg_subscription s
JOIN pg_subscription_rel sr ON sr.srsubid = s.oid
WHERE s.subname = $(ConvertTo-SqlLiteral $SubscriptionName)::name
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

        $last = "enabled=$enabled subid=$subid slot=$slotName sync=$sync provider_slot=$slotStatus"
        $syncParts = $sync.Split(':', 2)
        $readyCount = [int] $syncParts[0]
        $allReady = $syncParts.Count -gt 1 -and $syncParts[1] -eq 'true'
        if ($enabled -eq 'true' -and $slotName -and $readyCount -ge $MinReadyRelations -and $allReady -and $slotStatus.StartsWith('true:')) {
            return @{
                SlotName = $slotName
                OriginName = "pg_$subid"
            }
        }

        Start-Sleep -Milliseconds 250
    }

    throw "timed out waiting for native subscription $SubscriptionName readiness on ${SubscriberDatabase}: $last"
}

function Wait-SqlEqual {
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

$pgConfig = Get-PgrxPgConfig -PgMajor $PgMajor
$script:InitDb = Get-PglToolPath -PgConfig $pgConfig -Name 'initdb'
$script:PgCtl = Get-PglToolPath -PgConfig $pgConfig -Name 'pg_ctl'
$script:Psql = Get-PglToolPath -PgConfig $pgConfig -Name 'psql'
$script:Port = New-FreePort
$extensionSql = Get-ExtensionSqlPath -PgConfig $pgConfig
$watchdog = Start-CleanupWatchdog -ParentPid $PID -RemoveData:(-not $KeepData)

try {
    Write-Step "Cleaning prior native logical test cluster"
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

    Write-Step "Starting native-logical test cluster on port $script:Port"
    $socketOption = Get-PglUnixSocketOption -Directory $target
    $serverOptions = (@(
        "-p $script:Port",
        '-h localhost',
        $socketOption,
        '-c wal_level=logical',
        '-c max_worker_processes=20',
        '-c max_replication_slots=20',
        '-c max_wal_senders=20'
    ) | Where-Object { $_ }) -join ' '
    Invoke-CheckedProcess `
        -FilePath $script:PgCtl `
        -Arguments @('start', '-D', $data, '-l', $log, '-o', $serverOptions, '-w', '-t', '30') `
        -TimeoutSeconds 45 | Out-Null

    Write-Step 'Creating provider and native subscriber databases'
    Invoke-Sql -Database 'postgres' -Sql 'CREATE DATABASE provider' | Out-Null
    Invoke-Sql -Database 'postgres' -Sql 'CREATE DATABASE target' | Out-Null

    $providerDsn = "host=localhost port=$script:Port dbname=provider user=postgres connect_timeout=5 application_name=pgl_validate_native"
    $targetDsn = "host=localhost port=$script:Port dbname=target user=postgres connect_timeout=5 application_name=pgl_validate_native"
    $providerDsnSql = ConvertTo-SqlLiteral $providerDsn
    $targetDsnSql = ConvertTo-SqlLiteral $targetDsn

    Write-Step 'Creating native provider publications, including the barrier publication'
    Invoke-Sql -Database 'provider' -Sql 'CREATE EXTENSION pgl_validate' | Out-Null
    Invoke-Sql -Database 'provider' -Sql @"
CREATE TABLE public.accounts(id int PRIMARY KEY, value text);
SELECT pgl_validate.ensure_native_barrier_publication();
CREATE PUBLICATION app_pub FOR TABLE public.accounts;
"@ | Out-Null
    Invoke-Sql -Database 'provider' -Sql "SELECT slot_name FROM pg_create_logical_replication_slot('native_sub', 'pgoutput')" | Out-Null

    Write-Step 'Creating native target subscription'
    Invoke-Sql -Database 'target' -Sql 'CREATE EXTENSION pgl_validate' | Out-Null
    Invoke-Sql -Database 'target' -Sql 'CREATE TABLE public.accounts(id int PRIMARY KEY, value text)' | Out-Null
    Invoke-Sql -Database 'target' -Sql @"
CREATE SUBSCRIPTION native_sub
CONNECTION $providerDsnSql
PUBLICATION app_pub, pgl_validate_barrier
WITH (copy_data = false, create_slot = false, slot_name = 'native_sub', enabled = true)
"@ | Out-Null

    Write-Step 'Waiting for native subscription readiness'
    $subscription = Wait-NativeSubscriptionReady `
        -SubscriberDatabase 'target' `
        -SubscriptionName 'native_sub' `
        -ProviderDatabase 'provider' `
        -MinReadyRelations 2 `
        -TimeoutSeconds $TimeoutSeconds
    $slotName = $subscription.SlotName
    $originName = $subscription.OriginName
    $slotNameSql = ConvertTo-SqlLiteral $slotName
    $originNameSql = ConvertTo-SqlLiteral $originName

    Write-Step 'Replicating user table row for native compare_table validation'
    Invoke-Sql -Database 'provider' -Sql "INSERT INTO public.accounts VALUES (1, 'same')" | Out-Null
    Wait-SqlEqual `
        -Database 'target' `
        -Sql 'SELECT count(*)::text FROM public.accounts WHERE id = 1 AND value = ''same''' `
        -Expected '1' `
        -TimeoutSeconds $TimeoutSeconds

    Write-Step "Fencing provider->target native edge through slot $slotName and origin $originName"
    $observed = Invoke-Sql -Database 'provider' -Sql @"
WITH r AS (
    INSERT INTO pgl_validate.run(status)
    VALUES ('fencing')
    RETURNING run_id
), a AS (
    SELECT pgl_validate.fence_native_edge(
        r.run_id,
        1,
        1,
        'provider',
        'target',
        $providerDsnSql,
        $targetDsnSql,
        'native_sub',
        $slotNameSql,
        $originNameSql,
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
        throw "unexpected native fence result: $observed"
    }

    $recorded = Invoke-Sql -Database 'provider' -Sql @"
SELECT EXISTS (
    SELECT 1
    FROM pgl_validate.run_edge re
    JOIN pgl_validate.fence_edge fe USING (run_id, edge_id)
    JOIN pgl_validate.fence_attempt fa USING (run_id, epoch_seq, edge_id)
    JOIN pgl_validate.fence_barrier_run br USING (run_id, epoch_seq, edge_id)
    WHERE re.backend = 'native'
      AND fe.fence_kind = 'barrier'
      AND fa.status = 'converged'
      AND br.origin_node = 'provider'
)::text
"@
    if ($recorded -ne 'true') {
        throw 'native fence catalog rows were not recorded'
    }

    Write-Step 'Running compare_table through real native logical fencing'
    Invoke-Sql -Database 'provider' -Sql @"
INSERT INTO pgl_validate.peer(name, dsn, backend, subscription_name, replication_sets)
VALUES ('target', $targetDsnSql, 'native', 'native_sub', ARRAY['app_pub'])
"@ | Out-Null
    $compareVerdict = Invoke-Sql -Database 'provider' -Sql @"
SELECT (pgl_validate.compare_table(
    'public.accounts'::regclass,
    ARRAY['target'],
    jsonb_build_object(
        'backend', 'native',
        'provider_dsn', $providerDsnSql,
        'provider_node', 'provider',
        'publications', jsonb_build_array('app_pub'),
        'fence_timeout_ms', 30000,
        'fence_poll_interval_ms', 100
    )
)).verdict
"@
    if ($compareVerdict -ne 'match') {
        throw "unexpected native compare_table verdict: $compareVerdict"
    }

    $compareFenceRecorded = Invoke-Sql -Database 'provider' -Sql @"
SELECT EXISTS (
    SELECT 1
    FROM pgl_validate.table_result tr
    JOIN pgl_validate.run_edge re USING (run_id)
    JOIN pgl_validate.fence_attempt fa USING (run_id, edge_id)
    WHERE tr.schema_name = 'public'
      AND tr.table_name = 'accounts'
      AND tr.verdict = 'match'
      AND re.backend = 'native'
      AND fa.status = 'converged'
)::text
"@
    if ($compareFenceRecorded -ne 'true') {
        throw 'compare_table did not record a native converged fence'
    }

    Write-Step 'Validating native row-filter transition semantics'
    Invoke-Sql -Database 'provider' -Sql @"
CREATE TABLE public.native_filtered_accounts(
    id int PRIMARY KEY,
    include_row boolean NOT NULL,
    value text
);
ALTER TABLE public.native_filtered_accounts REPLICA IDENTITY FULL;
CREATE PUBLICATION native_filter_pub
FOR TABLE public.native_filtered_accounts
WHERE (include_row);
"@ | Out-Null
    Invoke-Sql -Database 'target' -Sql @"
CREATE TABLE public.native_filtered_accounts(
    id int PRIMARY KEY,
    include_row boolean NOT NULL,
    value text
);
"@ | Out-Null
    Invoke-Sql -Database 'target' -Sql @"
ALTER SUBSCRIPTION native_sub
ADD PUBLICATION native_filter_pub
WITH (copy_data = false, refresh = true);
"@ | Out-Null
    $null = Wait-NativeSubscriptionReady `
        -SubscriberDatabase 'target' `
        -SubscriptionName 'native_sub' `
        -ProviderDatabase 'provider' `
        -MinReadyRelations 3 `
        -TimeoutSeconds $TimeoutSeconds

    $filteredOutLsn = Invoke-Sql -Database 'provider' -Sql @"
INSERT INTO public.native_filtered_accounts
VALUES (6, false, 'insert-filtered-out');
SELECT pg_current_wal_lsn()::text;
"@
    Wait-SqlEqual `
        -Database 'provider' `
        -Sql "SELECT COALESCE((SELECT (confirmed_flush_lsn >= '$filteredOutLsn'::pg_lsn)::text FROM pg_replication_slots WHERE slot_name = 'native_sub'), 'false')" `
        -Expected 'true' `
        -TimeoutSeconds $TimeoutSeconds
    $filteredInsertAbsent = Invoke-Sql -Database 'target' -Sql "SELECT count(*)::text FROM public.native_filtered_accounts WHERE id = 6"
    if ($filteredInsertAbsent -ne '0') {
        throw "native filtered-out INSERT unexpectedly appeared on subscriber: $filteredInsertAbsent"
    }

    Invoke-Sql -Database 'provider' -Sql @"
UPDATE public.native_filtered_accounts
SET include_row = true,
    value = 'entered-filter-through-update'
WHERE id = 6;
"@ | Out-Null
    Wait-SqlEqual `
        -Database 'target' `
        -Sql "SELECT count(*)::text FROM public.native_filtered_accounts WHERE id = 6 AND include_row AND value = 'entered-filter-through-update'" `
        -Expected '1' `
        -TimeoutSeconds $TimeoutSeconds

    $nativeFilterResult = Invoke-Sql -Database 'provider' -Sql @"
SELECT run_id::text || ';' || verdict
FROM pgl_validate.compare_table(
    'public.native_filtered_accounts'::regclass,
    ARRAY['target'],
    jsonb_build_object(
        'backend', 'native',
        'provider_dsn', $providerDsnSql,
        'provider_node', 'provider',
        'publications', jsonb_build_array('native_filter_pub'),
        'fence_timeout_ms', 30000,
        'fence_poll_interval_ms', 100
    )
)
"@
    $nativeFilterParts = $nativeFilterResult.Split(';', 2)
    if ($nativeFilterParts.Count -ne 2) {
        throw "unexpected native filtered compare_table result: $nativeFilterResult"
    }
    $nativeFilterRunId = $nativeFilterParts[0]
    $nativeFilterVerdict = $nativeFilterParts[1]
    if ($nativeFilterVerdict -ne 'match') {
        throw "unexpected native filtered compare_table verdict: $nativeFilterVerdict"
    }

    $nativeFilterContract = Invoke-Sql -Database 'provider' -Sql @"
SELECT tp.validated_property || ';' ||
       tp.has_row_filter::text || ';' ||
       COALESCE(count(d.*), 0)::text
FROM pgl_validate.table_plan tp
LEFT JOIN pgl_validate.divergence d USING (run_id, schema_name, table_name)
WHERE tp.run_id = $nativeFilterRunId
  AND tp.schema_name = 'public'
  AND tp.table_name = 'native_filtered_accounts'
GROUP BY tp.validated_property, tp.has_row_filter
"@
    if ($nativeFilterContract -ne 'full;true;0') {
        throw "native filtered table was not validated as full equality: $nativeFilterContract"
    }

    Write-Step 'Validating native mid-sync table is skipped before fencing'
    $nativeSyncMarked = Invoke-Sql -Database 'target' -Sql @"
UPDATE pg_subscription_rel sr
SET srsubstate = 'd'
FROM pg_subscription s
WHERE sr.srsubid = s.oid
  AND s.subname = 'native_sub'::name
  AND sr.srrelid = 'public.accounts'::regclass
RETURNING 1
"@
    if ($nativeSyncMarked -ne '1') {
        throw "could not mark native table sync status as d: $nativeSyncMarked"
    }

    $midSyncResult = Invoke-Sql -Database 'provider' -Sql @"
SELECT run_id::text || ';' || verdict || ';' || reason
FROM pgl_validate.compare_table(
    'public.accounts'::regclass,
    ARRAY['target'],
    jsonb_build_object(
        'backend', 'native',
        'provider_dsn', $providerDsnSql,
        'provider_node', 'provider',
        'publications', jsonb_build_array('app_pub'),
        'fence_timeout_ms', 30000,
        'fence_poll_interval_ms', 100
    )
)
"@
    $midSyncParts = $midSyncResult.Split(';', 3)
    if ($midSyncParts.Count -ne 3) {
        throw "unexpected native mid-sync compare_table result: $midSyncResult"
    }
    $midSyncRunId = $midSyncParts[0]
    $midSyncVerdict = $midSyncParts[1]
    $midSyncReason = $midSyncParts[2]
    if ($midSyncVerdict -ne 'partial' -or -not $midSyncReason.Contains('sync_status=d')) {
        throw "native mid-sync table was not reported as partial/skipped: $midSyncResult"
    }

    $nativeSyncEvidence = Invoke-Sql -Database 'provider' -Sql @"
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
    if ($nativeSyncEvidence -ne 'true;true;true') {
        throw "native mid-sync skip evidence was incomplete: $nativeSyncEvidence"
    }

    Invoke-Sql -Database 'target' -Sql @"
UPDATE pg_subscription_rel sr
SET srsubstate = 'r'
FROM pg_subscription s
WHERE sr.srsubid = s.oid
  AND s.subname = 'native_sub'::name
  AND sr.srrelid = 'public.accounts'::regclass
"@ | Out-Null

    Write-Step 'Creating subscriber-side drift and confirming native recheck fencing'
    Invoke-Sql -Database 'target' -Sql "UPDATE public.accounts SET value = 'target-drift' WHERE id = 1" | Out-Null
    $driftResult = Invoke-Sql -Database 'provider' -Sql @"
SELECT run_id::text || ';' || verdict
FROM pgl_validate.compare_table(
    'public.accounts'::regclass,
    ARRAY['target'],
    jsonb_build_object(
        'backend', 'native',
        'provider_dsn', $providerDsnSql,
        'provider_node', 'provider',
        'publications', jsonb_build_array('app_pub'),
        'fence_timeout_ms', 30000,
        'fence_poll_interval_ms', 100
    )
)
"@
    $driftParts = $driftResult.Split(';', 2)
    if ($driftParts.Count -ne 2) {
        throw "unexpected native drift compare_table result: $driftResult"
    }
    $driftRunId = $driftParts[0]
    $driftVerdict = $driftParts[1]
    if ($driftVerdict -ne 'differ') {
        throw "unexpected native drift compare_table verdict: $driftVerdict"
    }

    $confirmedDrift = Invoke-Sql -Database 'provider' -Sql @"
SELECT EXISTS (
    SELECT 1
    FROM pgl_validate.divergence d
    JOIN pgl_validate.divergence_recheck dr USING (run_id, schema_name, table_name, key_bytes, node)
    JOIN pgl_validate.run_edge re ON re.run_id = d.run_id AND re.target_node = d.node
    JOIN pgl_validate.fence_attempt fa ON fa.run_id = re.run_id AND fa.edge_id = re.edge_id
    WHERE d.run_id = $driftRunId
      AND d.schema_name = 'public'
      AND d.table_name = 'accounts'
      AND d.node = 'target'
      AND d.classification = 'differs'
      AND d.status = 'confirmed'
      AND dr.epoch_seq = 2
      AND dr.outcome = 'still_differs'
      AND re.backend = 'native'
      AND fa.epoch_seq = 2
      AND fa.status = 'converged'
)::text
"@
    if ($confirmedDrift -ne 'true') {
        throw 'native subscriber-side drift was not confirmed through a recheck fence'
    }

    Write-Output "native logical fence, row-filter transition, compare_table, and divergence recheck tests passed on pg$PgMajor using slot $slotName"
}
catch {
    if (Test-Path -LiteralPath $log) {
        Write-Output '--- native logical test log tail ---'
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
