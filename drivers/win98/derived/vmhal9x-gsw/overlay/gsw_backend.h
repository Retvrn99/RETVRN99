/* SPDX-License-Identifier: GPL-3.0-only */
#ifndef RETVRN99_GSW_BACKEND_H
#define RETVRN99_GSW_BACKEND_H

#include <windows.h>
#include <ddraw.h>
#include <ddrawi.h>
#include "vmdahal32.h"
#include "gsw_ddraw_abi.h"

BOOL GSWDD_load(VMDAHAL_t *hal);
DWORD GSWDD_surface(VMDAHAL_t *hal, LPDDRAWI_DDRAWSURFACE_LCL surface);
BOOL GSWDD_unregister(DWORD surface_id);
BOOL GSWDD_fill(const GSWDDFill *request);
BOOL GSWDD_blt(const GSWDDBlt *request);
BOOL GSWDD_present(DWORD surface_id);
BOOL GSWDD_dirty(const GSWDDDirty *request);
BOOL GSWDD_rop_supported(DWORD rop3);
DWORD GSWDD_surface_bpp(VMDAHAL_t *hal, LPDDRAWI_DDRAWSURFACE_LCL surface);
void GSWDD_lock_rect(DWORD surface_id, const RECTL *rect, BOOL read_only);
BOOL GSWDD_unlock_rect(DWORD surface_id, GSWDDDirty *dirty);

#endif
