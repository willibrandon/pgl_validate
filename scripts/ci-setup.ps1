param(
    [ValidateSet(15, 16, 17, 18)]
    [int] $PgMajor = 18,

    [string] $CargoPgrxVersion = '0.19.1',

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

function Install-CargoPgrx {
    Invoke-Logged -FilePath 'cargo' -Arguments @('install', '--locked', 'cargo-pgrx', '--version', $CargoPgrxVersion)
}

function Ensure-ChocolateyPackage {
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

function Initialize-WindowsSourcePostgres {
    Ensure-ChocolateyPackage -CommandName 'perl' -PackageName 'strawberryperl'
    Ensure-ChocolateyPackage -CommandName 'cmake' -PackageName 'cmake'

    $postgresVersion = Get-PostgresSourceVersion -Major $PgMajor
    $architecture = if ($env:PGL_VALIDATE_MSVC_ARCH) {
        $env:PGL_VALIDATE_MSVC_ARCH.ToLowerInvariant()
    }
    else {
        [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
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
