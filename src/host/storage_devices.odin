// SPDX-License-Identifier: GPL-3.0-only
package host

import imgui "../../vendor_local/imgui"
import opticaldrive "../opticaldrive"
import "core:fmt"
import "core:path/filepath"

Storage_Device :: enum {
	Hard_Drive,
	Optical_Drive,
	Floppy,
}

storage_menu_device_order :: [3]Storage_Device{.Hard_Drive, .Optical_Drive, .Floppy}
status_bar_storage_device_order :: [3]Storage_Device{.Floppy, .Hard_Drive, .Optical_Drive}

storage_device_label :: proc(device: Storage_Device) -> string {
	switch device {
	case .Hard_Drive:
		return "Hard disk"
	case .Optical_Drive:
		return "DVD-ROM"
	case .Floppy:
		return "Floppy"
	}
	return "Storage"
}

storage_device_path :: proc(st: ^Menu_State, device: Storage_Device) -> string {
	if st == nil {return ""}
	switch device {
	case .Hard_Drive:
		return st.hard_drive_path
	case .Optical_Drive:
		return st.cdrom_path
	case .Floppy:
		return st.floppy_path
	}
	return ""
}

storage_device_mounted :: proc(st: ^Menu_State, device: Storage_Device) -> bool {
	if st == nil {return false}
	switch device {
	case .Hard_Drive:
		return st.hard_drive_status == .Ready && len(st.hard_drive_path) > 0
	case .Optical_Drive:
		return st.cdrom_mounted
	case .Floppy:
		return st.floppy_mounted
	}
	return false
}

storage_device_icon :: proc(
	icons: Ui_Icon_Textures,
	device: Storage_Device,
	large: bool,
) -> Ui_Icon_Texture {
	switch device {
	case .Hard_Drive:
		return large ? icons.hard_drive_32 : icons.hard_drive_16
	case .Optical_Drive:
		return large ? icons.dvd_rom_32 : icons.dvd_rom_16
	case .Floppy:
		return large ? icons.floppy_32 : icons.floppy_16
	}
	return {}
}

storage_device_active :: proc(st: ^Menu_State, device: Storage_Device) -> bool {
	if st == nil {return false}
	switch device {
	case .Hard_Drive:
		return st.hard_drive_active
	case .Optical_Drive:
		return st.dvd_rom_active
	case .Floppy:
		return st.floppy_active
	}
	return false
}

storage_device_state :: proc(st: ^Menu_State, device: Storage_Device) -> string {
	if st == nil {return "Unavailable"}
	switch device {
	case .Hard_Drive:
		switch st.hard_drive_status {
		case .Ready:
			return "Ready"
		case .None_Configured:
			return "Not configured"
		case .Missing:
			return "Missing"
		case .Invalid:
			return "Invalid"
		case .Unavailable, .Unknown:
			return "Unavailable"
		}
	case .Optical_Drive:
		if st.cdrom_unavailable {return "Unavailable"}
		return st.cdrom_mounted ? "Mounted" : "No media"
	case .Floppy:
		if st.floppy_unavailable {return "Unavailable"}
		return st.floppy_mounted ? "Mounted" : "No media"
	}
	return "Unavailable"
}

storage_device_tooltip :: proc(st: ^Menu_State, device: Storage_Device) -> string {
	path := storage_device_path(st, device)
	return len(path) > 0 ? path : "Empty"
}

storage_device_current_name :: proc(st: ^Menu_State, device: Storage_Device) -> string {
	path := storage_device_path(st, device)
	if len(path) == 0 {return ""}
	if device == .Optical_Drive {
		if letter, physical := opticaldrive.path_letter(path); physical {
			return fmt.tprintf("Host drive %c:", letter)
		}
	}
	return filepath.base(path)
}

storage_device_menu_current_label :: proc(st: ^Menu_State, device: Storage_Device) -> cstring {
	name := storage_device_current_name(st, device)
	if len(name) == 0 {return device == .Hard_Drive ? "Current: None" : "Current: No image"}
	return fmt.ctprintf("Current: %s", name)
}

storage_device_menu_contents :: proc(st: ^Menu_State, device: Storage_Device) -> Menu_Action {
	if st == nil {return .None}
	if device != .Hard_Drive {return storage_removable_menu_contents(st, device)}
	action := Menu_Action.None
	if imgui.MenuItem("Browse C:", nil, false, menu_action_enabled(st, .Browse_C_Drive)) {
		action = .Browse_C_Drive
	}
	if imgui.MenuItem(
		"Select Hard Disk...",
		nil,
		false,
		menu_action_enabled(st, .Select_Hard_Drive),
	) {
		action = .Select_Hard_Drive
	}
	if imgui.MenuItem(
		"Create Hard Disk...",
		nil,
		false,
		menu_action_enabled(st, .Create_Hard_Drive),
	) {
		action = .Create_Hard_Drive
	}
	imgui.Separator()
	_ = imgui.MenuItem(storage_device_menu_current_label(st, device), nil, false, false)
	if len(st.hard_drive_path) > 0 {
		imgui.SetItemTooltip("%s", fmt.ctprintf("%s", st.hard_drive_path))
	}
	imgui.Separator()
	if imgui.MenuItem("Properties") {st.show_hard_drive_properties = true}
	return action
}

storage_removable_menu_contents :: proc(st: ^Menu_State, device: Storage_Device) -> Menu_Action {
	if st == nil || device == .Hard_Drive {return .None}
	action := Menu_Action.None
	path := storage_device_path(st, device)
	mounted := storage_device_mounted(st, device)
	mount_action := device == .Optical_Drive ? Menu_Action.Mount_Cdrom : .Mount_Floppy
	eject_action := device == .Optical_Drive ? Menu_Action.Eject_Cdrom : .Eject_Floppy
	reveal_action := device == .Optical_Drive ? Menu_Action.Reveal_Cdrom : .Reveal_Floppy
	mount_label: cstring = mounted ? "Change..." : "Mount..."
	if imgui.MenuItem(mount_label, nil, false, menu_action_enabled(st, mount_action)) {
		action = mount_action
	}
	if device == .Optical_Drive &&
	   menu_begin("Use Host Optical Drive", menu_action_enabled(st, .Mount_Host_Cdrom)) {
		found := false
		for index in 0 ..< len(st.host_optical_drives) {
			if !st.host_optical_drives[index] {continue}
			found = true
			letter := u8('A' + index)
			if imgui.MenuItem(fmt.ctprintf("%c:", letter)) {
				st.requested_host_optical = letter
				action = .Mount_Host_Cdrom
			}
		}
		if !found {_ = imgui.MenuItem("No host optical drives found", nil, false, false)}
		menu_end()
	}
	if imgui.MenuItem("Eject", nil, false, menu_action_enabled(st, eject_action)) {
		action = eject_action
	}
	imgui.Separator()
	_ = imgui.MenuItem(storage_device_menu_current_label(st, device), nil, false, false)
	if len(path) > 0 {imgui.SetItemTooltip("%s", fmt.ctprintf("%s", path))}
	imgui.Separator()
	_, physical := opticaldrive.path_letter(path)
	if imgui.MenuItem(
		"Reveal Image in Folder",
		nil,
		false,
		!physical && menu_action_enabled(st, reveal_action),
	) {
		action = reveal_action
	}
	if imgui.MenuItem("Copy Path", nil, false, len(path) > 0) {
		imgui.SetClipboardText(fmt.ctprintf("%s", path))
		st.general_status = "Path copied to clipboard"
	}
	imgui.Separator()
	if imgui.MenuItem("Properties") {
		if device == .Optical_Drive {
			st.show_cdrom_properties = true
		} else {
			st.show_floppy_properties = true
		}
	}
	return action
}

storage_properties_window :: proc(
	open: ^bool,
	title: cstring,
	icon: Ui_Icon_Texture,
	path, state, diagnostic: string,
) {
	if open == nil || !open^ {return}
	viewport := imgui.GetMainViewport()
	center := imgui.Vec2 {
		viewport.Pos.x + viewport.Size.x * 0.5,
		viewport.Pos.y + viewport.Size.y * 0.5,
	}
	imgui.SetNextWindowPos(center, .Appearing, {0.5, 0.5})
	if win98_begin_window(title, open, {.AlwaysAutoResize, .NoCollapse, .NoSavedSettings}) {
		imgui.Image(win98_texture_ref(icon), {32, 32})
		imgui.SameLine()
		menu_text(state)
		imgui.Separator()
		menu_text(len(path) > 0 ? path : "No image selected")
		if len(diagnostic) > 0 {
			imgui.Separator()
			menu_text(diagnostic)
		}
		imgui.Separator()
		if imgui.Button("OK") {open^ = false}
	}
	imgui.End()
}

storage_properties_draw :: proc(st: ^Menu_State, icons: Ui_Icon_Textures) {
	if st == nil {return}
	storage_properties_window(
		&st.show_hard_drive_properties,
		"Hard Disk Properties",
		icons.hard_drive_32,
		st.hard_drive_path,
		storage_device_state(st, .Hard_Drive),
		st.hard_drive_diagnostic,
	)
	storage_properties_window(
		&st.show_cdrom_properties,
		"Optical Drive Properties",
		icons.dvd_rom_32,
		st.cdrom_path,
		storage_device_state(st, .Optical_Drive),
		st.cdrom_diagnostic,
	)
	storage_properties_window(
		&st.show_floppy_properties,
		"Floppy Drive Properties",
		icons.floppy_32,
		st.floppy_path,
		storage_device_state(st, .Floppy),
		st.floppy_diagnostic,
	)
}
