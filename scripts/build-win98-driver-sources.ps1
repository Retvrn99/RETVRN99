# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [string]$SourceRoot,
    [string]$ToolchainRoot,
    [string]$OutputRoot,
    [string]$BuildPlan,
    [string]$LockFile,
    [scriptblock]$BeforeLinkedMetadataUse
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:MaximumSteps = 32
$script:MaximumToolchains = 8
$script:MaximumArguments = 128
$script:MaximumArgumentCharacters = 4096
$script:MaximumOutputs = 128
$script:MaximumBuildTreeEntries = 50000
if ([string]::IsNullOrWhiteSpace($BuildPlan)) {
    $BuildPlan = Join-Path $PSScriptRoot '..\drivers\win98\build-plan.json'
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

function Assert-JsonPropertiesAreUnique {
    param(
        [Parameter(Mandatory = $true)][Text.Json.JsonElement]$Element,
        [Parameter(Mandatory = $true)][string]$JsonPath
    )

    if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($property in $Element.EnumerateObject()) {
            if (-not $names.Add($property.Name)) {
                throw "Duplicate JSON property '$($property.Name)' at $JsonPath."
            }
            Assert-JsonPropertiesAreUnique -Element $property.Value -JsonPath "$JsonPath.$($property.Name)"
        }
    }
    elseif ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
        $index = 0
        foreach ($item in $Element.EnumerateArray()) {
            Assert-JsonPropertiesAreUnique -Element $item -JsonPath "${JsonPath}[$index]"
            $index++
        }
    }
}

function Read-StrictJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $json = [IO.File]::ReadAllText($Path)
    return Read-StrictJsonText $json $Name
}

function Read-StrictJsonText {
    param(
        [Parameter(Mandatory = $true)][string]$Json,
        [Parameter(Mandatory = $true)][string]$Name
    )

    try {
        $document = [Text.Json.JsonDocument]::Parse($Json)
    }
    catch {
        throw "Malformed $Name JSON: $($_.Exception.Message)"
    }
    try {
        Assert-JsonPropertiesAreUnique -Element $document.RootElement -JsonPath '$'
    }
    finally {
        $document.Dispose()
    }
    try {
        return $Json | ConvertFrom-Json -Depth 16
    }
    catch {
        throw "Malformed $Name JSON: $($_.Exception.Message)"
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
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$AllowRoot
    )

    if ($AllowRoot -and $RelativePath -is [string] -and $RelativePath -ceq '.') {
        return Get-FullPath $Root
    }
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
    if ($RelativePath -ceq '.') { return }
    foreach ($component in $RelativePath.Split('/')) {
        $current = Join-Path $current $component
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($null -eq $item) { break }
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Reparse-point component '$component' is not allowed in $Name."
        }
    }
}

function Assert-BuildTreeContainsNoReparsePoints {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $rootPath = Get-FullPath $Root
    $rootAttributes = [IO.File]::GetAttributes($rootPath)
    if (($rootAttributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Reparse-point root is not allowed in $Name."
    }
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($rootPath)
    [UInt64]$entryCount = 0
    while ($pending.Count -ne 0) {
        $directory = $pending.Pop()
        foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($directory)) {
            $entryCount++
            if ($entryCount -gt $script:MaximumBuildTreeEntries) {
                throw "$Name exceeds the build-tree entry bound."
            }
            $attributes = [IO.File]::GetAttributes($entry)
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Reparse points are not allowed in $Name`: $entry"
            }
            if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) {
                $pending.Push($entry)
            }
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

function Get-LinkedFileSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$PlanDirectory,
        [Parameter(Mandatory = $true)][object]$Metadata,
        [Parameter(Mandatory = $true)][string]$Name
    )

    Assert-ExactProperties $Metadata @('relative_path', 'sha256') $Name
    Assert-LowercaseHash $Metadata.sha256 "$Name sha256"
    $path = Get-ContainedPath $PlanDirectory $Metadata.relative_path $Name
    Assert-PathComponentsAreNotReparsePoints $PlanDirectory $Metadata.relative_path $Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "$Name not found: $path"
    }
    $bytes = [IO.File]::ReadAllBytes($path)
    $hash = [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($bytes)
    ).ToLowerInvariant()
    if ($hash -cne $Metadata.sha256) {
        throw "$Name failed its exact SHA-256 check."
    }
    return [pscustomobject]@{
        OriginalPath = $path
        Bytes = $bytes
        Json = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    }
}

$planPath = Get-FullPath $BuildPlan
if (-not (Test-Path -LiteralPath $planPath -PathType Leaf)) {
    throw "Windows 98 build plan not found: $planPath"
}
$plan = Read-StrictJson $planPath 'Windows 98 build plan'
$planSchema = Assert-UnsignedInteger $plan.schema 'schema'
if ($plan._spdx -cne 'GPL-3.0-only' -or $planSchema -notin @(2, 3)) {
    throw 'Unsupported or unlicensed Windows 98 build plan.'
}
if ($plan.status -cnotin @('blocked', 'ready') -or $plan.reason -isnot [string]) {
    throw 'Windows 98 build plan status or reason is invalid.'
}
if ($plan.status -eq 'blocked') {
    Assert-ExactProperties $plan @('_spdx', 'schema', 'status', 'reason', 'toolchains', 'steps') 'blocked root'
    if ([string]::IsNullOrWhiteSpace($plan.reason) -or
        $plan.toolchains -isnot [Array] -or @($plan.toolchains).Count -ne 0 -or
        $plan.steps -isnot [Array] -or @($plan.steps).Count -ne 0) {
        throw 'A blocked Windows 98 build plan must give one reason and no executable work.'
    }
    throw "Windows 98 driver build is blocked: $($plan.reason)"
}
if ($planSchema -eq 2) {
    Assert-ExactProperties $plan @(
        '_spdx', 'schema', 'status', 'reason', 'derived_source_plan',
        'toolchain_lock', 'upstream_lock', 'toolchains', 'steps'
    ) 'ready root'
}
else {
    Assert-ExactProperties $plan @(
        '_spdx', 'schema', 'status', 'reason', 'derived_source_plan',
        'toolchain_locks', 'upstream_lock', 'toolchains', 'steps'
    ) 'ready root'
}
if ($plan.reason.Length -ne 0) {
    throw 'A ready Windows 98 build plan must have an empty reason.'
}
if ([string]::IsNullOrWhiteSpace($SourceRoot) -or
    [string]::IsNullOrWhiteSpace($ToolchainRoot) -or
    [string]::IsNullOrWhiteSpace($OutputRoot)) {
    throw 'SourceRoot, ToolchainRoot, and OutputRoot are required for a ready build plan.'
}
if ($plan.toolchains -isnot [Array] -or $plan.steps -isnot [Array]) {
    throw 'Ready build-plan toolchains and steps must be arrays.'
}
$toolchains = @($plan.toolchains)
$steps = @($plan.steps)
if ($toolchains.Count -eq 0 -or $toolchains.Count -gt $script:MaximumToolchains -or
    $steps.Count -eq 0 -or $steps.Count -gt $script:MaximumSteps) {
    throw 'A ready build plan has an invalid toolchain or step count.'
}

$planDirectory = Split-Path -Parent $planPath
$derivedPlanSnapshot = Get-LinkedFileSnapshot $planDirectory $plan.derived_source_plan 'derived_source_plan'
$toolchainLockSnapshots = @{}
if ($planSchema -eq 2) {
    $toolchainLockSnapshots['default'] = Get-LinkedFileSnapshot $planDirectory $plan.toolchain_lock 'toolchain_lock'
}
else {
    if ($plan.toolchain_locks -isnot [Array] -or @($plan.toolchain_locks).Count -eq 0 -or
        @($plan.toolchain_locks).Count -gt $script:MaximumToolchains) {
        throw 'Ready schema-3 build plans require a bounded toolchain_locks array.'
    }
    foreach ($metadata in @($plan.toolchain_locks)) {
        Assert-ExactProperties $metadata @('name', 'relative_path', 'sha256') 'toolchain lock link'
        if ($metadata.name -isnot [string] -or $metadata.name -cnotmatch '^[a-z0-9][a-z0-9-]*$' -or
            $toolchainLockSnapshots.ContainsKey($metadata.name)) {
            throw "Invalid or duplicate toolchain lock link '$($metadata.name)'."
        }
        $link = [pscustomobject]@{
            relative_path = [string]$metadata.relative_path
            sha256 = [string]$metadata.sha256
        }
        $toolchainLockSnapshots[$metadata.name] = Get-LinkedFileSnapshot `
            $planDirectory $link "toolchain_lock '$($metadata.name)'"
    }
}
$upstreamLockSnapshot = Get-LinkedFileSnapshot $planDirectory $plan.upstream_lock 'upstream_lock'
$requestedLockPath = Get-FullPath $LockFile
if (-not $requestedLockPath.Equals(
        $upstreamLockSnapshot.OriginalPath, [StringComparison]::OrdinalIgnoreCase
    )) {
    throw 'LockFile must resolve to the SHA-linked upstream_lock path.'
}
$derivedPlan = Read-StrictJsonText $derivedPlanSnapshot.Json 'derived-source plan'
if ($derivedPlan.status -cne 'ready' -or $derivedPlan.recipes -isnot [Array]) {
    throw 'A ready build plan must link one ready derived-source plan.'
}
$recipeDestinations = @{}
foreach ($recipe in @($derivedPlan.recipes)) {
    if ($recipe.name -isnot [string] -or $recipe.destination_directory -isnot [string] -or
        $recipeDestinations.ContainsKey($recipe.name)) {
        throw 'The linked derived-source plan has an ambiguous recipe mapping.'
    }
    $recipeDestinations[$recipe.name] = [string]$recipe.destination_directory
}

$toolchainRootPath = Get-FullPath $ToolchainRoot
$toolchainContexts = @{}
foreach ($lockName in $toolchainLockSnapshots.Keys) {
    $snapshot = $toolchainLockSnapshots[$lockName]
    $lock = Read-StrictJsonText $snapshot.Json "toolchain lock '$lockName'"
    $lockSchema = Assert-UnsignedInteger $lock.schema "toolchain lock '$lockName' schema"
    $extractedRoot = Get-ContainedPath $toolchainRootPath $lock.extracted.relative_path "extracted toolchain '$lockName'"
    if ($lockSchema -eq 1) {
        $watcomRoot = Get-ContainedPath $extractedRoot $lock.environment.watcom_root 'WATCOM root' -AllowRoot
        $edpath = Get-ContainedPath $watcomRoot $lock.environment.edpath 'EDPATH'
        $includePaths = @(
            foreach ($relativePath in @($lock.environment.include)) {
                Get-ContainedPath $watcomRoot $relativePath 'INCLUDE path'
            }
        )
        $pathPrefixes = @(
            foreach ($relativePath in @($lock.environment.path_prefixes)) {
                Get-ContainedPath $watcomRoot $relativePath 'PATH prefix'
            }
        )
        $environment = [pscustomobject]@{
            Watcom = $watcomRoot
            Edpath = $edpath
            Include = ($includePaths -join ';')
            PathPrefixes = $pathPrefixes
        }
        $directories = @($watcomRoot, $edpath) + $includePaths + $pathPrefixes
    }
    elseif ($lockSchema -eq 2) {
        $pathPrefixes = @(
            foreach ($relativePath in @($lock.environment.path_prefixes)) {
                Get-ContainedPath $extractedRoot $relativePath 'PATH prefix'
            }
        )
        $environment = [pscustomobject]@{
            Watcom = $null
            Edpath = $null
            Include = $null
            PathPrefixes = $pathPrefixes
        }
        $directories = $pathPrefixes
    }
    else {
        throw "Unsupported linked toolchain lock schema '$lockSchema'."
    }
    foreach ($directory in $directories) {
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            throw "Locked toolchain environment directory not found: $directory"
        }
    }
    $toolchainContexts[$lockName] = [pscustomobject]@{
        Snapshot = $snapshot
        Root = $extractedRoot
        Environment = $environment
    }
}

$verifiedToolchains = @{}
foreach ($toolchain in $toolchains) {
    if ($planSchema -eq 2) {
        Assert-ExactProperties $toolchain @('name', 'relative_path', 'sha256') 'toolchain'
        $toolchainLockName = 'default'
    }
    else {
        Assert-ExactProperties $toolchain @('name', 'lock', 'relative_path', 'sha256') 'toolchain'
        $toolchainLockName = [string]$toolchain.lock
    }
    if ($toolchain.name -isnot [string] -or $toolchain.name -cnotmatch '^[a-z0-9][a-z0-9-]*$' -or
        $verifiedToolchains.ContainsKey($toolchain.name)) {
        throw "Invalid or duplicate build toolchain '$($toolchain.name)'."
    }
    if (-not $toolchainContexts.ContainsKey($toolchainLockName)) {
        throw "Build toolchain '$($toolchain.name)' references an unknown lock."
    }
    Assert-LowercaseHash $toolchain.sha256 "toolchain '$($toolchain.name)' sha256"
    $context = $toolchainContexts[$toolchainLockName]
    $executable = Get-ContainedPath $context.Root $toolchain.relative_path "toolchain '$($toolchain.name)'"
    Assert-PathComponentsAreNotReparsePoints $context.Root $toolchain.relative_path "toolchain '$($toolchain.name)'"
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        throw "Toolchain executable not found: $executable"
    }
    $actualHash = (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -cne $toolchain.sha256) {
        throw "Toolchain '$($toolchain.name)' failed SHA-256 verification."
    }
    $verifiedToolchains[$toolchain.name] = [pscustomobject]@{
        Executable = $executable
        Environment = $context.Environment
    }
}

$validatedSteps = @()
$seenSteps = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$seenOutputs = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$totalOutputs = 0
foreach ($step in $steps) {
    Assert-ExactProperties $step @(
        'name', 'recipe', 'toolchain', 'working_directory',
        'arguments', 'normalizations', 'outputs'
    ) "build step '$($step.name)'"
    if ($step.name -isnot [string] -or $step.name -cnotmatch '^[a-z0-9][a-z0-9-]*$' -or
        -not $seenSteps.Add($step.name)) {
        throw "Invalid or duplicate build step '$($step.name)'."
    }
    if ($step.recipe -isnot [string] -or -not $recipeDestinations.ContainsKey($step.recipe)) {
        throw "Build step '$($step.name)' references an unknown derived recipe."
    }
    if ($step.toolchain -isnot [string] -or -not $verifiedToolchains.ContainsKey($step.toolchain)) {
        throw "Build step '$($step.name)' references an unknown toolchain."
    }
    if ($step.arguments -isnot [Array] -or $step.normalizations -isnot [Array] -or
        $step.outputs -isnot [Array]) {
        throw "Build step '$($step.name)' arguments, normalizations, and outputs must be arrays."
    }
    $arguments = @($step.arguments)
    if ($arguments.Count -gt $script:MaximumArguments) {
        throw "Build step '$($step.name)' has too many arguments."
    }
    foreach ($argument in $arguments) {
        if ($argument -isnot [string] -or $argument.Length -gt $script:MaximumArgumentCharacters -or
            $argument.IndexOf([char]0) -ge 0 -or $argument.Contains("`r") -or $argument.Contains("`n")) {
            throw "Build step '$($step.name)' has an invalid literal argument."
        }
    }
    [void](Get-ContainedPath $planDirectory $recipeDestinations[$step.recipe] "recipe '$($step.recipe)' destination")
    $normalizationsByPath = @{}
    foreach ($normalization in @($step.normalizations)) {
        Assert-ExactProperties $normalization @('kind', 'relative_path') "build step '$($step.name)' normalization"
        if ($normalization.kind -cne 'win16-version-date') {
            throw "Build step '$($step.name)' has an unsupported normalization kind."
        }
        [void](Get-ContainedPath $planDirectory $normalization.relative_path "build step '$($step.name)' normalization")
        $normalizationKey = ([string]$normalization.relative_path).ToLowerInvariant()
        if ($normalizationsByPath.ContainsKey($normalizationKey) -or
            [IO.Path]::GetExtension([string]$normalization.relative_path) -cne '.drv') {
            throw "Build step '$($step.name)' has a duplicate or non-DRV normalization."
        }
        $normalizationsByPath[$normalizationKey] = [string]$normalization.relative_path
    }
    $outputs = @($step.outputs)
    if ($outputs.Count -eq 0 -or $totalOutputs + $outputs.Count -gt $script:MaximumOutputs) {
        throw "Build step '$($step.name)' has an invalid output count."
    }
    $totalOutputs += $outputs.Count
    $validatedOutputs = @()
    foreach ($output in $outputs) {
        Assert-ExactProperties $output @(
            'relative_path', 'bytes', 'sha256', 'origin'
        ) "build step '$($step.name)' output"
        Assert-LowercaseHash $output.sha256 "build step '$($step.name)' output sha256"
        if ($output.origin -isnot [string] -or $output.origin -cnotin @('build', 'derived')) {
            throw "Build step '$($step.name)' output has an invalid origin."
        }
        [UInt64]$expectedBytes = Assert-UnsignedInteger $output.bytes "build step '$($step.name)' output bytes"
        if ($expectedBytes -eq 0) {
            throw "Build step '$($step.name)' has a zero-byte output."
        }
        [void](Get-ContainedPath $planDirectory $output.relative_path "build step '$($step.name)' output")
        $outputKey = ([string]$output.relative_path).ToLowerInvariant()
        if (-not $seenOutputs.Add("$($step.recipe)/$outputKey")) {
            throw "Duplicate build output '$($output.relative_path)' for recipe '$($step.recipe)'."
        }
        $isDrv = [IO.Path]::GetExtension([string]$output.relative_path).Equals(
            '.drv', [StringComparison]::OrdinalIgnoreCase
        )
        if ($isDrv -ne $normalizationsByPath.ContainsKey($outputKey)) {
            throw "Every DRV output, and only a DRV output, must have one explicit Win16 normalization."
        }
        if ($output.origin -ceq 'derived' -and $normalizationsByPath.ContainsKey($outputKey)) {
            throw "A derived output cannot also be a normalization target."
        }
        $validatedOutputs += [pscustomobject]@{
            RelativePath = [string]$output.relative_path
            Bytes = $expectedBytes
            Sha256 = [string]$output.sha256
            Origin = [string]$output.origin
        }
    }
    foreach ($normalizationKey in $normalizationsByPath.Keys) {
        if (-not @($validatedOutputs | Where-Object {
                    $_.RelativePath.Equals($normalizationKey, [StringComparison]::OrdinalIgnoreCase)
                }).Count) {
            throw "Build step '$($step.name)' normalizes an undeclared output."
        }
    }
    $validatedSteps += [pscustomobject]@{
        Name = [string]$step.name
        Recipe = [string]$step.recipe
        RecipeDestination = [string]$recipeDestinations[$step.recipe]
        Toolchain = $verifiedToolchains[$step.toolchain]
        WorkingDirectory = [string]$step.working_directory
        Arguments = [string[]]$arguments
        Normalizations = @($normalizationsByPath.Values)
        Outputs = $validatedOutputs
    }
}

$sourceRootPath = Get-FullPath $SourceRoot
$outputRootPath = Get-FullPath $OutputRoot
if (Test-Path -LiteralPath $outputRootPath) {
    throw "Verified build output already exists; refusing to overwrite it: $outputRootPath"
}
$outputParent = Split-Path -Parent $outputRootPath
if (-not (Test-Path -LiteralPath $outputParent -PathType Container)) {
    [void](New-Item -ItemType Directory -Path $outputParent)
}
if (((Get-Item -LiteralPath $outputParent -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'The verified build output parent cannot be a reparse point.'
}
$temporaryRoot = Join-Path $outputParent (
    '.retvrn99-win98-build-' + [Guid]::NewGuid().ToString('N')
)
$temporaryMetadataRoot = Join-Path $outputParent (
    '.retvrn99-win98-metadata-' + [Guid]::NewGuid().ToString('N')
)
$temporaryCreated = $false
$temporaryMetadataCreated = $false
$savedEnvironment = @{}
$allResolvedOutputs = @()
try {
    [void](New-Item -ItemType Directory -Path $temporaryMetadataRoot)
    $temporaryMetadataCreated = $true
    $derivedPlanPath = Join-Path $temporaryMetadataRoot 'derived-source-plan.json'
    $upstreamLockPath = Join-Path $temporaryMetadataRoot 'upstream.lock.tsv'
    [IO.File]::WriteAllBytes($derivedPlanPath, $derivedPlanSnapshot.Bytes)
    [IO.File]::WriteAllBytes($upstreamLockPath, $upstreamLockSnapshot.Bytes)
    $temporaryToolchainLocks = @{}
    foreach ($lockName in $toolchainContexts.Keys) {
        $toolchainLockPath = Join-Path $temporaryMetadataRoot ("toolchain-$lockName.lock.json")
        [IO.File]::WriteAllBytes($toolchainLockPath, $toolchainContexts[$lockName].Snapshot.Bytes)
        $temporaryToolchainLocks[$lockName] = $toolchainLockPath
    }
    if ($null -ne $BeforeLinkedMetadataUse) {
        $firstToolchainSnapshot = $toolchainContexts[@($toolchainContexts.Keys)[0]].Snapshot
        & $BeforeLinkedMetadataUse $derivedPlanSnapshot.OriginalPath `
            $firstToolchainSnapshot.OriginalPath $upstreamLockSnapshot.OriginalPath
    }
    foreach ($lockName in $temporaryToolchainLocks.Keys) {
        & (Join-Path $PSScriptRoot 'verify-win98-driver-toolchain.ps1') `
            -ToolchainRoot $toolchainRootPath -LockFile $temporaryToolchainLocks[$lockName]
    }
    & (Join-Path $PSScriptRoot 'prepare-win98-derived-sources.ps1') `
        -SourceRoot $sourceRootPath -OutputRoot $temporaryRoot `
        -RecipePlan $derivedPlanPath -RecipeRoot $planDirectory -LockFile $upstreamLockPath
    $temporaryCreated = $true
    foreach ($name in @('WATCOM', 'EDPATH', 'INCLUDE', 'PATH')) {
        $savedEnvironment[$name] = Get-ProcessEnvironmentEntry $name
    }
    foreach ($step in $validatedSteps) {
        $stepEnvironment = $step.Toolchain.Environment
        [Environment]::SetEnvironmentVariable('WATCOM', $stepEnvironment.Watcom, 'Process')
        [Environment]::SetEnvironmentVariable('EDPATH', $stepEnvironment.Edpath, 'Process')
        [Environment]::SetEnvironmentVariable('INCLUDE', $stepEnvironment.Include, 'Process')
        $pathValue = @($stepEnvironment.PathPrefixes) -join ';'
        if ($savedEnvironment.PATH.Present -and
            -not [string]::IsNullOrEmpty([string]$savedEnvironment.PATH.Value)) {
            $pathValue += ';' + [string]$savedEnvironment.PATH.Value
        }
        [Environment]::SetEnvironmentVariable('PATH', $pathValue, 'Process')
        Assert-BuildTreeContainsNoReparsePoints $temporaryRoot 'the private build tree'
        $recipeRoot = Get-ContainedPath $temporaryRoot $step.RecipeDestination "build recipe '$($step.Recipe)'"
        $workingDirectory = Get-ContainedPath $recipeRoot $step.WorkingDirectory "build step '$($step.Name)' working directory" -AllowRoot
        Assert-PathComponentsAreNotReparsePoints $recipeRoot $step.WorkingDirectory `
            "build step '$($step.Name)' working directory"
        if (-not (Test-Path -LiteralPath $workingDirectory -PathType Container)) {
            throw "Build working directory not found: $workingDirectory"
        }
        $resolvedOutputs = @()
        foreach ($output in $step.Outputs) {
            $outputPath = Get-ContainedPath $recipeRoot $output.RelativePath "build step '$($step.Name)' output"
            if ($output.Origin -ceq 'build' -and (Test-Path -LiteralPath $outputPath)) {
                throw "Build output exists before its producing step: $outputPath"
            }
            if ($output.Origin -ceq 'derived') {
                Assert-PathComponentsAreNotReparsePoints $recipeRoot $output.RelativePath `
                    "build step '$($step.Name)' derived output"
                if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
                    throw "Derived output is absent before its verifying step: $outputPath"
                }
                $derivedOutputFile = Get-Item -LiteralPath $outputPath -Force
                $derivedOutputHash = (Get-FileHash -LiteralPath $outputPath -Algorithm SHA256).Hash.ToLowerInvariant()
                if ([UInt64]$derivedOutputFile.Length -ne $output.Bytes -or
                    $derivedOutputHash -cne $output.Sha256) {
                    throw "Derived output does not match the reviewed plan before build: $outputPath"
                }
            }
            $resolvedOutputs += [pscustomobject]@{
                Path = $outputPath
                RelativePath = $output.RelativePath
                Bytes = $output.Bytes
                Sha256 = $output.Sha256
                Origin = $output.Origin
            }
        }
        Push-Location $workingDirectory
        try {
            [string]$toolchainExecutable = $step.Toolchain.Executable
            [string[]]$stepArguments = @($step.Arguments)
            & $toolchainExecutable @stepArguments
            if ($LASTEXITCODE -ne 0) {
                throw "Build step '$($step.Name)' failed with exit code $LASTEXITCODE."
            }
        }
        finally {
            Pop-Location
        }
        foreach ($normalization in $step.Normalizations) {
            $normalizationPath = Get-ContainedPath $recipeRoot $normalization "build step '$($step.Name)' normalization"
            Assert-PathComponentsAreNotReparsePoints $recipeRoot $normalization `
                "build step '$($step.Name)' normalization"
            if (-not (Test-Path -LiteralPath $normalizationPath -PathType Leaf) -or
                ((Get-Item -LiteralPath $normalizationPath -Force).Attributes -band
                    [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Build normalization target is absent or a reparse point: $normalizationPath"
            }
            & (Join-Path $PSScriptRoot 'normalize-win16-version-date.ps1') -Path $normalizationPath
        }
        foreach ($output in $resolvedOutputs) {
            Assert-PathComponentsAreNotReparsePoints $recipeRoot $output.RelativePath `
                "build step '$($step.Name)' output"
            if (-not (Test-Path -LiteralPath $output.Path -PathType Leaf)) {
                throw "Expected build output not found: $($output.Path)"
            }
            $outputFile = Get-Item -LiteralPath $output.Path
            if (($outputFile.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Build output cannot be a reparse point: $($output.Path)"
            }
            $outputHash = (Get-FileHash -LiteralPath $output.Path -Algorithm SHA256).Hash.ToLowerInvariant()
            if ([UInt64]$outputFile.Length -ne $output.Bytes -or $outputHash -cne $output.Sha256) {
                throw "Build output '$($output.Path)' is not reproducible from the reviewed plan: actual bytes=$($outputFile.Length), sha256=$outputHash."
            }
            $output | Add-Member -NotePropertyName RecipeRoot -NotePropertyValue $recipeRoot
            $allResolvedOutputs += $output
        }
        Assert-BuildTreeContainsNoReparsePoints $temporaryRoot `
            "the private build tree after step '$($step.Name)'"
    }
    foreach ($output in $allResolvedOutputs) {
        Assert-PathComponentsAreNotReparsePoints $output.RecipeRoot $output.RelativePath `
            'final build output verification'
        if (-not (Test-Path -LiteralPath $output.Path -PathType Leaf)) {
            throw "Previously verified build output disappeared before publication: $($output.Path)"
        }
        $outputFile = Get-Item -LiteralPath $output.Path
        if (($outputFile.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Build output became a reparse point before publication: $($output.Path)"
        }
        $outputHash = (Get-FileHash -LiteralPath $output.Path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ([UInt64]$outputFile.Length -ne $output.Bytes -or $outputHash -cne $output.Sha256) {
            throw "Previously verified build output changed before publication: $($output.Path)"
        }
    }
    if (Test-Path -LiteralPath $outputRootPath) {
        throw "Verified build output appeared during the build: $outputRootPath"
    }
    Assert-BuildTreeContainsNoReparsePoints $temporaryRoot 'the final build tree'
    [IO.Directory]::Move($temporaryRoot, $outputRootPath)
    $temporaryCreated = $false
}
finally {
    foreach ($name in $savedEnvironment.Keys) {
        Restore-ProcessEnvironmentEntry $name $savedEnvironment[$name]
    }
    if ($temporaryCreated -and
        (Test-Path -LiteralPath $temporaryRoot) -and
        (Split-Path -Parent $temporaryRoot) -ceq $outputParent -and
        (Split-Path -Leaf $temporaryRoot).StartsWith('.retvrn99-win98-build-', [StringComparison]::Ordinal)) {
        Remove-PrivateTreeSafely $temporaryRoot $outputParent '.retvrn99-win98-build-'
    }
    if ($temporaryMetadataCreated -and
        (Test-Path -LiteralPath $temporaryMetadataRoot) -and
        (Split-Path -Parent $temporaryMetadataRoot) -ceq $outputParent -and
        (Split-Path -Leaf $temporaryMetadataRoot).StartsWith('.retvrn99-win98-metadata-', [StringComparison]::Ordinal)) {
        Remove-PrivateTreeSafely $temporaryMetadataRoot $outputParent '.retvrn99-win98-metadata-'
    }
}

Write-Output "Built, normalized, and verified $totalOutputs deterministic Windows 98 driver outputs."
