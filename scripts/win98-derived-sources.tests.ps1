# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Failures = 0

function Assert-True {
    param([Parameter(Mandatory = $true)][bool]$Condition, [string]$Message = 'Expected true.')
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Message = 'Values differ.')
    if ($Actual -ne $Expected) { throw "$Message Expected '$Expected', observed '$Actual'." }
}

function Assert-Throws {
    param([Parameter(Mandatory = $true)][scriptblock]$Body, [string]$Pattern = '')
    try {
        & $Body | Out-Null
    }
    catch {
        if ($Pattern.Length -ne 0 -and $_.Exception.Message -notmatch $Pattern) {
            throw "Exception did not match '$Pattern': $($_.Exception.Message)"
        }
        return
    }
    throw 'Expected an exception.'
}

function Invoke-SelfTest {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )
    try {
        & $Body
        Write-Host "PASS $Name"
    }
    catch {
        $script:Failures++
        [Console]::Error.WriteLine(
            "FAIL $Name`: $($_.Exception.Message)$([Environment]::NewLine)$($_.ScriptStackTrace)"
        )
    }
}

function Invoke-Git {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $output = @(& git @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
    }
    return ($output -join [Environment]::NewLine).Trim()
}

function Get-BigEndianBytes {
    param([UInt64]$Value, [int]$Width)

    $bytes = if ($Width -eq 4) {
        [BitConverter]::GetBytes([UInt32]$Value)
    }
    else {
        [BitConverter]::GetBytes($Value)
    }
    if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($bytes) }
    return $bytes
}

function ConvertTo-LowerHex {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    return ([BitConverter]::ToString($Bytes) -replace '-', '').ToLowerInvariant()
}

function Get-TestRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $method = [IO.Path].GetMethod(
        'GetRelativePath',
        [Reflection.BindingFlags]'Public,Static',
        $null,
        [Type[]]@([string], [string]),
        $null
    )
    if ($null -ne $method) { return [IO.Path]::GetRelativePath($Root, $Path).Replace('\', '/') }
    $rootUri = New-Object Uri ($Root.TrimEnd([char[]]'\/') + [IO.Path]::DirectorySeparatorChar)
    $pathUri = New-Object Uri $Path
    return [Uri]::UnescapeDataString($rootUri.MakeRelativeUri($pathUri).ToString())
}

function Get-Sha256Bytes {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [byte[]]$sha.ComputeHash($Bytes) }
    finally { $sha.Dispose() }
}

function Get-TestTreeDescriptor {
    param([Parameter(Mandatory = $true)][string]$Root)

    $rootPath = [IO.Path]::GetFullPath($Root)
    $records = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $directories = @(Get-ChildItem -LiteralPath $rootPath -Directory -Recurse -Force)
    $files = @(Get-ChildItem -LiteralPath $rootPath -File -Recurse -Force)
    [UInt64]$aggregateBytes = 0
    [UInt64]$maximumFileBytes = 0
    [UInt64]$maximumPathBytes = 0
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    foreach ($entry in @($directories + $files)) {
        $relativePath = Get-TestRelativePath $rootPath $entry.FullName
        [UInt64]$pathByteCount = $utf8.GetByteCount($relativePath)
        if ($pathByteCount -gt $maximumPathBytes) { $maximumPathBytes = $pathByteCount }
    }
    foreach ($file in $files) {
        $relativePath = Get-TestRelativePath $rootPath $file.FullName
        $bytes = [IO.File]::ReadAllBytes($file.FullName)
        [UInt64]$length = $bytes.Length
        $aggregateBytes += $length
        if ($length -gt $maximumFileBytes) { $maximumFileBytes = $length }
        $records.Add($relativePath, [pscustomobject]@{
            Length = $length
            Hash = Get-Sha256Bytes $bytes
        })
    }
    [string[]]$paths = @($records.Keys)
    [Array]::Sort($paths, [StringComparer]::Ordinal)
    $canonical = New-Object IO.MemoryStream
    try {
        [byte[]]$field = $utf8.GetBytes("RETVRN99-WIN98-TREE-SHA256-V1`0")
        $canonical.Write($field, 0, $field.Length)
        $field = Get-BigEndianBytes -Value ([UInt64]$paths.Count) -Width 8
        $canonical.Write($field, 0, $field.Length)
        $field = Get-BigEndianBytes -Value $aggregateBytes -Width 8
        $canonical.Write($field, 0, $field.Length)
        foreach ($relativePath in $paths) {
            [byte[]]$encodedPath = $utf8.GetBytes($relativePath)
            $record = $records[$relativePath]
            $field = Get-BigEndianBytes -Value ([UInt64]$encodedPath.Length) -Width 4
            $canonical.Write($field, 0, $field.Length)
            $canonical.Write($encodedPath, 0, $encodedPath.Length)
            $field = Get-BigEndianBytes -Value ([UInt64]$record.Length) -Width 8
            $canonical.Write($field, 0, $field.Length)
            [byte[]]$fileHash = $record.Hash
            $canonical.Write($fileHash, 0, $fileHash.Length)
        }
        $canonical.Position = 0
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $sha256 = ConvertTo-LowerHex ($sha.ComputeHash($canonical)) }
        finally { $sha.Dispose() }
    }
    finally {
        $canonical.Dispose()
    }
    return [pscustomobject]@{
        FileCount = [UInt64]$files.Count
        DirectoryCount = [UInt64]$directories.Count
        TotalEntries = [UInt64]($files.Count + $directories.Count)
        AggregateBytes = $aggregateBytes
        MaximumFileBytes = $maximumFileBytes
        MaximumPathBytes = $maximumPathBytes
        Sha256 = $sha256
    }
}

function Convert-TreeDescriptor {
    param([Parameter(Mandatory = $true)][object]$Descriptor)

    return [ordered]@{
        file_count = $Descriptor.FileCount
        directory_count = $Descriptor.DirectoryCount
        total_entries = $Descriptor.TotalEntries
        aggregate_bytes = $Descriptor.AggregateBytes
        maximum_file_bytes = $Descriptor.MaximumFileBytes
        maximum_path_bytes = $Descriptor.MaximumPathBytes
        digest_algorithm = 'retvrn99-file-tree-sha256-v1'
        sha256 = $Descriptor.Sha256
    }
}

function Write-Plan {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Recipes,
        [string]$Status = 'ready',
        [string]$Reason = ''
    )

    $plan = [ordered]@{
        _spdx = 'GPL-3.0-only'
        schema = 2
        status = $Status
        reason = $Reason
        recipes = $Recipes
    }
    [IO.File]::WriteAllText($Path, ($plan | ConvertTo-Json -Depth 12))
}

function New-Recipe {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Patches,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Overlays,
        [Parameter(Mandatory = $true)][object]$OutputTree,
        [string]$Destination = 'vmdisp9x-gsw'
    )

    return [ordered]@{
        name = 'vmdisp9x-gsw'
        upstream_name = 'vmdisp9x'
        source_directory = 'vmdisp9x'
        destination_directory = $Destination
        patches = $Patches
        overlays = $Overlays
        output_tree = Convert-TreeDescriptor $OutputTree
    }
}

function New-OverlayRecord {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Path,
        [bool]$ReplaceExisting = $false
    )

    return [ordered]@{
        relative_path = $RelativePath
        destination_relative_path = '.'
        replace_existing = $ReplaceExisting
        tree = Convert-TreeDescriptor (Get-TestTreeDescriptor $Path)
    }
}

function New-PatchRecord {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Path,
        [string[]]$NormalizeLfPaths = @()
    )

    $file = Get-Item -LiteralPath $Path
    return [ordered]@{
        relative_path = $RelativePath
        bytes = $file.Length
        sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
        normalize_lf_paths = $NormalizeLfPaths
    }
}

function New-ExpectedTree {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Fixture = 'upstream',
        [string]$Existing = 'existing',
        [string]$OverlayRoot
    )

    [void](New-Item -ItemType Directory -Path (Join-Path $Path 'sub') -Force)
    [IO.File]::WriteAllText((Join-Path $Path 'fixture.txt'), "$Fixture`n")
    [IO.File]::WriteAllText((Join-Path $Path 'sub\existing.txt'), "$Existing`n")
    if (-not [string]::IsNullOrWhiteSpace($OverlayRoot)) {
        Copy-Item -Path (Join-Path $OverlayRoot '*') -Destination $Path -Recurse -Force
    }
    return Get-TestTreeDescriptor $Path
}

function Invoke-Preparation {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [scriptblock]$BeforePatchNormalization,
        [scriptblock]$BeforeCachedOverlayValidation,
        [scriptblock]$BeforeFinalPublication,
        [scriptblock]$BeforeSecondScan
    )

    $arguments = @{
        SourceRoot = $script:SourceRoot
        OutputRoot = Join-Path $script:TestRoot $Name
        RecipePlan = $script:PlanPath
        RecipeRoot = $script:TestRoot
        LockFile = $script:LockPath
    }
    if ($null -ne $BeforeSecondScan) {
        $arguments.BeforeSecondScan = $BeforeSecondScan
    }
    if ($null -ne $BeforePatchNormalization) {
        $arguments.BeforePatchNormalization = $BeforePatchNormalization
    }
    if ($null -ne $BeforeCachedOverlayValidation) {
        $arguments.BeforeCachedOverlayValidation = $BeforeCachedOverlayValidation
    }
    if ($null -ne $BeforeFinalPublication) {
        $arguments.BeforeFinalPublication = $BeforeFinalPublication
    }
    return @(& $script:PrepareScript @arguments)
}

if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
    throw 'git is required for the Windows 98 derived-source tests.'
}

$script:TestRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'retvrn99-win98-derived-test-{0}' -f [Guid]::NewGuid().ToString('N')
)
[void](New-Item -ItemType Directory -Path $script:TestRoot)

try {
    Invoke-Git @('init', '-q', $script:TestRoot) | Out-Null
    Invoke-Git @('-C', $script:TestRoot, 'config', 'user.name', 'RETVRN99 Parent Test') | Out-Null
    Invoke-Git @('-C', $script:TestRoot, 'config', 'user.email', 'parent@retvrn99.invalid') | Out-Null
    [IO.File]::WriteAllText((Join-Path $script:TestRoot 'parent-sentinel.txt'), 'parent worktree')
    Invoke-Git @('-C', $script:TestRoot, 'add', 'parent-sentinel.txt') | Out-Null
    Invoke-Git @('-C', $script:TestRoot, 'commit', '-q', '-m', 'Parent worktree fixture') | Out-Null
    $script:PrepareScript = Join-Path $PSScriptRoot 'prepare-win98-derived-sources.ps1'
    $script:PlanPath = Join-Path $script:TestRoot 'derived-plan.json'
    $script:SourceRoot = Join-Path $script:TestRoot 'sources'
    $checkout = Join-Path $script:SourceRoot 'vmdisp9x'
    [void](New-Item -ItemType Directory -Path $checkout -Force)
    Invoke-Git @('init', '-q', $checkout) | Out-Null
    Invoke-Git @('-C', $checkout, 'config', 'user.name', 'RETVRN99 Test') | Out-Null
    Invoke-Git @('-C', $checkout, 'config', 'user.email', 'test@retvrn99.invalid') | Out-Null
    Invoke-Git @('-C', $checkout, 'config', 'core.autocrlf', 'false') | Out-Null
    [void](New-Item -ItemType Directory -Path (Join-Path $checkout 'sub'))
    [IO.File]::WriteAllText((Join-Path $checkout 'fixture.txt'), "upstream`n")
    [IO.File]::WriteAllText((Join-Path $checkout 'sub\existing.txt'), "existing`n")
    Invoke-Git @('-C', $checkout, 'add', 'fixture.txt', 'sub/existing.txt') | Out-Null
    Invoke-Git @('-C', $checkout, 'commit', '-q', '-m', 'Pinned fixture') | Out-Null
    Invoke-Git @('-C', $checkout, 'remote', 'add', 'origin', 'https://example.invalid/vmdisp9x.git') | Out-Null
    $commit = Invoke-Git @('-C', $checkout, 'rev-parse', 'HEAD')
    $script:LockPath = Join-Path $script:TestRoot 'upstream.lock.tsv'
    $lockContents = @(
        '# SPDX-License-Identifier: GPL-3.0-only'
        "name`tsource_directory`trepository`tcommit`tupstream_license`tdisposition`tclosure_manifest`tclosure_manifest_sha256`tscope"
        "vmdisp9x`tvmdisp9x`thttps://example.invalid/vmdisp9x.git`t$commit`tMIT`tplanned`t`t`tdisplay-driver"
    ) -join "`r`n"
    [IO.File]::WriteAllText($script:LockPath, $lockContents + "`r`n")

    $overlayPath = Join-Path $script:TestRoot 'inputs\overlay'
    [void](New-Item -ItemType Directory -Path (Join-Path $overlayPath 'res') -Force)
    [IO.File]::WriteAllText((Join-Path $overlayPath 'gsw.mak'), "all:`n")
    [IO.File]::WriteAllText((Join-Path $overlayPath 'res\gswmini.rc'), "resource`n")
    $expectedOverlayPath = Join-Path $script:TestRoot 'expected-overlay'
    $overlayOutputTree = New-ExpectedTree $expectedOverlayPath -OverlayRoot $overlayPath
    $overlayRecord = New-OverlayRecord 'inputs/overlay' $overlayPath
    Write-Plan $script:PlanPath @(
        New-Recipe @() @($overlayRecord) $overlayOutputTree
    )

    Invoke-SelfTest 'Preparation rejects malformed upstream TSV before publication' {
        $originalLock = [IO.File]::ReadAllText($script:LockPath)
        try {
            $lines = @([IO.File]::ReadAllLines($script:LockPath))
            $rowFields = @($lines[2].Split([char]"`t"))
            $lines[2] = @($rowFields[0..7]) -join "`t"
            [IO.File]::WriteAllLines($script:LockPath, $lines)
            Assert-Throws { Invoke-Preparation 'strict-missing-field' } `
                'upstream lock data row 1 has 8 fields'
            Assert-True (-not (Test-Path (
                Join-Path $script:TestRoot 'strict-missing-field'
            )))

            $lines = @($originalLock -split "`r`n|`n|`r")
            $headerFields = @($lines[1].Split([char]"`t"))
            $lines[1] = (@($headerFields[1], $headerFields[0]) + @($headerFields[2..8])) -join "`t"
            [IO.File]::WriteAllText($script:LockPath, ($lines -join "`r`n"))
            Assert-Throws { Invoke-Preparation 'strict-reordered-header' } `
                "upstream lock header column 1 must be 'name'"
            Assert-True (-not (Test-Path (
                Join-Path $script:TestRoot 'strict-reordered-header'
            )))
        }
        finally {
            [IO.File]::WriteAllText($script:LockPath, $originalLock)
        }
    }

    Invoke-SelfTest 'Descriptor authoring uses the exact ready-mode tree grammar' {
        $description = & $script:PrepareScript -DescribeTree $overlayPath | ConvertFrom-Json
        Assert-Equal $description.sha256 $overlayRecord.tree.sha256
        Assert-Equal $description.file_count $overlayRecord.tree.file_count
        Assert-Equal $description.directory_count $overlayRecord.tree.directory_count
        Assert-Throws {
            & $script:PrepareScript -DescribeTree $overlayPath `
                -BeforeSecondScan {
                    param($treePath, $mode)
                    [IO.File]::WriteAllText((Join-Path $treePath 'late.tmp'), $mode)
                }
        } 'Described tree second scan .* mismatch'
        Remove-Item -LiteralPath (Join-Path $overlayPath 'late.tmp')
    }

    Invoke-SelfTest 'Draft recipes bootstrap exact final descriptors without publishing' {
        $draftRecipe = [ordered]@{
            name = 'vmdisp9x-gsw'
            upstream_name = 'vmdisp9x'
            source_directory = 'vmdisp9x'
            destination_directory = 'vmdisp9x-gsw'
            patches = @()
            overlays = @($overlayRecord)
        }
        Write-Plan $script:PlanPath @($draftRecipe) -Status 'draft' -Reason ''
        Assert-Throws {
            & $script:PrepareScript -SourceRoot $script:SourceRoot `
                -RecipePlan $script:PlanPath -RecipeRoot $script:TestRoot `
                -LockFile $script:LockPath -DescribeRecipe 'vmdisp9x-gsw'
        } 'draft derived-source plan must give one nonempty reason'
        Write-Plan $script:PlanPath @($draftRecipe) -Status 'draft' -Reason 'descriptor review required'
        try {
            $description = & $script:PrepareScript `
                -SourceRoot $script:SourceRoot -RecipePlan $script:PlanPath `
                -RecipeRoot $script:TestRoot -LockFile $script:LockPath `
                -DescribeRecipe 'vmdisp9x-gsw' | ConvertFrom-Json
            Assert-Equal $description.output_tree.sha256 $overlayOutputTree.Sha256
            Assert-Equal $description.destination_directory 'vmdisp9x-gsw'
            Assert-Throws {
                & $script:PrepareScript -SourceRoot $script:SourceRoot `
                    -OutputRoot (Join-Path $script:TestRoot 'draft-output') `
                    -RecipePlan $script:PlanPath -RecipeRoot $script:TestRoot `
                    -LockFile $script:LockPath
            } 'draft-only'
            Assert-True (-not (Test-Path (Join-Path $script:TestRoot 'draft-output')))
        }
        finally {
            Write-Plan $script:PlanPath @(New-Recipe @() @($overlayRecord) $overlayOutputTree)
        }
        Assert-Throws {
            & $script:PrepareScript -SourceRoot $script:SourceRoot `
                -RecipePlan $script:PlanPath -RecipeRoot $script:TestRoot `
                -LockFile $script:LockPath -DescribeRecipe 'vmdisp9x-gsw'
        } 'requires a draft'
    }

    Invoke-SelfTest 'A blocked plan cannot prepare or publish derived sources' {
        Write-Plan $script:PlanPath @() -Status 'blocked' -Reason 'review required'
        try {
            Assert-Throws { Invoke-Preparation 'blocked-output' } 'preparation is blocked: review required'
            Assert-True (-not (Test-Path (Join-Path $script:TestRoot 'blocked-output')))
        }
        finally {
            Write-Plan $script:PlanPath @(New-Recipe @() @($overlayRecord) $overlayOutputTree)
        }
        foreach ($gitVariable in @(
            'GIT_CEILING_DIRECTORIES', 'GIT_DIR', 'GIT_WORK_TREE',
            'GIT_PREFIX', 'GIT_INDEX_FILE'
        )) {
            Assert-True (-not (Test-Path -LiteralPath ('Env:' + $gitVariable))) `
                "Preparation leaked the $gitVariable environment variable."
        }
    }

    Invoke-SelfTest 'A hash-locked overlay produces the exact deterministic tree' {
        $output = Invoke-Preparation 'overlay-output'
        Assert-True (($output -join [Environment]::NewLine) -match 'Verified 1 immutable')
        Assert-True (($output -join [Environment]::NewLine) -match 'Prepared and verified 1 deterministic')
        $prepared = Join-Path $script:TestRoot 'overlay-output\vmdisp9x-gsw'
        Assert-Equal (Get-TestTreeDescriptor $prepared).Sha256 $overlayOutputTree.Sha256
        Assert-True (Test-Path (Join-Path $prepared 'gsw.mak'))
        Assert-True (Test-Path (Join-Path $prepared 'res\gswmini.rc'))
        Assert-Equal (Invoke-Git @('-C', $checkout, 'status', '--porcelain')) ''
    }

    Invoke-SelfTest 'Preparation never overwrites an existing output root' {
        Assert-Throws { Invoke-Preparation 'overlay-output' } 'already exists; refusing to overwrite'
    }

    Invoke-SelfTest 'Recipe destinations must be disjoint in both ancestor directions' {
        $parentRecipe = New-Recipe @() @($overlayRecord) $overlayOutputTree -Destination 'parent'
        $nestedRecipe = New-Recipe @() @($overlayRecord) $overlayOutputTree -Destination 'parent/nested'
        $nestedRecipe.name = 'nested-recipe'
        foreach ($recipes in @(
            @($parentRecipe, $nestedRecipe),
            @($nestedRecipe, $parentRecipe)
        )) {
            Write-Plan $script:PlanPath $recipes
            Assert-Throws { Invoke-Preparation ('nested-' + [Guid]::NewGuid().ToString('N')) } `
                'cannot be ancestors or descendants'
        }
        Write-Plan $script:PlanPath @(New-Recipe @() @($overlayRecord) $overlayOutputTree)
    }

    Invoke-SelfTest 'Overlay mutation fails before output publication' {
        [IO.File]::AppendAllText((Join-Path $overlayPath 'gsw.mak'), 'changed')
        try {
            Assert-Throws { Invoke-Preparation 'mutated-overlay' } 'overlay first scan .* mismatch'
            Assert-True (-not (Test-Path (Join-Path $script:TestRoot 'mutated-overlay')))
        }
        finally {
            [IO.File]::WriteAllText((Join-Path $overlayPath 'gsw.mak'), "all:`n")
        }

        Assert-Throws {
            Invoke-Preparation 'mutated-overlay-cache' -BeforeCachedOverlayValidation {
                param($cachedOverlay, $liveOverlay, $recipeName, $overlayIndex)
                [IO.File]::AppendAllText((Join-Path $cachedOverlay 'gsw.mak'), 'cached mutation')
            }
        } 'cached overlay .* mismatch'
        Assert-True (-not (Test-Path (Join-Path $script:TestRoot 'mutated-overlay-cache')))
    }

    Invoke-SelfTest 'An overlay cannot silently replace tracked source' {
        $replacementRoot = Join-Path $script:TestRoot 'inputs\replacement'
        [void](New-Item -ItemType Directory -Path $replacementRoot)
        [IO.File]::WriteAllText((Join-Path $replacementRoot 'fixture.txt'), "replaced`n")
        $replacementExpected = Join-Path $script:TestRoot 'expected-replacement'
        $replacementTree = New-ExpectedTree $replacementExpected -Fixture 'replaced'
        $replacementRecord = New-OverlayRecord 'inputs/replacement' $replacementRoot
        Write-Plan $script:PlanPath @(New-Recipe @() @($replacementRecord) $replacementTree)
        try {
            Assert-Throws { Invoke-Preparation 'replacement-denied' } 'without explicit approval'
        }
        finally {
            Write-Plan $script:PlanPath @(New-Recipe @() @($overlayRecord) $overlayOutputTree)
        }
    }

    Invoke-SelfTest 'An explicitly reviewed replacement remains hash locked' {
        $replacementRoot = Join-Path $script:TestRoot 'inputs\replacement'
        $replacementExpected = Join-Path $script:TestRoot 'expected-approved-replacement'
        $replacementTree = New-ExpectedTree $replacementExpected -Fixture 'replaced'
        $replacementRecord = New-OverlayRecord 'inputs/replacement' $replacementRoot -ReplaceExisting $true
        Write-Plan $script:PlanPath @(New-Recipe @() @($replacementRecord) $replacementTree)
        try {
            Invoke-Preparation 'replacement-approved' | Out-Null
            Assert-Equal (
                [IO.File]::ReadAllText((Join-Path $script:TestRoot 'replacement-approved\vmdisp9x-gsw\fixture.txt'))
            ) "replaced`n"
        }
        finally {
            Write-Plan $script:PlanPath @(New-Recipe @() @($overlayRecord) $overlayOutputTree)
        }
    }

    Invoke-SelfTest 'Patch LF normalization is explicit and deterministic for canonical CRLF blobs' {
        $patchDirectory = Join-Path $script:TestRoot 'inputs\patches'
        [void](New-Item -ItemType Directory -Path $patchDirectory)
        $patchPath = Join-Path $patchDirectory '0001-fixture.patch'
        $patchText = @(
            'diff --git a/fixture.txt b/fixture.txt'
            '--- a/fixture.txt'
            '+++ b/fixture.txt'
            '@@ -1 +1 @@'
            '-upstream'
            '+patched'
            ''
        ) -join "`n"
        [IO.File]::WriteAllText($patchPath, $patchText, [Text.UTF8Encoding]::new($false))
        $preCrlfCommit = Invoke-Git @('-C', $checkout, 'rev-parse', 'HEAD')
        [IO.File]::WriteAllBytes(
            (Join-Path $checkout 'fixture.txt'),
            [Text.Encoding]::ASCII.GetBytes("upstream`r`n")
        )
        Invoke-Git @('-C', $checkout, 'add', 'fixture.txt') | Out-Null
        Invoke-Git @('-C', $checkout, 'commit', '-q', '-m', 'Canonical CRLF fixture') | Out-Null
        $crlfCommit = Invoke-Git @('-C', $checkout, 'rev-parse', 'HEAD')
        Assert-Equal (Invoke-Git @('-C', $checkout, 'cat-file', '-s', 'HEAD:fixture.txt')) '10'
        $lockText = [IO.File]::ReadAllText($script:LockPath).Replace($preCrlfCommit, $crlfCommit)
        [IO.File]::WriteAllText($script:LockPath, $lockText)
        $patchedExpected = Join-Path $script:TestRoot 'expected-patched'
        $patchedTree = New-ExpectedTree $patchedExpected -Fixture 'patched'
        $patchRecord = New-PatchRecord 'inputs/patches/0001-fixture.patch' $patchPath @('fixture.txt')
        Write-Plan $script:PlanPath @(New-Recipe @($patchRecord) @() $patchedTree)
        $savedGitEnvironment = @{}
        foreach ($gitVariable in @('GIT_DIR', 'GIT_WORK_TREE')) {
            $item = Get-Item -LiteralPath ('Env:' + $gitVariable) -ErrorAction SilentlyContinue
            $savedGitEnvironment[$gitVariable] = [pscustomobject]@{
                Present = $null -ne $item
                Name = if ($null -eq $item) { $gitVariable } else { [string]$item.Name }
                Value = if ($null -eq $item) { $null } else { [string]$item.Value }
            }
        }
        $parentIndexPath = Join-Path $script:TestRoot '.git\index'
        $parentIndexHash = (Get-FileHash $parentIndexPath -Algorithm SHA256).Hash
        $parentSentinelHash = (Get-FileHash `
            (Join-Path $script:TestRoot 'parent-sentinel.txt') -Algorithm SHA256).Hash
        [IO.File]::AppendAllText(
            (Join-Path $script:TestRoot '.git\info\exclude'),
            "`npatched-output/`n"
        )
        $parentStatusBefore = Invoke-Git @(
            '-C', $script:TestRoot, 'status', '--porcelain=v1', '--untracked-files=all'
        )
        try {
            Remove-Item -LiteralPath Env:GIT_DIR -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath Env:GIT_WORK_TREE -ErrorAction SilentlyContinue
            Set-Item -LiteralPath Env:Git_Dir -Value (Join-Path $script:TestRoot '.git')
            Set-Item -LiteralPath Env:GIT_WORK_TREE -Value $script:TestRoot
            Invoke-Preparation 'patched-output' | Out-Null
            Assert-Equal (
                [IO.File]::ReadAllText((Join-Path $script:TestRoot 'patched-output\vmdisp9x-gsw\fixture.txt'))
            ) "patched`n"
            $restoredGitDirectory = Get-Item -LiteralPath Env:GIT_DIR
            Assert-Equal ([string]$restoredGitDirectory.Name) 'Git_Dir' `
                'Preparation did not preserve the mixed-case GIT_DIR key.'
            Assert-Equal ([string]$restoredGitDirectory.Value) (Join-Path $script:TestRoot '.git')
            Assert-Equal ([Environment]::GetEnvironmentVariable('GIT_WORK_TREE', 'Process')) `
                $script:TestRoot
            Assert-Equal (Get-FileHash $parentIndexPath -Algorithm SHA256).Hash $parentIndexHash `
                'Patch application changed the unrelated parent repository index.'
            Assert-Equal (Get-FileHash `
                (Join-Path $script:TestRoot 'parent-sentinel.txt') -Algorithm SHA256).Hash `
                $parentSentinelHash 'Patch application changed the unrelated parent worktree.'
            Assert-Equal (Invoke-Git @(
                '-C', $script:TestRoot, 'status', '--porcelain=v1', '--untracked-files=all'
            )) $parentStatusBefore 'Patch application changed the unrelated parent repository.'
            Assert-Equal (Invoke-Git @('-C', $script:TestRoot, 'diff', '--exit-code')) ''
            Assert-Equal (Invoke-Git @('-C', $script:TestRoot, 'diff', '--cached', '--exit-code')) ''
            foreach ($gitVariable in @(
                'GIT_CEILING_DIRECTORIES', 'GIT_PREFIX', 'GIT_INDEX_FILE'
            )) {
                Assert-True (-not (Test-Path -LiteralPath ('Env:' + $gitVariable))) `
                    "Preparation leaked the $gitVariable environment variable."
            }
        }
        finally {
            foreach ($gitVariable in @('GIT_DIR', 'GIT_WORK_TREE')) {
                Remove-Item -LiteralPath ('Env:' + $gitVariable) -ErrorAction SilentlyContinue
                if ($savedGitEnvironment[$gitVariable].Present) {
                    Set-Item -LiteralPath (
                        'Env:' + [string]$savedGitEnvironment[$gitVariable].Name
                    ) -Value ([string]$savedGitEnvironment[$gitVariable].Value)
                }
            }
            [IO.File]::WriteAllText((Join-Path $checkout 'fixture.txt'), "upstream`n")
            Invoke-Git @('-C', $checkout, 'add', 'fixture.txt') | Out-Null
            Invoke-Git @('-C', $checkout, 'commit', '-q', '-m', 'Restore canonical LF fixture') | Out-Null
            $restoredCommit = Invoke-Git @('-C', $checkout, 'rev-parse', 'HEAD')
            $lockText = [IO.File]::ReadAllText($script:LockPath).Replace($crlfCommit, $restoredCommit)
            [IO.File]::WriteAllText($script:LockPath, $lockText)
            Write-Plan $script:PlanPath @(New-Recipe @() @($overlayRecord) $overlayOutputTree)
        }
    }

    Invoke-SelfTest 'Patch LF normalization rejects unsafe data and preserves undeclared blobs' {
        $beforeCommit = Invoke-Git @('-C', $checkout, 'rev-parse', 'HEAD')
        $fixturePath = Join-Path $checkout 'fixture.txt'
        $unrelatedPath = Join-Path $checkout 'unrelated-crlf.txt'
        $loneCrPath = Join-Path $checkout 'lone-cr.txt'
        $nulPath = Join-Path $checkout 'binary.dat'
        [IO.File]::WriteAllBytes($fixturePath, [Text.Encoding]::ASCII.GetBytes("upstream`r`n"))
        $unrelatedBytes = [Text.Encoding]::ASCII.GetBytes("unrelated`r`n")
        [IO.File]::WriteAllBytes($unrelatedPath, $unrelatedBytes)
        [IO.File]::WriteAllBytes($loneCrPath, [Text.Encoding]::ASCII.GetBytes("bad`ronly"))
        [IO.File]::WriteAllBytes($nulPath, [byte[]](0x61, 0x00, 0x0a))
        Invoke-Git @('-C', $checkout, 'add', 'fixture.txt', 'unrelated-crlf.txt', 'lone-cr.txt', 'binary.dat') | Out-Null
        Invoke-Git @('-C', $checkout, 'commit', '-q', '-m', 'LF normalization hardening fixtures') | Out-Null
        $fixtureCommit = Invoke-Git @('-C', $checkout, 'rev-parse', 'HEAD')
        $lockText = [IO.File]::ReadAllText($script:LockPath).Replace($beforeCommit, $fixtureCommit)
        [IO.File]::WriteAllText($script:LockPath, $lockText)

        $expectedRoot = Join-Path $script:TestRoot 'expected-normalized-scope'
        [void](New-Item -ItemType Directory -Path (Join-Path $expectedRoot 'sub') -Force)
        [IO.File]::WriteAllText((Join-Path $expectedRoot 'fixture.txt'), "patched`n")
        [IO.File]::WriteAllText((Join-Path $expectedRoot 'sub\existing.txt'), "existing`n")
        [IO.File]::WriteAllBytes((Join-Path $expectedRoot 'unrelated-crlf.txt'), $unrelatedBytes)
        [IO.File]::WriteAllBytes((Join-Path $expectedRoot 'lone-cr.txt'), [Text.Encoding]::ASCII.GetBytes("bad`ronly"))
        [IO.File]::WriteAllBytes((Join-Path $expectedRoot 'binary.dat'), [byte[]](0x61, 0x00, 0x0a))
        $expectedTree = Get-TestTreeDescriptor $expectedRoot
        $patchPath = Join-Path $script:TestRoot 'inputs\patches\0001-fixture.patch'
        try {
            $declaredPatch = New-PatchRecord 'inputs/patches/0001-fixture.patch' $patchPath @('fixture.txt')
            Write-Plan $script:PlanPath @(New-Recipe @($declaredPatch) @() $expectedTree)
            Invoke-Preparation 'normalized-scope' | Out-Null
            $normalizedRoot = Join-Path $script:TestRoot 'normalized-scope\vmdisp9x-gsw'
            Assert-Equal (ConvertTo-LowerHex ([IO.File]::ReadAllBytes(
                (Join-Path $normalizedRoot 'unrelated-crlf.txt')
            ))) (ConvertTo-LowerHex $unrelatedBytes) 'An undeclared CRLF blob changed.'
            Assert-Equal (Get-TestTreeDescriptor $normalizedRoot).Sha256 $expectedTree.Sha256

            foreach ($failure in @(
                [pscustomobject]@{ Name = 'missing-normalization'; Paths = @('missing.c'); Pattern = 'is not a regular file' },
                [pscustomobject]@{ Name = 'unsafe-normalization'; Paths = @('../fixture.txt'); Pattern = 'Unsafe path component' },
                [pscustomobject]@{ Name = 'duplicate-normalization'; Paths = @('fixture.txt', 'FIXTURE.TXT'); Pattern = 'duplicate LF-normalization' },
                [pscustomobject]@{ Name = 'lone-cr-normalization'; Paths = @('lone-cr.txt'); Pattern = 'isolated CR' },
                [pscustomobject]@{ Name = 'nul-normalization'; Paths = @('binary.dat'); Pattern = 'contains a NUL' }
            )) {
                $failingPatch = New-PatchRecord 'inputs/patches/0001-fixture.patch' $patchPath $failure.Paths
                Write-Plan $script:PlanPath @(New-Recipe @($failingPatch) @() $expectedTree)
                Assert-Throws { Invoke-Preparation $failure.Name } $failure.Pattern
                Assert-True (-not (Test-Path (Join-Path $script:TestRoot $failure.Name)))
            }

            $junctionTarget = Join-Path $script:TestRoot 'normalization-junction-target'
            [void](New-Item -ItemType Directory -Path $junctionTarget)
            [IO.File]::WriteAllText((Join-Path $junctionTarget 'existing.txt'), "external`r`n")
            $junctionPatch = New-PatchRecord 'inputs/patches/0001-fixture.patch' $patchPath @('sub/existing.txt')
            Write-Plan $script:PlanPath @(New-Recipe @($junctionPatch) @() $expectedTree)
            Assert-Throws {
                Invoke-Preparation 'reparse-normalization' -BeforePatchNormalization {
                    param($derivedRoot, $recipeName, $patchIndex)
                    $subPath = Join-Path $derivedRoot 'sub'
                    [IO.File]::Delete((Join-Path $subPath 'existing.txt'))
                    [IO.Directory]::Delete($subPath, $false)
                    $output = & cmd.exe /d /c "mklink /J `"$subPath`" `"$junctionTarget`"" 2>&1
                    if ($LASTEXITCODE -ne 0) { throw "mklink failed: $output" }
                }
            } 'Reparse-point component'
            Assert-Equal ([IO.File]::ReadAllText((Join-Path $junctionTarget 'existing.txt'))) "external`r`n"

            $overlayEscapeTarget = Join-Path $script:TestRoot 'overlay-junction-target'
            [void](New-Item -ItemType Directory -Path $overlayEscapeTarget)
            [IO.File]::WriteAllText((Join-Path $overlayEscapeTarget 'sentinel.txt'), 'external')
            $safePatch = New-PatchRecord 'inputs/patches/0001-fixture.patch' $patchPath @('fixture.txt')
            Write-Plan $script:PlanPath @(
                New-Recipe @($safePatch) @($overlayRecord) $expectedTree
            )
            Assert-Throws {
                Invoke-Preparation 'overlay-reparse-escape' -BeforePatchNormalization {
                    param($derivedRoot, $recipeName, $patchIndex)
                    $resPath = Join-Path $derivedRoot 'res'
                    $output = & cmd.exe /d /c "mklink /J `"$resPath`" `"$overlayEscapeTarget`"" 2>&1
                    if ($LASTEXITCODE -ne 0) { throw "mklink failed: $output" }
                }
            } 'Reparse points are not allowed in a derived tree'
            Assert-True (-not (Test-Path (Join-Path $overlayEscapeTarget 'gswmini.rc'))) `
                'An overlay wrote through a patch-created junction.'
        }
        finally {
            foreach ($path in @($unrelatedPath, $loneCrPath, $nulPath)) {
                if (Test-Path -LiteralPath $path) { [IO.File]::Delete($path) }
            }
            [IO.File]::WriteAllText($fixturePath, "upstream`n")
            Invoke-Git @('-C', $checkout, 'add', '-u') | Out-Null
            Invoke-Git @('-C', $checkout, 'commit', '-q', '-m', 'Remove LF normalization hardening fixtures') | Out-Null
            $restoredCommit = Invoke-Git @('-C', $checkout, 'rev-parse', 'HEAD')
            $lockText = [IO.File]::ReadAllText($script:LockPath).Replace($fixtureCommit, $restoredCommit)
            [IO.File]::WriteAllText($script:LockPath, $lockText)
            Write-Plan $script:PlanPath @(New-Recipe @() @($overlayRecord) $overlayOutputTree)
        }
    }

    Invoke-SelfTest 'Final tree mismatch and between-scan mutation both fail closed' {
        $wrongRecipe = New-Recipe @() @($overlayRecord) $overlayOutputTree
        $wrongRecipe.output_tree.sha256 = '0' * 64
        Write-Plan $script:PlanPath @($wrongRecipe)
        Assert-Throws { Invoke-Preparation 'wrong-tree' } 'first scan Sha256 mismatch'
        Assert-True (-not (Test-Path (Join-Path $script:TestRoot 'wrong-tree')))

        Write-Plan $script:PlanPath @(New-Recipe @() @($overlayRecord) $overlayOutputTree)
        Assert-Throws {
            Invoke-Preparation 'between-scan' -BeforeSecondScan {
                param($derivedPath, $recipeName)
                [IO.File]::WriteAllText((Join-Path $derivedPath 'late.tmp'), $recipeName)
            }
        } 'second scan .* mismatch'
        Assert-True (-not (Test-Path (Join-Path $script:TestRoot 'between-scan')))

        Assert-Throws {
            Invoke-Preparation 'before-publication' -BeforeFinalPublication {
                param($privateRoot)
                [IO.File]::WriteAllText(
                    (Join-Path $privateRoot 'vmdisp9x-gsw\late-publication.tmp'),
                    'late'
                )
            }
        } 'final publication scan .* mismatch'
        Assert-True (-not (Test-Path (Join-Path $script:TestRoot 'before-publication')))
    }

    Invoke-SelfTest 'Dirty upstream and malformed metadata never publish output' {
        [IO.File]::WriteAllText((Join-Path $checkout 'dirty.tmp'), 'dirty')
        try {
            Assert-Throws { Invoke-Preparation 'dirty-source' } 'has local changes'
            Assert-True (-not (Test-Path (Join-Path $script:TestRoot 'dirty-source')))
        }
        finally {
            Remove-Item -LiteralPath (Join-Path $checkout 'dirty.tmp')
        }

        $validJson = [IO.File]::ReadAllText($script:PlanPath)
        $duplicateJson = $validJson -replace '("schema"\s*:\s*2\s*,)', '$1 "SCHEMA": 2,'
        Assert-True ($duplicateJson -cne $validJson) 'The duplicate-key mutation was not applied.'
        [IO.File]::WriteAllText($script:PlanPath, $duplicateJson)
        try {
            Assert-Throws { Invoke-Preparation 'duplicate-json' } 'Duplicate JSON property'
        }
        finally {
            [IO.File]::WriteAllText($script:PlanPath, $validJson)
        }
    }

    Invoke-SelfTest 'A reparse-point source directory is rejected before Git traversal' {
        $junctionSourceRoot = Join-Path $script:TestRoot 'junction-source-root'
        [void](New-Item -ItemType Directory -Path $junctionSourceRoot)
        $junctionCheckout = Join-Path $junctionSourceRoot 'vmdisp9x'
        $output = & cmd.exe /d /c "mklink /J `"$junctionCheckout`" `"$checkout`"" 2>&1
        if ($LASTEXITCODE -ne 0) { throw "mklink failed: $output" }
        try {
            Assert-Throws {
                & $script:PrepareScript -SourceRoot $junctionSourceRoot `
                    -OutputRoot (Join-Path $script:TestRoot 'junction-source-output') `
                    -RecipePlan $script:PlanPath -RecipeRoot $script:TestRoot `
                    -LockFile $script:LockPath
            } 'Reparse-point component.*source'
            Assert-True (-not (Test-Path (Join-Path $script:TestRoot 'junction-source-output')))
        }
        finally {
            if (Test-Path -LiteralPath $junctionCheckout) {
                [IO.Directory]::Delete($junctionCheckout, $false)
            }
            if (Test-Path -LiteralPath $junctionSourceRoot) {
                [IO.Directory]::Delete($junctionSourceRoot, $false)
            }
        }
    }

    Invoke-SelfTest 'Populated pinned gitlinks are copied as tracked source files' {
        $savedPath = $env:PATH
        $gitRoot = Split-Path -Parent (Split-Path -Parent (Get-Command git).Source)
        $gitUnixTools = Join-Path $gitRoot 'usr\bin'
        $gitRuntime = Join-Path $gitRoot 'mingw64\bin'
        $gitExecPath = (& git --exec-path).Trim().Replace('/', '\')
        if (Test-Path -LiteralPath $gitUnixTools -PathType Container) {
            $env:PATH = "$gitUnixTools;$gitRuntime;$gitExecPath;$savedPath"
        }
        try {
            $submoduleRepository = Join-Path $script:TestRoot 'fixlink-repository'
            [void](New-Item -ItemType Directory -Path $submoduleRepository)
            Invoke-Git @('init', '-q', $submoduleRepository) | Out-Null
            Invoke-Git @('-C', $submoduleRepository, 'config', 'user.name', 'RETVRN99 Test') | Out-Null
            Invoke-Git @('-C', $submoduleRepository, 'config', 'user.email', 'test@retvrn99.invalid') | Out-Null
            [IO.File]::WriteAllText((Join-Path $submoduleRepository 'linked.txt'), 'pinned gitlink')
            Invoke-Git @('-C', $submoduleRepository, 'add', 'linked.txt') | Out-Null
            Invoke-Git @('-C', $submoduleRepository, 'commit', '-q', '-m', 'Pinned gitlink fixture') | Out-Null
            Invoke-Git @(
                '-c', 'protocol.file.allow=always', 'clone', '-q',
                $submoduleRepository, (Join-Path $checkout 'fixlink')
            ) | Out-Null
            $submoduleUrl = $submoduleRepository.Replace('\', '/')
            $gitmodules = @(
                '[submodule "fixlink"]'
                "`tpath = fixlink"
                "`turl = $submoduleUrl"
            ) -join "`n"
            [IO.File]::WriteAllText((Join-Path $checkout '.gitmodules'), $gitmodules + "`n")
            Invoke-Git @('-C', $checkout, 'add', '.gitmodules') | Out-Null
            $submoduleCommit = Invoke-Git @('-C', $submoduleRepository, 'rev-parse', 'HEAD')
            Invoke-Git @(
                '-C', $checkout, 'update-index', '--add', '--cacheinfo',
                "160000,$submoduleCommit,fixlink"
            ) | Out-Null
            Invoke-Git @('-C', $checkout, 'commit', '-q', '-m', 'Add pinned gitlink') | Out-Null
            $commitWithGitlink = Invoke-Git @('-C', $checkout, 'rev-parse', 'HEAD')
            $lockContentsWithGitlink = @(
                '# SPDX-License-Identifier: GPL-3.0-only'
                "name`tsource_directory`trepository`tcommit`tupstream_license`tdisposition`tclosure_manifest`tclosure_manifest_sha256`tscope"
                "vmdisp9x`tvmdisp9x`thttps://example.invalid/vmdisp9x.git`t$commitWithGitlink`tMIT`tplanned`t`t`tdisplay-driver"
            ) -join "`r`n"
            [IO.File]::WriteAllText($script:LockPath, $lockContentsWithGitlink + "`r`n")

            $expectedWithGitlinkPath = Join-Path $script:TestRoot 'expected-gitlink'
            [void](New-ExpectedTree $expectedWithGitlinkPath -OverlayRoot $overlayPath)
            Copy-Item -LiteralPath (Join-Path $checkout '.gitmodules') -Destination $expectedWithGitlinkPath
            [void](New-Item -ItemType Directory -Path (Join-Path $expectedWithGitlinkPath 'fixlink'))
            Copy-Item -LiteralPath (Join-Path $checkout 'fixlink\linked.txt') `
                -Destination (Join-Path $expectedWithGitlinkPath 'fixlink')
            $treeWithGitlink = Get-TestTreeDescriptor $expectedWithGitlinkPath
            Write-Plan $script:PlanPath @(
                New-Recipe @() @($overlayRecord) $treeWithGitlink
            )
            Invoke-Preparation 'gitlink-output' | Out-Null
            $linkedOutput = Join-Path $script:TestRoot 'gitlink-output\vmdisp9x-gsw\fixlink\linked.txt'
            Assert-Equal ([IO.File]::ReadAllText($linkedOutput)) 'pinned gitlink'
            Assert-Equal (Invoke-Git @('-C', $checkout, 'status', '--porcelain')) ''

            $submoduleCheckout = Join-Path $checkout 'fixlink'
            $movedSubmodule = Join-Path $script:TestRoot 'fixlink-real'
            Move-Item -LiteralPath $submoduleCheckout -Destination $movedSubmodule
            $output = & cmd.exe /d /c "mklink /J `"$submoduleCheckout`" `"$movedSubmodule`"" 2>&1
            if ($LASTEXITCODE -ne 0) { throw "mklink failed: $output" }
            try {
                Assert-Throws { Invoke-Preparation 'gitlink-junction-output' } `
                    'Reparse-point component.*tracked gitlink'
                Assert-True (-not (Test-Path (Join-Path $script:TestRoot 'gitlink-junction-output')))
            }
            finally {
                if (Test-Path -LiteralPath $submoduleCheckout) {
                    [IO.Directory]::Delete($submoduleCheckout, $false)
                }
                Move-Item -LiteralPath $movedSubmodule -Destination $submoduleCheckout
            }
        }
        finally {
            $env:PATH = $savedPath
        }
    }
}
finally {
    $verifiedTestRoot = [IO.Path]::GetFullPath($script:TestRoot)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if (-not $verifiedTestRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        -not ([IO.Path]::GetFileName($verifiedTestRoot)).StartsWith('retvrn99-win98-derived-test-')) {
        throw "Refusing to remove unverified derived-source test path '$verifiedTestRoot'."
    }
    if (Test-Path -LiteralPath $verifiedTestRoot) {
        Remove-Item -LiteralPath $verifiedTestRoot -Recurse -Force
    }
}

if ($script:Failures -ne 0) {
    throw "$script:Failures Windows 98 derived-source test(s) failed."
}
Write-Host 'All Windows 98 derived-source tests passed.'
