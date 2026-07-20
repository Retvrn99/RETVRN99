// SPDX-License-Identifier: GPL-3.0-only
package machine

import "core:testing"

dma_test_enable_pc_at_cascade :: proc(d: ^Dma) {
	dma_out(d, 0xD6, 0xC0)
	dma_out(d, 0xD4, 0x00)
}

dma_test_program_primary :: proc(d: ^Dma, channel: int, addr, count: u16, page, mode: u8) {
	dma_test_enable_pc_at_cascade(d)
	dma_out(d, 0x0C, 0)
	addr_port := u16(channel * 2)
	count_port := addr_port + 1
	dma_out(d, addr_port, u8(addr))
	dma_out(d, addr_port, u8(addr >> 8))
	dma_out(d, count_port, u8(count))
	dma_out(d, count_port, u8(count >> 8))
	page_ports := [4]u16{0x87, 0x83, 0x81, 0x82}
	dma_out(d, page_ports[channel], page)
	dma_out(d, 0x0B, mode | u8(channel))
	dma_out(d, 0x0A, u8(channel))
}

dma_test_program_secondary :: proc(d: ^Dma, channel: int, addr, count: u16, page, mode: u8) {
	local := channel - 4
	dma_out(d, 0xD8, 0)
	addr_port := u16(0xC0 + local * 4)
	dma_out(d, addr_port, u8(addr))
	dma_out(d, addr_port, u8(addr >> 8))
	dma_out(d, addr_port + 2, u8(count))
	dma_out(d, addr_port + 2, u8(count >> 8))
	page_ports := [4]u16{0, 0x8B, 0x89, 0x8A}
	if local != 0 {dma_out(d, page_ports[local], page)}
	dma_out(d, 0xD6, mode | u8(local))
	dma_out(d, 0xD4, u8(local))
}

dma_setup :: proc(d: ^Dma) {
	dma_test_program_primary(d, 2, 0x1234, 511, 0x05, 0x44)
}

@(test)
test_dma_ch2_write_mem :: proc(t: ^testing.T) {
	d: Dma
	dma_setup(&d)
	ram := make([]u8, 1 << 20)
	defer delete(ram)
	data: [512]u8
	for i in 0 ..< len(data) {data[i] = u8(i)}
	dma_write_mem(&d, 2, ram, data[:])
	testing.expect_value(t, ram[0x51234], u8(0))
	testing.expect_value(t, ram[0x51234 + 511], u8(255))
	testing.expect(t, dma_in(&d, 0x08) & 0x04 != 0)
}

@(test)
test_dma_ch2_tc_rearm :: proc(t: ^testing.T) {
	d: Dma
	dma_setup(&d)
	ram := make([]u8, 1 << 20)
	defer delete(ram)
	data: [512]u8
	dma_write_mem(&d, 2, ram, data[:])
	testing.expect(t, d.ch[2].tc)

	dma_setup(&d)
	testing.expect(t, !d.ch[2].tc)
	testing.expect(t, dma_in(&d, 0x08) & 0x04 != 0)

	dma_write_mem(&d, 2, ram, data[:])
	testing.expect(t, d.ch[2].tc)
	testing.expect(t, dma_in(&d, 0x08) & 0x04 != 0)
}

@(test)
test_dma_ch2_read_mem :: proc(t: ^testing.T) {
	d: Dma
	dma_test_program_primary(&d, 2, 0x1234, 511, 0x05, 0x48)
	ram := make([]u8, 1 << 20)
	defer delete(ram)
	for i in 0 ..< 512 {ram[0x51234 + i] = u8(i)}
	out := dma_read_mem(&d, 2, ram, 512)
	defer delete(out)
	testing.expect_value(t, len(out), 512)
	testing.expect_value(t, out[0], u8(0))
	testing.expect_value(t, out[511], u8(255))
	testing.expect(t, dma_in(&d, 0x08) & 0x04 != 0)
}

@(test)
test_dma_page_latches_and_independent_flip_flops :: proc(t: ^testing.T) {
	d: Dma
	dma_init(&d)
	dma_out(&d, 0x81, 0x12)
	dma_out(&d, 0x8B, 0x34)
	dma_out(&d, 0x8F, 0x56)
	dma_out(&d, 0x84, 0x78)
	testing.expect_value(t, dma_in(&d, 0x81), u8(0x12))
	testing.expect_value(t, dma_in(&d, 0x8B), u8(0x34))
	testing.expect_value(t, dma_in(&d, 0x8F), u8(0x56))
	testing.expect_value(t, dma_in(&d, 0x84), u8(0x78))

	dma_out(&d, 0x00, 0xCD)
	dma_out(&d, 0xC0, 0x34)
	dma_out(&d, 0xC0, 0x12)
	dma_out(&d, 0x00, 0xAB)
	testing.expect_value(t, d.ch[0].addr, u16(0xABCD))
	testing.expect_value(t, d.ch[4].addr, u16(0x1234))
}

@(test)
test_dma_secondary_word_addressing :: proc(t: ^testing.T) {
	d: Dma
	dma_test_program_secondary(&d, 5, 0x1234, 0, 0x02, 0x44)
	ram := make([]u8, 1 << 20)
	defer delete(ram)
	dma_set_hardware_request(&d, 5, true)
	address, ok := dma_transfer_to_memory_word(&d, 5, ram, 0xBEEF)
	dma_set_hardware_request(&d, 5, false)
	testing.expect(t, ok)
	testing.expect_value(t, address, u32(0x22468))
	testing.expect_value(t, ram[0x22468], u8(0xEF))
	testing.expect_value(t, ram[0x22469], u8(0xBE))
	testing.expect(t, d.ch[5].tc)
	testing.expect(t, dma_in(&d, 0xD0) & 0x02 != 0)
}

@(test)
test_dma_secondary_page_low_bit_is_ignored :: proc(t: ^testing.T) {
	d: Dma
	dma_test_program_secondary(&d, 5, 0x4000, 0, 0xFC, 0x44)
	address, ok := dma_channel_address(&d, 5)
	testing.expect(t, ok)
	testing.expect_value(t, address, u32(0xFC8000))

	dma_out(&d, 0x8B, 0xFD)
	address, ok = dma_channel_address(&d, 5)
	testing.expect(t, ok)
	testing.expect_value(t, dma_in(&d, 0x8B), u8(0xFD))
	testing.expect_value(t, address, u32(0xFC8000))
}

@(test)
test_dma_secondary_word_read :: proc(t: ^testing.T) {
	d: Dma
	dma_test_program_secondary(&d, 6, 0x20, 0, 2, 0x48)
	ram := make([]u8, 1 << 20)
	defer delete(ram)
	address, _ := dma_channel_address(&d, 6)
	ram[int(address)] = 0x34
	ram[int(address) + 1] = 0x12
	dma_set_hardware_request(&d, 6, true)
	value, ok := dma_transfer_from_memory_word(&d, 6, ram)
	dma_set_hardware_request(&d, 6, false)
	testing.expect(t, ok)
	testing.expect_value(t, value, u16(0x1234))
	testing.expect_value(t, address, u32(0x20040))
}

@(test)
test_dma_physical_memory_path_does_not_wrap_a20 :: proc(t: ^testing.T) {
	d: Dma
	dma_test_program_primary(&d, 2, 0, 0, 0x10, 0x44)
	ram := make([]u8, 2 << 20)
	defer delete(ram)
	dma_set_hardware_request(&d, 2, true)
	address, ok := dma_transfer_to_memory_byte(&d, 2, ram, 0xA5)
	dma_set_hardware_request(&d, 2, false)
	testing.expect(t, ok)
	testing.expect_value(t, address, u32(0x100000))
	testing.expect_value(t, ram[0], u8(0))
	testing.expect_value(t, ram[0x100000], u8(0xA5))
}

@(test)
test_dma_decrement_and_auto_init :: proc(t: ^testing.T) {
	d: Dma
	dma_test_program_primary(&d, 1, 0x0102, 1, 0, 0x34)
	ram: [0x200]u8
	dma_set_hardware_request(&d, 1, true)
	_, ok0 := dma_transfer_to_memory_byte(&d, 1, ram[:], 0xAA)
	_, ok1 := dma_transfer_to_memory_byte(&d, 1, ram[:], 0xBB)
	testing.expect(t, ok0 && ok1)
	testing.expect_value(t, ram[0x102], u8(0xAA))
	testing.expect_value(t, ram[0x101], u8(0xBB))
	testing.expect(t, d.ch[1].tc)
	testing.expect(t, !d.ch[1].masked)
	testing.expect_value(t, d.ch[1].addr, u16(0x0102))
	testing.expect_value(t, d.ch[1].count, u16(1))
	_, ok2 := dma_transfer_to_memory_byte(&d, 1, ram[:], 0xCC)
	dma_set_hardware_request(&d, 1, false)
	testing.expect(t, ok2)
	testing.expect(t, !d.ch[1].tc)
	testing.expect_value(t, ram[0x102], u8(0xCC))
}

@(test)
test_dma_command_disable_software_request_and_status :: proc(t: ^testing.T) {
	d: Dma
	dma_test_program_primary(&d, 2, 0x100, 0, 0, 0x04)
	ram: [0x200]u8
	dma_out(&d, 0x09, 0x06)
	testing.expect(t, dma_in(&d, 0x08) & 0x40 != 0)
	dma_out(&d, 0x08, 0x04)
	_, blocked := dma_transfer_to_memory_byte(&d, 2, ram[:], 0x77)
	testing.expect(t, !blocked)
	dma_out(&d, 0x08, 0)
	_, ok := dma_transfer_to_memory_byte(&d, 2, ram[:], 0x77)
	testing.expect(t, ok)
	testing.expect_value(t, ram[0x100], u8(0x77))
	status := dma_in(&d, 0x08)
	testing.expect(t, status & 0x04 != 0)
	testing.expect_value(t, dma_in(&d, 0x08) & 0x0F, u8(0))
}

@(test)
test_dma_demand_single_block_and_cascade :: proc(t: ^testing.T) {
	ram: [32]u8

	demand: Dma
	dma_test_program_primary(&demand, 0, 0, 2, 0, 0x04)
	dma_set_hardware_request(&demand, 0, true)
	_, demand_ok := dma_transfer_to_memory_byte(&demand, 0, ram[:], 1)
	dma_set_hardware_request(&demand, 0, false)
	_, demand_stopped := dma_transfer_to_memory_byte(&demand, 0, ram[:], 2)
	testing.expect(t, demand_ok && !demand_stopped && !demand.ch[0].active)

	single: Dma
	dma_test_program_primary(&single, 0, 0, 2, 0, 0x44)
	dma_set_hardware_request(&single, 0, true)
	_, single_ok := dma_transfer_to_memory_byte(&single, 0, ram[:], 3)
	testing.expect(t, single_ok && !single.ch[0].active)
	dma_set_hardware_request(&single, 0, false)

	block: Dma
	dma_test_program_primary(&block, 0, 0, 2, 0, 0x84)
	dma_set_hardware_request(&block, 0, true)
	_, block_first := dma_transfer_to_memory_byte(&block, 0, ram[:], 4)
	dma_set_hardware_request(&block, 0, false)
	_, block_second := dma_transfer_to_memory_byte(&block, 0, ram[:], 5)
	testing.expect(t, block_first && block_second && block.ch[0].active)

	cascade: Dma
	dma_test_program_primary(&cascade, 2, 0, 0, 0, 0x04)
	dma_set_hardware_request(&cascade, 2, true)
	testing.expect(t, dma_cascade_granted(&cascade, 4))
	testing.expect(t, dma_in(&cascade, 0xD0) & 0x10 != 0)
	dma_out(&cascade, 0xD4, 4)
	testing.expect(t, !dma_cascade_granted(&cascade, 4))
	_, cascade_blocked := dma_transfer_to_memory_byte(&cascade, 2, ram[:], 6)
	testing.expect(t, !cascade_blocked)
	dma_out(&cascade, 0xD4, 0)
	dma_out(&cascade, 0xD6, 0x00)
	testing.expect(t, !dma_cascade_granted(&cascade, 4))
	_, wrong_mode := dma_transfer_to_memory_byte(&cascade, 2, ram[:], 6)
	testing.expect(t, !wrong_mode)
	dma_out(&cascade, 0xD6, 0xC0)
	testing.expect(t, dma_cascade_granted(&cascade, 4))
	_, cascade_ok := dma_transfer_to_memory_byte(&cascade, 2, ram[:], 6)
	testing.expect(t, cascade_ok)
	dma_set_hardware_request(&cascade, 2, false)
}

@(test)
test_dma_verify_transfer :: proc(t: ^testing.T) {
	d: Dma
	dma_test_program_primary(&d, 3, 0xFFFE, 0, 0, 0x00)
	dma_set_hardware_request(&d, 3, true)
	testing.expect(t, dma_transfer_verify(&d, 3))
	dma_set_hardware_request(&d, 3, false)
	testing.expect_value(t, d.ch[3].addr, u16(0xFFFF))
	testing.expect(t, d.ch[3].tc)
}

@(test)
test_dma_memory_to_memory_copy_and_temporary :: proc(t: ^testing.T) {
	d: Dma
	dma_test_program_primary(&d, 0, 0x100, 3, 0, 0)
	dma_test_program_primary(&d, 1, 0x200, 3, 0, 0)
	ram: [0x300]u8
	for i in 0 ..< 4 {ram[0x100 + i] = u8(0xA0 + i)}
	dma_out(&d, 0x08, 1)
	dma_out(&d, 0x09, 4)
	deadline, pending := dma_next_deadline(&d)
	testing.expect(t, pending)
	testing.expect_value(t, dma_advance_to(&d, deadline - 1, ram[:]), u64(0))
	testing.expect_value(t, ram[0x200], u8(0))
	testing.expect_value(t, dma_advance_to(&d, deadline, ram[:]), u64(1))
	testing.expect_value(t, ram[0x200], u8(0xA0))
	deadline, pending = dma_next_deadline(&d)
	testing.expect(t, pending)
	testing.expect_value(
		t,
		dma_advance_to(&d, deadline + 2 * DMA_MEM_TO_MEM_UNIT_TICKS, ram[:]),
		u64(3),
	)
	for i in 0 ..< 4 {testing.expect_value(t, ram[0x200 + i], u8(0xA0 + i))}
	testing.expect_value(t, dma_in(&d, 0x0D), u8(0xA3))
	testing.expect(t, dma_in(&d, 0x08) & 0x02 != 0)
}

@(test)
test_dma_memory_to_memory_channel_zero_hold :: proc(t: ^testing.T) {
	d: Dma
	dma_test_program_primary(&d, 0, 0x100, 3, 0, 0)
	dma_test_program_primary(&d, 1, 0x200, 3, 0, 0)
	ram: [0x300]u8
	ram[0x100] = 0x5A
	dma_out(&d, 0x08, 3)
	dma_out(&d, 0x09, 4)
	deadline, pending := dma_next_deadline(&d)
	testing.expect(t, pending)
	testing.expect_value(
		t,
		dma_advance_to(&d, deadline + 3 * DMA_MEM_TO_MEM_UNIT_TICKS, ram[:]),
		u64(4),
	)
	for i in 0 ..< 4 {testing.expect_value(t, ram[0x200 + i], u8(0x5A))}
	testing.expect_value(t, d.ch[0].addr, u16(0x100))
}

@(test)
test_dma_memory_to_memory_requires_destination_and_cascade :: proc(t: ^testing.T) {
	d: Dma
	dma_test_program_primary(&d, 0, 0x100, 0, 0, 0)
	dma_test_program_primary(&d, 1, 0x200, 0, 0, 0)
	dma_out(&d, 0x0A, 5)
	dma_out(&d, 0x08, 1)
	dma_out(&d, 0x09, 4)
	_, pending := dma_next_deadline(&d)
	testing.expect(t, !pending)

	dma_out(&d, 0x0A, 1)
	dma_out(&d, 0xD4, 4)
	_, pending = dma_next_deadline(&d)
	testing.expect(t, !pending)

	dma_out(&d, 0xD4, 0)
	_, pending = dma_next_deadline(&d)
	testing.expect(t, pending)
}

@(test)
test_dma_memory_to_memory_bounds_fault_aborts_request :: proc(t: ^testing.T) {
	d: Dma
	dma_test_program_primary(&d, 0, 0x100, 0, 0, 0)
	dma_test_program_primary(&d, 1, 0x08, 0, 0, 0)
	dma_out(&d, 0x08, 1)
	dma_out(&d, 0x09, 4)
	ram: [16]u8
	deadline, pending := dma_next_deadline(&d)
	testing.expect(t, pending)
	testing.expect_value(t, dma_advance_to(&d, deadline, ram[:]), u64(0))
	_, pending = dma_next_deadline(&d)
	testing.expect(t, !pending)
	testing.expect(t, !dma_mem_to_mem_request_armed(&d))
	testing.expect_value(t, ram[8], u8(0))
}

@(test)
test_dma_master_clear_masks_and_clears_requests :: proc(t: ^testing.T) {
	d: Dma
	dma_test_program_secondary(&d, 7, 0, 4, 0, 0x48)
	dma_out(&d, 0xD2, 7)
	dma_out(&d, 0xDA, 0)
	for channel in 4 ..< 8 {testing.expect(t, d.ch[channel].masked)}
	testing.expect_value(t, dma_in(&d, 0xD0), u8(0))
}
