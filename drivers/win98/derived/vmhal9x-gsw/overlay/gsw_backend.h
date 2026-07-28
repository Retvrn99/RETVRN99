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
BOOL GSWDD_unregister(VMDAHAL_t *hal, DWORD surface_id);
BOOL GSWDD_fill(const GSWDDFill *request);
BOOL GSWDD_blt(const GSWDDBlt *request);
BOOL GSWDD_present(DWORD surface_id);
BOOL GSWDD_dirty(const GSWDDDirty *request);
BOOL GSWDD_rop_supported(DWORD rop3);
DWORD GSWDD_surface_bpp(VMDAHAL_t *hal, LPDDRAWI_DDRAWSURFACE_LCL surface);
void GSWDD_lock_rect(DWORD surface_id, const RECTL *rect, BOOL read_only);
BOOL GSWDD_unlock_rect(DWORD surface_id, GSWDDDirty *dirty);

/* Host breadcrumbs for the DirectDraw entry points. A call that never returns
 * leaves no report behind, so the only way to see how far one reached is to
 * have the host record each step as it happens. Off unless the marker file
 * exists, and checked once. */
#define GSW_HAL_TRACE_MARKER "C:\\GSWGFX\\HALTRACE.TMP"
#define GSW_HAL_TRACE_LOCK 230
#define GSW_HAL_TRACE_LOCK_DONE 231
#define GSW_HAL_TRACE_UNLOCK 232
#define GSW_HAL_TRACE_FLIP 233
#define GSW_HAL_TRACE_LOCK_NO_SURFACE 234
#define GSW_HAL_TRACE_LOCK_BAD_RECT 235
#define GSW_HAL_TRACE_REGISTER 236
#define GSW_HAL_TRACE_REGISTER_DONE 237
void GSWDD_trace(BYTE label);

#endif
