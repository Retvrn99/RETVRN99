// SPDX-License-Identifier: GPL-3.0-only
package hv

import "base:runtime"

SHUTDOWN_TRACE_CAPACITY   :: 65_536
SHUTDOWN_TRACE_ARM_MARKER :: u8(0xD5)
SHUTDOWN_TRACE_FLAG_V86   :: u32(1 << 31)

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
	overwritten:      u64,
}

Shutdown_Trace_State :: struct {
	enabled:         bool,
	armed:           bool,
	entries:         []Shutdown_Trace_Event,
	start:           u32,
	count:           u32,
	recorded:        u64,
	dropped_unarmed: u64,
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
	if value == SHUTDOWN_TRACE_ARM_MARKER && !trace.armed {
		trace.armed = true
		trace.start = 0
		trace.count = 0
		trace.recorded = 0
		trace.overwritten = 0
	}
	shutdown_trace_record(vm, Shutdown_Trace_Event{kind = .Marker, value = value})
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
		overwritten       = trace.overwritten,
	}
}

shutdown_trace_export :: proc(vm: ^Vm, destination: []Shutdown_Trace_Event) -> int {
	if vm == nil || len(destination) == 0 {return 0}
	trace := &vm.shutdown_trace
	if trace.count == 0 || len(trace.entries) != SHUTDOWN_TRACE_CAPACITY {return 0}
	copy_count := min(len(destination), int(trace.count))
	for offset in 0 ..< copy_count {
		index := (trace.start + u32(offset)) % u32(SHUTDOWN_TRACE_CAPACITY)
		destination[offset] = trace.entries[index]
	}
	return copy_count
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
