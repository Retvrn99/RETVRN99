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
	// PAM0 = reg 0x59 → dword 0x58, offset 1 (puerto 0xCFD)
	pci_out(&p, 0xCF8, 4, 0x8000_0058)
	pci_out(&p, 0xCFD, 1, 0x30)
	testing.expect_value(t, pci_in(&p, 0xCFD, 1), 0x30)
}

@(test)
pci_test_absent_device :: proc(t: ^testing.T) {
	p: Pci
	pci_init(&p)
	pci_out(&p, 0xCF8, 4, 0x8000_8000) // dev 1: no existe
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), 0xFFFFFFFF)
}
