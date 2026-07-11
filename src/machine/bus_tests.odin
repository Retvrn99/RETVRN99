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
	bus_whitelist(&bus, 0x80) // puerto POST
	testing.expect_value(t, bus_io_read(&bus, 0x80, 1), 0xFF)
	testing.expect(t, !bus.frozen)
	{
		// el runner de tests falla ante logs de error; silenciar el congelado esperado
		context.logger = log.nil_logger()
		_ = bus_io_read(&bus, 0x1234, 1)
	}
	testing.expect(t, bus.frozen) // puerto desconocido congela la VM
}
