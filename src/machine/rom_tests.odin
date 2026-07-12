// SPDX-License-Identifier: GPL-3.0-only
package machine

import "core:testing"

@(test)
test_rom_placement_math :: proc(t: ^testing.T) {
	testing.expect_value(t, len(BIOS_IMAGE), BIOS_SIZE)
	testing.expect_value(t, int(BIOS_SHADOW_GPA), 0xE0000)
	testing.expect_value(t, u64(BIOS_HIGH_GPA), u64(0xFFFE0000))
	testing.expect(t, VGABIOS_GPA + len(VGABIOS_IMAGE) <= BIOS_SHADOW_GPA)
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
