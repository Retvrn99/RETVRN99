// SPDX-License-Identifier: GPL-3.0-only
package host

import contract "../presentation"
import vga "../vga"
import "core:c"
import sdl3 "vendor:sdl3"

Host_Presentation_Resource_Shadow :: struct {
	pixels:               []u32,
	width:                int,
	height:               int,
	valid:                bool,
	kind:                 Host_Presentation_Kind,
	lifecycle_generation: u64,
	mode_generation:      u64,
	identity_namespace:   contract.Identity_Namespace,
	device_generation:    u64,
	surface:              contract.Surface_Identity,
	format:               contract.Pixel_Format,
	source_kind:          contract.Source_Kind,
}

Host_Presentation_Upload_Plan :: struct {
	valid:   bool,
	full:    bool,
	rects:   contract.Rect_Set,
	pixels:  u64,
	bytes:   u64,
	regions: u64,
}

Host_Presentation_Texture_Write_Rect_Proc :: proc(
	ctx: rawptr,
	texture: ^sdl3.Texture,
	shadow: ^Host_Presentation_Resource_Shadow,
	rect: contract.Rect,
) -> bool

Host_Presentation_Texture_Create_Proc :: proc(ctx: rawptr, width, height: int) -> ^sdl3.Texture

Host_Presentation_Texture_Destroy_Proc :: proc(ctx: rawptr, texture: ^sdl3.Texture)

Host_Presentation_Upload_Ops :: struct {
	ctx:             rawptr,
	create_texture:  Host_Presentation_Texture_Create_Proc,
	write_rect:      Host_Presentation_Texture_Write_Rect_Proc,
	destroy_texture: Host_Presentation_Texture_Destroy_Proc,
}

host_presentation_upload_plan :: proc(
	frame: ^vga.Display_Frame,
	header: contract.Header,
) -> Host_Presentation_Upload_Plan {
	if frame == nil ||
	   frame.width <= 0 ||
	   frame.height <= 0 ||
	   frame.width > max(int) / frame.height ||
	   u64(frame.width) != u64(header.surface_extent.width) ||
	   u64(frame.height) != u64(header.surface_extent.height) ||
	   len(frame.pixels) < frame.width * frame.height {return {}}
	rects, result := contract.rect_set_canonicalize(header.dirty, header.surface_extent)
	if result != .Exact || !contract.rect_set_equal(rects, header.dirty) {return {}}
	if !contract.rect_set_equal(frame.dirty, rects) {return {}}
	pixels: u64
	for i in 0 ..< int(rects.count) {
		rect := rects.rects[i]
		area := u64(rect.width) * u64(rect.height)
		if area > max(u64) - pixels {return {}}
		pixels += area
	}
	if pixels > max(u64) / size_of(u32) {return {}}
	if frame.updated_pixels != pixels {return {}}
	return {
		valid = true,
		full = rects.count == 1 && contract.rect_equal(rects.rects[0], header.source),
		rects = rects,
		pixels = pixels,
		bytes = pixels * size_of(u32),
		regions = u64(rects.count),
	}
}

host_presentation_resource_identity_equal :: proc(
	kind: Host_Presentation_Kind,
	a, b: contract.Header,
) -> bool {
	return(
		kind != .Invalid &&
		a.lifecycle_generation == b.lifecycle_generation &&
		a.mode_generation == b.mode_generation &&
		contract.mode_key_equal(a.mode_key, b.mode_key) &&
		a.identity_namespace == b.identity_namespace &&
		a.device_generation == b.device_generation &&
		contract.surface_identity_equal(a.surface, b.surface) &&
		a.format == b.format &&
		a.surface_extent == b.surface_extent &&
		a.source_kind == b.source_kind \
	)
}

host_presentation_shadow_matches :: proc(
	shadow: ^Host_Presentation_Resource_Shadow,
	kind: Host_Presentation_Kind,
	header: contract.Header,
) -> bool {
	if shadow == nil || !shadow.valid {return false}
	return(
		shadow.kind == kind &&
		shadow.lifecycle_generation == header.lifecycle_generation &&
		shadow.mode_generation == header.mode_generation &&
		shadow.identity_namespace == header.identity_namespace &&
		shadow.device_generation == header.device_generation &&
		contract.surface_identity_equal(shadow.surface, header.surface) &&
		shadow.format == header.format &&
		shadow.source_kind == header.source_kind &&
		shadow.width == int(header.surface_extent.width) &&
		shadow.height == int(header.surface_extent.height) \
	)
}

host_presentation_shadow_apply :: proc(
	shadow: ^Host_Presentation_Resource_Shadow,
	kind: Host_Presentation_Kind,
	header: contract.Header,
	frame: ^vga.Display_Frame,
	plan: Host_Presentation_Upload_Plan,
) -> bool {
	if shadow == nil || frame == nil || !plan.valid {return false}
	needed := frame.width * frame.height
	matched := host_presentation_shadow_matches(shadow, kind, header)
	if !matched && !plan.full {return false}
	if len(shadow.pixels) != needed {
		if shadow.pixels != nil {delete(shadow.pixels)}
		shadow.pixels = make([]u32, needed)
	}
	if !matched || plan.full {
		copy(shadow.pixels, frame.pixels[:needed])
	} else {
		for rect_index in 0 ..< int(plan.rects.count) {
			rect := plan.rects.rects[rect_index]
			for y in int(rect.y) ..< int(rect.y + rect.height) {
				start := y * frame.width + int(rect.x)
				end := start + int(rect.width)
				copy(shadow.pixels[start:end], frame.pixels[start:end])
			}
		}
	}
	shadow.width = frame.width
	shadow.height = frame.height
	shadow.valid = true
	shadow.kind = kind
	shadow.lifecycle_generation = header.lifecycle_generation
	shadow.mode_generation = header.mode_generation
	shadow.identity_namespace = header.identity_namespace
	shadow.device_generation = header.device_generation
	shadow.surface = header.surface
	shadow.format = header.format
	shadow.source_kind = header.source_kind
	return true
}

host_presentation_texture_write_rect :: proc(
	texture: ^sdl3.Texture,
	shadow: ^Host_Presentation_Resource_Shadow,
	rect: contract.Rect,
) -> bool {
	if texture == nil ||
	   shadow == nil ||
	   !shadow.valid ||
	   rect.x > u32(max(i32)) ||
	   rect.y > u32(max(i32)) ||
	   rect.width > u32(max(i32)) ||
	   rect.height > u32(max(i32)) {return false}
	sdl_rect := sdl3.Rect{i32(rect.x), i32(rect.y), i32(rect.width), i32(rect.height)}
	raw: rawptr
	pitch: c.int
	if !sdl3.LockTexture(texture, &sdl_rect, &raw, &pitch) {return false}
	defer sdl3.UnlockTexture(texture)
	row_bytes := int(rect.width) * size_of(u32)
	if raw == nil || int(pitch) < row_bytes || int(pitch) % size_of(u32) != 0 {return false}
	pitch_pixels := int(pitch) / size_of(u32)
	destination := ([^]u32)(raw)[:pitch_pixels * int(rect.height)]
	for row in 0 ..< int(rect.height) {
		source_start := (int(rect.y) + row) * shadow.width + int(rect.x)
		copy(
			destination[row * pitch_pixels:][:int(rect.width)],
			shadow.pixels[source_start:][:int(rect.width)],
		)
	}
	return true
}

@(private = "package")
host_presentation_upload_ops_valid :: proc(ops: ^Host_Presentation_Upload_Ops) -> bool {
	return ops == nil || (ops.write_rect != nil && ops.destroy_texture != nil)
}

@(private = "package")
host_presentation_upload_create_texture :: proc(
	ops: ^Host_Presentation_Upload_Ops,
	h: ^Host,
	width, height: int,
) -> ^sdl3.Texture {
	if h == nil || width <= 0 || height <= 0 {return nil}
	if ops != nil {
		if ops.create_texture == nil {return nil}
		return ops.create_texture(ops.ctx, width, height)
	}
	texture := sdl3.CreateTexture(h.ren, .ARGB8888, .STREAMING, i32(width), i32(height))
	if texture != nil {
		_ = sdl3.SetTextureScaleMode(texture, h.visual_shader == .None ? .NEAREST : .LINEAR)
	}
	return texture
}

@(private = "package")
host_presentation_upload_write_rect :: proc(
	ops: ^Host_Presentation_Upload_Ops,
	texture: ^sdl3.Texture,
	shadow: ^Host_Presentation_Resource_Shadow,
	rect: contract.Rect,
) -> bool {
	if ops == nil {return host_presentation_texture_write_rect(texture, shadow, rect)}
	if ops.write_rect == nil {return false}
	return ops.write_rect(ops.ctx, texture, shadow, rect)
}

@(private = "package")
host_presentation_upload_destroy_texture :: proc(
	ops: ^Host_Presentation_Upload_Ops,
	texture: ^sdl3.Texture,
) -> bool {
	if texture == nil {return false}
	if ops == nil {
		sdl3.DestroyTexture(texture)
		return true
	}
	if ops.destroy_texture == nil {return false}
	ops.destroy_texture(ops.ctx, texture)
	return true
}
