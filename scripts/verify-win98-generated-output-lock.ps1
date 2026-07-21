# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [string]$SourceRoot,

    [Parameter(Mandatory = $true)]
    [string]$GeneratedRoot,

    [Parameter(Mandatory = $true)]
    [string]$LockFile,

    [string]$MetadataRoot,

    [scriptblock]$BeforeFinalCheckoutCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'strict-json.ps1')
. (Join-Path $PSScriptRoot 'strict-tsv.ps1')

$script:MaximumInputs = 20000
$script:MaximumNotices = 128
$script:MaximumOutputs = 20000
$script:MaximumDirectories = 10000
$script:MaximumEntries = 30000
$script:MaximumSourceFileBytes = [UInt64]536870912
$script:MaximumAggregateSourceBytes = [UInt64]2147483648
$script:MaximumOutputFileBytes = [UInt64]67108864
$script:MaximumAggregateOutputBytes = [UInt64]536870912
$script:MaximumEvidenceRangeBytes = [UInt64]1048576
$script:MaximumPathBytes = [UInt64]512
$script:V2GitExecutable = ''
$script:AllowedLicenses = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
)
foreach ($license in @('MIT', 'LGPL-2.1-or-later')) {
    [void]$script:AllowedLicenses.Add($license)
}

if ([string]::IsNullOrWhiteSpace($MetadataRoot)) {
    $MetadataRoot = Join-Path $PSScriptRoot '..\drivers\win98'
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

    $current = Get-FullPath $Path
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "$Name traverses reparse point '$current'."
            }
        }
        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or
            $parent.Equals($current, [StringComparison]::OrdinalIgnoreCase)) {
            break
        }
        $current = $parent
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

function Get-ContainedPath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][object]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Name
    )

    Assert-SafeRelativePath $RelativePath $Name
    $rootPath = Get-FullPath $Root
    $rootPrefix = $rootPath.TrimEnd([char[]]'\/') + [IO.Path]::DirectorySeparatorChar
    $candidate = [IO.Path]::GetFullPath((Join-Path $rootPath (
        $RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)
    )))
    if (-not $candidate.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Name escapes its declared root."
    }
    return $candidate
}

function Assert-ContainedPathHasNoReparsePoint {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $current = Get-FullPath $Root
    foreach ($component in $RelativePath.Split('/')) {
        $current = Join-Path $current $component
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "$Name crosses reparse point '$current'."
            }
        }
    }
}

function Read-StrictJsonSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [UInt64]$MaximumBytes = 4194304
    )

    try {
        return Read-GswStrictJsonFileSnapshot -Path $Path -Name $Name `
            -MaximumBytes $MaximumBytes
    }
    catch {
        throw "Malformed $Name JSON: $($_.Exception.Message)"
    }
}

function Assert-ExactProperties {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string[]]$Expected,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Object -or $Object -is [string] -or $Object -is [Array] -or
        $Object.GetType().IsValueType) {
        throw "$Name must be a JSON object."
    }
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

function Assert-UnsignedInteger {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$Value,
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

function Assert-Identifier {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Value -isnot [string] -or $Value -cnotmatch '^[a-z0-9][a-z0-9-]*$') {
        throw "Invalid $Name '$Value'."
    }
}

function Assert-LowercaseHash {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][int]$Length,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Value -isnot [string] -or $Value -cnotmatch "^[0-9a-f]{$Length}`$") {
        throw "$Name must be a lowercase $Length-character hexadecimal digest."
    }
}

function Convert-ToWin9xShortCharacter {
    param([Parameter(Mandatory = $true)][char]$Character)

    $upper = [char]::ToUpperInvariant($Character)
    if (($upper -ge 'A' -and $upper -le 'Z') -or
        ($upper -ge '0' -and $upper -le '9') -or
        "!#$%&'()-@^_``{}~".IndexOf($upper) -ge 0) {
        return [string]$upper
    }
    return '_'
}

function Get-Win9xDirectAlias {
    param([Parameter(Mandatory = $true)][string]$Name)

    $dot = $Name.LastIndexOf('.')
    $base = $Name
    $extension = ''
    if ($dot -ge 0) {
        $base = $Name.Substring(0, $dot)
        $extension = $Name.Substring($dot + 1)
    }
    $direct = $base.Length -gt 0 -and $base.Length -le 8 -and
        $extension.Length -le 3 -and -not $base.Contains('.')
    if (-not $direct) { return $null }
    $shortBase = ''
    foreach ($character in $base.ToCharArray()) {
        $converted = Convert-ToWin9xShortCharacter $character
        if ($converted -eq '_' -and $character -ne '_') {
            return $null
        }
        $shortBase += $converted
    }
    $shortExtension = ''
    foreach ($character in $extension.ToCharArray()) {
        $converted = Convert-ToWin9xShortCharacter $character
        if ($converted -eq '_' -and $character -ne '_') {
            return $null
        }
        $shortExtension += $converted
    }
    return $shortBase.PadRight(8, ' ') + $shortExtension.PadRight(3, ' ')
}

function Get-Win9xShortAlias {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()]
        [Collections.Generic.HashSet[string]]$UsedAliases
    )

    $direct = Get-Win9xDirectAlias $Name
    if ($null -ne $direct) {
        if (-not $UsedAliases.Add($direct)) {
            throw "Direct Windows 9x short-name collision for '$Name'."
        }
        return $direct
    }
    $dot = $Name.LastIndexOf('.')
    $base = $Name
    $extension = ''
    if ($dot -ge 0) {
        $base = $Name.Substring(0, $dot)
        $extension = $Name.Substring($dot + 1)
    }
    $shortExtension = ''
    foreach ($character in $extension.ToCharArray()) {
        if ($shortExtension.Length -ge 3) { break }
        $shortExtension += Convert-ToWin9xShortCharacter $character
    }
    for ($ordinal = 1; $ordinal -le 999999; $ordinal++) {
        $suffix = "~$ordinal"
        $stemLimit = 8 - $suffix.Length
        if ($stemLimit -le 0) { break }
        $shortBase = ''
        foreach ($character in $base.ToCharArray()) {
            if ($shortBase.Length -ge $stemLimit) { break }
            $shortBase += Convert-ToWin9xShortCharacter $character
        }
        if ($shortBase.Length -eq 0) { $shortBase = '_' }
        $candidate = ($shortBase + $suffix).PadRight(8, ' ') +
            $shortExtension.PadRight(3, ' ')
        if ($UsedAliases.Add($candidate)) {
            return $candidate
        }
    }
    throw "Windows 9x short-name space is exhausted for '$Name'."
}

function Assert-PortablePathSet {
    param(
        [Parameter(Mandatory = $true)][object[]]$Rows,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $ordinal = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $folded = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $childrenByParent =
        [Collections.Generic.Dictionary[string,object]]::new(
            [StringComparer]::Ordinal
        )
    $foldedChildrenByParent =
        [Collections.Generic.Dictionary[string,object]]::new(
            [StringComparer]::Ordinal
        )
    foreach ($row in $Rows) {
        Assert-SafeRelativePath $row.relative_path $Name
        $path = [string]$row.relative_path
        if (-not $ordinal.Add($path)) {
            throw "Duplicate path '$path' in $Name."
        }
        if (-not $folded.Add($path)) {
            throw "Case-folded path collision for '$path' in $Name."
        }
        $parent = ''
        foreach ($component in $path.Split('/')) {
            if (-not $childrenByParent.ContainsKey($parent)) {
                $childrenByParent.Add(
                    $parent,
                    [Collections.Generic.HashSet[string]]::new(
                        [StringComparer]::Ordinal
                    )
                )
                $foldedChildrenByParent.Add(
                    $parent,
                    [Collections.Generic.HashSet[string]]::new(
                        [StringComparer]::OrdinalIgnoreCase
                    )
                )
            }
            $newOrdinalChild = $childrenByParent[$parent].Add($component)
            $newFoldedChild = $foldedChildrenByParent[$parent].Add($component)
            if ($newOrdinalChild -and -not $newFoldedChild) {
                throw "Case-folded component collision for '$path' in $Name."
            }
            $parent = if ($parent.Length -eq 0) {
                $component.ToLowerInvariant()
            }
            else { "$parent/$($component.ToLowerInvariant())" }
        }
    }
    $componentAliases =
        [Collections.Generic.Dictionary[string,string]]::new(
            [StringComparer]::Ordinal
        )
    foreach ($parent in $childrenByParent.Keys) {
        [string[]]$children = @($childrenByParent[$parent])
        [Array]::Sort($children, [StringComparer]::Ordinal)
        $used = [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase
        )
        foreach ($child in @($children | Where-Object {
            $null -ne (Get-Win9xDirectAlias $_)
        })) {
            $key = if ($parent.Length -eq 0) {
                $child.ToLowerInvariant()
            }
            else { "$parent/$($child.ToLowerInvariant())" }
            $componentAliases.Add($key, (Get-Win9xShortAlias $child $used))
        }
        foreach ($child in @($children | Where-Object {
            $null -eq (Get-Win9xDirectAlias $_)
        })) {
            $key = if ($parent.Length -eq 0) {
                $child.ToLowerInvariant()
            }
            else { "$parent/$($child.ToLowerInvariant())" }
            $componentAliases.Add($key, (Get-Win9xShortAlias $child $used))
        }
    }
    $aliasPaths = [Collections.Generic.Dictionary[string,string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($path in $ordinal) {
        $longPrefix = ''
        $aliasParts = @()
        foreach ($component in $path.Split('/')) {
            $longPrefix = if ($longPrefix.Length -eq 0) {
                $component.ToLowerInvariant()
            }
            else { "$longPrefix/$($component.ToLowerInvariant())" }
            $aliasParts += $componentAliases[$longPrefix]
            $aliasPrefix = $aliasParts -join '/'
            if ($aliasPaths.ContainsKey($aliasPrefix) -and
                $aliasPaths[$aliasPrefix] -cne $longPrefix) {
                throw "Windows 9x short-name collision for '$path' in $Name."
            }
            $aliasPaths[$aliasPrefix] = $longPrefix
        }
    }
    foreach ($path in $ordinal) {
        $components = $path.Split('/')
        for ($count = 1; $count -lt $components.Count; $count++) {
            $ancestor = [string]::Join('/', $components[0..($count - 1)])
            if ($folded.Contains($ancestor)) {
                throw "File/ancestor path collision for '$path' in $Name."
            }
        }
    }
}

function Invoke-GitLines {
    param(
        [Parameter(Mandatory = $true)][string]$Checkout,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $text = Invoke-V2BoundedGitTextCommand -Checkout $Checkout `
        -Arguments (@('-c', 'core.quotePath=false') + $Arguments) `
        -Name "git $($Arguments -join ' ')"
    if ([string]::IsNullOrWhiteSpace($text)) {
        return @()
    }
    return @($text -split '\r?\n')
}

function ConvertTo-ProcessArgument {
    param([Parameter(Mandatory = $true)][string]$Argument)

    if ($Argument.Length -gt 0 -and $Argument -notmatch '[\s"]') {
        return $Argument
    }
    $builder = [Text.StringBuilder]::new()
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

function Get-V2GitExecutable {
    if (-not [string]::IsNullOrWhiteSpace($script:V2GitExecutable)) {
        return $script:V2GitExecutable
    }
    $discovered = @(Get-Command git -CommandType Application -ErrorAction Stop)[0].Source
    $installationRoot = Split-Path -Parent (Split-Path -Parent $discovered)
    $direct = Join-Path $installationRoot 'mingw64\bin\git.exe'
    if (Test-Path -LiteralPath $direct -PathType Leaf) {
        $script:V2GitExecutable = [IO.Path]::GetFullPath($direct)
    }
    else {
        $script:V2GitExecutable = [IO.Path]::GetFullPath($discovered)
    }
    return $script:V2GitExecutable
}

function Invoke-V2BoundedGitTextCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Checkout,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $git = Get-V2GitExecutable
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $git
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $childEnvironment = $startInfo.EnvironmentVariables
    if ($null -eq $childEnvironment) {
        throw 'Parent environment contains case-colliding keys and cannot be sanitized for Git.'
    }
    foreach ($variable in @(
        'GIT_CEILING_DIRECTORIES', 'GIT_DIR', 'GIT_WORK_TREE',
        'GIT_PREFIX', 'GIT_INDEX_FILE'
    )) {
        $childEnvironment.Remove($variable)
    }
    $startInfo.Arguments = (@(
        '-c', 'maintenance.auto=false', '-c', 'gc.auto=0',
        '-c', 'core.fsmonitor=false', '-C', $Checkout
    ) + $Arguments |
        ForEach-Object { ConvertTo-ProcessArgument $_ }) -join ' '

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $started = $false
    $ownedProcessId = -1
    try {
        if (-not $process.Start()) {
            throw "Unable to start bounded Git command for $Name."
        }
        $started = $true
        $ownedProcessId = $process.Id
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) {
            $process.Kill()
            $process.WaitForExit()
            throw "Bounded Git command timed out for $Name."
        }
        $tasks = [Threading.Tasks.Task[]]@($outputTask, $errorTask)
        if (-not [Threading.Tasks.Task]::WaitAll($tasks, 30000)) {
            throw "Bounded Git output collection timed out for $Name."
        }
        $output = $outputTask.GetAwaiter().GetResult()
        $errorText = $errorTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "Bounded Git command failed for ${Name}: $errorText"
        }
        if ($output.Length -gt 4096 -or $errorText.Length -gt 4096) {
            throw "Bounded Git command exceeded its text-output bound for $Name."
        }
        return $output.Trim()
    }
    finally {
        if ($started -and -not $process.HasExited) {
            $process.Kill()
            $process.WaitForExit()
        }
        if ($started -and -not $process.HasExited) {
            throw "Owned Git process $ownedProcessId did not exit after $Name."
        }
        $process.Dispose()
    }
}

function Read-V2GitBlobSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$Checkout,
        [Parameter(Mandatory = $true)][string]$Blob,
        [Parameter(Mandatory = $true)][UInt64]$ExpectedBytes,
        [Parameter(Mandatory = $true)][string]$Name
    )

    Assert-LowercaseHash $Blob 40 "$Name git_blob"
    if ($ExpectedBytes -gt $script:MaximumSourceFileBytes -or
        $ExpectedBytes -gt [int]::MaxValue) {
        throw "$Name exceeds the canonical Git-blob size bound."
    }
    $git = Get-V2GitExecutable
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $git
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $childEnvironment = $startInfo.EnvironmentVariables
    if ($null -eq $childEnvironment) {
        throw 'Parent environment contains case-colliding keys and cannot be sanitized for Git.'
    }
    foreach ($variable in @(
        'GIT_CEILING_DIRECTORIES', 'GIT_DIR', 'GIT_WORK_TREE',
        'GIT_PREFIX', 'GIT_INDEX_FILE'
    )) {
        $childEnvironment.Remove($variable)
    }
    $startInfo.Arguments = (@(
        '-c', 'maintenance.auto=false', '-c', 'gc.auto=0',
        '-c', 'core.fsmonitor=false', '-C', $Checkout,
        'cat-file', 'blob', $Blob
    ) |
        ForEach-Object { ConvertTo-ProcessArgument $_ }) -join ' '

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $memory = [IO.MemoryStream]::new([int]$ExpectedBytes)
    $started = $false
    $ownedProcessId = -1
    try {
        if (-not $process.Start()) {
            throw "Unable to read canonical Git blob for $Name."
        }
        $started = $true
        $ownedProcessId = $process.Id
        $outputTask = $process.StandardOutput.BaseStream.CopyToAsync($memory)
        $errorTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) {
            $process.Kill()
            $process.WaitForExit()
            throw "Canonical Git-blob read timed out for $Name."
        }
        $tasks = [Threading.Tasks.Task[]]@($outputTask, $errorTask)
        if (-not [Threading.Tasks.Task]::WaitAll($tasks, 30000)) {
            throw "Canonical Git-blob output collection timed out for $Name."
        }
        $errorText = $errorTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "Canonical Git-blob read failed for ${Name}: $errorText"
        }
        if ($errorText.Length -gt 4096) {
            throw "Canonical Git-blob read exceeded its error-output bound for $Name."
        }
        $bytes = $memory.ToArray()
        if ([UInt64]$bytes.Length -ne $ExpectedBytes) {
            throw "$Name canonical Git-blob length changed during its read."
        }
        return [pscustomobject]@{
            Bytes = [byte[]]$bytes
            Length = [UInt64]$bytes.Length
            Sha256 = Get-GswSha256Hex $bytes
        }
    }
    finally {
        if ($started -and -not $process.HasExited) {
            $process.Kill()
            $process.WaitForExit()
        }
        if ($started -and -not $process.HasExited) {
            throw "Owned Git process $ownedProcessId did not exit after $Name."
        }
        $memory.Dispose()
        $process.Dispose()
    }
}

function Get-GitBlobDigest {
    param(
        [Parameter(Mandatory = $true)][string]$Checkout,
        [Parameter(Mandatory = $true)][string]$Blob,
        [Parameter(Mandatory = $true)][UInt64]$ExpectedBytes
    )

    $snapshot = Read-V2GitBlobSnapshot -Checkout $Checkout -Blob $Blob `
        -ExpectedBytes $ExpectedBytes -Name "legacy source blob '$Blob'"
    return [pscustomobject]@{
        Bytes = $snapshot.Length
        Sha256 = $snapshot.Sha256
    }
}

function Get-FileDescriptor {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][UInt64]$MaximumBytes
    )

    $item = Get-Item -LiteralPath $Path -Force
    if ($item -isnot [IO.FileInfo] -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        ($item.Attributes -band [IO.FileAttributes]::Device) -ne 0) {
        throw "Generated output is not a regular file: $Path"
    }
    $stream = [IO.File]::Open(
        $item.FullName,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read
    )
    try {
        [UInt64]$length = $stream.Length
        if ($length -gt $MaximumBytes) {
            throw "File exceeds its size bound: $Path"
        }
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $hash = $sha.ComputeHash($stream)
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
        Hash = [byte[]]$hash
        Sha256 = ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
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
    return ,$bytes
}

function Add-DigestBlock {
    param(
        [Parameter(Mandatory = $true)]
        [Security.Cryptography.HashAlgorithm]$Digest,
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes
    )

    [void]$Digest.TransformBlock($Bytes, 0, $Bytes.Length, $Bytes, 0)
}

function Get-PortableChildPath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $rootPath = Get-FullPath $Root
    $prefix = $rootPath.TrimEnd([char[]]'\/') + [IO.Path]::DirectorySeparatorChar
    $fullPath = Get-FullPath $Path
    if (-not $fullPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Generated entry escapes its root: $fullPath"
    }
    return $fullPath.Substring($prefix.Length).Replace(
        [IO.Path]::DirectorySeparatorChar,
        '/'
    )
}

function Get-GeneratedTreeDescriptor {
    param([Parameter(Mandatory = $true)][string]$Root)

    $rootPath = Get-FullPath $Root
    if (-not (Test-Path -LiteralPath $rootPath -PathType Container)) {
        throw "Generated root not found: $rootPath"
    }
    Assert-NoReparseAncestor $rootPath 'Generated root'
    $records = [Collections.Generic.Dictionary[string,object]]::new(
        [StringComparer]::Ordinal
    )
    $directories = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($rootPath)
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    [UInt64]$totalEntries = 0
    [UInt64]$aggregateBytes = 0
    [UInt64]$maximumFileBytes = 0
    [UInt64]$maximumPathBytes = 0

    while ($pending.Count -ne 0) {
        $directory = $pending.Pop()
        foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($directory)) {
            $totalEntries++
            if ($totalEntries -gt $script:MaximumEntries) {
                throw 'Generated tree exceeds the entry-count bound.'
            }
            $relativePath = Get-PortableChildPath $rootPath $entry
            Assert-SafeRelativePath $relativePath 'generated tree'
            [UInt64]$relativePathByteCount = $utf8.GetByteCount($relativePath)
            if ($relativePathByteCount -gt $maximumPathBytes) {
                $maximumPathBytes = $relativePathByteCount
            }
            $attributes = [IO.File]::GetAttributes($entry)
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Reparse points are not allowed in the generated tree: $relativePath"
            }
            if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) {
                if ($directories.Count -ge $script:MaximumDirectories) {
                    throw 'Generated tree exceeds the directory-count bound.'
                }
                if (-not $directories.Add($relativePath)) {
                    throw "Duplicate generated directory '$relativePath'."
                }
                $pending.Push($entry)
                continue
            }
            if (($attributes -band [IO.FileAttributes]::Device) -ne 0) {
                throw "Non-regular generated entry is not supported: $relativePath"
            }
            if ($records.Count -ge $script:MaximumOutputs) {
                throw 'Generated tree exceeds the file-count bound.'
            }
            if ($records.ContainsKey($relativePath)) {
                throw "Duplicate generated output '$relativePath'."
            }
            $descriptor = Get-FileDescriptor $entry $script:MaximumOutputFileBytes
            if ([UInt64]::MaxValue - $aggregateBytes -lt $descriptor.Bytes -or
                $aggregateBytes + $descriptor.Bytes -gt $script:MaximumAggregateOutputBytes) {
                throw 'Generated tree exceeds the aggregate-byte bound.'
            }
            $aggregateBytes += $descriptor.Bytes
            if ($descriptor.Bytes -gt $maximumFileBytes) {
                $maximumFileBytes = $descriptor.Bytes
            }
            $records.Add($relativePath, $descriptor)
        }
    }

    [string[]]$paths = @($records.Keys)
    [Array]::Sort($paths, [StringComparer]::Ordinal)
    $digest = [Security.Cryptography.SHA256]::Create()
    try {
        $header = $utf8.GetBytes("RETVRN99-WIN98-TREE-SHA256-V1`0")
        Add-DigestBlock $digest $header
        Add-DigestBlock $digest (
            Get-BigEndianBytes -Value ([UInt64]$paths.Count) -Width 8
        )
        Add-DigestBlock $digest (
            Get-BigEndianBytes -Value $aggregateBytes -Width 8
        )
        foreach ($relativePath in $paths) {
            $encodedPath = $utf8.GetBytes($relativePath)
            $record = $records[$relativePath]
            Add-DigestBlock $digest (
                Get-BigEndianBytes -Value ([UInt64]$encodedPath.Length) -Width 4
            )
            Add-DigestBlock $digest $encodedPath
            Add-DigestBlock $digest (
                Get-BigEndianBytes -Value ([UInt64]$record.Bytes) -Width 8
            )
            Add-DigestBlock $digest ([byte[]]$record.Hash)
        }
        [void]$digest.TransformFinalBlock((New-Object byte[] 0), 0, 0)
        $treeHash = ([BitConverter]::ToString($digest.Hash) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $digest.Dispose()
    }
    return [pscustomobject]@{
        FileCount = [UInt64]$records.Count
        DirectoryCount = [UInt64]$directories.Count
        TotalEntries = $totalEntries
        AggregateBytes = $aggregateBytes
        MaximumFileBytes = $maximumFileBytes
        MaximumPathBytes = $maximumPathBytes
        Sha256 = $treeHash
        Records = $records
        Directories = $directories
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

function Assert-ClosureFileRow {
    param(
        [Parameter(Mandatory = $true)][object]$Row,
        [Parameter(Mandatory = $true)][string]$Name
    )

    Assert-ExactProperties $Row @(
        'relative_path', 'git_blob', 'bytes', 'sha256', 'license_expression',
        'notice_id', 'source_prefix_id', 'role'
    ) $Name
    Assert-SafeRelativePath $Row.relative_path $Name
    Assert-LowercaseHash $Row.git_blob 40 "$Name git_blob"
    Assert-LowercaseHash $Row.sha256 64 "$Name sha256"
    $bytes = Assert-UnsignedInteger $Row.bytes "$Name bytes"
    if ($bytes -gt $script:MaximumSourceFileBytes -or
        $Row.license_expression -isnot [string] -or
        -not $script:AllowedLicenses.Contains($Row.license_expression)) {
        throw "Invalid source metadata in $Name."
    }
    Assert-Identifier $Row.notice_id "$Name notice_id"
    Assert-Identifier $Row.source_prefix_id "$Name source_prefix_id"
    Assert-Identifier $Row.role "$Name role"
}

function Assert-NoticeRow {
    param(
        [Parameter(Mandatory = $true)][object]$Row,
        [Parameter(Mandatory = $true)][string]$Name
    )

    Assert-ExactProperties $Row @(
        'id', 'relative_path', 'git_blob', 'bytes', 'sha256', 'license_expression'
    ) $Name
    Assert-Identifier $Row.id "$Name id"
    Assert-SafeRelativePath $Row.relative_path $Name
    Assert-LowercaseHash $Row.git_blob 40 "$Name git_blob"
    Assert-LowercaseHash $Row.sha256 64 "$Name sha256"
    $bytes = Assert-UnsignedInteger $Row.bytes "$Name bytes"
    if ($bytes -gt $script:MaximumSourceFileBytes -or
        $Row.relative_path -cnotmatch '(?i)(^|/)(COPYING|LICENSE|NOTICE|COPYRIGHT)(\..*)?$' -or
        $Row.license_expression -isnot [string] -or
        -not $script:AllowedLicenses.Contains($Row.license_expression)) {
        throw "Invalid notice metadata in $Name."
    }
}

function Test-RowsEqual {
    param(
        [Parameter(Mandatory = $true)][object]$First,
        [Parameter(Mandatory = $true)][object]$Second,
        [Parameter(Mandatory = $true)][string[]]$Properties
    )

    foreach ($property in $Properties) {
        if ($First.$property -cne $Second.$property) {
            return $false
        }
    }
    return $true
}

function Assert-FalseBoolean {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Value -isnot [bool] -or $Value) {
        throw "$Name must remain false."
    }
}

function Assert-V2FileDescriptor {
    param(
        [Parameter(Mandatory = $true)][object]$Descriptor,
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$GitBlob
    )

    $properties = @('relative_path', 'bytes', 'sha256')
    if ($GitBlob) { $properties = @('relative_path', 'git_blob', 'bytes', 'sha256') }
    Assert-ExactProperties $Descriptor $properties $Name
    Assert-SafeRelativePath $Descriptor.relative_path $Name
    if ($GitBlob) { Assert-LowercaseHash $Descriptor.git_blob 40 "$Name git_blob" }
    [void](Assert-UnsignedInteger $Descriptor.bytes "$Name bytes")
    Assert-LowercaseHash $Descriptor.sha256 64 "$Name sha256"
}

function Test-V2FileDescriptorIdentity {
    param(
        [Parameter(Mandatory = $true)][object]$First,
        [Parameter(Mandatory = $true)][object]$Second,
        [switch]$GitBlob
    )

    if ($First.relative_path -cne $Second.relative_path -or
        [UInt64]$First.bytes -ne [UInt64]$Second.bytes -or
        $First.sha256 -cne $Second.sha256) {
        return $false
    }
    return -not $GitBlob -or $First.git_blob -ceq $Second.git_blob
}

function Assert-V2EvidenceLocator {
    param(
        [Parameter(Mandatory = $true)][object]$Locator,
        [Parameter(Mandatory = $true)][object]$Snapshot,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Locator -or $Locator.kind -isnot [string]) {
        throw "$Name has an invalid locator."
    }
    if ($Locator.kind -ceq 'whole-file') {
        Assert-ExactProperties $Locator @('kind', 'sha256') "$Name locator"
        Assert-LowercaseHash $Locator.sha256 64 "$Name locator sha256"
        if ($Locator.sha256 -cne $Snapshot.Sha256) {
            throw "$Name whole-file locator hash mismatch."
        }
        return
    }
    if ($Locator.kind -cne 'byte-range') {
        throw "$Name has an unsupported locator kind."
    }
    Assert-ExactProperties $Locator @(
        'kind', 'byte_offset', 'byte_count', 'sha256'
    ) "$Name locator"
    $offset = Assert-UnsignedInteger $Locator.byte_offset "$Name byte offset"
    $count = Assert-UnsignedInteger $Locator.byte_count "$Name byte count"
    Assert-LowercaseHash $Locator.sha256 64 "$Name locator sha256"
    if ($count -eq 0 -or $count -gt $script:MaximumEvidenceRangeBytes -or
        $offset -gt $Snapshot.Length -or $offset + $count -lt $offset -or
        $offset + $count -gt $Snapshot.Length -or
        $offset -gt [int]::MaxValue -or $count -gt [int]::MaxValue) {
        throw "$Name has an invalid byte-range locator."
    }
    $digest = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $digest.ComputeHash(
            [byte[]]$Snapshot.Bytes,
            [int]$offset,
            [int]$count
        )
    }
    finally {
        $digest.Dispose()
    }
    $rangeSha256 = ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
    if ($rangeSha256 -cne $Locator.sha256) {
        throw "$Name byte-range locator hash mismatch."
    }
}

function Get-V2ComponentClosureIndex {
    param(
        [Parameter(Mandatory = $true)][object]$Manifest,
        [Parameter(Mandatory = $true)][object]$Lock
    )

    Assert-ExactProperties $Manifest @(
        '_spdx', 'schema', 'status', 'reason', 'upstream_name', 'owning_commit',
        'source_prefixes', 'license_evidence', 'files'
    ) 'bound component closure'
    if ($Manifest._spdx -cne 'GPL-3.0-only' -or
        (Assert-UnsignedInteger $Manifest.schema 'component closure schema') -ne 2 -or
        $Manifest.status -cne 'blocked' -or
        [string]::IsNullOrWhiteSpace([string]$Manifest.reason) -or
        $Manifest.upstream_name -cne $Lock.component.upstream_name -or
        $Manifest.owning_commit -cne $Lock.component.owning_commit -or
        $Manifest.source_prefixes -isnot [Array] -or
        $Manifest.license_evidence -isnot [Array] -or
        $Manifest.files -isnot [Array] -or
        $Manifest.license_evidence.Count -gt 4096 -or
        $Manifest.files.Count -gt 20000) {
        throw 'Bound component closure identity or bounds mismatch.'
    }

    $prefixes = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )
    foreach ($prefix in @($Manifest.source_prefixes)) {
        Assert-ExactProperties $prefix @('id', 'relative_path', 'mode') `
            'bound component closure source prefix'
        Assert-Identifier $prefix.id 'component closure source prefix id'
        if (-not $prefixes.Add($prefix.id) -or
            @('subtree', 'exact-root-files') -cnotcontains $prefix.mode) {
            throw 'Bound component closure has an invalid source prefix.'
        }
        if ($prefix.mode -ceq 'exact-root-files') {
            if ($prefix.relative_path -cne '.') {
                throw 'Bound component closure has an invalid root-file prefix.'
            }
        }
        else {
            Assert-SafeRelativePath $prefix.relative_path `
                'component closure source prefix path'
        }
    }

    $evidenceById = [Collections.Generic.Dictionary[string,object]]::new(
        [StringComparer]::Ordinal
    )
    foreach ($evidence in @($Manifest.license_evidence)) {
        Assert-ExactProperties $evidence @(
            'id', 'kind', 'relative_path', 'git_blob', 'bytes', 'sha256',
            'source_prefix_id', 'locator', 'observed_license_expression'
        ) 'bound component closure license evidence'
        Assert-Identifier $evidence.id 'component closure license evidence id'
        Assert-SafeRelativePath $evidence.relative_path `
            'component closure evidence descriptor'
        Assert-LowercaseHash $evidence.git_blob 40 `
            'component closure evidence descriptor git_blob'
        [void](Assert-UnsignedInteger $evidence.bytes `
            'component closure evidence descriptor bytes')
        Assert-LowercaseHash $evidence.sha256 64 `
            'component closure evidence descriptor sha256'
        if ($evidenceById.ContainsKey($evidence.id) -or
            @('license-document', 'inline') -cnotcontains $evidence.kind -or
            -not $prefixes.Contains($evidence.source_prefix_id) -or
            $evidence.observed_license_expression -isnot [string] -or
            [string]::IsNullOrWhiteSpace($evidence.observed_license_expression)) {
            throw 'Bound component closure has invalid license evidence.'
        }
        if ($evidence.locator.kind -ceq 'whole-file') {
            Assert-ExactProperties $evidence.locator @('kind') `
                'component closure whole-file locator'
        }
        elseif ($evidence.locator.kind -ceq 'byte-range') {
            Assert-ExactProperties $evidence.locator @(
                'kind', 'byte_offset', 'byte_count', 'sha256'
            ) 'component closure byte-range locator'
            $offset = Assert-UnsignedInteger $evidence.locator.byte_offset `
                'component closure byte offset'
            $count = Assert-UnsignedInteger $evidence.locator.byte_count `
                'component closure byte count'
            Assert-LowercaseHash $evidence.locator.sha256 64 `
                'component closure locator sha256'
            if ($count -eq 0 -or $count -gt $script:MaximumEvidenceRangeBytes -or
                $offset + $count -lt $offset -or
                $offset + $count -gt [UInt64]$evidence.bytes) {
                throw 'Bound component closure has an invalid byte-range locator.'
            }
        }
        else {
            throw 'Bound component closure has an unsupported evidence locator.'
        }
        $evidenceById.Add($evidence.id, $evidence)
    }

    $filesByPath = [Collections.Generic.Dictionary[string,object]]::new(
        [StringComparer]::Ordinal
    )
    foreach ($file in @($Manifest.files)) {
        Assert-ExactProperties $file @(
            'relative_path', 'git_blob', 'bytes', 'sha256',
            'declared_license_expression', 'selected_license_expression',
            'license_evidence_ids', 'source_prefix_id', 'roles'
        ) 'bound component closure file'
        Assert-SafeRelativePath $file.relative_path `
            'component closure file descriptor'
        Assert-LowercaseHash $file.git_blob 40 `
            'component closure file descriptor git_blob'
        [void](Assert-UnsignedInteger $file.bytes `
            'component closure file descriptor bytes')
        Assert-LowercaseHash $file.sha256 64 `
            'component closure file descriptor sha256'
        if ($filesByPath.ContainsKey($file.relative_path) -or
            $file.license_evidence_ids -isnot [Array] -or
            $file.roles -isnot [Array] -or
            -not $prefixes.Contains($file.source_prefix_id)) {
            throw 'Bound component closure has an invalid file row.'
        }
        foreach ($id in @($file.license_evidence_ids)) {
            Assert-Identifier $id 'component closure file evidence id'
            if (-not $evidenceById.ContainsKey($id)) {
                throw 'Bound component closure file names unknown evidence.'
            }
        }
        foreach ($role in @($file.roles)) {
            if ($role -isnot [string] -or [string]::IsNullOrWhiteSpace($role)) {
                throw 'Bound component closure file has an invalid role.'
            }
        }
        $filesByPath.Add($file.relative_path, $file)
    }
    return [pscustomobject]@{
        EvidenceById = $evidenceById
        FilesByPath = $filesByPath
    }
}

function Get-MesaV2ExpectedLicenseExpression {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    switch -CaseSensitive ($RelativePath) {
        'mesa-23.1.x/src/compiler/glsl/glsl_parser.cpp' {
            return 'MIT AND (GPL-3.0-or-later WITH Bison-exception-2.2)'
        }
        'mesa-23.1.x/src/compiler/glsl/glcpp/glcpp-parse.c' {
            return 'MIT AND (GPL-3.0-or-later WITH Bison-exception-2.2)'
        }
        'mesa-23.1.x/src/mesa/program/program_parse.tab.c' {
            return 'MIT AND (GPL-3.0-or-later WITH Bison-exception-2.2)'
        }
        'mesa-23.1.x/src/compiler/glsl/float64_glsl.h' {
            return 'MIT AND BSD-3-Clause'
        }
        'mesa-23.1.x/src/mapi/glapi/enums.c' {
            return 'MIT AND Apache-2.0'
        }
        default { return 'MIT' }
    }
}

function Convert-V2TreeDescriptor {
    param(
        [Parameter(Mandatory = $true)][object]$Descriptor,
        [Parameter(Mandatory = $true)][string]$Name
    )

    Assert-ExactProperties $Descriptor @(
        'file_count', 'directory_count', 'total_entries', 'aggregate_bytes',
        'maximum_file_bytes', 'maximum_path_bytes', 'digest_algorithm', 'sha256'
    ) $Name
    if ($Descriptor.digest_algorithm -cne 'retvrn99-file-tree-sha256-v1') {
        throw "$Name has an unsupported tree digest."
    }
    Assert-LowercaseHash $Descriptor.sha256 64 "$Name sha256"
    return [pscustomobject]@{
        FileCount = Assert-UnsignedInteger $Descriptor.file_count "$Name file_count"
        DirectoryCount = Assert-UnsignedInteger $Descriptor.directory_count `
            "$Name directory_count"
        TotalEntries = Assert-UnsignedInteger $Descriptor.total_entries `
            "$Name total_entries"
        AggregateBytes = Assert-UnsignedInteger $Descriptor.aggregate_bytes `
            "$Name aggregate_bytes"
        MaximumFileBytes = Assert-UnsignedInteger $Descriptor.maximum_file_bytes `
            "$Name maximum_file_bytes"
        MaximumPathBytes = Assert-UnsignedInteger $Descriptor.maximum_path_bytes `
            "$Name maximum_path_bytes"
        Sha256 = [string]$Descriptor.sha256
    }
}

function Assert-V2ReproducibilityProof {
    param(
        [Parameter(Mandatory = $true)][object]$Proof,
        [Parameter(Mandatory = $true)][object]$Lock,
        [Parameter(Mandatory = $true)][object]$ExpectedTree
    )

    Assert-ExactProperties $Proof @(
        '_spdx', 'schema', 'schema_definition', 'status', 'reason',
        'component', 'inputs', 'runs', 'comparison', 'scope'
    ) 'generated source reproducibility proof'
    if ($Proof._spdx -cne 'GPL-3.0-only' -or
        (Assert-UnsignedInteger $Proof.schema 'reproducibility proof schema') -ne 1 -or
        $Proof.status -cne 'proven' -or
        $Proof.reason -isnot [string] -or
        [string]::IsNullOrWhiteSpace($Proof.reason) -or
        $Proof.reason.Length -gt 4096) {
        throw 'Generated source reproducibility proof is not proven.'
    }
    Assert-ExactProperties $Proof.schema_definition @(
        'relative_path', 'sha256'
    ) 'reproducibility proof schema definition'
    if ($Proof.schema_definition.relative_path -cne
            'mesa-generated-source-reproducibility.schema.json' -or
        $Proof.schema_definition.sha256 -cne
            '714ad34a83cfe5de7de4e633c9391b36f3d4cdddd6ddf4e3db304545f44ebce0') {
        throw 'Generated source reproducibility schema identity mismatch.'
    }

    Assert-ExactProperties $Proof.component @(
        'upstream_name', 'repository', 'owning_commit', 'mesa_version',
        'mesa_subtree'
    ) 'reproducibility proof component'
    foreach ($property in @(
        'upstream_name', 'repository', 'owning_commit', 'mesa_version',
        'mesa_subtree'
    )) {
        if ($Proof.component.$property -cne $Lock.component.$property) {
            throw 'Generated source reproducibility component identity mismatch.'
        }
    }

    Assert-ExactProperties $Proof.inputs @(
        'generated_source_plan', 'generated_source_plan_schema',
        'generator_recipe', 'source_seed'
    ) 'reproducibility proof inputs'
    Assert-V2FileDescriptor $Proof.inputs.generated_source_plan `
        'reproducibility generated source plan'
    Assert-V2FileDescriptor $Proof.inputs.generated_source_plan_schema `
        'reproducibility generated source plan schema'
    Assert-V2FileDescriptor $Proof.inputs.generator_recipe `
        'reproducibility generator recipe' -GitBlob
    Assert-V2FileDescriptor $Proof.inputs.source_seed `
        'reproducibility source seed'
    if (-not (Test-RowsEqual $Proof.inputs.generated_source_plan `
            $Lock.provenance.generated_source_plan @(
                'relative_path', 'bytes', 'sha256'
            )) -or
        $Proof.inputs.generated_source_plan_schema.relative_path -cne
            'mesa-generated-source-plan.schema.json' -or
        $Proof.inputs.generated_source_plan_schema.bytes -ne 10706 -or
        $Proof.inputs.generated_source_plan_schema.sha256 -cne
            'adc69c44e1ebd9e465f667ef42a605451c05a601c4db59bdd2652cf7709cec97' -or
        -not (Test-RowsEqual $Proof.inputs.generator_recipe `
            $Lock.provenance.generator_recipe @(
                'relative_path', 'git_blob', 'bytes', 'sha256'
            )) -or
        -not (Test-RowsEqual $Proof.inputs.source_seed `
            $Lock.provenance.source_seed @(
                'relative_path', 'bytes', 'sha256'
            ))) {
        throw 'Generated source reproducibility input identity mismatch.'
    }

    if ($Proof.runs -isnot [Array] -or $Proof.runs.Count -ne 2) {
        throw 'Generated source reproducibility requires exactly two runs.'
    }
    $expectedRuns = @(
        [pscustomobject]@{
            Id = 'mesa-generated-lf-v1'
            SourceMode = 'lf'
            CoreAutocrlf = $false
            Binding = 'fa3d0f5ed1eceebacf90bfb12f6a172738a858d590c10e277a52c45d7f23f82a'
        },
        [pscustomobject]@{
            Id = 'mesa-generated-crlf-v1'
            SourceMode = 'crlf'
            CoreAutocrlf = $true
            Binding = '9373c9e734ba71974ddde8b4edb4823fc6c60fa6d70a6a0bfc8339dc1d16f2c8'
        }
    )
    for ($index = 0; $index -lt $Proof.runs.Count; $index++) {
        $run = $Proof.runs[$index]
        $expectedRun = $expectedRuns[$index]
        Assert-ExactProperties $run @(
            'id', 'source_mode', 'core_autocrlf',
            'source_checkout_identity', 'output_root_identity', 'normalization',
            'descriptor', 'validation_side_output_count', 'run_binding_sha256'
        ) "reproducibility run $index"
        if ($run.id -cne $expectedRun.Id -or
            $run.source_mode -cne $expectedRun.SourceMode -or
            $run.core_autocrlf -isnot [bool] -or
            $run.core_autocrlf -ne $expectedRun.CoreAutocrlf -or
            $run.source_checkout_identity -cne 'independent-pinned-checkout' -or
            $run.output_root_identity -cne 'external-content-addressed-root' -or
            $run.normalization -cne 'strict-utf-8-no-bom-lf' -or
            (Assert-UnsignedInteger $run.validation_side_output_count `
                "reproducibility run $index side-output count") -ne 0 -or
            $run.run_binding_sha256 -cne $expectedRun.Binding) {
            throw 'Generated source reproducibility run identity mismatch.'
        }
        $runTree = Convert-V2TreeDescriptor $run.descriptor `
            "reproducibility run $index descriptor"
        Assert-DescriptorMatches $runTree $ExpectedTree `
            "Reproducibility run $index tree"
    }

    Assert-ExactProperties $Proof.comparison @(
        'source_checkout_relationship', 'output_root_relationship',
        'path_identity', 'normalized_outputs_byte_identical',
        'validation_side_output_paths',
        'validation_side_output_count_per_root'
    ) 'reproducibility comparison'
    if ($Proof.comparison.source_checkout_relationship -cne 'independent' -or
        $Proof.comparison.output_root_relationship -cne 'distinct-non-nested' -or
        $Proof.comparison.path_identity -cne 'content-only-no-absolute-root' -or
        $Proof.comparison.normalized_outputs_byte_identical -isnot [bool] -or
        -not $Proof.comparison.normalized_outputs_byte_identical -or
        $Proof.comparison.validation_side_output_paths -isnot [Array] -or
        $Proof.comparison.validation_side_output_paths.Count -ne 4 -or
        (Assert-UnsignedInteger `
            $Proof.comparison.validation_side_output_count_per_root `
            'reproducibility comparison side-output count') -ne 0) {
        throw 'Generated source reproducibility comparison is not distinct and proven.'
    }
    for ($index = 0; $index -lt 4; $index++) {
        if ($Proof.comparison.validation_side_output_paths[$index] -cne
            $Lock.validation_only_side_outputs[$index]) {
            throw 'Generated source reproducibility side-output identity mismatch.'
        }
    }

    Assert-ExactProperties $Proof.scope @(
        'classification', 'claims', 'authorizations'
    ) 'reproducibility proof scope'
    Assert-ExactProperties $Proof.scope.claims @(
        'normalized_output_reproducibility', 'generator_execution',
        'generator_trust', 'package_trust', 'generated_output_lock',
        'file_license_closure', 'build_closure'
    ) 'reproducibility proof claims'
    Assert-ExactProperties $Proof.scope.authorizations @(
        'generator_execution', 'build', 'stage', 'guest_install',
        'dll_activation', 'capability_advertisement'
    ) 'reproducibility proof authorizations'
    if ($Proof.scope.classification -cne
            'normalized-generated-source-reproducibility-only' -or
        $Proof.scope.claims.normalized_output_reproducibility -isnot [bool] -or
        -not $Proof.scope.claims.normalized_output_reproducibility) {
        throw 'Generated source reproducibility scope is not proven-only.'
    }
    foreach ($claim in @(
        'generator_execution', 'generator_trust', 'package_trust',
        'generated_output_lock', 'file_license_closure', 'build_closure'
    )) {
        Assert-FalseBoolean $Proof.scope.claims.$claim `
            "reproducibility proof claim $claim"
    }
    foreach ($authorization in @(
        'generator_execution', 'build', 'stage', 'guest_install',
        'dll_activation', 'capability_advertisement'
    )) {
        Assert-FalseBoolean $Proof.scope.authorizations.$authorization `
            "reproducibility proof authorization $authorization"
    }
}

function Get-V2CanonicalLicenseExpression {
    param([Parameter(Mandatory = $true)][string[]]$EvidenceExpressions)

    $unique = [Collections.Generic.List[string]]::new()
    foreach ($expression in $EvidenceExpressions) {
        if (-not $unique.Contains($expression)) { $unique.Add($expression) }
    }
    $key = $unique -join '|'
    switch -CaseSensitive ($key) {
        'MIT' { return 'MIT' }
        'MIT|GPL-3.0-or-later WITH Bison-exception-2.2' {
            return 'MIT AND (GPL-3.0-or-later WITH Bison-exception-2.2)'
        }
        'MIT|BSD-3-Clause' { return 'MIT AND BSD-3-Clause' }
        'MIT|Apache-2.0' { return 'MIT AND Apache-2.0' }
        default { throw "Non-canonical license evidence sequence '$key'." }
    }
}

function Invoke-V2GeneratedOutputLockVerification {
    param(
        [Parameter(Mandatory = $true)][string]$GeneratedRootPath,
        [Parameter(Mandatory = $true)][string]$LockPath,
        [Parameter(Mandatory = $true)][string]$MetadataRootPath,
        [Parameter(Mandatory = $true)][object]$LockSnapshot,
        [AllowNull()][string]$EvidenceSourceRootPath
    )

    foreach ($requiredDirectory in @(
        [pscustomobject]@{ Path = $GeneratedRootPath; Name = 'Generated root' },
        [pscustomobject]@{ Path = $MetadataRootPath; Name = 'Metadata root' }
    )) {
        if (-not (Test-Path -LiteralPath $requiredDirectory.Path -PathType Container)) {
            throw "$($requiredDirectory.Name) not found: $($requiredDirectory.Path)"
        }
        Assert-NoReparseAncestor $requiredDirectory.Path $requiredDirectory.Name
    }
    if (-not [string]::IsNullOrWhiteSpace($EvidenceSourceRootPath)) {
        if (-not (Test-Path -LiteralPath $EvidenceSourceRootPath -PathType Container)) {
            throw "Evidence source root not found: $EvidenceSourceRootPath"
        }
        Assert-NoReparseAncestor $EvidenceSourceRootPath 'Evidence source root'
    }
    Assert-NoReparseAncestor $LockPath 'Generated-output lock'

    $lock = $LockSnapshot.Value
    Assert-ExactProperties $lock @(
        '_spdx', 'schema', 'status', 'reason', 'component', 'provenance',
        'license_evidence', 'outputs', 'validation_only_side_outputs',
        'output_tree', 'scope'
    ) 'generated-output lock v2 root'
    if ($lock._spdx -isnot [string] -or $lock._spdx -cne 'GPL-3.0-only' -or
        (Assert-UnsignedInteger $lock.schema 'generated-output lock schema') -ne 2) {
        throw 'Unsupported generated-output lock v2 schema.'
    }
    if ($lock.status -isnot [string] -or
        @('blocked', 'reviewed-generated-source') -cnotcontains $lock.status -or
        $lock.reason -isnot [string] -or $lock.reason.Length -gt 4096) {
        throw 'Invalid generated-output review status.'
    }

    Assert-ExactProperties $lock.component @(
        'component_id', 'upstream_name', 'repository', 'owning_commit',
        'mesa_version', 'mesa_subtree'
    ) 'generated-output component v2'
    if ($lock.component.component_id -cne 'mesa-23-1-9-generated' -or
        $lock.component.upstream_name -cne 'mesa9x' -or
        $lock.component.repository -cne 'https://github.com/JHRobotics/mesa9x.git' -or
        $lock.component.owning_commit -cne
            '29b9adb44bc5ea54dc53c02b5e4b49292c6cc04f' -or
        $lock.component.mesa_version -cne '23.1.9' -or
        $lock.component.mesa_subtree -cne 'mesa-23.1.x') {
        throw 'Generated-output component v2 is not the pinned Mesa 23.1.9 source.'
    }

    Assert-ExactProperties $lock.provenance @(
        'generated_source_plan', 'generated_source_reproducibility',
        'component_closure', 'generator_recipe', 'source_seed', 'recipe_variable',
        'recipe_output_sequence_sha256'
    ) 'generated-output provenance v2'
    Assert-V2FileDescriptor $lock.provenance.generated_source_plan `
        'generated source plan descriptor'
    Assert-V2FileDescriptor $lock.provenance.generated_source_reproducibility `
        'generated source reproducibility descriptor'
    Assert-V2FileDescriptor $lock.provenance.component_closure `
        'component closure descriptor'
    Assert-V2FileDescriptor $lock.provenance.generator_recipe `
        'generator recipe descriptor' -GitBlob
    Assert-V2FileDescriptor $lock.provenance.source_seed 'source seed descriptor'
    if ($lock.provenance.generated_source_plan.relative_path -cne
            'mesa-generated-source-plan.json' -or
        $lock.provenance.generated_source_plan.bytes -ne 4354 -or
        $lock.provenance.generated_source_plan.sha256 -cne
            '7d08ea089889105443935fb48a59a69698e5c0cac9f5f87ff02c8710c2a5718c' -or
        $lock.provenance.generated_source_reproducibility.relative_path -cne
            'mesa-generated-source-reproducibility.json' -or
        $lock.provenance.component_closure.relative_path -cne
            'component-closures/mesa9x-23.1.x.json' -or
        $lock.provenance.component_closure.bytes -ne 815285 -or
        $lock.provenance.component_closure.sha256 -cne
            'd93a476656ec9f18c1d257a65ae6461111c7e85ec0b704360bcc42b836dbefc5' -or
        $lock.provenance.generator_recipe.relative_path -cne
            'generator/mesa-23.1.x-gen.mk' -or
        $lock.provenance.generator_recipe.git_blob -cne
            '68b2fd13d08ae0ce4276cb1f720ee9bbb1cd54e9' -or
        $lock.provenance.generator_recipe.bytes -ne 13288 -or
        $lock.provenance.generator_recipe.sha256 -cne
            '9ad77b1fe55e4097621dbefeffe989fb00f3c354320ce6521d69f8efd8a44dce' -or
        $lock.provenance.source_seed.relative_path -cne 'mesa-source-seed.json' -or
        $lock.provenance.source_seed.bytes -ne 6915 -or
        $lock.provenance.source_seed.sha256 -cne
            'b7a18f8bfe4bfe5fac1ef8b4f36105d585e7d69349766d865c8c79a180d79dd8' -or
        $lock.provenance.recipe_variable -cne 'GENERATE_FILES' -or
        $lock.provenance.recipe_output_sequence_sha256 -cne
            '480f4000b3d6c10eced24e4538ee4aabdd59e3dbe3172054910bc7eac01c7140') {
        throw 'Generated-output v2 provenance does not match the reviewed Mesa plan.'
    }

    $planPath = Get-ContainedPath $MetadataRootPath `
        $lock.provenance.generated_source_plan.relative_path 'generated source plan'
    $reproducibilityPath = Get-ContainedPath $MetadataRootPath `
        $lock.provenance.generated_source_reproducibility.relative_path `
        'generated source reproducibility proof'
    $componentClosurePath = Get-ContainedPath $MetadataRootPath `
        $lock.provenance.component_closure.relative_path 'component closure'
    $seedPath = Get-ContainedPath $MetadataRootPath `
        $lock.provenance.source_seed.relative_path 'source seed'
    foreach ($metadataFile in @(
        [pscustomobject]@{
            Path = $planPath
            Name = 'Generated source plan'
            Descriptor = $lock.provenance.generated_source_plan
        },
        [pscustomobject]@{
            Path = $reproducibilityPath
            Name = 'Generated source reproducibility proof'
            Descriptor = $lock.provenance.generated_source_reproducibility
        },
        [pscustomobject]@{
            Path = $componentClosurePath
            Name = 'Component closure'
            Descriptor = $lock.provenance.component_closure
        },
        [pscustomobject]@{
            Path = $seedPath
            Name = 'Source seed'
            Descriptor = $lock.provenance.source_seed
        }
    )) {
        if (-not (Test-Path -LiteralPath $metadataFile.Path -PathType Leaf)) {
            throw "$($metadataFile.Name) not found: $($metadataFile.Path)"
        }
        Assert-NoReparseAncestor $metadataFile.Path $metadataFile.Name
        $snapshot = Read-GswBoundedFileSnapshot -Path $metadataFile.Path `
            -Name $metadataFile.Name -MaximumBytes 1048576
        if ($snapshot.Bytes.Length -ne $metadataFile.Descriptor.bytes -or
            $snapshot.Sha256 -cne $metadataFile.Descriptor.sha256) {
            throw "$($metadataFile.Name) content mismatch."
        }
    }
    $planSnapshot = Read-StrictJsonSnapshot -Path $planPath `
        -Name 'generated source plan' -MaximumBytes 1048576
    $plan = $planSnapshot.Value
    $reproducibilitySnapshot = Read-StrictJsonSnapshot `
        -Path $reproducibilityPath `
        -Name 'generated source reproducibility proof' -MaximumBytes 1048576
    $reproducibility = $reproducibilitySnapshot.Value
    $componentClosureSnapshot = Read-StrictJsonSnapshot `
        -Path $componentClosurePath -Name 'component closure' `
        -MaximumBytes 1048576
    $componentClosure = $componentClosureSnapshot.Value
    if ($plan.component.upstream_name -cne $lock.component.upstream_name -or
        $plan.component.repository -cne $lock.component.repository -or
        $plan.component.owning_commit -cne $lock.component.owning_commit -or
        $plan.component.mesa_version -cne $lock.component.mesa_version -or
        $plan.component.mesa_subtree -cne $lock.component.mesa_subtree -or
        $plan.inputs.generator_recipe.relative_path -cne
            $lock.provenance.generator_recipe.relative_path -or
        $plan.inputs.generator_recipe.git_blob -cne
            $lock.provenance.generator_recipe.git_blob -or
        $plan.inputs.generator_recipe.bytes -ne
            $lock.provenance.generator_recipe.bytes -or
        $plan.inputs.generator_recipe.sha256 -cne
            $lock.provenance.generator_recipe.sha256 -or
        $plan.inputs.source_seed.relative_path -cne
            $lock.provenance.source_seed.relative_path -or
        $plan.inputs.source_seed.bytes -ne $lock.provenance.source_seed.bytes -or
        $plan.inputs.source_seed.sha256 -cne $lock.provenance.source_seed.sha256 -or
        $plan.selection.recipe_variable -cne $lock.provenance.recipe_variable -or
        $plan.selection.recipe_output_count -ne 67 -or
        $plan.selection.published_output_count -ne 67 -or
        $plan.selection.recipe_output_sequence_sha256 -cne
            $lock.provenance.recipe_output_sequence_sha256) {
        throw 'Generated-output v2 provenance disagrees with the generated source plan.'
    }
    $componentIndex = Get-V2ComponentClosureIndex $componentClosure $lock

    Assert-ExactProperties $lock.scope @(
        'classification', 'claims', 'authorizations'
    ) 'generated-output v2 scope'
    Assert-ExactProperties $lock.scope.claims @(
        'generated_source_bytes_reviewed', 'output_reproducibility',
        'file_license_evidence_complete', 'generator_input_closure',
        'component_closure', 'build_closure'
    ) 'generated-output v2 claims'
    Assert-ExactProperties $lock.scope.authorizations @(
        'generator_execution', 'build', 'stage', 'guest_install',
        'capability_advertisement'
    ) 'generated-output v2 authorizations'
    foreach ($authorization in @(
        'generator_execution', 'build', 'stage', 'guest_install',
        'capability_advertisement'
    )) {
        Assert-FalseBoolean $lock.scope.authorizations.$authorization `
            "generated-output authorization $authorization"
    }
    foreach ($claim in @(
        'generator_input_closure', 'component_closure', 'build_closure'
    )) {
        Assert-FalseBoolean $lock.scope.claims.$claim "generated-output claim $claim"
    }
    foreach ($claim in @(
        'generated_source_bytes_reviewed', 'output_reproducibility',
        'file_license_evidence_complete'
    )) {
        if ($lock.scope.claims.$claim -isnot [bool]) {
            throw "Generated-output claim $claim must be Boolean."
        }
    }
    if ($lock.status -ceq 'blocked') {
        if ([string]::IsNullOrWhiteSpace($lock.reason) -or
            $lock.scope.classification -cne 'generated-source-review-blocked' -or
            $lock.scope.claims.file_license_evidence_complete) {
            throw 'Blocked generated-output review has inconsistent status semantics.'
        }
    }
    elseif ($lock.reason.Length -ne 0 -or
        $lock.scope.classification -cne 'reviewed-generated-source' -or
        -not $lock.scope.claims.generated_source_bytes_reviewed -or
        -not $lock.scope.claims.output_reproducibility -or
        -not $lock.scope.claims.file_license_evidence_complete) {
        throw 'Reviewed generated-output source has inconsistent status semantics.'
    }

    if ($lock.license_evidence -isnot [Array] -or
        $lock.license_evidence.Count -gt 512 -or
        $lock.outputs -isnot [Array] -or $lock.outputs.Count -ne 67 -or
        $lock.validation_only_side_outputs -isnot [Array] -or
        $lock.validation_only_side_outputs.Count -ne 4) {
        throw 'Generated-output v2 arrays violate their exact bounds.'
    }
    $allowedEvidenceExpressions = @(
        'MIT', 'GPL-3.0-or-later WITH Bison-exception-2.2',
        'BSD-3-Clause', 'Apache-2.0'
    )
    $evidenceById = [Collections.Generic.Dictionary[string,object]]::new(
        [StringComparer]::Ordinal
    )
    $evidenceOrder = [Collections.Generic.Dictionary[string,int]]::new(
        [StringComparer]::Ordinal
    )
    $sourceBlobSnapshots = [Collections.Generic.Dictionary[string,object]]::new(
        [StringComparer]::Ordinal
    )
    $generatedEvidenceSnapshots = [Collections.Generic.Dictionary[string,object]]::new(
        [StringComparer]::Ordinal
    )
    $generatedEvidenceRows = [Collections.Generic.List[object]]::new()
    $evidenceRows = @($lock.license_evidence)
    $hasSourceEvidence = @($evidenceRows | Where-Object {
        $_.origin -ceq 'component-closure-source'
    }).Count -gt 0
    if ($hasSourceEvidence) {
        if ([string]::IsNullOrWhiteSpace($EvidenceSourceRootPath)) {
            throw 'SourceRoot is required to audit canonical Git-blob license evidence.'
        }
        if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
            throw 'git is required to audit canonical Git-blob license evidence.'
        }
        $sourceHead = Invoke-V2BoundedGitTextCommand `
            -Checkout $EvidenceSourceRootPath `
            -Arguments @('rev-parse', '--verify', 'HEAD^{commit}') `
            -Name 'evidence source HEAD'
        if ($sourceHead -cne $lock.component.owning_commit) {
            throw 'Evidence source checkout is not at the pinned Mesa commit.'
        }
    }
    $previousEvidenceId = $null
    for ($index = 0; $index -lt $evidenceRows.Count; $index++) {
        $evidence = $evidenceRows[$index]
        Assert-Identifier $evidence.id 'license evidence id'
        if ($previousEvidenceId -ne $null -and
            [StringComparer]::Ordinal.Compare($previousEvidenceId, $evidence.id) -ge 0) {
            throw 'License evidence must be in strict ordinal id order.'
        }
        if (@('generated-output', 'component-closure-source') -cnotcontains
                $evidence.origin -or
            $allowedEvidenceExpressions -cnotcontains $evidence.license_expression -or
            $evidenceById.ContainsKey($evidence.id) -or
            $null -eq $evidence.subject -or $null -eq $evidence.evidence_file -or
            $null -eq $evidence.locator) {
            throw "Invalid license evidence '$($evidence.id)'."
        }
        if ($evidence.origin -ceq 'generated-output') {
            Assert-ExactProperties $evidence @(
                'id', 'origin', 'subject', 'evidence_file', 'locator',
                'license_expression'
            ) 'generated-output license evidence'
            Assert-V2FileDescriptor $evidence.subject `
                'generated-output evidence subject'
            Assert-V2FileDescriptor $evidence.evidence_file `
                'generated-output evidence file'
            if (-not (Test-V2FileDescriptorIdentity `
                    $evidence.subject $evidence.evidence_file)) {
                throw "Generated evidence '$($evidence.id)' does not use its subject as the evidence file."
            }
            $evidencePath = Get-ContainedPath $GeneratedRootPath `
                $evidence.evidence_file.relative_path 'generated-output evidence'
            Assert-ContainedPathHasNoReparsePoint $GeneratedRootPath `
                $evidence.evidence_file.relative_path 'generated-output evidence'
            if (-not (Test-Path -LiteralPath $evidencePath -PathType Leaf)) {
                throw "Generated evidence '$($evidence.id)' is missing."
            }
            $evidenceSnapshot = Read-GswBoundedFileSnapshot `
                -Path $evidencePath -Name "generated evidence '$($evidence.id)'" `
                -MaximumBytes $script:MaximumOutputFileBytes
            if ($evidenceSnapshot.Length -ne [UInt64]$evidence.evidence_file.bytes -or
                $evidenceSnapshot.Sha256 -cne $evidence.evidence_file.sha256) {
                throw "Generated evidence '$($evidence.id)' content mismatch."
            }
            Assert-V2EvidenceLocator $evidence.locator $evidenceSnapshot `
                "generated evidence '$($evidence.id)'"
            $generatedEvidenceSnapshots.Add($evidence.id, [pscustomobject]@{
                Path = $evidencePath
                Sha256 = $evidenceSnapshot.Sha256
            })
            [void]$generatedEvidenceRows.Add($evidence)
        }
        else {
            Assert-ExactProperties $evidence @(
                'id', 'origin', 'subject', 'component_evidence_id',
                'evidence_file', 'locator', 'license_expression'
            ) 'component-closure source license evidence'
            Assert-Identifier $evidence.component_evidence_id `
                'component closure evidence id'
            Assert-V2FileDescriptor $evidence.subject `
                'source evidence subject' -GitBlob
            Assert-V2FileDescriptor $evidence.evidence_file `
                'source evidence file' -GitBlob
            if (-not $componentIndex.FilesByPath.ContainsKey(
                    $evidence.subject.relative_path
                )) {
                throw "Source evidence '$($evidence.id)' has an unknown subject."
            }
            $componentSubject = $componentIndex.FilesByPath[
                $evidence.subject.relative_path
            ]
            if (-not (Test-V2FileDescriptorIdentity `
                    $evidence.subject $componentSubject -GitBlob) -or
                @($componentSubject.roles | Where-Object {
                    $_ -ceq 'generator-input' -or $_ -ceq 'build-description'
                }).Count -eq 0 -or
                @($componentSubject.license_evidence_ids) -cnotcontains
                    $evidence.component_evidence_id) {
                throw "Source evidence '$($evidence.id)' does not bind an allowed component input."
            }
            if (-not $componentIndex.EvidenceById.ContainsKey(
                    $evidence.component_evidence_id
                )) {
                throw "Source evidence '$($evidence.id)' names unknown component evidence."
            }
            $componentEvidence = $componentIndex.EvidenceById[
                $evidence.component_evidence_id
            ]
            if (-not (Test-V2FileDescriptorIdentity `
                    $evidence.evidence_file $componentEvidence -GitBlob) -or
                $evidence.license_expression -cne
                    $componentEvidence.observed_license_expression -or
                $evidence.locator.kind -cne $componentEvidence.locator.kind) {
                throw "Source evidence '$($evidence.id)' disagrees with the component closure."
            }
            if ($evidence.locator.kind -ceq 'whole-file') {
                if ($evidence.locator.sha256 -cne
                    $evidence.evidence_file.sha256) {
                    throw "Source evidence '$($evidence.id)' has an invalid whole-file locator."
                }
            }
            elseif ($evidence.locator.byte_offset -ne
                    $componentEvidence.locator.byte_offset -or
                $evidence.locator.byte_count -ne
                    $componentEvidence.locator.byte_count -or
                $evidence.locator.sha256 -cne
                    $componentEvidence.locator.sha256) {
                throw "Source evidence '$($evidence.id)' has a non-canonical byte-range locator."
            }

            foreach ($descriptor in @(
                $evidence.subject, $evidence.evidence_file
            )) {
                if (-not $sourceBlobSnapshots.ContainsKey($descriptor.git_blob)) {
                    $snapshot = Read-V2GitBlobSnapshot `
                        -Checkout $EvidenceSourceRootPath `
                        -Blob $descriptor.git_blob `
                        -ExpectedBytes ([UInt64]$descriptor.bytes) `
                        -Name "source blob '$($descriptor.relative_path)'"
                    if ($snapshot.Sha256 -cne $descriptor.sha256) {
                        throw "Source blob '$($descriptor.relative_path)' content mismatch."
                    }
                    $sourceBlobSnapshots.Add($descriptor.git_blob, [pscustomobject]@{
                        Descriptor = $descriptor
                        Snapshot = $snapshot
                    })
                }
                elseif ($sourceBlobSnapshots[$descriptor.git_blob].Snapshot.Length -ne
                        [UInt64]$descriptor.bytes -or
                    $sourceBlobSnapshots[$descriptor.git_blob].Snapshot.Sha256 -cne
                        $descriptor.sha256) {
                    throw "Source blob '$($descriptor.relative_path)' has conflicting descriptors."
                }
            }
            Assert-V2EvidenceLocator $evidence.locator `
                $sourceBlobSnapshots[$evidence.evidence_file.git_blob].Snapshot `
                "source evidence '$($evidence.id)'"
        }
        $previousEvidenceId = [string]$evidence.id
        $evidenceById.Add($evidence.id, $evidence)
        $evidenceOrder.Add($evidence.id, $index)
    }

    $allowedOutputExpressions = @(
        'MIT', 'MIT AND (GPL-3.0-or-later WITH Bison-exception-2.2)',
        'MIT AND BSD-3-Clause', 'MIT AND Apache-2.0'
    )
    $outputs = @($lock.outputs)
    Assert-PortablePathSet $outputs 'generated outputs v2'
    $outputsByPath = [Collections.Generic.Dictionary[string,object]]::new(
        [StringComparer]::Ordinal
    )
    $usedEvidence = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )
    $expectedDirectories = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )
    $previousOutputPath = $null
    foreach ($output in $outputs) {
        Assert-ExactProperties $output @(
            'relative_path', 'bytes', 'sha256', 'license_expression',
            'license_evidence_ids'
        ) 'generated output v2'
        Assert-SafeRelativePath $output.relative_path 'generated output v2'
        if ($previousOutputPath -ne $null -and
            [StringComparer]::Ordinal.Compare(
                $previousOutputPath, $output.relative_path
            ) -ge 0) {
            throw 'Generated outputs v2 must be in strict ordinal path order.'
        }
        $previousOutputPath = [string]$output.relative_path
        $outputBytes = Assert-UnsignedInteger $output.bytes 'generated output v2 bytes'
        Assert-LowercaseHash $output.sha256 64 'generated output v2 sha256'
        if ($outputBytes -gt $script:MaximumOutputFileBytes -or
            $allowedOutputExpressions -cnotcontains $output.license_expression -or
            $output.license_expression -cne
                (Get-MesaV2ExpectedLicenseExpression $output.relative_path) -or
            $output.license_evidence_ids -isnot [Array] -or
            $output.license_evidence_ids.Count -gt 8) {
            throw "Invalid license classification for '$($output.relative_path)'."
        }
        $evidenceExpressions = [Collections.Generic.List[string]]::new()
        $previousEvidenceIndex = -1
        foreach ($evidenceId in $output.license_evidence_ids) {
            Assert-Identifier $evidenceId 'output license evidence id'
            if (-not $evidenceById.ContainsKey($evidenceId) -or
                $evidenceOrder[$evidenceId] -le $previousEvidenceIndex) {
                throw "Invalid or non-canonical license evidence order for '$($output.relative_path)'."
            }
            $previousEvidenceIndex = $evidenceOrder[$evidenceId]
            [void]$usedEvidence.Add($evidenceId)
            $evidenceExpressions.Add($evidenceById[$evidenceId].license_expression)
        }
        if ($output.license_evidence_ids.Count -eq 0) {
            if ($lock.status -cne 'blocked') {
                throw "Reviewed output '$($output.relative_path)' lacks license evidence."
            }
        }
        elseif ((Get-V2CanonicalLicenseExpression $evidenceExpressions) -cne
            $output.license_expression) {
            throw "Non-canonical license expression for '$($output.relative_path)'."
        }
        $outputsByPath.Add($output.relative_path, [pscustomobject]@{
            Bytes = $outputBytes
            Sha256 = [string]$output.sha256
        })
        $parts = $output.relative_path.Split('/')
        for ($count = 1; $count -lt $parts.Count; $count++) {
            [void]$expectedDirectories.Add(
                [string]::Join('/', $parts[0..($count - 1)])
            )
        }
    }
    if ($usedEvidence.Count -ne $evidenceById.Count) {
        throw 'Generated-output v2 contains unused license evidence.'
    }
    foreach ($evidence in $generatedEvidenceRows) {
        if (-not $outputsByPath.ContainsKey($evidence.subject.relative_path) -or
            $outputsByPath[$evidence.subject.relative_path].Bytes -ne
                [UInt64]$evidence.subject.bytes -or
            $outputsByPath[$evidence.subject.relative_path].Sha256 -cne
                $evidence.subject.sha256) {
            throw "Generated-output evidence '$($evidence.id)' does not bind its output."
        }
    }

    [string[]]$expectedSideOutputs = @(
        'mesa-23.1.x/src/compiler/glsl/glcpp/glcpp-parse.h',
        'mesa-23.1.x/src/compiler/glsl/glsl_parser.h',
        'mesa-23.1.x/src/gallium/auxiliary/driver_trace/tr_util.h',
        'mesa-23.1.x/src/mesa/program/program_parse.tab.h'
    )
    for ($index = 0; $index -lt $expectedSideOutputs.Count; $index++) {
        $sideOutput = $lock.validation_only_side_outputs[$index]
        Assert-SafeRelativePath $sideOutput 'validation-only side output'
        if ($sideOutput -cne $expectedSideOutputs[$index] -or
            $outputsByPath.ContainsKey($sideOutput)) {
            throw 'Validation-only side outputs are not exactly excluded.'
        }
        if ($plan.selection.validation_side_outputs[$index].relative_path -cne
            $sideOutput) {
            throw 'Validation-only side outputs disagree with the generated source plan.'
        }
        $sidePath = Get-ContainedPath $GeneratedRootPath $sideOutput `
            'validation-only side output'
        if (Test-Path -LiteralPath $sidePath) {
            throw "Validation-only side output '$sideOutput' was published."
        }
    }

    Assert-ExactProperties $lock.output_tree @(
        'file_count', 'directory_count', 'total_entries', 'aggregate_bytes',
        'maximum_file_bytes', 'maximum_path_bytes', 'digest_algorithm', 'sha256'
    ) 'output_tree v2'
    $expectedTree = [pscustomobject]@{
        FileCount = Assert-UnsignedInteger $lock.output_tree.file_count `
            'output_tree v2 file_count'
        DirectoryCount = Assert-UnsignedInteger $lock.output_tree.directory_count `
            'output_tree v2 directory_count'
        TotalEntries = Assert-UnsignedInteger $lock.output_tree.total_entries `
            'output_tree v2 total_entries'
        AggregateBytes = Assert-UnsignedInteger $lock.output_tree.aggregate_bytes `
            'output_tree v2 aggregate_bytes'
        MaximumFileBytes = Assert-UnsignedInteger $lock.output_tree.maximum_file_bytes `
            'output_tree v2 maximum_file_bytes'
        MaximumPathBytes = Assert-UnsignedInteger $lock.output_tree.maximum_path_bytes `
            'output_tree v2 maximum_path_bytes'
        Sha256 = [string]$lock.output_tree.sha256
    }
    if ($lock.output_tree.digest_algorithm -cne 'retvrn99-file-tree-sha256-v1' -or
        $expectedTree.FileCount -ne 67 -or $expectedTree.DirectoryCount -ne 20 -or
        $expectedTree.TotalEntries -ne 87 -or
        $expectedTree.AggregateBytes -ne 34876554 -or
        $expectedTree.MaximumFileBytes -ne 20214289 -or
        $expectedTree.MaximumPathBytes -ne 65 -or
        $expectedTree.Sha256 -cne
            'dd0ae888829eabf2a0043f27100aa64c57b43ad12054270bee62f50ccc451d84' -or
        $expectedDirectories.Count -ne 20) {
        throw 'Output tree v2 does not bind the reviewed 67-file Mesa root.'
    }

    Assert-V2ReproducibilityProof $reproducibility $lock $expectedTree
    if ($lock.provenance.generated_source_reproducibility.bytes -ne 4418 -or
        $lock.provenance.generated_source_reproducibility.sha256 -cne
            'd37322e969730fb71d2663c19752728802631cb9bd55b3d294824e3ac4ca2f0b') {
        throw 'Generated source reproducibility proof identity mismatch.'
    }

    $firstTree = Get-GeneratedTreeDescriptor $GeneratedRootPath
    if ($firstTree.Records.Count -ne $outputsByPath.Count) {
        throw 'Generated tree contains missing or unpinned output files.'
    }
    foreach ($path in $firstTree.Records.Keys) {
        if (-not $outputsByPath.ContainsKey($path)) {
            throw "Generated tree contains unpinned output '$path'."
        }
        if ($firstTree.Records[$path].Bytes -ne $outputsByPath[$path].Bytes -or
            $firstTree.Records[$path].Sha256 -cne $outputsByPath[$path].Sha256) {
            throw "Generated output '$path' content mismatch."
        }
    }
    Assert-DescriptorMatches $firstTree $expectedTree 'Output tree v2'

    if ($null -ne $BeforeFinalCheckoutCheck) { & $BeforeFinalCheckoutCheck }
    $secondTree = Get-GeneratedTreeDescriptor $GeneratedRootPath
    Assert-DescriptorMatches $secondTree $firstTree 'Generated tree stability'
    $finalLock = Read-GswBoundedFileSnapshot -Path $LockPath `
        -Name 'generated-output lock' -MaximumBytes 4194304
    $finalPlan = Read-GswBoundedFileSnapshot -Path $planPath `
        -Name 'generated source plan' -MaximumBytes 1048576
    $finalReproducibility = Read-GswBoundedFileSnapshot `
        -Path $reproducibilityPath `
        -Name 'generated source reproducibility proof' -MaximumBytes 1048576
    $finalComponentClosure = Read-GswBoundedFileSnapshot `
        -Path $componentClosurePath -Name 'component closure' `
        -MaximumBytes 1048576
    $finalSeed = Read-GswBoundedFileSnapshot -Path $seedPath `
        -Name 'source seed' -MaximumBytes 1048576
    if ($finalLock.Sha256 -cne $LockSnapshot.Sha256 -or
        $finalPlan.Sha256 -cne $lock.provenance.generated_source_plan.sha256 -or
        $finalReproducibility.Sha256 -cne
            $lock.provenance.generated_source_reproducibility.sha256 -or
        $finalComponentClosure.Sha256 -cne
            $lock.provenance.component_closure.sha256 -or
        $finalSeed.Sha256 -cne $lock.provenance.source_seed.sha256) {
        throw 'Generated-output v2 metadata changed during verification.'
    }
    foreach ($evidenceId in $generatedEvidenceSnapshots.Keys) {
        $finalEvidence = Read-GswBoundedFileSnapshot `
            -Path $generatedEvidenceSnapshots[$evidenceId].Path `
            -Name "license evidence '$evidenceId'" `
            -MaximumBytes $script:MaximumOutputFileBytes
        if ($finalEvidence.Sha256 -cne
            $generatedEvidenceSnapshots[$evidenceId].Sha256) {
            throw "License evidence '$evidenceId' changed during verification."
        }
    }
    foreach ($blob in $sourceBlobSnapshots.Keys) {
        $descriptor = $sourceBlobSnapshots[$blob].Descriptor
        $finalSourceBlob = Read-V2GitBlobSnapshot `
            -Checkout $EvidenceSourceRootPath -Blob $blob `
            -ExpectedBytes ([UInt64]$descriptor.bytes) `
            -Name "final source blob '$($descriptor.relative_path)'"
        if ($finalSourceBlob.Sha256 -cne
            $sourceBlobSnapshots[$blob].Snapshot.Sha256) {
            throw "Source blob '$($descriptor.relative_path)' changed during verification."
        }
    }

    if ($lock.status -ceq 'blocked') {
        throw "Generated-output review is blocked: $($lock.reason)"
    }
    Write-Output (
        "Reviewed generated source '{0}' with {1} exact outputs; build, stage, install, and capability authorization remain false." -f
            $lock.component.component_id, $outputs.Count
    )
}

$dispatchLockPath = Get-FullPath $LockFile
$dispatchMetadataRootPath = Get-FullPath $MetadataRoot
$dispatchGeneratedRootPath = Get-FullPath $GeneratedRoot
$dispatchEvidenceSourceRootPath = $null
if (-not [string]::IsNullOrWhiteSpace($SourceRoot)) {
    $dispatchEvidenceSourceRootPath = Get-FullPath $SourceRoot
}
if (-not (Test-Path -LiteralPath $dispatchLockPath -PathType Leaf)) {
    throw "Generated-output lock not found: $dispatchLockPath"
}
if ((Get-Item -LiteralPath $dispatchLockPath).Length -gt 4194304) {
    throw 'Generated-output lock exceeds the size bound.'
}
$dispatchLockSnapshot = Read-StrictJsonSnapshot -Path $dispatchLockPath `
    -Name 'generated-output lock' -MaximumBytes 4194304
$dispatchSchema = Assert-UnsignedInteger $dispatchLockSnapshot.Value.schema `
    'generated-output lock schema'
if ($dispatchSchema -eq 2) {
    Invoke-V2GeneratedOutputLockVerification `
        -GeneratedRootPath $dispatchGeneratedRootPath `
        -LockPath $dispatchLockPath `
        -MetadataRootPath $dispatchMetadataRootPath `
        -LockSnapshot $dispatchLockSnapshot `
        -EvidenceSourceRootPath $dispatchEvidenceSourceRootPath
    return
}
if ($dispatchSchema -ne 1) {
    throw 'Unsupported generated-output lock schema.'
}
if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
    throw 'SourceRoot is required for legacy generated-output lock schema v1.'
}

$sourceRootPath = Get-FullPath $SourceRoot
$generatedRootPath = Get-FullPath $GeneratedRoot
$lockPath = Get-FullPath $LockFile
$metadataRootPath = Get-FullPath $MetadataRoot
$upstreamLockPath = Get-FullPath (Join-Path $metadataRootPath 'upstream.lock.tsv')

foreach ($requiredDirectory in @(
    [pscustomobject]@{ Path = $sourceRootPath; Name = 'Source root' },
    [pscustomobject]@{ Path = $generatedRootPath; Name = 'Generated root' },
    [pscustomobject]@{ Path = $metadataRootPath; Name = 'Metadata root' }
)) {
    if (-not (Test-Path -LiteralPath $requiredDirectory.Path -PathType Container)) {
        throw "$($requiredDirectory.Name) not found: $($requiredDirectory.Path)"
    }
    Assert-NoReparseAncestor $requiredDirectory.Path $requiredDirectory.Name
}
if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
    throw "Generated-output lock not found: $lockPath"
}
Assert-NoReparseAncestor $lockPath 'Generated-output lock'
if (-not (Test-Path -LiteralPath $upstreamLockPath -PathType Leaf)) {
    throw "Authoritative upstream lock not found: $upstreamLockPath"
}
Assert-NoReparseAncestor $upstreamLockPath 'Authoritative upstream lock'
if ((Get-Item -LiteralPath $lockPath).Length -gt 4194304) {
    throw 'Generated-output lock exceeds the size bound.'
}
if ((Get-Item -LiteralPath $upstreamLockPath).Length -gt 1048576) {
    throw 'Authoritative upstream lock exceeds the size bound.'
}
if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
    throw 'git is required to verify generated-output locks.'
}

$lockSnapshot = Read-StrictJsonSnapshot -Path $lockPath `
    -Name 'generated-output lock' -MaximumBytes 4194304
$upstreamLockSnapshot = Read-GswBoundedFileSnapshot -Path $upstreamLockPath `
    -Name 'authoritative upstream lock' -MaximumBytes 1048576
$initialLockHash = $lockSnapshot.Sha256
$initialUpstreamLockHash = $upstreamLockSnapshot.Sha256
$lock = $lockSnapshot.Value
Assert-ExactProperties $lock @(
    '_spdx', 'schema', 'component', 'generator_inputs', 'notices', 'outputs',
    'output_tree'
) 'generated-output lock root'
if ($lock._spdx -isnot [string] -or $lock._spdx -cne 'GPL-3.0-only' -or
    (Assert-UnsignedInteger $lock.schema 'generated-output lock schema') -ne 1) {
    throw 'Unsupported generated-output lock schema.'
}
Assert-ExactProperties $lock.component @(
    'component_id', 'upstream_name', 'source_directory', 'repository',
    'owning_commit', 'closure_manifest'
) 'generated-output component'
Assert-Identifier $lock.component.component_id 'component_id'
Assert-Identifier $lock.component.upstream_name 'upstream_name'
if ($lock.component.source_directory -isnot [string] -or
    $lock.component.source_directory -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
    throw "Invalid component source directory '$($lock.component.source_directory)'."
}
if ($lock.component.repository -isnot [string] -or
    $lock.component.repository.Length -gt 2048) {
    throw "Invalid component repository '$($lock.component.repository)'."
}
$repositoryUri = $null
if (-not [Uri]::TryCreate(
        [string]$lock.component.repository,
        [UriKind]::Absolute,
        [ref]$repositoryUri
    ) -or
    $repositoryUri.Scheme -cne 'https' -or
    [string]::IsNullOrWhiteSpace($repositoryUri.Host) -or
    $repositoryUri.UserInfo.Length -ne 0 -or
    $repositoryUri.Query.Length -ne 0 -or
    $repositoryUri.Fragment.Length -ne 0) {
    throw 'Component repository must be a plain HTTPS URL.'
}
Assert-LowercaseHash $lock.component.owning_commit 40 'component owning_commit'
Assert-ExactProperties $lock.component.closure_manifest @(
    'relative_path', 'sha256'
) 'component closure link'
Assert-LowercaseHash $lock.component.closure_manifest.sha256 64 `
    'component closure link sha256'

$requiredUpstreamColumns = @(
    'name', 'source_directory', 'repository', 'commit', 'upstream_license',
    'disposition', 'closure_manifest', 'closure_manifest_sha256', 'scope'
)
$upstreamRows = @(ConvertFrom-StrictTsvUtf8Bytes `
    -Bytes $upstreamLockSnapshot.Bytes -ExpectedHeader $requiredUpstreamColumns `
    -Name 'authoritative upstream lock' -MaximumBytes 1048576 `
    -MaximumRows 64 -MaximumLineBytes 16384 -MaximumPhysicalLines 1024)
$upstreamNames = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
)
$authoritativeRow = $null
foreach ($row in $upstreamRows) {
    if ($row.name -notmatch '^[a-z0-9][a-z0-9-]*$' -or
        -not $upstreamNames.Add($row.name)) {
        throw "Authoritative upstream lock has invalid or duplicate name '$($row.name)'."
    }
    if ($row.name -ceq $lock.component.upstream_name) {
        $authoritativeRow = $row
    }
}
if ($null -eq $authoritativeRow -or
    $authoritativeRow.disposition -cne 'planned-component') {
    throw "Generated component '$($lock.component.upstream_name)' has no authoritative planned-component row."
}
if ($authoritativeRow.source_directory -cne $lock.component.source_directory -or
    $authoritativeRow.repository -cne $lock.component.repository -or
    $authoritativeRow.commit -cne $lock.component.owning_commit -or
    $authoritativeRow.closure_manifest -cne
        $lock.component.closure_manifest.relative_path -or
    $authoritativeRow.closure_manifest_sha256 -cne
        $lock.component.closure_manifest.sha256) {
    throw 'Generated component provenance does not match its authoritative upstream lock row.'
}
if ($authoritativeRow.upstream_license -notmatch '^[A-Za-z0-9][A-Za-z0-9.+-]*$' -or
    $authoritativeRow.scope -notmatch '^[a-z0-9][a-z0-9-]*$') {
    throw 'Authoritative upstream component row has invalid license or scope metadata.'
}

foreach ($arrayMetadata in @(
    [pscustomobject]@{
        Value = $lock.generator_inputs
        Name = 'generator_inputs'
        Minimum = 1
        Maximum = $script:MaximumInputs
    },
    [pscustomobject]@{
        Value = $lock.notices
        Name = 'notices'
        Minimum = 1
        Maximum = $script:MaximumNotices
    },
    [pscustomobject]@{
        Value = $lock.outputs
        Name = 'outputs'
        Minimum = 1
        Maximum = $script:MaximumOutputs
    }
)) {
    if ($arrayMetadata.Value -isnot [Array] -or
        $arrayMetadata.Value.Count -lt $arrayMetadata.Minimum -or
        $arrayMetadata.Value.Count -gt $arrayMetadata.Maximum) {
        throw "$($arrayMetadata.Name) must be a bounded non-empty JSON array."
    }
}

$closurePath = Get-ContainedPath $metadataRootPath `
    $lock.component.closure_manifest.relative_path 'component closure link'
if ($lock.component.closure_manifest.relative_path -cnotmatch '\.json$') {
    throw 'Component closure link must identify a JSON file.'
}
Assert-ContainedPathHasNoReparsePoint $metadataRootPath `
    $lock.component.closure_manifest.relative_path 'component closure link'
if (-not (Test-Path -LiteralPath $closurePath -PathType Leaf)) {
    throw "Component closure manifest not found: $closurePath"
}
if ((Get-Item -LiteralPath $closurePath).Length -gt 1048576) {
    throw 'Component closure manifest exceeds the size bound.'
}
$closureSnapshot = Read-StrictJsonSnapshot -Path $closurePath `
    -Name 'component closure' -MaximumBytes 1048576
$closureHash = $closureSnapshot.Sha256
if ($closureHash -cne $lock.component.closure_manifest.sha256) {
    throw 'Component closure manifest SHA-256 mismatch.'
}
$closure = $closureSnapshot.Value
Assert-ExactProperties $closure @(
    '_spdx', 'schema', 'status', 'reason', 'upstream_name', 'owning_commit',
    'source_prefixes', 'notices', 'files'
) 'component closure root'
if ($closure._spdx -isnot [string] -or $closure._spdx -cne 'GPL-3.0-only' -or
    (Assert-UnsignedInteger $closure.schema 'component closure schema') -ne 1) {
    throw 'Unsupported component closure schema.'
}
if ($closure.status -isnot [string] -or $closure.status -cne 'ready' -or
    $closure.reason -isnot [string] -or $closure.reason.Length -ne 0) {
    throw 'Component closure is not ready for generated output.'
}
if ($closure.upstream_name -isnot [string] -or
    $closure.upstream_name -cne $lock.component.upstream_name) {
    throw 'Component closure upstream identity mismatch.'
}
if ($closure.owning_commit -isnot [string] -or
    $closure.owning_commit -cne $lock.component.owning_commit) {
    throw 'Component closure owning commit mismatch.'
}
if ($closure.source_prefixes -isnot [Array] -or
    $closure.notices -isnot [Array] -or $closure.files -isnot [Array] -or
    $closure.source_prefixes.Count -eq 0 -or
    $closure.notices.Count -eq 0 -or $closure.files.Count -eq 0 -or
    $closure.source_prefixes.Count -gt 64 -or
    $closure.notices.Count -gt $script:MaximumNotices -or
    $closure.files.Count -gt $script:MaximumInputs) {
    throw 'Component closure has invalid bounded arrays.'
}

$closurePrefixesById = [Collections.Generic.Dictionary[string,object]]::new(
    [StringComparer]::Ordinal
)
foreach ($prefix in $closure.source_prefixes) {
    Assert-ExactProperties $prefix @('id', 'relative_path', 'mode') 'component closure prefix'
    Assert-Identifier $prefix.id 'component closure prefix id'
    if ($closurePrefixesById.ContainsKey($prefix.id) -or
        $prefix.mode -isnot [string] -or
        @('subtree', 'exact-root-files') -cnotcontains $prefix.mode) {
        throw 'Component closure has invalid or duplicate source prefixes.'
    }
    if ($prefix.mode -ceq 'exact-root-files') {
        if ($prefix.relative_path -isnot [string] -or $prefix.relative_path -cne '.') {
            throw 'Component closure exact-root-files prefix must use dot.'
        }
    }
    else {
        Assert-SafeRelativePath $prefix.relative_path 'component closure prefix'
    }
    $closurePrefixesById.Add($prefix.id, $prefix)
}

$closureNoticesById = [Collections.Generic.Dictionary[string,object]]::new(
    [StringComparer]::Ordinal
)
$closureSeenPaths = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase
)
$closureUsedNoticeIds = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
)
$closureUsedPrefixIds = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
)
[UInt64]$closureAggregateBytes = 0
$closureNoticePaths = @($closure.notices)
Assert-PortablePathSet $closureNoticePaths 'component closure notices'
foreach ($notice in $closure.notices) {
    Assert-NoticeRow $notice 'component closure notice'
    if ($closureNoticesById.ContainsKey($notice.id) -or
        -not $closureSeenPaths.Add($notice.relative_path)) {
        throw "Duplicate component closure notice id '$($notice.id)'."
    }
    $noticeBytes = Assert-UnsignedInteger $notice.bytes 'component closure notice bytes'
    if ([UInt64]::MaxValue - $closureAggregateBytes -lt $noticeBytes -or
        $closureAggregateBytes + $noticeBytes -gt $script:MaximumAggregateSourceBytes) {
        throw 'Component closure exceeds the aggregate source-byte bound.'
    }
    $closureAggregateBytes += $noticeBytes
    $closureNoticesById.Add($notice.id, $notice)
}
$closureFilesByPath = [Collections.Generic.Dictionary[string,object]]::new(
    [StringComparer]::Ordinal
)
Assert-PortablePathSet @($closure.files) 'component closure files'
foreach ($file in $closure.files) {
    Assert-ClosureFileRow $file 'component closure file'
    if ($closureFilesByPath.ContainsKey($file.relative_path) -or
        -not $closureSeenPaths.Add($file.relative_path) -or
        -not $closurePrefixesById.ContainsKey($file.source_prefix_id) -or
        -not $closureNoticesById.ContainsKey($file.notice_id) -or
        $closureNoticesById[$file.notice_id].license_expression -cne
            $file.license_expression) {
        throw "Invalid component closure binding for '$($file.relative_path)'."
    }
    $prefix = $closurePrefixesById[$file.source_prefix_id]
    if ($prefix.mode -ceq 'exact-root-files') {
        if ($file.relative_path.Contains('/')) {
            throw "Component closure file '$($file.relative_path)' escapes its exact-root prefix."
        }
    }
    elseif (-not $file.relative_path.StartsWith(
            "$($prefix.relative_path)/",
            [StringComparison]::Ordinal
        )) {
        throw "Component closure file '$($file.relative_path)' escapes its source prefix."
    }
    [void]$closureUsedNoticeIds.Add($file.notice_id)
    [void]$closureUsedPrefixIds.Add($file.source_prefix_id)
    $fileBytes = Assert-UnsignedInteger $file.bytes 'component closure file bytes'
    if ([UInt64]::MaxValue - $closureAggregateBytes -lt $fileBytes -or
        $closureAggregateBytes + $fileBytes -gt $script:MaximumAggregateSourceBytes) {
        throw 'Component closure exceeds the aggregate source-byte bound.'
    }
    $closureAggregateBytes += $fileBytes
    $closureFilesByPath.Add($file.relative_path, $file)
}
if ($closureUsedNoticeIds.Count -ne $closureNoticesById.Count -or
    $closureUsedPrefixIds.Count -ne $closurePrefixesById.Count) {
    throw 'Ready component closure has an unused notice or source prefix.'
}

$checkout = Get-ContainedPath $sourceRootPath $lock.component.source_directory `
    'component source directory'
Assert-ContainedPathHasNoReparsePoint $sourceRootPath `
    $lock.component.source_directory 'component source directory'
if (-not (Test-Path -LiteralPath $checkout -PathType Container)) {
    throw "Component checkout not found: $checkout"
}
$head = @(Invoke-GitLines $checkout @('rev-parse', 'HEAD'))
if ($head.Count -ne 1 -or $head[0] -cne $lock.component.owning_commit) {
    throw 'Component checkout HEAD does not match the owning commit.'
}
$origin = @(Invoke-GitLines $checkout @('remote', 'get-url', 'origin'))
if ($origin.Count -ne 1 -or $origin[0] -cne $lock.component.repository) {
    throw 'Component checkout origin does not match the locked repository.'
}
$dirty = @(Invoke-GitLines $checkout @('status', '--porcelain=v1', '--untracked-files=all'))
if ($dirty.Count -ne 0) {
    throw 'Component checkout has local changes.'
}

$componentClosureVerifier = Join-Path $PSScriptRoot `
    'verify-win98-component-closure.ps1'
if (-not (Test-Path -LiteralPath $componentClosureVerifier -PathType Leaf)) {
    throw "Canonical component-closure verifier not found: $componentClosureVerifier"
}
& $componentClosureVerifier -SourceRoot $sourceRootPath `
    -LockFile $upstreamLockPath `
    -SourceName ([string[]]@($lock.component.upstream_name)) | Out-Null

$inputs = @($lock.generator_inputs)
Assert-PortablePathSet $inputs 'generator inputs'
$previousInputPath = $null
foreach ($input in $inputs) {
    Assert-ClosureFileRow $input 'generator input'
    if ($null -ne $previousInputPath -and
        [StringComparer]::Ordinal.Compare($previousInputPath, $input.relative_path) -ge 0) {
        throw 'Generator inputs must be in strict ordinal path order.'
    }
    $previousInputPath = [string]$input.relative_path
    if (-not $closureFilesByPath.ContainsKey($input.relative_path) -or
        -not (Test-RowsEqual $input $closureFilesByPath[$input.relative_path] @(
            'relative_path', 'git_blob', 'bytes', 'sha256', 'license_expression',
            'notice_id', 'source_prefix_id', 'role'
        ))) {
        throw "Generator input '$($input.relative_path)' does not exactly match its component closure row."
    }
    $pathspec = ":(top,literal)$($input.relative_path)"
    $tree = @(Invoke-GitLines $checkout @(
        'ls-tree', $lock.component.owning_commit, '--', $pathspec
    ))
    if ($tree.Count -ne 1 -or
        $tree[0] -notmatch '^(?<mode>[0-9]{6}) blob (?<hash>[0-9a-f]{40})\t(?<path>.+)$' -or
        $Matches.mode -notin @('100644', '100755') -or
        $Matches.hash -cne $input.git_blob -or
        $Matches.path -cne $input.relative_path) {
        throw "Generator input '$($input.relative_path)' is not the exact locked regular Git blob."
    }
    $blob = Get-GitBlobDigest $checkout $input.git_blob `
        ([UInt64]$input.bytes)
    $inputBytes = Assert-UnsignedInteger $input.bytes 'generator input bytes'
    if ($blob.Bytes -ne $inputBytes -or $blob.Sha256 -cne $input.sha256) {
        throw "Generator input '$($input.relative_path)' content mismatch."
    }
}

$notices = @($lock.notices)
Assert-PortablePathSet $notices 'generated-output notices'
$noticesById = [Collections.Generic.Dictionary[string,object]]::new(
    [StringComparer]::Ordinal
)
$previousNoticeId = $null
foreach ($notice in $notices) {
    Assert-NoticeRow $notice 'generated-output notice'
    if ($null -ne $previousNoticeId -and
        [StringComparer]::Ordinal.Compare($previousNoticeId, $notice.id) -ge 0) {
        throw 'Generated-output notices must be in strict ordinal id order.'
    }
    $previousNoticeId = [string]$notice.id
    if ($noticesById.ContainsKey($notice.id) -or
        -not $closureNoticesById.ContainsKey($notice.id) -or
        -not (Test-RowsEqual $notice $closureNoticesById[$notice.id] @(
            'id', 'relative_path', 'git_blob', 'bytes', 'sha256', 'license_expression'
        ))) {
        throw "Generated-output notice '$($notice.id)' does not exactly match its component closure row."
    }
    $noticesById.Add($notice.id, $notice)
    $pathspec = ":(top,literal)$($notice.relative_path)"
    $tree = @(Invoke-GitLines $checkout @(
        'ls-tree', $lock.component.owning_commit, '--', $pathspec
    ))
    if ($tree.Count -ne 1 -or
        $tree[0] -notmatch '^(?<mode>[0-9]{6}) blob (?<hash>[0-9a-f]{40})\t(?<path>.+)$' -or
        $Matches.mode -notin @('100644', '100755') -or
        $Matches.hash -cne $notice.git_blob -or
        $Matches.path -cne $notice.relative_path) {
        throw "Generated-output notice '$($notice.id)' is not the exact locked regular Git blob."
    }
    $blob = Get-GitBlobDigest $checkout $notice.git_blob `
        ([UInt64]$notice.bytes)
    $noticeBytes = Assert-UnsignedInteger $notice.bytes 'generated-output notice bytes'
    if ($blob.Bytes -ne $noticeBytes -or $blob.Sha256 -cne $notice.sha256) {
        throw "Generated-output notice '$($notice.id)' content mismatch."
    }
}

$outputs = @($lock.outputs)
Assert-PortablePathSet $outputs 'generated outputs'
$outputsByPath = [Collections.Generic.Dictionary[string,object]]::new(
    [StringComparer]::Ordinal
)
$usedNoticeIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$expectedDirectories = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$previousOutputPath = $null
foreach ($output in $outputs) {
    Assert-ExactProperties $output @(
        'relative_path', 'bytes', 'sha256', 'license_expression', 'notice_id'
    ) 'generated output'
    Assert-SafeRelativePath $output.relative_path 'generated output'
    if ($null -ne $previousOutputPath -and
        [StringComparer]::Ordinal.Compare($previousOutputPath, $output.relative_path) -ge 0) {
        throw 'Generated outputs must be in strict ordinal path order.'
    }
    $previousOutputPath = [string]$output.relative_path
    $outputBytes = Assert-UnsignedInteger $output.bytes 'generated output bytes'
    Assert-LowercaseHash $output.sha256 64 'generated output sha256'
    Assert-Identifier $output.notice_id 'generated output notice_id'
    if ($outputBytes -gt $script:MaximumOutputFileBytes -or
        $output.license_expression -isnot [string] -or
        -not $script:AllowedLicenses.Contains($output.license_expression) -or
        -not $noticesById.ContainsKey($output.notice_id) -or
        $noticesById[$output.notice_id].license_expression -cne
            $output.license_expression) {
        throw "Invalid license or notice binding for generated output '$($output.relative_path)'."
    }
    [void]$usedNoticeIds.Add($output.notice_id)
    $outputsByPath.Add($output.relative_path, [pscustomobject]@{
        Bytes = $outputBytes
        Sha256 = [string]$output.sha256
    })
    $parts = $output.relative_path.Split('/')
    for ($count = 1; $count -lt $parts.Count; $count++) {
        [void]$expectedDirectories.Add([string]::Join('/', $parts[0..($count - 1)]))
    }
}
if ($usedNoticeIds.Count -ne $noticesById.Count) {
    throw 'Generated-output lock contains an unused notice.'
}

Assert-ExactProperties $lock.output_tree @(
    'file_count', 'directory_count', 'total_entries', 'aggregate_bytes',
    'maximum_file_bytes', 'maximum_path_bytes', 'digest_algorithm', 'sha256'
) 'output_tree'
if ($lock.output_tree.digest_algorithm -isnot [string] -or
    $lock.output_tree.digest_algorithm -cne 'retvrn99-file-tree-sha256-v1') {
    throw "Unsupported output tree digest '$($lock.output_tree.digest_algorithm)'."
}
Assert-LowercaseHash $lock.output_tree.sha256 64 'output_tree sha256'
$expectedTree = [pscustomobject]@{
    FileCount = Assert-UnsignedInteger $lock.output_tree.file_count 'output_tree file_count'
    DirectoryCount = Assert-UnsignedInteger $lock.output_tree.directory_count `
        'output_tree directory_count'
    TotalEntries = Assert-UnsignedInteger $lock.output_tree.total_entries `
        'output_tree total_entries'
    AggregateBytes = Assert-UnsignedInteger $lock.output_tree.aggregate_bytes `
        'output_tree aggregate_bytes'
    MaximumFileBytes = Assert-UnsignedInteger $lock.output_tree.maximum_file_bytes `
        'output_tree maximum_file_bytes'
    MaximumPathBytes = Assert-UnsignedInteger $lock.output_tree.maximum_path_bytes `
        'output_tree maximum_path_bytes'
    Sha256 = [string]$lock.output_tree.sha256
}
if ($expectedTree.FileCount -ne $outputs.Count -or
    $expectedTree.DirectoryCount -ne $expectedDirectories.Count -or
    $expectedTree.TotalEntries -ne
        $expectedTree.FileCount + $expectedTree.DirectoryCount -or
    $expectedTree.FileCount -gt $script:MaximumOutputs -or
    $expectedTree.DirectoryCount -gt $script:MaximumDirectories -or
    $expectedTree.TotalEntries -gt $script:MaximumEntries -or
    $expectedTree.AggregateBytes -gt $script:MaximumAggregateOutputBytes -or
    $expectedTree.MaximumFileBytes -gt $script:MaximumOutputFileBytes -or
    $expectedTree.MaximumPathBytes -gt $script:MaximumPathBytes) {
    throw 'Output tree metadata violates the declared output set or hard bounds.'
}

foreach ($path in $outputsByPath.Keys) {
    $outputPath = Get-ContainedPath $generatedRootPath $path 'generated output'
    Assert-ContainedPathHasNoReparsePoint $generatedRootPath $path 'generated output'
    if (-not (Test-Path -LiteralPath $outputPath)) {
        throw "Generated output '$path' is missing."
    }
    $outputItem = Get-Item -LiteralPath $outputPath -Force
    if ($outputItem -isnot [IO.FileInfo] -or
        ($outputItem.Attributes -band [IO.FileAttributes]::Device) -ne 0) {
        throw "Generated output '$path' is not a regular file."
    }
}

$firstTree = Get-GeneratedTreeDescriptor $generatedRootPath
if ($firstTree.Records.Count -ne $outputsByPath.Count) {
    throw 'Generated tree contains missing or unpinned output files.'
}
foreach ($path in $firstTree.Records.Keys) {
    if (-not $outputsByPath.ContainsKey($path)) {
        throw "Generated tree contains unpinned output '$path'."
    }
    if ($firstTree.Records[$path].Bytes -ne $outputsByPath[$path].Bytes -or
        $firstTree.Records[$path].Sha256 -cne $outputsByPath[$path].Sha256) {
        throw "Generated output '$path' content mismatch."
    }
}
foreach ($path in $outputsByPath.Keys) {
    if (-not $firstTree.Records.ContainsKey($path)) {
        throw "Generated output '$path' is missing."
    }
}
if ($firstTree.Directories.Count -ne $expectedDirectories.Count) {
    throw 'Generated tree contains missing or unpinned directories.'
}
foreach ($directory in $firstTree.Directories) {
    if (-not $expectedDirectories.Contains($directory)) {
        throw "Generated tree contains unpinned directory '$directory'."
    }
}
Assert-DescriptorMatches $firstTree $expectedTree 'Output tree'

if ($null -ne $BeforeFinalCheckoutCheck) {
    & $BeforeFinalCheckoutCheck
}

foreach ($requiredDirectory in @(
    [pscustomobject]@{ Path = $sourceRootPath; Name = 'Source root' },
    [pscustomobject]@{ Path = $generatedRootPath; Name = 'Generated root' },
    [pscustomobject]@{ Path = $metadataRootPath; Name = 'Metadata root' },
    [pscustomobject]@{ Path = $checkout; Name = 'Component checkout' }
)) {
    if (-not (Test-Path -LiteralPath $requiredDirectory.Path -PathType Container)) {
        throw "$($requiredDirectory.Name) changed during generated-output verification."
    }
    Assert-NoReparseAncestor $requiredDirectory.Path $requiredDirectory.Name
}
foreach ($requiredFile in @(
    [pscustomobject]@{ Path = $lockPath; Name = 'Generated-output lock' },
    [pscustomobject]@{ Path = $upstreamLockPath; Name = 'Authoritative upstream lock' },
    [pscustomobject]@{ Path = $closurePath; Name = 'Component closure manifest' }
)) {
    if (-not (Test-Path -LiteralPath $requiredFile.Path -PathType Leaf)) {
        throw "$($requiredFile.Name) changed during generated-output verification."
    }
    Assert-NoReparseAncestor $requiredFile.Path $requiredFile.Name
}
Assert-ContainedPathHasNoReparsePoint $metadataRootPath `
    $lock.component.closure_manifest.relative_path 'component closure link'
Assert-ContainedPathHasNoReparsePoint $sourceRootPath `
    $lock.component.source_directory 'component source directory'

$secondTree = Get-GeneratedTreeDescriptor $generatedRootPath
Assert-DescriptorMatches $secondTree $firstTree 'Generated tree stability'
try {
    $finalClosureSnapshot = Read-GswBoundedFileSnapshot -Path $closurePath `
        -Name 'component closure manifest' -MaximumBytes 1048576
}
catch {
    throw "Component closure manifest changed during verification: $($_.Exception.Message)"
}
if ($finalClosureSnapshot.Sha256 -cne $closureHash) {
    throw 'Component closure manifest changed during verification.'
}
try {
    $finalLockSnapshot = Read-GswBoundedFileSnapshot -Path $lockPath `
        -Name 'generated-output lock' -MaximumBytes 4194304
}
catch {
    throw "Generated-output lock changed during verification: $($_.Exception.Message)"
}
if ($finalLockSnapshot.Sha256 -cne $initialLockHash) {
    throw 'Generated-output lock changed during verification.'
}
try {
    $finalUpstreamLockSnapshot = Read-GswBoundedFileSnapshot -Path $upstreamLockPath `
        -Name 'authoritative upstream lock' -MaximumBytes 1048576
}
catch {
    throw "Authoritative upstream lock changed during verification: $($_.Exception.Message)"
}
if ($finalUpstreamLockSnapshot.Sha256 -cne $initialUpstreamLockHash) {
    throw 'Authoritative upstream lock changed during verification.'
}
$finalHead = @(Invoke-GitLines $checkout @('rev-parse', 'HEAD'))
$finalOrigin = @(Invoke-GitLines $checkout @('remote', 'get-url', 'origin'))
$finalDirty = @(Invoke-GitLines $checkout @(
    'status', '--porcelain=v1', '--untracked-files=all'
))
if ($finalHead.Count -ne 1 -or
    $finalHead[0] -cne $lock.component.owning_commit -or
    $finalOrigin.Count -ne 1 -or
    $finalOrigin[0] -cne $lock.component.repository -or
    $finalDirty.Count -ne 0) {
    throw 'Component checkout changed during generated-output verification.'
}

Write-Output (
    "Verified generated-output lock '{0}' with {1} generator inputs and {2} outputs." -f `
        $lock.component.component_id, $inputs.Count, $outputs.Count
)
