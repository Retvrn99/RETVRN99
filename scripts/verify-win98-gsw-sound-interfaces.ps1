# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SourceRoot,
    [Parameter(Mandatory = $true)][string]$ToolchainRoot,
    [string]$InterfaceLock
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'strict-json.ps1')
. (Join-Path $PSScriptRoot 'strict-tsv.ps1')
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($InterfaceLock)) {
    $InterfaceLock = Join-Path $repoRoot 'drivers\win98\gsw-sound\interface-inputs.lock.json'
}

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-RegularFile {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Label)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Label is absent: $Path" }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Label must not be a reparse point: $Path"
    }
    return $item
}

function Assert-FileIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][long]$Bytes,
        [Parameter(Mandatory = $true)][string]$Sha256,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $item = Assert-RegularFile $Path $Label
    if ($item.Length -ne $Bytes) {
        throw "$Label byte count differs. Expected $Bytes, observed $($item.Length): $Path"
    }
    $actual = Get-Sha256 $Path
    if ($actual -cne $Sha256.ToLowerInvariant()) {
        throw "$Label SHA-256 differs. Expected $Sha256, observed $actual`: $Path"
    }
}

$lockPath = [IO.Path]::GetFullPath($InterfaceLock)
$lock = Read-GswStrictJsonFile -Path $lockPath -Name 'GSW-Sound Interface lock' `
    -MaximumBytes 1048576
if ($lock._spdx -cne 'GPL-3.0-only' -or $lock.schema -ne 1 -or
    $lock.status -cne 'reviewed-compatible-interfaces') {
    throw 'GSW-Sound Interface lock metadata is unsupported.'
}

$lockDirectory = [IO.Path]::GetDirectoryName($lockPath)
$upstreamLockPath = [IO.Path]::GetFullPath((Join-Path $lockDirectory $lock.vmm_interface.source_lock))
$upstreamHeader = @(
    'name', 'source_directory', 'repository', 'commit', 'upstream_license',
    'disposition', 'closure_manifest', 'closure_manifest_sha256', 'scope'
)
$rows = @(Read-StrictTsvFile -Path $upstreamLockPath `
    -ExpectedHeader $upstreamHeader -Name 'Windows 98 upstream lock' `
    -MaximumBytes 1048576 -MaximumRows 256 -MaximumLineBytes 16384 `
    -MaximumPhysicalLines 1024)
$sourceRows = @($rows | Where-Object { $_.name -ceq $lock.vmm_interface.source_name })
if ($sourceRows.Count -ne 1) { throw 'The Interface source must have exactly one upstream-lock row.' }
$sourceRow = $sourceRows[0]
if ($sourceRow.repository -cne $lock.vmm_interface.repository -or
    $sourceRow.commit -cne $lock.vmm_interface.commit -or
    $sourceRow.upstream_license -cne $lock.vmm_interface.license) {
    throw 'The Interface lock disagrees with the upstream provenance row.'
}

$checkout = [IO.Path]::GetFullPath((Join-Path $SourceRoot $sourceRow.source_directory))
if (-not (Test-Path -LiteralPath $checkout -PathType Container)) {
    throw "Pinned Interface checkout is absent: $checkout"
}
$checkoutItem = Get-Item -LiteralPath $checkout -Force
if (($checkoutItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'Pinned Interface checkout must not be a reparse point.'
}
$head = (& git -C $checkout rev-parse HEAD 2>$null).Trim()
if ($LASTEXITCODE -ne 0 -or $head -cne $sourceRow.commit) {
    throw "Pinned Interface checkout commit differs. Expected $($sourceRow.commit), observed '$head'."
}
$origin = (& git -C $checkout remote get-url origin 2>$null).Trim()
if ($LASTEXITCODE -ne 0 -or $origin -cne $sourceRow.repository) {
    throw "Pinned Interface checkout origin differs. Expected $($sourceRow.repository), observed '$origin'."
}
$dirty = @(& git -C $checkout status --porcelain --untracked-files=all 2>$null)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -ne 0) {
    throw 'Pinned Interface checkout must be clean.'
}

foreach ($file in @($lock.vmm_interface.files)) {
    if ([IO.Path]::IsPathRooted([string]$file.source_relative_path) -or
        ([string]$file.source_relative_path).Contains('..')) {
        throw "Unsafe Interface source path '$($file.source_relative_path)'."
    }
    $path = [IO.Path]::GetFullPath((Join-Path $checkout $file.source_relative_path))
    if (-not $path.StartsWith($checkout + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Interface source escapes its checkout: $path"
    }
    Assert-FileIdentity $path ([long]$file.bytes) ([string]$file.sha256) `
        "Interface input '$($file.source_relative_path)'"
}

$mmdevldr = $lock.mmdevldr_interface_reference
if ($null -eq $mmdevldr -or
    $mmdevldr.repository -cne 'https://github.com/steward-fu/wadk.git' -or
    $mmdevldr.commit -cnotmatch '^[0-9a-f]{40}$' -or
    $mmdevldr.license -cne 'Microsoft-Windows-98-DDK-reference-only' -or
    $mmdevldr.disposition -cne `
        'service-identifiers-and-calling-convention-reviewed-into-original-minimal-build-support') {
    throw 'The MMDEVLDR Interface reference metadata is unsupported.'
}
$mmdevldrFiles = @($mmdevldr.files)
if ($mmdevldrFiles.Count -ne 3) {
    throw 'The MMDEVLDR Interface reference must pin exactly three reviewed files.'
}
$mmdevldrPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($file in $mmdevldrFiles) {
    if ($file.source_relative_path -isnot [string] -or
        [string]::IsNullOrWhiteSpace($file.source_relative_path) -or
        [IO.Path]::IsPathRooted($file.source_relative_path) -or
        $file.source_relative_path.Contains('..') -or
        -not $mmdevldrPaths.Add($file.source_relative_path) -or
        $file.git_blob -isnot [string] -or $file.git_blob -cnotmatch '^[0-9a-f]{40}$' -or
        $file.sha256 -isnot [string] -or $file.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $file.bytes -isnot [ValueType] -or [long]$file.bytes -lt 1) {
        throw 'The MMDEVLDR Interface reference contains an invalid file record.'
    }
}

$watcomLock = Join-Path $repoRoot 'drivers\win98\toolchain.lock.json'
$mingwLock = [IO.Path]::GetFullPath((Join-Path $lockDirectory $lock.multimedia_interface_reference.toolchain_lock))
& (Join-Path $PSScriptRoot 'verify-win98-driver-toolchain.ps1') `
    -ToolchainRoot $ToolchainRoot -LockFile $watcomLock
$mingwMetadata = & (Join-Path $PSScriptRoot 'verify-win98-driver-toolchain.ps1') `
    -ToolchainRoot $ToolchainRoot -LockFile $mingwLock -PassThruLock
$mingwRoot = Join-Path $ToolchainRoot $mingwMetadata.extracted.relative_path
$reference = Join-Path $mingwRoot $lock.multimedia_interface_reference.source_relative_path
Assert-FileIdentity $reference ([long]$lock.multimedia_interface_reference.bytes) `
    ([string]$lock.multimedia_interface_reference.sha256) 'Multimedia Interface reference'

Write-Output (
    "Verified GSW-Sound Interface inputs at {0}: {1} reviewed files, MMDEVLDR ABI, Watcom, and multimedia reference locked." -f `
        $sourceRow.commit, @($lock.vmm_interface.files).Count
)
