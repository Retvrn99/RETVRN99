// SPDX-License-Identifier: GPL-3.0-only
package machine

// Intel 8237A algorithms adapted from IzarraVM commit
// d930de57acccbc6a70cda8cc5a603173bf23cd1c.

DMA_MASTER_CLOCK_HZ :: u64(6_600_000_000)
DMA_ISA_CLOCK_HZ :: u64(8_333_333)
DMA_MEM_TO_MEM_BUS_CYCLES :: u64(4)
DMA_MEM_TO_MEM_UNIT_TICKS ::
	(DMA_MASTER_CLOCK_HZ * DMA_MEM_TO_MEM_BUS_CYCLES + DMA_ISA_CLOCK_HZ - 1) / DMA_ISA_CLOCK_HZ

Dma_Channel :: struct {
	base_addr:       u16,
	addr:            u16,
	base_count:      u16,
	count:           u16,
	page:            u8,
	mode:            u8,
	masked:          bool,
	tc:              bool,
	dreq:            bool,
	active:          bool,
	transfer_cycles: u64,
}

Dma_Chip :: struct {
	flip_flop:        bool,
	command:          u8,
	status:           u8,
	software_request: u8,
	temporary:        u8,
}

Dma :: struct {
	ch:           [8]Dma_Channel,
	master:       Dma_Chip,
	slave:        Dma_Chip,
	page_scratch: [16]u8,
	refresh_page: u8,
	now_tick: u64,
	mem_to_mem_next_tick: u64,
	mem_to_mem_pending: bool,
	initialized:  bool,
}

dma_init :: proc(d: ^Dma) {
	d^ = {
		initialized = true,
	}
	for &c in d.ch {c.masked = true}
}

@(private = "file")
dma_ensure_init :: proc(d: ^Dma) {
	if d.initialized {return}
	dma_init(d)
}

@(private = "file")
dma_chip :: proc(d: ^Dma, secondary: bool) -> ^Dma_Chip {
	return secondary ? &d.slave : &d.master
}

@(private = "file")
dma_channel_base :: proc(secondary: bool) -> int {
	return secondary ? 4 : 0
}

@(private = "file")
dma_local_port :: proc(port: u16) -> (secondary: bool, local: u8, ok: bool) {
	if port <= 0x0F {return false, u8(port), true}
	if port >= 0xC0 && port <= 0xDE && port & 1 == 0 {
		return true, u8((port - 0xC0) >> 1), true
	}
	return false, 0, false
}

@(private = "file")
dma_page_channel :: proc(port: u16) -> (channel: int, ok: bool) {
	switch port {
	case 0x87:
		return 0, true
	case 0x83:
		return 1, true
	case 0x81:
		return 2, true
	case 0x82:
		return 3, true
	case 0x8B:
		return 5, true
	case 0x89:
		return 6, true
	case 0x8A:
		return 7, true
	}
	return 0, false
}

@(private = "file")
dma_page_is_scratch :: proc(port: u16) -> bool {
	switch port {
	case 0x80, 0x84, 0x85, 0x86, 0x88, 0x8C, 0x8D, 0x8E:
		return true
	}
	return false
}

@(private = "file")
dma_write_addr :: proc(chip: ^Dma_Chip, c: ^Dma_Channel, value: u8) {
	if !chip.flip_flop {
		c.base_addr = (c.base_addr & 0xFF00) | u16(value)
	} else {
		c.base_addr = (c.base_addr & 0x00FF) | u16(value) << 8
	}
	c.addr = c.base_addr
	chip.flip_flop = !chip.flip_flop
}

@(private = "file")
dma_write_count :: proc(chip: ^Dma_Chip, c: ^Dma_Channel, value: u8) {
	if !chip.flip_flop {
		c.base_count = (c.base_count & 0xFF00) | u16(value)
	} else {
		c.base_count = (c.base_count & 0x00FF) | u16(value) << 8
	}
	c.count = c.base_count
	c.tc = false
	chip.flip_flop = !chip.flip_flop
}

@(private = "file")
dma_read_word_register :: proc(chip: ^Dma_Chip, value: u16) -> u8 {
	result := chip.flip_flop ? u8(value >> 8) : u8(value)
	chip.flip_flop = !chip.flip_flop
	return result
}

@(private = "file")
dma_master_clear :: proc(d: ^Dma, secondary: bool) {
	chip := dma_chip(d, secondary)
	chip^ = {}
	base := dma_channel_base(secondary)
	for i in 0 ..< 4 {
		c := &d.ch[base + i]
		c.masked = true
		c.tc = false
		c.dreq = false
		c.active = false
	}
}

@(private = "file")
dma_write_local :: proc(d: ^Dma, secondary: bool, local, value: u8) {
	chip := dma_chip(d, secondary)
	base := dma_channel_base(secondary)
	if local < 8 {
		channel := int(local >> 1)
		if local & 1 == 0 {
			dma_write_addr(chip, &d.ch[base + channel], value)
		} else {
			dma_write_count(chip, &d.ch[base + channel], value)
		}
		return
	}
	switch local {
	case 8:
		chip.command = value
		if value & 0x04 != 0 {
			for i in 0 ..< 4 {d.ch[base + i].active = false}
		}
	case 9:
		bit := u8(1) << (value & 3)
		if value & 4 != 0 {chip.software_request |= bit} else {chip.software_request &~= bit}
	case 10:
		channel := int(value & 3)
		c := &d.ch[base + channel]
		c.masked = value & 4 != 0
		if c.masked {c.active = false}
	case 11:
		d.ch[base + int(value & 3)].mode = value
	case 12:
		chip.flip_flop = false
	case 13:
		dma_master_clear(d, secondary)
	case 14:
		for i in 0 ..< 4 {d.ch[base + i].masked = false}
	case 15:
		for i in 0 ..< 4 {
			c := &d.ch[base + i]
			c.masked = value & (u8(1) << u8(i)) != 0
			if c.masked {c.active = false}
		}
	}
}

@(private = "file")
dma_read_local :: proc(d: ^Dma, secondary: bool, local: u8) -> u8 {
	chip := dma_chip(d, secondary)
	base := dma_channel_base(secondary)
	if local < 8 {
		c := &d.ch[base + int(local >> 1)]
		return dma_read_word_register(chip, local & 1 == 0 ? c.addr : c.count)
	}
	switch local {
	case 8:
		requests := chip.software_request & 0x0F
		for i in 0 ..< 4 do if d.ch[base + i].dreq {requests |= u8(1) << u8(i)}
		if secondary && dma_primary_hrq_active(d) {requests |= 1}
		result := (chip.status & 0x0F) | requests << 4
		chip.status &~= 0x0F
		return result
	case 13:
		return chip.temporary
	}
	return 0xFF
}

dma_out :: proc(d: ^Dma, port: u16, value: u8) {
	dma_ensure_init(d)
	defer dma_refresh_mem_to_mem_schedule(d)
	if secondary, local, ok := dma_local_port(port); ok {
		dma_write_local(d, secondary, local, value)
		return
	}
	if channel, ok := dma_page_channel(port); ok {
		d.ch[channel].page = value
		return
	}
	if port == 0x8F {d.refresh_page = value; return}
	if dma_page_is_scratch(port) {d.page_scratch[port & 0x0F] = value}
}

dma_in :: proc(d: ^Dma, port: u16) -> u8 {
	dma_ensure_init(d)
	if secondary, local, ok := dma_local_port(port);
	   ok {return dma_read_local(d, secondary, local)}
	if channel, ok := dma_page_channel(port); ok {return d.ch[channel].page}
	if port == 0x8F {return d.refresh_page}
	if dma_page_is_scratch(port) {return d.page_scratch[port & 0x0F]}
	return 0xFF
}

dma_set_hardware_request :: proc(d: ^Dma, channel: int, asserted: bool) {
	dma_ensure_init(d)
	defer dma_refresh_mem_to_mem_schedule(d)
	if channel < 0 || channel >= len(d.ch) {return}
	c := &d.ch[channel]
	c.dreq = asserted
	if !asserted && (c.mode >> 6) & 3 != 2 {c.active = false}
}

@(private = "file")
dma_request_active :: proc(d: ^Dma, channel: int) -> bool {
	chip := channel < 4 ? &d.master : &d.slave
	local := channel & 3
	return d.ch[channel].dreq || chip.software_request & (u8(1) << u8(local)) != 0
}

@(private = "file")
dma_cascade_channel_ready :: proc(d: ^Dma) -> bool {
	c := &d.ch[4]
	return d.slave.command & 4 == 0 && !c.masked && (c.mode >> 6) & 3 == 3
}

@(private = "file")
dma_primary_hrq_active :: proc(d: ^Dma) -> bool {
	if d.master.command & 4 != 0 {return false}
	for channel in 0 ..< 4 {
		c := &d.ch[channel]
		block_active := (c.mode >> 6) & 3 == 2 && c.active
		if !c.masked && (dma_request_active(d, channel) || block_active) {return true}
	}
	return false
}

@(private = "file")
dma_begin_cycle :: proc(d: ^Dma, channel: int, transfer_kind: u8) -> bool {
	if channel < 0 || channel >= len(d.ch) {return false}
	if channel < 4 && !dma_cascade_channel_ready(d) {return false}
	c := &d.ch[channel]
	chip := channel < 4 ? &d.master : &d.slave
	block_active := (c.mode >> 6) & 3 == 2 && c.active
	if chip.command & 4 != 0 ||
	   c.masked ||
	   (c.mode >> 6) & 3 == 3 ||
	   (!dma_request_active(d, channel) && !block_active) ||
	   (c.mode >> 2) & 3 != transfer_kind {
		return false
	}
	c.tc = false
	c.active = true
	return true
}

@(private = "file")
dma_step_channel :: proc(d: ^Dma, channel: int) -> bool {
	c := &d.ch[channel]
	c.transfer_cycles += 1
	if c.mode & 0x20 != 0 {c.addr -= 1} else {c.addr += 1}
	reached_tc := c.count == 0
	c.count -= 1
	c.tc = reached_tc
	if !reached_tc {return false}
	chip := channel < 4 ? &d.master : &d.slave
	local := channel & 3
	chip.status |= u8(1) << u8(local)
	chip.software_request &~= u8(1) << u8(local)
	if c.mode & 0x10 != 0 {
		c.addr = c.base_addr
		c.count = c.base_count
	} else {
		c.masked = true
	}
	return true
}

@(private = "file")
dma_finish_cycle :: proc(d: ^Dma, channel: int, completed: bool) {
	c := &d.ch[channel]
	if !completed || c.tc || (c.mode >> 6) & 3 != 2 {c.active = false}
}

dma_channel_address :: proc(d: ^Dma, channel: int) -> (u32, bool) {
	dma_ensure_init(d)
	if channel >= 0 && channel < 4 {
		c := &d.ch[channel]
		return u32(c.page) << 16 | u32(c.addr), true
	}
	if channel >= 5 && channel < 8 {
		c := &d.ch[channel]
		return u32(c.page) << 17 | u32(c.addr) << 1, true
	}
	return 0, false
}

dma_transfer_to_memory_byte :: proc(d: ^Dma, channel: int, ram: []u8, value: u8) -> (u32, bool) {
	dma_ensure_init(d)
	if channel < 0 || channel >= 4 || !dma_begin_cycle(d, channel, 1) {return 0, false}
	address, _ := dma_channel_address(d, channel)
	if u64(address) >= u64(len(ram)) {dma_finish_cycle(d, channel, false); return 0, false}
	ram[int(address)] = value
	_ = dma_step_channel(d, channel)
	dma_finish_cycle(d, channel, true)
	return address, true
}

dma_transfer_from_memory_byte :: proc(d: ^Dma, channel: int, ram: []u8) -> (u8, bool) {
	dma_ensure_init(d)
	if channel < 0 || channel >= 4 || !dma_begin_cycle(d, channel, 2) {return 0, false}
	address, _ := dma_channel_address(d, channel)
	if u64(address) >= u64(len(ram)) {dma_finish_cycle(d, channel, false); return 0, false}
	value := ram[int(address)]
	_ = dma_step_channel(d, channel)
	dma_finish_cycle(d, channel, true)
	return value, true
}

dma_transfer_to_memory_word :: proc(d: ^Dma, channel: int, ram: []u8, value: u16) -> (u32, bool) {
	dma_ensure_init(d)
	if channel < 5 || channel >= 8 || !dma_begin_cycle(d, channel, 1) {return 0, false}
	address, _ := dma_channel_address(d, channel)
	if u64(address) + 1 >= u64(len(ram)) {dma_finish_cycle(d, channel, false); return 0, false}
	ram[int(address)] = u8(value)
	ram[int(address) + 1] = u8(value >> 8)
	_ = dma_step_channel(d, channel)
	dma_finish_cycle(d, channel, true)
	return address, true
}

dma_transfer_from_memory_word :: proc(d: ^Dma, channel: int, ram: []u8) -> (u16, bool) {
	dma_ensure_init(d)
	if channel < 5 || channel >= 8 || !dma_begin_cycle(d, channel, 2) {return 0, false}
	address, _ := dma_channel_address(d, channel)
	if u64(address) + 1 >= u64(len(ram)) {dma_finish_cycle(d, channel, false); return 0, false}
	value := u16(ram[int(address)]) | u16(ram[int(address) + 1]) << 8
	_ = dma_step_channel(d, channel)
	dma_finish_cycle(d, channel, true)
	return value, true
}

dma_transfer_verify :: proc(d: ^Dma, channel: int) -> bool {
	dma_ensure_init(d)
	if channel < 0 ||
	   channel >= 8 ||
	   channel == 4 ||
	   !dma_begin_cycle(d, channel, 0) {return false}
	_ = dma_step_channel(d, channel)
	dma_finish_cycle(d, channel, true)
	return true
}

dma_cascade_granted :: proc(d: ^Dma, channel: int) -> bool {
	dma_ensure_init(d)
	if channel == 4 {
		return dma_cascade_channel_ready(d) && dma_primary_hrq_active(d)
	}
	if channel < 0 || channel >= 8 {return false}
	c := &d.ch[channel]
	chip := channel < 4 ? &d.master : &d.slave
	return(
		chip.command & 4 == 0 &&
		!c.masked &&
		(c.mode >> 6) & 3 == 3 &&
		dma_request_active(d, channel) \
	)
}

dma_at_terminal_count :: proc(d: ^Dma, channel: int) -> bool {
	return channel >= 0 && channel < len(d.ch) && d.ch[channel].tc
}

dma_mem_to_mem_request_armed :: proc(d: ^Dma) -> bool {
	dma_ensure_init(d)
	return(
		d.master.command & 1 != 0 &&
		d.master.command & 4 == 0 &&
		!d.ch[0].masked &&
		!d.ch[1].masked &&
		(d.ch[0].mode >> 6) & 3 != 3 &&
		(d.ch[1].mode >> 6) & 3 != 3 &&
		dma_cascade_channel_ready(d) &&
		dma_request_active(d, 0) \
	)
}

@(private = "file")
dma_refresh_mem_to_mem_schedule :: proc(d: ^Dma) {
	if !dma_mem_to_mem_request_armed(d) {
		d.mem_to_mem_pending = false
		return
	}
	if d.mem_to_mem_pending {return}
	d.mem_to_mem_next_tick = d.now_tick + min(DMA_MEM_TO_MEM_UNIT_TICKS, ~u64(0) - d.now_tick)
	d.mem_to_mem_pending = true
}

@(private = "file")
dma_mem_to_mem_abort :: proc(d: ^Dma) {
	d.mem_to_mem_pending = false
	d.master.software_request &~= 0x03
	d.ch[0].active = false
	d.ch[1].active = false
}

@(private = "file")
dma_mem_to_mem_step_source :: proc(d: ^Dma, hold: bool) {
	c := &d.ch[0]
	c.transfer_cycles += 1
	if !hold {
		if c.mode & 0x20 != 0 {c.addr -= 1} else {c.addr += 1}
	}
	reached_tc := c.count == 0
	c.count -= 1
	c.tc = reached_tc
}

dma_mem_to_mem_cycle :: proc(d: ^Dma, ram: []u8) -> bool {
	if !dma_mem_to_mem_request_armed(d) {return false}
	source, _ := dma_channel_address(d, 0)
	destination, _ := dma_channel_address(d, 1)
	if u64(source) >= u64(len(ram)) || u64(destination) >= u64(len(ram)) {return false}
	value := ram[int(source)]
	ram[int(destination)] = value
	d.master.temporary = value
	hold := d.master.command & 2 != 0
	d.ch[0].active = true
	d.ch[1].active = true
	dma_mem_to_mem_step_source(d, hold)
	destination_tc := dma_step_channel(d, 1)
	if destination_tc {
		d.master.software_request &~= 0x03
		d.ch[0].active = false
		d.ch[1].active = false
	}
	return true
}

dma_next_deadline :: proc(d: ^Dma) -> (u64, bool) {
	dma_ensure_init(d)
	dma_refresh_mem_to_mem_schedule(d)
	return d.mem_to_mem_next_tick, d.mem_to_mem_pending
}

dma_advance_to :: proc(d: ^Dma, target_tick: u64, ram: []u8) -> (transferred: u64) {
	dma_ensure_init(d)
	if target_tick < d.now_tick {return 0}
	dma_refresh_mem_to_mem_schedule(d)
	for d.mem_to_mem_pending && d.mem_to_mem_next_tick <= target_tick {
		d.now_tick = d.mem_to_mem_next_tick
		d.mem_to_mem_pending = false
		if !dma_mem_to_mem_cycle(d, ram) {
			dma_mem_to_mem_abort(d)
			break
		}
		transferred += 1
		dma_refresh_mem_to_mem_schedule(d)
	}
	d.now_tick = target_tick
	return
}

// Compatibility Adapters for the existing FDC channel-2 glue.
dma_write_mem :: proc(d: ^Dma, channel: int, ram: []u8, data: []u8) {
	dma_set_hardware_request(d, channel, true)
	defer dma_set_hardware_request(d, channel, false)
	for value in data {
		if _, ok := dma_transfer_to_memory_byte(d, channel, ram, value); !ok {break}
	}
}

dma_read_mem :: proc(
	d: ^Dma,
	channel: int,
	ram: []u8,
	count: int,
	allocator := context.allocator,
) -> []u8 {
	result := make([]u8, count, allocator)
	written := 0
	dma_set_hardware_request(d, channel, true)
	defer dma_set_hardware_request(d, channel, false)
	for written < count {
		value, ok := dma_transfer_from_memory_byte(d, channel, ram)
		if !ok {break}
		result[written] = value
		written += 1
	}
	return result[:written]
}
