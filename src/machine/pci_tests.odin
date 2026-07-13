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
	// config regs accept writes (SeaBIOS piix_isa_bridge_setup)
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
	pci_out(&p, 0xCF8, 4, 0x8000_0908) // class dword: class 0x0101, legacy-only prog-if
	testing.expect_value(t, pci_in(&p, 0xCFC, 4) >> 8, 0x010100)
	pci_out(&p, 0xCF8, 4, 0x8000_0910) // BAR0 reads 0: legacy compatibility mode
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), 0)
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
	pci_out(&p, 0xCF8, 1, 0x60)
	testing.expect_value(t, pci_in(&p, 0xC000, 4), 0x1237_8086)
	pci_out(&p, 0xCF8, 1, 0)
	testing.expect_value(t, pci_in(&p, 0xC000, 4), 0xFFFF_FFFF)
}

@(test)
pci_test_mechanism_2_bus_device_and_function :: proc(t: ^testing.T) {
	p: Pci
	pci_init(&p)
	pci_out(&p, 0xCF8, 1, 0x62) // function 1
	pci_out(&p, 0xCFA, 1, 0)
	testing.expect_value(t, pci_in(&p, 0xC100, 4), 0x7010_8086)
	testing.expect_value(t, pci_in(&p, 0xC000, 4), 0xFFFF_FFFF)
	pci_out(&p, 0xCF8, 1, 0x60)
	testing.expect_value(t, pci_in(&p, 0xC300, 4), 0x0001_FFFE)
	testing.expect_value(t, pci_in(&p, 0xC200, 4), 0xFFFF_FFFF)
	pci_out(&p, 0xCFA, 1, 1)
	testing.expect_value(t, pci_in(&p, 0xC000, 4), 0xFFFF_FFFF)
}

@(test)
pci_test_mechanism_2_register_lanes :: proc(t: ^testing.T) {
	p: Pci
	pci_init(&p)
	pci_out(&p, 0xCF8, 1, 0xA0)
	testing.expect_value(t, pci_in(&p, 0xC000, 1), 0x86)
	testing.expect_value(t, pci_in(&p, 0xC001, 1), 0x80)
	testing.expect_value(t, pci_in(&p, 0xC002, 2), 0x1237)
}

@(test)
pci_test_mechanism_2_control_is_separate_from_mechanism_1 :: proc(t: ^testing.T) {
	p: Pci
	pci_init(&p)
	pci_out(&p, 0xCF8, 4, 0x8000_1800)
	pci_out(&p, 0xCF8, 1, 0x62)
	pci_out(&p, 0xCFA, 1, 7)
	testing.expect_value(t, pci_in(&p, 0xCF8, 4), 0x8000_1800)
	testing.expect_value(t, pci_in(&p, 0xCF8, 1), 0x62)
	testing.expect_value(t, pci_in(&p, 0xCFA, 1), 7)
}

@(test)
pci_test_mechanism_2_config_data_does_not_wrap :: proc(t: ^testing.T) {
	p: Pci
	pci_init(&p)
	pci_out(&p, 0xCF8, 1, 0x60)
	pci_out(&p, 0xC0FF, 2, 0xABCD)
	testing.expect_value(t, pci_in(&p, 0xC0FF, 1), 0)
	testing.expect_value(t, pci_in(&p, 0xC0FF, 2), 0xFFFF)
	testing.expect_value(t, pci_in(&p, 0xC000, 4), 0x1237_8086)
}

@(test)
pci_test_absent_device :: proc(t: ^testing.T) {
	p: Pci
	pci_init(&p)
	pci_out(&p, 0xCF8, 4, 0x8000_1000) // dev 2: absent
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), 0xFFFFFFFF)
	pci_out(&p, 0xCF8, 4, 0x8000_0A00) // 00:01.2: absent function
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), 0xFFFFFFFF)
}
