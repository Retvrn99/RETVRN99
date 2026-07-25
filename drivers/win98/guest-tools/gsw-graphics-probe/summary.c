/* SPDX-License-Identifier: GPL-3.0-only */

#include "gswgfx.h"

static char *gsw_summary_decimal(char *output, DWORD value)
{
	char reverse[11];
	DWORD count = 0;
	DWORD index;
	if(value == 0) *output++ = '0';
	else
	{
		while(value != 0) { reverse[count++] = (char)('0' + value % 10); value /= 10; }
		for(index = count; index > 0; index--) *output++ = reverse[index - 1];
	}
	*output = '\0';
	return output;
}

static char *gsw_summary_text(char *output, const char *text)
{
	while(text != NULL && *text != '\0') *output++ = *text++;
	*output = '\0';
	return output;
}

static void gsw_summary_line(HDC dc, int y, const char *label, DWORD value)
{
	char line[96];
	char *end = gsw_summary_text(line, label);
	gsw_summary_decimal(end, value);
	TextOutA(dc, 32, y, line, (int)gsw_text_length(line));
}

BOOL gsw_draw_summary(GSW_SESSION *session, GSW_STATUS status)
{
	HDC dc;
	RECT rect;
	HBRUSH background;
	DWORD index;
	int y;
	const char *overall = status == GSW_STATUS_FAIL ? "FAIL" :
		(status == GSW_STATUS_WARN ? "WARN" : "PASS");
	if(session == NULL || session->window == NULL) return FALSE;
	SetWindowPos(session->window, HWND_TOPMOST, 0, 0,
		(int)session->original.mode.dmPelsWidth, (int)session->original.mode.dmPelsHeight,
		SWP_SHOWWINDOW);
	dc = GetDC(session->window);
	if(dc == NULL) return FALSE;
	GetClientRect(session->window, &rect);
	background = CreateSolidBrush(RGB(8, 12, 18));
	FillRect(dc, &rect, background);
	DeleteObject(background);
	SetBkMode(dc, TRANSPARENT);
	SetTextColor(dc, status == GSW_STATUS_FAIL ? RGB(255, 96, 96) :
		(status == GSW_STATUS_WARN ? RGB(255, 210, 64) : RGB(96, 255, 144)));
	TextOutA(dc, 32, 24, "GSWGFX DIAGNOSTIC", 17);
	TextOutA(dc, 32, 50, overall, (int)gsw_text_length(overall));
	SetTextColor(dc, RGB(230, 235, 240));
	gsw_summary_line(dc, 82, "Tested: ", session->tested);
	gsw_summary_line(dc, 102, "Failed: ", session->failed);
	gsw_summary_line(dc, 122, "Warnings: ", session->warnings);
	gsw_summary_line(dc, 142, "Unavailable: ", session->unavailable);
	gsw_summary_line(dc, 162, "Elapsed ms: ", (DWORD)(GetTickCount() - session->started_tick));
	TextOutA(dc, 32, 196, "Worst rows", 10);
	y = 220;
	for(index = 0; index < session->worst_count; index++)
	{
		const GSW_ROW *row = &session->worst[index];
		char line[192];
		char *end = gsw_summary_text(line, row->adapter);
		end = gsw_summary_text(end, " "); end = gsw_summary_decimal(end, row->mode.width);
		end = gsw_summary_text(end, "x"); end = gsw_summary_decimal(end, row->mode.height);
		end = gsw_summary_text(end, "x"); end = gsw_summary_decimal(end, row->mode.bpp);
		end = gsw_summary_text(end, " p95_us="); end = gsw_summary_decimal(end, row->metrics.p95_us);
		end = gsw_summary_text(end, " "); gsw_summary_text(end, row->detail);
		TextOutA(dc, 48, y, line, (int)gsw_text_length(line));
		y += 20;
	}
	GdiFlush();
	ReleaseDC(session->window, dc);
	return TRUE;
}
