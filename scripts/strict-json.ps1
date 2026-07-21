# SPDX-License-Identifier: GPL-3.0-only

function Skip-GswJsonWhitespace {
    param(
        [string]$Json,
        [ref]$Position
    )

    while ($Position.Value -lt $Json.Length) {
        $character = $Json[$Position.Value]
        if ($character -ne ' ' -and $character -ne "`t" -and
            $character -ne "`r" -and $character -ne "`n") {
            return
        }
        $Position.Value += 1
    }
}

function Read-GswJsonString {
    param(
        [string]$Json,
        [ref]$Position,
        [string]$Source
    )

    if ($Position.Value -ge $Json.Length -or $Json[$Position.Value] -ne '"') {
        throw "Invalid JSON string in $Source."
    }
    $Position.Value += 1
    $builder = [Text.StringBuilder]::new()
    while ($Position.Value -lt $Json.Length) {
        $character = $Json[$Position.Value]
        $Position.Value += 1
        if ($character -eq '"') {
            return $builder.ToString()
        }
        if ([int][char]$character -lt 0x20) {
            throw "Invalid control character in JSON string in $Source."
        }
        if ($character -ne '\') {
            [void]$builder.Append($character)
            continue
        }
        if ($Position.Value -ge $Json.Length) {
            throw "Incomplete JSON escape in $Source."
        }
        $escaped = $Json[$Position.Value]
        $Position.Value += 1
        switch ($escaped) {
            '"' { [void]$builder.Append('"') }
            '\' { [void]$builder.Append('\') }
            '/' { [void]$builder.Append('/') }
            'b' { [void]$builder.Append([char]0x08) }
            'f' { [void]$builder.Append([char]0x0c) }
            'n' { [void]$builder.Append([char]0x0a) }
            'r' { [void]$builder.Append([char]0x0d) }
            't' { [void]$builder.Append([char]0x09) }
            'u' {
                if ($Position.Value + 4 -gt $Json.Length) {
                    throw "Incomplete JSON Unicode escape in $Source."
                }
                $hex = $Json.Substring($Position.Value, 4)
                if ($hex -cnotmatch '^[0-9a-fA-F]{4}$') {
                    throw "Invalid JSON Unicode escape in $Source."
                }
                [void]$builder.Append([char][Convert]::ToInt32($hex, 16))
                $Position.Value += 4
            }
            default { throw "Invalid JSON escape in $Source." }
        }
    }
    throw "Unterminated JSON string in $Source."
}

function Read-GswJsonValue {
    param(
        [string]$Json,
        [ref]$Position,
        [string]$Source,
        [int]$Depth
    )

    if ($Depth -gt 16) {
        throw "JSON nesting exceeds the depth bound in $Source."
    }
    Skip-GswJsonWhitespace $Json $Position
    if ($Position.Value -ge $Json.Length) {
        throw "Incomplete JSON value in $Source."
    }
    switch ($Json[$Position.Value]) {
        '{' {
            Read-GswJsonObject $Json $Position $Source $Depth
            return
        }
        '[' {
            Read-GswJsonArray $Json $Position $Source $Depth
            return
        }
        '"' {
            $null = Read-GswJsonString $Json $Position $Source
            return
        }
    }

    $start = $Position.Value
    while ($Position.Value -lt $Json.Length) {
        $character = $Json[$Position.Value]
        if ($character -eq ',' -or $character -eq ']' -or $character -eq '}' -or
            $character -eq ' ' -or $character -eq "`t" -or
            $character -eq "`r" -or $character -eq "`n") {
            break
        }
        $Position.Value += 1
    }
    if ($Position.Value -eq $start) {
        throw "Invalid JSON value in $Source."
    }
    $token = $Json.Substring($start, $Position.Value - $start)
    $isKeyword = $token -ceq 'true' -or $token -ceq 'false' -or $token -ceq 'null'
    $isNumber = $token -cmatch '^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$'
    if (-not $isKeyword -and -not $isNumber) {
        throw "Invalid JSON primitive token '$token' in $Source."
    }
}

function Read-GswJsonObject {
    param(
        [string]$Json,
        [ref]$Position,
        [string]$Source,
        [int]$Depth
    )

    $Position.Value += 1
    $properties = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    Skip-GswJsonWhitespace $Json $Position
    if ($Position.Value -lt $Json.Length -and $Json[$Position.Value] -eq '}') {
        $Position.Value += 1
        return
    }

    while ($Position.Value -lt $Json.Length) {
        Skip-GswJsonWhitespace $Json $Position
        $name = [string](Read-GswJsonString $Json $Position $Source)
        if (-not $properties.Add($name)) {
            throw "Duplicate JSON property '$name' in $Source."
        }
        Skip-GswJsonWhitespace $Json $Position
        if ($Position.Value -ge $Json.Length -or $Json[$Position.Value] -ne ':') {
            throw "Missing JSON property separator in $Source."
        }
        $Position.Value += 1
        Read-GswJsonValue $Json $Position $Source ($Depth + 1)
        Skip-GswJsonWhitespace $Json $Position
        if ($Position.Value -ge $Json.Length) {
            throw "Unterminated JSON object in $Source."
        }
        if ($Json[$Position.Value] -eq '}') {
            $Position.Value += 1
            return
        }
        if ($Json[$Position.Value] -ne ',') {
            throw "Invalid JSON object separator in $Source."
        }
        $Position.Value += 1
    }
    throw "Unterminated JSON object in $Source."
}

function Read-GswJsonArray {
    param(
        [string]$Json,
        [ref]$Position,
        [string]$Source,
        [int]$Depth
    )

    $Position.Value += 1
    Skip-GswJsonWhitespace $Json $Position
    if ($Position.Value -lt $Json.Length -and $Json[$Position.Value] -eq ']') {
        $Position.Value += 1
        return
    }

    while ($Position.Value -lt $Json.Length) {
        Read-GswJsonValue $Json $Position $Source ($Depth + 1)
        Skip-GswJsonWhitespace $Json $Position
        if ($Position.Value -ge $Json.Length) {
            throw "Unterminated JSON array in $Source."
        }
        if ($Json[$Position.Value] -eq ']') {
            $Position.Value += 1
            return
        }
        if ($Json[$Position.Value] -ne ',') {
            throw "Invalid JSON array separator in $Source."
        }
        $Position.Value += 1
    }
    throw "Unterminated JSON array in $Source."
}

function ConvertFrom-GswStrictJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Json,
        [string]$Source = 'JSON input'
    )

    $position = 0
    Read-GswJsonValue $Json ([ref]$position) $Source 0
    Skip-GswJsonWhitespace $Json ([ref]$position)
    if ($position -ne $Json.Length) {
        throw "Unexpected trailing JSON content in $Source."
    }
    return $Json | ConvertFrom-Json
}

function Assert-GswJsonBoolean {
    param(
        [object]$Value,
        [string]$Label
    )

    if ($Value -isnot [bool]) {
        throw "$Label must be a JSON Boolean."
    }
}

function Assert-GswJsonInteger {
    param(
        [object]$Value,
        [string]$Label
    )

    $types = @(
        [byte], [uint16], [uint32], [uint64],
        [sbyte], [int16], [int32], [int64]
    )
    if ($null -eq $Value -or $types -cnotcontains $Value.GetType()) {
        throw "$Label must be a JSON integer."
    }
}

function Assert-GswJsonArray {
    param(
        [object]$Value,
        [string]$Label
    )

    if ($Value -isnot [Array]) {
        throw "$Label must be a JSON array."
    }
}

function Assert-GswJsonString {
    param(
        [object]$Value,
        [string]$Label
    )

    if ($Value -isnot [string]) {
        throw "$Label must be a JSON string."
    }
}

function Assert-GswJsonExactProperties {
    param(
        [object]$Value,
        [string[]]$Expected,
        [string]$Label
    )

    if ($null -eq $Value) {
        throw "$Label is missing."
    }
    $actual = @($Value.PSObject.Properties.Name)
    if ($actual.Count -ne $Expected.Count) {
        throw "$Label fields do not match its schema."
    }
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($name in $actual) {
        if (-not $names.Add([string]$name)) {
            throw "$Label contains a duplicate field."
        }
    }
    foreach ($name in $Expected) {
        if (-not $names.Contains($name)) {
            throw "$Label fields do not match its schema."
        }
    }
}

function Assert-GswNoReparseAncestor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name
    )

    $current = [IO.Path]::GetFullPath($Path)
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($null -ne $item -and
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Name traverses reparse point '$current'."
        }
        $parent = [IO.Path]::GetDirectoryName($current)
        if ([string]::IsNullOrWhiteSpace($parent) -or
            $parent.Equals($current, [StringComparison]::OrdinalIgnoreCase)) {
            break
        }
        $current = $parent
    }
}

function Get-GswSha256Hex {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes
    )

    $digest = [Security.Cryptography.SHA256]::Create()
    try {
        [byte[]]$hash = $digest.ComputeHash($Bytes)
    }
    finally {
        $digest.Dispose()
    }
    return ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
}

function Get-GswBoundedStreamSha256Hex {
    param(
        [Parameter(Mandatory = $true)][IO.Stream]$Stream,
        [Parameter(Mandatory = $true)][UInt64]$ExpectedLength,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $digest = [Security.Cryptography.SHA256]::Create()
    try {
        $buffer = New-Object byte[] 65536
        [UInt64]$total = 0
        while ($total -lt $ExpectedLength) {
            $remaining = $ExpectedLength - $total
            $request = [int][Math]::Min([UInt64]$buffer.Length, $remaining)
            $read = $Stream.Read($buffer, 0, $request)
            if ($read -le 0) {
                throw "$Name ended before its opened length."
            }
            [void]$digest.TransformBlock($buffer, 0, $read, $buffer, 0)
            $total += [UInt64]$read
        }
        if ($Stream.ReadByte() -ne -1 -or [UInt64]$Stream.Length -ne $ExpectedLength) {
            throw "$Name changed while its content was rechecked."
        }
        [void]$digest.TransformFinalBlock((New-Object byte[] 0), 0, 0)
        return ([BitConverter]::ToString($digest.Hash) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $digest.Dispose()
    }
}

function Assert-GswStableFileIdentity {
    param(
        [Parameter(Mandatory = $true)][IO.FileInfo]$Before,
        [Parameter(Mandatory = $true)][IO.FileInfo]$After,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ([UInt64]$After.Length -ne [UInt64]$Before.Length -or
        $After.CreationTimeUtc.Ticks -ne $Before.CreationTimeUtc.Ticks -or
        $After.LastWriteTimeUtc.Ticks -ne $Before.LastWriteTimeUtc.Ticks -or
        $After.Attributes -ne $Before.Attributes -or
        -not $After.FullName.Equals($Before.FullName, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Name changed during its bounded read."
    }
}

function Read-GswBoundedFileSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [UInt64]$MaximumBytes,

        [switch]$AllowEmpty,

        [scriptblock]$BeforePostReadCheck
    )

    if ($MaximumBytes -eq 0 -or $MaximumBytes -gt [int]::MaxValue) {
        throw "$Name declares an invalid byte bound."
    }
    $fullPath = [IO.Path]::GetFullPath($Path)
    Assert-GswNoReparseAncestor $fullPath $Name
    $before = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
    if (($before.Attributes -band [IO.FileAttributes]::Directory) -ne 0 -or
        ($before.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        ($before.Attributes -band [IO.FileAttributes]::Device) -ne 0) {
        throw "$Name must be one regular file."
    }
    if (-not $AllowEmpty -and $before.Length -eq 0) {
        throw "$Name must not be empty."
    }
    if ([UInt64]$before.Length -gt $MaximumBytes) {
        throw "$Name exceeds the $MaximumBytes-byte bound."
    }

    $stream = [IO.File]::Open(
        $fullPath,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read
    )
    try {
        Assert-GswNoReparseAncestor $fullPath $Name
        [UInt64]$length = $stream.Length
        if ($length -ne [UInt64]$before.Length -or
            (-not $AllowEmpty -and $length -eq 0) -or
            $length -gt $MaximumBytes -or $length -gt [int]::MaxValue) {
            throw "$Name changed while it was opened or exceeds its byte bound."
        }
        $bytes = New-Object byte[] ([int]$length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -le 0) {
                throw "$Name ended before its opened length."
            }
            $offset += $read
        }
        if ($stream.ReadByte() -ne -1 -or [UInt64]$stream.Length -ne $length) {
            throw "$Name changed while it was read."
        }
        $hash = Get-GswSha256Hex $bytes

        if ($null -ne $BeforePostReadCheck) {
            try {
                & $BeforePostReadCheck $fullPath | Out-Null
            }
            catch {
                throw "$Name changed during its bounded read: $($_.Exception.Message)"
            }
        }

        Assert-GswNoReparseAncestor $fullPath $Name
        $during = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
        if (($during.Attributes -band [IO.FileAttributes]::Directory) -ne 0 -or
            ($during.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            ($during.Attributes -band [IO.FileAttributes]::Device) -ne 0) {
            throw "$Name changed during its bounded read."
        }
        Assert-GswStableFileIdentity -Before $before -After $during -Name $Name

        $recheckStream = [IO.File]::Open(
            $fullPath,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::Read
        )
        try {
            if ([UInt64]$recheckStream.Length -ne $length) {
                throw "$Name changed during its bounded read."
            }
            $recheckHash = Get-GswBoundedStreamSha256Hex -Stream $recheckStream `
                -ExpectedLength $length -Name $Name
        }
        finally {
            $recheckStream.Dispose()
        }

        Assert-GswNoReparseAncestor $fullPath $Name
        $after = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
        if (($after.Attributes -band [IO.FileAttributes]::Directory) -ne 0 -or
            ($after.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            ($after.Attributes -band [IO.FileAttributes]::Device) -ne 0) {
            throw "$Name changed during its bounded read."
        }
        Assert-GswStableFileIdentity -Before $before -After $after -Name $Name
        if ($recheckHash -cne $hash) {
            throw "$Name content changed during its bounded read."
        }
    }
    finally {
        $stream.Dispose()
    }
    return [pscustomobject]@{
        Path = $fullPath
        Bytes = $bytes
        Length = [UInt64]$bytes.Length
        Sha256 = $hash
    }
}

function Read-GswBoundedFileBytes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][UInt64]$MaximumBytes,
        [switch]$AllowEmpty,
        [scriptblock]$BeforePostReadCheck
    )

    $snapshot = Read-GswBoundedFileSnapshot -Path $Path -Name $Name `
        -MaximumBytes $MaximumBytes -AllowEmpty:$AllowEmpty `
        -BeforePostReadCheck $BeforePostReadCheck
    return ,([byte[]]$snapshot.Bytes)
}

function ConvertFrom-GswStrictUtf8Bytes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Source
    )

    $hasUtf8Bom = $Bytes.Length -ge 3 -and $Bytes[0] -eq 0xef -and
        $Bytes[1] -eq 0xbb -and $Bytes[2] -eq 0xbf
    $hasUtf16Bom = $Bytes.Length -ge 2 -and (
        ($Bytes[0] -eq 0xff -and $Bytes[1] -eq 0xfe) -or
        ($Bytes[0] -eq 0xfe -and $Bytes[1] -eq 0xff)
    )
    $hasUtf32BeBom = $Bytes.Length -ge 4 -and $Bytes[0] -eq 0x00 -and
        $Bytes[1] -eq 0x00 -and $Bytes[2] -eq 0xfe -and $Bytes[3] -eq 0xff
    if ($hasUtf8Bom -or $hasUtf16Bom -or $hasUtf32BeBom) {
        throw "$Source must be strict UTF-8 without a byte-order mark."
    }
    try {
        return [Text.UTF8Encoding]::new($false, $true).GetString($Bytes)
    }
    catch {
        throw "$Source is not strict UTF-8."
    }
}

function ConvertFrom-GswStrictJsonUtf8Bytes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Source
    )

    $json = ConvertFrom-GswStrictUtf8Bytes -Bytes $Bytes -Source $Source
    return ConvertFrom-GswStrictJson -Json $json -Source $Source
}

function Read-GswStrictJsonFileSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][UInt64]$MaximumBytes,
        [scriptblock]$BeforePostReadCheck
    )

    $snapshot = Read-GswBoundedFileSnapshot -Path $Path -Name $Name `
        -MaximumBytes $MaximumBytes -BeforePostReadCheck $BeforePostReadCheck
    $text = ConvertFrom-GswStrictUtf8Bytes -Bytes $snapshot.Bytes -Source $Name
    $value = ConvertFrom-GswStrictJson -Json $text -Source $Name
    return [pscustomobject]@{
        Path = $snapshot.Path
        Bytes = $snapshot.Bytes
        Length = $snapshot.Length
        Sha256 = $snapshot.Sha256
        Text = $text
        Value = $value
    }
}

function Read-GswStrictJsonFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][UInt64]$MaximumBytes,
        [scriptblock]$BeforePostReadCheck
    )

    return (Read-GswStrictJsonFileSnapshot -Path $Path -Name $Name `
        -MaximumBytes $MaximumBytes `
        -BeforePostReadCheck $BeforePostReadCheck).Value
}
