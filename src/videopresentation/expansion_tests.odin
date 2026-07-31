// SPDX-License-Identifier: GPL-3.0-only
package videopresentation

import presentation "../presentation"
import vga "../vga"
import "core:bytes"
import "core:testing"

expansion_test_pixel_hash :: proc(pixels: []u32) -> u64 {
	hash := u64(14_695_981_039_346_656_037)
	for pixel in pixels {
		for shift: u32 = 0; shift < 32; shift += 8 {
			hash = (hash ~ u64(u8(pixel >> shift))) * u64(1_099_511_628_211)
		}
	}
	return hash
}

expansion_test_set_gsw_descriptor :: proc(
	descriptor: ^vga.Scanout_Descriptor,
	source: []u8,
	dirty: presentation.Rect_Set,
	sequence: u64,
	lifecycle_generation: u64 = 1,
) {
	full := presentation.Rect{0, 0, 3, 1}
	mode_key := presentation.Mode_Key {
		format         = .Bgrx_8888,
		display_aspect = {3, 1},
		surface_extent = {3, 1},
		canvas_extent  = {3, 1},
		source         = full,
		destination    = full,
	}
	clips: presentation.Rect_Set
	_ = presentation.rect_set_append(&clips, full)
	descriptor.allocator = context.allocator
	descriptor.gsw_presentation = {
		allocator = context.allocator,
		present_valid = true,
		present = {
			clip_mode = .Windowed,
			header = {
				sequence = sequence,
				lifecycle_generation = lifecycle_generation,
				mode_generation = 1,
				mode_key = mode_key,
				identity_namespace = .Gsw2d,
				device_generation = 1,
				surface = {1, 1},
				format = .Bgrx_8888,
				display_aspect = mode_key.display_aspect,
				surface_extent = {3, 1},
				canvas_extent = {3, 1},
				source = full,
				destination = full,
				dirty = dirty,
				source_kind = .Gsw_Snapshot,
				ownership = .Mailbox_Surface,
			},
			clips = clips,
			source_pitch = 12,
		},
		source = make([]u8, len(source)),
		raw_complete = dirty.count == 1 && presentation.rect_equal(dirty.rects[0], full),
		bytes_copied = len(source),
		damage_kind = .Pixel_Memory,
	}
	copy(descriptor.gsw_presentation.source, source)
}

expansion_test_dispi_write :: proc(target: ^vga.Vga, index, value: u16) {
	vga.vga_io_write(target, vga.DISPI_PORT_INDEX, 2, u32(index))
	vga.vga_io_write(target, vga.DISPI_PORT_DATA, 2, u32(value))
}

expansion_test_set_mode :: proc(target: ^vga.Vga, width, height, bpp: u16) {
	expansion_test_dispi_write(target, vga.DISPI_INDEX_ENABLE, 0)
	expansion_test_dispi_write(target, vga.DISPI_INDEX_XRES, width)
	expansion_test_dispi_write(target, vga.DISPI_INDEX_YRES, height)
	expansion_test_dispi_write(target, vga.DISPI_INDEX_BPP, bpp)
	expansion_test_dispi_write(target, vga.DISPI_INDEX_VIRT_WIDTH, width)
	expansion_test_dispi_write(
		target,
		vga.DISPI_INDEX_ENABLE,
		vga.DISPI_ENABLED | vga.DISPI_NOCLEARMEM,
	)
}

@(test)
expansion_test_legacy_uses_immutable_raw_descriptor_after_source_changes :: proc(t: ^testing.T) {
	backing := make([]u8, vga.VRAM_SIZE)
	defer delete(backing)
	target: vga.Vga
	if !testing.expect(t, vga.vga_init(&target, backing)) {return}
	defer vga.vga_destroy(&target)
	expansion_test_set_mode(&target, 2, 1, 8)
	target.vram[0], target.vram[1] = 1, 2
	target.dac[3], target.dac[4], target.dac[5] = 0x3F, 0, 0
	target.dac[6], target.dac[7], target.dac[8] = 0, 0x3F, 0
	vga.vga_note_content_change(&target)

	descriptor: vga.Scanout_Descriptor
	defer vga.scanout_descriptor_destroy(&descriptor)
	if !testing.expect(t, vga.scanout_descriptor_capture(&descriptor, &target, 1)) {return}
	first_index := descriptor.vram[0]
	second_index := descriptor.vram[1]
	first_red := descriptor.state.dac[3]
	target.vram[0], target.vram[1] = 0, 0
	target.dac = {}

	expansion: Expansion
	defer expansion_destroy(&expansion)
	frame := expand_legacy_result(&expansion, &descriptor).frame
	if !testing.expect(t, frame != nil) {return}
	testing.expect_value(t, frame.updated_pixels, u64(2))
	testing.expect_value(t, frame.pixels[0], u32(0xFFFF0000))
	testing.expect_value(t, frame.pixels[1], u32(0xFF00FF00))
	testing.expect_value(t, descriptor.vram[0], first_index)
	testing.expect_value(t, descriptor.vram[1], second_index)
	testing.expect_value(t, descriptor.state.dac[3], first_red)
}

@(test)
expansion_test_palette_only_capture_remains_raw_until_host_expansion :: proc(t: ^testing.T) {
	backing := make([]u8, vga.VRAM_SIZE)
	defer delete(backing)
	target: vga.Vga
	if !testing.expect(t, vga.vga_init(&target, backing)) {return}
	defer vga.vga_destroy(&target)
	expansion_test_set_mode(&target, 2, 1, 8)
	target.vram[0], target.vram[1] = 1, 2
	target.dac[3], target.dac[4], target.dac[5] = 0x3F, 0, 0
	target.dac[6], target.dac[7], target.dac[8] = 0, 0x3F, 0
	vga.vga_note_content_change(&target)
	if !testing.expect(
		t,
		vga.vga_damage_acknowledge(&target, target.legacy_presentation_sequence),
	) {
		return
	}
	vga.vga_io_write(&target, 0x3C8, 1, 1)
	vga.vga_io_write(&target, 0x3C9, 1, 0x3E)

	descriptor: vga.Scanout_Descriptor
	defer vga.scanout_descriptor_destroy(&descriptor)
	if !testing.expect(t, vga.scanout_descriptor_capture(&descriptor, &target, 1)) {return}
	testing.expect_value(
		t,
		descriptor.legacy_update.damage_kind,
		presentation.Damage_Kind.Palette_Only,
	)
	testing.expect(t, descriptor.bytes_copied > 0)

	expansion: Expansion
	defer expansion_destroy(&expansion)
	frame := expand_legacy_result(&expansion, &descriptor).frame
	if !testing.expect(t, frame != nil) {return}
	testing.expect_value(t, frame.updated_pixels, u64(2))
}

@(test)
expansion_test_legacy_full_then_coalesced_partial_preserves_complete_frame :: proc(t: ^testing.T) {
	backing := make([]u8, vga.VRAM_SIZE)
	defer delete(backing)
	target: vga.Vga
	if !testing.expect(t, vga.vga_init(&target, backing)) {return}
	defer vga.vga_destroy(&target)
	expansion_test_set_mode(&target, 4, 1, 32)
	copy(
		target.vram[:16],
		[]u8{0x11, 0x22, 0x33, 0, 0x21, 0x32, 0x43, 0, 0x31, 0x42, 0x53, 0, 0x41, 0x52, 0x63, 0},
	)
	vga.vga_note_content_change(&target)

	descriptor: vga.Scanout_Descriptor
	defer vga.scanout_descriptor_destroy(&descriptor)
	if !testing.expect(t, vga.scanout_descriptor_capture(&descriptor, &target, 1)) {return}
	expansion: Expansion
	defer expansion_destroy(&expansion)
	seed := expand_legacy_result(&expansion, &descriptor).frame
	if !testing.expect(t, seed != nil) {return}
	seed_storage := &expansion.legacy_pixels[0]
	if !testing.expect(
		t,
		vga.vga_damage_acknowledge(&target, target.legacy_presentation_sequence),
	) {
		return
	}

	if !testing.expect(t, vga.vga_mmio_write(&target, target.framebuffer_base + 4, 1, 0x44)) {
		return
	}
	if !testing.expect(t, vga.scanout_descriptor_capture(&descriptor, &target, 1)) {return}
	if !testing.expect(t, vga.vga_mmio_write(&target, target.framebuffer_base + 8, 1, 0x55)) {
		return
	}
	if !testing.expect(t, vga.scanout_descriptor_capture(&descriptor, &target, 1)) {return}
	testing.expect_value(t, descriptor.legacy_update.header.dirty.count, u32(1))
	testing.expect_value(
		t,
		descriptor.legacy_update.header.dirty.rects[0],
		presentation.Rect{1, 0, 2, 1},
	)
	testing.expect_value(t, descriptor.valid_ranges.count, u32(1))
	testing.expect_value(t, descriptor.valid_ranges.ranges[0].start, u32(4))
	testing.expect_value(t, descriptor.valid_ranges.ranges[0].end, u32(12))
	reference := vga.vga_display_frame(&target)
	if !testing.expect(t, reference != nil) {return}
	reference_hash := expansion_test_pixel_hash(reference.pixels)
	raw_before := make([]u8, 8, context.temp_allocator)
	copy(raw_before, descriptor.vram[4:12])
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

	frame := expand_legacy_result(&expansion, &descriptor).frame
	if !testing.expect(t, frame != nil) {return}
	testing.expect(t, &expansion.legacy_pixels[0] == seed_storage)
	testing.expect_value(t, expansion_test_pixel_hash(frame.pixels), reference_hash)
	testing.expect_value(t, frame.pixels[0], u32(0xFF33_2211))
	testing.expect_value(t, frame.pixels[1], u32(0xFF43_3244))
	testing.expect_value(t, frame.pixels[2], u32(0xFF53_4255))
	testing.expect_value(t, frame.pixels[3], u32(0xFF63_5241))
	testing.expect(t, bytes.equal(raw_before, descriptor.vram[4:12]))
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
	repeated := expand_legacy_result(&expansion, &descriptor).frame
	if !testing.expect(t, repeated != nil) {return}
	testing.expect_value(t, expansion_test_pixel_hash(repeated.pixels), reference_hash)
	testing.expect(t, bytes.equal(raw_before, descriptor.vram[4:12]))
	testing.expect(t, descriptor.valid_ranges == ranges_before)
}

@(test)
expansion_test_gsw_full_then_coalesced_partial_preserves_complete_frame :: proc(t: ^testing.T) {
	full_dirty := presentation.rect_set_full({3, 1})
	full_source := []u8{0x11, 0x22, 0x33, 0, 0x21, 0x32, 0x43, 0, 0x31, 0x42, 0x53, 0}
	descriptor: vga.Scanout_Descriptor
	defer vga.scanout_descriptor_destroy(&descriptor)
	expansion_test_set_gsw_descriptor(&descriptor, full_source, full_dirty, 1)
	expansion: Expansion
	defer expansion_destroy(&expansion)
	seed := expand_gsw(&expansion, &descriptor)
	if !testing.expect(t, seed != nil) {return}
	seed_storage := &expansion.gsw_pixels[0]

	coalesced_dirty: presentation.Rect_Set
	_ = presentation.rect_set_append(&coalesced_dirty, {1, 0, 1, 1})
	coalesced_source := []u8{0, 0, 0, 0, 0x44, 0x32, 0x43, 0, 0, 0, 0, 0}
	vga.gsw_presentation_descriptor_destroy(&descriptor.gsw_presentation)
	expansion_test_set_gsw_descriptor(&descriptor, coalesced_source, coalesced_dirty, 2)
	testing.expect_value(t, descriptor.gsw_presentation.present.header.sequence, u64(2))

	partial_dirty: presentation.Rect_Set
	_ = presentation.rect_set_append(&partial_dirty, {1, 0, 2, 1})
	partial_source := []u8{0, 0, 0, 0, 0x44, 0x32, 0x43, 0, 0x55, 0x42, 0x53, 0}
	vga.gsw_presentation_descriptor_destroy(&descriptor.gsw_presentation)
	expansion_test_set_gsw_descriptor(&descriptor, partial_source, partial_dirty, 3)
	source_before := make([]u8, len(descriptor.gsw_presentation.source), context.temp_allocator)
	copy(source_before, descriptor.gsw_presentation.source)
	present_before := descriptor.gsw_presentation.present
	raw_complete_before := descriptor.gsw_presentation.raw_complete
	bytes_before := descriptor.gsw_presentation.bytes_copied
	damage_before := descriptor.gsw_presentation.damage_kind
	frame := expand_gsw(&expansion, &descriptor)
	if !testing.expect(t, frame != nil) {return}
	testing.expect(t, &expansion.gsw_pixels[0] == seed_storage)
	testing.expect_value(t, frame.pixels[0], u32(0xFF33_2211))
	testing.expect_value(t, frame.pixels[1], u32(0xFF43_3244))
	testing.expect_value(t, frame.pixels[2], u32(0xFF53_4255))
	testing.expect_value(
		t,
		expansion_test_pixel_hash(frame.pixels),
		expansion_test_pixel_hash([]u32{0xFF33_2211, 0xFF43_3244, 0xFF53_4255}),
	)
	testing.expect(t, bytes.equal(source_before, descriptor.gsw_presentation.source))
	testing.expect(t, descriptor.gsw_presentation.present == present_before)
	testing.expect_value(t, descriptor.gsw_presentation.raw_complete, raw_complete_before)
	testing.expect_value(t, descriptor.gsw_presentation.bytes_copied, bytes_before)
	testing.expect_value(t, descriptor.gsw_presentation.damage_kind, damage_before)
	repeated := expand_gsw(&expansion, &descriptor)
	if !testing.expect(t, repeated != nil) {return}
	testing.expect_value(
		t,
		expansion_test_pixel_hash(repeated.pixels),
		expansion_test_pixel_hash([]u32{0xFF33_2211, 0xFF43_3244, 0xFF53_4255}),
	)
	testing.expect(t, bytes.equal(source_before, descriptor.gsw_presentation.source))
	testing.expect(t, descriptor.gsw_presentation.present == present_before)
}

@(test)
expansion_test_legacy_partial_without_baseline_requests_full_capture :: proc(t: ^testing.T) {
	backing := make([]u8, vga.VRAM_SIZE)
	defer delete(backing)
	target: vga.Vga
	if !testing.expect(t, vga.vga_init(&target, backing)) {return}
	defer vga.vga_destroy(&target)
	expansion_test_set_mode(&target, 2, 1, 32)
	copy(target.vram[:8], []u8{0x11, 0x22, 0x33, 0, 0x21, 0x32, 0x43, 0})
	vga.vga_note_content_change(&target)
	descriptor: vga.Scanout_Descriptor
	defer vga.scanout_descriptor_destroy(&descriptor)
	if !testing.expect(t, vga.scanout_descriptor_capture(&descriptor, &target, 1)) {return}
	expansion: Expansion
	defer expansion_destroy(&expansion)
	seed := expand_legacy_result(&expansion, &descriptor).frame
	if !testing.expect(t, seed != nil) {return}
	seed_hash := expansion_test_pixel_hash(seed.pixels)
	if !testing.expect(
		t,
		vga.vga_damage_acknowledge(&target, target.legacy_presentation_sequence),
	) {
		return
	}
	if !testing.expect(t, vga.vga_mmio_write(&target, target.framebuffer_base + 4, 1, 0x44)) {
		return
	}
	if !testing.expect(t, vga.scanout_descriptor_capture(&descriptor, &target, 1)) {return}
	testing.expect(t, !descriptor.raw_complete)
	recovery: Expansion
	defer expansion_destroy(&recovery)
	partial := expand_legacy_result(&recovery, &descriptor)
	testing.expect_value(t, partial.status, Expansion_Status.Needs_Full_Baseline)
	testing.expect(t, partial.frame == nil)
	testing.expect_value(t, expansion_test_pixel_hash(expansion.legacy_pixels), seed_hash)
	testing.expect_value(t, expansion.legacy_baseline.header.lifecycle_generation, u64(1))

	vga.vga_note_content_change(&target)
	if !testing.expect(t, vga.scanout_descriptor_capture(&descriptor, &target, 1)) {return}
	testing.expect(t, descriptor.raw_complete)
	result := expand_legacy_result(&recovery, &descriptor)
	testing.expect_value(t, result.status, Expansion_Status.Ready)
	frame := result.frame
	if !testing.expect(t, frame != nil) {return}
	testing.expect_value(t, frame.pixels[1], u32(0xFF43_3244))
	testing.expect_value(t, recovery.legacy_baseline.header.lifecycle_generation, u64(1))
}

@(test)
expansion_test_gsw_lifecycle_change_requires_complete_raw_baseline :: proc(t: ^testing.T) {
	full_dirty := presentation.rect_set_full({3, 1})
	full_source := []u8{0x11, 0x22, 0x33, 0, 0x21, 0x32, 0x43, 0, 0x31, 0x42, 0x53, 0}
	descriptor: vga.Scanout_Descriptor
	defer vga.scanout_descriptor_destroy(&descriptor)
	expansion_test_set_gsw_descriptor(&descriptor, full_source, full_dirty, 1, 1)
	expansion: Expansion
	defer expansion_destroy(&expansion)
	seed := expand_gsw(&expansion, &descriptor)
	if !testing.expect(t, seed != nil) {return}
	seed_hash := expansion_test_pixel_hash(seed.pixels)

	partial_dirty: presentation.Rect_Set
	_ = presentation.rect_set_append(&partial_dirty, {1, 0, 1, 1})
	partial_source := []u8{0, 0, 0, 0, 0x44, 0x32, 0x43, 0, 0, 0, 0, 0}
	vga.gsw_presentation_descriptor_destroy(&descriptor.gsw_presentation)
	expansion_test_set_gsw_descriptor(&descriptor, partial_source, partial_dirty, 2, 2)
	testing.expect(t, !descriptor.gsw_presentation.raw_complete)
	testing.expect(t, expand_gsw(&expansion, &descriptor) == nil)
	testing.expect_value(t, expansion_test_pixel_hash(expansion.gsw_pixels), seed_hash)
	testing.expect_value(t, expansion.gsw_baseline.header.lifecycle_generation, u64(1))

	full_source[4] = 0x44
	vga.gsw_presentation_descriptor_destroy(&descriptor.gsw_presentation)
	expansion_test_set_gsw_descriptor(&descriptor, full_source, full_dirty, 3, 2)
	frame := expand_gsw(&expansion, &descriptor)
	if !testing.expect(t, frame != nil) {return}
	testing.expect_value(t, frame.pixels[1], u32(0xFF43_3244))
	testing.expect_value(t, expansion.gsw_baseline.header.lifecycle_generation, u64(2))
}
