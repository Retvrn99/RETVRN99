// SPDX-License-Identifier: GPL-3.0-only
package vga

GSW_BLT_V2_COMMAND_BYTES :: 88
GSW_BLT_SRC_COLOR_KEY :: u32(1 << 0)
GSW_BLT_DST_COLOR_KEY :: u32(1 << 1)
GSW_SURFACE_BLT_COMMAND_BYTES :: 76

@(private = "package")
gsw_rop3_supported :: proc(rop: u8) -> bool {
	switch rop {
	case 0x00, 0x11, 0x33, 0x44, 0x55, 0x66, 0x88, 0xBB, 0xCC, 0xEE, 0xFF:
		return true
	}
	return false
}

@(private = "package")
gsw_pixel_mask :: proc(bytes: int) -> u32 {
	switch bytes {
	case 1:
		return 0x0000_00FF
	case 2:
		return 0x0000_FFFF
	case 3:
		return 0x00FF_FFFF
	case 4:
		return 0xFFFF_FFFF
	}
	return 0
}

@(private = "package")
gsw_pixel_read :: proc(data: []u8, offset, bytes: int) -> u32 {
	value: u32
	for i in 0 ..< bytes {value |= u32(data[offset + i]) << (8 * uint(i))}
	return value
}

@(private = "package")
gsw_pixel_write :: proc(data: []u8, offset, bytes: int, value: u32) {
	for i in 0 ..< bytes {data[offset + i] = u8(value >> (8 * uint(i)))}
}

@(private = "package")
gsw_rop3 :: proc(rop: u8, source, destination, pattern, mask: u32) -> u32 {
	result: u32
	for combination in 0 ..< 8 {
		if rop & (u8(1) << uint(combination)) == 0 {continue}
		term := mask
		term &= combination & 1 != 0 ? destination : ~destination
		term &= combination & 2 != 0 ? source : ~source
		term &= combination & 4 != 0 ? pattern : ~pattern
		result |= term
	}
	return result & mask
}

@(private = "package")
gsw_surface_rect :: proc(
	framebuffer_bytes: int,
	base, pitch, x, y, width, height: u32,
	bytes: int,
) -> (
	start: u64,
	ok: bool,
) {
	if bytes <= 0 || width == 0 || height == 0 {return 0, false}
	limit := u64(framebuffer_bytes)
	base_offset := u64(base)
	x_bytes := u64(x) * u64(bytes)
	row_bytes := u64(width) * u64(bytes)
	if base_offset > limit || x_bytes > u64(pitch) || row_bytes > u64(pitch) - x_bytes {
		return 0, false
	}
	y_offset := u64(y) * u64(pitch)
	if y_offset > limit - base_offset {return 0, false}
	start = base_offset + y_offset
	if x_bytes > limit - start {return 0, false}
	start += x_bytes
	last_row := u64(height - 1) * u64(pitch)
	if last_row > limit - start {return 0, false}
	last := start + last_row
	return start, row_bytes <= limit - last
}

@(private = "package")
gsw_vga_execute_blt :: proc(g: ^Gsw_Vga, command: []u8) -> bool {
	if g == nil || len(command) != GSW_BLT_V2_COMMAND_BYTES {return false}
	source_base := gsw_rd32(command, 16)
	destination_base := gsw_rd32(command, 20)
	source_pitch := gsw_rd32(command, 24)
	destination_pitch := gsw_rd32(command, 28)
	source_x := gsw_rd32(command, 32)
	source_y := gsw_rd32(command, 36)
	source_width := gsw_rd32(command, 40)
	source_height := gsw_rd32(command, 44)
	destination_x := gsw_rd32(command, 48)
	destination_y := gsw_rd32(command, 52)
	destination_width := gsw_rd32(command, 56)
	destination_height := gsw_rd32(command, 60)
	source_format := Gsw_Pixel_Format(gsw_rd32(command, 64))
	destination_format := Gsw_Pixel_Format(gsw_rd32(command, 68))
	flags := gsw_rd32(command, 72)
	color_key := gsw_rd32(command, 76)
	pattern := gsw_rd32(command, 80)
	rop_value := gsw_rd32(command, 84)
	bytes := gsw_format_bytes(source_format)
	if source_format != destination_format ||
	   bytes == 0 ||
	   flags &~ GSW_BLT_SRC_COLOR_KEY != 0 ||
	   rop_value > 0xFF {
		return false
	}
	source_start, source_ok := gsw_surface_rect(
		len(g.framebuffer),
		source_base,
		source_pitch,
		source_x,
		source_y,
		source_width,
		source_height,
		bytes,
	)
	destination_start, destination_ok := gsw_surface_rect(
		len(g.framebuffer),
		destination_base,
		destination_pitch,
		destination_x,
		destination_y,
		destination_width,
		destination_height,
		bytes,
	)
	pixel_count := u64(source_width) * u64(source_height)
	destination_pixels := u64(destination_width) * u64(destination_height)
	if !source_ok ||
	   !destination_ok ||
	   pixel_count == 0 ||
	   pixel_count > GSW_VGA_MAX_SOFTWARE_PIXELS ||
	   destination_pixels > GSW_VGA_MAX_SOFTWARE_PIXELS {
		return false
	}

	source_pixels := make([]u32, int(pixel_count))
	defer delete(source_pixels)
	for y in 0 ..< int(source_height) {
		row := source_start + u64(y) * u64(source_pitch)
		for x in 0 ..< int(source_width) {
			offset := int(row + u64(x * bytes))
			source_pixels[y * int(source_width) + x] = gsw_pixel_read(g.framebuffer, offset, bytes)
		}
	}

	mask := gsw_pixel_mask(bytes)
	for y in 0 ..< int(destination_height) {
		source_sample_y := int(u64(y) * u64(source_height) / u64(destination_height))
		destination_row := destination_start + u64(y) * u64(destination_pitch)
		for x in 0 ..< int(destination_width) {
			source_sample_x := int(u64(x) * u64(source_width) / u64(destination_width))
			source := source_pixels[source_sample_y * int(source_width) + source_sample_x] & mask
			if flags & GSW_BLT_SRC_COLOR_KEY != 0 && source == color_key & mask {continue}
			offset := int(destination_row + u64(x * bytes))
			destination := gsw_pixel_read(g.framebuffer, offset, bytes)
			result := gsw_rop3(u8(rop_value), source, destination, pattern, mask)
			gsw_pixel_write(g.framebuffer, offset, bytes, result)
		}
	}
	g.metrics.blits += 1
	g.metrics.software_pixels += u64(destination_width) * u64(destination_height)
	return true
}

@(private = "package")
gsw_vga_execute_surface_blt :: proc(g: ^Gsw_Vga, command: []u8) -> bool {
	if g == nil || len(command) != GSW_SURFACE_BLT_COMMAND_BYTES {return false}
	source_surface, source_found := gsw_surface_get(g, gsw_rd32(command, 16))
	destination_surface, destination_found := gsw_surface_get(g, gsw_rd32(command, 20))
	if !source_found || !destination_found || source_surface.format != destination_surface.format {
		return false
	}
	source_x, source_y := gsw_rd32(command, 24), gsw_rd32(command, 28)
	source_width, source_height := gsw_rd32(command, 32), gsw_rd32(command, 36)
	destination_x, destination_y := gsw_rd32(command, 40), gsw_rd32(command, 44)
	destination_width, destination_height := gsw_rd32(command, 48), gsw_rd32(command, 52)
	flags := gsw_rd32(command, 56)
	source_key := gsw_rd32(command, 60)
	destination_key := gsw_rd32(command, 64)
	pattern := gsw_rd32(command, 68)
	rop_value := gsw_rd32(command, 72)
	if flags &~ (GSW_BLT_SRC_COLOR_KEY | GSW_BLT_DST_COLOR_KEY) != 0 ||
	   rop_value > 0xFF ||
	   !gsw_rop3_supported(u8(rop_value)) {
		return false
	}
	source_start, source_ok := gsw_registered_surface_rect(
		g,
		source_surface,
		source_x,
		source_y,
		source_width,
		source_height,
	)
	destination_start, destination_ok := gsw_registered_surface_rect(
		g,
		destination_surface,
		destination_x,
		destination_y,
		destination_width,
		destination_height,
	)
	source_pixels_count := u64(source_width) * u64(source_height)
	destination_pixels_count := u64(destination_width) * u64(destination_height)
	if !source_ok ||
	   !destination_ok ||
	   source_pixels_count == 0 ||
	   source_pixels_count > GSW_VGA_MAX_SOFTWARE_PIXELS ||
	   destination_pixels_count > GSW_VGA_MAX_SOFTWARE_PIXELS {
		return false
	}

	bytes := gsw_format_bytes(source_surface.format)
	mask := gsw_pixel_mask(bytes)
	source_pixels := make([]u32, int(source_pixels_count))
	defer delete(source_pixels)
	for y in 0 ..< int(source_height) {
		row := source_start + u64(y) * u64(source_surface.pitch)
		for x in 0 ..< int(source_width) {
			offset := int(row + u64(x * bytes))
			source_pixels[y * int(source_width) + x] = gsw_pixel_read(g.framebuffer, offset, bytes)
		}
	}

	for y in 0 ..< int(destination_height) {
		sample_y := int(u64(y) * u64(source_height) / u64(destination_height))
		destination_row := destination_start + u64(y) * u64(destination_surface.pitch)
		for x in 0 ..< int(destination_width) {
			sample_x := int(u64(x) * u64(source_width) / u64(destination_width))
			source := source_pixels[sample_y * int(source_width) + sample_x] & mask
			if flags & GSW_BLT_SRC_COLOR_KEY != 0 && source == source_key & mask {continue}
			offset := int(destination_row + u64(x * bytes))
			destination := gsw_pixel_read(g.framebuffer, offset, bytes)
			if flags & GSW_BLT_DST_COLOR_KEY != 0 &&
			   destination != destination_key & mask {continue}
			result := gsw_rop3(u8(rop_value), source, destination, pattern, mask)
			if result != destination {
				gsw_pixel_write(g.framebuffer, offset, bytes, result)
			}
		}
	}
	g.metrics.blits += 1
	g.metrics.software_pixels += destination_pixels_count
	return true
}
