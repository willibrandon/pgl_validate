param(
    [ValidateSet(15, 16, 17, 18)]
    [int] $PgMajor = 18,

    [string] $CargoPgrxVersion = '0.19.1',

    [string] $LlvmVersion = '21.1.7',

    [switch] $BuildPostgresFromSource
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$common = Join-Path $PSScriptRoot 'pgrx-common.ps1'
. $common

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

        Write-Host "+ brew install $formula"
        $output = & $brew install $formula 2>&1
        $exitCode = $LASTEXITCODE
        foreach ($line in $output) {
            $text = "$line"
            if ($text -match '^Warning: postgresql@\d+ was installed but not linked because .+ already installed\. To link this version, run: brew link postgresql@\d+$') {
                Write-Host "Homebrew did not link $formula; CI uses its explicit pg_config path."
                continue
            }

            Write-Host $text
        }

        if ($exitCode -ne 0) {
            throw "brew install $formula exited with code $exitCode."
        }
    }
}

function Get-PostgresSourceVersion {
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

<#
.SYNOPSIS
Unlinks installed versioned PostgreSQL formulae so CI uses explicit pg_config paths instead of Homebrew's global links.
#>
function Disconnect-HomebrewPostgresLinks {
    $brew = Get-PglCommandSource -Name 'brew'
    if (-not $brew) {
        return
    }

    foreach ($major in @(15, 16, 17, 18)) {
        $formula = "postgresql@$major"
        $installed = & $brew list --versions $formula 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($installed -join ''))) {
            continue
        }

        Write-Host "+ brew unlink $formula"
        & $brew unlink $formula
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Could not unlink $formula; continuing because pgrx uses the explicit pg_config path."
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
    Disconnect-HomebrewPostgresLinks
    Install-HomebrewFormula -Formulae @('llvm', 'pkg-config', "postgresql@$PgMajor")

    $llvmPrefix = (& brew --prefix llvm).Trim()
    $llvmBin = Join-Path $llvmPrefix 'bin'
    $libclangPath = Join-Path $llvmPrefix 'lib'
    Add-GitHubPath -Path $llvmBin
    Add-GitHubEnv -Name 'LIBCLANG_PATH' -Value $libclangPath

    $pgPrefix = (& brew --prefix "postgresql@$PgMajor").Trim()
    $pgConfig = Join-Path (Join-Path $pgPrefix 'bin') 'pg_config'
    Invoke-Logged -FilePath 'cargo' -Arguments @('pgrx', 'init', "--pg$PgMajor", $pgConfig)
    Enable-PostgresInstallWrites -PgConfig $pgConfig
    Disconnect-HomebrewPostgresLinks
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

    Invoke-Logged -FilePath 'cargo' -Arguments @('pgrx', 'init', "--pg$PgMajor", 'download')
}

function Initialize-WindowsSourcePostgres {
    Install-ChocolateyPackage -CommandName 'perl' -PackageName 'strawberryperl'
    Install-ChocolateyPackage -CommandName 'cmake' -PackageName 'cmake'

    $postgresVersion = Get-PostgresSourceVersion -Major $PgMajor
    $architecture = if ($env:PGL_VALIDATE_MSVC_ARCH) {
        $env:PGL_VALIDATE_MSVC_ARCH.ToLowerInvariant()
    }
    else {
        [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
    }
    if ($architecture -eq 'arm64') {
        throw 'Native Windows ARM64 PostgreSQL source builds are not supported by the PostgreSQL 15-18 MSVC build scripts used in this CI path. Use the Windows ARM64-hosted x64 matrix lane instead.'
    }

    $pgrxHome = Get-PglPgrxHome
    $installRoot = Join-Path $pgrxHome "postgresql-$postgresVersion-$architecture"
    $pgConfig = Join-Path (Join-Path $installRoot 'bin') 'pg_config.exe'

    if (-not (Test-Path -LiteralPath $pgConfig)) {
        $workDir = Join-Path ([IO.Path]::GetTempPath()) "pgl_validate-postgresql-$postgresVersion-$([guid]::NewGuid())"
        $archivePath = Join-Path $workDir "postgresql-$postgresVersion.tar.gz"
        $sourceUri = "https://ftp.postgresql.org/pub/source/v$postgresVersion/postgresql-$postgresVersion.tar.gz"
        New-Item -ItemType Directory -Force -Path $workDir | Out-Null

        try {
            Invoke-WebRequest -Uri $sourceUri -OutFile $archivePath
            $tar = Get-PglCommandSource -Name 'tar'
            if (-not $tar) {
                throw 'tar is required to extract PostgreSQL source.'
            }

            Invoke-Logged -FilePath $tar -Arguments @('-xzf', $archivePath, '-C', $workDir)
            $sourceRoot = Join-Path $workDir "postgresql-$postgresVersion"
            $msvcRoot = Join-Path (Join-Path (Join-Path $sourceRoot 'src') 'tools') 'msvc'
            if (-not (Test-Path -LiteralPath $msvcRoot)) {
                throw "PostgreSQL $postgresVersion source archive does not contain src/tools/msvc; this CI source build path cannot build it with MSVC."
            }

            Push-Location $sourceRoot
            try {
                $buildScript = Join-Path (Join-Path 'src' 'tools') (Join-Path 'msvc' 'build.pl')
                $installScript = Join-Path (Join-Path 'src' 'tools') (Join-Path 'msvc' 'install.pl')
                Invoke-Logged -FilePath 'perl' -Arguments @($buildScript)
                Invoke-Logged -FilePath 'perl' -Arguments @($installScript, $installRoot)
            }
            finally {
                Pop-Location
            }
        }
        finally {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not (Test-Path -LiteralPath $pgConfig)) {
        throw "PostgreSQL source build did not produce $pgConfig."
    }

    Invoke-Logged -FilePath 'cargo' -Arguments @('pgrx', 'init', "--pg$PgMajor", $pgConfig)
    Enable-PostgresInstallWrites -PgConfig $pgConfig
}

Install-CargoPgrx

if (Test-PglWindows) {
    if ($BuildPostgresFromSource) {
        Initialize-WindowsSourcePostgres
    }
    else {
        Initialize-WindowsPostgres
    }
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
