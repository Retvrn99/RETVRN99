/* SPDX-License-Identifier: GPL-3.0-only */

#include "gswgfx.h"

typedef HRESULT (WINAPI *GSW_DDRAW_CREATE_EX)(GUID *, LPVOID *, REFIID, IUnknown *);
typedef HRESULT (WINAPI *GSW_DDRAW_CREATE)(GUID *, LPDIRECTDRAW *, IUnknown *);

typedef struct GSW_DDRAW_STATE {
	HMODULE library;
	LPDIRECTDRAW7 draw7;
	LPDIRECTDRAW4 draw4;
	LPDIRECTDRAWSURFACE7 primary7;
	LPDIRECTDRAWSURFACE7 back7;
	LPDIRECTDRAWSURFACE4 primary4;
	LPDIRECTDRAWSURFACE4 back4;
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
	HRESULT result = E_NOINTERFACE;
	BOOL force4 = state->session != NULL && state->session->options.ddraw4;
	state->library = LoadLibraryA("DDRAW.DLL");
	if(state->library == NULL) return (HRESULT)(0x80070000UL | GetLastError());
	gsw_trace(state->session, GSW_TRACE_DDRAW_LIBRARY);
	address = GetProcAddress(state->library, "DirectDrawCreateEx");
	if(address != NULL && !force4)
	{
		union { FARPROC raw; GSW_DDRAW_CREATE_EX typed; } create;
		create.raw = address;
		gsw_trace(state->session, GSW_TRACE_DDRAW_CREATE_EX);
		result = create.typed(NULL, (LPVOID *)&state->draw7, &IID_IDirectDraw7, NULL);
		gsw_trace(state->session, GSW_TRACE_DDRAW_CREATE_EX_DONE);
		if(result == DD_OK && state->draw7 != NULL) return result;
		state->draw7 = NULL;
	}
	address = GetProcAddress(state->library, "DirectDrawCreate");
	if(address != NULL)
	{
		union { FARPROC raw; GSW_DDRAW_CREATE typed; } create;
		LPDIRECTDRAW draw1 = NULL;
		HRESULT result;
		create.raw = address;
		gsw_trace(state->session, GSW_TRACE_DDRAW_CREATE);
		result = create.typed(NULL, &draw1, NULL);
		gsw_trace(state->session, GSW_TRACE_DDRAW_CREATE_DONE);
		if(result == DD_OK && draw1 != NULL)
		{
			if(!force4)
				result = IDirectDraw_QueryInterface(draw1, &IID_IDirectDraw7, (LPVOID *)&state->draw7);
			if(force4 || result != DD_OK || state->draw7 == NULL)
			{
				state->draw7 = NULL;
				result = IDirectDraw_QueryInterface(draw1, &IID_IDirectDraw4, (LPVOID *)&state->draw4);
			}
			IDirectDraw_Release(draw1);
		}
		return result;
	}
	return result;
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
	if(state->back7 != NULL) IDirectDrawSurface7_Release(state->back7);
	if(state->primary7 != NULL) IDirectDrawSurface7_Release(state->primary7);
	if(state->back4 != NULL) IDirectDrawSurface4_Release(state->back4);
	if(state->primary4 != NULL) IDirectDrawSurface4_Release(state->primary4);
	if(state->draw7 != NULL)
	{
		if(state->mode_set) IDirectDraw7_RestoreDisplayMode(state->draw7);
		if(state->exclusive) IDirectDraw7_SetCooperativeLevel(state->draw7, state->session->window, DDSCL_NORMAL);
		IDirectDraw7_Release(state->draw7);
	}
	if(state->draw4 != NULL)
	{
		if(state->mode_set) IDirectDraw4_RestoreDisplayMode(state->draw4);
		if(state->exclusive) IDirectDraw4_SetCooperativeLevel(state->draw4, state->session->window, DDSCL_NORMAL);
		IDirectDraw4_Release(state->draw4);
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
	gsw_trace(session, GSW_TRACE_DDRAW_ENTER);
	result = gsw_ddraw_open(&state);
	if(result == DD_OK)
	{
		enumeration.modes = &adapter->modes;
		gsw_trace(session, GSW_TRACE_DDRAW_ENUM);
		if(state.draw7 != NULL)
			result = IDirectDraw7_EnumDisplayModes(state.draw7, 0, NULL, &enumeration, gsw_ddraw_enum_callback);
		else result = IDirectDraw4_EnumDisplayModes(state.draw4, 0, NULL, &enumeration, gsw_ddraw_enum_callback);
		gsw_trace(session, GSW_TRACE_DDRAW_ENUM_DONE);
	}
	adapter->available = result == DD_OK && adapter->modes.count != 0 && !adapter->modes.overflow;
	gsw_ddraw_close(&state);
	gsw_trace(session, GSW_TRACE_DDRAW_CLOSED);
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
	gsw_trace(session, GSW_TRACE_DDRAW_SETUP);
	result = gsw_ddraw_open(state);
	if(result != DD_OK) goto fail;
	if(state->draw7 != NULL)
		result = IDirectDraw7_SetCooperativeLevel(state->draw7, session->window,
			DDSCL_EXCLUSIVE | DDSCL_FULLSCREEN | DDSCL_ALLOWREBOOT);
	else result = IDirectDraw4_SetCooperativeLevel(state->draw4, session->window,
		DDSCL_EXCLUSIVE | DDSCL_FULLSCREEN | DDSCL_ALLOWREBOOT);
	gsw_trace(session, GSW_TRACE_DDRAW_COOPERATIVE);
	if(result != DD_OK) goto fail;
	state->exclusive = TRUE;
	if(state->draw7 != NULL)
		result = IDirectDraw7_SetDisplayMode(state->draw7, mode->width, mode->height, mode->bpp, mode->hz, 0);
	else result = IDirectDraw4_SetDisplayMode(state->draw4, mode->width, mode->height, mode->bpp, mode->hz, 0);
	gsw_trace(session, GSW_TRACE_DDRAW_DISPLAY_MODE);
	if(result != DD_OK) goto fail;
	state->mode_set = TRUE;
	gsw_zero(&description, sizeof(description));
	description.dwSize = sizeof(description);
	if(state->draw7 != NULL) result = IDirectDraw7_GetDisplayMode(state->draw7, &description);
	else result = IDirectDraw4_GetDisplayMode(state->draw4, &description);
	gsw_trace(session, GSW_TRACE_DDRAW_GET_MODE);
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
	if(state->draw7 != NULL)
		result = IDirectDraw7_CreateSurface(state->draw7, &description, &state->primary7, NULL);
	else result = IDirectDraw4_CreateSurface(state->draw4, &description, &state->primary4, NULL);
	gsw_trace(session, GSW_TRACE_DDRAW_PRIMARY);
	if(result != DD_OK) goto fail;
	gsw_zero(&caps, sizeof(caps));
	caps.dwCaps = DDSCAPS_BACKBUFFER;
	if(state->draw7 != NULL)
		result = IDirectDrawSurface7_GetAttachedSurface(state->primary7, &caps, &state->back7);
	else result = IDirectDrawSurface4_GetAttachedSurface(state->primary4, &caps, &state->back4);
	gsw_trace(session, GSW_TRACE_DDRAW_ATTACHED);
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
		if(state->draw7 != NULL)
			result = IDirectDraw7_CreatePalette(state->draw7, DDPCAPS_8BIT | DDPCAPS_ALLOW256,
				entries, &state->palette, NULL);
		else result = IDirectDraw4_CreatePalette(state->draw4, DDPCAPS_8BIT | DDPCAPS_ALLOW256,
			entries, &state->palette, NULL);
		if(result != DD_OK) goto fail;
		if(state->draw7 != NULL) result = IDirectDrawSurface7_SetPalette(state->primary7, state->palette);
		else result = IDirectDrawSurface4_SetPalette(state->primary4, state->palette);
		gsw_trace(session, GSW_TRACE_DDRAW_PALETTE);
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
	gsw_trace(session, GSW_TRACE_DDRAW_SETUP_DONE);
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
	const GSW_SESSION *traced = frame == 0 ? state->session : NULL;
	gsw_zero(&locked, sizeof(locked));
	locked.dwSize = sizeof(locked);
	gsw_trace(traced, GSW_TRACE_DDRAW_LOCK);
	if(state->draw7 != NULL)
		result = IDirectDrawSurface7_Lock(state->back7, NULL, &locked, DDLOCK_WAIT, NULL);
	else result = IDirectDrawSurface4_Lock(state->back4, NULL, &locked, DDLOCK_WAIT, NULL);
	gsw_trace(traced, GSW_TRACE_DDRAW_COPIED);
	if(result != DD_OK) return result;
	if(locked.lpSurface == NULL || locked.lPitch == 0 ||
	   (locked.lPitch > 0 && (DWORD)locked.lPitch < row_bytes))
	{
		if(state->draw7 != NULL) IDirectDrawSurface7_Unlock(state->back7, NULL);
		else IDirectDrawSurface4_Unlock(state->back4, NULL);
		return DDERR_INVALIDPARAMS;
	}
	for(y = 0; y < state->mode.height; y++)
		gsw_copy((BYTE *)locked.lpSurface + (LONG)y * locked.lPitch,
			state->patterns[pattern] + y * state->pitch, row_bytes);
	if(state->draw7 != NULL) result = IDirectDrawSurface7_Unlock(state->back7, NULL);
	else result = IDirectDrawSurface4_Unlock(state->back4, NULL);
	gsw_trace(traced, GSW_TRACE_DDRAW_UNLOCK);
	if(result != DD_OK) return result;
	if(state->draw7 != NULL) result = IDirectDrawSurface7_Flip(state->primary7, NULL, DDFLIP_WAIT);
	else result = IDirectDrawSurface4_Flip(state->primary4, NULL, DDFLIP_WAIT);
	gsw_trace(traced, GSW_TRACE_DDRAW_FLIP);
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
		if(state->draw7 != NULL)
		{
			if(IDirectDrawSurface7_Restore(state->primary7) != DD_OK ||
			   IDirectDrawSurface7_Restore(state->back7) != DD_OK) return FALSE;
		}
		else if(IDirectDrawSurface4_Restore(state->primary4) != DD_OK ||
		   IDirectDrawSurface4_Restore(state->back4) != DD_OK) return FALSE;
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
	gsw_trace(session, GSW_TRACE_DDRAW_FRAME);
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
