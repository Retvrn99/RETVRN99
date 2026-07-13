// SPDX-License-Identifier: GPL-3.0-only
package machine

import "core:testing"

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
