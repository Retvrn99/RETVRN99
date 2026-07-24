# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceRoot,

    [Parameter(Mandatory = $true)]
    [string]$ToolchainRoot,

    [Parameter(Mandatory = $true)]
    [string]$ProofRoot,

    [string]$RepositoryRoot,

    [string]$BuildPlanRelativePath = 'drivers/win98/build-plan.json',

    [string[]]$CandidateRelativePath = @(),

    [string[]]$AdditionalInputRelativePath = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'bounded-git-process.ps1')
. (Join-Path $PSScriptRoot 'strict-json.ps1')
. (Join-Path $PSScriptRoot 'strict-tsv.ps1')
$script:GitTimeoutMilliseconds = 30000
$script:MaximumGitOutputBytes = [UInt64]4194304
$script:StrictGitUtf8 = [Text.UTF8Encoding]::new($false, $true)

function Get-FullPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }
    return [IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$Raw
    )

    $workingPath = Get-FullPath $WorkingDirectory
    $commands = @(Get-Command git -CommandType Application -ErrorAction Stop)
    if ($commands.Count -eq 0) {
        throw 'git is required for Win98 driver EOL reproducibility.'
    }
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = [IO.Path]::GetFullPath($commands[0].Source)
    foreach ($argument in @(
        '-c', "safe.directory=$workingPath", '-C', $workingPath
    ) + $Arguments) {
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
    foreach ($name in @($info.Environment.Keys | ForEach-Object { [string]$_ })) {
        if ($name -cmatch '^GIT_CONFIG_(?:COUNT|KEY_[0-9]+|VALUE_[0-9]+)$') {
            [void]$info.Environment.Remove($name)
        }
    }
    $info.Environment['GIT_CONFIG_GLOBAL'] = 'NUL'
    $info.Environment['GIT_CONFIG_NOSYSTEM'] = '1'

    $result = Invoke-GswBoundedProcess -StartInfo $info `
        -Name 'EOL reproducibility git' `
        -TimeoutMilliseconds $script:GitTimeoutMilliseconds `
        -MaximumStdoutBytes $script:MaximumGitOutputBytes `
        -MaximumStderrBytes $script:MaximumGitOutputBytes
    try {
        $stdout = $script:StrictGitUtf8.GetString([byte[]]$result.stdout)
        $stderr = $script:StrictGitUtf8.GetString([byte[]]$result.stderr)
    }
    catch {
        throw 'EOL reproducibility git output is not strict UTF-8.'
    }
    if ($result.exit_code -ne 0) {
        throw "git $($Arguments -join ' ') failed in '$workingPath': $stderr$stdout"
    }
    if ($Raw) { return $stdout }
    if ($stdout.Length -eq 0) { return @() }
    return @($stdout.TrimEnd("`r", "`n") -split "`n" | ForEach-Object {
        $_.TrimEnd("`r")
    })
}

function Get-NormalizedRepositoryRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $normalized = $Path.Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($normalized) -or
        [IO.Path]::IsPathRooted($normalized) -or
        $normalized.StartsWith('/', [StringComparison]::Ordinal)) {
        throw "$Name must be a nonempty repository-relative path: $Path"
    }
    $segments = @($normalized.Split('/'))
    if ($segments.Count -eq 0 -or @($segments | Where-Object {
            $_ -in @('', '.', '..') -or $_ -cnotmatch '^[A-Za-z0-9._-]+$'
        }).Count -ne 0) {
        throw "$Name is not a portable contained path: $Path"
    }
    return ($segments -join '/')
}

function Assert-RegularContainedFile {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $current = [IO.Path]::GetFullPath($Root)
    $rootItem = Get-Item -LiteralPath $current
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Name has a reparse-point repository root."
    }
    $segments = $RelativePath.Split('/')
    for ($index = 0; $index -lt $segments.Count; $index++) {
        $current = Join-Path $current $segments[$index]
        if (-not (Test-Path -LiteralPath $current)) {
            throw "$Name not found: $current"
        }
        $item = Get-Item -LiteralPath $current
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Name crosses a reparse point: $current"
        }
        if ($index -lt ($segments.Count - 1) -and -not $item.PSIsContainer) {
            throw "$Name has a non-directory ancestor: $current"
        }
    }
    if (-not (Test-Path -LiteralPath $current -PathType Leaf)) {
        throw "$Name must be a regular file: $current"
    }
    return $current
}

function Assert-OrdinaryRepositoryIndexState {
    param([Parameter(Mandatory = $true)][string]$Repository)

    $raw = [string](Invoke-Git -WorkingDirectory $Repository -Arguments @(
        '-c', 'core.quotePath=false', 'ls-files', '-v', '-z', '--'
    ) -Raw)
    $records = @($raw.Split(
        [char]0, [StringSplitOptions]::RemoveEmptyEntries
    ))
    for ($index = 0; $index -lt $records.Count; $index++) {
        $record = [string]$records[$index]
        if ($record.Length -lt 3 -or $record[1] -cne [char]' ') {
            throw 'Git returned a malformed index-state record.'
        }
        $tag = [char]$record[0]
        if ([char]::IsLower($tag)) {
            throw "Repository index entry $($index + 1) has assume-unchanged state."
        }
        if ($tag -ceq [char]'S') {
            throw "Repository index entry $($index + 1) has skip-worktree state."
        }
        if ($tag -cne [char]'H') {
            throw "Repository index entry $($index + 1) has nonordinary hidden state."
        }
    }
}

function Get-CandidateChanges {
    param(
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string]$Base,
        [switch]$Cached
    )

    $arguments = @('-c', 'core.safecrlf=false', '-c', 'core.quotePath=false', 'diff')
    if ($Cached) { $arguments += '--cached' }
    $arguments += @(
        '--name-status', '-z', '--no-renames', '--no-ext-diff', '--no-textconv',
        '--diff-filter=ACDMRTUXB', $Base, '--'
    )
    $changes = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $raw = [string](Invoke-Git -WorkingDirectory $WorkingDirectory `
        -Arguments $arguments -Raw)
    $fields = @($raw.Split([char]0, [StringSplitOptions]::RemoveEmptyEntries))
    if (($fields.Count % 2) -ne 0) {
        throw 'Git returned a malformed tracked candidate status stream.'
    }
    for ($index = 0; $index -lt $fields.Count; $index += 2) {
        $status = [string]$fields[$index]
        $path = [string]$fields[$index + 1]
        if ($status -cnotin @('A', 'M')) {
            throw "Candidate changes permit only added or modified files: $status`t$path"
        }
        $normalized = Get-NormalizedRepositoryRelativePath $path 'Git candidate path'
        if (-not $seen.Add($normalized)) {
            throw "Git returned a duplicate candidate path: $normalized"
        }
        $changes.Add([pscustomobject][ordered]@{
            status = $status
            relative_path = $normalized
        })
    }

    if (-not $Cached) {
        $untrackedRaw = [string](Invoke-Git -WorkingDirectory $WorkingDirectory `
            -Arguments @(
                '-c', 'core.quotePath=false', 'ls-files', '-z', '--others',
                '--exclude-standard', '--'
            ) -Raw)
        foreach ($path in @(
            $untrackedRaw.Split([char]0, [StringSplitOptions]::RemoveEmptyEntries)
        )) {
            $normalized = Get-NormalizedRepositoryRelativePath `
                ([string]$path) 'Git untracked candidate path'
            if (-not $seen.Add($normalized)) {
                throw "Git returned a duplicate candidate path: $normalized"
            }
            $changes.Add([pscustomobject][ordered]@{
                status = 'A'
                relative_path = $normalized
            })
        }
    }

    return @($changes | Sort-Object relative_path -CaseSensitive)
}

function Get-CandidateChangeIdentity {
    param([Parameter(Mandatory = $true)][object[]]$Changes)

    return @($Changes | ForEach-Object {
        '{0}|{1}' -f [string]$_.status, [string]$_.relative_path
    })
}

function Get-CandidateFileRecords {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][object[]]$Changes
    )

    [UInt64]$aggregateBytes = 0
    $records = [Collections.Generic.List[object]]::new()
    foreach ($change in $Changes) {
        $relativePath = [string]$change.relative_path
        $fullPath = Assert-RegularContainedFile $Repository $relativePath `
            "candidate '$relativePath'"
        $stage = @(Invoke-Git $Repository @(
            '-c', 'core.quotePath=false', 'ls-files', '--stage', '--',
            ":(literal)$relativePath"
        ))
        if ([string]$change.status -ceq 'M') {
            if ($stage.Count -ne 1 -or
                [string]$stage[0] -cnotmatch '^100(?:644|755) [0-9a-f]{40,64} 0\t(.+)$' -or
                [string]$Matches[1] -cne $relativePath) {
                throw "Modified candidate is not one ordinary tracked file: $relativePath"
            }
        }
        elseif ($stage.Count -ne 0) {
            throw "Added candidate unexpectedly exists in the source index: $relativePath"
        }
        $item = Get-Item -LiteralPath $fullPath
        $aggregateBytes += [UInt64]$item.Length
        if ($aggregateBytes -gt 16777216) {
            throw 'Candidate file bytes exceed the 16777216-byte aggregate bound.'
        }
        $records.Add([pscustomobject][ordered]@{
            status = [string]$change.status
            relative_path = $relativePath
            bytes = [UInt64]$item.Length
            sha256 = (
                Get-FileHash -LiteralPath $fullPath -Algorithm SHA256
            ).Hash.ToLowerInvariant()
        })
    }
    return @($records)
}

function Get-CandidateRecordIdentity {
    param([Parameter(Mandatory = $true)][object[]]$Records)

    return @($Records | ForEach-Object {
        '{0}|{1}|{2}|{3}' -f $_.status, $_.relative_path, $_.bytes, $_.sha256
    })
}

function Get-RepositoryIndexSnapshot {
    param([Parameter(Mandatory = $true)][string]$Repository)

    $indexPath = [string](Invoke-Git $Repository @(
        'rev-parse', '--path-format=absolute', '--git-path', 'index'
    ) | Select-Object -Last 1)
    $indexPath = [IO.Path]::GetFullPath($indexPath)
    if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) {
        throw "Repository index not found: $indexPath"
    }
    $item = Get-Item -LiteralPath $indexPath
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Repository index must not be a reparse point.'
    }
    return [pscustomobject][ordered]@{
        path = $indexPath
        bytes = [UInt64]$item.Length
        sha256 = (
            Get-FileHash -LiteralPath $indexPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
    }
}

function Assert-RepositoryIndexUnchanged {
    param(
        [Parameter(Mandatory = $true)]$Before,
        [Parameter(Mandatory = $true)][string]$Repository
    )

    $after = Get-RepositoryIndexSnapshot $Repository
    if ([string]$after.path -cne [string]$Before.path -or
        [UInt64]$after.bytes -ne [UInt64]$Before.bytes -or
        [string]$after.sha256 -cne [string]$Before.sha256) {
        throw 'The source repository index changed during the proof.'
    }
}

function Get-OrCreateSafeCaptureDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$CaptureRoot,
        [Parameter(Mandatory = $true)][string]$RelativeFilePath
    )

    $current = [IO.Path]::GetFullPath($CaptureRoot)
    $rootItem = Get-Item -LiteralPath $current
    if (-not $rootItem.PSIsContainer -or
        ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Candidate capture root must be an ordinary directory.'
    }
    $segments = @($RelativeFilePath.Split('/'))
    for ($index = 0; $index -lt ($segments.Count - 1); $index++) {
        $current = Join-Path $current $segments[$index]
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current
            if (-not $item.PSIsContainer -or
                ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Candidate capture crosses an unsafe ancestor: $current"
            }
        }
        else {
            [void](New-Item -ItemType Directory -Path $current)
        }
    }
    return $current
}

function New-CandidateCapture {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string]$Commit,
        [Parameter(Mandatory = $true)][string]$CaptureRoot,
        [Parameter(Mandatory = $true)][string]$PatchPath,
        [Parameter(Mandatory = $true)][object[]]$CandidateRecords
    )

    if (Test-Path -LiteralPath $CaptureRoot) {
        throw "Candidate capture root must be previously absent: $CaptureRoot"
    }
    [void](Invoke-Git $Repository @(
        'clone', '--local', '--no-hardlinks', '--no-checkout', '--quiet',
        $Repository, $CaptureRoot
    ))
    [void](Invoke-Git $CaptureRoot @('config', 'core.autocrlf', 'false'))
    [void](Invoke-Git $CaptureRoot @(
        'checkout', '--detach', '--force', '--quiet', $Commit
    ))

    foreach ($record in $CandidateRecords) {
        $relativePath = [string]$record.relative_path
        $source = Assert-RegularContainedFile $Repository $relativePath `
            "candidate '$relativePath'"
        $destination = Join-Path $CaptureRoot $relativePath
        [void](Get-OrCreateSafeCaptureDirectory $CaptureRoot $relativePath)
        if (Test-Path -LiteralPath $destination) {
            $destinationItem = Get-Item -LiteralPath $destination
            if ($destinationItem.PSIsContainer -or
                ($destinationItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Candidate capture target is not an ordinary file: $relativePath"
            }
        }
        [IO.File]::Copy($source, $destination, $true)
        $captured = Assert-RegularContainedFile $CaptureRoot $relativePath `
            "captured candidate '$relativePath'"
        $capturedItem = Get-Item -LiteralPath $captured
        $capturedHash = (
            Get-FileHash -LiteralPath $captured -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        if ([UInt64]$capturedItem.Length -ne [UInt64]$record.bytes -or
            $capturedHash -cne [string]$record.sha256) {
            throw "Candidate '$relativePath' changed while it was captured."
        }
    }

    [void](Invoke-Git $CaptureRoot (@(
        '-c', 'core.autocrlf=false', '-c', 'core.safecrlf=false', 'add', '--'
    ) + @($CandidateRecords | ForEach-Object {
        ":(literal)$([string]$_.relative_path)"
    })))
    [void](Invoke-Git $CaptureRoot @('diff', '--quiet', '--'))
    $capturedChanges = @(Get-CandidateChanges $CaptureRoot $Commit -Cached)
    $expectedChanges = @($CandidateRecords | ForEach-Object {
        [pscustomobject]@{
            status = [string]$_.status
            relative_path = [string]$_.relative_path
        }
    })
    $capturedIdentity = (Get-CandidateChangeIdentity $capturedChanges) -join "`n"
    $expectedIdentity = (Get-CandidateChangeIdentity $expectedChanges) -join "`n"
    if ($capturedIdentity -cne $expectedIdentity) {
        throw 'Candidate capture changed an unexpected path or status.'
    }

    $indexEntries = @(Invoke-Git $CaptureRoot (@(
        '-c', 'core.quotePath=false', 'ls-files', '--stage', '--'
    ) + @($CandidateRecords | ForEach-Object {
        ":(literal)$([string]$_.relative_path)"
    })))
    if ($indexEntries.Count -ne $CandidateRecords.Count -or @(
        $indexEntries | Where-Object {
            [string]$_ -cnotmatch '^100(?:644|755) [0-9a-f]{40,64} 0\t(.+)$'
        }
    ).Count -ne 0) {
        throw 'Candidate capture produced a non-ordinary Git index entry.'
    }

    $diffArguments = @(
        '-c', 'core.safecrlf=false', 'diff', '--cached', '--binary',
        '--full-index', '--no-ext-diff', '--no-textconv',
        "--output=$PatchPath", $Commit, '--'
    ) + @($CandidateRecords | ForEach-Object {
        ":(literal)$([string]$_.relative_path)"
    })
    [void](Invoke-Git $CaptureRoot $diffArguments)
    $patchItem = Get-Item -LiteralPath $PatchPath
    if ($patchItem.Length -le 0 -or $patchItem.Length -gt 16777216) {
        throw 'The candidate patch is empty or exceeds the 16777216-byte bound.'
    }
    return [pscustomobject][ordered]@{
        patch_sha256 = (
            Get-FileHash -LiteralPath $PatchPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        tree = [string](
            Invoke-Git $CaptureRoot @('write-tree') | Select-Object -Last 1
        )
        index_entries = $indexEntries
    }
}

function Get-ContainedPath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Base,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or [IO.Path]::IsPathRooted($RelativePath)) {
        throw "Build metadata path must be nonempty and relative: $RelativePath"
    }
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd([char[]]'\/')
    $candidate = [IO.Path]::GetFullPath((Join-Path $Base $RelativePath))
    $prefix = $rootPath + [IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Build metadata path escapes the checkout: $RelativePath"
    }
    return $candidate
}

function Get-InputInventory {
    param(
        [Parameter(Mandatory = $true)][string]$Checkout,
        [Parameter(Mandatory = $true)][string]$BuildPlanRelativePath,
        [string[]]$AdditionalInputRelativePath = @()
    )

    $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $planRelative = Get-NormalizedRepositoryRelativePath `
        $BuildPlanRelativePath 'BuildPlanRelativePath'
    [void]$paths.Add($planRelative)
    foreach ($additionalPath in @($AdditionalInputRelativePath)) {
        [void]$paths.Add($additionalPath)
    }
    $buildPlanPath = Get-ContainedPath $Checkout $Checkout $planRelative
    Assert-GswNoReparseAncestor $buildPlanPath 'build plan'
    $planDirectory = Split-Path -Parent $buildPlanPath
    $buildPlanSnapshot = Read-GswBoundedFileSnapshot -Path $buildPlanPath `
        -Name 'build plan' -MaximumBytes 4194304
    $buildPlan = ConvertFrom-GswStrictJsonUtf8Bytes `
        -Bytes $buildPlanSnapshot.Bytes -Source 'build plan'
    $linkedPaths = @(
        [string]$buildPlan.derived_source_plan.relative_path,
        [string]$buildPlan.upstream_lock.relative_path
    )
    if ($null -ne $buildPlan.PSObject.Properties['toolchain_lock']) {
        $linkedPaths += [string]$buildPlan.toolchain_lock.relative_path
    }
    if ($null -ne $buildPlan.PSObject.Properties['toolchain_locks']) {
        foreach ($lock in @($buildPlan.toolchain_locks)) {
            $linkedPaths += [string]$lock.relative_path
        }
    }
    foreach ($linkedPath in $linkedPaths) {
        $fullPath = Get-ContainedPath $Checkout $planDirectory $linkedPath
        Assert-GswNoReparseAncestor $fullPath "linked build metadata '$linkedPath'"
        [void]$paths.Add([IO.Path]::GetRelativePath($Checkout, $fullPath).Replace('\', '/'))
    }
    $upstreamLockPath = Get-ContainedPath $Checkout $planDirectory (
        [string]$buildPlan.upstream_lock.relative_path
    )
    $upstreamLockSnapshot = Read-GswBoundedFileSnapshot -Path $upstreamLockPath `
        -Name 'upstream lock' -MaximumBytes 1048576
    $upstreamEntries = @(ConvertFrom-StrictTsvUtf8Bytes `
        -Bytes $upstreamLockSnapshot.Bytes `
        -ExpectedHeader @(
            'name', 'source_directory', 'repository', 'commit', 'upstream_license',
            'disposition', 'closure_manifest', 'closure_manifest_sha256', 'scope'
        ) `
        -Name 'upstream lock' -MaximumBytes 1048576 -MaximumRows 256 `
        -MaximumLineBytes 16384 -MaximumPhysicalLines 1024)
    $upstreamLockDirectory = Split-Path -Parent $upstreamLockPath
    foreach ($entry in $upstreamEntries) {
        if ($entry.disposition -cne 'planned-component') { continue }
        $manifestPath = Get-ContainedPath $Checkout $upstreamLockDirectory `
            ([string]$entry.closure_manifest)
        Assert-GswNoReparseAncestor $manifestPath `
            "component closure manifest '$($entry.closure_manifest)'"
        [void]$paths.Add(
            [IO.Path]::GetRelativePath($Checkout, $manifestPath).Replace('\', '/')
        )
    }
    $derivedPlanPath = Get-ContainedPath $Checkout $planDirectory (
        [string]$buildPlan.derived_source_plan.relative_path
    )
    $derivedRoot = Split-Path -Parent $derivedPlanPath
    $derivedPlanSnapshot = Read-GswBoundedFileSnapshot -Path $derivedPlanPath `
        -Name 'derived-source plan' -MaximumBytes 4194304
    $derivedPlan = ConvertFrom-GswStrictJsonUtf8Bytes `
        -Bytes $derivedPlanSnapshot.Bytes -Source 'derived-source plan'
    foreach ($recipe in @($derivedPlan.recipes)) {
        foreach ($patch in @($recipe.patches)) {
            $fullPath = Get-ContainedPath $Checkout $derivedRoot ([string]$patch.relative_path)
            Assert-GswNoReparseAncestor $fullPath `
                "derived patch '$($patch.relative_path)'"
            [void]$paths.Add([IO.Path]::GetRelativePath($Checkout, $fullPath).Replace('\', '/'))
        }
        foreach ($overlay in @($recipe.overlays)) {
            $overlayRoot = Get-ContainedPath $Checkout $derivedRoot ([string]$overlay.relative_path)
            Assert-GswNoReparseAncestor $overlayRoot `
                "derived overlay '$($overlay.relative_path)'"
            foreach ($item in @(Get-ChildItem -LiteralPath $overlayRoot -Recurse -Force)) {
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "Derived overlay '$($overlay.relative_path)' contains a reparse point."
                }
                if ($item.PSIsContainer) { continue }
                [void]$paths.Add(
                    [IO.Path]::GetRelativePath($Checkout, $item.FullName).Replace('\', '/')
                )
            }
        }
    }

    return @($paths | Sort-Object -CaseSensitive | ForEach-Object {
        $path = Join-Path $Checkout $_
        Assert-GswNoReparseAncestor $path "raw input '$_'"
        $item = Get-Item -LiteralPath $path
        if ($item.PSIsContainer -or
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Raw input '$_' must be a regular file."
        }
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        '{0}|{1}|{2}' -f $_, $item.Length, $hash
    })
}

function Get-DeclaredOutputs {
    param(
        [Parameter(Mandatory = $true)][string]$Checkout,
        [Parameter(Mandatory = $true)][string]$BuildRoot,
        [Parameter(Mandatory = $true)][string]$BuildPlanRelativePath
    )

    $buildPlanPath = Join-Path $Checkout $BuildPlanRelativePath
    $buildPlan = Get-Content -Raw -LiteralPath $buildPlanPath | ConvertFrom-Json
    $planDirectory = Split-Path -Parent $buildPlanPath
    $derivedPlanPath = Join-Path $planDirectory ([string]$buildPlan.derived_source_plan.relative_path)
    $derivedPlan = Get-Content -Raw -LiteralPath $derivedPlanPath | ConvertFrom-Json
    $recipes = @{}
    foreach ($recipe in @($derivedPlan.recipes)) {
        $recipes[$recipe.name] = $recipe.destination_directory
    }

    $records = [Collections.Generic.List[string]]::new()
    foreach ($step in @($buildPlan.steps)) {
        if (-not $recipes.ContainsKey($step.recipe)) {
            throw "Build step '$($step.name)' references missing recipe '$($step.recipe)'."
        }
        foreach ($output in @($step.outputs)) {
            $relative = (Join-Path $recipes[$step.recipe] $output.relative_path).Replace('\', '/')
            $path = Join-Path $BuildRoot $relative
            $item = Get-Item -LiteralPath $path
            $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
            $record = '{0}|{1}|{2}' -f $relative, $item.Length, $hash
            if ($item.Length -ne [int64]$output.bytes -or $hash -cne [string]$output.sha256) {
                throw "Declared output '$relative' does not match its size or SHA-256 lock."
            }
            $records.Add($record)
        }
    }
    return @($records | Sort-Object -CaseSensitive)
}

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Join-Path $PSScriptRoot '..'
}
$repositoryPath = Get-FullPath $RepositoryRoot
$sourcePath = Get-FullPath $SourceRoot
$toolchainPath = Get-FullPath $ToolchainRoot
$proofPath = Get-FullPath $ProofRoot
$buildPlanRelative = Get-NormalizedRepositoryRelativePath `
    $BuildPlanRelativePath 'BuildPlanRelativePath'
$candidatePaths = @($CandidateRelativePath | ForEach-Object {
    Get-NormalizedRepositoryRelativePath $_ 'CandidateRelativePath'
} | Sort-Object -CaseSensitive)
$additionalInputPaths = @($AdditionalInputRelativePath | ForEach-Object {
    Get-NormalizedRepositoryRelativePath $_ 'AdditionalInputRelativePath'
} | Sort-Object -CaseSensitive)

foreach ($collection in @(
    [pscustomobject]@{ Name = 'CandidateRelativePath'; Paths = $candidatePaths },
    [pscustomobject]@{ Name = 'AdditionalInputRelativePath'; Paths = $additionalInputPaths }
)) {
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $collection.Paths) {
        if (-not $seen.Add($path)) {
            throw "$($collection.Name) contains a duplicate path: $path"
        }
    }
}
if ($candidatePaths.Count -gt 64 -or $additionalInputPaths.Count -gt 64) {
    throw 'Candidate or additional input path count exceeds the 64-path bound.'
}

if (Test-Path -LiteralPath $proofPath) {
    throw "ProofRoot must be previously absent: $proofPath"
}
foreach ($required in @(
    [pscustomobject]@{ Path = $repositoryPath; Name = 'repository' },
    [pscustomobject]@{ Path = $sourcePath; Name = 'source root' },
    [pscustomobject]@{ Path = $toolchainPath; Name = 'toolchain root' }
)) {
    if (-not (Test-Path -LiteralPath $required.Path -PathType Container)) {
        throw "Required $($required.Name) not found: $($required.Path)"
    }
}

$commit = [string](Invoke-Git $repositoryPath @('rev-parse', 'HEAD') | Select-Object -Last 1)
[void](Assert-OrdinaryRepositoryIndexState $repositoryPath)
[void](Invoke-Git $repositoryPath @('diff', '--cached', '--quiet', 'HEAD', '--'))
$sourceIndexSnapshot = Get-RepositoryIndexSnapshot $repositoryPath
$candidateRecords = @()
$candidateChanges = @(Get-CandidateChanges $repositoryPath 'HEAD')
if ($candidatePaths.Count -eq 0) {
    if ($candidateChanges.Count -ne 0) {
        throw 'Repository must have no nonignored dirty files when candidate mode is disabled.'
    }
}
else {
    $actualPaths = @($candidateChanges | ForEach-Object { [string]$_.relative_path })
    if (($actualPaths -join "`n") -cne ($candidatePaths -join "`n")) {
        throw "CandidateRelativePath must equal the exact nonignored dirty set.`nExpected: $($candidatePaths -join ', ')`nActual: $($actualPaths -join ', ')"
    }
    foreach ($relativePath in $candidatePaths) {
        if ([string]::Equals(
            $relativePath, '.gitattributes', [StringComparison]::OrdinalIgnoreCase
        )) {
            throw 'Candidate mode does not permit a .gitattributes change.'
        }
    }
    $candidateRecords = @(Get-CandidateFileRecords $repositoryPath $candidateChanges)
}
foreach ($relativePath in $additionalInputPaths) {
    [void](Assert-RegularContainedFile $repositoryPath $relativePath `
        "additional input '$relativePath'")
}
[void](Assert-GswNoReparseAncestor $proofPath 'proof root')
[void](New-Item -ItemType Directory -Path $proofPath)

$candidatePatchPath = $null
$candidatePatchHash = $null
$candidateCapture = $null
if ($candidatePaths.Count -ne 0) {
    $candidatePatchPath = Join-Path $proofPath 'candidate.patch'
    $candidateCapture = New-CandidateCapture `
        -Repository $repositoryPath -Commit $commit `
        -CaptureRoot (Join-Path $proofPath 'candidate-capture-initial') `
        -PatchPath $candidatePatchPath -CandidateRecords $candidateRecords
    $patchItem = Get-Item -LiteralPath $candidatePatchPath
    $candidatePatchHash = [string]$candidateCapture.patch_sha256
    $candidateDescriptor = [ordered]@{
        schema = 2
        base_commit = $commit
        patch_bytes = [UInt64]$patchItem.Length
        patch_sha256 = $candidatePatchHash
        candidate_files = $candidateRecords
        additional_input_paths = $additionalInputPaths
    }
    [IO.File]::WriteAllText(
        (Join-Path $proofPath 'candidate.json'),
        (($candidateDescriptor | ConvertTo-Json -Depth 8) + "`n"),
        [Text.UTF8Encoding]::new($false)
    )
}

$inventories = @{}
$outputs = @{}
$candidateTrees = @{}
$candidatePatchHashes = @{}
$candidateIndexEntries = @{}
foreach ($case in @(
    [pscustomobject]@{ Name = 'autocrlf-true'; Value = 'true' },
    [pscustomobject]@{ Name = 'autocrlf-false'; Value = 'false' }
)) {
    $checkout = Join-Path $proofPath $case.Name
    $buildRoot = Join-Path $proofPath ($case.Name + '-build')
    [void](Invoke-Git $repositoryPath @(
        'clone', '--local', '--no-hardlinks', '--no-checkout', '--quiet',
        $repositoryPath, $checkout
    ))
    [void](Invoke-Git $checkout @('config', 'core.autocrlf', $case.Value))
    [void](Invoke-Git $checkout @('checkout', '--detach', '--force', '--quiet', $commit))
    if ($candidatePaths.Count -ne 0) {
        [void](Invoke-Git $checkout @(
            'apply', '--check', '--cached', '--binary', '--whitespace=nowarn',
            '--', $candidatePatchPath
        ))
        [void](Invoke-Git $checkout @(
            'apply', '--cached', '--binary', '--whitespace=nowarn',
            '--', $candidatePatchPath
        ))
        [void](Invoke-Git $checkout @('checkout-index', '--force', '--all'))
        [void](Invoke-Git $checkout @('diff', '--quiet', '--'))
        $appliedChanges = @(Get-CandidateChanges $checkout $commit -Cached)
        $appliedIdentity = (Get-CandidateChangeIdentity $appliedChanges) -join "`n"
        $sourceIdentity = (Get-CandidateChangeIdentity $candidateChanges) -join "`n"
        if ($appliedIdentity -cne $sourceIdentity) {
            throw "Candidate patch changed an unexpected path in $($case.Name)."
        }
        $candidateTrees[$case.Name] = [string](
            Invoke-Git $checkout @('write-tree') | Select-Object -Last 1
        )
        $indexPatchPath = Join-Path $proofPath ($case.Name + '-candidate-index.patch')
        $indexDiffArguments = @(
            '-c', 'core.safecrlf=false', 'diff', '--cached', '--binary',
            '--full-index', '--no-ext-diff', '--no-textconv',
            "--output=$indexPatchPath", $commit, '--'
        ) + @($candidatePaths | ForEach-Object { ":(literal)$_" })
        [void](Invoke-Git $checkout $indexDiffArguments)
        $candidatePatchHashes[$case.Name] = (
            Get-FileHash -LiteralPath $indexPatchPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        if ([string]$candidatePatchHashes[$case.Name] -cne $candidatePatchHash) {
            throw "Candidate patch identity changed in $($case.Name)."
        }
        $candidateIndexEntries[$case.Name] = @(
            Invoke-Git $checkout (@(
                '-c', 'core.quotePath=false', 'ls-files', '--stage', '--'
            ) + @($candidatePaths | ForEach-Object { ":(literal)$_" }))
        )
        if ([string]$candidateTrees[$case.Name] -cne [string]$candidateCapture.tree -or
            ($candidateIndexEntries[$case.Name] -join "`n") -cne
            (@($candidateCapture.index_entries) -join "`n")) {
            throw "Candidate index or tree identity changed in $($case.Name)."
        }
    }

    $checkoutBuildPlan = Join-Path $checkout $buildPlanRelative
    $checkoutPlan = Get-Content -Raw -LiteralPath $checkoutBuildPlan | ConvertFrom-Json
    $checkoutPlanDirectory = Split-Path -Parent $checkoutBuildPlan
    $checkoutUpstreamLock = Join-Path $checkoutPlanDirectory (
        [string]$checkoutPlan.upstream_lock.relative_path
    )
    $inventories[$case.Name] = @(
        Get-InputInventory $checkout $buildPlanRelative $additionalInputPaths
    )
    & (Join-Path $checkout 'scripts\build-win98-driver-sources.ps1') `
        -SourceRoot $sourcePath -ToolchainRoot $toolchainPath `
        -OutputRoot $buildRoot `
        -BuildPlan $checkoutBuildPlan -LockFile $checkoutUpstreamLock
    $outputs[$case.Name] = @(
        Get-DeclaredOutputs $checkout $buildRoot $buildPlanRelative
    )
    [IO.File]::WriteAllText(
        (Join-Path $proofPath ($case.Name + '-input-inventory.txt')),
        (($inventories[$case.Name] -join "`n") + "`n"),
        [Text.UTF8Encoding]::new($false)
    )
    [IO.File]::WriteAllText(
        (Join-Path $proofPath ($case.Name + '-output-inventory.txt')),
        (($outputs[$case.Name] -join "`n") + "`n"),
        [Text.UTF8Encoding]::new($false)
    )
}

$trueInputs = $inventories['autocrlf-true'] -join "`n"
$falseInputs = $inventories['autocrlf-false'] -join "`n"
if ($trueInputs -cne $falseInputs) {
    throw 'core.autocrlf=true and false produced different raw Win98 driver input bytes.'
}
$trueOutputs = $outputs['autocrlf-true'] -join "`n"
$falseOutputs = $outputs['autocrlf-false'] -join "`n"
if ($trueOutputs -cne $falseOutputs) {
    throw 'core.autocrlf=true and false produced different declared driver outputs.'
}

if ($candidatePaths.Count -ne 0) {
    if ([string]$candidateTrees['autocrlf-true'] -cne
        [string]$candidateTrees['autocrlf-false']) {
        throw 'Candidate application produced different Git tree identities.'
    }
    if (($candidateIndexEntries['autocrlf-true'] -join "`n") -cne
        ($candidateIndexEntries['autocrlf-false'] -join "`n")) {
        throw 'Candidate application produced different Git index entries.'
    }
    [void](Invoke-Git $repositoryPath @('diff', '--cached', '--quiet', 'HEAD', '--'))
    Assert-RepositoryIndexUnchanged $sourceIndexSnapshot $repositoryPath
    $finalCommit = [string](
        Invoke-Git $repositoryPath @('rev-parse', 'HEAD') | Select-Object -Last 1
    )
    if ($finalCommit -cne $commit) {
        throw 'The source repository HEAD changed during the proof.'
    }
    $finalChanges = @(Get-CandidateChanges $repositoryPath 'HEAD')
    if (((Get-CandidateChangeIdentity $finalChanges) -join "`n") -cne
        ((Get-CandidateChangeIdentity $candidateChanges) -join "`n")) {
        throw 'The source candidate changed its exact path or status set during the proof.'
    }
    $finalRecords = @(Get-CandidateFileRecords $repositoryPath $finalChanges)
    if (((Get-CandidateRecordIdentity $finalRecords) -join "`n") -cne
        ((Get-CandidateRecordIdentity $candidateRecords) -join "`n")) {
        throw 'The source candidate file bytes changed during the proof.'
    }
    $candidateFinalPatchPath = Join-Path $proofPath 'candidate-final.patch'
    $finalCapture = New-CandidateCapture `
        -Repository $repositoryPath -Commit $commit `
        -CaptureRoot (Join-Path $proofPath 'candidate-capture-final') `
        -PatchPath $candidateFinalPatchPath -CandidateRecords $finalRecords
    $candidateFinalPatchHash = [string]$finalCapture.patch_sha256
    if ($candidateFinalPatchHash -cne $candidatePatchHash) {
        throw 'The source candidate patch changed during the proof.'
    }
    if ([string]$finalCapture.tree -cne [string]$candidateCapture.tree -or
        (@($finalCapture.index_entries) -join "`n") -cne
        (@($candidateCapture.index_entries) -join "`n")) {
        throw 'The final candidate capture changed its index or tree identity.'
    }
    Assert-RepositoryIndexUnchanged $sourceIndexSnapshot $repositoryPath
    $result = [ordered]@{
        schema = 2
        base_commit = $commit
        patch_sha256 = $candidatePatchHash
        final_patch_sha256 = $candidateFinalPatchHash
        candidate_tree = [string]$candidateTrees['autocrlf-true']
        candidate_index_entries = $candidateIndexEntries['autocrlf-true']
        input_files = $inventories['autocrlf-true'].Count
        declared_outputs = $outputs['autocrlf-true'].Count
    }
    [IO.File]::WriteAllText(
        (Join-Path $proofPath 'candidate-result.json'),
        (($result | ConvertTo-Json -Depth 4) + "`n"),
        [Text.UTF8Encoding]::new($false)
    )
    Write-Output "Verified fresh-checkout Win98 driver EOL reproducibility at base $commit with candidate patch $candidatePatchHash."
    Write-Output "Candidate tree: $($candidateTrees['autocrlf-true'])."
}
else {
    $finalCommit = [string](
        Invoke-Git $repositoryPath @('rev-parse', 'HEAD') | Select-Object -Last 1
    )
    if ($finalCommit -cne $commit -or
        @(Get-CandidateChanges $repositoryPath 'HEAD').Count -ne 0) {
        throw 'The source repository changed during the proof.'
    }
    Assert-RepositoryIndexUnchanged $sourceIndexSnapshot $repositoryPath
    Write-Output "Verified fresh-checkout Win98 driver EOL reproducibility at $commit."
}
Write-Output "Input files: $($inventories['autocrlf-true'].Count); declared outputs: $($outputs['autocrlf-true'].Count)."
Write-Output "Proof root: $proofPath"
