/* SPDX-License-Identifier: GPL-3.0-only */
#include <windows.h>
#include <mmsystem.h>

#include "../include/gswsound_abi.h"
#include "../include/gswsound_pm.h"
#include "gswsound_mixer.h"
#include "gswsound_pm16.h"
#include "gswsound_win16_mmddk.h"

#define GSW_MIXER_CLIENT_CAPACITY 8
#define GSW_MIXER_LINE_SPEAKERS   0x1000UL
#define GSW_MIXER_LINE_WAVEOUT    0x1001UL
#define GSW_MIXER_CONTROL_MASTER  0x2000UL
#define GSW_MIXER_CONTROL_WAVE    0x2001UL
#define GSW_MIXER_VOLUME_MAX      0xFFFFUL

typedef struct GSW_MIXER_CLIENT {
    gsw_u8 open;
    GSW_HMIXER mixer;
    DWORD callback;
    DWORD callback_instance;
    UINT callback_flags;
} GSW_MIXER_CLIENT;

typedef struct GSW_MIXER_STATE {
    gsw_u8 initialized;
    gsw_u8 wave_active;
    gsw_u16 master_volume;
    gsw_u16 wave_volume;
    GSW_MIXER_CLIENT clients[GSW_MIXER_CLIENT_CAPACITY];
} GSW_MIXER_STATE;

static GSW_MIXER_STATE gsw_mixer;

static void gsw_mixer_zero(void FAR *destination, gsw_u32 bytes)
{
    gsw_u8 FAR *out = (gsw_u8 FAR *)destination;
    while (bytes != 0) {
        *out++ = 0;
        bytes--;
    }
}

static void gsw_mixer_request_init(
    GSW_SOUND_PM_REQUEST FAR *request,
    GSW_SOUND_PM_OPCODE opcode
)
{
    gsw_mixer_zero(request, sizeof(*request));
    request->size = sizeof(*request);
    request->version = GSW_SOUND_PM_API_VERSION;
    request->opcode = (gsw_u16)opcode;
}

static GSW_MMRESULT gsw_mixer_result_to_mm(GSW_SOUND_RESULT result)
{
    switch (result) {
    case GSW_SOUND_OK: return MMSYSERR_NOERROR;
    case GSW_SOUND_BUSY: return MMSYSERR_ALLOCATED;
    case GSW_SOUND_INVALID: return MMSYSERR_INVALPARAM;
    case GSW_SOUND_UNAVAILABLE: return MMSYSERR_NOTENABLED;
    default: return MMSYSERR_ERROR;
    }
}

void gsw_mixer_initialize(void)
{
    if (gsw_mixer.initialized) return;
    gsw_mixer_zero(&gsw_mixer, sizeof(gsw_mixer));
    gsw_mixer.master_volume = (gsw_u16)GSW_MIXER_VOLUME_MAX;
    gsw_mixer.wave_volume = (gsw_u16)GSW_MIXER_VOLUME_MAX;
    gsw_mixer.initialized = 1;
}

void gsw_mixer_shutdown(void)
{
    gsw_mixer_zero(&gsw_mixer, sizeof(gsw_mixer));
}

static DWORD gsw_mixer_num_devices(void)
{
    GSW_SOUND_PM_REQUEST request;
    gsw_mixer_request_init(&request, GSW_SOUND_PM_QUERY);
    if (gsw_sound_pm_call(&request) != GSW_SOUND_OK) return 0;
    return (request.capabilities & GSW_PCM_REQUIRED_CAPS) == GSW_PCM_REQUIRED_CAPS ? 1 : 0;
}

static void gsw_mixer_notify(DWORD message, DWORD identifier)
{
    int index;
    for (index = 0; index < GSW_MIXER_CLIENT_CAPACITY; index++) {
        GSW_MIXER_CLIENT *client = &gsw_mixer.clients[index];
        if (!client->open) continue;
        DriverCallback(
            client->callback,
            client->callback_flags,
            (HDRVR)client->mixer,
            message,
            client->callback_instance,
            identifier,
            0
        );
    }
}

void gsw_mixer_set_wave_active(int active)
{
    gsw_u8 normalized = active ? 1 : 0;
    gsw_mixer_initialize();
    if (gsw_mixer.wave_active == normalized) return;
    gsw_mixer.wave_active = normalized;
    gsw_mixer_notify(MM_MIXM_LINE_CHANGE, GSW_MIXER_LINE_WAVEOUT);
}

static GSW_MMRESULT gsw_mixer_program_gain(gsw_u16 master, gsw_u16 wave)
{
    GSW_SOUND_PM_REQUEST request;
    gsw_u32 effective = (
        (gsw_u32)master * (gsw_u32)wave + (GSW_MIXER_VOLUME_MAX / 2)
    ) / GSW_MIXER_VOLUME_MAX;
    gsw_mixer_request_init(&request, GSW_SOUND_PM_SET_GAIN);
    request.gain_q16 = effective + (effective >= 0x8000UL ? 1 : 0);
    return gsw_mixer_result_to_mm(gsw_sound_pm_call(&request));
}

static GSW_MMRESULT gsw_mixer_set_control(DWORD control_id, DWORD value)
{
    GSW_MMRESULT result;
    gsw_u16 master;
    gsw_u16 wave;
    if (value > GSW_MIXER_VOLUME_MAX) return MIXERR_INVALVALUE;
    gsw_mixer_initialize();
    master = gsw_mixer.master_volume;
    wave = gsw_mixer.wave_volume;
    if (control_id == GSW_MIXER_CONTROL_MASTER) master = (gsw_u16)value;
    else if (control_id == GSW_MIXER_CONTROL_WAVE) wave = (gsw_u16)value;
    else return MIXERR_INVALCONTROL;
    if (master == gsw_mixer.master_volume && wave == gsw_mixer.wave_volume)
        return MMSYSERR_NOERROR;
    result = gsw_mixer_program_gain(master, wave);
    if (result != MMSYSERR_NOERROR) return result;
    gsw_mixer.master_volume = master;
    gsw_mixer.wave_volume = wave;
    gsw_mixer_notify(MM_MIXM_CONTROL_CHANGE, control_id);
    return MMSYSERR_NOERROR;
}

GSW_MMRESULT gsw_mixer_get_wave_volume(DWORD FAR *volume)
{
    gsw_u32 value;
    if (volume == 0) return MMSYSERR_INVALPARAM;
    gsw_mixer_initialize();
    value = gsw_mixer.wave_volume;
    *volume = value | (value << 16);
    return MMSYSERR_NOERROR;
}

GSW_MMRESULT gsw_mixer_set_wave_volume(DWORD volume)
{
    /* WAVECAPS_LRVOLUME is not advertised: WinMM defines the low word as authoritative. */
    return gsw_mixer_set_control(GSW_MIXER_CONTROL_WAVE, volume & 0xFFFFUL);
}

static GSW_MMRESULT gsw_mixer_get_caps(GSW_LPMIXERCAPS caps, DWORD bytes)
{
    GSW_MIXERCAPS local;
    gsw_u32 count;
    gsw_u8 FAR *out;
    const gsw_u8 *in;
    if (caps == 0 || bytes == 0) return MMSYSERR_INVALPARAM;
    gsw_mixer_zero(&local, sizeof(local));
    local.wMid = MM_UNMAPPED;
    local.wPid = 0;
    local.vDriverVersion = 0x0100;
    lstrcpy(local.szPname, "RETVRN99 GSW-Sound Mixer");
    local.fdwSupport = 0;
    local.cDestinations = 1;
    count = bytes < sizeof(local) ? bytes : sizeof(local);
    out = (gsw_u8 FAR *)caps;
    in = (const gsw_u8 *)&local;
    while (count-- != 0) *out++ = *in++;
    return MMSYSERR_NOERROR;
}

static void gsw_mixer_fill_line(GSW_LPMIXERLINE line, DWORD line_id)
{
    gsw_mixer_zero(line, sizeof(*line));
    line->cbStruct = sizeof(*line);
    line->dwDestination = 0;
    line->dwSource = 0;
    line->dwLineID = line_id;
    line->dwUser = 0;
    line->cChannels = 2;
    line->cControls = 1;
    line->Target.dwType = MIXERLINE_TARGETTYPE_WAVEOUT;
    line->Target.dwDeviceID = 0;
    line->Target.wMid = MM_UNMAPPED;
    line->Target.wPid = 0;
    line->Target.vDriverVersion = 0x0100;
    lstrcpy(line->Target.szPname, "RETVRN99 GSW-Sound");
    if (line_id == GSW_MIXER_LINE_SPEAKERS) {
        line->fdwLine = MIXERLINE_LINEF_ACTIVE;
        line->dwComponentType = MIXERLINE_COMPONENTTYPE_DST_SPEAKERS;
        line->cConnections = 1;
        lstrcpy(line->szShortName, "Master");
        lstrcpy(line->szName, "GSW-Sound Master Output");
    } else {
        line->fdwLine = MIXERLINE_LINEF_SOURCE;
        if (gsw_mixer.wave_active) line->fdwLine |= MIXERLINE_LINEF_ACTIVE;
        line->dwComponentType = MIXERLINE_COMPONENTTYPE_SRC_WAVEOUT;
        line->cConnections = 0;
        lstrcpy(line->szShortName, "Wave");
        lstrcpy(line->szName, "GSW-Sound Wave Output");
    }
}

static GSW_MMRESULT gsw_mixer_get_line_info(GSW_LPMIXERLINE line, DWORD flags)
{
    DWORD query;
    DWORD line_id;
    if (line == 0 || line->cbStruct < sizeof(*line)) return MMSYSERR_INVALPARAM;
    if ((flags & ~MIXER_GETLINEINFOF_QUERYMASK) != 0) return MMSYSERR_INVALFLAG;
    query = flags & MIXER_GETLINEINFOF_QUERYMASK;
    switch (query) {
    case MIXER_GETLINEINFOF_DESTINATION:
        if (line->dwDestination != 0) return MIXERR_INVALLINE;
        line_id = GSW_MIXER_LINE_SPEAKERS;
        break;
    case MIXER_GETLINEINFOF_SOURCE:
        if (line->dwDestination != 0 || line->dwSource != 0) return MIXERR_INVALLINE;
        line_id = GSW_MIXER_LINE_WAVEOUT;
        break;
    case MIXER_GETLINEINFOF_LINEID:
        if (line->dwLineID != GSW_MIXER_LINE_SPEAKERS &&
            line->dwLineID != GSW_MIXER_LINE_WAVEOUT)
            return MIXERR_INVALLINE;
        line_id = line->dwLineID;
        break;
    case MIXER_GETLINEINFOF_COMPONENTTYPE:
        if (line->dwComponentType == MIXERLINE_COMPONENTTYPE_DST_SPEAKERS)
            line_id = GSW_MIXER_LINE_SPEAKERS;
        else if (line->dwComponentType == MIXERLINE_COMPONENTTYPE_SRC_WAVEOUT)
            line_id = GSW_MIXER_LINE_WAVEOUT;
        else return MIXERR_INVALLINE;
        break;
    case MIXER_GETLINEINFOF_TARGETTYPE:
        if (line->Target.dwType != MIXERLINE_TARGETTYPE_WAVEOUT ||
            line->Target.dwDeviceID != 0)
            return MIXERR_INVALLINE;
        line_id = GSW_MIXER_LINE_WAVEOUT;
        break;
    default:
        return MMSYSERR_INVALFLAG;
    }
    gsw_mixer_fill_line(line, line_id);
    return MMSYSERR_NOERROR;
}

static DWORD gsw_mixer_line_control(DWORD line_id)
{
    if (line_id == GSW_MIXER_LINE_SPEAKERS) return GSW_MIXER_CONTROL_MASTER;
    if (line_id == GSW_MIXER_LINE_WAVEOUT) return GSW_MIXER_CONTROL_WAVE;
    return 0;
}

static DWORD gsw_mixer_control_line(DWORD control_id)
{
    if (control_id == GSW_MIXER_CONTROL_MASTER) return GSW_MIXER_LINE_SPEAKERS;
    if (control_id == GSW_MIXER_CONTROL_WAVE) return GSW_MIXER_LINE_WAVEOUT;
    return 0;
}

static void gsw_mixer_fill_control(GSW_LPMIXERCONTROL control, DWORD control_id)
{
    gsw_mixer_zero(control, sizeof(*control));
    control->cbStruct = sizeof(*control);
    control->dwControlID = control_id;
    control->dwControlType = MIXERCONTROL_CONTROLTYPE_VOLUME;
    control->fdwControl = MIXERCONTROL_CONTROLF_UNIFORM;
    control->cMultipleItems = 0;
    control->Bounds.dwMinimum = 0;
    control->Bounds.dwMaximum = GSW_MIXER_VOLUME_MAX;
    control->Metrics.cSteps = GSW_MIXER_VOLUME_MAX + 1;
    if (control_id == GSW_MIXER_CONTROL_MASTER) {
        lstrcpy(control->szShortName, "Master");
        lstrcpy(control->szName, "Master Volume");
    } else {
        lstrcpy(control->szShortName, "Wave");
        lstrcpy(control->szName, "Wave Volume");
    }
}

static GSW_MMRESULT gsw_mixer_get_line_controls(
    GSW_LPMIXERLINECONTROLS controls,
    DWORD flags
)
{
    DWORD query;
    DWORD control_id;
    DWORD line_id;
    if (controls == 0 || controls->cbStruct < sizeof(*controls) ||
        controls->pamxctrl == 0 || controls->cbmxctrl < sizeof(GSW_MIXERCONTROL))
        return MMSYSERR_INVALPARAM;
    if ((flags & ~MIXER_GETLINECONTROLSF_QUERYMASK) != 0)
        return MMSYSERR_INVALFLAG;
    query = flags & MIXER_GETLINECONTROLSF_QUERYMASK;
    switch (query) {
    case MIXER_GETLINECONTROLSF_ALL:
        if (controls->cControls < 1) return MMSYSERR_INVALPARAM;
        control_id = gsw_mixer_line_control(controls->dwLineID);
        if (control_id == 0) return MIXERR_INVALLINE;
        break;
    case MIXER_GETLINECONTROLSF_ONEBYID:
        if (controls->cControls != 1) return MMSYSERR_INVALPARAM;
        control_id = controls->Select.dwControlID;
        line_id = gsw_mixer_control_line(control_id);
        if (line_id == 0) return MIXERR_INVALCONTROL;
        break;
    case MIXER_GETLINECONTROLSF_ONEBYTYPE:
        if (controls->cControls != 1) return MMSYSERR_INVALPARAM;
        if (controls->Select.dwControlType != MIXERCONTROL_CONTROLTYPE_VOLUME)
            return MIXERR_INVALCONTROL;
        control_id = gsw_mixer_line_control(controls->dwLineID);
        if (control_id == 0) return MIXERR_INVALLINE;
        break;
    default:
        return MMSYSERR_INVALFLAG;
    }
    controls->cControls = 1;
    gsw_mixer_fill_control(controls->pamxctrl, control_id);
    return MMSYSERR_NOERROR;
}

static GSW_MMRESULT gsw_mixer_validate_details(
    GSW_LPMIXERCONTROLDETAILS details,
    DWORD flags,
    DWORD query_mask
)
{
    if (details == 0 || details->cbStruct < sizeof(*details) ||
        details->paDetails == 0 || details->cChannels != 1 ||
        details->cMultipleItems != 0 ||
        details->cbDetails != sizeof(GSW_MIXERCONTROLDETAILS_UNSIGNED))
        return MMSYSERR_INVALPARAM;
    if ((flags & ~query_mask) != 0) return MMSYSERR_INVALFLAG;
    if (gsw_mixer_control_line(details->dwControlID) == 0)
        return MIXERR_INVALCONTROL;
    return MMSYSERR_NOERROR;
}

static GSW_MMRESULT gsw_mixer_get_control_details(
    GSW_LPMIXERCONTROLDETAILS details,
    DWORD flags
)
{
    GSW_LPMIXERCONTROLDETAILS_UNSIGNED value;
    GSW_MMRESULT result = gsw_mixer_validate_details(
        details,
        flags,
        MIXER_GETCONTROLDETAILSF_QUERYMASK
    );
    if (result != MMSYSERR_NOERROR) return result;
    if ((flags & MIXER_GETCONTROLDETAILSF_QUERYMASK) != MIXER_GETCONTROLDETAILSF_VALUE)
        return MMSYSERR_INVALFLAG;
    value = (GSW_LPMIXERCONTROLDETAILS_UNSIGNED)details->paDetails;
    value->dwValue = details->dwControlID == GSW_MIXER_CONTROL_MASTER ?
        gsw_mixer.master_volume : gsw_mixer.wave_volume;
    return MMSYSERR_NOERROR;
}

static GSW_MMRESULT gsw_mixer_set_control_details(
    GSW_LPMIXERCONTROLDETAILS details,
    DWORD flags
)
{
    GSW_LPMIXERCONTROLDETAILS_UNSIGNED value;
    GSW_MMRESULT result = gsw_mixer_validate_details(
        details,
        flags,
        MIXER_SETCONTROLDETAILSF_QUERYMASK
    );
    if (result != MMSYSERR_NOERROR) return result;
    if ((flags & MIXER_SETCONTROLDETAILSF_QUERYMASK) != MIXER_SETCONTROLDETAILSF_VALUE)
        return MMSYSERR_INVALFLAG;
    value = (GSW_LPMIXERCONTROLDETAILS_UNSIGNED)details->paDetails;
    return gsw_mixer_set_control(details->dwControlID, value->dwValue);
}

static GSW_MMRESULT gsw_mixer_open(
    DWORD dwUser,
    GSW_LPMIXEROPENDESC description,
    DWORD flags
)
{
    int index;
    GSW_MIXER_CLIENT *client = 0;
    DWORD callback_type;
    if (dwUser == 0 || description == 0 || description->pReserved0 != 0)
        return MMSYSERR_INVALPARAM;
    if ((flags & ~CALLBACK_TYPEMASK) != 0) return MMSYSERR_INVALFLAG;
    callback_type = flags & CALLBACK_TYPEMASK;
    if (callback_type != CALLBACK_NULL && callback_type != CALLBACK_WINDOW &&
        callback_type != CALLBACK_TASK && callback_type != CALLBACK_FUNCTION &&
        callback_type != CALLBACK_EVENT)
        return MMSYSERR_INVALFLAG;
    if (gsw_mixer_num_devices() == 0) return MMSYSERR_NOTENABLED;
    for (index = 0; index < GSW_MIXER_CLIENT_CAPACITY; index++) {
        if (!gsw_mixer.clients[index].open) {
            client = &gsw_mixer.clients[index];
            break;
        }
    }
    if (client == 0) return MMSYSERR_ALLOCATED;
    gsw_mixer_zero(client, sizeof(*client));
    client->open = 1;
    client->mixer = description->hmx;
    client->callback = description->dwCallback;
    client->callback_instance = description->dwInstance;
    client->callback_flags = GSW_DRIVER_CALLBACK_FLAGS(flags);
    *(DWORD FAR *)dwUser = (DWORD)(void FAR *)client;
    return MMSYSERR_NOERROR;
}

static GSW_MIXER_CLIENT *gsw_mixer_client_from_user(DWORD dwUser)
{
    int index;
    for (index = 0; index < GSW_MIXER_CLIENT_CAPACITY; index++) {
        GSW_MIXER_CLIENT *client = &gsw_mixer.clients[index];
        if (client->open && dwUser == (DWORD)(void FAR *)client) return client;
    }
    return 0;
}

static GSW_MMRESULT gsw_mixer_close(DWORD dwUser)
{
    GSW_MIXER_CLIENT *client = gsw_mixer_client_from_user(dwUser);
    if (client == 0) return MMSYSERR_INVALHANDLE;
    gsw_mixer_zero(client, sizeof(*client));
    return MMSYSERR_NOERROR;
}

DWORD gsw_mixer_message(
    UINT device_id,
    UINT message,
    DWORD dwUser,
    DWORD parameter_one,
    DWORD parameter_two
)
{
    switch (message) {
    case MXDM_INIT:
    case DRVM_EXIT:
    case DRVM_DISABLE:
    case DRVM_ENABLE:
        return MMSYSERR_NOERROR;
    }
    gsw_mixer_initialize();
    if (device_id != 0 && message != MXDM_GETNUMDEVS) return MMSYSERR_BADDEVICEID;
    switch (message) {
    case MXDM_GETNUMDEVS:
        return gsw_mixer_num_devices();
    case MXDM_GETDEVCAPS:
        return gsw_mixer_get_caps((GSW_LPMIXERCAPS)parameter_one, parameter_two);
    case MXDM_OPEN:
        return gsw_mixer_open(
            dwUser,
            (GSW_LPMIXEROPENDESC)parameter_one,
            parameter_two
        );
    case MXDM_CLOSE:
        return gsw_mixer_close(dwUser);
    case MXDM_GETLINEINFO:
        return gsw_mixer_get_line_info((GSW_LPMIXERLINE)parameter_one, parameter_two);
    case MXDM_GETLINECONTROLS:
        return gsw_mixer_get_line_controls(
            (GSW_LPMIXERLINECONTROLS)parameter_one,
            parameter_two
        );
    case MXDM_GETCONTROLDETAILS:
        return gsw_mixer_get_control_details(
            (GSW_LPMIXERCONTROLDETAILS)parameter_one,
            parameter_two
        );
    case MXDM_SETCONTROLDETAILS:
        return gsw_mixer_set_control_details(
            (GSW_LPMIXERCONTROLDETAILS)parameter_one,
            parameter_two
        );
    default:
        return MMSYSERR_NOTSUPPORTED;
    }
}
