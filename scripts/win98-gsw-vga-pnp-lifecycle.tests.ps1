# SPDX-License-Identifier: GPL-3.0-only

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Match {
    param([string]$Text, [string]$Pattern, [string]$Message)
    if ($Text -cnotmatch $Pattern) { throw $Message }
}

function Assert-NotMatch {
    param([string]$Text, [string]$Pattern, [string]$Message)
    if ($Text -cmatch $Pattern) { throw $Message }
}

function Get-SimpleFunctionBody {
    param([string]$Text, [string]$Signature)
    $match = [regex]::Match(
        $Text,
        [regex]::Escape($Signature) + '\s*\{(?<body>[\s\S]*?)\r?\n\}'
    )
    if (-not $match.Success) { throw "Function body not found: $Signature" }
    return $match.Groups['body'].Value
}

$root = Join-Path $PSScriptRoot '..\drivers\win98\derived\vmdisp9x-gsw'
$halRoot = Join-Path $PSScriptRoot '..\drivers\win98\derived\vmhal9x-gsw'
$transport = Get-Content -Raw -LiteralPath (Join-Path $root 'overlay\gsw_transport.c')
$transport3d = Get-Content -Raw -LiteralPath (Join-Path $root 'overlay\gsw3d_transport.c')
$ddraw = Get-Content -Raw -LiteralPath (Join-Path $root 'overlay\gsw_ddraw.c')
$ioctl3d = Get-Content -Raw -LiteralPath (Join-Path $root 'overlay\gsw3d_ioctl.c')
$header = Get-Content -Raw -LiteralPath (Join-Path $root 'overlay\gsw_transport.h')
$shutdownTrace = Get-Content -Raw -LiteralPath (Join-Path $root 'overlay\gsw_shutdown_trace.h')
$shutdownPatch = Get-Content -Raw -LiteralPath (
    Join-Path $root 'patches\0010-gsw-process-shutdown.patch'
)
$vxdMain = Get-Content -Raw -LiteralPath (Join-Path $root 'overlay\vxd_main_gsw.c')
$vbe = Get-Content -Raw -LiteralPath (Join-Path $root 'overlay\vxd_vbe_gsw.c')
$pm16 = Get-Content -Raw -LiteralPath (Join-Path $root 'overlay\pm16_calls_gsw.c')
$lifecycle = Get-Content -Raw -LiteralPath (
    Join-Path $root 'patches\0009-gsw-pnp-display-lifecycle.patch'
)
$halDdraw = Get-Content -Raw -LiteralPath (Join-Path $halRoot 'overlay\gsw_ddraw.c')
$halBackend = Get-Content -Raw -LiteralPath (Join-Path $halRoot 'overlay\gsw_backend.c')

Assert-Match $transport '#define GSW_PCI_COMMAND_REQUIRED 0x0006' (
    'The transport must require memory decode and bus mastering without claiming I/O decode.'
)
Assert-Match $transport 'if\(gsw_is_ready && !replace_ready_binding\)[\s\S]+Signal_Semaphore\(gsw_semaphore\);[\s\S]+return TRUE;' (
    'An initialized transport must be reused without ordinary PCI configuration reads.'
)
Assert-Match $transport 'BOOL GSW_transport_rebind\(void\)[\s\S]+return gsw_transport_initialize\(TRUE\);' (
    'Serialized desktop restoration must replace the complete PCI and ring binding.'
)
Assert-NotMatch $transport 'PCI_GetBARSize\(' (
    'The driver must not size BARs by writing all ones while ConfigMgr may own enumeration.'
)
Assert-Match $transport 'gsw_pci_command_added = \(WORD\)\(\(~original_command\) & GSW_PCI_COMMAND_REQUIRED\);' (
    'The driver must remember only required PCI command bits that it added.'
)
Assert-Match $transport 'if\(gsw_pci_identity_current\(\) && gsw_pci_command_added != 0\)[\s\S]+command & ~gsw_pci_command_added' (
    'Shutdown must clear only driver-owned decode bits while preserving unrelated ConfigMgr state.'
)
Assert-NotMatch $transport 'gsw_original_pci_command|gsw_pci_command_saved' (
    'A stale complete PCI command word must never be restored over ConfigMgr state.'
)
Assert-Match $transport 'resources_current = gsw_pci_mmio_current\(\);[\s\S]+if\(!resources_current\)[\s\S]+gsw_registers = NULL;[\s\S]+GSW3D_transport_shutdown\(\);' (
    'Shutdown must suppress stale MMIO before releasing 3D resources.'
)
Assert-Match $transport 'BOOL GSW_transport_ready\(void\)[\s\S]+return gsw_is_ready;' (
    'Read-side transport readiness must be a cached lifecycle query.'
)
Assert-Match $transport 'static BOOL gsw_begin\(void\)[\s\S]+if\(!gsw_is_ready\)' (
    'Submission must fail closed without touching PCI configuration space.'
)
Assert-Match $transport3d 'if\(!gsw3d_ready \|\| !GSW_transport_ready\(\)\)' (
    'Every 3D operation must fail closed after PCI resource drift.'
)
Assert-Match $vxdMain '#include "gsw_transport\.h"\r?\n#include "vxd_main\.c"' (
    'The GSW VxD wrapper must include the transport contract before vxd_main can call cleanup helpers.'
)
Assert-Match $header 'void GSW_transport_process_cleanup\(DWORD owner_pid\);' (
    'The 2D transport must expose per-process cleanup to the VxD lifecycle hook.'
)
Assert-Match $header 'void GSW3D_transport_process_cleanup\(DWORD owner_pid\);' (
    'The 3D transport must expose per-process cleanup to the VxD lifecycle hook.'
)
Assert-Match $ddraw 'GSW_transport_surface_register\(&output\.registration,\s*params->tagProcess\);' (
    'DirectDraw surface registration must tag resources with DIOCParams.tagProcess.'
)
$createSurfaceBody = Get-SimpleFunctionBody $halDdraw (
    'DDENTRY(CreateSurface32, LPDDHAL_CREATESURFACEDATA, data)'
)
Assert-Match $createSurfaceBody 'data->ddRVal\s*=\s*DD_OK;\s*return DDHAL_DRIVER_NOTHANDLED;' (
    'CreateSurface must leave video-memory allocation to DirectDraw before GSW registration.'
)
Assert-NotMatch $createSurfaceBody 'GSWDD_surface|GSWDD_unregister|dwReserved1|DDERR_INVALIDPARAMS' (
    'CreateSurface must not treat the pre-allocation video-memory sentinel as an address.'
)
foreach ($signature in @(
    'DDENTRY(Lock32, LPDDHAL_LOCKDATA, data)',
    'DDENTRY(Blt32, LPDDHAL_BLTDATA, data)',
    'DDENTRY(Flip32, LPDDHAL_FLIPDATA, data)'
)) {
    Assert-Match (Get-SimpleFunctionBody $halDdraw $signature) 'GSWDD_surface\(' (
        "$signature must retain lazy surface registration after allocation."
    )
}
$destroySurfaceBody = Get-SimpleFunctionBody $halDdraw (
    'DDENTRY(DestroySurface32, LPDDHAL_DESTROYSURFACEDATA, data)'
)
Assert-Match $destroySurfaceBody (
    'dwReserved1\s*!=\s*0[\s\S]+GSWDD_unregister\([\s\S]+dwReserved1\s*=\s*0;'
) 'DestroySurface must unregister and clear a lazily assigned surface identity.'
Assert-Match $halBackend 'fpVidMem < hal->vramLinear \|\| surface->lpGbl->lPitch <= 0' (
    'Lazy registration must reject sentinel, below-framebuffer, and invalid-pitch addresses.'
)
Assert-Match $halBackend 'surface->dwReserved1 = request\.surface_id;' (
    'Lazy registration must cache the validated surface identity.'
)
Assert-Match $transport 'typedef struct GSWSurfaceRecord \{[\s\S]+DWORD owner_pid;' (
    '2D surface records must carry process ownership.'
)
Assert-Match $transport 'BOOL GSW_transport_surface_register\(GSWDDRegister \*request, DWORD owner_pid\)' (
    '2D surface registration must receive the caller process tag.'
)
Assert-Match $transport 'surface->owner_pid = owner_pid;' (
    '2D surface registration must persist the caller process tag.'
)
Assert-Match $transport 'void GSW_transport_process_cleanup\(DWORD owner_pid\)[\s\S]+surface->owner_pid != owner_pid[\s\S]+GSW_VGA_OPCODE_UNREGISTER_SURFACE[\s\S]+memset\(surface, 0, sizeof\(\*surface\)\);' (
    '2D process cleanup must unregister and reclaim only surfaces owned by the exiting process.'
)
Assert-Match $ioctl3d 'GSW3D_transport_context\([\s\S]+input\.context\.context_id,\s*params->tagProcess,' (
    '3D context creation must tag resources with DIOCParams.tagProcess.'
)
Assert-Match $transport3d 'typedef struct GSW3DContextRecord \{[\s\S]+DWORD id;[\s\S]+DWORD owner_pid;' (
    '3D context records must carry process ownership.'
)
Assert-Match $transport3d 'BOOL GSW3D_transport_context\([\s\S]+DWORD owner_pid' (
    '3D context creation and destruction must receive the caller process tag.'
)
Assert-Match $transport3d 'gsw3d_contexts\[slot\]\.owner_pid = owner_pid;' (
    '3D context creation must persist the caller process tag.'
)
Assert-Match $transport3d 'gsw3d_contexts\[slot\]\.owner_pid != owner_pid' (
    'Explicit 3D context destroy must not tear down another process owner.'
)
Assert-Match $transport3d 'void GSW3D_transport_process_cleanup\(DWORD owner_pid\)[\s\S]+gsw3d_contexts\[index\]\.owner_pid != owner_pid[\s\S]+GSW3D_OPCODE_DESTROY_CONTEXT[\s\S]+memset\(&gsw3d_contexts\[index\], 0' (
    '3D process cleanup must destroy and reclaim only contexts owned by the exiting process.'
)
Assert-Match $shutdownPatch 'win32_destroy_process_proc\(DWORD pid\)[\s\S]+GSW_transport_process_cleanup\(pid\);[\s\S]+GSW3D_transport_process_cleanup\(pid\);' (
    'The process-destroy lifecycle hook must reclaim both 2D and 3D GSW resources.'
)
Assert-Match $shutdownTrace 'GSW_MARK_DRIVER_DISABLING\s+0xD5[\s\S]+GSW_MARK_SYSTEM_EXIT\s+0xD6[\s\S]+GSW_MARK_DEVICE_EXIT_DONE\s+0xDC' (
    'The shutdown marker contract must distinguish display disable, System_Exit, and completed teardown.'
)
Assert-Match $transport 'GSW_MARK_TRANSPORT_WAIT[\s\S]+Wait_Semaphore\(gsw_semaphore, 0\);[\s\S]+GSW_MARK_TRANSPORT_ACQUIRED' (
    'The 2D shutdown semaphore must have before and after markers.'
)
Assert-Match $transport3d 'GSW_MARK_3D_WAIT[\s\S]+Wait_Semaphore\(gsw3d_semaphore, 0\);[\s\S]+GSW_MARK_3D_ACQUIRED' (
    'The 3D shutdown semaphore must have before and after markers.'
)
Assert-Match $vbe 'old_framebuffer != framebuffer \|\| old_framebuffer_bytes != framebuffer_bytes[\s\S]+!update_pm16\(ThisVM, hda->vram_pm16[\s\S]+return FALSE;[\s\S]+hda->vram_pm32 = framebuffer;' (
    'A changed Win16 framebuffer selector must update successfully before HDA publication.'
)
$validBody = Get-SimpleFunctionBody $vbe 'BOOL VBE_valid(void)'
$validModeBody = Get-SimpleFunctionBody $vbe 'BOOL VBE_validmode(DWORD width, DWORD height, DWORD bpp)'
$setModeBody = Get-SimpleFunctionBody $vbe 'BOOL VBE_setmode(DWORD width, DWORD height, DWORD bpp)'
Assert-Match $validBody 'GSW_transport_ready\(\) && GSW_base_VBE_valid\(\)' (
    'Driver validation must use only cached initialized state.'
)
Assert-NotMatch ($validBody + $validModeBody) 'GSW_transport_init|GSW_transport_rebind|GSW_bind_framebuffer|update_pm16|PCI_' (
    'Mode validation must remain side-effect-free during synchronous PnP enumeration.'
)
Assert-Match $validModeBody '!GSW_transport_ready\(\) \|\| hda == NULL' (
    'Mode validation must fail closed when the lifecycle binding is unavailable.'
)
Assert-Match $setModeBody 'if\(!GSW_transport_rebind\(\) \|\| !GSW_bind_framebuffer\(\)\)[\s\S]+return FALSE;' (
    'Serialized desktop mode restore must refresh PCI resources and rebind the framebuffer before mode programming.'
)
Assert-Match $pm16 'BOOL GSW_PM16_reconnect\(void\)[\s\S]+VXD_VM = 0;[\s\S]+vxd_fbhda16 = 0;[\s\S]+return VXD_VM_connect\(\);' (
    'The resident Win16 driver must discard a cached service vector before reconnecting.'
)

Assert-Match $lifecycle '(?m)^-    CallVDD\( VDD_PRE_MODE_CHANGE \);' (
    'SetDisplayMode must no longer own an unbalanced VDD PRE notification.'
)
Assert-Match $lifecycle '(?m)^\+    CallVDD\( VDD_PRE_MODE_CHANGE \);[\s\S]+PhysicalEnable: SetDisplayMode failed![\s\S]+^\+        CallVDD\( VDD_POST_MODE_CHANGE \);' (
    'PhysicalEnable must balance VDD notifications on mode-set failure.'
)
Assert-Match $lifecycle 'PhysicalEnable: continue[\s\S]+GSW_PM16_reconnect\(\)[\s\S]+FBHDA_setup\( &hda, &hda_linear \)' (
    'PhysicalEnable must reconnect and refresh FBHDA before validating a mode.'
)
Assert-Match $lifecycle '(?m)^ #ifdef VBE\r?\n\+#ifndef RETVRN99_GSW_DRIVER\r?\n     VBE_setmode\(wScrX, wScrY, wBpp\);\r?\n #endif\r?\n\+#endif' (
    'PhysicalEnable must not discard and rebind the live GSW transport a second time.'
)
Assert-Match (Get-Content -Raw -LiteralPath (Join-Path $root 'overlay\gsw.mak')) 'FLAGS \+= -DHWBLT -DRETVRN99_GSW_DRIVER' (
    'The GSW Win16 build must compile its lifecycle path explicitly.'
)
Assert-Match $lifecycle '(?m)RestoreDesktopMode: SetDisplayMode failed![\s\S]+^\+        CallVDD\( VDD_POST_MODE_CHANGE \);[\s\S]+^\+        lpDriverPDevice->deFlags \|= BUSY;\r?\n\+        wEnabled = 0;\r?\n\+        return;' (
    'RestoreDesktopMode must balance VDD notifications and remain disabled and BUSY on failure.'
)
Assert-Match $lifecycle '(?m)^\+    CallVDD\( VDD_POST_MODE_CHANGE \);\r?\n\+[\s\S]+Clear the busy flag' (
    'RestoreDesktopMode must publish success before it clears BUSY.'
)
Assert-Match $lifecycle 'RestoreDesktopMode\(\);[\s\S]+if\( lpDriverPDevice->deFlags & BUSY \)[\s\S]+return;[\s\S]+RepaintScreen\(\);' (
    'SwitchToFgnd must skip repaint and enable when desktop restore remains BUSY.'
)
Assert-Match $lifecycle 'BOOL update_pm16\(DWORD vm, DWORD oldmap, DWORD linear, DWORD size\)[\s\S]+return _SetDescriptor\(selector, vm, hi, low, 0\) != 0;' (
    'PM16 descriptor rebinding must report failure to the transactional caller.'
)
Assert-Match $lifecycle 'BOOL Hook_V86_Int_Chain\(DWORD int_num, DWORD HookProc\)[\s\S]+VMMCall\(Hook_V86_Int_Chain\)[\s\S]+setnc al[\s\S]+return result;' (
    'The V86 interrupt hook wrapper must preserve the VMM carry-clear success result.'
)
Assert-Match $lifecycle 'BOOL Unhook_V86_Int_Chain\(DWORD int_num, DWORD HookProc\)[\s\S]+VMMCall\(Unhook_V86_Int_Chain\)[\s\S]+setnc al[\s\S]+return result;' (
    'The V86 interrupt unhook wrapper must preserve the VMM carry-clear success result.'
)
Assert-Match $lifecycle 'if\(gsw_windows_hires_active && !mode_changing\)[\s\S]+if\(ah == 0\)[\s\S]+if\(al == 0x13\)[\s\S]+gsw_windows_hires_active = FALSE;[\s\S]+return 0;[\s\S]+return 1;[\s\S]+ah == 0x4F && al == 0x02[\s\S]+0xFFFF0000UL\) \| 0x034FUL;[\s\S]+return 1;' (
    'PnP BIOS standard and VBE mode sets must be blocked only while Windows owns high-resolution mode.'
)
Assert-Match $lifecycle 'if\(al == 0x13\)[\s\S]+gsw_windows_hires_active = FALSE;[\s\S]+return 0;' (
    'A WinQuake-style BIOS mode 13h request must release high-resolution ownership and continue to the VGA BIOS.'
)
Assert-Match $lifecycle 'cmp gsw_windows_hires_active,0[\s\S]+je _Virtual1CECheckOwner[\s\S]+ret[\s\S]+_Virtual1CECheckOwner:[\s\S]+VxDCall\(VDD, Get_VM_Info\)' (
    'Physical Bochs VBE port access must be swallowed before the ambiguous system-VM owner heuristic.'
)
Assert-Match $lifecycle 'REGISTER_DISPLAY_DRIVER, register_display_driver\)[\s\S]+state->Client_ESI = \(DWORD\)hda;[\s\S]+gsw_windows_hires_active = TRUE;[\s\S]+VDD_CY;' (
    'High-resolution ownership must begin only after successful display-driver registration.'
)
Assert-Match $lifecycle 'PRE_HIRES_TO_VGA, pre_hires_to_vga\)[\s\S]+gsw_windows_hires_active = FALSE;[\s\S]+mode_changing = TRUE;' (
    'A legitimate high-resolution-to-VGA transition must release the PnP mode-set guard first.'
)
Assert-Match $lifecycle 'POST_VGA_TO_HIRES, post_vga_to_hires\)[\s\S]+Enable_Global_Trapping\(0x1CE\);[\s\S]+Enable_Global_Trapping\(0x1CF\);' (
    'Returning to high resolution must trap Bochs VBE ports before a DOS-style PnP probe can alter the physical framebuffer.'
)
Assert-Match $lifecycle 'POST_VGA_TO_HIRES, post_vga_to_hires\)[\s\S]+mode_changing = FALSE;[\s\S]+gsw_windows_hires_active = TRUE;' (
    'A completed VGA-to-high-resolution transition must restore the PnP mode-set guard.'
)
Assert-Match $lifecycle 'DISPLAY_DRIVER_DISABLING, display_driver_disabling\)[\s\S]+gsw_windows_hires_active = FALSE;' (
    'Display-driver shutdown must release high-resolution ownership before BIOS mode changes.'
)
Assert-Match $lifecycle 'gsw_device_initializing = FALSE;[\s\S]+gsw_device_initialized = FALSE;' (
    'The VxD must track initialization and completion independently.'
)
Assert-Match $lifecycle 'call Device_Init_proc[\s\S]+dynamic init does not receive Init_Complete later[\s\S]+call Device_Init_Complete' (
    'Dynamic VxD startup must run the Init_Complete mapping hook.'
)
Assert-Match $lifecycle 'if\(gsw_device_initialized\)[\s\S]+return TRUE;' (
    'Duplicate Device_Init calls must not overwrite saved Main VDD dispatch entries.'
)
Assert-Match $lifecycle 'if\(gsw_device_initialized\)[\s\S]+return TRUE;[\s\S]+gsw_windows_hires_active = FALSE;' (
    'Duplicate Device_Init calls must preserve the active high-resolution guard.'
)
Assert-Match $lifecycle 'gsw_dispatch_installed = TRUE;[\s\S]+if\(!Hook_V86_Int_Chain\(0x10, \(\(DWORD\)virtual_int_10h\)\+8\)\)[\s\S]+Device_Exit_proc\(VM\);[\s\S]+return FALSE;[\s\S]+gsw_int10_hooked = TRUE;' (
    'The required INT 10h guard must install after fallible setup and fail initialization closed.'
)
Assert-Match $lifecycle 'if\(!gsw_device_initialized && !gsw_device_initializing\)[\s\S]+return TRUE;' (
    'Duplicate Device_Exit calls must be harmless.'
)
Assert-Match $lifecycle 'gsw_windows_hires_active = FALSE;[\s\S]+if\(gsw_int10_hooked\)[\s\S]+if\(!Unhook_V86_Int_Chain\(0x10, \(\(DWORD\)virtual_int_10h\)\+8\)\)[\s\S]+gsw_windows_hires_active = was_hires_active;[\s\S]+return FALSE;[\s\S]+gsw_device_initialized = FALSE;[\s\S]+GSW_restore_vdd_dispatch\(\);' (
    'Dynamic unload must retain all VxD state when the INT 10h hook cannot be removed.'
)
Assert-Match $lifecycle 'Sys_Dynamic_Device_Exit[\s\S]+call Device_Exit_proc[\s\S]+test eax,eax[\s\S]+jz control_dynamic_exit_failed[\s\S]+control_dynamic_exit_failed:[\s\S]+stc' (
    'A failed unhook must reject dynamic VxD unload with carry set.'
)
Assert-NotMatch $lifecycle 'gsw_trace_char|3f8h|out dx,al' (
    'Production lifecycle changes must not contain diagnostic UART tracing.'
)

Write-Host 'PASS GSW-VGA validation remains side-effect-free during PCI ConfigMgr enumeration.'
Write-Host 'PASS GSW-VGA desktop restore balances VDD notifications and stays BUSY on failure.'
Write-Host 'PASS GSW-VGA dynamic initialization is idempotent and completes framebuffer mapping.'
Write-Host 'PASS GSW-VGA Win16 enable refreshes a dynamically reloaded mini-VDD service vector.'
Write-Host 'PASS GSW-VGA physical enable avoids a redundant destructive transport rebind.'
Write-Host 'PASS GSW-VGA blocks PnP BIOS mode sets while preserving explicit VGA transitions.'
Write-Host 'PASS GSW-VGA installs and removes its V86 INT 10h hook with fail-closed unload semantics.'
Write-Host 'PASS GSW-VGA DirectDraw and 3D resources carry process ownership for lifecycle cleanup.'
Write-Host 'PASS GSW-VGA DirectDraw defers surface registration until runtime allocation.'
