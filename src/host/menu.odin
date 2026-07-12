// SPDX-License-Identifier: GPL-3.0-only
package host

import imgui "../../vendor_local/imgui"

Menu_Action :: enum {
	None,
	Reset,
	Power_Off,
	Mount_Floppy,
	Eject_Floppy,
}

Menu_State :: struct {
	show_debug: bool, // panel vCPU / estadísticas de salidas
	show_log:   bool, // panel de log de dispositivos
}

Menu_Info :: struct {
	frozen_msg: string, // vacío = VM viva
	regs_text:  string,
	exit_lines: []string,
	log_lines:  []string,
}

// Dibuja barra de menú, paneles de depuración y el aviso de congelación.
menu_draw :: proc(st: ^Menu_State, info: Menu_Info) -> Menu_Action {
	action := Menu_Action.None
	if imgui.BeginMainMenuBar() {
		if imgui.BeginMenu("Machine") {
			if imgui.MenuItem("Reset") { action = .Reset }
			imgui.MenuItem("Throttle", nil, false, false) // pendiente Task 25
			imgui.Separator()
			if imgui.MenuItem("Power Off") { action = .Power_Off }
			imgui.EndMenu()
		}
		if imgui.BeginMenu("Media") {
			if imgui.MenuItem("Mount Floppy...") { action = .Mount_Floppy }
			if imgui.MenuItem("Eject Floppy") { action = .Eject_Floppy }
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
		imgui.SetNextWindowPos({20, 40}, .FirstUseEver)
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
		imgui.SetNextWindowPos({400, 40}, .FirstUseEver)
		imgui.SetNextWindowSize({640, 320}, .FirstUseEver)
		if imgui.Begin("Device log", &st.show_log) {
			for l in info.log_lines { menu_text(l) }
			if imgui.GetScrollY() >= imgui.GetScrollMaxY() - 1 {
				imgui.SetScrollHereY(1) // autoscroll pegado al final
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

// TextUnformatted sin exigir cadenas terminadas en cero
menu_text :: proc(s: string) {
	if len(s) == 0 {
		imgui.TextUnformatted("")
		return
	}
	d := raw_data(s)
	imgui.TextUnformatted(cstring(d), cstring(d[len(s):]))
}
