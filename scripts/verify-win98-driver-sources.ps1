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
. (Join-Path $PSScriptRoot 'strict-tsv.ps1')
. (Join-Path $PSScriptRoot 'bounded-git-process.ps1')
$script:GitTimeoutMilliseconds = 30000
$script:MaximumGitOutputBytes = [UInt64]4194304
$script:StrictGitUtf8 = [Text.UTF8Encoding]::new($false, $true)
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

function Get-ContainedLockMetadataPath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    if ([IO.Path]::IsPathRooted($RelativePath) -or
        $RelativePath.Contains('\') -or
        $RelativePath -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*\.json$') {
        throw "Unsafe component closure manifest '$RelativePath' in upstream lock."
    }
    foreach ($component in $RelativePath.Split('/')) {
        if ([string]::IsNullOrWhiteSpace($component) -or $component -in @('.', '..')) {
            throw "Unsafe component closure manifest '$RelativePath' in upstream lock."
        }
    }
    $rootPath = Get-FullPath $Root
    $rootPrefix = $rootPath.TrimEnd([char[]]'\\/') + [IO.Path]::DirectorySeparatorChar
    $candidate = [IO.Path]::GetFullPath((Join-Path $rootPath (
        $RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)
    )))
    if (-not $candidate.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Component closure manifest '$RelativePath' escapes the lock directory."
    }

    $current = $rootPath
    foreach ($component in $RelativePath.Split('/')) {
        $current = Join-Path $current $component
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Component closure manifest '$RelativePath' crosses a reparse point."
            }
        }
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

function Invoke-IsolatedGit {
    param(
        [Parameter(Mandatory = $true)][string]$Checkout,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$QuotePaths
    )

    $checkoutPath = Get-FullPath $Checkout
    $commands = @(Get-Command git -CommandType Application -ErrorAction Stop)
    if ($commands.Count -eq 0) {
        throw 'git is required to verify upstream source checkouts.'
    }
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = [IO.Path]::GetFullPath($commands[0].Source)
    foreach ($argument in @('-c', "safe.directory=$checkoutPath") + @(
        if ($QuotePaths) { '-c', 'core.quotePath=false' }
    ) + @('-C', $checkoutPath) + $Arguments) {
        [void]$info.ArgumentList.Add($argument)
    }
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($name in @(
        'GIT_CEILING_DIRECTORIES', 'GIT_DIR', 'GIT_WORK_TREE',
        'GIT_PREFIX', 'GIT_INDEX_FILE', 'GIT_CONFIG_GLOBAL',
        'GIT_CONFIG_SYSTEM', 'GIT_CONFIG_NOSYSTEM'
    )) {
        [void]$info.Environment.Remove($name)
    }
    foreach ($name in @($info.Environment.Keys | ForEach-Object {
        [string]$_
    })) {
        if ($name -cmatch '^GIT_CONFIG_(?:COUNT|KEY_[0-9]+|VALUE_[0-9]+)$') {
            [void]$info.Environment.Remove($name)
        }
    }
    $info.Environment['GIT_CONFIG_GLOBAL'] = 'NUL'
    $info.Environment['GIT_CONFIG_NOSYSTEM'] = '1'

    $result = Invoke-GswBoundedProcess -StartInfo $info `
        -Name 'source-verifier git' `
        -TimeoutMilliseconds $script:GitTimeoutMilliseconds `
        -MaximumStdoutBytes $script:MaximumGitOutputBytes `
        -MaximumStderrBytes $script:MaximumGitOutputBytes
    if ($result.exit_code -ne 0) {
        throw 'git failed for the selected source checkout.'
    }
    try {
        return $script:StrictGitUtf8.GetString([byte[]]$result.stdout)
    }
    catch {
        throw 'git output is not strict UTF-8.'
    }
}

function Invoke-GitText {
    param(
        [Parameter(Mandatory = $true)][string]$Checkout,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    return (Invoke-IsolatedGit $Checkout $Arguments).Trim()
}

function Invoke-GitLines {
    param(
        [Parameter(Mandatory = $true)][string]$Checkout,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $text = Invoke-IsolatedGit $Checkout $Arguments -QuotePaths
    if ($text.Length -eq 0) {
        return @()
    }
    return @($text.TrimEnd("`r", "`n") -split "`n" | ForEach-Object {
        $_.TrimEnd("`r")
    })
}

function Get-ContainedGitPath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    if ([IO.Path]::IsPathRooted($RelativePath) -or $RelativePath.Contains('\')) {
        throw "Unsafe tracked git path '$RelativePath'."
    }
    foreach ($component in $RelativePath.Split('/')) {
        if ([string]::IsNullOrWhiteSpace($component) -or
            $component -in @('.', '..') -or
            $component -match '[\x00-\x1f:*?"<>|]' -or
            $component.EndsWith('.') -or
            $component.EndsWith(' ') -or
            $component -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$') {
            throw "Unsafe tracked git path component '$component'."
        }
    }
    $rootPath = Get-FullPath $Root
    $rootPrefix = $rootPath.TrimEnd([char[]]'\/') + [IO.Path]::DirectorySeparatorChar
    $candidate = [IO.Path]::GetFullPath((Join-Path $rootPath (
        $RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)
    )))
    if (-not $candidate.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Tracked git path '$RelativePath' escapes its checkout."
    }
    return $candidate
}

function Assert-PinnedSubmodules {
    param(
        [Parameter(Mandatory = $true)][string]$Checkout,
        [Parameter(Mandatory = $true)][string]$SourceName,
        [int]$Depth = 0,
        [ref]$Count
    )

    if ($Depth -gt 8) {
        throw "Pinned source '$SourceName' exceeds the recursive submodule depth bound."
    }
    $gitlinks = @()
    foreach ($line in @(Invoke-GitLines $Checkout @('ls-files', '--cached', '--stage'))) {
        if ($line -notmatch '^(?<mode>[0-9]{6}) (?<hash>[0-9a-f]{40}) 0\t(?<path>.+)$') {
            throw "Pinned source '$SourceName' has an unsafe or unsupported git index record."
        }
        if ($Matches.mode -eq '160000') {
            $gitlinks += [pscustomobject]@{
                Hash = $Matches.hash
                RelativePath = $Matches.path
            }
        }
        elseif ($Matches.mode -notin @('100644', '100755', '120000')) {
            throw "Pinned source '$SourceName' has unsupported git mode $($Matches.mode)."
        }
    }
    if ($gitlinks.Count -gt 0 -and
        -not (Test-Path -LiteralPath (Join-Path $Checkout '.gitmodules') -PathType Leaf)) {
        throw "Pinned source '$SourceName' has a gitlink without a tracked .gitmodules file."
    }
    foreach ($gitlink in $gitlinks) {
        $Count.Value++
        if ($Count.Value -gt 64) {
            throw "Pinned source '$SourceName' exceeds the recursive submodule count bound."
        }
        $submodule = Get-ContainedGitPath $Checkout $gitlink.RelativePath
        if (-not (Test-Path -LiteralPath $submodule -PathType Container) -or
            -not (Test-Path -LiteralPath (Join-Path $submodule '.git'))) {
            throw "Pinned source '$SourceName' has an unavailable submodule '$($gitlink.RelativePath)'."
        }
        $head = Invoke-GitText $submodule @('rev-parse', 'HEAD')
        if ($head -cne $gitlink.Hash) {
            throw "Pinned source '$SourceName' has a mismatched submodule '$($gitlink.RelativePath)'."
        }
        $status = Invoke-GitText $submodule @('status', '--porcelain=v1', '--untracked-files=all')
        if ($status.Length -ne 0) {
            throw "Pinned source '$SourceName' has a dirty submodule '$($gitlink.RelativePath)'."
        }
        Assert-PinnedSubmodules -Checkout $submodule -SourceName $SourceName `
            -Depth ($Depth + 1) -Count $Count
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
    throw 'git is required to verify pinned source checkouts.'
}

$requiredColumns = @(
    'name', 'source_directory', 'repository', 'commit',
    'upstream_license', 'disposition', 'closure_manifest',
    'closure_manifest_sha256', 'scope'
)
$entries = @(Read-StrictTsvFile -Path $lockPath `
    -ExpectedHeader $requiredColumns -Name 'upstream lock' `
    -MaximumBytes 1048576 -MaximumRows 256 -MaximumLineBytes 16384 `
    -MaximumPhysicalLines 1024)

$seenNames = @{}
$seenDirectories = @{}
$seenClosureManifests = @{}
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
    if (@('planned', 'planned-component', 'reference-only') -cnotcontains $entry.disposition) {
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

    if ($entry.disposition -ceq 'planned-component') {
        if ([string]::IsNullOrWhiteSpace($entry.closure_manifest) -or
            $entry.closure_manifest_sha256 -cnotmatch '^[0-9a-f]{64}$') {
            throw "Upstream '$($entry.name)' has invalid component closure linkage."
        }
        $manifestKey = $entry.closure_manifest.ToLowerInvariant()
        if ($seenClosureManifests.ContainsKey($manifestKey)) {
            throw "Duplicate component closure manifest '$($entry.closure_manifest)'."
        }
        $manifestPath = Get-ContainedLockMetadataPath `
            -Root (Split-Path -Parent $lockPath) -RelativePath $entry.closure_manifest
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            throw "Component closure manifest not found for '$($entry.name)': $manifestPath"
        }
        if ((Get-Item -LiteralPath $manifestPath).Length -gt 4194304) {
            throw "Component closure manifest for '$($entry.name)' exceeds the size bound."
        }
        $manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($manifestHash -cne $entry.closure_manifest_sha256) {
            throw "Component closure manifest hash mismatch for '$($entry.name)'."
        }
        $seenClosureManifests[$manifestKey] = $true
    }
    elseif (-not [string]::IsNullOrEmpty($entry.closure_manifest) -or
        -not [string]::IsNullOrEmpty($entry.closure_manifest_sha256)) {
        throw "Upstream '$($entry.name)' cannot link a component closure manifest."
    }

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
    $submoduleCount = 0
    Assert-PinnedSubmodules -Checkout $checkout -SourceName $entry.name `
        -Count ([ref]$submoduleCount)
}

Write-Output "Verified $($selectedEntries.Count) immutable Windows 98 source checkouts."
