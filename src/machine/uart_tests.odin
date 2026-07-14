// SPDX-License-Identifier: GPL-3.0-only
package machine

import "core:testing"

@(test)
test_uart_reset_and_port_decode :: proc(t: ^testing.T) {
	uart: Uart_16450
	uart_init_com1(&uart)
	value, claimed := uart_in(&uart, UART_COM1_BASE + 5)
	testing.expect(t, claimed)
	testing.expect_value(t, value, UART_LSR_THRE | UART_LSR_TEMT)
	_, claimed = uart_in(&uart, UART_COM2_BASE)
	testing.expect(t, !claimed)
	testing.expect(t, !uart_out(&uart, UART_COM2_BASE, 0x55))
	testing.expect_value(t, uart_irq_number(&uart), u8(4))

	uart_init_com2(&uart)
	testing.expect_value(t, uart_irq_number(&uart), u8(3))
	testing.expect(t, uart_out(&uart, UART_COM2_BASE + 7, 0xA5))
	value, claimed = uart_in(&uart, UART_COM2_BASE + 7)
	testing.expect(t, claimed)
	testing.expect_value(t, value, u8(0xA5))
}

@(test)
test_uart_dlab_preserves_ier :: proc(t: ^testing.T) {
	uart: Uart_16450
	uart_init(&uart)
	_ = uart_out(&uart, UART_COM1_BASE + 1, 0x0F)
	_ = uart_out(&uart, UART_COM1_BASE + 3, 0x80)
	_ = uart_out(&uart, UART_COM1_BASE, 0x01)
	_ = uart_out(&uart, UART_COM1_BASE + 1, 0xC2)
	lo, _ := uart_in(&uart, UART_COM1_BASE)
	hi, _ := uart_in(&uart, UART_COM1_BASE + 1)
	testing.expect_value(t, lo, u8(0x01))
	testing.expect_value(t, hi, u8(0xC2))
	testing.expect_value(t, uart.divisor, u16(0xC201))
	_ = uart_out(&uart, UART_COM1_BASE + 3, 0)
	ier, _ := uart_in(&uart, UART_COM1_BASE + 1)
	testing.expect_value(t, ier, u8(0x0F))
}

@(test)
test_uart_reports_true_16450 :: proc(t: ^testing.T) {
	uart: Uart_16450
	uart_init(&uart)
	_ = uart_out(&uart, UART_COM1_BASE + 2, 0xC7)
	iir, _ := uart_in(&uart, UART_COM1_BASE + 2)
	testing.expect_value(t, iir, UART_IIR_NONE)
	testing.expect_value(t, iir & 0xC0, u8(0))
}

@(test)
test_uart_loopback_cross_wires_modem_lines :: proc(t: ^testing.T) {
	uart: Uart_16450
	uart_init(&uart)
	_ = uart_out(&uart, UART_COM1_BASE + 4, UART_MCR_LOOP | UART_MCR_DTR | UART_MCR_RTS | UART_MCR_OUT1 | UART_MCR_OUT2)
	msr, _ := uart_in(&uart, UART_COM1_BASE + 6)
	testing.expect_value(t, msr & 0xF0, u8(0xF0))
	msr, _ = uart_in(&uart, UART_COM1_BASE + 6)
	testing.expect_value(t, msr & 0x0F, u8(0))
	_ = uart_out(&uart, UART_COM1_BASE + 4, UART_MCR_DTR | UART_MCR_RTS)
	msr, _ = uart_in(&uart, UART_COM1_BASE + 6)
	testing.expect_value(t, msr & 0xF0, u8(0))
	testing.expect(t, msr & (UART_MSR_DCTS | UART_MSR_DDSR) != 0)
}

@(test)
test_uart_transmit_obeys_absolute_deadline :: proc(t: ^testing.T) {
	uart: Uart_16450
	uart_init(&uart)
	_ = uart_out(&uart, UART_COM1_BASE + 3, 0x03)
	_ = uart_out(&uart, UART_COM1_BASE, 'A')
	deadline, pending := uart_next_deadline(&uart)
	testing.expect(t, pending)
	uart_advance_to(&uart, deadline - 1)
	testing.expect_value(t, len(uart_output(&uart)), 0)
	uart_advance_to(&uart, deadline)
	testing.expect_value(t, string(uart_output(&uart)), "A")
	testing.expect_value(t, uart_now(&uart), deadline)
	_, pending = uart_next_deadline(&uart)
	testing.expect(t, !pending)
}

@(test)
test_uart_holding_register_and_batch_invariance :: proc(t: ^testing.T) {
	whole, split: Uart_16450
	uart_init(&whole)
	_ = uart_out(&whole, UART_COM1_BASE + 3, 0x03)
	_ = uart_out(&whole, UART_COM1_BASE, 'H')
	_ = uart_out(&whole, UART_COM1_BASE, 'i')
	split = whole
	span := uart_ticks_until_idle(&whole)
	uart_advance(&whole, span)
	uart_advance(&split, span / 3)
	uart_advance(&split, span - span / 3)
	testing.expect_value(t, string(uart_output(&whole)), "Hi")
	testing.expect_value(t, string(uart_output(&split)), "Hi")
	testing.expect_value(t, whole.now_tick, split.now_tick)
	testing.expect_value(t, whole.lsr, split.lsr)
}

@(test)
test_uart_divisor_controls_character_deadline :: proc(t: ^testing.T) {
	fast, slow: Uart_16450
	uart_init(&fast)
	uart_init(&slow)
	_ = uart_out(&fast, UART_COM1_BASE + 3, 0x80)
	_ = uart_out(&fast, UART_COM1_BASE, 1)
	_ = uart_out(&fast, UART_COM1_BASE + 1, 0)
	_ = uart_out(&fast, UART_COM1_BASE + 3, 0x03)
	_ = uart_out(&fast, UART_COM1_BASE, 'F')
	_ = uart_out(&slow, UART_COM1_BASE + 3, 0x80)
	_ = uart_out(&slow, UART_COM1_BASE, 2)
	_ = uart_out(&slow, UART_COM1_BASE + 1, 0)
	_ = uart_out(&slow, UART_COM1_BASE + 3, 0x03)
	_ = uart_out(&slow, UART_COM1_BASE, 'S')
	testing.expect_value(t, uart_ticks_until_idle(&slow), uart_ticks_until_idle(&fast) * 2)
}

@(test)
test_uart_loopback_receive_and_irq_priority :: proc(t: ^testing.T) {
	uart: Uart_16450
	uart_init(&uart)
	_ = uart_out(&uart, UART_COM1_BASE + 1, UART_IER_RDA | UART_IER_THRE | UART_IER_RLS)
	_ = uart_out(&uart, UART_COM1_BASE + 4, UART_MCR_LOOP | UART_MCR_OUT2)
	_ = uart_out(&uart, UART_COM1_BASE, 'Z')
	uart_advance(&uart, uart_ticks_until_idle(&uart))
	testing.expect(t, uart_take_irq(&uart))
	testing.expect_value(t, len(uart_output(&uart)), 0)
	uart_receive(&uart, 'X')
	iir, _ := uart_in(&uart, UART_COM1_BASE + 2)
	testing.expect_value(t, iir, UART_IIR_RLS)
	_, _ = uart_in(&uart, UART_COM1_BASE + 5)
	iir, _ = uart_in(&uart, UART_COM1_BASE + 2)
	testing.expect_value(t, iir, UART_IIR_RDA)
	rbr, _ := uart_in(&uart, UART_COM1_BASE)
	testing.expect_value(t, rbr, u8('Z'))
	iir, _ = uart_in(&uart, UART_COM1_BASE + 2)
	testing.expect_value(t, iir, UART_IIR_THRE)
	iir, _ = uart_in(&uart, UART_COM1_BASE + 2)
	testing.expect_value(t, iir, UART_IIR_NONE)
}

@(test)
test_uart_thre_irq_requires_out2 :: proc(t: ^testing.T) {
	uart: Uart_16450
	uart_init(&uart)
	_ = uart_out(&uart, UART_COM1_BASE + 1, UART_IER_THRE)
	testing.expect(t, !uart_take_irq(&uart))
	_ = uart_out(&uart, UART_COM1_BASE + 4, UART_MCR_OUT2)
	testing.expect(t, uart_irq_line(&uart))
	testing.expect(t, uart_take_irq(&uart))
	iir, _ := uart_in(&uart, UART_COM1_BASE + 2)
	testing.expect_value(t, iir, UART_IIR_THRE)
	testing.expect(t, !uart_irq_line(&uart))
}

@(test)
test_uart_capture_is_bounded :: proc(t: ^testing.T) {
	uart: Uart_16450
	uart_init(&uart)
	for i in 0 ..< UART_CAPTURE_CAPACITY + 3 {
		_ = uart_out(&uart, UART_COM1_BASE, u8(i))
		uart_advance(&uart, uart_ticks_until_idle(&uart))
	}
	testing.expect_value(t, len(uart_output(&uart)), UART_CAPTURE_CAPACITY)
	testing.expect_value(t, uart_output_dropped(&uart), u64(3))
}
