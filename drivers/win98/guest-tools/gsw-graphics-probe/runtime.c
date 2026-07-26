/* SPDX-License-Identifier: GPL-3.0-only */

#include "gswgfx.h"

DWORD gsw_text_length(const char *text)
{
	DWORD length = 0;
	if(text == NULL) return 0;
	while(text[length] != '\0') length++;
	return length;
}

BOOL gsw_text_equal(const char *left, const char *right)
{
	DWORD index = 0;
	if(left == NULL || right == NULL) return FALSE;
	while(left[index] != '\0' && right[index] != '\0')
	{
		if(left[index] != right[index]) return FALSE;
		index++;
	}
	return left[index] == right[index];
}

BOOL gsw_text_copy(char *destination, DWORD capacity, const char *source)
{
	DWORD index;
	DWORD length = gsw_text_length(source);
	if(destination == NULL || source == NULL || length + 1 > capacity) return FALSE;
	for(index = 0; index <= length; index++) destination[index] = source[index];
	return TRUE;
}

void gsw_zero(void *memory, DWORD bytes)
{
	BYTE *output = (BYTE *)memory;
	DWORD index;
	for(index = 0; index < bytes; index++) output[index] = 0;
}

void gsw_copy(void *destination, const void *source, DWORD bytes)
{
	BYTE *output = (BYTE *)destination;
	const BYTE *input = (const BYTE *)source;
	DWORD index;
	for(index = 0; index < bytes; index++) output[index] = input[index];
}

BOOL gsw_checked_multiply(DWORD left, DWORD right, DWORD *result)
{
	if(result == NULL || (left != 0 && right > 0xFFFFFFFFUL / left)) return FALSE;
	*result = left * right;
	return TRUE;
}

BOOL gsw_timer_initialize(GSW_TIMER *timer)
{
	LARGE_INTEGER frequency;
	LARGE_INTEGER current;
	if(timer == NULL) return FALSE;
	gsw_zero(timer, sizeof(*timer));
	timer->frequency = 1000;
	timer->last = GetTickCount();
	if(QueryPerformanceFrequency(&frequency) && frequency.QuadPart > 0 &&
	   QueryPerformanceCounter(&current) && current.QuadPart >= 0)
	{
		timer->qpc = TRUE;
		timer->frequency = (ULONGLONG)frequency.QuadPart;
		timer->last = (ULONGLONG)current.QuadPart;
	}
	return TRUE;
}

ULONGLONG gsw_timer_now(GSW_TIMER *timer)
{
	LARGE_INTEGER current;
	if(timer == NULL || timer->failed) return timer != NULL ? timer->last : 0;
	if(timer->qpc)
	{
		if(!QueryPerformanceCounter(&current) || current.QuadPart < 0 ||
		   (ULONGLONG)current.QuadPart < timer->last)
		{
			timer->failed = TRUE;
			return timer->last;
		}
		timer->last = (ULONGLONG)current.QuadPart;
		return timer->last;
	}
	{
		DWORD tick = GetTickCount();
		DWORD prior = (DWORD)timer->last;
		timer->last += (DWORD)(tick - prior);
	}
	return timer->last;
}

DWORD gsw_timer_ms(const GSW_TIMER *timer, ULONGLONG ticks)
{
	if(timer == NULL || timer->frequency == 0) return 0;
	return (DWORD)((ticks / timer->frequency) * 1000ULL +
		((ticks % timer->frequency) * 1000ULL) / timer->frequency);
}

DWORD gsw_timer_us(const GSW_TIMER *timer, ULONGLONG ticks)
{
	if(timer == NULL || timer->frequency == 0) return 0;
	if(ticks > 0xFFFFFFFFULL * timer->frequency / 1000000ULL)
		return 0xFFFFFFFFUL;
	return (DWORD)((ticks * 1000000ULL) / timer->frequency);
}

static BOOL gsw_argument(const char *wanted)
{
	const char *command = GetCommandLineA();
	DWORD wanted_length = gsw_text_length(wanted);
	DWORD index = 0;
	while(command != NULL && command[index] != '\0')
	{
		DWORD matched = 0;
		while(command[index] == ' ' || command[index] == '\t') index++;
		if(command[index] == '"')
		{
			index++;
			while(command[index] != '\0' && command[index] != '"') index++;
			if(command[index] == '"') index++;
			continue;
		}
		while(matched < wanted_length && command[index + matched] == wanted[matched])
			matched++;
		if(matched == wanted_length &&
		   (command[index + matched] == '\0' || command[index + matched] == ' ' ||
		    command[index + matched] == '\t')) return TRUE;
		while(command[index] != '\0' && command[index] != ' ' && command[index] != '\t')
			index++;
	}
	return FALSE;
}

BOOL gsw_parse_options(GSW_OPTIONS *options)
{
	if(options == NULL) return FALSE;
	gsw_zero(options, sizeof(*options));
	options->exhaustive = gsw_argument("/exhaustive");
	options->self_test = gsw_argument("/self-test");
	options->host_report = gsw_argument("/host-report");
	options->import_vbe = gsw_argument("/import-vbe");
	options->gdi_only = gsw_argument("/gdi-only");
	options->ddraw_only = gsw_argument("/ddraw-only");
	options->d3d_only = gsw_argument("/d3d-only");
	options->ddraw4 = gsw_argument("/ddraw4");
	options->bounded = gsw_argument("/bounded");
	return TRUE;
}

BOOL gsw_capture_desktop(GSW_DESKTOP *desktop)
{
	HDC dc;
	if(desktop == NULL) return FALSE;
	gsw_zero(desktop, sizeof(*desktop));
	desktop->mode.dmSize = sizeof(desktop->mode);
	if(!EnumDisplaySettingsA(NULL, ENUM_CURRENT_SETTINGS, &desktop->mode)) return FALSE;
	dc = GetDC(NULL);
	if(dc == NULL) return FALSE;
	desktop->metric_width = (DWORD)GetSystemMetrics(SM_CXSCREEN);
	desktop->metric_height = (DWORD)GetSystemMetrics(SM_CYSCREEN);
	desktop->caps_bpp = (DWORD)GetDeviceCaps(dc, BITSPIXEL) *
		(DWORD)GetDeviceCaps(dc, PLANES);
	return ReleaseDC(NULL, dc) != 0;
}

BOOL gsw_restore_desktop(GSW_SESSION *session)
{
	GSW_DESKTOP observed;
	LONG code;
	if(session == NULL) return FALSE;
	code = ChangeDisplaySettingsA(NULL, 0);
	if(code != DISP_CHANGE_SUCCESSFUL || !gsw_capture_desktop(&observed))
		return FALSE;
	return observed.mode.dmPelsWidth == session->original.mode.dmPelsWidth &&
		observed.mode.dmPelsHeight == session->original.mode.dmPelsHeight &&
		observed.mode.dmBitsPerPel == session->original.mode.dmBitsPerPel;
}

HWND gsw_window_create(void)
{
	HWND window = CreateWindowExA(
		WS_EX_TOPMOST, "STATIC", "GSWGFX", WS_POPUP | WS_VISIBLE,
		0, 0, GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN),
		NULL, NULL, GetModuleHandleA(NULL), NULL
	);
	if(window != NULL)
	{
		ShowWindow(window, SW_SHOW);
		UpdateWindow(window);
		SetForegroundWindow(window);
	}
	return window;
}

void gsw_window_pump(void)
{
	MSG message;
	while(PeekMessageA(&message, NULL, 0, 0, PM_REMOVE))
	{
		TranslateMessage(&message);
		DispatchMessageA(&message);
	}
}

BOOL gsw_mode_add(GSW_MODE_LIST *list, DWORD id, DWORD width, DWORD height, DWORD bpp, DWORD hz, DWORD flags)
{
	DWORD index;
	if(list == NULL || width == 0 || height == 0 || bpp == 0 || bpp > 32) return FALSE;
	for(index = 0; index < list->count; index++)
	{
		const GSW_MODE *mode = &list->items[index];
		if(mode->width == width && mode->height == height && mode->bpp == bpp &&
		   mode->hz == hz && mode->flags == flags) return TRUE;
	}
	if(list->count >= GSW_MODE_CAP)
	{
		list->overflow = TRUE;
		return FALSE;
	}
	list->items[list->count].id = id;
	list->items[list->count].width = width;
	list->items[list->count].height = height;
	list->items[list->count].bpp = bpp;
	list->items[list->count].hz = hz;
	list->items[list->count].flags = flags;
	list->count++;
	return TRUE;
}

BOOL gsw_mode_is_canonical(const GSW_MODE *mode)
{
	if(mode == NULL) return FALSE;
	return (mode->width == 320 && (mode->height == 200 || mode->height == 240)) ||
		(mode->width == 640 && mode->height == 480) ||
		(mode->width == 800 && mode->height == 600) ||
		(mode->width == 1024 && mode->height == 768);
}
