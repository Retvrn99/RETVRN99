// SPDX-License-Identifier: GPL-3.0-only
package host

import imgui "../../vendor_local/imgui"
import "core:fmt"

WIN98_DIALOG_POPUP_ID :: "RETVRN99##win98_message_dialog"
WIN98_DIALOG_CONTENT_W :: f32(460)

Win98_Dialog_Kind :: enum {
	Error,
	Warning,
}

Win98_Dialog_Buttons :: enum {
	Ok,
	Ok_Cancel,
	Action_Cancel,
}

Win98_Dialog_Result :: enum {
	None,
	Ok,
	Action,
	Cancel,
}

Win98_Dialog_State :: struct {
	visible:          bool,
	open_requested:   bool,
	details_expanded: bool,
	kind:             Win98_Dialog_Kind,
	buttons:          Win98_Dialog_Buttons,
	title:            string,
	summary:          string,
	details:          string,
	action_label:     string,
}

win98_dialog_open :: proc(
	state: ^Win98_Dialog_State,
	kind: Win98_Dialog_Kind,
	title, summary: string,
	details: string = "",
	buttons: Win98_Dialog_Buttons = .Ok,
	action_label: string = "",
) {
	if state == nil {return}
	state^ = {
		visible        = true,
		open_requested = true,
		kind           = kind,
		buttons        = buttons,
		title          = title,
		summary        = summary,
		details        = details,
		action_label   = action_label,
	}
}

win98_dialog_primary_label :: proc(state: ^Win98_Dialog_State) -> string {
	if state == nil {return "OK"}
	if state.buttons == .Action_Cancel {
		if len(state.action_label) > 0 {return state.action_label}
		return "Continue"
	}
	return "OK"
}

win98_dialog_icon_role :: proc(kind: Win98_Dialog_Kind) -> Ui_Icon_Role {
	switch kind {
	case .Error:
		return .Error_32
	case .Warning:
		return .Warning_32
	}
	return .Warning_32
}

win98_dialog_text :: proc(value: string) {
	if len(value) == 0 {
		imgui.TextUnformatted("")
		return
	}
	data := raw_data(value)
	imgui.TextUnformatted(cstring(data), cstring(data[len(value):]))
}

win98_dialog_wrapped_text :: proc(value: string, width: f32) {
	if len(value) == 0 {return}
	imgui.PushTextWrapPos(imgui.GetCursorPosX() + width)
	data := raw_data(value)
	imgui.TextUnformatted(cstring(data), cstring(data[len(value):]))
	imgui.PopTextWrapPos()
}

win98_dialog_close :: proc(state: ^Win98_Dialog_State) {
	if state == nil {return}
	state.visible = false
	state.open_requested = false
	imgui.CloseCurrentPopup()
}

// Draws one reusable Windows 9x-style modal. The caller owns the strings in state
// and handles the returned button result.
win98_dialog_draw :: proc(
	state: ^Win98_Dialog_State,
	icons: ^Ui_Icon_Textures,
) -> Win98_Dialog_Result {
	if state == nil || icons == nil || !state.visible {return .None}
	if state.open_requested {
		imgui.OpenPopup(WIN98_DIALOG_POPUP_ID)
		state.open_requested = false
	}
	viewport := imgui.GetMainViewport()
	center := imgui.Vec2 {
		viewport.Pos.x + viewport.Size.x * 0.5,
		viewport.Pos.y + viewport.Size.y * 0.5,
	}
	imgui.SetNextWindowPos(center, .Appearing, {0.5, 0.5})
	if !win98_begin_popup_modal(WIN98_DIALOG_POPUP_ID, nil, {.AlwaysAutoResize, .NoSavedSettings}) {
		return .None
	}
	defer imgui.EndPopup()

	win98_section_title(state.title, WIN98_DIALOG_CONTENT_W)
	imgui.Spacing()
	icon := ui_icon_texture(icons, win98_dialog_icon_role(state.kind))
	imgui.Image(win98_texture_ref(icon), {32, 32})
	imgui.SameLine()
	imgui.BeginGroup()
	win98_dialog_wrapped_text(state.summary, WIN98_DIALOG_CONTENT_W - 48)
	imgui.EndGroup()

	if len(state.details) > 0 {
		imgui.Spacing()
		if imgui.Button(state.details_expanded ? "Details <<" : "Details >>") {
			state.details_expanded = !state.details_expanded
		}
		if state.details_expanded {
			imgui.Spacing()
			panel_min := imgui.GetCursorScreenPos()
			imgui.BeginGroup()
			imgui.Dummy({WIN98_DIALOG_CONTENT_W - 12, 2})
			win98_dialog_wrapped_text(state.details, WIN98_DIALOG_CONTENT_W - 24)
			imgui.Spacing()
			if imgui.Button("Copy Details") {
				imgui.SetClipboardText(fmt.ctprintf("%s", state.details))
			}
			imgui.EndGroup()
			panel_max := imgui.GetItemRectMax()
			win98_draw_bevel(
				imgui.GetWindowDrawList(),
				{panel_min.x - 4, panel_min.y - 3},
				{panel_max.x + 4, panel_max.y + 3},
				true,
			)
			imgui.Spacing()
		}
	}

	imgui.Separator()
	result := Win98_Dialog_Result.None
	primary := win98_dialog_primary_label(state)
	if imgui.Button(fmt.ctprintf("%s", primary)) {
		result = state.buttons == .Action_Cancel ? .Action : .Ok
		win98_dialog_close(state)
	}
	if state.buttons != .Ok {
		imgui.SameLine()
		if imgui.Button("Cancel") {
			result = .Cancel
			win98_dialog_close(state)
		}
	}
	return result
}
