/* SPDX-License-Identifier: GPL-3.0-only */

#ifndef GSW_DISPLAY_ADAPTER_H
#define GSW_DISPLAY_ADAPTER_H

#include "gsw_display_arbiter.h"

void GSW_display_device_ready(void);
void GSW_display_device_registered(unsigned long vm);
void GSW_display_driver_disabling(unsigned long vm);
void __stdcall GSW_display_system_exit(unsigned long vm);
void GSW_display_device_exit(unsigned long vm);

void GSW_display_vdd_pre_foreground(unsigned long vm);
void GSW_display_vdd_post_foreground(unsigned long vm);
void GSW_display_vdd_pre_desktop(unsigned long vm);
void GSW_display_vdd_post_desktop(unsigned long vm);
void GSW_display_desktop_programmed(unsigned long vm);
void GSW_display_desktop_program_failed(unsigned long vm);

void GSW_display_ddraw_exclusive(unsigned long vm, unsigned long flags);

GSW_Display_Action GSW_display_bios_mode_set(
    unsigned long vm,
    unsigned short mode
);
GSW_Display_Result GSW_display_vbe_mode_set(
    unsigned long vm,
    unsigned short mode
);
GSW_Display_Action __stdcall GSW_display_dispi_access(
    unsigned long vm
);

unsigned long GSW_display_physical_owner(unsigned long vm);
void GSW_display_sync_dispi_traps(void);

#endif
