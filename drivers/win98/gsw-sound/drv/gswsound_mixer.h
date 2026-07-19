/* SPDX-License-Identifier: GPL-3.0-only */
#ifndef RETVRN99_GSWSOUND_MIXER_H
#define RETVRN99_GSWSOUND_MIXER_H

#include "gswsound_win16_mmddk.h"

void gsw_mixer_initialize(void);
void gsw_mixer_shutdown(void);
void gsw_mixer_set_wave_active(int active);
GSW_MMRESULT gsw_mixer_get_wave_volume(DWORD FAR *volume);
GSW_MMRESULT gsw_mixer_set_wave_volume(DWORD volume);
DWORD gsw_mixer_message(
    UINT device_id,
    UINT message,
    DWORD dwUser,
    DWORD parameter_one,
    DWORD parameter_two
);

#endif
