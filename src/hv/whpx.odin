// SPDX-License-Identifier: GPL-3.0-only
package hv

import "base:runtime"
import "core:fmt"
import "core:sync"
import win32 "core:sys/windows"

// Windows allows only one WHPX partition with GPA mappings per process:
// a second WHvMapGpaRange fails with 0xC0370008
// (ERROR_VID_PARTITION_ALREADY_EXISTS) while another mapped partition
// exists, even single-threaded. Serialize whole VM lifetimes: whpx_create
// blocks until the previous VM is destroyed. Not reentrant — one thread
// must not create a second VM while holding one.
@(private = "file")
whpx_vm_gate: sync.Mutex

WHPX_A20_BIT :: u64(0x00100000)
WHPX_A20_PAIR_SIZE :: u64(0x00200000)

whpx_available :: proc() -> bool {
	present: win32.BOOL
	written: u32
	hr := WHvGetCapability(.HypervisorPresent, &present, size_of(present), &written)
	return hr >= 0 && bool(present)
}

whpx_create :: proc(vm: ^Vm, ram_size: int, options: Vm_Create_Options) -> bool {
	if !whpx_available() {
		return false
	}

	sync.lock(&whpx_vm_gate)
	part: WHV_PARTITION_HANDLE
	if WHvCreatePartition(&part) < 0 {
		sync.unlock(&whpx_vm_gate)
		return false
	}
	vm.part = part

	count: u32 = 1
	if WHvSetPartitionProperty(part, .ProcessorCount, &count, size_of(count)) < 0 {
		whpx_destroy(vm)
		return false
	}
	ext_exits: u64 = 0x3 // CPUID and MSR exits keep the GSW-886 profile independent of the host
	if options.trace_ud_gp_exits {ext_exits |= 1 << 2}
	if WHvSetPartitionProperty(part, .ExtendedVmExits, &ext_exits, size_of(ext_exits)) < 0 {
		whpx_destroy(vm)
		return false
	}
	if options.trace_ud_gp_exits {
		if !whpx_configure_exception_tracing(vm) {
			whpx_destroy(vm)
			return false
		}
	}
	if !whpx_apply_cpu_profile(part) {
		whpx_destroy(vm)
		return false
	}
	if WHvSetupPartition(part) < 0 {
		whpx_destroy(vm)
		return false
	}

	ram := win32.VirtualAlloc(
		nil,
		uint(ram_size),
		win32.MEM_COMMIT | win32.MEM_RESERVE,
		win32.PAGE_READWRITE,
	)
	if ram == nil {
		whpx_destroy(vm)
		return false
	}
	vm.ram = ([^]u8)(ram)[:ram_size]

	flags :=
		WHV_MAP_GPA_RANGE_FLAG_READ | WHV_MAP_GPA_RANGE_FLAG_WRITE | WHV_MAP_GPA_RANGE_FLAG_EXECUTE
	if WHvMapGpaRange(part, ram, 0, u64(ram_size), flags) < 0 {
		whpx_destroy(vm)
		return false
	}
	vm.a20_enabled = true
	vm.a20_requested = true

	if WHvCreateVirtualProcessor(part, 0, 0) < 0 {
		whpx_destroy(vm)
		return false
	}
	if !whpx_reset_vcpu(vm) {
		whpx_destroy(vm)
		return false
	}

	cb := WHV_EMULATOR_CALLBACKS {
		Size             = size_of(WHV_EMULATOR_CALLBACKS),
		IoPort           = whpx_emu_io,
		Memory           = whpx_emu_mmio,
		GetRegs          = whpx_emu_get_regs,
		SetRegs          = whpx_emu_set_regs,
		TranslateGvaPage = whpx_emu_translate,
	}
	emu: WHV_EMULATOR_HANDLE
	if WHvEmulatorCreateEmulator(&cb, &emu) < 0 {
		whpx_destroy(vm)
		return false
	}
	vm.emu = emu
	return true
}

whpx_destroy :: proc(vm: ^Vm) {
	held_gate := vm.part != nil // only a create that got a partition holds the gate
	if vm.emu != nil {
		WHvEmulatorDestroyEmulator(vm.emu)
		vm.emu = nil
	}
	if vm.part != nil {
		WHvDeletePartition(vm.part)
		vm.part = nil
	}
	if vm.ram != nil {
		win32.VirtualFree(raw_data(vm.ram), 0, win32.MEM_RELEASE)
		vm.ram = nil
	}
	for rom in vm.roms {
		win32.VirtualFree(rom.host, 0, win32.MEM_RELEASE)
	}
	delete(vm.roms)
	vm.roms = nil
	delete(vm.mmio_reservations)
	vm.mmio_reservations = nil
	delete(vm.shadow_mappings)
	vm.shadow_mappings = nil
	for mapping in vm.device_mappings {
		win32.VirtualFree(mapping.host, 0, win32.MEM_RELEASE)
	}
	delete(vm.device_mappings)
	vm.device_mappings = nil
	delete(vm.exception_trace)
	vm.exception_trace = nil
	vm.exception_count = 0
	vm.trace_ud_gp_exits = false
	if held_gate {
		sync.unlock(&whpx_vm_gate)
	}
}

@(private = "file")
whpx_page_range_valid :: proc(gpa, size: u64) -> bool {
	return size > 0 && gpa & 0xFFF == 0 && size & 0xFFF == 0 && gpa <= max(u64) - size
}

@(private = "file")
whpx_ranges_overlap :: proc(a_gpa, a_size, b_gpa, b_size: u64) -> bool {
	return a_gpa < b_gpa + b_size && b_gpa < a_gpa + a_size
}

@(private = "file")
whpx_reserve_memory :: proc(vm: ^Vm, gpa, size: u64, kind: Memory_Reservation_Kind) -> bool {
	if vm.part == nil || !whpx_page_range_valid(gpa, size) || gpa + size > u64(len(vm.ram)) {
		return false
	}
	for reservation in vm.mmio_reservations {
		if reservation.gpa == gpa && reservation.size == size {
			return reservation.kind == kind
		}
		if whpx_ranges_overlap(gpa, size, reservation.gpa, reservation.size) {
			return false
		}
	}
	for mapping in vm.device_mappings {
		if whpx_ranges_overlap(gpa, size, mapping.gpa, u64(mapping.size)) {
			return false
		}
	}
	for rom in vm.roms {
		if whpx_ranges_overlap(gpa, size, rom.gpa, u64(rom.size)) {
			return false
		}
	}
	if WHvUnmapGpaRange(vm.part, gpa, size) < 0 {
		return false
	}
	append(&vm.mmio_reservations, Mmio_Reservation{gpa = gpa, size = size, kind = kind})
	return true
}

whpx_reserve_mmio :: proc(vm: ^Vm, gpa, size: u64) -> bool {
	return whpx_reserve_memory(vm, gpa, size, .Mmio)
}

whpx_reserve_open_bus :: proc(vm: ^Vm, gpa, size: u64) -> bool {
	return whpx_reserve_memory(vm, gpa, size, .Open_Bus)
}

@(private = "file")
whpx_shadow_flags :: proc(readable, writable: bool) -> u32 {
	if !readable && !writable {return 0}
	flags: u32
	if readable {
		flags |= WHV_MAP_GPA_RANGE_FLAG_READ | WHV_MAP_GPA_RANGE_FLAG_EXECUTE
	}
	if writable {flags |= WHV_MAP_GPA_RANGE_FLAG_WRITE}
	return flags
}

@(private = "file")
whpx_map_ram_range :: proc(vm: ^Vm, gpa, size: u64, flags: u32) -> bool {
	if flags == 0 {return true}
	return WHvMapGpaRange(vm.part, raw_data(vm.ram[int(gpa):]), gpa, size, flags) >= 0
}

whpx_set_open_bus_shadow :: proc(vm: ^Vm, gpa, size: u64, readable, writable: bool) -> bool {
	if vm.part == nil || !whpx_page_range_valid(gpa, size) || gpa + size > u64(len(vm.ram)) {
		return false
	}
	contained := false
	for reservation in vm.mmio_reservations {
		if reservation.kind == .Open_Bus &&
		   gpa >= reservation.gpa &&
		   gpa + size <= reservation.gpa + reservation.size {
			contained = true
			break
		}
	}
	if !contained {return false}

	index := -1
	for mapping, i in vm.shadow_mappings {
		if mapping.gpa == gpa && mapping.size == size {
			index = i
			continue
		}
		if whpx_ranges_overlap(gpa, size, mapping.gpa, mapping.size) {return false}
	}
	old_readable, old_writable := false, false
	if index >= 0 {
		old := vm.shadow_mappings[index]
		old_readable, old_writable = old.readable, old.writable
		if old_readable == readable && old_writable == writable {return true}
	}

	new_flags := whpx_shadow_flags(readable, writable)
	if index >= 0 && whpx_shadow_flags(old_readable, old_writable) == new_flags {
		vm.shadow_mappings[index].readable = readable
		vm.shadow_mappings[index].writable = writable
		return true
	}
	if WHvUnmapGpaRange(vm.part, gpa, size) < 0 {return false}
	if !whpx_map_ram_range(vm, gpa, size, new_flags) {
		_ = whpx_map_ram_range(vm, gpa, size, whpx_shadow_flags(old_readable, old_writable))
		return false
	}
	mapping := Shadow_Mapping {
		gpa      = gpa,
		size     = size,
		readable = readable,
		writable = writable,
	}
	if index >= 0 {
		vm.shadow_mappings[index] = mapping
	} else {
		append(&vm.shadow_mappings, mapping)
	}
	return true
}

whpx_map_device_memory :: proc(vm: ^Vm, gpa: u64, size: int) -> ([]u8, bool) {
	if vm.part == nil || size <= 0 || !whpx_page_range_valid(gpa, u64(size)) {
		return nil, false
	}
	map_size := u64(size)
	if gpa < u64(len(vm.ram)) && whpx_ranges_overlap(gpa, map_size, 0, u64(len(vm.ram))) {
		return nil, false
	}
	for reservation in vm.mmio_reservations {
		if whpx_ranges_overlap(gpa, map_size, reservation.gpa, reservation.size) {
			return nil, false
		}
	}
	for mapping in vm.device_mappings {
		if whpx_ranges_overlap(gpa, map_size, mapping.gpa, u64(mapping.size)) {
			return nil, false
		}
	}
	for rom in vm.roms {
		if whpx_ranges_overlap(gpa, map_size, rom.gpa, u64(rom.size)) {
			return nil, false
		}
	}
	mem := win32.VirtualAlloc(
		nil,
		uint(size),
		win32.MEM_COMMIT | win32.MEM_RESERVE,
		win32.PAGE_READWRITE,
	)
	if mem == nil {
		return nil, false
	}
	flags := WHV_MAP_GPA_RANGE_FLAG_READ | WHV_MAP_GPA_RANGE_FLAG_WRITE
	if WHvMapGpaRange(vm.part, mem, gpa, map_size, flags) < 0 {
		win32.VirtualFree(mem, 0, win32.MEM_RELEASE)
		return nil, false
	}
	append(
		&vm.device_mappings,
		Device_Mapping {
			gpa = gpa,
			host = mem,
			size = size,
			mapped = true,
			requested_gpa = gpa,
			requested_mapped = true,
		},
	)
	return ([^]u8)(mem)[:size], true
}

@(private = "file")
whpx_device_mapping_index :: proc(vm: ^Vm, backing: []u8) -> int {
	if vm == nil || len(backing) <= 0 {return -1}
	host := raw_data(backing)
	for mapping, i in vm.device_mappings {
		if mapping.host == host && mapping.size == len(backing) {return i}
	}
	return -1
}

@(private = "file")
whpx_device_mapping_target_valid :: proc(vm: ^Vm, index: int, gpa: u64, enabled: bool) -> bool {
	if vm == nil || index < 0 || index >= len(vm.device_mappings) {return false}
	size := u64(vm.device_mappings[index].size)
	if !whpx_page_range_valid(gpa, size) {return false}
	if !enabled {return true}

	if whpx_ranges_overlap(gpa, size, 0, u64(len(vm.ram))) {return false}
	for reservation in vm.mmio_reservations {
		if whpx_ranges_overlap(gpa, size, reservation.gpa, reservation.size) {return false}
	}
	for rom in vm.roms {
		if whpx_ranges_overlap(gpa, size, rom.gpa, u64(rom.size)) {return false}
	}
	for mapping, other_index in vm.device_mappings {
		if other_index == index {continue}
		if mapping.mapped && whpx_ranges_overlap(gpa, size, mapping.gpa, u64(mapping.size)) {
			return false
		}
		if mapping.request_pending &&
		   mapping.requested_mapped &&
		   whpx_ranges_overlap(gpa, size, mapping.requested_gpa, u64(mapping.size)) {
			return false
		}
	}

	current := &vm.device_mappings[index]
	if current.mapped && current.gpa != gpa && whpx_ranges_overlap(gpa, size, current.gpa, size) {
		return false
	}
	return true
}

whpx_set_device_memory_mapping :: proc(vm: ^Vm, backing: []u8, gpa: u64, enabled: bool) -> bool {
	if vm == nil || vm.part == nil {return false}
	index := whpx_device_mapping_index(vm, backing)
	if !whpx_device_mapping_target_valid(vm, index, gpa, enabled) {return false}

	mapping := &vm.device_mappings[index]
	mapping.requested_gpa = gpa
	mapping.requested_mapped = enabled
	mapping.request_pending = mapping.gpa != gpa || mapping.mapped != enabled
	return true
}

whpx_set_a20 :: proc(vm: ^Vm, enabled: bool) -> bool {
	if vm.part == nil || len(vm.ram) <= int(WHPX_A20_BIT) {
		return false
	}
	if vm.a20_requested != enabled {vm.a20_request_count += 1}
	vm.a20_requested = enabled
	return true
}

@(private = "file")
whpx_map_a20_region :: proc(vm: ^Vm, odd_base: u64, enabled: bool) -> bool {
	ram_size := u64(len(vm.ram))
	if odd_base >= ram_size {return true}
	size := min(WHPX_A20_BIT, ram_size - odd_base)
	source_base := enabled ? odd_base : odd_base &~ WHPX_A20_BIT
	flags :=
		WHV_MAP_GPA_RANGE_FLAG_READ | WHV_MAP_GPA_RANGE_FLAG_WRITE | WHV_MAP_GPA_RANGE_FLAG_EXECUTE
	if WHvUnmapGpaRange(vm.part, odd_base, size) < 0 {return false}
	if WHvMapGpaRange(vm.part, raw_data(vm.ram[int(source_base):]), odd_base, size, flags) < 0 {
		return false
	}

	source_end := source_base + size
	for reservation in vm.mmio_reservations {
		first := max(source_base, reservation.gpa)
		last := min(source_end, reservation.gpa + reservation.size)
		if first >= last {continue}
		alias := odd_base + first - source_base
		if WHvUnmapGpaRange(vm.part, alias, last - first) < 0 {return false}
	}
	return true
}

@(private = "file")
whpx_map_a20_device_region :: proc(
	vm: ^Vm,
	mapping: ^Device_Mapping,
	odd_base: u64,
	enabled: bool,
) -> bool {
	mapping_end := mapping.gpa + u64(mapping.size)
	if odd_base < mapping.gpa || odd_base >= mapping_end {return true}
	size := min(WHPX_A20_BIT, mapping_end - odd_base)
	source_base := enabled ? odd_base : odd_base &~ WHPX_A20_BIT
	if source_base < mapping.gpa || source_base + size > mapping_end {return false}
	if WHvUnmapGpaRange(vm.part, odd_base, size) < 0 {return false}
	source := rawptr(uintptr(mapping.host) + uintptr(source_base - mapping.gpa))
	flags := WHV_MAP_GPA_RANGE_FLAG_READ | WHV_MAP_GPA_RANGE_FLAG_WRITE
	return WHvMapGpaRange(vm.part, source, odd_base, size, flags) >= 0
}

@(private = "file")
whpx_map_device_mapping_at :: proc(vm: ^Vm, mapping: ^Device_Mapping, gpa: u64) -> bool {
	flags := WHV_MAP_GPA_RANGE_FLAG_READ | WHV_MAP_GPA_RANGE_FLAG_WRITE
	if WHvMapGpaRange(vm.part, mapping.host, gpa, u64(mapping.size), flags) < 0 {return false}
	if vm.a20_enabled {return true}

	temporary := mapping^
	temporary.gpa = gpa
	pair_base := gpa &~ (WHPX_A20_PAIR_SIZE - 1)
	mapping_end := gpa + u64(mapping.size)
	for odd_base := pair_base + WHPX_A20_BIT;
	    odd_base < mapping_end;
	    odd_base += WHPX_A20_PAIR_SIZE {
		if odd_base < gpa {continue}
		if !whpx_map_a20_device_region(vm, &temporary, odd_base, false) {
			_ = WHvUnmapGpaRange(vm.part, gpa, u64(mapping.size))
			return false
		}
	}
	return true
}

@(private = "file")
whpx_apply_device_mapping_request :: proc(
	vm: ^Vm,
	mapping: ^Device_Mapping,
) -> (
	ok: bool,
	rollback_ok: bool,
) {
	if !mapping.request_pending {return true, true}
	old_gpa, old_mapped := mapping.gpa, mapping.mapped
	new_gpa, new_mapped := mapping.requested_gpa, mapping.requested_mapped

	if old_mapped && WHvUnmapGpaRange(vm.part, old_gpa, u64(mapping.size)) < 0 {
		return false, true
	}
	if new_mapped && !whpx_map_device_mapping_at(vm, mapping, new_gpa) {
		rollback_ok = !old_mapped || whpx_map_device_mapping_at(vm, mapping, old_gpa)
		return false, rollback_ok
	}

	mapping.gpa = new_gpa
	mapping.mapped = new_mapped
	mapping.request_pending = false
	return true, true
}

@(private = "file")
whpx_apply_device_mapping_requests :: proc(vm: ^Vm) -> (ok: bool, rollback_ok: bool) {
	for &mapping in vm.device_mappings {
		if applied, rollback_applied := whpx_apply_device_mapping_request(vm, &mapping); !applied {
			return false, rollback_applied
		}
	}
	return true, true
}

@(private = "file")
whpx_apply_a20_mapping :: proc(vm: ^Vm, enabled: bool) -> bool {
	for odd_base := WHPX_A20_BIT; odd_base < u64(len(vm.ram)); odd_base += WHPX_A20_PAIR_SIZE {
		if !whpx_map_a20_region(vm, odd_base, enabled) {return false}
	}
	for &mapping in vm.device_mappings {
		if !mapping.mapped {continue}
		pair_base := mapping.gpa &~ (WHPX_A20_PAIR_SIZE - 1)
		mapping_end := mapping.gpa + u64(mapping.size)
		for odd_base := pair_base + WHPX_A20_BIT;
		    odd_base < mapping_end;
		    odd_base += WHPX_A20_PAIR_SIZE {
			if odd_base < mapping.gpa {continue}
			if !whpx_map_a20_device_region(vm, &mapping, odd_base, enabled) {return false}
		}
	}
	return true
}

@(private = "file")
whpx_apply_a20_request :: proc(vm: ^Vm) -> (ok: bool, rollback_ok: bool) {
	if vm.a20_enabled == vm.a20_requested {return true, true}

	old_enabled := vm.a20_enabled
	new_enabled := vm.a20_requested
	if !whpx_apply_a20_mapping(vm, new_enabled) {
		rollback_ok = whpx_apply_a20_mapping(vm, old_enabled)
		vm.a20_requested = old_enabled
		return false, rollback_ok
	}
	vm.a20_enabled = vm.a20_requested
	vm.a20_apply_count += 1
	return true, true
}

// page-aligned private host copy mapped Read|Write|Execute: guest ROM safety alias
whpx_map_rom :: proc(vm: ^Vm, gpa: u64, data: []u8) -> bool {
	size := uint(len(data) + 0xFFF) & ~uint(0xFFF)
	mem := win32.VirtualAlloc(
		nil,
		size,
		win32.MEM_COMMIT | win32.MEM_RESERVE,
		win32.PAGE_READWRITE,
	)
	if mem == nil {
		return false
	}
	copy(([^]u8)(mem)[:len(data)], data)
	flags := WHV_MAP_GPA_RANGE_FLAG_READ |
	         WHV_MAP_GPA_RANGE_FLAG_WRITE |
	         WHV_MAP_GPA_RANGE_FLAG_EXECUTE
	if WHvMapGpaRange(vm.part, mem, gpa, u64(size), flags) < 0 {
		win32.VirtualFree(mem, 0, win32.MEM_RELEASE)
		return false
	}
	append(&vm.roms, Rom_Mapping{gpa = gpa, host = mem, size = int(size)})
	return true
}

// power-on state: real mode, CS F000:FFF0
whpx_reset_vcpu :: proc(vm: ^Vm) -> bool {
	code_seg := WHV_X64_SEGMENT_REGISTER {
		Base       = 0xFFFF0000,
		Limit      = 0xFFFF,
		Selector   = 0xF000,
		Attributes = 0x009B,
	}
	data_seg := WHV_X64_SEGMENT_REGISTER {
		Base       = 0,
		Limit      = 0xFFFF,
		Selector   = 0,
		Attributes = 0x0093,
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
		.Rax,
		.Rbx,
		.Rcx,
		.Rdx,
		.Rsp,
		.Rbp,
		.Rsi,
		.Rdi,
	}
	vals: [len(names)]WHV_REGISTER_VALUE
	vals[0].Segment = code_seg
	for i in 1 ..< 6 {
		vals[i].Segment = data_seg
	}
	vals[6].Reg64 = 0xFFF0
	vals[7].Reg64 = 0x2
	return WHvSetVirtualProcessorRegisters(vm.part, 0, &names[0], u32(len(names)), &vals[0]) >= 0
}

whpx_reset_cpu :: proc(vm: ^Vm) -> bool {
	if vm == nil || vm.part == nil {return false}
	if WHvDeleteVirtualProcessor(vm.part, 0) < 0 {return false}
	if WHvCreateVirtualProcessor(vm.part, 0, 0) < 0 {return false}
	vm.irq_queued = false
	vm.irq_vector = 0
	vm.irq_deferred_pending_event = false
	return whpx_reset_vcpu(vm)
}

whpx_set_realmode_entry :: proc(vm: ^Vm, cs_base: u32, ip: u16) {
	names := [?]WHV_REGISTER_NAME{.Cs, .Rip, .Rflags}
	vals: [len(names)]WHV_REGISTER_VALUE
	vals[0].Segment = WHV_X64_SEGMENT_REGISTER {
		Base       = u64(cs_base),
		Limit      = 0xFFFF,
		Selector   = u16(cs_base >> 4),
		Attributes = 0x009B,
	}
	vals[1].Reg64 = u64(ip)
	vals[2].Reg64 = 0x2
	WHvSetVirtualProcessorRegisters(vm.part, 0, &names[0], u32(len(names)), &vals[0])
}

// Max IO/MMIO emulation exits handled per whpx_run call. Keeps a port-polling
// guest from starving timers/IRQ injection: after the budget is spent, run
// returns Exit{kind = .Io} and the caller simply calls run again after
// pumping timers/IRQs.
WHPX_EXIT_BUDGET :: 32

whpx_run :: proc(vm: ^Vm) -> Exit {
	exit_ctx: WHV_RUN_VP_EXIT_CONTEXT
	for handled := 0;; handled += 1 {
		if ok, rollback_ok := whpx_apply_a20_request(vm); !ok {
			detail := "global A20 remap failed"
			if !rollback_ok {detail = "global A20 remap and rollback failed"}
			return Exit{kind = .Failed, detail = detail}
		}
		if ok, rollback_ok := whpx_apply_device_mapping_requests(vm); !ok {
			detail := "device memory remap failed"
			if !rollback_ok {detail = "device memory remap and rollback failed"}
			return Exit{kind = .Failed, detail = detail}
		}
		if handled >= WHPX_EXIT_BUDGET {
			return Exit{kind = .Io}
		}
		vm.run_calls += 1
		hr := WHvRunVirtualProcessor(vm.part, 0, &exit_ctx, size_of(exit_ctx))
		if hr < 0 {
			return Exit {
				kind = .Failed,
				detail = fmt.tprintf("WHvRunVirtualProcessor hr=0x%08x", u32(hr)),
			}
		}
		if vm.irq_queued {
			interruption_pending := exit_ctx.VpContext.ExecutionState & (u16(1) << 6) != 0
			if interruption_pending {
				vm.irq_pending_exit_count += 1
			} else {
				pending_name := WHV_REGISTER_NAME.PendingInterruption
				pending_value: WHV_REGISTER_VALUE
				if WHvGetVirtualProcessorRegisters(
					vm.part,
					0,
					&pending_name,
					1,
					&pending_value,
				) < 0 {
					return Exit{kind = .Failed, detail = "failed to verify PIC interrupt delivery"}
				}
				vm.irq_delivery_pending = pending_value.Reg64
				if pending_value.Reg64 & 0x1 != 0 {
					vm.irq_pending_exit_count += 1
				} else {
					vm.irq_delivery_reason = u32(exit_ctx.ExitReason)
					vm.irq_delivery_state = exit_ctx.VpContext.ExecutionState
					vm.irq_delivery_cs = exit_ctx.VpContext.Cs.Selector
					vm.irq_delivery_cs_base = exit_ctx.VpContext.Cs.Base
					vm.irq_delivery_rip = exit_ctx.VpContext.Rip
					vm.irq_delivery_rflags = exit_ctx.VpContext.Rflags
					vm.irq_delivery_io_port = 0
					vm.irq_delivery_io_access = 0
					vm.irq_delivery_io_rax = 0
					vm.irq_delivery_ins_len = 0
					vm.irq_delivery_ins = {}
					if exit_ctx.ExitReason == .X64IoPortAccess {
						io := &exit_ctx.u.IoPortAccess
						vm.irq_delivery_io_port = io.PortNumber
						vm.irq_delivery_io_access = io.AccessInfo
						vm.irq_delivery_io_rax = io.Rax
						vm.irq_delivery_ins_len = min(io.InstructionByteCount, u8(len(vm.irq_delivery_ins)))
						copy(
							vm.irq_delivery_ins[:vm.irq_delivery_ins_len],
							io.InstructionBytes[:vm.irq_delivery_ins_len],
						)
					}
					if vm.irq_delivered != nil && !vm.irq_delivered(vm.irq_ctx, vm.irq_vector) {
						return Exit{kind = .Failed, detail = "PIC interrupt delivery callback failed"}
					}
					vm.irq_queued = false
					vm.irq_delivery_count += 1
				}
			}
		}
		switch exit_ctx.ExitReason {
		case .X64IoPortAccess:
			if ok, detail := whpx_emulate_io(vm, &exit_ctx.VpContext, &exit_ctx.u.IoPortAccess);
			   !ok {
				return Exit{kind = .Failed, detail = detail}
			}
			if vm.io_should_yield != nil && vm.io_should_yield(vm.io_ctx) {
				return Exit{kind = .Io}
			}
		case .MemoryAccess:
			status: WHV_EMULATOR_STATUS
			hr = WHvEmulatorTryMmioEmulation(
				vm.emu,
				vm,
				&exit_ctx.VpContext,
				&exit_ctx.u.MemoryAccess,
				&status,
			)
			if hr < 0 || status.AsUINT32 & 1 == 0 {
				return Exit {
					kind = .Failed,
					detail = fmt.tprintf(
						"MMIO emulation gpa=0x%x hr=0x%08x status=0x%08x",
						exit_ctx.u.MemoryAccess.Gpa,
						u32(hr),
						status.AsUINT32,
					),
				}
			}
			if vm.io_should_yield != nil && vm.io_should_yield(vm.io_ctx) {
				return Exit{kind = .Io}
			}
		case .X64Halt:
			// advance RIP past the HLT
			whpx_advance_rip(vm, &exit_ctx.VpContext)
			return Exit{kind = .Halt}
		case .X64InterruptWindow:
			return Exit{kind = .Interrupt_Window}
		case .X64Cpuid:
			if !whpx_handle_cpuid(vm, &exit_ctx.VpContext, &exit_ctx.u.CpuidAccess) {
				return Exit{kind = .Failed, detail = "failed to apply CPUID result"}
			}
		case .X64MsrAccess:
			if !whpx_handle_msr(vm, &exit_ctx.VpContext, &exit_ctx.u.MsrAccess) {
				return Exit{kind = .Failed, detail = "failed to handle MSR access"}
			}
		case .Canceled:
			vm.run_cancellations += 1
			return Exit{kind = .Canceled}
		case .UnrecoverableException:
			return Exit{kind = .Reset, detail = "unrecoverable exception (triple fault)"}
		case .Exception:
			if ok, detail := whpx_trace_and_reinject_exception(
				vm,
				&exit_ctx.VpContext,
				&exit_ctx.u.VpException,
			); !ok {
				return Exit{kind = .Failed, detail = detail}
			}
		case .None, .InvalidVpRegisterValue, .UnsupportedFeature, .X64ApicEoi:
			return Exit {
				kind = .Failed,
				detail = fmt.tprintf("unhandled exit: %v", exit_ctx.ExitReason),
			}
		case:
			return Exit {
				kind = .Failed,
				detail = fmt.tprintf("unknown exit: %d", u32(exit_ctx.ExitReason)),
			}
		}
	}
}

// safe to call from another thread while whpx_run is blocked
whpx_cancel :: proc(vm: ^Vm) {
	WHvCancelRunVirtualProcessor(vm.part, 0, 0)
}

whpx_set_time_running :: proc(vm: ^Vm, running: bool) -> bool {
	if vm == nil || vm.part == nil {return false}
	if vm.time_suspended == !running {return true}
	if running {
		if WHvResumePartitionTime(vm.part) < 0 {return false}
		vm.time_suspended = false
	} else {
		if WHvSuspendPartitionTime(vm.part) < 0 {return false}
		vm.time_suspended = true
	}
	return true
}

whpx_advance_rip :: proc(vm: ^Vm, vp_ctx: ^WHV_VP_EXIT_CONTEXT) {
	name := WHV_REGISTER_NAME.Rip
	val: WHV_REGISTER_VALUE
	val.Reg64 = whpx_next_rip(vp_ctx)
	WHvSetVirtualProcessorRegisters(vm.part, 0, &name, 1, &val)
}

whpx_inject_irq :: proc(vm: ^Vm, vector: u8) {
	name := WHV_REGISTER_NAME.PendingInterruption
	val: WHV_REGISTER_VALUE
	// bit0 pending, type 0 (external interrupt), vector in bits 16..31
	val.Reg64 = 0x1 | (u64(vector) << 16)
	WHvSetVirtualProcessorRegisters(vm.part, 0, &name, 1, &val)
}

whpx_try_inject_irq :: proc(vm: ^Vm, vector: u8) -> Interrupt_Injection_Result {
	if vm == nil || vm.part == nil {return .Failed}
	vm.irq_deferred_pending_event = false
	names := [?]WHV_REGISTER_NAME {
		.Rflags,
		.PendingInterruption,
		.InterruptState,
		.PendingEvent,
		.Cs,
		.Rip,
	}
	values: [len(names)]WHV_REGISTER_VALUE
	if WHvGetVirtualProcessorRegisters(vm.part, 0, &names[0], u32(len(names)), &values[0]) < 0 {
		return .Failed
	}
	if_set := values[0].Reg64 & 0x200 != 0
	pending := values[1].Reg64 & 0x1 != 0
	shadow := values[2].Reg64 & 0x1 != 0
	event_pending := values[3].Reg128[0] & 0x1 != 0
	if event_pending {
		vm.irq_pending_event_deferrals += 1
		vm.irq_deferred_pending_event = true
		vm.irq_pending_event_low = values[3].Reg128[0]
		vm.irq_pending_event_high = values[3].Reg128[1]
	}
	if !if_set || pending || shadow || event_pending {return .Deferred}

	name := WHV_REGISTER_NAME.PendingInterruption
	value: WHV_REGISTER_VALUE
	value.Reg64 = 0x1 | u64(vector) << 16
	if WHvSetVirtualProcessorRegisters(vm.part, 0, &name, 1, &value) < 0 {
		return .Failed
	}
	vm.irq_queued = true
	vm.irq_vector = vector
	vm.irq_queue_count += 1
	vm.irq_queue_event = values[3].Reg128[0]
	vm.irq_queue_cs = values[4].Segment.Selector
	vm.irq_queue_cs_base = values[4].Segment.Base
	vm.irq_queue_rip = values[5].Reg64
	return .Injected
}

whpx_request_irq_window :: proc(vm: ^Vm, enable: bool) {
	name := WHV_REGISTER_NAME.DeliverabilityNotifications
	val: WHV_REGISTER_VALUE
	val.Reg64 = enable ? 0x2 : 0x0 // bit1 = InterruptNotification
	WHvSetVirtualProcessorRegisters(vm.part, 0, &name, 1, &val)
}

whpx_can_inject :: proc(vm: ^Vm) -> bool {
	names := [?]WHV_REGISTER_NAME {
		.Rflags,
		.PendingInterruption,
		.InterruptState,
		.PendingEvent,
	}
	vals: [len(names)]WHV_REGISTER_VALUE
	if WHvGetVirtualProcessorRegisters(vm.part, 0, &names[0], u32(len(names)), &vals[0]) < 0 {
		return false
	}
	if_set := vals[0].Reg64 & 0x200 != 0
	pending := vals[1].Reg64 & 0x1 != 0
	// WHV_X64_INTERRUPT_STATE_REGISTER: bit0 InterruptShadow, bit1 NmiMasked
	shadow := vals[2].Reg64 & 0x1 != 0
	event_pending := vals[3].Reg128[0] & 0x1 != 0
	return if_set && !pending && !shadow && !event_pending
}

whpx_reg_rax :: proc(vm: ^Vm) -> u64 {
	name := WHV_REGISTER_NAME.Rax
	val: WHV_REGISTER_VALUE
	WHvGetVirtualProcessorRegisters(vm.part, 0, &name, 1, &val)
	return val.Reg64
}

whpx_get_regs :: proc(vm: ^Vm) -> Regs {
	names := [?]WHV_REGISTER_NAME {
		.Rax,
		.Rbx,
		.Rcx,
		.Rdx,
		.Rsi,
		.Rdi,
		.Rsp,
		.Rbp,
		.Rip,
		.Rflags,
		.Cr0,
		.Cr3,
		.Cs,
		.Ss,
		.Ds,
		.Es,
	}
	vals: [len(names)]WHV_REGISTER_VALUE
	if WHvGetVirtualProcessorRegisters(vm.part, 0, &names[0], u32(len(names)), &vals[0]) < 0 {
		return {}
	}
	return Regs {
		rax = vals[0].Reg64,
		rbx = vals[1].Reg64,
		rcx = vals[2].Reg64,
		rdx = vals[3].Reg64,
		rsi = vals[4].Reg64,
		rdi = vals[5].Reg64,
		rsp = vals[6].Reg64,
		rbp = vals[7].Reg64,
		rip = vals[8].Reg64,
		rflags = vals[9].Reg64,
		cr0 = vals[10].Reg64,
		cr3 = vals[11].Reg64,
		cs_sel = vals[12].Segment.Selector,
		cs_base = vals[12].Segment.Base,
		ss_sel = vals[13].Segment.Selector,
		ss_base = vals[13].Segment.Base,
		ds_sel = vals[14].Segment.Selector,
		es_sel = vals[15].Segment.Selector,
	}
}

whpx_linear_read :: proc(vm: ^Vm, gva: u64, data: []u8) -> bool {
	if vm == nil || vm.part == nil {return false}
	cursor := 0
	for cursor < len(data) {
		linear := gva + u64(cursor)
		translation: WHV_TRANSLATE_GVA_RESULT
		gpa: u64
		if WHvTranslateGva(vm.part, 0, linear, 0x11, &translation, &gpa) < 0 ||
		   translation.ResultCode != .Success {
			return false
		}
		chunk := min(len(data) - cursor, int(0x1000 - (gpa & 0xfff)))
		if !whpx_physical_ram_read(vm, gpa, data[cursor:cursor + chunk]) {return false}
		cursor += chunk
	}
	return true
}

// --- emulator callbacks (WinHvEmulation) ---

whpx_emu_io :: proc "system" (ctx: rawptr, io: ^WHV_EMULATOR_IO_ACCESS_INFO) -> HRESULT {
	context = runtime.default_context()
	vm := (^Vm)(ctx)
	if io.Direction == 0 {
		if vm.io_read == nil {
			io.Data = 0xFFFFFFFF
			return 0
		}
		value, ok := vm.io_read(vm.io_ctx, io.Port, u8(io.AccessSize))
		io.Data = value
		if !ok {return HRESULT(-2147467259)}
	} else {
		if vm.io_write != nil && !vm.io_write(vm.io_ctx, io.Port, u8(io.AccessSize), io.Data) {
			return HRESULT(-2147467259)
		}
	}
	return 0
}

// The emulator resolves EVERY memory operand of an emulated instruction
// through this callback — including plain guest RAM (e.g. the buffer of a
// rep insb). Serve RAM and ROM directly; only true device MMIO reaches
// vm.mmio.
whpx_emu_mmio :: proc "system" (ctx: rawptr, mem: ^WHV_EMULATOR_MEMORY_ACCESS_INFO) -> HRESULT {
	context = runtime.default_context()
	return whpx_emulate_memory_access((^Vm)(ctx), mem)
}

whpx_emu_get_regs :: proc "system" (
	ctx: rawptr,
	names: [^]WHV_REGISTER_NAME,
	count: u32,
	values: [^]WHV_REGISTER_VALUE,
) -> HRESULT {
	vm := (^Vm)(ctx)
	return WHvGetVirtualProcessorRegisters(vm.part, 0, names, count, values)
}

whpx_emu_set_regs :: proc "system" (
	ctx: rawptr,
	names: [^]WHV_REGISTER_NAME,
	count: u32,
	values: [^]WHV_REGISTER_VALUE,
) -> HRESULT {
	vm := (^Vm)(ctx)
	return WHvSetVirtualProcessorRegisters(vm.part, 0, names, count, values)
}

whpx_emu_translate :: proc "system" (
	ctx: rawptr,
	gva: u64,
	flags: u32,
	result: ^WHV_TRANSLATE_GVA_RESULT_CODE,
	gpa: ^u64,
) -> HRESULT {
	context = runtime.default_context()
	vm := (^Vm)(ctx)
	translation: WHV_TRANSLATE_GVA_RESULT
	translated_gpa: u64
	hr := WHvTranslateGva(vm.part, 0, gva, flags, &translation, &translated_gpa)
	result^ = translation.ResultCode
	gpa^ = translated_gpa
	return hr
}
