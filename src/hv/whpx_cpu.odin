// SPDX-License-Identifier: GPL-3.0-only
package hv

import persona "../persona"

GSW_886_TSC_HZ :: persona.GUEST_PERSONA.cpu_tsc_hz
GSW_886_THROUGHPUT_HZ :: persona.GUEST_PERSONA.cpu_throughput_hz
GSW_886_MAX_BASIC_CPUID :: u32(0x0000_000D)
GSW_886_FEATURES_EDX :: u32(0x0383_A17B)
GSW_886_EXTENDED_FEATURES_EDX :: u32(0x0183_A17B)
GSW_886_CPUID_1_EDX_SSE2 :: u32(1) << 26
GSW_886_CPUID_1_ECX_SSE3 :: u32(1) << 0
GSW_886_CPUID_1_ECX_SSSE3 :: u32(1) << 9
GSW_886_CPUID_1_ECX_SSE41 :: u32(1) << 19
GSW_886_CPUID_1_ECX_SSE42 :: u32(1) << 20
GSW_886_CPUID_1_ECX_XSAVE :: u32(1) << 26
GSW_886_CPUID_1_ECX_OSXSAVE :: u32(1) << 27
GSW_886_CPUID_1_ECX_AVX :: u32(1) << 28
GSW_886_CPUID_7_EBX_AVX2 :: u32(1) << 5
GSW_886_CPUID_1_ECX_SIMD_MASK ::
	GSW_886_CPUID_1_ECX_SSE3 |
	GSW_886_CPUID_1_ECX_SSSE3 |
	GSW_886_CPUID_1_ECX_SSE41 |
	GSW_886_CPUID_1_ECX_SSE42
GSW_886_XCR0_X87_SSE :: u32(0x3)
GSW_886_XCR0_YMM :: u32(0x4)
GSW_886_XSAVE_LEGACY_SIZE :: u32(576)
GSW_886_XSAVE_YMM_SIZE :: u32(832)

Cpuid_Result :: struct {
	eax, ebx, ecx, edx: u32,
}

gsw_886_cpuid :: proc(
	function, subleaf: u32,
	backend: Cpuid_Result,
	guest_ymm_state_enabled: bool,
) -> Cpuid_Result {
	switch function {
	case 0:
		return {
			eax = GSW_886_MAX_BASIC_CPUID,
			ebx = 0x2D57_5347,
			ecx = 0x2020_2020,
			edx = 0x2036_3838,
		}
	case 1:
		ecx := backend.ecx & GSW_886_CPUID_1_ECX_SIMD_MASK
		if backend.ecx & GSW_886_CPUID_1_ECX_XSAVE != 0 {
			ecx |= GSW_886_CPUID_1_ECX_XSAVE
			if backend.ecx & GSW_886_CPUID_1_ECX_OSXSAVE != 0 {
				ecx |= GSW_886_CPUID_1_ECX_OSXSAVE
			}
			if guest_ymm_state_enabled && backend.ecx & GSW_886_CPUID_1_ECX_AVX != 0 {
				ecx |= GSW_886_CPUID_1_ECX_AVX
			}
		}
		return {
			eax = 0x0000_0622,
			ecx = ecx,
			edx = GSW_886_FEATURES_EDX | backend.edx & GSW_886_CPUID_1_EDX_SSE2,
		}
	case 7:
		if subleaf == 0 && guest_ymm_state_enabled {
			return {ebx = backend.ebx & GSW_886_CPUID_7_EBX_AVX2}
		}
	case 0x0000_000D:
		switch subleaf {
		case 0:
			supported := backend.eax & GSW_886_XCR0_X87_SSE
			if supported != GSW_886_XCR0_X87_SSE {return {}}
			current_size := backend.ebx
			maximum_size := backend.ecx
			ymm_supported := guest_ymm_state_enabled && backend.eax & GSW_886_XCR0_YMM != 0
			if ymm_supported {
				supported |= GSW_886_XCR0_YMM
				current_size = min(current_size, GSW_886_XSAVE_YMM_SIZE)
				maximum_size = min(maximum_size, GSW_886_XSAVE_YMM_SIZE)
			} else {
				current_size = min(current_size, GSW_886_XSAVE_LEGACY_SIZE)
				maximum_size = min(maximum_size, GSW_886_XSAVE_LEGACY_SIZE)
			}
			return {eax = supported, ebx = current_size, ecx = maximum_size}
		case 2:
			if guest_ymm_state_enabled {return backend}
		}
	case 0x8000_0000:
		return {eax = 0x8000_0008}
	case 0x8000_0001:
		return {eax = 0x0000_0622, edx = GSW_886_EXTENDED_FEATURES_EDX}
	case 0x8000_0002:
		return {eax = 0x2D57_5347, ebx = 0x2036_3838, ecx = 0x7472_6956, edx = 0x206C_6175}
	case 0x8000_0003:
		return {eax = 0x636F_7250, ebx = 0x6F73_7365, ecx = 0x2020_2072, edx = 0x2020_2020}
	case 0x8000_0004:
		return {eax = 0x2020_2020, ebx = 0x2020_2020, ecx = 0x2020_2020, edx = 0x2020_2020}
	case 0x8000_0005:
		return {ecx = 0x4002_0140, edx = 0x4002_0140}
	case 0x8000_0006:
		return {ecx = 0x0200_4140}
	case 0x8000_0008:
		return {eax = 0x0000_2024}
	}
	return {}
}

whpx_apply_cpu_profile :: proc(part: WHV_PARTITION_HANDLE) -> bool {
	clock_hz := GSW_886_TSC_HZ
	return(
		WHvSetPartitionProperty(part, .ProcessorClockFrequency, &clock_hz, size_of(clock_hz)) >=
		0 \
	)
}

whpx_handle_cpuid :: proc(
	vm: ^Vm,
	vp_ctx: ^WHV_VP_EXIT_CONTEXT,
	access: ^WHV_X64_CPUID_ACCESS_CONTEXT,
) -> bool {
	backend := Cpuid_Result {
		eax = u32(access.DefaultResultRax),
		ebx = u32(access.DefaultResultRbx),
		ecx = u32(access.DefaultResultRcx),
		edx = u32(access.DefaultResultRdx),
	}
	result := gsw_886_cpuid(u32(access.Rax), u32(access.Rcx), backend, vm.guest_ymm_state_enabled)
	names := [?]WHV_REGISTER_NAME{.Rax, .Rbx, .Rcx, .Rdx, .Rip}
	values: [len(names)]WHV_REGISTER_VALUE
	values[0].Reg64 = u64(result.eax)
	values[1].Reg64 = u64(result.ebx)
	values[2].Reg64 = u64(result.ecx)
	values[3].Reg64 = u64(result.edx)
	values[4].Reg64 = vp_ctx.Rip + u64(vp_ctx.InstructionLengthCr8 & 0xF)
	return WHvSetVirtualProcessorRegisters(vm.part, 0, &names[0], u32(len(names)), &values[0]) >= 0
}

whpx_pat_valid :: proc(value: u64) -> bool {
	for i in 0 ..< 8 {
		entry := u8(value >> (8 * uint(i)))
		if entry & 0xF8 != 0 {return false}
		switch entry {
		case 0, 1, 4, 5, 6, 7:
		case:
			return false
		}
	}
	return true
}

@(private = "file")
whpx_inject_general_protection :: proc(vm: ^Vm) -> bool {
	name := WHV_REGISTER_NAME.PendingEvent
	value: WHV_REGISTER_VALUE
	value.Reg128[0] = u64(1) | u64(1) << 8 | u64(13) << 16
	return WHvSetVirtualProcessorRegisters(vm.part, 0, &name, 1, &value) >= 0
}

whpx_handle_msr :: proc(
	vm: ^Vm,
	vp_ctx: ^WHV_VP_EXIT_CONTEXT,
	access: ^WHV_X64_MSR_ACCESS_CONTEXT,
) -> bool {
	register: WHV_REGISTER_NAME
	switch access.MsrNumber {
	case 0x0000_0010:
		register = .Tsc
	case 0x0000_0277:
		register = .Pat
	case:
		return whpx_inject_general_protection(vm)
	}

	is_write := access.AccessInfo & 1 != 0
	rip := whpx_next_rip(vp_ctx)
	if is_write {
		value := (access.Rdx & 0xFFFF_FFFF) << 32 | (access.Rax & 0xFFFF_FFFF)
		if register == .Pat && !whpx_pat_valid(value) {
			return whpx_inject_general_protection(vm)
		}
		names := [?]WHV_REGISTER_NAME{register, .Rip}
		values: [len(names)]WHV_REGISTER_VALUE
		values[0].Reg64 = value
		values[1].Reg64 = rip
		return(
			WHvSetVirtualProcessorRegisters(vm.part, 0, &names[0], u32(len(names)), &values[0]) >=
			0 \
		)
	}

	msr_value: WHV_REGISTER_VALUE
	if WHvGetVirtualProcessorRegisters(vm.part, 0, &register, 1, &msr_value) < 0 {return false}
	names := [?]WHV_REGISTER_NAME{.Rax, .Rdx, .Rip}
	values: [len(names)]WHV_REGISTER_VALUE
	values[0].Reg64 = msr_value.Reg64 & 0xFFFF_FFFF
	values[1].Reg64 = msr_value.Reg64 >> 32
	values[2].Reg64 = rip
	return WHvSetVirtualProcessorRegisters(vm.part, 0, &names[0], u32(len(names)), &values[0]) >= 0
}

whpx_host_clock_hz :: proc() -> u64 {
	clock_hz: u64
	written: u32
	if WHvGetCapability(.ProcessorClockFrequency, &clock_hz, size_of(clock_hz), &written) < 0 ||
	   written != size_of(clock_hz) {
		return 0
	}
	return clock_hz
}

whpx_partition_clock_hz :: proc(vm: ^Vm) -> u64 {
	clock_hz: u64
	written: u32
	if WHvGetPartitionProperty(
		   vm.part,
		   .ProcessorClockFrequency,
		   &clock_hz,
		   size_of(clock_hz),
		   &written,
	   ) <
		   0 ||
	   written != size_of(clock_hz) {
		return 0
	}
	return clock_hz
}

whpx_guest_runtime_ns :: proc(vm: ^Vm) -> (u64, bool) {
	counters: WHV_PROCESSOR_RUNTIME_COUNTERS
	written: u32
	if WHvGetVirtualProcessorCounters(
		   vm.part,
		   0,
		   .Runtime,
		   &counters,
		   size_of(counters),
		   &written,
	   ) <
		   0 ||
	   written != size_of(counters) ||
	   counters.TotalRuntime100ns < counters.HypervisorRuntime100ns {
		return 0, false
	}
	return (counters.TotalRuntime100ns - counters.HypervisorRuntime100ns) * 100, true
}
