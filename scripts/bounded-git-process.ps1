# SPDX-License-Identifier: GPL-3.0-only

Set-StrictMode -Version Latest

function Stop-GswBoundedProcessTree {
    param(
        [Parameter(Mandatory = $true)][Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)][string]$Name,
        [ValidateRange(1, 5000)][int]$GraceMilliseconds = 5000
    )

    if ($Process.HasExited) { return }
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    try { $Process.Kill($true) }
    catch {
        try { $Process.Kill() }
        catch { }
    }
    $remaining = [Math]::Max(
        0,
        $GraceMilliseconds - [int][Math]::Min(
            $stopwatch.ElapsedMilliseconds,
            $GraceMilliseconds
        )
    )
    if ($remaining -gt 0) { [void]$Process.WaitForExit($remaining) }
    if (-not $Process.HasExited) {
        throw "$Name survived process-tree cleanup."
    }
}

function Invoke-GswBoundedProcess {
    param(
        [Parameter(Mandatory = $true)]
        [Diagnostics.ProcessStartInfo]$StartInfo,

        [Parameter(Mandatory = $true)][string]$Name,

        [ValidateRange(1, 30000)][int]$TimeoutMilliseconds = 30000,

        [ValidateRange(1, 536870912)]
        [UInt64]$MaximumStdoutBytes = [UInt64]4194304,

        [ValidateRange(1, 4194304)]
        [UInt64]$MaximumStderrBytes = [UInt64]4194304,

        [scriptblock]$OnStdoutChunk
    )

    if ($StartInfo.UseShellExecute -or
        -not $StartInfo.RedirectStandardOutput -or
        -not $StartInfo.RedirectStandardError) {
        throw "$Name has an unsafe process configuration."
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $StartInfo
    $stdout = if ($null -eq $OnStdoutChunk) { [IO.MemoryStream]::new() } else { $null }
    $stderr = [IO.MemoryStream]::new()
    [byte[]]$stdoutBuffer = [byte[]]::new(8192)
    [byte[]]$stderrBuffer = [byte[]]::new(8192)
    $started = $false
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        try { $started = [bool]$process.Start() }
        catch { throw "$Name did not start." }
        if (-not $started) { throw "$Name did not start." }

        $stdoutDone = $false
        $stderrDone = $false
        [UInt64]$stdoutBytes = 0
        [UInt64]$stderrBytes = 0
        try {
            $stdoutTask = $process.StandardOutput.BaseStream.ReadAsync(
                $stdoutBuffer, 0, $stdoutBuffer.Length
            )
            $stderrTask = $process.StandardError.BaseStream.ReadAsync(
                $stderrBuffer, 0, $stderrBuffer.Length
            )
        }
        catch {
            Stop-GswBoundedProcessTree $process $Name
            throw "$Name failed while opening process output."
        }
        while (-not $stdoutDone -or -not $stderrDone) {
            $remaining = $TimeoutMilliseconds - $stopwatch.ElapsedMilliseconds
            if ($remaining -le 0) {
                Stop-GswBoundedProcessTree $process $Name
                throw "$Name exceeded its process timeout."
            }

            $delay = [Threading.Tasks.Task]::Delay(
                [Math]::Min(50, [int]$remaining)
            )
            [Threading.Tasks.Task[]]$pending = @($delay)
            if (-not $stdoutDone) { $pending += $stdoutTask }
            if (-not $stderrDone) { $pending += $stderrTask }
            [void][Threading.Tasks.Task]::WhenAny(
                $pending
            ).GetAwaiter().GetResult()

            if (-not $stdoutDone -and $stdoutTask.IsCompleted) {
                try { $read = $stdoutTask.GetAwaiter().GetResult() }
                catch {
                    Stop-GswBoundedProcessTree $process $Name
                    throw "$Name failed while reading standard output."
                }
                if ($read -eq 0) { $stdoutDone = $true }
                else {
                    if ($stdoutBytes + [UInt64]$read -gt $MaximumStdoutBytes) {
                        Stop-GswBoundedProcessTree $process $Name
                        throw "$Name exceeded its standard-output bound."
                    }
                    $stdoutBytes += [UInt64]$read
                    if ($null -eq $OnStdoutChunk) {
                        $stdout.Write($stdoutBuffer, 0, $read)
                    }
                    else {
                        $null = & $OnStdoutChunk $stdoutBuffer $read
                    }
                    try {
                        $stdoutTask = $process.StandardOutput.BaseStream.ReadAsync(
                            $stdoutBuffer, 0, $stdoutBuffer.Length
                        )
                    }
                    catch {
                        Stop-GswBoundedProcessTree $process $Name
                        throw "$Name failed while reading standard output."
                    }
                }
            }
            if (-not $stderrDone -and $stderrTask.IsCompleted) {
                try { $read = $stderrTask.GetAwaiter().GetResult() }
                catch {
                    Stop-GswBoundedProcessTree $process $Name
                    throw "$Name failed while reading standard error."
                }
                if ($read -eq 0) { $stderrDone = $true }
                else {
                    if ($stderrBytes + [UInt64]$read -gt $MaximumStderrBytes) {
                        Stop-GswBoundedProcessTree $process $Name
                        throw "$Name exceeded its standard-error bound."
                    }
                    $stderrBytes += [UInt64]$read
                    $stderr.Write($stderrBuffer, 0, $read)
                    try {
                        $stderrTask = $process.StandardError.BaseStream.ReadAsync(
                            $stderrBuffer, 0, $stderrBuffer.Length
                        )
                    }
                    catch {
                        Stop-GswBoundedProcessTree $process $Name
                        throw "$Name failed while reading standard error."
                    }
                }
            }
        }

        $remaining = $TimeoutMilliseconds - $stopwatch.ElapsedMilliseconds
        $exited = $false
        if ($remaining -gt 0) {
            try {
                $exited = $process.WaitForExit([Math]::Max(1, [int]$remaining))
            }
            catch {
                Stop-GswBoundedProcessTree $process $Name
                throw "$Name failed while waiting for process exit."
            }
        }
        if (-not $exited) {
            Stop-GswBoundedProcessTree $process $Name
            throw "$Name exceeded its process timeout."
        }
        [byte[]]$stdoutResult = [byte[]]::new(0)
        if ($null -ne $stdout) { $stdoutResult = $stdout.ToArray() }
        [byte[]]$stderrResult = $stderr.ToArray()
        return [pscustomobject][ordered]@{
            stdout = $stdoutResult
            stderr = $stderrResult
            stdout_bytes = $stdoutBytes
            stderr_bytes = $stderrBytes
            exit_code = [int]$process.ExitCode
        }
    }
    finally {
        if ($started -and -not $process.HasExited) {
            Stop-GswBoundedProcessTree $process $Name
        }
        if ($null -ne $stdout) { $stdout.Dispose() }
        $stderr.Dispose()
        $stopwatch.Stop()
        $process.Dispose()
    }
}
