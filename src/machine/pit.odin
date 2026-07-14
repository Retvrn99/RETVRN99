// SPDX-License-Identifier: GPL-3.0-only
package machine

// Counter state and transition algorithms adapted from IzarraVM commit
// d930de57acccbc6a70cda8cc5a603173bf23cd1c.

PIT_HZ                    :: u64(1_193_182)
PIT_REFRESH_DIVISOR       :: u16(18)
PIT_TRANSITION_CAPACITY   :: 4096

Pit_Counter_State :: enum u8 {
	Inactive,
	Load_Delay,
	Counting,
	Wait_Gate,
}

Pit_Channel :: struct {
	reload: u16,
	count:  u32,

	count_latch:         u16,
	count_latched:       bool,
	status_latch:        u8,
	status_latched:      bool,
	rw_mode:             u8,
	write_msb_next:      bool,
	read_msb_next:       bool,

	mode:       u8,
	bcd:        bool,
	gate:       bool,
	out:        bool,
	null_count: bool,
	state:      Pit_Counter_State,
}

Pit_Out_Transition :: struct {
	master_tick: u64,
	level:       bool,
}

Pit :: struct {
	ch:          [3]Pit_Channel,
	initialized: bool,
	now_tick:    u64,
	clock_phase: Rate_Phase,
	ns_phase:    Master_Source_Phase,
	port61_low:  u8,

	channel2_transitions:      [PIT_TRANSITION_CAPACITY]Pit_Out_Transition,
	channel2_transition_count: int,
	channel2_transition_dropped: u64,
}

@(private = "file")
pit_saturating_add :: proc(a, b: u64) -> u64 {
	if b > ~u64(0) - a {
		return ~u64(0)
	}
	return a + b
}

@(private = "file")
pit_effective_reload :: proc(c: ^Pit_Channel) -> u32 {
	return c.reload == 0 ? 0x10000 : u32(c.reload)
}

@(private = "file")
pit_bcd_decrement :: proc(value, amount: u32) -> u32 {
	result := value & 0xFFFF
	for _ in 0..<amount {
		if result == 0 {
			result = 0x9999
			continue
		}
		digits := [4]u32{
			result & 0xF,
			(result >> 4) & 0xF,
			(result >> 8) & 0xF,
			(result >> 12) & 0xF,
		}
		place := 0
		for {
			if digits[place] > 0 {
				digits[place] -= 1
				break
			}
			digits[place] = 9
			place += 1
		}
		result = digits[0] | digits[1] << 4 | digits[2] << 8 | digits[3] << 12
	}
	return result
}

@(private = "file")
pit_bcd_value :: proc(value: u32) -> u64 {
	if value == 0x10000 {
		return 10_000
	}
	return u64(value & 0xF) +
	       u64((value >> 4) & 0xF) * 10 +
	       u64((value >> 8) & 0xF) * 100 +
	       u64((value >> 12) & 0xF) * 1_000
}

@(private = "file")
pit_count_value :: proc(c: ^Pit_Channel, value: u32) -> u64 {
	return c.bcd ? pit_bcd_value(value) : u64(value)
}

@(private = "file")
pit_decrement :: proc(c: ^Pit_Channel, value, amount: u32) -> u32 {
	if c.bcd { return pit_bcd_decrement(value, amount) }
	if value >= amount { return value - amount }
	return 0x10000 - (amount - value)
}

@(private = "file")
pit_mode3_half :: proc(value: u64, high: bool) -> u64 {
	if value & 1 == 0 || !high {
		return max(value / 2, u64(1))
	}
	return (value + 1) / 2
}

@(private = "file")
pit_counter_latch_count :: proc(c: ^Pit_Channel) {
	if !c.count_latched {
		c.count_latch = u16(c.count & 0xFFFF)
		c.count_latched = true
	}
}

@(private = "file")
pit_counter_latch_status :: proc(c: ^Pit_Channel) {
	if c.status_latched {
		return
	}
	c.status_latch = u8(c.out) << 7 |
	                 u8(c.null_count) << 6 |
	                 (c.rw_mode & 3) << 4 |
	                 (c.mode & 7) << 1 |
	                 u8(c.bcd)
	c.status_latched = true
}

@(private = "file")
pit_counter_control :: proc(c: ^Pit_Channel, value: u8) {
	rw := (value >> 4) & 3
	if rw == 0 {
		pit_counter_latch_count(c)
		return
	}
	c.rw_mode = rw
	c.mode = (value >> 1) & 7
	if c.mode == 6 { c.mode = 2 }
	if c.mode == 7 { c.mode = 3 }
	c.bcd = value & 1 != 0
	c.out = c.mode != 0
	c.state = .Inactive
	c.null_count = true
	c.write_msb_next = false
	c.read_msb_next = false
	c.count_latched = false
	c.status_latched = false
}

@(private = "file")
pit_counter_arm :: proc(c: ^Pit_Channel) {
	c.null_count = true
	switch c.mode {
	case 1, 5:
		if c.state != .Counting {
			c.state = .Wait_Gate
		}
	case 2, 3:
		if c.state != .Counting {
			c.state = .Load_Delay
		}
	case:
		c.state = .Load_Delay
	}
}

@(private = "file")
pit_counter_write :: proc(c: ^Pit_Channel, value: u8) {
	c.null_count = true
	switch c.rw_mode {
	case 1:
		c.reload = (c.reload & 0xFF00) | u16(value)
		if c.mode == 0 { c.out = false }
		pit_counter_arm(c)
	case 2:
		c.reload = (c.reload & 0x00FF) | u16(value) << 8
		if c.mode == 0 { c.out = false }
		pit_counter_arm(c)
	case 3:
		if !c.write_msb_next {
			c.reload = (c.reload & 0xFF00) | u16(value)
			c.write_msb_next = true
			if c.mode == 0 {
				c.out = false
				c.state = .Inactive
			}
		} else {
			c.reload = (c.reload & 0x00FF) | u16(value) << 8
			c.write_msb_next = false
			pit_counter_arm(c)
		}
	case:
		c.rw_mode = 1
		pit_counter_write(c, value)
	}
}

@(private = "file")
pit_counter_read :: proc(c: ^Pit_Channel) -> u8 {
	if c.status_latched {
		c.status_latched = false
		return c.status_latch
	}
	value := c.count_latched ? c.count_latch : u16(c.count & 0xFFFF)
	switch c.rw_mode {
	case 1:
		c.count_latched = false
		return u8(value)
	case 2:
		c.count_latched = false
		return u8(value >> 8)
	case 3:
		if !c.read_msb_next {
			c.read_msb_next = true
			return u8(value)
		}
		c.read_msb_next = false
		c.count_latched = false
		return u8(value >> 8)
	}
	return u8(value)
}

@(private = "file")
pit_counter_set_gate :: proc(c: ^Pit_Channel, level: bool) {
	rising := !c.gate && level
	falling := c.gate && !level
	c.gate = level
	if rising {
		switch c.mode {
		case 1:
			c.count = pit_effective_reload(c)
			c.out = false
			c.null_count = false
			c.state = .Counting
		case 5:
			c.count = pit_effective_reload(c)
			c.out = true
			c.null_count = false
			c.state = .Counting
		case 2, 3:
			c.state = .Load_Delay
		}
	} else if falling && (c.mode == 2 || c.mode == 3) {
		c.out = true
	}
}

@(private = "file")
pit_counter_step :: proc(c: ^Pit_Channel) -> bool {
	switch c.state {
	case .Inactive, .Wait_Gate:
		return false
	case .Load_Delay:
		c.count = pit_effective_reload(c)
		c.null_count = false
		c.state = .Counting
		return false
	case .Counting:
	}
	if !c.gate && c.mode != 1 && c.mode != 5 {
		if c.mode == 2 || c.mode == 3 {
			c.out = true
		}
		return false
	}
	switch c.mode {
	case 0, 1:
		c.count = pit_decrement(c, c.count, 1)
		if c.count == 0 && !c.out {
			c.out = true
			if c.mode == 1 { c.state = .Inactive }
			return true
		}
	case 2:
		if pit_count_value(c, c.count) <= 1 {
			c.count = pit_effective_reload(c)
			c.null_count = false
			rose := !c.out
			c.out = true
			return rose
		}
		c.count = pit_decrement(c, c.count, 1)
		if pit_count_value(c, c.count) == 1 { c.out = false }
	case 3:
		first_half_clock := pit_count_value(c, c.count) & 1 != 0
		amount := u32(2)
		if first_half_clock {
			amount = c.out ? 1 : 3
		}
		if pit_count_value(c, c.count) <= u64(amount) {
			c.count = pit_effective_reload(c)
			c.null_count = false
			c.out = !c.out
			return c.out
		}
		c.count = pit_decrement(c, c.count, amount)
	case 4, 5:
		if c.out {
			c.count = pit_decrement(c, c.count, 1)
			if c.count == 0 { c.out = false }
		} else {
			c.out = true
			c.state = .Inactive
			return true
		}
	}
	return false
}

@(private = "file")
pit_counter_rise_from :: proc(c: ^Pit_Channel, count: u32) -> (u64, bool) {
	value := pit_count_value(c, count)
	reload := pit_count_value(c, pit_effective_reload(c))
	switch c.mode {
	case 0, 1:
		if c.out || value == 0 { return 0, false }
		return value, true
	case 2:
		if !c.out { return 1, true }
		if value >= 2 { return value, true }
		if reload >= 2 { return 1 + reload, true }
	case 3:
		if c.out {
			return pit_mode3_half(value, true) + pit_mode3_half(reload, false), true
		}
		return pit_mode3_half(value, false), true
	case 4, 5:
		if !c.out { return 1, true }
		if value != 0 { return value + 1, true }
	}
	return 0, false
}

@(private = "file")
pit_counter_clocks_until_rise :: proc(c: ^Pit_Channel) -> (u64, bool) {
	switch c.state {
	case .Inactive, .Wait_Gate:
		return 0, false
	case .Load_Delay:
		if !c.gate { return 0, false }
		clocks, pending := pit_counter_rise_from(c, pit_effective_reload(c))
		return pending ? clocks + 1 : 0, pending
	case .Counting:
		if !c.gate && c.mode != 1 && c.mode != 5 { return 0, false }
		return pit_counter_rise_from(c, c.count)
	}
	return 0, false
}

@(private = "file")
pit_counter_edge_from :: proc(c: ^Pit_Channel, count: u32) -> (u64, bool) {
	value := pit_count_value(c, count)
	reload := pit_count_value(c, pit_effective_reload(c))
	switch c.mode {
	case 0, 1:
		if !c.out && value != 0 { return value, true }
	case 2:
		if !c.out { return 1, true }
		if value >= 2 { return value - 1, true }
		if reload >= 2 { return reload, true }
	case 3:
		return pit_mode3_half(value, c.out), true
	case 4, 5:
		if !c.out { return 1, true }
		if value != 0 { return value, true }
	}
	return 0, false
}

@(private = "file")
pit_counter_clocks_until_edge :: proc(c: ^Pit_Channel) -> (u64, bool) {
	switch c.state {
	case .Inactive, .Wait_Gate:
		return 0, false
	case .Load_Delay:
		if !c.gate { return 0, false }
		clocks, pending := pit_counter_edge_from(c, pit_effective_reload(c))
		return pending ? clocks + 1 : 0, pending
	case .Counting:
		if !c.gate && c.mode != 1 && c.mode != 5 { return 0, false }
		return pit_counter_edge_from(c, c.count)
	}
	return 0, false
}

@(private = "file")
pit_record_channel2 :: proc(p: ^Pit, master_tick: u64, level: bool) {
	if p.channel2_transition_count < PIT_TRANSITION_CAPACITY {
		p.channel2_transitions[p.channel2_transition_count] = Pit_Out_Transition{
			master_tick = master_tick,
			level = level,
		}
		p.channel2_transition_count += 1
	} else {
		p.channel2_transition_dropped += 1
	}
}

@(private = "file")
pit_initialize :: proc(p: ^Pit) {
	if p.initialized { return }
	p.initialized = true
	for i in 0..<3 {
		p.ch[i].rw_mode = 1
	}
	p.ch[0].gate = true
	p.ch[1].gate = true
	p.ch[2].gate = false
	pit_counter_control(&p.ch[0], 0x36)
	pit_counter_write(&p.ch[0], 0)
	pit_counter_write(&p.ch[0], 0)
	pit_counter_control(&p.ch[1], 0x74)
	pit_counter_write(&p.ch[1], u8(PIT_REFRESH_DIVISOR))
	pit_counter_write(&p.ch[1], u8(PIT_REFRESH_DIVISOR >> 8))
}

pit_init :: proc(p: ^Pit) {
	p^ = {}
	pit_initialize(p)
}

pit_now :: proc(p: ^Pit) -> u64 {
	pit_initialize(p)
	return p.now_tick
}

pit_out :: proc(p: ^Pit, port: u16, value: u8) {
	pit_initialize(p)
	if port == 0x43 {
		selected := (value >> 6) & 3
		if selected == 3 {
			latch_count := value & 0x20 == 0
			latch_status := value & 0x10 == 0
			if !latch_count && !latch_status { return }
			for i in 0..<3 {
				if value & (u8(1) << u8(i + 1)) == 0 { continue }
				if latch_count { pit_counter_latch_count(&p.ch[i]) }
				if latch_status { pit_counter_latch_status(&p.ch[i]) }
			}
			return
		}
		old_channel2 := p.ch[2].out
		pit_counter_control(&p.ch[selected], value)
		if selected == 2 && p.ch[2].out != old_channel2 {
			pit_record_channel2(p, p.now_tick, p.ch[2].out)
		}
		return
	}
	if port >= 0x40 && port <= 0x42 {
		channel := int(port - 0x40)
		old_channel2 := p.ch[2].out
		pit_counter_write(&p.ch[channel], value)
		if channel == 2 && p.ch[2].out != old_channel2 {
			pit_record_channel2(p, p.now_tick, p.ch[2].out)
		}
	}
}

pit_in :: proc(p: ^Pit, port: u16) -> u8 {
	pit_initialize(p)
	if port < 0x40 || port > 0x42 { return 0xFF }
	return pit_counter_read(&p.ch[port - 0x40])
}

pit_channel_out :: proc(p: ^Pit, channel: int) -> bool {
	pit_initialize(p)
	if channel < 0 || channel >= 3 { return false }
	return p.ch[channel].out
}

pit_set_gate :: proc(p: ^Pit, channel: int, level: bool) {
	pit_initialize(p)
	if channel < 0 || channel >= 3 { return }
	old_channel2 := p.ch[2].out
	pit_counter_set_gate(&p.ch[channel], level)
	if channel == 2 && p.ch[2].out != old_channel2 {
		pit_record_channel2(p, p.now_tick, p.ch[2].out)
	}
}

pit_tick :: proc(p: ^Pit, clocks: u64) -> int {
	pit_initialize(p)
	if clocks == 0 { return 0 }
	fires := 0
	for _ in 0..<clocks {
		if pit_counter_step(&p.ch[0]) { fires += 1 }
		_ = pit_counter_step(&p.ch[1])
		old_channel2 := p.ch[2].out
		_ = pit_counter_step(&p.ch[2])
		if p.ch[2].out != old_channel2 {
			pit_record_channel2(p, p.now_tick, p.ch[2].out)
		}
	}
	return fires
}

@(private = "file")
pit_counter_advance_mode2 :: proc(c: ^Pit_Channel, clocks: u64) -> u64 {
	reload := u64(pit_effective_reload(c))
	value := u64(c.count)
	if reload < 2 || value == 0 || value > reload {return 0}
	phase := c.out ? reload - value : reload - 1
	total := u128(phase) + u128(clocks)
	rises := u64(total / u128(reload))
	next := u64(total % u128(reload))
	if next == reload - 1 {
		c.count = 1
		c.out = false
	} else {
		c.count = u32(reload - next)
		c.out = true
	}
	c.null_count = false
	return rises
}

@(private = "file")
pit_counter_mode3_phase :: proc(c: ^Pit_Channel, reload: u64) -> u64 {
	value := u64(c.count)
	high_clocks := (reload + 1) / 2
	if value == reload {return c.out ? 0 : high_clocks}
	if c.out {
		return reload & 1 == 0 ? (reload - value) / 2 : (reload - value + 1) / 2
	}
	low_phase := reload & 1 == 0 ? (reload - value) / 2 : (reload - value - 1) / 2
	return high_clocks + low_phase
}

@(private = "file")
pit_counter_advance_mode3 :: proc(c: ^Pit_Channel, clocks: u64) -> u64 {
	reload := u64(pit_effective_reload(c))
	value := u64(c.count)
	if reload < 2 || value == 0 || value > reload {return 0}
	phase := pit_counter_mode3_phase(c, reload)
	total := u128(phase) + u128(clocks)
	rises := u64(total / u128(reload))
	next := u64(total % u128(reload))
	high_clocks := (reload + 1) / 2
	if next < high_clocks {
		c.out = true
		if next == 0 {
			c.count = u32(reload)
		} else if reload & 1 == 0 {
			c.count = u32(reload - next * 2)
		} else {
			c.count = u32(reload - next * 2 + 1)
		}
	} else {
		c.out = false
		low_phase := next - high_clocks
		if low_phase == 0 {
			c.count = u32(reload)
		} else if reload & 1 == 0 {
			c.count = u32(reload - low_phase * 2)
		} else {
			c.count = u32(reload - low_phase * 2 - 1)
		}
	}
	c.null_count = false
	return rises
}

@(private = "file")
pit_counter_advance_bulk :: proc(c: ^Pit_Channel, clocks: u64) -> u64 {
	remaining := clocks
	rises: u64
	if remaining == 0 {return 0}
	if c.state == .Load_Delay {
		if pit_counter_step(c) {rises += 1}
		remaining -= 1
	}
	if remaining == 0 || c.state != .Counting {return rises}
	if !c.gate && c.mode != 1 && c.mode != 5 {
		if c.mode == 2 || c.mode == 3 {c.out = true}
		return rises
	}
	if !c.bcd {
		switch c.mode {
		case 2:
			return rises + pit_counter_advance_mode2(c, remaining)
		case 3:
			return rises + pit_counter_advance_mode3(c, remaining)
		}
	}
	for _ in 0 ..< remaining {
		if pit_counter_step(c) {rises += 1}
	}
	return rises
}

@(private = "file")
pit_channel2_advance_bulk :: proc(
	p: ^Pit,
	clocks: u64,
	start_tick: u64,
	start_phase: Rate_Phase,
) {
	remaining := clocks
	elapsed_clocks: u64
	for remaining > 0 {
		edge, pending := pit_counter_clocks_until_edge(&p.ch[2])
		if !pending || edge > remaining {
			_ = pit_counter_advance_bulk(&p.ch[2], remaining)
			return
		}
		old := p.ch[2].out
		_ = pit_counter_advance_bulk(&p.ch[2], edge)
		remaining -= edge
		elapsed_clocks += edge
		if p.ch[2].out != old {
			delta, _ := rate_phase_ticks_until(start_phase, elapsed_clocks, PIT_HZ)
			pit_record_channel2(p, pit_saturating_add(start_tick, delta), p.ch[2].out)
		}
	}
}

pit_advance_to :: proc(p: ^Pit, target_tick: u64) -> int {
	pit_initialize(p)
	if target_tick <= p.now_tick { return 0 }
	start_tick := p.now_tick
	start_phase := p.clock_phase
	elapsed := target_tick - start_tick
	clocks := rate_phase_advance(&p.clock_phase, elapsed, PIT_HZ)
	if clocks == 0 {
		p.now_tick = target_tick
		return 0
	}
	fires_u64 := pit_counter_advance_bulk(&p.ch[0], clocks)
	_ = pit_counter_advance_bulk(&p.ch[1], clocks)
	pit_channel2_advance_bulk(p, clocks, start_tick, start_phase)
	p.now_tick = target_tick
	return int(min(fires_u64, u64(max(int))))
}

pit_advance_master :: proc(p: ^Pit, master_ticks: u64) -> int {
	pit_initialize(p)
	return pit_advance_to(p, pit_saturating_add(p.now_tick, master_ticks))
}

// Compatibility entry point for callers that still advance devices in nanoseconds.
pit_advance :: proc(p: ^Pit, nanoseconds: u64) -> int {
	pit_initialize(p)
	master_ticks := master_source_advance_nanoseconds(&p.ns_phase, nanoseconds)
	return pit_advance_master(p, master_ticks)
}

pit_next_out_edge :: proc(p: ^Pit, channel: int) -> (deadline: u64, pending: bool) {
	pit_initialize(p)
	if channel < 0 || channel >= 3 { return 0, false }
	clocks, has_edge := pit_counter_clocks_until_edge(&p.ch[channel])
	if !has_edge { return 0, false }
	delta, running := rate_phase_ticks_until(p.clock_phase, clocks, PIT_HZ)
	if !running { return 0, false }
	return pit_saturating_add(p.now_tick, delta), true
}

pit_next_deadline :: proc(p: ^Pit) -> (deadline: u64, pending: bool) {
	pit_initialize(p)
	clocks, has_edge := pit_counter_clocks_until_rise(&p.ch[0])
	if !has_edge { return 0, false }
	delta, running := rate_phase_ticks_until(p.clock_phase, clocks, PIT_HZ)
	if !running { return 0, false }
	return pit_saturating_add(p.now_tick, delta), true
}

pit_channel2_transition_slice :: proc(p: ^Pit) -> []Pit_Out_Transition {
	pit_initialize(p)
	return p.channel2_transitions[:p.channel2_transition_count]
}

pit_clear_channel2_transitions :: proc(p: ^Pit) {
	pit_initialize(p)
	p.channel2_transition_count = 0
	p.channel2_transition_dropped = 0
}

pit_channel2_transitions_dropped :: proc(p: ^Pit) -> u64 {
	pit_initialize(p)
	return p.channel2_transition_dropped
}

pit_port61_read :: proc(p: ^Pit) -> u8 {
	pit_initialize(p)
	value := p.port61_low & 0x03
	if p.ch[1].out { value |= 0x10 }
	if p.ch[2].out { value |= 0x20 }
	return value
}

pit_port61_write :: proc(p: ^Pit, value: u8) {
	pit_initialize(p)
	p.port61_low = value & 0x03
	pit_set_gate(p, 2, value & 1 != 0)
}
