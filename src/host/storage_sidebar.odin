// SPDX-License-Identifier: GPL-3.0-only
package host

import imgui "../../vendor_local/imgui"
import "core:fmt"
import "core:path/filepath"

STORAGE_HEADER_H :: f32(27)
STORAGE_ROW_H :: f32(78)
STORAGE_COLLAPSED_ROW_H :: f32(76)

Storage_Sidebar_Device :: enum {
	Hard_Drive,
	Dvd_Rom,
	Floppy,
}

Storage_Sidebar_Toggle_Direction :: enum {
	Left,
	Right,
}

storage_sidebar_device_order :: [3]Storage_Sidebar_Device {
	.Hard_Drive,
	.Dvd_Rom,
	.Floppy,
}

storage_sidebar_device_label :: proc(device: Storage_Sidebar_Device) -> string {
	switch device {
	case .Hard_Drive: return "Hard disk"
	case .Dvd_Rom:    return "DVD-ROM"
	case .Floppy:     return "Floppy"
	}
	return "Storage"
}

storage_sidebar_device_path :: proc(st: ^Menu_State, device: Storage_Sidebar_Device) -> string {
	if st == nil {return ""}
	switch device {
	case .Hard_Drive: return st.hard_drive_path
	case .Dvd_Rom:    return st.cdrom_path
	case .Floppy:     return st.floppy_path
	}
	return ""
}

storage_sidebar_device_icon :: proc(
	icons: Ui_Icon_Textures,
	device: Storage_Sidebar_Device,
	large: bool,
) -> Ui_Icon_Texture {
	switch device {
	case .Hard_Drive: return large ? icons.hard_drive_32 : icons.hard_drive_16
	case .Dvd_Rom:    return large ? icons.dvd_rom_32 : icons.dvd_rom_16
	case .Floppy:     return large ? icons.floppy_32 : icons.floppy_16
	}
	return {}
}

storage_sidebar_device_active :: proc(st: ^Menu_State, device: Storage_Sidebar_Device) -> bool {
	if st == nil {return false}
	switch device {
	case .Hard_Drive: return st.hard_drive_active
	case .Dvd_Rom:    return st.dvd_rom_active
	case .Floppy:     return st.floppy_active
	}
	return false
}

storage_sidebar_device_state :: proc(st: ^Menu_State, device: Storage_Sidebar_Device) -> string {
	if st == nil {return "Unavailable"}
	switch device {
	case .Hard_Drive:
		switch st.hard_drive_status {
		case .Ready: return "Ready"
		case .None_Configured: return "Not configured"
		case .Missing: return "Missing"
		case .Invalid: return "Invalid"
		case .Unavailable, .Unknown: return "Unavailable"
		}
	case .Dvd_Rom:
		if st.cdrom_unavailable {return "Unavailable"}
		return st.cdrom_mounted ? "Mounted" : "No media"
	case .Floppy:
		if st.floppy_unavailable {return "Unavailable"}
		return st.floppy_mounted ? "Mounted" : "No media"
	}
	return "Unavailable"
}

storage_sidebar_draw_text :: proc(draw: ^imgui.DrawList, position: imgui.Vec2, text: string, color: u32) {
	if draw == nil || len(text) == 0 {return}
	data := raw_data(text)
	imgui.DrawList_AddText(draw, position, color, cstring(data), cstring(data[len(text):]))
}

storage_sidebar_toggle_direction :: proc(collapsed: bool) -> Storage_Sidebar_Toggle_Direction {
	return collapsed ? .Left : .Right
}

storage_sidebar_header :: proc(st: ^Menu_State, width: f32) {
	position := imgui.GetCursorScreenPos()
	imgui.InvisibleButton("##storage_sidebar_header", {width, STORAGE_HEADER_H})
	draw := imgui.GetWindowDrawList()
	maximum := imgui.Vec2{position.x + width, position.y + STORAGE_HEADER_H}
	imgui.DrawList_AddRectFilled(draw, position, maximum, win98_color(THEME_NAVY))
	if !st.sidebar_collapsed {
		win98_draw_title_text(
			draw,
			{position.x + 5, position.y + 5},
			"Storage",
			win98_color(THEME_LIGHT),
		)
	}
	button_size := f32(21)
	button_min := imgui.Vec2{
		st.sidebar_collapsed ? position.x + (width - button_size) * 0.5 : maximum.x - button_size - 3,
		position.y + 3,
	}
	button_max := imgui.Vec2{button_min.x + button_size, button_min.y + button_size}
	imgui.DrawList_AddRectFilled(draw, button_min, button_max, win98_color(THEME_FACE))
	win98_draw_bevel(draw, button_min, button_max, false)
	direction := storage_sidebar_toggle_direction(st.sidebar_collapsed)
	center := imgui.Vec2{(button_min.x + button_max.x) * 0.5, (button_min.y + button_max.y) * 0.5}
	if direction == .Left {
		imgui.DrawList_AddTriangleFilled(
			draw,
			{center.x - 4, center.y},
			{center.x + 3, center.y - 5},
			{center.x + 3, center.y + 5},
			win98_color(THEME_BLACK),
		)
	} else {
		imgui.DrawList_AddTriangleFilled(
			draw,
			{center.x + 4, center.y},
			{center.x - 3, center.y - 5},
			{center.x - 3, center.y + 5},
			win98_color(THEME_BLACK),
		)
	}
	if imgui.IsItemClicked() {st.sidebar_collapsed = !st.sidebar_collapsed}
	if imgui.IsItemHovered() {
		imgui.SetTooltipUnformatted(st.sidebar_collapsed ? "Expand storage sidebar" : "Collapse storage sidebar")
	}
}

storage_device_menu_current_label :: proc(
	st: ^Menu_State,
	device: Storage_Sidebar_Device,
) -> cstring {
	path := storage_sidebar_device_path(st, device)
	if len(path) == 0 {
		return device == .Hard_Drive ? "Current: None" : "Current: No image"
	}
	return fmt.ctprintf("Current: %s", filepath.base(path))
}

storage_device_menu_mount_label :: proc(
	st: ^Menu_State,
	device: Storage_Sidebar_Device,
) -> cstring {
	if device == .Hard_Drive {return ""}
	mounted := device == .Dvd_Rom ? st.cdrom_mounted : st.floppy_mounted
	return mounted ? "Change..." : "Mount..."
}

storage_device_menu_contents :: proc(
	st: ^Menu_State,
	device: Storage_Sidebar_Device,
) -> Menu_Action {
	action := Menu_Action.None
	path := storage_sidebar_device_path(st, device)
	if device == .Hard_Drive {
		if imgui.MenuItem("Browse C:", nil, false, menu_action_enabled(st, .Browse_C_Drive)) {
			action = .Browse_C_Drive
		}
		if imgui.MenuItem("Select Hard Disk...", nil, false, menu_action_enabled(st, .Select_Hard_Drive)) {
			action = .Select_Hard_Drive
		}
		if imgui.MenuItem("Create Hard Disk...", nil, false, menu_action_enabled(st, .Create_Hard_Drive)) {
			action = .Create_Hard_Drive
		}
		imgui.Separator()
		_ = imgui.MenuItem(storage_device_menu_current_label(st, device), nil, false, false)
		if len(path) > 0 {imgui.SetItemTooltip("%s", fmt.ctprintf("%s", path))}
		imgui.Separator()
		if imgui.MenuItem("Properties") {st.show_hard_drive_properties = true}
	} else {
		mounted := device == .Dvd_Rom ? st.cdrom_mounted : st.floppy_mounted
		mount_action := device == .Dvd_Rom ? Menu_Action.Mount_Cdrom : .Mount_Floppy
		eject_action := device == .Dvd_Rom ? Menu_Action.Eject_Cdrom : .Eject_Floppy
		reveal_action := device == .Dvd_Rom ? Menu_Action.Reveal_Cdrom : .Reveal_Floppy
		mount_label := storage_device_menu_mount_label(st, device)
		if imgui.MenuItem(mount_label, nil, false, menu_action_enabled(st, mount_action)) {
			action = mount_action
		}
		if imgui.MenuItem("Eject", nil, false, menu_action_enabled(st, eject_action)) {
			action = eject_action
		}
		imgui.Separator()
		_ = imgui.MenuItem(storage_device_menu_current_label(st, device), nil, false, false)
		if len(path) > 0 {imgui.SetItemTooltip("%s", fmt.ctprintf("%s", path))}
		imgui.Separator()
		if imgui.MenuItem("Reveal Image in Folder", nil, false, menu_action_enabled(st, reveal_action)) {
			action = reveal_action
		}
		if imgui.MenuItem("Copy Path", nil, false, len(path) > 0) {
			imgui.SetClipboardText(fmt.ctprintf("%s", path))
			st.general_status = "Path copied to clipboard"
		}
		imgui.Separator()
		if imgui.MenuItem("Properties") {
			if device == .Dvd_Rom {st.show_cdrom_properties = true}
			else {st.show_floppy_properties = true}
		}
	}
	return action
}

storage_sidebar_context_menu :: proc(
	st: ^Menu_State,
	device: Storage_Sidebar_Device,
) -> Menu_Action {
	if !imgui.BeginPopupContextItem(
		fmt.ctprintf("##storage_context_%d", int(device)),
		imgui.PopupFlags_MouseButtonRight,
	) {
		return .None
	}
	action := storage_device_menu_contents(st, device)
	imgui.EndPopup()
	return action
}

storage_sidebar_expanded_row :: proc(
	st: ^Menu_State,
	icons: Ui_Icon_Textures,
	device: Storage_Sidebar_Device,
	width: f32,
) -> Menu_Action {
	position := imgui.GetCursorScreenPos()
	imgui.InvisibleButton(fmt.ctprintf("##storage_row_%d", int(device)), {width, STORAGE_ROW_H})
	minimum := imgui.GetItemRectMin()
	maximum := imgui.GetItemRectMax()
	draw := imgui.GetWindowDrawList()
	imgui.DrawList_AddRectFilled(draw, minimum, maximum, win98_color(THEME_FACE))
	win98_draw_bevel(draw, minimum, maximum, true)
	icon := storage_sidebar_device_icon(icons, device, true)
	win98_draw_icon(draw, icon, {minimum.x + 9, minimum.y + 12}, 32)
	win98_draw_activity_led(draw, {minimum.x + 25, maximum.y - 14}, storage_sidebar_device_active(st, device))
	text_x := minimum.x + 50
	storage_sidebar_draw_text(draw, {text_x, minimum.y + 8}, storage_sidebar_device_label(device), win98_color(THEME_BLACK))
	path := storage_sidebar_device_path(st, device)
	basename := len(path) > 0 ? filepath.base(path) : "No image"
	storage_sidebar_draw_text(draw, {text_x, minimum.y + 30}, basename, win98_color(THEME_NAVY))
	storage_sidebar_draw_text(
		draw,
		{text_x, minimum.y + 51},
		storage_sidebar_device_state(st, device),
		win98_color(THEME_SHADOW),
	)
	if imgui.IsItemHovered() {
		if len(path) > 0 {imgui.SetTooltip("%s", fmt.ctprintf("%s", path))}
		else {imgui.SetTooltipUnformatted("No image mounted")}
	}
	return storage_sidebar_context_menu(st, device)
}

storage_sidebar_separator :: proc(width: f32) {
	position := imgui.GetCursorScreenPos()
	imgui.Dummy({width, 5})
	draw := imgui.GetWindowDrawList()
	imgui.DrawList_AddLine(draw, {position.x + 3, position.y + 2}, {position.x + width - 3, position.y + 2}, win98_color(THEME_DARK))
	imgui.DrawList_AddLine(draw, {position.x + 3, position.y + 3}, {position.x + width - 3, position.y + 3}, win98_color(THEME_LIGHT))
}

storage_sidebar_collapsed_row :: proc(
	st: ^Menu_State,
	icons: Ui_Icon_Textures,
	device: Storage_Sidebar_Device,
	width: f32,
) -> Menu_Action {
	position := imgui.GetCursorScreenPos()
	imgui.InvisibleButton(fmt.ctprintf("##storage_rail_%d", int(device)), {width, STORAGE_COLLAPSED_ROW_H})
	minimum := imgui.GetItemRectMin()
	maximum := imgui.GetItemRectMax()
	draw := imgui.GetWindowDrawList()
	icon := storage_sidebar_device_icon(icons, device, true)
	win98_draw_icon(draw, icon, {minimum.x + (width - 32) * 0.5, minimum.y + 10}, 32)
	win98_draw_activity_led(draw, {minimum.x + width * 0.5, minimum.y + 57}, storage_sidebar_device_active(st, device))
	if imgui.IsItemHovered() {
		path := storage_sidebar_device_path(st, device)
		if len(path) > 0 {
			imgui.SetTooltip(
				"%s\n%s\n%s",
				fmt.ctprintf("%s", storage_sidebar_device_label(device)),
				fmt.ctprintf("%s", filepath.base(path)),
				fmt.ctprintf("%s", storage_sidebar_device_state(st, device)),
			)
		} else {
			imgui.SetTooltip(
				"%s\n%s",
				fmt.ctprintf("%s", storage_sidebar_device_label(device)),
				fmt.ctprintf("%s", storage_sidebar_device_state(st, device)),
			)
		}
	}
	return storage_sidebar_context_menu(st, device)
}

storage_properties_window :: proc(
	open: ^bool,
	title: cstring,
	icon: Ui_Icon_Texture,
	path, state, diagnostic: string,
) {
	if open == nil || !open^ {return}
	viewport := imgui.GetMainViewport()
	center := imgui.Vec2{viewport.Pos.x + viewport.Size.x * 0.5, viewport.Pos.y + viewport.Size.y * 0.5}
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

storage_sidebar_draw :: proc(st: ^Menu_State, icons: Ui_Icon_Textures) -> Menu_Action {
	action := Menu_Action.None
	if st == nil || st.menu_reveal <= 0 {return action}
	viewport := imgui.GetMainViewport()
	width := f32(st.sidebar_collapsed ? STORAGE_SIDEBAR_COLLAPSED_W : STORAGE_SIDEBAR_EXPANDED_W)
	top := f32(MENU_BAR_H) * st.menu_reveal
	bottom := f32(STATUS_BAR_H) * st.menu_reveal
	height := max(f32(1), viewport.Size.y - top - bottom)
	imgui.SetNextWindowPos({viewport.Pos.x + viewport.Size.x - width * st.menu_reveal, viewport.Pos.y + top})
	imgui.SetNextWindowSize({width, height})
	imgui.SetNextWindowViewport(viewport.ID_)
	imgui.PushStyleVarImVec2(.WindowPadding, {3, 3})
	imgui.PushStyleVar(.WindowBorderSize, 0)
	imgui.PushStyleVarImVec2(.WindowMinSize, {0, 0})
	open := imgui.Begin(
		"##retvrn99_storage_sidebar",
		nil,
		{
			.NoTitleBar,
			.NoResize,
			.NoMove,
			.NoScrollbar,
			.NoScrollWithMouse,
			.NoCollapse,
			.NoSavedSettings,
			.NoFocusOnAppearing,
			.NoBringToFrontOnFocus,
			.NoNavFocus,
			.NoDocking,
		},
	)
	if open {
		content_width := imgui.GetContentRegionAvail().x
		storage_sidebar_header(st, content_width)
		for device, index in storage_sidebar_device_order {
			if index > 0 {storage_sidebar_separator(content_width)}
			row_action := Menu_Action.None
			if st.sidebar_collapsed {
				row_action = storage_sidebar_collapsed_row(st, icons, device, content_width)
			} else {
				row_action = storage_sidebar_expanded_row(st, icons, device, content_width)
			}
			if action == .None && row_action != .None {action = row_action}
		}
	}
	imgui.End()
	imgui.PopStyleVar(3)
	storage_properties_window(
		&st.show_hard_drive_properties,
		"Hard Disk Properties",
		icons.hard_drive_32,
		st.hard_drive_path,
		storage_sidebar_device_state(st, .Hard_Drive),
		st.hard_drive_diagnostic,
	)
	storage_properties_window(
		&st.show_cdrom_properties,
		"DVD-ROM Properties",
		icons.dvd_rom_32,
		st.cdrom_path,
		storage_sidebar_device_state(st, .Dvd_Rom),
		st.cdrom_diagnostic,
	)
	storage_properties_window(
		&st.show_floppy_properties,
		"Floppy Properties",
		icons.floppy_32,
		st.floppy_path,
		storage_sidebar_device_state(st, .Floppy),
		st.floppy_diagnostic,
	)
	return action
}
