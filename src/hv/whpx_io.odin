// SPDX-License-Identifier: GPL-3.0-only
package hv

import "core:fmt"

WHPX_IO_STRING_BUDGET :: u64(4096)
WHPX_IO_PAGE_SIZE :: u64(4096)
WHPX_IO_PAGE_MASK :: WHPX_IO_PAGE_SIZE - 1

@(private = "package")
whpx_io_iteration_budget :: proc(vm: ^Vm, remaining: u64) -> u64 {
	budget := WHPX_IO_STRING_BUDGET
	if vm != nil && vm.io_string_budget != nil {
		budget = clamp(vm.io_string_budget(vm.io_ctx), u64(1), WHPX_IO_STRING_BUDGET)
	}
	return min(remaining, budget)
}

Whpx_IO_Fault_Kind :: enum {
	None,
	General_Protection,
	Stack,
	Page,
	Host,
}

Whpx_IO_Fault :: struct {
	kind:        Whpx_IO_Fault_Kind,
	linear:      u64,
	error_code:  u32,
	translation: WHV_TRANSLATE_GVA_RESULT_CODE,
}

Whpx_IO_Translation_Cache :: struct {
	valid:       bool,
	linear_page: u64,
	gpa_page:    u64,
	flags:       u32,
}

@(private = "file")
whpx_io_mask :: proc(size: u8) -> u32 {
	switch size {
	case 1:
		return 0xFF
	case 2:
		return 0xFFFF
	case 4:
		return 0xFFFFFFFF
	}
	return 0
}

@(private = "file")
whpx_io_low :: proc(value: u64, bits: int) -> u64 {
	return bits == 16 ? value & 0xFFFF : value & 0xFFFFFFFF
}

@(private = "file")
whpx_io_replace_low :: proc(value, low: u64, bits: int) -> u64 {
	if bits == 16 {return value & ~u64(0xFFFF) | low & 0xFFFF}
	return value & ~u64(0xFFFFFFFF) | low & 0xFFFFFFFF
}

@(private = "file")
whpx_io_address_bits :: proc(
	vp: ^WHV_VP_EXIT_CONTEXT,
	io: ^WHV_X64_IO_PORT_ACCESS_CONTEXT,
) -> int {
	bits := 32 if vp.Cs.Attributes & 0x4000 != 0 else 16
	for i in 0 ..< int(io.InstructionByteCount) {
		switch io.InstructionBytes[i] {
		case 0x67:
			return bits == 32 ? 16 : 32
		case 0x26, 0x2E, 0x36, 0x3E, 0x64, 0x65, 0x66, 0xF0, 0xF2, 0xF3:
		case:
			return bits
		}
	}
	return bits
}

@(private = "file")
whpx_io_source_segment :: proc(
	vm: ^Vm,
	io: ^WHV_X64_IO_PORT_ACCESS_CONTEXT,
) -> (
	WHV_X64_SEGMENT_REGISTER,
	WHV_REGISTER_NAME,
	bool,
) {
	name := WHV_REGISTER_NAME.Ds
	for i in 0 ..< int(io.InstructionByteCount) {
		switch io.InstructionBytes[i] {
		case 0x26:
			name = .Es
		case 0x2E:
			name = .Cs
		case 0x36:
			name = .Ss
		case 0x3E:
			name = .Ds
		case 0x64:
			name = .Fs
		case 0x65:
			name = .Gs
		case 0x66, 0x67, 0xF0, 0xF2, 0xF3:
		case:
			break
		}
	}
	if name == .Ds {return io.Ds, name, true}
	if name == .Es {return io.Es, name, true}
	value: WHV_REGISTER_VALUE
	if WHvGetVirtualProcessorRegisters(vm.part, 0, &name, 1, &value) < 0 {
		return {}, name, false
	}
	return value.Segment, name, true
}

@(private = "file")
whpx_io_segment_contains :: proc(
	segment: WHV_X64_SEGMENT_REGISTER,
	offset: u64,
	size: u8,
) -> bool {
	if size == 0 || offset > max(u64) - u64(size - 1) {return false}
	last := offset + u64(size - 1)
	segment_type := segment.Attributes & 0xF
	expand_down := segment_type & 0x8 == 0 && segment_type & 0x4 != 0
	if expand_down {
		upper := u64(0xFFFFFFFF) if segment.Attributes & 0x4000 != 0 else u64(0xFFFF)
		return offset > u64(segment.Limit) && last <= upper
	}
	return last <= u64(segment.Limit)
}

@(private = "package")
whpx_io_segment_fault :: proc(
	segment: WHV_X64_SEGMENT_REGISTER,
	name: WHV_REGISTER_NAME,
	offset: u64,
	size: u8,
	write: bool,
) -> Whpx_IO_Fault {
	kind := Whpx_IO_Fault_Kind.General_Protection
	if name == .Ss {kind = .Stack}
	type := segment.Attributes & 0xF
	descriptor := segment.Attributes & 0x10 != 0
	present := segment.Attributes & 0x80 != 0
	code := type & 0x8 != 0
	allowed := descriptor && present
	if write {
		allowed = allowed && !code && type & 0x2 != 0
	} else if code {
		allowed = allowed && type & 0x2 != 0
	}
	if !allowed || !whpx_io_segment_contains(segment, offset, size) {
		return Whpx_IO_Fault{kind = kind}
	}
	if segment.Base > max(u64) - offset || segment.Base + offset > max(u64) - u64(size - 1) {
		return Whpx_IO_Fault{kind = kind}
	}
	return {}
}

@(private = "file")
whpx_io_reserved_gpa :: proc(vm: ^Vm, gpa: u64) -> bool {
	for reservation in vm.mmio_reservations {
		if gpa >= reservation.gpa && gpa < reservation.gpa + reservation.size {
			return true
		}
	}
	return false
}

@(private = "package")
whpx_io_page_fault_error :: proc(result: WHV_TRANSLATE_GVA_RESULT_CODE, write, user: bool) -> u32 {
	error := u32(0)
	if result == .PrivilegeViolation || result == .InvalidPageTableFlags {error |= 0x1}
	if write {error |= 0x2}
	if user {error |= 0x4}
	if result == .InvalidPageTableFlags {error |= 0x8}
	return error
}

@(private = "file")
whpx_io_translate :: proc(
	vm: ^Vm,
	segment: WHV_X64_SEGMENT_REGISTER,
	segment_name: WHV_REGISTER_NAME,
	offset: u64,
	size: u8,
	write: bool,
	user: bool,
	cache: ^Whpx_IO_Translation_Cache,
	gpas: ^[4]u64,
) -> Whpx_IO_Fault {
	if fault := whpx_io_segment_fault(segment, segment_name, offset, size, write);
	   fault.kind != .None {
		return fault
	}
	linear := segment.Base + offset
	flags := u32(0x10)
	if write {flags |= 0x2} else {flags |= 0x1}
	for i in 0 ..< int(size) {
		fault_linear := linear + u64(i)
		linear_page := fault_linear &~ WHPX_IO_PAGE_MASK
		page_offset := fault_linear & WHPX_IO_PAGE_MASK
		if cache.valid && cache.linear_page == linear_page && cache.flags == flags {
			gpas[i] = cache.gpa_page + page_offset
			continue
		}
		translation: WHV_TRANSLATE_GVA_RESULT
		gpa: u64
		vm.io_string_translations += 1
		if WHvTranslateGva(vm.part, 0, fault_linear, flags, &translation, &gpa) < 0 {
			return Whpx_IO_Fault{kind = .Host, linear = fault_linear}
		}
		switch translation.ResultCode {
		case .Success:
		case .GpaUnmapped:
			if !whpx_io_reserved_gpa(vm, gpa) {
				return Whpx_IO_Fault {
					kind = .Host,
					linear = fault_linear,
					translation = translation.ResultCode,
				}
			}
		case .PageNotPresent, .PrivilegeViolation, .InvalidPageTableFlags:
			return Whpx_IO_Fault {
				kind = .Page,
				linear = fault_linear,
				error_code = whpx_io_page_fault_error(translation.ResultCode, write, user),
				translation = translation.ResultCode,
			}
		case .GpaNoReadAccess, .GpaNoWriteAccess, .GpaIllegalOverlayAccess, .Intercept:
			return Whpx_IO_Fault {
				kind = .Host,
				linear = fault_linear,
				translation = translation.ResultCode,
			}
		}
		cache.valid = true
		cache.linear_page = linear_page
		cache.gpa_page = gpa &~ WHPX_IO_PAGE_MASK
		cache.flags = flags
		gpas[i] = gpa
	}
	return {}
}

@(private = "file")
whpx_io_inject_fault :: proc(vm: ^Vm, fault: Whpx_IO_Fault) -> bool {
	vector: u16
	switch fault.kind {
	case .General_Protection:
		vector = 13
	case .Stack:
		vector = 12
	case .Page:
		vector = 14
	case .None, .Host:
		return false
	}
	pending: WHV_REGISTER_VALUE
	pending.Reg128[0] = u64(1) | u64(1) << 8 | u64(vector) << 16 | u64(fault.error_code) << 32
	pending.Reg128[1] = fault.linear
	if fault.kind == .Page {
		names := [?]WHV_REGISTER_NAME{.Cr2, .PendingEvent}
		values: [len(names)]WHV_REGISTER_VALUE
		values[0].Reg64 = fault.linear
		values[1] = pending
		return(
			WHvSetVirtualProcessorRegisters(vm.part, 0, &names[0], u32(len(names)), &values[0]) >=
			0 \
		)
	}
	name := WHV_REGISTER_NAME.PendingEvent
	return WHvSetVirtualProcessorRegisters(vm.part, 0, &name, 1, &pending) >= 0
}

@(private = "file")
whpx_io_memory_access :: proc(vm: ^Vm, gpas: ^[4]u64, size: u8, write: bool, value: ^u32) -> bool {
	start := 0
	for start < int(size) {
		end := start + 1
		for end < int(size) && gpas[end] == gpas[end - 1] + 1 {
			end += 1
		}
		mem := WHV_EMULATOR_MEMORY_ACCESS_INFO {
			GpaAddress = gpas[start],
			Direction  = write ? 1 : 0,
			AccessSize = u8(end - start),
		}
		if write {
			for i in start ..< end {
				mem.Data[i - start] = u8(value^ >> u32(8 * i))
			}
		}
		if whpx_emu_mmio(vm, &mem) < 0 {return false}
		if !write {
			for i in start ..< end {
				value^ |= u32(mem.Data[i - start]) << u32(8 * i)
			}
		}
		start = end
	}
	return true
}

whpx_next_rip :: proc(vp: ^WHV_VP_EXIT_CONTEXT) -> u64 {
	rip := vp.Rip + u64(vp.InstructionLengthCr8 & 0xF)
	return vp.Cs.Attributes & 0x4000 != 0 ? rip & 0xFFFFFFFF : rip & 0xFFFF
}

@(private = "file")
whpx_io_commit :: proc(vm: ^Vm, rax, rcx, rsi, rdi, rip: u64) -> bool {
	names := [?]WHV_REGISTER_NAME{.Rax, .Rcx, .Rsi, .Rdi, .Rip}
	values: [len(names)]WHV_REGISTER_VALUE
	values[0].Reg64 = rax
	values[1].Reg64 = rcx
	values[2].Reg64 = rsi
	values[3].Reg64 = rdi
	values[4].Reg64 = rip
	return WHvSetVirtualProcessorRegisters(vm.part, 0, &names[0], u32(len(names)), &values[0]) >= 0
}

@(private = "file")
whpx_io_commit_rip :: proc(vm: ^Vm, rip: u64) -> bool {
	name := WHV_REGISTER_NAME.Rip
	value: WHV_REGISTER_VALUE
	value.Reg64 = rip
	return WHvSetVirtualProcessorRegisters(vm.part, 0, &name, 1, &value) >= 0
}

@(private = "file")
whpx_io_commit_rax_rip :: proc(vm: ^Vm, rax, rip: u64) -> bool {
	names := [?]WHV_REGISTER_NAME{.Rax, .Rip}
	values: [len(names)]WHV_REGISTER_VALUE
	values[0].Reg64 = rax
	values[1].Reg64 = rip
	return WHvSetVirtualProcessorRegisters(vm.part, 0, &names[0], u32(len(names)), &values[0]) >= 0
}

@(private = "file")
whpx_io_raise_fault :: proc(
	vm: ^Vm,
	fault: Whpx_IO_Fault,
	rax, rcx, rsi, rdi, rip: u64,
	operand: string,
) -> (
	bool,
	string,
) {
	if !whpx_io_commit(vm, rax, rcx, rsi, rdi, rip) {
		return false, "failed to commit faulting string-I/O state"
	}
	if fault.kind == .Host {
		return false, fmt.tprintf(
			"string I/O %s translation failed at 0x%x (%v)",
			operand,
			fault.linear,
			fault.translation,
		)
	}
	if !whpx_io_inject_fault(vm, fault) {
		return false, fmt.tprintf("failed to inject string-I/O %s fault", operand)
	}
	return true, ""
}

@(private = "file")
whpx_io_read_port :: proc(vm: ^Vm, port: u16, size: u8) -> (u32, bool) {
	if vm.io_read == nil {return whpx_io_mask(size), true}
	value, ok := vm.io_read(vm.io_ctx, port, size)
	return value & whpx_io_mask(size), ok
}

@(private = "file")
whpx_io_write_port :: proc(vm: ^Vm, port: u16, size: u8, value: u32) -> bool {
	if vm.io_write == nil {return true}
	return vm.io_write(vm.io_ctx, port, size, value & whpx_io_mask(size))
}

whpx_emulate_io :: proc(
	vm: ^Vm,
	vp: ^WHV_VP_EXIT_CONTEXT,
	io: ^WHV_X64_IO_PORT_ACCESS_CONTEXT,
) -> (
	bool,
	string,
) {
	size := u8(io.AccessInfo >> 1 & 0x7)
	if size != 1 && size != 2 && size != 4 {
		return false, fmt.tprintf("invalid I/O access size %d at port 0x%04x", size, io.PortNumber)
	}
	is_write := io.AccessInfo & 0x1 != 0
	is_string := io.AccessInfo & 0x10 != 0
	has_rep := io.AccessInfo & 0x20 != 0
	if !is_string {
		rax := io.Rax
		if is_write {
			if !whpx_io_write_port(vm, io.PortNumber, size, u32(rax)) {
				return false, fmt.tprintf("I/O write rejected at port 0x%04x", io.PortNumber)
			}
			if !whpx_io_commit_rip(vm, whpx_next_rip(vp)) {
				return false, "failed to commit I/O instruction pointer"
			}
		} else {
			value, ok := whpx_io_read_port(vm, io.PortNumber, size)
			if !ok {return false, fmt.tprintf("I/O read rejected at port 0x%04x", io.PortNumber)}
			switch size {
			case 1:
				rax = rax & ~u64(0xFF) | u64(value)
			case 2:
				rax = rax & ~u64(0xFFFF) | u64(value)
			case 4:
				rax = u64(value)
			}
			if !whpx_io_commit_rax_rip(vm, rax, whpx_next_rip(vp)) {
				return false, "failed to commit I/O register state"
			}
		}
		return true, ""
	}

	address_bits := whpx_io_address_bits(vp, io)
	rax, rcx, rsi, rdi := io.Rax, io.Rcx, io.Rsi, io.Rdi
	remaining := u64(1)
	if has_rep {remaining = whpx_io_low(rcx, address_bits)}
	if remaining == 0 {
		if !whpx_io_commit(vm, rax, rcx, rsi, rdi, whpx_next_rip(vp)) {
			return false, "failed to commit empty string-I/O state"
		}
		return true, ""
	}
	segment := io.Es
	segment_name := WHV_REGISTER_NAME.Es
	if is_write {
		segment_ok: bool
		segment, segment_name, segment_ok = whpx_io_source_segment(vm, io)
		if !segment_ok {return false, "failed to read string-I/O source segment"}
	}
	user := vp.Cs.Selector & 3 == 3
	if vm.io_string_begin != nil {vm.io_string_begin(vm.io_ctx)}
	defer if vm.io_string_end != nil {vm.io_string_end(vm.io_ctx)}
	initial_remaining := remaining
	iteration_limit := whpx_io_iteration_budget(vm, initial_remaining)
	translation_cache: Whpx_IO_Translation_Cache
	completed: u64
	for completed < iteration_limit {
		index := whpx_io_low(is_write ? rsi : rdi, address_bits)
		value: u32
		gpas: [4]u64
		if is_write {
			fault := whpx_io_translate(
				vm,
				segment,
				segment_name,
				index,
				size,
				false,
				user,
				&translation_cache,
				&gpas,
			)
			if fault.kind != .None {
				return whpx_io_raise_fault(vm, fault, rax, rcx, rsi, rdi, vp.Rip, "source")
			}
			if !whpx_io_memory_access(vm, &gpas, size, false, &value) {
				_ = whpx_io_commit(vm, rax, rcx, rsi, rdi, vp.Rip)
				return false, fmt.tprintf(
					"string I/O source memory access failed at 0x%x",
					segment.Base + index,
				)
			}
			if !whpx_io_write_port(vm, io.PortNumber, size, value) {
				_ = whpx_io_commit(vm, rax, rcx, rsi, rdi, vp.Rip)
				return false, fmt.tprintf(
					"string I/O write rejected at port 0x%04x",
					io.PortNumber,
				)
			}
		} else {
			fault := whpx_io_translate(
				vm,
				segment,
				segment_name,
				index,
				size,
				true,
				user,
				&translation_cache,
				&gpas,
			)
			if fault.kind != .None {
				return whpx_io_raise_fault(vm, fault, rax, rcx, rsi, rdi, vp.Rip, "destination")
			}
			ok: bool
			value, ok = whpx_io_read_port(vm, io.PortNumber, size)
			if !ok {
				_ = whpx_io_commit(vm, rax, rcx, rsi, rdi, vp.Rip)
				return false, fmt.tprintf("string I/O read rejected at port 0x%04x", io.PortNumber)
			}
			if !whpx_io_memory_access(vm, &gpas, size, true, &value) {
				_ = whpx_io_commit(vm, rax, rcx, rsi, rdi, vp.Rip)
				return false, fmt.tprintf(
					"string I/O destination memory access failed at 0x%x",
					segment.Base + index,
				)
			}
		}
		delta := u64(size)
		if vp.Rflags & 0x400 != 0 {delta = 0 - delta}
		index = whpx_io_low(index + delta, address_bits)
		if is_write {rsi = whpx_io_replace_low(rsi, index, address_bits)} else {rdi = whpx_io_replace_low(rdi, index, address_bits)}
		if has_rep {
			remaining -= 1
			rcx = whpx_io_replace_low(rcx, remaining, address_bits)
		}
		completed += 1
		iteration_limit = min(iteration_limit, whpx_io_iteration_budget(vm, initial_remaining))
	}
	rip := vp.Rip
	if !has_rep || remaining == 0 {rip = whpx_next_rip(vp)}
	if !whpx_io_commit(vm, rax, rcx, rsi, rdi, rip) {
		return false, "failed to commit string-I/O register state"
	}
	return true, ""
}
