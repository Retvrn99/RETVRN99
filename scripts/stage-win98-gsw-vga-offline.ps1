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
    [string]$OutputDirectory,

    [string]$PayloadManifest,

    [string]$PayloadInventory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'strict-json.ps1')

function Get-OfflineStageFullPath {
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
    $remainder = $fullPath.Substring($root.Length)
    if ($remainder.Contains(':')) {
        throw "$Name must not contain an alternate data stream."
    }
    return $fullPath
}

function Assert-OfflineStageNoReparsePoint {
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

function Resolve-OfflineStageDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $fullPath = Get-OfflineStageFullPath $Path $Name
    Assert-OfflineStageNoReparsePoint $fullPath $Name
    $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::Directory) -eq 0 -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        ($item.Attributes -band [IO.FileAttributes]::Device) -ne 0) {
        throw "$Name must be one regular directory."
    }
    return $fullPath
}

function Resolve-OfflineStageFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $fullPath = Get-OfflineStageFullPath $Path $Name
    Assert-OfflineStageNoReparsePoint $fullPath $Name
    $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::Directory) -ne 0 -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        ($item.Attributes -band [IO.FileAttributes]::Device) -ne 0) {
        throw "$Name must be one regular file."
    }
    return $fullPath
}

function Test-OfflineStagePathOverlap {
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

function Assert-OfflineStageProfileStopped {
    param([Parameter(Mandatory = $true)][string]$ProfilePath)

    $lockPath = Join-Path $ProfilePath '.profile.lock'
    Assert-OfflineStageNoReparsePoint $lockPath 'Profile lock path'
    if (Test-Path -LiteralPath $lockPath) {
        throw "Profile is not stopped because its lock exists: $lockPath"
    }
    $companionPath = Join-Path $ProfilePath '.c_drive.img.retvrn99-fat32'
    Assert-OfflineStageNoReparsePoint $companionPath 'FAT32 companion path'
    if (Test-Path -LiteralPath $companionPath) {
        throw "Profile has retained or active FAT32 companion state: $companionPath"
    }
}

function Assert-OfflineStageSettingsImage {
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
    $settingsImagePath = Get-OfflineStageFullPath `
        ([string]$hardDriveProperty.Value) 'Profile settings hard_drive_path'
    Assert-OfflineStageNoReparsePoint $settingsImagePath 'Profile settings hard_drive_path'
    if (-not $settingsImagePath.Equals($ImagePath, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Profile settings hard_drive_path must be exactly '$ImagePath'."
    }
}

$repositoryRoot = Resolve-OfflineStageDirectory `
    (Join-Path $PSScriptRoot '..') 'Repository root'
if ([string]::IsNullOrWhiteSpace($PayloadManifest)) {
    $PayloadManifest = Join-Path $repositoryRoot 'drivers\win98\payload-manifest.schema.tsv'
}
if ([string]::IsNullOrWhiteSpace($PayloadInventory)) {
    $PayloadInventory = Join-Path $repositoryRoot 'drivers\win98\payload-inventory.schema.tsv'
}
$priorManifest = Join-Path `
    $repositoryRoot 'drivers\win98\gsw-vga-prior-only-manifest.tsv'

$profilePath = Resolve-OfflineStageDirectory $ProfileRoot 'Profile root'
$packagePath = Resolve-OfflineStageDirectory $PackageDirectory 'GSW-VGA package directory'
$manifestPath = Resolve-OfflineStageFile $PayloadManifest 'Payload manifest'
$inventoryPath = Resolve-OfflineStageFile $PayloadInventory 'Payload inventory'
$priorManifestPath = Resolve-OfflineStageFile `
    $priorManifest 'Reviewed GSW-VGA prior-only manifest'
$outputPath = Get-OfflineStageFullPath $OutputDirectory 'Output directory'
Assert-OfflineStageNoReparsePoint $outputPath 'Output directory'
if (Test-Path -LiteralPath $outputPath) {
    throw "Output directory already exists: $outputPath"
}
if ((Test-OfflineStagePathOverlap $outputPath $profilePath) -or
    (Test-OfflineStagePathOverlap $outputPath $packagePath)) {
    throw 'Output directory must not overlap the profile or package directory.'
}

$imagePath = Resolve-OfflineStageFile `
    (Join-Path $profilePath 'c_drive.img') 'Profile hard-drive image'
$settingsPath = Resolve-OfflineStageFile `
    (Join-Path $profilePath 'settings.json') 'Profile settings'
Assert-OfflineStageProfileStopped $profilePath
Assert-OfflineStageSettingsImage $settingsPath $imagePath

$toolSource = Resolve-OfflineStageDirectory `
    (Join-Path $repositoryRoot 'tools\gsw-vga-offline-stage') 'Offline staging tool source'
$helperSource = Resolve-OfflineStageDirectory `
    (Join-Path $repositoryRoot 'src\fat32_helper') 'RETVRN99-FAT32 source'
$outputParent = Split-Path -Parent $outputPath
if (-not (Test-Path -LiteralPath $outputParent -PathType Container)) {
    throw "Output directory parent does not exist: $outputParent"
}
Assert-OfflineStageNoReparsePoint $outputParent 'Output directory parent'
New-Item -ItemType Directory -Path $outputPath -ErrorAction Stop | Out-Null
Assert-OfflineStageNoReparsePoint $outputPath 'Output directory'

$odin = Get-Command odin -CommandType Application -ErrorAction Stop
$threadCount = [Math]::Max(1, [Math]::Min(64, [Environment]::ProcessorCount))
$toolPath = Join-Path $outputPath 'retvrn99-gsw-vga-offline-stage.exe'
$helperPath = Join-Path $outputPath 'retvrn99-fat32.exe'

& $odin.Source build $toolSource "-out:$toolPath" '-o:speed' `
    "-thread-count:$threadCount"
if ($LASTEXITCODE -ne 0) {
    throw "Building the GSW-VGA offline staging tool failed with exit code $LASTEXITCODE."
}
& $odin.Source build $helperSource "-out:$helperPath" '-o:speed' `
    "-thread-count:$threadCount"
if ($LASTEXITCODE -ne 0) {
    throw "Building RETVRN99-FAT32 failed with exit code $LASTEXITCODE."
}
$toolPath = Resolve-OfflineStageFile $toolPath 'Offline staging executable'
$null = Resolve-OfflineStageFile $helperPath 'Adjacent RETVRN99-FAT32 executable'

$null = Resolve-OfflineStageDirectory $profilePath 'Profile root'
$null = Resolve-OfflineStageDirectory $packagePath 'GSW-VGA package directory'
$null = Resolve-OfflineStageFile $manifestPath 'Payload manifest'
$null = Resolve-OfflineStageFile $inventoryPath 'Payload inventory'
$null = Resolve-OfflineStageFile `
    $priorManifestPath 'Reviewed GSW-VGA prior-only manifest'
$null = Resolve-OfflineStageFile $imagePath 'Profile hard-drive image'
$null = Resolve-OfflineStageFile $settingsPath 'Profile settings'
Assert-OfflineStageProfileStopped $profilePath
Assert-OfflineStageSettingsImage $settingsPath $imagePath

$stageOutput = @(& $toolPath stage $imagePath $packagePath $manifestPath `
    $inventoryPath $priorManifestPath 2>&1)
$stageExitCode = $LASTEXITCODE
if ($stageExitCode -ne 0) {
    $stageDetail = (($stageOutput | Out-String).Trim())
    throw "GSW-VGA offline staging failed with exit code $stageExitCode`: $stageDetail"
}
$stageOutput | Write-Output

Write-Output (
    "PASS GSW-VGA package staged offline into stopped profile image; " +
    "guest_path=C:\GSW-VGA profile=$profilePath"
)
