# SPDX-License-Identifier: GPL-3.0-only

param(
    [Parameter(Mandatory)]
    [string]$OutputDirectory,

    [ValidateRange(1, 64)]
    [int]$ThreadCount = [Math]::Min(64, [Environment]::ProcessorCount)
)

$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$output = [IO.Path]::GetFullPath($OutputDirectory)
[void][IO.Directory]::CreateDirectory($output)

Push-Location $repository
try {
    & odin build src\fat32_helper `
        "-out:$output\retvrn99-fat32.exe" `
        -debug `
        "-thread-count:$ThreadCount"
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    & odin build src `
        "-out:$output\retvrn99-control.exe" `
        -debug `
        -define:RETVRN99_TEST_CONTROL=true `
        "-thread-count:$ThreadCount"
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    Copy-Item -LiteralPath (Join-Path $repository 'SDL3.dll') `
        -Destination (Join-Path $output 'SDL3.dll') -Force
} finally {
    Pop-Location
}

Write-Output "Built the RETVRN99 test-control host in $output"
