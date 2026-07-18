// SPDX-License-Identifier: GPL-3.0-only
package host

import "core:testing"
import sdl3 "vendor:sdl3"

@(test)
hotkey_test_defaults_preserve_existing_actions :: proc(t: ^testing.T) {
	config := host_hotkey_defaults()
	modifiers := sdl3.Keymod{.LGUI, .LSHIFT}
	testing.expect_value(t, host_hotkey_from_key(.F1, modifiers, true, false, &config), Host_Hotkey.Release_Input)
	modifiers = {.RGUI, .RSHIFT}
	testing.expect_value(t, host_hotkey_from_key(.F3, modifiers, true, false, &config), Host_Hotkey.Toggle_Fullscreen)
	testing.expect_value(t, host_hotkey_from_key(.F5, modifiers, true, false, &config), Host_Hotkey.Toggle_Turbo)
	testing.expect_value(t, host_hotkey_from_key(.F9, modifiers, true, false, &config), Host_Hotkey.Volume_Down)
	testing.expect_value(t, host_hotkey_from_key(.F10, modifiers, true, false, &config), Host_Hotkey.Volume_Up)
}

@(test)
hotkey_test_symbolic_round_trip_and_aliases :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	binding, valid := host_hotkey_parse("Windows+Control+Shift+F12")
	testing.expect(t, valid)
	testing.expect(t, binding.assigned)
	testing.expect_value(t, binding.scancode, sdl3.Scancode.F12)
	serialized, serialized_ok := host_hotkey_serialize(binding)
	testing.expect(t, serialized_ok)
	testing.expect_value(t, serialized, "Super+Ctrl+Shift+F12")
	reparsed, reparsed_ok := host_hotkey_parse(serialized)
	testing.expect(t, reparsed_ok)
	testing.expect(t, host_hotkey_binding_equal(binding, reparsed))
}

@(test)
hotkey_test_unassigned_and_invalid_bindings :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	unassigned, valid := host_hotkey_parse("None")
	testing.expect(t, valid)
	testing.expect(t, !unassigned.assigned)
	serialized, serialized_ok := host_hotkey_serialize(unassigned)
	testing.expect(t, serialized_ok)
	testing.expect_value(t, serialized, "None")
	_, duplicate := host_hotkey_parse("Shift+Shift+F1")
	_, modifier_only := host_hotkey_parse("Shift")
	_, two_keys := host_hotkey_parse("F1+F2")
	testing.expect(t, !duplicate)
	testing.expect(t, !modifier_only)
	testing.expect(t, !two_keys)
}

@(test)
hotkey_test_conflicts_and_extra_modifiers :: proc(t: ^testing.T) {
	config := host_hotkey_defaults()
	conflict := host_hotkey_conflict(&config, .Volume_Up, config.bindings[.Release_Input])
	testing.expect_value(t, conflict, Host_Hotkey.Release_Input)
	modifiers := sdl3.Keymod{.LGUI, .LSHIFT, .LCTRL}
	testing.expect_value(t, host_hotkey_from_key(.F1, modifiers, true, false, &config), Host_Hotkey.None)
	testing.expect_value(t, host_hotkey_from_key(.F1, {.LGUI, .LSHIFT}, false, false, &config), Host_Hotkey.None)
	testing.expect_value(t, host_hotkey_from_key(.F1, {.LGUI, .LSHIFT}, true, true, &config), Host_Hotkey.None)
}
