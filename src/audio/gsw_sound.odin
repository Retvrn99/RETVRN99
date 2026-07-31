// SPDX-License-Identifier: GPL-3.0-only
package audio

// GSW-Sound owns the legacy and native guest-audio personalities. Machine
// supplies platform operations and the final-mix sink through these Adapters.

Gsw_Sound_Source :: enum u8 {
	SB16,
	OPL3,
	Native_PCM,
}

Gsw_Sound_Dma_Channel_Snapshot :: struct {
	controller_command: u8,
	mode:               u8,
	count:              u16,
	masked:             bool,
	dreq:               bool,
}

Gsw_Sound_Dma_Snapshot_Proc :: proc(
	ctx: rawptr,
	channel: int,
) -> (
	Gsw_Sound_Dma_Channel_Snapshot,
	bool,
)
Gsw_Sound_Dreq_Proc :: proc(ctx: rawptr, channel: int, asserted: bool)
Gsw_Sound_Irq_Proc :: proc(ctx: rawptr, irq: u8)
Gsw_Sound_Irq_Level_Proc :: proc(ctx: rawptr, asserted: bool)
Gsw_Sound_Guest_Memory_Proc :: proc(ctx: rawptr) -> []u8
Gsw_Sound_Publish_Proc :: proc(
	ctx: rawptr,
	source: Gsw_Sound_Source,
	at_tick: u64,
	frame: Audio_Frame,
)
Gsw_Sound_Release_Proc :: proc(ctx: rawptr, source: Gsw_Sound_Source, at_tick: u64)

Gsw_Sound_Adapters :: struct {
	ctx:               rawptr,
	guest_memory:      Gsw_Sound_Guest_Memory_Proc,
	dma_snapshot:      Gsw_Sound_Dma_Snapshot_Proc,
	dma_read_byte:     Sb16_Dma_Read_Byte_Proc,
	dma_read_word:     Sb16_Dma_Read_Word_Proc,
	dreq:              Gsw_Sound_Dreq_Proc,
	legacy_irq:        Gsw_Sound_Irq_Proc,
	native_irq:        Gsw_Sound_Irq_Level_Proc,
	publish_completed: Gsw_Sound_Publish_Proc,
	release_completed: Gsw_Sound_Release_Proc,
}

Gsw_Sound_Observation :: struct {
	selected_dma8:            int,
	selected_dma16:           int,
	selected_irq:             u8,
	dreq_channel:             int,
	dreq_active:              bool,
	sb16_active:              bool,
	opl3_active:              bool,
	native_active:            bool,
	speaker_gain_left:        u32,
	speaker_gain_right:       u32,
	cdda_gain_left:           u32,
	cdda_gain_right:          u32,
	sb16_frame:               Audio_Frame,
	opl3_frame:               Audio_Frame,
	native_frame:             Audio_Frame,
	sb16_sample_deadline:     u64,
	sb16_sample_pending:      bool,
	opl3_sample_deadline:     u64,
	opl3_sample_pending:      bool,
	opl3_timer1_deadline:     u64,
	opl3_timer1_pending:      bool,
	opl3_timer2_deadline:     u64,
	opl3_timer2_pending:      bool,
	native_sample_deadline:   u64,
	native_sample_pending:    bool,
	opl3_global_sample_index: u64,
	opl3_register_fnv1a64:    u64,
	sb16_starvation_frames:   u64,
	sb16_irq_events:          u64,
	native_position_bytes:    u64,
	native_starvation_frames: u64,
	native_irq_events:        u64,
	native_irq_status:        u32,
}

@(private = "file")
Gsw_Sound_State :: struct {
	sb16:                Sb16,
	opl3:                Opl3,
	native_pcm:          Gsw_Pcm,
	dreq_channel:        int,
	dreq_active:         bool,
	native_irq_asserted: bool,
}

Gsw_Sound :: struct {
	state: Gsw_Sound_State,
}

gsw_sound_init :: proc(g: ^Gsw_Sound) {
	if g == nil {return}
	g^ = {}
	g.state.dreq_channel = -1
	sb16_init(&g.state.sb16)
	opl3_init(&g.state.opl3)
	gsw_pcm_init(&g.state.native_pcm)
}

@(private = "file")
gsw_sound_guest_memory :: proc(adapter: Gsw_Sound_Adapters) -> []u8 {
	if adapter.guest_memory == nil {return nil}
	return adapter.guest_memory(adapter.ctx)
}

@(private = "file")
gsw_sound_publish :: proc(
	adapter: Gsw_Sound_Adapters,
	source: Gsw_Sound_Source,
	at_tick: u64,
	frame: Audio_Frame,
) {
	if adapter.publish_completed != nil {
		adapter.publish_completed(adapter.ctx, source, at_tick, frame)
	}
}

@(private = "file")
gsw_sound_release :: proc(adapter: Gsw_Sound_Adapters, source: Gsw_Sound_Source, at_tick: u64) {
	if adapter.release_completed != nil {
		adapter.release_completed(adapter.ctx, source, at_tick)
	}
}

@(private = "file")
gsw_sound_sync_dreq :: proc(g: ^Gsw_Sound, adapter: Gsw_Sound_Adapters) {
	desired := -1
	sb := &g.state.sb16
	if sb.playing && !sb.silence_active {
		desired = sb.dma_16bit ? ct1745_selected_dma16(&sb.mixer) : ct1745_selected_dma8(&sb.mixer)
	}
	state := &g.state
	if state.dreq_active && state.dreq_channel != desired {
		if adapter.dreq != nil {adapter.dreq(adapter.ctx, state.dreq_channel, false)}
		state.dreq_active = false
	}
	if desired >= 0 && (!state.dreq_active || state.dreq_channel != desired) {
		if adapter.dreq != nil {adapter.dreq(adapter.ctx, desired, true)}
		state.dreq_channel = desired
		state.dreq_active = true
	}
}

@(private = "file")
gsw_sound_forward_legacy_irq :: proc(g: ^Gsw_Sound, adapter: Gsw_Sound_Adapters) {
	dma16, pending := sb16_take_irq(&g.state.sb16)
	if !pending {return}
	ct1745_set_irq_status(&g.state.sb16.mixer, dma16)
	if adapter.legacy_irq != nil {
		adapter.legacy_irq(adapter.ctx, ct1745_selected_irq(&g.state.sb16.mixer))
	}
}

@(private = "file")
gsw_sound_sync_native_irq :: proc(g: ^Gsw_Sound, adapter: Gsw_Sound_Adapters) {
	native := &g.state.native_pcm
	asserted := native.irq_status & native.irq_enable != 0
	if asserted == g.state.native_irq_asserted {return}
	g.state.native_irq_asserted = asserted
	if adapter.native_irq != nil {adapter.native_irq(adapter.ctx, asserted)}
}

@(private = "file")
gsw_sound_sync_platform :: proc(g: ^Gsw_Sound, adapter: Gsw_Sound_Adapters) {
	gsw_sound_sync_dreq(g, adapter)
	gsw_sound_sync_native_irq(g, adapter)
}

@(private = "file")
gsw_sound_publish_legacy_state :: proc(g: ^Gsw_Sound, at_tick: u64, adapter: Gsw_Sound_Adapters) {
	gsw_sound_publish(adapter, .SB16, at_tick, sb16_output_frame(&g.state.sb16))
	opl := ct1745_apply_gain(&g.state.sb16.mixer, opl3_current_output(&g.state.opl3), false)
	gsw_sound_publish(adapter, .OPL3, at_tick, opl)
}

gsw_sound_advance_to :: proc(g: ^Gsw_Sound, target_tick: u64, adapter: Gsw_Sound_Adapters) {
	if g == nil {return}
	state := &g.state
	ram := gsw_sound_guest_memory(adapter)
	for {
		next_tick: u64
		pending := false
		if deadline, ok := sb16_sample_deadline(&state.sb16); ok && deadline <= target_tick {
			next_tick, pending = deadline, true
		}
		if deadline, ok := opl3_sample_deadline(&state.opl3);
		   ok && deadline <= target_tick && (!pending || deadline < next_tick) {
			next_tick, pending = deadline, true
		}
		if deadline, ok := gsw_pcm_next_sample_deadline_tick(&state.native_pcm);
		   ok && deadline <= target_tick && (!pending || deadline < next_tick) {
			next_tick, pending = deadline, true
		}
		if !pending {break}

		sb16_advance_control_to(&state.sb16, next_tick)
		opl3_advance_control_to(&state.opl3, next_tick)
		if deadline, ok := sb16_sample_deadline(&state.sb16); ok && deadline == next_tick {
			_, produced := sb16_render_sample(
				&state.sb16,
				adapter.ctx,
				adapter.dma_read_byte,
				adapter.dma_read_word,
			)
			frame := produced ? sb16_output_frame(&state.sb16) : Audio_Frame{}
			gsw_sound_publish(adapter, .SB16, next_tick, frame)
			gsw_sound_forward_legacy_irq(g, adapter)
		}
		if deadline, ok := opl3_sample_deadline(&state.opl3); ok && deadline == next_tick {
			frame, produced := opl3_render_sample(&state.opl3)
			if produced {
				frame = ct1745_apply_gain(&state.sb16.mixer, frame, false)
				gsw_sound_publish(adapter, .OPL3, next_tick, frame)
			}
		}
		if deadline, ok := gsw_pcm_next_sample_deadline_tick(&state.native_pcm);
		   ok && deadline == next_tick {
			starvation_before := state.native_pcm.starvation_frames
			underrun_before := state.native_pcm.status & GSW_PCM_STATUS_UNDERRUN != 0
			frame, produced := gsw_pcm_render_sample(&state.native_pcm, next_tick, ram)
			gsw_sound_sync_native_irq(g, adapter)
			if !underrun_before && state.native_pcm.status & GSW_PCM_STATUS_UNDERRUN != 0 {
				gsw_sound_release(adapter, .Native_PCM, next_tick)
			} else if produced && state.native_pcm.starvation_frames == starvation_before {
				gsw_sound_publish(adapter, .Native_PCM, next_tick, frame)
			}
		}
		gsw_sound_sync_platform(g, adapter)
	}
	_ = gsw_pcm_advance_to(&state.native_pcm, target_tick, ram)
	sb16_advance_control_to(&state.sb16, target_tick)
	opl3_advance_control_to(&state.opl3, target_tick)
	gsw_sound_sync_platform(g, adapter)
}

gsw_sound_has_internal_samples :: proc(g: ^Gsw_Sound) -> bool {
	if g == nil {return false}
	_, sb16_pending := sb16_sample_deadline(&g.state.sb16)
	_, opl3_pending := opl3_sample_deadline(&g.state.opl3)
	_, native_pending := gsw_pcm_next_sample_deadline_tick(&g.state.native_pcm)
	return sb16_pending || opl3_pending || native_pending
}

@(private = "file")
gsw_sound_consider_deadline :: proc(deadline: ^u64, pending: ^bool, candidate: u64, ok: bool) {
	if ok && (!pending^ || candidate < deadline^) {
		deadline^ = candidate
		pending^ = true
	}
}

@(private = "file")
gsw_sound_dma_can_finish_block :: proc(g: ^Gsw_Sound, adapter: Gsw_Sound_Adapters) -> bool {
	sb := &g.state.sb16
	if sb.silence_active {return true}
	if adapter.dma_snapshot == nil {return false}
	channel := sb.dma_16bit ? ct1745_selected_dma16(&sb.mixer) : ct1745_selected_dma8(&sb.mixer)
	snapshot, ok := adapter.dma_snapshot(adapter.ctx, channel)
	if !ok ||
	   snapshot.controller_command & 4 != 0 ||
	   snapshot.masked ||
	   (snapshot.mode >> 6) & 3 == 3 ||
	   (snapshot.mode >> 2) & 3 != 2 ||
	   !snapshot.dreq {
		return false
	}
	if channel < 4 {
		cascade, cascade_ok := adapter.dma_snapshot(adapter.ctx, 4)
		if !cascade_ok ||
		   cascade.controller_command & 4 != 0 ||
		   cascade.masked ||
		   (cascade.mode >> 6) & 3 != 3 {
			return false
		}
	}
	return snapshot.mode & 0x10 != 0 || u32(snapshot.count) + 1 >= sb.block_remaining
}

@(private = "file")
gsw_sound_adpcm_sample_events :: proc(sb: ^Sb16) -> u64 {
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
	return queued_samples + 1 + (data_bytes - 1) * samples_per_byte
}

@(private = "file")
gsw_sound_legacy_block_deadline :: proc(
	g: ^Gsw_Sound,
	adapter: Gsw_Sound_Adapters,
) -> (
	u64,
	bool,
) {
	sb := &g.state.sb16
	if !sb.playing ||
	   !sb.sample_scheduled ||
	   sb.block_remaining == 0 ||
	   !gsw_sound_dma_can_finish_block(g, adapter) {
		return 0, false
	}
	sample_events := u64(0)
	if sb16_adpcm_active(&sb.adpcm) {
		sample_events = gsw_sound_adpcm_sample_events(sb)
	} else {
		stereo := sb.stereo || !sb.dma_16bit && ct1745_sbpro_stereo(&sb.mixer)
		units_per_frame := stereo ? u64(2) : u64(1)
		sample_events = (u64(sb.block_remaining) + units_per_frame - 1) / units_per_frame
	}
	if sample_events == 0 {return 0, false}
	if sample_events <= 1 {return sb.next_sample_tick, true}
	rate := u64(sb16_output_rate(sb))
	intervals := u128(sample_events - 1)
	base := u128(AUDIO_MASTER_CLOCK_HZ / rate)
	remainder := u128(AUDIO_MASTER_CLOCK_HZ % rate)
	extra := (u128(sb.sample_remainder) + intervals * remainder) / u128(rate)
	delta := intervals * base + extra
	if delta > u128(~u64(0) - sb.next_sample_tick) {return ~u64(0), true}
	return sb.next_sample_tick + u64(delta), true
}

gsw_sound_next_observable_deadline :: proc(
	g: ^Gsw_Sound,
	adapter: Gsw_Sound_Adapters,
) -> (
	deadline: u64,
	pending: bool,
) {
	if g == nil {return 0, false}
	state := &g.state
	if state.sb16.reset_pending {
		gsw_sound_consider_deadline(&deadline, &pending, state.sb16.reset_deadline, true)
	}
	candidate, ok := gsw_sound_legacy_block_deadline(g, adapter)
	gsw_sound_consider_deadline(&deadline, &pending, candidate, ok)
	candidate, ok = opl3_timer_deadline(&state.opl3, &state.opl3.timer1)
	gsw_sound_consider_deadline(&deadline, &pending, candidate, ok)
	candidate, ok = opl3_timer_deadline(&state.opl3, &state.opl3.timer2)
	gsw_sound_consider_deadline(&deadline, &pending, candidate, ok)
	candidate, ok = gsw_pcm_next_deadline_tick(&state.native_pcm)
	gsw_sound_consider_deadline(&deadline, &pending, candidate, ok)
	return
}

gsw_sound_legacy_read :: proc(
	g: ^Gsw_Sound,
	port: u16,
	adapter := Gsw_Sound_Adapters{},
) -> (
	u8,
	bool,
) {
	if g == nil {return 0xFF, false}
	value: u8
	handled: bool
	if port >= SB16_BASE_PORT && port <= SB16_BASE_PORT + 3 {
		value, handled = opl3_read_port(&g.state.opl3, OPL3_BASE_PORT + port - SB16_BASE_PORT)
	} else if port >= OPL3_BASE_PORT && port <= OPL3_LAST_PORT {
		value, handled = opl3_read_port(&g.state.opl3, port)
	} else {
		value, handled = sb16_read_port(&g.state.sb16, port)
	}
	gsw_sound_sync_platform(g, adapter)
	return value, handled
}

gsw_sound_legacy_write :: proc(
	g: ^Gsw_Sound,
	port: u16,
	value: u8,
	at_tick := u64(0),
	adapter := Gsw_Sound_Adapters{},
) -> bool {
	if g == nil {return false}
	handled: bool
	if port >= SB16_BASE_PORT && port <= SB16_BASE_PORT + 3 {
		handled = opl3_write_port(&g.state.opl3, OPL3_BASE_PORT + port - SB16_BASE_PORT, value)
	} else if port >= OPL3_BASE_PORT && port <= OPL3_LAST_PORT {
		handled = opl3_write_port(&g.state.opl3, port, value)
	} else {
		handled = sb16_write_port(&g.state.sb16, port, value)
	}
	gsw_sound_publish_legacy_state(g, at_tick, adapter)
	gsw_sound_forward_legacy_irq(g, adapter)
	gsw_sound_sync_platform(g, adapter)
	return handled
}

gsw_sound_pci_control_offset :: proc(g: ^Gsw_Sound, gpa: u64, size: int) -> (u32, bool) {
	if g == nil {return 0, false}
	return gsw_pcm_control_offset(&g.state.native_pcm, gpa, size)
}

gsw_sound_pci_mmio_read :: proc(g: ^Gsw_Sound, offset: u32, data: []u8) {
	if g == nil {return}
	gsw_pcm_mmio_read(&g.state.native_pcm, offset, data)
}

gsw_sound_pci_mmio_write :: proc(
	g: ^Gsw_Sound,
	offset: u32,
	data: []u8,
	at_tick: u64,
	adapter: Gsw_Sound_Adapters,
) {
	if g == nil {return}
	native := &g.state.native_pcm
	was_running := gsw_pcm_running(native)
	gsw_pcm_mmio_write(native, offset, data, gsw_sound_guest_memory(adapter))
	gsw_sound_sync_native_irq(g, adapter)
	if was_running && !gsw_pcm_running(native) {
		gsw_sound_release(adapter, .Native_PCM, at_tick)
	} else if gsw_pcm_running(native) && native.status & GSW_PCM_STATUS_UNDERRUN == 0 {
		gsw_sound_publish(adapter, .Native_PCM, at_tick, gsw_pcm_current_frame(native))
	}
}

gsw_sound_set_pci_decode :: proc(
	g: ^Gsw_Sound,
	memory_space_enabled, bus_master_enabled: bool,
	control_base, at_tick: u64,
	adapter: Gsw_Sound_Adapters,
) {
	if g == nil {return}
	was_running := gsw_pcm_running(&g.state.native_pcm)
	gsw_pcm_set_pci_decode(
		&g.state.native_pcm,
		memory_space_enabled,
		bus_master_enabled,
		control_base,
	)
	gsw_sound_sync_native_irq(g, adapter)
	if was_running && !gsw_pcm_running(&g.state.native_pcm) {
		gsw_sound_release(adapter, .Native_PCM, at_tick)
	}
}

@(private = "file")
gsw_sound_opl3_register_hash :: proc(opl: ^Opl3) -> u64 {
	hash := u64(14_695_981_039_346_656_037)
	for bank in 0 ..< len(opl.registers) {
		for value in opl.registers[bank] {
			hash = (hash ~ u64(value)) * u64(1_099_511_628_211)
		}
	}
	return hash
}

gsw_sound_observation :: proc(g: ^Gsw_Sound) -> Gsw_Sound_Observation {
	if g == nil {return {dreq_channel = -1}}
	state := &g.state
	speaker_left, speaker_right := ct1745_speaker_gain_pair(&state.sb16.mixer)
	cd_left, cd_right := ct1745_cd_gain_pair(&state.sb16.mixer)
	sb16_deadline, sb16_pending := sb16_sample_deadline(&state.sb16)
	opl3_deadline, opl3_pending := opl3_sample_deadline(&state.opl3)
	timer1_deadline, timer1_pending := opl3_timer_deadline(&state.opl3, &state.opl3.timer1)
	timer2_deadline, timer2_pending := opl3_timer_deadline(&state.opl3, &state.opl3.timer2)
	native_deadline, native_pending := gsw_pcm_next_sample_deadline_tick(&state.native_pcm)
	return {
		selected_dma8 = ct1745_selected_dma8(&state.sb16.mixer),
		selected_dma16 = ct1745_selected_dma16(&state.sb16.mixer),
		selected_irq = ct1745_selected_irq(&state.sb16.mixer),
		dreq_channel = state.dreq_channel,
		dreq_active = state.dreq_active,
		sb16_active = state.sb16.sample_scheduled || state.sb16.direct_dac_valid,
		opl3_active = state.opl3.sample_scheduled,
		native_active = gsw_pcm_running(&state.native_pcm) &&
		state.native_pcm.status & GSW_PCM_STATUS_UNDERRUN == 0,
		speaker_gain_left = speaker_left,
		speaker_gain_right = speaker_right,
		cdda_gain_left = cd_left,
		cdda_gain_right = cd_right,
		sb16_frame = sb16_output_frame(&state.sb16),
		opl3_frame = ct1745_apply_gain(&state.sb16.mixer, opl3_current_output(&state.opl3), false),
		native_frame = gsw_pcm_current_frame(&state.native_pcm),
		sb16_sample_deadline = sb16_deadline,
		sb16_sample_pending = sb16_pending,
		opl3_sample_deadline = opl3_deadline,
		opl3_sample_pending = opl3_pending,
		opl3_timer1_deadline = timer1_deadline,
		opl3_timer1_pending = timer1_pending,
		opl3_timer2_deadline = timer2_deadline,
		opl3_timer2_pending = timer2_pending,
		native_sample_deadline = native_deadline,
		native_sample_pending = native_pending,
		opl3_global_sample_index = state.opl3.global_sample_index,
		opl3_register_fnv1a64 = gsw_sound_opl3_register_hash(&state.opl3),
		sb16_starvation_frames = state.sb16.starvation_frames,
		sb16_irq_events = state.sb16.irq_events_dma8 +
		state.sb16.irq_events_dma16 +
		state.sb16.irq_events_midi,
		native_position_bytes = state.native_pcm.position_bytes,
		native_starvation_frames = state.native_pcm.starvation_frames,
		native_irq_events = state.native_pcm.period_irq_events +
		state.native_pcm.underrun_irq_events +
		state.native_pcm.invalid_irq_events,
		native_irq_status = state.native_pcm.irq_status,
	}
}
