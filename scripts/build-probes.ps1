# SPDX-License-Identifier: GPL-3.0-only

param(
    [string]$Nasm = "nasm"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$sourceDir = Join-Path $root "assets\probes"
$probes = @(
    "audio_legacy",
    "hlt_pit_irq",
    "rep_irq_progress",
    "paging_ad",
    "vga_clear_pit",
    "vga_copy_paging",
    "vga_scalar_mmio"
)

foreach ($probe in $probes) {
    $source = Join-Path $sourceDir "$probe.asm"
    $output = Join-Path $sourceDir "$probe.bin"
    $temporary = "$output.new"
    & $Nasm -f bin -I "$sourceDir\" -o $temporary $source
    if ($LASTEXITCODE -ne 0) {
        throw "NASM failed for $source"
    }
    if ((Get-Item -LiteralPath $temporary).Length -eq 0) {
        throw "NASM produced an empty binary for $source"
    }
    Move-Item -LiteralPath $temporary -Destination $output -Force
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $output).Hash.ToLowerInvariant()
    Write-Host "$probe.bin $hash"
}
