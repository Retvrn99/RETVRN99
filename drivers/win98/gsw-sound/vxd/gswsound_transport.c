/* SPDX-License-Identifier: GPL-3.0-only */
#include "gswsound_transport.h"

#define GSW_SOUND_DEFAULT_PERIOD_FRAMES 256UL

static void gsw_sound_zero(void *destination, gsw_u32 bytes)
{
    gsw_u8 *out = (gsw_u8 *)destination;
    while (bytes != 0) {
        *out++ = 0;
        bytes--;
    }
}

static int gsw_sound_power_of_two(gsw_u32 value)
{
    return value != 0 && (value & (value - 1)) == 0;
}

static gsw_u32 gsw_sound_read(const GSW_SOUND_TRANSPORT *transport, gsw_u32 offset)
{
    return transport->registers[offset >> 2];
}

static void gsw_sound_write(GSW_SOUND_TRANSPORT *transport, gsw_u32 offset, gsw_u32 value)
{
    transport->registers[offset >> 2] = value;
}

static int gsw_sound_service_irq(GSW_SOUND_TRANSPORT *transport)
{
    gsw_u32 irq_status;
    if (transport == 0 || !transport->bound) return 0;
    irq_status = gsw_sound_read(transport, GSW_PCM_REG_IRQ_STATUS) & GSW_PCM_IRQ_MASK;
    if (irq_status == 0) return 0;

    /* The device is level-triggered: deassert it before VPICD receives EOI. */
    gsw_sound_write(transport, GSW_PCM_REG_IRQ_STATUS, irq_status);
    transport->pending_irq_status |= irq_status;
    if ((irq_status & GSW_PCM_IRQ_PERIOD) != 0) transport->period_irq_count++;
    if ((irq_status & GSW_PCM_IRQ_UNDERRUN) != 0) transport->underrun_irq_count++;
    if ((irq_status & GSW_PCM_IRQ_INVALID) != 0) transport->invalid_irq_count++;
    return 1;
}

static void gsw_sound_position_read(
    const GSW_SOUND_TRANSPORT *transport,
    gsw_u32 *low,
    gsw_u32 *high
)
{
    gsw_u32 high_before;
    gsw_u32 high_after;
    do {
        high_before = gsw_sound_read(transport, GSW_PCM_REG_POSITION_HIGH);
        *low = gsw_sound_read(transport, GSW_PCM_REG_POSITION_LOW);
        high_after = gsw_sound_read(transport, GSW_PCM_REG_POSITION_HIGH);
    } while (high_before != high_after);
    *high = high_after;
}

static void gsw_sound_position_add(
    gsw_u32 *low,
    gsw_u32 *high,
    gsw_u32 increment
)
{
    gsw_u32 previous = *low;
    *low += increment;
    if (*low < previous) (*high)++;
}

static int gsw_sound_position_before(
    gsw_u32 low,
    gsw_u32 high,
    gsw_u32 target_low,
    gsw_u32 target_high
)
{
    if (high != target_high) return high < target_high;
    return low < target_low;
}

static int gsw_sound_rate_valid(gsw_u32 rate)
{
    return rate == GSW_PCM_RATE_11025 || rate == GSW_PCM_RATE_22050 ||
        rate == GSW_PCM_RATE_44100 || rate == GSW_PCM_RATE_48000;
}

static GSW_SOUND_RESULT gsw_sound_stream_validate(
    const GSW_SOUND_TRANSPORT *transport,
    gsw_u32 stream_id
)
{
    if (transport == 0 || !transport->bound) return GSW_SOUND_UNAVAILABLE;
    if (!transport->opened || stream_id == 0 || stream_id != transport->stream_id)
        return GSW_SOUND_INVALID;
    return GSW_SOUND_OK;
}

static GSW_SOUND_RESULT gsw_sound_program_stream(GSW_SOUND_TRANSPORT *transport)
{
    gsw_u32 period_bytes = transport->frame_bytes * GSW_SOUND_DEFAULT_PERIOD_FRAMES;
    gsw_sound_write(transport, GSW_PCM_REG_CONTROL, GSW_PCM_CONTROL_RESET);
    gsw_sound_write(transport, GSW_PCM_REG_SAMPLE_RATE, transport->sample_rate);
    gsw_sound_write(
        transport,
        GSW_PCM_REG_FORMAT,
        GSW_PCM_FORMAT(transport->channels, transport->bits_per_sample)
    );
    gsw_sound_write(transport, GSW_PCM_REG_RING_GPA_LOW, transport->ring_physical);
    gsw_sound_write(transport, GSW_PCM_REG_RING_GPA_HIGH, 0);
    gsw_sound_write(transport, GSW_PCM_REG_RING_SIZE, transport->ring_bytes);
    gsw_sound_write(transport, GSW_PCM_REG_PERIOD_BYTES, period_bytes);
    gsw_sound_write(transport, GSW_PCM_REG_RING_TAIL, 0);
    gsw_sound_write(transport, GSW_PCM_REG_MASTER_GAIN, transport->gain_q16);
    gsw_sound_write(transport, GSW_PCM_REG_IRQ_STATUS, GSW_PCM_IRQ_MASK);
    gsw_sound_write(
        transport,
        GSW_PCM_REG_IRQ_ENABLE,
        transport->interrupt_mode ? GSW_PCM_IRQ_MASK : 0
    );
    transport->ring_tail = 0;
    transport->submitted_position_low = 0;
    transport->submitted_position_high = 0;
    transport->completion_read = 0;
    transport->completion_write = 0;
    transport->completion_count = 0;
    transport->pending_irq_status = 0;
    transport->paused = 0;
    gsw_sound_zero(transport->ring, transport->ring_bytes);
    if ((gsw_sound_read(transport, GSW_PCM_REG_STATUS) & GSW_PCM_STATUS_READY) == 0)
        return GSW_SOUND_IO_ERROR;
    return GSW_SOUND_OK;
}

GSW_SOUND_RESULT gsw_sound_transport_bind(
    GSW_SOUND_TRANSPORT *transport,
    volatile gsw_u32 *registers,
    gsw_u8 *ring,
    gsw_u32 ring_physical,
    gsw_u32 ring_bytes
)
{
    gsw_u32 capabilities;
    if (transport == 0 || registers == 0 || ring == 0 ||
        ring_bytes < GSW_PCM_RING_MIN_SIZE || ring_bytes > GSW_PCM_RING_MAX_SIZE ||
        !gsw_sound_power_of_two(ring_bytes) ||
        (ring_physical & (GSW_PCM_RING_GPA_ALIGNMENT - 1)) != 0)
        return GSW_SOUND_INVALID;
    gsw_sound_zero(transport, sizeof(*transport));
    transport->registers = registers;
    transport->ring = ring;
    transport->ring_physical = ring_physical;
    transport->ring_bytes = ring_bytes;
    transport->gain_q16 = GSW_PCM_MASTER_GAIN_UNITY;
    if (gsw_sound_read(transport, GSW_PCM_REG_ID) != GSW_PCM_ID ||
        gsw_sound_read(transport, GSW_PCM_REG_VERSION) != GSW_PCM_INTERFACE_VERSION)
        return GSW_SOUND_UNAVAILABLE;
    capabilities = gsw_sound_read(transport, GSW_PCM_REG_CAPABILITIES);
    if ((capabilities & GSW_PCM_REQUIRED_CAPS) != GSW_PCM_REQUIRED_CAPS)
        return GSW_SOUND_UNAVAILABLE;
    if ((gsw_sound_read(transport, GSW_PCM_REG_STATUS) & GSW_PCM_STATUS_READY) == 0)
        return GSW_SOUND_UNAVAILABLE;
    transport->bound = 1;
    gsw_sound_write(transport, GSW_PCM_REG_CONTROL, GSW_PCM_CONTROL_RESET);
    return GSW_SOUND_OK;
}

void gsw_sound_transport_unbind(GSW_SOUND_TRANSPORT *transport)
{
    if (transport == 0) return;
    if (transport->bound) {
        gsw_sound_write(transport, GSW_PCM_REG_IRQ_ENABLE, 0);
        gsw_sound_write(transport, GSW_PCM_REG_IRQ_STATUS, GSW_PCM_IRQ_MASK);
        gsw_sound_write(transport, GSW_PCM_REG_CONTROL, GSW_PCM_CONTROL_RESET);
    }
    gsw_sound_zero(transport, sizeof(*transport));
}

GSW_SOUND_RESULT gsw_sound_transport_set_interrupt_mode(
    GSW_SOUND_TRANSPORT *transport,
    int enabled
)
{
    if (transport == 0 || !transport->bound || transport->opened)
        return GSW_SOUND_INVALID;
    transport->interrupt_mode = enabled ? 1 : 0;
    gsw_sound_write(transport, GSW_PCM_REG_IRQ_ENABLE, 0);
    gsw_sound_write(transport, GSW_PCM_REG_IRQ_STATUS, GSW_PCM_IRQ_MASK);
    transport->pending_irq_status = 0;
    return GSW_SOUND_OK;
}

int gsw_sound_transport_handle_interrupt(GSW_SOUND_TRANSPORT *transport)
{
    if (transport == 0 || !transport->interrupt_mode) return 0;
    return gsw_sound_service_irq(transport);
}

GSW_SOUND_RESULT gsw_sound_transport_open(
    GSW_SOUND_TRANSPORT *transport,
    gsw_u32 sample_rate,
    gsw_u16 channels,
    gsw_u16 bits_per_sample,
    gsw_u32 *stream_id
)
{
    GSW_SOUND_RESULT result;
    if (transport == 0 || !transport->bound) return GSW_SOUND_UNAVAILABLE;
    if (transport->opened) return GSW_SOUND_BUSY;
    if (!gsw_sound_rate_valid(sample_rate) || (channels != 1 && channels != 2) ||
        (bits_per_sample != 8 && bits_per_sample != 16) || stream_id == 0)
        return GSW_SOUND_INVALID;
    transport->sample_rate = sample_rate;
    transport->channels = channels;
    transport->bits_per_sample = bits_per_sample;
    transport->frame_bytes = channels * (bits_per_sample >> 3);
    transport->stream_id++;
    if (transport->stream_id == 0) transport->stream_id = 1;
    result = gsw_sound_program_stream(transport);
    if (result != GSW_SOUND_OK) return result;
    transport->opened = 1;
    *stream_id = transport->stream_id;
    return GSW_SOUND_OK;
}

GSW_SOUND_RESULT gsw_sound_transport_close(GSW_SOUND_TRANSPORT *transport, gsw_u32 stream_id)
{
    GSW_SOUND_RESULT result = gsw_sound_stream_validate(transport, stream_id);
    if (result != GSW_SOUND_OK) return result;
    gsw_sound_write(transport, GSW_PCM_REG_IRQ_ENABLE, 0);
    gsw_sound_write(transport, GSW_PCM_REG_IRQ_STATUS, GSW_PCM_IRQ_MASK);
    gsw_sound_write(transport, GSW_PCM_REG_CONTROL, GSW_PCM_CONTROL_RESET);
    transport->opened = 0;
    transport->paused = 0;
    transport->completion_count = 0;
    return GSW_SOUND_OK;
}

GSW_SOUND_RESULT gsw_sound_transport_submit(
    GSW_SOUND_TRANSPORT *transport,
    gsw_u32 stream_id,
    const gsw_u8 *data,
    gsw_u32 bytes,
    gsw_u32 flags,
    gsw_u32 token,
    gsw_u32 *accepted_bytes
)
{
    gsw_u32 head;
    gsw_u32 used;
    gsw_u32 free_bytes;
    gsw_u32 accepted;
    gsw_u32 index;
    GSW_SOUND_RESULT result = gsw_sound_stream_validate(transport, stream_id);
    if (accepted_bytes != 0) *accepted_bytes = 0;
    if (result != GSW_SOUND_OK) return result;
    if (transport->paused || data == 0 || accepted_bytes == 0 || bytes == 0 ||
        bytes > GSW_SOUND_MAX_SUBMIT_BYTES || bytes % transport->frame_bytes != 0 ||
        (flags & ~GSW_SOUND_SUBMIT_END_OF_BUFFER) != 0 ||
        ((flags & GSW_SOUND_SUBMIT_END_OF_BUFFER) != 0 && token == 0))
        return GSW_SOUND_INVALID;
    if ((flags & GSW_SOUND_SUBMIT_END_OF_BUFFER) != 0 &&
        transport->completion_count == GSW_SOUND_COMPLETION_CAPACITY)
        return GSW_SOUND_WOULD_BLOCK;
    head = gsw_sound_read(transport, GSW_PCM_REG_RING_HEAD);
    if (head >= transport->ring_bytes || head % transport->frame_bytes != 0)
        return GSW_SOUND_IO_ERROR;
    used = transport->ring_tail >= head ?
        transport->ring_tail - head : transport->ring_bytes - head + transport->ring_tail;
    free_bytes = transport->ring_bytes - used - transport->frame_bytes;
    accepted = bytes < free_bytes ? bytes : free_bytes;
    accepted -= accepted % transport->frame_bytes;
    if (accepted == 0) return GSW_SOUND_WOULD_BLOCK;
    for (index = 0; index < accepted; index++)
        transport->ring[(transport->ring_tail + index) & (transport->ring_bytes - 1)] = data[index];
    transport->ring_tail = (transport->ring_tail + accepted) & (transport->ring_bytes - 1);
    gsw_sound_position_add(
        &transport->submitted_position_low,
        &transport->submitted_position_high,
        accepted
    );
    gsw_sound_write(transport, GSW_PCM_REG_RING_TAIL, transport->ring_tail);
    if ((gsw_sound_read(transport, GSW_PCM_REG_STATUS) & GSW_PCM_STATUS_UNDERRUN) != 0)
        gsw_sound_write(transport, GSW_PCM_REG_STATUS, GSW_PCM_STATUS_UNDERRUN);
    if ((flags & GSW_SOUND_SUBMIT_END_OF_BUFFER) != 0 && accepted == bytes) {
        GSW_SOUND_COMPLETION *completion =
            &transport->completions[transport->completion_write];
        completion->token = token;
        completion->target_position_low = transport->submitted_position_low;
        completion->target_position_high = transport->submitted_position_high;
        transport->completion_write =
            (transport->completion_write + 1) % GSW_SOUND_COMPLETION_CAPACITY;
        transport->completion_count++;
    }
    if ((gsw_sound_read(transport, GSW_PCM_REG_STATUS) & GSW_PCM_STATUS_RUNNING) == 0)
        gsw_sound_write(transport, GSW_PCM_REG_CONTROL, GSW_PCM_CONTROL_START);
    *accepted_bytes = accepted;
    return GSW_SOUND_OK;
}

GSW_SOUND_RESULT gsw_sound_transport_poll(
    GSW_SOUND_TRANSPORT *transport,
    gsw_u32 stream_id,
    gsw_u32 *completed_token
)
{
    gsw_u32 irq_status;
    gsw_u32 status;
    gsw_u32 position_low;
    gsw_u32 position_high;
    GSW_SOUND_COMPLETION *completion;
    GSW_SOUND_RESULT result = gsw_sound_stream_validate(transport, stream_id);
    if (completed_token != 0) *completed_token = 0;
    if (result != GSW_SOUND_OK) return result;
    if (completed_token == 0) return GSW_SOUND_INVALID;
    if (!transport->interrupt_mode) gsw_sound_service_irq(transport);
    irq_status = transport->pending_irq_status;
    status = gsw_sound_read(transport, GSW_PCM_REG_STATUS);
    if ((status & GSW_PCM_STATUS_BAD_CONFIG) != 0 ||
        (irq_status & GSW_PCM_IRQ_INVALID) != 0)
        return GSW_SOUND_IO_ERROR;
    if (transport->completion_count == 0) return GSW_SOUND_NO_COMPLETION;
    gsw_sound_position_read(transport, &position_low, &position_high);
    completion = &transport->completions[transport->completion_read];
    if (gsw_sound_position_before(
            position_low,
            position_high,
            completion->target_position_low,
            completion->target_position_high
        ))
        return GSW_SOUND_NO_COMPLETION;
    *completed_token = completion->token;
    transport->completion_read =
        (transport->completion_read + 1) % GSW_SOUND_COMPLETION_CAPACITY;
    transport->completion_count--;
    return GSW_SOUND_OK;
}

GSW_SOUND_RESULT gsw_sound_transport_pause(GSW_SOUND_TRANSPORT *transport, gsw_u32 stream_id)
{
    GSW_SOUND_RESULT result = gsw_sound_stream_validate(transport, stream_id);
    if (result != GSW_SOUND_OK) return result;
    if (!transport->paused) gsw_sound_write(transport, GSW_PCM_REG_CONTROL, GSW_PCM_CONTROL_STOP);
    transport->paused = 1;
    return GSW_SOUND_OK;
}

GSW_SOUND_RESULT gsw_sound_transport_restart(GSW_SOUND_TRANSPORT *transport, gsw_u32 stream_id)
{
    GSW_SOUND_RESULT result = gsw_sound_stream_validate(transport, stream_id);
    if (result != GSW_SOUND_OK) return result;
    if (transport->paused) gsw_sound_write(transport, GSW_PCM_REG_CONTROL, GSW_PCM_CONTROL_START);
    transport->paused = 0;
    return GSW_SOUND_OK;
}

GSW_SOUND_RESULT gsw_sound_transport_reset(GSW_SOUND_TRANSPORT *transport, gsw_u32 stream_id)
{
    GSW_SOUND_RESULT result = gsw_sound_stream_validate(transport, stream_id);
    if (result != GSW_SOUND_OK) return result;
    return gsw_sound_program_stream(transport);
}

GSW_SOUND_RESULT gsw_sound_transport_position(
    GSW_SOUND_TRANSPORT *transport,
    gsw_u32 stream_id,
    gsw_u32 *low,
    gsw_u32 *high
)
{
    GSW_SOUND_RESULT result = gsw_sound_stream_validate(transport, stream_id);
    if (result != GSW_SOUND_OK) return result;
    if (low == 0 || high == 0) return GSW_SOUND_INVALID;
    gsw_sound_position_read(transport, low, high);
    return GSW_SOUND_OK;
}

GSW_SOUND_RESULT gsw_sound_transport_get_gain(GSW_SOUND_TRANSPORT *transport, gsw_u32 *gain_q16)
{
    if (transport == 0 || !transport->bound) return GSW_SOUND_UNAVAILABLE;
    if (gain_q16 == 0) return GSW_SOUND_INVALID;
    *gain_q16 = transport->gain_q16;
    return GSW_SOUND_OK;
}

GSW_SOUND_RESULT gsw_sound_transport_set_gain(GSW_SOUND_TRANSPORT *transport, gsw_u32 gain_q16)
{
    if (transport == 0 || !transport->bound) return GSW_SOUND_UNAVAILABLE;
    if (gain_q16 > GSW_PCM_MASTER_GAIN_UNITY) return GSW_SOUND_INVALID;
    transport->gain_q16 = gain_q16;
    gsw_sound_write(transport, GSW_PCM_REG_MASTER_GAIN, gain_q16);
    return GSW_SOUND_OK;
}
