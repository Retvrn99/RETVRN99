// SPDX-License-Identifier: GPL-3.0-only
package host

import imgui "../../vendor_local/imgui"
import "core:fmt"
import sdl3 "vendor:sdl3"

HOTKEY_CAPTURE_SCANCODES :: 512

Hotkey_Editor_State :: struct {
	baseline:          Hotkey_Config,
	draft:             Hotkey_Config,
	capture_action:    Host_Hotkey,
	conflict_action:   Host_Hotkey,
	conflict_other:    Host_Hotkey,
	conflict_binding:  Hotkey_Binding,
	suppressed:        [HOTKEY_CAPTURE_SCANCODES]bool,
	initialized:       bool,
	popup_requested:   bool,
}

hotkey_editor_open :: proc(editor: ^Hotkey_Editor_State, current: Hotkey_Config) {
	if editor == nil {return}
	editor^ = {
		baseline    = current,
		draft       = current,
		initialized = true,
	}
}

hotkey_editor_cancel :: proc(editor: ^Hotkey_Editor_State) {
	if editor == nil {return}
	editor.capture_action = .None
	editor.conflict_action = .None
	editor.conflict_other = .None
	editor.conflict_binding = {}
	editor.popup_requested = false
}

hotkey_editor_dirty :: proc(editor: ^Hotkey_Editor_State) -> bool {
	return editor != nil && editor.initialized && !host_hotkey_config_equal(editor.baseline, editor.draft)
}

hotkey_editor_capture_event :: proc(
	editor: ^Hotkey_Editor_State,
	scancode: sdl3.Scancode,
	modifiers: sdl3.Keymod,
	down, repeat: bool,
) -> bool {
	if editor == nil || repeat {return false}
	index := int(scancode)
	if !down && index >= 0 && index < len(editor.suppressed) && editor.suppressed[index] {
		editor.suppressed[index] = false
		return true
	}
	if editor.capture_action == .None {return false}
	if down && index >= 0 && index < len(editor.suppressed) {editor.suppressed[index] = true}
	if !down || host_hotkey_modifier_scancode(scancode) {return true}
	if scancode == .ESCAPE {
		editor.capture_action = .None
		return true
	}
	if scancode == .BACKSPACE || scancode == .DELETE {
		editor.draft.bindings[editor.capture_action] = {}
		editor.capture_action = .None
		return true
	}
	binding := Hotkey_Binding {
		modifiers = host_hotkey_modifiers_from_sdl(modifiers),
		scancode  = scancode,
		assigned  = true,
	}
	conflict := host_hotkey_conflict(&editor.draft, editor.capture_action, binding)
	if conflict != .None {
		editor.conflict_action = editor.capture_action
		editor.conflict_other = conflict
		editor.conflict_binding = binding
		editor.popup_requested = true
	} else {
		editor.draft.bindings[editor.capture_action] = binding
	}
	editor.capture_action = .None
	return true
}

hotkey_editor_draw :: proc(
	st: ^Menu_State,
	settings_icon: Ui_Icon_Texture = {},
) -> (apply: bool, close: bool) {
	if st == nil {return}
	editor := &st.hotkey_editor
	if !editor.initialized {hotkey_editor_open(editor, st.hotkeys)}
	win98_section_title("Keyboard Shortcuts", 520)
	imgui.Spacing()
	if settings_icon.texture != nil {
		imgui.Image(win98_texture_ref(settings_icon), {32, 32})
		imgui.SameLine()
	}
	imgui.BeginGroup()
	menu_text("Choose Change, then press the new shortcut.")
	menu_text("Esc cancels capture. Backspace or Delete clears a shortcut.")
	imgui.EndGroup()
	imgui.Separator()
	flags := imgui.TableFlags(
		imgui.TableFlags_RowBg | imgui.TableFlags_BordersInnerH | imgui.TableFlags_SizingStretchProp,
	)
	if imgui.BeginTable("##hotkey-bindings", 3, flags, {520, 0}) {
		imgui.TableSetupColumn("Action", {.WidthStretch}, 1)
		imgui.TableSetupColumn("Shortcut", {.WidthStretch}, 1)
		imgui.TableSetupColumn("", {.WidthFixed}, 82)
		imgui.TableHeadersRow()
		for action := Host_Hotkey.Release_Input; action <= .Volume_Up; action = Host_Hotkey(int(action) + 1) {
			imgui.TableNextRow()
			_ = imgui.TableSetColumnIndex(0)
			menu_text(host_hotkey_action_name(action))
			_ = imgui.TableSetColumnIndex(1)
			if editor.capture_action == action {
				menu_text("Press shortcut...")
			} else {
				binding_text, valid := host_hotkey_serialize(
					editor.draft.bindings[action],
					context.temp_allocator,
				)
				menu_text(valid ? binding_text : HOTKEY_UNASSIGNED)
			}
			_ = imgui.TableSetColumnIndex(2)
			if imgui.Button(fmt.ctprintf("Change...##hotkey-%d", int(action)), {78, 0}) {
				editor.capture_action = action
			}
		}
		imgui.EndTable()
	}
	imgui.Separator()
	menu_text("Right Ctrl is always available as an emergency input-release key.")
	imgui.Separator()
	if imgui.Button("Restore Defaults") {
		editor.draft = host_hotkey_defaults()
		editor.capture_action = .None
	}
	imgui.SameLine()
	if imgui.Button("OK") {
		if hotkey_editor_dirty(editor) {
			st.hotkeys = editor.draft
			editor.baseline = editor.draft
			apply = true
		}
		close = true
	}
	imgui.SameLine()
	if imgui.Button("Cancel") {close = true}
	imgui.SameLine()
	imgui.BeginDisabled(!hotkey_editor_dirty(editor))
	if imgui.Button("Apply") {
		st.hotkeys = editor.draft
		editor.baseline = editor.draft
		apply = true
	}
	imgui.EndDisabled()

	if editor.popup_requested {
		imgui.OpenPopup("Hotkey conflict")
		editor.popup_requested = false
	}
	if win98_begin_popup_modal("Hotkey conflict", nil, {.AlwaysAutoResize}) {
		binding_text, valid := host_hotkey_serialize(
			editor.conflict_binding,
			context.temp_allocator,
		)
		menu_text(
			fmt.tprintf(
				"%s is already assigned to %s.",
				valid ? binding_text : "This shortcut",
				host_hotkey_action_name(editor.conflict_other),
			),
		)
		menu_text("Replace the existing assignment?")
		if imgui.Button("Replace") {
			editor.draft.bindings[editor.conflict_other] = {}
			editor.draft.bindings[editor.conflict_action] = editor.conflict_binding
			hotkey_editor_cancel(editor)
			imgui.CloseCurrentPopup()
		}
		imgui.SameLine()
		if imgui.Button("Cancel") {
			hotkey_editor_cancel(editor)
			imgui.CloseCurrentPopup()
		}
		imgui.EndPopup()
	}
	return
}
