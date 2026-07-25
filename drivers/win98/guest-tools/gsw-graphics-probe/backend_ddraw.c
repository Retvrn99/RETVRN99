/* SPDX-License-Identifier: GPL-3.0-only */

#include "gswgfx.h"

typedef HRESULT (WINAPI *GSW_DDRAW_CREATE_EX)(GUID *, LPVOID *, REFIID, IUnknown *);
typedef HRESULT (WINAPI *GSW_DDRAW_CREATE)(GUID *, LPDIRECTDRAW *, IUnknown *);

typedef struct GSW_DDRAW_STATE {
	HMODULE library;
	LPDIRECTDRAW7 draw;
	LPDIRECTDRAWSURFACE7 primary;
	LPDIRECTDRAWSURFACE7 back;
	LPDIRECTDRAWPALETTE palette;
	GSW_SESSION *session;
	GSW_MODE mode;
	BYTE *patterns[2];
	DWORD pitch;
	DWORD crc[2];
	DWORD recoveries;
	BOOL exclusive;
	BOOL mode_set;
} GSW_DDRAW_STATE;

typedef struct GSW_DDRAW_ENUM {
	GSW_MODE_LIST *modes;
} GSW_DDRAW_ENUM;

static HRESULT gsw_ddraw_open(GSW_DDRAW_STATE *state)
{
	FARPROC address;
	state->library = LoadLibraryA("DDRAW.DLL");
	if(state->library == NULL) return (HRESULT)(0x80070000UL | GetLastError());
	address = GetProcAddress(state->library, "DirectDrawCreateEx");
	if(address != NULL)
	{
		union { FARPROC raw; GSW_DDRAW_CREATE_EX typed; } create;
		create.raw = address;
		return create.typed(NULL, (LPVOID *)&state->draw, &IID_IDirectDraw7, NULL);
	}
	address = GetProcAddress(state->library, "DirectDrawCreate");
	if(address != NULL)
	{
		union { FARPROC raw; GSW_DDRAW_CREATE typed; } create;
		LPDIRECTDRAW draw1 = NULL;
		HRESULT result;
		create.raw = address;
		result = create.typed(NULL, &draw1, NULL);
		if(result == DD_OK && draw1 != NULL)
		{
			result = IDirectDraw_QueryInterface(draw1, &IID_IDirectDraw7, (LPVOID *)&state->draw);
			IDirectDraw_Release(draw1);
		}
		return result;
	}
	return E_NOINTERFACE;
}

static HRESULT CALLBACK gsw_ddraw_enum_callback(LPDDSURFACEDESC2 description, LPVOID value)
{
	GSW_DDRAW_ENUM *context = (GSW_DDRAW_ENUM *)value;
	DWORD bpp;
	if(context == NULL || description == NULL) return DDENUMRET_CANCEL;
	bpp = description->ddpfPixelFormat.dwRGBBitCount;
	if(bpp == 8 || bpp == 15 || bpp == 16 || bpp == 24 || bpp == 32)
		if(!gsw_mode_add(context->modes, context->modes->count, description->dwWidth,
		   description->dwHeight, bpp, description->dwRefreshRate, 0))
			return DDENUMRET_CANCEL;
	return DDENUMRET_OK;
}

static void gsw_ddraw_close(GSW_DDRAW_STATE *state)
{
	if(state->palette != NULL) IDirectDrawPalette_Release(state->palette);
	if(state->back != NULL) IDirectDrawSurface7_Release(state->back);
	if(state->primary != NULL) IDirectDrawSurface7_Release(state->primary);
	if(state->draw != NULL)
	{
		if(state->mode_set) IDirectDraw7_RestoreDisplayMode(state->draw);
		if(state->exclusive) IDirectDraw7_SetCooperativeLevel(state->draw, state->session->window, DDSCL_NORMAL);
		IDirectDraw7_Release(state->draw);
	}
	if(state->library != NULL) FreeLibrary(state->library);
	gsw_pattern_release(state->patterns[0]);
	gsw_pattern_release(state->patterns[1]);
	gsw_zero(state, sizeof(*state));
}

static BOOL gsw_ddraw_enumerate(GSW_SESSION *session, GSW_ADAPTER *adapter)
{
	GSW_DDRAW_STATE state;
	GSW_DDRAW_ENUM enumeration;
	HRESULT result;
	gsw_zero(&state, sizeof(state));
	state.session = session;
	gsw_zero(&adapter->modes, sizeof(adapter->modes));
	result = gsw_ddraw_open(&state);
	if(result == DD_OK)
	{
		enumeration.modes = &adapter->modes;
		result = IDirectDraw7_EnumDisplayModes(state.draw, 0, NULL, &enumeration, gsw_ddraw_enum_callback);
	}
	adapter->available = result == DD_OK && adapter->modes.count != 0 && !adapter->modes.overflow;
	gsw_ddraw_close(&state);
	return adapter->available;
}

static BOOL gsw_ddraw_setup(GSW_DDRAW_STATE *state, GSW_SESSION *session, const GSW_MODE *mode, DWORD *api_code)
{
	DDSURFACEDESC2 description;
	DDSCAPS2 caps;
	HRESULT result;
	DWORD second_pitch;
	state->session = session;
	state->mode = *mode;
	result = gsw_ddraw_open(state);
	if(result != DD_OK) goto fail;
	result = IDirectDraw7_SetCooperativeLevel(state->draw, session->window,
		DDSCL_EXCLUSIVE | DDSCL_FULLSCREEN | DDSCL_ALLOWREBOOT);
	if(result != DD_OK) goto fail;
	state->exclusive = TRUE;
	result = IDirectDraw7_SetDisplayMode(state->draw, mode->width, mode->height, mode->bpp, mode->hz, 0);
	if(result != DD_OK) goto fail;
	state->mode_set = TRUE;
	gsw_zero(&description, sizeof(description));
	description.dwSize = sizeof(description);
	result = IDirectDraw7_GetDisplayMode(state->draw, &description);
	if(result != DD_OK) goto fail;
	if(description.dwWidth != mode->width || description.dwHeight != mode->height ||
	   description.ddpfPixelFormat.dwRGBBitCount != mode->bpp ||
	   (mode->hz != 0 && description.dwRefreshRate != 0 && description.dwRefreshRate != mode->hz))
	{
		result = DDERR_INVALIDMODE;
		goto fail;
	}
	gsw_zero(&description, sizeof(description));
	description.dwSize = sizeof(description);
	description.dwFlags = DDSD_CAPS | DDSD_BACKBUFFERCOUNT;
	description.ddsCaps.dwCaps = DDSCAPS_PRIMARYSURFACE | DDSCAPS_FLIP | DDSCAPS_COMPLEX;
	description.dwBackBufferCount = 1;
	result = IDirectDraw7_CreateSurface(state->draw, &description, &state->primary, NULL);
	if(result != DD_OK) goto fail;
	gsw_zero(&caps, sizeof(caps));
	caps.dwCaps = DDSCAPS_BACKBUFFER;
	result = IDirectDrawSurface7_GetAttachedSurface(state->primary, &caps, &state->back);
	if(result != DD_OK) goto fail;
	if(mode->bpp == 8)
	{
		PALETTEENTRY entries[256];
		DWORD index;
		for(index = 0; index < 256; index++)
		{
			entries[index].peRed = (BYTE)(((index >> 5) & 7) * 255 / 7);
			entries[index].peGreen = (BYTE)(((index >> 2) & 7) * 255 / 7);
			entries[index].peBlue = (BYTE)((index & 3) * 255 / 3);
			entries[index].peFlags = 0;
		}
		result = IDirectDraw7_CreatePalette(state->draw, DDPCAPS_8BIT | DDPCAPS_ALLOW256,
			entries, &state->palette, NULL);
		if(result != DD_OK) goto fail;
		result = IDirectDrawSurface7_SetPalette(state->primary, state->palette);
		if(result != DD_OK) goto fail;
	}
	if(!gsw_pattern_allocate(mode->width, mode->height, mode->bpp, &state->patterns[0], &state->pitch) ||
	   !gsw_pattern_allocate(mode->width, mode->height, mode->bpp, &state->patterns[1], &second_pitch) ||
	   second_pitch != state->pitch ||
	   !gsw_pattern_render(state->patterns[0], state->pitch, mode->width, mode->height, mode->bpp, 0) ||
	   !gsw_pattern_render(state->patterns[1], state->pitch, mode->width, mode->height, mode->bpp, 1))
	{
		result = DDERR_OUTOFMEMORY;
		goto fail;
	}
	state->crc[0] = gsw_pattern_crc(state->patterns[0], state->pitch, mode->width, mode->height, mode->bpp);
	state->crc[1] = gsw_pattern_crc(state->patterns[1], state->pitch, mode->width, mode->height, mode->bpp);
	if(api_code != NULL) *api_code = DD_OK;
	return TRUE;
fail:
	if(api_code != NULL) *api_code = (DWORD)result;
	return FALSE;
}

static HRESULT gsw_ddraw_present_once(GSW_DDRAW_STATE *state, DWORD frame, DWORD *crc32)
{
	DDSURFACEDESC2 locked;
	HRESULT result;
	DWORD pattern = frame & 1;
	DWORD y;
	DWORD row_bytes = state->mode.width * ((state->mode.bpp + 7) / 8);
	gsw_zero(&locked, sizeof(locked));
	locked.dwSize = sizeof(locked);
	result = IDirectDrawSurface7_Lock(state->back, NULL, &locked, DDLOCK_WAIT, NULL);
	if(result != DD_OK) return result;
	if(locked.lpSurface == NULL || locked.lPitch == 0 ||
	   (locked.lPitch > 0 && (DWORD)locked.lPitch < row_bytes))
	{
		IDirectDrawSurface7_Unlock(state->back, NULL);
		return DDERR_INVALIDPARAMS;
	}
	for(y = 0; y < state->mode.height; y++)
		gsw_copy((BYTE *)locked.lpSurface + (LONG)y * locked.lPitch,
			state->patterns[pattern] + y * state->pitch, row_bytes);
	result = IDirectDrawSurface7_Unlock(state->back, NULL);
	if(result != DD_OK) return result;
	result = IDirectDrawSurface7_Flip(state->primary, NULL, DDFLIP_WAIT);
	if(crc32 != NULL) *crc32 = state->crc[pattern];
	return result;
}

static BOOL gsw_ddraw_frame(void *value, DWORD frame, DWORD *crc32)
{
	GSW_DDRAW_STATE *state = (GSW_DDRAW_STATE *)value;
	DWORD attempt;
	for(attempt = 0; attempt <= GSW_SURFACE_RECOVERY_MAX; attempt++)
	{
		HRESULT result = gsw_ddraw_present_once(state, frame, crc32);
		if(result == DD_OK) return TRUE;
		if(result != DDERR_SURFACELOST || attempt == GSW_SURFACE_RECOVERY_MAX) return FALSE;
		state->recoveries++;
		if(IDirectDrawSurface7_Restore(state->primary) != DD_OK ||
		   IDirectDrawSurface7_Restore(state->back) != DD_OK) return FALSE;
	}
	return FALSE;
}

static BOOL gsw_ddraw_run(GSW_SESSION *session, GSW_ADAPTER *adapter, const GSW_MODE *mode, GSW_ROW *row, BOOL measured)
{
	GSW_DDRAW_STATE state;
	BOOL success;
	(void)adapter;
	gsw_zero(&state, sizeof(state));
	gsw_zero(row, sizeof(*row));
	gsw_text_copy(row->adapter, sizeof(row->adapter), "DIRECTDRAW");
	gsw_text_copy(row->path, sizeof(row->path), "FLIP");
	row->mode = *mode;
	if(!gsw_ddraw_setup(&state, session, mode, &row->api_code))
	{
		row->status = GSW_STATUS_FAIL;
		gsw_text_copy(row->detail, sizeof(row->detail), "SETUP");
		gsw_ddraw_close(&state);
		return FALSE;
	}
	if(measured) success = gsw_benchmark(session, gsw_ddraw_frame, &state, &row->metrics);
	else
	{
		success = gsw_ddraw_frame(&state, 0, &row->metrics.crc32);
		row->metrics.frames = success ? 1 : 0;
		row->metrics.status = success ? GSW_STATUS_PASS : GSW_STATUS_FAIL;
	}
	row->status = row->metrics.status;
	gsw_text_copy(row->detail, sizeof(row->detail), state.recoveries != 0 ? "SURFACE_RECOVERED" :
		(row->metrics.sample_cap ? "SAMPLE_CAP" : (measured ? "BENCHMARK" : "SMOKE")));
	gsw_ddraw_close(&state);
	return success;
}

static BOOL gsw_ddraw_smoke(GSW_SESSION *session, GSW_ADAPTER *adapter, const GSW_MODE *mode, GSW_ROW *row)
{
	return gsw_ddraw_run(session, adapter, mode, row, FALSE);
}

static BOOL gsw_ddraw_benchmark(GSW_SESSION *session, GSW_ADAPTER *adapter, const GSW_MODE *mode, GSW_ROW *row)
{
	return gsw_ddraw_run(session, adapter, mode, row, TRUE);
}

static BOOL gsw_ddraw_restore(GSW_SESSION *session, GSW_ADAPTER *adapter)
{
	(void)adapter;
	return gsw_restore_desktop(session);
}

BOOL gsw_ddraw_adapter(GSW_ADAPTER *adapter)
{
	if(adapter == NULL) return FALSE;
	gsw_zero(adapter, sizeof(*adapter));
	adapter->name = "DIRECTDRAW";
	adapter->enumerate = gsw_ddraw_enumerate;
	adapter->smoke = gsw_ddraw_smoke;
	adapter->benchmark = gsw_ddraw_benchmark;
	adapter->restore = gsw_ddraw_restore;
	return TRUE;
}
