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

function Assert-GswLowModeSourceContract {
    param([string]$PatchText, [string]$InfText)

    if ([regex]::Matches($PatchText, '(?m)^diff --git ').Count -ne 1) {
        throw 'The low-mode patch must modify exactly one source file.'
    }
    Assert-Match $PatchText '(?m)^diff --git a/modes\.c b/modes\.c\r?$' (
        'The low-mode patch must modify only modes.c.'
    )
    Assert-Match $PatchText '(?m)^\+\s+if\( \(lpMode->xRes != 320 \|\| lpMode->yRes != 240 \|\| lpMode->bpp != 8\) &&\r?$' (
        'FixModeInfo must bind the exact 320x240x8 exception.'
    )
    Assert-Match $PatchText '(?m)^\+\s+\(lpMode->xRes < 640 \|\| lpMode->yRes < 480\) \)\r?$' (
        'FixModeInfo must preserve the original low-resolution boundary.'
    )
    Assert-Match $PatchText '(?m)^-\s+if\( lpMode->xRes < 640 \|\| lpMode->yRes < 480 \)\r?$' (
        'The patch must remove the upstream unconditional low-resolution guard.'
    )
    Assert-NotMatch $PatchText '(?m)^\+\s+if\( lpMode->xRes < 640 \|\| lpMode->yRes < 480 \)\r?$' (
        'The patch must not add an unconditional low-resolution guard.'
    )

    $modeRows = [regex]::Matches(
        $InfText,
        '(?m)^HKR,"MODES\\(?<bpp>[0-9]+)\\(?<x>[0-9]+),(?<y>[0-9]+)"(?<tail>[^\r\n]*)\r?$'
    )
    if ($modeRows.Count -ne 88) {
        throw "The INF must contain the prior 87 modes plus one low mode; found $($modeRows.Count)."
    }
    $lowRows = @(
        foreach ($row in $modeRows) {
            if (
                [int]$row.Groups['x'].Value -lt 640 -or
                [int]$row.Groups['y'].Value -lt 480
            ) {
                $row
            }
        }
    )
    if ($lowRows.Count -ne 1) {
        throw "The INF must contain exactly one low mode; found $($lowRows.Count)."
    }
    $lowRow = $lowRows[0]
    if (
        [int]$lowRow.Groups['bpp'].Value -ne 8 -or
        [int]$lowRow.Groups['x'].Value -ne 320 -or
        [int]$lowRow.Groups['y'].Value -ne 240 -or
        $lowRow.Groups['tail'].Value -cne ''
    ) {
        throw 'The INF low-mode inventory must contain only the bare 8\320,240 row.'
    }
}

function Test-GswFixModeInfoAccepted {
    param([int]$X, [int]$Y, [int]$Bpp)

    $supportedBpp = $Bpp -in @(8, 16, 24, 32)
    $normalizedBpp = if ($supportedBpp) { $Bpp } else { 8 }
    $lowModeRejected = (
        ($X -ne 320 -or $Y -ne 240 -or $normalizedBpp -ne 8) -and
        ($X -lt 640 -or $Y -lt 480)
    )
    return $supportedBpp -and -not $lowModeRejected
}

function Assert-GswLowModeMutationRejected {
    param([string]$PatchText, [string]$InfText, [string]$Message)

    try {
        Assert-GswLowModeSourceContract -PatchText $PatchText -InfText $InfText
    } catch {
        return
    }
    throw $Message
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

function Get-SwitchCaseBody {
    param([string]$Text, [string]$CaseLabel)

    $label = [regex]::Escape($CaseLabel)
    $pattern = '(?ms)^\s*case\s+' + $label + ':\s*(?<body>.*?)(?=^\s*(?:case\s+|default:))'
    $match = [regex]::Match($Text, $pattern)
    if (-not $match.Success) {
        throw "Missing switch case: $CaseLabel"
    }
    return $match.Groups['body'].Value
}

function Get-PatchDeltaText {
    param([string]$PatchText, [char]$Prefix)

    return @(
        foreach ($line in ($PatchText -split "`r?`n")) {
            if (
                $line.Length -gt 0 -and
                $line[0] -ceq $Prefix -and
                -not $line.StartsWith("$Prefix$Prefix$Prefix")
            ) {
                $line.Substring(1)
            }
        }
    ) -join "`n"
}

$root = Join-Path $PSScriptRoot '..\drivers\win98\derived\vmdisp9x-gsw'
$halRoot = Join-Path $PSScriptRoot '..\drivers\win98\derived\vmhal9x-gsw'
$transport = Get-Content -Raw -LiteralPath (Join-Path $root 'overlay\gsw_transport.c')
$transport3d = Get-Content -Raw -LiteralPath (Join-Path $root 'overlay\gsw3d_transport.c')
$ddraw = Get-Content -Raw -LiteralPath (Join-Path $root 'overlay\gsw_ddraw.c')
$ioctl3d = Get-Content -Raw -LiteralPath (Join-Path $root 'overlay\gsw3d_ioctl.c')
$header = Get-Content -Raw -LiteralPath (Join-Path $root 'overlay\gsw_transport.h')
$shutdownTrace = Get-Content -Raw -LiteralPath (Join-Path $root 'overlay\gsw_shutdown_trace.h')
$modePatch = Get-Content -Raw -LiteralPath (
    Join-Path $root 'patches\0011-gsw-320x240x8-mode.patch'
)
$arbiterPatch = Get-Content -Raw -LiteralPath (
    Join-Path $root 'patches\0013-gsw-display-arbiter.patch'
)
$arbiterAdded = Get-PatchDeltaText -PatchText $arbiterPatch -Prefix '+'
$arbiterRemoved = Get-PatchDeltaText -PatchText $arbiterPatch -Prefix '-'
$displayAdapter = Get-Content -Raw -LiteralPath (
    Join-Path $root 'overlay\gsw_display_adapter.c'
)
$displayAdapterHeader = Get-Content -Raw -LiteralPath (
    Join-Path $root 'overlay\gsw_display_adapter.h'
)
$displayArbiter = Get-Content -Raw -LiteralPath (
    Join-Path $root 'overlay\gsw_display_arbiter.c'
)
$displayArbiterHeader = Get-Content -Raw -LiteralPath (
    Join-Path $root 'overlay\gsw_display_arbiter.h'
)
$deviceRegisteredCase = Get-SwitchCaseBody $displayArbiter 'GSW_DISPLAY_EVENT_DEVICE_REGISTERED'
$desktopProgrammedCase = Get-SwitchCaseBody $displayArbiter 'GSW_DISPLAY_EVENT_DESKTOP_PROGRAMMED'
$desktopProgramFailedCase = Get-SwitchCaseBody $displayArbiter 'GSW_DISPLAY_EVENT_DESKTOP_PROGRAM_FAILED'
$ddrawExclusiveBeginCase = Get-SwitchCaseBody $displayArbiter 'GSW_DISPLAY_EVENT_DDRAW_EXCLUSIVE_BEGIN'
$ddrawExclusiveEndCase = Get-SwitchCaseBody $displayArbiter 'GSW_DISPLAY_EVENT_DDRAW_EXCLUSIVE_END'
$vddPreForegroundBody = Get-SimpleFunctionBody $displayAdapter (
    'void GSW_display_vdd_pre_foreground(unsigned long vm)'
)
$vddPreDesktopBody = Get-SimpleFunctionBody $displayAdapter (
    'void GSW_display_vdd_pre_desktop(unsigned long vm)'
)
$desktopProgrammedBody = Get-SimpleFunctionBody $displayAdapter (
    'void GSW_display_desktop_programmed(unsigned long vm)'
)
$desktopProgramFailedBody = Get-SimpleFunctionBody $displayAdapter (
    'void GSW_display_desktop_program_failed(unsigned long vm)'
)
$systemQuiesceBody = Get-SimpleFunctionBody $arbiterAdded (
    'static void GSW_system_quiesce(DWORD VM)'
)
$criticalExitBody = Get-SimpleFunctionBody $arbiterAdded (
    'void __stdcall GSW_critical_exit_proc(DWORD VM)'
)
$gswMake = Get-Content -Raw -LiteralPath (Join-Path $root 'overlay\gsw.mak')
$inf = Get-Content -Raw -LiteralPath (Join-Path $root 'overlay\gswmini.inf')
$versionResource = Get-Content -Raw -LiteralPath (Join-Path $root 'overlay\res\gswmini.rc')
$shutdownPatch = Get-Content -Raw -LiteralPath (
    Join-Path $root 'patches\0010-gsw-process-shutdown.patch'
)
$vxdMain = Get-Content -Raw -LiteralPath (Join-Path $root 'overlay\vxd_main_gsw.c')
$vbe = Get-Content -Raw -LiteralPath (Join-Path $root 'overlay\vxd_vbe_gsw.c')
$vbeQuiesceBody = Get-SimpleFunctionBody $vbe 'void GSW_VBE_quiesce(void)'
$pm16 = Get-Content -Raw -LiteralPath (Join-Path $root 'overlay\pm16_calls_gsw.c')
$lifecycle = Get-Content -Raw -LiteralPath (
    Join-Path $root 'patches\0009-gsw-pnp-display-lifecycle.patch'
)
$halDdraw = Get-Content -Raw -LiteralPath (Join-Path $halRoot 'overlay\gsw_ddraw.c')
$halBackend = Get-Content -Raw -LiteralPath (Join-Path $halRoot 'overlay\gsw_backend.c')

Assert-GswLowModeSourceContract -PatchText $modePatch -InfText $inf
Assert-Match $inf '(?m)^DriverVer=07/26/2026,0\.2\.0\.8\r?$' (
    'The PnP package must advertise driver version 0.2.0.8 dated 07/26/2026.'
)
Assert-Match $versionResource '(?m)^FILEVERSION 0,2,0,8\r?$' (
    'The Win16 file version must be 0.2.0.8.'
)
Assert-Match $versionResource '(?m)^PRODUCTVERSION 0,2,0,8\r?$' (
    'The Win16 product version must be 0.2.0.8.'
)
Assert-Match $versionResource 'VALUE "FileVersion", "0\.2\.0\.8\\0"' (
    'The Win16 string file version must be 0.2.0.8.'
)
Assert-Match $versionResource 'VALUE "ProductVersion", "0\.2\.0\.8\\0"' (
    'The Win16 string product version must be 0.2.0.8.'
)
Assert-NotMatch ($inf + $versionResource) '0\.2\.0\.6|0,2,0,6' (
    'The 0.2.0.6 version must not remain in the new package metadata.'
)

$newlyAdmitted = @(
    foreach ($x in @(1, 319, 320, 321, 400, 512, 639, 640, 641)) {
        foreach ($y in @(1, 200, 239, 240, 241, 300, 384, 479, 480, 481)) {
            foreach ($bpp in @(0, 7, 8, 15, 16, 24, 32, 64)) {
                $oldAccepted = $bpp -in @(8, 16, 24, 32) -and $x -ge 640 -and $y -ge 480
                $newAccepted = Test-GswFixModeInfoAccepted -X $x -Y $y -Bpp $bpp
                if ($oldAccepted -and -not $newAccepted) {
                    throw "The low-mode exception rejected an existing mode: ${x}x${y}x${bpp}."
                }
                if (-not $oldAccepted -and $newAccepted) {
                    "${x}x${y}x${bpp}"
                }
            }
        }
    }
)
if (($newlyAdmitted -join ',') -cne '320x240x8') {
    throw "Only 320x240x8 may be newly admitted; found: $($newlyAdmitted -join ',')."
}

$patchMutations = @(
    $modePatch.Replace(' || lpMode->bpp != 8', ''),
    $modePatch.Replace(') &&', ') ||'),
    $modePatch.Replace(
        'lpMode->xRes != 320 || lpMode->yRes != 240',
        'lpMode->xRes != 320 && lpMode->yRes != 240'
    )
)
foreach ($mutation in $patchMutations) {
    if ($mutation -ceq $modePatch) { throw 'A low-mode patch mutation did not alter its fixture.' }
    Assert-GswLowModeMutationRejected -PatchText $mutation -InfText $inf (
        'A broadened low-mode source guard was accepted.'
    )
}
$infMutations = @(
    $inf.Replace('HKR,"MODES\8\640,480"', "HKR,`"MODES\8\400,300`"`r`nHKR,`"MODES\8\640,480`""),
    $inf.Replace('HKR,"MODES\8\320,240"', "HKR,`"MODES\8\320,240`"`r`nHKR,`"MODES\16\320,240`"")
)
foreach ($mutation in $infMutations) {
    if ($mutation -ceq $inf) { throw 'A low-mode INF mutation did not alter its fixture.' }
    Assert-GswLowModeMutationRejected -PatchText $modePatch -InfText $mutation (
        'A broadened low-mode INF inventory was accepted.'
    )
}

Assert-Match $arbiterRemoved 'bRestoreSwitchHooks = !bReEnabling \|\| !Int2FhHooked\(\);' (
    'The display-arbiter patch must explicitly supersede the screen-switch re-entry heuristic.'
)
Assert-Match $arbiterRemoved 'extern BOOL Int2FhHooked\( void \);' (
    'The display-arbiter patch must remove the screen-switch hook query introduced by patch 0012.'
)
Assert-Match $arbiterRemoved '#define INT_2F_SAVED\s+0x02' (
    'The display-arbiter patch must remove patch 0012 saved-chain state.'
)
Assert-Match $arbiterPatch '(?m)^\+        if\( !bReEnabling \) \{\r?\n^             int_2Fh\( STOP_IO_TRAP \);[\s\S]+^\+        if\( !bReEnabling \) \{\r?\n^             HookInt2Fh\(\);' (
    'Patch 0013 must restore the original bounded Win16 Enable hook conditions explicitly.'
)
Assert-Match $arbiterAdded 'selAlias = AllocCStoDSAlias[\s\S]+DOSGetIntVec\( 0x2F \)[\s\S]+DOSSetIntVec\( 0x2F, SWHook \);[\s\S]+FreeSelector\( selAlias \);' (
    'Patch 0013 must restore one ordinary INT 2Fh chain capture per real hook installation.'
)
Assert-NotMatch $arbiterAdded 'bRestoreSwitchHooks|Int2FhHooked|INT_2F_SAVED' (
    'No part of the superseded screen-switch re-entry heuristic may survive in the patch result.'
)

Assert-Match $arbiterRemoved 'BOOL gsw_windows_hires_active = FALSE;' (
    'Patch 0013 must remove the Boolean high-resolution ownership surrogate.'
)
Assert-Match $arbiterRemoved 'extern BOOL mode_changing;' (
    'The INT 10h policy path must stop reading the upstream mode_changing implementation flag.'
)
Assert-NotMatch $arbiterAdded 'gsw_windows_hires_active|GSW_MARK_INT10_MODE13|if\s*\(\s*al\s*==\s*0x13\s*\)' (
    'Patch 0013 must not retain a mode-13 exception or Boolean display authority.'
)
Assert-NotMatch ($displayAdapter + $displayAdapterHeader + $displayArbiter + $displayArbiterHeader) (
    'gsw_windows_hires_active|GSW_MARK_INT10_MODE13|mode_changing'
) 'Display arbitration must not depend on the retired high-resolution flag or mode_changing policy reads.'
Assert-NotMatch $arbiterAdded '(?m)^.*(?:if|while|&&|\|\|)[^\r\n]*mode_changing' (
    'Patch 0013 may preserve upstream mode_changing assignments but must not add a policy read.'
)
Assert-Match $arbiterAdded 'GSW_display_bios_mode_set\(vm, al\)[\s\S]+GSW_MARK_INT10_MODE_SET' (
    'Every BIOS standard mode set must use the arbiter before the generic mode-set marker.'
)

Assert-Match $arbiterAdded 'GSW_display_vdd_pre_foreground\(vm\);[\s\S]+GSW_display_vdd_post_foreground\(vm\);[\s\S]+GSW_display_vdd_pre_desktop\(vm\);[\s\S]+GSW_display_vdd_post_desktop\(vm\);' (
    'The mini-VDD callbacks must preserve all four directional VDD boundaries.'
)
foreach ($body in @(
    $vddPreForegroundBody,
    $vddPreDesktopBody,
    $desktopProgrammedBody,
    $desktopProgramFailedBody
)) {
    Assert-Match $body 'gsw_display_state\.lifecycle != GSW_DISPLAY_REGISTERED[\s\S]+return;[\s\S]+GSW_display_emit' (
        'PRE and programming callbacks must be dropped until registration opens the conventional transition.'
    )
}
Assert-Match $displayAdapter 'GSW_display_vdd_post_foreground\(unsigned long vm\)[\s\S]+owner = GSW_display_physical_owner\(vm\);[\s\S]+GSW_DISPLAY_EVENT_VDD_POST_FOREGROUND[\s\S]+GSW_DISPLAY_EVENT_PHYSICAL_OWNER_FRESH' (
    'Foreground POST must carry a fresh physical-owner observation.'
)
Assert-Match $displayAdapter 'GSW_display_vdd_post_desktop\(unsigned long vm\)[\s\S]+owner = GSW_display_physical_owner\(vm\);[\s\S]+GSW_DISPLAY_EVENT_VDD_POST_DESKTOP[\s\S]+GSW_DISPLAY_EVENT_PHYSICAL_OWNER_FRESH' (
    'Desktop POST must carry a fresh physical-owner observation.'
)
Assert-Match $displayArbiter 'GSW_DISPLAY_EVENT_VDD_PRE_FOREGROUND[\s\S]+state\.transition == GSW_DISPLAY_DESKTOP_RECONFIGURE[\s\S]+GSW_DISPLAY_TO_FOREGROUND_VGA' (
    'A same-VM DirectDraw reconfigure must refine into the directional foreground transition.'
)
Assert-Match $displayArbiter 'GSW_DISPLAY_EVENT_VDD_PRE_DESKTOP[\s\S]+state\.transition == GSW_DISPLAY_DESKTOP_RECONFIGURE[\s\S]+GSW_DISPLAY_TO_WINDOWS_DESKTOP' (
    'A same-Windows DirectDraw reconfigure must refine into the directional desktop transition.'
)
Assert-Match $displayArbiter 'fresh && event\.observed_physical_owner != target_vm[\s\S]+protocol_fault = 1U;[\s\S]+exact \|\| fresh[\s\S]+gsw_display_commit_authority' (
    'POST must preserve prior authority on contradictory fresh ownership and commit only exact or fresh matching transitions.'
)

Assert-Match $arbiterPatch 'rs = VBE_setmode[\s\S]+if\(rs\)[\s\S]+GSW_display_desktop_programmed\(ThisVM\);[\s\S]+else[\s\S]+GSW_display_desktop_program_failed\(ThisVM\);' (
    'Direct desktop programming must report the existing VBE operation result without inventing transition authority.'
)
Assert-NotMatch $arbiterAdded 'GSW_display_desktop_programming\(ThisVM\);' (
    'OP_VBE_SETMODE must not manufacture desktop-reconfigure authority over a real directional VDD PRE.'
)
Assert-NotMatch $arbiterAdded 'GSW_display_desktop_programmed\(vm\);' (
    'Pinned VMDisp9x SAVE_REGISTERS must remain a NOP rather than acting as a synthetic success fence.'
)
Assert-Match $arbiterPatch 'VDDPROC\(SAVE_REGISTERS, save_registers\)[\s\S]+Ownership is committed only by VDD POST callbacks\.[\s\S]+VDDPROC\(RESTORE_REGISTERS, restore_registers\)' (
    'The derived SAVE_REGISTERS result must remain an explicit ownership NOP.'
)
Assert-Match $displayAdapter 'GSW_display_desktop_programmed\(unsigned long vm\)[\s\S]+GSW_MARK_DESKTOP_PROGRAMMED[\s\S]+GSW_DISPLAY_EVENT_DESKTOP_PROGRAMMED' (
    'Successful desktop programming must emit its lifecycle event and marker.'
)
Assert-Match $displayAdapter 'GSW_display_desktop_program_failed\(unsigned long vm\)[\s\S]+GSW_DISPLAY_EVENT_DESKTOP_PROGRAM_FAILED' (
    'Failed desktop programming must emit a distinct failure event.'
)
Assert-Match $displayArbiterHeader 'GSW_DISPLAY_EVENT_DESKTOP_PROGRAMMED,[\s\S]+GSW_DISPLAY_EVENT_DESKTOP_PROGRAM_FAILED,' (
    'The pure arbiter interface must distinguish desktop programming success from failure.'
)
Assert-NotMatch ($displayAdapter + $displayAdapterHeader + $displayArbiter + $displayArbiterHeader) 'GSW_DISPLAY_EVENT_(?:VDD_(?:PRE|POST)_RECONFIGURE|DESKTOP_PROGRAMMING)|GSW_display_desktop_programming' (
    'Desktop completion must not depend on a synthetic PRE or reconfigure event.'
)
Assert-Match $desktopProgrammedCase 'state\.transition == GSW_DISPLAY_DESKTOP_RECONFIGURE &&[\s\S]+state\.transition_vm == state\.windows_vm[\s\S]+gsw_display_commit_authority\([\s\S]+GSW_DISPLAY_WINDOWS_DESKTOP' (
    'Desktop success may commit authority only from an owned desktop-reconfigure transition.'
)
Assert-Match $desktopProgrammedCase 'state\.transition == GSW_DISPLAY_TO_WINDOWS_DESKTOP &&[\s\S]+state\.transition_vm == state\.windows_vm[\s\S]+break;' (
    'Desktop success inside a real VDD desktop transition must defer authority to VDD POST.'
)
Assert-NotMatch $desktopProgrammedCase 'GSW_DISPLAY_TO_WINDOWS_DESKTOP[\s\S]+gsw_display_commit_authority' (
    'Desktop success must not commit a directional VDD transition early.'
)
Assert-Match $desktopProgramFailedCase 'state\.transition == GSW_DISPLAY_TRANSITION_NONE\)[\s\S]+break;' (
    'A duplicate desktop-programming failure with no active transition must be idempotent.'
)
Assert-Match $desktopProgramFailedCase 'state\.transition_vm == state\.windows_vm\)[\s\S]+result\.next\.transition = GSW_DISPLAY_TRANSITION_NONE;[\s\S]+result\.next\.transition_vm = 0UL;' (
    'Desktop failure must cancel only the matching Windows transition without inventing authority.'
)

Assert-Match $deviceRegisteredCase 'state\.lifecycle == GSW_DISPLAY_DISABLING &&[\s\S]+event\.vm != 0UL && event\.vm == state\.windows_vm[\s\S]+result\.next\.lifecycle = GSW_DISPLAY_REGISTERED;[\s\S]+GSW_DISPLAY_DESKTOP_RECONFIGURE,[\s\S]+state\.windows_vm' (
    'A full ReEnable must re-register only the retained nonzero Windows VM and begin desktop reconfiguration.'
)
Assert-NotMatch $deviceRegisteredCase 'generation' (
    'Re-registration must leave the authority generation unchanged until desktop programming succeeds.'
)
Assert-Match $arbiterPatch 'VDDPROC\(REGISTER_DISPLAY_DRIVER, register_display_driver\)[\s\S]+GSW_display_device_registered\(vm\);' (
    'Every successful VDD display-driver registration, including full ReEnable, must reach the arbiter.'
)

Assert-Match $displayAdapter 'GSW_display_dispi_access\(unsigned long vm\)[\s\S]+owner = GSW_display_physical_owner\(vm\);[\s\S]+vm != 0UL && vm == owner[\s\S]+GSW_DISPLAY_EVENT_PHYSICAL_OWNER[\s\S]+GSW_DISPLAY_EVENT_PHYSICAL_OWNER_FRESH[\s\S]+GSW_DISPLAY_EVENT_DISPI_ACCESS' (
    'DISPI access must first reconcile only a fresh matching physical owner, then apply request policy.'
)
Assert-Match $displayAdapter 'GSW_display_physical_owner\(unsigned long vm\)[\s\S]+mov ebx, \[vm\][\s\S]+VxDCall\(VDD, Get_VM_Info\);[\s\S]+mov \[owner\], edi[\s\S]+return owner;' (
    'The adapter must query VDD_Get_VM_Info with the caller VM and preserve the physical CRTC owner from EDI.'
)
Assert-Match $arbiterPatch 'call GSW_display_dispi_access[\s\S]+test eax,eax[\s\S]+jz _Virtual1CEPhysical[\s\S]+ret[\s\S]+VxDJmp\(VDD, Do_Physical_IO\);' (
    'The DISPI trap must reach physical I/O only when the arbiter returns Forward.'
)

Assert-Match $displayArbiterHeader '#define GSW_DISPLAY_VBE_REJECT_AX 0x034FU' (
    'The portable contract must define the required VBE failure AX value.'
)
Assert-Match $displayArbiterHeader 'typedef struct GSW_Display_Result \{[\s\S]+GSW_Display_Action action;[\s\S]+unsigned short vbe_ax;' (
    'The arbiter result must carry the VBE AX response alongside its action.'
)
Assert-Match $displayArbiter 'result->action = GSW_DISPLAY_REJECT_VBE;[\s\S]+result->vbe_ax = GSW_DISPLAY_VBE_REJECT_AX;' (
    'Every rejected VBE request must publish AX=034F through the result.'
)
Assert-Match $displayAdapterHeader 'GSW_Display_Result GSW_display_vbe_mode_set\(' (
    'The VBE adapter must return the complete arbiter result, not only its action.'
)
Assert-Match $displayAdapter 'GSW_Display_Result GSW_display_vbe_mode_set\([\s\S]+return GSW_display_emit\([\s\S]+GSW_DISPLAY_EVENT_VBE_MODE_SET[\s\S]+\);' (
    'The VBE adapter must preserve Result.vbe_ax when returning the arbiter decision.'
)
Assert-NotMatch $displayAdapter 'GSW_DISPLAY_EVENT_VBE_MODE_SET,\s*vm,\s*0UL,\s*mode,\s*0U\s*\)\.action;' (
    'The VBE adapter must not truncate its result to the action field.'
)
Assert-Match $arbiterAdded 'result = GSW_display_vbe_mode_set[\s\S]+result\.action == GSW_DISPLAY_REJECT_VBE[\s\S]+result\.vbe_ax' (
    'The INT 10h adapter must use Result.vbe_ax rather than hard-coding or discarding it.'
)

Assert-Match $arbiterPatch 'GSW_MARK_SYSTEM_EXIT[\s\S]+call GSW_system_exit_proc[\s\S]+#endif[\s\S]+pushad[\s\S]+push ebx ; VM handle' (
    'System Exit must quiesce GSW before the existing ordinary teardown sequence.'
)
Assert-Match $lifecycle 'cmp eax,System_Exit[\s\S]+push ebx ; VM handle[\s\S]+call Device_Exit_proc' (
    'The existing System Exit sequence must still delegate to Device Exit after lifecycle publication.'
)
Assert-Match $systemQuiesceBody 'GSW_display_system_exit\(VM\);[\s\S]+if\(is_qemu\)[\s\S]+GSW_VBE_quiesce\(\);[\s\S]+GSW_MARK_SYSTEM_DISPLAY_QUIESCED[\s\S]+GSW_restore_vdd_dispatch\(\);' (
    'Terminal exit must publish forward-only ownership, directly quiesce DISPI, and restore the borrowed VDD dispatch.'
)
Assert-Match $arbiterAdded 'static BOOL gsw_system_exiting = FALSE;' (
    'The VxD must distinguish terminal System Exit from a rejectable dynamic unload.'
)
Assert-Match $arbiterPatch 'gsw_system_exiting = FALSE;[\s\S]+gsw_device_initializing = TRUE;' (
    'Each device initialization must clear terminal-exit policy before fallible setup begins.'
)
Assert-Match $arbiterAdded 'GSW_system_exit_proc\(DWORD VM\)[\s\S]+gsw_system_exiting = TRUE;[\s\S]+GSW_system_quiesce\(VM\);' (
    'System Exit must enable terminal cleanup before the ordinary Device Exit callback runs.'
)
Assert-Match $vbeQuiesceBody 'outpw\(VBE_DISPI_IOPORT_INDEX, VBE_DISPI_INDEX_ENABLE\);[\s\S]+outpw\(VBE_DISPI_IOPORT_DATA, VBE_DISPI_DISABLED\);' (
    'Terminal exit must disable the GSW DISPI extension without BIOS nesting.'
)
Assert-Match $arbiterPatch 'cmp eax,Sys_Critical_Exit[\s\S]+call GSW_critical_exit_proc' (
    'Sys_Critical_Exit must reach the bounded owned-hook fallback.'
)
Assert-Match $criticalExitBody 'GSW_MARK_CRITICAL_EXIT_ENTER[\s\S]+GSW_system_quiesce\(VM\);[\s\S]+if\(!gsw_int10_hooked\)[\s\S]+Unhook_V86_Int_Chain[\s\S]+gsw_int10_hooked = FALSE;[\s\S]+GSW_MARK_CRITICAL_UNHOOKED[\s\S]+GSW_MARK_CRITICAL_UNHOOK_FAILED' (
    'Critical exit must idempotently retry only the outstanding owned INT 10h hook and mark its result.'
)
Assert-NotMatch ($systemQuiesceBody + $criticalExitBody) 'Device_Exit_proc|PhysicalDisable|\bint_10h\s*\(|Exec_Int|Simulate_Int|Wait_|Create_|Destroy_|GSW_transport_(?:shutdown|release)|FBHDA_release_hw|wram_release|mouse_release' (
    'Terminal quiesce and critical fallback must not allocate, wait, invoke BIOS, or run general teardown.'
)
Assert-Match $arbiterPatch 'if\(gsw_int10_hooked\)[\s\S]+if\(!Unhook_V86_Int_Chain[\s\S]+if\(!gsw_system_exiting\)[\s\S]+return FALSE;[\s\S]+else[\s\S]+gsw_int10_hooked = FALSE;[\s\S]+GSW_display_device_exit\(VM\);[\s\S]+gsw_device_initialized = FALSE;[\s\S]+GSW_restore_vdd_dispatch\(\);' (
    'Dynamic unload must remain fail-closed, while terminal cleanup continues with an outstanding hook for Critical Exit.'
)
Assert-NotMatch $criticalExitBody 'Device_Exit_proc|GSW_transport_release|FBHDA_release_hw|wram_release|mouse_release' (
    'Critical Exit must not resume or duplicate the ordinary cleanup completed during System Exit.'
)

Assert-Match $shutdownTrace 'GSW_MARK_DRIVER_DISABLING\s+0xD5' (
    'The mini-VDD driver-disabling boundary must retain marker D5.'
)
$win16DisableEnterMarker = [regex]::Match(
    $shutdownTrace,
    '(?m)^#define GSW_MARK_WIN16_DISABLE_ENTER\s+0x(?<value>[0-9A-Fa-f]{2})\s*$'
)
if (-not $win16DisableEnterMarker.Success) {
    throw 'The Win16 Disable entry boundary must have a fixed shutdown marker.'
}
if ($win16DisableEnterMarker.Groups['value'].Value.ToUpperInvariant() -eq 'D5') {
    throw 'The Win16 Disable entry marker must not alias the mini-VDD D5 boundary.'
}
if ($win16DisableEnterMarker.Groups['value'].Value.ToUpperInvariant() -ne 'DF') {
    throw 'The distinct Win16 Disable entry boundary must retain marker DF.'
}
Assert-Match $shutdownTrace 'GSW_MARK_WIN16_TRAPS_STARTED\s+0xE0[\s\S]+GSW_MARK_WIN16_PHYSICAL_OFF\s+0xE1[\s\S]+GSW_MARK_WIN16_UNREGISTERED\s+0xE2[\s\S]+GSW_MARK_WIN16_TEXT_RESTORED\s+0xE3[\s\S]+GSW_MARK_WIN16_HOOK_REMOVED\s+0xE4' (
    'The shutdown trace must assign the ordered Win16 disable stages to E0-E4.'
)
Assert-Match $shutdownTrace 'GSW_MARK_SYSTEM_DISPLAY_QUIESCED\s+0xE8[\s\S]+GSW_MARK_CRITICAL_EXIT_ENTER\s+0xE9[\s\S]+GSW_MARK_CRITICAL_UNHOOKED\s+0xEA[\s\S]+GSW_MARK_CRITICAL_UNHOOK_FAILED\s+0xEB' (
    'Terminal shutdown must retain distinct quiesce and critical-unhook markers.'
)
Assert-Match $arbiterPatch 'GSW_MARK_WIN16_DISABLE_ENTER[\s\S]+int_2Fh\( START_IO_TRAP \);[\s\S]+GSW_MARK_WIN16_TRAPS_STARTED[\s\S]+PhysicalDisable\(\);[\s\S]+GSW_MARK_WIN16_PHYSICAL_OFF[\s\S]+CallVDD\( VDD_DRIVER_UNREGISTER \);[\s\S]+GSW_MARK_WIN16_UNREGISTERED[\s\S]+int_10h\( 3 \);[\s\S]+GSW_MARK_WIN16_TEXT_RESTORED[\s\S]+UnhookInt2Fh\(\);[\s\S]+GSW_MARK_WIN16_HOOK_REMOVED' (
    'Win16 Disable must mark trap start, physical disable, unregister, text restoration, and unhook in execution order.'
)
Assert-Match $arbiterPatch 'DISPLAY_DRIVER_DISABLING, display_driver_disabling\)[\s\S]+GSW_MARK_DRIVER_DISABLING[\s\S]+GSW_display_driver_disabling\(vm\);' (
    'The D5 mini-VDD callback must enter the arbiter disabling lifecycle.'
)

$setExclusiveBody = Get-SimpleFunctionBody $halDdraw (
    'DDENTRY(SetExclusiveMode32, LPDDHAL_SETEXCLUSIVEMODEDATA, data)'
)
Assert-Match $setExclusiveBody 'if\(data == NULL\) return DDHAL_DRIVER_NOTHANDLED;[\s\S]+if\(data->dwEnterExcl\)[\s\S]+FBHDA_access_begin\(FBHDA_ACCESS_EXCLUSIVE_BEGIN\);[\s\S]+else[\s\S]+FBHDA_access_begin\(FBHDA_ACCESS_EXCLUSIVE_END\);[\s\S]+FBHDA_access_end\(0\);' (
    'SetExclusiveMode must restore the existing FBHDA exclusive begin/end flag ABI and balance access.'
)
Assert-Match $setExclusiveBody 'data->ddRVal = DD_OK;[\s\S]+return DDHAL_DRIVER_NOTHANDLED;' (
    'SetExclusiveMode must notify the existing ABI and still forward handling to DirectDraw.'
)
Assert-Match $arbiterPatch 'case OP_FBHDA_ACCESS_BEGIN:[\s\S]+GSW_display_ddraw_exclusive\(vmhandle, inBuf\[0\]\);[\s\S]+FBHDA_access_begin\(inBuf\[0\]\);' (
    'The existing FBHDA access-begin operation must feed arbitration without replacing its behavior.'
)
Assert-Match $displayAdapter 'flags &[\s\S]+FBHDA_ACCESS_EXCLUSIVE_BEGIN \| FBHDA_ACCESS_EXCLUSIVE_END[\s\S]+exclusive == FBHDA_ACCESS_EXCLUSIVE_BEGIN[\s\S]+GSW_DISPLAY_EVENT_DDRAW_EXCLUSIVE_BEGIN[\s\S]+exclusive == FBHDA_ACCESS_EXCLUSIVE_END[\s\S]+GSW_DISPLAY_EVENT_DDRAW_EXCLUSIVE_END[\s\S]+exclusive != 0UL[\s\S]+GSW_MARK_DISPLAY_PROTOCOL_FAULT' (
    'The adapter must accept exactly one existing exclusive flag and reject an ambiguous combination.'
)
Assert-Match $ddrawExclusiveBeginCase 'state\.authority == GSW_DISPLAY_FOREGROUND_VGA &&[\s\S]+state\.authority_vm == state\.windows_vm\)[\s\S]+break;' (
    'A duplicate DirectDraw begin from the Windows VM already owning foreground VGA must be a no-op.'
)
Assert-Match $ddrawExclusiveEndCase 'state\.transition != GSW_DISPLAY_TRANSITION_NONE[\s\S]+state\.transition_vm != state\.windows_vm[\s\S]+state\.transition == GSW_DISPLAY_DESKTOP_RECONFIGURE[\s\S]+state\.authority == GSW_DISPLAY_WINDOWS_DESKTOP[\s\S]+result\.next\.transition = GSW_DISPLAY_TRANSITION_NONE;[\s\S]+result\.next\.transition_vm = 0UL;' (
    'DirectDraw end must close only a begin-only desktop reconfigure on the stable Windows desktop.'
)
Assert-Match $ddrawExclusiveEndCase 'state\.authority == GSW_DISPLAY_FOREGROUND_VGA &&[\s\S]+state\.authority_vm == state\.windows_vm\)[\s\S]+gsw_display_set_transition' (
    'DirectDraw end must not seize desktop authorization from a foreign foreground VGA owner.'
)
Assert-NotMatch $ddrawExclusiveEndCase 'GSW_DISPLAY_TO_(?:FOREGROUND_VGA|WINDOWS_DESKTOP)' (
    'DirectDraw end must preserve stronger directional VDD transitions unchanged.'
)
Assert-NotMatch ($displayAdapterHeader + $displayArbiterHeader + $arbiterAdded) '(?m)^\s*#define\s+OP_' (
    'Display arbitration must not add a guest-host operation or ABI command.'
)

Assert-Match $displayArbiter 'gsw_display_trap_for[\s\S]+state\.lifecycle == GSW_DISPLAY_REGISTERED[\s\S]+GSW_DISPLAY_DISPI_INTERCEPT[\s\S]+GSW_DISPLAY_DISPI_BYPASS' (
    'The pure trap policy must intercept only while the display driver is registered.'
)
Assert-Match $displayArbiter 'case GSW_DISPLAY_EVENT_DRIVER_DISABLING:[\s\S]+state\.lifecycle == GSW_DISPLAY_EXITED[\s\S]+state\.lifecycle == GSW_DISPLAY_REGISTERED &&[\s\S]+event\.vm != 0UL && event\.vm == state\.windows_vm[\s\S]+state\.lifecycle != GSW_DISPLAY_DISABLING \|\|[\s\S]+event\.vm == 0UL \|\| event\.vm != state\.windows_vm[\s\S]+result\.protocol_fault = 1U;' (
    'Only the retained Windows VM may enter or duplicate the disabling lifecycle.'
)
Assert-Match $displayAdapter 'if \(!force && policy == gsw_display_applied_trap\) \{[\s\S]+return;[\s\S]+gsw_display_applied_trap = policy;' (
    'Ordinary trap-policy application must be idempotent.'
)
Assert-Match $displayAdapter 'result = gsw_display_step\(gsw_display_state, event\);[\s\S]+gsw_display_state = result\.next;[\s\S]+GSW_display_apply_dispi_traps\(result\.dispi_trap, 0\);' (
    'Every state transition must apply the trap policy returned by that exact pure step.'
)
Assert-Match $arbiterAdded 'GSW_display_sync_dispi_traps\(\);' (
    'The VDD ENABLE_TRAPS callback must resynchronize the arbiter-owned trap policy.'
)
Assert-NotMatch $arbiterAdded 'Enable_Global_Trapping\(0x1C[EF]\)|Disable_Global_Trapping\(0x1C[EF]\)' (
    'Patch 0013 must not bypass the adapter with a new direct trap-policy mutation.'
)
Assert-Match $gswMake 'GSW_VXD_OBJS = &[\s\S]+gsw_display_arbiter\.obj gsw_display_adapter\.obj' (
    'The VxD object inventory must include the pure arbiter and its adapter.'
)
Assert-Match $gswMake 'gsw_display_arbiter\.obj : gsw_display_arbiter\.c gsw_display_arbiter\.h[\s\S]+gsw_display_adapter\.obj : gsw_display_adapter\.c gsw_display_adapter\.h gsw_display_arbiter\.h' (
    'The makefile must compile both display lifecycle modules with explicit dependencies.'
)
Assert-Match $gswMake 'file gsw_display_arbiter\.obj[\s\S]+file gsw_display_adapter\.obj' (
    'The shipping VxD link must include both display lifecycle modules.'
)

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
Assert-Match $lifecycle 'gsw_device_initializing = FALSE;[\s\S]+gsw_device_initialized = FALSE;' (
    'The VxD must track initialization and completion independently.'
)
Assert-Match $lifecycle 'call Device_Init_proc[\s\S]+dynamic init does not receive Init_Complete later[\s\S]+call Device_Init_Complete' (
    'Dynamic VxD startup must run the Init_Complete mapping hook.'
)
Assert-Match $lifecycle 'if\(gsw_device_initialized\)[\s\S]+return TRUE;' (
    'Duplicate Device_Init calls must not overwrite saved Main VDD dispatch entries.'
)
Assert-Match $lifecycle 'gsw_dispatch_installed = TRUE;[\s\S]+if\(!Hook_V86_Int_Chain\(0x10, \(\(DWORD\)virtual_int_10h\)\+8\)\)[\s\S]+Device_Exit_proc\(VM\);[\s\S]+return FALSE;[\s\S]+gsw_int10_hooked = TRUE;' (
    'The required INT 10h guard must install after fallible setup and fail initialization closed.'
)
Assert-Match $lifecycle 'if\(!gsw_device_initialized && !gsw_device_initializing\)[\s\S]+return TRUE;' (
    'Duplicate Device_Exit calls must be harmless.'
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
Write-Host 'PASS GSW-VGA display arbitration owns BIOS, VBE, DISPI, VDD, and DirectDraw transitions.'
Write-Host 'PASS GSW-VGA installs and removes its V86 INT 10h hook with fail-closed unload semantics.'
Write-Host 'PASS GSW-VGA DirectDraw and 3D resources carry process ownership for lifecycle cleanup.'
Write-Host 'PASS GSW-VGA DirectDraw defers surface registration until runtime allocation.'
Write-Host 'PASS GSW-VGA derived, PnP, mode-return, and negative contracts admit only 320x240x8.'
Write-Host 'PASS GSW-VGA patch 0013 explicitly supersedes the screen-switch re-entry workaround.'
