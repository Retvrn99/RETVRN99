/* SPDX-License-Identifier: GPL-3.0-only */
#include <vmm.h>
#include <vxdwraps.h>

#include "../include/gswsound_abi.h"
#include "../include/gswsound_pm.h"
#include "../include/gswsound_telemetry.h"
#include "gswsound_ddk.h"
#include "gswsound_transport.h"

#define GSW_SOUND_RING_BYTES          (4UL * 1024UL)
/* Win9x maps the Win16 global heap in the ring-3 shared arena below 3 GiB. */
#define GSW_SOUND_RING3_LIMIT         0xC0000000UL
#define GSW_SOUND_PTE_PRESENT         0x00000001UL
#define GSW_SOUND_PTE_WRITE           0x00000002UL
#define GSW_SOUND_PTE_USER            0x00000004UL

/* A diagnostic build may retain the old 1 ms IRQ-status polling behavior. */
#ifndef GSW_SOUND_DIAGNOSTIC_POLLING_FALLBACK
#define GSW_SOUND_DIAGNOSTIC_POLLING_FALLBACK 0
#endif

typedef struct GSW_SOUND_LOCKED_RANGE {
    gsw_u32 first_page;
    gsw_u32 page_count;
    gsw_u8 locked;
} GSW_SOUND_LOCKED_RANGE;

static GSW_SOUND_TRANSPORT gsw_transport;
static gsw_u8 *gsw_ring;
static gsw_u32 gsw_ring_physical;
static volatile gsw_u32 *gsw_registers;
static DEVNODE gsw_devnode;
static GSW_SOUND_DDK_RESOURCES gsw_resources;
static GSW_SOUND_DDK_IRQ gsw_irq;
static gsw_u8 gsw_devnode_registered;
static gsw_u8 gsw_device_started;
static gsw_u8 gsw_diagnostic_polling;
static gsw_u32 gsw_telemetry_sequence;
static gsw_u32 gsw_telemetry_last_checkpoint;

static void gsw_copy(void *destination, const void *source, gsw_u32 bytes)
{
    gsw_u8 *out = (gsw_u8 *)destination;
    const gsw_u8 *in = (const gsw_u8 *)source;
    while (bytes != 0) {
        *out++ = *in++;
        bytes--;
    }
}

static void gsw_zero(void *destination, gsw_u32 bytes)
{
    gsw_u8 *out = (gsw_u8 *)destination;
    while (bytes != 0) {
        *out++ = 0;
        bytes--;
    }
}

static void gsw_telemetry_checkpoint(
    GSW_SOUND_TELEMETRY_CHECKPOINT checkpoint,
    GSW_SOUND_TELEMETRY_OUTCOME outcome,
    gsw_u32 detail0,
    gsw_u32 detail1
)
{
    GSW_SOUND_START_TELEMETRY telemetry;
    HKEY key = 0;
    gsw_zero(&telemetry, sizeof(telemetry));
    telemetry.magic = GSW_SOUND_TELEMETRY_MAGIC;
    telemetry.version = GSW_SOUND_TELEMETRY_VERSION;
    telemetry.record_bytes = sizeof(telemetry);
    telemetry.sequence = ++gsw_telemetry_sequence;
    telemetry.checkpoint = checkpoint;
    telemetry.outcome = outcome;
    telemetry.detail0 = detail0;
    telemetry.detail1 = detail1;
    gsw_telemetry_last_checkpoint = checkpoint;

    /* Diagnostics are best-effort and never participate in device results. */
    if (gsw_vmm_reg_open_key(
            HKEY_LOCAL_MACHINE,
            GSW_SOUND_TELEMETRY_REGISTRY_KEY,
            &key
        ) != ERROR_SUCCESS)
        return;
    (void)gsw_vmm_reg_set_value_ex(
        key,
        GSW_SOUND_TELEMETRY_VALUE_NAME,
        0,
        REG_BINARY,
        (const BYTE *)&telemetry,
        sizeof(telemetry)
    );
    (void)gsw_vmm_reg_close_key(key);
}

static void gsw_sound_ddk_register_devnode(
    DEVNODE devnode,
    GSW_SOUND_CONFIG_HANDLER handler
)
{
    gsw_mmdevldr_register_device_driver(devnode, handler, 0);
}

static CONFIGRET gsw_sound_ddk_get_allocated_resources(
    DEVNODE devnode,
    GSW_SOUND_DDK_RESOURCES *resources
)
{
    GSW_SOUND_DDK_ALLOCATION allocation;
    CONFIGRET result;
    gsw_u32 index;
    gsw_u32 matches = 0;
    if (resources == 0 || devnode == 0) return GSW_SOUND_CR_FAILURE;
    gsw_zero(&allocation, sizeof(allocation));
    gsw_zero(resources, sizeof(*resources));
    result = gsw_configmg_get_allocated_resources(devnode, &allocation);
    if (result != CR_SUCCESS) return result;

    if (allocation.memory_count > GSW_SOUND_DDK_MAX_MEMORY_WINDOWS ||
        allocation.irq_count > GSW_SOUND_DDK_MAX_IRQS)
        return GSW_SOUND_CR_FAILURE;
    for (index = 0; index < allocation.memory_count; index++) {
        gsw_u32 base = allocation.memory[index].base;
        gsw_u32 bytes = allocation.memory[index].bytes;
        if (bytes < GSW_PCM_CONTROL_SIZE ||
            (base & (GSW_SOUND_DDK_MMIO_ALIGNMENT - 1)) != 0 ||
            base > 0xFFFFFFFFUL - (GSW_PCM_CONTROL_SIZE - 1))
            continue;
        resources->mmio_physical = base;
        resources->mmio_bytes = bytes;
        matches++;
    }
    if (matches != 1 || allocation.irq_count != 1 ||
        allocation.irq_numbers[0] < GSW_SOUND_DDK_IRQ_MIN ||
        allocation.irq_numbers[0] > GSW_SOUND_DDK_IRQ_MAX)
        return GSW_SOUND_CR_FAILURE;
    resources->irq_number = allocation.irq_numbers[0];
    return CR_SUCCESS;
}

static int gsw_sound_ddk_install_level_irq(
    GSW_SOUND_DDK_IRQ *irq,
    gsw_u8 irq_number,
    void (*handler)(void)
)
{
    VPICD_IRQ_Descriptor descriptor;
    if (irq == 0 || handler == 0 || irq->installed ||
        irq_number < GSW_SOUND_DDK_IRQ_MIN || irq_number > GSW_SOUND_DDK_IRQ_MAX)
        return 0;
    gsw_zero(&descriptor, sizeof(descriptor));
    descriptor.IRQ_Number = irq_number;
    descriptor.Options = VPICD_OPT_CAN_SHARE;
    descriptor.Hw_Int_Proc = (gsw_u32)handler;
    descriptor.IRET_Time_Out = 0;
    irq->handle = gsw_vpicd_virtualize_irq(&descriptor);
    if (irq->handle == 0) return 0;
    irq->installed = 1;
    gsw_vpicd_physically_unmask(irq->handle);
    return 1;
}

static void gsw_sound_ddk_remove_level_irq(GSW_SOUND_DDK_IRQ *irq)
{
    if (irq == 0 || !irq->installed) return;
    gsw_vpicd_physically_mask(irq->handle);
    gsw_vpicd_force_default_behavior(irq->handle);
    gsw_zero(irq, sizeof(*irq));
}

static int gsw_lock_ring3(
    gsw_u32 address,
    gsw_u32 bytes,
    int writable,
    GSW_SOUND_LOCKED_RANGE *range
)
{
    gsw_u32 span;
    gsw_u32 index;
    gsw_u32 pte;
    gsw_u32 required = GSW_SOUND_PTE_PRESENT | GSW_SOUND_PTE_USER;
    if (range == 0) return 0;
    range->first_page = 0;
    range->page_count = 0;
    range->locked = 0;
    if (bytes == 0 || address == 0 || address >= GSW_SOUND_RING3_LIMIT ||
        address > 0xFFFFFFFFUL - (bytes - 1) || address + bytes > GSW_SOUND_RING3_LIMIT)
        return 0;
    span = (address & 0xFFFUL) + bytes;
    range->first_page = address >> 12;
    range->page_count = (span + 0xFFFUL) >> 12;
    if (range->page_count == 0 || range->page_count > 9) return 0;
    if (_LinPageLock(range->first_page, range->page_count, 0) == 0) return 0;
    if (writable) required |= GSW_SOUND_PTE_WRITE;
    for (index = 0; index < range->page_count; index++) {
        pte = 0;
        _CopyPageTable(range->first_page + index, 1, &pte, 0);
        if ((pte & required) != required) {
            _LinPageUnLock(range->first_page, range->page_count, 0);
            return 0;
        }
    }
    range->locked = 1;
    return 1;
}

static void gsw_unlock_ring3(GSW_SOUND_LOCKED_RANGE *range)
{
    if (range != 0 && range->locked) {
        _LinPageUnLock(range->first_page, range->page_count, 0);
        range->locked = 0;
    }
}

static GSW_SOUND_RESULT gsw_dispatch_request(GSW_SOUND_PM_REQUEST *request)
{
    GSW_SOUND_RESULT result;
    GSW_SOUND_LOCKED_RANGE buffer_range;
    gsw_u32 low;
    gsw_u32 high;
    if (request->size != sizeof(*request) ||
        request->version != GSW_SOUND_PM_API_VERSION ||
        request->reserved_zero != 0 ||
        request->opcode > GSW_SOUND_PM_SET_GAIN)
        return GSW_SOUND_INVALID;
    request->accepted_bytes = 0;
    request->completed_token = 0;
    request->capabilities = 0;
    request->result = GSW_SOUND_INVALID;
    switch ((GSW_SOUND_PM_OPCODE)request->opcode) {
    case GSW_SOUND_PM_QUERY:
        if (!gsw_transport.bound) result = GSW_SOUND_UNAVAILABLE;
        else {
            request->capabilities = gsw_registers[GSW_PCM_REG_CAPABILITIES >> 2];
            result = GSW_SOUND_OK;
        }
        break;
    case GSW_SOUND_PM_OPEN:
        result = gsw_sound_transport_open(
            &gsw_transport,
            request->sample_rate,
            request->channels,
            request->bits_per_sample,
            &request->stream_id
        );
        break;
    case GSW_SOUND_PM_CLOSE:
        result = gsw_sound_transport_close(&gsw_transport, request->stream_id);
        break;
    case GSW_SOUND_PM_SUBMIT:
        if (request->buffer_bytes == 0 ||
            request->buffer_bytes > GSW_SOUND_MAX_SUBMIT_BYTES ||
            !gsw_lock_ring3(
                request->buffer_linear,
                request->buffer_bytes,
                0,
                &buffer_range
            )) {
            result = GSW_SOUND_INVALID;
            break;
        }
        result = gsw_sound_transport_submit(
            &gsw_transport,
            request->stream_id,
            (const gsw_u8 *)request->buffer_linear,
            request->buffer_bytes,
            request->flags,
            request->user_token,
            &request->accepted_bytes
        );
        gsw_unlock_ring3(&buffer_range);
        break;
    case GSW_SOUND_PM_POLL:
        result = gsw_sound_transport_poll(
            &gsw_transport,
            request->stream_id,
            &request->completed_token
        );
        break;
    case GSW_SOUND_PM_PAUSE:
        result = gsw_sound_transport_pause(&gsw_transport, request->stream_id);
        break;
    case GSW_SOUND_PM_RESTART:
        result = gsw_sound_transport_restart(&gsw_transport, request->stream_id);
        break;
    case GSW_SOUND_PM_RESET:
        result = gsw_sound_transport_reset(&gsw_transport, request->stream_id);
        break;
    case GSW_SOUND_PM_GET_POSITION:
        result = gsw_sound_transport_position(&gsw_transport, request->stream_id, &low, &high);
        if (result == GSW_SOUND_OK) {
            request->position_low = low;
            request->position_high = high;
        }
        break;
    case GSW_SOUND_PM_GET_GAIN:
        result = gsw_sound_transport_get_gain(&gsw_transport, &request->gain_q16);
        break;
    case GSW_SOUND_PM_SET_GAIN:
        result = gsw_sound_transport_set_gain(&gsw_transport, request->gain_q16);
        break;
    default:
        result = GSW_SOUND_INVALID;
        break;
    }
    request->result = result;
    return result;
}

static gsw_u32 __cdecl gsw_dispatch_linear(gsw_u32 request_linear, gsw_u32 request_bytes)
{
    GSW_SOUND_LOCKED_RANGE request_range;
    GSW_SOUND_PM_REQUEST local_request;
    GSW_SOUND_RESULT result;
    if (request_bytes != sizeof(local_request) ||
        !gsw_lock_ring3(request_linear, request_bytes, 1, &request_range))
        return GSW_SOUND_INVALID;
    gsw_copy(&local_request, (const void *)request_linear, sizeof(local_request));
    result = gsw_dispatch_request(&local_request);
    gsw_copy((void *)request_linear, &local_request, sizeof(local_request));
    gsw_unlock_ring3(&request_range);
    return result;
}

void __declspec(naked) GSWSOUND_PM_API(void)
{
    _asm {
        push ebx
        push ecx
        push edx
        push esi
        push edi
        push ebp
        push ecx
        push esi
        call gsw_dispatch_linear
        add esp, 8
        pop ebp
        pop edi
        pop esi
        pop edx
        pop ecx
        pop ebx
        test eax, eax
        jnz gsw_pm_failed
        clc
        ret
gsw_pm_failed:
        stc
        ret
    }
}

static int __cdecl gsw_service_hardware_interrupt(GSW_SOUND_IRQ_HANDLE irq_handle)
{
    if (!gsw_device_started || !gsw_irq.installed || irq_handle != gsw_irq.handle)
        return 0;
    if (!gsw_sound_transport_handle_interrupt(&gsw_transport))
        return 0;
    gsw_vpicd_phys_eoi(irq_handle);
    return 1;
}

/*
 * VPICD enters with the IRQ handle in EAX.  Carry clear means that this
 * shared handler owned the interrupt; carry set passes it to the next owner.
 */
static void __declspec(naked) gsw_hardware_interrupt(void)
{
    _asm {
        pushad
        push eax
        call gsw_service_hardware_interrupt
        add esp, 4
        test eax, eax
        popad
        jz gsw_interrupt_not_handled
        clc
        ret
gsw_interrupt_not_handled:
        stc
        ret
    }
}

static void gsw_device_stop(void)
{
    /* Disable and acknowledge the device before releasing the shared IRQ. */
    gsw_sound_transport_unbind(&gsw_transport);
    gsw_sound_ddk_remove_level_irq(&gsw_irq);
    if (gsw_ring != 0) _PageFree((PVOID)gsw_ring, 0);
    gsw_ring = 0;
    gsw_ring_physical = 0;
    gsw_registers = 0;
    gsw_device_started = 0;
    gsw_diagnostic_polling = 0;
    gsw_zero(&gsw_resources, sizeof(gsw_resources));
}

static int gsw_device_start(DEVNODE devnode)
{
    gsw_u32 ring_linear;
    CONFIGRET configuration_result;
    GSW_SOUND_RESULT result;
    gsw_telemetry_checkpoint(
        GSW_SOUND_TELEMETRY_START,
        GSW_SOUND_TELEMETRY_ENTER,
        (gsw_u32)devnode,
        (gsw_u32)gsw_devnode
    );
    if (gsw_device_started) {
        if (devnode == gsw_devnode) {
            gsw_telemetry_checkpoint(
                GSW_SOUND_TELEMETRY_SUCCESS,
                GSW_SOUND_TELEMETRY_PASSED,
                (gsw_u32)devnode,
                1
            );
            return 1;
        }
        gsw_telemetry_checkpoint(
            GSW_SOUND_TELEMETRY_START,
            GSW_SOUND_TELEMETRY_FAILED,
            (gsw_u32)devnode,
            (gsw_u32)gsw_devnode
        );
        return 0;
    }
    if (devnode == 0 || gsw_devnode != devnode) {
        gsw_telemetry_checkpoint(
            GSW_SOUND_TELEMETRY_START,
            GSW_SOUND_TELEMETRY_FAILED,
            (gsw_u32)devnode,
            (gsw_u32)gsw_devnode
        );
        return 0;
    }

    gsw_telemetry_checkpoint(
        GSW_SOUND_TELEMETRY_RESOURCE,
        GSW_SOUND_TELEMETRY_ENTER,
        (gsw_u32)devnode,
        0
    );
    configuration_result = gsw_sound_ddk_get_allocated_resources(
        devnode,
        &gsw_resources
    );
    if (configuration_result != CR_SUCCESS) {
        gsw_telemetry_checkpoint(
            GSW_SOUND_TELEMETRY_RESOURCE,
            GSW_SOUND_TELEMETRY_FAILED,
            configuration_result,
            0
        );
        return 0;
    }
    gsw_telemetry_checkpoint(
        GSW_SOUND_TELEMETRY_RESOURCE,
        GSW_SOUND_TELEMETRY_PASSED,
        gsw_resources.mmio_physical,
        (gsw_u32)gsw_resources.irq_number
    );

    gsw_telemetry_checkpoint(
        GSW_SOUND_TELEMETRY_MAP,
        GSW_SOUND_TELEMETRY_ENTER,
        gsw_resources.mmio_physical,
        GSW_PCM_CONTROL_SIZE
    );
    gsw_registers = (volatile gsw_u32 *)_MapPhysToLinear(
        gsw_resources.mmio_physical,
        GSW_PCM_CONTROL_SIZE,
        0
    );
    if (gsw_registers == 0) {
        gsw_telemetry_checkpoint(
            GSW_SOUND_TELEMETRY_MAP,
            GSW_SOUND_TELEMETRY_FAILED,
            gsw_resources.mmio_physical,
            GSW_PCM_CONTROL_SIZE
        );
        return 0;
    }
    gsw_telemetry_checkpoint(
        GSW_SOUND_TELEMETRY_MAP,
        GSW_SOUND_TELEMETRY_PASSED,
        gsw_resources.mmio_physical,
        (gsw_u32)gsw_registers
    );

    gsw_telemetry_checkpoint(
        GSW_SOUND_TELEMETRY_PAGE,
        GSW_SOUND_TELEMETRY_ENTER,
        GSW_SOUND_RING_BYTES,
        0
    );
    ring_linear = _PageAllocate(
        RoundToPages(GSW_SOUND_RING_BYTES),
        PG_SYS,
        0,
        0,
        PAGE_ALLOC_MIN,
        PAGE_ALLOC_MAX,
        &gsw_ring_physical,
        PAGECONTIG | PAGEUSEALIGN | PAGEFIXED | PAGEZEROINIT
    );
    if (ring_linear == 0 ||
        (gsw_ring_physical & (GSW_PCM_RING_GPA_ALIGNMENT - 1)) != 0) {
        if (ring_linear != 0) _PageFree((PVOID)ring_linear, 0);
        gsw_telemetry_checkpoint(
            GSW_SOUND_TELEMETRY_PAGE,
            GSW_SOUND_TELEMETRY_FAILED,
            ring_linear,
            gsw_ring_physical
        );
        gsw_ring_physical = 0;
        return 0;
    }
    gsw_ring = (gsw_u8 *)ring_linear;
    gsw_telemetry_checkpoint(
        GSW_SOUND_TELEMETRY_PAGE,
        GSW_SOUND_TELEMETRY_PASSED,
        ring_linear,
        gsw_ring_physical
    );

    gsw_telemetry_checkpoint(
        GSW_SOUND_TELEMETRY_BIND,
        GSW_SOUND_TELEMETRY_ENTER,
        gsw_ring_physical,
        GSW_SOUND_RING_BYTES
    );
    result = gsw_sound_transport_bind(
        &gsw_transport,
        gsw_registers,
        gsw_ring,
        gsw_ring_physical,
        GSW_SOUND_RING_BYTES
    );
    if (result != GSW_SOUND_OK) {
        gsw_telemetry_checkpoint(
            GSW_SOUND_TELEMETRY_BIND,
            GSW_SOUND_TELEMETRY_FAILED,
            result,
            gsw_registers[GSW_PCM_REG_STATUS >> 2]
        );
        _PageFree((PVOID)gsw_ring, 0);
        gsw_ring = 0;
        gsw_ring_physical = 0;
        gsw_registers = 0;
        return 0;
    }
    gsw_telemetry_checkpoint(
        GSW_SOUND_TELEMETRY_BIND,
        GSW_SOUND_TELEMETRY_PASSED,
        gsw_registers[GSW_PCM_REG_ID >> 2],
        gsw_registers[GSW_PCM_REG_STATUS >> 2]
    );

    gsw_telemetry_checkpoint(
        GSW_SOUND_TELEMETRY_IRQ,
        GSW_SOUND_TELEMETRY_ENTER,
        (gsw_u32)gsw_resources.irq_number,
        0
    );
    if (gsw_sound_ddk_install_level_irq(
            &gsw_irq,
            gsw_resources.irq_number,
            gsw_hardware_interrupt
        )) {
        gsw_telemetry_checkpoint(
            GSW_SOUND_TELEMETRY_IRQ,
            GSW_SOUND_TELEMETRY_PASSED,
            (gsw_u32)gsw_resources.irq_number,
            gsw_irq.handle
        );
        gsw_telemetry_checkpoint(
            GSW_SOUND_TELEMETRY_MODE,
            GSW_SOUND_TELEMETRY_ENTER,
            1,
            0
        );
        result = gsw_sound_transport_set_interrupt_mode(&gsw_transport, 1);
    } else {
        gsw_telemetry_checkpoint(
            GSW_SOUND_TELEMETRY_IRQ,
            GSW_SOUND_TELEMETRY_FAILED,
            (gsw_u32)gsw_resources.irq_number,
            0
        );
#if GSW_SOUND_DIAGNOSTIC_POLLING_FALLBACK
        gsw_diagnostic_polling = 1;
        gsw_telemetry_checkpoint(
            GSW_SOUND_TELEMETRY_MODE,
            GSW_SOUND_TELEMETRY_ENTER,
            0,
            0
        );
        result = gsw_sound_transport_set_interrupt_mode(&gsw_transport, 0);
#else
        result = GSW_SOUND_UNAVAILABLE;
#endif
    }
    if (result != GSW_SOUND_OK) {
        gsw_telemetry_checkpoint(
            GSW_SOUND_TELEMETRY_MODE,
            GSW_SOUND_TELEMETRY_FAILED,
            result,
            (gsw_u32)gsw_diagnostic_polling
        );
        gsw_device_stop();
        return 0;
    }
    gsw_telemetry_checkpoint(
        GSW_SOUND_TELEMETRY_MODE,
        GSW_SOUND_TELEMETRY_PASSED,
        (gsw_u32)!gsw_diagnostic_polling,
        0
    );
    gsw_device_started = 1;
    gsw_telemetry_checkpoint(
        GSW_SOUND_TELEMETRY_SUCCESS,
        GSW_SOUND_TELEMETRY_PASSED,
        (gsw_u32)devnode,
        gsw_ring_physical
    );
    return 1;
}

static CONFIGRET __cdecl gsw_configuration_handler_impl(
    gsw_u32 function,
    gsw_u32 subfunction,
    DEVNODE devnode,
    gsw_u32 reference_data,
    gsw_u32 flags
)
{
    (void)subfunction;
    (void)reference_data;
    (void)flags;
    switch (function) {
    case GSW_SOUND_CONFIG_START:
        return gsw_device_start(devnode) ? CR_SUCCESS : GSW_SOUND_CR_FAILURE;
    case GSW_SOUND_CONFIG_STOP:
        if (devnode == gsw_devnode) gsw_device_stop();
        return CR_SUCCESS;
    case GSW_SOUND_CONFIG_REMOVE:
        if (devnode == gsw_devnode) {
            gsw_device_stop();
            gsw_devnode = 0;
            gsw_devnode_registered = 0;
        }
        return CR_SUCCESS;
    case GSW_SOUND_CONFIG_TEST:
        return CR_SUCCESS;
    default:
        return GSW_SOUND_CR_DEFAULT;
    }
}

/*
 * MMDEVLDR invokes the Config Handler with five cdecl stack arguments, but it
 * additionally consumes carry clear as the successful dispatch convention.
 */
static CONFIGRET __declspec(naked) __cdecl gsw_configuration_handler_thunk(
    gsw_u32 function,
    gsw_u32 subfunction,
    DEVNODE devnode,
    gsw_u32 reference_data,
    gsw_u32 flags
)
{
    _asm {
        push ebp
        mov ebp, esp
        push [ebp + 24]
        push [ebp + 20]
        push [ebp + 16]
        push [ebp + 12]
        push [ebp + 8]
        call gsw_configuration_handler_impl
        add esp, 20
        mov esp, ebp
        pop ebp
        clc
        ret
    }
}

static CONFIGRET __cdecl gsw_register_devnode(
    gsw_u32 devnode_value,
    gsw_u32 load_type
)
{
    DEVNODE devnode = (DEVNODE)devnode_value;
    gsw_telemetry_checkpoint(
        GSW_SOUND_TELEMETRY_PNP,
        GSW_SOUND_TELEMETRY_ENTER,
        devnode_value,
        load_type
    );
    /*
     * MMDEVLDR documents EDX as DLVXD_LOAD_DRIVER for this message, but the
     * Win9x DDK multimedia sample explicitly permits the value to be ignored.
     * Do not turn an advisory loader value into a devloader failure; retain it
     * in telemetry so unexpected callers remain visible.
     */
    if (devnode == 0) {
        gsw_telemetry_checkpoint(
            GSW_SOUND_TELEMETRY_PNP,
            GSW_SOUND_TELEMETRY_FAILED,
            0,
            load_type
        );
        return GSW_SOUND_CR_FAILURE;
    }
    gsw_telemetry_checkpoint(
        GSW_SOUND_TELEMETRY_PNP,
        GSW_SOUND_TELEMETRY_PASSED,
        devnode_value,
        load_type
    );
    if (gsw_devnode_registered) {
        if (devnode == gsw_devnode) return CR_SUCCESS;
        gsw_telemetry_checkpoint(
            GSW_SOUND_TELEMETRY_REGISTER,
            GSW_SOUND_TELEMETRY_FAILED,
            devnode_value,
            (gsw_u32)gsw_devnode
        );
        return GSW_SOUND_CR_FAILURE;
    }
    gsw_devnode = devnode;
    gsw_telemetry_checkpoint(
        GSW_SOUND_TELEMETRY_REGISTER,
        GSW_SOUND_TELEMETRY_ENTER,
        devnode_value,
        0
    );
    gsw_sound_ddk_register_devnode(devnode, gsw_configuration_handler_thunk);
    gsw_devnode_registered = 1;
    if (gsw_telemetry_last_checkpoint == GSW_SOUND_TELEMETRY_REGISTER) {
        gsw_telemetry_checkpoint(
            GSW_SOUND_TELEMETRY_REGISTER,
            GSW_SOUND_TELEMETRY_PASSED,
            devnode_value,
            0
        );
    }
    return CR_SUCCESS;
}

static void gsw_driver_exit(void)
{
    gsw_device_stop();
    gsw_devnode = 0;
    gsw_devnode_registered = 0;
}

void __declspec(naked) GSWSOUND_Control(void)
{
    _asm {
        cmp eax, PNP_New_Devnode
        je gsw_control_new_devnode
        cmp eax, Sys_Dynamic_Device_Init
        je gsw_control_ready
        cmp eax, Device_Init
        je gsw_control_ready
        cmp eax, Sys_Dynamic_Device_Exit
        je gsw_control_exit
        cmp eax, System_Exit
        je gsw_control_exit
gsw_control_ready:
        clc
        ret
gsw_control_new_devnode:
        pushad
        push edx
        push ebx
        call gsw_register_devnode
        add esp, 8
        /* PNP_New_Devnode is handled with CF set and CONFIGRET in EAX. */
        mov [esp + 28], eax
        popad
        stc
        ret
gsw_control_exit:
        pushad
        call gsw_driver_exit
        popad
        clc
        ret
    }
}

DDB GSWSOUND_DDB = {
    0,
    DDK_VERSION,
    UNDEFINED_DEVICE_ID,
    1,
    0,
    0,
    {'G', 'S', 'W', 'S', 'O', 'U', 'N', 'D'},
    Undefined_Init_Order,
    (DWORD)GSWSOUND_Control,
    0,
    (DWORD)GSWSOUND_PM_API,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    sizeof(DDB),
    0,
    0,
    0
};
