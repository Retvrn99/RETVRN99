// SPDX-License-Identifier: GPL-3.0-only
package machine

import hv "../hv"
import "core:log"
import "core:testing"
import "core:time"

@(test)
test_amd756_romw_does_not_lock_low_bios_shadow_ram :: proc(t: ^testing.T) {
	if !hv.available() {
		log.warn("WHPX not available")
		return
	}
	testing.set_fail_timeout(t, 10 * time.Second)
	m := new(Machine)
	defer free(m)
	if !testing.expect(t, machine_init(m, 64 * 1024 * 1024)) {return}
	defer machine_destroy(m)
	if !testing.expect(t, load_roms(&m.vm)) {return}

	testing.expect_value(t, pci_amd756_bios_write_enabled(&m.pci), false)

	// AMD-751 has no Intel PAM register.
	bus_io_write(&m.bus, 0xCF8, 4, 0x8000_0058)
	bus_io_write(&m.bus, 0xCFD, 1, 0xFF)
	testing.expect_value(t, bus_io_read(&m.bus, 0xCFD, 1), u32(0))

	bus_io_write(&m.bus, 0xCF8, 4, 0x8000_3840)
	bus_io_write(&m.bus, 0xCFC, 1, u32(AMD756_ISA_ROM_WRITE_ENABLE))
	testing.expect_value(t, pci_amd756_bios_write_enabled(&m.pci), true)
	m.vm.ram[0xE1000] = 0x66

	bus_io_write(&m.bus, 0xCFC, 1, 0)
	testing.expect_value(t, pci_amd756_bios_write_enabled(&m.pci), false)
	m.vm.ram[0xE1001] = 0x77
	testing.expect_value(t, m.vm.ram[0xE1000], u8(0x66))
	testing.expect_value(t, m.vm.ram[0xE1001], u8(0x77))
}

@(test)
test_amd756_guest_romw_clear_keeps_low_bios_shadow_writable :: proc(t: ^testing.T) {
	if !hv.available() {
		log.warn("WHPX not available")
		return
	}
	testing.set_fail_timeout(t, 10 * time.Second)
	m := new(Machine)
	defer free(m)
	if !testing.expect(t, machine_init(m, 64 * 1024 * 1024)) {return}
	defer machine_destroy(m)
	if !testing.expect(t, load_roms(&m.vm)) {return}

	copy(
		m.vm.ram[0x7C00:],
		[]u8 {
			0xFA,
			0xBA, 0xF8, 0x0C,
			0x66, 0xB8, 0x40, 0x38, 0x00, 0x80,
			0x66, 0xEF,
			0xBA, 0xFC, 0x0C,
			0xB0, 0x01,
			0xEE,
			0xB8, 0x00, 0xE0,
			0x8E, 0xD8,
			0xC6, 0x06, 0x00, 0x10, 0x66,
			0x30, 0xC0,
			0xEE,
			0xC6, 0x06, 0x01, 0x10, 0x77,
			0xF4,
		},
	)
	hv.set_realmode_entry(&m.vm, 0, 0x7C00)
	steps := 0
	for _ in 0 ..< 64 {
		steps += 1
		if !step(m) || m.cpu_halted {break}
	}
	if !testing.expect_value(t, m.bus.freeze_msg, "") {return}
	if !testing.expect_value(t, m.cpu_halted, true) {return}
	testing.expect(t, steps >= 1)

	bus_io_write(&m.bus, 0xCF8, 4, 0x8000_3840)
	testing.expect_value(
		t,
		bus_io_read(&m.bus, 0xCFC, 1) & u32(AMD756_ISA_ROM_WRITE_ENABLE),
		u32(0),
	)
	testing.expect_value(t, m.vm.ram[0xE1000], u8(0x66))
	testing.expect_value(t, m.vm.ram[0xE1001], u8(0x77))
}
