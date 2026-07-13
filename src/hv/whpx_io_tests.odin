// SPDX-License-Identifier: GPL-3.0-only
package hv

import "core:log"
import "core:testing"

@(test)
test_whpx_io_page_fault_error_codes :: proc(t: ^testing.T) {
	testing.expect_value(t, whpx_io_page_fault_error(.PageNotPresent, false, false), u32(0))
	testing.expect_value(t, whpx_io_page_fault_error(.PageNotPresent, true, true), u32(0x6))
	testing.expect_value(t, whpx_io_page_fault_error(.PrivilegeViolation, false, true), u32(0x5))
	testing.expect_value(t, whpx_io_page_fault_error(.InvalidPageTableFlags, true, false), u32(0xB))
}

@(test)
test_whpx_io_segment_fault_classification :: proc(t: ^testing.T) {
	data := WHV_X64_SEGMENT_REGISTER {
		Limit      = 0xFFFF,
		Selector   = 0x10,
		Attributes = 0x0093,
	}
	testing.expect_value(
		t,
		whpx_io_segment_fault(data, .Es, 0xFFFF, 1, true).kind,
		Whpx_IO_Fault_Kind.None,
	)
	testing.expect_value(
		t,
		whpx_io_segment_fault(data, .Es, 0xFFFF, 2, true).kind,
		Whpx_IO_Fault_Kind.General_Protection,
	)
	testing.expect_value(
		t,
		whpx_io_segment_fault(data, .Ss, 0xFFFF, 2, false).kind,
		Whpx_IO_Fault_Kind.Stack,
	)
	read_only := data
	read_only.Attributes = 0x0091
	testing.expect_value(
		t,
		whpx_io_segment_fault(read_only, .Es, 0, 1, true).kind,
		Whpx_IO_Fault_Kind.General_Protection,
	)
	execute_only := data
	execute_only.Attributes = 0x0099
	testing.expect_value(
		t,
		whpx_io_segment_fault(execute_only, .Ds, 0, 1, false).kind,
		Whpx_IO_Fault_Kind.General_Protection,
	)
}

@(test)
test_whpx_manual_page_fault_preserves_rep_progress :: proc(t: ^testing.T) {
	if !available() {
		log.warn("WHPX not available")
		return
	}
	vm: Vm
	if !testing.expect(t, create(&vm, 64 * 1024 * 1024)) {return}
	defer destroy(&vm)

	whpx_test_write_u32(vm.ram, 0x1000, 0x2003)
	whpx_test_write_u32(vm.ram, 0x2000 + 2 * 4, 0x5003)
	vm.ram[0x5FFF] = 0xA5
	vp: WHV_VP_EXIT_CONTEXT
	io: WHV_X64_IO_PORT_ACCESS_CONTEXT
	if !whpx_test_manual_io_context(t, &vm, &vp, &io, 0, 2, 0x2FFF, 0, 0x7500, 0x2) {
		return
	}
	whpx_test_manual_io_instruction(&vp, &io, []u8{0xF3, 0x6E}, 0x33, 0x6789)
	names := [?]WHV_REGISTER_NAME{.Cr3, .Cr0}
	values: [len(names)]WHV_REGISTER_VALUE
	values[0].Reg64 = 0x1000
	values[1].Reg64 = 0x80000011
	if !testing.expect(
		t,
		WHvSetVirtualProcessorRegisters(vm.part, 0, &names[0], u32(len(names)), &values[0]) >= 0,
	) {return}
	probe: Whpx_Test_Probe
	vm.io_ctx = &probe
	vm.io_write = whpx_test_io_write

	ok, detail := whpx_emulate_io(&vm, &vp, &io)
	testing.expect(t, ok)
	testing.expect_value(t, detail, "")
	testing.expect_value(t, probe.io_count, 1)
	testing.expect_value(t, probe.io_values[0], u8(0xA5))
	regs := get_regs(&vm)
	testing.expect_value(t, regs.rsi, u64(0x3000))
	testing.expect_value(t, regs.rcx, u64(1))
	testing.expect_value(t, regs.rip, u64(0x7500))
	fault_names := [?]WHV_REGISTER_NAME{.Cr2, .PendingEvent}
	fault: [len(fault_names)]WHV_REGISTER_VALUE
	if !testing.expect(
		t,
		WHvGetVirtualProcessorRegisters(
			vm.part,
			0,
			&fault_names[0],
			u32(len(fault_names)),
			&fault[0],
		) >= 0,
	) {return}
	testing.expect_value(t, fault[0].Reg64, u64(0x3000))
	testing.expect_value(t, fault[1].Reg128[0] & 1, u64(1))
	testing.expect_value(t, fault[1].Reg128[0] >> 8 & 1, u64(1))
	testing.expect_value(t, fault[1].Reg128[0] >> 16 & 0xFFFF, u64(14))
	testing.expect_value(t, fault[1].Reg128[0] >> 32, u64(0))
	testing.expect_value(t, fault[1].Reg128[1], u64(0x3000))
}

@(test)
test_whpx_manual_segment_limit_injects_gp :: proc(t: ^testing.T) {
	if !available() {
		log.warn("WHPX not available")
		return
	}
	vm: Vm
	if !testing.expect(t, create(&vm, 64 * 1024 * 1024)) {return}
	defer destroy(&vm)
	vp: WHV_VP_EXIT_CONTEXT
	io: WHV_X64_IO_PORT_ACCESS_CONTEXT
	if !whpx_test_manual_io_context(t, &vm, &vp, &io, 0, 2, 0, 0x100, 0x7600, 0x2) {
		return
	}
	io.Es.Limit = 0x100
	whpx_test_manual_io_instruction(&vp, &io, []u8{0xF3, 0x6D}, 0x34, 0x789A)
	probe: Whpx_Test_Probe
	vm.io_ctx = &probe
	vm.io_read = whpx_test_io_read

	ok, detail := whpx_emulate_io(&vm, &vp, &io)
	testing.expect(t, ok)
	testing.expect_value(t, detail, "")
	testing.expect_value(t, probe.io_read_count, 0)
	regs := get_regs(&vm)
	testing.expect_value(t, regs.rdi, u64(0x100))
	testing.expect_value(t, regs.rcx, u64(2))
	testing.expect_value(t, regs.rip, u64(0x7600))
	name := WHV_REGISTER_NAME.PendingEvent
	pending: WHV_REGISTER_VALUE
	if !testing.expect(
		t,
		WHvGetVirtualProcessorRegisters(vm.part, 0, &name, 1, &pending) >= 0,
	) {return}
	testing.expect_value(t, pending.Reg128[0] & 1, u64(1))
	testing.expect_value(t, pending.Reg128[0] >> 8 & 1, u64(1))
	testing.expect_value(t, pending.Reg128[0] >> 16 & 0xFFFF, u64(13))
	testing.expect_value(t, pending.Reg128[0] >> 32, u64(0))
}

@(test)
test_whpx_manual_reserved_mmio_string_source :: proc(t: ^testing.T) {
	if !available() {
		log.warn("WHPX not available")
		return
	}
	vm: Vm
	if !testing.expect(t, create(&vm, 64 * 1024 * 1024)) {return}
	defer destroy(&vm)
	if !testing.expect(t, reserve_mmio(&vm, 0xA0000, 0x1000)) {return}
	vp: WHV_VP_EXIT_CONTEXT
	io: WHV_X64_IO_PORT_ACCESS_CONTEXT
	if !whpx_test_manual_io_context(t, &vm, &vp, &io, 0, 1, 0xA0000, 0, 0x7700, 0x2) {
		return
	}
	whpx_test_manual_io_instruction(&vp, &io, []u8{0xF3, 0x6E}, 0x33, 0x2468)
	probe: Whpx_Test_Probe
	vm.io_ctx = &probe
	vm.mmio = whpx_test_mmio
	vm.io_write = whpx_test_io_write

	ok, detail := whpx_emulate_io(&vm, &vp, &io)
	testing.expect(t, ok)
	testing.expect_value(t, detail, "")
	testing.expect_value(t, probe.mmio_reads, 1)
	testing.expect_value(t, probe.mmio_gpa, u64(0xA0000))
	testing.expect_value(t, probe.io_count, 1)
	testing.expect_value(t, probe.io_values[0], u8(0xA5))
	regs := get_regs(&vm)
	testing.expect_value(t, regs.rsi, u64(0xA0001))
	testing.expect_value(t, regs.rcx, u64(0))
	testing.expect_value(t, regs.rip, u64(0x7702))
}
