// SPDX-License-Identifier: GPL-3.0-only
package hv

import "base:runtime"
import "core:testing"

@(test)
test_shutdown_trace_disabled_has_no_storage_or_accounting :: proc(t: ^testing.T) {
	vm: Vm
	shutdown_trace_record(&vm, Shutdown_Trace_Event{kind = .Mmio, address = 0xA0000})
	shutdown_trace_note_marker(&vm, SHUTDOWN_TRACE_ARM_MARKER)

	snapshot := shutdown_trace_snapshot(&vm)
	testing.expect(t, !snapshot.enabled)
	testing.expect(t, !snapshot.armed)
	testing.expect(t, !snapshot.storage_allocated)
	testing.expect_value(t, snapshot.count, u32(0))
	testing.expect_value(t, snapshot.recorded, u64(0))
	testing.expect_value(t, snapshot.dropped_unarmed, u64(0))
}

@(test)
test_shutdown_trace_arms_on_d5_and_exports_values_in_order :: proc(t: ^testing.T) {
	vm: Vm
	defer shutdown_trace_set_enabled(&vm, false)
	shutdown_trace_set_enabled(&vm, true)
	prearm := shutdown_trace_snapshot(&vm)
	testing.expect(t, prearm.storage_allocated)
	testing.expect(t, !prearm.armed)
	shutdown_trace_record(&vm, Shutdown_Trace_Event{kind = .Mmio, address = 0xA0000})
	shutdown_trace_note_marker(&vm, 0xD4)
	shutdown_trace_note_marker(&vm, SHUTDOWN_TRACE_ARM_MARKER)
	shutdown_trace_record(
		&vm,
		Shutdown_Trace_Event {
			kind = .Mmio, cs = 0x28, flags = 1, rip = 0x1234, address = 0xA0123,
			detail = 2,
		},
	)
	shutdown_trace_note_marker(&vm, 0xDC)

	snapshot := shutdown_trace_snapshot(&vm)
	testing.expect(t, snapshot.enabled)
	testing.expect(t, snapshot.armed)
	testing.expect(t, snapshot.storage_allocated)
	testing.expect_value(t, snapshot.count, u32(3))
	testing.expect_value(t, snapshot.recorded, u64(3))
	testing.expect_value(t, snapshot.dropped_unarmed, u64(2))
	testing.expect_value(t, snapshot.overwritten, u64(0))

	events: [3]Shutdown_Trace_Event
	testing.expect_value(t, shutdown_trace_export(&vm, events[:]), 3)
	testing.expect_value(t, events[0].kind, Shutdown_Trace_Event_Kind.Marker)
	testing.expect_value(t, events[0].value, u8(0xD5))
	testing.expect_value(t, events[0].sequence, u64(1))
	testing.expect_value(t, events[1].kind, Shutdown_Trace_Event_Kind.Mmio)
	testing.expect_value(t, events[1].cs, u16(0x28))
	testing.expect_value(t, events[1].rip, u64(0x1234))
	testing.expect_value(t, events[1].flags, u32(1))
	testing.expect_value(t, events[1].address, u64(0xA0123))
	testing.expect_value(t, events[1].detail, u64(2))
	testing.expect_value(t, events[2].value, u8(0xDC))
	testing.expect_value(t, events[2].sequence, u64(3))
	events[0].value = 0
	verification: [1]Shutdown_Trace_Event
	testing.expect_value(t, shutdown_trace_export(&vm, verification[:]), 1)
	testing.expect_value(t, verification[0].value, u8(0xD5))
}

@(test)
test_shutdown_trace_overwrites_oldest_entries_and_reports_loss :: proc(t: ^testing.T) {
	vm: Vm
	defer shutdown_trace_set_enabled(&vm, false)
	shutdown_trace_set_enabled(&vm, true)
	shutdown_trace_note_marker(&vm, SHUTDOWN_TRACE_ARM_MARKER)
	for index in 0 ..< SHUTDOWN_TRACE_CAPACITY + 3 {
		shutdown_trace_record(
			&vm,
			Shutdown_Trace_Event{kind = .Mmio, address = 0xA0000 + u64(index)},
		)
	}

	snapshot := shutdown_trace_snapshot(&vm)
	testing.expect_value(t, snapshot.count, u32(SHUTDOWN_TRACE_CAPACITY))
	testing.expect_value(t, snapshot.recorded, u64(SHUTDOWN_TRACE_CAPACITY + 4))
	testing.expect_value(t, snapshot.overwritten, u64(4))

	events := make(
		[]Shutdown_Trace_Event,
		SHUTDOWN_TRACE_CAPACITY,
		runtime.heap_allocator(),
	)
	defer delete(events, runtime.heap_allocator())
	testing.expect_value(t, shutdown_trace_export(&vm, events), SHUTDOWN_TRACE_CAPACITY)
	testing.expect_value(t, events[0].sequence, u64(5))
	testing.expect_value(t, events[len(events) - 1].sequence, u64(SHUTDOWN_TRACE_CAPACITY + 4))
	testing.expect_value(
		t,
		events[len(events) - 1].address,
		u64(0xA0000 + SHUTDOWN_TRACE_CAPACITY + 2),
	)
}

@(test)
test_shutdown_trace_disable_releases_and_resets_state :: proc(t: ^testing.T) {
	vm: Vm
	shutdown_trace_set_enabled(&vm, true)
	shutdown_trace_note_marker(&vm, SHUTDOWN_TRACE_ARM_MARKER)
	shutdown_trace_record(&vm, Shutdown_Trace_Event{kind = .Irq_Injected, value = 9})
	shutdown_trace_set_enabled(&vm, false)

	snapshot := shutdown_trace_snapshot(&vm)
	testing.expect(t, !snapshot.enabled)
	testing.expect(t, !snapshot.armed)
	testing.expect(t, !snapshot.storage_allocated)
	testing.expect_value(t, snapshot.count, u32(0))
	testing.expect_value(t, snapshot.recorded, u64(0))
	testing.expect_value(t, snapshot.overwritten, u64(0))
}
