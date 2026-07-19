/* SPDX-License-Identifier: GPL-3.0-only */
#ifndef RETVRN99_GSWSOUND_TRANSPORT_H
#define RETVRN99_GSWSOUND_TRANSPORT_H

#include "../include/gswsound_abi.h"
#include "../include/gswsound_pm.h"

typedef struct GSW_SOUND_COMPLETION {
    gsw_u32 token;
    gsw_u32 target_position_low;
    gsw_u32 target_position_high;
} GSW_SOUND_COMPLETION;

typedef struct GSW_SOUND_TRANSPORT {
    volatile gsw_u32 *registers;
    gsw_u8 *ring;
    gsw_u32 ring_physical;
    gsw_u32 ring_bytes;
    gsw_u32 ring_tail;
    gsw_u32 frame_bytes;
    gsw_u32 sample_rate;
    gsw_u16 channels;
    gsw_u16 bits_per_sample;
    gsw_u32 gain_q16;
    gsw_u32 stream_id;
    gsw_u32 submitted_position_low;
    gsw_u32 submitted_position_high;
    volatile gsw_u32 pending_irq_status;
    volatile gsw_u32 period_irq_count;
    volatile gsw_u32 underrun_irq_count;
    volatile gsw_u32 invalid_irq_count;
    GSW_SOUND_COMPLETION completions[GSW_SOUND_COMPLETION_CAPACITY];
    gsw_u16 completion_read;
    gsw_u16 completion_write;
    gsw_u16 completion_count;
    gsw_u8 bound;
    gsw_u8 opened;
    gsw_u8 paused;
    gsw_u8 interrupt_mode;
} GSW_SOUND_TRANSPORT;

GSW_SOUND_RESULT gsw_sound_transport_bind(
    GSW_SOUND_TRANSPORT *transport,
    volatile gsw_u32 *registers,
    gsw_u8 *ring,
    gsw_u32 ring_physical,
    gsw_u32 ring_bytes
);
void gsw_sound_transport_unbind(GSW_SOUND_TRANSPORT *transport);
GSW_SOUND_RESULT gsw_sound_transport_set_interrupt_mode(
    GSW_SOUND_TRANSPORT *transport,
    int enabled
);
int gsw_sound_transport_handle_interrupt(GSW_SOUND_TRANSPORT *transport);
GSW_SOUND_RESULT gsw_sound_transport_open(
    GSW_SOUND_TRANSPORT *transport,
    gsw_u32 sample_rate,
    gsw_u16 channels,
    gsw_u16 bits_per_sample,
    gsw_u32 *stream_id
);
GSW_SOUND_RESULT gsw_sound_transport_close(GSW_SOUND_TRANSPORT *transport, gsw_u32 stream_id);
GSW_SOUND_RESULT gsw_sound_transport_submit(
    GSW_SOUND_TRANSPORT *transport,
    gsw_u32 stream_id,
    const gsw_u8 *data,
    gsw_u32 bytes,
    gsw_u32 flags,
    gsw_u32 token,
    gsw_u32 *accepted_bytes
);
GSW_SOUND_RESULT gsw_sound_transport_poll(
    GSW_SOUND_TRANSPORT *transport,
    gsw_u32 stream_id,
    gsw_u32 *completed_token
);
GSW_SOUND_RESULT gsw_sound_transport_pause(GSW_SOUND_TRANSPORT *transport, gsw_u32 stream_id);
GSW_SOUND_RESULT gsw_sound_transport_restart(GSW_SOUND_TRANSPORT *transport, gsw_u32 stream_id);
GSW_SOUND_RESULT gsw_sound_transport_reset(GSW_SOUND_TRANSPORT *transport, gsw_u32 stream_id);
GSW_SOUND_RESULT gsw_sound_transport_position(
    GSW_SOUND_TRANSPORT *transport,
    gsw_u32 stream_id,
    gsw_u32 *low,
    gsw_u32 *high
);
GSW_SOUND_RESULT gsw_sound_transport_get_gain(GSW_SOUND_TRANSPORT *transport, gsw_u32 *gain_q16);
GSW_SOUND_RESULT gsw_sound_transport_set_gain(GSW_SOUND_TRANSPORT *transport, gsw_u32 gain_q16);

#endif
