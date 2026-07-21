# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [string]$SourceRoot,

    [string]$OutputRoot,

    [string]$DescribeTree,

    [string]$DescribeRecipe,

    [string]$RecipePlan,

    [Alias('PatchRoot')]
    [string]$RecipeRoot,

    [string]$LockFile,

    [scriptblock]$BeforePatchNormalization,

    [scriptblock]$BeforeCachedOverlayValidation,

    [scriptblock]$BeforeFinalPublication,

    [scriptblock]$BeforeSecondScan
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'strict-json.ps1')
. (Join-Path $PSScriptRoot 'strict-tsv.ps1')
$script:HardMaximumRecipes = 8
$script:HardMaximumPatches = 64
$script:HardMaximumNormalizedPaths = 128
$script:HardMaximumOverlays = 16
$script:HardMaximumPatchBytes = [UInt64]67108864
$script:HardMaximumFiles = [UInt64]20000
$script:HardMaximumDirectories = [UInt64]10000
$script:HardMaximumEntries = [UInt64]30000
$script:HardMaximumAggregateBytes = [UInt64]536870912
$script:HardMaximumFileBytes = [UInt64]67108864
$script:HardMaximumPathBytes = [UInt64]512
$script:HardMaximumLockBytes = [UInt64]1048576
$script:HardMaximumLockRows = 256

if ([string]::IsNullOrWhiteSpace($RecipePlan)) {
    $RecipePlan = Join-Path $PSScriptRoot '..\drivers\win98\derived-source-plan.json'
}
if ([string]::IsNullOrWhiteSpace($RecipeRoot)) {
    $RecipeRoot = Join-Path $PSScriptRoot '..\drivers\win98'
}
if ([string]::IsNullOrWhiteSpace($LockFile)) {
    $LockFile = Join-Path $PSScriptRoot '..\drivers\win98\upstream.lock.tsv'
}

function Get-FullPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }
    return [IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

function Get-ProcessEnvironmentEntry {
    param([Parameter(Mandatory = $true)][string]$Name)

    $item = Get-Item -LiteralPath ('Env:' + $Name) -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        return [pscustomobject]@{
            Present = $false
            Name = $Name
            Value = $null
        }
    }
    return [pscustomobject]@{
        Present = $true
        Name = [string]$item.Name
        Value = [string]$item.Value
    }
}

function Restore-ProcessEnvironmentEntry {
    param(
        [Parameter(Mandatory = $true)][string]$LookupName,
        [Parameter(Mandatory = $true)]$Entry
    )

    Remove-Item -LiteralPath ('Env:' + $LookupName) -ErrorAction SilentlyContinue
    if ($Entry.Present) {
        Set-Item -LiteralPath ('Env:' + [string]$Entry.Name) `
            -Value ([string]$Entry.Value)
    }
}

function Read-StrictJson {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        return Read-GswStrictJsonFile -Path $Path -Name 'derived-source metadata' `
            -MaximumBytes 4194304
    }
    catch {
        throw "Malformed derived-source plan JSON: $($_.Exception.Message)"
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
        return [UInt64]$Value
    }
    catch {
        throw "$Name must be a non-negative 64-bit integer."
    }
}

function Assert-LowercaseHash {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Value -isnot [string] -or $Value -cnotmatch '^[0-9a-f]{64}$') {
        throw "$Name must be a lowercase SHA-256 digest."
    }
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
        $RelativePath.Contains('\')) {
        throw "Unsafe relative path '$RelativePath' in $Name metadata."
    }
    foreach ($component in $RelativePath.Split('/')) {
        if ([string]::IsNullOrWhiteSpace($component) -or
            $component -in @('.', '..') -or
            $component -match '[\x00-\x1f:*?"<>|]' -or
            $component.EndsWith('.') -or
            $component.EndsWith(' ') -or
            $component -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$') {
            throw "Unsafe path component '$component' in $Name metadata."
        }
    }
    $rootPath = Get-FullPath $Root
    $rootPrefix = $rootPath.TrimEnd([char[]]'\/') + [IO.Path]::DirectorySeparatorChar
    $nativeRelativePath = $RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)
    $candidate = [IO.Path]::GetFullPath((Join-Path $rootPath $nativeRelativePath))
    if (-not $candidate.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Relative path '$RelativePath' escapes its declared root."
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
    $rootItem = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
    if ($null -ne $rootItem -and
        ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Reparse-point root is not allowed in $Name."
    }
    foreach ($component in $RelativePath.Split('/')) {
        $current = Join-Path $current $component
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($null -eq $item) {
            break
        }
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Reparse-point component '$component' is not allowed in $Name."
        }
    }
}

function Convert-FileToCanonicalLf {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $path = Get-ContainedPath $Root $RelativePath $Name
    Assert-PathComponentsAreNotReparsePoints $Root $RelativePath $Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "LF-normalization input '$RelativePath' is not a regular file."
    }
    $snapshot = Read-GswBoundedFileSnapshot -Path $path `
        -Name "LF-normalization input '$RelativePath'" `
        -MaximumBytes $script:HardMaximumFileBytes -AllowEmpty
    [byte[]]$bytes = $snapshot.Bytes
    $normalized = [Collections.Generic.List[byte]]::new($bytes.Length)
    for ($index = 0; $index -lt $bytes.Length; $index++) {
        $value = $bytes[$index]
        if ($value -eq 0) {
            throw "LF-normalization input '$RelativePath' contains a NUL byte."
        }
        if ($value -eq 13) {
            if ($index + 1 -ge $bytes.Length -or $bytes[$index + 1] -ne 10) {
                throw "LF-normalization input '$RelativePath' contains an isolated CR byte."
            }
            continue
        }
        $normalized.Add($value)
    }
    if ($normalized.Count -eq $bytes.Length) { return }
    $temporaryPath = Join-Path (Split-Path -Parent $path) (
        '.retvrn99-lf-' + [Guid]::NewGuid().ToString('N')
    )
    try {
        [IO.File]::WriteAllBytes($temporaryPath, $normalized.ToArray())
        $overwriteMove = [IO.File].GetMethod(
            'Move',
            [Reflection.BindingFlags]'Public,Static',
            $null,
            [Type[]]@([string], [string], [bool]),
            $null
        )
        if ($null -ne $overwriteMove) {
            [IO.File]::Move($temporaryPath, $path, $true)
        }
        else {
            [IO.File]::Delete($path)
            [IO.File]::Move($temporaryPath, $path)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            [IO.File]::Delete($temporaryPath)
        }
    }
}

function Get-DerivedGitExecutable {
    $commands = @(Get-Command git -CommandType Application -ErrorAction Stop)
    if ($commands.Count -eq 0) {
        throw 'git is required for derived-source preparation.'
    }
    $gitPath = [IO.Path]::GetFullPath($commands[0].Source)
    if ([IO.Path]::DirectorySeparatorChar -eq '\') {
        $gitRoot = Split-Path -Parent (Split-Path -Parent $gitPath)
        $directPath = Join-Path $gitRoot 'mingw64\bin\git.exe'
        if (Test-Path -LiteralPath $directPath -PathType Leaf) {
            return [IO.Path]::GetFullPath($directPath)
        }
    }
    return $gitPath
}

function Invoke-GitLines {
    param(
        [Parameter(Mandatory = $true)][string]$Checkout,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $output = @(Invoke-WithIsolatedGitEnvironment {
        & (Get-DerivedGitExecutable) -c core.quotePath=false -C $Checkout @Arguments
    })
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed for '$Checkout'."
    }
    return $output
}

function Invoke-WithIsolatedGitEnvironment {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Body,
        [string]$CeilingDirectory
    )

    $names = @(
        'GIT_CEILING_DIRECTORIES', 'GIT_DIR', 'GIT_WORK_TREE',
        'GIT_PREFIX', 'GIT_INDEX_FILE'
    )
    $saved = @{}
    foreach ($name in $names) {
        $saved[$name] = Get-ProcessEnvironmentEntry $name
    }
    try {
        foreach ($name in $names) {
            Remove-Item -LiteralPath ('Env:' + $name) -ErrorAction SilentlyContinue
        }
        if (-not [string]::IsNullOrEmpty($CeilingDirectory)) {
            [Environment]::SetEnvironmentVariable(
                'GIT_CEILING_DIRECTORIES', $CeilingDirectory, 'Process'
            )
        }
        & $Body
    }
    finally {
        foreach ($name in $names) {
            Restore-ProcessEnvironmentEntry $name $saved[$name]
        }
    }
}

function Get-BigEndianBytes {
    param(
        [Parameter(Mandatory = $true)][UInt64]$Value,
        [Parameter(Mandatory = $true)][int]$Width
    )

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

function ConvertTo-LowerHex {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    return ([BitConverter]::ToString($Bytes) -replace '-', '').ToLowerInvariant()
}

function Read-UpstreamLockSnapshot {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        $snapshot = Read-GswBoundedFileSnapshot -Path $Path -Name 'upstream lock' `
            -MaximumBytes $script:HardMaximumLockBytes
    }
    catch {
        throw "The upstream lock failed its hard byte bound or regular-file check: $($_.Exception.Message)"
    }
    [byte[]]$bytes = $snapshot.Bytes
    $hash = $snapshot.Sha256
    $header = @(
        'name', 'source_directory', 'repository', 'commit', 'upstream_license',
        'disposition', 'closure_manifest', 'closure_manifest_sha256', 'scope'
    )
    [object[]]$entries = @(ConvertFrom-StrictTsvUtf8Bytes `
        -Bytes $bytes -ExpectedHeader $header `
        -Name 'upstream lock' -MaximumRows $script:HardMaximumLockRows `
        -MaximumBytes ([int]$script:HardMaximumLockBytes) `
        -MaximumLineBytes 16384 -MaximumPhysicalLines 1024)
    return [pscustomobject]@{
        Bytes = [UInt64]$bytes.Length
        Sha256 = $hash
        Entries = $entries
    }
}

function Assert-ComponentInputsMatchSnapshots {
    param(
        [Parameter(Mandatory = $true)][string]$LockPath,
        [Parameter(Mandatory = $true)]$ExpectedLock,
        [Parameter(Mandatory = $true)][object[]]$Recipes
    )

    $currentLock = Read-UpstreamLockSnapshot $LockPath
    if ($currentLock.Bytes -ne $ExpectedLock.Bytes -or
        $currentLock.Sha256 -cne $ExpectedLock.Sha256) {
        throw 'The authoritative upstream lock changed before component publication.'
    }
    foreach ($recipe in $Recipes) {
        $binding = $recipe.Component.LockBinding
        $rows = @($currentLock.Entries | Where-Object { $_.name -ceq $binding.Name })
        if ($rows.Count -ne 1) {
            throw "Recipe '$($recipe.Name)' lost its authoritative component lock row."
        }
        $row = $rows[0]
        foreach ($field in @(
            [pscustomobject]@{ Lock = 'name'; Snapshot = 'Name' },
            [pscustomobject]@{ Lock = 'source_directory'; Snapshot = 'SourceDirectory' },
            [pscustomobject]@{ Lock = 'repository'; Snapshot = 'Repository' },
            [pscustomobject]@{ Lock = 'commit'; Snapshot = 'Commit' },
            [pscustomobject]@{ Lock = 'upstream_license'; Snapshot = 'UpstreamLicense' },
            [pscustomobject]@{ Lock = 'disposition'; Snapshot = 'Disposition' },
            [pscustomobject]@{ Lock = 'closure_manifest'; Snapshot = 'ClosureManifest' },
            [pscustomobject]@{ Lock = 'closure_manifest_sha256'; Snapshot = 'ClosureManifestSha256' },
            [pscustomobject]@{ Lock = 'scope'; Snapshot = 'Scope' }
        )) {
            if ([string]$row.($field.Lock) -cne [string]$binding.($field.Snapshot)) {
                throw "Recipe '$($recipe.Name)' component lock binding changed before publication."
            }
        }
        Assert-PathComponentsAreNotReparsePoints $recipe.Component.LockRoot `
            $recipe.Component.ManifestRelativePath `
            "recipe '$($recipe.Name)' component closure manifest"
        $manifestHash = (Get-FileHash -LiteralPath $recipe.Component.ManifestPath `
            -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($manifestHash -cne $recipe.Component.ManifestHash) {
            throw "Recipe '$($recipe.Name)' component closure changed before publication."
        }
    }
}

function Get-PortableRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $getRelativePath = [IO.Path].GetMethod(
        'GetRelativePath',
        [Reflection.BindingFlags]'Public,Static',
        $null,
        [Type[]]@([string], [string]),
        $null
    )
    if ($null -ne $getRelativePath) {
        $relativePath = [IO.Path]::GetRelativePath($Root, $Path)
    }
    else {
        $rootUri = New-Object Uri ($Root.TrimEnd([char[]]'\/') + [IO.Path]::DirectorySeparatorChar)
        $pathUri = New-Object Uri $Path
        $relativePath = [Uri]::UnescapeDataString($rootUri.MakeRelativeUri($pathUri).ToString())
    }
    if ([IO.Path]::DirectorySeparatorChar -ne '/') {
        $relativePath = $relativePath.Replace([IO.Path]::DirectorySeparatorChar, '/')
    }
    [void](Get-ContainedPath $Root $relativePath 'derived tree')
    return $relativePath
}

function Get-DerivedTreeDescriptor {
    param([Parameter(Mandatory = $true)][string]$Root)

    $rootPath = Get-FullPath $Root
    $rootItem = Get-Item -LiteralPath $rootPath -Force
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'A derived-source root cannot be a reparse point.'
    }
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
            if ($totalEntries -gt $script:HardMaximumEntries) {
                throw 'Derived tree exceeds the hard entry-count bound.'
            }
            $relativePath = Get-PortableRelativePath $rootPath $entryPath
            [UInt64]$pathByteCount = $utf8.GetByteCount($relativePath)
            if ($pathByteCount -gt $script:HardMaximumPathBytes) {
                throw "Derived path '$relativePath' exceeds the hard length bound."
            }
            if ($pathByteCount -gt $maximumPathBytes) {
                $maximumPathBytes = $pathByteCount
            }
            $attributes = [IO.File]::GetAttributes($entryPath)
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Reparse points are not allowed in a derived tree: $entryPath"
            }
            if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) {
                $directoryCount++
                if ($directoryCount -gt $script:HardMaximumDirectories) {
                    throw 'Derived tree exceeds the hard directory-count bound.'
                }
                $pendingDirectories.Push($entryPath)
                continue
            }
            if (($attributes -band [IO.FileAttributes]::Device) -ne 0) {
                throw "Non-regular derived entry is not supported: $entryPath"
            }
            $fileCount++
            if ($fileCount -gt $script:HardMaximumFiles) {
                throw 'Derived tree exceeds the hard file-count bound.'
            }
            if ($records.ContainsKey($relativePath)) {
                throw "Duplicate normalized derived path '$relativePath'."
            }
            $stream = [IO.File]::Open(
                $entryPath,
                [IO.FileMode]::Open,
                [IO.FileAccess]::Read,
                [IO.FileShare]::Read
            )
            try {
                [UInt64]$length = $stream.Length
                if ($length -gt $script:HardMaximumFileBytes) {
                    throw "Derived file '$relativePath' exceeds the hard size bound."
                }
                if ([UInt64]::MaxValue - $aggregateBytes -lt $length -or
                    $aggregateBytes + $length -gt $script:HardMaximumAggregateBytes) {
                    throw 'Derived tree exceeds the hard aggregate-byte bound.'
                }
                $aggregateBytes += $length
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
    $canonical = New-Object IO.MemoryStream
    try {
        [byte[]]$field = $utf8.GetBytes("RETVRN99-WIN98-TREE-SHA256-V1`0")
        $canonical.Write($field, 0, $field.Length)
        $field = Get-BigEndianBytes -Value ([UInt64]$paths.Count) -Width 8
        $canonical.Write($field, 0, $field.Length)
        $field = Get-BigEndianBytes -Value $aggregateBytes -Width 8
        $canonical.Write($field, 0, $field.Length)
        foreach ($relativePath in $paths) {
            [byte[]]$encodedPath = $utf8.GetBytes($relativePath)
            $record = $records[$relativePath]
            $field = Get-BigEndianBytes -Value ([UInt64]$encodedPath.Length) -Width 4
            $canonical.Write($field, 0, $field.Length)
            $canonical.Write($encodedPath, 0, $encodedPath.Length)
            $field = Get-BigEndianBytes -Value ([UInt64]$record.Length) -Width 8
            $canonical.Write($field, 0, $field.Length)
            [byte[]]$fileHash = $record.Hash
            $canonical.Write($fileHash, 0, $fileHash.Length)
        }
        $canonical.Position = 0
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $treeHash = ConvertTo-LowerHex -Bytes ($sha.ComputeHash($canonical))
        }
        finally {
            $sha.Dispose()
        }
    }
    finally {
        $canonical.Dispose()
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

function Assert-DescriptorMatches {
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

function Remove-EmptyDirectories {
    param([Parameter(Mandatory = $true)][string]$Root)

    $rootPath = Get-FullPath $Root
    $rootAttributes = [IO.File]::GetAttributes($rootPath)
    if (($rootAttributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Derived tree root cannot be a reparse point: $rootPath"
    }
    $pending = [Collections.Generic.Stack[string]]::new()
    $directories = [Collections.Generic.List[string]]::new()
    $pending.Push($rootPath)
    while ($pending.Count -ne 0) {
        $directory = $pending.Pop()
        $directories.Add($directory)
        foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($directory)) {
            $attributes = [IO.File]::GetAttributes($entry)
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Reparse points are not allowed in a derived tree: $entry"
            }
            if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) {
                $pending.Push($entry)
            }
        }
    }
    for ($index = $directories.Count - 1; $index -gt 0; $index--) {
        $directory = $directories[$index]
        $enumerator = [IO.Directory]::EnumerateFileSystemEntries($directory).GetEnumerator()
        try {
            $hasEntries = $enumerator.MoveNext()
        }
        finally {
            $enumerator.Dispose()
        }
        if (-not $hasEntries) {
            [IO.Directory]::Delete($directory, $false)
        }
    }
}

function Remove-PrivateTreeSafely {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedParent,
        [Parameter(Mandatory = $true)][string]$ExpectedPrefix
    )

    $rootPath = Get-FullPath $Path
    if ((Split-Path -Parent $rootPath) -cne (Get-FullPath $ExpectedParent) -or
        -not (Split-Path -Leaf $rootPath).StartsWith($ExpectedPrefix, [StringComparison]::Ordinal)) {
        throw "Refusing to remove unverified private tree '$rootPath'."
    }
    if (-not (Test-Path -LiteralPath $rootPath)) { return }
    $rootAttributes = [IO.File]::GetAttributes($rootPath)
    if (($rootAttributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        [IO.Directory]::Delete($rootPath, $false)
        return
    }
    $pending = [Collections.Generic.Stack[string]]::new()
    $directories = [Collections.Generic.List[string]]::new()
    $pending.Push($rootPath)
    while ($pending.Count -ne 0) {
        $directory = $pending.Pop()
        $directories.Add($directory)
        foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($directory)) {
            $attributes = [IO.File]::GetAttributes($entry)
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) {
                    [IO.Directory]::Delete($entry, $false)
                }
                else {
                    [IO.File]::Delete($entry)
                }
            }
            elseif (($attributes -band [IO.FileAttributes]::Directory) -ne 0) {
                $pending.Push($entry)
            }
            else {
                [IO.File]::SetAttributes($entry, [IO.FileAttributes]::Normal)
                [IO.File]::Delete($entry)
            }
        }
    }
    for ($index = $directories.Count - 1; $index -ge 0; $index--) {
        [IO.Directory]::Delete($directories[$index], $false)
    }
}

function Copy-OverlayTree {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][bool]$ReplaceExisting
    )

    $sourceRootPath = Get-FullPath $Source
    $pendingDirectories = [Collections.Generic.Stack[string]]::new()
    $pendingDirectories.Push($sourceRootPath)
    while ($pendingDirectories.Count -ne 0) {
        $sourceDirectory = $pendingDirectories.Pop()
        foreach ($sourcePath in [IO.Directory]::EnumerateFileSystemEntries($sourceDirectory)) {
            $relativePath = Get-PortableRelativePath $sourceRootPath $sourcePath
            $destinationPath = Get-ContainedPath $Destination $relativePath 'overlay destination'
            $attributes = [IO.File]::GetAttributes($sourcePath)
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Reparse points are not allowed in an overlay tree: $sourcePath"
            }
            if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) {
                if (Test-Path -LiteralPath $destinationPath -PathType Leaf) {
                    throw "Overlay directory collides with a derived file: $destinationPath"
                }
                if (-not (Test-Path -LiteralPath $destinationPath -PathType Container)) {
                    [void](New-Item -ItemType Directory -Path $destinationPath)
                }
                $pendingDirectories.Push($sourcePath)
                continue
            }
            if (($attributes -band [IO.FileAttributes]::Device) -ne 0) {
                throw "Non-regular overlay entry is not supported: $sourcePath"
            }
            $destinationParent = Split-Path -Parent $destinationPath
            if (-not (Test-Path -LiteralPath $destinationParent -PathType Container)) {
                [void](New-Item -ItemType Directory -Path $destinationParent -Force)
            }
            if ((Test-Path -LiteralPath $destinationPath) -and -not $ReplaceExisting) {
                throw "Overlay file would replace tracked source without explicit approval: $destinationPath"
            }
            [IO.File]::Copy($sourcePath, $destinationPath, $ReplaceExisting)
        }
    }
}

function ConvertTo-ProcessArgument {
    param([Parameter(Mandatory = $true)][string]$Argument)

    if ($Argument.Length -gt 0 -and $Argument -notmatch '[\s"]') {
        return $Argument
    }
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq '\') {
            $backslashes++
            continue
        }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (2 * $backslashes + 1)))
            [void]$builder.Append('"')
        }
        else {
            [void]$builder.Append(('\' * $backslashes))
            [void]$builder.Append($character)
        }
        $backslashes = 0
    }
    [void]$builder.Append(('\' * (2 * $backslashes)))
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Copy-GitBlob {
    param(
        [Parameter(Mandatory = $true)][string]$Checkout,
        [Parameter(Mandatory = $true)][string]$Hash,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][UInt64]$ExpectedLength
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Get-DerivedGitExecutable
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($gitVariable in @(
        'GIT_CEILING_DIRECTORIES', 'GIT_DIR', 'GIT_WORK_TREE',
        'GIT_PREFIX', 'GIT_INDEX_FILE'
    )) {
        if ($null -ne $startInfo.PSObject.Properties['Environment']) {
            [void]$startInfo.Environment.Remove($gitVariable)
        }
        else {
            [void]$startInfo.EnvironmentVariables.Remove($gitVariable)
        }
    }
    $arguments = @('-C', $Checkout, 'cat-file', 'blob', $Hash)
    if ($null -ne $startInfo.PSObject.Properties['ArgumentList']) {
        foreach ($argument in $arguments) { $startInfo.ArgumentList.Add($argument) }
    }
    else {
        $startInfo.Arguments = (@($arguments | ForEach-Object {
            ConvertTo-ProcessArgument ([string]$_)
        }) -join ' ')
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $destinationStream = $null
    try {
        if (-not $process.Start()) {
            throw "Unable to start git cat-file for '$Hash'."
        }
        $errorTask = $process.StandardError.ReadToEndAsync()
        $destinationStream = [IO.File]::Open(
            $Destination,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None
        )
        $process.StandardOutput.BaseStream.CopyTo($destinationStream)
        $destinationStream.Dispose()
        $destinationStream = $null
        $process.WaitForExit()
        $errorText = $errorTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "git cat-file failed for '$Hash': $errorText"
        }
    }
    catch {
        if ($null -ne $destinationStream) { $destinationStream.Dispose() }
        if (Test-Path -LiteralPath $Destination) {
            Remove-Item -LiteralPath $Destination -Force
        }
        throw
    }
    finally {
        $process.Dispose()
    }
    $written = Get-Item -LiteralPath $Destination
    if ([UInt64]$written.Length -ne $ExpectedLength) {
        Remove-Item -LiteralPath $Destination -Force
        throw "git blob '$Hash' changed length while it was copied."
    }
}

function Copy-TrackedRepository {
    param(
        [Parameter(Mandatory = $true)][string]$Checkout,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Prefix,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()]
        [Collections.Generic.HashSet[string]]$SeenPaths,
        [Parameter(Mandatory = $true)][ref]$AggregateBytes,
        [Parameter(Mandatory = $true)][ref]$FileCount,
        [int]$Depth = 0
    )

    if ($Depth -gt 8) {
        throw 'Tracked source exceeds the recursive gitlink depth bound.'
    }
    $checkoutItem = Get-Item -LiteralPath $Checkout -Force -ErrorAction Stop
    if (($checkoutItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Pinned checkout cannot be a reparse point: $Checkout"
    }
    $lines = @(Invoke-GitLines $Checkout @('ls-files', '--cached', '--stage'))
    if ($lines.Count -eq 0) {
        throw "Pinned checkout '$Checkout' contains no tracked files."
    }
    foreach ($line in $lines) {
        if ($line -notmatch '^(?<mode>[0-9]{6}) (?<hash>[0-9a-f]{40}) 0\t(?<path>.+)$') {
            throw "Unsafe or unsupported git index record in '$Checkout'."
        }
        $mode = $Matches.mode
        $hash = $Matches.hash
        $repositoryRelativePath = $Matches.path
        [void](Get-ContainedPath $Checkout $repositoryRelativePath 'tracked source')
        $relativePath = if ($Prefix.Length -eq 0) {
            $repositoryRelativePath
        }
        else {
            "$Prefix/$repositoryRelativePath"
        }
        if ($mode -eq '160000') {
            Assert-PathComponentsAreNotReparsePoints $Checkout $repositoryRelativePath 'tracked gitlink'
            $submodule = Get-ContainedPath $Checkout $repositoryRelativePath 'tracked gitlink'
            if (-not (Test-Path -LiteralPath $submodule -PathType Container) -or
                -not (Test-Path -LiteralPath (Join-Path $submodule '.git'))) {
                throw "Tracked gitlink '$relativePath' is not populated."
            }
            $submoduleHead = (Invoke-GitLines $submodule @('rev-parse', 'HEAD') | Select-Object -First 1)
            if ($submoduleHead -cne $hash) {
                throw "Tracked gitlink '$relativePath' does not match its pinned commit."
            }
            Copy-TrackedRepository -Checkout $submodule -Destination $Destination `
                -Prefix $relativePath -SeenPaths $SeenPaths `
                -AggregateBytes $AggregateBytes -FileCount $FileCount -Depth ($Depth + 1)
            continue
        }
        if ($mode -notin @('100644', '100755')) {
            throw "Tracked source '$relativePath' has unsupported git mode $mode."
        }
        if (-not $SeenPaths.Add($relativePath)) {
            throw "Tracked source has a case-folded duplicate path '$relativePath'."
        }
        $lengthText = (Invoke-GitLines $Checkout @('cat-file', '-s', $hash) | Select-Object -First 1)
        [UInt64]$length = 0
        if (-not [UInt64]::TryParse($lengthText, [ref]$length)) {
            throw "Tracked source '$relativePath' has an invalid git blob length."
        }
        if ($length -gt $script:HardMaximumFileBytes -or
            [UInt64]$AggregateBytes.Value + $length -gt $script:HardMaximumAggregateBytes) {
            throw 'Tracked source exceeds derived-source size bounds.'
        }
        $AggregateBytes.Value = [UInt64]$AggregateBytes.Value + $length
        $FileCount.Value = [UInt64]$FileCount.Value + 1
        if ([UInt64]$FileCount.Value -gt $script:HardMaximumFiles) {
            throw 'Tracked source exceeds the derived-source file-count bound.'
        }
        $destinationPath = Get-ContainedPath $Destination $relativePath 'derived destination'
        $destinationParent = Split-Path -Parent $destinationPath
        if (-not (Test-Path -LiteralPath $destinationParent -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $destinationParent -Force)
        }
        Copy-GitBlob -Checkout $Checkout -Hash $hash `
            -Destination $destinationPath -ExpectedLength $length
    }
}

function Copy-TrackedSource {
    param(
        [Parameter(Mandatory = $true)][string]$Checkout,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $seenPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    [UInt64]$aggregateBytes = 0
    [UInt64]$fileCount = 0
    Copy-TrackedRepository -Checkout $Checkout -Destination $Destination -Prefix '' `
        -SeenPaths $seenPaths -AggregateBytes ([ref]$aggregateBytes) `
        -FileCount ([ref]$fileCount)
}

function Get-DosShortAlias {
    param([Parameter(Mandatory = $true)][string]$Name)

    $lastDot = $Name.LastIndexOf('.')
    $base = if ($lastDot -gt 0) { $Name.Substring(0, $lastDot) } else { $Name }
    $extension = if ($lastDot -gt 0) { $Name.Substring($lastDot + 1) } else { '' }
    if ($base -cmatch '^[A-Za-z0-9_$~!#%&\-{}()@''`_^]{1,8}$' -and
        ($extension.Length -eq 0 -or
            $extension -cmatch '^[A-Za-z0-9_$~!#%&\-{}()@''`_^]{1,3}$')) {
        return $null
    }
    $shortBase = ($base -replace '[ .]', '' -replace '[^A-Za-z0-9_$~!#%&\-{}()@''`_^]', '_')
    $shortExtension = ($extension -replace '[ .]', '' -replace '[^A-Za-z0-9_$~!#%&\-{}()@''`_^]', '_')
    if ($shortBase.Length -eq 0) { $shortBase = '_' }
    $shortBase = $shortBase.Substring(0, [Math]::Min(6, $shortBase.Length)) + '~1'
    if ($shortExtension.Length -gt 3) { $shortExtension = $shortExtension.Substring(0, 3) }
    $alias = if ($shortExtension.Length -eq 0) {
        $shortBase
    }
    else {
        "$shortBase.$shortExtension"
    }
    return $alias.ToUpperInvariant()
}

function Assert-PortableComponentPaths {
    param(
        [Parameter(Mandatory = $true)][object[]]$Records,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $entriesByParent = New-Object 'Collections.Generic.Dictionary[string,object]' `
        ([StringComparer]::OrdinalIgnoreCase)
    foreach ($record in $Records) {
        $components = $record.RelativePath.Split('/')
        $parent = ''
        for ($index = 0; $index -lt $components.Count; $index++) {
            $component = $components[$index]
            $kind = if ($index -eq $components.Count - 1) { 'file' } else { 'directory' }
            if (-not $entriesByParent.ContainsKey($parent)) {
                $entriesByParent.Add($parent, (New-Object Collections.Generic.List[object]))
            }
            $siblings = $entriesByParent[$parent]
            $alias = Get-DosShortAlias $component
            $matched = $false
            foreach ($sibling in $siblings) {
                if ($sibling.Name -ceq $component) {
                    if ($sibling.Kind -cne $kind) {
                        throw "$Name has a file/directory collision at '$($record.RelativePath)'."
                    }
                    $matched = $true
                    break
                }
                if ($sibling.Name -ieq $component) {
                    throw "$Name has a case-folded path collision at '$($record.RelativePath)'."
                }
                if (($null -ne $alias -and $alias -ieq $sibling.Name) -or
                    ($null -ne $sibling.Alias -and $sibling.Alias -ieq $component)) {
                    throw "$Name has a DOS 8.3 path collision at '$($record.RelativePath)'."
                }
            }
            if (-not $matched) {
                [void]$siblings.Add([pscustomobject]@{
                    Name = $component
                    Alias = $alias
                    Kind = $kind
                })
            }
            $parent = if ($parent.Length -eq 0) { $component } else { "$parent/$component" }
        }
    }
}

function Get-ComponentClosureDescriptor {
    param(
        [Parameter(Mandatory = $true)]$LockedSource,
        [Parameter(Mandatory = $true)]$SourceSelection,
        [Parameter(Mandatory = $true)][string]$LockRoot,
        [Parameter(Mandatory = $true)][string]$RecipeName
    )

    Assert-ExactProperties $SourceSelection @(
        'mode', 'closure_manifest', 'closure_manifest_sha256'
    ) "recipe '$RecipeName' component source selection"
    if ($SourceSelection.mode -cne 'component-closure' -or
        $SourceSelection.closure_manifest -isnot [string] -or
        $SourceSelection.closure_manifest -cne $LockedSource.closure_manifest -or
        $SourceSelection.closure_manifest_sha256 -isnot [string] -or
        $SourceSelection.closure_manifest_sha256 -cne $LockedSource.closure_manifest_sha256) {
        throw "Recipe '$RecipeName' must match its canonical component closure link."
    }
    Assert-LowercaseHash $SourceSelection.closure_manifest_sha256 `
        "recipe '$RecipeName' component closure hash"
    $manifestPath = Get-ContainedPath $LockRoot $SourceSelection.closure_manifest `
        "recipe '$RecipeName' component closure manifest"
    Assert-PathComponentsAreNotReparsePoints $LockRoot $SourceSelection.closure_manifest `
        "recipe '$RecipeName' component closure manifest"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Recipe '$RecipeName' component closure manifest is missing."
    }
    $manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($manifestHash -cne $SourceSelection.closure_manifest_sha256) {
        throw "Recipe '$RecipeName' component closure manifest hash mismatch."
    }
    $manifest = Read-StrictJson $manifestPath
    Assert-ExactProperties $manifest @(
        '_spdx', 'schema', 'status', 'reason', 'upstream_name', 'owning_commit',
        'source_prefixes', 'notices', 'files'
    ) "recipe '$RecipeName' component closure"
    if ($manifest._spdx -cne 'GPL-3.0-only' -or
        (Assert-UnsignedInteger $manifest.schema "recipe '$RecipeName' component closure schema") -ne 1 -or
        $manifest.status -cne 'ready' -or $manifest.reason -cne '' -or
        $manifest.upstream_name -cne $LockedSource.name -or
        $manifest.owning_commit -cne $LockedSource.commit -or
        $manifest.notices -isnot [Array] -or $manifest.files -isnot [Array]) {
        throw "Recipe '$RecipeName' requires one ready closure for its pinned component source."
    }
    $records = New-Object Collections.Generic.List[object]
    [UInt64]$aggregateBytes = 0
    foreach ($record in @($manifest.notices) + @($manifest.files)) {
        $expectedProperties = if ($record.PSObject.Properties.Name -ccontains 'id') {
            @('id', 'relative_path', 'git_blob', 'bytes', 'sha256', 'license_expression')
        }
        else {
            @(
                'relative_path', 'git_blob', 'bytes', 'sha256', 'license_expression',
                'notice_id', 'source_prefix_id', 'role'
            )
        }
        Assert-ExactProperties $record $expectedProperties `
            "recipe '$RecipeName' component closure record"
        [void](Get-ContainedPath ([IO.Path]::GetTempPath()) $record.relative_path `
            "recipe '$RecipeName' component closure record")
        Assert-LowercaseHash $record.sha256 "recipe '$RecipeName' component closure record sha256"
        if ($record.git_blob -isnot [string] -or $record.git_blob -cnotmatch '^[0-9a-f]{40}$') {
            throw "Recipe '$RecipeName' component closure record has an invalid Git blob."
        }
        $bytes = Assert-UnsignedInteger $record.bytes `
            "recipe '$RecipeName' component closure record bytes"
        if ($bytes -gt $script:HardMaximumFileBytes -or
            [UInt64]::MaxValue - $aggregateBytes -lt $bytes -or
            $aggregateBytes + $bytes -gt $script:HardMaximumAggregateBytes) {
            throw "Recipe '$RecipeName' component source exceeds derived-source size bounds."
        }
        $aggregateBytes += $bytes
        [void]$records.Add([pscustomobject]@{
            RelativePath = [string]$record.relative_path
            GitBlob = [string]$record.git_blob
            Bytes = $bytes
            Sha256 = [string]$record.sha256
        })
    }
    if ($records.Count -eq 0 -or $records.Count -gt $script:HardMaximumFiles) {
        throw "Recipe '$RecipeName' component source has an invalid file count."
    }
    [object[]]$recordArray = @($records | ForEach-Object { $_ })
    Assert-PortableComponentPaths $recordArray "Recipe '$RecipeName' component source"
    $secondManifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($secondManifestHash -cne $manifestHash) {
        throw "Recipe '$RecipeName' component closure manifest changed during validation."
    }
    return [pscustomobject]@{
        ManifestPath = $manifestPath
        ManifestRelativePath = [string]$SourceSelection.closure_manifest
        ManifestHash = $manifestHash
        LockRoot = $LockRoot
        LockBinding = [pscustomobject]@{
            Name = [string]$LockedSource.name
            SourceDirectory = [string]$LockedSource.source_directory
            Repository = [string]$LockedSource.repository
            Commit = [string]$LockedSource.commit
            UpstreamLicense = [string]$LockedSource.upstream_license
            Disposition = [string]$LockedSource.disposition
            ClosureManifest = [string]$LockedSource.closure_manifest
            ClosureManifestSha256 = [string]$LockedSource.closure_manifest_sha256
            Scope = [string]$LockedSource.scope
        }
        Records = $recordArray
    }
}

function Copy-ComponentSource {
    param(
        [Parameter(Mandatory = $true)][string]$Checkout,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][object[]]$Records,
        [Parameter(Mandatory = $true)][string]$RecipeName
    )

    $validated = New-Object Collections.Generic.List[object]
    foreach ($record in $Records) {
        $literalPathspec = ":(top,literal)$($record.RelativePath)"
        $indexLines = @(Invoke-GitLines $Checkout @(
            'ls-files', '--cached', '--stage', '--', $literalPathspec
        ))
        if ($indexLines.Count -ne 1 -or
            $indexLines[0] -notmatch '^(?<mode>[0-9]{6}) (?<hash>[0-9a-f]{40}) 0\t(?<path>.+)$' -or
            $Matches.mode -notin @('100644', '100755') -or
            $Matches.path -cne $record.RelativePath -or
            $Matches.hash -cne $record.GitBlob) {
            throw "Recipe '$RecipeName' component record '$($record.RelativePath)' is not its exact regular Git blob."
        }
        $typeLines = @(Invoke-GitLines $Checkout @('cat-file', '-t', $record.GitBlob))
        $lengthLines = @(Invoke-GitLines $Checkout @('cat-file', '-s', $record.GitBlob))
        [UInt64]$length = 0
        if ($typeLines.Count -ne 1 -or $typeLines[0] -cne 'blob' -or
            $lengthLines.Count -ne 1 -or
            -not [UInt64]::TryParse($lengthLines[0], [ref]$length) -or
            $length -ne $record.Bytes) {
            throw "Recipe '$RecipeName' component record '$($record.RelativePath)' failed Git type or size validation."
        }
        [void]$validated.Add($record)
    }
    foreach ($record in $validated) {
        $destinationPath = Get-ContainedPath $Destination $record.RelativePath `
            "recipe '$RecipeName' component destination"
        $destinationParent = Split-Path -Parent $destinationPath
        if (-not (Test-Path -LiteralPath $destinationParent -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $destinationParent -Force)
        }
        Copy-GitBlob -Checkout $Checkout -Hash $record.GitBlob `
            -Destination $destinationPath -ExpectedLength $record.Bytes
        $hash = (Get-FileHash -LiteralPath $destinationPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($hash -cne $record.Sha256) {
            throw "Recipe '$RecipeName' component record '$($record.RelativePath)' failed SHA-256 validation."
        }
    }
}

if ($PSBoundParameters.ContainsKey('DescribeTree')) {
    foreach ($conflictingParameter in @(
        'SourceRoot', 'OutputRoot', 'DescribeRecipe', 'RecipePlan', 'RecipeRoot', 'LockFile',
        'BeforePatchNormalization', 'BeforeCachedOverlayValidation',
        'BeforeFinalPublication'
    )) {
        if ($PSBoundParameters.ContainsKey($conflictingParameter)) {
            throw "DescribeTree cannot be combined with $conflictingParameter."
        }
    }
    if ([string]::IsNullOrWhiteSpace($DescribeTree)) {
        throw 'DescribeTree requires one existing tree root.'
    }
    $describedRoot = Get-FullPath $DescribeTree
    if (-not (Test-Path -LiteralPath $describedRoot -PathType Container)) {
        throw "Tree root not found: $describedRoot"
    }
    $firstDescription = Get-DerivedTreeDescriptor $describedRoot
    if ($null -ne $BeforeSecondScan) {
        & $BeforeSecondScan $describedRoot 'describe-tree'
    }
    $secondDescription = Get-DerivedTreeDescriptor $describedRoot
    Assert-DescriptorMatches $secondDescription $firstDescription 'Described tree second scan'
    [ordered]@{
        file_count = $secondDescription.FileCount
        directory_count = $secondDescription.DirectoryCount
        total_entries = $secondDescription.TotalEntries
        aggregate_bytes = $secondDescription.AggregateBytes
        maximum_file_bytes = $secondDescription.MaximumFileBytes
        maximum_path_bytes = $secondDescription.MaximumPathBytes
        digest_algorithm = 'retvrn99-file-tree-sha256-v1'
        sha256 = $secondDescription.Sha256
    } | ConvertTo-Json
    return
}

$describeRecipeMode = $PSBoundParameters.ContainsKey('DescribeRecipe')
if ($describeRecipeMode) {
    if ([string]::IsNullOrWhiteSpace($DescribeRecipe) -or
        $DescribeRecipe -cnotmatch '^[a-z0-9][a-z0-9-]*$') {
        throw 'DescribeRecipe requires one canonical recipe name.'
    }
    if ($PSBoundParameters.ContainsKey('OutputRoot')) {
        throw 'DescribeRecipe does not publish and cannot be combined with OutputRoot.'
    }
}
elseif ([string]::IsNullOrWhiteSpace($SourceRoot) -or
    [string]::IsNullOrWhiteSpace($OutputRoot)) {
    throw 'SourceRoot and OutputRoot are required for derived-source preparation.'
}
if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
    throw 'SourceRoot is required to describe a derived recipe.'
}

$planPath = Get-FullPath $RecipePlan
if (-not (Test-Path -LiteralPath $planPath -PathType Leaf)) {
    throw "Derived-source plan not found: $planPath"
}
$plan = Read-StrictJson $planPath
Assert-ExactProperties $plan @('_spdx', 'schema', 'status', 'reason', 'recipes') 'root'
$planSchema = Assert-UnsignedInteger $plan.schema 'schema'
if ($plan._spdx -cne 'GPL-3.0-only' -or $planSchema -notin @(2, 3)) {
    throw 'Unsupported or unlicensed derived-source plan.'
}
if ($plan.status -cnotin @('blocked', 'draft', 'ready') -or $plan.reason -isnot [string]) {
    throw 'Derived-source plan status or reason is invalid.'
}
if ($plan.status -eq 'blocked') {
    if ($plan.recipes -isnot [Array] -or
        [string]::IsNullOrWhiteSpace($plan.reason) -or @($plan.recipes).Count -ne 0) {
        throw 'A blocked derived-source plan must give one reason and no recipes.'
    }
    throw "Windows 98 derived-source preparation is blocked: $($plan.reason)"
}
if ($plan.status -eq 'draft' -and -not $describeRecipeMode) {
    throw "Windows 98 derived-source preparation is draft-only: $($plan.reason)"
}
if ($describeRecipeMode -and $plan.status -cne 'draft') {
    throw 'DescribeRecipe requires a draft derived-source plan.'
}
if ($plan.status -eq 'draft' -and [string]::IsNullOrWhiteSpace($plan.reason)) {
    throw 'A draft derived-source plan must give one nonempty reason.'
}
if ($plan.status -eq 'ready' -and $plan.reason.Length -ne 0) {
    throw 'A ready derived-source plan must have an empty reason.'
}
$recipes = @($plan.recipes)
if ($plan.recipes -isnot [Array]) {
    throw 'Derived-source plan recipes must be an array.'
}
if ($recipes.Count -eq 0 -or $recipes.Count -gt $script:HardMaximumRecipes) {
    throw 'A ready derived-source plan has an invalid recipe count.'
}
if ($describeRecipeMode) {
    $recipes = @($recipes | Where-Object { $_.name -ceq $DescribeRecipe })
    if ($recipes.Count -ne 1) {
        throw "Draft plan must contain exactly one recipe named '$DescribeRecipe'."
    }
}

$sourceRootPath = Get-FullPath $SourceRoot
$recipeRootPath = Get-FullPath $RecipeRoot
$outputRootPath = if ($describeRecipeMode) {
    Join-Path ([IO.Path]::GetTempPath()) (
        'retvrn99-win98-described-' + [Guid]::NewGuid().ToString('N')
    )
}
else {
    Get-FullPath $OutputRoot
}
$lockPath = Get-FullPath $LockFile
foreach ($requiredRoot in @($sourceRootPath, $recipeRootPath)) {
    if (-not (Test-Path -LiteralPath $requiredRoot -PathType Container)) {
        throw "Required derived-source root not found: $requiredRoot"
    }
    if (((Get-Item -LiteralPath $requiredRoot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Required derived-source root cannot be a reparse point: $requiredRoot"
    }
}
if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
    throw "Upstream lock not found: $lockPath"
}
if (Test-Path -LiteralPath $outputRootPath) {
    throw "Derived-source output already exists; refusing to overwrite it: $outputRootPath"
}
if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
    throw 'git is required for deterministic derived-source preparation.'
}

$authoritativeLockSnapshot = Read-UpstreamLockSnapshot $lockPath
$lockEntries = @($authoritativeLockSnapshot.Entries)
$lockByName = @{}
foreach ($entry in $lockEntries) {
    if ([string]::IsNullOrWhiteSpace([string]$entry.name) -or $lockByName.ContainsKey($entry.name)) {
        throw "Duplicate or empty upstream name '$($entry.name)'."
    }
    $lockByName[$entry.name] = $entry
}

$validatedRecipes = @()
$seenNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$seenDestinations = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$wholeSourceNames = [Collections.Generic.List[string]]::new()
$componentNames = [Collections.Generic.List[string]]::new()
[UInt64]$totalPatchBytes = 0
foreach ($recipe in $recipes) {
    $recipeProperties = @(
        'name', 'upstream_name', 'source_directory', 'destination_directory',
        'patches', 'overlays'
    )
    if ($planSchema -eq 3) {
        $recipeProperties += 'source_selection'
    }
    if (-not $describeRecipeMode) {
        $recipeProperties += 'output_tree'
    }
    Assert-ExactProperties $recipe $recipeProperties "recipe '$($recipe.name)'"
    if ($recipe.name -isnot [string] -or $recipe.name -cnotmatch '^[a-z0-9][a-z0-9-]*$' -or
        -not $seenNames.Add($recipe.name)) {
        throw "Invalid or duplicate derived-source recipe name '$($recipe.name)'."
    }
    if ($recipe.upstream_name -isnot [string] -or
        -not $lockByName.ContainsKey($recipe.upstream_name)) {
        throw "Recipe '$($recipe.name)' references an unknown upstream."
    }
    $lockedSource = $lockByName[$recipe.upstream_name]
    if ($recipe.source_directory -isnot [string] -or
        $recipe.source_directory -cne $lockedSource.source_directory) {
        throw "Recipe '$($recipe.name)' must reference its canonical source directory."
    }
    $sourceMode = 'whole-upstream'
    $componentDescriptor = $null
    if ($planSchema -eq 3) {
        if ($recipe.source_selection -isnot [psobject] -or
            $recipe.source_selection.mode -isnot [string]) {
            throw "Recipe '$($recipe.name)' has an invalid source selection."
        }
        $sourceMode = [string]$recipe.source_selection.mode
    }
    if ($sourceMode -ceq 'whole-upstream') {
        if ($planSchema -eq 3) {
            Assert-ExactProperties $recipe.source_selection @('mode') `
                "recipe '$($recipe.name)' whole-upstream source selection"
        }
        if ($lockedSource.disposition -cne 'planned') {
            throw "Recipe '$($recipe.name)' whole-upstream source is not planned."
        }
    }
    elseif ($sourceMode -ceq 'component-closure' -and $planSchema -eq 3) {
        if ($lockedSource.disposition -cne 'planned-component') {
            throw "Recipe '$($recipe.name)' component source is not planned-component."
        }
        $componentVerifier = Join-Path $PSScriptRoot 'verify-win98-component-closure.ps1'
        Invoke-WithIsolatedGitEnvironment {
            & $componentVerifier -SourceRoot $sourceRootPath -LockFile $lockPath `
                -SourceName @([string]$recipe.upstream_name)
        } | Out-Null
        $componentDescriptor = Get-ComponentClosureDescriptor `
            -LockedSource $lockedSource -SourceSelection $recipe.source_selection `
            -LockRoot (Split-Path -Parent $lockPath) -RecipeName $recipe.name
        $componentNames.Add([string]$recipe.upstream_name)
    }
    else {
        throw "Recipe '$($recipe.name)' has an unsupported source selection."
    }
    [void](Get-ContainedPath $sourceRootPath $recipe.source_directory "recipe '$($recipe.name)' source")
    Assert-PathComponentsAreNotReparsePoints $sourceRootPath $recipe.source_directory `
        "recipe '$($recipe.name)' source"
    [void](Get-ContainedPath $outputRootPath $recipe.destination_directory "recipe '$($recipe.name)' destination")
    foreach ($existingDestination in $seenDestinations) {
        if ($recipe.destination_directory.StartsWith(
                "$existingDestination/", [StringComparison]::OrdinalIgnoreCase
            ) -or
            $existingDestination.StartsWith(
                "$($recipe.destination_directory)/", [StringComparison]::OrdinalIgnoreCase
            )) {
            throw "Derived-source destinations cannot be ancestors or descendants of one another."
        }
    }
    if (-not $seenDestinations.Add($recipe.destination_directory)) {
        throw "Duplicate derived-source destination '$($recipe.destination_directory)'."
    }
    if ($recipe.patches -isnot [Array] -or $recipe.overlays -isnot [Array]) {
        throw "Recipe '$($recipe.name)' patches and overlays must be arrays."
    }
    $patches = @($recipe.patches)
    $overlays = @($recipe.overlays)
    if ($patches.Count -gt $script:HardMaximumPatches) {
        throw "Recipe '$($recipe.name)' has an invalid patch count."
    }
    if ($overlays.Count -gt $script:HardMaximumOverlays -or
        ($sourceMode -ceq 'whole-upstream' -and $patches.Count + $overlays.Count -eq 0)) {
        throw "Recipe '$($recipe.name)' must declare a bounded patch or overlay input."
    }
    $validatedPatches = @()
    $seenPatches = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    [UInt64]$normalizedPathCount = 0
    foreach ($patch in $patches) {
        Assert-ExactProperties $patch @(
            'relative_path', 'bytes', 'sha256', 'normalize_lf_paths'
        ) "recipe '$($recipe.name)' patch"
        Assert-LowercaseHash $patch.sha256 "recipe '$($recipe.name)' patch sha256"
        [UInt64]$expectedBytes = Assert-UnsignedInteger $patch.bytes "recipe '$($recipe.name)' patch bytes"
        if ($expectedBytes -eq 0 -or $expectedBytes -gt $script:HardMaximumPatchBytes -or
            $totalPatchBytes + $expectedBytes -gt $script:HardMaximumPatchBytes) {
            throw "Recipe '$($recipe.name)' patch bytes exceed hard bounds."
        }
        $totalPatchBytes += $expectedBytes
        $patchPath = Get-ContainedPath $recipeRootPath $patch.relative_path "recipe '$($recipe.name)' patch"
        if (-not $seenPatches.Add($patch.relative_path) -or
            -not (Test-Path -LiteralPath $patchPath -PathType Leaf)) {
            throw "Recipe '$($recipe.name)' has a duplicate or missing patch '$($patch.relative_path)'."
        }
        Assert-PathComponentsAreNotReparsePoints $recipeRootPath $patch.relative_path 'patch input'
        $patchItem = Get-Item -LiteralPath $patchPath -Force
        $patchHash = (Get-FileHash -LiteralPath $patchPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ([UInt64]$patchItem.Length -ne $expectedBytes -or $patchHash -cne $patch.sha256) {
            throw "Patch '$patchPath' failed its exact size or SHA-256 check."
        }
        if ($patch.normalize_lf_paths -isnot [Array]) {
            throw "Recipe '$($recipe.name)' patch normalize_lf_paths must be an array."
        }
        $normalizeLfPaths = @($patch.normalize_lf_paths)
        $normalizedPathCount += $normalizeLfPaths.Count
        if ($normalizedPathCount -gt $script:HardMaximumNormalizedPaths) {
            throw "Recipe '$($recipe.name)' has too many LF-normalization paths."
        }
        $seenNormalizePaths = [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase
        )
        foreach ($normalizePath in $normalizeLfPaths) {
            [void](Get-ContainedPath $outputRootPath $normalizePath `
                "recipe '$($recipe.name)' LF-normalization path")
            if (-not $seenNormalizePaths.Add($normalizePath)) {
                throw "Recipe '$($recipe.name)' patch has a duplicate LF-normalization path."
            }
        }
        $validatedPatches += [pscustomobject]@{
            Path = $patchPath
            RelativePath = [string]$patch.relative_path
            Bytes = $expectedBytes
            Sha256 = [string]$patch.sha256
            NormalizeLfPaths = [string[]]$normalizeLfPaths
        }
    }
    $validatedOverlays = @()
    $seenOverlays = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($overlay in $overlays) {
        Assert-ExactProperties $overlay @(
            'relative_path', 'destination_relative_path', 'replace_existing', 'tree'
        ) "recipe '$($recipe.name)' overlay"
        $overlayPath = Get-ContainedPath $recipeRootPath $overlay.relative_path "recipe '$($recipe.name)' overlay"
        if (-not $seenOverlays.Add($overlay.relative_path) -or
            -not (Test-Path -LiteralPath $overlayPath -PathType Container)) {
            throw "Recipe '$($recipe.name)' has a duplicate or missing overlay '$($overlay.relative_path)'."
        }
        Assert-PathComponentsAreNotReparsePoints $recipeRootPath $overlay.relative_path 'overlay input'
        if ($overlay.destination_relative_path -isnot [string]) {
            throw "Recipe '$($recipe.name)' has an invalid overlay destination."
        }
        if ($overlay.destination_relative_path -ne '.') {
            [void](Get-ContainedPath $outputRootPath $overlay.destination_relative_path "recipe '$($recipe.name)' overlay destination")
        }
        if ($overlay.replace_existing -isnot [bool]) {
            throw "Recipe '$($recipe.name)' overlay replace_existing must be Boolean."
        }
        Assert-ExactProperties $overlay.tree @(
            'file_count', 'directory_count', 'total_entries', 'aggregate_bytes',
            'maximum_file_bytes', 'maximum_path_bytes', 'digest_algorithm', 'sha256'
        ) "recipe '$($recipe.name)' overlay tree"
        if ($overlay.tree.digest_algorithm -cne 'retvrn99-file-tree-sha256-v1') {
            throw "Recipe '$($recipe.name)' overlay uses an unsupported tree digest."
        }
        Assert-LowercaseHash $overlay.tree.sha256 "recipe '$($recipe.name)' overlay tree sha256"
        $expectedOverlayTree = [pscustomobject]@{
            FileCount = Assert-UnsignedInteger $overlay.tree.file_count 'overlay.tree.file_count'
            DirectoryCount = Assert-UnsignedInteger $overlay.tree.directory_count 'overlay.tree.directory_count'
            TotalEntries = Assert-UnsignedInteger $overlay.tree.total_entries 'overlay.tree.total_entries'
            AggregateBytes = Assert-UnsignedInteger $overlay.tree.aggregate_bytes 'overlay.tree.aggregate_bytes'
            MaximumFileBytes = Assert-UnsignedInteger $overlay.tree.maximum_file_bytes 'overlay.tree.maximum_file_bytes'
            MaximumPathBytes = Assert-UnsignedInteger $overlay.tree.maximum_path_bytes 'overlay.tree.maximum_path_bytes'
            Sha256 = [string]$overlay.tree.sha256
        }
        if ($expectedOverlayTree.TotalEntries -ne $expectedOverlayTree.FileCount + $expectedOverlayTree.DirectoryCount -or
            $expectedOverlayTree.FileCount -eq 0 -or
            $expectedOverlayTree.FileCount -gt $script:HardMaximumFiles -or
            $expectedOverlayTree.DirectoryCount -gt $script:HardMaximumDirectories -or
            $expectedOverlayTree.TotalEntries -gt $script:HardMaximumEntries -or
            $expectedOverlayTree.AggregateBytes -gt $script:HardMaximumAggregateBytes -or
            $expectedOverlayTree.MaximumFileBytes -gt $script:HardMaximumFileBytes -or
            $expectedOverlayTree.MaximumFileBytes -gt $expectedOverlayTree.AggregateBytes -or
            $expectedOverlayTree.MaximumPathBytes -gt $script:HardMaximumPathBytes -or
            $totalPatchBytes + $expectedOverlayTree.AggregateBytes -gt $script:HardMaximumAggregateBytes) {
            throw "Recipe '$($recipe.name)' overlay-tree descriptor violates hard bounds."
        }
        $totalPatchBytes += $expectedOverlayTree.AggregateBytes
        $validatedOverlays += [pscustomobject]@{
            Path = $overlayPath
            DestinationRelativePath = [string]$overlay.destination_relative_path
            ReplaceExisting = [bool]$overlay.replace_existing
            ExpectedTree = $expectedOverlayTree
        }
    }
    $expectedTree = $null
    if (-not $describeRecipeMode) {
        Assert-ExactProperties $recipe.output_tree @(
            'file_count', 'directory_count', 'total_entries', 'aggregate_bytes',
            'maximum_file_bytes', 'maximum_path_bytes', 'digest_algorithm', 'sha256'
        ) "recipe '$($recipe.name)' output_tree"
        if ($recipe.output_tree.digest_algorithm -cne 'retvrn99-file-tree-sha256-v1') {
            throw "Recipe '$($recipe.name)' uses an unsupported tree digest."
        }
        Assert-LowercaseHash $recipe.output_tree.sha256 "recipe '$($recipe.name)' output_tree.sha256"
        $expectedTree = [pscustomobject]@{
            FileCount = Assert-UnsignedInteger $recipe.output_tree.file_count 'output_tree.file_count'
            DirectoryCount = Assert-UnsignedInteger $recipe.output_tree.directory_count 'output_tree.directory_count'
            TotalEntries = Assert-UnsignedInteger $recipe.output_tree.total_entries 'output_tree.total_entries'
            AggregateBytes = Assert-UnsignedInteger $recipe.output_tree.aggregate_bytes 'output_tree.aggregate_bytes'
            MaximumFileBytes = Assert-UnsignedInteger $recipe.output_tree.maximum_file_bytes 'output_tree.maximum_file_bytes'
            MaximumPathBytes = Assert-UnsignedInteger $recipe.output_tree.maximum_path_bytes 'output_tree.maximum_path_bytes'
            Sha256 = [string]$recipe.output_tree.sha256
        }
        if ($expectedTree.TotalEntries -ne $expectedTree.FileCount + $expectedTree.DirectoryCount -or
            $expectedTree.FileCount -eq 0 -or
            $expectedTree.FileCount -gt $script:HardMaximumFiles -or
            $expectedTree.DirectoryCount -gt $script:HardMaximumDirectories -or
            $expectedTree.TotalEntries -gt $script:HardMaximumEntries -or
            $expectedTree.AggregateBytes -gt $script:HardMaximumAggregateBytes -or
            $expectedTree.MaximumFileBytes -gt $script:HardMaximumFileBytes -or
            $expectedTree.MaximumFileBytes -gt $expectedTree.AggregateBytes -or
            $expectedTree.MaximumPathBytes -gt $script:HardMaximumPathBytes) {
            throw "Recipe '$($recipe.name)' output-tree descriptor violates hard bounds."
        }
    }
    if ($sourceMode -ceq 'whole-upstream') {
        $wholeSourceNames.Add([string]$recipe.upstream_name)
    }
    $validatedRecipes += [pscustomobject]@{
        Name = [string]$recipe.name
        SourceDirectory = [string]$recipe.source_directory
        DestinationDirectory = [string]$recipe.destination_directory
        SourceMode = $sourceMode
        Component = $componentDescriptor
        Patches = $validatedPatches
        Overlays = $validatedOverlays
        ExpectedTree = $expectedTree
    }
}

$sourceVerification = @()
if ($wholeSourceNames.Count -gt 0) {
    $sourceVerification = @(Invoke-WithIsolatedGitEnvironment {
        & (Join-Path $PSScriptRoot 'verify-win98-driver-sources.ps1') `
            -SourceRoot $sourceRootPath -LockFile $lockPath `
            -SourceName @($wholeSourceNames | Sort-Object -Unique)
    })
}
if (-not $describeRecipeMode) {
    $sourceVerification | Write-Output
}

$outputParent = Split-Path -Parent $outputRootPath
if (-not (Test-Path -LiteralPath $outputParent -PathType Container)) {
    [void](New-Item -ItemType Directory -Path $outputParent)
}
if (((Get-Item -LiteralPath $outputParent -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'The derived-source output parent cannot be a reparse point.'
}
$token = [Guid]::NewGuid().ToString('N')
$temporaryRoot = Join-Path $outputParent ('.retvrn99-derived-' + $token)
$temporaryPatchRoot = Join-Path $outputParent ('.retvrn99-patches-' + $token)
$temporaryRootCreated = $false
$temporaryPatchRootCreated = $false
$describedRecipe = $null
try {
    [void](New-Item -ItemType Directory -Path $temporaryRoot)
    $temporaryRootCreated = $true
    [void](New-Item -ItemType Directory -Path $temporaryPatchRoot)
    $temporaryPatchRootCreated = $true
    foreach ($recipe in $validatedRecipes) {
        $checkout = Get-ContainedPath $sourceRootPath $recipe.SourceDirectory "recipe '$($recipe.Name)' source"
        $destination = Get-ContainedPath $temporaryRoot $recipe.DestinationDirectory "recipe '$($recipe.Name)' destination"
        [void](New-Item -ItemType Directory -Path $destination)
        if ($recipe.SourceMode -ceq 'component-closure') {
            Copy-ComponentSource -Checkout $checkout -Destination $destination `
                -Records $recipe.Component.Records -RecipeName $recipe.Name
        }
        else {
            Copy-TrackedSource $checkout $destination
        }
        $patchIndex = 0
        foreach ($patch in $recipe.Patches) {
            $patchIndex++
            $cachedPatch = Join-Path $temporaryPatchRoot (
                '{0}-{1:D3}.patch' -f $recipe.Name, $patchIndex
            )
            [IO.File]::Copy($patch.Path, $cachedPatch, $false)
            $cachedItem = Get-Item -LiteralPath $cachedPatch
            $cachedHash = (Get-FileHash -LiteralPath $cachedPatch -Algorithm SHA256).Hash.ToLowerInvariant()
            if ([UInt64]$cachedItem.Length -ne $patch.Bytes -or $cachedHash -cne $patch.Sha256) {
                throw "Patch '$($patch.RelativePath)' changed while it was cached."
            }
            if ($null -ne $BeforePatchNormalization) {
                & $BeforePatchNormalization $destination $recipe.Name $patchIndex
            }
            foreach ($normalizePath in $patch.NormalizeLfPaths) {
                Convert-FileToCanonicalLf -Root $destination -RelativePath $normalizePath `
                    -Name "recipe '$($recipe.Name)' patch LF normalization"
            }
            if ($temporaryRoot.IndexOf([IO.Path]::PathSeparator) -ge 0) {
                throw 'The private derived root is unsafe for Git ceiling isolation.'
            }
            Invoke-WithIsolatedGitEnvironment -CeilingDirectory $temporaryRoot -Body {
                $locationPushed = $false
                try {
                    Push-Location $destination
                    $locationPushed = $true
                    & (Get-DerivedGitExecutable) -c core.autocrlf=false -c core.eol=lf apply `
                        --no-index --check --whitespace=nowarn -- $cachedPatch
                    if ($LASTEXITCODE -ne 0) {
                        throw "Patch '$($patch.RelativePath)' failed its dry-run check."
                    }
                    & (Get-DerivedGitExecutable) -c core.autocrlf=false -c core.eol=lf apply `
                        --no-index --whitespace=nowarn -- $cachedPatch
                    if ($LASTEXITCODE -ne 0) {
                        throw "Patch '$($patch.RelativePath)' failed to apply."
                    }
                }
                finally {
                    if ($locationPushed) { Pop-Location }
                }
            }
            [void](Get-DerivedTreeDescriptor $destination)
        }
        $overlayIndex = 0
        foreach ($overlay in $recipe.Overlays) {
            $overlayIndex++
            $firstOverlayTree = Get-DerivedTreeDescriptor $overlay.Path
            Assert-DescriptorMatches $firstOverlayTree $overlay.ExpectedTree "Recipe '$($recipe.Name)' overlay first scan"
            $cachedOverlay = Join-Path $temporaryPatchRoot (
                '{0}-overlay-{1:D3}' -f $recipe.Name, $overlayIndex
            )
            [void](New-Item -ItemType Directory -Path $cachedOverlay)
            Copy-OverlayTree $overlay.Path $cachedOverlay $false
            if ($null -ne $BeforeCachedOverlayValidation) {
                & $BeforeCachedOverlayValidation $cachedOverlay $overlay.Path $recipe.Name $overlayIndex
            }
            $cachedOverlayTree = Get-DerivedTreeDescriptor $cachedOverlay
            Assert-DescriptorMatches $cachedOverlayTree $overlay.ExpectedTree `
                "Recipe '$($recipe.Name)' cached overlay"
            $secondOverlayTree = Get-DerivedTreeDescriptor $overlay.Path
            Assert-DescriptorMatches $secondOverlayTree $overlay.ExpectedTree "Recipe '$($recipe.Name)' overlay second scan"
            $overlayDestination = if ($overlay.DestinationRelativePath -ceq '.') {
                $destination
            }
            else {
                Get-ContainedPath $destination $overlay.DestinationRelativePath "recipe '$($recipe.Name)' overlay destination"
            }
            if (-not (Test-Path -LiteralPath $overlayDestination -PathType Container)) {
                [void](New-Item -ItemType Directory -Path $overlayDestination -Force)
            }
            Copy-OverlayTree $cachedOverlay $overlayDestination $overlay.ReplaceExisting
        }
        Remove-EmptyDirectories $destination
        $firstTree = Get-DerivedTreeDescriptor $destination
        if (-not $describeRecipeMode) {
            Assert-DescriptorMatches $firstTree $recipe.ExpectedTree "Recipe '$($recipe.Name)' first scan"
        }
        if ($null -ne $BeforeSecondScan) {
            & $BeforeSecondScan $destination $recipe.Name
        }
        $secondTree = Get-DerivedTreeDescriptor $destination
        if ($describeRecipeMode) {
            Assert-DescriptorMatches $secondTree $firstTree "Recipe '$($recipe.Name)' description second scan"
            $describedRecipe = [ordered]@{
                recipe = $recipe.Name
                destination_directory = $recipe.DestinationDirectory
                output_tree = [ordered]@{
                    file_count = $secondTree.FileCount
                    directory_count = $secondTree.DirectoryCount
                    total_entries = $secondTree.TotalEntries
                    aggregate_bytes = $secondTree.AggregateBytes
                    maximum_file_bytes = $secondTree.MaximumFileBytes
                    maximum_path_bytes = $secondTree.MaximumPathBytes
                    digest_algorithm = 'retvrn99-file-tree-sha256-v1'
                    sha256 = $secondTree.Sha256
                }
            }
        }
        else {
            Assert-DescriptorMatches $secondTree $recipe.ExpectedTree "Recipe '$($recipe.Name)' second scan"
        }
    }
    $sourceVerification = @()
    if ($wholeSourceNames.Count -gt 0) {
        $sourceVerification = @(Invoke-WithIsolatedGitEnvironment {
            & (Join-Path $PSScriptRoot 'verify-win98-driver-sources.ps1') `
                -SourceRoot $sourceRootPath -LockFile $lockPath `
                -SourceName @($wholeSourceNames | Sort-Object -Unique)
        })
    }
    if (-not $describeRecipeMode) {
        $sourceVerification | Write-Output
        if ($null -ne $BeforeFinalPublication) {
            & $BeforeFinalPublication $temporaryRoot
        }
        if ($componentNames.Count -gt 0) {
            [object[]]$componentRecipes = @($validatedRecipes | Where-Object {
                $_.SourceMode -ceq 'component-closure'
            })
            Assert-ComponentInputsMatchSnapshots -LockPath $lockPath `
                -ExpectedLock $authoritativeLockSnapshot -Recipes $componentRecipes
            Invoke-WithIsolatedGitEnvironment {
                & (Join-Path $PSScriptRoot 'verify-win98-component-closure.ps1') `
                    -SourceRoot $sourceRootPath -LockFile $lockPath `
                    -SourceName @($componentNames | Sort-Object -Unique)
            } | Out-Null
            Assert-ComponentInputsMatchSnapshots -LockPath $lockPath `
                -ExpectedLock $authoritativeLockSnapshot -Recipes $componentRecipes
        }
        foreach ($recipe in $validatedRecipes) {
            $finalDestination = Get-ContainedPath $temporaryRoot $recipe.DestinationDirectory `
                "recipe '$($recipe.Name)' final destination"
            $finalTree = Get-DerivedTreeDescriptor $finalDestination
            Assert-DescriptorMatches $finalTree $recipe.ExpectedTree `
                "Recipe '$($recipe.Name)' final publication scan"
        }
        if ($componentNames.Count -gt 0) {
            Assert-ComponentInputsMatchSnapshots -LockPath $lockPath `
                -ExpectedLock $authoritativeLockSnapshot -Recipes $componentRecipes
        }
        if (Test-Path -LiteralPath $outputRootPath) {
            throw "Derived-source output appeared during preparation: $outputRootPath"
        }
        [IO.Directory]::Move($temporaryRoot, $outputRootPath)
        $temporaryRootCreated = $false
    }
}
finally {
    foreach ($cleanup in @(
        [pscustomobject]@{ Path = $temporaryRoot; Created = $temporaryRootCreated; Prefix = '.retvrn99-derived-' },
        [pscustomobject]@{ Path = $temporaryPatchRoot; Created = $temporaryPatchRootCreated; Prefix = '.retvrn99-patches-' }
    )) {
        if ($cleanup.Created -and
            (Test-Path -LiteralPath $cleanup.Path) -and
            (Split-Path -Parent $cleanup.Path) -ceq $outputParent -and
            (Split-Path -Leaf $cleanup.Path).StartsWith($cleanup.Prefix, [StringComparison]::Ordinal)) {
            Remove-PrivateTreeSafely $cleanup.Path $outputParent $cleanup.Prefix
        }
    }
}

if ($describeRecipeMode) {
    $describedRecipe | ConvertTo-Json -Depth 4
}
else {
    Write-Output "Prepared and verified $($validatedRecipes.Count) deterministic Windows 98 derived source trees."
}
