/* SPDX-License-Identifier: GPL-3.0-only */
#include <windows.h>
#include <stdint.h>
#include "gsw_backend.h"

typedef BOOL (__stdcall *GSWDDQueryFn)(GSWDDQuery *);
typedef BOOL (__stdcall *GSWDDRegisterFn)(GSWDDRegister *);
typedef BOOL (__stdcall *GSWDDUnregisterFn)(const GSWDDUnregister *);
typedef BOOL (__stdcall *GSWDDFillFn)(const GSWDDFill *);
typedef BOOL (__stdcall *GSWDDBltFn)(const GSWDDBlt *);
typedef BOOL (__stdcall *GSWDDPresentFn)(const GSWDDPresent *);
typedef BOOL (__stdcall *GSWDDDirtyFn)(const GSWDDDirty *);

typedef struct GSWDDInterface {
	HMODULE module;
	GSWDDQueryFn query;
	GSWDDRegisterFn register_surface;
	GSWDDUnregisterFn unregister_surface;
	GSWDDFillFn fill;
	GSWDDBltFn blt;
	GSWDDPresentFn present;
	GSWDDDirtyFn dirty;
	GSWDDQuery info;
} GSWDDInterface;

typedef struct GSWDDLockRecord {
	DWORD surface_id;
	GSWDDDirty dirty;
	BOOL read_only;
} GSWDDLockRecord;

static GSWDDInterface gsw;
static GSWDDLockRecord locks[256];

#define GSW_LOAD(name, type) \
	gsw.name = (type)GetProcAddress(gsw.module, "GSWDD_" #name); \
	if(gsw.name == NULL) return FALSE

BOOL GSWDD_load(VMDAHAL_t *hal)
{
	if(hal == NULL || hal->pFBHDA32 == NULL)
	{
		return FALSE;
	}
	gsw.module = LoadLibraryA("gswdd32.dll");
	if(gsw.module == NULL)
	{
		return FALSE;
	}
	GSW_LOAD(query, GSWDDQueryFn);
	GSW_LOAD(register_surface, GSWDDRegisterFn);
	GSW_LOAD(unregister_surface, GSWDDUnregisterFn);
	GSW_LOAD(fill, GSWDDFillFn);
	GSW_LOAD(blt, GSWDDBltFn);
	GSW_LOAD(present, GSWDDPresentFn);
	GSW_LOAD(dirty, GSWDDDirtyFn);
	gsw.info.cb = sizeof(gsw.info);
	if(!gsw.query(&gsw.info) || gsw.info.cb != sizeof(gsw.info) ||
		gsw.info.version != GSW_DD_ABI_VERSION ||
		gsw.info.capabilities != (GSW_DD_CAP_SURFACE_IDS | GSW_DD_CAP_FILL |
			GSW_DD_CAP_BLT | GSW_DD_CAP_PRESENT | GSW_DD_CAP_DIRTY_RECT |
			GSW_DD_CAP_DST_COLOR_KEY) ||
		gsw.info.framebuffer_linear != hal->vramLinear ||
		gsw.info.framebuffer_bytes != hal->vramSize)
	{
		return FALSE;
	}
	return TRUE;
}

DWORD GSWDD_surface_bpp(VMDAHAL_t *hal, LPDDRAWI_DDRAWSURFACE_LCL surface)
{
	if(surface != NULL && surface->lpGbl != NULL &&
		(surface->dwFlags & DDRAWISURF_HASPIXELFORMAT) != 0 &&
		surface->lpGbl->ddpfSurface.dwRGBBitCount != 0)
	{
		return surface->lpGbl->ddpfSurface.dwRGBBitCount;
	}
	return hal == NULL ? 0 : hal->dwBpp;
}

DWORD GSWDD_surface(VMDAHAL_t *hal, LPDDRAWI_DDRAWSURFACE_LCL surface)
{
	GSWDDRegister request;
	DWORD offset;
	DWORD height;
	DWORD pitch;
	DWORD bytes;
	DWORD bpp;

	if(hal == NULL || surface == NULL || surface->lpGbl == NULL)
	{
		return 0;
	}
	if(surface->dwReserved1 != 0)
	{
		return (DWORD)surface->dwReserved1;
	}
	if(surface->lpGbl->fpVidMem < hal->vramLinear || surface->lpGbl->lPitch <= 0)
	{
		return 0;
	}
	offset = (DWORD)surface->lpGbl->fpVidMem - hal->vramLinear;
	height = surface->lpGbl->wHeight;
	pitch = (DWORD)surface->lpGbl->lPitch;
	if(height == 0 || pitch > 0xFFFFFFFFUL / height)
	{
		return 0;
	}
	bytes = pitch * height;
	if(offset > hal->vramSize || bytes > hal->vramSize - offset)
	{
		return 0;
	}
	bpp = GSWDD_surface_bpp(hal, surface);
	if(bpp != 8 && bpp != 15 && bpp != 16 && bpp != 24 && bpp != 32)
	{
		return 0;
	}
	request.cb = sizeof(request);
	request.offset = offset;
	request.byte_size = bytes;
	request.width = surface->lpGbl->wWidth;
	request.height = height;
	request.pitch = pitch;
	request.bpp = bpp;
	request.flags = (surface->ddsCaps.dwCaps &
		(DDSCAPS_PRIMARYSURFACE | DDSCAPS_FRONTBUFFER | DDSCAPS_BACKBUFFER)) != 0 ?
		GSW_DD_SURFACE_PRESENTABLE : 0;
	request.surface_id = 0;
	if(!gsw.register_surface(&request) || request.surface_id == 0)
	{
		return 0;
	}
	surface->dwReserved1 = request.surface_id;
	return request.surface_id;
}

BOOL GSWDD_unregister(DWORD surface_id)
{
	GSWDDUnregister request;
	if(surface_id == 0) return FALSE;
	request.cb = sizeof(request);
	request.surface_id = surface_id;
	return gsw.unregister_surface(&request);
}

BOOL GSWDD_fill(const GSWDDFill *request) { return gsw.fill(request); }
BOOL GSWDD_blt(const GSWDDBlt *request) { return gsw.blt(request); }

BOOL GSWDD_present(DWORD surface_id)
{
	GSWDDPresent request;
	request.cb = sizeof(request);
	request.surface_id = surface_id;
	return gsw.present(&request);
}

BOOL GSWDD_dirty(const GSWDDDirty *request) { return gsw.dirty(request); }

BOOL GSWDD_rop_supported(DWORD rop3)
{
	switch(rop3)
	{
		case 0x00: case 0x11: case 0x33: case 0x44: case 0x55:
		case 0x66: case 0x88: case 0xBB: case 0xCC: case 0xEE: case 0xFF:
			return TRUE;
	}
	return FALSE;
}

void GSWDD_lock_rect(DWORD surface_id, const RECTL *rect, BOOL read_only)
{
	GSWDDLockRecord *record;
	if(surface_id == 0) return;
	record = &locks[surface_id & 0xFF];
	record->surface_id = surface_id;
	record->read_only = read_only;
	record->dirty.cb = sizeof(record->dirty);
	record->dirty.surface_id = surface_id;
	record->dirty.x = (DWORD)rect->left;
	record->dirty.y = (DWORD)rect->top;
	record->dirty.width = (DWORD)(rect->right - rect->left);
	record->dirty.height = (DWORD)(rect->bottom - rect->top);
}

BOOL GSWDD_unlock_rect(DWORD surface_id, GSWDDDirty *dirty)
{
	GSWDDLockRecord *record;
	if(surface_id == 0 || dirty == NULL) return FALSE;
	record = &locks[surface_id & 0xFF];
	if(record->surface_id != surface_id)
	{
		return FALSE;
	}
	*dirty = record->dirty;
	record->surface_id = 0;
	return !record->read_only;
}
