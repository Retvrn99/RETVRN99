// SPDX-License-Identifier: GPL-3.0-only
package machine

import hv "../hv"
import "core:log"
import "core:testing"
import "core:time"

@(private = "file")
rom_test_contains :: proc(haystack, needle: []u8) -> bool {
	if len(needle) == 0 || len(needle) > len(haystack) {return false}
	for offset in 0 ..= len(haystack) - len(needle) {
		match := true
		for i in 0 ..< len(needle) {
			if haystack[offset + i] != needle[i] {
				match = false
				break
			}
		}
		if match {return true}
	}
	return false
}

@(test)
test_rom_placement_math :: proc(t: ^testing.T) {
	testing.expect_value(t, len(BIOS_IMAGE), BIOS_SIZE)
	testing.expect_value(t, len(VGABIOS_IMAGE), VGABIOS_SPAN_SIZE)
	testing.expect_value(t, int(BIOS_SHADOW_GPA), 0xE0000)
	testing.expect_value(t, u64(BIOS_HIGH_GPA), u64(0xFFFE0000))
	testing.expect_value(t, int(OPTION_ROM_HOLE_GPA), 0xC8000)
	testing.expect_value(t, int(OPTION_ROM_HOLE_SIZE), 0x18000)
	testing.expect(t, VGABIOS_GPA + len(VGABIOS_IMAGE) == OPTION_ROM_HOLE_GPA)
}

@(test)
test_rom_exposes_pci_bios :: proc(t: ^testing.T) {
	bios32_pci_service := [?]u8{0x24, 0x50, 0x43, 0x49} // "$PCI"
	testing.expect(t, rom_test_contains(BIOS_IMAGE[:], bios32_pci_service[:]))
}

@(test)
test_rom_place :: proc(t: ^testing.T) {
	ram := make([]u8, 0x100000)
	defer delete(ram)
	testing.expect(t, rom_place(ram))
	// BIOS spans 0xE0000..0xFFFFF
	testing.expect_value(t, ram[BIOS_SHADOW_GPA], BIOS_IMAGE[0])
	testing.expect_value(t, ram[0xFFFFF], BIOS_IMAGE[len(BIOS_IMAGE) - 1])
	// the low-MB image backs the F-segment jump target of the reset vector
	testing.expect_value(t, ram[0xFFFF0], BIOS_IMAGE[len(BIOS_IMAGE) - 16])
	// VGA BIOS at 0xC0000 with option-ROM signature 55AA
	testing.expect_value(t, ram[VGABIOS_GPA], u8(0x55))
	testing.expect_value(t, ram[VGABIOS_GPA + 1], u8(0xAA))
	testing.expect_value(t, ram[VGABIOS_GPA + 100], VGABIOS_IMAGE[100])
}

@(test)
test_rom_place_small_ram :: proc(t: ^testing.T) {
	ram := make([]u8, 0x80000)
	defer delete(ram)
	testing.expect(t, !rom_place(ram))
}

@(test)
test_load_roms_exposes_open_bus_hole_and_keeps_shadow_ranges_writable :: proc(t: ^testing.T) {
	if !hv.available() {
		log.warn("WHPX not available")
		return
	}
	testing.set_fail_timeout(t, 10 * time.Second)
	vm: hv.Vm
	if !testing.expect(t, hv.create(&vm, 64 * 1024 * 1024)) {return}
	defer hv.destroy(&vm)
	if !testing.expect(t, load_roms(&vm)) {return}
	vm.ram[0xC8000] = 0x11
	vm.ram[0xDFFFF] = 0x22
	copy(
		vm.ram[0x7C00:],
		[]u8 {
			0xFA,
			0xB8, 0x00, 0xC8,
			0x8E, 0xD8,
			0xA0, 0x00, 0x00,
			0x2E, 0xA2, 0x00, 0x05,
			0xC6, 0x06, 0x00, 0x00, 0x42,
			0xA0, 0x00, 0x00,
			0x2E, 0xA2, 0x01, 0x05,
			0xB8, 0xFF, 0xDF,
			0x8E, 0xD8,
			0xA0, 0x0F, 0x00,
			0x2E, 0xA2, 0x02, 0x05,
			0xB8, 0x00, 0xC0,
			0x8E, 0xD8,
			0xA0, 0x00, 0x00,
			0x2E, 0xA2, 0x03, 0x05,
			0xA0, 0x01, 0x00,
			0x2E, 0xA2, 0x04, 0x05,
			0xC6, 0x06, 0x00, 0x50, 0x99,
			0xA0, 0x00, 0x50,
			0x2E, 0xA2, 0x05, 0x05,
			0xB8, 0x00, 0xE0,
			0x8E, 0xD8,
			0xA0, 0x00, 0x00,
			0x2E, 0xA2, 0x06, 0x05,
			0xC6, 0x06, 0x00, 0x10, 0x77,
			0xA0, 0x00, 0x10,
			0x2E, 0xA2, 0x07, 0x05,
			0xF4,
		},
	)
	hv.set_realmode_entry(&vm, 0, 0x7C00)
	exit := hv.run(&vm)
	if !testing.expect_value(t, exit.kind, hv.Exit_Kind.Halt) {return}
	testing.expect_value(t, vm.ram[0x500], u8(0xFF))
	testing.expect_value(t, vm.ram[0x501], u8(0xFF))
	testing.expect_value(t, vm.ram[0x502], u8(0xFF))
	testing.expect_value(t, vm.ram[0x503], u8(0x55))
	testing.expect_value(t, vm.ram[0x504], u8(0xAA))
	testing.expect_value(t, vm.ram[0x505], u8(0x99))
	testing.expect_value(t, vm.ram[0x506], BIOS_IMAGE[0])
	testing.expect_value(t, vm.ram[0x507], u8(0x77))
	testing.expect_value(t, vm.ram[0xC8000], u8(0x11))
	testing.expect_value(t, vm.ram[0xDFFFF], u8(0x22))
	testing.expect_value(t, vm.ram[0xE1000], u8(0x77))
}

@(test)
test_high_bios_alias_guest_store_is_isolated_and_survives :: proc(t: ^testing.T) {
	if !hv.available() {
		log.warn("WHPX not available")
		return
	}
	testing.set_fail_timeout(t, 10 * time.Second)
	vm: hv.Vm
	if !testing.expect(t, hv.create(&vm, 64 * 1024 * 1024)) {return}
	defer hv.destroy(&vm)
	image := make([]u8, BIOS_SIZE)
	defer delete(image)
	image[0x11000] = 0x22
	copy(
		image[0x1FF80:],
		[]u8 {
			0xFA,
			0x2E, 0xC6, 0x06, 0x00, 0x10, 0x6D,
			0x2E, 0xA0, 0x00, 0x10,
			0xA2, 0x0B, 0x05,
			0xF4,
		},
	)
	copy(image[0x1FFF0:], []u8{0xEB, 0x8E})
	if !testing.expect(t, hv.map_rom(&vm, BIOS_HIGH_GPA, image)) {return}
	vm.ram[BIOS_SHADOW_GPA + 0x1000] = 0xA5
	exit := hv.run(&vm)
	if !testing.expect_value(t, exit.kind, hv.Exit_Kind.Halt) {return}
	testing.expect_value(t, vm.ram[0x50B], u8(0x6D))
	testing.expect_value(t, vm.ram[BIOS_SHADOW_GPA + 0x1000], u8(0xA5))
	testing.expect_value(t, image[0x11000], u8(0x22))
}
