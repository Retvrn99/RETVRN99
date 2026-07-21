# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [string]$EvidenceFile,
    [string]$LfGeneratedRoot,
    [string]$CrlfGeneratedRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'strict-json.ps1')

$script:MaximumJsonBytes = [UInt64]1048576
$script:MaximumFileBytes = [UInt64]33554432
$script:MaximumAggregateBytes = [UInt64]67108864
$script:MaximumEntries = 135
$script:MaximumDirectories = 64
$script:ExpectedSchemaSha256 = `
    '714ad34a83cfe5de7de4e633c9391b36f3d4cdddd6ddf4e3db304545f44ebce0'
$script:ExpectedRepository = 'https://github.com/JHRobotics/mesa9x.git'
$script:ExpectedCommit = '29b9adb44bc5ea54dc53c02b5e4b49292c6cc04f'
$script:ExpectedPlanSha256 = `
    '7d08ea089889105443935fb48a59a69698e5c0cac9f5f87ff02c8710c2a5718c'
$script:ExpectedPlanSchemaSha256 = `
    'adc69c44e1ebd9e465f667ef42a605451c05a601c4db59bdd2652cf7709cec97'
$script:ExpectedRecipeBlob = '68b2fd13d08ae0ce4276cb1f720ee9bbb1cd54e9'
$script:ExpectedRecipeSha256 = `
    '9ad77b1fe55e4097621dbefeffe989fb00f3c354320ce6521d69f8efd8a44dce'
$script:ExpectedSeedSha256 = `
    'b7a18f8bfe4bfe5fac1ef8b4f36105d585e7d69349766d865c8c79a180d79dd8'
$script:ExpectedTreeSha256 = `
    'dd0ae888829eabf2a0043f27100aa64c57b43ad12054270bee62f50ccc451d84'
$script:ExpectedSideOutputPaths = @(
    'mesa-23.1.x/src/compiler/glsl/glcpp/glcpp-parse.h',
    'mesa-23.1.x/src/compiler/glsl/glsl_parser.h',
    'mesa-23.1.x/src/gallium/auxiliary/driver_trace/tr_util.h',
    'mesa-23.1.x/src/mesa/program/program_parse.tab.h'
)
$script:Utf8 = [Text.UTF8Encoding]::new($false, $true)

if ([string]::IsNullOrWhiteSpace($EvidenceFile)) {
    $EvidenceFile = Join-Path $PSScriptRoot `
        '..\drivers\win98\mesa-generated-source-reproducibility.json'
}

function Get-FullPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }
    return [IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

function Assert-ExactProperties {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string[]]$Expected,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Value -or $Value -is [string] -or $Value -is [Array] -or
        $Value.GetType().IsValueType) {
        throw "$Name must be a JSON object."
    }
    $actual = @($Value.PSObject.Properties.Name)
    if ($actual.Count -ne $Expected.Count) {
        throw "$Name fields do not match the canonical evidence."
    }
    foreach ($nameValue in $Expected) {
        if ($actual -cnotcontains $nameValue) {
            throw "$Name fields do not match the canonical evidence."
        }
    }
}

function Assert-StringValue {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Value -isnot [string] -or [string]$Value -cne $Expected) {
        throw "$Name must be '$Expected'."
    }
}

function Assert-BooleanValue {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][bool]$Expected,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Value -isnot [bool] -or [bool]$Value -ne $Expected) {
        throw "$Name must be the JSON boolean $($Expected.ToString().ToLowerInvariant())."
    }
}

function Assert-IntegerValue {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][UInt64]$Expected,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $integerTypes = @(
        [byte], [uint16], [uint32], [uint64],
        [sbyte], [int16], [int32], [int64]
    )
    if ($null -eq $Value -or $integerTypes -cnotcontains $Value.GetType() -or
        [UInt64]$Value -ne $Expected) {
        throw "$Name must be the JSON integer $Expected."
    }
}

function Assert-ArrayCount {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][int]$Expected,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Value -isnot [Array] -or $Value.Count -ne $Expected) {
        throw "$Name must be a $Expected-item JSON array."
    }
    return ,@($Value)
}

function Assert-StringSequence {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string[]]$Expected,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $items = Assert-ArrayCount $Value $Expected.Count $Name
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        Assert-StringValue $items[$index] $Expected[$index] "$Name[$index]"
    }
}

function Read-EvidenceJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    try {
        return Read-GswStrictJsonFileSnapshot -Path $Path -Name $Name `
            -MaximumBytes $script:MaximumJsonBytes
    }
    catch {
        throw "Malformed or unsafe ${Name}: $($_.Exception.Message)"
    }
}

function Resolve-SiblingFile {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or
        [IO.Path]::IsPathRooted($RelativePath) -or
        $RelativePath.IndexOfAny([char[]]'\/') -ge 0 -or
        $RelativePath -in @('.', '..') -or
        $RelativePath.IndexOf([char]0) -ge 0) {
        throw "$Name must name one sibling metadata file."
    }
    $fullPath = [IO.Path]::GetFullPath((Join-Path $Directory $RelativePath))
    if (-not (Split-Path -Parent $fullPath).Equals(
            [IO.Path]::GetFullPath($Directory),
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw "$Name escapes the evidence directory."
    }
    return $fullPath
}

function Assert-PinnedFile {
    param(
        [Parameter(Mandatory = $true)][object]$Declaration,
        [Parameter(Mandatory = $true)][string]$ExpectedPath,
        [Parameter(Mandatory = $true)][UInt64]$ExpectedBytes,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256,
        [Parameter(Mandatory = $true)][string]$EvidenceDirectory,
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$ParseJson
    )

    Assert-ExactProperties $Declaration @('relative_path', 'bytes', 'sha256') $Name
    Assert-StringValue $Declaration.relative_path $ExpectedPath "$Name.relative_path"
    Assert-IntegerValue $Declaration.bytes $ExpectedBytes "$Name.bytes"
    Assert-StringValue $Declaration.sha256 $ExpectedSha256 "$Name.sha256"
    $path = Resolve-SiblingFile $EvidenceDirectory $ExpectedPath "$Name.relative_path"
    if ($ParseJson) {
        $snapshot = Read-EvidenceJson $path $Name
    }
    else {
        $snapshot = Read-GswBoundedFileSnapshot -Path $path -Name $Name `
            -MaximumBytes $script:MaximumJsonBytes
    }
    if ($snapshot.Length -ne $ExpectedBytes -or
        $snapshot.Sha256 -cne $ExpectedSha256) {
        throw "$Name does not match its pinned byte identity."
    }
    return $snapshot
}

function Assert-Descriptor {
    param(
        [Parameter(Mandatory = $true)][object]$Descriptor,
        [Parameter(Mandatory = $true)][string]$Name
    )

    Assert-ExactProperties $Descriptor @(
        'file_count', 'directory_count', 'total_entries', 'aggregate_bytes',
        'maximum_file_bytes', 'maximum_path_bytes', 'digest_algorithm', 'sha256'
    ) $Name
    Assert-IntegerValue $Descriptor.file_count 67 "$Name.file_count"
    Assert-IntegerValue $Descriptor.directory_count 20 "$Name.directory_count"
    Assert-IntegerValue $Descriptor.total_entries 87 "$Name.total_entries"
    Assert-IntegerValue $Descriptor.aggregate_bytes 34876554 "$Name.aggregate_bytes"
    Assert-IntegerValue $Descriptor.maximum_file_bytes 20214289 `
        "$Name.maximum_file_bytes"
    Assert-IntegerValue $Descriptor.maximum_path_bytes 65 "$Name.maximum_path_bytes"
    Assert-StringValue $Descriptor.digest_algorithm `
        'retvrn99-file-tree-sha256-v1' "$Name.digest_algorithm"
    Assert-StringValue $Descriptor.sha256 $script:ExpectedTreeSha256 "$Name.sha256"
}

function Get-RunBindingSha256 {
    param(
        [Parameter(Mandatory = $true)][object]$Run,
        [Parameter(Mandatory = $true)][object]$Evidence
    )

    $autocrlf = ([bool]$Run.core_autocrlf).ToString().ToLowerInvariant()
    $fields = @(
        'RETVRN99-MESA-GENERATED-SOURCE-RUN-V1',
        [string]$Run.id,
        [string]$Run.source_mode,
        $autocrlf,
        [string]$Evidence.component.repository,
        [string]$Evidence.component.owning_commit,
        [string]$Evidence.inputs.generated_source_plan.sha256,
        [string]$Evidence.inputs.generated_source_plan_schema.sha256,
        [string]$Evidence.inputs.generator_recipe.git_blob,
        [string]$Evidence.inputs.generator_recipe.sha256,
        [string]$Evidence.inputs.source_seed.sha256,
        [string]$Run.descriptor.file_count,
        [string]$Run.descriptor.directory_count,
        [string]$Run.descriptor.total_entries,
        [string]$Run.descriptor.aggregate_bytes,
        [string]$Run.descriptor.maximum_file_bytes,
        [string]$Run.descriptor.maximum_path_bytes,
        [string]$Run.descriptor.digest_algorithm,
        [string]$Run.descriptor.sha256,
        [string]$Run.validation_side_output_count
    )
    return Get-GswSha256Hex $script:Utf8.GetBytes(($fields -join [char]0))
}

function Assert-Run {
    param(
        [Parameter(Mandatory = $true)][object]$Run,
        [Parameter(Mandatory = $true)][object]$Evidence,
        [Parameter(Mandatory = $true)][string]$ExpectedId,
        [Parameter(Mandatory = $true)][string]$ExpectedMode,
        [Parameter(Mandatory = $true)][bool]$ExpectedAutocrlf,
        [Parameter(Mandatory = $true)][string]$ExpectedBinding,
        [Parameter(Mandatory = $true)][string]$Name
    )

    Assert-ExactProperties $Run @(
        'id', 'source_mode', 'core_autocrlf', 'source_checkout_identity',
        'output_root_identity', 'normalization', 'descriptor',
        'validation_side_output_count', 'run_binding_sha256'
    ) $Name
    Assert-StringValue $Run.id $ExpectedId "$Name.id"
    Assert-StringValue $Run.source_mode $ExpectedMode "$Name.source_mode"
    Assert-BooleanValue $Run.core_autocrlf $ExpectedAutocrlf "$Name.core_autocrlf"
    Assert-StringValue $Run.source_checkout_identity 'independent-pinned-checkout' `
        "$Name.source_checkout_identity"
    Assert-StringValue $Run.output_root_identity 'external-content-addressed-root' `
        "$Name.output_root_identity"
    Assert-StringValue $Run.normalization 'strict-utf-8-no-bom-lf' `
        "$Name.normalization"
    Assert-Descriptor $Run.descriptor "$Name.descriptor"
    Assert-IntegerValue $Run.validation_side_output_count 0 `
        "$Name.validation_side_output_count"
    Assert-StringValue $Run.run_binding_sha256 $ExpectedBinding `
        "$Name.run_binding_sha256"
    $computed = Get-RunBindingSha256 $Run $Evidence
    if ($computed -cne $ExpectedBinding) {
        throw "$Name canonical run binding does not match its declared digest."
    }
}

function Assert-Scope {
    param([Parameter(Mandatory = $true)][object]$Scope)

    Assert-ExactProperties $Scope @('classification', 'claims', 'authorizations') `
        'scope'
    Assert-StringValue $Scope.classification `
        'normalized-generated-source-reproducibility-only' 'scope.classification'
    Assert-ExactProperties $Scope.claims @(
        'normalized_output_reproducibility', 'generator_execution',
        'generator_trust', 'package_trust', 'generated_output_lock',
        'file_license_closure', 'build_closure'
    ) 'scope.claims'
    Assert-BooleanValue $Scope.claims.normalized_output_reproducibility $true `
        'scope.claims.normalized_output_reproducibility'
    foreach ($property in @(
            'generator_execution', 'generator_trust', 'package_trust',
            'generated_output_lock', 'file_license_closure', 'build_closure'
        )) {
        Assert-BooleanValue $Scope.claims.$property $false "scope.claims.$property"
    }
    Assert-ExactProperties $Scope.authorizations @(
        'generator_execution', 'build', 'stage', 'guest_install',
        'dll_activation', 'capability_advertisement'
    ) 'scope.authorizations'
    foreach ($property in @(
            'generator_execution', 'build', 'stage', 'guest_install',
            'dll_activation', 'capability_advertisement'
        )) {
        Assert-BooleanValue $Scope.authorizations.$property $false `
            "scope.authorizations.$property"
    }
}

function Assert-SafeRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or
        [IO.Path]::IsPathRooted($RelativePath) -or
        $RelativePath.Contains('\') -or
        $RelativePath.IndexOf([char]0) -ge 0 -or
        $script:Utf8.GetByteCount($RelativePath) -gt 512) {
        throw "$Name contains an unsafe relative path."
    }
    $segments = $RelativePath.Split('/')
    foreach ($segment in $segments) {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment -in @('.', '..') -or
            $segment.EndsWith(' ', [StringComparison]::Ordinal) -or
            $segment.EndsWith('.', [StringComparison]::Ordinal) -or
            $segment.IndexOf(':') -ge 0) {
            throw "$Name contains an unsafe path segment."
        }
        foreach ($character in $segment.ToCharArray()) {
            if ([int]$character -lt 32) {
                throw "$Name contains a control character."
            }
        }
    }
}

function Get-BigEndianBytes {
    param([UInt64]$Value, [int]$Width)

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
    if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($bytes) }
    return ,$bytes
}

function Add-DigestBlock {
    param(
        [Parameter(Mandatory = $true)][Security.Cryptography.HashAlgorithm]$Digest,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes
    )

    [void]$Digest.TransformBlock($Bytes, 0, $Bytes.Length, $Bytes, 0)
}

function Get-TreeDescriptor {
    param([Parameter(Mandatory = $true)][object[]]$Records)

    $directories = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )
    [UInt64]$aggregateBytes = 0
    [UInt64]$maximumFileBytes = 0
    [UInt64]$maximumPathBytes = 0
    foreach ($record in $Records) {
        $aggregateBytes += [UInt64]$record.Bytes
        if ($aggregateBytes -gt $script:MaximumAggregateBytes) {
            throw 'Generated roots exceed the aggregate-byte bound.'
        }
        if ([UInt64]$record.Bytes -gt $maximumFileBytes) {
            $maximumFileBytes = [UInt64]$record.Bytes
        }
        $pathBytes = [UInt64]$script:Utf8.GetByteCount($record.RelativePath)
        if ($pathBytes -gt $maximumPathBytes) { $maximumPathBytes = $pathBytes }
        $directory = [IO.Path]::GetDirectoryName($record.RelativePath)
        while (-not [string]::IsNullOrWhiteSpace($directory)) {
            $directory = $directory.Replace('\', '/')
            [void]$directories.Add($directory)
            $directory = [IO.Path]::GetDirectoryName($directory)
        }
    }
    if ($directories.Count -gt $script:MaximumDirectories -or
        $directories.Count + $Records.Count -gt $script:MaximumEntries) {
        throw 'Generated root exceeds its entry bounds.'
    }

    [string[]]$paths = @($Records | ForEach-Object { $_.RelativePath })
    [Array]::Sort($paths, [StringComparer]::Ordinal)
    $byPath = [Collections.Generic.Dictionary[string,object]]::new(
        [StringComparer]::Ordinal
    )
    foreach ($record in $Records) { $byPath.Add($record.RelativePath, $record) }
    $digest = [Security.Cryptography.SHA256]::Create()
    try {
        Add-DigestBlock $digest $script:Utf8.GetBytes(
            "RETVRN99-WIN98-TREE-SHA256-V1`0"
        )
        Add-DigestBlock $digest (Get-BigEndianBytes ([UInt64]$paths.Count) 8)
        Add-DigestBlock $digest (Get-BigEndianBytes $aggregateBytes 8)
        foreach ($path in $paths) {
            $pathBytes = $script:Utf8.GetBytes($path)
            $record = $byPath[$path]
            Add-DigestBlock $digest (Get-BigEndianBytes ([UInt64]$pathBytes.Length) 4)
            Add-DigestBlock $digest $pathBytes
            Add-DigestBlock $digest (Get-BigEndianBytes ([UInt64]$record.Bytes) 8)
            Add-DigestBlock $digest ([byte[]]$record.Hash)
        }
        [void]$digest.TransformFinalBlock((New-Object byte[] 0), 0, 0)
        $treeHash = ([BitConverter]::ToString($digest.Hash) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $digest.Dispose()
    }
    return [pscustomobject]@{
        file_count = [UInt64]$Records.Count
        directory_count = [UInt64]$directories.Count
        total_entries = [UInt64]($Records.Count + $directories.Count)
        aggregate_bytes = $aggregateBytes
        maximum_file_bytes = $maximumFileBytes
        maximum_path_bytes = $maximumPathBytes
        digest_algorithm = 'retvrn99-file-tree-sha256-v1'
        sha256 = $treeHash
    }
}

function Get-GeneratedRootSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $rootPath = Get-FullPath $Root
    Assert-GswNoReparseAncestor $rootPath $Name
    $rootItem = Get-Item -LiteralPath $rootPath -Force -ErrorAction Stop
    if (($rootItem.Attributes -band [IO.FileAttributes]::Directory) -eq 0 -or
        ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        ($rootItem.Attributes -band [IO.FileAttributes]::Device) -ne 0) {
        throw "$Name must be one regular directory."
    }
    $rootPrefix = $rootPath.TrimEnd([char[]]'\/') +
        [IO.Path]::DirectorySeparatorChar
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($rootPath)
    $records = @()
    [UInt64]$entryCount = 0
    [UInt64]$directoryCount = 0
    $portablePaths = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    while ($pending.Count -ne 0) {
        $directory = $pending.Pop()
        foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($directory)) {
            $entryCount++
            if ($entryCount -gt $script:MaximumEntries) {
                throw "$Name exceeds its entry bound."
            }
            $fullPath = [IO.Path]::GetFullPath($entry)
            if (-not $fullPath.StartsWith(
                    $rootPrefix, [StringComparison]::OrdinalIgnoreCase
                )) {
                throw "$Name contains an entry outside its root."
            }
            $relativePath = $fullPath.Substring($rootPrefix.Length).Replace('\', '/')
            Assert-SafeRelativePath $relativePath $Name
            if (-not $portablePaths.Add($relativePath)) {
                throw "$Name contains a case-folded duplicate path."
            }
            $attributes = [IO.File]::GetAttributes($fullPath)
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                ($attributes -band [IO.FileAttributes]::Device) -ne 0) {
                throw "$Name contains a reparse point or device."
            }
            if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) {
                $directoryCount++
                if ($directoryCount -gt $script:MaximumDirectories) {
                    throw "$Name exceeds its directory bound."
                }
                $pending.Push($fullPath)
                continue
            }
            $snapshot = Read-GswBoundedFileSnapshot -Path $fullPath `
                -Name "$Name file '$relativePath'" `
                -MaximumBytes $script:MaximumFileBytes
            $text = ConvertFrom-GswStrictUtf8Bytes -Bytes $snapshot.Bytes `
                -Source "$Name file '$relativePath'"
            if ($text.IndexOf([char]0) -ge 0) {
                throw "$Name file '$relativePath' contains NUL."
            }
            if ($text.IndexOf([char]13) -ge 0) {
                throw "$Name file '$relativePath' is not normalized to LF."
            }
            $hashBytes = New-Object byte[] 32
            for ($index = 0; $index -lt $hashBytes.Length; $index++) {
                $hashBytes[$index] = [Convert]::ToByte(
                    $snapshot.Sha256.Substring($index * 2, 2), 16
                )
            }
            $records += [pscustomobject]@{
                RelativePath = $relativePath
                Bytes = [UInt64]$snapshot.Length
                Hash = [byte[]]$hashBytes
                Sha256 = [string]$snapshot.Sha256
            }
        }
    }
    if ($directoryCount -ne 20 -or $entryCount -ne 87 -or $records.Count -ne 67) {
        throw "$Name entry counts do not match the recorded root."
    }
    foreach ($sidePath in $script:ExpectedSideOutputPaths) {
        if ($portablePaths.Contains($sidePath)) {
            throw "$Name publishes validation-only side output '$sidePath'."
        }
    }
    $descriptor = Get-TreeDescriptor @($records)
    Assert-Descriptor $descriptor "$Name descriptor"
    return [pscustomobject]@{
        Root = $rootPath
        Records = @($records)
        Descriptor = $descriptor
    }
}

function Assert-RootRelationship {
    param(
        [Parameter(Mandatory = $true)][string]$LfRoot,
        [Parameter(Mandatory = $true)][string]$CrlfRoot
    )

    $lf = (Get-FullPath $LfRoot).TrimEnd([char[]]'\/')
    $crlf = (Get-FullPath $CrlfRoot).TrimEnd([char[]]'\/')
    if ($lf.Equals($crlf, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'LF and CRLF generated roots must be distinct.'
    }
    $separator = [IO.Path]::DirectorySeparatorChar
    if ($lf.StartsWith($crlf + $separator, [StringComparison]::OrdinalIgnoreCase) -or
        $crlf.StartsWith($lf + $separator, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'LF and CRLF generated roots must not be nested.'
    }
}

function Assert-RecordSetsEqual {
    param(
        [Parameter(Mandatory = $true)][object[]]$Expected,
        [Parameter(Mandatory = $true)][object[]]$Actual
    )

    if ($Expected.Count -ne $Actual.Count) {
        throw 'LF and CRLF normalized roots have different file counts.'
    }
    $actualByPath = [Collections.Generic.Dictionary[string,object]]::new(
        [StringComparer]::Ordinal
    )
    foreach ($record in $Actual) { $actualByPath.Add($record.RelativePath, $record) }
    foreach ($record in $Expected) {
        if (-not $actualByPath.ContainsKey($record.RelativePath) -or
            [UInt64]$actualByPath[$record.RelativePath].Bytes -ne
                [UInt64]$record.Bytes -or
            $actualByPath[$record.RelativePath].Sha256 -cne $record.Sha256) {
            throw "LF and CRLF normalized roots differ at '$($record.RelativePath)'."
        }
    }
}

$evidencePath = Get-FullPath $EvidenceFile
$evidenceSnapshot = Read-EvidenceJson $evidencePath 'Mesa generated-source evidence'
$evidence = $evidenceSnapshot.Value
$evidenceDirectory = Split-Path -Parent $evidencePath
if ($evidenceSnapshot.Text.IndexOf('.scratch', [StringComparison]::OrdinalIgnoreCase) -ge 0) {
    throw 'Mesa generated-source evidence must not contain scratch-root paths.'
}

Assert-ExactProperties $evidence @(
    '_spdx', 'schema', 'schema_definition', 'status', 'reason', 'component',
    'inputs', 'runs', 'comparison', 'scope'
) 'Mesa generated-source evidence'
Assert-StringValue $evidence._spdx 'GPL-3.0-only' '_spdx'
Assert-IntegerValue $evidence.schema 1 'schema'
Assert-ExactProperties $evidence.schema_definition @('relative_path', 'sha256') `
    'schema_definition'
Assert-StringValue $evidence.schema_definition.relative_path `
    'mesa-generated-source-reproducibility.schema.json' `
    'schema_definition.relative_path'
Assert-StringValue $evidence.schema_definition.sha256 $script:ExpectedSchemaSha256 `
    'schema_definition.sha256'
$schemaPath = Resolve-SiblingFile $evidenceDirectory `
    $evidence.schema_definition.relative_path 'schema_definition.relative_path'
$schemaSnapshot = Read-EvidenceJson $schemaPath `
    'Mesa generated-source reproducibility schema'
if ($schemaSnapshot.Sha256 -cne $script:ExpectedSchemaSha256) {
    throw 'Mesa generated-source reproducibility schema digest mismatch.'
}
Assert-StringValue $evidence.status 'proven' 'status'
Assert-StringValue $evidence.reason `
    'Two independent pinned Mesa 23.1.9 generation checkouts with LF and CRLF source modes produced byte-identical normalized generated-source roots. This evidence proves only normalized output reproducibility and grants no execution, build, delivery, installation, activation, or capability authority.' `
    'reason'

Assert-ExactProperties $evidence.component @(
    'upstream_name', 'repository', 'owning_commit', 'mesa_version', 'mesa_subtree'
) 'component'
Assert-StringValue $evidence.component.upstream_name 'mesa9x' `
    'component.upstream_name'
Assert-StringValue $evidence.component.repository $script:ExpectedRepository `
    'component.repository'
Assert-StringValue $evidence.component.owning_commit $script:ExpectedCommit `
    'component.owning_commit'
Assert-StringValue $evidence.component.mesa_version '23.1.9' 'component.mesa_version'
Assert-StringValue $evidence.component.mesa_subtree 'mesa-23.1.x' `
    'component.mesa_subtree'

Assert-ExactProperties $evidence.inputs @(
    'generated_source_plan', 'generated_source_plan_schema',
    'generator_recipe', 'source_seed'
) 'inputs'
$planSnapshot = Assert-PinnedFile $evidence.inputs.generated_source_plan `
    'mesa-generated-source-plan.json' 4354 $script:ExpectedPlanSha256 `
    $evidenceDirectory 'inputs.generated_source_plan' -ParseJson
$planSchemaSnapshot = Assert-PinnedFile `
    $evidence.inputs.generated_source_plan_schema `
    'mesa-generated-source-plan.schema.json' 10706 $script:ExpectedPlanSchemaSha256 `
    $evidenceDirectory 'inputs.generated_source_plan_schema' -ParseJson
$seedSnapshot = Assert-PinnedFile $evidence.inputs.source_seed `
    'mesa-source-seed.json' 6915 $script:ExpectedSeedSha256 `
    $evidenceDirectory 'inputs.source_seed' -ParseJson
$null = $planSchemaSnapshot
$null = $seedSnapshot
Assert-ExactProperties $evidence.inputs.generator_recipe @(
    'relative_path', 'git_blob', 'bytes', 'sha256'
) 'inputs.generator_recipe'
Assert-StringValue $evidence.inputs.generator_recipe.relative_path `
    'generator/mesa-23.1.x-gen.mk' 'inputs.generator_recipe.relative_path'
Assert-StringValue $evidence.inputs.generator_recipe.git_blob `
    $script:ExpectedRecipeBlob 'inputs.generator_recipe.git_blob'
Assert-IntegerValue $evidence.inputs.generator_recipe.bytes 13288 `
    'inputs.generator_recipe.bytes'
Assert-StringValue $evidence.inputs.generator_recipe.sha256 `
    $script:ExpectedRecipeSha256 'inputs.generator_recipe.sha256'

$plan = $planSnapshot.Value
if ($plan.component.repository -cne $evidence.component.repository -or
    $plan.component.owning_commit -cne $evidence.component.owning_commit -or
    $plan.inputs.generator_recipe.relative_path -cne
        $evidence.inputs.generator_recipe.relative_path -or
    $plan.inputs.generator_recipe.git_blob -cne
        $evidence.inputs.generator_recipe.git_blob -or
    $plan.inputs.generator_recipe.bytes -ne $evidence.inputs.generator_recipe.bytes -or
    $plan.inputs.generator_recipe.sha256 -cne
        $evidence.inputs.generator_recipe.sha256 -or
    $plan.inputs.source_seed.relative_path -cne
        $evidence.inputs.source_seed.relative_path -or
    $plan.inputs.source_seed.bytes -ne $evidence.inputs.source_seed.bytes -or
    $plan.inputs.source_seed.sha256 -cne $evidence.inputs.source_seed.sha256 -or
    $plan.selection.recipe_output_count -ne 67 -or
    $plan.selection.validation_side_output_count -ne 4 -or
    $plan.selection.published_output_count -ne 67) {
    throw 'Generated-source evidence is cross-wired from its pinned preparation plan.'
}

$runs = Assert-ArrayCount $evidence.runs 2 'runs'
Assert-Run $runs[0] $evidence 'mesa-generated-lf-v1' 'lf' $false `
    'fa3d0f5ed1eceebacf90bfb12f6a172738a858d590c10e277a52c45d7f23f82a' `
    'runs[0]'
Assert-Run $runs[1] $evidence 'mesa-generated-crlf-v1' 'crlf' $true `
    '9373c9e734ba71974ddde8b4edb4823fc6c60fa6d70a6a0bfc8339dc1d16f2c8' `
    'runs[1]'

Assert-ExactProperties $evidence.comparison @(
    'source_checkout_relationship', 'output_root_relationship', 'path_identity',
    'normalized_outputs_byte_identical', 'validation_side_output_paths',
    'validation_side_output_count_per_root'
) 'comparison'
Assert-StringValue $evidence.comparison.source_checkout_relationship 'independent' `
    'comparison.source_checkout_relationship'
Assert-StringValue $evidence.comparison.output_root_relationship `
    'distinct-non-nested' 'comparison.output_root_relationship'
Assert-StringValue $evidence.comparison.path_identity 'content-only-no-absolute-root' `
    'comparison.path_identity'
Assert-BooleanValue $evidence.comparison.normalized_outputs_byte_identical $true `
    'comparison.normalized_outputs_byte_identical'
Assert-StringSequence $evidence.comparison.validation_side_output_paths `
    $script:ExpectedSideOutputPaths 'comparison.validation_side_output_paths'
Assert-IntegerValue $evidence.comparison.validation_side_output_count_per_root 0 `
    'comparison.validation_side_output_count_per_root'
Assert-Scope $evidence.scope

$hasLfRoot = -not [string]::IsNullOrWhiteSpace($LfGeneratedRoot)
$hasCrlfRoot = -not [string]::IsNullOrWhiteSpace($CrlfGeneratedRoot)
if ($hasLfRoot -ne $hasCrlfRoot) {
    throw 'LF and CRLF generated roots must be supplied together.'
}
if ($hasLfRoot) {
    Assert-RootRelationship $LfGeneratedRoot $CrlfGeneratedRoot
    $lfSnapshot = Get-GeneratedRootSnapshot $LfGeneratedRoot 'LF generated root'
    $crlfSnapshot = Get-GeneratedRootSnapshot $CrlfGeneratedRoot 'CRLF generated root'
    Assert-RecordSetsEqual @($lfSnapshot.Records) @($crlfSnapshot.Records)
    $rootStatus = 'verified-distinct-byte-identical'
}
else {
    $rootStatus = 'not-requested'
}

Write-Output (
    "Verified Mesa generated-source reproducibility evidence as proven; roots={0}; authorizations=false." -f `
        $rootStatus
)
