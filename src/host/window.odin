// SPDX-License-Identifier: GPL-3.0-only
package host

import sdl3 "vendor:sdl3"

MENU_H :: 24 // placeholder until the ImGui menu bar (Task 22)
WIN_W :: TEXT_W * 2 // 1440
WIN_H :: TEXT_H * 2 + MENU_H // 800 + menu

Host :: struct {
	win: ^sdl3.Window,
	ren: ^sdl3.Renderer,
	tex: ^sdl3.Texture,
}

host_init :: proc(h: ^Host) -> bool {
	sdl3.SetHint(sdl3.HINT_RENDER_DRIVER, "vulkan")
	if !sdl3.Init({.VIDEO}) {
		return false
	}
	// no RESIZABLE flag: fixed-size window
	h.win = sdl3.CreateWindow("RETVRN99", WIN_W, WIN_H, {})
	if h.win == nil {
		return false
	}
	h.ren = sdl3.CreateRenderer(h.win, nil)
	if h.ren == nil {
		return false
	}
	h.tex = sdl3.CreateTexture(h.ren, .ARGB8888, .STREAMING, TEXT_W, TEXT_H)
	if h.tex == nil {
		return false
	}
	sdl3.SetTextureScaleMode(h.tex, .NEAREST)
	return true
}

host_destroy :: proc(h: ^Host) {
	if h.tex != nil {sdl3.DestroyTexture(h.tex)}
	if h.ren != nil {sdl3.DestroyRenderer(h.ren)}
	if h.win != nil {sdl3.DestroyWindow(h.win)}
	sdl3.Quit()
}
