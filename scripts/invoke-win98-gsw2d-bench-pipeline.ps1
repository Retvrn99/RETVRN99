# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SourceRoot,
    [Parameter(Mandatory = $true)][string]$ToolchainRoot,
    [Parameter(Mandatory = $true)][string]$OutputRoot,
    [string]$BuildPlan,
    [string]$LockFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($BuildPlan)) {
    $BuildPlan = Join-Path $PSScriptRoot '..\drivers\win98\gsw2d-bench-build-plan.json'
}
if ([string]::IsNullOrWhiteSpace($LockFile)) {
    $LockFile = Join-Path $PSScriptRoot '..\drivers\win98\upstream.lock.tsv'
}

& (Join-Path $PSScriptRoot 'build-win98-driver-sources.ps1') `
    -SourceRoot $SourceRoot -ToolchainRoot $ToolchainRoot `
    -OutputRoot $OutputRoot -BuildPlan $BuildPlan -LockFile $LockFile

Write-Output 'Built the separate hash-verified GSW2D Windows 98 benchmark executable.'
