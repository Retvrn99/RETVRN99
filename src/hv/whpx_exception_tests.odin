// SPDX-License-Identifier: GPL-3.0-only
package hv

import "core:log"
import "core:testing"

whpx_exception_test_create :: proc(t: ^testing.T, vm: ^Vm, traced: bool) -> bool {
	if !available() {
		log.warn("WHPX not available")
		return false
	}
	if traced {
		return testing.expect(
			t,
			create_with_options(vm, 64 * 1024 * 1024, {trace_ud_gp_exits = true}),
		)
	}
	return testing.expect(t, create(vm, 64 * 1024 * 1024))
}

whpx_exception_test_bitmap :: proc(t: ^testing.T, vm: ^Vm) -> (u64, bool) {
	bitmap: u64
	written: u32
	ok :=
		WHvGetPartitionProperty(
			vm.part,
			.ExceptionExitBitmap,
			&bitmap,
			size_of(bitmap),
			&written,
		) >=
		0
	if !testing.expect(t, ok) {return 0, false}
	if !testing.expect_value(t, written, u32(size_of(bitmap))) {return 0, false}
	return bitmap, true
}

whpx_exception_test_write_u32 :: proc(memory: []u8, offset: int, value: u32) {
	memory[offset] = u8(value)
	memory[offset + 1] = u8(value >> 8)
	memory[offset + 2] = u8(value >> 16)
	memory[offset + 3] = u8(value >> 24)
}

@(test)
test_whpx_exception_trace_bitmap_is_opt_in_and_excludes_pf :: proc(t: ^testing.T) {
	testing.expect_value(t, size_of(WHV_VP_EXCEPTION_INFO), 4)
	testing.expect_value(t, size_of(WHV_VP_EXCEPTION_CONTEXT), 40)

	normal: Vm
	if !whpx_exception_test_create(t, &normal, false) {return}
	if bitmap, ok := whpx_exception_test_bitmap(t, &normal); ok {
		testing.expect_value(t, bitmap, u64(0))
	}
	destroy(&normal)

	traced: Vm
	if !whpx_exception_test_create(t, &traced, true) {return}
	defer destroy(&traced)
	if bitmap, ok := whpx_exception_test_bitmap(t, &traced); ok {
		testing.expect_value(t, bitmap, WHPX_UD_GP_EXCEPTION_BITMAP)
		testing.expect_value(t, bitmap & (u64(1) << 14), u64(0))
	}
}

@(test)
test_whpx_gp_trace_reinjects_exact_pending_event :: proc(t: ^testing.T) {
	vm: Vm
	if !whpx_exception_test_create(t, &vm, true) {return}
	defer destroy(&vm)

	rip_name := WHV_REGISTER_NAME.Rip
	rip_value: WHV_REGISTER_VALUE
	rip_value.Reg64 = 0x1234
	if !testing.expect(
		t,
		WHvSetVirtualProcessorRegisters(vm.part, 0, &rip_name, 1, &rip_value) >= 0,
	) {
		return
	}
	vp := WHV_VP_EXIT_CONTEXT {
		Rip    = 0x1234,
		Rflags = 0x246,
	}
	exception := WHV_VP_EXCEPTION_CONTEXT {
		InstructionByteCount = 3,
		ExceptionInfo = {AsUINT32 = 1},
		ExceptionType = .GeneralProtection,
		ErrorCode = 0xBEEF,
		ExceptionParameter = 0x1122_3344_5566_7788,
	}
	copy(exception.InstructionBytes[:], []u8{0x0F, 0x22, 0xC0})
	ok, detail := whpx_trace_and_reinject_exception(&vm, &vp, &exception)
	testing.expect(t, ok)
	testing.expect_value(t, detail, "")

	names := [?]WHV_REGISTER_NAME{.PendingEvent, .Rip}
	values: [len(names)]WHV_REGISTER_VALUE
	if !testing.expect(
		t,
		WHvGetVirtualProcessorRegisters(vm.part, 0, &names[0], u32(len(names)), &values[0]) >= 0,
	) {
		return
	}
	want_low := u64(1) | u64(1) << 8 | u64(13) << 16 | u64(0xBEEF) << 32
	testing.expect_value(t, values[0].Reg128[0], want_low)
	testing.expect_value(t, values[0].Reg128[1], exception.ExceptionParameter)
	testing.expect_value(t, values[1].Reg64, u64(0x1234))
	testing.expect_value(t, exception_trace_count(&vm), 1)
	if record, found := exception_trace_record(&vm, 0); testing.expect(t, found) {
		testing.expect_value(t, record.vector, u8(13))
		testing.expect(t, record.error_code_valid)
		testing.expect(t, !record.software_exception)
		testing.expect_value(t, record.error_code, u32(0xBEEF))
		testing.expect_value(t, record.exception_parameter, exception.ExceptionParameter)
		testing.expect_value(t, record.rip, u64(0x1234))
		testing.expect_value(t, record.rflags, u64(0x246))
	}
}

@(test)
test_whpx_ud_exit_is_traced_reinjected_and_resumes :: proc(t: ^testing.T) {
	vm: Vm
	if !whpx_exception_test_create(t, &vm, true) {return}
	defer destroy(&vm)

	copy(
		vm.ram[0x7C00:],
		[]u8 {
			0xFA,
			0x31,
			0xC0,
			0x8E,
			0xD0,
			0xBC,
			0x00,
			0x70,
			0x0F,
			0x0B,
			0xC6,
			0x06,
			0x00,
			0x05,
			0xA6,
			0xF4,
		},
	)
	copy(
		vm.ram[0x8000:],
		[]u8{0x89, 0xE5, 0x36, 0x83, 0x46, 0x00, 0x02, 0xC6, 0x06, 0x01, 0x05, 0x06, 0xCF},
	)
	copy(vm.ram[6 * 4:], []u8{0x00, 0x80, 0x00, 0x00})
	set_realmode_entry(&vm, 0, 0x7C00)
	exit := run(&vm)
	if !testing.expect_value(t, exit.kind, Exit_Kind.Halt) {return}
	testing.expect_value(t, exit.detail, "")
	testing.expect_value(t, vm.ram[0x500], u8(0xA6))
	testing.expect_value(t, vm.ram[0x501], u8(6))
	testing.expect_value(t, exception_trace_count(&vm), 1)
	if record, found := exception_trace_record(&vm, 0); testing.expect(t, found) {
		testing.expect_value(t, record.vector, u8(6))
		testing.expect(t, !record.error_code_valid)
		testing.expect_value(t, record.rip, u64(0x7C08))
		testing.expect(t, record.instruction_byte_count >= 2)
		testing.expect_value(t, record.instruction_bytes[0], u8(0x0F))
		testing.expect_value(t, record.instruction_bytes[1], u8(0x0B))
	}
}

@(test)
test_whpx_page_fault_stays_inside_guest_with_tracing_enabled :: proc(t: ^testing.T) {
	vm: Vm
	if !whpx_exception_test_create(t, &vm, true) {return}
	defer destroy(&vm)

	whpx_exception_test_write_u32(vm.ram, 0x1000, 0x2003)
	for page in 0 ..< 1024 {
		whpx_exception_test_write_u32(vm.ram, 0x2000 + page * 4, u32(page * 0x1000) | 3)
	}
	copy(vm.ram[0x4008:], []u8{0xFF, 0xFF, 0, 0, 0, 0x9A, 0xCF, 0})
	copy(vm.ram[0x4010:], []u8{0xFF, 0xFF, 0, 0, 0, 0x92, 0xCF, 0})
	copy(vm.ram[0x3070:], []u8{0x00, 0x80, 0x08, 0x00, 0x00, 0x8E, 0x00, 0x00})
	copy(
		vm.ram[0x7000:],
		[]u8{0xA1, 0x00, 0x00, 0x40, 0x00, 0xC6, 0x05, 0x00, 0x05, 0x00, 0x00, 0x5A, 0xF4},
	)
	copy(
		vm.ram[0x8000:],
		[]u8 {
			0x83,
			0x44,
			0x24,
			0x04,
			0x05,
			0xC6,
			0x05,
			0x01,
			0x05,
			0x00,
			0x00,
			0x0E,
			0x83,
			0xC4,
			0x04,
			0xCF,
		},
	)
	code := WHV_X64_SEGMENT_REGISTER {
		Base       = 0,
		Limit      = 0xFFFF_FFFF,
		Selector   = 8,
		Attributes = 0xC09B,
	}
	data := WHV_X64_SEGMENT_REGISTER {
		Base       = 0,
		Limit      = 0xFFFF_FFFF,
		Selector   = 16,
		Attributes = 0xC093,
	}
	names := [?]WHV_REGISTER_NAME {
		.Cs,
		.Ds,
		.Es,
		.Ss,
		.Fs,
		.Gs,
		.Rip,
		.Rflags,
		.Rsp,
		.Cr0,
		.Cr3,
		.Cr4,
		.Gdtr,
		.Idtr,
	}
	values: [len(names)]WHV_REGISTER_VALUE
	values[0].Segment = code
	for i in 1 ..< 6 {values[i].Segment = data}
	values[6].Reg64 = 0x7000
	values[7].Reg64 = 0x2
	values[8].Reg64 = 0x9000
	values[9].Reg64 = 0x8000_0011
	values[10].Reg64 = 0x1000
	values[11].Reg64 = 0
	values[12].Table = {
		Limit = 0x17,
		Base  = 0x4000,
	}
	values[13].Table = {
		Limit = 0x77,
		Base  = 0x3000,
	}
	if !testing.expect(
		t,
		WHvSetVirtualProcessorRegisters(vm.part, 0, &names[0], u32(len(names)), &values[0]) >= 0,
	) {
		return
	}

	exit := run(&vm)
	if !testing.expect_value(t, exit.kind, Exit_Kind.Halt) {return}
	testing.expect_value(t, vm.ram[0x500], u8(0x5A))
	testing.expect_value(t, vm.ram[0x501], u8(14))
	testing.expect_value(t, exception_trace_count(&vm), 0)
	cr2_name := WHV_REGISTER_NAME.Cr2
	cr2: WHV_REGISTER_VALUE
	if testing.expect(t, WHvGetVirtualProcessorRegisters(vm.part, 0, &cr2_name, 1, &cr2) >= 0) {
		testing.expect_value(t, cr2.Reg64, u64(0x0040_0000))
	}
}
