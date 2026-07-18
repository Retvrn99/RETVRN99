# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PayloadRoot,
    [Parameter(Mandatory = $true)][string]$ToolchainRoot,
    [string]$BuildPlan,
    [string]$ToolchainLock
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($BuildPlan)) {
    $BuildPlan = Join-Path $PSScriptRoot '..\drivers\win98\gsw2d-bench-build-plan.json'
}
if ([string]::IsNullOrWhiteSpace($ToolchainLock)) {
    $ToolchainLock = Join-Path $PSScriptRoot '..\drivers\win98\mingw32-toolchain.lock.json'
}

& (Join-Path $PSScriptRoot 'verify-win98-driver-toolchain.ps1') `
    -ToolchainRoot $ToolchainRoot -LockFile $ToolchainLock | Out-Host
$plan = Get-Content -Raw -LiteralPath $BuildPlan | ConvertFrom-Json
$declared = @($plan.steps | ForEach-Object { $_.outputs })
if ($declared.Count -ne 1 -or $declared[0].relative_path -cne 'gsw2d-bench/gsw2d-bench.exe') {
    throw 'The GSW2D benchmark plan must declare exactly one standalone executable.'
}
$exe = Join-Path ([IO.Path]::GetFullPath($PayloadRoot)) (
    'gsw2d-bench-source\' + [string]$declared[0].relative_path
)
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
    throw "GSW2D benchmark executable not found: $exe"
}
$actual = Get-FileHash -LiteralPath $exe -Algorithm SHA256
if ($actual.Hash.ToLowerInvariant() -cne [string]$declared[0].sha256 -or
    (Get-Item -LiteralPath $exe).Length -ne [long]$declared[0].bytes) {
    throw 'The GSW2D benchmark output does not match its build-plan lock.'
}
Write-Output 'PASS GSW2D benchmark output hash and single-executable boundary.'

$lock = Get-Content -Raw -LiteralPath $ToolchainLock | ConvertFrom-Json
$toolRoot = Join-Path ([IO.Path]::GetFullPath($ToolchainRoot)) $lock.extracted.relative_path
$objdump = Join-Path $toolRoot 'bin\objdump.exe'
$strings = Join-Path $toolRoot 'bin\strings.exe'
$pe = @(& $objdump -p $exe 2>&1)
if ($LASTEXITCODE -ne 0) { throw 'objdump failed for the GSW2D benchmark.' }
$imports = @(
    $pe | ForEach-Object {
        if ([string]$_ -match '^\s*DLL Name:\s*(\S+)\s*$') { $Matches[1] }
    } | Sort-Object -Unique
)
$expectedImports = @('GDI32.dll', 'KERNEL32.dll', 'USER32.dll')
if (Compare-Object $imports $expectedImports -CaseSensitive) {
    throw "Unexpected GSW2D benchmark imports: $($imports -join ', ')"
}
if (-not ($pe -match '^MajorSubsystemVersion\s+4$') -or
    -not ($pe -match '^MinorSubsystemVersion\s+0$') -or
    -not ($pe -match '^Subsystem\s+00000003\s+\(Windows CUI\)$')) {
    throw 'The GSW2D benchmark is not a Windows 4.0 console executable.'
}
$text = @(& $strings -a $exe 2>&1)
if ($LASTEXITCODE -ne 0) { throw 'strings failed for the GSW2D benchmark.' }
foreach ($marker in @(
    'GSW2D_BENCH BEGIN bpp=',
    'GSW2D_BENCH ROP3 ',
    'solid',
    'pattern',
    ' passed=',
    'GSW2D_BENCH PERF pixels_per_second=',
    'GSW2D_BENCH PASS',
    'GSW2D_BENCH FAIL'
)) {
    if ($text -notcontains $marker) { throw "Missing GSW2D benchmark marker '$marker'." }
}
if ($text -match '(?i:msvcrt|ucrt|opengl|mesa)') {
    throw 'The GSW2D benchmark contains a forbidden runtime or graphics dependency.'
}
Write-Output 'PASS GSW2D benchmark PE32, Win98 4.0, imports, and acceptance markers.'
