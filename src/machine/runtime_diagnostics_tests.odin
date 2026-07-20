// SPDX-License-Identifier: GPL-3.0-only
package machine

import hv "../hv"
import "core:strings"
import "core:testing"

@(test)
test_machine_runtime_diagnostic_reports_stalled_halt :: proc(t: ^testing.T) {
	m := new(Machine)
	defer free(m)
	m.active_ns = 1
	machine_runtime_diagnostic_note_io(m, 0x0080, true, 1, 0x55)
	machine_runtime_diagnostic_note_halt(m, hv.Exit {
		kind = .Halt,
		cs = 0x1234,
		rip = 0x5678,
		rflags = 0x202,
	})
	m.active_ns += MACHINE_STALLED_HALT_NS
	machine_runtime_diagnostic_check_halt(m)

	message, available := machine_take_runtime_diagnostic(m)
	defer delete(message)
	testing.expect(t, available)
	testing.expect(t, strings.contains(message, "guest halted for 5s"))
	testing.expect(t, strings.contains(message, "CS:IP=1234:00005678"))
	testing.expect(t, strings.contains(message, "IF=1"))
	testing.expect(t, strings.contains(message, "last_io=w[0080]/1=00000055"))
}

@(test)
test_machine_runtime_diagnostic_reports_vga_status_poll :: proc(t: ^testing.T) {
	m := new(Machine)
	defer free(m)
	m.active_ns = 1
	m.vm.io_origin = {valid = true, linear = 0xC0123456}
	machine_runtime_diagnostic_note_io(m, 0x03DA, false, 1, 0x08)
	m.active_ns += MACHINE_VGA_POLL_STALL_NS
	machine_runtime_diagnostic_note_io(m, 0x03DA, false, 1, 0x00)

	message, available := machine_take_runtime_diagnostic(m)
	defer delete(message)
	testing.expect(t, available)
	testing.expect(t, strings.contains(message, "polled VGA status for 2s"))
	testing.expect(t, strings.contains(message, "origin=c0123456"))
	testing.expect(t, strings.contains(message, "reads=2 status=00"))
}

@(test)
test_machine_runtime_diagnostic_reports_vga_irq9_storm :: proc(t: ^testing.T) {
	m := new(Machine)
	defer free(m)
	m.active_ns = 1
	offer := Pic_Interrupt_Token{kind = .Slave, slave_irq = 1}
	for _ in 0 ..< MACHINE_VGA_IRQ_STORM_COUNT {
		machine_runtime_diagnostic_note_irq(m, offer)
	}

	message, available := machine_take_runtime_diagnostic(m)
	defer delete(message)
	testing.expect(t, available)
	testing.expect(t, strings.contains(message, "VGA IRQ9 storm"))
	testing.expect(t, strings.contains(message, "deliveries=256"))
}
