// SPDX-License-Identifier: GPL-3.0-only
package disk

import "core:testing"

// 1MB RAM backing for tests
Ide_Test_Ram :: struct {
	data: []u8,
}

ide_test_ram_read :: proc(ctx: rawptr, lba: u64, buf: []u8) -> bool {
	r := (^Ide_Test_Ram)(ctx)
	off := int(lba) * 512
	if off + len(buf) > len(r.data) { return false }
	copy(buf, r.data[off:off + len(buf)])
	return true
}

ide_test_ram_write :: proc(ctx: rawptr, lba: u64, buf: []u8) -> bool {
	r := (^Ide_Test_Ram)(ctx)
	off := int(lba) * 512
	if off + len(buf) > len(r.data) { return false }
	copy(r.data[off:off + len(buf)], buf)
	return true
}

ide_test_setup :: proc(ram: ^Ide_Test_Ram, ide: ^Ide) {
	ram.data = make([]u8, 1024 * 1024)
	bd := Block_Device{
		ctx          = ram,
		sector_count = u64(len(ram.data) / 512),
		read         = ide_test_ram_read,
		write        = ide_test_ram_write,
	}
	ide_init(ide, bd)
}

ide_test_outb :: proc(ide: ^Ide, port: u16, v: u8) { ide_io_write(ide, port, 1, u32(v)) }
ide_test_outw :: proc(ide: ^Ide, port: u16, v: u16) { ide_io_write(ide, port, 2, u32(v)) }
ide_test_inb :: proc(ide: ^Ide, port: u16) -> u8 { return u8(ide_io_read(ide, port, 1)) }
ide_test_inw :: proc(ide: ^Ide, port: u16) -> u16 { return u16(ide_io_read(ide, port, 2)) }

ide_test_set_lba28 :: proc(ide: ^Ide, lba: u32, count: u8) {
	ide_test_outb(ide, 0x1F2, count)
	ide_test_outb(ide, 0x1F3, u8(lba))
	ide_test_outb(ide, 0x1F4, u8(lba >> 8))
	ide_test_outb(ide, 0x1F5, u8(lba >> 16))
	ide_test_outb(ide, 0x1F6, 0xE0 | u8(lba >> 24) & 0x0F)
}

@(test)
ide_test_identify :: proc(t: ^testing.T) {
	ram: Ide_Test_Ram
	ide: Ide
	ide_test_setup(&ram, &ide)
	defer delete(ram.data)

	ide_test_outb(&ide, 0x1F6, 0xA0)
	ide_test_outb(&ide, 0x1F7, 0xEC)

	st := ide_test_inb(&ide, 0x1F7)
	testing.expect(t, st & 0x80 == 0) // BSY clear
	testing.expect(t, st & 0x08 != 0) // DRQ set

	words: [256]u16
	for i in 0 ..< 256 { words[i] = ide_test_inw(&ide, 0x1F0) }

	testing.expect_value(t, words[0], 0x0040)
	testing.expect_value(t, words[1], 16383)
	testing.expect_value(t, words[3], 16)
	testing.expect_value(t, words[6], 63)
	testing.expect_value(t, words[47], 0x8000)
	testing.expect(t, words[49] & 0x0200 != 0) // LBA supported
	sectors := u32(words[60]) | (u32(words[61]) << 16)
	testing.expect_value(t, sectors, u32(2048))
	// "RETVRN99 VDISK" with swapped bytes
	testing.expect_value(t, words[27], u16('R') << 8 | u16('E'))
	testing.expect_value(t, words[28], u16('T') << 8 | u16('V'))

	st = ide_test_inb(&ide, 0x1F7)
	testing.expect(t, st & 0x08 == 0) // DRQ clear after 256 words
}

@(test)
ide_test_pio_roundtrip :: proc(t: ^testing.T) {
	ram: Ide_Test_Ram
	ide: Ide
	ide_test_setup(&ram, &ide)
	defer delete(ram.data)

	irq_count := 0
	ide.irq_ctx = &irq_count
	ide.irq = proc(ctx: rawptr) { (^int)(ctx)^ += 1 }

	// WRITE SECTORS to LBA 3
	ide_test_set_lba28(&ide, 3, 1)
	ide_test_outb(&ide, 0x1F7, 0x30)

	st := ide_test_inb(&ide, 0x1F7)
	testing.expect(t, st & 0x80 == 0) // BSY clear
	testing.expect(t, st & 0x08 != 0) // DRQ requests data

	for i in 0 ..< 256 { ide_test_outw(&ide, 0x1F0, u16(i) ~ 0xBEEF) }

	st = ide_test_inb(&ide, 0x1F7)
	testing.expect(t, st & 0x08 == 0) // DRQ clear
	testing.expect(t, st & 0x40 != 0) // DRDY
	testing.expect(t, st & 0x01 == 0) // no error
	testing.expect(t, irq_count > 0)

	// RAM backing holds word 0 (0xBEEF) in little-endian
	testing.expect_value(t, ram.data[3 * 512], u8(0xEF))
	testing.expect_value(t, ram.data[3 * 512 + 1], u8(0xBE))

	// READ SECTORS from LBA 3
	ide_test_set_lba28(&ide, 3, 1)
	ide_test_outb(&ide, 0x1F7, 0x20)

	st = ide_test_inb(&ide, 0x1F7)
	testing.expect(t, st & 0x08 != 0) // DRQ offers data

	ok := true
	for i in 0 ..< 256 {
		if ide_test_inw(&ide, 0x1F0) != (u16(i) ~ 0xBEEF) { ok = false }
	}
	testing.expect(t, ok)

	st = ide_test_inb(&ide, 0x1F7)
	testing.expect(t, st & 0x08 == 0)
}

@(test)
ide_test_multisector_read :: proc(t: ^testing.T) {
	ram: Ide_Test_Ram
	ide: Ide
	ide_test_setup(&ram, &ide)
	defer delete(ram.data)

	ram.data[5 * 512] = 0x55
	ram.data[6 * 512] = 0x66

	ide_test_set_lba28(&ide, 5, 2)
	ide_test_outb(&ide, 0x1F7, 0x20)

	buf: [512]u16
	for i in 0 ..< 512 { buf[i] = ide_test_inw(&ide, 0x1F0) }

	testing.expect_value(t, u8(buf[0]), u8(0x55))
	testing.expect_value(t, u8(buf[256]), u8(0x66))
	st := ide_test_inb(&ide, 0x1F7)
	testing.expect(t, st & 0x08 == 0)
	testing.expect_value(t, ide_test_inb(&ide, 0x1F2), u8(0))
}

@(test)
ide_test_chs_read :: proc(t: ^testing.T) {
	ram: Ide_Test_Ram
	ide: Ide
	ide_test_setup(&ram, &ide)
	defer delete(ram.data)

	// CHS 0/1/1 with 16 heads and 63 spt = LBA 63
	ram.data[63 * 512] = 0x7A

	ide_test_outb(&ide, 0x1F2, 1)
	ide_test_outb(&ide, 0x1F3, 1)    // sector 1
	ide_test_outb(&ide, 0x1F4, 0)    // cylinder low
	ide_test_outb(&ide, 0x1F5, 0)    // cylinder high
	ide_test_outb(&ide, 0x1F6, 0xA1) // head 1, no LBA bit
	ide_test_outb(&ide, 0x1F7, 0x20)

	w := ide_test_inw(&ide, 0x1F0)
	testing.expect_value(t, u8(w), u8(0x7A))
	for _ in 1 ..< 256 { _ = ide_test_inw(&ide, 0x1F0) }
	st := ide_test_inb(&ide, 0x1F7)
	testing.expect(t, st & 0x08 == 0)
}

@(test)
ide_test_nodata_commands :: proc(t: ^testing.T) {
	ram: Ide_Test_Ram
	ide: Ide
	ide_test_setup(&ram, &ide)
	defer delete(ram.data)

	for cmd in ([]u8{0xEF, 0x40, 0xE7}) {
		ide_test_outb(&ide, 0x1F7, cmd)
		st := ide_test_inb(&ide, 0x1F7)
		testing.expect(t, st & 0x40 != 0) // DRDY
		testing.expect(t, st & 0x88 == 0) // neither BSY nor DRQ
	}
}

@(test)
ide_test_slave_not_present :: proc(t: ^testing.T) {
	ram: Ide_Test_Ram
	ide: Ide
	ide_test_setup(&ram, &ide)
	defer delete(ram.data)

	// Select the absent slave: every register reads back 0x00
	ide_test_outb(&ide, 0x1F6, 0xB0)
	testing.expect_value(t, ide_test_inb(&ide, 0x1F6), u8(0x00)) // dh readback fails
	testing.expect_value(t, ide_test_inb(&ide, 0x1F7), u8(0x00)) // status reads zero

	ide_test_outb(&ide, 0x1F2, 0x55)
	testing.expect_value(t, ide_test_inb(&ide, 0x1F2), u8(0x00))

	// Commands to the absent slave are ignored
	ide_test_outb(&ide, 0x1F7, 0xEC)
	testing.expect_value(t, ide_test_inb(&ide, 0x1F7), u8(0x00))

	// Reselect master: no leftover state, IDENTIFY still works
	ide_test_outb(&ide, 0x1F6, 0xA0)
	st := ide_test_inb(&ide, 0x1F7)
	testing.expect(t, st & 0x08 == 0) // ignored command left no DRQ

	ide_test_outb(&ide, 0x1F7, 0xEC)
	st = ide_test_inb(&ide, 0x1F7)
	testing.expect(t, st & 0x80 == 0) // BSY clear
	testing.expect(t, st & 0x08 != 0) // DRQ set
	testing.expect_value(t, ide_test_inw(&ide, 0x1F0), u16(0x0040))
}
