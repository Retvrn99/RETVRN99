# SPDX-License-Identifier: GPL-3.0-only

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'strict-json.ps1')

$script:PresentationProofTopFields = @(
    'schema',
    'tool',
    'proof_scope',
    'synthetic_source',
    'presentation_path',
    'target_hz',
    'minimum_fps_milli',
    'host_presentation_metric',
    'host_presentation_p95_limit_ns',
    'width',
    'height',
    'warmup_seconds',
    'stable_seconds',
    'output_width',
    'output_height',
    'vsync',
    'warmup_presented',
    'stable_attempted',
    'stable_presented',
    'stable_skipped_slots',
    'stable_elapsed_ns',
    'presented_fps_milli',
    'sample_count',
    'sample_capacity',
    'sample_overflow',
    'pipeline_timing',
    'present_timing',
    'stable_host_metrics',
    'stable_host_metrics_valid',
    'gate_pass',
    'failure',
    'samples'
)

$script:PresentationProofMetricFields = @(
    'legacy_full_updates',
    'legacy_partial_updates',
    'gsw_snapshot_full_updates',
    'gsw_snapshot_partial_updates',
    'copy_bytes',
    'conversion_pixels',
    'upload_bytes',
    'upload_regions',
    'stale_generation_drops',
    'stale_finalization_drops',
    'invalid_rejections',
    'closed_rejections',
    'resident_presents',
    'readback_requests',
    'readback_bytes',
    'last_good_restorations',
    'resource_reuses',
    'resource_recreations',
    'resource_retirements',
    'full_fallback_uploads',
    'overlay_invalidated_regions',
    'overlay_full_invalidations',
    'source_full_initial',
    'source_full_mode',
    'source_full_ambiguous',
    'source_full_capacity',
    'source_full_external'
)

$script:PresentationProofSampleFields = @(
    'index',
    'slot',
    'skipped_before',
    'scheduled_offset_ns',
    'started_offset_ns',
    'completed_offset_ns',
    'pipeline_ns',
    'present_ns'
)

$script:PresentationProofTimingFields = @('p50_ns', 'p95_ns', 'p99_ns', 'max_ns')

function Initialize-PresentationProofBoundedCapture {
    if ($null -ne ('Retvrn99.PresentationProof.BoundedCapture' -as [type])) { return }
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Threading.Tasks;

namespace Retvrn99.PresentationProof {
    public sealed class BoundedCapture {
        private readonly Stream source;
        private readonly MemoryStream retained;
        private readonly int maximumBytes;
        private readonly object sync = new object();
        private bool overflow;

        private BoundedCapture(Stream source, int maximumBytes) {
            this.source = source;
            this.maximumBytes = maximumBytes;
            this.retained = new MemoryStream(Math.Min(maximumBytes, 65536));
            this.Completion = this.PumpAsync();
        }

        public Task Completion { get; private set; }

        public static BoundedCapture Start(Stream source, int maximumBytes) {
            if (source == null) throw new ArgumentNullException(nameof(source));
            if (maximumBytes <= 0) throw new ArgumentOutOfRangeException(nameof(maximumBytes));
            return new BoundedCapture(source, maximumBytes);
        }

        private async Task PumpAsync() {
            byte[] buffer = new byte[65536];
            while (true) {
                int read = await this.source.ReadAsync(buffer, 0, buffer.Length).ConfigureAwait(false);
                if (read == 0) return;
                lock (this.sync) {
                    int available = this.maximumBytes - (int)this.retained.Length;
                    int keep = Math.Min(available, read);
                    if (keep > 0) this.retained.Write(buffer, 0, keep);
                    if (keep != read) this.overflow = true;
                }
            }
        }

        public byte[] Snapshot(out bool overflowed) {
            lock (this.sync) {
                overflowed = this.overflow;
                return this.retained.ToArray();
            }
        }
    }
}
'@ | Out-Null
}

function Get-PresentationProofFullPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.IndexOf([char]0) -ge 0) {
        throw "$Name is empty or invalid."
    }
    if (-not [IO.Path]::IsPathFullyQualified($Path) -or $Path -cnotmatch '^[A-Za-z]:[\\/]') {
        throw "$Name must be a fully qualified local drive path; UNC paths are forbidden."
    }
    try {
        $root = [IO.Path]::GetPathRoot($Path)
        foreach ($segment in $Path.Substring($root.Length) -split '[\\/]') {
            if ($segment.Length -eq 0) { continue }
            if ($segment -eq '.' -or $segment -eq '..' -or
                $segment.EndsWith(' ') -or $segment.EndsWith('.') -or
                $segment.Contains(':') -or
                [Management.Automation.WildcardPattern]::ContainsWildcardCharacters($segment)) {
                throw "$Name contains an unsafe path segment or alternate data stream."
            }
        }
        $drive = [IO.DriveInfo]::new($root)
        if ($drive.DriveType -eq [IO.DriveType]::Network) {
            throw "$Name must be on a local filesystem."
        }
        return [IO.Path]::GetFullPath($Path)
    }
    catch {
        if ($_.Exception.Message -like "$Name contains an unsafe path segment*" -or
            $_.Exception.Message -like "$Name must be on a local filesystem*") { throw }
        throw "$Name is not a valid local path."
    }
}

function Assert-PresentationProofOrdinaryPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('File', 'Directory')][string]$Kind
    )

    $fullPath = Get-PresentationProofFullPath -Path $Path -Name $Name
    Assert-GswNoReparseAncestor -Path $fullPath -Name $Name
    $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
    $directory = ($item.Attributes -band [IO.FileAttributes]::Directory) -ne 0
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        ($item.Attributes -band [IO.FileAttributes]::Device) -ne 0 -or
        ($Kind -eq 'File' -and $directory) -or
        ($Kind -eq 'Directory' -and -not $directory)) {
        throw "$Name must be one ordinary $($Kind.ToLowerInvariant())."
    }
    if ($Kind -eq 'File') {
        $streams = @(Get-Item -LiteralPath $fullPath -Stream * -ErrorAction Stop)
        if ($streams.Count -ne 1 -or [string]$streams[0].Stream -cne ':$DATA') {
            throw "$Name must not contain alternate data streams."
        }
    }
    return $item
}

function Assert-PresentationProofAbsentChild {
    param(
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $run = (Assert-PresentationProofOrdinaryPath -Path $RunRoot -Name 'run root' `
        -Kind Directory).FullName
    $child = Get-PresentationProofFullPath -Path $Path -Name $Name
    $parent = [IO.Path]::GetDirectoryName($child)
    if (-not $parent.Equals($run, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Name must be a direct child of the run root."
    }
    if (Test-Path -LiteralPath $child) { throw "$Name must be absent." }
    Assert-GswNoReparseAncestor -Path $parent -Name "$Name parent"
    return $child
}

function Assert-PresentationProofOrdinaryTree {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $item = Assert-PresentationProofOrdinaryPath -Path $Root -Name $Name -Kind Directory
    foreach ($child in Get-ChildItem -LiteralPath $item.FullName -Force -Recurse) {
        if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            ($child.Attributes -band [IO.FileAttributes]::Device) -ne 0) {
            throw "$Name contains nonordinary path '$($child.FullName)'."
        }
    }
    return $item
}

function Write-PresentationProofNewText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )

    $fullPath = Get-PresentationProofFullPath -Path $Path -Name 'evidence file'
    Assert-GswNoReparseAncestor -Path ([IO.Path]::GetDirectoryName($fullPath)) `
        -Name 'evidence file parent'
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
    $stream = [IO.File]::Open($fullPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally {
        $stream.Dispose()
    }
    $null = Assert-PresentationProofOrdinaryPath -Path $fullPath `
        -Name 'evidence file' -Kind File
}

function Write-PresentationProofNewBytes {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes
    )

    $fullPath = Get-PresentationProofFullPath -Path $Path -Name 'evidence file'
    Assert-GswNoReparseAncestor -Path ([IO.Path]::GetDirectoryName($fullPath)) `
        -Name 'evidence file parent'
    $stream = [IO.File]::Open($fullPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $stream.Write($Bytes, 0, $Bytes.Length)
        $stream.Flush($true)
    }
    finally {
        $stream.Dispose()
    }
    $null = Assert-PresentationProofOrdinaryPath -Path $fullPath `
        -Name 'evidence file' -Kind File
}

function Write-PresentationProofNewJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )

    Write-PresentationProofNewText -Path $Path `
        -Text (($Value | ConvertTo-Json -Depth 100) + "`n")
}

function Get-PresentationProofFileRecord {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$DisplayPath
    )

    $item = Assert-PresentationProofOrdinaryPath -Path $Path -Name $DisplayPath -Kind File
    $snapshot = Read-GswBoundedFileSnapshot -Path $item.FullName -Name $DisplayPath `
        -MaximumBytes 1073741824 -AllowEmpty
    return [pscustomobject][ordered]@{
        path = $DisplayPath.Replace('\', '/')
        bytes = [UInt64]$snapshot.Length
        sha256 = $snapshot.Sha256
    }
}

function Get-PresentationProofTreeInventory {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$DisplayPrefix,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $tree = Assert-PresentationProofOrdinaryTree -Root $Root -Name $Name
    $records = foreach ($file in Get-ChildItem -LiteralPath $tree.FullName -Force -File -Recurse |
        Sort-Object FullName) {
        $relative = [IO.Path]::GetRelativePath($tree.FullName, $file.FullName)
        Get-PresentationProofFileRecord -Path $file.FullName `
            -DisplayPath ($DisplayPrefix.TrimEnd('/') + '/' + $relative.Replace('\', '/'))
    }
    return @($records)
}

function Get-PresentationProofSourceInventory {
    param([Parameter(Mandatory = $true)][string]$Repository)

    $repo = (Assert-PresentationProofOrdinaryPath -Path $Repository -Name 'repository' `
        -Kind Directory).FullName
    $records = @()
    $records += Get-PresentationProofTreeInventory -Root (Join-Path $repo 'src') `
        -DisplayPrefix 'src' -Name 'production source tree'
    $records += Get-PresentationProofTreeInventory `
        -Root (Join-Path $repo 'tools\presentation-60hz-proof') `
        -DisplayPrefix 'tools/presentation-60hz-proof' -Name 'presentation proof source tree'
    $records += Get-PresentationProofTreeInventory -Root (Join-Path $repo 'assets') `
        -DisplayPrefix 'assets' -Name 'compiled asset tree'
    foreach ($relative in @(
        'scripts\run-presentation-60hz-proof.ps1',
        'scripts\presentation-60hz-proof-support.ps1',
        'scripts\run-presentation-60hz-proof.tests.ps1',
        'scripts\strict-json.ps1',
        'docs\presentation-60hz-proof.md',
        'SDL3.dll'
    )) {
        $records += Get-PresentationProofFileRecord -Path (Join-Path $repo $relative) `
            -DisplayPath $relative
    }
    return @($records | Sort-Object path)
}

function Get-PresentationProofGitIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$Git,
        [Parameter(Mandatory = $true)][string]$Repository
    )

    $head = (& $Git -C $Repository rev-parse HEAD | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $head -cnotmatch '^[0-9a-f]{40}$') {
        throw 'Could not identify the exact source commit.'
    }
    $branch = (& $Git -C $Repository branch --show-current | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Could not identify the source branch.' }
    $status = @(& $Git -C $Repository status --porcelain=v1 --untracked-files=all)
    if ($LASTEXITCODE -ne 0) { throw 'Could not capture the source worktree status.' }
    $version = (& $Git version | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Could not identify Git.' }
    $gitItem = Assert-PresentationProofOrdinaryPath -Path $Git -Name 'Git executable' -Kind File
    return [pscustomobject][ordered]@{
        executable = $gitItem.FullName
        executable_sha256 = (Get-FileHash -LiteralPath $gitItem.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        version = $version
        commit = $head
        branch = $branch
        dirty = $status.Count -ne 0
        status = @($status)
    }
}

function Get-PresentationProofToolchainIdentity {
    param([Parameter(Mandatory = $true)][string]$Odin)

    $version = (& $Odin version | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Could not identify the Odin compiler.' }
    $rootText = (& $Odin root | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Could not identify the Odin root.' }
    $odinItem = Assert-PresentationProofOrdinaryPath -Path $Odin -Name 'Odin compiler' -Kind File
    $odinRoot = (Assert-PresentationProofOrdinaryPath -Path $rootText -Name 'Odin root' `
        -Kind Directory).FullName
    $vendor = @(Get-PresentationProofTreeInventory -Root (Join-Path $odinRoot 'vendor\sdl3') `
        -DisplayPrefix 'odin/vendor/sdl3' -Name 'Odin SDL3 bindings')
    return [pscustomobject][ordered]@{
        executable = $odinItem.FullName
        executable_sha256 = (Get-FileHash -LiteralPath $odinItem.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        version = $version
        root = $odinRoot
        sdl3_bindings = $vendor
    }
}

function Assert-PresentationProofStateEqual {
    param(
        [Parameter(Mandatory = $true)][object]$Expected,
        [Parameter(Mandatory = $true)][object]$Actual,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $expectedJson = $Expected | ConvertTo-Json -Compress -Depth 100
    $actualJson = $Actual | ConvertTo-Json -Compress -Depth 100
    if ($expectedJson -cne $actualJson) { throw "$Name changed during the proof run." }
}

function Invoke-PresentationProofCapturedProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string]$StdoutPath,
        [Parameter(Mandatory = $true)][string]$StderrPath,
        [Parameter(Mandatory = $true)][ValidateRange(1, 3600000)][int]$TimeoutMilliseconds,
        [ValidateRange(1, 268435456)][int]$MaximumStdoutBytes = 67108864,
        [ValidateRange(1, 268435456)][int]$MaximumStderrBytes = 67108864
    )

    Initialize-PresentationProofBoundedCapture
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $startInfo.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    $startInfo.CreateNoWindow = $true
    foreach ($argument in $Arguments) { [void]$startInfo.ArgumentList.Add($argument) }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $started = $false
    $stdoutCapture = $null
    $stderrCapture = $null
    $timedOut = $false
    $terminationFailure = $null
    [byte[]]$stdoutBytes = @()
    [byte[]]$stderrBytes = @()
    $stdoutOverflow = $false
    $stderrOverflow = $false
    $exitCode = $null
    try {
        if (-not $process.Start()) { throw "Could not start '$FilePath'." }
        $started = $true
        $stdoutCapture = [Retvrn99.PresentationProof.BoundedCapture]::Start(
            $process.StandardOutput.BaseStream,
            $MaximumStdoutBytes
        )
        $stderrCapture = [Retvrn99.PresentationProof.BoundedCapture]::Start(
            $process.StandardError.BaseStream,
            $MaximumStderrBytes
        )
        $timedOut = -not $process.WaitForExit($TimeoutMilliseconds)
        if ($timedOut) {
            try {
                $process.Kill($true)
                if (-not $process.WaitForExit(10000)) {
                    $terminationFailure = "Timed-out process '$FilePath' did not exit after termination."
                }
            }
            catch {
                $terminationFailure = "Timed-out process '$FilePath' could not be terminated: $($_.Exception.Message)"
            }
        }
    }
    finally {
        if ($started) {
            if ($process.HasExited) {
                $process.WaitForExit()
                $null = $stdoutCapture.Completion.GetAwaiter().GetResult()
                $null = $stderrCapture.Completion.GetAwaiter().GetResult()
                $exitCode = $process.ExitCode
            }
            $stdoutBytes = $stdoutCapture.Snapshot([ref]$stdoutOverflow)
            $stderrBytes = $stderrCapture.Snapshot([ref]$stderrOverflow)
            Write-PresentationProofNewBytes -Path $StdoutPath -Bytes $stdoutBytes
            Write-PresentationProofNewBytes -Path $StderrPath -Bytes $stderrBytes
        }
        $process.Dispose()
    }
    if ($null -ne $terminationFailure) { throw $terminationFailure }
    if ($stdoutOverflow -or $stderrOverflow) {
        throw 'The process exceeded its bounded stdout or stderr evidence size.'
    }
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    try {
        $stdout = $utf8.GetString($stdoutBytes)
        $stderr = $utf8.GetString($stderrBytes)
    }
    catch {
        throw 'The process emitted invalid UTF-8 output.'
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        TimedOut = $timedOut
        Stdout = $stdout
        Stderr = $stderr
        StdoutBytes = [UInt64]$stdoutBytes.Length
        StderrBytes = [UInt64]$stderrBytes.Length
    }
}

function Get-PresentationProofP95Limit {
    param([int]$Width, [int]$Height)

    if ($Width -eq 1024 -and $Height -eq 768) { return [UInt64]4000000 }
    if ($Width -eq 1920 -and $Height -eq 1080) { return [UInt64]8000000 }
    throw 'Only the 1024x768 and 1920x1080 reference extents are supported.'
}

function Get-PresentationProofUInt64 {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string]$Label
    )

    Assert-GswJsonInteger -Value $Value -Label $Label
    if ([decimal]$Value -lt 0) { throw "$Label must be nonnegative." }
    try { return [UInt64]$Value } catch { throw "$Label exceeds the UInt64 bound." }
}

function Get-PresentationProofTimingSummary {
    param([Parameter(Mandatory = $true)][UInt64[]]$Values)

    if ($Values.Count -eq 0) { throw 'Timing samples must not be empty.' }
    $ordered = @($Values | Sort-Object)
    $index = {
        param([int]$Percentile)
        return [int](($ordered.Count * $Percentile + 99) / 100) - 1
    }
    return [pscustomobject][ordered]@{
        p50_ns = [UInt64]$ordered[(& $index 50)]
        p95_ns = [UInt64]$ordered[(& $index 95)]
        p99_ns = [UInt64]$ordered[(& $index 99)]
        max_ns = [UInt64]$ordered[$ordered.Count - 1]
    }
}

function Assert-PresentationProofTimingSummary {
    param(
        [Parameter(Mandatory = $true)][object]$Actual,
        [Parameter(Mandatory = $true)][UInt64[]]$Values,
        [Parameter(Mandatory = $true)][string]$Label
    )

    Assert-GswJsonExactProperties -Value $Actual `
        -Expected $script:PresentationProofTimingFields -Label $Label
    $expected = Get-PresentationProofTimingSummary -Values $Values
    foreach ($field in $script:PresentationProofTimingFields) {
        $value = Get-PresentationProofUInt64 -Value $Actual.$field -Label "$Label.$field"
        if ($value -ne [UInt64]$expected.$field) {
            throw "$Label does not match the retained samples."
        }
    }
    return $expected
}

function Assert-PresentationProofResult {
    param(
        [Parameter(Mandatory = $true)][string]$Json,
        [Parameter(Mandatory = $true)][int]$Width,
        [Parameter(Mandatory = $true)][int]$Height,
        [Parameter(Mandatory = $true)][int]$WarmupSeconds,
        [Parameter(Mandatory = $true)][int]$StableSeconds
    )

    $limit = Get-PresentationProofP95Limit -Width $Width -Height $Height
    $result = ConvertFrom-GswStrictJson -Json $Json -Source 'presentation proof result'
    Assert-GswJsonExactProperties -Value $result `
        -Expected $script:PresentationProofTopFields -Label 'presentation proof result'
    foreach ($field in @('tool', 'proof_scope', 'synthetic_source', 'presentation_path',
        'host_presentation_metric', 'failure')) {
        Assert-GswJsonString -Value $result.$field -Label "result.$field"
    }
    foreach ($field in @('vsync', 'sample_overflow', 'stable_host_metrics_valid', 'gate_pass')) {
        Assert-GswJsonBoolean -Value $result.$field -Label "result.$field"
    }
    Assert-GswJsonArray -Value $result.samples -Label 'result.samples'
    foreach ($field in @('schema', 'target_hz', 'minimum_fps_milli',
        'host_presentation_p95_limit_ns', 'width', 'height', 'warmup_seconds',
        'stable_seconds', 'output_width', 'output_height', 'warmup_presented',
        'stable_attempted', 'stable_presented', 'stable_skipped_slots',
        'stable_elapsed_ns', 'presented_fps_milli', 'sample_count', 'sample_capacity')) {
        $null = Get-PresentationProofUInt64 -Value $result.$field -Label "result.$field"
    }

    $expectedPath = 'host_presentation_admit_gsw>host_presentation_stage_gsw_snapshot>' +
        'host_presentation_commit_gsw_snapshot_staged>host_render_guest>SDL_RenderPresent'
    if ([UInt64]$result.schema -ne 1 -or
        [string]$result.tool -cne 'retvrn99-presentation-60hz-proof' -or
        [string]$result.proof_scope -cne 'synthetic host presentation/upload/render/present only' -or
        [string]$result.synthetic_source -cne 'GSW2D snapshot with moving 64x64 dirty region' -or
        [string]$result.presentation_path -cne $expectedPath -or
        [UInt64]$result.target_hz -ne 60 -or [UInt64]$result.minimum_fps_milli -ne 55000 -or
        [string]$result.host_presentation_metric -cne 'pipeline_ns' -or
        [UInt64]$result.host_presentation_p95_limit_ns -ne $limit -or
        [UInt64]$result.width -ne [UInt64]$Width -or [UInt64]$result.height -ne [UInt64]$Height -or
        [UInt64]$result.warmup_seconds -ne [UInt64]$WarmupSeconds -or
        [UInt64]$result.stable_seconds -ne [UInt64]$StableSeconds -or
        [UInt64]$result.output_width -ne [UInt64]$Width -or
        [UInt64]$result.output_height -ne [UInt64]$Height -or
        $result.vsync -cne $true -or $result.sample_overflow -cne $false -or
        $result.stable_host_metrics_valid -cne $true -or $result.gate_pass -cne $true -or
        [string]$result.failure -cne 'none') {
        throw 'The presentation proof identity or fixed gate fields are invalid.'
    }

    [UInt64]$warmupPresented = $result.warmup_presented
    [UInt64]$attempted = $result.stable_attempted
    [UInt64]$presented = $result.stable_presented
    [UInt64]$skipped = $result.stable_skipped_slots
    [UInt64]$elapsed = $result.stable_elapsed_ns
    [UInt64]$reportedFps = $result.presented_fps_milli
    [UInt64]$sampleCount = $result.sample_count
    [UInt64]$capacity = $result.sample_capacity
    [UInt64]$stableSlots = [UInt64]$StableSeconds * 60
    if ($warmupPresented -eq 0 -or $warmupPresented -gt ([UInt64]$WarmupSeconds * 60) -or
        $attempted -eq 0 -or $attempted -ne $presented -or
        $presented -ne $sampleCount -or $sampleCount -gt $capacity -or
        $capacity -ne 4096 -or $presented -gt $stableSlots -or
        $presented -gt [UInt64]::MaxValue - $skipped -or
        $presented + $skipped -ne $stableSlots -or
        @($result.samples).Count -ne [int]$sampleCount -or
        $elapsed -lt ([UInt64]$StableSeconds * 1000000000)) {
        throw 'The presentation proof count, duration, or capacity accounting is invalid.'
    }
    $fps = [UInt64](([Numerics.BigInteger]$presented * 1000000000000) /
        [Numerics.BigInteger]$elapsed)
    if ($reportedFps -ne $fps -or $fps -lt 55000) {
        throw 'The presentation proof rate is below or inconsistent with the fixed gate.'
    }

    $pipelineValues = [Collections.Generic.List[UInt64]]::new()
    $presentValues = [Collections.Generic.List[UInt64]]::new()
    [UInt64]$nextSlot = 0
    [UInt64]$totalSkipped = 0
    for ($index = 0; $index -lt [int]$sampleCount; $index += 1) {
        $sample = @($result.samples)[$index]
        $label = "result.samples[$index]"
        Assert-GswJsonExactProperties -Value $sample `
            -Expected $script:PresentationProofSampleFields -Label $label
        $values = [ordered]@{}
        foreach ($field in $script:PresentationProofSampleFields) {
            $values[$field] = Get-PresentationProofUInt64 -Value $sample.$field `
                -Label "$label.$field"
        }
        if ($values.index -ne [UInt64]$index -or
            $values.skipped_before -gt [UInt64]::MaxValue - $nextSlot -or
            $values.slot -ne $nextSlot + $values.skipped_before -or
            $values.slot -ge $stableSlots) {
            throw "$label has invalid cadence accounting."
        }
        [UInt64]$scheduled = ([Numerics.BigInteger]$values.slot * 1000000000) / 60
        if ($values.scheduled_offset_ns -ne $scheduled -or
            $values.started_offset_ns -lt $scheduled -or
            $values.completed_offset_ns -lt $values.started_offset_ns -or
            $values.completed_offset_ns -gt $elapsed -or
            $values.pipeline_ns -ne $values.completed_offset_ns - $values.started_offset_ns -or
            $values.present_ns -gt $values.pipeline_ns) {
            throw "$label has invalid timing accounting."
        }
        if ($totalSkipped -gt [UInt64]::MaxValue - $values.skipped_before) {
            throw "$label overflows skipped-slot accounting."
        }
        $totalSkipped += $values.skipped_before
        $nextSlot = $values.slot + 1
        $pipelineValues.Add($values.pipeline_ns)
        $presentValues.Add($values.present_ns)
    }
    [UInt64]$trailingSkipped = $stableSlots - $nextSlot
    if ($totalSkipped -gt [UInt64]::MaxValue - $trailingSkipped -or
        $totalSkipped + $trailingSkipped -ne $skipped) {
        throw 'The stable skipped-slot total does not match the retained samples.'
    }

    $pipelineSummary = Assert-PresentationProofTimingSummary -Actual $result.pipeline_timing `
        -Values $pipelineValues.ToArray() -Label 'result.pipeline_timing'
    $null = Assert-PresentationProofTimingSummary -Actual $result.present_timing `
        -Values $presentValues.ToArray() -Label 'result.present_timing'
    if ([UInt64]$pipelineSummary.p95_ns -ge $limit) {
        throw 'The host presentation pipeline p95 does not meet the strict reference-host gate.'
    }

    $metrics = $result.stable_host_metrics
    Assert-GswJsonExactProperties -Value $metrics `
        -Expected $script:PresentationProofMetricFields -Label 'result.stable_host_metrics'
    $metricValues = [ordered]@{}
    foreach ($field in $script:PresentationProofMetricFields) {
        $metricValues[$field] = Get-PresentationProofUInt64 -Value $metrics.$field `
            -Label "result.stable_host_metrics.$field"
    }
    [UInt64]$expectedUploadBytes = $presented * 64 * 64 * 4
    foreach ($field in $script:PresentationProofMetricFields) {
        [UInt64]$expected = 0
        if ($field -ceq 'gsw_snapshot_partial_updates' -or
            $field -ceq 'upload_regions' -or $field -ceq 'resource_reuses') {
            $expected = $presented
        }
        elseif ($field -ceq 'upload_bytes') {
            $expected = $expectedUploadBytes
        }
        if ($metricValues[$field] -ne $expected) {
            throw "result.stable_host_metrics.$field violates the stable-path invariant."
        }
    }
    return $result
}

function Get-PresentationProofArtifactInventory {
    param(
        [Parameter(Mandatory = $true)][string]$EvidenceRoot,
        [string[]]$Exclude = @()
    )

    $records = foreach ($file in Get-ChildItem -LiteralPath $EvidenceRoot -Force -File |
        Sort-Object Name) {
        if ($file.Name -in $Exclude) { continue }
        Get-PresentationProofFileRecord -Path $file.FullName -DisplayPath $file.Name
    }
    return @($records)
}
