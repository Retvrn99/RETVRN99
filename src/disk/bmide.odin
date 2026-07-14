// SPDX-License-Identifier: GPL-3.0-only
package disk

// PIIX bus-master IDE algorithms adapted from IzarraVM commit
// d930de57acccbc6a70cda8cc5a603173bf23cd1c.

BMIDE_MASTER_CLOCK_HZ :: u64(6_600_000_000)
BMIDE_COMMAND_LATENCY_TICKS :: BMIDE_MASTER_CLOCK_HZ / 10_000
BMIDE_CHANNEL_COUNT :: 2
BMIDE_IO_SIZE :: 16
BMIDE_MAX_PRDS :: 512
BMIDE_DMA_UNIT_BYTES :: 512

BMIDE_COMMAND_START :: u8(0x01)
BMIDE_COMMAND_READ_FROM_DISK :: u8(0x08)
BMIDE_STATUS_ACTIVE :: u8(0x01)
BMIDE_STATUS_ERROR :: u8(0x02)
BMIDE_STATUS_INTERRUPT :: u8(0x04)
BMIDE_STATUS_DRIVE0_DMA :: u8(0x20)
BMIDE_STATUS_DRIVE1_DMA :: u8(0x40)
BMIDE_PRD_EOT :: u32(0x8000_0000)
BMIDE_PRD_RESERVED :: u32(0x7FFF_0000)

Bmide_Direction :: enum u8 {
	Device_To_Memory,
	Memory_To_Device,
}

Bmide_Memory_Adapter :: struct {
	ctx:   rawptr,
	size:  u64,
	read:  proc(ctx: rawptr, address: u64, data: []u8) -> bool,
	write: proc(ctx: rawptr, address: u64, data: []u8) -> bool,
}

Bmide_Device_Adapter :: struct {
	ctx:         rawptr,
	begin:       proc(
		ctx: rawptr,
		channel: u8,
		direction: Bmide_Direction,
		byte_count: u32,
	) -> bool,
	read:        proc(ctx: rawptr, channel: u8, offset: u32, data: []u8) -> bool,
	stage_write: proc(ctx: rawptr, channel: u8, offset: u32, data: []u8) -> bool,
	commit:      proc(ctx: rawptr, channel: u8) -> bool,
	abort:       proc(ctx: rawptr, channel: u8),
}

Bmide_Request :: struct {
	direction:        Bmide_Direction,
	byte_count:       u32,
	bytes_per_second: u64,
	device:           Bmide_Device_Adapter,
}

Bmide_Prd_Span :: struct {
	address: u32,
	length:  u32,
}

Bmide_Transfer :: struct {
	active:        bool,
	direction:     Bmide_Direction,
	spans:         [BMIDE_MAX_PRDS]Bmide_Prd_Span,
	span_count:    int,
	span_index:    int,
	span_offset:   u32,
	completed:     u32,
	byte_count:    u32,
	bytes_per_sec: u64,
	start_tick:    u64,
	next_tick:     u64,
	retires_eot:   bool,
}

Bmide_Channel :: struct {
	command:                   u8,
	status:                    u8,
	prd_address:               u32,
	request:                   Bmide_Request,
	request_pending:           bool,
	transfer:                  Bmide_Transfer,
	completion_waits_for_stop: bool,
	irq_signal:                bool,
	scratch:                   [BMIDE_DMA_UNIT_BYTES]u8,
}

Bmide :: struct {
	now_tick: u64,
	channels: [BMIDE_CHANNEL_COUNT]Bmide_Channel,
}

bmide_init :: proc(bm: ^Bmide) {
	bm^ = {}
}

@(private = "file")
bmide_size_mask :: proc(size: u8) -> u32 {
	switch size {
	case 1:
		return 0x0000_00FF
	case 2:
		return 0x0000_FFFF
	case 4:
		return 0xFFFF_FFFF
	}
	return 0xFFFF_FFFF
}

@(private = "file")
bmide_io_access_valid :: proc(offset: u8, size: u8) -> bool {
	if size != 1 && size != 2 && size != 4 {return false}
	return u16(offset) + u16(size) <= BMIDE_IO_SIZE
}

@(private = "file")
bmide_channel_for_offset :: proc(
	bm: ^Bmide,
	offset: u8,
) -> (
	channel: ^Bmide_Channel,
	register: u8,
) {
	index := int(offset >> 3)
	return &bm.channels[index], offset & 7
}

@(private = "file")
bmide_signal_interrupt :: proc(channel: ^Bmide_Channel) {
	channel.status |= BMIDE_STATUS_INTERRUPT
	channel.irq_signal = true
}

@(private = "file")
bmide_abort_adapter :: proc(channel: ^Bmide_Channel, channel_index: u8) {
	if channel.request_pending && channel.request.device.abort != nil {
		channel.request.device.abort(channel.request.device.ctx, channel_index)
	}
}

@(private = "file")
bmide_fail_channel :: proc(channel: ^Bmide_Channel, channel_index: u8) {
	bmide_abort_adapter(channel, channel_index)
	channel.request = {}
	channel.request_pending = false
	channel.transfer = {}
	channel.completion_waits_for_stop = false
	channel.status &= ~BMIDE_STATUS_ACTIVE
	channel.status |= BMIDE_STATUS_ERROR
	bmide_signal_interrupt(channel)
}

@(private = "file")
bmide_read_byte :: proc(bm: ^Bmide, offset: u8) -> u8 {
	channel, register := bmide_channel_for_offset(bm, offset)
	switch register {
	case 0:
		return channel.command
	case 2:
		return channel.status
	case 4 ..= 7:
		return u8(channel.prd_address >> (uint(register - 4) * 8))
	}
	return 0
}

@(private = "file")
bmide_write_command :: proc(channel: ^Bmide_Channel, channel_index, value: u8) {
	old := channel.command
	channel.command = value & (BMIDE_COMMAND_START | BMIDE_COMMAND_READ_FROM_DISK)
	stopped := old & BMIDE_COMMAND_START != 0 && channel.command & BMIDE_COMMAND_START == 0
	direction_changed := (old ~ channel.command) & BMIDE_COMMAND_READ_FROM_DISK != 0
	if stopped && channel.completion_waits_for_stop {
		channel.status &= ~BMIDE_STATUS_ACTIVE
		channel.completion_waits_for_stop = false
		return
	}
	if stopped && (channel.transfer.active || channel.request_pending) ||
	   direction_changed && channel.transfer.active {
		bmide_fail_channel(channel, channel_index)
	}
}

@(private = "file")
bmide_write_status :: proc(channel: ^Bmide_Channel, value: u8) {
	channel.status =
		(channel.status & ~(BMIDE_STATUS_DRIVE0_DMA | BMIDE_STATUS_DRIVE1_DMA)) |
		(value & (BMIDE_STATUS_DRIVE0_DMA | BMIDE_STATUS_DRIVE1_DMA))
	channel.status &= ~(value & (BMIDE_STATUS_ERROR | BMIDE_STATUS_INTERRUPT))
	if value & BMIDE_STATUS_INTERRUPT != 0 {channel.irq_signal = false}
}

@(private = "file")
bmide_write_byte :: proc(bm: ^Bmide, offset, value: u8) {
	channel, register := bmide_channel_for_offset(bm, offset)
	channel_index := offset >> 3
	switch register {
	case 0:
		bmide_write_command(channel, channel_index, value)
	case 2:
		bmide_write_status(channel, value)
	case 4 ..= 7:
		if channel.status & BMIDE_STATUS_ACTIVE != 0 {return}
		shift := uint(register - 4) * 8
		channel.prd_address = (channel.prd_address & ~(u32(0xFF) << shift)) | (u32(value) << shift)
		channel.prd_address &= ~u32(3)
	}
}

bmide_io_read :: proc(bm: ^Bmide, offset, size: u8) -> u32 {
	if !bmide_io_access_valid(offset, size) {return bmide_size_mask(size)}
	value: u32
	for index in 0 ..< int(size) {
		value |= u32(bmide_read_byte(bm, offset + u8(index))) << (uint(index) * 8)
	}
	return value
}

bmide_io_write :: proc(bm: ^Bmide, offset, size: u8, value: u32) {
	if !bmide_io_access_valid(offset, size) {return}
	for index in 0 ..< int(size) {
		bmide_write_byte(bm, offset + u8(index), u8(value >> (uint(index) * 8)))
	}
}

bmide_submit_request :: proc(bm: ^Bmide, channel_index: u8, request: Bmide_Request) -> bool {
	if channel_index >= BMIDE_CHANNEL_COUNT ||
	   request.byte_count == 0 ||
	   request.bytes_per_second == 0 {
		return false
	}
	channel := &bm.channels[channel_index]
	if channel.request_pending || channel.transfer.active || channel.completion_waits_for_stop {
		return false
	}
	channel.request = request
	channel.request_pending = true
	return true
}

bmide_cancel_request :: proc(bm: ^Bmide, channel_index: u8) {
	if channel_index >= BMIDE_CHANNEL_COUNT {return}
	channel := &bm.channels[channel_index]
	bmide_abort_adapter(channel, channel_index)
	channel.request = {}
	channel.request_pending = false
	channel.transfer = {}
	channel.completion_waits_for_stop = false
	channel.status &= ~BMIDE_STATUS_ACTIVE
}

@(private = "file")
bmide_memory_range_valid :: proc(memory: Bmide_Memory_Adapter, address, length: u64) -> bool {
	return address <= memory.size && length <= memory.size - address
}

@(private = "file")
bmide_memory_read :: proc(memory: Bmide_Memory_Adapter, address: u64, data: []u8) -> bool {
	return(
		memory.read != nil &&
		bmide_memory_range_valid(memory, address, u64(len(data))) &&
		memory.read(memory.ctx, address, data) \
	)
}

@(private = "file")
bmide_memory_write :: proc(memory: Bmide_Memory_Adapter, address: u64, data: []u8) -> bool {
	return(
		memory.write != nil &&
		bmide_memory_range_valid(memory, address, u64(len(data))) &&
		memory.write(memory.ctx, address, data) \
	)
}

@(private = "file")
bmide_memory_read_u32 :: proc(
	memory: Bmide_Memory_Adapter,
	address: u64,
) -> (
	value: u32,
	ok: bool,
) {
	bytes: [4]u8
	if !bmide_memory_read(memory, address, bytes[:]) {return 0, false}
	return u32(bytes[0]) | u32(bytes[1]) << 8 | u32(bytes[2]) << 16 | u32(bytes[3]) << 24, true
}

@(private = "file")
bmide_parse_prds :: proc(
	memory: Bmide_Memory_Adapter,
	request: Bmide_Request,
	table: u32,
	transfer: ^Bmide_Transfer,
) -> bool {
	if table & 3 != 0 {return false}
	table_address := u64(table)
	page_end := (table_address & ~u64(0xFFF)) + 0x1000
	max_entries := min(int((page_end - table_address) / 8), BMIDE_MAX_PRDS)
	covered: u64
	for index in 0 ..< max_entries {
		entry := table_address + u64(index * 8)
		address, address_ok := bmide_memory_read_u32(memory, entry)
		descriptor, descriptor_ok := bmide_memory_read_u32(memory, entry + 4)
		if !address_ok ||
		   !descriptor_ok ||
		   descriptor & BMIDE_PRD_RESERVED != 0 ||
		   address & 1 != 0 {
			return false
		}
		encoded_count := u16(descriptor)
		count := encoded_count == 0 ? u32(65_536) : u32(encoded_count)
		effective_address := address
		if request.direction == .Memory_To_Device {
			effective_address &~= 2
		}
		if count & 1 != 0 || u64(effective_address & 0xFFFF) + u64(count) > 0x1_0000 {
			return false
		}
		if !bmide_memory_range_valid(memory, u64(effective_address), u64(count)) {return false}
		remaining := u64(request.byte_count) - covered
		used := u32(min(u64(count), remaining))
		transfer.spans[index] = {
			address = effective_address,
			length  = used,
		}
		transfer.span_count = index + 1
		covered += u64(used)
		if covered == u64(request.byte_count) {
			transfer.retires_eot = used == count && descriptor & BMIDE_PRD_EOT != 0
			return true
		}
		if descriptor & BMIDE_PRD_EOT != 0 {return false}
	}
	return false
}

@(private = "file")
bmide_saturating_add :: proc(left, right: u64) -> u64 {
	if right > ~u64(0) - left {return ~u64(0)}
	return left + right
}

@(private = "file")
bmide_data_ticks :: proc(bytes, bytes_per_second: u64) -> u64 {
	numerator := u128(bytes) * u128(BMIDE_MASTER_CLOCK_HZ)
	value := (numerator + u128(bytes_per_second) - 1) / u128(bytes_per_second)
	return value > u128(~u64(0)) ? ~u64(0) : u64(value)
}

@(private = "file")
bmide_next_unit_length :: proc(transfer: ^Bmide_Transfer) -> u32 {
	if !transfer.active || transfer.span_index >= transfer.span_count {return 0}
	span := transfer.spans[transfer.span_index]
	span_remaining := span.length - transfer.span_offset
	transfer_remaining := transfer.byte_count - transfer.completed
	return min(min(span_remaining, transfer_remaining), u32(BMIDE_DMA_UNIT_BYTES))
}

@(private = "file")
bmide_schedule_next_unit :: proc(transfer: ^Bmide_Transfer) -> bool {
	unit := bmide_next_unit_length(transfer)
	if unit == 0 {return false}
	data_tick := bmide_data_ticks(u64(transfer.completed) + u64(unit), transfer.bytes_per_sec)
	transfer.next_tick = bmide_saturating_add(
		bmide_saturating_add(transfer.start_tick, BMIDE_COMMAND_LATENCY_TICKS),
		data_tick,
	)
	return true
}

@(private = "file")
bmide_request_callbacks_valid :: proc(
	memory: Bmide_Memory_Adapter,
	request: Bmide_Request,
) -> bool {
	if memory.read == nil {return false}
	switch request.direction {
	case .Device_To_Memory:
		return memory.write != nil && request.device.read != nil
	case .Memory_To_Device:
		return request.device.stage_write != nil
	}
	return false
}

@(private = "file")
bmide_arm_channel :: proc(bm: ^Bmide, channel_index: u8, memory: Bmide_Memory_Adapter) {
	channel := &bm.channels[channel_index]
	request := channel.request
	read_from_disk := channel.command & BMIDE_COMMAND_READ_FROM_DISK != 0
	if read_from_disk != (request.direction == .Device_To_Memory) ||
	   !bmide_request_callbacks_valid(memory, request) {
		bmide_fail_channel(channel, channel_index)
		return
	}
	transfer := Bmide_Transfer {
		direction     = request.direction,
		byte_count    = request.byte_count,
		bytes_per_sec = request.bytes_per_second,
		start_tick    = bm.now_tick,
	}
	if !bmide_parse_prds(memory, request, channel.prd_address, &transfer) {
		bmide_fail_channel(channel, channel_index)
		return
	}
	if request.device.begin != nil &&
	   !request.device.begin(
			   request.device.ctx,
			   channel_index,
			   request.direction,
			   request.byte_count,
		   ) {
		bmide_fail_channel(channel, channel_index)
		return
	}
	transfer.active = true
	if !bmide_schedule_next_unit(&transfer) {
		bmide_fail_channel(channel, channel_index)
		return
	}
	channel.transfer = transfer
	channel.completion_waits_for_stop = false
	channel.status |= BMIDE_STATUS_ACTIVE
}

bmide_synchronize :: proc(bm: ^Bmide, bus_master_enabled: bool, memory: Bmide_Memory_Adapter) {
	for index in 0 ..< BMIDE_CHANNEL_COUNT {
		channel := &bm.channels[index]
		if channel.transfer.active {
			if !bus_master_enabled {bmide_fail_channel(channel, u8(index))}
			continue
		}
		if channel.completion_waits_for_stop {
			if !bus_master_enabled {
				channel.status &= ~BMIDE_STATUS_ACTIVE
				channel.completion_waits_for_stop = false
			}
			continue
		}
		if bus_master_enabled &&
		   channel.command & BMIDE_COMMAND_START != 0 &&
		   channel.request_pending {
			bmide_arm_channel(bm, u8(index), memory)
		}
	}
}

@(private = "file")
bmide_complete_channel :: proc(channel: ^Bmide_Channel, channel_index: u8) -> bool {
	adapter := channel.request.device
	if adapter.commit != nil && !adapter.commit(adapter.ctx, channel_index) {
		bmide_fail_channel(channel, channel_index)
		return true
	}
	retired := channel.transfer.retires_eot
	channel.request = {}
	channel.request_pending = false
	channel.transfer = {}
	if retired {
		channel.status &= ~BMIDE_STATUS_ACTIVE
		channel.completion_waits_for_stop = false
	} else {
		channel.status |= BMIDE_STATUS_ACTIVE
		channel.completion_waits_for_stop = true
	}
	bmide_signal_interrupt(channel)
	return true
}

@(private = "file")
bmide_step_channel :: proc(bm: ^Bmide, channel_index: u8, memory: Bmide_Memory_Adapter) -> bool {
	channel := &bm.channels[channel_index]
	transfer := &channel.transfer
	unit := bmide_next_unit_length(transfer)
	if unit == 0 {
		bmide_fail_channel(channel, channel_index)
		return true
	}
	span := transfer.spans[transfer.span_index]
	address := u64(span.address) + u64(transfer.span_offset)
	data := channel.scratch[:int(unit)]
	adapter := channel.request.device
	ok := false
	switch transfer.direction {
	case .Device_To_Memory:
		ok =
			adapter.read(adapter.ctx, channel_index, transfer.completed, data) &&
			bmide_memory_write(memory, address, data)
	case .Memory_To_Device:
		ok =
			bmide_memory_read(memory, address, data) &&
			adapter.stage_write(adapter.ctx, channel_index, transfer.completed, data)
	}
	if !ok {
		bmide_fail_channel(channel, channel_index)
		return true
	}
	transfer.completed += unit
	transfer.span_offset += unit
	if transfer.span_offset == span.length {
		transfer.span_index += 1
		transfer.span_offset = 0
	}
	if transfer.completed == transfer.byte_count {
		return bmide_complete_channel(channel, channel_index)
	}
	if !bmide_schedule_next_unit(transfer) {
		bmide_fail_channel(channel, channel_index)
		return true
	}
	return false
}

bmide_next_deadline :: proc(bm: ^Bmide) -> (deadline: u64, pending: bool) {
	for &channel in bm.channels {
		if !channel.transfer.active {continue}
		if !pending || channel.transfer.next_tick < deadline {
			deadline = channel.transfer.next_tick
			pending = true
		}
	}
	return
}

bmide_advance_to :: proc(
	bm: ^Bmide,
	target_tick: u64,
	memory: Bmide_Memory_Adapter,
) -> (
	irq_mask: u8,
) {
	if target_tick < bm.now_tick {return 0}
	for {
		deadline, pending := bmide_next_deadline(bm)
		if !pending || deadline > target_tick {break}
		bm.now_tick = deadline
		for index in 0 ..< BMIDE_CHANNEL_COUNT {
			channel := &bm.channels[index]
			if channel.transfer.active &&
			   channel.transfer.next_tick == deadline &&
			   bmide_step_channel(bm, u8(index), memory) {
				irq_mask |= u8(1 << uint(index))
			}
		}
	}
	bm.now_tick = target_tick
	return
}

bmide_advance :: proc(bm: ^Bmide, master_ticks: u64, memory: Bmide_Memory_Adapter) -> u8 {
	target := bmide_saturating_add(bm.now_tick, master_ticks)
	return bmide_advance_to(bm, target, memory)
}

bmide_note_ide_irq :: proc(bm: ^Bmide, channel_index: u8) {
	if channel_index >= BMIDE_CHANNEL_COUNT {return}
	bm.channels[channel_index].status |= BMIDE_STATUS_INTERRUPT
}

bmide_take_irq :: proc(bm: ^Bmide, channel_index: u8) -> bool {
	if channel_index >= BMIDE_CHANNEL_COUNT {return false}
	channel := &bm.channels[channel_index]
	pending := channel.irq_signal
	channel.irq_signal = false
	return pending
}

bmide_interrupt_latched :: proc(bm: ^Bmide, channel_index: u8) -> bool {
	return(
		channel_index < BMIDE_CHANNEL_COUNT &&
		bm.channels[channel_index].status & BMIDE_STATUS_INTERRUPT != 0 \
	)
}

bmide_channel_active :: proc(bm: ^Bmide, channel_index: u8) -> bool {
	return(
		channel_index < BMIDE_CHANNEL_COUNT &&
		bm.channels[channel_index].status & BMIDE_STATUS_ACTIVE != 0 \
	)
}

bmide_reset_channel :: proc(bm: ^Bmide, channel_index: u8) {
	if channel_index >= BMIDE_CHANNEL_COUNT {return}
	channel := &bm.channels[channel_index]
	bmide_abort_adapter(channel, channel_index)
	channel^ = {}
}
