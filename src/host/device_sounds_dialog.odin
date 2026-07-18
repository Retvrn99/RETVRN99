// SPDX-License-Identifier: GPL-3.0-only
package host

import imgui "../../vendor_local/imgui"

DEVICE_SOUNDS_DIALOG_W :: f32(430)

Device_Sounds_Dialog_Event :: enum {
	None,
	Test_Hard_Drive,
	Test_Floppy,
	Apply,
	Ok,
	Cancel,
}

Device_Sounds_Dialog_Action :: enum {
	None,
	Test_Hard_Drive,
	Test_Floppy,
	Apply,
	Ok,
	Cancel,
}

Device_Sounds_Dialog_Result :: struct {
	action:              Device_Sounds_Dialog_Action,
	hard_drive_clicking: bool,
	floppy_noise:        bool,
}

Device_Sounds_Dialog_State :: struct {
	visible:                     bool,
	applied_hard_drive_clicking: bool,
	applied_floppy_noise:        bool,
	draft_hard_drive_clicking:   bool,
	draft_floppy_noise:          bool,
}

device_sounds_dialog_open :: proc(
	state: ^Device_Sounds_Dialog_State,
	hard_drive_clicking, floppy_noise: bool,
) {
	if state == nil {return}
	state^ = {
		visible                     = true,
		applied_hard_drive_clicking = hard_drive_clicking,
		applied_floppy_noise        = floppy_noise,
		draft_hard_drive_clicking   = hard_drive_clicking,
		draft_floppy_noise          = floppy_noise,
	}
}

device_sounds_dialog_changed :: proc(state: ^Device_Sounds_Dialog_State) -> bool {
	if state == nil {return false}
	return(
		state.draft_hard_drive_clicking != state.applied_hard_drive_clicking ||
		state.draft_floppy_noise != state.applied_floppy_noise \
	)
}

device_sounds_dialog_apply_event :: proc(
	state: ^Device_Sounds_Dialog_State,
	event: Device_Sounds_Dialog_Event,
) -> Device_Sounds_Dialog_Result {
	if state == nil {return {}}
	result := Device_Sounds_Dialog_Result {
		hard_drive_clicking = state.draft_hard_drive_clicking,
		floppy_noise        = state.draft_floppy_noise,
	}
	switch event {
	case .None:
	case .Test_Hard_Drive:
		result.action = .Test_Hard_Drive
	case .Test_Floppy:
		result.action = .Test_Floppy
	case .Apply:
		if device_sounds_dialog_changed(state) {
			state.applied_hard_drive_clicking = state.draft_hard_drive_clicking
			state.applied_floppy_noise = state.draft_floppy_noise
			result.action = .Apply
		}
	case .Ok:
		state.applied_hard_drive_clicking = state.draft_hard_drive_clicking
		state.applied_floppy_noise = state.draft_floppy_noise
		state.visible = false
		result.action = .Ok
	case .Cancel:
		state.draft_hard_drive_clicking = state.applied_hard_drive_clicking
		state.draft_floppy_noise = state.applied_floppy_noise
		state.visible = false
		result.action = .Cancel
		result.hard_drive_clicking = state.applied_hard_drive_clicking
		result.floppy_noise = state.applied_floppy_noise
	}
	return result
}

device_sounds_dialog_draw :: proc(
	state: ^Device_Sounds_Dialog_State,
	icons: ^Ui_Icon_Textures,
) -> Device_Sounds_Dialog_Result {
	if state == nil || icons == nil || !state.visible {return {}}
	viewport := imgui.GetMainViewport()
	center := imgui.Vec2 {
		viewport.Pos.x + viewport.Size.x * 0.5,
		viewport.Pos.y + viewport.Size.y * 0.5,
	}
	imgui.SetNextWindowPos(center, .Appearing, {0.5, 0.5})
	was_visible := state.visible
	window_open := win98_begin_window(
		"Device Sounds",
		&state.visible,
		{.AlwaysAutoResize, .NoCollapse, .NoSavedSettings},
	)
	result: Device_Sounds_Dialog_Result
	if window_open {
		win98_section_title("Mechanical Drive Sounds", DEVICE_SOUNDS_DIALOG_W)
		imgui.Spacing()
		panel_min := imgui.GetCursorScreenPos()
		imgui.BeginGroup()
		icon := ui_icon_texture(icons, .Sound_32)
		imgui.Image(win98_texture_ref(icon), {32, 32})
		imgui.SameLine()
		imgui.BeginGroup()
		win98_dialog_wrapped_text(
			"Add mechanical drive sounds to activity from the emulated machine.",
			DEVICE_SOUNDS_DIALOG_W - 52,
		)
		imgui.Spacing()
		_ = imgui.Checkbox("Realistic hard drive clicking", &state.draft_hard_drive_clicking)
		imgui.SameLine()
		if imgui.Button("Test##hard_drive_sound") {
			result = device_sounds_dialog_apply_event(state, .Test_Hard_Drive)
		}
		_ = imgui.Checkbox("Floppy drive noise", &state.draft_floppy_noise)
		imgui.SameLine()
		if result.action == .None && imgui.Button("Test##floppy_sound") {
			result = device_sounds_dialog_apply_event(state, .Test_Floppy)
		}
		imgui.EndGroup()
		imgui.EndGroup()
		panel_max := imgui.GetItemRectMax()
		win98_draw_bevel(
			imgui.GetWindowDrawList(),
			{panel_min.x - 4, panel_min.y - 4},
			{panel_max.x + 4, panel_max.y + 4},
			false,
		)
		imgui.Spacing()
		imgui.Separator()
		if imgui.Button("OK") {
			result = device_sounds_dialog_apply_event(state, .Ok)
		}
		imgui.SameLine()
		if imgui.Button("Cancel") {
			result = device_sounds_dialog_apply_event(state, .Cancel)
		}
		imgui.SameLine()
		imgui.BeginDisabled(!device_sounds_dialog_changed(state))
		if imgui.Button("Apply") {
			result = device_sounds_dialog_apply_event(state, .Apply)
		}
		imgui.EndDisabled()
	}
	imgui.End()
	if was_visible && !state.visible && result.action == .None {
		result = device_sounds_dialog_apply_event(state, .Cancel)
	}
	return result
}
