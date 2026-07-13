// SPDX-License-Identifier: GPL-3.0-only
package machine

import "core:log"
import "core:testing"

@(test)
test_bus_dispatch :: proc(t: ^testing.T) {
	bus: Bus
	bus_init(&bus)
	defer bus_destroy(&bus)
	val: u32 = 0xAB
	h := Io_Handler{
		ctx   = &val,
		read  = proc(ctx: rawptr, port: u16, size: u8) -> u32 { return (^u32)(ctx)^ },
		write = proc(ctx: rawptr, port: u16, size: u8, v: u32) { (^u32)(ctx)^ = v },
	}
	bus_register(&bus, 0x60, 0x60, h)
	testing.expect_value(t, bus_io_read(&bus, 0x60, 1), 0xAB)
	bus_io_write(&bus, 0x60, 1, 0xCD)
	testing.expect_value(t, val, 0xCD)
}

@(test)
test_bus_unknown_port :: proc(t: ^testing.T) {
	bus: Bus
	bus_init(&bus)
	defer bus_destroy(&bus)
	bus_whitelist(&bus, 0x80) // POST port
	testing.expect_value(t, bus_io_read(&bus, 0x80, 1), 0xFF)
	testing.expect(t, !bus.frozen)
	testing.expect_value(t, bus_io_read(&bus, 0x1234, 2), u32(0xFFFF))
	bus_io_write(&bus, 0x1234, 2, 0xABCD)
	testing.expect(t, !bus.frozen)
	testing.expect_value(t, bus.unclassified_count, u64(2))
}

@(test)
test_bus_strict_unknown_port_stops :: proc(t: ^testing.T) {
	bus: Bus
	bus_init(&bus)
	defer bus_destroy(&bus)
	bus_set_strict_io(&bus, true)
	context.logger = log.nil_logger()
	_ = bus_io_read(&bus, 0x1234, 1)
	testing.expect(t, bus.frozen)
}

@(test)
test_bus_byte_decomposes_declared_handler :: proc(t: ^testing.T) {
	bus: Bus
	bus_init(&bus)
	defer bus_destroy(&bus)
	bytes := [2]u8{0x12, 0x34}
	h := Io_Handler{
		ctx = &bytes,
		read = proc(ctx: rawptr, port: u16, size: u8) -> u32 {
			return u32((^[2]u8)(ctx)[int(port - 0x200)])
		},
		write = proc(ctx: rawptr, port: u16, size: u8, value: u32) {
			(^[2]u8)(ctx)[int(port - 0x200)] = u8(value)
		},
	}
	bus_register_byte_decomposed(&bus, 0x200, 0x201, h)
	testing.expect_value(t, bus_io_read(&bus, 0x200, 2), u32(0x3412))
	bus_io_write(&bus, 0x200, 2, 0xBBAA)
	testing.expect_value(t, bytes, [2]u8{0xAA, 0xBB})
}
