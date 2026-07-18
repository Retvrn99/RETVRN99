// SPDX-License-Identifier: GPL-3.0-only
package host

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
	testing.expect(t, !menu_action_visible(&st, .Quick_Install_Windows_98))
	st.quick_install_enabled = true
	testing.expect(t, menu_action_visible(&st, .Quick_Install_Windows_98))
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

host_expect_ui_icon_png_size :: proc(t: ^testing.T, encoded: []u8, expected_size: int) {
	img, err := png.load_from_bytes(encoded, {.alpha_add_if_missing})
	defer png.destroy(img)
	testing.expect(t, err == nil)
	if err != nil || img == nil {return}
	testing.expect_value(t, img.width, expected_size)
	testing.expect_value(t, img.height, expected_size)
	testing.expect_value(t, img.channels, 4)
	testing.expect_value(t, img.depth, 8)
}

@(test)
host_test_storage_sidebar_order_is_hdd_dvd_floppy :: proc(t: ^testing.T) {
	testing.expect_value(t, storage_sidebar_device_order[0], Storage_Sidebar_Device.Hard_Drive)
	testing.expect_value(t, storage_sidebar_device_order[1], Storage_Sidebar_Device.Dvd_Rom)
	testing.expect_value(t, storage_sidebar_device_order[2], Storage_Sidebar_Device.Floppy)
}

@(test)
host_test_media_menu_uses_sidebar_device_order_and_current_paths :: proc(t: ^testing.T) {
	st := Menu_State {
		hard_drive_path = `D:\images\c_drive.img`,
		cdrom_path      = `D:\images\Windows 98.iso`,
		floppy_path     = `D:\images\boot.img`,
		cdrom_mounted   = true,
	}
	testing.expect_value(t, storage_sidebar_device_label(storage_sidebar_device_order[0]), "Hard disk")
	testing.expect_value(t, storage_sidebar_device_label(storage_sidebar_device_order[1]), "DVD-ROM")
	testing.expect_value(t, storage_sidebar_device_label(storage_sidebar_device_order[2]), "Floppy")
	testing.expect_value(
		t,
		storage_device_menu_current_label(&st, .Hard_Drive),
		cstring("Current: c_drive.img"),
	)
	testing.expect_value(
		t,
		storage_device_menu_current_label(&st, .Dvd_Rom),
		cstring("Current: Windows 98.iso"),
	)
	testing.expect_value(
		t,
		storage_device_menu_current_label(&st, .Floppy),
		cstring("Current: boot.img"),
	)
	testing.expect_value(t, storage_device_menu_mount_label(&st, .Dvd_Rom), cstring("Change..."))
	testing.expect_value(t, storage_device_menu_mount_label(&st, .Floppy), cstring("Mount..."))
	testing.expect(t, menu_action_enabled(&st, .Mount_Cdrom))
	testing.expect(t, menu_action_enabled(&st, .Eject_Cdrom))
	testing.expect(t, menu_action_enabled(&st, .Reveal_Cdrom))
	testing.expect(t, menu_action_enabled(&st, .Mount_Floppy))
	testing.expect(t, !menu_action_enabled(&st, .Eject_Floppy))
	testing.expect(t, menu_action_enabled(&st, .Reveal_Floppy))

	empty: Menu_State
	testing.expect_value(
		t,
		storage_device_menu_current_label(&empty, .Hard_Drive),
		cstring("Current: None"),
	)
	testing.expect_value(
		t,
		storage_device_menu_current_label(&empty, .Dvd_Rom),
		cstring("Current: No image"),
	)
	testing.expect(t, !menu_action_enabled(&empty, .Reveal_Cdrom))
	testing.expect(t, !menu_action_enabled(&empty, .Reveal_Floppy))
}

@(test)
host_test_status_bar_reports_only_machine_state :: proc(t: ^testing.T) {
	st: Menu_State
	testing.expect_value(t, status_bar_machine_text(&st), "Machine stopped")
	st.machine_running = true
	testing.expect_value(t, status_bar_machine_text(&st), "Machine running")
	st.machine_paused = true
	testing.expect_value(t, status_bar_machine_text(&st), "Machine paused")
}

@(test)
host_test_storage_sidebar_collapse_changes_client_inset :: proc(t: ^testing.T) {
	h := Host{menu_reveal = 1}
	expanded := host_client_insets(&h)
	testing.expect_value(t, expanded.top, f32(MENU_BAR_H))
	testing.expect_value(t, expanded.right, f32(STORAGE_SIDEBAR_EXPANDED_W + STORAGE_SIDEBAR_GAP))
	testing.expect_value(t, expanded.bottom, f32(STATUS_BAR_H))
	h.sidebar_collapsed = true
	collapsed := host_client_insets(&h)
	testing.expect_value(t, collapsed.right, f32(STORAGE_SIDEBAR_COLLAPSED_W + STORAGE_SIDEBAR_GAP))
}

@(test)
host_test_storage_sidebar_arrow_points_toward_movement :: proc(t: ^testing.T) {
	testing.expect_value(t, storage_sidebar_toggle_direction(false), Storage_Sidebar_Toggle_Direction.Right)
	testing.expect_value(t, storage_sidebar_toggle_direction(true), Storage_Sidebar_Toggle_Direction.Left)
}

@(test)
host_test_embedded_chicago95_icons_decode_at_native_sizes :: proc(t: ^testing.T) {
	host_expect_ui_icon_png_size(t, UI_ICON_COMPUTER_16_PNG, 16)
	host_expect_ui_icon_png_size(t, UI_ICON_HARD_DRIVE_16_PNG, 16)
	host_expect_ui_icon_png_size(t, UI_ICON_DVD_ROM_16_PNG, 16)
	host_expect_ui_icon_png_size(t, UI_ICON_FLOPPY_16_PNG, 16)
	host_expect_ui_icon_png_size(t, UI_ICON_FOLDER_16_PNG, 16)
	host_expect_ui_icon_png_size(t, UI_ICON_FOLDER_OPEN_16_PNG, 16)
	host_expect_ui_icon_png_size(t, UI_ICON_GENERIC_FILE_16_PNG, 16)
	host_expect_ui_icon_png_size(t, UI_ICON_TEXT_FILE_16_PNG, 16)
	host_expect_ui_icon_png_size(t, UI_ICON_EXECUTABLE_16_PNG, 16)
	host_expect_ui_icon_png_size(t, UI_ICON_COMPUTER_32_PNG, 32)
	host_expect_ui_icon_png_size(t, UI_ICON_HARD_DRIVE_32_PNG, 32)
	host_expect_ui_icon_png_size(t, UI_ICON_DVD_ROM_32_PNG, 32)
	host_expect_ui_icon_png_size(t, UI_ICON_FLOPPY_32_PNG, 32)
	host_expect_ui_icon_png_size(t, UI_ICON_SETTINGS_32_PNG, 32)
	host_expect_ui_icon_png_size(t, UI_ICON_ERROR_32_PNG, 32)
	host_expect_ui_icon_png_size(t, UI_ICON_WARNING_32_PNG, 32)
}
