# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Failures = 0
$script:Junctions = New-Object Collections.Generic.List[string]

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

    try { & $Body | Out-Null }
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

function Get-FileRecord {
    param(
        [Parameter(Mandatory = $true)]$Fixture,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$PayloadPath
    )

    $blob = Invoke-Git @('-C', $Fixture.Checkout, 'rev-parse', "HEAD:$RelativePath")
    $item = Get-Item -LiteralPath $PayloadPath
    return [ordered]@{
        relative_path = $RelativePath
        git_blob = $blob
        bytes = [UInt64]$item.Length
        sha256 = (Get-FileHash -LiteralPath $PayloadPath -Algorithm SHA256).Hash.ToLowerInvariant()
        license_expression = 'MIT'
        notice_id = 'mit'
        source_prefix_id = 'src'
        role = 'fixture'
    }
}

function Get-NoticeRecord {
    param([Parameter(Mandatory = $true)]$Fixture)

    $path = Join-Path $Fixture.Checkout 'LICENSE'
    return [ordered]@{
        id = 'mit'
        relative_path = 'LICENSE'
        git_blob = Invoke-Git @('-C', $Fixture.Checkout, 'rev-parse', 'HEAD:LICENSE')
        bytes = [UInt64](Get-Item -LiteralPath $path).Length
        sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        license_expression = 'MIT'
    }
}

function Write-Lock {
    param(
        [Parameter(Mandatory = $true)]$Fixture,
        [Parameter(Mandatory = $true)][string]$ManifestRelativePath,
        [Parameter(Mandatory = $true)][string]$ManifestHash
    )

    $lines = @(
        '# SPDX-License-Identifier: GPL-3.0-only'
        "name`tsource_directory`trepository`tcommit`tupstream_license`tdisposition`tclosure_manifest`tclosure_manifest_sha256`tscope"
        "component`tcomponent`thttps://example.invalid/component.git`t$($Fixture.Commit)`tMIT`tplanned-component`t$ManifestRelativePath`t$ManifestHash`tfixture"
    )
    [IO.File]::WriteAllText($Fixture.LockPath, (($lines -join "`r`n") + "`r`n"))
}

function Write-Manifest {
    param(
        [Parameter(Mandatory = $true)]$Fixture,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Files,
        [string]$Status = 'ready',
        [string]$Reason = ''
    )

    [object[]]$noticeRecords = @()
    if ($Status -eq 'ready') {
        $noticeRecords = [object[]]@((Get-NoticeRecord $Fixture))
    }
    [object[]]$fileRecords = @($Files)
    $manifest = [ordered]@{
        _spdx = 'GPL-3.0-only'
        schema = 1
        status = $Status
        reason = $Reason
        upstream_name = 'component'
        owning_commit = $Fixture.Commit
        source_prefixes = @([ordered]@{
            id = 'src'
            relative_path = 'src'
            mode = 'subtree'
        })
        notices = $noticeRecords
        files = $fileRecords
    }
    [IO.File]::WriteAllText($Path, ($manifest | ConvertTo-Json -Depth 12))
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-Plan {
    param(
        [Parameter(Mandatory = $true)]$Fixture,
        [Parameter(Mandatory = $true)][string]$ManifestRelativePath,
        [Parameter(Mandatory = $true)][string]$ManifestHash,
        [object]$OutputTree,
        [string]$Status = 'ready',
        [string]$Reason = ''
    )

    $recipe = [ordered]@{
        name = 'component-derived'
        upstream_name = 'component'
        source_directory = 'component'
        destination_directory = 'component-derived'
        source_selection = [ordered]@{
            mode = 'component-closure'
            closure_manifest = $ManifestRelativePath
            closure_manifest_sha256 = $ManifestHash
        }
        patches = @()
        overlays = @()
    }
    if ($null -ne $OutputTree) { $recipe.output_tree = $OutputTree }
    $plan = [ordered]@{
        _spdx = 'GPL-3.0-only'
        schema = 3
        status = $Status
        reason = $Reason
        recipes = @($recipe)
    }
    [IO.File]::WriteAllText($Fixture.PlanPath, ($plan | ConvertTo-Json -Depth 12))
}

function New-Fixture {
    $root = Join-Path $script:TestRoot ([Guid]::NewGuid().ToString('N'))
    $sourceRoot = Join-Path $root 'sources'
    $checkout = Join-Path $sourceRoot 'component'
    $metadataRoot = Join-Path $root 'metadata'
    [void](New-Item -ItemType Directory -Path (Join-Path $checkout 'src') -Force)
    [void](New-Item -ItemType Directory -Path $metadataRoot -Force)
    Invoke-Git @('init', '-q', $checkout) | Out-Null
    Invoke-Git @('-C', $checkout, 'config', 'user.name', 'RETVRN99 Component Test') | Out-Null
    Invoke-Git @('-C', $checkout, 'config', 'user.email', 'component@retvrn99.invalid') | Out-Null
    Invoke-Git @('-C', $checkout, 'config', 'core.autocrlf', 'false') | Out-Null
    [IO.File]::WriteAllText((Join-Path $checkout 'LICENSE'), "MIT fixture notice`n")
    [IO.File]::WriteAllText((Join-Path $checkout 'src\keep.c'), "int keep(void) { return 1; }`n")
    [IO.File]::WriteAllText((Join-Path $checkout 'src\omit.c'), "int omit(void) { return 0; }`n")
    Invoke-Git @('-C', $checkout, 'add', 'LICENSE', 'src/keep.c', 'src/omit.c') | Out-Null
    Invoke-Git @('-C', $checkout, 'commit', '-q', '-m', 'Pinned component fixture') | Out-Null
    Invoke-Git @('-C', $checkout, 'remote', 'add', 'origin', 'https://example.invalid/component.git') | Out-Null
    return [pscustomobject]@{
        Root = $root
        SourceRoot = $sourceRoot
        Checkout = $checkout
        MetadataRoot = $metadataRoot
        ManifestPath = Join-Path $metadataRoot 'closure.json'
        ManifestRelativePath = 'metadata/closure.json'
        LockPath = Join-Path $root 'upstream.lock.tsv'
        PlanPath = Join-Path $root 'derived-plan.json'
        Commit = Invoke-Git @('-C', $checkout, 'rev-parse', 'HEAD')
    }
}

function Add-VirtualIndexRecord {
    param(
        [Parameter(Mandatory = $true)]$Fixture,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Mode,
        [Parameter(Mandatory = $true)][string]$Contents
    )

    $payload = Join-Path $Fixture.MetadataRoot ([Guid]::NewGuid().ToString('N') + '.bin')
    [IO.File]::WriteAllText($payload, $Contents)
    $blob = Invoke-Git @('-C', $Fixture.Checkout, 'hash-object', '-w', '--', $payload)
    Invoke-Git @(
        '-C', $Fixture.Checkout, 'update-index', '--add', '--cacheinfo',
        "$Mode,$blob,$RelativePath"
    ) | Out-Null
    Invoke-Git @('-C', $Fixture.Checkout, 'commit', '-q', '-m', "Add $RelativePath") | Out-Null
    if ($Mode -ne '160000') {
        Invoke-Git @('-C', $Fixture.Checkout, 'update-index', '--skip-worktree', '--', $RelativePath) | Out-Null
    }
    $Fixture.Commit = Invoke-Git @('-C', $Fixture.Checkout, 'rev-parse', 'HEAD')
    return [ordered]@{
        relative_path = $RelativePath
        git_blob = $blob
        bytes = [UInt64](Get-Item -LiteralPath $payload).Length
        sha256 = (Get-FileHash -LiteralPath $payload -Algorithm SHA256).Hash.ToLowerInvariant()
        license_expression = 'MIT'
        notice_id = 'mit'
        source_prefix_id = 'src'
        role = 'fixture'
    }
}

function Get-ReadyFixture {
    $fixture = New-Fixture
    $record = Get-FileRecord $fixture 'src/keep.c' (Join-Path $fixture.Checkout 'src\keep.c')
    $manifestHash = Write-Manifest $fixture $fixture.ManifestPath @($record)
    Write-Lock $fixture $fixture.ManifestRelativePath $manifestHash
    Write-Plan $fixture $fixture.ManifestRelativePath $manifestHash $null `
        -Status 'draft' -Reason 'descriptor authoring'
    $description = & $script:PrepareScript -SourceRoot $fixture.SourceRoot `
        -RecipePlan $fixture.PlanPath -RecipeRoot $fixture.Root `
        -LockFile $fixture.LockPath -DescribeRecipe 'component-derived' | ConvertFrom-Json
    Write-Plan $fixture $fixture.ManifestRelativePath $manifestHash $description.output_tree
    return $fixture
}

function Invoke-Preparation {
    param(
        [Parameter(Mandatory = $true)]$Fixture,
        [Parameter(Mandatory = $true)][string]$OutputName,
        [scriptblock]$BeforeFinalPublication
    )

    $arguments = @{
        SourceRoot = $Fixture.SourceRoot
        OutputRoot = Join-Path $Fixture.Root $OutputName
        RecipePlan = $Fixture.PlanPath
        RecipeRoot = $Fixture.Root
        LockFile = $Fixture.LockPath
    }
    if ($null -ne $BeforeFinalPublication) {
        $arguments.BeforeFinalPublication = $BeforeFinalPublication
    }
    return @(& $script:PrepareScript @arguments)
}

if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
    throw 'git is required for component-derived source tests.'
}

$script:PrepareScript = Join-Path $PSScriptRoot 'prepare-win98-derived-sources.ps1'
$script:TestRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'retvrn99-component-derived-test-' + [Guid]::NewGuid().ToString('N')
)
[void](New-Item -ItemType Directory -Path $script:TestRoot)

try {
    Invoke-SelfTest 'Schema 3 explicitly preserves whole-upstream derivation' {
        $fixture = New-Fixture
        $lines = @(
            '# SPDX-License-Identifier: GPL-3.0-only'
            "name`tsource_directory`trepository`tcommit`tupstream_license`tdisposition`tclosure_manifest`tclosure_manifest_sha256`tscope"
            "component`tcomponent`thttps://example.invalid/component.git`t$($fixture.Commit)`tMIT`tplanned`t`t`tfixture"
        )
        [IO.File]::WriteAllText($fixture.LockPath, (($lines -join "`r`n") + "`r`n"))
        $overlay = Join-Path $fixture.Root 'whole-overlay'
        [void](New-Item -ItemType Directory -Path $overlay)
        [IO.File]::WriteAllText((Join-Path $overlay 'whole.txt'), "whole`n")
        $overlayTree = & $script:PrepareScript -DescribeTree $overlay | ConvertFrom-Json
        $recipe = [ordered]@{
            name = 'component-derived'
            upstream_name = 'component'
            source_directory = 'component'
            destination_directory = 'component-derived'
            source_selection = [ordered]@{ mode = 'whole-upstream' }
            patches = @()
            overlays = @([ordered]@{
                relative_path = 'whole-overlay'
                destination_relative_path = '.'
                replace_existing = $false
                tree = $overlayTree
            })
        }
        $plan = [ordered]@{
            _spdx = 'GPL-3.0-only'; schema = 3; status = 'draft'
            reason = 'descriptor authoring'; recipes = @($recipe)
        }
        [IO.File]::WriteAllText($fixture.PlanPath, ($plan | ConvertTo-Json -Depth 12))
        $description = & $script:PrepareScript -SourceRoot $fixture.SourceRoot `
            -RecipePlan $fixture.PlanPath -RecipeRoot $fixture.Root `
            -LockFile $fixture.LockPath -DescribeRecipe 'component-derived' | ConvertFrom-Json
        $recipe['output_tree'] = $description.output_tree
        $plan.status = 'ready'
        $plan.reason = ''
        [IO.File]::WriteAllText($fixture.PlanPath, ($plan | ConvertTo-Json -Depth 12))
        Invoke-Preparation $fixture 'whole-output' | Out-Null
        $output = Join-Path $fixture.Root 'whole-output\component-derived'
        Assert-True (Test-Path -LiteralPath (Join-Path $output 'src\omit.c') -PathType Leaf)
        Assert-True (Test-Path -LiteralPath (Join-Path $output 'whole.txt') -PathType Leaf)
    }

    Invoke-SelfTest 'Component closure materializes exact declared blobs only' {
        $fixture = Get-ReadyFixture
        Invoke-Preparation $fixture 'output' | Out-Null
        $output = Join-Path $fixture.Root 'output\component-derived'
        Assert-True (Test-Path -LiteralPath (Join-Path $output 'LICENSE') -PathType Leaf)
        Assert-True (Test-Path -LiteralPath (Join-Path $output 'src\keep.c') -PathType Leaf)
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $output 'src\omit.c')))
        Assert-Equal ([IO.File]::ReadAllText((Join-Path $output 'src\keep.c'))) `
            ([IO.File]::ReadAllText((Join-Path $fixture.Checkout 'src\keep.c')))
    }

    Invoke-SelfTest 'Blocked and hash-mismatched component closures never publish' {
        $blocked = New-Fixture
        $blockedHash = Write-Manifest $blocked $blocked.ManifestPath @() `
            -Status 'blocked' -Reason 'license review required'
        Write-Lock $blocked $blocked.ManifestRelativePath $blockedHash
        Write-Plan $blocked $blocked.ManifestRelativePath $blockedHash ([ordered]@{
            file_count = 1; directory_count = 0; total_entries = 1; aggregate_bytes = 1
            maximum_file_bytes = 1; maximum_path_bytes = 1
            digest_algorithm = 'retvrn99-file-tree-sha256-v1'; sha256 = ('0' * 64)
        })
        Assert-Throws { Invoke-Preparation $blocked 'blocked-output' } 'is blocked'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $blocked.Root 'blocked-output')))

        $mismatch = New-Fixture
        $record = Get-FileRecord $mismatch 'src/keep.c' (Join-Path $mismatch.Checkout 'src\keep.c')
        $originalHash = Write-Manifest $mismatch $mismatch.ManifestPath @($record)
        Write-Lock $mismatch $mismatch.ManifestRelativePath $originalHash
        Write-Plan $mismatch $mismatch.ManifestRelativePath $originalHash ([ordered]@{
            file_count = 1; directory_count = 0; total_entries = 1; aggregate_bytes = 1
            maximum_file_bytes = 1; maximum_path_bytes = 1
            digest_algorithm = 'retvrn99-file-tree-sha256-v1'; sha256 = ('0' * 64)
        })
        [IO.File]::AppendAllText($mismatch.ManifestPath, "`n")
        Assert-Throws { Invoke-Preparation $mismatch 'mismatch-output' } 'hash mismatch'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $mismatch.Root 'mismatch-output')))
    }

    Invoke-SelfTest 'Gitlinks and nonregular component records are rejected' {
        $gitlink = New-Fixture
        Invoke-Git @(
            '-C', $gitlink.Checkout, 'update-index', '--add', '--cacheinfo',
            "160000,$($gitlink.Commit),src/gitlink"
        ) | Out-Null
        Invoke-Git @('-C', $gitlink.Checkout, 'commit', '-q', '-m', 'Add gitlink') | Out-Null
        Invoke-Git @(
            '-C', $gitlink.Checkout, 'update-index', '--skip-worktree', '--', 'src/gitlink'
        ) | Out-Null
        $gitlink.Commit = Invoke-Git @('-C', $gitlink.Checkout, 'rev-parse', 'HEAD')
        $record = [ordered]@{
            relative_path = 'src/gitlink'; git_blob = $gitlink.Commit; bytes = 1
            sha256 = ('0' * 64); license_expression = 'MIT'; notice_id = 'mit'
            source_prefix_id = 'src'; role = 'fixture'
        }
        $hash = Write-Manifest $gitlink $gitlink.ManifestPath @($record)
        Write-Lock $gitlink $gitlink.ManifestRelativePath $hash
        Write-Plan $gitlink $gitlink.ManifestRelativePath $hash ([ordered]@{
            file_count = 1; directory_count = 0; total_entries = 1; aggregate_bytes = 1
            maximum_file_bytes = 1; maximum_path_bytes = 1
            digest_algorithm = 'retvrn99-file-tree-sha256-v1'; sha256 = ('0' * 64)
        })
        Assert-Throws { Invoke-Preparation $gitlink 'gitlink-output' } 'gitlink'

        $nonregular = New-Fixture
        $symlinkRecord = Add-VirtualIndexRecord $nonregular 'src/link.c' '120000' 'keep.c'
        $hash = Write-Manifest $nonregular $nonregular.ManifestPath @($symlinkRecord)
        Write-Lock $nonregular $nonregular.ManifestRelativePath $hash
        Write-Plan $nonregular $nonregular.ManifestRelativePath $hash ([ordered]@{
            file_count = 1; directory_count = 0; total_entries = 1; aggregate_bytes = 1
            maximum_file_bytes = 1; maximum_path_bytes = 1
            digest_algorithm = 'retvrn99-file-tree-sha256-v1'; sha256 = ('0' * 64)
        })
        Assert-Throws { Invoke-Preparation $nonregular 'nonregular-output' } 'exact regular'
    }

    Invoke-SelfTest 'Case-folded and DOS 8.3 component paths are rejected' {
        $caseFixture = New-Fixture
        $record = Get-FileRecord $caseFixture 'src/keep.c' (Join-Path $caseFixture.Checkout 'src\keep.c')
        $caseRecord = [ordered]@{}
        foreach ($key in $record.Keys) { $caseRecord[$key] = $record[$key] }
        $caseRecord.relative_path = 'SRC/KEEP.C'
        $hash = Write-Manifest $caseFixture $caseFixture.ManifestPath @($record, $caseRecord)
        Write-Lock $caseFixture $caseFixture.ManifestRelativePath $hash
        Write-Plan $caseFixture $caseFixture.ManifestRelativePath $hash ([ordered]@{
            file_count = 1; directory_count = 0; total_entries = 1; aggregate_bytes = 1
            maximum_file_bytes = 1; maximum_path_bytes = 1
            digest_algorithm = 'retvrn99-file-tree-sha256-v1'; sha256 = ('0' * 64)
        })
        Assert-Throws { Invoke-Preparation $caseFixture 'case-output' } 'duplicate path'

        $shortFixture = New-Fixture
        $longRecord = Add-VirtualIndexRecord $shortFixture 'src/longfilename.c' '100644' "long`n"
        $shortRecord = Add-VirtualIndexRecord $shortFixture 'src/LONGFI~1.C' '100644' "short`n"
        $hash = Write-Manifest $shortFixture $shortFixture.ManifestPath @($longRecord, $shortRecord)
        Write-Lock $shortFixture $shortFixture.ManifestRelativePath $hash
        Write-Plan $shortFixture $shortFixture.ManifestRelativePath $hash ([ordered]@{
            file_count = 1; directory_count = 0; total_entries = 1; aggregate_bytes = 1
            maximum_file_bytes = 1; maximum_path_bytes = 1
            digest_algorithm = 'retvrn99-file-tree-sha256-v1'; sha256 = ('0' * 64)
        })
        Assert-Throws { Invoke-Preparation $shortFixture 'short-output' } 'DOS 8.3 path collision'
    }

    Invoke-SelfTest 'Component manifest escape and reparse traversal are rejected' {
        $escape = New-Fixture
        $escapePath = Join-Path $script:TestRoot 'escape.json'
        $record = Get-FileRecord $escape 'src/keep.c' (Join-Path $escape.Checkout 'src\keep.c')
        $hash = Write-Manifest $escape $escapePath @($record)
        Write-Lock $escape '../escape.json' $hash
        Write-Plan $escape '../escape.json' $hash ([ordered]@{
            file_count = 1; directory_count = 0; total_entries = 1; aggregate_bytes = 1
            maximum_file_bytes = 1; maximum_path_bytes = 1
            digest_algorithm = 'retvrn99-file-tree-sha256-v1'; sha256 = ('0' * 64)
        })
        Assert-Throws { Invoke-Preparation $escape 'escape-output' } 'Unsafe (relative )?path|escapes'

        $reparse = New-Fixture
        $realRoot = Join-Path $reparse.Root 'real-metadata'
        $linkedRoot = Join-Path $reparse.Root 'linked-metadata'
        [void](New-Item -ItemType Directory -Path $realRoot)
        [void](New-Item -ItemType Junction -Path $linkedRoot -Target $realRoot)
        [void]$script:Junctions.Add($linkedRoot)
        $linkedManifest = Join-Path $realRoot 'closure.json'
        $record = Get-FileRecord $reparse 'src/keep.c' (Join-Path $reparse.Checkout 'src\keep.c')
        $hash = Write-Manifest $reparse $linkedManifest @($record)
        Write-Lock $reparse 'linked-metadata/closure.json' $hash
        Write-Plan $reparse 'linked-metadata/closure.json' $hash ([ordered]@{
            file_count = 1; directory_count = 0; total_entries = 1; aggregate_bytes = 1
            maximum_file_bytes = 1; maximum_path_bytes = 1
            digest_algorithm = 'retvrn99-file-tree-sha256-v1'; sha256 = ('0' * 64)
        })
        Assert-Throws { Invoke-Preparation $reparse 'reparse-output' } 'reparse point'
    }

    Invoke-SelfTest 'Component mutation before publication fails closed' {
        $fixture = Get-ReadyFixture
        $output = Join-Path $fixture.Root 'mutated-output'
        Assert-Throws {
            Invoke-Preparation $fixture 'mutated-output' -BeforeFinalPublication {
                param($privateRoot)
                [IO.File]::AppendAllText((Join-Path $fixture.Checkout 'src\keep.c'), "mutation`n")
            }
        } 'local changes|changed before publication'
        Assert-True (-not (Test-Path -LiteralPath $output))
    }

    Invoke-SelfTest 'Component lock retargeting before publication fails closed' {
        $fixture = Get-ReadyFixture
        $secondManifest = Join-Path $fixture.MetadataRoot 'closure-second.json'
        $omitRecord = Get-FileRecord $fixture 'src/omit.c' `
            (Join-Path $fixture.Checkout 'src\omit.c')
        $secondHash = Write-Manifest $fixture $secondManifest @($omitRecord)
        $replacementLock = @(
            '# SPDX-License-Identifier: GPL-3.0-only'
            "name`tsource_directory`trepository`tcommit`tupstream_license`tdisposition`tclosure_manifest`tclosure_manifest_sha256`tscope"
            "component`tcomponent`thttps://example.invalid/component.git`t$($fixture.Commit)`tMIT`tplanned-component`tmetadata/closure-second.json`t$secondHash`tfixture"
        ) -join "`r`n"
        $replacementLock += "`r`n"
        $originalLock = [IO.File]::ReadAllText($fixture.LockPath)
        [IO.File]::WriteAllText($fixture.LockPath, $replacementLock)
        try {
            $verification = @(& (Join-Path $PSScriptRoot 'verify-win98-component-closure.ps1') `
                -SourceRoot $fixture.SourceRoot -LockFile $fixture.LockPath `
                -SourceName @('component'))
            Assert-True (($verification -join ' ') -match 'Verified 1 ready') `
                'The replacement component closure did not verify as ready.'
        }
        finally {
            [IO.File]::WriteAllText($fixture.LockPath, $originalLock)
        }
        $output = Join-Path $fixture.Root 'retargeted-output'
        Assert-Throws {
            Invoke-Preparation $fixture 'retargeted-output' -BeforeFinalPublication {
                param($privateRoot)
                [IO.File]::WriteAllText($fixture.LockPath, $replacementLock)
            }
        } 'authoritative upstream lock changed'
        Assert-True (-not (Test-Path -LiteralPath $output))
    }

    Invoke-SelfTest 'Authoritative lock snapshot enforces byte and row bounds' {
        $oversized = Get-ReadyFixture
        [IO.File]::AppendAllText($oversized.LockPath, ('x' * 1048576))
        Assert-Throws { Invoke-Preparation $oversized 'oversized-lock-output' } `
            'hard byte bound'
        Assert-True (-not (Test-Path -LiteralPath (
            Join-Path $oversized.Root 'oversized-lock-output'
        )))

        $tooMany = Get-ReadyFixture
        $header = "name`tsource_directory`trepository`tcommit`tupstream_license`tdisposition`tclosure_manifest`tclosure_manifest_sha256`tscope"
        $row = "component`tcomponent`thttps://example.invalid/component.git`t$($tooMany.Commit)`tMIT`tplanned-component`t$($tooMany.ManifestRelativePath)`t$((Get-FileHash $tooMany.ManifestPath -Algorithm SHA256).Hash.ToLowerInvariant())`tfixture"
        $rows = New-Object Collections.Generic.List[string]
        [void]$rows.Add('# SPDX-License-Identifier: GPL-3.0-only')
        [void]$rows.Add($header)
        for ($index = 0; $index -lt 257; $index++) { [void]$rows.Add($row) }
        [IO.File]::WriteAllText($tooMany.LockPath, (($rows -join "`r`n") + "`r`n"))
        Assert-Throws { Invoke-Preparation $tooMany 'row-bound-output' } `
            'exceeds the 256-row limit'
        Assert-True (-not (Test-Path -LiteralPath (
            Join-Path $tooMany.Root 'row-bound-output'
        )))
    }
}
finally {
    foreach ($junction in $script:Junctions) {
        if (Test-Path -LiteralPath $junction) {
            [IO.Directory]::Delete($junction, $false)
        }
    }
    if (Test-Path -LiteralPath $script:TestRoot) {
        Remove-Item -LiteralPath $script:TestRoot -Recurse -Force
    }
}

if ($script:Failures -ne 0) {
    throw "$($script:Failures) component-derived source test(s) failed."
}
Write-Output 'All component-derived source tests passed.'
