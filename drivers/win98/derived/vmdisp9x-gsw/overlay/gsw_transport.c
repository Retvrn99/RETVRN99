/* SPDX-License-Identifier: GPL-3.0-only */

#include "winhack.h"
#include "vmm.h"
#include "vxd_lib.h"
#include "pci.h"
#include "gsw_transport.h"
#include "code32.h"

typedef char GSWHeaderSizeCheck[(sizeof(GSWCommandHeader) == 16) ? 1 : -1];
typedef char GSWSetModeSizeCheck[(sizeof(GSWSetModeCommand) == 32) ? 1 : -1];
typedef char GSWPresentSizeCheck[(sizeof(GSWPresentCommand) == 40) ? 1 : -1];
typedef char GSWFillSizeCheck[(sizeof(GSWFillCommand) == 40) ? 1 : -1];
typedef char GSWCopySizeCheck[(sizeof(GSWCopyCommand) == 44) ? 1 : -1];
typedef char GSWRegisterSizeCheck[(sizeof(GSWRegisterSurfaceCommand) == 48) ? 1 : -1];
typedef char GSWUnregisterSizeCheck[(sizeof(GSWUnregisterSurfaceCommand) == 20) ? 1 : -1];
typedef char GSWSurfaceFillSizeCheck[(sizeof(GSWSurfaceFillCommand) == 40) ? 1 : -1];
typedef char GSWSurfaceBltSizeCheck[(sizeof(GSWSurfaceBltCommand) == 76) ? 1 : -1];
typedef char GSWSurfacePresentSizeCheck[(sizeof(GSWSurfacePresentCommand) == 20) ? 1 : -1];
typedef char GSWSurfaceDirtySizeCheck[(sizeof(GSWSurfaceDirtyCommand) == 36) ? 1 : -1];

static PCIAddress gsw_pci_address;
static volatile DWORD *gsw_registers = NULL;
static volatile BYTE *gsw_ring = NULL;
static DWORD gsw_ring_physical = 0;
static DWORD gsw_ring_tail = 0;
static DWORD gsw_fence_low = 1;
static DWORD gsw_fence_high = 0;
static DWORD gsw_framebuffer_linear = 0;
static DWORD gsw_framebuffer_size = 0;
static DWORD gsw_capabilities = 0;
static DWORD gsw_semaphore = 0;
static WORD gsw_original_pci_command = 0;
static BOOL gsw_pci_command_saved = FALSE;
static BOOL gsw_is_ready = FALSE;

typedef struct GSWSurfaceRecord {
	DWORD id;
	DWORD offset;
	DWORD byte_size;
	DWORD width;
	DWORD height;
	DWORD pitch;
	DWORD bpp;
	DWORD flags;
} GSWSurfaceRecord;

static GSWSurfaceRecord gsw_surfaces[256];
static DWORD gsw_next_surface_id = 1;

static DWORD gsw_register_read(DWORD offset)
{
	return gsw_registers[offset >> 2];
}

static void gsw_register_write(DWORD offset, DWORD value)
{
	gsw_registers[offset >> 2] = value;
}

DWORD GSW_transport_register_read(DWORD offset)
{
	if(gsw_registers == NULL || offset >= GSW_VGA_CONTROL_BYTES || (offset & 3) != 0)
		return 0;
	return gsw_register_read(offset);
}

void GSW_transport_register_write(DWORD offset, DWORD value)
{
	if(gsw_registers != NULL && offset < GSW_VGA_CONTROL_BYTES && (offset & 3) == 0)
		gsw_register_write(offset, value);
}

static DWORD gsw_bytes_per_pixel(DWORD bpp)
{
	switch(bpp)
	{
		case 8:  return 1;
		case 15:
		case 16: return 2;
		case 24: return 3;
		case 32: return 4;
	}
	return 0;
}

static DWORD gsw_pixel_format(DWORD bpp)
{
	switch(bpp)
	{
		case 8:  return GSW_PIXEL_FORMAT_INDEXED_8;
		case 15: return GSW_PIXEL_FORMAT_RGB_555;
		case 16: return GSW_PIXEL_FORMAT_RGB_565;
		case 24: return GSW_PIXEL_FORMAT_RGB_888;
		case 32: return GSW_PIXEL_FORMAT_XRGB_8888;
	}
	return 0;
}

static BOOL gsw_surface_valid(
	DWORD offset,
	DWORD pitch,
	DWORD width,
	DWORD height,
	DWORD bpp
)
{
	DWORD bytes;
	DWORD row_bytes;
	DWORD remaining;

	bytes = gsw_bytes_per_pixel(bpp);
	if(bytes == 0 || width == 0 || height == 0 || pitch == 0)
		return FALSE;
	if(offset % bytes != 0 || pitch % bytes != 0)
		return FALSE;
	if(width > 0xFFFFFFFFUL / bytes)
		return FALSE;

	row_bytes = width * bytes;
	if(row_bytes > pitch || offset > gsw_framebuffer_size)
		return FALSE;

	remaining = gsw_framebuffer_size - offset;
	if(row_bytes > remaining)
		return FALSE;
	if(height - 1 > (remaining - row_bytes) / pitch)
		return FALSE;

	return TRUE;
}

static BOOL gsw_scanout_valid(
	DWORD offset,
	DWORD pitch,
	DWORD width,
	DWORD height,
	DWORD bpp
)
{
	DWORD bytes;
	DWORD row_bytes;
	DWORD row_offset;

	if(width > GSW_VGA_MAX_WIDTH || height > GSW_VGA_MAX_HEIGHT ||
	   !gsw_surface_valid(offset, pitch, width, height, bpp))
		return FALSE;

	bytes = gsw_bytes_per_pixel(bpp);
	row_bytes = width * bytes;
	row_offset = offset % pitch;
	return row_bytes <= pitch - row_offset &&
	       pitch / bytes <= 0xFFFFUL && offset / pitch <= 0xFFFFUL;
}

static void gsw_advance_fence(void)
{
	gsw_fence_low++;
	if(gsw_fence_low == 0)
	{
		gsw_fence_high++;
		if(gsw_fence_high == 0)
			gsw_fence_low = 1;
	}
}

static void gsw_ring_copy(DWORD offset, const BYTE *source, DWORD length)
{
	DWORD i;
	for(i = 0; i < length; i++)
		gsw_ring[(offset + i) & (GSW_VGA_RING_BYTES - 1)] = source[i];
}

static void gsw_recover_failed_submission(void)
{
	DWORD head;

	if(gsw_registers == NULL)
		return;

	head = gsw_register_read(GSW_VGA_REG_RING_HEAD) & (GSW_VGA_RING_BYTES - 1);
	gsw_ring_tail = head;
	gsw_register_write(GSW_VGA_REG_RING_TAIL, head);
	gsw_register_write(GSW_VGA_REG_STATUS, GSW_VGA_STATUS_ERROR);
	gsw_register_write(GSW_VGA_REG_IRQ_STATUS, GSW_VGA_IRQ_2D);
}

static BOOL gsw_submit_locked(void *command, DWORD length)
{
	GSWCommandHeader *header;
	DWORD new_tail;
	DWORD status;
	BOOL success;

	if(!gsw_is_ready || command == NULL || length < sizeof(GSWCommandHeader) ||
	   length >= GSW_VGA_RING_BYTES || (length & 3) != 0)
		return FALSE;

	success = FALSE;
	if(!gsw_is_ready)
		goto done;

	status = gsw_register_read(GSW_VGA_REG_STATUS);
	if((status & GSW_VGA_STATUS_READY) == 0 ||
	   (status & GSW_VGA_STATUS_ERROR) != 0 ||
	   gsw_register_read(GSW_VGA_REG_RING_HEAD) != gsw_ring_tail ||
	   gsw_register_read(GSW_VGA_REG_RING_TAIL) != gsw_ring_tail)
		goto done;

	header = (GSWCommandHeader *)command;
	header->version = header->opcode >= GSW_VGA_OPCODE_REGISTER_SURFACE ?
		GSW_VGA_COMMAND_VERSION_3 : GSW_VGA_COMMAND_VERSION_2;
	header->length = length;
	header->fence_low = gsw_fence_low;
	header->fence_high = gsw_fence_high;

	gsw_ring_copy(gsw_ring_tail, (const BYTE *)command, length);
	new_tail = (gsw_ring_tail + length) & (GSW_VGA_RING_BYTES - 1);
	gsw_register_write(GSW_VGA_REG_RING_TAIL, new_tail);
	gsw_register_write(GSW_VGA_REG_DOORBELL, 1);

	status = gsw_register_read(GSW_VGA_REG_STATUS);
	if((status & GSW_VGA_STATUS_ERROR) != 0 ||
	   gsw_register_read(GSW_VGA_REG_RING_HEAD) != new_tail ||
	   gsw_register_read(GSW_VGA_REG_RING_TAIL) != new_tail ||
	   gsw_register_read(GSW_VGA_REG_FENCE_LOW) != gsw_fence_low ||
	   gsw_register_read(GSW_VGA_REG_FENCE_HIGH) != gsw_fence_high)
		goto done;

	gsw_register_write(GSW_VGA_REG_IRQ_STATUS, GSW_VGA_IRQ_2D);
	gsw_ring_tail = new_tail;
	gsw_advance_fence();
	success = TRUE;

done:
	if(!success)
		gsw_recover_failed_submission();
	return success;
}

static BOOL gsw_begin(void)
{
	if(gsw_semaphore == 0) return FALSE;
	Wait_Semaphore(gsw_semaphore, 0);
	if(!gsw_is_ready)
	{
		Signal_Semaphore(gsw_semaphore);
		return FALSE;
	}
	return TRUE;
}

static void gsw_end(void)
{
	Signal_Semaphore(gsw_semaphore);
}

static BOOL gsw_submit(void *command, DWORD length)
{
	BOOL success;
	if(!gsw_begin()) return FALSE;
	success = gsw_submit_locked(command, length);
	gsw_end();
	return success;
}

BOOL GSW_transport_init(void)
{
	DWORD bar0_raw;
	DWORD bar1_raw;
	DWORD bar0;
	DWORD bar1;
	DWORD bar0_size;
	DWORD bar1_size;
	DWORD capability;
	DWORD capability_info;
	DWORD vram_megabytes;
	DWORD command;
	DWORD original_command;
	DWORD ring_linear;

	if(gsw_is_ready)
		return TRUE;
	if(gsw_semaphore == 0)
	{
		gsw_semaphore = Create_Semaphore(1);
		if(gsw_semaphore == 0) return FALSE;
	}

	if(!PCI_FindDevice(GSW_PCI_VENDOR_ID, GSW_PCI_DEVICE_ID, &gsw_pci_address))
		return FALSE;

	capability = PCI_ConfigRead32(&gsw_pci_address, GSW_PCI_CAPABILITY_OFFSET);
	capability_info = PCI_ConfigRead32(&gsw_pci_address, GSW_PCI_CAPABILITY_OFFSET + 4);
	vram_megabytes = PCI_ConfigRead16(&gsw_pci_address, GSW_PCI_CAPABILITY_OFFSET + 8);
	if(capability != GSW_PCI_CAPABILITY_SIGNATURE ||
	   (capability_info & 0xFFFF) < GSW_PCI_CAPABILITY_VERSION ||
	   (capability_info >> 16) < GSW_PCI_CAPABILITY_LENGTH ||
	   vram_megabytes == 0 || vram_megabytes > 256)
		return FALSE;

	bar0_raw = PCI_ConfigRead32(&gsw_pci_address, 0x10);
	bar1_raw = PCI_ConfigRead32(&gsw_pci_address, 0x14);
	if((bar0_raw & (PCI_CONF_BAR_IO | PCI_CONF_BAR_64BIT)) != 0 ||
	   (bar1_raw & (PCI_CONF_BAR_IO | PCI_CONF_BAR_64BIT)) != 0)
		return FALSE;

	bar0 = PCI_GetBARAddr(&gsw_pci_address, 0);
	bar1 = PCI_GetBARAddr(&gsw_pci_address, 1);
	original_command = PCI_ConfigRead16(&gsw_pci_address, 4);
	PCI_ConfigWrite16(&gsw_pci_address, 4, (WORD)(original_command & ~0x0002));
	bar0_size = PCI_GetBARSize(&gsw_pci_address, 0);
	bar1_size = PCI_GetBARSize(&gsw_pci_address, 1);
	PCI_ConfigWrite16(&gsw_pci_address, 4, (WORD)original_command);
	if(bar0 == 0 || bar1 == 0 || bar0_size != GSW_VGA_CONTROL_BYTES ||
	   bar1_size != vram_megabytes * 1024UL * 1024UL)
		return FALSE;

	gsw_original_pci_command = (WORD)original_command;
	gsw_pci_command_saved = TRUE;
	PCI_ConfigWrite16(&gsw_pci_address, 4, (WORD)(original_command | 0x0003));
	command = PCI_ConfigRead16(&gsw_pci_address, 4);
	if((command & 0x0003) != 0x0003)
	{
		GSW_transport_shutdown();
		return FALSE;
	}

	gsw_registers = (volatile DWORD *)_MapPhysToLinear(bar0, GSW_VGA_CONTROL_BYTES, 0);
	if(gsw_registers == NULL)
	{
		GSW_transport_shutdown();
		return FALSE;
	}

	if(gsw_register_read(GSW_VGA_REG_ID) != GSW_VGA_ID ||
	   gsw_register_read(GSW_VGA_REG_VERSION) != GSW_VGA_INTERFACE_VERSION)
	{
		GSW_transport_shutdown();
		return FALSE;
	}

	gsw_capabilities = gsw_register_read(GSW_VGA_REG_CAPABILITIES);
	if((gsw_capabilities & (GSW_VGA_CAP_2D | GSW_VGA_CAP_SURFACE_OFFSET)) !=
	   (GSW_VGA_CAP_2D | GSW_VGA_CAP_SURFACE_OFFSET))
	{
		GSW_transport_shutdown();
		return FALSE;
	}

	gsw_framebuffer_size = bar1_size;
	gsw_framebuffer_linear = _MapPhysToLinear(bar1, bar1_size, 0);
	if(gsw_framebuffer_linear == 0)
	{
		GSW_transport_shutdown();
		return FALSE;
	}

	ring_linear = _PageAllocate(
		RoundToPages(GSW_VGA_RING_BYTES),
		PG_SYS,
		0,
		0,
		PAGE_ALLOC_MIN,
		PAGE_ALLOC_MAX,
		&gsw_ring_physical,
		PAGECONTIG | PAGEUSEALIGN | PAGEFIXED | PAGEZEROINIT
	);
	if(ring_linear == 0)
	{
		GSW_transport_shutdown();
		return FALSE;
	}
	if((gsw_ring_physical & (GSW_VGA_RING_BYTES - 1)) != 0)
	{
		_PageFree((PVOID)ring_linear, 0);
		gsw_ring_physical = 0;
		GSW_transport_shutdown();
		return FALSE;
	}
	gsw_ring = (volatile BYTE *)ring_linear;

	gsw_ring_tail = 0;
	gsw_fence_low = 1;
	gsw_fence_high = 0;
	gsw_register_write(GSW_VGA_REG_IRQ_ENABLE, 0);
	gsw_register_write(GSW_VGA_REG_IRQ_STATUS, GSW_VGA_IRQ_2D);
	gsw_register_write(GSW_VGA_REG_STATUS, GSW_VGA_STATUS_ERROR);
	gsw_register_write(GSW_VGA_REG_RING_GPA_LOW, gsw_ring_physical);
	gsw_register_write(GSW_VGA_REG_RING_GPA_HIGH, 0);
	gsw_register_write(GSW_VGA_REG_RING_SIZE, GSW_VGA_RING_BYTES);
	gsw_register_write(GSW_VGA_REG_RING_HEAD, 0);
	gsw_register_write(GSW_VGA_REG_RING_TAIL, 0);

	if((gsw_register_read(GSW_VGA_REG_STATUS) & GSW_VGA_STATUS_READY) == 0)
	{
		GSW_transport_shutdown();
		return FALSE;
	}

	gsw_is_ready = TRUE;
	(void)GSW3D_transport_init();
	return TRUE;
}

void GSW_transport_shutdown(void)
{
	if(gsw_semaphore != 0) Wait_Semaphore(gsw_semaphore, 0);
	GSW3D_transport_shutdown();
	gsw_is_ready = FALSE;
	if(gsw_registers != NULL)
	{
		gsw_register_write(GSW_VGA_REG_IRQ_ENABLE, 0);
		gsw_register_write(GSW_VGA_REG_RING_HEAD, 0);
		gsw_register_write(GSW_VGA_REG_RING_TAIL, 0);
		gsw_register_write(GSW_VGA_REG_RING_GPA_LOW, 0);
		gsw_register_write(GSW_VGA_REG_RING_GPA_HIGH, 0);
		gsw_register_write(GSW_VGA_REG_RING_SIZE, 0);
	}
	if(gsw_ring != NULL)
	{
		_PageFree((PVOID)gsw_ring, 0);
		gsw_ring = NULL;
	}
	gsw_ring_physical = 0;
	gsw_ring_tail = 0;
	gsw_fence_low = 1;
	gsw_fence_high = 0;
	gsw_framebuffer_linear = 0;
	gsw_framebuffer_size = 0;
	gsw_capabilities = 0;
	memset(gsw_surfaces, 0, sizeof(gsw_surfaces));
	gsw_next_surface_id = 1;
	gsw_registers = NULL;
	if(gsw_pci_command_saved)
	{
		PCI_ConfigWrite16(&gsw_pci_address, 4, gsw_original_pci_command);
		gsw_pci_command_saved = FALSE;
	}
	gsw_original_pci_command = 0;
	memset(&gsw_pci_address, 0, sizeof(gsw_pci_address));
	if(gsw_semaphore != 0) Signal_Semaphore(gsw_semaphore);
}

void GSW_transport_release(void)
{
	GSW_transport_shutdown();
	/* The VMM owns this single semaphore through the VxD lifetime. */
}

BOOL GSW_transport_ready(void)
{
	return gsw_is_ready;
}

void *GSW_transport_framebuffer(void)
{
	return gsw_is_ready ? (void *)gsw_framebuffer_linear : NULL;
}

DWORD GSW_transport_framebuffer_bytes(void)
{
	return gsw_is_ready ? gsw_framebuffer_size : 0;
}

DWORD GSW_transport_capabilities(void)
{
	return gsw_is_ready ? gsw_capabilities : 0;
}

BOOL GSW_transport_mode_valid(DWORD width, DWORD height, DWORD pitch, DWORD bpp)
{
	return gsw_is_ready && gsw_scanout_valid(0, pitch, width, height, bpp);
}

BOOL GSW_transport_set_mode(DWORD width, DWORD height, DWORD pitch, DWORD bpp)
{
	GSWSetModeCommand command;

	if(!GSW_transport_mode_valid(width, height, pitch, bpp))
		return FALSE;

	memset(&command, 0, sizeof(command));
	command.header.opcode = GSW_VGA_OPCODE_SET_MODE;
	command.width = width;
	command.height = height;
	command.pitch = pitch;
	command.format = gsw_pixel_format(bpp);
	return gsw_submit(&command, sizeof(command));
}

BOOL GSW_transport_present(
	DWORD offset,
	DWORD width,
	DWORD height,
	DWORD pitch,
	DWORD bpp
)
{
	GSWPresentCommand command;

	if(!gsw_is_ready || !gsw_scanout_valid(offset, pitch, width, height, bpp))
		return FALSE;

	memset(&command, 0, sizeof(command));
	command.header.opcode = GSW_VGA_OPCODE_PRESENT;
	command.offset = offset;
	command.width = width;
	command.height = height;
	command.pitch = pitch;
	command.format = gsw_pixel_format(bpp);
	return gsw_submit(&command, sizeof(command));
}

BOOL GSW_transport_fill(
	DWORD offset,
	DWORD pitch,
	DWORD width,
	DWORD height,
	DWORD color,
	DWORD bpp
)
{
	GSWFillCommand command;

	if(!gsw_is_ready || !gsw_surface_valid(offset, pitch, width, height, bpp) ||
	   height > GSW_VGA_MAX_SOFTWARE_PIXELS / width)
		return FALSE;

	memset(&command, 0, sizeof(command));
	command.header.opcode = GSW_VGA_OPCODE_FILL;
	command.offset = offset;
	command.pitch = pitch;
	command.width = width;
	command.height = height;
	command.color = color;
	command.format = gsw_pixel_format(bpp);
	return gsw_submit(&command, sizeof(command));
}

BOOL GSW_transport_copy(
	DWORD source,
	DWORD destination,
	DWORD source_pitch,
	DWORD destination_pitch,
	DWORD width,
	DWORD height,
	DWORD bpp
)
{
	GSWCopyCommand command;

	if(!gsw_is_ready ||
	   !gsw_surface_valid(source, source_pitch, width, height, bpp) ||
	   !gsw_surface_valid(destination, destination_pitch, width, height, bpp) ||
	   height > GSW_VGA_MAX_SOFTWARE_PIXELS / width)
		return FALSE;

	memset(&command, 0, sizeof(command));
	command.header.opcode = GSW_VGA_OPCODE_COPY;
	command.source = source;
	command.destination = destination;
	command.source_pitch = source_pitch;
	command.destination_pitch = destination_pitch;
	command.width = width;
	command.height = height;
	command.format = gsw_pixel_format(bpp);
	return gsw_submit(&command, sizeof(command));
}

static GSWSurfaceRecord *gsw_surface_find(DWORD id)
{
	GSWSurfaceRecord *surface;
	if(id == 0)
		return NULL;
	surface = &gsw_surfaces[id & 255];
	return surface->id == id ? surface : NULL;
}

static BOOL gsw_surface_rect_valid(
	const GSWSurfaceRecord *surface,
	DWORD x,
	DWORD y,
	DWORD width,
	DWORD height
)
{
	if(surface == NULL || width == 0 || height == 0 ||
	   x > surface->width || width > surface->width - x ||
	   y > surface->height || height > surface->height - y)
		return FALSE;
	return TRUE;
}

BOOL GSW_transport_surface_register(GSWDDRegister *request)
{
	GSWRegisterSurfaceCommand command;
	GSWSurfaceRecord *surface;
	DWORD attempts;
	DWORD id;
	BOOL success = FALSE;

	if(request == NULL || request->cb != sizeof(*request) || !gsw_begin())
		return FALSE;
	if(
	   (gsw_capabilities & GSW_VGA_CAP_SURFACE_IDS) == 0 ||
	   !gsw_surface_valid(
		request->offset, request->pitch, request->width, request->height, request->bpp
	   ) || request->byte_size == 0 || request->offset > gsw_framebuffer_size ||
	   request->byte_size > gsw_framebuffer_size - request->offset ||
	   request->flags & ~GSW_DD_SURFACE_PRESENTABLE)
		goto done;

	for(attempts = 0; attempts < 256; attempts++)
	{
		id = gsw_next_surface_id++;
		if(id == 0)
			id = gsw_next_surface_id++;
		if(gsw_surfaces[id & 255].id == 0)
			break;
	}
	if(attempts == 256)
		goto done;

	memset(&command, 0, sizeof(command));
	command.header.opcode = GSW_VGA_OPCODE_REGISTER_SURFACE;
	command.surface_id = id;
	command.offset = request->offset;
	command.byte_size = request->byte_size;
	command.width = request->width;
	command.height = request->height;
	command.pitch = request->pitch;
	command.format = gsw_pixel_format(request->bpp);
	command.flags = request->flags;
	if(!gsw_submit_locked(&command, sizeof(command)))
		goto done;

	surface = &gsw_surfaces[id & 255];
	surface->id = id;
	surface->offset = request->offset;
	surface->byte_size = request->byte_size;
	surface->width = request->width;
	surface->height = request->height;
	surface->pitch = request->pitch;
	surface->bpp = request->bpp;
	surface->flags = request->flags;
	request->surface_id = id;
	success = TRUE;
done:
	gsw_end();
	return success;
}

BOOL GSW_transport_surface_unregister(DWORD surface_id)
{
	GSWUnregisterSurfaceCommand command;
	GSWSurfaceRecord *surface;
	BOOL success = FALSE;
	if(!gsw_begin()) return FALSE;
	surface = gsw_surface_find(surface_id);
	if(surface == NULL) goto done;
	memset(&command, 0, sizeof(command));
	command.header.opcode = GSW_VGA_OPCODE_UNREGISTER_SURFACE;
	command.surface_id = surface_id;
	if(!gsw_submit_locked(&command, sizeof(command))) goto done;
	memset(surface, 0, sizeof(*surface));
	success = TRUE;
done:
	gsw_end();
	return success;
}

BOOL GSW_transport_surface_fill(const GSWDDFill *request)
{
	GSWSurfaceFillCommand command;
	GSWSurfaceRecord *surface;
	BOOL success = FALSE;
	if(request == NULL || request->cb != sizeof(*request))
		return FALSE;
	if(!gsw_begin()) return FALSE;
	surface = gsw_surface_find(request->surface_id);
	if(!gsw_surface_rect_valid(surface, request->x, request->y, request->width, request->height))
		goto done;
	memset(&command, 0, sizeof(command));
	command.header.opcode = GSW_VGA_OPCODE_SURFACE_FILL;
	command.surface_id = request->surface_id;
	command.x = request->x;
	command.y = request->y;
	command.width = request->width;
	command.height = request->height;
	command.color = request->color;
	success = gsw_submit_locked(&command, sizeof(command));
done:
	gsw_end();
	return success;
}

BOOL GSW_transport_surface_blt(const GSWDDBlt *request)
{
	GSWSurfaceBltCommand command;
	GSWSurfaceRecord *source;
	GSWSurfaceRecord *destination;
	BOOL success = FALSE;
	if(request == NULL || request->cb != sizeof(*request) ||
	   request->flags & ~(GSW_DD_BLT_SRC_COLOR_KEY | GSW_DD_BLT_DST_COLOR_KEY))
		return FALSE;
	if(!gsw_begin()) return FALSE;
	source = gsw_surface_find(request->source_id);
	destination = gsw_surface_find(request->destination_id);
	if(source == NULL || destination == NULL || source->bpp != destination->bpp ||
	   !gsw_surface_rect_valid(
		source, request->source_x, request->source_y,
		request->source_width, request->source_height
	   ) || !gsw_surface_rect_valid(
		destination, request->destination_x, request->destination_y,
		request->destination_width, request->destination_height
	   ))
		goto done;
	memset(&command, 0, sizeof(command));
	command.header.opcode = GSW_VGA_OPCODE_SURFACE_BLT;
	command.source_id = request->source_id;
	command.destination_id = request->destination_id;
	command.source_x = request->source_x;
	command.source_y = request->source_y;
	command.source_width = request->source_width;
	command.source_height = request->source_height;
	command.destination_x = request->destination_x;
	command.destination_y = request->destination_y;
	command.destination_width = request->destination_width;
	command.destination_height = request->destination_height;
	command.flags = request->flags;
	command.source_color_key = request->source_color_key;
	command.destination_color_key = request->destination_color_key;
	command.pattern = request->pattern;
	command.rop3 = request->rop3;
	success = gsw_submit_locked(&command, sizeof(command));
done:
	gsw_end();
	return success;
}

BOOL GSW_transport_surface_present(DWORD surface_id)
{
	GSWSurfacePresentCommand command;
	GSWSurfaceRecord *surface;
	BOOL success = FALSE;
	if(!gsw_begin()) return FALSE;
	surface = gsw_surface_find(surface_id);
	if(surface == NULL || (surface->flags & GSW_DD_SURFACE_PRESENTABLE) == 0)
		goto done;
	memset(&command, 0, sizeof(command));
	command.header.opcode = GSW_VGA_OPCODE_SURFACE_PRESENT;
	command.surface_id = surface_id;
	success = gsw_submit_locked(&command, sizeof(command));
done:
	gsw_end();
	return success;
}

BOOL GSW_transport_surface_dirty(const GSWDDDirty *request)
{
	GSWSurfaceDirtyCommand command;
	GSWSurfaceRecord *surface;
	BOOL success = FALSE;
	if(request == NULL || request->cb != sizeof(*request))
		return FALSE;
	if(!gsw_begin()) return FALSE;
	surface = gsw_surface_find(request->surface_id);
	if(!gsw_surface_rect_valid(surface, request->x, request->y, request->width, request->height))
		goto done;
	memset(&command, 0, sizeof(command));
	command.header.opcode = GSW_VGA_OPCODE_SURFACE_DIRTY;
	command.surface_id = request->surface_id;
	command.x = request->x;
	command.y = request->y;
	command.width = request->width;
	command.height = request->height;
	success = gsw_submit_locked(&command, sizeof(command));
done:
	gsw_end();
	return success;
}
