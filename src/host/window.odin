// SPDX-License-Identifier: GPL-3.0-only
package host

import sdl3 "vendor:sdl3"

WIN_W :: TEXT_W * 2 // 1440
WIN_H :: TEXT_H * 2 + MENU_BAR_H

Host :: struct {
	win:           ^sdl3.Window,
	ren:           ^sdl3.Renderer,
	tex:           ^sdl3.Texture,
	tex_width:     int,
	tex_height:    int,
	aspect_width:  int,
	aspect_height: int,
	has_frame:     bool,
	vsync:         bool, // presents are paced by the display; else the UI loop sleeps
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
	h.vsync = sdl3.SetRenderVSync(h.ren, 1) // never busy-spin the UI loop
	h.tex = sdl3.CreateTexture(h.ren, .ARGB8888, .STREAMING, TEXT_W, TEXT_H)
	if h.tex == nil {
		return false
	}
	sdl3.SetTextureScaleMode(h.tex, .NEAREST)
	h.tex_width = TEXT_W
	h.tex_height = TEXT_H
	h.aspect_width = 4
	h.aspect_height = 3
	return true
}

host_destroy :: proc(h: ^Host) {
	if h.tex != nil {sdl3.DestroyTexture(h.tex)}
	if h.ren != nil {sdl3.DestroyRenderer(h.ren)}
	if h.win != nil {sdl3.DestroyWindow(h.win)}
	sdl3.Quit()
}
