# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Failures = 0

function Assert-True {
    param([Parameter(Mandatory = $true)][bool]$Condition, [string]$Message = 'Expected true.')
    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param([Parameter(Mandatory = $true)][scriptblock]$Body, [string]$Pattern = '')
    try {
        & $Body | Out-Null
    }
    catch {
        if ($Pattern.Length -ne 0 -and $_.Exception.Message -notmatch $Pattern) {
            throw "Exception did not match '$Pattern': $($_.Exception.Message)"
        }
        return
    }
    throw 'Expected an exception.'
}

function Invoke-SelfTest {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )
    try {
        & $Body
        Write-Host "PASS $Name"
    }
    catch {
        $script:Failures++
        [Console]::Error.WriteLine(
            "FAIL $Name`: $($_.Exception.Message)$([Environment]::NewLine)$($_.ScriptStackTrace)"
        )
    }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'retvrn99-win98-pipeline-test-{0}' -f [Guid]::NewGuid().ToString('N')
)
[void](New-Item -ItemType Directory -Path $testRoot)

try {
    $pipeline = Join-Path $PSScriptRoot 'invoke-win98-gsw-vga-pipeline.ps1'
    $sourceRoot = Join-Path $testRoot 'sources'
    $toolchainRoot = Join-Path $testRoot 'toolchains'
    [void](New-Item -ItemType Directory -Path $sourceRoot)
    [void](New-Item -ItemType Directory -Path $toolchainRoot)
    $planPath = Join-Path $testRoot 'build-plan.json'
    $blockedPlan = [ordered]@{
        _spdx = 'GPL-3.0-only'
        schema = 2
        status = 'blocked'
        reason = 'review required'
        toolchains = @()
        steps = @()
    }
    [IO.File]::WriteAllText($planPath, ($blockedPlan | ConvertTo-Json -Depth 4))
    $lockPath = Join-Path $testRoot 'upstream.lock.tsv'
    [IO.File]::WriteAllText(
        $lockPath,
        "# SPDX-License-Identifier: GPL-3.0-only`r`nname`tsource_directory`trepository`tcommit`tupstream_license`tdisposition`tscope`r`n"
    )
    $inventoryPath = Join-Path $testRoot 'inventory.tsv'
    [IO.File]::WriteAllText(
        $inventoryPath,
        "# SPDX-License-Identifier: GPL-3.0-only`r`npackage_id`tdestination_relative_path`tkind`thardware_id`trun_once_order`r`n"
    )
    $manifestPath = Join-Path $testRoot 'manifest.tsv'
    [IO.File]::WriteAllText(
        $manifestPath,
        "# SPDX-License-Identifier: GPL-3.0-only`r`npackage_id`tsource_relative_path`tdestination_relative_path`tkind`tsha256`tbytes`thardware_id`trun_once_order`r`n"
    )

    Invoke-SelfTest 'Build and stage roots must be distinct' {
        $sameRoot = Join-Path $testRoot 'same-output'
        Assert-Throws {
            & $pipeline -SourceRoot $sourceRoot -ToolchainRoot $toolchainRoot `
                -BuildOutputRoot $sameRoot -StageOutputRoot $sameRoot `
                -PayloadManifest $manifestPath -PayloadInventory $inventoryPath `
                -BuildPlan $planPath -LockFile $lockPath
        } 'must be distinct and non-overlapping'
        Assert-True (-not (Test-Path $sameRoot))
    }

    Invoke-SelfTest 'Nested build and stage roots are rejected in both directions' {
        $outer = Join-Path $testRoot 'outer-output'
        $inner = Join-Path $outer 'inner-output'
        Assert-Throws {
            & $pipeline -SourceRoot $sourceRoot -ToolchainRoot $toolchainRoot `
                -BuildOutputRoot $outer -StageOutputRoot $inner `
                -PayloadManifest $manifestPath -PayloadInventory $inventoryPath `
                -BuildPlan $planPath -LockFile $lockPath
        } 'must be distinct and non-overlapping'
        Assert-Throws {
            & $pipeline -SourceRoot $sourceRoot -ToolchainRoot $toolchainRoot `
                -BuildOutputRoot $inner -StageOutputRoot $outer `
                -PayloadManifest $manifestPath -PayloadInventory $inventoryPath `
                -BuildPlan $planPath -LockFile $lockPath
        } 'must be distinct and non-overlapping'
        Assert-True (-not (Test-Path $outer))
    }

    Invoke-SelfTest 'A blocked build cannot reach payload staging' {
        $buildRoot = Join-Path $testRoot 'blocked-build'
        $stageRoot = Join-Path $testRoot 'blocked-stage'
        Assert-Throws {
            & $pipeline -SourceRoot $sourceRoot -ToolchainRoot $toolchainRoot `
                -BuildOutputRoot $buildRoot -StageOutputRoot $stageRoot `
                -PayloadManifest $manifestPath -PayloadInventory $inventoryPath `
                -BuildPlan $planPath -LockFile $lockPath
        } 'driver build is blocked: review required'
        Assert-True (-not (Test-Path $buildRoot))
        Assert-True (-not (Test-Path $stageRoot))
    }
}
finally {
    $verifiedTestRoot = [IO.Path]::GetFullPath($testRoot)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if (-not $verifiedTestRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        -not ([IO.Path]::GetFileName($verifiedTestRoot)).StartsWith('retvrn99-win98-pipeline-test-')) {
        throw "Refusing to remove unverified pipeline test path '$verifiedTestRoot'."
    }
    if (Test-Path -LiteralPath $verifiedTestRoot) {
        Remove-Item -LiteralPath $verifiedTestRoot -Recurse -Force
    }
}

if ($script:Failures -ne 0) {
    throw "$script:Failures GSW VGA pipeline test(s) failed."
}
Write-Host 'All GSW VGA pipeline tests passed.'
