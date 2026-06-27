param(
    [ValidateSet(15, 16, 17, 18)]
    [int] $PgMajor = 18,

    [string] $Platform = 'windows-x64',

    [string] $PackageDirectory = '',

    [string] $ArtifactDir = '',

    [switch] $VerifyInstall
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$common = Join-Path $PSScriptRoot 'pgrx-common.ps1'
. $common

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ArtifactDir)) {
    $ArtifactDir = Join-Path (Join-Path $root 'target') 'package-artifacts'
}

function Get-PglExtensionVersion {
    <#
    .SYNOPSIS
        Reads the extension default_version from the control file.
    #>
    $control = Get-ChildItem -LiteralPath $root -Filter '*.control' | Select-Object -First 1
    if (-not $control) {
        throw "No extension control file was found under $root."
    }

    $controlText = Get-Content -LiteralPath $control.FullName -Raw
    $versionMatch = [regex]::Match($controlText, "(?m)^\s*default_version\s*=\s*'([^']+)'\s*$")
    if (-not $versionMatch.Success) {
        throw "Could not read default_version from $($control.FullName)."
    }

    return $versionMatch.Groups[1].Value
}

function Get-PglMsiVersion {
    <#
    .SYNOPSIS
        Converts a SemVer-ish extension version into a numeric MSI version.
    #>
    param([string] $Version)

    $numeric = $Version -replace '-.*$', ''
    if ($numeric -notmatch '^\d+\.\d+\.\d+$') {
        throw "MSI_VERSION must be numeric major.minor.patch, got '$numeric' from '$Version'."
    }

    return $numeric
}

function Test-PglPathUnderRoot {
    <#
    .SYNOPSIS
        Guards generated package paths before deleting or overwriting them.
    #>
    param(
        [string] $Path,
        [string] $AllowedRoot
    )

    $rootFull = [IO.Path]::GetFullPath($AllowedRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $pathFull = [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $prefix = "$rootFull$([IO.Path]::DirectorySeparatorChar)"

    if ($pathFull -eq $rootFull -or $pathFull.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    throw "Refusing to remove or overwrite $pathFull because it is outside $rootFull."
}

function Test-PglWindowsPackageLayout {
    <#
    .SYNOPSIS
        Verifies the cargo-pgrx package has the files the MSI installs.
    #>
    param([string] $Directory)

    $library = Join-Path (Join-Path $Directory 'lib') 'pgl_validate.dll'
    $extensionDirectory = Join-Path (Join-Path $Directory 'share') 'extension'
    $control = Join-Path $extensionDirectory 'pgl_validate.control'
    $sql = Get-ChildItem -LiteralPath $extensionDirectory -Filter 'pgl_validate--*.sql' -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if (-not (Test-Path -LiteralPath $library)) {
        throw "Package is missing $library."
    }
    if (-not (Test-Path -LiteralPath $control)) {
        throw "Package is missing $control."
    }
    if (-not $sql) {
        throw "Package is missing pgl_validate--*.sql under $extensionDirectory."
    }
}

function Get-PglMsiProductCode {
    <#
    .SYNOPSIS
        Reads ProductCode from an MSI database.
    #>
    param([string] $MsiPath)

    $installer = New-Object -ComObject WindowsInstaller.Installer
    $database = $installer.OpenDatabase((Resolve-Path $MsiPath).Path, 0)
    $view = $database.OpenView("SELECT ``Value`` FROM ``Property`` WHERE ``Property`` = 'ProductCode'")
    [void] $view.Execute()
    $record = $view.Fetch()
    if (-not $record) {
        throw "Could not read ProductCode from $MsiPath."
    }

    return [string] $record.StringData(1)
}

function Get-PglMsiProductState {
    <#
    .SYNOPSIS
        Reads the Windows Installer state for a product code.
    #>
    param([string] $ProductCode)

    $installer = New-Object -ComObject WindowsInstaller.Installer
    return $installer.ProductState($ProductCode)
}

function Test-PglProcessElevated {
    <#
    .SYNOPSIS
        Checks whether the current Windows process has an elevated admin token.
    #>
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-PglMsiProductCodeFromUninstallEntry {
    <#
    .SYNOPSIS
        Extracts an MSI product code from an uninstall registry entry.
    #>
    param($Entry)

    if ($Entry.PSChildName -match '^\{[0-9A-Fa-f-]{36}\}$') {
        return $Entry.PSChildName
    }

    foreach ($value in @($Entry.UninstallString, $Entry.QuietUninstallString)) {
        if ($value -and $value -match '\{[0-9A-Fa-f-]{36}\}') {
            return $matches[0]
        }
    }

    return $null
}

function Assert-PglNoInstalledMsiProduct {
    <#
    .SYNOPSIS
        Refuses verification when the same PG-major MSI product is installed.
    #>
    $uninstallRoots = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $displayPattern = "pgl_validate * for PostgreSQL $PgMajor"
    $installed = foreach ($rootPath in $uninstallRoots) {
        Get-ItemProperty -Path $rootPath -ErrorAction SilentlyContinue |
            Where-Object {
                if ($_.DisplayName -notlike $displayPattern) {
                    $false
                }
                else {
                    $productCode = Get-PglMsiProductCodeFromUninstallEntry -Entry $_
                    if (-not $productCode) {
                        $true
                    }
                    else {
                        (Get-PglMsiProductState -ProductCode $productCode) -ne -1
                    }
                }
            } |
            Select-Object -First 1
    }

    if ($installed) {
        $names = ($installed | ForEach-Object { $_.DisplayName } | Sort-Object -Unique) -join ', '
        throw "-VerifyInstall refuses to replace an existing MSI install for PostgreSQL ${PgMajor}: $names"
    }
}

function Invoke-PglMsiInstallVerification {
    <#
    .SYNOPSIS
        Performs a silent MSI install into the pgrx PostgreSQL root and checks installed files.
    #>
    param([string] $MsiPath)

    $pgRoot = Join-Path $ArtifactDir "msi-verify-pg$PgMajor"
    $installLog = Join-Path $ArtifactDir "pgl_validate-pg$PgMajor-msi-install.log"
    $uninstallLog = Join-Path $ArtifactDir "pgl_validate-pg$PgMajor-msi-uninstall.log"
    $productCode = Get-PglMsiProductCode -MsiPath $MsiPath
    if (-not (Test-PglProcessElevated)) {
        throw '-VerifyInstall requires an elevated shell because the MSI is per-machine.'
    }
    Assert-PglNoInstalledMsiProduct

    if (Test-Path -LiteralPath $pgRoot) {
        Remove-Item -LiteralPath $pgRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path (Join-Path $pgRoot 'lib') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path (Join-Path $pgRoot 'share') 'extension') | Out-Null

    $install = Start-Process `
        -FilePath 'msiexec.exe' `
        -ArgumentList @('/i', $MsiPath, "POSTGRESQLDIR=$pgRoot", 'WIXUI_DONTSETPATH=1', 'ALLUSERS=1', '/qn', '/norestart', '/l*v', $installLog) `
        -Wait `
        -PassThru
    if ($install.ExitCode -ne 0) {
        if (Test-Path -LiteralPath $installLog) {
            Get-Content -LiteralPath $installLog -Tail 80
        }
        throw "MSI installation failed with code $($install.ExitCode)."
    }

    $installedLibrary = Join-Path (Join-Path $pgRoot 'lib') 'pgl_validate.dll'
    $installedControl = Join-Path (Join-Path (Join-Path $pgRoot 'share') 'extension') 'pgl_validate.control'
    if (-not (Test-Path -LiteralPath $installedLibrary)) {
        throw "MSI did not install $installedLibrary."
    }
    if (-not (Test-Path -LiteralPath $installedControl)) {
        throw "MSI did not install $installedControl."
    }

    $uninstall = Start-Process `
        -FilePath 'msiexec.exe' `
        -ArgumentList @('/x', $productCode, 'ALLUSERS=1', '/qn', '/norestart', '/l*v', $uninstallLog) `
        -Wait `
        -PassThru
    if ($uninstall.ExitCode -ne 0) {
        if (Test-Path -LiteralPath $uninstallLog) {
            Get-Content -LiteralPath $uninstallLog -Tail 80
        }
        throw "MSI uninstall failed with code $($uninstall.ExitCode)."
    }

    $productState = Get-PglMsiProductState -ProductCode $productCode
    if ($productState -ne -1) {
        throw "MSI uninstall left product $productCode in Windows Installer state $productState."
    }
}

if (-not (Test-PglWindows)) {
    throw 'MSI packaging is only supported on Windows.'
}

$wix = Get-PglCommandSource -Name 'wix'
if (-not $wix) {
    throw 'WiX Toolset v5 was not found on PATH. Install it with: dotnet tool install --global wix --version 5.0.2'
}
$wixExtensions = & $wix extension list -g 2>$null
if ($LASTEXITCODE -ne 0 -or -not (($wixExtensions -join "`n") -match 'WixToolset\.UI\.wixext')) {
    throw 'WiX UI extension was not found. Install it with: wix extension add -g WixToolset.UI.wixext/5.0.2'
}

$version = Get-PglExtensionVersion
$msiVersion = Get-PglMsiVersion -Version $version
$packageName = "pgl_validate-$version-pg$PgMajor-$Platform"
if ([string]::IsNullOrWhiteSpace($PackageDirectory)) {
    $PackageDirectory = Join-Path (Join-Path $root 'target') (Join-Path 'package' $packageName)
}

$wxs = Join-Path (Join-Path (Join-Path $root 'packaging') 'windows') 'pgl_validate.wxs'
$licenseRtf = Join-Path (Join-Path (Join-Path $root 'packaging') 'windows') 'license.rtf'
$msiPath = Join-Path $ArtifactDir "$packageName.msi"

Test-PglPathUnderRoot -Path $msiPath -AllowedRoot $root | Out-Null
Test-PglWindowsPackageLayout -Directory $PackageDirectory

New-Item -ItemType Directory -Force -Path $ArtifactDir | Out-Null
if (Test-Path -LiteralPath $msiPath) {
    Remove-Item -LiteralPath $msiPath -Force
}

& $wix build `
    -arch x64 `
    -o $msiPath `
    -ext WixToolset.UI.wixext `
    -d "VERSION=$version" `
    -d "MSI_VERSION=$msiVersion" `
    -d "PG_VERSION=$PgMajor" `
    -d "PackageDir=$PackageDirectory" `
    -d "LicenseRtf=$licenseRtf" `
    $wxs
if ($LASTEXITCODE -ne 0) {
    throw "wix build exited with code $LASTEXITCODE."
}

if ($VerifyInstall) {
    Invoke-PglMsiInstallVerification -MsiPath $msiPath
}

if ($env:GITHUB_OUTPUT) {
    "msi_artifact_name=$packageName-msi" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
    "msi_artifact_path=$msiPath" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
}

Write-Information -MessageData "MSI: $msiPath" -InformationAction Continue
