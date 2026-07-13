// SPDX-License-Identifier: GPL-3.0-only
package hv

import "core:log"
import "core:testing"
import "core:time"

@(test)
test_gsw_886_cpuid_table :: proc(t: ^testing.T) {
	vendor := gsw_886_cpuid(0, 0)
	testing.expect_value(t, vendor.eax, u32(2))
	testing.expect_value(t, vendor.ebx, u32(0x756E6547))
	testing.expect_value(t, vendor.ecx, u32(0x6C65746E))
	testing.expect_value(t, vendor.edx, u32(0x49656E69))

	features := gsw_886_cpuid(1, 0)
	testing.expect_value(t, features.eax, u32(0x0000068A))
	testing.expect_value(t, features.ebx, u32(0x00000002))
	testing.expect_value(t, features.ecx, u32(0))
	testing.expect_value(t, features.edx, u32(0x0383A17F))
	mmx_fxsr_sse: u32 = 1 << 23 | 1 << 24 | 1 << 25
	testing.expect_value(t, features.edx & mmx_fxsr_sse, mmx_fxsr_sse)
	absent: u32 = 1 << 7 | 1 << 9 | 1 << 11 | 1 << 12 | 1 << 14 | 1 << 18 | 1 << 19 | 1 << 26
	testing.expect_value(t, features.edx & absent, u32(0))

	cache := gsw_886_cpuid(2, 0)
	testing.expect_value(t, cache.eax, u32(0x03020101))
	testing.expect_value(t, cache.edx, u32(0x0C040882))
	leaves := [?]u32{3, 7, 0xD, 0x40000000, 0x80000000, 0x80000002, 0xFFFFFFFF}
	for leaf in leaves {
		testing.expect_value(t, gsw_886_cpuid(leaf, 7), Cpuid_Result{})
	}
}

@(test)
test_gsw_886_pat_validation :: proc(t: ^testing.T) {
	testing.expect(t, whpx_pat_valid(0x0007_0406_0007_0406))
	testing.expect(t, !whpx_pat_valid(0x0007_0406_0007_0402))
	testing.expect(t, !whpx_pat_valid(0x8007_0406_0007_0406))
}

@(test)
test_whpx_gsw_886_profile :: proc(t: ^testing.T) {
	if !available() {
		log.warn("WHPX not available")
		return
	}
	vm: Vm
	if !testing.expect(t, create(&vm, 64 * 1024 * 1024)) { return }
	defer destroy(&vm)
	testing.expect_value(t, whpx_partition_clock_hz(&vm), GSW_886_TSC_HZ)

	cases := [?]struct {
		function, subleaf: u32,
		want:              Cpuid_Result,
	} {
		{0, 0, gsw_886_cpuid(0, 0)},
		{1, 0, gsw_886_cpuid(1, 0)},
		{2, 0, gsw_886_cpuid(2, 0)},
		{7, 0, {}},
		{0x80000002, 0, {}},
	}
	for c in cases {
		code: [15]u8
		code[0] = 0x66; code[1] = 0xB8
		code[2] = u8(c.function); code[3] = u8(c.function >> 8)
		code[4] = u8(c.function >> 16); code[5] = u8(c.function >> 24)
		code[6] = 0x66; code[7] = 0xB9
		code[8] = u8(c.subleaf); code[9] = u8(c.subleaf >> 8)
		code[10] = u8(c.subleaf >> 16); code[11] = u8(c.subleaf >> 24)
		code[12] = 0x0F; code[13] = 0xA2; code[14] = 0xF4
		copy(vm.ram[0x7C00:], code[:])
		set_realmode_entry(&vm, 0, 0x7C00)
		ex := run(&vm)
		if !testing.expect_value(t, ex.kind, Exit_Kind.Halt) { return }
		regs := get_regs(&vm)
		testing.expect_value(t, regs.rax, u64(c.want.eax))
		testing.expect_value(t, regs.rbx, u64(c.want.ebx))
		testing.expect_value(t, regs.rcx, u64(c.want.ecx))
		testing.expect_value(t, regs.rdx, u64(c.want.edx))
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
		0x66, 0xB9, 0x77, 0x02, 0x00, 0x00,
		0x66, 0xB8, 0x06, 0x04, 0x07, 0x00,
		0x66, 0xBA, 0x06, 0x04, 0x07, 0x00,
		0x0F, 0x30,
		0x66, 0x31, 0xC0,
		0x66, 0x31, 0xD2,
		0x0F, 0x32,
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
	vp := WHV_VP_EXIT_CONTEXT{InstructionLengthCr8 = 2, Rip = 0x7C00}
	access := WHV_X64_MSR_ACCESS_CONTEXT{MsrNumber = 0xDEAD_BEEF}
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
	if !testing.expect(t, WHvGetVirtualProcessorRegisters(vm.part, 0, &name, 1, &before) >= 0) {return}
	time.sleep(5 * time.Millisecond)
	if !testing.expect(t, WHvGetVirtualProcessorRegisters(vm.part, 0, &name, 1, &suspended) >= 0) {return}
	testing.expect_value(t, suspended.Reg64, before.Reg64)
	if !testing.expect(t, set_time_running(&vm, true)) {return}
	time.sleep(time.Millisecond)
	if !testing.expect(t, WHvGetVirtualProcessorRegisters(vm.part, 0, &name, 1, &resumed) >= 0) {return}
	testing.expect(t, resumed.Reg64 > suspended.Reg64)
}
