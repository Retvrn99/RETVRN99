# SPDX-License-Identifier: GPL-3.0-only

Set-StrictMode -Version Latest

$script:Vkd3dEvidenceUtf8 = [Text.UTF8Encoding]::new($false, $true)
$script:Vkd3dEvidenceTimeoutSeconds = 30
$script:Vkd3dEvidenceMaximumOutputBytes = 1048576
$script:Vkd3dEvidenceBatchSize = 25
$script:Vkd3dEvidenceQuiescenceMilliseconds = 1000

. (Join-Path $PSScriptRoot 'vkd3d-shader-evidence-native.ps1')

function Get-Vkd3dEvidenceSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes
    )

    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($hash.ComputeHash($Bytes)) `
            -replace '-', '').ToLowerInvariant()
    }
    finally { $hash.Dispose() }
}

function Get-Vkd3dEvidenceTextIdentity {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Bytes.Length -eq 0 -or $Bytes -contains [byte]0) {
        throw "$Name is not non-empty text without NUL bytes."
    }
    $hasBom = $Bytes.Length -ge 3 -and $Bytes[0] -eq 0xef -and
        $Bytes[1] -eq 0xbb -and $Bytes[2] -eq 0xbf
    if ($hasBom) { throw "$Name contains a UTF-8 BOM." }
    [void](ConvertFrom-Vkd3dEvidenceUtf8 $Bytes $Name)

    [UInt64]$lfCount = 0
    [UInt64]$crlfCount = 0
    [UInt64]$lfOnlyCount = 0
    [UInt64]$crOnlyCount = 0
    for ($index = 0; $index -lt $Bytes.Length; $index++) {
        if ($Bytes[$index] -eq 10) {
            $lfCount++
            if ($index -gt 0 -and $Bytes[$index - 1] -eq 13) {
                $crlfCount++
            }
            else { $lfOnlyCount++ }
        }
        elseif ($Bytes[$index] -eq 13 -and
            ($index + 1 -ge $Bytes.Length -or $Bytes[$index + 1] -ne 10)) {
            $crOnlyCount++
        }
    }
    return [pscustomobject][ordered]@{
        bytes = [UInt64]$Bytes.Length
        sha256 = Get-Vkd3dEvidenceSha256 $Bytes
        lf_count = $lfCount
        crlf_count = $crlfCount
        lf_only_count = $lfOnlyCount
        cr_only_count = $crOnlyCount
        utf8_bom = $false
    }
}

function Get-Vkd3dEvidenceGeneratedNormalization {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][byte[]]$RawBytes,
        [Parameter(Mandatory = $true)][string]$Name
    )

    Assert-Vkd3dEvidenceRelativePath $RelativePath "$Name path"
    $widlPaths = @(
        'include/vkd3d_d3dcommon.h',
        'include/vkd3d_d3dx9shader.h'
    )
    $mode = if ($widlPaths -ccontains $RelativePath) {
        'crlf-to-lf'
    }
    else { 'none' }
    $raw = Get-Vkd3dEvidenceTextIdentity $RawBytes "$Name raw bytes"

    if ($mode -ceq 'none') {
        if ([UInt64]$raw.crlf_count -ne 0 -or
            [UInt64]$raw.cr_only_count -ne 0 -or
            [UInt64]$raw.lf_count -ne [UInt64]$raw.lf_only_count) {
            throw "$Name unexpectedly requires newline normalization."
        }
        [byte[]]$canonicalBytes = $RawBytes
    }
    else {
        if ([UInt64]$raw.crlf_count -lt 1 -or
            [UInt64]$raw.lf_count -ne [UInt64]$raw.crlf_count -or
            [UInt64]$raw.lf_only_count -ne 0 -or
            [UInt64]$raw.cr_only_count -ne 0) {
            throw "$Name is not strict CRLF-only WIDL output."
        }
        $stream = [IO.MemoryStream]::new(
            [int]([UInt64]$raw.bytes - [UInt64]$raw.crlf_count)
        )
        try {
            for ($index = 0; $index -lt $RawBytes.Length; $index++) {
                if ($RawBytes[$index] -eq 13 -and
                    $index + 1 -lt $RawBytes.Length -and
                    $RawBytes[$index + 1] -eq 10) {
                    $stream.WriteByte(10)
                    $index++
                }
                else { $stream.WriteByte($RawBytes[$index]) }
            }
            [byte[]]$canonicalBytes = $stream.ToArray()
        }
        finally { $stream.Dispose() }
    }

    $canonical = Get-Vkd3dEvidenceTextIdentity $canonicalBytes `
        "$Name canonical bytes"
    if ([UInt64]$canonical.crlf_count -ne 0 -or
        [UInt64]$canonical.cr_only_count -ne 0 -or
        [UInt64]$canonical.lf_count -ne [UInt64]$canonical.lf_only_count) {
        throw "$Name canonical bytes are not LF-only text."
    }
    if ($mode -ceq 'none') {
        if ([UInt64]$raw.bytes -ne [UInt64]$canonical.bytes -or
            [string]$raw.sha256 -cne [string]$canonical.sha256 -or
            [UInt64]$raw.lf_count -ne [UInt64]$canonical.lf_count) {
            throw "$Name no-op normalization changed its bytes."
        }
        [UInt64]$removedCrBytes = 0
    }
    else {
        if ([UInt64]$raw.bytes -ne
                ([UInt64]$canonical.bytes + [UInt64]$raw.crlf_count) -or
            [UInt64]$canonical.lf_count -ne [UInt64]$raw.crlf_count -or
            [string]$raw.sha256 -ceq [string]$canonical.sha256) {
            throw "$Name CRLF-to-LF byte relation is invalid."
        }
        [UInt64]$removedCrBytes = [UInt64]$raw.crlf_count
    }
    return [pscustomobject][ordered]@{
        RawBytes = $RawBytes
        CanonicalBytes = $canonicalBytes
        Raw = $raw
        Canonical = $canonical
        Mode = $mode
        RemovedCrBytes = $removedCrBytes
        Proven = $true
    }
}

function Assert-Vkd3dEvidenceNoPrivatePathText {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Text -match '(?i)(?:^|[^a-z0-9+.-])[a-z]:[\\/]' -or
        $Text -match '(?i)(?:-I|-isystem|-include|-L)[a-z]:[\\/]' -or
        $Text -match '\\\\[^\\/\s]+[\\/]' -or
        $Text -match
            '(?i)/(?:users|home|root|tmp|var/tmp|var/folders|private/tmp|opt|mnt)(?:/|$)') {
        throw "$Name contains a private absolute path."
    }
}

function Get-Vkd3dEvidenceSanitizedFailureText {
    param(
        [Parameter(Mandatory = $true)][Exception]$Exception,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$PrivateRoots
    )

    $kind = $Exception.GetType().FullName
    $text = ($kind + ': ' + [string]$Exception.Message).Replace("`r", ' ').Replace("`n", ' ')
    foreach ($root in $PrivateRoots) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        try { $full = [IO.Path]::GetFullPath($root) }
        catch { return "$kind`: failure detail redacted." }
        foreach ($spelling in @($full, $full.Replace('\', '/'))) {
            $text = [regex]::Replace(
                $text,
                [regex]::Escape($spelling),
                '<private>',
                [Text.RegularExpressions.RegexOptions]::IgnoreCase
            )
        }
    }
    if ([Text.Encoding]::UTF8.GetByteCount($text) -gt 2048) {
        return "$kind`: failure detail exceeded its bound."
    }
    try { Assert-Vkd3dEvidenceNoPrivatePathText $text 'failure detail' }
    catch { return "$kind`: failure detail redacted." }
    return $text
}

function New-Vkd3dEvidenceCombinedFailure {
    param(
        [Parameter(Mandatory = $true)][Exception]$Primary,
        [Parameter(Mandatory = $true)][Exception[]]$Cleanup,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$PrivateRoots
    )

    $primaryText = Get-Vkd3dEvidenceSanitizedFailureText $Primary $PrivateRoots
    $failures = [Collections.Generic.List[Exception]]::new()
    $failures.Add(
        [InvalidOperationException]::new("Primary failure: $primaryText")
    )
    for ($index = 0; $index -lt $Cleanup.Count; $index++) {
        $cleanupText = Get-Vkd3dEvidenceSanitizedFailureText `
            $Cleanup[$index] $PrivateRoots
        $failures.Add([InvalidOperationException]::new(
            "Cleanup failure $($index + 1): $cleanupText"
        ))
    }
    return [AggregateException]::new(
        'Compiler evidence collection and cleanup both failed.',
        [Exception[]]$failures.ToArray()
    )
}

function New-Vkd3dEvidenceCleanupFailure {
    param(
        [Parameter(Mandatory = $true)][Exception[]]$Cleanup,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$PrivateRoots
    )

    $failures = [Collections.Generic.List[Exception]]::new()
    for ($index = 0; $index -lt $Cleanup.Count; $index++) {
        $cleanupText = Get-Vkd3dEvidenceSanitizedFailureText `
            $Cleanup[$index] $PrivateRoots
        $failures.Add([InvalidOperationException]::new(
            "Cleanup failure $($index + 1): $cleanupText"
        ))
    }
    return [AggregateException]::new(
        'Compiler evidence cleanup failed.',
        [Exception[]]$failures.ToArray()
    )
}

function Get-Vkd3dEvidenceFileIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [UInt64]$MaximumBytes = [UInt64]67108864
    )

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        ($item.Attributes -band [IO.FileAttributes]::Device) -ne 0) {
        throw "$Name is not one ordinary file."
    }
    $stream = [IO.File]::Open(
        $item.FullName,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read
    )
    try {
        if ([UInt64]$stream.Length -gt $MaximumBytes) {
            throw "$Name exceeds its byte bound."
        }
        $hash = [Security.Cryptography.SHA256]::Create()
        try { $digest = $hash.ComputeHash($stream) }
        finally { $hash.Dispose() }
    }
    finally { $stream.Dispose() }
    return [pscustomobject][ordered]@{
        bytes = [UInt64]$item.Length
        sha256 = ([BitConverter]::ToString($digest) -replace '-', '').ToLowerInvariant()
    }
}

function Read-Vkd3dEvidenceFileBytes {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [UInt64]$MaximumBytes = [UInt64]67108864
    )

    $identity = Get-Vkd3dEvidenceFileIdentity $Path $Name $MaximumBytes
    [byte[]]$bytes = [IO.File]::ReadAllBytes($Path)
    if ([UInt64]$bytes.Length -ne [UInt64]$identity.bytes -or
        (Get-Vkd3dEvidenceSha256 $bytes) -cne [string]$identity.sha256) {
        throw "$Name changed while it was read."
    }
    return ,$bytes
}

function Assert-Vkd3dEvidenceDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Name is not one ordinary directory."
    }
}

function Assert-Vkd3dEvidenceNoReparseAncestor {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $current = [IO.Path]::GetFullPath($Path)
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($null -ne $item -and
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Name traverses a reparse point."
        }
        $parent = [IO.Path]::GetDirectoryName($current)
        if ([string]::IsNullOrWhiteSpace($parent) -or
            $parent.Equals($current, [StringComparison]::OrdinalIgnoreCase)) {
            break
        }
        $current = $parent
    }
}

function Assert-Vkd3dEvidenceFreshMutationBoundary {
    param(
        [Parameter(Mandatory = $true)][string]$Parent,
        [Parameter(Mandatory = $true)][string[]]$AbsentPaths,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $parentFull = [IO.Path]::GetFullPath($Parent)
    Assert-Vkd3dEvidenceNoReparseAncestor $parentFull "$Name parent"
    Assert-Vkd3dEvidenceDirectory $parentFull "$Name parent"
    foreach ($path in $AbsentPaths) {
        $full = [IO.Path]::GetFullPath($path)
        if (-not [IO.Path]::GetDirectoryName($full).Equals(
                $parentFull,
                [StringComparison]::OrdinalIgnoreCase
            )) {
            throw "$Name leaf is not a direct child of its parent."
        }
        if (-not (Test-Vkd3dEvidencePathAbsent $full)) {
            throw "$Name leaf must be fresh and absent."
        }
    }
}

function Remove-Vkd3dEvidenceOwnedLeaf {
    param(
        [Parameter(Mandatory = $true)][string]$Parent,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [object]$ExpectedBytes,
        [string]$ExpectedSha256,
        [string]$ExpectedFileIdentity,
        [Microsoft.Win32.SafeHandles.SafeFileHandle]$ParentHandle
    )

    $parentFull = [IO.Path]::GetFullPath($Parent)
    $full = [IO.Path]::GetFullPath($Path)
    Assert-Vkd3dEvidenceNoReparseAncestor $parentFull "$Name parent"
    Assert-Vkd3dEvidenceDirectory $parentFull "$Name parent"
    if (-not [IO.Path]::GetDirectoryName($full).Equals(
            $parentFull,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw "$Name is not a direct child of its parent."
    }
    if (Test-Vkd3dEvidencePathAbsent $full) { return }
    $parentRoot = $ParentHandle
    $ownsParent = $null -eq $parentRoot
    if ($ownsParent) {
        $parentRoot = Open-Vkd3dEvidenceDeleteHandle $parentFull `
            "$Name parent"
    }
    else {
        Assert-Vkd3dEvidenceSafeHandle $parentRoot "$Name parent"
    }
    $handle = $null
    try {
        $handle = Open-Vkd3dEvidenceDeleteHandle $full $Name
        try {
            $identity = Get-Vkd3dEvidenceHandleIdentity $handle $Name
            if ($null -ne $ExpectedBytes -and
                [UInt64]$identity.bytes -ne [UInt64]$ExpectedBytes) {
                throw "$Name no longer has its expected owned byte count."
            }
            if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256) -and
                [string]$identity.sha256 -cne $ExpectedSha256) {
                throw "$Name no longer has its expected owned content."
            }
            if (-not [string]::IsNullOrWhiteSpace($ExpectedFileIdentity) -and
                [string]$identity.file_identity -cne $ExpectedFileIdentity) {
                throw "$Name no longer has its expected owned file identity."
            }
            Set-Vkd3dEvidenceBoundHandleDelete $parentRoot $handle `
                $parentFull $full $Name
        }
        finally { if ($null -ne $handle) { $handle.Dispose() } }
    }
    finally {
        if ($ownsParent -and $null -ne $parentRoot) {
            $parentRoot.Dispose()
        }
    }
    Assert-Vkd3dEvidencePathAbsent $full $Name
}

function Assert-Vkd3dEvidenceRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or
        [IO.Path]::IsPathRooted($Path) -or $Path.Contains('\') -or
        $Path.StartsWith('/') -or
        [Text.Encoding]::UTF8.GetByteCount($Path) -gt 1024) {
        throw "$Name has an unsafe relative path '$Path'."
    }
    foreach ($component in $Path.Split('/')) {
        if ([string]::IsNullOrWhiteSpace($component) -or
            $component -in @('.', '..') -or
            $component -match '[\x00-\x1f:*?"<>|]' -or
            $component.EndsWith('.') -or $component.EndsWith(' ') -or
            $component -match
                '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$') {
            throw "$Name has an unsafe relative path '$Path'."
        }
    }
}

function Get-Vkd3dEvidenceObjectStem {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    Assert-Vkd3dEvidenceRelativePath $RelativePath 'compiler unit'
    $leaf = [IO.Path]::GetFileName($RelativePath)
    if ($leaf -cnotmatch '^([A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)*)\.c$') {
        throw "Compiler unit '$RelativePath' has an unsafe object stem."
    }
    return [string]$Matches[1]
}

function ConvertFrom-Vkd3dEvidenceUtf8 {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][string]$Name
    )

    try { return $script:Vkd3dEvidenceUtf8.GetString($Bytes) }
    catch { throw "$Name is not strict UTF-8." }
}

function Stop-Vkd3dEvidenceProcessTree {
    param([Parameter(Mandatory = $true)][object]$Process)

    $grace = [Diagnostics.Stopwatch]::StartNew()
    $terminationFailure = $null
    try { $Process.Terminate() }
    catch { $terminationFailure = $_.Exception }
    $remaining = [Math]::Max(
        0,
        5000 - [int][Math]::Min($grace.ElapsedMilliseconds, 5000)
    )
    if ($remaining -gt 0) { [void]$Process.WaitForExit($remaining) }
    if ([UInt32]$Process.ActiveProcesses -ne 0) {
        throw 'A child process survived bounded job cleanup.'
    }
    if ($null -ne $terminationFailure) {
        throw 'The bounded job reported a termination failure.'
    }
}

function Read-Vkd3dEvidenceProcessStreams {
    param(
        [Parameter(Mandatory = $true)][object]$Process,
        [Parameter(Mandatory = $true)][Diagnostics.Stopwatch]$Stopwatch,
        [Parameter(Mandatory = $true)][string]$Name,
        [ValidateRange(1, 30)][int]$TimeoutSeconds,
        [ValidateRange(1, 1048576)][int]$MaximumOutputBytes
    )

    $stdout = [IO.MemoryStream]::new()
    $stderr = [IO.MemoryStream]::new()
    [byte[]]$stdoutBuffer = [byte[]]::new(8192)
    [byte[]]$stderrBuffer = [byte[]]::new(8192)
    $stdoutDone = $false
    $stderrDone = $false
    $stdoutTask = $Process.Stdout.ReadAsync(
        $stdoutBuffer, 0, $stdoutBuffer.Length
    )
    $stderrTask = $Process.Stderr.ReadAsync(
        $stderrBuffer, 0, $stderrBuffer.Length
    )
    try {
        while (-not $stdoutDone -or -not $stderrDone) {
            $remaining = $TimeoutSeconds * 1000 - $Stopwatch.ElapsedMilliseconds
            if ($remaining -le 0) {
                Stop-Vkd3dEvidenceProcessTree $Process
                throw "$Name exceeded its $TimeoutSeconds-second bound."
            }

            $delay = [Threading.Tasks.Task]::Delay(
                [Math]::Min(50, [int]$remaining)
            )
            [Threading.Tasks.Task[]]$pending = @($delay)
            if (-not $stdoutDone) { $pending += $stdoutTask }
            if (-not $stderrDone) { $pending += $stderrTask }
            [void][Threading.Tasks.Task]::WhenAny($pending).GetAwaiter().GetResult()

            if (-not $stdoutDone -and $stdoutTask.IsCompleted) {
                $read = $stdoutTask.GetAwaiter().GetResult()
                if ($read -eq 0) { $stdoutDone = $true }
                else {
                    if ($stdout.Length + $read -gt $MaximumOutputBytes) {
                        Stop-Vkd3dEvidenceProcessTree $Process
                        throw "$Name exceeded its output bound."
                    }
                    $stdout.Write($stdoutBuffer, 0, $read)
                    $stdoutTask = $Process.Stdout.ReadAsync(
                        $stdoutBuffer, 0, $stdoutBuffer.Length
                    )
                }
            }
            if (-not $stderrDone -and $stderrTask.IsCompleted) {
                $read = $stderrTask.GetAwaiter().GetResult()
                if ($read -eq 0) { $stderrDone = $true }
                else {
                    if ($stderr.Length + $read -gt $MaximumOutputBytes) {
                        Stop-Vkd3dEvidenceProcessTree $Process
                        throw "$Name exceeded its output bound."
                    }
                    $stderr.Write($stderrBuffer, 0, $read)
                    $stderrTask = $Process.Stderr.ReadAsync(
                        $stderrBuffer, 0, $stderrBuffer.Length
                    )
                }
            }
        }

        $remaining = $TimeoutSeconds * 1000 - $Stopwatch.ElapsedMilliseconds
        if ($remaining -le 0 -or
            -not $Process.WaitForExit([Math]::Max(1, [int]$remaining))) {
            Stop-Vkd3dEvidenceProcessTree $Process
            throw "$Name exceeded its $TimeoutSeconds-second bound."
        }
        while ([UInt32]$Process.ActiveProcesses -ne 0) {
            $remaining = $TimeoutSeconds * 1000 - $Stopwatch.ElapsedMilliseconds
            if ($remaining -le 0) {
                Stop-Vkd3dEvidenceProcessTree $Process
                throw "$Name left a detached descendant after its parent exited."
            }
            Start-Sleep -Milliseconds ([Math]::Min(20, [int]$remaining))
        }
        return [pscustomobject][ordered]@{
            stdout = $stdout.ToArray()
            stderr = $stderr.ToArray()
        }
    }
    finally {
        $stdout.Dispose()
        $stderr.Dispose()
    }
}

function Select-Vkd3dEvidenceProcessStreams {
    param(
        [Parameter(Mandatory = $true)][object]$Result,
        [Parameter(Mandatory = $true)]
        [ValidateSet('stdout', 'stderr')][string]$ExpectedStream
    )

    if ($null -eq $Result -or
        @($Result.PSObject.Properties.Name) -cnotcontains 'stdout' -or
        @($Result.PSObject.Properties.Name) -cnotcontains 'stderr') {
        throw 'Process result has no complete stream pair.'
    }
    [byte[]]$stdout = $Result.stdout
    [byte[]]$stderr = $Result.stderr
    if ($null -eq $stdout -or $null -eq $stderr) {
        throw 'Process result has a null stream.'
    }
    if ($ExpectedStream -ceq 'stdout') {
        return [pscustomobject][ordered]@{
            selected = $stdout
            other = $stderr
        }
    }
    return [pscustomobject][ordered]@{
        selected = $stderr
        other = $stdout
    }
}

function Get-Vkd3dEvidenceBigEndianBytes {
    param([UInt64]$Value, [ValidateSet(4, 8)][int]$Width)

    [byte[]]$bytes = [byte[]]::new($Width)
    for ($index = 0; $index -lt $Width; $index++) {
        $bytes[$Width - 1 - $index] = [byte](($Value -shr (8 * $index)) -band 0xff)
    }
    return ,$bytes
}

function Get-Vkd3dEvidenceTreeIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][object]$Expected,
        [Parameter(Mandatory = $true)][string]$Name
    )

    Assert-Vkd3dEvidenceDirectory $Root $Name
    $records = [Collections.Generic.Dictionary[string,object]]::new(
        [StringComparer]::Ordinal
    )
    [UInt64]$fileCount = 0
    [UInt64]$directoryCount = 0
    [UInt64]$aggregateBytes = 0
    [UInt64]$maximumFileBytes = 0
    [UInt64]$maximumPathBytes = 0
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push([IO.Path]::GetFullPath($Root))
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($directory)) {
            $full = [IO.Path]::GetFullPath($entry)
            $relative = [IO.Path]::GetRelativePath($Root, $full).Replace('\', '/')
            Assert-Vkd3dEvidenceRelativePath $relative "$Name entry"
            $pathBytes = [Text.UTF8Encoding]::new($false).GetByteCount($relative)
            if ($pathBytes -gt $maximumPathBytes) { $maximumPathBytes = $pathBytes }
            $attributes = [IO.File]::GetAttributes($full)
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                ($attributes -band [IO.FileAttributes]::Device) -ne 0) {
                throw "$Name contains a non-ordinary entry '$relative'."
            }
            if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) {
                $directoryCount++
                $pending.Push($full)
                continue
            }
            $identity = Get-Vkd3dEvidenceFileIdentity $full `
                "$Name file '$relative'" ([UInt64]16777216)
            $fileCount++
            $aggregateBytes += [UInt64]$identity.bytes
            if ([UInt64]$identity.bytes -gt $maximumFileBytes) {
                $maximumFileBytes = [UInt64]$identity.bytes
            }
            if ($records.ContainsKey($relative)) {
                throw "$Name repeats '$relative'."
            }
            $records.Add($relative, $identity)
            if ($fileCount -gt 1024 -or $directoryCount -gt 128 -or
                $aggregateBytes -gt 67108864 -or $maximumPathBytes -gt 512) {
                throw "$Name exceeds its hard tree bounds."
            }
        }
    }
    [string[]]$paths = @($records.Keys)
    [Array]::Sort($paths, [StringComparer]::Ordinal)
    $digest = [Security.Cryptography.IncrementalHash]::CreateHash(
        [Security.Cryptography.HashAlgorithmName]::SHA256
    )
    try {
        $digest.AppendData([Text.UTF8Encoding]::new($false).GetBytes(
            "RETVRN99-WIN98-TREE-SHA256-V1`0"
        ))
        $digest.AppendData((Get-Vkd3dEvidenceBigEndianBytes $fileCount 8))
        $digest.AppendData((Get-Vkd3dEvidenceBigEndianBytes $aggregateBytes 8))
        foreach ($relative in $paths) {
            [byte[]]$path = [Text.UTF8Encoding]::new($false).GetBytes($relative)
            $record = $records[$relative]
            $digest.AppendData((Get-Vkd3dEvidenceBigEndianBytes `
                ([UInt64]$path.Length) 4))
            $digest.AppendData($path)
            $digest.AppendData((Get-Vkd3dEvidenceBigEndianBytes `
                ([UInt64]$record.bytes) 8))
            $digest.AppendData([Convert]::FromHexString([string]$record.sha256))
        }
        $treeHash = ([BitConverter]::ToString($digest.GetHashAndReset()) `
            -replace '-', '').ToLowerInvariant()
    }
    finally { $digest.Dispose() }
    $observed = [pscustomobject][ordered]@{
        file_count = $fileCount
        directory_count = $directoryCount
        total_entries = $fileCount + $directoryCount
        aggregate_bytes = $aggregateBytes
        maximum_file_bytes = $maximumFileBytes
        maximum_path_bytes = $maximumPathBytes
        digest_algorithm = 'retvrn99-file-tree-sha256-v1'
        sha256 = $treeHash
    }
    foreach ($property in @(
        'file_count', 'directory_count', 'total_entries', 'aggregate_bytes',
        'maximum_file_bytes', 'maximum_path_bytes', 'digest_algorithm', 'sha256'
    )) {
        if ($observed.$property -cne $Expected.$property) {
            throw "$Name $property differs from the toolchain lock."
        }
    }
    return $observed
}

function Get-Vkd3dEvidenceAggregateSha256 {
    param([Parameter(Mandatory = $true)][object[]]$Rows)

    $builder = [Text.StringBuilder]::new()
    $seen = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )
    foreach ($row in $Rows) {
        $path = [string]$row.relative_path
        Assert-Vkd3dEvidenceRelativePath $path 'aggregate row'
        if (-not $seen.Add($path) -or
            [string]$row.sha256 -cnotmatch '^[0-9a-f]{64}$') {
            throw "Invalid or duplicate aggregate row '$path'."
        }
    }
    [object[]]$sorted = @($Rows)
    $comparer = [Collections.Generic.Comparer[object]]::Create(
        [Comparison[object]]{
            param($left, $right)
            return [StringComparer]::Ordinal.Compare(
                [string]$left.relative_path,
                [string]$right.relative_path
            )
        }
    )
    [Array]::Sort($sorted, $comparer)
    foreach ($row in $sorted) {
        [void]$builder.Append([string]$row.relative_path)
        [void]$builder.Append("`t")
        [void]$builder.Append(([UInt64]$row.bytes).ToString(
            [Globalization.CultureInfo]::InvariantCulture
        ))
        [void]$builder.Append("`t")
        [void]$builder.Append([string]$row.sha256)
        [void]$builder.Append("`n")
    }
    return Get-Vkd3dEvidenceSha256 (
        [Text.UTF8Encoding]::new($false).GetBytes($builder.ToString())
    )
}

function Get-Vkd3dEvidenceDependencyMultiplicitySha256 {
    param([Parameter(Mandatory = $true)][object[]]$Rows)

    if ($Rows.Count -lt 1 -or $Rows.Count -gt 77824) {
        throw 'Dependency multiplicity inventory has an invalid unique count.'
    }
    $builder = [Text.StringBuilder]::new()
    $seen = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )
    foreach ($row in $Rows) {
        $path = [string]$row.relative_path
        Assert-Vkd3dEvidenceRelativePath $path 'dependency multiplicity row'
        if (-not $seen.Add($path) -or
            [UInt64]$row.occurrence_count -lt 1 -or
            [UInt64]$row.occurrence_count -gt 77824 -or
            [string]$row.sha256 -cnotmatch '^[0-9a-f]{64}$') {
            throw "Invalid dependency multiplicity row '$path'."
        }
    }
    [object[]]$sorted = @($Rows)
    [Array]::Sort($sorted, [Collections.Generic.Comparer[object]]::Create(
        [Comparison[object]]{
            param($left, $right)
            return [StringComparer]::Ordinal.Compare(
                [string]$left.relative_path,
                [string]$right.relative_path
            )
        }
    ))
    foreach ($row in $sorted) {
        [void]$builder.Append([string]$row.relative_path)
        [void]$builder.Append("`t")
        [void]$builder.Append(([UInt64]$row.occurrence_count).ToString(
            [Globalization.CultureInfo]::InvariantCulture
        ))
        [void]$builder.Append("`t")
        [void]$builder.Append(([UInt64]$row.bytes).ToString(
            [Globalization.CultureInfo]::InvariantCulture
        ))
        [void]$builder.Append("`t")
        [void]$builder.Append([string]$row.sha256)
        [void]$builder.Append("`n")
    }
    return Get-Vkd3dEvidenceSha256 (
        [Text.UTF8Encoding]::new($false).GetBytes($builder.ToString())
    )
}

function Add-Vkd3dEvidenceDependencyOccurrence {
    param(
        [Parameter(Mandatory = $true)][object]$Rows,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][UInt64]$Bytes,
        [Parameter(Mandatory = $true)][string]$Sha256,
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 77824)][UInt64]$MaximumOccurrenceCount
    )

    Assert-Vkd3dEvidenceRelativePath $RelativePath `
        'dependency occurrence path'
    if ($Bytes -gt 67108864 -or $Sha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw "Dependency occurrence '$RelativePath' has an invalid identity."
    }
    if ($Rows.ContainsKey($RelativePath)) {
        $row = $Rows[$RelativePath]
        if ([UInt64]$row.bytes -ne $Bytes -or
            [string]$row.sha256 -cne $Sha256 -or
            [UInt64]$row.occurrence_count -ge $MaximumOccurrenceCount) {
            throw "Repeated dependency '$RelativePath' changed or overflowed."
        }
        $row.occurrence_count =
            [UInt64]$row.occurrence_count + [UInt64]1
        return $row
    }
    $row = [pscustomobject][ordered]@{
        relative_path = $RelativePath
        occurrence_count = [UInt64]1
        bytes = $Bytes
        sha256 = $Sha256
    }
    $Rows.Add($RelativePath, $row)
    return $row
}

function Get-Vkd3dEvidenceDependencyTokens {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$ExpectedTarget
    )

    $joined = [Text.RegularExpressions.Regex]::Replace(
        $Text.Replace("`r`n", "`n"), '\\\n', ' '
    )
    if ($joined.Contains("`r")) { throw 'Dependency file contains a lone CR.' }
    $prefix = $ExpectedTarget + ':'
    if (-not $joined.StartsWith($prefix, [StringComparison]::Ordinal)) {
        throw 'Dependency file target differs from the exact -MT identity.'
    }
    $tokens = [Collections.Generic.List[string]]::new()
    $builder = [Text.StringBuilder]::new()
    $escaped = $false
    foreach ($character in $joined.Substring($prefix.Length).ToCharArray()) {
        if ($escaped) {
            [void]$builder.Append($character)
            $escaped = $false
        }
        elseif ($character -eq '\') { $escaped = $true }
        elseif ([char]::IsWhiteSpace($character)) {
            if ($builder.Length -gt 0) {
                $tokens.Add($builder.ToString())
                [void]$builder.Clear()
            }
        }
        else { [void]$builder.Append($character) }
    }
    if ($escaped) { throw 'Dependency file ends with an escape.' }
    if ($builder.Length -gt 0) { $tokens.Add($builder.ToString()) }
    if ($tokens.Count -eq 0) { throw 'Dependency file has no dependencies.' }
    foreach ($token in $tokens) {
        if ($token.Contains('\') -or $token -notmatch '^[A-Za-z]:/') {
            throw "Dependency token '$token' is not an unambiguous forward-slash absolute path."
        }
    }
    return @($tokens)
}

function ConvertTo-Vkd3dEvidenceLogicalPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Roots
    )

    $full = [IO.Path]::GetFullPath($Path).TrimEnd([char[]]'\/')
    $candidates = [Collections.Generic.List[object]]::new()
    foreach ($key in $Roots.Keys) {
        $root = [IO.Path]::GetFullPath([string]$Roots[$key]).TrimEnd([char[]]'\/')
        $candidates.Add([pscustomobject]@{ id = [string]$key; root = $root })
    }
    [object[]]$ordered = @($candidates)
    [Array]::Sort($ordered, [Collections.Generic.Comparer[object]]::Create(
        [Comparison[object]]{
            param($left, $right)
            return ([string]$right.root).Length.CompareTo(
                ([string]$left.root).Length
            )
        }
    ))
    foreach ($candidate in $ordered) {
        $root = [string]$candidate.root
        if ($full -ceq $root -or $full.StartsWith(
                $root + [IO.Path]::DirectorySeparatorChar,
                [StringComparison]::OrdinalIgnoreCase
            )) {
            $relative = [IO.Path]::GetRelativePath($root, $full).Replace('\', '/')
            if ($relative -ceq '.') { return "{$($candidate.id)}" }
            Assert-Vkd3dEvidenceRelativePath $relative 'logicalized dependency'
            return "{$($candidate.id)}/$relative"
        }
    }
    throw "Dependency path is outside every exact logical root."
}

function Get-Vkd3dEvidenceMakefileList {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Variable
    )

    if ($Text.Contains("`r")) { throw 'Makefile.am is not canonical LF.' }
    $pattern = '(?m)^' + [regex]::Escape($Variable) +
        ' = \\\n(?<body>(?:\t[^\n]+\n)+)'
    $matches = [regex]::Matches(
        $Text,
        $pattern,
        [Text.RegularExpressions.RegexOptions]::CultureInvariant
    )
    if ($matches.Count -ne 1) {
        throw "Makefile.am has no unique $Variable assignment."
    }
    $paths = [Collections.Generic.List[string]]::new()
    foreach ($line in $matches[0].Groups['body'].Value -split "`n") {
        $value = $line.Trim()
        if ($value.Length -eq 0) { continue }
        if ($value.EndsWith('\')) { $value = $value.Substring(0, $value.Length - 1).TrimEnd() }
        Assert-Vkd3dEvidenceRelativePath $value "$Variable entry"
        $paths.Add($value)
    }
    if ($paths.Count -eq 0) { throw "$Variable is empty." }
    return @($paths)
}

function Remove-Vkd3dEvidenceOwnedTree {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$OwnerToken,
        [Microsoft.Win32.SafeHandles.SafeFileHandle]$RootHandle,
        [Microsoft.Win32.SafeHandles.SafeFileHandle]$OwnerMarkerHandle,
        [Parameter(DontShow = $true)][scriptblock]$BeforeDelete
    )

    Initialize-Vkd3dEvidenceNative
    $full = [IO.Path]::GetFullPath($Path)
    if ($null -eq $RootHandle -and
        (Test-Vkd3dEvidencePathAbsent $full)) {
        return
    }
    $root = $RootHandle
    $markerHandle = $OwnerMarkerHandle
    $handles = [Collections.Generic.List[
        Microsoft.Win32.SafeHandles.SafeFileHandle]]::new()
    $files = [Collections.Generic.List[object]]::new()
    $directories = [Collections.Generic.List[object]]::new()
    $snapshotPaths = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    [UInt64]$entryCount = 0
    [UInt64]$directoryCount = 0
    [UInt64]$aggregateBytes = 0
    try {
        if ($null -eq $root) {
            $root = Open-Vkd3dEvidenceDeleteHandle $full 'proof root'
        }
        $handles.Add($root)
        [UInt32]$rootAttributes = `
            [Retvrn99.Vkd3dEvidenceNative]::GetAttributes($root)
        if (($rootAttributes -band [IO.FileAttributes]::Directory) -eq 0 -or
            ($rootAttributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            ($rootAttributes -band [IO.FileAttributes]::Device) -ne 0) {
            throw 'Owned proof root is not one ordinary directory.'
        }
        $directories.Add([pscustomobject]@{
            Path = $full; Depth = 0; Handle = $root
        })
        $marker = [IO.Path]::GetFullPath(
            (Join-Path $full '.retvrn99-vkd3d-proof-owner')
        )
        if ($null -eq $markerHandle) {
            $markerHandle = Open-Vkd3dEvidenceDeleteHandle $marker `
                'proof ownership marker'
        }
        if (-not [object]::ReferenceEquals($markerHandle, $root)) {
            $handles.Add($markerHandle)
        }
        [UInt32]$markerAttributes = `
            [Retvrn99.Vkd3dEvidenceNative]::GetAttributes($markerHandle)
        if (($markerAttributes -band [IO.FileAttributes]::Directory) -ne 0 -or
            ($markerAttributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            ($markerAttributes -band [IO.FileAttributes]::Device) -ne 0) {
            throw 'Proof ownership marker is not one ordinary file.'
        }
        [byte[]]$markerBytes = [Retvrn99.Vkd3dEvidenceNative]::ReadAll(
            $markerHandle, 256
        )
        $observed = ConvertFrom-Vkd3dEvidenceUtf8 $markerBytes `
            'proof ownership marker'
        if ($observed -cne $OwnerToken) {
            throw 'Refusing to remove a proof root with a different owner token.'
        }

        $pending = [Collections.Generic.Stack[object]]::new()
        $pending.Push([pscustomobject]@{ Path = $full; Depth = 0 })
        $markerFound = $false
        while ($pending.Count -gt 0) {
            $directory = $pending.Pop()
            try {
                [string[]]$entries = @(
                    [IO.Directory]::EnumerateFileSystemEntries($directory.Path)
                )
            }
            catch {
                throw 'Owned proof root could not be snapshotted safely.'
            }
            foreach ($entry in $entries) {
                $entryCount++
                if ($entryCount -gt 4096) {
                    throw 'Owned proof root exceeds its cleanup entry bound.'
                }
                $entryFull = [IO.Path]::GetFullPath($entry)
                if (-not $snapshotPaths.Add($entryFull)) {
                    throw 'Owned proof root duplicates a cleanup path.'
                }
                if ($entryFull.Equals(
                        $marker,
                        [StringComparison]::OrdinalIgnoreCase
                    )) {
                    if ($markerFound) {
                        throw 'Owned proof root duplicates its ownership marker.'
                    }
                    $markerFound = $true
                    $entryHandle = $markerHandle
                }
                else {
                    $entryHandle = Open-Vkd3dEvidenceDeleteHandle $entryFull `
                        'owned cleanup entry'
                    $handles.Add($entryHandle)
                }
                [UInt32]$attributes = `
                    [Retvrn99.Vkd3dEvidenceNative]::GetAttributes($entryHandle)
                if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                    ($attributes -band [IO.FileAttributes]::Device) -ne 0) {
                    throw 'Owned proof root contains a non-ordinary cleanup entry.'
                }
                if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) {
                    if ($entryHandle -eq $markerHandle) {
                        throw 'Proof ownership marker changed into a directory.'
                    }
                    $directoryCount++
                    if ($directoryCount -gt 512) {
                        throw 'Owned proof root exceeds its cleanup directory bound.'
                    }
                    $depth = [int]$directory.Depth + 1
                    $directories.Add([pscustomobject]@{
                        Path = $entryFull; Depth = $depth; Handle = $entryHandle
                    })
                    $pending.Push([pscustomobject]@{
                        Path = $entryFull; Depth = $depth
                    })
                    continue
                }
                $identity = Get-Vkd3dEvidenceHandleIdentity $entryHandle `
                    'owned cleanup file' 268435456
                $aggregateBytes += [UInt64]$identity.bytes
                if ($aggregateBytes -gt 1073741824) {
                    throw 'Owned proof root exceeds its cleanup byte bound.'
                }
                $files.Add([pscustomobject]@{
                    Path = $entryFull; Handle = $entryHandle
                })
            }
        }
        if (-not $markerFound) {
            throw 'Owned proof root lost its ownership marker.'
        }
        if ($null -ne $BeforeDelete) { & $BeforeDelete $full | Out-Null }
        $recheck = [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase
        )
        foreach ($directory in $directories) {
            foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries(
                    $directory.Path
                )) {
                if (-not $recheck.Add([IO.Path]::GetFullPath($entry))) {
                    throw 'Owned proof root duplicates a rechecked path.'
                }
            }
        }
        if ($recheck.Count -ne $snapshotPaths.Count -or
            @($snapshotPaths | Where-Object { -not $recheck.Contains($_) }).Count -ne 0) {
            throw 'Owned proof root changed after its cleanup snapshot.'
        }

        $failures = [Collections.Generic.List[Exception]]::new()
        foreach ($file in $files) {
            try {
                Set-Vkd3dEvidenceBoundHandleDelete $root $file.Handle `
                    $full $file.Path 'owned cleanup file'
            }
            catch { $failures.Add($_.Exception) }
            finally { $file.Handle.Dispose() }
        }
        [object[]]$orderedDirectories = @($directories)
        [Array]::Sort($orderedDirectories,
            [Collections.Generic.Comparer[object]]::Create(
                [Comparison[object]]{
                    param($left, $right)
                    return ([int]$right.Depth).CompareTo([int]$left.Depth)
                }
            ))
        foreach ($directory in $orderedDirectories) {
            try {
                Set-Vkd3dEvidenceBoundHandleDelete $root `
                    $directory.Handle $full $directory.Path `
                    'owned cleanup directory'
            }
            catch { $failures.Add($_.Exception) }
            finally { $directory.Handle.Dispose() }
        }
        if ($failures.Count -gt 0) {
            throw [AggregateException]::new(
                'Owned proof cleanup failed.',
                [Exception[]]$failures.ToArray()
            )
        }
    }
    finally {
        foreach ($handle in $handles) {
            if ($null -ne $handle -and -not $handle.IsClosed) {
                $handle.Dispose()
            }
        }
    }
    Assert-Vkd3dEvidencePathAbsent $full 'Owned proof root'
}

function Remove-Vkd3dEvidenceBootstrapTree {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][bool]$MarkerCreated,
        [Microsoft.Win32.SafeHandles.SafeFileHandle]$RootHandle,
        [Microsoft.Win32.SafeHandles.SafeFileHandle]$OwnerMarkerHandle,
        [Parameter(DontShow = $true)][scriptblock]$BeforeDelete
    )

    Initialize-Vkd3dEvidenceNative
    $full = [IO.Path]::GetFullPath($Path)
    if ($null -eq $RootHandle -and
        (Test-Vkd3dEvidencePathAbsent $full)) {
        return
    }
    $root = $RootHandle
    $markerHandle = $OwnerMarkerHandle
    $handles = [Collections.Generic.List[
        Microsoft.Win32.SafeHandles.SafeFileHandle]]::new()
    try {
        if ($null -eq $root) {
            $root = Open-Vkd3dEvidenceDeleteHandle $full `
                'bootstrap proof root'
        }
        $handles.Add($root)
        [UInt32]$rootAttributes = `
            [Retvrn99.Vkd3dEvidenceNative]::GetAttributes($root)
        if (($rootAttributes -band [IO.FileAttributes]::Directory) -eq 0 -or
            ($rootAttributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            ($rootAttributes -band [IO.FileAttributes]::Device) -ne 0) {
            throw 'Bootstrap proof root is not one ordinary directory.'
        }
        try {
            [string[]]$entries = @(
                [IO.Directory]::EnumerateFileSystemEntries($full)
            )
        }
        catch {
            throw 'Bootstrap proof root could not be snapshotted safely.'
        }
        if ($entries.Count -gt 1) {
            throw 'Bootstrap proof root contains foreign entries.'
        }
        if ($entries.Count -eq 1) {
            $marker = [IO.Path]::GetFullPath(
                (Join-Path $full '.retvrn99-vkd3d-proof-owner')
            )
            $entry = [IO.Path]::GetFullPath($entries[0])
            if (-not $MarkerCreated -or -not $entry.Equals(
                    $marker,
                    [StringComparison]::OrdinalIgnoreCase
                )) {
                throw 'Bootstrap proof root contains a foreign entry.'
            }
            if ($null -eq $markerHandle) {
                $markerHandle = Open-Vkd3dEvidenceDeleteHandle $marker `
                    'bootstrap ownership marker'
            }
            $handles.Add($markerHandle)
            [UInt32]$attributes = `
                [Retvrn99.Vkd3dEvidenceNative]::GetAttributes($markerHandle)
            if (($attributes -band [IO.FileAttributes]::Directory) -ne 0 -or
                ($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                ($attributes -band [IO.FileAttributes]::Device) -ne 0) {
                throw 'Bootstrap ownership marker is not one ordinary file.'
            }
            if ($null -ne $BeforeDelete) { & $BeforeDelete $full | Out-Null }
            [string[]]$recheck = @(
                [IO.Directory]::EnumerateFileSystemEntries($full)
            )
            if ($recheck.Count -ne 1 -or
                -not [IO.Path]::GetFullPath($recheck[0]).Equals(
                    $marker,
                    [StringComparison]::OrdinalIgnoreCase
                )) {
                throw 'Bootstrap proof root changed after its cleanup snapshot.'
            }
            Set-Vkd3dEvidenceBoundHandleDelete $root $markerHandle `
                $full $marker 'bootstrap ownership marker'
            $markerHandle.Dispose()
        }
        elseif ($null -ne $BeforeDelete) {
            & $BeforeDelete $full | Out-Null
            if (@([IO.Directory]::EnumerateFileSystemEntries($full)).Count -ne 0) {
                throw 'Bootstrap proof root changed after its cleanup snapshot.'
            }
        }
        Set-Vkd3dEvidenceBoundHandleDelete $root $root $full $full `
            'bootstrap proof root'
        $root.Dispose()
    }
    finally {
        foreach ($handle in $handles) {
            if ($null -ne $handle -and -not $handle.IsClosed) {
                $handle.Dispose()
            }
        }
    }
    Assert-Vkd3dEvidencePathAbsent $full 'Bootstrap proof root'
}
