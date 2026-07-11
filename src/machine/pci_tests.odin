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
	pci_out(&p, 0xCF8, 4, 0x8000_0908) // class dword: class 0x0101, prog-if 0x80
	testing.expect_value(t, pci_in(&p, 0xCFC, 4) >> 8, 0x010180)
	pci_out(&p, 0xCF8, 4, 0x8000_0910) // BAR0 reads 0: legacy compatibility mode
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), 0)
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
