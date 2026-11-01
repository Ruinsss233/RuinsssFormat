# Build the native NAPI module for arm64 HarmonyOS devices.
# The hvigor CMake/Ninja path is intentionally bypassed: on this Windows host
# CMake's compiler ABI probe and Ninja child-process handling can hang.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tools/build-native.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$sdk = 'D:\DevEco Studio\sdk\default\openharmony'
$clang = Join-Path $sdk 'native\llvm\bin\clang++.exe'
$sysroot = Join-Path $sdk 'native\sysroot'
$source = Join-Path $root 'entry\src\main\cpp\ruinsss_media.cpp'
$outDir = Join-Path $root 'entry\libs\arm64-v8a'
$output = Join-Path $outDir 'libruinsss_media.so'

if (-not (Test-Path -LiteralPath $clang)) { throw "clang++ not found: $clang" }
if (-not (Test-Path -LiteralPath $source)) { throw "native source not found: $source" }
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

# PowerShell 5.1 mangles commas in bare -Wl,... arguments, so always splat an
# argument array instead of building one long command string.
$params = @(
    '--target=aarch64-linux-ohos',
    '-fPIC',
    '-shared',
    '-O3',
    '-DNDEBUG',
    '-std=c++17',
    '-D__MUSL__',
    "-I$sysroot\usr\include",
    "-L$sysroot\usr\lib\aarch64-linux-ohos",
    '-Wl,-soname,libruinsss_media.so',
    '-Wl,--build-id=sha1',
    '-Wl,--no-undefined',
    '-static-libstdc++',
    '-lace_napi.z',
    '-lhilog_ndk.z',
    '-lnative_media_core',
    '-lnative_media_codecbase',
    '-lnative_media_acodec',
    '-lnative_media_avsource',
    '-lnative_media_avdemuxer',
    '-lnative_media_avmuxer',
    '-o', $output,
    $source
)

& $clang @params
if ($LASTEXITCODE -ne 0) {
    throw "Native build failed with exit code $LASTEXITCODE"
}

$info = Get-Item -LiteralPath $output
Write-Host ("Native module: {0} ({1:N0} bytes)" -f $info.FullName, $info.Length)
