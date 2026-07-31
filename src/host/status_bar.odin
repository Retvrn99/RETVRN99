// SPDX-License-Identifier: GPL-3.0-only
package host

import imgui "../../vendor_local/imgui"
import "core:fmt"

STATUS_MACHINE_CELL_W :: f32(170)
STATUS_CELL_GAP :: f32(3)
STATUS_STORAGE_ITEM_W :: f32(48)
STATUS_STORAGE_ICON_SIZE :: f32(32)

status_bar_storage_width :: proc() -> f32 {
	return(
		STATUS_STORAGE_ITEM_W * f32(len(status_bar_storage_device_order)) +
		STATUS_CELL_GAP * f32(len(status_bar_storage_device_order) - 1) \
	)
}

status_bar_machine_text :: proc(st: ^Menu_State) -> string {
	if st == nil || !st.machine_running {return "Machine stopped"}
	if st.machine_paused {return "Machine paused"}
	return "Machine running"
}

status_bar_current_image_label :: proc(st: ^Menu_State, device: Storage_Device) -> cstring {
	name := storage_device_current_name(st, device)
	return fmt.ctprintf("Current image file: %s", name)
}

status_bar_removable_menu_contents :: proc(
	st: ^Menu_State,
	device: Storage_Device,
) -> Menu_Action {
	if st == nil || device == .Hard_Drive {return .None}
	action := Menu_Action.None
	mounted := storage_device_mounted(st, device)
	path := storage_device_path(st, device)
	if mounted {
		_ = imgui.MenuItem(status_bar_current_image_label(st, device), nil, false, false)
		if len(path) > 0 {imgui.SetItemTooltip("%s", fmt.ctprintf("%s", path))}
		imgui.Separator()
	}
	mount_action := device == .Optical_Drive ? Menu_Action.Mount_Cdrom : .Mount_Floppy
	if imgui.MenuItem("Mount...", nil, false, menu_action_enabled(st, mount_action)) {
		action = mount_action
	}
	if mounted {
		eject_action := device == .Optical_Drive ? Menu_Action.Eject_Cdrom : .Eject_Floppy
		if imgui.MenuItem("Eject", nil, false, menu_action_enabled(st, eject_action)) {
			action = eject_action
		}
	}
	return action
}

status_bar_storage_context_menu :: proc(st: ^Menu_State, device: Storage_Device) -> Menu_Action {
	if !imgui.BeginPopupContextItem(
		fmt.ctprintf("##status_storage_context_%d", int(device)),
		imgui.PopupFlags_MouseButtonRight,
	) {
		return .None
	}
	action :=
		device == .Hard_Drive ? hard_drive_menu_contents(st) : status_bar_removable_menu_contents(st, device)
	imgui.EndPopup()
	return action
}

status_bar_storage_item :: proc(
	st: ^Menu_State,
	icons: Ui_Icon_Textures,
	device: Storage_Device,
	height: f32,
) -> Menu_Action {
	imgui.InvisibleButton(
		fmt.ctprintf("##status_storage_%d", int(device)),
		{STATUS_STORAGE_ITEM_W, height},
	)
	minimum := imgui.GetItemRectMin()
	maximum := imgui.GetItemRectMax()
	draw := imgui.GetWindowDrawList()
	imgui.DrawList_AddRectFilled(draw, minimum, maximum, win98_color(THEME_FACE))
	win98_draw_bevel(draw, minimum, maximum, true)
	center_y := (minimum.y + maximum.y) * 0.5
	win98_draw_activity_led(draw, {minimum.x + 7, center_y}, storage_device_active(st, device))
	icon := storage_device_icon(icons, device, true)
	win98_draw_icon(
		draw,
		icon,
		{maximum.x - STATUS_STORAGE_ICON_SIZE - 2, center_y - STATUS_STORAGE_ICON_SIZE * 0.5},
		STATUS_STORAGE_ICON_SIZE,
	)
	if imgui.IsItemHovered() {
		imgui.SetTooltipUnformatted(fmt.ctprintf("%s", storage_device_tooltip(st, device)))
	}
	return status_bar_storage_context_menu(st, device)
}

status_bar_draw :: proc(st: ^Menu_State, icons: Ui_Icon_Textures) -> Menu_Action {
	action := Menu_Action.None
	if st == nil || st.menu_reveal <= 0 {return action}
	viewport := imgui.GetMainViewport()
	height := f32(STATUS_BAR_H)
	imgui.SetNextWindowPos(
		{viewport.Pos.x, viewport.Pos.y + viewport.Size.y - height * st.menu_reveal},
	)
	imgui.SetNextWindowSize({viewport.Size.x, height})
	imgui.SetNextWindowViewport(viewport.ID_)
	imgui.PushStyleVarImVec2(.WindowPadding, {2, 2})
	imgui.PushStyleVar(.WindowBorderSize, 0)
	imgui.PushStyleVarImVec2(.WindowMinSize, {0, 0})
	open := imgui.Begin(
		"##retvrn99_status_bar",
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
		available := imgui.GetContentRegionAvail()
		cell_height := max(f32(1), available.y)
		win98_status_cell(status_bar_machine_text(st), STATUS_MACHINE_CELL_W, cell_height)
		imgui.SameLine(0, STATUS_CELL_GAP)
		storage_width := status_bar_storage_width()
		general_width := max(
			f32(1),
			available.x - STATUS_MACHINE_CELL_W - storage_width - STATUS_CELL_GAP * 2,
		)
		general := st.general_status
		if len(general) == 0 {general = "Ready"}
		win98_status_cell(general, general_width, cell_height)
		for device in status_bar_storage_device_order {
			imgui.SameLine(0, STATUS_CELL_GAP)
			item_action := status_bar_storage_item(st, icons, device, cell_height)
			if action == .None && item_action != .None {action = item_action}
		}
	}
	imgui.End()
	imgui.PopStyleVar(3)
	return action
}
