# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'strict-json.ps1')

$verifier = Join-Path $PSScriptRoot 'verify-graphics-baseline-plan.ps1'
$productionPlan = Join-Path $PSScriptRoot '..\qualification\graphics\baseline-plan.json'
$productionLock = Join-Path $PSScriptRoot '..\qualification\graphics\media.lock.json'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'retvrn99-graphics-baseline-' + [Guid]::NewGuid().ToString('N')
)
$testPlan = Join-Path $testRoot 'baseline-plan.json'
$testLock = Join-Path $testRoot 'media.lock.json'
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

function Write-TestPlan {
    param([scriptblock]$Mutation)

    $plan = Get-Content -Raw -LiteralPath $productionPlan | ConvertFrom-Json
    & $Mutation $plan
    [IO.File]::WriteAllText(
        $testPlan,
        ($plan | ConvertTo-Json -Depth 16),
        [Text.UTF8Encoding]::new($false)
    )
}

function Assert-PlanMutationFails {
    param(
        [scriptblock]$Mutation,
        [string]$Pattern,
        [string]$Message
    )

    Write-TestPlan $Mutation
    Assert-Throws {
        & $verifier -PlanFile $testPlan -MediaLock $productionLock
    } $Pattern $Message
}

function Assert-RawPlanMutationFails {
    param(
        [scriptblock]$Mutation,
        [string]$Pattern,
        [string]$Message
    )

    $json = Get-Content -Raw -LiteralPath $productionPlan
    $json = & $Mutation $json
    [IO.File]::WriteAllText($testPlan, $json, [Text.UTF8Encoding]::new($false))
    Assert-Throws {
        & $verifier -PlanFile $testPlan -MediaLock $productionLock
    } $Pattern $Message
}

New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
try {
    $success = @(& $verifier -PlanFile $productionPlan -MediaLock $productionLock)
    Assert-True ($success -contains (
        'PASS graphics baseline plan modes=4 presentations=2 cells=8 ' +
        'repetitions=3 media=quake-shareware-1.06,winquake-1.00 ' +
        'aggregate=1s trace=opt-in'
    )) 'The production Phase 0 baseline plan should verify.'

    Assert-PlanMutationFails { param($p) $p.schema = 2 } `
        'schema must be 1' 'A schema mutation must fail closed.'
    Assert-PlanMutationFails { param($p) $p._spdx = 'MIT' } `
        'GPL-3.0-only' 'A license mutation must fail closed.'
    Assert-PlanMutationFails { param($p) $p.policy.authorized_by_this_plan = $true } `
        'fresh-authorization gated' 'Self-authorizing guest work must fail closed.'
    Assert-PlanMutationFails { param($p) $p.policy.authorized_by_this_plan = 0 } `
        'JSON Boolean' 'A numeric false authorization value must fail closed.'
    Assert-PlanMutationFails { param($p) $p.policy.read_only_plan = 'true' } `
        'JSON Boolean' 'A string policy value must fail closed.'
    Assert-PlanMutationFails { param($p) $p.machine.guest_ram_mib = 512 } `
        '256 MiB RAM' 'A guest RAM mutation must fail closed.'
    Assert-PlanMutationFails { param($p) $p.machine.guest_ram_mib = '256' } `
        'JSON integer' 'A string guest RAM value must fail closed.'
    Assert-PlanMutationFails { param($p) $p.machine.framebuffer_mib = 64 } `
        '32 MiB framebuffer' 'A framebuffer mutation must fail closed.'
    Assert-PlanMutationFails {
        param($p)
        $p.workload.media_ids = @('winquake-1.00')
    } 'media ids' 'Removing the Quake data payload must fail closed.'
    Assert-PlanMutationFails {
        param($p)
        $p.workload.executable_media_id = 'quake-shareware-1.06'
    } 'WinQuake as its executable' 'Changing the executable payload must fail closed.'
    Assert-PlanMutationFails {
        param($p)
        $p.workload.modes = @($p.workload.modes | Select-Object -First 3)
    } 'four fixed modes' 'An incomplete resolution matrix must fail closed.'
    Assert-PlanMutationFails {
        param($p)
        $p.workload.presentation_modes = @('windowed')
    } 'presentation modes' 'An incomplete presentation matrix must fail closed.'
    Assert-PlanMutationFails {
        param($p)
        $p.workload.presentation_scope = 'host-window'
    } 'guest application' 'Host-window state must not substitute for guest presentation mode.'
    Assert-PlanMutationFails { param($p) $p.workload.repetitions = 2 } `
        'three repetitions' 'A repetition mutation must fail closed.'
    Assert-PlanMutationFails { param($p) $p.workload.repetitions = 3.5 } `
        'JSON integer' 'A fractional repetition count must fail closed.'
    Assert-PlanMutationFails {
        param($p)
        $p.workload.lifecycle_actions = @(
            'windowed-fullscreen-mode-churn', 'process-exit', 'shutdown'
        )
    } 'lifecycle actions' 'Removing relaunch from the lifecycle must fail closed.'
    Assert-PlanMutationFails {
        param($p)
        $p.telemetry.stages[6] = 'alternate-renderer-submit'
    } 'telemetry stages' 'A required telemetry stage mutation must fail closed.'
    Assert-PlanMutationFails {
        param($p)
        $p.telemetry.counters[3] = 'dirty-pages-only'
    } 'telemetry counters' 'A required telemetry counter mutation must fail closed.'
    Assert-PlanMutationFails {
        param($p)
        $p.telemetry.terminal_results[9] = 'device-lost'
    } 'terminal results' 'A terminal result mutation must fail closed.'
    Assert-PlanMutationFails { param($p) $p.telemetry.aggregate.period_seconds = 2 } `
        'one-second windows' 'A non-one-second aggregate must fail closed.'
    Assert-PlanMutationFails { param($p) $p.telemetry.trace.enabled_by_default = $true } `
        'opt-in and bounded' 'A default-on detailed trace must fail closed.'
    Assert-PlanMutationFails {
        param($p)
        $p.evidence.root = 'qualification/graphics/evidence'
    } 'ignored .scratch root' 'A tracked evidence root must fail closed.'
    Assert-PlanMutationFails {
        param($p)
        $p.gates[0] = 'guest-run-authorized'
    } 'baseline gates' 'Removing the fresh guest authorization gate must fail closed.'
    Assert-PlanMutationFails {
        param($p)
        $p | Add-Member -NotePropertyName renderer -NotePropertyValue 'software'
    } 'fields do not match schema 1' 'An unknown schema field must fail closed.'
    Assert-RawPlanMutationFails {
        param($json)
        $mutated = $json -creplace '"guest_ram_mib"\s*:\s*256\s*,', `
            '"guest_ram_mib": 256, "GUEST_RAM_MIB": 512,'
        if ($mutated -ceq $json) {
            throw 'The duplicate plan property mutation did not apply.'
        }
        $mutated
    } 'Duplicate JSON property.*GUEST_RAM_MIB' `
        'A nested case-insensitive duplicate plan property must fail before conversion.'

    [IO.File]::WriteAllBytes($testPlan, [byte[]]::new(1048577))
    Assert-Throws {
        & $verifier -PlanFile $testPlan -MediaLock $productionLock
    } 'exceeds the 1048576-byte bound' `
        'An oversized baseline plan must fail before JSON parsing.'

    [IO.File]::WriteAllBytes($testLock, [byte[]]::new(1048577))
    Assert-Throws {
        & $verifier -PlanFile $productionPlan -MediaLock $testLock
    } 'exceeds the 1048576-byte bound' `
        'An oversized media lock must fail before JSON parsing.'

    $mutablePlan = Join-Path $testRoot 'mutable-plan.json'
    $replacementPlan = Join-Path $testRoot 'replacement-plan.json'
    $planText = Get-Content -Raw -LiteralPath $productionPlan
    $replacementText = $planText.Replace(
        'retvrn99-graphics-phase0-winquake-baseline-v1',
        'retvrn99-graphics-phase0-winquake-baseline-v2'
    )
    [IO.File]::WriteAllText($mutablePlan, $planText, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText(
        $replacementPlan,
        $replacementText,
        [Text.UTF8Encoding]::new($false)
    )
    Assert-Throws {
        Read-GswStrictJsonFileSnapshot -Path $mutablePlan `
            -Name 'Mutable graphics baseline plan' -MaximumBytes 1048576 `
            -BeforePostReadCheck {
                param($openedPath)
                Move-Item -LiteralPath $replacementPlan -Destination $openedPath -Force
            }
    } 'changed during its bounded read' `
        'A plan replacement during its stability window must fail closed.'

    Copy-Item -LiteralPath $productionPlan -Destination $testPlan -Force
    $capturedPlan = Read-GswStrictJsonFileSnapshot -Path $testPlan `
        -Name 'Captured graphics baseline plan' -MaximumBytes 1048576
    $capturedLock = Read-GswStrictJsonFileSnapshot -Path $productionLock `
        -Name 'Captured graphics media lock' -MaximumBytes 1048576
    [IO.File]::WriteAllText(
        $testPlan,
        $replacementText,
        [Text.UTF8Encoding]::new($false)
    )
    $null = . $verifier -DefineValidatorOnly
    $capturedSuccess = @(Invoke-GswGraphicsBaselinePlanValidation `
        -Plan $capturedPlan.Value -MediaLockValue $capturedLock.Value)
    Assert-True ($capturedSuccess -contains (
        'PASS graphics baseline plan modes=4 presentations=2 cells=8 ' +
        'repetitions=3 media=quake-shareware-1.06,winquake-1.00 ' +
        'aggregate=1s trace=opt-in'
    )) 'Validation must remain bound to captured bytes after an on-disk replacement.'
    Assert-Throws {
        & $verifier -PlanFile $testPlan -MediaLock $productionLock `
            -PlanSnapshot $capturedPlan
    } 'PlanSnapshot' `
        'The standalone verifier must not accept caller-supplied snapshots.'

    $reparseTarget = Join-Path $testRoot 'reparse-plan-target'
    $reparseLink = Join-Path $testRoot 'reparse-plan-link'
    New-Item -ItemType Directory -Path $reparseTarget | Out-Null
    Copy-Item -LiteralPath $productionPlan -Destination (
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
            & $verifier `
                -PlanFile (Join-Path $reparseLink 'baseline-plan.json') `
                -MediaLock $productionLock
        } 'reparse point' 'A baseline plan reached through a reparse point must fail closed.'
    }

    $wrongTypeLock = Get-Content -Raw -LiteralPath $productionLock | ConvertFrom-Json
    $wrongTypeLock.media[0].title = $true
    [IO.File]::WriteAllText(
        $testLock,
        ($wrongTypeLock | ConvertTo-Json -Depth 8),
        [Text.UTF8Encoding]::new($false)
    )
    Assert-Throws {
        & $verifier -PlanFile $productionPlan -MediaLock $testLock
    } 'JSON string' 'A Boolean media title must fail the baseline plan verifier.'

    Write-Output "PASS graphics baseline plan verifier ($script:tests assertions)."
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
