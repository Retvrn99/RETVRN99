/* SPDX-License-Identifier: GPL-3.0-only */
#ifndef RETVRN99_GSWSOUND_VXDWRAPS_H
#define RETVRN99_GSWSOUND_VXDWRAPS_H

#define SYS_DYNAMIC_DEVICE_INIT Sys_Dynamic_Device_Init
#define SYS_DYNAMIC_DEVICE_EXIT Sys_Dynamic_Device_Exit
#define DEVICE_INIT Device_Init
#define DEVICE_EXIT Device_Exit
#define UNDEFINED_INIT_ORDER Undefined_Init_Order

#define PAGE_ALLOC_MIN 0x1001UL
#define PAGE_ALLOC_MAX 0x100000UL
#define RoundToPages(bytes) (((bytes) + P_SIZE - 1) / P_SIZE)

ULONG __cdecl _PageAllocate(
    ULONG page_count,
    ULONG page_type,
    ULONG vm,
    ULONG alignment_mask,
    ULONG minimum_physical,
    ULONG maximum_physical,
    ULONG *physical_address,
    ULONG flags
);
ULONG __cdecl _PageFree(PVOID memory, DWORD flags);
ULONG __cdecl _CopyPageTable(ULONG linear_page, ULONG page_count, DWORD *entries, ULONG flags);
ULONG __cdecl _LinPageLock(ULONG linear_page, ULONG page_count, ULONG flags);
ULONG __cdecl _LinPageUnLock(ULONG linear_page, ULONG page_count, ULONG flags);
ULONG __cdecl _MapPhysToLinear(ULONG physical_address, ULONG bytes, ULONG flags);

LONG __cdecl gsw_vmm_reg_open_key(HKEY root, LPCSTR subkey, PHKEY result);
LONG __cdecl gsw_vmm_reg_set_value_ex(
    HKEY key,
    LPCSTR value_name,
    DWORD reserved,
    DWORD type,
    const BYTE *data,
    DWORD bytes
);
LONG __cdecl gsw_vmm_reg_close_key(HKEY key);

#define Declare_Virtual_Device(                                                  \
    name, major, minor, control, device_id, init_order, v86_api, pm_api, refs)  \
    DDB name##_DDB = {                                                          \
        0, DDK_VERSION, device_id, major, minor, 0, #name, init_order,          \
        (DWORD)control, (DWORD)v86_api, (DWORD)pm_api, 0, 0, 0,                 \
        0, 0, 0, 0, sizeof(DDB), 0, 0, 0                                       \
    }

#endif
