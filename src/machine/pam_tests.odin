// SPDX-License-Identifier: GPL-3.0-only
package machine

import hv "../hv"
import "core:log"
import "core:testing"
import "core:time"

@(test)
test_i440fx_pam_keeps_option_shadow_executable_after_lock :: proc(t: ^testing.T) {
	if !hv.available() {
		log.warn("WHPX not available")
		return
	}
	testing.set_fail_timeout(t, 10 * time.Second)
	m: Machine
	if !testing.expect(t, machine_init(&m, 64 * 1024 * 1024)) {return}
	defer machine_destroy(&m)
	if !testing.expect(t, load_roms(&m.vm)) {return}

	bus_io_write(&m.bus, 0xCF8, 4, 0x8000_005C)
	bus_io_write(&m.bus, 0xCFD, 1, 0x33)
	m.vm.ram[0xD9309] = 0xF4
	bus_io_write(&m.bus, 0xCFD, 1, 0x11)

	hv.set_realmode_entry(&m.vm, 0xD9000, 0x0309)
	exit := hv.run(&m.vm)
	testing.expect_value(t, exit.kind, hv.Exit_Kind.Halt)
}
