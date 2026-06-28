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
$cascadeData = Join-Path $target 'pglogical-cascade-pgdata'
$log = Join-Path $target 'pglogical-test.log'
$cascadeLog = Join-Path $target 'pglogical-cascade.log'
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
        [string] $Sql,
        [int] $Port = $script:Port
    )

    $output = & $script:Psql -X -w -h localhost -p $Port -U postgres -d $Database `
        -v ON_ERROR_STOP=1 -Atq -c $Sql 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "psql failed on database ${Database}: $($output -join [Environment]::NewLine)"
    }

    return ($output -join "`n").Trim()
}

function Start-AsyncSql {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string] $Database,
        [string] $Sql
    )

    if (-not $PSCmdlet.ShouldProcess($MyInvocation.MyCommand.Name, 'Run')) {
        return
    }

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
        [int] $SubscriberPort = $script:Port,
        [int] $ProviderPort = $script:Port,
        [int] $StableReadyPolls = 1,
        [int] $TimeoutSeconds
    )

    $deadline = [DateTimeOffset]::Now.AddSeconds($TimeoutSeconds)
    $last = ''
    $readyPolls = 0

    while ([DateTimeOffset]::Now -lt $deadline) {
        $status = Invoke-Sql -Database $SubscriberDatabase -Port $SubscriberPort -Sql @"
SELECT COALESCE((
    SELECT status || '|' || slot_name
    FROM pglogical.show_subscription_status($(ConvertTo-SqlLiteral $SubscriptionName)::name)
), '<missing>|')
"@
        $parts = $status.Split('|', 2)
        $statusValue = $parts[0]
        $slotName = if ($parts.Count -gt 1) { $parts[1] } else { '' }
        $sync = Invoke-Sql -Database $SubscriberDatabase -Port $SubscriberPort -Sql @"
SELECT COALESCE(
    string_agg(
        sync_kind::text || ':' || sync_status::text || ':' || sync_statuslsn::text,
        ',' ORDER BY sync_kind, sync_nspname, sync_relname
    ),
    '<none>'
)
FROM pglogical.local_sync_status
"@
        $syncReady = Invoke-Sql -Database $SubscriberDatabase -Port $SubscriberPort -Sql @"
SELECT (NOT EXISTS (
    SELECT 1
    FROM pglogical.local_sync_status
    WHERE sync_status <> 'r'
))::text
"@
        $slotStatus = '<no-slot>'
        if ($slotName) {
            $slotStatus = Invoke-Sql -Database $ProviderDatabase -Port $ProviderPort -Sql @"
SELECT COALESCE((
    SELECT active::text || ':' || confirmed_flush_lsn::text
    FROM pg_replication_slots
    WHERE slot_name = $(ConvertTo-SqlLiteral $slotName)
), '<missing>')
"@
        }

        $last = "status=$statusValue slot=$slotName sync=$sync sync_ready=$syncReady provider_slot=$slotStatus"
        if ($statusValue -eq 'replicating' -and $syncReady -eq 'true' -and $slotStatus.StartsWith('true:')) {
            $readyPolls++
            if ($readyPolls -ge $StableReadyPolls) {
                return $slotName
            }
        }
        else {
            $readyPolls = 0
        }

        Start-Sleep -Milliseconds 250
    }

    throw "timed out waiting for pglogical subscription $SubscriptionName readiness on ${SubscriberDatabase}: $last"
}

function Wait-ReplicationSlotInactive {
    param(
        [string] $Database,
        [string] $SlotName,
        [int] $Port = $script:Port,
        [int] $TimeoutSeconds
    )

    $deadline = [DateTimeOffset]::Now.AddSeconds($TimeoutSeconds)
    $last = ''

    while ([DateTimeOffset]::Now -lt $deadline) {
        $last = Invoke-Sql -Database $Database -Port $Port -Sql @"
SELECT COALESCE((
    SELECT active::text
    FROM pg_replication_slots
    WHERE slot_name = $(ConvertTo-SqlLiteral $SlotName)
), '<missing>')
"@
        if ($last -eq 'false' -or $last -eq '<missing>') {
            return
        }

        Start-Sleep -Milliseconds 250
    }

    throw "timed out waiting for replication slot $SlotName to become inactive on ${Database}; last result: $last"
}

function Wait-SqlEqual {
    param(
        [string] $Database,
        [string] $Sql,
        [string] $Expected,
        [int] $Port = $script:Port,
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

    throw "timed out waiting for SQL result '$Expected' on ${Database}; last result: $last"
}

function Set-PglogicalConflictResolution {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string] $Value,
        [int] $Port = $script:Port,
        [string] $Database = 'provider'
    )

    if (-not $PSCmdlet.ShouldProcess("pglogical.conflict_resolution on port $Port", "Set to $Value")) {
        return
    }

    $literal = ConvertTo-SqlLiteral $Value
    Invoke-Sql -Database 'postgres' -Port $Port -Sql "ALTER SYSTEM SET pglogical.conflict_resolution = $literal" | Out-Null
    Invoke-Sql -Database 'postgres' -Port $Port -Sql 'SELECT pg_reload_conf()' | Out-Null
    Wait-SqlEqual `
        -Database $Database `
        -Sql 'SHOW pglogical.conflict_resolution' `
        -Expected $Value `
        -Port $Port `
        -TimeoutSeconds $TimeoutSeconds
}

function Wait-AdvisoryLockHeld {
    param(
        [string] $Database,
        [int] $ClassId,
        [int] $ObjectId,
        [int] $Port = $script:Port,
        [int] $TimeoutSeconds
    )

    Wait-SqlEqual `
        -Database $Database `
        -Sql "SELECT EXISTS (SELECT 1 FROM pg_locks WHERE locktype = 'advisory' AND classid = $ClassId AND objid = $ObjectId AND granted)::text" `
        -Expected 'true' `
        -Port $Port `
        -TimeoutSeconds $TimeoutSeconds
}

$pgConfig = Get-PgrxPgConfig -PgMajor $PgMajor
$script:InitDb = Get-PglToolPath -PgConfig $pgConfig -Name 'initdb'
$script:PgCtl = Get-PglToolPath -PgConfig $pgConfig -Name 'pg_ctl'
$script:Psql = Get-PglToolPath -PgConfig $pgConfig -Name 'psql'
$script:Port = New-FreePort
do {
    $script:CascadePort = New-FreePort
} while ($script:CascadePort -eq $script:Port)
$extensionSql = Get-ExtensionSqlPath -PgConfig $pgConfig
$watchdog = Start-CleanupWatchdog -ParentPid $PID -RemoveData:(-not $KeepData)

try {
    Write-Step "Cleaning prior pglogical fence test cluster"
    Stop-TestCluster -Data $data -PgCtl $script:PgCtl
    if (-not $KeepData) {
        Remove-TestData -Data $data
        Remove-TestData -Data $cascadeData
    }
    if (Test-Path -LiteralPath $log) {
        Remove-Item -LiteralPath $log -Force
    }
    if (Test-Path -LiteralPath $cascadeLog) {
        Remove-Item -LiteralPath $cascadeLog -Force
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
    Write-Step "Initializing cascade test cluster at $cascadeData"
    Invoke-CheckedProcess `
        -FilePath $script:InitDb `
        -Arguments @('--locale=C', '--auth=trust', '--username=postgres', '-D', $cascadeData) `
        -TimeoutSeconds 120 | Out-Null

    Write-Step "Starting pglogical-enabled test cluster on port $script:Port"
    $socketOption = Get-PglUnixSocketOption -Directory $target
    $serverOptions = (@(
        "-p $script:Port",
        '-h localhost',
        $socketOption,
        '-c shared_preload_libraries=pglogical',
        '-c wal_level=logical',
        '-c track_commit_timestamp=on',
        '-c max_worker_processes=20',
        '-c max_replication_slots=20',
        '-c max_wal_senders=20'
    ) | Where-Object { $_ }) -join ' '
    Invoke-CheckedProcess `
        -FilePath $script:PgCtl `
        -Arguments @('start', '-D', $data, '-l', $log, '-o', $serverOptions, '-w', '-t', '30') `
        -TimeoutSeconds 45 | Out-Null
    Write-Step "Starting pglogical-enabled cascade test cluster on port $script:CascadePort"
    $cascadeServerOptions = (@(
        "-p $script:CascadePort",
        '-h localhost',
        $socketOption,
        '-c shared_preload_libraries=pglogical',
        '-c wal_level=logical',
        '-c track_commit_timestamp=on',
        '-c max_worker_processes=20',
        '-c max_replication_slots=20',
        '-c max_wal_senders=20'
    ) | Where-Object { $_ }) -join ' '
    Invoke-CheckedProcess `
        -FilePath $script:PgCtl `
        -Arguments @('start', '-D', $cascadeData, '-l', $cascadeLog, '-o', $cascadeServerOptions, '-w', '-t', '30') `
        -TimeoutSeconds 45 | Out-Null

    Write-Step 'Creating coordinator/provider/target databases and extensions'
    Invoke-Sql -Database 'postgres' -Sql 'CREATE DATABASE provider' | Out-Null
    Invoke-Sql -Database 'postgres' -Sql 'CREATE DATABASE target' | Out-Null
    Invoke-Sql -Database 'postgres' -Sql 'CREATE DATABASE fanout' | Out-Null
    Invoke-Sql -Database 'postgres' -Sql 'CREATE DATABASE degraded' | Out-Null
    Invoke-Sql -Database 'postgres' -Port $script:CascadePort -Sql 'CREATE DATABASE cascade' | Out-Null
    Invoke-Sql -Database 'postgres' -Sql 'CREATE EXTENSION pgl_validate' | Out-Null

    $providerDsn = "host=localhost port=$script:Port dbname=provider user=postgres connect_timeout=5 application_name=pgl_validate_pglogical"
    $targetDsn = "host=localhost port=$script:Port dbname=target user=postgres connect_timeout=5 application_name=pgl_validate_pglogical"
    $fanoutDsn = "host=localhost port=$script:Port dbname=fanout user=postgres connect_timeout=5 application_name=pgl_validate_pglogical"
    $degradedDsn = "host=localhost port=$script:Port dbname=degraded user=postgres connect_timeout=5 application_name=pgl_validate_pglogical"
    $cascadeDsn = "host=localhost port=$script:CascadePort dbname=cascade user=postgres connect_timeout=5 application_name=pgl_validate_pglogical"
    $sequenceProviderDsn = "host=localhost port=$script:Port dbname=seq_provider user=postgres connect_timeout=5 application_name=pgl_validate_pglogical"
    $sequenceTargetDsn = "host=localhost port=$script:Port dbname=seq_target user=postgres connect_timeout=5 application_name=pgl_validate_pglogical"
    $providerDsnSql = ConvertTo-SqlLiteral $providerDsn
    $targetDsnSql = ConvertTo-SqlLiteral $targetDsn
    $fanoutDsnSql = ConvertTo-SqlLiteral $fanoutDsn
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

    Write-Step 'Creating second direct pglogical target for fan-out validation'
    Invoke-Sql -Database 'fanout' -Sql 'CREATE EXTENSION pgl_validate' | Out-Null
    Invoke-Sql -Database 'fanout' -Sql 'CREATE EXTENSION pglogical' | Out-Null
    Invoke-Sql -Database 'fanout' -Sql 'CREATE TABLE public.accounts(id int PRIMARY KEY, value text)' | Out-Null
    Invoke-Sql -Database 'fanout' -Sql "SELECT pglogical.create_node('fanout', $fanoutDsnSql)" | Out-Null
    Invoke-Sql -Database 'fanout' -Sql @"
SELECT pglogical.create_subscription(
    'sub_fanout',
    $providerDsnSql,
    ARRAY['default','pgl_validate_barrier'],
    false,
    false,
    ARRAY[]::text[]
)
"@ | Out-Null
    $fanoutSlotName = Wait-SubscriptionReady `
        -SubscriberDatabase 'fanout' `
        -SubscriptionName 'sub_fanout' `
        -ProviderDatabase 'provider' `
        -TimeoutSeconds $TimeoutSeconds

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
    Wait-SqlEqual `
        -Database 'target' `
        -Sql 'SELECT count(*)::text FROM public.accounts WHERE id = 1 AND value = ''same''' `
        -Expected '1' `
        -TimeoutSeconds $TimeoutSeconds
    Wait-SqlEqual `
        -Database 'fanout' `
        -Sql 'SELECT count(*)::text FROM public.accounts WHERE id = 1 AND value = ''same''' `
        -Expected '1' `
        -TimeoutSeconds $TimeoutSeconds
    Wait-SqlEqual `
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
SELECT pgl_validate.register_pglogical_peer(
    'target',
    $targetDsnSql,
    'sub'::name,
    NULL,
    ARRAY['default']
);
SELECT pgl_validate.register_pglogical_peer(
    'target',
    $targetDsnSql,
    'sub'::name,
    NULL,
    ARRAY['default'],
    11,
    601000,
    31000
)
"@ | Out-Null
    $compareResult = Invoke-Sql -Database 'provider' -Sql @"
SELECT run_id::text || ';' || verdict
FROM pgl_validate.compare_table(
    'public.accounts'::regclass,
    ARRAY['target'],
    jsonb_build_object(
        'repsets', jsonb_build_array('default'),
        'fence_timeout_ms', 30000,
        'fence_poll_interval_ms', 100
    )
)
"@
    $compareParts = $compareResult.Split(';', 2)
    if ($compareParts.Count -ne 2) {
        throw "unexpected compare_table result: $compareResult"
    }
    $compareRunId = $compareParts[0]
    $compareVerdict = $compareParts[1]
    if ($compareVerdict -ne 'match') {
        throw "unexpected compare_table verdict: $compareVerdict"
    }

    $compareFenceRecorded = Invoke-Sql -Database 'provider' -Sql @"
SELECT EXISTS (
    SELECT 1
    FROM pgl_validate.table_result tr
    JOIN pgl_validate.fence_attempt fa USING (run_id)
    WHERE tr.run_id = $compareRunId
      AND tr.schema_name = 'public'
      AND tr.table_name = 'accounts'
      AND tr.verdict = 'match'
      AND fa.status = 'converged'
)::text
"@
    if ($compareFenceRecorded -ne 'true') {
        throw 'compare_table did not record a converged fence'
    }

    $registeredPeer = Invoke-Sql -Database 'provider' -Sql @"
SELECT subscription_name::text || ';' ||
       COALESCE(reverse_subscription_name::text, '<null>') || ';' ||
       (replication_sets = ARRAY['default'])::text || ';' ||
       (provider_dsn = $providerDsnSql)::text || ';' ||
       connect_timeout_seconds::text || ';' ||
       statement_timeout_ms::text || ';' ||
       lock_timeout_ms::text
FROM pgl_validate.peer
WHERE name = 'target'
"@
    if ($registeredPeer -ne 'sub;<null>;true;true;11;601000;31000') {
        throw "register_pglogical_peer did not persist the expected target peer: $registeredPeer"
    }

    $registeredPeerCount = Invoke-Sql -Database 'provider' -Sql @"
SELECT count(*)::text
FROM pgl_validate.peer
WHERE name = 'target'
"@
    if ($registeredPeerCount -ne '1') {
        throw "register_pglogical_peer is not idempotent for target peer: $registeredPeerCount rows"
    }

    Write-Step "Validating pglogical direct fan-out through slots $slotName and $fanoutSlotName"
    Invoke-Sql -Database 'provider' -Sql @"
SELECT pgl_validate.register_pglogical_peer(
    'fanout',
    $fanoutDsnSql,
    'sub_fanout'::name,
    NULL,
    ARRAY['default']
)
"@ | Out-Null
    $fanoutResult = Invoke-Sql -Database 'provider' -Sql @"
SELECT run_id::text || ';' || verdict
FROM pgl_validate.compare_table(
    'public.accounts'::regclass,
    ARRAY['target','fanout'],
    jsonb_build_object(
        'repsets', jsonb_build_array('default'),
        'fence_timeout_ms', 30000,
        'fence_poll_interval_ms', 100
    )
)
"@
    $fanoutParts = $fanoutResult.Split(';', 2)
    if ($fanoutParts.Count -ne 2) {
        throw "unexpected fan-out compare_table result: $fanoutResult"
    }
    $fanoutRunId = $fanoutParts[0]
    $fanoutVerdict = $fanoutParts[1]
    if ($fanoutVerdict -ne 'match') {
        throw "unexpected fan-out compare_table verdict: $fanoutVerdict"
    }

    $fanoutFenceShape = Invoke-Sql -Database 'provider' -Sql @"
SELECT
    count(*) FILTER (
        WHERE re.provider_node = 'provider'
          AND re.target_node IN ('target','fanout')
          AND fa.status = 'converged'
    )::text || ';' ||
    count(DISTINCT re.target_node) FILTER (
        WHERE re.provider_node = 'provider'
          AND re.target_node IN ('target','fanout')
          AND fa.status = 'converged'
    )::text || ';' ||
    count(*) FILTER (
        WHERE br.origin_node = 'provider'
    )::text
FROM pgl_validate.run_edge re
JOIN pgl_validate.fence_attempt fa USING (run_id, edge_id)
LEFT JOIN pgl_validate.fence_barrier_run br USING (run_id, epoch_seq, edge_id)
WHERE re.run_id = $fanoutRunId
  AND re.backend = 'pglogical'
  AND fa.epoch_seq = 1
"@
    if ($fanoutFenceShape -ne '2;2;2') {
        throw "pglogical fan-out fence vector was not recorded correctly: $fanoutFenceShape"
    }

    $fanoutNodeShape = Invoke-Sql -Database 'provider' -Sql @"
SELECT tr.verdict || ';' ||
       string_agg(tnr.node || ':' || tnr.n_rows::text, ',' ORDER BY tnr.node)
FROM pgl_validate.table_result tr
JOIN pgl_validate.table_node_result tnr USING (run_id, schema_name, table_name)
WHERE tr.run_id = $fanoutRunId
  AND tr.schema_name = 'public'
  AND tr.table_name = 'accounts'
GROUP BY tr.verdict
"@
    if ($fanoutNodeShape -ne 'match;fanout:1,local:1,target:1') {
        throw "pglogical fan-out node results were incomplete: $fanoutNodeShape"
    }

    Write-Step 'Re-fencing the recorded pglogical edge vector'
    Invoke-Sql -Database 'provider' -Sql @"
DO `$pgl_validate_re_fence`$
DECLARE
    v_run_id bigint;
    v_epoch int;
    v_edges int;
BEGIN
    v_run_id := $compareRunId;

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
    Wait-SqlEqual `
        -Database 'target' `
        -Sql "SELECT count(*)::text FROM public.truncate_accounts WHERE id = 1 AND value = 'left-behind'" `
        -Expected '1' `
        -TimeoutSeconds $TimeoutSeconds
    Invoke-Sql -Database 'provider' -Sql 'TRUNCATE public.truncate_accounts' | Out-Null
    Wait-SqlEqual `
        -Database 'provider' `
        -Sql 'SELECT count(*)::text FROM public.truncate_accounts' `
        -Expected '0' `
        -TimeoutSeconds $TimeoutSeconds
    Wait-SqlEqual `
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
    Invoke-Sql -Database 'fanout' -Sql 'SELECT pgl_validate.ensure_pglogical_barrier_repset()' | Out-Null
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
    Invoke-Sql -Database 'fanout' -Sql @"
CREATE TABLE public.bidir_accounts(id int PRIMARY KEY, value text);
SELECT pglogical.create_replication_set('pgl_validate_bidir');
SELECT pglogical.replication_set_add_table('pgl_validate_bidir', 'public.bidir_accounts'::regclass, false);
SELECT pglogical.alter_subscription_add_replication_set('sub_fanout', 'pgl_validate_bidir');
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
    Invoke-Sql -Database 'provider' -Sql @"
SELECT pglogical.create_subscription(
    'sub_from_fanout',
    $fanoutDsnSql,
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
    $fanoutReverseSlotName = Wait-SubscriptionReady `
        -SubscriberDatabase 'provider' `
        -SubscriptionName 'sub_from_fanout' `
        -ProviderDatabase 'fanout' `
        -TimeoutSeconds $TimeoutSeconds
    Wait-SqlEqual `
        -Database 'provider' `
        -Sql "SELECT sync_status FROM pgl_validate.pglogical_subscription_table_sync_status('sub_from_target'::name, 'public.bidir_accounts'::regclass)" `
        -Expected 'r' `
        -TimeoutSeconds $TimeoutSeconds
    Wait-SqlEqual `
        -Database 'provider' `
        -Sql "SELECT sync_status FROM pgl_validate.pglogical_subscription_table_sync_status('sub_from_fanout'::name, 'public.bidir_accounts'::regclass)" `
        -Expected 'r' `
        -TimeoutSeconds $TimeoutSeconds
    $reverseSlotName = Wait-SubscriptionReady `
        -SubscriberDatabase 'provider' `
        -SubscriptionName 'sub_from_target' `
        -ProviderDatabase 'target' `
        -StableReadyPolls 12 `
        -TimeoutSeconds $TimeoutSeconds
    $fanoutReverseSlotName = Wait-SubscriptionReady `
        -SubscriberDatabase 'provider' `
        -SubscriptionName 'sub_from_fanout' `
        -ProviderDatabase 'fanout' `
        -StableReadyPolls 12 `
        -TimeoutSeconds $TimeoutSeconds

    Invoke-Sql -Database 'provider' -Sql @"
SELECT pgl_validate.register_pglogical_peer(
    'target',
    $targetDsnSql,
    'sub'::name,
    'sub_from_target'::name,
    ARRAY['pgl_validate_bidir']
);
SELECT pgl_validate.register_pglogical_peer(
    'fanout',
    $fanoutDsnSql,
    'sub_fanout'::name,
    'sub_from_fanout'::name,
    ARRAY['pgl_validate_bidir']
)
"@ | Out-Null
    $bidirectionalResult = Invoke-Sql -Database 'provider' -Sql @"
SELECT run_id::text || ';' || verdict
FROM pgl_validate.compare_table(
    'public.bidir_accounts'::regclass,
    ARRAY['target','fanout'],
    jsonb_build_object(
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
          AND re.target_node IN ('target','fanout')
          AND fa.status = 'converged'
    )::text || ';' ||
    count(*) FILTER (
        WHERE re.provider_node IN ('target','fanout')
          AND re.target_node = 'provider'
          AND fa.status = 'converged'
    )::text || ';' ||
    count(*) FILTER (
        WHERE br.origin_node IN ('target','fanout')
    )::text
FROM pgl_validate.run_edge re
JOIN pgl_validate.fence_attempt fa USING (run_id, edge_id)
LEFT JOIN pgl_validate.fence_barrier_run br USING (run_id, epoch_seq, edge_id)
WHERE re.run_id = $bidirectionalRunId
  AND re.backend = 'pglogical'
  AND fa.epoch_seq = 1
"@
    if ($bidirectionalFenceShape -ne '2;2;2') {
        throw "N-way bidirectional pglogical fence vector was not recorded: $bidirectionalFenceShape using reverse slots $reverseSlotName and $fanoutReverseSlotName"
    }

    Write-Step 'Validating real pglogical keep_local bidirectional conflict detection'
    $priorConflictResolution = Invoke-Sql -Database 'provider' -Sql 'SHOW pglogical.conflict_resolution'
    Set-PglogicalConflictResolution -Value 'keep_local'
    $hasConflictHistory = Invoke-Sql -Database 'target' -Sql @"
SELECT (
    to_regclass('pglogical.conflict_history') IS NOT NULL AND
    to_regprocedure('pglogical.conflict_history_ensure_partition(date)') IS NOT NULL AND
    current_setting('pglogical.conflict_history_enabled', true) IS NOT NULL
)::text
"@
    if ($hasConflictHistory -eq 'true') {
        Invoke-Sql -Database 'postgres' -Sql "ALTER SYSTEM SET pglogical.conflict_history_enabled = 'on'" | Out-Null
        Invoke-Sql -Database 'postgres' -Sql "ALTER SYSTEM SET pglogical.conflict_history_store_tuples = 'on'" | Out-Null
        Invoke-Sql -Database 'postgres' -Sql 'SELECT pg_reload_conf()' | Out-Null
        Wait-SqlEqual `
            -Database 'provider' `
            -Sql 'SHOW pglogical.conflict_history_enabled' `
            -Expected 'on' `
            -TimeoutSeconds $TimeoutSeconds
        Invoke-Sql -Database 'provider' -Sql 'SELECT pglogical.conflict_history_ensure_partition(CURRENT_DATE)' | Out-Null
        Invoke-Sql -Database 'target' -Sql 'SELECT pglogical.conflict_history_ensure_partition(CURRENT_DATE)' | Out-Null
    }

    Invoke-Sql -Database 'provider' -Sql "INSERT INTO public.bidir_accounts VALUES (1, 'base')" | Out-Null
    Wait-SqlEqual `
        -Database 'target' `
        -Sql "SELECT value FROM public.bidir_accounts WHERE id = 1" `
        -Expected 'base' `
        -TimeoutSeconds $TimeoutSeconds

    Invoke-Sql -Database 'target' -Sql "SELECT pglogical.alter_subscription_disable('sub', true)" | Out-Null
    Invoke-Sql -Database 'provider' -Sql "SELECT pglogical.alter_subscription_disable('sub_from_target', true)" | Out-Null

    $providerConflictLsn = Invoke-Sql -Database 'provider' -Sql @"
WITH changed AS (
    UPDATE public.bidir_accounts
    SET value = 'provider-conflict'
    WHERE id = 1
    RETURNING 1
)
SELECT pg_current_wal_lsn()
FROM changed
"@
    $targetConflictLsn = Invoke-Sql -Database 'target' -Sql @"
WITH changed AS (
    UPDATE public.bidir_accounts
    SET value = 'target-conflict'
    WHERE id = 1
    RETURNING 1
)
SELECT pg_current_wal_lsn()
FROM changed
"@
    Invoke-Sql -Database 'provider' -Sql "SELECT pglogical.alter_subscription_enable('sub_from_target', true)" | Out-Null
    $reverseSlotName = Wait-SubscriptionReady `
        -SubscriberDatabase 'provider' `
        -SubscriptionName 'sub_from_target' `
        -ProviderDatabase 'target' `
        -StableReadyPolls 12 `
        -TimeoutSeconds $TimeoutSeconds
    $targetConflictLsnSql = ConvertTo-SqlLiteral $targetConflictLsn
    $reverseSlotSql = ConvertTo-SqlLiteral $reverseSlotName
    Invoke-Sql -Database 'target' -Sql "SELECT pglogical.wait_slot_confirm_lsn($reverseSlotSql, ${targetConflictLsnSql}::pg_lsn)" | Out-Null
    Wait-SqlEqual `
        -Database 'provider' `
        -Sql "SELECT value FROM public.bidir_accounts WHERE id = 1" `
        -Expected 'provider-conflict' `
        -TimeoutSeconds $TimeoutSeconds

    Invoke-Sql -Database 'target' -Sql "SELECT pglogical.alter_subscription_enable('sub', true)" | Out-Null
    $slotName = Wait-SubscriptionReady `
        -SubscriberDatabase 'target' `
        -SubscriptionName 'sub' `
        -ProviderDatabase 'provider' `
        -StableReadyPolls 12 `
        -TimeoutSeconds $TimeoutSeconds
    $providerConflictLsnSql = ConvertTo-SqlLiteral $providerConflictLsn
    $slotSql = ConvertTo-SqlLiteral $slotName
    Invoke-Sql -Database 'provider' -Sql "SELECT pglogical.wait_slot_confirm_lsn($slotSql, ${providerConflictLsnSql}::pg_lsn)" | Out-Null
    Wait-SqlEqual `
        -Database 'target' `
        -Sql "SELECT value FROM public.bidir_accounts WHERE id = 1" `
        -Expected 'target-conflict' `
        -TimeoutSeconds $TimeoutSeconds

    $keepLocalResult = Invoke-Sql -Database 'provider' -Sql @"
SELECT run_id::text || ';' || verdict
FROM pgl_validate.compare_table(
    'public.bidir_accounts'::regclass,
    ARRAY['target'],
    jsonb_build_object(
        'repsets', jsonb_build_array('pgl_validate_bidir'),
        'fence_timeout_ms', 30000,
        'fence_poll_interval_ms', 100
    )
)
"@
    $keepLocalParts = $keepLocalResult.Split(';', 2)
    if ($keepLocalParts.Count -ne 2) {
        throw "unexpected keep_local compare_table result: $keepLocalResult"
    }
    $keepLocalRunId = $keepLocalParts[0]
    $keepLocalVerdict = $keepLocalParts[1]
    if ($keepLocalVerdict -ne 'differ') {
        throw "real keep_local conflict should remain a divergence, saw: $keepLocalResult"
    }

    $keepLocalEvidence = Invoke-Sql -Database 'provider' -Sql @"
SELECT d.classification || ';' ||
       d.status || ';' ||
       d.node || ';' ||
       count(DISTINCT re.edge_id) FILTER (
           WHERE re.provider_node = 'provider'
             AND re.target_node = 'target'
             AND fa.status = 'converged'
       )::text || ';' ||
       count(DISTINCT re.edge_id) FILTER (
           WHERE re.provider_node = 'target'
             AND re.target_node = 'provider'
             AND fa.status = 'converged'
       )::text
FROM pgl_validate.divergence d
JOIN pgl_validate.run_edge re ON re.run_id = d.run_id
JOIN pgl_validate.fence_attempt fa ON fa.run_id = re.run_id
                                  AND fa.edge_id = re.edge_id
WHERE d.run_id = $keepLocalRunId
  AND d.schema_name = 'public'
  AND d.table_name = 'bidir_accounts'
  AND d.node = 'target'
GROUP BY d.classification, d.status, d.node
"@
    if ($keepLocalEvidence -ne 'differs;confirmed;target;1;1') {
        throw "real keep_local conflict was not confirmed with both directed edges fenced: $keepLocalEvidence"
    }

    if ($hasConflictHistory -eq 'true') {
        $keepLocalConflictHistory = Invoke-Sql -Database 'provider' -Sql @"
SELECT EXISTS (
    SELECT 1
    FROM pgl_validate.conflict_evidence($keepLocalRunId)
    WHERE node = 'target'
      AND conflict_type = 'update_update'
      AND resolution = 'keep_local'
)::text
"@
        if ($keepLocalConflictHistory -ne 'true') {
            throw 'real keep_local conflict was not attached as pglogical conflict evidence'
        }
    }

    Set-PglogicalConflictResolution -Value $priorConflictResolution
    Invoke-Sql -Database 'target' -Sql "SELECT pglogical.alter_subscription_disable('sub', true)" | Out-Null
    Invoke-Sql -Database 'provider' -Sql "SELECT pglogical.alter_subscription_disable('sub_from_target', true)" | Out-Null
    Invoke-Sql -Database 'provider' -Sql "SELECT pglogical.alter_subscription_enable('sub_from_target', true)" | Out-Null
    $reverseSlotName = Wait-SubscriptionReady `
        -SubscriberDatabase 'provider' `
        -SubscriptionName 'sub_from_target' `
        -ProviderDatabase 'target' `
        -StableReadyPolls 3 `
        -TimeoutSeconds $TimeoutSeconds
    Invoke-Sql -Database 'target' -Sql "SELECT pglogical.alter_subscription_enable('sub', true)" | Out-Null
    $slotName = Wait-SubscriptionReady `
        -SubscriberDatabase 'target' `
        -SubscriptionName 'sub' `
        -ProviderDatabase 'provider' `
        -StableReadyPolls 3 `
        -TimeoutSeconds $TimeoutSeconds

    Invoke-Sql -Database 'provider' -Sql @"
UPDATE pgl_validate.peer
SET replication_sets = ARRAY['default'],
    reverse_subscription_name = NULL
WHERE name IN ('target','fanout')
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

    $degradedDefaultFailed = $false
    try {
        Invoke-Sql -Database 'provider' -Sql @"
SELECT *
FROM pgl_validate.compare_table(
    'public.accounts'::regclass,
    ARRAY['degraded'],
    jsonb_build_object(
        'provider_dsn', $providerDsnSql,
        'provider_node', 'provider',
        'repsets', jsonb_build_array('default'),
        'fence_timeout_ms', 30000,
        'fence_poll_interval_ms', 100
    )
)
"@ | Out-Null
    }
    catch {
        if ($_ -notlike '*does not include pgl_validate_barrier*') {
            throw
        }
        $degradedDefaultFailed = $true
    }
    if (-not $degradedDefaultFailed) {
        throw 'pglogical missing-barrier peer did not fail closed by default'
    }

    $degradedResult = Invoke-Sql -Database 'provider' -Sql @"
SELECT run_id::text || ';' || verdict
FROM pgl_validate.compare_table(
    'public.accounts'::regclass,
    ARRAY['degraded'],
    jsonb_build_object(
        'provider_dsn', $providerDsnSql,
        'provider_node', 'provider',
        'repsets', jsonb_build_array('default'),
        'require_barrier', false,
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
    Wait-SqlEqual `
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
DO `$pgl_validate_role`$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgl_validate_recheck_user') THEN
        CREATE ROLE pgl_validate_recheck_user LOGIN;
    END IF;
END
`$pgl_validate_role`$;
GRANT pgl_validate_orchestrate TO pgl_validate_recheck_user;
GRANT USAGE ON SCHEMA public, pglogical TO pgl_validate_recheck_user;
GRANT SELECT ON ALL TABLES IN SCHEMA pglogical TO pgl_validate_recheck_user;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pglogical TO pgl_validate_recheck_user;
CREATE FUNCTION public.pgl_validate_recheck_gate(i int)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
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
        ('pgl_validate_recheck_delete'::text, 3, 3),
        ('pgl_validate_recheck_hot'::text, 4, 3)
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
    false
);
ALTER TABLE public.post_fence_update_accounts ENABLE ROW LEVEL SECURITY;
CREATE POLICY pgl_validate_recheck_update_gate
ON public.post_fence_update_accounts
FOR SELECT
TO pgl_validate_recheck_user
USING (public.pgl_validate_recheck_gate(id));
GRANT SELECT ON public.post_fence_update_accounts TO pgl_validate_recheck_user;
GRANT EXECUTE ON FUNCTION public.pgl_validate_recheck_gate(int) TO pgl_validate_recheck_user;
"@ | Out-Null
    Invoke-Sql -Database 'target' -Sql @"
CREATE TABLE public.post_fence_update_accounts(
    id int PRIMARY KEY,
    value text
)
"@ | Out-Null
    Invoke-Sql -Database 'provider' -Sql "INSERT INTO public.post_fence_update_accounts VALUES (1, 'before-update')" | Out-Null
    Wait-SqlEqual `
        -Database 'target' `
        -Sql "SELECT value FROM public.post_fence_update_accounts WHERE id = 1" `
        -Expected 'before-update' `
        -TimeoutSeconds $TimeoutSeconds
    Invoke-Sql -Database 'target' -Sql "UPDATE public.post_fence_update_accounts SET value = 'after-update' WHERE id = 1" | Out-Null

    $clearedCompareSql = @"
SET ROLE pgl_validate_recheck_user;
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
        Wait-SqlEqual `
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
    if ($clearedEvidence -ne 'differs;cleared;cleared;match;full') {
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
    false
);
ALTER TABLE public.post_fence_delete_accounts ENABLE ROW LEVEL SECURITY;
CREATE POLICY pgl_validate_recheck_delete_gate
ON public.post_fence_delete_accounts
FOR SELECT
TO pgl_validate_recheck_user
USING (public.pgl_validate_recheck_gate(id));
GRANT SELECT ON public.post_fence_delete_accounts TO pgl_validate_recheck_user;
"@ | Out-Null
    Invoke-Sql -Database 'target' -Sql @"
CREATE TABLE public.post_fence_delete_accounts(
    id int PRIMARY KEY,
    value text
)
"@ | Out-Null
    Invoke-Sql -Database 'provider' -Sql "INSERT INTO public.post_fence_delete_accounts VALUES (1, 'before-delete')" | Out-Null
    Wait-SqlEqual `
        -Database 'target' `
        -Sql "SELECT value FROM public.post_fence_delete_accounts WHERE id = 1" `
        -Expected 'before-delete' `
        -TimeoutSeconds $TimeoutSeconds
    Invoke-Sql -Database 'target' -Sql "UPDATE public.post_fence_delete_accounts SET value = 'target-delete-drift' WHERE id = 1" | Out-Null

    $deleteCompareSql = @"
SET ROLE pgl_validate_recheck_user;
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
        Wait-SqlEqual `
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
      AND tp.validated_property = 'full'
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

    Write-Step 'Validating continuously hot pglogical key becomes indeterminate'
    Invoke-Sql -Database 'provider' -Sql @"
CREATE TABLE public.post_fence_hot_accounts(
    id int PRIMARY KEY,
    value text
);
SELECT pglogical.replication_set_add_table(
    'default',
    'public.post_fence_hot_accounts'::regclass,
    false
);
ALTER TABLE public.post_fence_hot_accounts ENABLE ROW LEVEL SECURITY;
CREATE POLICY pgl_validate_recheck_hot_gate
ON public.post_fence_hot_accounts
FOR SELECT
TO pgl_validate_recheck_user
USING (public.pgl_validate_recheck_gate(id));
GRANT SELECT ON public.post_fence_hot_accounts TO pgl_validate_recheck_user;
"@ | Out-Null
    Invoke-Sql -Database 'target' -Sql @"
CREATE TABLE public.post_fence_hot_accounts(
    id int PRIMARY KEY,
    value text
)
"@ | Out-Null
    Invoke-Sql -Database 'provider' -Sql "INSERT INTO public.post_fence_hot_accounts VALUES (1, 'hot-before')" | Out-Null
    Wait-SqlEqual `
        -Database 'target' `
        -Sql "SELECT value FROM public.post_fence_hot_accounts WHERE id = 1" `
        -Expected 'hot-before' `
        -TimeoutSeconds $TimeoutSeconds
    Invoke-Sql -Database 'target' -Sql "UPDATE public.post_fence_hot_accounts SET value = 'target-hot-drift' WHERE id = 1" | Out-Null

    $hotCompareSql = @"
SET ROLE pgl_validate_recheck_user;
SET application_name = 'pgl_validate_recheck_hot';
SET pgl_validate.recheck_gate_calls = '0';
SELECT run_id::text || ';' || verdict
FROM pgl_validate.compare_table(
    'public.post_fence_hot_accounts'::regclass,
    ARRAY['target'],
    jsonb_build_object(
        'provider_dsn', $providerDsnSql,
        'provider_node', 'provider',
        'repsets', jsonb_build_array('default'),
        'recheck_passes', 1,
        'fence_timeout_ms', 30000,
        'fence_poll_interval_ms', 100
    )
)
"@
    $hotProcess = Start-AsyncSql -Database 'provider' -Sql $hotCompareSql
    try {
        Wait-AdvisoryLockHeld `
            -Database 'provider' `
            -ClassId 76422 `
            -ObjectId 4 `
            -TimeoutSeconds $clearedTimeoutSeconds

        Invoke-Sql -Database 'provider' -Sql "UPDATE public.post_fence_hot_accounts SET value = 'hot-after' WHERE id = 1" | Out-Null
        Wait-SqlEqual `
            -Database 'target' `
            -Sql "SELECT value FROM public.post_fence_hot_accounts WHERE id = 1" `
            -Expected 'hot-after' `
            -TimeoutSeconds $clearedTimeoutSeconds

        $hotResult = Wait-AsyncSql `
            -Process $hotProcess `
            -TimeoutSeconds $clearedTimeoutSeconds `
            -Context 'continuously hot pglogical key compare_table'
    }
    finally {
        if ($hotProcess -and -not $hotProcess.HasExited) {
            Stop-ProcessTree -ProcessId $hotProcess.Id
        }
    }

    $hotParts = $hotResult.Split(';', 2)
    if ($hotParts.Count -ne 2) {
        throw "unexpected hot-key compare_table result: $hotResult"
    }
    $hotRunId = $hotParts[0]
    $hotVerdict = $hotParts[1]
    if ($hotVerdict -ne 'indeterminate') {
        throw "continuously hot pglogical key should become indeterminate, saw: $hotResult"
    }

    $hotEvidence = Invoke-Sql -Database 'provider' -Sql @"
SELECT d.classification || ';' ||
       d.status || ';' ||
       dr.outcome || ';' ||
       tr.verdict || ';' ||
       tp.validated_property
FROM pgl_validate.divergence d
JOIN pgl_validate.divergence_recheck dr USING (run_id, schema_name, table_name, key_bytes, node)
JOIN pgl_validate.table_result tr USING (run_id, schema_name, table_name)
JOIN pgl_validate.table_plan tp USING (run_id, schema_name, table_name)
WHERE d.run_id = $hotRunId
  AND d.schema_name = 'public'
  AND d.table_name = 'post_fence_hot_accounts'
  AND d.node = 'target'
"@
    if ($hotEvidence -ne 'differs;indeterminate;still_hot;indeterminate;full') {
        throw "hot pglogical key did not persist an indeterminate still_hot outcome: $hotEvidence"
    }

    Write-Step 'Creating subscriber-side drift and applying audited pglogical repair'
    Invoke-Sql -Database 'target' -Sql "UPDATE public.accounts SET value = 'target-drift' WHERE id = 1" | Out-Null
    $hasQueryableConflictHistory = Invoke-Sql -Database 'target' -Sql @"
SELECT (
    to_regclass('pglogical.conflict_history') IS NOT NULL AND
    to_regprocedure('pglogical.conflict_history_ensure_partition(date)') IS NOT NULL
)::text
"@
    if ($hasQueryableConflictHistory -eq 'true') {
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
    }

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
    $expectedConflictEvidence = if ($hasQueryableConflictHistory -eq 'true') {
        '1;update_update;keep_local;true;true'
    }
    else {
        '0;<none>;<none>;false;false'
    }
    if ($conflictEvidence -ne $expectedConflictEvidence) {
        throw "unexpected pglogical conflict-history evidence: $conflictEvidence"
    }

    $reportConflictEvidence = Invoke-Sql -Database 'provider' -Sql @"
SELECT COALESCE(jsonb_array_length(
    pgl_validate.report($repairableDriftRunId)
        -> 'tables' -> 0
        -> 'divergences' -> 0
        -> 'conflict_evidence'
), 0)::text
"@
    $expectedReportConflictEvidence = if ($hasQueryableConflictHistory -eq 'true') { '1' } else { '0' }
    if ($reportConflictEvidence -ne $expectedReportConflictEvidence) {
        throw "unexpected pglogical conflict-history evidence count in report(): $reportConflictEvidence"
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
    Invoke-Sql -Database 'cascade' -Port $script:CascadePort -Sql 'CREATE EXTENSION pgl_validate' | Out-Null
    Invoke-Sql -Database 'cascade' -Port $script:CascadePort -Sql 'CREATE EXTENSION pglogical' | Out-Null
    Invoke-Sql -Database 'cascade' -Port $script:CascadePort -Sql 'CREATE TABLE public.accounts(id int PRIMARY KEY, value text)' | Out-Null
    Invoke-Sql -Database 'cascade' -Port $script:CascadePort -Sql "INSERT INTO public.accounts VALUES (1, 'target-drift')" | Out-Null
    Invoke-Sql -Database 'cascade' -Port $script:CascadePort -Sql "SELECT pglogical.create_node('cascade', $cascadeDsnSql)" | Out-Null
    Invoke-Sql -Database 'cascade' -Port $script:CascadePort -Sql @"
SELECT pglogical.create_subscription(
    'sub_from_target',
    $targetDsnSql,
    ARRAY['default','pgl_validate_barrier'],
    false,
    false,
    ARRAY['all']
)
"@ | Out-Null
    $cascadeTargetSlotName = Wait-SubscriptionReady `
        -SubscriberDatabase 'cascade' `
        -SubscriptionName 'sub_from_target' `
        -ProviderDatabase 'target' `
        -SubscriberPort $script:CascadePort `
        -TimeoutSeconds $TimeoutSeconds

    Write-Step 'Validating cascade token visibility is not direct-edge convergence'
    $cascadedOnlyBarrier = Invoke-Sql -Database 'provider' -Sql @"
SELECT token::text || ';' || barrier_end_lsn::text
FROM pgl_validate.remote_inject_barrier(
    $providerDsnSql,
    10,
    30000,
    30000
)
"@
    $cascadedOnlyParts = $cascadedOnlyBarrier.Split(';', 2)
    if ($cascadedOnlyParts.Count -ne 2) {
        throw "unexpected cascaded-only barrier result: $cascadedOnlyBarrier"
    }
    $cascadedOnlyToken = $cascadedOnlyParts[0]
    $cascadedOnlyLsn = $cascadedOnlyParts[1]
    $cascadedOnlyTokenSql = ConvertTo-SqlLiteral $cascadedOnlyToken
    $cascadedOnlyLsnSql = ConvertTo-SqlLiteral $cascadedOnlyLsn
    Wait-SqlEqual `
        -Database 'cascade' `
        -Sql "SELECT count(*)::text FROM pgl_validate.fence_barrier WHERE token = ${cascadedOnlyTokenSql}::uuid" `
        -Expected '1' `
        -Port $script:CascadePort `
        -TimeoutSeconds $TimeoutSeconds

    $probeDirectOriginSql = ConvertTo-SqlLiteral 'pgl_validate_probe_direct_provider_origin'
    Invoke-Sql -Database 'cascade' -Port $script:CascadePort -Sql @"
DO `$`$
BEGIN
    PERFORM pg_replication_origin_create($probeDirectOriginSql);
EXCEPTION WHEN duplicate_object THEN
    NULL;
END
`$`$;
"@ | Out-Null
    $edgeSpecificObservation = Invoke-Sql -Database 'provider' -Sql @"
SELECT token_visible::text || ';' ||
       converged::text || ';' ||
       (origin_progress_lsn >= ${cascadedOnlyLsnSql}::pg_lsn)::text
FROM pgl_validate.remote_observe_barrier(
    $cascadeDsnSql,
    $probeDirectOriginSql,
    ${cascadedOnlyTokenSql}::uuid,
    ${cascadedOnlyLsnSql}::pg_lsn,
    10,
    30000,
    30000
)
"@
    if ($edgeSpecificObservation -ne 'true;false;false') {
        throw "cascaded token was incorrectly treated as direct-edge convergence: $edgeSpecificObservation"
    }

    Write-Step 'Validating duplicate cascade barrier tokens do not stall pglogical apply'
    Set-PglogicalConflictResolution -Value 'error' -Port $script:CascadePort -Database 'cascade'
    Invoke-Sql -Database 'cascade' -Port $script:CascadePort -Sql @"
SELECT pglogical.create_subscription(
    'sub_direct_provider',
    $providerDsnSql,
    ARRAY['pgl_validate_barrier'],
    false,
    false,
    ARRAY[]::text[]
)
"@ | Out-Null
    $cascadeProviderSlotName = Wait-SubscriptionReady `
        -SubscriberDatabase 'cascade' `
        -SubscriptionName 'sub_direct_provider' `
        -ProviderDatabase 'provider' `
        -SubscriberPort $script:CascadePort `
        -TimeoutSeconds $TimeoutSeconds
    $duplicateBarrier = Invoke-Sql -Database 'provider' -Sql @"
SELECT token::text || ';' || barrier_end_lsn::text
FROM pgl_validate.remote_inject_barrier(
    $providerDsnSql,
    10,
    30000,
    30000
)
"@
    $duplicateParts = $duplicateBarrier.Split(';', 2)
    if ($duplicateParts.Count -ne 2) {
        throw "unexpected duplicate barrier result: $duplicateBarrier"
    }
    $duplicateTokenSql = ConvertTo-SqlLiteral $duplicateParts[0]
    Wait-SqlEqual `
        -Database 'cascade' `
        -Sql "SELECT count(*)::text FROM pgl_validate.fence_barrier WHERE token = ${duplicateTokenSql}::uuid" `
        -Expected '2' `
        -Port $script:CascadePort `
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

    Write-Step 'Applying replicate repair with explicit conflict-policy acknowledgement'
    $replicateRepairResult = Invoke-Sql -Database 'provider' -Sql @"
SELECT repair_id::text || ';' || status || ';' || propagation || ';' || (origin_name IS NULL)::text
FROM pgl_validate.apply_repair($driftRunId, 'local', 'target', 'target', 'replicate', true)
"@
    $replicateRepairParts = $replicateRepairResult.Split(';', 4)
    if ($replicateRepairParts.Count -ne 4) {
        throw "unexpected replicate repair result: $replicateRepairResult"
    }
    $replicateRepairId = $replicateRepairParts[0]
    $replicateRepairStatus = $replicateRepairParts[1]
    $replicateRepairPropagation = $replicateRepairParts[2]
    $replicateRepairOriginIsNull = $replicateRepairParts[3]
    if ($replicateRepairStatus -ne 'revalidated' -or
        $replicateRepairPropagation -ne 'replicate' -or
        $replicateRepairOriginIsNull -ne 'true') {
        throw "replicate repair did not run as local-origin acknowledged repair: $replicateRepairResult"
    }

    $replicateRepairAudit = Invoke-Sql -Database 'provider' -Sql @"
SELECT COALESCE(string_agg(action || ':' || post_verdict, ',' ORDER BY action), '<none>')
FROM pgl_validate.repair_result
WHERE repair_id = $replicateRepairId
"@
    if ($replicateRepairAudit -ne 'update:match') {
        throw "unexpected replicate repair audit actions: $replicateRepairAudit"
    }

    Wait-SqlEqual `
        -Database 'cascade' `
        -Port $script:CascadePort `
        -Sql "SELECT value FROM public.accounts WHERE id = 1" `
        -Expected 'same' `
        -TimeoutSeconds $TimeoutSeconds

    $replicatedRepairVerdict = Invoke-Sql -Database 'provider' -Sql @"
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
    if ($replicatedRepairVerdict -ne 'match') {
        throw "unexpected post-replicate-repair compare_table verdict: $replicatedRepairVerdict"
    }

    Write-Step 'Quiescing completed cascade pglogical subscriptions'
    Invoke-Sql `
        -Database 'cascade' `
        -Port $script:CascadePort `
        -Sql "SELECT pglogical.alter_subscription_disable('sub_direct_provider', true)" | Out-Null
    Invoke-Sql `
        -Database 'cascade' `
        -Port $script:CascadePort `
        -Sql "SELECT pglogical.alter_subscription_disable('sub_from_target', true)" | Out-Null
    Wait-ReplicationSlotInactive `
        -Database 'provider' `
        -SlotName $cascadeProviderSlotName `
        -TimeoutSeconds $TimeoutSeconds
    Wait-ReplicationSlotInactive `
        -Database 'target' `
        -SlotName $cascadeTargetSlotName `
        -TimeoutSeconds $TimeoutSeconds

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
SELECT pgl_validate.register_pglogical_peer(
    'seq_target',
    $sequenceTargetDsnSql,
    'seq_sub'::name,
    NULL,
    ARRAY['default']
)
"@ | Out-Null
    Invoke-Sql -Database 'seq_provider' -Sql @"
SELECT setval('public.account_seq'::regclass, 10, true);
SELECT pglogical.synchronize_sequence('public.account_seq'::regclass);
"@ | Out-Null
    Wait-SqlEqual `
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
    if (Test-Path -LiteralPath $cascadeLog) {
        Write-Output '--- pglogical cascade test log tail ---'
        Get-Content -LiteralPath $cascadeLog -Tail 120
    }
    throw
}
finally {
    Stop-TestCluster -Data $data -PgCtl $script:PgCtl
    if (-not $KeepData) {
        Remove-TestData -Data $data
        Remove-TestData -Data $cascadeData
    }
    if ($watchdog -and -not $watchdog.HasExited) {
        Stop-ProcessTree -ProcessId $watchdog.Id
    }
}

$global:LASTEXITCODE = 0
