/* SPDX-License-Identifier: GPL-3.0-only */
#include <windows.h>
#include <mmsystem.h>

#include "../include/gswsound_abi.h"
#include "../include/gswsound_pm.h"
#include "gswsound_mixer.h"
#include "gswsound_pm16.h"
#include "gswsound_win16_mmddk.h"

#define GSW_WAVE_QUEUE_CAPACITY 32
#define GSW_PUMP_PERIOD_MS 1
#define GSW_PUMP_WORK_LIMIT 64

typedef struct GSW_WAVE_BUFFER {
    LPWAVEHDR header;
    gsw_u32 buffer_linear;
    gsw_u32 buffer_bytes;
    gsw_u32 header_flags;
    gsw_u32 loop_count;
    gsw_u32 submitted_bytes;
    gsw_u32 token;
} GSW_WAVE_BUFFER;

typedef struct GSW_WAVE_PLAY {
    gsw_u32 token;
    gsw_u16 buffer_index;
    gsw_u16 loop_start_index;
    gsw_u16 loop_end_index;
    gsw_u8 complete_buffer;
    gsw_u8 release_loop;
} GSW_WAVE_PLAY;

typedef struct GSW_WAVE_INSTANCE {
    gsw_u8 open;
    gsw_u8 paused;
    gsw_u8 pumping;
    gsw_u8 queue_loop_open;
    gsw_u8 loop_active;
    gsw_u8 loop_break_requested;
    gsw_u8 break_next_loop;
    HWAVEOUT wave;
    DWORD callback;
    DWORD callback_instance;
    UINT callback_flags;
    gsw_u32 stream_id;
    gsw_u32 next_token;
    gsw_u32 sample_rate;
    gsw_u16 channels;
    gsw_u16 bits_per_sample;
    gsw_u16 frame_bytes;
    UINT timer_id;
    gsw_u8 timer_period_active;
    GSW_WAVE_BUFFER queue[GSW_WAVE_QUEUE_CAPACITY];
    gsw_u16 queue_read;
    gsw_u16 queue_write;
    gsw_u16 queue_count;
    gsw_u16 schedule_index;
    GSW_WAVE_PLAY plays[GSW_WAVE_QUEUE_CAPACITY];
    gsw_u16 play_read;
    gsw_u16 play_write;
    gsw_u16 play_count;
    gsw_u16 loop_start_index;
    gsw_u16 loop_release_pending;
    gsw_u32 loop_remaining;
} GSW_WAVE_INSTANCE;

typedef struct GSW_CALLBACK_CONTEXT {
    HWAVEOUT wave;
    DWORD callback;
    DWORD callback_instance;
    UINT callback_flags;
} GSW_CALLBACK_CONTEXT;

static GSW_WAVE_INSTANCE gsw_wave;

static void gsw_zero(void __far *destination, gsw_u32 bytes)
{
    gsw_u8 __far *out = (gsw_u8 __far *)destination;
    while (bytes != 0) {
        *out++ = 0;
        bytes--;
    }
}

static void gsw_request_init(GSW_SOUND_PM_REQUEST __far *request, GSW_SOUND_PM_OPCODE opcode)
{
    gsw_zero(request, sizeof(*request));
    request->size = sizeof(*request);
    request->version = GSW_SOUND_PM_API_VERSION;
    request->opcode = (gsw_u16)opcode;
}

static int gsw_format_supported(const GSW_WAVEFORMATEX FAR *format)
{
    gsw_u32 expected_rate;
    gsw_u16 expected_align;
    if (format == 0 || format->wFormatTag != WAVE_FORMAT_PCM ||
        (format->nChannels != 1 && format->nChannels != 2) ||
        (format->wBitsPerSample != 8 && format->wBitsPerSample != 16) ||
        (format->nSamplesPerSec != 11025UL && format->nSamplesPerSec != 22050UL &&
         format->nSamplesPerSec != 44100UL && format->nSamplesPerSec != 48000UL))
        return 0;
    expected_align = format->nChannels * (format->wBitsPerSample >> 3);
    expected_rate = format->nSamplesPerSec * expected_align;
    return format->nBlockAlign == expected_align && format->nAvgBytesPerSec == expected_rate;
}

static GSW_MMRESULT gsw_result_to_mm(GSW_SOUND_RESULT result)
{
    switch (result) {
    case GSW_SOUND_OK: return MMSYSERR_NOERROR;
    case GSW_SOUND_BUSY: return MMSYSERR_ALLOCATED;
    case GSW_SOUND_WOULD_BLOCK: return MMSYSERR_NOERROR;
    case GSW_SOUND_INVALID: return MMSYSERR_INVALPARAM;
    case GSW_SOUND_UNAVAILABLE: return MMSYSERR_NOTENABLED;
    default: return MMSYSERR_ERROR;
    }
}

static void gsw_capture_callback(GSW_CALLBACK_CONTEXT *context)
{
    context->wave = gsw_wave.wave;
    context->callback = gsw_wave.callback;
    context->callback_instance = gsw_wave.callback_instance;
    context->callback_flags = gsw_wave.callback_flags;
}

static void gsw_callback_with(
    const GSW_CALLBACK_CONTEXT *context,
    UINT message,
    DWORD parameter
)
{
    DriverCallback(
        context->callback,
        context->callback_flags,
        (HDRVR)context->wave,
        message,
        context->callback_instance,
        parameter,
        0
    );
}

static void gsw_callback(UINT message, DWORD parameter)
{
    GSW_CALLBACK_CONTEXT context;
    gsw_capture_callback(&context);
    gsw_callback_with(&context, message, parameter);
}

static gsw_u16 gsw_next_queue_index(gsw_u16 index)
{
    return (index + 1) % GSW_WAVE_QUEUE_CAPACITY;
}

static void gsw_return_header_with(
    const GSW_CALLBACK_CONTEXT *context,
    LPWAVEHDR header
)
{
    if (header == 0) return;
    header->dwFlags &= ~WHDR_INQUEUE;
    header->dwFlags |= WHDR_DONE;
    gsw_callback_with(context, WOM_DONE, (DWORD)header);
}

static int gsw_complete_head(gsw_u16 expected_index)
{
    GSW_WAVE_BUFFER *buffer;
    LPWAVEHDR header;
    GSW_CALLBACK_CONTEXT context;
    if (gsw_wave.queue_count == 0 || gsw_wave.queue_read != expected_index)
        return 0;
    buffer = &gsw_wave.queue[gsw_wave.queue_read];
    header = buffer->header;
    if (header == 0) return 0;
    gsw_capture_callback(&context);
    gsw_zero(buffer, sizeof(*buffer));
    gsw_wave.queue_read = gsw_next_queue_index(gsw_wave.queue_read);
    gsw_wave.queue_count--;
    if (gsw_wave.queue_count == 0) gsw_wave.schedule_index = gsw_wave.queue_write;
    gsw_return_header_with(&context, header);
    return 1;
}

static int gsw_complete_loop(gsw_u16 start_index, gsw_u16 end_index)
{
    GSW_CALLBACK_CONTEXT context;
    LPWAVEHDR headers[GSW_WAVE_QUEUE_CAPACITY];
    gsw_u16 current;
    gsw_u16 count = 0;
    gsw_u16 remaining;
    if (gsw_wave.queue_count == 0 || gsw_wave.queue_read != start_index) return 0;
    current = start_index;
    remaining = gsw_wave.queue_count;
    for (;;) {
        if (remaining == 0 || count == GSW_WAVE_QUEUE_CAPACITY ||
            gsw_wave.queue[current].header == 0)
            return 0;
        headers[count++] = gsw_wave.queue[current].header;
        if (current == end_index) break;
        current = gsw_next_queue_index(current);
        remaining--;
    }
    gsw_capture_callback(&context);
    for (current = 0; current < count; current++) {
        gsw_u16 index = gsw_wave.queue_read;
        gsw_zero(&gsw_wave.queue[index], sizeof(gsw_wave.queue[index]));
        gsw_wave.queue_read = gsw_next_queue_index(index);
        gsw_wave.queue_count--;
    }
    if (gsw_wave.queue_count == 0) gsw_wave.schedule_index = gsw_wave.queue_write;
    for (current = 0; current < count; current++)
        gsw_return_header_with(&context, headers[current]);
    return 1;
}

static void gsw_complete_all(void)
{
    GSW_CALLBACK_CONTEXT context;
    LPWAVEHDR headers[GSW_WAVE_QUEUE_CAPACITY];
    gsw_u16 index = gsw_wave.queue_read;
    gsw_u16 count = gsw_wave.queue_count;
    gsw_u16 header_count = 0;
    gsw_capture_callback(&context);
    while (header_count < count) {
        headers[header_count++] = gsw_wave.queue[index].header;
        index = gsw_next_queue_index(index);
    }
    gsw_zero(gsw_wave.queue, sizeof(gsw_wave.queue));
    gsw_zero(gsw_wave.plays, sizeof(gsw_wave.plays));
    gsw_wave.queue_read = 0;
    gsw_wave.queue_write = 0;
    gsw_wave.queue_count = 0;
    gsw_wave.schedule_index = 0;
    gsw_wave.play_read = 0;
    gsw_wave.play_write = 0;
    gsw_wave.play_count = 0;
    gsw_wave.queue_loop_open = 0;
    gsw_wave.loop_active = 0;
    gsw_wave.loop_break_requested = 0;
    gsw_wave.break_next_loop = 0;
    gsw_wave.loop_start_index = 0;
    gsw_wave.loop_remaining = 0;
    gsw_wave.loop_release_pending = 0;
    for (index = 0; index < header_count; index++)
        gsw_return_header_with(&context, headers[index]);
}

static void gsw_abort_queue(void)
{
    GSW_SOUND_PM_REQUEST request;
    if (gsw_wave.open) {
        gsw_request_init(&request, GSW_SOUND_PM_RESET);
        request.stream_id = gsw_wave.stream_id;
        (void)gsw_sound_pm_call(&request);
    }
    gsw_complete_all();
}

static void gsw_poll_completions(void)
{
    GSW_SOUND_PM_REQUEST request;
    int work = 0;
    while (gsw_wave.play_count != 0 && work++ < GSW_PUMP_WORK_LIMIT) {
        GSW_WAVE_PLAY completed;
        GSW_WAVE_PLAY *head = &gsw_wave.plays[gsw_wave.play_read];
        GSW_SOUND_RESULT result;
        gsw_request_init(&request, GSW_SOUND_PM_POLL);
        request.stream_id = gsw_wave.stream_id;
        result = gsw_sound_pm_call(&request);
        if (result == GSW_SOUND_NO_COMPLETION) break;
        if (result != GSW_SOUND_OK || request.completed_token != head->token) {
            gsw_abort_queue();
            break;
        }
        completed = *head;
        gsw_zero(head, sizeof(*head));
        gsw_wave.play_read = gsw_next_queue_index(gsw_wave.play_read);
        gsw_wave.play_count--;
        if (completed.complete_buffer &&
            !gsw_complete_head(completed.buffer_index)) {
            gsw_abort_queue();
            break;
        }
        if (completed.release_loop) {
            if (gsw_wave.loop_release_pending == 0) {
                gsw_abort_queue();
                break;
            }
            gsw_wave.loop_release_pending--;
            if (!gsw_complete_loop(
                    completed.loop_start_index,
                    completed.loop_end_index
                )) {
                gsw_abort_queue();
                break;
            }
        }
        if (!gsw_wave.open || gsw_wave.stream_id != request.stream_id) break;
    }
}

static gsw_u32 gsw_allocate_token(void)
{
    gsw_u32 token = gsw_wave.next_token++;
    if (token == 0) {
        token = gsw_wave.next_token++;
        if (token == 0) token = 1;
    }
    if (gsw_wave.next_token == 0) gsw_wave.next_token = 1;
    return token;
}

static int gsw_record_play(
    GSW_WAVE_BUFFER *buffer,
    gsw_u16 buffer_index,
    int complete_buffer,
    int release_loop,
    gsw_u16 loop_start_index,
    gsw_u16 loop_end_index
)
{
    GSW_WAVE_PLAY *play;
    if (buffer == 0 || buffer->token == 0 ||
        gsw_wave.play_count == GSW_WAVE_QUEUE_CAPACITY)
        return 0;
    play = &gsw_wave.plays[gsw_wave.play_write];
    gsw_zero(play, sizeof(*play));
    play->token = buffer->token;
    play->buffer_index = buffer_index;
    play->complete_buffer = complete_buffer ? 1 : 0;
    play->release_loop = release_loop ? 1 : 0;
    play->loop_start_index = loop_start_index;
    play->loop_end_index = loop_end_index;
    gsw_wave.play_write = gsw_next_queue_index(gsw_wave.play_write);
    gsw_wave.play_count++;
    buffer->submitted_bytes = 0;
    buffer->token = 0;
    return 1;
}

static int gsw_finish_occurrence(gsw_u16 buffer_index)
{
    GSW_WAVE_BUFFER *buffer = &gsw_wave.queue[buffer_index];
    int begins_loop;
    int ends_loop;
    int complete_buffer = 0;
    int release_loop = 0;
    gsw_u16 release_start = 0;
    if (buffer->header == 0) return 0;
    begins_loop = (buffer->header_flags & WHDR_BEGINLOOP) != 0;
    ends_loop = (buffer->header_flags & WHDR_ENDLOOP) != 0;
    if (begins_loop) {
        if (!gsw_wave.loop_active) {
            if (buffer->loop_count == 0) return 0;
            gsw_wave.loop_active = 1;
            gsw_wave.loop_start_index = buffer_index;
            gsw_wave.loop_remaining = buffer->loop_count;
            gsw_wave.loop_break_requested = gsw_wave.break_next_loop;
            gsw_wave.break_next_loop = 0;
        } else if (buffer_index != gsw_wave.loop_start_index) {
            return 0;
        }
    }
    if (gsw_wave.loop_active) {
        if (ends_loop) {
            if (gsw_wave.loop_break_requested || gsw_wave.loop_remaining <= 1) {
                release_loop = 1;
                release_start = gsw_wave.loop_start_index;
                gsw_wave.loop_active = 0;
                gsw_wave.loop_break_requested = 0;
                gsw_wave.loop_remaining = 0;
                gsw_wave.loop_release_pending++;
                gsw_wave.schedule_index = gsw_next_queue_index(buffer_index);
            } else {
                gsw_wave.loop_remaining--;
                gsw_wave.schedule_index = gsw_wave.loop_start_index;
            }
        } else {
            gsw_wave.schedule_index = gsw_next_queue_index(buffer_index);
        }
    } else {
        if (ends_loop) return 0;
        complete_buffer = 1;
        gsw_wave.schedule_index = gsw_next_queue_index(buffer_index);
    }
    return gsw_record_play(
        buffer,
        buffer_index,
        complete_buffer,
        release_loop,
        release_start,
        buffer_index
    );
}

static void gsw_submit_buffers(void)
{
    int work = 0;
    while (gsw_wave.queue_count != 0 && work++ < GSW_PUMP_WORK_LIMIT) {
        gsw_u16 buffer_index = gsw_wave.schedule_index;
        GSW_WAVE_BUFFER *buffer = &gsw_wave.queue[buffer_index];
        GSW_SOUND_PM_REQUEST request;
        gsw_u32 remaining;
        gsw_u32 chunk;
        GSW_SOUND_RESULT result;
        if (gsw_wave.play_count == GSW_WAVE_QUEUE_CAPACITY || buffer->header == 0) break;
        if (buffer->token == 0) buffer->token = gsw_allocate_token();
        remaining = buffer->buffer_bytes - buffer->submitted_bytes;
        if (remaining == 0 || buffer->submitted_bytes > buffer->buffer_bytes) {
            gsw_abort_queue();
            break;
        }
        chunk = remaining > GSW_SOUND_MAX_SUBMIT_BYTES ? GSW_SOUND_MAX_SUBMIT_BYTES : remaining;
        chunk -= chunk % gsw_wave.frame_bytes;
        if (chunk == 0) break;
        gsw_request_init(&request, GSW_SOUND_PM_SUBMIT);
        request.stream_id = gsw_wave.stream_id;
        request.buffer_linear = buffer->buffer_linear + buffer->submitted_bytes;
        request.buffer_bytes = chunk;
        request.user_token = buffer->token;
        if (chunk == remaining) request.flags = GSW_SOUND_SUBMIT_END_OF_BUFFER;
        result = gsw_sound_pm_call(&request);
        if (result == GSW_SOUND_WOULD_BLOCK) break;
        if (result != GSW_SOUND_OK || request.result != GSW_SOUND_OK ||
            request.accepted_bytes == 0 ||
            request.accepted_bytes > chunk ||
            request.accepted_bytes % gsw_wave.frame_bytes != 0) {
            gsw_abort_queue();
            break;
        }
        buffer->submitted_bytes += request.accepted_bytes;
        if (buffer->submitted_bytes == buffer->buffer_bytes) {
            if (!gsw_finish_occurrence(buffer_index)) {
                gsw_abort_queue();
                break;
            }
        }
        if (request.accepted_bytes < chunk) break;
    }
}

static void gsw_pump(void)
{
    if (!gsw_wave.open || gsw_wave.paused || gsw_wave.pumping) return;
    gsw_wave.pumping = 1;
    gsw_poll_completions();
    gsw_submit_buffers();
    gsw_wave.pumping = 0;
}

static void CALLBACK __loadds gsw_timer_callback(
    UINT timer,
    UINT message,
    DWORD user,
    DWORD one,
    DWORD two
)
{
    (void)timer;
    (void)message;
    (void)user;
    (void)one;
    (void)two;
    gsw_pump();
}

static void gsw_stop_timer(void)
{
    if (gsw_wave.timer_id != 0) {
        timeKillEvent(gsw_wave.timer_id);
        gsw_wave.timer_id = 0;
    }
    if (gsw_wave.timer_period_active) {
        timeEndPeriod(GSW_PUMP_PERIOD_MS);
        gsw_wave.timer_period_active = 0;
    }
}

static DWORD gsw_get_num_devices(void)
{
    GSW_SOUND_PM_REQUEST request;
    gsw_request_init(&request, GSW_SOUND_PM_QUERY);
    if (gsw_sound_pm_call(&request) != GSW_SOUND_OK) return 0;
    return (request.capabilities & GSW_PCM_REQUIRED_CAPS) == GSW_PCM_REQUIRED_CAPS ? 1 : 0;
}

static GSW_MMRESULT gsw_get_caps(LPWAVEOUTCAPS caps, DWORD bytes)
{
    WAVEOUTCAPS local;
    gsw_u32 count;
    gsw_u8 FAR *out;
    const gsw_u8 *in;
    if (caps == 0 || bytes == 0) return MMSYSERR_INVALPARAM;
    gsw_zero(&local, sizeof(local));
    local.wMid = MM_UNMAPPED;
    local.wPid = 0;
    local.vDriverVersion = 0x0100;
    lstrcpy(local.szPname, "RETVRN99 GSW-Sound");
    local.dwFormats = WAVE_FORMAT_1M08 | WAVE_FORMAT_1M16 | WAVE_FORMAT_1S08 |
        WAVE_FORMAT_1S16 | WAVE_FORMAT_2M08 | WAVE_FORMAT_2M16 |
        WAVE_FORMAT_2S08 | WAVE_FORMAT_2S16 | WAVE_FORMAT_4M08 |
        WAVE_FORMAT_4M16 | WAVE_FORMAT_4S08 | WAVE_FORMAT_4S16;
    local.wChannels = 2;
    local.dwSupport = WAVECAPS_VOLUME;
    count = bytes < sizeof(local) ? bytes : sizeof(local);
    out = (gsw_u8 FAR *)caps;
    in = (const gsw_u8 *)&local;
    while (count-- != 0) *out++ = *in++;
    return MMSYSERR_NOERROR;
}

static int gsw_callback_type_supported(DWORD flags)
{
    switch (flags & CALLBACK_TYPEMASK) {
    case CALLBACK_NULL:
    case CALLBACK_WINDOW:
    case CALLBACK_TASK:
    case CALLBACK_FUNCTION:
    case CALLBACK_EVENT:
        return 1;
    default:
        return 0;
    }
}

static GSW_MMRESULT gsw_open(
    DWORD dwUser,
    GSW_LPWAVEOPENDESC description,
    DWORD flags
)
{
    GSW_SOUND_PM_REQUEST request;
    GSW_SOUND_RESULT result;
    gsw_u32 stream_id;
    if (description == 0 || !gsw_format_supported(description->lpFormat)) return WAVERR_BADFORMAT;
    if ((flags & WAVE_FORMAT_DIRECT) != 0) return MMSYSERR_NOTSUPPORTED;
    if ((flags & ~(CALLBACK_TYPEMASK | WAVE_FORMAT_QUERY | WAVE_ALLOWSYNC |
                   WAVE_FORMAT_DIRECT)) != 0 || !gsw_callback_type_supported(flags))
        return MMSYSERR_INVALFLAG;
    if ((flags & WAVE_FORMAT_QUERY) != 0) return MMSYSERR_NOERROR;
    if (dwUser == 0) return MMSYSERR_INVALPARAM;
    if (gsw_wave.open) return MMSYSERR_ALLOCATED;
    gsw_zero(&gsw_wave, sizeof(gsw_wave));
    gsw_request_init(&request, GSW_SOUND_PM_OPEN);
    request.sample_rate = description->lpFormat->nSamplesPerSec;
    request.channels = description->lpFormat->nChannels;
    request.bits_per_sample = description->lpFormat->wBitsPerSample;
    result = gsw_sound_pm_call(&request);
    if (result != GSW_SOUND_OK) return gsw_result_to_mm(result);
    stream_id = request.stream_id;
    if (request.sample_rate != description->lpFormat->nSamplesPerSec ||
        request.channels != description->lpFormat->nChannels ||
        request.bits_per_sample != description->lpFormat->wBitsPerSample) {
        gsw_request_init(&request, GSW_SOUND_PM_CLOSE);
        request.stream_id = stream_id;
        (void)gsw_sound_pm_call(&request);
        return MMSYSERR_ERROR;
    }
    gsw_wave.open = 1;
    gsw_wave.wave = description->hWave;
    gsw_wave.callback = description->dwCallback;
    gsw_wave.callback_instance = description->dwInstance;
    gsw_wave.callback_flags = GSW_DRIVER_CALLBACK_FLAGS(flags);
    gsw_wave.stream_id = stream_id;
    gsw_wave.next_token = 1;
    gsw_wave.sample_rate = request.sample_rate;
    gsw_wave.channels = request.channels;
    gsw_wave.bits_per_sample = request.bits_per_sample;
    gsw_wave.frame_bytes = request.channels * (request.bits_per_sample >> 3);
    if (timeBeginPeriod(GSW_PUMP_PERIOD_MS) != TIMERR_NOERROR) {
        gsw_request_init(&request, GSW_SOUND_PM_CLOSE);
        request.stream_id = gsw_wave.stream_id;
        (void)gsw_sound_pm_call(&request);
        gsw_zero(&gsw_wave, sizeof(gsw_wave));
        return MMSYSERR_ERROR;
    }
    gsw_wave.timer_period_active = 1;
    gsw_wave.timer_id = timeSetEvent(
        GSW_PUMP_PERIOD_MS,
        GSW_PUMP_PERIOD_MS,
        gsw_timer_callback,
        0,
        TIME_PERIODIC
    );
    if (gsw_wave.timer_id == 0) {
        gsw_stop_timer();
        gsw_request_init(&request, GSW_SOUND_PM_CLOSE);
        request.stream_id = gsw_wave.stream_id;
        (void)gsw_sound_pm_call(&request);
        gsw_zero(&gsw_wave, sizeof(gsw_wave));
        return MMSYSERR_NOMEM;
    }
    *(DWORD FAR *)dwUser = (DWORD)(void FAR *)&gsw_wave;
    gsw_callback(WOM_OPEN, 0);
    if (gsw_wave.open && gsw_wave.stream_id == stream_id)
        gsw_mixer_set_wave_active(1);
    return MMSYSERR_NOERROR;
}

static GSW_MMRESULT gsw_close(void)
{
    GSW_CALLBACK_CONTEXT context;
    GSW_SOUND_PM_REQUEST request;
    GSW_SOUND_RESULT result;
    if (!gsw_wave.open) return MMSYSERR_INVALHANDLE;
    if (gsw_wave.queue_count != 0) return WAVERR_STILLPLAYING;
    gsw_stop_timer();
    gsw_request_init(&request, GSW_SOUND_PM_CLOSE);
    request.stream_id = gsw_wave.stream_id;
    result = gsw_sound_pm_call(&request);
    gsw_capture_callback(&context);
    gsw_zero(&gsw_wave, sizeof(gsw_wave));
    gsw_mixer_set_wave_active(0);
    gsw_callback_with(&context, WOM_CLOSE, 0);
    return gsw_result_to_mm(result);
}

static GSW_MMRESULT gsw_prepare_header(LPWAVEHDR header, DWORD bytes)
{
    if (header == 0 || bytes < sizeof(*header)) return MMSYSERR_INVALPARAM;
    if ((header->dwFlags & WHDR_INQUEUE) != 0) return WAVERR_STILLPLAYING;
    header->dwFlags |= WHDR_PREPARED;
    return MMSYSERR_NOERROR;
}

static GSW_MMRESULT gsw_unprepare_header(LPWAVEHDR header, DWORD bytes)
{
    if (header == 0 || bytes < sizeof(*header)) return MMSYSERR_INVALPARAM;
    if ((header->dwFlags & WHDR_INQUEUE) != 0) return WAVERR_STILLPLAYING;
    header->dwFlags &= ~WHDR_PREPARED;
    return MMSYSERR_NOERROR;
}

static int gsw_snapshot_buffer_linear(
    LPSTR data,
    gsw_u32 bytes,
    gsw_u32 *linear
)
{
    int valid = 0;
    if (data == 0 || bytes == 0 || linear == 0) return 0;
    *linear = gsw_sound_pm_linear(data, &valid);
    if (!valid || *linear > 0xFFFFFFFFUL - (bytes - 1)) return 0;
    return 1;
}

static GSW_MMRESULT gsw_write(LPWAVEHDR header)
{
    GSW_WAVE_BUFFER *buffer;
    gsw_u32 buffer_linear;
    int queue_loop_open;
    int begins_loop;
    int ends_loop;
    if (!gsw_wave.open) return MMSYSERR_INVALHANDLE;
    if (header == 0 || header->lpData == 0 ||
        header->dwBufferLength == 0 || header->dwBufferLength % gsw_wave.frame_bytes != 0)
        return MMSYSERR_INVALPARAM;
    if ((header->dwFlags & WHDR_INQUEUE) != 0) return WAVERR_STILLPLAYING;
    if ((header->dwFlags & WHDR_PREPARED) == 0) return WAVERR_UNPREPARED;
    if (gsw_wave.queue_count == GSW_WAVE_QUEUE_CAPACITY) return MMSYSERR_NOMEM;
    if (!gsw_snapshot_buffer_linear(
            header->lpData,
            header->dwBufferLength,
            &buffer_linear
        ))
        return MMSYSERR_INVALPARAM;
    begins_loop = (header->dwFlags & WHDR_BEGINLOOP) != 0;
    ends_loop = (header->dwFlags & WHDR_ENDLOOP) != 0;
    queue_loop_open = gsw_wave.queue_loop_open;
    if (begins_loop) {
        if (queue_loop_open || header->dwLoops == 0) return MMSYSERR_INVALPARAM;
        queue_loop_open = 1;
    }
    if (ends_loop) {
        if (!queue_loop_open) return MMSYSERR_INVALPARAM;
        queue_loop_open = 0;
    }
    buffer = &gsw_wave.queue[gsw_wave.queue_write];
    gsw_zero(buffer, sizeof(*buffer));
    buffer->header = header;
    buffer->buffer_linear = buffer_linear;
    buffer->buffer_bytes = header->dwBufferLength;
    buffer->header_flags = header->dwFlags & (WHDR_BEGINLOOP | WHDR_ENDLOOP);
    buffer->loop_count = header->dwLoops;
    header->dwFlags &= ~WHDR_DONE;
    header->dwFlags |= WHDR_INQUEUE;
    if (gsw_wave.queue_count == 0) {
        gsw_wave.queue_read = gsw_wave.queue_write;
        gsw_wave.schedule_index = gsw_wave.queue_write;
    }
    gsw_wave.queue_loop_open = (gsw_u8)queue_loop_open;
    gsw_wave.queue_write = gsw_next_queue_index(gsw_wave.queue_write);
    gsw_wave.queue_count++;
    gsw_pump();
    return MMSYSERR_NOERROR;
}

static int gsw_has_unscheduled_loop(void)
{
    gsw_u16 index;
    gsw_u16 scanned;
    if (gsw_wave.queue_count == 0) return 0;
    if (gsw_wave.schedule_index == gsw_wave.queue_write &&
        gsw_wave.queue_count != GSW_WAVE_QUEUE_CAPACITY)
        return 0;
    index = gsw_wave.schedule_index;
    for (scanned = 0; scanned < gsw_wave.queue_count; scanned++) {
        GSW_WAVE_BUFFER *buffer = &gsw_wave.queue[index];
        if (buffer->header == 0) return 0;
        if ((buffer->header_flags & WHDR_BEGINLOOP) != 0) return 1;
        index = gsw_next_queue_index(index);
        if (index == gsw_wave.queue_write) break;
    }
    return 0;
}

static GSW_MMRESULT gsw_break_loop(void)
{
    if (gsw_wave.loop_active) gsw_wave.loop_break_requested = 1;
    else if (gsw_has_unscheduled_loop()) gsw_wave.break_next_loop = 1;
    return MMSYSERR_NOERROR;
}

static GSW_MMRESULT gsw_simple_stream_command(GSW_SOUND_PM_OPCODE opcode)
{
    GSW_SOUND_PM_REQUEST request;
    if (!gsw_wave.open) return MMSYSERR_INVALHANDLE;
    gsw_request_init(&request, opcode);
    request.stream_id = gsw_wave.stream_id;
    return gsw_result_to_mm(gsw_sound_pm_call(&request));
}

static GSW_MMRESULT gsw_reset(void)
{
    GSW_MMRESULT result = gsw_simple_stream_command(GSW_SOUND_PM_RESET);
    if (result == MMSYSERR_NOERROR) gsw_wave.paused = 0;
    gsw_complete_all();
    return result;
}

static GSW_MMRESULT gsw_pause(void)
{
    GSW_MMRESULT result;
    if (!gsw_wave.open) return MMSYSERR_INVALHANDLE;
    result = gsw_simple_stream_command(GSW_SOUND_PM_PAUSE);
    if (result == MMSYSERR_NOERROR) gsw_wave.paused = 1;
    return result;
}

static GSW_MMRESULT gsw_restart(void)
{
    GSW_MMRESULT result;
    if (!gsw_wave.open) return MMSYSERR_INVALHANDLE;
    result = gsw_simple_stream_command(GSW_SOUND_PM_RESTART);
    if (result == MMSYSERR_NOERROR) gsw_wave.paused = 0;
    return result;
}

static DWORD gsw_position_clamp(gsw_u64 value)
{
    return value > (gsw_u64)0xFFFFFFFFUL ? 0xFFFFFFFFUL : (DWORD)value;
}

static GSW_MMRESULT gsw_get_position(LPMMTIME time, DWORD bytes)
{
    GSW_SOUND_PM_REQUEST request;
    gsw_u64 position;
    gsw_u64 frames;
    gsw_u64 seconds;
    gsw_u64 value;
    if (time == 0 || bytes < sizeof(*time)) return MMSYSERR_INVALPARAM;
    gsw_request_init(&request, GSW_SOUND_PM_GET_POSITION);
    request.stream_id = gsw_wave.stream_id;
    if (gsw_sound_pm_call(&request) != GSW_SOUND_OK) return MMSYSERR_ERROR;
    position = ((gsw_u64)request.position_high << 32) | request.position_low;
    frames = position / gsw_wave.frame_bytes;
    switch (time->wType) {
    case TIME_SAMPLES:
        time->u.sample = gsw_position_clamp(frames);
        break;
    case TIME_MS:
        seconds = frames / gsw_wave.sample_rate;
        if (seconds > (gsw_u64)(0xFFFFFFFFUL / 1000UL)) {
            time->u.ms = 0xFFFFFFFFUL;
        } else {
            value = seconds * 1000UL;
            value += ((frames % gsw_wave.sample_rate) * 1000UL) /
                gsw_wave.sample_rate;
            time->u.ms = gsw_position_clamp(value);
        }
        break;
    default:
        time->wType = TIME_BYTES;
        time->u.cb = gsw_position_clamp(position);
        break;
    }
    return MMSYSERR_NOERROR;
}

static GSW_MMRESULT gsw_get_volume(DWORD FAR *volume)
{
    return gsw_mixer_get_wave_volume(volume);
}

static GSW_MMRESULT gsw_set_volume(DWORD volume)
{
    return gsw_mixer_set_wave_volume(volume);
}

static int gsw_wave_user_valid(DWORD dwUser)
{
    return gsw_wave.open && dwUser == (DWORD)(void FAR *)&gsw_wave;
}

DWORD FAR PASCAL __loadds wodMessage(
    UINT device_id,
    UINT message,
    DWORD dwUser,
    DWORD parameter_one,
    DWORD parameter_two
)
{
    switch (message) {
    case WODM_INIT:
    case DRVM_EXIT:
    case DRVM_DISABLE:
    case DRVM_ENABLE:
        return MMSYSERR_NOERROR;
    }
    if (device_id != 0 && message != WODM_GETNUMDEVS) return MMSYSERR_BADDEVICEID;
    if (message == DRV_QUERYDRVENTRY) return MMSYSERR_NOTSUPPORTED;
    if (message == DRV_QUERYDSOUNDIFACE) return MMSYSERR_NOTSUPPORTED;
    switch (message) {
    case WODM_GETNUMDEVS: return gsw_get_num_devices();
    case WODM_GETDEVCAPS: return gsw_get_caps((LPWAVEOUTCAPS)parameter_one, parameter_two);
    case WODM_OPEN:
        return gsw_open(dwUser, (GSW_LPWAVEOPENDESC)parameter_one, parameter_two);
    case WODM_GETVOLUME: return gsw_get_volume((DWORD FAR *)parameter_one);
    case WODM_SETVOLUME: return gsw_set_volume(parameter_one);
    }
    if (!gsw_wave_user_valid(dwUser)) return MMSYSERR_INVALHANDLE;
    switch (message) {
    case WODM_CLOSE: return gsw_close();
    case WODM_PREPARE:
        return gsw_prepare_header((LPWAVEHDR)parameter_one, parameter_two);
    case WODM_UNPREPARE:
        return gsw_unprepare_header((LPWAVEHDR)parameter_one, parameter_two);
    case WODM_WRITE: return gsw_write((LPWAVEHDR)parameter_one);
    case WODM_PAUSE: return gsw_pause();
    case WODM_RESTART: return gsw_restart();
    case WODM_RESET: return gsw_reset();
    case WODM_GETPOS: return gsw_get_position((LPMMTIME)parameter_one, parameter_two);
    case WODM_BREAKLOOP: return gsw_break_loop();
    default: return MMSYSERR_NOTSUPPORTED;
    }
}

DWORD FAR PASCAL __loadds mxdMessage(
    UINT device_id,
    UINT message,
    DWORD dwUser,
    DWORD parameter_one,
    DWORD parameter_two
)
{
    return gsw_mixer_message(
        device_id,
        message,
        dwUser,
        parameter_one,
        parameter_two
    );
}

BOOL FAR PASCAL LibMain(
    HINSTANCE instance,
    WORD data_segment,
    WORD heap_size,
    LPSTR command_line
)
{
    (void)instance;
    (void)data_segment;
    (void)heap_size;
    (void)command_line;
    return TRUE;
}

DWORD FAR PASCAL __loadds DriverProc(
    DWORD driver_id,
    HDRVR driver,
    UINT message,
    LPARAM parameter_one,
    LPARAM parameter_two
)
{
    switch (message) {
    case DRV_LOAD:
        if (!gsw_sound_pm_connect()) return 0;
        gsw_mixer_initialize();
        return 1;
    case DRV_FREE:
        gsw_mixer_shutdown();
        return 1;
    case DRV_OPEN:
    case DRV_CLOSE:
    case DRV_ENABLE:
    case DRV_DISABLE:
        return 1;
    }
    return DefDriverProc(driver_id, driver, message, parameter_one, parameter_two);
}

int FAR PASCAL __loadds WEP(int reason)
{
    GSW_SOUND_PM_REQUEST request;
    (void)reason;
    if (gsw_wave.open) {
        gsw_stop_timer();
        gsw_request_init(&request, GSW_SOUND_PM_RESET);
        request.stream_id = gsw_wave.stream_id;
        (void)gsw_sound_pm_call(&request);
        gsw_request_init(&request, GSW_SOUND_PM_CLOSE);
        request.stream_id = gsw_wave.stream_id;
        (void)gsw_sound_pm_call(&request);
        gsw_zero(&gsw_wave, sizeof(gsw_wave));
    }
    gsw_mixer_shutdown();
    return 1;
}
