// SPDX-License-Identifier: GPL-3.0-only
package machine

import "core:testing"

@(test)
pci_test_hostbridge_id :: proc(t: ^testing.T) {
	p: Pci
	pci_init(&p)
	pci_out(&p, 0xCF8, 4, 0x8000_0000)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), 0x12378086)
}

@(test)
pci_test_pam_writable :: proc(t: ^testing.T) {
	p: Pci
	pci_init(&p)
	// PAM0 = reg 0x59 -> dword 0x58, offset 1 (port 0xCFD)
	pci_out(&p, 0xCF8, 4, 0x8000_0058)
	pci_out(&p, 0xCFD, 1, 0x30)
	testing.expect_value(t, pci_in(&p, 0xCFD, 1), 0x30)
}

@(test)
pci_test_piix3_isa_bridge :: proc(t: ^testing.T) {
	p: Pci
	pci_init(&p)
	pci_out(&p, 0xCF8, 4, 0x8000_0800) // 00:01.0
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), 0x70008086)
	pci_out(&p, 0xCF8, 4, 0x8000_0808) // class dword
	testing.expect_value(t, pci_in(&p, 0xCFC, 4) >> 16, 0x0601)
	pci_out(&p, 0xCF8, 4, 0x8000_080C) // header type at byte 0x0E
	testing.expect_value(t, (pci_in(&p, 0xCFC, 4) >> 16) & 0xFF, 0x80)
	// SeaBIOS programs PIRQA-D during bridge setup.
	pci_out(&p, 0xCF8, 4, 0x8000_0860) // PIRQA-D routing
	pci_out(&p, 0xCFC, 4, 0x0B0A0B0A)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), 0x0B0A0B0A)
}

@(test)
pci_test_piix3_ide :: proc(t: ^testing.T) {
	p: Pci
	pci_init(&p)
	pci_out(&p, 0xCF8, 4, 0x8000_0900) // 00:01.1
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), 0x70108086)
	pci_out(&p, 0xCF8, 4, 0x8000_0908) // class dword: class 0x0101, bus-master IDE
	testing.expect_value(t, pci_in(&p, 0xCFC, 4) >> 8, 0x010180)
	pci_out(&p, 0xCF8, 4, 0x8000_0910) // BAR0 reads 0: legacy compatibility mode
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), 0)
}

@(test)
pci_test_intel_command_register_masks :: proc(t: ^testing.T) {
	p: Pci
	pci_init(&p)

	pci_out(&p, 0xCF8, 4, 0x8000_0004)
	testing.expect_value(t, pci_in(&p, 0xCFC, 2), 0x0006)
	pci_out(&p, 0xCFC, 2, 0xFFFF)
	testing.expect_value(t, pci_in(&p, 0xCFC, 2), 0x0146)
	pci_out(&p, 0xCFC, 2, 0)
	testing.expect_value(t, pci_in(&p, 0xCFC, 2), 0x0006)

	pci_out(&p, 0xCF8, 4, 0x8000_0804)
	testing.expect_value(t, pci_in(&p, 0xCFC, 2), 0x0007)
	pci_out(&p, 0xCFC, 2, 0xFFFF)
	testing.expect_value(t, pci_in(&p, 0xCFC, 2), 0x010F)
	pci_out(&p, 0xCFC, 2, 0)
	testing.expect_value(t, pci_in(&p, 0xCFC, 2), 0x0007)

	pci_out(&p, 0xCF8, 4, 0x8000_0904)
	testing.expect_value(t, pci_in(&p, 0xCFC, 2), 0x0005)
	pci_out(&p, 0xCFC, 2, 0xFFFF)
	testing.expect_value(t, pci_in(&p, 0xCFC, 2), 0x0005)
	pci_out(&p, 0xCFC, 2, 0)
	testing.expect_value(t, pci_in(&p, 0xCFC, 2), 0)
	pci_out(&p, 0xCFC, 2, 0xFFFA)
	testing.expect_value(t, pci_in(&p, 0xCFC, 2), 0)
}

@(test)
pci_test_intel_status_register_w1c :: proc(t: ^testing.T) {
	p: Pci
	pci_init(&p)

	p.functions[0].cfg[0x07] |= 0xF9
	pci_out(&p, 0xCF8, 4, 0x8000_0004)
	testing.expect_value(t, pci_in(&p, 0xCFE, 2), 0xFB80)
	pci_out(&p, 0xCFE, 2, 0x2000)
	testing.expect_value(t, pci_in(&p, 0xCFE, 2), 0xDB80)
	pci_out(&p, 0xCFE, 2, 0xFFFF)
	testing.expect_value(t, pci_in(&p, 0xCFE, 2), 0x0280)

	p.functions[1].cfg[0x07] |= 0x78
	pci_out(&p, 0xCF8, 4, 0x8000_0804)
	testing.expect_value(t, pci_in(&p, 0xCFE, 2), 0x7A00)
	pci_out(&p, 0xCFE, 2, 0xFFFF)
	testing.expect_value(t, pci_in(&p, 0xCFE, 2), 0x0200)

	p.functions[2].cfg[0x07] |= 0x38
	pci_out(&p, 0xCF8, 4, 0x8000_0904)
	testing.expect_value(t, pci_in(&p, 0xCFE, 2), 0x3A80)
	pci_out(&p, 0xCFE, 2, 0xFFFF)
	testing.expect_value(t, pci_in(&p, 0xCFE, 2), 0x0280)
	pci_out(&p, 0xCFE, 2, 0xFFFF)
	testing.expect_value(t, pci_in(&p, 0xCFE, 2), 0x0280)
}

@(test)
pci_test_piix3_pirq_routing :: proc(t: ^testing.T) {
	p: Pci
	pci_init(&p)
	pci_out(&p, 0xCF8, 4, 0x8000_0860)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), 0x8080_8080)
	pci_out(&p, 0xCFC, 4, 0xFFFF_FFFF)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), 0x8F8F_8F8F)

	pci_out(&p, 0xCFC, 1, 0x0B)
	irq, routed := pci_pirq_route(&p, 0)
	testing.expect_value(t, irq, 11)
	testing.expect_value(t, routed, true)
	pci_out(&p, 0xCFC, 1, 0x8B)
	irq, routed = pci_pirq_route(&p, 0)
	testing.expect_value(t, irq, 11)
	testing.expect_value(t, routed, false)
	pci_out(&p, 0xCFC, 1, 0x0D)
	irq, routed = pci_pirq_route(&p, 0)
	testing.expect_value(t, irq, 13)
	testing.expect_value(t, routed, false)
	_, routed = pci_pirq_route(&p, PIIX3_PIRQ_COUNT)
	testing.expect_value(t, routed, false)
}

@(test)
pci_test_piix3_ide_bus_master_bar :: proc(t: ^testing.T) {
	p: Pci
	pci_init(&p)
	pci_out(&p, 0xCF8, 4, 0x8000_0920)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), PIIX3_IDE_BMIBA_DEFAULT)
	base, valid := pci_ide_bus_master_io_base(&p)
	testing.expect_value(t, base, 0xC000)
	testing.expect_value(t, valid, true)
	testing.expect_value(t, pci_ide_io_enabled(&p), true)
	testing.expect_value(t, pci_ide_bus_master_enabled(&p), true)

	pci_out(&p, 0xCFC, 4, 0xFFFF_FFFF)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), 0xFFFF_FFF1)
	_, valid = pci_ide_bus_master_io_base(&p)
	testing.expect_value(t, valid, false)

	pci_out(&p, 0xCFC, 4, 0x0000_E007)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), 0x0000_E001)
	base, valid = pci_ide_bus_master_io_base(&p)
	testing.expect_value(t, base, 0xE000)
	testing.expect_value(t, valid, true)
	offset, claimed := pci_ide_bus_master_decode(&p, 0xE00F, 1)
	testing.expect_value(t, offset, 0x0F)
	testing.expect_value(t, claimed, true)
	_, claimed = pci_ide_bus_master_decode(&p, 0xE00F, 2)
	testing.expect_value(t, claimed, false)

	pci_out(&p, 0xCF8, 4, 0x8000_0904)
	pci_out(&p, 0xCFC, 2, 0x0004)
	testing.expect_value(t, pci_ide_io_enabled(&p), false)
	testing.expect_value(t, pci_ide_bus_master_enabled(&p), true)
	_, claimed = pci_ide_bus_master_decode(&p, 0xE000, 1)
	testing.expect_value(t, claimed, false)
	pci_out(&p, 0xCFC, 2, 0x0001)
	testing.expect_value(t, pci_ide_bus_master_enabled(&p), false)
	_, claimed = pci_ide_bus_master_decode(&p, 0xE000, 1)
	testing.expect_value(t, claimed, true)
}

@(test)
pci_test_gsw_chipset_identity :: proc(t: ^testing.T) {
	p: Pci
	pci_init(&p)
	pci_out(&p, 0xCF8, 4, 0x8000_1800) // 00:03.0
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), 0x0001_FFFE)
	pci_out(&p, 0xCF8, 4, 0x8000_1808)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), 0x0880_0001)
	pci_out(&p, 0xCF8, 4, 0x8000_182C)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), 0x0001_FFFE)
}

@(test)
pci_test_gsw_vga_identity_bars_and_persona :: proc(t: ^testing.T) {
	p: Pci
	pci_init(&p)
	pci_out(&p, 0xCF8, 4, 0x8000_1000)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), 0x0002_FFFE)
	pci_out(&p, 0xCF8, 4, 0x8000_1008)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4) >> 16, u32(0x0300))
	pci_out(&p, 0xCF8, 4, 0x8000_1010)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), GSW_VGA_CONTROL_BAR)
	pci_out(&p, 0xCFC, 4, 0xFFFF_FFFF)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0xFFFF_F000))
	pci_out(&p, 0xCFC, 4, GSW_VGA_CONTROL_BAR)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), GSW_VGA_CONTROL_BAR)
	pci_out(&p, 0xCF8, 4, 0x8000_1014)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), GSW_VGA_FRAMEBUFFER_BAR)
	pci_out(&p, 0xCFC, 4, 0xFFFF_FFFF)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0xFE00_0000))
	pci_out(&p, 0xCFC, 4, GSW_VGA_FRAMEBUFFER_BAR)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), GSW_VGA_FRAMEBUFFER_BAR)
	pci_out(&p, 0xCF8, 4, 0x8000_1040)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), GSW_VGA_CAPABILITY_SIGNATURE)
	pci_out(&p, 0xCF8, 4, 0x8000_1048)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(150) << 16 | 32)
	pci_out(&p, 0xCF8, 4, 0x8000_104C)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4) & 0x00FF_FFFF, u32(0x0003_0104))
}

@(test)
pci_test_gsw_chipset_capability_contract :: proc(t: ^testing.T) {
	p: Pci
	pci_init(&p)
	pci_out(&p, 0xCF8, 4, 0x8000_1840)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), GSW_CHIPSET_CAPABILITY_SIGNATURE)
	pci_out(&p, 0xCF8, 4, 0x8000_1844)
	testing.expect_value(
		t,
		pci_in(&p, 0xCFC, 4),
		u32(GSW_CHIPSET_CAPABILITY_LENGTH) << 16 | u32(GSW_CHIPSET_CAPABILITY_VERSION),
	)
	pci_out(&p, 0xCF8, 4, 0x8000_1848)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), 0x02BC_0100)
	pci_out(&p, 0xCF8, 4, 0x8000_184C)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), 0x0F0A_3404)
	pci_out(&p, 0xCF8, 4, 0x8000_1850)
	testing.expect_value(t, pci_in(&p, 0xCFC, 2), u32(GSW_CHIPSET_RESERVED_TIMELINE))

	pci_out(&p, 0xCF8, 4, 0x8000_1840)
	pci_out(&p, 0xCFC, 4, 0)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), GSW_CHIPSET_CAPABILITY_SIGNATURE)
}

@(test)
pci_test_gsw_chipset_config_is_read_only_and_resource_less :: proc(t: ^testing.T) {
	p: Pci
	pci_init(&p)
	pci_out(&p, 0xCF8, 4, 0x8000_1800)
	pci_out(&p, 0xCFC, 4, 0)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), 0x0001_FFFE)
	pci_out(&p, 0xCF8, 4, 0x8000_1808)
	pci_out(&p, 0xCFC, 4, 0xFFFF_FFFF)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), 0x0880_0001)
	pci_out(&p, 0xCF8, 4, 0x8000_1804)
	pci_out(&p, 0xCFC, 2, 0x0007)
	testing.expect_value(t, pci_in(&p, 0xCFC, 2), 0)
	pci_out(&p, 0xCF8, 4, 0x8000_180C)
	pci_out(&p, 0xCFC, 4, 0xFFFF_FFFF)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), 0)
	pci_out(&p, 0xCF8, 4, 0x8000_1810)
	pci_out(&p, 0xCFC, 4, 0xFFFF_FFFF)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), 0)
	for offset := u32(0x14); offset <= 0x24; offset += 4 {
		pci_out(&p, 0xCF8, 4, 0x8000_1800 | offset)
		pci_out(&p, 0xCFC, 4, 0xFFFF_FFFF)
		testing.expect_value(t, pci_in(&p, 0xCFC, 4), 0)
	}
	resource_offsets := [?]u32{0x30, 0x34, 0x3C}
	for offset in resource_offsets {
		pci_out(&p, 0xCF8, 4, 0x8000_1800 | offset)
		pci_out(&p, 0xCFC, 4, 0xFFFF_FFFF)
		testing.expect_value(t, pci_in(&p, 0xCFC, 4), 0)
	}
}

@(test)
pci_test_intel_identity_is_read_only :: proc(t: ^testing.T) {
	p: Pci
	pci_init(&p)
	pci_out(&p, 0xCF8, 4, 0x8000_0000)
	pci_out(&p, 0xCFC, 4, 0)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), 0x1237_8086)
	pci_out(&p, 0xCF8, 4, 0x8000_0008)
	pci_out(&p, 0xCFC, 4, 0xFFFF_FFFF)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4) >> 24, 0x06)
}

@(test)
pci_test_config_address_hardwired_bits :: proc(t: ^testing.T) {
	p: Pci
	pci_init(&p)
	pci_out(&p, 0xCF8, 4, 0xFFFF_FFFF)
	testing.expect_value(t, pci_in(&p, 0xCF8, 4), 0x80FF_FFFC)
}

@(test)
pci_test_config_data_access_does_not_wrap :: proc(t: ^testing.T) {
	p: Pci
	pci_init(&p)
	pci_out(&p, 0xCF8, 4, 0x8000_00FC)
	pci_out(&p, 0xCFF, 2, 0xABCD)
	testing.expect_value(t, pci_in(&p, 0xCFF, 1), 0)
	testing.expect_value(t, pci_in(&p, 0xCFF, 2), 0xFFFF)
	pci_out(&p, 0xCF8, 4, 0x8000_0000)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), 0x1237_8086)
}

@(test)
pci_test_config_data_widths_are_little_endian :: proc(t: ^testing.T) {
	p: Pci
	pci_init(&p)
	pci_out(&p, 0xCF8, 4, 0x8000_0000)
	testing.expect_value(t, pci_in(&p, 0xCFC, 1), 0x86)
	testing.expect_value(t, pci_in(&p, 0xCFD, 1), 0x80)
	testing.expect_value(t, pci_in(&p, 0xCFE, 2), 0x1237)
}

@(test)
pci_test_mechanism_2_enable_key_and_disable :: proc(t: ^testing.T) {
	p: Pci
	pci_init(&p)
	testing.expect_value(t, pci_in(&p, 0xC000, 4), 0xFFFF_FFFF)
	pci_out(&p, 0xCF8, 1, 0x0E)
	testing.expect_value(t, pci_in(&p, 0xC000, 4), 0xFFFF_FFFF)
	pci_out(&p, 0xCF8, 1, 0x61)
	testing.expect_value(t, pci_in(&p, 0xC000, 4), 0xFFFF_FFFF)
	pci_out(&p, 0xCF8, 1, 0xA0)
	testing.expect_value(t, pci_in(&p, 0xC000, 4), 0xFFFF_FFFF)
	pci_out(&p, 0xCF8, 1, 0xF1)
	testing.expect_value(t, pci_in(&p, 0xC000, 4), 0xFFFF_FFFF)
	pci_out(&p, 0xCF8, 1, 0x60)
	testing.expect_value(t, pci_in(&p, 0xC000, 4), 0xFFFF_FFFF)
	pci_out(&p, 0xCF8, 1, 0xF0)
	testing.expect_value(t, pci_in(&p, 0xC000, 4), 0x1237_8086)
	testing.expect_value(t, pci_mechanism_2_active(&p), true)
	testing.expect_value(t, pci_mechanism_2_claims(&p, 0xCFFF, 1), true)
	testing.expect_value(t, pci_mechanism_2_claims(&p, 0xCFFF, 2), false)
	pci_out(&p, 0xCF8, 1, 0)
	testing.expect_value(t, pci_in(&p, 0xC000, 4), 0xFFFF_FFFF)
	testing.expect_value(t, pci_mechanism_2_active(&p), false)
}

@(test)
pci_test_mechanism_2_bus_device_and_function :: proc(t: ^testing.T) {
	p: Pci
	pci_init(&p)
	pci_out(&p, 0xCF8, 1, 0xF2) // function 1
	pci_out(&p, 0xCFA, 1, 0)
	testing.expect_value(t, pci_in(&p, 0xC100, 4), 0x7010_8086)
	testing.expect_value(t, pci_in(&p, 0xC000, 4), 0xFFFF_FFFF)
	pci_out(&p, 0xCF8, 1, 0xF0)
	testing.expect_value(t, pci_in(&p, 0xC300, 4), 0x0001_FFFE)
	testing.expect_value(t, pci_in(&p, 0xC200, 4), 0x0002_FFFE)
	pci_out(&p, 0xCFA, 1, 1)
	testing.expect_value(t, pci_in(&p, 0xC000, 4), 0xFFFF_FFFF)
}

@(test)
pci_test_mechanism_2_register_lanes :: proc(t: ^testing.T) {
	p: Pci
	pci_init(&p)
	pci_out(&p, 0xCF8, 1, 0xF0)
	testing.expect_value(t, pci_in(&p, 0xC000, 1), 0x86)
	testing.expect_value(t, pci_in(&p, 0xC001, 1), 0x80)
	testing.expect_value(t, pci_in(&p, 0xC002, 2), 0x1237)
}

@(test)
pci_test_mechanism_2_control_is_separate_from_mechanism_1 :: proc(t: ^testing.T) {
	p: Pci
	pci_init(&p)
	pci_out(&p, 0xCF8, 4, 0x8000_1800)
	pci_out(&p, 0xCF8, 1, 0xF2)
	pci_out(&p, 0xCFA, 1, 7)
	testing.expect_value(t, pci_in(&p, 0xCF8, 4), 0x8000_1800)
	testing.expect_value(t, pci_in(&p, 0xCF8, 1), 0xF2)
	testing.expect_value(t, pci_in(&p, 0xCFA, 1), 7)
}

@(test)
pci_test_mechanism_2_config_data_does_not_wrap :: proc(t: ^testing.T) {
	p: Pci
	pci_init(&p)
	pci_out(&p, 0xCF8, 1, 0xF0)
	pci_out(&p, 0xC0FF, 2, 0xABCD)
	testing.expect_value(t, pci_in(&p, 0xC0FF, 1), 0)
	testing.expect_value(t, pci_in(&p, 0xC0FF, 2), 0xFFFF)
	testing.expect_value(t, pci_in(&p, 0xC000, 4), 0x1237_8086)
}

@(test)
pci_test_mechanism_2_precedes_default_bus_master_bar :: proc(t: ^testing.T) {
	p: Pci
	pci_init(&p)
	offset, claimed := pci_ide_bus_master_decode(&p, 0xC000, 1)
	testing.expect_value(t, offset, 0)
	testing.expect_value(t, claimed, true)
	pci_out(&p, 0xCF8, 1, 0xF0)
	testing.expect_value(t, pci_in(&p, 0xC000, 4), 0x1237_8086)
	_, claimed = pci_ide_bus_master_decode(&p, 0xC000, 1)
	testing.expect_value(t, claimed, false)
	pci_out(&p, 0xCF8, 1, 0)
	_, claimed = pci_ide_bus_master_decode(&p, 0xC000, 1)
	testing.expect_value(t, claimed, true)
}

@(test)
pci_test_absent_device :: proc(t: ^testing.T) {
	p: Pci
	pci_init(&p)
	pci_out(&p, 0xCF8, 4, 0x8000_2000) // dev 4: absent
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), 0xFFFFFFFF)
	pci_out(&p, 0xCF8, 4, 0x8000_0A00) // 00:01.2: absent function
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), 0xFFFFFFFF)
}
