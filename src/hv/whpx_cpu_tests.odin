// SPDX-License-Identifier: GPL-3.0-only
package hv

import "core:log"
import "core:testing"
import "core:time"

@(test)
test_gsw_886_cpuid_table :: proc(t: ^testing.T) {
	backend := Cpuid_Result{}
	vendor := gsw_886_cpuid(0, 0, backend, false)
	testing.expect_value(t, vendor.eax, GSW_886_MAX_BASIC_CPUID)
	testing.expect_value(t, vendor.ebx, u32(0x2D57_5347))
	testing.expect_value(t, vendor.ecx, u32(0x2020_2020))
	testing.expect_value(t, vendor.edx, u32(0x2036_3838))

	features := gsw_886_cpuid(1, 0, backend, false)
	testing.expect_value(t, features.eax, u32(0x0000_0622))
	testing.expect_value(t, features.ebx, u32(0))
	testing.expect_value(t, features.ecx, u32(0))
	testing.expect_value(t, features.edx, u32(0x0383A17B))
	mmx_fxsr_sse: u32 = 1 << 23 | 1 << 24 | 1 << 25
	testing.expect_value(t, features.edx & mmx_fxsr_sse, mmx_fxsr_sse)
	absent: u32 =
		1 << 2 | 1 << 7 | 1 << 9 | 1 << 11 | 1 << 12 | 1 << 14 | 1 << 18 | 1 << 19 | 1 << 26
	testing.expect_value(t, features.edx & absent, u32(0))

	extended := gsw_886_cpuid(0x8000_0000, 0, backend, false)
	testing.expect_value(t, extended.eax, u32(0x8000_0008))
	extended_features := gsw_886_cpuid(0x8000_0001, 0, backend, false).edx
	testing.expect_value(t, extended_features, GSW_886_EXTENDED_FEATURES_EDX)
	testing.expect_value(t, extended_features & u32(1 << 25), u32(0))
	testing.expect_value(t, gsw_886_cpuid(0x8000_0008, 0, backend, false).eax, u32(0x0000_2024))
	brand0 := gsw_886_cpuid(0x8000_0002, 0, backend, false)
	testing.expect_value(t, brand0.eax, u32(0x2D57_5347))
	testing.expect_value(t, brand0.ebx, u32(0x2036_3838))
	leaves := [?]u32{2, 3, 7, 0xD, 0x4000_0000, 0x8000_0009, 0xFFFF_FFFF}
	for leaf in leaves {
		testing.expect_value(t, gsw_886_cpuid(leaf, 7, backend, false), Cpuid_Result{})
	}
}

@(test)
test_gsw_886_cpuid_masks_backend_simd_features :: proc(t: ^testing.T) {
	backend := Cpuid_Result {
		ecx = GSW_886_CPUID_1_ECX_SIMD_MASK | GSW_886_CPUID_1_ECX_XSAVE | GSW_886_CPUID_1_ECX_OSXSAVE | GSW_886_CPUID_1_ECX_AVX | u32(1) << 30,
		edx = GSW_886_CPUID_1_EDX_SSE2 | u32(1) << 27,
	}
	features := gsw_886_cpuid(1, 0, backend, false)
	testing.expect_value(
		t,
		features.ecx,
		GSW_886_CPUID_1_ECX_SIMD_MASK | GSW_886_CPUID_1_ECX_XSAVE | GSW_886_CPUID_1_ECX_OSXSAVE,
	)
	testing.expect_value(t, features.edx, GSW_886_FEATURES_EDX | GSW_886_CPUID_1_EDX_SSE2)

	backend.ecx &= ~GSW_886_CPUID_1_ECX_OSXSAVE
	disabled_osxsave := gsw_886_cpuid(1, 0, backend, false)
	testing.expect_value(t, disabled_osxsave.ecx & GSW_886_CPUID_1_ECX_OSXSAVE, u32(0))
}

@(test)
test_gsw_886_cpuid_requires_guest_ymm_state_for_avx :: proc(t: ^testing.T) {
	leaf1_backend := Cpuid_Result {
		ecx = GSW_886_CPUID_1_ECX_XSAVE | GSW_886_CPUID_1_ECX_OSXSAVE | GSW_886_CPUID_1_ECX_AVX,
	}
	without_ymm := gsw_886_cpuid(1, 0, leaf1_backend, false)
	with_ymm := gsw_886_cpuid(1, 0, leaf1_backend, true)
	testing.expect_value(t, without_ymm.ecx & GSW_886_CPUID_1_ECX_AVX, u32(0))
	testing.expect_value(t, with_ymm.ecx & GSW_886_CPUID_1_ECX_AVX, GSW_886_CPUID_1_ECX_AVX)

	avx_without_xsave := gsw_886_cpuid(1, 0, {ecx = GSW_886_CPUID_1_ECX_AVX}, true)
	testing.expect_value(t, avx_without_xsave.ecx & GSW_886_CPUID_1_ECX_AVX, u32(0))

	leaf7_backend := Cpuid_Result {
		ebx = GSW_886_CPUID_7_EBX_AVX2 | u32(1) << 3,
	}
	testing.expect_value(t, gsw_886_cpuid(7, 0, leaf7_backend, false), Cpuid_Result{})
	testing.expect_value(
		t,
		gsw_886_cpuid(7, 0, leaf7_backend, true),
		Cpuid_Result{ebx = GSW_886_CPUID_7_EBX_AVX2},
	)
}

@(test)
test_gsw_886_cpuid_keeps_xcr0_sizing_dynamic :: proc(t: ^testing.T) {
	legacy := Cpuid_Result {
		eax = 0x207,
		ebx = 576,
		ecx = 11008,
	}
	ymm := Cpuid_Result {
		eax = 0x207,
		ebx = 11008,
		ecx = 11008,
	}
	testing.expect_value(
		t,
		gsw_886_cpuid(0xD, 0, ymm, false),
		Cpuid_Result{eax = 3, ebx = 576, ecx = 576},
	)
	testing.expect_value(
		t,
		gsw_886_cpuid(0xD, 0, legacy, true),
		Cpuid_Result{eax = 7, ebx = 576, ecx = 832},
	)
	testing.expect_value(
		t,
		gsw_886_cpuid(0xD, 0, ymm, true),
		Cpuid_Result{eax = 7, ebx = 832, ecx = 832},
	)
	testing.expect_value(
		t,
		gsw_886_cpuid(0xD, 0, {eax = 3, ebx = 11008, ecx = 11008}, true),
		Cpuid_Result{eax = 3, ebx = 576, ecx = 576},
	)

	ymm_component := Cpuid_Result {
		eax = 256,
		ebx = 576,
	}
	testing.expect_value(t, gsw_886_cpuid(0xD, 2, ymm_component, false), Cpuid_Result{})
	testing.expect_value(t, gsw_886_cpuid(0xD, 2, ymm_component, true), ymm_component)
}

@(test)
test_gsw_886_pat_validation :: proc(t: ^testing.T) {
	testing.expect(t, whpx_pat_valid(0x0007_0406_0007_0406))
	testing.expect(t, !whpx_pat_valid(0x0007_0406_0007_0402))
	testing.expect(t, !whpx_pat_valid(0x8007_0406_0007_0406))
}

@(private = "file")
whpx_test_cpuid :: proc(vm: ^Vm, function, subleaf: u32) -> (Cpuid_Result, bool) {
	code: [15]u8
	code[0] = 0x66; code[1] = 0xB8
	code[2] = u8(function); code[3] = u8(function >> 8)
	code[4] = u8(function >> 16); code[5] = u8(function >> 24)
	code[6] = 0x66; code[7] = 0xB9
	code[8] = u8(subleaf); code[9] = u8(subleaf >> 8)
	code[10] = u8(subleaf >> 16); code[11] = u8(subleaf >> 24)
	code[12] = 0x0F; code[13] = 0xA2; code[14] = 0xF4
	copy(vm.ram[0x7C00:], code[:])
	set_realmode_entry(vm, 0, 0x7C00)
	if run(vm).kind != .Halt {return {}, false}
	regs := get_regs(vm)
	return {eax = u32(regs.rax), ebx = u32(regs.rbx), ecx = u32(regs.rcx), edx = u32(regs.rdx)},
		true
}

@(test)
test_whpx_gsw_886_profile :: proc(t: ^testing.T) {
	if !available() {
		log.warn("WHPX not available")
		return
	}
	vm: Vm
	if !testing.expect(t, create(&vm, 64 * 1024 * 1024)) {return}
	defer destroy(&vm)
	testing.expect_value(t, whpx_partition_clock_hz(&vm), GSW_886_TSC_HZ)

	cases := [?]struct {
		function, subleaf: u32,
		want:              Cpuid_Result,
	} {
		{0, 0, gsw_886_cpuid(0, 0, {}, false)},
		{0x80000000, 0, gsw_886_cpuid(0x80000000, 0, {}, false)},
		{0x80000002, 0, gsw_886_cpuid(0x80000002, 0, {}, false)},
		{7, 0, {}},
	}
	for c in cases {
		got, ok := whpx_test_cpuid(&vm, c.function, c.subleaf)
		if !testing.expect(t, ok) {return}
		testing.expect_value(t, got, c.want)
	}

	features, ok := whpx_test_cpuid(&vm, 1, 0)
	if !testing.expect(t, ok) {return}
	allowed_ecx :=
		GSW_886_CPUID_1_ECX_SIMD_MASK | GSW_886_CPUID_1_ECX_XSAVE | GSW_886_CPUID_1_ECX_OSXSAVE
	allowed_edx := GSW_886_FEATURES_EDX | GSW_886_CPUID_1_EDX_SSE2
	testing.expect_value(t, features.eax, u32(0x0000_0622))
	testing.expect_value(t, features.ebx, u32(0))
	testing.expect_value(t, features.ecx & ~allowed_ecx, u32(0))
	testing.expect_value(t, features.ecx & GSW_886_CPUID_1_ECX_AVX, u32(0))
	testing.expect_value(t, features.edx & GSW_886_FEATURES_EDX, GSW_886_FEATURES_EDX)
	testing.expect_value(t, features.edx & ~allowed_edx, u32(0))

	xsave, xsave_ok := whpx_test_cpuid(&vm, 0xD, 0)
	if !testing.expect(t, xsave_ok) {return}
	testing.expect_value(t, xsave.eax & ~GSW_886_XCR0_X87_SSE, u32(0))
	testing.expect_value(t, xsave.edx, u32(0))
	testing.expect(t, xsave.ebx <= GSW_886_XSAVE_LEGACY_SIZE)
	testing.expect(t, xsave.ecx <= GSW_886_XSAVE_LEGACY_SIZE)
	if features.ecx & GSW_886_CPUID_1_ECX_XSAVE != 0 {
		testing.expect_value(t, xsave.eax, GSW_886_XCR0_X87_SSE)
	} else {
		testing.expect_value(t, xsave, Cpuid_Result{})
	}
}

@(test)
test_whpx_gsw_886_exposed_simd_executes_without_ymm :: proc(t: ^testing.T) {
	vm: Vm
	if !whpx_exception_test_create(t, &vm, true) {return}
	defer destroy(&vm)
	testing.expect(t, !vm.guest_ymm_state_enabled)

	features, features_ok := whpx_test_cpuid(&vm, 1, 0)
	if !testing.expect(t, features_ok) {return}
	testing.expect_value(
		t,
		features.ecx & GSW_886_CPUID_1_ECX_SIMD_MASK,
		GSW_886_CPUID_1_ECX_SIMD_MASK,
	)
	testing.expect_value(t, features.edx & GSW_886_CPUID_1_EDX_SSE2, GSW_886_CPUID_1_EDX_SSE2)
	testing.expect_value(t, features.ecx & GSW_886_CPUID_1_ECX_AVX, u32(0))
	leaf7, leaf7_ok := whpx_test_cpuid(&vm, 7, 0)
	if !testing.expect(t, leaf7_ok) {return}
	testing.expect_value(t, leaf7.ebx & GSW_886_CPUID_7_EBX_AVX2, u32(0))
	if !testing.expect(t, reset_cpu(&vm)) {return}

	copy(vm.ram[0x8000:], []u8{0xC6, 0x06, 0x01, 0x05, 0x06, 0xF4})
	copy(vm.ram[0x8010:], []u8{0xC6, 0x06, 0x01, 0x05, 0x0D, 0xF4})
	whpx_exception_test_write_u32(vm.ram, 6 * 4, 0x0000_8000)
	whpx_exception_test_write_u32(vm.ram, 13 * 4, 0x0000_8010)
	code := [?]u8 {
		0x66,
		0x0F,
		0xEF,
		0xC0, // PXOR xmm0,xmm0 (SSE2)
		0xF2,
		0x0F,
		0xD0,
		0xC0, // ADDSUBPS xmm0,xmm0 (SSE3)
		0x66,
		0x0F,
		0x38,
		0x00,
		0xC0, // PSHUFB xmm0,xmm0 (SSSE3)
		0x66,
		0x0F,
		0x38,
		0x17,
		0xC0, // PTEST xmm0,xmm0 (SSE4.1)
		0x66,
		0x0F,
		0x38,
		0x37,
		0xC0, // PCMPGTQ xmm0,xmm0 (SSE4.2)
		0xC6,
		0x06,
		0x00,
		0x05,
		0xA5,
		0xF4,
	}
	copy(vm.ram[0x7C00:], code[:])
	set_realmode_entry(&vm, 0, 0x7C00)

	control_names := [?]WHV_REGISTER_NAME{.Cr0, .Cr4}
	control_values: [len(control_names)]WHV_REGISTER_VALUE
	if !testing.expect(
		t,
		WHvGetVirtualProcessorRegisters(
			vm.part,
			0,
			&control_names[0],
			u32(len(control_names)),
			&control_values[0],
		) >=
		0,
	) {
		return
	}
	control_values[0].Reg64 =
		(control_values[0].Reg64 | u64(1 << 1)) &~ (u64(1 << 2) | u64(1 << 3))
	control_values[1].Reg64 = (control_values[1].Reg64 | u64(1 << 9)) &~ u64(1 << 18)
	if !testing.expect(
		t,
		WHvSetVirtualProcessorRegisters(
			vm.part,
			0,
			&control_names[0],
			u32(len(control_names)),
			&control_values[0],
		) >=
		0,
	) {
		return
	}

	exit := run(&vm)
	if !testing.expect_value(t, exit.kind, Exit_Kind.Halt) {return}
	testing.expect_value(t, exit.detail, "")
	testing.expect_value(t, vm.ram[0x500], u8(0xA5))
	testing.expect_value(t, vm.ram[0x501], u8(0))
	testing.expect_value(t, exception_trace_count(&vm), 0)
	if testing.expect(
		t,
		WHvGetVirtualProcessorRegisters(
			vm.part,
			0,
			&control_names[0],
			u32(len(control_names)),
			&control_values[0],
		) >=
		0,
	) {
		testing.expect_value(t, control_values[0].Reg64 & (u64(1 << 2) | u64(1 << 3)), u64(0))
		testing.expect(t, control_values[1].Reg64 & u64(1 << 9) != 0)
		testing.expect_value(t, control_values[1].Reg64 & u64(1 << 18), u64(0))
	}
}

@(test)
test_whpx_gsw_886_pat_msr_round_trip :: proc(t: ^testing.T) {
	if !available() {
		log.warn("WHPX not available")
		return
	}
	vm: Vm
	if !testing.expect(t, create(&vm, 64 * 1024 * 1024)) {return}
	defer destroy(&vm)

	code := [?]u8 {
		0x66,
		0xB9,
		0x77,
		0x02,
		0x00,
		0x00,
		0x66,
		0xB8,
		0x06,
		0x04,
		0x07,
		0x00,
		0x66,
		0xBA,
		0x06,
		0x04,
		0x07,
		0x00,
		0x0F,
		0x30,
		0x66,
		0x31,
		0xC0,
		0x66,
		0x31,
		0xD2,
		0x0F,
		0x32,
		0xF4,
	}
	copy(vm.ram[0x7C00:], code[:])
	set_realmode_entry(&vm, 0, 0x7C00)
	if !testing.expect_value(t, run(&vm).kind, Exit_Kind.Halt) {return}
	regs := get_regs(&vm)
	testing.expect_value(t, regs.rax, u64(0x0007_0406))
	testing.expect_value(t, regs.rdx, u64(0x0007_0406))
}

@(test)
test_whpx_unsupported_msr_injects_gp_without_advancing_rip :: proc(t: ^testing.T) {
	if !available() {
		log.warn("WHPX not available")
		return
	}
	vm: Vm
	if !testing.expect(t, create(&vm, 64 * 1024 * 1024)) {return}
	defer destroy(&vm)
	vp := WHV_VP_EXIT_CONTEXT {
		InstructionLengthCr8 = 2,
		Rip                  = 0x7C00,
	}
	access := WHV_X64_MSR_ACCESS_CONTEXT {
		MsrNumber = 0xDEAD_BEEF,
	}
	if !testing.expect(t, whpx_handle_msr(&vm, &vp, &access)) {return}

	names := [?]WHV_REGISTER_NAME{.PendingEvent, .Rip}
	values: [len(names)]WHV_REGISTER_VALUE
	if !testing.expect(
		t,
		WHvGetVirtualProcessorRegisters(vm.part, 0, &names[0], u32(len(names)), &values[0]) >= 0,
	) {return}
	testing.expect(t, values[0].Reg128[0] & 1 != 0)
	testing.expect_value(t, u8(values[0].Reg128[0] >> 16), u8(13))
	testing.expect_value(t, values[1].Reg64, u64(0xFFF0))
}

@(test)
test_whpx_partition_time_suspends_tsc :: proc(t: ^testing.T) {
	if !available() {
		log.warn("WHPX not available")
		return
	}
	vm: Vm
	if !testing.expect(t, create(&vm, 64 * 1024 * 1024)) {return}
	defer destroy(&vm)
	name := WHV_REGISTER_NAME.Tsc
	before, suspended, resumed: WHV_REGISTER_VALUE
	if !testing.expect(t, set_time_running(&vm, false)) {return}
	if !testing.expect(
		t,
		WHvGetVirtualProcessorRegisters(vm.part, 0, &name, 1, &before) >= 0,
	) {return}
	time.sleep(5 * time.Millisecond)
	if !testing.expect(
		t,
		WHvGetVirtualProcessorRegisters(vm.part, 0, &name, 1, &suspended) >= 0,
	) {return}
	testing.expect_value(t, suspended.Reg64, before.Reg64)
	if !testing.expect(t, set_time_running(&vm, true)) {return}
	time.sleep(time.Millisecond)
	if !testing.expect(
		t,
		WHvGetVirtualProcessorRegisters(vm.part, 0, &name, 1, &resumed) >= 0,
	) {return}
	testing.expect(t, resumed.Reg64 > suspended.Reg64)
}
