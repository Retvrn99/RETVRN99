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

// The framebuffer identity is only comparable once the display driver has
// published it. The first load runs before that, with vramLinear and vramSize
// still zero, and requiring them to match the VxD there refused the bridge
// permanently: DirectDraw's own initialisation takes that first path, so every
// later surface registration was rejected before it was attempted. An
// unpublished value is treated as "not yet known" rather than as a mismatch;
// every other term of the check is unchanged.
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
	if(!gsw.query(&gsw.info)) return FALSE;
	if(gsw.info.cb != sizeof(gsw.info) ||
		gsw.info.version != GSW_DD_ABI_VERSION ||
		gsw.info.capabilities != (GSW_DD_CAP_SURFACE_IDS | GSW_DD_CAP_FILL |
			GSW_DD_CAP_BLT | GSW_DD_CAP_PRESENT | GSW_DD_CAP_DIRTY_RECT |
			GSW_DD_CAP_DST_COLOR_KEY) ||
		(hal->vramLinear != 0 && gsw.info.framebuffer_linear != hal->vramLinear) ||
		(hal->vramSize != 0 && gsw.info.framebuffer_bytes != hal->vramSize))
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

// gswdd32.dll loads below 2 GiB, which on this platform means per process,
// while this driver's own state sits in the shared arena where every process
// sees the same copy. A module handle and entry points cached by whichever
// process loaded first are therefore meaningless to the next one, and calling
// them jumps somewhere unmapped. Re-resolve them whenever the cached module is
// not the one this process has.
static BOOL gsw_interface_current(VMDAHAL_t *hal)
{
	HMODULE current = GetModuleHandleA("gswdd32.dll");
	if(gsw.module != NULL && current == gsw.module) return TRUE;
	gsw.module = NULL;
	gsw.query = NULL;
	gsw.register_surface = NULL;
	gsw.unregister_surface = NULL;
	gsw.fill = NULL;
	gsw.blt = NULL;
	gsw.present = NULL;
	gsw.dirty = NULL;
	return GSWDD_load(hal);
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
	if(!gsw_interface_current(hal))
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
	GSWDD_trace(GSW_HAL_TRACE_REGISTER);
	if(!gsw.register_surface(&request) || request.surface_id == 0)
	{
		return 0;
	}
	GSWDD_trace(GSW_HAL_TRACE_REGISTER_DONE);
	surface->dwReserved1 = request.surface_id;
	return request.surface_id;
}

// Destroy is the one entry that reaches the bridge without a surface lookup
// first, so it is the one that can be the first call a process makes and find
// another process's pointers cached. Re-resolve here too. Every other entry is
// preceded by GSWDD_surface on the same surface in the same call, but each still
// refuses a null pointer rather than calling it: the pointers are shared state
// with per-process validity, so "resolved" is never assumed.
BOOL GSWDD_unregister(VMDAHAL_t *hal, DWORD surface_id)
{
	GSWDDUnregister request;
	if(surface_id == 0 || !gsw_interface_current(hal)) return FALSE;
	request.cb = sizeof(request);
	request.surface_id = surface_id;
	return gsw.unregister_surface(&request);
}

BOOL GSWDD_fill(const GSWDDFill *request)
{
	return gsw.fill == NULL ? FALSE : gsw.fill(request);
}

BOOL GSWDD_blt(const GSWDDBlt *request)
{
	return gsw.blt == NULL ? FALSE : gsw.blt(request);
}

BOOL GSWDD_present(DWORD surface_id)
{
	GSWDDPresent request;
	if(gsw.present == NULL) return FALSE;
	request.cb = sizeof(request);
	request.surface_id = surface_id;
	return gsw.present(&request);
}

BOOL GSWDD_dirty(const GSWDDDirty *request)
{
	return gsw.dirty == NULL ? FALSE : gsw.dirty(request);
}

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

static void gsw_out8(WORD port, BYTE value)
{
	__asm__ __volatile__("outb %0, %1" : : "a"(value), "Nd"(port));
}

static BYTE gsw_in8(WORD port)
{
	BYTE value;
	__asm__ __volatile__("inb %1, %0" : "=a"(value) : "Nd"(port));
	return value;
}

void GSWDD_trace(BYTE label)
{
	static int enabled = -1;
	DWORD poll;
	if(enabled < 0)
		enabled = GetFileAttributesA(GSW_HAL_TRACE_MARKER) != 0xFFFFFFFFUL ? 1 : 0;
	if(enabled == 0) return;
	gsw_out8(0xE4, 29);
	gsw_out8(0xE5, label);
	gsw_out8(0xE4, 31);
	gsw_out8(0xE5, 0);
	gsw_out8(0xE6, 8);
	for(poll = 0; poll < 2000; poll++)
	{
		gsw_out8(0xE4, 31);
		if(gsw_in8(0xE5) != 0) return;
	}
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
