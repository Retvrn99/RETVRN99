// SPDX-License-Identifier: GPL-3.0-only
package machine

import sound "../audio"
import disk "../disk"

@(private = "package")
machine_audio_reset_cdda :: proc(m: ^Machine) {
	if m == nil {return}
	m.cdda_pending_count = 0
	sound.audio_mixer_reset_cdda(&m.audio)
}

@(private = "package")
machine_audio_drain_cdda :: proc(m: ^Machine) {
	if m.cdda_pending_count == 0 {return}
	consumed := sound.audio_mixer_queue_cdda(&m.audio, m.cdda_pending[:m.cdda_pending_count])
	if consumed <= 0 {return}
	remaining := m.cdda_pending_count - consumed
	copy(m.cdda_pending[:remaining], m.cdda_pending[consumed:m.cdda_pending_count])
	m.cdda_pending_count = remaining
}

@(private = "package")
machine_cdda_frame :: proc(ctx: rawptr, pcm: []u8) {
	m := (^Machine)(ctx)
	if m == nil || len(pcm) != disk.DISC_RAW_SECTOR_SIZE {return}
	machine_audio_drain_cdda(m)
	frames: [disk.DISC_RAW_SECTOR_SIZE / 4]sound.Audio_Frame
	for i in 0 ..< len(frames) {
		offset := i * 4
		frames[i] = {
			left  = i16(u16(pcm[offset]) | u16(pcm[offset + 1]) << 8),
			right = i16(u16(pcm[offset + 2]) | u16(pcm[offset + 3]) << 8),
		}
	}
	consumed := sound.audio_mixer_queue_cdda(&m.audio, frames[:])
	remaining := len(frames) - consumed
	if remaining == 0 {return}
	if m.cdda_pending_count + remaining > len(m.cdda_pending) {
		bus_freeze(&m.bus, "CDDA source queue overflow")
		return
	}
	copy(m.cdda_pending[m.cdda_pending_count:m.cdda_pending_count + remaining], frames[consumed:])
	m.cdda_pending_count += remaining
}

@(private = "package")
machine_audio_apply_pit_transitions :: proc(m: ^Machine) {
	enabled := m.pit.port61_low & 0x02 != 0
	for transition in pit_channel2_transition_slice(&m.pit) {
		_ = sound.audio_mixer_set_speaker_state(
			&m.audio,
			transition.master_tick,
			enabled,
			transition.level,
		)
	}
	pit_clear_channel2_transitions(&m.pit)
}

@(private = "package")
machine_audio_next_deadline :: proc(m: ^Machine) -> (deadline: u64, pending: bool) {
	deadline, pending = sound.audio_mixer_next_deadline_tick(&m.audio)
	if candidate, ok := sound.sb16_next_deadline(&m.sb16);
	   ok && (!pending || candidate < deadline) {
		deadline = candidate
		pending = true
	}
	if candidate, ok := sound.opl3_next_deadline(&m.opl3);
	   ok && (!pending || candidate < deadline) {
		deadline = candidate
		pending = true
	}
	return
}

@(private = "package")
machine_sb16_dma_read_byte :: proc(ctx: rawptr, channel: int) -> (u8, bool) {
	m := (^Machine)(ctx)
	return dma_transfer_from_memory_byte(&m.dma, channel, m.vm.ram)
}

@(private = "package")
machine_sb16_dma_read_word :: proc(ctx: rawptr, channel: int) -> (u16, bool) {
	m := (^Machine)(ctx)
	if channel >= 5 {return dma_transfer_from_memory_word(&m.dma, channel, m.vm.ram)}
	low, low_ok := dma_transfer_from_memory_byte(&m.dma, channel, m.vm.ram)
	if !low_ok {return 0, false}
	high, high_ok := dma_transfer_from_memory_byte(&m.dma, channel, m.vm.ram)
	if !high_ok {return 0, false}
	return u16(low) | u16(high) << 8, true
}

@(private = "package")
machine_audio_refresh_sb16_dreq :: proc(m: ^Machine) {
	desired := -1
	if m.sb16.playing {
		if m.sb16.dma_16bit {
			desired = sound.ct1745_selected_dma16(&m.sb16.mixer)
		} else {
			desired = sound.ct1745_selected_dma8(&m.sb16.mixer)
		}
	}
	if m.sb16_dreq_active && m.sb16_dreq_channel != desired {
		dma_set_hardware_request(&m.dma, m.sb16_dreq_channel, false)
		m.sb16_dreq_active = false
	}
	if desired >= 0 && (!m.sb16_dreq_active || m.sb16_dreq_channel != desired) {
		dma_set_hardware_request(&m.dma, desired, true)
		m.sb16_dreq_channel = desired
		m.sb16_dreq_active = true
	}
}

@(private = "package")
machine_audio_forward_sb16_irq :: proc(m: ^Machine) {
	dma16, pending := sound.sb16_take_irq(&m.sb16)
	if !pending {return}
	sound.ct1745_set_irq_status(&m.sb16.mixer, dma16)
	pic_raise(&m.pic, sound.ct1745_selected_irq(&m.sb16.mixer))
}

@(private = "package")
machine_audio_publish_sources :: proc(m: ^Machine, tick: u64) {
	_ = sound.audio_mixer_set_sb16_frame(&m.audio, tick, sound.sb16_output_frame(&m.sb16))
	opl := sound.ct1745_apply_gain(&m.sb16.mixer, sound.opl3_current_output(&m.opl3), false)
	_ = sound.audio_mixer_set_opl3_frame(&m.audio, tick, opl)
}

@(private = "package")
machine_audio_advance_to :: proc(m: ^Machine, tick: u64) {
	machine_audio_apply_pit_transitions(m)
	machine_audio_drain_cdda(m)
	for {
		next_tick: u64
		pending := false
		if deadline, ok := sound.sb16_sample_deadline(&m.sb16); ok && deadline <= tick {
			next_tick = deadline
			pending = true
		}
		if deadline, ok := sound.opl3_sample_deadline(&m.opl3);
		   ok && deadline <= tick && (!pending || deadline < next_tick) {
			next_tick = deadline
			pending = true
		}
		if !pending {break}

		_ = sound.audio_mixer_advance_to(&m.audio, next_tick)
		sound.sb16_advance_control_to(&m.sb16, next_tick)
		sound.opl3_advance_control_to(&m.opl3, next_tick)
		if deadline, ok := sound.sb16_sample_deadline(&m.sb16); ok && deadline == next_tick {
			_, produced := sound.sb16_render_sample(
				&m.sb16,
				m,
				machine_sb16_dma_read_byte,
				machine_sb16_dma_read_word,
			)
			if produced {
				_ = sound.audio_mixer_set_sb16_frame(
					&m.audio,
					next_tick,
					sound.sb16_output_frame(&m.sb16),
				)
			}
			machine_audio_forward_sb16_irq(m)
			machine_audio_refresh_sb16_dreq(m)
		}
		if deadline, ok := sound.opl3_sample_deadline(&m.opl3); ok && deadline == next_tick {
			frame, produced := sound.opl3_render_sample(&m.opl3)
			if produced {
				frame = sound.ct1745_apply_gain(&m.sb16.mixer, frame, false)
				_ = sound.audio_mixer_set_opl3_frame(&m.audio, next_tick, frame)
			}
		}
	}
	_ = sound.audio_mixer_advance_to(&m.audio, tick)
	sound.sb16_advance_control_to(&m.sb16, tick)
	sound.opl3_advance_control_to(&m.opl3, tick)
	machine_audio_forward_sb16_irq(m)
	machine_audio_refresh_sb16_dreq(m)
}

@(private = "package")
machine_sb16_read :: proc(ctx: rawptr, port: u16, size: u8) -> u32 {
	m := (^Machine)(ctx)
	machine_sync_device(m, .Audio)
	value, _ := sound.sb16_read_port(&m.sb16, port)
	machine_audio_refresh_sb16_dreq(m)
	return u32(value)
}

@(private = "package")
machine_sb16_write :: proc(ctx: rawptr, port: u16, size: u8, val: u32) {
	m := (^Machine)(ctx)
	machine_sync_device(m, .Audio)
	_ = sound.sb16_write_port(&m.sb16, port, u8(val))
	now := master_timeline_now(m.timeline)
	machine_audio_publish_sources(m, now)
	machine_audio_forward_sb16_irq(m)
	machine_audio_refresh_sb16_dreq(m)
}

@(private = "package")
machine_opl3_read :: proc(ctx: rawptr, port: u16, size: u8) -> u32 {
	m := (^Machine)(ctx)
	machine_sync_device(m, .Audio)
	value, _ := sound.opl3_read_port(&m.opl3, port)
	return u32(value)
}

@(private = "package")
machine_opl3_write :: proc(ctx: rawptr, port: u16, size: u8, val: u32) {
	m := (^Machine)(ctx)
	machine_sync_device(m, .Audio)
	_ = sound.opl3_write_port(&m.opl3, port, u8(val))
	now := master_timeline_now(m.timeline)
	machine_audio_publish_sources(m, now)
}
