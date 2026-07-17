# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceRoot,

    [Parameter(Mandatory = $true)]
    [string]$ToolchainRoot,

    [Parameter(Mandatory = $true)]
    [string]$BuildOutputRoot,

    [Parameter(Mandatory = $true)]
    [string]$StageOutputRoot,

    [Parameter(Mandatory = $true)]
    [string]$PayloadManifest,

    [string]$BuildPlan,

    [string]$PayloadInventory,

    [string]$LockFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($BuildPlan)) {
    $BuildPlan = Join-Path $PSScriptRoot '..\drivers\win98\build-plan.json'
}
if ([string]::IsNullOrWhiteSpace($PayloadInventory)) {
    $PayloadInventory = Join-Path $PSScriptRoot '..\drivers\win98\payload-inventory.schema.tsv'
}
if ([string]::IsNullOrWhiteSpace($LockFile)) {
    $LockFile = Join-Path $PSScriptRoot '..\drivers\win98\upstream.lock.tsv'
}

function Get-FullPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }
    return [IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

function Test-PathIsSameOrContained {
    param(
        [Parameter(Mandatory = $true)][string]$Candidate,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $rootPrefix = $Root.TrimEnd([char[]]'\/') + [IO.Path]::DirectorySeparatorChar
    return $Candidate.Equals($Root, [StringComparison]::OrdinalIgnoreCase) -or
        $Candidate.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)
}

$buildOutputPath = Get-FullPath $BuildOutputRoot
$stageOutputPath = Get-FullPath $StageOutputRoot
if ((Test-PathIsSameOrContained $buildOutputPath $stageOutputPath) -or
    (Test-PathIsSameOrContained $stageOutputPath $buildOutputPath)) {
    throw 'BuildOutputRoot and StageOutputRoot must be distinct and non-overlapping.'
}
foreach ($pair in @(
    [pscustomobject]@{ Path = $BuildPlan; Name = 'Build plan' },
    [pscustomobject]@{ Path = $PayloadInventory; Name = 'Payload inventory' },
    [pscustomobject]@{ Path = $PayloadManifest; Name = 'Payload manifest' },
    [pscustomobject]@{ Path = $LockFile; Name = 'Upstream lock' }
)) {
    $path = Get-FullPath $pair.Path
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "$($pair.Name) not found: $path"
    }
}

& (Join-Path $PSScriptRoot 'build-win98-driver-sources.ps1') `
    -SourceRoot $SourceRoot -ToolchainRoot $ToolchainRoot `
    -OutputRoot $buildOutputPath -BuildPlan $BuildPlan -LockFile $LockFile

& (Join-Path $PSScriptRoot 'stage-win98-driver-payloads.ps1') `
    -SourceRoot $SourceRoot -PayloadRoot $buildOutputPath `
    -PayloadManifest $PayloadManifest -PayloadInventory $PayloadInventory `
    -OutputDirectory $stageOutputPath -LockFile $LockFile -PackageId 'gsw-vga'

Write-Output 'Built and staged the complete hash-verified GSW VGA package.'
