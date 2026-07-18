// SPDX-License-Identifier: GPL-3.0-only
package host

import "core:testing"
import sdl3 "vendor:sdl3"

@(test)
hotkey_editor_test_capture_clear_cancel_and_suppressed_release :: proc(t: ^testing.T) {
	editor: Hotkey_Editor_State
	hotkey_editor_open(&editor, host_hotkey_defaults())
	editor.capture_action = .Toggle_Turbo
	testing.expect(t, hotkey_editor_capture_event(&editor, .LCTRL, {.LCTRL}, true, false))
	testing.expect(t, hotkey_editor_capture_event(&editor, .F8, {.LCTRL}, true, false))
	testing.expect_value(t, editor.capture_action, Host_Hotkey.None)
	testing.expect_value(t, editor.draft.bindings[.Toggle_Turbo].scancode, sdl3.Scancode.F8)
	testing.expect(t, .Control in editor.draft.bindings[.Toggle_Turbo].modifiers)
	testing.expect(t, hotkey_editor_capture_event(&editor, .F8, {.LCTRL}, false, false))
	testing.expect(t, hotkey_editor_capture_event(&editor, .LCTRL, {}, false, false))

	editor.capture_action = .Toggle_Turbo
	testing.expect(t, hotkey_editor_capture_event(&editor, .ESCAPE, {}, true, false))
	testing.expect_value(t, editor.draft.bindings[.Toggle_Turbo].scancode, sdl3.Scancode.F8)
	editor.capture_action = .Toggle_Turbo
	testing.expect(t, hotkey_editor_capture_event(&editor, .DELETE, {}, true, false))
	testing.expect(t, !editor.draft.bindings[.Toggle_Turbo].assigned)
}

@(test)
hotkey_editor_test_conflict_requires_explicit_replace :: proc(t: ^testing.T) {
	editor: Hotkey_Editor_State
	hotkey_editor_open(&editor, host_hotkey_defaults())
	editor.capture_action = .Volume_Up
	testing.expect(t, hotkey_editor_capture_event(&editor, .F1, {.LGUI, .LSHIFT}, true, false))
	testing.expect_value(t, editor.conflict_other, Host_Hotkey.Release_Input)
	testing.expect_value(t, editor.conflict_action, Host_Hotkey.Volume_Up)
	testing.expect(t, editor.popup_requested)
	testing.expect_value(t, editor.draft.bindings[.Volume_Up].scancode, sdl3.Scancode.F10)
}

@(test)
hotkey_editor_test_restore_defaults_and_dirty_state :: proc(t: ^testing.T) {
	editor: Hotkey_Editor_State
	defaults := host_hotkey_defaults()
	hotkey_editor_open(&editor, defaults)
	testing.expect(t, !hotkey_editor_dirty(&editor))
	editor.draft.bindings[.Volume_Down] = {}
	testing.expect(t, hotkey_editor_dirty(&editor))
	editor.draft = host_hotkey_defaults()
	testing.expect(t, !hotkey_editor_dirty(&editor))
}
