// SPDX-License-Identifier: GPL-3.0-only
package host

import imgui "../../vendor_local/imgui"
import config "../vmconfig"

MENU_ROLL_SECONDS :: f32(0.18)

Menu_Action :: enum {
	None,
	Start,
	Stop,
	Reset,
	Toggle_Pause,
	Power_Off,
	Mount_Floppy,
	Eject_Floppy,
	Mount_Cdrom,
	Eject_Cdrom,
	Install_Windows_98,
	Finish_Windows_98_Installation,
	Set_Cpu_Mode,
	Set_Window_Scale,
	Toggle_Fullscreen,
	Set_Visual_Shader,
	Open_Github,
	Open_Third_Party,
}

Menu_State :: struct {
	machine_running:   bool,
	user_paused:       bool,
	cpu_mode:          config.Cpu_Mode,
	window_scale:      int,
	fullscreen:        bool,
	menu_reveal:       f32,
	visual_shader:     Visual_Shader,
	shaders_available: bool,
	show_hotkeys:      bool,
	show_about:        bool,
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

menu_action_enabled :: proc(st: ^Menu_State, action: Menu_Action) -> bool {
	if st == nil {return false}
	#partial switch action {
	case .Start:
		return !st.machine_running
	case .Stop:
		return st.machine_running
	case .Toggle_Pause:
		return st.machine_running
	case .Set_Window_Scale:
		return !st.fullscreen
	case .Set_Visual_Shader:
		return st.shaders_available
	}
	return true
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

menu_draw :: proc(st: ^Menu_State, info: Menu_Info) -> Menu_Action {
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
			if menu_begin("Machine") {
				if imgui.MenuItem(menu_machine_label(st)) {
					action = st.machine_running ? .Stop : .Start
				}
				if imgui.MenuItem(
					"Pause",
					nil,
					st.user_paused,
					menu_action_enabled(st, .Toggle_Pause),
				) {
					action = .Toggle_Pause
				}
				imgui.Separator()
				if imgui.MenuItem("Exit") {action = .Power_Off}
				menu_end()
			}

			if menu_begin("Emulation") {
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

			if menu_begin("Tools") {
				if imgui.MenuItem("Install Windows 98") {action = .Install_Windows_98}
				menu_end()
			}

			if menu_begin("Help") {
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

	if st.show_hotkeys {
		imgui.SetNextWindowPos(center, .Appearing, {0.5, 0.5})
		if imgui.Begin("Hotkeys", &st.show_hotkeys, {.AlwaysAutoResize, .NoCollapse}) {
			menu_text("Release input lock ([Windows/Super]+Shift+F1)")
			menu_text("Toggle full screen ([Windows/Super]+Shift+F3)")
			menu_text("Toggle Turbo ([Windows/Super]+Shift+F5)")
			menu_text("Volume Up ([Windows/Super]+Shift+F10)")
			menu_text("Volume Down ([Windows/Super]+Shift+F9)")
			imgui.Separator()
			if imgui.Button("Accept") {st.show_hotkeys = false}
			imgui.SameLine()
			if imgui.Button("Cancel") {st.show_hotkeys = false}
		}
		imgui.End()
	}

	if st.show_about {
		imgui.SetNextWindowPos(center, .Appearing, {0.5, 0.5})
		if imgui.Begin("About RETVRN99", &st.show_about, {.AlwaysAutoResize, .NoCollapse}) {
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
		if imgui.Begin("VM frozen", nil, {.AlwaysAutoResize, .NoCollapse}) {
			menu_text(info.frozen_msg)
			if len(info.regs_text) > 0 {
				imgui.Separator()
				menu_text(info.regs_text)
			}
		}
		imgui.End()
	}
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
