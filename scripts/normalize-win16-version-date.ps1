# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:MaximumFileBytes = 64MB
$script:MaximumResourceCount = 4096
$script:MaximumSegmentCount = 4096
$script:MaximumModuleReferenceCount = 4096
$script:NeHeaderBytes = 64
$script:VersionType = 0x8010
$script:FixedInfoBytes = 52
$script:FixedInfoSignature = [uint32]4277077181
$script:FixedInfoStructureVersion = [uint32]65536
$script:VersionKey = [Text.Encoding]::ASCII.GetBytes("VS_VERSION_INFO`0")

function Assert-ByteRange {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][long]$Offset,
        [Parameter(Mandatory = $true)][long]$Length,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if ($Offset -lt 0 -or $Length -lt 0 -or
        $Offset -gt $Bytes.LongLength -or $Length -gt ($Bytes.LongLength - $Offset)) {
        throw "$Label is outside the executable."
    }
}

function Read-UInt16LE {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][long]$Offset,
        [Parameter(Mandatory = $true)][string]$Label
    )

    Assert-ByteRange $Bytes $Offset 2 $Label
    return [uint16]([uint16]$Bytes[$Offset] -bor ([uint16]$Bytes[$Offset + 1] -shl 8))
}

function Read-UInt32LE {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][long]$Offset,
        [Parameter(Mandatory = $true)][string]$Label
    )

    Assert-ByteRange $Bytes $Offset 4 $Label
    return [uint32](
        [uint32]$Bytes[$Offset] -bor
        ([uint32]$Bytes[$Offset + 1] -shl 8) -bor
        ([uint32]$Bytes[$Offset + 2] -shl 16) -bor
        ([uint32]$Bytes[$Offset + 3] -shl 24)
    )
}

function Test-NamedResourceIdentifier {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][long]$ResourceTableStart,
        [Parameter(Mandatory = $true)][long]$StructuresEnd,
        [Parameter(Mandatory = $true)][long]$ResourceTableEnd,
        [Parameter(Mandatory = $true)][int]$IdentifierOffset
    )

    $identifier = $ResourceTableStart + $IdentifierOffset
    if ($identifier -lt $StructuresEnd -or $identifier -ge $ResourceTableEnd) {
        throw 'An NE resource identifier points outside the resource string area.'
    }
    $length = [int]$Bytes[$identifier]
    if ($length -eq 0 -or $length -gt ($ResourceTableEnd - $identifier - 1)) {
        throw 'An NE resource identifier string is malformed.'
    }
}

function Test-ResidentNameTable {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][long]$Start,
        [Parameter(Mandatory = $true)][long]$End
    )

    $cursor = $Start
    $terminated = $false
    while ($cursor -lt $End) {
        $length = [int]$Bytes[$cursor]
        $cursor++
        if ($length -eq 0) {
            $terminated = $true
            break
        }
        if ($length -gt ($End - $cursor - 2)) {
            throw 'The NE resident-name table is malformed.'
        }
        $cursor += $length + 2
    }
    if (-not $terminated -or $cursor -ne $End) {
        throw 'The NE resident-name table is not exactly bounded.'
    }
}

function Test-ModuleReferenceTable {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][long]$ModuleStart,
        [Parameter(Mandatory = $true)][long]$ImportStart,
        [Parameter(Mandatory = $true)][long]$EntryStart,
        [Parameter(Mandatory = $true)][int]$Count
    )

    if (($ModuleStart + ([long]$Count * 2)) -ne $ImportStart) {
        throw 'The NE module-reference table is malformed.'
    }
    if ($ImportStart -ge $EntryStart -or $Bytes[$ImportStart] -ne 0) {
        throw 'The NE imported-name table is malformed.'
    }
    $importBytes = $EntryStart - $ImportStart
    for ($index = 0; $index -lt $Count; $index++) {
        $nameOffset = [int](Read-UInt16LE $Bytes ($ModuleStart + ($index * 2)) 'NE module-name offset')
        if ($nameOffset -eq 0 -or $nameOffset -ge $importBytes) {
            throw 'An NE module reference has an invalid imported-name offset.'
        }
        $nameStart = $ImportStart + $nameOffset
        $nameLength = [int]$Bytes[$nameStart]
        if ($nameLength -eq 0 -or $nameLength -gt ($EntryStart - $nameStart - 1)) {
            throw 'An NE imported module name is malformed.'
        }
    }
}

function Test-RangeOverlap {
    param(
        [Parameter(Mandatory = $true)][long]$Start,
        [Parameter(Mandatory = $true)][long]$End,
        [Parameter(Mandatory = $true)][long]$OtherStart,
        [Parameter(Mandatory = $true)][long]$OtherEnd
    )

    return $Start -lt $OtherEnd -and $OtherStart -lt $End
}

function Get-VersionDateOffsets {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][long]$ResourceStart,
        [Parameter(Mandatory = $true)][long]$ResourceLength
    )

    if ($ResourceLength -lt (4 + $script:VersionKey.Length + $script:FixedInfoBytes)) {
        throw 'An NE VERSIONINFO resource is too short.'
    }
    $rootLength = [int](Read-UInt16LE $Bytes $ResourceStart 'VERSIONINFO root length')
    $valueLength = [int](Read-UInt16LE $Bytes ($ResourceStart + 2) 'VERSIONINFO value length')
    $minimumLength = 4 + $script:VersionKey.Length + $script:FixedInfoBytes
    if ($rootLength -lt $minimumLength -or $rootLength -gt $ResourceLength) {
        throw 'The VERSIONINFO root length is malformed.'
    }
    if ($valueLength -ne $script:FixedInfoBytes) {
        throw 'The VERSIONINFO fixed-value length is not 52 bytes.'
    }

    for ($index = 0; $index -lt $script:VersionKey.Length; $index++) {
        if ($Bytes[$ResourceStart + 4 + $index] -ne $script:VersionKey[$index]) {
            throw 'The VERSIONINFO root key is malformed.'
        }
    }

    $fixedInfo = $ResourceStart + 4 + $script:VersionKey.Length
    Assert-ByteRange $Bytes $fixedInfo $script:FixedInfoBytes 'VS_FIXEDFILEINFO'
    if ((Read-UInt32LE $Bytes $fixedInfo 'VS_FIXEDFILEINFO signature') -ne
        $script:FixedInfoSignature) {
        throw 'The VS_FIXEDFILEINFO signature is invalid.'
    }
    if ((Read-UInt32LE $Bytes ($fixedInfo + 4) 'VS_FIXEDFILEINFO structure version') -ne
        $script:FixedInfoStructureVersion) {
        throw 'The VS_FIXEDFILEINFO structure version is unsupported.'
    }

    return [pscustomobject]@{
        DateMS = $fixedInfo + 44
        DateLS = $fixedInfo + 48
    }
}

function Find-VersionDateOffsets {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    Assert-ByteRange $Bytes 0 64 'DOS header'
    if ($Bytes[0] -ne 0x4d -or $Bytes[1] -ne 0x5a) {
        throw 'Input is not an MZ executable.'
    }

    $neStart = [long](Read-UInt32LE $Bytes 0x3c 'NE header offset')
    if ($neStart -lt 64) {
        throw 'The NE header overlaps the DOS header.'
    }
    Assert-ByteRange $Bytes $neStart $script:NeHeaderBytes 'NE header'
    if ($Bytes[$neStart] -ne 0x4e -or $Bytes[$neStart + 1] -ne 0x45) {
        throw 'Input is not an NE executable.'
    }
    if ($Bytes[$neStart + 0x36] -ne 2) {
        throw 'The NE executable does not target 16-bit Windows.'
    }

    $entryTableRelative = [int](Read-UInt16LE $Bytes ($neStart + 0x04) 'NE entry table offset')
    $entryTableBytes = [int](Read-UInt16LE $Bytes ($neStart + 0x06) 'NE entry table length')
    $segmentCount = [int](Read-UInt16LE $Bytes ($neStart + 0x1c) 'NE segment count')
    $moduleReferenceCount = [int](Read-UInt16LE $Bytes ($neStart + 0x1e) 'NE module-reference count')
    $nonResidentBytes = [int](Read-UInt16LE $Bytes ($neStart + 0x20) 'NE nonresident-name length')
    $segmentTableRelative = [int](Read-UInt16LE $Bytes ($neStart + 0x22) 'NE segment table offset')
    $resourceTableRelative = [int](Read-UInt16LE $Bytes ($neStart + 0x24) 'NE resource table offset')
    $residentTableRelative = [int](Read-UInt16LE $Bytes ($neStart + 0x26) 'NE resident-name table offset')
    $moduleTableRelative = [int](Read-UInt16LE $Bytes ($neStart + 0x28) 'NE module-reference table offset')
    $importTableRelative = [int](Read-UInt16LE $Bytes ($neStart + 0x2a) 'NE imported-name table offset')
    $nonResidentStart = [long](Read-UInt32LE $Bytes ($neStart + 0x2c) 'NE nonresident-name offset')
    $segmentAlignmentShift = [int](Read-UInt16LE $Bytes ($neStart + 0x32) 'NE segment alignment shift')
    $declaredResourceCount = [int](Read-UInt16LE $Bytes ($neStart + 0x34) 'NE resource count')

    if ($segmentCount -gt $script:MaximumSegmentCount -or
        $moduleReferenceCount -gt $script:MaximumModuleReferenceCount) {
        throw 'The NE metadata count exceeds the normalizer bound.'
    }
    if ($declaredResourceCount -gt $script:MaximumResourceCount) {
        throw 'The NE resource count exceeds the normalizer bound.'
    }
    $segmentTableBytes = [long]$segmentCount * 8
    if ($segmentTableRelative -lt $script:NeHeaderBytes -or
        $segmentTableBytes -gt ($resourceTableRelative - $segmentTableRelative) -or
        $resourceTableRelative -lt $script:NeHeaderBytes -or
        $residentTableRelative -le $resourceTableRelative -or
        $moduleTableRelative -le $residentTableRelative -or
        $importTableRelative -ne ($moduleTableRelative + ($moduleReferenceCount * 2)) -or
        $entryTableRelative -le $importTableRelative) {
        throw 'The NE resource-table bounds are malformed.'
    }
    $resourceTableStart = $neStart + $resourceTableRelative
    $resourceTableEnd = $neStart + $residentTableRelative
    $residentTableEnd = $neStart + $moduleTableRelative
    $moduleTableStart = $residentTableEnd
    $importTableStart = $neStart + $importTableRelative
    $entryTableStart = $neStart + $entryTableRelative
    $entryTableEnd = $entryTableStart + $entryTableBytes
    Assert-ByteRange $Bytes $resourceTableStart ($resourceTableEnd - $resourceTableStart) 'NE resource table'
    Assert-ByteRange $Bytes $resourceTableEnd ($residentTableEnd - $resourceTableEnd) 'NE resident-name table'
    Assert-ByteRange $Bytes $moduleTableStart ($importTableStart - $moduleTableStart) 'NE module-reference table'
    Assert-ByteRange $Bytes $importTableStart ($entryTableStart - $importTableStart) 'NE imported-name table'
    Assert-ByteRange $Bytes $entryTableStart $entryTableBytes 'NE entry table'
    if (($resourceTableEnd - $resourceTableStart) -lt 4) {
        throw 'The NE resource table is truncated.'
    }
    Test-ResidentNameTable $Bytes $resourceTableEnd $residentTableEnd
    Test-ModuleReferenceTable $Bytes $moduleTableStart $importTableStart $entryTableStart $moduleReferenceCount

    $nonResidentEnd = $nonResidentStart
    if ($nonResidentBytes -ne 0) {
        Assert-ByteRange $Bytes $nonResidentStart $nonResidentBytes 'NE nonresident-name table'
        $nonResidentEnd = $nonResidentStart + $nonResidentBytes
        if ($nonResidentStart -lt $entryTableEnd) {
            throw 'The NE nonresident-name table overlaps the resident metadata.'
        }
    }

    if ($segmentAlignmentShift -gt 31) {
        throw 'The NE segment alignment shift is unsupported.'
    }
    $segmentAlignment = [uint64][Math]::Pow(2, $segmentAlignmentShift)
    $segments = [Collections.Generic.List[object]]::new()
    $payloadFloor = [long][Math]::Max($entryTableEnd, $nonResidentEnd)
    $segmentTableStart = $neStart + $segmentTableRelative
    for ($index = 0; $index -lt $segmentCount; $index++) {
        $record = $segmentTableStart + ([long]$index * 8)
        $addressUnits = [uint64](Read-UInt16LE $Bytes $record 'NE segment data offset')
        if ($addressUnits -eq 0) {
            continue
        }
        $segmentLengthWord = [int](Read-UInt16LE $Bytes ($record + 2) 'NE segment data length')
        $segmentFlags = [int](Read-UInt16LE $Bytes ($record + 4) 'NE segment flags')
        $segmentLength = if ($segmentLengthWord -eq 0) { [long]65536 } else { [long]$segmentLengthWord }
        $segmentStart = $addressUnits * $segmentAlignment
        if ($segmentStart -gt [uint64]$Bytes.LongLength -or
            [uint64]$segmentLength -gt ([uint64]$Bytes.LongLength - $segmentStart)) {
            throw 'An NE segment points outside the executable.'
        }
        $segmentEnd = [long]($segmentStart + [uint64]$segmentLength)
        $protectedSegmentEnd = $segmentEnd
        if (($segmentFlags -band 0x0100) -ne 0) {
            $relocationCount = [int](Read-UInt16LE $Bytes $segmentEnd 'NE segment relocation count')
            $relocationBytes = 2 + ([long]$relocationCount * 8)
            Assert-ByteRange $Bytes $segmentEnd $relocationBytes 'NE segment relocation table'
            $protectedSegmentEnd = $segmentEnd + $relocationBytes
        }
        if ([long]$segmentStart -lt $entryTableEnd -or
            ($nonResidentBytes -ne 0 -and
                (Test-RangeOverlap ([long]$segmentStart) $protectedSegmentEnd $nonResidentStart $nonResidentEnd))) {
            throw 'An NE segment overlaps executable metadata.'
        }
        $segments.Add([pscustomobject]@{ Start = [long]$segmentStart; End = $protectedSegmentEnd })
        $payloadFloor = [long][Math]::Max($payloadFloor, $protectedSegmentEnd)
    }
    $orderedSegments = @($segments | Sort-Object Start, End)
    for ($index = 1; $index -lt $orderedSegments.Count; $index++) {
        if ($orderedSegments[$index].Start -lt $orderedSegments[$index - 1].End) {
            throw 'NE segment data ranges overlap.'
        }
    }

    $alignmentShift = [int](Read-UInt16LE $Bytes $resourceTableStart 'NE resource alignment shift')
    if ($alignmentShift -gt 31) {
        throw 'The NE resource alignment shift is unsupported.'
    }
    $alignment = [uint64][Math]::Pow(2, $alignmentShift)
    $cursor = $resourceTableStart + 2
    $resourceCount = 0
    $resources = [Collections.Generic.List[object]]::new()
    $namedIdentifiers = [Collections.Generic.List[int]]::new()

    while ($true) {
        if ($cursor -gt ($resourceTableEnd - 2)) {
            throw 'The NE resource table has no bounded terminator.'
        }
        $type = [int](Read-UInt16LE $Bytes $cursor 'NE resource type')
        if ($type -eq 0) {
            $cursor += 2
            break
        }
        Assert-ByteRange $Bytes $cursor 8 'NE resource type record'
        $typeCount = [int](Read-UInt16LE $Bytes ($cursor + 2) 'NE resource type count')
        if ($typeCount -eq 0) {
            throw 'An NE resource type has no resources.'
        }
        if ($typeCount -gt ($script:MaximumResourceCount - $resourceCount)) {
            throw 'The parsed NE resource count exceeds the normalizer bound.'
        }
        if ($declaredResourceCount -ne 0 -and
            $typeCount -gt ($declaredResourceCount - $resourceCount)) {
            throw 'The NE resource table exceeds its declared resource count.'
        }
        $recordsStart = $cursor + 8
        $recordsBytes = [long]$typeCount * 12
        if ($recordsStart -gt $resourceTableEnd -or
            $recordsBytes -gt ($resourceTableEnd - $recordsStart)) {
            throw 'An NE resource type record is truncated.'
        }
        if (($type -band 0x8000) -eq 0) {
            $namedIdentifiers.Add($type)
        }
        elseif (($type -band 0x7fff) -eq 0) {
            throw 'An NE resource type uses ordinal zero.'
        }

        for ($index = 0; $index -lt $typeCount; $index++) {
            $record = $recordsStart + ([long]$index * 12)
            $offsetUnits = [uint64](Read-UInt16LE $Bytes $record 'NE resource data offset')
            $lengthUnits = [uint64](Read-UInt16LE $Bytes ($record + 2) 'NE resource data length')
            if ($lengthUnits -eq 0) {
                throw 'An NE resource has zero length.'
            }
            $name = [int](Read-UInt16LE $Bytes ($record + 6) 'NE resource name')
            if (($name -band 0x8000) -eq 0) {
                $namedIdentifiers.Add($name)
            }
            elseif (($name -band 0x7fff) -eq 0) {
                throw 'An NE resource name uses ordinal zero.'
            }

            $resourceStart = $offsetUnits * $alignment
            $resourceLength = $lengthUnits * $alignment
            if ($resourceStart -gt [uint64]$Bytes.LongLength -or
                $resourceLength -gt ([uint64]$Bytes.LongLength - $resourceStart)) {
                throw 'An NE resource points outside the executable.'
            }
            if ($resourceStart -lt [uint64]$payloadFloor) {
                throw 'An NE resource overlaps executable metadata or segment data.'
            }
            $resources.Add([pscustomobject]@{
                Type = $type
                Start = [long]$resourceStart
                Length = [long]$resourceLength
                End = [long]($resourceStart + $resourceLength)
            })
            $resourceCount++
        }
        $cursor = $recordsStart + $recordsBytes
    }

    if ($declaredResourceCount -ne 0 -and $declaredResourceCount -ne $resourceCount) {
        throw 'The NE header resource count does not match the resource table.'
    }
    foreach ($identifierOffset in $namedIdentifiers) {
        Test-NamedResourceIdentifier $Bytes $resourceTableStart $cursor $resourceTableEnd $identifierOffset
    }

    $orderedResources = @($resources | Sort-Object Start, End)
    for ($index = 1; $index -lt $orderedResources.Count; $index++) {
        if ($orderedResources[$index].Start -lt $orderedResources[$index - 1].End) {
            throw 'NE resource data ranges overlap.'
        }
    }

    $versionDates = @()
    foreach ($resource in $resources) {
        if ($resource.Type -eq $script:VersionType) {
            $versionDates += Get-VersionDateOffsets $Bytes $resource.Start $resource.Length
        }
    }
    if ($versionDates.Count -eq 0) {
        throw 'The NE executable contains no structured VS_FIXEDFILEINFO.'
    }
    if ($versionDates.Count -ne 1) {
        throw 'The NE executable contains ambiguous VS_FIXEDFILEINFO resources.'
    }
    return $versionDates[0]
}

$fullPath = [IO.Path]::GetFullPath($Path)
if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
    throw "Win16 driver not found: $fullPath"
}
$file = Get-Item -LiteralPath $fullPath -Force
if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'Refusing to normalize a reparse-point executable.'
}

$inputStream = [IO.FileStream]::new(
    $fullPath,
    [IO.FileMode]::Open,
    [IO.FileAccess]::Read,
    [IO.FileShare]::Read,
    65536,
    [IO.FileOptions]::SequentialScan
)
try {
    if ($inputStream.Length -lt 64 -or $inputStream.Length -gt $script:MaximumFileBytes) {
        throw "The Win16 executable must be between 64 bytes and $($script:MaximumFileBytes) bytes."
    }
    $bytes = [byte[]]::new([int]$inputStream.Length)
    $read = 0
    while ($read -lt $bytes.Length) {
        $count = $inputStream.Read($bytes, $read, $bytes.Length - $read)
        if ($count -eq 0) {
            throw 'The Win16 executable ended while it was being read.'
        }
        $read += $count
    }
    $dateOffsets = Find-VersionDateOffsets $bytes

    $alreadyNormalized = $true
    foreach ($dateOffset in @($dateOffsets.DateMS, $dateOffsets.DateLS)) {
        for ($index = 0; $index -lt 4; $index++) {
            if ($bytes[$dateOffset + $index] -ne 0) {
                $alreadyNormalized = $false
            }
        }
    }
    if ($alreadyNormalized) {
        Write-Output "Win16 version date is already normalized: $fullPath"
        return
    }

    $normalized = [byte[]]$bytes.Clone()
    foreach ($dateOffset in @($dateOffsets.DateMS, $dateOffsets.DateLS)) {
        for ($index = 0; $index -lt 4; $index++) {
            $normalized[$dateOffset + $index] = 0
        }
    }
}
finally {
    $inputStream.Dispose()
}

$directory = [IO.Path]::GetDirectoryName($fullPath)
$temporaryName = '.{0}.normalize-{1}.tmp' -f [IO.Path]::GetFileName($fullPath), [Guid]::NewGuid().ToString('N')
$temporaryPath = Join-Path $directory $temporaryName
$backupName = '.{0}.normalize-backup-{1}.tmp' -f [IO.Path]::GetFileName($fullPath), [Guid]::NewGuid().ToString('N')
$backupPath = Join-Path $directory $backupName
try {
    $outputStream = [IO.FileStream]::new(
        $temporaryPath,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None,
        65536,
        [IO.FileOptions]::WriteThrough
    )
    try {
        $outputStream.Write($normalized, 0, $normalized.Length)
        $outputStream.Flush($true)
    }
    finally {
        $outputStream.Dispose()
    }
    [IO.File]::Replace($temporaryPath, $fullPath, $backupPath, $false)
}
finally {
    if (Test-Path -LiteralPath $temporaryPath) {
        Remove-Item -LiteralPath $temporaryPath -Force
    }
    if (Test-Path -LiteralPath $backupPath) {
        Remove-Item -LiteralPath $backupPath -Force
    }
}

Write-Output "Normalized Win16 version date: $fullPath"
