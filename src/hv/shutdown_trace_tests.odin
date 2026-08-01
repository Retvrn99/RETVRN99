// SPDX-License-Identifier: GPL-3.0-only
package hv

import "base:runtime"
import "core:testing"

@(test)
test_shutdown_trace_disabled_has_no_storage_or_accounting :: proc(t: ^testing.T) {
	vm: Vm
	shutdown_trace_record(&vm, Shutdown_Trace_Event{kind = .Mmio, address = 0xA0000})
	shutdown_trace_note_marker(&vm, SHUTDOWN_TRACE_DRIVER_DISABLE_MARKER)

	snapshot := shutdown_trace_snapshot(&vm)
	testing.expect(t, !snapshot.enabled)
	testing.expect(t, !snapshot.armed)
	testing.expect(t, !snapshot.storage_allocated)
	testing.expect_value(t, snapshot.count, u32(0))
	testing.expect_value(t, snapshot.recorded, u64(0))
	testing.expect_value(t, snapshot.dropped_unarmed, u64(0))
	testing.expect_value(t, snapshot.dropped_markers, u64(0))
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
	shutdown_trace_note_marker(&vm, SHUTDOWN_TRACE_DRIVER_DISABLE_MARKER)
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
	testing.expect_value(t, snapshot.count, u32(4))
	testing.expect_value(t, snapshot.recorded, u64(4))
	testing.expect_value(t, snapshot.dropped_unarmed, u64(1))
	testing.expect_value(t, snapshot.dropped_markers, u64(0))
	testing.expect_value(t, snapshot.overwritten, u64(0))

	events: [4]Shutdown_Trace_Event
	testing.expect_value(t, shutdown_trace_export(&vm, events[:]), 4)
	testing.expect_value(t, events[0].kind, Shutdown_Trace_Event_Kind.Marker)
	testing.expect_value(t, events[0].value, u8(0xD4))
	testing.expect_value(t, events[0].sequence, u64(1))
	testing.expect_value(t, events[1].value, u8(0xD5))
	testing.expect_value(t, events[1].sequence, u64(2))
	testing.expect_value(t, events[2].kind, Shutdown_Trace_Event_Kind.Mmio)
	testing.expect_value(t, events[2].cs, u16(0x28))
	testing.expect_value(t, events[2].rip, u64(0x1234))
	testing.expect_value(t, events[2].flags, u32(1))
	testing.expect_value(t, events[2].address, u64(0xA0123))
	testing.expect_value(t, events[2].detail, u64(2))
	testing.expect_value(t, events[3].value, u8(0xDC))
	testing.expect_value(t, events[3].sequence, u64(4))
	events[0].value = 0
	verification: [1]Shutdown_Trace_Event
	testing.expect_value(t, shutdown_trace_export(&vm, verification[:]), 1)
	testing.expect_value(t, verification[0].value, u8(0xD4))
}

@(test)
test_shutdown_trace_replays_prearm_lifecycle_markers_in_order :: proc(t: ^testing.T) {
	vm: Vm
	defer shutdown_trace_set_enabled(&vm, false)
	shutdown_trace_set_enabled(&vm, true)
	want := [6]u8{0xD1, 0xD2, 0xD3, 0xD4, 0xEF, 0xD5}
	for value in want[:len(want) - 1] {
		shutdown_trace_note_marker(&vm, value)
	}

	prearm := shutdown_trace_snapshot(&vm)
	testing.expect(t, !prearm.armed)
	testing.expect_value(t, prearm.count, u32(0))
	testing.expect_value(t, prearm.recorded, u64(0))
	testing.expect_value(t, prearm.dropped_unarmed, u64(0))
	testing.expect_value(t, prearm.dropped_markers, u64(0))

	shutdown_trace_note_marker(&vm, SHUTDOWN_TRACE_DRIVER_DISABLE_MARKER)
	events: [6]Shutdown_Trace_Event
	exported := shutdown_trace_export(&vm, events[:])
	snapshot := shutdown_trace_snapshot(&vm)
	testing.expect(t, snapshot.armed)
	testing.expect_value(t, exported, len(events))
	testing.expect_value(t, snapshot.count, u32(exported))
	testing.expect_value(t, snapshot.recorded, u64(exported))
	testing.expect_value(t, snapshot.overwritten, u64(0))
	for event, index in events {
		testing.expect_value(t, event.kind, Shutdown_Trace_Event_Kind.Marker)
		testing.expect_value(t, event.value, want[index])
		testing.expect_value(t, event.sequence, u64(index + 1))
	}
}

@(test)
test_shutdown_trace_arms_on_win16_disable_entry :: proc(t: ^testing.T) {
	vm: Vm
	defer shutdown_trace_set_enabled(&vm, false)
	shutdown_trace_set_enabled(&vm, true)
	shutdown_trace_note_marker(&vm, SHUTDOWN_TRACE_WIN16_DISABLE_MARKER)

	snapshot := shutdown_trace_snapshot(&vm)
	testing.expect(t, snapshot.armed)
	testing.expect_value(t, snapshot.count, u32(1))
	events: [1]Shutdown_Trace_Event
	testing.expect_value(t, shutdown_trace_export(&vm, events[:]), 1)
	testing.expect_value(t, events[0].value, u8(0xDF))
}

@(test)
test_shutdown_trace_second_arm_marker_preserves_sequence :: proc(t: ^testing.T) {
	vm: Vm
	defer shutdown_trace_set_enabled(&vm, false)
	shutdown_trace_set_enabled(&vm, true)
	shutdown_trace_note_marker(&vm, 0xD1)
	shutdown_trace_note_marker(&vm, SHUTDOWN_TRACE_WIN16_DISABLE_MARKER)
	shutdown_trace_record(&vm, Shutdown_Trace_Event{kind = .Mmio, address = 0xA0000})
	shutdown_trace_note_marker(&vm, SHUTDOWN_TRACE_DRIVER_DISABLE_MARKER)

	snapshot := shutdown_trace_snapshot(&vm)
	testing.expect_value(t, snapshot.count, u32(4))
	testing.expect_value(t, snapshot.recorded, u64(4))
	testing.expect_value(t, vm.shutdown_trace.prelude_count, u32(0))
	events: [4]Shutdown_Trace_Event
	testing.expect_value(t, shutdown_trace_export(&vm, events[:]), 4)
	testing.expect_value(t, events[0].value, u8(0xD1))
	testing.expect_value(t, events[0].sequence, u64(1))
	testing.expect_value(t, events[1].value, SHUTDOWN_TRACE_WIN16_DISABLE_MARKER)
	testing.expect_value(t, events[1].sequence, u64(2))
	testing.expect_value(t, events[2].address, u64(0xA0000))
	testing.expect_value(t, events[2].sequence, u64(3))
	testing.expect_value(t, events[3].value, SHUTDOWN_TRACE_DRIVER_DISABLE_MARKER)
	testing.expect_value(t, events[3].sequence, u64(4))
}

@(test)
test_shutdown_trace_inverse_arm_markers_preserve_sequence :: proc(t: ^testing.T) {
	vm: Vm
	defer shutdown_trace_set_enabled(&vm, false)
	shutdown_trace_set_enabled(&vm, true)
	shutdown_trace_note_marker(&vm, SHUTDOWN_TRACE_DRIVER_DISABLE_MARKER)
	shutdown_trace_record(&vm, Shutdown_Trace_Event{kind = .Irq_Injected, value = 9})
	shutdown_trace_note_marker(&vm, SHUTDOWN_TRACE_WIN16_DISABLE_MARKER)

	snapshot := shutdown_trace_snapshot(&vm)
	testing.expect_value(t, snapshot.count, u32(3))
	testing.expect_value(t, snapshot.recorded, u64(3))
	events: [3]Shutdown_Trace_Event
	testing.expect_value(t, shutdown_trace_export(&vm, events[:]), 3)
	testing.expect_value(t, events[0].value, SHUTDOWN_TRACE_DRIVER_DISABLE_MARKER)
	testing.expect_value(t, events[0].sequence, u64(1))
	testing.expect_value(t, events[1].kind, Shutdown_Trace_Event_Kind.Irq_Injected)
	testing.expect_value(t, events[1].sequence, u64(2))
	testing.expect_value(t, events[2].value, SHUTDOWN_TRACE_WIN16_DISABLE_MARKER)
	testing.expect_value(t, events[2].sequence, u64(3))
}

@(test)
test_shutdown_trace_overwrites_oldest_entries_and_reports_loss :: proc(t: ^testing.T) {
	vm: Vm
	defer shutdown_trace_set_enabled(&vm, false)
	shutdown_trace_set_enabled(&vm, true)
	shutdown_trace_note_marker(&vm, SHUTDOWN_TRACE_DRIVER_DISABLE_MARKER)
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
	testing.expect_value(t, events[0].kind, Shutdown_Trace_Event_Kind.Marker)
	testing.expect_value(t, events[0].value, SHUTDOWN_TRACE_DRIVER_DISABLE_MARKER)
	testing.expect_value(t, events[0].sequence, u64(1))
	testing.expect_value(t, events[1].sequence, u64(6))
	testing.expect_value(t, events[len(events) - 1].sequence, u64(SHUTDOWN_TRACE_CAPACITY + 4))
	testing.expect_value(
		t,
		events[len(events) - 1].address,
		u64(0xA0000 + SHUTDOWN_TRACE_CAPACITY + 2),
	)
}

@(test)
test_shutdown_trace_saturation_preserves_lifecycle_markers :: proc(t: ^testing.T) {
	vm: Vm
	defer shutdown_trace_set_enabled(&vm, false)
	shutdown_trace_set_enabled(&vm, true)
	shutdown_trace_note_marker(&vm, 0xD1)
	shutdown_trace_note_marker(&vm, 0xD2)
	shutdown_trace_note_marker(&vm, 0xD3)
	shutdown_trace_note_marker(&vm, 0xD4)
	shutdown_trace_note_marker(&vm, 0xEF)
	shutdown_trace_note_marker(&vm, 0xD5)
	shutdown_trace_note_marker(&vm, 0xD6)
	shutdown_trace_note_marker(&vm, 0xE8)
	shutdown_trace_note_marker(&vm, 0xD7)
	for index in 0 ..< SHUTDOWN_TRACE_CAPACITY + 17 {
		shutdown_trace_record(
			&vm,
			Shutdown_Trace_Event{kind = .Mmio, address = 0xA0000 + u64(index)},
		)
	}
	shutdown_trace_note_marker(&vm, 0xD8)
	shutdown_trace_note_marker(&vm, 0xD9)
	shutdown_trace_note_marker(&vm, 0xDA)
	shutdown_trace_note_marker(&vm, 0xDB)
	shutdown_trace_note_marker(&vm, 0xDC)

	snapshot := shutdown_trace_snapshot(&vm)
	testing.expect_value(t, snapshot.count, u32(SHUTDOWN_TRACE_CAPACITY))
	testing.expect_value(t, snapshot.recorded, u64(SHUTDOWN_TRACE_CAPACITY + 31))
	testing.expect_value(t, snapshot.overwritten, u64(31))
	testing.expect_value(t, snapshot.dropped_markers, u64(0))

	events := make(
		[]Shutdown_Trace_Event,
		SHUTDOWN_TRACE_CAPACITY + 32,
		runtime.heap_allocator(),
	)
	defer delete(events, runtime.heap_allocator())
	exported := shutdown_trace_export(&vm, events)
	testing.expect_value(t, exported, SHUTDOWN_TRACE_CAPACITY)
	testing.expect(t, exported <= SHUTDOWN_TRACE_CAPACITY)

	want := [14]u8{
		0xD1, 0xD2, 0xD3, 0xD4, 0xEF, 0xD5, 0xD6,
		0xE8, 0xD7, 0xD8, 0xD9, 0xDA, 0xDB, 0xDC,
	}
	marker_index := 0
	previous_sequence := u64(0)
	for event in events[:exported] {
		testing.expect(t, event.sequence > previous_sequence)
		previous_sequence = event.sequence
		if event.kind != .Marker {continue}
		testing.expect(t, marker_index < len(want))
		if marker_index < len(want) {
			testing.expect_value(t, event.value, want[marker_index])
		}
		marker_index += 1
	}
	testing.expect_value(t, marker_index, len(want))
	testing.expect_value(t, events[0].sequence, u64(1))
	testing.expect_value(
		t,
		events[exported - 1].sequence,
		u64(SHUTDOWN_TRACE_CAPACITY + 31),
	)
}

@(test)
test_shutdown_trace_prearm_marker_overflow_is_observable :: proc(t: ^testing.T) {
	vm: Vm
	defer shutdown_trace_set_enabled(&vm, false)
	shutdown_trace_set_enabled(&vm, true)
	for index in 0 ..< SHUTDOWN_TRACE_PRELUDE_CAPACITY + 3 {
		shutdown_trace_note_marker(&vm, u8(0xD1 + index % 4))
	}

	prearm := shutdown_trace_snapshot(&vm)
	testing.expect(t, !prearm.armed)
	testing.expect_value(t, prearm.count, u32(0))
	testing.expect_value(t, prearm.recorded, u64(0))
	testing.expect_value(t, prearm.dropped_unarmed, u64(0))
	testing.expect_value(t, prearm.dropped_markers, u64(3))
	testing.expect_value(
		t,
		vm.shutdown_trace.prelude_count,
		u32(SHUTDOWN_TRACE_PRELUDE_CAPACITY),
	)

	shutdown_trace_note_marker(&vm, SHUTDOWN_TRACE_DRIVER_DISABLE_MARKER)
	events: [SHUTDOWN_TRACE_PRELUDE_CAPACITY + 1]Shutdown_Trace_Event
	exported := shutdown_trace_export(&vm, events[:])
	snapshot := shutdown_trace_snapshot(&vm)
	testing.expect_value(t, exported, len(events))
	testing.expect_value(t, snapshot.count, u32(exported))
	testing.expect_value(t, snapshot.recorded, u64(exported))
	testing.expect_value(t, snapshot.dropped_unarmed, u64(0))
	testing.expect_value(t, snapshot.dropped_markers, u64(3))
	testing.expect_value(t, snapshot.overwritten, u64(0))
	testing.expect_value(t, vm.shutdown_trace.prelude_count, u32(0))
	testing.expect_value(
		t,
		events[exported - 1].value,
		SHUTDOWN_TRACE_DRIVER_DISABLE_MARKER,
	)
	testing.expect_value(t, events[exported - 1].sequence, u64(exported))
}

@(test)
test_shutdown_trace_marker_archive_overflow_is_observable :: proc(t: ^testing.T) {
	vm: Vm
	defer shutdown_trace_set_enabled(&vm, false)
	shutdown_trace_set_enabled(&vm, true)
	shutdown_trace_note_marker(&vm, SHUTDOWN_TRACE_DRIVER_DISABLE_MARKER)
	for index in 0 ..< SHUTDOWN_TRACE_MARKER_CAPACITY + 2 {
		shutdown_trace_note_marker(&vm, u8(0xE0 + index % 16))
	}

	snapshot := shutdown_trace_snapshot(&vm)
	testing.expect_value(
		t,
		snapshot.count,
		u32(SHUTDOWN_TRACE_MARKER_CAPACITY + 3),
	)
	testing.expect_value(t, snapshot.dropped_markers, u64(3))

	events: [SHUTDOWN_TRACE_MARKER_CAPACITY + 3]Shutdown_Trace_Event
	exported := shutdown_trace_export(&vm, events[:])
	testing.expect_value(t, exported, len(events))
	for event, index in events {
		testing.expect_value(t, event.kind, Shutdown_Trace_Event_Kind.Marker)
		testing.expect_value(t, event.sequence, u64(index + 1))
	}
}

@(test)
test_shutdown_trace_disable_releases_and_resets_state :: proc(t: ^testing.T) {
	vm: Vm
	shutdown_trace_set_enabled(&vm, true)
	shutdown_trace_note_marker(&vm, 0xD1)
	testing.expect_value(t, vm.shutdown_trace.prelude_count, u32(1))
	shutdown_trace_set_enabled(&vm, false)
	testing.expect_value(t, vm.shutdown_trace.prelude_count, u32(0))
	shutdown_trace_set_enabled(&vm, true)
	shutdown_trace_note_marker(&vm, SHUTDOWN_TRACE_DRIVER_DISABLE_MARKER)
	shutdown_trace_record(&vm, Shutdown_Trace_Event{kind = .Irq_Injected, value = 9})
	shutdown_trace_set_enabled(&vm, false)

	snapshot := shutdown_trace_snapshot(&vm)
	testing.expect(t, !snapshot.enabled)
	testing.expect(t, !snapshot.armed)
	testing.expect(t, !snapshot.storage_allocated)
	testing.expect_value(t, snapshot.count, u32(0))
	testing.expect_value(t, snapshot.recorded, u64(0))
	testing.expect_value(t, snapshot.overwritten, u64(0))
	testing.expect_value(t, snapshot.dropped_markers, u64(0))
	testing.expect_value(t, vm.shutdown_trace.marker_count, u32(0))
	testing.expect_value(t, vm.shutdown_trace.prelude_count, u32(0))
}
