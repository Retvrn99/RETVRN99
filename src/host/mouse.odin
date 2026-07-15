// SPDX-License-Identifier: GPL-3.0-only
package host

import sdl3 "vendor:sdl3"

MOUSE_LEFT :: u8(1 << 0)
MOUSE_RIGHT :: u8(1 << 1)
MOUSE_MIDDLE :: u8(1 << 2)

mouse_inside_guest :: proc(h: ^Host, x, y: f32) -> bool {
	if h == nil || !h.has_frame {return false}
	output_width, output_height := WIN_W, WIN_H
	w, hh: i32
	if h.ren != nil && sdl3.GetRenderOutputSize(h.ren, &w, &hh) {
		output_width = int(w)
		output_height = int(hh)
	}
	r := guest_view_rect(
		h.aspect_width,
		h.aspect_height,
		output_width,
		output_height,
		f32(MENU_BAR_H) * h.menu_reveal,
	)
	return x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h
}

mouse_buttons_from_sdl :: proc(flags: sdl3.MouseButtonFlags) -> u8 {
	buttons: u8
	if .LEFT in flags {buttons |= MOUSE_LEFT}
	if .RIGHT in flags {buttons |= MOUSE_RIGHT}
	if .MIDDLE in flags {buttons |= MOUSE_MIDDLE}
	return buttons
}

mouse_set_button :: proc(buttons: u8, button: u8, down: bool) -> u8 {
	mask: u8
	switch int(button) {
	case sdl3.BUTTON_LEFT:
		mask = MOUSE_LEFT
	case sdl3.BUTTON_RIGHT:
		mask = MOUSE_RIGHT
	case sdl3.BUTTON_MIDDLE:
		mask = MOUSE_MIDDLE
	case:
		return buttons
	}
	return down ? buttons | mask : buttons &~ mask
}

mouse_capture :: proc(h: ^Host, enabled: bool) -> bool {
	if h == nil || h.win == nil {return false}
	if h.mouse_captured == enabled {return true}
	if !sdl3.SetWindowRelativeMouseMode(h.win, enabled) {return false}
	h.mouse_captured = enabled
	if !enabled {h.mouse_buttons = 0}
	return true
}
