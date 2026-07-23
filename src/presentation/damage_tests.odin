// SPDX-License-Identifier: GPL-3.0-only
package presentation

import "core:testing"

@(test)
damage_test_canonicalizes_overlap_and_adjacency_exactly :: proc(t: ^testing.T) {
	input: Rect_Set
	_ = rect_set_append(&input, {8, 4, 8, 4})
	_ = rect_set_append(&input, {0, 0, 8, 8})
	_ = rect_set_append(&input, {4, 0, 8, 8})
	_ = rect_set_append(&input, {16, 4, 8, 4})
	actual, result := rect_set_canonicalize(input, {24, 8})
	testing.expect_value(t, result, Rect_Set_Result.Exact)
	testing.expect_value(t, actual.count, u32(3))
	testing.expect_value(t, actual.rects[0], Rect{0, 0, 8, 8})
	testing.expect_value(t, actual.rects[1], Rect{8, 0, 4, 4})
	testing.expect_value(t, actual.rects[2], Rect{8, 4, 16, 4})
}

@(test)
damage_test_clips_and_rejects_malformed_arithmetic :: proc(t: ^testing.T) {
	input: Rect_Set
	_ = rect_set_append(&input, {8, 8, 8, 8})
	actual, result := rect_set_canonicalize(input, {12, 10})
	testing.expect_value(t, result, Rect_Set_Result.Exact)
	testing.expect_value(t, actual.rects[0], Rect{8, 8, 4, 2})

	input = {}
	_ = rect_set_append(&input, {max(u32), 0, 2, 1})
	_, result = rect_set_canonicalize(input, {12, 10})
	testing.expect_value(t, result, Rect_Set_Result.Invalid)

	input = {}
	_ = rect_set_append(&input, {0, 0, 0, 1})
	_, result = rect_set_canonicalize(input, {12, 10})
	testing.expect_value(t, result, Rect_Set_Result.Invalid)
}

@(test)
damage_test_preserves_exact_maximum_and_reports_capacity :: proc(t: ^testing.T) {
	maximum: Rect_Set
	for i in 0 ..< MAX_RECTS {
		_ = rect_set_append(&maximum, {u32(i * 2), 0, 1, 1})
	}
	actual, result := rect_set_canonicalize(maximum, {MAX_RECTS * 2, 2})
	testing.expect_value(t, result, Rect_Set_Result.Exact)
	testing.expect_value(t, actual.count, u32(MAX_RECTS))

	removal: Rect_Set
	for i in 0 ..< MAX_RECTS {
		_ = rect_set_append(&removal, {u32(i * 2 + 1), 0, 1, 1})
	}
	full := rect_set_full({MAX_RECTS * 2, 1})
	_, result = rect_set_subtract(full, removal, {MAX_RECTS * 2, 1})
	testing.expect_value(t, result, Rect_Set_Result.Exact)

	_ = rect_set_append(&maximum, {1, 1, 1, 1})
	maximum.count = MAX_RECTS + 1
	_, result = rect_set_canonicalize(maximum, {MAX_RECTS * 2, 2})
	testing.expect_value(t, result, Rect_Set_Result.Invalid)
}

@(test)
damage_test_intersection_and_subtraction_are_exact :: proc(t: ^testing.T) {
	base := rect_set_full({10, 10})
	cut: Rect_Set
	_ = rect_set_append(&cut, {2, 2, 6, 6})
	overlap, overlap_result := rect_set_intersection(base, cut, {10, 10})
	testing.expect_value(t, overlap_result, Rect_Set_Result.Exact)
	testing.expect_value(t, overlap.count, u32(1))
	testing.expect_value(t, overlap.rects[0], Rect{2, 2, 6, 6})

	remaining, subtract_result := rect_set_subtract(base, cut, {10, 10})
	testing.expect_value(t, subtract_result, Rect_Set_Result.Exact)
	testing.expect_value(t, remaining.count, u32(4))
	testing.expect_value(t, remaining.rects[0], Rect{0, 0, 10, 2})
	testing.expect_value(t, remaining.rects[1], Rect{0, 2, 2, 6})
	testing.expect_value(t, remaining.rects[2], Rect{8, 2, 2, 6})
	testing.expect_value(t, remaining.rects[3], Rect{0, 8, 10, 2})
}

@(test)
damage_test_palette_and_pixel_merge_preserves_full_fallback :: proc(t: ^testing.T) {
	pixel: Damage_Record
	pixel.kind = .Pixel_Memory
	_ = rect_set_append(&pixel.rects, {1, 1, 2, 2})
	palette: Damage_Record = {
		kind  = .Palette_Only,
		rects = rect_set_full({8, 8}),
	}
	merged := damage_record_merge(pixel, palette, {8, 8})
	testing.expect_value(t, merged.kind, Damage_Kind.Pixel_And_Palette)
	testing.expect_value(t, merged.full_reason, Damage_Full_Reason.None)
	testing.expect_value(t, merged.rects, rect_set_full({8, 8}))

	fallback := damage_record_full({8, 8}, .Pixel_Memory, .Ambiguous_Mapping)
	merged = damage_record_merge(palette, fallback, {8, 8})
	testing.expect_value(t, merged.kind, Damage_Kind.Pixel_And_Palette)
	testing.expect_value(t, merged.full_reason, Damage_Full_Reason.Ambiguous_Mapping)
	testing.expect_value(t, merged.rects, rect_set_full({8, 8}))
}

@(test)
damage_test_full_fallback_merge_is_order_independent :: proc(t: ^testing.T) {
	mode := damage_record_full({8, 8}, .Pixel_Memory, .Mode_Boundary)
	capacity := damage_record_full({8, 8}, .Pixel_Memory, .Capacity_Exceeded)
	forward := damage_record_merge(mode, capacity, {8, 8})
	reverse := damage_record_merge(capacity, mode, {8, 8})
	testing.expect_value(t, forward, reverse)
	testing.expect_value(t, forward.full_reason, Damage_Full_Reason.Capacity_Exceeded)
}
