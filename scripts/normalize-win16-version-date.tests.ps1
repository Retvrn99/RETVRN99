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

function Assert-Equal {
    param($Actual, $Expected, [string]$Message = 'Values differ.')
    if ($Actual -ne $Expected) { throw "$Message Expected '$Expected', observed '$Actual'." }
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
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][scriptblock]$Body)
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

function Set-UInt16LE {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][int]$Offset,
        [Parameter(Mandatory = $true)][uint16]$Value
    )

    $Bytes[$Offset] = [byte]($Value -band 0xff)
    $Bytes[$Offset + 1] = [byte](($Value -shr 8) -band 0xff)
}

function Set-UInt32LE {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][int]$Offset,
        [Parameter(Mandatory = $true)][uint32]$Value
    )

    $Bytes[$Offset] = [byte]($Value -band 0xff)
    $Bytes[$Offset + 1] = [byte](($Value -shr 8) -band 0xff)
    $Bytes[$Offset + 2] = [byte](($Value -shr 16) -band 0xff)
    $Bytes[$Offset + 3] = [byte](($Value -shr 24) -band 0xff)
}

function New-MinimalWin16Ne {
    param(
        [ValidateRange(1, 8)][int]$VersionResourceCount = 1,
        [ValidateRange(2, 4096)][int]$NeStart = 0x40
    )

    $resourceTableStart = $NeStart + 0x40
    $resourceBytes = 2 + 8 + (12 * $VersionResourceCount) + 2
    $residentTableStart = $resourceTableStart + $resourceBytes
    $moduleTableStart = $residentTableStart + 1
    $importTableStart = $moduleTableStart
    $entryTableStart = $importTableStart + 1
    $resourceLength = 0x80
    $lastResourceStart = 0x200 + (($VersionResourceCount - 1) * 0x100)
    $bytes = [byte[]]::new($lastResourceStart + $resourceLength)

    $bytes[0] = 0x4d
    $bytes[1] = 0x5a
    Set-UInt32LE $bytes 0x3c ([uint32]$NeStart)
    $bytes[$NeStart] = 0x4e
    $bytes[$NeStart + 1] = 0x45
    Set-UInt16LE $bytes ($NeStart + 0x04) ([uint16]($entryTableStart - $NeStart))
    Set-UInt16LE $bytes ($NeStart + 0x22) 0x0040
    Set-UInt16LE $bytes ($NeStart + 0x24) ([uint16]($resourceTableStart - $NeStart))
    Set-UInt16LE $bytes ($NeStart + 0x26) ([uint16]($residentTableStart - $NeStart))
    Set-UInt16LE $bytes ($NeStart + 0x28) ([uint16]($moduleTableStart - $NeStart))
    Set-UInt16LE $bytes ($NeStart + 0x2a) ([uint16]($importTableStart - $NeStart))
    Set-UInt16LE $bytes ($NeStart + 0x34) ([uint16]$VersionResourceCount)
    $bytes[$NeStart + 0x36] = 2

    Set-UInt16LE $bytes $resourceTableStart 4
    Set-UInt16LE $bytes ($resourceTableStart + 2) 0x8010
    Set-UInt16LE $bytes ($resourceTableStart + 4) ([uint16]$VersionResourceCount)
    Set-UInt32LE $bytes ($resourceTableStart + 6) 0
    $record = $resourceTableStart + 10
    $dateOffsets = [Collections.Generic.List[int]]::new()
    $resourceStarts = [Collections.Generic.List[int]]::new()
    for ($index = 0; $index -lt $VersionResourceCount; $index++) {
        $resourceStart = 0x200 + ($index * 0x100)
        Set-UInt16LE $bytes $record ([uint16]($resourceStart -shr 4))
        Set-UInt16LE $bytes ($record + 2) ([uint16]($resourceLength -shr 4))
        Set-UInt16LE $bytes ($record + 4) 0x0030
        Set-UInt16LE $bytes ($record + 6) ([uint16](0x8001 + $index))
        Set-UInt32LE $bytes ($record + 8) 0
        $record += 12

        Set-UInt16LE $bytes $resourceStart 72
        Set-UInt16LE $bytes ($resourceStart + 2) 52
        $key = [Text.Encoding]::ASCII.GetBytes("VS_VERSION_INFO`0")
        [Array]::Copy($key, 0, $bytes, $resourceStart + 4, $key.Length)
        $fixedInfo = $resourceStart + 20
        Set-UInt32LE $bytes $fixedInfo ([uint32]4277077181)
        Set-UInt32LE $bytes ($fixedInfo + 4) 0x00010000
        for ($field = 2; $field -lt 11; $field++) {
            Set-UInt32LE $bytes ($fixedInfo + ($field * 4)) ([uint32](0x01010101 * $field))
        }
        Set-UInt32LE $bytes ($fixedInfo + 44) ([uint32](0x11223344 + $index))
        Set-UInt32LE $bytes ($fixedInfo + 48) ([uint32](0x55667788 + $index))
        $dateOffsets.Add($fixedInfo + 44)
        $dateOffsets.Add($fixedInfo + 48)
        $resourceStarts.Add($resourceStart)
    }
    Set-UInt16LE $bytes $record 0

    return [pscustomobject]@{
        Bytes = $bytes
        DateOffsets = @($dateOffsets)
        NeStart = $NeStart
        ResourceTableStart = $resourceTableStart
        ResourceTableEnd = $residentTableStart
        ResourceStarts = @($resourceStarts)
    }
}

function Write-Fixture {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][byte[]]$Bytes
    )

    [IO.File]::WriteAllBytes($Path, $Bytes)
}

function Assert-RejectedWithoutMutation {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Pattern
    )

    $before = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    Assert-Throws { & $script:Normalizer -Path $Path } $Pattern
    $after = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    Assert-Equal $after $before 'A rejected executable was modified.'
}

$script:Normalizer = Join-Path $PSScriptRoot 'normalize-win16-version-date.ps1'
$script:TestRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'retvrn99-win16-normalizer-test-{0}' -f [Guid]::NewGuid().ToString('N')
)
New-Item -ItemType Directory -Path $script:TestRoot | Out-Null

try {
    Invoke-SelfTest 'Only the two VS_FIXEDFILEINFO date DWORDs are zeroed' {
        $fixture = New-MinimalWin16Ne
        $path = Join-Path $script:TestRoot 'valid.drv'
        Write-Fixture $path $fixture.Bytes
        $before = [IO.File]::ReadAllBytes($path)

        $output = @(& $script:Normalizer -Path $path)
        Assert-Equal ($output -join [Environment]::NewLine) "Normalized Win16 version date: $path"
        $after = [IO.File]::ReadAllBytes($path)
        Assert-Equal $after.Length $before.Length

        $allowed = @{}
        foreach ($dateOffset in $fixture.DateOffsets) {
            for ($index = 0; $index -lt 4; $index++) {
                $allowed[$dateOffset + $index] = $true
            }
        }
        $changed = 0
        for ($index = 0; $index -lt $before.Length; $index++) {
            if ($allowed.ContainsKey($index)) {
                Assert-Equal $after[$index] 0 "Date byte $index was not zeroed."
                if ($after[$index] -ne $before[$index]) { $changed++ }
            }
            else {
                Assert-Equal $after[$index] $before[$index] "Unexpected byte change at $index."
            }
        }
        Assert-Equal $changed 8 'The fixture should exercise all eight date bytes.'
        Assert-Equal @(Get-ChildItem -LiteralPath $script:TestRoot -Filter '.valid.drv.normalize-*.tmp').Count 0
    }

    Invoke-SelfTest 'A normalized driver is left byte-identical and is not replaced again' {
        $fixture = New-MinimalWin16Ne
        $path = Join-Path $script:TestRoot 'idempotent.drv'
        Write-Fixture $path $fixture.Bytes
        & $script:Normalizer -Path $path | Out-Null
        $before = [IO.File]::ReadAllBytes($path)
        $fixedTime = [DateTime]::SpecifyKind([DateTime]'2001-02-03T04:05:06', [DateTimeKind]::Utc)
        [IO.File]::SetLastWriteTimeUtc($path, $fixedTime)

        $output = @(& $script:Normalizer -Path $path)
        Assert-Equal ($output -join [Environment]::NewLine) "Win16 version date is already normalized: $path"
        $after = [IO.File]::ReadAllBytes($path)
        Assert-Equal ([Convert]::ToHexString($after)) ([Convert]::ToHexString($before))
        Assert-Equal ([IO.File]::GetLastWriteTimeUtc($path).Ticks) $fixedTime.Ticks
    }

    Invoke-SelfTest 'A zero NE header resource count defers to the bounded parsed table' {
        $fixture = New-MinimalWin16Ne
        $bytes = [byte[]]$fixture.Bytes.Clone()
        Set-UInt16LE $bytes ($fixture.NeStart + 0x34) 0
        $path = Join-Path $script:TestRoot 'unspecified-resource-count.drv'
        Write-Fixture $path $bytes

        $output = @(& $script:Normalizer -Path $path)
        Assert-Equal ($output -join [Environment]::NewLine) "Normalized Win16 version date: $path"
        $normalized = [IO.File]::ReadAllBytes($path)
        foreach ($dateOffset in $fixture.DateOffsets) {
            for ($index = 0; $index -lt 4; $index++) {
                Assert-Equal $normalized[$dateOffset + $index] 0
            }
        }
    }

    Invoke-SelfTest 'Non-MZ, non-NE, and non-Windows inputs are rejected' {
        $plainPath = Join-Path $script:TestRoot 'plain.drv'
        Write-Fixture $plainPath ([byte[]]::new(64))
        Assert-RejectedWithoutMutation $plainPath 'not an MZ executable'

        $fixture = New-MinimalWin16Ne
        $peBytes = [byte[]]$fixture.Bytes.Clone()
        $peBytes[$fixture.NeStart] = 0x50
        $peBytes[$fixture.NeStart + 1] = 0x45
        $pePath = Join-Path $script:TestRoot 'pe.drv'
        Write-Fixture $pePath $peBytes
        Assert-RejectedWithoutMutation $pePath 'not an NE executable'

        $os2Bytes = [byte[]]$fixture.Bytes.Clone()
        $os2Bytes[$fixture.NeStart + 0x36] = 1
        $os2Path = Join-Path $script:TestRoot 'os2.drv'
        Write-Fixture $os2Path $os2Bytes
        Assert-RejectedWithoutMutation $os2Path 'does not target 16-bit Windows'
    }

    Invoke-SelfTest 'An NE header cannot overlap the DOS header' {
        $fixture = New-MinimalWin16Ne -NeStart 2
        $path = Join-Path $script:TestRoot 'overlapping-headers.drv'
        Write-Fixture $path $fixture.Bytes
        Assert-RejectedWithoutMutation $path 'NE header overlaps the DOS header'
    }

    Invoke-SelfTest 'Malformed and out-of-file NE resource layouts are rejected' {
        $fixture = New-MinimalWin16Ne
        $shortTable = [byte[]]$fixture.Bytes.Clone()
        Set-UInt16LE $shortTable ($fixture.NeStart + 0x26) 0x0048
        $shortPath = Join-Path $script:TestRoot 'short-table.drv'
        Write-Fixture $shortPath $shortTable
        Assert-RejectedWithoutMutation $shortPath '(resource|resident-name).*(truncated|outside|bounded)'

        $outside = [byte[]]$fixture.Bytes.Clone()
        Set-UInt16LE $outside ($fixture.ResourceTableStart + 10) 0xffff
        $outsidePath = Join-Path $script:TestRoot 'outside-resource.drv'
        Write-Fixture $outsidePath $outside
        Assert-RejectedWithoutMutation $outsidePath 'resource points outside'

        $countMismatch = [byte[]]$fixture.Bytes.Clone()
        Set-UInt16LE $countMismatch ($fixture.NeStart + 0x34) 2
        $countPath = Join-Path $script:TestRoot 'count-mismatch.drv'
        Write-Fixture $countPath $countMismatch
        Assert-RejectedWithoutMutation $countPath 'resource count does not match'
    }

    Invoke-SelfTest 'Resources cannot alias resident or entry-table metadata' {
        $fixture = New-MinimalWin16Ne
        $residentAlias = [byte[]]$fixture.Bytes.Clone()
        [Array]::Copy(
            $fixture.Bytes, $fixture.ResourceStarts[0],
            $residentAlias, $fixture.ResourceTableEnd, 0x80
        )
        Set-UInt16LE $residentAlias $fixture.ResourceTableStart 0
        Set-UInt16LE $residentAlias ($fixture.ResourceTableStart + 10) ([uint16]$fixture.ResourceTableEnd)
        Set-UInt16LE $residentAlias ($fixture.ResourceTableStart + 12) 0x0080
        $residentPath = Join-Path $script:TestRoot 'resident-alias.drv'
        Write-Fixture $residentPath $residentAlias
        Assert-RejectedWithoutMutation $residentPath 'resident-name table'

        $entryAlias = [byte[]]$fixture.Bytes.Clone()
        $entryStart = 0x100
        [Array]::Copy($fixture.Bytes, $fixture.ResourceStarts[0], $entryAlias, $entryStart, 0x80)
        Set-UInt16LE $entryAlias ($fixture.NeStart + 0x04) ([uint16]($entryStart - $fixture.NeStart))
        Set-UInt16LE $entryAlias ($fixture.NeStart + 0x06) 0x0080
        Set-UInt16LE $entryAlias $fixture.ResourceTableStart 0
        Set-UInt16LE $entryAlias ($fixture.ResourceTableStart + 10) ([uint16]$entryStart)
        Set-UInt16LE $entryAlias ($fixture.ResourceTableStart + 12) 0x0080
        $entryPath = Join-Path $script:TestRoot 'entry-alias.drv'
        Write-Fixture $entryPath $entryAlias
        Assert-RejectedWithoutMutation $entryPath 'resource overlaps executable metadata'
    }

    Invoke-SelfTest 'Resource counts are bounded before records are accumulated' {
        $fixture = New-MinimalWin16Ne
        $aboveBound = [byte[]]$fixture.Bytes.Clone()
        Set-UInt16LE $aboveBound ($fixture.NeStart + 0x34) 4097
        $aboveBoundPath = Join-Path $script:TestRoot 'resource-count-bound.drv'
        Write-Fixture $aboveBoundPath $aboveBound
        Assert-RejectedWithoutMutation $aboveBoundPath 'resource count exceeds the normalizer bound'

        $parsedBound = [byte[]]$fixture.Bytes.Clone()
        Set-UInt16LE $parsedBound ($fixture.NeStart + 0x34) 0
        Set-UInt16LE $parsedBound ($fixture.ResourceTableStart + 4) 4097
        $parsedBoundPath = Join-Path $script:TestRoot 'parsed-resource-count-bound.drv'
        Write-Fixture $parsedBoundPath $parsedBound
        Assert-RejectedWithoutMutation $parsedBoundPath 'parsed NE resource count exceeds the normalizer bound'

        $aggregate = [byte[]]$fixture.Bytes.Clone()
        Set-UInt16LE $aggregate ($fixture.ResourceTableStart + 4) 2
        $aggregatePath = Join-Path $script:TestRoot 'resource-count-aggregate.drv'
        Write-Fixture $aggregatePath $aggregate
        Assert-RejectedWithoutMutation $aggregatePath 'exceeds its declared resource count'
    }

    Invoke-SelfTest 'Malformed VERSIONINFO keys, lengths, signatures, and versions are rejected' {
        $fixture = New-MinimalWin16Ne
        $resourceStart = $fixture.ResourceStarts[0]
        $cases = @(
            [pscustomobject]@{ Name = 'key'; Pattern = 'root key'; Mutate = {
                param([byte[]]$Bytes) $Bytes[$resourceStart + 4] = 0x58
            } },
            [pscustomobject]@{ Name = 'root-length'; Pattern = 'root length'; Mutate = {
                param([byte[]]$Bytes) Set-UInt16LE $Bytes $resourceStart 71
            } },
            [pscustomobject]@{ Name = 'length'; Pattern = 'fixed-value length'; Mutate = {
                param([byte[]]$Bytes) Set-UInt16LE $Bytes ($resourceStart + 2) 48
            } },
            [pscustomobject]@{ Name = 'signature'; Pattern = 'signature is invalid'; Mutate = {
                param([byte[]]$Bytes) Set-UInt32LE $Bytes ($resourceStart + 20) 0
            } },
            [pscustomobject]@{ Name = 'version'; Pattern = 'structure version is unsupported'; Mutate = {
                param([byte[]]$Bytes) Set-UInt32LE $Bytes ($resourceStart + 24) 0x00020000
            } }
        )
        foreach ($case in $cases) {
            $bytes = [byte[]]$fixture.Bytes.Clone()
            & $case.Mutate $bytes
            $path = Join-Path $script:TestRoot "malformed-$($case.Name).drv"
            Write-Fixture $path $bytes
            Assert-RejectedWithoutMutation $path $case.Pattern
        }
    }

    Invoke-SelfTest 'A valid Win16 NE without an RT_VERSION resource is rejected' {
        $fixture = New-MinimalWin16Ne
        $bytes = [byte[]]$fixture.Bytes.Clone()
        Set-UInt16LE $bytes ($fixture.ResourceTableStart + 2) 0x8002
        $path = Join-Path $script:TestRoot 'no-version.drv'
        Write-Fixture $path $bytes
        Assert-RejectedWithoutMutation $path 'no structured VS_FIXEDFILEINFO'
    }

    Invoke-SelfTest 'Multiple structured fixed-file records are rejected as ambiguous' {
        $fixture = New-MinimalWin16Ne -VersionResourceCount 2
        $path = Join-Path $script:TestRoot 'ambiguous.drv'
        Write-Fixture $path $fixture.Bytes
        Assert-RejectedWithoutMutation $path 'ambiguous VS_FIXEDFILEINFO'
    }

    Invoke-SelfTest 'Inputs above the fixed parser bound are rejected before parsing' {
        $path = Join-Path $script:TestRoot 'oversized.drv'
        $stream = [IO.FileStream]::new(
            $path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None
        )
        try {
            $stream.SetLength((64MB) + 1)
        }
        finally {
            $stream.Dispose()
        }
        Assert-RejectedWithoutMutation $path 'must be between 64 bytes and'
    }
}
finally {
    $verifiedTestRoot = [IO.Path]::GetFullPath($script:TestRoot)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if (-not $verifiedTestRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        -not ([IO.Path]::GetFileName($verifiedTestRoot)).StartsWith('retvrn99-win16-normalizer-test-')) {
        throw "Refusing to remove unverified normalizer test path '$verifiedTestRoot'."
    }
    if (Test-Path -LiteralPath $verifiedTestRoot) {
        Remove-Item -LiteralPath $verifiedTestRoot -Recurse -Force
    }
}

if ($script:Failures -ne 0) {
    throw "$script:Failures Win16 version-date normalizer test(s) failed."
}
Write-Host 'All Win16 version-date normalizer tests passed.'
