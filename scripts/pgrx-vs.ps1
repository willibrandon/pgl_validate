param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $Command = @('cargo', 'pgrx', 'test', 'pg18')
)

$ErrorActionPreference = 'Stop'

$common = Join-Path $PSScriptRoot 'pgrx-common.ps1'
. $common

if (-not (Test-PglWindows)) {
    if ($Command.Length -gt 1) {
        & $Command[0] $Command[1..($Command.Length - 1)]
    }
    else {
        & $Command[0]
    }
    exit $LASTEXITCODE
}

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) {
    throw "vswhere.exe was not found. Install Visual Studio with the C++ workload."
}

$requestedArch = $env:PGL_VALIDATE_MSVC_ARCH
if (-not $requestedArch) {
    $requestedArch = if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq [Runtime.InteropServices.Architecture]::Arm64) {
        'arm64'
    }
    else {
        'x64'
    }
}
$requestedArch = $requestedArch.ToLowerInvariant()

$vcvarsName = switch ($requestedArch) {
    'x64' {
        'vcvars64.bat'
        break
    }
    'arm64' {
        'vcvarsarm64.bat'
        break
    }
    default {
        throw "Unsupported MSVC architecture '$requestedArch'. Use x64 or arm64."
    }
}

$requiredComponent = switch ($requestedArch) {
    'x64' { 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64' }
    'arm64' { 'Microsoft.VisualStudio.Component.VC.Tools.ARM64' }
}

$installPath = & $vswhere -latest -products * `
    -requires $requiredComponent `
    -property installationPath
if (-not $installPath) {
    throw "Visual Studio C++ tools for $requestedArch were not found. Install the Desktop development with C++ workload for $requestedArch."
}

$vcvars = Join-Path $installPath "VC\Auxiliary\Build\$vcvarsName"
if (-not (Test-Path $vcvars)) {
    throw "$vcvarsName was not found at $vcvars"
}

$argLine = ($Command | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join ' '
& cmd.exe /d /s /c "call `"$vcvars`" >nul && $argLine"
exit $LASTEXITCODE
