// SPDX-License-Identifier: GPL-3.0-only
package audio

import "core:math"

// Timer, register-bank, and channel routing behavior adapted from IzarraVM
// commit b88a9fe68a8109f26632ff2802262cc38a6a5ad9. The compact tone generator is
// deliberately a foundation: it preserves OPL3 frequency and stereo routing
// while full operator envelopes, modulation, rhythm, and four-op synthesis are
// added independently.

OPL3_BASE_PORT :: u16(0x388)
OPL3_LAST_PORT :: u16(0x38B)
OPL3_NATIVE_HZ :: u64(49_716)
OPL3_TIMER1_TICKS :: AUDIO_MASTER_CLOCK_HZ * 80 / 1_000_000
OPL3_TIMER2_TICKS :: AUDIO_MASTER_CLOCK_HZ * 320 / 1_000_000
OPL3_SINE_SIZE :: 1_024

OPL3_CARRIER_SLOTS := [9]u8{3, 4, 5, 11, 12, 13, 19, 20, 21}

Opl3_Timer :: struct {
	step_ticks: u64,
	count:      u16,
	remainder:  u64,
	running:    bool,
	expired:    bool,
}

Opl3 :: struct {
	registers:        [2][256]u8,
	address:          [2]u8,
	timer1:           Opl3_Timer,
	timer2:           Opl3_Timer,
	now_tick:         u64,
	phases:           [18]u32,
	sine:             [OPL3_SINE_SIZE]i16,
	sample_scheduled: bool,
	next_sample_tick: u64,
	sample_remainder: u64,
	current_frame:    Audio_Frame,
}

opl3_init :: proc(opl: ^Opl3) {
	opl^ = {}
	opl.timer1.step_ticks = OPL3_TIMER1_TICKS
	opl.timer2.step_ticks = OPL3_TIMER2_TICKS
	for index in 0 ..< OPL3_SINE_SIZE {
		angle := 2.0 * math.PI * f64(index) / f64(OPL3_SINE_SIZE)
		opl.sine[index] = i16(math.round(math.sin(angle) * 32_767.0))
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
	count := opl3_enabled(opl) ? 18 : 9
	for channel in 0 ..< count {
		if opl3_channel_active(opl, channel) {return true}
	}
	return false
}

opl3_schedule_first_sample :: proc(opl: ^Opl3) {
	delta := max(AUDIO_MASTER_CLOCK_HZ / OPL3_NATIVE_HZ, u64(1))
	opl.sample_remainder = AUDIO_MASTER_CLOCK_HZ % OPL3_NATIVE_HZ
	opl.next_sample_tick = opl.now_tick + min(delta, ~u64(0) - opl.now_tick)
	opl.sample_scheduled = true
}

opl3_schedule_next_sample :: proc(opl: ^Opl3) {
	delta := AUDIO_MASTER_CLOCK_HZ / OPL3_NATIVE_HZ
	opl.sample_remainder += AUDIO_MASTER_CLOCK_HZ % OPL3_NATIVE_HZ
	if opl.sample_remainder >= OPL3_NATIVE_HZ {
		opl.sample_remainder -= OPL3_NATIVE_HZ
		delta += 1
	}
	opl.next_sample_tick += min(max(delta, u64(1)), ~u64(0) - opl.next_sample_tick)
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
		opl.address[0] = value
	case 0x389:
		opl3_write_register(opl, 0, opl.address[0], value)
	case 0x38A:
		opl.address[1] = value
	case 0x38B:
		opl3_write_register(opl, 1, opl.address[1], value)
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
	left, right: i64
	channel_count := opl3_enabled(opl) ? 18 : 9
	for channel in 0 ..< channel_count {
		if !opl3_channel_active(opl, channel) {continue}
		bank := channel / 9
		local := channel % 9
		register_b := opl.registers[bank][0xB0 + local]
		f_number := u32(opl.registers[bank][0xA0 + local]) | u32(register_b & 0x03) << 8
		block := uint((register_b >> 2) & 0x07)
		increment := u32(u64(f_number) << (block + 12))
		opl.phases[channel] += increment
		sine := i32(opl.sine[int(opl.phases[channel] >> 22)])
		level := opl.registers[bank][0x40 + OPL3_CARRIER_SLOTS[local]] & 0x3F
		amplitude := i32(63 - level) * 128
		sample := i64(sine * amplitude / 32_768)
		if opl3_enabled(opl) {
			pan := opl.registers[bank][0xC0 + local]
			if pan & 0x10 != 0 {left += sample}
			if pan & 0x20 != 0 {right += sample}
		} else {
			left += sample
			right += sample
		}
	}
	opl.current_frame = {
		left  = audio_clamp_i16(left),
		right = audio_clamp_i16(right),
	}
	opl3_schedule_next_sample(opl)
	return opl.current_frame, true
}

opl3_current_output :: proc(opl: ^Opl3) -> Audio_Frame {
	return opl.current_frame
}
