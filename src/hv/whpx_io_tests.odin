// SPDX-License-Identifier: GPL-3.0-only
package hv

import "core:log"
import "core:testing"

whpx_test_io_budget :: proc(ctx: rawptr) -> u64 {
	return (^u64)(ctx)^
}

Whpx_Deadline_IO_Probe :: struct {
	budget: u64,
	writes: int,
	begins: int,
	ends:   int,
	reject: bool,
}

whpx_test_deadline_budget :: proc(ctx: rawptr) -> u64 {
	return (^Whpx_Deadline_IO_Probe)(ctx).budget
}

whpx_test_deadline_write :: proc(ctx: rawptr, port: u16, size: u8, value: u32) -> bool {
	probe := (^Whpx_Deadline_IO_Probe)(ctx)
	probe.writes += 1
	probe.budget = 1
	return !probe.reject
}

whpx_test_string_io_begin :: proc(ctx: rawptr) {
	(^Whpx_Deadline_IO_Probe)(ctx).begins += 1
}

whpx_test_string_io_end :: proc(ctx: rawptr) {
	(^Whpx_Deadline_IO_Probe)(ctx).ends += 1
}

Whpx_String_Memory_Probe :: struct {
	mmio_reads: int,
	mmio_gpas:  [4]u64,
	mmio_sizes: [4]u8,
	io_writes:  int,
	io_size:    u8,
	io_value:   u32,
}

whpx_test_string_mmio :: proc(ctx: rawptr, gpa: u64, write: bool, data: []u8) {
	probe := (^Whpx_String_Memory_Probe)(ctx)
	if write {return}
	if probe.mmio_reads < len(probe.mmio_gpas) {
		probe.mmio_gpas[probe.mmio_reads] = gpa
		probe.mmio_sizes[probe.mmio_reads] = u8(len(data))
	}
	probe.mmio_reads += 1
	for &byte in data {byte = 0xA5}
}

whpx_test_string_port_write :: proc(ctx: rawptr, port: u16, size: u8, value: u32) -> bool {
	probe := (^Whpx_String_Memory_Probe)(ctx)
	probe.io_writes += 1
	probe.io_size = size
	probe.io_value = value
	return true
}

Whpx_Stream_Probe :: struct {
	calls: int,
	elements: int,
	first: u16,
}

whpx_test_stream_write :: proc(
	ctx: rawptr,
	port: u16,
	size: u8,
	data: []u8,
) -> (int, bool, bool) {
	probe := (^Whpx_Stream_Probe)(ctx)
	probe.calls += 1
	probe.elements = len(data) / int(size)
	probe.first = u16(data[0]) | u16(data[1]) << 8
	return probe.elements, true, true
}

@(test)
test_whpx_rep_outsw_streams_one_page_span :: proc(t: ^testing.T) {
	if !available() {log.warn("WHPX not available"); return}
	vm: Vm
	if !testing.expect(t, create(&vm, 64 * 1024 * 1024)) {return}
	defer destroy(&vm)
	for i in 0 ..< 2048 {vm.ram[0x8000 + i] = u8(i)}
	vp: WHV_VP_EXIT_CONTEXT
	io: WHV_X64_IO_PORT_ACCESS_CONTEXT
	if !whpx_test_manual_io_context(t, &vm, &vp, &io, 0, 1024, 0x8000, 0, 0x77F0, 0x2) {return}
	whpx_test_manual_io_instruction(&vp, &io, []u8{0xF3, 0x6F}, 0x35, 0x1F0)
	probe: Whpx_Stream_Probe
	vm.io_ctx = &probe
	vm.io_stream_write = whpx_test_stream_write
	translations := vm.io_string_translations
	ok, detail := whpx_emulate_io(&vm, &vp, &io)
	if !testing.expect(t, ok) {return}
	testing.expect_value(t, detail, "")
	testing.expect_value(t, probe.calls, 1)
	testing.expect_value(t, probe.elements, 1024)
	testing.expect_value(t, probe.first, u16(0x0100))
	testing.expect_value(t, vm.io_string_translations - translations, u64(1))
	regs := get_regs(&vm)
	testing.expect_value(t, regs.rsi, u64(0x8800))
	testing.expect_value(t, regs.rcx, u64(0))
	testing.expect_value(t, regs.rip, u64(0x77F2))
}

@(test)
test_whpx_string_io_budget_is_deadline_adjustable_and_bounded :: proc(t: ^testing.T) {
	requested := u64(17)
	vm := Vm {
		io_ctx           = &requested,
		io_string_budget = whpx_test_io_budget,
	}
	testing.expect_value(t, whpx_io_iteration_budget(&vm, 100), u64(17))
	requested = 0
	testing.expect_value(t, whpx_io_iteration_budget(&vm, 100), u64(1))
	requested = 100_000
	testing.expect_value(t, whpx_io_iteration_budget(&vm, 100_000), WHPX_IO_STRING_BUDGET)
}

@(test)
test_whpx_rep_out_rechecks_budget_after_device_programming :: proc(t: ^testing.T) {
	if !available() {
		log.warn("WHPX not available")
		return
	}
	vm: Vm
	if !testing.expect(t, create(&vm, 64 * 1024 * 1024)) {return}
	defer destroy(&vm)
	copy(vm.ram[0x9000:], []u8{1, 2, 3, 4, 5, 6, 7, 8})
	vp: WHV_VP_EXIT_CONTEXT
	io: WHV_X64_IO_PORT_ACCESS_CONTEXT
	if !whpx_test_manual_io_context(t, &vm, &vp, &io, 0, 8, 0x9000, 0, 0x7800, 0x2) {
		return
	}
	whpx_test_manual_io_instruction(&vp, &io, []u8{0xF3, 0x6E}, 0x33, 0x1234)
	probe := Whpx_Deadline_IO_Probe {
		budget = WHPX_IO_STRING_BUDGET,
	}
	vm.io_ctx = &probe
	vm.io_write = whpx_test_deadline_write
	vm.io_string_budget = whpx_test_deadline_budget
	vm.io_string_begin = whpx_test_string_io_begin
	vm.io_string_end = whpx_test_string_io_end
	ok, detail := whpx_emulate_io(&vm, &vp, &io)
	if !testing.expect(t, ok) {return}
	testing.expect_value(t, detail, "")
	testing.expect_value(t, probe.writes, 1)
	testing.expect_value(t, probe.begins, 1)
	testing.expect_value(t, probe.ends, 1)
	regs := get_regs(&vm)
	testing.expect_value(t, regs.rsi, u64(0x9001))
	testing.expect_value(t, regs.rcx, u64(7))
	testing.expect_value(t, regs.rip, u64(0x7800))
}

@(test)
test_whpx_rep_io_scope_balances_on_rejection :: proc(t: ^testing.T) {
	if !available() {
		log.warn("WHPX not available")
		return
	}
	vm: Vm
	if !testing.expect(t, create(&vm, 64 * 1024 * 1024)) {return}
	defer destroy(&vm)
	vm.ram[0x9000] = 0xA5
	vp: WHV_VP_EXIT_CONTEXT
	io: WHV_X64_IO_PORT_ACCESS_CONTEXT
	if !whpx_test_manual_io_context(t, &vm, &vp, &io, 0, 1, 0x9000, 0, 0x7810, 0x2) {
		return
	}
	whpx_test_manual_io_instruction(&vp, &io, []u8{0xF3, 0x6E}, 0x33, 0x1234)
	probe := Whpx_Deadline_IO_Probe {
		budget = WHPX_IO_STRING_BUDGET,
		reject = true,
	}
	vm.io_ctx = &probe
	vm.io_write = whpx_test_deadline_write
	vm.io_string_budget = whpx_test_deadline_budget
	vm.io_string_begin = whpx_test_string_io_begin
	vm.io_string_end = whpx_test_string_io_end
	ok, _ := whpx_emulate_io(&vm, &vp, &io)
	testing.expect(t, !ok)
	testing.expect_value(t, probe.writes, 1)
	testing.expect_value(t, probe.begins, 1)
	testing.expect_value(t, probe.ends, 1)
}

@(test)
test_whpx_rep_io_scope_balances_on_fault :: proc(t: ^testing.T) {
	if !available() {
		log.warn("WHPX not available")
		return
	}
	vm: Vm
	if !testing.expect(t, create(&vm, 64 * 1024 * 1024)) {return}
	defer destroy(&vm)
	vp: WHV_VP_EXIT_CONTEXT
	io: WHV_X64_IO_PORT_ACCESS_CONTEXT
	if !whpx_test_manual_io_context(t, &vm, &vp, &io, 0, 1, 0, 0x100, 0x7820, 0x2) {
		return
	}
	io.Es.Limit = 0xFF
	whpx_test_manual_io_instruction(&vp, &io, []u8{0xF3, 0x6C}, 0x32, 0x1234)
	probe := Whpx_Deadline_IO_Probe {
		budget = WHPX_IO_STRING_BUDGET,
	}
	vm.io_ctx = &probe
	vm.io_string_budget = whpx_test_deadline_budget
	vm.io_string_begin = whpx_test_string_io_begin
	vm.io_string_end = whpx_test_string_io_end
	ok, detail := whpx_emulate_io(&vm, &vp, &io)
	testing.expect(t, ok)
	testing.expect_value(t, detail, "")
	testing.expect_value(t, probe.begins, 1)
	testing.expect_value(t, probe.ends, 1)
}

@(test)
test_whpx_rep_outsw_translates_once_per_page :: proc(t: ^testing.T) {
	if !available() {
		log.warn("WHPX not available")
		return
	}
	vm: Vm
	if !testing.expect(t, create(&vm, 64 * 1024 * 1024)) {return}
	defer destroy(&vm)
	vp: WHV_VP_EXIT_CONTEXT
	io: WHV_X64_IO_PORT_ACCESS_CONTEXT
	if !whpx_test_manual_io_context(t, &vm, &vp, &io, 0, 4096, 0x8000, 0, 0x7830, 0x2) {
		return
	}
	whpx_test_manual_io_instruction(&vp, &io, []u8{0xF3, 0x6F}, 0x35, 0x1234)
	probe: Whpx_Test_Probe
	vm.io_ctx = &probe
	vm.io_write = whpx_test_io_write
	translations := vm.io_string_translations

	ok, detail := whpx_emulate_io(&vm, &vp, &io)
	if !testing.expect(t, ok) {return}
	testing.expect_value(t, detail, "")
	testing.expect_value(t, probe.io_attempts, 4096)
	testing.expect_value(t, probe.io_last_size, u8(2))
	testing.expect_value(t, vm.io_string_translations - translations, u64(2))
	regs := get_regs(&vm)
	testing.expect_value(t, regs.rsi, u64(0xA000))
	testing.expect_value(t, regs.rcx, u64(0))
	testing.expect_value(t, regs.rip, u64(0x7832))
}

@(test)
test_whpx_outsw_groups_contiguous_mmio_bytes :: proc(t: ^testing.T) {
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
	if !whpx_test_manual_io_context(t, &vm, &vp, &io, 0, 1, 0xA0010, 0, 0x7840, 0x2) {
		return
	}
	whpx_test_manual_io_instruction(&vp, &io, []u8{0xF3, 0x6F}, 0x35, 0x1234)
	probe: Whpx_String_Memory_Probe
	vm.io_ctx = &probe
	vm.mmio = whpx_test_string_mmio
	vm.io_write = whpx_test_string_port_write

	ok, detail := whpx_emulate_io(&vm, &vp, &io)
	if !testing.expect(t, ok) {return}
	testing.expect_value(t, detail, "")
	testing.expect_value(t, probe.mmio_reads, 1)
	testing.expect_value(t, probe.mmio_gpas[0], u64(0xA0010))
	testing.expect_value(t, probe.mmio_sizes[0], u8(2))
	testing.expect_value(t, probe.io_writes, 1)
	testing.expect_value(t, probe.io_size, u8(2))
	testing.expect_value(t, probe.io_value, u32(0xA5A5))
}

@(test)
test_whpx_outsw_splits_noncontiguous_page_boundary :: proc(t: ^testing.T) {
	if !available() {
		log.warn("WHPX not available")
		return
	}
	vm: Vm
	if !testing.expect(t, create(&vm, 64 * 1024 * 1024)) {return}
	defer destroy(&vm)
	if !testing.expect(t, reserve_mmio(&vm, 0xA0000, 0x1000)) {return}
	if !testing.expect(t, reserve_mmio(&vm, 0xB0000, 0x1000)) {return}
	whpx_test_write_u32(vm.ram, 0x1000, 0x2003)
	whpx_test_write_u32(vm.ram, 0x2000 + 2 * 4, 0xA0003)
	whpx_test_write_u32(vm.ram, 0x2000 + 3 * 4, 0xB0003)
	vp: WHV_VP_EXIT_CONTEXT
	io: WHV_X64_IO_PORT_ACCESS_CONTEXT
	if !whpx_test_manual_io_context(t, &vm, &vp, &io, 0, 1, 0x2FFF, 0, 0x7850, 0x2) {
		return
	}
	whpx_test_manual_io_instruction(&vp, &io, []u8{0xF3, 0x6F}, 0x35, 0x1234)
	names := [?]WHV_REGISTER_NAME{.Cr3, .Cr0}
	values: [len(names)]WHV_REGISTER_VALUE
	values[0].Reg64 = 0x1000
	values[1].Reg64 = 0x80000011
	if !testing.expect(
		t,
		WHvSetVirtualProcessorRegisters(vm.part, 0, &names[0], u32(len(names)), &values[0]) >= 0,
	) {
		return
	}
	probe: Whpx_String_Memory_Probe
	vm.io_ctx = &probe
	vm.mmio = whpx_test_string_mmio
	vm.io_write = whpx_test_string_port_write
	translations := vm.io_string_translations

	ok, detail := whpx_emulate_io(&vm, &vp, &io)
	if !testing.expect(t, ok) {return}
	testing.expect_value(t, detail, "")
	testing.expect_value(t, vm.io_string_translations - translations, u64(2))
	testing.expect_value(t, probe.mmio_reads, 2)
	testing.expect_value(t, probe.mmio_gpas[0], u64(0xA0FFF))
	testing.expect_value(t, probe.mmio_gpas[1], u64(0xB0000))
	testing.expect_value(t, probe.mmio_sizes[0], u8(1))
	testing.expect_value(t, probe.mmio_sizes[1], u8(1))
	testing.expect_value(t, probe.io_writes, 1)
	testing.expect_value(t, probe.io_value, u32(0xA5A5))
	regs := get_regs(&vm)
	testing.expect_value(t, regs.rsi, u64(0x3001))
	testing.expect_value(t, regs.rcx, u64(0))
	testing.expect_value(t, regs.rip, u64(0x7852))
}

@(test)
test_whpx_insw_page_fault_does_not_consume_partial_element :: proc(t: ^testing.T) {
	if !available() {
		log.warn("WHPX not available")
		return
	}
	vm: Vm
	if !testing.expect(t, create(&vm, 64 * 1024 * 1024)) {return}
	defer destroy(&vm)
	whpx_test_write_u32(vm.ram, 0x1000, 0x2003)
	whpx_test_write_u32(vm.ram, 0x2000 + 2 * 4, 0x5003)
	vp: WHV_VP_EXIT_CONTEXT
	io: WHV_X64_IO_PORT_ACCESS_CONTEXT
	if !whpx_test_manual_io_context(t, &vm, &vp, &io, 0, 1, 0, 0x2FFF, 0x7860, 0x2) {
		return
	}
	whpx_test_manual_io_instruction(&vp, &io, []u8{0xF3, 0x6D}, 0x34, 0x1234)
	names := [?]WHV_REGISTER_NAME{.Cr3, .Cr0}
	values: [len(names)]WHV_REGISTER_VALUE
	values[0].Reg64 = 0x1000
	values[1].Reg64 = 0x80000011
	if !testing.expect(
		t,
		WHvSetVirtualProcessorRegisters(vm.part, 0, &names[0], u32(len(names)), &values[0]) >= 0,
	) {
		return
	}
	probe: Whpx_Test_Probe
	probe.io_read_values[0] = 0xBEEF
	vm.io_ctx = &probe
	vm.io_read = whpx_test_io_read
	translations := vm.io_string_translations

	ok, detail := whpx_emulate_io(&vm, &vp, &io)
	if !testing.expect(t, ok) {return}
	testing.expect_value(t, detail, "")
	testing.expect_value(t, vm.io_string_translations - translations, u64(2))
	testing.expect_value(t, probe.io_read_count, 0)
	regs := get_regs(&vm)
	testing.expect_value(t, regs.rsi, u64(0))
	testing.expect_value(t, regs.rdi, u64(0x2FFF))
	testing.expect_value(t, regs.rcx, u64(1))
	testing.expect_value(t, regs.rip, u64(0x7860))
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
		) >=
		0,
	) {
		return
	}
	testing.expect_value(t, fault[0].Reg64, u64(0x3000))
	testing.expect_value(t, fault[1].Reg128[0] >> 16 & 0xFFFF, u64(14))
	testing.expect_value(t, fault[1].Reg128[0] >> 32, u64(2))
}

@(test)
test_whpx_io_page_fault_error_codes :: proc(t: ^testing.T) {
	testing.expect_value(t, whpx_io_page_fault_error(.PageNotPresent, false, false), u32(0))
	testing.expect_value(t, whpx_io_page_fault_error(.PageNotPresent, true, true), u32(0x6))
	testing.expect_value(t, whpx_io_page_fault_error(.PrivilegeViolation, false, true), u32(0x5))
	testing.expect_value(
		t,
		whpx_io_page_fault_error(.InvalidPageTableFlags, true, false),
		u32(0xB),
	)
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
		) >=
		0,
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
