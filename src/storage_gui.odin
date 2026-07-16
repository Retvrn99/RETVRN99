// SPDX-License-Identifier: GPL-3.0-only
package main

import "fat32session"
import "host"
import "profile"
import "core:strings"
import "core:sync"

GUI_STATUS_ADAPTER :: fat32session.Adapter_Kind.In_Process

gui_storage_dispatch_allowed :: proc(
	machine_running, install_active, blocked: bool,
) -> bool {
	return !machine_running && !install_active && !blocked
}

gui_storage_lifecycle_snapshot :: proc(shared: ^Shared) -> (machine_running, install_active: bool) {
	if shared == nil {return}
	sync.lock(&shared.mu)
	machine_running = shared.machine_running
	install_active = shared.installing_windows_98 || shared.install_recovery_required
	sync.unlock(&shared.mu)
	return
}

gui_hard_drive_status :: proc(
	path: string,
	adapter := GUI_STATUS_ADAPTER,
) -> (host.Hard_Drive_Status, string) {
	if path == "" {return .None_Configured, ""}
	info, validation_error := fat32session.validate_image(path, adapter)
	if validation_error.code == .None {
		fat32session.image_info_destroy(&info)
		return .Ready, ""
	}
	diagnostic := strings.clone(fat32session.error_text(&validation_error))
	#partial switch validation_error.code {
	case .Image_Missing:
		return .Missing, diagnostic
	case .Image_Invalid, .State_Mismatch:
		return .Invalid, diagnostic
	case .Image_Locked, .Image_IO, .Helper_Missing, .Protocol_Mismatch:
		return .Unavailable, diagnostic
	}
	return .Unavailable, diagnostic
}

gui_hard_drive_status_refresh :: proc(st: ^host.Menu_State, path: string) {
	if st == nil {return}
	delete(st.hard_drive_diagnostic)
	st.hard_drive_status, st.hard_drive_diagnostic = gui_hard_drive_status(
		path,
		GUI_STATUS_ADAPTER,
	)
	st.hard_drive_path = path
}

gui_hard_drive_select :: proc(
	ctx: ^Vm_Ctx,
	settings: ^profile.Settings,
	st: ^host.Menu_State,
	path: string,
	runtime_machine_running := false,
	runtime_install_active := false,
	adapter := fat32session.DEFAULT_ADAPTER,
) -> bool {
	if ctx == nil || settings == nil || st == nil || path == "" ||
	   runtime_machine_running || runtime_install_active || st.machine_running ||
	   st.install_active || st.install_recovery_required {
		return false
	}
	status, diagnostic := gui_hard_drive_status(path, adapter)
	defer delete(diagnostic)
	if status != .Ready {return false}
	normalized, normalized_ok := profile.settings_normalize_hard_drive_path(path)
	if !normalized_ok {return false}
	previous := settings.hard_drive_path
	settings.hard_drive_path = normalized
	if profile.settings_save(ctx.paths.settings, settings^) != .None {
		delete(normalized)
		settings.hard_drive_path = previous
		return false
	}
	delete(previous)
	delete(ctx.hard_drive_path)
	ctx.hard_drive_path = strings.clone(settings.hard_drive_path)
	ctx.attach = ctx.allow_hard_drive
	gui_hard_drive_status_refresh(st, settings.hard_drive_path)
	return true
}
