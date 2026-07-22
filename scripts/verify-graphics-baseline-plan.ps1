# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [string]$PlanFile,
    [string]$MediaLock,
    [Parameter(DontShow = $true)][switch]$DefineValidatorOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'strict-json.ps1')

function Invoke-GswGraphicsBaselinePlanValidation {
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][object]$MediaLockValue
    )

    function Assert-ExactProperties {
        param(
            [object]$Value,
            [string[]]$Expected,
            [string]$Label
        )

        if ($null -eq $Value) {
            throw "$Label is missing."
        }
        $actual = @($Value.PSObject.Properties.Name)
        if ($actual.Count -ne $Expected.Count) {
            throw "$Label fields do not match schema 1."
        }
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($name in $actual) {
            if (-not $names.Add([string]$name)) {
                throw "$Label contains a duplicate field."
            }
        }
        foreach ($name in $Expected) {
            if (-not $names.Contains($name)) {
                throw "$Label fields do not match schema 1."
            }
        }
    }

    function Assert-ExactSequence {
        param(
            [object[]]$Actual,
            [string[]]$Expected,
            [string]$Label
        )

        $items = @($Actual)
        if ($items.Count -ne $Expected.Count) {
            throw "$Label must contain the complete fixed sequence."
        }
        for ($i = 0; $i -lt $Expected.Count; $i += 1) {
            if ([string]$items[$i] -cne $Expected[$i]) {
                throw "$Label must contain the complete fixed sequence."
            }
        }
    }

Assert-ExactProperties $plan @(
    '_spdx', 'schema', 'id', 'policy', 'machine', 'workload', 'telemetry',
    'evidence', 'gates'
) 'Graphics baseline plan'
if ([string]$plan._spdx -cne 'GPL-3.0-only') {
    throw 'Graphics baseline plan must declare GPL-3.0-only.'
}
Assert-GswJsonInteger $plan.schema 'Graphics baseline plan schema'
if ([int]$plan.schema -ne 1) {
    throw 'Graphics baseline plan schema must be 1.'
}
if ([string]$plan.id -cne 'retvrn99-graphics-phase0-winquake-baseline-v1') {
    throw 'Graphics baseline plan id is not the fixed Phase 0 baseline.'
}

Assert-ExactProperties $plan.policy @(
    'read_only_plan',
    'verifier_must_not_mutate',
    'media_payloads_are_external',
    'guest_install_requires_fresh_authorization',
    'guest_run_requires_fresh_authorization',
    'host_mutation_requires_fresh_authorization',
    'authorized_by_this_plan'
) 'Graphics baseline policy'
foreach ($property in @(
    'read_only_plan',
    'verifier_must_not_mutate',
    'media_payloads_are_external',
    'guest_install_requires_fresh_authorization',
    'guest_run_requires_fresh_authorization',
    'host_mutation_requires_fresh_authorization',
    'authorized_by_this_plan'
)) {
    Assert-GswJsonBoolean $plan.policy.$property "Graphics baseline policy $property"
}
if ($plan.policy.read_only_plan -ne $true -or
    $plan.policy.verifier_must_not_mutate -ne $true -or
    $plan.policy.media_payloads_are_external -ne $true -or
    $plan.policy.guest_install_requires_fresh_authorization -ne $true -or
    $plan.policy.guest_run_requires_fresh_authorization -ne $true -or
    $plan.policy.host_mutation_requires_fresh_authorization -ne $true -or
    $plan.policy.authorized_by_this_plan -ne $false) {
    throw 'Graphics baseline policy must remain read-only, external-media, and fresh-authorization gated.'
}

Assert-ExactProperties $plan.machine @('guest_ram_mib', 'framebuffer_mib') `
    'Graphics baseline machine'
Assert-GswJsonInteger $plan.machine.guest_ram_mib 'Graphics baseline guest RAM'
Assert-GswJsonInteger $plan.machine.framebuffer_mib 'Graphics baseline framebuffer'
if ([int]$plan.machine.guest_ram_mib -ne 256 -or
    [int]$plan.machine.framebuffer_mib -ne 32) {
    throw 'Graphics baseline machine must use 256 MiB RAM and a 32 MiB framebuffer.'
}

Assert-ExactProperties $plan.workload @(
    'media_lock', 'media_ids', 'executable_media_id', 'matrix_kind',
    'presentation_scope', 'repetitions', 'modes', 'presentation_modes',
    'lifecycle_actions'
) 'Graphics baseline workload'
if ([string]$plan.workload.media_lock -cne 'media.lock.json') {
    throw 'Graphics baseline workload must reference media.lock.json.'
}
Assert-ExactSequence @($plan.workload.media_ids) @(
    'quake-shareware-1.06', 'winquake-1.00'
) 'Graphics baseline media ids'
if ([string]$plan.workload.executable_media_id -cne 'winquake-1.00') {
    throw 'Graphics baseline workload must use WinQuake as its executable payload.'
}
if ([string]$plan.workload.matrix_kind -cne 'cross-product') {
    throw 'Graphics baseline workload must use the full cross-product matrix.'
}
if ([string]$plan.workload.presentation_scope -cne 'guest-application') {
    throw 'Graphics baseline presentation modes must describe the guest application.'
}
Assert-GswJsonInteger $plan.workload.repetitions 'Graphics baseline repetitions'
if ([int]$plan.workload.repetitions -ne 3) {
    throw 'Graphics baseline workload must run three repetitions.'
}

$expectedModes = @(
    @(320, 200),
    @(320, 240),
    @(640, 480),
    @(800, 600)
)
$modes = @($plan.workload.modes)
Assert-GswJsonArray $plan.workload.modes 'Graphics baseline modes'
if ($modes.Count -ne $expectedModes.Count) {
    throw 'Graphics baseline mode matrix must contain four fixed modes.'
}
for ($i = 0; $i -lt $expectedModes.Count; $i += 1) {
    Assert-ExactProperties $modes[$i] @('width', 'height') "Graphics baseline mode $i"
    Assert-GswJsonInteger $modes[$i].width "Graphics baseline mode $i width"
    Assert-GswJsonInteger $modes[$i].height "Graphics baseline mode $i height"
    if ([int]$modes[$i].width -ne $expectedModes[$i][0] -or
        [int]$modes[$i].height -ne $expectedModes[$i][1]) {
        throw 'Graphics baseline mode matrix must be 320x200, 320x240, 640x480, and 800x600.'
    }
}
Assert-ExactSequence @($plan.workload.presentation_modes) @(
    'windowed', 'fullscreen'
) 'Graphics baseline presentation modes'
Assert-ExactSequence @($plan.workload.lifecycle_actions) @(
    'windowed-fullscreen-mode-churn', 'process-exit', 'relaunch', 'shutdown'
) 'Graphics baseline lifecycle actions'

Assert-ExactProperties $plan.telemetry @(
    'aggregate', 'trace', 'stages', 'counters', 'terminal_results'
) 'Graphics baseline telemetry'
Assert-ExactProperties $plan.telemetry.aggregate @(
    'period_seconds', 'bounded', 'max_windows'
) 'Graphics baseline aggregate telemetry'
Assert-GswJsonInteger $plan.telemetry.aggregate.period_seconds `
    'Graphics baseline aggregate period'
Assert-GswJsonBoolean $plan.telemetry.aggregate.bounded `
    'Graphics baseline aggregate bounded'
Assert-GswJsonInteger $plan.telemetry.aggregate.max_windows `
    'Graphics baseline aggregate window bound'
if ([int]$plan.telemetry.aggregate.period_seconds -ne 1 -or
    $plan.telemetry.aggregate.bounded -ne $true -or
    [int]$plan.telemetry.aggregate.max_windows -ne 3600) {
    throw 'Graphics baseline aggregates must be bounded one-second windows.'
}
Assert-ExactProperties $plan.telemetry.trace @(
    'enabled_by_default', 'opt_in', 'bounded', 'capacity_frames'
) 'Graphics baseline detailed trace'
Assert-GswJsonBoolean $plan.telemetry.trace.enabled_by_default `
    'Graphics baseline trace default'
Assert-GswJsonBoolean $plan.telemetry.trace.opt_in 'Graphics baseline trace opt-in'
Assert-GswJsonBoolean $plan.telemetry.trace.bounded 'Graphics baseline trace bounded'
Assert-GswJsonInteger $plan.telemetry.trace.capacity_frames `
    'Graphics baseline trace capacity'
if ($plan.telemetry.trace.enabled_by_default -ne $false -or
    $plan.telemetry.trace.opt_in -ne $true -or
    $plan.telemetry.trace.bounded -ne $true -or
    [int]$plan.telemetry.trace.capacity_frames -ne 256) {
    throw 'Graphics baseline detailed trace must be opt-in and bounded to 256 frames.'
}

Assert-ExactSequence @($plan.telemetry.stages) @(
    'vm-execution',
    'gsw-vga-write',
    'dirty-tracking',
    'descriptor-copy',
    'pixel-conversion',
    'texture-upload',
    'tracked-sdl-render-present',
    'direct-sdl-gpu-submission',
    'direct-physical-fence-completion',
    'queue',
    'compose',
    'present',
    'end-to-end'
) 'Graphics baseline telemetry stages'
Assert-ExactSequence @($plan.telemetry.counters) @(
    'vm-execution-ns',
    'gsw-mmio-write-bytes',
    'vga-io-write-bytes',
    'dirty-bytes-upper-bound',
    'descriptor-copy-bytes',
    'descriptor-copy-ns',
    'converted-pixels',
    'pixel-conversion-ns',
    'texture-upload-bytes',
    'texture-upload-ns',
    'tracked-sdl-render-present-calls',
    'tracked-sdl-render-present-ns',
    'direct-sdl-gpu-submission-calls',
    'direct-sdl-gpu-submission-failures',
    'direct-sdl-gpu-submission-ns',
    'direct-physical-fence-submissions',
    'direct-physical-fence-completions',
    'direct-physical-fence-completion-ns',
    'queue-depth-current',
    'queue-depth-sampled-peak',
    'queue-depth-lifetime-high-water',
    'coalesced-frames',
    'texture-recreates',
    'input-latency-ns',
    'max-input-latency-ns',
    'audio-underrun-events',
    'audio-underrun-frames',
    'frame-end-to-end-ns',
    'max-frame-end-to-end-ns'
) 'Graphics baseline telemetry counters'
Assert-ExactSequence @($plan.telemetry.terminal_results) @(
    'presented',
    'superseded',
    'coalesced',
    'capture-failed',
    'render-failed',
    'upload-failed',
    'compose-failed',
    'present-failed',
    'gpu-work',
    'reset'
) 'Graphics baseline terminal results'

Assert-ExactProperties $plan.evidence @(
    'root', 'must_be_git_ignored', 'commit_allowed'
) 'Graphics baseline evidence policy'
Assert-GswJsonBoolean $plan.evidence.must_be_git_ignored `
    'Graphics baseline evidence Git-ignore policy'
Assert-GswJsonBoolean $plan.evidence.commit_allowed `
    'Graphics baseline evidence commit policy'
if ([string]$plan.evidence.root -cne '.scratch/graphics-qualification/baseline' -or
    $plan.evidence.must_be_git_ignored -ne $true -or
    $plan.evidence.commit_allowed -ne $false) {
    throw 'Graphics baseline evidence must remain under the ignored .scratch root and uncommitted.'
}

Assert-ExactSequence @($plan.gates) @(
    'fresh-guest-authorization',
    'full-mode-presentation-matrix',
    'three-lifecycle-repetitions',
    'frame-cost-attribution',
    'bounded-telemetry'
) 'Graphics baseline gates'

$lock = $MediaLockValue
Assert-GswJsonExactProperties $lock @('_spdx', 'schema', 'policy', 'media') `
    'Graphics qualification media lock'
Assert-GswJsonString $lock._spdx 'Graphics qualification media lock SPDX'
Assert-GswJsonInteger $lock.schema 'Graphics qualification media lock schema'
if ([int]$lock.schema -ne 1 -or [string]$lock._spdx -cne 'GPL-3.0-only') {
    throw 'Graphics qualification media lock must use GPL-3.0-only schema 1.'
}
Assert-GswJsonExactProperties $lock.policy @(
    'payloads_are_external',
    'redistribution_allowed',
    'guest_install_requires_explicit_authorization'
) 'Graphics qualification media policy'
Assert-GswJsonArray $lock.media 'Graphics qualification media entries'
Assert-GswJsonBoolean $lock.policy.payloads_are_external `
    'Graphics qualification media external-payload policy'
Assert-GswJsonBoolean $lock.policy.redistribution_allowed `
    'Graphics qualification media redistribution policy'
Assert-GswJsonBoolean $lock.policy.guest_install_requires_explicit_authorization `
    'Graphics qualification media guest-install policy'
if ($lock.policy.payloads_are_external -ne $true -or
    $lock.policy.redistribution_allowed -ne $false -or
    $lock.policy.guest_install_requires_explicit_authorization -ne $true) {
    throw 'Graphics qualification media lock policy must remain external-only and guest-gated.'
}
$selectedMedia = @()
foreach ($mediaId in @($plan.workload.media_ids)) {
    $matches = @($lock.media | Where-Object { [string]$_.id -ceq [string]$mediaId })
    if ($matches.Count -ne 1) {
        throw "Graphics baseline media id '$mediaId' must resolve exactly once."
    }
    Assert-GswJsonExactProperties $matches[0] @(
        'id', 'title', 'relative_path', 'bytes', 'sha256', 'source_url'
    ) "Graphics baseline media '$mediaId'"
    Assert-GswJsonString $matches[0].id "Graphics baseline media '$mediaId' id"
    Assert-GswJsonString $matches[0].title "Graphics baseline media '$mediaId' title"
    Assert-GswJsonString $matches[0].relative_path "Graphics baseline media '$mediaId' path"
    Assert-GswJsonInteger $matches[0].bytes "Graphics baseline media '$mediaId' byte count"
    Assert-GswJsonString $matches[0].sha256 "Graphics baseline media '$mediaId' SHA-256"
    Assert-GswJsonString $matches[0].source_url "Graphics baseline media '$mediaId' source URL"
    if ([string]::IsNullOrWhiteSpace([string]$matches[0].title) -or
        [string]$matches[0].sha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'Graphics baseline media entries must retain their titles and SHA-256 identities.'
    }
    $selectedMedia += $matches[0]
}
if (@($plan.workload.media_ids) -cnotcontains [string]$plan.workload.executable_media_id) {
    throw 'Graphics baseline executable payload must be part of the required media set.'
}

$cells = $modes.Count * @($plan.workload.presentation_modes).Count
Write-Output (
    "PASS graphics baseline plan modes=$($modes.Count) presentations=2 " +
    "cells=$cells repetitions=3 media=quake-shareware-1.06,winquake-1.00 " +
    "aggregate=1s trace=opt-in"
)
}

if ($DefineValidatorOnly) {
    return
}
if ([string]::IsNullOrWhiteSpace($PlanFile)) {
    $PlanFile = Join-Path $PSScriptRoot '..\qualification\graphics\baseline-plan.json'
}
$planPath = [IO.Path]::GetFullPath($PlanFile)
if (-not (Test-Path -LiteralPath $planPath -PathType Leaf)) {
    throw "Graphics baseline plan not found: $planPath"
}
$planSnapshot = Read-GswStrictJsonFileSnapshot -Path $planPath `
    -Name 'Graphics baseline plan' -MaximumBytes 1048576
$plan = $planSnapshot.Value
if ([string]::IsNullOrWhiteSpace($MediaLock)) {
    $MediaLock = Join-Path (Split-Path -Parent $planPath) ([string]$plan.workload.media_lock)
}
$mediaLockPath = [IO.Path]::GetFullPath($MediaLock)
if (-not (Test-Path -LiteralPath $mediaLockPath -PathType Leaf)) {
    throw "Graphics qualification media lock not found: $mediaLockPath"
}
$mediaLockSnapshot = Read-GswStrictJsonFileSnapshot -Path $mediaLockPath `
    -Name 'Graphics qualification media lock' -MaximumBytes 1048576
Invoke-GswGraphicsBaselinePlanValidation -Plan $planSnapshot.Value `
    -MediaLockValue $mediaLockSnapshot.Value
