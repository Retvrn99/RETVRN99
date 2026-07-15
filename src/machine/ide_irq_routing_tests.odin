// SPDX-License-Identifier: GPL-3.0-only
package machine

import disk "../disk"
import "core:testing"

@(private = "file")
ide_irq_routing_test_init :: proc(m: ^Machine) {
	pic_setup(&m.pic)
	pci_init(&m.pci)
	pci_connect_pic(&m.pci, &m.pic)
	disk.bmide_init(&m.bmide)
	disk.ide_init(&m.ide, {})
	m.ide.irq_ctx = m
	m.ide.irq = machine_irq14
	disk.atapi_init(&m.atapi)
	m.atapi.irq_ctx = m
	m.atapi.irq = machine_irq15
	m.pci.functions[PCI_IDE_FUNCTION_INDEX].cfg[0x04] = 1
	m.pci.functions[PCI_IDE_FUNCTION_INDEX].cfg[0x40] |=
		AMD756_IDE_PRIMARY_CHANNEL_ENABLE | AMD756_IDE_SECONDARY_CHANNEL_ENABLE
	_ = machine_sync_pci_devices(m)
}

@(private = "file")
ide_irq_routing_test_signal_primary :: proc(m: ^Machine, asserted: bool) {
	m.ide.irq_pending = asserted
	m.ide.irq_signaled = asserted
	m.ide.irq(m.ide.irq_ctx, asserted)
}

@(private = "file")
ide_irq_routing_test_signal_secondary :: proc(m: ^Machine, asserted: bool) {
	m.atapi.irq_pending = asserted
	m.atapi.irq_signaled = asserted
	m.atapi.irq(m.atapi.irq_ctx, asserted)
}

@(private = "file")
ide_irq_routing_test_ack_slave :: proc(t: ^testing.T, m: ^Machine, expected: u8) {
	vector, ok := pic_ack(&m.pic)
	testing.expect(t, ok)
	testing.expect_value(t, vector, expected)
	pic_out(&m.pic, 0xA0, 0x20)
	pic_out(&m.pic, 0x20, 0x20)
	testing.expect(t, !pic_has_pending(&m.pic))
}

@(test)
ide_irq_routing_test_compatibility_channels_drive_irq14_and_irq15 :: proc(t: ^testing.T) {
	m := new(Machine)
	defer free(m)
	ide_irq_routing_test_init(m)

	ide_irq_routing_test_signal_primary(m, true)
	ide_irq_routing_test_signal_secondary(m, true)
	testing.expect(t, m.pic.direct_asserted & (u16(1) << 14) != 0)
	testing.expect(t, m.pic.direct_asserted & (u16(1) << 15) != 0)
	testing.expect(t, !pci_pirq_is_asserted(&m.pci, PCI_AMD756_IDE_PIRQ))
	testing.expect(t, disk.bmide_interrupt_latched(&m.bmide, 0))
	testing.expect(t, disk.bmide_interrupt_latched(&m.bmide, 1))

	ide_irq_routing_test_signal_primary(m, false)
	ide_irq_routing_test_signal_secondary(m, false)
	testing.expect(t, m.pic.direct_asserted & (u16(1) << 14) == 0)
	testing.expect(t, m.pic.direct_asserted & (u16(1) << 15) == 0)
}

@(test)
ide_irq_routing_test_native_channels_share_pirqc_until_both_acknowledge :: proc(t: ^testing.T) {
	m := new(Machine)
	defer free(m)
	ide_irq_routing_test_init(m)
	m.pci.functions[PCI_IDE_FUNCTION_INDEX].cfg[0x09] =
		AMD756_IDE_PROGRAMMING_INTERFACE |
		AMD756_IDE_PRIMARY_NATIVE_MODE |
		AMD756_IDE_SECONDARY_NATIVE_MODE

	ide_irq_routing_test_signal_primary(m, true)
	ide_irq_routing_test_signal_secondary(m, true)
	testing.expect(t, pci_pirq_is_asserted(&m.pci, PCI_AMD756_IDE_PIRQ))
	testing.expect_value(t, pci_pirq_active_irq_mask(&m.pci), u16(1 << 10))
	testing.expect(t, m.pic.direct_asserted & (u16(1) << 14) == 0)
	testing.expect(t, m.pic.direct_asserted & (u16(1) << 15) == 0)

	ide_irq_routing_test_signal_primary(m, false)
	testing.expect(t, pci_pirq_is_asserted(&m.pci, PCI_AMD756_IDE_PIRQ))
	ide_irq_routing_test_signal_secondary(m, false)
	testing.expect(t, !pci_pirq_is_asserted(&m.pci, PCI_AMD756_IDE_PIRQ))
	testing.expect_value(t, pci_pirq_active_irq_mask(&m.pci), u16(0))
}

@(test)
ide_irq_routing_test_active_interrupt_follows_programming_mode :: proc(t: ^testing.T) {
	m := new(Machine)
	defer free(m)
	ide_irq_routing_test_init(m)
	m.pci.functions[PCI_IDE_FUNCTION_INDEX].cfg[0x04] = 1
	m.pci.functions[PCI_IDE_FUNCTION_INDEX].cfg[0x40] |= AMD756_IDE_PRIMARY_CHANNEL_ENABLE
	testing.expect(t, machine_sync_pci_devices(m))
	ide_irq_routing_test_signal_primary(m, true)
	testing.expect(t, m.pic.direct_asserted & (u16(1) << 14) != 0)

	m.pci.functions[PCI_IDE_FUNCTION_INDEX].cfg[0x09] |= AMD756_IDE_PRIMARY_NATIVE_MODE
	testing.expect(t, machine_sync_pci_devices(m))
	testing.expect(t, m.pic.direct_asserted & (u16(1) << 14) == 0)
	testing.expect(t, pci_pirq_is_asserted(&m.pci, PCI_AMD756_IDE_PIRQ))

	m.pci.functions[PCI_IDE_FUNCTION_INDEX].cfg[0x09] &~= AMD756_IDE_PRIMARY_NATIVE_MODE
	testing.expect(t, machine_sync_pci_devices(m))
	testing.expect(t, !pci_pirq_is_asserted(&m.pci, PCI_AMD756_IDE_PIRQ))
	testing.expect(t, m.pic.direct_asserted & (u16(1) << 14) != 0)

	ide_irq_routing_test_signal_primary(m, false)
}

@(test)
ide_irq_routing_test_iden_disable_does_not_pulse_legacy_irqs :: proc(t: ^testing.T) {
	m := new(Machine)
	defer free(m)
	ide_irq_routing_test_init(m)
	ide := &m.pci.functions[PCI_IDE_FUNCTION_INDEX]
	ide.cfg[0x04] = 1
	ide.cfg[0x40] |= AMD756_IDE_PRIMARY_CHANNEL_ENABLE | AMD756_IDE_SECONDARY_CHANNEL_ENABLE
	ide.cfg[0x09] =
		AMD756_IDE_PROGRAMMING_INTERFACE |
		AMD756_IDE_PRIMARY_NATIVE_MODE |
		AMD756_IDE_SECONDARY_NATIVE_MODE
	testing.expect(t, machine_sync_pci_devices(m))
	ide_irq_routing_test_signal_primary(m, true)
	ide_irq_routing_test_signal_secondary(m, true)
	testing.expect(t, pci_pirq_is_asserted(&m.pci, PCI_AMD756_IDE_PIRQ))

	m.pci.functions[PCI_ISA_FUNCTION_INDEX].cfg[0x48] |= AMD756_ISA_IDE_DISABLE
	testing.expect(t, machine_sync_pci_devices(m))
	testing.expect(t, !pci_pirq_is_asserted(&m.pci, PCI_AMD756_IDE_PIRQ))
	testing.expect(t, m.pic.direct_asserted & (u16(3) << 14) == 0)
	testing.expect(t, m.pic.slave.irr & 0xC0 == 0)
}

@(test)
ide_irq_routing_test_pending_legacy_irq_survives_iose_toggle_without_new_edge :: proc(
	t: ^testing.T,
) {
	m := new(Machine)
	defer free(m)
	ide_irq_routing_test_init(m)
	ide := &m.pci.functions[PCI_IDE_FUNCTION_INDEX]
	ide.cfg[0x04] |= 0x01
	ide.cfg[0x40] |= AMD756_IDE_PRIMARY_CHANNEL_ENABLE
	testing.expect(t, machine_sync_pci_devices(m))

	ide_irq_routing_test_signal_primary(m, true)
	testing.expect(t, m.pic.direct_asserted & (u16(1) << 14) != 0)
	ide_irq_routing_test_ack_slave(t, m, 0x76)

	ide.cfg[0x04] &~= 0x01
	testing.expect(t, machine_sync_pci_devices(m))
	testing.expect(t, !m.ide.io_space_enabled)
	testing.expect(t, m.pic.direct_asserted & (u16(1) << 14) != 0)
	testing.expect(t, m.pic.slave.irr & 0x40 == 0)
	testing.expect(t, !pic_has_pending(&m.pic))

	ide.cfg[0x04] |= 0x01
	testing.expect(t, machine_sync_pci_devices(m))
	testing.expect(t, m.ide.io_space_enabled)
	testing.expect(t, m.pic.direct_asserted & (u16(1) << 14) != 0)
	testing.expect(t, m.pic.slave.irr & 0x40 == 0)
	testing.expect(t, !pic_has_pending(&m.pic))

	ide_irq_routing_test_signal_primary(m, false)
	testing.expect(t, m.pic.direct_asserted & (u16(1) << 14) == 0)
	testing.expect(t, !pic_has_pending(&m.pic))
}

@(test)
ide_irq_routing_test_pending_native_irq_survives_iose_toggle_without_new_edge :: proc(
	t: ^testing.T,
) {
	m := new(Machine)
	defer free(m)
	ide_irq_routing_test_init(m)
	ide := &m.pci.functions[PCI_IDE_FUNCTION_INDEX]
	ide.cfg[0x04] |= 0x01
	ide.cfg[0x40] |= AMD756_IDE_PRIMARY_CHANNEL_ENABLE
	ide.cfg[0x09] |= AMD756_IDE_PRIMARY_NATIVE_MODE
	testing.expect(t, machine_sync_pci_devices(m))

	ide_irq_routing_test_signal_primary(m, true)
	testing.expect(t, pci_pirq_is_asserted(&m.pci, PCI_AMD756_IDE_PIRQ))
	testing.expect(t, m.pic.source_asserted[10] & (u8(1) << u8(Pic_Irq_Source.Pci_Pirq)) != 0)
	ide_irq_routing_test_ack_slave(t, m, 0x72)

	ide.cfg[0x04] &~= 0x01
	testing.expect(t, machine_sync_pci_devices(m))
	testing.expect(t, !m.ide.io_space_enabled)
	testing.expect(t, pci_pirq_is_asserted(&m.pci, PCI_AMD756_IDE_PIRQ))
	testing.expect(t, m.pic.source_asserted[10] & (u8(1) << u8(Pic_Irq_Source.Pci_Pirq)) != 0)
	testing.expect(t, m.pic.slave.irr & 0x04 == 0)
	testing.expect(t, !pic_has_pending(&m.pic))

	ide.cfg[0x04] |= 0x01
	testing.expect(t, machine_sync_pci_devices(m))
	testing.expect(t, m.ide.io_space_enabled)
	testing.expect(t, pci_pirq_is_asserted(&m.pci, PCI_AMD756_IDE_PIRQ))
	testing.expect(t, m.pic.source_asserted[10] & (u8(1) << u8(Pic_Irq_Source.Pci_Pirq)) != 0)
	testing.expect(t, m.pic.slave.irr & 0x04 == 0)
	testing.expect(t, !pic_has_pending(&m.pic))

	ide_irq_routing_test_signal_primary(m, false)
	testing.expect(t, !pci_pirq_is_asserted(&m.pci, PCI_AMD756_IDE_PIRQ))
	testing.expect(t, m.pic.source_asserted[10] & (u8(1) << u8(Pic_Irq_Source.Pci_Pirq)) == 0)
	testing.expect(t, !pic_has_pending(&m.pic))
}
