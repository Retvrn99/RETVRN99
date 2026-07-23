// SPDX-License-Identifier: GPL-3.0-only
package presentation

import "core:testing"

test_mode_key :: proc(width: u32 = 640, height: u32 = 480) -> Mode_Key {
	return {
		format = .Bgrx_8888,
		surface_extent = {width, height},
		canvas_extent = {width, height},
		source = {0, 0, width, height},
		destination = {0, 0, width, height},
	}
}

test_full_rects :: proc(width: u32 = 640, height: u32 = 480) -> Rect_Set {
	set: Rect_Set
	_ = rect_set_append(&set, {0, 0, width, height})
	return set
}

test_legacy_update :: proc(
	sequence: u64 = 1,
	mode_generation: u64 = 1,
	lifecycle_generation: u64 = 1,
) -> Legacy_Frame_Update {
	key := test_mode_key()
	return {
		header = {
			sequence = sequence,
			lifecycle_generation = lifecycle_generation,
			mode_generation = mode_generation,
			mode_key = key,
			surface = {1, 1},
			format = key.format,
			surface_extent = key.surface_extent,
			canvas_extent = key.canvas_extent,
			source = key.source,
			destination = key.destination,
			dirty = test_full_rects(),
			interval = 0,
			source_kind = .Legacy_Snapshot,
			ownership = .Mailbox_Descriptor,
		},
	}
}

test_gsw_snapshot :: proc(
	sequence: u64 = 2,
	mode_generation: u64 = 1,
	lifecycle_generation: u64 = 1,
) -> Gsw_Present {
	key := test_mode_key()
	return {
		header = {
			sequence = sequence,
			lifecycle_generation = lifecycle_generation,
			mode_generation = mode_generation,
			mode_key = key,
			identity_namespace = .Gsw2d,
			device_generation = 3,
			surface = {7, 4},
			format = key.format,
			surface_extent = key.surface_extent,
			canvas_extent = key.canvas_extent,
			source = key.source,
			destination = key.destination,
			dirty = test_full_rects(),
			interval = 1,
			completion = {9, 3},
			source_kind = .Gsw_Snapshot,
			ownership = .Vm_Framebuffer,
		},
		clips = test_full_rects(),
		source_offset = 128,
		source_pitch = 640 * 4,
	}
}

test_gsw_resident :: proc(
	sequence: u64 = 2,
	mode_generation: u64 = 1,
	lifecycle_generation: u64 = 1,
) -> Gsw_Present {
	present := test_gsw_snapshot(sequence, mode_generation, lifecycle_generation)
	present.header.source_kind = .Gsw_Resident
	present.header.identity_namespace = .Gsw3d
	present.header.ownership = .Host_Resident
	present.source_offset = 0
	present.source_pitch = 0
	return present
}

test_context :: proc(header: Header, source_byte_capacity: u64 = 0) -> Validation_Context {
	return {
		lifecycle_generation = header.lifecycle_generation,
		mode_generation = header.mode_generation,
		mode_key = header.mode_key,
		identity_namespace = header.identity_namespace,
		device_generation = header.device_generation,
		surface = header.surface,
		format_mask = PIXEL_FORMAT_MASK_ALL,
		interval_mask = PRESENT_INTERVAL_MASK_ALL,
		source_byte_capacity = source_byte_capacity,
	}
}

test_invalidation :: proc(present: Gsw_Present, reason: Invalidation_Reason) -> Gsw_Invalidation {
	return {
		lifecycle_generation = present.header.lifecycle_generation,
		mode_generation = present.header.mode_generation,
		mode_key = present.header.mode_key,
		identity_namespace = present.header.identity_namespace,
		device_generation = present.header.device_generation,
		surface = present.header.surface,
		reason = reason,
	}
}

test_expect_code :: proc(t: ^testing.T, diagnostic: Diagnostic, code: Diagnostic_Code) {
	testing.expect_value(t, diagnostic.code, code)
}

@(test)
contracts_test_accepts_valid_legacy_snapshot_and_resident_records :: proc(t: ^testing.T) {
	legacy := test_legacy_update()
	testing.expect(t, diagnostic_valid(validate_legacy(legacy, test_context(legacy.header))))

	snapshot := test_gsw_snapshot()
	testing.expect(
		t,
		diagnostic_valid(validate_gsw(snapshot, test_context(snapshot.header, 2 * 1024 * 1024))),
	)

	resident := test_gsw_resident()
	testing.expect(t, diagnostic_valid(validate_gsw(resident, test_context(resident.header))))
	resident.header.format = .Rgb_555
	resident.header.mode_key.format = .Rgb_555
	testing.expect(t, diagnostic_valid(validate_gsw(resident, test_context(resident.header))))
}

@(test)
contracts_test_rejects_zero_overflowing_and_out_of_bounds_rectangles :: proc(t: ^testing.T) {
	legacy := test_legacy_update()
	current := test_context(legacy.header)
	legacy.header.source.width = 0
	legacy.header.mode_key.source = legacy.header.source
	current.mode_key.source = legacy.header.source
	test_expect_code(t, validate_legacy(legacy, current), .Zero_Source_Rect)

	legacy = test_legacy_update()
	current = test_context(legacy.header)
	legacy.header.source = {
		x      = ~u32(0),
		width  = 2,
		height = 1,
	}
	legacy.header.mode_key.source = legacy.header.source
	current.mode_key.source = legacy.header.source
	test_expect_code(t, validate_legacy(legacy, current), .Source_Rect_Overflow)

	legacy = test_legacy_update()
	current = test_context(legacy.header)
	legacy.header.source = {639, 0, 2, 1}
	legacy.header.mode_key.source = legacy.header.source
	current.mode_key.source = legacy.header.source
	test_expect_code(t, validate_legacy(legacy, current), .Source_Rect_Out_Of_Bounds)

	legacy = test_legacy_update()
	current = test_context(legacy.header)
	legacy.header.destination = {
		x      = ~u32(0),
		width  = 2,
		height = 1,
	}
	legacy.header.mode_key.destination = legacy.header.destination
	current.mode_key.destination = legacy.header.destination
	test_expect_code(t, validate_legacy(legacy, current), .Destination_Rect_Overflow)

	legacy = test_legacy_update()
	current = test_context(legacy.header)
	legacy.header.dirty.rects[0] = {640, 0, 1, 1}
	test_expect_code(t, validate_legacy(legacy, current), .Dirty_Rect_Out_Of_Bounds)
}

@(test)
contracts_test_enforces_rect_capacity_duplicates_and_zero_tails :: proc(t: ^testing.T) {
	legacy := test_legacy_update()
	legacy.header.dirty.count = MAX_RECTS + 1
	test_expect_code(
		t,
		validate_legacy(legacy, test_context(legacy.header)),
		.Dirty_Count_Overflow,
	)

	legacy = test_legacy_update()
	legacy.header.dirty.rects[1] = {0, 0, 1, 1}
	test_expect_code(
		t,
		validate_legacy(legacy, test_context(legacy.header)),
		.Dirty_Unused_Tail_Nonzero,
	)

	legacy = test_legacy_update()
	legacy.header.dirty.count = 2
	legacy.header.dirty.rects[1] = legacy.header.dirty.rects[0]
	test_expect_code(
		t,
		validate_legacy(legacy, test_context(legacy.header)),
		.Dirty_Rect_Duplicate,
	)

	legacy = test_legacy_update()
	legacy.header.dirty = {}
	test_expect_code(t, validate_legacy(legacy, test_context(legacy.header)), .Missing_Dirty_Rects)

	legacy = test_legacy_update()
	legacy.header.dirty.count = MAX_RECTS
	for i in 0 ..< MAX_RECTS {
		legacy.header.dirty.rects[i] = {u32(i), 0, 1, 1}
	}
	testing.expect(t, diagnostic_valid(validate_legacy(legacy, test_context(legacy.header))))
}

@(test)
contracts_test_enforces_clip_capacity_bounds_duplicates_and_tails :: proc(t: ^testing.T) {
	present := test_gsw_resident()
	present.clips.count = MAX_RECTS + 1
	test_expect_code(t, validate_gsw(present, test_context(present.header)), .Clip_Count_Overflow)

	present = test_gsw_resident()
	present.clips.rects[1] = {0, 0, 1, 1}
	test_expect_code(
		t,
		validate_gsw(present, test_context(present.header)),
		.Clip_Unused_Tail_Nonzero,
	)

	present = test_gsw_resident()
	present.clips.count = 2
	present.clips.rects[1] = present.clips.rects[0]
	test_expect_code(t, validate_gsw(present, test_context(present.header)), .Clip_Rect_Duplicate)

	present = test_gsw_resident()
	present.clips.rects[0] = {639, 479, 2, 1}
	test_expect_code(
		t,
		validate_gsw(present, test_context(present.header)),
		.Clip_Rect_Out_Of_Bounds,
	)

	present = test_gsw_resident()
	present.clips = {}
	testing.expect(t, diagnostic_valid(validate_gsw(present, test_context(present.header))))
}

@(test)
contracts_test_rejects_missing_and_stale_lifecycle_and_mode_identity :: proc(t: ^testing.T) {
	legacy := test_legacy_update()
	current := test_context(legacy.header)
	legacy.header.lifecycle_generation = 0
	test_expect_code(t, validate_legacy(legacy, current), .Missing_Lifecycle_Generation)

	legacy = test_legacy_update()
	current = test_context(legacy.header)
	current.lifecycle_generation = 2
	test_expect_code(t, validate_legacy(legacy, current), .Stale_Lifecycle_Generation)

	legacy = test_legacy_update()
	current = test_context(legacy.header)
	legacy.header.mode_generation = 0
	test_expect_code(t, validate_legacy(legacy, current), .Missing_Mode_Generation)

	legacy = test_legacy_update()
	current = test_context(legacy.header)
	current.mode_generation = 2
	test_expect_code(t, validate_legacy(legacy, current), .Stale_Mode_Generation)

	legacy = test_legacy_update()
	current = test_context(legacy.header)
	current.mode_key.canvas_extent.width = 800
	test_expect_code(t, validate_legacy(legacy, current), .Stale_Mode_Key)
}

@(test)
contracts_test_rejects_mode_key_divergence_from_header_geometry :: proc(t: ^testing.T) {
	present := test_gsw_resident()
	present.header.format = .Rgb_565
	test_expect_code(
		t,
		validate_gsw(present, test_context(present.header)),
		.Header_Mode_Key_Mismatch,
	)

	present = test_gsw_resident()
	present.header.surface_extent.width += 1
	test_expect_code(
		t,
		validate_gsw(present, test_context(present.header)),
		.Header_Mode_Key_Mismatch,
	)

	present = test_gsw_resident()
	present.header.canvas_extent.width += 1
	test_expect_code(
		t,
		validate_gsw(present, test_context(present.header)),
		.Header_Mode_Key_Mismatch,
	)

	present = test_gsw_resident()
	present.header.source.width -= 1
	test_expect_code(
		t,
		validate_gsw(present, test_context(present.header)),
		.Header_Mode_Key_Mismatch,
	)

	present = test_gsw_resident()
	present.header.destination.width -= 1
	test_expect_code(
		t,
		validate_gsw(present, test_context(present.header)),
		.Header_Mode_Key_Mismatch,
	)
}

@(test)
contracts_test_requires_exact_gsw_identity_namespace :: proc(t: ^testing.T) {
	present := test_gsw_resident()
	current := test_context(present.header)
	present.header.identity_namespace = .Invalid
	test_expect_code(t, validate_gsw(present, current), .Missing_Identity_Namespace)

	present = test_gsw_resident()
	current = test_context(present.header)
	current.identity_namespace = .Invalid
	test_expect_code(t, validate_gsw(present, current), .Missing_Current_Identity_Namespace)

	present = test_gsw_resident()
	current = test_context(present.header)
	current.identity_namespace = .Gsw2d
	test_expect_code(t, validate_gsw(present, current), .Stale_Identity_Namespace)

	unknown := transmute(Identity_Namespace)u8(0x7F)
	present = test_gsw_resident()
	current = test_context(present.header)
	present.header.identity_namespace = unknown
	current.identity_namespace = unknown
	test_expect_code(t, validate_gsw(present, current), .Unexpected_Identity_Namespace)

	present = test_gsw_resident()
	current = test_context(present.header)
	current.identity_namespace = unknown
	test_expect_code(t, validate_gsw(present, current), .Unexpected_Identity_Namespace)

	legacy := test_legacy_update()
	legacy.header.identity_namespace = .Gsw2d
	test_expect_code(
		t,
		validate_legacy(legacy, test_context(legacy.header)),
		.Unexpected_Identity_Namespace,
	)
}

@(test)
contracts_test_rejects_missing_stale_and_replaced_surface_identity :: proc(t: ^testing.T) {
	present := test_gsw_resident()
	current := test_context(present.header)
	present.header.surface = {}
	test_expect_code(t, validate_gsw(present, current), .Missing_Surface_Identity)

	present = test_gsw_resident()
	current = test_context(present.header)
	current.surface.generation = generation_next(current.surface.generation)
	test_expect_code(t, validate_gsw(present, current), .Stale_Surface_Identity)

	present = test_gsw_resident()
	current = test_context(present.header)
	current.surface.id += 1
	test_expect_code(t, validate_gsw(present, current), .Stale_Surface_Identity)
}

@(test)
contracts_test_rejects_device_format_interval_and_completion_mismatches :: proc(t: ^testing.T) {
	present := test_gsw_resident()
	current := test_context(present.header)
	present.header.device_generation = 0
	test_expect_code(t, validate_gsw(present, current), .Missing_Device_Generation)

	present = test_gsw_resident()
	current = test_context(present.header)
	current.device_generation += 1
	test_expect_code(t, validate_gsw(present, current), .Stale_Device_Generation)

	present = test_gsw_resident()
	current = test_context(present.header)
	present.header.format = .Invalid
	present.header.mode_key.format = .Invalid
	current.mode_key.format = .Invalid
	test_expect_code(t, validate_gsw(present, current), .Unsupported_Format)

	present = test_gsw_resident()
	current = test_context(present.header)
	present.header.interval = MAX_PRESENT_INTERVAL + 1
	test_expect_code(t, validate_gsw(present, current), .Unsupported_Interval)

	present = test_gsw_resident()
	current = test_context(present.header)
	current.interval_mask = presentation_interval_mask(0)
	test_expect_code(t, validate_gsw(present, current), .Unsupported_Interval)

	present = test_gsw_resident()
	current = test_context(present.header)
	present.header.completion.generation = 0
	test_expect_code(t, validate_gsw(present, current), .Invalid_Completion)

	present = test_gsw_resident()
	current = test_context(present.header)
	present.header.completion.generation += 1
	test_expect_code(t, validate_gsw(present, current), .Completion_Generation_Mismatch)

	legacy := test_legacy_update()
	legacy.header.completion = {1, 1}
	test_expect_code(t, validate_legacy(legacy, test_context(legacy.header)), .Invalid_Completion)
}

@(test)
contracts_test_validates_snapshot_layout_without_overflow :: proc(t: ^testing.T) {
	present := test_gsw_snapshot()
	current := test_context(present.header)
	test_expect_code(t, validate_gsw(present, current), .Missing_Source_Capacity)

	current.source_byte_capacity = 2 * 1024 * 1024
	present.source_pitch -= 1
	test_expect_code(t, validate_gsw(present, current), .Invalid_Source_Pitch)

	present = test_gsw_snapshot()
	current = test_context(present.header, 1024)
	test_expect_code(t, validate_gsw(present, current), .Source_Layout_Out_Of_Bounds)

	present = test_gsw_snapshot()
	present.source_offset = ~u64(0) - 64
	current = test_context(present.header, ~u64(0))
	test_expect_code(t, validate_gsw(present, current), .Source_Layout_Overflow)

	present = test_gsw_resident()
	present.source_offset = 1
	test_expect_code(
		t,
		validate_gsw(present, test_context(present.header)),
		.Unexpected_Source_Layout,
	)
}

@(test)
contracts_test_generation_order_wrap_and_half_range_are_explicit :: proc(t: ^testing.T) {
	testing.expect_value(t, generation_next(0), u64(1))
	testing.expect_value(t, generation_next(~u64(0)), u64(1))
	testing.expect_value(t, generation_order(7, 7), Generation_Order.Same)
	testing.expect_value(t, generation_order(8, 7), Generation_Order.Newer)
	testing.expect_value(t, generation_order(7, 8), Generation_Order.Older)
	testing.expect_value(t, generation_order(1, ~u64(0)), Generation_Order.Newer)
	testing.expect_value(
		t,
		generation_order(1 + GENERATION_HALF_RANGE, 1),
		Generation_Order.Ambiguous,
	)
	testing.expect_value(t, generation_order(0, 1), Generation_Order.Invalid)
	testing.expect(t, !generation_is_newer(1 + GENERATION_HALF_RANGE, 1))
}

@(test)
contracts_test_legacy_surface_transition_requires_same_or_strictly_newer_identity :: proc(
	t: ^testing.T,
) {
	previous := test_legacy_update()
	previous.header.surface = {
		id         = 7,
		generation = 5,
	}
	content := previous
	testing.expect(t, legacy_surface_transition_valid(previous, content))

	zero := content
	zero.header.surface.generation = 0
	testing.expect(t, !legacy_surface_transition_valid(previous, zero))

	colliding := content
	colliding.header.surface.id = 8
	testing.expect(t, !legacy_surface_transition_valid(previous, colliding))

	older := content
	older.header.surface.generation = 4
	testing.expect(t, !legacy_surface_transition_valid(previous, older))

	ambiguous := content
	ambiguous.header.surface.generation = 5 + GENERATION_HALF_RANGE
	testing.expect(t, !legacy_surface_transition_valid(previous, ambiguous))

	replacement := content
	replacement.header.surface = {
		id         = 8,
		generation = 6,
	}
	testing.expect(t, legacy_surface_transition_valid(previous, replacement))

	geometry := content
	geometry.header.mode_key.canvas_extent.width = 800
	geometry.header.canvas_extent.width = 800
	testing.expect(t, !legacy_surface_transition_valid(previous, geometry))
	geometry.header.surface.generation = 6
	testing.expect(t, legacy_surface_transition_valid(previous, geometry))
}

@(test)
contracts_test_mode_clock_changes_only_for_semantic_mode_changes :: proc(t: ^testing.T) {
	clock: Mode_Clock
	key := test_mode_key()
	generation, changed := mode_clock_observe(&clock, .Legacy, key)
	testing.expect_value(t, generation, u64(1))
	testing.expect(t, changed)
	testing.expect_value(t, clock.owner, Display_Owner.Legacy)

	generation, changed = mode_clock_observe(&clock, .Legacy, key)
	testing.expect_value(t, generation, u64(1))
	testing.expect(t, !changed)

	generation, changed = mode_clock_observe(&clock, .Gsw2d, key)
	testing.expect_value(t, generation, u64(2))
	testing.expect(t, changed)
	testing.expect_value(t, clock.owner, Display_Owner.Gsw2d)

	changed_key := key
	changed_key.canvas_extent.width = 800
	generation, changed = mode_clock_observe(&clock, .Gsw2d, changed_key)
	testing.expect_value(t, generation, u64(3))
	testing.expect(t, changed)

	clock.generation = ~u64(0)
	changed_key.destination.x = 1
	generation, changed = mode_clock_observe(&clock, .None, changed_key)
	testing.expect_value(t, generation, u64(1))
	testing.expect(t, changed)
	testing.expect_value(t, clock.owner, Display_Owner.None)
}

@(test)
contracts_test_display_owner_is_exact_for_each_adapter :: proc(t: ^testing.T) {
	legacy := test_legacy_update()
	testing.expect_value(t, display_owner_from_header(legacy.header), Display_Owner.Legacy)

	snapshot := test_gsw_snapshot()
	testing.expect_value(t, display_owner_from_header(snapshot.header), Display_Owner.Gsw2d)
	snapshot.header.identity_namespace = .Gsw3d
	test_expect_code(
		t,
		validate_gsw(snapshot, test_context(snapshot.header, 2 * 1024 * 1024)),
		.Invalid_Display_Owner,
	)

	resident := test_gsw_resident()
	testing.expect_value(t, display_owner_from_header(resident.header), Display_Owner.Gsw3d)
	resident.header.identity_namespace = .Gsw2d
	test_expect_code(
		t,
		validate_gsw(resident, test_context(resident.header)),
		.Invalid_Display_Owner,
	)
}

@(test)
contracts_test_record_equality_is_deterministic :: proc(t: ^testing.T) {
	legacy := test_legacy_update()
	legacy_copy := legacy
	testing.expect(t, legacy_frame_update_equal(legacy, legacy_copy))
	legacy_copy.header.dirty.rects[1] = {0, 0, 1, 1}
	testing.expect(t, !legacy_frame_update_equal(legacy, legacy_copy))

	present := test_gsw_snapshot()
	present_copy := present
	testing.expect(t, gsw_present_equal(present, present_copy))
	present_copy.source_offset += 1
	testing.expect(t, !gsw_present_equal(present, present_copy))
}

@(test)
contracts_test_selector_presents_legacy_then_newer_gsw :: proc(t: ^testing.T) {
	selector: Selector
	legacy := test_legacy_update(1)
	result := selector_submit_legacy(&selector, legacy, test_context(legacy.header))
	testing.expect_value(t, result.action, Selector_Action.Present_Legacy)
	testing.expect_value(t, selector.active.kind, Active_Kind.Legacy)

	present := test_gsw_resident(2, 2)
	result = selector_submit_gsw(&selector, present, test_context(present.header))
	testing.expect_value(t, result.action, Selector_Action.Present_Gsw)
	testing.expect_value(t, selector.active.kind, Active_Kind.Gsw)
	testing.expect_value(t, selector.display_owner, Display_Owner.Gsw3d)
	testing.expect_value(t, selector.mode_generation, u64(2))
	testing.expect(t, surface_identity_equal(selector.active.surface, present.header.surface))
}

@(test)
contracts_test_selector_refreshes_last_good_without_stealing_active_gsw :: proc(t: ^testing.T) {
	selector: Selector
	legacy := test_legacy_update(1)
	_ = selector_submit_legacy(&selector, legacy, test_context(legacy.header))
	present := test_gsw_resident(2, 2)
	_ = selector_submit_gsw(&selector, present, test_context(present.header))

	refresh := test_legacy_update(3, 2)
	result := selector_submit_legacy(&selector, refresh, test_context(refresh.header))
	testing.expect_value(t, result.action, Selector_Action.Refresh_Legacy)
	testing.expect_value(t, selector.active.kind, Active_Kind.Gsw)
	testing.expect_value(t, selector.display_owner, Display_Owner.Gsw3d)
	testing.expect_value(t, selector.mode_generation, u64(2))
	testing.expect(t, legacy_frame_update_equal(selector.last_good_legacy, refresh))
}

@(test)
contracts_test_gsw_owner_transition_requires_a_new_mode_generation :: proc(t: ^testing.T) {
	selector: Selector
	legacy := test_legacy_update(1, 1)
	_ = selector_submit_legacy(&selector, legacy, test_context(legacy.header))
	snapshot := test_gsw_snapshot(2, 2)
	result := selector_submit_gsw(
		&selector,
		snapshot,
		test_context(snapshot.header, 2 * 1024 * 1024),
	)
	if !testing.expect_value(t, result.action, Selector_Action.Present_Gsw) {return}
	testing.expect_value(t, selector.display_owner, Display_Owner.Gsw2d)

	stale_owner := test_gsw_resident(3, 2)
	result = selector_submit_gsw(&selector, stale_owner, test_context(stale_owner.header))
	testing.expect_value(t, result.action, Selector_Action.Drop_Stale)
	testing.expect_value(t, selector.display_owner, Display_Owner.Gsw2d)

	resident := test_gsw_resident(4, 3)
	result = selector_submit_gsw(&selector, resident, test_context(resident.header))
	testing.expect_value(t, result.action, Selector_Action.Present_Gsw)
	testing.expect_value(t, selector.display_owner, Display_Owner.Gsw3d)
	testing.expect_value(t, selector.mode_generation, u64(3))
}

@(test)
contracts_test_selector_rejects_spurious_or_missing_mode_transitions :: proc(t: ^testing.T) {
	selector: Selector
	legacy := test_legacy_update(1, 1)
	_ = selector_submit_legacy(&selector, legacy, test_context(legacy.header))
	before := selector

	spurious := test_legacy_update(2, 2)
	result := selector_submit_legacy(&selector, spurious, test_context(spurious.header))
	testing.expect_value(t, result.action, Selector_Action.Drop_Stale)
	testing.expect_value(t, selector, before)

	missing := test_legacy_update(2, 1)
	missing.header.mode_key.canvas_extent.width = 800
	missing.header.canvas_extent.width = 800
	missing.header.surface.generation = 2
	result = selector_submit_legacy(&selector, missing, test_context(missing.header))
	testing.expect_value(t, result.action, Selector_Action.Drop_Stale)
	testing.expect_value(t, selector, before)

	transition := missing
	transition.header.mode_generation = 2
	result = selector_submit_legacy(&selector, transition, test_context(transition.header))
	testing.expect_value(t, result.action, Selector_Action.Present_Legacy)
	testing.expect_value(t, selector.mode_generation, u64(2))
}

@(test)
contracts_test_new_legacy_mode_invalidates_active_gsw :: proc(t: ^testing.T) {
	selector: Selector
	legacy := test_legacy_update(1, 1)
	_ = selector_submit_legacy(&selector, legacy, test_context(legacy.header))
	present := test_gsw_resident(2, 2)
	_ = selector_submit_gsw(&selector, present, test_context(present.header))

	new_mode := test_legacy_update(3, 3)
	new_mode.header.mode_key.canvas_extent = {800, 600}
	new_mode.header.canvas_extent = {800, 600}
	new_mode.header.destination = {0, 0, 640, 480}
	new_mode.header.mode_key.destination = new_mode.header.destination
	new_mode.header.surface.generation = 2
	result := selector_submit_legacy(&selector, new_mode, test_context(new_mode.header))
	testing.expect_value(t, result.action, Selector_Action.Present_Legacy)
	testing.expect_value(t, selector.active.kind, Active_Kind.Legacy)
	testing.expect_value(t, selector.mode_generation, u64(3))
	testing.expect_value(t, selector.display_owner, Display_Owner.Legacy)
}

@(test)
contracts_test_new_gsw_mode_preserves_last_good_legacy :: proc(t: ^testing.T) {
	selector: Selector
	legacy := test_legacy_update(1, 1)
	_ = selector_submit_legacy(&selector, legacy, test_context(legacy.header))

	present := test_gsw_resident(2, 2)
	present.header.mode_key.canvas_extent = {800, 600}
	present.header.canvas_extent = {800, 600}
	present.header.mode_key.destination = present.header.destination
	result := selector_submit_gsw(&selector, present, test_context(present.header))
	testing.expect_value(t, result.action, Selector_Action.Present_Gsw)
	testing.expect_value(t, selector.mode_generation, u64(2))
	testing.expect_value(t, selector.active.kind, Active_Kind.Gsw)
	testing.expect(t, selector.has_last_good_legacy)
	testing.expect(t, legacy_frame_update_equal(selector.last_good_legacy, legacy))
}

@(test)
contracts_test_selector_drops_stale_and_ambiguous_work :: proc(t: ^testing.T) {
	selector: Selector
	legacy := test_legacy_update(4)
	_ = selector_submit_legacy(&selector, legacy, test_context(legacy.header))

	stale := test_gsw_resident(3, 2)
	result := selector_submit_gsw(&selector, stale, test_context(stale.header))
	testing.expect_value(t, result.action, Selector_Action.Drop_Stale)
	testing.expect_value(t, selector.active.kind, Active_Kind.Legacy)

	ambiguous := test_gsw_resident(4 + GENERATION_HALF_RANGE, 2)
	result = selector_submit_gsw(&selector, ambiguous, test_context(ambiguous.header))
	testing.expect_value(t, result.action, Selector_Action.Drop_Stale)
	testing.expect_value(t, selector.active.kind, Active_Kind.Legacy)
}

@(test)
contracts_test_exact_gsw_invalidation_restores_last_good_legacy :: proc(t: ^testing.T) {
	selector: Selector
	legacy := test_legacy_update(1)
	_ = selector_submit_legacy(&selector, legacy, test_context(legacy.header))
	present := test_gsw_resident(2, 2)
	current := test_context(present.header)
	_ = selector_submit_gsw(&selector, present, current)
	mode_stale := test_invalidation(present, .Surface_Destroyed)
	mode_stale.mode_key.canvas_extent.width += 1
	test_expect_code(t, validate_gsw_invalidation(mode_stale, current), .Stale_Mode_Key)

	stale := test_invalidation(present, .Surface_Destroyed)
	stale.surface.generation += 1
	stale_current := current
	stale_current.surface = stale.surface
	result := selector_invalidate_gsw(&selector, stale, stale_current)
	testing.expect_value(t, result.action, Selector_Action.Drop_Stale)
	testing.expect_value(t, selector.active.kind, Active_Kind.Gsw)

	invalidation := test_invalidation(present, .Device_Reset)
	result = selector_invalidate_gsw(&selector, invalidation, current)
	testing.expect_value(t, result.action, Selector_Action.Restore_Legacy)
	testing.expect_value(t, selector.active.kind, Active_Kind.Legacy)
	testing.expect_value(t, selector.display_owner, Display_Owner.Legacy)
	testing.expect_value(t, selector.mode_generation, u64(3))
	testing.expect(t, surface_identity_equal(selector.active.surface, legacy.header.surface))
	testing.expect(t, generation_is_newer(selector.active.sequence, present.header.sequence))

	result = selector_submit_gsw(&selector, present, current)
	testing.expect_value(t, result.action, Selector_Action.Drop_Stale)
	testing.expect_value(t, selector.active.kind, Active_Kind.Legacy)
}

@(test)
contracts_test_cross_mode_gsw_teardown_restores_legacy_with_forward_mode :: proc(t: ^testing.T) {
	reasons := [?]Invalidation_Reason{.Surface_Destroyed, .Device_Reset, .Process_Exit}
	for reason in reasons {
		selector: Selector
		legacy := test_legacy_update(10, 1)
		_ = selector_submit_legacy(&selector, legacy, test_context(legacy.header))
		present := test_gsw_resident(20, 2)
		key := test_mode_key(800, 600)
		present.header.mode_key = key
		present.header.format = key.format
		present.header.surface_extent = key.surface_extent
		present.header.canvas_extent = key.canvas_extent
		present.header.source = key.source
		present.header.destination = key.destination
		present.header.dirty = test_full_rects(800, 600)
		present.clips = test_full_rects(800, 600)
		current := test_context(present.header)
		result := selector_submit_gsw(&selector, present, current)
		if !testing.expect_value(t, result.action, Selector_Action.Present_Gsw) {continue}
		gsw_mode := selector.mode_generation

		result = selector_invalidate_gsw(&selector, test_invalidation(present, reason), current)
		testing.expect_value(t, result.action, Selector_Action.Restore_Legacy)
		testing.expect_value(t, selector.active.kind, Active_Kind.Legacy)
		testing.expect(t, generation_is_newer(selector.mode_generation, gsw_mode))
		testing.expect_value(t, selector.active.mode_generation, selector.mode_generation)
		testing.expect(
			t,
			mode_key_equal(selector.last_good_legacy.header.mode_key, legacy.header.mode_key),
		)
		testing.expect(t, surface_identity_equal(selector.active.surface, legacy.header.surface))
		testing.expect(t, generation_is_newer(selector.active.sequence, present.header.sequence))
	}
}

@(test)
contracts_test_cross_namespace_invalidation_cannot_match_numeric_identity :: proc(t: ^testing.T) {
	selector: Selector
	present := test_gsw_resident()
	current := test_context(present.header)
	_ = selector_submit_gsw(&selector, present, current)
	before := selector

	invalidation := test_invalidation(present, .Device_Reset)
	invalidation.identity_namespace = .Gsw2d
	result := selector_invalidate_gsw(&selector, invalidation, current)
	testing.expect_value(t, result.action, Selector_Action.Drop_Stale)
	testing.expect_value(t, result.diagnostic.code, Diagnostic_Code.Stale_Identity_Namespace)
	testing.expect_value(t, selector, before)

	unknown := transmute(Identity_Namespace)u8(0x7F)
	invalidation = test_invalidation(present, .Device_Reset)
	invalidation.identity_namespace = unknown
	current.identity_namespace = unknown
	result = selector_invalidate_gsw(&selector, invalidation, current)
	testing.expect_value(t, result.action, Selector_Action.Reject_Invalid)
	testing.expect_value(t, result.diagnostic.code, Diagnostic_Code.Unexpected_Identity_Namespace)
	testing.expect_value(t, selector, before)
}

@(test)
contracts_test_mode_invalidation_and_vm_stop_clear_state :: proc(t: ^testing.T) {
	selector: Selector
	present := test_gsw_resident()
	current := test_context(present.header)
	_ = selector_submit_gsw(&selector, present, current)
	result := selector_invalidate_gsw(
		&selector,
		test_invalidation(present, .Mode_Changed),
		current,
	)
	testing.expect_value(t, result.action, Selector_Action.Clear)
	testing.expect_value(t, selector.active.kind, Active_Kind.None)
	testing.expect_value(t, selector.display_owner, Display_Owner.None)
	testing.expect_value(t, selector.mode_generation, u64(2))

	present = test_gsw_resident(4, 3)
	current = test_context(present.header)
	_ = selector_submit_gsw(&selector, present, current)
	result = selector_invalidate_gsw(&selector, test_invalidation(present, .Process_Exit), current)
	testing.expect_value(t, result.action, Selector_Action.Clear)
	testing.expect_value(t, selector.active.kind, Active_Kind.None)
	testing.expect_value(t, selector.mode_generation, u64(4))

	present = test_gsw_resident(6, 5)
	current = test_context(present.header)
	_ = selector_submit_gsw(&selector, present, current)
	result = selector_lifecycle_change(&selector, 2)
	testing.expect_value(t, result.action, Selector_Action.Clear)
	testing.expect_value(t, selector.lifecycle_generation, u64(2))
	testing.expect_value(t, selector.active.kind, Active_Kind.None)

	result = selector_vm_stop(&selector)
	testing.expect_value(t, result.action, Selector_Action.Clear)
	testing.expect_value(t, selector, Selector{})
}
