// SPDX-License-Identifier: GPL-3.0-only
package machine

import hv "../hv"
import video "../vga"
import "core:strings"
import "core:testing"

@(test)
test_machine_runtime_diagnostic_reports_stalled_halt :: proc(t: ^testing.T) {
	m := new(Machine)
	defer free(m)
	m.active_ns = 1
	machine_runtime_diagnostic_note_io(m, 0x0080, true, 1, 0x55)
	machine_runtime_diagnostic_note_halt(
		m,
		hv.Exit{kind = .Halt, cs = 0x1234, rip = 0x5678, rflags = 0x202},
	)
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
	m.vm.io_origin = {
		valid  = true,
		linear = 0xC0123456,
	}
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
	offer := Pic_Interrupt_Token {
		kind      = .Slave,
		slave_irq = 1,
	}
	for _ in 0 ..< MACHINE_VGA_IRQ_STORM_COUNT {
		machine_runtime_diagnostic_note_irq(m, offer)
	}

	message, available := machine_take_runtime_diagnostic(m)
	defer delete(message)
	testing.expect(t, available)
	testing.expect(t, strings.contains(message, "VGA IRQ9 storm"))
	testing.expect(t, strings.contains(message, "deliveries=256"))
}

@(test)
test_machine_runtime_diagnostic_reports_gsw_shutdown_marker_stall :: proc(t: ^testing.T) {
	m := new(Machine)
	defer free(m)
	m.active_ns = 1
	machine_runtime_diagnostic_note_shutdown_marker(m, 0xD0)
	machine_runtime_diagnostic_note_shutdown_marker(m, 0xD5)
	machine_runtime_diagnostic_note_shutdown_marker(m, 0xD7)
	m.active_ns += MACHINE_GSW_SHUTDOWN_STALL_NS
	machine_runtime_diagnostic_check_shutdown(m)

	message, available := machine_take_runtime_diagnostic(m)
	defer delete(message)
	testing.expect(t, available)
	testing.expect(t, strings.contains(message, "GSW shutdown stalled for 5s"))
	testing.expect(t, strings.contains(message, "markers=d0d5d7"))
}

@(test)
test_machine_runtime_diagnostic_reports_mmio_exit_storm_state :: proc(t: ^testing.T) {
	m := new(Machine)
	defer free(m)
	m.active_ns = 1
	machine_runtime_diagnostic_check_mmio(m)
	m.active_ns += MACHINE_MMIO_STORM_WINDOW_NS
	m.vm.mmio_fallbacks = MACHINE_MMIO_STORM_THRESHOLD + 5
	m.vm.mmio_scalar_fallbacks = MACHINE_MMIO_STORM_THRESHOLD
	m.vm.mmio_string_fallbacks = 5
	m.vm.device_alias_maps = 7
	m.vm.device_alias_unmaps = 6
	m.vga.dispi[video.DISPI_INDEX_ENABLE] = 0xE1
	m.vga.dispi[video.DISPI_INDEX_BPP] = 32
	m.vga.bank_read = 2
	m.vga.bank_write = 3
	append(
		&m.vm.device_aliases,
		hv.Device_Alias {
			mapped = false,
			request_pending = true,
			backing_offset = 0x10000,
			requested_offset = 0x18000,
		},
	)
	defer delete(m.vm.device_aliases)
	machine_runtime_diagnostic_check_mmio(m)

	message, available := machine_take_runtime_diagnostic(m)
	defer delete(message)
	testing.expect(t, available)
	testing.expect(t, strings.contains(message, "MMIO exit storm"))
	testing.expect(t, strings.contains(message, "fallbacks=20005 scalar=20000 string=5"))
	testing.expect(t, strings.contains(message, "vbe=e1 bpp=32 bank=2/3"))
	testing.expect(t, strings.contains(message, "alias=0 pending=1"))
	testing.expect(t, strings.contains(message, "maps=7 unmaps=6"))
}

@(test)
test_machine_runtime_diagnostic_ignores_completed_gsw_shutdown :: proc(t: ^testing.T) {
	m := new(Machine)
	defer free(m)
	m.active_ns = 1
	machine_shutdown_trace_write(m, 0x80, 1, 0xD5)
	machine_shutdown_trace_write(m, 0x80, 1, 0xDC)
	machine_shutdown_trace_write(m, 0x80, 1, 0x7F)
	m.active_ns += MACHINE_GSW_SHUTDOWN_STALL_NS
	machine_runtime_diagnostic_check_shutdown(m)

	_, available := machine_take_runtime_diagnostic(m)
	testing.expect(t, !available)
	testing.expect_value(t, m.runtime_diagnostic.shutdown_marker_count, u64(2))
}
