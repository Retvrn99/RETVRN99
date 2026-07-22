# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Vkd3dCheckout,

    [string]$ManifestPath,
    [string]$GitExe
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'vkd3d-shader-compiler-evidence.ps1')
$vkd3dUpdaterWasDotSourced = $MyInvocation.InvocationName -eq '.'

$script:PinnedCommit = '1b0924d12c18df03912a8876ed17fd017ce9308e'
$script:PinnedOrigin = 'https://gitlab.winehq.org/wine/vkd3d.git'
$script:ProcessTimeoutSeconds = 30
$script:MaximumGitOutputBytes = 1048576
$script:Utf8 = [Text.UTF8Encoding]::new($false, $true)

function Invoke-Vkd3dComponentClosureUpdaterInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Vkd3dCheckout,
        [string]$ManifestPath,
        [string]$GitExe,
        [Parameter(DontShow = $true)]
        [ValidateSet(
            'none',
            'bootstrap-after-marker',
            'cleanup-failure',
            'candidate-corrupt',
            'candidate-replace-exact',
            'promotion-destination-race',
            'promotion-backup-race',
            'forward-replace-partial',
            'rollback-replace-partial',
            'postpromotion-destination-race',
            'backup-replace-exact'
        )]
        [string]$TestFault = 'none'
    )

$checkoutInput = $Vkd3dCheckout
$manifestInput = $ManifestPath
$gitInput = $GitExe
try {
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $repoRoot `
        'drivers\win98\component-closures\vkd3d-shader.json'
}
$Vkd3dCheckout = [IO.Path]::GetFullPath($Vkd3dCheckout)
$ManifestPath = [IO.Path]::GetFullPath($ManifestPath)
if ([string]::IsNullOrWhiteSpace($GitExe)) {
    $gitCommand = Get-Command git.exe -CommandType Application `
        -ErrorAction Stop | Select-Object -First 1
    $GitExe = [IO.Path]::GetFullPath($gitCommand.Source)
    if ([IO.Path]::GetFileName(
            [IO.Path]::GetDirectoryName($GitExe)
        ) -ieq 'cmd') {
        $coreGit = [IO.Path]::GetFullPath((Join-Path `
            ([IO.Path]::GetDirectoryName(
                [IO.Path]::GetDirectoryName($GitExe)
            )) 'mingw64\bin\git.exe'))
        if ([IO.File]::Exists($coreGit)) { $GitExe = $coreGit }
    }
}
else { $GitExe = [IO.Path]::GetFullPath($GitExe) }
}
catch {
    $initializationText = Get-Vkd3dEvidenceSanitizedFailureText `
        $_.Exception @($checkoutInput, $manifestInput, $gitInput)
    throw [InvalidOperationException]::new(
        "vkd3d-shader updater initialization failed: $initializationText"
    )
}
$gitBin = [IO.Path]::GetDirectoryName($GitExe)
$privateTempParent = [IO.Path]::GetFullPath(
    [IO.Path]::GetTempPath()
).TrimEnd([char[]]'\/')
$privateTempRoot = Join-Path $privateTempParent (
    'retvrn99-vkd3d-updater-{0}' -f [Guid]::NewGuid().ToString('N')
)
$privateTempOwner = [Guid]::NewGuid().ToString('N')
$privateTempState = 'absent'
$privateTempOwnerLeaf = '.retvrn99-vkd3d-proof-owner'
$privateTempParentHandle = $null
$privateTempParentSnapshot = $null
$privateTempHandle = $null
$privateTempSnapshot = $null
$privateTempMarkerHandle = $null
$privateTempMarkerSnapshot = $null
$gitChildCount = 0
$manifestLeaf = [IO.Path]::GetFileName($ManifestPath)
$manifestDirectory = [IO.Path]::GetDirectoryName($ManifestPath)
$transactionId = [Guid]::NewGuid().ToString('N')
$candidatePath = Join-Path $manifestDirectory (
    ".$manifestLeaf.retvrn99-candidate-$transactionId"
)
$backupPath = Join-Path $manifestDirectory (
    ".$manifestLeaf.retvrn99-backup-$transactionId"
)
$discardPath = Join-Path $manifestDirectory (
    ".$manifestLeaf.retvrn99-discard-$transactionId"
)
$primaryError = $null
$cleanupErrors = [Collections.Generic.List[object]]::new()
$successOutput = $null
$manifestParentHandle = $null
$manifestParentSnapshot = $null
$originalManifestHandle = $null
$originalManifestSnapshot = $null
$candidateHandle = $null
$candidateCleanup = $null
$backupCleanup = $null
$discardCleanup = $null
$faultCleanup = $null
$preservedTransactionLeaf = $false
$transactionHandles = [Collections.Generic.List[object]]::new()

function Invoke-GitBytes {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [ValidateRange(1, 1048576)]
        [int]$MaximumBytes = $script:MaximumGitOutputBytes
    )

    [string[]]$gitArguments = @(
        '-c', "safe.directory=$Vkd3dCheckout", '-C', $Vkd3dCheckout
    ) + $Arguments
    $result = Invoke-Vkd3dEvidenceProcess -File $GitExe `
        -Arguments $gitArguments -WorkingDirectory $Vkd3dCheckout `
        -PathDirectories @($gitBin) -PrivateTemp $privateTempRoot `
        -Name 'Git command' -ChildCount ([ref]$gitChildCount) `
        -TimeoutSeconds $script:ProcessTimeoutSeconds `
        -MaximumOutputBytes $MaximumBytes -MaximumProcessTreeWidth 2
    if ($result.stderr.Length -ne 0) {
        throw 'Git command wrote unexpected standard error.'
    }
    return ,([byte[]]$result.stdout)
}

function Invoke-GitLines {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $bytes = Invoke-GitBytes $Arguments
    if ($bytes.Length -eq 0) {
        return @()
    }
    $text = $script:Utf8.GetString($bytes).TrimEnd("`r", "`n")
    if ($text.Length -eq 0) {
        return @()
    }
    return @($text -split "`n" | ForEach-Object { $_.TrimEnd("`r") })
}

function Get-Sha256 {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes
    )

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return (([BitConverter]::ToString($sha256.ComputeHash($Bytes))) `
            -replace '-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-OrdinalSortedStrings {
    param([Parameter(Mandatory = $true)][string[]]$Values)

    [string[]]$copy = @($Values)
    [Array]::Sort($copy, [StringComparer]::Ordinal)
    return @($copy)
}

function Get-OrdinalSortedRows {
    param([Parameter(Mandatory = $true)][object[]]$Rows)

    [object[]]$copy = @($Rows)
    $comparer = [Collections.Generic.Comparer[object]]::Create(
        [Comparison[object]]{
            param($left, $right)
            return [StringComparer]::Ordinal.Compare(
                [string]$left.relative_path,
                [string]$right.relative_path
            )
        }
    )
    [Array]::Sort($copy, $comparer)
    return @($copy)
}

function Test-ExactBytes {
    param(
        [Parameter(Mandatory = $true)][byte[]]$First,
        [Parameter(Mandatory = $true)][byte[]]$Second
    )

    if ($First.Length -ne $Second.Length) { return $false }
    for ($index = 0; $index -lt $First.Length; $index++) {
        if ($First[$index] -ne $Second[$index]) { return $false }
    }
    return $true
}

function Read-ManifestBytes {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $opened = Open-UpdaterStableFile $Path $Name 1048576
    try { [byte[]]$bytes = $opened.Snapshot.Bytes }
    finally { $opened.Handle.Dispose() }
    Assert-UpdaterManifestBytes $bytes $Name
    return ,$bytes
}

function Assert-UpdaterManifestBytes {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $bytes = $Bytes
    if ($bytes.Length -lt 2 -or $bytes.Length -gt 1048576) {
        throw "$Name is not bounded manifest text."
    }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and
        $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf) {
        throw "$Name has a UTF-8 BOM."
    }
    if ($bytes -contains [byte]0 -or $bytes -contains [byte]13 -or
        $bytes[$bytes.Length - 1] -ne [byte]10) {
        throw "$Name is not canonical LF text."
    }
}

function Initialize-UpdaterNative {
    Initialize-Vkd3dEvidenceNative
    if ($null -eq ('Retvrn99.Vkd3dEvidenceNative' -as [type])) {
        throw 'Updater native isolation is unavailable.'
    }
}

function Get-UpdaterHandleSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [Microsoft.Win32.SafeHandles.SafeFileHandle]$Handle,
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$Directory,
        [UInt64]$MaximumBytes = [UInt64]1048576
    )

    if ($Handle.IsInvalid -or $Handle.IsClosed) {
        throw "$Name handle is not usable."
    }
    $attributes = [UInt32][Retvrn99.Vkd3dEvidenceNative]::GetAttributes($Handle)
    $isDirectory = ($attributes -band [UInt32]0x10) -ne 0
    if (($attributes -band [UInt32]0x440) -ne 0 -or
        $isDirectory -ne [bool]$Directory) {
        throw "$Name handle has an unsafe file type."
    }
    $identity = [Retvrn99.Vkd3dEvidenceNative]::GetFileIdentity($Handle)
    [byte[]]$bytes = if ($Directory) { @() }
        else { [Retvrn99.Vkd3dEvidenceNative]::ReadAll($Handle, $MaximumBytes) }
    $observedAttributes =
        [UInt32][Retvrn99.Vkd3dEvidenceNative]::GetAttributes($Handle)
    $observedIdentity =
        [Retvrn99.Vkd3dEvidenceNative]::GetFileIdentity($Handle)
    if ($observedAttributes -ne $attributes -or
        $observedIdentity -cne $identity) {
        throw "$Name handle identity changed."
    }
    return [pscustomobject][ordered]@{
        Identity = $identity
        Attributes = $attributes
        Bytes = $bytes
    }
}

function Test-UpdaterSameSnapshot {
    param(
        [Parameter(Mandatory = $true)][object]$First,
        [Parameter(Mandatory = $true)][object]$Second,
        [switch]$Directory
    )

    if ([string]$First.Identity -cne [string]$Second.Identity -or
        [UInt32]$First.Attributes -ne [UInt32]$Second.Attributes) {
        return $false
    }
    if (-not $Directory -and
        -not (Test-ExactBytes ([byte[]]$First.Bytes) ([byte[]]$Second.Bytes))) {
        return $false
    }
    return $true
}

function Open-UpdaterStableFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [UInt64]$MaximumBytes = [UInt64]1048576
    )

    $handle = [Retvrn99.Vkd3dEvidenceNative]::OpenStableFile($Path)
    try {
        $snapshot = Get-UpdaterHandleSnapshot $handle $Name `
            -MaximumBytes $MaximumBytes
        return [pscustomobject][ordered]@{
            Handle = $handle
            Snapshot = $snapshot
        }
    }
    catch {
        $handle.Dispose()
        throw
    }
}

function Open-UpdaterStableDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $handle = [Retvrn99.Vkd3dEvidenceNative]::OpenStableDirectory($Path)
    try {
        $snapshot = Get-UpdaterHandleSnapshot $handle $Name -Directory
        return [pscustomobject][ordered]@{
            Handle = $handle
            Snapshot = $snapshot
        }
    }
    catch {
        $handle.Dispose()
        throw
    }
}

function Assert-UpdaterParentPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Expected,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $opened = Open-UpdaterStableDirectory $Path $Name
    try {
        if (-not (Test-UpdaterSameSnapshot $opened.Snapshot $Expected `
                -Directory)) {
            throw "$Name path identity changed."
        }
    }
    finally { $opened.Handle.Dispose() }
}

function Assert-UpdaterHeldDirectoryPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Expected,
        [Parameter(Mandatory = $true)]
        [Microsoft.Win32.SafeHandles.SafeFileHandle]$Handle,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $snapshot = Get-UpdaterHandleSnapshot $Handle $Name -Directory
    $finalPath = [Retvrn99.Vkd3dEvidenceNative]::GetFinalPath($Handle)
    if (-not (Test-UpdaterSameSnapshot $snapshot $Expected -Directory) -or
        -not $finalPath.Equals(
            [IO.Path]::GetFullPath($Path),
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw "$Name path identity changed."
    }
}

function Assert-UpdaterDirectChild {
    param(
        [Parameter(Mandatory = $true)][string]$Parent,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $parentFull = [IO.Path]::GetFullPath($Parent)
    $full = [IO.Path]::GetFullPath($Path)
    if (-not [IO.Path]::GetDirectoryName($full).Equals(
            $parentFull,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw "$Name is not a direct child of its parent."
    }
}

function New-UpdaterOwnedLeaf {
    param(
        [Parameter(Mandatory = $true)][string]$Parent,
        [Parameter(Mandatory = $true)][object]$ParentSnapshot,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][string]$Name,
        [Microsoft.Win32.SafeHandles.SafeFileHandle]$PinnedParentHandle
    )

    Assert-UpdaterDirectChild $Parent $Path $Name
    if ($null -eq $PinnedParentHandle) {
        Assert-UpdaterParentPath $Parent $ParentSnapshot "$Name parent"
    }
    else {
        Assert-UpdaterHeldDirectoryPath $Parent $ParentSnapshot `
            $PinnedParentHandle "$Name parent"
    }
    if ($null -ne (Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue) -or
        [IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path)) {
        throw "$Name was not fresh."
    }
    $handle = [Retvrn99.Vkd3dEvidenceNative]::CreateOwnedFile($Path)
    try {
        [Retvrn99.Vkd3dEvidenceNative]::WriteAll($handle, $Bytes)
        $snapshot = Get-UpdaterHandleSnapshot $handle $Name `
            -MaximumBytes ([UInt64][Math]::Max($Bytes.Length, 1))
        if (-not (Test-ExactBytes $Bytes ([byte[]]$snapshot.Bytes))) {
            throw "$Name write verification failed."
        }
        if ($null -eq $PinnedParentHandle) {
            Assert-UpdaterParentPath $Parent $ParentSnapshot "$Name parent"
        }
        else {
            Assert-UpdaterHeldDirectoryPath $Parent $ParentSnapshot `
                $PinnedParentHandle "$Name parent"
        }
        return [pscustomobject][ordered]@{
            Path = [IO.Path]::GetFullPath($Path)
            Handle = $handle
            Snapshot = $snapshot
        }
    }
    catch {
        $creationError = $_.Exception
        $secondary = [Collections.Generic.List[Exception]]::new()
        try { [Retvrn99.Vkd3dEvidenceNative]::MarkDelete($handle) }
        catch { [void]$secondary.Add($_.Exception) }
        try { $handle.Dispose() }
        catch { [void]$secondary.Add($_.Exception) }
        if ($secondary.Count -ne 0) {
            $failures = [Collections.Generic.List[Exception]]::new()
            [void]$failures.Add($creationError)
            foreach ($failure in $secondary) { [void]$failures.Add($failure) }
            throw [AggregateException]::new(
                "$Name creation and cleanup both failed.",
                [Exception[]]$failures.ToArray()
            )
        }
        throw $creationError
    }
}

function Remove-UpdaterOwnedLeaf {
    param(
        [Parameter(Mandatory = $true)][string]$Parent,
        [Parameter(Mandatory = $true)][object]$ParentSnapshot,
        [Parameter(Mandatory = $true)][object]$Owned,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $path = [string]$Owned.Path
    Assert-UpdaterDirectChild $Parent $path $Name
    Assert-UpdaterParentPath $Parent $ParentSnapshot "$Name parent"
    if ($null -eq (Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue)) {
        if ([IO.File]::Exists($path) -or [IO.Directory]::Exists($path)) {
            throw "$Name has an unreadable path identity."
        }
        return
    }
    $handle = [Retvrn99.Vkd3dEvidenceNative]::OpenDeleteHandle($path)
    try {
        $snapshot = Get-UpdaterHandleSnapshot $handle $Name `
            -MaximumBytes ([UInt64][Math]::Max(
                ([byte[]]$Owned.Snapshot.Bytes).Length,
                1
            ))
        if (-not (Test-UpdaterSameSnapshot $snapshot $Owned.Snapshot)) {
            throw "$Name no longer has its owned identity and bytes."
        }
        [Retvrn99.Vkd3dEvidenceNative]::MarkDelete($handle)
    }
    finally { $handle.Dispose() }
    Assert-UpdaterParentPath $Parent $ParentSnapshot "$Name parent"
    if ($null -ne (Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue) -or
        [IO.File]::Exists($path) -or [IO.Directory]::Exists($path)) {
        throw "$Name survived handle-gated cleanup."
    }
}

function Remove-UpdaterOwnedTreeEntries {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$SkipPath,
        [Parameter(Mandatory = $true)][ref]$EntryCount,
        [Parameter(Mandatory = $true)][ref]$DirectoryCount,
        [Parameter(Mandatory = $true)][ref]$AggregateBytes
    )

    foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($Path)) {
        $full = [IO.Path]::GetFullPath($entry)
        if ($full.Equals($SkipPath, [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        $EntryCount.Value++
        if ($EntryCount.Value -gt 4096) {
            throw 'Owned Git temporary root exceeds its cleanup entry bound.'
        }
        $handle = [Retvrn99.Vkd3dEvidenceNative]::OpenDeleteHandle($full)
        try {
            $attributes =
                [UInt32][Retvrn99.Vkd3dEvidenceNative]::GetAttributes($handle)
            if (($attributes -band [UInt32]0x440) -ne 0) {
                throw 'Owned Git temporary root contains an unsafe entry.'
            }
            if (($attributes -band [UInt32]0x10) -ne 0) {
                $DirectoryCount.Value++
                if ($DirectoryCount.Value -gt 512) {
                    throw 'Owned Git temporary root exceeds its directory bound.'
                }
                Remove-UpdaterOwnedTreeEntries $full $SkipPath $EntryCount `
                    $DirectoryCount $AggregateBytes
            }
            else {
                [UInt64]$length = [UInt64]([IO.FileInfo]::new($full).Length)
                if ($length -gt 268435456) {
                    throw 'Owned Git temporary root contains an oversized file.'
                }
                $AggregateBytes.Value += $length
                if ($AggregateBytes.Value -gt 1073741824) {
                    throw 'Owned Git temporary root exceeds its cleanup byte bound.'
                }
            }
            [Retvrn99.Vkd3dEvidenceNative]::MarkDelete($handle)
        }
        finally { $handle.Dispose() }
    }
}

function Remove-UpdaterPrivateTempRoot {
    if ($null -eq $privateTempHandle -or $null -eq $privateTempSnapshot) {
        throw 'Owned Git temporary root lacks its exclusive handle.'
    }
    Assert-UpdaterParentPath $privateTempParent $privateTempParentSnapshot `
        'Owned Git temporary parent'
    Assert-UpdaterHeldDirectoryPath $privateTempRoot $privateTempSnapshot `
        $privateTempHandle 'Owned Git temporary root'

    $ownerPath = Join-Path $privateTempRoot $privateTempOwnerLeaf
    if ($null -eq $privateTempMarkerHandle) {
        if (@([IO.Directory]::EnumerateFileSystemEntries($privateTempRoot)).Count `
            -ne 0) {
            throw 'Unowned bootstrap entries were preserved.'
        }
    }
    else {
        $markerSnapshot = Get-UpdaterHandleSnapshot $privateTempMarkerHandle `
            'Owned Git temporary marker' -MaximumBytes 256
        if (-not (Test-UpdaterSameSnapshot $markerSnapshot `
                $privateTempMarkerSnapshot)) {
            throw 'Owned Git temporary marker identity changed.'
        }
        [UInt64]$entryCount = 0
        [UInt64]$directoryCount = 0
        [UInt64]$aggregateBytes = 0
        Remove-UpdaterOwnedTreeEntries $privateTempRoot `
            ([IO.Path]::GetFullPath($ownerPath)) ([ref]$entryCount) `
            ([ref]$directoryCount) ([ref]$aggregateBytes)
        [Retvrn99.Vkd3dEvidenceNative]::MarkDelete($privateTempMarkerHandle)
        $privateTempMarkerHandle.Dispose()
        Set-Variable -Name privateTempMarkerHandle -Scope 1 -Value $null
        if (@([IO.Directory]::EnumerateFileSystemEntries($privateTempRoot)).Count `
            -ne 0) {
            throw 'Owned Git temporary root was not empty after cleanup.'
        }
    }
    [Retvrn99.Vkd3dEvidenceNative]::MarkDelete($privateTempHandle)
    $privateTempHandle.Dispose()
    Set-Variable -Name privateTempHandle -Scope 1 -Value $null
    Assert-UpdaterParentPath $privateTempParent $privateTempParentSnapshot `
        'Owned Git temporary parent'
    if ($null -ne (Get-Item -LiteralPath $privateTempRoot -Force `
            -ErrorAction SilentlyContinue) -or
        [IO.File]::Exists($privateTempRoot) -or
        [IO.Directory]::Exists($privateTempRoot)) {
        throw 'Owned Git temporary root survived handle-gated cleanup.'
    }
}

function Find-ByteSequence {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Content,
        [Parameter(Mandatory = $true)][byte[]]$Sequence,
        [int]$Start = 0
    )

    if ($Sequence.Length -eq 0) {
        throw 'An empty byte marker is not supported.'
    }
    for ($offset = $Start;
        $offset -le $Content.Length - $Sequence.Length;
        $offset++) {
        $match = $true
        for ($index = 0; $index -lt $Sequence.Length; $index++) {
            if ($Content[$offset + $index] -ne $Sequence[$index]) {
                $match = $false
                break
            }
        }
        if ($match) {
            return $offset
        }
    }
    return -1
}

function Find-LastByteSequence {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Content,
        [Parameter(Mandatory = $true)][byte[]]$Sequence,
        [Parameter(Mandatory = $true)][int]$Before
    )

    $last = -1
    $offset = Find-ByteSequence $Content $Sequence 0
    while ($offset -ge 0 -and $offset -lt $Before) {
        $last = $offset
        $offset = Find-ByteSequence $Content $Sequence ($offset + 1)
    }
    return $last
}

function Get-UniqueMarkerOffset {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Content,
        [Parameter(Mandatory = $true)][string]$Marker,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    $sequence = [Text.Encoding]::ASCII.GetBytes($Marker)
    $first = Find-ByteSequence $Content $sequence 0
    if ($first -lt 0 -or
        (Find-ByteSequence $Content $sequence ($first + 1)) -ge 0) {
        throw "Pinned input '$RelativePath' must contain exactly one '$Marker' marker."
    }
    return $first
}

function New-RangeDescriptor {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Content,
        [Parameter(Mandatory = $true)][int]$Offset,
        [Parameter(Mandatory = $true)][int]$Count
    )

    if ($Offset -lt 0 -or $Count -le 0 -or
        $Offset + $Count -gt $Content.Length) {
        throw 'Invalid license evidence range.'
    }
    $range = New-Object byte[] $Count
    [Array]::Copy($Content, $Offset, $range, 0, $Count)
    return [pscustomobject]@{
        Offset = [UInt64]$Offset
        Count = [UInt64]$Count
        Sha256 = Get-Sha256 $range
    }
}

function Get-CCommentRange {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Content,
        [Parameter(Mandatory = $true)][string]$Marker,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [switch]$AllowRepeatedMarker
    )

    $markerBytes = [Text.Encoding]::ASCII.GetBytes($Marker)
    $markerOffset = Find-ByteSequence $Content $markerBytes 0
    $nextMarker = if ($markerOffset -ge 0) {
        Find-ByteSequence $Content $markerBytes ($markerOffset + 1)
    }
    else {
        -1
    }
    if ($markerOffset -lt 0 -or
        (-not $AllowRepeatedMarker -and $nextMarker -ge 0)) {
        throw "Pinned input '$RelativePath' has an unexpected '$Marker' marker count."
    }
    $open = [Text.Encoding]::ASCII.GetBytes('/*')
    $close = [Text.Encoding]::ASCII.GetBytes('*/')
    $start = Find-LastByteSequence $Content $open ($markerOffset + 1)
    $priorEnd = Find-LastByteSequence $Content $close ($markerOffset + 1)
    $end = Find-ByteSequence $Content $close $markerOffset
    if ($start -lt 0 -or $start -le $priorEnd -or $end -lt 0) {
        throw "Pinned input '$RelativePath' has malformed license evidence."
    }
    while ($nextMarker -ge 0) {
        if ($nextMarker -ge $end) {
            throw "Pinned input '$RelativePath' has split repeated license evidence."
        }
        $nextMarker = Find-ByteSequence $Content $markerBytes ($nextMarker + 1)
    }
    return New-RangeDescriptor $Content $start ($end + 2 - $start)
}

function Get-HashCommentRange {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Content,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    [void](Get-UniqueMarkerOffset $Content `
        'This library is free software' $RelativePath)
    $firstLineEnd = Find-ByteSequence $Content @([byte]0x0a) 0
    $blockEnd = Find-ByteSequence $Content @([byte]0x0a, [byte]0x0a) `
        ($firstLineEnd + 1)
    if ($firstLineEnd -lt 0 -or $blockEnd -lt 0) {
        throw "Pinned input '$RelativePath' has malformed hash-comment evidence."
    }
    return New-RangeDescriptor $Content ($firstLineEnd + 1) `
        ($blockEnd - ($firstLineEnd + 1))
}

function Get-GrammarLicenseRange {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Content,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    [void](Get-UniqueMarkerOffset $Content `
        'Permission is hereby granted' $RelativePath)
    $startMarker = [Text.Encoding]::ASCII.GetBytes('  "copyright" : [')
    $endMarker = [Text.Encoding]::ASCII.GetBytes(
        "`n  ],`n  `"magic_number`""
    )
    $start = Find-ByteSequence $Content $startMarker 0
    $end = Find-ByteSequence $Content $endMarker $start
    if ($start -lt 0 -or $end -lt 0) {
        throw "Pinned input '$RelativePath' has malformed grammar-license evidence."
    }
    return New-RangeDescriptor $Content $start ($end + 4 - $start)
}

function Get-MakeVariablePaths {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $lines = @($Text -split "`n" | ForEach-Object { $_.TrimEnd("`r") })
    $header = "$Name = \"
    $start = [Array]::IndexOf($lines, $header)
    if ($start -lt 0) {
        throw "Pinned Makefile.am lacks the exact '$Name' assignment."
    }
    $paths = [Collections.Generic.List[string]]::new()
    for ($index = $start + 1; $index -lt $lines.Count; $index++) {
        $line = $lines[$index].Trim()
        $continued = $line.EndsWith('\', [StringComparison]::Ordinal)
        if ($continued) {
            $line = $line.Substring(0, $line.Length - 1).TrimEnd()
        }
        if ($line -notmatch '^[A-Za-z0-9_./-]+$') {
            throw "Pinned Makefile.am has a malformed '$Name' path."
        }
        [void]$paths.Add($line)
        if (-not $continued) {
            return @($paths)
        }
    }
    throw "Pinned Makefile.am has an unterminated '$Name' assignment."
}

function Assert-SameOrdinalSet {
    param(
        [Parameter(Mandatory = $true)][string[]]$Actual,
        [Parameter(Mandatory = $true)][string[]]$Expected,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $actualSorted = @(Get-OrdinalSortedStrings $Actual)
    $expectedSorted = @(Get-OrdinalSortedStrings $Expected)
    if ($actualSorted.Count -ne $expectedSorted.Count -or
        ($actualSorted -join "`n") -cne ($expectedSorted -join "`n")) {
        throw "$Name changed. Observed '$($actualSorted -join ', ')'."
    }
}

function Get-CompactManifestBytes {
    param([Parameter(Mandatory = $true)][object]$Manifest)

    $builder = [Text.StringBuilder]::new()
    [void]$builder.AppendLine('{')
    foreach ($name in @(
        '_spdx', 'schema', 'status', 'reason', 'upstream_name', 'owning_commit'
    )) {
        $json = $Manifest.$name | ConvertTo-Json -Compress
        [void]$builder.AppendLine("  `"$name`": $json,")
    }
    foreach ($section in @('source_prefixes', 'license_evidence', 'files')) {
        [void]$builder.AppendLine("  `"$section`": [")
        $rows = @($Manifest.$section)
        for ($index = 0; $index -lt $rows.Count; $index++) {
            $suffix = if ($index + 1 -lt $rows.Count) { ',' } else { '' }
            $json = $rows[$index] | ConvertTo-Json -Depth 16 -Compress
            [void]$builder.AppendLine("    $json$suffix")
        }
        $suffix = if ($section -cne 'files') { ',' } else { '' }
        [void]$builder.AppendLine("  ]$suffix")
    }
    [void]$builder.AppendLine('}')
    [byte[]]$bytes = $script:Utf8.GetBytes(
        $builder.ToString().Replace("`r`n", "`n")
    )
    return ,$bytes
}

function Set-UpdaterTestReplacement {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $leaf = [IO.Path]::GetFileName($Path)
    $faultPath = Join-Path $manifestDirectory (
        ".$leaf.retvrn99-fault-{0}" -f [Guid]::NewGuid().ToString('N')
    )
    $owned = New-UpdaterOwnedLeaf $manifestDirectory `
        $manifestParentSnapshot $faultPath $Bytes "$Name input"
    try {
        $owned.Handle.Dispose()
        [IO.File]::Move($faultPath, $Path, $true)
        Assert-UpdaterParentPath $manifestDirectory $manifestParentSnapshot `
            "$Name parent"
    }
    catch {
        try {
            Remove-UpdaterOwnedLeaf $manifestDirectory `
                $manifestParentSnapshot $owned "$Name input"
        }
        catch { }
        throw
    }
}

function Get-UpdaterLeafState {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        if ([IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path)) {
            return [pscustomobject]@{
                Kind = 'unknown'
                Snapshot = $null
                Error = [InvalidOperationException]::new(
                    "$Name has an unreadable path identity."
                )
            }
        }
        return [pscustomobject]@{
            Kind = 'absent'
            Snapshot = $null
            Error = $null
        }
    }
    try {
        $opened = Open-UpdaterStableFile $Path $Name 1048576
        try { $snapshot = $opened.Snapshot }
        finally { $opened.Handle.Dispose() }
        return [pscustomobject]@{
            Kind = 'file'
            Snapshot = $snapshot
            Error = $null
        }
    }
    catch {
        return [pscustomobject]@{
            Kind = 'unknown'
            Snapshot = $null
            Error = $_.Exception
        }
    }
}

function Test-UpdaterLeafSnapshot {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object]$Expected
    )

    return $State.Kind -ceq 'file' -and
        (Test-UpdaterSameSnapshot $State.Snapshot $Expected)
}

function Test-UpdaterLeafIdentityAndBytes {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object]$Expected
    )

    return $State.Kind -ceq 'file' -and
        [string]$State.Snapshot.Identity -ceq [string]$Expected.Identity -and
        (Test-ExactBytes ([byte[]]$State.Snapshot.Bytes) `
            ([byte[]]$Expected.Bytes))
}

function New-UpdaterTransactionAggregate {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][Exception[]]$Failures
    )

    $privateRoots = @(
        $Vkd3dCheckout,
        $ManifestPath,
        $privateTempRoot,
        $candidatePath,
        $backupPath,
        $discardPath
    )
    $sanitized = [Collections.Generic.List[Exception]]::new()
    foreach ($failure in $Failures) {
        [Exception[]]$leaves = if ($failure -is [AggregateException]) {
            @($failure.Flatten().InnerExceptions)
        }
        else { @($failure) }
        foreach ($leaf in $leaves) {
            $detail = Get-Vkd3dEvidenceSanitizedFailureText `
                $leaf $privateRoots
            [void]$sanitized.Add([InvalidOperationException]::new($detail))
        }
    }
    return [AggregateException]::new(
        $Message,
        [Exception[]]$sanitized.ToArray()
    )
}

function Invoke-UpdaterMissingTargetRestoreInternal {
    param(
        [Parameter(Mandatory = $true)][object]$ExpectedTarget,
        [Parameter(Mandatory = $true)][object]$ExpectedBackup
    )

    $failures = [Collections.Generic.List[Exception]]::new()
    $moveFailure = $null
    $canMove = $true
    try {
        Assert-UpdaterParentPath $manifestDirectory $manifestParentSnapshot `
            'Missing-target recovery parent'
        Assert-UpdaterDirectChild $manifestDirectory $ManifestPath `
            'Missing-target recovery destination'
        Assert-UpdaterDirectChild $manifestDirectory $backupPath `
            'Missing-target recovery backup'
    }
    catch {
        [void]$failures.Add($_.Exception)
        $canMove = $false
    }

    $targetBefore = Get-UpdaterLeafState $ManifestPath `
        'Missing-target recovery destination'
    $backupBefore = Get-UpdaterLeafState $backupPath `
        'Missing-target recovery backup'
    foreach ($state in @($targetBefore, $backupBefore)) {
        if ($null -ne $state.Error) { [void]$failures.Add($state.Error) }
    }
    if ($targetBefore.Kind -cne 'absent' -or
        -not (Test-UpdaterLeafSnapshot $backupBefore $ExpectedBackup)) {
        [void]$failures.Add([InvalidOperationException]::new(
            'Missing-target recovery input was not the exact expected layout.'
        ))
        $canMove = $false
    }

    if ($canMove) {
        try { [IO.File]::Move($backupPath, $ManifestPath, $false) }
        catch { $moveFailure = $_.Exception }
    }

    try {
        Assert-UpdaterParentPath $manifestDirectory $manifestParentSnapshot `
            'Post-recovery manifest parent'
    }
    catch { [void]$failures.Add($_.Exception) }
    $targetAfter = Get-UpdaterLeafState $ManifestPath `
        'Post-recovery component manifest'
    $backupAfter = Get-UpdaterLeafState $backupPath `
        'Post-recovery backup'
    foreach ($state in @($targetAfter, $backupAfter)) {
        if ($null -ne $state.Error) { [void]$failures.Add($state.Error) }
    }
    $restored = Test-UpdaterLeafIdentityAndBytes `
        $targetAfter $ExpectedTarget
    $backupConsumed = $backupAfter.Kind -ceq 'absent'
    $noMapping = $targetAfter.Kind -ceq 'absent' -and
        (Test-UpdaterLeafSnapshot $backupAfter $ExpectedBackup)
    if (-not ($restored -and $backupConsumed) -and -not $noMapping) {
        [void]$failures.Add([InvalidOperationException]::new(
            'Missing-target recovery was not an exact pre-move or post-move layout.'
        ))
    }

    return [pscustomobject]@{
        Restored = $restored -and $backupConsumed
        NoMapping = $noMapping
        PreserveBackup = $backupAfter.Kind -cne 'absent'
        MoveFailure = $moveFailure
        ReconciliationFailures = [Exception[]]$failures.ToArray()
    }
}

function Invoke-UpdaterRollbackReplaceInternal {
    param(
        [Parameter(Mandatory = $true)][object]$ExpectedBackup,
        [Parameter(Mandatory = $true)][object]$CurrentTarget,
        [Parameter(Mandatory = $true)][bool]$CurrentTargetOwned,
        [switch]$InjectPartialFailure
    )

    Assert-UpdaterParentPath $manifestDirectory $manifestParentSnapshot `
        'Immediate pre-rollback manifest parent'
    Assert-UpdaterDirectChild $manifestDirectory $backupPath `
        'Immediate pre-rollback backup'
    Assert-UpdaterDirectChild $manifestDirectory $discardPath `
        'Immediate pre-rollback discard'
    $candidateBefore = Get-UpdaterLeafState $candidatePath `
        'Immediate pre-rollback candidate'
    $targetBefore = Get-UpdaterLeafState $ManifestPath `
        'Immediate pre-rollback component manifest'
    $backupBefore = Get-UpdaterLeafState $backupPath `
        'Immediate pre-rollback backup'
    $discardBefore = Get-UpdaterLeafState $discardPath `
        'Immediate pre-rollback discard'
    if ($candidateBefore.Kind -cne 'absent' -or
        -not (Test-UpdaterLeafSnapshot $targetBefore $CurrentTarget) -or
        -not (Test-UpdaterLeafSnapshot $backupBefore $ExpectedBackup) -or
        $discardBefore.Kind -cne 'absent') {
        throw 'Immediate pre-rollback transaction layout changed.'
    }

    $replaceFailure = $null
    try {
        if ($InjectPartialFailure) {
            [IO.File]::Move($ManifestPath, $discardPath, $false)
            throw [IO.IOException]::new(
                'Injected rollback ReplaceFile partial-state failure.'
            )
        }
        [IO.File]::Replace($backupPath, $ManifestPath, $discardPath, $true)
    }
    catch { $replaceFailure = $_.Exception }

    $reconciliationFailures = [Collections.Generic.List[Exception]]::new()
    try {
        Assert-UpdaterParentPath $manifestDirectory $manifestParentSnapshot `
            'Post-rollback manifest parent'
    }
    catch { [void]$reconciliationFailures.Add($_.Exception) }
    $candidateAfter = Get-UpdaterLeafState $candidatePath `
        'Post-rollback candidate'
    $targetAfter = Get-UpdaterLeafState $ManifestPath `
        'Post-rollback component manifest'
    $backupAfter = Get-UpdaterLeafState $backupPath `
        'Post-rollback backup'
    $discardAfter = Get-UpdaterLeafState $discardPath `
        'Post-rollback discard'
    foreach ($state in @(
        $candidateAfter, $targetAfter, $backupAfter, $discardAfter
    )) {
        if ($null -ne $state.Error) {
            [void]$reconciliationFailures.Add($state.Error)
        }
    }
    $candidateAbsent = $candidateAfter.Kind -ceq 'absent'
    $targetRestored = Test-UpdaterLeafIdentityAndBytes `
        $targetAfter $ExpectedBackup
    $backupConsumed = $backupAfter.Kind -ceq 'absent'
    $discardMapped = Test-UpdaterLeafIdentityAndBytes `
        $discardAfter $CurrentTarget
    $mapped = $candidateAbsent -and $targetRestored -and
        $backupConsumed -and $discardMapped
    $noMapping = $candidateAbsent -and
        (Test-UpdaterLeafSnapshot $backupAfter $ExpectedBackup) -and
        (Test-UpdaterLeafSnapshot $targetAfter $CurrentTarget) -and
        $discardAfter.Kind -ceq 'absent'
    $partialMapping = $candidateAbsent -and
        $targetAfter.Kind -ceq 'absent' -and
        (Test-UpdaterLeafIdentityAndBytes $backupAfter $ExpectedBackup) -and
        $discardMapped
    $recoveryFailure = $null
    if ($partialMapping) {
        $recovery = Invoke-UpdaterMissingTargetRestoreInternal `
            -ExpectedTarget $ExpectedBackup `
            -ExpectedBackup $backupAfter.Snapshot
        $recoveryFailure = $recovery.MoveFailure
        foreach ($failure in $recovery.ReconciliationFailures) {
            [void]$reconciliationFailures.Add($failure)
        }
        $candidateAfter = Get-UpdaterLeafState $candidatePath `
            'Recovered rollback candidate'
        $targetAfter = Get-UpdaterLeafState $ManifestPath `
            'Recovered rollback component manifest'
        $backupAfter = Get-UpdaterLeafState $backupPath `
            'Recovered rollback backup'
        $discardAfter = Get-UpdaterLeafState $discardPath `
            'Recovered rollback discard'
        foreach ($state in @(
            $candidateAfter, $targetAfter, $backupAfter, $discardAfter
        )) {
            if ($null -ne $state.Error) {
                [void]$reconciliationFailures.Add($state.Error)
            }
        }
        $candidateAbsent = $candidateAfter.Kind -ceq 'absent'
        $targetRestored = Test-UpdaterLeafIdentityAndBytes `
            $targetAfter $ExpectedBackup
        $backupConsumed = $backupAfter.Kind -ceq 'absent'
        $discardMapped = Test-UpdaterLeafIdentityAndBytes `
            $discardAfter $CurrentTarget
        $mapped = $candidateAbsent -and $targetRestored -and
            $backupConsumed -and $discardMapped
    }

    if (-not $mapped -and -not $noMapping) {
        [void]$reconciliationFailures.Add(
            [InvalidOperationException]::new(
                'Rollback ReplaceFile state was not an exact pre-map, ' +
                'post-map, or recovered partial-map layout.'
            )
        )
    }
    $discardOwned = $null
    $preserveDiscard = $false
    if ($mapped) {
        if ($CurrentTargetOwned) {
            $discardOwned = [pscustomobject]@{
                Path = $discardPath
                Snapshot = $discardAfter.Snapshot
            }
        }
        else { $preserveDiscard = $true }
    }
    elseif ($discardAfter.Kind -cne 'absent') {
        $preserveDiscard = $true
    }

    return [pscustomobject]@{
        Restored = $mapped
        Mapped = $mapped
        PartialMapping = $partialMapping
        NoMapping = $noMapping
        DiscardOwned = $discardOwned
        PreserveDiscard = $preserveDiscard
        PreserveBackup = $backupAfter.Kind -cne 'absent'
        PreserveCandidate = $candidateAfter.Kind -cne 'absent'
        ReplaceFailure = $replaceFailure
        RecoveryFailure = $recoveryFailure
        ReconciliationFailures =
            [Exception[]]$reconciliationFailures.ToArray()
    }
}

try {
    Initialize-UpdaterNative
    [void](Get-Vkd3dEvidenceFileIdentity $GitExe 'Git executable')
    Assert-Vkd3dEvidenceNoReparseAncestor $privateTempParent `
        'Owned Git temporary parent'
    $openedTempParent = Open-UpdaterStableDirectory $privateTempParent `
        'Owned Git temporary parent'
    $privateTempParentHandle = $openedTempParent.Handle
    $privateTempParentSnapshot = $openedTempParent.Snapshot
    Assert-UpdaterDirectChild $privateTempParent $privateTempRoot `
        'Owned Git temporary root'
    if ($null -ne (Get-Item -LiteralPath $privateTempRoot -Force `
            -ErrorAction SilentlyContinue) -or
        [IO.Directory]::Exists($privateTempRoot) -or
        [IO.File]::Exists($privateTempRoot)) {
        throw 'Owned Git temporary root was not fresh.'
    }
    $privateTempHandle =
        [Retvrn99.Vkd3dEvidenceNative]::CreateExclusiveDirectoryAt(
            $privateTempParentHandle,
            [IO.Path]::GetFileName($privateTempRoot)
        )
    $privateTempState = 'bootstrap'
    $privateTempSnapshot = Get-UpdaterHandleSnapshot $privateTempHandle `
        'Owned Git temporary root' -Directory
    Assert-UpdaterParentPath $privateTempParent $privateTempParentSnapshot `
        'Owned Git temporary parent'
    $ownerPath = Join-Path $privateTempRoot $privateTempOwnerLeaf
    [byte[]]$ownerBytes = $script:Utf8.GetBytes($privateTempOwner)
    $ownedMarker = New-UpdaterOwnedLeaf $privateTempRoot `
        $privateTempSnapshot $ownerPath $ownerBytes `
        'Owned Git temporary marker' `
        -PinnedParentHandle $privateTempHandle
    $privateTempMarkerHandle = $ownedMarker.Handle
    $privateTempMarkerSnapshot = $ownedMarker.Snapshot
    if ($TestFault -ceq 'bootstrap-after-marker') {
        throw 'Injected owner-marker bootstrap failure.'
    }
    $privateTempState = 'owned'

    if (-not (Test-Path -LiteralPath (Join-Path $Vkd3dCheckout '.git'))) {
        throw "vkd3d checkout is not a Git checkout: $Vkd3dCheckout"
    }
    Assert-Vkd3dEvidenceNoReparseAncestor $manifestDirectory `
        'Component manifest parent'
    $openedManifestParent = Open-UpdaterStableDirectory $manifestDirectory `
        'Component manifest parent'
    $manifestParentHandle = $openedManifestParent.Handle
    $manifestParentSnapshot = $openedManifestParent.Snapshot
    Assert-UpdaterDirectChild $manifestDirectory $ManifestPath `
        'Component manifest'
    $openedManifest = Open-UpdaterStableFile $ManifestPath `
        'Existing component manifest' 1048576
    $originalManifestHandle = $openedManifest.Handle
    $originalManifestSnapshot = $openedManifest.Snapshot
    [byte[]]$originalManifestBytes = $originalManifestSnapshot.Bytes
    Assert-UpdaterManifestBytes $originalManifestBytes `
        'Existing component manifest'
    Assert-UpdaterParentPath $manifestDirectory $manifestParentSnapshot `
        'Component manifest parent'
    $existing = $script:Utf8.GetString($originalManifestBytes) | ConvertFrom-Json
    if ($existing.upstream_name -cne 'vkd3d-shader' -or
        $existing.owning_commit -cne $script:PinnedCommit) {
        throw 'The target is not the pinned vkd3d-shader component manifest.'
    }

if (@(Invoke-GitLines @('status', '--porcelain=v1', '--untracked-files=all')).Count `
    -ne 0) {
    throw 'The pinned vkd3d checkout must be clean.'
}
$head = @(Invoke-GitLines @('rev-parse', 'HEAD'))
$headName = @(Invoke-GitLines @('rev-parse', '--abbrev-ref', 'HEAD'))
$remotes = @(Invoke-GitLines @('remote'))
$originUrls = @(Invoke-GitLines @('remote', 'get-url', '--all', 'origin'))
$pushUrls = @(Invoke-GitLines @('remote', 'get-url', '--push', '--all', 'origin'))
if ($head.Count -ne 1 -or $head[0] -cne $script:PinnedCommit -or
    $headName.Count -ne 1 -or $headName[0] -cne 'HEAD' -or
    $remotes.Count -ne 1 -or $remotes[0] -cne 'origin' -or
    $originUrls.Count -ne 1 -or $originUrls[0] -cne $script:PinnedOrigin -or
    $pushUrls.Count -ne 1 -or $pushUrls[0] -cne $script:PinnedOrigin) {
    throw 'The vkd3d checkout is not the clean detached canonical pin.'
}

$tree = [Collections.Generic.Dictionary[string,string]]::new(
    [StringComparer]::Ordinal
)
foreach ($line in @(Invoke-GitLines @('ls-tree', '-r', 'HEAD'))) {
    if ($line -cnotmatch `
        '^(100644|100755) blob (?<hash>[0-9a-f]{40})\t(?<path>.+)$') {
        throw 'Pinned Git tree output is malformed.'
    }
    $tree.Add($Matches.path, $Matches.hash)
}

$descriptorCache = [Collections.Generic.Dictionary[string,object]]::new(
    [StringComparer]::Ordinal
)
function Get-Descriptor {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    if ($descriptorCache.ContainsKey($RelativePath)) {
        return $descriptorCache[$RelativePath]
    }
    if (-not $tree.ContainsKey($RelativePath)) {
        throw "Pinned input '$RelativePath' is not a regular tracked file."
    }
    $blob = $tree[$RelativePath]
    $bytes = Invoke-GitBytes @('cat-file', 'blob', $blob)
    $descriptor = [pscustomobject]@{
        RelativePath = $RelativePath
        GitBlob = $blob
        Bytes = [UInt64]$bytes.Length
        Sha256 = Get-Sha256 $bytes
        Content = $bytes
    }
    $descriptorCache.Add($RelativePath, $descriptor)
    return $descriptor
}

$subtreePaths = @($tree.Keys | Where-Object {
    $_.StartsWith('libs/vkd3d-shader/', [StringComparison]::Ordinal)
})
$subtreePaths = @(Get-OrdinalSortedStrings $subtreePaths)
if ($subtreePaths.Count -eq 0) {
    throw 'The pinned vkd3d-shader subtree is empty.'
}

$makeDescriptor = Get-Descriptor 'Makefile.am'
$configureDescriptor = Get-Descriptor 'configure.ac'
$makeText = $script:Utf8.GetString($makeDescriptor.Content)
$configureText = $script:Utf8.GetString($configureDescriptor.Content)
foreach ($marker in @(
    'AC_USE_SYSTEM_EXTENSIONS',
    'AC_CHECK_PROGS([FLEX]',
    'AC_CHECK_PROGS([BISON]',
    'VKD3D_PROG_WIDL(3, 21)'
)) {
    if (-not $configureText.Contains($marker, [StringComparison]::Ordinal)) {
        throw "Pinned configure.ac lacks required build evidence '$marker'."
    }
}

$makeSourcePaths = @(Get-MakeVariablePaths $makeText `
    'libvkd3d_shader_la_SOURCES')
$referencedSubtree = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
)
foreach ($match in [regex]::Matches(
    $makeText,
    'libs/vkd3d-shader/[A-Za-z0-9._/-]+'
)) {
    if ($tree.ContainsKey($match.Value)) {
        [void]$referencedSubtree.Add($match.Value)
    }
}
Assert-SameOrdinalSet @($referencedSubtree) $subtreePaths `
    'The tracked vkd3d-shader Makefile inventory'

$grammarRule = 'include/private/spirv_grammar.h: ' +
    'libs/vkd3d-shader/make_spirv include/private/spirv.core.grammar.json'
if (-not $makeText.Contains($grammarRule, [StringComparison]::Ordinal)) {
    throw 'Pinned Makefile.am lacks the exact SPIR-V grammar generator rule.'
}

$curatedDependencies = @(
    'include/private/list.h',
    'include/private/rbtree.h',
    'include/private/spirv.core.grammar.json',
    'include/private/vkd3d_common.h',
    'include/private/vkd3d_memory.h',
    'include/private/vkd3d_shader_utils.h',
    'include/vkd3d_d3d9types.h',
    'include/vkd3d_d3dcommon.idl',
    'include/vkd3d_d3dx9shader.idl',
    'include/vkd3d_shader.h',
    'include/vkd3d_types.h',
    'include/vkd3d_unknown.idl',
    'include/vkd3d_windows.h'
)
$derivedDependencies = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
)
$scanQueue = [Collections.Generic.Queue[string]]::new()
$scannedPaths = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
)
foreach ($path in $subtreePaths) {
    $scanQueue.Enqueue($path)
}
foreach ($path in $makeSourcePaths) {
    if ($tree.ContainsKey($path)) {
        $scanQueue.Enqueue($path)
        if ($path.StartsWith('include/', [StringComparison]::Ordinal)) {
            [void]$derivedDependencies.Add($path)
        }
    }
    elseif ($path -cne 'include/private/spirv_grammar.h') {
        throw "Pinned Makefile.am names unknown shader input '$path'."
    }
}
[void]$derivedDependencies.Add('include/private/spirv.core.grammar.json')
$scanQueue.Enqueue('include/private/spirv.core.grammar.json')

while ($scanQueue.Count -gt 0) {
    $path = $scanQueue.Dequeue()
    if (-not $scannedPaths.Add($path)) {
        continue
    }
    $descriptor = Get-Descriptor $path
    $text = $script:Utf8.GetString($descriptor.Content)
    $tokens = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )
    foreach ($pattern in @(
        '(?m)^[ \t]*#[ \t]*include[ \t]*[<"]([^">]+)[">]',
        '(?m)^[ \t]*import[ \t]*[<"]([^">]+)[">]'
    )) {
        foreach ($match in [regex]::Matches($text, $pattern)) {
            [void]$tokens.Add($match.Groups[1].Value.Replace('\', '/'))
        }
    }
    foreach ($token in $tokens) {
        $candidates = [Collections.Generic.List[string]]::new()
        foreach ($candidate in @(
            $token,
            "include/$token",
            "include/private/$token",
            "libs/vkd3d-shader/$token"
        )) {
            if ($tree.ContainsKey($candidate) -and
                -not $candidates.Contains($candidate)) {
                [void]$candidates.Add($candidate)
            }
        }
        if ($candidates.Count -gt 1) {
            throw "Pinned include '$token' resolves ambiguously from '$path'."
        }
        if ($candidates.Count -eq 1) {
            $candidate = $candidates[0]
            $scanQueue.Enqueue($candidate)
            if ($candidate.StartsWith('include/', [StringComparison]::Ordinal)) {
                [void]$derivedDependencies.Add($candidate)
            }
            continue
        }

        if ($token -ceq 'spirv_grammar.h') {
            $candidate = 'include/private/spirv.core.grammar.json'
        }
        elseif ($token.EndsWith('.h', [StringComparison]::Ordinal)) {
            $candidate = 'include/' +
                $token.Substring(0, $token.Length - 2) + '.idl'
            if (-not $tree.ContainsKey($candidate)) {
                continue
            }
        }
        else {
            continue
        }
        [void]$derivedDependencies.Add($candidate)
        $scanQueue.Enqueue($candidate)
    }
}
Assert-SameOrdinalSet @($derivedDependencies) $curatedDependencies `
    'The curated vkd3d-shader include and generator dependency set'

$filePaths = @($subtreePaths + $curatedDependencies + @(
    'Makefile.am', 'configure.ac'
))
$uniqueFilePaths = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
)
foreach ($path in $filePaths) {
    if (-not $uniqueFilePaths.Add($path)) {
        throw "Duplicate vkd3d-shader component input '$path'."
    }
}
$filePaths = @(Get-OrdinalSortedStrings $filePaths)

$copying = Get-Descriptor 'COPYING'
$license = Get-Descriptor 'LICENSE'
$evidence = [Collections.Generic.List[object]]::new()
foreach ($document in @(
    @('copying-lgpl', $copying),
    @('license-lgpl', $license)
)) {
    [void]$evidence.Add([ordered]@{
        id = $document[0]
        kind = 'license-document'
        relative_path = $document[1].RelativePath
        git_blob = $document[1].GitBlob
        bytes = $document[1].Bytes
        sha256 = $document[1].Sha256
        source_prefix_id = 'root-files'
        locator = [ordered]@{kind = 'whole-file'}
        observed_license_expression = 'LGPL-2.1-or-later'
    })
}

$files = [Collections.Generic.List[object]]::new()
$inlineIndex = 0
foreach ($path in $filePaths) {
    $descriptor = Get-Descriptor $path
    $evidenceIds = [Collections.Generic.List[string]]::new()
    $declared = 'LGPL-2.1-or-later'

    if ($path -ceq 'include/private/spirv.core.grammar.json') {
        $range = Get-GrammarLicenseRange $descriptor.Content $path
        $inlineIndex++
        $id = 'inline-{0:D4}-mit' -f $inlineIndex
        [void]$evidence.Add([ordered]@{
            id = $id
            kind = 'inline'
            relative_path = $path
            git_blob = $descriptor.GitBlob
            bytes = $descriptor.Bytes
            sha256 = $descriptor.Sha256
            source_prefix_id = 'include'
            locator = [ordered]@{
                kind = 'byte-range'
                byte_offset = $range.Offset
                byte_count = $range.Count
                sha256 = $range.Sha256
            }
            observed_license_expression = 'MIT'
        })
        [void]$evidenceIds.Add($id)
        $declared = 'MIT'
    }
    elseif ($path -cin @(
        'libs/vkd3d-shader/libvkd3d-shader.pc.in',
        'libs/vkd3d-shader/vkd3d_shader.map'
    )) {
        [void]$evidenceIds.Add('copying-lgpl')
    }
    elseif ($path -cin @('Makefile.am', 'configure.ac')) {
        [void]$evidenceIds.Add('license-lgpl')
    }
    else {
        if ($path -ceq 'libs/vkd3d-shader/make_spirv') {
            $range = Get-HashCommentRange $descriptor.Content $path
        }
        else {
            if ($path -ceq `
                'libs/vkd3d-shader/vkd3d_shader_private.h') {
                $range = Get-CCommentRange $descriptor.Content `
                    'This library is free software' $path `
                    -AllowRepeatedMarker
            }
            else {
                $range = Get-CCommentRange $descriptor.Content `
                    'This library is free software' $path
            }
        }
        $inlineIndex++
        $id = 'inline-{0:D4}-lgpl' -f $inlineIndex
        $prefixId = if ($path.StartsWith('include/', `
                [StringComparison]::Ordinal)) { 'include' } else { 'vkd3d-shader' }
        [void]$evidence.Add([ordered]@{
            id = $id
            kind = 'inline'
            relative_path = $path
            git_blob = $descriptor.GitBlob
            bytes = $descriptor.Bytes
            sha256 = $descriptor.Sha256
            source_prefix_id = $prefixId
            locator = [ordered]@{
                kind = 'byte-range'
                byte_offset = $range.Offset
                byte_count = $range.Count
                sha256 = $range.Sha256
            }
            observed_license_expression = 'LGPL-2.1-or-later'
        })
        [void]$evidenceIds.Add($id)

        if ($path -ceq 'libs/vkd3d-shader/hlsl.h') {
            $mitRange = Get-CCommentRange $descriptor.Content `
                'Permission is hereby granted' $path
            $inlineIndex++
            $mitId = 'inline-{0:D4}-mit' -f $inlineIndex
            [void]$evidence.Add([ordered]@{
                id = $mitId
                kind = 'inline'
                relative_path = $path
                git_blob = $descriptor.GitBlob
                bytes = $descriptor.Bytes
                sha256 = $descriptor.Sha256
                source_prefix_id = 'vkd3d-shader'
                locator = [ordered]@{
                    kind = 'byte-range'
                    byte_offset = $mitRange.Offset
                    byte_count = $mitRange.Count
                    sha256 = $mitRange.Sha256
                }
                observed_license_expression = 'MIT'
            })
            [void]$evidenceIds.Add($mitId)
            $declared = 'LGPL-2.1-or-later AND MIT'
        }
        if ($path -ceq 'libs/vkd3d-shader/checksum.c') {
            [void](Get-UniqueMarkerOffset $descriptor.Content `
                'based on code in the public domain written by Colin' $path)
        }
    }

    if ($path -cmatch '^libs/vkd3d-shader/.+\.c$') {
        $roles = @('source-unit')
    }
    elseif ($path -ceq 'include/vkd3d_d3d9types.h') {
        $roles = @('compiler-dependency', 'generator-input')
    }
    elseif ($path -cmatch '^(?:libs/vkd3d-shader|include)/.+\.h$') {
        $roles = @('compiler-dependency')
    }
    elseif ($path -cmatch '^libs/vkd3d-shader/.+\.[ly]$' -or
        $path -ceq 'libs/vkd3d-shader/make_spirv' -or
        $path -cmatch '^include/.+\.(?:idl|json)$') {
        $roles = @('generator-input')
    }
    elseif ($path -cin @(
        'Makefile.am',
        'configure.ac',
        'libs/vkd3d-shader/vkd3d_shader.map'
    )) {
        $roles = @('build-description')
    }
    elseif ($path -ceq `
        'libs/vkd3d-shader/libvkd3d-shader.pc.in') {
        $roles = @('resource')
    }
    else {
        throw "Pinned input '$path' has no curated component role."
    }

    $prefixId = if ($path -cin @('Makefile.am', 'configure.ac')) {
        'root-files'
    }
    elseif ($path.StartsWith('include/', [StringComparison]::Ordinal)) {
        'include'
    }
    else {
        'vkd3d-shader'
    }
    [void]$files.Add([ordered]@{
        relative_path = $path
        git_blob = $descriptor.GitBlob
        bytes = $descriptor.Bytes
        sha256 = $descriptor.Sha256
        declared_license_expression = $declared
        selected_license_expression = $declared
        license_evidence_ids = @($evidenceIds)
        source_prefix_id = $prefixId
        roles = @($roles)
    })
}

$files = @(Get-OrdinalSortedRows @($files))
$manifest = [ordered]@{
    _spdx = 'GPL-3.0-only'
    schema = 2
    status = 'ready'
    reason = ''
    upstream_name = 'vkd3d-shader'
    owning_commit = $script:PinnedCommit
    source_prefixes = @(
        [ordered]@{id = 'root-files'; relative_path = '.'; mode = 'exact-root-files'},
        [ordered]@{id = 'include'; relative_path = 'include'; mode = 'subtree'},
        [ordered]@{id = 'vkd3d-shader'; relative_path = 'libs/vkd3d-shader'; mode = 'subtree'}
    )
    license_evidence = @($evidence)
    files = @($files)
}

$transactionPaths = @($candidatePath, $backupPath, $discardPath)
Assert-UpdaterParentPath $manifestDirectory $manifestParentSnapshot `
    'Component manifest parent'
foreach ($path in $transactionPaths) {
    Assert-UpdaterDirectChild $manifestDirectory $path `
        'Manifest transaction leaf'
    if ($null -ne (Get-Item -LiteralPath $path -Force `
            -ErrorAction SilentlyContinue) -or
        [IO.File]::Exists($path) -or [IO.Directory]::Exists($path)) {
        throw 'Manifest transaction path was not fresh.'
    }
}
[byte[]]$expectedCandidateBytes = Get-CompactManifestBytes $manifest
$ownedCandidate = New-UpdaterOwnedLeaf $manifestDirectory `
    $manifestParentSnapshot $candidatePath $expectedCandidateBytes `
    'Candidate component manifest'
$candidateHandle = $ownedCandidate.Handle
$candidateCleanup = [pscustomobject][ordered]@{
    Path = $ownedCandidate.Path
    Snapshot = $ownedCandidate.Snapshot
}
if ($TestFault -ceq 'candidate-corrupt') {
    [byte[]]$corruptBytes = $script:Utf8.GetBytes("{}`n")
    [Retvrn99.Vkd3dEvidenceNative]::WriteAll($candidateHandle, $corruptBytes)
    $corruptSnapshot = Get-UpdaterHandleSnapshot $candidateHandle `
        'Corrupted candidate component manifest' `
        -MaximumBytes ([UInt64]$corruptBytes.Length)
    $candidateCleanup = [pscustomobject][ordered]@{
        Path = $candidatePath
        Snapshot = $corruptSnapshot
    }
}
if ($TestFault -ceq 'candidate-replace-exact') {
    [Retvrn99.Vkd3dEvidenceNative]::MarkDelete($candidateHandle)
    $candidateHandle.Dispose()
    $candidateHandle = $null
    $candidateCleanup = $null
    Set-UpdaterTestReplacement $candidatePath $expectedCandidateBytes `
        'Candidate replacement fault'
    $preservedTransactionLeaf = $true
    throw 'Candidate component manifest ownership changed.'
}
try {
    $candidateSnapshot = Get-UpdaterHandleSnapshot $candidateHandle `
        'Candidate component manifest' `
        -MaximumBytes ([UInt64]$expectedCandidateBytes.Length)
    [byte[]]$candidateBytes = $candidateSnapshot.Bytes
    Assert-UpdaterManifestBytes $candidateBytes 'Candidate component manifest'
    $candidate = $script:Utf8.GetString($candidateBytes) | ConvertFrom-Json
    if (-not (Test-UpdaterSameSnapshot $candidateSnapshot `
            $ownedCandidate.Snapshot) -or
        -not (Test-ExactBytes $expectedCandidateBytes $candidateBytes) -or
        $candidate.status -cne 'ready' -or
        $candidate.upstream_name -cne 'vkd3d-shader' -or
        $candidate.owning_commit -cne $script:PinnedCommit -or
        @($candidate.files).Count -ne $files.Count -or
        @($candidate.license_evidence).Count -ne $evidence.Count) {
        throw 'Candidate component manifest identity changed.'
    }
}
catch {
    throw 'Candidate component manifest failed exact verification.'
}

$currentOriginalSnapshot = Get-UpdaterHandleSnapshot $originalManifestHandle `
    'Pre-promotion component manifest' -MaximumBytes 1048576
$currentCandidateSnapshot = Get-UpdaterHandleSnapshot $candidateHandle `
    'Pre-promotion candidate manifest' `
    -MaximumBytes ([UInt64]$expectedCandidateBytes.Length)
if (-not (Test-UpdaterSameSnapshot $currentOriginalSnapshot `
        $originalManifestSnapshot) -or
    -not (Test-UpdaterSameSnapshot $currentCandidateSnapshot `
        $ownedCandidate.Snapshot)) {
    throw 'Manifest transaction input drifted before promotion.'
}

Assert-UpdaterParentPath $manifestDirectory $manifestParentSnapshot `
    'Component manifest parent'
foreach ($path in @($backupPath, $discardPath)) {
    if ($null -ne (Get-Item -LiteralPath $path -Force `
            -ErrorAction SilentlyContinue) -or
        [IO.File]::Exists($path) -or [IO.Directory]::Exists($path)) {
        throw 'Manifest transaction output appeared before promotion.'
    }
}
$originalManifestHandle.Dispose()
$originalManifestHandle = $null
$candidateHandle.Dispose()
$candidateHandle = $null

if ($TestFault -ceq 'promotion-destination-race') {
    [byte[]]$racedBytes = $script:Utf8.GetBytes("{}`n")
    Set-UpdaterTestReplacement $ManifestPath $racedBytes `
        'Promotion destination race'
}
Assert-UpdaterParentPath $manifestDirectory $manifestParentSnapshot `
    'Component manifest parent'
$openedPrePromotionTarget = Open-UpdaterStableFile $ManifestPath `
    'Pre-promotion target' 1048576
[void]$transactionHandles.Add($openedPrePromotionTarget.Handle)
$openedPrePromotionCandidate = Open-UpdaterStableFile $candidatePath `
    'Pre-promotion candidate' 1048576
[void]$transactionHandles.Add($openedPrePromotionCandidate.Handle)
try {
    $prePromotionTargetSnapshot = $openedPrePromotionTarget.Snapshot
    $prePromotionCandidateSnapshot = $openedPrePromotionCandidate.Snapshot
    if (-not (Test-UpdaterSameSnapshot $prePromotionCandidateSnapshot `
            $ownedCandidate.Snapshot)) {
        throw 'Candidate identity changed before atomic promotion.'
    }
}
finally {
    $openedPrePromotionCandidate.Handle.Dispose()
    $openedPrePromotionTarget.Handle.Dispose()
}

if ($TestFault -ceq 'promotion-backup-race') {
    [byte[]]$racedBackupBytes = $script:Utf8.GetBytes(
        "foreign promotion backup`n"
    )
    Set-UpdaterTestReplacement $backupPath $racedBackupBytes `
        'Promotion backup race'
    $preservedTransactionLeaf = $true
}
Assert-UpdaterParentPath $manifestDirectory $manifestParentSnapshot `
    'Immediate pre-promotion manifest parent'
foreach ($path in @($backupPath, $discardPath)) {
    Assert-UpdaterDirectChild $manifestDirectory $path `
        'Immediate pre-promotion transaction leaf'
    if ($null -ne (Get-Item -LiteralPath $path -Force `
            -ErrorAction SilentlyContinue) -or
        [IO.File]::Exists($path) -or [IO.Directory]::Exists($path)) {
        throw 'Manifest transaction output appeared immediately before promotion.'
    }
}
$forwardReplaceFailure = $null
try {
    if ($TestFault -ceq 'forward-replace-partial') {
        [IO.File]::Move($ManifestPath, $backupPath, $false)
        throw [IO.IOException]::new(
            'Injected forward ReplaceFile partial-state failure.'
        )
    }
    [IO.File]::Replace($candidatePath, $ManifestPath, $backupPath, $true)
}
catch { $forwardReplaceFailure = $_.Exception }

if ($null -eq $forwardReplaceFailure) {
    $candidateCleanup = $null
}
else {
    $forwardFailures = [Collections.Generic.List[Exception]]::new()
    [void]$forwardFailures.Add($forwardReplaceFailure)
    $forwardParentStable = $true
    try {
        Assert-UpdaterParentPath $manifestDirectory $manifestParentSnapshot `
            'Post-promotion-failure manifest parent'
    }
    catch {
        [void]$forwardFailures.Add($_.Exception)
        $forwardParentStable = $false
    }

    $forwardCandidate = Get-UpdaterLeafState $candidatePath `
        'Post-promotion-failure candidate'
    $forwardTarget = Get-UpdaterLeafState $ManifestPath `
        'Post-promotion-failure component manifest'
    $forwardBackup = Get-UpdaterLeafState $backupPath `
        'Post-promotion-failure backup'
    $forwardDiscard = Get-UpdaterLeafState $discardPath `
        'Post-promotion-failure discard'
    foreach ($state in @(
        $forwardCandidate, $forwardTarget, $forwardBackup, $forwardDiscard
    )) {
        if ($null -ne $state.Error) {
            [void]$forwardFailures.Add($state.Error)
        }
    }

    $candidateIsOwned = Test-UpdaterLeafIdentityAndBytes `
        $forwardCandidate $ownedCandidate.Snapshot
    $targetIsPrior = Test-UpdaterLeafIdentityAndBytes `
        $forwardTarget $prePromotionTargetSnapshot
    $targetIsCandidate = Test-UpdaterLeafIdentityAndBytes `
        $forwardTarget $ownedCandidate.Snapshot
    $backupIsPrior = Test-UpdaterLeafIdentityAndBytes `
        $forwardBackup $prePromotionTargetSnapshot
    $forwardNoMapping = $candidateIsOwned -and $targetIsPrior -and
        $forwardBackup.Kind -ceq 'absent' -and
        $forwardDiscard.Kind -ceq 'absent'
    $forwardMapped = $forwardCandidate.Kind -ceq 'absent' -and
        $targetIsCandidate -and $backupIsPrior -and
        $forwardDiscard.Kind -ceq 'absent'
    $forwardPartialMapping = $forwardTarget.Kind -ceq 'absent' -and
        $backupIsPrior -and $forwardDiscard.Kind -ceq 'absent'

    if ($forwardCandidate.Kind -ceq 'absent') {
        $candidateCleanup = $null
    }
    elseif ($candidateIsOwned) {
        $candidateCleanup = [pscustomobject][ordered]@{
            Path = $candidatePath
            Snapshot = $forwardCandidate.Snapshot
        }
    }
    else {
        $candidateCleanup = $null
        $preservedTransactionLeaf = $true
    }

    $forwardRecovered = $forwardNoMapping
    if (-not $forwardParentStable) {
        $candidateCleanup = $null
        foreach ($state in @(
            $forwardCandidate, $forwardBackup, $forwardDiscard
        )) {
            if ($state.Kind -cne 'absent') {
                $preservedTransactionLeaf = $true
            }
        }
    }
    elseif ($forwardMapped) {
        $candidateCleanup = $null
        $rollbackResult = $null
        try {
            $rollbackResult = Invoke-UpdaterRollbackReplaceInternal `
                -ExpectedBackup $forwardBackup.Snapshot `
                -CurrentTarget $forwardTarget.Snapshot `
                -CurrentTargetOwned $true
        }
        catch {
            [void]$forwardFailures.Add($_.Exception)
            $preservedTransactionLeaf = $true
        }
        if ($null -ne $rollbackResult) {
            if ($null -ne $rollbackResult.ReplaceFailure) {
                [void]$forwardFailures.Add($rollbackResult.ReplaceFailure)
            }
            if ($null -ne $rollbackResult.RecoveryFailure) {
                [void]$forwardFailures.Add($rollbackResult.RecoveryFailure)
            }
            foreach ($failure in $rollbackResult.ReconciliationFailures) {
                [void]$forwardFailures.Add($failure)
            }
            if ($rollbackResult.PreserveCandidate -or
                $rollbackResult.PreserveBackup -or
                $rollbackResult.PreserveDiscard) {
                $preservedTransactionLeaf = $true
            }
            if ($null -ne $rollbackResult.DiscardOwned) {
                $discardCleanup = $rollbackResult.DiscardOwned
                try {
                    Remove-UpdaterOwnedLeaf $manifestDirectory `
                        $manifestParentSnapshot $discardCleanup `
                        'Manifest rollback discard'
                    $discardCleanup = $null
                }
                catch { [void]$forwardFailures.Add($_.Exception) }
            }
            $forwardRecovered = $rollbackResult.Restored
        }
    }
    elseif ($forwardPartialMapping) {
        $restoreResult = Invoke-UpdaterMissingTargetRestoreInternal `
            -ExpectedTarget $prePromotionTargetSnapshot `
            -ExpectedBackup $forwardBackup.Snapshot
        if ($null -ne $restoreResult.MoveFailure) {
            [void]$forwardFailures.Add($restoreResult.MoveFailure)
        }
        foreach ($failure in $restoreResult.ReconciliationFailures) {
            [void]$forwardFailures.Add($failure)
        }
        $recoveredCandidate = Get-UpdaterLeafState $candidatePath `
            'Recovered forward candidate'
        $recoveredTarget = Get-UpdaterLeafState $ManifestPath `
            'Recovered forward component manifest'
        $recoveredBackup = Get-UpdaterLeafState $backupPath `
            'Recovered forward backup'
        $recoveredDiscard = Get-UpdaterLeafState $discardPath `
            'Recovered forward discard'
        foreach ($state in @(
            $recoveredCandidate, $recoveredTarget,
            $recoveredBackup, $recoveredDiscard
        )) {
            if ($null -ne $state.Error) {
                [void]$forwardFailures.Add($state.Error)
            }
        }
        $recoveredCandidateIsOwned = Test-UpdaterLeafIdentityAndBytes `
            $recoveredCandidate $ownedCandidate.Snapshot
        if ($recoveredCandidateIsOwned) {
            $candidateCleanup = [pscustomobject][ordered]@{
                Path = $candidatePath
                Snapshot = $recoveredCandidate.Snapshot
            }
        }
        elseif ($recoveredCandidate.Kind -ceq 'absent') {
            $candidateCleanup = $null
        }
        else {
            $candidateCleanup = $null
            $preservedTransactionLeaf = $true
        }
        if ($recoveredBackup.Kind -cne 'absent' -or
            $recoveredDiscard.Kind -cne 'absent') {
            $preservedTransactionLeaf = $true
        }
        $forwardRecovered = $restoreResult.Restored -and
            $recoveredCandidateIsOwned -and
            (Test-UpdaterLeafIdentityAndBytes `
                $recoveredTarget $prePromotionTargetSnapshot) -and
            $recoveredBackup.Kind -ceq 'absent' -and
            $recoveredDiscard.Kind -ceq 'absent'
    }
    else {
        foreach ($state in @($forwardBackup, $forwardDiscard)) {
            if ($state.Kind -cne 'absent') {
                $preservedTransactionLeaf = $true
            }
        }
    }

    if (-not $forwardRecovered) {
        [void]$forwardFailures.Add([InvalidOperationException]::new(
            'Forward ReplaceFile state was not restored to its exact prior destination.'
        ))
    }
    throw (New-UpdaterTransactionAggregate `
        -Message 'Forward ReplaceFile failed after state reconciliation.' `
        -Failures ([Exception[]]$forwardFailures.ToArray()))
}
Assert-UpdaterParentPath $manifestDirectory $manifestParentSnapshot `
    'Component manifest parent'

$openedPromoted = Open-UpdaterStableFile $ManifestPath `
    'Promoted component manifest' 1048576
[void]$transactionHandles.Add($openedPromoted.Handle)
$openedBackup = Open-UpdaterStableFile $backupPath `
    'Manifest transaction backup' 1048576
[void]$transactionHandles.Add($openedBackup.Handle)
$observedPromotedSnapshot = $openedPromoted.Snapshot
$observedBackupSnapshot = $openedBackup.Snapshot
$openedPromoted.Handle.Dispose()
$openedBackup.Handle.Dispose()

if ($TestFault -cin @(
    'postpromotion-destination-race',
    'rollback-replace-partial'
)) {
    [byte[]]$racedBytes = $script:Utf8.GetBytes("{}`n")
    Set-UpdaterTestReplacement $ManifestPath $racedBytes `
        'Post-promotion destination race'
}
elseif ($TestFault -ceq 'backup-replace-exact') {
    Set-UpdaterTestReplacement $backupPath $originalManifestBytes `
        'Manifest backup replacement race'
}

$currentPromoted = Open-UpdaterStableFile $ManifestPath `
    'Current promoted component manifest' 1048576
[void]$transactionHandles.Add($currentPromoted.Handle)
$currentBackup = Open-UpdaterStableFile $backupPath `
    'Current manifest transaction backup' 1048576
[void]$transactionHandles.Add($currentBackup.Handle)
$currentPromotedSnapshot = $currentPromoted.Snapshot
$currentBackupSnapshot = $currentBackup.Snapshot
$backupStable = Test-UpdaterSameSnapshot $currentBackupSnapshot `
    $observedBackupSnapshot
$targetIsCandidate = Test-UpdaterSameSnapshot $currentPromotedSnapshot `
    $ownedCandidate.Snapshot
$backupIsOriginal = Test-UpdaterSameSnapshot $currentBackupSnapshot `
    $originalManifestSnapshot

if (-not $backupStable) {
    $currentPromoted.Handle.Dispose()
    $currentBackup.Handle.Dispose()
    $preservedTransactionLeaf = $true
    throw 'Manifest transaction backup ownership changed after promotion.'
}

if ($targetIsCandidate -and $backupIsOriginal) {
    $backupCleanup = [pscustomobject][ordered]@{
        Path = $backupPath
        Snapshot = $currentBackupSnapshot
    }
    $finalTargetSnapshot = Get-UpdaterHandleSnapshot `
        $currentPromoted.Handle 'Committed component manifest' `
        -MaximumBytes 1048576
    if (-not (Test-UpdaterSameSnapshot $finalTargetSnapshot `
            $ownedCandidate.Snapshot)) {
        throw 'Committed component manifest changed before backup retirement.'
    }
    $currentBackup.Handle.Dispose()
    Remove-UpdaterOwnedLeaf $manifestDirectory $manifestParentSnapshot `
        $backupCleanup 'Manifest transaction backup'
    $backupCleanup = $null
    $currentPromoted.Handle.Dispose()
}
else {
    $rollbackTargetSnapshot = $currentPromotedSnapshot
    $rollbackBackupSnapshot = $currentBackupSnapshot
    $rollbackTargetWasCandidate = $targetIsCandidate
    $currentPromoted.Handle.Dispose()
    $currentBackup.Handle.Dispose()
    $promotionFailure = if ($backupIsOriginal) {
        [InvalidOperationException]::new(
            'Promoted component manifest drifted and was rolled back.'
        )
    }
    else {
        [InvalidOperationException]::new(
            'Promotion destination drifted; the raced destination was restored.'
        )
    }
    $rollbackFailures = [Collections.Generic.List[Exception]]::new()
    [void]$rollbackFailures.Add($promotionFailure)
    $rollbackResult = $null
    try {
        $rollbackResult = Invoke-UpdaterRollbackReplaceInternal `
            -ExpectedBackup $rollbackBackupSnapshot `
            -CurrentTarget $rollbackTargetSnapshot `
            -CurrentTargetOwned $rollbackTargetWasCandidate `
            -InjectPartialFailure:($TestFault -ceq `
                'rollback-replace-partial')
    }
    catch {
        [void]$rollbackFailures.Add($_.Exception)
        $preservedTransactionLeaf = $true
    }
    if ($null -ne $rollbackResult) {
        if ($null -ne $rollbackResult.ReplaceFailure) {
            [void]$rollbackFailures.Add($rollbackResult.ReplaceFailure)
        }
        if ($null -ne $rollbackResult.RecoveryFailure) {
            [void]$rollbackFailures.Add($rollbackResult.RecoveryFailure)
        }
        foreach ($failure in $rollbackResult.ReconciliationFailures) {
            [void]$rollbackFailures.Add($failure)
        }
        if ($rollbackResult.PreserveCandidate -or
            $rollbackResult.PreserveBackup -or
            $rollbackResult.PreserveDiscard) {
            $preservedTransactionLeaf = $true
        }
        if ($null -ne $rollbackResult.DiscardOwned) {
            $discardCleanup = $rollbackResult.DiscardOwned
            try {
                Remove-UpdaterOwnedLeaf $manifestDirectory `
                    $manifestParentSnapshot $discardCleanup `
                    'Manifest rollback discard'
                $discardCleanup = $null
            }
            catch { [void]$rollbackFailures.Add($_.Exception) }
        }
        if (-not $rollbackResult.Restored) {
            [void]$rollbackFailures.Add([InvalidOperationException]::new(
                'Manifest rollback did not restore the exact prior destination.'
            ))
        }
    }
    if ($rollbackFailures.Count -eq 1) { throw $promotionFailure }
    throw (New-UpdaterTransactionAggregate `
        -Message 'Manifest promotion and rollback both failed.' `
        -Failures ([Exception[]]$rollbackFailures.ToArray()))
}

$manifestHash = Get-Sha256 $expectedCandidateBytes
$successOutput = (
    ('Wrote ready vkd3d-shader component closure with {0} files ' +
    '({1} subtree, {2} dependency, and 2 build-description roots), ' +
    '{3} evidence rows, and SHA-256 {4}.') -f `
        $files.Count, $subtreePaths.Count, $curatedDependencies.Count,
        $evidence.Count, $manifestHash
)
}
catch {
    $primaryError = $_
}
finally {
    if ($TestFault -ceq 'cleanup-failure') {
        [void]$cleanupErrors.Add(
            [InvalidOperationException]::new('Injected cleanup failure.')
        )
    }
    if ($null -ne $originalManifestHandle) {
        try { $originalManifestHandle.Dispose() }
        catch { [void]$cleanupErrors.Add($_) }
        $originalManifestHandle = $null
    }
    foreach ($handle in $transactionHandles) {
        try { $handle.Dispose() }
        catch { [void]$cleanupErrors.Add($_) }
    }
    $transactionHandles.Clear()
    if ($null -ne $candidateHandle) {
        try {
            if ($null -eq $candidateCleanup) {
                throw 'Open candidate handle lacks an owned cleanup identity.'
            }
            $openCandidateSnapshot = Get-UpdaterHandleSnapshot $candidateHandle `
                'Open candidate cleanup handle' -MaximumBytes 1048576
            if (-not (Test-UpdaterSameSnapshot $openCandidateSnapshot `
                    $candidateCleanup.Snapshot)) {
                throw 'Open candidate cleanup identity changed.'
            }
            [Retvrn99.Vkd3dEvidenceNative]::MarkDelete($candidateHandle)
            $candidateCleanup = $null
        }
        catch { [void]$cleanupErrors.Add($_) }
        finally {
            try { $candidateHandle.Dispose() }
            catch { [void]$cleanupErrors.Add($_) }
            $candidateHandle = $null
        }
    }
    foreach ($binding in @(
        [pscustomobject]@{Name = 'candidate'; Owned = $candidateCleanup},
        [pscustomobject]@{Name = 'backup'; Owned = $backupCleanup},
        [pscustomobject]@{Name = 'discard'; Owned = $discardCleanup},
        [pscustomobject]@{Name = 'fault'; Owned = $faultCleanup}
    )) {
        if ($null -eq $binding.Owned) { continue }
        try {
            Remove-UpdaterOwnedLeaf $manifestDirectory $manifestParentSnapshot `
                $binding.Owned "Manifest transaction $($binding.Name)"
        }
        catch { [void]$cleanupErrors.Add($_) }
    }
    if ($null -ne $manifestParentSnapshot) {
        foreach ($path in @($candidatePath, $backupPath, $discardPath)) {
            if ($null -ne (Get-Item -LiteralPath $path -Force `
                    -ErrorAction SilentlyContinue) -or
                [IO.File]::Exists($path) -or [IO.Directory]::Exists($path)) {
                $preservedTransactionLeaf = $true
            }
        }
        if ($preservedTransactionLeaf) {
            [void]$cleanupErrors.Add([InvalidOperationException]::new(
                'An unowned manifest transaction leaf was preserved.'
            ))
        }
    }
    if ($privateTempState -cne 'absent') {
        try { Remove-UpdaterPrivateTempRoot }
        catch { [void]$cleanupErrors.Add($_) }
    }
    foreach ($handleName in @(
        'privateTempMarkerHandle',
        'privateTempHandle',
        'privateTempParentHandle',
        'manifestParentHandle'
    )) {
        $handle = Get-Variable -Name $handleName -ValueOnly
        if ($null -ne $handle) {
            try { $handle.Dispose() }
            catch { [void]$cleanupErrors.Add($_) }
            Set-Variable -Name $handleName -Value $null
        }
    }
}

$privateRoots = @(
    $Vkd3dCheckout,
    $ManifestPath,
    $privateTempRoot,
    $candidatePath,
    $backupPath,
    $discardPath
)
[Exception[]]$cleanupExceptions = @($cleanupErrors | ForEach-Object {
    if ($_ -is [Exception]) { $_ }
    elseif ($null -ne $_.Exception) { $_.Exception }
    else { [InvalidOperationException]::new('Unknown cleanup failure.') }
})
if ($null -ne $primaryError) {
    [Exception[]]$primaryExceptions = if (
        $primaryError.Exception -is [AggregateException]
    ) {
        @($primaryError.Exception.Flatten().InnerExceptions)
    }
    else { @($primaryError.Exception) }
    if ($cleanupExceptions.Count -ne 0) {
        $inner = [Collections.Generic.List[Exception]]::new()
        for ($index = 0; $index -lt $primaryExceptions.Count; $index++) {
            $primaryText = Get-Vkd3dEvidenceSanitizedFailureText `
                $primaryExceptions[$index] $privateRoots
            [void]$inner.Add([InvalidOperationException]::new(
                "Primary failure $($index + 1): $primaryText"
            ))
        }
        for ($index = 0; $index -lt $cleanupExceptions.Count; $index++) {
            $cleanupText = Get-Vkd3dEvidenceSanitizedFailureText `
                $cleanupExceptions[$index] $privateRoots
            [void]$inner.Add([InvalidOperationException]::new(
                "Cleanup failure $($index + 1): $cleanupText"
            ))
        }
        throw [AggregateException]::new(
            'vkd3d-shader updater and cleanup both failed.',
            [Exception[]]$inner.ToArray()
        )
    }
    if ($primaryError.Exception -is [AggregateException]) {
        $inner = [Collections.Generic.List[Exception]]::new()
        foreach ($failure in $primaryExceptions) {
            $primaryText = Get-Vkd3dEvidenceSanitizedFailureText `
                $failure $privateRoots
            [void]$inner.Add([InvalidOperationException]::new($primaryText))
        }
        throw [AggregateException]::new(
            'vkd3d-shader updater failed.',
            [Exception[]]$inner.ToArray()
        )
    }
    $primaryText = Get-Vkd3dEvidenceSanitizedFailureText `
        $primaryError.Exception $privateRoots
    throw [InvalidOperationException]::new(
        "vkd3d-shader updater failed: $primaryText"
    )
}
if ($cleanupExceptions.Count -ne 0) {
    $inner = [Collections.Generic.List[Exception]]::new()
    for ($index = 0; $index -lt $cleanupExceptions.Count; $index++) {
        $cleanupText = Get-Vkd3dEvidenceSanitizedFailureText `
            $cleanupExceptions[$index] $privateRoots
        [void]$inner.Add([InvalidOperationException]::new(
            "Cleanup failure $($index + 1): $cleanupText"
        ))
    }
    throw [AggregateException]::new(
        'vkd3d-shader updater cleanup failed.',
        [Exception[]]$inner.ToArray()
    )
}
Write-Output $successOutput
}

if (-not $vkd3dUpdaterWasDotSourced) {
    Invoke-Vkd3dComponentClosureUpdaterInternal `
        -Vkd3dCheckout $Vkd3dCheckout `
        -ManifestPath $ManifestPath `
        -GitExe $GitExe
}
