// SPDX-License-Identifier: GPL-3.0-only
package machine

// SeaBIOS / SeaVGABIOS images baked into the binary.

import hv "../hv"

@(rodata) BIOS_IMAGE := #load("../../assets/seabios/bios.bin")
@(rodata) VGABIOS_IMAGE := #load("../../assets/seabios/vgabios-stdvga.bin")

BIOS_SIZE :: 128 * 1024
VGABIOS_GPA :: 0xC0000
BIOS_SHADOW_GPA :: 0x100000 - BIOS_SIZE // top of the first MB
BIOS_HIGH_GPA :: 0x1_0000_0000 - BIOS_SIZE // reset vector alias below 4GB

// copies both images into low guest RAM; pure, unit-testable
rom_place :: proc(ram: []u8) -> bool {
	if len(ram) < 0x100000 || len(BIOS_IMAGE) != BIOS_SIZE {
		return false
	}
	if VGABIOS_GPA + len(VGABIOS_IMAGE) > BIOS_SHADOW_GPA {
		return false
	}
	copy(ram[BIOS_SHADOW_GPA:], BIOS_IMAGE)
	copy(ram[VGABIOS_GPA:], VGABIOS_IMAGE)
	return true
}

// low-RAM copies plus a Read|Execute alias so the reset vector
// (CS base 0xFFFF0000, RIP 0xFFF0) and SeaBIOS's shadow-copy source
// (code32flat_start + 0xfff00000) both resolve
load_roms :: proc(vm: ^hv.Vm) -> bool {
	if !rom_place(vm.ram) {
		return false
	}
	return hv.map_rom(vm, BIOS_HIGH_GPA, BIOS_IMAGE)
}
