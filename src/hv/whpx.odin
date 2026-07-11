// SPDX-License-Identifier: GPL-3.0-only
package hv

import "base:runtime"
import "core:fmt"
import win32 "core:sys/windows"

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

	part: WHV_PARTITION_HANDLE
	if WHvCreatePartition(&part) < 0 {
		return false
	}
	vm.part = part

	count: u32 = 1
	if WHvSetPartitionProperty(part, .ProcessorCount, &count, size_of(count)) < 0 {
		whpx_destroy(vm)
		return false
	}
	ext_exits: u64 = 0 // X64CpuidExit=0, sin salidas extendidas
	if WHvSetPartitionProperty(part, .ExtendedVmExits, &ext_exits, size_of(ext_exits)) < 0 {
		whpx_destroy(vm)
		return false
	}
	if WHvSetupPartition(part) < 0 {
		whpx_destroy(vm)
		return false
	}

	ram := win32.VirtualAlloc(nil, uint(ram_size), win32.MEM_COMMIT | win32.MEM_RESERVE, win32.PAGE_READWRITE)
	if ram == nil {
		whpx_destroy(vm)
		return false
	}
	vm.ram = ([^]u8)(ram)[:ram_size]

	flags := WHV_MAP_GPA_RANGE_FLAG_READ | WHV_MAP_GPA_RANGE_FLAG_WRITE | WHV_MAP_GPA_RANGE_FLAG_EXECUTE
	if WHvMapGpaRange(part, ram, 0, u64(ram_size), flags) < 0 {
		whpx_destroy(vm)
		return false
	}

	if WHvCreateVirtualProcessor(part, 0, 0) < 0 {
		whpx_destroy(vm)
		return false
	}
	whpx_reset_vcpu(vm)

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
}

// estado de encendido: modo real, CS F000:FFF0
whpx_reset_vcpu :: proc(vm: ^Vm) {
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
	names := [?]WHV_REGISTER_NAME{
		.Cs, .Ds, .Es, .Ss, .Fs, .Gs,
		.Rip, .Rflags,
		.Rax, .Rbx, .Rcx, .Rdx, .Rsp, .Rbp, .Rsi, .Rdi,
	}
	vals: [len(names)]WHV_REGISTER_VALUE
	vals[0].Segment = code_seg
	for i in 1 ..< 6 {
		vals[i].Segment = data_seg
	}
	vals[6].Reg64 = 0xFFF0
	vals[7].Reg64 = 0x2
	WHvSetVirtualProcessorRegisters(vm.part, 0, &names[0], u32(len(names)), &vals[0])
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

whpx_run :: proc(vm: ^Vm) -> Exit {
	exit_ctx: WHV_RUN_VP_EXIT_CONTEXT
	for {
		hr := WHvRunVirtualProcessor(vm.part, 0, &exit_ctx, size_of(exit_ctx))
		if hr < 0 {
			return Exit{kind = .Failed, detail = fmt.tprintf("WHvRunVirtualProcessor hr=0x%08x", u32(hr))}
		}
		switch exit_ctx.ExitReason {
		case .X64IoPortAccess:
			status: WHV_EMULATOR_STATUS
			hr = WHvEmulatorTryIoEmulation(vm.emu, vm, &exit_ctx.VpContext, &exit_ctx.u.IoPortAccess, &status)
			if hr < 0 || status.AsUINT32 & 1 == 0 {
				return Exit{
					kind = .Failed,
					detail = fmt.tprintf("emulación E/S puerto 0x%04x hr=0x%08x estado=0x%08x",
						exit_ctx.u.IoPortAccess.PortNumber, u32(hr), status.AsUINT32),
				}
			}
		case .MemoryAccess:
			status: WHV_EMULATOR_STATUS
			hr = WHvEmulatorTryMmioEmulation(vm.emu, vm, &exit_ctx.VpContext, &exit_ctx.u.MemoryAccess, &status)
			if hr < 0 || status.AsUINT32 & 1 == 0 {
				return Exit{
					kind = .Failed,
					detail = fmt.tprintf("emulación MMIO gpa=0x%x hr=0x%08x estado=0x%08x",
						exit_ctx.u.MemoryAccess.Gpa, u32(hr), status.AsUINT32),
				}
			}
		case .X64Halt:
			// avanzar RIP más allá del HLT
			whpx_advance_rip(vm, &exit_ctx.VpContext)
			return Exit{kind = .Halt}
		case .X64InterruptWindow:
			return Exit{kind = .Interrupt_Window}
		case .Canceled:
			return Exit{kind = .Canceled}
		case .None, .UnrecoverableException, .InvalidVpRegisterValue, .UnsupportedFeature,
		     .X64ApicEoi, .X64MsrAccess, .X64Cpuid, .Exception:
			return Exit{kind = .Failed, detail = fmt.tprintf("salida no manejada: %v", exit_ctx.ExitReason)}
		case:
			return Exit{kind = .Failed, detail = fmt.tprintf("salida desconocida: %d", u32(exit_ctx.ExitReason))}
		}
	}
}

whpx_advance_rip :: proc(vm: ^Vm, vp_ctx: ^WHV_VP_EXIT_CONTEXT) {
	name := WHV_REGISTER_NAME.Rip
	val: WHV_REGISTER_VALUE
	val.Reg64 = vp_ctx.Rip + u64(vp_ctx.InstructionLengthCr8 & 0xF)
	WHvSetVirtualProcessorRegisters(vm.part, 0, &name, 1, &val)
}

whpx_inject_irq :: proc(vm: ^Vm, vector: u8) {
	name := WHV_REGISTER_NAME.PendingInterruption
	val: WHV_REGISTER_VALUE
	// bit0 pendiente, tipo 0 (interrupción externa), vector en bits 16..31
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
	names := [?]WHV_REGISTER_NAME{.Rflags, .PendingInterruption}
	vals: [len(names)]WHV_REGISTER_VALUE
	if WHvGetVirtualProcessorRegisters(vm.part, 0, &names[0], u32(len(names)), &vals[0]) < 0 {
		return false
	}
	if_set := vals[0].Reg64 & 0x200 != 0
	pending := vals[1].Reg64 & 0x1 != 0
	return if_set && !pending
}

whpx_reg_rax :: proc(vm: ^Vm) -> u64 {
	name := WHV_REGISTER_NAME.Rax
	val: WHV_REGISTER_VALUE
	WHvGetVirtualProcessorRegisters(vm.part, 0, &name, 1, &val)
	return val.Reg64
}

// --- callbacks del emulador (WinHvEmulation) ---

whpx_emu_io :: proc "system" (ctx: rawptr, io: ^WHV_EMULATOR_IO_ACCESS_INFO) -> HRESULT {
	context = runtime.default_context()
	vm := (^Vm)(ctx)
	if io.Direction == 0 {
		io.Data = vm.io_read != nil ? vm.io_read(vm.io_ctx, io.Port, u8(io.AccessSize)) : 0xFFFFFFFF
	} else {
		if vm.io_write != nil {
			vm.io_write(vm.io_ctx, io.Port, u8(io.AccessSize), io.Data)
		}
	}
	return 0
}

whpx_emu_mmio :: proc "system" (ctx: rawptr, mem: ^WHV_EMULATOR_MEMORY_ACCESS_INFO) -> HRESULT {
	context = runtime.default_context()
	vm := (^Vm)(ctx)
	size := int(mem.AccessSize)
	if size > len(mem.Data) {
		size = len(mem.Data)
	}
	if vm.mmio != nil {
		vm.mmio(vm.io_ctx, mem.GpaAddress, mem.Direction == 1, mem.Data[:size])
	} else if mem.Direction == 0 {
		for i in 0 ..< size {
			mem.Data[i] = 0xFF
		}
	}
	return 0
}

whpx_emu_get_regs :: proc "system" (ctx: rawptr, names: [^]WHV_REGISTER_NAME, count: u32, values: [^]WHV_REGISTER_VALUE) -> HRESULT {
	vm := (^Vm)(ctx)
	return WHvGetVirtualProcessorRegisters(vm.part, 0, names, count, values)
}

whpx_emu_set_regs :: proc "system" (ctx: rawptr, names: [^]WHV_REGISTER_NAME, count: u32, values: [^]WHV_REGISTER_VALUE) -> HRESULT {
	vm := (^Vm)(ctx)
	return WHvSetVirtualProcessorRegisters(vm.part, 0, names, count, values)
}

// sin paginación en M1: GVA == GPA
whpx_emu_translate :: proc "system" (ctx: rawptr, gva: u64, flags: u32, result: ^u32, gpa: ^u64) -> HRESULT {
	result^ = 0 // WHvTranslateGvaResultSuccess
	gpa^ = gva
	return 0
}
