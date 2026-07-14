// SPDX-License-Identifier: GPL-3.0-only
package machine

// Register and timing behavior adapted from IzarraVM commit d930de57acccbc6a70cda8cc5a603173bf23cd1c.

LPT1_BASE :: u16(0x0378)
LPT2_BASE :: u16(0x0278)
LPT_CAPTURE_CAPACITY :: 4096

LPT_STATUS_NOT_BUSY  :: u8(0x80)
LPT_STATUS_NOT_ACK   :: u8(0x40)
LPT_STATUS_SELECT    :: u8(0x10)
LPT_STATUS_NOT_ERROR :: u8(0x08)
LPT_STATUS_RESERVED  :: u8(0x07)
LPT_STATUS_IDLE :: LPT_STATUS_NOT_BUSY | LPT_STATUS_NOT_ACK | LPT_STATUS_SELECT | LPT_STATUS_NOT_ERROR | LPT_STATUS_RESERVED

LPT_CONTROL_STROBE     :: u8(0x01)
LPT_CONTROL_IRQ_ENABLE :: u8(0x10)
LPT_CONTROL_RESERVED   :: u8(0xC0)

LPT_BUSY_TICKS :: MASTER_CLOCK_HZ / 100_000
LPT_ACK_TICKS  :: MASTER_CLOCK_HZ / 200_000

Lpt_Phase :: enum u8 {
	Idle,
	Busy,
	Ack,
}

Lpt :: struct {
	base:     u16,
	now_tick: u64,
	data:     u8,
	control:  u8,
	strobe_asserted: bool,
	phase:          Lpt_Phase,
	phase_deadline: u64,
	latched_byte:   u8,
	irq_edge:       bool,

	capture:         [LPT_CAPTURE_CAPACITY]u8,
	capture_count:   int,
	capture_dropped: u64,
}

lpt_init :: proc(lpt: ^Lpt, base := LPT1_BASE) {
	lpt^ = {}
	lpt.base = base
}

lpt_init_lpt1 :: proc(lpt: ^Lpt) {
	lpt_init(lpt, LPT1_BASE)
}

lpt_init_lpt2 :: proc(lpt: ^Lpt) {
	lpt_init(lpt, LPT2_BASE)
}

lpt_irq_number :: proc(lpt: ^Lpt) -> u8 {
	return lpt.base == LPT2_BASE ? 5 : 7
}

lpt_output :: proc(lpt: ^Lpt) -> []u8 {
	return lpt.capture[:lpt.capture_count]
}

lpt_output_dropped :: proc(lpt: ^Lpt) -> u64 {
	return lpt.capture_dropped
}

lpt_clear_output :: proc(lpt: ^Lpt) {
	lpt.capture_count = 0
	lpt.capture_dropped = 0
}

lpt_take_irq :: proc(lpt: ^Lpt) -> bool {
	edge := lpt.irq_edge
	lpt.irq_edge = false
	return edge
}

@(private = "file")
lpt_offset :: proc(lpt: ^Lpt, port: u16) -> (u8, bool) {
	if port < lpt.base || port > lpt.base + 2 {
		return 0, false
	}
	return u8(port - lpt.base), true
}

@(private = "file")
lpt_status :: proc(lpt: ^Lpt) -> u8 {
	switch lpt.phase {
	case .Idle:
		return LPT_STATUS_IDLE
	case .Busy:
		return LPT_STATUS_IDLE & ~LPT_STATUS_NOT_BUSY
	case .Ack:
		return LPT_STATUS_IDLE & ~LPT_STATUS_NOT_ACK
	}
	return LPT_STATUS_IDLE
}

lpt_in :: proc(lpt: ^Lpt, port: u16) -> (value: u8, claimed: bool) {
	offset, ok := lpt_offset(lpt, port)
	if !ok {
		return 0xFF, false
	}
	switch offset {
	case 0:
		return lpt.data, true
	case 1:
		return lpt_status(lpt), true
	case 2:
		return lpt.control | LPT_CONTROL_RESERVED, true
	}
	return 0xFF, true
}

@(private = "file")
lpt_deadline_after :: proc(now, elapsed: u64) -> u64 {
	if elapsed > ~u64(0) - now {
		return ~u64(0)
	}
	return now + elapsed
}

lpt_out :: proc(lpt: ^Lpt, port: u16, value: u8) -> bool {
	offset, ok := lpt_offset(lpt, port)
	if !ok {
		return false
	}
	switch offset {
	case 0:
		lpt.data = value
	case 1:
	case 2:
		lpt.control = value & 0x3F
		strobe_now := value & LPT_CONTROL_STROBE != 0
		if strobe_now && !lpt.strobe_asserted && lpt.phase == .Idle {
			lpt.latched_byte = lpt.data
			lpt.phase = .Busy
			lpt.phase_deadline = lpt_deadline_after(lpt.now_tick, LPT_BUSY_TICKS)
		}
		lpt.strobe_asserted = strobe_now
	}
	return true
}

@(private = "file")
lpt_capture_byte :: proc(lpt: ^Lpt, value: u8) {
	if lpt.capture_count < LPT_CAPTURE_CAPACITY {
		lpt.capture[lpt.capture_count] = value
		lpt.capture_count += 1
	} else {
		lpt.capture_dropped += 1
	}
}

lpt_now :: proc(lpt: ^Lpt) -> u64 {
	return lpt.now_tick
}

lpt_next_deadline :: proc(lpt: ^Lpt) -> (deadline: u64, pending: bool) {
	if lpt.phase == .Idle {
		return 0, false
	}
	return lpt.phase_deadline, true
}

lpt_advance_to :: proc(lpt: ^Lpt, target_tick: u64) {
	if target_tick <= lpt.now_tick {
		return
	}
	for lpt.phase != .Idle && lpt.phase_deadline <= target_tick {
		lpt.now_tick = lpt.phase_deadline
		switch lpt.phase {
		case .Busy:
			lpt_capture_byte(lpt, lpt.latched_byte)
			if lpt.control & LPT_CONTROL_IRQ_ENABLE != 0 {
				lpt.irq_edge = true
			}
			lpt.phase = .Ack
			lpt.phase_deadline = lpt_deadline_after(lpt.now_tick, LPT_ACK_TICKS)
		case .Ack:
			lpt.phase = .Idle
			lpt.phase_deadline = 0
		case .Idle:
		}
	}
	lpt.now_tick = target_tick
}

lpt_advance :: proc(lpt: ^Lpt, master_ticks: u64) {
	target := lpt_deadline_after(lpt.now_tick, master_ticks)
	lpt_advance_to(lpt, target)
}

lpt_ticks_until_idle :: proc(lpt: ^Lpt) -> u64 {
	switch lpt.phase {
	case .Idle:
		return 0
	case .Busy:
		remaining := lpt.phase_deadline - lpt.now_tick
		if LPT_ACK_TICKS > ~u64(0) - remaining {
			return ~u64(0)
		}
		return remaining + LPT_ACK_TICKS
	case .Ack:
		return lpt.phase_deadline - lpt.now_tick
	}
	return 0
}

lpt_irq_deadline :: proc(lpt: ^Lpt) -> (deadline: u64, pending: bool) {
	if lpt.phase != .Busy || lpt.control & LPT_CONTROL_IRQ_ENABLE == 0 {
		return 0, false
	}
	return lpt.phase_deadline, true
}
