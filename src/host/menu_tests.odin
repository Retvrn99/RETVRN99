// SPDX-License-Identifier: GPL-3.0-only
package host

import "core:testing"
import sdl3 "vendor:sdl3"

@(test)
host_test_machine_and_scaling_menu_availability :: proc(t: ^testing.T) {
	st: Menu_State
	testing.expect(t, menu_action_enabled(&st, .Start))
	testing.expect(t, !menu_action_enabled(&st, .Stop))
	testing.expect(t, !menu_action_enabled(&st, .Toggle_Pause))
	testing.expect(t, menu_action_enabled(&st, .Set_Window_Scale))

	st.machine_running = true
	testing.expect(t, !menu_action_enabled(&st, .Start))
	testing.expect(t, menu_action_enabled(&st, .Stop))
	testing.expect(t, menu_action_enabled(&st, .Toggle_Pause))

	st.fullscreen = true
	testing.expect(t, !menu_action_enabled(&st, .Set_Window_Scale))
}

@(test)
host_test_visual_shader_menu_requires_gpu_except_for_none :: proc(t: ^testing.T) {
	st: Menu_State
	testing.expect(t, !menu_action_enabled(&st, .Set_Visual_Shader))
	st.shaders_available = true
	testing.expect(t, menu_action_enabled(&st, .Set_Visual_Shader))
}

@(test)
host_test_windows_super_hotkeys_map_to_host_actions :: proc(t: ^testing.T) {
	gui := sdl3.Keymod{.LGUI, .LSHIFT}
	testing.expect_value(t, host_hotkey_from_key(.F1, gui, true, false), Host_Hotkey.Release_Input)
	testing.expect_value(
		t,
		host_hotkey_from_key(.F3, gui, true, false),
		Host_Hotkey.Toggle_Fullscreen,
	)
	testing.expect_value(t, host_hotkey_from_key(.F5, gui, true, false), Host_Hotkey.Toggle_Turbo)
	testing.expect_value(t, host_hotkey_from_key(.F9, gui, true, false), Host_Hotkey.Volume_Down)
	testing.expect_value(t, host_hotkey_from_key(.F10, gui, true, false), Host_Hotkey.Volume_Up)
	testing.expect_value(t, host_hotkey_from_key(.F5, {}, true, false), Host_Hotkey.None)
	testing.expect_value(t, host_hotkey_from_key(.F5, {.LGUI}, true, false), Host_Hotkey.None)
	testing.expect_value(t, host_hotkey_from_key(.F5, {.LSHIFT}, true, false), Host_Hotkey.None)
	testing.expect_value(t, host_hotkey_from_key(.F5, gui, false, false), Host_Hotkey.None)
	testing.expect_value(t, host_hotkey_from_key(.F5, gui, true, true), Host_Hotkey.None)
}

@(test)
host_test_volume_hotkeys_step_and_clamp :: proc(t: ^testing.T) {
	testing.expect_value(t, host_volume_adjust(1, .Volume_Up), f32(1))
	testing.expect_value(t, host_volume_adjust(0, .Volume_Down), f32(0))
	testing.expect_value(t, host_volume_adjust(0.5, .Volume_Up), f32(0.6))
	testing.expect_value(t, host_volume_adjust(0.5, .Volume_Down), f32(0.4))
}

@(test)
host_test_fullscreen_menu_roll_clamps_at_each_end :: proc(t: ^testing.T) {
	testing.expect_value(t, menu_reveal_step(1, 0, MENU_ROLL_SECONDS), f32(0))
	testing.expect_value(t, menu_reveal_step(0, 1, MENU_ROLL_SECONDS), f32(1))
	testing.expect_value(t, menu_reveal_step(0.5, 0, MENU_ROLL_SECONDS / 4), f32(0.25))
	testing.expect_value(t, menu_reveal_step(0.5, 1, MENU_ROLL_SECONDS / 4), f32(0.75))
	testing.expect_value(t, menu_reveal_step(-1, 0, 1), f32(0))
	testing.expect_value(t, menu_reveal_step(2, 1, 1), f32(1))
}
