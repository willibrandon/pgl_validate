param(
    [ValidateSet(15, 16, 17, 18)]
    [int] $PgMajor = 18,

    [switch] $KeepData,

    [ValidateRange(1, 86400)]
    [int] $TimeoutSeconds = 180
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$data = Join-Path $root 'target\pglogical-test-pgdata'
$log = Join-Path $root 'target\pglogical-test.log'
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

    $children = Get-CimInstance Win32_Process | Where-Object { $_.ParentProcessId -eq $ProcessId }
    foreach ($child in $children) {
        Stop-ProcessTree -ProcessId $child.ProcessId
    }

    Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
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
    param([string] $PgConfig)

    $control = Get-ChildItem -LiteralPath $root -Filter '*.control' | Select-Object -First 1
    if (-not $control) {
        throw "No extension control file was found under $root."
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

    $powershell = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
    if (-not $powershell) {
        $powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
    }

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
    return Start-Process -FilePath $powershell `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded) `
        -WindowStyle Hidden `
        -PassThru
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
        [string] $Sql
    )

    $output = & $script:Psql -X -w -h localhost -p $script:Port -U postgres -d $Database `
        -v ON_ERROR_STOP=1 -Atq -c $Sql 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "psql failed on database ${Database}: $($output -join [Environment]::NewLine)"
    }

    return ($output -join "`n").Trim()
}

function Wait-SubscriptionReady {
    param(
        [int] $TimeoutSeconds
    )

    $deadline = [DateTimeOffset]::Now.AddSeconds($TimeoutSeconds)
    $last = ''

    while ([DateTimeOffset]::Now -lt $deadline) {
        $status = Invoke-Sql -Database 'target' -Sql @"
SELECT COALESCE((
    SELECT status || '|' || slot_name
    FROM pglogical.show_subscription_status('sub')
), '<missing>|')
"@
        $parts = $status.Split('|', 2)
        $statusValue = $parts[0]
        $slotName = if ($parts.Count -gt 1) { $parts[1] } else { '' }
        $sync = Invoke-Sql -Database 'target' -Sql @"
SELECT COALESCE(
    string_agg(
        sync_kind::text || ':' || sync_status::text || ':' || sync_statuslsn::text,
        ',' ORDER BY sync_kind, sync_nspname, sync_relname
    ),
    '<none>'
)
FROM pglogical.local_sync_status
"@
        $syncReady = Invoke-Sql -Database 'target' -Sql @"
SELECT (NOT EXISTS (
    SELECT 1
    FROM pglogical.local_sync_status
    WHERE sync_status <> 'r'
))::text
"@
        $slotStatus = '<no-slot>'
        if ($slotName) {
            $slotStatus = Invoke-Sql -Database 'provider' -Sql @"
SELECT COALESCE((
    SELECT active::text || ':' || confirmed_flush_lsn::text
    FROM pg_replication_slots
    WHERE slot_name = $(Sql-Literal $slotName)
), '<missing>')
"@
        }

        $last = "status=$statusValue slot=$slotName sync=$sync sync_ready=$syncReady provider_slot=$slotStatus"
        if ($statusValue -eq 'replicating' -and $syncReady -eq 'true' -and $slotStatus.StartsWith('true:')) {
            return $slotName
        }

        Start-Sleep -Milliseconds 250
    }

    throw "timed out waiting for pglogical subscription readiness: $last"
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

$pgConfig = Get-PgrxPgConfig -PgMajor $PgMajor
$pgBin = Split-Path -Parent $pgConfig
$script:InitDb = Join-Path $pgBin 'initdb.exe'
$script:PgCtl = Join-Path $pgBin 'pg_ctl.exe'
$script:Psql = Join-Path $pgBin 'psql.exe'
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
    $serverOptions = "-p $script:Port -h localhost -c shared_preload_libraries=pglogical -c wal_level=logical -c max_worker_processes=20 -c max_replication_slots=20 -c max_wal_senders=20"
    Invoke-CheckedProcess `
        -FilePath $script:PgCtl `
        -Arguments @('start', '-D', $data, '-l', $log, '-o', $serverOptions, '-w', '-t', '30') `
        -TimeoutSeconds 45 | Out-Null

    Write-Step 'Creating coordinator/provider/target databases and extensions'
    Invoke-Sql -Database 'postgres' -Sql 'CREATE DATABASE provider' | Out-Null
    Invoke-Sql -Database 'postgres' -Sql 'CREATE DATABASE target' | Out-Null
    Invoke-Sql -Database 'postgres' -Sql 'CREATE EXTENSION pgl_validate' | Out-Null

    $providerDsn = "host=localhost port=$script:Port dbname=provider user=postgres connect_timeout=5 application_name=pgl_validate_pglogical"
    $targetDsn = "host=localhost port=$script:Port dbname=target user=postgres connect_timeout=5 application_name=pgl_validate_pglogical"
    $providerDsnSql = Sql-Literal $providerDsn
    $targetDsnSql = Sql-Literal $targetDsn

    Write-Step 'Creating pglogical provider node and barrier replication set'
    Invoke-Sql -Database 'provider' -Sql 'CREATE EXTENSION pgl_validate' | Out-Null
    Invoke-Sql -Database 'provider' -Sql 'CREATE EXTENSION pglogical' | Out-Null
    Invoke-Sql -Database 'provider' -Sql "SELECT pglogical.create_node('provider', $providerDsnSql)" | Out-Null
    Invoke-Sql -Database 'provider' -Sql 'SELECT pgl_validate.ensure_pglogical_barrier_repset()' | Out-Null
    Invoke-Sql -Database 'provider' -Sql @"
CREATE TABLE public.accounts(id int PRIMARY KEY, value text);
SELECT pglogical.replication_set_add_table('default', 'public.accounts'::regclass, false);
"@ | Out-Null

    Write-Step 'Creating pglogical target node and subscription'
    Invoke-Sql -Database 'target' -Sql 'CREATE EXTENSION pgl_validate' | Out-Null
    Invoke-Sql -Database 'target' -Sql 'CREATE EXTENSION pglogical' | Out-Null
    Invoke-Sql -Database 'target' -Sql 'CREATE TABLE public.accounts(id int PRIMARY KEY, value text)' | Out-Null
    Invoke-Sql -Database 'target' -Sql "SELECT pglogical.create_node('target', $targetDsnSql)" | Out-Null
    Invoke-Sql -Database 'target' -Sql @"
SELECT pglogical.create_subscription(
    'sub',
    $providerDsnSql,
    ARRAY['default','pgl_validate_barrier'],
    false,
    false,
    ARRAY['all']
)
"@ | Out-Null

    Write-Step 'Waiting for pglogical subscription readiness'
    $slotName = Wait-SubscriptionReady -TimeoutSeconds $TimeoutSeconds
    $slotNameSql = Sql-Literal $slotName

    Write-Step 'Replicating user table row for compare_table validation'
    Invoke-Sql -Database 'provider' -Sql "INSERT INTO public.accounts VALUES (1, 'same')" | Out-Null
    Wait-SqlEquals `
        -Database 'target' `
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

    Write-Step 'Validating pglogical sequence buffer-window semantics'
    Invoke-Sql -Database 'provider' -Sql @"
CREATE SEQUENCE public.account_seq CACHE 5;
SELECT pglogical.replication_set_add_sequence(
    'default',
    'public.account_seq'::regclass,
    true
);
"@ | Out-Null
    Invoke-Sql -Database 'target' -Sql 'CREATE SEQUENCE public.account_seq CACHE 5' | Out-Null
    Invoke-Sql -Database 'provider' -Sql @"
SELECT setval('public.account_seq'::regclass, 10, true);
SELECT pglogical.synchronize_sequence('public.account_seq'::regclass);
"@ | Out-Null
    Wait-SqlEquals `
        -Database 'target' `
        -Sql 'SELECT (last_value >= 10)::text FROM public.account_seq' `
        -Expected 'true' `
        -TimeoutSeconds $TimeoutSeconds

    $sequenceVerdict = Invoke-Sql -Database 'provider' -Sql @"
SELECT verdict || ';' || within_contract::text
FROM pgl_validate.compare_sequence(
    'public.account_seq'::regclass,
    ARRAY['target'],
    jsonb_build_object(
        'provider_dsn', $providerDsnSql,
        'provider_node', 'provider',
        'fence_timeout_ms', 30000,
        'fence_poll_interval_ms', 100
    )
)
"@
    if ($sequenceVerdict -ne 'match;true') {
        throw "unexpected sequence compare result: $sequenceVerdict"
    }

    Invoke-Sql -Database 'target' -Sql "SELECT setval('public.account_seq'::regclass, 1, true)" | Out-Null
    $sequenceBehind = Invoke-Sql -Database 'provider' -Sql @"
SELECT verdict || ';' || within_contract::text
FROM pgl_validate.compare_sequence(
    'public.account_seq'::regclass,
    ARRAY['target'],
    jsonb_build_object(
        'provider_dsn', $providerDsnSql,
        'provider_node', 'provider',
        'fence_timeout_ms', 30000,
        'fence_poll_interval_ms', 100
    )
)
"@
    if ($sequenceBehind -ne 'behind;false') {
        throw "subscriber-behind sequence drift was not detected: $sequenceBehind"
    }

    Write-Step 'Creating subscriber-side drift and confirming key-level divergence'
    Invoke-Sql -Database 'target' -Sql "UPDATE public.accounts SET value = 'target-drift' WHERE id = 1" | Out-Null
    $driftVerdict = Invoke-Sql -Database 'provider' -Sql @"
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

    Write-Output "pglogical fence, compare_table, and divergence recheck tests passed on pg$PgMajor using slot $slotName"
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
