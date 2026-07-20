// SPDX-License-Identifier: GPL-3.0-only
package hv

import "core:fmt"

@(private = "file")
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
whpx_mmio_next_rip :: proc(vp: ^WHV_VP_EXIT_CONTEXT, instruction_length: u64) -> u64 {
	rip := vp.Rip + instruction_length
	return vp.Cs.Attributes & 0x4000 != 0 ? rip & 0xFFFF_FFFF : rip & 0xFFFF
}

@(private = "file")
whpx_mmio_rep_movs_registers :: proc(
	vm: ^Vm,
) -> (
	rax, rcx, rsi, rdi: u64,
	ds, es: WHV_X64_SEGMENT_REGISTER,
	ok: bool,
) {
	names := [?]WHV_REGISTER_NAME{.Rax, .Rcx, .Rsi, .Rdi, .Ds, .Es}
	values: [len(names)]WHV_REGISTER_VALUE
	if WHvGetVirtualProcessorRegisters(vm.part, 0, &names[0], u32(len(names)), &values[0]) < 0 {
		return
	}
	return values[0].Reg64,
		values[1].Reg64,
		values[2].Reg64,
		values[3].Reg64,
		values[4].Segment,
		values[5].Segment,
		true
}

// WHPX rejects REP MOVS when a Win9x segment base wraps the destination to VGA memory.
whpx_try_mmio_rep_movs :: proc(
	vm: ^Vm,
	vp: ^WHV_VP_EXIT_CONTEXT,
	mmio: ^WHV_MEMORY_ACCESS_CONTEXT,
) -> (
	handled, ok: bool,
	detail: string,
) {
	if vm == nil ||
	   vp == nil ||
	   mmio == nil ||
	   mmio.AccessInfo & 1 == 0 ||
	   mmio.InstructionByteCount < 2 ||
	   mmio.InstructionBytes[0] != 0xF3 ||
	   (mmio.InstructionBytes[1] != 0xA4 && mmio.InstructionBytes[1] != 0xA5) ||
	   vp.Cs.Attributes & 0x4000 == 0 ||
	   vp.Rflags & 0x400 != 0 {
		return false, false, ""
	}

	size := u8(1)
	if mmio.InstructionBytes[1] == 0xA5 {size = 4}
	rax, rcx, rsi, rdi, ds, es, regs_ok := whpx_mmio_rep_movs_registers(vm)
	if !regs_ok {return true, false, "failed to read REP MOVS register state"}
	remaining := whpx_io_low(rcx, 32)
	if remaining == 0 {
		if !whpx_io_commit(vm, rax, rcx, rsi, rdi, whpx_mmio_next_rip(vp, 2)) {
			return true, false, "failed to commit empty REP MOVS state"
		}
		return true, true, ""
	}

	if vm.io_string_begin != nil {vm.io_string_begin(vm.io_ctx)}
	defer if vm.io_string_end != nil {vm.io_string_end(vm.io_ctx)}
	initial_remaining := remaining
	limit := whpx_io_iteration_budget(vm, initial_remaining)
	user := vp.Cs.Selector & 3 == 3
	source_cache, destination_cache: Whpx_IO_Translation_Cache
	completed: u64
	vm.mmio_string_fallbacks += 1
	for completed < limit {
		source_index := whpx_io_low(rsi, 32)
		destination_index := whpx_io_low(rdi, 32)
		if fault := whpx_io_segment_fault(ds, .Ds, source_index, size, false);
		   fault.kind != .None {
			fault_ok, fault_detail := whpx_io_raise_fault(
				vm,
				fault,
				rax,
				rcx,
				rsi,
				rdi,
				vp.Rip,
				"source",
			)
			return true, fault_ok, fault_detail
		}
		if fault := whpx_io_segment_fault(es, .Es, destination_index, size, true);
		   fault.kind != .None {
			fault_ok, fault_detail := whpx_io_raise_fault(
				vm,
				fault,
				rax,
				rcx,
				rsi,
				rdi,
				vp.Rip,
				"destination",
			)
			return true, fault_ok, fault_detail
		}

		source_linear := (ds.Base + source_index) & 0xFFFF_FFFF
		destination_linear := (es.Base + destination_index) & 0xFFFF_FFFF
		page_elements := min(
			limit - completed,
			(WHPX_IO_PAGE_SIZE - (source_linear & WHPX_IO_PAGE_MASK)) / u64(size),
			(WHPX_IO_PAGE_SIZE - (destination_linear & WHPX_IO_PAGE_MASK)) / u64(size),
		)
		if page_elements == 0 {page_elements = 1}
		last_delta := (page_elements - 1) * u64(size)
		if whpx_io_segment_fault(ds, .Ds, source_index + last_delta, size, false).kind != .None ||
		   whpx_io_segment_fault(es, .Es, destination_index + last_delta, size, true).kind !=
			   .None {
			page_elements = 1
		}

		source_gpas, destination_gpas: [4]u64
		if fault := whpx_io_translate(
			vm,
			ds,
			.Ds,
			source_index,
			size,
			false,
			user,
			&source_cache,
			&source_gpas,
		); fault.kind != .None {
			fault_ok, fault_detail := whpx_io_raise_fault(
				vm,
				fault,
				rax,
				rcx,
				rsi,
				rdi,
				vp.Rip,
				"source",
			)
			return true, fault_ok, fault_detail
		}
		if fault := whpx_io_translate(
			vm,
			es,
			.Es,
			destination_index,
			size,
			true,
			user,
			&destination_cache,
			&destination_gpas,
		); fault.kind != .None {
			fault_ok, fault_detail := whpx_io_raise_fault(
				vm,
				fault,
				rax,
				rcx,
				rsi,
				rdi,
				vp.Rip,
				"destination",
			)
			return true, fault_ok, fault_detail
		}

		byte_count := page_elements * u64(size)
		source_gpa := source_gpas[0]
		destination_gpa := destination_gpas[0]
		if completed == 0 && destination_gpa != mmio.Gpa {return false, false, ""}
		if !whpx_io_ram_span_available(vm, source_gpa, byte_count) ||
		   !whpx_mmio_reserved_span_available(vm, destination_gpa, byte_count) {
			return false, false, ""
		}
		data := vm.ram[int(source_gpa):int(source_gpa + byte_count)]
		if vm.mmio != nil {vm.mmio(vm.io_ctx, destination_gpa, true, data)}
		vm.mmio_string_chunks += 1
		vm.mmio_string_elements += page_elements

		delta := page_elements * u64(size)
		rsi = whpx_io_replace_low(rsi, source_index + delta, 32)
		rdi = whpx_io_replace_low(rdi, destination_index + delta, 32)
		remaining -= page_elements
		rcx = whpx_io_replace_low(rcx, remaining, 32)
		completed += page_elements
		limit = min(limit, whpx_io_iteration_budget(vm, initial_remaining))
	}

	rip := vp.Rip
	if remaining == 0 {rip = whpx_mmio_next_rip(vp, 2)}
	if !whpx_io_commit(vm, rax, rcx, rsi, rdi, rip) {
		return true, false, "failed to commit REP MOVS register state"
	}
	return true, true, ""
}

whpx_emulate_mmio :: proc(
	vm: ^Vm,
	vp: ^WHV_VP_EXIT_CONTEXT,
	mmio: ^WHV_MEMORY_ACCESS_CONTEXT,
) -> (
	bool,
	string,
) {
	status: WHV_EMULATOR_STATUS
	hr := WHvEmulatorTryMmioEmulation(vm.emu, vm, vp, mmio, &status)
	if hr >= 0 && status.AsUINT32 & 1 != 0 {return true, ""}
	if hr >= 0 && status.AsUINT32 == 0x2 {
		if handled, ok, detail := whpx_try_mmio_rep_movs(vm, vp, mmio); handled {
			return ok, detail
		}
	}
	return false, fmt.tprintf(
		"MMIO emulation gpa=0x%x hr=0x%08x status=0x%08x ilen=%d csattr=0x%04x ins=%02x",
		mmio.Gpa,
		u32(hr),
		status.AsUINT32,
		vp.InstructionLengthCr8 & 0xF,
		vp.Cs.Attributes,
		mmio.InstructionBytes[:int(mmio.InstructionByteCount)],
	)
}
