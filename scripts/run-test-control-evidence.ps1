# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RunRoot,
    [Parameter(Mandatory = $true)][string]$ControlHost,
    [Parameter(Mandatory = $true)][string]$ProfileRoot,
    [Parameter(Mandatory = $true)][string]$ControlScript,
    [Parameter(Mandatory = $true)][string]$CapturePlan,
    [Parameter(Mandatory = $true)][string]$EvidenceDirectory,
    [Parameter(Mandatory = $true)][ValidateRange(10, 900)][int]$AutoCloseSeconds,
    [Parameter(Mandatory = $true)][ValidateRange(11, 960)][int]$ExitTimeoutSeconds,
    [ValidateRange(1, 30)][int]$GracefulShutdownSeconds = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'test-control-evidence-support.ps1')

function Initialize-TestControlCaptureNative {
    if ($null -ne ('Retvrn99.TestControlCapture.Native' -as [type])) { return }
    try {
        Add-Type -AssemblyName System.Drawing.Common -ErrorAction Stop
    }
    catch {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    }
    $drawingAssembly = [Drawing.Bitmap].Assembly
    $captureAssemblies = @($drawingAssembly.Location)
    foreach ($reference in $drawingAssembly.GetReferencedAssemblies()) {
        $location = [Reflection.Assembly]::Load($reference).Location
        if (-not [string]::IsNullOrEmpty($location)) { $captureAssemblies += $location }
    }
    $captureAssemblies = @($captureAssemblies | Sort-Object -Unique)
    Add-Type -ReferencedAssemblies $captureAssemblies -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading.Tasks;

namespace Retvrn99.TestControlCapture {
    public sealed class CaptureResult {
        public int Width { get; set; }
        public int Height { get; set; }
        public byte[] Png { get; set; }
    }

    public static class Native {
        [StructLayout(LayoutKind.Sequential)]
        public struct Rect {
            public int Left;
            public int Top;
            public int Right;
            public int Bottom;
        }

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool PrintWindow(IntPtr window, IntPtr target, uint flags);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GetWindowRect(IntPtr window, out Rect rect);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool IsWindowVisible(IntPtr window);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool IsIconic(IntPtr window);

        public static Task<CaptureResult> CapturePngAsync(IntPtr window) {
            return Task.Run(() => CapturePng(window));
        }

        private static CaptureResult CapturePng(IntPtr window) {
            if (window == IntPtr.Zero || !IsWindowVisible(window) || IsIconic(window)) {
                throw new InvalidOperationException("The control-host window is not visibly capturable.");
            }
            Rect rect;
            if (!GetWindowRect(window, out rect)) {
                throw new InvalidOperationException(
                    String.Format("GetWindowRect failed with Win32 error {0}.", Marshal.GetLastWin32Error())
                );
            }
            int width = rect.Right - rect.Left;
            int height = rect.Bottom - rect.Top;
            if (width <= 0 || height <= 0 || width > 16384 || height > 16384 ||
                (long)width * (long)height > 100000000L) {
                throw new InvalidOperationException(
                    String.Format("The control-host window has invalid capture dimensions {0}x{1}.", width, height)
                );
            }
            using (Bitmap bitmap = new Bitmap(width, height, PixelFormat.Format32bppRgb))
            using (Graphics graphics = Graphics.FromImage(bitmap)) {
                IntPtr device = graphics.GetHdc();
                try {
                    if (!PrintWindow(window, device, 2)) {
                        throw new InvalidOperationException(
                            String.Format("PrintWindow failed with Win32 error {0}.", Marshal.GetLastWin32Error())
                        );
                    }
                }
                finally {
                    graphics.ReleaseHdc(device);
                }
                using (MemoryStream output = new MemoryStream()) {
                    bitmap.Save(output, ImageFormat.Png);
                    return new CaptureResult {
                        Width = width,
                        Height = height,
                        Png = output.ToArray()
                    };
                }
            }
        }
    }
}
'@
}

function Initialize-TestControlOutputCollector {
    if ($null -ne ('Retvrn99.TestControlOutput.BoundedUtf8LineCollector' -as [type])) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Tasks;

namespace Retvrn99.TestControlOutput {
    public sealed class LineRecord {
        public long LineIndex { get; internal set; }
        public long ReceivedMilliseconds { get; internal set; }
        public long Utf8Bytes { get; internal set; }
        public string Sha256 { get; internal set; }
    }

    public sealed class OutputSnapshot {
        public byte[] Bytes { get; internal set; }
        public LineRecord[] Lines { get; internal set; }
        public bool Completed { get; internal set; }
        public bool Overflowed { get; internal set; }
        public string Failure { get; internal set; }
        public long MaximumBytes { get; internal set; }
    }

    public sealed class BoundedUtf8LineCollector {
        private static readonly UTF8Encoding StrictUtf8 = new UTF8Encoding(false, true);
        private readonly object gate = new object();
        private readonly Stopwatch clock;
        private readonly long maximumBytes;
        private readonly MemoryStream output = new MemoryStream();
        private readonly MemoryStream currentLine = new MemoryStream();
        private readonly List<LineRecord> lines = new List<LineRecord>();
        private Task drainTask;
        private long previousReceivedMilliseconds;
        private bool discard;
        private bool completed;
        private bool overflowed;
        private string failure;

        private BoundedUtf8LineCollector(Stopwatch clock, long maximumBytes) {
            if (clock == null) { throw new ArgumentNullException("clock"); }
            if (maximumBytes < 1) { throw new ArgumentOutOfRangeException("maximumBytes"); }
            this.clock = clock;
            this.maximumBytes = maximumBytes;
        }

        public Stopwatch Clock { get { return clock; } }

        public static BoundedUtf8LineCollector Start(
            Stream stream,
            Stopwatch clock,
            long maximumBytes
        ) {
            if (stream == null) { throw new ArgumentNullException("stream"); }
            BoundedUtf8LineCollector collector =
                new BoundedUtf8LineCollector(clock, maximumBytes);
            collector.drainTask = collector.DrainAsync(stream);
            return collector;
        }

        public OutputSnapshot Snapshot() {
            lock (gate) {
                return new OutputSnapshot {
                    Bytes = output.ToArray(),
                    Lines = lines.ToArray(),
                    Completed = completed,
                    Overflowed = overflowed,
                    Failure = failure,
                    MaximumBytes = maximumBytes
                };
            }
        }

        public OutputSnapshot Complete() {
            drainTask.GetAwaiter().GetResult();
            return Snapshot();
        }

        private async Task DrainAsync(Stream stream) {
            byte[] buffer = new byte[8192];
            try {
                for (;;) {
                    int count = await stream.ReadAsync(buffer, 0, buffer.Length).ConfigureAwait(false);
                    if (count == 0) { break; }
                    lock (gate) {
                        for (int index = 0; index < count; index += 1) {
                            AcceptByte(buffer[index]);
                        }
                    }
                }
                lock (gate) {
                    if (!discard && currentLine.Length != 0) { CommitLine(); }
                }
            }
            catch (Exception error) {
                lock (gate) {
                    failure = error.Message;
                    discard = true;
                    currentLine.SetLength(0);
                }
            }
            finally {
                lock (gate) { completed = true; }
            }
        }

        private void AcceptByte(byte value) {
            if (discard) { return; }
            if (value == 10) {
                CommitLine();
                return;
            }
            if (output.Length + currentLine.Length + 1 > maximumBytes) {
                overflowed = true;
                discard = true;
                currentLine.SetLength(0);
                return;
            }
            currentLine.WriteByte(value);
        }

        private void CommitLine() {
            byte[] buffer = currentLine.GetBuffer();
            int length = checked((int)currentLine.Length);
            if (length > 0 && buffer[length - 1] == 13) { length -= 1; }
            if (output.Length + length + 1 > maximumBytes) {
                overflowed = true;
                discard = true;
                currentLine.SetLength(0);
                return;
            }
            try {
                StrictUtf8.GetCharCount(buffer, 0, length);
            }
            catch (DecoderFallbackException error) {
                failure = error.Message;
                discard = true;
                currentLine.SetLength(0);
                return;
            }
            long receivedMilliseconds = clock.ElapsedMilliseconds;
            if (receivedMilliseconds < previousReceivedMilliseconds) {
                receivedMilliseconds = previousReceivedMilliseconds;
            }
            previousReceivedMilliseconds = receivedMilliseconds;
            string hash;
            using (SHA256 sha256 = SHA256.Create()) {
                hash = BitConverter.ToString(sha256.ComputeHash(buffer, 0, length))
                    .Replace("-", "").ToLowerInvariant();
            }
            output.Write(buffer, 0, length);
            output.WriteByte(10);
            lines.Add(new LineRecord {
                LineIndex = lines.Count,
                ReceivedMilliseconds = receivedMilliseconds,
                Utf8Bytes = length,
                Sha256 = hash
            });
            currentLine.SetLength(0);
        }
    }
}
'@
}

function Save-TestControlPrintWindowPng {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Window,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateRange(1, 60000)][int]$TimeoutMilliseconds
    )

    $task = [Retvrn99.TestControlCapture.Native]::CapturePngAsync($Window)
    $wait = [Diagnostics.Stopwatch]::StartNew()
    while (-not $task.IsCompleted -and $wait.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
        Start-Sleep -Milliseconds 10
    }
    $wait.Stop()
    if (-not $task.IsCompleted) {
        throw "PrintWindow exceeded its $TimeoutMilliseconds-millisecond capture deadline."
    }
    $capture = $task.GetAwaiter().GetResult()
    if ($null -eq $capture.Png -or $capture.Png.Length -le 8) {
        throw 'PrintWindow produced an empty PNG.'
    }
    Write-TestControlNewBytes -Path $Path -Bytes $capture.Png
    $file = Assert-TestControlOrdinaryPath -Path $Path -Name 'window capture' -Kind File
    if ($file.Length -le 8) { throw 'PrintWindow produced an empty PNG.' }
    $stream = [IO.File]::OpenRead($file.FullName)
    try {
        $signature = New-Object byte[] 8
        if ($stream.Read($signature, 0, $signature.Length) -ne $signature.Length -or
            ([BitConverter]::ToString($signature) -cne '89-50-4E-47-0D-0A-1A-0A')) {
            throw 'PrintWindow did not produce a valid PNG signature.'
        }
    }
    finally {
        $stream.Dispose()
    }
    $decoded = [Drawing.Image]::FromFile($file.FullName)
    try {
        if ($decoded.Width -ne $capture.Width -or $decoded.Height -ne $capture.Height) {
            throw 'The captured PNG dimensions changed during encoding.'
        }
    }
    finally {
        $decoded.Dispose()
    }
    return [pscustomobject]@{
        Width = $capture.Width
        Height = $capture.Height
        Bytes = [UInt64]$file.Length
        Sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Wait-TestControlProcessExit {
    param(
        [Parameter(Mandatory = $true)][Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)][Diagnostics.Stopwatch]$Clock,
        [Parameter(Mandatory = $true)][UInt64]$DeadlineMilliseconds
    )

    while (-not $Process.HasExited -and [UInt64]$Clock.ElapsedMilliseconds -lt $DeadlineMilliseconds) {
        Start-Sleep -Milliseconds 100
        $Process.Refresh()
    }
    return $Process.HasExited
}

function Assert-TestControlStdoutTimelineBinding {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Lines
    )

    $result = @()
    $offset = 0
    for ($index = 0; $index -lt $Lines.Count; $index += 1) {
        $end = $offset
        while ($end -lt $Bytes.Length -and $Bytes[$end] -ne 10) { $end += 1 }
        if ($end -ge $Bytes.Length) {
            throw 'stdout timeline contains a line without its LF byte.'
        }
        $length = $end - $offset
        $lineBytes = New-Object byte[] $length
        if ($length -ne 0) { [Array]::Copy($Bytes, $offset, $lineBytes, 0, $length) }
        $line = $Lines[$index]
        if ([Int64]$line.LineIndex -ne $index -or
            [Int64]$line.Utf8Bytes -ne $length -or
            [string]$line.Sha256 -cne (Get-GswSha256Hex -Bytes $lineBytes)) {
            throw "stdout timeline binding failed at line $index."
        }
        if ($index -gt 0 -and
            [Int64]$line.ReceivedMilliseconds -lt
                [Int64]$Lines[$index - 1].ReceivedMilliseconds) {
            throw 'stdout timeline receipt times are not monotonic.'
        }
        $result += [ordered]@{
            line_index = [UInt64]$index
            received_ms = [UInt64]$line.ReceivedMilliseconds
            utf8_bytes = [UInt64]$length
            sha256 = [string]$line.Sha256
        }
        $offset = $end + 1
    }
    if ($offset -ne $Bytes.Length) {
        throw 'stdout timeline does not bind every stdout.log byte.'
    }
    return $result
}

function Write-TestControlLogsIfComplete {
    param(
        [Diagnostics.Process]$Process,
        [object]$StdoutCollector,
        [object]$StderrCollector,
        [string]$EvidenceRoot
    )

    if ($null -eq $Process -or -not $Process.HasExited -or
        $null -eq $StdoutCollector -or $null -eq $StderrCollector) {
        return $null
    }
    $Process.WaitForExit()
    $stdoutSnapshot = $StdoutCollector.Complete()
    $stderrSnapshot = $StderrCollector.Complete()
    [byte[]]$stdoutBytes = $stdoutSnapshot.Bytes
    [byte[]]$stderrBytes = $stderrSnapshot.Bytes
    $timelineLines = @(Assert-TestControlStdoutTimelineBinding `
        -Bytes $stdoutBytes -Lines @($stdoutSnapshot.Lines))
    $stdoutPath = Join-Path $EvidenceRoot 'stdout.log'
    $stderrPath = Join-Path $EvidenceRoot 'stderr.log'
    $timelinePath = Join-Path $EvidenceRoot 'stdout-timeline.json'
    if (-not (Test-Path -LiteralPath $stdoutPath)) {
        Write-TestControlNewBytes -Path $stdoutPath -Bytes $stdoutBytes
    }
    if (-not (Test-Path -LiteralPath $stderrPath)) {
        Write-TestControlNewBytes -Path $stderrPath -Bytes $stderrBytes
    }
    if (-not (Test-Path -LiteralPath $timelinePath)) {
        Write-TestControlNewJson -Path $timelinePath -Value ([ordered]@{
            _spdx = 'GPL-3.0-only'
            schema = 1
            lines = $timelineLines
        })
    }
    $collectionFailures = @()
    foreach ($entry in @(
        [pscustomobject]@{ Name = 'stdout'; Snapshot = $stdoutSnapshot },
        [pscustomobject]@{ Name = 'stderr'; Snapshot = $stderrSnapshot }
    )) {
        if (-not $entry.Snapshot.Completed) {
            $collectionFailures += "$($entry.Name) collection did not drain completely."
        }
        if ($entry.Snapshot.Overflowed) {
            $collectionFailures += "$($entry.Name) exceeded its bounded output evidence size."
        }
        if (-not [string]::IsNullOrEmpty([string]$entry.Snapshot.Failure)) {
            $collectionFailures += "$($entry.Name) collection failed: $($entry.Snapshot.Failure)"
        }
    }
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    return [pscustomobject]@{
        Stdout = $utf8.GetString($stdoutBytes)
        Stderr = $utf8.GetString($stderrBytes)
        StdoutBytes = [UInt64]$stdoutBytes.Length
        StderrBytes = [UInt64]$stderrBytes.Length
        TimelineLines = [UInt64]$timelineLines.Count
        CollectionFailure = $collectionFailures -join ' '
    }
}

function Get-TestControlArtifactInventory {
    param(
        [Parameter(Mandatory = $true)][string]$EvidenceRoot,
        [string[]]$Exclude = @()
    )

    $result = @()
    foreach ($file in Get-ChildItem -LiteralPath $EvidenceRoot -Force -File |
        Sort-Object Name) {
        if ($file.Name -in $Exclude) { continue }
        $result += [ordered]@{
            path = $file.Name
            bytes = [UInt64]$file.Length
            sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    return $result
}

function Get-TestControlBinaryInventory {
    param(
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [Parameter(Mandatory = $true)][string[]]$Paths
    )

    $result = @()
    foreach ($path in $Paths) {
        $item = Assert-TestControlOrdinaryPath -Path $path `
            -Name 'runtime binary' -Kind File
        $result += [ordered]@{
            path = [IO.Path]::GetRelativePath($RunRoot, $item.FullName).Replace('\', '/')
            bytes = [UInt64]$item.Length
            sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    return @($result | Sort-Object path)
}

if (-not [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
    [Runtime.InteropServices.OSPlatform]::Windows
)) {
    throw 'The test-control evidence runner requires Windows.'
}
if ($ExitTimeoutSeconds -le $AutoCloseSeconds -or
    $ExitTimeoutSeconds -gt $AutoCloseSeconds + 60) {
    throw 'ExitTimeoutSeconds must be greater than AutoCloseSeconds and at most 60 seconds later.'
}

$run = Get-TestControlFullPath -Path $RunRoot -Name 'run root'
$null = Assert-TestControlOrdinaryPath -Path $run -Name 'run root' -Kind Directory
if ($run.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar).Equals(
    [IO.Path]::GetPathRoot($run).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    ),
    (Get-TestControlPathComparison)
)) {
    throw 'The run root must not be a filesystem root.'
}
$hostPath = Assert-TestControlContainedPath -Root $run -Path $ControlHost `
    -Name 'control host'
$hostItem = Assert-TestControlOrdinaryPath -Path $hostPath -Name 'control host' -Kind File
if ($hostItem.Name -cne 'retvrn99-control.exe') {
    throw 'The control host must be named retvrn99-control.exe.'
}
$buildRoot = $hostItem.DirectoryName
$helperPath = Assert-TestControlContainedPath -Root $run `
    -Path (Join-Path $buildRoot 'retvrn99-fat32.exe') -Name 'FAT32 helper'
$sdlPath = Assert-TestControlContainedPath -Root $run `
    -Path (Join-Path $buildRoot 'SDL3.dll') -Name 'SDL3 runtime'
$null = Assert-TestControlOrdinaryPath -Path $helperPath -Name 'FAT32 helper' -Kind File
$null = Assert-TestControlOrdinaryPath -Path $sdlPath -Name 'SDL3 runtime' -Kind File

$profileState = Assert-TestControlProfileBinding -RunRoot $run -ProfileRoot $ProfileRoot
$controlPath = Assert-TestControlContainedPath -Root $run -Path $ControlScript `
    -Name 'control script'
$planPath = Assert-TestControlContainedPath -Root $run -Path $CapturePlan `
    -Name 'capture plan'
if ($controlPath.Equals($planPath, (Get-TestControlPathComparison))) {
    throw 'The control script and capture plan must be different files.'
}
$evidence = Assert-TestControlAbsentLeaf -Root $run -Path $EvidenceDirectory `
    -Name 'evidence directory'
if ($evidence.StartsWith(
    $profileState.ProfileRoot + [IO.Path]::DirectorySeparatorChar,
    (Get-TestControlPathComparison)
)) {
    throw 'The evidence directory must not be inside the Profile.'
}
Assert-NoTestControlRuntimeProcess

$heldControl = $null
$heldPlan = $null
$process = $null
$stdoutCollector = $null
$stderrCollector = $null
$clock = $null
$evidenceCreated = $false
$completed = $false
$captureResults = @()
$logs = $null

try {
    $heldControl = Open-TestControlHeldFile -Path $controlPath `
        -Name 'control script' -MaximumBytes 65536
    $heldPlan = Open-TestControlHeldFile -Path $planPath `
        -Name 'capture plan' -MaximumBytes 65536
    $captures = @(ConvertFrom-TestControlCapturePlan -Bytes $heldPlan.Bytes `
        -AutoCloseMilliseconds ([UInt64]$AutoCloseSeconds * 1000))
    $preProfile = @(Get-TestControlFileInventory -Root $profileState.ProfileRoot `
        -Name 'Profile root')
    $binaryState = @(Get-TestControlBinaryInventory -RunRoot $run `
        -Paths @($hostPath, $helperPath, $sdlPath))

    New-Item -ItemType Directory -Path $evidence -ErrorAction Stop | Out-Null
    $evidenceCreated = $true
    $null = Assert-TestControlOrdinaryPath -Path $evidence `
        -Name 'evidence directory' -Kind Directory
    Assert-TestControlHeldFileUnchanged -Held $heldControl
    Assert-TestControlHeldFileUnchanged -Held $heldPlan
    $profileState = Assert-TestControlProfileBinding -RunRoot $run `
        -ProfileRoot $profileState.ProfileRoot
    $preProfileRecheck = @(Get-TestControlFileInventory `
        -Root $profileState.ProfileRoot -Name 'Profile root')
    Assert-TestControlInventoryEqual -Expected $preProfile -Actual $preProfileRecheck `
        -Name 'pre-launch Profile'
    $binaryRecheck = @(Get-TestControlBinaryInventory -RunRoot $run `
        -Paths @($hostPath, $helperPath, $sdlPath))
    Assert-TestControlInventoryEqual -Expected $binaryState -Actual $binaryRecheck `
        -Name 'runtime binary'
    Assert-NoTestControlRuntimeProcess

    Write-TestControlNewBytes -Path (Join-Path $evidence 'control-script.input') `
        -Bytes $heldControl.Bytes
    Write-TestControlNewBytes -Path (Join-Path $evidence 'capture-plan.json') `
        -Bytes $heldPlan.Bytes
    $preState = [ordered]@{
        _spdx = 'GPL-3.0-only'
        schema = 1
        phase = 'pre-launch'
        recorded_utc = [DateTime]::UtcNow.ToString('O')
        profile = $preProfile
        binaries = $binaryState
        immutable_inputs = @(
            [ordered]@{
                name = 'control-script.input'
                bytes = $heldControl.Length
                sha256 = $heldControl.Sha256
            },
            [ordered]@{
                name = 'capture-plan.json'
                bytes = $heldPlan.Length
                sha256 = $heldPlan.Sha256
            }
        )
        profile_lock_absent = $true
        fat32_companion_absent = $true
        runtime_process_absent = $true
    }
    Write-TestControlNewJson -Path (Join-Path $evidence 'pre-state.json') `
        -Value $preState

    Initialize-TestControlCaptureNative
    Initialize-TestControlOutputCollector
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    if ($null -eq $startInfo.ArgumentList) {
        throw 'ProcessStartInfo.ArgumentList is unavailable.'
    }
    $startInfo.FileName = $hostPath
    $startInfo.WorkingDirectory = $buildRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $false
    $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Normal
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false, $true)
    $startInfo.StandardErrorEncoding = [Text.UTF8Encoding]::new($false, $true)
    [void]$startInfo.ArgumentList.Add('--start')
    [void]$startInfo.ArgumentList.Add('--graphics-trace')
    [void]$startInfo.ArgumentList.Add("--auto-close:$AutoCloseSeconds")
    [void]$startInfo.ArgumentList.Add("--profile-root:$($profileState.ProfileRoot)")
    [void]$startInfo.ArgumentList.Add("--control-script:$($heldControl.Path)")

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $clock = [Diagnostics.Stopwatch]::StartNew()
    if (-not $process.Start()) { throw 'The control host did not start.' }
    $stdoutCollector = [Retvrn99.TestControlOutput.BoundedUtf8LineCollector]::Start(
        $process.StandardOutput.BaseStream,
        $clock,
        16777216
    )
    $stderrCollector = [Retvrn99.TestControlOutput.BoundedUtf8LineCollector]::Start(
        $process.StandardError.BaseStream,
        $clock,
        1048576
    )
    $launch = [ordered]@{
        _spdx = 'GPL-3.0-only'
        schema = 1
        pid = $process.Id
        started_utc = $process.StartTime.ToUniversalTime().ToString('O')
        visible = $true
        arguments = @(
            '--start',
            '--graphics-trace',
            "--auto-close:$AutoCloseSeconds",
            '--profile-root:<run-root-relative-profile>',
            '--control-script:<held-control-script>'
        )
    }
    Write-TestControlNewJson -Path (Join-Path $evidence 'launch.json') -Value $launch

    foreach ($capture in $captures) {
        while (-not $process.HasExited -and
            [UInt64]$clock.ElapsedMilliseconds -lt $capture.AfterMilliseconds) {
            Start-Sleep -Milliseconds 50
            $process.Refresh()
        }
        if ($process.HasExited) {
            throw "The control host exited before capture '$($capture.Id)'."
        }
        $capturePath = Join-Path $evidence ("capture-$($capture.Id).png")
        $captured = $false
        [UInt64]$capturedAt = 0
        $lastCaptureError = 'No visible window was available.'
        while (-not $captured -and -not $process.HasExited -and
            [UInt64]$clock.ElapsedMilliseconds -le $capture.DeadlineMilliseconds) {
            $process.Refresh()
            try {
                $remaining = [Int64]$capture.DeadlineMilliseconds -
                    [Int64]$clock.ElapsedMilliseconds
                $captureValue = Save-TestControlPrintWindowPng `
                    -Window $process.MainWindowHandle -Path $capturePath `
                    -TimeoutMilliseconds ([int][Math]::Min(
                        [Int64]60000,
                        [Math]::Max([Int64]1, $remaining)
                    ))
                $capturedAt = [UInt64]$clock.ElapsedMilliseconds
                if ($capturedAt -gt $capture.DeadlineMilliseconds) {
                    throw "Capture '$($capture.Id)' completed after its deadline."
                }
                $captured = $true
            }
            catch {
                $lastCaptureError = $_.Exception.Message
                if (Test-Path -LiteralPath $capturePath) {
                    throw "Capture '$($capture.Id)' left an invalid output: $lastCaptureError"
                }
                Start-Sleep -Milliseconds 100
            }
        }
        if (-not $captured) {
            throw "Capture '$($capture.Id)' missed its deadline: $lastCaptureError"
        }
        $captureResults += [ordered]@{
            id = $capture.Id
            after_ms = $capture.AfterMilliseconds
            deadline_ms = $capture.DeadlineMilliseconds
            captured_ms = $capturedAt
            width = $captureValue.Width
            height = $captureValue.Height
            bytes = $captureValue.Bytes
            sha256 = $captureValue.Sha256
            method = 'PrintWindow/PW_RENDERFULLCONTENT'
        }
    }
    Write-TestControlNewJson -Path (Join-Path $evidence 'captures.json') `
        -Value ([ordered]@{
            _spdx = 'GPL-3.0-only'
            schema = 1
            captures = $captureResults
        })

    if (-not (Wait-TestControlProcessExit -Process $process -Clock $clock `
        -DeadlineMilliseconds ([UInt64]$ExitTimeoutSeconds * 1000))) {
        throw "The control host exceeded its $ExitTimeoutSeconds-second exit deadline."
    }
    $logs = Write-TestControlLogsIfComplete -Process $process `
        -StdoutCollector $stdoutCollector -StderrCollector $stderrCollector `
        -EvidenceRoot $evidence
    if (-not [string]::IsNullOrEmpty($logs.CollectionFailure)) {
        throw $logs.CollectionFailure
    }
    if ($process.ExitCode -ne 0) {
        throw "The control host exited with code $($process.ExitCode)."
    }
    if ([UInt64]$clock.ElapsedMilliseconds -lt [UInt64]$AutoCloseSeconds * 1000) {
        throw 'The control host exited before its configured graceful auto-close boundary.'
    }
    if ($logs.StderrBytes -ne 0) {
        throw 'The control host emitted stderr evidence.'
    }

    Assert-TestControlHeldFileUnchanged -Held $heldControl
    Assert-TestControlHeldFileUnchanged -Held $heldPlan
    if (Test-Path -LiteralPath $profileState.LockPath) {
        throw 'The Profile lock remained after control-host exit.'
    }
    if (Test-Path -LiteralPath $profileState.CompanionPath) {
        throw 'The FAT32 companion remained after control-host exit.'
    }
    Wait-NoTestControlRuntimeProcess -TimeoutMilliseconds 5000
    $postBinaries = @(Get-TestControlBinaryInventory -RunRoot $run `
        -Paths @($hostPath, $helperPath, $sdlPath))
    Assert-TestControlInventoryEqual -Expected $binaryState -Actual $postBinaries `
        -Name 'post-run runtime binary'
    Assert-TestControlOrdinaryTree -Root $profileState.ProfileRoot -Name 'post-run Profile'
    $postNames = @(Get-ChildItem -LiteralPath $profileState.ProfileRoot -Force -Recurse -File |
        ForEach-Object {
            [IO.Path]::GetRelativePath($profileState.ProfileRoot, $_.FullName).Replace('\', '/')
        } | Sort-Object)
    $expectedPostNames = @($script:TestControlProfileFiles + 'graphics-postmortem.json' |
        Sort-Object)
    if (($postNames -join "`n") -cne ($expectedPostNames -join "`n")) {
        throw 'The post-run Profile contains an unexpected artifact inventory.'
    }
    $postProfile = @(Get-TestControlFileInventory -Root $profileState.ProfileRoot `
        -Name 'post-run Profile')
    $postmortemSnapshot = Read-GswBoundedFileSnapshot `
        -Path $profileState.PostmortemPath -Name 'graphics postmortem' `
        -MaximumBytes 98304
    $postmortem = Save-TestControlValidatedPostmortem `
        -Bytes $postmortemSnapshot.Bytes -ProcessId $process.Id `
        -EvidenceRoot $evidence
    $telemetry = Assert-TestControlTelemetry -Stdout $logs.Stdout

    $postState = [ordered]@{
        _spdx = 'GPL-3.0-only'
        schema = 1
        phase = 'post-exit'
        recorded_utc = [DateTime]::UtcNow.ToString('O')
        pid = $process.Id
        exit_code = $process.ExitCode
        elapsed_ms = [UInt64]$clock.ElapsedMilliseconds
        profile = $postProfile
        binaries = $postBinaries
        profile_lock_absent = $true
        fat32_companion_absent = $true
        runtime_process_absent = $true
        postmortem_session = $postmortem.Session
        postmortem_revision = $postmortem.Revision
        control_actions = $telemetry.NumericFields.actions
        trace_lines = $telemetry.TraceLines
    }
    Write-TestControlNewJson -Path (Join-Path $evidence 'post-state.json') `
        -Value $postState
    $artifacts = @(Get-TestControlArtifactInventory -EvidenceRoot $evidence)
    $result = [ordered]@{
        _spdx = 'GPL-3.0-only'
        schema = 1
        result = 'pass'
        pid = $process.Id
        exit_code = $process.ExitCode
        postmortem_session = $postmortem.Session
        postmortem_revision = $postmortem.Revision
        telemetry_fields = 26
        trace_lines = $telemetry.TraceLines
        captures = $captureResults.Count
        immutable_control_sha256 = $heldControl.Sha256
        immutable_capture_plan_sha256 = $heldPlan.Sha256
        artifacts = $artifacts
    }
    Write-TestControlNewJson -Path (Join-Path $evidence 'result.json') -Value $result
    $completed = $true
    Write-Output (
        "PASS test-control evidence pid=$($process.Id) captures=$($captureResults.Count) " +
        "revision=$($postmortem.Revision) artifacts=$($artifacts.Count)"
    )
}
catch {
    $failure = $_
    $cleanupMessages = @()
    if ($null -ne $process) {
        try {
            if (-not $process.HasExited) {
                $closeRequested = $process.CloseMainWindow()
                if ($closeRequested) {
                    if (-not $process.WaitForExit($GracefulShutdownSeconds * 1000)) {
                        $cleanupMessages += 'The control host remained active after CloseMainWindow.'
                    }
                }
                else {
                    $cleanupMessages += 'The control host had no graceful close target.'
                }
            }
            if ($process.HasExited) {
                $logs = Write-TestControlLogsIfComplete -Process $process `
                    -StdoutCollector $stdoutCollector -StderrCollector $stderrCollector `
                    -EvidenceRoot $evidence
            }
        }
        catch {
            $cleanupMessages += "Log or graceful-exit collection failed: $($_.Exception.Message)"
        }
    }
    if ($evidenceCreated) {
        try {
            if ($captureResults.Count -gt 0 -and
                -not (Test-Path -LiteralPath (Join-Path $evidence 'captures.json'))) {
                Write-TestControlNewJson -Path (Join-Path $evidence 'captures.partial.json') `
                    -Value ([ordered]@{
                        _spdx = 'GPL-3.0-only'
                        schema = 1
                        captures = $captureResults
                    })
            }
            $active = @(Get-TestControlRuntimeProcesses | ForEach-Object {
                [ordered]@{ name = $_.ProcessName; pid = $_.Id }
            })
            $failureValue = [ordered]@{
                _spdx = 'GPL-3.0-only'
                schema = 1
                result = 'fail'
                recorded_utc = [DateTime]::UtcNow.ToString('O')
                message = $failure.Exception.Message
                pid = $null -eq $process ? $null : $process.Id
                process_exited = $null -ne $process -and $process.HasExited
                exit_code = if ($null -ne $process -and $process.HasExited) {
                    $process.ExitCode
                } else { $null }
                cleanup = $cleanupMessages
                active_runtime_processes = $active
            }
            Write-TestControlNewJson -Path (Join-Path $evidence 'failure.json') `
                -Value $failureValue
            $partial = @(Get-TestControlArtifactInventory -EvidenceRoot $evidence `
                -Exclude @('partial-artifact-hashes.json'))
            Write-TestControlNewJson `
                -Path (Join-Path $evidence 'partial-artifact-hashes.json') `
                -Value ([ordered]@{
                    _spdx = 'GPL-3.0-only'
                    schema = 1
                    result = 'partial'
                    artifacts = $partial
                })
        }
        catch {
            $cleanupMessages += "Failure evidence finalization failed: $($_.Exception.Message)"
        }
    }
    throw $failure
}
finally {
    if ($null -ne $heldControl) { $heldControl.Stream.Dispose() }
    if ($null -ne $heldPlan) { $heldPlan.Stream.Dispose() }
    if ($null -ne $process) { $process.Dispose() }
    if (-not $completed -and $evidenceCreated) {
        Write-Warning "Partial evidence was retained at '$evidence'."
    }
}
