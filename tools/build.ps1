# Build the RuinsssFormat HAP with the DevEco Studio 26 toolchain.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tools/build.ps1 [assembleHap|clean]
param([string]$Task = 'assembleHap')

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$node = 'D:\DevEco Studio\tools\node\node.exe'
$hvigor = Join-Path $root 'node_modules\@ohos\hvigor\bin\hvigor.js'
$log = Join-Path $root '.build.log'

if (-not (Test-Path -LiteralPath $node)) { throw "Node not found: $node" }
if (-not (Test-Path -LiteralPath $hvigor)) { throw "hvigor not found: $hvigor" }

if ($Task -eq 'clean') {
    $targets = @(
        (Join-Path $root 'entry\build'),
        (Join-Path $root 'entry\libs'),
        (Join-Path $root 'entry\.preview'),
        (Join-Path $root '.hvigor')
    )
    foreach ($target in $targets) {
        $resolved = [System.IO.Path]::GetFullPath($target)
        if ($resolved.StartsWith([System.IO.Path]::GetFullPath($root), [System.StringComparison]::OrdinalIgnoreCase) -and
            (Test-Path -LiteralPath $resolved)) {
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
    Write-Host 'Clean finished.'
    exit 0
}

if ($Task -ne 'assembleHap') {
    throw "Unknown task: $Task (expected assembleHap or clean)"
}

# Compile the NAPI module first; hvigor packages entry/libs/arm64-v8a.
& (Join-Path $PSScriptRoot 'build-native.ps1')
if ($LASTEXITCODE -ne 0) { throw "Native build failed with exit code $LASTEXITCODE" }

$env:DEVECO_SDK_HOME = 'D:\DevEco Studio\sdk'
$env:NODE_HOME = 'D:\DevEco Studio\tools\node'
$env:HVIGOR_USER_HOME = Join-Path $root '.hvigor-home'
$env:DSH_CP_SHIM_DIR = Join-Path $root '.cpshim'
$env:NODE_OPTIONS = '--require ' + ((Join-Path $root 'tools\cp-shim.js') -replace '\\', '/')

# Windows PowerShell 5.1 turns a native program's stderr into a
# NativeCommandError. Let cmd.exe own the redirection and working directory;
# its exit code is hvigor's real exit code.
$errLog = Join-Path $root '.build.err.log'
$commandLine = 'cd /d "' + $root + '" && "' + $node + '" "' + $hvigor +
    '" --mode module -p product=default assembleHap --no-daemon > "' + $log + '" 2>&1'
& cmd.exe /c $commandLine
$code = $LASTEXITCODE
Get-Content -LiteralPath $log
if (Test-Path -LiteralPath $errLog) {
    Get-Content -LiteralPath $errLog
}

if ($code -ne 0) {
    Write-Host "hvigor failed with exit code $code" -ForegroundColor Red
}
exit $code
