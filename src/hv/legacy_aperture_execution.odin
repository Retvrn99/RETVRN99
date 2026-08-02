// SPDX-License-Identifier: GPL-3.0-only
package hv

import "core:fmt"
import "core:slice"
import "core:strings"

LEGACY_APERTURE_EXECUTION_BASE :: u64(0xA0000)
LEGACY_APERTURE_EXECUTION_END :: u64(0xC0000)
LEGACY_APERTURE_HISTOGRAM_CAPACITY :: 65_536

Legacy_Aperture_Execution_Mode :: enum u8 {
	Auto,
	Scalar,
}

Legacy_Aperture_Execution_Action :: enum u8 {
	Forward,
	Handled,
	Failed,
}

Legacy_Aperture_Layout_Kind :: enum u8 {
	Unavailable,
	Indexed_Unchained,
}

Legacy_Aperture_Layout :: struct {
	kind:          Legacy_Aperture_Layout_Kind,
	width:         int,
	height:        int,
	pitch_bytes:   int,
	aperture_base: u64,
	aperture_size: u64,
}

Legacy_Aperture_Layout_Adapter :: struct {
	user_data: rawptr,
	snapshot:  proc(user_data: rawptr) -> Legacy_Aperture_Layout,
}

@(private = "file")
Legacy_Aperture_Histogram_Key :: struct {
	instruction:       [15]u8,
	instruction_count: u8,
	operation:         Whpx_Mmio_Kind,
	cs:                u16,
	rip:               u64,
	gpa:               u64,
	layout:            Legacy_Aperture_Layout,
}

@(private = "file")
Legacy_Aperture_Histogram_Entry :: struct {
	occupied: bool,
	key:      Legacy_Aperture_Histogram_Key,
	exits:    u64,
}

Legacy_Aperture_Execution :: struct {
	mode:                     Legacy_Aperture_Execution_Mode,
	memory_access_exits:      u64,
	forwarded_exits:          u64,
	handled_exits:            u64,
	executed_elements:        u64,
	layout:                   Legacy_Aperture_Layout_Adapter,
	histogram_enabled:        bool,
	histogram_collecting:     bool,
	histogram:                []Legacy_Aperture_Histogram_Entry,
	histogram_rows:           u64,
	histogram_exits:          u64,
	histogram_retained_exits: u64,
	histogram_dropped_exits:  u64,
}

Legacy_Aperture_Execution_Observability :: struct {
	mode:                     Legacy_Aperture_Execution_Mode,
	memory_access_exits:      u64,
	forwarded_exits:          u64,
	handled_exits:            u64,
	executed_elements:        u64,
	histogram_enabled:        bool,
	histogram_collecting:     bool,
	histogram_rows:           u64,
	histogram_exits:          u64,
	histogram_retained_exits: u64,
	histogram_dropped_exits:  u64,
}

@(private = "file")
Legacy_Aperture_Template_Result :: enum u8 {
	Forward,
	Handled,
	Failed,
}

@(private = "file")
LEGACY_APERTURE_COUNTED_STORE_CURRENT :: [11]u8 {
	0x89,
	0x1F,
	0x83,
	0xC6,
	0x10,
	0x83,
	0xC7,
	0x04,
	0x49,
	0x75,
	0xE7,
}

@(private = "file")
LEGACY_APERTURE_COUNTED_STORE_HEAD :: [14]u8 {
	0x8A,
	0x7E,
	0x0C,
	0x8A,
	0x5E,
	0x08,
	0xC1,
	0xE3,
	0x10,
	0x8A,
	0x7E,
	0x04,
	0x8A,
	0x1E,
}

legacy_aperture_execution_set_mode :: proc(vm: ^Vm, mode: Legacy_Aperture_Execution_Mode) {
	if vm == nil {return}
	vm.legacy_aperture_execution.mode = mode
}

legacy_aperture_execution_set_layout_adapter :: proc(
	vm: ^Vm,
	adapter: Legacy_Aperture_Layout_Adapter,
) {
	if vm == nil {return}
	vm.legacy_aperture_execution.layout = adapter
}

legacy_aperture_execution_set_histogram_enabled :: proc(vm: ^Vm, enabled: bool) -> bool {
	if vm == nil {return false}
	state := &vm.legacy_aperture_execution
	if state.histogram_enabled == enabled {return true}
	if !enabled {
		delete(state.histogram)
		state.histogram = nil
		state.histogram_enabled = false
		state.histogram_collecting = false
		state.histogram_rows = 0
		state.histogram_exits = 0
		state.histogram_retained_exits = 0
		state.histogram_dropped_exits = 0
		return true
	}
	state.histogram = make([]Legacy_Aperture_Histogram_Entry, LEGACY_APERTURE_HISTOGRAM_CAPACITY)
	state.histogram_enabled = true
	state.histogram_collecting = true
	return true
}

legacy_aperture_execution_histogram_begin :: proc(vm: ^Vm) -> bool {
	if vm == nil {return false}
	state := &vm.legacy_aperture_execution
	if !state.histogram_enabled || len(state.histogram) == 0 {return false}
	for &entry in state.histogram {entry = {}}
	state.histogram_rows = 0
	state.histogram_exits = 0
	state.histogram_retained_exits = 0
	state.histogram_dropped_exits = 0
	state.histogram_collecting = true
	return true
}

legacy_aperture_execution_histogram_end :: proc(vm: ^Vm) -> bool {
	if vm == nil || !vm.legacy_aperture_execution.histogram_enabled {return false}
	vm.legacy_aperture_execution.histogram_collecting = false
	return true
}

legacy_aperture_execution_destroy :: proc(vm: ^Vm) {
	if vm == nil {return}
	delete(vm.legacy_aperture_execution.histogram)
	vm.legacy_aperture_execution = {}
}

@(private = "file")
legacy_aperture_histogram_hash_byte :: proc(hash: u64, value: u8) -> u64 {
	return (hash ~ u64(value)) * 0x100000001B3
}

@(private = "file")
legacy_aperture_histogram_hash_u64 :: proc(hash: u64, value: u64) -> u64 {
	result := hash
	for shift in 0 ..< 8 {
		result = legacy_aperture_histogram_hash_byte(result, u8(value >> u64(shift * 8)))
	}
	return result
}

@(private = "file")
legacy_aperture_histogram_hash :: proc(key: ^Legacy_Aperture_Histogram_Key) -> u64 {
	hash := u64(0xCBF29CE484222325)
	hash = legacy_aperture_histogram_hash_byte(hash, key.instruction_count)
	for index in 0 ..< int(key.instruction_count) {
		hash = legacy_aperture_histogram_hash_byte(hash, key.instruction[index])
	}
	hash = legacy_aperture_histogram_hash_u64(hash, u64(key.operation))
	hash = legacy_aperture_histogram_hash_u64(hash, u64(key.cs))
	hash = legacy_aperture_histogram_hash_u64(hash, key.rip)
	hash = legacy_aperture_histogram_hash_u64(hash, key.gpa)
	hash = legacy_aperture_histogram_hash_u64(hash, u64(key.layout.kind))
	hash = legacy_aperture_histogram_hash_u64(hash, u64(key.layout.width))
	hash = legacy_aperture_histogram_hash_u64(hash, u64(key.layout.height))
	hash = legacy_aperture_histogram_hash_u64(hash, u64(key.layout.pitch_bytes))
	hash = legacy_aperture_histogram_hash_u64(hash, key.layout.aperture_base)
	return legacy_aperture_histogram_hash_u64(hash, key.layout.aperture_size)
}

@(private = "file")
legacy_aperture_histogram_key_equal :: proc(left, right: ^Legacy_Aperture_Histogram_Key) -> bool {
	if left.instruction_count != right.instruction_count ||
	   left.operation != right.operation ||
	   left.cs != right.cs ||
	   left.rip != right.rip ||
	   left.gpa != right.gpa ||
	   left.layout != right.layout {
		return false
	}
	for index in 0 ..< int(left.instruction_count) {
		if left.instruction[index] != right.instruction[index] {return false}
	}
	return true
}

@(private = "file")
legacy_aperture_histogram_record :: proc(
	state: ^Legacy_Aperture_Execution,
	key: Legacy_Aperture_Histogram_Key,
) {
	candidate := key
	state.histogram_exits += 1
	if len(state.histogram) == 0 {
		state.histogram_dropped_exits += 1
		return
	}
	mask := u64(len(state.histogram) - 1)
	start := legacy_aperture_histogram_hash(&candidate) & mask
	for probe in 0 ..< len(state.histogram) {
		entry := &state.histogram[int((start + u64(probe)) & mask)]
		if !entry.occupied {
			entry.occupied = true
			entry.key = candidate
			entry.exits = 1
			state.histogram_rows += 1
			state.histogram_retained_exits += 1
			return
		}
		if legacy_aperture_histogram_key_equal(&entry.key, &candidate) {
			entry.exits += 1
			state.histogram_retained_exits += 1
			return
		}
	}
	state.histogram_dropped_exits += 1
}

@(private = "file")
legacy_aperture_bytes_equal :: proc(left, right: []u8) -> bool {
	if len(left) != len(right) {return false}
	for byte, index in left {
		if byte != right[index] {return false}
	}
	return true
}

@(private = "file")
legacy_aperture_counted_store_matches :: proc(
	vm: ^Vm,
	vp: ^WHV_VP_EXIT_CONTEXT,
	bytes: []u8,
) -> bool {
	if vm == nil ||
	   vp == nil ||
	   vp.Cs.Attributes & 0x4000 == 0 ||
	   vp.Rflags & 0x100 != 0 ||
	   len(bytes) < len(LEGACY_APERTURE_COUNTED_STORE_CURRENT) ||
	   vp.Rip < u64(len(LEGACY_APERTURE_COUNTED_STORE_HEAD)) {
		return false
	}
	current := LEGACY_APERTURE_COUNTED_STORE_CURRENT
	if !legacy_aperture_bytes_equal(bytes[:len(current)], current[:]) {return false}
	head_rip := vp.Rip - u64(len(LEGACY_APERTURE_COUNTED_STORE_HEAD))
	head_linear := (vp.Cs.Base + head_rip) & 0xFFFF_FFFF
	head: [len(LEGACY_APERTURE_COUNTED_STORE_HEAD)]u8
	expected_head := LEGACY_APERTURE_COUNTED_STORE_HEAD
	return(
		whpx_linear_read(vm, head_linear, head[:]) &&
		legacy_aperture_bytes_equal(head[:], expected_head[:]) \
	)
}

@(private = "file")
legacy_aperture_layout_contains :: proc(layout: Legacy_Aperture_Layout, gpa, size: u64) -> bool {
	if layout.kind != .Indexed_Unchained ||
	   size == 0 ||
	   layout.aperture_size == 0 ||
	   layout.aperture_base > max(u64) - layout.aperture_size ||
	   gpa < layout.aperture_base ||
	   gpa > max(u64) - size {
		return false
	}
	return gpa + size <= layout.aperture_base + layout.aperture_size
}

@(private = "file")
legacy_aperture_counted_store_destination :: proc(
	vm: ^Vm,
	vp: ^WHV_VP_EXIT_CONTEXT,
	state: ^Whpx_Mmio_State,
	offset: u64,
	layout: Legacy_Aperture_Layout,
	cache: ^Whpx_IO_Translation_Cache,
	gpas: ^[4]u64,
) -> bool {
	fault := whpx_mmio_translate(vm, state, vp, .Ds, offset, 4, true, cache, gpas)
	if fault.kind != .None ||
	   gpas[1] != gpas[0] + 1 ||
	   gpas[2] != gpas[0] + 2 ||
	   gpas[3] != gpas[0] + 3 {
		return false
	}
	return(
		legacy_aperture_layout_contains(layout, gpas[0], 4) &&
		whpx_mmio_reserved_span_available(vm, gpas[0], 4) \
	)
}

@(private = "file")
legacy_aperture_counted_store_source :: proc(
	vm: ^Vm,
	vp: ^WHV_VP_EXIT_CONTEXT,
	state: ^Whpx_Mmio_State,
	offset: u64,
	cache: ^Whpx_IO_Translation_Cache,
) -> (
	u32,
	bool,
) {
	result: u32
	read_offsets := [?]u64{0, 4, 8, 12}
	for read_offset, index in read_offsets {
		gpas: [4]u64
		fault := whpx_mmio_translate(
			vm,
			state,
			vp,
			.Ds,
			offset + read_offset,
			1,
			false,
			cache,
			&gpas,
		)
		byte: [1]u8
		if fault.kind != .None || !whpx_physical_ram_read(vm, gpas[0], byte[:]) {
			return 0, false
		}
		result |= u32(byte[0]) << u32(index * 8)
	}
	return result, true
}

@(private = "package")
legacy_aperture_dec32_flags :: proc(flags: u64, before, result: u32, add_carry: bool) -> u64 {
	DEC_MASK :: u64(0x8D5)
	updated := flags & ~DEC_MASK
	if add_carry {updated |= 0x1}
	if result == 0 {updated |= 0x40}
	if result & 0x8000_0000 != 0 {updated |= 0x80}
	if (before ~ 1 ~ result) & 0x10 != 0 {updated |= 0x10}
	if before == 0x8000_0000 {updated |= 0x800}
	ones := 0
	for bit in 0 ..< 8 {
		if result & u32(1 << u32(bit)) != 0 {ones += 1}
	}
	if ones & 1 == 0 {updated |= 0x4}
	return updated
}

@(private = "file")
legacy_aperture_try_counted_store :: proc(
	vm: ^Vm,
	vp: ^WHV_VP_EXIT_CONTEXT,
	mmio: ^WHV_MEMORY_ACCESS_CONTEXT,
	bytes: []u8,
	layout: Legacy_Aperture_Layout,
) -> (
	Legacy_Aperture_Template_Result,
	u64,
	string,
) {
	if layout.kind != .Indexed_Unchained ||
	   !legacy_aperture_counted_store_matches(vm, vp, bytes) ||
	   mmio.AccessInfo & 1 == 0 {
		return .Forward, 0, ""
	}
	state, state_ok := whpx_mmio_read_state(vm)
	if !state_ok {return .Failed, 0, "failed to read counted-store register state"}
	remaining := whpx_io_low(state.gpr[1], 32)
	if remaining == 0 {return .Forward, 0, ""}
	if vm.io_string_begin != nil {vm.io_string_begin(vm.io_ctx)}
	defer if vm.io_string_end != nil {vm.io_string_end(vm.io_ctx)}
	elements := whpx_io_iteration_budget(vm, remaining)
	source := whpx_io_low(state.gpr[6], 32)
	destination := whpx_io_low(state.gpr[7], 32)
	source_cache, destination_cache: Whpx_IO_Translation_Cache
	for element in 0 ..< elements {
		destination_gpas: [4]u64
		if !legacy_aperture_counted_store_destination(
			   vm,
			   vp,
			   &state,
			   destination,
			   layout,
			   &destination_cache,
			   &destination_gpas,
		   ) ||
		   element == 0 && !whpx_mmio_validate_intercept(mmio, &destination_gpas, true) {
			return .Forward, 0, ""
		}
		if element > 0 {
			if _, source_ok := legacy_aperture_counted_store_source(
				vm,
				vp,
				&state,
				source,
				&source_cache,
			); !source_ok {
				return .Forward, 0, ""
			}
		}
		if element + 1 < elements && (source > 0xFFFF_FFEF || destination > 0xFFFF_FFFB) {
			return .Forward, 0, ""
		}
		source = (source + 16) & 0xFFFF_FFFF
		destination = (destination + 4) & 0xFFFF_FFFF
	}

	source = whpx_io_low(state.gpr[6], 32)
	destination = whpx_io_low(state.gpr[7], 32)
	value: u32 = whpx_mmio_register_read(&state, 3, 4)
	source_cache = {}
	destination_cache = {}
	for element in 0 ..< elements {
		if element > 0 {
			source_ok: bool
			value, source_ok = legacy_aperture_counted_store_source(
				vm,
				vp,
				&state,
				source,
				&source_cache,
			)
			if !source_ok {return .Failed, element, "counted-store source changed after preflight"}
			whpx_mmio_register_write(&state, 3, 4, value)
		}
		destination_gpas: [4]u64
		if !legacy_aperture_counted_store_destination(
			   vm,
			   vp,
			   &state,
			   destination,
			   layout,
			   &destination_cache,
			   &destination_gpas,
		   ) ||
		   !whpx_io_memory_access(vm, &destination_gpas, 4, true, &value) {
			return .Failed, element, "counted-store destination changed after preflight"
		}
		before_count := u32(remaining)
		add_carry := destination > 0xFFFF_FFFB
		source = (source + 16) & 0xFFFF_FFFF
		destination = (destination + 4) & 0xFFFF_FFFF
		remaining = (remaining - 1) & 0xFFFF_FFFF
		state.rflags = legacy_aperture_dec32_flags(
			state.rflags,
			before_count,
			u32(remaining),
			add_carry,
		)
	}
	state.gpr[1] = whpx_io_replace_low(state.gpr[1], remaining, 32)
	state.gpr[6] = whpx_io_replace_low(state.gpr[6], source, 32)
	state.gpr[7] = whpx_io_replace_low(state.gpr[7], destination, 32)
	next_rip := vp.Rip - u64(len(LEGACY_APERTURE_COUNTED_STORE_HEAD))
	if remaining == 0 {
		next_rip = whpx_mmio_advance_rip(vp, u8(len(LEGACY_APERTURE_COUNTED_STORE_CURRENT)))
	}
	if !whpx_mmio_commit_state(vm, &state, next_rip) {
		return .Failed, elements, "failed to commit counted-store register state"
	}
	return .Handled, elements, ""
}

legacy_aperture_execution_step :: proc(
	vm: ^Vm,
	vp: ^WHV_VP_EXIT_CONTEXT,
	mmio: ^WHV_MEMORY_ACCESS_CONTEXT,
) -> (
	Legacy_Aperture_Execution_Action,
	string,
) {
	if vm == nil || vp == nil || mmio == nil {
		return .Failed, "legacy aperture execution state unavailable"
	}
	if mmio.Gpa < LEGACY_APERTURE_EXECUTION_BASE || mmio.Gpa >= LEGACY_APERTURE_EXECUTION_END {
		return .Forward, ""
	}
	state := &vm.legacy_aperture_execution
	state.memory_access_exits += 1
	layout: Legacy_Aperture_Layout
	if state.layout.snapshot != nil {
		layout = state.layout.snapshot(state.layout.user_data)
	}
	scratch: [15]u8
	bytes: []u8
	if state.mode == .Auto || state.histogram_enabled && state.histogram_collecting {
		bytes = whpx_mmio_instruction_bytes(vm, vp, mmio, &scratch)
	}
	if state.histogram_enabled && state.histogram_collecting {
		decoded, decoded_ok, _ := whpx_decode_mmio_instruction(
			bytes,
			vp.Cs.Attributes & 0x4000 != 0,
		)
		key := Legacy_Aperture_Histogram_Key {
			instruction_count = u8(len(bytes)),
			operation         = decoded_ok ? decoded.kind : Whpx_Mmio_Kind.Invalid,
			cs                = vp.Cs.Selector,
			rip               = vp.Rip,
			gpa               = mmio.Gpa,
			layout            = layout,
		}
		copy(key.instruction[:], bytes)
		legacy_aperture_histogram_record(state, key)
	}
	if state.mode == .Auto {
		result, elements, detail := legacy_aperture_try_counted_store(vm, vp, mmio, bytes, layout)
		switch result {
		case .Handled:
			state.handled_exits += 1
			state.executed_elements += elements
			return .Handled, ""
		case .Failed:
			return .Failed, detail
		case .Forward:
		}
	}
	state.forwarded_exits += 1
	return .Forward, ""
}

legacy_aperture_execution_observability :: proc(
	vm: ^Vm,
) -> Legacy_Aperture_Execution_Observability {
	if vm == nil {return {}}
	state := &vm.legacy_aperture_execution
	return {
		mode = state.mode,
		memory_access_exits = state.memory_access_exits,
		forwarded_exits = state.forwarded_exits,
		handled_exits = state.handled_exits,
		executed_elements = state.executed_elements,
		histogram_enabled = state.histogram_enabled,
		histogram_collecting = state.histogram_collecting,
		histogram_rows = state.histogram_rows,
		histogram_exits = state.histogram_exits,
		histogram_retained_exits = state.histogram_retained_exits,
		histogram_dropped_exits = state.histogram_dropped_exits,
	}
}

@(private = "file")
legacy_aperture_histogram_entry_less :: proc(
	left, right: Legacy_Aperture_Histogram_Entry,
) -> bool {
	if left.key.instruction_count != right.key.instruction_count {
		return left.key.instruction_count < right.key.instruction_count
	}
	for index in 0 ..< int(left.key.instruction_count) {
		if left.key.instruction[index] != right.key.instruction[index] {
			return left.key.instruction[index] < right.key.instruction[index]
		}
	}
	if left.key.operation != right.key.operation {return left.key.operation < right.key.operation}
	if left.key.cs != right.key.cs {return left.key.cs < right.key.cs}
	if left.key.rip != right.key.rip {return left.key.rip < right.key.rip}
	if left.key.gpa != right.key.gpa {return left.key.gpa < right.key.gpa}
	if left.key.layout.kind !=
	   right.key.layout.kind {return left.key.layout.kind < right.key.layout.kind}
	if left.key.layout.width !=
	   right.key.layout.width {return left.key.layout.width < right.key.layout.width}
	if left.key.layout.height !=
	   right.key.layout.height {return left.key.layout.height < right.key.layout.height}
	if left.key.layout.pitch_bytes != right.key.layout.pitch_bytes {
		return left.key.layout.pitch_bytes < right.key.layout.pitch_bytes
	}
	if left.key.layout.aperture_base != right.key.layout.aperture_base {
		return left.key.layout.aperture_base < right.key.layout.aperture_base
	}
	return left.key.layout.aperture_size < right.key.layout.aperture_size
}

legacy_aperture_execution_histogram_text :: proc(vm: ^Vm) -> string {
	if vm == nil || !vm.legacy_aperture_execution.histogram_enabled {
		return ""
	}
	state := &vm.legacy_aperture_execution
	entries := make([]Legacy_Aperture_Histogram_Entry, int(state.histogram_rows))
	defer delete(entries)
	cursor := 0
	for entry in state.histogram {
		if entry.occupied {
			entries[cursor] = entry
			cursor += 1
		}
	}
	slice.sort_by(entries, legacy_aperture_histogram_entry_less)
	builder := strings.builder_make(0, 512 + len(entries) * 192, context.allocator)
	mode_name := state.mode == .Scalar ? "scalar" : "auto"
	fmt.sbprintf(
		&builder,
		"schema\tlegacy-aperture-histogram-v1\nmode\t%s\ncapacity\t%d\nrows\t%d\nexits\t%d\nretained\t%d\ndropped\t%d\n",
		mode_name,
		LEGACY_APERTURE_HISTOGRAM_CAPACITY,
		state.histogram_rows,
		state.histogram_exits,
		state.histogram_retained_exits,
		state.histogram_dropped_exits,
	)
	strings.write_string(
		&builder,
		"instruction\toperation\tcs\trip\tgpa\tlayout\twidth\theight\tpitch\taperture_base\taperture_size\texits\n",
	)
	for entry in entries {
		for index in 0 ..< int(entry.key.instruction_count) {
			fmt.sbprintf(&builder, "%02x", entry.key.instruction[index])
		}
		fmt.sbprintf(
			&builder,
			"\t%v\t%04x\t%016x\t%016x\t%v\t%d\t%d\t%d\t%016x\t%d\t%d\n",
			entry.key.operation,
			entry.key.cs,
			entry.key.rip,
			entry.key.gpa,
			entry.key.layout.kind,
			entry.key.layout.width,
			entry.key.layout.height,
			entry.key.layout.pitch_bytes,
			entry.key.layout.aperture_base,
			entry.key.layout.aperture_size,
			entry.exits,
		)
	}
	return strings.to_string(builder)
}
