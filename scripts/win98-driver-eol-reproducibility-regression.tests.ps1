# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Failures = 0
$script:Utf8 = [Text.UTF8Encoding]::new($false)

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [string]$Message = 'Expected true.'
    )
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Message = 'Values differ.')
    if ($Actual -ne $Expected) {
        throw "$Message Expected '$Expected', observed '$Actual'."
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Body,
        [Parameter(Mandatory = $true)][string]$Pattern
    )
    try { & $Body | Out-Null }
    catch {
        if ($_.Exception.Message -notmatch $Pattern) {
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
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $output = @(& git -c "safe.directory=$Repository" -C $Repository @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
    }
    return ($output -join [Environment]::NewLine).Trim()
}

function Write-Utf8 {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $parent -Force)
    }
    [IO.File]::WriteAllText($Path, $Text, $script:Utf8)
}

function New-EolFixture {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Attributes = "* -text`n"
    )

    $root = Join-Path $script:TestRoot $Name
    $repository = Join-Path $root 'repository'
    $source = Join-Path $root 'source'
    $toolchain = Join-Path $root 'toolchain'
    [void](New-Item -ItemType Directory -Path $repository)
    [void](New-Item -ItemType Directory -Path $source)
    [void](New-Item -ItemType Directory -Path $toolchain)

    Write-Utf8 (Join-Path $repository 'scripts\build-win98-driver-sources.ps1') @'
# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param(
    [string]$SourceRoot,
    [string]$ToolchainRoot,
    [string]$OutputRoot,
    [string]$BuildPlan,
    [string]$LockFile
)
[void](New-Item -ItemType Directory -Path $OutputRoot)
'@
    Write-Utf8 (Join-Path $repository 'drivers\win98\build-plan.json') @'
{
  "_spdx": "GPL-3.0-only",
  "derived_source_plan": { "relative_path": "derived-source-plan.json" },
  "upstream_lock": { "relative_path": "upstream.lock.tsv" },
  "steps": []
}
'@
    Write-Utf8 (Join-Path $repository 'drivers\win98\derived-source-plan.json') @'
{
  "_spdx": "GPL-3.0-only",
  "recipes": []
}
'@
    Write-Utf8 (Join-Path $repository 'drivers\win98\upstream.lock.tsv') (
        "# SPDX-License-Identifier: GPL-3.0-only`n" +
        "name`tsource_directory`trepository`tcommit`tupstream_license`tdisposition`tclosure_manifest`tclosure_manifest_sha256`tscope`n" +
        "fixture`tnone`thttps://example.invalid/fixture.git`t0123456789abcdef0123456789abcdef01234567`tMIT`treference-only`t`t`tfixture`n"
    )
    Write-Utf8 (Join-Path $repository '.gitattributes') $Attributes
    Write-Utf8 (Join-Path $repository '.gitignore') "*.ignored`n"
    Write-Utf8 (Join-Path $repository 'tracked.txt') "base`n"

    & git init -q $repository
    if ($LASTEXITCODE -ne 0) { throw 'Synthetic git init failed.' }
    [void](Invoke-Git $repository @('config', 'user.name', 'RETVRN99 Test'))
    [void](Invoke-Git $repository @('config', 'user.email', 'test@retvrn99.invalid'))
    [void](Invoke-Git $repository @('add', '--all'))
    [void](Invoke-Git $repository @('commit', '-q', '-m', 'Synthetic baseline'))

    return [pscustomobject][ordered]@{
        root = $root
        repository = $repository
        source = $source
        toolchain = $toolchain
        proof = Join-Path $root 'proof'
    }
}

function Invoke-EolProof {
    param(
        [Parameter(Mandatory = $true)]$Fixture,
        [Parameter(Mandatory = $true)][string[]]$Candidate
    )

    return @(& $script:EolScript `
        -SourceRoot $Fixture.source `
        -ToolchainRoot $Fixture.toolchain `
        -ProofRoot $Fixture.proof `
        -RepositoryRoot $Fixture.repository `
        -CandidateRelativePath $Candidate)
}

if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
    throw 'git is required for the Win98 driver EOL reproducibility regressions.'
}

$script:EolScript = Join-Path $PSScriptRoot 'win98-driver-eol-reproducibility.tests.ps1'
$script:TestRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'retvrn99-win98-eol-regression-{0}' -f [Guid]::NewGuid().ToString('N')
)
[void](New-Item -ItemType Directory -Path $script:TestRoot)

try {
    Invoke-SelfTest 'Mixed added and modified candidate is reproduced without index mutation' {
        $fixture = New-EolFixture 'mixed-success'
        Write-Utf8 (Join-Path $fixture.repository 'tracked.txt') "modified`n"
        Write-Utf8 (Join-Path $fixture.repository 'tools\new-tool.ps1') (
            "# SPDX-License-Identifier: GPL-3.0-only`n'new tool'`n"
        )
        $indexPath = Invoke-Git $fixture.repository @(
            'rev-parse', '--path-format=absolute', '--git-path', 'index'
        )
        $indexHash = (Get-FileHash -LiteralPath $indexPath -Algorithm SHA256).Hash

        $output = Invoke-EolProof $fixture @('tracked.txt', 'tools/new-tool.ps1')
        Assert-True (($output -join "`n") -match 'with candidate patch')
        Assert-Equal (
            (Get-FileHash -LiteralPath $indexPath -Algorithm SHA256).Hash
        ) $indexHash 'The source index changed.'
        $descriptor = Get-Content -Raw -LiteralPath (
            Join-Path $fixture.proof 'candidate.json'
        ) | ConvertFrom-Json
        Assert-Equal $descriptor.schema 2
        Assert-Equal @($descriptor.candidate_files).Count 2
        Assert-Equal @($descriptor.candidate_files | Where-Object status -ceq 'A').Count 1
        Assert-Equal @($descriptor.candidate_files | Where-Object status -ceq 'M').Count 1
    }

    Invoke-SelfTest 'Assume-unchanged index state rejects before proof creation' {
        $fixture = New-EolFixture 'assume-unchanged'
        Write-Utf8 (Join-Path $fixture.repository 'added.txt') "added`n"
        [void](Invoke-Git $fixture.repository @(
            'update-index', '--assume-unchanged', '--', 'tracked.txt'
        ))
        Assert-Throws {
            Invoke-EolProof $fixture @('added.txt')
        } 'assume-unchanged state'
        Assert-True (-not (Test-Path -LiteralPath $fixture.proof)) `
            'Assume-unchanged rejection created proof artifacts.'
    }

    Invoke-SelfTest 'Skip-worktree index state rejects before proof creation' {
        $fixture = New-EolFixture 'skip-worktree'
        Write-Utf8 (Join-Path $fixture.repository 'added.txt') "added`n"
        [void](Invoke-Git $fixture.repository @(
            'update-index', '--skip-worktree', '--', 'tracked.txt'
        ))
        Assert-Throws {
            Invoke-EolProof $fixture @('added.txt')
        } 'skip-worktree state'
        Assert-True (-not (Test-Path -LiteralPath $fixture.proof)) `
            'Skip-worktree rejection created proof artifacts.'
    }

    Invoke-SelfTest 'Unstaged rename is rejected explicitly' {
        $fixture = New-EolFixture 'renamed-tracked'
        Move-Item -LiteralPath (Join-Path $fixture.repository 'tracked.txt') `
            -Destination (Join-Path $fixture.repository 'renamed.txt')
        Assert-Throws {
            Invoke-EolProof $fixture @('tracked.txt', 'renamed.txt')
        } 'only added or modified files'
        Assert-True (-not (Test-Path -LiteralPath $fixture.proof)) `
            'Rename rejection created proof artifacts.'
    }

    Invoke-SelfTest 'Tracked type change is rejected explicitly' {
        $fixture = New-EolFixture 'type-change'
        $linkData = Join-Path $fixture.repository 'link-data.tmp'
        Write-Utf8 $linkData 'target.txt'
        $blob = Invoke-Git $fixture.repository @('hash-object', '-w', '--', 'link-data.tmp')
        Remove-Item -LiteralPath $linkData
        [void](Invoke-Git $fixture.repository @(
            'update-index', '--cacheinfo', "120000,$blob,tracked.txt"
        ))
        [void](Invoke-Git $fixture.repository @(
            'commit', '-q', '-m', 'Synthetic symlink baseline'
        ))
        [void](Invoke-Git $fixture.repository @(
            '-c', 'core.symlinks=false', 'checkout', '-f', 'HEAD', '--', 'tracked.txt'
        ))
        [void](Invoke-Git $fixture.repository @('config', 'core.symlinks', 'true'))
        $status = Invoke-Git $fixture.repository @(
            'diff', '--name-status', '--no-renames', 'HEAD', '--', 'tracked.txt'
        )
        Assert-True ($status -match '^T\s+tracked\.txt$') `
            "Synthetic type-change fixture did not report T: $status"
        Assert-Throws {
            Invoke-EolProof $fixture @('tracked.txt')
        } 'only added or modified files'
        Assert-True (-not (Test-Path -LiteralPath $fixture.proof)) `
            'Type-change rejection created proof artifacts.'
    }

    Invoke-SelfTest 'Binary added and modified patch remains byte-stable' {
        $fixture = New-EolFixture 'binary-mixed'
        $trackedBinary = Join-Path $fixture.repository 'tracked.bin'
        $addedBinary = Join-Path $fixture.repository 'added.bin'
        [IO.File]::WriteAllBytes($trackedBinary, [byte[]](0, 1, 2, 0, 254, 255))
        [void](Invoke-Git $fixture.repository @('add', '--', 'tracked.bin'))
        [void](Invoke-Git $fixture.repository @(
            'commit', '-q', '-m', 'Synthetic binary baseline'
        ))
        [IO.File]::WriteAllBytes($trackedBinary, [byte[]](0, 8, 7, 0, 253, 252))
        [IO.File]::WriteAllBytes($addedBinary, [byte[]](255, 0, 9, 8, 7, 0))

        [void](Invoke-EolProof $fixture @('tracked.bin', 'added.bin'))
        $result = Get-Content -Raw -LiteralPath (
            Join-Path $fixture.proof 'candidate-result.json'
        ) | ConvertFrom-Json
        Assert-Equal $result.patch_sha256 $result.final_patch_sha256
        $patchText = [IO.File]::ReadAllText(
            (Join-Path $fixture.proof 'candidate.patch'), [Text.Encoding]::ASCII
        )
        Assert-True ($patchText.Contains('GIT binary patch'))
    }

    Invoke-SelfTest 'Active autocrlf conversion preserves candidate index and patch identity' {
        $attributes = @'
drivers/** -text
scripts/** -text
.gitattributes -text
.gitignore -text
'@
        $fixture = New-EolFixture 'autocrlf-active' ($attributes + "`n")
        Write-Utf8 (Join-Path $fixture.repository 'tracked.txt') "modified`nline`n"
        Write-Utf8 (Join-Path $fixture.repository 'converted\added.txt') "added`nline`n"

        [void](Invoke-EolProof $fixture @('tracked.txt', 'converted/added.txt'))
        $trueText = [IO.File]::ReadAllText(
            (Join-Path $fixture.proof 'autocrlf-true\tracked.txt')
        )
        $falseText = [IO.File]::ReadAllText(
            (Join-Path $fixture.proof 'autocrlf-false\tracked.txt')
        )
        Assert-True ($trueText.Contains("`r`n")) `
            'core.autocrlf=true did not exercise CRLF checkout conversion.'
        Assert-True (-not $falseText.Contains("`r`n")) `
            'core.autocrlf=false unexpectedly produced CRLF checkout bytes.'
    }

    Invoke-SelfTest 'Omitted added candidate is rejected' {
        $fixture = New-EolFixture 'omitted-added'
        Write-Utf8 (Join-Path $fixture.repository 'tracked.txt') "modified`n"
        Write-Utf8 (Join-Path $fixture.repository 'added.txt') "added`n"
        Assert-Throws {
            Invoke-EolProof $fixture @('tracked.txt')
        } 'exact nonignored dirty set'
    }

    Invoke-SelfTest 'Unexpected nonignored added candidate is rejected' {
        $fixture = New-EolFixture 'unexpected-added'
        Write-Utf8 (Join-Path $fixture.repository 'tracked.txt') "modified`n"
        Write-Utf8 (Join-Path $fixture.repository 'declared.txt') "declared`n"
        Write-Utf8 (Join-Path $fixture.repository 'surprise.txt') "surprise`n"
        Assert-Throws {
            Invoke-EolProof $fixture @('tracked.txt', 'declared.txt')
        } 'exact nonignored dirty set'
    }

    Invoke-SelfTest 'Ignored added candidate cannot enter the proof' {
        $fixture = New-EolFixture 'ignored-added'
        Write-Utf8 (Join-Path $fixture.repository 'tracked.txt') "modified`n"
        Write-Utf8 (Join-Path $fixture.repository 'payload.ignored') "ignored`n"
        Assert-Throws {
            Invoke-EolProof $fixture @('tracked.txt', 'payload.ignored')
        } 'exact nonignored dirty set'
    }

    Invoke-SelfTest 'Added candidate through a reparse point is rejected' {
        $fixture = New-EolFixture 'reparse-added'
        $target = Join-Path $fixture.root 'reparse-target'
        $junction = Join-Path $fixture.repository 'junction'
        [void](New-Item -ItemType Directory -Path $target)
        Write-Utf8 (Join-Path $target 'payload.txt') "payload`n"
        [void](New-Item -ItemType Junction -Path $junction -Target $target)
        try {
            Assert-Throws {
                Invoke-EolProof $fixture @('junction/payload.txt')
            } 'reparse point'
        }
        finally {
            if (Test-Path -LiteralPath $junction) {
                Remove-Item -LiteralPath $junction -Force
            }
        }
    }

    Invoke-SelfTest 'Unsafe added path and destructive tracked status are rejected' {
        $unsafe = New-EolFixture 'unsafe-added'
        Write-Utf8 (Join-Path $unsafe.repository 'unsafe name.txt') "unsafe`n"
        Assert-Throws {
            Invoke-EolProof $unsafe @('unsafe name.txt')
        } 'portable contained path'

        $deleted = New-EolFixture 'deleted-tracked'
        Remove-Item -LiteralPath (Join-Path $deleted.repository 'tracked.txt')
        Assert-Throws {
            Invoke-EolProof $deleted @('tracked.txt')
        } 'only added or modified files'
    }
}
finally {
    $verifiedRoot = [IO.Path]::GetFullPath($script:TestRoot)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if (-not $verifiedRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        -not ([IO.Path]::GetFileName($verifiedRoot)).StartsWith(
            'retvrn99-win98-eol-regression-', [StringComparison]::Ordinal
        )) {
        throw "Refusing to remove unverified EOL regression path '$verifiedRoot'."
    }
    if (Test-Path -LiteralPath $verifiedRoot) {
        Remove-Item -LiteralPath $verifiedRoot -Recurse -Force
    }
}

if ($script:Failures -ne 0) {
    throw "$script:Failures Win98 driver EOL reproducibility regression(s) failed."
}
Write-Host 'All Win98 driver EOL reproducibility regressions passed.'
