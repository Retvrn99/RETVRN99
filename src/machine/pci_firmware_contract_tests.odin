// SPDX-License-Identifier: GPL-3.0-only
package machine

import "core:testing"

pci_firmware_read_u16 :: proc(data: []u8, offset: int) -> u16 {
	return u16(data[offset]) | u16(data[offset + 1]) << 8
}

pci_firmware_read_u32 :: proc(data: []u8, offset: int) -> u32 {
	return u32(data[offset]) |
	       u32(data[offset + 1]) << 8 |
	       u32(data[offset + 2]) << 16 |
	       u32(data[offset + 3]) << 24
}

pci_firmware_find_pir_table :: proc(ram: []u8) -> (offset, size: int, found: bool) {
	limit := min(len(ram), 0x10_0000)
	if limit < 32 {return 0, 0, false}
	for candidate in 0 ..< limit - 31 {
		if ram[candidate] != '$' ||
		   ram[candidate + 1] != 'P' ||
		   ram[candidate + 2] != 'I' ||
		   ram[candidate + 3] != 'R' {
			continue
		}
		if pci_firmware_read_u16(ram, candidate + 4) != 0x0100 {continue}
		table_size := int(pci_firmware_read_u16(ram, candidate + 6))
		if table_size < 48 || (table_size - 32) % 16 != 0 || candidate + table_size > limit {
			continue
		}
		checksum: u32
		for byte in ram[candidate:candidate + table_size] {checksum += u32(byte)}
		if checksum & 0xFF != 0 {continue}
		return candidate, table_size, true
	}
	return 0, 0, false
}

pci_firmware_validate_pir_contract :: proc(t: ^testing.T, ram: []u8) -> bool {
	offset, size, found := pci_firmware_find_pir_table(ram)
	if !testing.expect(t, found) {return false}
	testing.expect_value(t, size, 80)
	testing.expect_value(t, ram[offset + 8], u8(0))
	testing.expect_value(t, ram[offset + 9], u8(7 << 3))
	testing.expect_value(t, pci_firmware_read_u16(ram, offset + 10), u16(0x0C00))
	testing.expect_value(t, pci_firmware_read_u32(ram, offset + 12), u32(0))

	devices := [3]u8{2, 3, 7}
	for device in devices {
		slot_offset := -1
		for entry := offset + 32; entry < offset + size; entry += 16 {
			if ram[entry] == 0 && ram[entry + 1] == device << 3 {
				slot_offset = entry
				break
			}
		}
		if !testing.expect(t, slot_offset >= 0) {return false}
		for pin_index in 0 ..< 4 {
			link_offset := slot_offset + 2 + pin_index * 3
			if pin_index > 0 {
				testing.expect_value(t, ram[link_offset], u8(0))
				testing.expect_value(t, pci_firmware_read_u16(ram, link_offset + 1), u16(0))
				continue
			}
			pin := u8(pin_index + 1)
			pirq, valid := pci_slot_pirq(device, pin)
			if !testing.expect(t, valid) {return false}
			link, link_valid := pci_pirq_link(pirq)
			if !testing.expect(t, link_valid) {return false}
			bitmap, bitmap_valid := pci_pirq_irq_bitmap(pirq)
			if !testing.expect(t, bitmap_valid) {return false}
			testing.expect_value(t, ram[link_offset], link)
			testing.expect_value(t, pci_firmware_read_u16(ram, link_offset + 1), bitmap)
		}
	}
	ide_pirq, ide_pirq_valid := pci_slot_pirq(7, 1)
	testing.expect(t, ide_pirq_valid)
	testing.expect_value(t, ide_pirq, PCI_AMD756_IDE_PIRQ)
	sound_pirq, sound_pirq_valid := pci_slot_pirq(3, 1)
	testing.expect(t, sound_pirq_valid)
	testing.expect_value(t, sound_pirq, PCI_GSW_SOUND_PIRQ)
	return true
}
