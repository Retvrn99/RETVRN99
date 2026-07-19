# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ToolchainRoot,
    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$sourceDirectory = [IO.Path]::GetFullPath($PSScriptRoot)
$repoRoot = [IO.Path]::GetFullPath((Join-Path $sourceDirectory '..\..\..\..'))
$lockFile = Join-Path $repoRoot 'drivers\win98\mingw32-toolchain.lock.json'
& (Join-Path $repoRoot 'scripts\verify-win98-driver-toolchain.ps1') `
    -ToolchainRoot $ToolchainRoot -LockFile $lockFile | Out-Host
$lock = Get-Content -Raw -LiteralPath $lockFile | ConvertFrom-Json
$toolRoot = Join-Path ([IO.Path]::GetFullPath($ToolchainRoot)) $lock.extracted.relative_path
$gcc = Join-Path $toolRoot 'bin\gcc.exe'
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $sourceDirectory 'out'
}
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
[void](New-Item -ItemType Directory -Force -Path $outputRoot)
$output = Join-Path $outputRoot 'GSWSMOKE.EXE'
$arguments = @(
    '-std=gnu99', '-Wall', '-Wextra', '-Werror', '-Os', '-pipe',
    '-ffreestanding', '-fno-builtin', '-fno-ident', '-fomit-frame-pointer',
    '-fno-asynchronous-unwind-tables', '-fno-unwind-tables', '-fno-stack-protector',
    '-DNDEBUG', '-march=pentium2', '-mtune=core2', '-static', '-nostdlib',
    '-nodefaultlibs', '-I.', 'main.c', '-lwinmm', '-ladvapi32', '-lkernel32', '-lgcc',
    '-Wl,--entry,_mainCRTStartup,--no-insert-timestamp,--disable-dynamicbase,--disable-nxcompat,--subsystem,console:4.0,--image-base,0x00400000,--strip-all',
    '-o', $output
)
$savedPath = $env:PATH
try {
    $env:PATH = (Join-Path $toolRoot 'bin') + [IO.Path]::PathSeparator + $savedPath
    Push-Location $sourceDirectory
    try { & $gcc @arguments 2>&1 | Out-Host } finally { Pop-Location }
    if ($LASTEXITCODE -ne 0) { throw 'The GSW-Sound guest smoke build failed.' }
}
finally {
    $env:PATH = $savedPath
}
$item = Get-Item -LiteralPath $output
$hash = (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Output ("GSWSMOKE.EXE bytes={0} sha256={1}" -f $item.Length, $hash)
