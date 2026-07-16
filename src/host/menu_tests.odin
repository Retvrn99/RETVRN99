// SPDX-License-Identifier: GPL-3.0-only
package host

import "core:bytes"
import "core:image/png"
import "core:testing"
import sdl3 "vendor:sdl3"

@(test)
host_test_machine_and_scaling_menu_availability :: proc(t: ^testing.T) {
	st: Menu_State
	testing.expect(t, menu_action_enabled(&st, .Start))
	testing.expect(t, !menu_action_enabled(&st, .Stop))
	testing.expect(t, !menu_action_enabled(&st, .Toggle_Pause))
	testing.expect(t, !menu_action_enabled(&st, .Reset))
	testing.expect(t, menu_action_enabled(&st, .Set_Window_Scale))

	st.machine_running = true
	testing.expect(t, !menu_action_enabled(&st, .Start))
	testing.expect(t, menu_action_enabled(&st, .Stop))
	testing.expect(t, menu_action_enabled(&st, .Toggle_Pause))
	testing.expect(t, menu_action_enabled(&st, .Reset))

	st.fullscreen = true
	testing.expect(t, !menu_action_enabled(&st, .Set_Window_Scale))

	st.machine_running = false
	st.storage_actions_blocked = true
	testing.expect(t, !menu_action_enabled(&st, .Start))
}

@(test)
host_test_hard_drive_actions_require_stopped_ready_machine :: proc(t: ^testing.T) {
	st := Menu_State {
		hard_drive_status = .Ready,
		hard_drive_path   = `D:\images\c_drive.img`,
	}
	testing.expect(t, menu_action_enabled(&st, .Select_Hard_Drive))
	testing.expect(t, menu_action_enabled(&st, .Browse_C_Drive))
	testing.expect(t, menu_action_enabled(&st, .Create_Hard_Drive))
	testing.expect(t, menu_action_enabled(&st, .Install_Windows_98))
	testing.expect_value(t, menu_select_hard_drive_label(&st), cstring("Select Hard Drive..."))
	testing.expect_value(t, menu_browse_c_drive_label(&st), cstring("Browse C drive..."))

	st.machine_running = true
	testing.expect(t, !menu_action_enabled(&st, .Select_Hard_Drive))
	testing.expect(t, !menu_action_enabled(&st, .Browse_C_Drive))
	testing.expect(t, !menu_action_enabled(&st, .Create_Hard_Drive))
	testing.expect(t, !menu_action_enabled(&st, .Install_Windows_98))
	testing.expect_value(
		t,
		menu_select_hard_drive_label(&st),
		cstring("Select Hard Drive... (Stop machine first)"),
	)
	testing.expect_value(
		t,
		menu_browse_c_drive_label(&st),
		cstring("Browse C drive... (Stop machine first)"),
	)

	st.machine_running = false
	st.hard_drive_status = .Missing
	testing.expect(t, !menu_action_enabled(&st, .Browse_C_Drive))
	testing.expect(t, menu_action_enabled(&st, .Select_Hard_Drive))

	st.storage_actions_blocked = true
	testing.expect(t, !menu_action_enabled(&st, .Select_Hard_Drive))
	testing.expect(t, !menu_action_enabled(&st, .Create_Hard_Drive))
}

@(test)
host_test_install_session_owns_disk_and_media_actions :: proc(t: ^testing.T) {
	st := Menu_State {
		install_active    = true,
		floppy_mounted    = true,
		cdrom_mounted     = true,
		hard_drive_path   = "c_drive.img",
		hard_drive_status = .Ready,
	}
	testing.expect(t, menu_action_enabled(&st, .Start))
	testing.expect(t, !menu_action_enabled(&st, .Select_Hard_Drive))
	testing.expect(t, !menu_action_enabled(&st, .Browse_C_Drive))
	testing.expect(t, !menu_action_enabled(&st, .Create_Hard_Drive))
	testing.expect(t, !menu_action_enabled(&st, .Install_Windows_98))
	testing.expect(t, !menu_action_enabled(&st, .Mount_Floppy))
	testing.expect(t, !menu_action_enabled(&st, .Eject_Floppy))
	testing.expect(t, !menu_action_enabled(&st, .Mount_Cdrom))
	testing.expect(t, !menu_action_enabled(&st, .Eject_Cdrom))
	testing.expect(t, menu_action_enabled(&st, .Abandon_Windows_98_Installation))

	st.machine_running = true
	testing.expect(t, !menu_action_enabled(&st, .Abandon_Windows_98_Installation))
}

@(test)
host_test_invalid_retained_install_state_locks_storage_but_exposes_abandon :: proc(t: ^testing.T) {
	st := Menu_State {
		install_recovery_required = true,
		floppy_mounted            = true,
		cdrom_mounted             = true,
		hard_drive_path           = "c_drive.img",
		hard_drive_status         = .Ready,
	}
	testing.expect(t, !st.install_active)
	testing.expect(t, menu_install_storage_locked(&st))
	testing.expect(t, !menu_action_enabled(&st, .Start))
	testing.expect(t, !menu_action_enabled(&st, .Select_Hard_Drive))
	testing.expect(t, !menu_action_enabled(&st, .Browse_C_Drive))
	testing.expect(t, !menu_action_enabled(&st, .Create_Hard_Drive))
	testing.expect(t, !menu_action_enabled(&st, .Install_Windows_98))
	testing.expect(t, !menu_action_enabled(&st, .Mount_Floppy))
	testing.expect(t, !menu_action_enabled(&st, .Eject_Floppy))
	testing.expect(t, !menu_action_enabled(&st, .Mount_Cdrom))
	testing.expect(t, !menu_action_enabled(&st, .Eject_Cdrom))
	testing.expect(t, menu_action_visible(&st, .Abandon_Windows_98_Installation))
	testing.expect(t, menu_action_enabled(&st, .Abandon_Windows_98_Installation))
	testing.expect_value(t, menu_center_panel(&st), Menu_Center_Panel.Install_State_Recovery)

	st.machine_running = true
	testing.expect(t, !menu_action_enabled(&st, .Abandon_Windows_98_Installation))
	testing.expect_value(t, menu_center_panel(&st), Menu_Center_Panel.None)
}

@(test)
host_test_top_level_menu_order_is_stable :: proc(t: ^testing.T) {
	expected := [6]string{"Machine", "Hard Drive", "Media", "Emulation", "Tools", "Help"}
	for label, index in MENU_TOP_LEVEL_ORDER {
		testing.expect_value(t, string(label), expected[index])
	}
}

@(test)
host_test_welcome_recovery_and_tools_visibility_models_are_exact :: proc(t: ^testing.T) {
	testing.expect_value(t, string(MENU_CREATE_HARD_DRIVE_LABEL), "Create Hard Drive...")
	testing.expect_value(t, string(MENU_INSTALL_WINDOWS_98_LABEL), "Install Windows 98...")
	testing.expect_value(
		t,
		string(MENU_ABANDON_WINDOWS_98_LABEL),
		"Abandon Windows 98 Installation...",
	)
	testing.expect_value(t, string(WELCOME_PANEL_TITLE), "Welcome to RETVRN99")
	testing.expect_value(
		t,
		string(WELCOME_PANEL_FIRST_TIME),
		"It looks like this is your first time running RETVRN99.",
	)
	testing.expect_value(t, string(WELCOME_PANEL_QUICK_START), "Quick start")
	testing.expect_value(
		t,
		string(WELCOME_PANEL_QUICK_START_TEXT),
		"Choose Tools > Install Windows 98 and follow the steps.",
	)
	testing.expect_value(t, string(WELCOME_PANEL_ADVANCED), "Advanced setup")
	testing.expect_value(
		t,
		string(WELCOME_PANEL_ADVANCED_FIRST),
		"Create or select a hard drive, mount bootable media from the Media menu,",
	)
	testing.expect_value(t, string(WELCOME_PANEL_ADVANCED_SECOND), "then choose Machine > Start.")
	testing.expect_value(
		t,
		string(WELCOME_PANEL_DOCUMENTATION),
		"For the full guide, choose Help > Documentation.",
	)
	testing.expect_value(t, string(RECOVERY_PANEL_TITLE), "Hard drive unavailable")
	testing.expect_value(
		t,
		string(RECOVERY_PANEL_MESSAGE),
		"The selected hard drive could not be opened.",
	)
	testing.expect_value(
		t,
		string(RECOVERY_PANEL_ACTION),
		"Choose Hard Drive > Select Hard Drive to select another image.",
	)
	testing.expect_value(
		t,
		string(INSTALL_RECOVERY_PANEL_TITLE),
		"Windows 98 installation recovery",
	)
	testing.expect_value(
		t,
		string(INSTALL_RECOVERY_PANEL_MESSAGE),
		"The saved Windows 98 installation state is invalid or no longer bound.",
	)
	testing.expect_value(
		t,
		string(INSTALL_RECOVERY_PANEL_LOCK),
		"Hard-drive and media tools remain disabled to preserve recovery evidence.",
	)
	testing.expect_value(
		t,
		string(INSTALL_RECOVERY_PANEL_ACTION),
		"Choose Tools > Abandon Windows 98 Installation... to retain the evidence and clear the invalid state.",
	)

	st := Menu_State {
		hard_drive_status = .None_Configured,
	}
	testing.expect_value(t, menu_center_panel(&st), Menu_Center_Panel.Welcome)
	recovery_statuses := [?]Hard_Drive_Status{.Missing, .Invalid, .Unavailable}
	for status in recovery_statuses {
		st.hard_drive_status = status
		testing.expect_value(t, menu_center_panel(&st), Menu_Center_Panel.Hard_Drive_Unavailable)
	}
	st.hard_drive_status = .Ready
	testing.expect_value(t, menu_center_panel(&st), Menu_Center_Panel.None)
	st.hard_drive_status = .None_Configured
	st.machine_running = true
	testing.expect_value(t, menu_center_panel(&st), Menu_Center_Panel.None)

	st.machine_running = false
	testing.expect(t, !menu_action_visible(&st, .Abandon_Windows_98_Installation))
	st.install_active = true
	testing.expect(t, menu_action_visible(&st, .Abandon_Windows_98_Installation))
	testing.expect(t, menu_action_visible(&st, .Create_Hard_Drive))
	st.install_active = false
	st.install_recovery_required = true
	testing.expect(t, menu_action_visible(&st, .Abandon_Windows_98_Installation))
	st.hard_drive_status = .Ready
	testing.expect_value(t, menu_center_panel(&st), Menu_Center_Panel.Install_State_Recovery)
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

@(test)
host_test_storage_activity_light_pulses_and_holds_for_visibility :: proc(t: ^testing.T) {
	light: Activity_Light_State
	testing.expect(t, !activity_light_step(&light, 0, 1, true, 0))
	testing.expect(t, activity_light_step(&light, 1, 1, true, 0.01))
	testing.expect_value(t, light.remaining_seconds, MENU_ACTIVITY_HOLD_SECONDS)
	testing.expect(t, activity_light_step(&light, 1, 1, true, 0.14))
	testing.expect(t, !activity_light_step(&light, 1, 1, true, 0.02))

	testing.expect(t, activity_light_step(&light, 2, 1, true, 1))
	testing.expect_value(t, light.remaining_seconds, MENU_ACTIVITY_HOLD_SECONDS)
	testing.expect(t, !activity_light_step(&light, 2, 1, false, 0))
	testing.expect_value(t, light.remaining_seconds, f32(0))
}

@(test)
host_test_storage_activity_light_baselines_while_stopped_and_handles_first_io :: proc(
	t: ^testing.T,
) {
	light: Activity_Light_State
	testing.expect(t, !activity_light_step(&light, 7, 1, false, 0))
	testing.expect(t, !activity_light_step(&light, 7, 1, true, 0))
	testing.expect(t, activity_light_step(&light, 8, 1, true, 0))

	fresh: Activity_Light_State
	testing.expect(t, activity_light_step(&fresh, 1, 1, true, 0))
	testing.expect_value(t, fresh.remaining_seconds, MENU_ACTIVITY_HOLD_SECONDS)
}

@(test)
host_test_storage_activity_new_machine_zero_is_baseline_then_first_io_pulses :: proc(
	t: ^testing.T,
) {
	light: Activity_Light_State
	testing.expect(t, !activity_light_step(&light, 12, 1, false, 0))
	testing.expect(t, !activity_light_step(&light, 12, 1, true, 0))
	testing.expect(t, !activity_light_step(&light, 0, 2, true, 0.01))
	testing.expect(t, activity_light_step(&light, 1, 2, true, 0.01))
}

@(test)
host_test_storage_indicators_are_anchored_to_menu_bar_right_edge :: proc(t: ^testing.T) {
	left := menu_storage_indicator_left(40, 1440)
	testing.expect_value(t, left + MENU_STORAGE_TOTAL_WIDTH + MENU_STORAGE_RIGHT_INSET, f32(1480))
	testing.expect(t, menu_storage_indicators_fit(600, left))
	narrow_left := menu_storage_indicator_left(0, 640)
	testing.expect(t, !menu_storage_indicators_fit(560, narrow_left))
}

@(test)
host_test_storage_icon_rect_draws_equal_square_canvases :: proc(t: ^testing.T) {
	floppy_min, floppy_max := menu_storage_icon_rect(256, 256, 100, 10)
	testing.expect_value(t, floppy_max.x - floppy_min.x, MENU_STORAGE_ICON_SIZE)
	testing.expect_value(t, floppy_max.y - floppy_min.y, MENU_STORAGE_ICON_SIZE)
	testing.expect_value(t, floppy_min.x, f32(100))

	hdd_min, hdd_max := menu_storage_icon_rect(240, 240, 200, 10)
	testing.expect_value(t, hdd_max.x - hdd_min.x, MENU_STORAGE_ICON_SIZE)
	testing.expect_value(t, hdd_max.y - hdd_min.y, MENU_STORAGE_ICON_SIZE)
}

@(test)
host_test_storage_icon_alpha_bounds_remove_transparent_canvas :: proc(t: ^testing.T) {
	pixels := [5 * 4 * 4]u8{}
	for y in 1 ..= 2 {
		for x in 2 ..= 4 {
			pixels[(y * 5 + x) * 4 + 3] = 255
		}
	}
	bounds, ok := storage_icon_alpha_bounds(pixels[:], 5, 4, 4)
	testing.expect(t, ok)
	testing.expect_value(t, bounds, Storage_Icon_Alpha_Bounds{x = 2, y = 1, width = 3, height = 2})
}

@(test)
host_test_storage_icon_square_bounds_center_content_without_distortion :: proc(t: ^testing.T) {
	floppy, floppy_ok := storage_icon_square_bounds(
		{x = 142, y = 146, width = 256, height = 200},
		540,
		500,
	)
	testing.expect(t, floppy_ok)
	testing.expect_value(
		t,
		floppy,
		Storage_Icon_Alpha_Bounds{x = 142, y = 118, width = 256, height = 256},
	)

	hdd, hdd_ok := storage_icon_square_bounds(
		{x = 150, y = 242, width = 240, height = 112},
		540,
		500,
	)
	testing.expect(t, hdd_ok)
	testing.expect_value(
		t,
		hdd,
		Storage_Icon_Alpha_Bounds{x = 150, y = 178, width = 240, height = 240},
	)
}

host_expect_storage_icon_png_bounds :: proc(
	t: ^testing.T,
	encoded: []u8,
	expected_content, expected_square: Storage_Icon_Alpha_Bounds,
) {
	img, err := png.load_from_bytes(encoded, {.alpha_add_if_missing})
	defer png.destroy(img)
	testing.expect(t, err == nil)
	if err != nil || img == nil {return}
	testing.expect_value(t, img.width, 540)
	testing.expect_value(t, img.height, 500)
	testing.expect_value(t, img.channels, 4)
	testing.expect_value(t, img.depth, 8)
	pixels := bytes.buffer_to_bytes(&img.pixels)
	bounds, ok := storage_icon_alpha_bounds(pixels, img.width, img.height, img.channels)
	testing.expect(t, ok)
	testing.expect_value(t, bounds, expected_content)
	square, square_ok := storage_icon_square_bounds(bounds, img.width, img.height)
	testing.expect(t, square_ok)
	testing.expect_value(t, square, expected_square)
}

@(test)
host_test_embedded_storage_icon_pngs_decode_with_expected_content_bounds :: proc(t: ^testing.T) {
	host_expect_storage_icon_png_bounds(
		t,
		STORAGE_ICON_FLOPPY_PNG,
		{x = 142, y = 146, width = 256, height = 200},
		{x = 142, y = 118, width = 256, height = 256},
	)
	host_expect_storage_icon_png_bounds(
		t,
		STORAGE_ICON_HARD_DRIVE_PNG,
		{x = 150, y = 242, width = 240, height = 112},
		{x = 150, y = 178, width = 240, height = 240},
	)
	host_expect_storage_icon_png_bounds(
		t,
		STORAGE_ICON_DVD_ROM_PNG,
		{x = 142, y = 122, width = 256, height = 256},
		{x = 142, y = 122, width = 256, height = 256},
	)
}
