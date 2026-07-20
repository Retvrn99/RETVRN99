/* SPDX-License-Identifier: GPL-3.0-only */
#include "winhack.h"
#include "vmm.h"
#include "vxd_lib.h"
#include "gsw_transport.h"

typedef struct GSWLockedRange {
	DWORD page;
	DWORD pages;
	BOOL locked;
} GSWLockedRange;

#define GSW_RING3_LIMIT 0x80000000UL
#define GSW_PTE_PRESENT 0x00000001UL
#define GSW_PTE_WRITE   0x00000002UL
#define GSW_PTE_USER    0x00000004UL

typedef union GSWDDPayload {
	GSWDDQuery query;
	GSWDDRegister registration;
	GSWDDUnregister unregister_request;
	GSWDDFill fill;
	GSWDDBlt blt;
	GSWDDPresent present;
	GSWDDDirty dirty;
	DWORD success;
} GSWDDPayload;

static BOOL gsw_dd_range_lock(
	DWORD address,
	DWORD bytes,
	BOOL writable,
	GSWLockedRange *range
)
{
	DWORD span;
	DWORD page_table[2];
	DWORD required;
	DWORD i;
	if(range == NULL) return FALSE;
	memset(range, 0, sizeof(*range));
	if(bytes == 0) return TRUE;
	if(address == 0 || address > 0xFFFFFFFFUL - (bytes - 1)) return FALSE;
	if(address >= GSW_RING3_LIMIT || address + bytes > GSW_RING3_LIMIT) return FALSE;
	span = (address & 0xFFF) + bytes;
	range->page = address >> 12;
	range->pages = (span + 0xFFF) >> 12;
	if(range->pages > 2) return FALSE;
	if(_LinPageLock(range->page, range->pages, 0) == 0) return FALSE;
	memset(page_table, 0, sizeof(page_table));
	_CopyPageTable(range->page, range->pages, page_table, 0);
	required = GSW_PTE_PRESENT | GSW_PTE_USER;
	if(writable) required |= GSW_PTE_WRITE;
	for(i = 0; i < range->pages; i++)
	{
		if((page_table[i] & required) != required)
		{
			_LinPageUnLock(range->page, range->pages, 0);
			return FALSE;
		}
	}
	range->locked = TRUE;
	return TRUE;
}

static void gsw_dd_range_unlock(GSWLockedRange *range)
{
	if(range != NULL && range->locked)
	{
		_LinPageUnLock(range->page, range->pages, 0);
		range->locked = FALSE;
	}
}

static BOOL gsw_dd_sizes(
	const struct DIOCParams *params,
	DWORD *input_bytes,
	DWORD *output_bytes
)
{
	if(params == NULL || input_bytes == NULL || output_bytes == NULL) return FALSE;
	switch(params->dwIoControlCode)
	{
		case GSW_DD_IOCTL_QUERY:
			*input_bytes = 0; *output_bytes = sizeof(GSWDDQuery); break;
		case GSW_DD_IOCTL_REGISTER:
			*input_bytes = sizeof(GSWDDRegister); *output_bytes = sizeof(GSWDDRegister); break;
		case GSW_DD_IOCTL_UNREGISTER:
			*input_bytes = sizeof(GSWDDUnregister); *output_bytes = sizeof(DWORD); break;
		case GSW_DD_IOCTL_FILL:
			*input_bytes = sizeof(GSWDDFill); *output_bytes = sizeof(DWORD); break;
		case GSW_DD_IOCTL_BLT:
			*input_bytes = sizeof(GSWDDBlt); *output_bytes = sizeof(DWORD); break;
		case GSW_DD_IOCTL_PRESENT:
			*input_bytes = sizeof(GSWDDPresent); *output_bytes = sizeof(DWORD); break;
		case GSW_DD_IOCTL_DIRTY:
			*input_bytes = sizeof(GSWDDDirty); *output_bytes = sizeof(DWORD); break;
		default:
			return FALSE;
	}
	return params->cbInBuffer == *input_bytes && params->cbOutBuffer == *output_bytes &&
		(*input_bytes == 0 || params->lpInBuffer != 0) &&
		(*output_bytes == 0 || params->lpOutBuffer != 0);
}

BOOL GSW_DD_ioctl(struct DIOCParams *params, DWORD *result)
{
	GSWDDPayload input;
	GSWDDPayload output;
	GSWLockedRange input_range;
	GSWLockedRange output_range;
	DWORD input_bytes;
	DWORD output_bytes;
	DWORD success = 0;

	if(result == NULL || params == NULL) return FALSE;
	*result = 1;
	if(!gsw_dd_sizes(params, &input_bytes, &output_bytes))
		return params->dwIoControlCode >= GSW_DD_IOCTL_QUERY &&
			params->dwIoControlCode <= GSW_DD_IOCTL_DIRTY;
	if(!gsw_dd_range_lock(params->lpInBuffer, input_bytes, FALSE, &input_range)) return TRUE;
	if(!gsw_dd_range_lock(params->lpOutBuffer, output_bytes, TRUE, &output_range))
	{
		gsw_dd_range_unlock(&input_range);
		return TRUE;
	}

	memset(&input, 0, sizeof(input));
	memset(&output, 0, sizeof(output));
	if(input_bytes != 0) memcpy(&input, (void *)params->lpInBuffer, input_bytes);

	switch(params->dwIoControlCode)
	{
		case GSW_DD_IOCTL_QUERY:
			output.query.cb = sizeof(output.query);
			output.query.version = GSW_DD_ABI_VERSION;
			output.query.capabilities = GSW_DD_CAP_SURFACE_IDS |
				GSW_DD_CAP_FILL | GSW_DD_CAP_BLT | GSW_DD_CAP_PRESENT |
				GSW_DD_CAP_DIRTY_RECT | GSW_DD_CAP_DST_COLOR_KEY;
			output.query.framebuffer_linear = (DWORD)GSW_transport_framebuffer();
			output.query.framebuffer_bytes = GSW_transport_framebuffer_bytes();
			if(!GSW_transport_ready() ||
				(GSW_transport_capabilities() & GSW_VGA_CAP_SURFACE_IDS) == 0)
			{
				output.query.capabilities = 0;
				output.query.framebuffer_linear = 0;
				output.query.framebuffer_bytes = 0;
			}
			break;
		case GSW_DD_IOCTL_REGISTER:
			output.registration = input.registration;
			output.registration.surface_id = 0;
			if(output.registration.cb == sizeof(output.registration))
				GSW_transport_surface_register(&output.registration, params->tagProcess);
			break;
		case GSW_DD_IOCTL_UNREGISTER:
			if(input.unregister_request.cb == sizeof(input.unregister_request))
				success = GSW_transport_surface_unregister(input.unregister_request.surface_id);
			output.success = success;
			break;
		case GSW_DD_IOCTL_FILL:
			if(input.fill.cb == sizeof(input.fill)) success = GSW_transport_surface_fill(&input.fill);
			output.success = success;
			break;
		case GSW_DD_IOCTL_BLT:
			if(input.blt.cb == sizeof(input.blt)) success = GSW_transport_surface_blt(&input.blt);
			output.success = success;
			break;
		case GSW_DD_IOCTL_PRESENT:
			if(input.present.cb == sizeof(input.present))
				success = GSW_transport_surface_present(input.present.surface_id);
			output.success = success;
			break;
		case GSW_DD_IOCTL_DIRTY:
			if(input.dirty.cb == sizeof(input.dirty)) success = GSW_transport_surface_dirty(&input.dirty);
			output.success = success;
			break;
	}

	memcpy((void *)params->lpOutBuffer, &output, output_bytes);
	gsw_dd_range_unlock(&output_range);
	gsw_dd_range_unlock(&input_range);
	*result = 0;
	return TRUE;
}
