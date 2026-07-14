// SPDX-License-Identifier: GPL-3.0-only
package machine

// Register and timing behavior adapted from IzarraVM commit d930de57acccbc6a70cda8cc5a603173bf23cd1c.

UART_COM1_BASE :: u16(0x03F8)
UART_COM2_BASE :: u16(0x02F8)
UART_CAPTURE_CAPACITY :: 4096

UART_LSR_DR   :: u8(0x01)
UART_LSR_OE   :: u8(0x02)
UART_LSR_THRE :: u8(0x20)
UART_LSR_TEMT :: u8(0x40)

UART_MSR_DCTS :: u8(0x01)
UART_MSR_DDSR :: u8(0x02)
UART_MSR_TERI :: u8(0x04)
UART_MSR_DDCD :: u8(0x08)
UART_MSR_CTS  :: u8(0x10)
UART_MSR_DSR  :: u8(0x20)
UART_MSR_RI   :: u8(0x40)
UART_MSR_DCD  :: u8(0x80)

UART_MCR_DTR  :: u8(0x01)
UART_MCR_RTS  :: u8(0x02)
UART_MCR_OUT1 :: u8(0x04)
UART_MCR_OUT2 :: u8(0x08)
UART_MCR_LOOP :: u8(0x10)

UART_IER_RDA  :: u8(0x01)
UART_IER_THRE :: u8(0x02)
UART_IER_RLS  :: u8(0x04)
UART_IER_MS   :: u8(0x08)

UART_IIR_NONE :: u8(0x01)
UART_IIR_RLS  :: u8(0x06)
UART_IIR_RDA  :: u8(0x04)
UART_IIR_THRE :: u8(0x02)
UART_IIR_MS   :: u8(0x00)

Uart_16450 :: struct {
	base: u16,
	now_tick: u64,

	ier:     u8,
	lcr:     u8,
	mcr:     u8,
	lsr:     u8,
	msr:     u8,
	scratch: u8,
	divisor: u16,

	thr:       u8,
	thr_valid: bool,
	shift:       u8,
	shift_valid: bool,
	tx_deadline: u64,

	rbr:       u8,
	rbr_valid: bool,
	thre_pending: bool,
	irq_asserted: bool,
	irq_edge:     bool,

	capture:         [UART_CAPTURE_CAPACITY]u8,
	capture_count:   int,
	capture_dropped: u64,
}

uart_init :: proc(u: ^Uart_16450, base := UART_COM1_BASE) {
	u^ = {}
	u.base = base
	u.lsr = UART_LSR_THRE | UART_LSR_TEMT
}

uart_init_com1 :: proc(u: ^Uart_16450) {
	uart_init(u, UART_COM1_BASE)
}

uart_init_com2 :: proc(u: ^Uart_16450) {
	uart_init(u, UART_COM2_BASE)
}

uart_irq_number :: proc(u: ^Uart_16450) -> u8 {
	return u.base == UART_COM2_BASE ? 3 : 4
}

uart_output :: proc(u: ^Uart_16450) -> []u8 {
	return u.capture[:u.capture_count]
}

uart_output_dropped :: proc(u: ^Uart_16450) -> u64 {
	return u.capture_dropped
}

uart_clear_output :: proc(u: ^Uart_16450) {
	u.capture_count = 0
	u.capture_dropped = 0
}

@(private = "file")
uart_dlab :: proc(u: ^Uart_16450) -> bool {
	return u.lcr & 0x80 != 0
}

@(private = "file")
uart_offset :: proc(u: ^Uart_16450, port: u16) -> (u8, bool) {
	if port < u.base || port > u.base + 7 {
		return 0, false
	}
	return u8(port - u.base), true
}

@(private = "file")
uart_pending_code :: proc(u: ^Uart_16450) -> u8 {
	if u.ier & UART_IER_RLS != 0 && u.lsr & UART_LSR_OE != 0 {
		return UART_IIR_RLS
	}
	if u.ier & UART_IER_RDA != 0 && u.rbr_valid {
		return UART_IIR_RDA
	}
	if u.ier & UART_IER_THRE != 0 && u.thre_pending {
		return UART_IIR_THRE
	}
	if u.ier & UART_IER_MS != 0 && u.msr & 0x0F != 0 {
		return UART_IIR_MS
	}
	return UART_IIR_NONE
}

@(private = "file")
uart_refresh_irq :: proc(u: ^Uart_16450) {
	asserted := u.mcr & UART_MCR_OUT2 != 0 && uart_pending_code(u) != UART_IIR_NONE
	if asserted && !u.irq_asserted {
		u.irq_edge = true
	}
	u.irq_asserted = asserted
}

uart_irq_line :: proc(u: ^Uart_16450) -> bool {
	return u.irq_asserted
}

uart_take_irq :: proc(u: ^Uart_16450) -> bool {
	edge := u.irq_edge
	u.irq_edge = false
	return edge
}

@(private = "file")
uart_update_tx_status :: proc(u: ^Uart_16450) {
	if u.thr_valid {
		u.lsr &= ~UART_LSR_THRE
	} else {
		u.lsr |= UART_LSR_THRE
	}
	if !u.thr_valid && !u.shift_valid {
		u.lsr |= UART_LSR_TEMT
	} else {
		u.lsr &= ~UART_LSR_TEMT
	}
}

uart_character_ticks :: proc(u: ^Uart_16450) -> u64 {
	data_bits := u64(5 + (u.lcr & 0x03))
	parity_bits := u64(u.lcr & 0x08 != 0 ? 1 : 0)
	stop_half_bits: u64
	if u.lcr & 0x04 == 0 {
		stop_half_bits = 2
	} else if data_bits == 5 {
		stop_half_bits = 3
	} else {
		stop_half_bits = 4
	}
	half_bits := u64(2) + data_bits * 2 + parity_bits * 2 + stop_half_bits
	divisor := max(u64(u.divisor), u64(1))
	numerator := u128(MASTER_CLOCK_HZ) * u128(divisor) * u128(half_bits)
	return u64((numerator + 230_399) / 230_400)
}

@(private = "file")
uart_deadline_after :: proc(now, elapsed: u64) -> u64 {
	if elapsed > ~u64(0) - now {
		return ~u64(0)
	}
	return now + elapsed
}

@(private = "file")
uart_start_transmit :: proc(u: ^Uart_16450) {
	if u.shift_valid || !u.thr_valid {
		uart_update_tx_status(u)
		return
	}
	u.shift = u.thr
	u.shift_valid = true
	u.thr_valid = false
	u.tx_deadline = uart_deadline_after(u.now_tick, uart_character_ticks(u))
	u.thre_pending = true
	uart_update_tx_status(u)
}

@(private = "file")
uart_capture_byte :: proc(u: ^Uart_16450, value: u8) {
	if u.capture_count < UART_CAPTURE_CAPACITY {
		u.capture[u.capture_count] = value
		u.capture_count += 1
	} else {
		u.capture_dropped += 1
	}
}

uart_receive :: proc(u: ^Uart_16450, value: u8) {
	if u.rbr_valid {
		u.lsr |= UART_LSR_OE
	} else {
		u.rbr = value
		u.rbr_valid = true
		u.lsr |= UART_LSR_DR
	}
	uart_refresh_irq(u)
}

@(private = "file")
uart_complete_transmit :: proc(u: ^Uart_16450) {
	value := u.shift
	u.shift_valid = false
	if u.mcr & UART_MCR_LOOP != 0 {
		uart_receive(u, value)
	} else {
		uart_capture_byte(u, value)
	}
	uart_start_transmit(u)
	uart_update_tx_status(u)
	uart_refresh_irq(u)
}

uart_now :: proc(u: ^Uart_16450) -> u64 {
	return u.now_tick
}

uart_next_deadline :: proc(u: ^Uart_16450) -> (deadline: u64, pending: bool) {
	if !u.shift_valid {
		return 0, false
	}
	return u.tx_deadline, true
}

uart_advance_to :: proc(u: ^Uart_16450, target_tick: u64) {
	if target_tick <= u.now_tick {
		return
	}
	for u.shift_valid && u.tx_deadline <= target_tick {
		u.now_tick = u.tx_deadline
		uart_complete_transmit(u)
	}
	u.now_tick = target_tick
}

uart_advance :: proc(u: ^Uart_16450, master_ticks: u64) {
	target := uart_deadline_after(u.now_tick, master_ticks)
	uart_advance_to(u, target)
}

uart_ticks_until_idle :: proc(u: ^Uart_16450) -> u64 {
	if !u.shift_valid {
		return 0
	}
	remaining := u.tx_deadline - u.now_tick
	if u.thr_valid {
		character := uart_character_ticks(u)
		if character > ~u64(0) - remaining {
			return ~u64(0)
		}
		remaining += character
	}
	return remaining
}

@(private = "file")
uart_loopback_msr :: proc(u: ^Uart_16450, old_mcr: u8) {
	inputs: u8
	if u.mcr & UART_MCR_RTS != 0  { inputs |= UART_MSR_CTS }
	if u.mcr & UART_MCR_DTR != 0  { inputs |= UART_MSR_DSR }
	if u.mcr & UART_MCR_OUT1 != 0 { inputs |= UART_MSR_RI }
	if u.mcr & UART_MCR_OUT2 != 0 { inputs |= UART_MSR_DCD }

	deltas := u.msr & 0x0F
	changed := old_mcr ~ u.mcr
	if changed & UART_MCR_RTS != 0  { deltas |= UART_MSR_DCTS }
	if changed & UART_MCR_DTR != 0  { deltas |= UART_MSR_DDSR }
	if changed & UART_MCR_OUT1 != 0 { deltas |= UART_MSR_TERI }
	if changed & UART_MCR_OUT2 != 0 { deltas |= UART_MSR_DDCD }
	u.msr = inputs | deltas
}

@(private = "file")
uart_leave_loopback :: proc(u: ^Uart_16450) {
	deltas := u.msr & 0x0F
	if u.msr & UART_MSR_CTS != 0 { deltas |= UART_MSR_DCTS }
	if u.msr & UART_MSR_DSR != 0 { deltas |= UART_MSR_DDSR }
	if u.msr & UART_MSR_RI  != 0 { deltas |= UART_MSR_TERI }
	if u.msr & UART_MSR_DCD != 0 { deltas |= UART_MSR_DDCD }
	u.msr = deltas
}

@(private = "file")
uart_read_rbr :: proc(u: ^Uart_16450) -> u8 {
	value := u.rbr_valid ? u.rbr : 0
	u.rbr_valid = false
	u.lsr &= ~UART_LSR_DR
	return value
}

@(private = "file")
uart_read_iir :: proc(u: ^Uart_16450) -> u8 {
	code := uart_pending_code(u)
	if code == UART_IIR_THRE {
		u.thre_pending = false
	}
	return code
}

uart_in :: proc(u: ^Uart_16450, port: u16) -> (value: u8, claimed: bool) {
	offset, ok := uart_offset(u, port)
	if !ok {
		return 0xFF, false
	}
	switch offset {
	case 0:
		value = uart_dlab(u) ? u8(u.divisor) : uart_read_rbr(u)
	case 1:
		value = uart_dlab(u) ? u8(u.divisor >> 8) : u.ier
	case 2:
		value = uart_read_iir(u)
	case 3:
		value = u.lcr
	case 4:
		value = u.mcr
	case 5:
		value = u.lsr
		u.lsr &= ~UART_LSR_OE
	case 6:
		value = u.msr
		u.msr &= 0xF0
	case 7:
		value = u.scratch
	}
	uart_refresh_irq(u)
	return value, true
}

@(private = "file")
uart_write_thr :: proc(u: ^Uart_16450, value: u8) {
	if u.thr_valid {
		return
	}
	u.thr = value
	u.thr_valid = true
	u.thre_pending = false
	uart_update_tx_status(u)
	uart_start_transmit(u)
}

uart_out :: proc(u: ^Uart_16450, port: u16, value: u8) -> bool {
	offset, ok := uart_offset(u, port)
	if !ok {
		return false
	}
	switch offset {
	case 0:
		if uart_dlab(u) {
			u.divisor = (u.divisor & 0xFF00) | u16(value)
		} else {
			uart_write_thr(u, value)
		}
	case 1:
		if uart_dlab(u) {
			u.divisor = (u.divisor & 0x00FF) | u16(value) << 8
		} else {
			old := u.ier
			u.ier = value & 0x0F
			if old & UART_IER_THRE == 0 && u.ier & UART_IER_THRE != 0 && u.lsr & UART_LSR_THRE != 0 {
				u.thre_pending = true
			}
		}
	case 2:
		// A 16450 has no FIFO control register.
	case 3:
		u.lcr = value
	case 4:
		old := u.mcr
		u.mcr = value & 0x1F
		if u.mcr & UART_MCR_LOOP != 0 {
			uart_loopback_msr(u, old)
		} else if old & UART_MCR_LOOP != 0 {
			uart_leave_loopback(u)
		}
	case 5, 6:
	case 7:
		u.scratch = value
	}
	uart_refresh_irq(u)
	return true
}
