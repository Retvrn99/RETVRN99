/* SPDX-License-Identifier: GPL-3.0-only */
#ifndef RETVRN99_GSWSOUND_DDK_H
#define RETVRN99_GSWSOUND_DDK_H

/*
 * Narrow Windows 98 DDK Adapter.
 *
 * The reviewed Interface input deliberately contains only the public VMM,
 * ConfigMgr, and VPICD wire definitions.  Keep the driver policy here and
 * put register marshalling for VxD services in build-support/vxdwraps.c.
 */
#include <vmm.h>
#include <configmg.h>
#include <mmdevldr.h>
#include <vpicd.h>

#include "../include/gswsound_types.h"

#define GSW_SOUND_DDK_MMIO_ALIGNMENT 0x1000UL
#define GSW_SOUND_DDK_IRQ_MIN        3
#define GSW_SOUND_DDK_IRQ_MAX        15
#define GSW_SOUND_DDK_MAX_MEMORY_WINDOWS 4
#define GSW_SOUND_DDK_MAX_IRQS           4

/* CONFIGFUNC values consumed by this driver. */
#define GSW_SOUND_CONFIG_START  0x00000001UL
#define GSW_SOUND_CONFIG_STOP   0x00000002UL
#define GSW_SOUND_CONFIG_TEST   0x00000003UL
#define GSW_SOUND_CONFIG_REMOVE 0x00000004UL

/* CONFIGRET values consumed or returned by this driver. */
#define GSW_SOUND_CR_DEFAULT 0x00000001UL
#define GSW_SOUND_CR_FAILURE 0x00000013UL

typedef struct GSW_SOUND_DDK_MEMORY_WINDOW {
    gsw_u32 base;
    gsw_u32 bytes;
} GSW_SOUND_DDK_MEMORY_WINDOW;

typedef struct GSW_SOUND_DDK_ALLOCATION {
    gsw_u32 memory_count;
    GSW_SOUND_DDK_MEMORY_WINDOW memory[GSW_SOUND_DDK_MAX_MEMORY_WINDOWS];
    gsw_u32 irq_count;
    gsw_u8 irq_numbers[GSW_SOUND_DDK_MAX_IRQS];
} GSW_SOUND_DDK_ALLOCATION;

typedef struct GSW_SOUND_DDK_RESOURCES {
    gsw_u32 mmio_physical;
    gsw_u32 mmio_bytes;
    gsw_u8 irq_number;
} GSW_SOUND_DDK_RESOURCES;

typedef CONFIGRET (__cdecl *GSW_SOUND_CONFIG_HANDLER)(
    gsw_u32 function,
    gsw_u32 subfunction,
    DEVNODE devnode,
    gsw_u32 reference_data,
    gsw_u32 flags
);

typedef gsw_u32 GSW_SOUND_IRQ_HANDLE;

typedef struct GSW_SOUND_DDK_IRQ {
    GSW_SOUND_IRQ_HANDLE handle;
    gsw_u8 installed;
} GSW_SOUND_DDK_IRQ;

/* Original wrappers over the reviewed, hash-pinned service Interface. */
void __cdecl gsw_mmdevldr_register_device_driver(
    DEVNODE devnode,
    GSW_SOUND_CONFIG_HANDLER handler,
    gsw_u32 reference_data
);
CONFIGRET __cdecl gsw_configmg_get_allocated_resources(
    DEVNODE devnode,
    GSW_SOUND_DDK_ALLOCATION *allocation
);
GSW_SOUND_IRQ_HANDLE __cdecl gsw_vpicd_virtualize_irq(
    VPICD_IRQ_Descriptor *descriptor
);
void __cdecl gsw_vpicd_physically_mask(GSW_SOUND_IRQ_HANDLE handle);
void __cdecl gsw_vpicd_physically_unmask(GSW_SOUND_IRQ_HANDLE handle);
void __cdecl gsw_vpicd_phys_eoi(GSW_SOUND_IRQ_HANDLE handle);
void __cdecl gsw_vpicd_force_default_behavior(GSW_SOUND_IRQ_HANDLE handle);

#endif
