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
		bus_freeze(&m.platform.bus, "CDDA source queue overflow")
		return
	}
	copy(m.cdda_pending[m.cdda_pending_count:m.cdda_pending_count + remaining], frames[consumed:])
	m.cdda_pending_count += remaining
}

@(private = "package")
machine_audio_consider_deadline :: proc(deadline: ^u64, pending: ^bool, candidate: u64, ok: bool) {
	if ok && (!pending^ || candidate < deadline^) {
		deadline^ = candidate
		pending^ = true
	}
}

@(private = "package")
machine_audio_next_deadline :: proc(m: ^Machine) -> (deadline: u64, pending: bool) {
	deadline, pending = sound.audio_mixer_next_deadline_tick(&m.audio)
	if sound.gsw_sound_has_internal_samples(&m.gsw_sound) {
		candidate, ok := sound.audio_mixer_next_render_deadline_tick(&m.audio)
		machine_audio_consider_deadline(&deadline, &pending, candidate, ok)
	}
	adapter := machine_audio_gsw_adapters(m)
	candidate, ok := sound.gsw_sound_next_observable_deadline(&m.gsw_sound, adapter)
	machine_audio_consider_deadline(&deadline, &pending, candidate, ok)
	return
}

@(private = "package")
machine_sb16_dma_read_byte :: proc(ctx: rawptr, channel: int) -> (u8, bool) {
	m := (^Machine)(ctx)
	return dma_transfer_from_memory_byte(&m.platform.dma, channel, m.vm.ram)
}

@(private = "package")
machine_sb16_dma_read_word :: proc(ctx: rawptr, channel: int) -> (u16, bool) {
	m := (^Machine)(ctx)
	if channel >= 5 {return dma_transfer_from_memory_word(&m.platform.dma, channel, m.vm.ram)}
	low, low_ok := dma_transfer_from_memory_byte(&m.platform.dma, channel, m.vm.ram)
	if !low_ok {return 0, false}
	high, high_ok := dma_transfer_from_memory_byte(&m.platform.dma, channel, m.vm.ram)
	if !high_ok {return 0, false}
	return u16(low) | u16(high) << 8, true
}

@(private = "file")
machine_audio_dma_snapshot_adapter :: proc(
	ctx: rawptr,
	channel: int,
) -> (
	sound.Gsw_Sound_Dma_Channel_Snapshot,
	bool,
) {
	m := (^Machine)(ctx)
	if m == nil || channel < 0 || channel >= len(m.platform.dma.ch) {return {}, false}
	chip := channel < 4 ? &m.platform.dma.master : &m.platform.dma.slave
	c := &m.platform.dma.ch[channel]
	return {
			controller_command = chip.command,
			mode = c.mode,
			count = c.count,
			masked = c.masked,
			dreq = c.dreq,
		},
		true
}

@(private = "file")
machine_audio_dreq_adapter :: proc(ctx: rawptr, channel: int, asserted: bool) {
	m := (^Machine)(ctx)
	if m == nil {return}
	dma_set_hardware_request(&m.platform.dma, channel, asserted)
}

@(private = "file")
machine_audio_legacy_irq_adapter :: proc(ctx: rawptr, irq: u8) {
	m := (^Machine)(ctx)
	if m == nil {return}
	pic_raise(&m.platform.pic, irq)
}

@(private = "file")
machine_audio_native_irq_adapter :: proc(ctx: rawptr, asserted: bool) {
	machine_gsw_sound_irq(ctx, asserted)
}

@(private = "file")
machine_audio_guest_memory_adapter :: proc(ctx: rawptr) -> []u8 {
	m := (^Machine)(ctx)
	if m == nil {return nil}
	return m.vm.ram
}

@(private = "package")
machine_audio_apply_gsw_observation :: proc(m: ^Machine) {
	observation := sound.gsw_sound_observation(&m.gsw_sound)
	sound.audio_mixer_set_gain_pairs(
		&m.audio,
		observation.speaker_gain_left,
		observation.speaker_gain_right,
		observation.cdda_gain_left,
		observation.cdda_gain_right,
	)
	sound.audio_mixer_set_source_active(&m.audio, .SB16, observation.sb16_active)
	sound.audio_mixer_set_source_active(&m.audio, .OPL3, observation.opl3_active)
	sound.audio_mixer_set_source_active(&m.audio, .Native_PCM, observation.native_active)
}

@(private = "file")
machine_audio_gsw_publish_adapter :: proc(
	ctx: rawptr,
	source: sound.Gsw_Sound_Source,
	at_tick: u64,
	frame: sound.Audio_Frame,
) {
	m := (^Machine)(ctx)
	if m == nil {return}
	switch source {
	case .SB16:
		_ = sound.audio_mixer_set_sb16_frame(&m.audio, at_tick, frame)
	case .OPL3:
		_ = sound.audio_mixer_set_opl3_frame(&m.audio, at_tick, frame)
	case .Native_PCM:
		_ = sound.audio_mixer_set_native_pcm_frame(&m.audio, at_tick, frame)
	}
}

@(private = "file")
machine_audio_gsw_release_adapter :: proc(
	ctx: rawptr,
	source: sound.Gsw_Sound_Source,
	at_tick: u64,
) {
	m := (^Machine)(ctx)
	if m == nil {return}
	if source == .Native_PCM {
		_ = sound.audio_mixer_release_native_pcm(&m.audio, at_tick)
	}
}

@(private = "package")
machine_audio_gsw_adapters :: proc(m: ^Machine) -> sound.Gsw_Sound_Adapters {
	return {
		ctx = m,
		guest_memory = machine_audio_guest_memory_adapter,
		dma_snapshot = machine_audio_dma_snapshot_adapter,
		dma_read_byte = machine_sb16_dma_read_byte,
		dma_read_word = machine_sb16_dma_read_word,
		dreq = machine_audio_dreq_adapter,
		legacy_irq = machine_audio_legacy_irq_adapter,
		native_irq = machine_audio_native_irq_adapter,
		publish_completed = machine_audio_gsw_publish_adapter,
		release_completed = machine_audio_gsw_release_adapter,
	}
}

@(private = "package")
machine_audio_advance_gsw_to :: proc(m: ^Machine, tick: u64) {
	adapter := machine_audio_gsw_adapters(m)
	sound.gsw_sound_advance_to(&m.gsw_sound, tick, adapter)
	machine_audio_apply_gsw_observation(m)
}

@(private = "package")
machine_audio_render_to :: proc(m: ^Machine, tick: u64) {
	machine_audio_apply_gsw_observation(m)
	machine_audio_drain_cdda(m)
	transitions := pit_channel2_transition_slice(&m.platform.pit)
	transition_index := 0
	speaker_enabled := m.platform.pit.port61_low & 0x02 != 0
	if !speaker_enabled {transition_index = len(transitions)}
	for transition_index < len(transitions) && transitions[transition_index].master_tick <= tick {
		next_tick := transitions[transition_index].master_tick
		// GSW-Sound's target is inclusive. Stop one tick short, integrate
		// the preceding interval, then apply every PIT edge at this tick
		// before allowing any coincident GSW event to publish.
		if next_tick > 0 {machine_audio_advance_gsw_to(m, next_tick - 1)}
		_ = sound.audio_mixer_advance_to(&m.audio, next_tick)
		for transition_index < len(transitions) &&
		    transitions[transition_index].master_tick == next_tick {
			_ = sound.audio_mixer_set_speaker_state(
				&m.audio,
				next_tick,
				true,
				transitions[transition_index].level,
			)
			transition_index += 1
		}
		machine_audio_advance_gsw_to(m, next_tick)
	}
	sound.audio_mixer_record_speaker_dropped(&m.audio, pit_channel2_transitions_dropped(&m.platform.pit))
	pit_clear_channel2_transitions(&m.platform.pit)
	machine_audio_advance_gsw_to(m, tick)
	_ = sound.audio_mixer_advance_to(&m.audio, tick)
}

@(private = "package")
machine_audio_apply_pit_transitions :: proc(m: ^Machine) {
	transitions := pit_channel2_transition_slice(&m.platform.pit)
	dropped := pit_channel2_transitions_dropped(&m.platform.pit)
	if len(transitions) == 0 && dropped == 0 {return}
	if m.platform.pit.port61_low & 0x02 == 0 {
		sound.audio_mixer_record_speaker_dropped(&m.audio, dropped)
		pit_clear_channel2_transitions(&m.platform.pit)
		return
	}
	machine_audio_render_to(m, pit_now(&m.platform.pit))
}

@(private = "package")
machine_audio_advance_to :: proc(m: ^Machine, tick: u64) {
	for _ in 0 ..< pit_advance_to(&m.platform.pit, tick) {pic_raise(&m.platform.pic, 0)}
	machine_audio_render_to(m, tick)
}

@(private = "package")
machine_sb16_read :: proc(ctx: rawptr, port: u16, size: u8) -> u32 {
	m := (^Machine)(ctx)
	machine_sync_device(m, .Audio)
	value, _ := sound.gsw_sound_legacy_read(&m.gsw_sound, port, machine_audio_gsw_adapters(m))
	machine_audio_apply_gsw_observation(m)
	return u32(value)
}

@(private = "package")
machine_sb16_write :: proc(ctx: rawptr, port: u16, size: u8, val: u32) {
	m := (^Machine)(ctx)
	machine_sync_device(m, .Audio)
	now := master_timeline_now(m.timeline)
	_ = sound.gsw_sound_legacy_write(
		&m.gsw_sound,
		port,
		u8(val),
		now,
		machine_audio_gsw_adapters(m),
	)
	machine_audio_apply_gsw_observation(m)
}

@(private = "package")
machine_opl3_read :: proc(ctx: rawptr, port: u16, size: u8) -> u32 {
	m := (^Machine)(ctx)
	machine_sync_device(m, .Audio)
	value, _ := sound.gsw_sound_legacy_read(&m.gsw_sound, port, machine_audio_gsw_adapters(m))
	machine_audio_apply_gsw_observation(m)
	return u32(value)
}

@(private = "package")
machine_opl3_write :: proc(ctx: rawptr, port: u16, size: u8, val: u32) {
	m := (^Machine)(ctx)
	machine_sync_device(m, .Audio)
	now := master_timeline_now(m.timeline)
	_ = sound.gsw_sound_legacy_write(
		&m.gsw_sound,
		port,
		u8(val),
		now,
		machine_audio_gsw_adapters(m),
	)
	machine_audio_apply_gsw_observation(m)
}
