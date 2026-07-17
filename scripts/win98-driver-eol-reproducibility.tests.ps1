# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceRoot,

    [Parameter(Mandatory = $true)]
    [string]$ToolchainRoot,

    [Parameter(Mandatory = $true)]
    [string]$ProofRoot,

    [string]$RepositoryRoot
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

function Get-InputInventory {
    param([Parameter(Mandatory = $true)][string]$Checkout)

    $driverRoot = Join-Path $Checkout 'drivers\win98'
    $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($item in @(Get-ChildItem -LiteralPath $driverRoot -File)) {
        if ($item.Extension -cin @('.json', '.tsv')) {
            [void]$paths.Add([IO.Path]::GetRelativePath($Checkout, $item.FullName).Replace('\', '/'))
        }
    }
    $derivedPlan = Get-Content -Raw -LiteralPath (Join-Path $driverRoot 'derived-source-plan.json') |
        ConvertFrom-Json
    foreach ($recipe in @($derivedPlan.recipes)) {
        foreach ($patch in @($recipe.patches)) {
            [void]$paths.Add(('drivers/win98/' + [string]$patch.relative_path).Replace('\', '/'))
        }
        foreach ($overlay in @($recipe.overlays)) {
            $overlayRoot = Join-Path $driverRoot ([string]$overlay.relative_path)
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
        [Parameter(Mandatory = $true)][string]$BuildRoot
    )

    $driverRoot = Join-Path $Checkout 'drivers\win98'
    $buildPlan = Get-Content -Raw -LiteralPath (Join-Path $driverRoot 'build-plan.json') |
        ConvertFrom-Json
    $derivedPlan = Get-Content -Raw -LiteralPath (Join-Path $driverRoot 'derived-source-plan.json') |
        ConvertFrom-Json
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

    $inventories[$case.Name] = @(Get-InputInventory $checkout)
    & (Join-Path $checkout 'scripts\build-win98-driver-sources.ps1') `
        -SourceRoot $sourcePath -ToolchainRoot $toolchainPath `
        -OutputRoot $buildRoot `
        -BuildPlan (Join-Path $checkout 'drivers\win98\build-plan.json') `
        -LockFile (Join-Path $checkout 'drivers\win98\upstream.lock.tsv')
    $outputs[$case.Name] = @(Get-DeclaredOutputs $checkout $buildRoot)
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
