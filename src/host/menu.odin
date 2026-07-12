// SPDX-License-Identifier: GPL-3.0-only
package host

import imgui "../../vendor_local/imgui"
import config "../vmconfig"

Menu_Action :: enum {
	None,
	Reset,
	Power_Off,
	Mount_Floppy,
	Eject_Floppy,
	Mount_Cdrom,
	Eject_Cdrom,
	Install_Windows_98,
	Set_Cpu_Mode,
}

Menu_State :: struct {
	show_debug:           bool, // vCPU / exit-stats panel
	show_log:             bool, // device-log panel
	cpu_mode:             config.Cpu_Mode,
	cdrom_mounted:        bool,
	installing_windows_98: bool,
}

Menu_Info :: struct {
	frozen_msg: string, // empty = VM alive
	regs_text:  string,
	exit_lines: []string,
	log_lines:  []string,
}

menu_action_enabled :: proc(st: ^Menu_State, action: Menu_Action) -> bool {
	#partial switch action {
	case .Mount_Cdrom, .Install_Windows_98:
		return !st.installing_windows_98
	case .Eject_Cdrom:
		return st.cdrom_mounted && !st.installing_windows_98
	}
	return true
}

// Draws the menu bar, debug panels and the freeze notice.
menu_draw :: proc(st: ^Menu_State, info: Menu_Info) -> Menu_Action {
	action := Menu_Action.None
	if imgui.BeginMainMenuBar() {
		if imgui.BeginMenu("Machine") {
			if imgui.MenuItem("Reset") { action = .Reset }
			if imgui.BeginMenu("CPU Speed") {
				if imgui.MenuItem("GSW-886", nil, st.cpu_mode == .GSW_886) {
					st.cpu_mode = .GSW_886
					action = .Set_Cpu_Mode
				}
				if imgui.MenuItem("Turbo", nil, st.cpu_mode == .Turbo) {
					st.cpu_mode = .Turbo
					action = .Set_Cpu_Mode
				}
				imgui.EndMenu()
			}
			imgui.Separator()
			if imgui.MenuItem(
				"Install Windows 98...",
				nil,
				false,
				menu_action_enabled(st, .Install_Windows_98),
			) {
				action = .Install_Windows_98
			}
			imgui.Separator()
			if imgui.MenuItem("Power Off") { action = .Power_Off }
			imgui.EndMenu()
		}
		if imgui.BeginMenu("Media") {
			if imgui.MenuItem("Mount Floppy...") { action = .Mount_Floppy }
			if imgui.MenuItem("Eject Floppy") { action = .Eject_Floppy }
			imgui.Separator()
			if imgui.MenuItem(
				"Mount CD-ROM...",
				nil,
				false,
				menu_action_enabled(st, .Mount_Cdrom),
			) {
				action = .Mount_Cdrom
			}
			if imgui.MenuItem(
				"Eject CD-ROM",
				nil,
				false,
				menu_action_enabled(st, .Eject_Cdrom),
			) {
				action = .Eject_Cdrom
			}
			imgui.EndMenu()
		}
		if imgui.BeginMenu("Debug") {
			imgui.MenuItemBoolPtr("vCPU / exit stats", nil, &st.show_debug)
			imgui.MenuItemBoolPtr("Device log", nil, &st.show_log)
			imgui.EndMenu()
		}
		imgui.EndMainMenuBar()
	}

	if st.show_debug {
		imgui.SetNextWindowPos({20, MENU_BAR_H + 16}, .FirstUseEver)
		if imgui.Begin("vCPU", &st.show_debug, {.AlwaysAutoResize}) {
			for l in info.exit_lines { menu_text(l) }
			if len(info.regs_text) > 0 {
				imgui.Separator()
				menu_text(info.regs_text)
			}
		}
		imgui.End()
	}

	if st.show_log {
		imgui.SetNextWindowPos({400, MENU_BAR_H + 16}, .FirstUseEver)
		imgui.SetNextWindowSize({640, 320}, .FirstUseEver)
		if imgui.Begin("Device log", &st.show_log) {
			for l in info.log_lines { menu_text(l) }
			if imgui.GetScrollY() >= imgui.GetScrollMaxY() - 1 {
				imgui.SetScrollHereY(1) // autoscroll pinned to the end
			}
		}
		imgui.End()
	}

	if len(info.frozen_msg) > 0 {
		imgui.SetNextWindowPos({f32(WIN_W) / 2, f32(WIN_H) / 2}, .Appearing, {0.5, 0.5})
		if imgui.Begin("VM frozen", nil, {.AlwaysAutoResize, .NoCollapse}) {
			menu_text(info.frozen_msg)
			imgui.Separator()
			menu_text(info.regs_text)
		}
		imgui.End()
	}
	return action
}

// TextUnformatted without requiring zero-terminated strings
menu_text :: proc(s: string) {
	if len(s) == 0 {
		imgui.TextUnformatted("")
		return
	}
	d := raw_data(s)
	imgui.TextUnformatted(cstring(d), cstring(d[len(s):]))
}
