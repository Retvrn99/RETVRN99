// SPDX-License-Identifier: GPL-3.0-only
package hv

import "core:fmt"

WHPX_EMULATOR_INTERNAL_FAILURE :: u32(1 << 1)
WHPX_EMULATOR_CALLBACK_FAILURES :: u32(0xFC)
WHPX_EMULATOR_NON_FALLBACK_STATUS :: u32(0x300)

@(private = "file")
whpx_mmio_instruction_bytes :: proc(
	vm: ^Vm,
	vp: ^WHV_VP_EXIT_CONTEXT,
	mmio: ^WHV_MEMORY_ACCESS_CONTEXT,
	scratch: ^[15]u8,
) -> []u8 {
	count := min(int(mmio.InstructionByteCount), len(mmio.InstructionBytes), 15)
	if count > 0 {return mmio.InstructionBytes[:count]}
	offset := vp.Cs.Attributes & 0x4000 != 0 ? vp.Rip & 0xFFFF_FFFF : vp.Rip & 0xFFFF
	linear := (vp.Cs.Base + offset) & 0xFFFF_FFFF
	for i in 0 ..< len(scratch) {
		if !whpx_linear_read(vm, linear + u64(i), scratch[i:i + 1]) {
			return scratch[:i]
		}
	}
	return scratch[:]
}

@(private = "file")
whpx_mmio_isolated_internal_failure :: proc(status: u32) -> bool {
	return(
		status & WHPX_EMULATOR_INTERNAL_FAILURE != 0 &&
		status & WHPX_EMULATOR_CALLBACK_FAILURES == 0 &&
		status & WHPX_EMULATOR_NON_FALLBACK_STATUS == 0 \
	)
}

@(private = "file")
whpx_mmio_diagnostic :: proc(
	vm: ^Vm,
	vp: ^WHV_VP_EXIT_CONTEXT,
	mmio: ^WHV_MEMORY_ACCESS_CONTEXT,
	hr: HRESULT,
	status: u32,
	width: u8,
	bytes: []u8,
	reason: string,
) -> string {
	state, _ := whpx_mmio_read_state(vm)
	direction := mmio.AccessInfo & 1 != 0 ? "write" : "read"
	return fmt.tprintf(
		"MMIO emulation rip=0x%x gva=0x%x gpa=0x%x direction=%s width=%d " +
		"hr=0x%08x status=0x%08x ilen=%d cs={sel=0x%04x base=0x%x attr=0x%04x} " +
		"ds={sel=0x%04x base=0x%x attr=0x%04x} es={sel=0x%04x base=0x%x attr=0x%04x} " +
		"ss={sel=0x%04x base=0x%x attr=0x%04x} " +
		"eax=0x%08x ecx=0x%08x edx=0x%08x ebx=0x%08x " +
		"esp=0x%08x ebp=0x%08x esi=0x%08x edi=0x%08x ins=%02x reject=%s",
		vp.Rip,
		mmio.Gva,
		mmio.Gpa,
		direction,
		width,
		u32(hr),
		status,
		vp.InstructionLengthCr8 & 0xF,
		vp.Cs.Selector,
		vp.Cs.Base,
		vp.Cs.Attributes,
		state.ds.Selector,
		state.ds.Base,
		state.ds.Attributes,
		state.es.Selector,
		state.es.Base,
		state.es.Attributes,
		state.ss.Selector,
		state.ss.Base,
		state.ss.Attributes,
		u32(state.gpr[0]),
		u32(state.gpr[1]),
		u32(state.gpr[2]),
		u32(state.gpr[3]),
		u32(state.gpr[4]),
		u32(state.gpr[5]),
		u32(state.gpr[6]),
		u32(state.gpr[7]),
		bytes,
		reason,
	)
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

	scratch: [15]u8
	bytes := whpx_mmio_instruction_bytes(vm, vp, mmio, &scratch)
	decoded, decoded_ok, reason := whpx_decode_mmio_instruction(
		bytes,
		vp.Cs.Attributes & 0x4000 != 0,
	)
	if hr >= 0 && whpx_mmio_isolated_internal_failure(status.AsUINT32) {
		kind := decoded_ok ? decoded.kind : Whpx_Mmio_Kind.Invalid
		whpx_note_mmio_fallback(vm, kind, .Attempt)
		if decoded_ok {
			ok, execute_detail := whpx_execute_mmio_fallback(vm, vp, mmio, decoded)
			if ok {
				whpx_note_mmio_fallback(vm, kind, .Success)
				vm.mmio_fallbacks += 1
				if decoded.kind == .Scalar_Load ||
				   decoded.kind == .Scalar_Store_Register ||
				   decoded.kind == .Scalar_Store_Immediate ||
				   decoded.kind == .Winquake_Store_Loop {
					vm.mmio_scalar_fallbacks += 1
				}
				return true, ""
			}
			reason = execute_detail
		}
		whpx_note_mmio_fallback(vm, kind, .Failure)
	} else if hr < 0 {
		reason = "WHvEmulatorTryMmioEmulation failed"
	} else if !whpx_mmio_isolated_internal_failure(status.AsUINT32) {
		reason = "native emulator did not report isolated internal failure"
	}

	return false, whpx_mmio_diagnostic(
		vm,
		vp,
		mmio,
		hr,
		status.AsUINT32,
		decoded.memory_width,
		bytes,
		reason,
	)
}
