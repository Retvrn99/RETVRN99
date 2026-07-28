/* SPDX-License-Identifier: GPL-3.0-only */
#include <windows.h>
#include <ddraw.h>
#include <ddrawi.h>
#include <stdint.h>
#include "ddrawi_ddk.h"
#include "vmdahal32.h"
#include "vmhal9x.h"
#include "gsw_backend.h"

#define IS_GLOBAL_ADDR(ptr) ((DWORD)(ptr) >= 0x80000000UL)

VMDAHAL_t *GetHAL(LPDDRAWI_DIRECTDRAW_GBL lpDD)
{
	if(lpDD != NULL && IS_GLOBAL_ADDR(lpDD->dwReserved3))
		return (VMDAHAL_t *)lpDD->dwReserved3;
	return globalHal;
}

static BOOL gsw_rect(const RECTL *rect, DWORD *x, DWORD *y, DWORD *width, DWORD *height)
{
	if(rect == NULL || rect->left < 0 || rect->top < 0 ||
		rect->right <= rect->left || rect->bottom <= rect->top)
		return FALSE;
	*x = (DWORD)rect->left;
	*y = (DWORD)rect->top;
	*width = (DWORD)(rect->right - rect->left);
	*height = (DWORD)(rect->bottom - rect->top);
	return TRUE;
}

static BOOL gsw_exact_key(const DDCOLORKEY *key, DWORD *value)
{
	if(key == NULL || value == NULL || key->dwColorSpaceLowValue != key->dwColorSpaceHighValue)
		return FALSE;
	*value = key->dwColorSpaceLowValue;
	return TRUE;
}

static BOOL gsw_pixel_format_supported(const DDPIXELFORMAT *format)
{
	DWORD flags;
	if(format == NULL) return FALSE;
	flags = format->dwFlags;
	switch(format->dwRGBBitCount)
	{
		case 8:
			return flags == (DDPF_RGB | DDPF_PALETTEINDEXED8);
		case 15:
			return flags == DDPF_RGB && format->dwRBitMask == 0x7C00 &&
				format->dwGBitMask == 0x03E0 && format->dwBBitMask == 0x001F;
		case 16:
			return flags == DDPF_RGB && format->dwRBitMask == 0xF800 &&
				format->dwGBitMask == 0x07E0 && format->dwBBitMask == 0x001F;
		case 24:
		case 32:
			return flags == DDPF_RGB && format->dwRBitMask == 0x00FF0000UL &&
				format->dwGBitMask == 0x0000FF00UL &&
				format->dwBBitMask == 0x000000FFUL;
	}
	return FALSE;
}

DDENTRY(CanCreateSurface32, LPDDHAL_CANCREATESURFACEDATA, data)
{
	DWORD caps;
	if(data == NULL || data->lpDDSurfaceDesc == NULL)
		return DDHAL_DRIVER_NOTHANDLED;
	caps = data->lpDDSurfaceDesc->ddsCaps.dwCaps;
	if((caps & (DDSCAPS_SYSTEMMEMORY | DDSCAPS_TEXTURE | DDSCAPS_ZBUFFER |
		DDSCAPS_OVERLAY | DDSCAPS_EXECUTEBUFFER)) != 0)
	{
		data->ddRVal = DDERR_UNSUPPORTED;
		return DDHAL_DRIVER_HANDLED;
	}
	if(data->bIsDifferentPixelFormat)
	{
		if(!gsw_pixel_format_supported(&data->lpDDSurfaceDesc->ddpfPixelFormat))
		{
			data->ddRVal = DDERR_INVALIDPIXELFORMAT;
			return DDHAL_DRIVER_HANDLED;
		}
	}
	data->ddRVal = DD_OK;
	return DDHAL_DRIVER_HANDLED;
}

DDENTRY(CreateSurface32, LPDDHAL_CREATESURFACEDATA, data)
{
	if(data == NULL || data->lplpSList == NULL)
		return DDHAL_DRIVER_NOTHANDLED;
	data->ddRVal = DD_OK;
	return DDHAL_DRIVER_NOTHANDLED;
}

DDENTRY(DestroySurface32, LPDDHAL_DESTROYSURFACEDATA, data)
{
	if(data == NULL || data->lpDDSurface == NULL)
		return DDHAL_DRIVER_NOTHANDLED;
	if(data->lpDDSurface->dwReserved1 != 0)
	{
		GSWDD_unregister(GetHAL(data->lpDD), (DWORD)data->lpDDSurface->dwReserved1);
		data->lpDDSurface->dwReserved1 = 0;
	}
	data->ddRVal = DD_OK;
	return DDHAL_DRIVER_HANDLED;
}

DDENTRY(Lock32, LPDDHAL_LOCKDATA, data)
{
	VMDAHAL_t *hal;
	DWORD surface_id;
	RECTL rect;
	GSWDD_trace(GSW_HAL_TRACE_LOCK);
	if(data == NULL || data->lpDDSurface == NULL)
		return DDHAL_DRIVER_NOTHANDLED;
	hal = GetHAL(data->lpDD);
	surface_id = GSWDD_surface(hal, data->lpDDSurface);
	if(surface_id == 0)
	{
		GSWDD_trace(GSW_HAL_TRACE_LOCK_NO_SURFACE);
		return DDHAL_DRIVER_NOTHANDLED;
	}
	if(data->bHasRect)
		 rect = data->rArea;
	else
	{
		rect.left = 0;
		rect.top = 0;
		rect.right = data->lpDDSurface->lpGbl->wWidth;
		rect.bottom = data->lpDDSurface->lpGbl->wHeight;
	}
	if(rect.left < 0 || rect.top < 0 || rect.right <= rect.left || rect.bottom <= rect.top ||
		(DWORD)rect.right > data->lpDDSurface->lpGbl->wWidth ||
		(DWORD)rect.bottom > data->lpDDSurface->lpGbl->wHeight)
	{
		GSWDD_trace(GSW_HAL_TRACE_LOCK_BAD_RECT);
		return DDHAL_DRIVER_NOTHANDLED;
	}
	GSWDD_lock_rect(surface_id, &rect, (data->dwFlags & DDLOCK_READONLY) != 0);
	GSWDD_trace(GSW_HAL_TRACE_LOCK_DONE);
	return DDHAL_DRIVER_NOTHANDLED;
}

DDENTRY(Unlock32, LPDDHAL_UNLOCKDATA, data)
{
	GSWDDDirty dirty;
	DWORD surface_id;
	GSWDD_trace(GSW_HAL_TRACE_UNLOCK);
	if(data == NULL || data->lpDDSurface == NULL)
		return DDHAL_DRIVER_NOTHANDLED;
	surface_id = (DWORD)data->lpDDSurface->dwReserved1;
	if(GSWDD_unlock_rect(surface_id, &dirty) && !GSWDD_dirty(&dirty))
	{
		data->ddRVal = DDERR_GENERIC;
		return DDHAL_DRIVER_HANDLED;
	}
	return DDHAL_DRIVER_NOTHANDLED;
}

DDENTRY(Blt32, LPDDHAL_BLTDATA, data)
{
	VMDAHAL_t *hal;
	GSWDDBlt request;
	GSWDDFill fill;
	DWORD allowed;
	DWORD src_bpp;
	DWORD dst_bpp;
	if(data == NULL || data->lpDDDestSurface == NULL || data->IsClipped)
		return DDHAL_DRIVER_NOTHANDLED;
	hal = GetHAL(data->lpDD);
	request.cb = sizeof(request);
	request.destination_id = GSWDD_surface(hal, data->lpDDDestSurface);
	if(request.destination_id == 0 || !gsw_rect(&data->rDest, &request.destination_x,
		&request.destination_y, &request.destination_width, &request.destination_height))
		return DDHAL_DRIVER_NOTHANDLED;
	allowed = DDBLT_ROP | DDBLT_COLORFILL | DDBLT_KEYSRC | DDBLT_KEYSRCOVERRIDE |
		DDBLT_KEYDEST | DDBLT_KEYDESTOVERRIDE | DDBLT_WAIT | DDBLT_ASYNC | DDBLT_DONOTWAIT;
	if((data->dwFlags & ~allowed) != 0)
		return DDHAL_DRIVER_NOTHANDLED;
	if((data->dwFlags & DDBLT_COLORFILL) != 0)
	{
		if((data->dwFlags & ~(DDBLT_COLORFILL | DDBLT_WAIT | DDBLT_ASYNC | DDBLT_DONOTWAIT)) != 0)
			return DDHAL_DRIVER_NOTHANDLED;
		fill.cb = sizeof(fill);
		fill.surface_id = request.destination_id;
		fill.x = request.destination_x;
		fill.y = request.destination_y;
		fill.width = request.destination_width;
		fill.height = request.destination_height;
		fill.color = data->bltFX.dwFillColor;
		data->ddRVal = GSWDD_fill(&fill) ? DD_OK : DDERR_GENERIC;
		return DDHAL_DRIVER_HANDLED;
	}
	if(data->lpDDSrcSurface == NULL ||
		!gsw_rect(&data->rSrc, &request.source_x, &request.source_y,
			&request.source_width, &request.source_height))
		return DDHAL_DRIVER_NOTHANDLED;
	request.source_id = GSWDD_surface(hal, data->lpDDSrcSurface);
	if(request.source_id == 0)
		return DDHAL_DRIVER_NOTHANDLED;
	src_bpp = GSWDD_surface_bpp(hal, data->lpDDSrcSurface);
	dst_bpp = GSWDD_surface_bpp(hal, data->lpDDDestSurface);
	if(src_bpp != dst_bpp)
		return DDHAL_DRIVER_NOTHANDLED;
	request.flags = 0;
	request.source_color_key = 0;
	request.destination_color_key = 0;
	if((data->dwFlags & DDBLT_KEYSRCOVERRIDE) != 0)
	{
		if(!gsw_exact_key(&data->bltFX.ddckSrcColorkey, &request.source_color_key)) return DDHAL_DRIVER_NOTHANDLED;
		request.flags |= GSW_DD_BLT_SRC_COLOR_KEY;
	}
	else if((data->dwFlags & DDBLT_KEYSRC) != 0)
	{
		if(!gsw_exact_key(&data->lpDDSrcSurface->ddckCKSrcBlt, &request.source_color_key)) return DDHAL_DRIVER_NOTHANDLED;
		request.flags |= GSW_DD_BLT_SRC_COLOR_KEY;
	}
	if((data->dwFlags & DDBLT_KEYDESTOVERRIDE) != 0)
	{
		if(!gsw_exact_key(&data->bltFX.ddckDestColorkey, &request.destination_color_key)) return DDHAL_DRIVER_NOTHANDLED;
		request.flags |= GSW_DD_BLT_DST_COLOR_KEY;
	}
	else if((data->dwFlags & DDBLT_KEYDEST) != 0)
	{
		if(!gsw_exact_key(&data->lpDDDestSurface->ddckCKDestBlt, &request.destination_color_key)) return DDHAL_DRIVER_NOTHANDLED;
		request.flags |= GSW_DD_BLT_DST_COLOR_KEY;
	}
	request.rop3 = (data->dwFlags & DDBLT_ROP) != 0 ? (data->bltFX.dwROP >> 16) & 0xFF : 0xCC;
	if(!GSWDD_rop_supported(request.rop3))
		return DDHAL_DRIVER_NOTHANDLED;
	request.pattern = data->bltFX.dwFillColor;
	data->ddRVal = GSWDD_blt(&request) ? DD_OK : DDERR_GENERIC;
	return DDHAL_DRIVER_HANDLED;
}

DDENTRY(Flip32, LPDDHAL_FLIPDATA, data)
{
	DWORD surface_id;
	GSWDD_trace(GSW_HAL_TRACE_FLIP);
	if(data == NULL || data->lpSurfTarg == NULL)
		return DDHAL_DRIVER_NOTHANDLED;
	surface_id = GSWDD_surface(GetHAL(data->lpDD), data->lpSurfTarg);
	if(surface_id == 0)
		return DDHAL_DRIVER_NOTHANDLED;
	data->ddRVal = GSWDD_present(surface_id) ? DD_OK : DDERR_WASSTILLDRAWING;
	return DDHAL_DRIVER_HANDLED;
}

DDENTRY(GetFlipStatus32, LPDDHAL_GETFLIPSTATUSDATA, data)
{
	data->ddRVal = DD_OK;
	return DDHAL_DRIVER_HANDLED;
}

DDENTRY(GetBltStatus32, LPDDHAL_GETBLTSTATUSDATA, data)
{
	data->ddRVal = DD_OK;
	return DDHAL_DRIVER_HANDLED;
}

DDENTRY(WaitForVerticalBlank32, LPDDHAL_WAITFORVERTICALBLANKDATA, data)
{
	if(data == NULL) return DDHAL_DRIVER_NOTHANDLED;
	data->ddRVal = DDERR_UNSUPPORTED;
	return DDHAL_DRIVER_NOTHANDLED;
}

DDENTRY(SetExclusiveMode32, LPDDHAL_SETEXCLUSIVEMODEDATA, data)
{
	data->ddRVal = DD_OK;
	return DDHAL_DRIVER_NOTHANDLED;
}

DDENTRY(SetMode32, LPDDHAL_SETMODEDATA, data)
{
	data->ddRVal = DD_OK;
	return DDHAL_DRIVER_NOTHANDLED;
}

DDENTRY(SetColorKey32, LPDDHAL_SETCOLORKEYDATA, data)
{
	if(data == NULL || data->lpDDSurface == NULL ||
		data->ckNew.dwColorSpaceLowValue != data->ckNew.dwColorSpaceHighValue ||
		(data->dwFlags & ~(DDCKEY_SRCBLT | DDCKEY_DESTBLT)) != 0 ||
		(data->dwFlags & (DDCKEY_SRCBLT | DDCKEY_DESTBLT)) == 0)
		return DDHAL_DRIVER_NOTHANDLED;
	if((data->dwFlags & DDCKEY_SRCBLT) != 0)
	{
		data->lpDDSurface->ddckCKSrcBlt = data->ckNew;
		data->lpDDSurface->dwFlags |= DDRAWISURF_HASCKEYSRCBLT;
	}
	if((data->dwFlags & DDCKEY_DESTBLT) != 0)
	{
		data->lpDDSurface->ddckCKDestBlt = data->ckNew;
		data->lpDDSurface->dwFlags |= DDRAWISURF_HASCKEYDESTBLT;
	}
	data->ddRVal = DD_OK;
	return DDHAL_DRIVER_HANDLED;
}

DDENTRY(AddAttachedSurface32, LPDDHAL_ADDATTACHEDSURFACEDATA, data)
{
	data->ddRVal = DD_OK;
	return DDHAL_DRIVER_NOTHANDLED;
}

uint64_t GetTimeTMS(void)
{
	LARGE_INTEGER frequency;
	LARGE_INTEGER counter;
	if(!QueryPerformanceFrequency(&frequency) || frequency.QuadPart == 0) return 0;
	QueryPerformanceCounter(&counter);
	return (uint64_t)(counter.QuadPart * 10000 / frequency.QuadPart);
}
