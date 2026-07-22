# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'mesa-object-proof.ps1')

$script:Tests = 0
$script:Failures = 0
$script:TestRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'retvrn99-mesa-object-test-' + [Guid]::NewGuid().ToString('N')
)

function Invoke-ObjectTest {
    param([string]$Name, [scriptblock]$Body)

    $script:Tests++
    try { & $Body; Write-Output "PASS: $Name" }
    catch {
        $script:Failures++
        Write-Output "FAIL: $Name"
        Write-Output "  $($_.Exception.Message)"
    }
}

function Assert-ObjectThrows {
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

function New-TestCoff {
    param(
        [string]$Name,
        [UInt32]$Timestamp,
        [byte[]]$Payload = [byte[]](1, 2, 3, 4),
        [UInt16]$Machine = [UInt16]0x014c,
        [UInt16]$OptionalBytes = 0,
        [UInt32]$RawPointer = 60,
        [UInt16]$SectionCount = 1
    )

    $sectionEnd = 20 + [int]$SectionCount * 40
    $length = [Math]::Max($sectionEnd, [int]$RawPointer + $Payload.Length)
    [byte[]]$bytes = [byte[]]::new($length)
    [BitConverter]::GetBytes($Machine).CopyTo($bytes, 0)
    [BitConverter]::GetBytes($SectionCount).CopyTo($bytes, 2)
    [BitConverter]::GetBytes($Timestamp).CopyTo($bytes, 4)
    [BitConverter]::GetBytes($OptionalBytes).CopyTo($bytes, 16)
    [Text.Encoding]::ASCII.GetBytes('.data').CopyTo($bytes, 20)
    [BitConverter]::GetBytes([UInt32]$Payload.Length).CopyTo($bytes, 36)
    [BitConverter]::GetBytes($RawPointer).CopyTo($bytes, 40)
    $Payload.CopyTo($bytes, [int]$RawPointer)
    $path = Join-Path $script:TestRoot $Name
    [IO.File]::WriteAllBytes($path, $bytes)
    return $path
}

try {
    [void][IO.Directory]::CreateDirectory($script:TestRoot)
    Invoke-ObjectTest 'Timestamp-only normalization is reproducible' {
        $firstPath = New-TestCoff 'first.o' 123
        $secondPath = New-TestCoff 'second.o' 456
        $first = Get-MesaNormalizedCoffObject $firstPath @($script:TestRoot)
        $second = Get-MesaNormalizedCoffObject $secondPath @($script:TestRoot)
        Assert-MesaObjectTwin $first $second 'synthetic object'
        if ($first.RawSha256 -ceq $second.RawSha256 -or
            $first.Timestamp -ne 123 -or $second.Timestamp -ne 456) {
            throw 'Raw timestamp evidence was not retained.'
        }
        $raw = [IO.File]::ReadAllBytes($firstPath)
        for ($index = 0; $index -lt $raw.Length; $index++) {
            if ($index -ge 4 -and $index -le 7) { continue }
            if ($raw[$index] -ne $first.NormalizedBytes[$index]) {
                throw "Normalization changed byte $index."
            }
        }
    }
    Invoke-ObjectTest 'Non-i386 COFF is rejected' {
        $path = New-TestCoff 'machine.o' 0 ([byte[]](1)) ([UInt16]0x8664)
        Assert-ObjectThrows {
            Get-MesaNormalizedCoffObject $path @($script:TestRoot)
        } 'IMAGE_FILE_MACHINE_I386'
    }
    Invoke-ObjectTest 'Optional headers are rejected' {
        $path = New-TestCoff 'optional.o' 0 ([byte[]](1)) `
            ([UInt16]0x014c) ([UInt16]4)
        Assert-ObjectThrows {
            Get-MesaNormalizedCoffObject $path @($script:TestRoot)
        } 'optional header'
    }
    Invoke-ObjectTest 'Malformed COFF ranges are rejected' {
        $path = New-TestCoff 'range.o' 0 ([byte[]](1, 2, 3, 4)) `
            ([UInt16]0x014c) 0 ([UInt32]4096)
        [byte[]]$bytes = [IO.File]::ReadAllBytes($path)
        [Array]::Resize([ref]$bytes, 64)
        [IO.File]::WriteAllBytes($path, $bytes)
        Assert-ObjectThrows {
            Get-MesaNormalizedCoffObject $path @($script:TestRoot)
        } 'raw data'
    }
    Invoke-ObjectTest 'Uninitialized COFF data may omit raw bytes' {
        $path = New-TestCoff 'uninitialized.o' 0 ([byte[]](1))
        [byte[]]$bytes = [IO.File]::ReadAllBytes($path)
        [BitConverter]::GetBytes([UInt32]4096).CopyTo($bytes, 36)
        [BitConverter]::GetBytes([UInt32]0).CopyTo($bytes, 40)
        [BitConverter]::GetBytes([UInt32]0x00000080).CopyTo($bytes, 56)
        [IO.File]::WriteAllBytes($path, $bytes)
        [void](Get-MesaNormalizedCoffObject $path @($script:TestRoot))
    }
    Invoke-ObjectTest 'Initialized COFF data requires a raw offset' {
        $path = New-TestCoff 'missing-raw-offset.o' 0 ([byte[]](1))
        [byte[]]$bytes = [IO.File]::ReadAllBytes($path)
        [BitConverter]::GetBytes([UInt32]4096).CopyTo($bytes, 36)
        [BitConverter]::GetBytes([UInt32]0).CopyTo($bytes, 40)
        [BitConverter]::GetBytes([UInt32]0x00000040).CopyTo($bytes, 56)
        [IO.File]::WriteAllBytes($path, $bytes)
        Assert-ObjectThrows {
            Get-MesaNormalizedCoffObject $path @($script:TestRoot)
        } 'no raw-data offset'
    }
    Invoke-ObjectTest 'Bounded COFF objects may exceed 96 sections' {
        $path = New-TestCoff -Name 'many-sections.o' -Timestamp 0 `
            -Payload ([byte[]](1)) -RawPointer ([UInt32](20 + 97 * 40)) `
            -SectionCount ([UInt16]97)
        [void](Get-MesaNormalizedCoffObject $path @($script:TestRoot))
    }
    Invoke-ObjectTest 'Private absolute paths are rejected' {
        $private = Join-Path $script:TestRoot 'private-root'
        $payload = [Text.Encoding]::ASCII.GetBytes($private.Replace('\', '/'))
        $path = New-TestCoff 'private.o' 0 $payload
        Assert-ObjectThrows {
            Get-MesaNormalizedCoffObject $path @($private)
        } 'private absolute path'
    }
    Invoke-ObjectTest 'Even-offset UTF-16 private paths are rejected' {
        $private = Join-Path $script:TestRoot 'utf16-even-root'
        $payload = [Text.Encoding]::Unicode.GetBytes($private)
        $path = New-TestCoff 'private-utf16-even.o' 0 $payload
        Assert-ObjectThrows {
            Get-MesaNormalizedCoffObject $path @($private)
        } 'private absolute path'
    }
    Invoke-ObjectTest 'Mixed-separator private paths are rejected' {
        $private = Join-Path $script:TestRoot 'mixed-root'
        $normalized = $private.Replace('\', '/')
        $slash = $normalized.IndexOf('/')
        $mixed = $normalized.Substring(0, $slash) + '\' +
            $normalized.Substring($slash + 1)
        $path = New-TestCoff 'private-mixed.o' 0 `
            ([Text.Encoding]::ASCII.GetBytes($mixed))
        Assert-ObjectThrows {
            Get-MesaNormalizedCoffObject $path @($private)
        } 'private absolute path'
    }
    Invoke-ObjectTest 'Odd-offset UTF-16 private paths are rejected' {
        $private = Join-Path $script:TestRoot 'utf16-odd-root'
        $payload = [Text.Encoding]::Unicode.GetBytes($private)
        $path = New-TestCoff 'private-utf16-odd.o' 0 $payload `
            ([UInt16]0x014c) 0 ([UInt32]61)
        Assert-ObjectThrows {
            Get-MesaNormalizedCoffObject $path @($private)
        } 'private absolute path'
    }
    Invoke-ObjectTest 'Twin payload drift is rejected' {
        $first = Get-MesaNormalizedCoffObject `
            (New-TestCoff 'twin-a.o' 1 ([byte[]](1, 2, 3))) `
            @($script:TestRoot)
        $second = Get-MesaNormalizedCoffObject `
            (New-TestCoff 'twin-b.o' 2 ([byte[]](1, 2, 4))) `
            @($script:TestRoot)
        Assert-ObjectThrows {
            Assert-MesaObjectTwin $first $second 'synthetic object'
        } 'differ'
    }
    Invoke-ObjectTest 'Aggregate rejects duplicate object identities' {
        $hash = '0' * 64
        $objects = @(
            [pscustomobject]@{ unit_ordinal = 1; object = 'obj/a.o'; bytes = 64; normalized_sha256 = $hash },
            [pscustomobject]@{ unit_ordinal = 2; object = 'obj/a.o'; bytes = 64; normalized_sha256 = $hash }
        )
        Assert-ObjectThrows {
            Get-MesaObjectAggregateSha256 $objects
        } 'Duplicate object identity'
    }
    Invoke-ObjectTest 'Object tree cleanup is proof-root bounded' {
        $objects = Join-Path $script:TestRoot 'objects-a'
        [void][IO.Directory]::CreateDirectory($objects)
        [IO.File]::WriteAllBytes((Join-Path $objects 'unit.o'), [byte[]](1))
        Remove-MesaObjectTree $objects $script:TestRoot
        if (Test-Path -LiteralPath $objects) {
            throw 'Object tree survived cleanup.'
        }
        Assert-ObjectThrows {
            Remove-MesaObjectTree (Split-Path -Parent $script:TestRoot) `
                $script:TestRoot
        } 'outside proof root'
    }
}
finally {
    if ([IO.Directory]::Exists($script:TestRoot)) {
        [IO.Directory]::Delete($script:TestRoot, $true)
    }
}
if ($script:Failures -ne 0) {
    throw "$($script:Failures) of $($script:Tests) object-proof tests failed."
}
Write-Output "All $($script:Tests) object-proof tests passed."
