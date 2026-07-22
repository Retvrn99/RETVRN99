# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$preparer = Join-Path $PSScriptRoot 'prepare-graphics-baseline-run.ps1'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$productionPlan = Join-Path $repositoryRoot 'qualification\graphics\baseline-plan.json'
$testRoot = Join-Path $repositoryRoot (
    '.scratch\graphics-qualification\baseline\tests\' + [Guid]::NewGuid().ToString('N')
)
$outputPath = Join-Path $testRoot 'run-plan.json'
$fixturePlan = Join-Path $testRoot 'baseline-plan.json'
$fixtureLock = Join-Path $testRoot 'media.lock.json'
$fixtureMedia = Join-Path $testRoot 'media'
$script:tests = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:tests += 1
    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern, [string]$Message)
    $script:tests += 1
    try {
        & $Action
    } catch {
        if ($_.Exception.Message -notmatch $Pattern) {
            throw "$Message Observed: $($_.Exception.Message)"
        }
        return
    }
    throw $Message
}

New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
try {
    New-Item -ItemType Directory -Path $fixtureMedia | Out-Null
    Copy-Item -LiteralPath $productionPlan -Destination $fixturePlan
    $fixturePayloads = @(
        [ordered]@{
            id = 'quake-shareware-1.06'
            title = 'Quake shareware fixture Espa' + [char]0x00f1 + 'ol'
            relative_path = 'quake-data.bin'
            content = 'quake-data-fixture'
        },
        [ordered]@{
            id = 'winquake-1.00'
            title = 'WinQuake fixture'
            relative_path = 'winquake.bin'
            content = 'winquake-fixture'
        }
    )
    $mediaEntries = @()
    foreach ($fixture in $fixturePayloads) {
        $payloadPath = Join-Path $fixtureMedia $fixture.relative_path
        [IO.File]::WriteAllText(
            $payloadPath,
            [string]$fixture.content,
            [Text.UTF8Encoding]::new($false)
        )
        $mediaEntries += [ordered]@{
            id = [string]$fixture.id
            title = [string]$fixture.title
            relative_path = [string]$fixture.relative_path
            bytes = (Get-Item -LiteralPath $payloadPath).Length
            sha256 = (Get-FileHash -LiteralPath $payloadPath -Algorithm SHA256).Hash.ToLowerInvariant()
            source_url = 'https://example.invalid/' + [string]$fixture.relative_path
        }
    }
    $fixtureLockValue = [ordered]@{
        _spdx = 'GPL-3.0-only'
        schema = 1
        policy = [ordered]@{
            payloads_are_external = $true
            redistribution_allowed = $false
            guest_install_requires_explicit_authorization = $true
        }
        media = $mediaEntries
    }
    [IO.File]::WriteAllText(
        $fixtureLock,
        (($fixtureLockValue | ConvertTo-Json -Depth 8 -Compress) + "`n"),
        [Text.UTF8Encoding]::new($false)
    )

    $success = @(& $preparer `
        -PlanFile $fixturePlan `
        -MediaLock $fixtureLock `
        -MediaRoot $fixtureMedia `
        -OutputFile $outputPath)
    Assert-True ($success.Count -eq 1 -and $success[0] -match (
        '^PASS prepared graphics baseline cells=24 authorized=false '
    )) 'The production baseline should prepare exactly one inert run plan.'
    Assert-True (Test-Path -LiteralPath $outputPath -PathType Leaf) `
        'The prepared run plan should exist.'
    $preparedHash = (Get-FileHash -LiteralPath $outputPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-True ($preparedHash -ceq 'c329aae22a13a201e8bf46503f283af3be026f9d8baaa0a207d926325d026f6a') `
        'The prepared fixture must be byte-identical across supported PowerShell versions.'

    $prepared = Get-Content -Raw -LiteralPath $outputPath | ConvertFrom-Json
    Assert-True ([string]$prepared.source.plan_sha256 -ceq (
        Get-FileHash -LiteralPath $fixturePlan -Algorithm SHA256
    ).Hash.ToLowerInvariant()) `
        'The prepared run must record the exact validated plan snapshot hash.'
    Assert-True ([string]$prepared.source.media_lock_sha256 -ceq (
        Get-FileHash -LiteralPath $fixtureLock -Algorithm SHA256
    ).Hash.ToLowerInvariant()) `
        'The prepared run must record the exact validated media-lock snapshot hash.'
    Assert-True ($prepared.policy.prepared_only -eq $true -and
        $prepared.policy.execution_authorized -eq $false -and
        $prepared.policy.guest_launch_allowed -eq $false -and
        $prepared.policy.guest_install_allowed -eq $false -and
        $prepared.policy.host_mutation_allowed -eq $false) `
        'Preparation must never authorize or launch guest work.'
    Assert-True (@($prepared.media).Count -eq 2 -and
        [string]$prepared.media[0].id -ceq 'quake-shareware-1.06' -and
        [string]$prepared.media[1].id -ceq 'winquake-1.00') `
        'The prepared run must bind both Quake data and WinQuake executable media.'
    Assert-True (@($prepared.cells).Count -eq 24 -and
        [int]$prepared.execution.cell_count -eq 24) `
        'The prepared run must expand eight matrix cells across three repetitions.'
    Assert-True ([string]$prepared.execution.presentation_scope -ceq 'guest-application') `
        'Windowed and fullscreen cells must describe WinQuake, not the host window.'
    Assert-True ([string]$prepared.cells[0].id -ceq '001-320x200-windowed-r1' -and
        [string]$prepared.cells[23].id -ceq '024-800x600-fullscreen-r3') `
        'The execution cell order and identities must be deterministic.'

    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($cell in @($prepared.cells)) {
        Assert-True ($ids.Add([string]$cell.id)) 'Execution cell ids must be unique.'
        Assert-True (-not [IO.Path]::IsPathRooted([string]$cell.evidence_directory) -and
            [string]$cell.evidence_directory -notmatch '(^|[\\/])\.\.([\\/]|$)') `
            'Execution evidence paths must remain relative and non-traversing.'
    }

    $repeat = @(& $preparer `
        -PlanFile $fixturePlan `
        -MediaLock $fixtureLock `
        -MediaRoot $fixtureMedia `
        -OutputFile $outputPath)
    Assert-True ($repeat[0] -ceq $success[0]) `
        'Preparing the same UTF-8 inputs must be idempotent.'

    $outputReparseTarget = Join-Path $testRoot 'output-reparse-target'
    $outputReparseLink = Join-Path $testRoot 'output-reparse-link'
    New-Item -ItemType Directory -Path $outputReparseTarget | Out-Null
    $outputReparseCreated = $false
    try {
        if ([IO.Path]::DirectorySeparatorChar -eq '\') {
            New-Item -ItemType Junction -Path $outputReparseLink `
                -Target $outputReparseTarget | Out-Null
        } else {
            New-Item -ItemType SymbolicLink -Path $outputReparseLink `
                -Target $outputReparseTarget | Out-Null
        }
        $outputReparseCreated = $true
    } catch {
        $outputReparseCreated = $false
    }
    if ($outputReparseCreated) {
        Assert-Throws {
            & $preparer `
                -PlanFile $fixturePlan `
                -MediaLock $fixtureLock `
                -MediaRoot $fixtureMedia `
                -OutputFile (Join-Path $outputReparseLink 'run.json')
        } 'reparse point' `
            'Preparation must reject an output path through a reparse point.'
    }

    $outside = Join-Path ([IO.Path]::GetTempPath()) (
        'retvrn99-graphics-baseline-outside-' + [Guid]::NewGuid().ToString('N') + '.json'
    )
    Assert-Throws {
        & $preparer `
            -PlanFile $fixturePlan `
            -MediaLock $fixtureLock `
            -MediaRoot $fixtureMedia `
            -OutputFile $outside
    } 'must remain inside' 'An output path outside the ignored evidence root must fail closed.'

    $differentPath = Join-Path $testRoot 'different.json'
    [IO.File]::WriteAllText($differentPath, '{}', [Text.UTF8Encoding]::new($false))
    Assert-Throws {
        & $preparer `
            -PlanFile $fixturePlan `
            -MediaLock $fixtureLock `
            -MediaRoot $fixtureMedia `
            -OutputFile $differentPath
    } 'already exists with different content' `
        'Preparation must not overwrite existing evidence with different content.'

    $missingMedia = Join-Path $testRoot 'missing-media'
    New-Item -ItemType Directory -Path $missingMedia | Out-Null
    Assert-Throws {
        & $preparer `
            -PlanFile $fixturePlan `
            -MediaLock $fixtureLock `
            -MediaRoot $missingMedia `
            -OutputFile (Join-Path $testRoot 'missing.json')
    } 'is missing' 'Preparation must require every selected baseline payload.'

    $oversizedPlan = Join-Path $testRoot 'oversized-plan.json'
    [IO.File]::WriteAllBytes($oversizedPlan, [byte[]]::new(1048577))
    Assert-Throws {
        & $preparer `
            -PlanFile $oversizedPlan `
            -MediaLock $fixtureLock `
            -MediaRoot $fixtureMedia `
            -OutputFile (Join-Path $testRoot 'oversized.json')
    } 'exceeds the 1048576-byte bound' `
        'Preparation must reject an oversized plan before parsing it.'

    $reparseTarget = Join-Path $testRoot 'reparse-plan-target'
    $reparseLink = Join-Path $testRoot 'reparse-plan-link'
    New-Item -ItemType Directory -Path $reparseTarget | Out-Null
    Copy-Item -LiteralPath $fixturePlan -Destination (
        Join-Path $reparseTarget 'baseline-plan.json'
    )
    $reparseCreated = $false
    try {
        if ([IO.Path]::DirectorySeparatorChar -eq '\') {
            New-Item -ItemType Junction -Path $reparseLink -Target $reparseTarget |
                Out-Null
        } else {
            New-Item -ItemType SymbolicLink -Path $reparseLink -Target $reparseTarget |
                Out-Null
        }
        $reparseCreated = $true
    } catch {
        $reparseCreated = $false
    }
    if ($reparseCreated) {
        Assert-Throws {
            & $preparer `
                -PlanFile (Join-Path $reparseLink 'baseline-plan.json') `
                -MediaLock $fixtureLock `
                -MediaRoot $fixtureMedia `
                -OutputFile (Join-Path $testRoot 'reparse.json')
        } 'reparse point' 'Preparation must reject a plan reached through a reparse point.'
    }

    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        $preparer,
        [ref]$tokens,
        [ref]$parseErrors
    )
    Assert-True (@($parseErrors).Count -eq 0) 'The preparer must parse without errors.'
    $allowedCommands = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($name in @(
        'Assert-NoExistingReparsePoint',
        'Assert-PathWithinRoot',
        'ConvertFrom-GswStrictJson',
        'ConvertTo-Json',
        'Get-Content',
        'Get-FileHash',
        'Get-Item',
        'Get-GswSha256Hex',
        'git',
        'Invoke-GswGraphicsBaselinePlanValidation',
        'Invoke-GswGraphicsQualificationMediaValidation',
        'Join-Path',
        'New-Item',
        'Out-Null',
        'Read-GswBoundedFileSnapshot',
        'Read-GswStrictJsonFileSnapshot',
        'Set-StrictMode',
        'Split-Path',
        'Test-Path',
        'Where-Object',
        'Write-Output'
    )) {
        [void]$allowedCommands.Add($name)
    }
    foreach ($command in @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.CommandAst]
    }, $true))) {
        $name = $command.GetCommandName()
        if ($null -ne $name) {
            Assert-True ($allowedCommands.Contains($name)) `
                "The preparer command '$name' is not on the inert allowlist."
            continue
        }
        $first = [string]$command.CommandElements[0].Extent.Text
        $allowedDynamic = (
            $command.InvocationOperator -eq [Management.Automation.Language.TokenKind]::Dot -and
            $first -ceq "(Join-Path `$PSScriptRoot 'strict-json.ps1')"
        ) -or (
            $command.InvocationOperator -eq [Management.Automation.Language.TokenKind]::Dot -and
            @('$planVerifier', '$mediaVerifier') -ccontains $first
        )
        Assert-True $allowedDynamic `
            "The preparer dynamic command '$($command.Extent.Text)' is not allowed."
    }
    $forbiddenTypes = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.TypeExpressionAst] -and
        $node.TypeName.FullName -match '(?i)Diagnostics\.Process|ProcessStartInfo|PowerShell|Runspace|ManagementObject|Wmi'
    }, $true))
    Assert-True ($forbiddenTypes.Count -eq 0) `
        'The preparer must not use process, remoting, or management execution types.'
    $scriptText = Get-Content -Raw -LiteralPath $preparer
    $snapshotReads = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -ceq 'Read-GswStrictJsonFileSnapshot'
    }, $true))
    Assert-True ($snapshotReads.Count -eq 2) `
        'The preparer must read exactly one plan snapshot and one media-lock snapshot.'
    Assert-True ($scriptText -notmatch 'Get-Content\s+-Raw\s+-LiteralPath\s+\$(planPath|lockPath)') `
        'The preparer must not reopen validated provenance JSON through raw reads.'
    Assert-True ($scriptText -match 'plan_sha256 = \$planSnapshot\.Sha256' -and
        $scriptText -match 'media_lock_sha256 = \$mediaLockSnapshot\.Sha256') `
        'Prepared provenance hashes must come directly from the validated snapshots.'
    Assert-True ($scriptText -match 'Invoke-GswGraphicsBaselinePlanValidation -Plan \$planSnapshot\.Value' -and
        $scriptText -match 'Invoke-GswGraphicsQualificationMediaValidation -Root \$mediaRootPath' -and
        $scriptText -match '-Lock \$mediaLockSnapshot\.Value -ManifestOnly') `
        'Both internal validators must consume values from the exact opened snapshots.'
    Assert-True (($scriptText | Select-String `
        -Pattern 'Read-GswBoundedFileSnapshot -Path \$payloadPath' -AllMatches
    ).Matches.Count -eq 1) `
        'Each selected media payload must be materialized through one stable snapshot.'
    Assert-True ($scriptText -match '\[IO\.FileMode\]::CreateNew' -and
        $scriptText -match '\[IO\.FileShare\]::None' -and
        $scriptText -match 'Read-GswBoundedFileSnapshot -Path \$outputPath' -and
        $scriptText -notmatch '\[IO\.File\]::WriteAllText\(\$outputPath') `
        'Output publication must compare bounded bytes and use atomic no-overwrite creation.'
    Assert-True ($scriptText -match (
        "(?m)^\`$planVerifier = Join-Path \`$PSScriptRoot 'verify-graphics-baseline-plan\.ps1'`$"
    )) 'The plan verifier invocation must remain bound to the repository script.'
    Assert-True ($scriptText -match (
        "(?m)^\`$mediaVerifier = Join-Path \`$PSScriptRoot 'verify-graphics-qualification-media\.ps1'`$"
    )) 'The media verifier invocation must remain bound to the repository script.'

    Write-Output "PASS graphics baseline run preparation ($script:tests assertions)."
} finally {
    $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
    $allowedRoot = [IO.Path]::GetFullPath((
        Join-Path $repositoryRoot '.scratch\graphics-qualification\baseline\tests'
    )).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if ($resolvedRoot.StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $resolvedRoot)) {
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
    }
}
