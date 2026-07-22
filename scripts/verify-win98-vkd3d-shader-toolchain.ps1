# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [string]$LockFile,
    [switch]$MetadataOnly,
    [hashtable]$RootMappings
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:MaximumJsonBytes = [UInt64](1024 * 1024)
$script:MaximumPathBytes = 512
$script:ExpectedSchemaSha256 = `
    '8cd4361a09adc07ab35ada394743db2580ffbd0ae62458cdd601679a6ca34814'
$script:ExpectedLockSha256 = `
    '0e38b6d9098200f0572ac0c9a6b38e2b0b2e563309cd8493c4629a661364f533'
$script:Utf8 = [Text.UTF8Encoding]::new($false, $true)

. (Join-Path $PSScriptRoot 'strict-json.ps1')
. (Join-Path $PSScriptRoot 'vkd3d-shader-compiler-evidence.ps1')

if ([string]::IsNullOrWhiteSpace($LockFile)) {
    $LockFile = Join-Path $PSScriptRoot `
        '..\drivers\win98\vkd3d-shader-toolchain-lock.json'
}

function Assert-ExactProperties {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string[]]$Expected,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $actual = @($Value.PSObject.Properties.Name)
    foreach ($property in $actual) {
        if ($Expected -cnotcontains $property) {
            throw "Unexpected property '$property' in $Name."
        }
    }
    foreach ($property in $Expected) {
        if ($actual -cnotcontains $property) {
            throw "Missing property '$property' in $Name."
        }
    }
}

function Assert-String {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$MaximumLength = 1024
    )

    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value) -or
        $Value.Length -gt $MaximumLength -or $Value.IndexOf([char]0) -ge 0) {
        throw "$Name must be a bounded non-empty string."
    }
    return [string]$Value
}

function Assert-UnsignedInteger {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string]$Name,
        [UInt64]$Maximum = [UInt64]::MaxValue
    )

    $types = @([byte], [uint16], [uint32], [uint64], [sbyte], [int16], [int32], [int64])
    if ($types -cnotcontains $Value.GetType()) {
        throw "$Name must be a JSON integer."
    }
    try {
        [UInt64]$number = $Value
    }
    catch {
        throw "$Name must be a non-negative integer."
    }
    if ($number -gt $Maximum) {
        throw "$Name exceeds its hard bound."
    }
    return $number
}

function Assert-Sha256 {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Value -isnot [string] -or $Value -cnotmatch '^[0-9a-f]{64}$') {
        throw "$Name must be one lowercase SHA-256 digest."
    }
}

function Assert-SafeRelativePath {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$RequireLeaf
    )

    $path = Assert-String $Value $Name $script:MaximumPathBytes
    if ([IO.Path]::IsPathRooted($path) -or $path.Contains('\') -or
        $script:Utf8.GetByteCount($path) -gt $script:MaximumPathBytes) {
        throw "Unsafe relative path '$path' in $Name."
    }
    if ($RequireLeaf -and $path.Contains('/')) {
        throw "$Name must be one portable filename."
    }
    foreach ($component in $path.Split('/')) {
        if ([string]::IsNullOrWhiteSpace($component) -or
            $component -in @('.', '..') -or
            $component -match '[\x00-\x1f:*?"<>|]' -or
            $component.EndsWith('.') -or $component.EndsWith(' ') -or
            $component -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$') {
            throw "Unsafe path component '$component' in $Name."
        }
    }
    return $path
}

function Assert-NoPrivatePathText {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Text -match '(?i)(?:^|["''\s])(?:[a-z]:[\\/]|\\\\)' -or
        $Text -match '(?i)/(?:Users|home|private|tmp|var/tmp)/') {
        throw "$Name contains a private absolute path."
    }
}

function Get-OrdinaryFileHash {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [UInt64]$MaximumBytes = [UInt64]67108864
    )

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::Directory) -ne 0 -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        ($item.Attributes -band [IO.FileAttributes]::Device) -ne 0) {
        throw "$Name must be one ordinary file."
    }
    [UInt64]$length = $item.Length
    if ($length -gt $MaximumBytes) {
        throw "$Name exceeds its byte bound."
    }
    $stream = [IO.File]::Open(
        $item.FullName,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read
    )
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $digest = $sha.ComputeHash($stream)
        }
        finally {
            $sha.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
    return [pscustomobject]@{
        Bytes = $length
        Sha256 = ([BitConverter]::ToString($digest) -replace '-', '').ToLowerInvariant()
    }
}

function Get-ContainedPath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $safe = Assert-SafeRelativePath $RelativePath $Name
    $rootPath = [IO.Path]::GetFullPath($Root)
    $prefix = $rootPath.TrimEnd([char[]]'\/') + [IO.Path]::DirectorySeparatorChar
    $native = $safe.Replace('/', [IO.Path]::DirectorySeparatorChar)
    $candidate = [IO.Path]::GetFullPath((Join-Path $rootPath $native))
    if (-not $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Name escapes its mapped root."
    }
    $current = $rootPath
    foreach ($component in $safe.Split('/')) {
        $current = Join-Path $current $component
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($null -eq $item) {
            break
        }
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Name traverses reparse point '$component'."
        }
    }
    return $candidate
}

function Get-BigEndianBytes {
    param(
        [Parameter(Mandatory = $true)][UInt64]$Value,
        [Parameter(Mandatory = $true)][ValidateSet(4, 8)][int]$Width
    )

    $bytes = [byte[]]::new($Width)
    for ($index = $Width - 1; $index -ge 0; $index--) {
        $bytes[$index] = [byte]($Value -band 0xff)
        $Value = $Value -shr 8
    }
    return $bytes
}

function Get-PortableTreeRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $relative = [IO.Path]::GetRelativePath($Root, $Path).Replace('\', '/')
    if ($relative -eq '..' -or $relative.StartsWith('../', [StringComparison]::Ordinal)) {
        throw "Tree entry escapes its root: $Path"
    }
    [void](Assert-SafeRelativePath $relative 'tree entry')
    return $relative
}

function Get-TreeDescriptor {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][object]$Expected,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $rootItem = Get-Item -LiteralPath $Root -Force -ErrorAction Stop
    if (($rootItem.Attributes -band [IO.FileAttributes]::Directory) -eq 0 -or
        ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        ($rootItem.Attributes -band [IO.FileAttributes]::Device) -ne 0) {
        throw "$Name must be one ordinary directory."
    }
    [UInt64]$fileLimit = Assert-UnsignedInteger $Expected.file_count "$Name.file_count" 1024
    [UInt64]$directoryLimit = Assert-UnsignedInteger $Expected.directory_count "$Name.directory_count" 128
    [UInt64]$entryLimit = Assert-UnsignedInteger $Expected.total_entries "$Name.total_entries" 1152
    [UInt64]$byteLimit = Assert-UnsignedInteger $Expected.aggregate_bytes "$Name.aggregate_bytes" 67108864
    [UInt64]$fileByteLimit = Assert-UnsignedInteger $Expected.maximum_file_bytes "$Name.maximum_file_bytes" 16777216
    [UInt64]$pathLimit = Assert-UnsignedInteger $Expected.maximum_path_bytes "$Name.maximum_path_bytes" 512

    $records = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($rootItem.FullName)
    [UInt64]$fileCount = 0
    [UInt64]$directoryCount = 0
    [UInt64]$entryCount = 0
    [UInt64]$aggregateBytes = 0
    [UInt64]$maximumFileBytes = 0
    [UInt64]$maximumPathBytes = 0

    while ($pending.Count -ne 0) {
        $directory = $pending.Pop()
        foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($directory)) {
            $entryCount++
            if ($entryCount -gt $entryLimit) {
                throw "$Name exceeds its locked entry count."
            }
            $relative = Get-PortableTreeRelativePath $rootItem.FullName $entry
            [UInt64]$pathByteCount = $script:Utf8.GetByteCount($relative)
            if ($pathByteCount -gt $pathLimit) {
                throw "$Name path '$relative' exceeds its locked bound."
            }
            $maximumPathBytes = [Math]::Max($maximumPathBytes, $pathByteCount)
            $attributes = [IO.File]::GetAttributes($entry)
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "$Name contains reparse point '$relative'."
            }
            if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) {
                $directoryCount++
                if ($directoryCount -gt $directoryLimit) {
                    throw "$Name exceeds its locked directory count."
                }
                $pending.Push($entry)
                continue
            }
            if (($attributes -band [IO.FileAttributes]::Device) -ne 0) {
                throw "$Name contains a non-file entry '$relative'."
            }
            $fileCount++
            if ($fileCount -gt $fileLimit -or $records.ContainsKey($relative)) {
                throw "$Name exceeds or duplicates its locked file set."
            }
            $identity = Get-OrdinaryFileHash $entry "$Name file '$relative'" $fileByteLimit
            if ([UInt64]::MaxValue - $aggregateBytes -lt $identity.Bytes) {
                throw "$Name byte count overflowed."
            }
            $aggregateBytes += $identity.Bytes
            if ($aggregateBytes -gt $byteLimit) {
                throw "$Name exceeds its locked byte count."
            }
            $maximumFileBytes = [Math]::Max($maximumFileBytes, $identity.Bytes)
            $records.Add($relative, $identity)
        }
    }

    [string[]]$paths = @($records.Keys)
    [Array]::Sort($paths, [StringComparer]::Ordinal)
    $digest = [Security.Cryptography.IncrementalHash]::CreateHash(
        [Security.Cryptography.HashAlgorithmName]::SHA256
    )
    try {
        $digest.AppendData($script:Utf8.GetBytes("RETVRN99-WIN98-TREE-SHA256-V1`0"))
        $digest.AppendData((Get-BigEndianBytes $fileCount 8))
        $digest.AppendData((Get-BigEndianBytes $aggregateBytes 8))
        foreach ($relative in $paths) {
            $pathBytes = $script:Utf8.GetBytes($relative)
            $record = $records[$relative]
            $digest.AppendData((Get-BigEndianBytes ([UInt64]$pathBytes.Length) 4))
            $digest.AppendData($pathBytes)
            $digest.AppendData((Get-BigEndianBytes ([UInt64]$record.Bytes) 8))
            $digest.AppendData([Convert]::FromHexString($record.Sha256))
        }
        $treeHash = ([BitConverter]::ToString($digest.GetHashAndReset()) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $digest.Dispose()
    }

    return [pscustomobject]@{
        file_count = $fileCount
        directory_count = $directoryCount
        total_entries = $entryCount
        aggregate_bytes = $aggregateBytes
        maximum_file_bytes = $maximumFileBytes
        maximum_path_bytes = $maximumPathBytes
        digest_algorithm = 'retvrn99-file-tree-sha256-v1'
        sha256 = $treeHash
    }
}

function Assert-DescriptorMatch {
    param(
        [Parameter(Mandatory = $true)][object]$Observed,
        [Parameter(Mandatory = $true)][object]$Expected,
        [Parameter(Mandatory = $true)][string]$Name
    )

    foreach ($property in @(
        'file_count', 'directory_count', 'total_entries', 'aggregate_bytes',
        'maximum_file_bytes', 'maximum_path_bytes', 'digest_algorithm', 'sha256'
    )) {
        if ($Observed.$property -cne $Expected.$property) {
            throw "$Name $property mismatch."
        }
    }
}

function Read-ToolchainMetadata {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [scriptblock]$BeforePostReadCheck
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    try {
        $snapshot = Read-GswStrictJsonFileSnapshot -Path $fullPath `
            -Name 'vkd3d-shader toolchain lock' `
            -MaximumBytes $script:MaximumJsonBytes `
            -BeforePostReadCheck $BeforePostReadCheck
    }
    catch {
        $detail = Get-Vkd3dEvidenceSanitizedFailureText `
            $_.Exception @($fullPath, (Split-Path -Parent $fullPath))
        throw "Malformed vkd3d-shader toolchain lock JSON: $detail"
    }
    Assert-NoPrivatePathText $snapshot.Text 'vkd3d-shader toolchain lock'
    return [pscustomobject]@{
        Path = $fullPath
        Directory = Split-Path -Parent $fullPath
        Identity = [pscustomobject]@{
            Bytes = [UInt64]$snapshot.Length
            Sha256 = [string]$snapshot.Sha256
        }
        Lock = $snapshot.Value
    }
}

function Assert-StructuralContract {
    param(
        [Parameter(Mandatory = $true)][object]$Metadata,
        [scriptblock]$BeforeSchemaCheck
    )

    $lock = $Metadata.Lock
    Assert-ExactProperties $lock @(
        '_spdx', 'schema', 'schema_definition', 'name', 'status', 'reason',
        'roots', 'packages', 'files', 'trees', 'tool_probes', 'recipes',
        'environment', 'process_limits', 'host_dependencies', 'authorizations'
    ) 'toolchain lock'
    if ($lock._spdx -cne 'GPL-3.0-only' -or $lock.schema -cne 1 -or
        $lock.name -cne 'vkd3d-shader-host-tools-20260722' -or
        $lock.status -cne 'ready') {
        throw 'The vkd3d-shader toolchain lock identity is unsupported.'
    }
    [void](Assert-String $lock.reason 'reason')

    Assert-ExactProperties $lock.schema_definition @('relative_path', 'sha256') `
        'schema_definition'
    if ($lock.schema_definition.relative_path -cne
        'vkd3d-shader-toolchain-lock.schema.json') {
        throw 'The toolchain schema path is not canonical.'
    }
    Assert-Sha256 $lock.schema_definition.sha256 'schema_definition.sha256'
    $schemaPath = Get-ContainedPath $Metadata.Directory `
        $lock.schema_definition.relative_path 'schema definition'
    try {
        $schemaSnapshot = Read-GswStrictJsonFileSnapshot -Path $schemaPath `
            -Name 'vkd3d-shader toolchain schema' `
            -MaximumBytes $script:MaximumJsonBytes `
            -BeforePostReadCheck $BeforeSchemaCheck
    }
    catch {
        $detail = Get-Vkd3dEvidenceSanitizedFailureText `
            $_.Exception @($schemaPath, $Metadata.Directory)
        throw "Malformed vkd3d-shader toolchain schema JSON: $detail"
    }
    if ($schemaSnapshot.Sha256 -cne $lock.schema_definition.sha256 -or
        $schemaSnapshot.Sha256 -cne $script:ExpectedSchemaSha256) {
        throw 'The vkd3d-shader toolchain schema hash does not match.'
    }
    $schema = $schemaSnapshot.Value
    Assert-ExactProperties $schema @(
        '_spdx', '$schema', '$id', 'title', 'type', 'additionalProperties',
        'required', 'properties', '$defs'
    ) 'toolchain schema'

    $expectedRoots = @('msys', 'ucrt64', 'git', 'package_cache')
    if ($lock.roots -isnot [Array] -or @($lock.roots).Count -ne 4) {
        throw 'The toolchain lock must declare exactly four logical roots.'
    }
    for ($index = 0; $index -lt 4; $index++) {
        $root = $lock.roots[$index]
        Assert-ExactProperties $root @('id', 'purpose', 'required_live') "root[$index]"
        if ($root.id -cne $expectedRoots[$index] -or $root.required_live -isnot [bool] -or
            -not $root.required_live) {
            throw 'The logical root contract is not exact.'
        }
        [void](Assert-String $root.purpose "root[$index].purpose" 128)
    }

    if ($lock.packages -isnot [Array] -or @($lock.packages).Count -ne 30) {
        throw 'The toolchain lock must declare exactly 30 package identities.'
    }
    $packageKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $archiveNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $archiveCount = 0
    foreach ($package in @($lock.packages)) {
        Assert-ExactProperties $package @('root', 'name', 'version', 'architecture', 'archive') `
            "package '$($package.name)'"
        if (@('msys', 'ucrt64', 'git') -cnotcontains $package.root -or
            @('x86_64', 'any') -cnotcontains $package.architecture) {
            throw "Package '$($package.name)' has invalid root or architecture."
        }
        $name = Assert-String $package.name 'package name' 96
        [void](Assert-String $package.version "package '$name' version" 96)
        if (-not $packageKeys.Add("$($package.root):$name")) {
            throw "Duplicate package identity '$($package.root):$name'."
        }
        Assert-ExactProperties $package.archive @('present', 'relative_path', 'bytes', 'sha256') `
            "package '$name' archive"
        if ($package.archive.present -isnot [bool]) {
            throw "Package '$name' archive presence must be Boolean."
        }
        if ($package.archive.present) {
            $archiveCount++
            $archiveName = Assert-SafeRelativePath $package.archive.relative_path `
                "package '$name' archive" -RequireLeaf
            if (-not $archiveNames.Add($archiveName)) {
                throw "Duplicate package archive '$archiveName'."
            }
            [void](Assert-UnsignedInteger $package.archive.bytes `
                "package '$name' archive bytes" 67108864)
            Assert-Sha256 $package.archive.sha256 "package '$name' archive sha256"
        }
        elseif ($package.archive.relative_path -cne '' -or
            $package.archive.bytes -cne 0 -or $package.archive.sha256 -cne '') {
            throw "Package '$name' absent archive metadata is malformed."
        }
    }
    if ($archiveCount -ne 16) {
        throw 'The toolchain lock must declare exactly 16 cached archives.'
    }

    if ($lock.files -isnot [Array] -or @($lock.files).Count -ne 50) {
        throw 'The toolchain lock must declare exactly 50 files.'
    }
    $fileIds = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $filePaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in @($lock.files)) {
        Assert-ExactProperties $file @('id', 'root', 'relative_path', 'role', 'bytes', 'sha256') `
            "file '$($file.id)'"
        $id = Assert-String $file.id 'file id' 96
        if ($id -cnotmatch '^[a-z0-9][a-z0-9._-]*$' -or $fileIds.ContainsKey($id)) {
            throw "Invalid or duplicate file id '$id'."
        }
        if (@('msys', 'ucrt64', 'git') -cnotcontains $file.root -or
            @('executable', 'runtime-library', 'module', 'package-metadata') -cnotcontains
                $file.role) {
            throw "File '$id' has invalid root or role."
        }
        $relative = Assert-SafeRelativePath $file.relative_path "file '$id' path"
        if (-not $filePaths.Add("$($file.root):$relative")) {
            throw "Duplicate locked file path '$($file.root):$relative'."
        }
        [UInt64]$bytes = Assert-UnsignedInteger $file.bytes "file '$id' bytes" 67108864
        if ($bytes -eq 0) {
            throw "File '$id' must not be empty."
        }
        Assert-Sha256 $file.sha256 "file '$id' sha256"
        $fileIds.Add($id, $file)
    }

    if ($lock.trees -isnot [Array] -or @($lock.trees).Count -ne 2) {
        throw 'The toolchain lock must declare exactly two tree closures.'
    }
    $treeIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($tree in @($lock.trees)) {
        Assert-ExactProperties $tree @('id', 'root', 'relative_path', 'role', 'descriptor') `
            "tree '$($tree.id)'"
        $id = Assert-String $tree.id 'tree id' 96
        if (-not $treeIds.Add($id) -or @('msys', 'ucrt64') -cnotcontains $tree.root -or
            @('bison-data', 'gcc-internal-headers') -cnotcontains $tree.role) {
            throw "Invalid or duplicate tree closure '$id'."
        }
        [void](Assert-SafeRelativePath $tree.relative_path "tree '$id' path")
        Assert-ExactProperties $tree.descriptor @(
            'file_count', 'directory_count', 'total_entries', 'aggregate_bytes',
            'maximum_file_bytes', 'maximum_path_bytes', 'digest_algorithm', 'sha256'
        ) "tree '$id' descriptor"
        if ($tree.descriptor.digest_algorithm -cne 'retvrn99-file-tree-sha256-v1') {
            throw "Tree '$id' uses an unsupported digest algorithm."
        }
        [void](Assert-UnsignedInteger $tree.descriptor.file_count "tree '$id' file_count" 1024)
        [void](Assert-UnsignedInteger $tree.descriptor.directory_count "tree '$id' directory_count" 128)
        [void](Assert-UnsignedInteger $tree.descriptor.total_entries "tree '$id' total_entries" 1152)
        [void](Assert-UnsignedInteger $tree.descriptor.aggregate_bytes "tree '$id' aggregate_bytes" 67108864)
        [void](Assert-UnsignedInteger $tree.descriptor.maximum_file_bytes "tree '$id' maximum_file_bytes" 16777216)
        [void](Assert-UnsignedInteger $tree.descriptor.maximum_path_bytes "tree '$id' maximum_path_bytes" 512)
        Assert-Sha256 $tree.descriptor.sha256 "tree '$id' sha256"
    }

    if ($lock.tool_probes -isnot [Array] -or @($lock.tool_probes).Count -ne 9) {
        throw 'The toolchain lock must declare exactly nine tool probes.'
    }
    $probeIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($probe in @($lock.tool_probes)) {
        Assert-ExactProperties $probe @(
            'id', 'file_id', 'arguments', 'expected_stream', 'expected_lines',
            'exit_code', 'timeout_ms', 'maximum_output_bytes'
        ) "probe '$($probe.id)'"
        $id = Assert-String $probe.id 'probe id' 96
        if (-not $probeIds.Add($id) -or -not $fileIds.ContainsKey($probe.file_id) -or
            $fileIds[$probe.file_id].role -cne 'executable') {
            throw "Probe '$id' does not reference one unique executable."
        }
        if ($probe.arguments -isnot [Array] -or @($probe.arguments).Count -lt 1 -or
            @($probe.arguments).Count -gt 8) {
            throw "Probe '$id' has invalid arguments."
        }
        foreach ($argument in @($probe.arguments)) {
            $argumentText = Assert-String $argument "probe '$id' argument" 256
            Assert-NoPrivatePathText $argumentText "probe '$id' argument"
        }
        if (@('stdout', 'stderr') -cnotcontains $probe.expected_stream -or
            $probe.expected_lines -isnot [Array] -or
            @($probe.expected_lines).Count -lt 1 -or @($probe.expected_lines).Count -gt 4) {
            throw "Probe '$id' has invalid expected output metadata."
        }
        foreach ($line in @($probe.expected_lines)) {
            [void](Assert-String $line "probe '$id' expected line" 256)
        }
        if ($probe.exit_code -cne 0) {
            throw "Probe '$id' must require exit code zero."
        }
        [UInt64]$timeout = Assert-UnsignedInteger $probe.timeout_ms "probe '$id' timeout" 10000
        [UInt64]$outputLimit = Assert-UnsignedInteger $probe.maximum_output_bytes `
            "probe '$id' output bound" 65536
        if ($timeout -lt 1000 -or $outputLimit -lt 256) {
            throw "Probe '$id' bounds are too small."
        }
    }

    if ($lock.recipes -isnot [Array] -or @($lock.recipes).Count -ne 6) {
        throw 'The toolchain lock must declare exactly six recipes.'
    }
    $recipeIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $allowedPlaceholders = @(
        'output_c', 'input_l', 'input_y', 'source_include', 'output_h',
        'input_idl', 'make_spirv', 'grammar', 'source_root', 'generated_root',
        'temporary_root', 'unit_sha256', 'depfile', 'object', 'input_c'
    )
    foreach ($recipe in @($lock.recipes)) {
        Assert-ExactProperties $recipe @(
            'id', 'tool_file_id', 'provenance', 'arguments', 'standard_output'
        ) "recipe '$($recipe.id)'"
        $id = Assert-String $recipe.id 'recipe id' 96
        if (-not $recipeIds.Add($id) -or -not $fileIds.ContainsKey($recipe.tool_file_id) -or
            $fileIds[$recipe.tool_file_id].role -cne 'executable') {
            throw "Recipe '$id' does not reference one unique executable."
        }
        if (@('upstream', 'closure-proof') -cnotcontains $recipe.provenance -or
            @('capture-as-output', 'capture-for-validation') -cnotcontains
                $recipe.standard_output -or $recipe.arguments -isnot [Array] -or
            @($recipe.arguments).Count -lt 1 -or @($recipe.arguments).Count -gt 48) {
            throw "Recipe '$id' has invalid execution metadata."
        }
        foreach ($argument in @($recipe.arguments)) {
            $argumentText = Assert-String $argument "recipe '$id' argument" 256
            Assert-NoPrivatePathText $argumentText "recipe '$id' argument"
            foreach ($match in [regex]::Matches($argumentText, '\{([^{}]+)\}')) {
                if ($allowedPlaceholders -cnotcontains $match.Groups[1].Value) {
                    throw "Recipe '$id' uses unknown placeholder '$($match.Groups[1].Value)'."
                }
            }
            $withoutPlaceholders = [regex]::Replace($argumentText, '\{[^{}]+\}', '')
            if ($withoutPlaceholders.Contains('{') -or $withoutPlaceholders.Contains('}')) {
                throw "Recipe '$id' contains malformed placeholders."
            }
        }
    }
    $compileRows = @($lock.recipes | Where-Object {
        $_.id -ceq 'compile-c-object'
    })
    if ($compileRows.Count -ne 1 -or
        $compileRows[0].provenance -cne 'closure-proof') {
        throw 'The compile-c-object recipe is not the exact proof-only no-LTO contract.'
    }
    $compileArguments = @($compileRows[0].arguments)
    if (@($compileArguments | Where-Object { $_ -ceq '-fno-lto' }).Count -ne 1 -or
        @($compileArguments | Where-Object {
            [string]$_ -match '^-flto(?:=|$)'
        }).Count -ne 0) {
        throw 'The compile-c-object recipe is not the exact proof-only no-LTO contract.'
    }

    Assert-ExactProperties $lock.environment @('inherit', 'clear', 'set', 'path_entries') `
        'environment'
    $expectedInherit = @('SystemRoot', 'WINDIR')
    $expectedPaths = @(
        'msys:usr/bin', 'ucrt64:bin', 'git:mingw64/bin', 'git:usr/bin',
        'host:System32'
    )
    foreach ($contract in @(
        [pscustomobject]@{ Value = $lock.environment.inherit; Expected = $expectedInherit; Name = 'environment.inherit' },
        [pscustomobject]@{ Value = $lock.environment.path_entries; Expected = $expectedPaths; Name = 'environment.path_entries' }
    )) {
        if ($contract.Value -isnot [Array] -or @($contract.Value).Count -ne $contract.Expected.Count) {
            throw "$($contract.Name) is not exact."
        }
        for ($index = 0; $index -lt $contract.Expected.Count; $index++) {
            if ($contract.Value[$index] -cne $contract.Expected[$index]) {
                throw "$($contract.Name) is not exact."
            }
        }
    }
    if ($lock.environment.clear -isnot [Array] -or @($lock.environment.clear).Count -lt 20 -or
        @($lock.environment.clear).Count -gt 64) {
        throw 'environment.clear is not bounded.'
    }
    $clearNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @($lock.environment.clear)) {
        if ($name -isnot [string] -or $name -cnotmatch '^[A-Z][A-Z0-9_]*$' -or
            -not $clearNames.Add($name)) {
            throw "Invalid or duplicate cleared environment variable '$name'."
        }
    }
    Assert-ExactProperties $lock.environment.set @(
        'LC_ALL', 'LANG', 'TZ', 'SOURCE_DATE_EPOCH', 'PERL_JSON_BACKEND'
    ) 'environment.set'
    $expectedSet = [ordered]@{
        LC_ALL = 'C'; LANG = 'C'; TZ = 'UTC'; SOURCE_DATE_EPOCH = '0';
        PERL_JSON_BACKEND = 'JSON::PP'
    }
    foreach ($name in $expectedSet.Keys) {
        if ($lock.environment.set.$name -cne $expectedSet[$name]) {
            throw "environment.set.$name is not exact."
        }
    }

    Assert-ExactProperties $lock.process_limits @(
        'no_shell', 'maximum_top_level_processes', 'maximum_process_tree_width',
        'timeout_seconds', 'termination_grace_seconds', 'maximum_stdout_bytes',
        'maximum_stderr_bytes', 'terminate_process_tree',
        'temporary_output_root_required', 'complete_cleanup_required'
    ) 'process_limits'
    if ($lock.process_limits.no_shell -cne $true -or
        $lock.process_limits.maximum_top_level_processes -cne 1 -or
        $lock.process_limits.maximum_process_tree_width -cne 5 -or
        $lock.process_limits.timeout_seconds -cne 30 -or
        $lock.process_limits.termination_grace_seconds -cne 5 -or
        $lock.process_limits.maximum_stdout_bytes -cne 1048576 -or
        $lock.process_limits.maximum_stderr_bytes -cne 1048576 -or
        $lock.process_limits.terminate_process_tree -cne $true -or
        $lock.process_limits.temporary_output_root_required -cne $true -or
        $lock.process_limits.complete_cleanup_required -cne $true) {
        throw 'The bounded process contract is not exact.'
    }

    Assert-ExactProperties $lock.host_dependencies @('system_dlls') 'host_dependencies'
    if ($lock.host_dependencies.system_dlls -isnot [Array] -or
        @($lock.host_dependencies.system_dlls).Count -ne 18) {
        throw 'The host system DLL contract is not exact.'
    }
    $dlls = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($dll in @($lock.host_dependencies.system_dlls)) {
        if ($dll -isnot [string] -or $dll -cnotmatch '^[A-Za-z0-9._-]+\.dll$' -or
            -not $dlls.Add($dll)) {
            throw "Invalid or duplicate host DLL '$dll'."
        }
    }

    $authorizationNames = @(
        'fetch', 'download', 'install_tools', 'link_production_binaries',
        'stage_payloads', 'activate', 'run_guest',
        'graphics_capability_advertisement'
    )
    Assert-ExactProperties $lock.authorizations $authorizationNames 'authorizations'
    foreach ($name in $authorizationNames) {
        if ($lock.authorizations.$name -isnot [bool] -or $lock.authorizations.$name) {
            throw "Authorization '$name' must remain false."
        }
    }

    if ($Metadata.Identity.Sha256 -cne $script:ExpectedLockSha256) {
        throw 'The vkd3d-shader toolchain lock violates its immutable semantic contract.'
    }

    return [pscustomobject]@{
        SchemaPath = $schemaPath
        FileById = $fileIds
        CachedArchiveCount = $archiveCount
    }
}

function Resolve-RootMap {
    param([Parameter(Mandatory = $true)][hashtable]$Mappings)

    $expected = @('msys', 'ucrt64', 'git', 'package_cache')
    if ($Mappings.Count -ne $expected.Count) {
        throw 'Live verification requires exactly four root mappings.'
    }
    $resolved = @{}
    foreach ($key in $Mappings.Keys) {
        if ($key -isnot [string] -or $expected -cnotcontains $key) {
            throw "Unknown live root mapping '$key'."
        }
    }
    foreach ($id in $expected) {
        if (-not $Mappings.ContainsKey($id) -or $Mappings[$id] -isnot [string] -or
            [string]::IsNullOrWhiteSpace($Mappings[$id])) {
            throw "Missing live root mapping '$id'."
        }
        $path = [IO.Path]::GetFullPath([string]$Mappings[$id])
        Assert-GswNoReparseAncestor $path "live root '$id'"
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::Directory) -eq 0 -or
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            ($item.Attributes -band [IO.FileAttributes]::Device) -ne 0) {
            throw "Live root '$id' must be one ordinary directory."
        }
        $resolved[$id] = $item.FullName
    }
    return $resolved
}

function Open-LiveProbeFileLocks {
    param(
        [Parameter(Mandatory = $true)][object]$Lock,
        [Parameter(Mandatory = $true)][hashtable]$Roots
    )

    if (-not [OperatingSystem]::IsWindows()) {
        throw 'Live toolchain file locking requires Windows.'
    }
    $locks = @{}
    try {
        foreach ($file in @($Lock.files | Where-Object {
            @('executable', 'runtime-library', 'module') -ccontains $_.role
        })) {
            $path = Get-ContainedPath $Roots[$file.root] $file.relative_path `
                "locked file '$($file.id)'"
            $handle = Open-Vkd3dEvidenceStableHandle $path `
                "locked file '$($file.id)'"
            $identity = Get-Vkd3dEvidenceHandleIdentity $handle `
                "locked file '$($file.id)'" 67108864
            if ($identity.bytes -cne $file.bytes -or
                $identity.sha256 -cne $file.sha256) {
                $handle.Dispose()
                throw "Locked file '$($file.id)' identity mismatch."
            }
            $locks[$file.id] = [pscustomobject]@{
                Path = $path
                Handle = $handle
                FileIdentity = $identity.file_identity
                ExpectedBytes = [UInt64]$file.bytes
                ExpectedSha256 = [string]$file.sha256
            }
        }
        return $locks
    }
    catch {
        foreach ($record in @($locks.Values)) {
            if (-not $record.Handle.IsClosed) { $record.Handle.Dispose() }
        }
        $privateRoots = @($Roots.Values | ForEach-Object { [string]$_ })
        $detail = Get-Vkd3dEvidenceSanitizedFailureText `
            $_.Exception $privateRoots
        throw "Live toolchain files could not be locked: $detail"
    }
}

function Assert-LiveProbeFileLock {
    param(
        [Parameter(Mandatory = $true)][object]$Record,
        [Parameter(Mandatory = $true)][string]$Name,
        [object]$FreshExpected
    )

    $identity = Get-Vkd3dEvidenceHandleIdentity $Record.Handle $Name 67108864
    if ($identity.file_identity -cne $Record.FileIdentity -or
        $identity.bytes -cne $Record.ExpectedBytes -or
        $identity.sha256 -cne $Record.ExpectedSha256) {
        throw "$Name changed while its stability lock was held."
    }
    if ($null -ne $FreshExpected -and
        ([UInt64]$FreshExpected.bytes -cne $Record.ExpectedBytes -or
        [string]$FreshExpected.sha256 -cne $Record.ExpectedSha256)) {
        throw "$Name fresh metadata differs from its locked expectation."
    }
    $pathHandle = Open-Vkd3dEvidenceStableHandle $Record.Path "$Name path"
    try {
        $pathIdentity = Get-Vkd3dEvidenceHandleIdentity $pathHandle `
            "$Name path" 67108864
        if ($pathIdentity.file_identity -cne $Record.FileIdentity -or
            $pathIdentity.bytes -cne $Record.ExpectedBytes -or
            $pathIdentity.sha256 -cne $Record.ExpectedSha256) {
            throw "$Name path no longer resolves to its locked file."
        }
    }
    finally { $pathHandle.Dispose() }
}

function Close-LiveProbeFileLocks {
    param([hashtable]$Locks)

    if ($null -eq $Locks) { return }
    foreach ($record in @($Locks.Values)) {
        if ($null -ne $record.Handle -and -not $record.Handle.IsClosed) {
            $record.Handle.Dispose()
        }
    }
}

function Assert-LiveSnapshot {
    param(
        [Parameter(Mandatory = $true)][object]$Lock,
        [Parameter(Mandatory = $true)][hashtable]$Roots,
        [hashtable]$LockedFiles
    )

    foreach ($file in @($Lock.files)) {
        if ($null -ne $LockedFiles -and $LockedFiles.ContainsKey($file.id)) {
            Assert-LiveProbeFileLock $LockedFiles[$file.id] `
                "locked file '$($file.id)'" $file
        }
        else {
            $path = Get-ContainedPath $Roots[$file.root] $file.relative_path `
                "locked file '$($file.id)'"
            $identity = Get-OrdinaryFileHash $path `
                "locked file '$($file.id)'" 67108864
            if ($identity.Bytes -cne $file.bytes -or
                $identity.Sha256 -cne $file.sha256) {
                throw "Locked file '$($file.id)' identity mismatch."
            }
        }
    }
    foreach ($package in @($Lock.packages | Where-Object { $_.archive.present })) {
        $path = Get-ContainedPath $Roots.package_cache $package.archive.relative_path `
            "package '$($package.name)' archive"
        $identity = Get-OrdinaryFileHash $path "package '$($package.name)' archive" 67108864
        if ($identity.Bytes -cne $package.archive.bytes -or
            $identity.Sha256 -cne $package.archive.sha256) {
            throw "Package '$($package.name)' archive identity mismatch."
        }
    }
    foreach ($tree in @($Lock.trees)) {
        $path = Get-ContainedPath $Roots[$tree.root] $tree.relative_path `
            "tree '$($tree.id)'"
        $observed = Get-TreeDescriptor $path $tree.descriptor "tree '$($tree.id)'"
        Assert-DescriptorMatch $observed $tree.descriptor "Tree '$($tree.id)'"
    }
}

function Invoke-BoundedProbe {
    param(
        [Parameter(Mandatory = $true)][object]$Probe,
        [Parameter(Mandatory = $true)][object]$Executable,
        [Parameter(Mandatory = $true)][hashtable]$Roots,
        [Parameter(Mandatory = $true)][object]$Environment,
        [Parameter(Mandatory = $true)][string]$PrivateTemp,
        [Parameter(Mandatory = $true)][ref]$ChildCount,
        [Parameter(Mandatory = $true)][hashtable]$LockedFiles
    )

    $executablePath = Get-ContainedPath $Roots[$Executable.root] `
        $Executable.relative_path "probe '$($Probe.id)' executable"
    $pathDirectories = @(
        (Join-Path $Roots.msys 'usr\bin'),
        (Join-Path $Roots.ucrt64 'bin'),
        (Join-Path $Roots.git 'mingw64\bin'),
        (Join-Path $Roots.git 'usr\bin')
    )
    foreach ($property in $Environment.set.PSObject.Properties) {
        if (@('LC_ALL', 'LANG', 'TZ', 'SOURCE_DATE_EPOCH',
                'PERL_JSON_BACKEND') -cnotcontains $property.Name) {
            throw "Probe '$($Probe.id)' has an unsupported environment value."
        }
    }
    if (-not $LockedFiles.ContainsKey($Executable.id)) {
        throw "Probe '$($Probe.id)' executable has no stability lock."
    }
    $lockedExecutable = $LockedFiles[$Executable.id]
    Assert-LiveProbeFileLock $lockedExecutable `
        "probe '$($Probe.id)' executable" $Executable
    $result = Invoke-Vkd3dEvidenceProcess -File $executablePath `
        -Arguments @($Probe.arguments) `
        -WorkingDirectory $Roots[$Executable.root] `
        -PathDirectories $pathDirectories -PrivateTemp $PrivateTemp `
        -Name "Probe '$($Probe.id)'" -ChildCount $ChildCount `
        -PinnedExecutableHandle $lockedExecutable.Handle `
        -TimeoutSeconds ([Math]::Ceiling([int]$Probe.timeout_ms / 1000)) `
        -MaximumOutputBytes ([int]$Probe.maximum_output_bytes)
    Assert-LiveProbeFileLock $lockedExecutable `
        "probe '$($Probe.id)' executable" $Executable
    if ([UInt64]$result.exit_code -ne [UInt64]$Probe.exit_code) {
        throw "Probe '$($Probe.id)' exited with an unexpected code."
    }
    [byte[]]$selectedBytes = @()
    [byte[]]$otherBytes = @()
    if ($Probe.expected_stream -ceq 'stdout') {
        $selectedBytes = [byte[]]@($result.stdout)
        $otherBytes = [byte[]]@($result.stderr)
    }
    else {
        $selectedBytes = [byte[]]@($result.stderr)
        $otherBytes = [byte[]]@($result.stdout)
    }
    if ($otherBytes.Length -ne 0) {
        throw "Probe '$($Probe.id)' wrote unexpected output to the other stream."
    }
    try { $selected = $script:Utf8.GetString($selectedBytes) }
    catch { throw "Probe '$($Probe.id)' output is not strict UTF-8." }
    $normalized = $selected.Replace("`r`n", "`n").Replace("`r", "`n").TrimEnd("`n")
    [string[]]$lines = if ($normalized.Length -eq 0) {
        @()
    }
    else {
        @($normalized.Split("`n"))
    }
    [string[]]$expectedLines = @($Probe.expected_lines)
    if ($lines.Count -lt $expectedLines.Count) {
        throw "Probe '$($Probe.id)' output is incomplete."
    }
    for ($index = 0; $index -lt $expectedLines.Count; $index++) {
        if ($lines[$index] -cne $expectedLines[$index]) {
            throw "Probe '$($Probe.id)' output mismatch."
        }
    }
}

function New-Win98Vkd3dShaderToolchainInternalFaultModel {
    [CmdletBinding()]
    param(
        [scriptblock]$BeforeFinalCheck,
        [scriptblock]$BeforeLockPostReadCheck,
        [scriptblock]$BeforeSchemaPostReadCheck,
        [scriptblock]$BeforeFirstProbe,
        [ValidateSet('none', 'race-owned-cleanup')]
        [string]$CleanupMutation = 'none'
    )

    return [pscustomobject][ordered]@{
        before_final_check = $BeforeFinalCheck
        before_lock_post_read_check = $BeforeLockPostReadCheck
        before_schema_post_read_check = $BeforeSchemaPostReadCheck
        before_first_probe = $BeforeFirstProbe
        cleanup_mutation = $CleanupMutation
    }
}

function Invoke-Win98Vkd3dShaderToolchainInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LockFile,
        [switch]$MetadataOnly,
        [hashtable]$RootMappings,
        [object]$InternalFaultModel
    )

    $BeforeFinalCheck = $null
    $BeforeLockPostReadCheck = $null
    $BeforeSchemaPostReadCheck = $null
    $BeforeFirstProbe = $null
    $CleanupMutation = 'none'
    if ($null -ne $InternalFaultModel) {
        $faultProperties = @(
            'before_final_check',
            'before_lock_post_read_check',
            'before_schema_post_read_check',
            'before_first_probe',
            'cleanup_mutation'
        )
        Assert-ExactProperties $InternalFaultModel $faultProperties `
            'internal verifier fault model'
        foreach ($property in @(
            'before_final_check',
            'before_lock_post_read_check',
            'before_schema_post_read_check',
            'before_first_probe'
        )) {
            $value = $InternalFaultModel.$property
            if ($null -ne $value -and $value -isnot [scriptblock]) {
                throw "Internal verifier fault '$property' is malformed."
            }
        }
        $cleanupValue = $InternalFaultModel.cleanup_mutation
        if ($cleanupValue -isnot [string] -or
            @('none', 'race-owned-cleanup') -cnotcontains $cleanupValue) {
            throw 'Internal verifier cleanup fault is malformed.'
        }
        $BeforeFinalCheck = $InternalFaultModel.before_final_check
        $BeforeLockPostReadCheck =
            $InternalFaultModel.before_lock_post_read_check
        $BeforeSchemaPostReadCheck =
            $InternalFaultModel.before_schema_post_read_check
        $BeforeFirstProbe = $InternalFaultModel.before_first_probe
        $CleanupMutation = $cleanupValue
    }

$metadataMode = [bool]$MetadataOnly
$hasRoots = $null -ne $RootMappings
if ($metadataMode -eq $hasRoots) {
    throw 'Choose exactly one of -MetadataOnly or -RootMappings.'
}

$metadata = Read-ToolchainMetadata $LockFile $BeforeLockPostReadCheck
$contract = Assert-StructuralContract $metadata $BeforeSchemaPostReadCheck
$resolvedRoots = $null
if ($hasRoots) {
    try { $resolvedRoots = Resolve-RootMap $RootMappings }
    catch {
        $privateRoots = @($RootMappings.Values | ForEach-Object { [string]$_ })
        $detail = Get-Vkd3dEvidenceSanitizedFailureText `
            $_.Exception $privateRoots
        throw "Live root mapping is unavailable or unsafe: $detail"
    }
    $lockedFiles = $null
    try {
        $lockedFiles = Open-LiveProbeFileLocks $metadata.Lock $resolvedRoots
        try {
            Assert-LiveSnapshot $metadata.Lock $resolvedRoots $lockedFiles
        }
        catch {
            $privateRoots = @($resolvedRoots.Values | ForEach-Object {
                [string]$_
            })
            $detail = Get-Vkd3dEvidenceSanitizedFailureText `
                $_.Exception $privateRoots
            throw "Initial live toolchain snapshot failed: $detail"
        }
    $tempParent = [IO.Path]::GetFullPath(
        [IO.Path]::GetTempPath()
    ).TrimEnd([char[]]'\/')
    try {
        Assert-GswNoReparseAncestor $tempParent 'tool-probe temporary parent'
        Assert-Vkd3dEvidenceDirectory $tempParent `
            'tool-probe temporary parent'
    }
    catch {
        $detail = Get-Vkd3dEvidenceSanitizedFailureText `
            $_.Exception @($tempParent)
        throw "Tool-probe temporary parent is unavailable: $detail"
    }
    $probeTemp = Join-Path $tempParent (
        'retvrn99-vkd3d-tool-probe-{0}' -f [Guid]::NewGuid().ToString('N')
    )
    if ([IO.Directory]::Exists($probeTemp) -or [IO.File]::Exists($probeTemp)) {
        throw 'Tool-probe temporary root must be fresh and absent.'
    }
    $childCount = 0
    $ownedDirectory = $null
    $primaryFailure = $null
    try {
        Assert-Vkd3dEvidenceFreshMutationBoundary `
            $tempParent @($probeTemp) `
            'tool-probe temporary root mutation boundary'
        $ownedDirectory = New-Vkd3dEvidenceOwnedDirectory $probeTemp `
            'tool-probe temporary root'
        if ($null -ne $BeforeFirstProbe) {
            & $BeforeFirstProbe $probeTemp | Out-Null
        }
        foreach ($probe in @($metadata.Lock.tool_probes)) {
            Invoke-BoundedProbe $probe $contract.FileById[$probe.file_id] `
                $resolvedRoots $metadata.Lock.environment $probeTemp `
                ([ref]$childCount) $lockedFiles
        }
        if ($null -ne $BeforeFinalCheck) {
            & $BeforeFinalCheck $probeTemp | Out-Null
        }
    }
    catch {
        $privateRoots = @(
            $metadata.Path, $tempParent, $probeTemp
        ) + @($resolvedRoots.Values | ForEach-Object { [string]$_ })
        $detail = Get-Vkd3dEvidenceSanitizedFailureText `
            $_.Exception $privateRoots
        $primaryFailure = [InvalidOperationException]::new($detail)
        throw $primaryFailure
    }
    finally {
        $cleanupFailures = [Collections.Generic.List[Exception]]::new()
        if ($null -ne $ownedDirectory) {
            $cleanupRacePath = Join-Path $probeTemp `
                '.retvrn99-vkd3d-cleanup-race'
            [byte[]]$cleanupRaceBytes = $script:Utf8.GetBytes(
                'synthetic-cleanup-race'
            )
            $cleanupHook = if ($CleanupMutation -ceq
                    'race-owned-cleanup') {
                {
                    param([string]$root)
                    $stream = [IO.File]::Open(
                        $cleanupRacePath,
                        [IO.FileMode]::CreateNew,
                        [IO.FileAccess]::Write,
                        [IO.FileShare]::None
                    )
                    try {
                        $stream.Write(
                            $cleanupRaceBytes, 0, $cleanupRaceBytes.Length
                        )
                        $stream.Flush($true)
                    }
                    finally { $stream.Dispose() }
                }.GetNewClosure()
            }
            else { $null }
            try {
                Remove-Vkd3dEvidenceOwnedTree $probeTemp `
                    $ownedDirectory.OwnerToken `
                    -RootHandle $ownedDirectory.RootHandle `
                    -OwnerMarkerHandle $ownedDirectory.OwnerMarkerHandle `
                    -BeforeDelete $cleanupHook
            }
            catch {
                $cleanupFailures.Add($_.Exception)
                if ($CleanupMutation -ceq 'race-owned-cleanup') {
                    $recoveryRoot = $null
                    $recoveryMarker = $null
                    try {
                        Remove-Vkd3dEvidenceOwnedLeaf $probeTemp `
                            $cleanupRacePath 'synthetic cleanup race' `
                            -ExpectedBytes $cleanupRaceBytes.Length `
                            -ExpectedSha256 (
                                Get-Vkd3dEvidenceSha256 $cleanupRaceBytes
                            )
                        $recoveryRoot = Open-Vkd3dEvidenceDeleteHandle `
                            $probeTemp 'cleanup recovery root'
                        $recoveryMarker = Open-Vkd3dEvidenceDeleteHandle `
                            (Join-Path $probeTemp `
                                '.retvrn99-vkd3d-proof-owner') `
                            'cleanup recovery marker'
                        Remove-Vkd3dEvidenceOwnedTree $probeTemp `
                            $ownedDirectory.OwnerToken `
                            -RootHandle $recoveryRoot `
                            -OwnerMarkerHandle $recoveryMarker
                    }
                    catch { $cleanupFailures.Add($_.Exception) }
                    finally {
                        if ($null -ne $recoveryMarker -and
                            -not $recoveryMarker.IsClosed) {
                            $recoveryMarker.Dispose()
                        }
                        if ($null -ne $recoveryRoot -and
                            -not $recoveryRoot.IsClosed) {
                            $recoveryRoot.Dispose()
                        }
                    }
                }
            }
            finally { $ownedDirectory = $null }
        }
        if ($cleanupFailures.Count -gt 0) {
            $cleanupPrivateRoots = @(
                $metadata.Path, $tempParent, $probeTemp
            ) + @($resolvedRoots.Values | ForEach-Object { [string]$_ })
            if ($null -ne $primaryFailure) {
                $combinedFailure = New-Vkd3dEvidenceCombinedFailure `
                    $primaryFailure `
                    ([Exception[]]$cleanupFailures.ToArray()) `
                    $cleanupPrivateRoots
                throw $combinedFailure
            }
            $cleanupFailure = New-Vkd3dEvidenceCleanupFailure `
                ([Exception[]]$cleanupFailures.ToArray()) `
                $cleanupPrivateRoots
            throw $cleanupFailure
        }
    }
        $finalMetadata = Read-ToolchainMetadata $metadata.Path
        [void](Assert-StructuralContract $finalMetadata)
        try {
            Assert-LiveSnapshot $finalMetadata.Lock $resolvedRoots $lockedFiles
        }
        catch {
            $privateRoots = @($resolvedRoots.Values | ForEach-Object {
                [string]$_
            })
            $detail = Get-Vkd3dEvidenceSanitizedFailureText `
                $_.Exception $privateRoots
            throw "Final live toolchain snapshot failed: $detail"
        }
    }
    finally { Close-LiveProbeFileLocks $lockedFiles }
}

if (-not $hasRoots -and $null -ne $BeforeFinalCheck) {
    & $BeforeFinalCheck | Out-Null
}

if (-not $hasRoots) {
    $finalMetadata = Read-ToolchainMetadata $metadata.Path
    [void](Assert-StructuralContract $finalMetadata)
}

[pscustomobject]@{
    status = 'ready'
    mode = if ($metadataMode) { 'metadata-only' } else { 'live' }
    packages = 30
    cached_archives = $contract.CachedArchiveCount
    files = 50
    trees = 2
    probes = if ($metadataMode) { 0 } else { 9 }
    activation_authorized = $false
    capability_advertisement_authorized = $false
}
}

if ($MyInvocation.InvocationName -cne '.') {
    Invoke-Win98Vkd3dShaderToolchainInternal -LockFile $LockFile `
        -MetadataOnly:$MetadataOnly -RootMappings $RootMappings
}
