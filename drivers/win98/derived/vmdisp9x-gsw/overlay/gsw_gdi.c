/* SPDX-License-Identifier: GPL-3.0-only */

#include "winhack.h"
#include <gdidefs.h>
#include <dibeng.h>
#include <string.h>
#include "gsw_transport.h"
#include "gsw_gdi.h"

typedef char GSWGdiCommandSizeCheck[
	(sizeof(GSWGdiBltCommand) == GSW_GDI_BLT_COMMAND_BYTES) ? 1 : -1
];

static GSWGdiBltCommand gsw_gdi_command;

static BOOL gsw_gdi_source_dependent(BYTE rop)
{
	return ((rop ^ (rop >> 2)) & 0x33) != 0;
}

static BOOL gsw_gdi_pattern_dependent(BYTE rop)
{
	return ((rop ^ (rop >> 4)) & 0x0F) != 0;
}

static DWORD gsw_gdi_mask(WORD bpp)
{
	switch(bpp)
	{
		case 8:  return 0x000000FFUL;
		case 16: return 0x0000FFFFUL;
		case 24: return 0x00FFFFFFUL;
		case 32: return 0xFFFFFFFFUL;
	}
	return 0;
}

static DWORD gsw_gdi_format(LPDIBENGINE device)
{
	if(device == NULL) return 0;
	switch(device->deBitsPixel)
	{
		case 8:  return GSW_PIXEL_FORMAT_INDEXED_8;
		case 16: return (device->deFlags & FIVE6FIVE) != 0 ? GSW_PIXEL_FORMAT_RGB_565 : 0;
		case 24: return GSW_PIXEL_FORMAT_RGB_888;
		case 32: return GSW_PIXEL_FORMAT_XRGB_8888;
	}
	return 0;
}

static BOOL gsw_gdi_device_valid(
	LPDIBENGINE device,
	WORD x,
	WORD y,
	WORD width,
	WORD height
)
{
	WORD rejected = BANKEDVRAM | BANKEDSCAN | NOT_FRAMEBUFFER | BUSY;
	if(device == NULL || device->deType != TYPE_DIBENG || width == 0 || height == 0 ||
	   (device->deFlags & VRAM) == 0 || (device->deFlags & rejected) != 0 ||
	   device->deDeltaScan == 0 || (LONG)device->deDeltaScan < 0 ||
	   device->deBeginAccess == NULL || device->deEndAccess == NULL ||
	   gsw_gdi_format(device) == 0 ||
	   x > device->deWidth || width > device->deWidth - x ||
	   y > device->deHeight || height > device->deHeight - y)
		return FALSE;
	return TRUE;
}

static DWORD gsw_gdi_read_pixel(const BYTE __far *source, WORD bytes)
{
	DWORD value = 0;
	WORD index;
	for(index = 0; index < bytes; index++)
		value |= (DWORD)source[index] << (index * 8);
	return value;
}

static BYTE __far *gsw_gdi_pattern_bits(LPBRUSH brush, WORD bpp)
{
	switch(bpp)
	{
		case 8:  return ((DIB_Brush8 __far *)brush)->dp8BrushBits;
		case 16: return ((DIB_Brush16 __far *)brush)->dp16BrushBits;
		case 24: return ((DIB_Brush24 __far *)brush)->dp24BrushBits;
		case 32: return ((DIB_Brush32 __far *)brush)->dp32BrushBits;
	}
	return NULL;
}

static BOOL gsw_gdi_pattern(
	GSWGdiBltCommand *command,
	LPBRUSH brush,
	WORD bpp
)
{
	DIB_Brush8 __far *prefix = (DIB_Brush8 __far *)brush;
	BYTE __far *bits;
	DWORD mask = gsw_gdi_mask(bpp);
	WORD bytes = (bpp + 7) >> 3;
	WORD index;
	if(prefix == NULL || prefix->dp8BrushBpp != bpp || mask == 0 ||
	   (prefix->dp8BrushStyle != BS_SOLID && prefix->dp8BrushStyle != BS_PATTERN) ||
	   (prefix->dp8BrushFlags & (PATTERNMONO | MASKVALID)) != 0)
		return FALSE;
	command->flags |= GSW_GDI_PATTERN_VALID;
	bits = gsw_gdi_pattern_bits(brush, bpp);
	if(bits == NULL) return FALSE;
	if((prefix->dp8BrushFlags & COLORSOLID) != 0)
	{
		for(index = 0; index < GSW_GDI_PATTERN_PIXELS; index++)
			command->pattern[index] = gsw_gdi_read_pixel(bits, bytes) & mask;
		return TRUE;
	}
	for(index = 0; index < GSW_GDI_PATTERN_PIXELS; index++)
		command->pattern[index] = gsw_gdi_read_pixel(bits + index * bytes, bytes) & mask;
	return TRUE;
}

static void gsw_gdi_cursor_begin(
	LPDIBENGINE destination,
	WORD destination_x,
	WORD destination_y,
	LPDIBENGINE source,
	WORD source_x,
	WORD source_y,
	WORD width,
	WORD height,
	BOOL source_needed
)
{
	WORD left = destination_x;
	WORD top = destination_y;
	WORD right = destination_x + width - 1;
	WORD bottom = destination_y + height - 1;
	if(source_needed && source == destination)
	{
		if(source_x < left) left = source_x;
		if(source_y < top) top = source_y;
		if(source_x + width - 1 > right) right = source_x + width - 1;
		if(source_y + height - 1 > bottom) bottom = source_y + height - 1;
	}
	destination->deBeginAccess(destination, left, top, right, bottom, CURSOREXCLUDE);
	if(source_needed && source != destination)
		source->deBeginAccess(
			source, source_x, source_y, source_x + width - 1, source_y + height - 1,
			CURSOREXCLUDE
		);
}

static void gsw_gdi_cursor_end(
	LPDIBENGINE destination,
	LPDIBENGINE source,
	BOOL source_needed
)
{
	if(source_needed && source != destination)
		source->deEndAccess(source, CURSOREXCLUDE);
	destination->deEndAccess(destination, CURSOREXCLUDE);
}

BOOL WINAPI __loadds GSW_BitBlt(
	LPDIBENGINE destination,
	WORD destination_x,
	WORD destination_y,
	LPPDEVICE source_device,
	WORD source_x,
	WORD source_y,
	WORD width,
	WORD height,
	DWORD rop3,
	LPBRUSH brush,
	LPDRAWMODE draw_mode
)
{
	LPDIBENGINE source = (LPDIBENGINE)source_device;
	BYTE truth = (BYTE)(rop3 >> 16);
	BOOL source_needed = gsw_gdi_source_dependent(truth);
	BOOL pattern_needed = gsw_gdi_pattern_dependent(truth);
	BOOL submitted;
	DWORD format;

	if((GSW_PM16_capabilities() & GSW_VGA_CAP_GDI_ROP3) == 0 ||
	   !gsw_gdi_device_valid(destination, destination_x, destination_y, width, height))
		goto fallback;
	format = gsw_gdi_format(destination);
	if(source_needed &&
	   (!gsw_gdi_device_valid(source, source_x, source_y, width, height) ||
	    source->deBitsPixel != destination->deBitsPixel ||
	    gsw_gdi_format(source) != format))
		goto fallback;

	gsw_gdi_command.header.opcode = GSW_VGA_OPCODE_GDI_BLT;
	gsw_gdi_command.flags = 0;
	gsw_gdi_command.destination_offset = destination->deBitsOffset;
	gsw_gdi_command.destination_pitch = destination->deDeltaScan;
	gsw_gdi_command.destination_x = destination_x;
	gsw_gdi_command.destination_y = destination_y;
	gsw_gdi_command.width = width;
	gsw_gdi_command.height = height;
	gsw_gdi_command.format = format;
	gsw_gdi_command.rop3 = truth;
	if(source_needed)
	{
		gsw_gdi_command.flags |= GSW_GDI_SOURCE_VALID;
		gsw_gdi_command.source_offset = source->deBitsOffset;
		gsw_gdi_command.source_pitch = source->deDeltaScan;
		gsw_gdi_command.source_x = source_x;
		gsw_gdi_command.source_y = source_y;
	}
	if(pattern_needed && !gsw_gdi_pattern(&gsw_gdi_command, brush, destination->deBitsPixel))
		goto fallback;

	gsw_gdi_cursor_begin(
		destination, destination_x, destination_y, source, source_x, source_y,
		width, height, source_needed
	);
	submitted = GSW_PM16_submit(&gsw_gdi_command);
	gsw_gdi_cursor_end(destination, source, source_needed);
	if(submitted) return TRUE;

fallback:
	return DIB_BitBlt(
		destination, destination_x, destination_y, source_device, source_x, source_y,
		width, height, rop3, brush, draw_mode
	);
}
