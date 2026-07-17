# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ToolchainRoot,

    [string]$LockFile,

    [scriptblock]$BeforeSecondScan
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:HardMaximumFiles = [UInt64]10000
$script:HardMaximumDirectories = [UInt64]5000
$script:HardMaximumEntries = [UInt64]15000
$script:HardMaximumAggregateBytes = [UInt64]1073741824
$script:HardMaximumFileBytes = [UInt64]67108864
$script:HardMaximumPathBytes = [UInt64]1024
if ([string]::IsNullOrWhiteSpace($LockFile)) {
    $LockFile = Join-Path $PSScriptRoot '..\drivers\win98\toolchain.lock.json'
}

function Get-FullPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }
    return [IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

function Assert-JsonPropertiesAreUnique {
    param(
        [Parameter(Mandatory = $true)][Text.Json.JsonElement]$Element,
        [Parameter(Mandatory = $true)][string]$JsonPath
    )

    if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($property in $Element.EnumerateObject()) {
            if (-not $names.Add($property.Name)) {
                throw "Duplicate JSON property '$($property.Name)' at $JsonPath."
            }
            Assert-JsonPropertiesAreUnique -Element $property.Value -JsonPath "$JsonPath.$($property.Name)"
        }
    }
    elseif ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
        $index = 0
        foreach ($item in $Element.EnumerateArray()) {
            Assert-JsonPropertiesAreUnique -Element $item -JsonPath "${JsonPath}[$index]"
            $index++
        }
    }
}

function Read-StrictJson {
    param([Parameter(Mandatory = $true)][string]$Path)

    $json = [IO.File]::ReadAllText($Path)
    try {
        $document = [Text.Json.JsonDocument]::Parse($json)
    }
    catch {
        throw "Malformed toolchain lock JSON: $($_.Exception.Message)"
    }
    try {
        Assert-JsonPropertiesAreUnique -Element $document.RootElement -JsonPath '$'
    }
    finally {
        $document.Dispose()
    }
    try {
        return $json | ConvertFrom-Json -Depth 16
    }
    catch {
        throw "Malformed toolchain lock JSON: $($_.Exception.Message)"
    }
}

function Assert-ExactProperties {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string[]]$Expected,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $actual = @($Object.PSObject.Properties.Name)
    foreach ($property in $actual) {
        if ($Expected -cnotcontains $property) {
            throw "Unexpected property '$property' in $Name metadata."
        }
    }
    foreach ($property in $Expected) {
        if ($actual -cnotcontains $property) {
            throw "Missing property '$property' in $Name metadata."
        }
    }
}

function Assert-UnsignedInteger {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $integerTypes = @(
        [byte], [uint16], [uint32], [uint64],
        [sbyte], [int16], [int32], [int64]
    )
    if ($integerTypes -cnotcontains $Value.GetType()) {
        throw "$Name must be a JSON integer."
    }
    try {
        $converted = [UInt64]$Value
    }
    catch {
        throw "$Name must be a non-negative 64-bit integer."
    }
    return $converted
}

function Get-ContainedPath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][object]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($RelativePath -isnot [string] -or
        [string]::IsNullOrWhiteSpace($RelativePath) -or
        [IO.Path]::IsPathRooted($RelativePath) -or
        $RelativePath.Contains('\') -or
        $RelativePath -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]*(/[A-Za-z0-9][A-Za-z0-9._+-]*)*$') {
        throw "Unsafe relative path '$RelativePath' in $Name metadata."
    }
    $rootPath = Get-FullPath $Root
    $rootPrefix = $rootPath.TrimEnd([char[]]'\/') + [IO.Path]::DirectorySeparatorChar
    $nativeRelativePath = $RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)
    $candidate = [IO.Path]::GetFullPath((Join-Path $rootPath $nativeRelativePath))
    if (-not $candidate.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Relative path '$RelativePath' escapes the toolchain root."
    }
    return $candidate
}

function Assert-PathComponentsAreNotReparsePoints {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $current = Get-FullPath $Root
    foreach ($component in $RelativePath.Split('/')) {
        $current = Join-Path $current $component
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($null -eq $item) {
            break
        }
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Reparse-point path component '$component' is not allowed in $Name metadata."
        }
    }
}

function Assert-LowercaseHash {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][int]$Length,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Value -isnot [string] -or $Value -cnotmatch "^[0-9a-f]{$Length}$") {
        throw "$Name must be a lowercase $Length-character hexadecimal digest."
    }
}

function Assert-ExactStringArray {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string[]]$Expected,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Value -isnot [Array]) {
        throw "$Name must be an array."
    }
    $values = @($Value)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $values) {
        if ($item -isnot [string]) {
            throw "$Name entries must be strings."
        }
        if (-not $seen.Add($item)) {
            throw "Duplicate $Name entry '$item'."
        }
    }
    if ($values.Count -ne $Expected.Count) {
        throw "$Name must be exactly: $($Expected -join ';')."
    }
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        if ($values[$index] -cne $Expected[$index]) {
            throw "$Name must be exactly: $($Expected -join ';')."
        }
    }
}

function Get-BigEndianBytes {
    param([Parameter(Mandatory = $true)][UInt64]$Value, [Parameter(Mandatory = $true)][int]$Width)

    if ($Width -eq 4) {
        if ($Value -gt [UInt32]::MaxValue) {
            throw 'Canonical tree field exceeds 32 bits.'
        }
        $bytes = [BitConverter]::GetBytes([UInt32]$Value)
    }
    elseif ($Width -eq 8) {
        $bytes = [BitConverter]::GetBytes($Value)
    }
    else {
        throw "Unsupported canonical integer width $Width."
    }
    if ([BitConverter]::IsLittleEndian) {
        [Array]::Reverse($bytes)
    }
    return $bytes
}

function Get-PortableRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $relativePath = [IO.Path]::GetRelativePath($Root, $Path)
    if ([IO.Path]::DirectorySeparatorChar -ne '/') {
        $relativePath = $relativePath.Replace([IO.Path]::DirectorySeparatorChar, '/')
    }
    if ([IO.Path]::IsPathRooted($relativePath) -or
        $relativePath -eq '..' -or
        $relativePath.StartsWith('../', [StringComparison]::Ordinal)) {
        throw "Toolchain entry escapes the extracted root: $Path"
    }
    if ($relativePath.Contains('\')) {
        throw "Literal backslashes are not portable in toolchain path '$relativePath'."
    }
    foreach ($component in $relativePath.Split('/')) {
        if ($component -notmatch '^[A-Za-z0-9_][A-Za-z0-9._+-]*$') {
            throw "Non-portable toolchain path component '$component' in '$relativePath'."
        }
    }
    return $relativePath
}

function Get-ToolchainTreeDescriptor {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][UInt64]$ExpectedFileCount,
        [Parameter(Mandatory = $true)][UInt64]$ExpectedDirectoryCount,
        [Parameter(Mandatory = $true)][UInt64]$ExpectedTotalEntries,
        [Parameter(Mandatory = $true)][UInt64]$ExpectedAggregateBytes,
        [Parameter(Mandatory = $true)][UInt64]$ExpectedMaximumFileBytes,
        [Parameter(Mandatory = $true)][UInt64]$ExpectedMaximumPathBytes
    )

    $rootPath = Get-FullPath $Root
    $records = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $pendingDirectories = [Collections.Generic.Stack[string]]::new()
    $pendingDirectories.Push($rootPath)
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    [UInt64]$fileCount = 0
    [UInt64]$directoryCount = 0
    [UInt64]$totalEntries = 0
    [UInt64]$aggregateBytes = 0
    [UInt64]$maximumFileBytes = 0
    [UInt64]$maximumPathBytes = 0

    while ($pendingDirectories.Count -ne 0) {
        $directoryPath = $pendingDirectories.Pop()
        foreach ($entryPath in [IO.Directory]::EnumerateFileSystemEntries($directoryPath)) {
            $totalEntries++
            if ($totalEntries -gt $script:HardMaximumEntries -or
                $totalEntries -gt $ExpectedTotalEntries) {
                throw "Extracted toolchain entry count exceeds locked or hard bounds."
            }

            $relativePath = Get-PortableRelativePath $rootPath $entryPath
            [UInt64]$pathBytes = $utf8.GetByteCount($relativePath)
            if ($pathBytes -gt $script:HardMaximumPathBytes -or
                $pathBytes -gt $ExpectedMaximumPathBytes) {
                throw "Toolchain path '$relativePath' exceeds locked or hard length bounds."
            }
            if ($pathBytes -gt $maximumPathBytes) {
                $maximumPathBytes = $pathBytes
            }

            $attributes = [IO.File]::GetAttributes($entryPath)
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Reparse points are not allowed in the extracted toolchain: $entryPath"
            }
            if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) {
                $directoryCount++
                if ($directoryCount -gt $script:HardMaximumDirectories -or
                    $directoryCount -gt $ExpectedDirectoryCount) {
                    throw 'Extracted toolchain directory count exceeds locked or hard bounds.'
                }
                $pendingDirectories.Push($entryPath)
                continue
            }
            if (($attributes -band [IO.FileAttributes]::Device) -ne 0) {
                throw "Non-regular toolchain entry is not supported: $entryPath"
            }

            $fileCount++
            if ($fileCount -gt $script:HardMaximumFiles -or $fileCount -gt $ExpectedFileCount) {
                throw 'Extracted toolchain file count exceeds locked or hard bounds.'
            }
            if ($records.ContainsKey($relativePath)) {
                throw "Duplicate normalized toolchain path '$relativePath'."
            }

            $stream = [IO.File]::Open(
                $entryPath,
                [IO.FileMode]::Open,
                [IO.FileAccess]::Read,
                [IO.FileShare]::Read
            )
            try {
                [UInt64]$length = $stream.Length
                if ($length -gt $script:HardMaximumFileBytes -or
                    $length -gt $ExpectedMaximumFileBytes) {
                    throw "Toolchain file '$relativePath' exceeds locked or hard size bounds."
                }
                if ([UInt64]::MaxValue - $aggregateBytes -lt $length) {
                    throw 'Extracted toolchain byte count overflowed 64 bits.'
                }
                [UInt64]$nextAggregateBytes = $aggregateBytes + $length
                if ($nextAggregateBytes -gt $script:HardMaximumAggregateBytes -or
                    $nextAggregateBytes -gt $ExpectedAggregateBytes) {
                    throw 'Extracted toolchain byte count exceeds locked or hard bounds.'
                }
                $sha = [Security.Cryptography.SHA256]::Create()
                try {
                    [byte[]]$fileHash = $sha.ComputeHash($stream)
                }
                finally {
                    $sha.Dispose()
                }
            }
            finally {
                $stream.Dispose()
            }

            $aggregateBytes = $nextAggregateBytes
            if ($length -gt $maximumFileBytes) {
                $maximumFileBytes = $length
            }
            $records.Add($relativePath, [pscustomobject]@{
                Length = $length
                Hash = $fileHash
            })
        }
    }

    [string[]]$paths = @($records.Keys)
    [Array]::Sort($paths, [StringComparer]::Ordinal)
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    # v1 uses big-endian counts, then ordinal UTF-8 path/length/SHA256 records.
    $digest = [Security.Cryptography.IncrementalHash]::CreateHash(
        [Security.Cryptography.HashAlgorithmName]::SHA256
    )
    try {
        $digest.AppendData($utf8.GetBytes("RETVRN99-WIN98-TREE-SHA256-V1`0"))
        $digest.AppendData((Get-BigEndianBytes -Value ([UInt64]$paths.Count) -Width 8))
        $digest.AppendData((Get-BigEndianBytes -Value $aggregateBytes -Width 8))
        foreach ($relativePath in $paths) {
            [byte[]]$pathBytes = $utf8.GetBytes($relativePath)
            $record = $records[$relativePath]
            $digest.AppendData((Get-BigEndianBytes -Value ([UInt64]$pathBytes.Length) -Width 4))
            $digest.AppendData($pathBytes)
            $digest.AppendData((Get-BigEndianBytes -Value ([UInt64]$record.Length) -Width 8))
            $digest.AppendData([byte[]]$record.Hash)
        }
        $treeHash = [Convert]::ToHexString($digest.GetHashAndReset()).ToLowerInvariant()
    }
    finally {
        $digest.Dispose()
    }

    return [pscustomobject]@{
        FileCount = $fileCount
        DirectoryCount = $directoryCount
        TotalEntries = $totalEntries
        AggregateBytes = $aggregateBytes
        MaximumFileBytes = $maximumFileBytes
        MaximumPathBytes = $maximumPathBytes
        Sha256 = $treeHash
    }
}

function Assert-TreeDescriptorMatches {
    param(
        [Parameter(Mandatory = $true)][object]$Observed,
        [Parameter(Mandatory = $true)][object]$Expected,
        [Parameter(Mandatory = $true)][string]$Name
    )

    foreach ($property in @(
        'FileCount', 'DirectoryCount', 'TotalEntries', 'AggregateBytes',
        'MaximumFileBytes', 'MaximumPathBytes', 'Sha256'
    )) {
        if ($Observed.$property -cne $Expected.$property) {
            throw "$Name $property mismatch: expected $($Expected.$property), observed $($Observed.$property)."
        }
    }
}

$lockPath = Get-FullPath $LockFile
$toolchainRootPath = Get-FullPath $ToolchainRoot
if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
    throw "Toolchain lock not found: $lockPath"
}
if (-not (Test-Path -LiteralPath $toolchainRootPath -PathType Container)) {
    throw "Toolchain root not found: $toolchainRootPath"
}
if (((Get-Item -LiteralPath $toolchainRootPath).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'The toolchain root cannot be a reparse point.'
}

$lock = Read-StrictJson $lockPath
Assert-ExactProperties $lock @('_spdx', 'schema', 'name', 'archive', 'extracted', 'environment') 'root'
Assert-ExactProperties $lock.archive @('relative_path', 'bytes', 'sha256', 'md5') 'archive'
Assert-ExactProperties $lock.extracted @(
    'relative_path', 'file_count', 'directory_count', 'total_entries',
    'aggregate_bytes', 'maximum_file_bytes', 'maximum_path_bytes',
    'digest_algorithm', 'sha256'
) 'extracted'
Assert-ExactProperties $lock.environment @(
    'watcom_root', 'edpath', 'include', 'path_prefixes'
) 'environment'

if ($lock._spdx -cne 'GPL-3.0-only') {
    throw 'The toolchain lock must declare GPL-3.0-only metadata licensing.'
}
if ((Assert-UnsignedInteger $lock.schema 'schema') -ne 1) {
    throw "Unsupported toolchain lock schema '$($lock.schema)'."
}
if ($lock.name -isnot [string] -or $lock.name -cnotmatch '^[a-z0-9][a-z0-9.-]*$') {
    throw "Invalid toolchain name '$($lock.name)'."
}
Assert-LowercaseHash $lock.archive.sha256 64 'archive.sha256'
Assert-LowercaseHash $lock.archive.md5 32 'archive.md5'
Assert-LowercaseHash $lock.extracted.sha256 64 'extracted.sha256'
if ($lock.extracted.digest_algorithm -cne 'retvrn99-file-tree-sha256-v1') {
    throw "Unsupported extracted-tree digest algorithm '$($lock.extracted.digest_algorithm)'."
}

[UInt64]$expectedArchiveBytes = Assert-UnsignedInteger $lock.archive.bytes 'archive.bytes'
[UInt64]$expectedFileCount = Assert-UnsignedInteger $lock.extracted.file_count 'extracted.file_count'
[UInt64]$expectedDirectoryCount = Assert-UnsignedInteger $lock.extracted.directory_count 'extracted.directory_count'
[UInt64]$expectedTotalEntries = Assert-UnsignedInteger $lock.extracted.total_entries 'extracted.total_entries'
[UInt64]$expectedAggregateBytes = Assert-UnsignedInteger $lock.extracted.aggregate_bytes 'extracted.aggregate_bytes'
[UInt64]$expectedMaximumFileBytes = Assert-UnsignedInteger $lock.extracted.maximum_file_bytes 'extracted.maximum_file_bytes'
[UInt64]$expectedMaximumPathBytes = Assert-UnsignedInteger $lock.extracted.maximum_path_bytes 'extracted.maximum_path_bytes'
if ($expectedFileCount -gt $script:HardMaximumFiles -or
    $expectedDirectoryCount -gt $script:HardMaximumDirectories -or
    $expectedTotalEntries -gt $script:HardMaximumEntries -or
    $expectedAggregateBytes -gt $script:HardMaximumAggregateBytes -or
    $expectedMaximumFileBytes -gt $script:HardMaximumFileBytes -or
    $expectedMaximumPathBytes -gt $script:HardMaximumPathBytes) {
    throw 'Extracted toolchain lock exceeds verifier hard bounds.'
}
if ($expectedTotalEntries -ne $expectedFileCount + $expectedDirectoryCount) {
    throw 'extracted.total_entries must equal file_count plus directory_count.'
}
if (($expectedFileCount -eq 0 -and $expectedMaximumFileBytes -ne 0) -or
    $expectedMaximumFileBytes -gt $expectedAggregateBytes -or
    ($expectedTotalEntries -eq 0 -and $expectedMaximumPathBytes -ne 0)) {
    throw 'Extracted toolchain maximum-size metadata is inconsistent.'
}
$archivePath = Get-ContainedPath $toolchainRootPath $lock.archive.relative_path 'archive'
$extractedPath = Get-ContainedPath $toolchainRootPath $lock.extracted.relative_path 'extracted'
if ($archivePath -ieq $extractedPath) {
    throw 'Archive and extracted toolchain paths must be distinct.'
}
Assert-PathComponentsAreNotReparsePoints $toolchainRootPath $lock.archive.relative_path 'archive'
Assert-PathComponentsAreNotReparsePoints $toolchainRootPath $lock.extracted.relative_path 'extracted'

if ($lock.environment.watcom_root -cne '.' -or $lock.environment.edpath -cne 'eddat') {
    throw "Environment metadata must set WATCOM='.' and EDPATH='eddat'."
}
Assert-ExactStringArray $lock.environment.include @('h/nt', 'h/win', 'h') 'environment.include'
Assert-ExactStringArray $lock.environment.path_prefixes @('binnt', 'binw') 'environment.path_prefixes'

if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
    throw "Pinned toolchain archive is absent: $archivePath"
}
if (-not (Test-Path -LiteralPath $extractedPath -PathType Container)) {
    throw "Extracted toolchain is absent: $extractedPath"
}
if (((Get-Item -LiteralPath $archivePath).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
    ((Get-Item -LiteralPath $extractedPath).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'Pinned toolchain archive and extracted root cannot be reparse points.'
}

$requiredEnvironmentDirectories = @('eddat', 'h/nt', 'h/win', 'h', 'binnt', 'binw')
foreach ($relativePath in $requiredEnvironmentDirectories) {
    $directoryPath = Get-ContainedPath $extractedPath $relativePath 'environment'
    Assert-PathComponentsAreNotReparsePoints $extractedPath $relativePath 'environment'
    if (-not (Test-Path -LiteralPath $directoryPath -PathType Container)) {
        throw "Required Watcom environment directory is absent: $relativePath"
    }
    if (((Get-Item -LiteralPath $directoryPath).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Required Watcom environment directory is a reparse point: $relativePath"
    }
}

$archive = Get-Item -LiteralPath $archivePath
if ([UInt64]$archive.Length -ne $expectedArchiveBytes) {
    throw "Toolchain archive byte count mismatch: expected $expectedArchiveBytes, observed $($archive.Length)."
}
$archiveSha256 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($archiveSha256 -cne $lock.archive.sha256) {
    throw "Toolchain archive SHA256 mismatch: expected $($lock.archive.sha256), observed $archiveSha256."
}
$archiveMd5 = (Get-FileHash -LiteralPath $archivePath -Algorithm MD5).Hash.ToLowerInvariant()
if ($archiveMd5 -cne $lock.archive.md5) {
    throw "Toolchain archive MD5 mismatch: expected $($lock.archive.md5), observed $archiveMd5."
}

$lockedTree = [pscustomobject]@{
    FileCount = $expectedFileCount
    DirectoryCount = $expectedDirectoryCount
    TotalEntries = $expectedTotalEntries
    AggregateBytes = $expectedAggregateBytes
    MaximumFileBytes = $expectedMaximumFileBytes
    MaximumPathBytes = $expectedMaximumPathBytes
    Sha256 = $lock.extracted.sha256
}
$scanArguments = @{
    Root = $extractedPath
    ExpectedFileCount = $expectedFileCount
    ExpectedDirectoryCount = $expectedDirectoryCount
    ExpectedTotalEntries = $expectedTotalEntries
    ExpectedAggregateBytes = $expectedAggregateBytes
    ExpectedMaximumFileBytes = $expectedMaximumFileBytes
    ExpectedMaximumPathBytes = $expectedMaximumPathBytes
}
$firstTree = Get-ToolchainTreeDescriptor @scanArguments
Assert-TreeDescriptorMatches $firstTree $lockedTree 'Extracted toolchain'
if ($null -ne $BeforeSecondScan) {
    & $BeforeSecondScan $extractedPath | Out-Null
}
$secondTree = Get-ToolchainTreeDescriptor @scanArguments
Assert-TreeDescriptorMatches $secondTree $firstTree 'Second extracted-toolchain scan'
Assert-TreeDescriptorMatches $secondTree $lockedTree 'Extracted toolchain'

Write-Output (
    "Verified Windows 98 toolchain '$($lock.name)' " +
    "($($secondTree.FileCount) files, $($secondTree.AggregateBytes) bytes, tree $($secondTree.Sha256))."
)
