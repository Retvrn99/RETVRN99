# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param([string]$ClosureFile)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Tests = 0
$script:Failures = 0
if ([string]::IsNullOrWhiteSpace($ClosureFile)) {
    $script:DriversRoot = [IO.Path]::GetFullPath(
        (Join-Path $PSScriptRoot '..\drivers\win98')
    )
    $script:ClosurePath = Join-Path $script:DriversRoot `
        'mesa-compiler-closure.json'
}
else {
    $script:ClosurePath = [IO.Path]::GetFullPath($ClosureFile)
    $script:DriversRoot = Split-Path -Parent $script:ClosurePath
}
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
        & (Join-Path $PSScriptRoot 'verify-win98-mesa-compiler-closure.ps1') `
            -ClosureFile $script:ClosurePath | Out-Null
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
    Invoke-ClosureTest 'Ready component dependency hashes remain bound' {
        $value = Read-ClosureClone
        $sourceHeader = @($value.evidence.headers | Where-Object {
            $_.root -ceq 'source'
        })[0]
        $sourceHeader.sha256 = '0' * 64
        $path = Write-ClosureFixture $value
        Assert-ClosureThrows {
            & (Join-Path $PSScriptRoot 'verify-win98-mesa-compiler-closure.ps1') `
                -ClosureFile $path
        } 'changed from canonical closure'
    }
    Invoke-ClosureTest 'Canonical CRLF dependency hashes remain bound' {
        $value = Read-ClosureClone
        $header = @($value.evidence.headers | Where-Object {
            $_.root -ceq 'source' -and $_.relative_path -ceq 'mesa9x.h'
        })[0]
        $header.sha256 = '0' * 64
        $path = Write-ClosureFixture $value
        Assert-ClosureThrows {
            & (Join-Path $PSScriptRoot 'verify-win98-mesa-compiler-closure.ps1') `
                -ClosureFile $path
        } 'changed from canonical closure'
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
    Invoke-ClosureTest 'First compile-context exception remains bound to cmd-0002' {
        $value = Read-ClosureClone
        $value.evidence.unit_argument_overrides[0].command_id = 'cmd-0003'
        $path = Write-ClosureFixture $value
        Assert-ClosureThrows {
            & (Join-Path $PSScriptRoot 'verify-win98-mesa-compiler-closure.ps1') `
                -ClosureFile $path
        } 'unit override 0 changed'
    }
    Invoke-ClosureTest 'Second compile-context exception remains bound to cmd-0792' {
        $value = Read-ClosureClone
        $value.evidence.unit_argument_overrides[1].source = `
            '{source}/mesa-23.1.x/src/util/rand_xor.c'
        $path = Write-ClosureFixture $value
        Assert-ClosureThrows {
            & (Join-Path $PSScriptRoot 'verify-win98-mesa-compiler-closure.ps1') `
                -ClosureFile $path
        } 'unit override 1 changed'
    }
    Invoke-ClosureTest 'Third compile-context exception keeps exact assembler arguments' {
        $value = Read-ClosureClone
        $value.evidence.unit_argument_overrides[2].arguments = @(
            '-DGLX_X86_READONLY_TEXT', '-DUSE_X86_ASM'
        )
        $path = Write-ClosureFixture $value
        Assert-ClosureThrows {
            & (Join-Path $PSScriptRoot 'verify-win98-mesa-compiler-closure.ps1') `
                -ClosureFile $path
        } 'unit override 2 changed'
    }
    Invoke-ClosureTest 'Compile-context exception cannot be missing' {
        $value = Read-ClosureClone
        $value.evidence.unit_argument_overrides = @(
            $value.evidence.unit_argument_overrides[0],
            $value.evidence.unit_argument_overrides[1]
        )
        $path = Write-ClosureFixture $value
        Assert-ClosureThrows {
            & (Join-Path $PSScriptRoot 'verify-win98-mesa-compiler-closure.ps1') `
                -ClosureFile $path
        } 'three exact ordered unit overrides'
    }
    Invoke-ClosureTest 'Compile-context exceptions cannot be swapped' {
        $value = Read-ClosureClone
        $second = $value.evidence.unit_argument_overrides[1]
        $third = $value.evidence.unit_argument_overrides[2]
        $value.evidence.unit_argument_overrides = @(
            $value.evidence.unit_argument_overrides[0], $third, $second
        )
        $path = Write-ClosureFixture $value
        Assert-ClosureThrows {
            & (Join-Path $PSScriptRoot 'verify-win98-mesa-compiler-closure.ps1') `
                -ClosureFile $path
        } 'unit override 1 changed'
    }
    Invoke-ClosureTest 'Compile-context exception cannot be added' {
        $value = Read-ClosureClone
        $value.evidence.unit_argument_overrides += `
            $value.evidence.unit_argument_overrides[1]
        $path = Write-ClosureFixture $value
        Assert-ClosureThrows {
            & (Join-Path $PSScriptRoot 'verify-win98-mesa-compiler-closure.ps1') `
                -ClosureFile $path
        } 'three exact ordered unit overrides'
    }
    Invoke-ClosureTest 'Compile-context exception binds both profiles' {
        $value = Read-ClosureClone
        $value.evidence.unit_argument_overrides[0].profiles = `
            @('mesa-object-v1')
        $path = Write-ClosureFixture $value
        Assert-ClosureThrows {
            & (Join-Path $PSScriptRoot 'verify-win98-mesa-compiler-closure.ps1') `
                -ClosureFile $path
        } 'unit override 0 changed'
    }
    Invoke-ClosureTest 'Compile-context exception rejects altered definitions' {
        $value = Read-ClosureClone
        $value.evidence.unit_argument_overrides[0].arguments = `
            @('-DHAVE_PTHREAD=1')
        $path = Write-ClosureFixture $value
        Assert-ClosureThrows {
            & (Join-Path $PSScriptRoot 'verify-win98-mesa-compiler-closure.ps1') `
                -ClosureFile $path
        } 'unit override 0 changed'
    }
    Invoke-ClosureTest 'Compile-context exception rejects added linker flags' {
        $value = Read-ClosureClone
        $value.evidence.unit_argument_overrides[0].arguments += '-lpthread'
        $path = Write-ClosureFixture $value
        Assert-ClosureThrows {
            & (Join-Path $PSScriptRoot 'verify-win98-mesa-compiler-closure.ps1') `
                -ClosureFile $path
        } 'unit override 0 changed'
    }
    Invoke-ClosureTest 'HAVE_PTHREAD cannot become a common definition' {
        $value = Read-ClosureClone
        $value.evidence.profile.common_arguments += '-DHAVE_PTHREAD'
        $path = Write-ClosureFixture $value
        Assert-ClosureThrows {
            & (Join-Path $PSScriptRoot 'verify-win98-mesa-compiler-closure.ps1') `
                -ClosureFile $path
        } 'forbidden define'
    }
    Invoke-ClosureTest 'USE_X86_ASM cannot become a dependency common definition' {
        $value = Read-ClosureClone
        $value.evidence.profile.common_arguments += '-DUSE_X86_ASM'
        $path = Write-ClosureFixture $value
        Assert-ClosureThrows {
            & (Join-Path $PSScriptRoot 'verify-win98-mesa-compiler-closure.ps1') `
                -ClosureFile $path
        } 'forbidden define'
    }
    Invoke-ClosureTest 'GLX_X86_READONLY_TEXT cannot become an object common definition' {
        $value = Read-ClosureClone
        $value.evidence.object_profile.common_arguments += `
            '-DGLX_X86_READONLY_TEXT'
        $path = Write-ClosureFixture $value
        Assert-ClosureThrows {
            & (Join-Path $PSScriptRoot 'verify-win98-mesa-compiler-closure.ps1') `
                -ClosureFile $path
        } 'forbidden define'
    }
    Invoke-ClosureTest 'Dependency target version cannot be promoted' {
        $value = Read-ClosureClone
        $value.evidence.profile.common_arguments += '-D_WIN32_WINNT=0x0600'
        $path = Write-ClosureFixture $value
        Assert-ClosureThrows {
            & (Join-Path $PSScriptRoot 'verify-win98-mesa-compiler-closure.ps1') `
                -ClosureFile $path
        } "one exact '-D_WIN32_WINNT=0x0400'"
    }
    Invoke-ClosureTest 'Object target version cannot be promoted' {
        $value = Read-ClosureClone
        $arguments = @(
            $value.evidence.object_profile.common_arguments | Where-Object {
                [string]$_ -cne '-DWINVER=0x0400'
            }
        )
        $arguments += '-DWINVER=0x0600'
        $value.evidence.object_profile.common_arguments = $arguments
        $path = Write-ClosureFixture $value
        Assert-ClosureThrows {
            & (Join-Path $PSScriptRoot 'verify-win98-mesa-compiler-closure.ps1') `
                -ClosureFile $path
        } "one exact '-DWINVER=0x0400'"
    }
    Invoke-ClosureTest 'Reviewed generated includes precede source includes' {
        $value = Read-ClosureClone
        $arguments = @($value.evidence.profile.common_arguments)
        $generatedIndex = -1
        $sourceIndex = -1
        for ($index = 0; $index -lt $arguments.Count; $index++) {
            if ([string]$arguments[$index] -ceq
                '{generated}/mesa-23.1.x/src/compiler/nir') {
                $generatedIndex = $index
            }
            elseif ([string]$arguments[$index] -ceq
                '{source}/mesa-23.1.x/src/compiler/nir') {
                $sourceIndex = $index
            }
        }
        $swap = $arguments[$generatedIndex]
        $arguments[$generatedIndex] = $arguments[$sourceIndex]
        $arguments[$sourceIndex] = $swap
        $value.evidence.profile.common_arguments = $arguments
        $path = Write-ClosureFixture $value
        Assert-ClosureThrows {
            & (Join-Path $PSScriptRoot 'verify-win98-mesa-compiler-closure.ps1') `
                -ClosureFile $path
        } 'prioritize reviewed generated inputs'
    }
    Invoke-ClosureTest 'Compiler children remain strictly sequential' {
        $value = Read-ClosureClone
        $value.evidence.object_profile.maximum_concurrent_children = 2
        $path = Write-ClosureFixture $value
        Assert-ClosureThrows {
            & (Join-Path $PSScriptRoot 'verify-win98-mesa-compiler-closure.ps1') `
                -ClosureFile $path
        } 'object profile changed'
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
    Invoke-ClosureTest 'Twin normalized object hashes remain identical' {
        $value = Read-ClosureClone
        $value.evidence.objects[0].run_b.normalized_sha256 = 'f' * 64
        $path = Write-ClosureFixture $value
        Assert-ClosureThrows {
            & (Join-Path $PSScriptRoot 'verify-win98-mesa-compiler-closure.ps1') `
                -ClosureFile $path
        } 'not exact'
    }
    Invoke-ClosureTest 'Object identities remain collision-free' {
        $value = Read-ClosureClone
        $value.evidence.objects[1].object = $value.evidence.objects[0].object
        $path = Write-ClosureFixture $value
        Assert-ClosureThrows {
            & (Join-Path $PSScriptRoot 'verify-win98-mesa-compiler-closure.ps1') `
                -ClosureFile $path
        } 'not exact'
    }
    Invoke-ClosureTest 'Ordered aggregate hash is recomputed' {
        $value = Read-ClosureClone
        $value.evidence.summary.aggregate_object_sha256 = '0' * 64
        $path = Write-ClosureFixture $value
        Assert-ClosureThrows {
            & (Join-Path $PSScriptRoot 'verify-win98-mesa-compiler-closure.ps1') `
                -ClosureFile $path
        } 'summary changed'
    }
    Invoke-ClosureTest 'Private absolute paths are rejected' {
        $value = Read-ClosureClone
        $value.reason = 'private C:\proof\object.o'
        $path = Write-ClosureFixture $value
        Assert-ClosureThrows {
            & (Join-Path $PSScriptRoot 'verify-win98-mesa-compiler-closure.ps1') `
                -ClosureFile $path
        } 'private absolute path'
    }
    Invoke-ClosureTest 'Renderer selection remains unauthorized' {
        $value = Read-ClosureClone
        $value.scope.authorizations.renderer_selection = $true
        $path = Write-ClosureFixture $value
        Assert-ClosureThrows {
            & (Join-Path $PSScriptRoot 'verify-win98-mesa-compiler-closure.ps1') `
                -ClosureFile $path
        } 'must remain false'
    }
    Invoke-ClosureTest 'Pthread link ABI remains unproven' {
        $value = Read-ClosureClone
        $value.scope.claims.pthread_link_abi_proven = $true
        $path = Write-ClosureFixture $value
        Assert-ClosureThrows {
            & (Join-Path $PSScriptRoot 'verify-win98-mesa-compiler-closure.ps1') `
                -ClosureFile $path
        } 'claims changed'
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
