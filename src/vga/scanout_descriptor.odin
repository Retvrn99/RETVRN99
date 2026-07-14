// SPDX-License-Identifier: GPL-3.0-only
package vga

Scanout_Descriptor :: struct {
	state:        Vga,
	vram:         []u8,
	generation:   u64,
	bytes_copied: int,
}

@(private = "file")
scanout_required_vram :: proc(v: ^Vga) -> int {
	legacy_bytes := LEGACY_PLANE_SIZE * 4
	if !vga_vbe_enabled(v) {return legacy_bytes}
	kind, width, height := display_geometry(v)
	if kind == .Invalid || width <= 0 || height <= 0 {return legacy_bytes}
	bpp := int(v.dispi[DISPI_INDEX_BPP])
	if bpp == 4 {return legacy_bytes}
	bytes_per_pixel := (bpp + 7) / 8
	pitch := vga_vbe_pitch(v)
	x_end := int(v.dispi[DISPI_INDEX_X_OFFSET]) + width
	y_end := int(v.dispi[DISPI_INDEX_Y_OFFSET]) + height
	needed := (y_end - 1) * pitch + x_end * bytes_per_pixel
	return min(max(needed, legacy_bytes), VRAM_SIZE)
}

scanout_descriptor_capture :: proc(descriptor: ^Scanout_Descriptor, source: ^Vga) -> bool {
	if descriptor == nil || source == nil || source.vram == nil {return false}
	if len(descriptor.vram) != VRAM_SIZE {
		if descriptor.vram != nil {delete(descriptor.vram)}
		descriptor.vram = make([]u8, VRAM_SIZE)
	}
	bytes := scanout_required_vram(source)
	copy(descriptor.vram[:bytes], source.vram[:bytes])

	frame_pixels := descriptor.state.frame_pixels
	if descriptor.state.raster_pixels != nil {
		delete(descriptor.state.raster_pixels, descriptor.state.allocator)
	}
	descriptor.state = source^
	descriptor.state.vram = descriptor.vram
	descriptor.state.frame_pixels = frame_pixels
	descriptor.state.frame = {}
	descriptor.state.raster_pixels = nil
	descriptor.state.raster_valid = false
	descriptor.state.raster_fallback = false
	descriptor.state.defer_scanout_conversion = false
	descriptor.state.frame_valid = false
	descriptor.state.full_frame_renders = 0
	descriptor.state.raster_pixels_rendered = 0
	descriptor.generation = source.content_generation
	descriptor.bytes_copied = bytes
	return true
}

scanout_descriptor_render :: proc(descriptor: ^Scanout_Descriptor) -> ^Display_Frame {
	if descriptor == nil || descriptor.vram == nil {return nil}
	return vga_display_frame(&descriptor.state)
}

scanout_descriptor_destroy :: proc(descriptor: ^Scanout_Descriptor) {
	if descriptor == nil {return}
	vram := descriptor.vram
	vga_destroy(&descriptor.state)
	if vram != nil {delete(vram)}
	descriptor^ = {}
}
