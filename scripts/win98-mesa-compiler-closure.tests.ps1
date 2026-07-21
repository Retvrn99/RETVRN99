# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'verify-win98-mesa-compiler-closure.ps1')

$script:Tests = 0
$script:Failures = 0
$script:DriversRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\drivers\win98'))
$script:ClosurePath = Join-Path $script:DriversRoot 'mesa-compiler-closure.json'
$script:Fixtures = [Collections.Generic.List[string]]::new()

function Invoke-ClosureTest {
    param([string]$Name, [scriptblock]$Body)
    $script:Tests++
    try { & $Body; Write-Output "PASS: $Name" }
    catch {
        $script:Failures++
        Write-Output "FAIL: $Name"
        Write-Output "  $($_.Exception.Message)"
    }
}

function Assert-ClosureThrows {
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

function Read-ClosureClone {
    return Get-Content $script:ClosurePath -Raw | ConvertFrom-Json
}

function Write-ClosureFixture {
    param([object]$Value)
    $path = Join-Path $script:DriversRoot (
        '.mesa-compiler-closure-test-' + [Guid]::NewGuid().ToString('N') + '.json'
    )
    $json = ($Value | ConvertTo-Json -Depth 20) -replace "`r`n", "`n"
    [IO.File]::WriteAllText($path, $json + "`n", [Text.UTF8Encoding]::new($false))
    $script:Fixtures.Add($path)
    return $path
}

try {
    Invoke-ClosureTest 'Production compiler closure validates' {
        & (Join-Path $PSScriptRoot 'verify-win98-mesa-compiler-closure.ps1') |
            Out-Null
    }
    Invoke-ClosureTest 'Command source identity is exact' {
        $value = Read-ClosureClone
        $value.evidence.commands[0].source = '{source}/forbidden.c'
        $path = Write-ClosureFixture $value
        Assert-ClosureThrows {
            & (Join-Path $PSScriptRoot 'verify-win98-mesa-compiler-closure.ps1') `
                -ClosureFile $path
        } 'not exact'
    }
    Invoke-ClosureTest 'Twin depfile hashes are required' {
        $value = Read-ClosureClone
        $value.evidence.commands[0].twin_sha256 = 'broken'
        $path = Write-ClosureFixture $value
        Assert-ClosureThrows {
            & (Join-Path $PSScriptRoot 'verify-win98-mesa-compiler-closure.ps1') `
                -ClosureFile $path
        } 'not exact'
    }
    Invoke-ClosureTest 'Header identities remain unique' {
        $value = Read-ClosureClone
        $value.evidence.headers[1] = $value.evidence.headers[0]
        $path = Write-ClosureFixture $value
        Assert-ClosureThrows {
            & (Join-Path $PSScriptRoot 'verify-win98-mesa-compiler-closure.ps1') `
                -ClosureFile $path
        } 'ordinal order'
    }
    Invoke-ClosureTest 'Forbidden include paths remain absent' {
        $value = Read-ClosureClone
        $value.evidence.profile.common_arguments += `
            '-I{source}/mesa-23.1.x/src/gallium/winsys/sw'
        $path = Write-ClosureFixture $value
        Assert-ClosureThrows {
            & (Join-Path $PSScriptRoot 'verify-win98-mesa-compiler-closure.ps1') `
                -ClosureFile $path
        } 'forbidden include fragment'
    }
    Invoke-ClosureTest 'Production build authorization remains false' {
        $value = Read-ClosureClone
        $value.scope.authorizations.production_build = $true
        $path = Write-ClosureFixture $value
        Assert-ClosureThrows {
            & (Join-Path $PSScriptRoot 'verify-win98-mesa-compiler-closure.ps1') `
                -ClosureFile $path
        } 'must remain false'
    }
}
finally {
    foreach ($path in $script:Fixtures) {
        if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
    }
}
if ($script:Failures -ne 0) {
    throw "$($script:Failures) of $($script:Tests) compiler-closure tests failed."
}
Write-Output "All $($script:Tests) compiler-closure tests passed."
