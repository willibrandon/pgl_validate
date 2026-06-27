param(
    [ValidateSet(15, 16, 17, 18)]
    [int] $PgMajor = 18,

    [string] $CargoPgrxVersion = '0.19.1',

    [string] $LlvmVersion = '21.1.7'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$common = Join-Path $PSScriptRoot 'pgrx-common.ps1'
. $common
$root = Split-Path -Parent $PSScriptRoot

function Add-GitHubEnv {
    param(
        [string] $Name,
        [string] $Value
    )

    Set-Item -Path "env:$Name" -Value $Value
    if ($env:GITHUB_ENV) {
        "$Name=$Value" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
    }
}

function Add-GitHubPath {
    param([string] $Path)

    $env:PATH = "$Path$([IO.Path]::PathSeparator)$env:PATH"
    if ($env:GITHUB_PATH) {
        $Path | Out-File -FilePath $env:GITHUB_PATH -Append -Encoding utf8
    }
}

function Get-PeMachine {
    param([string] $Path)

    $stream = [IO.File]::Open(
        $Path,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::ReadWrite
    )
    try {
        $reader = [IO.BinaryReader]::new($stream)
        try {
            if ($stream.Length -lt 0x40) {
                return 'unknown'
            }

            $stream.Position = 0x3c
            $peOffset = $reader.ReadInt32()
            if ($peOffset -lt 0 -or ($peOffset + 6) -gt $stream.Length) {
                return 'unknown'
            }

            $stream.Position = $peOffset
            $signature = $reader.ReadUInt32()
            if ($signature -ne 0x00004550) {
                return 'unknown'
            }

            $machine = $reader.ReadUInt16()
            switch ($machine) {
                0x014c { return 'x86' }
                0x8664 { return 'x64' }
                0xaa64 { return 'arm64' }
                default { return "unknown-0x$($machine.ToString('x4'))" }
            }
        }
        finally {
            $reader.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function ConvertTo-WindowsArchitecture {
    param([string] $Architecture)

    if ([string]::IsNullOrWhiteSpace($Architecture)) {
        return [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
    }

    switch ($Architecture.ToLowerInvariant()) {
        'amd64' { return 'x64' }
        'x86_64' { return 'x64' }
        'x64' { return 'x64' }
        'aarch64' { return 'arm64' }
        'arm64' { return 'arm64' }
        default { throw "Unsupported Windows architecture '$Architecture'." }
    }
}

function Test-LibclangArchitecture {
    param(
        [string] $Directory,
        [string] $Architecture
    )

    $dll = Join-Path $Directory 'libclang.dll'
    if (-not (Test-Path -LiteralPath $dll)) {
        return $false
    }

    $actual = Get-PeMachine -Path $dll
    if ($actual -eq $Architecture) {
        return $true
    }

    Write-Warning "Ignoring $dll because it is $actual, but the Rust target needs $Architecture."
    return $false
}

function Get-VisualStudioLibclangCandidates {
    param([string] $Architecture)

    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere)) {
        return @()
    }

    $installPaths = & $vswhere -all -products * -property installationPath 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $installPaths) {
        return @()
    }

    $archFolder = switch ($Architecture) {
        'x64' { 'x64' }
        'arm64' { 'ARM64' }
        default { $Architecture }
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($installPath in $installPaths) {
        [void] $candidates.Add((Join-Path $installPath "VC\Tools\Llvm\$archFolder\bin"))
        [void] $candidates.Add((Join-Path $installPath 'VC\Tools\Llvm\bin'))
    }

    return $candidates
}

function Install-WindowsLlvm {
    param([string] $Architecture)

    if ($Architecture -ne 'x64') {
        $choco = Get-PglCommandSource -Name 'choco'
        if (-not $choco) {
            throw "LLVM for $Architecture was not found and Chocolatey is unavailable."
        }

        Invoke-Logged -FilePath $choco -Arguments @('install', 'llvm', '-y', '--no-progress')
        return
    }

    $installRoot = Join-Path (Get-PglPgrxHome) "llvm-$LlvmVersion-$Architecture"
    $bin = Join-Path $installRoot 'bin'
    if (Test-LibclangArchitecture -Directory $bin -Architecture $Architecture) {
        return
    }

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $installRoot) | Out-Null
    $installer = Join-Path ([IO.Path]::GetTempPath()) "LLVM-$LlvmVersion-win64.exe"
    $uri = "https://github.com/llvm/llvm-project/releases/download/llvmorg-$LlvmVersion/LLVM-$LlvmVersion-win64.exe"

    Write-Host "+ Invoke-WebRequest $uri"
    Invoke-WebRequest -Uri $uri -OutFile $installer

    Write-Host "+ $installer /S /D=$installRoot"
    $process = Start-Process -FilePath $installer -ArgumentList @('/S', "/D=$installRoot") -Wait -PassThru -WindowStyle Hidden
    if ($process.ExitCode -ne 0) {
        throw "LLVM installer exited with code $($process.ExitCode)."
    }
}

function Resolve-WindowsLibclangPath {
    $architecture = ConvertTo-WindowsArchitecture -Architecture $env:PGL_VALIDATE_MSVC_ARCH

    $candidateDirs = New-Object System.Collections.Generic.List[string]
    [void] $candidateDirs.Add((Join-Path (Get-PglPgrxHome) "llvm-$LlvmVersion-$architecture\bin"))
    foreach ($candidate in @('C:\Program Files\LLVM\bin', 'C:\Program Files (x86)\LLVM\bin')) {
        [void] $candidateDirs.Add($candidate)
    }
    if ($architecture -ne 'x64') {
        foreach ($candidate in Get-VisualStudioLibclangCandidates -Architecture $architecture) {
            [void] $candidateDirs.Add($candidate)
        }
    }

    foreach ($candidate in $candidateDirs) {
        if (Test-LibclangArchitecture -Directory $candidate -Architecture $architecture) {
            return $candidate
        }
    }

    Install-WindowsLlvm -Architecture $architecture

    foreach ($candidate in $candidateDirs) {
        if (Test-LibclangArchitecture -Directory $candidate -Architecture $architecture) {
            return $candidate
        }
    }

    throw "Could not find a $architecture libclang.dll after LLVM setup."
}

function Invoke-Logged {
    param(
        [string] $FilePath,
        [string[]] $Arguments
    )

    if ($env:PGL_VALIDATE_RUST_TOOLCHAIN) {
        $commandName = [IO.Path]::GetFileNameWithoutExtension($FilePath)
        if (($commandName -eq 'cargo' -or $commandName -eq 'rustc') -and
            ($Arguments.Count -eq 0 -or -not $Arguments[0].StartsWith('+', [StringComparison]::Ordinal))) {
            $Arguments = @("+$env:PGL_VALIDATE_RUST_TOOLCHAIN") + $Arguments
        }
    }

    Write-Host "+ $FilePath $($Arguments -join ' ')"
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath exited with code $LASTEXITCODE."
    }
}

function Install-HomebrewFormula {
    param([string[]] $Formulae)

    $brew = Get-PglCommandSource -Name 'brew'
    if (-not $brew) {
        throw 'Homebrew was not found.'
    }

    foreach ($formula in $Formulae) {
        $installed = & $brew list --versions $formula 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(($installed -join ''))) {
            Write-Host "+ brew list --versions $formula"
            Write-Host ($installed -join [Environment]::NewLine)
            continue
        }

        Invoke-Logged -FilePath $brew -Arguments @('install', $formula)
    }
}

<#
.SYNOPSIS
Returns the PostgreSQL patch release used by CI for a supported major version.
#>
function Get-PostgresReleaseVersion {
    param([int] $Major)

    switch ($Major) {
        15 { return '15.18' }
        16 { return '16.14' }
        17 { return '17.10' }
        18 { return '18.4' }
        default { throw "Unsupported PostgreSQL major: $Major" }
    }
}

<#
.SYNOPSIS
Returns the supported Windows PostgreSQL binary architecture for CI.
#>
function Get-WindowsPostgresArchitecture {
    $architecture = ConvertTo-WindowsArchitecture -Architecture $env:PGL_VALIDATE_MSVC_ARCH
    if ($architecture -ne 'x64') {
        throw "The official PostgreSQL Windows binary fallback supports x64 only; requested $architecture."
    }

    return $architecture
}

<#
.SYNOPSIS
Returns the official PostgreSQL Windows binary zip URL for the requested major.
#>
function Get-WindowsPostgresBinaryUri {
    param([int] $Major)

    $postgresVersion = Get-PostgresReleaseVersion -Major $Major
    $architecture = Get-WindowsPostgresArchitecture
    return "https://get.enterprisedb.com/postgresql/postgresql-$postgresVersion-1-windows-$architecture-binaries.zip"
}

<#
.SYNOPSIS
Downloads an official PostgreSQL Windows binary zip with bounded retries.
#>
function Invoke-PostgresBinaryDownload {
    param(
        [string] $Uri,
        [string] $OutFile
    )

    $maxAttempts = 4
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            Write-Host "+ Invoke-WebRequest $Uri"
            Invoke-WebRequest `
                -Uri $Uri `
                -OutFile $OutFile `
                -UserAgent 'pgl_validate-ci/1.0'
            return
        }
        catch {
            if ($attempt -eq $maxAttempts) {
                throw
            }

            $delaySeconds = 10 * $attempt
            Write-Host "PostgreSQL binary download attempt $attempt failed: $($_.Exception.Message). Retrying in $delaySeconds seconds."
            Start-Sleep -Seconds $delaySeconds
        }
    }
}

<#
.SYNOPSIS
Installs PostgreSQL from the same official Windows binary zip that cargo-pgrx expects.
#>
function Install-WindowsPostgresBinary {
    $postgresVersion = Get-PostgresReleaseVersion -Major $PgMajor
    $pgrxHome = Get-PglPgrxHome
    $installRoot = Join-Path $pgrxHome $postgresVersion
    $pgConfig = Join-Path (Join-Path $installRoot 'bin') 'pg_config.exe'

    if (-not (Test-Path -LiteralPath $pgConfig)) {
        $workDir = Join-Path ([IO.Path]::GetTempPath()) "pgl_validate-postgresql-$postgresVersion-$([guid]::NewGuid())"
        $archivePath = Join-Path $workDir "postgresql-$postgresVersion-windows.zip"
        $unpackDir = Join-Path $workDir 'unpack'
        New-Item -ItemType Directory -Force -Path $unpackDir | Out-Null

        try {
            $uri = Get-WindowsPostgresBinaryUri -Major $PgMajor
            Invoke-PostgresBinaryDownload -Uri $uri -OutFile $archivePath
            Expand-Archive -LiteralPath $archivePath -DestinationPath $unpackDir -Force

            $firstLevelDirs = @(Get-ChildItem -LiteralPath $unpackDir -Directory)
            if ($firstLevelDirs.Count -ne 1) {
                throw "Expected one top-level directory in PostgreSQL binary zip, found $($firstLevelDirs.Count)."
            }

            if (Test-Path -LiteralPath $installRoot) {
                Remove-Item -LiteralPath $installRoot -Recurse -Force
            }

            New-Item -ItemType Directory -Force -Path $pgrxHome | Out-Null
            Move-Item -LiteralPath $firstLevelDirs[0].FullName -Destination $installRoot
        }
        finally {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not (Test-Path -LiteralPath $pgConfig)) {
        throw "PostgreSQL binary install did not produce $pgConfig."
    }

    Invoke-Logged -FilePath 'cargo' -Arguments @('pgrx', 'init', "--pg$PgMajor", $pgConfig)
    Enable-PostgresInstallWrites -PgConfig $pgConfig
}

<#
.SYNOPSIS
Returns true when the requested cargo-pgrx version is already installed.
#>
function Test-CargoPgrxVersion {
    param([string] $Version)

    $cargoPgrx = Get-PglCommandSource -Name 'cargo-pgrx'
    if (-not $cargoPgrx) {
        return $false
    }

    $reported = & $cargoPgrx --version 2>$null
    return ($LASTEXITCODE -eq 0 -and $reported -match "\b$([regex]::Escape($Version))\b")
}

<#
.SYNOPSIS
Installs cargo-pgrx with retries for transient registry transport failures.
#>
function Install-CargoPgrx {
    if (Test-CargoPgrxVersion -Version $CargoPgrxVersion) {
        Write-Host "cargo-pgrx $CargoPgrxVersion is already installed"
        return
    }

    if (-not $env:CARGO_NET_RETRY) {
        $env:CARGO_NET_RETRY = '10'
    }
    if (-not $env:CARGO_HTTP_MULTIPLEXING) {
        $env:CARGO_HTTP_MULTIPLEXING = 'false'
    }
    if (-not $env:CARGO_HTTP_TIMEOUT) {
        $env:CARGO_HTTP_TIMEOUT = '120'
    }

    $maxAttempts = 3
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            Invoke-Logged -FilePath 'cargo' -Arguments @('install', '--locked', 'cargo-pgrx', '--version', $CargoPgrxVersion)
            return
        }
        catch {
            if ($attempt -eq $maxAttempts) {
                throw
            }

            $delaySeconds = 15 * $attempt
            Write-Warning "cargo-pgrx install attempt $attempt failed: $($_.Exception.Message). Retrying in $delaySeconds seconds."
            Start-Sleep -Seconds $delaySeconds
        }
    }
}

<#
.SYNOPSIS
Fetches Rust crate dependencies before cargo-pgrx commands need Cargo metadata.
#>
function Invoke-CargoDependencyFetch {
    if (-not $env:CARGO_NET_RETRY) {
        $env:CARGO_NET_RETRY = '10'
    }
    if (-not $env:CARGO_HTTP_MULTIPLEXING) {
        $env:CARGO_HTTP_MULTIPLEXING = 'false'
    }
    if (-not $env:CARGO_HTTP_TIMEOUT) {
        $env:CARGO_HTTP_TIMEOUT = '120'
    }

    $manifestPath = Join-Path $root 'Cargo.toml'
    $maxAttempts = 4
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            Invoke-Logged -FilePath 'cargo' -Arguments @('fetch', '--locked', '--manifest-path', $manifestPath)
            $metadataArguments = @('metadata', '--locked', '--format-version', '1', '--manifest-path', $manifestPath)
            if ($env:PGL_VALIDATE_RUST_TOOLCHAIN) {
                $metadataArguments = @("+$env:PGL_VALIDATE_RUST_TOOLCHAIN") + $metadataArguments
            }

            Write-Host "+ cargo $($metadataArguments -join ' ')"
            $metadataOutput = & cargo @metadataArguments 2>&1
            if ($LASTEXITCODE -ne 0) {
                $metadataOutput | Write-Host
                throw "cargo metadata exited with code $LASTEXITCODE."
            }

            return
        }
        catch {
            if ($attempt -eq $maxAttempts) {
                throw
            }

            $delaySeconds = 20 * $attempt
            Write-Warning "cargo dependency fetch attempt $attempt failed: $($_.Exception.Message). Retrying in $delaySeconds seconds."
            Start-Sleep -Seconds $delaySeconds
        }
    }
}

function Install-ChocolateyPackage {
    param(
        [string] $CommandName,
        [string] $PackageName
    )

    if (Get-PglCommandSource -Name $CommandName) {
        return
    }

    $choco = Get-PglCommandSource -Name 'choco'
    if (-not $choco) {
        throw "$CommandName was not found and Chocolatey is unavailable."
    }

    Invoke-Logged -FilePath $choco -Arguments @('install', $PackageName, '-y', '--no-progress')

    if ($PackageName -eq 'strawberryperl') {
        foreach ($path in @('C:\Strawberry\perl\bin', 'C:\Strawberry\c\bin')) {
            if (Test-Path -LiteralPath $path) {
                Add-GitHubPath -Path $path
            }
        }
    }
    elseif ($PackageName -eq 'cmake') {
        $path = 'C:\Program Files\CMake\bin'
        if (Test-Path -LiteralPath $path) {
            Add-GitHubPath -Path $path
        }
    }
}

function Enable-PostgresInstallWrites {
    param([string] $PgConfig)

    if (Test-PglWindows) {
        return
    }

    $paths = @(
        (& $PgConfig --pkglibdir),
        (Join-Path (& $PgConfig --sharedir) 'extension'),
        (& $PgConfig --bindir)
    )

    Invoke-Logged -FilePath 'sudo' -Arguments (@('chmod', '-R', 'a+rwx') + $paths)
}

<#
.SYNOPSIS
Removes runner-provided Homebrew taps that fail current tap-trust checks.
#>
function Remove-UntrustedHomebrewTaps {
    $brew = Get-PglCommandSource -Name 'brew'
    if (-not $brew) {
        return
    }

    $taps = & $brew tap 2>$null
    if ($LASTEXITCODE -ne 0) {
        return
    }

    if ($taps -contains 'aws/tap') {
        Write-Host '+ brew untap aws/tap'
        & $brew untap aws/tap
        if ($LASTEXITCODE -ne 0) {
            Write-Warning 'Could not untap aws/tap; continuing because it is unrelated to PostgreSQL setup.'
        }
    }
}

function Initialize-LinuxPostgres {
    $packages = @(
        'build-essential',
        'ca-certificates',
        'clang',
        'gcc',
        'gnupg',
        'libclang-dev',
        'libkrb5-dev',
        'liblz4-dev',
        'libnuma-dev',
        'libpam0g-dev',
        'libselinux1-dev',
        'libssl-dev',
        'libxml2-dev',
        'libxslt1-dev',
        'libzstd-dev',
        'llvm-dev',
        'lsb-release',
        'make',
        'pkg-config',
        'wget',
        'zlib1g-dev'
    )

    Invoke-Logged -FilePath 'sudo' -Arguments @('apt-get', 'update')
    Invoke-Logged -FilePath 'sudo' -Arguments (@('apt-get', 'install', '-y') + $packages)

    $keyring = '/etc/apt/keyrings/postgresql.gpg'
    if (-not (Test-Path -LiteralPath $keyring)) {
        Invoke-Logged -FilePath 'sudo' -Arguments @('install', '-d', '-m', '0755', '/etc/apt/keyrings')
        $keyPath = Join-Path ([IO.Path]::GetTempPath()) 'postgresql.asc'
        Invoke-WebRequest -Uri 'https://www.postgresql.org/media/keys/ACCC4CF8.asc' -OutFile $keyPath
        Invoke-Logged -FilePath 'gpg' -Arguments @('--dearmor', '--yes', '--output', "$keyPath.gpg", $keyPath)
        Invoke-Logged -FilePath 'sudo' -Arguments @('mv', "$keyPath.gpg", $keyring)
    }

    $codename = (& lsb_release -cs).Trim()
    $repoLine = "deb [signed-by=$keyring] http://apt.postgresql.org/pub/repos/apt $codename-pgdg main"
    $repoFile = '/etc/apt/sources.list.d/pgdg.list'
    $tempRepo = Join-Path ([IO.Path]::GetTempPath()) 'pgdg.list'
    $repoLine | Out-File -FilePath $tempRepo -Encoding ascii
    Invoke-Logged -FilePath 'sudo' -Arguments @('mv', $tempRepo, $repoFile)
    Invoke-Logged -FilePath 'sudo' -Arguments @('apt-get', 'update')
    Invoke-Logged -FilePath 'sudo' -Arguments @('apt-get', 'install', '-y', "postgresql-$PgMajor", "postgresql-server-dev-$PgMajor")

    $pgConfig = "/usr/lib/postgresql/$PgMajor/bin/pg_config"
    Invoke-Logged -FilePath 'cargo' -Arguments @('pgrx', 'init', "--pg$PgMajor", $pgConfig)
    Enable-PostgresInstallWrites -PgConfig $pgConfig
}

function Initialize-MacPostgres {
    Remove-UntrustedHomebrewTaps
    Install-HomebrewFormula -Formulae @('llvm', 'icu4c', 'pkg-config')

    $llvmPrefix = (& brew --prefix llvm).Trim()
    $llvmBin = Join-Path $llvmPrefix 'bin'
    $libclangPath = Join-Path $llvmPrefix 'lib'
    $icuPrefix = (& brew --prefix icu4c).Trim()
    $icuPkgConfigPath = Join-Path (Join-Path $icuPrefix 'lib') 'pkgconfig'
    Add-GitHubPath -Path $llvmBin
    Add-GitHubEnv -Name 'LIBCLANG_PATH' -Value $libclangPath
    $pkgConfigPath = if ($env:PKG_CONFIG_PATH) {
        "$icuPkgConfigPath$([IO.Path]::PathSeparator)$env:PKG_CONFIG_PATH"
    }
    else {
        $icuPkgConfigPath
    }
    Add-GitHubEnv -Name 'PKG_CONFIG_PATH' -Value $pkgConfigPath

    Invoke-Logged -FilePath 'cargo' -Arguments @('pgrx', 'init', "--pg$PgMajor", 'download')
    $pgConfig = Get-PglPgrxPgConfig -PgMajor $PgMajor
    Invoke-Logged -FilePath 'cargo' -Arguments @('pgrx', 'init', "--pg$PgMajor", $pgConfig)
    Enable-PostgresInstallWrites -PgConfig $pgConfig
}

function Initialize-WindowsPostgres {
    $libclang = Resolve-WindowsLibclangPath
    Add-GitHubPath -Path $libclang
    Add-GitHubEnv -Name 'LIBCLANG_PATH' -Value $libclang

    if (-not (Get-PglCommandSource -Name 'cmake')) {
        $choco = Get-PglCommandSource -Name 'choco'
        if (-not $choco) {
            throw 'CMake was not found and Chocolatey is unavailable.'
        }
        Invoke-Logged -FilePath $choco -Arguments @('install', 'cmake', '-y', '--no-progress')
    }

    try {
        Invoke-Logged -FilePath 'cargo' -Arguments @('pgrx', 'init', "--pg$PgMajor", 'download')
    }
    catch {
        Write-Host "cargo-pgrx PostgreSQL download failed; installing PostgreSQL $PgMajor from the official Windows binary zip instead."
        Write-Host $_.Exception.Message
        Install-WindowsPostgresBinary
    }
}

Install-CargoPgrx

if (Test-PglWindows) {
    Initialize-WindowsPostgres
}
elseif (Test-PglMacOS) {
    Initialize-MacPostgres
}
elseif (Test-PglLinux) {
    Initialize-LinuxPostgres
}
else {
    throw 'Unsupported CI operating system.'
}

Invoke-CargoDependencyFetch
