# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [string]$MediaRoot,
    [string]$LockFile,
    [switch]$RequireAll,
    [Parameter(DontShow = $true)][switch]$DefineValidatorOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'strict-json.ps1')

function Invoke-GswGraphicsQualificationMediaValidation {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][object]$Lock,
        [switch]$RequireAll,
        [switch]$ManifestOnly
    )

Assert-GswJsonExactProperties $lock @('_spdx', 'schema', 'policy', 'media') `
    'Graphics qualification media lock'
Assert-GswJsonString $lock._spdx 'Graphics qualification media lock SPDX'
Assert-GswJsonInteger $lock.schema 'Graphics qualification media lock schema'
if ([int]$lock.schema -ne 1) {
    throw 'Graphics qualification media lock schema must be 1.'
}
if ([string]$lock._spdx -cne 'GPL-3.0-only') {
    throw 'Graphics qualification media lock must declare GPL-3.0-only.'
}
Assert-GswJsonExactProperties $lock.policy @(
    'payloads_are_external',
    'redistribution_allowed',
    'guest_install_requires_explicit_authorization'
) 'Graphics qualification media policy'
Assert-GswJsonBoolean $lock.policy.payloads_are_external `
    'Graphics qualification media external-payload policy'
Assert-GswJsonBoolean $lock.policy.redistribution_allowed `
    'Graphics qualification media redistribution policy'
Assert-GswJsonBoolean $lock.policy.guest_install_requires_explicit_authorization `
    'Graphics qualification media guest-install policy'
if ($lock.policy.payloads_are_external -ne $true -or
    $lock.policy.redistribution_allowed -ne $false -or
    $lock.policy.guest_install_requires_explicit_authorization -ne $true) {
    throw 'Graphics qualification media policy must remain external-only and guest-gated.'
}

Assert-GswJsonArray $lock.media 'Graphics qualification media entries'
$entries = @($lock.media)
if ($entries.Count -eq 0) {
    throw 'Graphics qualification media lock must contain at least one entry.'
}

$ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$verified = 0
$missing = 0
foreach ($entry in $entries) {
    Assert-GswJsonExactProperties $entry @(
        'id', 'title', 'relative_path', 'bytes', 'sha256', 'source_url'
    ) 'Graphics qualification media entry'
    Assert-GswJsonString $entry.id 'Graphics qualification media id'
    Assert-GswJsonString $entry.title "Graphics qualification media '$($entry.id)' title"
    Assert-GswJsonString $entry.relative_path `
        "Graphics qualification media '$($entry.id)' path"
    Assert-GswJsonString $entry.sha256 `
        "Graphics qualification media '$($entry.id)' SHA-256"
    Assert-GswJsonString $entry.source_url `
        "Graphics qualification media '$($entry.id)' source URL"
    $id = [string]$entry.id
    $relativePath = [string]$entry.relative_path
    $sha256 = [string]$entry.sha256
    $sourceUrl = [string]$entry.source_url
    Assert-GswJsonInteger $entry.bytes "Graphics qualification media '$id' byte count"
    $bytes = [long]$entry.bytes

    if ($id -cnotmatch '^[a-z0-9][a-z0-9.-]{0,79}$' -or -not $ids.Add($id)) {
        throw "Invalid or duplicate graphics qualification media id: $id"
    }
    if ([string]::IsNullOrWhiteSpace([string]$entry.title)) {
        throw "Graphics qualification media '$id' has no title."
    }
    if ([IO.Path]::IsPathRooted($relativePath) -or
        $relativePath -match '(^|[\\/])\.\.([\\/]|$)' -or
        $relativePath -match '[\\/]' -or
        -not $paths.Add($relativePath)) {
        throw "Invalid or duplicate graphics qualification media path: $relativePath"
    }
    if ($bytes -le 0) {
        throw "Graphics qualification media '$id' has an invalid byte count."
    }
    if ($sha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw "Graphics qualification media '$id' has an invalid SHA-256."
    }
    $uri = $null
    if (-not [Uri]::TryCreate($sourceUrl, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -cne 'https') {
        throw "Graphics qualification media '$id' must have an HTTPS source URL."
    }

    if ($ManifestOnly) {
        continue
    }
    $path = Join-Path $root $relativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $missing += 1
        if ($RequireAll) {
            throw "Graphics qualification media '$id' is missing."
        }
        continue
    }
    $payloadSnapshot = Read-GswBoundedFileSnapshot -Path $path `
        -Name "Graphics qualification media '$id'" `
        -MaximumBytes ([UInt64]$bytes)
    if ([UInt64]$payloadSnapshot.Length -ne [UInt64]$bytes) {
        throw "Graphics qualification media '$id' byte count does not match its lock."
    }
    if ($payloadSnapshot.Sha256 -cne $sha256) {
        throw "Graphics qualification media '$id' SHA-256 does not match its lock."
    }
    $verified += 1
}

if ($ManifestOnly) {
    Write-Output "PASS graphics qualification media manifest-only=true locked=$($entries.Count)"
} else {
    Write-Output "PASS graphics qualification media verified=$verified missing=$missing locked=$($entries.Count)"
}
}

if ($DefineValidatorOnly) {
    return
}
if ([string]::IsNullOrWhiteSpace($MediaRoot)) {
    $MediaRoot = Join-Path $PSScriptRoot '..\.scratch\graphics-qualification\media'
}
if ([string]::IsNullOrWhiteSpace($LockFile)) {
    $LockFile = Join-Path $PSScriptRoot '..\qualification\graphics\media.lock.json'
}
$root = [IO.Path]::GetFullPath($MediaRoot)
$lockPath = [IO.Path]::GetFullPath($LockFile)
if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
    throw "Graphics qualification media lock not found: $lockPath"
}
$lockSnapshot = Read-GswStrictJsonFileSnapshot -Path $lockPath `
    -Name 'Graphics qualification media lock' -MaximumBytes 1048576
Invoke-GswGraphicsQualificationMediaValidation -Root $root `
    -Lock $lockSnapshot.Value -RequireAll:$RequireAll
