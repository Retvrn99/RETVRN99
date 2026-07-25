/* SPDX-License-Identifier: GPL-3.0-only */

#include "gswgfx.h"

static DWORD gsw_bytes_per_pixel(DWORD bpp)
{
	if(bpp == 8) return 1;
	if(bpp == 15 || bpp == 16) return 2;
	if(bpp == 24) return 3;
	if(bpp == 32) return 4;
	return 0;
}

BOOL gsw_pattern_allocate(DWORD width, DWORD height, DWORD bpp, BYTE **pixels, DWORD *pitch)
{
	DWORD bytes;
	DWORD size;
	if(pixels == NULL || pitch == NULL) return FALSE;
	bytes = gsw_bytes_per_pixel(bpp);
	if(bytes == 0 || !gsw_checked_multiply(width, bytes, pitch) ||
	   !gsw_checked_multiply(*pitch, height, &size) || size > GSW_PATTERN_BYTES)
		return FALSE;
	*pitch = (*pitch + 3UL) & ~3UL;
	if(!gsw_checked_multiply(*pitch, height, &size) || size > GSW_PATTERN_BYTES)
		return FALSE;
	*pixels = (BYTE *)HeapAlloc(GetProcessHeap(), 0, size);
	return *pixels != NULL;
}

DWORD gsw_pattern_crc(const BYTE *pixels, DWORD pitch, DWORD width, DWORD height, DWORD bpp)
{
	DWORD bytes = gsw_bytes_per_pixel(bpp);
	DWORD row_bytes;
	DWORD y;
	DWORD crc = 0xFFFFFFFFUL;
	if(pixels == NULL || bytes == 0 || !gsw_checked_multiply(width, bytes, &row_bytes) ||
	   pitch < row_bytes) return 0;
	for(y = 0; y < height; y++)
	{
		DWORD index;
		const BYTE *row = pixels + y * pitch;
		for(index = 0; index < row_bytes; index++)
		{
			DWORD bit;
			crc ^= row[index];
			for(bit = 0; bit < 8; bit++)
				crc = (crc >> 1) ^ (0xEDB88320UL & (DWORD)(0UL - (crc & 1UL)));
		}
	}
	return crc ^ 0xFFFFFFFFUL;
}

void gsw_pattern_release(BYTE *pixels)
{
	if(pixels != NULL) HeapFree(GetProcessHeap(), 0, pixels);
}

static DWORD gsw_pattern_rgb(DWORD x, DWORD y, DWORD width, DWORD height, DWORD pattern)
{
	DWORD r;
	DWORD g;
	DWORD b;
	if(pattern == 0)
	{
		r = width > 1 ? x * 255UL / (width - 1) : 0;
		g = height > 1 ? y * 255UL / (height - 1) : 0;
		b = ((x >> 4) ^ (y >> 4)) & 1 ? 0xE0 : 0x20;
	}
	else
	{
		DWORD tile = ((x / 31UL) + (y / 23UL)) & 7UL;
		r = (tile * 37UL + x) & 255UL;
		g = (tile * 67UL + y) & 255UL;
		b = (tile * 97UL + x + y) & 255UL;
	}
	return (r << 16) | (g << 8) | b;
}

BOOL gsw_pattern_render(BYTE *pixels, DWORD pitch, DWORD width, DWORD height, DWORD bpp, DWORD pattern)
{
	DWORD y;
	DWORD bytes = gsw_bytes_per_pixel(bpp);
	if(pixels == NULL || bytes == 0 || pitch < width * bytes) return FALSE;
	for(y = 0; y < height; y++)
	{
		BYTE *row = pixels + y * pitch;
		DWORD x;
		for(x = 0; x < width; x++)
		{
			DWORD rgb = gsw_pattern_rgb(x, y, width, height, pattern & 1);
			DWORD r = (rgb >> 16) & 255;
			DWORD g = (rgb >> 8) & 255;
			DWORD b = rgb & 255;
			BYTE *pixel = row + x * bytes;
			if(bpp == 8) pixel[0] = (BYTE)((r & 0xE0) | ((g >> 3) & 0x1C) | (b >> 6));
			else if(bpp == 15)
			{
				WORD value = (WORD)(((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3));
				pixel[0] = (BYTE)value; pixel[1] = (BYTE)(value >> 8);
			}
			else if(bpp == 16)
			{
				WORD value = (WORD)(((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3));
				pixel[0] = (BYTE)value; pixel[1] = (BYTE)(value >> 8);
			}
			else
			{
				pixel[0] = (BYTE)b; pixel[1] = (BYTE)g; pixel[2] = (BYTE)r;
				if(bpp == 32) pixel[3] = 0;
			}
		}
	}
	return TRUE;
}
