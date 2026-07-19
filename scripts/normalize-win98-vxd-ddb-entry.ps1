# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:MaximumVxdBytes = 64MB
$script:LinearHeaderMinimumBytes = 0xB0
$script:LinearObjectRecordBytes = 24
$script:DdbBytes = 80
$script:EntryExported = 0x01
$script:EntryShared = 0x02

function Assert-Range {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][long]$Offset,
        [Parameter(Mandatory = $true)][long]$Count,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if ($Offset -lt 0 -or $Count -lt 0 -or $Offset -gt $Bytes.LongLength -or
        $Count -gt $Bytes.LongLength - $Offset) {
        throw "$Label is outside the VxD image."
    }
}

function Read-U16 {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][long]$Offset,
        [Parameter(Mandatory = $true)][string]$Label
    )
    Assert-Range $Bytes $Offset 2 $Label
    return [uint16]([uint16]$Bytes[$Offset] -bor ([uint16]$Bytes[$Offset + 1] -shl 8))
}

function Read-U32 {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][long]$Offset,
        [Parameter(Mandatory = $true)][string]$Label
    )
    Assert-Range $Bytes $Offset 4 $Label
    return [uint32](
        [uint32]$Bytes[$Offset] -bor
        ([uint32]$Bytes[$Offset + 1] -shl 8) -bor
        ([uint32]$Bytes[$Offset + 2] -shl 16) -bor
        ([uint32]$Bytes[$Offset + 3] -shl 24)
    )
}

function Read-Ascii {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][long]$Offset,
        [Parameter(Mandatory = $true)][long]$Count,
        [Parameter(Mandatory = $true)][string]$Label
    )
    Assert-Range $Bytes $Offset $Count $Label
    return [Text.Encoding]::ASCII.GetString($Bytes, [int]$Offset, [int]$Count)
}

function Assert-GswSoundNames {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][long]$LinearOffset
    )

    $residentRelative = [long](Read-U32 $Bytes ($LinearOffset + 0x58) 'resident-name table offset')
    $residentOffset = $LinearOffset + $residentRelative
    Assert-Range $Bytes $residentOffset 12 'resident-name table'
    $residentLength = [int]$Bytes[$residentOffset]
    if ($residentLength -ne 8 -or
        (Read-Ascii $Bytes ($residentOffset + 1) $residentLength 'resident module name') -cne 'GSWSOUND' -or
        (Read-U16 $Bytes ($residentOffset + 1 + $residentLength) 'resident module ordinal') -ne 0 -or
        $Bytes[$residentOffset + 3 + $residentLength] -ne 0) {
        throw 'The LE resident-name table is not the exact GSWSOUND module record.'
    }

    $nonResidentOffset = [long](Read-U32 $Bytes ($LinearOffset + 0x88) 'nonresident-name table offset')
    $nonResidentBytes = [long](Read-U32 $Bytes ($LinearOffset + 0x8C) 'nonresident-name table size')
    if ($nonResidentBytes -lt 1) { throw 'The LE nonresident-name table is empty.' }
    Assert-Range $Bytes $nonResidentOffset $nonResidentBytes 'nonresident-name table'
    $cursor = $nonResidentOffset
    $end = $nonResidentOffset + $nonResidentBytes
    $ddbNames = 0
    while ($cursor -lt $end) {
        $length = [int]$Bytes[$cursor]
        $cursor++
        if ($length -eq 0) {
            if ($cursor -ne $end) { throw 'The LE nonresident-name terminator is not final.' }
            break
        }
        Assert-Range $Bytes $cursor ($length + 2) 'nonresident-name record'
        if ($cursor + $length + 2 -gt $end) {
            throw 'A nonresident-name record exceeds its declared table.'
        }
        $name = Read-Ascii $Bytes $cursor $length 'nonresident export name'
        $cursor += $length
        $ordinal = Read-U16 $Bytes $cursor 'nonresident export ordinal'
        $cursor += 2
        if ($ordinal -eq 1) {
            if ($name -cne 'GSWSOUND_DDB') {
                throw "Ordinal 1 has unexpected nonresident name '$name'."
            }
            $ddbNames++
        }
        elseif ($ordinal -ne 0) {
            throw "Unexpected named ordinal $ordinal in the GSW-Sound VxD."
        }
    }
    if ($cursor -ne $end -or $ddbNames -ne 1) {
        throw 'The LE nonresident-name table must name GSWSOUND_DDB at ordinal 1 exactly once.'
    }
}

$fullPath = [IO.Path]::GetFullPath($Path)
if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
    throw "GSW-Sound VxD is absent: $fullPath"
}
$item = Get-Item -LiteralPath $fullPath -Force
if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "GSW-Sound VxD must not be a reparse point: $fullPath"
}
if ($item.Length -lt 0x100 -or $item.Length -gt $script:MaximumVxdBytes) {
    throw "GSW-Sound VxD has an unsupported byte count: $($item.Length)."
}

$stream = [IO.File]::Open($fullPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
    if ($stream.Length -ne $item.Length) { throw 'GSW-Sound VxD changed before normalization.' }
    $bytes = [byte[]]::new([int]$stream.Length)
    $read = 0
    while ($read -lt $bytes.Length) {
        $count = $stream.Read($bytes, $read, $bytes.Length - $read)
        if ($count -eq 0) { throw 'Unexpected end of file while reading the GSW-Sound VxD.' }
        $read += $count
    }

    if ($bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) { throw 'GSW-Sound VxD has no MZ header.' }
    $linearOffset = [long](Read-U32 $bytes 0x3C 'linear-header pointer')
    Assert-Range $bytes $linearOffset $script:LinearHeaderMinimumBytes 'LE header'
    if ($bytes[$linearOffset] -ne 0x4C -or $bytes[$linearOffset + 1] -ne 0x45) {
        throw 'GSW-Sound VxD has no LE header.'
    }
    if ((Read-U16 $bytes ($linearOffset + 0x0A) 'LE target OS') -ne 4) {
        throw 'GSW-Sound VxD is not a Win386 LE image.'
    }
    Assert-GswSoundNames $bytes $linearOffset

    $objectRelative = [long](Read-U32 $bytes ($linearOffset + 0x40) 'object-table offset')
    $objectCount = [long](Read-U32 $bytes ($linearOffset + 0x44) 'object-table count')
    if ($objectCount -lt 1 -or $objectCount -gt 0xFFFF) {
        throw "The LE object count is unsupported: $objectCount."
    }
    $objectOffset = $linearOffset + $objectRelative
    Assert-Range $bytes $objectOffset ($objectCount * $script:LinearObjectRecordBytes) 'object table'

    $entryRelative = [long](Read-U32 $bytes ($linearOffset + 0x5C) 'entry-table offset')
    $entryOffset = $linearOffset + $entryRelative
    Assert-Range $bytes $entryOffset 10 'ordinal-1 entry bundle'
    $bundleCount = [int]$bytes[$entryOffset]
    $bundleType = [int]$bytes[$entryOffset + 1]
    $entryObject = [long](Read-U16 $bytes ($entryOffset + 2) 'ordinal-1 object')
    if ($bundleCount -ne 1 -or $bundleType -ne 3 -or
        $entryObject -lt 1 -or $entryObject -gt $objectCount) {
        throw 'Ordinal 1 is not the sole 32-bit GSWSOUND_DDB entry bundle.'
    }
    $flagsOffset = $entryOffset + 4
    $entryFlags = [int]$bytes[$flagsOffset]
    $ddbOffset = [long](Read-U32 $bytes ($entryOffset + 5) 'GSWSOUND_DDB object offset')
    if ($bytes[$entryOffset + 9] -ne 0) {
        throw 'The GSWSOUND_DDB entry bundle is not followed by the entry-table terminator.'
    }
    $objectRecord = $objectOffset + (($entryObject - 1) * $script:LinearObjectRecordBytes)
    $objectBytes = [long](Read-U32 $bytes $objectRecord 'GSWSOUND_DDB object size')
    if ($ddbOffset -lt 0 -or $ddbOffset -gt $objectBytes - $script:DdbBytes) {
        throw 'GSWSOUND_DDB does not fit in its declared LE object.'
    }
    if ($entryFlags -ne $script:EntryExported -and
        $entryFlags -ne ($script:EntryExported -bor $script:EntryShared)) {
        throw ('GSWSOUND_DDB has unsupported LE entry flags 0x{0:X2}.' -f $entryFlags)
    }

    $normalizedFlags = $script:EntryExported -bor $script:EntryShared
    if ($entryFlags -ne $normalizedFlags) {
        $stream.Position = $flagsOffset
        $stream.WriteByte([byte]$normalizedFlags)
        $stream.Flush($true)
        Write-Output ('Normalized GSWSOUND_DDB ordinal 1 at file offset 0x{0:X8}: 0x{1:X2} -> 0x{2:X2}.' -f
            $flagsOffset, $entryFlags, $normalizedFlags)
    }
    else {
        Write-Output ('GSWSOUND_DDB ordinal 1 is already normalized at file offset 0x{0:X8} (flags 0x{1:X2}).' -f
            $flagsOffset, $entryFlags)
    }
}
finally {
    $stream.Dispose()
}
