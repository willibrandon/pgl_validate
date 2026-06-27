$script:PglValidateIsWindows = if ($PSVersionTable.PSEdition -eq 'Desktop') {
    $true
}
elseif ($PSVersionTable.ContainsKey('Platform')) {
    $PSVersionTable.Platform -eq 'Win32NT'
}
else {
    [IO.Path]::DirectorySeparatorChar -eq '\'
}

$script:PglValidateIsLinux = if ($PSVersionTable.ContainsKey('Platform')) {
    $PSVersionTable.Platform -eq 'Unix' -and [IO.Directory]::Exists('/proc')
}
else {
    $false
}

$script:PglValidateIsMacOS = if ($PSVersionTable.ContainsKey('Platform')) {
    $PSVersionTable.Platform -eq 'Unix' -and [IO.Directory]::Exists('/System/Library/CoreServices')
}
else {
    $false
}

function Test-PglWindows {
    return $script:PglValidateIsWindows
}

function Test-PglLinux {
    return $script:PglValidateIsLinux
}

function Test-PglMacOS {
    return $script:PglValidateIsMacOS
}

function Get-PglHomeDirectory {
    $homeDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    if (-not $homeDirectory) {
        $homeDirectory = $HOME
    }
    if (-not $homeDirectory) {
        throw 'Could not determine the current user home directory.'
    }

    return $homeDirectory
}

function Get-PglPgrxConfigPath {
    return Join-Path (Join-Path (Get-PglHomeDirectory) '.pgrx') 'config.toml'
}

function Get-PglPgrxHome {
    return Join-Path (Get-PglHomeDirectory) '.pgrx'
}

function Get-PglCommandSource {
    param([string] $Name)

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    if ((Test-PglWindows) -and -not $Name.EndsWith('.exe', [StringComparison]::OrdinalIgnoreCase)) {
        $command = Get-Command "$Name.exe" -ErrorAction SilentlyContinue
        if ($command) {
            return $command.Source
        }
    }

    return $null
}

function Find-PglExecutableInDirectory {
    param(
        [string] $Directory,
        [string] $Name
    )

    $candidates = @($Name)
    if (-not $Name.EndsWith('.exe', [StringComparison]::OrdinalIgnoreCase)) {
        $candidates += "$Name.exe"
    }

    foreach ($candidate in $candidates) {
        $path = Join-Path $Directory $candidate
        if (Test-Path -LiteralPath $path) {
            return (Resolve-Path -LiteralPath $path).Path
        }
    }

    return $null
}

function Get-PglToolPath {
    param(
        [string] $PgConfig,
        [string] $Name
    )

    $binDirectory = Split-Path -Parent $PgConfig
    $tool = Find-PglExecutableInDirectory -Directory $binDirectory -Name $Name
    if ($tool) {
        return $tool
    }

    $fromPath = Get-PglCommandSource -Name $Name
    if ($fromPath) {
        return $fromPath
    }

    throw "Could not find PostgreSQL tool '$Name' next to $PgConfig or on PATH."
}

function Get-PglPgrxPgConfig {
    param([int] $PgMajor)

    $envName = "PG${PgMajor}_PG_CONFIG"
    $envValue = [Environment]::GetEnvironmentVariable($envName)
    if ($envValue -and (Test-Path -LiteralPath $envValue)) {
        return (Resolve-Path -LiteralPath $envValue).Path
    }

    $configPath = Get-PglPgrxConfigPath
    if (Test-Path -LiteralPath $configPath) {
        $configText = Get-Content -LiteralPath $configPath -Raw
        $label = "pg$PgMajor"
        $pattern = "(?m)^\s*$label\s*=\s*['""]([^'""]+)['""]\s*$"
        $match = [regex]::Match($configText, $pattern)
        if ($match.Success -and (Test-Path -LiteralPath $match.Groups[1].Value)) {
            return (Resolve-Path -LiteralPath $match.Groups[1].Value).Path
        }
    }

    $pgrxHome = Get-PglPgrxHome
    if (Test-Path -LiteralPath $pgrxHome) {
        $filter = if (Test-PglWindows) { 'pg_config.exe' } else { 'pg_config' }
        $candidate = Get-ChildItem -LiteralPath $pgrxHome -Filter $filter -Recurse -ErrorAction SilentlyContinue |
            Where-Object {
                try {
                    $version = & $_.FullName --version 2>$null
                    $version -match "PostgreSQL\s+$PgMajor\."
                }
                catch {
                    $false
                }
            } |
            Sort-Object FullName -Descending |
            Select-Object -First 1
        if ($candidate) {
            return $candidate.FullName
        }
    }

    $fromPath = Get-PglCommandSource -Name 'pg_config'
    if ($fromPath) {
        $version = & $fromPath --version
        if ($version -match "PostgreSQL\s+$PgMajor\.") {
            return $fromPath
        }
    }

    throw "Could not find pg_config for PostgreSQL $PgMajor. Run cargo pgrx init --pg$PgMajor download, or pass a pg_config path."
}

function Get-PglExtensionSqlPath {
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

function Stop-PglProcessTree {
    [CmdletBinding(SupportsShouldProcess)]
    param([int] $ProcessId)

    if (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) {
        return
    }

    if (Test-PglWindows) {
        $children = Get-CimInstance Win32_Process | Where-Object { $_.ParentProcessId -eq $ProcessId }
        foreach ($child in $children) {
            Stop-PglProcessTree -ProcessId $child.ProcessId
        }
    }
    else {
        $pgrep = Get-PglCommandSource -Name 'pgrep'
        if ($pgrep) {
            $children = & $pgrep -P $ProcessId 2>$null
            foreach ($child in $children) {
                $childPid = 0
                if ([int]::TryParse($child.ToString().Trim(), [ref] $childPid)) {
                    Stop-PglProcessTree -ProcessId $childPid
                }
            }
        }
    }

    Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
}

function Get-PglPowerShellExecutable {
    $names = if (Test-PglWindows) {
        @('pwsh.exe', 'pwsh', 'powershell.exe', 'powershell')
    }
    else {
        @('pwsh', 'powershell')
    }

    foreach ($name in $names) {
        $source = Get-PglCommandSource -Name $name
        if ($source) {
            return $source
        }
    }

    throw 'Could not find pwsh or powershell on PATH.'
}

<#
.SYNOPSIS
Returns a writable Unix-domain socket option for PostgreSQL test clusters.
#>
function Get-PglUnixSocketOption {
    param([string] $Directory)

    if (Test-PglWindows) {
        return ''
    }

    New-Item -ItemType Directory -Force -Path $Directory | Out-Null
    return "-c unix_socket_directories=$Directory"
}

function Start-PglHiddenProcess {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string] $FilePath,
        [string[]] $ArgumentList
    )

    $startArgs = @{
        FilePath = $FilePath
        ArgumentList = $ArgumentList
        PassThru = $true
    }

    if (Test-PglWindows) {
        $startArgs.WindowStyle = 'Hidden'
    }

    return Start-Process @startArgs
}

function Get-PglProcessInfo {
    if (Test-PglWindows) {
        return Get-CimInstance Win32_Process | ForEach-Object {
            [pscustomobject] @{
                Name = $_.Name
                ProcessId = $_.ProcessId
                CommandLine = $_.CommandLine
            }
        }
    }

    $ps = Get-PglCommandSource -Name 'ps'
    if (-not $ps) {
        return @()
    }

    $arguments = if (Test-PglMacOS) {
        @('-axo', 'pid=,comm=,args=')
    }
    else {
        @('-eo', 'pid=,comm=,args=')
    }

    return & $ps @arguments | ForEach-Object {
        if ($_ -match '^\s*(\d+)\s+(\S+)\s*(.*)$') {
            [pscustomobject] @{
                Name = Split-Path -Leaf $Matches[2]
                ProcessId = [int] $Matches[1]
                CommandLine = $Matches[3]
            }
        }
    }
}
