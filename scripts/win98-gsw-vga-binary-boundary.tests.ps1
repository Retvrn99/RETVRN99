# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PayloadRoot,
    [Parameter(Mandatory = $true)][string]$ToolchainRoot,
    [string]$ToolchainLock
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ToolchainLock)) {
    $ToolchainLock = Join-Path $PSScriptRoot '..\drivers\win98\mingw32-toolchain.lock.json'
}

& (Join-Path $PSScriptRoot 'verify-win98-driver-toolchain.ps1') `
    -ToolchainRoot $ToolchainRoot -LockFile $ToolchainLock | Out-Host
$lock = Get-Content -Raw -LiteralPath $ToolchainLock | ConvertFrom-Json
$toolRoot = Join-Path ([IO.Path]::GetFullPath($ToolchainRoot)) $lock.extracted.relative_path
$objdump = Join-Path $toolRoot 'bin\objdump.exe'
$strings = Join-Path $toolRoot 'bin\strings.exe'
$hal = Join-Path ([IO.Path]::GetFullPath($PayloadRoot)) 'vmhal9x-gsw\gswhal9x.dll'
$bridge = Join-Path ([IO.Path]::GetFullPath($PayloadRoot)) 'vmhal9x-gsw\gswdd32.dll'
foreach ($path in @($objdump, $strings, $hal, $bridge)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required file not found: $path" }
}

$allowedImports = @('KERNEL32.dll', 'USER32.dll', 'GDI32.dll', 'ADVAPI32.dll')
$forbidden = '(?i:wined[89]?[.]dll|mesa(?:3d|89|99)?[.]dll|d3d[89][.]dll|Direct3DCreate|opengl32[.]dll|InstallWineHook|UninstallWineHook|CheckWineHook|vmhal_setup)'
foreach ($dll in @($hal, $bridge)) {
    $pe = @(& $objdump -p $dll 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "objdump failed for '$dll'." }
    $imports = @(
        $pe | ForEach-Object {
            if ([string]$_ -match '^\s*DLL Name:\s*(\S+)\s*$') { $Matches[1] }
        } | Sort-Object -Unique
    )
    foreach ($import in $imports) {
        if ($allowedImports -cnotcontains $import) { throw "Unexpected PE import '$import' in '$dll'." }
    }
    $text = @(& $strings -a $dll 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "strings failed for '$dll'." }
    $match = $text | Select-String -Pattern $forbidden | Select-Object -First 1
    if ($null -ne $match) { throw "Forbidden compatibility hook '$($match.Line)' in '$dll'." }
}

$halPe = @(& $objdump -p $hal 2>&1)
$halExports = @(
    $halPe | ForEach-Object {
        if ([string]$_ -match '^\s*\[\s*\d+\]\s+\+base\[.*\]\s+\S+\s+(\S+)\s*$') { $Matches[1] }
    } | Sort-Object -Unique
)
if (($halExports -join ',') -cne 'DriverInit,VidMemInfo') {
    throw "Unexpected HAL export set: $($halExports -join ', ')"
}

Write-Host 'PASS GSW-VGA DLL imports, exports, and DirectDraw-only string boundary.'
