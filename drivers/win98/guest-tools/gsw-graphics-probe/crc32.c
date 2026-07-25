/* SPDX-License-Identifier: GPL-3.0-only */

#include "gswgfx.h"

DWORD gsw_crc32(const BYTE *pixels, DWORD count)
{
	DWORD crc = 0xFFFFFFFFUL;
	DWORD index;
	if(pixels == NULL || count == 0) return 0;
	for(index = 0; index < count; index++)
	{
		DWORD bit;
		crc ^= pixels[index];
		for(bit = 0; bit < 8; bit++)
			crc = (crc >> 1) ^ (0xEDB88320UL & (DWORD)(0UL - (crc & 1UL)));
	}
	return crc ^ 0xFFFFFFFFUL;
}
