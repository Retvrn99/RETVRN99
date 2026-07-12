// SPDX-License-Identifier: GPL-3.0-only
package hv

import "core:log"
import "core:testing"

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
	testing.expect_value(t, features.edx, u32(0x0383F9FF))
	mmx_fxsr_sse: u32 = 1 << 23 | 1 << 24 | 1 << 25
	testing.expect_value(t, features.edx & mmx_fxsr_sse, mmx_fxsr_sse)
	testing.expect_value(t, features.edx & (1 << 9 | 1 << 26 | 1 << 28), u32(0)) // APIC, SSE2, HTT

	cache := gsw_886_cpuid(2, 0)
	testing.expect_value(t, cache.eax, u32(0x03020101))
	testing.expect_value(t, cache.edx, u32(0x0C040882))
	leaves := [?]u32{3, 7, 0xD, 0x40000000, 0x80000000, 0x80000002, 0xFFFFFFFF}
	for leaf in leaves {
		testing.expect_value(t, gsw_886_cpuid(leaf, 7), Cpuid_Result{})
	}
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
