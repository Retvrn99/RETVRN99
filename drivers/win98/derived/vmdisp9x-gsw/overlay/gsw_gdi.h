/* SPDX-License-Identifier: GPL-3.0-only */
#ifndef RETVRN99_GSW_GDI_H
#define RETVRN99_GSW_GDI_H

#include "gsw_gdi_abi.h"

DWORD GSW_PM16_capabilities(void);
BOOL GSW_PM16_submit(const GSWGdiBltCommand __far *request);
BOOL WINAPI __loadds GSW_BitBlt(
	LPDIBENGINE destination,
	WORD destination_x,
	WORD destination_y,
	LPPDEVICE source,
	WORD source_x,
	WORD source_y,
	WORD width,
	WORD height,
	DWORD rop3,
	LPBRUSH brush,
	LPDRAWMODE draw_mode
);

#endif
