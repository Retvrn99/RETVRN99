# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [string]$SourceRoot,
    [string]$ProfileFile,
    [switch]$PolicyAudit,
    [scriptblock]$BeforeFinalMetadataCheck
)

Set-StrictMode -Version Latest

$script:MesaSeedMaximumDefinitionBytes = [UInt64]131072
$script:MesaSeedMaximumDefinitionLines = 4096
$script:MesaSeedMaximumLineBytes = 4096
$script:MesaSeedMaximumEntries = 1000
$script:MesaSeedMaximumPathBytes = 512
$script:MesaSeedMaximumJsonBytes = [UInt64]131072
$script:MesaSeedMaximumCandidateBytes = [UInt64](16 * 1024 * 1024)
$script:MesaSeedExpectedSchemaSha256 = `
    '987a11af8aecbbbb509adf4419e42b29e2f5ca9ae324b1bb05ed34cac5d1f884'

. (Join-Path $PSScriptRoot 'strict-json.ps1')

function Get-MesaSeedFullPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }
    return [IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

function Get-MesaSeedPathEntry {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = Get-MesaSeedFullPath $Path
    $parent = Split-Path -Parent $fullPath
    if ([string]::IsNullOrWhiteSpace($parent) -or
        $parent.Equals($fullPath, [StringComparison]::OrdinalIgnoreCase)) {
        try {
            $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
            return [pscustomobject]@{
                Path = $item.FullName
                Attributes = $item.Attributes
            }
        }
        catch [Management.Automation.ItemNotFoundException] {
            return $null
        }
    }
    $leaf = Split-Path -Leaf $fullPath
    try {
        foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries(
                $parent,
                $leaf,
                [IO.SearchOption]::TopDirectoryOnly
            )) {
            $entryPath = [IO.Path]::GetFullPath($entry)
            if ($entryPath.Equals($fullPath, [StringComparison]::OrdinalIgnoreCase)) {
                return [pscustomobject]@{
                    Path = $entryPath
                    Attributes = [IO.File]::GetAttributes($entryPath)
                }
            }
        }
    }
    catch [IO.DirectoryNotFoundException] {
        return $null
    }
    catch [IO.FileNotFoundException] {
        return $null
    }
    return $null
}

function Assert-MesaSeedNoReparseAncestor {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $current = Get-MesaSeedFullPath $Path
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        $entry = Get-MesaSeedPathEntry $current
        if ($null -ne $entry) {
            if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
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

function Assert-MesaSeedSafeRelativePath {
    param(
        [Parameter(Mandatory = $true)][object]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$AllowDirectory
    )

    if ($RelativePath -isnot [string] -or
        [string]::IsNullOrWhiteSpace($RelativePath) -or
        [IO.Path]::IsPathRooted($RelativePath) -or
        $RelativePath.Contains('\') -or
        [Text.Encoding]::UTF8.GetByteCount($RelativePath) -gt
            $script:MesaSeedMaximumPathBytes) {
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
    if (-not $AllowDirectory -and $RelativePath.EndsWith('/')) {
        throw "Unsafe file path '$RelativePath' in $Name."
    }
}

function Get-MesaSeedContainedPath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][object]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$AllowDirectory
    )

    Assert-MesaSeedSafeRelativePath $RelativePath $Name -AllowDirectory:$AllowDirectory
    $rootPath = Get-MesaSeedFullPath $Root
    $rootPrefix = $rootPath.TrimEnd([char[]]'\/') + [IO.Path]::DirectorySeparatorChar
    $candidate = [IO.Path]::GetFullPath((Join-Path $rootPath (
        $RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)
    )))
    if (-not $candidate.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Name escapes its declared root."
    }
    return $candidate
}

function Assert-MesaSeedContainedPathNoReparse {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $current = Get-MesaSeedFullPath $Root
    foreach ($component in $RelativePath.Split('/')) {
        $current = Join-Path $current $component
        $entry = Get-MesaSeedPathEntry $current
        if ($null -ne $entry) {
            if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "$Name crosses reparse point '$current'."
            }
        }
    }
}

function Assert-MesaSeedContainedPathsNoReparse {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string[]]$RelativePaths,
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$RequireRegularLeaves
    )

    if ($RelativePaths.Count -eq 0 -or
        $RelativePaths.Count -gt $script:MesaSeedMaximumEntries + 64) {
        throw "$Name exceeds its path-count bound."
    }
    $checked = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $rootPath = Get-MesaSeedFullPath $Root
    foreach ($relativePath in $RelativePaths) {
        Assert-MesaSeedSafeRelativePath $relativePath $Name
        $current = $rootPath
        foreach ($component in $relativePath.Split('/')) {
            $current = Join-Path $current $component
            if (-not $checked.Add($current)) {
                continue
            }
            $entry = Get-MesaSeedPathEntry $current
            if ($null -eq $entry) {
                continue
            }
            if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "$Name crosses reparse point '$current'."
            }
        }
        if ($RequireRegularLeaves) {
            Assert-MesaSeedRegularBoundedFile $current `
                "$Name '$relativePath'" $script:MesaSeedMaximumCandidateBytes
        }
    }
}

function Invoke-MesaSeedGitLines {
    param(
        [Parameter(Mandatory = $true)][string]$Checkout,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Get-MesaSeedGitExecutable
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($gitVariable in @(
        'GIT_CEILING_DIRECTORIES', 'GIT_DIR', 'GIT_WORK_TREE',
        'GIT_PREFIX', 'GIT_INDEX_FILE'
    )) {
        $startInfo.EnvironmentVariables.Remove($gitVariable)
    }
    $startInfo.Arguments = (@(
        '-c', 'core.quotePath=false', '-C', $Checkout
    ) + $Arguments | ForEach-Object {
        ConvertTo-MesaSeedProcessArgument ([string]$_)
    }) -join ' '

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $started = $false
    try {
        if (-not $process.Start()) {
            throw "Unable to start git for '$Checkout'."
        }
        $started = $true
        $outputText = $process.StandardOutput.ReadToEnd()
        $errorText = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) {
            throw "git $($Arguments -join ' ') failed for '$Checkout': $errorText"
        }
        if ([Text.Encoding]::UTF8.GetByteCount($outputText) -gt 16777216) {
            throw "git $($Arguments -join ' ') output exceeds the size bound."
        }
        if ($outputText.Length -eq 0) {
            return @()
        }
        $normalized = $outputText.Replace("`r`n", "`n")
        if ($normalized.EndsWith("`n", [StringComparison]::Ordinal)) {
            $normalized = $normalized.Substring(0, $normalized.Length - 1)
        }
        if ($normalized.Length -eq 0) {
            return @()
        }
        return @($normalized.Split([char]10))
    }
    finally {
        if ($started -and -not $process.HasExited) {
            $process.Kill()
            $process.WaitForExit()
        }
        $process.Dispose()
    }
}

function Invoke-MesaSeedGitText {
    param(
        [Parameter(Mandatory = $true)][string]$Checkout,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    return (@(Invoke-MesaSeedGitLines $Checkout $Arguments) -join "`n").TrimEnd(
        [char[]]"`r`n"
    )
}

function Get-MesaSeedNormalizedRepository {
    param([Parameter(Mandatory = $true)][string]$Repository)

    $normalized = $Repository.Trim().TrimEnd('/')
    if ($normalized.EndsWith('.git', [StringComparison]::OrdinalIgnoreCase)) {
        $normalized = $normalized.Substring(0, $normalized.Length - 4)
    }
    return $normalized.ToLowerInvariant()
}

function Assert-MesaSeedGitCheckout {
    param(
        [Parameter(Mandatory = $true)][string]$Checkout,
        [Parameter(Mandatory = $true)][string]$ExpectedCommit,
        [Parameter(Mandatory = $true)][string]$ExpectedRepository
    )

    if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
        throw 'git is required for the Mesa source-list seed audit.'
    }
    $checkoutPath = Get-MesaSeedFullPath $Checkout
    Assert-MesaSeedNoReparseAncestor $checkoutPath 'Mesa checkout'
    if (-not (Test-Path -LiteralPath $checkoutPath -PathType Container)) {
        throw "Mesa checkout not found: $checkoutPath"
    }
    $root = Invoke-MesaSeedGitText $checkoutPath @('rev-parse', '--show-toplevel')
    if ((Get-MesaSeedFullPath $root) -cne $checkoutPath) {
        throw "Mesa checkout root mismatch: $root"
    }
    $head = Invoke-MesaSeedGitText $checkoutPath @('rev-parse', 'HEAD')
    if ($head -cne $ExpectedCommit) {
        throw "Mesa checkout is at $head, expected $ExpectedCommit."
    }
    $origin = Invoke-MesaSeedGitText $checkoutPath @('remote', 'get-url', 'origin')
    if ((Get-MesaSeedNormalizedRepository $origin) -cne
        (Get-MesaSeedNormalizedRepository $ExpectedRepository)) {
        throw "Mesa checkout has unexpected origin '$origin'."
    }
    $status = Invoke-MesaSeedGitText $checkoutPath @(
        'status', '--porcelain=v1', '--untracked-files=all', '--ignore-submodules=none'
    )
    if ($status.Length -ne 0) {
        throw 'Mesa checkout has local changes.'
    }
}

function ConvertTo-MesaSeedProcessArgument {
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

function Get-MesaSeedGitExecutable {
    $commands = @(Get-Command git -CommandType Application -ErrorAction Stop)
    if ($commands.Count -eq 0) {
        throw 'git is required for Mesa source-seed verification.'
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

function Get-MesaSeedGitBlob {
    param(
        [Parameter(Mandatory = $true)][string]$Checkout,
        [Parameter(Mandatory = $true)][string]$Blob
    )

    if ($Blob -cnotmatch '^[0-9a-f]{40}$') {
        throw "Invalid Mesa definition blob '$Blob'."
    }
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Get-MesaSeedGitExecutable
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($gitVariable in @(
        'GIT_CEILING_DIRECTORIES', 'GIT_DIR', 'GIT_WORK_TREE',
        'GIT_PREFIX', 'GIT_INDEX_FILE'
    )) {
        $startInfo.EnvironmentVariables.Remove($gitVariable)
    }
    $startInfo.Arguments = (@(
        '-C', $Checkout, 'cat-file', 'blob', $Blob
    ) | ForEach-Object { ConvertTo-MesaSeedProcessArgument $_ }) -join ' '

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $memory = [IO.MemoryStream]::new()
    $started = $false
    try {
        if (-not $process.Start()) {
            throw "Unable to start git cat-file for '$Blob'."
        }
        $started = $true
        $buffer = New-Object byte[] 16384
        while (($read = $process.StandardOutput.BaseStream.Read(
                    $buffer, 0, $buffer.Length
                )) -gt 0) {
            $memory.Write($buffer, 0, $read)
            if ([UInt64]$memory.Length -gt $script:MesaSeedMaximumDefinitionBytes) {
                throw "Mesa definition blob '$Blob' exceeds the size bound."
            }
        }
        $errorText = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) {
            throw "git cat-file failed for '$Blob': $errorText"
        }
        $bytes = $memory.ToArray()
        $digest = [Security.Cryptography.SHA256]::Create()
        try {
            $hash = $digest.ComputeHash($bytes)
        }
        finally {
            $digest.Dispose()
        }
        return [pscustomobject]@{
            Bytes = $bytes
            Length = [UInt64]$bytes.Length
            Sha256 = (([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant())
        }
    }
    finally {
        if ($started -and -not $process.HasExited) {
            $process.Kill()
            $process.WaitForExit()
        }
        $memory.Dispose()
        $process.Dispose()
    }
}

function ConvertFrom-MesaSeedUtf8 {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][string]$Name
    )

    try {
        $encoding = [Text.UTF8Encoding]::new($false, $true)
        $text = $encoding.GetString($Bytes)
    }
    catch {
        throw "$Name is not strict UTF-8: $($_.Exception.Message)"
    }
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xfeff) {
        throw "$Name must not contain a UTF-8 BOM."
    }
    return $text
}

function Read-MesaSeedAssignments {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$DefinitionFile,
        [Parameter(Mandatory = $true)][string[]]$VariableNames
    )

    if ($VariableNames.Count -eq 0 -or $VariableNames.Count -gt 16) {
        throw 'Mesa source variable selection exceeds its bound.'
    }
    $selected = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($name in $VariableNames) {
        if ($name -cnotmatch '^[A-Za-z][A-Za-z0-9_]*$' -or -not $selected.Add($name)) {
            throw "Invalid or duplicate Mesa source variable '$name'."
        }
    }
    if (-not $Text.EndsWith("`n", [StringComparison]::Ordinal)) {
        throw "Mesa definition '$DefinitionFile' must end with a newline."
    }
    $lines = $Text.Split([char]10)
    if ($lines.Count -gt $script:MesaSeedMaximumDefinitionLines + 1) {
        throw "Mesa definition '$DefinitionFile' exceeds the line-count bound."
    }

    $baseAssignments = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )
    $entries = [Collections.Generic.List[object]]::new()
    $active = $null
    foreach ($rawLine in $lines) {
        if ([Text.Encoding]::UTF8.GetByteCount($rawLine) -gt
            $script:MesaSeedMaximumLineBytes) {
            throw "Mesa definition '$DefinitionFile' exceeds the line-size bound."
        }
        $line = $rawLine
        if ($line.EndsWith("`r", [StringComparison]::Ordinal)) {
            $line = $line.Substring(0, $line.Length - 1)
        }
        if ($line.Contains("`r") -or $line -match '[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]') {
            throw "Mesa definition '$DefinitionFile' contains a forbidden control character."
        }

        if ($null -eq $active) {
            if ($line -notmatch '^([A-Za-z][A-Za-z0-9_]*)[ \t]*(\+?=)[ \t]*(.*)$') {
                continue
            }
            $variable = [string]$Matches[1]
            if (-not $selected.Contains($variable)) {
                continue
            }
            $operator = [string]$Matches[2]
            if ($operator -ceq '=') {
                if (-not $baseAssignments.Add($variable)) {
                    throw "Mesa source variable '$variable' has multiple base assignments."
                }
            }
            elseif (-not $baseAssignments.Contains($variable)) {
                throw "Mesa source variable '$variable' is extended before its base assignment."
            }
            $active = $variable
            $line = [string]$Matches[3]
        }

        $trimmedEnd = $line.TrimEnd([char[]]" `t")
        $continued = $trimmedEnd.EndsWith('\', [StringComparison]::Ordinal)
        if ($continued) {
            $value = $trimmedEnd.Substring(0, $trimmedEnd.Length - 1).Trim()
        }
        else {
            $value = $trimmedEnd.Trim()
        }
        if ($value.Length -gt 0) {
            if ($value.StartsWith('#', [StringComparison]::Ordinal)) {
                throw "Mesa source variable '$active' contains a comment in its assignment."
            }
            foreach ($token in @($value -split '[ \t]+')) {
                if ([string]::IsNullOrWhiteSpace($token)) {
                    continue
                }
                if ($token.StartsWith('$(MESA_VER)/', [StringComparison]::Ordinal)) {
                    $relativePath = 'mesa-23.1.x/' + $token.Substring(12)
                }
                elseif ($token.StartsWith('extra/', [StringComparison]::Ordinal) -or
                    $token.StartsWith('win9x/', [StringComparison]::Ordinal)) {
                    $relativePath = $token
                }
                else {
                    throw "Unsupported token '$token' in Mesa source variable '$active'."
                }
                Assert-MesaSeedSafeRelativePath $relativePath `
                    "Mesa source variable '$active'"
                $entries.Add([pscustomobject]@{
                    Variable = [string]$active
                    DefinitionFile = $DefinitionFile
                    RelativePath = [string]$relativePath
                })
                if ($entries.Count -gt $script:MesaSeedMaximumEntries) {
                    throw 'Mesa source-list seed exceeds its entry-count bound.'
                }
            }
        }
        if (-not $continued) {
            $active = $null
        }
    }
    if ($null -ne $active) {
        throw "Mesa source variable '$active' has an unterminated continuation."
    }
    foreach ($name in $VariableNames) {
        if (-not $baseAssignments.Contains($name)) {
            throw "Mesa source variable '$name' has no base assignment."
        }
    }
    return @($entries)
}

function Assert-MesaSeedDisabledConditionals {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$DefinitionFile,
        [Parameter(Mandatory = $true)][string[]]$VariableNames
    )

    $assignment = '  MesaLib_SRC += $(MESA_VER)/src/mapi/glapi/gen/glapi_x86.S'
    $lines = @($Text.Split([char]10) | ForEach-Object {
        if ($_.EndsWith("`r", [StringComparison]::Ordinal)) {
            $_.Substring(0, $_.Length - 1)
        }
        else {
            $_
        }
    })
    $observed = 0
    $selected = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($name in $VariableNames) {
        [void]$selected.Add($name)
    }
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $line = [string]$lines[$index]
        if ($line -notmatch '^[ \t]+(?<variable>[A-Za-z][A-Za-z0-9_]*)[ \t]+\+?=') {
            continue
        }
        if (-not $selected.Contains([string]$Matches.variable)) {
            continue
        }
        if ($line -cne $assignment -or $index -eq 0 -or
            $index + 1 -ge $lines.Count -or
            $lines[$index - 1] -cne 'ifdef USE_ASM' -or
            $lines[$index + 1] -cne 'endif') {
            throw "Mesa definition '$DefinitionFile' contains an undeclared conditional assignment for '$($Matches.variable)'."
        }
        $observed++
    }
    if ($observed -ne 1) {
        throw "Mesa definition '$DefinitionFile' must contain exactly one disabled USE_ASM assignment."
    }
}

function Get-MesaSeedTextSha256 {
    param([Parameter(Mandatory = $true)][string]$Text)

    $digest = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $digest.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes($Text))
    }
    finally {
        $digest.Dispose()
    }
    return (([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant())
}

function Get-MesaSeedAnalysis {
    param(
        [Parameter(Mandatory = $true)][object[]]$Entries,
        [Parameter(Mandatory = $true)][string]$ExpectedDuplicatePath,
        [Parameter(Mandatory = $true)][int]$ExpectedDuplicateOccurrences
    )

    if ($Entries.Count -eq 0 -or $Entries.Count -gt $script:MesaSeedMaximumEntries) {
        throw 'Mesa source-list seed has an invalid entry count.'
    }
    $counts = [Collections.Generic.Dictionary[string,int]]::new(
        [StringComparer]::Ordinal
    )
    $occurrences = [Collections.Generic.List[string]]::new()
    foreach ($entry in $Entries) {
        $path = [string]$entry.RelativePath
        Assert-MesaSeedSafeRelativePath $path 'Mesa source-list seed'
        $occurrences.Add($path)
        if ($counts.ContainsKey($path)) {
            $counts[$path]++
        }
        else {
            $counts.Add($path, 1)
        }
    }
    $duplicates = [Collections.Generic.List[string]]::new()
    foreach ($pair in $counts.GetEnumerator()) {
        if ($pair.Value -gt 1) {
            $duplicates.Add($pair.Key)
        }
    }
    if ($duplicates.Count -ne 1 -or
        $duplicates[0] -cne $ExpectedDuplicatePath -or
        $counts[$ExpectedDuplicatePath] -ne $ExpectedDuplicateOccurrences) {
        throw 'Mesa source-list seed contains an unexpected duplicate.'
    }

    $unique = [Collections.Generic.List[string]]::new()
    foreach ($path in $counts.Keys) {
        $unique.Add($path)
    }
    $unique.Sort([StringComparer]::Ordinal)
    $candidateText = [string]::Join("`n", $unique) + "`n"
    $occurrenceText = [string]::Join("`n", $occurrences) + "`n"
    return [pscustomobject]@{
        OccurrenceCount = $occurrences.Count
        UniqueCount = $unique.Count
        UniquePaths = @($unique)
        CandidateSetSha256 = Get-MesaSeedTextSha256 $candidateText
        OccurrenceSequenceSha256 = Get-MesaSeedTextSha256 $occurrenceText
    }
}

function Assert-MesaSeedRegularBoundedFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][UInt64]$MaximumBytes
    )

    Assert-MesaSeedNoReparseAncestor $Path $Name
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Name not found: $Path"
    }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        ($item.Attributes -band [IO.FileAttributes]::Device) -ne 0) {
        throw "$Name must be a regular file."
    }
    if ([UInt64]$item.Length -gt $MaximumBytes) {
        throw "$Name exceeds the $MaximumBytes-byte bound."
    }
}

function Read-MesaSeedJsonDocument {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    Assert-MesaSeedRegularBoundedFile $Path $Name $script:MesaSeedMaximumJsonBytes
    $before = Get-Item -LiteralPath $Path -Force
    $stream = [IO.FileStream]::new(
        $Path,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read
    )
    try {
        if ([UInt64]$stream.Length -ne [UInt64]$before.Length -or
            [UInt64]$stream.Length -gt $script:MesaSeedMaximumJsonBytes) {
            throw "$Name changed while it was opened."
        }
        $bytes = New-Object byte[] ([int]$stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -le 0) {
                throw "$Name ended before its declared length."
            }
            $offset += $read
        }
        if ($stream.ReadByte() -ne -1 -or
            [UInt64]$stream.Length -ne [UInt64]$before.Length) {
            throw "$Name changed while it was read."
        }
    }
    finally {
        $stream.Dispose()
    }
    Assert-MesaSeedRegularBoundedFile $Path $Name $script:MesaSeedMaximumJsonBytes
    $after = Get-Item -LiteralPath $Path -Force
    if ([UInt64]$after.Length -ne [UInt64]$before.Length) {
        throw "$Name changed during verification."
    }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and
        $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf) {
        throw "$Name must not contain a UTF-8 BOM."
    }
    try {
        $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    }
    catch {
        throw "$Name is not strict UTF-8: $($_.Exception.Message)"
    }
    $digest = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $digest.ComputeHash($bytes)
    }
    finally {
        $digest.Dispose()
    }
    try {
        $value = ConvertFrom-GswStrictJson -Json $text -Source $Path
    }
    catch {
        throw "Malformed $Name JSON: $($_.Exception.Message)"
    }
    return [pscustomobject]@{
        Value = $value
        Bytes = [UInt64]$bytes.Length
        Sha256 = (([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant())
    }
}

function Assert-MesaSeedExactProperties {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string[]]$Expected,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Value -or $Value -is [string] -or $Value -is [Array] -or
        $Value.GetType().IsValueType) {
        throw "$Name must be a JSON object."
    }
    Assert-GswJsonExactProperties $Value $Expected $Name
}

function Assert-MesaSeedExactString {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Value -isnot [string] -or $Value -cne $Expected) {
        throw "$Name must be '$Expected'."
    }
}

function Assert-MesaSeedBoundedString {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][int]$MaximumBytes,
        [switch]$NonEmpty
    )

    if ($Value -isnot [string] -or
        [Text.Encoding]::UTF8.GetByteCount($Value) -gt $MaximumBytes -or
        $Value -match '[\x00-\x08\x0a-\x1f\x7f-\x9f]' -or
        ($NonEmpty -and [string]::IsNullOrWhiteSpace($Value))) {
        throw "$Name must be a bounded JSON string."
    }
}

function Assert-MesaSeedExactInteger {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][UInt64]$Expected,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $types = @(
        [byte], [uint16], [uint32], [uint64],
        [sbyte], [int16], [int32], [int64]
    )
    if ($null -eq $Value -or $types -cnotcontains $Value.GetType()) {
        throw "$Name must be a JSON integer."
    }
    try {
        $actual = [UInt64]$Value
    }
    catch {
        throw "$Name must be a non-negative JSON integer."
    }
    if ($actual -ne $Expected) {
        throw "$Name must be $Expected."
    }
}

function Assert-MesaSeedFalse {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Value -isnot [bool] -or $Value) {
        throw "$Name must remain false."
    }
}

function Assert-MesaSeedTrue {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Value -isnot [bool] -or -not $Value) {
        throw "$Name must remain true."
    }
}

function Assert-MesaSeedArray {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][int]$Count,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Value -isnot [Array] -or $Value.Count -ne $Count) {
        throw "$Name must be a $Count-item JSON array."
    }
    return ,@($Value)
}

function Assert-MesaSeedExactStringSequence {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string[]]$Expected,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $actual = Assert-MesaSeedArray $Value $Expected.Count $Name
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        if ($actual[$index] -isnot [string] -or
            $actual[$index] -cne $Expected[$index]) {
            throw "$Name must contain only the canonical ordered values."
        }
    }
}

function Get-MesaSeedIndex {
    param([Parameter(Mandatory = $true)][string]$Checkout)

    $lines = @(Invoke-MesaSeedGitLines $Checkout @('ls-files', '--stage'))
    if ($lines.Count -gt 100000) {
        throw 'Mesa index exceeds the entry-count bound.'
    }
    $index = [Collections.Generic.Dictionary[string,object]]::new(
        [StringComparer]::Ordinal
    )
    foreach ($line in $lines) {
        if ([Text.Encoding]::UTF8.GetByteCount($line) -gt 2048 -or
            $line -notmatch '^(?<mode>[0-9]{6}) (?<blob>[0-9a-f]{40}) (?<stage>[0-3])\t(?<path>.+)$') {
            throw 'Mesa index contains an unsupported record.'
        }
        if ($Matches.stage -cne '0') {
            throw 'Mesa index contains an unmerged record.'
        }
        $path = [string]$Matches.path
        Assert-MesaSeedSafeRelativePath $path 'Mesa index' -AllowDirectory
        if ($index.ContainsKey($path)) {
            throw "Mesa index contains duplicate path '$path'."
        }
        $index.Add($path, [pscustomobject]@{
            Mode = [string]$Matches.mode
            Blob = [string]$Matches.blob
        })
    }
    return $index
}

function Assert-MesaSeedPathAbsent {
    param(
        [Parameter(Mandatory = $true)][string]$Checkout,
        [Parameter(Mandatory = $true)][object]$IndexRecords,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $path = Get-MesaSeedContainedPath $Checkout $RelativePath $Name
    Assert-MesaSeedContainedPathNoReparse $Checkout $RelativePath $Name
    if ($IndexRecords.ContainsKey($RelativePath) -or
        $null -ne (Get-MesaSeedPathEntry $path)) {
        throw "$Name '$RelativePath' unexpectedly exists."
    }
}

function Get-MesaSeedWorktreeBlobHashes {
    param(
        [Parameter(Mandatory = $true)][string]$Checkout,
        [Parameter(Mandatory = $true)][string[]]$RelativePaths,
        [switch]$NoFilters,
        [switch]$PathsValidated
    )

    if ($RelativePaths.Count -eq 0 -or
        $RelativePaths.Count -gt $script:MesaSeedMaximumEntries) {
        throw 'Mesa indexed-file hash request exceeds its entry-count bound.'
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($relativePath in $RelativePaths) {
        Assert-MesaSeedSafeRelativePath $relativePath 'Mesa indexed-file hash request'
        if (-not $seen.Add($relativePath)) {
            throw "Mesa indexed-file hash request repeats '$relativePath'."
        }
        if (-not $PathsValidated) {
            $path = Get-MesaSeedContainedPath $Checkout $relativePath `
                'Mesa indexed file'
            Assert-MesaSeedContainedPathNoReparse $Checkout $relativePath `
                'Mesa indexed file'
            Assert-MesaSeedRegularBoundedFile $path `
                "Mesa indexed file '$relativePath'" `
                $script:MesaSeedMaximumCandidateBytes
        }
    }

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Get-MesaSeedGitExecutable
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($gitVariable in @(
        'GIT_CEILING_DIRECTORIES', 'GIT_DIR', 'GIT_WORK_TREE',
        'GIT_PREFIX', 'GIT_INDEX_FILE'
    )) {
        $startInfo.EnvironmentVariables.Remove($gitVariable)
    }
    $arguments = @('-c', 'core.quotePath=false', '-C', $Checkout, 'hash-object')
    if ($NoFilters) {
        $arguments += '--no-filters'
    }
    $arguments += '--stdin-paths'
    $startInfo.Arguments = @($arguments | ForEach-Object {
        ConvertTo-MesaSeedProcessArgument ([string]$_)
    }) -join ' '

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $started = $false
    try {
        if (-not $process.Start()) {
            throw "Unable to start git hash-object for '$Checkout'."
        }
        $started = $true
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        foreach ($relativePath in $RelativePaths) {
            $process.StandardInput.WriteLine($relativePath)
        }
        $process.StandardInput.Close()
        $process.WaitForExit()
        $outputText = $outputTask.GetAwaiter().GetResult()
        $errorText = $errorTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "git hash-object failed for '$Checkout': $errorText"
        }
    }
    finally {
        if ($started -and -not $process.HasExited) {
            $process.Kill()
            $process.WaitForExit()
        }
        $process.Dispose()
    }
    $lines = @($outputText.Replace("`r`n", "`n").TrimEnd([char]10).Split([char]10))
    if ($lines.Count -ne $RelativePaths.Count) {
        throw 'git hash-object returned an unexpected result count.'
    }
    $hashes = [Collections.Generic.Dictionary[string,string]]::new(
        [StringComparer]::Ordinal
    )
    for ($index = 0; $index -lt $RelativePaths.Count; $index++) {
        if ($lines[$index] -cnotmatch '^[0-9a-f]{40}$') {
            throw 'git hash-object returned an invalid blob hash.'
        }
        $hashes.Add($RelativePaths[$index], [string]$lines[$index])
    }
    return $hashes
}

function Get-MesaSeedSafeAttributes {
    param(
        [Parameter(Mandatory = $true)][string]$Checkout,
        [Parameter(Mandatory = $true)][string[]]$RelativePaths,
        [switch]$Worktree
    )

    $attributeNames = @('filter', 'working-tree-encoding', 'ident', 'text')
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Get-MesaSeedGitExecutable
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($gitVariable in @(
        'GIT_CEILING_DIRECTORIES', 'GIT_DIR', 'GIT_WORK_TREE',
        'GIT_PREFIX', 'GIT_INDEX_FILE'
    )) {
        $startInfo.EnvironmentVariables.Remove($gitVariable)
    }
    $arguments = @(
        '-c', 'core.quotePath=false', '-C', $Checkout, 'check-attr'
    )
    if (-not $Worktree) {
        $arguments += '--cached'
    }
    $arguments += '-z'
    $arguments += $attributeNames
    $arguments += '--stdin'
    $startInfo.Arguments = @($arguments | ForEach-Object {
        ConvertTo-MesaSeedProcessArgument ([string]$_)
    }) -join ' '

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $started = $false
    try {
        if (-not $process.Start()) {
            throw "Unable to start git check-attr for '$Checkout'."
        }
        $started = $true
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        foreach ($relativePath in $RelativePaths) {
            $process.StandardInput.Write($relativePath)
            $process.StandardInput.Write([char]0)
        }
        $process.StandardInput.Close()
        $process.WaitForExit()
        $outputText = $outputTask.GetAwaiter().GetResult()
        $errorText = $errorTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "git check-attr failed for '$Checkout': $errorText"
        }
    }
    finally {
        if ($started -and -not $process.HasExited) {
            $process.Kill()
            $process.WaitForExit()
        }
        $process.Dispose()
    }

    $fields = @($outputText.Split([char]0))
    if ($fields.Count -ne ($RelativePaths.Count * $attributeNames.Count * 3 + 1) -or
        $fields[$fields.Count - 1].Length -ne 0) {
        throw 'git check-attr returned an unexpected result shape.'
    }
    $textAttributes = [Collections.Generic.Dictionary[string,string]]::new(
        [StringComparer]::Ordinal
    )
    $fieldIndex = 0
    foreach ($relativePath in $RelativePaths) {
        foreach ($attributeName in $attributeNames) {
            $observedPath = [string]$fields[$fieldIndex]
            $observedName = [string]$fields[$fieldIndex + 1]
            $observedValue = [string]$fields[$fieldIndex + 2]
            $fieldIndex += 3
            if ($observedPath -cne $relativePath -or
                $observedName -cne $attributeName) {
                throw 'git check-attr returned records out of canonical order.'
            }
            if ($attributeName -ne 'text' -and
                $observedValue -notin @('unspecified', 'unset')) {
                throw "Mesa source-list candidate '$relativePath' has unsafe Git attribute '$attributeName=$observedValue'."
            }
            if ($attributeName -ceq 'text') {
                $textAttributes.Add($relativePath, $observedValue)
            }
        }
    }
    return $textAttributes
}

function Assert-MesaSeedIndexedFiles {
    param(
        [Parameter(Mandatory = $true)][string]$Checkout,
        [Parameter(Mandatory = $true)][string[]]$RelativePaths,
        [Parameter(Mandatory = $true)][object]$IndexRecords,
        [switch]$PathsValidated
    )

    foreach ($relativePath in $RelativePaths) {
        if (-not $IndexRecords.ContainsKey($relativePath)) {
            throw "Tracked Mesa source-list candidate '$relativePath' is unavailable."
        }
        $record = $IndexRecords[$relativePath]
        if ($record.Mode -notin @('100644', '100755')) {
            throw "Tracked Mesa source-list candidate '$relativePath' is unavailable."
        }
    }
    $rawHashes = Get-MesaSeedWorktreeBlobHashes $Checkout $RelativePaths -NoFilters `
        -PathsValidated:$PathsValidated
    $normalizationPaths = @($RelativePaths | Where-Object {
        $rawHashes[$_] -cne $IndexRecords[$_].Blob
    })
    if ($normalizationPaths.Count -eq 0) {
        return
    }
    $attributes = Get-MesaSeedSafeAttributes $Checkout $normalizationPaths
    $worktreeAttributes = Get-MesaSeedSafeAttributes $Checkout $normalizationPaths `
        -Worktree
    foreach ($relativePath in $normalizationPaths) {
        if ($worktreeAttributes[$relativePath] -cne $attributes[$relativePath]) {
            throw "Mesa source-list candidate '$relativePath' has divergent cached and worktree attributes."
        }
        $mesaPath = $relativePath.StartsWith(
            'mesa-23.1.x/',
            [StringComparison]::Ordinal
        ) -and $attributes[$relativePath] -ceq 'auto'
        $win9xPath = (
            $relativePath.StartsWith('win9x/eight/', [StringComparison]::Ordinal) -or
            $relativePath.StartsWith('win9x/nine/', [StringComparison]::Ordinal)
        ) -and $attributes[$relativePath] -in @('auto', 'unspecified')
        if (-not $mesaPath -and -not $win9xPath) {
            throw "Tracked Mesa source-list candidate '$relativePath' requires an undeclared worktree normalization."
        }
    }
    $normalizedHashes = Get-MesaSeedWorktreeBlobHashes $Checkout `
        $normalizationPaths -PathsValidated:$PathsValidated
    $finalAttributes = Get-MesaSeedSafeAttributes $Checkout $normalizationPaths
    $finalWorktreeAttributes = Get-MesaSeedSafeAttributes $Checkout `
        $normalizationPaths -Worktree
    foreach ($relativePath in $normalizationPaths) {
        $record = $IndexRecords[$relativePath]
        if ($finalAttributes[$relativePath] -cne $attributes[$relativePath] -or
            $finalWorktreeAttributes[$relativePath] -cne $attributes[$relativePath] -or
            $normalizedHashes[$relativePath] -cne $record.Blob) {
            throw "Tracked Mesa source-list candidate '$relativePath' does not match indexed blob '$($record.Blob)'."
        }
    }
}

function Invoke-MesaSourceSeedVerification {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRootPath,
        [Parameter(Mandatory = $true)][string]$ProfilePath,
        [switch]$AuditPolicy,
        [scriptblock]$BeforeFinalMetadataCheck
    )

    $expectedDefinitions = @(
        [pscustomobject]@{
            RelativePath = 'mesa-23.1.x.mk'
            GitBlob = 'bd847297fc0c874480dec09bc1ce63442bdc5901'
            Bytes = [UInt64]58030
            Sha256 = 'a2bab2c9329df8cf8852247dd4cf3e786a7790f8b3350158c3be8fc3b2f060b8'
        },
        [pscustomobject]@{
            RelativePath = 'Makefile'
            GitBlob = 'fe49eb7abffefab98e6681fc97029b69204b35d0'
            Bytes = [UInt64]33844
            Sha256 = '7d578346607fe6dd3171b04d7b4eedc905a893df5094183c724e066e93e37d93'
        }
    )
    $expectedNormalization = [pscustomobject]@{
        RelativePath = 'mesa-23.1.x/.gitattributes'
        GitBlob = 'c0386978fadab6dc403690c4fd6b38433a8e9a4e'
        Bytes = [UInt64]79
        Sha256 = 'a560a09c4e6a6d5350465a615678e25fdf252669cb72569d1dd642b8f98bc180'
    }
    $expectedVariables = @(
        [pscustomobject]@{Name='MesaUtilLib_SRC'; DefinitionFile='mesa-23.1.x.mk'; Occurrences=78},
        [pscustomobject]@{Name='MesaLib_SRC'; DefinitionFile='mesa-23.1.x.mk'; Occurrences=519},
        [pscustomobject]@{Name='MesaWglLib_SRC'; DefinitionFile='mesa-23.1.x.mk'; Occurrences=18},
        [pscustomobject]@{Name='MesaGalliumAuxLib_SRC'; DefinitionFile='mesa-23.1.x.mk'; Occurrences=143},
        [pscustomobject]@{Name='MesaNineLib_SRC'; DefinitionFile='mesa-23.1.x.mk'; Occurrences=42},
        [pscustomobject]@{Name='MesaSVGALib_SRC'; DefinitionFile='mesa-23.1.x.mk'; Occurrences=59},
        [pscustomobject]@{Name='eight_SRC'; DefinitionFile='Makefile'; Occurrences=11}
    )
    $expectedForbiddenVariables = @('MesaSVGAWinsysLib_SRC', 'MesaGdiLib_SRC')
    $expectedNormalizationPrefixes = @(
        'mesa-23.1.x/', 'win9x/eight/', 'win9x/nine/'
    )
    $expectedForbiddenAttributes = @(
        'filter', 'working-tree-encoding', 'ident'
    )
    $expectedAbsentPaths = @(
        'mesa-23.1.x/src/compiler/glsl/glcpp/glcpp-lex.c',
        'mesa-23.1.x/src/compiler/glsl/glcpp/glcpp-parse.c',
        'mesa-23.1.x/src/compiler/glsl/glsl_lexer.cpp',
        'mesa-23.1.x/src/compiler/glsl/glsl_parser.cpp',
        'mesa-23.1.x/src/compiler/nir/nir_constant_expressions.c',
        'mesa-23.1.x/src/compiler/nir/nir_intrinsics.c',
        'mesa-23.1.x/src/compiler/nir/nir_opcodes.c',
        'mesa-23.1.x/src/compiler/nir/nir_opt_algebraic.c',
        'mesa-23.1.x/src/compiler/spirv/spirv_info.c',
        'mesa-23.1.x/src/compiler/spirv/vtn_gather_types.c',
        'mesa-23.1.x/src/gallium/auxiliary/driver_trace/tr_util.c',
        'mesa-23.1.x/src/gallium/auxiliary/indices/u_indices_gen.c',
        'mesa-23.1.x/src/gallium/auxiliary/indices/u_unfilled_gen.c',
        'mesa-23.1.x/src/mapi/glapi/enums.c',
        'mesa-23.1.x/src/mesa/main/api_exec_init.c',
        'mesa-23.1.x/src/mesa/main/format_fallback.c',
        'mesa-23.1.x/src/mesa/main/marshal_generated0.c',
        'mesa-23.1.x/src/mesa/main/marshal_generated1.c',
        'mesa-23.1.x/src/mesa/main/marshal_generated2.c',
        'mesa-23.1.x/src/mesa/main/marshal_generated3.c',
        'mesa-23.1.x/src/mesa/main/marshal_generated4.c',
        'mesa-23.1.x/src/mesa/main/marshal_generated5.c',
        'mesa-23.1.x/src/mesa/main/marshal_generated6.c',
        'mesa-23.1.x/src/mesa/main/marshal_generated7.c',
        'mesa-23.1.x/src/mesa/main/unmarshal_table.c',
        'mesa-23.1.x/src/mesa/program/lex.yy.c',
        'mesa-23.1.x/src/mesa/program/program_parse.tab.c',
        'mesa-23.1.x/src/util/format/u_format_table.c',
        'mesa-23.1.x/src/util/format_srgb.c'
    )
    $expectedBlockers = @(
        [pscustomobject]@{Path='include/git_sha1.h'; Relation='transitive-include-risk'; Disposition='original-replacement-required'},
        [pscustomobject]@{Path='win9x/nine/nine_memory_helper.c'; Relation='selected'; Disposition='original-replacement-required'},
        [pscustomobject]@{Path='extra/clock_gettime32.c'; Relation='selected'; Disposition='omit-unless-file-license-approved'},
        [pscustomobject]@{Path='mesa-23.1.x/src/gallium/auxiliary/postprocess/pp_mlaa.c'; Relation='selected'; Disposition='omit-unless-file-license-approved'},
        [pscustomobject]@{Path='win9x/wddm_screen.h'; Relation='transitive-include-risk'; Disposition='omit-from-private-gsw-build'},
        [pscustomobject]@{Path='include/winddk'; Relation='transitive-include-risk'; Disposition='omit-from-private-gsw-build'}
    )

    $resolvedProfile = Get-MesaSeedFullPath $ProfilePath
    $profileDocument = Read-MesaSeedJsonDocument $resolvedProfile `
        'Mesa source-list seed profile'
    $profile = $profileDocument.Value
    Assert-MesaSeedExactProperties $profile @(
        '_spdx', 'schema', 'schema_definition', 'status', 'reason', 'source',
        'selection', 'scope', 'blockers'
    ) 'Mesa source-list seed profile'
    Assert-MesaSeedExactString $profile._spdx 'GPL-3.0-only' '_spdx'
    Assert-MesaSeedExactInteger $profile.schema 1 'schema'
    Assert-MesaSeedExactProperties $profile.schema_definition @(
        'relative_path', 'sha256'
    ) 'schema_definition'
    Assert-MesaSeedExactString $profile.schema_definition.relative_path `
        'mesa-source-seed.schema.json' 'schema_definition.relative_path'
    Assert-MesaSeedExactString $profile.schema_definition.sha256 `
        $script:MesaSeedExpectedSchemaSha256 'schema_definition.sha256'

    $profileRoot = Split-Path -Parent $resolvedProfile
    $schemaPath = Get-MesaSeedContainedPath $profileRoot `
        $profile.schema_definition.relative_path 'Mesa source-list seed schema'
    $schemaDocument = Read-MesaSeedJsonDocument $schemaPath `
        'Mesa source-list seed schema'
    if ($schemaDocument.Sha256 -cne $script:MesaSeedExpectedSchemaSha256) {
        throw 'Mesa source-list seed schema hash mismatch.'
    }
    Assert-MesaSeedExactString $profile.status 'blocked' 'status'
    Assert-MesaSeedBoundedString $profile.reason 'reason' 1024 -NonEmpty

    Assert-MesaSeedExactProperties $profile.source @(
        'upstream_name', 'repository', 'owning_commit', 'mesa_version',
        'mesa_subtree', 'definition_files', 'normalization_file',
        'confirmed_absent_input'
    ) 'source'
    Assert-MesaSeedExactString $profile.source.upstream_name 'mesa9x' `
        'source.upstream_name'
    Assert-MesaSeedExactString $profile.source.repository `
        'https://github.com/JHRobotics/mesa9x.git' 'source.repository'
    Assert-MesaSeedExactString $profile.source.owning_commit `
        '29b9adb44bc5ea54dc53c02b5e4b49292c6cc04f' 'source.owning_commit'
    Assert-MesaSeedExactString $profile.source.mesa_version '23.1.9' `
        'source.mesa_version'
    Assert-MesaSeedExactString $profile.source.mesa_subtree 'mesa-23.1.x' `
        'source.mesa_subtree'
    Assert-MesaSeedExactString $profile.source.confirmed_absent_input `
        'mesa-23.1.x/Makefile.sources' 'source.confirmed_absent_input'
    $definitionRecords = Assert-MesaSeedArray $profile.source.definition_files 2 `
        'source.definition_files'
    for ($index = 0; $index -lt $expectedDefinitions.Count; $index++) {
        $record = $definitionRecords[$index]
        $expected = $expectedDefinitions[$index]
        Assert-MesaSeedExactProperties $record @(
            'relative_path', 'git_blob', 'bytes', 'sha256'
        ) "source.definition_files[$index]"
        Assert-MesaSeedExactString $record.relative_path $expected.RelativePath `
            "source.definition_files[$index].relative_path"
        Assert-MesaSeedExactString $record.git_blob $expected.GitBlob `
            "source.definition_files[$index].git_blob"
        Assert-MesaSeedExactInteger $record.bytes $expected.Bytes `
            "source.definition_files[$index].bytes"
        Assert-MesaSeedExactString $record.sha256 $expected.Sha256 `
            "source.definition_files[$index].sha256"
    }
    Assert-MesaSeedExactProperties $profile.source.normalization_file @(
        'relative_path', 'git_blob', 'bytes', 'sha256'
    ) 'source.normalization_file'
    Assert-MesaSeedExactString $profile.source.normalization_file.relative_path `
        $expectedNormalization.RelativePath 'source.normalization_file.relative_path'
    Assert-MesaSeedExactString $profile.source.normalization_file.git_blob `
        $expectedNormalization.GitBlob 'source.normalization_file.git_blob'
    Assert-MesaSeedExactInteger $profile.source.normalization_file.bytes `
        $expectedNormalization.Bytes 'source.normalization_file.bytes'
    Assert-MesaSeedExactString $profile.source.normalization_file.sha256 `
        $expectedNormalization.Sha256 'source.normalization_file.sha256'

    Assert-MesaSeedExactProperties $profile.selection @(
        'variables', 'forbidden_variables', 'disabled_conditionals',
        'normalization', 'worktree_normalization', 'occurrence_count',
        'unique_count', 'tracked_present_count', 'generated_absent_count',
        'expected_duplicate', 'candidate_set_sha256',
        'occurrence_sequence_sha256', 'generated_absent_paths'
    ) 'selection'
    $variables = Assert-MesaSeedArray $profile.selection.variables 7 `
        'selection.variables'
    for ($index = 0; $index -lt $expectedVariables.Count; $index++) {
        $variable = $variables[$index]
        $expected = $expectedVariables[$index]
        Assert-MesaSeedExactProperties $variable @(
            'name', 'definition_file', 'occurrences'
        ) "selection.variables[$index]"
        Assert-MesaSeedExactString $variable.name $expected.Name `
            "selection.variables[$index].name"
        Assert-MesaSeedExactString $variable.definition_file $expected.DefinitionFile `
            "selection.variables[$index].definition_file"
        Assert-MesaSeedExactInteger $variable.occurrences $expected.Occurrences `
            "selection.variables[$index].occurrences"
    }
    Assert-MesaSeedExactStringSequence $profile.selection.forbidden_variables `
        $expectedForbiddenVariables 'selection.forbidden_variables'
    $disabledConditionals = Assert-MesaSeedArray `
        $profile.selection.disabled_conditionals 1 'selection.disabled_conditionals'
    $disabledConditional = $disabledConditionals[0]
    Assert-MesaSeedExactProperties $disabledConditional @(
        'definition_file', 'macro', 'state', 'variable', 'operator',
        'relative_path'
    ) 'selection.disabled_conditionals[0]'
    Assert-MesaSeedExactString $disabledConditional.definition_file `
        'mesa-23.1.x.mk' 'selection.disabled_conditionals[0].definition_file'
    Assert-MesaSeedExactString $disabledConditional.macro 'USE_ASM' `
        'selection.disabled_conditionals[0].macro'
    Assert-MesaSeedExactString $disabledConditional.state 'undefined' `
        'selection.disabled_conditionals[0].state'
    Assert-MesaSeedExactString $disabledConditional.variable 'MesaLib_SRC' `
        'selection.disabled_conditionals[0].variable'
    Assert-MesaSeedExactString $disabledConditional.operator '+=' `
        'selection.disabled_conditionals[0].operator'
    Assert-MesaSeedExactString $disabledConditional.relative_path `
        'mesa-23.1.x/src/mapi/glapi/gen/glapi_x86.S' `
        'selection.disabled_conditionals[0].relative_path'
    Assert-MesaSeedExactProperties $profile.selection.normalization @(
        'mesa_version_token', 'mesa_version_prefix', 'path_separator',
        'candidate_order', 'canonical_encoding'
    ) 'selection.normalization'
    Assert-MesaSeedExactString $profile.selection.normalization.mesa_version_token `
        '$(MESA_VER)/' 'selection.normalization.mesa_version_token'
    Assert-MesaSeedExactString $profile.selection.normalization.mesa_version_prefix `
        'mesa-23.1.x/' 'selection.normalization.mesa_version_prefix'
    Assert-MesaSeedExactString $profile.selection.normalization.path_separator '/' `
        'selection.normalization.path_separator'
    Assert-MesaSeedExactString $profile.selection.normalization.candidate_order `
        'ordinal-case-sensitive' 'selection.normalization.candidate_order'
    Assert-MesaSeedExactString $profile.selection.normalization.canonical_encoding `
        'utf-8-no-bom-lf-terminal-newline' `
        'selection.normalization.canonical_encoding'
    Assert-MesaSeedExactProperties $profile.selection.worktree_normalization @(
        'strategy', 'allowed_prefixes', 'forbidden_attributes', 'final_rehash'
    ) 'selection.worktree_normalization'
    Assert-MesaSeedExactString $profile.selection.worktree_normalization.strategy `
        'crlf-to-lf-only' 'selection.worktree_normalization.strategy'
    Assert-MesaSeedExactStringSequence `
        $profile.selection.worktree_normalization.allowed_prefixes `
        $expectedNormalizationPrefixes `
        'selection.worktree_normalization.allowed_prefixes'
    Assert-MesaSeedExactStringSequence `
        $profile.selection.worktree_normalization.forbidden_attributes `
        $expectedForbiddenAttributes `
        'selection.worktree_normalization.forbidden_attributes'
    Assert-MesaSeedTrue $profile.selection.worktree_normalization.final_rehash `
        'selection.worktree_normalization.final_rehash'
    Assert-MesaSeedExactInteger $profile.selection.occurrence_count 870 `
        'selection.occurrence_count'
    Assert-MesaSeedExactInteger $profile.selection.unique_count 869 `
        'selection.unique_count'
    Assert-MesaSeedExactInteger $profile.selection.tracked_present_count 840 `
        'selection.tracked_present_count'
    Assert-MesaSeedExactInteger $profile.selection.generated_absent_count 29 `
        'selection.generated_absent_count'
    Assert-MesaSeedExactProperties $profile.selection.expected_duplicate @(
        'relative_path', 'occurrences'
    ) 'selection.expected_duplicate'
    Assert-MesaSeedExactString $profile.selection.expected_duplicate.relative_path `
        'mesa-23.1.x/src/mesa/main/es1_conversion.c' `
        'selection.expected_duplicate.relative_path'
    Assert-MesaSeedExactInteger $profile.selection.expected_duplicate.occurrences 2 `
        'selection.expected_duplicate.occurrences'
    Assert-MesaSeedExactString $profile.selection.candidate_set_sha256 `
        '6cbc9ffcad7d06f01ad019b9f62bc7c647ff19da3f4993ac0707ef5b5faed716' `
        'selection.candidate_set_sha256'
    Assert-MesaSeedExactString $profile.selection.occurrence_sequence_sha256 `
        '4ecdda04b89dabc541f837a0972806a88187b9f6751b75905f4df6dbd762b8f2' `
        'selection.occurrence_sequence_sha256'
    Assert-MesaSeedExactStringSequence $profile.selection.generated_absent_paths `
        $expectedAbsentPaths 'selection.generated_absent_paths'

    Assert-MesaSeedExactProperties $profile.scope @(
        'classification', 'claims', 'authorizations'
    ) 'scope'
    Assert-MesaSeedExactString $profile.scope.classification 'source-list-seed-only' `
        'scope.classification'
    Assert-MesaSeedExactProperties $profile.scope.claims @(
        'header_closure', 'depfile_closure', 'generator_closure',
        'build_closure', 'license_closure'
    ) 'scope.claims'
    foreach ($claim in @(
        'header_closure', 'depfile_closure', 'generator_closure',
        'build_closure', 'license_closure'
    )) {
        Assert-MesaSeedFalse $profile.scope.claims.$claim "scope.claims.$claim"
    }
    Assert-MesaSeedExactProperties $profile.scope.authorizations @(
        'build', 'stage', 'guest_install', 'capability_advertisement'
    ) 'scope.authorizations'
    foreach ($authorization in @(
        'build', 'stage', 'guest_install', 'capability_advertisement'
    )) {
        Assert-MesaSeedFalse $profile.scope.authorizations.$authorization `
            "scope.authorizations.$authorization"
    }

    $blockers = Assert-MesaSeedArray $profile.blockers 6 'blockers'
    for ($index = 0; $index -lt $expectedBlockers.Count; $index++) {
        $blocker = $blockers[$index]
        $expected = $expectedBlockers[$index]
        Assert-MesaSeedExactProperties $blocker @(
            'relative_path', 'candidate_relation', 'required_disposition'
        ) "blockers[$index]"
        Assert-MesaSeedExactString $blocker.relative_path $expected.Path `
            "blockers[$index].relative_path"
        Assert-MesaSeedExactString $blocker.candidate_relation $expected.Relation `
            "blockers[$index].candidate_relation"
        Assert-MesaSeedExactString $blocker.required_disposition $expected.Disposition `
            "blockers[$index].required_disposition"
    }

    $resolvedSourceRoot = Get-MesaSeedFullPath $SourceRootPath
    Assert-MesaSeedNoReparseAncestor $resolvedSourceRoot 'Mesa source root'
    if (-not (Test-Path -LiteralPath $resolvedSourceRoot -PathType Container)) {
        throw "Mesa source root not found: $resolvedSourceRoot"
    }
    $checkout = Get-MesaSeedContainedPath $resolvedSourceRoot 'mesa9x' 'Mesa checkout' `
        -AllowDirectory
    Assert-MesaSeedGitCheckout $checkout $profile.source.owning_commit `
        $profile.source.repository
    $indexRecords = Get-MesaSeedIndex $checkout
    Write-Verbose 'Verified Mesa checkout and index.'

    $normalizationRecord = $profile.source.normalization_file
    $normalizationPath = [string]$normalizationRecord.relative_path
    $normalizationBlob = Get-MesaSeedGitBlob $checkout $normalizationRecord.git_blob
    if ($normalizationBlob.Length -ne [UInt64]$normalizationRecord.bytes -or
        $normalizationBlob.Sha256 -cne $normalizationRecord.sha256) {
        throw "Mesa normalization file '$normalizationPath' blob digest mismatch."
    }
    $normalizationText = ConvertFrom-MesaSeedUtf8 $normalizationBlob.Bytes `
        "Mesa normalization file '$normalizationPath'"
    if ($normalizationText -cne (
            "*.csv eol=crlf`n* text=auto`n*.jpg binary`n*.png binary`n" +
            "*.gif binary`n*.ico binary`n"
        )) {
        throw "Mesa normalization file '$normalizationPath' has unexpected policy."
    }
    Assert-MesaSeedIndexedFiles $checkout @($normalizationPath) $indexRecords

    $claimedMissingPath = [string]$profile.source.confirmed_absent_input
    Assert-MesaSeedPathAbsent $checkout $indexRecords $claimedMissingPath `
        'Confirmed absent input'

    $allEntries = [Collections.Generic.List[object]]::new()
    $definitionTexts = @{}
    Assert-MesaSeedIndexedFiles $checkout @(
        $definitionRecords | ForEach-Object { [string]$_.relative_path }
    ) $indexRecords
    foreach ($definition in $definitionRecords) {
        $relativePath = [string]$definition.relative_path
        if (-not $indexRecords.ContainsKey($relativePath)) {
            throw "Mesa definition '$relativePath' is not tracked."
        }
        $indexRecord = $indexRecords[$relativePath]
        if ($indexRecord.Mode -cne '100644' -or
            $indexRecord.Blob -cne $definition.git_blob) {
            throw "Mesa definition '$relativePath' index record mismatch."
        }
        $blob = Get-MesaSeedGitBlob $checkout $definition.git_blob
        if ($blob.Length -ne [UInt64]$definition.bytes -or
            $blob.Sha256 -cne $definition.sha256) {
            throw "Mesa definition '$relativePath' blob digest mismatch."
        }
        $text = ConvertFrom-MesaSeedUtf8 $blob.Bytes "Mesa definition '$relativePath'"
        $definitionTexts[$relativePath] = $text
        $names = @($variables | Where-Object {
            $_.definition_file -ceq $relativePath
        } | ForEach-Object { [string]$_.name })
        $parsed = @(Read-MesaSeedAssignments $text $relativePath $names)
        foreach ($entry in $parsed) {
            $allEntries.Add($entry)
        }
    }
    foreach ($variable in $variables) {
        $observed = @($allEntries | Where-Object {
            $_.Variable -ceq $variable.name
        }).Count
        if ($observed -ne [int]$variable.occurrences) {
            throw "Mesa source variable '$($variable.name)' has $observed entries, expected $($variable.occurrences)."
        }
    }
    Write-Verbose 'Parsed pinned Mesa source definitions.'
    $mesaDefinitionText = [string]$definitionTexts['mesa-23.1.x.mk']
    Assert-MesaSeedDisabledConditionals $mesaDefinitionText 'mesa-23.1.x.mk' `
        @($variables | Where-Object {
            $_.definition_file -ceq 'mesa-23.1.x.mk'
        } | ForEach-Object { [string]$_.name })
    foreach ($forbidden in $expectedForbiddenVariables) {
        if ($mesaDefinitionText -notmatch "(?m)^$([regex]::Escape($forbidden))[ \t]*=") {
            throw "Forbidden Mesa family '$forbidden' is not anchored in its definition file."
        }
    }

    $analysis = Get-MesaSeedAnalysis @($allEntries) `
        $profile.selection.expected_duplicate.relative_path `
        ([int]$profile.selection.expected_duplicate.occurrences)
    if ($analysis.OccurrenceCount -ne [int]$profile.selection.occurrence_count -or
        $analysis.UniqueCount -ne [int]$profile.selection.unique_count -or
        $analysis.CandidateSetSha256 -cne $profile.selection.candidate_set_sha256 -or
        $analysis.OccurrenceSequenceSha256 -cne
            $profile.selection.occurrence_sequence_sha256) {
        throw 'Mesa source-list seed count or digest mismatch.'
    }

    $observedAbsent = [Collections.Generic.List[string]]::new()
    $trackedCount = 0
    $trackedPaths = @($analysis.UniquePaths | Where-Object {
        $indexRecords.ContainsKey($_)
    })
    Write-Verbose 'Validating Mesa source-list candidate paths.'
    Assert-MesaSeedContainedPathsNoReparse $checkout @($analysis.UniquePaths) `
        'Mesa source-list candidates'
    foreach ($relativePath in $analysis.UniquePaths) {
        $candidate = Get-MesaSeedContainedPath $checkout $relativePath `
            'Mesa source-list candidate'
        if ($indexRecords.ContainsKey($relativePath)) {
            $record = $indexRecords[$relativePath]
            if ($record.Mode -notin @('100644', '100755')) {
                throw "Tracked Mesa source-list candidate '$relativePath' is unavailable."
            }
            Assert-MesaSeedRegularBoundedFile $candidate `
                "Tracked Mesa source-list candidate '$relativePath'" `
                $script:MesaSeedMaximumCandidateBytes
            $trackedCount++
        }
        else {
            if (Test-Path -LiteralPath $candidate) {
                throw "Generated-absent Mesa candidate '$relativePath' exists in the checkout."
            }
            $observedAbsent.Add($relativePath)
        }
    }
    Write-Verbose 'Hashing validated Mesa source-list candidates.'
    Assert-MesaSeedIndexedFiles $checkout $trackedPaths $indexRecords -PathsValidated
    Write-Verbose 'Matched Mesa source-list candidates to indexed blobs.'
    if ($trackedCount -ne [int]$profile.selection.tracked_present_count -or
        $observedAbsent.Count -ne [int]$profile.selection.generated_absent_count) {
        throw 'Mesa source-list tracked/generated classification count mismatch.'
    }
    Assert-MesaSeedExactStringSequence @($observedAbsent) $expectedAbsentPaths `
        'observed generated-absent paths'

    $candidateSet = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )
    foreach ($path in $analysis.UniquePaths) {
        [void]$candidateSet.Add($path)
    }
    foreach ($blocker in $blockers) {
        $path = [string]$blocker.relative_path
        if ($blocker.candidate_relation -ceq 'selected') {
            if (-not $candidateSet.Contains($path)) {
                throw "Selected blocker '$path' is absent from the source-list seed."
            }
        }
        elseif ($candidateSet.Contains($path)) {
            throw "Transitive blocker '$path' unexpectedly entered the source-list seed."
        }
        if ($path -ceq 'include/winddk') {
            $prefix = $path + '/'
            $matches = @($indexRecords.Keys | Where-Object {
                $_.StartsWith($prefix, [StringComparison]::Ordinal)
            })
            if ($matches.Count -eq 0) {
                throw "Blocker directory '$path' is not tracked."
            }
        }
        elseif (-not $indexRecords.ContainsKey($path)) {
            throw "Blocker '$path' is not tracked."
        }
    }

    if ($null -ne $BeforeFinalMetadataCheck) {
        & $BeforeFinalMetadataCheck
    }
    $metadataSourcePaths = @(
        $definitionRecords | ForEach-Object { [string]$_.relative_path }
    ) + @($normalizationPath)
    Assert-MesaSeedContainedPathsNoReparse $checkout @(
        $metadataSourcePaths + $trackedPaths
    ) 'final Mesa source-list candidates' -RequireRegularLeaves
    Assert-MesaSeedContainedPathsNoReparse $checkout $expectedAbsentPaths `
        'final generated-absent Mesa candidates'
    Assert-MesaSeedIndexedFiles $checkout $metadataSourcePaths $indexRecords `
        -PathsValidated
    Assert-MesaSeedIndexedFiles $checkout $trackedPaths $indexRecords `
        -PathsValidated
    foreach ($relativePath in $expectedAbsentPaths) {
        $candidate = Get-MesaSeedContainedPath $checkout $relativePath `
            'generated-absent Mesa candidate'
        if (Test-Path -LiteralPath $candidate) {
            throw "Generated-absent Mesa candidate '$relativePath' appeared during verification."
        }
    }
    $finalIndexRecords = Get-MesaSeedIndex $checkout
    Assert-MesaSeedPathAbsent $checkout $finalIndexRecords $claimedMissingPath `
        'Confirmed absent input'
    $finalProfileDocument = Read-MesaSeedJsonDocument $resolvedProfile `
        'Mesa source-list seed profile'
    $finalSchemaDocument = Read-MesaSeedJsonDocument $schemaPath `
        'Mesa source-list seed schema'
    if ($finalProfileDocument.Bytes -ne $profileDocument.Bytes -or
        $finalProfileDocument.Sha256 -cne $profileDocument.Sha256 -or
        $finalSchemaDocument.Bytes -ne $schemaDocument.Bytes -or
        $finalSchemaDocument.Sha256 -cne $schemaDocument.Sha256) {
        throw 'Mesa source-list seed metadata changed during verification.'
    }
    Assert-MesaSeedGitCheckout $checkout $profile.source.owning_commit `
        $profile.source.repository
    if (-not $AuditPolicy) {
        throw "Mesa source-list seed is blocked: $($profile.reason)"
    }
    Write-Output (
        'Policy-audited blocked Mesa source-list seed: 870 occurrences, ' +
        '869 unique, 840 tracked-present, 29 generated-absent; unusable for ' +
        'build, stage, or capability activation.'
    )
}

if ($MyInvocation.InvocationName -cne '.') {
    if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
        throw 'SourceRoot is required.'
    }
    if ([string]::IsNullOrWhiteSpace($ProfileFile)) {
        $ProfileFile = Join-Path $PSScriptRoot `
            '..\drivers\win98\mesa-source-seed.json'
    }
    Invoke-MesaSourceSeedVerification -SourceRootPath $SourceRoot `
        -ProfilePath $ProfileFile -AuditPolicy:$PolicyAudit `
        -BeforeFinalMetadataCheck $BeforeFinalMetadataCheck
}
