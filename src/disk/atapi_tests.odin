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

atapi_test_be16 :: proc(data: []u8) -> u16 {
	return u16(data[0]) << 8 | u16(data[1])
}

atapi_test_consume_media_change :: proc(t: ^testing.T, a: ^Atapi) {
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
	for _ in 1 ..< 49 {
		_ = atapi_test_inw(&a)
	}
	word49 := atapi_test_inw(&a)
	testing.expect(t, word49 & 0x0100 == 0)
	testing.expect(t, word49 & 0x0200 != 0)
	for _ in 50 ..< 256 {
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

	mode: [ATAPI_PACKET_BYTES]u8
	mode[0], mode[2], mode[8] = 0x5A, 0x2A, 30
	atapi_test_packet(&a, mode, 30)
	capabilities: [28]u8
	atapi_test_read(&a, capabilities[:])
	testing.expect_value(t, capabilities[2], u8(0x70))

	mode[2], mode[8] = 0x01, 8
	atapi_test_packet(&a, mode, 8)
	fallback: [8]u8
	atapi_test_read(&a, fallback[:])
	testing.expect_value(t, atapi_test_be16(fallback[0:2]), u16(6))
}

@(test)
atapi_test_read_capacity_and_multiblock_read_10 :: proc(t: ^testing.T) {
	path := cdrom_test_iso(t)
	defer os.remove(path)
	a: Atapi
	atapi_init(&a)
	testing.expect(t, atapi_attach(&a, path))
	defer atapi_eject(&a)

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

@(test)
atapi_test_rejects_unimplemented_packet_dma :: proc(t: ^testing.T) {
	a: Atapi
	atapi_init(&a)
	atapi_test_outb(&a, 0x171, 0x01)
	atapi_test_outb(&a, 0x177, 0xA0)
	testing.expect(t, atapi_test_inb(&a, 0x177) & ATAPI_STATUS_ERR != 0)
	testing.expect(t, atapi_test_inb(&a, 0x177) & ATAPI_STATUS_DRQ == 0)
	testing.expect_value(t, atapi_test_inb(&a, 0x171), u8(ATAPI_ERROR_ABRT))
}

@(test)
atapi_test_replacing_media_reports_unit_attention_once :: proc(t: ^testing.T) {
	first := cdrom_test_iso(t)
	defer os.remove(first)
	second := cdrom_test_iso(t)
	defer os.remove(second)
	a: Atapi
	atapi_init(&a)
	testing.expect(t, atapi_attach(&a, first))
	testing.expect(t, atapi_mount(&a, second))
	defer atapi_eject(&a)
	atapi_test_consume_media_change(t, &a)
}

@(test)
atapi_test_eject_and_reinsert_reports_unit_attention_once :: proc(t: ^testing.T) {
	first := cdrom_test_iso(t)
	defer os.remove(first)
	second := cdrom_test_iso(t)
	defer os.remove(second)
	a: Atapi
	atapi_init(&a)
	testing.expect(t, atapi_attach(&a, first))
	atapi_eject(&a)
	testing.expect(t, atapi_mount(&a, second))
	defer atapi_eject(&a)
	atapi_test_consume_media_change(t, &a)
}

@(test)
atapi_test_live_first_insertion_is_immediately_ready :: proc(t: ^testing.T) {
	path := cdrom_test_iso(t)
	defer os.remove(path)
	a: Atapi
	atapi_init(&a)
	testing.expect(t, atapi_mount(&a, path))
	defer atapi_eject(&a)
	capacity: [ATAPI_PACKET_BYTES]u8
	capacity[0] = 0x25
	atapi_test_packet(&a, capacity, 8)
	response: [8]u8
	atapi_test_read(&a, response[:])
	testing.expect_value(t, atapi_test_be32(response[0:4]), u32(23))
}

@(test)
atapi_test_mode_sense_reports_pending_replacement_attention :: proc(t: ^testing.T) {
	first := cdrom_test_iso(t)
	defer os.remove(first)
	second := cdrom_test_iso(t)
	defer os.remove(second)
	a: Atapi
	atapi_init(&a)
	testing.expect(t, atapi_attach(&a, first))
	testing.expect(t, atapi_mount(&a, second))
	defer atapi_eject(&a)

	mode: [ATAPI_PACKET_BYTES]u8
	mode[0], mode[2], mode[8] = 0x5A, 0x2A, 30
	atapi_test_packet(&a, mode, 30)
	testing.expect(t, atapi_test_inb(&a, 0x177) & ATAPI_STATUS_ERR != 0)

	sense: [ATAPI_PACKET_BYTES]u8
	sense[0], sense[4] = 0x03, 18
	atapi_test_packet(&a, sense, 18)
	sense_data: [18]u8
	atapi_test_read(&a, sense_data[:])
	testing.expect_value(t, sense_data[2], u8(0x06))
	testing.expect_value(t, sense_data[12], u8(0x28))

	atapi_test_packet(&a, mode, 30)
	capabilities: [28]u8
	atapi_test_read(&a, capabilities[:])
	testing.expect_value(t, capabilities[2], u8(0x01))
}

@(test)
atapi_test_oak_capabilities_and_legacy_multisession_toc :: proc(t: ^testing.T) {
	path := cdrom_test_iso(t)
	defer os.remove(path)
	a: Atapi
	atapi_init(&a)
	testing.expect(t, atapi_attach(&a, path))
	defer atapi_eject(&a)

	subchannel: [ATAPI_PACKET_BYTES]u8
	subchannel[0], subchannel[1], subchannel[3], subchannel[8] = 0x42, 0x02, 1, 4
	atapi_test_packet(&a, subchannel, 4)
	subchannel_header: [4]u8
	atapi_test_read(&a, subchannel_header[:])
	testing.expect_value(t, subchannel_header, [4]u8{0, 0x15, 0, 0})

	mode: [ATAPI_PACKET_BYTES]u8
	mode[0], mode[2], mode[8] = 0x5A, 0x2A, 30
	atapi_test_packet(&a, mode, 30)
	capabilities: [28]u8
	atapi_test_read(&a, capabilities[:])
	testing.expect_value(t, atapi_test_be16(capabilities[0:2]), u16(26))
	testing.expect_value(t, capabilities[2], u8(0x01))
	testing.expect_value(t, capabilities[8], u8(0x2A))
	testing.expect_value(t, capabilities[9], u8(18))
	testing.expect_value(t, capabilities[14], u8(0x20))
	testing.expect_value(t, atapi_test_be16(capabilities[16:18]), u16(9173))

	toc: [ATAPI_PACKET_BYTES]u8
	toc[0], toc[1], toc[8], toc[9] = 0x43, 0x02, 12, 0x40
	atapi_test_packet(&a, toc, 12)
	multisession: [12]u8
	atapi_test_read(&a, multisession[:])
	testing.expect_value(t, atapi_test_be16(multisession[0:2]), u16(10))
	testing.expect_value(t, multisession[2], u8(1))
	testing.expect_value(t, multisession[3], u8(1))
	testing.expect_value(t, multisession[5], u8(0x14))
	testing.expect_value(t, multisession[6], u8(1))
	testing.expect_value(t, multisession[10], u8(2))
}

@(test)
atapi_test_packet_trace_is_bounded_and_dispatch_labeled :: proc(t: ^testing.T) {
	a: Atapi
	atapi_init(&a)
	for i in 0 ..< ATAPI_TRACE_HISTORY + 1 {
		packet: [ATAPI_PACKET_BYTES]u8
		packet[0], packet[1] = 0xFF, u8(i)
		atapi_test_packet(&a, packet, 0)
	}
	testing.expect_value(t, a.trace_count, u64(ATAPI_TRACE_HISTORY + 1))
	testing.expect_value(t, a.trace_hist[0].packet[1], u8(ATAPI_TRACE_HISTORY))
	testing.expect(t, a.trace_hist[0].dispatch_status & ATAPI_STATUS_ERR != 0)
}
