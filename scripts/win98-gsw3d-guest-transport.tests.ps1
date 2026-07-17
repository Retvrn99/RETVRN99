# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Match {
    param([string]$Text, [string]$Pattern, [string]$Message)
    if ($Text -cnotmatch $Pattern) { throw $Message }
}

$driverRoot = Join-Path $PSScriptRoot '..\drivers\win98'
$shared = Get-Content -Raw -LiteralPath (Join-Path $driverRoot 'derived\shared\gsw3d_abi.h')
$transport = Get-Content -Raw -LiteralPath (
    Join-Path $driverRoot 'derived\vmdisp9x-gsw\overlay\gsw3d_transport.c'
)
$ioctl = Get-Content -Raw -LiteralPath (
    Join-Path $driverRoot 'derived\vmdisp9x-gsw\overlay\gsw3d_ioctl.c'
)
$makefile = Get-Content -Raw -LiteralPath (
    Join-Path $driverRoot 'derived\vmdisp9x-gsw\overlay\gsw.mak'
)
$dispatch = Get-Content -Raw -LiteralPath (
    Join-Path $driverRoot 'derived\vmdisp9x-gsw\patches\0006-gsw-directdraw-ioctl.patch'
)
$inf = Get-Content -Raw -LiteralPath (
    Join-Path $driverRoot 'derived\vmdisp9x-gsw\overlay\gswmini.inf'
)

Assert-Match $shared '#define GSW3D_IOCTL_QUERY\s+0x47530100UL' 'The query IOCTL is not frozen.'
Assert-Match $shared 'typedef struct GSW3DSubmitRequest[\s\S]+DWORD byte_count;' (
    'Submit must carry an inline byte count rather than a payload pointer.'
)
if ($shared -cmatch '\b(?:void|BYTE|DWORD)\s*\*') {
    throw 'The shared GSW3D ABI must not contain raw pointers.'
}
Assert-Match $transport 'GSW_VGA_CAP_3D_SVGA9[\s\S]+GSW_VGA_CAP_DIRECT_PRESENT[\s\S]+GSW_VGA_CAP_RESOURCE_UPLOAD' (
    'Initialization must require the proof backend capabilities.'
)
Assert-Match $transport 'GSW3D_REG_PACKET_FORMAT\) != GSW3D_PACKET_SVGA9' (
    'Initialization must reject an unavailable packet grammar.'
)
Assert-Match $transport 'RoundToPages\(GSW3D_RING_BYTES\)' 'The independent 3D ring is not page allocated.'
Assert-Match $transport 'RoundToPages\(GSW3D_STAGING_BYTES\)' 'The bounded staging region is not page allocated.'
Assert-Match $transport 'static void gsw3d_result_unavailable[\s\S]+result->cb = sizeof\(\*result\);' (
    'Unavailable calls must return a zeroed result without unlocked MMIO reads.'
)
Assert-Match $transport 'request->fence_low == 0 && request->fence_high == 0' (
    'Fence polling must reject the reserved zero fence.'
)
Assert-Match $ioctl '_LinPageLock' 'DIOC buffers must be page locked.'
Assert-Match $ioctl '_CopyPageTable' 'DIOC page mappings must be inspected.'
Assert-Match $ioctl 'GSW3D_PTE_PRESENT \| GSW3D_PTE_USER' (
    'DIOC buffers must require present ring-3 mappings.'
)
Assert-Match $ioctl 'input\.submit\.byte_count == payload_bytes' (
    'Submit must reject a mismatched inline payload length.'
)
Assert-Match $makefile 'gsw3d_transport\.obj[\s\S]+gsw3d_ioctl\.obj' (
    'Both GSW3D objects must be linked into the existing VxD.'
)
Assert-Match $dispatch 'GSW3D_ioctl\(params, &rc\)[\s\S]+GSW_DD_ioctl\(params, &rc\)' (
    'The bounded GSW3D DIOC range must dispatch before DirectDraw.'
)
if ($inf -cmatch '(?i)OpenGL|ICD|Mesa') {
    throw 'This prerequisite must not advertise an OpenGL ICD or Mesa.'
}

Write-Host 'PASS shared GSW3D ABI contains no raw pointers.'
Write-Host 'PASS GSW3D initialization is capability and packet-format gated.'
Write-Host 'PASS unavailable snapshots avoid MMIO and zero fences are rejected.'
Write-Host 'PASS GSW3D DIOC payloads are locked, bounded, and inline.'
Write-Host 'PASS GSW3D transport remains inside the existing VxD package.'
Write-Host 'PASS no Mesa or ICD advertising was added.'
