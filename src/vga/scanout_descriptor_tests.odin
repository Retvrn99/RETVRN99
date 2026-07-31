// SPDX-License-Identifier: GPL-3.0-only
package vga

import contract "../presentation"
import "core:bytes"
import "core:mem"
import "core:testing"

Scanout_Test_Expansion :: struct {
	legacy_pixels: []u32,
	legacy_frame:  Display_Frame,
	gsw_pixels:    []u32,
	gsw_frame:     Display_Frame,
}

scanout_test_expand_legacy :: proc(descriptor: ^Scanout_Descriptor) -> ^Display_Frame {
	expansion := new(Scanout_Test_Expansion, context.temp_allocator)
	return scanout_descriptor_expand_legacy(
		descriptor,
		&expansion.legacy_pixels,
		&expansion.legacy_frame,
		context.temp_allocator,
	)
}

scanout_test_expand_gsw :: proc(descriptor: ^Scanout_Descriptor) -> ^Display_Frame {
	expansion := new(Scanout_Test_Expansion, context.temp_allocator)
	return scanout_descriptor_expand_gsw(
		descriptor,
		&expansion.gsw_pixels,
		&expansion.gsw_frame,
		context.temp_allocator,
	)
}

scanout_test_pixel_hash :: proc(pixels: []u32) -> u64 {
	hash := u64(14_695_981_039_346_656_037)
	for pixel in pixels {
		for shift: u32 = 0; shift < 32; shift += 8 {
			hash = (hash ~ u64(u8(pixel >> shift))) * u64(1_099_511_628_211)
		}
	}
	return hash
}

Scanout_Reference_Mode :: enum {
	Text,
	Planar,
	Ega_Planar,
	Chain_4,
	Mode_X,
	Cga_2,
	Cga_1,
}

scanout_test_expect_reference_equivalence :: proc(t: ^testing.T, source: ^Vga) {
	vga_note_content_change(source)
	reference := vga_display_frame(source)
	if !testing.expect(t, reference != nil) {return}
	reference_hash := scanout_test_pixel_hash(reference.pixels)
	reference_text := reference.text

	descriptor: Scanout_Descriptor
	defer scanout_descriptor_destroy(&descriptor)
	if !testing.expect(t, scanout_descriptor_capture(&descriptor, source)) {return}
	raw_before := make([]u8, descriptor.bytes_copied, context.temp_allocator)
	copy(raw_before, descriptor.vram[:descriptor.bytes_copied])
	state_before := descriptor.state
	journal_before := descriptor.journal
	mode_before := descriptor.mode_observability
	ranges_before := descriptor.valid_ranges
	raw_complete_before := descriptor.raw_complete
	text_before := descriptor.text
	generation_before := descriptor.generation
	bytes_before := descriptor.bytes_copied
	duration_before := descriptor.copy_duration_ns
	update_before := descriptor.legacy_update

	expanded := scanout_test_expand_legacy(&descriptor)
	if !testing.expect(t, expanded != nil) {return}
	testing.expect_value(t, expanded.kind, reference.kind)
	testing.expect_value(t, expanded.width, reference.width)
	testing.expect_value(t, expanded.height, reference.height)
	testing.expect_value(t, expanded.aspect_width, reference.aspect_width)
	testing.expect_value(t, expanded.aspect_height, reference.aspect_height)
	testing.expect_value(t, expanded.generation, reference.generation)
	testing.expect_value(t, expanded.content_generation, reference.content_generation)
	testing.expect_value(
		t,
		expanded.guest_activity_generation,
		reference.guest_activity_generation,
	)
	testing.expect_value(t, expanded.overscan, reference.overscan)
	testing.expect_value(t, expanded.border, reference.border)
	testing.expect(t, text_snapshot_equal(&expanded.text, &reference_text))
	testing.expect_value(t, scanout_test_pixel_hash(expanded.pixels), reference_hash)

	testing.expect(t, bytes.equal(raw_before, descriptor.vram[:descriptor.bytes_copied]))
	testing.expect(t, descriptor.state == state_before)
	testing.expect(t, descriptor.journal == journal_before)
	testing.expect(t, descriptor.mode_observability == mode_before)
	testing.expect(t, descriptor.valid_ranges == ranges_before)
	testing.expect_value(t, descriptor.raw_complete, raw_complete_before)
	testing.expect(t, descriptor.text == text_before)
	testing.expect_value(t, descriptor.generation, generation_before)
	testing.expect_value(t, descriptor.bytes_copied, bytes_before)
	testing.expect_value(t, descriptor.copy_duration_ns, duration_before)
	testing.expect(t, descriptor.legacy_update == update_before)
}

scanout_descriptor_test_set_owned_gsw :: proc(
	t: ^testing.T,
	descriptor: ^Scanout_Descriptor,
	format: contract.Pixel_Format,
	source: []u8,
	width: u32 = 1,
	height: u32 = 1,
) {
	bytes_per_pixel, known := contract.pixel_format_bytes(format)
	if !testing.expect(t, known) {return}
	full := contract.Rect {
		width  = width,
		height = height,
	}
	dirty, clips: contract.Rect_Set
	testing.expect(t, contract.rect_set_append(&dirty, full))
	testing.expect(t, contract.rect_set_append(&clips, full))
	mode_key := contract.Mode_Key {
		format = format,
		surface_extent = {width = width, height = height},
		canvas_extent = {width = width, height = height},
		source = full,
		destination = full,
	}
	present := contract.Gsw_Present {
		clip_mode = .Windowed,
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
		source_pitch = width * bytes_per_pixel,
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
		raw_complete = true,
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
	frame := scanout_test_expand_legacy(&descriptor)
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

	frame := scanout_test_expand_legacy(&descriptor)
	testing.expect(t, frame != nil)
	testing.expect_value(t, frame.kind, Display_Kind.Indexed_8)
	testing.expect_value(t, frame.pixels[0], u32(0xFFFF0000))
}

@(test)
scanout_descriptor_test_partial_vbe_capture_copies_and_converts_exact_pixel :: proc(
	t: ^testing.T,
) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	testing.expect(t, test_set_vbe_mode(&v, 4, 1, 32))
	v.vram[4], v.vram[5], v.vram[6], v.vram[7] = 0x11, 0x22, 0x33, 0
	testing.expect(t, vga_damage_acknowledge(&v, v.legacy_presentation_sequence))
	testing.expect(t, vga_mmio_write(&v, v.framebuffer_base + 4, 1, 0x44))

	descriptor: Scanout_Descriptor
	defer scanout_descriptor_destroy(&descriptor)
	testing.expect(t, scanout_descriptor_capture(&descriptor, &v))
	testing.expect_value(t, descriptor.bytes_copied, 4)
	testing.expect_value(t, descriptor.valid_ranges.count, u32(1))
	testing.expect_value(t, descriptor.valid_ranges.ranges[0], Vga_Damage_Range{4, 8})
	testing.expect_value(t, descriptor.legacy_update.header.dirty.count, u32(1))
	testing.expect_value(
		t,
		descriptor.legacy_update.header.dirty.rects[0],
		contract.Rect{1, 0, 1, 1},
	)
	for i in 0 ..< 8 {v.vram[i] = 0}
	frame := scanout_test_expand_legacy(&descriptor)
	if !testing.expect(t, frame != nil) {return}
	testing.expect_value(t, frame.updated_pixels, u64(1))
	testing.expect_value(t, frame.pixels[1], u32(0xFF332244))
	testing.expect_value(t, frame.pixels[0], u32(0))
}

@(test)
scanout_descriptor_test_fragment_budget_captures_and_converts_full_surface :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	testing.expect(t, test_set_vbe_mode(&v, 128, 1, 8))
	testing.expect(t, vga_damage_acknowledge(&v, v.legacy_presentation_sequence))
	for i in 0 ..< VGA_DAMAGE_MAX_PARTIAL_RANGES + 1 {
		testing.expect(t, vga_damage_record_backing_range(&v, u32(i * 2), 1))
	}
	vga_note_memory_change(&v)

	descriptor: Scanout_Descriptor
	defer scanout_descriptor_destroy(&descriptor)
	testing.expect(t, scanout_descriptor_capture(&descriptor, &v))
	testing.expect_value(t, descriptor.bytes_copied, scanout_required_vram(&v))
	testing.expect_value(
		t,
		descriptor.legacy_update.full_reason,
		contract.Damage_Full_Reason.Capacity_Exceeded,
	)
	testing.expect_value(
		t,
		descriptor.legacy_update.header.dirty,
		contract.rect_set_full({128, 1}),
	)
	frame := scanout_test_expand_legacy(&descriptor)
	if !testing.expect(t, frame != nil) {return}
	testing.expect_value(t, frame.updated_pixels, u64(128))
}

@(test)
scanout_descriptor_test_raw_vbe_expansion_matches_reference_pixel_hashes :: proc(t: ^testing.T) {
	bpps := [6]u16{4, 8, 15, 16, 24, 32}
	for bpp in bpps {
		v: Vga
		backing := test_vga_init(t, &v)
		if !testing.expect(t, backing != nil) {continue}
		width := u16(3)
		if bpp == 4 {width = 16}
		if !testing.expect(t, test_set_vbe_mode(&v, width, 2, bpp)) {
			vga_destroy(&v)
			delete(backing)
			continue
		}
		for i in 0 ..< 256 {
			v.vram[i] = u8((i * 37 + int(bpp)) & 0xFF)
			v.dac[i * 3] = u8(i & 0x3F)
			v.dac[i * 3 + 1] = u8((i * 3) & 0x3F)
			v.dac[i * 3 + 2] = u8((i * 5) & 0x3F)
		}
		vga_note_content_change(&v)
		reference := vga_display_frame(&v)
		if !testing.expect(t, reference != nil) {
			vga_destroy(&v)
			delete(backing)
			continue
		}
		reference_hash := scanout_test_pixel_hash(reference.pixels)

		descriptor: Scanout_Descriptor
		if testing.expect(t, scanout_descriptor_capture(&descriptor, &v)) {
			raw_before := make([]u8, descriptor.bytes_copied, context.temp_allocator)
			copy(raw_before, descriptor.vram[:descriptor.bytes_copied])
			state_before := descriptor.state
			journal_before := descriptor.journal
			ranges_before := descriptor.valid_ranges
			raw_complete_before := descriptor.raw_complete
			update_before := descriptor.legacy_update
			expanded := scanout_test_expand_legacy(&descriptor)
			if testing.expect(t, expanded != nil) {
				testing.expect_value(t, expanded.width, reference.width)
				testing.expect_value(t, expanded.height, reference.height)
				testing.expect_value(t, scanout_test_pixel_hash(expanded.pixels), reference_hash)
			}
			testing.expect(t, bytes.equal(raw_before, descriptor.vram[:descriptor.bytes_copied]))
			testing.expect(t, descriptor.state == state_before)
			testing.expect(t, descriptor.journal == journal_before)
			testing.expect(t, descriptor.valid_ranges == ranges_before)
			testing.expect_value(t, descriptor.raw_complete, raw_complete_before)
			testing.expect(t, descriptor.legacy_update == update_before)
		}
		scanout_descriptor_destroy(&descriptor)
		vga_destroy(&v)
		delete(backing)
	}
}

@(test)
scanout_descriptor_test_raw_legacy_modes_match_reference_frames :: proc(t: ^testing.T) {
	modes := [7]Scanout_Reference_Mode {
		.Text,
		.Planar,
		.Ega_Planar,
		.Chain_4,
		.Mode_X,
		.Cga_2,
		.Cga_1,
	}
	for mode in modes {
		v: Vga
		backing := test_vga_init(t, &v)
		if !testing.expect(t, backing != nil) {continue}
		switch mode {
		case .Text:
			_ = vga_mmio_write(&v, 0xB8000, 2, 0x0741)
			set_plane_byte(&v, 2, int('A') * 32, 0x80)
		case .Planar:
			test_graphics_geometry(&v, 8, 2)
			v.gfx[5] = 0
			set_plane_byte(&v, 0, 0, 0x80)
			set_plane_byte(&v, 2, 1, 0x40)
		case .Ega_Planar:
			test_bochs_legacy_mode(&v, 0x12)
			set_plane_byte(&v, 0, 0, 0x80)
			set_plane_byte(&v, 2, 1, 0x40)
		case .Chain_4:
			test_bochs_legacy_mode(&v, 0x13)
			for i in 0 ..< 16 {v.vram[i] = u8(i + 1)}
		case .Mode_X:
			test_graphics_geometry(&v, 8, 2)
			v.gfx[5] = 0x40
			for plane in 0 ..< 4 {set_plane_byte(&v, plane, 0, u8(plane + 1))}
		case .Cga_2:
			vga_out(&v, 0x3D8, CGA_MODE_GRAPHICS | CGA_MODE_VIDEO_ENABLE)
			_ = vga_mmio_write(&v, 0xB8000, 1, 0x6C)
		case .Cga_1:
			vga_out(&v, 0x3D8, CGA_MODE_GRAPHICS | CGA_MODE_HIGH_RES | CGA_MODE_VIDEO_ENABLE)
			vga_out(&v, 0x3D9, 0x0F)
			_ = vga_mmio_write(&v, 0xB8000, 1, 0x80)
		}
		scanout_test_expect_reference_equivalence(t, &v)
		vga_destroy(&v)
		delete(backing)
	}
}

@(test)
scanout_descriptor_test_palette_only_copies_raw_vram_without_conversion :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	testing.expect(t, test_set_vbe_mode(&v, 2, 1, 8))
	v.vram[0], v.vram[1] = 1, 2
	v.dac[3], v.dac[4], v.dac[5] = 0x3F, 0, 0
	v.dac[6], v.dac[7], v.dac[8] = 0, 0x3F, 0
	testing.expect(t, vga_damage_acknowledge(&v, v.legacy_presentation_sequence))
	vga_note_palette_change(&v)

	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)
	descriptor: Scanout_Descriptor
	descriptor.allocator = mem.tracking_allocator(&tracker)
	defer scanout_descriptor_destroy(&descriptor)
	testing.expect(t, scanout_descriptor_capture(&descriptor, &v))
	testing.expect_value(t, descriptor.bytes_copied, scanout_required_vram(&v))
	testing.expect_value(t, tracker.total_allocation_count, i64(1))
	testing.expect_value(t, tracker.current_memory_allocated, i64(VRAM_SIZE))
	for i in 0 ..< 9 {v.dac[i] = 0}
	v.vram[0], v.vram[1] = 0, 0
	frame := scanout_test_expand_legacy(&descriptor)
	if !testing.expect(t, frame != nil) {return}
	testing.expect_value(t, frame.updated_pixels, u64(2))
	testing.expect_value(t, frame.pixels[0], u32(0xFFFF0000))
	testing.expect_value(t, frame.pixels[1], u32(0xFF00FF00))
}

@(test)
scanout_descriptor_test_empty_damage_performs_no_legacy_work :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	testing.expect(t, test_set_vbe_mode(&v, 2, 1, 32))
	testing.expect(t, vga_damage_acknowledge(&v, v.legacy_presentation_sequence))
	descriptor: Scanout_Descriptor
	defer scanout_descriptor_destroy(&descriptor)
	testing.expect(t, scanout_descriptor_capture(&descriptor, &v))
	testing.expect_value(t, descriptor.bytes_copied, 0)
	testing.expect(t, scanout_test_expand_legacy(&descriptor) == nil)
}

@(test)
scanout_descriptor_test_missing_valid_ranges_rejects_without_mutation :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	if !testing.expect(t, test_set_vbe_mode(&v, 2, 1, 32)) {return}
	v.vram[0], v.vram[1], v.vram[2] = 0x11, 0x22, 0x33
	vga_note_content_change(&v)
	descriptor: Scanout_Descriptor
	defer scanout_descriptor_destroy(&descriptor)
	if !testing.expect(t, scanout_descriptor_capture(&descriptor, &v)) {return}
	descriptor.valid_ranges = {}
	state_before := descriptor.state
	journal_before := descriptor.journal
	mode_before := descriptor.mode_observability
	text_before := descriptor.text
	update_before := descriptor.legacy_update
	raw_before := make([]u8, descriptor.bytes_copied, context.temp_allocator)
	copy(raw_before, descriptor.vram[:descriptor.bytes_copied])
	pixels: []u32
	frame: Display_Frame

	testing.expect(
		t,
		scanout_descriptor_expand_legacy(&descriptor, &pixels, &frame, context.allocator) == nil,
	)
	testing.expect(t, pixels == nil)
	testing.expect(t, descriptor.valid_ranges.count == 0)
	testing.expect(t, descriptor.state == state_before)
	testing.expect(t, descriptor.journal == journal_before)
	testing.expect(t, descriptor.mode_observability == mode_before)
	testing.expect(t, descriptor.text == text_before)
	testing.expect(t, descriptor.legacy_update == update_before)
	testing.expect(t, bytes.equal(raw_before, descriptor.vram[:descriptor.bytes_copied]))
}

@(test)
scanout_descriptor_test_large_vbe_planar_capture_exceeds_legacy_window :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	testing.expect(t, test_set_vbe_mode(&v, 1024, 1024, 4))
	testing.expect_value(t, scanout_required_vram(&v), 512 * 1024)
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
		{.Bgra_8888, {0x11, 0x22, 0x33, 0x44}, 4, 0xFF33_2211, .Xrgb_8888},
		{.Rgba_8888, {0x33, 0x22, 0x11, 0x44}, 4, 0xFF33_2211, .Xrgb_8888},
	}
	for &item in cases {
		surface_source := make([]u8, item.source_length * 6, context.temp_allocator)
		for pixel in 0 ..< 6 {
			copy(
				surface_source[pixel * item.source_length:(pixel + 1) * item.source_length],
				item.source[:item.source_length],
			)
		}
		descriptor: Scanout_Descriptor
		scanout_descriptor_test_set_owned_gsw(t, &descriptor, item.format, surface_source, 3, 2)
		descriptor.gsw_presentation.palette.entries[3] = 0x12
		descriptor.gsw_presentation.palette.entries[4] = 0x34
		descriptor.gsw_presentation.palette.entries[5] = 0x56
		descriptor.state.pel_mask = 0
		descriptor.state.dac[3] = 0x3F
		source_before := make(
			[]u8,
			len(descriptor.gsw_presentation.source),
			context.temp_allocator,
		)
		copy(source_before, descriptor.gsw_presentation.source)
		state_before := descriptor.state
		journal_before := descriptor.journal
		mode_before := descriptor.mode_observability
		text_before := descriptor.text
		generation_before := descriptor.generation
		bytes_before := descriptor.bytes_copied
		duration_before := descriptor.copy_duration_ns
		update_before := descriptor.legacy_update
		state_generation_before := descriptor.gsw_presentation.state_generation
		raw_complete_before := descriptor.gsw_presentation.raw_complete
		present_before := descriptor.gsw_presentation.present
		present_valid_before := descriptor.gsw_presentation.present_valid
		invalidation_before := descriptor.gsw_presentation.invalidation
		invalidation_valid_before := descriptor.gsw_presentation.invalidation_valid
		palette_before := descriptor.gsw_presentation.palette
		gsw_bytes_before := descriptor.gsw_presentation.bytes_copied
		gsw_duration_before := descriptor.gsw_presentation.copy_duration_ns
		damage_before := descriptor.gsw_presentation.damage_kind
		full_reason_before := descriptor.gsw_presentation.full_reason

		frame := scanout_test_expand_gsw(&descriptor)
		if testing.expect(t, frame != nil) {
			testing.expect_value(t, frame.kind, item.kind)
			testing.expect_value(t, frame.width, 3)
			testing.expect_value(t, frame.height, 2)
			testing.expect_value(t, frame.aspect_width, 3)
			testing.expect_value(t, frame.aspect_height, 2)
			testing.expect_value(t, frame.content_generation, u64(17))
			testing.expect_value(t, frame.updated_pixels, u64(6))
			for pixel in frame.pixels {testing.expect_value(t, pixel, item.expected)}
		}
		testing.expect(t, bytes.equal(source_before, descriptor.gsw_presentation.source))
		testing.expect(t, descriptor.state == state_before)
		testing.expect(t, descriptor.journal == journal_before)
		testing.expect(t, descriptor.mode_observability == mode_before)
		testing.expect(t, descriptor.text == text_before)
		testing.expect_value(t, descriptor.generation, generation_before)
		testing.expect_value(t, descriptor.bytes_copied, bytes_before)
		testing.expect_value(t, descriptor.copy_duration_ns, duration_before)
		testing.expect(t, descriptor.legacy_update == update_before)
		testing.expect_value(
			t,
			descriptor.gsw_presentation.state_generation,
			state_generation_before,
		)
		testing.expect_value(t, descriptor.gsw_presentation.raw_complete, raw_complete_before)
		testing.expect(t, descriptor.gsw_presentation.present == present_before)
		testing.expect_value(t, descriptor.gsw_presentation.present_valid, present_valid_before)
		testing.expect(t, descriptor.gsw_presentation.invalidation == invalidation_before)
		testing.expect_value(
			t,
			descriptor.gsw_presentation.invalidation_valid,
			invalidation_valid_before,
		)
		testing.expect(t, descriptor.gsw_presentation.palette == palette_before)
		testing.expect_value(t, descriptor.gsw_presentation.bytes_copied, gsw_bytes_before)
		testing.expect_value(t, descriptor.gsw_presentation.copy_duration_ns, gsw_duration_before)
		testing.expect_value(t, descriptor.gsw_presentation.damage_kind, damage_before)
		testing.expect_value(t, descriptor.gsw_presentation.full_reason, full_reason_before)
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

	frame := scanout_test_expand_gsw(&descriptor)

	if testing.expect(t, frame != nil) {
		testing.expect_value(t, frame.pixels[0], u32(0xFF80_4020))
	}
}

@(test)
scanout_descriptor_test_gsw_render_rejects_invalid_or_missing_record :: proc(t: ^testing.T) {
	testing.expect(t, scanout_test_expand_gsw(nil) == nil)
	descriptor: Scanout_Descriptor
	testing.expect(t, scanout_test_expand_gsw(&descriptor) == nil)
	descriptor.gsw_presentation.present_valid = true
	testing.expect(t, scanout_test_expand_gsw(&descriptor) == nil)
	descriptor.gsw_presentation.present.header.surface_extent = {
		width  = 1,
		height = 1,
	}
	descriptor.gsw_presentation.present.header.format = .Invalid
	testing.expect(t, scanout_test_expand_gsw(&descriptor) == nil)
	scanout_descriptor_destroy(&descriptor)
}

@(test)
scanout_descriptor_test_gsw_render_revalidates_mailbox_owned_layout :: proc(t: ^testing.T) {
	source := [4]u8{0x11, 0x22, 0x33, 0}
	descriptor: Scanout_Descriptor
	scanout_descriptor_test_set_owned_gsw(t, &descriptor, .Bgrx_8888, source[:])
	descriptor.gsw_presentation.present.header.ownership = .Vm_Framebuffer
	testing.expect(t, scanout_test_expand_gsw(&descriptor) == nil)
	scanout_descriptor_destroy(&descriptor)

	descriptor = {}
	scanout_descriptor_test_set_owned_gsw(t, &descriptor, .Bgrx_8888, source[:])
	descriptor.gsw_presentation.present.source_offset = 1
	testing.expect(t, scanout_test_expand_gsw(&descriptor) == nil)
	scanout_descriptor_destroy(&descriptor)

	descriptor = {}
	scanout_descriptor_test_set_owned_gsw(t, &descriptor, .Bgrx_8888, source[:])
	descriptor.gsw_presentation.present.source_pitch = 8
	present_before := descriptor.gsw_presentation.present
	palette_before := descriptor.gsw_presentation.palette
	source_before := make([]u8, len(descriptor.gsw_presentation.source), context.temp_allocator)
	copy(source_before, descriptor.gsw_presentation.source)
	testing.expect(t, scanout_test_expand_gsw(&descriptor) == nil)
	testing.expect(t, descriptor.gsw_presentation.present == present_before)
	testing.expect(t, descriptor.gsw_presentation.palette == palette_before)
	testing.expect(t, bytes.equal(source_before, descriptor.gsw_presentation.source))
	scanout_descriptor_destroy(&descriptor)

	descriptor = {}
	indexed := [1]u8{1}
	scanout_descriptor_test_set_owned_gsw(t, &descriptor, .Indexed_8, indexed[:])
	descriptor.gsw_presentation.palette.dac_bits = 6
	testing.expect(t, scanout_test_expand_gsw(&descriptor) == nil)
	scanout_descriptor_destroy(&descriptor)
}

@(test)
scanout_descriptor_test_destroy_clears_raw_source_but_not_consumer_pixels :: proc(t: ^testing.T) {
	descriptor: Scanout_Descriptor
	source := [4]u8{0x11, 0x22, 0x33, 0}
	scanout_descriptor_test_set_owned_gsw(t, &descriptor, .Bgrx_8888, source[:])
	pixels: []u32
	frame_storage: Display_Frame
	frame := scanout_descriptor_expand_gsw(&descriptor, &pixels, &frame_storage, context.allocator)
	testing.expect(t, frame != nil)
	testing.expect(t, descriptor.gsw_presentation.source != nil)
	testing.expect(t, pixels != nil)

	scanout_descriptor_destroy(&descriptor)
	testing.expect(t, descriptor.gsw_presentation.source == nil)
	testing.expect(t, pixels != nil)
	testing.expect(t, !descriptor.gsw_presentation.present_valid)
	delete(pixels)
}
