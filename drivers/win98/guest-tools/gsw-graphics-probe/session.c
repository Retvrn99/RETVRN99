/* SPDX-License-Identifier: GPL-3.0-only */

#include "gswgfx.h"

static void gsw_track_row(GSW_SESSION *session, const GSW_ROW *row)
{
	DWORD rank;
	DWORD index;
	session->tested++;
	if(row->status == GSW_STATUS_FAIL) session->failed++;
	else if(row->status == GSW_STATUS_WARN) session->warnings++;
	else if(row->status == GSW_STATUS_UNAVAILABLE) session->unavailable++;
	if(row->status == GSW_STATUS_PASS) return;
	rank = row->status == GSW_STATUS_FAIL ? 3 : row->status == GSW_STATUS_WARN ? 2 : 1;
	for(index = 0; index < session->worst_count; index++)
	{
		DWORD current = session->worst[index].status == GSW_STATUS_FAIL ? 3 :
			session->worst[index].status == GSW_STATUS_WARN ? 2 : 1;
		if(rank > current || (rank == current && row->metrics.p95_us > session->worst[index].metrics.p95_us)) break;
	}
	if(index < GSW_WORST_CAP)
	{
		DWORD move = session->worst_count < GSW_WORST_CAP ? session->worst_count : GSW_WORST_CAP - 1;
		while(move > index) { session->worst[move] = session->worst[move - 1]; move--; }
		session->worst[index] = *row;
		if(session->worst_count < GSW_WORST_CAP) session->worst_count++;
	}
}

static BOOL gsw_record(GSW_SESSION *session, const GSW_ROW *row)
{
	gsw_track_row(session, row);
	if(!gsw_report_mode(session, row))
	{
		session->report_failed = TRUE;
		return FALSE;
	}
	return TRUE;
}

static BOOL gsw_unavailable(GSW_SESSION *session, const char *adapter, const char *detail)
{
	GSW_ROW row;
	gsw_zero(&row, sizeof(row));
	gsw_text_copy(row.adapter, sizeof(row.adapter), adapter);
	gsw_text_copy(row.path, sizeof(row.path), "NONE");
	gsw_text_copy(row.detail, sizeof(row.detail), detail);
	row.status = GSW_STATUS_UNAVAILABLE;
	row.api_code = (DWORD)E_NOINTERFACE;
	return gsw_record(session, &row);
}

static BOOL gsw_adapter_run(GSW_SESSION *session, GSW_ADAPTER *adapter)
{
	DWORD index;
	BOOL completed = TRUE;
	if(!adapter->enumerate(session, adapter))
	{
		gsw_unavailable(session, adapter->name,
			gsw_text_equal(adapter->name, "DIRECT3D") ? "D3D7_OR_D3D3_UNAVAILABLE" : "ADAPTER_UNAVAILABLE");
		return gsw_text_equal(adapter->name, "DIRECT3D");
	}
	for(index = 0; index < adapter->modes.count; index++)
	{
		GSW_ROW row;
		BOOL success = adapter->smoke(session, adapter, &adapter->modes.items[index], &row);
		if(!adapter->restore(session, adapter)) { row.status = GSW_STATUS_FAIL; session->restore_failed = TRUE; }
		if(!success) row.status = GSW_STATUS_FAIL;
		if(!gsw_record(session, &row)) completed = FALSE;
		if(!success) completed = FALSE;
	}
	for(index = 0; index < adapter->modes.count; index++)
	{
		const GSW_MODE *mode = &adapter->modes.items[index];
		GSW_ROW row;
		BOOL selected = session->options.exhaustive || gsw_mode_is_canonical(mode);
		BOOL success;
		if(gsw_text_equal(adapter->name, "DIRECT3D") && !session->options.exhaustive &&
		   mode->width < 640) selected = FALSE;
		if(!selected) continue;
		success = adapter->benchmark(session, adapter, mode, &row);
		if(!adapter->restore(session, adapter)) { row.status = GSW_STATUS_FAIL; session->restore_failed = TRUE; }
		if(!success) row.status = GSW_STATUS_FAIL;
		if(!gsw_record(session, &row)) completed = FALSE;
		if(!success) completed = FALSE;
	}
	return completed;
}

typedef struct GSW_SELF_FRAME { DWORD value; } GSW_SELF_FRAME;

static BOOL gsw_self_frame(void *value, DWORD frame, DWORD *crc32)
{
	GSW_SELF_FRAME *state = (GSW_SELF_FRAME *)value;
	state->value = state->value * 1664525UL + 1013904223UL + frame;
	if(crc32 != NULL) *crc32 = state->value;
	return TRUE;
}

static BOOL gsw_self_test(GSW_SESSION *session)
{
	BYTE *pattern = NULL;
	DWORD pitch = 0;
	GSW_SELF_FRAME frame;
	GSW_ROW row;
	BOOL success;
	gsw_zero(&frame, sizeof(frame)); gsw_zero(&row, sizeof(row));
	gsw_text_copy(row.adapter, sizeof(row.adapter), "SELFTEST");
	gsw_text_copy(row.path, sizeof(row.path), "SYNTHETIC");
	row.mode.id = 0; row.mode.width = 64; row.mode.height = 64; row.mode.bpp = 32;
	success = gsw_pattern_allocate(64, 64, 32, &pattern, &pitch) &&
		gsw_pattern_render(pattern, pitch, 64, 64, 32, 0);
	if(success)
	{
		DWORD crc = gsw_pattern_crc(pattern, pitch, 64, 64, 32);
		success = crc != 0 && crc == gsw_pattern_crc(pattern, pitch, 64, 64, 32);
	}
	if(success) success = gsw_benchmark(session, gsw_self_frame, &frame, &row.metrics);
	row.status = success ? row.metrics.status : GSW_STATUS_FAIL;
	row.metrics.crc32 ^= pattern != NULL ? gsw_pattern_crc(pattern, pitch, 64, 64, 32) : 0;
	gsw_text_copy(row.detail, sizeof(row.detail), success ? "METRICS_FORMAT_CRC" : "SELF_TEST_FAILED");
	gsw_pattern_release(pattern);
	return gsw_record(session, &row) && success;
}

DWORD gsw_run(void)
{
	GSW_SESSION session;
	GSW_ADAPTER adapters[3];
	BOOL initialized;
	BOOL completed = TRUE;
	BOOL summary_ok;
	GSW_STATUS overall;
	DWORD exit_code;
	DWORD index;
	gsw_zero(&session, sizeof(session));
	session.started_tick = GetTickCount();
	if(!gsw_parse_options(&session.options) || !gsw_timer_initialize(&session.timer)) return 2;
	initialized = gsw_report_initialize(&session.report) && gsw_capture_desktop(&session.original);
	if(!initialized) { gsw_report_release(&session.report); return 2; }
	session.window = gsw_window_create();
	if(session.window == NULL) { gsw_report_release(&session.report); return 2; }
	if(session.options.self_test) completed = gsw_self_test(&session);
	else
	{
		if(!gsw_vbe_import(&session))
		{
			GSW_ROW row;
			gsw_zero(&row, sizeof(row));
			gsw_text_copy(row.adapter, sizeof(row.adapter), "VGA_VBE");
			gsw_text_copy(row.path, sizeof(row.path), "DOS_COMPANION");
			gsw_text_copy(row.detail, sizeof(row.detail), "COMPANION_OR_HANDOFF_FAILED");
			row.status = GSW_STATUS_FAIL; row.api_code = ERROR_BAD_FORMAT;
			gsw_record(&session, &row); completed = FALSE;
		}
		gsw_gdi_adapter(&adapters[0]); gsw_ddraw_adapter(&adapters[1]); gsw_d3d_adapter(&adapters[2]);
		for(index = 0; index < 3; index++) if(!gsw_adapter_run(&session, &adapters[index])) completed = FALSE;
	}
	if(!session.options.self_test && !gsw_restore_desktop(&session))
	{
		session.restore_failed = TRUE; completed = FALSE;
	}
	overall = !completed || session.failed != 0 || session.restore_failed || session.report_failed ?
		GSW_STATUS_FAIL : session.warnings != 0 ? GSW_STATUS_WARN : GSW_STATUS_PASS;
	if(!gsw_report_run(&session, overall, 0, overall == GSW_STATUS_FAIL ? "FAILED" : "COMPLETE"))
	{
		session.report_failed = TRUE; overall = GSW_STATUS_FAIL;
	}
	if(session.options.host_report && !gsw_host_publish(&session.report))
	{
		session.report_failed = TRUE; overall = GSW_STATUS_FAIL;
	}
	summary_ok = gsw_draw_summary(&session, overall);
	if(!summary_ok) overall = GSW_STATUS_FAIL;
	exit_code = overall == GSW_STATUS_FAIL ? 1 : 0;
	if(session.options.host_report) gsw_host_exit(exit_code);
	gsw_report_release(&session.report);
	return exit_code;
}
