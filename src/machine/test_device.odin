// SPDX-License-Identifier: GPL-3.0-only
package machine

import video "../vga"

// Wire protocol adapted from IzarraVM commit d930de57acccbc6a70cda8cc5a603173bf23cd1c.

TEST_DEVICE_INDEX_PORT   :: u16(0xE4)
TEST_DEVICE_DATA_PORT    :: u16(0xE5)
TEST_DEVICE_COMMAND_PORT :: u16(0xE6)

TEST_DEVICE_REGISTER_COUNT :: 32

TEST_DEVICE_REG_X          :: 0
TEST_DEVICE_REG_Y          :: 2
TEST_DEVICE_REG_WIDTH      :: 4
TEST_DEVICE_REG_HEIGHT     :: 6
TEST_DEVICE_REG_CRC        :: 8
TEST_DEVICE_REG_EXIT       :: 12
TEST_DEVICE_REG_SELECTOR   :: 16
TEST_DEVICE_REG_ITERATIONS :: 17
TEST_DEVICE_REG_AUX        :: 21
TEST_DEVICE_REG_STATUS     :: 25
TEST_DEVICE_REG_REPORT_LENGTH :: 30
TEST_DEVICE_REG_REPORT_STATUS :: 31

TEST_DEVICE_REPORT_PAYLOAD_BYTES :: 30

Test_Device_Command :: enum u8 {
	None     = 0,
	Crc      = 1,
	Snapshot = 2,
	Exit     = 3,
	Begin_Report  = 4,
	Append_Report = 5,
	Commit_Report = 6,
	Abort_Report  = 7,
}

Test_Device_Rect :: struct {
	x, y:          u16,
	width, height: u16,
}

Test_Device :: struct {
	index:   u8,
	regs:    [TEST_DEVICE_REGISTER_COUNT]u8,
	pending: Test_Device_Command,
}

test_device_read :: proc(device: ^Test_Device, port: u16) -> (u8, bool) {
	switch port {
	case TEST_DEVICE_INDEX_PORT:
		return device.index, true
	case TEST_DEVICE_DATA_PORT:
		value: u8
		if int(device.index) < TEST_DEVICE_REGISTER_COUNT {
			value = device.regs[int(device.index)]
		}
		device.index = u8((u16(device.index) + 1) % TEST_DEVICE_REGISTER_COUNT)
		return value, true
	case TEST_DEVICE_COMMAND_PORT:
		return 0, true
	}
	return 0, false
}

test_device_write :: proc(device: ^Test_Device, port: u16, value: u8) -> bool {
	switch port {
	case TEST_DEVICE_INDEX_PORT:
		device.index = value
		return true
	case TEST_DEVICE_DATA_PORT:
		if int(device.index) < TEST_DEVICE_REGISTER_COUNT {
			device.regs[int(device.index)] = value
		}
		device.index = u8((u16(device.index) + 1) % TEST_DEVICE_REGISTER_COUNT)
		return true
	case TEST_DEVICE_COMMAND_PORT:
		if command := Test_Device_Command(value); command >= .Crc && command <= .Abort_Report {
			device.pending = command
		} else {
			device.pending = .None
		}
		return true
	}
	return false
}

test_device_take_command :: proc(device: ^Test_Device) -> Test_Device_Command {
	command := device.pending
	device.pending = .None
	return command
}

test_device_rect :: proc(device: ^Test_Device) -> Test_Device_Rect {
	return {
		x      = u16(device.regs[TEST_DEVICE_REG_X]) |
		         u16(device.regs[TEST_DEVICE_REG_X + 1]) << 8,
		y      = u16(device.regs[TEST_DEVICE_REG_Y]) |
		         u16(device.regs[TEST_DEVICE_REG_Y + 1]) << 8,
		width  = u16(device.regs[TEST_DEVICE_REG_WIDTH]) |
		         u16(device.regs[TEST_DEVICE_REG_WIDTH + 1]) << 8,
		height = u16(device.regs[TEST_DEVICE_REG_HEIGHT]) |
		         u16(device.regs[TEST_DEVICE_REG_HEIGHT + 1]) << 8,
	}
}

test_device_set_crc :: proc(device: ^Test_Device, value: u32) {
	for i in 0 ..< 4 {device.regs[TEST_DEVICE_REG_CRC + i] = u8(value >> (8 * u32(i)))}
}

test_device_exit_code :: proc(device: ^Test_Device) -> u8 {
	return device.regs[TEST_DEVICE_REG_EXIT]
}

test_device_report_payload :: proc(device: ^Test_Device) -> ([]u8, bool) {
	length := int(device.regs[TEST_DEVICE_REG_REPORT_LENGTH])
	if length < 1 || length > TEST_DEVICE_REPORT_PAYLOAD_BYTES {return nil, false}
	return device.regs[:length], true
}

test_device_set_report_status :: proc(device: ^Test_Device, value: u8) {
	device.regs[TEST_DEVICE_REG_REPORT_STATUS] = value
}

test_device_register_u32 :: proc(device: ^Test_Device, offset: int) -> u32 {
	if offset < 0 {return 0}
	value: u32
	for i in 0 ..< 4 {
		if offset + i >= TEST_DEVICE_REGISTER_COUNT {break}
		value |= u32(device.regs[offset + i]) << (8 * u32(i))
	}
	return value
}

test_device_crc32 :: proc(data: []u8) -> u32 {
	crc := ~u32(0)
	for byte in data {
		crc ~= u32(byte)
		for _ in 0 ..< 8 {
			mask := u32(0) - (crc & 1)
			crc = (crc >> 1) ~ (0xEDB8_8320 & mask)
		}
	}
	return ~crc
}

test_device_frame_crc :: proc(frame: ^video.Display_Frame, rect: Test_Device_Rect) -> u32 {
	if frame == nil || frame.width <= 0 || frame.height <= 0 || len(frame.pixels) == 0 {
		return 0
	}
	x := min(int(rect.x), frame.width)
	y := min(int(rect.y), frame.height)
	x_end := min(x + int(rect.width), frame.width)
	y_end := min(y + int(rect.height), frame.height)
	if x >= x_end || y >= y_end {return 0}
	crc := ~u32(0)
	for row in y ..< y_end {
		for column in x ..< x_end {
			pixel := frame.pixels[row * frame.width + column]
			for shift := u32(0); shift < 32; shift += 8 {
				crc ~= (pixel >> shift) & 0xFF
				for _ in 0 ..< 8 {
					mask := u32(0) - (crc & 1)
					crc = (crc >> 1) ~ (0xEDB8_8320 & mask)
				}
			}
		}
	}
	return ~crc
}
