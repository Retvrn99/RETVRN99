/* SPDX-License-Identifier: GPL-3.0-only */

#include "gswgfx.h"

static BOOL gsw_report_bytes(GSW_REPORT *report, const char *text)
{
	DWORD length = gsw_text_length(text);
	if(report == NULL || report->broken || report->length + length > GSW_REPORT_CAP)
	{
		if(report != NULL) report->broken = TRUE;
		return FALSE;
	}
	gsw_copy(report->bytes + report->length, text, length);
	report->length += length;
	return TRUE;
}

static BOOL gsw_report_decimal(GSW_REPORT *report, DWORD value)
{
	char digits[11];
	DWORD count = 0;
	DWORD index;
	if(value == 0) return gsw_report_bytes(report, "0");
	while(value != 0 && count < sizeof(digits))
	{
		digits[count++] = (char)('0' + value % 10);
		value /= 10;
	}
	for(index = 0; index < count / 2; index++)
	{
		char swap = digits[index];
		digits[index] = digits[count - index - 1];
		digits[count - index - 1] = swap;
	}
	digits[count] = '\0';
	return gsw_report_bytes(report, digits);
}

static BOOL gsw_report_hex(GSW_REPORT *report, DWORD value, BOOL prefix)
{
	static const char hex[] = "0123456789ABCDEF";
	char text[11];
	DWORD index;
	DWORD offset = prefix ? 2 : 0;
	if(prefix)
	{
		text[0] = '0';
		text[1] = 'x';
	}
	for(index = 0; index < 8; index++)
		text[offset + index] = hex[(value >> ((7 - index) * 4)) & 15];
	text[offset + 8] = '\0';
	return gsw_report_bytes(report, text);
}

static const char *gsw_status_text(GSW_STATUS status)
{
	if(status == GSW_STATUS_WARN) return "WARN";
	if(status == GSW_STATUS_UNAVAILABLE) return "UNAVAILABLE";
	if(status == GSW_STATUS_FAIL) return "FAIL";
	return "PASS";
}

static BOOL gsw_field(GSW_REPORT *report, const char *text)
{
	DWORD index;
	if(text == NULL) text = "";
	for(index = 0; text[index] != '\0'; index++)
	{
		char value[2];
		BYTE byte = (BYTE)text[index];
		value[0] = byte >= 0x20 && byte <= 0x7E && byte != '\t' ? (char)byte : '_';
		value[1] = '\0';
		if(!gsw_report_bytes(report, value)) return FALSE;
	}
	return TRUE;
}

static BOOL gsw_tab(GSW_REPORT *report) { return gsw_report_bytes(report, "\t"); }

BOOL gsw_report_initialize(GSW_REPORT *report)
{
	if(report == NULL) return FALSE;
	gsw_zero(report, sizeof(*report));
	report->bytes = (BYTE *)HeapAlloc(GetProcessHeap(), 0, GSW_REPORT_CAP);
	if(report->bytes == NULL) return FALSE;
	return gsw_report_bytes(report, GSW_HEADER);
}

void gsw_report_release(GSW_REPORT *report)
{
	if(report != NULL && report->bytes != NULL)
		HeapFree(GetProcessHeap(), 0, report->bytes);
	if(report != NULL) gsw_zero(report, sizeof(*report));
}

static BOOL gsw_report_common(GSW_REPORT *report, const char *record, const GSW_ROW *row)
{
	const GSW_MODE *mode = &row->mode;
	const GSW_METRICS *metrics = &row->metrics;
	return gsw_field(report, GSW_SCHEMA) && gsw_tab(report) &&
		gsw_report_decimal(report, report->sequence++) && gsw_tab(report) &&
		gsw_field(report, record) && gsw_tab(report) &&
		gsw_field(report, row->adapter) && gsw_tab(report) &&
		gsw_report_decimal(report, mode->id) && gsw_tab(report) &&
		gsw_report_decimal(report, mode->width) && gsw_tab(report) &&
		gsw_report_decimal(report, mode->height) && gsw_tab(report) &&
		gsw_report_decimal(report, mode->bpp) && gsw_tab(report) &&
		gsw_report_decimal(report, mode->hz) && gsw_tab(report) &&
		gsw_field(report, row->path) && gsw_tab(report) &&
		gsw_field(report, gsw_status_text(row->status)) && gsw_tab(report) &&
		gsw_report_hex(report, row->api_code, TRUE) && gsw_tab(report) &&
		gsw_report_decimal(report, metrics->frames) && gsw_tab(report) &&
		gsw_report_decimal(report, metrics->duration_ms) && gsw_tab(report) &&
		gsw_report_decimal(report, metrics->avg_fps_milli) && gsw_tab(report) &&
		gsw_report_decimal(report, metrics->p50_us) && gsw_tab(report) &&
		gsw_report_decimal(report, metrics->p95_us) && gsw_tab(report) &&
		gsw_report_decimal(report, metrics->max_us) && gsw_tab(report) &&
		gsw_report_decimal(report, metrics->slow_frames) && gsw_tab(report);
}

BOOL gsw_report_mode(GSW_SESSION *session, const GSW_ROW *row)
{
	GSW_REPORT *report;
	if(session == NULL || row == NULL) return FALSE;
	report = &session->report;
	return gsw_report_common(report, "MODE", row) &&
		gsw_report_decimal(report, 0) && gsw_tab(report) &&
		gsw_report_decimal(report, 0) && gsw_tab(report) &&
		gsw_report_decimal(report, 0) && gsw_tab(report) &&
		gsw_report_decimal(report, 0) && gsw_tab(report) &&
		gsw_report_hex(report, row->metrics.crc32, FALSE) && gsw_tab(report) &&
		gsw_field(report, row->detail) && gsw_report_bytes(report, "\r\n");
}

BOOL gsw_report_run(GSW_SESSION *session, GSW_STATUS status, DWORD api_code, const char *detail)
{
	GSW_ROW row;
	if(session == NULL) return FALSE;
	gsw_zero(&row, sizeof(row));
	gsw_text_copy(row.adapter, sizeof(row.adapter), "RUN");
	gsw_text_copy(row.path, sizeof(row.path), "SUMMARY");
	gsw_text_copy(row.detail, sizeof(row.detail), detail);
	row.status = status;
	row.api_code = api_code;
	if(!gsw_report_common(&session->report, "RUN", &row)) return FALSE;
	return gsw_report_decimal(&session->report, session->tested) && gsw_tab(&session->report) &&
		gsw_report_decimal(&session->report, session->failed) && gsw_tab(&session->report) &&
		gsw_report_decimal(&session->report, session->warnings) && gsw_tab(&session->report) &&
		gsw_report_decimal(&session->report, session->unavailable) && gsw_tab(&session->report) &&
		gsw_report_hex(&session->report, 0, FALSE) && gsw_tab(&session->report) &&
		gsw_field(&session->report, detail) && gsw_report_bytes(&session->report, "\r\n");
}

BOOL gsw_report_import_rows(GSW_REPORT *report, const BYTE *bytes, DWORD length)
{
	DWORD offset = 0;
	DWORD schema_length = gsw_text_length(GSW_SCHEMA);
	if(report == NULL || bytes == NULL || length == 0 || length > 128UL * 1024UL) return FALSE;
	while(offset < length)
	{
		DWORD line_start = offset;
		DWORD sequence = 0;
		DWORD digits = 0;
		DWORD index;
		if(length - offset < schema_length + 8) return FALSE;
		for(index = 0; index < schema_length; index++)
			if(bytes[offset + index] != (BYTE)GSW_SCHEMA[index]) return FALSE;
		offset += schema_length;
		if(bytes[offset++] != '\t') return FALSE;
		while(offset < length && bytes[offset] >= '0' && bytes[offset] <= '9')
		{
			if(sequence > 429496729UL) return FALSE;
			sequence = sequence * 10 + (bytes[offset++] - '0');
			digits++;
		}
		if(digits == 0 || sequence != report->sequence || offset + 6 > length ||
		   bytes[offset++] != '\t' || bytes[offset++] != 'M' || bytes[offset++] != 'O' ||
		   bytes[offset++] != 'D' || bytes[offset++] != 'E' || bytes[offset++] != '\t') return FALSE;
		while(offset + 1 < length && !(bytes[offset] == '\r' && bytes[offset + 1] == '\n'))
		{
			if((bytes[offset] < 0x20 && bytes[offset] != '\t') || bytes[offset] > 0x7E)
				return FALSE;
			offset++;
		}
		if(offset + 1 >= length) return FALSE;
		offset += 2;
		for(index = line_start; index < offset; index++)
			if(bytes[index] > 0x7F ||
			   (bytes[index] == '\n' && (index == 0 || bytes[index - 1] != '\r'))) return FALSE;
		if(report->length + offset - line_start > GSW_REPORT_CAP) return FALSE;
		gsw_copy(report->bytes + report->length, bytes + line_start, offset - line_start);
		report->length += offset - line_start;
		report->sequence++;
	}
	return TRUE;
}
