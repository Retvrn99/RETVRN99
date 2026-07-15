// SPDX-License-Identifier: GPL-3.0-only
package disk

import "core:testing"

BMIDE_TEST_TABLE :: u32(0x1000)
BMIDE_TEST_BUFFER :: u32(0x2_0000)

Bmide_Test_Memory :: struct {
	data:   []u8,
	reads:  int,
	writes: int,
}

Bmide_Test_Device :: struct {
	source:      []u8,
	staged:      []u8,
	committed:   []u8,
	expected:    u32,
	direction:   Bmide_Direction,
	begun:       bool,
	begins:      int,
	reads:       int,
	stages:      int,
	commits:     int,
	aborts:      int,
	fail_begin:  bool,
	fail_read:   bool,
	fail_stage:  bool,
	fail_commit: bool,
}

Bmide_Test_Invalid_Prd :: struct {
	table:      u32,
	address:    u32,
	descriptor: u32,
}

bmide_test_memory_init :: proc(memory: ^Bmide_Test_Memory, size: int) {
	memory^ = {
		data = make([]u8, size),
	}
}

bmide_test_memory_destroy :: proc(memory: ^Bmide_Test_Memory) {
	delete(memory.data)
	memory^ = {}
}

bmide_test_memory_read :: proc(ctx: rawptr, address: u64, data: []u8) -> bool {
	memory := (^Bmide_Test_Memory)(ctx)
	if address > u64(len(memory.data)) || u64(len(data)) > u64(len(memory.data)) - address {
		return false
	}
	start := int(address)
	copy(data, memory.data[start:start + len(data)])
	memory.reads += 1
	return true
}

bmide_test_memory_write :: proc(ctx: rawptr, address: u64, data: []u8) -> bool {
	memory := (^Bmide_Test_Memory)(ctx)
	if address > u64(len(memory.data)) || u64(len(data)) > u64(len(memory.data)) - address {
		return false
	}
	start := int(address)
	copy(memory.data[start:start + len(data)], data)
	memory.writes += 1
	return true
}

bmide_test_memory_adapter :: proc(memory: ^Bmide_Test_Memory) -> Bmide_Memory_Adapter {
	return {
		ctx = memory,
		size = u64(len(memory.data)),
		read = bmide_test_memory_read,
		write = bmide_test_memory_write,
	}
}

bmide_test_device_init :: proc(device: ^Bmide_Test_Device, size: int) {
	device^ = {
		source    = make([]u8, size),
		staged    = make([]u8, size),
		committed = make([]u8, size),
	}
}

bmide_test_device_destroy :: proc(device: ^Bmide_Test_Device) {
	delete(device.source)
	delete(device.staged)
	delete(device.committed)
	device^ = {}
}

bmide_test_device_reset_stats :: proc(device: ^Bmide_Test_Device) {
	device.expected = 0
	device.begun = false
	device.begins = 0
	device.reads = 0
	device.stages = 0
	device.commits = 0
	device.aborts = 0
	device.fail_begin = false
	device.fail_read = false
	device.fail_stage = false
	device.fail_commit = false
}

bmide_test_device_begin :: proc(
	ctx: rawptr,
	channel: u8,
	direction: Bmide_Direction,
	byte_count: u32,
) -> bool {
	device := (^Bmide_Test_Device)(ctx)
	_ = channel
	device.begins += 1
	device.expected = byte_count
	device.direction = direction
	if device.fail_begin || int(byte_count) > len(device.staged) {return false}
	for index in 0 ..< int(byte_count) {device.staged[index] = 0}
	device.begun = true
	return true
}

bmide_test_device_read :: proc(ctx: rawptr, channel: u8, offset: u32, data: []u8) -> bool {
	device := (^Bmide_Test_Device)(ctx)
	_ = channel
	if !device.begun ||
	   device.fail_read ||
	   u64(offset) + u64(len(data)) > u64(len(device.source)) {
		return false
	}
	copy(data, device.source[int(offset):int(offset) + len(data)])
	device.reads += 1
	return true
}

bmide_test_device_stage_write :: proc(ctx: rawptr, channel: u8, offset: u32, data: []u8) -> bool {
	device := (^Bmide_Test_Device)(ctx)
	_ = channel
	if !device.begun ||
	   device.fail_stage ||
	   u64(offset) + u64(len(data)) > u64(len(device.staged)) {
		return false
	}
	copy(device.staged[int(offset):int(offset) + len(data)], data)
	device.stages += 1
	return true
}

bmide_test_device_commit :: proc(ctx: rawptr, channel: u8) -> bool {
	device := (^Bmide_Test_Device)(ctx)
	_ = channel
	if !device.begun || device.fail_commit {return false}
	if device.direction == .Memory_To_Device {
		copy(device.committed[:int(device.expected)], device.staged[:int(device.expected)])
	}
	device.commits += 1
	device.begun = false
	return true
}

bmide_test_device_abort :: proc(ctx: rawptr, channel: u8) {
	device := (^Bmide_Test_Device)(ctx)
	_ = channel
	device.aborts += 1
	device.begun = false
}

bmide_test_device_adapter :: proc(device: ^Bmide_Test_Device) -> Bmide_Device_Adapter {
	return {
		ctx = device,
		begin = bmide_test_device_begin,
		read = bmide_test_device_read,
		stage_write = bmide_test_device_stage_write,
		commit = bmide_test_device_commit,
		abort = bmide_test_device_abort,
	}
}

bmide_test_request :: proc(
	device: ^Bmide_Test_Device,
	direction: Bmide_Direction,
	byte_count: u32,
	ignored_rate: ..u64,
) -> Bmide_Request {
	return {
		direction = direction,
		byte_count = byte_count,
		device = bmide_test_device_adapter(device),
	}
}

bmide_test_write_u32 :: proc(memory: ^Bmide_Test_Memory, address, value: u32) {
	start := int(address)
	memory.data[start] = u8(value)
	memory.data[start + 1] = u8(value >> 8)
	memory.data[start + 2] = u8(value >> 16)
	memory.data[start + 3] = u8(value >> 24)
}

bmide_test_write_prd :: proc(
	memory: ^Bmide_Test_Memory,
	table: u32,
	index: int,
	address, count: u32,
	eot: bool,
) {
	entry := table + u32(index * 8)
	bmide_test_write_u32(memory, entry, address)
	descriptor := count & 0xFFFF
	if eot {descriptor |= BMIDE_PRD_EOT}
	bmide_test_write_u32(memory, entry + 4, descriptor)
}

bmide_test_program_prd :: proc(bm: ^Bmide, channel: u8, table: u32) {
	bmide_io_write(bm, channel * 8 + 4, 4, table)
}

bmide_test_start :: proc(
	bm: ^Bmide,
	memory: Bmide_Memory_Adapter,
	device: ^Bmide_Test_Device,
	channel: u8,
	direction: Bmide_Direction,
	byte_count: u32,
	ignored_rate: ..u64,
) -> bool {
	if !bmide_submit_request(bm, channel, bmide_test_request(device, direction, byte_count)) {
		return false
	}
	command := BMIDE_COMMAND_START
	if direction == .Device_To_Memory {command |= BMIDE_COMMAND_READ_FROM_DISK}
	bmide_io_write(bm, channel * 8, 1, u32(command))
	bmide_synchronize(bm, true, memory)
	return u8(bmide_io_read(bm, channel * 8 + 2, 1)) & BMIDE_STATUS_ERROR == 0
}

bmide_test_run_until_idle :: proc(bm: ^Bmide, memory: Bmide_Memory_Adapter) -> u8 {
	events: u8
	for index in 0 ..< BMIDE_CHANNEL_COUNT {
		if bmide_interrupt_latched(bm, u8(index)) {events |= u8(1 << uint(index))}
	}
	return events
}

bmide_test_bytes_equal :: proc(left, right: []u8) -> bool {
	if len(left) != len(right) {return false}
	for index in 0 ..< len(left) {
		if left[index] != right[index] {return false}
	}
	return true
}

@(test)
bmide_test_register_banks_are_byte_decomposed :: proc(t: ^testing.T) {
	bm: Bmide
	bmide_init(&bm)
	bmide_io_write(&bm, 4, 4, 0x1234_567B)
	testing.expect_value(t, bmide_io_read(&bm, 4, 4), 0x1234_5678)
	bmide_io_write(&bm, 12, 4, 0xCAFE_BABF)
	testing.expect_value(t, bmide_io_read(&bm, 12, 4), 0xCAFE_BABC)

	bmide_io_write(&bm, 0, 4, 0x0060_0009)
	testing.expect_value(t, bmide_io_read(&bm, 0, 4), 0x0060_0009)
	bmide_io_write(&bm, 7, 2, 0x0900)
	testing.expect_value(t, bmide_io_read(&bm, 8, 1), u32(0x09))
	testing.expect_value(t, bmide_io_read(&bm, 15, 2), 0xFFFF)

	bmide_note_ide_irq(&bm, 0)
	testing.expect(t, !bmide_take_irq(&bm, 0))
	testing.expect(t, bmide_interrupt_latched(&bm, 0))
	bmide_io_write(&bm, 2, 1, 0x64)
	testing.expect_value(t, bmide_io_read(&bm, 2, 1), u32(0x60))
	testing.expect(t, !bmide_interrupt_latched(&bm, 0))
}

@(test)
bmide_test_device_to_memory_completes_one_bulk_transaction :: proc(t: ^testing.T) {
	memory: Bmide_Test_Memory
	device: Bmide_Test_Device
	bmide_test_memory_init(&memory, 2 * 1024 * 1024)
	bmide_test_device_init(&device, 1024)
	defer bmide_test_memory_destroy(&memory)
	defer bmide_test_device_destroy(&device)
	for index in 0 ..< len(device.source) {device.source[index] = u8(index * 37 + 11)}

	bmide_test_write_prd(&memory, BMIDE_TEST_TABLE, 0, BMIDE_TEST_BUFFER, 256, false)
	bmide_test_write_prd(&memory, BMIDE_TEST_TABLE, 1, BMIDE_TEST_BUFFER + 256, 768, true)
	bm: Bmide
	bmide_init(&bm)
	bmide_test_program_prd(&bm, 0, BMIDE_TEST_TABLE)
	adapter := bmide_test_memory_adapter(&memory)
	testing.expect(
		t,
		bmide_test_start(&bm, adapter, &device, 0, .Device_To_Memory, 1024, 1_024_000),
	)
	bmide_io_write(&bm, 4, 4, 0x4000)
	testing.expect_value(t, bmide_io_read(&bm, 4, 4), u32(0x4000))
	_, pending := bmide_next_deadline(&bm)
	testing.expect(t, !pending)
	testing.expect_value(t, device.reads, 1)
	testing.expect_value(t, memory.data[BMIDE_TEST_BUFFER], device.source[0])
	testing.expect_value(t, memory.data[BMIDE_TEST_BUFFER + 256], device.source[256])

	events := bmide_test_run_until_idle(&bm, adapter)
	testing.expect_value(t, events, u8(1))
	testing.expect(
		t,
		bmide_test_bytes_equal(
			memory.data[BMIDE_TEST_BUFFER:BMIDE_TEST_BUFFER + 1024],
			device.source,
		),
	)
	testing.expect_value(t, device.reads, 1)
	testing.expect_value(t, device.commits, 1)
	testing.expect_value(t, bm.transactions, u64(1))
	testing.expect_value(t, bm.prd_spans, u64(1))
	testing.expect_value(t, bm.bytes_moved, u64(1024))
	testing.expect_value(t, bm.channel_transactions[0], u64(1))
	testing.expect_value(t, bm.channel_bytes_moved[0], u64(1024))
	testing.expect_value(t, bm.channel_transactions[1], u64(0))
	testing.expect_value(t, bm.channel_bytes_moved[1], u64(0))
	testing.expect_value(t, device.aborts, 0)
	testing.expect(t, !bmide_channel_active(&bm, 0))
	testing.expect(t, bmide_interrupt_latched(&bm, 0))
	testing.expect(t, bmide_take_irq(&bm, 0))
	bmide_io_write(&bm, 2, 1, u32(BMIDE_STATUS_INTERRUPT))
	testing.expect(t, !bmide_interrupt_latched(&bm, 0))
}

@(test)
bmide_test_128k_request_coalesces_to_one_host_transaction :: proc(t: ^testing.T) {
	memory: Bmide_Test_Memory
	device: Bmide_Test_Device
	bmide_test_memory_init(&memory, 1024 * 1024)
	bmide_test_device_init(&device, 128 * 1024)
	defer bmide_test_memory_destroy(&memory)
	defer bmide_test_device_destroy(&device)
	bmide_test_write_prd(&memory, BMIDE_TEST_TABLE, 0, 0x2_0000, 65_536, false)
	bmide_test_write_prd(&memory, BMIDE_TEST_TABLE, 1, 0x3_0000, 65_536, true)
	bm: Bmide
	bmide_init(&bm)
	bmide_test_program_prd(&bm, 0, BMIDE_TEST_TABLE)
	adapter := bmide_test_memory_adapter(&memory)
	testing.expect(t, bmide_test_start(&bm, adapter, &device, 0, .Device_To_Memory, 128 * 1024, 1))
	testing.expect_value(t, bm.transactions, u64(1))
	testing.expect_value(t, bm.host_calls, u64(1))
	testing.expect_value(t, bm.prd_spans, u64(1))
	testing.expect_value(t, device.reads, 1)
	_, pending := bmide_next_deadline(&bm)
	testing.expect(t, !pending)
}

@(test)
bmide_test_amd756_preserves_prd_address_bit1_both_directions :: proc(t: ^testing.T) {
	memory: Bmide_Test_Memory
	read_device, write_device: Bmide_Test_Device
	bmide_test_memory_init(&memory, 1024 * 1024)
	bmide_test_device_init(&read_device, 512)
	bmide_test_device_init(&write_device, 512)
	defer bmide_test_memory_destroy(&memory)
	defer bmide_test_device_destroy(&read_device)
	defer bmide_test_device_destroy(&write_device)
	for index in 0 ..< 512 {read_device.source[index] = u8(index * 17 + 9)}
	memory.data[BMIDE_TEST_BUFFER] = 0xAA
	memory.data[BMIDE_TEST_BUFFER + 1] = 0xBB
	bmide_test_write_prd(&memory, 0x1000, 0, BMIDE_TEST_BUFFER + 2, 512, true)
	read_bm: Bmide
	bmide_init(&read_bm)
	bmide_test_program_prd(&read_bm, 0, 0x1000)
	adapter := bmide_test_memory_adapter(&memory)
	testing.expect(
		t,
		bmide_test_start(&read_bm, adapter, &read_device, 0, .Device_To_Memory, 512, 512_000),
	)
	_ = bmide_test_run_until_idle(&read_bm, adapter)
	testing.expect_value(t, memory.data[BMIDE_TEST_BUFFER], u8(0xAA))
	testing.expect_value(t, memory.data[BMIDE_TEST_BUFFER + 1], u8(0xBB))
	testing.expect_value(t, memory.data[BMIDE_TEST_BUFFER + 2], read_device.source[0])

	expected: [512]u8
	for index in 0 ..< 512 {expected[index] = u8(index * 23 + 4)}
	memory.data[BMIDE_TEST_BUFFER] = 0xCC
	memory.data[BMIDE_TEST_BUFFER + 1] = 0xDD
	copy(memory.data[BMIDE_TEST_BUFFER + 2:BMIDE_TEST_BUFFER + 514], expected[:])
	bmide_test_write_prd(&memory, 0x1100, 0, BMIDE_TEST_BUFFER + 2, 512, true)
	write_bm: Bmide
	bmide_init(&write_bm)
	bmide_test_program_prd(&write_bm, 0, 0x1100)
	testing.expect(
		t,
		bmide_test_start(&write_bm, adapter, &write_device, 0, .Memory_To_Device, 512, 512_000),
	)
	_ = bmide_test_run_until_idle(&write_bm, adapter)
	testing.expect(t, bmide_test_bytes_equal(write_device.committed, expected[:]))
	testing.expect_value(t, write_device.committed[0], memory.data[BMIDE_TEST_BUFFER + 2])
}

@(test)
bmide_test_accepts_full_64k_prd_table_entry_count :: proc(t: ^testing.T) {
	memory: Bmide_Test_Memory
	device: Bmide_Test_Device
	entry_count := BMIDE_MAX_PRDS
	byte_count := entry_count * 2
	bmide_test_memory_init(&memory, 1024 * 1024)
	bmide_test_device_init(&device, byte_count)
	defer bmide_test_memory_destroy(&memory)
	defer bmide_test_device_destroy(&device)
	for index in 0 ..< byte_count {device.source[index] = u8(index * 13 + 5)}

	table := u32(0)
	buffer := u32(0x2_0000)
	for index in 0 ..< entry_count {
		bmide_test_write_prd(
			&memory,
			table,
			index,
			buffer + u32(index * 2),
			2,
			index == entry_count - 1,
		)
	}
	bm: Bmide
	bmide_init(&bm)
	bmide_test_program_prd(&bm, 0, table)
	adapter := bmide_test_memory_adapter(&memory)
	testing.expect(
		t,
		bmide_test_start(
			&bm,
			adapter,
			&device,
			0,
			.Device_To_Memory,
			u32(byte_count),
			u64(byte_count) * 1000,
		),
	)
	_ = bmide_test_run_until_idle(&bm, adapter)
	testing.expect(
		t,
		bmide_test_bytes_equal(memory.data[int(buffer):int(buffer) + byte_count], device.source),
	)
	testing.expect_value(t, device.commits, 1)
}

@(test)
bmide_test_memory_to_device_commits_atomically :: proc(t: ^testing.T) {
	memory: Bmide_Test_Memory
	device: Bmide_Test_Device
	bmide_test_memory_init(&memory, 2 * 1024 * 1024)
	bmide_test_device_init(&device, 1024)
	defer bmide_test_memory_destroy(&memory)
	defer bmide_test_device_destroy(&device)
	expected: [1024]u8
	for index in 0 ..< len(expected) {expected[index] = u8(index * 19 + 7)}
	copy(memory.data[BMIDE_TEST_BUFFER:BMIDE_TEST_BUFFER + 256], expected[:256])
	copy(memory.data[BMIDE_TEST_BUFFER + 0x1000:BMIDE_TEST_BUFFER + 0x1300], expected[256:])
	bmide_test_write_prd(&memory, BMIDE_TEST_TABLE, 0, BMIDE_TEST_BUFFER, 256, false)
	bmide_test_write_prd(&memory, BMIDE_TEST_TABLE, 1, BMIDE_TEST_BUFFER + 0x1000, 768, true)

	bm: Bmide
	bmide_init(&bm)
	bmide_test_program_prd(&bm, 0, BMIDE_TEST_TABLE)
	adapter := bmide_test_memory_adapter(&memory)
	testing.expect(
		t,
		bmide_test_start(&bm, adapter, &device, 0, .Memory_To_Device, 1024, 1_024_000),
	)
	testing.expect_value(t, device.stages, 2)
	testing.expect_value(t, device.committed[0], expected[0])
	_ = bmide_test_run_until_idle(&bm, adapter)
	testing.expect_value(t, device.commits, 1)
	testing.expect(t, bmide_test_bytes_equal(device.committed, expected[:]))
}

@(test)
bmide_test_rejected_commit_aborts_transaction :: proc(t: ^testing.T) {
	memory: Bmide_Test_Memory
	device: Bmide_Test_Device
	bmide_test_memory_init(&memory, 1024 * 1024)
	bmide_test_device_init(&device, 512)
	defer bmide_test_memory_destroy(&memory)
	defer bmide_test_device_destroy(&device)
	for index in 0 ..< 512 {memory.data[int(BMIDE_TEST_BUFFER) + index] = u8(index + 1)}
	bmide_test_write_prd(&memory, BMIDE_TEST_TABLE, 0, BMIDE_TEST_BUFFER, 512, true)
	device.fail_commit = true
	bm: Bmide
	bmide_init(&bm)
	bmide_test_program_prd(&bm, 0, BMIDE_TEST_TABLE)
	adapter := bmide_test_memory_adapter(&memory)
	testing.expect(t, !bmide_test_start(&bm, adapter, &device, 0, .Memory_To_Device, 512, 512_000))
	testing.expect_value(t, bmide_test_run_until_idle(&bm, adapter), u8(1))
	testing.expect_value(t, device.commits, 0)
	testing.expect_value(t, device.aborts, 1)
	testing.expect_value(t, device.committed[0], u8(0))
	testing.expect_value(t, bm.transactions, u64(0))
	testing.expect_value(t, bm.bytes_moved, u64(0))
	testing.expect_value(t, bm.channel_transactions[0], u64(0))
	testing.expect_value(t, bm.channel_bytes_moved[0], u64(0))
	testing.expect_value(t, bm.prd_spans, u64(0))
	status := u8(bmide_io_read(&bm, 2, 1))
	testing.expect_value(t, status & (BMIDE_STATUS_ERROR | BMIDE_STATUS_INTERRUPT), u8(0x06))
}

@(test)
bmide_test_direction_mismatch_signals_error_and_irq :: proc(t: ^testing.T) {
	memory: Bmide_Test_Memory
	device: Bmide_Test_Device
	bmide_test_memory_init(&memory, 1024 * 1024)
	bmide_test_device_init(&device, 512)
	defer bmide_test_memory_destroy(&memory)
	defer bmide_test_device_destroy(&device)
	bmide_test_write_prd(&memory, BMIDE_TEST_TABLE, 0, BMIDE_TEST_BUFFER, 512, true)
	bm: Bmide
	bmide_init(&bm)
	bmide_test_program_prd(&bm, 0, BMIDE_TEST_TABLE)
	testing.expect(
		t,
		bmide_submit_request(&bm, 0, bmide_test_request(&device, .Memory_To_Device, 512, 512_000)),
	)
	bmide_io_write(&bm, 0, 1, u32(BMIDE_COMMAND_START | BMIDE_COMMAND_READ_FROM_DISK))
	bmide_synchronize(&bm, true, bmide_test_memory_adapter(&memory))
	status := u8(bmide_io_read(&bm, 2, 1))
	testing.expect_value(t, status & (BMIDE_STATUS_ERROR | BMIDE_STATUS_INTERRUPT), u8(0x06))
	testing.expect_value(t, device.aborts, 1)
	testing.expect(t, bmide_take_irq(&bm, 0))
	_, pending := bmide_next_deadline(&bm)
	testing.expect(t, !pending)
	bmide_io_write(&bm, 2, 1, 0x66)
	testing.expect_value(t, bmide_io_read(&bm, 2, 1), u32(0x60))
}

@(test)
bmide_test_invalid_prds_abort_before_data_moves :: proc(t: ^testing.T) {
	memory: Bmide_Test_Memory
	device: Bmide_Test_Device
	bmide_test_memory_init(&memory, 2 * 1024 * 1024)
	bmide_test_device_init(&device, 512)
	defer bmide_test_memory_destroy(&memory)
	defer bmide_test_device_destroy(&device)
	cases := [?]Bmide_Test_Invalid_Prd {
		{BMIDE_TEST_TABLE, BMIDE_TEST_BUFFER | 1, BMIDE_PRD_EOT | 512},
		{BMIDE_TEST_TABLE, BMIDE_TEST_BUFFER, BMIDE_PRD_EOT | 511},
		{BMIDE_TEST_TABLE, 0x2_FF00, BMIDE_PRD_EOT | 512},
		{BMIDE_TEST_TABLE, BMIDE_TEST_BUFFER, BMIDE_PRD_EOT | 0x0001_0000 | 512},
		{BMIDE_TEST_TABLE, BMIDE_TEST_BUFFER, BMIDE_PRD_EOT | 256},
		{0xFFF8, BMIDE_TEST_BUFFER, 256},
		{BMIDE_TEST_TABLE, u32(len(memory.data)), BMIDE_PRD_EOT | 512},
	}
	for invalid in cases {
		bmide_test_device_reset_stats(&device)
		bmide_test_write_u32(&memory, invalid.table, invalid.address)
		bmide_test_write_u32(&memory, invalid.table + 4, invalid.descriptor)
		bm: Bmide
		bmide_init(&bm)
		bmide_test_program_prd(&bm, 0, invalid.table)
		adapter := bmide_test_memory_adapter(&memory)
		testing.expect(
			t,
			bmide_submit_request(
				&bm,
				0,
				bmide_test_request(&device, .Device_To_Memory, 512, 512_000),
			),
		)
		bmide_io_write(&bm, 0, 1, u32(BMIDE_COMMAND_START | BMIDE_COMMAND_READ_FROM_DISK))
		bmide_synchronize(&bm, true, adapter)
		testing.expect_value(t, device.begins, 0)
		testing.expect_value(t, device.aborts, 1)
		testing.expect_value(t, memory.data[BMIDE_TEST_BUFFER], u8(0))
		testing.expect_value(
			t,
			u8(bmide_io_read(&bm, 2, 1)) & BMIDE_STATUS_ERROR,
			BMIDE_STATUS_ERROR,
		)
	}
}

@(test)
bmide_test_zero_prd_count_transfers_64k :: proc(t: ^testing.T) {
	memory: Bmide_Test_Memory
	device: Bmide_Test_Device
	bmide_test_memory_init(&memory, 256 * 1024)
	bmide_test_device_init(&device, 65_536)
	defer bmide_test_memory_destroy(&memory)
	defer bmide_test_device_destroy(&device)
	for index in 0 ..< len(device.source) {device.source[index] = u8(index * 13 + 5)}
	bmide_test_write_prd(&memory, BMIDE_TEST_TABLE, 0, 0x1_0000, 0, true)
	bm: Bmide
	bmide_init(&bm)
	bmide_test_program_prd(&bm, 0, BMIDE_TEST_TABLE)
	adapter := bmide_test_memory_adapter(&memory)
	testing.expect(
		t,
		bmide_test_start(&bm, adapter, &device, 0, .Device_To_Memory, 65_536, 65_536),
	)
	events := bmide_test_run_until_idle(&bm, adapter)
	testing.expect_value(t, events, u8(1))
	testing.expect_value(t, memory.data[0x1_0000], device.source[0])
	testing.expect_value(t, memory.data[0x1_FFFF], device.source[65_535])
	testing.expect_value(t, device.reads, 1)
}

@(test)
bmide_test_prd_table_may_cross_4k_within_64k_boundary :: proc(t: ^testing.T) {
	memory: Bmide_Test_Memory
	device: Bmide_Test_Device
	bmide_test_memory_init(&memory, 1024 * 1024)
	bmide_test_device_init(&device, 1024)
	defer bmide_test_memory_destroy(&memory)
	defer bmide_test_device_destroy(&device)
	for index in 0 ..< len(device.source) {device.source[index] = u8(index * 11 + 7)}

	table := u32(0x1FF8)
	bmide_test_write_prd(&memory, table, 0, BMIDE_TEST_BUFFER, 512, false)
	bmide_test_write_prd(&memory, table, 1, BMIDE_TEST_BUFFER + 512, 512, true)
	bm: Bmide
	bmide_init(&bm)
	bmide_test_program_prd(&bm, 0, table)
	adapter := bmide_test_memory_adapter(&memory)
	testing.expect(t, bmide_test_start(&bm, adapter, &device, 0, .Device_To_Memory, 1024))
	testing.expect(
		t,
		bmide_test_bytes_equal(
			memory.data[BMIDE_TEST_BUFFER:BMIDE_TEST_BUFFER + 1024],
			device.source,
		),
	)
	testing.expect_value(t, device.commits, 1)
	testing.expect_value(t, device.aborts, 0)
}

@(test)
bmide_test_channels_complete_independently :: proc(t: ^testing.T) {
	memory: Bmide_Test_Memory
	primary, secondary: Bmide_Test_Device
	bmide_test_memory_init(&memory, 1024 * 1024)
	bmide_test_device_init(&primary, 512)
	bmide_test_device_init(&secondary, 512)
	defer bmide_test_memory_destroy(&memory)
	defer bmide_test_device_destroy(&primary)
	defer bmide_test_device_destroy(&secondary)
	for index in 0 ..< 512 {
		primary.source[index] = u8(index + 1)
		secondary.source[index] = u8(index + 97)
	}
	bmide_test_write_prd(&memory, 0x1000, 0, 0x2_0000, 512, true)
	bmide_test_write_prd(&memory, 0x1100, 0, 0x3_0000, 512, true)
	bm: Bmide
	bmide_init(&bm)
	bmide_test_program_prd(&bm, 0, 0x1000)
	bmide_test_program_prd(&bm, 1, 0x1100)
	adapter := bmide_test_memory_adapter(&memory)
	testing.expect(t, bmide_test_start(&bm, adapter, &primary, 0, .Device_To_Memory, 512, 512_000))
	testing.expect(
		t,
		bmide_test_start(&bm, adapter, &secondary, 1, .Device_To_Memory, 512, 512_000),
	)
	_, pending := bmide_next_deadline(&bm)
	testing.expect(t, !pending)
	testing.expect_value(t, bmide_test_run_until_idle(&bm, adapter), u8(3))
	testing.expect(t, bmide_test_bytes_equal(memory.data[0x2_0000:0x2_0200], primary.source))
	testing.expect(t, bmide_test_bytes_equal(memory.data[0x3_0000:0x3_0200], secondary.source))
	testing.expect(t, bmide_take_irq(&bm, 0))
	testing.expect(t, bmide_take_irq(&bm, 1))
}

@(test)
bmide_test_stop_and_pci_disable_leave_completed_transfer_intact :: proc(t: ^testing.T) {
	memory: Bmide_Test_Memory
	device: Bmide_Test_Device
	bmide_test_memory_init(&memory, 1024 * 1024)
	bmide_test_device_init(&device, 1024)
	defer bmide_test_memory_destroy(&memory)
	defer bmide_test_device_destroy(&device)
	bmide_test_write_prd(&memory, BMIDE_TEST_TABLE, 0, BMIDE_TEST_BUFFER, 1024, true)
	adapter := bmide_test_memory_adapter(&memory)
	bm: Bmide
	bmide_init(&bm)
	bmide_test_program_prd(&bm, 0, BMIDE_TEST_TABLE)
	testing.expect(
		t,
		bmide_test_start(&bm, adapter, &device, 0, .Device_To_Memory, 1024, 1_024_000),
	)
	bmide_io_write(&bm, 0, 1, 0)
	testing.expect_value(t, device.aborts, 0)
	testing.expect_value(t, u8(bmide_io_read(&bm, 2, 1)) & BMIDE_STATUS_ERROR, u8(0))

	bmide_reset_channel(&bm, 0)
	bmide_test_device_reset_stats(&device)
	bmide_test_program_prd(&bm, 0, BMIDE_TEST_TABLE)
	testing.expect(
		t,
		bmide_test_start(&bm, adapter, &device, 0, .Device_To_Memory, 1024, 1_024_000),
	)
	bmide_synchronize(&bm, false, adapter)
	testing.expect_value(t, device.aborts, 0)
	testing.expect(t, !bmide_channel_active(&bm, 0))
}

@(test)
bmide_test_partial_final_prd_waits_for_stop :: proc(t: ^testing.T) {
	memory: Bmide_Test_Memory
	device: Bmide_Test_Device
	bmide_test_memory_init(&memory, 1024 * 1024)
	bmide_test_device_init(&device, 512)
	defer bmide_test_memory_destroy(&memory)
	defer bmide_test_device_destroy(&device)
	bmide_test_write_prd(&memory, BMIDE_TEST_TABLE, 0, BMIDE_TEST_BUFFER, 1024, true)
	bm: Bmide
	bmide_init(&bm)
	bmide_test_program_prd(&bm, 0, BMIDE_TEST_TABLE)
	adapter := bmide_test_memory_adapter(&memory)
	testing.expect(t, bmide_test_start(&bm, adapter, &device, 0, .Device_To_Memory, 512, 512_000))
	_ = bmide_test_run_until_idle(&bm, adapter)
	testing.expect(t, bmide_channel_active(&bm, 0))
	_, pending := bmide_next_deadline(&bm)
	testing.expect(t, !pending)
	bmide_io_write(&bm, 0, 1, 0)
	testing.expect(t, !bmide_channel_active(&bm, 0))
	testing.expect_value(t, u8(bmide_io_read(&bm, 2, 1)) & BMIDE_STATUS_ERROR, u8(0))
}

@(test)
bmide_test_ide_dma_commit_and_abort_drive_one_irq_level_transition :: proc(t: ^testing.T) {
	ram: Ide_Test_Ram
	ide: Ide
	ide_test_setup(&ram, &ide)
	defer delete(ram.data)
	ram.data[4 * IDE_SECTOR_SIZE] = 0x5A

	memory: Bmide_Test_Memory
	bmide_test_memory_init(&memory, 1024 * 1024)
	defer bmide_test_memory_destroy(&memory)
	bmide_test_write_prd(
		&memory,
		BMIDE_TEST_TABLE,
		0,
		BMIDE_TEST_BUFFER,
		IDE_SECTOR_SIZE,
		true,
	)
	adapter := bmide_test_memory_adapter(&memory)
	bm: Bmide
	bmide_init(&bm)
	bmide_test_program_prd(&bm, 0, BMIDE_TEST_TABLE)

	ide_test_set_lba28(&ide, 4, 1)
	ide_test_outb(&ide, 0x1F7, 0xC8)
	request, pending := ide_bmide_request(&ide)
	if !testing.expect(t, pending) {return}
	testing.expect(t, bmide_submit_request(&bm, 0, request))
	ide_bmide_mark_submitted(&ide)
	bmide_io_write(
		&bm,
		0,
		1,
		u32(BMIDE_COMMAND_START | BMIDE_COMMAND_READ_FROM_DISK),
	)
	bmide_synchronize(&bm, true, adapter)
	testing.expect_value(t, memory.data[BMIDE_TEST_BUFFER], u8(0x5A))
	testing.expect(t, ide_interrupt_pending(&ide))
	testing.expect_value(t, ram.irqs, 1)
	testing.expect_value(t, ram.irq_deasserts, 0)
	testing.expect(t, ram.irq_level)
	_ = ide_test_inb(&ide, 0x1F7)
	testing.expect_value(t, ram.irq_deasserts, 1)
	testing.expect(t, !ram.irq_level)

	bmide_reset_channel(&bm, 0)
	ide_test_set_lba28(&ide, 5, 1)
	ide_test_outb(&ide, 0x1F7, 0xC8)
	request, pending = ide_bmide_request(&ide)
	if !testing.expect(t, pending) {return}
	testing.expect(t, bmide_submit_request(&bm, 0, request))
	ide_bmide_mark_submitted(&ide)
	bmide_cancel_request(&bm, 0)
	testing.expect(t, ide_interrupt_pending(&ide))
	testing.expect_value(t, ram.irqs, 2)
	testing.expect_value(t, ram.irq_deasserts, 1)
	testing.expect(t, ram.irq_level)
	bmide_cancel_request(&bm, 0)
	testing.expect_value(t, ram.irqs, 2)
	_ = ide_test_inb(&ide, 0x1F7)
	testing.expect_value(t, ram.irq_deasserts, 2)
	testing.expect(t, !ram.irq_level)
}

@(test)
bmide_test_randomized_time_partition_is_invariant :: proc(t: ^testing.T) {
	one_memory, split_memory: Bmide_Test_Memory
	one_device, split_device: Bmide_Test_Device
	bmide_test_memory_init(&one_memory, 1024 * 1024)
	bmide_test_memory_init(&split_memory, 1024 * 1024)
	bmide_test_device_init(&one_device, 4096)
	bmide_test_device_init(&split_device, 4096)
	defer bmide_test_memory_destroy(&one_memory)
	defer bmide_test_memory_destroy(&split_memory)
	defer bmide_test_device_destroy(&one_device)
	defer bmide_test_device_destroy(&split_device)
	for index in 0 ..< 4096 {
		value := u8(index * 29 + 3)
		one_device.source[index] = value
		split_device.source[index] = value
	}
	bmide_test_write_prd(&one_memory, BMIDE_TEST_TABLE, 0, BMIDE_TEST_BUFFER, 4096, true)
	bmide_test_write_prd(&split_memory, BMIDE_TEST_TABLE, 0, BMIDE_TEST_BUFFER, 4096, true)
	one, split: Bmide
	bmide_init(&one)
	bmide_init(&split)
	bmide_test_program_prd(&one, 0, BMIDE_TEST_TABLE)
	bmide_test_program_prd(&split, 0, BMIDE_TEST_TABLE)
	one_adapter := bmide_test_memory_adapter(&one_memory)
	split_adapter := bmide_test_memory_adapter(&split_memory)
	testing.expect(
		t,
		bmide_test_start(&one, one_adapter, &one_device, 0, .Device_To_Memory, 4096, 4096),
	)
	testing.expect(
		t,
		bmide_test_start(&split, split_adapter, &split_device, 0, .Device_To_Memory, 4096, 4096),
	)
	final_tick := BMIDE_COMMAND_LATENCY_TICKS + BMIDE_MASTER_CLOCK_HZ
	_ = bmide_advance_to(&one, final_tick, one_adapter)
	seed: u64 = 0x5EED_1234
	for split.now_tick < final_tick {
		seed = seed * 6_364_136_223_846_793_005 + 1
		remaining := final_tick - split.now_tick
		step_limit := min(remaining, u64(100_000_000))
		step := 1 + seed % step_limit
		_ = bmide_advance_to(&split, split.now_tick + step, split_adapter)
	}
	testing.expect(
		t,
		bmide_test_bytes_equal(
			one_memory.data[BMIDE_TEST_BUFFER:BMIDE_TEST_BUFFER + 4096],
			split_memory.data[BMIDE_TEST_BUFFER:BMIDE_TEST_BUFFER + 4096],
		),
	)
	testing.expect_value(t, bmide_io_read(&one, 2, 1), bmide_io_read(&split, 2, 1))
	testing.expect_value(t, one_device.reads, split_device.reads)
	testing.expect_value(t, one_device.commits, split_device.commits)
}
