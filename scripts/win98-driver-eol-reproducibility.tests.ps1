# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceRoot,

    [Parameter(Mandatory = $true)]
    [string]$ToolchainRoot,

    [Parameter(Mandatory = $true)]
    [string]$ProofRoot,

    [string]$RepositoryRoot,

    [string]$BuildPlanRelativePath = 'drivers/win98/build-plan.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-FullPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }
    return [IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $output = @(& git -C $WorkingDirectory @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed in '$WorkingDirectory': $($output -join [Environment]::NewLine)"
    }
    return $output
}

function Get-ContainedPath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Base,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or [IO.Path]::IsPathRooted($RelativePath)) {
        throw "Build metadata path must be nonempty and relative: $RelativePath"
    }
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd([char[]]'\/')
    $candidate = [IO.Path]::GetFullPath((Join-Path $Base $RelativePath))
    $prefix = $rootPath + [IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Build metadata path escapes the checkout: $RelativePath"
    }
    return $candidate
}

function Get-InputInventory {
    param(
        [Parameter(Mandatory = $true)][string]$Checkout,
        [Parameter(Mandatory = $true)][string]$BuildPlanRelativePath
    )

    $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $planRelative = $BuildPlanRelativePath.Replace('\', '/')
    if ([IO.Path]::IsPathRooted($planRelative) -or $planRelative.Contains('../')) {
        throw 'BuildPlanRelativePath must be a contained repository-relative path.'
    }
    [void]$paths.Add($planRelative)
    $buildPlanPath = Get-ContainedPath $Checkout $Checkout $planRelative
    $planDirectory = Split-Path -Parent $buildPlanPath
    $buildPlan = Get-Content -Raw -LiteralPath $buildPlanPath | ConvertFrom-Json
    $linkedPaths = @(
        [string]$buildPlan.derived_source_plan.relative_path,
        [string]$buildPlan.upstream_lock.relative_path
    )
    if ($null -ne $buildPlan.PSObject.Properties['toolchain_lock']) {
        $linkedPaths += [string]$buildPlan.toolchain_lock.relative_path
    }
    if ($null -ne $buildPlan.PSObject.Properties['toolchain_locks']) {
        foreach ($lock in @($buildPlan.toolchain_locks)) {
            $linkedPaths += [string]$lock.relative_path
        }
    }
    foreach ($linkedPath in $linkedPaths) {
        $fullPath = Get-ContainedPath $Checkout $planDirectory $linkedPath
        [void]$paths.Add([IO.Path]::GetRelativePath($Checkout, $fullPath).Replace('\', '/'))
    }
    $derivedPlanPath = Get-ContainedPath $Checkout $planDirectory (
        [string]$buildPlan.derived_source_plan.relative_path
    )
    $derivedRoot = Split-Path -Parent $derivedPlanPath
    $derivedPlan = Get-Content -Raw -LiteralPath $derivedPlanPath | ConvertFrom-Json
    foreach ($recipe in @($derivedPlan.recipes)) {
        foreach ($patch in @($recipe.patches)) {
            $fullPath = Get-ContainedPath $Checkout $derivedRoot ([string]$patch.relative_path)
            [void]$paths.Add([IO.Path]::GetRelativePath($Checkout, $fullPath).Replace('\', '/'))
        }
        foreach ($overlay in @($recipe.overlays)) {
            $overlayRoot = Get-ContainedPath $Checkout $derivedRoot ([string]$overlay.relative_path)
            foreach ($item in @(Get-ChildItem -LiteralPath $overlayRoot -Recurse -File)) {
                [void]$paths.Add(
                    [IO.Path]::GetRelativePath($Checkout, $item.FullName).Replace('\', '/')
                )
            }
        }
    }

    return @($paths | Sort-Object -CaseSensitive | ForEach-Object {
        $path = Join-Path $Checkout $_
        $item = Get-Item -LiteralPath $path
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        '{0}|{1}|{2}' -f $_, $item.Length, $hash
    })
}

function Get-DeclaredOutputs {
    param(
        [Parameter(Mandatory = $true)][string]$Checkout,
        [Parameter(Mandatory = $true)][string]$BuildRoot,
        [Parameter(Mandatory = $true)][string]$BuildPlanRelativePath
    )

    $buildPlanPath = Join-Path $Checkout $BuildPlanRelativePath
    $buildPlan = Get-Content -Raw -LiteralPath $buildPlanPath | ConvertFrom-Json
    $planDirectory = Split-Path -Parent $buildPlanPath
    $derivedPlanPath = Join-Path $planDirectory ([string]$buildPlan.derived_source_plan.relative_path)
    $derivedPlan = Get-Content -Raw -LiteralPath $derivedPlanPath | ConvertFrom-Json
    $recipes = @{}
    foreach ($recipe in @($derivedPlan.recipes)) {
        $recipes[$recipe.name] = $recipe.destination_directory
    }

    $records = [Collections.Generic.List[string]]::new()
    foreach ($step in @($buildPlan.steps)) {
        if (-not $recipes.ContainsKey($step.recipe)) {
            throw "Build step '$($step.name)' references missing recipe '$($step.recipe)'."
        }
        foreach ($output in @($step.outputs)) {
            $relative = (Join-Path $recipes[$step.recipe] $output.relative_path).Replace('\', '/')
            $path = Join-Path $BuildRoot $relative
            $item = Get-Item -LiteralPath $path
            $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
            $record = '{0}|{1}|{2}' -f $relative, $item.Length, $hash
            if ($item.Length -ne [int64]$output.bytes -or $hash -cne [string]$output.sha256) {
                throw "Declared output '$relative' does not match its size or SHA-256 lock."
            }
            $records.Add($record)
        }
    }
    return @($records | Sort-Object -CaseSensitive)
}

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Join-Path $PSScriptRoot '..'
}
$repositoryPath = Get-FullPath $RepositoryRoot
$sourcePath = Get-FullPath $SourceRoot
$toolchainPath = Get-FullPath $ToolchainRoot
$proofPath = Get-FullPath $ProofRoot
$buildPlanRelative = $BuildPlanRelativePath.Replace('\', '/')

if (Test-Path -LiteralPath $proofPath) {
    throw "ProofRoot must be previously absent: $proofPath"
}
foreach ($required in @(
    [pscustomobject]@{ Path = $repositoryPath; Name = 'repository' },
    [pscustomobject]@{ Path = $sourcePath; Name = 'source root' },
    [pscustomobject]@{ Path = $toolchainPath; Name = 'toolchain root' }
)) {
    if (-not (Test-Path -LiteralPath $required.Path -PathType Container)) {
        throw "Required $($required.Name) not found: $($required.Path)"
    }
}

[void](Invoke-Git $repositoryPath @('diff', '--quiet', 'HEAD', '--'))
$commit = [string](Invoke-Git $repositoryPath @('rev-parse', 'HEAD') | Select-Object -Last 1)
[void](New-Item -ItemType Directory -Path $proofPath)

$inventories = @{}
$outputs = @{}
foreach ($case in @(
    [pscustomobject]@{ Name = 'autocrlf-true'; Value = 'true' },
    [pscustomobject]@{ Name = 'autocrlf-false'; Value = 'false' }
)) {
    $checkout = Join-Path $proofPath $case.Name
    $buildRoot = Join-Path $proofPath ($case.Name + '-build')
    $cloneOutput = @(& git clone --local --no-hardlinks --no-checkout --quiet `
        $repositoryPath $checkout 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Fresh clone failed for $($case.Name): $($cloneOutput -join [Environment]::NewLine)"
    }
    [void](Invoke-Git $checkout @('config', 'core.autocrlf', $case.Value))
    [void](Invoke-Git $checkout @('checkout', '--detach', '--force', '--quiet', $commit))

    $checkoutBuildPlan = Join-Path $checkout $buildPlanRelative
    $checkoutPlan = Get-Content -Raw -LiteralPath $checkoutBuildPlan | ConvertFrom-Json
    $checkoutPlanDirectory = Split-Path -Parent $checkoutBuildPlan
    $checkoutUpstreamLock = Join-Path $checkoutPlanDirectory (
        [string]$checkoutPlan.upstream_lock.relative_path
    )
    $inventories[$case.Name] = @(Get-InputInventory $checkout $buildPlanRelative)
    & (Join-Path $checkout 'scripts\build-win98-driver-sources.ps1') `
        -SourceRoot $sourcePath -ToolchainRoot $toolchainPath `
        -OutputRoot $buildRoot `
        -BuildPlan $checkoutBuildPlan -LockFile $checkoutUpstreamLock
    $outputs[$case.Name] = @(
        Get-DeclaredOutputs $checkout $buildRoot $buildPlanRelative
    )
}

$trueInputs = $inventories['autocrlf-true'] -join "`n"
$falseInputs = $inventories['autocrlf-false'] -join "`n"
if ($trueInputs -cne $falseInputs) {
    throw 'core.autocrlf=true and false produced different raw Win98 driver input bytes.'
}
$trueOutputs = $outputs['autocrlf-true'] -join "`n"
$falseOutputs = $outputs['autocrlf-false'] -join "`n"
if ($trueOutputs -cne $falseOutputs) {
    throw 'core.autocrlf=true and false produced different declared driver outputs.'
}

Write-Output "Verified fresh-checkout Win98 driver EOL reproducibility at $commit."
Write-Output "Input files: $($inventories['autocrlf-true'].Count); declared outputs: $($outputs['autocrlf-true'].Count)."
Write-Output "Proof root: $proofPath"
