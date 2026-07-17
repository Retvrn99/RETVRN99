/* SPDX-License-Identifier: GPL-3.0-only */

#include "winhack.h"
#include "vmm.h"
#include "vxd_lib.h"
#include "gsw_transport.h"
#include "code32.h"

#define GSW3D_RING_BYTES                  0x1000UL
#define GSW3D_STAGING_REGION_ID           0x4753FFF0UL
#define GSW3D_CONTEXT_CAPACITY            128

typedef char GSW3DHeaderSizeCheck[(sizeof(GSW3DCommandHeader) == 16) ? 1 : -1];
typedef char GSW3DRegionSizeCheck[(sizeof(GSW3DRegionCommand) == 40) ? 1 : -1];
typedef char GSW3DIdSizeCheck[(sizeof(GSW3DIdCommand) == 24) ? 1 : -1];
typedef char GSW3DSubmitSizeCheck[(sizeof(GSW3DSubmitCommand) == 40) ? 1 : -1];
typedef char GSW3DUploadSizeCheck[(sizeof(GSW3DUploadCommand) == 48) ? 1 : -1];
typedef char GSW3DPresentSizeCheck[(sizeof(GSW3DPresentCommand) == 64) ? 1 : -1];

static volatile BYTE *gsw3d_ring = NULL;
static BYTE *gsw3d_staging = NULL;
static DWORD gsw3d_ring_physical = 0;
static DWORD gsw3d_staging_physical = 0;
static DWORD gsw3d_ring_tail = 0;
static DWORD gsw3d_fence_low = 1;
static DWORD gsw3d_fence_high = 0;
static DWORD gsw3d_capabilities = 0;
static DWORD gsw3d_present_intervals = 0;
static DWORD gsw3d_semaphore = 0;
static DWORD gsw3d_contexts[GSW3D_CONTEXT_CAPACITY];
static BOOL gsw3d_ready = FALSE;

static void gsw3d_result_snapshot(GSW3DResult *result, BOOL success, DWORD fence_low, DWORD fence_high)
{
	if(result == NULL) return;
	memset(result, 0, sizeof(*result));
	result->cb = sizeof(*result);
	result->success = success ? 1 : 0;
	result->fence_low = fence_low;
	result->fence_high = fence_high;
	result->completed_low = GSW_transport_register_read(GSW3D_REG_FENCE_LOW);
	result->completed_high = GSW_transport_register_read(GSW3D_REG_FENCE_HIGH);
	result->status = GSW_transport_register_read(GSW3D_REG_STATUS);
	result->error = GSW_transport_register_read(GSW3D_REG_ERROR);
}

static void gsw3d_result_unavailable(GSW3DResult *result)
{
	if(result == NULL) return;
	memset(result, 0, sizeof(*result));
	result->cb = sizeof(*result);
}

static BOOL gsw3d_begin(void)
{
	if(gsw3d_semaphore == 0) return FALSE;
	Wait_Semaphore(gsw3d_semaphore, 0);
	if(!gsw3d_ready)
	{
		Signal_Semaphore(gsw3d_semaphore);
		return FALSE;
	}
	return TRUE;
}

static void gsw3d_end(void)
{
	Signal_Semaphore(gsw3d_semaphore);
}

static void gsw3d_advance_fence(void)
{
	gsw3d_fence_low++;
	if(gsw3d_fence_low == 0)
	{
		gsw3d_fence_high++;
		if(gsw3d_fence_high == 0) gsw3d_fence_low = 1;
	}
}

static void gsw3d_ring_copy(DWORD offset, const BYTE *source, DWORD length)
{
	DWORD i;
	for(i = 0; i < length; i++)
		gsw3d_ring[(offset + i) & (GSW3D_RING_BYTES - 1)] = source[i];
}

static BOOL gsw3d_submit_locked(void *descriptor, DWORD length, DWORD *fence_low, DWORD *fence_high)
{
	GSW3DCommandHeader *header;
	DWORD current_low;
	DWORD current_high;
	DWORD new_tail;
	DWORD status;

	if(!gsw3d_ready || descriptor == NULL || length < sizeof(GSW3DCommandHeader) ||
	   length >= GSW3D_RING_BYTES || (length & 3) != 0)
		return FALSE;
	status = GSW_transport_register_read(GSW3D_REG_STATUS);
	if((status & GSW3D_STATUS_READY) == 0 || (status & GSW3D_STATUS_ERROR) != 0 ||
	   GSW_transport_register_read(GSW3D_REG_RING_HEAD) != gsw3d_ring_tail ||
	   GSW_transport_register_read(GSW3D_REG_RING_TAIL) != gsw3d_ring_tail)
		return FALSE;

	current_low = gsw3d_fence_low;
	current_high = gsw3d_fence_high;
	header = (GSW3DCommandHeader *)descriptor;
	header->version = GSW3D_COMMAND_VERSION;
	header->length = length;
	header->fence_low = current_low;
	header->fence_high = current_high;
	gsw3d_ring_copy(gsw3d_ring_tail, (const BYTE *)descriptor, length);
	new_tail = (gsw3d_ring_tail + length) & (GSW3D_RING_BYTES - 1);
	GSW_transport_register_write(GSW3D_REG_RING_TAIL, new_tail);
	GSW_transport_register_write(GSW3D_REG_DOORBELL, 1);
	status = GSW_transport_register_read(GSW3D_REG_STATUS);
	if(GSW_transport_register_read(GSW3D_REG_RING_HEAD) != new_tail ||
	   GSW_transport_register_read(GSW3D_REG_RING_TAIL) != new_tail ||
	   (status & GSW3D_STATUS_ERROR) != 0)
	{
		gsw3d_ring_tail = GSW_transport_register_read(GSW3D_REG_RING_HEAD) &
			(GSW3D_RING_BYTES - 1);
		GSW_transport_register_write(GSW3D_REG_RING_TAIL, gsw3d_ring_tail);
		return FALSE;
	}

	GSW_transport_register_write(GSW_VGA_REG_IRQ_STATUS, GSW_VGA_IRQ_3D);
	gsw3d_ring_tail = new_tail;
	gsw3d_advance_fence();
	if(fence_low != NULL) *fence_low = current_low;
	if(fence_high != NULL) *fence_high = current_high;
	return TRUE;
}

static BOOL gsw3d_context_find(DWORD context_id, DWORD *slot)
{
	DWORD i;
	for(i = 0; i < GSW3D_CONTEXT_CAPACITY; i++)
	{
		if(gsw3d_contexts[i] == context_id)
		{
			if(slot != NULL) *slot = i;
			return TRUE;
		}
	}
	return FALSE;
}

static BOOL gsw3d_context_free(DWORD *slot)
{
	DWORD i;
	for(i = 0; i < GSW3D_CONTEXT_CAPACITY; i++)
	{
		if(gsw3d_contexts[i] == 0)
		{
			if(slot != NULL) *slot = i;
			return TRUE;
		}
	}
	return FALSE;
}

BOOL GSW3D_transport_init(void)
{
	GSW3DRegionCommand region;
	DWORD ring_linear;
	DWORD staging_linear;
	DWORD required;
	DWORD fence_low;
	DWORD fence_high;

	if(gsw3d_ready) return TRUE;
	required = GSW_VGA_CAP_3D_SVGA9 | GSW_VGA_CAP_DIRECT_PRESENT |
		GSW_VGA_CAP_RESOURCE_UPLOAD;
	if(!GSW_transport_ready() ||
	   (GSW_transport_capabilities() & required) != required ||
	   GSW_transport_register_read(GSW3D_REG_PACKET_FORMAT) != GSW3D_PACKET_SVGA9 ||
	   (GSW_transport_register_read(GSW3D_REG_STATUS) & GSW3D_STATUS_READY) == 0)
		return FALSE;
	if(gsw3d_semaphore == 0)
	{
		gsw3d_semaphore = Create_Semaphore(1);
		if(gsw3d_semaphore == 0) return FALSE;
	}

	ring_linear = _PageAllocate(
		RoundToPages(GSW3D_RING_BYTES), PG_SYS, 0, 0, PAGE_ALLOC_MIN,
		PAGE_ALLOC_MAX, &gsw3d_ring_physical,
		PAGECONTIG | PAGEUSEALIGN | PAGEFIXED | PAGEZEROINIT
	);
	if(ring_linear == 0 || (gsw3d_ring_physical & (GSW3D_RING_BYTES - 1)) != 0)
	{
		if(ring_linear != 0) _PageFree((PVOID)ring_linear, 0);
		gsw3d_ring_physical = 0;
		return FALSE;
	}
	gsw3d_ring = (volatile BYTE *)ring_linear;

	staging_linear = _PageAllocate(
		RoundToPages(GSW3D_STAGING_BYTES), PG_SYS, 0, 0, PAGE_ALLOC_MIN,
		PAGE_ALLOC_MAX, &gsw3d_staging_physical,
		PAGECONTIG | PAGEUSEALIGN | PAGEFIXED | PAGEZEROINIT
	);
	if(staging_linear == 0)
	{
		_PageFree((PVOID)gsw3d_ring, 0);
		gsw3d_ring = NULL;
		gsw3d_ring_physical = 0;
		return FALSE;
	}
	gsw3d_staging = (BYTE *)staging_linear;
	gsw3d_capabilities = GSW_transport_register_read(GSW3D_REG_CAPABILITIES);
	gsw3d_present_intervals = GSW_transport_register_read(GSW3D_REG_PRESENT_INTERVALS);
	gsw3d_ring_tail = 0;
	gsw3d_fence_low = 1;
	gsw3d_fence_high = 0;
	memset(gsw3d_contexts, 0, sizeof(gsw3d_contexts));
	GSW_transport_register_write(GSW3D_REG_RING_GPA_LOW, gsw3d_ring_physical);
	GSW_transport_register_write(GSW3D_REG_RING_GPA_HIGH, 0);
	GSW_transport_register_write(GSW3D_REG_RING_SIZE, GSW3D_RING_BYTES);
	GSW_transport_register_write(GSW3D_REG_RING_HEAD, 0);
	GSW_transport_register_write(GSW3D_REG_RING_TAIL, 0);
	GSW_transport_register_write(GSW3D_REG_STATUS, GSW3D_STATUS_ERROR);
	if((GSW_transport_register_read(GSW3D_REG_STATUS) & GSW3D_STATUS_READY) == 0)
	{
		GSW3D_transport_shutdown();
		return FALSE;
	}
	gsw3d_ready = TRUE;
	memset(&region, 0, sizeof(region));
	region.header.opcode = GSW3D_OPCODE_REGISTER_REGION;
	region.region_id = GSW3D_STAGING_REGION_ID;
	region.gpa_low = gsw3d_staging_physical;
	region.size_low = GSW3D_STAGING_BYTES;
	if(!gsw3d_submit_locked(&region, sizeof(region), &fence_low, &fence_high))
	{
		GSW3D_transport_shutdown();
		return FALSE;
	}
	return TRUE;
}

void GSW3D_transport_shutdown(void)
{
	GSW3DIdCommand unregister_region;
	DWORD ignored_low;
	DWORD ignored_high;
	if(gsw3d_semaphore != 0) Wait_Semaphore(gsw3d_semaphore, 0);
	if(gsw3d_ready)
	{
		memset(&unregister_region, 0, sizeof(unregister_region));
		unregister_region.header.opcode = GSW3D_OPCODE_UNREGISTER_REGION;
		unregister_region.id = GSW3D_STAGING_REGION_ID;
		(void)gsw3d_submit_locked(
			&unregister_region, sizeof(unregister_region), &ignored_low, &ignored_high
		);
		GSW_transport_register_write(GSW3D_REG_STATUS, GSW3D_STATUS_RESET);
		GSW_transport_register_write(GSW3D_REG_RING_HEAD, 0);
		GSW_transport_register_write(GSW3D_REG_RING_TAIL, 0);
		GSW_transport_register_write(GSW3D_REG_RING_GPA_LOW, 0);
		GSW_transport_register_write(GSW3D_REG_RING_GPA_HIGH, 0);
		GSW_transport_register_write(GSW3D_REG_RING_SIZE, 0);
	}
	gsw3d_ready = FALSE;
	if(gsw3d_staging != NULL) _PageFree((PVOID)gsw3d_staging, 0);
	if(gsw3d_ring != NULL) _PageFree((PVOID)gsw3d_ring, 0);
	gsw3d_staging = NULL;
	gsw3d_ring = NULL;
	gsw3d_staging_physical = 0;
	gsw3d_ring_physical = 0;
	gsw3d_ring_tail = 0;
	gsw3d_fence_low = 1;
	gsw3d_fence_high = 0;
	gsw3d_capabilities = 0;
	gsw3d_present_intervals = 0;
	memset(gsw3d_contexts, 0, sizeof(gsw3d_contexts));
	if(gsw3d_semaphore != 0) Signal_Semaphore(gsw3d_semaphore);
}

BOOL GSW3D_transport_query(GSW3DQuery *query)
{
	if(query == NULL) return FALSE;
	memset(query, 0, sizeof(*query));
	query->cb = sizeof(*query);
	query->version = GSW3D_ABI_VERSION;
	if(!gsw3d_begin()) return TRUE;
	query->available = 1;
	query->capabilities = gsw3d_capabilities;
	query->packet_format = GSW3D_PACKET_SVGA9;
	query->present_intervals = gsw3d_present_intervals;
	query->staging_bytes = GSW3D_STAGING_BYTES;
	query->maximum_batch_bytes = GSW3D_MAX_BATCH_BYTES;
	gsw3d_end();
	return TRUE;
}

BOOL GSW3D_transport_context(BOOL create, DWORD context_id, GSW3DResult *result)
{
	GSW3DIdCommand command;
	DWORD slot;
	DWORD fence_low = 0;
	DWORD fence_high = 0;
	BOOL success = FALSE;
	if(result == NULL || context_id == 0 || !gsw3d_begin())
	{
		gsw3d_result_unavailable(result);
		return FALSE;
	}
	if(create)
	{
		if(gsw3d_context_find(context_id, NULL) || !gsw3d_context_free(&slot)) goto done;
	}
	else if(!gsw3d_context_find(context_id, &slot)) goto done;
	memset(&command, 0, sizeof(command));
	command.header.opcode = create ? GSW3D_OPCODE_CREATE_CONTEXT : GSW3D_OPCODE_DESTROY_CONTEXT;
	command.id = context_id;
	if(!gsw3d_submit_locked(&command, sizeof(command), &fence_low, &fence_high)) goto done;
	gsw3d_contexts[slot] = create ? context_id : 0;
	success = TRUE;
done:
	gsw3d_result_snapshot(result, success, fence_low, fence_high);
	gsw3d_end();
	return success;
}

BOOL GSW3D_transport_submit(
	DWORD context_id, const BYTE *batch, DWORD byte_count, GSW3DResult *result
)
{
	GSW3DSubmitCommand command;
	DWORD fence_low = 0;
	DWORD fence_high = 0;
	BOOL success = FALSE;
	if(result == NULL || batch == NULL || byte_count == 0 ||
	   byte_count > GSW3D_MAX_BATCH_BYTES || (byte_count & 3) != 0 || !gsw3d_begin())
	{
		gsw3d_result_unavailable(result);
		return FALSE;
	}
	if(!gsw3d_context_find(context_id, NULL)) goto done;
	memcpy(gsw3d_staging, batch, byte_count);
	memset(&command, 0, sizeof(command));
	command.header.opcode = GSW3D_OPCODE_SUBMIT;
	command.context_id = context_id;
	command.region_id = GSW3D_STAGING_REGION_ID;
	command.byte_count = byte_count;
	command.packet_format = GSW3D_PACKET_SVGA9;
	success = gsw3d_submit_locked(&command, sizeof(command), &fence_low, &fence_high);
done:
	gsw3d_result_snapshot(result, success, fence_low, fence_high);
	gsw3d_end();
	return success;
}

BOOL GSW3D_transport_upload(
	DWORD resource_id, DWORD destination_offset_low, DWORD destination_offset_high,
	const BYTE *bytes, DWORD byte_count, GSW3DResult *result
)
{
	GSW3DUploadCommand command;
	DWORD fence_low = 0;
	DWORD fence_high = 0;
	BOOL success = FALSE;
	if(result == NULL || resource_id == 0 || bytes == NULL || byte_count == 0 ||
	   byte_count > GSW3D_STAGING_BYTES || !gsw3d_begin())
	{
		gsw3d_result_unavailable(result);
		return FALSE;
	}
	memcpy(gsw3d_staging, bytes, byte_count);
	memset(&command, 0, sizeof(command));
	command.header.opcode = GSW3D_OPCODE_RESOURCE_UPLOAD;
	command.resource_id = resource_id;
	command.region_id = GSW3D_STAGING_REGION_ID;
	command.destination_offset_low = destination_offset_low;
	command.destination_offset_high = destination_offset_high;
	command.byte_count = byte_count;
	success = gsw3d_submit_locked(&command, sizeof(command), &fence_low, &fence_high);
	gsw3d_result_snapshot(result, success, fence_low, fence_high);
	gsw3d_end();
	return success;
}

BOOL GSW3D_transport_present(const GSW3DPresentRequest *request, GSW3DResult *result)
{
	GSW3DPresentCommand command;
	DWORD fence_low = 0;
	DWORD fence_high = 0;
	BOOL success = FALSE;
	if(result == NULL || request == NULL || request->cb != sizeof(*request) ||
	   request->context_id == 0 || request->surface_id == 0 ||
	   request->source_width == 0 || request->source_height == 0 ||
	   request->destination_width == 0 || request->destination_height == 0 ||
	   request->source_x > 0xFFFFFFFFUL - request->source_width ||
	   request->source_y > 0xFFFFFFFFUL - request->source_height ||
	   request->destination_x > 0xFFFFFFFFUL - request->destination_width ||
	   request->destination_y > 0xFFFFFFFFUL - request->destination_height ||
	   request->interval > 31 ||
	   (gsw3d_present_intervals & (1UL << request->interval)) == 0 || !gsw3d_begin())
	{
		gsw3d_result_unavailable(result);
		return FALSE;
	}
	if(!gsw3d_context_find(request->context_id, NULL)) goto done;
	memset(&command, 0, sizeof(command));
	command.header.opcode = GSW3D_OPCODE_DIRECT_PRESENT;
	command.context_id = request->context_id;
	command.surface_id = request->surface_id;
	command.source_x = request->source_x;
	command.source_y = request->source_y;
	command.source_width = request->source_width;
	command.source_height = request->source_height;
	command.destination_x = request->destination_x;
	command.destination_y = request->destination_y;
	command.destination_width = request->destination_width;
	command.destination_height = request->destination_height;
	command.interval = request->interval;
	success = gsw3d_submit_locked(&command, sizeof(command), &fence_low, &fence_high);
done:
	gsw3d_result_snapshot(result, success, fence_low, fence_high);
	gsw3d_end();
	return success;
}

static BOOL gsw3d_fence_reached(DWORD completed_low, DWORD completed_high, DWORD low, DWORD high)
{
	return completed_high > high || (completed_high == high && completed_low >= low);
}

BOOL GSW3D_transport_fence_poll(const GSW3DFencePollRequest *request, GSW3DResult *result)
{
	DWORD completed_low;
	DWORD completed_high;
	BOOL success;
	if(result == NULL || request == NULL || request->cb != sizeof(*request) ||
	   (request->fence_low == 0 && request->fence_high == 0) || !gsw3d_begin())
	{
		gsw3d_result_unavailable(result);
		return FALSE;
	}
	completed_low = GSW_transport_register_read(GSW3D_REG_FENCE_LOW);
	completed_high = GSW_transport_register_read(GSW3D_REG_FENCE_HIGH);
	success = (GSW_transport_register_read(GSW3D_REG_STATUS) & GSW3D_STATUS_ERROR) == 0 &&
		gsw3d_fence_reached(
			completed_low, completed_high, request->fence_low, request->fence_high
		);
	gsw3d_result_snapshot(result, success, request->fence_low, request->fence_high);
	gsw3d_end();
	return success;
}
