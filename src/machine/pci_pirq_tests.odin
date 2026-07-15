// SPDX-License-Identifier: GPL-3.0-only
package machine

import "core:testing"

@(test)
pci_test_pirq_level_line_obeys_elcr :: proc(t: ^testing.T) {
	p: Pci
	pic: Pic_Pair
	pci_init(&p)
	pic_setup(&pic)
	pci_connect_pic(&p, &pic)

	testing.expect(t, pci_pirq_set_level(&p, PCI_PIRQ_B, true))
	testing.expect_value(t, pci_pirq_active_irq_mask(&p), u16(1 << 11))
	testing.expect(t, pic.slave.asserted & (1 << 3) != 0)
	vector, ok := pic_ack(&pic)
	testing.expect(t, ok)
	testing.expect_value(t, vector, u8(0x73))
	pic_out(&pic, 0xA0, 0x20)
	pic_out(&pic, 0x20, 0x20)
	testing.expect(t, !pic_has_pending(&pic))

	// The PCI wire stays high; changing ELCR to level mode must relatch it.
	pic_out(&pic, 0x4D1, 1 << 3)
	testing.expect(t, pic_has_pending(&pic))
	_, ok = pic_ack(&pic)
	testing.expect(t, ok)
	pic_out(&pic, 0xA0, 0x20)
	pic_out(&pic, 0x20, 0x20)
	testing.expect(t, pic_has_pending(&pic))
	_, ok = pic_ack(&pic)
	testing.expect(t, ok)

	testing.expect(t, pci_pirq_set_level(&p, PCI_PIRQ_B, false))
	pic_out(&pic, 0xA0, 0x20)
	pic_out(&pic, 0x20, 0x20)
	testing.expect_value(t, pci_pirq_active_irq_mask(&p), u16(0))
	testing.expect(t, pic.slave.asserted & (1 << 3) == 0)
	testing.expect(t, !pic_has_pending(&pic))
}

@(test)
pci_test_pirq_a_routes_to_irq10 :: proc(t: ^testing.T) {
	p: Pci
	pic: Pic_Pair
	pci_init(&p)
	pic_setup(&pic)
	pci_connect_pic(&p, &pic)
	pic_out(&pic, 0x4D1, 1 << 2)

	testing.expect(t, pci_pirq_set_level(&p, PCI_PIRQ_A, true))
	testing.expect(t, pic.slave.asserted & (1 << 2) != 0)
	vector, ok := pic_ack(&pic)
	testing.expect(t, ok)
	testing.expect_value(t, vector, u8(0x72))
	testing.expect(t, pci_pirq_set_level(&p, PCI_PIRQ_A, false))
	pic_out(&pic, 0xA0, 0x20)
	pic_out(&pic, 0x20, 0x20)
	testing.expect(t, pic.slave.asserted & (1 << 2) == 0)
	testing.expect(t, !pic_has_pending(&pic))
}

@(test)
pci_test_shared_static_pirqs_hold_irq_until_all_deassert :: proc(t: ^testing.T) {
	p: Pci
	pic: Pic_Pair
	pci_init(&p)
	pic_setup(&pic)
	pci_connect_pic(&p, &pic)
	pic_out(&pic, 0x4D1, 1 << 2)

	testing.expect(t, pci_pirq_set_level(&p, PCI_PIRQ_A, true))
	testing.expect(t, pci_pirq_set_level(&p, PCI_PIRQ_C, true))
	testing.expect(t, pci_pirq_set_level(&p, PCI_PIRQ_A, false))
	testing.expect_value(t, pci_pirq_active_irq_mask(&p), u16(1 << 10))
	testing.expect(t, pic.slave.asserted & (1 << 2) != 0)

	// A direct source sharing IRQ10 survives removal of the PCI source.
	pic_set_irq_level(&pic, 10, true)
	testing.expect(t, pci_pirq_set_level(&p, PCI_PIRQ_C, false))
	testing.expect_value(t, pci_pirq_active_irq_mask(&p), u16(0))
	testing.expect(t, pic.slave.asserted & (1 << 2) != 0)
	pic_set_irq_level(&pic, 10, false)
	testing.expect(t, pic.slave.asserted & (1 << 2) == 0)
}

@(test)
pci_test_held_pirq_drives_on_adapter_attach :: proc(t: ^testing.T) {
	p: Pci
	pic: Pic_Pair
	pci_init(&p)
	pic_setup(&pic)

	testing.expect(t, pci_pirq_set_level(&p, PCI_PIRQ_C, true))
	testing.expect(t, pci_pirq_is_asserted(&p, PCI_PIRQ_C))
	testing.expect_value(t, pci_pirq_active_irq_mask(&p), u16(1 << 10))
	testing.expect(t, pic.slave.asserted & (1 << 2) == 0)

	pci_connect_pic(&p, &pic)
	testing.expect(t, pic.slave.asserted & (1 << 2) != 0)
	pci_connect_pic(&p, nil)
	testing.expect(t, pic.slave.asserted & (1 << 2) == 0)
	testing.expect(t, !pci_pirq_set_level(&p, PCI_PIRQ_COUNT, true))
}

@(test)
pci_test_pirq_deassert_preserves_legacy_ide_edges :: proc(t: ^testing.T) {
	p: Pci
	pic: Pic_Pair
	pci_init(&p)
	pic_setup(&pic)
	pci_connect_pic(&p, &pic)
	pic_out(&pic, 0x4D1, 1 << 3)
	testing.expect(t, pci_pirq_set_level(&p, PCI_PIRQ_B, true))

	pic_raise(&pic, 14)
	pic_raise(&pic, 15)
	testing.expect(t, pci_pirq_set_level(&p, PCI_PIRQ_B, false))
	testing.expect_value(t, pic.slave.irr & 0xC0, u8(0xC0))
}
