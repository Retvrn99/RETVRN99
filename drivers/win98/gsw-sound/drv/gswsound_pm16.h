/* SPDX-License-Identifier: GPL-3.0-only */
#ifndef RETVRN99_GSWSOUND_PM16_H
#define RETVRN99_GSWSOUND_PM16_H

#include "../include/gswsound_pm.h"

int gsw_sound_pm_connect(void);
GSW_SOUND_RESULT gsw_sound_pm_call(GSW_SOUND_PM_REQUEST __far *request);
gsw_u32 gsw_sound_pm_linear(const void __far *pointer, int *valid);

#endif
