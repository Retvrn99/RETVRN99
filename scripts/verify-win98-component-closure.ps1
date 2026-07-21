# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceRoot,

    [string]$LockFile,

    [string[]]$SourceName,

    [switch]$PolicyAudit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'strict-json.ps1')
. (Join-Path $PSScriptRoot 'strict-tsv.ps1')

$script:MaximumFiles = 20000
$script:MaximumPrefixes = 64
$script:MaximumNotices = 128
$script:MaximumLicenseEvidence = 40000
$script:MaximumEvidenceIdsPerFile = 128
$script:MaximumEvidenceRangeBytes = [UInt64]1048576
$script:MaximumAggregateEvidenceRangeBytes = [UInt64]16777216
$script:MaximumSpdxDeclarationBytes = 4096
$script:MaximumSpdxDeclarations = 128
$script:MaximumFileBytes = [UInt64]536870912
$script:MaximumAggregateBytes = [UInt64]2147483648
$script:MaximumPathBytes = 1024
$script:AllowedLicenseExpressions = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
)
foreach ($expression in @('MIT', 'LGPL-2.1-or-later')) {
    [void]$script:AllowedLicenseExpressions.Add($expression)
}
$script:V2DeclaredLicenseExpressions = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
)
foreach ($expression in @(
    'MIT',
    'LGPL-2.1-or-later',
    'BSD-2-Clause',
    'BSD-3-Clause',
    'BSL-1.0',
    'Apache-2.0',
    'LicenseRef-Mesa-SHA1-Public-Domain',
    'LicenseRef-Mesa-DbgHelp-Public-Domain',
    'LicenseRef-Mesa-Jimenez-MLAA',
    'MIT AND BSD-3-Clause',
    'MIT AND Apache-2.0',
    'GPL-2.0-only OR MIT',
    'GPL-3.0-only OR MIT',
    'GPL-2.0-only AND MIT',
    'GPL-3.0-or-later WITH Bison-exception-2.2',
    'MIT AND (GPL-3.0-or-later WITH Bison-exception-2.2)'
)) {
    [void]$script:V2DeclaredLicenseExpressions.Add($expression)
}
$script:V2ObservedLicenseExpressions = [Collections.Generic.HashSet[string]]::new(
    $script:V2DeclaredLicenseExpressions,
    [StringComparer]::Ordinal
)
foreach ($expression in @(
    'GPL-2.0-only',
    'GPL-3.0-only',
    'GPL-3.0-or-later'
)) {
    [void]$script:V2ObservedLicenseExpressions.Add($expression)
}
$script:V2SelectedLicenseExpressions = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
)
foreach ($expression in @(
    'MIT',
    'LGPL-2.1-or-later',
    'BSD-2-Clause',
    'BSD-3-Clause',
    'BSL-1.0',
    'Apache-2.0',
    'LicenseRef-Mesa-SHA1-Public-Domain',
    'LicenseRef-Mesa-DbgHelp-Public-Domain',
    'LicenseRef-Mesa-Jimenez-MLAA',
    'MIT AND BSD-3-Clause',
    'MIT AND Apache-2.0',
    'GPL-2.0-only',
    'GPL-3.0-only',
    'GPL-2.0-only AND MIT',
    'GPL-3.0-or-later',
    'GPL-3.0-or-later WITH Bison-exception-2.2',
    'MIT AND (GPL-3.0-or-later WITH Bison-exception-2.2)'
)) {
    [void]$script:V2SelectedLicenseExpressions.Add($expression)
}
$script:V2ReadyLicenseSelections = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
)
foreach ($expression in @(
    'MIT',
    'LGPL-2.1-or-later',
    'BSD-2-Clause',
    'BSD-3-Clause',
    'BSL-1.0',
    'Apache-2.0',
    'LicenseRef-Mesa-SHA1-Public-Domain',
    'LicenseRef-Mesa-DbgHelp-Public-Domain',
    'MIT AND BSD-3-Clause',
    'MIT AND Apache-2.0',
    'GPL-3.0-or-later WITH Bison-exception-2.2',
    'MIT AND (GPL-3.0-or-later WITH Bison-exception-2.2)'
)) {
    [void]$script:V2ReadyLicenseSelections.Add($expression)
}
$script:V2Roles = @(
    'source-unit',
    'compiler-dependency',
    'generator-input',
    'build-description',
    'resource'
)

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

function Get-ContainedMetadataPath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][object]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Name
    )

    Assert-SafeRelativePath $RelativePath $Name
    if ($RelativePath -cnotmatch '\.json$') {
        throw "$Name must identify a JSON file."
    }
    $rootPath = Get-FullPath $Root
    $rootPrefix = $rootPath.TrimEnd([char[]]'\\/') + [IO.Path]::DirectorySeparatorChar
    $candidate = [IO.Path]::GetFullPath((Join-Path $rootPath (
        $RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)
    )))
    if (-not $candidate.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Name escapes the lock directory."
    }

    $current = $rootPath
    foreach ($component in $RelativePath.Split('/')) {
        $current = Join-Path $current $component
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "$Name crosses a reparse point."
            }
        }
    }
    return $candidate
}

function Skip-ClosureJsonWhitespace {
    param(
        [Parameter(Mandatory = $true)][string]$Json,
        [Parameter(Mandatory = $true)][ref]$Position
    )

    while ($Position.Value -lt $Json.Length) {
        $character = $Json[$Position.Value]
        if ($character -notin @(' ', "`t", "`r", "`n")) {
            return
        }
        $Position.Value++
    }
}

function Read-ClosureJsonString {
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

function Read-ClosureJsonValue {
    param(
        [Parameter(Mandatory = $true)][string]$Json,
        [Parameter(Mandatory = $true)][ref]$Position,
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][int]$Depth
    )

    if ($Depth -gt 16) {
        throw "JSON nesting exceeds the depth bound in $Source."
    }
    Skip-ClosureJsonWhitespace $Json $Position
    if ($Position.Value -ge $Json.Length) {
        throw "Incomplete JSON value in $Source."
    }
    switch ($Json[$Position.Value]) {
        '{' {
            Read-ClosureJsonObject $Json $Position $Source $Depth
            return
        }
        '[' {
            Read-ClosureJsonArray $Json $Position $Source $Depth
            return
        }
        '"' {
            $null = Read-ClosureJsonString $Json $Position $Source
            return
        }
    }

    $start = $Position.Value
    while ($Position.Value -lt $Json.Length) {
        $character = $Json[$Position.Value]
        if ($character -in @(',', ']', '}', ' ', "`t", "`r", "`n")) {
            break
        }
        $Position.Value++
    }
    if ($Position.Value -eq $start) {
        throw "Invalid JSON value in $Source."
    }
}

function Read-ClosureJsonObject {
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
    Skip-ClosureJsonWhitespace $Json $Position
    if ($Position.Value -lt $Json.Length -and $Json[$Position.Value] -eq '}') {
        $Position.Value++
        return
    }
    while ($Position.Value -lt $Json.Length) {
        Skip-ClosureJsonWhitespace $Json $Position
        $name = [string](Read-ClosureJsonString $Json $Position $Source)
        if (-not $properties.Add($name)) {
            throw "Duplicate JSON property '$name' in $Source."
        }
        Skip-ClosureJsonWhitespace $Json $Position
        if ($Position.Value -ge $Json.Length -or $Json[$Position.Value] -ne ':') {
            throw "Missing JSON property separator in $Source."
        }
        $Position.Value++
        Read-ClosureJsonValue $Json $Position $Source ($Depth + 1)
        Skip-ClosureJsonWhitespace $Json $Position
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

function Read-ClosureJsonArray {
    param(
        [Parameter(Mandatory = $true)][string]$Json,
        [Parameter(Mandatory = $true)][ref]$Position,
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][int]$Depth
    )

    $Position.Value++
    Skip-ClosureJsonWhitespace $Json $Position
    if ($Position.Value -lt $Json.Length -and $Json[$Position.Value] -eq ']') {
        $Position.Value++
        return
    }
    while ($Position.Value -lt $Json.Length) {
        Read-ClosureJsonValue $Json $Position $Source ($Depth + 1)
        Skip-ClosureJsonWhitespace $Json $Position
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

function Read-StrictJson {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        return Read-GswStrictJsonFile -Path $Path -Name 'component closure' `
            -MaximumBytes 1048576
    }
    catch {
        throw "Malformed component closure JSON: $($_.Exception.Message)"
    }
}

function Read-ClosureSchemaVersion {
    param(
        [Parameter(Mandatory = $true)][string]$Json,
        [Parameter(Mandatory = $true)][string]$Source
    )

    $position = 0
    Skip-ClosureJsonWhitespace $json ([ref]$position)
    if ($position -ge $json.Length -or $json[$position] -ne '{') {
        throw "Malformed component closure JSON: top-level value must be an object in $Source."
    }
    $position++
    $schemaToken = $null
    while ($position -lt $json.Length) {
        Skip-ClosureJsonWhitespace $json ([ref]$position)
        if ($position -lt $json.Length -and $json[$position] -eq '}') {
            break
        }
        $name = Read-ClosureJsonString $json ([ref]$position) $Source
        Skip-ClosureJsonWhitespace $json ([ref]$position)
        if ($position -ge $json.Length -or $json[$position] -ne ':') {
            throw "Malformed component closure JSON: missing JSON property separator in $Source."
        }
        $position++
        Skip-ClosureJsonWhitespace $json ([ref]$position)
        $valueStart = $position
        Read-ClosureJsonValue $json ([ref]$position) $Source 1
        if ($name -ceq 'schema') {
            $schemaToken = $json.Substring($valueStart, $position - $valueStart).Trim()
        }
        Skip-ClosureJsonWhitespace $json ([ref]$position)
        if ($position -ge $json.Length -or $json[$position] -eq '}') {
            break
        }
        if ($json[$position] -ne ',') {
            throw "Malformed component closure JSON: invalid JSON object separator in $Source."
        }
        $position++
    }
    if ($null -eq $schemaToken -or $schemaToken -cnotmatch '^(?:0|[1-9][0-9]*)$') {
        throw 'Component closure schema must be a JSON integer.'
    }
    [UInt64]$schemaVersion = 0
    if (-not [UInt64]::TryParse($schemaToken, [ref]$schemaVersion)) {
        throw 'Component closure schema must be a non-negative 64-bit JSON integer.'
    }
    return $schemaVersion
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

function Invoke-GitLines {
    param(
        [Parameter(Mandatory = $true)][string]$Checkout,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $git = Get-ComponentClosureGitExecutable
    $output = @(& $git -c core.quotePath=false -C $Checkout @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed for '$Checkout': $($output -join ' ')"
    }
    return @($output | ForEach-Object { [string]$_ })
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

function Get-ComponentClosureGitExecutable {
    $commands = @(Get-Command git -CommandType Application -ErrorAction Stop)
    if ($commands.Count -eq 0) {
        throw 'git is required for component-closure verification.'
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

function Start-IsolatedGitProcess {
    param([Parameter(Mandatory = $true)][Diagnostics.Process]$Process)

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
        return $Process.Start()
    }
    finally {
        foreach ($name in $names) {
            Restore-ProcessEnvironmentEntry $name $saved[$name]
        }
    }
}

function Get-GitBlobDigest {
    param(
        [Parameter(Mandatory = $true)][string]$Checkout,
        [Parameter(Mandatory = $true)][string]$Blob
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Get-ComponentClosureGitExecutable
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Arguments = (@(
        '-C', $Checkout, 'cat-file', 'blob', $Blob
    ) | ForEach-Object { ConvertTo-ProcessArgument $_ }) -join ' '

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $digest = [Security.Cryptography.SHA256]::Create()
    $started = $false
    [UInt64]$length = 0
    $spdxNeedle = [Text.Encoding]::ASCII.GetBytes('SPDX-License-Identifier:')
    $spdxFailure = New-Object int[] $spdxNeedle.Length
    $spdxDeclarations = [Collections.Generic.List[object]]::new()
    $currentSpdxCapture = $null
    [Int64]$currentSpdxOffset = -1
    $currentSpdxTruncated = $false
    $spdxMatched = 0
    $failureMatched = 0
    for ($failureIndex = 1; $failureIndex -lt $spdxNeedle.Length; $failureIndex++) {
        while ($failureMatched -gt 0 -and
            $spdxNeedle[$failureIndex] -ne $spdxNeedle[$failureMatched]) {
            $failureMatched = $spdxFailure[$failureMatched - 1]
        }
        if ($spdxNeedle[$failureIndex] -eq $spdxNeedle[$failureMatched]) {
            $failureMatched++
        }
        $spdxFailure[$failureIndex] = $failureMatched
    }
    try {
        if (-not (Start-IsolatedGitProcess $process)) {
            throw "Unable to start git cat-file for '$Blob'."
        }
        $started = $true
        $errorTask = $process.StandardError.ReadToEndAsync()
        $buffer = New-Object byte[] 65536
        while (($read = $process.StandardOutput.BaseStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            [void]$digest.TransformBlock($buffer, 0, $read, $buffer, 0)
            for ($index = 0; $index -lt $read; $index++) {
                $byte = $buffer[$index]
                if ($null -ne $currentSpdxCapture) {
                    if ($byte -in @([byte]0x0a, [byte]0x0d)) {
                        if ($spdxDeclarations.Count -ge $script:MaximumSpdxDeclarations) {
                            throw "Git blob '$Blob' exceeds the SPDX declaration-count bound."
                        }
                        [void]$spdxDeclarations.Add([pscustomobject]@{
                            Offset = $currentSpdxOffset
                            ByteCount = [UInt64]$currentSpdxCapture.Length
                            Text = [Text.Encoding]::UTF8.GetString(
                                $currentSpdxCapture.ToArray()
                            )
                            Truncated = $currentSpdxTruncated
                        })
                        $currentSpdxCapture.Dispose()
                        $currentSpdxCapture = $null
                    }
                    elseif ($currentSpdxCapture.Length -lt
                        $script:MaximumSpdxDeclarationBytes) {
                        $currentSpdxCapture.WriteByte($byte)
                    }
                    else {
                        $currentSpdxTruncated = $true
                    }
                }
                while ($spdxMatched -gt 0 -and
                    $byte -ne $spdxNeedle[$spdxMatched]) {
                    $spdxMatched = $spdxFailure[$spdxMatched - 1]
                }
                if ($byte -eq $spdxNeedle[$spdxMatched]) {
                    $spdxMatched++
                }
                if ($spdxMatched -eq $spdxNeedle.Length) {
                    if ($null -ne $currentSpdxCapture) {
                        if ($spdxDeclarations.Count -ge $script:MaximumSpdxDeclarations) {
                            throw "Git blob '$Blob' exceeds the SPDX declaration-count bound."
                        }
                        [void]$spdxDeclarations.Add([pscustomobject]@{
                            Offset = $currentSpdxOffset
                            ByteCount = [UInt64]$currentSpdxCapture.Length
                            Text = [Text.Encoding]::UTF8.GetString(
                                $currentSpdxCapture.ToArray()
                            )
                            Truncated = $true
                        })
                        $currentSpdxCapture.Dispose()
                    }
                    $currentSpdxOffset = [Int64](
                        $length + [UInt64]$index + 1 - [UInt64]$spdxNeedle.Length
                    )
                    $currentSpdxCapture = [IO.MemoryStream]::new(
                        $script:MaximumSpdxDeclarationBytes
                    )
                    $currentSpdxCapture.Write($spdxNeedle, 0, $spdxNeedle.Length)
                    $currentSpdxTruncated = $false
                    $spdxMatched = $spdxFailure[$spdxMatched - 1]
                }
            }
            $length += [UInt64]$read
            if ($length -gt $script:MaximumFileBytes) {
                throw "Git blob '$Blob' exceeds the file size bound."
            }
        }
        $process.WaitForExit()
        $errorText = $errorTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "git cat-file failed for '$Blob': $errorText"
        }
        if ($null -ne $currentSpdxCapture) {
            if ($spdxDeclarations.Count -ge $script:MaximumSpdxDeclarations) {
                throw "Git blob '$Blob' exceeds the SPDX declaration-count bound."
            }
            [void]$spdxDeclarations.Add([pscustomobject]@{
                Offset = $currentSpdxOffset
                ByteCount = [UInt64]$currentSpdxCapture.Length
                Text = [Text.Encoding]::UTF8.GetString($currentSpdxCapture.ToArray())
                Truncated = $currentSpdxTruncated
            })
            $currentSpdxCapture.Dispose()
            $currentSpdxCapture = $null
        }
        [void]$digest.TransformFinalBlock((New-Object byte[] 0), 0, 0)
        return [pscustomobject]@{
            Bytes = $length
            Sha256 = ([BitConverter]::ToString($digest.Hash) -replace '-', '').ToLowerInvariant()
            SpdxDeclarations = @($spdxDeclarations)
        }
    }
    finally {
        if ($started -and -not $process.HasExited) {
            $process.Kill()
            $process.WaitForExit()
        }
        if ($null -ne $currentSpdxCapture) {
            $currentSpdxCapture.Dispose()
        }
        $digest.Dispose()
        $process.Dispose()
    }
}

function Get-GitBlobRangeDigests {
    param(
        [Parameter(Mandatory = $true)][string]$Checkout,
        [Parameter(Mandatory = $true)][string]$Blob,
        [Parameter(Mandatory = $true)][object[]]$Ranges
    )

    if ($Ranges.Count -eq 0) {
        throw "Git blob '$Blob' has no license-evidence byte ranges."
    }
    $states = [Collections.Generic.List[object]]::new()
    $seenEvidenceIds = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )
    foreach ($range in $Ranges) {
        [UInt64]$offset = $range.RangeOffset
        [UInt64]$count = $range.RangeCount
        if ($range.EvidenceId -isnot [string] -or
            -not $seenEvidenceIds.Add($range.EvidenceId) -or
            $count -eq 0 -or $count -gt $script:MaximumEvidenceRangeBytes -or
            $offset -gt $script:MaximumFileBytes -or
            $offset + $count -lt $offset -or
            $offset + $count -gt $script:MaximumFileBytes) {
            throw "Git blob '$Blob' has an invalid license-evidence byte range."
        }
        [void]$states.Add([pscustomobject]@{
            EvidenceId = [string]$range.EvidenceId
            Offset = $offset
            Count = $count
            End = $offset + $count
            Captured = [UInt64]0
            Digest = [Security.Cryptography.SHA256]::Create()
        })
    }
    $orderedStates = @($states | Sort-Object `
        @{Expression = {[UInt64]$_.Offset}}, `
        @{Expression = {[string]$_.EvidenceId}})

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Get-ComponentClosureGitExecutable
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Arguments = (@(
        '-C', $Checkout, 'cat-file', 'blob', $Blob
    ) | ForEach-Object { ConvertTo-ProcessArgument $_ }) -join ' '

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $started = $false
    [UInt64]$position = 0
    try {
        if (-not (Start-IsolatedGitProcess $process)) {
            throw "Unable to start git cat-file for '$Blob'."
        }
        $started = $true
        $errorTask = $process.StandardError.ReadToEndAsync()
        $buffer = New-Object byte[] 65536
        $active = [Collections.Generic.List[object]]::new()
        $nextState = 0
        while (($read = $process.StandardOutput.BaseStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $chunkStart = $position
            $chunkEnd = $position + [UInt64]$read
            while ($nextState -lt $orderedStates.Count -and
                [UInt64]$orderedStates[$nextState].Offset -lt $chunkEnd) {
                [void]$active.Add($orderedStates[$nextState])
                $nextState++
            }
            for ($activeIndex = $active.Count - 1; $activeIndex -ge 0; $activeIndex--) {
                $state = $active[$activeIndex]
                if ([UInt64]$state.End -le $chunkStart) {
                    $active.RemoveAt($activeIndex)
                    continue
                }
                $copyStart = $chunkStart
                if ([UInt64]$state.Offset -gt $copyStart) {
                    $copyStart = [UInt64]$state.Offset
                }
                $copyEnd = $chunkEnd
                if ([UInt64]$state.End -lt $copyEnd) {
                    $copyEnd = [UInt64]$state.End
                }
                if ($copyEnd -gt $copyStart) {
                    $bufferOffset = [int]($copyStart - $chunkStart)
                    $copyCount = [int]($copyEnd - $copyStart)
                    [void]$state.Digest.TransformBlock(
                        $buffer,
                        $bufferOffset,
                        $copyCount,
                        $buffer,
                        $bufferOffset
                    )
                    $state.Captured = [UInt64]$state.Captured + [UInt64]$copyCount
                }
                if ([UInt64]$state.End -le $chunkEnd) {
                    $active.RemoveAt($activeIndex)
                }
            }
            $position = $chunkEnd
            if ($position -gt $script:MaximumFileBytes) {
                throw "Git blob '$Blob' exceeds the file size bound."
            }
        }
        $process.WaitForExit()
        $errorText = $errorTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "git cat-file failed for '$Blob': $errorText"
        }
        $results = [Collections.Generic.Dictionary[string,string]]::new(
            [StringComparer]::Ordinal
        )
        foreach ($state in $states) {
            if ([UInt64]$state.Captured -ne [UInt64]$state.Count) {
                throw "Git blob '$Blob' license-evidence byte range exceeds the blob."
            }
            [void]$state.Digest.TransformFinalBlock((New-Object byte[] 0), 0, 0)
            $results.Add(
                $state.EvidenceId,
                (([BitConverter]::ToString($state.Digest.Hash) -replace '-', '').ToLowerInvariant())
            )
        }
        return $results
    }
    finally {
        if ($started -and -not $process.HasExited) {
            $process.Kill()
            $process.WaitForExit()
        }
        foreach ($state in $states) {
            $state.Digest.Dispose()
        }
        $process.Dispose()
    }
}

function Assert-V2PathMatchesPrefix {
    param(
        [Parameter(Mandatory = $true)][object]$Prefix,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$ComponentName,
        [Parameter(Mandatory = $true)][string]$RecordName
    )

    if ($Prefix.mode -ceq 'exact-root-files') {
        if ($RelativePath.Contains('/')) {
            throw "Component closure '$ComponentName' $RecordName '$RelativePath' escapes its exact-root prefix."
        }
    }
    elseif (-not $RelativePath.StartsWith(
            "$($Prefix.relative_path)/",
            [StringComparison]::Ordinal
        )) {
        throw "Component closure '$ComponentName' $RecordName '$RelativePath' escapes its source prefix."
    }
}

function Get-V2DerivedLicenseExpression {
    param(
        [Parameter(Mandatory = $true)][Collections.Generic.HashSet[string]]$Expressions,
        [Parameter(Mandatory = $true)][string]$ComponentName,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    if ($Expressions.Count -eq 1) {
        return @($Expressions)[0]
    }
    if ($Expressions.Count -eq 2 -and
        $Expressions.Contains('MIT') -and $Expressions.Contains('BSD-3-Clause')) {
        return 'MIT AND BSD-3-Clause'
    }
    if ($Expressions.Count -eq 2 -and
        $Expressions.Contains('MIT') -and $Expressions.Contains('Apache-2.0')) {
        return 'MIT AND Apache-2.0'
    }
    if ($Expressions.Count -eq 2 -and
        $Expressions.Contains('MIT') -and $Expressions.Contains('GPL-2.0-only')) {
        return 'GPL-2.0-only AND MIT'
    }
    if ($Expressions.Count -eq 2 -and
        $Expressions.Contains('MIT') -and
        $Expressions.Contains('GPL-3.0-or-later WITH Bison-exception-2.2')) {
        return 'MIT AND (GPL-3.0-or-later WITH Bison-exception-2.2)'
    }
    throw "Component closure '$ComponentName' file '$RelativePath' has an uncurated license-evidence combination."
}

function ConvertFrom-V2SpdxDeclaration {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$ComponentName,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    $marker = 'SPDX-License-Identifier:'
    if (-not $Text.StartsWith($marker, [StringComparison]::Ordinal)) {
        throw "Component closure '$ComponentName' file '$RelativePath' has malformed SPDX evidence."
    }
    $expression = $Text.Substring($marker.Length).Trim()
    foreach ($suffix in @('*/', '-->')) {
        if ($expression.EndsWith($suffix, [StringComparison]::Ordinal)) {
            $expression = $expression.Substring(
                0,
                $expression.Length - $suffix.Length
            ).TrimEnd()
        }
    }
    $expression = $expression -creplace 'GPL-2\.0\+', 'GPL-2.0-or-later'
    $expression = $expression -creplace 'GPL-3\.0\+', 'GPL-3.0-or-later'
    $expression = $expression -creplace 'GPL-2\.0(?![-+])', 'GPL-2.0-only'
    $expression = $expression -creplace 'GPL-3\.0(?![-+])', 'GPL-3.0-only'
    if (-not $script:V2ObservedLicenseExpressions.Contains($expression)) {
        throw "Component closure '$ComponentName' file '$RelativePath' has an uncurated SPDX expression '$expression'."
    }
    return $expression
}

function Test-V2LicenseSelection {
    param(
        [Parameter(Mandatory = $true)][string]$Declared,
        [Parameter(Mandatory = $true)][string]$Selected
    )

    switch -CaseSensitive ($Declared) {
        'GPL-2.0-only OR MIT' {
            return $Selected -cin @('GPL-2.0-only', 'MIT')
        }
        'GPL-3.0-only OR MIT' {
            return $Selected -cin @('GPL-3.0-only', 'MIT')
        }
        default {
            return $Selected -ceq $Declared
        }
    }
}

function Read-V2ComponentClosure {
    param(
        [Parameter(Mandatory = $true)][object]$Manifest,
        [Parameter(Mandatory = $true)][object]$Entry,
        [Parameter(Mandatory = $true)][bool]$AuditBlocked
    )

    $componentName = [string]$Entry.name
    Assert-ExactProperties $Manifest @(
        '_spdx', 'schema', 'status', 'reason', 'upstream_name', 'owning_commit',
        'source_prefixes', 'license_evidence', 'files'
    ) "component closure '$componentName'"
    if ($Manifest._spdx -cne 'GPL-3.0-only') {
        throw "Unsupported component closure schema for '$componentName'."
    }
    if ($Manifest.upstream_name -isnot [string] -or
        $Manifest.upstream_name -cne $componentName) {
        throw "Component closure upstream mismatch for '$componentName'."
    }
    if ($Manifest.owning_commit -isnot [string] -or
        $Manifest.owning_commit -cnotmatch '^[0-9a-f]{40}$' -or
        $Manifest.owning_commit -cne $Entry.commit) {
        throw "Component closure owning commit mismatch for '$componentName'."
    }
    if (@('blocked', 'ready') -cnotcontains $Manifest.status) {
        throw "Invalid component closure status for '$componentName'."
    }
    if ($Manifest.reason -isnot [string] -or $Manifest.reason.Length -gt 512 -or
        $Manifest.reason -match '[\x00-\x08\x0a-\x1f]') {
        throw "Invalid component closure reason for '$componentName'."
    }
    if ($Manifest.source_prefixes -isnot [Array] -or
        $Manifest.license_evidence -isnot [Array] -or
        $Manifest.files -isnot [Array]) {
        throw "Component closure arrays for '$componentName' have invalid JSON types."
    }

    $prefixes = @($Manifest.source_prefixes)
    $evidenceRows = @($Manifest.license_evidence)
    $files = @($Manifest.files)
    if ($prefixes.Count -gt $script:MaximumPrefixes -or
        $evidenceRows.Count -gt $script:MaximumLicenseEvidence -or
        $files.Count -gt $script:MaximumFiles) {
        throw "Component closure '$componentName' exceeds entry-count bounds."
    }
    if ($Manifest.status -ceq 'ready') {
        if ($Manifest.reason.Length -ne 0 -or $prefixes.Count -eq 0 -or
            $evidenceRows.Count -eq 0 -or $files.Count -eq 0) {
            throw "Ready component closure '$componentName' has invalid readiness metadata."
        }
    }
    elseif ([string]::IsNullOrWhiteSpace($Manifest.reason)) {
        throw "Blocked component closure '$componentName' must have a reason."
    }

    $prefixesById = [Collections.Generic.Dictionary[string,object]]::new(
        [StringComparer]::Ordinal
    )
    foreach ($prefix in $prefixes) {
        Assert-ExactProperties $prefix @('id', 'relative_path', 'mode') `
            "component closure '$componentName' source prefix"
        if ($prefix.id -isnot [string] -or
            $prefix.id -cnotmatch '^[a-z0-9][a-z0-9-]*$' -or
            $prefix.relative_path -isnot [string] -or
            @('subtree', 'exact-root-files') -cnotcontains $prefix.mode -or
            $prefixesById.ContainsKey($prefix.id)) {
            throw "Component closure '$componentName' has an invalid or duplicate source prefix."
        }
        if ($prefix.mode -ceq 'exact-root-files') {
            if ($prefix.relative_path -cne '.') {
                throw "Component closure '$componentName' exact-root-files prefix must use '.'."
            }
        }
        else {
            Assert-SafeRelativePath $prefix.relative_path `
                "component closure '$componentName' source prefix"
        }
        $prefixesById.Add($prefix.id, $prefix)
    }

    $evidenceById = [Collections.Generic.Dictionary[string,object]]::new(
        [StringComparer]::Ordinal
    )
    $pathIdentities = [Collections.Generic.Dictionary[string,string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $countedPaths = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $usedEvidenceIds = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )
    $usedPrefixIds = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )
    [UInt64]$aggregateBytes = 0
    [UInt64]$aggregateEvidenceRangeBytes = 0
    $validatedRecords = [Collections.Generic.List[object]]::new()
    $evidenceRecords = [Collections.Generic.List[object]]::new()
    foreach ($evidence in $evidenceRows) {
        Assert-ExactProperties $evidence @(
            'id', 'kind', 'relative_path', 'git_blob', 'bytes', 'sha256',
            'source_prefix_id', 'locator', 'observed_license_expression'
        ) "component closure '$componentName' license evidence"
        Assert-SafeRelativePath $evidence.relative_path `
            "component closure '$componentName' license evidence"
        if ($evidence.id -isnot [string] -or
            $evidence.id -cnotmatch '^[a-z0-9][a-z0-9-]*$' -or
            $evidenceById.ContainsKey($evidence.id) -or
            @('license-document', 'inline') -cnotcontains $evidence.kind -or
            $evidence.git_blob -isnot [string] -or
            $evidence.git_blob -cnotmatch '^[0-9a-f]{40}$' -or
            $evidence.sha256 -isnot [string] -or
            $evidence.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
            $evidence.source_prefix_id -isnot [string] -or
            $evidence.source_prefix_id -cnotmatch '^[a-z0-9][a-z0-9-]*$' -or
            $evidence.observed_license_expression -isnot [string] -or
            -not $script:V2ObservedLicenseExpressions.Contains(
                $evidence.observed_license_expression
            )) {
            throw "Component closure '$componentName' has invalid license-evidence metadata."
        }
        if (-not $prefixesById.ContainsKey($evidence.source_prefix_id)) {
            throw "Component closure '$componentName' license evidence '$($evidence.id)' has an unknown source prefix."
        }
        Assert-V2PathMatchesPrefix $prefixesById[$evidence.source_prefix_id] `
            $evidence.relative_path $componentName 'license evidence'
        [void]$usedPrefixIds.Add($evidence.source_prefix_id)

        $bytes = Assert-UnsignedInteger $evidence.bytes `
            "component closure '$componentName' license evidence bytes"
        if ($bytes -eq 0 -or $bytes -gt $script:MaximumFileBytes) {
            if ($bytes -eq 0) {
                throw "Component closure '$componentName' license evidence must not be empty."
            }
            throw "Component closure '$componentName' exceeds source size bounds."
        }
        $identity = "$($evidence.git_blob)|$bytes|$($evidence.sha256)"
        if ($pathIdentities.ContainsKey($evidence.relative_path)) {
            if ($pathIdentities[$evidence.relative_path] -cne $identity) {
                throw "Component closure '$componentName' has a same-path whole-blob identity mismatch for '$($evidence.relative_path)'."
            }
        }
        else {
            $pathIdentities.Add($evidence.relative_path, $identity)
        }
        if ($countedPaths.Add($evidence.relative_path)) {
            if ($aggregateBytes + $bytes -lt $aggregateBytes -or
                $aggregateBytes + $bytes -gt $script:MaximumAggregateBytes) {
                throw "Component closure '$componentName' exceeds source size bounds."
            }
            $aggregateBytes += $bytes
        }

        if ($null -eq $evidence.locator) {
            throw "Component closure '$componentName' license evidence '$($evidence.id)' has an invalid locator."
        }
        $locatorProperties = @($evidence.locator.PSObject.Properties.Name)
        if ($locatorProperties -cnotcontains 'kind' -or
            $evidence.locator.kind -isnot [string]) {
            throw "Component closure '$componentName' license evidence '$($evidence.id)' has an invalid locator."
        }
        [UInt64]$rangeOffset = 0
        [UInt64]$rangeCount = 0
        $rangeSha256 = ''
        if ($evidence.locator.kind -ceq 'whole-file') {
            Assert-ExactProperties $evidence.locator @('kind') `
                "component closure '$componentName' license evidence locator"
            if ($evidence.kind -ceq 'inline') {
                throw "Component closure '$componentName' inline evidence '$($evidence.id)' must use a byte-range locator."
            }
        }
        elseif ($evidence.locator.kind -ceq 'byte-range') {
            Assert-ExactProperties $evidence.locator @(
                'kind', 'byte_offset', 'byte_count', 'sha256'
            ) "component closure '$componentName' license evidence locator"
            $rangeOffset = Assert-UnsignedInteger $evidence.locator.byte_offset `
                "component closure '$componentName' license evidence byte offset"
            $rangeCount = Assert-UnsignedInteger $evidence.locator.byte_count `
                "component closure '$componentName' license evidence byte count"
            if ($rangeCount -eq 0 -or
                $rangeCount -gt $script:MaximumEvidenceRangeBytes -or
                $rangeOffset -gt $bytes -or
                $rangeOffset + $rangeCount -lt $rangeOffset -or
                $rangeOffset + $rangeCount -gt $bytes -or
                $evidence.locator.sha256 -isnot [string] -or
                $evidence.locator.sha256 -cnotmatch '^[0-9a-f]{64}$') {
                throw "Component closure '$componentName' license evidence '$($evidence.id)' has an invalid byte range."
            }
            if ($aggregateEvidenceRangeBytes + $rangeCount -lt
                    $aggregateEvidenceRangeBytes -or
                $aggregateEvidenceRangeBytes + $rangeCount -gt
                    $script:MaximumAggregateEvidenceRangeBytes) {
                throw "Component closure '$componentName' exceeds the aggregate license-evidence byte-range work bound."
            }
            $aggregateEvidenceRangeBytes += $rangeCount
            $rangeSha256 = [string]$evidence.locator.sha256
        }
        else {
            throw "Component closure '$componentName' license evidence '$($evidence.id)' has an invalid locator."
        }

        $evidenceRecord = [pscustomobject]@{
            RelativePath = [string]$evidence.relative_path
            GitBlob = [string]$evidence.git_blob
            Bytes = $bytes
            Sha256 = [string]$evidence.sha256
            LicenseExpression = [string]$evidence.observed_license_expression
            Kind = 'license evidence'
            EvidenceId = [string]$evidence.id
            EvidenceKind = [string]$evidence.kind
            LocatorKind = [string]$evidence.locator.kind
            RangeOffset = $rangeOffset
            RangeCount = $rangeCount
            RangeSha256 = $rangeSha256
        }
        $evidenceById.Add($evidence.id, $evidenceRecord)
        [void]$validatedRecords.Add($evidenceRecord)
        [void]$evidenceRecords.Add($evidenceRecord)
    }

    $seenFilePaths = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $fileRecords = [Collections.Generic.List[object]]::new()
    foreach ($file in $files) {
        Assert-ExactProperties $file @(
            'relative_path', 'git_blob', 'bytes', 'sha256',
            'declared_license_expression', 'selected_license_expression',
            'license_evidence_ids', 'source_prefix_id', 'roles'
        ) "component closure '$componentName' file"
        Assert-SafeRelativePath $file.relative_path `
            "component closure '$componentName' file"
        if (-not $seenFilePaths.Add($file.relative_path) -or
            $file.git_blob -isnot [string] -or
            $file.git_blob -cnotmatch '^[0-9a-f]{40}$' -or
            $file.sha256 -isnot [string] -or
            $file.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
            $file.declared_license_expression -isnot [string] -or
            -not $script:V2DeclaredLicenseExpressions.Contains(
                $file.declared_license_expression
            ) -or
            $file.selected_license_expression -isnot [string] -or
            -not $script:V2SelectedLicenseExpressions.Contains(
                $file.selected_license_expression
            ) -or
            $file.source_prefix_id -isnot [string] -or
            $file.source_prefix_id -cnotmatch '^[a-z0-9][a-z0-9-]*$') {
            throw "Component closure '$componentName' has invalid metadata for '$($file.relative_path)'."
        }
        if ($Manifest.status -ceq 'ready' -and
            ($file.relative_path -ieq 'include/git_sha1.h' -or
             $file.relative_path -ieq 'win9x/wddm_screen.h' -or
             $file.relative_path -imatch '^include/winddk(?:/|$)')) {
            throw "Ready component closure '$componentName' includes forbidden Mesa path '$($file.relative_path)'."
        }
        if (-not $prefixesById.ContainsKey($file.source_prefix_id)) {
            throw "Component closure '$componentName' file '$($file.relative_path)' has an unknown source prefix."
        }
        Assert-V2PathMatchesPrefix $prefixesById[$file.source_prefix_id] `
            $file.relative_path $componentName 'file'
        [void]$usedPrefixIds.Add($file.source_prefix_id)

        $bytes = Assert-UnsignedInteger $file.bytes `
            "component closure '$componentName' file bytes"
        if ($bytes -gt $script:MaximumFileBytes) {
            throw "Component closure '$componentName' exceeds source size bounds."
        }
        $identity = "$($file.git_blob)|$bytes|$($file.sha256)"
        if ($pathIdentities.ContainsKey($file.relative_path)) {
            if ($pathIdentities[$file.relative_path] -cne $identity) {
                throw "Component closure '$componentName' has a same-path whole-blob identity mismatch for '$($file.relative_path)'."
            }
        }
        else {
            $pathIdentities.Add($file.relative_path, $identity)
        }
        if ($countedPaths.Add($file.relative_path)) {
            if ($aggregateBytes + $bytes -lt $aggregateBytes -or
                $aggregateBytes + $bytes -gt $script:MaximumAggregateBytes) {
                throw "Component closure '$componentName' exceeds source size bounds."
            }
            $aggregateBytes += $bytes
        }

        if ($file.license_evidence_ids -isnot [Array] -or
            $file.roles -isnot [Array]) {
            throw "Component closure '$componentName' file '$($file.relative_path)' has invalid JSON arrays."
        }
        $licenseEvidenceIds = @($file.license_evidence_ids)
        $roles = @($file.roles)
        if ($licenseEvidenceIds.Count -eq 0 -or
            $licenseEvidenceIds.Count -gt $script:MaximumEvidenceIdsPerFile -or
            $roles.Count -eq 0 -or $roles.Count -gt $script:V2Roles.Count) {
            throw "Component closure '$componentName' file '$($file.relative_path)' exceeds binding bounds."
        }
        $fileEvidenceIds = [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::Ordinal
        )
        $observedExpressions = [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::Ordinal
        )
        $boundInlineEvidence = [Collections.Generic.List[object]]::new()
        foreach ($evidenceId in $licenseEvidenceIds) {
            if ($evidenceId -isnot [string] -or
                $evidenceId -cnotmatch '^[a-z0-9][a-z0-9-]*$' -or
                -not $fileEvidenceIds.Add($evidenceId)) {
                throw "Component closure '$componentName' file '$($file.relative_path)' has a duplicate or invalid license-evidence ID."
            }
            if (-not $evidenceById.ContainsKey($evidenceId)) {
                throw "Component closure '$componentName' file '$($file.relative_path)' has an unknown license-evidence ID."
            }
            $boundEvidence = $evidenceById[$evidenceId]
            [void]$usedEvidenceIds.Add($evidenceId)
            [void]$observedExpressions.Add($boundEvidence.LicenseExpression)
            if ($boundEvidence.EvidenceKind -ceq 'inline') {
                if ($boundEvidence.RelativePath -cne $file.relative_path -or
                    $boundEvidence.GitBlob -cne $file.git_blob -or
                    $boundEvidence.Bytes -ne $bytes -or
                    $boundEvidence.Sha256 -cne $file.sha256) {
                    throw "Component closure '$componentName' file '$($file.relative_path)' has inline evidence for a different whole blob."
                }
                [void]$boundInlineEvidence.Add($boundEvidence)
            }
        }
        $derivedExpression = Get-V2DerivedLicenseExpression $observedExpressions `
            $componentName $file.relative_path
        if ($file.declared_license_expression -cne $derivedExpression) {
            throw "Component closure '$componentName' file '$($file.relative_path)' declared license does not match all bound evidence."
        }
        if (-not (Test-V2LicenseSelection $file.declared_license_expression `
                $file.selected_license_expression)) {
            throw "Component closure '$componentName' file '$($file.relative_path)' has an invalid structural license selection."
        }
        if ($Manifest.status -ceq 'ready' -and
            -not $script:V2ReadyLicenseSelections.Contains(
                $file.selected_license_expression
            )) {
            throw "Ready component closure '$componentName' file '$($file.relative_path)' has an incompatible license selection."
        }

        $seenRoles = [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::Ordinal
        )
        $lastRoleIndex = -1
        foreach ($role in $roles) {
            $roleIndex = [Array]::IndexOf($script:V2Roles, $role)
            if ($role -isnot [string] -or $roleIndex -lt 0 -or
                -not $seenRoles.Add($role) -or $roleIndex -le $lastRoleIndex) {
                throw "Component closure '$componentName' file '$($file.relative_path)' has duplicate, unknown, or unordered roles."
            }
            $lastRoleIndex = $roleIndex
        }

        $fileRecord = [pscustomobject]@{
            RelativePath = [string]$file.relative_path
            GitBlob = [string]$file.git_blob
            Bytes = $bytes
            Sha256 = [string]$file.sha256
            LicenseExpression = [string]$file.selected_license_expression
            Kind = 'file'
            EvidenceId = ''
            EvidenceKind = ''
            LocatorKind = ''
            RangeOffset = [UInt64]0
            RangeCount = [UInt64]0
            RangeSha256 = ''
            BoundInlineEvidence = @($boundInlineEvidence)
        }
        [void]$validatedRecords.Add($fileRecord)
        [void]$fileRecords.Add($fileRecord)
    }

    if ($usedEvidenceIds.Count -ne $evidenceById.Count -or
        $usedPrefixIds.Count -ne $prefixesById.Count) {
        throw "Component closure '$componentName' has unused license evidence or source prefix."
    }
    if ($Manifest.status -ceq 'blocked' -and -not $AuditBlocked) {
        throw "Component closure '$componentName' is blocked: $($Manifest.reason)"
    }
    return [pscustomobject]@{
        Records = @($validatedRecords)
        EvidenceRecords = @($evidenceRecords)
        FileRecords = @($fileRecords)
        IsBlocked = $Manifest.status -ceq 'blocked'
    }
}

$lockPath = Get-FullPath $LockFile
$sourceRootPath = Get-FullPath $SourceRoot
if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
    throw "Upstream lock not found: $lockPath"
}
if (-not (Test-Path -LiteralPath $sourceRootPath -PathType Container)) {
    throw "Source root not found: $sourceRootPath"
}
if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
    throw 'git is required to verify component source closures.'
}

$requiredColumns = @(
    'name', 'source_directory', 'repository', 'commit', 'upstream_license',
    'disposition', 'closure_manifest', 'closure_manifest_sha256', 'scope'
)
$entries = @(Read-StrictTsvFile -Path $lockPath `
    -ExpectedHeader $requiredColumns -Name 'upstream lock' `
    -MaximumBytes 1048576 -MaximumRows 256 -MaximumLineBytes 16384 `
    -MaximumPhysicalLines 1024)

$entriesByName = @{}
foreach ($entry in $entries) {
    if ($entry.name -notmatch '^[a-z0-9][a-z0-9-]*$' -or
        $entriesByName.ContainsKey($entry.name)) {
        throw "Invalid or duplicate upstream name '$($entry.name)'."
    }
    $entriesByName[$entry.name] = $entry
}

$selectedEntries = @($entries | Where-Object { $_.disposition -ceq 'planned-component' })
if ($PSBoundParameters.ContainsKey('SourceName')) {
    if ($null -eq $SourceName -or $SourceName.Count -eq 0) {
        throw 'SourceName must contain at least one component upstream name.'
    }
    $requested = @{}
    foreach ($name in $SourceName) {
        if ($name -notmatch '^[a-z0-9][a-z0-9-]*$' -or $requested.ContainsKey($name)) {
            throw "Invalid or duplicate requested upstream name '$name'."
        }
        if (-not $entriesByName.ContainsKey($name)) {
            throw "Unknown requested upstream name '$name'."
        }
        if ($entriesByName[$name].disposition -cne 'planned-component') {
            throw "Requested upstream '$name' is not a planned component."
        }
        $requested[$name] = $true
    }
    $selectedEntries = @($entries | Where-Object { $requested.ContainsKey($_.name) })
}
if ($selectedEntries.Count -eq 0) {
    throw 'The upstream lock selects no planned component closures.'
}

$lockRoot = Split-Path -Parent $lockPath
$closures = [Collections.Generic.List[object]]::new()
$readyNames = [Collections.Generic.List[string]]::new()
$verificationNames = [Collections.Generic.List[string]]::new()
$seenManifests = @{}
$blockedCount = 0
foreach ($entry in $selectedEntries) {
    if ($entry.commit -cnotmatch '^[0-9a-f]{40}$') {
        throw "Invalid owning commit in the upstream lock for '$($entry.name)'."
    }
    if ($entry.closure_manifest_sha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw "Invalid component closure hash for '$($entry.name)'."
    }
    $manifestPath = Get-ContainedMetadataPath $lockRoot $entry.closure_manifest `
        "component closure manifest for '$($entry.name)'"
    $manifestKey = $manifestPath.ToLowerInvariant()
    if ($seenManifests.ContainsKey($manifestKey)) {
        throw "Duplicate component closure manifest '$($entry.closure_manifest)'."
    }
    $seenManifests[$manifestKey] = $true
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Component closure manifest not found for '$($entry.name)': $manifestPath"
    }
    try {
        $manifestSnapshot = Read-GswStrictJsonFileSnapshot -Path $manifestPath `
            -Name "component closure manifest for '$($entry.name)'" `
            -MaximumBytes 1048576
    }
    catch {
        throw "Malformed component closure JSON: $($_.Exception.Message)"
    }
    $manifestHash = $manifestSnapshot.Sha256
    if ($manifestHash -cne $entry.closure_manifest_sha256) {
        throw "Component closure manifest hash mismatch for '$($entry.name)'."
    }

    $schemaVersion = Read-ClosureSchemaVersion -Json $manifestSnapshot.Text `
        -Source $manifestPath
    $manifest = $manifestSnapshot.Value
    if (@($manifest.PSObject.Properties.Name) -cnotcontains 'schema') {
        throw "Unsupported component closure schema for '$($entry.name)'."
    }
    $convertedSchemaVersion = Assert-UnsignedInteger $manifest.schema `
        "component closure '$($entry.name)' schema"
    if ($convertedSchemaVersion -ne $schemaVersion) {
        throw "Unsupported component closure schema for '$($entry.name)'."
    }
    if ($schemaVersion -eq 2) {
        $v2Closure = Read-V2ComponentClosure $manifest $entry ([bool]$PolicyAudit)
        if ($v2Closure.IsBlocked) {
            $blockedCount++
        }
        else {
            [void]$readyNames.Add($entry.name)
        }
        [void]$verificationNames.Add($entry.name)
        [void]$closures.Add([pscustomobject]@{
            Entry = $entry
            ManifestPath = $manifestPath
            ManifestHash = $manifestHash
            Manifest = $manifest
            SchemaVersion = [UInt64]2
            VerifyRecords = $true
            Records = @($v2Closure.Records)
            EvidenceRecords = @($v2Closure.EvidenceRecords)
            FileRecords = @($v2Closure.FileRecords)
        })
        continue
    }
    if ($schemaVersion -ne 1) {
        throw "Unsupported component closure schema for '$($entry.name)'."
    }
    Assert-ExactProperties $manifest @(
        '_spdx', 'schema', 'status', 'reason', 'upstream_name', 'owning_commit',
        'source_prefixes', 'notices', 'files'
    ) "component closure '$($entry.name)'"
    if ($manifest._spdx -cne 'GPL-3.0-only' -or
        (Assert-UnsignedInteger $manifest.schema "component closure '$($entry.name)' schema") -ne 1) {
        throw "Unsupported component closure schema for '$($entry.name)'."
    }
    if ($manifest.upstream_name -isnot [string] -or
        $manifest.upstream_name -cne $entry.name) {
        throw "Component closure upstream mismatch for '$($entry.name)'."
    }
    if ($manifest.owning_commit -isnot [string] -or
        $manifest.owning_commit -cnotmatch '^[0-9a-f]{40}$' -or
        $manifest.owning_commit -cne $entry.commit) {
        throw "Component closure owning commit mismatch for '$($entry.name)'."
    }
    if (@('blocked', 'ready') -cnotcontains $manifest.status) {
        throw "Invalid component closure status for '$($entry.name)'."
    }
    if ($manifest.reason -isnot [string] -or $manifest.reason.Length -gt 512 -or
        $manifest.reason -match '[\x00-\x08\x0a-\x1f]') {
        throw "Invalid component closure reason for '$($entry.name)'."
    }
    if ($manifest.source_prefixes -isnot [Array] -or
        $manifest.notices -isnot [Array] -or
        $manifest.files -isnot [Array]) {
        throw "Component closure arrays for '$($entry.name)' have invalid JSON types."
    }
    $prefixes = @($manifest.source_prefixes)
    $notices = @($manifest.notices)
    $files = @($manifest.files)
    if ($prefixes.Count -gt $script:MaximumPrefixes -or
        $notices.Count -gt $script:MaximumNotices -or
        $files.Count -gt $script:MaximumFiles) {
        throw "Component closure '$($entry.name)' exceeds entry-count bounds."
    }

    $prefixesById = [Collections.Generic.Dictionary[string,object]]::new(
        [StringComparer]::Ordinal
    )
    foreach ($prefix in $prefixes) {
        Assert-ExactProperties $prefix @('id', 'relative_path', 'mode') `
            "component closure '$($entry.name)' source prefix"
        if ($prefix.id -isnot [string] -or $prefix.id -cnotmatch '^[a-z0-9][a-z0-9-]*$' -or
            $prefix.relative_path -isnot [string] -or
            @('subtree', 'exact-root-files') -cnotcontains $prefix.mode -or
            $prefixesById.ContainsKey($prefix.id)) {
            throw "Component closure '$($entry.name)' has an invalid or duplicate source prefix."
        }
        if ($prefix.mode -ceq 'exact-root-files') {
            if ($prefix.relative_path -cne '.') {
                throw "Component closure '$($entry.name)' exact-root-files prefix must use '.'."
            }
        }
        else {
            Assert-SafeRelativePath $prefix.relative_path `
                "component closure '$($entry.name)' source prefix"
        }
        $prefixesById.Add($prefix.id, $prefix)
    }

    if ($manifest.status -ceq 'blocked') {
        if ([string]::IsNullOrWhiteSpace($manifest.reason) -or
            $notices.Count -ne 0 -or $files.Count -ne 0) {
            throw "Blocked component closure '$($entry.name)' must have a reason, no notices, and no files."
        }
        if (-not $PolicyAudit) {
            throw "Component closure '$($entry.name)' is blocked: $($manifest.reason)"
        }
        $blockedCount++
        [void]$closures.Add([pscustomobject]@{
            Entry = $entry
            ManifestPath = $manifestPath
            ManifestHash = $manifestHash
            Manifest = $manifest
            SchemaVersion = [UInt64]1
            VerifyRecords = $false
            Records = @()
            EvidenceRecords = @()
            FileRecords = @()
        })
        continue
    }

    if ($manifest.reason.Length -ne 0 -or $prefixes.Count -eq 0 -or
        $notices.Count -eq 0 -or $files.Count -eq 0) {
        throw "Ready component closure '$($entry.name)' has invalid readiness metadata."
    }

    $seenPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $noticesById = [Collections.Generic.Dictionary[string,object]]::new(
        [StringComparer]::Ordinal
    )
    $usedNoticeIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $usedPrefixIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    [UInt64]$aggregateBytes = 0
    $validatedRecords = [Collections.Generic.List[object]]::new()
    foreach ($notice in $notices) {
        Assert-ExactProperties $notice @(
            'id', 'relative_path', 'git_blob', 'bytes', 'sha256', 'license_expression'
        ) "component closure '$($entry.name)' notice"
        Assert-SafeRelativePath $notice.relative_path `
            "component closure '$($entry.name)' notice"
        if ($notice.id -isnot [string] -or $notice.id -cnotmatch '^[a-z0-9][a-z0-9-]*$' -or
            $noticesById.ContainsKey($notice.id) -or
            -not $seenPaths.Add($notice.relative_path) -or
            $notice.relative_path -cnotmatch '(?i)(^|/)(COPYING|LICENSE|NOTICE|COPYRIGHT)(\..*)?$' -or
            $notice.git_blob -isnot [string] -or $notice.git_blob -cnotmatch '^[0-9a-f]{40}$' -or
            $notice.sha256 -isnot [string] -or $notice.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
            $notice.license_expression -isnot [string] -or
            -not $script:AllowedLicenseExpressions.Contains($notice.license_expression)) {
            throw "Component closure '$($entry.name)' has invalid notice metadata."
        }
        $bytes = Assert-UnsignedInteger $notice.bytes `
            "component closure '$($entry.name)' notice bytes"
        if ($bytes -gt $script:MaximumFileBytes -or
            $aggregateBytes + $bytes -gt $script:MaximumAggregateBytes) {
            throw "Component closure '$($entry.name)' exceeds source size bounds."
        }
        $aggregateBytes += $bytes
        $noticeRecord = [pscustomobject]@{
            RelativePath = [string]$notice.relative_path
            GitBlob = [string]$notice.git_blob
            Bytes = $bytes
            Sha256 = [string]$notice.sha256
            LicenseExpression = [string]$notice.license_expression
            Kind = 'notice'
        }
        $noticesById.Add($notice.id, $noticeRecord)
        [void]$validatedRecords.Add($noticeRecord)
    }

    foreach ($file in $files) {
        Assert-ExactProperties $file @(
            'relative_path', 'git_blob', 'bytes', 'sha256', 'license_expression',
            'notice_id', 'source_prefix_id', 'role'
        ) "component closure '$($entry.name)' file"
        Assert-SafeRelativePath $file.relative_path `
            "component closure '$($entry.name)' file"
        if (-not $seenPaths.Add($file.relative_path)) {
            throw "Component closure '$($entry.name)' has duplicate path '$($file.relative_path)'."
        }
        if ($file.git_blob -isnot [string] -or $file.git_blob -cnotmatch '^[0-9a-f]{40}$' -or
            $file.sha256 -isnot [string] -or $file.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
            $file.license_expression -isnot [string] -or
            -not $script:AllowedLicenseExpressions.Contains($file.license_expression) -or
            $file.notice_id -isnot [string] -or
            $file.notice_id -cnotmatch '^[a-z0-9][a-z0-9-]*$' -or
            $file.source_prefix_id -isnot [string] -or
            $file.source_prefix_id -cnotmatch '^[a-z0-9][a-z0-9-]*$' -or
            $file.role -isnot [string] -or $file.role -cnotmatch '^[a-z0-9][a-z0-9-]*$') {
            throw "Component closure '$($entry.name)' has invalid metadata for '$($file.relative_path)'."
        }
        if (-not $noticesById.ContainsKey($file.notice_id) -or
            $noticesById[$file.notice_id].LicenseExpression -cne $file.license_expression) {
            throw "Component closure '$($entry.name)' file '$($file.relative_path)' has invalid notice binding."
        }
        if (-not $prefixesById.ContainsKey($file.source_prefix_id)) {
            throw "Component closure '$($entry.name)' file '$($file.relative_path)' has an unknown source prefix."
        }
        [void]$usedNoticeIds.Add($file.notice_id)
        [void]$usedPrefixIds.Add($file.source_prefix_id)
        $prefix = $prefixesById[$file.source_prefix_id]
        if ($prefix.mode -ceq 'exact-root-files') {
            if ($file.relative_path.Contains('/')) {
                throw "Component closure '$($entry.name)' file '$($file.relative_path)' escapes its exact-root prefix."
            }
        }
        elseif (-not $file.relative_path.StartsWith(
                "$($prefix.relative_path)/",
                [StringComparison]::Ordinal
            )) {
            throw "Component closure '$($entry.name)' file '$($file.relative_path)' escapes its source prefix."
        }
        $bytes = Assert-UnsignedInteger $file.bytes `
            "component closure '$($entry.name)' file bytes"
        if ($bytes -gt $script:MaximumFileBytes -or
            $aggregateBytes + $bytes -gt $script:MaximumAggregateBytes) {
            throw "Component closure '$($entry.name)' exceeds source size bounds."
        }
        $aggregateBytes += $bytes
        [void]$validatedRecords.Add([pscustomobject]@{
            RelativePath = [string]$file.relative_path
            GitBlob = [string]$file.git_blob
            Bytes = $bytes
            Sha256 = [string]$file.sha256
            LicenseExpression = [string]$file.license_expression
            Kind = 'file'
        })
    }
    if ($usedNoticeIds.Count -ne $noticesById.Count -or
        $usedPrefixIds.Count -ne $prefixesById.Count) {
        throw "Ready component closure '$($entry.name)' has an unused notice or source prefix."
    }
    [void]$readyNames.Add($entry.name)
    [void]$verificationNames.Add($entry.name)
    [void]$closures.Add([pscustomobject]@{
        Entry = $entry
        ManifestPath = $manifestPath
        ManifestHash = $manifestHash
        Manifest = $manifest
        SchemaVersion = [UInt64]1
        VerifyRecords = $true
        Records = @($validatedRecords)
        EvidenceRecords = @()
        FileRecords = @()
    })
}

$sourceVerifier = Join-Path $PSScriptRoot 'verify-win98-driver-sources.ps1'
if ($verificationNames.Count -gt 0) {
    & $sourceVerifier -SourceRoot $sourceRootPath -LockFile $lockPath `
        -SourceName @($verificationNames) | Out-Null

    foreach ($closure in @($closures | Where-Object { $_.VerifyRecords })) {
        if ($closure.Entry.source_directory -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
            throw "Unsafe source directory for '$($closure.Entry.name)'."
        }
        $checkout = [IO.Path]::GetFullPath((Join-Path $sourceRootPath $closure.Entry.source_directory))
        $blobProofs = [Collections.Generic.Dictionary[string,object]]::new(
            [StringComparer]::Ordinal
        )
        $rangeRecordsByBlob = [Collections.Generic.Dictionary[string,object]]::new(
            [StringComparer]::Ordinal
        )
        foreach ($record in $closure.Records) {
            $literalPathspec = ":(top,literal)$($record.RelativePath)"
            $indexLines = @(Invoke-GitLines $checkout @(
                'ls-files', '--cached', '--stage', '--', $literalPathspec
            ))
            if ($indexLines.Count -ne 1 -or
                $indexLines[0] -notmatch '^(?<mode>[0-9]{6}) (?<hash>[0-9a-f]{40}) 0\t(?<path>.+)$' -or
                $Matches.mode -notin @('100644', '100755') -or
                $Matches.path -cne $record.RelativePath) {
                throw "Component closure '$($closure.Entry.name)' has no exact regular tracked $($record.Kind) '$($record.RelativePath)'."
            }
            if ($Matches.hash -cne $record.GitBlob) {
                throw "Component closure '$($closure.Entry.name)' git blob mismatch for '$($record.RelativePath)'."
            }
            $sizeLines = @(Invoke-GitLines $checkout @('cat-file', '-s', $record.GitBlob))
            [UInt64]$gitSize = 0
            if ($sizeLines.Count -ne 1 -or
                -not [UInt64]::TryParse($sizeLines[0], [ref]$gitSize) -or
                $gitSize -ne $record.Bytes) {
                throw "Component closure '$($closure.Entry.name)' byte count mismatch for '$($record.RelativePath)'."
            }
            if (-not $blobProofs.ContainsKey($record.GitBlob)) {
                $blobProofs.Add(
                    $record.GitBlob,
                    (Get-GitBlobDigest $checkout $record.GitBlob)
                )
            }
            $blob = $blobProofs[$record.GitBlob]
            if ($blob.Bytes -ne $record.Bytes -or $blob.Sha256 -cne $record.Sha256) {
                throw "Component closure '$($closure.Entry.name)' SHA-256 mismatch for '$($record.RelativePath)'."
            }
            if ($closure.SchemaVersion -eq 2 -and
                $record.LocatorKind -ceq 'byte-range') {
                if (-not $rangeRecordsByBlob.ContainsKey($record.GitBlob)) {
                    $rangeRecordsByBlob.Add(
                        $record.GitBlob,
                        [Collections.Generic.List[object]]::new()
                    )
                }
                [void]$rangeRecordsByBlob[$record.GitBlob].Add($record)
            }
        }
        if ($closure.SchemaVersion -eq 2) {
            foreach ($blobId in @($rangeRecordsByBlob.Keys | Sort-Object)) {
                $rangeDigests = Get-GitBlobRangeDigests $checkout $blobId `
                    @($rangeRecordsByBlob[$blobId])
                foreach ($record in $rangeRecordsByBlob[$blobId]) {
                    if ($rangeDigests[$record.EvidenceId] -cne $record.RangeSha256) {
                        throw "Component closure '$($closure.Entry.name)' byte-range SHA-256 mismatch for license evidence '$($record.EvidenceId)'."
                    }
                }
            }
            foreach ($evidenceRecord in $closure.EvidenceRecords) {
                $blob = $blobProofs[$evidenceRecord.GitBlob]
                foreach ($declaration in $blob.SpdxDeclarations) {
                    if ($declaration.Truncated) {
                        throw "Component closure '$($closure.Entry.name)' license evidence '$($evidenceRecord.EvidenceId)' has an overlong SPDX declaration."
                    }
                    $spdxStart = [UInt64]$declaration.Offset
                    $spdxEnd = $spdxStart + [UInt64]$declaration.ByteCount
                    $insideLocator = $evidenceRecord.LocatorKind -ceq 'whole-file'
                    $overlapsLocator = $insideLocator
                    if ($evidenceRecord.LocatorKind -ceq 'byte-range') {
                        $rangeEnd = $evidenceRecord.RangeOffset + $evidenceRecord.RangeCount
                        $insideLocator = $evidenceRecord.RangeOffset -le $spdxStart -and
                            $rangeEnd -ge $spdxEnd
                        $overlapsLocator = $evidenceRecord.RangeOffset -lt $spdxEnd -and
                            $rangeEnd -gt $spdxStart
                    }
                    if ($overlapsLocator -and -not $insideLocator) {
                        throw "Component closure '$($closure.Entry.name)' license evidence '$($evidenceRecord.EvidenceId)' partially covers an SPDX declaration."
                    }
                    if ($insideLocator) {
                        $normalizedExpression = ConvertFrom-V2SpdxDeclaration `
                            $declaration.Text $closure.Entry.name `
                            $evidenceRecord.RelativePath
                        if ($normalizedExpression -cne
                            $evidenceRecord.LicenseExpression) {
                            throw "Component closure '$($closure.Entry.name)' license evidence '$($evidenceRecord.EvidenceId)' SPDX declaration does not match its observed license expression."
                        }
                    }
                }
            }
            foreach ($fileRecord in $closure.FileRecords) {
                $blob = $blobProofs[$fileRecord.GitBlob]
                foreach ($declaration in $blob.SpdxDeclarations) {
                    if ($declaration.Truncated) {
                        throw "Component closure '$($closure.Entry.name)' file '$($fileRecord.RelativePath)' has an overlong SPDX declaration."
                    }
                    $normalizedExpression = ConvertFrom-V2SpdxDeclaration `
                        $declaration.Text $closure.Entry.name $fileRecord.RelativePath
                    $spdxStart = [UInt64]$declaration.Offset
                    $spdxEnd = $spdxStart + [UInt64]$declaration.ByteCount
                    $covered = $false
                    foreach ($inlineEvidence in $fileRecord.BoundInlineEvidence) {
                        $rangeEnd = $inlineEvidence.RangeOffset + $inlineEvidence.RangeCount
                        if ($inlineEvidence.RangeOffset -le $spdxStart -and
                            $rangeEnd -ge $spdxEnd -and
                            $inlineEvidence.LicenseExpression -ceq $normalizedExpression) {
                            $covered = $true
                        }
                    }
                    if (-not $covered) {
                        throw "Component closure '$($closure.Entry.name)' file '$($fileRecord.RelativePath)' has an SPDX declaration without matching bound inline evidence."
                    }
                }
            }
        }
    }

    & $sourceVerifier -SourceRoot $sourceRootPath -LockFile $lockPath `
        -SourceName @($verificationNames) | Out-Null
}

foreach ($closure in $closures) {
    $currentHash = (Get-FileHash -LiteralPath $closure.ManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($currentHash -cne $closure.ManifestHash) {
        throw "Component closure manifest changed during verification for '$($closure.Entry.name)'."
    }
}

if ($blockedCount -gt 0) {
    Write-Output (
        "Policy-audited {0} Windows 98 component closure manifests; {1} remain blocked and unusable." -f `
            $selectedEntries.Count, $blockedCount
    )
}
else {
    Write-Output "Verified $($selectedEntries.Count) ready Windows 98 component source closures."
}
