// SPDX-License-Identifier: GPL-3.0-only
package host

import contract "../presentation"
import "core:testing"
import sdl3 "vendor:sdl3"

composition_test_active :: proc(header: contract.Header) -> contract.Active_Identity {
	return {
		kind = .Gsw,
		display_owner = contract.display_owner_from_header(header),
		sequence = header.sequence,
		lifecycle_generation = header.lifecycle_generation,
		mode_generation = header.mode_generation,
		identity_namespace = header.identity_namespace,
		device_generation = header.device_generation,
		surface = header.surface,
		source_kind = header.source_kind,
		ownership = header.ownership,
	}
}

composition_test_windowed_resident :: proc() -> contract.Gsw_Present {
	key := contract.Mode_Key {
		format         = .Bgra_8888,
		surface_extent = {200, 100},
		canvas_extent  = {100, 100},
		source         = {20, 10, 80, 40},
		destination    = {10, 20, 40, 20},
	}
	dirty := contract.rect_set_full(key.surface_extent)
	return {
		clip_mode = .Windowed,
		header = {
			sequence = 30,
			lifecycle_generation = 1,
			mode_generation = 3,
			mode_key = key,
			identity_namespace = .Gsw3d,
			device_generation = 7,
			surface = {23, 5},
			format = key.format,
			surface_extent = key.surface_extent,
			canvas_extent = key.canvas_extent,
			source = key.source,
			destination = key.destination,
			dirty = dirty,
			interval = 1,
			source_kind = .Gsw_Resident,
			ownership = .Host_Resident,
		},
	}
}

composition_test_background :: proc(sequence: u64 = 20) -> contract.Gsw_Present {
	key := contract.Mode_Key {
		format         = .Bgrx_8888,
		surface_extent = {100, 100},
		canvas_extent  = {100, 100},
		source         = {0, 0, 100, 100},
		destination    = {0, 0, 100, 100},
	}
	return {
		clip_mode = .Fullscreen,
		header = {
			sequence = sequence,
			lifecycle_generation = 1,
			mode_generation = 2,
			mode_key = key,
			identity_namespace = .Gsw2d,
			device_generation = 4,
			surface = {9, 6},
			format = key.format,
			surface_extent = key.surface_extent,
			canvas_extent = key.canvas_extent,
			source = key.source,
			destination = key.destination,
			dirty = contract.rect_set_full(key.surface_extent),
			source_kind = .Gsw_Snapshot,
			ownership = .Mailbox_Surface,
		},
		source_pitch = 400,
	}
}

@(test)
composition_test_windowed_draw_plan_maps_guest_coordinates :: proc(t: ^testing.T) {
	present := composition_test_windowed_resident()
	texture_width, texture_height, valid_extent := host_presentation_resident_texture_extent(
		present,
	)
	testing.expect(t, valid_extent)
	testing.expect_value(t, texture_width, 200)
	testing.expect_value(t, texture_height, 100)
	_ = contract.rect_set_append(&present.clips, {20, 25, 10, 5})
	_ = contract.rect_set_append(&present.clips, {40, 30, 5, 5})
	plan := host_presentation_build_resident_draw_plan(present, sdl3.FRect{100, 50, 200, 100})
	testing.expect(t, plan.valid)
	testing.expect_value(t, plan.count, u32(2))
	testing.expect_value(t, plan.segments[0].source, sdl3.FRect{40, 20, 20, 10})
	testing.expect_value(t, plan.segments[0].destination, sdl3.FRect{140, 75, 20, 5})
	testing.expect_value(t, plan.segments[1].source, sdl3.FRect{80, 30, 10, 10})
	testing.expect_value(t, plan.segments[1].destination, sdl3.FRect{180, 80, 10, 5})
}

@(test)
composition_test_fullscreen_and_empty_window_have_distinct_draw_counts :: proc(t: ^testing.T) {
	present := composition_test_windowed_resident()
	testing.expect(t, host_presentation_resident_requires_desktop(present))
	plan := host_presentation_build_resident_draw_plan(present, sdl3.FRect{0, 0, 100, 100})
	testing.expect(t, plan.valid)
	testing.expect_value(t, plan.count, u32(0))

	present.clip_mode = .Fullscreen
	testing.expect(t, !host_presentation_resident_requires_desktop(present))
	present.clips = {}
	present.header.canvas_extent = {40, 20}
	present.header.destination = {0, 0, 40, 20}
	present.header.mode_key.canvas_extent = present.header.canvas_extent
	present.header.mode_key.destination = present.header.destination
	plan = host_presentation_build_resident_draw_plan(present, sdl3.FRect{0, 0, 200, 100})
	testing.expect(t, plan.valid)
	testing.expect_value(t, plan.count, u32(1))
	testing.expect_value(t, plan.segments[0].destination, sdl3.FRect{0, 0, 200, 100})
}

@(test)
composition_test_overlay_damage_splits_only_intersecting_clips :: proc(t: ^testing.T) {
	resident := composition_test_background(30)
	resident.clip_mode = .Windowed
	resident.header.source_kind = .Gsw_Resident
	resident.header.identity_namespace = .Gsw3d
	resident.header.device_generation = 7
	resident.header.surface = {23, 5}
	resident.header.ownership = .Host_Resident
	resident.header.mode_generation = 3
	resident.header.mode_key.format = .Bgra_8888
	resident.header.format = .Bgra_8888
	resident.header.interval = 1
	resident.clips = {}
	_ = contract.rect_set_append(&resident.clips, {0, 0, 10, 10})
	_ = contract.rect_set_append(&resident.clips, {20, 20, 10, 10})
	background := composition_test_background()
	update := background
	update.header.sequence = 21
	update.header.dirty = {}
	_ = contract.rect_set_append(&update.header.dirty, {4, 4, 4, 4})
	state := Host_Presentation_State {
		accepting = true,
		lifecycle = 1,
		selector = {active = composition_test_active(resident.header)},
		gsw = resident,
		gsw_snapshot = background,
		gsw_snapshot_source_mode_generation = background.header.mode_generation,
	}
	plan := host_presentation_overlay_plan(&state, update)
	testing.expect(t, plan.valid)
	testing.expect(t, !plan.fallback)
	testing.expect_value(t, plan.invalidated_regions, u64(1))
	testing.expect_value(t, plan.clips.count, u32(5))
	expected := [?]contract.Rect {
		{0, 0, 10, 4},
		{0, 4, 4, 4},
		{8, 4, 2, 4},
		{0, 8, 10, 2},
		{20, 20, 10, 10},
	}
	for rect, i in expected {testing.expect_value(t, plan.clips.rects[i], rect)}

	update.header.sequence = 22
	update.header.dirty = {}
	_ = contract.rect_set_append(&update.header.dirty, {40, 40, 2, 2})
	plan = host_presentation_overlay_plan(&state, update)
	testing.expect(t, plan.valid)
	testing.expect_value(t, plan.invalidated_regions, u64(0))
	testing.expect(t, contract.rect_set_equal(plan.clips, resident.clips))
}

@(test)
composition_test_stale_background_identity_cannot_change_overlay :: proc(t: ^testing.T) {
	resident := composition_test_background(30)
	resident.clip_mode = .Windowed
	resident.header.source_kind = .Gsw_Resident
	resident.header.identity_namespace = .Gsw3d
	resident.header.device_generation = 7
	resident.header.surface = {23, 5}
	resident.header.ownership = .Host_Resident
	resident.header.mode_generation = 3
	resident.header.mode_key.format = .Bgra_8888
	resident.header.format = .Bgra_8888
	resident.header.interval = 1
	_ = contract.rect_set_append(&resident.clips, {0, 0, 10, 10})
	background := composition_test_background()
	state := Host_Presentation_State {
		selector = {active = composition_test_active(resident.header)},
		gsw = resident,
		gsw_snapshot = background,
		gsw_snapshot_source_mode_generation = background.header.mode_generation,
	}
	stale := background
	stale.header.sequence += 1
	stale.header.surface.generation -= 1
	testing.expect(t, !host_presentation_overlay_plan(&state, stale).valid)
}
