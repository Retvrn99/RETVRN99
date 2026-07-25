/* SPDX-License-Identifier: GPL-3.0-only */

#include "gswgfx.h"

typedef HRESULT (WINAPI *GSW_D3D_DDRAW_CREATE_EX)(GUID *, LPVOID *, REFIID, IUnknown *);

typedef struct GSW_D3D_ENUM {
	BOOL hal;
	BOOL hel;
	BOOL legacy3;
} GSW_D3D_ENUM;

typedef struct GSW_D3D_MODE_ENUM {
	GSW_MODE_LIST *modes;
	DWORD paths;
} GSW_D3D_MODE_ENUM;

typedef struct GSW_D3D_VERTEX {
	float x;
	float y;
	float z;
	float rhw;
	DWORD color;
} GSW_D3D_VERTEX;

typedef struct GSW_D3D_FRAME {
	HMODULE library;
	LPDIRECTDRAW7 draw;
	LPDIRECTDRAWSURFACE7 primary;
	LPDIRECTDRAWSURFACE7 back;
	LPDIRECT3D7 d3d;
	LPDIRECT3DDEVICE7 device;
	LPDIRECT3D3 d3d3;
	LPDIRECT3DDEVICE3 device3;
	LPDIRECT3DVIEWPORT3 viewport3;
	LPDIRECTDRAWSURFACE4 back4;
	GSW_SESSION *session;
	GSW_MODE mode;
	DWORD recoveries;
	BOOL exclusive;
	BOOL mode_set;
	BOOL use_d3d3;
} GSW_D3D_FRAME;

static HRESULT CALLBACK gsw_d3d7_enum(char *description, char *name, LPD3DDEVICEDESC7 device, LPVOID value)
{
	GSW_D3D_ENUM *context = (GSW_D3D_ENUM *)value;
	(void)description; (void)name;
	if(device == NULL || context == NULL) return D3DENUMRET_CANCEL;
	if(device->dwDevCaps & D3DDEVCAPS_HWRASTERIZATION) context->hal = TRUE;
	else context->hel = TRUE;
	return D3DENUMRET_OK;
}

static HRESULT CALLBACK gsw_d3d3_enum(LPGUID guid, LPSTR description, LPSTR name,
	LPD3DDEVICEDESC hal, LPD3DDEVICEDESC hel, LPVOID value)
{
	GSW_D3D_ENUM *context = (GSW_D3D_ENUM *)value;
	(void)guid; (void)description; (void)name;
	if(context == NULL) return D3DENUMRET_CANCEL;
	if(hal != NULL && hal->dwFlags != 0) context->hal = TRUE;
	if(hel != NULL && hel->dwFlags != 0) context->hel = TRUE;
	context->legacy3 = TRUE;
	return D3DENUMRET_OK;
}

static HRESULT CALLBACK gsw_d3d_mode_enum(LPDDSURFACEDESC2 description, LPVOID value)
{
	GSW_D3D_MODE_ENUM *context = (GSW_D3D_MODE_ENUM *)value;
	DWORD bpp;
	if(description == NULL || context == NULL) return DDENUMRET_CANCEL;
	bpp = description->ddpfPixelFormat.dwRGBBitCount;
	if(bpp == 16 || bpp == 32)
	{
		if((context->paths & 1) && !gsw_mode_add(context->modes, context->modes->count,
		   description->dwWidth, description->dwHeight, bpp, description->dwRefreshRate, 1))
			return DDENUMRET_CANCEL;
		if((context->paths & 2) && !gsw_mode_add(context->modes, context->modes->count,
		   description->dwWidth, description->dwHeight, bpp, description->dwRefreshRate, 2))
			return DDENUMRET_CANCEL;
	}
	return DDENUMRET_OK;
}

static HRESULT gsw_d3d_open_draw(GSW_D3D_FRAME *frame)
{
	FARPROC address;
	union { FARPROC raw; GSW_D3D_DDRAW_CREATE_EX typed; } create;
	frame->library = LoadLibraryA("DDRAW.DLL");
	if(frame->library == NULL) return (HRESULT)(0x80070000UL | GetLastError());
	address = GetProcAddress(frame->library, "DirectDrawCreateEx");
	if(address == NULL) return E_NOINTERFACE;
	create.raw = address;
	return create.typed(NULL, (LPVOID *)&frame->draw, &IID_IDirectDraw7, NULL);
}

static void gsw_d3d_close(GSW_D3D_FRAME *frame)
{
	if(frame->device3 != NULL && frame->viewport3 != NULL)
		IDirect3DDevice3_DeleteViewport(frame->device3, frame->viewport3);
	if(frame->viewport3 != NULL) IDirect3DViewport3_Release(frame->viewport3);
	if(frame->device3 != NULL) IDirect3DDevice3_Release(frame->device3);
	if(frame->d3d3 != NULL) IDirect3D3_Release(frame->d3d3);
	if(frame->back4 != NULL) IDirectDrawSurface4_Release(frame->back4);
	if(frame->device != NULL) IDirect3DDevice7_Release(frame->device);
	if(frame->d3d != NULL) IDirect3D7_Release(frame->d3d);
	if(frame->back != NULL) IDirectDrawSurface7_Release(frame->back);
	if(frame->primary != NULL) IDirectDrawSurface7_Release(frame->primary);
	if(frame->draw != NULL)
	{
		if(frame->mode_set) IDirectDraw7_RestoreDisplayMode(frame->draw);
		if(frame->exclusive) IDirectDraw7_SetCooperativeLevel(frame->draw, frame->session->window, DDSCL_NORMAL);
		IDirectDraw7_Release(frame->draw);
	}
	if(frame->library != NULL) FreeLibrary(frame->library);
	gsw_zero(frame, sizeof(*frame));
}

static BOOL gsw_d3d_enumerate(GSW_SESSION *session, GSW_ADAPTER *adapter)
{
	GSW_D3D_FRAME frame;
	GSW_D3D_ENUM devices;
	GSW_D3D_MODE_ENUM modes;
	LPDIRECT3D3 legacy = NULL;
	HRESULT result;
	gsw_zero(&frame, sizeof(frame));
	gsw_zero(&devices, sizeof(devices));
	gsw_zero(&adapter->modes, sizeof(adapter->modes));
	frame.session = session;
	result = gsw_d3d_open_draw(&frame);
	if(result != DD_OK) goto done;
	result = IDirectDraw7_QueryInterface(frame.draw, &IID_IDirect3D7, (LPVOID *)&frame.d3d);
	if(result == DD_OK && frame.d3d != NULL)
		result = IDirect3D7_EnumDevices(frame.d3d, gsw_d3d7_enum, &devices);
	else
	{
		result = IDirectDraw7_QueryInterface(frame.draw, &IID_IDirect3D3, (LPVOID *)&legacy);
		if(result == DD_OK && legacy != NULL)
			result = IDirect3D3_EnumDevices(legacy, gsw_d3d3_enum, &devices);
	}
	if(result != DD_OK || (!devices.hal && !devices.hel)) goto done;
	modes.modes = &adapter->modes;
	modes.paths = (devices.hal ? 1UL : 0UL) | (devices.hel ? 2UL : 0UL);
	result = IDirectDraw7_EnumDisplayModes(frame.draw, 0, NULL, &modes, gsw_d3d_mode_enum);
done:
	if(legacy != NULL) IDirect3D3_Release(legacy);
	adapter->available = result == DD_OK && adapter->modes.count != 0 && !adapter->modes.overflow;
	gsw_d3d_close(&frame);
	return adapter->available;
}

static BOOL gsw_d3d_setup(GSW_D3D_FRAME *frame, GSW_SESSION *session, const GSW_MODE *mode, DWORD *api_code)
{
	DDSURFACEDESC2 description;
	DDSCAPS2 caps;
	D3DVIEWPORT7 viewport;
	D3DVIEWPORT2 viewport3;
	const GUID *device_guid = mode->flags == 1 ? &IID_IDirect3DHALDevice : &IID_IDirect3DRGBDevice;
	HRESULT result;
	frame->session = session;
	frame->mode = *mode;
	result = gsw_d3d_open_draw(frame);
	if(result != DD_OK) goto fail;
	result = IDirectDraw7_SetCooperativeLevel(frame->draw, session->window,
		DDSCL_EXCLUSIVE | DDSCL_FULLSCREEN | DDSCL_ALLOWREBOOT);
	if(result != DD_OK) goto fail;
	frame->exclusive = TRUE;
	result = IDirectDraw7_SetDisplayMode(frame->draw, mode->width, mode->height, mode->bpp, mode->hz, 0);
	if(result != DD_OK) goto fail;
	frame->mode_set = TRUE;
	gsw_zero(&description, sizeof(description));
	description.dwSize = sizeof(description);
	result = IDirectDraw7_GetDisplayMode(frame->draw, &description);
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
	description.ddsCaps.dwCaps = DDSCAPS_PRIMARYSURFACE | DDSCAPS_FLIP |
		DDSCAPS_COMPLEX | DDSCAPS_3DDEVICE;
	description.dwBackBufferCount = 1;
	result = IDirectDraw7_CreateSurface(frame->draw, &description, &frame->primary, NULL);
	if(result != DD_OK) goto fail;
	gsw_zero(&caps, sizeof(caps)); caps.dwCaps = DDSCAPS_BACKBUFFER;
	result = IDirectDrawSurface7_GetAttachedSurface(frame->primary, &caps, &frame->back);
	if(result != DD_OK) goto fail;
	result = IDirectDraw7_QueryInterface(frame->draw, &IID_IDirect3D7, (LPVOID *)&frame->d3d);
	if(result == DD_OK && frame->d3d != NULL)
	{
		result = IDirect3D7_CreateDevice(frame->d3d, device_guid, frame->back, &frame->device);
		if(result != D3D_OK) goto fail;
		gsw_zero(&viewport, sizeof(viewport));
		viewport.dwWidth = mode->width; viewport.dwHeight = mode->height;
		viewport.dvMinZ = 0.0f; viewport.dvMaxZ = 1.0f;
		result = IDirect3DDevice7_SetViewport(frame->device, &viewport);
		if(result != D3D_OK) goto fail;
		IDirect3DDevice7_SetRenderState(frame->device, D3DRENDERSTATE_LIGHTING, FALSE);
	}
	else
	{
		frame->use_d3d3 = TRUE;
		result = IDirectDraw7_QueryInterface(frame->draw, &IID_IDirect3D3, (LPVOID *)&frame->d3d3);
		if(result != DD_OK) goto fail;
		result = IDirectDrawSurface7_QueryInterface(frame->back, &IID_IDirectDrawSurface4, (LPVOID *)&frame->back4);
		if(result != DD_OK) goto fail;
		result = IDirect3D3_CreateDevice(frame->d3d3, device_guid, frame->back4, &frame->device3, NULL);
		if(result != D3D_OK) goto fail;
		result = IDirect3D3_CreateViewport(frame->d3d3, &frame->viewport3, NULL);
		if(result != D3D_OK) goto fail;
		result = IDirect3DDevice3_AddViewport(frame->device3, frame->viewport3);
		if(result != D3D_OK) goto fail;
		gsw_zero(&viewport3, sizeof(viewport3));
		viewport3.dwSize = sizeof(viewport3);
		viewport3.dwWidth = mode->width; viewport3.dwHeight = mode->height;
		viewport3.dvClipX = -1.0f; viewport3.dvClipY = 1.0f;
		viewport3.dvClipWidth = 2.0f; viewport3.dvClipHeight = 2.0f;
		viewport3.dvMinZ = 0.0f; viewport3.dvMaxZ = 1.0f;
		result = IDirect3DViewport3_SetViewport2(frame->viewport3, &viewport3);
		if(result != D3D_OK) goto fail;
		result = IDirect3DDevice3_SetCurrentViewport(frame->device3, frame->viewport3);
		if(result != D3D_OK) goto fail;
		IDirect3DDevice3_SetRenderState(frame->device3, D3DRENDERSTATE_LIGHTING, FALSE);
	}
	if(api_code != NULL) *api_code = D3D_OK;
	return TRUE;
fail:
	if(api_code != NULL) *api_code = (DWORD)result;
	return FALSE;
}

static DWORD gsw_d3d_surface_crc(GSW_D3D_FRAME *frame)
{
	DDSURFACEDESC2 locked;
	DWORD crc = 0;
	DWORD bytes = (frame->mode.bpp + 7) / 8;
	gsw_zero(&locked, sizeof(locked)); locked.dwSize = sizeof(locked);
	if(IDirectDrawSurface7_Lock(frame->back, NULL, &locked, DDLOCK_WAIT | DDLOCK_READONLY, NULL) == DD_OK)
	{
		crc = gsw_pattern_crc((const BYTE *)locked.lpSurface, (DWORD)locked.lPitch,
			frame->mode.width, frame->mode.height, bytes * 8);
		IDirectDrawSurface7_Unlock(frame->back, NULL);
	}
	return crc;
}

static HRESULT gsw_d3d_present_once(GSW_D3D_FRAME *frame, DWORD index, DWORD *crc32)
{
	GSW_D3D_VERTEX vertices[3];
	HRESULT result;
	DWORD alternate = index & 1;
	vertices[0].x = frame->mode.width * 0.5f; vertices[0].y = frame->mode.height * 0.12f;
	vertices[1].x = frame->mode.width * 0.12f; vertices[1].y = frame->mode.height * 0.86f;
	vertices[2].x = frame->mode.width * 0.88f; vertices[2].y = frame->mode.height * 0.86f;
	vertices[0].z = vertices[1].z = vertices[2].z = 0.5f;
	vertices[0].rhw = vertices[1].rhw = vertices[2].rhw = 1.0f;
	vertices[0].color = alternate ? 0xFF00FFFFUL : 0xFFFF0000UL;
	vertices[1].color = alternate ? 0xFFFF00FFUL : 0xFF00FF00UL;
	vertices[2].color = alternate ? 0xFFFFFF00UL : 0xFF0000FFUL;
	if(frame->use_d3d3)
	{
		result = IDirect3DViewport3_Clear2(frame->viewport3, 0, NULL, D3DCLEAR_TARGET,
			alternate ? 0x00101820UL : 0x00201008UL, 1.0f, 0);
		if(result != D3D_OK) return result;
		result = IDirect3DDevice3_BeginScene(frame->device3);
		if(result != D3D_OK) return result;
		result = IDirect3DDevice3_DrawPrimitive(frame->device3, D3DPT_TRIANGLELIST,
			D3DFVF_XYZRHW | D3DFVF_DIFFUSE, vertices, 3, 0);
		if(IDirect3DDevice3_EndScene(frame->device3) != D3D_OK && result == D3D_OK) result = E_FAIL;
	}
	else
	{
		result = IDirect3DDevice7_Clear(frame->device, 0, NULL, D3DCLEAR_TARGET,
			alternate ? 0x00101820UL : 0x00201008UL, 1.0f, 0);
		if(result != D3D_OK) return result;
		result = IDirect3DDevice7_BeginScene(frame->device);
		if(result != D3D_OK) return result;
		result = IDirect3DDevice7_DrawPrimitive(frame->device, D3DPT_TRIANGLELIST,
			D3DFVF_XYZRHW | D3DFVF_DIFFUSE, vertices, 3, 0);
		if(IDirect3DDevice7_EndScene(frame->device) != D3D_OK && result == D3D_OK) result = E_FAIL;
	}
	if(result != D3D_OK) return result;
	if(crc32 != NULL) *crc32 = gsw_d3d_surface_crc(frame);
	return IDirectDrawSurface7_Flip(frame->primary, NULL, DDFLIP_WAIT);
}

static BOOL gsw_d3d_frame(void *value, DWORD index, DWORD *crc32)
{
	GSW_D3D_FRAME *frame = (GSW_D3D_FRAME *)value;
	DWORD attempt;
	for(attempt = 0; attempt <= GSW_SURFACE_RECOVERY_MAX; attempt++)
	{
		HRESULT result = gsw_d3d_present_once(frame, index, crc32);
		if(result == D3D_OK) return TRUE;
		if(result != DDERR_SURFACELOST || attempt == GSW_SURFACE_RECOVERY_MAX) return FALSE;
		frame->recoveries++;
		if(IDirectDrawSurface7_Restore(frame->primary) != DD_OK ||
		   IDirectDrawSurface7_Restore(frame->back) != DD_OK) return FALSE;
	}
	return FALSE;
}

static BOOL gsw_d3d_run(GSW_SESSION *session, GSW_ADAPTER *adapter, const GSW_MODE *mode, GSW_ROW *row, BOOL measured)
{
	GSW_D3D_FRAME frame;
	BOOL success;
	(void)adapter;
	gsw_zero(&frame, sizeof(frame)); gsw_zero(row, sizeof(*row));
	gsw_text_copy(row->adapter, sizeof(row->adapter), "DIRECT3D");
	gsw_text_copy(row->path, sizeof(row->path), mode->flags == 1 ? "HAL" : "HEL");
	row->mode = *mode;
	if(!gsw_d3d_setup(&frame, session, mode, &row->api_code))
	{
		row->status = GSW_STATUS_FAIL; gsw_text_copy(row->detail, sizeof(row->detail), "D3D7_SETUP");
		gsw_d3d_close(&frame); return FALSE;
	}
	if(measured) success = gsw_benchmark(session, gsw_d3d_frame, &frame, &row->metrics);
	else
	{
		success = gsw_d3d_frame(&frame, 0, &row->metrics.crc32);
		row->metrics.frames = success ? 1 : 0;
		row->metrics.status = success ? GSW_STATUS_PASS : GSW_STATUS_FAIL;
	}
	row->status = row->metrics.status;
	gsw_text_copy(row->detail, sizeof(row->detail), frame.recoveries ? "SURFACE_RECOVERED" :
		(row->metrics.sample_cap ? "SAMPLE_CAP" : frame.use_d3d3 ?
		(measured ? "D3D3_TRIANGLE_BENCHMARK" : "D3D3_TRIANGLE_SMOKE") :
		(measured ? "D3D7_TRIANGLE_BENCHMARK" : "D3D7_TRIANGLE_SMOKE")));
	gsw_d3d_close(&frame);
	return success;
}

static BOOL gsw_d3d_smoke(GSW_SESSION *session, GSW_ADAPTER *adapter, const GSW_MODE *mode, GSW_ROW *row)
{ return gsw_d3d_run(session, adapter, mode, row, FALSE); }
static BOOL gsw_d3d_benchmark(GSW_SESSION *session, GSW_ADAPTER *adapter, const GSW_MODE *mode, GSW_ROW *row)
{ return gsw_d3d_run(session, adapter, mode, row, TRUE); }
static BOOL gsw_d3d_restore(GSW_SESSION *session, GSW_ADAPTER *adapter)
{ (void)adapter; return gsw_restore_desktop(session); }

BOOL gsw_d3d_adapter(GSW_ADAPTER *adapter)
{
	if(adapter == NULL) return FALSE;
	gsw_zero(adapter, sizeof(*adapter));
	adapter->name = "DIRECT3D";
	adapter->enumerate = gsw_d3d_enumerate;
	adapter->smoke = gsw_d3d_smoke;
	adapter->benchmark = gsw_d3d_benchmark;
	adapter->restore = gsw_d3d_restore;
	return TRUE;
}
