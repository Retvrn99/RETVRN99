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
# VWIN32 hands a VxD the caller's DeviceIoControl buffers as flat linear
# addresses in the shared arena at or above 80000000h, so a ring-3 address limit
# rejects every legal request; that is what kept DirectDraw from ever working.
# Upstream vmdisp9x calls neither VMM service from an IOCTL. The 3D path now
# bounds its buffers with arithmetic alone, as the DirectDraw path does.
foreach ($forbidden in @('_LinPageLock(', '_CopyPageTable(', '_LinPageUnLock(', 'GSW3D_RING3_LIMIT')) {
    if ($ioctl -cmatch [regex]::Escape($forbidden)) {
        throw "DIOC buffer handling must not use '$forbidden'."
    }
}
Assert-Match $ioctl 'static BOOL gsw3d_ioctl_range_valid\(DWORD address, DWORD bytes\)' (
    'DIOC buffers must be bounded by an arithmetic-only validity check.'
)
Assert-Match $ioctl 'address > 0xFFFFFFFFUL - \(bytes - 1\)' (
    'DIOC buffer bounds must reject an address range that wraps.'
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
Write-Host 'PASS GSW3D DIOC payloads are bounded by arithmetic alone and inline.'
Write-Host 'PASS GSW3D transport remains inside the existing VxD package.'
Write-Host 'PASS no Mesa or ICD advertising was added.'
