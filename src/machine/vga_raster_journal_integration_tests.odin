// SPDX-License-Identifier: GPL-3.0-only
package machine

import hv "../hv"
import "core:log"
import "core:testing"
import "core:time"

// The raster journal depends on machine_vga_write stamping every guest port
// write with device time before it reaches the register file. This crosses that
// boundary instead of calling the trigger directly, and it pins the counters
// reaching the acceptance execution results, which is where a real guest run
// can observe them.
@(test)
test_machine_vga_records_mid_frame_palette_deltas :: proc(t: ^testing.T) {
	if !hv.available() {
		log.warn("WHPX not available")
		return
	}
	testing.set_fail_timeout(t, 10 * time.Second)
	m := new(Machine)
	defer free(m)
	if !testing.expect(t, machine_init(m, 64 * 1024 * 1024)) {return}
	defer machine_destroy(m)
	machine_clock_set_running(m, false)
	// The GSW-VGA function decodes no port I/O until firmware enables it, so a
	// write before this reaches no register at all. Bus 0, device 2, function 0,
	// command register, I/O and memory space on.
	bus_io_write(&m.bus, 0xCF8, 4, 0x8000_1004)
	bus_io_write(&m.bus, 0xCFC, 2, 0x0003)

	line_ns := m.vga.timing.line_period_ns
	if !testing.expect(t, line_ns > 0) {return}
	machine_advance_time_ns(m, line_ns * 40 + line_ns / 2)

	// Power-on 80x25 text resolves colour through the palette, so a DAC write
	// landing on scan line 40 is a recordable delta. Entry 1 defaults to
	// 00/00/2A, and every component of the replacement differs.
	testing.expect(t, machine_io_write(m, 0x3C8, 1, 1))
	testing.expect(t, machine_io_write(m, 0x3C9, 1, 0x3F))
	testing.expect(t, machine_io_write(m, 0x3C9, 1, 0x15))
	testing.expect(t, machine_io_write(m, 0x3C9, 1, 0x00))

	execution := machine_execution_counters(m)
	testing.expect_value(t, execution.raster_journal_deltas, u64(3))
	testing.expect_value(t, execution.raster_journal_truncations, u64(0))
	testing.expect_value(t, m.vga.raster_journal.count, u32(3))
	testing.expect_value(t, m.vga.raster_journal.entries[0].line, u16(40))
}
