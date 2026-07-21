/* SPDX-License-Identifier: GPL-3.0-only */

#ifndef GSW_SVGA_WINSYS_H
#define GSW_SVGA_WINSYS_H

#include "svga_winsys.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct pipe_screen *
(*gsw_svga_screen_create_fn)(struct svga_winsys_screen *sws);

struct svga_winsys_screen *
gsw_svga_winsys_screen_create(void);

struct pipe_screen *
gsw_svga_winsys_screen_try_create(gsw_svga_screen_create_fn create_screen);

void
gsw_svga_winsys_screen_destroy(struct svga_winsys_screen *sws);

uint64_t
gsw_svga_winsys_abi_submission_count(const struct svga_winsys_screen *sws);

#ifdef __cplusplus
}
#endif

#endif
