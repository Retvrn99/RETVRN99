# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [string]$SourceProfile,
    [string]$DisposableProfile,
    [string]$EvidenceDirectory,
    [string]$PifFile,
    [string]$KnownGoodRegFile,
    [string]$KnownGoodAutoexecFile,
    [string]$HostExecutable,
    [string]$GuestImportExecutable,
    [string]$LauncherStageExecutable,
    [string]$PifLauncherExecutable,
    [string]$CandidateDriverRoot,
    [string]$NasmExecutable,
    [string]$Case,
    [string]$Mode,
    [int]$Width,
    [int]$Height,
    [int]$Repetition,
    [int]$SentinelX = -1,
    [int]$SentinelY = -1,
    [int]$SentinelWidth = -1,
    [int]$SentinelHeight = -1,
    [string]$ExpectedDesktopSentinelCrc,
    [string]$QuakeArguments,
    [ValidateSet('auto', 'scalar')]
    [string]$LegacyApertureMode = 'auto',
    [switch]$ScalarControl,
    [ValidateRange(90, 900)]
    [int]$Seconds = 180,
    [string]$GuestPifPath = 'QUAKE/QUAKEPIF.PIF',
    [string]$GuestPifLauncherPath = 'QUAKE/PIFRUN.EXE',
    [string]$GuestBatchPath = 'QUAKE/RETURN3.BAT',
    [string]$GuestHelperPath = 'QUAKE/EXITVM.COM',
    [string]$GuestRegPath = 'QUAKE/DRIVER.REG',
    [switch]$GuestRunAuthorized,
    [switch]$ValidateOnly,
    [switch]$DefineFunctionsOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:LegacyVgaEvidencePifBytes = 967L
$script:LegacyVgaEvidencePifSha256 =
    'B4CAF52E570078852B84A814664A3D091CF0916EBA70DB4DBA559FA90C400281'
$script:LegacyVgaEvidencePreCapture = 224
$script:LegacyVgaEvidencePostCapture = 225
$script:LegacyVgaEvidenceFailureCapture = 239
$script:LegacyVgaEvidenceReportName = 'legacy-vga-result.tsv'
$script:LegacyVgaEvidenceShutdownTraceName = 'shutdown-trace.tsv'
$script:LegacyVgaEvidenceQuakeExitConfigPath = 'QUAKE/ID1/RETVRN99.CFG'
$script:LegacyVgaEvidenceQuakeExitWaitFrames = 1100
$script:LegacyVgaEvidenceLauncherStageContract =
    'usage: gswgfx-launcher-stage IMAGE REG_FILE AUTOEXEC_FILE [GUEST_REG_PATH]'

function Assert-LegacyVgaEvidenceRequiredText {
    param([string]$Value, [string]$Label)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "$Label must be supplied explicitly."
    }
}

function Get-LegacyVgaEvidenceFullPath {
    param([string]$Path, [string]$Label)

    Assert-LegacyVgaEvidenceRequiredText $Path $Label
    try {
        $full = [IO.Path]::GetFullPath($Path)
    } catch {
        throw "$Label is not a valid path: $Path"
    }
    $root = [IO.Path]::GetPathRoot($full)
    $tail = $full.Substring($root.Length)
    if ($tail.Contains(':')) {
        throw "$Label must not contain an alternate data stream."
    }
    return $full.TrimEnd([char[]]@('\', '/'))
}

function Test-LegacyVgaEvidencePathWithin {
    param([string]$Path, [string]$Root)

    $candidate = [IO.Path]::GetFullPath($Path).TrimEnd([char[]]@('\', '/'))
    $container = [IO.Path]::GetFullPath($Root).TrimEnd([char[]]@('\', '/'))
    if ($candidate.Equals($container, [StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }
    $prefix = $container + [IO.Path]::DirectorySeparatorChar
    return $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-LegacyVgaEvidenceTemporaryPath {
    param([string]$Path, [string]$Label)

    $temporaryRoot = [IO.Path]::GetFullPath('V:\tmp').TrimEnd([char[]]@('\', '/'))
    if (-not (Test-LegacyVgaEvidencePathWithin $Path $temporaryRoot)) {
        throw "$Label must remain under $temporaryRoot."
    }
}

function Assert-LegacyVgaEvidenceFile {
    param([string]$Path, [string]$Label)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label is missing: $Path"
    }
}

function Get-LegacyVgaEvidenceCandidateDrivers {
    param([string]$Root)

    $rootPath = Get-LegacyVgaEvidenceFullPath $Root 'Candidate driver root'
    if (-not (Test-Path -LiteralPath $rootPath -PathType Container)) {
        throw "Candidate driver root is missing: $rootPath"
    }
    $specifications = @(
        @('gswmini.drv', 'WINDOWS/SYSTEM/GSWMINI.DRV'),
        @('gswmini.vxd', 'WINDOWS/SYSTEM/GSWMINI.VXD'),
        @('gswhal9x.dll', 'WINDOWS/SYSTEM/GSWHAL9X.DLL'),
        @('gswdd32.dll', 'WINDOWS/SYSTEM/GSWDD32.DLL')
    )
    return @(
        foreach ($specification in $specifications) {
            $source = Join-Path $rootPath ([string]$specification[0])
            Assert-LegacyVgaEvidenceFile $source "Candidate driver $($specification[0])"
            $item = Get-Item -LiteralPath $source -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                $item.Length -le 0) {
                throw "Candidate driver must be a nonempty regular file: $source"
            }
            [pscustomobject]@{
                name = [string]$specification[0]
                source = $source
                guest_path = [string]$specification[1]
                bytes = [long]$item.Length
                sha256 = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
            }
        }
    )
}

function Assert-LegacyVgaEvidencePifMetadata {
    param([long]$Length, [string]$Sha256)

    if ($Length -ne $script:LegacyVgaEvidencePifBytes) {
        throw (
            'The fullscreen Quake PIF must be exactly {0} bytes; observed {1}.' -f
            $script:LegacyVgaEvidencePifBytes, $Length
        )
    }
    if ($Sha256.ToUpperInvariant() -cne $script:LegacyVgaEvidencePifSha256) {
        throw "The fullscreen Quake PIF SHA-256 is not the approved exact PIF."
    }
}

function Assert-LegacyVgaEvidencePifFile {
    param([string]$Path)

    Assert-LegacyVgaEvidenceFile $Path 'Fullscreen Quake PIF'
    $item = Get-Item -LiteralPath $Path
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    Assert-LegacyVgaEvidencePifMetadata $item.Length $hash
    return [pscustomobject]@{
        path = [IO.Path]::GetFullPath($Path)
        bytes = [long]$item.Length
        sha256 = $hash.ToUpperInvariant()
    }
}

function ConvertTo-LegacyVgaEvidenceGuestPath {
    param([string]$Path, [string]$Label)

    Assert-LegacyVgaEvidenceRequiredText $Path $Label
    if ($Path -notmatch '^[A-Za-z0-9_~.-]+(?:[\\/][A-Za-z0-9_~.-]+)+$' -or
        $Path.Contains('..')) {
        throw "$Label must be a relative DOS path without spaces or traversal."
    }
    return 'C:\' + $Path.Replace('/', '\')
}

function New-LegacyVgaEvidenceLauncherArguments {
    param(
        [string]$CloneDisk,
        [string]$RegSource,
        [string]$AutoexecSource,
        [string]$GuestRegWindows
    )

    if (-not $GuestRegWindows.StartsWith(
        'C:\',
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'Launcher guest REG must be an absolute DOS path.'
    }
    $guestRegImage = $GuestRegWindows.Substring(3).Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($guestRegImage) -or
        $guestRegImage.Contains(':') -or $guestRegImage.Contains('..')) {
        throw 'Launcher guest REG must resolve to one FAT-relative file path.'
    }
    return @($CloneDisk, $RegSource, $AutoexecSource, $guestRegImage)
}

function Assert-LegacyVgaEvidenceToken {
    param([string]$Value, [string]$Label)

    Assert-LegacyVgaEvidenceRequiredText $Value $Label
    if ($Value -notmatch '^[A-Za-z0-9_.-]+$') {
        throw "$Label contains characters that are unsafe for a DOS report row."
    }
}

function Assert-LegacyVgaEvidenceQuakeArguments {
    param([string]$Arguments)

    Assert-LegacyVgaEvidenceRequiredText $Arguments 'Quake arguments'
    if ($Arguments -notmatch '^[A-Za-z0-9_+.,:=/\\ -]+$' -or
        $Arguments.IndexOfAny([char[]]@("`r", "`n", "`t", '&', '|', '<', '>', '%', '"')) -ge 0) {
        throw 'Quake arguments contain unsafe Win98 command characters.'
    }
    if ($Arguments -match '(?i)(?:^|\s)\+quit(?:\s|$)') {
        throw 'Quake arguments must not contain +quit; the test-owned config exits through the console.'
    }
    if ($Arguments -match '(?i)(?:^|\s)\+exec(?:\s|$)') {
        throw 'Quake arguments must not contain +exec; the harness owns the exit config.'
    }
    if ($Arguments -notmatch '(?i)(?:^|\s)\+timedemo\s+[A-Za-z0-9_.-]+(?:\s|$)') {
        throw 'Quake arguments must contain +timedemo with one bounded workload.'
    }
}

function Assert-LegacyVgaEvidencePifLauncherFile {
    param([string]$Path)

    Assert-LegacyVgaEvidenceFile $Path 'PIF launcher executable'
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $item.Length -lt 1024 -or $item.Length -gt 1048576) {
        throw 'PIF launcher must be a bounded regular executable.'
    }
    $stream = [IO.File]::Open(
        $item.FullName,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read
    )
    try {
        if ($stream.ReadByte() -ne 0x4D -or $stream.ReadByte() -ne 0x5A) {
            throw 'PIF launcher must be a Windows MZ executable.'
        }
    } finally {
        $stream.Dispose()
    }
    return [pscustomobject]@{
        path = $item.FullName
        bytes = [long]$item.Length
        sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
    }
}

function Assert-LegacyVgaEvidenceLauncherStageFile {
    param([string]$Path)

    Assert-LegacyVgaEvidenceFile $Path 'launcher-stage executable'
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $item.Length -lt 1024 -or $item.Length -gt 16777216) {
        throw 'launcher-stage must be a bounded regular executable.'
    }
    [byte[]]$bytes = [IO.File]::ReadAllBytes($item.FullName)
    if ($bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) {
        throw 'launcher-stage must be a Windows MZ executable.'
    }
    $text = [Text.Encoding]::ASCII.GetString($bytes)
    if (-not $text.Contains($script:LegacyVgaEvidenceLauncherStageContract)) {
        throw 'launcher-stage does not support the required guest REG path contract.'
    }
    return [pscustomobject]@{
        path = $item.FullName
        bytes = [long]$item.Length
        sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
    }
}

function Get-LegacyVgaEvidenceSentinel {
    param(
        [int]$X,
        [int]$Y,
        [int]$Width,
        [int]$Height,
        [string]$ExpectedCrc
    )

    Assert-LegacyVgaEvidenceRequiredText $ExpectedCrc 'Expected desktop sentinel CRC'
    if ($X -lt 0 -or $Y -lt 0 -or $Width -lt 1 -or $Height -lt 1 -or
        $X + $Width -gt 800 -or $Y + $Height -gt 600 -or
        $X -gt 65535 -or $Y -gt 65535 -or
        $Width -gt 65535 -or $Height -gt 65535) {
        throw 'Desktop sentinel rectangle must be nonempty and inside the 800x600 desktop.'
    }
    $hex = $ExpectedCrc
    if ($hex.StartsWith('0x', [StringComparison]::OrdinalIgnoreCase)) {
        $hex = $hex.Substring(2)
    }
    if ($hex -notmatch '^[0-9A-Fa-f]{8}$') {
        throw 'Expected desktop sentinel CRC must contain exactly eight hexadecimal digits.'
    }
    return [pscustomobject]@{
        X = [uint16]$X
        Y = [uint16]$Y
        Width = [uint16]$Width
        Height = [uint16]$Height
        Crc = [Convert]::ToUInt32($hex, 16)
        CrcHex = $hex.ToUpperInvariant()
    }
}

function Get-LegacyVgaEvidenceSentinelBytes {
    param([pscustomobject]$Sentinel)

    [byte[]]$bytes = [byte[]]::new(12)
    $values = @(
        [uint16]$Sentinel.X,
        [uint16]$Sentinel.Y,
        [uint16]$Sentinel.Width,
        [uint16]$Sentinel.Height
    )
    for ($index = 0; $index -lt $values.Count; $index += 1) {
        $bytes[$index * 2] = [byte]($values[$index] -band 0xFF)
        $bytes[$index * 2 + 1] = [byte](($values[$index] -shr 8) -band 0xFF)
    }
    [uint32]$crc = $Sentinel.Crc
    for ($index = 0; $index -lt 4; $index += 1) {
        $bytes[8 + $index] = [byte](($crc -shr (8 * $index)) -band 0xFF)
    }
    return $bytes
}

function Get-LegacyVgaEvidenceAsciiBytes {
    param([string]$Text)

    foreach ($character in $Text.ToCharArray()) {
        if ([int]$character -gt 0x7F) {
            throw 'Generated Win98 staging text must remain ASCII.'
        }
    }
    return [Text.Encoding]::ASCII.GetBytes($Text)
}

function Get-LegacyVgaEvidenceSha256 {
    param([byte[]]$Bytes)

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return [BitConverter]::ToString($sha256.ComputeHash($Bytes)).Replace('-', '')
    } finally {
        $sha256.Dispose()
    }
}

function Get-LegacyVgaEvidenceDerivedRegBytes {
    param([byte[]]$SourceBytes, [string]$RunTarget)

    if ($SourceBytes.Length -lt 32 -or $SourceBytes.Length -gt 65536) {
        throw 'Known-good REG bytes are outside the bounded size.'
    }
    foreach ($value in $SourceBytes) {
        if ($value -gt 0x7F) { throw 'Known-good REG must be ASCII.' }
    }
    if ($RunTarget -notmatch '^[A-Za-z]:\\[A-Za-z0-9_~.\\-]+$') {
        throw 'The Run-key target must be one safe DOS path.'
    }

    $text = [Text.Encoding]::ASCII.GetString($SourceBytes)
    if (-not $text.StartsWith("REGEDIT4`r`n", [StringComparison]::Ordinal)) {
        throw 'Known-good REG must be a CRLF REGEDIT4 file.'
    }
    $marker = '"GSWGFX"="'
    $markerIndex = $text.IndexOf($marker, [StringComparison]::Ordinal)
    if ($markerIndex -lt 0 -or
        $text.IndexOf($marker, $markerIndex + $marker.Length,
            [StringComparison]::Ordinal) -ge 0) {
        throw 'Known-good REG must contain exactly one GSWGFX Run value.'
    }
    $valueStart = $markerIndex + $marker.Length
    $valueEnd = $text.IndexOf('"', $valueStart)
    if ($valueEnd -lt $valueStart) {
        throw 'Known-good REG has an unterminated GSWGFX Run value.'
    }
    $knownValue = $text.Substring($valueStart, $valueEnd - $valueStart)
    $slash = 0
    while ($slash -lt $knownValue.Length) {
        if ($knownValue[$slash] -ne '\') { $slash += 1; continue }
        if ($slash + 1 -ge $knownValue.Length -or $knownValue[$slash + 1] -ne '\') {
            throw 'Known-good REG lost a doubled Run-value backslash.'
        }
        $slash += 2
    }

    $escapedTarget = $RunTarget.Replace('\', '\\')
    [byte[]]$replacement = Get-LegacyVgaEvidenceAsciiBytes $escapedTarget
    [byte[]]$derived = [byte[]]::new(
        $valueStart + $replacement.Length + ($SourceBytes.Length - $valueEnd)
    )
    [Array]::Copy($SourceBytes, 0, $derived, 0, $valueStart)
    [Array]::Copy($replacement, 0, $derived, $valueStart, $replacement.Length)
    [Array]::Copy(
        $SourceBytes,
        $valueEnd,
        $derived,
        $valueStart + $replacement.Length,
        $SourceBytes.Length - $valueEnd
    )
    return $derived
}

function Assert-LegacyVgaEvidenceAutoexec {
    param([string]$Path, [string]$GuestRegWindowsPath)

    Assert-LegacyVgaEvidenceFile $Path 'Known-good AUTOEXEC'
    [byte[]]$bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 32 -or $bytes.Length -gt 65536) {
        throw 'Known-good AUTOEXEC is outside the bounded size.'
    }
    foreach ($value in $bytes) {
        if ($value -gt 0x7F) { throw 'Known-good AUTOEXEC must be ASCII.' }
    }
    $text = [Text.Encoding]::ASCII.GetString($bytes)
    $firstLine = ($text -split "`r`n", 2)[0]
    $requiredPrefix =
        'C:\WINDOWS\REGEDIT.EXE /L:C:\WINDOWS\SYSTEM.DAT ' +
        '/R:C:\WINDOWS\USER.DAT '
    if (-not $firstLine.StartsWith($requiredPrefix,
            [StringComparison]::OrdinalIgnoreCase) -or
        -not $firstLine.EndsWith($GuestRegWindowsPath,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Known-good AUTOEXEC must import the staged REG before any launcher work.'
    }
    return $bytes
}

function New-LegacyVgaEvidenceBatchText {
    param(
        [string]$PifWindowsPath,
        [string]$PifLauncherWindowsPath,
        [string]$HelperWindowsPath,
        [string]$Arguments
    )

    Assert-LegacyVgaEvidenceQuakeArguments $Arguments
    $lines = @(
        '@ECHO OFF',
        "$HelperWindowsPath P",
        'IF ERRORLEVEL 2 GOTO SHUTDOWN',
        'IF ERRORLEVEL 1 GOTO REPORTFAIL',
        'DEL C:\QUAKE\ID1\QCONSOLE.LOG >NUL 2>NUL',
        "START $PifWindowsPath $Arguments +exec RETVRN99.CFG",
        "$PifLauncherWindowsPath /wait",
        'IF ERRORLEVEL 1 GOTO QUAKEFAIL',
        "$HelperWindowsPath O",
        'GOTO SHUTDOWN',
        ':QUAKEFAIL',
        "$HelperWindowsPath Q",
        ':FAILHOLD',
        'PAUSE >NUL',
        'GOTO FAILHOLD',
        ':REPORTFAIL',
        "$HelperWindowsPath R",
        ':SHUTDOWN',
        'RUNDLL32.EXE user.exe,ExitWindows'
    )
    return ($lines -join "`r`n") + "`r`n"
}

function New-LegacyVgaEvidenceQuakeExitConfig {
    $lines = [Collections.Generic.List[string]]::new(
        $script:LegacyVgaEvidenceQuakeExitWaitFrames + 4
    )
    [void]$lines.Add('startdemos')
    for ($frame = 0; $frame -lt $script:LegacyVgaEvidenceQuakeExitWaitFrames; $frame += 1) {
        [void]$lines.Add('wait')
    }
    [void]$lines.Add('echo RETVRN99_NORMAL_EXIT')
    [void]$lines.Add('toggleconsole')
    [void]$lines.Add('quit')
    $text = ($lines -join "`r`n") + "`r`n"
    if ($text.Length -gt 16384) {
        throw 'Generated Quake exit config exceeded its test-only bound.'
    }
    return $text
}

function New-LegacyVgaEvidenceReportPayloads {
    param(
        [string]$Case,
        [string]$Mode,
        [int]$Width,
        [int]$Height,
        [int]$Repetition,
        [string]$ExpectedSentinelCrc
    )

    Assert-LegacyVgaEvidenceToken $Case 'Case'
    Assert-LegacyVgaEvidenceToken $Mode 'Mode'
    if ($Width -notin @(320, 360) -or $Height -notin @(200, 240, 350, 400, 480)) {
        throw 'Legacy VGA geometry must be one of the ten 320/360 Mode X geometries.'
    }
    if ($Repetition -lt 1 -or $Repetition -gt 99) {
        throw 'Repetition must be between 1 and 99.'
    }
    if ($ExpectedSentinelCrc -notmatch '^[0-9A-F]{8}$') {
        throw 'Report sentinel CRC must be normalized to eight uppercase hex digits.'
    }

    $header = @(
        'schema', 'case', 'mode', 'width', 'height', 'repetition', 'phase',
        'owner_generation', 'mode_generation', 'surface_generation',
        'aperture_exits', 'presented_hz', 'desktop_sentinel_crc',
        'shutdown_marker_completion', 'status', 'reason'
    ) -join "`t"
    $common = @('1', $Case, $Mode, $Width, $Height, $Repetition)
    $unobserved = @(
        'host-join-required', 'host-join-required', 'host-join-required',
        'host-join-required', 'host-join-required'
    )
    $pre = @(
        $header,
        (($common + @('pre-pif') + $unobserved + @(
            $ExpectedSentinelCrc, 'pending', 'INFO', 'launching-exact-pif'
        )) -join "`t")
    ) -join "`r`n"
    $post = @(
        (($common + @('desktop-restored') + $unobserved + @(
            $ExpectedSentinelCrc, 'pending', 'PASS', 'pif-returned'
        )) -join "`t"),
        (($common + @('terminal') + $unobserved + @(
            $ExpectedSentinelCrc, 'pending', 'PASS', 'launcher-complete'
        )) -join "`t")
    ) -join "`r`n"
    $quakeFailure = (($common + @('terminal') + $unobserved + @(
        $ExpectedSentinelCrc, 'pending', 'FAIL', 'pif-returned-error'
    )) -join "`t")
    $sentinelFailure = (($common + @('terminal') + $unobserved + @(
        $ExpectedSentinelCrc, 'pending', 'FAIL', 'desktop-sentinel-crc-mismatch'
    )) -join "`t")
    $reportFailure = @(
        $header,
        (($common + @('terminal') + $unobserved + @(
            $ExpectedSentinelCrc, 'pending', 'FAIL', 'pre-phase-report-error'
        )) -join "`t")
    ) -join "`r`n"

    return [pscustomobject]@{
        Pre = $pre + "`r`n"
        Post = $post + "`r`n"
        QuakeFailure = $quakeFailure + "`r`n"
        SentinelFailure = $sentinelFailure + "`r`n"
        ReportFailure = $reportFailure + "`r`n"
    }
}

function Write-LegacyVgaEvidenceFileCreateNew {
    param([string]$Path, [byte[]]$Bytes)

    $stream = [IO.File]::Open(
        $Path,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None
    )
    try {
        $stream.Write($Bytes, 0, $Bytes.Length)
        $stream.Flush($true)
    } finally {
        $stream.Dispose()
    }
}

function Build-LegacyVgaEvidenceKateaHelper {
    param(
        [string]$StageDirectory,
        [string]$Assembler,
        [string]$Template,
        [pscustomobject]$Payloads,
        [pscustomobject]$Sentinel
    )

    $source = Join-Path $StageDirectory 'legacy-vga-evidence-katea.asm'
    Copy-Item -LiteralPath $Template -Destination $source
    $payloadFiles = [ordered]@{
        'legacy-vga-evidence-pre.tsv' = $Payloads.Pre
        'legacy-vga-evidence-post.tsv' = $Payloads.Post
        'legacy-vga-evidence-quake-failure.tsv' = $Payloads.QuakeFailure
        'legacy-vga-evidence-sentinel-failure.tsv' = $Payloads.SentinelFailure
        'legacy-vga-evidence-report-failure.tsv' = $Payloads.ReportFailure
    }
    foreach ($entry in $payloadFiles.GetEnumerator()) {
        $payloadPath = Join-Path $StageDirectory $entry.Key
        [byte[]]$bytes = Get-LegacyVgaEvidenceAsciiBytes ([string]$entry.Value)
        Write-LegacyVgaEvidenceFileCreateNew $payloadPath $bytes
    }
    Write-LegacyVgaEvidenceFileCreateNew `
        (Join-Path $StageDirectory 'legacy-vga-evidence-sentinel.bin') `
        (Get-LegacyVgaEvidenceSentinelBytes $Sentinel)

    $output = Join-Path $StageDirectory 'legacy-vga-evidence-katea.com'
    Push-Location $StageDirectory
    try {
        & $Assembler '-f' 'bin' '-o' $output $source
        $exitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    if ($exitCode -ne 0 -or -not (Test-Path -LiteralPath $output -PathType Leaf)) {
        throw "NASM failed to build the Katea reporter with exit $exitCode."
    }
    $item = Get-Item -LiteralPath $output
    if ($item.Length -lt 256 -or $item.Length -gt 65535) {
        throw "Generated Katea COM size is invalid: $($item.Length)."
    }
    return [pscustomobject]@{
        Path = $output
        Bytes = [long]$item.Length
        Sha256 = (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash
    }
}

function Assert-LegacyVgaEvidenceShutdownTrace {
    param([string]$Path)

    Assert-LegacyVgaEvidenceFile $Path 'Shutdown trace'
    $lines = @(Get-Content -LiteralPath $Path)
    $metadataHeader = 'enabled' + "`t" + 'armed' + "`t" + 'capacity' + "`t" +
        'count' + "`t" + 'recorded' + "`t" + 'dropped_unarmed' + "`t" +
        'dropped_markers' + "`t" + 'overwritten'
    $metadataIndex = [Array]::IndexOf($lines, $metadataHeader)
    if ($metadataIndex -lt 0 -or $metadataIndex + 1 -ge $lines.Count) {
        throw 'Shutdown trace has no bounded-ring metadata.'
    }
    $metadataFields = @(([string]$lines[$metadataIndex + 1]).Split("`t"))
    if ($metadataFields.Count -ne 8) {
        throw 'Shutdown trace bounded-ring metadata row is malformed.'
    }
    foreach ($counter in $metadataFields[2..7]) {
        if ($counter -cnotmatch '^(0|[1-9][0-9]*)$') {
            throw 'Shutdown trace bounded-ring metadata contains an invalid counter.'
        }
    }
    try {
        [uint64]$capacity = $metadataFields[2]
        [uint64]$count = $metadataFields[3]
        [uint64]$recorded = $metadataFields[4]
        [uint64]$droppedUnarmed = $metadataFields[5]
        [uint64]$droppedMarkers = $metadataFields[6]
        [uint64]$overwritten = $metadataFields[7]
    } catch {
        throw 'Shutdown trace bounded-ring metadata contains an invalid counter.'
    }
    if ($metadataFields[0] -cne 'true' -or
        $metadataFields[1] -cne 'true' -or
        $capacity -ne 65536 -or
        $count -lt 1 -or
        $count -gt $capacity) {
        throw 'Shutdown trace bounded-ring metadata is invalid.'
    }
    if ($recorded -ne $count + $overwritten) {
        throw 'Shutdown trace bounded-ring accounting is inconsistent.'
    }
    if ($droppedMarkers -ne 0) {
        throw 'Shutdown trace dropped lifecycle markers.'
    }
    $null = $droppedUnarmed
    $header = 'sequence' + "`t" + 'kind' + "`t" + 'value' + "`t" +
        'cs' + "`t" + 'flags' + "`t" + 'rip' + "`t" + 'address' + "`t" + 'detail'
    $headerIndex = [Array]::IndexOf($lines, $header)
    if ($headerIndex -lt 0 -or $headerIndex + 1 -ge $lines.Count) {
        throw 'Shutdown trace has no event table.'
    }
    $eventLines = @($lines[($headerIndex + 1)..($lines.Count - 1)])
    if ([uint64]$eventLines.Count -ne $count) {
        throw 'Shutdown trace event count does not match bounded-ring metadata.'
    }
    $events = @()
    [uint64]$previousSequence = 0
    [uint64]$missingSequences = 0
    foreach ($line in $eventLines) {
        $fields = @(([string]$line).Split("`t"))
        if ($fields.Count -ne 8) {
            throw 'Shutdown trace event row is malformed.'
        }
        if ($fields[0] -cnotmatch '^[1-9][0-9]*$') {
            throw 'Shutdown trace event sequence is invalid.'
        }
        try {
            [uint64]$sequence = $fields[0]
        } catch {
            throw 'Shutdown trace event sequence is invalid.'
        }
        if ($sequence -le $previousSequence) {
            throw 'Shutdown trace event sequence is not strictly increasing.'
        }
        $missingSequences += $sequence - $previousSequence - 1
        $previousSequence = $sequence
        $kind = $fields[1]
        $value = $fields[2]
        if ($kind -cnotin @(
            'marker', 'mmio', 'irq-injected', 'irq-deferred', 'fault-injected'
        )) {
            throw 'Shutdown trace event kind is invalid.'
        }
        if ($value -cnotmatch '^[0-9a-f]{2}$' -or
            $fields[3] -cnotmatch '^[0-9a-f]{4}$' -or
            $fields[4] -cnotmatch '^[0-9a-f]{8}$' -or
            $fields[5] -cnotmatch '^[0-9a-f]{16}$' -or
            $fields[6] -cnotmatch '^[0-9a-f]{16}$' -or
            $fields[7] -cnotmatch '^[0-9a-f]{16}$') {
            throw 'Shutdown trace event row has malformed encoded values.'
        }
        $events += [pscustomobject]@{
            sequence = $sequence
            kind = $kind
            value = $value
        }
    }
    if ($events[0].sequence -ne 1 -or
        $events[$events.Count - 1].sequence -ne $recorded -or
        $missingSequences -ne $overwritten) {
        throw 'Shutdown trace event sequence accounting is inconsistent.'
    }
    $markers = @($events | Where-Object { $_.kind -ceq 'marker' })
    foreach ($failureMarker in @('eb', 'ef')) {
        if (@($markers | Where-Object { $_.value -ceq $failureMarker }).Count -ne 0) {
            throw "Shutdown trace contains lifecycle failure marker $failureMarker."
        }
    }

    $terminalRequired = @('d6', 'e8', 'd7', 'd8', 'd9', 'da', 'db', 'dc')
    $firstD5 = -1
    for ($index = 0; $index -lt $markers.Count; $index += 1) {
        if ($markers[$index].value -ceq 'd5') {
            $firstD5 = $index
            break
        }
    }
    if ($firstD5 -lt 0) {
        throw 'Shutdown trace did not complete ordered marker d5.'
    }

    $beforeTerminal = @()
    if ($firstD5 -gt 0) {
        $beforeTerminal = @($markers[0..($firstD5 - 1)])
    }
    $prematureTerminal = @($beforeTerminal | Where-Object {
        $_.value -cin @('d6', 'e8', 'd7', 'dc', 'e9', 'ea')
    })
    if ($prematureTerminal.Count -ne 0) {
        throw 'Shutdown trace contains a terminal lifecycle marker before driver disabling.'
    }
    $transitions = @($beforeTerminal |
        Where-Object { $_.value -match '^d[1-4]$' } |
        ForEach-Object { $_.value })
    $expectedTransition = @('d1', 'd2', 'd3', 'd4')
    if ($transitions.Count -lt 4 -or $transitions.Count % 4 -ne 0) {
        throw 'Shutdown trace has no balanced D1-D4 fullscreen transition.'
    }
    for ($index = 0; $index -lt $transitions.Count; $index += 1) {
        if ($transitions[$index] -cne $expectedTransition[$index % 4]) {
            throw 'Shutdown trace has no balanced D1-D4 fullscreen transition.'
        }
    }
    $afterDisable = @($markers[$firstD5..($markers.Count - 1)] |
        Where-Object { $_.value -match '^d[1-4]$' })
    if ($afterDisable.Count -ne 0) {
        throw 'Shutdown trace contains a fullscreen transition after driver disabling.'
    }

    $terminalCursor = 0
    for ($index = $firstD5 + 1; $index -lt $markers.Count; $index += 1) {
        $value = $markers[$index].value
        if ($value -ceq 'd5') {
            if ($terminalCursor -ne 0) {
                throw 'Shutdown trace did not complete ordered marker d6 through dc.'
            }
            continue
        }
        if ($terminalRequired -cnotcontains $value) { continue }
        if ($value -cne $terminalRequired[$terminalCursor]) {
            throw 'Shutdown trace did not complete ordered marker d6 through dc.'
        }
        $terminalCursor += 1
        if ($terminalCursor -eq $terminalRequired.Count) { break }
    }
    if ($terminalCursor -ne $terminalRequired.Count) {
        throw 'Shutdown trace did not complete ordered marker d6 through dc.'
    }
}

function Assert-LegacyVgaEvidenceResult {
    param([object]$Result, [int]$HostExit)

    foreach ($field in @(
        'stop_reason', 'exit_code', 'reset_count', 'guest_requested_resets',
        'boot_epoch', 'unclassified_io', 'unclassified_mmio'
    )) {
        if ($null -eq $Result -or
            $Result.PSObject.Properties.Name -cnotcontains $field -or
            $null -eq $Result.$field) {
            throw "Legacy VGA result field '$field' is missing or null."
        }
    }
    if ($Result.stop_reason -isnot [string]) {
        throw 'Legacy VGA result stop_reason is invalid.'
    }
    $integerTypes = @(
        [TypeCode]::SByte, [TypeCode]::Byte,
        [TypeCode]::Int16, [TypeCode]::UInt16,
        [TypeCode]::Int32, [TypeCode]::UInt32,
        [TypeCode]::Int64, [TypeCode]::UInt64
    )
    foreach ($field in @(
        'exit_code', 'reset_count', 'guest_requested_resets', 'boot_epoch',
        'unclassified_io', 'unclassified_mmio'
    )) {
        if ([Type]::GetTypeCode($Result.$field.GetType()) -notin $integerTypes) {
            throw "Legacy VGA result field '$field' is not an integer."
        }
    }
    try {
        [int]$exitCode = $Result.exit_code
        [uint64]$resetCount = $Result.reset_count
        [uint64]$guestRequestedResets = $Result.guest_requested_resets
        [uint64]$bootEpoch = $Result.boot_epoch
        [uint64]$unclassifiedIo = $Result.unclassified_io
        [uint64]$unclassifiedMmio = $Result.unclassified_mmio
    } catch {
        throw 'Legacy VGA result contains an invalid numeric field.'
    }
    if ($HostExit -ne 0 -or
        [string]$Result.stop_reason -cne 'power_off' -or
        $exitCode -ne 0) {
        throw (
            "Expected host exit 0 and power_off/0, observed host=$HostExit " +
            "stop=$($Result.stop_reason) result=$exitCode."
        )
    }
    if ($resetCount -ne 0 -or
        $guestRequestedResets -ne 0 -or
        $bootEpoch -ne 1) {
        throw 'Legacy VGA evidence must complete without a guest or lifetime reset.'
    }
    if ($unclassifiedIo -ne 0 -or $unclassifiedMmio -ne 0) {
        throw (
            'Legacy VGA evidence contains unclassified I/O: io={0} mmio={1}.' -f
            $unclassifiedIo, $unclassifiedMmio
        )
    }
}

function Assert-LegacyVgaEvidenceLogs {
    param([string[]]$Paths, [switch]$AllowMmioStorm)

    $failures = @('upload-failed', 'render failure', 'warm CPU reset')
    if (-not $AllowMmioStorm) { $failures = @('MMIO exit storm') + $failures }
    foreach ($failureText in $failures) {
        $matches = @(Select-String -LiteralPath $Paths -Pattern $failureText `
            -SimpleMatch -ErrorAction Stop)
        if ($matches.Count -ne 0) {
            throw "Legacy VGA evidence contains '$failureText'."
        }
    }
}

function Assert-LegacyVgaEvidenceScalarControl {
    param([string]$Mode, [bool]$Enabled)

    if ($Enabled -and $Mode -cne 'scalar') {
        throw 'Scalar control is valid only with legacy aperture mode scalar.'
    }
}

function Assert-LegacyVgaEvidencePairedPerformance {
    param([object[]]$Summaries)

    if ($null -eq $Summaries -or $Summaries.Count -ne 60) {
        throw 'Legacy VGA paired performance requires exactly 60 summaries.'
    }
    $records = @{}
    foreach ($summary in $Summaries) {
        foreach ($field in @(
            'schema', 'width', 'height', 'repetition', 'legacy_aperture_mode',
            'aperture_exits', 'presented_hz_milli', 'mmio_storm_observed',
            'legacy_aperture_histogram'
        )) {
            if ($null -eq $summary -or
                $summary.PSObject.Properties.Name -cnotcontains $field -or
                $null -eq $summary.$field) {
                throw "Legacy VGA paired performance summary field $field is missing."
            }
        }
        [uint64]$schema = ConvertTo-LegacyVgaEvidenceUInt64 `
            $summary.schema 'Legacy VGA paired performance schema'
        [uint64]$width = ConvertTo-LegacyVgaEvidenceUInt64 `
            $summary.width 'Legacy VGA paired performance width'
        [uint64]$height = ConvertTo-LegacyVgaEvidenceUInt64 `
            $summary.height 'Legacy VGA paired performance height'
        [uint64]$repetition = ConvertTo-LegacyVgaEvidenceUInt64 `
            $summary.repetition 'Legacy VGA paired performance repetition'
        [uint64]$exits = ConvertTo-LegacyVgaEvidenceUInt64 `
            $summary.aperture_exits 'Legacy VGA paired performance aperture exits'
        [uint64]$hzMilli = ConvertTo-LegacyVgaEvidenceUInt64 `
            $summary.presented_hz_milli 'Legacy VGA paired performance presented rate'
        [uint64]$dropped = ConvertTo-LegacyVgaEvidenceUInt64 `
            $summary.legacy_aperture_histogram.dropped `
            'Legacy VGA paired performance dropped histogram exits'
        $mode = [string]$summary.legacy_aperture_mode
        if ($schema -ne 1 -or $width -notin @(320, 360) -or
            $height -notin @(200, 240, 350, 400, 480) -or
            $repetition -lt 1 -or $repetition -gt 3 -or
            $mode -notin @('auto', 'scalar') -or $exits -eq 0 -or $dropped -ne 0 -or
            $summary.mmio_storm_observed -isnot [bool]) {
            throw 'Legacy VGA paired performance summary is invalid.'
        }
        if ($mode -ceq 'auto' -and $summary.mmio_storm_observed) {
            throw 'Legacy VGA auto performance contains an MMIO storm.'
        }
        if ($mode -ceq 'auto' -and $hzMilli -lt 55000) {
            throw 'Legacy VGA auto performance did not reach 55 presented frames per second.'
        }
        $key = "${width}x${height}:$repetition`:$mode"
        if ($records.ContainsKey($key)) {
            throw 'Legacy VGA paired performance contains a duplicate summary.'
        }
        $records.Add($key, [pscustomobject]@{
            exits = $exits
            presented_hz_milli = $hzMilli
        })
    }

    foreach ($width in @(320, 360)) {
        foreach ($height in @(200, 240, 350, 400, 480)) {
            foreach ($repetition in 1..3) {
                $scalarKey = "${width}x${height}:$repetition`:scalar"
                $autoKey = "${width}x${height}:$repetition`:auto"
                if (-not $records.ContainsKey($scalarKey) -or
                    -not $records.ContainsKey($autoKey)) {
                    throw 'Legacy VGA paired performance matrix is incomplete.'
                }
                $scalar = $records[$scalarKey]
                $auto = $records[$autoKey]
                if ([decimal]$scalar.exits -lt [decimal]$auto.exits * 10) {
                    throw 'Legacy VGA auto mode did not achieve a 10x aperture exit reduction.'
                }
            }
        }
    }
    return [pscustomobject]@{
        summaries = 60
        geometries = 10
        repetitions = 3
        scalar_controls = 30
        auto_runs = 30
    }
}

function Write-LegacyVgaEvidenceFileAtomic {
    param([string]$Path, [byte[]]$Bytes)

    $temporary = $Path + '.joining-' + [Guid]::NewGuid().ToString('N')
    try {
        Write-LegacyVgaEvidenceFileCreateNew $temporary $Bytes
        [IO.File]::Move($temporary, $Path, $true)
    } finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            [IO.File]::Delete($temporary)
        }
    }
}

function Assert-LegacyVgaEvidenceApertureHistogram {
    param([string]$Path, [string]$ExpectedMode)

    Assert-LegacyVgaEvidenceFile $Path 'Legacy aperture histogram'
    if ($ExpectedMode -cnotin @('auto', 'scalar')) {
        throw 'Legacy aperture histogram expected mode is invalid.'
    }
    $lines = @(Get-Content -LiteralPath $Path)
    if ($lines.Count -lt 8) {
        throw 'Legacy aperture histogram is incomplete.'
    }
    $metadataNames = @('schema', 'mode', 'capacity', 'rows', 'exits', 'retained', 'dropped')
    $metadata = @{}
    for ($index = 0; $index -lt $metadataNames.Count; $index += 1) {
        $fields = @(([string]$lines[$index]).Split("`t"))
        if ($fields.Count -ne 2 -or $fields[0] -cne $metadataNames[$index]) {
            throw 'Legacy aperture histogram metadata is malformed.'
        }
        $metadata[$fields[0]] = $fields[1]
    }
    if ($metadata.schema -cne 'legacy-aperture-histogram-v1' -or
        $metadata.mode -cne $ExpectedMode) {
        throw 'Legacy aperture histogram schema or mode is invalid.'
    }
    foreach ($name in @('capacity', 'rows', 'exits', 'retained', 'dropped')) {
        if ([string]$metadata[$name] -cnotmatch '^(0|[1-9][0-9]*)$') {
            throw 'Legacy aperture histogram counter is invalid.'
        }
    }
    try {
        [uint64]$capacity = $metadata.capacity
        [uint64]$rows = $metadata.rows
        [uint64]$exits = $metadata.exits
        [uint64]$retained = $metadata.retained
        [uint64]$dropped = $metadata.dropped
    } catch {
        throw 'Legacy aperture histogram counter is invalid.'
    }
    if ($capacity -ne 65536 -or $rows -lt 1 -or $rows -gt $capacity -or $exits -lt 1) {
        throw 'Legacy aperture histogram bounded metadata is invalid.'
    }
    if ($retained -gt [uint64]::MaxValue - $dropped -or $retained + $dropped -ne $exits) {
        throw 'Legacy aperture histogram accounting is inconsistent.'
    }
    if ($dropped -ne 0) {
        throw 'Legacy aperture histogram dropped exits.'
    }

    $header = 'instruction' + "`t" + 'operation' + "`t" + 'cs' + "`t" +
        'rip' + "`t" + 'gpa' + "`t" + 'layout' + "`t" + 'width' + "`t" +
        'height' + "`t" + 'pitch' + "`t" + 'aperture_base' + "`t" +
        'aperture_size' + "`t" + 'exits'
    if ([string]$lines[7] -cne $header) {
        throw 'Legacy aperture histogram row header is invalid.'
    }
    $rowLines = @()
    if ($lines.Count -gt 8) { $rowLines = @($lines[8..($lines.Count - 1)]) }
    if ([uint64]$rowLines.Count -ne $rows) {
        throw 'Legacy aperture histogram row count is inconsistent.'
    }
    [uint64]$rowExitSum = 0
    $patternCounts = [Collections.Generic.Dictionary[string, uint64]]::new(
        [StringComparer]::Ordinal
    )
    foreach ($line in $rowLines) {
        $fields = @(([string]$line).Split("`t"))
        if ($fields.Count -ne 12 -or
            $fields[0] -cnotmatch '^(?:[0-9a-f]{2}){0,15}$' -or
            $fields[1] -cnotin @(
                'Invalid', 'Scalar_Load', 'Scalar_Store_Register',
                'Scalar_Store_Immediate', 'Movs', 'Stos', 'Lods'
            ) -or
            $fields[2] -cnotmatch '^[0-9a-f]{4}$' -or
            $fields[3] -cnotmatch '^[0-9a-f]{16}$' -or
            $fields[4] -cnotmatch '^[0-9a-f]{16}$' -or
            $fields[5] -cnotin @('Unavailable', 'Indexed_Unchained') -or
            $fields[6] -cnotmatch '^(0|[1-9][0-9]*)$' -or
            $fields[7] -cnotmatch '^(0|[1-9][0-9]*)$' -or
            $fields[8] -cnotmatch '^(0|[1-9][0-9]*)$' -or
            $fields[9] -cnotmatch '^[0-9a-f]{16}$' -or
            $fields[10] -cnotmatch '^(0|[1-9][0-9]*)$' -or
            $fields[11] -cnotmatch '^[1-9][0-9]*$') {
            throw 'Legacy aperture histogram row is malformed.'
        }
        try { [uint64]$rowExits = $fields[11] } catch {
            throw 'Legacy aperture histogram row exit count is invalid.'
        }
        if ($rowExitSum -gt [uint64]::MaxValue - $rowExits) {
            throw 'Legacy aperture histogram row exit count is invalid.'
        }
        $rowExitSum += $rowExits
        $patternKey = @(
            $fields[0], $fields[1], $fields[2], $fields[3],
            $fields[5], $fields[6], $fields[7], $fields[8],
            $fields[9], $fields[10]
        ) -join "`t"
        [uint64]$patternExits = 0
        if ($patternCounts.TryGetValue($patternKey, [ref]$patternExits)) {
            if ($patternExits -gt [uint64]::MaxValue - $rowExits) {
                throw 'Legacy aperture histogram pattern count is invalid.'
            }
            $patternCounts[$patternKey] = $patternExits + $rowExits
        } else {
            $patternCounts.Add($patternKey, $rowExits)
        }
    }
    if ($rowExitSum -ne $retained) {
        throw 'Legacy aperture histogram accounting is inconsistent.'
    }
    $rankedPatterns = @($patternCounts.GetEnumerator() | Sort-Object `
        @{ Expression = { $_.Value }; Descending = $true }, `
        @{ Expression = { $_.Key }; Descending = $false })
    [uint64]$targetExits = [decimal]::Ceiling(([decimal]$exits * 9) / 10)
    [uint64]$attributedExits = 0
    $patternsToTarget = 0
    foreach ($pattern in $rankedPatterns) {
        if ($attributedExits -ge $targetExits) { break }
        $attributedExits += [uint64]$pattern.Value
        $patternsToTarget += 1
    }
    $attributedBasisPoints = [int][decimal]::Floor(
        ([decimal]$attributedExits * 10000) / [decimal]$exits
    )
    return [pscustomobject]@{
        mode = $ExpectedMode
        capacity = $capacity
        rows = $rows
        exits = $exits
        retained = $retained
        dropped = $dropped
        patterns = $patternCounts.Count
        patterns_to_90_percent = $patternsToTarget
        attributed_exits = $attributedExits
        attributed_basis_points = $attributedBasisPoints
    }
}

function ConvertTo-LegacyVgaEvidenceUInt64 {
    param([object]$Value, [string]$Label)

    $text = [string]$Value
    [uint64]$parsed = 0
    if ($text -notmatch '^\d+$' -or -not [uint64]::TryParse(
        $text,
        [Globalization.NumberStyles]::None,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$parsed
    )) {
        throw "$Label is not an unsigned integer."
    }
    return $parsed
}

function Assert-LegacyVgaEvidenceHostMetrics {
    param(
        [string]$Path,
        [string]$ExpectedMode,
        [int]$ExpectedWidth,
        [int]$ExpectedHeight
    )

    Assert-LegacyVgaEvidenceFile $Path 'Legacy VGA host metrics'
    if ($ExpectedMode -notin @('auto', 'scalar')) {
        throw 'Legacy VGA host metrics expected mode is invalid.'
    }
    $rows = @(Import-Csv -LiteralPath $Path -Delimiter "`t")
    if ($rows.Count -ne 3) {
        throw 'Legacy VGA host metrics must contain exactly three rows.'
    }
    $required = @(
        'schema', 'record', 'mode', 'label', 'valid', 'time_ns', 'width', 'height',
        'owner_generation', 'mode_generation', 'surface_generation',
        'content_generation', 'elapsed_ns', 'sample_count', 'presented_frames',
        'presented_hz_milli', 'aperture_exits', 'counter_regressions', 'complete'
    )
    foreach ($name in $required) {
        if ($rows[0].PSObject.Properties.Name -notcontains $name) {
            throw "Legacy VGA host metrics are missing field $name."
        }
    }
    $byRecord = @{}
    foreach ($row in $rows) {
        if ([string]$row.schema -cne '1' -or [string]$row.mode -cne $ExpectedMode) {
            throw 'Legacy VGA host metrics schema or mode does not match.'
        }
        $record = [string]$row.record
        if ($record -notin @('pre-pif', 'desktop-restored', 'performance') -or
            $byRecord.ContainsKey($record)) {
            throw 'Legacy VGA host metrics record set is invalid.'
        }
        $byRecord.Add($record, $row)
    }
    foreach ($record in @('pre-pif', 'desktop-restored', 'performance')) {
        if (-not $byRecord.ContainsKey($record)) {
            throw "Legacy VGA host metrics are missing $record."
        }
    }

    $normalized = @{}
    foreach ($record in @('pre-pif', 'desktop-restored', 'performance')) {
        $row = $byRecord[$record]
        $entry = [ordered]@{}
        foreach ($field in @(
            'label', 'valid', 'time_ns', 'width', 'height', 'owner_generation',
            'mode_generation', 'surface_generation', 'content_generation',
            'elapsed_ns', 'sample_count', 'presented_frames', 'presented_hz_milli',
            'aperture_exits', 'counter_regressions', 'complete'
        )) {
            $entry[$field] = ConvertTo-LegacyVgaEvidenceUInt64 `
                $row.$field "Legacy VGA host metrics $record $field"
        }
        $normalized[$record] = [pscustomobject]$entry
    }

    $pre = $normalized['pre-pif']
    $post = $normalized['desktop-restored']
    $performance = $normalized['performance']
    foreach ($capture in @(
        @($pre, [uint64]$script:LegacyVgaEvidencePreCapture, 'pre-pif'),
        @($post, [uint64]$script:LegacyVgaEvidencePostCapture, 'desktop-restored')
    )) {
        $row = $capture[0]
        $expectedLabel = [uint64]$capture[1]
        $record = [string]$capture[2]
        if ($row.valid -ne 1 -or $row.label -ne $expectedLabel -or
            $row.width -ne 800 -or $row.height -ne 600 -or
            $row.owner_generation -eq 0 -or $row.mode_generation -eq 0 -or
            $row.surface_generation -eq 0 -or $row.content_generation -eq 0) {
            throw "Legacy VGA host metrics $record capture is invalid."
        }
    }
    if ($pre.mode_generation -eq $post.mode_generation) {
        throw 'Legacy VGA host metrics did not observe a new restored desktop mode generation.'
    }
    if ($performance.valid -ne 1 -or $performance.complete -ne 1) {
        throw 'Legacy VGA host metrics performance window is incomplete.'
    }
    if ($performance.label -ne 0 -or
        $performance.width -ne [uint64]$ExpectedWidth -or
        $performance.height -ne [uint64]$ExpectedHeight) {
        throw 'Legacy VGA host metrics performance geometry does not match the requested mode.'
    }
    if ($performance.owner_generation -eq 0 -or $performance.mode_generation -eq 0 -or
        $performance.surface_generation -eq 0 -or
        $performance.elapsed_ns -lt 10000000000 -or
        $performance.sample_count -eq 0 -or
        $performance.presented_frames -gt $performance.sample_count -or
        $performance.aperture_exits -eq 0 -or
        $performance.counter_regressions -ne 0) {
        throw 'Legacy VGA host metrics performance counters are invalid.'
    }
    $expectedHzMilli = [uint64][decimal]::Floor(
        ([decimal]$performance.presented_frames * 1000000000000) /
        [decimal]$performance.elapsed_ns
    )
    if ($performance.presented_hz_milli -ne $expectedHzMilli) {
        throw 'Legacy VGA host metrics presented rate is inconsistent.'
    }
    return [pscustomobject]@{
        mode = $ExpectedMode
        pre = $pre
        post = $post
        performance = $performance
    }
}

function Assert-LegacyVgaEvidencePerformanceWindow {
    param([object]$Histogram, [object]$HostMetrics)

    if ($null -eq $Histogram -or $null -eq $HostMetrics -or
        $Histogram.PSObject.Properties.Name -cnotcontains 'mode' -or
        $Histogram.PSObject.Properties.Name -cnotcontains 'exits' -or
        $HostMetrics.PSObject.Properties.Name -cnotcontains 'mode' -or
        $HostMetrics.PSObject.Properties.Name -cnotcontains 'performance' -or
        $null -eq $HostMetrics.performance -or
        $HostMetrics.performance.PSObject.Properties.Name -cnotcontains 'aperture_exits') {
        throw 'Legacy VGA performance window join is incomplete.'
    }
    if ([string]$Histogram.mode -cne [string]$HostMetrics.mode) {
        throw 'Legacy VGA histogram mode does not match the performance window.'
    }
    [uint64]$histogramExits = ConvertTo-LegacyVgaEvidenceUInt64 `
        $Histogram.exits 'Legacy VGA histogram window exits'
    [uint64]$performanceExits = ConvertTo-LegacyVgaEvidenceUInt64 `
        $HostMetrics.performance.aperture_exits 'Legacy VGA performance window exits'
    if ($histogramExits -eq 0 -or $histogramExits -ne $performanceExits) {
        throw 'Legacy VGA histogram exit count does not match the performance window.'
    }
}

function Join-LegacyVgaEvidenceGuestReport {
    param(
        [string]$Path,
        [pscustomobject]$HostMetrics,
        [string]$ShutdownMarkerCompletion
    )

    if ($ShutdownMarkerCompletion -cne 'd5-through-dc') {
        throw 'Legacy VGA shutdown marker completion is invalid.'
    }
    Assert-LegacyVgaEvidenceGuestReport $Path -AllowHostJoinRequired
    $rows = @(Import-Csv -LiteralPath $Path -Delimiter "`t")
    $columns = @(
        'schema', 'case', 'mode', 'width', 'height', 'repetition', 'phase',
        'owner_generation', 'mode_generation', 'surface_generation',
        'aperture_exits', 'presented_hz', 'desktop_sentinel_crc',
        'shutdown_marker_completion', 'status', 'reason'
    )
    $hz = ([decimal]$HostMetrics.performance.presented_hz_milli / 1000).ToString(
        '0.000',
        [Globalization.CultureInfo]::InvariantCulture
    )
    foreach ($row in $rows) {
        switch ([string]$row.phase) {
            'pre-pif' {
                $identity = $HostMetrics.pre
                $row.aperture_exits = '0'
                $row.presented_hz = '0.000'
            }
            'desktop-restored' {
                $identity = $HostMetrics.post
                $row.aperture_exits = [string]$HostMetrics.performance.aperture_exits
                $row.presented_hz = $hz
            }
            'terminal' {
                $identity = $HostMetrics.post
                $row.aperture_exits = [string]$HostMetrics.performance.aperture_exits
                $row.presented_hz = $hz
            }
            default {
                throw "Legacy VGA guest report phase is invalid: $($row.phase)."
            }
        }
        $row.owner_generation = [string]$identity.owner_generation
        $row.mode_generation = [string]$identity.mode_generation
        $row.surface_generation = [string]$identity.surface_generation
        $row.shutdown_marker_completion = $ShutdownMarkerCompletion
    }
    $lines = [Collections.Generic.List[string]]::new($rows.Count + 1)
    [void]$lines.Add(($columns -join "`t"))
    foreach ($row in $rows) {
        [void]$lines.Add((@($columns | ForEach-Object { [string]$row.$_ }) -join "`t"))
    }
    return ($lines -join "`r`n") + "`r`n"
}

function Assert-LegacyVgaEvidenceGuestReport {
    param([string]$Path, [switch]$AllowHostJoinRequired)

    Assert-LegacyVgaEvidenceFile $Path 'Legacy VGA guest report'
    $rows = @(Import-Csv -LiteralPath $Path -Delimiter "`t")
    if ($rows.Count -ne 3) {
        throw 'Legacy VGA guest report must contain exactly three rows.'
    }
    $columns = @(
        'schema', 'case', 'mode', 'width', 'height', 'repetition', 'phase',
        'owner_generation', 'mode_generation', 'surface_generation',
        'aperture_exits', 'presented_hz', 'desktop_sentinel_crc',
        'shutdown_marker_completion', 'status', 'reason'
    )
    foreach ($column in $columns) {
        if ($rows[0].PSObject.Properties.Name -cnotcontains $column) {
            throw "Legacy VGA guest report is missing field $column."
        }
    }
    $phaseContracts = @(
        @('pre-pif', 'INFO', 'launching-exact-pif'),
        @('desktop-restored', 'PASS', 'pif-returned'),
        @('terminal', 'PASS', 'launcher-complete')
    )
    [uint64]$width = ConvertTo-LegacyVgaEvidenceUInt64 `
        $rows[0].width 'Legacy VGA guest report width'
    [uint64]$height = ConvertTo-LegacyVgaEvidenceUInt64 `
        $rows[0].height 'Legacy VGA guest report height'
    [uint64]$repetition = ConvertTo-LegacyVgaEvidenceUInt64 `
        $rows[0].repetition 'Legacy VGA guest report repetition'
    if ([string]$rows[0].schema -cne '1' -or
        $width -notin @(320, 360) -or $height -notin @(200, 240, 350, 400, 480) -or
        $repetition -lt 1 -or $repetition -gt 99 -or
        [string]$rows[0].desktop_sentinel_crc -notmatch '^[0-9A-F]{8}$') {
        throw 'Legacy VGA guest report common contract is invalid.'
    }
    Assert-LegacyVgaEvidenceToken ([string]$rows[0].case) 'Guest report case'
    Assert-LegacyVgaEvidenceToken ([string]$rows[0].mode) 'Guest report mode'
    for ($index = 0; $index -lt $rows.Count; $index += 1) {
        $row = $rows[$index]
        $contract = $phaseContracts[$index]
        foreach ($field in @(
            'schema', 'case', 'mode', 'width', 'height', 'repetition',
            'desktop_sentinel_crc'
        )) {
            if ([string]$row.$field -cne [string]$rows[0].$field) {
                throw 'Legacy VGA guest report rows do not describe the same case.'
            }
        }
        if ([string]$row.phase -cne $contract[0] -or
            [string]$row.status -cne $contract[1] -or
            [string]$row.reason -cne $contract[2]) {
            throw 'Legacy VGA guest report phase contract is invalid.'
        }
        foreach ($field in @(
            'owner_generation', 'mode_generation', 'surface_generation',
            'aperture_exits', 'presented_hz'
        )) {
            $value = [string]$row.$field
            if ($AllowHostJoinRequired) {
                if ($value -cne 'host-join-required') {
                    throw "Legacy VGA raw guest report $field is not awaiting the host join."
                }
            } elseif ($value -ceq 'host-join-required' -or [string]::IsNullOrWhiteSpace($value)) {
                throw "Legacy VGA guest report retained an unresolved $field."
            }
        }
        if (-not $AllowHostJoinRequired) {
            foreach ($field in @(
                'owner_generation', 'mode_generation', 'surface_generation',
                'aperture_exits'
            )) {
                $parsed = ConvertTo-LegacyVgaEvidenceUInt64 `
                    $row.$field "Legacy VGA guest report $field"
                if ($field -ne 'aperture_exits' -and $parsed -eq 0) {
                    throw "Legacy VGA guest report $field is zero."
                }
            }
            if ([string]$row.presented_hz -notmatch '^\d+\.\d{3}$') {
                throw 'Legacy VGA guest report presented_hz is invalid.'
            }
        }
        if ($AllowHostJoinRequired) {
            if ([string]$row.shutdown_marker_completion -cne 'pending') {
                throw 'Legacy VGA raw guest report shutdown completion is invalid.'
            }
        } elseif ([string]$row.shutdown_marker_completion -cne 'd5-through-dc') {
            throw 'Legacy VGA guest report shutdown completion is unresolved.'
        }
    }
    $terminal = $rows[$rows.Count - 1]
    if ([string]$terminal.phase -cne 'terminal' -or
        [string]$terminal.status -cne 'PASS') {
        throw "Legacy VGA guest report terminal row is not PASS."
    }
}

function Assert-LegacyVgaEvidenceCaptures {
    param([string]$Artifacts)

    foreach ($name in @(
        "snapshot-$($script:LegacyVgaEvidencePreCapture).png",
        "composed-$($script:LegacyVgaEvidencePreCapture).png",
        "snapshot-$($script:LegacyVgaEvidencePostCapture).png",
        "composed-$($script:LegacyVgaEvidencePostCapture).png",
        'captures.tsv'
    )) {
        Assert-LegacyVgaEvidenceFile (Join-Path $Artifacts $name) "Capture artifact $name"
    }
}

function Write-LegacyVgaEvidenceJsonCreateNew {
    param([string]$Path, [object]$Value)

    $json = ($Value | ConvertTo-Json -Depth 12) + "`r`n"
    [byte[]]$bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
    Write-LegacyVgaEvidenceFileCreateNew $Path $bytes
}

if ($DefineFunctionsOnly) { return }

Assert-LegacyVgaEvidenceScalarControl $LegacyApertureMode $ScalarControl.IsPresent

foreach ($required in @(
    @($SourceProfile, 'Source profile'),
    @($DisposableProfile, 'Disposable profile'),
    @($EvidenceDirectory, 'Evidence directory'),
    @($PifFile, 'Fullscreen Quake PIF'),
    @($KnownGoodRegFile, 'Known-good REG'),
    @($KnownGoodAutoexecFile, 'Known-good AUTOEXEC'),
    @($HostExecutable, 'Host executable'),
    @($GuestImportExecutable, 'guest-import executable'),
    @($LauncherStageExecutable, 'launcher-stage executable'),
    @($PifLauncherExecutable, 'PIF launcher executable'),
    @($CandidateDriverRoot, 'Candidate driver root'),
    @($Case, 'Case'),
    @($Mode, 'Mode'),
    @($ExpectedDesktopSentinelCrc, 'Expected desktop sentinel CRC'),
    @($QuakeArguments, 'Quake arguments')
)) {
    Assert-LegacyVgaEvidenceRequiredText ([string]$required[0]) ([string]$required[1])
}

$sourcePath = Get-LegacyVgaEvidenceFullPath $SourceProfile 'Source profile'
$profilePath = Get-LegacyVgaEvidenceFullPath $DisposableProfile 'Disposable profile'
$evidencePath = Get-LegacyVgaEvidenceFullPath $EvidenceDirectory 'Evidence directory'
$pifPath = Get-LegacyVgaEvidenceFullPath $PifFile 'Fullscreen Quake PIF'
$regPath = Get-LegacyVgaEvidenceFullPath $KnownGoodRegFile 'Known-good REG'
$autoexecPath = Get-LegacyVgaEvidenceFullPath $KnownGoodAutoexecFile 'Known-good AUTOEXEC'
$hostPath = Get-LegacyVgaEvidenceFullPath $HostExecutable 'Host executable'
$importPath = Get-LegacyVgaEvidenceFullPath $GuestImportExecutable 'guest-import executable'
$launcherPath = Get-LegacyVgaEvidenceFullPath $LauncherStageExecutable 'launcher-stage executable'
$launcherIdentity = Assert-LegacyVgaEvidenceLauncherStageFile $launcherPath
$pifLauncherPath = Get-LegacyVgaEvidenceFullPath `
    $PifLauncherExecutable 'PIF launcher executable'
$candidateDriverPath = Get-LegacyVgaEvidenceFullPath `
    $CandidateDriverRoot 'Candidate driver root'
if (-not $ValidateOnly) {
    Assert-LegacyVgaEvidenceTemporaryPath $candidateDriverPath 'Candidate driver root'
}
$candidateDrivers = Get-LegacyVgaEvidenceCandidateDrivers $candidateDriverPath
$pifLauncherIdentity = Assert-LegacyVgaEvidencePifLauncherFile $pifLauncherPath
Assert-LegacyVgaEvidenceTemporaryPath $profilePath 'Disposable profile'
Assert-LegacyVgaEvidenceTemporaryPath $evidencePath 'Evidence directory'
if ((Test-LegacyVgaEvidencePathWithin $profilePath $sourcePath) -or
    (Test-LegacyVgaEvidencePathWithin $sourcePath $profilePath) -or
    (Test-LegacyVgaEvidencePathWithin $profilePath $evidencePath) -or
    (Test-LegacyVgaEvidencePathWithin $evidencePath $profilePath) -or
    $profilePath.Equals($sourcePath, [StringComparison]::OrdinalIgnoreCase) -or
    $profilePath.Equals($evidencePath, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Source, disposable profile, and evidence paths must not overlap.'
}
if (Test-Path -LiteralPath $profilePath) {
    throw "Refusing to replace disposable profile state: $profilePath"
}
if (Test-Path -LiteralPath $evidencePath) {
    throw "Refusing to replace retained evidence: $evidencePath"
}

foreach ($tool in @(
    @($hostPath, 'Host executable'),
    @($importPath, 'guest-import executable'),
    @($launcherPath, 'launcher-stage executable'),
    @($pifLauncherPath, 'PIF launcher executable')
)) {
    Assert-LegacyVgaEvidenceFile ([string]$tool[0]) ([string]$tool[1])
}
$fat32Helper = Join-Path (Split-Path -Parent $hostPath) 'retvrn99-fat32.exe'
Assert-LegacyVgaEvidenceFile $fat32Helper 'Host FAT32 sidecar'

if ([string]::IsNullOrWhiteSpace($NasmExecutable)) {
    $nasmCommand = Get-Command nasm -ErrorAction SilentlyContinue
    if ($null -eq $nasmCommand) { throw 'NASM must be supplied or available on PATH.' }
    $NasmExecutable = $nasmCommand.Source
}
$nasmPath = Get-LegacyVgaEvidenceFullPath $NasmExecutable 'NASM executable'
Assert-LegacyVgaEvidenceFile $nasmPath 'NASM executable'
$kateaTemplate = Join-Path $PSScriptRoot 'legacy-vga-evidence-katea.asm'
Assert-LegacyVgaEvidenceFile $kateaTemplate 'Katea reporter template'

foreach ($name in @('c_drive.img', 'cmos.bin', 'install-state.json', 'settings.json')) {
    Assert-LegacyVgaEvidenceFile (Join-Path $sourcePath $name) "Source profile $name"
}
$pifIdentity = Assert-LegacyVgaEvidencePifFile $pifPath
Assert-LegacyVgaEvidenceToken $Case 'Case'
Assert-LegacyVgaEvidenceToken $Mode 'Mode'
Assert-LegacyVgaEvidenceQuakeArguments $QuakeArguments
$sentinel = Get-LegacyVgaEvidenceSentinel `
    $SentinelX $SentinelY $SentinelWidth $SentinelHeight `
    $ExpectedDesktopSentinelCrc
$payloads = New-LegacyVgaEvidenceReportPayloads `
    $Case $Mode $Width $Height $Repetition $sentinel.CrcHex
$guestPifWindows = ConvertTo-LegacyVgaEvidenceGuestPath $GuestPifPath 'Guest PIF path'
$guestPifLauncherWindows = ConvertTo-LegacyVgaEvidenceGuestPath `
    $GuestPifLauncherPath 'Guest PIF launcher path'
if ($guestPifWindows -cne 'C:\QUAKE\QUAKEPIF.PIF' -or
    $guestPifLauncherWindows -cne 'C:\QUAKE\PIFRUN.EXE') {
    throw 'The test-only PIF launcher requires its fixed approved guest paths.'
}
$guestBatchWindows = ConvertTo-LegacyVgaEvidenceGuestPath $GuestBatchPath 'Guest batch path'
$guestHelperWindows = ConvertTo-LegacyVgaEvidenceGuestPath $GuestHelperPath 'Guest helper path'
$guestRegWindows = ConvertTo-LegacyVgaEvidenceGuestPath $GuestRegPath 'Guest REG path'
$null = Assert-LegacyVgaEvidenceAutoexec $autoexecPath $guestRegWindows
[byte[]]$knownRegBytes = [IO.File]::ReadAllBytes($regPath)
[byte[]]$derivedRegBytes = Get-LegacyVgaEvidenceDerivedRegBytes `
    $knownRegBytes $guestBatchWindows
$batchText = New-LegacyVgaEvidenceBatchText `
    $guestPifWindows $guestPifLauncherWindows $guestHelperWindows $QuakeArguments
$quakeExitConfigText = New-LegacyVgaEvidenceQuakeExitConfig
[byte[]]$quakeExitConfigBytes = Get-LegacyVgaEvidenceAsciiBytes $quakeExitConfigText
$quakeExitConfigIdentity = [ordered]@{
    guest_path = $script:LegacyVgaEvidenceQuakeExitConfigPath
    wait_frames = $script:LegacyVgaEvidenceQuakeExitWaitFrames
    bytes = $quakeExitConfigBytes.Length
    sha256 = Get-LegacyVgaEvidenceSha256 $quakeExitConfigBytes
}
$sourceDisk = Join-Path $sourcePath 'c_drive.img'
$sourceDiskHashBefore = (Get-FileHash -LiteralPath $sourceDisk -Algorithm SHA256).Hash

if ($ValidateOnly) {
    [pscustomobject]@{
        validated = $true
        guest_run_authorized = $false
        scalar_control = $ScalarControl.IsPresent
        source_profile = $sourcePath
        disposable_profile = $profilePath
        evidence_directory = $evidencePath
        source_disk_sha256 = $sourceDiskHashBefore
        pif_bytes = $pifIdentity.bytes
        pif_sha256 = $pifIdentity.sha256
        guest_pif = $guestPifWindows
        guest_pif_launcher = $guestPifLauncherWindows
        pif_launcher_bytes = $pifLauncherIdentity.bytes
        pif_launcher_sha256 = $pifLauncherIdentity.sha256
        launcher_stage_bytes = $launcherIdentity.bytes
        launcher_stage_sha256 = $launcherIdentity.sha256
        guest_batch = $guestBatchWindows
        guest_helper = $guestHelperWindows
        quake_exit_config = $quakeExitConfigIdentity
        candidate_drivers = $candidateDrivers
        desktop_sentinel = $sentinel
        host_arguments = @(
            '--start', '--test-device', '--strict-io',
            '--guest-report-kind:legacy-vga', '--shutdown-trace',
            "--legacy-aperture-mode:$LegacyApertureMode"
        )
    }
    return
}

if (-not $GuestRunAuthorized) {
    throw 'Guest execution requires fresh explicit approval and -GuestRunAuthorized.'
}
$active = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.ProcessName -like 'retvrn99*'
})
if ($active.Count -ne 0) {
    throw 'A RETVRN99 process is already active.'
}

[void][IO.Directory]::CreateDirectory($profilePath)
[void][IO.Directory]::CreateDirectory($evidencePath)
    $stagePath = Join-Path $evidencePath 'stage'
    [void][IO.Directory]::CreateDirectory($stagePath)
    Write-LegacyVgaEvidenceJsonCreateNew `
        (Join-Path $evidencePath 'candidate-drivers.json') $candidateDrivers
$primaryError = $null
$sourceDiskHashAfter = $null
$hostExit = $null
$stopReason = $null
$resultExit = $null
$helperIdentity = $null

try {
    foreach ($name in @('c_drive.img', 'cmos.bin', 'install-state.json')) {
        Copy-Item -LiteralPath (Join-Path $sourcePath $name) `
            -Destination (Join-Path $profilePath $name)
    }
    $cloneDisk = Join-Path $profilePath 'c_drive.img'
    $cloneHash = (Get-FileHash -LiteralPath $cloneDisk -Algorithm SHA256).Hash
    if ($cloneHash -cne $sourceDiskHashBefore) {
        throw 'Disposable disk does not match the source disk before staging.'
    }

    $settings = Get-Content -Raw -LiteralPath (Join-Path $sourcePath 'settings.json') |
        ConvertFrom-Json
    $settings.hard_drive_path = $cloneDisk
    $settings.cdrom_path = ''
    $settings.floppy_path = ''
    $settingsJson = ($settings | ConvertTo-Json -Depth 16) + "`r`n"
    [IO.File]::WriteAllText(
        (Join-Path $profilePath 'settings.json'),
        $settingsJson,
        [Text.UTF8Encoding]::new($false)
    )
    $roundTrip = Get-Content -Raw -LiteralPath (Join-Path $profilePath 'settings.json') |
        ConvertFrom-Json
    if ([string]$roundTrip.hard_drive_path -cne $cloneDisk -or
        [string]$roundTrip.cdrom_path -cne '' -or
        [string]$roundTrip.floppy_path -cne '') {
        throw 'Disposable profile disk binding failed its read-back check.'
    }

    $stagedPif = Join-Path $stagePath 'legacy-vga-evidence-quake.pif'
    Copy-Item -LiteralPath $pifPath -Destination $stagedPif
    $stagedPifLauncher = Join-Path $stagePath 'legacy-vga-evidence-pif-runner.exe'
    Copy-Item -LiteralPath $pifLauncherPath -Destination $stagedPifLauncher
    $stagedBatch = Join-Path $stagePath 'legacy-vga-evidence-run.bat'
    Write-LegacyVgaEvidenceFileCreateNew `
        $stagedBatch (Get-LegacyVgaEvidenceAsciiBytes $batchText)
    $stagedQuakeExitConfig = Join-Path $stagePath 'legacy-vga-evidence-quake-exit.cfg'
    Write-LegacyVgaEvidenceFileCreateNew `
        $stagedQuakeExitConfig $quakeExitConfigBytes
    $stagedReg = Join-Path $stagePath 'legacy-vga-evidence-driver.reg'
    Write-LegacyVgaEvidenceFileCreateNew $stagedReg $derivedRegBytes
    $stagedAutoexec = Join-Path $stagePath 'legacy-vga-evidence-autoexec.bat'
    Copy-Item -LiteralPath $autoexecPath -Destination $stagedAutoexec
    $helperIdentity = Build-LegacyVgaEvidenceKateaHelper `
        $stagePath $nasmPath $kateaTemplate $payloads $sentinel

    $importArguments = @(
        $cloneDisk
    )
    foreach ($driver in $candidateDrivers) {
        $importArguments += @($driver.source, $driver.guest_path)
    }
    $importArguments += @(
        $stagedPif, $GuestPifPath,
        $stagedPifLauncher, $GuestPifLauncherPath,
        $stagedBatch, $GuestBatchPath,
        $stagedQuakeExitConfig, $script:LegacyVgaEvidenceQuakeExitConfigPath,
        $helperIdentity.Path, $GuestHelperPath
    )
    & $importPath @importArguments
    if ($LASTEXITCODE -ne 0) {
        throw "guest-import failed with exit $LASTEXITCODE."
    }
    $launcherArguments = New-LegacyVgaEvidenceLauncherArguments `
        $cloneDisk $stagedReg $stagedAutoexec $guestRegWindows
    & $launcherPath @launcherArguments
    if ($LASTEXITCODE -ne 0) {
        throw "launcher staging failed with exit $LASTEXITCODE."
    }
    $sourceDiskHashBeforeLaunch =
        (Get-FileHash -LiteralPath $sourceDisk -Algorithm SHA256).Hash
    if ($sourceDiskHashBeforeLaunch -cne $sourceDiskHashBefore) {
        throw 'Source disk changed during disposable staging.'
    }

    $resultPath = Join-Path $evidencePath 'result.json'
    $artifactsPath = Join-Path $evidencePath 'artifacts'
    $stdoutPath = Join-Path $evidencePath 'console.stdout.log'
    $stderrPath = Join-Path $evidencePath 'console.stderr.log'
    $hostArguments = @(
        '--start',
        '--test-device',
        '--strict-io',
        '--guest-report-kind:legacy-vga',
        '--shutdown-trace',
        "--legacy-aperture-mode:$LegacyApertureMode",
        "--profile-root:$profilePath",
        "--seconds:$Seconds",
        "--result-json:$resultPath",
        "--artifacts:$artifactsPath"
    )
    $process = Start-Process -FilePath $hostPath -ArgumentList $hostArguments `
        -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    $hostExit = [int]$process.ExitCode
    if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
        throw "Host exit $hostExit produced no result.json."
    }
    $result = Get-Content -Raw -LiteralPath $resultPath | ConvertFrom-Json
    $stopReason = [string]$result.stop_reason
    $resultExit = [int]$result.exit_code
    Assert-LegacyVgaEvidenceResult $result $hostExit
    Assert-LegacyVgaEvidenceLogs `
        @($stdoutPath, $stderrPath) -AllowMmioStorm:$ScalarControl.IsPresent
    $mmioStormObserved = @(
        Select-String -LiteralPath @($stdoutPath, $stderrPath) `
            -Pattern 'MMIO exit storm' -SimpleMatch -ErrorAction Stop
    ).Count -ne 0
    $guestReportPath = Join-Path $artifactsPath $script:LegacyVgaEvidenceReportName
    Assert-LegacyVgaEvidenceGuestReport $guestReportPath -AllowHostJoinRequired
    $rawGuestReportPath = Join-Path $artifactsPath 'legacy-vga-result.guest.tsv'
    Write-LegacyVgaEvidenceFileCreateNew `
        $rawGuestReportPath ([IO.File]::ReadAllBytes($guestReportPath))
    Assert-LegacyVgaEvidenceCaptures $artifactsPath
    Assert-LegacyVgaEvidenceShutdownTrace `
        (Join-Path $artifactsPath $script:LegacyVgaEvidenceShutdownTraceName)
    $hostMetrics = Assert-LegacyVgaEvidenceHostMetrics `
        (Join-Path $artifactsPath 'legacy-vga-host-metrics.tsv') `
        $LegacyApertureMode $Width $Height
    if ($LegacyApertureMode -ceq 'auto' -and
        $hostMetrics.performance.presented_hz_milli -lt 55000) {
        throw 'Legacy VGA auto performance did not reach 55 presented frames per second.'
    }
    $apertureHistogram = Assert-LegacyVgaEvidenceApertureHistogram `
        (Join-Path $artifactsPath 'legacy-aperture-histogram.tsv') `
        $LegacyApertureMode
    Assert-LegacyVgaEvidencePerformanceWindow $apertureHistogram $hostMetrics
    $joinedGuestReport = Join-LegacyVgaEvidenceGuestReport `
        $guestReportPath $hostMetrics 'd5-through-dc'
    Write-LegacyVgaEvidenceFileAtomic `
        $guestReportPath ([Text.UTF8Encoding]::new($false).GetBytes($joinedGuestReport))
    Assert-LegacyVgaEvidenceGuestReport $guestReportPath

    $summary = [ordered]@{
        schema = 1
        case = $Case
        mode = $Mode
        width = $Width
        height = $Height
        repetition = $Repetition
        legacy_aperture_mode = $LegacyApertureMode
        scalar_control = $ScalarControl.IsPresent
        mmio_storm_observed = $mmioStormObserved
        legacy_aperture_histogram = $apertureHistogram
        legacy_vga_host_metrics = [ordered]@{
            pre = $hostMetrics.pre
            desktop_restored = $hostMetrics.post
            performance = $hostMetrics.performance
        }
        aperture_exits = $hostMetrics.performance.aperture_exits
        presented_hz_milli = $hostMetrics.performance.presented_hz_milli
        host_exit = $hostExit
        stop_reason = $stopReason
        result_exit_code = $resultExit
        source_disk_sha256 = $sourceDiskHashBefore
        desktop_sentinel = [ordered]@{
            x = $sentinel.X
            y = $sentinel.Y
            width = $sentinel.Width
            height = $sentinel.Height
            crc32 = $sentinel.CrcHex
            verified_before_pif = $true
            verified_after_pif = $true
        }
        pif = $pifIdentity
        candidate_drivers = $candidateDrivers
        katea_helper = [ordered]@{
            bytes = $helperIdentity.Bytes
            sha256 = $helperIdentity.Sha256
            production_abi_added = $false
        }
        quake_exit_config = $quakeExitConfigIdentity
        shutdown_marker_completion = 'd5-through-dc'
        apm_power_off = $true
    }
    Write-LegacyVgaEvidenceJsonCreateNew `
        (Join-Path $evidencePath 'legacy-vga-evidence-summary.json') $summary
} catch {
    $primaryError = $_
} finally {
    $sourceDiskHashAfter = (Get-FileHash -LiteralPath $sourceDisk -Algorithm SHA256).Hash
    $integrity = [ordered]@{
        schema = 1
        source_disk = $sourceDisk
        before_sha256 = $sourceDiskHashBefore
        after_sha256 = $sourceDiskHashAfter
        unchanged = ($sourceDiskHashAfter -ceq $sourceDiskHashBefore)
    }
    try {
        Write-LegacyVgaEvidenceJsonCreateNew `
            (Join-Path $evidencePath 'source-disk-integrity.json') $integrity
    } catch {
        if ($null -eq $primaryError) { $primaryError = $_ }
    }
}

if ($sourceDiskHashAfter -cne $sourceDiskHashBefore) {
    throw 'Source guest disk changed during the disposable evidence run.'
}
if ($null -ne $primaryError) { throw $primaryError }

Write-Output (
    "PASS legacy-vga-evidence case=$Case mode=$Mode geometry=${Width}x${Height} " +
    "repetition=$Repetition power_off/0 source_unchanged=true evidence=$evidencePath"
)
