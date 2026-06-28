param(
    [ValidateSet(15, 16, 17, 18)]
    [int] $ProviderPgMajor = 15,

    [ValidateSet(15, 16, 17, 18)]
    [int] $TargetPgMajor = 18,

    [string] $PglogicalVersion = $(if ($env:PGL_VALIDATE_PGLOGICAL_VERSION) { $env:PGL_VALIDATE_PGLOGICAL_VERSION } else { '2.5.3' }),

    [switch] $KeepData,

    [ValidateRange(1, 86400)]
    [int] $TimeoutSeconds = 180,

    [ValidateRange(1, 86400)]
    [int] $BuildTimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'

$common = Join-Path $PSScriptRoot 'pgrx-common.ps1'
. $common

$root = Split-Path -Parent $PSScriptRoot
$target = Join-Path $root 'target'
$providerData = Join-Path $target "pglogical-mixed-provider-pg$ProviderPgMajor"
$targetData = Join-Path $target "pglogical-mixed-target-pg$TargetPgMajor"
$providerLog = Join-Path $target "pglogical-mixed-provider-pg$ProviderPgMajor.log"
$targetLog = Join-Path $target "pglogical-mixed-target-pg$TargetPgMajor.log"
$runner = Join-Path $PSScriptRoot 'pgrx-vs.ps1'
$installer = Join-Path $PSScriptRoot 'install-pglogical-release.ps1'
$cleanupScript = Join-Path $PSScriptRoot 'stop-pgrx-test-clusters.ps1'

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

function Invoke-PgrxVisualStudio {
    param(
        [string[]] $Arguments,
        [int] $TimeoutSeconds
    )

    $powershell = Get-PglPowerShellExecutable
    $runnerLiteral = ConvertTo-PowerShellLiteral -Value $runner
    $argumentLiterals = ($Arguments | ForEach-Object { ConvertTo-PowerShellLiteral -Value $_ }) -join ', '
    $script = "& $runnerLiteral @($argumentLiterals); exit `$LASTEXITCODE"
    Invoke-CheckedProcess `
        -FilePath $powershell `
        -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', (ConvertTo-EncodedCommand -Script $script)) `
        -TimeoutSeconds $TimeoutSeconds | Out-Null
}

function ConvertTo-EncodedCommand {
    param([string] $Script)

    $bytes = [System.Text.Encoding]::Unicode.GetBytes($Script)
    return [Convert]::ToBase64String($bytes)
}

function ConvertTo-PowerShellLiteral {
    param([string] $Value)

    return "'" + $Value.Replace("'", "''") + "'"
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
        [string] $Psql,
        [int] $Port,
        [string] $Database,
        [string] $Sql
    )

    $output = & $Psql -X -w -h localhost -p $Port -U postgres -d $Database `
        -v ON_ERROR_STOP=1 -Atq -c $Sql 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "psql failed on port $Port database ${Database}: $($output -join [Environment]::NewLine)"
    }

    return ($output -join "`n").Trim()
}

function Wait-SqlEqual {
    param(
        [string] $Psql,
        [int] $Port,
        [string] $Database,
        [string] $Sql,
        [string] $Expected,
        [int] $TimeoutSeconds
    )

    $deadline = [DateTimeOffset]::Now.AddSeconds($TimeoutSeconds)
    $last = ''

    while ([DateTimeOffset]::Now -lt $deadline) {
        $last = Invoke-Sql -Psql $Psql -Port $Port -Database $Database -Sql $Sql
        if ($last -eq $Expected) {
            return
        }

        Start-Sleep -Milliseconds 250
    }

    throw "timed out waiting for SQL result '$Expected' on port $Port database ${Database}; last result: $last"
}

function Wait-SubscriptionReady {
    param(
        [string] $TargetPsql,
        [int] $TargetPort,
        [string] $TargetDatabase,
        [string] $ProviderPsql,
        [int] $ProviderPort,
        [string] $ProviderDatabase,
        [string] $SubscriptionName,
        [int] $TimeoutSeconds
    )

    $deadline = [DateTimeOffset]::Now.AddSeconds($TimeoutSeconds)
    $last = ''

    while ([DateTimeOffset]::Now -lt $deadline) {
        $status = Invoke-Sql -Psql $TargetPsql -Port $TargetPort -Database $TargetDatabase -Sql @"
SELECT COALESCE((
    SELECT status || '|' || slot_name
    FROM pglogical.show_subscription_status($(ConvertTo-SqlLiteral $SubscriptionName)::name)
), '<missing>|')
"@
        $parts = $status.Split('|', 2)
        $statusValue = $parts[0]
        $slotName = if ($parts.Count -gt 1) { $parts[1] } else { '' }
        $syncReady = Invoke-Sql -Psql $TargetPsql -Port $TargetPort -Database $TargetDatabase -Sql @"
SELECT (NOT EXISTS (
    SELECT 1
    FROM pglogical.local_sync_status
    WHERE sync_status <> 'r'
))::text
"@
        $slotStatus = '<no-slot>'
        if ($slotName) {
            $slotStatus = Invoke-Sql -Psql $ProviderPsql -Port $ProviderPort -Database $ProviderDatabase -Sql @"
SELECT COALESCE((
    SELECT active::text || ':' || confirmed_flush_lsn::text
    FROM pg_replication_slots
    WHERE slot_name = $(ConvertTo-SqlLiteral $slotName)
), '<missing>')
"@
        }

        $last = "status=$statusValue slot=$slotName sync_ready=$syncReady provider_slot=$slotStatus"
        if ($statusValue -eq 'replicating' -and $syncReady -eq 'true' -and $slotStatus.StartsWith('true:')) {
            return $slotName
        }

        Start-Sleep -Milliseconds 250
    }

    throw "timed out waiting for pglogical subscription $SubscriptionName readiness: $last"
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
            Write-Warning "pg_ctl stop failed for ${Data}; falling back to process cleanup: $_"
        }
    }
}

function Stop-TestClusterGroup {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if (-not $PSCmdlet.ShouldProcess($MyInvocation.MyCommand.Name, 'Run')) {
        return
    }

Stop-TestCluster -Data $providerData -PgCtl $script:ProviderPgCtl
    Stop-TestCluster -Data $targetData -PgCtl $script:TargetPgCtl
    & $cleanupScript -Root $root
    Start-Sleep -Milliseconds 500
}

function Remove-TestData {
    [CmdletBinding(SupportsShouldProcess)]
    param([string[]] $Paths)

    foreach ($path in $Paths) {
        if (Test-Path -LiteralPath $path) {
            Assert-UnderRoot -Path $path -Root $root
            for ($attempt = 1; $attempt -le 20; $attempt++) {
                try {
                    Remove-Item -LiteralPath $path -Recurse -Force
                    break
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
}

function Start-CleanupWatchdog {
    [CmdletBinding(SupportsShouldProcess)]
    param([int] $ParentPid)

    if (-not $PSCmdlet.ShouldProcess($MyInvocation.MyCommand.Name, 'Run')) {
        return
    }

    $powershell = Get-PglPowerShellExecutable
    $removeFlag = if ($KeepData) { '$false' } else { '$true' }
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

    return Start-PglHiddenProcess `
        -FilePath $powershell `
        -ArgumentList @(
            '-NoProfile',
            '-ExecutionPolicy',
            'Bypass',
            '-EncodedCommand',
            (ConvertTo-EncodedCommand -Script $watchdogScript)
        )
}

if ($ProviderPgMajor -eq $TargetPgMajor) {
    throw 'ProviderPgMajor and TargetPgMajor must be different for mixed-major coverage.'
}

$providerPgConfig = Get-PglPgrxPgConfig -PgMajor $ProviderPgMajor
$targetPgConfig = Get-PglPgrxPgConfig -PgMajor $TargetPgMajor
$script:ProviderInitDb = Get-PglToolPath -PgConfig $providerPgConfig -Name 'initdb'
$script:ProviderPgCtl = Get-PglToolPath -PgConfig $providerPgConfig -Name 'pg_ctl'
$script:ProviderPsql = Get-PglToolPath -PgConfig $providerPgConfig -Name 'psql'
$script:TargetInitDb = Get-PglToolPath -PgConfig $targetPgConfig -Name 'initdb'
$script:TargetPgCtl = Get-PglToolPath -PgConfig $targetPgConfig -Name 'pg_ctl'
$script:TargetPsql = Get-PglToolPath -PgConfig $targetPgConfig -Name 'psql'
$providerExtensionSql = Get-PglExtensionSqlPath -Root $root -PgConfig $providerPgConfig
$targetExtensionSql = Get-PglExtensionSqlPath -Root $root -PgConfig $targetPgConfig
$providerPort = New-FreePort
$targetPort = New-FreePort
$watchdog = Start-CleanupWatchdog -ParentPid $PID

try {
    Write-Step "Cleaning prior mixed-major pglogical clusters"
    Stop-TestClusterGroup
    if (-not $KeepData) {
        Remove-TestData -Paths @($providerData, $targetData)
    }
    Remove-Item -LiteralPath $providerLog, $targetLog -Force -ErrorAction SilentlyContinue

    Write-Step "Installing pglogical $PglogicalVersion release for pg$ProviderPgMajor and pg$TargetPgMajor"
    Invoke-PgrxVisualStudio `
        -Arguments @(
            'pwsh',
            '-NoProfile',
            '-ExecutionPolicy',
            'Bypass',
            '-File',
            $installer,
            '-PgMajor',
            "$ProviderPgMajor",
            '-Version',
            $PglogicalVersion,
            '-PgConfig',
            $providerPgConfig
        ) `
        -TimeoutSeconds $BuildTimeoutSeconds
    Invoke-PgrxVisualStudio `
        -Arguments @(
            'pwsh',
            '-NoProfile',
            '-ExecutionPolicy',
            'Bypass',
            '-File',
            $installer,
            '-PgMajor',
            "$TargetPgMajor",
            '-Version',
            $PglogicalVersion,
            '-PgConfig',
            $targetPgConfig
        ) `
        -TimeoutSeconds $BuildTimeoutSeconds

    Write-Step "Installing pgl_validate for pg$ProviderPgMajor and pg$TargetPgMajor"
    Invoke-PgrxVisualStudio `
        -Arguments @('cargo', 'pgrx', 'install', '--pg-config', $providerPgConfig, '--no-default-features', '--features', "pg$ProviderPgMajor") `
        -TimeoutSeconds $BuildTimeoutSeconds
    Invoke-PgrxVisualStudio `
        -Arguments @('cargo', 'pgrx', 'install', '--pg-config', $targetPgConfig, '--no-default-features', '--features', "pg$TargetPgMajor") `
        -TimeoutSeconds $BuildTimeoutSeconds

    Write-Step "Generating extension SQL for pg$ProviderPgMajor and pg$TargetPgMajor"
    Invoke-PgrxVisualStudio `
        -Arguments @('cargo', 'pgrx', 'schema', '--pg-config', $providerPgConfig, '--no-default-features', '--features', "pg$ProviderPgMajor", '--out', $providerExtensionSql) `
        -TimeoutSeconds 120
    Invoke-PgrxVisualStudio `
        -Arguments @('cargo', 'pgrx', 'schema', '--pg-config', $targetPgConfig, '--no-default-features', '--features', "pg$TargetPgMajor", '--out', $targetExtensionSql) `
        -TimeoutSeconds 120

    Write-Step "Initializing provider pg$ProviderPgMajor cluster at $providerData"
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Invoke-CheckedProcess `
        -FilePath $script:ProviderInitDb `
        -Arguments @('--locale=C', '--auth=trust', '--username=postgres', '-D', $providerData) `
        -TimeoutSeconds 120 | Out-Null

    Write-Step "Initializing target pg$TargetPgMajor cluster at $targetData"
    Invoke-CheckedProcess `
        -FilePath $script:TargetInitDb `
        -Arguments @('--locale=C', '--auth=trust', '--username=postgres', '-D', $targetData) `
        -TimeoutSeconds 120 | Out-Null

    Write-Step "Starting provider on port $providerPort and target on port $targetPort"
    $providerSocketOption = Get-PglUnixSocketOption -Directory (Join-Path $providerData 'socket')
    $targetSocketOption = Get-PglUnixSocketOption -Directory (Join-Path $targetData 'socket')
    $providerOptions = (@(
        "-p $providerPort",
        '-h localhost',
        $providerSocketOption,
        '-c shared_preload_libraries=pglogical',
        '-c wal_level=logical',
        '-c max_worker_processes=20',
        '-c max_replication_slots=20',
        '-c max_wal_senders=20'
    ) | Where-Object { $_ }) -join ' '
    $targetOptions = (@(
        "-p $targetPort",
        '-h localhost',
        $targetSocketOption,
        '-c shared_preload_libraries=pglogical',
        '-c wal_level=logical',
        '-c max_worker_processes=20',
        '-c max_replication_slots=20',
        '-c max_wal_senders=20'
    ) | Where-Object { $_ }) -join ' '
    Invoke-CheckedProcess `
        -FilePath $script:ProviderPgCtl `
        -Arguments @('start', '-D', $providerData, '-l', $providerLog, '-o', $providerOptions, '-w', '-t', '30') `
        -TimeoutSeconds 45 | Out-Null
    Invoke-CheckedProcess `
        -FilePath $script:TargetPgCtl `
        -Arguments @('start', '-D', $targetData, '-l', $targetLog, '-o', $targetOptions, '-w', '-t', '30') `
        -TimeoutSeconds 45 | Out-Null

    $providerDsn = "host=localhost port=$providerPort dbname=provider user=postgres connect_timeout=5 application_name=pgl_validate_mixed_major"
    $targetDsn = "host=localhost port=$targetPort dbname=target user=postgres connect_timeout=5 application_name=pgl_validate_mixed_major"
    $providerDsnSql = ConvertTo-SqlLiteral $providerDsn
    $targetDsnSql = ConvertTo-SqlLiteral $targetDsn

    Write-Step 'Creating databases, extensions, pglogical nodes, and replicated table'
    Invoke-Sql -Psql $script:ProviderPsql -Port $providerPort -Database 'postgres' -Sql 'CREATE DATABASE provider' | Out-Null
    Invoke-Sql -Psql $script:TargetPsql -Port $targetPort -Database 'postgres' -Sql 'CREATE DATABASE target' | Out-Null
    Invoke-Sql -Psql $script:ProviderPsql -Port $providerPort -Database 'provider' -Sql 'CREATE EXTENSION pgl_validate' | Out-Null
    Invoke-Sql -Psql $script:ProviderPsql -Port $providerPort -Database 'provider' -Sql 'CREATE EXTENSION pglogical' | Out-Null
    Invoke-Sql -Psql $script:TargetPsql -Port $targetPort -Database 'target' -Sql 'CREATE EXTENSION pgl_validate' | Out-Null
    Invoke-Sql -Psql $script:TargetPsql -Port $targetPort -Database 'target' -Sql 'CREATE EXTENSION pglogical' | Out-Null
    Invoke-Sql -Psql $script:ProviderPsql -Port $providerPort -Database 'provider' -Sql "SELECT pglogical.create_node('provider_pg$ProviderPgMajor', $providerDsnSql)" | Out-Null
    Invoke-Sql -Psql $script:TargetPsql -Port $targetPort -Database 'target' -Sql "SELECT pglogical.create_node('target_pg$TargetPgMajor', $targetDsnSql)" | Out-Null
    Invoke-Sql -Psql $script:ProviderPsql -Port $providerPort -Database 'provider' -Sql 'SELECT pgl_validate.ensure_pglogical_barrier_repset()' | Out-Null
    Invoke-Sql -Psql $script:ProviderPsql -Port $providerPort -Database 'provider' -Sql @"
CREATE TABLE public.mixed_major_accounts(
    id int PRIMARY KEY,
    note text NOT NULL,
    payload json NOT NULL,
    price numeric(18,6) NOT NULL,
    seen_at timestamptz NOT NULL
);
SELECT pglogical.replication_set_add_table('default', 'public.mixed_major_accounts'::regclass, false);
"@ | Out-Null
    Invoke-Sql -Psql $script:TargetPsql -Port $targetPort -Database 'target' -Sql @"
CREATE TABLE public.mixed_major_accounts(
    id int PRIMARY KEY,
    note text NOT NULL,
    payload json NOT NULL,
    price numeric(18,6) NOT NULL,
    seen_at timestamptz NOT NULL
);
"@ | Out-Null

    Write-Step 'Verifying generated digest SQL uses deterministic column order and text fallback encodings'
    $encodedPlanOk = Invoke-Sql -Psql $script:ProviderPsql -Port $providerPort -Database 'provider' -Sql @"
SELECT (
    pgl_validate.plan_chunk_sql(
        'public.mixed_major_accounts'::regclass,
        ARRAY['id'],
        NULL,
        NULL,
        NULL,
        ARRAY['default'],
        NULL,
        true
    ) LIKE '%pgl_validate.row_digest(''{1,1,2,2,1}''::int[], t.id, t.note, t.payload, t.price, t.seen_at)%'
)::text
"@
    if ($encodedPlanOk -ne 'true') {
        throw 'mixed-major plan did not pin expected text-fallback encodings for json/numeric columns'
    }

    Write-Step 'Creating mixed-major pglogical subscription'
    Invoke-Sql -Psql $script:TargetPsql -Port $targetPort -Database 'target' -Sql @"
SELECT pglogical.create_subscription(
    'sub_mixed',
    $providerDsnSql,
    ARRAY['default','pgl_validate_barrier'],
    false,
    false,
    ARRAY[]::text[]
)
"@ | Out-Null
    $slotName = Wait-SubscriptionReady `
        -TargetPsql $script:TargetPsql `
        -TargetPort $targetPort `
        -TargetDatabase 'target' `
        -ProviderPsql $script:ProviderPsql `
        -ProviderPort $providerPort `
        -ProviderDatabase 'provider' `
        -SubscriptionName 'sub_mixed' `
        -TimeoutSeconds $TimeoutSeconds

    Write-Step "Replicating rows across pg$ProviderPgMajor -> pg$TargetPgMajor through slot $slotName"
    Invoke-Sql -Psql $script:ProviderPsql -Port $providerPort -Database 'provider' -Sql @"
INSERT INTO public.mixed_major_accounts(id, note, payload, price, seen_at)
VALUES
    (1, 'same', '{"kind":"primary","n":1}', 42.500000, TIMESTAMPTZ '2026-06-26 12:00:00+00'),
    (2, 'unicode-free', '{"kind":"secondary","items":[1,2,3]}', -7.125000, TIMESTAMPTZ '2020-01-02 03:04:05+00')
"@ | Out-Null
    Wait-SqlEqual `
        -Psql $script:TargetPsql `
        -Port $targetPort `
        -Database 'target' `
        -Sql 'SELECT count(*)::text FROM public.mixed_major_accounts' `
        -Expected '2' `
        -TimeoutSeconds $TimeoutSeconds

    Write-Step 'Running pgl_validate.compare_table against mixed-major pglogical peer'
    Invoke-Sql -Psql $script:ProviderPsql -Port $providerPort -Database 'provider' -Sql @"
INSERT INTO pgl_validate.peer(name, dsn, backend, subscription_name, replication_sets)
VALUES ('target_pg$TargetPgMajor', $targetDsnSql, 'pglogical', 'sub_mixed', ARRAY['default'])
"@ | Out-Null
    $compareResult = Invoke-Sql -Psql $script:ProviderPsql -Port $providerPort -Database 'provider' -Sql @"
SELECT run_id::text || ';' || verdict
FROM pgl_validate.compare_table(
    'public.mixed_major_accounts'::regclass,
    ARRAY['target_pg$TargetPgMajor'],
    jsonb_build_object(
        'provider_dsn', $providerDsnSql,
        'provider_node', 'provider_pg$ProviderPgMajor',
        'repsets', jsonb_build_array('default'),
        'fence_timeout_ms', 30000,
        'fence_poll_interval_ms', 100
    )
)
"@
    $compareParts = $compareResult.Split(';', 2)
    if ($compareParts.Count -ne 2) {
        throw "unexpected compare_table output: $compareResult"
    }
    $runId = $compareParts[0]
    $verdict = $compareParts[1]
    if ($verdict -ne 'match') {
        throw "unexpected mixed-major compare_table verdict: $compareResult"
    }

    Write-Step 'Checking mixed-major evidence recorded by the run'
    $evidence = Invoke-Sql -Psql $script:ProviderPsql -Port $providerPort -Database 'provider' -Sql @"
WITH participants AS (
    SELECT string_agg(node || ':' || (pg_version / 10000)::text, ',' ORDER BY node) AS versions
    FROM pgl_validate.run_participant
    WHERE run_id = $runId
), node_results AS (
    SELECT count(*) AS nodes,
           count(DISTINCT lthash) AS distinct_lthash,
           min(n_rows) AS min_rows,
           max(n_rows) AS max_rows
    FROM pgl_validate.table_node_result
    WHERE run_id = $runId
      AND schema_name = 'public'
      AND table_name = 'mixed_major_accounts'
)
SELECT (participants.versions = 'local:${ProviderPgMajor},target_pg${TargetPgMajor}:${TargetPgMajor}')::text || ';' ||
       EXISTS (
           SELECT 1
           FROM pgl_validate.table_plan
           WHERE run_id = $runId
             AND schema_name = 'public'
             AND table_name = 'mixed_major_accounts'
             AND validated_property = 'full'
       )::text || ';' ||
       EXISTS (
           SELECT 1
           FROM pgl_validate.fence_attempt
           WHERE run_id = $runId
             AND status = 'converged'
             AND origin_progress_lsn >= barrier_end_lsn
             AND token_visible
       )::text || ';' ||
       (node_results.nodes = 2 AND node_results.distinct_lthash = 1 AND node_results.min_rows = 2 AND node_results.max_rows = 2)::text
FROM participants, node_results
"@
    if ($evidence -ne 'true;true;true;true') {
        throw "mixed-major run evidence check failed: $evidence"
    }

    Write-Step "Mixed-major pglogical validation passed for pg$ProviderPgMajor -> pg$TargetPgMajor"
}
finally {
    try {
        Stop-TestClusterGroup
    }
    finally {
        if (-not $KeepData) {
            Remove-TestData -Paths @($providerData, $targetData)
        }
        if ($watchdog -and -not $watchdog.HasExited) {
            Stop-Process -Id $watchdog.Id -Force -ErrorAction SilentlyContinue
        }
    }
}
