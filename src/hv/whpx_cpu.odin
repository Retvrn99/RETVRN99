// SPDX-License-Identifier: GPL-3.0-only
package hv

GSW_886_TSC_HZ :: u64(1_000_000_000)

Cpuid_Result :: struct {
	eax, ebx, ecx, edx: u32,
}

gsw_886_cpuid :: proc(function, subleaf: u32) -> Cpuid_Result {
	switch function {
	case 0:
		return {eax = 2, ebx = 0x756E6547, ecx = 0x6C65746E, edx = 0x49656E69}
	case 1:
		return {eax = 0x0000068A, ebx = 0x00000002, edx = 0x0383F9FF}
	case 2:
		return {eax = 0x03020101, edx = 0x0C040882}
	}
	return {}
}

whpx_apply_cpu_profile :: proc(part: WHV_PARTITION_HANDLE) -> bool {
	clock_hz := GSW_886_TSC_HZ
	return WHvSetPartitionProperty(part, .ProcessorClockFrequency, &clock_hz, size_of(clock_hz)) >= 0
}

whpx_handle_cpuid :: proc(
	vm: ^Vm,
	vp_ctx: ^WHV_VP_EXIT_CONTEXT,
	access: ^WHV_X64_CPUID_ACCESS_CONTEXT,
) -> bool {
	result := gsw_886_cpuid(u32(access.Rax), u32(access.Rcx))
	names := [?]WHV_REGISTER_NAME{.Rax, .Rbx, .Rcx, .Rdx, .Rip}
	values: [len(names)]WHV_REGISTER_VALUE
	values[0].Reg64 = u64(result.eax)
	values[1].Reg64 = u64(result.ebx)
	values[2].Reg64 = u64(result.ecx)
	values[3].Reg64 = u64(result.edx)
	values[4].Reg64 = vp_ctx.Rip + u64(vp_ctx.InstructionLengthCr8 & 0xF)
	return WHvSetVirtualProcessorRegisters(
		vm.part,
		0,
		&names[0],
		u32(len(names)),
		&values[0],
	) >= 0
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
	) < 0 || written != size_of(clock_hz) {
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
	) < 0 || written != size_of(counters) || counters.TotalRuntime100ns < counters.HypervisorRuntime100ns {
		return 0, false
	}
	return (counters.TotalRuntime100ns - counters.HypervisorRuntime100ns) * 100, true
}
