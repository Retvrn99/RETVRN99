// SPDX-License-Identifier: GPL-3.0-only
package disk

import "core:os"
import "core:testing"

atapi_test_outb :: proc(a: ^Atapi, port: u16, value: u8) {
	atapi_io_write(a, port, 1, u32(value))
}

atapi_test_outw :: proc(a: ^Atapi, value: u16) {
	atapi_io_write(a, 0x170, 2, u32(value))
}

atapi_test_inb :: proc(a: ^Atapi, port: u16) -> u8 {
	return u8(atapi_io_read(a, port, 1))
}

atapi_test_inw :: proc(a: ^Atapi) -> u16 {
	return u16(atapi_io_read(a, 0x170, 2))
}

atapi_test_packet :: proc(a: ^Atapi, cdb: [ATAPI_PACKET_BYTES]u8, limit: u16 = CDROM_SECTOR_SIZE) {
	atapi_test_outb(a, 0x174, u8(limit))
	atapi_test_outb(a, 0x175, u8(limit >> 8))
	atapi_test_outb(a, 0x177, 0xA0)
	for i in 0 ..< ATAPI_PACKET_BYTES / 2 {
		atapi_test_outw(a, u16(cdb[i * 2]) | u16(cdb[i * 2 + 1]) << 8)
	}
}

atapi_test_read :: proc(a: ^Atapi, out: []u8) {
	for i := 0; i < len(out); i += 2 {
		word := atapi_test_inw(a)
		out[i] = u8(word)
		if i + 1 < len(out) {
			out[i + 1] = u8(word >> 8)
		}
	}
}

atapi_test_be32 :: proc(data: []u8) -> u32 {
	return u32(data[0]) << 24 | u32(data[1]) << 16 | u32(data[2]) << 8 | u32(data[3])
}

atapi_test_ready_after_mount :: proc(t: ^testing.T, a: ^Atapi) {
	tur: [ATAPI_PACKET_BYTES]u8
	atapi_test_packet(a, tur, 0)
	testing.expect(t, atapi_test_inb(a, 0x177) & ATAPI_STATUS_ERR != 0)

	sense: [ATAPI_PACKET_BYTES]u8
	sense[0], sense[4] = 0x03, 18
	atapi_test_packet(a, sense, 18)
	response: [18]u8
	atapi_test_read(a, response[:])
	testing.expect_value(t, response[2], u8(0x06))
	testing.expect_value(t, response[12], u8(0x28))

	atapi_test_packet(a, tur, 0)
	testing.expect(t, atapi_test_inb(a, 0x177) & (ATAPI_STATUS_ERR | ATAPI_STATUS_DRQ) == 0)
}

@(test)
atapi_test_reset_signature_and_identify_packet :: proc(t: ^testing.T) {
	a: Atapi
	atapi_init(&a)
	testing.expect_value(t, atapi_test_inb(&a, 0x174), u8(0x14))
	testing.expect_value(t, atapi_test_inb(&a, 0x175), u8(0xEB))

	atapi_test_outb(&a, 0x177, 0xA1)
	testing.expect(t, atapi_test_inb(&a, 0x177) & ATAPI_STATUS_DRQ != 0)
	word0 := atapi_test_inw(&a)
	testing.expect_value(t, word0, u16(0x85C0))
	for _ in 1 ..< 256 {
		_ = atapi_test_inw(&a)
	}
	testing.expect(t, atapi_test_inb(&a, 0x177) & ATAPI_STATUS_DRQ == 0)

	atapi_test_outb(&a, 0x376, 0x06)
	testing.expect(t, atapi_test_inb(&a, 0x376) & ATAPI_STATUS_BSY != 0)
	atapi_test_outb(&a, 0x376, 0x02)
	testing.expect_value(t, atapi_test_inb(&a, 0x174), u8(0x14))
	testing.expect_value(t, atapi_test_inb(&a, 0x175), u8(0xEB))
}

@(test)
atapi_test_no_media_sense_and_inquiry :: proc(t: ^testing.T) {
	a: Atapi
	atapi_init(&a)
	tur: [ATAPI_PACKET_BYTES]u8
	atapi_test_packet(&a, tur, 0)
	testing.expect(t, atapi_test_inb(&a, 0x177) & ATAPI_STATUS_ERR != 0)
	testing.expect_value(t, atapi_test_inb(&a, 0x171), u8(0x20))

	sense: [ATAPI_PACKET_BYTES]u8
	sense[0], sense[4] = 0x03, 18
	atapi_test_packet(&a, sense, 18)
	response: [18]u8
	atapi_test_read(&a, response[:])
	testing.expect_value(t, response[0], u8(0x70))
	testing.expect_value(t, response[2], u8(0x02))
	testing.expect_value(t, response[12], u8(0x3A))

	inquiry: [ATAPI_PACKET_BYTES]u8
	inquiry[0], inquiry[4] = 0x12, 36
	atapi_test_packet(&a, inquiry, 36)
	info: [36]u8
	atapi_test_read(&a, info[:])
	testing.expect_value(t, info[0], u8(0x05))
	testing.expect(t, string(info[8:16]) == "GSW     ")
}

@(test)
atapi_test_read_capacity_and_multiblock_read_10 :: proc(t: ^testing.T) {
	path := cdrom_test_iso(t)
	defer os.remove(path)
	a: Atapi
	atapi_init(&a)
	testing.expect(t, atapi_mount(&a, path))
	defer atapi_eject(&a)
	atapi_test_ready_after_mount(t, &a)

	capacity: [ATAPI_PACKET_BYTES]u8
	capacity[0] = 0x25
	atapi_test_packet(&a, capacity, 8)
	cap: [8]u8
	atapi_test_read(&a, cap[:])
	testing.expect_value(t, atapi_test_be32(cap[0:4]), u32(23))
	testing.expect_value(t, atapi_test_be32(cap[4:8]), u32(CDROM_SECTOR_SIZE))

	read: [ATAPI_PACKET_BYTES]u8
	read[0], read[5], read[8] = 0x28, 18, 2
	atapi_test_packet(&a, read)
	first: [CDROM_SECTOR_SIZE]u8
	second: [CDROM_SECTOR_SIZE]u8
	atapi_test_read(&a, first[:])
	testing.expect_value(t, first[0], u8(18))
	testing.expect(t, atapi_test_inb(&a, 0x177) & ATAPI_STATUS_DRQ != 0)
	atapi_test_read(&a, second[:])
	testing.expect_value(t, second[0], u8(19))
	testing.expect(t, atapi_test_inb(&a, 0x177) & ATAPI_STATUS_DRQ == 0)

	write: [ATAPI_PACKET_BYTES]u8
	write[0] = 0x2A
	atapi_test_packet(&a, write)
	testing.expect(t, atapi_test_inb(&a, 0x177) & ATAPI_STATUS_ERR != 0)
	testing.expect_value(t, atapi_test_inb(&a, 0x171), u8(0x50))
}
