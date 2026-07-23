// SPDX-License-Identifier: GPL-3.0-only
package vga

GSW_GDI_BLT_COMMAND_BYTES :: 324
GSW_GDI_SOURCE_VALID :: u32(1 << 0)
GSW_GDI_PATTERN_VALID :: u32(1 << 1)
GSW_GDI_DOORBELL_TAIL_FLAG :: u32(1 << 31)
GSW_GDI_DOORBELL_COOKIE_FLAG :: u32(1 << 30)
GSW_GDI_COMPLETION_COOKIE :: u32(0x4753_574F)

@(private = "package")
gsw_gdi_source_dependent :: proc(rop: u8) -> bool {
	return ((rop ~ (rop >> 2)) & 0x33) != 0
}

@(private = "package")
gsw_gdi_pattern_dependent :: proc(rop: u8) -> bool {
	return ((rop ~ (rop >> 4)) & 0x0F) != 0
}

@(private = "package")
gsw_gdi_format_bytes :: proc(format: Gsw_Pixel_Format) -> int {
	#partial switch format {
	case .Indexed_8:
		return 1
	case .Rgb_565:
		return 2
	case .Rgb_888:
		return 3
	case .Xrgb_8888:
		return 4
	}
	return 0
}

@(private = "file")
gsw_gdi_rect :: proc(
	g: ^Gsw_Vga,
	base, pitch, x, y, width, height: u32,
	bytes: int,
) -> (
	start, last: u64,
	ok: bool,
) {
	if g == nil || bytes == 0 || pitch == 0 {
		return 0, 0, false
	}
	rect_start, valid := gsw_surface_rect(
		len(g.framebuffer),
		base,
		pitch,
		x,
		y,
		width,
		height,
		bytes,
	)
	if !valid {return 0, 0, false}
	row_bytes := u64(width) * u64(bytes)
	return rect_start, rect_start + u64(height - 1) * u64(pitch) + row_bytes, true
}

@(private = "file")
gsw_gdi_fill :: proc(
	framebuffer: []u8,
	start: u64,
	pitch, width, height: u32,
	bytes: int,
	color: u32,
) {
	for y in 0 ..< int(height) {
		row := int(start) + y * int(pitch)
		for x in 0 ..< int(width) {
			gsw_pixel_write(framebuffer, row + x * bytes, bytes, color)
		}
	}
}

@(private = "file")
gsw_gdi_copy_rows :: proc(
	framebuffer: []u8,
	source_start, destination_start: u64,
	source_pitch, destination_pitch, width, height: u32,
	bytes: int,
	overlaps: bool,
) {
	row_bytes := int(width) * bytes
	if overlaps && source_pitch != destination_pitch {
		snapshot := make([]u8, row_bytes * int(height))
		defer delete(snapshot)
		for y in 0 ..< int(height) {
			source := int(source_start) + y * int(source_pitch)
			copy(
				snapshot[y * row_bytes:(y + 1) * row_bytes],
				framebuffer[source:source + row_bytes],
			)
		}
		for y in 0 ..< int(height) {
			destination := int(destination_start) + y * int(destination_pitch)
			copy(
				framebuffer[destination:destination + row_bytes],
				snapshot[y * row_bytes:(y + 1) * row_bytes],
			)
		}
		return
	}
	if overlaps && destination_start > source_start {
		for reverse in 0 ..< int(height) {
			y := int(height) - 1 - reverse
			source := int(source_start) + y * int(source_pitch)
			destination := int(destination_start) + y * int(destination_pitch)
			copy(
				framebuffer[destination:destination + row_bytes],
				framebuffer[source:source + row_bytes],
			)
		}
		return
	}
	for y in 0 ..< int(height) {
		source := int(source_start) + y * int(source_pitch)
		destination := int(destination_start) + y * int(destination_pitch)
		copy(
			framebuffer[destination:destination + row_bytes],
			framebuffer[source:source + row_bytes],
		)
	}
}

@(private = "package")
gsw_vga_execute_gdi_blt :: proc(g: ^Gsw_Vga, command: []u8) -> bool {
	if g == nil || len(command) != GSW_GDI_BLT_COMMAND_BYTES {return false}
	source_base := gsw_rd32(command, 16)
	destination_base := gsw_rd32(command, 20)
	source_pitch := gsw_rd32(command, 24)
	destination_pitch := gsw_rd32(command, 28)
	source_x, source_y := gsw_rd32(command, 32), gsw_rd32(command, 36)
	destination_x, destination_y := gsw_rd32(command, 40), gsw_rd32(command, 44)
	width, height := gsw_rd32(command, 48), gsw_rd32(command, 52)
	format := Gsw_Pixel_Format(gsw_rd32(command, 56))
	flags := gsw_rd32(command, 60)
	rop_value := gsw_rd32(command, 64)
	bytes := gsw_gdi_format_bytes(format)
	if bytes == 0 ||
	   flags &~ (GSW_GDI_SOURCE_VALID | GSW_GDI_PATTERN_VALID) != 0 ||
	   rop_value > 0xFF ||
	   width == 0 ||
	   height == 0 ||
	   u64(width) * u64(height) > GSW_VGA_MAX_SOFTWARE_PIXELS {
		return false
	}
	rop := u8(rop_value)
	source_needed := gsw_gdi_source_dependent(rop)
	pattern_needed := gsw_gdi_pattern_dependent(rop)
	if source_needed && flags & GSW_GDI_SOURCE_VALID == 0 ||
	   pattern_needed && flags & GSW_GDI_PATTERN_VALID == 0 {
		return false
	}
	destination_start, _, destination_ok := gsw_gdi_rect(
		g,
		destination_base,
		destination_pitch,
		destination_x,
		destination_y,
		width,
		height,
		bytes,
	)
	if !destination_ok {return false}
	source_start := u64(0)
	if flags & GSW_GDI_SOURCE_VALID != 0 {
		source_ok: bool
		source_start, _, source_ok = gsw_gdi_rect(
			g,
			source_base,
			source_pitch,
			source_x,
			source_y,
			width,
			height,
			bytes,
		)
		if !source_ok {return false}
	}
	mask := gsw_pixel_mask(bytes)
	pattern: [64]u32
	if flags & GSW_GDI_PATTERN_VALID != 0 {
		for &pixel, index in pattern {
			pixel = gsw_rd32(command, 68 + index * 4)
			if pixel &~ mask != 0 {return false}
		}
	}
	if rop == 0xAA {return true}
	overlaps :=
		source_needed &&
		gsw_surface_rows_overlap(
			source_start,
			u64(source_pitch),
			u64(width) * u64(bytes),
			height,
			destination_start,
			u64(destination_pitch),
			u64(width) * u64(bytes),
			height,
		)
	if rop == 0xCC {
		gsw_gdi_copy_rows(
			g.framebuffer,
			source_start,
			destination_start,
			source_pitch,
			destination_pitch,
			width,
			height,
			bytes,
			overlaps,
		)
	} else if rop == 0x00 || rop == 0xFF {
		gsw_gdi_fill(
			g.framebuffer,
			destination_start,
			destination_pitch,
			width,
			height,
			bytes,
			rop == 0x00 ? 0 : mask,
		)
	} else if rop == 0xF0 {
		solid := true
		for index in 1 ..< 64 {
			if pattern[index] != pattern[0] {solid = false; break}
		}
		if solid {
			gsw_gdi_fill(
				g.framebuffer,
				destination_start,
				destination_pitch,
				width,
				height,
				bytes,
				pattern[0],
			)
		} else {
			for y in 0 ..< int(height) {
				destination_row := int(destination_start) + y * int(destination_pitch)
				pattern_y := (int(destination_y) + y) & 7
				for x in 0 ..< int(width) {
					pattern_x := (int(destination_x) + x) & 7
					gsw_pixel_write(
						g.framebuffer,
						destination_row + x * bytes,
						bytes,
						pattern[pattern_y * 8 + pattern_x],
					)
				}
			}
		}
	} else {
		snapshot: []u32
		if source_needed && overlaps {
			snapshot = make([]u32, int(width) * int(height))
			defer delete(snapshot)
			for y in 0 ..< int(height) {
				source_row := int(source_start) + y * int(source_pitch)
				for x in 0 ..< int(width) {
					snapshot[y * int(width) + x] = gsw_pixel_read(
						g.framebuffer,
						source_row + x * bytes,
						bytes,
					)
				}
			}
		}
		for y in 0 ..< int(height) {
			source_row := int(source_start) + y * int(source_pitch)
			destination_row := int(destination_start) + y * int(destination_pitch)
			pattern_y := (int(destination_y) + y) & 7
			for x in 0 ..< int(width) {
				source := u32(0)
				if source_needed {
					source =
						overlaps ? snapshot[y * int(width) + x] : gsw_pixel_read(g.framebuffer, source_row + x * bytes, bytes)
				}
				destination_offset := destination_row + x * bytes
				destination := gsw_pixel_read(g.framebuffer, destination_offset, bytes)
				pattern_pixel := u32(0)
				if pattern_needed {
					pattern_x := (int(destination_x) + x) & 7
					pattern_pixel = pattern[pattern_y * 8 + pattern_x]
				}
				gsw_pixel_write(
					g.framebuffer,
					destination_offset,
					bytes,
					gsw_rop3(rop, source, destination, pattern_pixel, mask),
				)
			}
		}
	}
	g.metrics.blits += 1
	g.metrics.software_pixels += u64(width) * u64(height)
	return true
}
