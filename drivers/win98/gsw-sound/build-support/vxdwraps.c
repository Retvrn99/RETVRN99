/* SPDX-License-Identifier: GPL-3.0-only */
#include "vmm.h"
#include "configmg.h"
#include "mmdevldr.h"
#include "vpicd.h"
#include "vxdwraps.h"
#include "../vxd/gswsound_ddk.h"

#define GSW_CM_MAX_MEMORY_WINDOWS 9
#define GSW_CM_MAX_IO_PORTS       20
#define GSW_CM_MAX_IRQS           7
#define GSW_CM_MAX_DMA_CHANNELS   7

#pragma pack(push)
#pragma pack(1)
typedef struct GSW_CMCONFIG_RAW {
    WORD memory_count;
    DWORD memory_base[GSW_CM_MAX_MEMORY_WINDOWS];
    DWORD memory_length[GSW_CM_MAX_MEMORY_WINDOWS];
    WORD memory_attributes[GSW_CM_MAX_MEMORY_WINDOWS];
    WORD io_count;
    WORD io_base[GSW_CM_MAX_IO_PORTS];
    WORD io_length[GSW_CM_MAX_IO_PORTS];
    WORD irq_count;
    BYTE irq_number[GSW_CM_MAX_IRQS];
    BYTE irq_attributes[GSW_CM_MAX_IRQS];
    WORD dma_count;
    BYTE dma_number[GSW_CM_MAX_DMA_CHANNELS];
    WORD dma_attributes[GSW_CM_MAX_DMA_CHANNELS];
    BYTE reserved[3];
} GSW_CMCONFIG_RAW;
#pragma pack(pop)

typedef char gsw_cmconfig_must_be_216_bytes[
    sizeof(GSW_CMCONFIG_RAW) == 216 ? 1 : -1
];

static void gsw_support_zero(void *destination, ULONG bytes)
{
    BYTE *out = (BYTE *)destination;
    while (bytes != 0) {
        *out++ = 0;
        bytes--;
    }
}

static CONFIGRET __declspec(naked) __cdecl gsw_configmg_get_allocated_raw(
    GSW_CMCONFIG_RAW *configuration,
    DEVNODE devnode,
    ULONG flags
)
{
    VxDJmp(CONFIGMG, _Get_Alloc_Log_Conf);
}

/*
 * These VMM registry services use the Win32 ANSI registry signatures.  Keep
 * the service jumps in this reviewed Adapter so the device logic never emits
 * raw VMM ordinals.
 */
LONG __declspec(naked) __cdecl gsw_vmm_reg_open_key(
    HKEY root,
    LPCSTR subkey,
    PHKEY result
)
{
    VMMJmp(_RegOpenKey);
}

LONG __declspec(naked) __cdecl gsw_vmm_reg_set_value_ex(
    HKEY key,
    LPCSTR value_name,
    DWORD reserved,
    DWORD type,
    const BYTE *data,
    DWORD bytes
)
{
    VMMJmp(_RegSetValueEx);
}

LONG __declspec(naked) __cdecl gsw_vmm_reg_close_key(HKEY key)
{
    VMMJmp(_RegCloseKey);
}

void __cdecl gsw_mmdevldr_register_device_driver(
    DEVNODE devnode,
    GSW_SOUND_CONFIG_HANDLER handler,
    gsw_u32 reference_data
)
{
    gsw_u32 handler_address = (gsw_u32)handler;
    _asm {
        push eax
        push ebx
        push ecx
        mov eax, devnode
        mov ebx, handler_address
        mov ecx, reference_data
    }
    VxDCall(MMDEVLDR, Register_Device_Driver);
    _asm {
        pop ecx
        pop ebx
        pop eax
    }
}

CONFIGRET __cdecl gsw_configmg_get_allocated_resources(
    DEVNODE devnode,
    GSW_SOUND_DDK_ALLOCATION *allocation
)
{
    GSW_CMCONFIG_RAW configuration;
    CONFIGRET result;
    ULONG index;
    if (allocation == 0) return GSW_SOUND_CR_FAILURE;
    gsw_support_zero(allocation, sizeof(*allocation));
    gsw_support_zero(&configuration, sizeof(configuration));
    result = gsw_configmg_get_allocated_raw(&configuration, devnode, 0);
    if (result != CR_SUCCESS) return result;
    if (configuration.memory_count > GSW_CM_MAX_MEMORY_WINDOWS ||
        configuration.irq_count > GSW_CM_MAX_IRQS)
        return GSW_SOUND_CR_FAILURE;
    if (configuration.memory_count > GSW_SOUND_DDK_MAX_MEMORY_WINDOWS ||
        configuration.irq_count > GSW_SOUND_DDK_MAX_IRQS)
        return GSW_SOUND_CR_FAILURE;
    allocation->memory_count = configuration.memory_count;
    for (index = 0; index < configuration.memory_count; index++) {
        allocation->memory[index].base = configuration.memory_base[index];
        allocation->memory[index].bytes = configuration.memory_length[index];
    }
    allocation->irq_count = configuration.irq_count;
    for (index = 0; index < configuration.irq_count; index++)
        allocation->irq_numbers[index] = configuration.irq_number[index];
    return CR_SUCCESS;
}

GSW_SOUND_IRQ_HANDLE __cdecl gsw_vpicd_virtualize_irq(
    VPICD_IRQ_Descriptor *descriptor
)
{
    GSW_SOUND_IRQ_HANDLE handle = 0;
    _asm {
        push edi
        mov edi, descriptor
    }
    VxDCall(VPICD, Virtualize_IRQ);
    _asm {
        jc gsw_vpicd_virtualize_done
        mov handle, eax
gsw_vpicd_virtualize_done:
        pop edi
    }
    return handle;
}

void __cdecl gsw_vpicd_physically_mask(GSW_SOUND_IRQ_HANDLE handle)
{
    _asm {
        push eax
        mov eax, handle
    }
    VxDCall(VPICD, Physically_Mask);
    _asm pop eax
}

void __cdecl gsw_vpicd_physically_unmask(GSW_SOUND_IRQ_HANDLE handle)
{
    _asm {
        push eax
        mov eax, handle
    }
    VxDCall(VPICD, Physically_Unmask);
    _asm pop eax
}

void __cdecl gsw_vpicd_phys_eoi(GSW_SOUND_IRQ_HANDLE handle)
{
    _asm {
        push eax
        mov eax, handle
    }
    VxDCall(VPICD, Phys_EOI);
    _asm pop eax
}

void __cdecl gsw_vpicd_force_default_behavior(GSW_SOUND_IRQ_HANDLE handle)
{
    _asm {
        push eax
        mov eax, handle
    }
    VxDCall(VPICD, Force_Default_Behavior);
    _asm pop eax
}

ULONG __declspec(naked) __cdecl _PageAllocate(
    ULONG page_count,
    ULONG page_type,
    ULONG vm,
    ULONG alignment_mask,
    ULONG minimum_physical,
    ULONG maximum_physical,
    ULONG *physical_address,
    ULONG flags
)
{
    VMMJmp(_PageAllocate);
}

ULONG __declspec(naked) __cdecl _PageFree(PVOID memory, DWORD flags)
{
    VMMJmp(_PageFree);
}

ULONG __declspec(naked) __cdecl _CopyPageTable(
    ULONG linear_page,
    ULONG page_count,
    DWORD *entries,
    ULONG flags
)
{
    VMMJmp(_CopyPageTable);
}

ULONG __declspec(naked) __cdecl _LinPageLock(
    ULONG linear_page,
    ULONG page_count,
    ULONG flags
)
{
    VMMJmp(_LinPageLock);
}

ULONG __declspec(naked) __cdecl _LinPageUnLock(
    ULONG linear_page,
    ULONG page_count,
    ULONG flags
)
{
    VMMJmp(_LinPageUnLock);
}

ULONG __declspec(naked) __cdecl _MapPhysToLinear(
    ULONG physical_address,
    ULONG bytes,
    ULONG flags
)
{
    VMMJmp(_MapPhysToLinear);
}
