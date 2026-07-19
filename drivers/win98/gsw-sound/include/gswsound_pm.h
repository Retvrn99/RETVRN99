/* SPDX-License-Identifier: GPL-3.0-only */
#ifndef RETVRN99_GSWSOUND_PM_H
#define RETVRN99_GSWSOUND_PM_H

#include "gswsound_types.h"

#define GSW_SOUND_PM_API_VERSION 1
#define GSW_SOUND_MAX_SUBMIT_BYTES (32UL * 1024UL)
#define GSW_SOUND_COMPLETION_CAPACITY 32
#define GSW_SOUND_VXD_NAME "GSWSOUND"

typedef enum GSW_SOUND_PM_OPCODE {
    GSW_SOUND_PM_QUERY = 0,
    GSW_SOUND_PM_OPEN = 1,
    GSW_SOUND_PM_CLOSE = 2,
    GSW_SOUND_PM_SUBMIT = 3,
    GSW_SOUND_PM_POLL = 4,
    GSW_SOUND_PM_PAUSE = 5,
    GSW_SOUND_PM_RESTART = 6,
    GSW_SOUND_PM_RESET = 7,
    GSW_SOUND_PM_GET_POSITION = 8,
    GSW_SOUND_PM_GET_GAIN = 9,
    GSW_SOUND_PM_SET_GAIN = 10
} GSW_SOUND_PM_OPCODE;

typedef enum GSW_SOUND_RESULT {
    GSW_SOUND_OK = 0,
    GSW_SOUND_UNAVAILABLE = 1,
    GSW_SOUND_INVALID = 2,
    GSW_SOUND_BUSY = 3,
    GSW_SOUND_WOULD_BLOCK = 4,
    GSW_SOUND_IO_ERROR = 5,
    GSW_SOUND_NO_COMPLETION = 6
} GSW_SOUND_RESULT;

#define GSW_SOUND_SUBMIT_END_OF_BUFFER (1UL << 0)

#pragma pack(push, 1)
typedef struct GSW_SOUND_PM_REQUEST {
    gsw_u16 size;
    gsw_u16 version;
    gsw_u16 opcode;
    gsw_u16 reserved_zero;
    gsw_u32 stream_id;
    gsw_u32 flags;
    gsw_u32 sample_rate;
    gsw_u16 channels;
    gsw_u16 bits_per_sample;
    gsw_u32 buffer_linear;
    gsw_u32 buffer_bytes;
    gsw_u32 user_token;
    gsw_u32 accepted_bytes;
    gsw_u32 completed_token;
    gsw_u32 position_low;
    gsw_u32 position_high;
    gsw_u32 gain_q16;
    gsw_u32 capabilities;
    gsw_u32 result;
} GSW_SOUND_PM_REQUEST;
#pragma pack(pop)

GSW_STATIC_ASSERT(gsw_sound_pm_request_is_64_bytes, sizeof(GSW_SOUND_PM_REQUEST) == 64);

#endif
