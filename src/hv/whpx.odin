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

WHPX_HMA_BASE :: u64(0x00100000)
WHPX_HMA_SIZE :: u64(0x00010000)

whpx_available :: proc() -> bool {
	present: win32.BOOL
	written: u32
	hr := WHvGetCapability(.HypervisorPresent, &present, size_of(present), &written)
	return hr >= 0 && bool(present)
}

whpx_create :: proc(vm: ^Vm, ram_size: int) -> bool {
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
	ext_exits: u64 = 1 // CPUID exits keep the GSW-886 profile independent of the host
	if WHvSetPartitionProperty(part, .ExtendedVmExits, &ext_exits, size_of(ext_exits)) < 0 {
		whpx_destroy(vm)
		return false
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
	for mapping in vm.device_mappings {
		win32.VirtualFree(mapping.host, 0, win32.MEM_RELEASE)
	}
	delete(vm.device_mappings)
	vm.device_mappings = nil
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

whpx_reserve_mmio :: proc(vm: ^Vm, gpa, size: u64) -> bool {
	if vm.part == nil || !whpx_page_range_valid(gpa, size) || gpa + size > u64(len(vm.ram)) {
		return false
	}
	for reservation in vm.mmio_reservations {
		if reservation.gpa == gpa && reservation.size == size {
			return true
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
	append(&vm.mmio_reservations, Mmio_Reservation{gpa = gpa, size = size})
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
	append(&vm.device_mappings, Device_Mapping{gpa = gpa, host = mem, size = size})
	return ([^]u8)(mem)[:size], true
}

whpx_set_a20 :: proc(vm: ^Vm, enabled: bool) -> bool {
	if vm.part == nil || len(vm.ram) < int(WHPX_HMA_BASE + WHPX_HMA_SIZE) {
		return false
	}
	if vm.a20_requested != enabled {vm.a20_request_count += 1}
	vm.a20_requested = enabled
	return true
}

@(private = "file")
whpx_apply_a20_request :: proc(vm: ^Vm) -> (ok: bool, rollback_ok: bool) {
	if vm.a20_enabled == vm.a20_requested {return true, true}

	flags :=
		WHV_MAP_GPA_RANGE_FLAG_READ | WHV_MAP_GPA_RANGE_FLAG_WRITE | WHV_MAP_GPA_RANGE_FLAG_EXECUTE
	old_source := vm.a20_enabled ? raw_data(vm.ram[WHPX_HMA_BASE:]) : raw_data(vm.ram)
	new_source := vm.a20_requested ? raw_data(vm.ram[WHPX_HMA_BASE:]) : raw_data(vm.ram)
	if WHvUnmapGpaRange(vm.part, WHPX_HMA_BASE, WHPX_HMA_SIZE) < 0 {
		vm.a20_requested = vm.a20_enabled
		return false, true
	}
	if WHvMapGpaRange(vm.part, new_source, WHPX_HMA_BASE, WHPX_HMA_SIZE, flags) < 0 {
		rollback_ok = WHvMapGpaRange(vm.part, old_source, WHPX_HMA_BASE, WHPX_HMA_SIZE, flags) >= 0
		vm.a20_requested = vm.a20_enabled
		return false, rollback_ok
	}
	vm.a20_enabled = vm.a20_requested
	vm.a20_apply_count += 1
	return true, true
}

// page-aligned host copy mapped Read|Execute (no Write): guest ROM
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
	flags := WHV_MAP_GPA_RANGE_FLAG_READ | WHV_MAP_GPA_RANGE_FLAG_EXECUTE
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
			detail := "A20 HMA remap failed"
			if !rollback_ok {detail = "A20 HMA remap and rollback failed"}
			return Exit{kind = .Failed, detail = detail}
		}
		if handled >= WHPX_EXIT_BUDGET {
			return Exit{kind = .Io}
		}
		hr := WHvRunVirtualProcessor(vm.part, 0, &exit_ctx, size_of(exit_ctx))
		if hr < 0 {
			return Exit {
				kind = .Failed,
				detail = fmt.tprintf("WHvRunVirtualProcessor hr=0x%08x", u32(hr)),
			}
		}
		switch exit_ctx.ExitReason {
		case .X64IoPortAccess:
			if ok, detail := whpx_emulate_io(vm, &exit_ctx.VpContext, &exit_ctx.u.IoPortAccess);
			   !ok {
				return Exit{kind = .Failed, detail = detail}
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
		case .Canceled:
			return Exit{kind = .Canceled}
		case .UnrecoverableException:
			return Exit{kind = .Reset, detail = "unrecoverable exception (triple fault)"}
		case .None,
		     .InvalidVpRegisterValue,
		     .UnsupportedFeature,
		     .X64ApicEoi,
		     .X64MsrAccess,
		     .Exception:
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

whpx_request_irq_window :: proc(vm: ^Vm, enable: bool) {
	name := WHV_REGISTER_NAME.DeliverabilityNotifications
	val: WHV_REGISTER_VALUE
	val.Reg64 = enable ? 0x2 : 0x0 // bit1 = InterruptNotification
	WHvSetVirtualProcessorRegisters(vm.part, 0, &name, 1, &val)
}

whpx_can_inject :: proc(vm: ^Vm) -> bool {
	names := [?]WHV_REGISTER_NAME{.Rflags, .PendingInterruption, .InterruptState}
	vals: [len(names)]WHV_REGISTER_VALUE
	if WHvGetVirtualProcessorRegisters(vm.part, 0, &names[0], u32(len(names)), &vals[0]) < 0 {
		return false
	}
	if_set := vals[0].Reg64 & 0x200 != 0
	pending := vals[1].Reg64 & 0x1 != 0
	// WHV_X64_INTERRUPT_STATE_REGISTER: bit0 InterruptShadow, bit1 NmiMasked
	shadow := vals[2].Reg64 & 0x1 != 0
	return if_set && !pending && !shadow
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
		cs_sel = vals[10].Segment.Selector,
		cs_base = vals[10].Segment.Base,
		ss_sel = vals[11].Segment.Selector,
		ss_base = vals[11].Segment.Base,
		ds_sel = vals[12].Segment.Selector,
		es_sel = vals[13].Segment.Selector,
	}
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
