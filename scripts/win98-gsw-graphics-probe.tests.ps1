# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PayloadRoot,
    [Parameter(Mandatory = $true)][string]$ToolchainRoot,
    [string]$BuildPlan,
    [string]$ToolchainLock,
    [string]$WatcomLock,
    [string]$SourceRoot,
    [string]$StageManifest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-GswgfxFullPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

function Assert-Gswgfx {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) { throw $Message }
}

function Get-GswgfxSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-GswgfxHash {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )
    Assert-Gswgfx ($Value -is [string] -and $Value -cmatch '^[0-9a-f]{64}$') `
        "$Name must be one lowercase SHA-256 digest."
}

function Read-GswgfxJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $bytes = [IO.File]::ReadAllBytes($Path)
    Assert-Gswgfx ($bytes.Length -gt 0 -and $bytes.Length -le 4194304) `
        "$Name must be bounded and nonempty."
    try { return [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json }
    catch { throw "$Name is not valid JSON: $($_.Exception.Message)" }
}

function Get-GswgfxPe32 {
    param([Parameter(Mandatory = $true)][string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    Assert-Gswgfx ($bytes.Length -ge 256 -and $bytes[0] -eq 0x4D -and $bytes[1] -eq 0x5A) `
        'GSWGFX.EXE must begin with an MZ header.'
    $pe = [BitConverter]::ToUInt32($bytes, 0x3C)
    Assert-Gswgfx ($pe -le $bytes.Length - 128 -and
        [BitConverter]::ToUInt32($bytes, $pe) -eq 0x00004550) `
        'GSWGFX.EXE must contain a bounded PE signature.'
    $optional = $pe + 24
    return [pscustomobject]@{
        Machine = [BitConverter]::ToUInt16($bytes, $pe + 4)
        Timestamp = [BitConverter]::ToUInt32($bytes, $pe + 8)
        Magic = [BitConverter]::ToUInt16($bytes, $optional)
        ImageBase = [BitConverter]::ToUInt32($bytes, $optional + 28)
        MajorOs = [BitConverter]::ToUInt16($bytes, $optional + 40)
        MinorOs = [BitConverter]::ToUInt16($bytes, $optional + 42)
        MajorSubsystem = [BitConverter]::ToUInt16($bytes, $optional + 48)
        MinorSubsystem = [BitConverter]::ToUInt16($bytes, $optional + 50)
        Subsystem = [BitConverter]::ToUInt16($bytes, $optional + 68)
    }
}

if ([string]::IsNullOrWhiteSpace($BuildPlan)) {
    $BuildPlan = Join-Path $PSScriptRoot '..\drivers\win98\gsw-graphics-probe-build-plan.json'
}
if ([string]::IsNullOrWhiteSpace($ToolchainLock)) {
    $ToolchainLock = Join-Path $PSScriptRoot '..\drivers\win98\mingw32-toolchain.lock.json'
}
if ([string]::IsNullOrWhiteSpace($WatcomLock)) {
    $WatcomLock = Join-Path $PSScriptRoot '..\drivers\win98\toolchain.lock.json'
}
if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
    $SourceRoot = Join-Path $PSScriptRoot '..\drivers\win98\guest-tools\gsw-graphics-probe'
}
if ([string]::IsNullOrWhiteSpace($StageManifest)) {
    $StageManifest = Join-Path $PSScriptRoot '..\drivers\win98\gsw-graphics-probe-stage-manifest.tsv'
}

$payloadPath = Get-GswgfxFullPath $PayloadRoot
$toolchainPath = Get-GswgfxFullPath $ToolchainRoot
$buildPlanPath = Get-GswgfxFullPath $BuildPlan
$mingwLockPath = Get-GswgfxFullPath $ToolchainLock
$watcomLockPath = Get-GswgfxFullPath $WatcomLock
$sourcePath = Get-GswgfxFullPath $SourceRoot
$manifestPath = Get-GswgfxFullPath $StageManifest
foreach ($directory in @($payloadPath, $toolchainPath, $sourcePath)) {
    Assert-Gswgfx (Test-Path -LiteralPath $directory -PathType Container) `
        "Required GSWGFX directory is absent: $directory"
}
foreach ($file in @($buildPlanPath, $mingwLockPath, $watcomLockPath, $manifestPath)) {
    Assert-Gswgfx (Test-Path -LiteralPath $file -PathType Leaf) `
        "Required GSWGFX file is absent: $file"
}

$build = Read-GswgfxJson $buildPlanPath 'GSWGFX build plan'
Assert-Gswgfx ($build._spdx -ceq 'GPL-3.0-only' -and $build.schema -eq 3 -and
    $build.status -cin @('blocked', 'ready')) `
    'GSWGFX build plan must be a GPL-3.0-only schema-3 plan.'
$authoring = $build.status -ceq 'blocked'
Assert-Gswgfx (($authoring -and -not [string]::IsNullOrWhiteSpace([string]$build.reason)) -or
    (-not $authoring -and [string]$build.reason -ceq '')) `
    'GSWGFX build-plan status and reason disagree.'
$planDirectory = Split-Path -Parent $buildPlanPath
$derivedPath = Join-Path $planDirectory ([string]$build.derived_source_plan.relative_path)
Assert-GswgfxHash $build.derived_source_plan.sha256 'Derived-source plan identity'
if ($authoring) {
    Assert-Gswgfx ([string]$build.derived_source_plan.sha256 -ceq ('0' * 64)) `
        'Blocked hash-authoring state must use an explicit zero derived-plan identity.'
}
else {
    Assert-Gswgfx ((Get-GswgfxSha256 $derivedPath) -ceq
        [string]$build.derived_source_plan.sha256) `
        'Derived-source plan does not match its build-plan identity.'
}
$derived = Read-GswgfxJson $derivedPath 'GSWGFX derived-source plan'
Assert-Gswgfx ($derived._spdx -ceq 'GPL-3.0-only' -and
    $derived.status -cin @('draft', 'ready') -and
    @($derived.recipes).Count -eq 1) 'GSWGFX must have one draft or ready derived-source recipe.'
$recipe = @($derived.recipes)[0]
Assert-Gswgfx ($recipe.name -ceq 'gsw-graphics-probe' -and
    $recipe.destination_directory -ceq 'gsw-graphics-probe-source') `
    'GSWGFX derived-source recipe identity changed.'
$licensePath = Join-Path $planDirectory 'gswgfx-dos32a-license.txt'
Assert-Gswgfx (Test-Path -LiteralPath $licensePath -PathType Leaf) `
    'The DOS/32A Liberty license record is absent.'
$dos32aLicense = [IO.File]::ReadAllText($licensePath)
Assert-Gswgfx ($dos32aLicense.IndexOf(
    'DOS/32 Advanced DOS Extender Liberty Edition Software License',
    [StringComparison]::Ordinal
) -ge 0 -and $dos32aLicense.IndexOf(
    'This product uses DOS/32 Advanced DOS Extender technology.',
    [StringComparison]::Ordinal
) -ge 0) 'The DOS/32A license or required acknowledgment is incomplete.'

$lockLinks = @($build.toolchain_locks)
Assert-Gswgfx ($lockLinks.Count -eq 2) 'GSWGFX must link MinGW32 and Open Watcom locks.'
$expectedLocks = [ordered]@{
    mingw32 = $mingwLockPath
    'open-watcom' = $watcomLockPath
}
foreach ($name in $expectedLocks.Keys) {
    $matches = @($lockLinks | Where-Object { $_.name -ceq $name })
    Assert-Gswgfx ($matches.Count -eq 1) "Missing toolchain lock '$name'."
    Assert-GswgfxHash $matches[0].sha256 "Toolchain lock '$name' identity"
    Assert-Gswgfx ((Get-GswgfxSha256 $expectedLocks[$name]) -ceq [string]$matches[0].sha256) `
        "Toolchain lock '$name' does not match its build-plan identity."
}

$toolchains = @($build.toolchains)
$expectedTools = [ordered]@{
    'mingw32-gcc' = @('mingw32', 'bin/gcc.exe')
    'watcom-wcl386' = @('open-watcom', 'binnt/wcl386.exe')
    'watcom-wlink' = @('open-watcom', 'binnt/wlink.exe')
    'dos32a-bind' = @('open-watcom', 'binw/sb.exe')
    'dos32a-extender' = @('open-watcom', 'binw/dos32a.exe')
}
foreach ($name in $expectedTools.Keys) {
    $matches = @($toolchains | Where-Object { $_.name -ceq $name })
    Assert-Gswgfx ($matches.Count -eq 1) "Missing pinned build input '$name'."
    Assert-Gswgfx ($matches[0].lock -ceq $expectedTools[$name][0] -and
        $matches[0].relative_path -ceq $expectedTools[$name][1]) `
        "Pinned build input '$name' has the wrong path or lock."
    Assert-GswgfxHash $matches[0].sha256 "Pinned build input '$name' identity"
}

$steps = @($build.steps)
Assert-Gswgfx ($steps.Count -eq 2) 'GSWGFX build plan must have Win32 and DOS companion steps.'
$winStep = @($steps | Where-Object { $_.name -ceq 'build-gsw-graphics-probe' })
$dosStep = @($steps | Where-Object { $_.name -ceq 'build-gsw-vbe-companion' })
Assert-Gswgfx ($winStep.Count -eq 1 -and $dosStep.Count -eq 1) `
    'GSWGFX build steps must name the Win32 controller and DOS companion.'
$winArguments = @($winStep[0].arguments)
$dosArguments = @($dosStep[0].arguments)
foreach ($argument in @('-std=gnu99', '-D_WIN32_WINNT=0x0400', '-DWINVER=0x0400',
    '-march=pentium2', '-nostdlib', '-lkernel32', '-luser32', '-lgdi32', '-ldxguid', '-o',
    'GSWGFX.EXE')) {
    Assert-Gswgfx ($winArguments -ccontains $argument) `
        "GSWGFX Win32 arguments lost '$argument'."
}
foreach ($argument in @('-bt=dos', '-l=dos32a', '-fe=GSWVBE.EXE')) {
    Assert-Gswgfx ($dosArguments -ccontains $argument) `
        "GSWVBE arguments lost '$argument'."
}
Assert-Gswgfx (-not ($winArguments -ccontains 'plan.c') -and
    -not ($winArguments -ccontains 'PLAN.TSV')) 'The old fixed plan remains in the Win32 build.'

$outputs = @($steps | ForEach-Object { @($_.outputs) })
Assert-Gswgfx ($outputs.Count -eq 2) 'GSWGFX build plan must declare exactly two executables.'
$expectedOutputNames = @('GSWGFX.EXE', 'GSWVBE.EXE')
$outputByName = @{}
foreach ($output in $outputs) {
    $leaf = [IO.Path]::GetFileName([string]$output.relative_path)
    $boundedOutput = if ($authoring) {
        [UInt64]$output.bytes -eq 0 -and [string]$output.sha256 -ceq ('0' * 64)
    }
    else {
        [UInt64]$output.bytes -gt 0 -and [UInt64]$output.bytes -le 67108864
    }
    Assert-Gswgfx ($expectedOutputNames -ccontains $leaf -and
        $output.origin -ceq 'build' -and $boundedOutput) `
        'GSWGFX build output declaration is invalid.'
    Assert-GswgfxHash $output.sha256 "Output '$leaf' identity"
    $outputByName[$leaf] = $output
}
Assert-Gswgfx ($outputByName.Count -eq 2) 'GSWGFX output names must be unique.'

$sourceFiles = @(Get-ChildItem -LiteralPath $sourcePath -File | Sort-Object Name)
Assert-Gswgfx ($sourceFiles.Count -ge 6 -and $sourceFiles.Count -le 24) `
    'GSWGFX source Module count is outside its reviewed bound.'
Assert-Gswgfx (-not (Test-Path -LiteralPath (Join-Path $sourcePath 'PLAN.TSV'))) `
    'PLAN.TSV must not remain in the rewritten source directory.'
$sourceText = ''
foreach ($file in $sourceFiles) {
    Assert-Gswgfx ($file.Extension -cin @('.c', '.h')) `
        "Unexpected non-source file in GSWGFX source directory: $($file.Name)"
    $text = [IO.File]::ReadAllText($file.FullName)
    Assert-Gswgfx ($text.StartsWith('/* SPDX-License-Identifier: GPL-3.0-only */',
        [StringComparison]::Ordinal)) "Missing GPL-3.0-only SPDX header: $($file.Name)"
    Assert-Gswgfx ($text -cnotmatch '(?i)RESULT\.TMP|RESULT\.TSV|DONE\.OK|PLAN\.TSV') `
        "Obsolete guest-file Interface remains in $($file.Name)."
    $sourceText += "`n" + $text
}
$header = 'schema sequence record adapter mode width height bpp hz path status api_code ' +
    'frames duration_ms avg_fps_milli p50_us p95_us max_us slow_frames tested failed ' +
    'warnings unavailable crc32 detail'
$header = $header.Replace(' ', "\t") + "\r\n"
foreach ($token in @('GSWGFX_RESULT_V2', $header, '/exhaustive', '/self-test',
    '/host-report', '/import-vbe', '/gdi-only', '/ddraw-only', '/d3d-only',
    '/ddraw4', '/bounded', '/no-d3d', 'BOUNDED_GUEST_ADAPTER', 'GSWVBE.EXE',
    'C:\\GSWGFX\\VBE.TMP', 'GSW_SAMPLE_CAP',
    'GSW_WARMUP_MS', 'GSW_MEASURE_MS', 'GSW_STATUS_UNAVAILABLE')) {
    Assert-Gswgfx ($sourceText.IndexOf($token, [StringComparison]::Ordinal) -ge 0) `
        "GSWGFX observable source Interface lost '$token'."
}
foreach ($adapter in @('VGA', 'VBE', 'GDI', 'DDRAW', 'D3D7', 'D3D3')) {
    Assert-Gswgfx ($sourceText.IndexOf($adapter, [StringComparison]::OrdinalIgnoreCase) -ge 0) `
        "GSWGFX source lost the $adapter Adapter."
}
$vbeText = [IO.File]::ReadAllText((Join-Path $sourcePath 'vbe_import.c'))
foreach ($token in @('session->options.import_vbe', 'CreateProcessA', 'OPEN_EXISTING')) {
    Assert-Gswgfx ($vbeText.IndexOf($token, [StringComparison]::Ordinal) -ge 0) `
        "GSWGFX explicit VBE handoff lost '$token'."
}
$reportText = [IO.File]::ReadAllText((Join-Path $sourcePath 'report.c'))
Assert-Gswgfx ($reportText.IndexOf("bytes[offset] != '\t'", [StringComparison]::Ordinal) -ge 0) `
    'GSWGFX imported-row parser no longer permits canonical TSV separators.'
$vbeCompanionText = [IO.File]::ReadAllText((Join-Path $sourcePath 'gswvbe.c'))
foreach ($token in @('VBE_MODE_NO_CLEAR', 'mode | VBE_MODE_NO_CLEAR', '/preboot',
    'PREBOOT_VBE_UNBOUNDED')) {
    Assert-Gswgfx ($vbeCompanionText.IndexOf($token, [StringComparison]::Ordinal) -ge 0) `
        "GSWVBE bounded mode-set path lost '$token'."
}
$ddrawText = [IO.File]::ReadAllText((Join-Path $sourcePath 'backend_ddraw.c'))
foreach ($token in @('DirectDrawCreateEx', 'DirectDrawCreate', 'IID_IDirectDraw7',
    'IID_IDirectDraw4', 'IDirectDraw4_EnumDisplayModes',
    'IDirectDrawSurface4_Flip', 'options.ddraw4')) {
    Assert-Gswgfx ($ddrawText.IndexOf($token, [StringComparison]::Ordinal) -ge 0) `
        "GSWGFX DirectDraw compatibility fallback lost '$token'."
}
$sessionText = [IO.File]::ReadAllText((Join-Path $sourcePath 'session.c'))
Assert-Gswgfx ($sessionText.IndexOf('session.unavailable != 0',
    [StringComparison]::Ordinal) -ge 0) `
    'GSWGFX unavailable coverage no longer forces at least WARN.'
Write-Output 'PASS GSWGFX source is licensed and exposes dynamic mode, benchmark, report, and Adapter Interfaces.'

$recipeOutput = Join-Path $payloadPath ([string]$recipe.destination_directory)
if (-not $authoring) {
    foreach ($name in $expectedOutputNames) {
        $output = $outputByName[$name]
        $path = Join-Path $recipeOutput ([string]$output.relative_path)
        Assert-Gswgfx (Test-Path -LiteralPath $path -PathType Leaf) `
            "Built GSWGFX package member is absent: $path"
        $item = Get-Item -LiteralPath $path
        Assert-Gswgfx ([UInt64]$item.Length -eq [UInt64]$output.bytes -and
            (Get-GswgfxSha256 $path) -ceq [string]$output.sha256) `
            "$name does not match its authored build lock."
    }
    $pe = Get-GswgfxPe32 (Join-Path $recipeOutput `
        ([string]$outputByName['GSWGFX.EXE'].relative_path))
    Assert-Gswgfx ($pe.Machine -eq 0x014C -and $pe.Magic -eq 0x010B -and
        $pe.Timestamp -eq 0 -and $pe.ImageBase -eq 0x00400000 -and
        $pe.MajorOs -eq 4 -and $pe.MinorOs -eq 0 -and
        $pe.MajorSubsystem -eq 4 -and $pe.MinorSubsystem -eq 0 -and
        $pe.Subsystem -eq 3) 'GSWGFX.EXE must be deterministic PE32 Windows 4.0 CUI.'
    $mingwLock = Read-GswgfxJson $mingwLockPath 'MinGW32 toolchain lock'
    $objdumpPath = Join-Path $toolchainPath ([string]$mingwLock.extracted.relative_path)
    $objdumpPath = Join-Path $objdumpPath 'bin\objdump.exe'
    Assert-Gswgfx (Test-Path -LiteralPath $objdumpPath -PathType Leaf) `
        'Pinned MinGW32 objdump is absent.'
    $pePath = Join-Path $recipeOutput ([string]$outputByName['GSWGFX.EXE'].relative_path)
    $dump = (& $objdumpPath -p $pePath 2>&1) -join "`n"
    Assert-Gswgfx ($LASTEXITCODE -eq 0) 'Pinned objdump could not inspect GSWGFX.EXE.'
    $imports = @([regex]::Matches($dump, '(?m)^\s*DLL Name:\s*(\S+)\s*$') |
        ForEach-Object { $_.Groups[1].Value } | Sort-Object)
    Assert-Gswgfx (($imports -join ',') -ceq 'GDI32.dll,KERNEL32.dll,USER32.dll') `
        "GSWGFX.EXE import closure changed: $($imports -join ', ')"
    $dosBytes = [IO.File]::ReadAllBytes((Join-Path $recipeOutput `
        ([string]$outputByName['GSWVBE.EXE'].relative_path)))
    Assert-Gswgfx ($dosBytes.Length -ge 1024 -and
        $dosBytes[0] -eq 0x4D -and $dosBytes[1] -eq 0x5A) `
        'GSWVBE.EXE must be one bound DOS executable.'
    $dosAscii = [Text.Encoding]::ASCII.GetString($dosBytes)
    Assert-Gswgfx ($dosAscii.IndexOf('DOS/32A', [StringComparison]::OrdinalIgnoreCase) -ge 0) `
        'GSWVBE.EXE does not contain its bound DOS/32A extender identity.'
    Write-Output 'PASS GSWGFX and GSWVBE binaries match their pinned output locks and executable shapes.'
}

$manifestBytes = [IO.File]::ReadAllBytes($manifestPath)
Assert-Gswgfx ($manifestBytes.Length -gt 0 -and $manifestBytes.Length -le 4096 -and
    $manifestBytes[-1] -eq 0x0A) 'GSWGFX stage manifest must be bounded canonical LF TSV.'
foreach ($byte in $manifestBytes) {
    Assert-Gswgfx ($byte -ne 0x0D -and $byte -ne 0 -and $byte -lt 0x80 -and
        ($byte -ge 0x20 -or $byte -in @(0x09, 0x0A))) `
        'GSWGFX stage manifest must be canonical 7-bit ASCII.'
}
$lines = [regex]::Split([Text.Encoding]::ASCII.GetString($manifestBytes), "`n")
Assert-Gswgfx ($lines.Count -eq 4 -and $lines[0] -ceq
    "guest_directory`tfile_name`tsha256`tbytes" -and $lines[3] -ceq '') `
    'GSWGFX stage manifest must contain one exact header and two rows.'
for ($index = 0; $index -lt 2; $index++) {
    $fields = $lines[$index + 1].Split([char]"`t")
    $name = $expectedOutputNames[$index]
    $output = $outputByName[$name]
    Assert-Gswgfx ($fields.Count -eq 4 -and $fields[0] -ceq 'GSWGFX' -and
        $fields[1] -ceq $name -and $fields[2] -ceq [string]$output.sha256 -and
        $fields[3] -ceq ([UInt64]$output.bytes).ToString(
            [Globalization.CultureInfo]::InvariantCulture)) `
        "GSWGFX stage manifest does not exactly bind $name."
}
Write-Output 'PASS GSWGFX stage manifest binds exactly GSWGFX.EXE and GSWVBE.EXE.'
Write-Output 'All focused GSWGFX build, binary, schema, licensing, and package Interface gates passed.'
