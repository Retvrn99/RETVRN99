// SPDX-License-Identifier: GPL-3.0-only
package machine

import "core:testing"

pci_test_set_pirq_route :: proc(p: ^Pci, pirq, route: u8) {
	pci_out(p, 0xCF8, 4, 0x8000_0860)
	pci_out(p, 0xCFC + u16(pirq), 1, u32(route))
}

@(test)
pci_test_pirq_level_line_obeys_elcr :: proc(t: ^testing.T) {
	p: Pci
	pic: Pic_Pair
	pci_init(&p)
	pic_setup(&pic)
	pci_connect_pic(&p, &pic)
	pci_test_set_pirq_route(&p, 0, 11)

	testing.expect(t, pci_pirq_set_level(&p, 0, true))
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

	testing.expect(t, pci_pirq_set_level(&p, 0, false))
	pic_out(&pic, 0xA0, 0x20)
	pic_out(&pic, 0x20, 0x20)
	testing.expect_value(t, pci_pirq_active_irq_mask(&p), u16(0))
	testing.expect(t, pic.slave.asserted & (1 << 3) == 0)
	testing.expect(t, !pic_has_pending(&pic))
}

@(test)
pci_test_pirq_routes_master_level_line :: proc(t: ^testing.T) {
	p: Pci
	pic: Pic_Pair
	pci_init(&p)
	pic_setup(&pic)
	pci_connect_pic(&p, &pic)
	pci_test_set_pirq_route(&p, 3, 5)
	pic_out(&pic, 0x4D0, 1 << 5)

	_ = pci_pirq_set_level(&p, 3, true)
	testing.expect(t, pic.master.asserted & (1 << 5) != 0)
	vector, ok := pic_ack(&pic)
	testing.expect(t, ok)
	testing.expect_value(t, vector, u8(0x0D))
	_ = pci_pirq_set_level(&p, 3, false)
	pic_out(&pic, 0x20, 0x20)
	testing.expect(t, pic.master.asserted & (1 << 5) == 0)
	testing.expect(t, !pic_has_pending(&pic))
}

@(test)
pci_test_shared_pirqs_hold_and_reroute_atomically :: proc(t: ^testing.T) {
	p: Pci
	pic: Pic_Pair
	pci_init(&p)
	pic_setup(&pic)
	pci_connect_pic(&p, &pic)
	pci_test_set_pirq_route(&p, 0, 11)
	pci_test_set_pirq_route(&p, 1, 11)
	pic_out(&pic, 0x4D1, 1 << 3)

	testing.expect(t, pci_pirq_set_level(&p, 0, true))
	testing.expect(t, pci_pirq_set_level(&p, 1, true))
	testing.expect(t, pci_pirq_set_level(&p, 0, false))
	testing.expect_value(t, pci_pirq_active_irq_mask(&p), u16(1 << 11))
	testing.expect(t, pic.slave.asserted & (1 << 3) != 0)

	pci_test_set_pirq_route(&p, 1, 10)
	testing.expect_value(t, pci_pirq_active_irq_mask(&p), u16(1 << 10))
	testing.expect(t, pic.slave.asserted & (1 << 3) == 0)
	testing.expect(t, pic.slave.asserted & (1 << 2) != 0)

	// A direct source sharing IRQ10 survives removal of the routed PCI source.
	pic_set_irq_level(&pic, 10, true)
	pci_test_set_pirq_route(&p, 1, 0x8A)
	testing.expect_value(t, pci_pirq_active_irq_mask(&p), u16(0))
	testing.expect(t, pic.slave.asserted & (1 << 2) != 0)
	pic_set_irq_level(&pic, 10, false)
	testing.expect(t, pic.slave.asserted & (1 << 2) == 0)
}

@(test)
pci_test_held_pirq_activates_on_valid_route_and_adapter_attach :: proc(t: ^testing.T) {
	p: Pci
	pic: Pic_Pair
	pci_init(&p)
	pic_setup(&pic)

	testing.expect(t, pci_pirq_set_level(&p, 2, true))
	testing.expect(t, pci_pirq_is_asserted(&p, 2))
	testing.expect_value(t, pci_pirq_active_irq_mask(&p), u16(0))
	pci_test_set_pirq_route(&p, 2, 13)
	testing.expect_value(t, pci_pirq_active_irq_mask(&p), u16(0))
	pci_test_set_pirq_route(&p, 2, 9)
	testing.expect_value(t, pci_pirq_active_irq_mask(&p), u16(1 << 9))

	pci_connect_pic(&p, &pic)
	testing.expect(t, pic.slave.asserted & (1 << 1) != 0)
	pci_connect_pic(&p, nil)
	testing.expect(t, pic.slave.asserted & (1 << 1) == 0)
	testing.expect(t, !pci_pirq_set_level(&p, PIIX3_PIRQ_COUNT, true))
}

@(test)
pci_test_pirq_deassert_preserves_legacy_ide_edges :: proc(t: ^testing.T) {
	p: Pci
	pic: Pic_Pair
	pci_init(&p)
	pic_setup(&pic)
	pci_connect_pic(&p, &pic)
	pci_test_set_pirq_route(&p, 0, 11)
	pic_out(&pic, 0x4D1, 1 << 3)
	_ = pci_pirq_set_level(&p, 0, true)

	pic_raise(&pic, 14)
	pic_raise(&pic, 15)
	_ = pci_pirq_set_level(&p, 0, false)
	testing.expect_value(t, pic.slave.irr & 0xC0, u8(0xC0))
}
