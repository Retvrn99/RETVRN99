// SPDX-License-Identifier: GPL-3.0-only
package vga

import "core:testing"

@(test)
gsw_gdi_tail_doorbell_publishes_and_completes_synchronously :: proc(t: ^testing.T) {
	framebuffer: [4096]u8
	ram: [1024]u8
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer[:])
	g.ring_gpa = 128
	g.ring_size = 512
	command := ram[128:128 + GSW_GDI_BLT_COMMAND_BYTES]
	gsw_test_header(command, .Gdi_Blt, 7)
	gsw_test_wr16(command, 2, GSW_VGA_COMMAND_VERSION_4)
	pattern: [64]u32
	gsw_gdi_test_command(command, 0, 0, 0, 8, 0, 0, 0, 0, 4, 4, .Indexed_8, 0, 0xFF, pattern)
	doorbell: [4]u8
	gsw_test_wr32(doorbell[:], 0, GSW_GDI_DOORBELL_TAIL_FLAG | u32(GSW_GDI_BLT_COMMAND_BYTES))
	gsw_vga_mmio_write(&g, GSW_VGA_REG_DOORBELL, doorbell[:], ram[:])

	testing.expect_value(t, g.ring_head, u32(GSW_GDI_BLT_COMMAND_BYTES))
	testing.expect_value(t, g.ring_tail, u32(GSW_GDI_BLT_COMMAND_BYTES))
	testing.expect_value(t, g.completed_fence, u64(7))
	for y in 0 ..< 4 {
		for x in 0 ..< 8 {
			testing.expect_value(t, framebuffer[y * 8 + x], x < 4 ? u8(0xFF) : u8(0))
		}
	}
}

@(test)
gsw_gdi_cookie_doorbell_returns_completion_in_guest_memory :: proc(t: ^testing.T) {
	framebuffer: [4096]u8
	ram: [1024]u8
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer[:])
	g.ring_gpa = 128
	g.ring_size = 512
	command := ram[128:128 + GSW_GDI_BLT_COMMAND_BYTES]
	gsw_test_header(command, .Gdi_Blt, 9)
	gsw_test_wr16(command, 2, GSW_VGA_COMMAND_VERSION_4)
	pattern: [64]u32
	gsw_gdi_test_command(command, 0, 0, 0, 8, 0, 0, 0, 0, 4, 4, .Indexed_8, 0, 0xFF, pattern)
	doorbell: [4]u8
	gsw_test_wr32(
		doorbell[:],
		0,
		GSW_GDI_DOORBELL_TAIL_FLAG | GSW_GDI_DOORBELL_COOKIE_FLAG | u32(GSW_GDI_BLT_COMMAND_BYTES),
	)
	gsw_vga_mmio_write(&g, GSW_VGA_REG_DOORBELL, doorbell[:], ram[:])

	testing.expect_value(t, g.ring_head, u32(GSW_GDI_BLT_COMMAND_BYTES))
	testing.expect_value(t, g.ring_tail, u32(GSW_GDI_BLT_COMMAND_BYTES))
	testing.expect_value(t, g.completed_fence, u64(9))
	testing.expect_value(t, g.irq_status & GSW_VGA_IRQ_2D, u32(0))
	testing.expect_value(t, gsw_rd32(ram[:], 128), GSW_GDI_COMPLETION_COOKIE)
}

@(test)
gsw_gdi_cookie_doorbell_never_acknowledges_a_failed_command :: proc(t: ^testing.T) {
	framebuffer: [4096]u8
	ram: [1024]u8
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer[:])
	g.ring_gpa = 128
	g.ring_size = 512
	command := ram[128:128 + GSW_GDI_BLT_COMMAND_BYTES]
	gsw_test_header(command, .Gdi_Blt, 11)
	gsw_test_wr16(command, 2, GSW_VGA_COMMAND_VERSION_4)
	pattern: [64]u32
	gsw_gdi_test_command(command, 0, 0, 0, 8, 0, 0, 0, 0, 0, 4, .Indexed_8, 0, 0xFF, pattern)
	initial_header := gsw_rd32(ram[:], 128)
	doorbell: [4]u8
	gsw_test_wr32(
		doorbell[:],
		0,
		GSW_GDI_DOORBELL_TAIL_FLAG | GSW_GDI_DOORBELL_COOKIE_FLAG | u32(GSW_GDI_BLT_COMMAND_BYTES),
	)
	gsw_vga_mmio_write(&g, GSW_VGA_REG_DOORBELL, doorbell[:], ram[:])

	testing.expect(t, g.status & GSW_VGA_STATUS_ERROR != 0)
	testing.expect_value(t, g.ring_head, u32(0))
	testing.expect_value(t, gsw_rd32(ram[:], 128), initial_header)
	testing.expect(t, initial_header != GSW_GDI_COMPLETION_COOKIE)
}

@(test)
gsw_gdi_cookie_doorbell_rejects_non_gdi_ranges :: proc(t: ^testing.T) {
	framebuffer: [4096]u8
	ram: [1024]u8
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer[:])
	g.ring_gpa = 128
	g.ring_size = 512
	command := ram[128:128 + 40]
	gsw_test_header(command, .Fill, 13)
	gsw_test_wr32(command, 16, 4)
	gsw_test_wr32(command, 20, 4)
	gsw_test_wr32(command, 24, 4)
	gsw_test_wr32(command, 28, u32(Gsw_Pixel_Format.Indexed_8))
	gsw_test_wr32(command, 32, 0x55)
	doorbell: [4]u8
	gsw_test_wr32(
		doorbell[:],
		0,
		GSW_GDI_DOORBELL_TAIL_FLAG | GSW_GDI_DOORBELL_COOKIE_FLAG | u32(len(command)),
	)
	gsw_vga_mmio_write(&g, GSW_VGA_REG_DOORBELL, doorbell[:], ram[:])

	testing.expect(t, g.status & GSW_VGA_STATUS_ERROR != 0)
	testing.expect_value(t, g.ring_head, u32(0))
	testing.expect(t, gsw_rd32(ram[:], 128) != GSW_GDI_COMPLETION_COOKIE)
}

@(test)
gsw_gdi_cookie_doorbell_rejects_an_empty_kick :: proc(t: ^testing.T) {
	framebuffer: [4096]u8
	ram: [1024]u8
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer[:])
	g.ring_gpa = 128
	g.ring_size = 512
	doorbell: [4]u8
	gsw_test_wr32(doorbell[:], 0, GSW_GDI_DOORBELL_TAIL_FLAG | GSW_GDI_DOORBELL_COOKIE_FLAG)
	gsw_vga_mmio_write(&g, GSW_VGA_REG_DOORBELL, doorbell[:], ram[:])

	testing.expect(t, g.status & GSW_VGA_STATUS_ERROR != 0)
	testing.expect_value(t, g.ring_head, u32(0))
	testing.expect(t, gsw_rd32(ram[:], 128) != GSW_GDI_COMPLETION_COOKIE)
}

@(test)
gsw_gdi_cookie_doorbell_preserves_a_pending_2d_irq :: proc(t: ^testing.T) {
	framebuffer: [4096]u8
	ram: [1024]u8
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer[:])
	g.ring_gpa = 128
	g.ring_size = 512
	g.irq_status = GSW_VGA_IRQ_2D
	command := ram[128:128 + GSW_GDI_BLT_COMMAND_BYTES]
	gsw_test_header(command, .Gdi_Blt, 15)
	gsw_test_wr16(command, 2, GSW_VGA_COMMAND_VERSION_4)
	pattern: [64]u32
	gsw_gdi_test_command(command, 0, 0, 0, 8, 0, 0, 0, 0, 4, 4, .Indexed_8, 0, 0xFF, pattern)
	doorbell: [4]u8
	gsw_test_wr32(
		doorbell[:],
		0,
		GSW_GDI_DOORBELL_TAIL_FLAG | GSW_GDI_DOORBELL_COOKIE_FLAG | u32(GSW_GDI_BLT_COMMAND_BYTES),
	)
	gsw_vga_mmio_write(&g, GSW_VGA_REG_DOORBELL, doorbell[:], ram[:])

	testing.expect_value(t, g.irq_status & GSW_VGA_IRQ_2D, GSW_VGA_IRQ_2D)
	testing.expect_value(t, gsw_rd32(ram[:], 128), GSW_GDI_COMPLETION_COOKIE)
}

@(test)
gsw_gdi_cookie_doorbell_handles_a_wrapped_command :: proc(t: ^testing.T) {
	framebuffer: [4096]u8
	ram: [1024]u8
	command: [GSW_GDI_BLT_COMMAND_BYTES]u8
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer[:])
	g.ring_gpa = 128
	g.ring_size = 512
	g.ring_head = 384
	g.ring_tail = 384
	gsw_test_header(command[:], .Gdi_Blt, 17)
	gsw_test_wr16(command[:], 2, GSW_VGA_COMMAND_VERSION_4)
	pattern: [64]u32
	gsw_gdi_test_command(command[:], 0, 0, 0, 8, 0, 0, 0, 0, 4, 4, .Indexed_8, 0, 0xFF, pattern)
	copy(ram[128 + 384:128 + 512], command[:128])
	copy(ram[128:128 + GSW_GDI_BLT_COMMAND_BYTES - 128], command[128:])
	new_tail := u32((384 + GSW_GDI_BLT_COMMAND_BYTES) & (512 - 1))
	doorbell: [4]u8
	gsw_test_wr32(
		doorbell[:],
		0,
		GSW_GDI_DOORBELL_TAIL_FLAG | GSW_GDI_DOORBELL_COOKIE_FLAG | new_tail,
	)
	gsw_vga_mmio_write(&g, GSW_VGA_REG_DOORBELL, doorbell[:], ram[:])

	testing.expect_value(t, g.ring_head, new_tail)
	testing.expect_value(t, g.ring_tail, new_tail)
	testing.expect_value(t, gsw_rd32(ram[:], 128 + 384), GSW_GDI_COMPLETION_COOKIE)
}

gsw_gdi_test_ring_write :: proc(ram: []u8, ring_gpa: u64, ring_size, offset: u32, data: []u8) {
	first := min(len(data), int(ring_size - offset))
	start := int(ring_gpa + u64(offset))
	copy(ram[start:start + first], data[:first])
	if first < len(data) {
		base := int(ring_gpa)
		copy(ram[base:base + len(data) - first], data[first:])
	}
}

@(test)
gsw_gdi_cookie_doorbell_progresses_across_recreated_blt_sequences :: proc(t: ^testing.T) {
	framebuffer: [4096]u8
	ram: [1024]u8
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer[:])
	g.ring_gpa = 256
	g.ring_size = 512
	for &pixel, index in framebuffer[:256] {pixel = u8(index)}

	for submission in 0 ..< 40 {
		command: [GSW_GDI_BLT_COMMAND_BYTES]u8
		fence := u64(submission + 1)
		gsw_test_header(command[:], .Gdi_Blt, fence)
		gsw_test_wr16(command[:], 2, GSW_VGA_COMMAND_VERSION_4)
		pattern: [64]u32
		flags, rop3 := u32(GSW_GDI_SOURCE_VALID), u32(0xCC)
		if submission & 1 == 0 {
			flags, rop3 = GSW_GDI_PATTERN_VALID, 0xF0
			for &pixel, index in pattern {pixel = u32(index + submission) & 0xFF}
		}
		gsw_gdi_test_command(
			command[:],
			0,
			512,
			16,
			16,
			0,
			0,
			0,
			0,
			8,
			8,
			.Indexed_8,
			flags,
			rop3,
			pattern,
		)
		command_offset := g.ring_tail
		gsw_gdi_test_ring_write(ram[:], g.ring_gpa, g.ring_size, command_offset, command[:])
		new_tail := (command_offset + GSW_GDI_BLT_COMMAND_BYTES) & (g.ring_size - 1)
		doorbell: [4]u8
		gsw_test_wr32(
			doorbell[:],
			0,
			GSW_GDI_DOORBELL_TAIL_FLAG | GSW_GDI_DOORBELL_COOKIE_FLAG | new_tail,
		)
		gsw_vga_mmio_write(&g, GSW_VGA_REG_DOORBELL, doorbell[:], ram[:])

		if !testing.expect_value(t, g.ring_head, new_tail) {return}
		if !testing.expect_value(t, g.ring_tail, new_tail) {return}
		if !testing.expect_value(t, g.completed_fence, fence) {return}
		if !testing.expect_value(
			t,
			gsw_rd32(ram[:], int(g.ring_gpa + u64(command_offset))),
			GSW_GDI_COMPLETION_COOKIE,
		) {return}
	}
	testing.expect_value(t, g.status, GSW_VGA_STATUS_READY)
}

@(test)
gsw_gdi_failed_cookie_submission_can_rearm_the_same_ring_slot :: proc(t: ^testing.T) {
	framebuffer: [4096]u8
	ram: [1024]u8
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer[:])
	g.ring_gpa = 128
	g.ring_size = 512
	command := ram[128:128 + GSW_GDI_BLT_COMMAND_BYTES]
	pattern: [64]u32
	gsw_test_header(command, .Gdi_Blt, 1)
	gsw_test_wr16(command, 2, GSW_VGA_COMMAND_VERSION_4)
	gsw_gdi_test_command(command, 0, 0, 0, 8, 0, 0, 0, 0, 0, 4, .Indexed_8, 0, 0xFF, pattern)
	doorbell: [4]u8
	gsw_test_wr32(
		doorbell[:],
		0,
		GSW_GDI_DOORBELL_TAIL_FLAG | GSW_GDI_DOORBELL_COOKIE_FLAG | u32(GSW_GDI_BLT_COMMAND_BYTES),
	)
	gsw_vga_mmio_write(&g, GSW_VGA_REG_DOORBELL, doorbell[:], ram[:])
	testing.expect(t, g.status & GSW_VGA_STATUS_ERROR != 0)
	testing.expect_value(t, g.ring_head, u32(0))

	register: [4]u8
	gsw_test_wr32(register[:], 0, g.ring_head)
	gsw_vga_mmio_write(&g, GSW_VGA_REG_RING_TAIL, register[:], ram[:])
	gsw_test_wr32(register[:], 0, GSW_VGA_STATUS_ERROR)
	gsw_vga_mmio_write(&g, GSW_VGA_REG_STATUS, register[:], ram[:])
	gsw_test_header(command, .Gdi_Blt, 2)
	gsw_test_wr16(command, 2, GSW_VGA_COMMAND_VERSION_4)
	gsw_gdi_test_command(command, 0, 0, 0, 8, 0, 0, 0, 0, 4, 4, .Indexed_8, 0, 0xFF, pattern)
	gsw_vga_mmio_write(&g, GSW_VGA_REG_DOORBELL, doorbell[:], ram[:])

	testing.expect_value(t, g.status, GSW_VGA_STATUS_READY)
	testing.expect_value(t, g.ring_head, u32(GSW_GDI_BLT_COMMAND_BYTES))
	testing.expect_value(t, g.ring_tail, u32(GSW_GDI_BLT_COMMAND_BYTES))
	testing.expect_value(t, g.completed_fence, u64(2))
	testing.expect_value(t, gsw_rd32(ram[:], 128), GSW_GDI_COMPLETION_COOKIE)
}

gsw_gdi_test_command :: proc(
	command: []u8,
	source_base, destination_base, source_pitch, destination_pitch: u32,
	source_x, source_y, destination_x, destination_y, width, height: u32,
	format: Gsw_Pixel_Format,
	flags, rop3: u32,
	pattern: [64]u32,
) {
	gsw_test_wr32(command, 16, source_base)
	gsw_test_wr32(command, 20, destination_base)
	gsw_test_wr32(command, 24, source_pitch)
	gsw_test_wr32(command, 28, destination_pitch)
	gsw_test_wr32(command, 32, source_x)
	gsw_test_wr32(command, 36, source_y)
	gsw_test_wr32(command, 40, destination_x)
	gsw_test_wr32(command, 44, destination_y)
	gsw_test_wr32(command, 48, width)
	gsw_test_wr32(command, 52, height)
	gsw_test_wr32(command, 56, u32(format))
	gsw_test_wr32(command, 60, flags)
	gsw_test_wr32(command, 64, rop3)
	for pixel, index in pattern {gsw_test_wr32(command, 68 + index * 4, pixel)}
}

gsw_gdi_test_reference :: proc(rop: u8, source, destination, pattern, mask: u32) -> u32 {
	result: u32
	for bit in 0 ..< 32 {
		bit_mask := u32(1) << uint(bit)
		if mask & bit_mask == 0 {continue}
		index := u8(0)
		if destination & bit_mask != 0 {index |= 1}
		if source & bit_mask != 0 {index |= 2}
		if pattern & bit_mask != 0 {index |= 4}
		if rop & (u8(1) << uint(index)) != 0 {result |= bit_mask}
	}
	return result
}

@(test)
gsw_gdi_all_rop3_values_match_scalar_reference_in_every_packed_format :: proc(t: ^testing.T) {
	formats := []Gsw_Pixel_Format{.Indexed_8, .Rgb_565, .Rgb_888, .Xrgb_8888}
	for format in formats {
		bytes := gsw_gdi_format_bytes(format)
		mask := gsw_pixel_mask(bytes)
		pitch := u32(24 * bytes)
		source_base, destination_base := u32(96), u32(1152)
		for rop_integer in 0 ..< 256 {
			for brush_kind in 0 ..< 2 {
				framebuffer: [4096]u8
				g: Gsw_Vga
				gsw_vga_init(&g, framebuffer[:])
				pattern: [64]u32
				for &pixel, index in pattern {
					pixel =
						brush_kind == 0 ? 0xA55A_3CC3 & mask : (u32(index) * 0x102_0409 + 0x35) & mask
				}
				sources: [64]u32
				destinations: [64]u32
				for y in 0 ..< 8 {
					for x in 0 ..< 8 {
						index := y * 8 + x
						sources[index] = (u32(index) * 0x0102_0305 + 0x17) & mask
						destinations[index] = (u32(index) * 0x0705_0301 + 0xC3) & mask
						gsw_pixel_write(
							framebuffer[:],
							int(source_base) + (2 + y) * int(pitch) + (3 + x) * bytes,
							bytes,
							sources[index],
						)
						gsw_pixel_write(
							framebuffer[:],
							int(destination_base) + (4 + y) * int(pitch) + (5 + x) * bytes,
							bytes,
							destinations[index],
						)
					}
				}
				command: [GSW_GDI_BLT_COMMAND_BYTES]u8
				gsw_gdi_test_command(
					command[:],
					source_base,
					destination_base,
					pitch,
					pitch,
					3,
					2,
					5,
					4,
					8,
					8,
					format,
					GSW_GDI_SOURCE_VALID | GSW_GDI_PATTERN_VALID,
					u32(rop_integer),
					pattern,
				)
				testing.expect(t, gsw_vga_execute_gdi_blt(&g, command[:]))
				for y in 0 ..< 8 {
					for x in 0 ..< 8 {
						index := y * 8 + x
						actual := gsw_pixel_read(
							framebuffer[:],
							int(destination_base) + (4 + y) * int(pitch) + (5 + x) * bytes,
							bytes,
						)
						expected := gsw_gdi_test_reference(
							u8(rop_integer),
							sources[index],
							destinations[index],
							pattern[((4 + y) & 7) * 8 + ((5 + x) & 7)],
							mask,
						)
						testing.expect_value(t, actual, expected)
					}
				}
				gsw_vga_destroy(&g)
			}
		}
	}
}

@(test)
gsw_gdi_accepts_dword_aligned_24bit_surfaces_with_nonpixel_aligned_pitch :: proc(t: ^testing.T) {
	framebuffer: [256]u8
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer[:])
	source_base, destination_base := u32(4), u32(100)
	source_pitch, destination_pitch := u32(16), u32(20)
	for y in 0 ..< 2 {
		for x in 0 ..< 5 {
			value := u32(0x10203 + y * 0x10101 + x * 0x30303) & 0x00FF_FFFF
			gsw_pixel_write(framebuffer[:], int(source_base) + y * 16 + x * 3, 3, value)
		}
	}
	pattern: [64]u32
	command: [GSW_GDI_BLT_COMMAND_BYTES]u8
	gsw_gdi_test_command(
		command[:],
		source_base,
		destination_base,
		source_pitch,
		destination_pitch,
		0,
		0,
		0,
		0,
		5,
		2,
		.Rgb_888,
		GSW_GDI_SOURCE_VALID,
		0xCC,
		pattern,
	)
	testing.expect(t, gsw_vga_execute_gdi_blt(&g, command[:]))
	for y in 0 ..< 2 {
		for x in 0 ..< 5 {
			source := gsw_pixel_read(framebuffer[:], int(source_base) + y * 16 + x * 3, 3)
			destination := gsw_pixel_read(
				framebuffer[:],
				int(destination_base) + y * 20 + x * 3,
				3,
			)
			testing.expect_value(t, destination, source)
		}
	}
}

@(test)
gsw_gdi_pitch_gaps_do_not_create_false_overlap :: proc(t: ^testing.T) {
	testing.expect(t, !gsw_surface_rows_overlap(0, 16, 4, 2, 8, 16, 4, 2))
	testing.expect(t, gsw_surface_rows_overlap(0, 16, 12, 2, 8, 16, 12, 2))
}

@(test)
gsw_gdi_dst_noop_does_not_dirty_visible_scanout :: proc(t: ^testing.T) {
	v: Vga
	framebuffer := test_vga_init(t, &v)
	defer delete(framebuffer)
	defer vga_destroy(&v)
	testing.expect(t, test_set_vbe_mode(&v, 640, 480, 8, DISPI_LFB_ENABLED))
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer)
	gsw_vga_attach_scanout(&g, &v)
	pattern: [64]u32
	command: [GSW_GDI_BLT_COMMAND_BYTES]u8
	gsw_gdi_test_command(
		command[:],
		0,
		0,
		640,
		640,
		0,
		0,
		0,
		0,
		64,
		64,
		.Indexed_8,
		0,
		0xAA,
		pattern,
	)
	generation := v.content_generation
	testing.expect(t, gsw_vga_execute_gdi_blt(&g, command[:]))
	testing.expect_value(t, v.content_generation, generation)
}

@(test)
gsw_gdi_dependency_classification_allows_only_unneeded_missing_operands :: proc(t: ^testing.T) {
	framebuffer: [256]u8
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer[:])
	defer gsw_vga_destroy(&g)
	pattern: [64]u32
	command: [GSW_GDI_BLT_COMMAND_BYTES]u8
	gsw_gdi_test_command(command[:], 0, 64, 8, 8, 0, 0, 0, 0, 4, 4, .Indexed_8, 0, 0xAA, pattern)
	testing.expect(t, gsw_vga_execute_gdi_blt(&g, command[:]))
	gsw_gdi_test_command(command[:], 0, 64, 8, 8, 0, 0, 0, 0, 4, 4, .Indexed_8, 0, 0xCC, pattern)
	testing.expect(t, !gsw_vga_execute_gdi_blt(&g, command[:]))
	gsw_gdi_test_command(command[:], 0, 64, 8, 8, 0, 0, 0, 0, 4, 4, .Indexed_8, 0, 0xF0, pattern)
	testing.expect(t, !gsw_vga_execute_gdi_blt(&g, command[:]))
	gsw_gdi_test_command(
		command[:],
		0,
		64,
		8,
		8,
		0,
		0,
		0,
		0,
		4,
		4,
		.Indexed_8,
		GSW_GDI_SOURCE_VALID,
		0xCC,
		pattern,
	)
	testing.expect(t, gsw_vga_execute_gdi_blt(&g, command[:]))
}

@(test)
gsw_gdi_overlap_is_exact_horizontally_vertically_and_with_different_pitches :: proc(
	t: ^testing.T,
) {
	for scenario in 0 ..< 3 {
		framebuffer: [512]u8
		for &pixel, index in framebuffer {pixel = u8(index * 17 + 3)}
		before := framebuffer
		g: Gsw_Vga
		gsw_vga_init(&g, framebuffer[:])
		pattern: [64]u32
		command: [GSW_GDI_BLT_COMMAND_BYTES]u8
		source_pitch, destination_pitch := u32(16), u32(16)
		source_x, source_y, destination_x, destination_y := u32(1), u32(1), u32(3), u32(1)
		if scenario == 1 {destination_x, destination_y = 1, 2}
		if scenario == 2 {
			source_pitch, destination_pitch = 20, 12
			destination_x, destination_y = 3, 1
		}
		gsw_gdi_test_command(
			command[:],
			32,
			32,
			source_pitch,
			destination_pitch,
			source_x,
			source_y,
			destination_x,
			destination_y,
			6,
			4,
			.Indexed_8,
			GSW_GDI_SOURCE_VALID,
			0xCC,
			pattern,
		)
		expected: [24]u8
		for y in 0 ..< 4 {
			for x in 0 ..< 6 {
				offset :=
					32 +
					int(source_y) * int(source_pitch) +
					y * int(source_pitch) +
					int(source_x) +
					x
				expected[y * 6 + x] = before[offset]
			}
		}
		testing.expect(t, gsw_vga_execute_gdi_blt(&g, command[:]))
		for y in 0 ..< 4 {
			for x in 0 ..< 6 {
				offset :=
					32 +
					int(destination_y) * int(destination_pitch) +
					y * int(destination_pitch) +
					int(destination_x) +
					x
				actual := framebuffer[offset]
				testing.expect_value(t, actual, expected[y * 6 + x])
			}
		}
		gsw_vga_destroy(&g)
	}
}

@(test)
gsw_gdi_rejects_malformed_commands_without_writing :: proc(t: ^testing.T) {
	framebuffer: [512]u8
	for &pixel, index in framebuffer {pixel = u8(index)}
	before := framebuffer
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer[:])
	defer gsw_vga_destroy(&g)
	pattern: [64]u32
	command: [GSW_GDI_BLT_COMMAND_BYTES]u8
	gsw_gdi_test_command(
		command[:],
		0,
		128,
		16,
		16,
		0,
		0,
		0,
		0,
		4,
		4,
		.Indexed_8,
		GSW_GDI_SOURCE_VALID | GSW_GDI_PATTERN_VALID,
		0xCC,
		pattern,
	)
	testing.expect(t, !gsw_vga_execute_gdi_blt(&g, command[:len(command) - 4]))
	oversized: [GSW_GDI_BLT_COMMAND_BYTES + 4]u8
	testing.expect(t, !gsw_vga_execute_gdi_blt(&g, oversized[:]))
	mutations := []struct {
		offset, value: u32,
	} {
		{48, 0},
		{52, 0},
		{56, u32(Gsw_Pixel_Format.Rgb_555)},
		{60, 4},
		{64, 256},
		{20, 500},
		{28, 0xFFFF_FFFC},
	}
	for mutation in mutations {
		mutated := command
		gsw_test_wr32(mutated[:], int(mutation.offset), mutation.value)
		testing.expect(t, !gsw_vga_execute_gdi_blt(&g, mutated[:]))
	}
	invalid_pattern := command
	gsw_test_wr32(invalid_pattern[:], 68, 0x100)
	gsw_test_wr32(invalid_pattern[:], 64, 0xF0)
	testing.expect(t, !gsw_vga_execute_gdi_blt(&g, invalid_pattern[:]))
	testing.expect_value(t, framebuffer, before)
}

@(test)
gsw_gdi_accepts_the_maximum_software_rectangle :: proc(t: ^testing.T) {
	width, height := u32(4096), u32(2160)
	framebuffer := make([]u8, int(width * height))
	defer delete(framebuffer)
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer)
	defer gsw_vga_destroy(&g)
	pattern: [64]u32
	command: [GSW_GDI_BLT_COMMAND_BYTES]u8
	gsw_gdi_test_command(
		command[:],
		0,
		0,
		width,
		width,
		0,
		0,
		0,
		0,
		width,
		height,
		.Indexed_8,
		0,
		0x00,
		pattern,
	)
	testing.expect(t, gsw_vga_execute_gdi_blt(&g, command[:]))
}

@(test)
gsw_gdi_version_four_opcode_routes_through_the_ring :: proc(t: ^testing.T) {
	framebuffer: [256]u8
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer[:])
	defer gsw_vga_destroy(&g)
	ram: [512]u8
	command := ram[:GSW_GDI_BLT_COMMAND_BYTES]
	pattern: [64]u32
	gsw_test_header(command, .Gdi_Blt, 9, GSW_VGA_COMMAND_VERSION_4)
	gsw_gdi_test_command(command, 0, 64, 8, 8, 0, 0, 0, 0, 4, 4, .Indexed_8, 0, 0x00, pattern)
	g.ring_size = 512
	g.ring_tail = GSW_GDI_BLT_COMMAND_BYTES
	gsw_vga_process(&g, ram[:])
	testing.expect(t, g.status & GSW_VGA_STATUS_ERROR == 0)
	testing.expect_value(t, g.completed_fence, u64(9))
	testing.expect_value(t, g.metrics.blits, u64(1))
}
