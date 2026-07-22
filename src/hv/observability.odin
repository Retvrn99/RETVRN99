// SPDX-License-Identifier: GPL-3.0-only
package hv

Whpx_Physical_Exit_Reason :: enum {
	None,
	Memory_Access,
	Io_Port_Access,
	Unrecoverable_Exception,
	Invalid_Vp_Register_Value,
	Unsupported_Feature,
	Interrupt_Window,
	Halt,
	Apic_Eoi,
	Msr_Access,
	Cpuid,
	Exception,
	Canceled,
	Unknown,
}

WHPX_PHYSICAL_EXIT_REASON_COUNT :: int(Whpx_Physical_Exit_Reason.Unknown) + 1
WHPX_MMIO_KIND_COUNT :: int(Whpx_Mmio_Kind.Winquake_Store_Loop) + 1

Whpx_Mmio_Fallback_Counters :: struct {
	attempts:  u64,
	successes: u64,
	failures:  u64,
}

Whpx_Graphics_Observability :: struct {
	run_calls:             u64,
	physical_exit_count:   u64,
	physical_exit_reasons: [WHPX_PHYSICAL_EXIT_REASON_COUNT]u64,
	mmio_fallbacks:        u64,
	mmio_scalar_fallbacks: u64,
	mmio_string_fallbacks: u64,
	mmio_string_chunks:    u64,
	mmio_string_elements:  u64,
	mmio_fallback_by_kind: [WHPX_MMIO_KIND_COUNT]Whpx_Mmio_Fallback_Counters,
}

@(private = "package")
whpx_physical_exit_reason :: proc(reason: WHV_RUN_VP_EXIT_REASON) -> Whpx_Physical_Exit_Reason {
	switch reason {
	case .None:
		return .None
	case .MemoryAccess:
		return .Memory_Access
	case .X64IoPortAccess:
		return .Io_Port_Access
	case .UnrecoverableException:
		return .Unrecoverable_Exception
	case .InvalidVpRegisterValue:
		return .Invalid_Vp_Register_Value
	case .UnsupportedFeature:
		return .Unsupported_Feature
	case .X64InterruptWindow:
		return .Interrupt_Window
	case .X64Halt:
		return .Halt
	case .X64ApicEoi:
		return .Apic_Eoi
	case .X64MsrAccess:
		return .Msr_Access
	case .X64Cpuid:
		return .Cpuid
	case .Exception:
		return .Exception
	case .Canceled:
		return .Canceled
	}
	return .Unknown
}

@(private = "package")
whpx_note_physical_exit :: proc(vm: ^Vm, reason: WHV_RUN_VP_EXIT_REASON) {
	if vm == nil {return}
	mapped := whpx_physical_exit_reason(reason)
	vm.physical_exit_count += 1
	vm.physical_exit_reasons[int(mapped)] += 1
}

Whpx_Mmio_Fallback_Outcome :: enum {
	Attempt,
	Success,
	Failure,
}

@(private = "package")
whpx_note_mmio_fallback :: proc(
	vm: ^Vm,
	kind: Whpx_Mmio_Kind,
	outcome: Whpx_Mmio_Fallback_Outcome,
) {
	if vm == nil {return}
	index := int(kind)
	if index < 0 || index >= WHPX_MMIO_KIND_COUNT {index = int(Whpx_Mmio_Kind.Invalid)}
	counters := &vm.mmio_fallback_by_kind[index]
	switch outcome {
	case .Attempt:
		counters.attempts += 1
	case .Success:
		counters.successes += 1
	case .Failure:
		counters.failures += 1
	}
}

whpx_graphics_observability :: proc(vm: ^Vm) -> Whpx_Graphics_Observability {
	if vm == nil {return {}}
	return {
		run_calls = vm.run_calls,
		physical_exit_count = vm.physical_exit_count,
		physical_exit_reasons = vm.physical_exit_reasons,
		mmio_fallbacks = vm.mmio_fallbacks,
		mmio_scalar_fallbacks = vm.mmio_scalar_fallbacks,
		mmio_string_fallbacks = vm.mmio_string_fallbacks,
		mmio_string_chunks = vm.mmio_string_chunks,
		mmio_string_elements = vm.mmio_string_elements,
		mmio_fallback_by_kind = vm.mmio_fallback_by_kind,
	}
}
