# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [string]$SourceRoot,
    [string]$ToolchainRoot,
    [string]$BuildPlan,
    [string]$LockFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($BuildPlan)) {
    $BuildPlan = Join-Path $PSScriptRoot '..\drivers\win98\build-plan.json'
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

function Get-ContainedPath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if ([IO.Path]::IsPathRooted($RelativePath) -or $RelativePath -match '(^|[\/])\.\.([\/]|$)') {
        throw "$Label uses an unsafe relative path '$RelativePath'."
    }
    $rootPath = Get-FullPath $Root
    $rootPrefix = $rootPath.TrimEnd([char[]]'\/') + [IO.Path]::DirectorySeparatorChar
    $candidate = [IO.Path]::GetFullPath((Join-Path $rootPath $RelativePath))
    if (-not $candidate.Equals($rootPath, [StringComparison]::OrdinalIgnoreCase) -and
        -not $candidate.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label escapes its declared root."
    }
    return $candidate
}

$planPath = Get-FullPath $BuildPlan
if (-not (Test-Path -LiteralPath $planPath -PathType Leaf)) {
    throw "Windows 98 build plan not found: $planPath"
}
$plan = Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json
if ($plan._spdx -cne 'GPL-3.0-only' -or $plan.schema -ne 1) {
    throw 'Unsupported or unlicensed Windows 98 build plan.'
}
if ($plan.status -cne 'ready') {
    throw "Windows 98 driver build is blocked: $($plan.reason)"
}
if ([string]::IsNullOrWhiteSpace($SourceRoot) -or
    [string]::IsNullOrWhiteSpace($ToolchainRoot)) {
    throw 'SourceRoot and ToolchainRoot are required for a ready build plan.'
}
$toolchains = @($plan.toolchains)
$steps = @($plan.steps)
if ($toolchains.Count -eq 0 -or $steps.Count -eq 0) {
    throw 'A ready build plan must declare exact toolchains and build steps.'
}

$sourceRootPath = Get-FullPath $SourceRoot
$toolchainRootPath = Get-FullPath $ToolchainRoot
$lockPath = Get-FullPath $LockFile
if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
    throw "Upstream lock not found: $lockPath"
}
$lockLines = @(
    Get-Content -LiteralPath $lockPath |
        Where-Object { $_.Trim().Length -gt 0 -and -not $_.TrimStart().StartsWith('#') }
)
if ($lockLines.Count -lt 2) {
    throw 'The upstream lock must contain a header and at least one source row.'
}
$lockEntries = @($lockLines | ConvertFrom-Csv -Delimiter "`t")
$lockColumns = @($lockEntries[0].PSObject.Properties.Name)
foreach ($column in @('name', 'source_directory', 'disposition')) {
    if ($lockColumns -notcontains $column) {
        throw "The upstream lock is missing '$column'."
    }
}
$lockedSources = @{}
foreach ($source in $lockEntries) {
    $sourceDirectory = [string]$source.source_directory
    if ([string]::IsNullOrWhiteSpace($sourceDirectory)) {
        throw "Upstream '$($source.name)' has no source directory."
    }
    $directoryKey = $sourceDirectory.ToLowerInvariant()
    if ($lockedSources.ContainsKey($directoryKey)) {
        throw "Duplicate source directory '$sourceDirectory'."
    }
    $lockedSources[$directoryKey] = [PSCustomObject]@{
        Name = [string]$source.name
        SourceDirectory = $sourceDirectory
        Disposition = [string]$source.disposition
    }
}

$requiredSourceNames = @{}
foreach ($step in $steps) {
    $stepSourceDirectory = [string]$step.source_directory
    if ($stepSourceDirectory -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw "Build step '$($step.name)' has an invalid source directory."
    }
    $directoryKey = $stepSourceDirectory.ToLowerInvariant()
    if (-not $lockedSources.ContainsKey($directoryKey)) {
        throw "Build step '$($step.name)' does not reference a locked source."
    }
    $lockedSource = $lockedSources[$directoryKey]
    if ($stepSourceDirectory -cne $lockedSource.SourceDirectory) {
        throw "Build step '$($step.name)' must use canonical source directory '$($lockedSource.SourceDirectory)'."
    }
    if ([string]::IsNullOrWhiteSpace($lockedSource.Name) -or
        $lockedSource.Disposition -cne 'planned') {
        throw "Build step '$($step.name)' must reference exactly one named planned source."
    }
    $requiredSourceNames[$lockedSource.Name] = $true
}
$sourceAllowlist = @($requiredSourceNames.Keys | Sort-Object)
& (Join-Path $PSScriptRoot 'verify-win98-driver-sources.ps1') `
    -SourceRoot $sourceRootPath -LockFile $lockPath -SourceName $sourceAllowlist
if ($LASTEXITCODE -ne 0) {
    throw 'Pinned Windows 98 source verification failed.'
}

$verifiedToolchains = @{}
foreach ($toolchain in $toolchains) {
    if ($toolchain.name -notmatch '^[a-z0-9][a-z0-9-]*$' -or
        $toolchain.sha256 -notmatch '^[0-9a-f]{64}$') {
        throw 'A toolchain entry has an invalid name or SHA-256.'
    }
    if ($verifiedToolchains.ContainsKey($toolchain.name)) {
        throw "Duplicate toolchain '$($toolchain.name)'."
    }
    $executable = Get-ContainedPath $toolchainRootPath $toolchain.relative_path "Toolchain '$($toolchain.name)'"
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        throw "Toolchain executable not found: $executable"
    }
    $actualHash = (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -cne $toolchain.sha256) {
        throw "Toolchain '$($toolchain.name)' failed SHA-256 verification."
    }
    $verifiedToolchains[$toolchain.name] = $executable
}

$validatedSteps = @()
$seenSteps = @{}
foreach ($step in $steps) {
    if ($step.name -notmatch '^[a-z0-9][a-z0-9-]*$' -or
        -not $verifiedToolchains.ContainsKey([string]$step.toolchain)) {
        throw 'A build step has an invalid name or toolchain reference.'
    }
    if ($seenSteps.ContainsKey([string]$step.name)) {
        throw "Duplicate build step '$($step.name)'."
    }
    if ($step.source_directory -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw "Build step '$($step.name)' has an invalid source directory."
    }
    $directoryKey = ([string]$step.source_directory).ToLowerInvariant()
    if (-not $lockedSources.ContainsKey($directoryKey)) {
        throw "Build step '$($step.name)' does not reference a locked source."
    }
    $lockedSource = $lockedSources[$directoryKey]
    if ([string]$step.source_directory -cne $lockedSource.SourceDirectory -or
        $lockedSource.Disposition -cne 'planned') {
        throw "Build step '$($step.name)' does not reference its canonical planned source."
    }
    $checkout = Get-ContainedPath $sourceRootPath $lockedSource.SourceDirectory "Build step '$($step.name)'"
    $workingDirectory = Get-ContainedPath $checkout $step.working_directory "Build step '$($step.name)' working directory"
    if (-not (Test-Path -LiteralPath $workingDirectory -PathType Container)) {
        throw "Build working directory not found: $workingDirectory"
    }
    $arguments = @($step.arguments | ForEach-Object { [string]$_ })
    $outputs = @($step.outputs)
    if ($outputs.Count -eq 0) {
        throw "Build step '$($step.name)' declares no deterministic outputs."
    }
    $validatedOutputs = @()
    foreach ($output in $outputs) {
        if ([string]::IsNullOrWhiteSpace([string]$output.relative_path) -or
            $output.sha256 -notmatch '^[0-9a-f]{64}$' -or
            [int64]$output.bytes -lt 1) {
            throw "Build step '$($step.name)' has invalid output metadata."
        }
        $validatedOutputs += [PSCustomObject]@{
            Path = Get-ContainedPath $checkout $output.relative_path "Build step '$($step.name)' output"
            Sha256 = [string]$output.sha256
            Bytes = [int64]$output.bytes
        }
    }
    $seenSteps[[string]$step.name] = $true
    $validatedSteps += [PSCustomObject]@{
        Name = [string]$step.name
        Toolchain = $verifiedToolchains[[string]$step.toolchain]
        WorkingDirectory = $workingDirectory
        Arguments = $arguments
        Outputs = $validatedOutputs
    }
}

foreach ($step in $validatedSteps) {
    Push-Location $step.WorkingDirectory
    try {
        $toolchainExecutable = [string]$step.Toolchain
        [string[]]$stepArguments = @($step.Arguments)
        & $toolchainExecutable @stepArguments
        if ($LASTEXITCODE -ne 0) {
            throw "Build step '$($step.Name)' failed with exit code $LASTEXITCODE."
        }
    }
    finally {
        Pop-Location
    }
    foreach ($output in $step.Outputs) {
        if (-not (Test-Path -LiteralPath $output.Path -PathType Leaf)) {
            throw "Expected build output not found: $($output.Path)"
        }
        $outputFile = Get-Item -LiteralPath $output.Path
        $outputHash = (Get-FileHash -LiteralPath $output.Path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($outputFile.Length -ne $output.Bytes -or $outputHash -cne $output.Sha256) {
            throw "Build output '$($output.Path)' is not reproducible from the reviewed plan."
        }
    }
}

Write-Output "Completed and verified $($steps.Count) Windows 98 driver build steps."
