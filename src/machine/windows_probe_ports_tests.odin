// SPDX-License-Identifier: GPL-3.0-only
package machine

import hv "../hv"
import "core:log"
import "core:testing"

@(test)
test_windows_known_absent_probe_ports :: proc(t: ^testing.T) {
	if !hv.available() {
		log.warn("WHPX not available")
		return
	}
	m := new(Machine)
	defer free(m)
	if !testing.expect(t, machine_init(m, 64 * 1024 * 1024)) {return}
	defer machine_destroy(m)
	bus_set_strict_io(&m.platform.bus, true)

	ports := [17]u16{
		0x94, 0x102, 0x180, 0x183, 0x18F, 0x421, 0x4A1, 0x622, 0x623,
		0x67A, 0x77A, 0xA22, 0xA23, 0xA78, 0xB78, 0xE22, 0xE23,
	}
	for port in ports {
		testing.expect_value(t, bus_io_read(&m.platform.bus, port, 1), u32(0xFF))
		bus_io_write(&m.platform.bus, port, 1, 0x5A)
	}
	testing.expect_value(t, bus_io_read(&m.platform.bus, 0xE22, 2), u32(0xFFFF))
	bus_io_write(&m.platform.bus, 0xE22, 2, 0x00E0)
	testing.expect(t, !m.platform.bus.frozen)
	testing.expect_value(t, m.platform.bus.unclassified_count, u64(0))
	testing.expect_value(t, m.platform.bus.passive_count, u64(36))
}
