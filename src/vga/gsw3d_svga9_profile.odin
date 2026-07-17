// SPDX-License-Identifier: GPL-3.0-only
package vga

GSW3D_SVGA9_PROFILE_CONTEXT_ID :: u32(1)
GSW3D_SVGA9_PROFILE_TARGET_ID :: u32(1)
GSW3D_SVGA9_PROFILE_BUFFER_ID :: u32(2)
GSW3D_SVGA9_PROFILE_TARGET_FORMAT :: u32(1)
GSW3D_SVGA9_PROFILE_BUFFER_FORMAT :: u32(37)
GSW3D_SVGA9_PROFILE_VERTEX_BYTES :: u32(60)
GSW3D_SVGA9_PROFILE_MAX_DIMENSION :: u32(8192)
GSW3D_SVGA9_PROFILE_MAX_SURFACE_BYTES :: u64(256 * 1024 * 1024)

Gsw3d_Svga9_Profile_Kind :: enum u8 {
	Invalid,
	Define,
	Render,
	Destroy,
}

Gsw3d_Svga9_Profile_Command :: struct {
	kind:      Gsw3d_Svga9_Profile_Kind,
	width:     u32,
	height:    u32,
	clear:     u32,
	destroyed: [2]bool,
}

gsw3d_svga9_profile_extent_valid :: proc(width, height: u32) -> bool {
	if width == 0 ||
	   height == 0 ||
	   width > GSW3D_SVGA9_PROFILE_MAX_DIMENSION ||
	   height > GSW3D_SVGA9_PROFILE_MAX_DIMENSION {return false}
	pixels := u64(width) * u64(height)
	return pixels <= GSW3D_SVGA9_PROFILE_MAX_SURFACE_BYTES / 4
}

@(private = "file")
gsw3d_svga9_profile_words_equal :: proc(data: []u8, offset: int, expected: []u32) -> bool {
	if offset < 0 || offset > len(data) || len(expected) > (len(data) - offset) / 4 {
		return false
	}
	for wanted, index in expected {
		if gsw_rd32(data, offset + index * 4) != wanted {return false}
	}
	return true
}

@(private = "file")
gsw3d_svga9_profile_header :: proc(data: []u8, offset: int, opcode, body_size: u32) -> bool {
	if offset < 0 || offset > len(data) || len(data) - offset < 8 + int(body_size) {
		return false
	}
	return gsw3d_svga9_profile_words_equal(data, offset, []u32{opcode, body_size})
}

@(private = "file")
gsw3d_svga9_profile_define :: proc(batch: []u8) -> (Gsw3d_Svga9_Profile_Command, bool) {
	if len(batch) != 128 ||
	   !gsw3d_svga9_profile_header(batch, 0, 1070, 56) ||
	   !gsw3d_svga9_profile_header(batch, 64, 1070, 56) {return {}, false}

	width := gsw_rd32(batch, 52)
	height := gsw_rd32(batch, 56)
	if !gsw3d_svga9_profile_extent_valid(width, height) {return {}, false}
	target := [?]u32 {
		GSW3D_SVGA9_PROFILE_TARGET_ID,
		0x40,
		GSW3D_SVGA9_PROFILE_TARGET_FORMAT,
		1,
		0,
		0,
		0,
		0,
		0,
		0,
		0,
		width,
		height,
		1,
	}
	buffer := [?]u32 {
		GSW3D_SVGA9_PROFILE_BUFFER_ID,
		0x12,
		GSW3D_SVGA9_PROFILE_BUFFER_FORMAT,
		1,
		0,
		0,
		0,
		0,
		0,
		0,
		0,
		GSW3D_SVGA9_PROFILE_VERTEX_BYTES,
		1,
		1,
	}
	if !gsw3d_svga9_profile_words_equal(batch, 8, target[:]) ||
	   !gsw3d_svga9_profile_words_equal(batch, 72, buffer[:]) {return {}, false}
	return {kind = .Define, width = width, height = height}, true
}

@(private = "file")
gsw3d_svga9_profile_render :: proc(batch: []u8) -> (Gsw3d_Svga9_Profile_Command, bool) {
	if len(batch) != 360 {return {}, false}
	headers := [?][3]u32 {
		{0, 1050, 20},
		{28, 1055, 20},
		{56, 1049, 60},
		{124, 1051, 64},
		{196, 1057, 36},
		{240, 1063, 112},
	}
	for header in headers {
		if !gsw3d_svga9_profile_header(batch, int(header[0]), header[1], header[2]) {
			return {}, false
		}
	}

	width := gsw_rd32(batch, 48)
	height := gsw_rd32(batch, 52)
	if !gsw3d_svga9_profile_extent_valid(width, height) {return {}, false}
	render_target := [?]u32{GSW3D_SVGA9_PROFILE_CONTEXT_ID, 2, GSW3D_SVGA9_PROFILE_TARGET_ID, 0, 0}
	viewport := [?]u32{GSW3D_SVGA9_PROFILE_CONTEXT_ID, 0, 0, width, height}
	render_states := [?]u32 {
		GSW3D_SVGA9_PROFILE_CONTEXT_ID,
		1,
		0,
		2,
		0,
		5,
		0,
		9,
		0,
		35,
		1,
		47,
		15,
		30,
		2,
	}
	texture_states := [?]u32 {
		GSW3D_SVGA9_PROFILE_CONTEXT_ID,
		0,
		1,
		0xffff_ffff,
		0,
		2,
		2,
		0,
		3,
		3,
		0,
		5,
		2,
		0,
		6,
		3,
	}
	clear_color := gsw_rd32(batch, 212)
	clear := [?]u32 {
		GSW3D_SVGA9_PROFILE_CONTEXT_ID,
		1,
		clear_color,
		0x3f80_0000,
		0,
		0,
		0,
		width,
		height,
	}
	draw := [?]u32 {
		GSW3D_SVGA9_PROFILE_CONTEXT_ID,
		2,
		1,
		3,
		0,
		9,
		0,
		GSW3D_SVGA9_PROFILE_BUFFER_ID,
		0,
		20,
		0,
		0,
		4,
		0,
		10,
		0,
		GSW3D_SVGA9_PROFILE_BUFFER_ID,
		16,
		20,
		0,
		0,
		1,
		1,
		0xffff_ffff,
		0,
		0,
		0,
		0,
	}
	if !gsw3d_svga9_profile_words_equal(batch, 8, render_target[:]) ||
	   !gsw3d_svga9_profile_words_equal(batch, 36, viewport[:]) ||
	   !gsw3d_svga9_profile_words_equal(batch, 64, render_states[:]) ||
	   !gsw3d_svga9_profile_words_equal(batch, 132, texture_states[:]) ||
	   !gsw3d_svga9_profile_words_equal(batch, 204, clear[:]) ||
	   !gsw3d_svga9_profile_words_equal(batch, 248, draw[:]) {return {}, false}
	return {kind = .Render, width = width, height = height, clear = clear_color | 0xff00_0000},
		true
}

@(private = "file")
gsw3d_svga9_profile_destroy :: proc(batch: []u8) -> (Gsw3d_Svga9_Profile_Command, bool) {
	if len(batch) != 12 && len(batch) != 24 {return {}, false}
	destroyed: [2]bool
	for offset := 0; offset < len(batch); offset += 12 {
		if !gsw3d_svga9_profile_header(batch, offset, 1041, 4) {return {}, false}
		id := gsw_rd32(batch, offset + 8)
		if id < GSW3D_SVGA9_PROFILE_TARGET_ID || id > GSW3D_SVGA9_PROFILE_BUFFER_ID {
			return {}, false
		}
		index := int(id - GSW3D_SVGA9_PROFILE_TARGET_ID)
		if destroyed[index] {return {}, false}
		destroyed[index] = true
	}
	return {kind = .Destroy, destroyed = destroyed}, true
}

gsw3d_svga9_profile_parse :: proc(batch: []u8) -> (Gsw3d_Svga9_Profile_Command, bool) {
	switch len(batch) {
	case 128:
		return gsw3d_svga9_profile_define(batch)
	case 360:
		return gsw3d_svga9_profile_render(batch)
	case 12, 24:
		return gsw3d_svga9_profile_destroy(batch)
	}
	return {}, false
}
