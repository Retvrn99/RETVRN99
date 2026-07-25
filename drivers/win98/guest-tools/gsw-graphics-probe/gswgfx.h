/* SPDX-License-Identifier: GPL-3.0-only */

#ifndef GSWGFX_H
#define GSWGFX_H

#ifndef WINVER
#define WINVER 0x0400
#endif
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0400
#endif
#ifndef DIRECTDRAW_VERSION
#define DIRECTDRAW_VERSION 0x0700
#endif
#ifndef DIRECT3D_VERSION
#define DIRECT3D_VERSION 0x0700
#endif

#include <windows.h>
#include <ddraw.h>
#include <d3d.h>

#define GSW_SCHEMA "GSWGFX_RESULT_V2"
#define GSW_HEADER "schema\tsequence\trecord\tadapter\tmode\twidth\theight\tbpp\thz\tpath\tstatus\tapi_code\tframes\tduration_ms\tavg_fps_milli\tp50_us\tp95_us\tmax_us\tslow_frames\ttested\tfailed\twarnings\tunavailable\tcrc32\tdetail\r\n"
#define GSW_VBE_PATH "C:\\GSWGFX\\VBE.TMP"
#define GSW_REPORT_CAP (256UL * 1024UL)
#define GSW_SAMPLE_CAP 65536UL
#define GSW_MODE_CAP 512UL
#define GSW_DETAIL_CAP 64UL
#define GSW_WORST_CAP 8UL
#define GSW_PATTERN_BYTES (16UL * 1024UL * 1024UL)
#define GSW_WARMUP_MS 500UL
#define GSW_MEASURE_MS 3000UL
#define GSW_SURFACE_RECOVERY_MAX 2UL

typedef enum GSW_STATUS {
	GSW_STATUS_PASS = 0,
	GSW_STATUS_WARN,
	GSW_STATUS_UNAVAILABLE,
	GSW_STATUS_FAIL
} GSW_STATUS;

typedef struct GSW_MODE {
	DWORD id;
	DWORD width;
	DWORD height;
	DWORD bpp;
	DWORD hz;
	DWORD flags;
} GSW_MODE;

typedef struct GSW_MODE_LIST {
	GSW_MODE items[GSW_MODE_CAP];
	DWORD count;
	BOOL overflow;
} GSW_MODE_LIST;

typedef struct GSW_TIMER {
	BOOL qpc;
	BOOL failed;
	ULONGLONG frequency;
	ULONGLONG last;
} GSW_TIMER;

typedef struct GSW_METRICS {
	DWORD frames;
	DWORD duration_ms;
	DWORD avg_fps_milli;
	DWORD p50_us;
	DWORD p95_us;
	DWORD max_us;
	DWORD slow_frames;
	DWORD crc32;
	BOOL sample_cap;
	GSW_STATUS status;
} GSW_METRICS;

typedef struct GSW_ROW {
	char adapter[16];
	char path[16];
	char detail[GSW_DETAIL_CAP];
	GSW_MODE mode;
	GSW_STATUS status;
	DWORD api_code;
	GSW_METRICS metrics;
} GSW_ROW;

typedef struct GSW_DESKTOP {
	DEVMODEA mode;
	DWORD metric_width;
	DWORD metric_height;
	DWORD caps_bpp;
} GSW_DESKTOP;

typedef struct GSW_OPTIONS {
	BOOL exhaustive;
	BOOL self_test;
	BOOL host_report;
} GSW_OPTIONS;

typedef struct GSW_REPORT {
	BYTE *bytes;
	DWORD length;
	DWORD sequence;
	BOOL broken;
} GSW_REPORT;

struct GSW_SESSION;
typedef struct GSW_ADAPTER GSW_ADAPTER;
typedef BOOL (*GSW_ENUMERATE)(struct GSW_SESSION *, GSW_ADAPTER *);
typedef BOOL (*GSW_MODE_OPERATION)(struct GSW_SESSION *, GSW_ADAPTER *, const GSW_MODE *, GSW_ROW *);
typedef BOOL (*GSW_ADAPTER_OPERATION)(struct GSW_SESSION *, GSW_ADAPTER *);

struct GSW_ADAPTER {
	const char *name;
	GSW_MODE_LIST modes;
	GSW_ENUMERATE enumerate;
	GSW_MODE_OPERATION smoke;
	GSW_MODE_OPERATION benchmark;
	GSW_ADAPTER_OPERATION restore;
	void *state;
	BOOL available;
};

typedef struct GSW_SESSION {
	GSW_OPTIONS options;
	GSW_TIMER timer;
	GSW_DESKTOP original;
	GSW_REPORT report;
	HWND window;
	DWORD started_tick;
	DWORD tested;
	DWORD failed;
	DWORD warnings;
	DWORD unavailable;
	DWORD worst_count;
	GSW_ROW worst[GSW_WORST_CAP];
	BOOL restore_failed;
	BOOL report_failed;
} GSW_SESSION;

typedef BOOL (*GSW_FRAME_FUNCTION)(void *context, DWORD frame, DWORD *crc32);

DWORD gsw_text_length(const char *text);
BOOL gsw_text_equal(const char *left, const char *right);
BOOL gsw_text_copy(char *destination, DWORD capacity, const char *source);
void gsw_zero(void *memory, DWORD bytes);
void gsw_copy(void *destination, const void *source, DWORD bytes);
BOOL gsw_checked_multiply(DWORD left, DWORD right, DWORD *result);
DWORD gsw_crc32(const BYTE *bytes, DWORD count);
BOOL gsw_timer_initialize(GSW_TIMER *timer);
ULONGLONG gsw_timer_now(GSW_TIMER *timer);
DWORD gsw_timer_ms(const GSW_TIMER *timer, ULONGLONG ticks);
DWORD gsw_timer_us(const GSW_TIMER *timer, ULONGLONG ticks);
BOOL gsw_parse_options(GSW_OPTIONS *options);
BOOL gsw_capture_desktop(GSW_DESKTOP *desktop);
BOOL gsw_restore_desktop(GSW_SESSION *session);
HWND gsw_window_create(void);
void gsw_window_pump(void);
BOOL gsw_mode_add(GSW_MODE_LIST *list, DWORD id, DWORD width, DWORD height, DWORD bpp, DWORD hz, DWORD flags);
BOOL gsw_mode_is_canonical(const GSW_MODE *mode);

BOOL gsw_report_initialize(GSW_REPORT *report);
void gsw_report_release(GSW_REPORT *report);
BOOL gsw_report_mode(GSW_SESSION *session, const GSW_ROW *row);
BOOL gsw_report_run(GSW_SESSION *session, GSW_STATUS status, DWORD api_code, const char *detail);
BOOL gsw_report_import_rows(GSW_REPORT *report, const BYTE *bytes, DWORD length);
BOOL gsw_host_publish(const GSW_REPORT *report);
void gsw_host_exit(DWORD code);

BOOL gsw_pattern_allocate(DWORD width, DWORD height, DWORD bpp, BYTE **pixels, DWORD *pitch);
void gsw_pattern_release(BYTE *pixels);
BOOL gsw_pattern_render(BYTE *pixels, DWORD pitch, DWORD width, DWORD height, DWORD bpp, DWORD pattern);
DWORD gsw_pattern_crc(const BYTE *pixels, DWORD pitch, DWORD width, DWORD height, DWORD bpp);
BOOL gsw_benchmark(GSW_SESSION *session, GSW_FRAME_FUNCTION frame, void *context, GSW_METRICS *metrics);

BOOL gsw_gdi_adapter(GSW_ADAPTER *adapter);
BOOL gsw_ddraw_adapter(GSW_ADAPTER *adapter);
BOOL gsw_d3d_adapter(GSW_ADAPTER *adapter);
BOOL gsw_vbe_import(GSW_SESSION *session);
BOOL gsw_draw_summary(GSW_SESSION *session, GSW_STATUS status);
DWORD gsw_run(void);

#endif
