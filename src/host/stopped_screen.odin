// SPDX-License-Identifier: GPL-3.0-only
package host

import sdl3 "vendor:sdl3"

STOPPED_SCREEN_LOGO_PNG := #load("../../assets/logo.png")
STOPPED_SCREEN_LOGO_MARGIN :: f32(24)
STOPPED_SCREEN_REFERENCE_WIDTH :: f32(TEXT_W * DEFAULT_WINDOW_SCALE)
STOPPED_SCREEN_REFERENCE_HEIGHT :: f32(TEXT_H * DEFAULT_WINDOW_SCALE)

stopped_screen_rect :: proc(
	output_width, output_height: int,
	insets: Host_Client_Insets,
) -> sdl3.FRect {
	width := f32(max(1, output_width))
	height := f32(max(1, output_height))
	left := clamp(insets.left, f32(0), width - 1)
	top := clamp(insets.top, f32(0), height - 1)
	right := clamp(insets.right, f32(0), width - left - 1)
	bottom := clamp(insets.bottom, f32(0), height - top - 1)
	return {left, top, width - left - right, height - top - bottom}
}

stopped_logo_rect :: proc(screen: sdl3.FRect, logo_width, logo_height: int) -> sdl3.FRect {
	if screen.w <= 0 || screen.h <= 0 || logo_width <= 0 || logo_height <= 0 {return {}}
	scale := min(
		screen.w / STOPPED_SCREEN_REFERENCE_WIDTH,
		screen.h / STOPPED_SCREEN_REFERENCE_HEIGHT,
	)
	margin := STOPPED_SCREEN_LOGO_MARGIN * scale
	draw_width := f32(logo_width) * scale
	draw_height := f32(logo_height) * scale
	available_width := max(f32(1), screen.w - margin * 2)
	available_height := max(f32(1), screen.h - margin * 2)
	fit := min(f32(1), available_width / draw_width, available_height / draw_height)
	draw_width *= fit
	draw_height *= fit
	return {
		screen.x + screen.w - margin - draw_width,
		screen.y + screen.h - margin - draw_height,
		draw_width,
		draw_height,
	}
}

stopped_screen_init :: proc(h: ^Host) -> bool {
	if h == nil || h.ren == nil {return false}
	logo, ok := ui_icon_texture_load(h.ren, STOPPED_SCREEN_LOGO_PNG)
	if !ok {return false}
	if !sdl3.SetTextureScaleMode(logo.texture, .LINEAR) {
		ui_icon_texture_destroy(&logo)
		return false
	}
	h.stopped_logo = logo
	return true
}

stopped_screen_destroy :: proc(h: ^Host) {
	if h == nil {return}
	ui_icon_texture_destroy(&h.stopped_logo)
}

host_render_stopped_screen :: proc(h: ^Host, output_width, output_height: int) {
	if h == nil || h.ren == nil {return}
	screen := stopped_screen_rect(output_width, output_height, host_client_insets(h))
	sdl3.SetRenderDrawColor(h.ren, 255, 255, 255, 255)
	_ = sdl3.RenderFillRect(h.ren, &screen)
	if h.stopped_logo.texture == nil {return}
	destination := stopped_logo_rect(screen, h.stopped_logo.width, h.stopped_logo.height)
	_ = sdl3.RenderTexture(h.ren, h.stopped_logo.texture, nil, &destination)
}
