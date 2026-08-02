// SPDX-License-Identifier: GPL-3.0-only
package vga

import "core:testing"

gsw2d_test_register :: proc(
	t: ^testing.T,
	g: ^Gsw_Vga,
	id, base, width, height, pitch: u32,
	format: Gsw_Pixel_Format,
	flags: u32 = 0,
) {
	bytes := u32(gsw_format_bytes(format))
	byte_size := (height - 1) * pitch + width * bytes
	testing.expect(t, gsw_surface_register(g, id, base, byte_size, width, height, pitch, format, flags))
}

gsw2d_test_blt_command :: proc(
	command: []u8,
	source_id, destination_id: u32,
	source_x, source_y, source_width, source_height: u32,
	destination_x, destination_y, destination_width, destination_height: u32,
	flags, source_key, destination_key, pattern, rop3: u32,
) {
	gsw_test_wr32(command, 16, source_id)
	gsw_test_wr32(command, 20, destination_id)
	gsw_test_wr32(command, 24, source_x)
	gsw_test_wr32(command, 28, source_y)
	gsw_test_wr32(command, 32, source_width)
	gsw_test_wr32(command, 36, source_height)
	gsw_test_wr32(command, 40, destination_x)
	gsw_test_wr32(command, 44, destination_y)
	gsw_test_wr32(command, 48, destination_width)
	gsw_test_wr32(command, 52, destination_height)
	gsw_test_wr32(command, 56, flags)
	gsw_test_wr32(command, 60, source_key)
	gsw_test_wr32(command, 64, destination_key)
	gsw_test_wr32(command, 68, pattern)
	gsw_test_wr32(command, 72, rop3)
}

gsw2d_test_rop3 :: proc(rop: u8, source, destination, pattern: u8) -> u8 {
	result: u8
	for combination in 0 ..< 8 {
		if rop & (u8(1) << uint(combination)) == 0 {continue}
		term := u8(0xFF)
		term &= combination & 1 != 0 ? destination : ~destination
		term &= combination & 2 != 0 ? source : ~source
		term &= combination & 4 != 0 ? pattern : ~pattern
		result |= term
	}
	return result
}

@(test)
gsw2d_registered_surfaces_cover_supported_formats_and_padded_pitch :: proc(t: ^testing.T) {
	formats := []Gsw_Pixel_Format{.Indexed_8, .Rgb_555, .Rgb_565, .Rgb_888, .Xrgb_8888}
	for format, index in formats {
		framebuffer: [512]u8
		g: Gsw_Vga
		gsw_vga_init(&g, framebuffer[:])
		defer gsw_vga_destroy(&g)
		bytes := gsw_format_bytes(format)
		pitch := u32(3 * bytes + 5 * bytes)
		base := u32(16 * bytes)
		gsw2d_test_register(t, &g, u32(0x100 + index), base, 3, 2, pitch, format)
		surface, ok := gsw_surface_get(&g, u32(0x100 + index))
		testing.expect(t, ok)
		testing.expect_value(t, surface.base, base)
		testing.expect_value(t, surface.pitch, pitch)
	}
}

@(test)
gsw2d_registration_rejects_overlap_alignment_and_overflow :: proc(t: ^testing.T) {
	framebuffer: [256]u8
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer[:])
	defer gsw_vga_destroy(&g)
	testing.expect(t, gsw_surface_register(&g, 1, 32, 64, 4, 4, 16, .Xrgb_8888, 0))
	testing.expect(t, !gsw_surface_register(&g, 2, 48, 32, 4, 2, 16, .Xrgb_8888, 0))
	testing.expect(t, !gsw_surface_register(&g, 3, 33, 16, 2, 2, 8, .Xrgb_8888, 0))
	testing.expect(t, !gsw_surface_register(&g, 4, 240, 32, 2, 2, 16, .Xrgb_8888, 0))
	testing.expect(t, !gsw_surface_register(&g, 5, 128, 16, 5, 1, 16, .Xrgb_8888, 0))
}

@(test)
gsw2d_same_surface_copy_uses_overlap_safe_snapshot :: proc(t: ^testing.T) {
	framebuffer: [128]u8
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer[:])
	defer gsw_vga_destroy(&g)
	gsw2d_test_register(t, &g, 1, 16, 4, 1, 8, .Indexed_8)
	framebuffer[16], framebuffer[17], framebuffer[18], framebuffer[19] = 1, 2, 3, 4
	command: [GSW_SURFACE_BLT_COMMAND_BYTES]u8
	gsw2d_test_blt_command(command[:], 1, 1, 0, 0, 3, 1, 1, 0, 3, 1, 0, 0, 0, 0, 0xCC)
	testing.expect(t, gsw_vga_execute_surface_blt(&g, command[:]))
	testing.expect_value(t, framebuffer[16], u8(1))
	testing.expect_value(t, framebuffer[17], u8(1))
	testing.expect_value(t, framebuffer[18], u8(2))
	testing.expect_value(t, framebuffer[19], u8(3))
}

@(test)
gsw2d_stretch_and_both_color_keys_are_exact :: proc(t: ^testing.T) {
	framebuffer: [256]u8
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer[:])
	defer gsw_vga_destroy(&g)
	gsw2d_test_register(t, &g, 1, 16, 2, 1, 4, .Indexed_8)
	gsw2d_test_register(t, &g, 2, 64, 4, 1, 8, .Indexed_8)
	framebuffer[16], framebuffer[17] = 7, 9
	framebuffer[64], framebuffer[65], framebuffer[66], framebuffer[67] = 3, 4, 3, 4
	command: [GSW_SURFACE_BLT_COMMAND_BYTES]u8
	gsw2d_test_blt_command(command[:], 1, 2, 0, 0, 2, 1, 0, 0, 4, 1,
		GSW_BLT_SRC_COLOR_KEY | GSW_BLT_DST_COLOR_KEY, 7, 3, 0, 0xCC)
	testing.expect(t, gsw_vga_execute_surface_blt(&g, command[:]))
	testing.expect_value(t, framebuffer[64], u8(3))
	testing.expect_value(t, framebuffer[65], u8(4))
	testing.expect_value(t, framebuffer[66], u8(9))
	testing.expect_value(t, framebuffer[67], u8(4))
}

@(test)
gsw2d_rejects_invalid_ids_rectangles_flags_and_rops_without_writes :: proc(t: ^testing.T) {
	framebuffer: [256]u8
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer[:])
	defer gsw_vga_destroy(&g)
	gsw2d_test_register(t, &g, 1, 16, 2, 2, 4, .Indexed_8)
	gsw2d_test_register(t, &g, 2, 64, 2, 2, 4, .Indexed_8)
	before := framebuffer
	command: [GSW_SURFACE_BLT_COMMAND_BYTES]u8
	gsw2d_test_blt_command(command[:], 9, 2, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 0, 0, 0xCC)
	testing.expect(t, !gsw_vga_execute_surface_blt(&g, command[:]))
	gsw2d_test_blt_command(command[:], 1, 2, 1, 0, 2, 1, 0, 0, 1, 1, 0, 0, 0, 0, 0xCC)
	testing.expect(t, !gsw_vga_execute_surface_blt(&g, command[:]))
	gsw2d_test_blt_command(command[:], 1, 2, 0, 0, 1, 1, 0, 0, 1, 1, 4, 0, 0, 0, 0xCC)
	testing.expect(t, !gsw_vga_execute_surface_blt(&g, command[:]))
	gsw2d_test_blt_command(command[:], 1, 2, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 0, 0, 0x5A)
	testing.expect(t, !gsw_vga_execute_surface_blt(&g, command[:]))
	testing.expect_value(t, framebuffer, before)
}

// Windows scrolls by blitting a surface onto itself, so source and destination
// overlap and the copy has to behave as though the source were taken whole
// before any destination pixel moved. The implementation reads the source into
// its own buffer first, which gets this right for free and is easy to optimise
// away later without noticing. Eight pixels shifted right by three: every
// destination has to carry the original source, not a value this blit already
// wrote earlier in the same run.
@(test)
gsw2d_overlapping_self_blt_takes_the_source_before_writing :: proc(t: ^testing.T) {
	framebuffer: [64]u8
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer[:])
	defer gsw_vga_destroy(&g)
	gsw2d_test_register(t, &g, 1, 0, 16, 1, 16, .Indexed_8)
	original := [8]u8{0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17}
	for value, index in original {framebuffer[index] = value}

	command: [GSW_SURFACE_BLT_COMMAND_BYTES]u8
	gsw2d_test_blt_command(
		command[:], 1, 1, 0, 0, 8, 1, 3, 0, 8, 1,
		0, 0, 0, 0, 0xCC,
	)
	testing.expect(t, gsw_vga_execute_surface_blt(&g, command[:]))

	for value, index in original {
		testing.expectf(
			t,
			framebuffer[3 + index] == value,
			"destination pixel %d is %02X, the untouched source says %02X",
			index,
			framebuffer[3 + index],
			value,
		)
	}
	// The three pixels the source left behind keep what they started with.
	for index in 0 ..< 3 {
		testing.expect_value(t, framebuffer[index], original[index])
	}
}

// Windows defines a ternary raster operation as a lookup rather than a formula:
// the result for one pattern, source and destination bit is the operation
// byte's own bit at index P*4 + S*2 + D. `gsw_rop3` builds that answer as a sum
// of minterms instead, and `gsw2d_test_rop3` builds it the same way, so the
// advertised-operation test above cannot tell a wrong formulation from a right
// one. This walks all 256 operations against the definition itself. Both the
// GDI blit and the DirectDraw surface blit resolve through `gsw_rop3`, so this
// is the shared floor under each.
@(test)
gsw2d_rop3_matches_the_windows_lookup_for_every_operation :: proc(t: ^testing.T) {
	for rop in 0 ..< 256 {
		for combination in 0 ..< 8 {
			pattern := u32(combination >> 2 & 1)
			source := u32(combination >> 1 & 1)
			destination := u32(combination & 1)
			expected := u32(rop >> uint(combination)) & 1
			actual := gsw_rop3(u8(rop), source, destination, pattern, 1)
			testing.expectf(
				t,
				actual == expected,
				"rop %02X with pattern %d source %d destination %d gave %d, definition says %d",
				rop,
				pattern,
				source,
				destination,
				actual,
				expected,
			)
		}
	}
}

// The same definition has to hold across a whole pixel, not just one bit, and
// the mask has to keep the result inside the pixel width it names.
@(test)
gsw2d_rop3_applies_the_definition_across_a_whole_pixel :: proc(t: ^testing.T) {
	source, destination, pattern := u32(0x3C), u32(0xA5), u32(0x5A)
	for rop in 0 ..< 256 {
		expected: u32
		for bit in 0 ..< 8 {
			index :=
				int((pattern >> uint(bit) & 1) << 2 |
					(source >> uint(bit) & 1) << 1 |
					(destination >> uint(bit) & 1))
			if rop >> uint(index) & 1 != 0 {expected |= 1 << uint(bit)}
		}
		actual := gsw_rop3(u8(rop), source, destination, pattern, gsw_pixel_mask(1))
		testing.expectf(t, actual == expected, "rop %02X gave %02X, definition says %02X", rop, actual, expected)
	}
}

@(test)
gsw2d_every_advertised_rop_matches_its_truth_table :: proc(t: ^testing.T) {
	rops := []u8{0x00, 0x11, 0x33, 0x44, 0x55, 0x66, 0x88, 0xBB, 0xCC, 0xEE, 0xFF}
	for rop in rops {
		framebuffer: [64]u8
		g: Gsw_Vga
		gsw_vga_init(&g, framebuffer[:])
		gsw2d_test_register(t, &g, 1, 8, 1, 1, 1, .Indexed_8)
		gsw2d_test_register(t, &g, 2, 16, 1, 1, 1, .Indexed_8)
		framebuffer[8], framebuffer[16] = 0x3C, 0xA5
		command: [GSW_SURFACE_BLT_COMMAND_BYTES]u8
		gsw2d_test_blt_command(
			command[:], 1, 2, 0, 0, 1, 1, 0, 0, 1, 1,
			0, 0, 0, 0x5A, u32(rop),
		)
		expected := gsw2d_test_rop3(rop, 0x3C, 0xA5, 0x5A)
		testing.expect(t, gsw_vga_execute_surface_blt(&g, command[:]))
		testing.expect_value(t, framebuffer[16], expected)
		gsw_vga_destroy(&g)
	}
}

@(test)
gsw2d_present_uses_registered_offset_without_copying_pixels :: proc(t: ^testing.T) {
	framebuffer: [128]u8
	for &value, index in framebuffer {value = u8(index)}
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer[:])
	defer gsw_vga_destroy(&g)
	gsw2d_test_register(t, &g, 1, 32, 4, 2, 8, .Indexed_8, GSW_SURFACE_PRESENTABLE)
	before := framebuffer
	ram: [GSW_VGA_RING_MIN_SIZE]u8
	command := ram[:20]
	gsw_test_header(command[:], .Surface_Present, 1, GSW_VGA_COMMAND_VERSION_3)
	gsw_test_wr32(command[:], 16, 1)
	g.ring_size = GSW_VGA_RING_MIN_SIZE
	g.ring_tail = 20
	gsw_vga_process(&g, ram[:])
	testing.expect(t, g.status & GSW_VGA_STATUS_ERROR == 0)
	testing.expect_value(t, g.present_generation, u64(1))
	testing.expect_value(t, g.metrics.presents, u64(1))
	testing.expect_value(t, g.metrics.software_pixels, u64(0))
	testing.expect_value(t, framebuffer, before)
}

@(test)
gsw2d_transport_reset_releases_surface_ids :: proc(t: ^testing.T) {
	framebuffer: [128]u8
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer[:])
	defer gsw_vga_destroy(&g)
	gsw2d_test_register(t, &g, 1, 32, 4, 2, 8, .Indexed_8)
	write: [4]u8
	gsw_test_wr32(write[:], 0, 0)
	gsw_vga_mmio_write(&g, GSW_VGA_REG_RING_SIZE, write[:], nil)
	_, stale := gsw_surface_get(&g, 1)
	testing.expect(t, !stale)
	gsw2d_test_register(t, &g, 1, 32, 4, 2, 8, .Indexed_8)
}
