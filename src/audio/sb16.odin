// SPDX-License-Identifier: GPL-3.0-only
package audio

// DSP, DMA framing, and ASP probe behavior adapted from IzarraVM commit
// b88a9fe68a8109f26632ff2802262cc38a6a5ad9. The implementation is GPLv3-only
// clean-room code derived from public Creative programming documentation.
// Unsupported-command argument framing also follows DOSBox-X commit
// f3483ce0bda88c977dc266924fa36c15ce7eb5f8.

SB16_BASE_PORT :: u16(0x220)
SB16_LAST_PORT :: u16(0x22F)
SB16_DSP_VERSION_MAJOR :: u8(4)
SB16_DSP_VERSION_MINOR :: u8(5)
SB16_RESET_TICKS :: AUDIO_MASTER_CLOCK_HZ / 10_000
SB16_READ_QUEUE_CAPACITY :: 64
SB16_MAX_OUTPUT_RATE :: u32(48_000)

Sb16_Dma_Read_Byte_Proc :: proc(ctx: rawptr, channel: int) -> (u8, bool)
Sb16_Dma_Read_Word_Proc :: proc(ctx: rawptr, channel: int) -> (u16, bool)

Sb16 :: struct {
	mixer:              Ct1745,
	now_tick:           u64,
	reset_asserted:     bool,
	reset_pending:      bool,
	reset_deadline:     u64,
	read_queue:         [SB16_READ_QUEUE_CAPACITY]u8,
	read_head:          int,
	read_count:         int,
	last_read:          u8,
	pending_command:    u8,
	pending_args:       [3]u8,
	pending_count:      int,
	pending_need:       int,
	test_register:      u8,
	speaker_enabled:    bool,
	direct_dac_valid:   bool,
	direct_dac:         u8,
	rate_hz:            u32,
	rate_is_byte_rate:  bool,
	block_size:         u32,
	block_remaining:    u32,
	auto_init:          bool,
	playing:            bool,
	paused:             bool,
	silence_active:     bool,
	dma_16bit:          bool,
	stereo:             bool,
	signed_samples:     bool,
	pending_left_valid: bool,
	pending_left:       i16,
	irq_edge:           bool,
	irq_is_16bit:       bool,
	irq_pending_dma8:   bool,
	irq_pending_dma16:  bool,
	irq_pending_midi:   bool,
	irq_events_dma8:    u64,
	irq_events_dma16:   u64,
	irq_events_midi:    u64,
	starvation_frames:  u64,
	adpcm:              Sb16_Adpcm,
	sample_scheduled:   bool,
	next_sample_tick:   u64,
	sample_remainder:   u64,
	release_pending:    bool,
	raw_frame:          Audio_Frame,
	asp_mode:           u8,
	asp_registers:      [256]u8,
	controller_ram:     [256]u8,
}

sb16_init :: proc(sb: ^Sb16) {
	sb^ = {
		last_read         = 0xFF,
		rate_hz           = 22_050,
		rate_is_byte_rate = true,
	}
	ct1745_reset(&sb.mixer)
	// These power-on values are probed by the inbox Windows 98 SB16.VXD.
	// DSP reset does not clear the ASP register file, so initialize them here
	// rather than in sb16_reset_dsp.
	sb.asp_registers[0x05] = 0x01
	sb.asp_registers[0x09] = 0xF8
	sb.asp_registers[0x83] = 0x10
	sb.controller_ram[0x0E] = 0xFF
	sb.controller_ram[0x0F] = 0x07
	sb.controller_ram[0x37] = 0x38
}

sb16_queue_read :: proc(sb: ^Sb16, value: u8) {
	if sb.read_count == len(sb.read_queue) {return}
	index := (sb.read_head + sb.read_count) % len(sb.read_queue)
	sb.read_queue[index] = value
	sb.read_count += 1
}

sb16_pop_read :: proc(sb: ^Sb16) -> u8 {
	if sb.read_count == 0 {return sb.last_read}
	value := sb.read_queue[sb.read_head]
	sb.read_head = (sb.read_head + 1) % len(sb.read_queue)
	sb.read_count -= 1
	sb.last_read = value
	return value
}

sb16_command_arity :: proc(command: u8) -> int {
	if command >= 0xB0 && command <= 0xCF {return 3}
	switch command {
	case 0x04, 0x08, 0x0F, 0x10, 0x38, 0x40, 0xE0, 0xE2, 0xE4, 0xF9:
		return 1
	case 0x05,
	     0x0E,
	     0x14,
	     0x15,
	     0x16,
	     0x17,
	     0x24,
	     0x41,
	     0x42,
	     0x48,
	     0x74,
	     0x75,
	     0x76,
	     0x77,
	     0x80,
	     0xFA:
		return 2
	}
	return 0
}

sb16_output_rate :: proc(sb: ^Sb16) -> u32 {
	stereo := sb.stereo || !sb.dma_16bit && ct1745_sbpro_stereo(&sb.mixer)
	rate := sb.rate_hz
	if stereo && !sb.dma_16bit && sb.rate_is_byte_rate {rate /= 2}
	return clamp(rate, u32(1), SB16_MAX_OUTPUT_RATE)
}

sb16_schedule_first_sample :: proc(sb: ^Sb16) {
	rate := u64(sb16_output_rate(sb))
	delta := max(AUDIO_MASTER_CLOCK_HZ / rate, u64(1))
	sb.sample_remainder = AUDIO_MASTER_CLOCK_HZ % rate
	sb.next_sample_tick = sb.now_tick + min(delta, ~u64(0) - sb.now_tick)
	sb.sample_scheduled = true
}

sb16_schedule_next_sample :: proc(sb: ^Sb16) {
	rate := u64(sb16_output_rate(sb))
	delta := AUDIO_MASTER_CLOCK_HZ / rate
	sb.sample_remainder += AUDIO_MASTER_CLOCK_HZ % rate
	if sb.sample_remainder >= rate {
		sb.sample_remainder -= rate
		delta += 1
	}
	delta = max(delta, u64(1))
	sb.next_sample_tick += min(delta, ~u64(0) - sb.next_sample_tick)
	sb.sample_scheduled = true
}

sb16_arm :: proc(sb: ^Sb16, dma16, auto_init, stereo, signed_samples: bool, count: u32) {
	sb.dma_16bit = dma16
	sb.auto_init = auto_init
	sb.stereo = stereo
	sb.signed_samples = signed_samples
	sb.block_size = count
	sb.block_remaining = count
	sb.pending_left_valid = false
	sb.playing = true
	sb.paused = false
	sb.silence_active = false
	sb.adpcm = {}
	sb.direct_dac_valid = false
	sb.release_pending = false
	sb16_schedule_first_sample(sb)
}

sb16_arm_silence :: proc(sb: ^Sb16, count: u32) {
	sb.dma_16bit = false
	sb.auto_init = false
	sb.stereo = false
	sb.signed_samples = false
	sb.block_size = count
	sb.block_remaining = count
	sb.pending_left_valid = false
	sb.playing = true
	sb.paused = false
	sb.silence_active = true
	sb.adpcm = {}
	sb.direct_dac_valid = false
	sb.release_pending = false
	sb.raw_frame = {}
	sb16_schedule_first_sample(sb)
}

sb16_halt :: proc(sb: ^Sb16) {
	if !sb.playing {return}
	sb.playing = false
	sb.paused = true
	sb.sample_scheduled = false
	sb.release_pending = false
	sb.raw_frame = {}
}

sb16_continue :: proc(sb: ^Sb16) {
	if !sb.paused || sb.block_remaining == 0 {return}
	sb.playing = true
	sb.paused = false
	sb16_schedule_first_sample(sb)
}

sb16_raise_dma_irq :: proc(sb: ^Sb16, dma16: bool) {
	if dma16 {
		sb.irq_pending_dma16 = true
		sb.irq_events_dma16 += 1
	} else {
		sb.irq_pending_dma8 = true
		sb.irq_events_dma8 += 1
	}
	ct1745_set_irq_status(&sb.mixer, dma16)
	sb.irq_edge = true
	sb.irq_is_16bit = dma16
}

sb16_raise_midi_irq :: proc(sb: ^Sb16) {
	if sb == nil {return}
	sb.irq_pending_midi = true
	sb.irq_events_midi += 1
	ct1745_set_midi_irq_status(&sb.mixer)
}

sb16_ack_midi_irq :: proc(sb: ^Sb16) {
	if sb == nil {return}
	sb.irq_pending_midi = false
	ct1745_ack_irq_status(&sb.mixer, 0x04)
}

sb16_ack_dma_irq :: proc(sb: ^Sb16, dma16: bool) {
	if dma16 {
		sb.irq_pending_dma16 = false
		ct1745_ack_irq_status(&sb.mixer, 0x02)
	} else {
		sb.irq_pending_dma8 = false
		ct1745_ack_irq_status(&sb.mixer, 0x01)
	}
	if sb.irq_edge && sb.irq_is_16bit == dma16 {sb.irq_edge = false}
}

sb16_advance_block :: proc(sb: ^Sb16) {
	if !sb.playing || sb.block_remaining == 0 {return}
	sb.block_remaining -= 1
	if sb.block_remaining != 0 {return}
	sb16_raise_dma_irq(sb, sb.dma_16bit)
	if sb.auto_init && sb.block_size > 0 {
		sb.block_remaining = sb.block_size
	} else {
		sb.playing = false
		sb.paused = false
		sb.silence_active = false
	}
}

sb16_reset_dsp :: proc(sb: ^Sb16) {
	sb.read_head = 0
	sb.read_count = 0
	sb.pending_need = 0
	sb.pending_count = 0
	sb.playing = false
	sb.paused = false
	sb.auto_init = false
	sb.block_remaining = 0
	sb.dma_16bit = false
	sb.stereo = false
	sb.signed_samples = false
	sb.pending_left_valid = false
	sb.irq_edge = false
	sb.irq_pending_dma8 = false
	sb.irq_pending_dma16 = false
	sb.irq_pending_midi = false
	sb.sample_scheduled = false
	sb.release_pending = false
	sb.direct_dac_valid = false
	sb.silence_active = false
	sb.adpcm = {}
	sb.raw_frame = {}
	ct1745_clear_irq_status(&sb.mixer)
}

sb16_advance_control_to :: proc(sb: ^Sb16, target_tick: u64) {
	if target_tick < sb.now_tick {return}
	if sb.reset_pending && sb.reset_deadline <= target_tick {
		sb16_queue_read(sb, 0xAA)
		sb.reset_pending = false
	}
	sb.now_tick = target_tick
}

sb16_sample_deadline :: proc(sb: ^Sb16) -> (u64, bool) {
	return sb.next_sample_tick, sb.sample_scheduled
}

sb16_next_deadline :: proc(sb: ^Sb16) -> (u64, bool) {
	deadline: u64
	pending := false
	if sb.reset_pending {
		deadline = sb.reset_deadline
		pending = true
	}
	if sb.sample_scheduled && (!pending || sb.next_sample_tick < deadline) {
		deadline = sb.next_sample_tick
		pending = true
	}
	return deadline, pending
}

sb16_sample_byte :: proc(sb: ^Sb16, value: u8) -> i16 {
	return sb.signed_samples ? audio_pcm_i8(value) : audio_pcm_u8(value)
}

sb16_sample_word :: proc(sb: ^Sb16, value: u16) -> i16 {
	return sb.signed_samples ? audio_pcm_i16(value) : audio_pcm_u16(value)
}

sb16_render_sample :: proc(
	sb: ^Sb16,
	dma_ctx: rawptr,
	read_byte: Sb16_Dma_Read_Byte_Proc,
	read_word: Sb16_Dma_Read_Word_Proc,
) -> (
	Audio_Frame,
	bool,
) {
	if !sb.sample_scheduled {return {}, false}
	if sb16_adpcm_active(&sb.adpcm) {
		return sb16_render_adpcm_sample(sb, dma_ctx, read_byte)
	}
	if sb.release_pending {
		sb.release_pending = false
		sb.sample_scheduled = false
		sb.raw_frame = {}
		return {}, true
	}
	if !sb.playing {
		sb.sample_scheduled = false
		return {}, false
	}
	if sb.silence_active {
		sb.raw_frame = {}
		sb16_advance_block(sb)
		if sb.playing {
			sb16_schedule_next_sample(sb)
		} else {
			sb.release_pending = true
			sb16_schedule_next_sample(sb)
		}
		return {}, true
	}

	stereo := sb.stereo || !sb.dma_16bit && ct1745_sbpro_stereo(&sb.mixer)
	channel := sb.dma_16bit ? ct1745_selected_dma16(&sb.mixer) : ct1745_selected_dma8(&sb.mixer)
	left: i16
	left_completed_block := false
	if sb.pending_left_valid {
		left = sb.pending_left
		sb.pending_left_valid = false
	} else if sb.dma_16bit {
		if read_word == nil {
			sb.starvation_frames += 1
			sb.raw_frame = {}
			sb16_schedule_next_sample(sb)
			return {}, true
		}
		value, ok := read_word(dma_ctx, channel)
		if !ok {
			sb.starvation_frames += 1
			sb.raw_frame = {}
			sb16_schedule_next_sample(sb)
			return {}, true
		}
		left = sb16_sample_word(sb, value)
		left_completed_block = sb.block_remaining == 1
		sb16_advance_block(sb)
	} else {
		if read_byte == nil {
			sb.starvation_frames += 1
			sb.raw_frame = {}
			sb16_schedule_next_sample(sb)
			return {}, true
		}
		value, ok := read_byte(dma_ctx, channel)
		if !ok {
			sb.starvation_frames += 1
			sb.raw_frame = {}
			sb16_schedule_next_sample(sb)
			return {}, true
		}
		left = sb16_sample_byte(sb, value)
		left_completed_block = sb.block_remaining == 1
		sb16_advance_block(sb)
	}

	frame := Audio_Frame{left, left}
	if stereo {
		if left_completed_block {
			// A stereo block may contain an odd number of DMA units. Do not
			// borrow the right channel from the next auto-init block or read
			// beyond a single-cycle block; publish a neutral right sample.
			frame.right = 0
			sb.raw_frame = frame
			if !sb.playing {sb.release_pending = true}
			sb16_schedule_next_sample(sb)
			return frame, true
		}
		if sb.dma_16bit {
			value, ok := read_word(dma_ctx, channel)
			if !ok {
				sb.pending_left = left
				sb.pending_left_valid = true
				sb.starvation_frames += 1
				sb.raw_frame = {}
				sb16_schedule_next_sample(sb)
				return {}, true
			}
			frame.right = sb16_sample_word(sb, value)
		} else {
			value, ok := read_byte(dma_ctx, channel)
			if !ok {
				sb.pending_left = left
				sb.pending_left_valid = true
				sb.starvation_frames += 1
				sb.raw_frame = {}
				sb16_schedule_next_sample(sb)
				return {}, true
			}
			frame.right = sb16_sample_byte(sb, value)
		}
		sb16_advance_block(sb)
	}

	sb.raw_frame = frame
	if sb.playing {
		sb16_schedule_next_sample(sb)
	} else {
		sb.release_pending = true
		sb16_schedule_next_sample(sb)
	}
	return frame, true
}

sb16_take_irq :: proc(sb: ^Sb16) -> (dma16: bool, pending: bool) {
	dma16 = sb.irq_is_16bit
	pending = sb.irq_edge
	sb.irq_edge = false
	return
}

sb16_output_frame :: proc(sb: ^Sb16) -> Audio_Frame {
	return ct1745_apply_gain(&sb.mixer, sb.raw_frame, true)
}

sb16_read_port :: proc(sb: ^Sb16, port: u16) -> (u8, bool) {
	if value, ok := ct1745_read_port(&sb.mixer, port); ok {return value, true}
	switch port {
	case 0x22A:
		return sb16_pop_read(sb), true
	case 0x22C:
		return 0x00, true
	case 0x22E:
		if sb.pending_command == 0xFA && sb.pending_need == 2 && sb.pending_count == 0 {
			sb.pending_need = 0
			sb16_queue_read(sb, 0xFF)
		}
		sb16_ack_dma_irq(sb, false)
		return sb.read_count > 0 ? 0x80 : 0x00, true
	case 0x22F:
		sb16_ack_dma_irq(sb, true)
		return sb.read_count > 0 ? 0x80 : 0x00, true
	}
	return 0xFF, false
}

sb16_write_port :: proc(sb: ^Sb16, port: u16, value: u8) -> bool {
	old_rate := sb16_output_rate(sb)
	if ct1745_write_port(&sb.mixer, port, value) {
		if sb.playing && old_rate != sb16_output_rate(sb) {sb16_schedule_first_sample(sb)}
		return true
	}
	switch port {
	case 0x226:
		if value == 1 {
			sb.reset_asserted = true
			sb.reset_pending = false
		} else {
			sb16_reset_dsp(sb)
			sb.reset_asserted = false
			sb.reset_pending = true
			sb.reset_deadline = sb.now_tick + min(SB16_RESET_TICKS, ~u64(0) - sb.now_tick)
		}
		return true
	case 0x22C:
		sb16_write_command_byte(sb, value)
		return true
	}
	return false
}
