# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceRoot,

    [string]$LockFile,

    [string[]]$SourceName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
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
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    if ([IO.Path]::IsPathRooted($RelativePath) -or
        $RelativePath -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw "Unsafe source directory '$RelativePath' in upstream lock."
    }
    $rootPath = Get-FullPath $Root
    $rootPrefix = $rootPath.TrimEnd([char[]]'\/') + [IO.Path]::DirectorySeparatorChar
    $candidate = [IO.Path]::GetFullPath((Join-Path $rootPath $RelativePath))
    if (-not $candidate.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Source directory '$RelativePath' escapes the source root."
    }
    return $candidate
}

function Get-NormalizedRepository {
    param([Parameter(Mandatory = $true)][string]$Repository)

    $normalized = $Repository.Trim().TrimEnd('/')
    if ($normalized.EndsWith('.git', [StringComparison]::OrdinalIgnoreCase)) {
        $normalized = $normalized.Substring(0, $normalized.Length - 4)
    }
    return $normalized.ToLowerInvariant()
}

function Invoke-GitText {
    param(
        [Parameter(Mandatory = $true)][string]$Checkout,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $output = @(& git -C $Checkout @Arguments)
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed for '$Checkout'."
    }
    return ($output -join [Environment]::NewLine).Trim()
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
    throw 'git is required to verify pinned source checkouts.'
}

$dataLines = @(
    Get-Content -LiteralPath $lockPath |
        Where-Object { $_.Trim().Length -gt 0 -and -not $_.TrimStart().StartsWith('#') }
)
if ($dataLines.Count -lt 2) {
    throw 'The upstream lock must contain a header and at least one source row.'
}
$entries = @($dataLines | ConvertFrom-Csv -Delimiter "`t")
$requiredColumns = @(
    'name', 'source_directory', 'repository', 'commit',
    'upstream_license', 'disposition', 'scope'
)
$columns = @($entries[0].PSObject.Properties.Name)
foreach ($column in $requiredColumns) {
    if ($columns -notcontains $column) {
        throw "The upstream lock is missing '$column'."
    }
}

$seenNames = @{}
$seenDirectories = @{}
$checkoutPaths = @{}
foreach ($entry in $entries) {
    if ([string]::IsNullOrWhiteSpace($entry.name) -or $entry.name -notmatch '^[a-z0-9][a-z0-9-]*$') {
        throw "Invalid upstream name '$($entry.name)'."
    }
    if ($entry.commit -notmatch '^[0-9a-f]{40}$') {
        throw "Upstream '$($entry.name)' is not locked to a lowercase 40-character commit."
    }
    $repositoryUri = $null
    if (-not [Uri]::TryCreate(
            [string]$entry.repository,
            [UriKind]::Absolute,
            [ref]$repositoryUri
        ) -or
        $repositoryUri.Scheme -cne 'https' -or
        [string]::IsNullOrWhiteSpace($repositoryUri.Host) -or
        $repositoryUri.UserInfo.Length -ne 0 -or
        $repositoryUri.Query.Length -ne 0 -or
        $repositoryUri.Fragment.Length -ne 0) {
        throw "Upstream '$($entry.name)' must use a plain HTTPS repository URL."
    }
    if ($entry.disposition -notin @('planned', 'reference-only')) {
        throw "Upstream '$($entry.name)' has an invalid disposition."
    }
    if ($entry.upstream_license -notmatch '^[A-Za-z0-9][A-Za-z0-9.+-]*$' -or
        $entry.scope -notmatch '^[a-z0-9][a-z0-9-]*$') {
        throw "Upstream '$($entry.name)' has invalid license or scope metadata."
    }
    if ($seenNames.ContainsKey($entry.name)) {
        throw "Duplicate upstream name '$($entry.name)'."
    }
    if ($seenDirectories.ContainsKey($entry.source_directory.ToLowerInvariant())) {
        throw "Duplicate source directory '$($entry.source_directory)'."
    }
    $seenNames[$entry.name] = $true
    $seenDirectories[$entry.source_directory.ToLowerInvariant()] = $true

    $checkout = Get-ContainedPath $sourceRootPath $entry.source_directory
    $checkoutPaths[$entry.name] = $checkout
}

$selectedEntries = $entries
if ($PSBoundParameters.ContainsKey('SourceName')) {
    if ($null -eq $SourceName -or $SourceName.Count -eq 0) {
        throw 'SourceName must contain at least one allowlisted upstream name.'
    }
    $requestedNames = @{}
    foreach ($name in $SourceName) {
        if ([string]::IsNullOrWhiteSpace($name) -or $name -notmatch '^[a-z0-9][a-z0-9-]*$') {
            throw "Invalid requested upstream name '$name'."
        }
        if ($requestedNames.ContainsKey($name)) {
            throw "Duplicate requested upstream name '$name'."
        }
        if (-not $seenNames.ContainsKey($name)) {
            throw "Unknown requested upstream name '$name'."
        }
        $requestedNames[$name] = $true
    }
    $selectedEntries = @($entries | Where-Object { $requestedNames.ContainsKey($_.name) })
}

foreach ($entry in $selectedEntries) {
    $checkout = $checkoutPaths[$entry.name]
    if (-not (Test-Path -LiteralPath $checkout -PathType Container)) {
        throw "Pinned checkout is absent for '$($entry.name)': $checkout"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $checkout '.git'))) {
        throw "Pinned source '$($entry.name)' is not a Git checkout: $checkout"
    }

    $head = Invoke-GitText $checkout @('rev-parse', 'HEAD')
    if ($head -cne $entry.commit) {
        throw "Pinned source '$($entry.name)' is at $head, expected $($entry.commit)."
    }
    $origin = Invoke-GitText $checkout @('remote', 'get-url', 'origin')
    if ((Get-NormalizedRepository $origin) -cne (Get-NormalizedRepository $entry.repository)) {
        throw "Pinned source '$($entry.name)' has unexpected origin '$origin'."
    }
    $status = Invoke-GitText $checkout @('status', '--porcelain=v1', '--untracked-files=all')
    if ($status.Length -ne 0) {
        throw "Pinned source '$($entry.name)' has local changes."
    }
    $trackedGitmodules = Invoke-GitText $checkout @(
        'ls-tree', '--name-only', 'HEAD', '--', '.gitmodules'
    )
    if ($trackedGitmodules.Length -ne 0) {
        if (-not (Test-Path -LiteralPath (Join-Path $checkout '.gitmodules') -PathType Leaf)) {
            throw "Pinned source '$($entry.name)' is missing its tracked .gitmodules file."
        }
        $submodules = Invoke-GitText $checkout @('submodule', 'status', '--recursive')
        foreach ($line in @($submodules -split "`r?`n")) {
            if ($line.Length -gt 0 -and $line[0] -in @('-', '+', 'U')) {
                throw "Pinned source '$($entry.name)' has an unavailable or mismatched submodule: $line"
            }
        }
    }
}

Write-Output "Verified $($selectedEntries.Count) immutable Windows 98 source checkouts."
