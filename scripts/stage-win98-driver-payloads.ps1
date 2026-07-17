# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceRoot,

    [Parameter(Mandatory = $true)]
    [string]$PayloadRoot,

    [Parameter(Mandatory = $true)]
    [string]$PayloadManifest,

    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory,

    [string]$PayloadInventory,

    [string]$LockFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($PayloadInventory)) {
    $PayloadInventory = Join-Path $PSScriptRoot '..\drivers\win98\payload-inventory.schema.tsv'
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

function Get-ContainedPath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or
        [IO.Path]::IsPathRooted($RelativePath)) {
        throw "$Label uses an unsafe relative path '$RelativePath'."
    }
    $segments = @($RelativePath -split '[\\/]')
    foreach ($segment in $segments) {
        if ([string]::IsNullOrWhiteSpace($segment) -or
            $segment -in @('.', '..') -or
            $segment -match '[\x00-\x1f:*?"<>|]' -or
            $segment.EndsWith('.') -or
            $segment.EndsWith(' ') -or
            $segment -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$') {
            throw "$Label uses an unsafe path segment '$segment'."
        }
    }
    $rootPath = Get-FullPath $Root
    $rootPrefix = $rootPath.TrimEnd([char[]]'\/') + [IO.Path]::DirectorySeparatorChar
    $candidate = [IO.Path]::GetFullPath((Join-Path $rootPath $RelativePath))
    if (-not $candidate.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label escapes its declared root."
    }
    return $candidate
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

function Get-Win9xShortAlias {
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
    $shortBase = ''
    $shortExtension = ''
    if ($direct) {
        foreach ($character in $base.ToCharArray()) {
            $converted = Convert-ToWin9xShortCharacter $character
            if ($converted -eq '_' -and $character -ne '_') {$direct = $false; break}
            $shortBase += $converted
        }
        if ($direct) {
            foreach ($character in $extension.ToCharArray()) {
                $converted = Convert-ToWin9xShortCharacter $character
                if ($converted -eq '_' -and $character -ne '_') {$direct = $false; break}
                $shortExtension += $converted
            }
        }
    }
    if (-not $direct) {
        $shortBase = ''
        foreach ($character in $base.ToCharArray()) {
            if ($shortBase.Length -ge 6) {break}
            $shortBase += Convert-ToWin9xShortCharacter $character
        }
        if ($shortBase.Length -eq 0) {$shortBase = '_'}
        $shortBase += '~1'
        $shortExtension = ''
        foreach ($character in $extension.ToCharArray()) {
            if ($shortExtension.Length -ge 3) {break}
            $shortExtension += Convert-ToWin9xShortCharacter $character
        }
    }
    return $shortBase.PadRight(8, ' ') + $shortExtension.PadRight(3, ' ')
}

function Get-Win9xAliasPrefixes {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    $prefixes = @()
    $parts = @()
    foreach ($segment in @($RelativePath -split '[\\/]')) {
        $parts += Get-Win9xShortAlias $segment
        $prefixes += ($parts -join '\')
    }
    return $prefixes
}

function Test-PayloadDestinationKind {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Kind
    )

    $extension = [IO.Path]::GetExtension($RelativePath)
    switch ($Kind) {
        'INF' { return $extension.Equals('.INF', [StringComparison]::OrdinalIgnoreCase) }
        'Catalog' { return $extension.Equals('.CAT', [StringComparison]::OrdinalIgnoreCase) }
        'Binary' {
            return @('.VXD', '.DRV', '.MPD', '.SYS', '.DLL', '.EXE') -contains $extension.ToUpperInvariant()
        }
        'Component' { return $true }
    }
    return $false
}

$manifestPath = Get-FullPath $PayloadManifest
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Payload manifest not found: $manifestPath"
}
$dataLines = @(
    Get-Content -LiteralPath $manifestPath |
        Where-Object { $_.Trim().Length -gt 0 -and -not $_.TrimStart().StartsWith('#') }
)
if ($dataLines.Count -lt 2) {
    throw 'No install-ready Windows 98 payload rows are declared; staging is blocked.'
}
$entries = @($dataLines | ConvertFrom-Csv -Delimiter "`t")
$requiredColumns = @(
    'package_id', 'source_relative_path', 'destination_relative_path', 'kind',
    'sha256', 'bytes', 'hardware_id', 'run_once_order'
)
$columns = @($entries[0].PSObject.Properties.Name)
foreach ($column in $requiredColumns) {
    if ($columns -notcontains $column) {
        throw "The payload manifest is missing '$column'."
    }
}

$payloadRootPath = Get-FullPath $PayloadRoot
if (-not (Test-Path -LiteralPath $payloadRootPath -PathType Container)) {
    throw "Payload root not found: $payloadRootPath"
}
$packageRules = @{
    'gsw-vga' = @{ HardwareId = 'PCI\VEN_FFFE&DEV_0002'; RunOnceOrder = 0 }
    'gsw-sound' = @{ HardwareId = 'PCI\VEN_FFFE&DEV_0003'; RunOnceOrder = 0 }
    'directx9-runtime' = @{ HardwareId = ''; RunOnceOrder = 100 }
    'gsw-dx9-compat' = @{ HardwareId = ''; RunOnceOrder = 200 }
}
$maxPayloadRows = 128
$maxPayloadBytes = [int64](512 * 1024 * 1024)
$maxPayloadFileBytes = [int64](256 * 1024 * 1024)
if ($entries.Count -gt $maxPayloadRows) {
    throw "Payload manifest exceeds the $maxPayloadRows-row limit."
}

$inventoryPath = Get-FullPath $PayloadInventory
if (-not (Test-Path -LiteralPath $inventoryPath -PathType Leaf)) {
    throw "Reviewed payload inventory not found: $inventoryPath"
}
$inventoryLines = @(
    Get-Content -LiteralPath $inventoryPath |
        Where-Object { $_.Trim().Length -gt 0 -and -not $_.TrimStart().StartsWith('#') }
)
if ($inventoryLines.Count -lt 2) {
    throw 'No reviewed Windows 98 payload inventory is declared; staging is blocked.'
}
$inventoryEntries = @($inventoryLines | ConvertFrom-Csv -Delimiter "`t")
if ($inventoryEntries.Count -gt $maxPayloadRows) {
    throw "Payload inventory exceeds the $maxPayloadRows-row limit."
}
$inventoryRequiredColumns = @(
    'package_id', 'destination_relative_path', 'kind', 'hardware_id', 'run_once_order'
)
$inventoryColumns = @($inventoryEntries[0].PSObject.Properties.Name)
foreach ($column in $inventoryRequiredColumns) {
    if ($inventoryColumns -notcontains $column) {
        throw "The payload inventory is missing '$column'."
    }
}

$expectedDestinations = @{}
$expectedAliases = @{}
$packageKinds = @{}
foreach ($packageId in $packageRules.Keys) {
    $packageKinds[$packageId] = @{ INF = 0; Catalog = 0; Binary = 0; Component = 0 }
}
foreach ($inventoryEntry in $inventoryEntries) {
    $packageId = [string]$inventoryEntry.package_id
    $kind = [string]$inventoryEntry.kind
    if ($packageRules.Keys -cnotcontains $packageId) {
        throw "Unknown reviewed payload package '$packageId'."
    }
    if ($kind -cnotin @('INF', 'Catalog', 'Binary', 'Component')) {
        throw "Reviewed payload '$($inventoryEntry.destination_relative_path)' has an invalid kind."
    }
    [int]$runOnceOrder = 0
    if (-not [int]::TryParse($inventoryEntry.run_once_order, [ref]$runOnceOrder)) {
        throw "Reviewed payload '$($inventoryEntry.destination_relative_path)' has invalid ordering metadata."
    }
    $rule = $packageRules[$packageId]
    if ($inventoryEntry.hardware_id -cne $rule.HardwareId -or
        $runOnceOrder -ne $rule.RunOnceOrder) {
        throw "Reviewed payload package '$packageId' violates its PCI ID or RunOnce order."
    }
    $inventoryDestination = [string]$inventoryEntry.destination_relative_path
    [void](Get-ContainedPath $payloadRootPath $inventoryDestination 'Reviewed payload destination')
    if (-not (Test-PayloadDestinationKind $inventoryDestination $kind)) {
        throw "Reviewed payload '$inventoryDestination' has an extension inconsistent with kind '$kind'."
    }
    $destinationKey = $inventoryDestination.Replace('/', '\').ToLowerInvariant()
    if ($expectedDestinations.ContainsKey($destinationKey)) {
        throw "Duplicate reviewed payload destination '$inventoryDestination'."
    }
    foreach ($priorKey in @($expectedDestinations.Keys)) {
        if ($destinationKey.StartsWith($priorKey + '\', [StringComparison]::OrdinalIgnoreCase) -or
            $priorKey.StartsWith($destinationKey + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw "Reviewed payload destination '$inventoryDestination' conflicts with an ancestor path."
        }
    }
    $longParts = @($destinationKey -split '\\')
    $longPrefixParts = @()
    $aliasPrefixes = @(Get-Win9xAliasPrefixes $inventoryDestination)
    for ($index = 0; $index -lt $aliasPrefixes.Count; $index += 1) {
        $longPrefixParts += $longParts[$index]
        $longPrefix = $longPrefixParts -join '\'
        $aliasKey = $aliasPrefixes[$index]
        if ($expectedAliases.ContainsKey($aliasKey) -and
            $expectedAliases[$aliasKey].LongPrefix -cne $longPrefix) {
            throw "Windows 9x short-name collision between '$inventoryDestination' and '$($expectedAliases[$aliasKey].Destination)'."
        }
        $expectedAliases[$aliasKey] = [PSCustomObject]@{
            LongPrefix = $longPrefix
            Destination = $inventoryDestination
        }
    }
    $expectedDestinations[$destinationKey] = [PSCustomObject]@{
        PackageId = $packageId
        Kind = $kind
        Destination = $inventoryDestination
        HardwareId = [string]$inventoryEntry.hardware_id
        RunOnceOrder = $runOnceOrder
    }
    $packageKinds[$packageId][$kind] += 1
}
foreach ($packageId in @('gsw-vga', 'gsw-sound')) {
    $kinds = $packageKinds[$packageId]
    if ($kinds.INF -ne 1 -or $kinds.Binary -lt 1 -or
        $kinds.Catalog -gt 1 -or $kinds.Component -ne 0) {
        throw "Reviewed PnP package '$packageId' must contain exactly one INF, at least one binary, at most one catalog, and no RunOnce component."
    }
}
foreach ($packageId in @('directx9-runtime', 'gsw-dx9-compat')) {
    $kinds = $packageKinds[$packageId]
    if ($kinds.Component -lt 1 -or $kinds.INF -ne 0 -or $kinds.Catalog -ne 0) {
        throw "Reviewed RunOnce package '$packageId' must contain a component and no INF or catalog."
    }
}

$seenPackages = @{}
$seenDestinations = @{}
$validated = @()
$aggregateBytes = [int64]0
foreach ($entry in $entries) {
    if ($packageRules.Keys -cnotcontains [string]$entry.package_id) {
        throw "Unknown Windows 98 payload package '$($entry.package_id)'."
    }
    if ([string]$entry.kind -cnotin @('INF', 'Catalog', 'Binary', 'Component')) {
        throw "Payload '$($entry.source_relative_path)' has an invalid kind."
    }
    if ($entry.sha256 -notmatch '^[0-9a-f]{64}$') {
        throw "Payload '$($entry.source_relative_path)' lacks an exact lowercase SHA-256."
    }
    [int64]$expectedBytes = 0
    [int]$runOnceOrder = 0
    if (-not [int64]::TryParse($entry.bytes, [ref]$expectedBytes) -or $expectedBytes -lt 1 -or
        $expectedBytes -gt $maxPayloadFileBytes -or
        -not [int]::TryParse($entry.run_once_order, [ref]$runOnceOrder)) {
        throw "Payload '$($entry.source_relative_path)' has invalid size or ordering metadata."
    }
    if ($aggregateBytes -gt $maxPayloadBytes - $expectedBytes) {
        throw "Payload manifest exceeds the $maxPayloadBytes-byte aggregate limit."
    }
    $aggregateBytes += $expectedBytes
    $rule = $packageRules[$entry.package_id]
    if ($entry.hardware_id -cne $rule.HardwareId -or $runOnceOrder -ne $rule.RunOnceOrder) {
        throw "Payload package '$($entry.package_id)' violates its PCI ID or RunOnce order."
    }

    $source = Get-ContainedPath $payloadRootPath $entry.source_relative_path 'Payload source'
    $destinationKey = $entry.destination_relative_path.Replace('/', '\').ToLowerInvariant()
    [void](Get-ContainedPath $payloadRootPath $entry.destination_relative_path 'Payload destination')
    if ($seenDestinations.ContainsKey($destinationKey)) {
        throw "Duplicate payload destination '$($entry.destination_relative_path)'."
    }
    if (-not $expectedDestinations.ContainsKey($destinationKey)) {
        throw "Payload destination '$($entry.destination_relative_path)' is not in the reviewed inventory."
    }
    $expected = $expectedDestinations[$destinationKey]
    $normalizedEntryDestination = ([string]$entry.destination_relative_path).Replace('/', '\')
    $normalizedExpectedDestination = $expected.Destination.Replace('/', '\')
    if ($normalizedEntryDestination -cne $normalizedExpectedDestination -or
        $entry.package_id -cne $expected.PackageId -or
        $entry.kind -cne $expected.Kind -or
        $entry.hardware_id -cne $expected.HardwareId -or
        $runOnceOrder -ne $expected.RunOnceOrder) {
        throw "Payload '$($entry.destination_relative_path)' does not match its reviewed inventory row."
    }
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Payload file not found: $source"
    }
    $file = Get-Item -LiteralPath $source
    $actualHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($file.Length -ne $expectedBytes -or $actualHash -cne $entry.sha256) {
        throw "Payload '$source' failed its exact size or SHA-256 check."
    }
    $seenPackages[$entry.package_id] = $true
    $seenDestinations[$destinationKey] = $true
    $validated += [PSCustomObject]@{
        Source = $source
        Destination = $expected.Destination
        Sha256 = [string]$entry.sha256
        Bytes = $expectedBytes
    }
}
foreach ($packageId in $packageRules.Keys) {
    if (-not $seenPackages.ContainsKey($packageId)) {
        throw "Required Windows 98 payload package '$packageId' is absent."
    }
}
if ($seenDestinations.Count -ne $expectedDestinations.Count) {
    $missing = @($expectedDestinations.Keys | Where-Object { -not $seenDestinations.ContainsKey($_) })
    throw "Payload manifest is incomplete; missing reviewed destination '$($expectedDestinations[$missing[0]].Destination)'."
}

& (Join-Path $PSScriptRoot 'verify-win98-driver-sources.ps1') `
    -SourceRoot $SourceRoot -LockFile $LockFile
if ($LASTEXITCODE -ne 0) {
    throw 'Pinned Windows 98 source verification failed.'
}

$outputPath = Get-FullPath $OutputDirectory
if (Test-Path -LiteralPath $outputPath) {
    throw "Output directory already exists; refusing to overwrite it: $outputPath"
}
$outputParent = Split-Path -Parent $outputPath
if (-not (Test-Path -LiteralPath $outputParent -PathType Container)) {
    [void](New-Item -ItemType Directory -Path $outputParent)
}
$temporaryPath = Join-Path $outputParent ('.retvrn99-win98-stage-' + [Guid]::NewGuid().ToString('N'))
$temporaryCreated = $false
try {
    [void](New-Item -ItemType Directory -Path $temporaryPath)
    $temporaryCreated = $true
    foreach ($payload in @($validated | Sort-Object Destination)) {
        $destination = Get-ContainedPath $temporaryPath $payload.Destination 'Staged payload destination'
        $destinationParent = Split-Path -Parent $destination
        if (-not (Test-Path -LiteralPath $destinationParent -PathType Container)) {
            [void](New-Item -ItemType Directory -Force -Path $destinationParent)
        }
        Copy-Item -LiteralPath $payload.Source -Destination $destination
        $stagedFile = Get-Item -LiteralPath $destination
        $stagedHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($stagedFile.Length -ne $payload.Bytes -or $stagedHash -cne $payload.Sha256) {
            throw "Staged payload '$destination' changed after validation."
        }
    }
    if (Test-Path -LiteralPath $outputPath) {
        throw "Output directory appeared during staging; refusing to overwrite it: $outputPath"
    }
    [IO.Directory]::Move($temporaryPath, $outputPath)
    $temporaryCreated = $false
}
catch {
    if ($temporaryCreated -and (Test-Path -LiteralPath $temporaryPath)) {
        Remove-Item -LiteralPath $temporaryPath -Recurse -Force
    }
    throw
}

Write-Output "Staged $($validated.Count) hash-verified Windows 98 payload files."
