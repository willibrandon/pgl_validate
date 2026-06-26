param(
    [ValidateSet(15, 16, 17, 18)]
    [int] $PgMajor = 18,

    [string] $CargoPgrxVersion = '0.19.1'
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

function Invoke-Logged {
    param(
        [string] $FilePath,
        [string[]] $Arguments
    )

    Write-Host "+ $FilePath $($Arguments -join ' ')"
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath exited with code $LASTEXITCODE."
    }
}

function Install-CargoPgrx {
    Invoke-Logged -FilePath 'cargo' -Arguments @('install', '--locked', 'cargo-pgrx', '--version', $CargoPgrxVersion)
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

function Initialize-LinuxPostgres {
    $packages = @(
        'build-essential',
        'ca-certificates',
        'clang',
        'gcc',
        'gnupg',
        'libclang-dev',
        'libssl-dev',
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
    Invoke-Logged -FilePath 'brew' -Arguments @('install', 'llvm', 'pkg-config', "postgresql@$PgMajor")

    $llvmPrefix = (& brew --prefix llvm).Trim()
    $llvmBin = Join-Path $llvmPrefix 'bin'
    $libclangPath = Join-Path $llvmPrefix 'lib'
    Add-GitHubPath -Path $llvmBin
    Add-GitHubEnv -Name 'LIBCLANG_PATH' -Value $libclangPath

    $pgPrefix = (& brew --prefix "postgresql@$PgMajor").Trim()
    $pgConfig = Join-Path (Join-Path $pgPrefix 'bin') 'pg_config'
    Invoke-Logged -FilePath 'cargo' -Arguments @('pgrx', 'init', "--pg$PgMajor", $pgConfig)
    Enable-PostgresInstallWrites -PgConfig $pgConfig
}

function Initialize-WindowsPostgres {
    $libclang = 'C:\Program Files\LLVM\bin'
    if (-not (Test-Path -LiteralPath (Join-Path $libclang 'libclang.dll'))) {
        $choco = Get-PglCommandSource -Name 'choco'
        if (-not $choco) {
            throw 'LLVM was not found and Chocolatey is unavailable.'
        }
        Invoke-Logged -FilePath $choco -Arguments @('install', 'llvm', '-y', '--no-progress')
    }

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
