// SPDX-License-Identifier: GPL-3.0-only
package host

import imgui "../../vendor_local/imgui"
import config "../vmconfig"
import "core:fmt"
import "core:path/filepath"

MENU_ROLL_SECONDS :: f32(0.18)
MENU_ACTIVITY_HOLD_SECONDS :: f32(0.15)
MENU_MESSAGE_WIDTH :: f32(510)

MENU_LED_IDLE :: u32(0xFF305830)
MENU_LED_ACTIVE :: u32(0xFF00D838)

MENU_TOP_LEVEL_ORDER :: [6]cstring{"Machine", "Hard Drive", "Media", "Emulation", "Tools", "Help"}
MENU_CREATE_HARD_DRIVE_LABEL :: "Create Hard Drive..."
MENU_INSTALL_WINDOWS_98_LABEL :: "Install Windows 98..."
MENU_ABANDON_WINDOWS_98_LABEL :: "Abandon Windows 98 Installation..."

WELCOME_PANEL_TITLE :: "Welcome to RETVRN99"
WELCOME_PANEL_FIRST_TIME :: "It looks like this is your first time running RETVRN99."
WELCOME_PANEL_QUICK_START :: "Quick start"
WELCOME_PANEL_QUICK_START_TEXT :: "Choose Tools > Install Windows 98 and follow the steps."
WELCOME_PANEL_ADVANCED :: "Advanced setup"
WELCOME_PANEL_ADVANCED_FIRST :: "Create or select a hard drive, mount bootable media from the Media menu,"
WELCOME_PANEL_ADVANCED_SECOND :: "then choose Machine > Start."
WELCOME_PANEL_DOCUMENTATION :: "For the full guide, choose Help > Documentation."

RECOVERY_PANEL_TITLE :: "Hard drive unavailable"
RECOVERY_PANEL_MESSAGE :: "The selected hard drive could not be opened."
RECOVERY_PANEL_ACTION :: "Choose Hard Drive > Select Hard Drive to select another image."

INSTALL_RECOVERY_PANEL_TITLE :: "Windows 98 installation recovery"
INSTALL_RECOVERY_PANEL_MESSAGE :: "The saved Windows 98 installation state is invalid or no longer bound."
INSTALL_RECOVERY_PANEL_LOCK :: "Hard-drive and media tools remain disabled to preserve recovery evidence."
INSTALL_RECOVERY_PANEL_ACTION :: "Choose Tools > Abandon Windows 98 Installation... to retain the evidence and clear the invalid state."

Menu_Action :: enum {
	None,
	Start,
	Stop,
	Reset,
	Toggle_Pause,
	Power_Off,
	Select_Hard_Drive,
	Browse_C_Drive,
	Create_Hard_Drive,
	Mount_Floppy,
	Eject_Floppy,
	Mount_Cdrom,
	Mount_Host_Cdrom,
	Eject_Cdrom,
	Reveal_Cdrom,
	Reveal_Floppy,
	Install_Windows_98,
	Abandon_Windows_98_Installation,
	Set_Cpu_Mode,
	Set_Window_Scale,
	Toggle_Fullscreen,
	Set_Visual_Shader,
	Set_Hotkeys,
	Open_Documentation,
	Open_Github,
	Open_Third_Party,
}

Hard_Drive_Status :: enum {
	Unknown,
	None_Configured,
	Ready,
	Missing,
	Invalid,
	Unavailable,
}

Menu_Center_Panel :: enum {
	None,
	Welcome,
	Hard_Drive_Unavailable,
	Install_State_Recovery,
}

Menu_State :: struct {
	machine_running:            bool,
	machine_paused:             bool,
	user_paused:                bool,
	install_active:             bool,
	install_recovery_required:  bool,
	storage_actions_blocked:    bool,
	hard_drive_status:          Hard_Drive_Status,
	hard_drive_path:            string,
	hard_drive_diagnostic:      string,
	floppy_mounted:             bool,
	cdrom_mounted:              bool,
	floppy_unavailable:         bool,
	cdrom_unavailable:          bool,
	floppy_path:                string,
	cdrom_path:                 string,
	floppy_diagnostic:          string,
	cdrom_diagnostic:           string,
	host_optical_drives:        [26]bool,
	requested_host_optical:     u8,
	floppy_active:              bool,
	hard_drive_active:          bool,
	dvd_rom_active:             bool,
	cpu_mode:                   config.Cpu_Mode,
	window_scale:               int,
	fullscreen:                 bool,
	menu_reveal:                f32,
	visual_shader:              Visual_Shader,
	shaders_available:          bool,
	show_hotkeys:               bool,
	hotkeys:                    Hotkey_Config,
	hotkey_editor:              Hotkey_Editor_State,
	show_about:                 bool,
	show_hard_drive_properties: bool,
	show_cdrom_properties:      bool,
	show_floppy_properties:     bool,
	general_status:             string,
}

Activity_Light_State :: struct {
	generation:         u64,
	session_generation: u64,
	remaining_seconds:  f32,
	initialized:        bool,
}

activity_light_step :: proc(
	light: ^Activity_Light_State,
	generation: u64,
	session_generation: u64,
	machine_running: bool,
	elapsed_seconds: f32,
) -> bool {
	if light == nil {return false}
	if !machine_running {
		light.generation = generation
		light.session_generation = session_generation
		light.remaining_seconds = 0
		light.initialized = true
		return false
	}
	if light.session_generation != session_generation {
		light.session_generation = session_generation
		light.generation = generation
		light.initialized = true
		light.remaining_seconds = generation != 0 ? MENU_ACTIVITY_HOLD_SECONDS : 0
		return light.remaining_seconds > 0
	}
	changed := light.initialized && light.generation != generation
	if !light.initialized {
		light.initialized = true
		changed = generation != 0
	}
	light.generation = generation
	if changed {
		light.remaining_seconds = MENU_ACTIVITY_HOLD_SECONDS
	} else {
		light.remaining_seconds = max(
			f32(0),
			light.remaining_seconds - max(f32(0), elapsed_seconds),
		)
	}
	return light.remaining_seconds > 0
}

menu_reveal_step :: proc(current, target, elapsed_seconds: f32) -> f32 {
	from := clamp(current, f32(0), f32(1))
	to := clamp(target, f32(0), f32(1))
	step := max(f32(0), elapsed_seconds) / MENU_ROLL_SECONDS
	if from < to {return min(to, from + step)}
	return max(to, from - step)
}

Menu_Info :: struct {
	frozen_msg: string,
	regs_text:  string,
}

menu_machine_label :: proc(st: ^Menu_State) -> cstring {
	return st != nil && st.machine_running ? "Stop" : "Start"
}

menu_select_hard_drive_label :: proc(st: ^Menu_State) -> cstring {
	if st != nil && st.machine_running {
		return "Select Hard Drive... (Stop machine first)"
	}
	return "Select Hard Drive..."
}

menu_browse_c_drive_label :: proc(st: ^Menu_State) -> cstring {
	if st != nil && st.machine_running {
		return "Browse C drive... (Stop machine first)"
	}
	return "Browse C drive..."
}

menu_current_hard_drive_label :: proc(st: ^Menu_State) -> cstring {
	if st == nil || len(st.hard_drive_path) == 0 {return "Current: None"}
	return fmt.ctprintf("Current: %s", filepath.base(st.hard_drive_path))
}

menu_action_visible :: proc(st: ^Menu_State, action: Menu_Action) -> bool {
	if action == .Abandon_Windows_98_Installation {
		return st != nil && menu_install_storage_locked(st)
	}
	return true
}

menu_center_panel :: proc(st: ^Menu_State) -> Menu_Center_Panel {
	if st == nil || st.machine_running {return .None}
	if st.install_recovery_required {return .Install_State_Recovery}
	switch st.hard_drive_status {
	case .None_Configured:
		return .Welcome
	case .Missing, .Invalid, .Unavailable:
		return .Hard_Drive_Unavailable
	case .Unknown, .Ready:
		return .None
	}
	return .None
}

menu_action_enabled :: proc(st: ^Menu_State, action: Menu_Action) -> bool {
	if st == nil {return false}
	install_locked := menu_install_storage_locked(st)
	#partial switch action {
	case .Start:
		return !st.machine_running && !st.install_recovery_required && !st.storage_actions_blocked
	case .Stop:
		return st.machine_running
	case .Reset, .Toggle_Pause:
		return st.machine_running
	case .Select_Hard_Drive:
		return !st.machine_running && !install_locked && !st.storage_actions_blocked
	case .Browse_C_Drive:
		return(
			!st.machine_running &&
			!install_locked &&
			!st.storage_actions_blocked &&
			st.hard_drive_status == .Ready &&
			len(st.hard_drive_path) > 0 \
		)
	case .Create_Hard_Drive, .Install_Windows_98:
		return !st.machine_running && !install_locked && !st.storage_actions_blocked
	case .Abandon_Windows_98_Installation:
		return !st.machine_running && install_locked && !st.storage_actions_blocked
	case .Mount_Floppy:
		return !install_locked && !st.storage_actions_blocked
	case .Eject_Floppy:
		return !install_locked && !st.storage_actions_blocked && st.floppy_mounted
	case .Mount_Cdrom, .Mount_Host_Cdrom:
		return !install_locked && !st.storage_actions_blocked
	case .Eject_Cdrom:
		return !install_locked && !st.storage_actions_blocked && st.cdrom_mounted
	case .Set_Window_Scale:
		return !st.fullscreen
	case .Set_Visual_Shader:
		return st.shaders_available
	case .Reveal_Cdrom:
		return len(st.cdrom_path) > 0
	case .Reveal_Floppy:
		return len(st.floppy_path) > 0
	}
	return true
}

menu_install_storage_locked :: proc(st: ^Menu_State) -> bool {
	return st != nil && (st.install_active || st.install_recovery_required)
}

// Dear ImGui deliberately removes the usual frame padding from vertical menu
// items. Restore a small Win32-style gutter inside each popup.
menu_begin :: proc(label: cstring, enabled: bool = true) -> bool {
	if !imgui.BeginMenu(label, enabled) {return false}
	imgui.Indent(THEME_MENU_ITEM_INSET_X)
	return true
}

menu_end :: proc() {
	imgui.Unindent(THEME_MENU_ITEM_INSET_X)
	imgui.EndMenu()
}

hard_drive_menu_contents :: proc(st: ^Menu_State) -> Menu_Action {
	action := Menu_Action.None
	if imgui.MenuItem(
		menu_select_hard_drive_label(st),
		nil,
		false,
		menu_action_enabled(st, .Select_Hard_Drive),
	) {
		action = .Select_Hard_Drive
	}
	if imgui.MenuItem(
		menu_browse_c_drive_label(st),
		nil,
		false,
		menu_action_enabled(st, .Browse_C_Drive),
	) {
		action = .Browse_C_Drive
	}
	imgui.Separator()
	_ = imgui.MenuItem(menu_current_hard_drive_label(st), nil, false, false)
	if st != nil && len(st.hard_drive_path) > 0 {
		imgui.SetItemTooltip("%s", fmt.ctprintf("%s", st.hard_drive_path))
	}
	return action
}

menu_draw :: proc(
	st: ^Menu_State,
	info: Menu_Info,
	storage_icons: Storage_Icon_Textures,
) -> Menu_Action {
	action := Menu_Action.None
	viewport := imgui.GetMainViewport()
	if st.menu_reveal > 0 {
		bar_height := f32(MENU_BAR_H)
		imgui.SetNextWindowPos(
			{viewport.Pos.x, viewport.Pos.y - bar_height * (1 - st.menu_reveal)},
		)
		imgui.SetNextWindowSize({viewport.Size.x, bar_height})
		imgui.SetNextWindowViewport(viewport.ID_)
		// The top bar is flush and borderless like a native Win32 menu. Dialogs and
		// popup menus retain the crisp one-pixel border from the global theme.
		imgui.PushStyleVarImVec2(.WindowPadding, {THEME_MENU_INSET_X, 0})
		imgui.PushStyleVar(.WindowBorderSize, 0)
		imgui.PushStyleVarImVec2(.WindowMinSize, {0, 0})
		// Begin() paints the menu-bar decoration. Match its edge to the face so the
		// top menu flows directly into the guest display without an underline.
		imgui.PushStyleColorImVec4(.Border, theme_color(THEME_FACE))
		imgui.PushStyleColorImVec4(.Separator, theme_color(THEME_FACE))
		bar_open := imgui.Begin(
			"##retvrn99_top_menu",
			nil,
			{
				.NoTitleBar,
				.NoResize,
				.NoMove,
				.NoScrollbar,
				.NoScrollWithMouse,
				.NoCollapse,
				.NoSavedSettings,
				.MenuBar,
				.NoFocusOnAppearing,
				.NoBringToFrontOnFocus,
				.NoNavFocus,
				.NoDocking,
			},
		)
		imgui.PopStyleColor(2)
		if bar_open && imgui.BeginMenuBar() {
			if menu_begin(MENU_TOP_LEVEL_ORDER[0]) {
				machine_action := st.machine_running ? Menu_Action.Stop : .Start
				if imgui.MenuItem(
					menu_machine_label(st),
					nil,
					false,
					menu_action_enabled(st, machine_action),
				) {
					action = machine_action
				}
				if imgui.MenuItem(
					"Pause",
					nil,
					st.user_paused,
					menu_action_enabled(st, .Toggle_Pause),
				) {
					action = .Toggle_Pause
				}
				if imgui.MenuItem("Reset", nil, false, menu_action_enabled(st, .Reset)) {
					action = .Reset
				}
				imgui.Separator()
				if imgui.MenuItem("Exit") {action = .Power_Off}
				menu_end()
			}

			if menu_begin(MENU_TOP_LEVEL_ORDER[1]) {
				hard_drive_action := hard_drive_menu_contents(st)
				if hard_drive_action != .None {action = hard_drive_action}
				menu_end()
			}

			if menu_begin(MENU_TOP_LEVEL_ORDER[2]) {
				for device in storage_menu_device_order {
					if menu_begin(fmt.ctprintf("%s", storage_device_label(device))) {
						device_action := storage_device_menu_contents(st, device)
						if device_action != .None {action = device_action}
						menu_end()
					}
				}
				menu_end()
			}

			if menu_begin(MENU_TOP_LEVEL_ORDER[3]) {
				if menu_begin("Speed") {
					if imgui.MenuItem("GSW886 @700MHz", nil, st.cpu_mode == .GSW_886) {
						st.cpu_mode = .GSW_886
						action = .Set_Cpu_Mode
					}
					if imgui.MenuItem("Turbo (Uncapped)", nil, st.cpu_mode == .Turbo) {
						st.cpu_mode = .Turbo
						action = .Set_Cpu_Mode
					}
					menu_end()
				}

				if menu_begin("Scaling", menu_action_enabled(st, .Set_Window_Scale)) {
					for scale in 2 ..= 4 {
						label: cstring = scale == 2 ? "2x" : scale == 3 ? "3x" : "4x"
						if imgui.MenuItem(label, nil, st.window_scale == scale) {
							st.window_scale = scale
							action = .Set_Window_Scale
						}
					}
					menu_end()
				}

				if imgui.MenuItem("Full Screen", nil, st.fullscreen) {
					action = .Toggle_Fullscreen
				}

				if menu_begin("Visual Shader") {
					styles := []Visual_Shader{.None, .Subtle, .Not_So_Subtle}
					for style in styles {
						enabled := style == .None || menu_action_enabled(st, .Set_Visual_Shader)
						label := visual_shader_name(style)
						if imgui.MenuItem(label, nil, st.visual_shader == style, enabled) {
							st.visual_shader = style
							action = .Set_Visual_Shader
						}
					}
					menu_end()
				}
				imgui.Separator()
				if imgui.MenuItem("Hotkeys") {st.show_hotkeys = true}
				menu_end()
			}

			if menu_begin(MENU_TOP_LEVEL_ORDER[4]) {
				if imgui.MenuItem(
					MENU_CREATE_HARD_DRIVE_LABEL,
					nil,
					false,
					menu_action_enabled(st, .Create_Hard_Drive),
				) {
					action = .Create_Hard_Drive
				}
				if imgui.MenuItem(
					MENU_INSTALL_WINDOWS_98_LABEL,
					nil,
					false,
					menu_action_enabled(st, .Install_Windows_98),
				) {
					action = .Install_Windows_98
				}
				if menu_action_visible(st, .Abandon_Windows_98_Installation) {
					if imgui.MenuItem(
						MENU_ABANDON_WINDOWS_98_LABEL,
						nil,
						false,
						menu_action_enabled(st, .Abandon_Windows_98_Installation),
					) {
						action = .Abandon_Windows_98_Installation
					}
				}
				menu_end()
			}

			if menu_begin(MENU_TOP_LEVEL_ORDER[5]) {
				if imgui.MenuItem("Documentation") {action = .Open_Documentation}
				imgui.Separator()
				if imgui.MenuItem("Github") {action = .Open_Github}
				if imgui.MenuItem("About...") {st.show_about = true}
				menu_end()
			}
			imgui.EndMenuBar()
		}
		imgui.End()
		imgui.PopStyleVar(3)
	}

	center := imgui.Vec2 {
		viewport.Pos.x + viewport.Size.x * 0.5,
		viewport.Pos.y + viewport.Size.y * 0.5,
	}

	center_panel := menu_center_panel(st)
	if center_panel == .Welcome {
		imgui.SetNextWindowPos(center, .Appearing, {0.5, 0.5})
		if win98_begin_window(
			WELCOME_PANEL_TITLE,
			nil,
			{.AlwaysAutoResize, .NoCollapse, .NoSavedSettings},
		) {
			menu_message_intro(
				storage_icons.computer_32,
				"Initial Setup",
				WELCOME_PANEL_FIRST_TIME,
				MENU_MESSAGE_WIDTH,
			)
			imgui.Separator()
			menu_text(WELCOME_PANEL_QUICK_START)
			menu_text(WELCOME_PANEL_QUICK_START_TEXT)
			imgui.Separator()
			menu_text(WELCOME_PANEL_ADVANCED)
			menu_text(WELCOME_PANEL_ADVANCED_FIRST)
			menu_text(WELCOME_PANEL_ADVANCED_SECOND)
			imgui.Separator()
			menu_text(WELCOME_PANEL_DOCUMENTATION)
		}
		imgui.End()
	} else if center_panel == .Hard_Drive_Unavailable {
		imgui.SetNextWindowPos(center, .Appearing, {0.5, 0.5})
		if win98_begin_window(
			RECOVERY_PANEL_TITLE,
			nil,
			{.AlwaysAutoResize, .NoCollapse, .NoSavedSettings},
		) {
			menu_message_intro(
				storage_icons.warning_32,
				RECOVERY_PANEL_TITLE,
				RECOVERY_PANEL_MESSAGE,
				MENU_MESSAGE_WIDTH,
			)
			if len(st.hard_drive_path) > 0 {menu_text(st.hard_drive_path)}
			if len(st.hard_drive_diagnostic) > 0 {
				menu_message_details(st.hard_drive_diagnostic, MENU_MESSAGE_WIDTH)
			}
			imgui.Separator()
			menu_text(RECOVERY_PANEL_ACTION)
		}
		imgui.End()
	} else if center_panel == .Install_State_Recovery {
		imgui.SetNextWindowPos(center, .Appearing, {0.5, 0.5})
		if win98_begin_window(
			INSTALL_RECOVERY_PANEL_TITLE,
			nil,
			{.AlwaysAutoResize, .NoCollapse, .NoSavedSettings},
		) {
			menu_message_intro(
				storage_icons.warning_32,
				INSTALL_RECOVERY_PANEL_TITLE,
				INSTALL_RECOVERY_PANEL_MESSAGE,
				MENU_MESSAGE_WIDTH,
			)
			menu_text(INSTALL_RECOVERY_PANEL_LOCK)
			imgui.Separator()
			menu_text(INSTALL_RECOVERY_PANEL_ACTION)
		}
		imgui.End()
	}

	if st.show_hotkeys {
		imgui.SetNextWindowPos(center, .Appearing, {0.5, 0.5})
		window_open := st.show_hotkeys
		if win98_begin_window(
			"Hotkeys",
			&window_open,
			{.AlwaysAutoResize, .NoCollapse, .NoSavedSettings},
		) {
			apply_hotkeys, close_hotkeys := hotkey_editor_draw(st, storage_icons.settings_32)
			if apply_hotkeys {action = .Set_Hotkeys}
			if close_hotkeys {window_open = false}
		}
		imgui.End()
		if !window_open {
			st.show_hotkeys = false
			st.hotkey_editor.initialized = false
			hotkey_editor_cancel(&st.hotkey_editor)
		}
	}

	if st.show_about {
		imgui.SetNextWindowPos(center, .Appearing, {0.5, 0.5})
		if win98_begin_window("About RETVRN99", &st.show_about, {.AlwaysAutoResize, .NoCollapse}) {
			menu_text("RETVRN99 (c) 2026 - General Simulation Works")
			menu_text("GPLv3-only")
			if imgui.TextLink("Github") {action = .Open_Github}
			if imgui.TextLink("Third party licenses and acknowledgements") {
				action = .Open_Third_Party
			}
			imgui.Separator()
			if imgui.Button("Close") {st.show_about = false}
		}
		imgui.End()
	}

	if len(info.frozen_msg) > 0 {
		imgui.SetNextWindowPos(center, .Appearing, {0.5, 0.5})
		if win98_begin_window("VM frozen", nil, {.AlwaysAutoResize, .NoCollapse}) {
			menu_message_intro(
				storage_icons.error_32,
				"Virtual Machine Error",
				info.frozen_msg,
				MENU_MESSAGE_WIDTH,
			)
			if len(info.regs_text) > 0 {
				menu_message_details(info.regs_text, MENU_MESSAGE_WIDTH)
			}
		}
		imgui.End()
	}
	storage_properties_draw(st, storage_icons)
	status_action := status_bar_draw(st, storage_icons)
	if action == .None && status_action != .None {action = status_action}
	return action
}

menu_text :: proc(s: string) {
	if len(s) == 0 {
		imgui.TextUnformatted("")
		return
	}
	d := raw_data(s)
	imgui.TextUnformatted(cstring(d), cstring(d[len(s):]))
}

menu_message_intro :: proc(icon: Ui_Icon_Texture, title, summary: string, width: f32) {
	win98_section_title(title, width)
	imgui.Spacing()
	imgui.Image(win98_texture_ref(icon), {32, 32})
	imgui.SameLine()
	imgui.BeginGroup()
	win98_dialog_wrapped_text(summary, width - 48)
	imgui.EndGroup()
	imgui.Spacing()
}

menu_message_details :: proc(details: string, width: f32) {
	if len(details) == 0 {return}
	imgui.Spacing()
	minimum := imgui.GetCursorScreenPos()
	imgui.BeginGroup()
	imgui.Dummy({width - 12, 1})
	win98_dialog_wrapped_text(details, width - 24)
	imgui.Spacing()
	if imgui.Button("Copy Details") {
		imgui.SetClipboardText(fmt.ctprintf("%s", details))
	}
	imgui.EndGroup()
	maximum := imgui.GetItemRectMax()
	win98_draw_bevel(
		imgui.GetWindowDrawList(),
		{minimum.x - 4, minimum.y - 3},
		{maximum.x + 4, maximum.y + 3},
		true,
	)
	imgui.Spacing()
}
