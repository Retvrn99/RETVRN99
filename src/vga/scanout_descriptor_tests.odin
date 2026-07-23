// SPDX-License-Identifier: GPL-3.0-only
package vga

import contract "../presentation"
import "core:testing"

scanout_descriptor_test_set_owned_gsw :: proc(
	t: ^testing.T,
	descriptor: ^Scanout_Descriptor,
	format: contract.Pixel_Format,
	source: []u8,
) {
	bytes_per_pixel, known := contract.pixel_format_bytes(format)
	if !testing.expect(t, known) {return}
	full := contract.Rect {
		width  = 1,
		height = 1,
	}
	dirty, clips: contract.Rect_Set
	testing.expect(t, contract.rect_set_append(&dirty, full))
	testing.expect(t, contract.rect_set_append(&clips, full))
	mode_key := contract.Mode_Key {
		format = format,
		surface_extent = {width = 1, height = 1},
		canvas_extent = {width = 1, height = 1},
		source = full,
		destination = full,
	}
	present := contract.Gsw_Present {
		header = {
			sequence = 17,
			lifecycle_generation = 2,
			mode_generation = 3,
			mode_key = mode_key,
			identity_namespace = .Gsw2d,
			device_generation = 4,
			surface = {id = 5, generation = 6},
			format = format,
			surface_extent = mode_key.surface_extent,
			canvas_extent = mode_key.canvas_extent,
			source = full,
			destination = full,
			dirty = dirty,
			interval = 0,
			source_kind = .Gsw_Snapshot,
			ownership = .Mailbox_Surface,
		},
		clips = clips,
		source_pitch = bytes_per_pixel,
	}
	validation := contract.Validation_Context {
		lifecycle_generation = present.header.lifecycle_generation,
		mode_generation      = present.header.mode_generation,
		mode_key             = present.header.mode_key,
		identity_namespace   = present.header.identity_namespace,
		device_generation    = present.header.device_generation,
		surface              = present.header.surface,
		format_mask          = contract.PIXEL_FORMAT_MASK_ALL,
		interval_mask        = contract.PRESENT_INTERVAL_MASK_ALL,
		source_byte_capacity = u64(len(source)),
	}
	testing.expect(t, contract.diagnostic_valid(contract.validate_gsw(present, validation)))
	descriptor.allocator = context.allocator
	descriptor.gsw_presentation = {
		allocator = context.allocator,
		present = present,
		present_valid = true,
		palette = {dac_bits = GSW_PALETTE_DAC_BITS},
		source = make([]u8, len(source)),
		bytes_copied = len(source),
	}
	copy(descriptor.gsw_presentation.source, source)
}

@(test)
scanout_descriptor_test_captures_active_vram_and_renders_later :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	testing.expect(t, test_set_vbe_mode(&v, 2, 1, 32))
	v.vram[0], v.vram[1], v.vram[2] = 0x11, 0x22, 0x33
	vga_note_content_change(&v)

	descriptor: Scanout_Descriptor
	defer scanout_descriptor_destroy(&descriptor)
	testing.expect(t, scanout_descriptor_capture(&descriptor, &v))
	testing.expect_value(t, descriptor.generation, v.presentation_sequence)
	testing.expect_value(t, descriptor.state.bank_read, v.bank_read)
	testing.expect_value(t, descriptor.state.bank_write, v.bank_write)
	testing.expect_value(t, descriptor.mode_observability.scanout_generation, v.content_generation)
	testing.expect_value(t, descriptor.mode_observability.kind, Display_Kind.Xrgb_8888)
	testing.expect(t, descriptor.bytes_copied < VRAM_SIZE)
	v.vram[0], v.vram[1], v.vram[2] = 0, 0, 0
	frame := scanout_descriptor_render(&descriptor)
	testing.expect(t, frame != nil)
	testing.expect_value(t, frame.pixels[0], u32(0xFF332211))
	testing.expect_value(t, v.full_frame_renders, u64(0))
}

@(test)
scanout_descriptor_test_uses_explicit_state_without_source_vga_lifetime :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	testing.expect(t, test_set_vbe_mode(&v, 1, 1, 8))
	v.vram[0] = 3
	v.dac[9], v.dac[10], v.dac[11] = 0x3F, 0, 0
	vga_note_content_change(&v)

	descriptor: Scanout_Descriptor
	defer scanout_descriptor_destroy(&descriptor)
	testing.expect(t, scanout_descriptor_capture(&descriptor, &v))
	vga_destroy(&v)

	frame := scanout_descriptor_render(&descriptor)
	testing.expect(t, frame != nil)
	testing.expect_value(t, frame.kind, Display_Kind.Indexed_8)
	testing.expect_value(t, frame.pixels[0], u32(0xFFFF0000))
}

@(test)
scanout_descriptor_test_deferred_source_tracks_raster_mode_without_rendering :: proc(
	t: ^testing.T,
) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	testing.expect(t, test_set_vbe_mode(&v, 2, 2, 8))
	vga_set_deferred_scanout(&v, true)
	vga_begin_raster_change(&v, 500_000)
	vga_sync_to(&v, 1_500_000)
	testing.expect(t, v.raster_fallback)
	testing.expect_value(t, v.raster_pixels_rendered, u64(0))
	testing.expect_value(t, v.full_frame_renders, u64(0))
}

@(test)
scanout_descriptor_test_renders_owned_gsw_pixel_formats :: proc(t: ^testing.T) {
	cases := []struct {
		format:        contract.Pixel_Format,
		source:        [4]u8,
		source_length: int,
		expected:      u32,
		kind:          Display_Kind,
	} {
		{.Indexed_8, {1, 0, 0, 0}, 1, 0xFF12_3456, .Indexed_8},
		{.Rgb_555, {0x01, 0x7E, 0, 0}, 2, 0xFFFF_8408, .Rgb_555},
		{.Rgb_565, {0x1F, 0x0C, 0, 0}, 2, 0xFF08_82FF, .Rgb_565},
		{.Bgr_888, {0x11, 0x22, 0x33, 0}, 3, 0xFF33_2211, .Rgb_888},
		{.Bgrx_8888, {0x11, 0x22, 0x33, 0x44}, 4, 0xFF33_2211, .Xrgb_8888},
		{.Rgba_8888, {0x33, 0x22, 0x11, 0x44}, 4, 0xFF33_2211, .Xrgb_8888},
	}
	for &item in cases {
		descriptor: Scanout_Descriptor
		scanout_descriptor_test_set_owned_gsw(
			t,
			&descriptor,
			item.format,
			item.source[:item.source_length],
		)
		descriptor.gsw_presentation.palette.entries[3] = 0x12
		descriptor.gsw_presentation.palette.entries[4] = 0x34
		descriptor.gsw_presentation.palette.entries[5] = 0x56
		descriptor.state.pel_mask = 0
		descriptor.state.dac[3] = 0x3F

		frame := scanout_descriptor_render_gsw(&descriptor)
		if testing.expect(t, frame != nil) {
			testing.expect_value(t, frame.kind, item.kind)
			testing.expect_value(t, frame.width, 1)
			testing.expect_value(t, frame.height, 1)
			testing.expect_value(t, frame.aspect_width, 1)
			testing.expect_value(t, frame.aspect_height, 1)
			testing.expect_value(t, frame.content_generation, u64(17))
			testing.expect_value(t, frame.pixels[0], item.expected)
		}
		scanout_descriptor_destroy(&descriptor)
	}
}

@(test)
scanout_descriptor_test_indexed_gsw_uses_captured_owned_palette :: proc(t: ^testing.T) {
	v: Vga
	framebuffer := test_vga_init(t, &v)
	defer delete(framebuffer)
	defer vga_destroy(&v)
	framebuffer[0] = 1
	v.dac[3], v.dac[4], v.dac[5] = 0x3F, 0, 0
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer)
	defer gsw_vga_destroy(&g)
	gsw_vga_attach_scanout(&g, &v)
	ram: [GSW_VGA_RING_MIN_SIZE]u8
	gsw_test_header(ram[:28], .Set_Palette, 0)
	gsw_test_wr32(ram[:28], 16, 1)
	gsw_test_wr32(ram[:28], 20, 1)
	gsw_test_wr32(ram[:28], 24, 0x0080_4020)
	gsw_test_raw_present_command(ram[28:68], 0, 1, 1, 1, .Indexed_8, 1)
	g.ring_size = GSW_VGA_RING_MIN_SIZE
	g.ring_tail = 68
	gsw_vga_process(&g, ram[:])
	descriptor: Scanout_Descriptor
	defer scanout_descriptor_destroy(&descriptor)
	testing.expect(t, scanout_descriptor_capture(&descriptor, &v))
	testing.expect(
		t,
		gsw_presentation_descriptor_capture(
			&descriptor.gsw_presentation,
			&g,
			7,
			&v.presentation_mode_clock,
		),
	)
	testing.expect_value(t, descriptor.gsw_presentation.palette.dac_bits, GSW_PALETTE_DAC_BITS)
	testing.expect_value(t, descriptor.gsw_presentation.palette.entries[3], u8(0x80))
	testing.expect_value(t, descriptor.gsw_presentation.palette.entries[4], u8(0x40))
	testing.expect_value(t, descriptor.gsw_presentation.palette.entries[5], u8(0x20))
	g.palette.entries[3], g.palette.entries[4], g.palette.entries[5] = 1, 2, 3
	descriptor.state.dac[3], descriptor.state.dac[4], descriptor.state.dac[5] = 0, 0x3F, 0
	descriptor.state.pel_mask = 0

	frame := scanout_descriptor_render_gsw(&descriptor)

	if testing.expect(t, frame != nil) {
		testing.expect_value(t, frame.pixels[0], u32(0xFF80_4020))
	}
}

@(test)
scanout_descriptor_test_gsw_render_rejects_invalid_or_missing_record :: proc(t: ^testing.T) {
	testing.expect(t, scanout_descriptor_render_gsw(nil) == nil)
	descriptor: Scanout_Descriptor
	testing.expect(t, scanout_descriptor_render_gsw(&descriptor) == nil)
	descriptor.gsw_presentation.present_valid = true
	testing.expect(t, scanout_descriptor_render_gsw(&descriptor) == nil)
	descriptor.gsw_presentation.present.header.surface_extent = {
		width  = 1,
		height = 1,
	}
	descriptor.gsw_presentation.present.header.format = .Invalid
	testing.expect(t, scanout_descriptor_render_gsw(&descriptor) == nil)
	scanout_descriptor_destroy(&descriptor)
}

@(test)
scanout_descriptor_test_gsw_render_revalidates_mailbox_owned_layout :: proc(t: ^testing.T) {
	source := [4]u8{0x11, 0x22, 0x33, 0}
	descriptor: Scanout_Descriptor
	scanout_descriptor_test_set_owned_gsw(t, &descriptor, .Bgrx_8888, source[:])
	descriptor.gsw_presentation.present.header.ownership = .Vm_Framebuffer
	testing.expect(t, scanout_descriptor_render_gsw(&descriptor) == nil)
	scanout_descriptor_destroy(&descriptor)

	descriptor = {}
	scanout_descriptor_test_set_owned_gsw(t, &descriptor, .Bgrx_8888, source[:])
	descriptor.gsw_presentation.present.source_offset = 1
	testing.expect(t, scanout_descriptor_render_gsw(&descriptor) == nil)
	scanout_descriptor_destroy(&descriptor)

	descriptor = {}
	scanout_descriptor_test_set_owned_gsw(t, &descriptor, .Bgrx_8888, source[:])
	descriptor.gsw_presentation.present.source_pitch = 8
	testing.expect(t, scanout_descriptor_render_gsw(&descriptor) == nil)
	scanout_descriptor_destroy(&descriptor)

	descriptor = {}
	indexed := [1]u8{1}
	scanout_descriptor_test_set_owned_gsw(t, &descriptor, .Indexed_8, indexed[:])
	descriptor.gsw_presentation.palette.dac_bits = 6
	testing.expect(t, scanout_descriptor_render_gsw(&descriptor) == nil)
	scanout_descriptor_destroy(&descriptor)
}

@(test)
scanout_descriptor_test_destroy_clears_owned_gsw_pixels :: proc(t: ^testing.T) {
	descriptor: Scanout_Descriptor
	source := [4]u8{0x11, 0x22, 0x33, 0}
	scanout_descriptor_test_set_owned_gsw(t, &descriptor, .Bgrx_8888, source[:])
	frame := scanout_descriptor_render_gsw(&descriptor)
	testing.expect(t, frame != nil)
	testing.expect(t, descriptor.gsw_presentation.source != nil)
	testing.expect(t, descriptor.gsw_frame_pixels != nil)
	testing.expect(t, descriptor.gsw_frame.pixels != nil)

	scanout_descriptor_destroy(&descriptor)
	testing.expect(t, descriptor.gsw_presentation.source == nil)
	testing.expect(t, descriptor.gsw_frame_pixels == nil)
	testing.expect(t, descriptor.gsw_frame.pixels == nil)
	testing.expect(t, !descriptor.gsw_presentation.present_valid)
}
