// SPDX-License-Identifier: GPL-3.0-only
package vga

import contract "../presentation"
import "core:testing"

damage_test_vga :: proc(t: ^testing.T, v: ^Vga) -> []u8 {
	backing := test_vga_init(t, v)
	v.legacy_damage = {}
	return backing
}

@(test)
vga_damage_test_packed_vbe_maps_exact_pixels_and_rows :: proc(t: ^testing.T) {
	v: Vga
	backing := damage_test_vga(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	testing.expect(t, test_set_vbe_mode(&v, 4, 2, 32))
	v.legacy_damage = {}
	_ = vga_damage_record_backing_range(&v, 4 * 4 + 2 * 4 + 1, 1)
	damage := vga_damage_snapshot(&v)
	testing.expect_value(t, damage.kind, contract.Damage_Kind.Pixel_Memory)
	testing.expect_value(t, damage.full_reason, contract.Damage_Full_Reason.None)
	testing.expect_value(t, damage.rects.count, u32(1))
	testing.expect_value(t, damage.rects.rects[0], contract.Rect{2, 1, 1, 1})

	v.legacy_damage = {}
	_ = vga_damage_record_backing_range(&v, 15, 2)
	damage = vga_damage_snapshot(&v)
	testing.expect_value(t, damage.rects.count, u32(2))
	testing.expect_value(t, damage.rects.rects[0], contract.Rect{3, 0, 1, 1})
	testing.expect_value(t, damage.rects.rects[1], contract.Rect{0, 1, 1, 1})
}

@(test)
vga_damage_test_vbe_planar_maps_one_byte_to_eight_pixels :: proc(t: ^testing.T) {
	v: Vga
	backing := damage_test_vga(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	testing.expect(t, test_set_vbe_mode(&v, 16, 2, 4))
	v.legacy_damage = {}
	_ = vga_damage_record_backing_range(&v, 2, 1)
	damage := vga_damage_snapshot(&v)
	testing.expect_value(t, damage.full_reason, contract.Damage_Full_Reason.None)
	testing.expect_value(t, damage.rects.count, u32(1))
	testing.expect_value(t, damage.rects.rects[0], contract.Rect{0, 0, 8, 1})
}

@(test)
vga_damage_test_planar_and_mode_x_use_physical_plane_identity :: proc(t: ^testing.T) {
	v: Vga
	backing := damage_test_vga(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_graphics_geometry(&v, 16, 2)
	v.gfx[5] = 0
	v.crtc[0x17] = 0x43
	v.crtc[0x13] = 1
	v.legacy_damage = {}
	_ = vga_damage_record_backing_range(&v, 1, 1)
	damage := vga_damage_snapshot(&v)
	testing.expect_value(t, damage.rects.count, u32(1))
	testing.expect_value(t, damage.rects.rects[0], contract.Rect{0, 0, 8, 1})

	v.gfx[5] = 0x40
	v.seq[4] = 0x06
	v.legacy_damage = {}
	_ = vga_damage_record_backing_range(&v, 2, 1)
	damage = vga_damage_snapshot(&v)
	testing.expect_value(t, damage.rects.count, u32(1))
	testing.expect_value(t, damage.rects.rects[0], contract.Rect{2, 0, 1, 1})
}

@(test)
vga_damage_test_planar_source_groups_respect_panning_boundary :: proc(t: ^testing.T) {
	v: Vga
	backing := damage_test_vga(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_graphics_geometry(&v, 16, 1)
	v.gfx[5] = 0
	v.crtc[0x17] = 0x43
	v.attr[0x13] = 3
	v.legacy_damage = {}
	_ = vga_damage_record_backing_range(&v, 1, 1)
	damage := vga_damage_snapshot(&v)
	testing.expect_value(t, damage.rects.count, u32(1))
	testing.expect_value(t, damage.rects.rects[0], contract.Rect{0, 0, 5, 1})
}

@(test)
vga_damage_test_mode_x_sorted_ranges_keep_separated_pixels :: proc(t: ^testing.T) {
	v: Vga
	backing := damage_test_vga(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_graphics_geometry(&v, 32, 1)
	v.gfx[5] = 0x40
	v.seq[4] = 0x06
	v.crtc[0x17] = 0x43
	v.legacy_damage = {}
	_ = vga_damage_record_backing_range(&v, 14, 1)
	_ = vga_damage_record_backing_range(&v, 1, 1)
	damage := vga_damage_snapshot(&v)
	testing.expect_value(t, damage.rects.count, u32(2))
	testing.expect_value(t, damage.rects.rects[0], contract.Rect{1, 0, 1, 1})
	testing.expect_value(t, damage.rects.rects[1], contract.Rect{14, 0, 1, 1})
}

@(test)
vga_damage_test_text_and_cga_source_groups_map_exact_visible_spans :: proc(t: ^testing.T) {
	v: Vga
	backing := damage_test_vga(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	v.attr[0x13] = 4
	v.legacy_damage = {}
	_ = vga_damage_record_backing_range(&v, 0, 1)
	damage := vga_damage_snapshot(&v)
	testing.expect_value(t, damage.rects.count, u32(1))
	testing.expect_value(t, damage.rects.rects[0], contract.Rect{0, 0, 5, 16})

	vga_out(&v, 0x3D8, CGA_MODE_GRAPHICS | CGA_MODE_VIDEO_ENABLE)
	v.legacy_damage = {}
	_ = vga_damage_record_backing_range(&v, 0, 1)
	damage = vga_damage_snapshot(&v)
	testing.expect_value(t, damage.rects.count, u32(1))
	testing.expect_value(t, damage.rects.rects[0], contract.Rect{0, 0, 4, 1})

	vga_out(&v, 0x3D8, CGA_MODE_GRAPHICS | CGA_MODE_HIGH_RES | CGA_MODE_VIDEO_ENABLE)
	v.legacy_damage = {}
	_ = vga_damage_record_backing_range(&v, 0, 1)
	damage = vga_damage_snapshot(&v)
	testing.expect_value(t, damage.rects.count, u32(1))
	testing.expect_value(t, damage.rects.rects[0], contract.Rect{0, 0, 8, 1})
}

@(test)
vga_damage_test_palette_is_separate_and_direct_color_is_unchanged :: proc(t: ^testing.T) {
	v: Vga
	backing := damage_test_vga(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	testing.expect(t, test_set_vbe_mode(&v, 4, 2, 8))
	v.legacy_damage = {}
	testing.expect(t, vga_damage_record_palette(&v))
	damage := vga_damage_snapshot(&v)
	testing.expect_value(t, damage.kind, contract.Damage_Kind.Palette_Only)
	testing.expect_value(t, damage.rects, contract.rect_set_full({4, 2}))

	testing.expect(t, test_set_vbe_mode(&v, 4, 2, 32))
	v.legacy_damage = {}
	sequence := v.legacy_presentation_sequence
	vga_io_write(&v, 0x3C8, 1, 1)
	vga_io_write(&v, 0x3C9, 1, 0x3F)
	testing.expect_value(t, v.legacy_presentation_sequence, sequence)
	testing.expect_value(t, vga_damage_snapshot(&v), contract.Damage_Record{})
}

@(test)
vga_damage_test_graphics_time_is_not_false_damage_and_start_latches :: proc(t: ^testing.T) {
	v: Vga
	backing := damage_test_vga(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	testing.expect(t, test_set_vbe_mode(&v, 4, 2, 32))
	v.legacy_damage = {}
	sequence := v.legacy_presentation_sequence
	vga_sync_to(&v, 500_000_001)
	testing.expect_value(t, v.legacy_presentation_sequence, sequence)
	testing.expect_value(t, vga_damage_snapshot(&v), contract.Damage_Record{})

	test_dispi_write(&v, DISPI_INDEX_ENABLE, 0)
	v.legacy_damage = {}
	sequence = v.legacy_presentation_sequence
	v.crtc[0x0C], v.crtc[0x0D] = 0, 1
	v.pending_start = 1
	v.start_pending = true
	latch_display_start(&v)
	testing.expect(t, v.legacy_presentation_sequence != sequence)
	damage := vga_damage_snapshot(&v)
	testing.expect_value(t, damage.full_reason, contract.Damage_Full_Reason.Mode_Boundary)
}

@(test)
vga_damage_test_acknowledgement_requires_exact_presentation_identity :: proc(t: ^testing.T) {
	v: Vga
	backing := damage_test_vga(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	testing.expect(t, test_set_vbe_mode(&v, 4, 2, 32))
	vga_note_content_change(&v)
	update := vga_legacy_frame_update(&v)
	testing.expect(t, update.header.sequence != 0)
	testing.expect(
		t,
		!vga_damage_acknowledge_identity(
			&v,
			update.header.sequence,
			update.header.mode_generation,
			update.header.surface.id,
			contract.generation_next(update.header.surface.generation),
		),
	)
	testing.expect(t, vga_damage_snapshot(&v).kind != .Invalid)
	testing.expect(
		t,
		vga_damage_acknowledge_identity(
			&v,
			update.header.sequence,
			update.header.mode_generation,
			update.header.surface.id,
			update.header.surface.generation,
		),
	)
	testing.expect_value(t, vga_damage_snapshot(&v), contract.Damage_Record{})
}

@(test)
vga_damage_test_acknowledgement_preserves_writes_after_capture :: proc(t: ^testing.T) {
	v: Vga
	backing := damage_test_vga(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	testing.expect(t, test_set_vbe_mode(&v, 4, 2, 32, DISPI_NOCLEARMEM | DISPI_LFB_ENABLED))
	vga_note_content_change(&v)
	initial := vga_legacy_frame_update(&v)
	testing.expect(
		t,
		vga_damage_acknowledge_identity(
			&v,
			initial.header.sequence,
			initial.header.mode_generation,
			initial.header.surface.id,
			initial.header.surface.generation,
		),
	)

	testing.expect(t, vga_mmio_write(&v, VBE_LFB_BASE, 1, 0x51))
	captured := vga_legacy_frame_update(&v)
	testing.expect_value(t, captured.header.dirty.rects[0], contract.Rect{0, 0, 1, 1})
	testing.expect(t, vga_mmio_write(&v, VBE_LFB_BASE + 28, 1, 0x71))
	testing.expect(t, v.legacy_presentation_sequence != captured.header.sequence)
	testing.expect(
		t,
		vga_damage_acknowledge_identity(
			&v,
			captured.header.sequence,
			captured.header.mode_generation,
			captured.header.surface.id,
			captured.header.surface.generation,
		),
	)
	remaining := vga_damage_snapshot(&v)
	testing.expect_value(t, remaining.rects.count, u32(1))
	testing.expect_value(t, remaining.rects.rects[0], contract.Rect{3, 1, 1, 1})
}

@(test)
vga_damage_test_oldest_ack_at_batch_capacity_preserves_pending_write :: proc(t: ^testing.T) {
	v: Vga
	backing := damage_test_vga(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	testing.expect(t, test_set_vbe_mode(&v, 6, 1, 32, DISPI_NOCLEARMEM | DISPI_LFB_ENABLED))
	vga_note_content_change(&v)
	initial := vga_legacy_frame_update(&v)
	testing.expect(
		t,
		vga_damage_acknowledge_identity(
			&v,
			initial.header.sequence,
			initial.header.mode_generation,
			initial.header.surface.id,
			initial.header.surface.generation,
		),
	)

	oldest: contract.Legacy_Frame_Update
	for x in 0 ..< VGA_DAMAGE_MAX_BATCHES {
		testing.expect(t, vga_mmio_write(&v, VBE_LFB_BASE + u64(x * 4), 1, u32(x + 1)))
		captured := vga_legacy_frame_update(&v)
		if x == 0 {oldest = captured}
	}
	testing.expect_value(t, v.legacy_damage_batch_count, u32(VGA_DAMAGE_MAX_BATCHES))
	testing.expect(t, vga_mmio_write(&v, VBE_LFB_BASE + 16, 1, 0x61))
	testing.expect(
		t,
		vga_damage_acknowledge_identity(
			&v,
			oldest.header.sequence,
			oldest.header.mode_generation,
			oldest.header.surface.id,
			oldest.header.surface.generation,
		),
	)
	remaining := vga_damage_snapshot(&v)
	testing.expect_value(t, remaining.rects.count, u32(1))
	testing.expect_value(t, remaining.rects.rects[0], contract.Rect{1, 0, 4, 1})
}

@(test)
vga_damage_test_reset_discards_preceding_batches :: proc(t: ^testing.T) {
	v: Vga
	backing := damage_test_vga(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	testing.expect(t, test_set_vbe_mode(&v, 4, 2, 32, DISPI_NOCLEARMEM | DISPI_LFB_ENABLED))
	vga_note_content_change(&v)
	initial := vga_legacy_frame_update(&v)
	testing.expect(
		t,
		vga_damage_acknowledge_identity(
			&v,
			initial.header.sequence,
			initial.header.mode_generation,
			initial.header.surface.id,
			initial.header.surface.generation,
		),
	)
	testing.expect(t, vga_mmio_write(&v, VBE_LFB_BASE, 1, 0x51))
	preceding := vga_legacy_frame_update(&v)
	testing.expect_value(t, v.legacy_damage_batch_count, u32(1))

	vga_reset(&v)
	testing.expect_value(t, v.legacy_damage_batch_count, u32(0))
	reset_damage := vga_damage_snapshot(&v)
	testing.expect_value(t, reset_damage.full_reason, contract.Damage_Full_Reason.Initial_Surface)
	_, width, height := display_geometry(&v)
	testing.expect_value(t, reset_damage.rects, contract.rect_set_full({u32(width), u32(height)}))
	testing.expect(
		t,
		!vga_damage_acknowledge_identity(
			&v,
			preceding.header.sequence,
			preceding.header.mode_generation,
			preceding.header.surface.id,
			preceding.header.surface.generation,
		),
	)
}

@(test)
vga_damage_test_full_and_palette_accumulation_is_order_independent :: proc(t: ^testing.T) {
	v: Vga
	backing := damage_test_vga(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	testing.expect(t, test_set_vbe_mode(&v, 4, 2, 8))

	v.legacy_damage = {}
	_ = vga_damage_record_palette(&v)
	vga_damage_record_full(&v, .Pixel_Memory, .Mode_Boundary)
	palette_then_full := vga_damage_snapshot(&v)
	v.legacy_damage = {}
	vga_damage_record_full(&v, .Pixel_Memory, .Mode_Boundary)
	_ = vga_damage_record_palette(&v)
	full_then_palette := vga_damage_snapshot(&v)
	testing.expect_value(t, palette_then_full.kind, contract.Damage_Kind.Pixel_And_Palette)
	testing.expect_value(t, palette_then_full, full_then_palette)

	v.legacy_damage = {}
	vga_damage_record_full(&v, .Pixel_Memory, .Ambiguous_Mapping)
	vga_damage_record_full(&v, .Pixel_Memory, .Capacity_Exceeded)
	forward := vga_damage_snapshot(&v)
	v.legacy_damage = {}
	vga_damage_record_full(&v, .Pixel_Memory, .Capacity_Exceeded)
	vga_damage_record_full(&v, .Pixel_Memory, .Ambiguous_Mapping)
	reverse := vga_damage_snapshot(&v)
	testing.expect_value(t, forward, reverse)
	testing.expect_value(t, forward.full_reason, contract.Damage_Full_Reason.Capacity_Exceeded)
}

@(test)
vga_damage_test_attribute_mode_control_is_not_palette_only :: proc(t: ^testing.T) {
	v: Vga
	backing := damage_test_vga(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	testing.expect(t, test_set_vbe_mode(&v, 4, 2, 8))
	_ = vga_io_read(&v, 0x3DA, 1)
	vga_io_write(&v, 0x3C0, 1, 0x30)
	v.legacy_damage = {}
	vga_io_write(&v, 0x3C0, 1, u32(v.attr[16] ~ u8(0x08)))
	damage := vga_damage_snapshot(&v)
	testing.expect_value(t, damage.kind, contract.Damage_Kind.Pixel_Memory)
	testing.expect_value(t, damage.full_reason, contract.Damage_Full_Reason.Mode_Boundary)
}

@(test)
vga_damage_test_fragmented_ranges_fall_back_before_mapping :: proc(t: ^testing.T) {
	v: Vga
	backing := damage_test_vga(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	testing.expect(t, test_set_vbe_mode(&v, 128, 1, 8))
	v.legacy_damage = {}
	for i in 0 ..< VGA_DAMAGE_MAX_PARTIAL_RANGES {
		testing.expect(t, vga_damage_record_backing_range(&v, u32(i * 2), 1))
	}
	partial := vga_damage_snapshot(&v)
	testing.expect_value(t, partial.full_reason, contract.Damage_Full_Reason.None)
	testing.expect_value(t, partial.rects.count, u32(VGA_DAMAGE_MAX_PARTIAL_RANGES))

	testing.expect(
		t,
		vga_damage_record_backing_range(&v, u32(VGA_DAMAGE_MAX_PARTIAL_RANGES * 2), 1),
	)
	full := vga_damage_snapshot(&v)
	testing.expect_value(t, full.full_reason, contract.Damage_Full_Reason.Capacity_Exceeded)
	testing.expect_value(t, full.rects, contract.rect_set_full({128, 1}))
}

@(test)
vga_damage_test_accumulated_fragment_budget_and_acknowledgement :: proc(t: ^testing.T) {
	v: Vga
	backing := damage_test_vga(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	testing.expect(t, test_set_vbe_mode(&v, 128, 1, 8))
	v.legacy_damage = {}
	for i in 0 ..< 16 {
		testing.expect(t, vga_damage_record_backing_range(&v, u32(i * 2), 1))
	}
	testing.expect(t, vga_damage_seal_pending(&v, 1))
	for i in 16 ..< 33 {
		testing.expect(t, vga_damage_record_backing_range(&v, u32(i * 2), 1))
	}
	testing.expect_value(
		t,
		vga_damage_snapshot(&v).full_reason,
		contract.Damage_Full_Reason.Capacity_Exceeded,
	)
	testing.expect(t, vga_damage_acknowledge(&v, 1))
	remaining := vga_damage_snapshot(&v)
	testing.expect_value(t, remaining.full_reason, contract.Damage_Full_Reason.None)
	testing.expect_value(t, remaining.rects.count, u32(17))
}

@(test)
vga_damage_test_mapped_rect_budget_falls_back_after_expansion :: proc(t: ^testing.T) {
	v: Vga
	backing := damage_test_vga(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	testing.expect(t, test_set_vbe_mode(&v, 4, 64, 8))
	v.legacy_damage = {}
	for i in 0 ..< 17 {
		start := u32(i * 3 * 4 + 3)
		testing.expect(t, vga_damage_record_backing_range(&v, start, 2))
	}
	testing.expect_value(t, v.legacy_damage.range_count, u32(17))
	damage := vga_damage_snapshot(&v)
	testing.expect_value(t, damage.full_reason, contract.Damage_Full_Reason.Capacity_Exceeded)
	testing.expect_value(t, damage.rects, contract.rect_set_full({4, 64}))
}

@(test)
vga_damage_test_backing_range_capacity_falls_back_on_the_257th_entry :: proc(t: ^testing.T) {
	v: Vga
	backing := damage_test_vga(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	testing.expect(t, test_set_vbe_mode(&v, 640, 480, 8))
	v.legacy_damage = {}
	for i in 0 ..< VGA_DAMAGE_MAX_RANGES {
		testing.expect(t, vga_damage_record_backing_range(&v, u32(i * 2), 1))
	}
	testing.expect_value(t, v.legacy_damage.range_count, u32(VGA_DAMAGE_MAX_RANGES))
	testing.expect_value(t, v.legacy_damage.full_reason, contract.Damage_Full_Reason.None)

	testing.expect(t, vga_damage_record_backing_range(&v, u32(VGA_DAMAGE_MAX_RANGES * 2), 1))
	testing.expect_value(t, v.legacy_damage.range_count, u32(0))
	testing.expect_value(
		t,
		v.legacy_damage.full_reason,
		contract.Damage_Full_Reason.Capacity_Exceeded,
	)
	testing.expect_value(t, vga_damage_snapshot(&v).rects, contract.rect_set_full({640, 480}))
}
