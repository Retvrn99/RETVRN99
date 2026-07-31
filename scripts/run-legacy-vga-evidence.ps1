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
    [ValidateRange(90, 900)]
    [int]$Seconds = 180,
    [string]$GuestPifPath = 'QUAKE/QUAKEPIF.PIF',
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
    if ($Arguments -notmatch '(?i)(?:^|\s)\+quit(?:\s|$)') {
        throw 'Quake arguments must contain +quit so the PIF return is bounded.'
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
        [string]$HelperWindowsPath,
        [string]$Arguments
    )

    Assert-LegacyVgaEvidenceQuakeArguments $Arguments
    $lines = @(
        '@ECHO OFF',
        "$HelperWindowsPath P",
        'IF ERRORLEVEL 2 GOTO SHUTDOWN',
        'IF ERRORLEVEL 1 GOTO REPORTFAIL',
        "START /W $PifWindowsPath $Arguments",
        'IF ERRORLEVEL 1 GOTO QUAKEFAIL',
        "$HelperWindowsPath O",
        'GOTO SHUTDOWN',
        ':QUAKEFAIL',
        "$HelperWindowsPath Q",
        'GOTO SHUTDOWN',
        ':REPORTFAIL',
        "$HelperWindowsPath R",
        ':SHUTDOWN',
        'RUNDLL32.EXE user.exe,ExitWindows'
    )
    return ($lines -join "`r`n") + "`r`n"
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
    $header = 'sequence' + "`t" + 'kind' + "`t" + 'value' + "`t" +
        'cs' + "`t" + 'flags' + "`t" + 'rip' + "`t" + 'address' + "`t" + 'detail'
    $headerIndex = [Array]::IndexOf($lines, $header)
    if ($headerIndex -lt 0 -or $headerIndex + 1 -ge $lines.Count) {
        throw 'Shutdown trace has no event table.'
    }
    $events = @($lines[($headerIndex + 1)..($lines.Count - 1)] |
        ConvertFrom-Csv -Delimiter "`t" -Header @(
            'sequence', 'kind', 'value', 'cs', 'flags', 'rip', 'address', 'detail'
        ))
    $markers = @($events | Where-Object { $_.kind -ceq 'marker' } |
        ForEach-Object { ([string]$_.value).ToLowerInvariant() })
    $cursor = 0
    foreach ($required in @('d5', 'd6', 'd7', 'd8', 'd9', 'da', 'db', 'dc')) {
        while ($cursor -lt $markers.Count -and $markers[$cursor] -cne $required) {
            $cursor += 1
        }
        if ($cursor -ge $markers.Count) {
            throw "Shutdown trace did not complete ordered marker $required."
        }
        $cursor += 1
    }
}

function Assert-LegacyVgaEvidenceGuestReport {
    param([string]$Path)

    Assert-LegacyVgaEvidenceFile $Path 'Legacy VGA guest report'
    $rows = @(Import-Csv -LiteralPath $Path -Delimiter "`t")
    if ($rows.Count -lt 3) {
        throw 'Legacy VGA guest report is incomplete.'
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
    @($launcherPath, 'launcher-stage executable')
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
$guestBatchWindows = ConvertTo-LegacyVgaEvidenceGuestPath $GuestBatchPath 'Guest batch path'
$guestHelperWindows = ConvertTo-LegacyVgaEvidenceGuestPath $GuestHelperPath 'Guest helper path'
$guestRegWindows = ConvertTo-LegacyVgaEvidenceGuestPath $GuestRegPath 'Guest REG path'
$null = Assert-LegacyVgaEvidenceAutoexec $autoexecPath $guestRegWindows
[byte[]]$knownRegBytes = [IO.File]::ReadAllBytes($regPath)
[byte[]]$derivedRegBytes = Get-LegacyVgaEvidenceDerivedRegBytes `
    $knownRegBytes $guestBatchWindows
$batchText = New-LegacyVgaEvidenceBatchText `
    $guestPifWindows $guestHelperWindows $QuakeArguments
$sourceDisk = Join-Path $sourcePath 'c_drive.img'
$sourceDiskHashBefore = (Get-FileHash -LiteralPath $sourceDisk -Algorithm SHA256).Hash

if ($ValidateOnly) {
    [pscustomobject]@{
        validated = $true
        guest_run_authorized = $false
        source_profile = $sourcePath
        disposable_profile = $profilePath
        evidence_directory = $evidencePath
        source_disk_sha256 = $sourceDiskHashBefore
        pif_bytes = $pifIdentity.bytes
        pif_sha256 = $pifIdentity.sha256
        guest_pif = $guestPifWindows
        guest_batch = $guestBatchWindows
        guest_helper = $guestHelperWindows
        desktop_sentinel = $sentinel
        host_arguments = @(
            '--start', '--test-device', '--strict-io', '--graphics-trace',
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
    $stagedBatch = Join-Path $stagePath 'legacy-vga-evidence-run.bat'
    Write-LegacyVgaEvidenceFileCreateNew `
        $stagedBatch (Get-LegacyVgaEvidenceAsciiBytes $batchText)
    $stagedReg = Join-Path $stagePath 'legacy-vga-evidence-driver.reg'
    Write-LegacyVgaEvidenceFileCreateNew $stagedReg $derivedRegBytes
    $stagedAutoexec = Join-Path $stagePath 'legacy-vga-evidence-autoexec.bat'
    Copy-Item -LiteralPath $autoexecPath -Destination $stagedAutoexec
    $helperIdentity = Build-LegacyVgaEvidenceKateaHelper `
        $stagePath $nasmPath $kateaTemplate $payloads $sentinel

    $importArguments = @(
        $cloneDisk,
        $stagedPif, $GuestPifPath,
        $stagedBatch, $GuestBatchPath,
        $helperIdentity.Path, $GuestHelperPath
    )
    & $importPath @importArguments
    if ($LASTEXITCODE -ne 0) {
        throw "guest-import failed with exit $LASTEXITCODE."
    }
    & $launcherPath $cloneDisk $stagedReg $stagedAutoexec
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
        '--graphics-trace',
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
    if ($hostExit -ne 0 -or $stopReason -cne 'power_off' -or $resultExit -ne 0) {
        throw (
            "Expected host exit 0 and power_off/0, observed host=$hostExit " +
            "stop=$stopReason result=$resultExit."
        )
    }
    if ([long]$result.unclassified_io -ne 0 -or
        [long]$result.unclassified_mmio -ne 0) {
        throw (
            'Legacy VGA evidence contains unclassified I/O: io={0} mmio={1}.' -f
            [long]$result.unclassified_io, [long]$result.unclassified_mmio
        )
    }
    foreach ($failureText in @('MMIO storm', 'upload-failed', 'render failure')) {
        $matches = @(Select-String -LiteralPath @($stdoutPath, $stderrPath) `
            -Pattern $failureText -SimpleMatch -ErrorAction Stop)
        if ($matches.Count -ne 0) {
            throw "Legacy VGA evidence contains '$failureText'."
        }
    }
    Assert-LegacyVgaEvidenceGuestReport `
        (Join-Path $artifactsPath $script:LegacyVgaEvidenceReportName)
    Assert-LegacyVgaEvidenceCaptures $artifactsPath
    Assert-LegacyVgaEvidenceShutdownTrace `
        (Join-Path $artifactsPath $script:LegacyVgaEvidenceShutdownTraceName)

    $summary = [ordered]@{
        schema = 1
        case = $Case
        mode = $Mode
        width = $Width
        height = $Height
        repetition = $Repetition
        legacy_aperture_mode = $LegacyApertureMode
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
        katea_helper = [ordered]@{
            bytes = $helperIdentity.Bytes
            sha256 = $helperIdentity.Sha256
            production_abi_added = $false
        }
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
