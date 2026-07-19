/* SPDX-License-Identifier: GPL-3.0-only */
#ifndef RETVRN99_GSWSOUND_WIN16_MMDDK_H
#define RETVRN99_GSWSOUND_WIN16_MMDDK_H

/*
 * Narrow Windows 98 multimedia-driver Interface for the 16-bit DRV.
 *
 * Open Watcom 1.9's Win16 mmsystem.h predates WAVEFORMATEX and the mixer
 * API. Message values and field order below were cross-checked against the
 * hash-pinned, public-domain MinGW-w64 mmddk.h/mmeapi.h declarations named
 * by interface-inputs.lock.json. This is an original Win16 adaptation: all
 * added types are GSW-prefixed, pointer-bearing structures use far pointers,
 * and Win16 UINT/handle/version fields remain 16-bit.
 *
 * Win16 multimedia structures use one-byte packing. The size assertions are
 * intentional build gates: compiling this file with a 32-bit data model, a
 * near-pointer model, or a different public ABI must fail rather than create
 * a loadable but corrupt driver.
 */

#include <windows.h>
#include <mmsystem.h>

#include "../include/gswsound_types.h"

typedef UINT GSW_MMRESULT;
typedef UINT GSW_HMIXER;

/* DriverCallback consumes low-word DCB_* values, not CALLBACK_* open flags. */
#define GSW_DRIVER_CALLBACK_FLAGS(flags) \
    ((UINT)(((flags) & CALLBACK_TYPEMASK) >> 16))

#ifndef MM_UNMAPPED
#define MM_UNMAPPED 0xFFFFU
#endif

#ifndef WAVE_FORMAT_DIRECT
#define WAVE_FORMAT_DIRECT 0x00000008UL
#endif

#ifndef CALLBACK_EVENT
#define CALLBACK_EVENT 0x00050000UL
#endif

#ifndef DRV_QUERYDRVENTRY
#define DRV_QUERYDRVENTRY (DRV_RESERVED + 1)
#endif
#ifndef DRV_QUERYDSOUNDIFACE
#define DRV_QUERYDSOUNDIFACE (DRV_RESERVED + 20)
#endif

/* WinMM sends these lifecycle messages to every low-level entry point. */
#ifndef DRVM_INIT
#define DRVM_INIT    100
#define DRVM_EXIT    101
#define DRVM_DISABLE 102
#define DRVM_ENABLE  103
#endif

#ifndef WODM_GETNUMDEVS
#define WODM_INIT       DRVM_INIT
#define WODM_GETNUMDEVS 3
#define WODM_GETDEVCAPS 4
#define WODM_OPEN 5
#define WODM_CLOSE 6
#define WODM_PREPARE 7
#define WODM_UNPREPARE 8
#define WODM_WRITE 9
#define WODM_PAUSE 10
#define WODM_RESTART 11
#define WODM_RESET 12
#define WODM_GETPOS 13
#define WODM_GETPITCH 14
#define WODM_SETPITCH 15
#define WODM_GETVOLUME 16
#define WODM_SETVOLUME 17
#define WODM_GETPLAYBACKRATE 18
#define WODM_SETPLAYBACKRATE 19
#define WODM_BREAKLOOP 20
#define WODM_PREFERRED 21
#endif

#ifndef MXDM_BASE
#define MXDM_BASE 1
#endif
#ifndef MXDM_INIT
#define MXDM_INIT DRVM_INIT
#endif
#ifndef MXDM_GETNUMDEVS
#define MXDM_GETNUMDEVS (MXDM_BASE + 0)
#define MXDM_GETDEVCAPS (MXDM_BASE + 1)
#define MXDM_OPEN (MXDM_BASE + 2)
#define MXDM_CLOSE (MXDM_BASE + 3)
#define MXDM_GETLINEINFO (MXDM_BASE + 4)
#define MXDM_GETLINECONTROLS (MXDM_BASE + 5)
#define MXDM_GETCONTROLDETAILS (MXDM_BASE + 6)
#define MXDM_SETCONTROLDETAILS (MXDM_BASE + 7)
#endif

#ifndef MIXER_SHORT_NAME_CHARS
#define MIXER_SHORT_NAME_CHARS 16
#define MIXER_LONG_NAME_CHARS 64
#endif

#ifndef MIXERR_BASE
#define MIXERR_BASE 1024
#endif
#ifndef MIXERR_INVALLINE
#define MIXERR_INVALLINE (MIXERR_BASE + 0)
#define MIXERR_INVALCONTROL (MIXERR_BASE + 1)
#define MIXERR_INVALVALUE (MIXERR_BASE + 2)
#endif

#ifndef MM_MIXM_LINE_CHANGE
#define MM_MIXM_LINE_CHANGE 0x03D0
#define MM_MIXM_CONTROL_CHANGE 0x03D1
#endif

#ifndef MIXERLINE_LINEF_ACTIVE
#define MIXERLINE_LINEF_ACTIVE 0x00000001UL
#define MIXERLINE_LINEF_SOURCE 0x80000000UL
#endif
#ifndef MIXERLINE_COMPONENTTYPE_DST_SPEAKERS
#define MIXERLINE_COMPONENTTYPE_DST_SPEAKERS 0x00000004UL
#define MIXERLINE_COMPONENTTYPE_SRC_WAVEOUT 0x00001008UL
#endif
#ifndef MIXERLINE_TARGETTYPE_WAVEOUT
#define MIXERLINE_TARGETTYPE_WAVEOUT 1
#endif

#ifndef MIXER_GETLINEINFOF_DESTINATION
#define MIXER_GETLINEINFOF_DESTINATION 0x00000000UL
#define MIXER_GETLINEINFOF_SOURCE 0x00000001UL
#define MIXER_GETLINEINFOF_LINEID 0x00000002UL
#define MIXER_GETLINEINFOF_COMPONENTTYPE 0x00000003UL
#define MIXER_GETLINEINFOF_TARGETTYPE 0x00000004UL
#define MIXER_GETLINEINFOF_QUERYMASK 0x0000000FUL
#endif

#ifndef MIXERCONTROL_CONTROLF_UNIFORM
#define MIXERCONTROL_CONTROLF_UNIFORM 0x00000001UL
#endif
#ifndef MIXERCONTROL_CONTROLTYPE_VOLUME
#define MIXERCONTROL_CONTROLTYPE_VOLUME 0x50030001UL
#endif

#ifndef MIXER_GETLINECONTROLSF_ALL
#define MIXER_GETLINECONTROLSF_ALL 0x00000000UL
#define MIXER_GETLINECONTROLSF_ONEBYID 0x00000001UL
#define MIXER_GETLINECONTROLSF_ONEBYTYPE 0x00000002UL
#define MIXER_GETLINECONTROLSF_QUERYMASK 0x0000000FUL
#endif

#ifndef MIXER_GETCONTROLDETAILSF_VALUE
#define MIXER_GETCONTROLDETAILSF_VALUE 0x00000000UL
#define MIXER_GETCONTROLDETAILSF_QUERYMASK 0x0000000FUL
#endif
#ifndef MIXER_SETCONTROLDETAILSF_VALUE
#define MIXER_SETCONTROLDETAILSF_VALUE 0x00000000UL
#define MIXER_SETCONTROLDETAILSF_QUERYMASK 0x0000000FUL
#endif

#pragma pack(push, 1)
typedef struct GSW_WAVEFORMATEX {
    WORD wFormatTag;
    WORD nChannels;
    DWORD nSamplesPerSec;
    DWORD nAvgBytesPerSec;
    WORD nBlockAlign;
    WORD wBitsPerSample;
    WORD cbSize;
} GSW_WAVEFORMATEX, FAR *GSW_LPWAVEFORMATEX;

typedef struct GSW_WAVEOPENDESC {
    HWAVEOUT hWave;
    GSW_LPWAVEFORMATEX lpFormat;
    DWORD dwCallback;
    DWORD dwInstance;
    UINT uMappedDeviceID;
    DWORD dnDevNode;
} GSW_WAVEOPENDESC, FAR *GSW_LPWAVEOPENDESC;

typedef struct GSW_MIXEROPENDESC {
    GSW_HMIXER hmx;
    void FAR *pReserved0;
    DWORD dwCallback;
    DWORD dwInstance;
    DWORD dnDevNode;
} GSW_MIXEROPENDESC, FAR *GSW_LPMIXEROPENDESC;

typedef struct GSW_MIXERCAPS {
    WORD wMid;
    WORD wPid;
    WORD vDriverVersion;
    char szPname[MAXPNAMELEN];
    DWORD fdwSupport;
    DWORD cDestinations;
} GSW_MIXERCAPS, FAR *GSW_LPMIXERCAPS;

typedef struct GSW_MIXERLINE {
    DWORD cbStruct;
    DWORD dwDestination;
    DWORD dwSource;
    DWORD dwLineID;
    DWORD fdwLine;
    DWORD dwUser;
    DWORD dwComponentType;
    DWORD cChannels;
    DWORD cConnections;
    DWORD cControls;
    char szShortName[MIXER_SHORT_NAME_CHARS];
    char szName[MIXER_LONG_NAME_CHARS];
    struct {
        DWORD dwType;
        DWORD dwDeviceID;
        WORD wMid;
        WORD wPid;
        WORD vDriverVersion;
        char szPname[MAXPNAMELEN];
    } Target;
} GSW_MIXERLINE, FAR *GSW_LPMIXERLINE;

typedef struct GSW_MIXERCONTROL {
    DWORD cbStruct;
    DWORD dwControlID;
    DWORD dwControlType;
    DWORD fdwControl;
    DWORD cMultipleItems;
    char szShortName[MIXER_SHORT_NAME_CHARS];
    char szName[MIXER_LONG_NAME_CHARS];
    struct {
        DWORD dwMinimum;
        DWORD dwMaximum;
        DWORD reserved[4];
    } Bounds;
    struct {
        DWORD cSteps;
        DWORD reserved[5];
    } Metrics;
} GSW_MIXERCONTROL, FAR *GSW_LPMIXERCONTROL;

typedef struct GSW_MIXERLINECONTROLS {
    DWORD cbStruct;
    DWORD dwLineID;
    union {
        DWORD dwControlID;
        DWORD dwControlType;
    } Select;
    DWORD cControls;
    DWORD cbmxctrl;
    GSW_LPMIXERCONTROL pamxctrl;
} GSW_MIXERLINECONTROLS, FAR *GSW_LPMIXERLINECONTROLS;

typedef struct GSW_MIXERCONTROLDETAILS {
    DWORD cbStruct;
    DWORD dwControlID;
    DWORD cChannels;
    DWORD cMultipleItems;
    DWORD cbDetails;
    void FAR *paDetails;
} GSW_MIXERCONTROLDETAILS, FAR *GSW_LPMIXERCONTROLDETAILS;

typedef struct GSW_MIXERCONTROLDETAILS_UNSIGNED {
    DWORD dwValue;
} GSW_MIXERCONTROLDETAILS_UNSIGNED,
    FAR *GSW_LPMIXERCONTROLDETAILS_UNSIGNED;
#pragma pack(pop)

GSW_STATIC_ASSERT(gsw_win16_uint_is_2_bytes, sizeof(UINT) == 2);
GSW_STATIC_ASSERT(gsw_win16_far_pointer_is_4_bytes, sizeof(void FAR *) == 4);
GSW_STATIC_ASSERT(gsw_waveformatex_is_18_bytes, sizeof(GSW_WAVEFORMATEX) == 18);
GSW_STATIC_ASSERT(gsw_waveopendesc_is_20_bytes, sizeof(GSW_WAVEOPENDESC) == 20);
GSW_STATIC_ASSERT(gsw_mixeropendesc_is_18_bytes, sizeof(GSW_MIXEROPENDESC) == 18);
GSW_STATIC_ASSERT(gsw_mixercaps_is_46_bytes, sizeof(GSW_MIXERCAPS) == 46);
GSW_STATIC_ASSERT(gsw_mixerline_is_166_bytes, sizeof(GSW_MIXERLINE) == 166);
GSW_STATIC_ASSERT(gsw_mixercontrol_is_148_bytes, sizeof(GSW_MIXERCONTROL) == 148);
GSW_STATIC_ASSERT(
    gsw_mixerlinecontrols_is_24_bytes,
    sizeof(GSW_MIXERLINECONTROLS) == 24
);
GSW_STATIC_ASSERT(
    gsw_mixercontroldetails_is_24_bytes,
    sizeof(GSW_MIXERCONTROLDETAILS) == 24
);

BOOL FAR PASCAL DriverCallback(
    DWORD callback,
    UINT flags,
    HDRVR driver,
    UINT message,
    DWORD instance,
    DWORD parameter_one,
    DWORD parameter_two
);

#endif
