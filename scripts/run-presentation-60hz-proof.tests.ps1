# SPDX-License-Identifier: GPL-3.0-only

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$support = Join-Path $PSScriptRoot 'presentation-60hz-proof-support.ps1'
$runner = Join-Path $PSScriptRoot 'run-presentation-60hz-proof.ps1'
. $support

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
    }
    catch {
        if ($_.Exception.Message -like "*$Pattern*") { return }
        throw "$Message Unexpected error: $($_.Exception.Message)"
    }
    throw $Message
}

function New-PresentationProofResult {
    param(
        [int]$Width = 1024,
        [int]$Height = 768,
        [UInt64]$PipelineNs = 3999999
    )

    [UInt64]$limit = Get-PresentationProofP95Limit -Width $Width -Height $Height
    $samples = @()
    for ($index = 0; $index -lt 275; $index += 1) {
        [UInt64]$scheduled = ([Numerics.BigInteger]$index * 1000000000) / 60
        [UInt64]$started = $scheduled + 1000000
        $samples += [ordered]@{
            index = $index
            slot = $index
            skipped_before = 0
            scheduled_offset_ns = $scheduled
            started_offset_ns = $started
            completed_offset_ns = $started + $PipelineNs
            pipeline_ns = $PipelineNs
            present_ns = 1000000
        }
    }
    $metrics = [ordered]@{}
    foreach ($field in $script:PresentationProofMetricFields) { $metrics[$field] = 0 }
    $metrics.gsw_snapshot_partial_updates = 275
    $metrics.upload_bytes = 275 * 64 * 64 * 4
    $metrics.upload_regions = 275
    $metrics.resource_reuses = 275
    $pipeline = [ordered]@{
        p50_ns = $PipelineNs
        p95_ns = $PipelineNs
        p99_ns = $PipelineNs
        max_ns = $PipelineNs
    }
    $present = [ordered]@{
        p50_ns = 1000000
        p95_ns = 1000000
        p99_ns = 1000000
        max_ns = 1000000
    }
    return [ordered]@{
        schema = 1
        tool = 'retvrn99-presentation-60hz-proof'
        proof_scope = 'synthetic host presentation/upload/render/present only'
        synthetic_source = 'GSW2D snapshot with moving 64x64 dirty region'
        presentation_path = 'host_presentation_admit_gsw>host_presentation_stage_gsw_snapshot>host_presentation_commit_gsw_snapshot_staged>host_render_guest>SDL_RenderPresent'
        target_hz = 60
        minimum_fps_milli = 55000
        host_presentation_metric = 'pipeline_ns'
        host_presentation_p95_limit_ns = $limit
        width = $Width
        height = $Height
        warmup_seconds = 2
        stable_seconds = 5
        output_width = $Width
        output_height = $Height
        vsync = $true
        warmup_presented = 110
        stable_attempted = 275
        stable_presented = 275
        stable_skipped_slots = 25
        stable_elapsed_ns = 5000000000
        presented_fps_milli = 55000
        sample_count = 275
        sample_capacity = 4096
        sample_overflow = $false
        pipeline_timing = $pipeline
        present_timing = $present
        stable_host_metrics = $metrics
        stable_host_metrics_valid = $true
        gate_pass = $true
        failure = 'none'
        samples = $samples
    }
}

function ConvertTo-PresentationProofJson {
    param([Parameter(Mandatory = $true)][object]$Value)
    return $Value | ConvertTo-Json -Compress -Depth 100
}

$testParent = Join-Path $repository 'dev\presentation-60hz-proof-tests'
$testRoot = Join-Path $testParent ("run-{0}-{1}" -f $PID, [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

try {
    $runRoot = Join-Path $testRoot 'run'
    New-Item -ItemType Directory -Path $runRoot | Out-Null
    $child = Join-Path $runRoot 'evidence'
    Assert-True ((Assert-PresentationProofAbsentChild -RunRoot $runRoot -Path $child `
        -Name 'evidence') -ceq [IO.Path]::GetFullPath($child)) `
        'An absent direct evidence child should pass.'
    New-Item -ItemType Directory -Path $child | Out-Null
    Assert-Throws {
        Assert-PresentationProofAbsentChild -RunRoot $runRoot -Path $child -Name 'evidence'
    } 'must be absent' 'An existing evidence child must fail closed.'
    Assert-Throws {
        Assert-PresentationProofAbsentChild -RunRoot $runRoot `
            -Path (Join-Path $runRoot 'nested\evidence') -Name 'evidence'
    } 'direct child' 'A nested evidence path must fail closed.'
    Assert-Throws {
        Get-PresentationProofFullPath -Path '.\relative' -Name 'unsafe'
    } 'fully qualified local drive path' 'A relative path must fail closed.'
    Assert-Throws {
        Get-PresentationProofFullPath -Path '\\server\share\evidence' -Name 'unsafe'
    } 'UNC paths are forbidden' 'A UNC path must fail closed.'
    Assert-Throws {
        Get-PresentationProofFullPath -Path ($runRoot + ':stream') -Name 'unsafe'
    } 'alternate data stream' 'An alternate data stream must fail closed.'
    Assert-Throws {
        Get-PresentationProofP95Limit -Width 800 -Height 600
    } 'Only the 1024x768 and 1920x1080' `
        'An unnamed reference extent must fail closed.'
    $adsFile = Join-Path $runRoot 'ads.txt'
    [IO.File]::WriteAllText($adsFile, 'ordinary', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($adsFile + ':proof', 'hidden', [Text.UTF8Encoding]::new($false))
    Assert-Throws {
        Assert-PresentationProofOrdinaryPath -Path $adsFile -Name 'ADS file' -Kind File
    } 'must not contain alternate data streams' `
        'An ordinary-looking file with an attached data stream must fail closed.'

    $junctionTarget = Join-Path $testRoot 'junction-target'
    $junction = Join-Path $runRoot 'junction'
    New-Item -ItemType Directory -Path $junctionTarget | Out-Null
    New-Item -ItemType Junction -Path $junction -Target $junctionTarget | Out-Null
    Assert-Throws {
        Assert-PresentationProofOrdinaryPath -Path $junction -Name 'junction' -Kind Directory
    } 'reparse point' 'A reparse-point run path must fail closed.'
    Remove-Item -LiteralPath $junction -Force

    $valid1024 = New-PresentationProofResult
    $validated = Assert-PresentationProofResult `
        -Json (ConvertTo-PresentationProofJson $valid1024) `
        -Width 1024 -Height 768 -WarmupSeconds 2 -StableSeconds 5
    Assert-True ($validated.gate_pass -eq $true) `
        'A complete 1024x768 result below the strict p95 gate should validate.'

    $valid1920 = New-PresentationProofResult -Width 1920 -Height 1080 -PipelineNs 7999999
    $validated = Assert-PresentationProofResult `
        -Json (ConvertTo-PresentationProofJson $valid1920) `
        -Width 1920 -Height 1080 -WarmupSeconds 2 -StableSeconds 5
    Assert-True ($validated.pipeline_timing.p95_ns -eq 7999999) `
        'A complete 1920x1080 result below the strict p95 gate should validate.'

    foreach ($case in @(
        [pscustomobject]@{ Width = 1024; Height = 768; Pipeline = [UInt64]4000000 },
        [pscustomobject]@{ Width = 1920; Height = 1080; Pipeline = [UInt64]8000000 }
    )) {
        $equal = New-PresentationProofResult -Width $case.Width -Height $case.Height `
            -PipelineNs $case.Pipeline
        Assert-Throws {
            Assert-PresentationProofResult -Json (ConvertTo-PresentationProofJson $equal) `
                -Width $case.Width -Height $case.Height -WarmupSeconds 2 -StableSeconds 5
        } 'strict reference-host gate' `
            "Equality at the $($case.Width)x$($case.Height) p95 limit must fail."
    }

    $forged = New-PresentationProofResult
    $forged.vsync = $false
    $forged.output_width = 1
    $forged.presented_fps_milli = 1
    $forged.stable_host_metrics_valid = $false
    $forged.failure = 'fabricated failure'
    Assert-Throws {
        Assert-PresentationProofResult -Json (ConvertTo-PresentationProofJson $forged) `
            -Width 1024 -Height 768 -WarmupSeconds 2 -StableSeconds 5
    } 'fixed gate fields are invalid' `
        'A forged gate_pass result must not bypass independent validation.'

    $badSample = New-PresentationProofResult
    $badSample.samples[10].pipeline_ns += 1
    Assert-Throws {
        Assert-PresentationProofResult -Json (ConvertTo-PresentationProofJson $badSample) `
            -Width 1024 -Height 768 -WarmupSeconds 2 -StableSeconds 5
    } 'invalid timing accounting' 'A forged sample duration must fail closed.'

    $badSummary = New-PresentationProofResult
    $badSummary.pipeline_timing.p95_ns = 1
    Assert-Throws {
        Assert-PresentationProofResult -Json (ConvertTo-PresentationProofJson $badSummary) `
            -Width 1024 -Height 768 -WarmupSeconds 2 -StableSeconds 5
    } 'does not match the retained samples' `
        'A forged nearest-rank timing summary must fail closed.'

    $badFps = New-PresentationProofResult
    $badFps.presented_fps_milli = 55001
    Assert-Throws {
        Assert-PresentationProofResult -Json (ConvertTo-PresentationProofJson $badFps) `
            -Width 1024 -Height 768 -WarmupSeconds 2 -StableSeconds 5
    } 'below or inconsistent' 'A forged FPS summary must fail closed.'

    $badMetrics = New-PresentationProofResult
    $badMetrics.stable_host_metrics.copy_bytes = 1
    Assert-Throws {
        Assert-PresentationProofResult -Json (ConvertTo-PresentationProofJson $badMetrics) `
            -Width 1024 -Height 768 -WarmupSeconds 2 -StableSeconds 5
    } 'copy_bytes violates' 'A forged zero-copy metric must fail closed.'

    $missingTail = New-PresentationProofResult
    $missingTail.stable_skipped_slots = 0
    Assert-Throws {
        Assert-PresentationProofResult -Json (ConvertTo-PresentationProofJson $missingTail) `
            -Width 1024 -Height 768 -WarmupSeconds 2 -StableSeconds 5
    } 'count, duration, or capacity accounting' `
        'Trailing cadence slots after a long final frame must remain counted as skipped.'

    $duplicate = (ConvertTo-PresentationProofJson (New-PresentationProofResult)) `
        -replace '^\{"schema":1,', '{"schema":1,"schema":1,'
    Assert-Throws {
        Assert-PresentationProofResult -Json $duplicate -Width 1024 -Height 768 `
            -WarmupSeconds 2 -StableSeconds 5
    } 'Duplicate JSON property' 'Duplicate result fields must fail closed.'

    $sourceTree = Join-Path $testRoot 'source'
    New-Item -ItemType Directory -Path $sourceTree | Out-Null
    $sourceFile = Join-Path $sourceTree 'source.txt'
    [IO.File]::WriteAllText($sourceFile, 'before', [Text.UTF8Encoding]::new($false))
    $before = @(Get-PresentationProofTreeInventory -Root $sourceTree `
        -DisplayPrefix 'source' -Name 'synthetic source')
    [IO.File]::WriteAllText($sourceFile, 'after!', [Text.UTF8Encoding]::new($false))
    $after = @(Get-PresentationProofTreeInventory -Root $sourceTree `
        -DisplayPrefix 'source' -Name 'synthetic source')
    Assert-Throws {
        Assert-PresentationProofStateEqual -Expected $before -Actual $after `
            -Name 'synthetic source'
    } 'changed during the proof run' 'Source drift must fail closed.'

    $timeoutStdout = Join-Path $testRoot 'timeout.stdout.txt'
    $timeoutStderr = Join-Path $testRoot 'timeout.stderr.txt'
    $pwsh = (Get-Process -Id $PID).Path
    $timeout = Invoke-PresentationProofCapturedProcess -FilePath $pwsh `
        -Arguments @(
            '-NoLogo',
            '-NoProfile',
            '-NonInteractive',
            '-Command',
            "[Console]::Out.Write('before-timeout'); [Console]::Out.Flush(); Start-Sleep -Seconds 5"
        ) `
        -WorkingDirectory $testRoot -StdoutPath $timeoutStdout `
        -StderrPath $timeoutStderr -TimeoutMilliseconds 250
    Assert-True ($timeout.TimedOut -and
        (Get-Content -Raw -LiteralPath $timeoutStdout) -ceq 'before-timeout' -and
        (Test-Path -LiteralPath $timeoutStderr -PathType Leaf)) `
        'A timed-out process must preserve its completed stdout and stderr files.'

    $overflowStdout = Join-Path $testRoot 'overflow.stdout.txt'
    $overflowStderr = Join-Path $testRoot 'overflow.stderr.txt'
    Assert-Throws {
        Invoke-PresentationProofCapturedProcess -FilePath $pwsh `
            -Arguments @(
                '-NoLogo',
                '-NoProfile',
                '-NonInteractive',
                '-Command',
                "[Console]::Out.Write(('x' * 512)); [Console]::Out.Flush()"
            ) `
            -WorkingDirectory $testRoot -StdoutPath $overflowStdout `
            -StderrPath $overflowStderr -TimeoutMilliseconds 5000 `
            -MaximumStdoutBytes 64 -MaximumStderrBytes 64
    } 'bounded stdout or stderr evidence size' `
        'Output beyond the fixed evidence bound must fail closed.'
    Assert-True ((Get-Item -LiteralPath $overflowStdout).Length -eq 64 -and
        (Get-Item -LiteralPath $overflowStderr).Length -eq 0) `
        'Oversized output evidence must be retained only to its declared bound.'

    foreach ($scriptPath in @($support, $runner)) {
        $tokens = $null
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile(
            $scriptPath,
            [ref]$tokens,
            [ref]$errors
        )
        Assert-True (@($errors).Count -eq 0) `
            "PowerShell parser errors were found in '$scriptPath'."
    }
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $runRoot 'live-evidence'))) `
        'Non-live tests must not create or launch a presentation proof.'

    Write-Output "PASS run-presentation-60hz-proof tests=$script:tests"
}
finally {
    $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
    $resolvedParent = [IO.Path]::GetFullPath($testParent)
    if ($resolvedRoot.StartsWith(
        $resolvedParent.TrimEnd([IO.Path]::DirectorySeparatorChar) +
            [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    ) -and (Test-Path -LiteralPath $resolvedRoot)) {
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
    }
}
