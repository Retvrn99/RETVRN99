// SPDX-License-Identifier: GPL-3.0-only
package host

import imgui "../../vendor_local/imgui"

win98_color :: proc(color: u32) -> u32 {
	return imgui.ColorConvertFloat4ToU32(theme_color(color))
}

win98_begin_window :: proc(
	name: cstring,
	open: ^bool = nil,
	flags: imgui.WindowFlags = {},
) -> bool {
	imgui.PushStyleColorImVec4(.Text, theme_color(THEME_LIGHT))
	result := imgui.Begin(name, open, flags)
	imgui.PopStyleColor()
	return result
}

win98_begin_popup_modal :: proc(
	name: cstring,
	open: ^bool = nil,
	flags: imgui.WindowFlags = {},
) -> bool {
	imgui.PushStyleColorImVec4(.Text, theme_color(THEME_LIGHT))
	result := imgui.BeginPopupModal(name, open, flags)
	imgui.PopStyleColor()
	return result
}

win98_draw_bevel :: proc(
	draw: ^imgui.DrawList,
	minimum, maximum: imgui.Vec2,
	sunken: bool,
	thickness: f32 = 2,
) {
	if draw == nil || maximum.x <= minimum.x || maximum.y <= minimum.y {return}
	top_left := win98_color(sunken ? THEME_SHADOW : THEME_LIGHT)
	bottom_right := win98_color(sunken ? THEME_LIGHT : THEME_SHADOW)
	inner_top_left := win98_color(sunken ? THEME_DARK : u32(0xFFDFDFDF))
	inner_bottom_right := win98_color(sunken ? u32(0xFFDFDFDF) : THEME_DARK)
	imgui.DrawList_AddLine(draw, minimum, {maximum.x, minimum.y}, top_left, 1)
	imgui.DrawList_AddLine(draw, minimum, {minimum.x, maximum.y}, top_left, 1)
	imgui.DrawList_AddLine(draw, {minimum.x, maximum.y}, maximum, bottom_right, 1)
	imgui.DrawList_AddLine(draw, {maximum.x, minimum.y}, maximum, bottom_right, 1)
	if thickness > 1 {
		inner_min := imgui.Vec2{minimum.x + 1, minimum.y + 1}
		inner_max := imgui.Vec2{maximum.x - 1, maximum.y - 1}
		imgui.DrawList_AddLine(draw, inner_min, {inner_max.x, inner_min.y}, inner_top_left, 1)
		imgui.DrawList_AddLine(draw, inner_min, {inner_min.x, inner_max.y}, inner_top_left, 1)
		imgui.DrawList_AddLine(draw, {inner_min.x, inner_max.y}, inner_max, inner_bottom_right, 1)
		imgui.DrawList_AddLine(draw, {inner_max.x, inner_min.y}, inner_max, inner_bottom_right, 1)
	}
}

win98_texture_ref :: proc(icon: Ui_Icon_Texture) -> imgui.TextureRef {
	if icon.texture == nil {return {}}
	return {_TexID = imgui.TextureID(uintptr(icon.texture))}
}

win98_draw_icon :: proc(
	draw: ^imgui.DrawList,
	icon: Ui_Icon_Texture,
	position: imgui.Vec2,
	size: f32 = 0,
) {
	if draw == nil || icon.texture == nil || icon.width <= 0 || icon.height <= 0 {return}
	draw_width := f32(icon.width)
	draw_height := f32(icon.height)
	if size > 0 {
		scale := min(size / draw_width, size / draw_height)
		draw_width *= scale
		draw_height *= scale
	}
	imgui.DrawList_AddImage(
		draw,
		win98_texture_ref(icon),
		position,
		{position.x + draw_width, position.y + draw_height},
	)
}

win98_icon_button :: proc(id: cstring, icon: Ui_Icon_Texture, size: f32 = 32) -> bool {
	clicked := imgui.InvisibleButton(id, {size + 8, size + 8})
	minimum := imgui.GetItemRectMin()
	maximum := imgui.GetItemRectMax()
	draw := imgui.GetWindowDrawList()
	imgui.DrawList_AddRectFilled(draw, minimum, maximum, win98_color(THEME_FACE))
	win98_draw_bevel(draw, minimum, maximum, imgui.IsItemActive())
	offset := imgui.Vec2{
		minimum.x + (maximum.x - minimum.x - f32(icon.width)) * 0.5,
		minimum.y + (maximum.y - minimum.y - f32(icon.height)) * 0.5,
	}
	win98_draw_icon(draw, icon, offset, size)
	return clicked
}

win98_draw_activity_led :: proc(draw: ^imgui.DrawList, center: imgui.Vec2, active: bool) {
	if draw == nil {return}
	fill := win98_color(active ? MENU_LED_ACTIVE : MENU_LED_IDLE)
	imgui.DrawList_AddCircleFilled(draw, center, 4, fill)
	imgui.DrawList_AddCircle(draw, center, 4, win98_color(THEME_SHADOW), 0, 1)
	imgui.DrawList_AddCircle(draw, {center.x - 1, center.y - 1}, 1, win98_color(active ? u32(0xFF80FF80) : THEME_DARK), 0, 1)
}

win98_status_cell :: proc(text: string, width, height: f32) {
	position := imgui.GetCursorScreenPos()
	imgui.Dummy({width, height})
	draw := imgui.GetWindowDrawList()
	maximum := imgui.Vec2{position.x + width, position.y + height}
	imgui.DrawList_AddRectFilled(draw, position, maximum, win98_color(THEME_FACE))
	win98_draw_bevel(draw, position, maximum, true)
	if len(text) > 0 {
		data := raw_data(text)
		imgui.DrawList_AddText(
			draw,
			{position.x + 5, position.y + (height - f32(THEME_FONT_PX)) * 0.5},
			win98_color(THEME_BLACK),
			cstring(data),
			cstring(data[len(text):]),
		)
	}
}

win98_section_title :: proc(label: string, width: f32) {
	position := imgui.GetCursorScreenPos()
	height := f32(THEME_FONT_PX + 6)
	imgui.Dummy({width, height})
	draw := imgui.GetWindowDrawList()
	maximum := imgui.Vec2{position.x + width, position.y + height}
	imgui.DrawList_AddRectFilled(draw, position, maximum, win98_color(THEME_NAVY))
	if len(label) > 0 {
		data := raw_data(label)
		imgui.DrawList_AddText(
			draw,
			{position.x + 4, position.y + 3},
			win98_color(THEME_LIGHT),
			cstring(data),
			cstring(data[len(label):]),
		)
	}
}
