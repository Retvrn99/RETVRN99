// SPDX-License-Identifier: GPL-3.0-only
package machine

import "core:testing"
import video "../vga"

@(test)
test_test_device_indexed_registers_wrap :: proc(t: ^testing.T) {
	device: Test_Device
	testing.expect(t, test_device_write(&device, TEST_DEVICE_INDEX_PORT, 31))
	testing.expect(t, test_device_write(&device, TEST_DEVICE_DATA_PORT, 0xAA))
	testing.expect(t, test_device_write(&device, TEST_DEVICE_DATA_PORT, 0xBB))
	testing.expect_value(t, device.regs[31], u8(0xAA))
	testing.expect_value(t, device.regs[0], u8(0xBB))
	testing.expect_value(t, device.index, u8(1))
	_, handled := test_device_read(&device, 0xE7)
	testing.expect(t, !handled)
}

@(test)
test_test_device_out_of_range_index_matches_izarra_protocol :: proc(t: ^testing.T) {
	device: Test_Device
	testing.expect(t, test_device_write(&device, TEST_DEVICE_INDEX_PORT, 0xFE))
	value, ok := test_device_read(&device, TEST_DEVICE_DATA_PORT)
	testing.expect(t, ok)
	testing.expect_value(t, value, u8(0))
	testing.expect_value(t, device.index, u8(31))
	testing.expect(t, test_device_write(&device, TEST_DEVICE_DATA_PORT, 0xAA))
	testing.expect_value(t, device.regs[31], u8(0xAA))
	testing.expect_value(t, device.index, u8(0))
	device.regs[31] = 0x12
	testing.expect_value(t, test_device_register_u32(&device, 31), u32(0x12))
}

@(test)
test_test_device_commands_are_deferred :: proc(t: ^testing.T) {
	device: Test_Device
	test_device_write(&device, TEST_DEVICE_COMMAND_PORT, u8(Test_Device_Command.Exit))
	testing.expect_value(t, test_device_take_command(&device), Test_Device_Command.Exit)
	testing.expect_value(t, test_device_take_command(&device), Test_Device_Command.None)
	test_device_write(&device, TEST_DEVICE_COMMAND_PORT, 0xFF)
	testing.expect_value(t, test_device_take_command(&device), Test_Device_Command.None)
}

@(test)
test_test_device_rectangle_crc_and_results :: proc(t: ^testing.T) {
	device: Test_Device
	values := [?]u8{1, 0, 2, 0, 3, 0, 4, 0}
	test_device_write(&device, TEST_DEVICE_INDEX_PORT, TEST_DEVICE_REG_X)
	for value in values {test_device_write(&device, TEST_DEVICE_DATA_PORT, value)}
	testing.expect_value(t, test_device_rect(&device), Test_Device_Rect{x = 1, y = 2, width = 3, height = 4})
	test_device_set_crc(&device, 0x1234_5678)
	testing.expect_value(t, test_device_register_u32(&device, TEST_DEVICE_REG_CRC), u32(0x1234_5678))
	device.regs[TEST_DEVICE_REG_EXIT] = 0xA5
	testing.expect_value(t, test_device_exit_code(&device), u8(0xA5))
	testing.expect_value(t, test_device_crc32({1, 2, 3, 4}), u32(0xB63C_FBcd))
}

@(test)
test_test_device_frame_crc_clamps_and_uses_little_endian_argb :: proc(t: ^testing.T) {
	pixels := []u32{0x1122_3344, 0x5566_7788, 0x99AA_BBCC, 0xDDEE_FF00}
	frame := video.Display_Frame{width = 2, height = 2, pixels = pixels}
	bytes := []u8{0xCC, 0xBB, 0xAA, 0x99, 0x00, 0xFF, 0xEE, 0xDD}
	crc := test_device_frame_crc(&frame, {x = 0, y = 1, width = 8, height = 8})
	testing.expect_value(t, crc, test_device_crc32(bytes))
	testing.expect_value(
		t,
		test_device_frame_crc(&frame, {x = 5, y = 5, width = 1, height = 1}),
		u32(0),
	)
}

@(test)
test_machine_test_device_is_opt_in_and_byte_decomposed :: proc(t: ^testing.T) {
	m: Machine
	bus_init(&m.bus)
	defer bus_destroy(&m.bus)
	_ = bus_io_read(&m.bus, TEST_DEVICE_INDEX_PORT, 1)
	testing.expect_value(t, m.bus.unclassified_count, u64(1))
	machine_enable_test_device(&m)
	bus_io_write(&m.bus, TEST_DEVICE_INDEX_PORT, 2, 0xBBAA)
	testing.expect_value(t, m.test_device.index, u8(11))
	testing.expect_value(t, m.test_device.regs[10], u8(0))
	testing.expect_value(t, m.bus.modeled_count, u64(1))
}
