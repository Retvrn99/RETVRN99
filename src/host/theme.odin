// SPDX-License-Identifier: GPL-3.0-only
package host

import imgui "../../vendor_local/imgui"
import "core:math"

THEME_FONT_PX :: 15
THEME_FRAME_PAD_X :: 7
THEME_FRAME_PAD_Y :: 2
THEME_WINDOW_PAD_X :: 8
THEME_WINDOW_PAD_Y :: 6
THEME_MENU_INSET_X :: 3
THEME_MENU_ITEM_INSET_X :: 5
MENU_BAR_H :: THEME_FONT_PX + THEME_FRAME_PAD_Y * 2

THEME_BLACK :: u32(0xFF000000)
THEME_FACE :: u32(0xFFC0C0C0)
THEME_LIGHT :: u32(0xFFFFFFFF)
THEME_DARK :: u32(0xFF808080)
THEME_SHADOW :: u32(0xFF404040)
THEME_NAVY :: u32(0xFF000080)
THEME_HIGHLIGHT :: u32(0xFFA0A0FF)
THEME_FONT := #load("../../assets/font/libre-franklin.ttf")

theme_color :: proc(argb: u32) -> imgui.Vec4 {
	return {
		f32((argb >> 16) & 0xFF) / 255.0,
		f32((argb >> 8) & 0xFF) / 255.0,
		f32(argb & 0xFF) / 255.0,
		f32((argb >> 24) & 0xFF) / 255.0,
	}
}

// Applies a compact Windows 9x-inspired host UI with Libre Franklin.
// Call once after imgui.CreateContext and before the first frame.
theme_apply :: proc() {
	io := imgui.GetIO()
	font_config := imgui.FontConfig {
		FontDataOwnedByAtlas = false,
		GlyphMaxAdvanceX     = math.F32_MAX,
		RasterizerMultiply   = 1,
		RasterizerDensity    = 1,
		ExtraSizeScale       = 1,
	}
	if font := imgui.FontAtlas_AddFontFromMemoryTTF(
		io.Fonts,
		raw_data(THEME_FONT),
		i32(len(THEME_FONT)),
		f32(THEME_FONT_PX),
		&font_config,
	); font != nil {
		io.FontDefault = font
	}
	style := imgui.GetStyle()
	style.FontSizeBase = f32(THEME_FONT_PX)
	style.FontScaleMain = 1
	style.FontScaleDpi = 1
	style.WindowPadding = {THEME_WINDOW_PAD_X, THEME_WINDOW_PAD_Y}
	style.WindowRounding = 0
	style.WindowBorderSize = 1
	style.WindowTitleAlign = {0, 0.5}
	style.ChildRounding = 0
	style.ChildBorderSize = 1
	style.PopupRounding = 0
	style.PopupBorderSize = 1
	style.FramePadding = {THEME_FRAME_PAD_X, THEME_FRAME_PAD_Y}
	style.FrameRounding = 0
	style.FrameBorderSize = 1
	style.ItemSpacing = {8, 3}
	style.ItemInnerSpacing = {6, 2}
	style.CellPadding = {4, 2}
	style.IndentSpacing = 16
	style.ScrollbarSize = 16
	style.ScrollbarRounding = 0
	style.GrabMinSize = 8
	style.GrabRounding = 0
	style.ImageRounding = 0
	style.ImageBorderSize = 1
	style.TabRounding = 0
	style.TabBorderSize = 1
	style.TabBarBorderSize = 1
	style.ButtonTextAlign = {0.5, 0.5}
	style.SelectableTextAlign = {0, 0.5}
	style.SeparatorSize = 1

	face := theme_color(THEME_FACE)
	for i in 0 ..< int(imgui.Col.COUNT) {
		style.Colors[i] = face
	}

	black := theme_color(THEME_BLACK)
	light := theme_color(THEME_LIGHT)
	dark := theme_color(THEME_DARK)
	shadow := theme_color(THEME_SHADOW)
	navy := theme_color(THEME_NAVY)
	highlight := theme_color(THEME_HIGHLIGHT)
	transparent := imgui.Vec4{0, 0, 0, 0}

	style.Colors[imgui.Col.Text] = black
	style.Colors[imgui.Col.TextDisabled] = dark
	style.Colors[imgui.Col.WindowBg] = face
	style.Colors[imgui.Col.ChildBg] = face
	style.Colors[imgui.Col.PopupBg] = face
	style.Colors[imgui.Col.Border] = dark
	style.Colors[imgui.Col.BorderShadow] = transparent
	style.Colors[imgui.Col.FrameBg] = light
	style.Colors[imgui.Col.FrameBgHovered] = face
	style.Colors[imgui.Col.FrameBgActive] = dark
	style.Colors[imgui.Col.TitleBg] = dark
	style.Colors[imgui.Col.TitleBgActive] = highlight
	style.Colors[imgui.Col.TitleBgCollapsed] = dark
	style.Colors[imgui.Col.MenuBarBg] = face
	style.Colors[imgui.Col.ScrollbarBg] = light
	style.Colors[imgui.Col.ScrollbarGrab] = face
	style.Colors[imgui.Col.ScrollbarGrabHovered] = dark
	style.Colors[imgui.Col.ScrollbarGrabActive] = shadow
	style.Colors[imgui.Col.CheckMark] = black
	style.Colors[imgui.Col.CheckboxSelectedBg] = highlight
	style.Colors[imgui.Col.SliderGrab] = dark
	style.Colors[imgui.Col.SliderGrabActive] = shadow
	style.Colors[imgui.Col.Button] = face
	style.Colors[imgui.Col.ButtonHovered] = light
	style.Colors[imgui.Col.ButtonActive] = dark
	style.Colors[imgui.Col.Header] = face
	style.Colors[imgui.Col.HeaderHovered] = highlight
	style.Colors[imgui.Col.HeaderActive] = highlight
	style.Colors[imgui.Col.Separator] = dark
	style.Colors[imgui.Col.SeparatorHovered] = navy
	style.Colors[imgui.Col.SeparatorActive] = navy
	style.Colors[imgui.Col.ResizeGrip] = face
	style.Colors[imgui.Col.ResizeGripHovered] = dark
	style.Colors[imgui.Col.ResizeGripActive] = shadow
	style.Colors[imgui.Col.InputTextCursor] = black
	style.Colors[imgui.Col.Tab] = face
	style.Colors[imgui.Col.TabHovered] = light
	style.Colors[imgui.Col.TabSelected] = dark
	style.Colors[imgui.Col.TabSelectedOverline] = navy
	style.Colors[imgui.Col.TabDimmed] = face
	style.Colors[imgui.Col.TabDimmedSelected] = dark
	style.Colors[imgui.Col.TabDimmedSelectedOverline] = dark
	style.Colors[imgui.Col.TableHeaderBg] = face
	style.Colors[imgui.Col.TableBorderStrong] = dark
	style.Colors[imgui.Col.TableBorderLight] = dark
	style.Colors[imgui.Col.TableRowBg] = light
	style.Colors[imgui.Col.TableRowBgAlt] = face
	style.Colors[imgui.Col.TextLink] = navy
	style.Colors[imgui.Col.TextSelectedBg] = {highlight.x, highlight.y, highlight.z, 0.65}
	style.Colors[imgui.Col.TreeLines] = dark
	style.Colors[imgui.Col.DragDropTarget] = navy
	style.Colors[imgui.Col.DragDropTargetBg] = transparent
	style.Colors[imgui.Col.UnsavedMarker] = navy
	style.Colors[imgui.Col.NavCursor] = navy
	style.Colors[imgui.Col.NavWindowingHighlight] = navy
	style.Colors[imgui.Col.NavWindowingDimBg] = {0, 0, 0, 0.2}
	style.Colors[imgui.Col.ModalWindowDimBg] = {0, 0, 0, 0.35}
}
