param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $Command = @('cargo', 'pgrx', 'test', 'pg18')
)

$ErrorActionPreference = 'Stop'

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) {
    throw "vswhere.exe was not found. Install Visual Studio with the C++ workload."
}

$installPath = & $vswhere -latest -products * `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -property installationPath
if (-not $installPath) {
    throw "Visual Studio C++ tools were not found. Install the Desktop development with C++ workload."
}

$vcvars = Join-Path $installPath 'VC\Auxiliary\Build\vcvars64.bat'
if (-not (Test-Path $vcvars)) {
    throw "vcvars64.bat was not found at $vcvars"
}

$argLine = ($Command | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join ' '
& cmd.exe /d /s /c "call `"$vcvars`" >nul && $argLine"
exit $LASTEXITCODE
