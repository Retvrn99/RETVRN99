# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [string]$ProfileFile,

    [string]$EvidenceRoot,

    [switch]$PolicyAudit,

    [switch]$CandidateEvidenceAudit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:MaximumProfileBytes = [UInt64]1048576
$script:MaximumPathBytes = 512
$script:MingwRequiredFeatures = @('mmx', 'sse', 'sse2', 'sse3')
$script:MingwDisabledFeatures = @(
    'cx16', 'ssse3', 'sse4', 'sse4a', 'avx', 'avx2', 'avx512',
    'aes', 'pclmul', 'fma', 'fma4', 'f16c', 'xop', 'bmi', 'bmi2',
    'abm', 'tbm', 'movbe', 'rdrand', 'rdseed', 'adx', 'sha', 'gfni',
    'vaes', 'vpclmulqdq', 'rtm', 'hle', 'sgx', 'pku', 'xsave',
    'waitpkg', 'enqcmd', 'movdir', 'serialize', 'uintr', 'amx'
)
$script:MingwCpuFlags = @(
    '-march=i686',
    '-mmmx',
    '-msse',
    '-msse2',
    '-msse3',
    '-mno-cx16',
    '-mno-ssse3',
    '-mno-sse4',
    '-mno-sse4.1',
    '-mno-sse4.2',
    '-mno-sse4a',
    '-mno-avx',
    '-mno-avx2',
    '-mno-avx512f',
    '-mno-avx512bw',
    '-mno-avx512cd',
    '-mno-avx512dq',
    '-mno-avx512vl',
    '-mno-aes',
    '-mno-pclmul',
    '-mno-fma',
    '-mno-fma4',
    '-mno-f16c',
    '-mno-xop',
    '-mno-bmi',
    '-mno-bmi2',
    '-mno-abm',
    '-mno-tbm',
    '-mno-movbe',
    '-mno-rdrnd',
    '-mno-rdseed',
    '-mno-adx',
    '-mno-sha',
    '-mno-gfni',
    '-mno-vaes',
    '-mno-vpclmulqdq',
    '-mno-rtm',
    '-mno-hle',
    '-mno-sgx',
    '-mno-pku',
    '-mno-xsave',
    '-mno-waitpkg',
    '-mno-enqcmd',
    '-mno-movdiri',
    '-mno-movdir64b',
    '-mno-serialize',
    '-mno-uintr',
    '-mno-amx-tile',
    '-mno-amx-int8',
    '-mno-amx-bf16'
)
$script:WatcomCpuFlags = @('-6s', '-fpi87')

if ([string]::IsNullOrWhiteSpace($ProfileFile)) {
    $ProfileFile = Join-Path $PSScriptRoot '..\drivers\win98\guest-cpu-profile.json'
}
if ($PolicyAudit -and $CandidateEvidenceAudit) {
    throw 'PolicyAudit and CandidateEvidenceAudit are mutually exclusive.'
}

function Get-FullPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }
    return [IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

function Assert-NoReparseAncestor {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $fullPath = Get-FullPath $Path
    $pathRoot = [IO.Path]::GetPathRoot($fullPath)
    if ([string]::IsNullOrWhiteSpace($pathRoot)) {
        throw "$Name has no filesystem root."
    }
    $current = $pathRoot
    $remainder = $fullPath.Substring($pathRoot.Length)
    $components = @(
        $remainder.Split(
            [char[]]@(
                [IO.Path]::DirectorySeparatorChar,
                [IO.Path]::AltDirectorySeparatorChar
            ),
            [StringSplitOptions]::RemoveEmptyEntries
        )
    )
    foreach ($component in $components) {
        $current = Join-Path $current $component
        if (-not (Test-Path -LiteralPath $current)) {
            throw "$Name path component is absent: $current"
        }
        $item = Get-Item -LiteralPath $current -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Name cannot cross a reparse point: $current"
        }
    }
}

function Assert-SafeRelativePath {
    param(
        [Parameter(Mandatory = $true)][object]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($RelativePath -isnot [string] -or
        [string]::IsNullOrWhiteSpace($RelativePath) -or
        [IO.Path]::IsPathRooted($RelativePath) -or
        $RelativePath.Contains('\') -or
        [Text.Encoding]::UTF8.GetByteCount($RelativePath) -gt $script:MaximumPathBytes) {
        throw "Unsafe relative path '$RelativePath' in $Name."
    }
    foreach ($component in $RelativePath.Split('/')) {
        if ([string]::IsNullOrWhiteSpace($component) -or
            $component -in @('.', '..') -or
            $component -match '[\x00-\x1f:*?"<>|]' -or
            $component.EndsWith('.') -or
            $component.EndsWith(' ') -or
            $component -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$') {
            throw "Unsafe path component '$component' in $Name."
        }
    }
}

function Get-ContainedExistingFile {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][object]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Name
    )

    Assert-SafeRelativePath $RelativePath $Name
    $rootPath = Get-FullPath $Root
    if (-not (Test-Path -LiteralPath $rootPath -PathType Container)) {
        throw "$Name root not found: $rootPath"
    }
    Assert-NoReparseAncestor $rootPath "$Name root"
    $rootItem = Get-Item -LiteralPath $rootPath -Force
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Name root cannot be a reparse point."
    }

    $current = $rootPath
    foreach ($component in $RelativePath.Split('/')) {
        $caseMatches = @(
            [IO.Directory]::EnumerateFileSystemEntries($current) |
                Where-Object {
                    [IO.Path]::GetFileName($_).Equals(
                        $component,
                        [StringComparison]::OrdinalIgnoreCase
                    )
                }
        )
        if ($caseMatches.Count -ne 1 -or
            [IO.Path]::GetFileName($caseMatches[0]) -cne $component) {
            throw "$Name path is absent or does not use exact filesystem casing: $RelativePath"
        }
        $current = $caseMatches[0]
        $item = Get-Item -LiteralPath $current -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Name crosses a reparse point: $RelativePath"
        }
    }
    if (-not (Test-Path -LiteralPath $current -PathType Leaf)) {
        throw "$Name is not a regular file: $RelativePath"
    }
    Assert-NoReparseAncestor $current $Name
    return [IO.Path]::GetFullPath($current)
}

function Get-Sha256Hex {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        [byte[]]$hash = $sha.ComputeHash($Bytes)
    }
    finally {
        $sha.Dispose()
    }
    return ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
}

function Read-BoundedFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][UInt64]$MaximumBytes,
        [Parameter(Mandatory = $true)][string]$Name
    )

    Assert-NoReparseAncestor $Path $Name
    $stream = [IO.File]::Open(
        $Path,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read
    )
    try {
        Assert-NoReparseAncestor $Path $Name
        [UInt64]$length = $stream.Length
        if ($length -eq 0 -or $length -gt $MaximumBytes -or
            $length -gt [int]::MaxValue) {
            throw "$Name byte count is outside its bound."
        }
        $bytes = New-Object byte[] ([int]$length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -eq 0) {
                throw "Unexpected end of file while reading $Name."
            }
            $offset += $read
        }
        Assert-NoReparseAncestor $Path $Name
        $finalItem = Get-Item -LiteralPath $Path -Force
        if (($finalItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            [UInt64]$finalItem.Length -ne $length -or $stream.Length -ne $length) {
            throw "$Name changed while it was being read."
        }
    }
    finally {
        $stream.Dispose()
    }
    return ,$bytes
}

function Skip-GuestCpuJsonWhitespace {
    param(
        [Parameter(Mandatory = $true)][string]$Json,
        [Parameter(Mandatory = $true)][ref]$Position
    )

    while ($Position.Value -lt $Json.Length) {
        if ($Json[$Position.Value] -notin @(' ', "`t", "`r", "`n")) {
            return
        }
        $Position.Value++
    }
}

function Read-GuestCpuJsonString {
    param(
        [Parameter(Mandatory = $true)][string]$Json,
        [Parameter(Mandatory = $true)][ref]$Position,
        [Parameter(Mandatory = $true)][string]$Source
    )

    if ($Position.Value -ge $Json.Length -or $Json[$Position.Value] -ne '"') {
        throw "Invalid JSON string in $Source."
    }
    $Position.Value++
    $builder = [Text.StringBuilder]::new()
    while ($Position.Value -lt $Json.Length) {
        $character = $Json[$Position.Value]
        $Position.Value++
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
        $Position.Value++
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

function Read-GuestCpuJsonValue {
    param(
        [Parameter(Mandatory = $true)][string]$Json,
        [Parameter(Mandatory = $true)][ref]$Position,
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][int]$Depth
    )

    if ($Depth -gt 16) {
        throw "JSON nesting exceeds the depth bound in $Source."
    }
    Skip-GuestCpuJsonWhitespace $Json $Position
    if ($Position.Value -ge $Json.Length) {
        throw "Incomplete JSON value in $Source."
    }
    switch ($Json[$Position.Value]) {
        '{' {
            Read-GuestCpuJsonObject $Json $Position $Source $Depth
            return
        }
        '[' {
            Read-GuestCpuJsonArray $Json $Position $Source $Depth
            return
        }
        '"' {
            $null = Read-GuestCpuJsonString $Json $Position $Source
            return
        }
    }

    $start = $Position.Value
    while ($Position.Value -lt $Json.Length) {
        if ($Json[$Position.Value] -in @(',', ']', '}', ' ', "`t", "`r", "`n")) {
            break
        }
        $Position.Value++
    }
    if ($Position.Value -eq $start) {
        throw "Invalid JSON value in $Source."
    }
}

function Read-GuestCpuJsonObject {
    param(
        [Parameter(Mandatory = $true)][string]$Json,
        [Parameter(Mandatory = $true)][ref]$Position,
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][int]$Depth
    )

    $Position.Value++
    $properties = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    Skip-GuestCpuJsonWhitespace $Json $Position
    if ($Position.Value -lt $Json.Length -and $Json[$Position.Value] -eq '}') {
        $Position.Value++
        return
    }
    while ($Position.Value -lt $Json.Length) {
        Skip-GuestCpuJsonWhitespace $Json $Position
        $name = [string](Read-GuestCpuJsonString $Json $Position $Source)
        if (-not $properties.Add($name)) {
            throw "Duplicate JSON property '$name' in $Source."
        }
        Skip-GuestCpuJsonWhitespace $Json $Position
        if ($Position.Value -ge $Json.Length -or $Json[$Position.Value] -ne ':') {
            throw "Missing JSON property separator in $Source."
        }
        $Position.Value++
        Read-GuestCpuJsonValue $Json $Position $Source ($Depth + 1)
        Skip-GuestCpuJsonWhitespace $Json $Position
        if ($Position.Value -ge $Json.Length) {
            throw "Unterminated JSON object in $Source."
        }
        if ($Json[$Position.Value] -eq '}') {
            $Position.Value++
            return
        }
        if ($Json[$Position.Value] -ne ',') {
            throw "Invalid JSON object separator in $Source."
        }
        $Position.Value++
    }
    throw "Unterminated JSON object in $Source."
}

function Read-GuestCpuJsonArray {
    param(
        [Parameter(Mandatory = $true)][string]$Json,
        [Parameter(Mandatory = $true)][ref]$Position,
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][int]$Depth
    )

    $Position.Value++
    Skip-GuestCpuJsonWhitespace $Json $Position
    if ($Position.Value -lt $Json.Length -and $Json[$Position.Value] -eq ']') {
        $Position.Value++
        return
    }
    while ($Position.Value -lt $Json.Length) {
        Read-GuestCpuJsonValue $Json $Position $Source ($Depth + 1)
        Skip-GuestCpuJsonWhitespace $Json $Position
        if ($Position.Value -ge $Json.Length) {
            throw "Unterminated JSON array in $Source."
        }
        if ($Json[$Position.Value] -eq ']') {
            $Position.Value++
            return
        }
        if ($Json[$Position.Value] -ne ',') {
            throw "Invalid JSON array separator in $Source."
        }
        $Position.Value++
    }
    throw "Unterminated JSON array in $Source."
}

function ConvertFrom-StrictJsonBytes {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][string]$Source
    )

    try {
        $json = [Text.UTF8Encoding]::new($false, $true).GetString($Bytes)
    }
    catch {
        throw "Malformed UTF-8 JSON in $Source."
    }
    $position = 0
    try {
        Read-GuestCpuJsonValue $json ([ref]$position) $Source 0
        Skip-GuestCpuJsonWhitespace $json ([ref]$position)
        if ($position -ne $json.Length) {
            throw "Unexpected trailing JSON content in $Source."
        }
        return $json | ConvertFrom-Json
    }
    catch {
        throw "Malformed guest CPU JSON: $($_.Exception.Message)"
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
            throw "Unexpected property '$property' in $Name."
        }
    }
    foreach ($property in $Expected) {
        if ($actual -cnotcontains $property) {
            throw "Missing property '$property' in $Name."
        }
    }
}

function Assert-JsonString {
    param(
        [AllowEmptyString()][Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$MaximumLength = 2048
    )

    if ($Value -isnot [string] -or $Value.Length -gt $MaximumLength) {
        throw "$Name must be a bounded JSON string."
    }
}

function Assert-JsonBoolean {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Value -isnot [bool]) {
        throw "$Name must be a JSON boolean."
    }
}

function Assert-UnsignedInteger {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Value) {
        throw "$Name must be a JSON integer."
    }
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

function Assert-ExactStringArray {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string[]]$Expected,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Value -isnot [Array]) {
        throw "$Name must be a JSON array."
    }
    $values = @($Value)
    if ($values.Count -ne $Expected.Count) {
        throw "$Name must be exactly: $($Expected -join ';')."
    }
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        if ($values[$index] -isnot [string] -or $values[$index] -cne $Expected[$index]) {
            throw "$Name must be exactly: $($Expected -join ';')."
        }
    }
}

function Assert-LowercaseSha256 {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Value -isnot [string] -or $Value -cnotmatch '^[0-9a-f]{64}$') {
        throw "$Name must be a lowercase SHA-256."
    }
}

function Assert-FilePin {
    param(
        [Parameter(Mandatory = $true)][object]$Pin,
        [Parameter(Mandatory = $true)][string]$Name
    )

    Assert-ExactProperties $Pin @('relative_path', 'sha256') $Name
    Assert-SafeRelativePath $Pin.relative_path "$Name.relative_path"
    Assert-LowercaseSha256 $Pin.sha256 "$Name.sha256"
}

function Read-PinnedFile {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][object]$Pin,
        [Parameter(Mandatory = $true)][UInt64]$MaximumBytes,
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$RequirePinnedBytes
    )

    $path = Get-ContainedExistingFile $Root $Pin.relative_path $Name
    [byte[]]$bytes = Read-BoundedFile $path $MaximumBytes $Name
    if ($RequirePinnedBytes -and [UInt64]$bytes.Length -ne [UInt64]$Pin.bytes) {
        throw "$Name byte count mismatch."
    }
    $hash = Get-Sha256Hex $bytes
    if ($hash -cne $Pin.sha256) {
        throw "$Name SHA-256 mismatch."
    }
    return [pscustomobject]@{
        Path = $path
        Bytes = $bytes
        Sha256 = $hash
    }
}

function Assert-ToolchainLock {
    param(
        [Parameter(Mandatory = $true)][string]$ProfileRoot,
        [Parameter(Mandatory = $true)][object]$Pin,
        [Parameter(Mandatory = $true)][string]$Name
    )

    Assert-FilePin $Pin $Name
    if ($Pin.relative_path -cnotmatch '\.json$') {
        throw "$Name must identify a JSON lock."
    }
    [void](Read-PinnedFile $ProfileRoot $Pin $script:MaximumProfileBytes $Name)
}

function Assert-SchemaDefinition {
    param(
        [Parameter(Mandatory = $true)][string]$ProfileRoot,
        [Parameter(Mandatory = $true)][object]$Pin
    )

    Assert-FilePin $Pin 'schema_definition'
    if ($Pin.relative_path -cne 'guest-cpu-profile.schema.json' -or
        $Pin.sha256 -cne '2551f1c9785e614ac6090adf45f57ecc7869c1f0c5465982f0df4764b0901cfe') {
        throw 'The guest CPU schema definition pin is immutable.'
    }
    $schemaFile = Read-PinnedFile $ProfileRoot $Pin $script:MaximumProfileBytes `
        'guest CPU schema definition'
    $schema = ConvertFrom-StrictJsonBytes $schemaFile.Bytes $schemaFile.Path
    Assert-JsonString $schema._spdx 'guest CPU schema definition._spdx'
    Assert-JsonString $schema.'$schema' 'guest CPU schema definition.$schema'
    Assert-JsonString $schema.'$id' 'guest CPU schema definition.$id'
    Assert-JsonString $schema.type 'guest CPU schema definition.type'
    Assert-JsonBoolean $schema.additionalProperties `
        'guest CPU schema definition.additionalProperties'
    [UInt64]$schemaVersion = Assert-UnsignedInteger $schema.properties.schema.const `
        'guest CPU schema definition profile schema'
    if ($schema._spdx -cne 'GPL-3.0-only' -or
        $schema.'$schema' -cne 'https://json-schema.org/draft/2020-12/schema' -or
        $schema.'$id' -cne 'guest-cpu-profile.schema.json' -or
        $schema.type -cne 'object' -or
        $schema.additionalProperties -or
        $schemaVersion -ne 1 -or
        $schema.properties.profile_id.const -cne 'gsw-886-win98-i686-v1') {
        throw 'The guest CPU schema definition identity is invalid.'
    }
}

function Assert-MingwPolicy {
    param(
        [Parameter(Mandatory = $true)][object]$Policy,
        [Parameter(Mandatory = $true)][string]$ProfileRoot
    )

    Assert-ExactProperties $Policy @(
        'toolchain_id', 'toolchain_lock', 'compiler', 'objdump',
        'target', 'architecture', 'required_features', 'disabled_features',
        'cpu_flags'
    ) 'toolchains.mingw'
    foreach ($property in @('toolchain_id', 'target', 'architecture')) {
        Assert-JsonString $Policy.$property "toolchains.mingw.$property"
    }
    if ($Policy.toolchain_id -cne 'msys2-mingw32-gcc-15.2.0-rev13' -or
        $Policy.target -cne 'i686-w64-mingw32' -or
        $Policy.architecture -cne 'i686') {
        throw 'The MinGW toolchain identity and i686 target are immutable.'
    }
    Assert-FilePin $Policy.toolchain_lock 'toolchains.mingw.toolchain_lock'
    if ($Policy.toolchain_lock.relative_path -cne 'mingw32-toolchain.lock.json' -or
        $Policy.toolchain_lock.sha256 -cne `
            'db3a84b7388937a5ffd5ab3e30429bae4c3ca5d8d17f095a491a42bc82413a12') {
        throw 'The pinned MinGW toolchain lock identity is immutable.'
    }
    Assert-ToolchainLock $ProfileRoot $Policy.toolchain_lock 'toolchains.mingw.toolchain_lock'
    Assert-FilePin $Policy.compiler 'toolchains.mingw.compiler'
    if ($Policy.compiler.relative_path -cne 'bin/gcc.exe' -or
        $Policy.compiler.sha256 -cne '0c79d47814364067e560ba4d26849126388a44fc5765d33df00c1fdd582c89a9') {
        throw 'The pinned MinGW compiler identity is immutable.'
    }
    Assert-FilePin $Policy.objdump 'toolchains.mingw.objdump'
    if ($Policy.objdump.relative_path -cne 'bin/objdump.exe' -or
        $Policy.objdump.sha256 -cne '3a3309d8a8f8898193d5e41e73085d8c8702a1efe296c6236a48f925fc5411f5') {
        throw 'The pinned MinGW objdump identity is immutable.'
    }
    Assert-ExactStringArray $Policy.required_features `
        $script:MingwRequiredFeatures 'toolchains.mingw.required_features'
    Assert-ExactStringArray $Policy.disabled_features `
        $script:MingwDisabledFeatures 'toolchains.mingw.disabled_features'
    Assert-ExactStringArray $Policy.cpu_flags $script:MingwCpuFlags 'toolchains.mingw.cpu_flags'
}

function Assert-WatcomPolicy {
    param(
        [Parameter(Mandatory = $true)][object]$Policy,
        [Parameter(Mandatory = $true)][string]$ProfileRoot
    )

    Assert-ExactProperties $Policy @(
        'toolchain_id', 'toolchain_lock', 'processor_switch', 'architecture',
        'floating_point', 'cpu_flags'
    ) 'toolchains.open_watcom'
    foreach ($property in @('toolchain_id', 'processor_switch', 'architecture', 'floating_point')) {
        Assert-JsonString $Policy.$property "toolchains.open_watcom.$property"
    }
    if ($Policy.toolchain_id -cne 'open-watcom-c-win32-1.9' -or
        $Policy.processor_switch -cne '-6' -or
        $Policy.architecture -cne 'i686' -or
        $Policy.floating_point -cne 'x87') {
        throw 'Open Watcom must remain the declared -6 i686 and x87 subset.'
    }
    Assert-FilePin $Policy.toolchain_lock 'toolchains.open_watcom.toolchain_lock'
    if ($Policy.toolchain_lock.relative_path -cne 'toolchain.lock.json' -or
        $Policy.toolchain_lock.sha256 -cne `
            'e97012fb9d9b1257e59ac5ea46ac8aa1b54b62e2feb03fed70545c5769e07dff') {
        throw 'The pinned Open Watcom toolchain lock identity is immutable.'
    }
    Assert-ToolchainLock $ProfileRoot $Policy.toolchain_lock `
        'toolchains.open_watcom.toolchain_lock'
    Assert-ExactStringArray $Policy.cpu_flags $script:WatcomCpuFlags `
        'toolchains.open_watcom.cpu_flags'
}

$profilePath = Get-FullPath $ProfileFile
if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
    throw "Guest CPU profile not found: $profilePath"
}
Assert-NoReparseAncestor $profilePath 'guest CPU profile'
$profileItem = Get-Item -LiteralPath $profilePath -Force
if (($profileItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'The guest CPU profile cannot be a reparse point.'
}
[byte[]]$profileBytes = Read-BoundedFile $profilePath $script:MaximumProfileBytes `
    'guest CPU profile'
$profile = ConvertFrom-StrictJsonBytes $profileBytes $profilePath
$profileRoot = Split-Path -Parent $profilePath

Assert-ExactProperties $profile @(
    '_spdx', 'schema', 'schema_definition', 'profile_id', 'cpu_persona',
    'cpuid', 'toolchains', 'proof'
) 'guest CPU profile'
Assert-JsonString $profile._spdx 'guest CPU profile._spdx'
Assert-JsonString $profile.profile_id 'guest CPU profile.profile_id'
[UInt64]$profileSchema = Assert-UnsignedInteger $profile.schema 'guest CPU profile.schema'
if ($profile._spdx -cne 'GPL-3.0-only' -or $profileSchema -ne 1 -or
    $profile.profile_id -cne 'gsw-886-win98-i686-v1') {
    throw 'Unsupported guest CPU profile identity.'
}
Assert-SchemaDefinition $profileRoot $profile.schema_definition

Assert-ExactProperties $profile.cpu_persona @('name', 'architecture') 'cpu_persona'
Assert-JsonString $profile.cpu_persona.name 'cpu_persona.name'
Assert-JsonString $profile.cpu_persona.architecture 'cpu_persona.architecture'
if ($profile.cpu_persona.name -cne 'GSW-886' -or
    $profile.cpu_persona.architecture -cne 'i686') {
    throw 'The GSW-886 i686 guest CPU persona is immutable.'
}

Assert-ExactProperties $profile.cpuid @('policy', 'changes_allowed') 'cpuid'
Assert-JsonString $profile.cpuid.policy 'cpuid.policy'
Assert-JsonBoolean $profile.cpuid.changes_allowed 'cpuid.changes_allowed'
if ($profile.cpuid.policy -cne 'unchanged' -or $profile.cpuid.changes_allowed) {
    throw 'Guest CPU policy cannot alter CPUID.'
}

Assert-ExactProperties $profile.toolchains @('mingw', 'open_watcom') 'toolchains'
Assert-MingwPolicy $profile.toolchains.mingw $profileRoot
Assert-WatcomPolicy $profile.toolchains.open_watcom $profileRoot

Assert-ExactProperties $profile.proof @(
    'status', 'evidence_status', 'reason', 'compiler_feature_report', 'final_pe_outputs',
    'final_binary_objdump_evidence'
) 'proof'
Assert-JsonString $profile.proof.status 'proof.status'
Assert-JsonString $profile.proof.evidence_status 'proof.evidence_status'
Assert-JsonString $profile.proof.reason 'proof.reason' 1024
if ($profile.proof.final_pe_outputs -isnot [Array] -or
    $profile.proof.final_binary_objdump_evidence -isnot [Array]) {
    throw 'proof final PE outputs and objdump evidence must be JSON arrays.'
}

if ($profile.proof.status -cne 'blocked' -or
    [string]::IsNullOrWhiteSpace($profile.proof.reason)) {
    throw 'Guest CPU profile schema v1 is blocked-only.'
}
if ($profile.proof.evidence_status -cne 'absent') {
    throw 'Guest CPU profile schema v1 does not accept candidate evidence.'
}
if ($null -ne $profile.proof.compiler_feature_report -or
    $profile.proof.final_pe_outputs.Count -ne 0 -or
    $profile.proof.final_binary_objdump_evidence.Count -ne 0) {
    throw 'Guest CPU profile schema v1 cannot carry proof artifacts.'
}
if ($CandidateEvidenceAudit) {
    throw (
        'Guest CPU profile schema v1 has no candidate-evidence acceptance path. ' +
        'A later schema requires a hash-pinned capture publisher, a pinned empty ' +
        'translation unit, canonical compile/query arguments, deterministic locale ' +
        'and environment, a 30000 ms timeout, exit code zero, raw stdout and stderr ' +
        'byte counts and SHA-256 digests, an authoritative final build inventory, ' +
        'and complete executable-section opcode classification.'
    )
}
if (-not [string]::IsNullOrWhiteSpace($EvidenceRoot)) {
    throw 'Schema v1 does not accept an evidence root.'
}
if (-not $PolicyAudit) {
    throw "Guest CPU proof is blocked: $($profile.proof.reason)"
}
Write-Output (
    "Policy-audited blocked guest CPU profile '$($profile.profile_id)': " +
    $profile.proof.reason
)
