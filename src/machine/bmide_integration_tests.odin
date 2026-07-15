// SPDX-License-Identifier: GPL-3.0-only
package machine

import disk "../disk"
import hv "../hv"
import "core:log"
import "core:os"
import "core:testing"
import "core:time"

Bmide_Test_Block :: struct {
	data:     []u8,
	writes:   int,
	flushes:  int,
	last_lba: u64,
	last_len: int,
}

bmide_test_block_read :: proc(ctx: rawptr, lba: u64, data: []u8) -> bool {
	block := (^Bmide_Test_Block)(ctx)
	offset := int(lba) * disk.IDE_SECTOR_SIZE
	if offset < 0 || offset + len(data) > len(block.data) {return false}
	copy(data, block.data[offset:offset + len(data)])
	return true
}

bmide_test_block_write :: proc(ctx: rawptr, lba: u64, data: []u8) -> bool {
	block := (^Bmide_Test_Block)(ctx)
	offset := int(lba) * disk.IDE_SECTOR_SIZE
	if offset < 0 || offset + len(data) > len(block.data) {return false}
	block.writes += 1
	block.last_lba = lba
	block.last_len = len(data)
	copy(block.data[offset:offset + len(data)], data)
	return true
}

bmide_test_block_flush :: proc(ctx: rawptr) -> bool {
	block := (^Bmide_Test_Block)(ctx)
	block.flushes += 1
	return true
}

bmide_test_block_device :: proc(block: ^Bmide_Test_Block) -> disk.Block_Device {
	return {
		ctx = block,
		sector_count = u64(len(block.data) / disk.IDE_SECTOR_SIZE),
		read = bmide_test_block_read,
		write = bmide_test_block_write,
		flush = bmide_test_block_flush,
	}
}

bmide_test_machine_init :: proc(t: ^testing.T, m: ^Machine) -> bool {
	if !hv.available() {
		log.warn("WHPX not available")
		return false
	}
	testing.set_fail_timeout(t, 10 * time.Second)
	if !testing.expect(t, machine_init(m, 64 * 1024 * 1024)) {return false}
	machine_clock_set_running(m, false)
	// Match the AMD-756 firmware setup before driving the channels directly.
	bus_io_write(&m.bus, 0xCF8, 4, 0x8000_3940)
	bus_io_write(&m.bus, 0xCFC, 1, 0x03)
	bus_io_write(&m.bus, 0xCF8, 4, 0x8000_3920)
	bus_io_write(&m.bus, 0xCFC, 4, 0x0000_C001)
	bus_io_write(&m.bus, 0xCF8, 4, 0x8000_3904)
	bus_io_write(&m.bus, 0xCFC, 2, 0x0005)
	return true
}

bmide_test_io_write :: proc(m: ^Machine, port: u16, size: u8, value: u32) -> bool {
	return machine_io_write(m, port, size, value)
}

bmide_test_io_read :: proc(m: ^Machine, port: u16, size: u8) -> u32 {
	value, _ := machine_io_read(m, port, size)
	return value
}

bmide_test_put_u32 :: proc(data: []u8, offset: int, value: u32) {
	data[offset] = u8(value)
	data[offset + 1] = u8(value >> 8)
	data[offset + 2] = u8(value >> 16)
	data[offset + 3] = u8(value >> 24)
}

bmide_test_set_prd :: proc(m: ^Machine, table, buffer, count: u32) {
	bmide_test_put_u32(m.vm.ram, int(table), buffer)
	bmide_test_put_u32(m.vm.ram, int(table) + 4, u32(count) | disk.BMIDE_PRD_EOT)
}

bmide_test_set_lba28 :: proc(m: ^Machine, lba: u32, count: u8) {
	bus_io_write(&m.bus, 0x1F2, 1, u32(count))
	bus_io_write(&m.bus, 0x1F3, 1, u32(u8(lba)))
	bus_io_write(&m.bus, 0x1F4, 1, u32(u8(lba >> 8)))
	bus_io_write(&m.bus, 0x1F5, 1, u32(u8(lba >> 16)))
	bus_io_write(&m.bus, 0x1F6, 1, u32(0xE0 | u8(lba >> 24) & 0x0F))
}

bmide_test_bytes_equal :: proc(left, right: []u8) -> bool {
	if len(left) != len(right) {return false}
	for byte, index in left {
		if byte != right[index] {return false}
	}
	return true
}

@(test)
bmide_machine_test_config_ports_precede_overlapping_bar_decode :: proc(t: ^testing.T) {
	m := new(Machine)
	defer free(m)
	if !bmide_test_machine_init(t, m) {return}
	defer machine_destroy(m)

	bus_io_write(&m.bus, 0xCF8, 4, 0x8000_3920)
	bus_io_write(&m.bus, 0xCFC, 4, 0x0000_0CF1)
	testing.expect(t, bmide_test_io_write(m, 0xCF0, 1, u32(disk.BMIDE_COMMAND_READ_FROM_DISK)))
	testing.expect_value(
		t,
		bmide_test_io_read(m, 0xCF0, 1),
		u32(disk.BMIDE_COMMAND_READ_FROM_DISK),
	)

	testing.expect(t, bmide_test_io_write(m, 0xCF8, 4, 0x8000_3920))
	testing.expect_value(t, pci_in(&m.pci, 0xCF8, 4), u32(0x8000_3920))
	testing.expect_value(t, m.bmide.channels[1].command, u8(0))
	testing.expect(t, bmide_test_io_write(m, 0xCFC, 4, 0x0000_C001))
	testing.expect_value(t, pci_in(&m.pci, 0xCFC, 4), u32(0x0000_C001))
	testing.expect_value(t, m.bmide.channels[1].prd_address, u32(0))
}

@(test)
bmide_machine_test_ata_read_uses_physical_gpa_with_a20_disabled :: proc(t: ^testing.T) {
	m := new(Machine)
	defer free(m)
	if !bmide_test_machine_init(t, m) {return}
	defer machine_destroy(m)

	block := Bmide_Test_Block {
		data = make([]u8, 8 * disk.IDE_SECTOR_SIZE),
	}
	defer delete(block.data)
	for &byte, index in block.data[disk.IDE_SECTOR_SIZE:2 * disk.IDE_SECTOR_SIZE] {
		byte = u8(index) ~ 0x5A
	}
	machine_attach_disk(m, bmide_test_block_device(&block))

	table := u32(0x2000)
	buffer := u32(0x100500)
	alias := int(buffer &~ u32(0x100000))
	for &byte in m.vm.ram[alias:alias + disk.IDE_SECTOR_SIZE] {byte = 0xA5}
	for &byte in m.vm.ram[int(buffer):int(buffer) + disk.IDE_SECTOR_SIZE] {byte = 0xCC}
	m.vm.a20_enabled = false
	bmide_test_set_prd(m, table, buffer, disk.IDE_SECTOR_SIZE)
	bmide_test_set_lba28(m, 1, 1)
	bus_io_write(&m.bus, 0x1F7, 1, 0xC8)
	testing.expect(t, bmide_test_io_write(m, 0xC004, 4, table))
	testing.expect(
		t,
		bmide_test_io_write(
			m,
			0xC000,
			1,
			u32(disk.BMIDE_COMMAND_START | disk.BMIDE_COMMAND_READ_FROM_DISK),
		),
	)
	machine_advance_time_ns(m, 2_000_000)

	testing.expect(
		t,
		bmide_test_bytes_equal(
			m.vm.ram[int(buffer):int(buffer) + disk.IDE_SECTOR_SIZE],
			block.data[disk.IDE_SECTOR_SIZE:2 * disk.IDE_SECTOR_SIZE],
		),
	)
	for byte in m.vm.ram[alias:alias + disk.IDE_SECTOR_SIZE] {
		if !testing.expect_value(t, byte, u8(0xA5)) {break}
	}
	status := u8(bmide_test_io_read(m, 0xC002, 1))
	testing.expect(t, status & disk.BMIDE_STATUS_ACTIVE == 0)
	testing.expect(t, status & disk.BMIDE_STATUS_INTERRUPT != 0)
	testing.expect(t, status & disk.BMIDE_STATUS_ERROR == 0)
	testing.expect(t, m.pic.slave.irr & (u8(1) << 6) != 0)
	execution := machine_execution_counters(m)
	testing.expect_value(t, execution.primary_ide_dma_transactions, u64(1))
	testing.expect_value(t, execution.primary_ide_dma_bytes, u64(disk.IDE_SECTOR_SIZE))
}

@(test)
bmide_machine_test_ata_write_commits_one_block_transaction :: proc(t: ^testing.T) {
	m := new(Machine)
	defer free(m)
	if !bmide_test_machine_init(t, m) {return}
	defer machine_destroy(m)

	block := Bmide_Test_Block {
		data = make([]u8, 8 * disk.IDE_SECTOR_SIZE),
	}
	defer delete(block.data)
	machine_attach_disk(m, bmide_test_block_device(&block))

	table := u32(0x2100)
	buffer := u32(0x4000)
	byte_count := 2 * disk.IDE_SECTOR_SIZE
	for &byte, index in m.vm.ram[int(buffer):int(buffer) + byte_count] {
		byte = u8(index * 13 + 7)
	}
	bmide_test_set_prd(m, table, buffer, u32(byte_count))
	bmide_test_set_lba28(m, 3, 2)
	bus_io_write(&m.bus, 0x1F7, 1, 0xCA)
	testing.expect(t, bmide_test_io_write(m, 0xC004, 4, table))
	testing.expect(t, bmide_test_io_write(m, 0xC000, 1, u32(disk.BMIDE_COMMAND_START)))
	machine_advance_time_ns(m, 2_000_000)

	testing.expect_value(t, block.writes, 1)
	testing.expect_value(t, block.flushes, 0)
	testing.expect(t, m.ide.writeback_pending)
	testing.expect_value(t, block.last_lba, u64(3))
	testing.expect_value(t, block.last_len, byte_count)
	testing.expect(
		t,
		bmide_test_bytes_equal(
			block.data[3 * disk.IDE_SECTOR_SIZE:3 * disk.IDE_SECTOR_SIZE + byte_count],
			m.vm.ram[int(buffer):int(buffer) + byte_count],
		),
	)
	testing.expect(t, m.pic.slave.irr & (u8(1) << 6) != 0)
}

@(test)
bmide_machine_test_atapi_read10_dma_routes_secondary_channel :: proc(t: ^testing.T) {
	path := machine_test_iso(t)
	defer os.remove(path)
	image, read_error := os.read_entire_file(path, context.temp_allocator)
	if !testing.expect(t, read_error == nil) {return}
	sector := image[18 * disk.CDROM_SECTOR_SIZE:19 * disk.CDROM_SECTOR_SIZE]
	for &byte, index in sector {byte = u8(index * 5 + 3)}
	if !testing.expect(t, os.write_entire_file(path, image) == nil) {return}

	m := new(Machine)
	defer free(m)
	if !bmide_test_machine_init(t, m) {return}
	defer machine_destroy(m)
	if !testing.expect(t, machine_attach_cdrom(m, path)) {return}

	table := u32(0x2200)
	buffer := u32(0x120000)
	bmide_test_set_prd(m, table, buffer, disk.CDROM_SECTOR_SIZE)
	bus_io_write(&m.bus, 0x171, 1, 0x01)
	bus_io_write(&m.bus, 0x174, 1, 0x00)
	bus_io_write(&m.bus, 0x175, 1, 0x08)
	bus_io_write(&m.bus, 0x177, 1, 0xA0)
	packet := [12]u8{0x28, 0, 0, 0, 0, 18, 0, 0, 1, 0, 0, 0}
	completed, handled := bus_io_stream_write(&m.bus, 0x170, 2, packet[:])
	testing.expect(t, handled)
	testing.expect_value(t, completed, disk.ATAPI_PACKET_BYTES / 2)
	testing.expect(t, m.atapi.dma_submitted)
	testing.expect(t, bmide_test_io_write(m, 0xC00C, 4, table))
	testing.expect(
		t,
		bmide_test_io_write(
			m,
			0xC008,
			1,
			u32(disk.BMIDE_COMMAND_START | disk.BMIDE_COMMAND_READ_FROM_DISK),
		),
	)
	machine_advance_time_ns(m, 2_000_000)

	testing.expect(
		t,
		bmide_test_bytes_equal(m.vm.ram[int(buffer):int(buffer) + disk.CDROM_SECTOR_SIZE], sector),
	)
	status := u8(bmide_test_io_read(m, 0xC00A, 1))
	testing.expect(t, status & disk.BMIDE_STATUS_ACTIVE == 0)
	testing.expect(t, status & disk.BMIDE_STATUS_INTERRUPT != 0)
	testing.expect(t, status & disk.BMIDE_STATUS_ERROR == 0)
	testing.expect(t, m.pic.slave.irr & (u8(1) << 7) != 0)
	testing.expect(t, bus_io_read(&m.bus, 0x177, 1) & disk.ATAPI_STATUS_ERR == 0)
	execution := machine_execution_counters(m)
	testing.expect_value(t, execution.primary_ide_dma_transactions, u64(0))
	testing.expect_value(t, execution.primary_ide_dma_bytes, u64(0))
}
