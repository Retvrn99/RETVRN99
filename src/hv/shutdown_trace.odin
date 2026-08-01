// SPDX-License-Identifier: GPL-3.0-only
package hv

import "base:runtime"

SHUTDOWN_TRACE_CAPACITY              :: 65_536
SHUTDOWN_TRACE_PRELUDE_CAPACITY      :: 256
SHUTDOWN_TRACE_MARKER_CAPACITY       :: 512
SHUTDOWN_TRACE_DRIVER_DISABLE_MARKER :: u8(0xD5)
SHUTDOWN_TRACE_WIN16_DISABLE_MARKER  :: u8(0xDF)
SHUTDOWN_TRACE_FLAG_V86              :: u32(1 << 31)

Shutdown_Trace_Event_Kind :: enum u8 {
	Marker,
	Mmio,
	Irq_Injected,
	Irq_Deferred,
	Fault_Injected,
}

Shutdown_Trace_Event :: struct {
	kind:     Shutdown_Trace_Event_Kind,
	value:    u8,
	cs:       u16,
	flags:    u32,
	rip:      u64,
	address:  u64,
	detail:   u64,
	sequence: u64,
}

Shutdown_Trace_Snapshot :: struct {
	enabled:          bool,
	armed:            bool,
	storage_allocated: bool,
	count:            u32,
	capacity:         u32,
	recorded:         u64,
	dropped_unarmed:  u64,
	dropped_markers:  u64,
	overwritten:      u64,
}

Shutdown_Trace_State :: struct {
	enabled:         bool,
	armed:           bool,
	entries:         []Shutdown_Trace_Event,
	prelude:         [SHUTDOWN_TRACE_PRELUDE_CAPACITY]u8,
	prelude_count:   u32,
	markers:         [SHUTDOWN_TRACE_MARKER_CAPACITY]Shutdown_Trace_Event,
	marker_count:    u32,
	start:           u32,
	count:           u32,
	recorded:        u64,
	dropped_unarmed: u64,
	dropped_markers: u64,
	overwritten:     u64,
}

shutdown_trace_set_enabled :: proc(vm: ^Vm, enabled: bool) {
	if vm == nil {return}
	trace := &vm.shutdown_trace
	if trace.enabled == enabled {return}
	shutdown_trace_release(trace)
	trace^ = {}
	trace.enabled = enabled
	if enabled {
		trace.entries = make(
			[]Shutdown_Trace_Event,
			SHUTDOWN_TRACE_CAPACITY,
			runtime.heap_allocator(),
		)
	}
}

shutdown_trace_note_marker :: proc(vm: ^Vm, value: u8) {
	if vm == nil || !vm.shutdown_trace.enabled {return}
	trace := &vm.shutdown_trace
	if !trace.armed && !shutdown_trace_is_arm_marker(value) {
		if trace.prelude_count < SHUTDOWN_TRACE_PRELUDE_CAPACITY {
			trace.prelude[trace.prelude_count] = value
			trace.prelude_count += 1
		} else {
			trace.dropped_markers = saturating_increment(trace.dropped_markers)
		}
		return
	}
	if !trace.armed {
		trace.armed = true
		trace.start = 0
		trace.count = 0
		trace.recorded = 0
		trace.overwritten = 0
		trace.marker_count = 0
		for index in 0 ..< int(trace.prelude_count) {
			shutdown_trace_record(
				vm,
				Shutdown_Trace_Event{kind = .Marker, value = trace.prelude[index]},
			)
		}
		trace.prelude = {}
		trace.prelude_count = 0
	}
	shutdown_trace_record(vm, Shutdown_Trace_Event{kind = .Marker, value = value})
}

@(private = "file")
shutdown_trace_is_arm_marker :: proc(value: u8) -> bool {
	return value == SHUTDOWN_TRACE_DRIVER_DISABLE_MARKER ||
	       value == SHUTDOWN_TRACE_WIN16_DISABLE_MARKER
}

shutdown_trace_record :: proc(vm: ^Vm, event: Shutdown_Trace_Event) {
	if vm == nil || !vm.shutdown_trace.enabled {return}
	trace := &vm.shutdown_trace
	if !trace.armed {
		trace.dropped_unarmed = saturating_increment(trace.dropped_unarmed)
		return
	}
	if len(trace.entries) != SHUTDOWN_TRACE_CAPACITY {return}

	trace.recorded = saturating_increment(trace.recorded)
	record := event
	record.sequence = trace.recorded
	if record.kind == .Marker {
		if trace.marker_count < SHUTDOWN_TRACE_MARKER_CAPACITY {
			trace.markers[trace.marker_count] = record
			trace.marker_count += 1
		} else {
			trace.dropped_markers = saturating_increment(trace.dropped_markers)
		}
	}
	if trace.count < u32(SHUTDOWN_TRACE_CAPACITY) {
		index := (trace.start + trace.count) % u32(SHUTDOWN_TRACE_CAPACITY)
		trace.entries[index] = record
		trace.count += 1
		return
	}

	trace.entries[trace.start] = record
	trace.start = (trace.start + 1) % u32(SHUTDOWN_TRACE_CAPACITY)
	trace.overwritten = saturating_increment(trace.overwritten)
}

shutdown_trace_snapshot :: proc(vm: ^Vm) -> Shutdown_Trace_Snapshot {
	if vm == nil {return {capacity = u32(SHUTDOWN_TRACE_CAPACITY)}}
	trace := &vm.shutdown_trace
	return {
		enabled           = trace.enabled,
		armed             = trace.armed,
		storage_allocated = trace.entries != nil,
		count             = trace.count,
		capacity          = u32(SHUTDOWN_TRACE_CAPACITY),
		recorded          = trace.recorded,
		dropped_unarmed   = trace.dropped_unarmed,
		dropped_markers   = trace.dropped_markers,
		overwritten       = trace.overwritten,
	}
}

shutdown_trace_export :: proc(vm: ^Vm, destination: []Shutdown_Trace_Event) -> int {
	if vm == nil || len(destination) == 0 {return 0}
	trace := &vm.shutdown_trace
	if trace.count == 0 || len(trace.entries) != SHUTDOWN_TRACE_CAPACITY {return 0}
	export_capacity := min(len(destination), SHUTDOWN_TRACE_CAPACITY)
	marker_count := min(export_capacity, int(trace.marker_count))
	ring_capacity := export_capacity - marker_count
	available_ring_events := 0
	for offset in 0 ..< int(trace.count) {
		index := (trace.start + u32(offset)) % u32(SHUTDOWN_TRACE_CAPACITY)
		if shutdown_trace_ring_event_is_exportable(trace, trace.entries[index]) {
			available_ring_events += 1
		}
	}
	ring_event_count := min(available_ring_events, ring_capacity)
	ring_event_skip := available_ring_events - ring_event_count

	marker_index := 0
	ring_offset := 0
	skipped_ring_events := 0
	written_ring_events := 0
	written := 0
	for written < marker_count + ring_event_count {
		for ring_offset < int(trace.count) {
			index := (trace.start + u32(ring_offset)) % u32(SHUTDOWN_TRACE_CAPACITY)
			if !shutdown_trace_ring_event_is_exportable(trace, trace.entries[index]) {
				ring_offset += 1
				continue
			}
			if skipped_ring_events < ring_event_skip {
				skipped_ring_events += 1
				ring_offset += 1
				continue
			}
			break
		}

		has_marker := marker_index < marker_count
		has_ring_event := written_ring_events < ring_event_count &&
		                  ring_offset < int(trace.count)
		if has_marker && (!has_ring_event ||
		   trace.markers[marker_index].sequence <
		   trace.entries[(trace.start + u32(ring_offset)) % u32(SHUTDOWN_TRACE_CAPACITY)].sequence) {
			destination[written] = trace.markers[marker_index]
			marker_index += 1
		} else if has_ring_event {
			index := (trace.start + u32(ring_offset)) % u32(SHUTDOWN_TRACE_CAPACITY)
			destination[written] = trace.entries[index]
			ring_offset += 1
			written_ring_events += 1
		} else {
			break
		}
		written += 1
	}
	return written
}

@(private = "file")
shutdown_trace_ring_event_is_exportable :: proc(
	trace: ^Shutdown_Trace_State,
	event: Shutdown_Trace_Event,
) -> bool {
	if event.kind != .Marker || trace.marker_count == 0 {return true}
	return event.sequence > trace.markers[trace.marker_count - 1].sequence
}

@(private = "file")
shutdown_trace_release :: proc(trace: ^Shutdown_Trace_State) {
	if trace == nil || trace.entries == nil {return}
	delete(trace.entries, runtime.heap_allocator())
	trace.entries = nil
}

@(private = "file")
saturating_increment :: proc(value: u64) -> u64 {
	return value < max(u64) ? value + 1 : value
}
