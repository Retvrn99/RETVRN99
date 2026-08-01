// SPDX-License-Identifier: GPL-3.0-only
package machine

import hv "../hv"
import "core:log"
import "core:testing"

@(test)
test_machine_port_80_arms_and_orders_shutdown_trace :: proc(t: ^testing.T) {
	if !hv.available() {
		log.warn("WHPX not available")
		return
	}
	m := new(Machine)
	defer free(m)
	if !testing.expect(t, machine_init(m, 64 * 1024 * 1024)) {return}
	defer machine_destroy(m)
	hv.shutdown_trace_set_enabled(&m.vm, true)

	bus_io_write(&m.platform.bus, 0x80, 1, 0xD4)
	bus_io_write(&m.platform.bus, 0x80, 1, 0xD5)
	bus_io_write(&m.platform.bus, 0x80, 1, 0xD6)
	bus_io_write(&m.platform.bus, 0x80, 1, 0xDC)

	snapshot := hv.shutdown_trace_snapshot(&m.vm)
	testing.expect(t, snapshot.armed)
	testing.expect_value(t, snapshot.dropped_unarmed, u64(0))
	testing.expect_value(t, snapshot.count, u32(4))
	testing.expect_value(t, snapshot.recorded, u64(4))
	events: [4]hv.Shutdown_Trace_Event
	testing.expect_value(t, hv.shutdown_trace_export(&m.vm, events[:]), 4)
	for event, index in events {
		testing.expect_value(t, event.kind, hv.Shutdown_Trace_Event_Kind.Marker)
		testing.expect_value(t, event.sequence, u64(index + 1))
	}
	testing.expect_value(t, events[0].value, u8(0xD4))
	testing.expect_value(t, events[1].value, u8(0xD5))
	testing.expect_value(t, events[2].value, u8(0xD6))
	testing.expect_value(t, events[3].value, u8(0xDC))
}
