// SPDX-License-Identifier: GPL-3.0-only
package vga

GSW_SURFACE_LIMIT :: 256
GSW_SURFACE_PRESENTABLE :: u32(1 << 0)

Gsw_Surface :: struct {
	id:        u32,
	base:      u32,
	byte_size: u32,
	width:     u32,
	height:    u32,
	pitch:     u32,
	format:    Gsw_Pixel_Format,
	flags:     u32,
}

@(private = "package")
gsw_surface_get :: proc(g: ^Gsw_Vga, id: u32) -> (^Gsw_Surface, bool) {
	if g == nil || id == 0 {return nil, false}
	surface := &g.surfaces[int(id & (GSW_SURFACE_LIMIT - 1))]
	return surface, surface.id == id
}

@(private = "package")
gsw_surface_register :: proc(
	g: ^Gsw_Vga,
	id, base, byte_size, width, height, pitch: u32,
	format: Gsw_Pixel_Format,
	flags: u32,
) -> bool {
	if g == nil || id == 0 || byte_size == 0 || width == 0 || height == 0 ||
	   flags &~ GSW_SURFACE_PRESENTABLE != 0 {
		return false
	}
	bytes := gsw_format_bytes(format)
	if bytes == 0 || base % u32(bytes) != 0 || pitch == 0 || pitch % u32(bytes) != 0 {
		return false
	}
	row_bytes := u64(width) * u64(bytes)
	required := u64(height - 1) * u64(pitch) + row_bytes
	end := u64(base) + u64(byte_size)
	if row_bytes > u64(pitch) || required > u64(byte_size) ||
	   end > u64(len(g.framebuffer)) {
		return false
	}
	slot := &g.surfaces[int(id & (GSW_SURFACE_LIMIT - 1))]
	if slot.id != 0 {return false}
	for &existing in g.surfaces {
		if existing.id == 0 {continue}
		existing_end := u64(existing.base) + u64(existing.byte_size)
		if u64(base) < existing_end && u64(existing.base) < end {return false}
	}
	slot^ = {
		id = id,
		base = base,
		byte_size = byte_size,
		width = width,
		height = height,
		pitch = pitch,
		format = format,
		flags = flags,
	}
	return true
}

@(private = "package")
gsw_surface_unregister :: proc(g: ^Gsw_Vga, id: u32) -> bool {
	surface, ok := gsw_surface_get(g, id)
	if !ok {return false}
	surface^ = {}
	return true
}

@(private = "package")
gsw_surface_reset :: proc(g: ^Gsw_Vga) {
	if g == nil {return}
	for &surface in g.surfaces {surface = {}}
}

@(private = "package")
gsw_registered_surface_rect :: proc(
	g: ^Gsw_Vga,
	surface: ^Gsw_Surface,
	x, y, width, height: u32,
) -> (u64, bool) {
	if g == nil || surface == nil || surface.id == 0 ||
	   x > surface.width || width > surface.width - x ||
	   y > surface.height || height > surface.height - y {
		return 0, false
	}
	start, ok := gsw_surface_rect(
		len(g.framebuffer), surface.base, surface.pitch,
		x, y, width, height, gsw_format_bytes(surface.format),
	)
	if !ok {return 0, false}
	relative := start - u64(surface.base)
	row_bytes := u64(width) * u64(gsw_format_bytes(surface.format))
	last := relative + u64(height - 1) * u64(surface.pitch) + row_bytes
	return start, last <= u64(surface.byte_size)
}
