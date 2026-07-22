# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [string]$PlanFile,
    [string]$MediaLock,
    [string]$MediaRoot,
    [string]$OutputFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'strict-json.ps1')

function Assert-PathWithinRoot {
    param(
        [string]$Path,
        [string]$Root,
        [string]$Label
    )

    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd(
        [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    )
    $candidate = [IO.Path]::GetFullPath($Path)
    $prefix = $rootPath + [IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label must remain inside $rootPath."
    }
    return $candidate
}

function Assert-NoExistingReparsePoint {
    param(
        [string]$Root,
        [string]$Candidate
    )

    $rootPath = [IO.Path]::GetFullPath($Root)
    $candidatePath = Assert-PathWithinRoot $Candidate $rootPath 'Graphics baseline output'
    $relative = $candidatePath.Substring($rootPath.TrimEnd('\', '/').Length)
    $relative = $relative.TrimStart([char[]]@('\', '/'))
    $current = $rootPath
    foreach ($component in @($relative -split '[\\/]')) {
        if ([string]::IsNullOrWhiteSpace($component)) { continue }
        $current = Join-Path $current $component
        if (-not (Test-Path -LiteralPath $current)) { break }
        $item = Get-Item -LiteralPath $current -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Graphics baseline output path contains a reparse point: $current"
        }
    }
}

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($PlanFile)) {
    $PlanFile = Join-Path $repositoryRoot 'qualification\graphics\baseline-plan.json'
}
if ([string]::IsNullOrWhiteSpace($MediaLock)) {
    $MediaLock = Join-Path $repositoryRoot 'qualification\graphics\media.lock.json'
}
if ([string]::IsNullOrWhiteSpace($MediaRoot)) {
    $MediaRoot = Join-Path $repositoryRoot '.scratch\graphics-qualification\media'
}

$planPath = [IO.Path]::GetFullPath($PlanFile)
$lockPath = [IO.Path]::GetFullPath($MediaLock)
$mediaRootPath = [IO.Path]::GetFullPath($MediaRoot)
$planVerifier = Join-Path $PSScriptRoot 'verify-graphics-baseline-plan.ps1'
$mediaVerifier = Join-Path $PSScriptRoot 'verify-graphics-qualification-media.ps1'
$planSnapshot = Read-GswStrictJsonFileSnapshot -Path $planPath `
    -Name 'Graphics baseline plan' -MaximumBytes 1048576
$mediaLockSnapshot = Read-GswStrictJsonFileSnapshot -Path $lockPath `
    -Name 'Graphics qualification media lock' -MaximumBytes 1048576
$null = . $planVerifier -DefineValidatorOnly
$null = . $mediaVerifier -DefineValidatorOnly
$null = Invoke-GswGraphicsBaselinePlanValidation -Plan $planSnapshot.Value `
    -MediaLockValue $mediaLockSnapshot.Value
$null = Invoke-GswGraphicsQualificationMediaValidation -Root $mediaRootPath `
    -Lock $mediaLockSnapshot.Value -ManifestOnly

$plan = $planSnapshot.Value
$mediaLockValue = $mediaLockSnapshot.Value

$evidenceRoot = [IO.Path]::GetFullPath((Join-Path $repositoryRoot ([string]$plan.evidence.root)))
if ([string]::IsNullOrWhiteSpace($OutputFile)) {
    $OutputFile = Join-Path $evidenceRoot 'prepared-run-v1.json'
}
$outputPath = Assert-PathWithinRoot $OutputFile $evidenceRoot 'Graphics baseline output'
if ([IO.Path]::GetExtension($outputPath) -cne '.json') {
    throw 'Graphics baseline output must be a JSON file.'
}
Assert-NoExistingReparsePoint $repositoryRoot $outputPath

$relativeOutput = $outputPath.Substring($repositoryRoot.TrimEnd('\', '/').Length)
$relativeOutput = $relativeOutput.TrimStart([char[]]@('\', '/')).Replace('\', '/')
& git -C $repositoryRoot check-ignore --quiet -- $relativeOutput
if ($LASTEXITCODE -ne 0) {
    throw 'Graphics baseline output must be ignored by Git.'
}

$selectedMedia = @()
foreach ($mediaId in @($plan.workload.media_ids)) {
    $entries = @($mediaLockValue.media | Where-Object { [string]$_.id -ceq [string]$mediaId })
    if ($entries.Count -ne 1) {
        throw "Graphics baseline media id '$mediaId' must resolve exactly once."
    }
    $entry = $entries[0]
    $payloadPath = Join-Path $mediaRootPath ([string]$entry.relative_path)
    if (-not (Test-Path -LiteralPath $payloadPath -PathType Leaf)) {
        throw "Graphics baseline media '$mediaId' is missing."
    }
    $payloadSnapshot = Read-GswBoundedFileSnapshot -Path $payloadPath `
        -Name "Graphics baseline media '$mediaId'" `
        -MaximumBytes ([UInt64]$entry.bytes)
    if ([UInt64]$payloadSnapshot.Length -ne [UInt64]$entry.bytes) {
        throw "Graphics baseline media '$mediaId' byte count does not match its lock."
    }
    if ($payloadSnapshot.Sha256 -cne [string]$entry.sha256) {
        throw "Graphics baseline media '$mediaId' SHA-256 does not match its lock."
    }
    $selectedMedia += [ordered]@{
        id = [string]$entry.id
        title = [string]$entry.title
        relative_path = [string]$entry.relative_path
        bytes = [long]$entry.bytes
        sha256 = [string]$entry.sha256
    }
}

$cells = @()
$sequence = 0
foreach ($mode in @($plan.workload.modes)) {
    foreach ($presentationMode in @($plan.workload.presentation_modes)) {
        for ($repetition = 1; $repetition -le [int]$plan.workload.repetitions; $repetition += 1) {
            $sequence += 1
            $cellId = '{0:d3}-{1}x{2}-{3}-r{4}' -f `
                $sequence, [int]$mode.width, [int]$mode.height, `
                [string]$presentationMode, $repetition
            $cellRoot = "cells/$cellId"
            $cells += [ordered]@{
                sequence = $sequence
                id = $cellId
                width = [int]$mode.width
                height = [int]$mode.height
                presentation_mode = [string]$presentationMode
                repetition = $repetition
                evidence_directory = $cellRoot
                profile_root = "$cellRoot/profile"
                console_log = "$cellRoot/console.log"
                graphics_postmortem = "$cellRoot/profile/graphics-postmortem.json"
                result = "$cellRoot/result.json"
            }
        }
    }
}
if ($sequence -ne 24) {
    throw "Graphics baseline preparation expected 24 execution cells, observed $sequence."
}

$runPlan = [ordered]@{
    _spdx = 'GPL-3.0-only'
    schema = 1
    id = 'retvrn99-graphics-phase0-winquake-prepared-run-v1'
    source = [ordered]@{
        plan_id = [string]$plan.id
        plan_sha256 = $planSnapshot.Sha256
        media_lock_sha256 = $mediaLockSnapshot.Sha256
    }
    policy = [ordered]@{
        prepared_only = $true
        execution_authorized = $false
        guest_launch_allowed = $false
        guest_install_allowed = $false
        host_mutation_allowed = $false
    }
    machine = [ordered]@{
        guest_ram_mib = [int]$plan.machine.guest_ram_mib
        framebuffer_mib = [int]$plan.machine.framebuffer_mib
    }
    media = $selectedMedia
    execution = [ordered]@{
        executable_media_id = [string]$plan.workload.executable_media_id
        presentation_scope = [string]$plan.workload.presentation_scope
        cell_count = $sequence
        trace_requested = $true
        required_arguments = @('--graphics-trace')
        lifecycle_actions = @($plan.workload.lifecycle_actions)
    }
    cells = $cells
}

$json = ($runPlan | ConvertTo-Json -Depth 16 -Compress) + "`n"
[byte[]]$jsonBytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
$outputHash = Get-GswSha256Hex $jsonBytes
$parent = Split-Path -Parent $outputPath
if (-not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
}
Assert-NoExistingReparsePoint $repositoryRoot $outputPath
if (Test-Path -LiteralPath $outputPath) {
    $existing = Read-GswBoundedFileSnapshot -Path $outputPath `
        -Name 'Existing graphics baseline output' `
        -MaximumBytes ([UInt64]$jsonBytes.Length)
    $matches = $existing.Bytes.Length -eq $jsonBytes.Length
    for ($i = 0; $matches -and $i -lt $jsonBytes.Length; $i += 1) {
        $matches = $existing.Bytes[$i] -eq $jsonBytes[$i]
    }
    if (-not $matches) {
        throw 'Graphics baseline output already exists with different content.'
    }
} else {
    Assert-NoExistingReparsePoint $repositoryRoot $outputPath
    try {
        $stream = [IO.File]::Open(
            $outputPath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None
        )
    } catch [IO.IOException] {
        throw 'Graphics baseline output appeared during atomic creation.'
    }
    try {
        Assert-NoExistingReparsePoint $repositoryRoot $outputPath
        $stream.Write($jsonBytes, 0, $jsonBytes.Length)
        $stream.Flush($true)
        if ($stream.Length -ne $jsonBytes.Length) {
            throw 'Graphics baseline output write was incomplete.'
        }
    } finally {
        $stream.Dispose()
    }
}

Write-Output (
    "PASS prepared graphics baseline cells=24 authorized=false " +
    "output=$relativeOutput sha256=$outputHash"
)
