// SPDX-License-Identifier: GPL-3.0-only
package main

import "acceptance"
import "core:fmt"
import "fat32session"
import "host"
import "machine"
import "profile"
import sdl3 "vendor:sdl3"

graphics_presentation_sync_lifecycle :: proc(
	h: ^host.Host,
	frames: ^Frame_Mailbox,
	machine_running: bool,
) -> bool {
	if !machine_running {return false}
	return host.host_presentation_start(h, frame_mailbox_lifecycle_generation(frames))
}

vm_open_volume :: proc(c: ^Vm_Ctx) -> bool {
	return vm_open_volume_with_adapter(c, fat32session.DEFAULT_ADAPTER)
}

vm_open_volume_with_adapter :: proc(c: ^Vm_Ctx, adapter: fat32session.Adapter_Kind) -> bool {
	if c == nil {return false}
	c.volume_open_error = {}
	if !c.attach {return true}
	if vm_volume_ready(c) {return true}
	if c.fat_session != nil {return false}
	session, open_error := fat32session.open_machine(
		c.hard_drive_path,
		c.machine_session_id,
		adapter,
	)
	if open_error.code != .None {
		c.volume_open_error = open_error
		vm_log(
			c.shared,
			fmt.tprintf(
				"disk: FAT32 session open failed: %s",
				fat32session.error_text(&open_error),
			),
		)
		return false
	}
	c.fat_session = session
	return true
}

vm_volume_open_failure_message :: proc(c: ^Vm_Ctx, operation: string) -> string {
	if c == nil || c.volume_open_error.code == .None {
		return fmt.tprintf("%s failed: hard-drive storage could not be opened", operation)
	}
	return fmt.tprintf(
		"%s failed: hard-drive storage error %v: %s",
		operation,
		c.volume_open_error.code,
		fat32session.error_text(&c.volume_open_error),
	)
}

vm_volume_ready :: proc(c: ^Vm_Ctx) -> bool {
	if c == nil {return false}
	if !c.attach {return true}
	return fat32session.session_ready(c.fat_session)
}

vm_ensure_volume :: proc(c: ^Vm_Ctx) -> bool {
	if vm_volume_ready(c) {return true}
	return vm_open_volume(c)
}

vm_close_volume :: proc(c: ^Vm_Ctx) -> bool {
	if c == nil || c.fat_session == nil {return true}
	close_error := fat32session.close(c.fat_session, .Commit)
	if close_error.outcome == .Completed {
		c.fat_session = nil
		vm_log(
			c.shared,
			fmt.tprintf(
				"disk: close completed with a companion cleanup warning: %s",
				fat32session.error_text(&close_error),
			),
		)
		return true
	}
	if close_error.code != .None {
		vm_log(
			c.shared,
			fmt.tprintf(
				"disk: close failed; FAT32 session retained: %s",
				fat32session.error_text(&close_error),
			),
		)
		return false
	}
	c.fat_session = nil
	return true
}

vm_release_failed_boot_volume :: proc(c: ^Vm_Ctx) -> bool {
	if c == nil || c.fat_session == nil {return true}
	if vm_close_volume(c) {return true}
	retain_error := fat32session.close(c.fat_session, .Retain)
	c.fat_session = nil
	if retain_error.code != .None {
		vm_log(
			c.shared,
			fmt.tprintf(
				"disk: failed boot session released with recovery evidence: %s",
				fat32session.error_text(&retain_error),
			),
		)
		return false
	}
	vm_log(c.shared, "disk: failed boot session retained for recovery and released")
	return true
}

machine_session_release_after_failed_reset :: proc(
	session: ^^fat32session.Machine_Session,
) -> bool {
	if session == nil || session^ == nil {return true}
	close_error := fat32session.close(session^, .Commit)
	if close_error.code == .None || close_error.outcome == .Completed {
		session^ = nil
		return true
	}
	retain_error := fat32session.close(session^, .Retain)
	session^ = nil
	return retain_error.code == .None
}

vm_volume_terminal_error :: proc(c: ^Vm_Ctx) -> (fat32session.Session_Error, bool) {
	if c == nil || c.fat_session == nil {return {}, false}
	return fat32session.session_terminal_error(c.fat_session)
}

vm_close_then_shutdown :: proc(c: ^Vm_Ctx, m: ^machine.Machine, machine_live: ^bool) -> bool {
	if c == nil {return false}
	if machine_live != nil && machine_live^ {
		if c.fat_session != nil {
			disk_attached := m != nil && m.has_disk
			_, barrier_error := fat32session.barrier(c.fat_session, .Clean_Close)
			if barrier_error.code != .None || (disk_attached && !machine.machine_detach_disk(m)) {
				vm_log(
					c.shared,
					fmt.tprintf(
						"disk: clean-close barrier failed: %s",
						fat32session.error_text(&barrier_error),
					),
				)
				return false
			}
			if !vm_close_volume(c) {
				if disk_attached {machine.machine_attach_disk(m, fat32session.block_device(c.fat_session))}
				return false
			}
		}
		vm_shutdown(c, m)
		machine_live^ = false
		return true
	}
	return vm_close_volume(c)
}

vm_start_machine :: proc(
	c: ^Vm_Ctx,
	m: ^machine.Machine,
	machine_live: ^bool,
	clock_running: bool = true,
) -> bool {
	if c == nil || m == nil || machine_live == nil || machine_live^ {return false}
	selected_image_path := c.attach ? c.hard_drive_path : ""
	install_gate := install_image_boot_gate_loaded(
		&c.install_state,
		selected_image_path,
		c.install_state_diagnostic,
	)
	if !install_gate.allowed {
		vm_log(
			c.shared,
			fmt.tprintf(
				"Windows 98: start blocked: %s",
				install_image_boot_diagnostic_text(&install_gate),
			),
		)
		return false
	}
	if !vm_ensure_volume(c) {return false}
	if !vm_boot(c, m, clock_running) {
		_ = vm_release_failed_boot_volume(c)
		return false
	}
	machine_live^ = true
	return true
}

vm_begin_volume_maintenance :: proc(c: ^Vm_Ctx, m: ^machine.Machine, machine_live: ^bool) -> bool {
	if c == nil || m == nil || machine_live == nil {return false}
	return vm_close_then_shutdown(c, m, machine_live)
}

vm_end_volume_maintenance :: proc(c: ^Vm_Ctx) -> bool {
	return c != nil && c.fat_session == nil
}

Vm_Reinitialize_Diagnostic :: enum {
	None,
	Invalid_State,
	Durability_Failed,
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
	if !machine_live^ || (c.attach && c.fat_session == nil) {return .Invalid_State}
	if c.attach {
		_, reset_error := fat32session.barrier(c.fat_session, .Reset)
		if reset_error.code != .None {return .Durability_Failed}
		if m.has_disk && !machine.machine_detach_disk(m) {return .Durability_Failed}
	}
	vm_shutdown(c, m)
	machine_live^ = false
	if install_state_changed && !profile.install_state_active(&c.install_state) {
		_ = vm_release_failed_boot_volume(c)
		return .Invalid_State
	}
	if !vm_boot(c, m, clock_running) {
		_ = vm_release_failed_boot_volume(c)
		return .Machine_Init_Failed
	}
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
	if c.gsw3d_host != nil {
		backend, backend_ready := host.host_gsw3d_proof_machine_backend(c.gsw3d_host)
		if !backend_ready || !machine.machine_set_gsw3d_backend(m, backend) {return false}
	}
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
	if c.attach {machine.machine_attach_disk(m, fat32session.block_device(c.fat_session))}
	if c.floppy != nil {_ = machine.machine_mount_floppy(m, c.floppy)}
	if c.cdrom_path != "" {
		if machine.machine_attach_cdrom(m, c.cdrom_path) {
			publish_cdrom_state(c.shared, true, c.cdrom_path)
		} else {
			publish_cdrom_state(
				c.shared,
				false,
				"",
				c.cdrom_path,
				"The selected disc image could not be reopened",
			)
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
	session: ^^fat32session.Machine_Session,
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
		session,
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
	session: ^^fat32session.Machine_Session,
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
	   session == nil ||
	   paths == nil ||
	   options == nil {
		return false
	}
	if attach && session^ == nil {return false}
	if session^ != nil {
		_, reset_error := fat32session.barrier(session^, .Reset)
		if reset_error.code != .None {return false}
		if m.has_disk && !machine.machine_detach_disk(m) {return false}
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
		_ = machine_session_release_after_failed_reset(session)
		machine_live^ = false
	}
	machine.machine_destroy(m)
	machine_live^ = false
	m^ = {}
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
	machine.machine_set_bus_diagnostic_tracing(m, options.setup_diagnostics == .Hardware)
	if options.test_device {machine.machine_enable_test_device(m)}
	if attach {
		machine.machine_attach_disk(m, fat32session.block_device(session^))
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
