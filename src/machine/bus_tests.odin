// SPDX-License-Identifier: GPL-3.0-only
package machine

import hv "../hv"
import "core:log"
import "core:testing"

@(test)
test_bus_dispatch :: proc(t: ^testing.T) {
	bus: Bus
	bus_init(&bus)
	defer bus_destroy(&bus)
	testing.expect_value(t, len(bus.io), 0x1_0000)
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
	testing.expect_value(t, bus.modeled_count, u64(2))
	testing.expect_value(t, bus.passive_count, u64(0))
}

@(test)
test_bus_stream_dispatch_counts_elements_once :: proc(t: ^testing.T) {
	bus: Bus
	bus_init(&bus)
	defer bus_destroy(&bus)
	h := Io_Handler {
		stream_write = proc(_: rawptr, _: u16, size: u8, data: []u8) -> int {
			return len(data) / int(size)
		},
	}
	bus_register(&bus, 0x1F0, 0x1F0, h)
	data: [512]u8
	completed, handled := bus_io_stream_write(&bus, 0x1F0, 2, data[:])
	testing.expect(t, handled)
	testing.expect_value(t, completed, 256)
	testing.expect_value(t, bus.modeled_count, u64(256))
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
	testing.expect_value(t, bus.passive_count, u64(1))
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
	testing.expect_value(t, bus.modeled_count, u64(2))
}

@(test)
test_machine_unknown_mmio_is_open_bus_unless_strict :: proc(t: ^testing.T) {
	m := new(Machine)
	defer free(m)
	bus_init(&m.bus)
	defer bus_destroy(&m.bus)
	m.vm.a20_enabled = true
	data := [4]u8{}
	machine_mmio(m, 0x4000_0000, false, data[:])
	testing.expect_value(t, data, [4]u8{0xFF, 0xFF, 0xFF, 0xFF})
	testing.expect_value(t, m.bus.unclassified_mmio_count, u64(1))
	testing.expect(t, !m.bus.frozen)

	bus_set_strict_io(&m.bus, true)
	context.logger = log.nil_logger()
	machine_mmio(m, 0x4000_1000, true, data[:2])
	testing.expect_value(t, m.bus.unclassified_mmio_count, u64(2))
	testing.expect(t, m.bus.frozen)
}

// A guest instruction against device memory that no decoder can execute is
// contained like any other unclassified access: recorded on the same path and
// frozen with the diagnostic intact, rather than lost as a host failure.
@(test)
test_undecodable_mmio_is_recorded_and_contained :: proc(t: ^testing.T) {
	m := new(Machine)
	defer free(m)
	bus_init(&m.bus)
	defer bus_destroy(&m.bus)
	bus_set_strict_io(&m.bus, false)
	m.bus.diagnostic_tracing = true
	context.logger = log.nil_logger()

	detail := "MMIO emulation rip=0xffff gpa=0xae000 cs=[sel=0x9e9d] reject=unsupported MMIO opcode"
	alive := machine_handle_exit(
		m,
		hv.Exit {
			kind = .Mmio_Undecodable,
			detail = detail,
			cs = 0x9E9D,
			rip = 0xFFFF,
			gpa = 0xAE000,
			size = 1,
			write = false,
		},
	)

	testing.expect(t, !alive)
	testing.expect_value(t, m.bus.unclassified_mmio_count, u64(1))
	recorded := m.bus.unclassified_mmio_history[0]
	testing.expect_value(t, recorded.gpa, u64(0xAE000))
	testing.expect_value(t, recorded.size, u32(1))
	testing.expect(t, !recorded.write)
	testing.expect(t, m.bus.frozen)
	testing.expect_value(t, m.bus.freeze_msg, detail)
}
