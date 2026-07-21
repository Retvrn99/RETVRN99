# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$MesaCheckout,

    [Parameter(Mandatory = $true)]
    [string]$OutputRoot,

    [string]$PlanFile,

    [switch]$Describe
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:ExpectedPlanSha256 =
    '7d08ea089889105443935fb48a59a69698e5c0cac9f5f87ff02c8710c2a5718c'
$script:ExpectedSchemaSha256 =
    'adc69c44e1ebd9e465f667ef42a605451c05a601c4db59bdd2652cf7709cec97'
$script:ExpectedSeedSha256 =
    'b7a18f8bfe4bfe5fac1ef8b4f36105d585e7d69349766d865c8c79a180d79dd8'
$script:ExpectedCommit = '29b9adb44bc5ea54dc53c02b5e4b49292c6cc04f'
$script:ExpectedRepository = 'https://github.com/JHRobotics/mesa9x.git'
$script:ExpectedRecipeBlob = '68b2fd13d08ae0ce4276cb1f720ee9bbb1cd54e9'
$script:ExpectedRecipeSha256 =
    '9ad77b1fe55e4097621dbefeffe989fb00f3c354320ce6521d69f8efd8a44dce'
$script:ExpectedRecipePathDigest =
    '480f4000b3d6c10eced24e4538ee4aabdd59e3dbe3172054910bc7eac01c7140'
$script:Utf8 = New-Object Text.UTF8Encoding($false, $true)
$script:MaximumPathBytes = 512
$script:MaximumFileBytes = [UInt64]33554432
$script:MaximumAggregateBytes = [UInt64]67108864
$script:MaximumDirectories = 64
$script:MaximumEntries = 135

. (Join-Path $PSScriptRoot 'strict-json.ps1')

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
        throw "$Name fields do not match the pinned schema."
    }
    foreach ($property in $Expected) {
        if ($actual -cnotcontains $property) {
            throw "$Name is missing '$property'."
        }
    }
}

function Assert-FalseBoolean {
    param([AllowNull()][object]$Value, [string]$Name)

    if ($Value -isnot [bool] -or $Value) {
        throw "$Name must remain false."
    }
}

function Assert-SafeRelativePath {
    param([AllowNull()][object]$RelativePath, [string]$Name)

    if ($RelativePath -isnot [string] -or
        [string]::IsNullOrWhiteSpace($RelativePath) -or
        [IO.Path]::IsPathRooted($RelativePath) -or
        $RelativePath.Contains('\') -or
        $script:Utf8.GetByteCount($RelativePath) -gt $script:MaximumPathBytes) {
        throw "Unsafe relative path '$RelativePath' in $Name."
    }
    foreach ($component in $RelativePath.Split('/')) {
        if ([string]::IsNullOrWhiteSpace($component) -or
            $component -in @('.', '..') -or
            $component -match '[\x00-\x1f:*?"<>|]' -or
            $component.EndsWith('.') -or $component.EndsWith(' ') -or
            $component -match
                '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$') {
            throw "Unsafe path component '$component' in $Name."
        }
    }
}

function Convert-ToWin9xShortCharacter {
    param([char]$Character)

    $upper = [char]::ToUpperInvariant($Character)
    if (($upper -ge 'A' -and $upper -le 'Z') -or
        ($upper -ge '0' -and $upper -le '9') -or
        "!#$%&'()-@^_``{}~".IndexOf($upper) -ge 0) {
        return [string]$upper
    }
    return '_'
}

function Get-Win9xDirectAlias {
    param([string]$Name)

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
        [string]$Name,
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
    param([string[]]$Paths, [string]$Name)

    $ordinal = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )
    $folded = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $childrenByParent =
        [Collections.Generic.Dictionary[string,object]]::new(
            [StringComparer]::Ordinal
        )
    $foldedChildrenByParent =
        [Collections.Generic.Dictionary[string,object]]::new(
            [StringComparer]::Ordinal
        )
    foreach ($path in $Paths) {
        Assert-SafeRelativePath $path $Name
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
    foreach ($path in $Paths) {
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
                throw "File/ancestor collision for '$path' in $Name."
            }
        }
    }
}

function Assert-OrdinaryDirectory {
    param([string]$Path, [string]$Name)

    $fullPath = [IO.Path]::GetFullPath($Path)
    Assert-GswNoReparseAncestor -Path $fullPath -Name $Name
    $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::Directory) -eq 0 -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        ($item.Attributes -band [IO.FileAttributes]::Device) -ne 0) {
        throw "$Name must be one ordinary directory."
    }
    return $item.FullName
}

function Resolve-ExactContainedFile {
    param([string]$Root, [string]$RelativePath, [string]$Name)

    Assert-SafeRelativePath $RelativePath $Name
    $current = [IO.Path]::GetFullPath($Root)
    $parts = $RelativePath.Split('/')
    for ($index = 0; $index -lt $parts.Count; $index++) {
        $matches = @([IO.Directory]::EnumerateFileSystemEntries($current) |
            Where-Object {
                [IO.Path]::GetFileName($_).Equals(
                    $parts[$index],
                    [StringComparison]::OrdinalIgnoreCase
                )
            })
        if ($matches.Count -ne 1 -or
            [IO.Path]::GetFileName($matches[0]) -cne $parts[$index]) {
            throw "$Name '$RelativePath' is missing or has non-exact casing."
        }
        $attributes = [IO.File]::GetAttributes($matches[0])
        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            ($attributes -band [IO.FileAttributes]::Device) -ne 0) {
            throw "$Name '$RelativePath' crosses a reparse point or device."
        }
        $isLast = $index -eq $parts.Count - 1
        $isDirectory = ($attributes -band [IO.FileAttributes]::Directory) -ne 0
        if (($isLast -and $isDirectory) -or (-not $isLast -and -not $isDirectory)) {
            throw "$Name '$RelativePath' has an invalid filesystem type."
        }
        $current = $matches[0]
    }
    return [IO.Path]::GetFullPath($current)
}

function ConvertTo-ProcessArgument {
    param([string]$Argument)

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

function New-GitStartInfo {
    param([string]$Checkout, [string[]]$Arguments)

    $commands = @(Get-Command git -CommandType Application -ErrorAction Stop)
    if ($commands.Count -eq 0) {
        throw 'git is unavailable for generated-source preparation.'
    }
    $gitPath = [IO.Path]::GetFullPath($commands[0].Source)
    if ([IO.Path]::DirectorySeparatorChar -eq '\') {
        $gitRoot = Split-Path -Parent (Split-Path -Parent $gitPath)
        $directPath = Join-Path $gitRoot 'mingw64\bin\git.exe'
        if (Test-Path -LiteralPath $directPath -PathType Leaf) {
            $gitPath = [IO.Path]::GetFullPath($directPath)
        }
    }
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $gitPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($name in @(
        'GIT_CEILING_DIRECTORIES', 'GIT_DIR', 'GIT_WORK_TREE', 'GIT_PREFIX',
        'GIT_INDEX_FILE', 'GIT_CONFIG_COUNT', 'GIT_CONFIG_PARAMETERS',
        'GIT_CONFIG_SYSTEM', 'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_NOSYSTEM',
        'GIT_COMMON_DIR', 'GIT_OBJECT_DIRECTORY',
        'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_SHALLOW_FILE',
        'GIT_GRAFT_FILE', 'GIT_REPLACE_REF_BASE', 'GIT_NAMESPACE',
        'GIT_ATTR_SOURCE', 'GIT_EXEC_PATH', 'GIT_LITERAL_PATHSPECS',
        'GIT_GLOB_PATHSPECS', 'GIT_NOGLOB_PATHSPECS',
        'GIT_ICASE_PATHSPECS', 'GIT_REDIRECT_STDERR'
    )) {
        $startInfo.EnvironmentVariables.Remove($name)
    }
    foreach ($name in @($startInfo.EnvironmentVariables.Keys)) {
        if ($name.StartsWith('GIT_CONFIG_KEY_',
                [StringComparison]::OrdinalIgnoreCase) -or
            $name.StartsWith('GIT_CONFIG_VALUE_',
                [StringComparison]::OrdinalIgnoreCase) -or
            $name.StartsWith('GIT_TRACE',
                [StringComparison]::OrdinalIgnoreCase)) {
            $startInfo.EnvironmentVariables.Remove($name)
        }
    }
    $startInfo.EnvironmentVariables['GIT_OPTIONAL_LOCKS'] = '0'
    $startInfo.EnvironmentVariables['GIT_NO_REPLACE_OBJECTS'] = '1'
    $startInfo.EnvironmentVariables['GIT_NO_LAZY_FETCH'] = '1'
    $startInfo.EnvironmentVariables['GIT_CONFIG_NOSYSTEM'] = '1'
    $startInfo.EnvironmentVariables['GIT_CONFIG_GLOBAL'] = if (
        [IO.Path]::DirectorySeparatorChar -eq '\'
    ) { 'NUL' } else { '/dev/null' }
    $allArguments = @(
        '--no-pager', '--no-replace-objects',
        '-c', 'core.quotePath=false',
        '-c', 'core.fsmonitor=false',
        '-c', 'core.untrackedCache=false',
        '-c', "safe.directory=$Checkout",
        '-C', $Checkout
    ) + $Arguments
    $startInfo.Arguments = ($allArguments | ForEach-Object {
        ConvertTo-ProcessArgument ([string]$_)
    }) -join ' '
    return $startInfo
}

function Invoke-PreparationGit {
    param([string]$Checkout, [string[]]$Arguments)

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = New-GitStartInfo $Checkout $Arguments
    try {
        if (-not $process.Start()) {
            throw 'Unable to start git for generated-source preparation.'
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(5000)) {
            $process.Kill()
            [void]$process.WaitForExit(5000)
            throw "git $($Arguments -join ' ') exceeded five seconds."
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "git $($Arguments -join ' ') failed: $($stderr.Trim())"
        }
        if ($script:Utf8.GetByteCount($stdout) -gt 4194304 -or
            $script:Utf8.GetByteCount($stderr) -gt 1048576) {
            throw "git $($Arguments -join ' ') exceeded its output bound."
        }
        return $stdout
    }
    finally {
        $process.Dispose()
    }
}

function Read-GitBlobBytes {
    param([string]$Checkout, [string]$Blob)

    if ($Blob -cnotmatch '^[0-9a-f]{40}$') {
        throw "Invalid Git blob '$Blob'."
    }
    $sizeText = (Invoke-PreparationGit $Checkout @(
        'cat-file', '-s', $Blob
    )).TrimEnd("`r", "`n")
    [UInt64]$announcedLength = 0
    if (-not [UInt64]::TryParse(
            $sizeText,
            [Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$announcedLength
        ) -or $announcedLength -gt $script:MaximumFileBytes -or
        $announcedLength -gt [int]::MaxValue) {
        throw "Git blob '$Blob' has an invalid or excessive announced size."
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = New-GitStartInfo $Checkout @('cat-file', 'blob', $Blob)
    $started = $false
    try {
        if (-not $process.Start()) {
            throw "Unable to read Git blob '$Blob'."
        }
        $started = $true
        $errorTask = $process.StandardError.ReadToEndAsync()
        $memory = [IO.MemoryStream]::new([int]$announcedLength)
        try {
            $copyTask = $process.StandardOutput.BaseStream.CopyToAsync($memory)
            if (-not $process.WaitForExit(5000)) {
                $process.Kill()
                [void]$process.WaitForExit(5000)
                throw "git cat-file for '$Blob' exceeded five seconds."
            }
            [void]$copyTask.GetAwaiter().GetResult()
            $errorText = $errorTask.GetAwaiter().GetResult()
            if ($process.ExitCode -ne 0) {
                throw "git cat-file failed for '$Blob': $errorText"
            }
            if ([UInt64]$memory.Length -ne $announcedLength) {
                throw "Git blob '$Blob' length differs from cat-file -s."
            }
            return ,([byte[]]$memory.ToArray())
        }
        finally {
            $memory.Dispose()
        }
    }
    finally {
        if ($started -and -not $process.HasExited) {
            $process.Kill()
            [void]$process.WaitForExit(5000)
        }
        $process.Dispose()
    }
}

function Get-NulItems {
    param([string]$Text, [string]$Name)

    if ($Text.Length -eq 0) { return @() }
    if ($Text[$Text.Length - 1] -ne [char]0) {
        throw "$Name is not NUL terminated."
    }
    $items = @($Text.Substring(0, $Text.Length - 1).Split([char]0))
    if (@($items | Where-Object { $_.Length -eq 0 }).Count -ne 0) {
        throw "$Name contains an empty item."
    }
    return @($items)
}

function Get-NormalizedRepository {
    param([string]$Repository)

    $normalized = $Repository.TrimEnd('/')
    if ($normalized.EndsWith('.git', [StringComparison]::OrdinalIgnoreCase)) {
        $normalized = $normalized.Substring(0, $normalized.Length - 4)
    }
    return $normalized.ToLowerInvariant()
}

function Assert-LocalGitConfiguration {
    param([string]$Checkout)

    $gitDirectory = Assert-OrdinaryDirectory (Join-Path $Checkout '.git') `
        'Mesa Git directory'
    if (Test-Path -LiteralPath (Join-Path $gitDirectory 'config.worktree')) {
        throw 'Mesa checkout cannot use worktree-specific Git config.'
    }
    $configPath = Resolve-ExactContainedFile $gitDirectory 'config' `
        'Mesa local Git config'
    $snapshot = Read-GswBoundedFileSnapshot -Path $configPath `
        -Name 'Mesa local Git config' -MaximumBytes 1048576
    $originText = Invoke-PreparationGit $Checkout @(
        'config', '--file', $configPath, '--no-includes', '--null',
        '--get-all', 'remote.origin.url'
    )
    $origins = @(Get-NulItems $originText 'Mesa local origin list')
    if ($origins.Count -ne 1 -or $origins[0] -cne $origins[0].Trim() -or
        (Get-NormalizedRepository $origins[0]) -cne
            (Get-NormalizedRepository $script:ExpectedRepository)) {
        throw 'Mesa checkout must have exactly the pinned local origin.'
    }
    $names = Get-NulItems (Invoke-PreparationGit $Checkout @(
        'config', '--file', $configPath, '--no-includes', '--null',
        '--name-only', '--list'
    )) 'Mesa local config-name list'
    foreach ($name in $names) {
        if ($name -match
            '^(?i:include\.path|includeif\..*\.path|filter\..*\.(?:clean|smudge|process|required)|extensions\.(?:partialclone|worktreeconfig)|remote\..*\.(?:partialclonefilter|promisor|receivepack|uploadpack|vcs)|url\..*\.(?:insteadof|pushinsteadof)|protocol\..*\.allow|core\.gitproxy)$') {
            throw "Mesa local Git config contains forbidden key '$name'."
        }
    }
    return $snapshot
}

function ConvertTo-NormalizedSource {
    param([byte[]]$Bytes, [string]$Name)

    $text = ConvertFrom-GswStrictUtf8Bytes -Bytes $Bytes -Source $Name
    if ($text.IndexOf([char]0) -ge 0) {
        throw "$Name contains NUL."
    }
    $withoutCrLf = $text.Replace("`r`n", '')
    if ($withoutCrLf.IndexOf("`r", [StringComparison]::Ordinal) -ge 0) {
        throw "$Name contains an isolated carriage return."
    }
    $normalizedText = $text.Replace("`r`n", "`n")
    return ,([byte[]]$script:Utf8.GetBytes($normalizedText))
}

function Get-GitBlobSha1 {
    param([byte[]]$Bytes)

    $header = [Text.Encoding]::ASCII.GetBytes("blob $($Bytes.Length)`0")
    $sha = [Security.Cryptography.SHA1]::Create()
    try {
        [void]$sha.TransformBlock($header, 0, $header.Length, $header, 0)
        [void]$sha.TransformFinalBlock($Bytes, 0, $Bytes.Length)
        return ([BitConverter]::ToString($sha.Hash) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-CNonCommentTokenSha256 {
    param([byte[]]$Bytes, [string]$Name)

    $text = $script:Utf8.GetString($Bytes)
    $builder = [Text.StringBuilder]::new($text.Length)
    $state = 'normal'
    $pendingSeparator = $false
    for ($index = 0; $index -lt $text.Length; $index++) {
        $character = $text[$index]
        $next = if ($index + 1 -lt $text.Length) {
            $text[$index + 1]
        }
        else { [char]0 }
        switch ($state) {
            'normal' {
                if ([char]::IsWhiteSpace($character)) {
                    $pendingSeparator = $true
                    continue
                }
                if ($character -eq '/' -and $next -eq '*') {
                    $state = 'block-comment'
                    $pendingSeparator = $true
                    $index++
                    continue
                }
                if ($character -eq '/' -and $next -eq '/') {
                    $state = 'line-comment'
                    $pendingSeparator = $true
                    $index++
                    continue
                }
                if ($pendingSeparator -and $builder.Length -ne 0) {
                    [void]$builder.Append(' ')
                }
                $pendingSeparator = $false
                [void]$builder.Append($character)
                if ($character -eq '"') { $state = 'string' }
                elseif ($character -eq "'") { $state = 'character' }
            }
            'block-comment' {
                if ($character -eq '*' -and $next -eq '/') {
                    $state = 'normal'
                    $index++
                }
            }
            'line-comment' {
                if ($character -eq "`n") {
                    $state = 'normal'
                    $pendingSeparator = $true
                }
            }
            'string' {
                [void]$builder.Append($character)
                if ($character -eq '\') { $state = 'string-escape' }
                elseif ($character -eq '"') { $state = 'normal' }
            }
            'string-escape' {
                [void]$builder.Append($character)
                $state = 'string'
            }
            'character' {
                [void]$builder.Append($character)
                if ($character -eq '\') { $state = 'character-escape' }
                elseif ($character -eq "'") { $state = 'normal' }
            }
            'character-escape' {
                [void]$builder.Append($character)
                $state = 'character'
            }
        }
    }
    if ($state -notin @('normal', 'line-comment')) {
        throw "$Name contains an unterminated C lexical construct."
    }
    return Get-GswSha256Hex $script:Utf8.GetBytes($builder.ToString())
}

function Get-RecipePaths {
    param([string]$Text)

    if ($Text.IndexOf("`r", [StringComparison]::Ordinal) -ge 0) {
        throw 'Pinned generator recipe must use LF line endings.'
    }
    $lines = @($Text.Split("`n"))
    $headers = @($lines | Where-Object { $_ -ceq 'GENERATE_FILES = \' })
    if ($headers.Count -ne 1) {
        throw 'Pinned generator recipe must contain one exact GENERATE_FILES block.'
    }
    if (@($lines | Where-Object { $_ -ceq 'MESA_VER ?= mesa-23.1.x' }).Count -ne 1) {
        throw 'Pinned generator recipe has an unexpected MESA_VER assignment.'
    }
    $start = [Array]::IndexOf($lines, 'GENERATE_FILES = \')
    $paths = @()
    for ($index = $start + 1; $index -lt $lines.Count; $index++) {
        $line = $lines[$index]
        if ($line.Length -eq 0) { break }
        $match = [regex]::Match(
            $line,
            '^\t\$\(MESA_VER\)/(?<path>[A-Za-z0-9._/-]+)(?<continuation> \\)?$'
        )
        if (-not $match.Success) {
            throw "Malformed GENERATE_FILES row '$line'."
        }
        $paths += "mesa-23.1.x/$($match.Groups['path'].Value)"
        $hasContinuation = $match.Groups['continuation'].Success
        if ($paths.Count -lt 67 -and -not $hasContinuation) {
            throw 'GENERATE_FILES terminates before its pinned row count.'
        }
        if ($paths.Count -eq 67 -and $hasContinuation) {
            throw 'GENERATE_FILES exceeds its pinned row count.'
        }
    }
    if ($paths.Count -ne 67) {
        throw "GENERATE_FILES contains $($paths.Count) paths instead of 67."
    }
    Assert-PortablePathSet ([string[]]$paths) 'GENERATE_FILES'
    $sequenceBytes = $script:Utf8.GetBytes(($paths -join "`n") + "`n")
    if ((Get-GswSha256Hex $sequenceBytes) -cne
        $script:ExpectedRecipePathDigest) {
        throw 'GENERATE_FILES path sequence does not match the pinned recipe.'
    }
    return @($paths)
}

function Get-StatusMap {
    param([string]$Checkout)

    $raw = Invoke-PreparationGit $Checkout @(
        'status', '--porcelain=v1', '-z', '--untracked-files=all',
        '--ignored=matching', '--ignore-submodules=all'
    )
    $map = [Collections.Generic.Dictionary[string,string]]::new(
        [StringComparer]::Ordinal
    )
    foreach ($record in @(Get-NulItems $raw 'Mesa Git status')) {
        if ($record.Length -lt 4 -or $record[2] -ne ' ') {
            throw 'Mesa Git status contains a malformed record.'
        }
        $code = $record.Substring(0, 2)
        $path = $record.Substring(3).Replace('\', '/')
        Assert-SafeRelativePath $path 'Mesa Git status'
        if ($code -notin @('!!', ' M') -or $map.ContainsKey($path)) {
            throw "Mesa Git status contains unsupported state '$code $path'."
        }
        $map.Add($path, $code)
    }
    return $map
}

function Assert-ExactGeneratedState {
    param(
        [string]$Checkout,
        [string[]]$RecipePaths,
        [object[]]$SideOutputs
    )

    $status = Get-StatusMap $Checkout
    $allowed = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )
    foreach ($path in $RecipePaths) {
        [void]$allowed.Add($path)
        if (-not $status.ContainsKey($path) -or $status[$path] -cne '!!') {
            throw "Generated recipe target '$path' is not the exact ignored-present state."
        }
    }
    foreach ($side in $SideOutputs) {
        [void]$allowed.Add([string]$side.relative_path)
        if ($side.git_status -ceq 'required-worktree-modified') {
            if (-not $status.ContainsKey($side.relative_path) -or
                $status[$side.relative_path] -cne ' M') {
                throw "Validation-only side output '$($side.relative_path)' is not the required worktree-modified state."
            }
        }
        elseif ($side.git_status -ceq 'optional-worktree-modified') {
            if ($status.ContainsKey($side.relative_path) -and
                $status[$side.relative_path] -cne ' M') {
                throw "Validation-only side output '$($side.relative_path)' has an unsupported optional state."
            }
        }
        else {
            throw "Unsupported side-output Git policy '$($side.git_status)'."
        }
    }
    foreach ($path in $status.Keys) {
        if (-not $allowed.Contains($path)) {
            throw "Mesa checkout has unexpected changed, untracked, or ignored path '$path'."
        }
    }
}

function Assert-SideOutput {
    param([string]$Checkout, [object]$Side)

    $treeBlob = (Invoke-PreparationGit $Checkout @(
        'rev-parse', "HEAD:$($Side.relative_path)"
    )).TrimEnd("`r", "`n")
    if ($treeBlob -cne $Side.head_git_blob) {
        throw "Side output '$($Side.relative_path)' HEAD blob mismatch."
    }
    $worktreePath = Resolve-ExactContainedFile $Checkout $Side.relative_path `
        'validation-only side output'
    $worktree = Read-GswBoundedFileSnapshot -Path $worktreePath `
        -Name "validation-only side output '$($Side.relative_path)'" `
        -MaximumBytes $script:MaximumFileBytes
    $normalizedWorktree = ConvertTo-NormalizedSource $worktree.Bytes `
        "validation-only side output '$($Side.relative_path)'"
    $worktreeBlob = Get-GitBlobSha1 $normalizedWorktree
    if ($Side.validation -ceq 'exact-head-blob-equivalence') {
        if ($worktreeBlob -cne $Side.head_git_blob) {
            throw "Side output '$($Side.relative_path)' is not HEAD-blob equivalent."
        }
    }
    elseif ($Side.validation -ceq
        'exact-generated-blob-and-c-noncomment-token-equivalence') {
        $headBytes = Read-GitBlobBytes $Checkout $Side.head_git_blob
        $normalizedHead = ConvertTo-NormalizedSource $headBytes `
            "HEAD side output '$($Side.relative_path)'"
        $headTokens = Get-CNonCommentTokenSha256 $normalizedHead `
            "HEAD side output '$($Side.relative_path)'"
        $worktreeTokens = Get-CNonCommentTokenSha256 $normalizedWorktree `
            "generated side output '$($Side.relative_path)'"
        if ($headTokens -cne $worktreeTokens) {
            throw "Side output '$($Side.relative_path)' changes non-comment C tokens."
        }
    }
    else {
        throw "Unsupported side-output validation '$($Side.validation)'."
    }
    if ($worktreeBlob -cne $Side.generated_git_blob) {
        throw "Side output '$($Side.relative_path)' generated blob mismatch."
    }
    return [pscustomobject]@{
        RelativePath = [string]$Side.relative_path
        RawBytes = [UInt64]$worktree.Length
        RawSha256 = [string]$worktree.Sha256
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
        [Security.Cryptography.HashAlgorithm]$Digest,
        [byte[]]$Bytes
    )

    [void]$Digest.TransformBlock($Bytes, 0, $Bytes.Length, $Bytes, 0)
}

function Get-TreeDescriptor {
    param([object[]]$Records)

    $directories = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )
    [UInt64]$aggregateBytes = 0
    [UInt64]$maximumFileBytes = 0
    [UInt64]$maximumPathBytes = 0
    foreach ($record in $Records) {
        $aggregateBytes += [UInt64]$record.Bytes
        if ($aggregateBytes -gt $script:MaximumAggregateBytes) {
            throw 'Generated sources exceed the aggregate-byte bound.'
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
        throw 'Generated source tree exceeds its entry bounds.'
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
            Add-DigestBlock $digest (
                Get-BigEndianBytes ([UInt64]$pathBytes.Length) 4
            )
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

function Get-PublishedTreeRecords {
    param([string]$Root)

    $records = @()
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($Root)
    [UInt64]$entries = 0
    while ($pending.Count -ne 0) {
        $directory = $pending.Pop()
        foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($directory)) {
            $entries++
            if ($entries -gt $script:MaximumEntries) {
                throw 'Published source tree exceeds its entry bound.'
            }
            $attributes = [IO.File]::GetAttributes($entry)
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                ($attributes -band [IO.FileAttributes]::Device) -ne 0) {
                throw "Published source tree contains a reparse point or device: $entry"
            }
            if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) {
                $pending.Push($entry)
                continue
            }
            $prefix = $Root.TrimEnd([char[]]'\/') +
                [IO.Path]::DirectorySeparatorChar
            $fullPath = [IO.Path]::GetFullPath($entry)
            if (-not $fullPath.StartsWith(
                    $prefix, [StringComparison]::OrdinalIgnoreCase
                )) {
                throw 'Published source entry escapes its root.'
            }
            $relativePath = $fullPath.Substring($prefix.Length).Replace('\', '/')
            Assert-SafeRelativePath $relativePath 'published source tree'
            $snapshot = Read-GswBoundedFileSnapshot -Path $fullPath `
                -Name "published source '$relativePath'" `
                -MaximumBytes $script:MaximumFileBytes
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
    Assert-PortablePathSet ([string[]]@(
        $records | ForEach-Object { $_.RelativePath }
    )) 'published source tree'
    return @($records)
}

function Assert-RecordSetsEqual {
    param([object[]]$Expected, [object[]]$Actual, [string]$Name)

    if ($Expected.Count -ne $Actual.Count) {
        throw "$Name file count mismatch."
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
            throw "$Name mismatch for '$($record.RelativePath)'."
        }
    }
}

function Assert-SnapshotsUnchanged {
    param([string]$Checkout, [object[]]$Snapshots)

    foreach ($snapshot in $Snapshots) {
        $path = Resolve-ExactContainedFile $Checkout $snapshot.RelativePath `
            'generated source recheck'
        $current = Read-GswBoundedFileSnapshot -Path $path `
            -Name "generated source recheck '$($snapshot.RelativePath)'" `
            -MaximumBytes $script:MaximumFileBytes
        if ([UInt64]$current.Length -ne [UInt64]$snapshot.RawBytes -or
            $current.Sha256 -cne $snapshot.RawSha256) {
            throw "Generated source '$($snapshot.RelativePath)' changed during preparation."
        }
    }
}

function Remove-PrivateTemporaryTree {
    param([string]$Path, [string]$Parent)

    if ([string]::IsNullOrWhiteSpace($Path) -or
        -not (Test-Path -LiteralPath $Path)) {
        return
    }
    $fullPath = [IO.Path]::GetFullPath($Path)
    $parentPrefix = [IO.Path]::GetFullPath($Parent).TrimEnd([char[]]'\/') +
        [IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith(
            $parentPrefix, [StringComparison]::OrdinalIgnoreCase
        ) -or
        -not [IO.Path]::GetFileName($fullPath).StartsWith(
            '.retvrn99-generated-source-',
            [StringComparison]::Ordinal
        )) {
        throw "Refusing to remove unsafe temporary tree '$fullPath'."
    }
    [IO.Directory]::Delete($fullPath, $true)
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($PlanFile)) {
    $PlanFile = Join-Path $repoRoot `
        'drivers\win98\mesa-generated-source-plan.json'
}
$planPath = [IO.Path]::GetFullPath($PlanFile)
$planSnapshot = Read-GswStrictJsonFileSnapshot -Path $planPath `
    -Name 'Mesa generated-source plan' -MaximumBytes 1048576
if ($planSnapshot.Sha256 -cne $script:ExpectedPlanSha256) {
    throw 'Mesa generated-source plan is not the pinned draft.'
}
$plan = $planSnapshot.Value
Assert-ExactProperties $plan @(
    '_spdx', 'schema', 'schema_definition', 'status', 'reason', 'component',
    'inputs', 'selection', 'normalization', 'bounds', 'descriptor', 'scope'
) 'Mesa generated-source plan'
if ($plan._spdx -cne 'GPL-3.0-only' -or $plan.schema -ne 1 -or
    $plan.status -cne 'draft' -or
    [string]::IsNullOrWhiteSpace([string]$plan.reason)) {
    throw 'Mesa generated-source plan must remain a blocked draft.'
}
foreach ($claim in $plan.scope.claims.PSObject.Properties) {
    Assert-FalseBoolean $claim.Value "scope.claims.$($claim.Name)"
}
foreach ($authorization in $plan.scope.authorizations.PSObject.Properties) {
    Assert-FalseBoolean $authorization.Value `
        "scope.authorizations.$($authorization.Name)"
}
if ($plan.component.owning_commit -cne $script:ExpectedCommit -or
    $plan.component.repository -cne $script:ExpectedRepository -or
    $plan.selection.recipe_output_count -ne 67 -or
    $plan.selection.validation_side_output_count -ne 4 -or
    $plan.selection.published_output_count -ne 67) {
    throw 'Mesa generated-source plan identity or counts do not match the Interface.'
}

$metadataRoot = Split-Path -Parent $planPath
$schemaPath = Resolve-ExactContainedFile $metadataRoot `
    $plan.schema_definition.relative_path 'generated-source plan schema'
$schemaSnapshot = Read-GswBoundedFileSnapshot -Path $schemaPath `
    -Name 'generated-source plan schema' -MaximumBytes 1048576
if ($schemaSnapshot.Sha256 -cne $script:ExpectedSchemaSha256 -or
    $schemaSnapshot.Sha256 -cne $plan.schema_definition.sha256) {
    throw 'Generated-source plan schema identity mismatch.'
}
$seedPath = Resolve-ExactContainedFile $metadataRoot `
    $plan.inputs.source_seed.relative_path 'Mesa source seed'
$seedSnapshot = Read-GswStrictJsonFileSnapshot -Path $seedPath `
    -Name 'Mesa source seed' -MaximumBytes 1048576
if ($seedSnapshot.Sha256 -cne $script:ExpectedSeedSha256 -or
    $seedSnapshot.Sha256 -cne $plan.inputs.source_seed.sha256 -or
    $seedSnapshot.Length -ne [UInt64]$plan.inputs.source_seed.bytes) {
    throw 'Mesa source seed identity mismatch.'
}
$seed = $seedSnapshot.Value
if ($seed.source.owning_commit -cne $script:ExpectedCommit -or
    $seed.selection.generated_absent_count -ne 29 -or
    $seed.selection.generated_absent_paths -isnot [Array] -or
    $seed.selection.generated_absent_paths.Count -ne 29) {
    throw 'Mesa source seed does not match the pinned source selection.'
}

$checkout = Assert-OrdinaryDirectory $MesaCheckout 'Mesa checkout'
$gitConfigSnapshot = Assert-LocalGitConfiguration $checkout
$root = (Invoke-PreparationGit $checkout @(
    'rev-parse', '--show-toplevel'
)).TrimEnd("`r", "`n")
if ([IO.Path]::GetFullPath($root) -cne $checkout) {
    throw 'Mesa checkout root mismatch.'
}
$head = (Invoke-PreparationGit $checkout @(
    'rev-parse', '--verify', 'HEAD'
)).TrimEnd("`r", "`n")
if ($head -cne $script:ExpectedCommit) {
    throw "Mesa checkout HEAD '$head' is not pinned."
}
$recipePath = Resolve-ExactContainedFile $checkout `
    $plan.inputs.generator_recipe.relative_path 'Mesa generator recipe'
$recipeIndexState = (Invoke-PreparationGit $checkout @(
    'ls-files', '-v', '--', $plan.inputs.generator_recipe.relative_path
)).TrimEnd("`r", "`n")
if ($recipeIndexState -cne "H $($plan.inputs.generator_recipe.relative_path)") {
    throw 'Mesa generator recipe has hidden or unexpected index state.'
}
$recipeBlob = (Invoke-PreparationGit $checkout @(
    'rev-parse', "HEAD:$($plan.inputs.generator_recipe.relative_path)"
)).TrimEnd("`r", "`n")
if ($recipeBlob -cne $script:ExpectedRecipeBlob -or
    $recipeBlob -cne $plan.inputs.generator_recipe.git_blob) {
    throw 'Mesa generator recipe blob identity mismatch.'
}
$recipeSnapshot = Read-GswBoundedFileSnapshot -Path $recipePath `
    -Name 'Mesa generator recipe' `
    -MaximumBytes ([UInt64]$plan.bounds.maximum_recipe_bytes)
if ($recipeSnapshot.Length -ne [UInt64]$plan.inputs.generator_recipe.bytes -or
    $recipeSnapshot.Sha256 -cne $script:ExpectedRecipeSha256 -or
    $recipeSnapshot.Sha256 -cne $plan.inputs.generator_recipe.sha256) {
    throw 'Mesa generator recipe content mismatch.'
}
$normalizedRecipe = ConvertTo-NormalizedSource $recipeSnapshot.Bytes `
    'Mesa generator recipe'
$recipeText = $script:Utf8.GetString($normalizedRecipe)
$recipePaths = @(Get-RecipePaths $recipeText)
$sideOutputs = @($plan.selection.validation_side_outputs)
$allPaths = @($recipePaths) + @($sideOutputs | ForEach-Object {
    [string]$_.relative_path
})
Assert-PortablePathSet ([string[]]$allPaths) 'generated-source selection'
foreach ($absentPath in $seed.selection.generated_absent_paths) {
    if ($recipePaths -cnotcontains [string]$absentPath) {
        throw "Mesa source seed path '$absentPath' is absent from GENERATE_FILES."
    }
}
Assert-ExactGeneratedState $checkout ([string[]]$recipePaths) $sideOutputs
$sideSnapshots = @($sideOutputs | ForEach-Object {
    Assert-SideOutput $checkout $_
})

$rawOutputPath = ([string]$OutputRoot).TrimEnd([char[]]'\/')
if ([string]::IsNullOrWhiteSpace($rawOutputPath)) {
    throw 'Generated-source output root must name one non-root directory.'
}
$rawOutputLeaf = [IO.Path]::GetFileName($rawOutputPath)
if ([string]::IsNullOrWhiteSpace($rawOutputLeaf)) {
    throw 'Generated-source output root must name one non-root directory.'
}
Assert-SafeRelativePath $rawOutputLeaf 'generated-source output leaf'
$outputFullPath = [IO.Path]::GetFullPath($rawOutputPath)
$outputLeaf = [IO.Path]::GetFileName($outputFullPath)
if ($outputLeaf -cne $rawOutputLeaf) {
    throw 'Generated-source output leaf changed during path canonicalization.'
}
$outputParentPath = [IO.Path]::GetDirectoryName($outputFullPath)
if ([string]::IsNullOrWhiteSpace($outputParentPath)) {
    throw 'Generated-source output root must have an existing parent.'
}
$outputParent = Assert-OrdinaryDirectory $outputParentPath `
    'Generated-source output parent'
if (Get-Item -LiteralPath $outputFullPath -Force -ErrorAction SilentlyContinue) {
    throw 'Generated-source output root must be fresh and absent.'
}

$records = @()
[UInt64]$rawAggregate = 0
foreach ($relativePath in $recipePaths) {
    $sourcePath = Resolve-ExactContainedFile $checkout $relativePath `
        'generated recipe target'
    $snapshot = Read-GswBoundedFileSnapshot -Path $sourcePath `
        -Name "generated recipe target '$relativePath'" `
        -MaximumBytes $script:MaximumFileBytes
    $rawAggregate += [UInt64]$snapshot.Length
    if ($rawAggregate -gt $script:MaximumAggregateBytes) {
        throw 'Generated recipe targets exceed the aggregate input bound.'
    }
    $normalized = ConvertTo-NormalizedSource $snapshot.Bytes `
        "generated recipe target '$relativePath'"
    $hash = [Security.Cryptography.SHA256]::Create()
    try { [byte[]]$digestBytes = $hash.ComputeHash($normalized) }
    finally { $hash.Dispose() }
    $records += [pscustomobject]@{
        RelativePath = [string]$relativePath
        Bytes = [UInt64]$normalized.Length
        Hash = $digestBytes
        Sha256 = ([BitConverter]::ToString($digestBytes) -replace '-', '').ToLowerInvariant()
        Content = $normalized
        RawBytes = [UInt64]$snapshot.Length
        RawSha256 = [string]$snapshot.Sha256
    }
}
[string[]]$recordPaths = @($records | ForEach-Object { $_.RelativePath })
[Array]::Sort($recordPaths, [StringComparer]::Ordinal)
$recordsByPath = [Collections.Generic.Dictionary[string,object]]::new(
    [StringComparer]::Ordinal
)
foreach ($record in $records) { $recordsByPath.Add($record.RelativePath, $record) }
$orderedRecords = @($recordPaths | ForEach-Object { $recordsByPath[$_] })
$treeDescriptor = Get-TreeDescriptor $orderedRecords

$temporaryRoot = Join-Path $outputParent (
    '.retvrn99-generated-source-' + [Guid]::NewGuid().ToString('N')
)
try {
    [void][IO.Directory]::CreateDirectory($temporaryRoot)
    foreach ($record in $orderedRecords) {
        $target = [IO.Path]::GetFullPath((Join-Path $temporaryRoot (
            $record.RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)
        )))
        $temporaryPrefix = $temporaryRoot.TrimEnd([char[]]'\/') +
            [IO.Path]::DirectorySeparatorChar
        if (-not $target.StartsWith(
                $temporaryPrefix, [StringComparison]::OrdinalIgnoreCase
            )) {
            throw "Generated target '$($record.RelativePath)' escapes the temporary root."
        }
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
        $stream = [IO.File]::Open(
            $target,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None
        )
        try { $stream.Write($record.Content, 0, $record.Content.Length) }
        finally { $stream.Dispose() }
    }
    $temporaryRecords = @(Get-PublishedTreeRecords $temporaryRoot)
    Assert-RecordSetsEqual $orderedRecords $temporaryRecords 'Temporary output tree'
    $temporaryTree = Get-TreeDescriptor $temporaryRecords
    if ($temporaryTree.sha256 -cne $treeDescriptor.sha256 -or
        $temporaryTree.total_entries -ne $treeDescriptor.total_entries) {
        throw 'Temporary output tree descriptor mismatch.'
    }

    Assert-SnapshotsUnchanged $checkout $orderedRecords
    Assert-SnapshotsUnchanged $checkout $sideSnapshots
    Assert-ExactGeneratedState $checkout ([string[]]$recipePaths) $sideOutputs
    foreach ($side in $sideOutputs) { Assert-SideOutput $checkout $side | Out-Null }
    $finalRecipe = Read-GswBoundedFileSnapshot -Path $recipePath `
        -Name 'Mesa generator recipe final recheck' -MaximumBytes 1048576
    $finalPlan = Read-GswBoundedFileSnapshot -Path $planPath `
        -Name 'Mesa generated-source plan final recheck' -MaximumBytes 1048576
    $finalSchema = Read-GswBoundedFileSnapshot -Path $schemaPath `
        -Name 'generated-source plan schema final recheck' -MaximumBytes 1048576
    $finalSeed = Read-GswBoundedFileSnapshot -Path $seedPath `
        -Name 'Mesa source seed final recheck' -MaximumBytes 1048576
    $finalConfig = Read-GswBoundedFileSnapshot `
        -Path (Join-Path $checkout '.git\config') `
        -Name 'Mesa local Git config final recheck' -MaximumBytes 1048576
    $finalHead = (Invoke-PreparationGit $checkout @(
        'rev-parse', '--verify', 'HEAD'
    )).TrimEnd("`r", "`n")
    if ($finalRecipe.Sha256 -cne $recipeSnapshot.Sha256 -or
        $finalPlan.Sha256 -cne $planSnapshot.Sha256 -or
        $finalSchema.Sha256 -cne $schemaSnapshot.Sha256 -or
        $finalSeed.Sha256 -cne $seedSnapshot.Sha256 -or
        $finalConfig.Sha256 -cne $gitConfigSnapshot.Sha256 -or
        $finalHead -cne $script:ExpectedCommit) {
        throw 'A pinned input changed during generated-source preparation.'
    }
    if (Get-Item -LiteralPath $outputFullPath -Force -ErrorAction SilentlyContinue) {
        throw 'Generated-source output root appeared before atomic publication.'
    }
    [IO.Directory]::Move($temporaryRoot, $outputFullPath)
    $temporaryRoot = $null
    $publishedRecords = @(Get-PublishedTreeRecords $outputFullPath)
    Assert-RecordSetsEqual $orderedRecords $publishedRecords 'Published output tree'
    $publishedTree = Get-TreeDescriptor $publishedRecords
    if ($publishedTree.sha256 -cne $treeDescriptor.sha256) {
        throw 'Published output tree descriptor mismatch.'
    }
}
finally {
    if (-not [string]::IsNullOrWhiteSpace($temporaryRoot)) {
        Remove-PrivateTemporaryTree $temporaryRoot $outputParent
    }
}

if ($Describe) {
    $publicFiles = @($orderedRecords | ForEach-Object {
        [pscustomobject]@{
            relative_path = $_.RelativePath
            bytes = $_.Bytes
            sha256 = $_.Sha256
        }
    })
    Write-Output ([pscustomobject]@{
        _spdx = 'GPL-3.0-only'
        schema = 1
        component_commit = $script:ExpectedCommit
        files = $publicFiles
        tree = $treeDescriptor
    })
}
else {
    Write-Output (
        "Prepared {0} pinned Mesa generated sources at '{1}' ({2})." -f
            $orderedRecords.Count, $outputFullPath, $treeDescriptor.sha256
    )
}
