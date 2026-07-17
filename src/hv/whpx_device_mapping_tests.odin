// SPDX-License-Identifier: GPL-3.0-only
package hv

import "core:log"
import "core:testing"

@(private = "file")
whpx_device_mapping_test_read :: proc(t: ^testing.T, vm: ^Vm, gpa: u64) -> (u8, bool) {
	if !testing.expect(t, gpa <= u64(max(u32))) {return 0, false}
	copy(vm.ram[0x7000:], []u8{0xA0, u8(gpa), u8(gpa >> 8), u8(gpa >> 16), u8(gpa >> 24), 0xF4})
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
	names := [?]WHV_REGISTER_NAME{.Cs, .Ds, .Es, .Ss, .Fs, .Gs, .Rip, .Rflags, .Rsp, .Rax, .Cr0}
	values: [len(names)]WHV_REGISTER_VALUE
	values[0].Segment = code
	for i in 1 ..< 6 {values[i].Segment = data}
	values[6].Reg64 = 0x7000
	values[7].Reg64 = 0x2
	values[8].Reg64 = 0x8000
	values[9].Reg64 = 0
	values[10].Reg64 = 0x11
	if !testing.expect(
		t,
		WHvSetVirtualProcessorRegisters(vm.part, 0, &names[0], u32(len(names)), &values[0]) >= 0,
	) {
		return 0, false
	}
	if !testing.expect_value(t, run(vm).kind, Exit_Kind.Halt) {return 0, false}
	return u8(reg_rax(vm)), true
}

@(private = "file")
whpx_device_mapping_test_write :: proc(t: ^testing.T, vm: ^Vm, gpa: u64, value: u8) -> bool {
	if !testing.expect(t, gpa <= u64(max(u32))) {return false}
	copy(
		vm.ram[0x7000:],
		[]u8{0xB0, value, 0xA2, u8(gpa), u8(gpa >> 8), u8(gpa >> 16), u8(gpa >> 24), 0xF4},
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
	names := [?]WHV_REGISTER_NAME{.Cs, .Ds, .Es, .Ss, .Fs, .Gs, .Rip, .Rflags, .Rsp, .Rax, .Cr0}
	values: [len(names)]WHV_REGISTER_VALUE
	values[0].Segment = code
	for i in 1 ..< 6 {values[i].Segment = data}
	values[6].Reg64 = 0x7000
	values[7].Reg64 = 0x2
	values[8].Reg64 = 0x8000
	values[9].Reg64 = 0
	values[10].Reg64 = 0x11
	if !testing.expect(
		t,
		WHvSetVirtualProcessorRegisters(vm.part, 0, &names[0], u32(len(names)), &values[0]) >= 0,
	) {
		return false
	}
	return testing.expect_value(t, run(vm).kind, Exit_Kind.Halt)
}

@(test)
whpx_tracked_device_mapping_reports_and_clears_guest_writes :: proc(t: ^testing.T) {
	if !available() {
		log.warn("WHPX not available")
		return
	}
	vm: Vm
	if !testing.expect(t, create(&vm, 64 * 1024 * 1024)) {return}
	defer destroy(&vm)

	base: u64 = 0xE000_0000
	backing, mapped := map_device_memory_tracked(&vm, base, 0x2000)
	if !testing.expect(t, mapped) {return}
	dirty, query_ok := query_device_memory_dirty(&vm, backing)
	testing.expect(t, query_ok && !dirty)
	if !whpx_device_mapping_test_write(t, &vm, base + 0x1003, 0x5A) {return}
	dirty, query_ok = query_device_memory_dirty(&vm, backing)
	testing.expect(t, query_ok && dirty)
	testing.expect_value(t, backing[0x1003], u8(0x5A))
	dirty, query_ok = query_device_memory_dirty(&vm, backing)
	testing.expect(t, query_ok && !dirty)
}

@(test)
whpx_device_mapping_relocates_disables_and_preserves_backing :: proc(t: ^testing.T) {
	if !available() {
		log.warn("WHPX not available")
		return
	}
	vm: Vm
	if !testing.expect(t, create(&vm, 64 * 1024 * 1024)) {return}
	defer destroy(&vm)

	old_gpa: u64 = 0xE000_0000
	new_gpa: u64 = 0xD000_0000
	final_gpa: u64 = 0xC000_0000
	backing, mapped := map_device_memory(&vm, old_gpa, 0x2000)
	if !testing.expect(t, mapped) {return}
	backing[0] = 0x5A

	if value, ok := whpx_device_mapping_test_read(t, &vm, old_gpa); ok {
		testing.expect_value(t, value, u8(0x5A))
	}
	testing.expect(t, set_device_memory_mapping(&vm, backing, old_gpa, true))
	testing.expect(t, !vm.device_mappings[0].request_pending)

	testing.expect(t, set_device_memory_mapping(&vm, backing, new_gpa, true))
	testing.expect_value(t, vm.device_mappings[0].gpa, old_gpa)
	testing.expect(t, vm.device_mappings[0].request_pending)
	if value, ok := whpx_device_mapping_test_read(t, &vm, new_gpa); ok {
		testing.expect_value(t, value, u8(0x5A))
	}
	testing.expect_value(t, vm.device_mappings[0].gpa, new_gpa)
	testing.expect(t, vm.device_mappings[0].mapped && !vm.device_mappings[0].request_pending)
	if value, ok := whpx_device_mapping_test_read(t, &vm, old_gpa); ok {
		testing.expect_value(t, value, u8(0xFF))
	}

	// Multiple BAR writes before the next run coalesce to the final address.
	testing.expect(t, set_device_memory_mapping(&vm, backing, old_gpa, true))
	testing.expect(t, set_device_memory_mapping(&vm, backing, final_gpa, true))
	if value, ok := whpx_device_mapping_test_read(t, &vm, final_gpa); ok {
		testing.expect_value(t, value, u8(0x5A))
	}
	if value, ok := whpx_device_mapping_test_read(t, &vm, old_gpa); ok {
		testing.expect_value(t, value, u8(0xFF))
	}

	// Disabling removes the direct GPA decode without freeing VRAM.
	testing.expect(t, set_device_memory_mapping(&vm, backing, final_gpa, false))
	if value, ok := whpx_device_mapping_test_read(t, &vm, final_gpa); ok {
		testing.expect_value(t, value, u8(0xFF))
	}
	testing.expect(t, !vm.device_mappings[0].mapped)
	backing[0] = 0xA6
	testing.expect(t, set_device_memory_mapping(&vm, backing, final_gpa, true))
	if value, ok := whpx_device_mapping_test_read(t, &vm, final_gpa); ok {
		testing.expect_value(t, value, u8(0xA6))
	}
}

@(test)
whpx_device_mapping_rejects_invalid_or_ambiguous_targets :: proc(t: ^testing.T) {
	if !available() {
		log.warn("WHPX not available")
		return
	}
	vm: Vm
	if !testing.expect(t, create(&vm, 64 * 1024 * 1024)) {return}
	defer destroy(&vm)

	old_gpa: u64 = 0xE000_0000
	other_gpa: u64 = 0xD000_0000
	backing, mapped := map_device_memory(&vm, old_gpa, 0x2000)
	if !testing.expect(t, mapped) {return}
	other_backing, other_mapped := map_device_memory(&vm, other_gpa, 0x2000)
	if !testing.expect(t, other_mapped) {return}

	testing.expect(t, !set_device_memory_mapping(&vm, backing, old_gpa + 0x1000, true))
	testing.expect(t, !set_device_memory_mapping(&vm, backing, other_gpa, true))
	testing.expect(t, !set_device_memory_mapping(&vm, backing, 0xD100_0001, true))
	testing.expect(t, !set_device_memory_mapping(&vm, backing, 0x03FF_F000, true))
	testing.expect(t, !set_device_memory_mapping(&vm, backing[:0x1000], 0xD100_0000, true))
	// A target remains unavailable until another pending unmap reaches the run boundary.
	testing.expect(t, set_device_memory_mapping(&vm, other_backing, other_gpa, false))
	testing.expect(t, !set_device_memory_mapping(&vm, backing, other_gpa, true))
	if value, ok := whpx_device_mapping_test_read(t, &vm, other_gpa); ok {
		testing.expect_value(t, value, u8(0xFF))
	}
	testing.expect(t, set_device_memory_mapping(&vm, backing, other_gpa, true))
	testing.expect(t, set_device_memory_mapping(&vm, backing, old_gpa, true))

	// A disabled BAR may retain an otherwise unusable address, but enabling it
	// still has to satisfy the GPA collision contract.
	testing.expect(t, set_device_memory_mapping(&vm, backing, 0, false))
	if value, ok := whpx_device_mapping_test_read(t, &vm, old_gpa); ok {
		testing.expect_value(t, value, u8(0xFF))
	}
	testing.expect(t, !set_device_memory_mapping(&vm, backing, 0, true))
}

@(test)
whpx_device_mapping_relocation_preserves_a20_aliasing :: proc(t: ^testing.T) {
	if !available() {
		log.warn("WHPX not available")
		return
	}
	vm: Vm
	if !testing.expect(t, create(&vm, 64 * 1024 * 1024)) {return}
	defer destroy(&vm)

	backing, mapped := map_device_memory(&vm, 0xE000_0000, 0x20_0000)
	if !testing.expect(t, mapped) {return}
	backing[0x000500] = 0x31
	backing[0x100500] = 0x72

	testing.expect(t, set_a20(&vm, false))
	testing.expect(t, set_device_memory_mapping(&vm, backing, 0xD000_0000, true))
	if value, ok := whpx_device_mapping_test_read(t, &vm, 0xD010_0500); ok {
		testing.expect_value(t, value, u8(0x31))
	}
	testing.expect(t, !vm.a20_enabled)

	testing.expect(t, set_a20(&vm, true))
	if value, ok := whpx_device_mapping_test_read(t, &vm, 0xD010_0500); ok {
		testing.expect_value(t, value, u8(0x72))
	}
}
