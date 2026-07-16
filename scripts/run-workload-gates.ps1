# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [string]$ManifestPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\tests\workload-manifest.json'),
    [Alias('DosSeed')]
    [string]$DosSeedPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dev\workloads\dos-seed'),
    [Alias('WorkloadPath')]
    [string]$WorkloadRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dev\workloads'),
    [Alias('ExePath', 'Retvrn99Path')]
    [string]$EmulatorPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'retvrn99.exe'),
    [Alias('OutputPath')]
    [string]$OutputRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dev\workload-gates'),
    [ValidateRange(30, 3600)]
    [int]$TimeoutSeconds = 600,
    [string]$ImageToolPath = '',
    [ValidateRange(1, 64)]
    [int]$ThreadCount = [Environment]::ProcessorCount
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Harness structure and completion identities are adapted from IzarraVM commit
# d930de57acccbc6a70cda8cc5a603173bf23cd1c.

$script:ExitVmBytes = [byte[]](
    0xB0, 0x0C,       # mov al, 0Ch
    0xE6, 0xE4,       # out E4h, al
    0x30, 0xC0,       # xor al, al
    0xE6, 0xE5,       # out E5h, al
    0xB0, 0x03,       # mov al, 3
    0xE6, 0xE6,       # out E6h, al
    0xB8, 0x01, 0x4C, # mov ax, 4C01h
    0xCD, 0x21        # int 21h
)

function Get-ExitVmBytes {
    return [byte[]]$script:ExitVmBytes.Clone()
}

function Get-FullPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.IndexOfAny([char[]]"`0`r`n") -ge 0) {
        throw "$Label is empty or contains a control character."
    }
    if ([System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($Path)) {
        throw "$Label must be a literal path without wildcard characters: $Path"
    }
    try {
        $full = [IO.Path]::GetFullPath($Path)
    }
    catch {
        throw "$Label is not a valid path: $Path"
    }
    if ($full.StartsWith('\\?\', [StringComparison]::Ordinal) -or
        $full.StartsWith('\\.\', [StringComparison]::Ordinal)) {
        throw "$Label cannot use a Windows device namespace: $Path"
    }
    $pathRoot = [IO.Path]::GetPathRoot($full)
    if ($full.Substring($pathRoot.Length).Contains(':')) {
        throw "$Label cannot address an alternate data stream: $Path"
    }
    return $full
}

function Resolve-ExistingDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $full = Get-FullPath -Path $Path -Label $Label
    if (-not (Test-Path -LiteralPath $full -PathType Container)) {
        throw "$Label directory is missing: $full"
    }
    $item = Get-Item -LiteralPath $full -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Label cannot be a reparse point: $full"
    }
    return $item.FullName
}

function Resolve-ExistingFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $full = Get-FullPath -Path $Path -Label $Label
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        throw "$Label file is missing: $full"
    }
    $item = Get-Item -LiteralPath $full -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Label cannot be a reparse point: $full"
    }
    return $item.FullName
}

function Test-PathWithin {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )
    $candidate = [IO.Path]::GetFullPath($Path).TrimEnd([char[]]'\/')
    $boundary = [IO.Path]::GetFullPath($Root).TrimEnd([char[]]'\/')
    if ([string]::Equals($candidate, $boundary, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    return $candidate.StartsWith($boundary + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-NoReparseTree {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Label
    )
    foreach ($item in Get-ChildItem -LiteralPath $Root -Recurse -Force) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Label contains a reparse point: $($item.FullName)"
        }
    }
}

function Assert-SafeOutputRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string[]]$ProtectedPaths
    )
    $full = Get-FullPath -Path $Path -Label 'Output root'
    $root = [IO.Path]::GetPathRoot($full).TrimEnd([char[]]'\/')
    if ([string]::Equals($full.TrimEnd([char[]]'\/'), $root, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Output root cannot be a filesystem root: $full"
    }
    if (Test-PathWithin -Path $RepositoryRoot -Root $full) {
        throw "Output root cannot contain the repository: $full"
    }
    if (Test-PathWithin -Path $full -Root $RepositoryRoot) {
        $developmentRoot = Join-Path $RepositoryRoot 'dev'
        if (-not (Test-PathWithin -Path $full -Root $developmentRoot)) {
            throw "Repository-local output must be under the excluded dev directory: $full"
        }
    }
    foreach ($protected in $ProtectedPaths) {
        if ((Test-PathWithin -Path $full -Root $protected) -or
            (Test-PathWithin -Path $protected -Root $full)) {
            throw "Output root overlaps protected input path: $protected"
        }
    }
    if (Test-Path -LiteralPath $full) {
        $item = Get-Item -LiteralPath $full -Force
        if (-not $item.PSIsContainer) {
            throw "Output root is not a directory: $full"
        }
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Output root cannot be a reparse point: $full"
        }
    }
    return $full
}

function Test-DosBatchArgument {
    param([Parameter(Mandatory = $true)][string]$Value)
    if ($Value.Length -eq 0 -or $Value.Length -gt 63) { return $false }
    return $Value -notmatch '[\x00-\x20&|<>^%"]'
}

function Read-WorkloadManifest {
    param([Parameter(Mandatory = $true)][string]$Path)
    $resolved = Resolve-ExistingFile -Path $Path -Label 'Workload manifest'
    try {
        $document = Get-Content -LiteralPath $resolved -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw "Workload manifest is not valid JSON: $resolved"
    }
    if ([int]$document.version -ne 1) {
        throw "Unsupported workload manifest version: $($document.version)"
    }
    $rawWorkloads = @($document.workloads)
    if ($rawWorkloads.Count -eq 0) { throw 'Workload manifest has no workloads.' }
    $ids = @{}
    $validated = @()
    foreach ($raw in $rawWorkloads) {
        $id = [string]$raw.id
        if ($id -notmatch '^[a-z0-9][a-z0-9-]{0,63}$' -or $ids.ContainsKey($id)) {
            throw "Invalid or duplicate workload id: $id"
        }
        $ids[$id] = $true
        $executable = [string]$raw.executable
        if ($executable -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,7}(\.[A-Za-z0-9]{1,3})?$' -or
            [IO.Path]::GetFileName($executable) -ne $executable) {
            throw "Workload $id executable must be a safe DOS 8.3 leaf name."
        }
        $arguments = @()
        foreach ($argumentValue in @($raw.arguments)) {
            $argument = [string]$argumentValue
            if (-not (Test-DosBatchArgument -Value $argument)) {
                throw "Workload $id has an unsafe DOS argument: $argument"
            }
            $arguments += $argument
        }
        if ($arguments.Count -gt 32) { throw "Workload $id has too many arguments." }
        $metric = [string]$raw.metric
        if ($metric -ne 'gametics' -and $metric -ne 'frames') {
            throw "Workload $id has an unsupported metric: $metric"
        }
        $expected = [int64]$raw.expected
        if ($expected -le 0) { throw "Workload $id expected metric must be positive." }
        $repetitions = [int]$raw.repetitions
        if ($repetitions -ne 3) { throw "Workload $id must declare exactly 3 repetitions." }
        if ([string]$raw.semantic_exit -ne 'test_device') {
            throw "Workload $id must use the test_device semantic exit."
        }
        $declaredHash = ([string]$raw.executable_sha256).ToLowerInvariant()
        if ($declaredHash.Length -ne 0 -and $declaredHash -notmatch '^[0-9a-f]{64}$') {
            throw "Workload $id executable_sha256 is invalid."
        }
        $validated += [pscustomobject]@{
            id = $id
            executable = $executable
            arguments = [string[]]$arguments
            executable_sha256 = $declaredHash
            metric = $metric
            expected = $expected
            repetitions = $repetitions
            semantic_exit = 'test_device'
        }
    }
    return [pscustomobject]@{ version = 1; path = $resolved; workloads = $validated }
}

function Get-Sha256Hex {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $algorithm.Dispose()
    }
}

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-FixtureTreeHash {
    param([Parameter(Mandatory = $true)][string]$Root)
    Assert-NoReparseTree -Root $Root -Label 'Fixture tree'
    $files = @(Get-ChildItem -LiteralPath $Root -File -Recurse -Force | Sort-Object FullName)
    $builder = New-Object Text.StringBuilder
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($Root.TrimEnd([char[]]'\/').Length).TrimStart([char[]]'\/').Replace('\', '/')
        [void]$builder.Append($relative.ToLowerInvariant())
        [void]$builder.Append("`0")
        [void]$builder.Append((Get-FileSha256 -Path $file.FullName))
        [void]$builder.Append("`n")
    }
    $encoding = New-Object Text.UTF8Encoding($false)
    return [pscustomobject]@{
        sha256 = Get-Sha256Hex -Bytes $encoding.GetBytes($builder.ToString())
        file_count = $files.Count
    }
}

function Copy-TreeWithoutOverwrite {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    Assert-NoReparseTree -Root $Source -Label 'Staging source'
    foreach ($item in Get-ChildItem -LiteralPath $Source -Recurse -Force | Sort-Object FullName) {
        $relative = $item.FullName.Substring($Source.TrimEnd([char[]]'\/').Length).TrimStart([char[]]'\/')
        $target = Join-Path $Destination $relative
        if ($item.PSIsContainer) {
            if (Test-Path -LiteralPath $target -PathType Leaf) {
                throw "Staging directory collides with a file: $relative"
            }
            if (-not (Test-Path -LiteralPath $target)) {
                New-Item -ItemType Directory -Path $target | Out-Null
            }
        }
        else {
            if (Test-Path -LiteralPath $target) {
                throw "Staging would overwrite an existing file: $relative"
            }
            $parent = Split-Path -Parent $target
            if (-not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
            Copy-Item -LiteralPath $item.FullName -Destination $target
        }
    }
}

function Build-WorkloadImageTool {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$OutputDirectory,
        [Parameter(Mandatory = $true)][int]$Threads
    )
    $source = Resolve-ExistingDirectory -Path (Join-Path $RepositoryRoot 'tools\workload-image') -Label 'Workload image tool source'
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    $output = Join-Path $OutputDirectory 'retvrn99-workload-image.exe'
    $odinCommand = Get-Command odin -ErrorAction Stop
    $build = Invoke-CapturedProcess -FilePath $odinCommand.Source -Arguments @(
        'build', $source, "-out:$output", '-o:speed', "-thread-count:$Threads"
    ) -WorkingDirectory $RepositoryRoot -Timeout 300
    if ($build.timed_out) { throw 'Building the workload image tool timed out.' }
    if ($build.exit_code -ne 0 -or -not (Test-Path -LiteralPath $output -PathType Leaf)) {
        throw "Building the workload image tool failed: $($build.stderr.Trim())"
    }
    $sidecarOutput = Join-Path $OutputDirectory 'retvrn99-fat32.exe'
    $sidecarSource = Join-Path $RepositoryRoot 'src\fat32_helper'
    $sidecarBuild = Invoke-CapturedProcess -FilePath $odinCommand.Source -Arguments @(
        'build', $sidecarSource, "-out:$sidecarOutput", '-o:speed', "-thread-count:$Threads"
    ) -WorkingDirectory $RepositoryRoot -Timeout 300
    if ($sidecarBuild.timed_out) { throw 'Building RETVRN99-FAT32 for the workload image tool timed out.' }
    if ($sidecarBuild.exit_code -ne 0 -or -not (Test-Path -LiteralPath $sidecarOutput -PathType Leaf)) {
        throw "Building RETVRN99-FAT32 for the workload image tool failed: $($sidecarBuild.stderr.Trim())"
    }
    return (Resolve-ExistingFile -Path $output -Label 'Workload image tool')
}

function Invoke-WorkloadImageTool {
    param(
        [Parameter(Mandatory = $true)][string]$ImageTool,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][int]$Timeout
    )
    $tool = Resolve-ExistingFile -Path $ImageTool -Label 'Workload image tool'
    $result = Invoke-CapturedProcess -FilePath $tool -Arguments $Arguments -WorkingDirectory (Split-Path -Parent $tool) -Timeout $Timeout
    if ($result.timed_out) { throw 'Workload image operation timed out.' }
    return $result
}

function Write-WorkloadProfileSettings {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ImagePath
    )
    $absoluteImage = [IO.Path]::GetFullPath($ImagePath)
    $settings = [ordered]@{
        version = 2
        cpu_mode = 'GSW-886'
        hard_drive_path = $absoluteImage
    }
    Write-JsonFile -Path $Path -Value $settings
}

function New-QuakeGateConfig {
    param([Parameter(Mandatory = $true)][int64]$ExpectedFrames)
    $builder = New-Object Text.StringBuilder
    for ($index = 0; $index -lt $ExpectedFrames + 128; $index++) {
        [void]$builder.Append("wait`r`n")
    }
    [void]$builder.Append("quit`r`n")
    return $builder.ToString()
}

function New-AutoexecText {
    param([Parameter(Mandatory = $true)]$Workload)
    $arguments = @($Workload.arguments)
    if ($Workload.metric -eq 'frames') {
        $arguments += @('-condebug', '+exec', 'GATEEND.CFG')
    }
    $command = (@($Workload.executable) + $arguments) -join ' '
    if ($command.Length -gt 126) {
        throw "Workload $($Workload.id) command exceeds the DOS command-line limit."
    }
    return "@ECHO OFF`r`nC:`r`nCD \`r`n$command > GATE.OUT`r`nTYPE GATE.OUT`r`nEXITVM.COM`r`n"
}

function Stage-WorkloadProfile {
    param(
        [Parameter(Mandatory = $true)][string]$ProfileRoot,
        [Parameter(Mandatory = $true)][string]$DosSeed,
        [Parameter(Mandatory = $true)][string]$WorkloadDirectory,
        [Parameter(Mandatory = $true)]$Workload,
        [Parameter(Mandatory = $true)][string]$ImageTool
    )
    if (Test-Path -LiteralPath $ProfileRoot) {
        throw "Fresh profile path already exists: $ProfileRoot"
    }
    $stagingRoot = Join-Path $ProfileRoot 'image-staging'
    $imagePath = Join-Path $ProfileRoot 'c_drive.img'
    $settingsPath = Join-Path $ProfileRoot 'settings.json'
    New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null
    Copy-TreeWithoutOverwrite -Source $DosSeed -Destination $stagingRoot
    Copy-TreeWithoutOverwrite -Source $WorkloadDirectory -Destination $stagingRoot
    foreach ($required in @('IO.SYS', 'MSDOS.SYS', 'COMMAND.COM')) {
        if (-not (Test-Path -LiteralPath (Join-Path $stagingRoot $required) -PathType Leaf)) {
            throw "DOS seed is missing required file: $required"
        }
    }
    $guestExecutable = Join-Path $stagingRoot $Workload.executable
    if (-not (Test-Path -LiteralPath $guestExecutable -PathType Leaf)) {
        throw "Staged workload executable is missing: $($Workload.executable)"
    }
    $exitPath = Join-Path $stagingRoot 'EXITVM.COM'
    if (Test-Path -LiteralPath $exitPath) {
        throw 'Fixture tree reserves EXITVM.COM for the gate harness.'
    }
    if (Test-Path -LiteralPath (Join-Path $stagingRoot 'GATE.OUT')) {
        throw 'Fixture tree reserves GATE.OUT for the gate harness.'
    }
    [IO.File]::WriteAllBytes($exitPath, (Get-ExitVmBytes))
    if ($Workload.metric -eq 'frames') {
        $id1 = Join-Path $stagingRoot 'ID1'
        if (-not (Test-Path -LiteralPath $id1 -PathType Container)) {
            throw "Quake workload $($Workload.id) is missing its ID1 directory."
        }
        $gateConfig = Join-Path $id1 'GATEEND.CFG'
        if (Test-Path -LiteralPath $gateConfig) {
            throw 'Fixture tree reserves ID1\GATEEND.CFG for the gate harness.'
        }
        if (@(Get-ChildItem -LiteralPath $stagingRoot -Filter 'QCONSOLE.LOG' -File -Recurse -Force).Count -ne 0) {
            throw 'Quake fixture tree must not contain a stale QCONSOLE.LOG.'
        }
        $ascii = New-Object Text.ASCIIEncoding
        [IO.File]::WriteAllText($gateConfig, (New-QuakeGateConfig -ExpectedFrames $Workload.expected), $ascii)
    }
    $autoexecPath = Join-Path $stagingRoot 'AUTOEXEC.BAT'
    $asciiEncoding = New-Object Text.ASCIIEncoding
    [IO.File]::WriteAllText($autoexecPath, (New-AutoexecText -Workload $Workload), $asciiEncoding)
    $stageResult = Invoke-WorkloadImageTool -ImageTool $ImageTool -Arguments @('stage', $imagePath, $stagingRoot) -Timeout 300
    if ($stageResult.exit_code -ne 0) {
        throw "Workload image staging failed: $($stageResult.stderr.Trim())"
    }
    if (-not (Test-Path -LiteralPath $imagePath -PathType Leaf)) {
        throw 'Workload image tool did not create the selected image.'
    }
    Write-WorkloadProfileSettings -Path $settingsPath -ImagePath $imagePath
    Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    return [pscustomobject]@{
        profile_root = $ProfileRoot
        image_path = $imagePath
        settings_path = $settingsPath
        executable = $Workload.executable
    }
}

function ConvertTo-ProcessArgument {
    param([Parameter(Mandatory = $true)][string]$Value)
    if ($Value.IndexOfAny([char[]]"`0`r`n") -ge 0) { throw 'Process argument contains a control character.' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') {
            $slashes++
            continue
        }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * ($slashes * 2 + 1)))
            [void]$builder.Append('"')
        }
        else {
            if ($slashes -gt 0) { [void]$builder.Append(('\' * $slashes)) }
            [void]$builder.Append($character)
        }
        $slashes = 0
    }
    if ($slashes -gt 0) { [void]$builder.Append(('\' * ($slashes * 2))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Invoke-CapturedProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][int]$Timeout
    )
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = (($Arguments | ForEach-Object { ConvertTo-ProcessArgument -Value $_ }) -join ' ')
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    $started = [DateTime]::UtcNow
    if (-not $process.Start()) { throw "Failed to start emulator: $FilePath" }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $timedOut = -not $process.WaitForExit($Timeout * 1000)
    if ($timedOut) {
        try { $process.Kill() } catch { }
    }
    $process.WaitForExit()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $result = [pscustomobject]@{
        exit_code = $process.ExitCode
        timed_out = $timedOut
        stdout = $stdout
        stderr = $stderr
        wall_milliseconds = [int64]([DateTime]::UtcNow - $started).TotalMilliseconds
        command_line = "$FilePath $($startInfo.Arguments)"
    }
    $process.Dispose()
    return $result
}

function Parse-DoomTimedemo {
    param([Parameter(Mandatory = $true)][object[]]$Sources)
    $pattern = '(?im)\btimed\s+(?<gametics>\d+)\s+gametics\s+in\s+(?<realtics>\d+)\s+realtics\b'
    foreach ($source in $Sources) {
        $matches = [regex]::Matches([string]$source.text, $pattern)
        if ($matches.Count -eq 0) { continue }
        $match = $matches[$matches.Count - 1]
        $gametics = [int64]$match.Groups['gametics'].Value
        $realtics = [int64]$match.Groups['realtics'].Value
        $throughput = if ($realtics -gt 0) { [Math]::Round(35.0 * $gametics / $realtics, 6) } else { 0.0 }
        return [pscustomobject]@{
            metric = 'gametics'; value = $gametics; realtics = $realtics
            seconds = $null; throughput = $throughput; source = [string]$source.name
        }
    }
    throw 'Doom timedemo completion text was not found.'
}

function Parse-QuakeTimedemo {
    param([Parameter(Mandatory = $true)][object[]]$Sources)
    $pattern = '(?im)\b(?<frames>\d+)\s+frames\s+(?<seconds>\d+(?:\.\d+)?)\s+seconds\s+(?<fps>\d+(?:\.\d+)?)\s+fps\b'
    foreach ($source in $Sources) {
        $matches = [regex]::Matches([string]$source.text, $pattern)
        if ($matches.Count -eq 0) { continue }
        $match = $matches[$matches.Count - 1]
        return [pscustomobject]@{
            metric = 'frames'; value = [int64]$match.Groups['frames'].Value; realtics = $null
            seconds = [double]::Parse($match.Groups['seconds'].Value, [Globalization.CultureInfo]::InvariantCulture)
            throughput = [double]::Parse($match.Groups['fps'].Value, [Globalization.CultureInfo]::InvariantCulture)
            source = [string]$source.name
        }
    }
    throw 'Quake timedemo completion text was not found.'
}

function Test-AmplificationResult {
    param([Parameter(Mandatory)]$Result)
    if ($null -eq $Result.execution) {
        return [pscustomobject]@{ passed = $false; failure = 'Result JSON has no execution counters.' }
    }
    $execution = $Result.execution
    if ([int64]$execution.storage_host_calls -gt [int64]$execution.storage_transactions) {
        return [pscustomobject]@{ passed = $false; failure = 'Storage host calls exceed bulk transactions.' }
    }
    if ([int64]$execution.scheduler_dispatches -gt [int64]$execution.device_advances) {
        return [pscustomobject]@{ passed = $false; failure = 'A scheduler dispatch did not advance its device.' }
    }
    if ([int64]$Result.audio.frames_produced -eq 0 -and [int64]$execution.audio_blocks -ne 0) {
        return [pscustomobject]@{ passed = $false; failure = 'Silent audio produced VM-side blocks.' }
    }
    return [pscustomobject]@{ passed = $true; failure = $null }
}

function Get-TextFileSource {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Path
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return [pscustomobject]@{ name = $Name; text = [IO.File]::ReadAllText($Path) }
}

function Get-MetricSources {
    param(
        [Parameter(Mandatory = $true)][string]$ImagePath,
        [Parameter(Mandatory = $true)][string]$ImageTool,
        [Parameter(Mandatory = $true)][string]$ObservationRoot,
        [Parameter(Mandatory = $true)]$ProcessResult,
        [Parameter(Mandatory = $true)][string]$Metric
    )
    $sources = @()
    New-Item -ItemType Directory -Path $ObservationRoot -Force | Out-Null
    $guestPaths = if ($Metric -eq 'frames') { @('QCONSOLE.LOG', 'GATE.OUT') } else { @('GATE.OUT') }
    foreach ($guestPath in $guestPaths) {
        $hostPath = Join-Path $ObservationRoot $guestPath
        $observation = Invoke-WorkloadImageTool -ImageTool $ImageTool -Arguments @(
            'observe', $ImagePath, $guestPath, $hostPath
        ) -Timeout 120
        if ($observation.exit_code -eq 3) { continue }
        if ($observation.exit_code -ne 0) {
            throw "Workload image observation failed for $guestPath`: $($observation.stderr.Trim())"
        }
        $source = Get-TextFileSource -Name $guestPath -Path $hostPath
        if ($null -ne $source) { $sources += $source }
    }
    $sources += [pscustomobject]@{ name = 'stdout'; text = $ProcessResult.stdout }
    $sources += [pscustomobject]@{ name = 'stderr'; text = $ProcessResult.stderr }
    return $sources
}

function Get-CompletionIdentity {
    param(
        [Parameter(Mandatory = $true)]$Workload,
        [Parameter(Mandatory = $true)]$Metric,
        [Parameter(Mandatory = $true)]$Result
    )
    $text = @(
        $Workload.id, $Metric.metric, $Metric.value,
        $Result.stop_reason, $Result.test_exit_code,
        $Result.unclassified_io, $Result.unclassified_mmio
    ) -join '|'
    $encoding = New-Object Text.UTF8Encoding($false)
    return Get-Sha256Hex -Bytes $encoding.GetBytes($text)
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )
    $encoding = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 12), $encoding)
}

function Invoke-WorkloadGates {
    param(
        [Parameter(Mandatory = $true)][string]$Manifest,
        [Parameter(Mandatory = $true)][string]$DosSeed,
        [Parameter(Mandatory = $true)][string]$Workloads,
        [Parameter(Mandatory = $true)][string]$Emulator,
        [Parameter(Mandatory = $true)][string]$Output,
        [Parameter(Mandatory = $true)][int]$Timeout,
        [string]$ImageTool = '',
        [ValidateRange(1, 64)][int]$Threads = [Environment]::ProcessorCount
    )
    $repositoryRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
    $manifestData = Read-WorkloadManifest -Path $Manifest
    $seedRoot = Resolve-ExistingDirectory -Path $DosSeed -Label 'DOS seed'
    $workloadRootPath = Resolve-ExistingDirectory -Path $Workloads -Label 'Workload root'
    $emulatorFile = Resolve-ExistingFile -Path $Emulator -Label 'RETVRN99 executable'
    $sidecarFile = Resolve-ExistingFile -Path (Join-Path (Split-Path -Parent $emulatorFile) 'retvrn99-fat32.exe') -Label 'RETVRN99-FAT32 executable'
    Assert-NoReparseTree -Root $seedRoot -Label 'DOS seed'
    $outputPath = Assert-SafeOutputRoot -Path $Output -RepositoryRoot $repositoryRoot -ProtectedPaths @(
        $manifestData.path, $seedRoot, $workloadRootPath, $emulatorFile
    )
    $preflight = @()
    foreach ($workload in $manifestData.workloads) {
        $fixturePath = Resolve-ExistingDirectory -Path (Join-Path $workloadRootPath $workload.id) -Label "Workload $($workload.id)"
        if (-not (Test-PathWithin -Path $fixturePath -Root $workloadRootPath)) {
            throw "Workload escaped the workload root: $($workload.id)"
        }
        Assert-NoReparseTree -Root $fixturePath -Label "Workload $($workload.id)"
        $executable = Resolve-ExistingFile -Path (Join-Path $fixturePath $workload.executable) -Label "Workload $($workload.id) executable"
        $executableHash = Get-FileSha256 -Path $executable
        if ($workload.executable_sha256.Length -ne 0 -and $workload.executable_sha256 -ne $executableHash) {
            throw "Workload $($workload.id) executable hash does not match the manifest."
        }
        $fixtureHash = Get-FixtureTreeHash -Root $fixturePath
        $preflight += [pscustomobject]@{
            workload = $workload; fixture_path = $fixturePath
            executable_sha256 = $executableHash; fixture = $fixtureHash
        }
    }
    if (-not (Test-Path -LiteralPath $outputPath)) {
        New-Item -ItemType Directory -Path $outputPath -Force | Out-Null
    }
    $runName = '{0}-{1}' -f [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'), [Guid]::NewGuid().ToString('N')
    $runRoot = Join-Path $outputPath $runName
    New-Item -ItemType Directory -Path $runRoot | Out-Null
    $imageToolFile = if ([string]::IsNullOrWhiteSpace($ImageTool)) {
        Build-WorkloadImageTool -RepositoryRoot $repositoryRoot -OutputDirectory (Join-Path $runRoot 'tools') -Threads $Threads
    }
    else {
        Resolve-ExistingFile -Path $ImageTool -Label 'Workload image tool'
    }
    $started = [DateTime]::UtcNow
    $allPassed = $true
    $workloadReports = @()
    $ascii = New-Object Text.UTF8Encoding($false)
    foreach ($entry in $preflight) {
        $workload = $entry.workload
        $workloadRunRoot = Join-Path $runRoot $workload.id
        New-Item -ItemType Directory -Path $workloadRunRoot | Out-Null
        $repetitionReports = @()
        for ($repetition = 1; $repetition -le $workload.repetitions; $repetition++) {
            $repetitionRoot = Join-Path $workloadRunRoot ("run-{0}" -f $repetition)
            New-Item -ItemType Directory -Path $repetitionRoot | Out-Null
            $profileRoot = Join-Path $repetitionRoot 'profile'
            $resultPath = Join-Path $repetitionRoot 'result.json'
            $artifactsPath = Join-Path $repetitionRoot 'artifacts'
            $stdoutPath = Join-Path $repetitionRoot 'stdout.txt'
            $stderrPath = Join-Path $repetitionRoot 'stderr.txt'
            $passed = $false
            $failure = $null
            $metric = $null
            $diskResult = $null
            $processResult = $null
            $amplification = $null
            try {
                $staged = Stage-WorkloadProfile -ProfileRoot $profileRoot -DosSeed $seedRoot -WorkloadDirectory $entry.fixture_path -Workload $workload -ImageTool $imageToolFile
                $emulatorArguments = @(
                    '--console', '--test-device', '--strict-io',
                    "--seconds:$Timeout", "--result-json:$resultPath",
                    "--artifacts:$artifactsPath", "--profile-root:$profileRoot"
                )
                $processResult = Invoke-CapturedProcess -FilePath $emulatorFile -Arguments $emulatorArguments -WorkingDirectory (Split-Path -Parent $emulatorFile) -Timeout ($Timeout + 30)
                [IO.File]::WriteAllText($stdoutPath, $processResult.stdout, $ascii)
                [IO.File]::WriteAllText($stderrPath, $processResult.stderr, $ascii)
                if ($processResult.timed_out) { throw "Emulator exceeded the $Timeout-second workload timeout." }
                if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) { throw 'Emulator did not emit result JSON.' }
                $diskResult = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($processResult.exit_code -ne 0 -or [int]$diskResult.exit_code -ne 0) { throw 'Emulator returned a non-zero exit code.' }
                if ([string]$diskResult.stop_reason -ne 'test_exit' -or [int]$diskResult.test_exit_code -ne 0) { throw 'Guest did not complete through Test_Exit with code zero.' }
                if ([int64]$diskResult.unclassified_io -ne 0 -or [int64]$diskResult.unclassified_mmio -ne 0) { throw 'Run reported unclassified I/O or MMIO.' }
                $sources = Get-MetricSources -ImagePath $staged.image_path -ImageTool $imageToolFile -ObservationRoot (Join-Path $repetitionRoot 'guest-observations') -ProcessResult $processResult -Metric $workload.metric
                $metric = if ($workload.metric -eq 'gametics') { Parse-DoomTimedemo -Sources $sources } else { Parse-QuakeTimedemo -Sources $sources }
                if ([int64]$metric.value -ne [int64]$workload.expected) {
                    throw "Expected $($workload.expected) $($workload.metric), observed $($metric.value)."
                }
                $amplification = Test-AmplificationResult -Result $diskResult
                if (-not $amplification.passed) { throw $amplification.failure }
                $passed = $true
            }
            catch {
                $failure = $_.Exception.Message
                $allPassed = $false
                if ($null -ne $processResult) {
                    if (-not (Test-Path -LiteralPath $stdoutPath)) { [IO.File]::WriteAllText($stdoutPath, $processResult.stdout, $ascii) }
                    if (-not (Test-Path -LiteralPath $stderrPath)) { [IO.File]::WriteAllText($stderrPath, $processResult.stderr, $ascii) }
                }
            }
            $identity = if ($passed) { Get-CompletionIdentity -Workload $workload -Metric $metric -Result $diskResult } else { $null }
            $repetitionReports += [pscustomobject]@{
                repetition = $repetition; passed = $passed; failure = $failure
                completion_identity = $identity; metric = $metric
                amplification = $amplification
                process_exit_code = if ($null -ne $processResult) { $processResult.exit_code } else { $null }
                process_wall_milliseconds = if ($null -ne $processResult) { $processResult.wall_milliseconds } else { $null }
                command_line = if ($null -ne $processResult) { $processResult.command_line } else { $null }
                result = $diskResult; profile_root = $profileRoot; result_json = $resultPath
                artifacts = $artifactsPath; stdout = $stdoutPath; stderr = $stderrPath
            }
        }
        $identities = @($repetitionReports | Where-Object passed | ForEach-Object completion_identity | Select-Object -Unique)
        $identical = $repetitionReports.Count -eq $workload.repetitions -and
                     @($repetitionReports | Where-Object { -not $_.passed }).Count -eq 0 -and
                     $identities.Count -eq 1
        if (-not $identical) { $allPassed = $false }
        $workloadReports += [pscustomobject]@{
            id = $workload.id; metric = $workload.metric; expected = $workload.expected
            declared_arguments = $workload.arguments
            harness_arguments = if ($workload.metric -eq 'frames') { @('-condebug', '+exec', 'GATEEND.CFG') } else { @() }
            repetitions_required = $workload.repetitions; executable_sha256 = $entry.executable_sha256
            fixture_tree_sha256 = $entry.fixture.sha256; fixture_file_count = $entry.fixture.file_count
            identical_completion = $identical; repetitions = $repetitionReports
        }
    }
    $manifestHash = Get-FileSha256 -Path $manifestData.path
    $seedHash = Get-FixtureTreeHash -Root $seedRoot
    $aggregate = [pscustomobject]@{
        version = 1; passed = $allPassed; started_utc = $started.ToString('o')
        completed_utc = [DateTime]::UtcNow.ToString('o'); repository_root = $repositoryRoot
        manifest_path = $manifestData.path; manifest_sha256 = $manifestHash
        emulator_path = $emulatorFile; emulator_sha256 = Get-FileSha256 -Path $emulatorFile
        sidecar_path = $sidecarFile; sidecar_sha256 = Get-FileSha256 -Path $sidecarFile
        workload_image_tool = $imageToolFile; workload_image_tool_sha256 = Get-FileSha256 -Path $imageToolFile
        dos_seed_path = $seedRoot; dos_seed_tree_sha256 = $seedHash.sha256
        output_root = $runRoot; performance_gated = $allPassed; wall_time_gated = $false
        workloads = $workloadReports
    }
    $reportPath = Join-Path $runRoot 'aggregate.json'
    Write-JsonFile -Path $reportPath -Value $aggregate
    return [pscustomobject]@{ passed = $allPassed; report_path = $reportPath; report = $aggregate }
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $outcome = Invoke-WorkloadGates -Manifest $ManifestPath -DosSeed $DosSeedPath -Workloads $WorkloadRoot -Emulator $EmulatorPath -Output $OutputRoot -Timeout $TimeoutSeconds -ImageTool $ImageToolPath -Threads $ThreadCount
        Write-Host "Workload gate report: $($outcome.report_path)"
        if (-not $outcome.passed) { exit 1 }
    }
    catch {
        [Console]::Error.WriteLine("Workload gate failed: $($_.Exception.Message)")
        exit 1
    }
}
