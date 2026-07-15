// SPDX-License-Identifier: GPL-3.0-only
package main

import "acceptance"
import "core:fmt"
import "fat32"
import "host"
import "machine"
import "profile"
import sdl3 "vendor:sdl3"

vm_open_volume :: proc(c: ^Vm_Ctx) -> bool {
	if c == nil || !c.attach {return c != nil}
	if vm_volume_ready(c) {return true}
	if c.volume != nil {return false}
	vol := fat32.volume_open(c.paths.c_drive, VOLUME_MB)
	if vol == nil {return false}
	vol.fail_ctx = c.shared
	vol.on_fail = proc(ctx: rawptr, msg: string) {
		vm_log((^Shared)(ctx), fmt.tprintf("disk: writes frozen: %s", msg))
	}
	c.volume = vol
	c.bd = fat32.volume_block_device(vol)
	return true
}

vm_volume_ready :: proc(c: ^Vm_Ctx) -> bool {
	if c == nil {return false}
	if !c.attach {return true}
	return(
		c.volume != nil &&
		!c.volume.frozen &&
		c.bd.ctx == rawptr(c.volume) &&
		c.bd.sector_count > 0 &&
		c.bd.read != nil &&
		c.bd.write != nil &&
		c.bd.flush != nil \
	)
}

vm_ensure_volume :: proc(c: ^Vm_Ctx) -> bool {
	if vm_volume_ready(c) {return true}
	return vm_open_volume(c)
}

vm_close_volume :: proc(c: ^Vm_Ctx) -> bool {
	if c == nil || c.volume == nil {return true}
	if !fat32.volume_close(c.volume) {
		vm_log(c.shared, "disk: reconciliation failed; staged C: writes retained")
		return false
	}
	c.volume = nil
	c.bd = {}
	return true
}

vm_close_then_shutdown :: proc(c: ^Vm_Ctx, m: ^machine.Machine, machine_live: ^bool) -> bool {
	if c == nil {return false}
	if machine_live != nil && machine_live^ {
		if c.volume != nil {
			disk_attached := m != nil && m.has_disk
			if !fat32.volume_flush(c.volume) ||
			   (disk_attached && !machine.machine_detach_disk(m)) {
				vm_log(c.shared, "disk: reconciliation failed; staged C: writes retained")
				return false
			}
			if !vm_close_volume(c) {
				if disk_attached {machine.machine_attach_disk(m, c.bd)}
				return false
			}
		}
		vm_shutdown(c, m)
		machine_live^ = false
		return true
	}
	return vm_close_volume(c)
}

Vm_Reinitialize_Diagnostic :: enum {
	None,
	Invalid_State,
	Reconciliation_Failed,
	Install_Cleanup_Failed,
	Volume_Open_Failed,
	Machine_Init_Failed,
}

vm_reinitialize_machine :: proc(
	c: ^Vm_Ctx,
	m: ^machine.Machine,
	machine_live: ^bool,
	clock_running: bool = true,
	install_state_changed: bool = false,
) -> Vm_Reinitialize_Diagnostic {
	if c == nil || m == nil || machine_live == nil {return .Invalid_State}
	if !vm_close_then_shutdown(c, m, machine_live) {return .Reconciliation_Failed}
	if install_state_changed && !profile.install_state_active(&c.install_state) {
		return .Invalid_State
	}
	if cleanup := install_failed_boot_sentinel_cleanup(
		c.paths.c_drive,
		install_state_changed,
	); cleanup != .None {
		vm_log(c.shared, fmt.tprintf("Windows 98: failed-boot sentinel cleanup failed (%v)", cleanup))
		return .Install_Cleanup_Failed
	}
	if !vm_ensure_volume(c) {return .Volume_Open_Failed}
	if !vm_boot(c, m, clock_running) {return .Machine_Init_Failed}
	machine_live^ = true
	return .None
}

vm_boot :: proc(c: ^Vm_Ctx, m: ^machine.Machine, clock_running: bool = true) -> bool {
	if c == nil ||
	   m == nil ||
	   !install_state_boot_allowed(&c.install_state) ||
	   !vm_volume_ready(c) {
		return false
	}
	hardware_trace := machine.machine_hardware_trace_detach(m)
	booted := false
	defer if !booted {
		vm_guard_unbind(&c.guard)
		host.host_audio_close(&c.audio)
		current_trace := machine.machine_hardware_trace_detach(m)
		if current_trace != nil {
			if hardware_trace == nil {
				hardware_trace = current_trace
			} else if hardware_trace != current_trace {
				free(current_trace)
			}
		}
		machine.machine_destroy(m)
		if hardware_trace != nil && !machine.machine_hardware_trace_attach(m, hardware_trace) {
			free(hardware_trace)
		}
	}
	vm_guard_unbind(&c.guard)
	host.host_audio_close(&c.audio)
	m^ = {}
	if !machine.machine_init(m, RAM_SIZE) {return false}
	if hardware_trace != nil {
		if !machine.machine_hardware_trace_attach(m, hardware_trace) {return false}
		hardware_trace = nil
	}
	if !machine.machine_set_hardware_trace(m, true) {return false}
	if !clock_running {machine.machine_clock_set_running(m, false)}
	frame_mailbox_reset(&c.shared.frames)
	if c.has_cmos {_ = machine.machine_cmos_import(m, c.cmos[:])}
	if profile.install_state_active(&c.install_state) {
		if !install_prepare_boot_cmos(c, m.cmos.ram[:]) {
			return false
		}
	}
	machine.machine_set_cpu_mode(m, install_runtime_cpu_mode(c.cpu_mode, &c.install_state))
	if !machine.load_roms(&m.vm) {
		return false
	}
	if c.attach {machine.machine_attach_disk(m, c.bd)}
	if c.floppy != nil {_ = machine.machine_mount_floppy(m, c.floppy)}
	if c.cdrom_path != "" {
		if machine.machine_attach_cdrom(m, c.cdrom_path) {
			publish_cdrom_state(c.shared, true)
		} else {
			publish_cdrom_state(c.shared, false)
			vm_log(c.shared, fmt.tprintf("CD-ROM: cannot reopen %s", c.cdrom_path))
		}
	}
	if c.audio_enabled && !host.host_audio_open(&c.audio, machine.machine_audio_output(m)) {
		vm_log(c.shared, fmt.tprintf("audio: SDL3 output unavailable (%s)", sdl3.GetError()))
	}
	_ = host.host_audio_set_gain(&c.audio, c.volume_gain)
	vm_guard_bind(&c.guard, &m.vm)
	machine.machine_set_wake_adapter(m, &c.guard, vm_guard_schedule)
	if m.bus.frozen {
		return false
	}
	booted = true
	return true
}

vm_shutdown :: proc(c: ^Vm_Ctx, m: ^machine.Machine) {
	if c == nil {return}
	vm_guard_unbind(&c.guard)
	host.host_audio_close(&c.audio)
	if m == nil || m.vm.part == nil {return}
	saved_cmos := machine.machine_cmos_export(m)
	copy(c.cmos[:], saved_cmos[:])
	c.has_cmos = true
	if diag := profile.cmos_save(c.paths.cmos, c.cmos); diag != .None {
		vm_log(c.shared, fmt.tprintf("CMOS: save failed (%v)", diag))
	}
	hardware_trace := machine.machine_hardware_trace_detach(m)
	machine.machine_destroy(m)
	if hardware_trace != nil && !machine.machine_hardware_trace_attach(m, hardware_trace) {
		free(hardware_trace)
	}
}

console_reinitialize_machine :: proc(
	m: ^machine.Machine,
	guard: ^Vm_Guard,
	machine_live: ^bool,
	vol: ^^fat32.Volume,
	paths: ^profile.Paths,
	settings: profile.Settings,
	cmos: []u8,
	attach: bool,
	cdrom_path: string,
	floppy: []u8,
	options: ^acceptance.Options,
	install_state_changed: bool = false,
) -> bool {
	return console_reinitialize_machine_with_ram(
		m,
		guard,
		machine_live,
		vol,
		paths,
		settings,
		cmos,
		attach,
		cdrom_path,
		floppy,
		options,
		RAM_SIZE,
		install_state_changed,
	)
}

@(private)
console_reinitialize_machine_with_ram :: proc(
	m: ^machine.Machine,
	guard: ^Vm_Guard,
	machine_live: ^bool,
	vol: ^^fat32.Volume,
	paths: ^profile.Paths,
	settings: profile.Settings,
	cmos: []u8,
	attach: bool,
	cdrom_path: string,
	floppy: []u8,
	options: ^acceptance.Options,
	ram_size: int,
	install_state_changed: bool = false,
) -> bool {
	if m == nil ||
	   guard == nil ||
	   machine_live == nil ||
	   !machine_live^ ||
	   vol == nil ||
	   paths == nil ||
	   options == nil {
		return false
	}
	if vol^ != nil {
		disk_attached := m.has_disk
		if !fat32.volume_flush(vol^) || (disk_attached && !machine.machine_detach_disk(m)) {
			return false
		}
		block_device := fat32.volume_block_device(vol^)
		if !fat32.volume_close(vol^) {
			if disk_attached {machine.machine_attach_disk(m, block_device)}
			return false
		}
		vol^ = nil
	}
	reinitialized := false
	success := false
	vm_guard_unbind(guard)
	hardware_trace := machine.machine_hardware_trace_detach(m)
	defer if !success {
		if reinitialized {
			current_trace := machine.machine_hardware_trace_detach(m)
			if current_trace != nil {
				if hardware_trace == nil {
					hardware_trace = current_trace
				} else if hardware_trace != current_trace {
					free(current_trace)
				}
			}
			vm_guard_unbind(guard)
			machine.machine_destroy(m)
		}
		if hardware_trace != nil {
			if machine.machine_hardware_trace_attach(m, hardware_trace) {
				hardware_trace = nil
			} else {
				free(hardware_trace)
				hardware_trace = nil
			}
		}
		machine_live^ = false
	}
	machine.machine_destroy(m)
	machine_live^ = false
	m^ = {}
	if cleanup := install_failed_boot_sentinel_cleanup(
		paths.c_drive,
		install_state_changed,
	); cleanup != .None {
		fmt.eprintfln("Windows 98: failed-boot sentinel cleanup failed (%v)", cleanup)
		return false
	}
	if !machine.machine_init(m, ram_size) {return false}
	reinitialized = true
	if hardware_trace != nil {
		if !machine.machine_hardware_trace_attach(m, hardware_trace) {return false}
		hardware_trace = nil
	} else {
		if !machine.machine_set_hardware_trace(m, true) {return false}
	}
	if len(cmos) > 0 {_ = machine.machine_cmos_import(m, cmos)}
	if !machine.load_roms(&m.vm) {return false}
	machine.machine_set_cpu_mode(m, settings.cpu_mode)
	machine.bus_set_strict_io(&m.bus, options.strict_io)
	machine.machine_set_diagnostic_tracing(m, options.strict_io)
	machine.machine_set_bus_diagnostic_tracing(
		m,
		options.setup_diagnostics == .Hardware,
	)
	if options.test_device {machine.machine_enable_test_device(m)}
	if attach {
		vol^ = fat32.volume_open(paths.c_drive, VOLUME_MB)
		if vol^ == nil {return false}
		vol^^.on_fail = proc(ctx: rawptr, msg: string) {
			fmt.printfln("disk: writes frozen: %s", msg)
		}
		machine.machine_attach_disk(m, fat32.volume_block_device(vol^))
	}
	if cdrom_path != "" && !machine.machine_attach_cdrom(m, cdrom_path) {return false}
	if len(floppy) > 0 && !machine.machine_mount_floppy(m, floppy) {return false}
	vm_guard_bind(guard, &m.vm)
	machine.machine_set_wake_adapter(m, guard, vm_guard_schedule)
	if m.bus.frozen {return false}
	success = true
	machine_live^ = true
	return true
}
