# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ProfileRoot,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$PackageDirectory,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$StageManifest,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'strict-json.ps1')

function Get-GswgfxOfflineFullPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "$Name must not be empty."
    }
    if ([IO.Path]::IsPathRooted($Path)) {
        $fullPath = [IO.Path]::GetFullPath($Path)
    }
    else {
        $fullPath = [IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
    }
    $root = [IO.Path]::GetPathRoot($fullPath)
    if ([string]::IsNullOrWhiteSpace($root)) {
        throw "$Name must resolve to a rooted filesystem path."
    }
    if ($fullPath.Substring($root.Length).Contains(':')) {
        throw "$Name must not contain an alternate data stream."
    }
    return $fullPath
}

function Assert-GswgfxOfflineNoReparsePoint {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $current = [IO.Path]::GetFullPath($Path)
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($null -ne $item -and
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Name traverses reparse point '$current'."
        }
        $parent = [IO.Path]::GetDirectoryName($current)
        if ([string]::IsNullOrWhiteSpace($parent) -or
            $parent.Equals($current, [StringComparison]::OrdinalIgnoreCase)) {
            break
        }
        $current = $parent
    }
}

function Assert-GswgfxOfflineNoNamedStreams {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return }
    $streams = @(Get-Item -LiteralPath $Path -Stream * -ErrorAction Stop)
    $named = @($streams | Where-Object { $_.Stream -cne ':$DATA' })
    if ($named.Count -ne 0) {
        throw "$Name must not contain alternate data streams."
    }
}

function Resolve-GswgfxOfflineDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $fullPath = Get-GswgfxOfflineFullPath $Path $Name
    Assert-GswgfxOfflineNoReparsePoint $fullPath $Name
    $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::Directory) -eq 0 -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        ($item.Attributes -band [IO.FileAttributes]::Device) -ne 0) {
        throw "$Name must be one regular directory."
    }
    return $fullPath
}

function Resolve-GswgfxOfflineFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $fullPath = Get-GswgfxOfflineFullPath $Path $Name
    Assert-GswgfxOfflineNoReparsePoint $fullPath $Name
    $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::Directory) -ne 0 -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        ($item.Attributes -band [IO.FileAttributes]::Device) -ne 0) {
        throw "$Name must be one regular file."
    }
    Assert-GswgfxOfflineNoNamedStreams $fullPath $Name
    return $fullPath
}

function Test-GswgfxOfflinePathOverlap {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )

    $leftPath = $Left.TrimEnd([char[]]'\/')
    $rightPath = $Right.TrimEnd([char[]]'\/')
    $leftPrefix = $leftPath + [IO.Path]::DirectorySeparatorChar
    $rightPrefix = $rightPath + [IO.Path]::DirectorySeparatorChar
    return $leftPath.Equals($rightPath, [StringComparison]::OrdinalIgnoreCase) -or
        $leftPath.StartsWith($rightPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        $rightPath.StartsWith($leftPrefix, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-GswgfxOfflineProfileStopped {
    param([Parameter(Mandatory = $true)][string]$ProfilePath)

    foreach ($lockName in @('.profile.lock', '.retvrn99.lock')) {
        $lockPath = Join-Path $ProfilePath $lockName
        Assert-GswgfxOfflineNoReparsePoint $lockPath 'Profile lock path'
        if (Test-Path -LiteralPath $lockPath) {
            throw "Profile is not stopped because its lock exists: $lockPath"
        }
    }
    $companionPath = Join-Path $ProfilePath '.c_drive.img.retvrn99-fat32'
    Assert-GswgfxOfflineNoReparsePoint $companionPath 'FAT32 companion path'
    if (Test-Path -LiteralPath $companionPath) {
        throw "Profile has retained or active FAT32 companion state: $companionPath"
    }
}

function Assert-GswgfxOfflineSettingsImage {
    param(
        [Parameter(Mandatory = $true)][string]$SettingsPath,
        [Parameter(Mandatory = $true)][string]$ImagePath
    )

    $settings = (Read-GswStrictJsonFileSnapshot -Path $SettingsPath `
        -Name 'Profile settings' -MaximumBytes 1048576).Value
    $hardDriveProperty = $settings.PSObject.Properties['hard_drive_path']
    if ($null -eq $hardDriveProperty -or $hardDriveProperty.Value -isnot [string] -or
        [string]::IsNullOrWhiteSpace([string]$hardDriveProperty.Value)) {
        throw 'Profile settings must contain one string hard_drive_path.'
    }
    $settingsImagePath = Get-GswgfxOfflineFullPath `
        ([string]$hardDriveProperty.Value) 'Profile settings hard_drive_path'
    Assert-GswgfxOfflineNoReparsePoint `
        $settingsImagePath 'Profile settings hard_drive_path'
    if (-not $settingsImagePath.Equals(
        $ImagePath,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Profile settings hard_drive_path must be exactly '$ImagePath'."
    }
}

function Assert-GswgfxOfflineImageUnlocked {
    param([Parameter(Mandatory = $true)][string]$ImagePath)

    try {
        $stream = [IO.File]::Open(
            $ImagePath,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::None
        )
        $stream.Dispose()
    }
    catch {
        throw "Profile hard-drive image is not exclusively readable: $ImagePath"
    }
}

function Assert-GswgfxOfflinePackage {
    param([Parameter(Mandatory = $true)][string]$PackagePath)

    $expected = @('GSWGFX.EXE', 'GSWVBE.EXE')
    $entries = @(Get-ChildItem -LiteralPath $PackagePath -Force)
    if ($entries.Count -ne $expected.Count) {
        throw 'GSWGFX package directory must contain exactly GSWGFX.EXE and GSWVBE.EXE.'
    }
    $result = [ordered]@{}
    foreach ($name in $expected) {
        $matches = @($entries | Where-Object { $_.Name -ceq $name })
        if ($matches.Count -ne 1) {
            throw 'GSWGFX package directory must contain exactly GSWGFX.EXE and GSWVBE.EXE.'
        }
        $path = Resolve-GswgfxOfflineFile $matches[0].FullName "GSWGFX package file $name"
        if ($matches[0].Length -le 0) {
            throw "GSWGFX package file $name must not be empty."
        }
        $result[$name] = $path
    }
    return $result
}

function Assert-GswgfxOfflineManifest {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][Collections.IDictionary]$PackageFiles
    )

    $bytes = [IO.File]::ReadAllBytes($ManifestPath)
    if ($bytes.Length -le 0 -or $bytes.Length -gt 4096 -or $bytes[-1] -ne 0x0A) {
        throw 'GSWGFX stage manifest must be bounded canonical LF TSV.'
    }
    foreach ($byte in $bytes) {
        if ($byte -eq 0x0D -or $byte -eq 0 -or $byte -ge 0x80 -or
            ($byte -lt 0x20 -and $byte -ne 0x09 -and $byte -ne 0x0A)) {
            throw 'GSWGFX stage manifest must be bounded canonical LF TSV.'
        }
    }
    $text = [Text.Encoding]::ASCII.GetString($bytes)
    $lines = [regex]::Split($text, "`n")
    $header = "guest_directory`tfile_name`tsha256`tbytes"
    if ($lines.Count -ne 4 -or $lines[0] -cne $header -or $lines[3] -cne '') {
        throw 'GSWGFX stage manifest must have one exact header and two canonical rows.'
    }
    $names = @('GSWGFX.EXE', 'GSWVBE.EXE')
    for ($index = 0; $index -lt $names.Count; $index++) {
        $fields = $lines[$index + 1].Split([char]"`t")
        $name = $names[$index]
        if ($fields.Count -ne 4 -or $fields[0] -cne 'GSWGFX' -or
            $fields[1] -cne $name -or $fields[2] -cnotmatch '^[0-9a-f]{64}$' -or
            $fields[3] -cnotmatch '^[1-9][0-9]*$') {
            throw 'GSWGFX stage manifest contains a noncanonical row.'
        }
        [UInt64]$declaredBytes = 0
        if (-not [UInt64]::TryParse(
            $fields[3],
            [Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$declaredBytes
        ) -or $declaredBytes -gt 67108864) {
            throw 'GSWGFX stage manifest contains an invalid byte count.'
        }
        $file = Get-Item -LiteralPath $PackageFiles[$name] -Force
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        if ([UInt64]$file.Length -ne $declaredBytes -or $hash -cne $fields[2]) {
            throw "GSWGFX package file $name does not match the stage manifest."
        }
    }
}

$repositoryRoot = Resolve-GswgfxOfflineDirectory `
    (Join-Path $PSScriptRoot '..') 'Repository root'
$profilePath = Resolve-GswgfxOfflineDirectory $ProfileRoot 'Profile root'
$packagePath = Resolve-GswgfxOfflineDirectory `
    $PackageDirectory 'GSWGFX package directory'
$manifestPath = Resolve-GswgfxOfflineFile $StageManifest 'GSWGFX stage manifest'
$outputPath = Get-GswgfxOfflineFullPath $OutputDirectory 'Output directory'
Assert-GswgfxOfflineNoReparsePoint $outputPath 'Output directory'
if (Test-Path -LiteralPath $outputPath) {
    throw "Output directory already exists: $outputPath"
}
if (Test-GswgfxOfflinePathOverlap $profilePath $packagePath) {
    throw 'Profile and GSWGFX package directories must not overlap.'
}
if ((Test-GswgfxOfflinePathOverlap $outputPath $profilePath) -or
    (Test-GswgfxOfflinePathOverlap $outputPath $packagePath)) {
    throw 'Output directory must not overlap the profile or GSWGFX package directory.'
}

$imagePath = Resolve-GswgfxOfflineFile `
    (Join-Path $profilePath 'c_drive.img') 'Profile hard-drive image'
$settingsPath = Resolve-GswgfxOfflineFile `
    (Join-Path $profilePath 'settings.json') 'Profile settings'
Assert-GswgfxOfflineProfileStopped $profilePath
Assert-GswgfxOfflineSettingsImage $settingsPath $imagePath
Assert-GswgfxOfflineImageUnlocked $imagePath
$packageFiles = Assert-GswgfxOfflinePackage $packagePath
Assert-GswgfxOfflineManifest $manifestPath $packageFiles

$toolSource = Resolve-GswgfxOfflineDirectory `
    (Join-Path $repositoryRoot 'tools\gswgfx-offline-stage') `
    'GSWGFX offline staging tool source'
$helperSource = Resolve-GswgfxOfflineDirectory `
    (Join-Path $repositoryRoot 'src\fat32_helper') 'RETVRN99-FAT32 source'
$outputParent = Split-Path -Parent $outputPath
if (-not (Test-Path -LiteralPath $outputParent -PathType Container)) {
    throw "Output directory parent does not exist: $outputParent"
}
Assert-GswgfxOfflineNoReparsePoint $outputParent 'Output directory parent'
New-Item -ItemType Directory -Path $outputPath -ErrorAction Stop | Out-Null
Assert-GswgfxOfflineNoReparsePoint $outputPath 'Output directory'

$odin = Get-Command odin -CommandType Application -ErrorAction Stop
$threadCount = [Math]::Max(1, [Math]::Min(64, [Environment]::ProcessorCount))
$toolPath = Join-Path $outputPath 'retvrn99-gswgfx-offline-stage.exe'
$helperPath = Join-Path $outputPath 'retvrn99-fat32.exe'

& $odin.Source build $toolSource "-out:$toolPath" '-o:speed' `
    "-thread-count:$threadCount"
if ($LASTEXITCODE -ne 0) {
    throw "Building the GSWGFX offline staging tool failed with exit code $LASTEXITCODE."
}
& $odin.Source build $helperSource "-out:$helperPath" '-o:speed' `
    "-thread-count:$threadCount"
if ($LASTEXITCODE -ne 0) {
    throw "Building RETVRN99-FAT32 failed with exit code $LASTEXITCODE."
}
$toolPath = Resolve-GswgfxOfflineFile $toolPath 'GSWGFX offline staging executable'
$null = Resolve-GswgfxOfflineFile $helperPath 'Adjacent RETVRN99-FAT32 executable'

$null = Resolve-GswgfxOfflineDirectory $profilePath 'Profile root'
$null = Resolve-GswgfxOfflineDirectory $packagePath 'GSWGFX package directory'
$null = Resolve-GswgfxOfflineFile $manifestPath 'GSWGFX stage manifest'
$null = Resolve-GswgfxOfflineFile $imagePath 'Profile hard-drive image'
$null = Resolve-GswgfxOfflineFile $settingsPath 'Profile settings'
Assert-GswgfxOfflineProfileStopped $profilePath
Assert-GswgfxOfflineSettingsImage $settingsPath $imagePath
Assert-GswgfxOfflineImageUnlocked $imagePath
$packageFiles = Assert-GswgfxOfflinePackage $packagePath
Assert-GswgfxOfflineManifest $manifestPath $packageFiles

$stageOutput = @(& $toolPath stage $imagePath $packagePath $manifestPath 2>&1)
$stageExitCode = $LASTEXITCODE
if ($stageExitCode -ne 0) {
    $stageDetail = (($stageOutput | Out-String).Trim())
    throw "GSWGFX offline staging failed with exit code $stageExitCode`: $stageDetail"
}
$stageOutput | Write-Output

Write-Output (
    'PASS GSWGFX staged offline into stopped profile image; ' +
    "guest_path=C:\GSWGFX profile=$profilePath"
)
