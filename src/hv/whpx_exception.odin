// SPDX-License-Identifier: GPL-3.0-only
package hv

import "core:fmt"

WHPX_EXCEPTION_TRACE_CAPACITY :: 32
WHPX_UD_GP_EXCEPTION_BITMAP :: u64(
	1 << u8(WHV_EXCEPTION_TYPE.InvalidOpcode) | 1 << u8(WHV_EXCEPTION_TYPE.GeneralProtection),
)

#assert(WHPX_UD_GP_EXCEPTION_BITMAP & (u64(1) << u8(WHV_EXCEPTION_TYPE.PageFault)) == 0)

whpx_configure_exception_tracing :: proc(vm: ^Vm) -> bool {
	bitmap := WHPX_UD_GP_EXCEPTION_BITMAP
	if WHvSetPartitionProperty(vm.part, .ExceptionExitBitmap, &bitmap, size_of(bitmap)) < 0 {
		return false
	}
	vm.trace_ud_gp_exits = true
	vm.exception_trace = make([dynamic]Exception_Trace_Record, 0, WHPX_EXCEPTION_TRACE_CAPACITY)
	return true
}

@(private = "file")
whpx_exception_trace_append :: proc(vm: ^Vm, record: Exception_Trace_Record) {
	if len(vm.exception_trace) < cap(vm.exception_trace) {
		append(&vm.exception_trace, record)
	} else if len(vm.exception_trace) > 0 {
		vm.exception_trace[vm.exception_count % u64(len(vm.exception_trace))] = record
	}
	vm.exception_count += 1
}

whpx_exception_trace_count :: proc(vm: ^Vm) -> int {
	return vm == nil ? 0 : len(vm.exception_trace)
}

whpx_exception_trace_record :: proc(vm: ^Vm, index: int) -> (Exception_Trace_Record, bool) {
	count := whpx_exception_trace_count(vm)
	if index < 0 || index >= count {return {}, false}
	if vm.exception_count <= u64(count) {return vm.exception_trace[index], true}
	oldest := vm.exception_count % u64(count)
	return vm.exception_trace[(int(oldest) + index) % count], true
}

@(private = "file")
whpx_reinject_exception :: proc(vm: ^Vm, exception: ^WHV_VP_EXCEPTION_CONTEXT) -> bool {
	info := exception.ExceptionInfo.AsUINT32
	deliver_error := info & 1 != 0
	software := info & 2 != 0
	name: WHV_REGISTER_NAME
	value: WHV_REGISTER_VALUE
	if software {
		name = .PendingInterruption
		value.Reg64 =
			u64(1) |
			u64(3) << 1 |
			(deliver_error ? u64(1) << 4 : 0) |
			u64(exception.InstructionByteCount & 0x0F) << 5 |
			u64(exception.ExceptionType) << 16 |
			u64(exception.ErrorCode) << 32
	} else {
		name = .PendingEvent
		value.Reg128[0] =
			u64(1) |
			(deliver_error ? u64(1) << 8 : 0) |
			u64(exception.ExceptionType) << 16 |
			u64(exception.ErrorCode) << 32
		value.Reg128[1] = exception.ExceptionParameter
	}
	return WHvSetVirtualProcessorRegisters(vm.part, 0, &name, 1, &value) >= 0
}

whpx_trace_and_reinject_exception :: proc(
	vm: ^Vm,
	vp: ^WHV_VP_EXIT_CONTEXT,
	exception: ^WHV_VP_EXCEPTION_CONTEXT,
) -> (
	ok: bool,
	detail: string,
) {
	if vm == nil || !vm.trace_ud_gp_exits {
		return false, "exception exit received while tracing is disabled"
	}
	if exception.ExceptionType != .InvalidOpcode && exception.ExceptionType != .GeneralProtection {
		return false, fmt.tprintf(
			"unexpected exception exit vector %d",
			u8(exception.ExceptionType),
		)
	}
	info := exception.ExceptionInfo.AsUINT32
	record := Exception_Trace_Record {
		vector                 = u8(exception.ExceptionType),
		error_code_valid       = info & 1 != 0,
		software_exception     = info & 2 != 0,
		instruction_byte_count = exception.InstructionByteCount,
		error_code             = exception.ErrorCode,
		exception_parameter    = exception.ExceptionParameter,
		rip                    = vp.Rip,
		rflags                 = vp.Rflags,
		instruction_bytes      = exception.InstructionBytes,
	}
	whpx_exception_trace_append(vm, record)
	if !whpx_reinject_exception(vm, exception) {
		return false, fmt.tprintf("failed to reinject exception vector %d", record.vector)
	}
	return true, ""
}
