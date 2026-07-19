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
machine_audio_consider_deadline :: proc(deadline: ^u64, pending: ^bool, candidate: u64, ok: bool) {
	if ok && (!pending^ || candidate < deadline^) {
		deadline^ = candidate
		pending^ = true
	}
}

@(private = "file")
machine_audio_sb16_dma_can_finish_block :: proc(m: ^Machine) -> bool {
	if m.sb16.silence_active {return true}
	channel :=
		m.sb16.dma_16bit ? sound.ct1745_selected_dma16(&m.sb16.mixer) : sound.ct1745_selected_dma8(&m.sb16.mixer)
	if channel < 0 || channel >= len(m.dma.ch) {return false}
	c := &m.dma.ch[channel]
	chip := channel < 4 ? &m.dma.master : &m.dma.slave
	if chip.command & 4 != 0 ||
	   c.masked ||
	   (c.mode >> 6) & 3 == 3 ||
	   (c.mode >> 2) & 3 != 2 ||
	   !c.dreq {
		return false
	}
	if channel < 4 {
		cascade := &m.dma.ch[4]
		if m.dma.slave.command & 4 != 0 || cascade.masked || (cascade.mode >> 6) & 3 != 3 {
			return false
		}
	}
	return c.mode & 0x10 != 0 || u32(c.count) + 1 >= m.sb16.block_remaining
}

@(private = "file")
machine_audio_sb16_adpcm_sample_events :: proc(sb: ^sound.Sb16) -> u64 {
	queued_samples := u64(max(sb.adpcm.sample_count, 0))
	data_bytes := u64(sb.block_remaining)
	if sb.adpcm.wants_reference && data_bytes > 0 {data_bytes -= 1}
	if data_bytes == 0 {return queued_samples + 1}
	samples_per_byte: u64
	switch sb.adpcm.mode {
	case .Bits_4:
		samples_per_byte = 2
	case .Bits_26:
		samples_per_byte = 3
	case .Bits_2:
		samples_per_byte = 4
	case .None:
		return 0
	}
	// The first pending byte is fetched at the next sample event. Each prior
	// encoded byte must drain all of its decoded samples before another fetch.
	return queued_samples + 1 + (data_bytes - 1) * samples_per_byte
}

@(private = "package")
machine_audio_sb16_block_deadline :: proc(m: ^Machine) -> (u64, bool) {
	sb := &m.sb16
	if !sb.playing ||
	   !sb.sample_scheduled ||
	   sb.block_remaining == 0 ||
	   !machine_audio_sb16_dma_can_finish_block(m) {
		return 0, false
	}
	sample_events := u64(0)
	if sound.sb16_adpcm_active(&sb.adpcm) {
		sample_events = machine_audio_sb16_adpcm_sample_events(sb)
	} else {
		stereo := sb.stereo || !sb.dma_16bit && sound.ct1745_sbpro_stereo(&sb.mixer)
		units_per_frame := stereo ? u64(2) : u64(1)
		sample_events = (u64(sb.block_remaining) + units_per_frame - 1) / units_per_frame
	}
	if sample_events == 0 {return 0, false}
	if sample_events <= 1 {return sb.next_sample_tick, true}
	rate := u64(sound.sb16_output_rate(sb))
	intervals := u128(sample_events - 1)
	base := u128(sound.AUDIO_MASTER_CLOCK_HZ / rate)
	remainder := u128(sound.AUDIO_MASTER_CLOCK_HZ % rate)
	extra := (u128(sb.sample_remainder) + intervals * remainder) / u128(rate)
	delta := intervals * base + extra
	if delta > u128(~u64(0) - sb.next_sample_tick) {return ~u64(0), true}
	return sb.next_sample_tick + u64(delta), true
}

@(private = "file")
machine_audio_sb16_block_deadline_adapter :: proc(ctx: rawptr) -> (u64, bool) {
	return machine_audio_sb16_block_deadline((^Machine)(ctx))
}

@(private = "package")
machine_audio_next_deadline :: proc(m: ^Machine) -> (deadline: u64, pending: bool) {
	deadline, pending = sound.audio_mixer_next_deadline_tick(&m.audio)
	if sound.gsw_sound_has_internal_samples(&m.gsw_sound) {
		candidate, ok := sound.audio_mixer_next_render_deadline_tick(&m.audio)
		machine_audio_consider_deadline(&deadline, &pending, candidate, ok)
	}
	adapter := machine_audio_gsw_adapters(m)
	candidate, ok := sound.gsw_sound_next_observable_deadline(
		&m.gsw_sound,
		adapter,
	)
	machine_audio_consider_deadline(&deadline, &pending, candidate, ok)
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
	if m.sb16.playing && !m.sb16.silence_active {
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

@(private = "file")
machine_audio_legacy_irq_adapter :: proc(ctx: rawptr, dma16: bool) {
	m := (^Machine)(ctx)
	if m == nil {return}
	sound.ct1745_set_irq_status(&m.sb16.mixer, dma16)
	pic_raise(&m.pic, sound.ct1745_selected_irq(&m.sb16.mixer))
}

@(private = "package")
machine_audio_forward_sb16_irq :: proc(m: ^Machine) {
	dma16, pending := sound.sb16_take_irq(&m.sb16)
	if !pending {return}
	machine_audio_legacy_irq_adapter(m, dma16)
}

@(private = "package")
machine_audio_refresh_mixer_gains :: proc(m: ^Machine) {
	cd_left, cd_right := sound.ct1745_cd_gain_pair(&m.sb16.mixer)
	speaker_left, speaker_right := sound.ct1745_speaker_gain_pair(&m.sb16.mixer)
	sound.audio_mixer_set_gain_pairs(&m.audio, speaker_left, speaker_right, cd_left, cd_right)
}

@(private = "package")
machine_audio_refresh_source_activity :: proc(m: ^Machine) {
	sound.audio_mixer_set_source_active(
		&m.audio,
		.SB16,
		m.sb16.sample_scheduled || m.sb16.direct_dac_valid,
	)
	sound.audio_mixer_set_source_active(&m.audio, .OPL3, m.opl3.sample_scheduled)
	sound.audio_mixer_set_source_active(
		&m.audio,
		.Native_PCM,
		sound.gsw_pcm_running(&m.gsw_pcm) &&
			m.gsw_pcm.status & sound.GSW_PCM_STATUS_UNDERRUN == 0,
	)
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
	machine_audio_refresh_source_activity(m)
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
	machine_audio_refresh_source_activity(m)
}

@(private = "file")
machine_audio_gsw_adapters :: proc(m: ^Machine) -> sound.Gsw_Sound_Adapters {
	return {
		ctx                   = m,
		ram                   = m.vm.ram,
		dma_read_byte         = machine_sb16_dma_read_byte,
		dma_read_word         = machine_sb16_dma_read_word,
		publish               = machine_audio_gsw_publish_adapter,
		release               = machine_audio_gsw_release_adapter,
		legacy_irq            = machine_audio_legacy_irq_adapter,
		legacy_block_deadline = machine_audio_sb16_block_deadline_adapter,
	}
}

@(private = "file")
machine_audio_advance_gsw_to :: proc(m: ^Machine, tick: u64) {
	adapter := machine_audio_gsw_adapters(m)
	sound.gsw_sound_advance_to(&m.gsw_sound, tick, adapter)
	machine_audio_refresh_source_activity(m)
	machine_audio_refresh_sb16_dreq(m)
}

@(private = "package")
machine_audio_publish_sources :: proc(m: ^Machine, tick: u64) {
	machine_audio_refresh_mixer_gains(m)
	_ = sound.audio_mixer_set_sb16_frame(&m.audio, tick, sound.sb16_output_frame(&m.sb16))
	opl := sound.ct1745_apply_gain(&m.sb16.mixer, sound.opl3_current_output(&m.opl3), false)
	_ = sound.audio_mixer_set_opl3_frame(&m.audio, tick, opl)
	machine_audio_refresh_source_activity(m)
}

@(private = "package")
machine_audio_render_to :: proc(m: ^Machine, tick: u64) {
	machine_audio_refresh_mixer_gains(m)
	machine_audio_refresh_source_activity(m)
	machine_audio_drain_cdda(m)
	transitions := pit_channel2_transition_slice(&m.pit)
	transition_index := 0
	speaker_enabled := m.pit.port61_low & 0x02 != 0
	if !speaker_enabled {transition_index = len(transitions)}
	for transition_index < len(transitions) &&
	    transitions[transition_index].master_tick <= tick {
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
	sound.audio_mixer_record_speaker_dropped(&m.audio, pit_channel2_transitions_dropped(&m.pit))
	pit_clear_channel2_transitions(&m.pit)
	machine_audio_advance_gsw_to(m, tick)
	_ = sound.audio_mixer_advance_to(&m.audio, tick)
	machine_audio_forward_sb16_irq(m)
	machine_audio_refresh_sb16_dreq(m)
}

@(private = "package")
machine_audio_apply_pit_transitions :: proc(m: ^Machine) {
	transitions := pit_channel2_transition_slice(&m.pit)
	dropped := pit_channel2_transitions_dropped(&m.pit)
	if len(transitions) == 0 && dropped == 0 {return}
	if m.pit.port61_low & 0x02 == 0 {
		sound.audio_mixer_record_speaker_dropped(&m.audio, dropped)
		pit_clear_channel2_transitions(&m.pit)
		return
	}
	machine_audio_render_to(m, pit_now(&m.pit))
}

@(private = "package")
machine_audio_advance_to :: proc(m: ^Machine, tick: u64) {
	for _ in 0 ..< pit_advance_to(&m.pit, tick) {pic_raise(&m.pic, 0)}
	machine_audio_render_to(m, tick)
}

@(private = "package")
machine_sb16_read :: proc(ctx: rawptr, port: u16, size: u8) -> u32 {
	m := (^Machine)(ctx)
	machine_sync_device(m, .Audio)
	value, _ := sound.gsw_sound_legacy_read(&m.gsw_sound, port)
	machine_audio_refresh_sb16_dreq(m)
	return u32(value)
}

@(private = "package")
machine_sb16_write :: proc(ctx: rawptr, port: u16, size: u8, val: u32) {
	m := (^Machine)(ctx)
	machine_sync_device(m, .Audio)
	_ = sound.gsw_sound_legacy_write(&m.gsw_sound, port, u8(val))
	now := master_timeline_now(m.timeline)
	machine_audio_publish_sources(m, now)
	machine_audio_forward_sb16_irq(m)
	machine_audio_refresh_sb16_dreq(m)
}

@(private = "package")
machine_opl3_read :: proc(ctx: rawptr, port: u16, size: u8) -> u32 {
	m := (^Machine)(ctx)
	machine_sync_device(m, .Audio)
	value, _ := sound.gsw_sound_legacy_read(&m.gsw_sound, port)
	return u32(value)
}

@(private = "package")
machine_opl3_write :: proc(ctx: rawptr, port: u16, size: u8, val: u32) {
	m := (^Machine)(ctx)
	machine_sync_device(m, .Audio)
	_ = sound.gsw_sound_legacy_write(&m.gsw_sound, port, u8(val))
	now := master_timeline_now(m.timeline)
	machine_audio_publish_sources(m, now)
}
