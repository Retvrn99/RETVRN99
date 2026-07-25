/* SPDX-License-Identifier: GPL-3.0-only */

#include <dos.h>
#include <i86.h>
#include <conio.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define VBE_HANDOFF "C:\\GSWGFX\\VBE.TMP"
#define SAMPLE_CAP 65536UL
#define MODE_CAP 160
#define WARMUP_TICKS (CLOCKS_PER_SEC / 2)
#define MEASURE_TICKS (CLOCKS_PER_SEC * 3)

#pragma pack(push, 1)
typedef struct VBE_INFO {
	char signature[4];
	unsigned short version;
	unsigned long oem;
	unsigned char capabilities[4];
	unsigned long modes;
	unsigned short memory_blocks;
	unsigned char reserved[236];
} VBE_INFO;

typedef struct VBE_MODE_INFO {
	unsigned short attributes;
	unsigned char win_a_attributes;
	unsigned char win_b_attributes;
	unsigned short granularity_kb;
	unsigned short window_kb;
	unsigned short win_a_segment;
	unsigned short win_b_segment;
	unsigned long window_function;
	unsigned short pitch;
	unsigned short width;
	unsigned short height;
	unsigned char char_width;
	unsigned char char_height;
	unsigned char planes;
	unsigned char bpp;
	unsigned char banks;
	unsigned char memory_model;
	unsigned char bank_size_kb;
	unsigned char image_pages;
	unsigned char reserved0;
	unsigned char red_mask;
	unsigned char red_position;
	unsigned char green_mask;
	unsigned char green_position;
	unsigned char blue_mask;
	unsigned char blue_position;
	unsigned char reserved_mask;
	unsigned char reserved_position;
	unsigned char direct_attributes;
	unsigned long lfb_physical;
	unsigned long offscreen;
	unsigned short offscreen_kb;
	unsigned char reserved[206];
} VBE_MODE_INFO;
#pragma pack(pop)

typedef struct METRICS {
	unsigned long frames;
	unsigned long duration_ms;
	unsigned long avg_fps_milli;
	unsigned long p50_us;
	unsigned long p95_us;
	unsigned long max_us;
	unsigned long slow_frames;
	unsigned long crc32;
	int sample_cap;
	int warning;
} METRICS;

typedef struct MODE {
	unsigned short id;
	VBE_MODE_INFO info;
} MODE;

static unsigned long samples[SAMPLE_CAP];
static unsigned long sequence_number;

static unsigned long crc32_bytes(const unsigned char *bytes, unsigned long count)
{
	unsigned long crc = 0xFFFFFFFFUL;
	unsigned long index;
	for(index = 0; index < count; index++)
	{
		unsigned bit;
		crc ^= bytes[index];
		for(bit = 0; bit < 8; bit++)
			crc = (crc >> 1) ^ (0xEDB88320UL & (0UL - (crc & 1UL)));
	}
	return crc ^ 0xFFFFFFFFUL;
}

static int compare_ulong(const void *left, const void *right)
{
	unsigned long a = *(const unsigned long *)left;
	unsigned long b = *(const unsigned long *)right;
	return a < b ? -1 : a > b ? 1 : 0;
}

static unsigned long nearest_rank(unsigned long count, unsigned long percentile)
{
	unsigned long rank = (count * percentile + 99UL) / 100UL;
	if(rank == 0) rank = 1;
	return samples[rank - 1];
}

static void metrics_finish(METRICS *metrics, unsigned long sample_count, clock_t elapsed)
{
	unsigned long index;
	unsigned long threshold;
	metrics->duration_ms = (unsigned long)(((unsigned __int64)elapsed * 1000UL) / CLOCKS_PER_SEC);
	metrics->avg_fps_milli = metrics->duration_ms != 0 ?
		(unsigned long)(((unsigned __int64)metrics->frames * 1000000UL) / metrics->duration_ms) : 0;
	qsort(samples, sample_count, sizeof(samples[0]), compare_ulong);
	metrics->p50_us = nearest_rank(sample_count, 50);
	metrics->p95_us = nearest_rank(sample_count, 95);
	metrics->max_us = samples[sample_count - 1];
	threshold = metrics->p50_us > 16666UL ? metrics->p50_us * 2UL : 33333UL;
	for(index = 0; index < sample_count; index++) if(samples[index] > threshold) metrics->slow_frames++;
	metrics->warning = metrics->avg_fps_milli < 20000UL ||
		(sample_count >= 60 && (metrics->p95_us > metrics->p50_us * 2UL ||
		 metrics->slow_frames > (sample_count / 100UL > 3UL ? sample_count / 100UL : 3UL)));
}

static void emit_row(FILE *file, const char *adapter, unsigned mode, unsigned width,
	unsigned height, unsigned bpp, const char *path, const char *status,
	unsigned long api_code, const METRICS *metrics, unsigned long crc, const char *detail)
{
	METRICS empty;
	if(metrics == NULL) { memset(&empty, 0, sizeof(empty)); metrics = &empty; }
	fprintf(file,
		"GSWGFX_RESULT_V2\t%lu\tMODE\t%s\t%u\t%u\t%u\t%u\t0\t%s\t%s\t0x%08lX\t%lu\t%lu\t%lu\t%lu\t%lu\t%lu\t%lu\t0\t0\t0\t0\t%08lX\t%s\r\n",
		sequence_number++, adapter, mode, width, height, bpp, path, status, api_code,
		metrics->frames, metrics->duration_ms, metrics->avg_fps_milli, metrics->p50_us,
		metrics->p95_us, metrics->max_us, metrics->slow_frames, crc, detail);
}

static unsigned char bios_mode(void)
{
	union REGS registers;
	memset(&registers, 0, sizeof(registers));
	registers.h.ah = 0x0F;
	int386(0x10, &registers, &registers);
	return registers.h.al;
}

static int bios_set(unsigned short mode)
{
	union REGS registers;
	memset(&registers, 0, sizeof(registers));
	registers.w.ax = mode <= 0x13 ? mode : 0x4F02;
	if(mode > 0x13) registers.w.bx = mode;
	int386(0x10, &registers, &registers);
	if(mode <= 0x13) return bios_mode() == mode;
	if(registers.w.ax != 0x004F) return 0;
	memset(&registers, 0, sizeof(registers));
	registers.w.ax = 0x4F03;
	int386(0x10, &registers, &registers);
	return registers.w.ax == 0x004F && (registers.w.bx & 0x3FFF) == (mode & 0x3FFF);
}

static void text_smoke(void)
{
	union REGS registers;
	memset(&registers, 0, sizeof(registers));
	registers.h.ah = 0x0E;
	registers.h.al = '.';
	registers.h.bl = 7;
	int386(0x10, &registers, &registers);
}

typedef struct CLASSIC_CONTEXT {
	unsigned char mode;
	unsigned long layout_bytes;
	unsigned long plane_bytes;
	unsigned char *layout[2];
	unsigned long crc[2];
} CLASSIC_CONTEXT;

static void packed_index_pattern(unsigned char *pixels, unsigned width, unsigned height,
	unsigned bpp, unsigned pattern)
{
	unsigned long bytes = ((unsigned long)width * height * bpp + 7UL) / 8UL;
	unsigned y;
	memset(pixels, 0, bytes);
	for(y = 0; y < height; y++)
	{
		unsigned x;
		for(x = 0; x < width; x++)
		{
			unsigned value = (x / 11U + y / 7U + pattern * 5U) & ((1U << bpp) - 1U);
			unsigned long bit = ((unsigned long)y * width + x) * bpp;
			unsigned shift = 8U - bpp - (unsigned)(bit & 7UL);
			pixels[bit >> 3] |= (unsigned char)(value << shift);
		}
	}
}

static int classic_prepare(CLASSIC_CONTEXT *context, unsigned char mode,
	unsigned width, unsigned height, unsigned bpp)
{
	unsigned long packed_bytes = ((unsigned long)width * height * bpp + 7UL) / 8UL;
	unsigned pattern;
	memset(context, 0, sizeof(*context)); context->mode = mode;
	context->plane_bytes = mode >= 0x0D && mode <= 0x12 ? (unsigned long)(width / 8U) * height : 0;
	context->layout_bytes = context->plane_bytes ? context->plane_bytes * 4UL :
		(mode >= 4 && mode <= 6 ? 16384UL : packed_bytes);
	for(pattern = 0; pattern < 2; pattern++)
	{
		unsigned char *packed = malloc(packed_bytes);
		unsigned y;
		context->layout[pattern] = calloc(1, context->layout_bytes);
		if(packed == NULL || context->layout[pattern] == NULL) { free(packed); return 0; }
		packed_index_pattern(packed, width, height, bpp, pattern);
		context->crc[pattern] = crc32_bytes(packed, packed_bytes);
		if(context->plane_bytes)
		{
			unsigned plane;
			for(plane = 0; plane < 4; plane++)
				for(y = 0; y < height; y++)
				{
					unsigned x;
					unsigned char *row = context->layout[pattern] +
						(unsigned long)plane * context->plane_bytes + (unsigned long)y * (width / 8U);
					for(x = 0; x < width; x++)
					{
						unsigned value = (x / 11U + y / 7U + pattern * 5U) & 15U;
						if(value & (1U << plane)) row[x >> 3] |= (unsigned char)(0x80U >> (x & 7U));
					}
				}
		}
		else if(mode >= 4 && mode <= 6)
		{
			unsigned row_bytes = width * bpp / 8U;
			for(y = 0; y < height; y++)
				memcpy(context->layout[pattern] + (y & 1U) * 0x2000UL +
					(unsigned long)(y >> 1) * row_bytes,
					packed + (unsigned long)y * row_bytes, row_bytes);
		}
		else memcpy(context->layout[pattern], packed, packed_bytes);
		free(packed);
	}
	return 1;
}

static void classic_release(CLASSIC_CONTEXT *context)
{
	free(context->layout[0]); free(context->layout[1]);
}

static void classic_present(CLASSIC_CONTEXT *context, unsigned long frame)
{
	unsigned pattern = (unsigned)(frame & 1UL);
	volatile unsigned char *video = (volatile unsigned char *)(context->mode >= 4 && context->mode <= 6 ?
		0xB8000UL : 0xA0000UL);
	unsigned long index;
	if(context->plane_bytes)
	{
		unsigned plane;
		for(plane = 0; plane < 4; plane++)
		{
			outp(0x3C4, 2); outp(0x3C5, 1U << plane);
			for(index = 0; index < context->plane_bytes; index++)
				video[index] = context->layout[pattern][(unsigned long)plane * context->plane_bytes + index];
		}
		outp(0x3C4, 2); outp(0x3C5, 0x0F);
	}
	else for(index = 0; index < context->layout_bytes; index++) video[index] = context->layout[pattern][index];
}

static int benchmark_classic(unsigned char mode, unsigned width, unsigned height,
	unsigned bpp, METRICS *metrics)
{
	CLASSIC_CONTEXT context;
	clock_t started;
	clock_t ended;
	unsigned long sample_count = 0;
	unsigned long frame = 0;
	if(!classic_prepare(&context, mode, width, height, bpp)) return 0;
	memset(metrics, 0, sizeof(*metrics));
	started = clock();
	while((clock_t)(clock() - started) < WARMUP_TICKS) classic_present(&context, frame++);
	started = clock(); ended = started;
	while((clock_t)(ended - started) < MEASURE_TICKS)
	{
		clock_t frame_started = clock();
		classic_present(&context, frame++); ended = clock();
		if(sample_count < SAMPLE_CAP) samples[sample_count++] =
			(unsigned long)(((unsigned __int64)(ended - frame_started) * 1000000UL) / CLOCKS_PER_SEC);
		else metrics->sample_cap = 1;
		metrics->frames++;
	}
	metrics->crc32 = context.crc[(frame - 1) & 1UL];
	metrics_finish(metrics, sample_count, ended - started);
	classic_release(&context);
	return 1;
}

static void run_vga(FILE *file, unsigned char original)
{
	static const unsigned char ids[] = {0,1,2,3,4,5,6,7,0x0D,0x0E,0x0F,0x10,0x11,0x12,0x13};
	static const unsigned short widths[] = {40,40,80,80,320,320,640,80,320,640,640,640,640,640,320};
	static const unsigned short heights[] = {25,25,25,25,200,200,200,25,200,200,350,350,480,480,200};
	static const unsigned char bpps[] = {0,0,0,0,2,2,1,0,4,4,1,4,1,4,8};
	unsigned index;
	for(index = 0; index < sizeof(ids); index++)
	{
		int pass = bios_set(ids[index]);
		METRICS metrics;
		if(pass && bpps[index] == 0) text_smoke();
		emit_row(file, "VGA_BIOS", ids[index], widths[index], heights[index], bpps[index],
			bpps[index] == 0 ? "TEXT" : bpps[index] == 8 ? "CHAIN4" : "PLANAR",
			pass ? "PASS" : "FAIL", pass ? 0 : 1, NULL, 0,
			bpps[index] == 0 ? "FUNCTIONAL_SMOKE" : "GRAPHICS_SMOKE");
		if(pass && bpps[index] != 0)
		{
			if(benchmark_classic(ids[index], widths[index], heights[index], bpps[index], &metrics))
			emit_row(file, "VGA_BIOS", ids[index], widths[index], heights[index], bpps[index],
				bpps[index] == 8 ? "CHAIN4" : "PLANAR", metrics.warning ? "WARN" : "PASS",
				0, &metrics, metrics.crc32, metrics.sample_cap ? "SAMPLE_CAP" : "BENCHMARK");
		}
	}
	bios_set(original);
}

static unsigned short dos_allocate(unsigned paragraphs)
{
	union REGS registers;
	memset(&registers, 0, sizeof(registers));
	registers.h.ah = 0x48;
	registers.w.bx = paragraphs;
	int386(0x21, &registers, &registers);
	return registers.x.cflag ? 0 : registers.w.ax;
}

static void dos_free(unsigned short segment)
{
	union REGS registers;
	struct SREGS segments;
	memset(&registers, 0, sizeof(registers)); segread(&segments);
	registers.h.ah = 0x49; segments.es = segment;
	int386x(0x21, &registers, &registers, &segments);
}

static int vbe_call_buffer(unsigned short ax, unsigned short cx, unsigned short segment)
{
	union REGS registers;
	struct SREGS segments;
	memset(&registers, 0, sizeof(registers)); segread(&segments);
	registers.w.ax = ax; registers.w.cx = cx; registers.w.di = 0; segments.es = segment;
	int386x(0x10, &registers, &registers, &segments);
	return registers.w.ax == 0x004F;
}

static unsigned long dpmi_map(unsigned long physical, unsigned long bytes)
{
	union REGS registers;
	memset(&registers, 0, sizeof(registers));
	registers.w.ax = 0x0800;
	registers.w.bx = (unsigned short)(physical >> 16); registers.w.cx = (unsigned short)physical;
	registers.w.si = (unsigned short)(bytes >> 16); registers.w.di = (unsigned short)bytes;
	int386(0x31, &registers, &registers);
	if(registers.x.cflag) return 0;
	return ((unsigned long)registers.w.bx << 16) | registers.w.cx;
}

static void dpmi_unmap(unsigned long linear)
{
	union REGS registers;
	memset(&registers, 0, sizeof(registers));
	registers.w.ax = 0x0801; registers.w.bx = (unsigned short)(linear >> 16);
	registers.w.cx = (unsigned short)linear;
	int386(0x31, &registers, &registers);
}

static int packed_bpp(unsigned bpp)
{
	return bpp == 8 || bpp == 15 || bpp == 16 || bpp == 24 || bpp == 32;
}

static int build_pattern(unsigned char *pixels, unsigned long pitch, unsigned width,
	unsigned height, unsigned bpp, unsigned pattern)
{
	unsigned bytes = bpp == 8 ? 1 : bpp == 15 || bpp == 16 ? 2 : bpp == 24 ? 3 : bpp == 32 ? 4 : 0;
	unsigned y;
	if(bytes == 0 || pitch < (unsigned long)width * bytes) return 0;
	memset(pixels, 0, pitch * height);
	for(y = 0; y < height; y++)
	{
		unsigned x;
		unsigned char *row = pixels + (unsigned long)y * pitch;
		for(x = 0; x < width; x++)
		{
			unsigned long r = pattern == 0 ? (width > 1 ? (unsigned long)x * 255UL / (width - 1) : 0) :
				((x / 31U + y / 23U) * 37UL + x) & 255UL;
			unsigned long g = pattern == 0 ? (height > 1 ? (unsigned long)y * 255UL / (height - 1) : 0) :
				((x / 31U + y / 23U) * 67UL + y) & 255UL;
			unsigned long b = pattern == 0 ? (((x >> 4) ^ (y >> 4)) & 1 ? 0xE0 : 0x20) :
				((x / 31U + y / 23U) * 97UL + x + y) & 255UL;
			unsigned char *pixel = row + (unsigned long)x * bytes;
			if(bpp == 8) pixel[0] = (unsigned char)((r & 0xE0) | ((g >> 3) & 0x1C) | (b >> 6));
			else if(bpp == 15)
			{
				unsigned short value = (unsigned short)(((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3));
				pixel[0] = (unsigned char)value; pixel[1] = (unsigned char)(value >> 8);
			}
			else if(bpp == 16)
			{
				unsigned short value = (unsigned short)(((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3));
				pixel[0] = (unsigned char)value; pixel[1] = (unsigned char)(value >> 8);
			}
			else
			{
				pixel[0] = (unsigned char)b; pixel[1] = (unsigned char)g; pixel[2] = (unsigned char)r;
				if(bpp == 32) pixel[3] = 0;
			}
		}
	}
	return 1;
}

static unsigned long crc32_rows(const unsigned char *pixels, unsigned long pitch,
	unsigned long active, unsigned height)
{
	unsigned long crc = 0xFFFFFFFFUL;
	unsigned y;
	for(y = 0; y < height; y++)
	{
		unsigned long index;
		const unsigned char *row = pixels + (unsigned long)y * pitch;
		for(index = 0; index < active; index++)
		{
			unsigned bit;
			crc ^= row[index];
			for(bit = 0; bit < 8; bit++)
				crc = (crc >> 1) ^ (0xEDB88320UL & (0UL - (crc & 1UL)));
		}
	}
	return crc ^ 0xFFFFFFFFUL;
}

static int vbe_bank(unsigned long offset_kb, unsigned granularity_kb)
{
	union REGS registers;
	if(granularity_kb == 0) return 0;
	memset(&registers, 0, sizeof(registers));
	registers.w.ax = 0x4F05; registers.w.bx = 0;
	registers.w.dx = (unsigned short)(offset_kb / granularity_kb);
	int386(0x10, &registers, &registers);
	return registers.w.ax == 0x004F;
}

static int vbe_copy_banked(const MODE *mode, const unsigned char *pixels, unsigned long bytes)
{
	unsigned long offset = 0;
	volatile unsigned char *window = (volatile unsigned char *)((unsigned long)mode->info.win_a_segment << 4);
	unsigned long window_bytes = (unsigned long)mode->info.window_kb * 1024UL;
	if(window_bytes == 0 || mode->info.granularity_kb == 0) return 0;
	while(offset < bytes)
	{
		unsigned long count = bytes - offset;
		unsigned long index;
		if(count > window_bytes) count = window_bytes;
		if(!vbe_bank(offset / 1024UL, mode->info.granularity_kb)) return 0;
		for(index = 0; index < count; index++) window[index] = pixels[offset + index];
		offset += count;
	}
	return 1;
}

static int vbe_copy_lfb(unsigned long linear, const unsigned char *pixels, unsigned long bytes)
{
	volatile unsigned char *output = (volatile unsigned char *)linear;
	unsigned long index;
	for(index = 0; index < bytes; index++) output[index] = pixels[index];
	return 1;
}

static int smoke_banked(const MODE *mode)
{
	volatile unsigned char *window;
	unsigned index;
	if(!bios_set(mode->id) || !vbe_bank(0, mode->info.granularity_kb)) return 0;
	window = (volatile unsigned char *)((unsigned long)mode->info.win_a_segment << 4);
	for(index = 0; index < 32; index++) window[index] = (unsigned char)(index * 7U);
	return 1;
}

static int smoke_lfb(const MODE *mode)
{
	unsigned long bytes = (unsigned long)mode->info.pitch * mode->info.height;
	unsigned long linear;
	volatile unsigned char *output;
	unsigned index;
	if(!bios_set(mode->id | 0x4000) || bytes == 0) return 0;
	linear = dpmi_map(mode->info.lfb_physical, bytes);
	if(linear == 0) return 0;
	output = (volatile unsigned char *)linear;
	for(index = 0; index < 32; index++) output[index] = (unsigned char)(index * 11U);
	dpmi_unmap(linear);
	return 1;
}

static int benchmark_vbe(const MODE *mode, int lfb, METRICS *metrics)
{
	unsigned long bytes = (unsigned long)mode->info.pitch * mode->info.height;
	unsigned long active = (unsigned long)mode->info.width * ((mode->info.bpp + 7U) / 8U);
	unsigned char *patterns[2];
	unsigned long linear = 0;
	unsigned long sample_count = 0;
	unsigned long frame = 0;
	clock_t started;
	clock_t ended;
	if(bytes == 0 || active > mode->info.pitch || bytes > 16UL * 1024UL * 1024UL) return 0;
	patterns[0] = malloc(bytes); patterns[1] = malloc(bytes);
	if(patterns[0] == NULL || patterns[1] == NULL) { free(patterns[0]); free(patterns[1]); return 0; }
	if(!build_pattern(patterns[0], mode->info.pitch, mode->info.width, mode->info.height,
	   mode->info.bpp, 0) || !build_pattern(patterns[1], mode->info.pitch,
	   mode->info.width, mode->info.height, mode->info.bpp, 1)) goto fail;
	if(lfb) { linear = dpmi_map(mode->info.lfb_physical, bytes); if(linear == 0) goto fail; }
	memset(metrics, 0, sizeof(*metrics));
	started = clock();
	while((clock_t)(clock() - started) < WARMUP_TICKS)
	{
		if(lfb) vbe_copy_lfb(linear, patterns[frame & 1], bytes);
		else if(!vbe_copy_banked(mode, patterns[frame & 1], bytes)) goto fail;
		frame++;
	}
	started = clock(); ended = started;
	while((clock_t)(ended - started) < MEASURE_TICKS)
	{
		clock_t frame_started = clock();
		if(lfb) vbe_copy_lfb(linear, patterns[frame & 1], bytes);
		else if(!vbe_copy_banked(mode, patterns[frame & 1], bytes)) goto fail;
		frame++; ended = clock();
		if(sample_count < SAMPLE_CAP) samples[sample_count++] =
			(unsigned long)(((unsigned __int64)(ended - frame_started) * 1000000UL) / CLOCKS_PER_SEC);
		else metrics->sample_cap = 1;
		metrics->frames++;
	}
	metrics->crc32 = crc32_rows(patterns[(frame - 1) & 1], mode->info.pitch,
		active, mode->info.height);
	metrics_finish(metrics, sample_count, ended - started);
	if(linear != 0) dpmi_unmap(linear);
	free(patterns[0]); free(patterns[1]); return 1;
fail:
	if(linear != 0) dpmi_unmap(linear);
	free(patterns[0]); free(patterns[1]); return 0;
}

static int canonical(const MODE *mode)
{
	return (mode->info.width == 320 && (mode->info.height == 200 || mode->info.height == 240)) ||
		(mode->info.width == 640 && mode->info.height == 480) ||
		(mode->info.width == 800 && mode->info.height == 600) ||
		(mode->info.width == 1024 && mode->info.height == 768);
}

static int run_vbe(FILE *file, int exhaustive)
{
	unsigned short info_segment = dos_allocate(32);
	unsigned short mode_segment = dos_allocate(16);
	VBE_INFO *info;
	VBE_MODE_INFO *mode_info;
	unsigned short *mode_ids;
	MODE modes[MODE_CAP];
	unsigned count = 0;
	unsigned index;
	int success = 1;
	if(info_segment == 0 || mode_segment == 0) goto fail;
	info = (VBE_INFO *)((unsigned long)info_segment << 4);
	mode_info = (VBE_MODE_INFO *)((unsigned long)mode_segment << 4);
	memset(info, 0, sizeof(*info)); memcpy(info->signature, "VBE2", 4);
	if(!vbe_call_buffer(0x4F00, 0, info_segment) || memcmp(info->signature, "VESA", 4) != 0) goto fail;
	mode_ids = (unsigned short *)((((info->modes >> 16) & 0xFFFFUL) << 4) + (info->modes & 0xFFFFUL));
	while(count < MODE_CAP && mode_ids[count] != 0xFFFF)
	{
		memset(mode_info, 0, sizeof(*mode_info));
		if(vbe_call_buffer(0x4F01, mode_ids[count], mode_segment) &&
		   (mode_info->attributes & 0x11) == 0x11 && mode_info->width != 0 &&
		   mode_info->height != 0 && mode_info->bpp != 0)
		{
			modes[count].id = mode_ids[count]; modes[count].info = *mode_info; count++;
		}
		else mode_ids++;
	}
	for(index = 0; index < count; index++)
	{
		MODE *mode = &modes[index];
		int banked = mode->info.win_a_segment != 0 && mode->info.granularity_kb != 0;
		int lfb = (mode->info.attributes & 0x80) != 0 && mode->info.lfb_physical != 0;
		int banked_smoke = banked ? smoke_banked(mode) : 0;
		int lfb_smoke = lfb ? smoke_lfb(mode) : 0;
		if(banked)
		{
			emit_row(file, "VBE", mode->id, mode->info.width, mode->info.height, mode->info.bpp,
				"BANKED", banked_smoke ? "PASS" : "FAIL", banked_smoke ? 0 : 0x4F02,
				NULL, 0, "MODE_SMOKE_READBACK");
			if(!banked_smoke) success = 0;
		}
		if(lfb)
		{
			emit_row(file, "VBE", mode->id, mode->info.width, mode->info.height, mode->info.bpp,
				"LFB", lfb_smoke ? "PASS" : "FAIL", lfb_smoke ? 0 : 0x4F02,
				NULL, 0, "MODE_SMOKE_READBACK");
			if(!lfb_smoke) success = 0;
		}
		if(!banked && !lfb)
			emit_row(file, "VBE", mode->id, mode->info.width, mode->info.height, mode->info.bpp,
				"NONE", "UNAVAILABLE", 0, NULL, 0, "NO_FRAMEBUFFER_PATH");
		if(packed_bpp(mode->info.bpp) && (exhaustive || canonical(mode)))
		{
			METRICS metrics;
			if(banked && banked_smoke && bios_set(mode->id) && benchmark_vbe(mode, 0, &metrics))
				emit_row(file, "VBE", mode->id, mode->info.width, mode->info.height, mode->info.bpp,
					"BANKED", metrics.warning ? "WARN" : "PASS", 0, &metrics,
					metrics.crc32, metrics.sample_cap ? "SAMPLE_CAP" : "BENCHMARK");
			else if(banked) success = 0;
			if(lfb && lfb_smoke && bios_set(mode->id | 0x4000) && benchmark_vbe(mode, 1, &metrics))
				emit_row(file, "VBE", mode->id, mode->info.width, mode->info.height, mode->info.bpp,
					"LFB", metrics.warning ? "WARN" : "PASS", 0, &metrics,
					metrics.crc32, metrics.sample_cap ? "SAMPLE_CAP" : "BENCHMARK");
			else if(lfb) success = 0;
		}
	}
	dos_free(mode_segment); dos_free(info_segment); return success;
fail:
	if(mode_segment != 0) dos_free(mode_segment);
	if(info_segment != 0) dos_free(info_segment);
	return 0;
}

int main(int argc, char **argv)
{
	FILE *file;
	unsigned char original = bios_mode();
	int exhaustive = argc > 1 && strcmp(argv[1], "/exhaustive") == 0;
	int success;
	remove(VBE_HANDOFF);
	file = fopen(VBE_HANDOFF, "wb");
	if(file == NULL) return 2;
	run_vga(file, original);
	success = run_vbe(file, exhaustive);
	bios_set(original);
	if(fclose(file) != 0) success = 0;
	if(!success) return 1;
	return 0;
}
