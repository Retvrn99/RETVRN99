/* SPDX-License-Identifier: GPL-3.0-only */

#include "winhack.h"
#include "vmm.h"
#include "vxd_lib.h"
#include "gsw_transport.h"

#define GSW3D_MAX_DIOC_INPUT (sizeof(GSW3DUploadRequest) + GSW3D_STAGING_BYTES)

typedef union GSW3DInput {
	GSW3DContextRequest context;
	GSW3DSubmitRequest submit;
	GSW3DUploadRequest upload;
	GSW3DPresentRequest present;
	GSW3DFencePollRequest fence;
} GSW3DInput;

// Bounds a buffer VWIN32 handed us, without calling the memory manager. This is
// the same shape gsw_ddraw.c arrived at, and for the same reasons: VWIN32 hands
// a VxD the caller's DeviceIoControl buffers as flat linear addresses in the
// shared arena at or above 80000000h, so a ring 3 limit here rejects every legal
// request, and upstream vmdisp9x calls neither _LinPageLock nor _CopyPageTable
// from an IOCTL at all. gsw3d_ioctl_shape has already bounded bytes.
static BOOL gsw3d_ioctl_range_valid(DWORD address, DWORD bytes)
{
	if(bytes == 0) return TRUE;
	if(address == 0 || address > 0xFFFFFFFFUL - (bytes - 1)) return FALSE;
	return TRUE;
}

static BOOL gsw3d_ioctl_shape(
	const struct DIOCParams *params, DWORD *minimum_input, DWORD *output_bytes
)
{
	if(params == NULL || minimum_input == NULL || output_bytes == NULL) return FALSE;
	*output_bytes = sizeof(GSW3DResult);
	switch(params->dwIoControlCode)
	{
		case GSW3D_IOCTL_QUERY:
			*minimum_input = 0;
			*output_bytes = sizeof(GSW3DQuery);
			return params->cbInBuffer == 0 && params->cbOutBuffer == *output_bytes;
		case GSW3D_IOCTL_CONTEXT_CREATE:
		case GSW3D_IOCTL_CONTEXT_DESTROY:
			*minimum_input = sizeof(GSW3DContextRequest);
			break;
		case GSW3D_IOCTL_SUBMIT:
			*minimum_input = sizeof(GSW3DSubmitRequest);
			break;
		case GSW3D_IOCTL_UPLOAD:
			*minimum_input = sizeof(GSW3DUploadRequest);
			break;
		case GSW3D_IOCTL_PRESENT:
			*minimum_input = sizeof(GSW3DPresentRequest);
			break;
		case GSW3D_IOCTL_FENCE_POLL:
			*minimum_input = sizeof(GSW3DFencePollRequest);
			break;
		default:
			return FALSE;
	}
	if(params->cbOutBuffer != *output_bytes || params->cbInBuffer < *minimum_input ||
	   params->cbInBuffer > GSW3D_MAX_DIOC_INPUT)
		return FALSE;
	return TRUE;
}

BOOL GSW3D_ioctl(struct DIOCParams *params, DWORD *result)
{
	GSW3DInput input;
	GSW3DQuery query;
	GSW3DResult output;
	DWORD minimum_input;
	DWORD output_bytes;
	DWORD payload_bytes;
	const BYTE *payload;
	BOOL recognized;

	if(params == NULL || result == NULL) return FALSE;
	*result = 1;
	recognized = params->dwIoControlCode >= GSW3D_IOCTL_FIRST &&
		params->dwIoControlCode <= GSW3D_IOCTL_LAST;
	if(!gsw3d_ioctl_shape(params, &minimum_input, &output_bytes)) return recognized;
	if((params->cbInBuffer != 0 && params->lpInBuffer == 0) ||
	   params->lpOutBuffer == 0) return TRUE;
	if(!gsw3d_ioctl_range_valid(params->lpInBuffer, params->cbInBuffer)) return TRUE;
	if(!gsw3d_ioctl_range_valid(params->lpOutBuffer, output_bytes)) return TRUE;

	memset(&input, 0, sizeof(input));
	memset(&query, 0, sizeof(query));
	memset(&output, 0, sizeof(output));
	if(minimum_input != 0)
		memcpy(&input, (const void *)params->lpInBuffer, minimum_input);
	payload = (const BYTE *)params->lpInBuffer + minimum_input;
	payload_bytes = params->cbInBuffer - minimum_input;

	switch(params->dwIoControlCode)
	{
		case GSW3D_IOCTL_QUERY:
			(void)GSW3D_transport_query(&query);
			memcpy((void *)params->lpOutBuffer, &query, sizeof(query));
			break;
		case GSW3D_IOCTL_CONTEXT_CREATE:
		case GSW3D_IOCTL_CONTEXT_DESTROY:
			if(input.context.cb == sizeof(input.context) &&
			   params->cbInBuffer == sizeof(input.context))
				(void)GSW3D_transport_context(
					params->dwIoControlCode == GSW3D_IOCTL_CONTEXT_CREATE,
					input.context.context_id,
					params->tagProcess,
					&output
				);
			memcpy((void *)params->lpOutBuffer, &output, sizeof(output));
			break;
		case GSW3D_IOCTL_SUBMIT:
			if(input.submit.cb == sizeof(input.submit) &&
			   input.submit.byte_count == payload_bytes && payload_bytes != 0)
				(void)GSW3D_transport_submit(
					input.submit.context_id, payload, payload_bytes, &output
				);
			memcpy((void *)params->lpOutBuffer, &output, sizeof(output));
			break;
		case GSW3D_IOCTL_UPLOAD:
			if(input.upload.cb == sizeof(input.upload) &&
			   input.upload.byte_count == payload_bytes && payload_bytes != 0)
				(void)GSW3D_transport_upload(
					input.upload.resource_id,
					input.upload.destination_offset_low,
					input.upload.destination_offset_high,
					payload,
					payload_bytes,
					&output
				);
			memcpy((void *)params->lpOutBuffer, &output, sizeof(output));
			break;
		case GSW3D_IOCTL_PRESENT:
			if(params->cbInBuffer == sizeof(input.present))
				(void)GSW3D_transport_present(&input.present, &output);
			memcpy((void *)params->lpOutBuffer, &output, sizeof(output));
			break;
		case GSW3D_IOCTL_FENCE_POLL:
			if(params->cbInBuffer == sizeof(input.fence))
				(void)GSW3D_transport_fence_poll(&input.fence, &output);
			memcpy((void *)params->lpOutBuffer, &output, sizeof(output));
			break;
	}

	*result = 0;
	return TRUE;
}
