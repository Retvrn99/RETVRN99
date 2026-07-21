# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param([string]$SourceRoot = 'D:\src\retvrn99-win98')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Failures = 0
$script:Tests = 0
$script:DriversRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\drivers\win98'))
$script:PlanPath = Join-Path $script:DriversRoot 'mesa-gsw-direct-build-plan.json'
. (Join-Path $PSScriptRoot 'verify-win98-mesa-gsw-direct-build-plan.ps1') `
    -SourceRoot $SourceRoot

function Invoke-SelfTest {
    param([string]$Name, [scriptblock]$Body)
    $script:Tests++
    try {
        & $Body
        Write-Output "PASS: $Name"
    }
    catch {
        $script:Failures++
        Write-Output "FAIL: $Name"
        Write-Output "  $($_.Exception.Message)"
    }
}

function Assert-Throws {
    param([scriptblock]$Body, [string]$Expected)
    try { & $Body }
    catch {
        if ($_.Exception.Message.IndexOf(
                $Expected, [StringComparison]::OrdinalIgnoreCase
            ) -lt 0) {
            throw "Expected '$Expected', observed '$($_.Exception.Message)'."
        }
        return
    }
    throw "Expected failure containing '$Expected'."
}

function Read-PlanClone {
    $text = [IO.File]::ReadAllText(
        $script:PlanPath,
        [Text.UTF8Encoding]::new($false, $true)
    )
    return ConvertFrom-GswStrictJson -Json $text -Source $script:PlanPath
}

function Write-TestPlan {
    param([object]$Plan)
    $path = Join-Path $script:DriversRoot (
        '.mesa-direct-plan-test-' + [Guid]::NewGuid().ToString('N') + '.json'
    )
    $json = ($Plan | ConvertTo-Json -Depth 16) -replace "`r`n", "`n"
    [IO.File]::WriteAllText($path, $json + "`n", [Text.UTF8Encoding]::new($false))
    $script:TestFiles.Add($path)
    return $path
}

$script:TestFiles = [Collections.Generic.List[string]]::new()
try {
    Invoke-SelfTest 'Production direct-build plan validates' {
        Assert-GswDirectBuildPlan $SourceRoot $script:PlanPath $false
    }

    Invoke-SelfTest 'Every source assignment remains unique and ordered' {
        $plan = Read-PlanClone
        $plan.units[1].relative_path = $plan.units[0].relative_path
        $path = Write-TestPlan $plan
        Assert-Throws { Assert-GswDirectBuildPlan $SourceRoot $path $false } `
            'not in exact ordinal source-kind order'
    }

    Invoke-SelfTest 'Language classification is extension-derived' {
        $plan = Read-PlanClone
        $plan.units[0].language = 'cxx-gnu++14'
        $path = Write-TestPlan $plan
        Assert-Throws { Assert-GswDirectBuildPlan $SourceRoot $path $false } `
            'Language assignment mismatch'
    }

    Invoke-SelfTest 'Path-derived object identities cannot collide' {
        $plan = Read-PlanClone
        $plan.units[1].object_identity = $plan.units[0].object_identity
        $path = Write-TestPlan $plan
        Assert-Throws { Assert-GswDirectBuildPlan $SourceRoot $path $false } `
            'Object identity is invalid or colliding'
    }

    Invoke-SelfTest 'Compiler evidence remains empty in the metadata plan' {
        $plan = Read-PlanClone
        $plan.empty_evidence.compiler_commands = @('not-authorized')
        $path = Write-TestPlan $plan
        Assert-Throws { Assert-GswDirectBuildPlan $SourceRoot $path $false } `
            'evidence is not empty'
    }

    Invoke-SelfTest 'Production build authorization remains false' {
        $plan = Read-PlanClone
        $plan.scope.authorizations.production_build = $true
        $path = Write-TestPlan $plan
        Assert-Throws { Assert-GswDirectBuildPlan $SourceRoot $path $false } `
            'is not false'
    }
}
finally {
    foreach ($path in $script:TestFiles) {
        $full = [IO.Path]::GetFullPath($path)
        $prefix = $script:DriversRoot.TrimEnd([char[]]'\/') + `
            [IO.Path]::DirectorySeparatorChar
        if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
            (Split-Path -Leaf $full) -notlike '.mesa-direct-plan-test-*.json') {
            throw "Refusing to remove unsafe direct-plan fixture '$full'."
        }
        if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Force }
    }
}

if ($script:Failures -ne 0) {
    throw "$($script:Failures) of $($script:Tests) direct-build plan tests failed."
}
Write-Output "All $($script:Tests) direct-build plan tests passed."
