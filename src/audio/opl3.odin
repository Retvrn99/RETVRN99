// SPDX-License-Identifier: GPL-3.0-only
package audio

// Register, timer and synthesis behavior adapted from IzarraVM commit
// b88a9fe68a8109f26632ff2802262cc38a6a5ad9. RETVRN99 retains its master-clock
// scheduler so native 49,716 Hz output is deterministically integrated into the
// 48 kHz host mixer.

OPL3_BASE_PORT :: u16(0x388)
OPL3_LAST_PORT :: u16(0x38B)
OPL3_NATIVE_HZ :: u64(49_716)
OPL3_TIMER1_TICKS :: AUDIO_MASTER_CLOCK_HZ * 80 / 1_000_000
OPL3_TIMER2_TICKS :: AUDIO_MASTER_CLOCK_HZ * 320 / 1_000_000

Opl3_Timer :: struct {
	step_ticks: u64,
	count:      u16,
	remainder:  u64,
	running:    bool,
	expired:    bool,
}

Opl3 :: struct {
	registers:           [2][256]u8,
	address:             u16,
	timer1:              Opl3_Timer,
	timer2:              Opl3_Timer,
	now_tick:            u64,
	operators:           [36]Opl3_Operator,
	eg_counter:          u32,
	noise:               u32,
	global_sample_index: u64,
	synthesis_dirty:     bool,
	sample_scheduled:    bool,
	next_sample_tick:    u64,
	current_frame:       Audio_Frame,
}

opl3_init :: proc(opl: ^Opl3) {
	opl^ = {}
	opl.timer1.step_ticks = OPL3_TIMER1_TICKS
	opl.timer2.step_ticks = OPL3_TIMER2_TICKS
	opl.noise = 1
	for index in 0 ..< len(opl.operators) {
		opl3_operator_init(&opl.operators[index])
	}
}

opl3_enabled :: proc(opl: ^Opl3) -> bool {
	return opl.registers[1][0x05] & 0x01 != 0
}

opl3_channel_active :: proc(opl: ^Opl3, channel: int) -> bool {
	if channel < 0 || channel >= 18 {return false}
	if channel >= 9 && !opl3_enabled(opl) {return false}
	bank := channel / 9
	local := channel % 9
	return opl.registers[bank][0xB0 + local] & 0x20 != 0
}

opl3_any_channel_active :: proc(opl: ^Opl3) -> bool {
	if opl.synthesis_dirty {return true}
	count := opl3_enabled(opl) ? 18 : 9
	rhythm := opl3_rhythm_enabled(opl)
	four_op_mask := opl3_four_op_mask(opl)
	for channel in 0 ..< count {
		if rhythm && channel >= 6 && channel <= 8 {continue}
		if opl3_four_op_secondary(channel, four_op_mask) {continue}
		if opl3_channel_active(opl, channel) {return true}
	}
	if rhythm && opl.registers[0][0xBD] & 0x1F != 0 {return true}
	operator_count := opl3_enabled(opl) ? 36 : 18
	for index in 0 ..< operator_count {
		if opl3_operator_audible(&opl.operators[index]) {return true}
	}
	return false
}

opl3_native_index_at_tick :: proc(tick: u64) -> u64 {
	numerator := (u128(tick) + 1) * u128(OPL3_NATIVE_HZ) - 1
	return u64(numerator / u128(AUDIO_MASTER_CLOCK_HZ))
}

opl3_native_tick_for_index :: proc(index: u64) -> u64 {
	tick := u128(index) * u128(AUDIO_MASTER_CLOCK_HZ) / u128(OPL3_NATIVE_HZ)
	return tick > u128(~u64(0)) ? ~u64(0) : u64(tick)
}

opl3_advance_globals_to :: proc(opl: ^Opl3, target_tick: u64) {
	target_index := opl3_native_index_at_tick(target_tick)
	if target_index <= opl.global_sample_index {return}
	steps := target_index - opl.global_sample_index
	opl.eg_counter += u32(steps)
	opl.noise = opl3_advance_noise_steps(opl.noise, steps)
	opl.global_sample_index = target_index
}

opl3_schedule_first_sample :: proc(opl: ^Opl3) {
	index := max(opl.global_sample_index, opl3_native_index_at_tick(opl.now_tick)) + 1
	opl.next_sample_tick = opl3_native_tick_for_index(index)
	opl.sample_scheduled = true
}

opl3_schedule_next_sample :: proc(opl: ^Opl3) {
	opl.next_sample_tick = opl3_native_tick_for_index(opl.global_sample_index + 1)
	opl.sample_scheduled = true
}

opl3_refresh_sample_clock :: proc(opl: ^Opl3) {
	if opl3_any_channel_active(opl) {
		if !opl.sample_scheduled {opl3_schedule_first_sample(opl)}
	} else {
		opl.sample_scheduled = false
		opl.current_frame = {}
	}
}

opl3_timer_start :: proc(timer: ^Opl3_Timer, preset: u8) {
	timer.count = u16(preset)
	timer.remainder = 0
	timer.running = true
}

opl3_timer_advance :: proc(timer: ^Opl3_Timer, elapsed: u64, preset: u8) {
	if !timer.running || elapsed == 0 {return}
	total := u128(timer.remainder) + u128(elapsed)
	steps := u64(total / u128(timer.step_ticks))
	timer.remainder = u64(total % u128(timer.step_ticks))
	if steps == 0 {return}
	until_overflow := u64(256 - timer.count)
	if steps < until_overflow {
		timer.count += u16(steps)
		return
	}
	timer.expired = true
	remaining := steps - until_overflow
	period := u64(256 - u16(preset))
	timer.count = u16(preset) + u16(remaining % period)
}

opl3_timer_deadline :: proc(opl: ^Opl3, timer: ^Opl3_Timer) -> (u64, bool) {
	if !timer.running || timer.expired {return 0, false}
	steps := u64(256 - timer.count)
	remaining := steps * timer.step_ticks - timer.remainder
	return opl.now_tick + min(max(remaining, u64(1)), ~u64(0) - opl.now_tick), true
}

opl3_advance_control_to :: proc(opl: ^Opl3, target_tick: u64) {
	if target_tick < opl.now_tick {return}
	elapsed := target_tick - opl.now_tick
	opl3_timer_advance(&opl.timer1, elapsed, opl.registers[0][0x02])
	opl3_timer_advance(&opl.timer2, elapsed, opl.registers[0][0x03])
	opl3_advance_globals_to(opl, target_tick)
	opl.now_tick = target_tick
}

opl3_status :: proc(opl: ^Opl3) -> u8 {
	control := opl.registers[0][0x04]
	timer1_irq := opl.timer1.expired && control & 0x40 == 0
	timer2_irq := opl.timer2.expired && control & 0x20 == 0
	return(
		u8(timer1_irq || timer2_irq ? 0x80 : 0) |
		u8(opl.timer1.expired ? 0x40 : 0) |
		u8(opl.timer2.expired ? 0x20 : 0) \
	)
}

opl3_write_register :: proc(opl: ^Opl3, bank: int, index, value: u8) {
	if bank == 0 && index == 0x04 {
		if value & 0x80 != 0 {
			opl.timer1.expired = false
			opl.timer2.expired = false
		}
		start1 := value & 0x01 != 0
		start2 := value & 0x02 != 0
		if start1 && !opl.timer1.running {
			opl3_timer_start(&opl.timer1, opl.registers[0][0x02])
		} else {
			opl.timer1.running = start1
		}
		if start2 && !opl.timer2.running {
			opl3_timer_start(&opl.timer2, opl.registers[0][0x03])
		} else {
			opl.timer2.running = start2
		}
	}
	opl.registers[bank][index] = value
	if index >= 0xB0 && index <= 0xB8 ||
	   bank == 0 && index == 0xBD ||
	   bank == 1 && (index == 0x04 || index == 0x05) {
		opl.synthesis_dirty = true
		opl3_sync_key_states(opl)
	}
	opl3_refresh_sample_clock(opl)
}

opl3_read_port :: proc(opl: ^Opl3, port: u16) -> (u8, bool) {
	switch port {
	case 0x388, 0x38A:
		return opl3_status(opl), true
	case 0x389, 0x38B:
		return 0xFF, true
	}
	return 0xFF, false
}

opl3_write_port :: proc(opl: ^Opl3, port: u16, value: u8) -> bool {
	switch port {
	case 0x388:
		opl.address = u16(value)
	case 0x38A:
		if opl3_enabled(opl) || value == 0x05 {
			opl.address = 0x100 | u16(value)
		} else {
			opl.address = u16(value)
		}
	case 0x389, 0x38B:
		opl3_write_register(opl, int(opl.address >> 8), u8(opl.address), value)
	case:
		return false
	}
	return true
}

opl3_sample_deadline :: proc(opl: ^Opl3) -> (u64, bool) {
	return opl.next_sample_tick, opl.sample_scheduled
}

opl3_next_deadline :: proc(opl: ^Opl3) -> (u64, bool) {
	deadline: u64
	pending := false
	if opl.sample_scheduled {
		deadline = opl.next_sample_tick
		pending = true
	}
	if candidate, ok := opl3_timer_deadline(opl, &opl.timer1);
	   ok && (!pending || candidate < deadline) {
		deadline = candidate
		pending = true
	}
	if candidate, ok := opl3_timer_deadline(opl, &opl.timer2);
	   ok && (!pending || candidate < deadline) {
		deadline = candidate
		pending = true
	}
	return deadline, pending
}

opl3_render_sample :: proc(opl: ^Opl3) -> (Audio_Frame, bool) {
	if !opl.sample_scheduled {return {}, false}
	opl3_advance_globals_to(opl, opl.next_sample_tick)
	left, right := opl3_synthesize_sample(opl)
	opl.synthesis_dirty = false
	opl.current_frame = {
		left  = audio_clamp_i16(i64(left)),
		right = audio_clamp_i16(i64(right)),
	}
	frame := opl.current_frame
	opl3_schedule_next_sample(opl)
	if !opl3_any_channel_active(opl) {
		opl.sample_scheduled = false
		opl.current_frame = {}
	}
	return frame, true
}

opl3_current_output :: proc(opl: ^Opl3) -> Audio_Frame {
	return opl.current_frame
}
