// SPDX-License-Identifier: GPL-3.0-only
package host

import imgui "../../vendor_local/imgui"
import "core:testing"
import sdl3 "vendor:sdl3"

@(test)
host_test_theme_layout_invariant :: proc(t: ^testing.T) {
	testing.expect_value(t, MENU_BAR_H, THEME_FONT_PX + THEME_FRAME_PAD_Y * 2)
	testing.expect_value(t, WIN_H, TEXT_H * 2 + MENU_BAR_H)

	r := guest_view_rect(9, 5)
	testing.expect_value(t, r.x, f32(0))
	testing.expect_value(t, r.y, f32(MENU_BAR_H))
	testing.expect_value(t, r.w, f32(TEXT_W * 2))
	testing.expect_value(t, r.h, f32(TEXT_H * 2))
	testing.expect_value(t, int(r.y + r.h), WIN_H)

	r = guest_view_rect(4, 3)
	testing.expect_value(t, int(r.x + 0.5), 187)
	testing.expect_value(t, int(r.y), MENU_BAR_H)
	testing.expect_value(t, int(r.w + 0.5), 1067)
	testing.expect_value(t, int(r.h), TEXT_H * 2)

	r = guest_view_rect(4, 3, 1440, 1080, 0)
	testing.expect_value(t, r, sdl3.FRect{0, 0, 1440, 1080})
}

@(test)
host_test_theme_apply_headless :: proc(t: ^testing.T) {
	ctx := imgui.CreateContext()
	if !testing.expect(t, ctx != nil) {
		return
	}
	defer imgui.DestroyContext(ctx)

	theme_apply()
	io := imgui.GetIO()
	testing.expect(t, io.FontDefault != nil)
	io.IniFilename = nil
	io.DisplaySize = {640, 480}
	io.DeltaTime = 1.0 / 60.0
	io.BackendFlags += {.RendererHasTextures}
	imgui.NewFrame()
	defer imgui.EndFrame()
	style := imgui.GetStyle()
	testing.expect_value(t, style.FontSizeBase, f32(THEME_FONT_PX))
	testing.expect_value(t, style.FontScaleMain, f32(1))
	testing.expect_value(t, style.FontScaleDpi, f32(1))
	testing.expect_value(t, int(imgui.GetFrameHeight()), MENU_BAR_H)
	testing.expect_value(t, style.FramePadding[1], f32(THEME_FRAME_PAD_Y))
	testing.expect_value(t, style.FramePadding[0], f32(THEME_FRAME_PAD_X))
	testing.expect_value(t, style.WindowPadding[0], f32(THEME_WINDOW_PAD_X))
	testing.expect_value(t, style.WindowPadding[1], f32(THEME_WINDOW_PAD_Y))
	testing.expect_value(t, style.WindowRounding, f32(0))
	testing.expect_value(t, style.WindowBorderSize, f32(1))
	testing.expect_value(t, style.PopupBorderSize, f32(1))
	testing.expect_value(t, style.FrameBorderSize, f32(1))
	testing.expect_value(t, style.Colors[imgui.Col.Text], theme_color(THEME_BLACK))
	testing.expect_value(t, style.Colors[imgui.Col.WindowBg], theme_color(THEME_FACE))
	testing.expect_value(t, style.Colors[imgui.Col.HeaderHovered], theme_color(THEME_HIGHLIGHT))
	testing.expect_value(t, style.Colors[imgui.Col.TextSelectedBg].w, f32(0.65))
}
