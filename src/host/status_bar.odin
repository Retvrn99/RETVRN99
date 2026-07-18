// SPDX-License-Identifier: GPL-3.0-only
package host

import imgui "../../vendor_local/imgui"

STATUS_MACHINE_CELL_W :: f32(170)
STATUS_CELL_GAP :: f32(3)

status_bar_machine_text :: proc(st: ^Menu_State) -> string {
	if st == nil || !st.machine_running {return "Machine stopped"}
	if st.machine_paused {return "Machine paused"}
	return "Machine running"
}

status_bar_draw :: proc(st: ^Menu_State) {
	if st == nil || st.menu_reveal <= 0 {return}
	viewport := imgui.GetMainViewport()
	height := f32(STATUS_BAR_H)
	imgui.SetNextWindowPos({
		viewport.Pos.x,
		viewport.Pos.y + viewport.Size.y - height * st.menu_reveal,
	})
	imgui.SetNextWindowSize({viewport.Size.x, height})
	imgui.SetNextWindowViewport(viewport.ID_)
	imgui.PushStyleVarImVec2(.WindowPadding, {2, 2})
	imgui.PushStyleVar(.WindowBorderSize, 0)
	imgui.PushStyleVarImVec2(.WindowMinSize, {0, 0})
	open := imgui.Begin(
		"##retvrn99_status_bar",
		nil,
		{
			.NoTitleBar,
			.NoResize,
			.NoMove,
			.NoScrollbar,
			.NoScrollWithMouse,
			.NoCollapse,
			.NoSavedSettings,
			.NoFocusOnAppearing,
			.NoBringToFrontOnFocus,
			.NoNavFocus,
			.NoDocking,
		},
	)
	if open {
		available := imgui.GetContentRegionAvail()
		cell_height := max(f32(1), available.y)
		win98_status_cell(status_bar_machine_text(st), STATUS_MACHINE_CELL_W, cell_height)
		imgui.SameLine(0, STATUS_CELL_GAP)
		general_width := max(f32(1), available.x - STATUS_MACHINE_CELL_W - STATUS_CELL_GAP)
		general := st.general_status
		if len(general) == 0 {general = "Ready"}
		win98_status_cell(general, general_width, cell_height)
	}
	imgui.End()
	imgui.PopStyleVar(3)
}
