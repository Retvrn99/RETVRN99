/* SPDX-License-Identifier: GPL-3.0-only */

#define QEMU
#define GSW

#include "winhack.h"
#include "vmm.h"
#include "vxd_vdd.h"
#include "vxd_lib.h"
#include "3d_accel.h"

#include "gsw_display_adapter.h"
#include "gsw_shutdown_trace.h"

extern DWORD is_qemu;

static GSW_Display_Arbiter gsw_display_state;
static GSW_Display_Dispi_Trap gsw_display_applied_trap =
    GSW_DISPLAY_DISPI_BYPASS;

static GSW_Display_Dispi_Trap GSW_display_desired_trap(void)
{
    if (gsw_display_state.lifecycle == GSW_DISPLAY_REGISTERED) {
        return GSW_DISPLAY_DISPI_INTERCEPT;
    }
    return GSW_DISPLAY_DISPI_BYPASS;
}

static void GSW_display_apply_dispi_traps(
    GSW_Display_Dispi_Trap policy,
    int force
)
{
    if (!force && policy == gsw_display_applied_trap) {
        return;
    }
    if (is_qemu) {
        if (policy == GSW_DISPLAY_DISPI_INTERCEPT) {
            Enable_Global_Trapping(0x1CE);
            Enable_Global_Trapping(0x1CF);
        } else {
            Disable_Global_Trapping(0x1CE);
            Disable_Global_Trapping(0x1CF);
        }
    }
    gsw_display_applied_trap = policy;
}

static GSW_Display_Result GSW_display_emit(
    GSW_Display_Event_Kind kind,
    GSW_Display_VM vm,
    GSW_Display_VM physical_owner,
    unsigned short value,
    unsigned short flags
)
{
    GSW_Display_Event event;
    GSW_Display_Result result;

    event.kind = kind;
    event.vm = vm;
    event.observed_physical_owner = physical_owner;
    event.value = value;
    event.flags = flags;
    result = gsw_display_step(gsw_display_state, event);
    gsw_display_state = result.next;
    if (result.protocol_fault) {
        GSW_shutdown_marker(GSW_MARK_DISPLAY_PROTOCOL_FAULT);
    }
    GSW_display_apply_dispi_traps(result.dispi_trap, 0);
    return result;
}

static GSW_Display_Result GSW_display_emit_plain(
    GSW_Display_Event_Kind kind,
    GSW_Display_VM vm
)
{
    return GSW_display_emit(kind, vm, 0UL, 0U, 0U);
}

void GSW_display_device_ready(void)
{
    (void)GSW_display_emit_plain(GSW_DISPLAY_EVENT_DEVICE_READY, 0UL);
}

void GSW_display_device_registered(unsigned long vm)
{
    (void)GSW_display_emit_plain(GSW_DISPLAY_EVENT_DEVICE_REGISTERED, vm);
}

void GSW_display_driver_disabling(unsigned long vm)
{
    (void)GSW_display_emit_plain(GSW_DISPLAY_EVENT_DRIVER_DISABLING, vm);
}

void __stdcall GSW_display_system_exit(unsigned long vm)
{
    (void)GSW_display_emit_plain(GSW_DISPLAY_EVENT_SYSTEM_EXIT, vm);
}

void GSW_display_device_exit(unsigned long vm)
{
    (void)GSW_display_emit_plain(GSW_DISPLAY_EVENT_DEVICE_EXIT, vm);
}

void GSW_display_vdd_pre_foreground(unsigned long vm)
{
    if (gsw_display_state.lifecycle != GSW_DISPLAY_REGISTERED) {
        return;
    }
    (void)GSW_display_emit_plain(
        GSW_DISPLAY_EVENT_VDD_PRE_FOREGROUND,
        vm
    );
}

void GSW_display_vdd_post_foreground(unsigned long vm)
{
    unsigned long owner;

    if (gsw_display_state.lifecycle != GSW_DISPLAY_REGISTERED) {
        return;
    }
    owner = GSW_display_physical_owner(vm);
    (void)GSW_display_emit(
        GSW_DISPLAY_EVENT_VDD_POST_FOREGROUND,
        vm,
        owner,
        0U,
        GSW_DISPLAY_EVENT_PHYSICAL_OWNER_FRESH
    );
}

void GSW_display_vdd_pre_desktop(unsigned long vm)
{
    if (gsw_display_state.lifecycle != GSW_DISPLAY_REGISTERED) {
        return;
    }
    (void)GSW_display_emit_plain(
        GSW_DISPLAY_EVENT_VDD_PRE_DESKTOP,
        vm
    );
}

void GSW_display_vdd_post_desktop(unsigned long vm)
{
    unsigned long owner;

    if (gsw_display_state.lifecycle != GSW_DISPLAY_REGISTERED) {
        return;
    }
    owner = GSW_display_physical_owner(vm);
    (void)GSW_display_emit(
        GSW_DISPLAY_EVENT_VDD_POST_DESKTOP,
        vm,
        owner,
        0U,
        GSW_DISPLAY_EVENT_PHYSICAL_OWNER_FRESH
    );
}

void GSW_display_desktop_programmed(unsigned long vm)
{
    if (gsw_display_state.lifecycle != GSW_DISPLAY_REGISTERED) {
        return;
    }
    GSW_shutdown_marker(GSW_MARK_DESKTOP_PROGRAMMED);
    (void)GSW_display_emit_plain(GSW_DISPLAY_EVENT_DESKTOP_PROGRAMMED, vm);
}

void GSW_display_desktop_program_failed(unsigned long vm)
{
    if (gsw_display_state.lifecycle != GSW_DISPLAY_REGISTERED) {
        return;
    }
    (void)GSW_display_emit_plain(
        GSW_DISPLAY_EVENT_DESKTOP_PROGRAM_FAILED,
        vm
    );
}

void GSW_display_ddraw_exclusive(unsigned long vm, unsigned long flags)
{
    unsigned long exclusive;

    exclusive = flags &
        (FBHDA_ACCESS_EXCLUSIVE_BEGIN | FBHDA_ACCESS_EXCLUSIVE_END);
    if (exclusive == FBHDA_ACCESS_EXCLUSIVE_BEGIN) {
        GSW_shutdown_marker(GSW_MARK_DDRAW_EXCLUSIVE_BEGIN);
        (void)GSW_display_emit_plain(
            GSW_DISPLAY_EVENT_DDRAW_EXCLUSIVE_BEGIN,
            vm
        );
    } else if (exclusive == FBHDA_ACCESS_EXCLUSIVE_END) {
        GSW_shutdown_marker(GSW_MARK_DDRAW_EXCLUSIVE_END);
        (void)GSW_display_emit_plain(
            GSW_DISPLAY_EVENT_DDRAW_EXCLUSIVE_END,
            vm
        );
    } else if (exclusive != 0UL) {
        GSW_shutdown_marker(GSW_MARK_DISPLAY_PROTOCOL_FAULT);
    }
}

GSW_Display_Action GSW_display_bios_mode_set(
    unsigned long vm,
    unsigned short mode
)
{
    unsigned long owner;

    if (gsw_display_state.lifecycle == GSW_DISPLAY_REGISTERED) {
        owner = GSW_display_physical_owner(vm);
        if (vm != 0UL && vm == owner) {
            (void)GSW_display_emit(
                GSW_DISPLAY_EVENT_PHYSICAL_OWNER,
                vm,
                owner,
                0U,
                GSW_DISPLAY_EVENT_PHYSICAL_OWNER_FRESH
            );
        }
    }
    return GSW_display_emit(
        GSW_DISPLAY_EVENT_BIOS_MODE_SET,
        vm,
        0UL,
        mode,
        0U
    ).action;
}

GSW_Display_Result GSW_display_vbe_mode_set(
    unsigned long vm,
    unsigned short mode
)
{
    unsigned long owner;

    if (gsw_display_state.lifecycle == GSW_DISPLAY_REGISTERED) {
        owner = GSW_display_physical_owner(vm);
        if (vm != 0UL && vm == owner) {
            (void)GSW_display_emit(
                GSW_DISPLAY_EVENT_PHYSICAL_OWNER,
                vm,
                owner,
                0U,
                GSW_DISPLAY_EVENT_PHYSICAL_OWNER_FRESH
            );
        }
    }
    return GSW_display_emit(
        GSW_DISPLAY_EVENT_VBE_MODE_SET,
        vm,
        0UL,
        mode,
        0U
    );
}

GSW_Display_Action __stdcall GSW_display_dispi_access(unsigned long vm)
{
    unsigned long owner;

    if (gsw_display_state.lifecycle == GSW_DISPLAY_REGISTERED) {
        owner = GSW_display_physical_owner(vm);
        if (vm != 0UL && vm == owner) {
            (void)GSW_display_emit(
                GSW_DISPLAY_EVENT_PHYSICAL_OWNER,
                vm,
                owner,
                0U,
                GSW_DISPLAY_EVENT_PHYSICAL_OWNER_FRESH
            );
        }
    }
    return GSW_display_emit_plain(
        GSW_DISPLAY_EVENT_DISPI_ACCESS,
        vm
    ).action;
}

unsigned long GSW_display_physical_owner(unsigned long vm)
{
    unsigned long owner;

    owner = 0UL;
    _asm pushad
    _asm mov ebx, [vm]
    VxDCall(VDD, Get_VM_Info);
    _asm mov [owner], edi
    _asm popad
    return owner;
}

void GSW_display_sync_dispi_traps(void)
{
    GSW_display_apply_dispi_traps(GSW_display_desired_trap(), 1);
}
