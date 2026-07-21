# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [string]$SourceRoot = 'D:\src\retvrn99-win98',
    [string]$NameFilter,
    [switch]$DetailedFailures
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Failures = 0
$script:TestCount = 0
$script:NameFilter = [string]$NameFilter
$script:DetailedFailures = [bool]$DetailedFailures
$script:Verifier = Join-Path $PSScriptRoot 'verify-win98-mesa-source-seed.ps1'
$script:ProductionProfile = Join-Path $PSScriptRoot `
    '..\drivers\win98\mesa-source-seed.json'
$script:ProductionSchema = Join-Path $PSScriptRoot `
    '..\drivers\win98\mesa-source-seed.schema.json'
$script:SourceRoot = [IO.Path]::GetFullPath($SourceRoot)
$script:Checkout = Join-Path $script:SourceRoot 'mesa9x'

. $script:Verifier -SourceRoot $script:SourceRoot

function Invoke-SelfTest {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )

    if (-not [string]::IsNullOrWhiteSpace($script:NameFilter) -and
        $Name -notlike "*$($script:NameFilter)*") {
        return
    }
    $script:TestCount++
    try {
        & $Body
        Write-Output "PASS: $Name"
    }
    catch {
        $script:Failures++
        Write-Output "FAIL: $Name"
        Write-Output "  $($_.Exception.Message)"
        if ($script:DetailedFailures) {
            Write-Output "  $($_.ScriptStackTrace)"
        }
    }
}

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)]$Actual,
        [Parameter(Mandatory = $true)]$Expected
    )

    if ($Actual -cne $Expected) {
        throw "Expected '$Expected', observed '$Actual'."
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Body,
        [Parameter(Mandatory = $true)][string]$ExpectedText
    )

    try {
        & $Body
    }
    catch {
        if ($_.Exception.Message.IndexOf(
                $ExpectedText,
                [StringComparison]::OrdinalIgnoreCase
            ) -lt 0) {
            throw "Expected error containing '$ExpectedText', observed '$($_.Exception.Message)'."
        }
        return
    }
    throw "Expected an error containing '$ExpectedText'."
}

function Invoke-TestGit {
    param(
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $output = @(& git -C $WorkingDirectory @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed: $($output -join ' ')"
    }
    return @($output)
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )

    $json = $Value | ConvertTo-Json -Depth 32
    [IO.File]::WriteAllText(
        $Path,
        $json + "`n",
        [Text.UTF8Encoding]::new($false)
    )
}

function Get-ProductionProfileObject {
    return ConvertFrom-GswStrictJson `
        -Json ([IO.File]::ReadAllText($script:ProductionProfile)) `
        -Source $script:ProductionProfile
}

function New-MutatedProfile {
    param([Parameter(Mandatory = $true)][scriptblock]$Mutation)

    $profile = Get-ProductionProfileObject
    & $Mutation $profile
    $path = Join-Path $script:FixtureMetadataRoot 'mesa-source-seed.json'
    Write-JsonFile $path $profile
    return $path
}

function Invoke-Verification {
    param(
        [Parameter(Mandatory = $true)][string]$Profile,
        [switch]$PolicyAudit,
        [scriptblock]$BeforeFinalMetadataCheck
    )

    return @(& $script:Verifier -SourceRoot $script:SourceRoot `
        -ProfileFile $Profile -PolicyAudit:$PolicyAudit `
        -BeforeFinalMetadataCheck $BeforeFinalMetadataCheck)
}

function Remove-TestRoot {
    param([Parameter(Mandatory = $true)][string]$Path)

    $resolved = [IO.Path]::GetFullPath($Path)
    $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd(
        [char[]]'\/'
    ) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $resolved) -notlike 'retvrn99-mesa-source-seed-*') {
        throw "Refusing to remove unsafe test root '$resolved'."
    }
    if (Test-Path -LiteralPath $resolved) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}

function Assert-HiddenIndexMutationRejected {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$SetFlag,
        [Parameter(Mandatory = $true)][string]$ClearFlag
    )

    $fixtureRepo = Join-Path $testRoot $Name
    [void](New-Item -ItemType Directory -Path $fixtureRepo)
    Invoke-TestGit $fixtureRepo @('init', '--quiet') | Out-Null
    Invoke-TestGit $fixtureRepo @('config', 'user.name', 'vorvek') | Out-Null
    Invoke-TestGit $fixtureRepo @('config', 'user.email', 'vorvek@example.invalid') | Out-Null
    Invoke-TestGit $fixtureRepo @('config', 'core.autocrlf', 'false') | Out-Null
    $path = Join-Path $fixtureRepo 'tracked.c'
    [IO.File]::WriteAllText($path, "original`n", [Text.UTF8Encoding]::new($false))
    Invoke-TestGit $fixtureRepo @('add', 'tracked.c') | Out-Null
    Invoke-TestGit $fixtureRepo @('commit', '--quiet', '-m', 'Fixture') | Out-Null
    $index = Get-MesaSeedIndex $fixtureRepo
    Assert-MesaSeedIndexedFiles $fixtureRepo @('tracked.c') $index
    [IO.File]::WriteAllText($path, "modified`n", [Text.UTF8Encoding]::new($false))
    Invoke-TestGit $fixtureRepo @('update-index', $SetFlag, 'tracked.c') | Out-Null
    try {
        Assert-Throws {
            Assert-MesaSeedIndexedFiles $fixtureRepo @('tracked.c') $index
        } 'requires an undeclared worktree normalization'
    }
    finally {
        Invoke-TestGit $fixtureRepo @('update-index', $ClearFlag, 'tracked.c') | Out-Null
    }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'retvrn99-mesa-source-seed-' + [Guid]::NewGuid().ToString('N')
)
$script:FixtureMetadataRoot = Join-Path $testRoot 'metadata'
[void](New-Item -ItemType Directory -Path $script:FixtureMetadataRoot -Force)
Copy-Item -LiteralPath $script:ProductionSchema -Destination (
    Join-Path $script:FixtureMetadataRoot 'mesa-source-seed.schema.json'
)

try {
    Invoke-SelfTest 'Policy audit proves the exact blocked source-list seed' {
        $output = Invoke-Verification -Profile $script:ProductionProfile -PolicyAudit
        Assert-Equal ($output -join [Environment]::NewLine) (
            'Policy-audited blocked Mesa source-list seed: 870 occurrences, ' +
            '869 unique, 840 tracked-present, 29 generated-absent; unusable for ' +
            'build, stage, or capability activation.'
        )
    }

    Invoke-SelfTest 'Ordinary verification fails because the seed remains blocked' {
        Assert-Throws {
            Invoke-Verification -Profile $script:ProductionProfile
        } 'Mesa source-list seed is blocked'
    }

    Invoke-SelfTest 'Profile records the exact counts and candidate digests' {
        $profile = Get-ProductionProfileObject
        Assert-Equal ([int]$profile.selection.occurrence_count) 870
        Assert-Equal ([int]$profile.selection.unique_count) 869
        Assert-Equal ([int]$profile.selection.tracked_present_count) 840
        Assert-Equal ([int]$profile.selection.generated_absent_count) 29
        Assert-Equal $profile.selection.candidate_set_sha256 `
            '6cbc9ffcad7d06f01ad019b9f62bc7c647ff19da3f4993ac0707ef5b5faed716'
        Assert-Equal $profile.selection.occurrence_sequence_sha256 `
            '4ecdda04b89dabc541f837a0972806a88187b9f6751b75905f4df6dbd762b8f2'
        Assert-Equal $profile.selection.disabled_conditionals[0].macro 'USE_ASM'
        Assert-Equal $profile.selection.disabled_conditionals[0].state 'undefined'
    }

    Invoke-SelfTest 'The disabled USE_ASM assignment is explicit and exact' {
        $text = [IO.File]::ReadAllText((Join-Path $script:Checkout 'mesa-23.1.x.mk'))
        Assert-MesaSeedDisabledConditionals $text 'mesa-23.1.x.mk' @('MesaLib_SRC')
        Assert-Throws {
            Assert-MesaSeedDisabledConditionals `
                $text.Replace('ifdef USE_ASM', 'ifdef OTHER_ASM') `
                'mesa-23.1.x.mk' @('MesaLib_SRC')
        } 'undeclared conditional assignment'
    }

    Invoke-SelfTest 'Candidate digest mutation is rejected' {
        $path = New-MutatedProfile {
            param($profile)
            $profile.selection.candidate_set_sha256 = '0' * 64
        }
        Assert-Throws {
            Invoke-Verification -Profile $path -PolicyAudit
        } 'selection.candidate_set_sha256 must be'
    }

    Invoke-SelfTest 'Definition blob mutation is rejected' {
        $path = New-MutatedProfile {
            param($profile)
            $profile.source.definition_files[0].git_blob = '0' * 40
        }
        Assert-Throws {
            Invoke-Verification -Profile $path -PolicyAudit
        } 'source.definition_files[0].git_blob must be'
    }

    Invoke-SelfTest 'An unexpected source-list duplicate is rejected' {
        $mesaText = [IO.File]::ReadAllText((Join-Path $script:Checkout 'mesa-23.1.x.mk'))
        $mesaText += 'MesaUtilLib_SRC += $(MESA_VER)/src/util/bitscan.c' + "`r`n"
        $entries = @(Read-MesaSeedAssignments -Text $mesaText `
            -DefinitionFile 'mesa-23.1.x.mk' -VariableNames @(
                'MesaUtilLib_SRC', 'MesaLib_SRC', 'MesaWglLib_SRC',
                'MesaGalliumAuxLib_SRC', 'MesaNineLib_SRC', 'MesaSVGALib_SRC'
            ))
        $entries += @(Read-MesaSeedAssignments `
            -Text ([IO.File]::ReadAllText((Join-Path $script:Checkout 'Makefile'))) `
            -DefinitionFile 'Makefile' -VariableNames @('eight_SRC'))
        Assert-Throws {
            Get-MesaSeedAnalysis -Entries $entries `
                -ExpectedDuplicatePath 'mesa-23.1.x/src/mesa/main/es1_conversion.c' `
                -ExpectedDuplicateOccurrences 2
        } 'unexpected duplicate'
    }

    Invoke-SelfTest 'The sole canonical duplicate is exactly es1_conversion.c' {
        $mesaEntries = @(Read-MesaSeedAssignments `
            -Text ([IO.File]::ReadAllText((Join-Path $script:Checkout 'mesa-23.1.x.mk'))) `
            -DefinitionFile 'mesa-23.1.x.mk' -VariableNames @(
                'MesaUtilLib_SRC', 'MesaLib_SRC', 'MesaWglLib_SRC',
                'MesaGalliumAuxLib_SRC', 'MesaNineLib_SRC', 'MesaSVGALib_SRC'
            ))
        $eightEntries = @(Read-MesaSeedAssignments `
            -Text ([IO.File]::ReadAllText((Join-Path $script:Checkout 'Makefile'))) `
            -DefinitionFile 'Makefile' -VariableNames @('eight_SRC'))
        $analysis = Get-MesaSeedAnalysis -Entries @($mesaEntries + $eightEntries) `
            -ExpectedDuplicatePath 'mesa-23.1.x/src/mesa/main/es1_conversion.c' `
            -ExpectedDuplicateOccurrences 2
        Assert-Equal $analysis.OccurrenceCount 870
        Assert-Equal $analysis.UniqueCount 869
    }

    Invoke-SelfTest 'A missing generated-absent entry is rejected' {
        $path = New-MutatedProfile {
            param($profile)
            $profile.selection.generated_absent_paths = @(
                $profile.selection.generated_absent_paths[0..27]
            )
        }
        Assert-Throws {
            Invoke-Verification -Profile $path -PolicyAudit
        } 'must be a 29-item JSON array'
    }

    Invoke-SelfTest 'A forbidden winsys family cannot enter the selection' {
        $path = New-MutatedProfile {
            param($profile)
            $profile.selection.variables[5].name = 'MesaSVGAWinsysLib_SRC'
        }
        Assert-Throws {
            Invoke-Verification -Profile $path -PolicyAudit
        } 'selection.variables[5].name must be'
    }

    Invoke-SelfTest 'The software GDI family cannot enter the selection' {
        $path = New-MutatedProfile {
            param($profile)
            $profile.selection.variables[5].name = 'MesaGdiLib_SRC'
        }
        Assert-Throws {
            Invoke-Verification -Profile $path -PolicyAudit
        } 'selection.variables[5].name must be'
    }

    Invoke-SelfTest 'eight_SRC remains bound to the root Makefile' {
        $path = New-MutatedProfile {
            param($profile)
            $profile.selection.variables[6].definition_file = 'mesa-23.1.x.mk'
        }
        Assert-Throws {
            Invoke-Verification -Profile $path -PolicyAudit
        } 'selection.variables[6].definition_file must be'
    }

    Invoke-SelfTest 'The nonexistent Makefile.sources cannot become an input' {
        $path = New-MutatedProfile {
            param($profile)
            $profile.source.confirmed_absent_input = 'mesa-23.1.x.mk'
        }
        Assert-Throws {
            Invoke-Verification -Profile $path -PolicyAudit
        } 'source.confirmed_absent_input must be'
    }

    Invoke-SelfTest 'An ignored confirmed-absent input is rejected on final recheck' {
        $fixtureRepo = Join-Path $testRoot 'confirmed-absent-repo'
        [void](New-Item -ItemType Directory -Path $fixtureRepo)
        Invoke-TestGit $fixtureRepo @('init', '--quiet') | Out-Null
        Invoke-TestGit $fixtureRepo @('config', 'user.name', 'vorvek') | Out-Null
        Invoke-TestGit $fixtureRepo @('config', 'user.email', 'vorvek@example.invalid') | Out-Null
        Invoke-TestGit $fixtureRepo @('config', 'core.autocrlf', 'false') | Out-Null
        [IO.File]::WriteAllText(
            (Join-Path $fixtureRepo 'tracked.txt'),
            "tracked`n",
            [Text.UTF8Encoding]::new($false)
        )
        Invoke-TestGit $fixtureRepo @('add', 'tracked.txt') | Out-Null
        Invoke-TestGit $fixtureRepo @('commit', '--quiet', '-m', 'Fixture') | Out-Null
        $index = Get-MesaSeedIndex $fixtureRepo
        Assert-MesaSeedPathAbsent $fixtureRepo $index 'missing.input' `
            'Confirmed absent input'
        [IO.File]::WriteAllText(
            (Join-Path $fixtureRepo '.git\info\exclude'),
            "missing.input`n",
            [Text.UTF8Encoding]::new($false)
        )
        [IO.File]::WriteAllText(
            (Join-Path $fixtureRepo 'missing.input'),
            "appeared`n",
            [Text.UTF8Encoding]::new($false)
        )
        Assert-Throws {
            Assert-MesaSeedPathAbsent $fixtureRepo (Get-MesaSeedIndex $fixtureRepo) `
                'missing.input' 'Confirmed absent input'
        } 'unexpectedly exists'
    }

    Invoke-SelfTest 'A dangling reparse cannot impersonate an absent input' {
        $fixtureRepo = Join-Path $testRoot 'dangling-absent-repo'
        [void](New-Item -ItemType Directory -Path $fixtureRepo)
        Invoke-TestGit $fixtureRepo @('init', '--quiet') | Out-Null
        Invoke-TestGit $fixtureRepo @('config', 'user.name', 'vorvek') | Out-Null
        Invoke-TestGit $fixtureRepo @('config', 'user.email', 'vorvek@example.invalid') | Out-Null
        Invoke-TestGit $fixtureRepo @('config', 'core.autocrlf', 'false') | Out-Null
        [IO.File]::WriteAllText(
            (Join-Path $fixtureRepo 'tracked.txt'),
            "tracked`n",
            [Text.UTF8Encoding]::new($false)
        )
        Invoke-TestGit $fixtureRepo @('add', 'tracked.txt') | Out-Null
        Invoke-TestGit $fixtureRepo @('commit', '--quiet', '-m', 'Fixture') | Out-Null
        $target = Join-Path $testRoot 'dangling-target'
        $link = Join-Path $fixtureRepo 'missing.input'
        [void](New-Item -ItemType Directory -Path $target)
        [void](New-Item -ItemType Junction -Path $link -Target $target)
        [IO.Directory]::Delete($target)
        try {
            Assert-Throws {
                Assert-MesaSeedPathAbsent $fixtureRepo (Get-MesaSeedIndex $fixtureRepo) `
                    'missing.input' 'Confirmed absent input'
            } 'reparse point'
        }
        finally {
            [IO.Directory]::Delete($link)
        }
    }

    Invoke-SelfTest 'Build authorization cannot be enabled by schema v1' {
        $path = New-MutatedProfile {
            param($profile)
            $profile.scope.authorizations.build = $true
        }
        Assert-Throws {
            Invoke-Verification -Profile $path -PolicyAudit
        } 'scope.authorizations.build must remain false'
    }

    Invoke-SelfTest 'Capability advertisement cannot be enabled by schema v1' {
        $path = New-MutatedProfile {
            param($profile)
            $profile.scope.authorizations.capability_advertisement = $true
        }
        Assert-Throws {
            Invoke-Verification -Profile $path -PolicyAudit
        } 'scope.authorizations.capability_advertisement must remain false'
    }

    Invoke-SelfTest 'Ready status is rejected by the blocked-only schema' {
        $path = New-MutatedProfile {
            param($profile)
            $profile.status = 'ready'
            $profile.reason = ''
        }
        Assert-Throws {
            Invoke-Verification -Profile $path -PolicyAudit
        } "status must be 'blocked'"
    }

    Invoke-SelfTest 'Malformed UTF-8 profile bytes are rejected' {
        $path = Join-Path $script:FixtureMetadataRoot 'mesa-source-seed.json'
        [IO.File]::WriteAllBytes($path, [byte[]]@(0x7b, 0x22, 0xff, 0x22, 0x7d))
        Assert-Throws {
            Invoke-Verification -Profile $path -PolicyAudit
        } 'is not strict UTF-8'
    }

    Invoke-SelfTest 'A UTF-8 BOM in the profile is rejected' {
        $path = Join-Path $script:FixtureMetadataRoot 'mesa-source-seed.json'
        $sourceBytes = [IO.File]::ReadAllBytes($script:ProductionProfile)
        $bytes = New-Object byte[] ($sourceBytes.Length + 3)
        $bytes[0] = 0xef
        $bytes[1] = 0xbb
        $bytes[2] = 0xbf
        [Array]::Copy($sourceBytes, 0, $bytes, 3, $sourceBytes.Length)
        [IO.File]::WriteAllBytes($path, $bytes)
        Assert-Throws {
            Invoke-Verification -Profile $path -PolicyAudit
        } 'must not contain a UTF-8 BOM'
    }

    Invoke-SelfTest 'Excessively nested profile JSON is rejected' {
        $path = Join-Path $script:FixtureMetadataRoot 'mesa-source-seed.json'
        $json = ('[' * 48) + '0' + (']' * 48) + "`n"
        [IO.File]::WriteAllText($path, $json, [Text.UTF8Encoding]::new($false))
        Assert-Throws {
            Invoke-Verification -Profile $path -PolicyAudit
        } 'JSON nesting exceeds'
    }

    Invoke-SelfTest 'Dirty Git checkouts are rejected' {
        $fixtureRepo = Join-Path $testRoot 'dirty-repo'
        [void](New-Item -ItemType Directory -Path $fixtureRepo)
        Invoke-TestGit $fixtureRepo @('init', '--quiet') | Out-Null
        Invoke-TestGit $fixtureRepo @('config', 'user.name', 'vorvek') | Out-Null
        Invoke-TestGit $fixtureRepo @('config', 'user.email', 'vorvek@example.invalid') | Out-Null
        Invoke-TestGit $fixtureRepo @('config', 'core.autocrlf', 'false') | Out-Null
        Invoke-TestGit $fixtureRepo @(
            'remote', 'add', 'origin', 'https://example.invalid/fixture.git'
        ) | Out-Null
        [IO.File]::WriteAllText((Join-Path $fixtureRepo 'tracked.txt'), "fixture`n")
        Invoke-TestGit $fixtureRepo @('add', 'tracked.txt') | Out-Null
        Invoke-TestGit $fixtureRepo @('commit', '--quiet', '-m', 'Fixture') | Out-Null
        $commit = (@(Invoke-TestGit $fixtureRepo @('rev-parse', 'HEAD')) -join '').Trim()
        Assert-MesaSeedGitCheckout $fixtureRepo $commit `
            'https://example.invalid/fixture.git'
        [IO.File]::WriteAllText((Join-Path $fixtureRepo 'dirty.txt'), "dirty`n")
        Assert-Throws {
            Assert-MesaSeedGitCheckout $fixtureRepo $commit `
                'https://example.invalid/fixture.git'
        } 'has local changes'
    }

    Invoke-SelfTest 'Assume-unchanged cannot hide a source mutation' {
        Assert-HiddenIndexMutationRejected 'assume-unchanged-repo' `
            '--assume-unchanged' '--no-assume-unchanged'
    }

    Invoke-SelfTest 'Skip-worktree cannot hide a source mutation' {
        Assert-HiddenIndexMutationRejected 'skip-worktree-repo' `
            '--skip-worktree' '--no-skip-worktree'
    }

    Invoke-SelfTest 'Custom clean filters cannot authorize normalized source bytes' {
        $fixtureRepo = Join-Path $testRoot 'custom-filter-repo'
        [void](New-Item -ItemType Directory -Path $fixtureRepo)
        Invoke-TestGit $fixtureRepo @('init', '--quiet') | Out-Null
        Invoke-TestGit $fixtureRepo @('config', 'user.name', 'vorvek') | Out-Null
        Invoke-TestGit $fixtureRepo @('config', 'user.email', 'vorvek@example.invalid') | Out-Null
        Invoke-TestGit $fixtureRepo @('config', 'core.autocrlf', 'false') | Out-Null
        $path = Join-Path $fixtureRepo 'tracked.c'
        [IO.File]::WriteAllText($path, "original`n", [Text.UTF8Encoding]::new($false))
        Invoke-TestGit $fixtureRepo @('add', 'tracked.c') | Out-Null
        Invoke-TestGit $fixtureRepo @('commit', '--quiet', '-m', 'Fixture') | Out-Null
        $index = Get-MesaSeedIndex $fixtureRepo
        [IO.File]::WriteAllText(
            (Join-Path $fixtureRepo '.git\info\attributes'),
            "tracked.c filter=mask text=auto`n",
            [Text.UTF8Encoding]::new($false)
        )
        [IO.File]::WriteAllText($path, "original`r`n", [Text.UTF8Encoding]::new($false))
        Assert-Throws {
            Assert-MesaSeedIndexedFiles $fixtureRepo @('tracked.c') $index
        } 'unsafe Git attribute'
    }

    Invoke-SelfTest 'Ignored worktree attributes cannot diverge from cached policy' {
        $fixtureRepo = Join-Path $testRoot 'ignored-attributes-repo'
        [void](New-Item -ItemType Directory -Path $fixtureRepo)
        Invoke-TestGit $fixtureRepo @('init', '--quiet') | Out-Null
        Invoke-TestGit $fixtureRepo @('config', 'user.name', 'vorvek') | Out-Null
        Invoke-TestGit $fixtureRepo @('config', 'user.email', 'vorvek@example.invalid') | Out-Null
        Invoke-TestGit $fixtureRepo @('config', 'core.autocrlf', 'false') | Out-Null
        [void](New-Item -ItemType Directory -Path (Join-Path $fixtureRepo 'src'))
        $path = Join-Path $fixtureRepo 'src\tracked.c'
        [IO.File]::WriteAllText($path, "original`n", [Text.UTF8Encoding]::new($false))
        Invoke-TestGit $fixtureRepo @('add', 'src/tracked.c') | Out-Null
        Invoke-TestGit $fixtureRepo @('commit', '--quiet', '-m', 'Fixture') | Out-Null
        $index = Get-MesaSeedIndex $fixtureRepo
        [IO.File]::WriteAllText(
            (Join-Path $fixtureRepo '.git\info\exclude'),
            "src/.gitattributes`n",
            [Text.UTF8Encoding]::new($false)
        )
        [IO.File]::WriteAllText(
            (Join-Path $fixtureRepo 'src\.gitattributes'),
            "tracked.c filter=mask text=auto`n",
            [Text.UTF8Encoding]::new($false)
        )
        [IO.File]::WriteAllText($path, "original`r`n", [Text.UTF8Encoding]::new($false))
        Assert-Throws {
            Assert-MesaSeedIndexedFiles $fixtureRepo @('src/tracked.c') $index
        } 'unsafe Git attribute'
    }

    Invoke-SelfTest 'Final path validation reapplies the candidate size bound' {
        $root = Join-Path $testRoot 'final-size-bound'
        [void](New-Item -ItemType Directory -Path $root)
        [IO.File]::WriteAllBytes((Join-Path $root 'candidate.c'), [byte[]](1..5))
        $previousBound = $script:MesaSeedMaximumCandidateBytes
        $script:MesaSeedMaximumCandidateBytes = [UInt64]4
        try {
            Assert-Throws {
                Assert-MesaSeedContainedPathsNoReparse $root @('candidate.c') `
                    'final candidates' -RequireRegularLeaves
            } 'exceeds the 4-byte bound'
        }
        finally {
            $script:MesaSeedMaximumCandidateBytes = $previousBound
        }
    }

    Invoke-SelfTest 'Profile replacement before the final metadata check is rejected' {
        $path = New-MutatedProfile { param($profile) }
        $env:RETVRN99_MESA_SEED_MUTATION_TARGET = $path
        $callback = {
            [IO.File]::AppendAllText(
                $env:RETVRN99_MESA_SEED_MUTATION_TARGET,
                ' '
            )
        }
        try {
            Assert-Throws {
                Invoke-Verification -Profile $path -PolicyAudit `
                    -BeforeFinalMetadataCheck $callback
            } 'metadata changed during verification'
        }
        finally {
            Remove-Item Env:RETVRN99_MESA_SEED_MUTATION_TARGET `
                -ErrorAction SilentlyContinue
        }
    }

    Invoke-SelfTest 'Schema replacement before the final metadata check is rejected' {
        $schemaPath = Join-Path $script:FixtureMetadataRoot `
            'mesa-source-seed.schema.json'
        Copy-Item -LiteralPath $script:ProductionSchema -Destination $schemaPath -Force
        $path = New-MutatedProfile { param($profile) }
        $env:RETVRN99_MESA_SEED_MUTATION_TARGET = $schemaPath
        $callback = {
            [IO.File]::AppendAllText(
                $env:RETVRN99_MESA_SEED_MUTATION_TARGET,
                ' '
            )
        }
        try {
            Assert-Throws {
                Invoke-Verification -Profile $path -PolicyAudit `
                    -BeforeFinalMetadataCheck $callback
            } 'metadata changed during verification'
        }
        finally {
            Remove-Item Env:RETVRN99_MESA_SEED_MUTATION_TARGET `
                -ErrorAction SilentlyContinue
            Copy-Item -LiteralPath $script:ProductionSchema -Destination $schemaPath -Force
        }
    }

    Invoke-SelfTest 'Metadata profile and schema paths crossing a junction are rejected' {
        $target = Join-Path $testRoot 'metadata-target'
        $junction = Join-Path $testRoot 'metadata-link'
        [void](New-Item -ItemType Directory -Path $target)
        Copy-Item -LiteralPath $script:ProductionProfile -Destination (
            Join-Path $target 'mesa-source-seed.json'
        )
        Copy-Item -LiteralPath $script:ProductionSchema -Destination (
            Join-Path $target 'mesa-source-seed.schema.json'
        )
        [void](New-Item -ItemType Junction -Path $junction -Target $target)
        try {
            Assert-Throws {
                Invoke-Verification -Profile (
                    Join-Path $junction 'mesa-source-seed.json'
                ) -PolicyAudit
            } 'traverses reparse point'
        }
        finally {
            if (Test-Path -LiteralPath $junction) {
                [IO.Directory]::Delete($junction)
            }
        }
    }
}
finally {
    Remove-TestRoot $testRoot
}

if ($script:Failures -ne 0) {
    throw "$($script:Failures) of $($script:TestCount) Mesa source-list seed tests failed."
}
Write-Output "All $($script:TestCount) Windows 98 Mesa source-list seed tests passed."
