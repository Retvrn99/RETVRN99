// SPDX-License-Identifier: GPL-3.0-only
package main

import "core:fmt"
import "fat32session"
import "host"
import "machine"
import "profile"
import video "videopresentation"

graphics_presentation_sync_lifecycle :: proc(
	h: ^host.Host,
	presentation: ^video.Video_Presentation,
	machine_running: bool,
) -> bool {
	if !machine_running {return false}
	adapter := video.video_presentation_host_adapter(h)
	return video.video_presentation_start(presentation, &adapter)
}

gui_vm_lifetime_log :: proc(ctx: rawptr, message: string) {
	c := (^Vm_Ctx)(ctx)
	if c != nil {vm_log(c.shared, message)}
}

gui_vm_lifetime_configure :: proc(ctx: rawptr, m: ^machine.Machine, cmos: []u8) -> bool {
	c := (^Vm_Ctx)(ctx)
	if c == nil || m == nil {return false}
	if c.gsw3d_host != nil {
		backend, backend_ready := host.host_gsw3d_proof_machine_backend(c.gsw3d_host)
		if !backend_ready || !machine.machine_set_gsw3d_backend(m, backend) {return false}
	}
	video.video_presentation_reset(&c.shared.video_presentation)
	if profile.install_state_active(&c.install_state) && !install_prepare_boot_cmos(c, cmos) {
		return false
	}
	machine.machine_set_cpu_mode(m, install_runtime_cpu_mode(c.cpu_mode, &c.install_state))
	return machine.load_roms(&m.vm)
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
	if c == nil || c.lifetime.state == .Uninitialized {return false}
	return !c.attach || vm_lifetime_observation(&c.lifetime).session_ready
}

vm_volume_terminal_error :: proc(c: ^Vm_Ctx) -> (fat32session.Session_Error, bool) {
	if c == nil || c.lifetime.state == .Uninitialized {return {}, false}
	return vm_lifetime_session_terminal_error(&c.lifetime)
}

vm_close_then_shutdown :: proc(c: ^Vm_Ctx, machine_live: ^bool) -> bool {
	if c == nil || machine_live == nil || c.lifetime.state == .Uninitialized {return false}
	if c.lifetime.state == .Stopped {
		machine_live^ = false
		return true
	}
	result := vm_lifetime_stop(&c.lifetime)
	machine_live^ = result.state == .Running
	c.volume_open_error = result.storage_error
	return result.completed
}

vm_start_machine :: proc(c: ^Vm_Ctx, machine_live: ^bool, clock_running: bool = true) -> bool {
	if c == nil || machine_live == nil || machine_live^ || c.lifetime.state == .Uninitialized {
		return false
	}
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
	vm_lifetime_set_clock_running(&c.lifetime, clock_running)
	result := vm_lifetime_start(&c.lifetime)
	c.volume_open_error = result.storage_error
	machine_live^ = result.state == .Running
	return result.completed
}

vm_begin_volume_maintenance :: proc(c: ^Vm_Ctx, machine_live: ^bool) -> bool {
	if c == nil || machine_live == nil || c.lifetime.state == .Uninitialized {return false}
	result := vm_lifetime_begin_storage_maintenance(&c.lifetime)
	machine_live^ = result.state == .Running
	return result.completed
}

vm_end_volume_maintenance :: proc(c: ^Vm_Ctx) -> bool {
	if c == nil || c.lifetime.state == .Uninitialized {return false}
	return vm_lifetime_end_storage_maintenance(&c.lifetime).completed
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
	machine_live: ^bool,
	clock_running: bool = true,
	install_state_changed: bool = false,
) -> Vm_Reinitialize_Diagnostic {
	if c == nil || machine_live == nil || c.lifetime.state == .Uninitialized {
		return .Invalid_State
	}
	if install_state_changed && !profile.install_state_active(&c.install_state) {
		return .Invalid_State
	}
	vm_lifetime_set_clock_running(&c.lifetime, clock_running)
	result := vm_lifetime_reset(&c.lifetime)
	c.volume_open_error = result.storage_error
	machine_live^ = result.state == .Running
	switch result.diagnostic {
	case .None:
		return .None
	case .Durability_Failed, .Clean_Close_Failed:
		return .Durability_Failed
	case .Volume_Open_Failed:
		return .Volume_Open_Failed
	case .Invalid_State,
	     .Guard_Init_Failed,
	     .Machine_Init_Failed,
	     .Machine_Configure_Failed,
	     .Hardware_Trace_Failed,
	     .Media_Failed,
	     .Guard_Destroy_Failed:
		return .Machine_Init_Failed
	}
	return .Machine_Init_Failed
}
