# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [ValidateRange(1, 64)]
    [int]$ThreadCount = [Math]::Min([Environment]::ProcessorCount, 64)
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$odin = Get-Command odin -ErrorAction Stop

function Invoke-AudioTestPackage {
    param(
        [Parameter(Mandatory)]
        [string]$Package,
        [string[]]$ExtraArguments = @()
    )

    $arguments = @('test', $Package, "-thread-count:$ThreadCount") + $ExtraArguments
    & $odin.Source @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Audio acceptance failed for '$Package' with exit code $LASTEXITCODE."
    }
}

Push-Location $repoRoot
try {
    # This suite is deliberately separate from performance workloads. In
    # particular, it does not alter Quake's established -nosound gate.
    Invoke-AudioTestPackage 'src\audio' @("-define:ODIN_TEST_THREADS=$ThreadCount")
    Invoke-AudioTestPackage 'src\machine' @('-all-packages', "-define:ODIN_TEST_THREADS=$ThreadCount")
    Invoke-AudioTestPackage 'src\acceptance' @("-define:ODIN_TEST_THREADS=$ThreadCount")
    Write-Output 'Audio acceptance passed: synthesis, timing, PCI PCM, mixer, and result telemetry.'
}
finally {
    Pop-Location
}
