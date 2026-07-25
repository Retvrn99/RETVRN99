/* SPDX-License-Identifier: GPL-3.0-only */

#include "gswgfx.h"

static void gsw_heap_down(DWORD *values, DWORD count, DWORD root)
{
	for(;;)
	{
		DWORD child = root * 2 + 1;
		DWORD selected = root;
		DWORD swap;
		if(child < count && values[child] > values[selected]) selected = child;
		if(child + 1 < count && values[child + 1] > values[selected]) selected = child + 1;
		if(selected == root) return;
		swap = values[root]; values[root] = values[selected]; values[selected] = swap;
		root = selected;
	}
}

static void gsw_sort(DWORD *values, DWORD count)
{
	DWORD index;
	if(count < 2) return;
	for(index = count / 2; index > 0; index--) gsw_heap_down(values, count, index - 1);
	for(index = count - 1; index > 0; index--)
	{
		DWORD swap = values[0]; values[0] = values[index]; values[index] = swap;
		gsw_heap_down(values, index, 0);
	}
}

static DWORD gsw_rank(const DWORD *values, DWORD count, DWORD numerator, DWORD denominator)
{
	DWORD rank;
	if(count == 0) return 0;
	rank = (count * numerator + denominator - 1) / denominator;
	if(rank == 0) rank = 1;
	return values[rank - 1];
}

BOOL gsw_benchmark(GSW_SESSION *session, GSW_FRAME_FUNCTION frame, void *context, GSW_METRICS *metrics)
{
	DWORD *samples;
	DWORD sample_count = 0;
	DWORD frame_index = 0;
	ULONGLONG phase_start;
	ULONGLONG measured_start;
	ULONGLONG measured_end;
	DWORD crc = 0;
	DWORD index;
	DWORD threshold;
	if(session == NULL || frame == NULL || metrics == NULL) return FALSE;
	gsw_zero(metrics, sizeof(*metrics));
	samples = (DWORD *)HeapAlloc(GetProcessHeap(), 0, GSW_SAMPLE_CAP * sizeof(DWORD));
	if(samples == NULL) return FALSE;
	phase_start = gsw_timer_now(&session->timer);
	while(gsw_timer_ms(&session->timer, gsw_timer_now(&session->timer) - phase_start) < GSW_WARMUP_MS)
	{
		if(!frame(context, frame_index++, &crc)) goto fail;
		gsw_window_pump();
	}
	measured_start = gsw_timer_now(&session->timer);
	measured_end = measured_start;
	while(gsw_timer_ms(&session->timer, measured_end - measured_start) < GSW_MEASURE_MS)
	{
		ULONGLONG started = gsw_timer_now(&session->timer);
		ULONGLONG ended;
		if(!frame(context, frame_index++, &crc)) goto fail;
		ended = gsw_timer_now(&session->timer);
		if(sample_count < GSW_SAMPLE_CAP)
			samples[sample_count++] = gsw_timer_us(&session->timer, ended - started);
		else metrics->sample_cap = TRUE;
		metrics->frames++;
		measured_end = ended;
		gsw_window_pump();
	}
	if(session->timer.failed || metrics->frames == 0 || sample_count == 0) goto fail;
	metrics->duration_ms = gsw_timer_ms(&session->timer, measured_end - measured_start);
	metrics->avg_fps_milli = metrics->duration_ms != 0 ?
		(DWORD)(((ULONGLONG)metrics->frames * 1000000ULL) / metrics->duration_ms) : 0;
	gsw_sort(samples, sample_count);
	metrics->p50_us = gsw_rank(samples, sample_count, 50, 100);
	metrics->p95_us = gsw_rank(samples, sample_count, 95, 100);
	metrics->max_us = samples[sample_count - 1];
	threshold = metrics->p50_us > 16666UL ? metrics->p50_us * 2 : 33333UL;
	for(index = 0; index < sample_count; index++)
		if(samples[index] > threshold) metrics->slow_frames++;
	metrics->crc32 = crc;
	metrics->status = GSW_STATUS_PASS;
	if(metrics->avg_fps_milli < 20000UL ||
	   (sample_count >= 60 && (metrics->p95_us > metrics->p50_us * 2 ||
	    metrics->slow_frames > (sample_count / 100 > 3 ? sample_count / 100 : 3))))
		metrics->status = GSW_STATUS_WARN;
	HeapFree(GetProcessHeap(), 0, samples);
	return TRUE;
fail:
	HeapFree(GetProcessHeap(), 0, samples);
	metrics->status = GSW_STATUS_FAIL;
	return FALSE;
}
