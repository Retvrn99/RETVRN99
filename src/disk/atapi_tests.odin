// SPDX-License-Identifier: GPL-3.0-only
package disk

import persona "../persona"
import "core:os"
import "core:fmt"
import "core:path/filepath"
import "core:testing"

Atapi_Test_Irq :: struct {
	asserts:   int,
	deasserts: int,
	level:     bool,
}

atapi_test_irq :: proc(ctx: rawptr, asserted: bool) {
	irq := (^Atapi_Test_Irq)(ctx)
	irq.level = asserted
	if asserted {
		irq.asserts += 1
	} else {
		irq.deasserts += 1
	}
}

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
	if deadline, pending := atapi_next_deadline(a); pending && a.data_pending {
		atapi_advance_to(a, deadline)
	}
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
	words: [256]u16
	for i in 0 ..< len(words) {words[i] = atapi_test_inw(&a)}
	testing.expect_value(t, words[0], u16(0x85C0))
	testing.expect(t, words[49] & 0x0100 != 0)
	testing.expect(t, words[49] & 0x0200 != 0)
	testing.expect_value(t, words[63], u16(0x0407))
	model_bytes: [40]u8
	for i in 0 ..< 20 {
		model_bytes[2 * i] = u8(words[27 + i] >> 8)
		model_bytes[2 * i + 1] = u8(words[27 + i])
	}
	model := "GSW DVD/CD 10X/52X"
	testing.expect(t, string(model_bytes[:len(model)]) == model)
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
	testing.expect(t, string(info[16:32]) == "GSW-DVD/CD 10/52")

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
atapi_test_mode_select_data_out_advances_phases_and_irqs :: proc(t: ^testing.T) {
	a: Atapi
	atapi_init(&a)
	irq: Atapi_Test_Irq
	a.irq_ctx = &irq
	a.irq = atapi_test_irq

	select: [ATAPI_PACKET_BYTES]u8
	select[0], select[4] = 0x15, 10
	atapi_test_packet(&a, select, 4)
	testing.expect_value(t, a.state, Atapi_State.Data_Out)
	testing.expect_value(t, a.data_out_remaining, 10)
	testing.expect_value(t, a.data_out_phase_remaining, 4)
	testing.expect_value(t, atapi_test_inb(&a, 0x174), u8(4))
	testing.expect_value(t, irq.asserts, 1)
	_ = atapi_test_inb(&a, 0x177)

	atapi_test_outw(&a, 0)
	atapi_test_outw(&a, 0)
	testing.expect_value(t, a.data_out_remaining, 6)
	testing.expect_value(t, a.data_out_phase_remaining, 4)
	testing.expect_value(t, atapi_test_inb(&a, 0x174), u8(4))
	testing.expect_value(t, irq.asserts, 2)
	_ = atapi_test_inb(&a, 0x177)

	atapi_test_outw(&a, 0)
	atapi_test_outw(&a, 0)
	testing.expect_value(t, a.data_out_remaining, 2)
	testing.expect_value(t, a.data_out_phase_remaining, 2)
	testing.expect_value(t, atapi_test_inb(&a, 0x174), u8(2))
	testing.expect_value(t, irq.asserts, 3)
	_ = atapi_test_inb(&a, 0x177)

	atapi_test_outw(&a, 0)
	testing.expect_value(t, a.state, Atapi_State.Idle)
	testing.expect_value(t, atapi_test_inb(&a, 0x177), u8(ATAPI_STATUS_DRDY))
	testing.expect_value(t, irq.asserts, 4)
}

@(test)
atapi_test_pci_decode_and_status_irq_acknowledgement :: proc(t: ^testing.T) {
	a: Atapi
	atapi_init(&a)
	irq: Atapi_Test_Irq
	a.irq_ctx = &irq
	a.irq = atapi_test_irq

	atapi_set_pci_decode(&a, false, true)
	testing.expect_value(t, atapi_io_read(&a, 0x177, 1), u32(0xFF))
	atapi_set_pci_decode(&a, true, false)
	testing.expect_value(t, atapi_io_read(&a, 0x177, 1), u32(0xFF))
	atapi_set_pci_decode(&a, true, true)
	atapi_test_outb(&a, 0x177, 0xA1)
	testing.expect(t, atapi_interrupt_pending(&a))
	testing.expect_value(t, irq.asserts, 1)
	testing.expect_value(t, irq.deasserts, 0)
	testing.expect(t, irq.level)

	atapi_set_pci_decode(&a, false, true)
	atapi_set_pci_decode(&a, false, true)
	testing.expect(t, atapi_interrupt_pending(&a))
	testing.expect_value(t, irq.deasserts, 0)
	testing.expect(t, irq.level)
	atapi_set_pci_decode(&a, true, false)
	testing.expect_value(t, irq.asserts, 1)
	atapi_set_pci_decode(&a, true, true)
	testing.expect_value(t, irq.asserts, 2)
	testing.expect(t, irq.level)

	atapi_test_outb(&a, 0x376, 0x02)
	atapi_test_outb(&a, 0x376, 0x02)
	testing.expect_value(t, irq.deasserts, 2)
	testing.expect(t, atapi_interrupt_pending(&a))
	atapi_test_outb(&a, 0x376, 0)
	atapi_test_outb(&a, 0x376, 0)
	testing.expect_value(t, irq.asserts, 3)
	testing.expect(t, irq.level)
	_ = atapi_test_inb(&a, 0x376)
	testing.expect(t, atapi_interrupt_pending(&a))
	testing.expect_value(t, irq.deasserts, 2)
	_ = atapi_test_inb(&a, 0x177)
	testing.expect(t, !atapi_interrupt_pending(&a))
	testing.expect_value(t, irq.deasserts, 3)
	testing.expect(t, !irq.level)
	_ = atapi_test_inb(&a, 0x177)
	testing.expect_value(t, irq.deasserts, 3)
}

@(test)
atapi_test_dma_abort_reasserts_after_nien_clears :: proc(t: ^testing.T) {
	a: Atapi
	atapi_init(&a)
	irq: Atapi_Test_Irq
	a.irq_ctx = &irq
	a.irq = atapi_test_irq
	a.dma_pending = true

	atapi_test_outb(&a, 0x376, 0x02)
	request, pending := atapi_bmide_request(&a)
	if !testing.expect(t, pending && request.device.abort != nil) {return}
	request.device.abort(request.device.ctx, 1)
	testing.expect(t, atapi_interrupt_pending(&a))
	testing.expect_value(t, irq.asserts, 0)
	testing.expect_value(t, irq.deasserts, 0)
	atapi_test_outb(&a, 0x376, 0)
	testing.expect_value(t, irq.asserts, 1)
	testing.expect(t, irq.level)
	testing.expect(t, atapi_interrupt_pending(&a))
	_ = atapi_test_inb(&a, 0x177)
	testing.expect(t, !atapi_interrupt_pending(&a))
	testing.expect_value(t, irq.deasserts, 1)
	testing.expect(t, !irq.level)
}

@(test)
atapi_test_dma_commit_and_software_reset_drive_irq_levels :: proc(t: ^testing.T) {
	a: Atapi
	atapi_init(&a)
	irq: Atapi_Test_Irq
	a.irq_ctx = &irq
	a.irq = atapi_test_irq
	a.dma_pending = true

	request, pending := atapi_bmide_request(&a)
	if !testing.expect(t, pending && request.device.commit != nil) {return}
	testing.expect(t, request.device.commit(request.device.ctx, 1))
	testing.expect(t, atapi_interrupt_pending(&a))
	testing.expect_value(t, irq.asserts, 1)
	testing.expect_value(t, irq.deasserts, 0)
	testing.expect(t, irq.level)

	atapi_test_outb(&a, 0x376, 0x04)
	testing.expect(t, !atapi_interrupt_pending(&a))
	testing.expect_value(t, irq.deasserts, 1)
	testing.expect(t, !irq.level)
	atapi_test_outb(&a, 0x376, 0x04)
	testing.expect_value(t, irq.deasserts, 1)
	atapi_test_outb(&a, 0x376, 0)
	testing.expect_value(t, atapi_test_inb(&a, 0x174), u8(0x14))
	testing.expect_value(t, atapi_test_inb(&a, 0x175), u8(0xEB))
	testing.expect_value(t, irq.asserts, 1)
	testing.expect_value(t, irq.deasserts, 1)
}

@(test)
atapi_test_read_cd_selects_header_and_user_data_atomically :: proc(t: ^testing.T) {
	path := cdrom_test_iso(t)
	defer os.remove(path)
	a: Atapi
	atapi_init(&a)
	testing.expect(t, atapi_attach(&a, path))
	defer atapi_eject(&a)

	read_cd: [ATAPI_PACKET_BYTES]u8
	read_cd[0], read_cd[5], read_cd[8], read_cd[9] = 0xBE, 18, 1, 0x30
	atapi_test_packet(&a, read_cd, DISC_DATA_SECTOR_SIZE + 4)
	selected: [DISC_DATA_SECTOR_SIZE + 4]u8
	atapi_test_read(&a, selected[:])
	testing.expect_value(t, selected[0], u8(0x00))
	testing.expect_value(t, selected[1], u8(0x02))
	testing.expect_value(t, selected[2], u8(0x18))
	testing.expect_value(t, selected[3], u8(0x01))
	testing.expect_value(t, selected[4], u8(18))
	testing.expect(t, atapi_test_inb(&a, 0x177) & ATAPI_STATUS_ERR == 0)

	unsupported := read_cd
	unsupported[9] = 0x50
	atapi_test_packet(&a, unsupported, DISC_DATA_SECTOR_SIZE)
	testing.expect(t, atapi_test_inb(&a, 0x177) & ATAPI_STATUS_ERR != 0)
	testing.expect_value(t, a.sense_asc, u8(0x24))
	testing.expect(t, !a.data_pending && !a.dma_pending)
	testing.expect_value(t, a.read_blocks, u32(0))
	testing.expect_value(t, a.state, Atapi_State.Idle)

	no_fields := read_cd
	no_fields[9] = 0
	atapi_test_packet(&a, no_fields, 0)
	testing.expect(t, atapi_test_inb(&a, 0x177) & (ATAPI_STATUS_ERR | ATAPI_STATUS_DRQ) == 0)
}

@(test)
atapi_test_accepts_packet_dma_feature :: proc(t: ^testing.T) {
	a: Atapi
	atapi_init(&a)
	atapi_test_outb(&a, 0x171, 0x01)
	atapi_test_outb(&a, 0x177, 0xA0)
	testing.expect(t, atapi_test_inb(&a, 0x177) & ATAPI_STATUS_ERR == 0)
	testing.expect(t, atapi_test_inb(&a, 0x177) & ATAPI_STATUS_DRQ != 0)
	testing.expect_value(t, a.state, Atapi_State.Packet_Out)
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
	testing.expect_value(t, atapi_test_be16(capabilities[16:18]), ATAPI_DVD_SPEED_KBPS)
	testing.expect_value(t, atapi_test_be16(capabilities[22:24]), ATAPI_CD_SPEED_KBPS)

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

@(test)
atapi_test_data_phase_is_host_speed_while_reporting_52x :: proc(t: ^testing.T) {
	path := cdrom_test_iso(t)
	defer os.remove(path)
	a: Atapi
	atapi_init(&a)
	testing.expect(t, atapi_attach(&a, path))
	defer atapi_eject(&a)

	read: [ATAPI_PACKET_BYTES]u8
	read[0], read[5], read[8] = 0x28, 18, 1
	atapi_test_packet(&a, read)
	testing.expect(t, !a.data_pending)
	_, pending := atapi_next_deadline(&a)
	testing.expect(t, !pending)
	testing.expect(t, a.reg_status & ATAPI_STATUS_DRQ != 0)
	testing.expect_value(t, atapi_test_inw(&a) & 0xFF, u16(18))
	testing.expect_value(t, persona.GUEST_PERSONA.cd_speed, u8(52))
}

@(test)
atapi_test_dvd_media_reports_10x_without_pacing_data :: proc(t: ^testing.T) {
	path := cdrom_test_iso(t)
	defer os.remove(path)
	a: Atapi
	atapi_init(&a)
	testing.expect(t, atapi_attach_classified(&a, path, .Dvd_Rom))
	defer atapi_eject(&a)

	read: [ATAPI_PACKET_BYTES]u8
	read[0], read[5], read[8] = 0x28, 18, 1
	atapi_test_packet(&a, read)
	_, pending := atapi_next_deadline(&a)
	testing.expect(t, !pending)
	sector: [DISC_DATA_SECTOR_SIZE]u8
	atapi_test_read(&a, sector[:])
	mode: [ATAPI_PACKET_BYTES]u8
	mode[0], mode[2], mode[8] = 0x5A, 0x2A, 30
	atapi_test_packet(&a, mode, 30)
	capabilities: [28]u8
	atapi_test_read(&a, capabilities[:])
	testing.expect_value(t, atapi_test_be16(capabilities[16:18]), ATAPI_DVD_SPEED_KBPS)
	testing.expect_value(t, atapi_test_be16(capabilities[22:24]), ATAPI_DVD_SPEED_KBPS)
}

@(test)
atapi_test_dvd_reports_mmc_profile_and_physical_structure :: proc(t: ^testing.T) {
	path := cdrom_test_iso(t)
	defer os.remove(path)
	a: Atapi
	atapi_init(&a)
	testing.expect(t, atapi_attach_classified(&a, path, .Dvd_Rom))
	defer atapi_eject(&a)

	configuration: [ATAPI_PACKET_BYTES]u8
	configuration[0], configuration[8] = 0x46, 64
	atapi_test_packet(&a, configuration, 64)
	reply: [64]u8
	atapi_test_read(&a, reply[:])
	testing.expect_value(t, atapi_test_be32(reply[0:4]), u32(60))
	testing.expect_value(t, atapi_test_be16(reply[6:8]), u16(0x0010))
	testing.expect_value(t, atapi_test_be16(reply[8:10]), u16(0x0000))
	testing.expect_value(t, reply[10] & 1, u8(1))
	found_dvd := false
	for offset := 8; offset + 4 <= len(reply); {
		code := atapi_test_be16(reply[offset:offset + 2])
		length := int(reply[offset + 3])
		if code == 0x001F {
			found_dvd = true
			testing.expect_value(t, reply[offset + 2] & 1, u8(1))
		}
		offset += 4 + length
	}
	testing.expect(t, found_dvd)

	structure: [ATAPI_PACKET_BYTES]u8
	structure[0], structure[7], structure[9] = 0xAD, 0, 20
	atapi_test_packet(&a, structure, 20)
	physical: [20]u8
	atapi_test_read(&a, physical[:])
	testing.expect_value(t, atapi_test_be16(physical[0:2]), u16(18))
	testing.expect_value(t, physical[4], u8(0x01))
	testing.expect(t, physical[12] != 0 || physical[13] != 0 || physical[14] != 0)
}

@(test)
atapi_test_dvd_dma_request_uses_10x_data_rate :: proc(t: ^testing.T) {
	path := cdrom_test_iso(t)
	defer os.remove(path)
	a: Atapi
	atapi_init(&a)
	testing.expect(t, atapi_attach_classified(&a, path, .Dvd_Rom))
	defer atapi_eject(&a)
	atapi_test_outb(&a, 0x171, 1)

	read: [ATAPI_PACKET_BYTES]u8
	read[0], read[5], read[8] = 0x28, 18, 1
	atapi_test_packet(&a, read)
	request, pending := atapi_bmide_request(&a)
	testing.expect(t, pending)
	testing.expect_value(t, persona.GUEST_PERSONA.dvd_speed, u8(10))
}

Atapi_Test_Cdda_Sink :: struct {
	frames: u64,
	first: u8,
	last: u8,
}

atapi_test_cdda_frame :: proc(ctx: rawptr, pcm: []u8) {
	sink := (^Atapi_Test_Cdda_Sink)(ctx)
	if sink.frames == 0 {sink.first = pcm[0]}
	sink.last = pcm[len(pcm) - 1]
	sink.frames += 1
}

@(test)
atapi_test_mixed_media_toc_raw_read_and_cdda :: proc(t: ^testing.T) {
	bin_path := disc_image_test_path("atapi mixed.bin")
	cue_path := disc_image_test_path("atapi mixed.cue")
	defer os.remove(bin_path)
	defer os.remove(cue_path)
	bin := make([]u8, 2 * DISC_DATA_SECTOR_SIZE + 2 * DISC_RAW_SECTOR_SIZE, context.temp_allocator)
	bin[DISC_DATA_SECTOR_SIZE] = 0x41
	audio_offset := 2 * DISC_DATA_SECTOR_SIZE
	bin[audio_offset] = 0x51
	bin[len(bin) - 1] = 0x52
	testing.expect(t, os.write_entire_file(bin_path, bin) == nil)
	cue := fmt.tprintf(
		"FILE \"%s\" BINARY\nTRACK 01 MODE1/2048\nINDEX 01 00:00:00\nTRACK 02 AUDIO\nINDEX 01 00:00:02\n",
		filepath.base(bin_path),
	)
	testing.expect(t, os.write_entire_file(cue_path, transmute([]u8)cue) == nil)

	a: Atapi
	atapi_init(&a)
	testing.expect(t, atapi_attach(&a, cue_path))
	defer atapi_eject(&a)

	toc: [ATAPI_PACKET_BYTES]u8
	toc[0], toc[8] = 0x43, 28
	atapi_test_packet(&a, toc, 28)
	toc_data: [28]u8
	atapi_test_read(&a, toc_data[:])
	testing.expect_value(t, toc_data[2], u8(1))
	testing.expect_value(t, toc_data[3], u8(2))
	testing.expect_value(t, toc_data[6], u8(1))
	testing.expect_value(t, toc_data[14], u8(2))
	testing.expect_value(t, toc_data[22], u8(0xAA))

	read_cd: [ATAPI_PACKET_BYTES]u8
	read_cd[0], read_cd[5], read_cd[8], read_cd[9] = 0xBE, 1, 1, 0xF8
	atapi_test_packet(&a, read_cd, DISC_RAW_SECTOR_SIZE)
	raw: [DISC_RAW_SECTOR_SIZE]u8
	atapi_test_read(&a, raw[:])
	testing.expect_value(t, raw[0], u8(0))
	testing.expect_value(t, raw[1], u8(0xFF))
	testing.expect_value(t, raw[16], u8(0x41))

	sink: Atapi_Test_Cdda_Sink
	atapi_set_cdda_output(&a, &sink, atapi_test_cdda_frame)
	generation_before_play := atapi_cdda_generation(&a)
	play: [ATAPI_PACKET_BYTES]u8
	play[0], play[5], play[8] = 0x45, 2, 2
	atapi_test_packet(&a, play, 0)
	testing.expect_value(t, a.cdda_state, Atapi_Cdda_State.Playing)
	testing.expect(t, atapi_cdda_generation(&a) > generation_before_play)
	playing_generation := atapi_cdda_generation(&a)
	deadline, pending := atapi_next_deadline(&a)
	testing.expect(t, pending)
	atapi_advance_to(&a, deadline + ATAPI_CDDA_FRAME_TICKS)
	testing.expect_value(t, sink.frames, u64(2))
	testing.expect_value(t, sink.first, u8(0x51))
	testing.expect_value(t, sink.last, u8(0x52))
	testing.expect_value(t, a.cdda_state, Atapi_Cdda_State.Complete)
	testing.expect(t, atapi_cdda_generation(&a) > playing_generation)
}
