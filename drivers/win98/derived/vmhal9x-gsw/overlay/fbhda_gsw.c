/* SPDX-License-Identifier: GPL-3.0-only */
#include "fbhda.c"
#include "gsw_ddraw_abi.h"

static BOOL gsw_ioctl(DWORD code, const void *input, DWORD input_bytes, void *output, DWORD output_bytes)
{
	if(hda_vxd == INVALID_HANDLE_VALUE)
	{
		return FALSE;
	}
	return DeviceIoControl(hda_vxd, code, (LPVOID)input, input_bytes,
		output, output_bytes, NULL, NULL);
}

BOOL __stdcall GSWDD_query(GSWDDQuery *query)
{
	return query != NULL && gsw_ioctl(GSW_DD_IOCTL_QUERY, NULL, 0, query, sizeof(*query));
}

BOOL __stdcall GSWDD_register_surface(GSWDDRegister *request)
{
	GSWDDRegister output;
	if(request == NULL || !gsw_ioctl(GSW_DD_IOCTL_REGISTER, request, sizeof(*request), &output, sizeof(output)))
		return FALSE;
	*request = output;
	return output.surface_id != 0;
}

#define GSW_SIMPLE_WRAPPER(name, type, code) \
	BOOL __stdcall GSWDD_##name(const type *request) { \
		DWORD result = 0; \
		return request != NULL && gsw_ioctl(code, request, sizeof(*request), &result, sizeof(result)) && result != 0; \
	}

GSW_SIMPLE_WRAPPER(unregister_surface, GSWDDUnregister, GSW_DD_IOCTL_UNREGISTER)
GSW_SIMPLE_WRAPPER(fill, GSWDDFill, GSW_DD_IOCTL_FILL)
GSW_SIMPLE_WRAPPER(blt, GSWDDBlt, GSW_DD_IOCTL_BLT)
GSW_SIMPLE_WRAPPER(present, GSWDDPresent, GSW_DD_IOCTL_PRESENT)
GSW_SIMPLE_WRAPPER(dirty, GSWDDDirty, GSW_DD_IOCTL_DIRTY)
