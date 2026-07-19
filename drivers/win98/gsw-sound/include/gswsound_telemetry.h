/* SPDX-License-Identifier: GPL-3.0-only */
#ifndef RETVRN99_GSWSOUND_TELEMETRY_H
#define RETVRN99_GSWSOUND_TELEMETRY_H

#include "gswsound_types.h"

#define GSW_SOUND_TELEMETRY_MAGIC         0x54575347UL /* "GSWT" */
#define GSW_SOUND_TELEMETRY_VERSION       1UL
#define GSW_SOUND_TELEMETRY_REGISTRY_KEY  "Software\\RETVRN99\\GSW-Sound"
#define GSW_SOUND_TELEMETRY_VALUE_NAME    "StartTelemetry"

typedef enum GSW_SOUND_TELEMETRY_CHECKPOINT {
    GSW_SOUND_TELEMETRY_SEED = 0,
    GSW_SOUND_TELEMETRY_PNP = 1,
    GSW_SOUND_TELEMETRY_REGISTER = 2,
    GSW_SOUND_TELEMETRY_START = 3,
    GSW_SOUND_TELEMETRY_RESOURCE = 4,
    GSW_SOUND_TELEMETRY_MAP = 5,
    GSW_SOUND_TELEMETRY_PAGE = 6,
    GSW_SOUND_TELEMETRY_BIND = 7,
    GSW_SOUND_TELEMETRY_IRQ = 8,
    GSW_SOUND_TELEMETRY_MODE = 9,
    GSW_SOUND_TELEMETRY_SUCCESS = 10
} GSW_SOUND_TELEMETRY_CHECKPOINT;

typedef enum GSW_SOUND_TELEMETRY_OUTCOME {
    GSW_SOUND_TELEMETRY_NOT_RUN = 0,
    GSW_SOUND_TELEMETRY_ENTER = 1,
    GSW_SOUND_TELEMETRY_PASSED = 2,
    GSW_SOUND_TELEMETRY_FAILED = 3
} GSW_SOUND_TELEMETRY_OUTCOME;

#pragma pack(push)
#pragma pack(1)
typedef struct GSW_SOUND_START_TELEMETRY {
    gsw_u32 magic;
    gsw_u32 version;
    gsw_u32 record_bytes;
    gsw_u32 sequence;
    gsw_u32 checkpoint;
    gsw_u32 outcome;
    gsw_u32 detail0;
    gsw_u32 detail1;
} GSW_SOUND_START_TELEMETRY;
#pragma pack(pop)

typedef char gsw_sound_telemetry_must_be_32_bytes[
    sizeof(GSW_SOUND_START_TELEMETRY) == 32 ? 1 : -1
];

#endif
