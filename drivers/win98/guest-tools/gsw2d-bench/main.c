/* SPDX-License-Identifier: GPL-3.0-only */

#include <windows.h>

#define BENCH_LOG_PATH "C:\\GSW2D-BENCH\\GSW2D.LOG"
#define BENCH_MINIMUM_MS 1500UL
#define BENCH_MAX_ITERATIONS 262144UL
#define BENCH_TEST_WIDTH 8
#define BENCH_TEST_HEIGHT 8
#define BENCH_SOURCE_X 32
#define BENCH_SOURCE_Y 32
#define BENCH_DESTINATION_X 48
#define BENCH_DESTINATION_Y 32
#define BENCH_REFERENCE_SOURCE_X 0
#define BENCH_REFERENCE_DESTINATION_X 16
#define BENCH_PERF_WIDTH 256
#define BENCH_PERF_HEIGHT 192
#define BENCH_PERF_SOURCE_X 32
#define BENCH_PERF_SOURCE_Y 96
#define BENCH_PERF_DESTINATION_X 64
#define BENCH_PERF_DESTINATION_Y 128

static HANDLE bench_log = INVALID_HANDLE_VALUE;
static DWORD bench_failures = 0;

static DWORD bench_text_length(const char *text)
{
	DWORD length = 0;
	if(text == NULL) return 0;
	while(text[length] != '\0') length++;
	return length;
}

static void bench_write_handle(HANDLE handle, const char *text, DWORD bytes)
{
	DWORD written;
	if(handle != NULL && handle != INVALID_HANDLE_VALUE)
		(void)WriteFile(handle, text, bytes, &written, NULL);
}

static void bench_write(const char *text)
{
	DWORD bytes = bench_text_length(text);
	bench_write_handle(GetStdHandle(STD_OUTPUT_HANDLE), text, bytes);
	bench_write_handle(bench_log, text, bytes);
}

static void bench_write_u32(DWORD value)
{
	char digits[10];
	DWORD count = 0;
	if(value == 0)
	{
		bench_write("0");
		return;
	}
	while(value != 0)
	{
		digits[count++] = (char)('0' + value % 10);
		value /= 10;
	}
	while(count != 0)
	{
		char digit = digits[--count];
		bench_write_handle(GetStdHandle(STD_OUTPUT_HANDLE), &digit, 1);
		bench_write_handle(bench_log, &digit, 1);
	}
}

static void bench_write_u64(ULONGLONG value)
{
	char digits[20];
	DWORD count = 0;
	if(value == 0)
	{
		bench_write("0");
		return;
	}
	while(value != 0)
	{
		digits[count++] = (char)('0' + value % 10);
		value /= 10;
	}
	while(count != 0)
	{
		char digit = digits[--count];
		bench_write_handle(GetStdHandle(STD_OUTPUT_HANDLE), &digit, 1);
		bench_write_handle(bench_log, &digit, 1);
	}
}

static void bench_write_hex_byte(BYTE value)
{
	static const char digits[] = "0123456789ABCDEF";
	char output[2];
	output[0] = digits[value >> 4];
	output[1] = digits[value & 15];
	bench_write_handle(GetStdHandle(STD_OUTPUT_HANDLE), output, 2);
	bench_write_handle(bench_log, output, 2);
}

static void bench_line_value(const char *name, DWORD value)
{
	bench_write(name);
	bench_write_u32(value);
	bench_write("\r\n");
}

static COLORREF bench_source_color(int x, int y)
{
	return RGB(
		(BYTE)(0x31 + x * 17 + y * 3),
		(BYTE)(0xA6 + x * 5 + y * 11),
		(BYTE)(0x5C + x * 7 + y * 13)
	);
}

static COLORREF bench_destination_color(int x, int y)
{
	return RGB(
		(BYTE)(0xC3 + x * 9 + y * 5),
		(BYTE)(0x52 + x * 3 + y * 17),
		(BYTE)(0x9D + x * 15 + y * 7)
	);
}

static COLORREF bench_pattern_color(int x, int y)
{
	return RGB(
		(BYTE)(0x27 + x * 23 + y * 7),
		(BYTE)(0x74 + x * 11 + y * 19),
		(BYTE)(0xD1 + x * 5 + y * 29)
	);
}

static BOOL bench_initialize_rectangles(
	HDC screen, HDC reference, int screen_source_x, int screen_destination_x
)
{
	int x;
	int y;
	for(y = 0; y < BENCH_TEST_HEIGHT; y++)
	{
		for(x = 0; x < BENCH_TEST_WIDTH; x++)
		{
			COLORREF source = bench_source_color(x, y);
			COLORREF destination = bench_destination_color(x, y);
			if(!SetPixelV(screen, screen_source_x + x, BENCH_SOURCE_Y + y, source) ||
			   !SetPixelV(screen, screen_destination_x + x, BENCH_DESTINATION_Y + y, destination) ||
			   !SetPixelV(reference, BENCH_REFERENCE_SOURCE_X + x, 0 + y, source) ||
			   !SetPixelV(reference, BENCH_REFERENCE_DESTINATION_X + x, 0 + y, destination))
				return FALSE;
		}
	}
	return TRUE;
}

static HBRUSH bench_create_pattern_brush(HDC compatible)
{
	HDC pattern_dc;
	HBITMAP bitmap;
	HBITMAP old_bitmap;
	HBRUSH brush;
	int x;
	int y;

	pattern_dc = CreateCompatibleDC(compatible);
	if(pattern_dc == NULL) return NULL;
	bitmap = CreateCompatibleBitmap(compatible, 8, 8);
	if(bitmap == NULL)
	{
		DeleteDC(pattern_dc);
		return NULL;
	}
	old_bitmap = (HBITMAP)SelectObject(pattern_dc, bitmap);
	if(old_bitmap == NULL)
	{
		DeleteObject(bitmap);
		DeleteDC(pattern_dc);
		return NULL;
	}
	for(y = 0; y < 8; y++)
		for(x = 0; x < 8; x++)
			if(!SetPixelV(pattern_dc, x, y, bench_pattern_color(x, y)))
			{
				SelectObject(pattern_dc, old_bitmap);
				DeleteObject(bitmap);
				DeleteDC(pattern_dc);
				return NULL;
			}
	SelectObject(pattern_dc, old_bitmap);
	brush = CreatePatternBrush(bitmap);
	DeleteObject(bitmap);
	DeleteDC(pattern_dc);
	return brush;
}

static BOOL bench_compare_rectangles(HDC screen, HDC reference)
{
	int x;
	int y;
	for(y = 0; y < BENCH_TEST_HEIGHT; y++)
	{
		for(x = 0; x < BENCH_TEST_WIDTH; x++)
		{
			COLORREF actual = GetPixel(
				screen, BENCH_DESTINATION_X + x, BENCH_DESTINATION_Y + y
			);
			COLORREF expected = GetPixel(
				reference, BENCH_REFERENCE_DESTINATION_X + x, y
			);
			if(actual == CLR_INVALID || expected == CLR_INVALID || actual != expected)
				return FALSE;
		}
	}
	return TRUE;
}

static BOOL bench_one_rop(HDC screen, HDC reference, HBRUSH brush, BYTE rop)
{
	HGDIOBJ old_screen_brush;
	HGDIOBJ old_reference_brush;
	DWORD operation = (DWORD)rop << 16;
	BOOL screen_ok;
	BOOL reference_ok;
	BOOL equal;

	if(!bench_initialize_rectangles(
		screen, reference, BENCH_SOURCE_X, BENCH_DESTINATION_X
	)) return FALSE;
	old_screen_brush = SelectObject(screen, brush);
	old_reference_brush = SelectObject(reference, brush);
	if(old_screen_brush == NULL || old_reference_brush == NULL) return FALSE;
	reference_ok = BitBlt(
		reference,
		BENCH_REFERENCE_DESTINATION_X, 0,
		BENCH_TEST_WIDTH, BENCH_TEST_HEIGHT,
		reference,
		BENCH_REFERENCE_SOURCE_X, 0,
		operation
	);
	screen_ok = BitBlt(
		screen,
		BENCH_DESTINATION_X, BENCH_DESTINATION_Y,
		BENCH_TEST_WIDTH, BENCH_TEST_HEIGHT,
		screen,
		BENCH_SOURCE_X, BENCH_SOURCE_Y,
		operation
	);
	SelectObject(screen, old_screen_brush);
	SelectObject(reference, old_reference_brush);
	equal = screen_ok && reference_ok && bench_compare_rectangles(screen, reference);
	return equal;
}

static DWORD bench_rop_set(HDC screen, HDC reference, HBRUSH brush, const char *name)
{
	DWORD passed = 0;
	DWORD rop;
	bench_write("GSW2D_BENCH ROP3 ");
	bench_write(name);
	bench_write(" BEGIN\r\n");
	for(rop = 0; rop < 256; rop++)
	{
		if(bench_one_rop(screen, reference, brush, (BYTE)rop))
		{
			passed++;
		}
		else
		{
			bench_write("GSW2D_BENCH ROP3 FAIL brush=");
			bench_write(name);
			bench_write(" rop=");
			bench_write_hex_byte((BYTE)rop);
			bench_write("\r\n");
		}
	}
	bench_write("GSW2D_BENCH ROP3 ");
	bench_write(name);
	bench_write(" passed=");
	bench_write_u32(passed);
	bench_write(" total=256\r\n");
	return passed;
}

static BOOL bench_prepare_performance(HDC screen)
{
	int x;
	int y;
	for(y = 0; y < BENCH_PERF_HEIGHT + 32; y++)
	{
		for(x = 0; x < BENCH_PERF_WIDTH + 32; x++)
		{
			COLORREF color = RGB(
				(BYTE)(x * 3 + y),
				(BYTE)(x + y * 5),
				(BYTE)(x * 7 + y * 11)
			);
			if(!SetPixelV(
				screen, BENCH_PERF_SOURCE_X + x, BENCH_PERF_SOURCE_Y + y, color
			)) return FALSE;
		}
	}
	return TRUE;
}

static BOOL bench_run_copies(HDC screen, DWORD iterations)
{
	DWORD i;
	for(i = 0; i < iterations; i++)
	{
		BOOL ok;
		if((i & 1) == 0)
		{
			ok = BitBlt(
				screen,
				BENCH_PERF_DESTINATION_X, BENCH_PERF_DESTINATION_Y,
				BENCH_PERF_WIDTH, BENCH_PERF_HEIGHT,
				screen,
				BENCH_PERF_SOURCE_X, BENCH_PERF_SOURCE_Y,
				SRCCOPY
			);
		}
		else
		{
			ok = BitBlt(
				screen,
				BENCH_PERF_SOURCE_X, BENCH_PERF_SOURCE_Y,
				BENCH_PERF_WIDTH, BENCH_PERF_HEIGHT,
				screen,
				BENCH_PERF_DESTINATION_X, BENCH_PERF_DESTINATION_Y,
				SRCCOPY
			);
		}
		if(!ok) return FALSE;
	}
	return TRUE;
}

static BOOL bench_performance(HDC screen)
{
	DWORD iterations = 16;
	DWORD elapsed = 0;
	DWORD started;
	ULONGLONG pixels_per_second;
	ULONGLONG pixels_per_iteration = BENCH_PERF_WIDTH * BENCH_PERF_HEIGHT;
	if(!bench_prepare_performance(screen)) return FALSE;
	while(iterations <= BENCH_MAX_ITERATIONS)
	{
		started = GetTickCount();
		if(!bench_run_copies(screen, iterations)) return FALSE;
		elapsed = GetTickCount() - started;
		if(elapsed >= BENCH_MINIMUM_MS || iterations == BENCH_MAX_ITERATIONS) break;
		iterations *= 2;
	}
	if(elapsed == 0) elapsed = 1;
	pixels_per_second =
		(ULONGLONG)iterations * pixels_per_iteration * 1000ULL / elapsed;
	bench_line_value("GSW2D_BENCH PERF iterations=", iterations);
	bench_line_value("GSW2D_BENCH PERF elapsed_ms=", elapsed);
	bench_write("GSW2D_BENCH PERF pixels_per_second=");
	bench_write_u64(pixels_per_second);
	bench_write("\r\n");
	return elapsed >= BENCH_MINIMUM_MS || iterations == BENCH_MAX_ITERATIONS;
}

static HWND bench_create_window(void)
{
	HWND window = CreateWindowExA(
		WS_EX_TOPMOST,
		"STATIC",
		"GSW2D BENCH",
		WS_POPUP | WS_VISIBLE | WS_BORDER,
		24, 24, 576, 432,
		NULL, NULL, GetModuleHandleA(NULL), NULL
	);
	if(window != NULL)
	{
		ShowWindow(window, SW_SHOW);
		UpdateWindow(window);
		Sleep(100);
	}
	return window;
}

static BOOL bench_run(void)
{
	HWND window;
	HDC screen;
	HDC reference;
	HBITMAP reference_bitmap;
	HBITMAP old_reference_bitmap;
	HBRUSH solid_brush;
	HBRUSH pattern_brush;
	DWORD bpp;
	DWORD solid_passed;
	DWORD pattern_passed;
	BOOL performance_ok;
	BOOL result;

	window = bench_create_window();
	if(window == NULL) return FALSE;
	screen = GetDC(window);
	if(screen == NULL)
	{
		DestroyWindow(window);
		return FALSE;
	}
	bpp = (DWORD)GetDeviceCaps(screen, BITSPIXEL) * (DWORD)GetDeviceCaps(screen, PLANES);
	bench_write("GSW2D_BENCH BEGIN bpp=");
	bench_write_u32(bpp);
	bench_write(" width=");
	bench_write_u32((DWORD)GetSystemMetrics(SM_CXSCREEN));
	bench_write(" height=");
	bench_write_u32((DWORD)GetSystemMetrics(SM_CYSCREEN));
	bench_write("\r\n");
	if(bpp != 8 && bpp != 16 && bpp != 24 && bpp != 32)
	{
		bench_write("GSW2D_BENCH FAIL unsupported-bpp\r\n");
		ReleaseDC(window, screen);
		DestroyWindow(window);
		return FALSE;
	}
	reference = CreateCompatibleDC(screen);
	reference_bitmap = CreateCompatibleBitmap(screen, 32, 8);
	if(reference == NULL || reference_bitmap == NULL)
	{
		if(reference_bitmap != NULL) DeleteObject(reference_bitmap);
		if(reference != NULL) DeleteDC(reference);
		ReleaseDC(window, screen);
		DestroyWindow(window);
		return FALSE;
	}
	old_reference_bitmap = (HBITMAP)SelectObject(reference, reference_bitmap);
	if(old_reference_bitmap == NULL)
	{
		DeleteObject(reference_bitmap);
		DeleteDC(reference);
		ReleaseDC(window, screen);
		DestroyWindow(window);
		return FALSE;
	}
	solid_brush = CreateSolidBrush(RGB(0x6D, 0xC2, 0x39));
	pattern_brush = bench_create_pattern_brush(screen);
	if(solid_brush == NULL || pattern_brush == NULL)
	{
		if(solid_brush != NULL) DeleteObject(solid_brush);
		if(pattern_brush != NULL) DeleteObject(pattern_brush);
		SelectObject(reference, old_reference_bitmap);
		DeleteObject(reference_bitmap);
		DeleteDC(reference);
		ReleaseDC(window, screen);
		DestroyWindow(window);
		return FALSE;
	}
	solid_passed = bench_rop_set(screen, reference, solid_brush, "solid");
	pattern_passed = bench_rop_set(screen, reference, pattern_brush, "pattern");
	performance_ok = bench_performance(screen);
	result = solid_passed == 256 && pattern_passed == 256 && performance_ok;
	if(!result) bench_failures++;
	DeleteObject(pattern_brush);
	DeleteObject(solid_brush);
	SelectObject(reference, old_reference_bitmap);
	DeleteObject(reference_bitmap);
	DeleteDC(reference);
	ReleaseDC(window, screen);
	DestroyWindow(window);
	return result;
}

void mainCRTStartup(void)
{
	BOOL success;
	bench_log = CreateFileA(
		BENCH_LOG_PATH,
		GENERIC_WRITE,
		FILE_SHARE_READ,
		NULL,
		CREATE_ALWAYS,
		FILE_ATTRIBUTE_NORMAL,
		NULL
	);
	if(bench_log == INVALID_HANDLE_VALUE)
	{
		bench_write("GSW2D_BENCH FAIL log-open\r\n");
		ExitProcess(1);
	}
	success = bench_run();
	if(success && bench_failures == 0)
		bench_write("GSW2D_BENCH PASS\r\n");
	else
		bench_write("GSW2D_BENCH FAIL\r\n");
	CloseHandle(bench_log);
	bench_log = INVALID_HANDLE_VALUE;
	ExitProcess(success && bench_failures == 0 ? 0 : 1);
}
