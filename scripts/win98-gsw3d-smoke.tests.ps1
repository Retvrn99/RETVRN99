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
    $BuildPlan = Join-Path $PSScriptRoot '..\drivers\win98\gsw3d-smoke-build-plan.json'
}
if ([string]::IsNullOrWhiteSpace($ToolchainLock)) {
    $ToolchainLock = Join-Path $PSScriptRoot '..\drivers\win98\mingw32-toolchain.lock.json'
}

& (Join-Path $PSScriptRoot 'verify-win98-driver-toolchain.ps1') `
    -ToolchainRoot $ToolchainRoot -LockFile $ToolchainLock | Out-Host
$plan = Get-Content -Raw -LiteralPath $BuildPlan | ConvertFrom-Json
$declared = @($plan.steps | ForEach-Object { $_.outputs })
if ($declared.Count -ne 1 -or $declared[0].relative_path -cne 'gsw3d-smoke/gsw3d-smoke.exe') {
    throw 'The GSW3D smoke plan must declare exactly one standalone executable.'
}
$exe = Join-Path ([IO.Path]::GetFullPath($PayloadRoot)) (
    'gsw3d-smoke-source\' + [string]$declared[0].relative_path
)
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Smoke executable not found: $exe" }
$item = Get-Item -LiteralPath $exe
$hash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant()
if ([UInt64]$item.Length -ne [UInt64]$declared[0].bytes -or
    $hash -cne [string]$declared[0].sha256) {
    throw 'The GSW3D smoke executable does not match its reviewed output.'
}

$lock = Get-Content -Raw -LiteralPath $ToolchainLock | ConvertFrom-Json
$toolRoot = Join-Path ([IO.Path]::GetFullPath($ToolchainRoot)) $lock.extracted.relative_path
$gcc = Join-Path $toolRoot 'bin\gcc.exe'
$objdump = Join-Path $toolRoot 'bin\objdump.exe'
$strings = Join-Path $toolRoot 'bin\strings.exe'
$sourceDirectory = Join-Path ([IO.Path]::GetFullPath($PayloadRoot)) (
    'gsw3d-smoke-source\gsw3d-smoke'
)
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'retvrn99-gsw3d-fixture-{0}' -f [Guid]::NewGuid().ToString('N')
)
[void](New-Item -ItemType Directory -Path $fixtureRoot)
try {
    $dumpExe = Join-Path $fixtureRoot 'gsw3d-fixture-dump.exe'
    $dumpArguments = [Collections.Generic.List[string]]::new()
    [void]$dumpArguments.Add('-DGSW3D_SMOKE_FIXTURE_DUMP')
    [void]$dumpArguments.Add('-Wno-unused-function')
    $skip = $false
    foreach ($argument in @($plan.steps[0].arguments)) {
        if ($skip) { $skip = $false; continue }
        if ([string]$argument -ceq '-o') { $skip = $true; continue }
        [void]$dumpArguments.Add([string]$argument)
    }
    [void]$dumpArguments.Add('-o')
    [void]$dumpArguments.Add($dumpExe)
    $savedPath = $env:PATH
    try {
        $env:PATH = (Join-Path $toolRoot 'bin') + [IO.Path]::PathSeparator + $savedPath
        Push-Location $sourceDirectory
        try { & $gcc @dumpArguments 2>&1 | Out-Host } finally { Pop-Location }
        if ($LASTEXITCODE -ne 0) { throw 'The GSW3D semantic fixture build failed.' }
        Push-Location $fixtureRoot
        try { & $dumpExe } finally { Pop-Location }
        if ($LASTEXITCODE -ne 0) { throw 'The GSW3D semantic fixture dump failed.' }
    }
    finally {
        $env:PATH = $savedPath
    }

    $fixture = [IO.File]::ReadAllBytes((Join-Path $fixtureRoot 'GSW3D.FIX'))
    if ($fixture.Length -ne 572) { throw "Unexpected GSW3D fixture length: $($fixture.Length)" }
    $hostFixturePath = Join-Path $PSScriptRoot '..\src\vga\gsw3d_triangle_fixture_tests.odin'
    $hostFixture = Get-Content -Raw -LiteralPath $hostFixturePath
    function Get-HostFixtureHash {
        param([Parameter(Mandatory = $true)][string]$Name)
        $pattern = [regex]::Escape($Name) + '\s*::\s*\[32\]u8\s*\{(?<body>[\s\S]*?)\}'
        $match = [regex]::Match($hostFixture, $pattern)
        if (-not $match.Success) { throw "Host fixture hash not found: $Name" }
        $octets = [regex]::Matches($match.Groups['body'].Value, '0x([0-9A-Fa-f]{2})')
        if ($octets.Count -ne 32) { throw "Host fixture hash is malformed: $Name" }
        return (($octets | ForEach-Object { $_.Groups[1].Value }) -join '').ToLowerInvariant()
    }
    $profiles = @(
        @{ Name = 'definitions'; Offset = 0; Length = 128; Hash = Get-HostFixtureHash 'GSW3D_TRIANGLE_FIXTURE_DEFINITIONS_SHA256' },
        @{ Name = 'vertices'; Offset = 128; Length = 60; Hash = Get-HostFixtureHash 'GSW3D_TRIANGLE_FIXTURE_VERTICES_SHA256' },
        @{ Name = 'render'; Offset = 188; Length = 360; Hash = Get-HostFixtureHash 'GSW3D_TRIANGLE_FIXTURE_RENDER_SHA256' },
        @{ Name = 'destroy'; Offset = 548; Length = 24; Hash = '9f0719a6477ff604a0c94bb302bf0228a397fa101b0bc97438a3064bad876e91' }
    )
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        foreach ($profile in $profiles) {
            $actual = [BitConverter]::ToString(
                $sha256.ComputeHash($fixture, $profile.Offset, $profile.Length)
            ).Replace('-', '').ToLowerInvariant()
            if ($actual -cne $profile.Hash) {
                throw "GSW3D $($profile.Name) fixture drifted: $actual"
            }
        }
    }
    finally {
        $sha256.Dispose()
    }
}
finally {
    if (Test-Path -LiteralPath $fixtureRoot) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
    }
}
$pe = @(& $objdump -p $exe 2>&1)
if ($LASTEXITCODE -ne 0) { throw 'objdump failed for the GSW3D smoke executable.' }
$joined = $pe -join "`n"
foreach ($required in @(
    'file format pei-i386',
    'MajorOSystemVersion\s+4',
    'MinorOSystemVersion\s+0',
    'MajorSubsystemVersion\s+4',
    'MinorSubsystemVersion\s+0',
    'Subsystem\s+00000003\s+\(Windows CUI\)'
)) {
    if ($joined -notmatch $required) { throw "Missing Win98 PE boundary: $required" }
}
$imports = @(
    $pe | ForEach-Object {
        if ([string]$_ -match '^\s*DLL Name:\s*(\S+)\s*$') { $Matches[1] }
    } | Sort-Object -Unique
)
if (($imports -join ',') -cne 'KERNEL32.dll') {
    throw "Unexpected GSW3D smoke imports: $($imports -join ', ')"
}
$text = @(& $strings -a $exe 2>&1)
if ($LASTEXITCODE -ne 0) { throw 'strings failed for the GSW3D smoke executable.' }
foreach ($marker in @(
    'GSW3D_SMOKE BEGIN',
    'GSW3D_SMOKE UNAVAILABLE capability',
    'GSW3D_SMOKE FAIL present',
    'GSW3D_SMOKE PASS fence='
)) {
    if ($text -cnotcontains $marker) { throw "Missing acceptance marker '$marker'." }
}
$forbidden = $text | Select-String -Pattern '(?i:msvcrt|ucrt|libgcc|libstdc\+\+|opengl|mesa)' |
    Select-Object -First 1
if ($null -ne $forbidden) { throw "Forbidden smoke dependency: $($forbidden.Line)" }

Write-Output 'PASS GSW3D smoke output hash and single-executable boundary.'
Write-Output 'PASS GSW3D smoke command streams match the canonical host fixture hashes.'
Write-Output 'PASS GSW3D smoke PE32, Win98 4.0, and KERNEL32-only import boundary.'
Write-Output 'PASS GSW3D smoke acceptance markers and no Mesa/OpenGL dependency.'
