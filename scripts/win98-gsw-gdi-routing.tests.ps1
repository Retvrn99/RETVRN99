# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Match {
    param([string]$Text, [string]$Pattern, [string]$Message)
    if ($Text -cnotmatch $Pattern) { throw $Message }
}

$root = Join-Path $PSScriptRoot '..\drivers\win98'
$shared = Get-Content -Raw -LiteralPath (Join-Path $root 'derived\shared\gsw_gdi_abi.h')
$driver = Get-Content -Raw -LiteralPath (
    Join-Path $root 'derived\vmdisp9x-gsw\overlay\gsw_gdi.c'
)
$pm16 = Get-Content -Raw -LiteralPath (
    Join-Path $root 'derived\vmdisp9x-gsw\overlay\pm16_calls_gsw.c'
)
$transport = Get-Content -Raw -LiteralPath (
    Join-Path $root 'derived\vmdisp9x-gsw\overlay\gsw_transport.c'
)
$routing = Get-Content -Raw -LiteralPath (
    Join-Path $root 'derived\vmdisp9x-gsw\patches\0008-gsw-gdi-rop3.patch'
)
$makefile = Get-Content -Raw -LiteralPath (
    Join-Path $root 'derived\vmdisp9x-gsw\overlay\gsw.mak'
)
$inf = Get-Content -Raw -LiteralPath (
    Join-Path $root 'derived\vmdisp9x-gsw\overlay\gswmini.inf'
)
$readme = Get-Content -Raw -LiteralPath (Join-Path $root 'README.md')

Assert-Match $shared '#define GSW_VGA_CAP_GDI_ROP3\s+\(1UL << 5\)' 'GDI capability bit 5 is not frozen.'
Assert-Match $shared '#define GSW_VGA_CAP_GDI_FAST_DOORBELL\s+\(1UL << 6\)' 'Fast GDI doorbell capability bit 6 is not frozen.'
Assert-Match $shared '#define GSW_VGA_CAP_GDI_SYNC_COOKIE\s+\(1UL << 7\)' 'GDI completion-cookie capability bit 7 is not frozen.'
Assert-Match $shared '#define GSW_VGA_COMMAND_VERSION_4\s+4' 'Command version 4 is not frozen.'
Assert-Match $shared '#define GSW_VGA_OPCODE_GDI_BLT\s+13' 'GDI opcode 13 is not frozen.'
Assert-Match $shared '#define GSW_GDI_PM16_QUERY\s+0x47B0' 'PM16 query service is not frozen.'
Assert-Match $shared '#define GSW_GDI_PM16_SUBMIT\s+0x47B1' 'PM16 submission service is not frozen.'
Assert-Match $shared 'typedef struct GSWGdiBltCommand[\s\S]+DWORD pattern\[GSW_GDI_PATTERN_PIXELS\];' (
    'The GDI command must retain its inline normalized pattern.'
)
if ($shared -cmatch '\b(?:void|BYTE|DWORD)\s*\*') {
    throw 'The shared GDI command ABI must not contain pointers.'
}

Assert-Match $makefile 'FLAGS \+= -DHWBLT' 'The Win16 hardware BitBlt route is not enabled.'
Assert-Match $makefile 'gsw_gdi\.obj' 'The Win16 GDI callback is not linked.'
Assert-Match $routing 'BitBltDevProc\s*=\s*GSW_BitBlt' 'Mode setup does not install the GSW callback.'
Assert-Match $routing 'GSWGdiBltCommand request;[\s\S]+byte_count == sizeof\(request\)[\s\S]+memcpy\(&request' (
    'The VxD must size-check and immediately copy the PM16 request.'
)
Assert-Match $routing 'GSW_GDI_PM16_QUERY[\s\S]+GSW_GDI_PM16_SUBMIT' 'Both private PM16 services must route.'
Assert-Match $routing 'GSW_VGA_CAP_GDI_ROP3 \| GSW_VGA_CAP_GDI_FAST_DOORBELL \|[\s\S]+GSW_VGA_CAP_GDI_SYNC_COOKIE' (
    'The private query must negotiate both optimized doorbells independently.'
)
Assert-Match $pm16 'DPMI_GetSegBase[\s\S]+GSW_GDI_PM16_SUBMIT' 'The Win16 request is not converted to a linear pointer.'
Assert-Match $pm16 'xor ecx, ecx[\s\S]+GSW_GDI_PM16_QUERY[\s\S]+setc al[\s\S]+return failed \? 0' (
    'Capability negotiation must fail closed when the private VxD service is absent.'
)
Assert-Match $pm16 'GSW_GDI_PM16_SUBMIT[\s\S]+setc al[\s\S]+return !failed && result != 0' (
    'Unknown or failed VxD submission must reach the DIB fallback.'
)
Assert-Match $pm16 'request_selector != selector[\s\S]+request_base = DPMI_GetSegBase\(selector\)[\s\S]+request_linear = request_base \+ \(WORD\)pointer' (
    'The fixed command selector base should be cached across hot-path submissions.'
)

Assert-Match $driver 'GSW_PM16_capabilities\(\)[\s\S]+GSW_VGA_CAP_GDI_ROP3' (
    'Each operation must negotiate the host capability.'
)
Assert-Match $driver 'BANKEDVRAM \| BANKEDSCAN \| NOT_FRAMEBUFFER \| BUSY' (
    'Banked, unavailable, and busy destinations must fall back.'
)
Assert-Match $driver 'device == NULL \|\| device->deType != TYPE_DIBENG \|\| width == 0' (
    'System-memory BITMAP sources must be rejected before DIBENGINE-only fields are read.'
)
Assert-Match $driver 'device->deDeltaScan == 0 \|\| \(LONG\)device->deDeltaScan < 0' (
    'Zero and negative pitches must fall back.'
)
Assert-Match $driver 'source->deBitsPixel != destination->deBitsPixel' (
    'Mismatched source formats must fall back.'
)
Assert-Match $driver 'PATTERNMONO \| MASKVALID' 'Monochrome and masked brushes must fall back.'
Assert-Match $driver 'DIB_Brush8[\s\S]+dp8BrushBits[\s\S]+DIB_Brush16[\s\S]+dp16BrushBits[\s\S]+DIB_Brush24[\s\S]+dp24BrushBits[\s\S]+DIB_Brush32[\s\S]+dp32BrushBits' (
    'Packed patterns must use the DIB Engine format-specific brush fields.'
)
Assert-Match $driver 'COLORSOLID[\s\S]+gsw_gdi_read_pixel\(bits, bytes\)' (
    'Solid brushes must use the DIB Engine native brush pixel rather than dpFgColor.'
)
if ($driver -cmatch 'dp(?:8|16|24|32)FgColor') {
    throw 'Native packed brush normalization must never use DIB mono/hatch foreground colors.'
}
Assert-Match $driver 'dp8BrushStyle != BS_SOLID && prefix->dp8BrushStyle != BS_PATTERN' (
    'Only solid and opaque color-pattern brush styles may be accelerated.'
)
Assert-Match $driver 'pattern\[index\] = gsw_gdi_read_pixel' 'Native 8x8 patterns are not normalized inline.'
Assert-Match $driver 'gsw_gdi_cursor_begin[\s\S]+GSW_PM16_submit[\s\S]+gsw_gdi_cursor_end' (
    'Cursor exclusion must surround synchronous submission.'
)
Assert-Match $driver 'if\(submitted\) return TRUE;[\s\S]+fallback:[\s\S]+return DIB_BitBlt' (
    'A failed or unsupported operation must immediately use DIB_BitBlt.'
)

Assert-Match $transport 'memcpy\(&command, request, sizeof\(command\)\)' (
    'The transport must operate on its own fixed command copy.'
)
Assert-Match $transport 'byte_count != sizeof\(command\)' 'The transport must reject non-exact request sizes.'
Assert-Match $transport 'command\.flags & ~\(GSW_GDI_SOURCE_VALID \| GSW_GDI_PATTERN_VALID\)' (
    'The transport must reject malformed flags.'
)
Assert-Match $transport 'command\.pattern\[index\] & ~mask' 'The transport must reject non-native pattern pixels.'
Assert-Match $transport 'header->opcode == GSW_VGA_OPCODE_GDI_BLT[\s\S]+GSW_VGA_COMMAND_VERSION_4' (
    'The fenced ring must submit GDI commands as version 4.'
)
Assert-Match $transport 'GSW_GDI_DOORBELL_TAIL_FLAG \| new_tail[\s\S]+gsw_register_read\(GSW_VGA_REG_STATUS\)' (
    'The two-exit GDI path must publish its ring tail atomically and confirm completion.'
)
Assert-Match $transport 'gsw_submit_gdi_locked[\s\S]+gsw_ring_copy\(command_offset[\s\S]+gsw_write_barrier\(\)[\s\S]+GSW_GDI_DOORBELL_TAIL_FLAG' (
    'Ring writes must be ordered before the fast MMIO doorbell.'
)
Assert-Match $transport 'GSW_VGA_CAP_GDI_SYNC_COOKIE[\s\S]+GSW_GDI_DOORBELL_COOKIE_FLAG[\s\S]+\*completion != GSW_GDI_COMPLETION_COOKIE' (
    'The one-exit path must negotiate and verify a host-written completion cookie.'
)
Assert-Match $transport 'GSW_VGA_CAP_GDI_FAST_DOORBELL\) == 0\)[\s\S]+gsw_submit\(&command' (
    'Hosts without the fast-doorbell capability must retain generic fenced submission.'
)
Assert-Match $inf 'DriverVer=07/18/2026,0\.2\.0\.2' 'The fixed driver version must be 0.2.0.2.'
Assert-Match $readme '16,732[^\r\n]+c26acc98913474fd7d306d094694f38e226c88e386d567d716d15c39904b540a' (
    'The documented Win16 driver identity must match the deterministic build.'
)
Assert-Match $readme '38,897[^\r\n]+716ce252412aa2474b303bab4ef181f325bb260b4d60eeaff1612242da9a5748' (
    'The documented VxD identity must match the deterministic build.'
)

Write-Host 'PASS GSW GDI ABI is pointer-free, exact-size, and version frozen.'
Write-Host 'PASS Win16 routing retains immediate DIB fallback and cursor exclusion.'
Write-Host 'PASS VxD submission copies, validates, and uses the synchronous fenced ring.'
Write-Host 'PASS GSW-VGA driver version is 0.2.0.2.'
