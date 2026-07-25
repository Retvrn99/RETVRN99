/* SPDX-License-Identifier: GPL-3.0-only */

#include "gswgfx.h"

typedef struct GSW_DIB_INFO {
	BITMAPINFOHEADER header;
	DWORD extra[256];
} GSW_DIB_INFO;

typedef struct GSW_GDI_FRAME {
	GSW_SESSION *session;
	GSW_MODE mode;
	HDC dc;
	GSW_DIB_INFO info;
	BYTE *patterns[2];
	DWORD pitch;
	DWORD crc[2];
} GSW_GDI_FRAME;

static void gsw_gdi_devmode(const GSW_MODE *mode, DEVMODEA *request)
{
	gsw_zero(request, sizeof(*request));
	request->dmSize = sizeof(*request);
	request->dmFields = DM_PELSWIDTH | DM_PELSHEIGHT | DM_BITSPERPEL;
	request->dmPelsWidth = mode->width;
	request->dmPelsHeight = mode->height;
	request->dmBitsPerPel = mode->bpp;
	if(mode->hz != 0)
	{
		request->dmFields |= DM_DISPLAYFREQUENCY;
		request->dmDisplayFrequency = mode->hz;
	}
}

static BOOL gsw_gdi_enumerate(GSW_SESSION *session, GSW_ADAPTER *adapter)
{
	DWORD index;
	(void)session;
	gsw_zero(&adapter->modes, sizeof(adapter->modes));
	for(index = 0; index < 4096; index++)
	{
		DEVMODEA mode;
		gsw_zero(&mode, sizeof(mode));
		mode.dmSize = sizeof(mode);
		if(!EnumDisplaySettingsA(NULL, index, &mode)) break;
		if(mode.dmBitsPerPel == 8 || mode.dmBitsPerPel == 15 || mode.dmBitsPerPel == 16 ||
		   mode.dmBitsPerPel == 24 || mode.dmBitsPerPel == 32)
			gsw_mode_add(&adapter->modes, index, mode.dmPelsWidth, mode.dmPelsHeight,
				mode.dmBitsPerPel, mode.dmDisplayFrequency, 0);
	}
	adapter->available = adapter->modes.count != 0 && !adapter->modes.overflow;
	return adapter->available;
}

static BOOL gsw_gdi_apply(const GSW_MODE *mode, DWORD *code)
{
	DEVMODEA request;
	DEVMODEA observed;
	LONG result;
	gsw_gdi_devmode(mode, &request);
	result = ChangeDisplaySettingsA(&request, CDS_TEST);
	if(code != NULL) *code = (DWORD)result;
	if(result != DISP_CHANGE_SUCCESSFUL) return FALSE;
	result = ChangeDisplaySettingsA(&request, CDS_FULLSCREEN);
	if(code != NULL) *code = (DWORD)result;
	if(result != DISP_CHANGE_SUCCESSFUL) return FALSE;
	gsw_zero(&observed, sizeof(observed));
	observed.dmSize = sizeof(observed);
	if(!EnumDisplaySettingsA(NULL, ENUM_CURRENT_SETTINGS, &observed)) return FALSE;
	return observed.dmPelsWidth == mode->width && observed.dmPelsHeight == mode->height &&
		observed.dmBitsPerPel == mode->bpp && (mode->hz == 0 || observed.dmDisplayFrequency == mode->hz);
}

static BOOL gsw_gdi_frame(void *value, DWORD frame, DWORD *crc32)
{
	GSW_GDI_FRAME *context = (GSW_GDI_FRAME *)value;
	DWORD pattern = frame & 1;
	int lines = SetDIBitsToDevice(
		context->dc, 0, 0, context->mode.width, context->mode.height,
		0, 0, 0, context->mode.height, context->patterns[pattern],
		(const BITMAPINFO *)&context->info, DIB_RGB_COLORS
	);
	if(crc32 != NULL) *crc32 = context->crc[pattern];
	return lines == (int)context->mode.height;
}

static BOOL gsw_gdi_prepare(GSW_SESSION *session, const GSW_MODE *mode, GSW_GDI_FRAME *frame)
{
	DWORD index;
	gsw_zero(frame, sizeof(*frame));
	frame->session = session;
	frame->mode = *mode;
	if(!gsw_pattern_allocate(mode->width, mode->height, mode->bpp, &frame->patterns[0], &frame->pitch) ||
	   !gsw_pattern_allocate(mode->width, mode->height, mode->bpp, &frame->patterns[1], &index))
		return FALSE;
	if(index != frame->pitch || !gsw_pattern_render(frame->patterns[0], frame->pitch,
	   mode->width, mode->height, mode->bpp, 0) ||
	   !gsw_pattern_render(frame->patterns[1], frame->pitch,
	   mode->width, mode->height, mode->bpp, 1)) return FALSE;
	frame->crc[0] = gsw_pattern_crc(frame->patterns[0], frame->pitch, mode->width, mode->height, mode->bpp);
	frame->crc[1] = gsw_pattern_crc(frame->patterns[1], frame->pitch, mode->width, mode->height, mode->bpp);
	frame->info.header.biSize = sizeof(BITMAPINFOHEADER);
	frame->info.header.biWidth = (LONG)mode->width;
	frame->info.header.biHeight = -(LONG)mode->height;
	frame->info.header.biPlanes = 1;
	frame->info.header.biBitCount = (WORD)(mode->bpp == 15 ? 16 : mode->bpp);
	frame->info.header.biCompression = mode->bpp == 15 || mode->bpp == 16 ? BI_BITFIELDS : BI_RGB;
	if(mode->bpp == 15)
	{
		frame->info.extra[0] = 0x7C00; frame->info.extra[1] = 0x03E0; frame->info.extra[2] = 0x001F;
	}
	else if(mode->bpp == 16)
	{
		frame->info.extra[0] = 0xF800; frame->info.extra[1] = 0x07E0; frame->info.extra[2] = 0x001F;
	}
	else if(mode->bpp == 8)
	{
		RGBQUAD *colors = (RGBQUAD *)frame->info.extra;
		for(index = 0; index < 256; index++)
		{
			colors[index].rgbRed = (BYTE)(((index >> 5) & 7) * 255 / 7);
			colors[index].rgbGreen = (BYTE)(((index >> 2) & 7) * 255 / 7);
			colors[index].rgbBlue = (BYTE)((index & 3) * 255 / 3);
			colors[index].rgbReserved = 0;
		}
	}
	frame->dc = GetDC(session->window);
	return frame->dc != NULL;
}

static void gsw_gdi_release(GSW_GDI_FRAME *frame)
{
	if(frame->dc != NULL) ReleaseDC(frame->session->window, frame->dc);
	gsw_pattern_release(frame->patterns[0]);
	gsw_pattern_release(frame->patterns[1]);
	gsw_zero(frame, sizeof(*frame));
}

static BOOL gsw_gdi_run(GSW_SESSION *session, GSW_ADAPTER *adapter, const GSW_MODE *mode, GSW_ROW *row, BOOL measured)
{
	GSW_GDI_FRAME frame;
	BOOL success;
	(void)adapter;
	gsw_zero(row, sizeof(*row));
	gsw_text_copy(row->adapter, sizeof(row->adapter), "GDI");
	gsw_text_copy(row->path, sizeof(row->path), "DIB");
	row->mode = *mode;
	if(!gsw_gdi_apply(mode, &row->api_code))
	{
		row->status = GSW_STATUS_FAIL;
		gsw_text_copy(row->detail, sizeof(row->detail), "MODE_SET_OR_READBACK");
		return FALSE;
	}
	if(!SetWindowPos(session->window, HWND_TOPMOST, 0, 0, (int)mode->width, (int)mode->height, SWP_SHOWWINDOW) ||
	   !gsw_gdi_prepare(session, mode, &frame))
	{
		row->api_code = GetLastError();
		row->status = GSW_STATUS_FAIL;
		gsw_text_copy(row->detail, sizeof(row->detail), "DIB_PREPARE");
		gsw_gdi_release(&frame);
		return FALSE;
	}
	if(measured) success = gsw_benchmark(session, gsw_gdi_frame, &frame, &row->metrics);
	else
	{
		success = gsw_gdi_frame(&frame, 0, &row->metrics.crc32);
		row->metrics.frames = success ? 1 : 0;
		row->metrics.status = success ? GSW_STATUS_PASS : GSW_STATUS_FAIL;
	}
	row->status = row->metrics.status;
	gsw_text_copy(row->detail, sizeof(row->detail), row->metrics.sample_cap ? "SAMPLE_CAP" :
		(measured ? "BENCHMARK" : "SMOKE"));
	gsw_gdi_release(&frame);
	return success;
}

static BOOL gsw_gdi_smoke(GSW_SESSION *session, GSW_ADAPTER *adapter, const GSW_MODE *mode, GSW_ROW *row)
{
	return gsw_gdi_run(session, adapter, mode, row, FALSE);
}

static BOOL gsw_gdi_benchmark(GSW_SESSION *session, GSW_ADAPTER *adapter, const GSW_MODE *mode, GSW_ROW *row)
{
	return gsw_gdi_run(session, adapter, mode, row, TRUE);
}

static BOOL gsw_gdi_restore(GSW_SESSION *session, GSW_ADAPTER *adapter)
{
	(void)adapter;
	return gsw_restore_desktop(session);
}

BOOL gsw_gdi_adapter(GSW_ADAPTER *adapter)
{
	if(adapter == NULL) return FALSE;
	gsw_zero(adapter, sizeof(*adapter));
	adapter->name = "GDI";
	adapter->enumerate = gsw_gdi_enumerate;
	adapter->smoke = gsw_gdi_smoke;
	adapter->benchmark = gsw_gdi_benchmark;
	adapter->restore = gsw_gdi_restore;
	return TRUE;
}
