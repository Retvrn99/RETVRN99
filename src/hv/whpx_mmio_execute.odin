// SPDX-License-Identifier: GPL-3.0-only
package hv

import "core:fmt"

Whpx_Mmio_State :: struct {
	gpr: [8]u64,
	ds:  WHV_X64_SEGMENT_REGISTER,
	es:  WHV_X64_SEGMENT_REGISTER,
	ss:  WHV_X64_SEGMENT_REGISTER,
	fs:  WHV_X64_SEGMENT_REGISTER,
	gs:  WHV_X64_SEGMENT_REGISTER,
	rflags: u64,
}

@(private = "package")
whpx_mmio_read_state :: proc(vm: ^Vm) -> (Whpx_Mmio_State, bool) {
	state: Whpx_Mmio_State
	names := [?]WHV_REGISTER_NAME {
		.Rax, .Rcx, .Rdx, .Rbx, .Rsp, .Rbp, .Rsi, .Rdi,
		.Ds, .Es, .Ss, .Fs, .Gs, .Rflags,
	}
	values: [len(names)]WHV_REGISTER_VALUE
	if WHvGetVirtualProcessorRegisters(vm.part, 0, &names[0], u32(len(names)), &values[0]) < 0 {
		return state, false
	}
	for i in 0 ..< 8 {state.gpr[i] = values[i].Reg64}
	state.ds = values[8].Segment
	state.es = values[9].Segment
	state.ss = values[10].Segment
	state.fs = values[11].Segment
	state.gs = values[12].Segment
	state.rflags = values[13].Reg64
	return state, true
}

@(private = "package")
whpx_mmio_commit_state :: proc(vm: ^Vm, state: ^Whpx_Mmio_State, rip: u64) -> bool {
	names := [?]WHV_REGISTER_NAME {
		.Rax, .Rcx, .Rdx, .Rbx, .Rsp, .Rbp, .Rsi, .Rdi, .Rflags, .Rip,
	}
	values: [len(names)]WHV_REGISTER_VALUE
	for i in 0 ..< 8 {values[i].Reg64 = state.gpr[i]}
	values[8].Reg64 = state.rflags
	values[9].Reg64 = rip
	return WHvSetVirtualProcessorRegisters(
		vm.part,
		0,
		&names[0],
		u32(len(names)),
		&values[0],
	) >= 0
}

@(private = "file")
whpx_mmio_segment :: proc(
	state: ^Whpx_Mmio_State,
	vp: ^WHV_VP_EXIT_CONTEXT,
	name: WHV_REGISTER_NAME,
) -> (
	WHV_X64_SEGMENT_REGISTER,
	bool,
) {
	#partial switch name {
	case .Cs:
		return vp.Cs, true
	case .Ds:
		return state.ds, true
	case .Es:
		return state.es, true
	case .Ss:
		return state.ss, true
	case .Fs:
		return state.fs, true
	case .Gs:
		return state.gs, true
	}
	return {}, false
}

@(private = "package")
whpx_mmio_register_read :: proc(state: ^Whpx_Mmio_State, register, width: u8) -> u32 {
	if width == 1 && register >= 4 {
		return u32(state.gpr[register - 4] >> 8) & 0xFF
	}
	switch width {
	case 1:
		return u32(state.gpr[register]) & 0xFF
	case 2:
		return u32(state.gpr[register]) & 0xFFFF
	case 4:
		return u32(state.gpr[register])
	}
	return 0
}

@(private = "package")
whpx_mmio_register_write :: proc(
	state: ^Whpx_Mmio_State,
	register, width: u8,
	value: u32,
) {
	if width == 1 && register >= 4 {
		index := register - 4
		state.gpr[index] = state.gpr[index] & ~u64(0xFF00) | u64(value & 0xFF) << 8
		return
	}
	switch width {
	case 1:
		state.gpr[register] = state.gpr[register] & ~u64(0xFF) | u64(value & 0xFF)
	case 2:
		state.gpr[register] = state.gpr[register] & ~u64(0xFFFF) | u64(value & 0xFFFF)
	case 4:
		state.gpr[register] = u64(value)
	}
}

@(private = "file")
whpx_mmio_extend :: proc(value: u32, source_width, destination_width: u8, mode: Whpx_Mmio_Extension) -> u32 {
	if mode == .None || mode == .Zero {return value & whpx_io_mask(source_width)}
	if source_width == 1 && value & 0x80 != 0 {
		return destination_width == 2 ? value | 0xFF00 : value | 0xFFFF_FF00
	}
	if source_width == 2 && value & 0x8000 != 0 {return value | 0xFFFF_0000}
	return value & whpx_io_mask(source_width)
}

@(private = "file")
whpx_mmio_effective_offset :: proc(state: ^Whpx_Mmio_State, address: Whpx_Mmio_Address) -> u64 {
	offset := address.displacement
	if address.base_present {
		offset += whpx_io_low(state.gpr[address.base_register], address.address_bits)
	}
	if address.index_present {
		offset += whpx_io_low(state.gpr[address.index_register], address.address_bits) *
			u64(address.scale)
	}
	return whpx_io_low(offset, address.address_bits)
}

@(private = "package")
whpx_mmio_advance_rip :: proc(vp: ^WHV_VP_EXIT_CONTEXT, length: u8) -> u64 {
	rip := vp.Rip + u64(length)
	return vp.Cs.Attributes & 0x4000 != 0 ? rip & 0xFFFF_FFFF : rip & 0xFFFF
}

@(private = "package")
whpx_mmio_translate :: proc(
	vm: ^Vm,
	state: ^Whpx_Mmio_State,
	vp: ^WHV_VP_EXIT_CONTEXT,
	segment_name: WHV_REGISTER_NAME,
	offset: u64,
	width: u8,
	write: bool,
	cache: ^Whpx_IO_Translation_Cache,
	gpas: ^[4]u64,
) -> Whpx_IO_Fault {
	segment, ok := whpx_mmio_segment(state, vp, segment_name)
	if !ok {return Whpx_IO_Fault{kind = .Host}}
	return whpx_io_translate(
		vm,
		segment,
		segment_name,
		offset,
		width,
		write,
		vp.Cs.Selector & 3 == 3,
		cache,
		gpas,
	)
}

@(private = "file")
whpx_mmio_fault_detail :: proc(
	vm: ^Vm,
	fault: Whpx_IO_Fault,
	operand: string,
) -> (
	bool,
	string,
) {
	if fault.kind == .Host {
		return false, fmt.tprintf(
			"%s translation failed at gva=0x%x result=%v",
			operand,
			fault.linear,
			fault.translation,
		)
	}
	if !whpx_io_inject_fault(vm, fault) {
		return false, fmt.tprintf("failed to inject %s fault", operand)
	}
	return true, ""
}

@(private = "package")
whpx_mmio_validate_intercept :: proc(
	mmio: ^WHV_MEMORY_ACCESS_CONTEXT,
	gpas: ^[4]u64,
	write: bool,
) -> bool {
	return mmio.AccessInfo & 1 != 0 == write && gpas[0] == mmio.Gpa
}

@(private = "package")
whpx_mmio_reserved_span_available :: proc(vm: ^Vm, gpa, size: u64) -> bool {
	if size == 0 || gpa > max(u64) - size {return false}
	for reservation in vm.mmio_reservations {
		if reservation.kind == .Mmio &&
		   gpa >= reservation.gpa &&
		   gpa + size <= reservation.gpa + reservation.size {
			return true
		}
	}
	return false
}

@(private = "file")
whpx_mmio_try_movs_chunk :: proc(
	vm: ^Vm,
	vp: ^WHV_VP_EXIT_CONTEXT,
	decoded: Whpx_Mmio_Instruction,
	state: ^Whpx_Mmio_State,
	source_index, destination_index: u64,
	source_gpas, destination_gpas: ^[4]u64,
	element_limit: u64,
	intercept_write: bool,
) -> (
	u64,
	bool,
	bool,
) {
	if decoded.kind != .Movs || vp.Rflags & 0x400 != 0 || element_limit == 0 {
		return 0, false, true
	}
	source_segment, source_ok := whpx_mmio_segment(state, vp, decoded.address.segment)
	destination_segment, destination_ok := whpx_mmio_segment(state, vp, .Es)
	if !source_ok || !destination_ok {return 0, false, true}
	source_linear := (source_segment.Base + source_index) & 0xFFFF_FFFF
	destination_linear := (destination_segment.Base + destination_index) & 0xFFFF_FFFF
	elements := min(
		element_limit,
		(WHPX_IO_PAGE_SIZE - (source_linear & WHPX_IO_PAGE_MASK)) /
			u64(decoded.memory_width),
		(WHPX_IO_PAGE_SIZE - (destination_linear & WHPX_IO_PAGE_MASK)) /
			u64(decoded.memory_width),
	)
	if elements == 0 {return 0, false, true}
	last_delta := (elements - 1) * u64(decoded.memory_width)
	address_mask := decoded.address.address_bits == 16 ? u64(0xFFFF) : u64(0xFFFF_FFFF)
	if source_index > address_mask - min(address_mask, last_delta) ||
	   destination_index > address_mask - min(address_mask, last_delta) ||
	   whpx_io_segment_fault(
		   source_segment,
		   decoded.address.segment,
		   source_index + last_delta,
		   decoded.memory_width,
		   false,
	   ).kind != .None ||
	   whpx_io_segment_fault(
		   destination_segment,
		   .Es,
		   destination_index + last_delta,
		   decoded.memory_width,
		   true,
	   ).kind != .None {
		return 0, false, true
	}
	byte_count := elements * u64(decoded.memory_width)
	source_gpa := source_gpas[0]
	destination_gpa := destination_gpas[0]
	if intercept_write {
		if !whpx_io_ram_span_available(vm, source_gpa, byte_count) ||
		   !whpx_mmio_reserved_span_available(vm, destination_gpa, byte_count) {
			return 0, false, true
		}
		data := vm.ram[int(source_gpa):int(source_gpa + byte_count)]
		if vm.mmio != nil {vm.mmio(vm.io_ctx, destination_gpa, true, data)}
	} else {
		if !whpx_mmio_reserved_span_available(vm, source_gpa, byte_count) ||
		   !whpx_io_ram_span_available(vm, destination_gpa, byte_count) {
			return 0, false, true
		}
		data := vm.ram[int(destination_gpa):int(destination_gpa + byte_count)]
		if vm.mmio != nil {vm.mmio(vm.io_ctx, source_gpa, false, data)}
	}
	return elements, true, true
}

@(private = "file")
whpx_execute_scalar_mmio :: proc(
	vm: ^Vm,
	vp: ^WHV_VP_EXIT_CONTEXT,
	mmio: ^WHV_MEMORY_ACCESS_CONTEXT,
	decoded: Whpx_Mmio_Instruction,
) -> (
	bool,
	string,
) {
	state, state_ok := whpx_mmio_read_state(vm)
	if !state_ok {return false, "failed to read MMIO register state"}
	write := decoded.kind != .Scalar_Load
	offset := whpx_mmio_effective_offset(&state, decoded.address)
	cache: Whpx_IO_Translation_Cache
	gpas: [4]u64
	fault := whpx_mmio_translate(
		vm,
		&state,
		vp,
		decoded.address.segment,
		offset,
		decoded.memory_width,
		write,
		&cache,
		&gpas,
	)
	if fault.kind != .None {return whpx_mmio_fault_detail(vm, fault, "MMIO operand")}
	if !whpx_mmio_validate_intercept(mmio, &gpas, write) {
		return false, fmt.tprintf(
			"decoded MMIO operand mismatch gpa=0x%x direction=%s",
			gpas[0],
			write ? "write" : "read",
		)
	}
	value: u32
	#partial switch decoded.kind {
	case .Scalar_Load:
		if !whpx_io_memory_access(vm, &gpas, decoded.memory_width, false, &value) {
			return false, "MMIO read failed"
		}
		value = whpx_mmio_extend(
			value,
			decoded.memory_width,
			decoded.register_width,
			decoded.extension,
		)
		whpx_mmio_register_write(&state, decoded.register, decoded.register_width, value)
	case .Scalar_Store_Register:
		value = whpx_mmio_register_read(&state, decoded.register, decoded.memory_width)
		if !whpx_io_memory_access(vm, &gpas, decoded.memory_width, true, &value) {
			return false, "MMIO write failed"
		}
	case .Scalar_Store_Immediate:
		value = decoded.immediate
		if !whpx_io_memory_access(vm, &gpas, decoded.memory_width, true, &value) {
			return false, "MMIO immediate write failed"
		}
	case:
		return false, "invalid scalar MMIO operation"
	}
	if !whpx_mmio_commit_state(vm, &state, whpx_mmio_advance_rip(vp, decoded.length)) {
		return false, "failed to commit scalar MMIO state"
	}
	return true, ""
}

@(private = "file")
whpx_mmio_string_fault :: proc(
	vm: ^Vm,
	state: ^Whpx_Mmio_State,
	vp: ^WHV_VP_EXIT_CONTEXT,
	fault: Whpx_IO_Fault,
	operand: string,
) -> (
	bool,
	string,
) {
	if !whpx_mmio_commit_state(vm, state, vp.Rip) {
		return false, "failed to commit faulting MMIO string state"
	}
	return whpx_mmio_fault_detail(vm, fault, operand)
}

@(private = "file")
whpx_execute_string_mmio :: proc(
	vm: ^Vm,
	vp: ^WHV_VP_EXIT_CONTEXT,
	mmio: ^WHV_MEMORY_ACCESS_CONTEXT,
	decoded: Whpx_Mmio_Instruction,
) -> (
	bool,
	string,
) {
	state, state_ok := whpx_mmio_read_state(vm)
	if !state_ok {return false, "failed to read MMIO string register state"}
	address_bits := decoded.address.address_bits
	remaining := u64(1)
	if decoded.rep {remaining = whpx_io_low(state.gpr[1], address_bits)}
	if remaining == 0 {
		if !whpx_mmio_commit_state(vm, &state, whpx_mmio_advance_rip(vp, decoded.length)) {
			return false, "failed to commit empty MMIO string state"
		}
		return true, ""
	}

	if vm.io_string_begin != nil {vm.io_string_begin(vm.io_ctx)}
	defer if vm.io_string_end != nil {vm.io_string_end(vm.io_ctx)}
	initial_remaining := remaining
	limit := whpx_io_iteration_budget(vm, initial_remaining)
	source_cache, destination_cache: Whpx_IO_Translation_Cache
	completed: u64
	vm.mmio_string_fallbacks += 1
	for completed < limit {
		source_index := whpx_io_low(state.gpr[6], address_bits)
		destination_index := whpx_io_low(state.gpr[7], address_bits)
		source_gpas, destination_gpas: [4]u64
		if decoded.kind == .Movs || decoded.kind == .Lods {
			fault := whpx_mmio_translate(
				vm,
				&state,
				vp,
				decoded.address.segment,
				source_index,
				decoded.memory_width,
				false,
				&source_cache,
				&source_gpas,
			)
			if fault.kind != .None {
				return whpx_mmio_string_fault(vm, &state, vp, fault, "MMIO string source")
			}
		}
		if decoded.kind == .Movs || decoded.kind == .Stos {
			fault := whpx_mmio_translate(
				vm,
				&state,
				vp,
				.Es,
				destination_index,
				decoded.memory_width,
				true,
				&destination_cache,
				&destination_gpas,
			)
			if fault.kind != .None {
				return whpx_mmio_string_fault(vm, &state, vp, fault, "MMIO string destination")
			}
		}

		if completed == 0 {
			intercept_ok := false
			#partial switch decoded.kind {
			case .Movs:
				intercept_ok = whpx_mmio_validate_intercept(
					mmio,
					mmio.AccessInfo & 1 != 0 ? &destination_gpas : &source_gpas,
					mmio.AccessInfo & 1 != 0,
				)
			case .Stos:
				intercept_ok = whpx_mmio_validate_intercept(mmio, &destination_gpas, true)
			case .Lods:
				intercept_ok = whpx_mmio_validate_intercept(mmio, &source_gpas, false)
			}
			if !intercept_ok {return false, "decoded MMIO string operand mismatch"}
		}
		if decoded.kind == .Movs {
			chunk_limit := limit - completed
			if decoded.rep {chunk_limit = min(chunk_limit, remaining)} else {chunk_limit = 1}
			chunk, handled, chunk_ok := whpx_mmio_try_movs_chunk(
				vm,
				vp,
				decoded,
				&state,
				source_index,
				destination_index,
				&source_gpas,
				&destination_gpas,
				chunk_limit,
				mmio.AccessInfo & 1 != 0,
			)
			if handled {
				if !chunk_ok {return false, "MMIO MOVS chunk failed"}
				delta := chunk * u64(decoded.memory_width)
				state.gpr[6] = whpx_io_replace_low(
					state.gpr[6],
					whpx_io_low(source_index + delta, address_bits),
					address_bits,
				)
				state.gpr[7] = whpx_io_replace_low(
					state.gpr[7],
					whpx_io_low(destination_index + delta, address_bits),
					address_bits,
				)
				if decoded.rep {
					remaining -= chunk
					state.gpr[1] = whpx_io_replace_low(state.gpr[1], remaining, address_bits)
				}
				completed += chunk
				vm.mmio_string_chunks += 1
				vm.mmio_string_elements += chunk
				limit = min(limit, whpx_io_iteration_budget(vm, initial_remaining))
				continue
			}
		}

		value: u32
		#partial switch decoded.kind {
		case .Movs:
			if !whpx_io_memory_access(vm, &source_gpas, decoded.memory_width, false, &value) {
				return false, "MMIO MOVS source read failed"
			}
			if !whpx_io_memory_access(vm, &destination_gpas, decoded.memory_width, true, &value) {
				return false, "MMIO MOVS destination write failed"
			}
		case .Stos:
			value = whpx_mmio_register_read(&state, 0, decoded.memory_width)
			if !whpx_io_memory_access(vm, &destination_gpas, decoded.memory_width, true, &value) {
				return false, "MMIO STOS write failed"
			}
		case .Lods:
			if !whpx_io_memory_access(vm, &source_gpas, decoded.memory_width, false, &value) {
				return false, "MMIO LODS read failed"
			}
			whpx_mmio_register_write(&state, 0, decoded.memory_width, value)
		}

		delta := u64(decoded.memory_width)
		if vp.Rflags & 0x400 != 0 {delta = 0 - delta}
		if decoded.kind == .Movs || decoded.kind == .Lods {
			state.gpr[6] = whpx_io_replace_low(
				state.gpr[6],
				whpx_io_low(source_index + delta, address_bits),
				address_bits,
			)
		}
		if decoded.kind == .Movs || decoded.kind == .Stos {
			state.gpr[7] = whpx_io_replace_low(
				state.gpr[7],
				whpx_io_low(destination_index + delta, address_bits),
				address_bits,
			)
		}
		if decoded.rep {
			remaining -= 1
			state.gpr[1] = whpx_io_replace_low(state.gpr[1], remaining, address_bits)
		}
		completed += 1
		vm.mmio_string_chunks += 1
		vm.mmio_string_elements += 1
		limit = min(limit, whpx_io_iteration_budget(vm, initial_remaining))
	}

	rip := vp.Rip
	if !decoded.rep || remaining == 0 {rip = whpx_mmio_advance_rip(vp, decoded.length)}
	if !whpx_mmio_commit_state(vm, &state, rip) {
		return false, "failed to commit MMIO string state"
	}
	return true, ""
}

whpx_execute_mmio_fallback :: proc(
	vm: ^Vm,
	vp: ^WHV_VP_EXIT_CONTEXT,
	mmio: ^WHV_MEMORY_ACCESS_CONTEXT,
	decoded: Whpx_Mmio_Instruction,
) -> (
	bool,
	string,
) {
	#partial switch decoded.kind {
	case .Scalar_Load, .Scalar_Store_Register, .Scalar_Store_Immediate:
		return whpx_execute_scalar_mmio(vm, vp, mmio, decoded)
	case .Movs, .Stos, .Lods:
		return whpx_execute_string_mmio(vm, vp, mmio, decoded)
	case:
		return false, "invalid MMIO fallback operation"
	}
}
