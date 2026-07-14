// SPDX-License-Identifier: GPL-3.0-only
package machine

import hv "../hv"
import "core:log"
import "core:testing"
import "core:time"

@(test)
test_win98_vtd_pit_calibration_reaches_ff_window :: proc(t: ^testing.T) {
	if !hv.available() {
		log.warn("WHPX not available")
		return
	}
	testing.set_fail_timeout(t, 10 * time.Second)
	m: Machine
	if !testing.expect(t, machine_init(&m, 64 * 1024 * 1024)) {return}
	defer machine_destroy(&m)

	// VTD programs mode 2, then waits for a changed count in the FFxx window.
	copy(
		m.vm.ram[0x7C00:],
		[]u8 {
			0xB0,
			0x34,
			0xE6,
			0x43,
			0x31,
			0xC0,
			0xE6,
			0x40,
			0xE6,
			0x40,
			0xE4,
			0x40,
			0x31,
			0xC0,
			0xE6,
			0x43,
			0xE4,
			0x40,
			0x88,
			0xC1,
			0xE4,
			0x40,
			0x88,
			0xC5,
			0x31,
			0xC0,
			0xE6,
			0x43,
			0xE4,
			0x40,
			0x88,
			0xC4,
			0xE4,
			0x40,
			0x86,
			0xE0,
			0x39,
			0xC8,
			0x74,
			0xF0,
			0x80,
			0xFC,
			0xFF,
			0x75,
			0xEB,
			0xF4,
		},
	)
	hv.set_realmode_entry(&m.vm, 0, 0x7C00)
	machine_clock_set_running(&m, true)

	start := time.tick_now()
	for !m.cpu_halted && time.tick_since(start) < time.Second {
		if !step(&m) {break}
	}
	testing.expect(t, m.cpu_halted)
}
