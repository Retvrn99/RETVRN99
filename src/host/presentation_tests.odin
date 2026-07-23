// SPDX-License-Identifier: GPL-3.0-only
package host

import contract "../presentation"
import vga "../vga"
import "core:testing"
import sdl3 "vendor:sdl3"

host_presentation_test_mode_key :: proc(width: u32 = 640, height: u32 = 480) -> contract.Mode_Key {
	return {
		format = .Bgra_8888,
		surface_extent = {width, height},
		canvas_extent = {width, height},
		source = {0, 0, width, height},
		destination = {0, 0, width, height},
	}
}

host_presentation_test_dirty :: proc(width: u32, height: u32) -> contract.Rect_Set {
	dirty: contract.Rect_Set
	_ = contract.rect_set_append(&dirty, {0, 0, width, height})
	return dirty
}

host_presentation_test_legacy :: proc(
	sequence: u64,
	lifecycle: u64 = 1,
	key: contract.Mode_Key = {},
) -> contract.Legacy_Frame_Update {
	resolved := key
	if resolved.surface_extent.width == 0 {resolved = host_presentation_test_mode_key()}
	return {
		damage_kind = .Pixel_Memory,
		header = {
			sequence = sequence,
			lifecycle_generation = lifecycle,
			mode_generation = 1,
			mode_key = resolved,
			surface = {11, 1},
			format = resolved.format,
			surface_extent = resolved.surface_extent,
			canvas_extent = resolved.canvas_extent,
			source = resolved.source,
			destination = resolved.destination,
			dirty = host_presentation_test_dirty(
				resolved.surface_extent.width,
				resolved.surface_extent.height,
			),
			interval = 0,
			source_kind = .Legacy_Snapshot,
			ownership = .Mailbox_Descriptor,
		},
	}
}

host_presentation_test_resident :: proc(
	sequence: u64,
	lifecycle: u64 = 1,
	key: contract.Mode_Key = {},
) -> contract.Gsw_Present {
	resolved := key
	if resolved.surface_extent.width == 0 {resolved = host_presentation_test_mode_key()}
	return {
		clip_mode = .Fullscreen,
		header = {
			sequence = sequence,
			lifecycle_generation = lifecycle,
			mode_generation = 1,
			mode_key = resolved,
			identity_namespace = .Gsw3d,
			device_generation = 7,
			surface = {23, 5},
			format = resolved.format,
			surface_extent = resolved.surface_extent,
			canvas_extent = resolved.canvas_extent,
			source = resolved.source,
			destination = resolved.destination,
			dirty = host_presentation_test_dirty(
				resolved.surface_extent.width,
				resolved.surface_extent.height,
			),
			interval = 1,
			completion = {17, 7},
			source_kind = .Gsw_Resident,
			ownership = .Host_Resident,
		},
	}
}

host_presentation_test_snapshot :: proc(
	sequence: u64,
	lifecycle: u64 = 1,
	key: contract.Mode_Key = {},
) -> contract.Gsw_Present {
	present := host_presentation_test_resident(sequence, lifecycle, key)
	present.header.mode_generation = 2
	present.header.mode_key.format = .Bgrx_8888
	present.header.format = .Bgrx_8888
	present.header.identity_namespace = .Gsw2d
	present.header.source_kind = .Gsw_Snapshot
	present.header.ownership = .Mailbox_Surface
	present.header.interval = 0
	present.source_pitch = present.header.surface_extent.width * 4
	return present
}

host_presentation_test_local_resident :: proc(
	h: ^Host,
	sequence: u64,
	lifecycle: u64 = 1,
	key: contract.Mode_Key = {},
) -> contract.Gsw_Present {
	present := host_presentation_test_resident(sequence, lifecycle, key)
	if h == nil {return present}
	clock := h.presentation_state.mode_clock
	present.header.mode_generation, _ = contract.mode_clock_observe(
		&clock,
		.Gsw3d,
		contract.output_mode_key(present.header),
	)
	return present
}

host_presentation_test_physical :: proc(present: contract.Gsw_Present) -> Host_Gpu_Present {
	header := present.header
	return {
		surface_id = u32(header.surface.id),
		source = {header.source.x, header.source.y, header.source.width, header.source.height},
		destination = {
			header.destination.x,
			header.destination.y,
			header.destination.width,
			header.destination.height,
		},
		canvas_width = header.canvas_extent.width,
		canvas_height = header.canvas_extent.height,
		interval = header.interval,
	}
}

host_presentation_test_install_surface :: proc(h: ^Host, present: contract.Gsw_Present) {
	header := present.header
	h.gpu_surfaces[0] = {
		live           = true,
		generation     = header.surface.generation,
		descriptor     = {
			u32(header.surface.id),
			header.surface_extent.width,
			header.surface_extent.height,
			.Bgra8_Unorm,
		},
		render_texture = transmute(^sdl3.Texture)(uintptr(1)),
	}
}

host_presentation_test_apply_legacy :: proc(h: ^Host, admission: Host_Presentation_Admission) {
	h.presentation_state.selector = admission.selector
	h.presentation_state.mode_clock = admission.mode_clock
	h.presentation_state.vga_mode_clock = admission.vga_mode_clock
	h.presentation_state.legacy = admission.legacy
	h.presentation_state.last_vga_sequence = admission.source_sequence
	h.aspect_width = int(admission.legacy.header.canvas_extent.width)
	h.aspect_height = int(admission.legacy.header.canvas_extent.height)
	h.has_frame = true
}

host_presentation_test_apply_gsw :: proc(h: ^Host, admission: Host_Presentation_Admission) {
	h.presentation_state.selector = admission.selector
	h.presentation_state.mode_clock = admission.mode_clock
	if admission.vga_ordered {
		h.presentation_state.vga_mode_clock = admission.vga_mode_clock
	}
	h.presentation_state.gsw = admission.gsw
	h.presentation_state.gsw_source_mode_generation = admission.source_mode_generation
	if admission.gsw.header.source_kind == .Gsw_Snapshot {
		h.presentation_state.gsw_snapshot = admission.gsw
		h.presentation_state.gsw_snapshot_source_mode_generation = admission.source_mode_generation
	}
	h.presentation_state.last_vga_sequence = admission.source_sequence
	h.has_frame = true
}

host_presentation_test_staged :: proc(
	admission: ^Host_Presentation_Admission,
	texture: ^sdl3.Texture,
	generation: u64,
	width: int = 640,
	height: int = 480,
) -> Host_Presentation_Staged_Texture {
	if admission == nil {return {}}
	header := admission.kind == .Legacy ? admission.legacy.header : admission.gsw.header
	return {
		valid = true,
		kind = admission.kind,
		texture = texture,
		width = width,
		height = height,
		stage_generation = generation,
		lifecycle_generation = header.lifecycle_generation,
		admission_sequence = header.sequence,
	}
}

@(test)
host_presentation_test_in_place_legacy_commit_preserves_texture :: proc(t: ^testing.T) {
	h: Host
	if !host_presentation_test_seed_legacy(t, &h) {return}
	texture := transmute(^sdl3.Texture)(uintptr(71))
	h.tex = texture
	h.tex_width = 640
	h.tex_height = 480
	h.presentation_state.legacy_resource_generation = 4
	next := host_presentation_test_legacy(11)
	next.header.dirty = {}
	_ = contract.rect_set_append(&next.header.dirty, {1, 2, 3, 4})
	admission := host_presentation_admit_legacy(&h, next)
	if !testing.expect(t, admission.valid) {return}
	h.presentation_state.texture_stage_generation = 9
	staged := Host_Presentation_Staged_Texture {
		valid                = true,
		kind                 = .Legacy,
		texture              = texture,
		width                = 640,
		height               = 480,
		stage_generation     = 9,
		lifecycle_generation = admission.legacy.header.lifecycle_generation,
		admission_sequence   = admission.legacy.header.sequence,
		in_place             = true,
		mutated              = true,
		resource_generation  = 4,
		upload_bytes         = 48,
		upload_regions       = 1,
	}
	testing.expect(t, host_presentation_commit_legacy_staged(&h, &admission, staged))
	testing.expect_value(t, h.tex, texture)
	testing.expect_value(
		t,
		h.presentation_state.legacy.header.sequence,
		admission.legacy.header.sequence,
	)
}

host_presentation_test_invalidation :: proc(
	h: ^Host,
	namespace: contract.Identity_Namespace,
	reason: contract.Invalidation_Reason,
) -> contract.Gsw_Invalidation {
	present := h.presentation_state.gsw.header
	return {
		lifecycle_generation = present.lifecycle_generation,
		mode_generation = h.presentation_state.gsw_source_mode_generation,
		mode_key = present.mode_key,
		identity_namespace = namespace,
		device_generation = present.device_generation,
		surface = present.surface,
		reason = reason,
	}
}

host_presentation_test_seed_legacy :: proc(t: ^testing.T, h: ^Host) -> bool {
	if !testing.expect(t, host_presentation_start(h, 1)) {return false}
	legacy := host_presentation_test_legacy(10)
	admission := host_presentation_admit_legacy(h, legacy)
	if !testing.expect(t, admission.valid) {return false}
	if !testing.expect_value(t, admission.result.action, contract.Selector_Action.Present_Legacy) {
		return false
	}
	host_presentation_test_apply_legacy(h, admission)
	return true
}

host_presentation_test_seed_resident :: proc(t: ^testing.T, h: ^Host) -> bool {
	if !host_presentation_test_seed_legacy(t, h) {return false}
	h.tex = transmute(^sdl3.Texture)(uintptr(90))
	h.tex_width = 640
	h.tex_height = 480
	present := host_presentation_test_local_resident(h, 20)
	admission := host_presentation_admit_gsw(h, present)
	if !testing.expect(t, admission.valid) {return false}
	host_presentation_test_install_surface(h, admission.gsw)
	return testing.expect(
		t,
		host_presentation_commit_resident(
			h,
			&admission,
			host_presentation_test_physical(admission.gsw),
		),
	)
}

@(test)
host_presentation_test_stale_lifecycle_and_ordered_source_sequences_drop :: proc(t: ^testing.T) {
	h: Host
	if !host_presentation_test_seed_legacy(t, &h) {return}
	drops := h.presentation_metrics.stale_generation_drops

	wrong_lifecycle := host_presentation_test_legacy(11, 2)
	admission := host_presentation_admit_legacy(&h, wrong_lifecycle)
	testing.expect(t, !admission.valid)
	testing.expect_value(t, h.presentation_metrics.stale_generation_drops, drops + 1)

	stale_legacy := host_presentation_test_legacy(10)
	admission = host_presentation_admit_legacy(&h, stale_legacy)
	testing.expect(t, !admission.valid)
	testing.expect_value(t, h.presentation_metrics.stale_generation_drops, drops + 2)

	stale_gsw := host_presentation_test_snapshot(9)
	gsw_admission := host_presentation_admit_gsw(&h, stale_gsw, 640 * 480 * 4)
	testing.expect(t, !gsw_admission.valid)
	testing.expect_value(t, h.presentation_metrics.stale_generation_drops, drops + 3)
	testing.expect_value(t, h.presentation_state.selector.active.kind, contract.Active_Kind.Legacy)
}

@(test)
host_presentation_test_invalid_record_is_not_counted_as_stale :: proc(t: ^testing.T) {
	h: Host
	if !host_presentation_test_seed_legacy(t, &h) {return}
	drops := h.presentation_metrics.stale_generation_drops
	invalid := h.presentation_metrics.invalid_rejections
	malformed := host_presentation_test_legacy(11)
	malformed.header.mode_generation = 0

	admission := host_presentation_admit_legacy(&h, malformed)

	testing.expect(t, !admission.valid)
	testing.expect_value(t, h.presentation_metrics.stale_generation_drops, drops)
	testing.expect_value(t, h.presentation_metrics.invalid_rejections, invalid + 1)
}

@(test)
host_presentation_test_vga_source_mode_rejects_missing_stale_and_ambiguous_transitions :: proc(
	t: ^testing.T,
) {
	h: Host
	if !host_presentation_test_seed_legacy(t, &h) {return}
	before := h.presentation_state
	drops := h.presentation_metrics.stale_generation_drops

	missing := host_presentation_test_snapshot(20)
	missing.header.mode_generation = 1
	admission := host_presentation_admit_gsw(&h, missing, 640 * 480 * 4)
	testing.expect(t, !admission.valid)
	testing.expect_value(t, h.presentation_state, before)

	ambiguous := host_presentation_test_snapshot(20)
	ambiguous.header.mode_generation = 1 + contract.GENERATION_HALF_RANGE
	admission = host_presentation_admit_gsw(&h, ambiguous, 640 * 480 * 4)
	testing.expect(t, !admission.valid)
	testing.expect_value(t, h.presentation_state, before)

	older := host_presentation_test_snapshot(20)
	older.header.mode_generation = max(u64)
	admission = host_presentation_admit_gsw(&h, older, 640 * 480 * 4)
	testing.expect(t, !admission.valid)
	testing.expect_value(t, h.presentation_state, before)

	spurious := host_presentation_test_legacy(11)
	spurious.header.mode_generation = 2
	admission = host_presentation_admit_legacy(&h, spurious)
	testing.expect(t, !admission.valid)
	testing.expect_value(t, h.presentation_state, before)
	testing.expect_value(t, h.presentation_metrics.stale_generation_drops, drops + 4)
}

@(test)
host_presentation_test_local_resident_requires_exact_canonical_mode_generation :: proc(
	t: ^testing.T,
) {
	h: Host
	if !host_presentation_test_seed_legacy(t, &h) {return}
	before := h.presentation_state
	drops := h.presentation_metrics.stale_generation_drops

	stale := host_presentation_test_resident(20)
	admission := host_presentation_admit_gsw(&h, stale)
	testing.expect(t, !admission.valid)
	testing.expect_value(t, h.presentation_state, before)
	testing.expect_value(t, h.presentation_metrics.stale_generation_drops, drops + 1)

	current := host_presentation_test_local_resident(&h, 20)
	admission = host_presentation_admit_gsw(&h, current)
	testing.expect(t, admission.valid)
	testing.expect_value(t, admission.mode_clock.generation, u64(2))
}

@(test)
host_presentation_test_legacy_surface_generation_cannot_roll_back :: proc(t: ^testing.T) {
	identities := [?]contract.Surface_Identity {
		{id = 11, generation = max(u64)},
		{id = 11, generation = 1 + contract.GENERATION_HALF_RANGE},
		{id = 12, generation = 1},
	}
	for identity in identities {
		h: Host
		if !host_presentation_test_seed_legacy(t, &h) {continue}
		before_selector := h.presentation_state.selector
		before_clock := h.presentation_state.mode_clock
		before_sequence := h.presentation_state.sequence
		before_legacy := h.presentation_state.legacy
		drops := h.presentation_metrics.stale_generation_drops
		update := host_presentation_test_legacy(11)
		update.header.surface = identity

		admission := host_presentation_admit_legacy(&h, update)

		testing.expect(t, !admission.valid)
		testing.expect_value(t, h.presentation_state.selector, before_selector)
		testing.expect_value(t, h.presentation_state.mode_clock, before_clock)
		testing.expect_value(t, h.presentation_state.sequence, before_sequence)
		testing.expect_value(t, h.presentation_state.legacy, before_legacy)
		testing.expect_value(t, h.presentation_metrics.stale_generation_drops, drops + 1)
	}
}

@(test)
host_presentation_test_zero_legacy_surface_generation_rejects_transactionally :: proc(
	t: ^testing.T,
) {
	h: Host
	if !host_presentation_test_seed_legacy(t, &h) {return}
	before_selector := h.presentation_state.selector
	before_clock := h.presentation_state.mode_clock
	before_sequence := h.presentation_state.sequence
	invalid := h.presentation_metrics.invalid_rejections
	update := host_presentation_test_legacy(11)
	update.header.surface.generation = 0

	admission := host_presentation_admit_legacy(&h, update)

	testing.expect(t, !admission.valid)
	testing.expect_value(t, h.presentation_state.selector, before_selector)
	testing.expect_value(t, h.presentation_state.mode_clock, before_clock)
	testing.expect_value(t, h.presentation_state.sequence, before_sequence)
	testing.expect_value(t, h.presentation_metrics.invalid_rejections, invalid + 1)
}

@(test)
host_presentation_test_legacy_content_preserves_surface_and_mode_generations :: proc(
	t: ^testing.T,
) {
	h: Host
	if !host_presentation_test_seed_legacy(t, &h) {return}
	update := host_presentation_test_legacy(11)

	admission := host_presentation_admit_legacy(&h, update)

	testing.expect(t, admission.valid)
	testing.expect_value(t, admission.result.action, contract.Selector_Action.Present_Legacy)
	testing.expect_value(t, admission.mode_clock.generation, u64(1))
	testing.expect_value(t, admission.mode_clock.owner, contract.Display_Owner.Legacy)
	testing.expect_value(t, admission.legacy.header.surface, update.header.surface)
}

@(test)
host_presentation_test_new_legacy_identity_and_geometry_advance_independent_clocks :: proc(
	t: ^testing.T,
) {
	h: Host
	if !host_presentation_test_seed_legacy(t, &h) {return}
	replacement := host_presentation_test_legacy(11)
	replacement.header.surface.generation = 2
	admission := host_presentation_admit_legacy(&h, replacement)
	testing.expect(t, admission.valid)
	testing.expect_value(t, admission.mode_clock.generation, u64(1))
	testing.expect_value(t, admission.legacy.header.surface.generation, u64(2))

	h = {}
	if !host_presentation_test_seed_legacy(t, &h) {return}
	geometry := host_presentation_test_legacy(11, 1, host_presentation_test_mode_key(800, 600))
	geometry.header.mode_generation = 2
	geometry.header.surface.generation = 2
	admission = host_presentation_admit_legacy(&h, geometry)
	testing.expect(t, admission.valid)
	testing.expect_value(t, admission.result.action, contract.Selector_Action.Present_Legacy)
	testing.expect_value(t, admission.mode_clock.generation, u64(2))
	testing.expect_value(t, admission.legacy.header.surface.generation, u64(2))
}

@(test)
host_presentation_test_same_mode_legacy_refresh_preserves_active_gsw :: proc(t: ^testing.T) {
	h: Host
	if !host_presentation_test_seed_resident(t, &h) {return}
	active := h.presentation_state.selector.active

	refresh := host_presentation_test_legacy(11)
	admission := host_presentation_admit_legacy(&h, refresh)
	testing.expect(t, admission.valid)
	testing.expect_value(t, admission.result.action, contract.Selector_Action.Refresh_Legacy)
	testing.expect_value(t, admission.mode_clock.owner, contract.Display_Owner.Gsw3d)
	testing.expect_value(t, admission.mode_clock.generation, u64(2))
	testing.expect_value(t, admission.selector.active, active)
	testing.expect_value(t, admission.selector.active.kind, contract.Active_Kind.Gsw)
	testing.expect_value(t, h.presentation_state.selector.active.kind, contract.Active_Kind.Gsw)
}

@(test)
host_presentation_test_cross_geometry_legacy_content_stays_hidden_under_gsw :: proc(
	t: ^testing.T,
) {
	h: Host
	if !host_presentation_test_seed_legacy(t, &h) {return}
	present := host_presentation_test_local_resident(
		&h,
		20,
		1,
		host_presentation_test_mode_key(800, 600),
	)
	admission := host_presentation_admit_gsw(&h, present)
	if !testing.expect(t, admission.valid) {return}
	host_presentation_test_install_surface(&h, admission.gsw)
	if !testing.expect(
		t,
		host_presentation_commit_resident(
			&h,
			&admission,
			host_presentation_test_physical(admission.gsw),
		),
	) {return}
	active := h.presentation_state.selector.active
	clock := h.presentation_state.mode_clock

	refresh := host_presentation_test_legacy(21)
	admission = host_presentation_admit_legacy(&h, refresh)

	testing.expect(t, admission.valid)
	testing.expect_value(t, admission.result.action, contract.Selector_Action.Refresh_Legacy)
	testing.expect_value(t, admission.selector.active, active)
	testing.expect_value(t, admission.mode_clock, clock)
	testing.expect_value(t, admission.vga_mode_clock, h.presentation_state.vga_mode_clock)
}

@(test)
host_presentation_test_gsw2d_hidden_legacy_requires_last_good_geometry :: proc(t: ^testing.T) {
	h: Host
	if !host_presentation_test_seed_legacy(t, &h) {return}
	snapshot := host_presentation_test_snapshot(20, 1, host_presentation_test_mode_key(800, 600))
	admission := host_presentation_admit_gsw(&h, snapshot, 800 * 600 * 4)
	if !testing.expect(t, admission.valid) {return}
	host_presentation_test_apply_gsw(&h, admission)
	active := h.presentation_state.selector.active

	refresh := host_presentation_test_legacy(21)
	refresh.header.mode_generation = 2
	admission = host_presentation_admit_legacy(&h, refresh)
	if !testing.expect(t, admission.valid) {return}
	testing.expect_value(t, admission.result.action, contract.Selector_Action.Refresh_Legacy)
	testing.expect_value(t, admission.selector.active, active)

	poisoned := host_presentation_test_legacy(22, 1, host_presentation_test_mode_key(1024, 768))
	poisoned.header.mode_generation = 2
	poisoned.header.surface.generation = 2
	drops := h.presentation_metrics.stale_generation_drops
	admission = host_presentation_admit_legacy(&h, poisoned)
	testing.expect(t, !admission.valid)
	testing.expect_value(t, h.presentation_state.selector.active, active)
	testing.expect_value(t, h.presentation_metrics.stale_generation_drops, drops + 1)
}

@(test)
host_presentation_test_gsw2d_hidden_legacy_bootstraps_current_geometry :: proc(t: ^testing.T) {
	h: Host
	if !host_presentation_test_seed_legacy(t, &h) {return}
	key := host_presentation_test_mode_key(800, 600)
	snapshot := host_presentation_test_snapshot(20, 1, key)
	admission := host_presentation_admit_gsw(&h, snapshot, 800 * 600 * 4)
	if !testing.expect(t, admission.valid) {return}
	host_presentation_test_apply_gsw(&h, admission)
	active := h.presentation_state.selector.active

	bootstrap := host_presentation_test_legacy(21, 1, key)
	bootstrap.header.mode_generation = 2
	bootstrap.header.surface.generation = 2
	admission = host_presentation_admit_legacy(&h, bootstrap)
	if !testing.expect(t, admission.valid) {return}
	testing.expect_value(t, admission.result.action, contract.Selector_Action.Refresh_Legacy)
	testing.expect_value(t, admission.selector.active, active)

	wrong_active := h
	wrong_active.presentation_state.selector.active.sequence = contract.generation_next(
		wrong_active.presentation_state.selector.active.sequence,
	)
	drops := wrong_active.presentation_metrics.stale_generation_drops
	bad := host_presentation_admit_legacy(&wrong_active, bootstrap)
	testing.expect(t, !bad.valid)
	testing.expect_value(t, wrong_active.presentation_metrics.stale_generation_drops, drops + 1)

	stale := bootstrap
	stale.header.sequence = 22
	stale.header.mode_generation = 1
	drops = h.presentation_metrics.stale_generation_drops
	bad = host_presentation_admit_legacy(&h, stale)
	testing.expect(t, !bad.valid)
	testing.expect_value(t, h.presentation_metrics.stale_generation_drops, drops + 1)
}

@(test)
host_presentation_test_new_legacy_geometry_reclaims_active_gsw :: proc(t: ^testing.T) {
	h: Host
	if !host_presentation_test_seed_resident(t, &h) {return}
	update := host_presentation_test_legacy(21, 1, host_presentation_test_mode_key(800, 600))
	update.header.mode_generation = 2
	update.header.surface.generation = 2

	admission := host_presentation_admit_legacy(&h, update)

	testing.expect(t, admission.valid)
	testing.expect_value(t, admission.result.action, contract.Selector_Action.Present_Legacy)
	testing.expect_value(t, admission.mode_clock.owner, contract.Display_Owner.Legacy)
	testing.expect_value(t, admission.mode_clock.generation, u64(3))
	testing.expect_value(t, admission.selector.active.kind, contract.Active_Kind.Legacy)
	testing.expect_value(t, admission.selector.active.surface, update.header.surface)
}

@(test)
host_presentation_test_same_geometry_gsw_adapter_transition_advances_mode :: proc(t: ^testing.T) {
	h: Host
	if !host_presentation_test_seed_legacy(t, &h) {return}
	snapshot := host_presentation_test_snapshot(20)
	snapshot_admission := host_presentation_admit_gsw(&h, snapshot, 640 * 480 * 4)
	if !testing.expect(t, snapshot_admission.valid) {return}
	testing.expect_value(t, snapshot_admission.mode_clock.owner, contract.Display_Owner.Gsw2d)
	testing.expect_value(t, snapshot_admission.mode_clock.generation, u64(2))
	host_presentation_test_apply_gsw(&h, snapshot_admission)

	resident := host_presentation_test_local_resident(&h, 21)
	resident_admission := host_presentation_admit_gsw(&h, resident)
	testing.expect(t, resident_admission.valid)
	testing.expect_value(t, resident_admission.mode_clock.owner, contract.Display_Owner.Gsw3d)
	testing.expect_value(t, resident_admission.mode_clock.generation, u64(3))
	testing.expect_value(
		t,
		resident_admission.selector.display_owner,
		contract.Display_Owner.Gsw3d,
	)
}

@(test)
host_presentation_test_newer_gsw_mode_preserves_last_good_legacy :: proc(t: ^testing.T) {
	h: Host
	if !host_presentation_test_seed_resident(t, &h) {return}
	key := host_presentation_test_mode_key(800, 600)
	present := host_presentation_test_local_resident(&h, 21, 1, key)

	admission := host_presentation_admit_gsw(&h, present)
	testing.expect(t, admission.valid)
	testing.expect_value(t, admission.result.action, contract.Selector_Action.Present_Gsw)
	testing.expect_value(t, admission.mode_clock.generation, u64(3))
	testing.expect_value(t, admission.selector.mode_generation, u64(3))
	testing.expect_value(t, admission.selector.active.kind, contract.Active_Kind.Gsw)
	testing.expect(t, admission.selector.has_last_good_legacy)
}

@(test)
host_presentation_test_exact_invalidation_restores_last_good :: proc(t: ^testing.T) {
	h: Host
	if !host_presentation_test_seed_resident(t, &h) {return}
	legacy := h.presentation_state.legacy
	before := h.presentation_metrics.last_good_restorations

	action := host_presentation_invalidate_active(&h, .Gsw3d, .Surface_Destroyed)
	testing.expect_value(t, action, contract.Selector_Action.Restore_Legacy)
	testing.expect_value(t, h.presentation_state.selector.active.kind, contract.Active_Kind.Legacy)
	testing.expect_value(t, h.presentation_state.mode_clock.owner, contract.Display_Owner.Legacy)
	testing.expect_value(t, h.presentation_state.mode_clock.generation, u64(3))
	testing.expect(
		t,
		contract.surface_identity_equal(
			h.presentation_state.selector.active.surface,
			legacy.header.surface,
		),
	)
	testing.expect_value(t, h.presentation_state.gsw, contract.Gsw_Present{})
	testing.expect_value(t, h.gpu_present, Host_Gpu_Present{})
	testing.expect(t, h.has_frame)
	testing.expect_value(t, h.presentation_metrics.last_good_restorations, before + 1)
}

@(test)
host_presentation_test_missing_legacy_texture_clears_resident_invalidation :: proc(t: ^testing.T) {
	h: Host
	if !host_presentation_test_seed_resident(t, &h) {return}
	h.tex = nil
	h.tex_width = 0
	h.tex_height = 0
	invalidation := host_presentation_test_invalidation(&h, .Gsw3d, .Surface_Destroyed)
	testing.expect(t, host_presentation_invalidation_matches_active(&h, invalidation))

	action := host_presentation_apply_invalidation(&h, invalidation)
	testing.expect_value(t, action, contract.Selector_Action.Clear)
	testing.expect_value(t, h.presentation_state.selector.active.kind, contract.Active_Kind.None)
	testing.expect(t, !h.presentation_state.selector.has_last_good_legacy)
	testing.expect(t, !h.has_frame)
}

@(test)
host_presentation_test_paired_legacy_refresh_precedes_one_restoration :: proc(t: ^testing.T) {
	h: Host
	if !host_presentation_test_seed_resident(t, &h) {return}
	before := h.presentation_metrics.last_good_restorations
	invalidation := host_presentation_test_invalidation(&h, .Gsw3d, .Process_Exit)
	paired := host_presentation_invalidation_matches_active(&h, invalidation)
	if !testing.expect(t, paired) {return}
	refresh := host_presentation_test_legacy(21, 1, host_presentation_test_mode_key(800, 600))
	refresh.header.mode_generation = 2
	refresh.header.surface.generation = 2
	admission := host_presentation_admit_legacy(&h, refresh, paired)
	if !testing.expect(t, admission.valid) {return}
	testing.expect_value(t, admission.result.action, contract.Selector_Action.Refresh_Legacy)
	testing.expect_value(t, admission.mode_clock.owner, contract.Display_Owner.Gsw3d)
	testing.expect_value(t, admission.mode_clock.generation, u64(2))
	h.presentation_state.selector = admission.selector
	h.presentation_state.mode_clock = admission.mode_clock
	h.presentation_state.vga_mode_clock = admission.vga_mode_clock
	h.presentation_state.legacy = admission.legacy
	h.presentation_state.last_vga_sequence = admission.source_sequence

	action := host_presentation_apply_invalidation(&h, invalidation)
	testing.expect_value(t, action, contract.Selector_Action.Restore_Legacy)
	testing.expect_value(t, h.presentation_state.selector.active.kind, contract.Active_Kind.Legacy)
	testing.expect_value(t, h.presentation_state.mode_clock.owner, contract.Display_Owner.Legacy)
	testing.expect_value(t, h.presentation_state.mode_clock.generation, u64(3))
	testing.expect(
		t,
		contract.mode_key_equal(h.presentation_state.mode_clock.key, refresh.header.mode_key),
	)
	testing.expect_value(t, h.presentation_state.legacy.header.surface, refresh.header.surface)
	testing.expect_value(t, h.presentation_metrics.last_good_restorations, before + 1)
}

@(test)
host_presentation_test_paired_invalidation_requires_exact_active_identity :: proc(t: ^testing.T) {
	h: Host
	if !host_presentation_test_seed_resident(t, &h) {return}
	exact := host_presentation_test_invalidation(&h, .Gsw3d, .Process_Exit)
	if !testing.expect(t, host_presentation_invalidation_matches_active(&h, exact)) {return}
	state := h.presentation_state

	mismatch := exact
	mismatch.lifecycle_generation = contract.generation_next(mismatch.lifecycle_generation)
	testing.expect(t, !host_presentation_invalidation_matches_active(&h, mismatch))
	mismatch = exact
	mismatch.mode_generation = contract.generation_next(mismatch.mode_generation)
	testing.expect(t, !host_presentation_invalidation_matches_active(&h, mismatch))
	mismatch = exact
	mismatch.mode_key = host_presentation_test_mode_key(800, 600)
	testing.expect(t, !host_presentation_invalidation_matches_active(&h, mismatch))
	mismatch = exact
	mismatch.identity_namespace = .Gsw2d
	testing.expect(t, !host_presentation_invalidation_matches_active(&h, mismatch))
	mismatch = exact
	mismatch.device_generation = contract.generation_next(mismatch.device_generation)
	testing.expect(t, !host_presentation_invalidation_matches_active(&h, mismatch))
	mismatch = exact
	mismatch.surface.generation = contract.generation_next(mismatch.surface.generation)
	testing.expect(t, !host_presentation_invalidation_matches_active(&h, mismatch))
	mismatch = exact
	mismatch.reason = .Invalid
	testing.expect(t, !host_presentation_invalidation_matches_active(&h, mismatch))
	testing.expect_value(t, h.presentation_state, state)

	h.presentation_state.selector.active.display_owner = .Gsw2d
	testing.expect(t, !host_presentation_invalidation_matches_active(&h, exact))
	h.presentation_state = state
	h.presentation_state.selector.display_owner = .Gsw2d
	testing.expect(t, !host_presentation_invalidation_matches_active(&h, exact))
	h.presentation_state = state
	h.presentation_state.mode_clock.owner = .Gsw2d
	testing.expect(t, !host_presentation_invalidation_matches_active(&h, exact))
	h.presentation_state = state
	testing.expect_value(t, h.presentation_state, state)
}

@(test)
host_presentation_test_stale_pair_cannot_suppress_newer_legacy_mode :: proc(t: ^testing.T) {
	h: Host
	if !host_presentation_test_seed_resident(t, &h) {return}
	stale := host_presentation_test_invalidation(&h, .Gsw3d, .Mode_Changed)
	stale.surface.generation = contract.generation_next(stale.surface.generation)
	paired := host_presentation_invalidation_matches_active(&h, stale)
	if !testing.expect(t, !paired) {return}
	update := host_presentation_test_legacy(21, 1, host_presentation_test_mode_key(800, 600))
	update.header.mode_generation = 2
	update.header.surface.generation = 2
	admission := host_presentation_admit_legacy(&h, update, paired)
	if !testing.expect(t, admission.valid) {return}
	testing.expect_value(t, admission.result.action, contract.Selector_Action.Present_Legacy)
	testing.expect_value(t, admission.mode_clock.owner, contract.Display_Owner.Legacy)
	before_invalidation := admission.selector
	h.presentation_state.selector = admission.selector
	h.presentation_state.mode_clock = admission.mode_clock
	h.presentation_state.vga_mode_clock = admission.vga_mode_clock
	h.presentation_state.legacy = admission.legacy
	h.presentation_state.last_vga_sequence = admission.source_sequence

	action := host_presentation_apply_invalidation(&h, stale)
	testing.expect_value(t, action, contract.Selector_Action.None)
	testing.expect_value(t, h.presentation_state.selector, before_invalidation)
	testing.expect_value(t, h.presentation_state.selector.active.kind, contract.Active_Kind.Legacy)
	testing.expect_value(t, h.presentation_state.mode_clock.owner, contract.Display_Owner.Legacy)
}

@(test)
host_presentation_test_gsw_teardown_without_legacy_advances_to_none :: proc(t: ^testing.T) {
	h: Host
	if !testing.expect(t, host_presentation_start(&h, 1)) {return}
	present := host_presentation_test_local_resident(&h, 20)
	admission := host_presentation_admit_gsw(&h, present)
	if !testing.expect(t, admission.valid) {return}
	host_presentation_test_install_surface(&h, admission.gsw)
	if !testing.expect(
		t,
		host_presentation_commit_resident(
			&h,
			&admission,
			host_presentation_test_physical(admission.gsw),
		),
	) {return}
	testing.expect_value(t, h.presentation_state.mode_clock.owner, contract.Display_Owner.Gsw3d)
	testing.expect_value(t, h.presentation_state.mode_clock.generation, u64(1))

	action := host_presentation_invalidate_active(&h, .Gsw3d, .Device_Reset)
	testing.expect_value(t, action, contract.Selector_Action.Clear)
	testing.expect_value(t, h.presentation_state.mode_clock.owner, contract.Display_Owner.None)
	testing.expect_value(t, h.presentation_state.mode_clock.generation, u64(2))
	testing.expect(t, !h.has_frame)
}

@(test)
host_presentation_test_cross_mode_teardown_restores_legacy_desktop :: proc(t: ^testing.T) {
	reasons := [?]contract.Invalidation_Reason{.Surface_Destroyed, .Device_Reset, .Process_Exit}
	for reason in reasons {
		h: Host
		if !host_presentation_test_seed_legacy(t, &h) {continue}
		legacy_texture := transmute(^sdl3.Texture)(uintptr(30))
		h.tex = legacy_texture
		h.tex_width = 640
		h.tex_height = 480
		legacy_surface := h.presentation_state.legacy.header.surface
		legacy_key := h.presentation_state.legacy.header.mode_key
		present := host_presentation_test_local_resident(
			&h,
			20,
			1,
			host_presentation_test_mode_key(800, 600),
		)
		admission := host_presentation_admit_gsw(&h, present)
		if !testing.expect(t, admission.valid) {continue}
		host_presentation_test_install_surface(&h, admission.gsw)
		if !testing.expect(
			t,
			host_presentation_commit_resident(
				&h,
				&admission,
				host_presentation_test_physical(admission.gsw),
			),
		) {
			continue
		}
		gsw_mode := h.presentation_state.selector.mode_generation
		gsw_sequence := h.presentation_state.selector.sequence
		testing.expect(t, h.presentation_state.selector.has_last_good_legacy)

		action := host_presentation_invalidate_active(&h, .Gsw3d, reason)
		testing.expect_value(t, action, contract.Selector_Action.Restore_Legacy)
		testing.expect_value(
			t,
			h.presentation_state.selector.active.kind,
			contract.Active_Kind.Legacy,
		)
		testing.expect(
			t,
			contract.generation_is_newer(h.presentation_state.mode_clock.generation, gsw_mode),
		)
		testing.expect(
			t,
			contract.generation_is_newer(h.presentation_state.sequence, gsw_sequence),
		)
		testing.expect_value(
			t,
			h.presentation_state.selector.active.mode_generation,
			h.presentation_state.mode_clock.generation,
		)
		testing.expect(t, contract.mode_key_equal(h.presentation_state.mode_clock.key, legacy_key))
		testing.expect(
			t,
			contract.surface_identity_equal(
				h.presentation_state.selector.active.surface,
				legacy_surface,
			),
		)
		testing.expect_value(t, h.tex, legacy_texture)
		testing.expect_value(t, h.gpu_present, Host_Gpu_Present{})
		testing.expect_value(t, h.aspect_width, 640)
		testing.expect_value(t, h.aspect_height, 480)
		testing.expect(t, h.has_frame)
	}
}

@(test)
host_presentation_test_gsw2d_source_format_change_retains_desktop_restore :: proc(t: ^testing.T) {
	h: Host
	if !host_presentation_test_seed_legacy(t, &h) {return}
	h.tex = transmute(^sdl3.Texture)(uintptr(91))
	h.tex_width = 640
	h.tex_height = 480
	first := host_presentation_test_snapshot(20)
	first_admission := host_presentation_admit_gsw(&h, first, 640 * 480 * 4)
	if !testing.expect(t, first_admission.valid) {return}
	testing.expect_value(t, first_admission.mode_clock.generation, u64(2))
	host_presentation_test_apply_gsw(&h, first_admission)

	second := host_presentation_test_snapshot(21)
	second.header.mode_generation = 2
	second.header.surface.generation += 1
	second.header.mode_key.format = .Indexed_8
	second.header.format = .Indexed_8
	second.source_pitch = second.header.surface_extent.width
	second_admission := host_presentation_admit_gsw(&h, second, 640 * 480)
	if !testing.expect(t, second_admission.valid) {return}
	testing.expect_value(t, second_admission.mode_clock.generation, u64(2))
	testing.expect(t, second_admission.selector.has_last_good_legacy)
	host_presentation_test_apply_gsw(&h, second_admission)

	action := host_presentation_apply_invalidation(
		&h,
		host_presentation_test_invalidation(&h, .Gsw2d, .Process_Exit),
	)
	testing.expect_value(t, action, contract.Selector_Action.Restore_Legacy)
	testing.expect_value(t, h.presentation_state.selector.active.kind, contract.Active_Kind.Legacy)
}

@(test)
host_presentation_test_stop_clears_selection_and_rejects_more_work :: proc(t: ^testing.T) {
	h: Host
	if !host_presentation_test_seed_resident(t, &h) {return}
	host_presentation_stop(&h)

	testing.expect(t, !h.presentation_state.accepting)
	testing.expect_value(t, h.presentation_state.selector, contract.Selector{})
	testing.expect_value(t, h.presentation_state.vga_mode_clock, contract.Mode_Clock{})
	testing.expect_value(t, h.presentation_state.mode_clock, contract.Mode_Clock{})
	testing.expect_value(t, h.presentation_state.legacy, contract.Legacy_Frame_Update{})
	testing.expect_value(t, h.presentation_state.gsw, contract.Gsw_Present{})
	testing.expect_value(t, h.gpu_present, Host_Gpu_Present{})
	testing.expect(t, !h.has_frame)

	drops := h.presentation_metrics.stale_generation_drops
	closed := h.presentation_metrics.closed_rejections
	admission := host_presentation_admit_gsw(&h, host_presentation_test_resident(21))
	testing.expect(t, !admission.valid)
	testing.expect_value(t, h.presentation_metrics.stale_generation_drops, drops)
	testing.expect_value(t, h.presentation_metrics.closed_rejections, closed + 1)
}

@(test)
host_presentation_test_physical_work_is_recorded_before_selection_commit :: proc(t: ^testing.T) {
	h: Host
	frame := vga.Display_Frame {
		width          = 4,
		height         = 2,
		updated_pixels = 8,
	}
	host_presentation_record_descriptor_copy(&h, 16)
	host_presentation_record_conversion(&h, &frame)
	host_presentation_record_upload(&h, frame.width, frame.height)

	testing.expect_value(t, h.presentation_metrics.copy_bytes, u64(16))
	testing.expect_value(t, h.presentation_metrics.conversion_pixels, u64(8))
	testing.expect_value(t, h.presentation_metrics.upload_bytes, u64(32))
	testing.expect_value(t, h.presentation_metrics.upload_regions, u64(1))
}

@(test)
host_presentation_test_resident_commit_preserves_zero_copy_metrics :: proc(t: ^testing.T) {
	h: Host
	if !host_presentation_test_seed_legacy(t, &h) {return}
	h.presentation_metrics = {
		legacy_full_updates          = 2,
		legacy_partial_updates       = 3,
		gsw_snapshot_full_updates    = 4,
		gsw_snapshot_partial_updates = 5,
		copy_bytes                   = 4096,
		conversion_pixels            = 307200,
		upload_bytes                 = 1228800,
		upload_regions               = 4,
		stale_generation_drops       = 6,
		stale_finalization_drops     = 2,
		invalid_rejections           = 7,
		closed_rejections            = 8,
		readback_requests            = 5,
		resident_presents            = 9,
		last_good_restorations       = 10,
	}

	present := host_presentation_test_local_resident(&h, 20)
	admission := host_presentation_admit_gsw(&h, present)
	if !testing.expect(t, admission.valid) {return}
	host_presentation_test_install_surface(&h, admission.gsw)
	physical := host_presentation_test_physical(admission.gsw)
	before := h.presentation_metrics
	testing.expect(t, host_presentation_commit_resident(&h, &admission, physical))
	after := h.presentation_metrics

	testing.expect(t, host_presentation_resident_zero_work(before, after))
	testing.expect_value(t, after.copy_bytes, before.copy_bytes)
	testing.expect_value(t, after.conversion_pixels, before.conversion_pixels)
	testing.expect_value(t, after.upload_bytes, before.upload_bytes)
	testing.expect_value(t, after.upload_regions, before.upload_regions)
	testing.expect_value(t, after.readback_requests, before.readback_requests)
	testing.expect_value(t, h.gpu_direct_presents, u64(1))
}

@(test)
host_presentation_test_resident_commit_requires_exact_admitted_physical_present :: proc(
	t: ^testing.T,
) {
	h: Host
	if !host_presentation_test_seed_legacy(t, &h) {return}
	present := host_presentation_test_local_resident(&h, 20)
	admission := host_presentation_admit_gsw(&h, present)
	if !testing.expect(t, admission.valid) {return}
	host_presentation_test_install_surface(&h, admission.gsw)
	exact := host_presentation_test_physical(admission.gsw)
	selector := h.presentation_state.selector
	selected := h.gpu_present
	resident := h.presentation_metrics.resident_presents

	mismatch := exact
	mismatch.surface_id += 1
	testing.expect(t, !host_presentation_commit_resident(&h, &admission, mismatch))
	mismatch = exact
	mismatch.source.x = 1
	mismatch.source.width -= 1
	testing.expect(t, !host_presentation_commit_resident(&h, &admission, mismatch))
	mismatch = exact
	mismatch.destination.x = 1
	mismatch.destination.width -= 1
	testing.expect(t, !host_presentation_commit_resident(&h, &admission, mismatch))
	mismatch = exact
	mismatch.canvas_width += 1
	testing.expect(t, !host_presentation_commit_resident(&h, &admission, mismatch))
	mismatch = exact
	mismatch.interval = 0
	testing.expect(t, !host_presentation_commit_resident(&h, &admission, mismatch))
	original_generation := h.gpu_surfaces[0].generation
	h.gpu_surfaces[0].generation = contract.generation_next(original_generation)
	testing.expect(t, !host_presentation_commit_resident(&h, &admission, exact))
	h.gpu_surfaces[0].generation = original_generation

	testing.expect_value(t, h.presentation_state.selector, selector)
	testing.expect_value(t, h.gpu_present, selected)
	testing.expect_value(t, h.presentation_metrics.resident_presents, resident)
	testing.expect(t, host_presentation_commit_resident(&h, &admission, exact))
	testing.expect_value(t, h.presentation_metrics.resident_presents, resident + 1)
}

@(test)
host_presentation_test_full_and_partial_update_classification_is_exact :: proc(t: ^testing.T) {
	header := host_presentation_test_legacy(1).header
	testing.expect(t, host_presentation_full_update(header))

	header.dirty = {}
	_ = contract.rect_set_append(&header.dirty, {0, 0, 320, 480})
	testing.expect(t, !host_presentation_full_update(header))

	header.dirty = {}
	_ = contract.rect_set_append(&header.dirty, {0, 0, 320, 480})
	_ = contract.rect_set_append(&header.dirty, {320, 0, 320, 480})
	testing.expect(t, !host_presentation_full_update(header))
}

@(test)
host_presentation_test_legacy_success_counters_follow_committed_physical_work :: proc(
	t: ^testing.T,
) {
	h: Host
	if !host_presentation_test_seed_legacy(t, &h) {return}
	h.tex = transmute(^sdl3.Texture)(uintptr(40))
	h.tex_width = 640
	h.tex_height = 480

	full := host_presentation_admit_legacy(&h, host_presentation_test_legacy(11))
	if !testing.expect(t, full.valid) {return}
	h.presentation_state.legacy_staging = {
		texture          = transmute(^sdl3.Texture)(uintptr(41)),
		width            = 640,
		height           = 480,
		stage_generation = 1,
	}
	frame := vga.Display_Frame {
		width          = 4,
		height         = 2,
		updated_pixels = 8,
	}
	host_presentation_record_descriptor_copy(&h, 16)
	host_presentation_record_conversion(&h, &frame)
	host_presentation_record_upload(&h, frame.width, frame.height)
	full_staged := host_presentation_test_staged(
		&full,
		h.presentation_state.legacy_staging.texture,
		1,
	)
	if !testing.expect(t, host_presentation_commit_legacy_staged(&h, &full, full_staged)) {
		return
	}
	testing.expect_value(t, h.presentation_metrics.legacy_full_updates, u64(1))
	testing.expect_value(t, h.presentation_metrics.legacy_partial_updates, u64(0))
	testing.expect_value(t, h.presentation_metrics.copy_bytes, u64(16))
	testing.expect_value(t, h.presentation_metrics.conversion_pixels, u64(8))
	testing.expect_value(t, h.presentation_metrics.upload_bytes, u64(32))
	testing.expect_value(t, h.presentation_metrics.upload_regions, u64(1))

	partial_update := host_presentation_test_legacy(12)
	partial_update.header.dirty = {}
	_ = contract.rect_set_append(&partial_update.header.dirty, {0, 0, 320, 480})
	partial := host_presentation_admit_legacy(&h, partial_update)
	if !testing.expect(t, partial.valid) {return}
	h.presentation_state.legacy_staging = {
		texture          = transmute(^sdl3.Texture)(uintptr(42)),
		width            = 640,
		height           = 480,
		stage_generation = 2,
	}
	frame = {
		width          = 8,
		height         = 4,
		updated_pixels = 32,
	}
	host_presentation_record_descriptor_copy(&h, 32)
	host_presentation_record_conversion(&h, &frame)
	host_presentation_record_upload(&h, frame.width, frame.height)
	partial_staged := host_presentation_test_staged(
		&partial,
		h.presentation_state.legacy_staging.texture,
		2,
	)
	if !testing.expect(t, host_presentation_commit_legacy_staged(&h, &partial, partial_staged)) {
		return
	}
	testing.expect_value(t, h.presentation_metrics.legacy_full_updates, u64(1))
	testing.expect_value(t, h.presentation_metrics.legacy_partial_updates, u64(1))
	testing.expect_value(t, h.presentation_metrics.copy_bytes, u64(48))
	testing.expect_value(t, h.presentation_metrics.conversion_pixels, u64(40))
	testing.expect_value(t, h.presentation_metrics.upload_bytes, u64(160))
	testing.expect_value(t, h.presentation_metrics.upload_regions, u64(2))

	stale := host_presentation_admit_legacy(&h, host_presentation_test_legacy(13))
	if !testing.expect(t, stale.valid) {return}
	h.presentation_state.legacy_staging = {
		texture          = transmute(^sdl3.Texture)(uintptr(43)),
		width            = 640,
		height           = 480,
		stage_generation = 3,
	}
	stale_staged := host_presentation_test_staged(
		&stale,
		h.presentation_state.legacy_staging.texture,
		3,
	)
	h.presentation_state.sequence = contract.generation_next(h.presentation_state.sequence)
	full_successes := h.presentation_metrics.legacy_full_updates
	partial_successes := h.presentation_metrics.legacy_partial_updates
	testing.expect(t, !host_presentation_commit_legacy_staged(&h, &stale, stale_staged))
	testing.expect_value(t, h.presentation_metrics.legacy_full_updates, full_successes)
	testing.expect_value(t, h.presentation_metrics.legacy_partial_updates, partial_successes)
}

@(test)
host_presentation_test_staged_legacy_refresh_swaps_only_last_good_texture :: proc(t: ^testing.T) {
	h: Host
	if !host_presentation_test_seed_resident(t, &h) {return}
	old_texture := transmute(^sdl3.Texture)(uintptr(2))
	new_texture := transmute(^sdl3.Texture)(uintptr(3))
	h.tex = old_texture
	h.tex_width = 640
	h.tex_height = 480
	h.presentation_state.legacy_staging = {
		texture          = new_texture,
		width            = 640,
		height           = 480,
		stage_generation = 9,
	}
	refresh := host_presentation_test_legacy(11)
	admission := host_presentation_admit_legacy(&h, refresh)
	if !testing.expect(t, admission.valid) {return}
	staged := host_presentation_test_staged(&admission, new_texture, 9)
	active := h.presentation_state.selector.active

	testing.expect(t, host_presentation_commit_legacy_staged(&h, &admission, staged))
	testing.expect_value(t, h.tex, new_texture)
	testing.expect_value(t, h.presentation_state.legacy_staging.texture, old_texture)
	testing.expect_value(t, h.presentation_state.selector.active, active)
	testing.expect_value(t, h.presentation_state.legacy, admission.legacy)

	action := host_presentation_invalidate_active(&h, .Gsw3d, .Surface_Destroyed)
	testing.expect_value(t, action, contract.Selector_Action.Restore_Legacy)
	testing.expect_value(t, h.tex, new_texture)
	testing.expect_value(t, h.presentation_state.selector.active.kind, contract.Active_Kind.Legacy)
}

@(test)
host_presentation_test_stale_staged_legacy_finalize_preserves_selected_state :: proc(
	t: ^testing.T,
) {
	h: Host
	if !host_presentation_test_seed_legacy(t, &h) {return}
	old_texture := transmute(^sdl3.Texture)(uintptr(4))
	staged_texture := transmute(^sdl3.Texture)(uintptr(5))
	h.tex = old_texture
	h.tex_width = 640
	h.tex_height = 480
	h.presentation_state.legacy_staging = {
		texture          = staged_texture,
		width            = 640,
		height           = 480,
		stage_generation = 10,
	}
	admission := host_presentation_admit_legacy(&h, host_presentation_test_legacy(11))
	staged := host_presentation_test_staged(&admission, staged_texture, 10)
	frame := vga.Display_Frame {
		width  = 640,
		height = 480,
	}
	host_presentation_record_descriptor_copy(&h, 64)
	host_presentation_record_conversion(&h, &frame)
	host_presentation_record_upload(&h, frame.width, frame.height)
	physical_work := h.presentation_metrics
	h.presentation_state.sequence = contract.generation_next(h.presentation_state.sequence)
	selector := h.presentation_state.selector
	legacy := h.presentation_state.legacy

	drops := h.presentation_metrics.stale_generation_drops
	finalizations := h.presentation_metrics.stale_finalization_drops
	testing.expect(t, !host_presentation_commit_legacy_staged(&h, &admission, staged))
	testing.expect_value(t, h.tex, old_texture)
	testing.expect_value(t, h.presentation_state.legacy_staging.texture, staged_texture)
	testing.expect_value(t, h.presentation_state.selector, selector)
	testing.expect_value(t, h.presentation_state.legacy, legacy)
	testing.expect_value(t, h.presentation_metrics.copy_bytes, physical_work.copy_bytes)
	testing.expect_value(
		t,
		h.presentation_metrics.conversion_pixels,
		physical_work.conversion_pixels,
	)
	testing.expect_value(t, h.presentation_metrics.upload_bytes, physical_work.upload_bytes)
	testing.expect_value(t, h.presentation_metrics.upload_regions, physical_work.upload_regions)
	testing.expect_value(t, h.presentation_metrics.stale_generation_drops, drops + 1)
	testing.expect_value(t, h.presentation_metrics.stale_finalization_drops, finalizations + 1)
}

@(test)
host_presentation_test_staged_gsw_snapshot_swaps_transactionally :: proc(t: ^testing.T) {
	h: Host
	if !host_presentation_test_seed_legacy(t, &h) {return}
	old_texture := transmute(^sdl3.Texture)(uintptr(6))
	new_texture := transmute(^sdl3.Texture)(uintptr(7))
	h.presentation_state.gsw_texture = old_texture
	h.presentation_state.gsw_texture_width = 320
	h.presentation_state.gsw_texture_height = 200
	h.presentation_state.gsw_staging = {
		texture          = new_texture,
		width            = 640,
		height           = 480,
		stage_generation = 11,
	}
	present := host_presentation_test_snapshot(20)
	admission := host_presentation_admit_gsw(&h, present, 640 * 480 * 4, .Capacity_Exceeded)
	if !testing.expect(t, admission.valid) {return}
	staged := host_presentation_test_staged(&admission, new_texture, 11)

	testing.expect(t, host_presentation_commit_gsw_snapshot_staged(&h, &admission, staged))
	testing.expect_value(t, h.presentation_state.gsw_texture, new_texture)
	testing.expect_value(t, h.presentation_state.gsw_staging.texture, old_texture)
	testing.expect_value(
		t,
		h.presentation_state.selector.active.source_kind,
		contract.Source_Kind.Gsw_Snapshot,
	)
	testing.expect_value(t, h.presentation_metrics.gsw_snapshot_full_updates, u64(1))
	testing.expect_value(t, h.presentation_metrics.gsw_snapshot_partial_updates, u64(0))
	testing.expect_value(t, h.presentation_metrics.source_full_capacity, u64(1))

	stale_texture := transmute(^sdl3.Texture)(uintptr(8))
	h.presentation_state.gsw_staging = {
		texture          = stale_texture,
		width            = 640,
		height           = 480,
		stage_generation = 12,
	}
	stale_admission := host_presentation_admit_gsw(
		&h,
		host_presentation_test_snapshot(21),
		640 * 480 * 4,
	)
	stale := host_presentation_test_staged(&stale_admission, stale_texture, 12)
	h.presentation_state.sequence = contract.generation_next(h.presentation_state.sequence)
	selector := h.presentation_state.selector
	committed := h.presentation_state.gsw
	testing.expect(t, !host_presentation_commit_gsw_snapshot_staged(&h, &stale_admission, stale))
	testing.expect_value(t, h.presentation_state.gsw_texture, new_texture)
	testing.expect_value(t, h.presentation_state.gsw_staging.texture, stale_texture)
	testing.expect_value(t, h.presentation_state.selector, selector)
	testing.expect_value(t, h.presentation_state.gsw, committed)
}

@(test)
host_presentation_test_gsw_fallback_reason_requires_a_full_snapshot :: proc(t: ^testing.T) {
	h: Host
	if !host_presentation_test_seed_legacy(t, &h) {return}
	present := host_presentation_test_snapshot(20)
	present.header.dirty = {}
	_ = contract.rect_set_append(&present.header.dirty, {1, 1, 2, 2})
	invalid := h.presentation_metrics.invalid_rejections
	admission := host_presentation_admit_gsw(&h, present, 640 * 480 * 4, .Ambiguous_Mapping)
	testing.expect(t, !admission.valid)
	testing.expect_value(t, h.presentation_metrics.invalid_rejections, invalid + 1)
}

@(test)
host_presentation_test_windowed_resident_requires_an_exact_desktop_texture :: proc(t: ^testing.T) {
	h: Host
	if !host_presentation_test_seed_legacy(t, &h) {return}
	present := host_presentation_test_local_resident(&h, 20)
	present.clip_mode = .Windowed
	present.clips = {}
	_ = contract.rect_set_append(&present.clips, {4, 4, 20, 20})
	invalid := h.presentation_metrics.invalid_rejections
	testing.expect(t, !host_presentation_admit_gsw(&h, present).valid)
	testing.expect_value(t, h.presentation_metrics.invalid_rejections, invalid + 1)

	h.tex = transmute(^sdl3.Texture)(uintptr(92))
	h.tex_width = 640
	h.tex_height = 480
	admission := host_presentation_admit_gsw(&h, present)
	testing.expect(t, admission.valid)
	testing.expect_value(t, admission.kind, Host_Presentation_Kind.Gsw_Resident)
}

@(test)
host_presentation_test_rejects_malformed_raw_clips_before_normalization :: proc(t: ^testing.T) {
	h: Host
	if !host_presentation_test_seed_legacy(t, &h) {return}
	present := host_presentation_test_local_resident(&h, 20)
	present.clip_mode = .Windowed
	invalid := h.presentation_metrics.invalid_rejections
	sequence := h.presentation_state.sequence

	present.clips.count = 1
	present.clips.rects[0] = {1, 1, 0, 2}
	testing.expect(t, !host_presentation_admit_gsw(&h, present).valid)

	present.clips = {}
	present.clips.count = 1
	present.clips.rects[0] = {max(u32), 1, 2, 2}
	testing.expect(t, !host_presentation_admit_gsw(&h, present).valid)

	present.clips = {}
	present.clips.count = 1
	present.clips.rects[0] = {640, 1, 1, 1}
	testing.expect(t, !host_presentation_admit_gsw(&h, present).valid)

	present.clips = {}
	present.clips.count = 1
	present.clips.rects[0] = {1, 1, 2, 2}
	present.clips.rects[1] = {4, 4, 2, 2}
	testing.expect(t, !host_presentation_admit_gsw(&h, present).valid)

	testing.expect_value(t, h.presentation_metrics.invalid_rejections, invalid + 4)
	testing.expect_value(t, h.presentation_state.sequence, sequence)
}

@(test)
host_presentation_test_mode_away_and_back_rejects_unselected_gsw_desktop :: proc(t: ^testing.T) {
	h: Host
	if !testing.expect(t, host_presentation_start(&h, 1)) {return}
	snapshot := host_presentation_test_snapshot(10)
	snapshot_admission := host_presentation_admit_gsw(&h, snapshot, 640 * 480 * 4)
	if !testing.expect(t, snapshot_admission.valid) {return}
	host_presentation_test_apply_gsw(&h, snapshot_admission)
	h.presentation_state.gsw_texture = transmute(^sdl3.Texture)(uintptr(93))
	h.presentation_state.gsw_texture_width = 640
	h.presentation_state.gsw_texture_height = 480

	resident := host_presentation_test_local_resident(&h, 20)
	resident.clip_mode = .Windowed
	_ = contract.rect_set_append(&resident.clips, {4, 4, 20, 20})
	testing.expect(t, host_presentation_gsw_desktop_available(&h, resident.header))
	selected_snapshot := h.presentation_state.selector.last_good_gsw
	h.presentation_state.selector.last_good_gsw.header.sequence = contract.generation_next(
		selected_snapshot.header.sequence,
	)
	testing.expect(t, !host_presentation_gsw_desktop_available(&h, resident.header))
	h.presentation_state.selector.last_good_gsw = selected_snapshot

	away_key := host_presentation_test_mode_key(800, 600)
	away := host_presentation_test_legacy(21, 1, away_key)
	away.header.mode_generation = contract.generation_next(snapshot.header.mode_generation)
	away_admission := host_presentation_admit_legacy(&h, away)
	if !testing.expect(t, away_admission.valid) {return}
	host_presentation_test_apply_legacy(&h, away_admission)
	testing.expect(t, !h.presentation_state.selector.has_last_good_gsw)
	testing.expect(t, h.presentation_state.gsw_snapshot.header.sequence != 0)
	testing.expect(t, h.presentation_state.gsw_texture != nil)

	back := host_presentation_test_local_resident(&h, 30)
	back.clip_mode = .Windowed
	_ = contract.rect_set_append(&back.clips, {4, 4, 20, 20})
	testing.expect(t, !host_presentation_gsw_desktop_available(&h, back.header))
	invalid := h.presentation_metrics.invalid_rejections
	testing.expect(t, !host_presentation_admit_gsw(&h, back).valid)
	testing.expect_value(t, h.presentation_metrics.invalid_rejections, invalid + 1)
}

@(test)
host_presentation_test_hidden_gsw_refresh_preserves_resident_and_restores_desktop :: proc(
	t: ^testing.T,
) {
	h: Host
	if !host_presentation_test_seed_legacy(t, &h) {return}
	snapshot := host_presentation_test_snapshot(20)
	snapshot.header.completion = {}
	snapshot_admission := host_presentation_admit_gsw(&h, snapshot, 640 * 480 * 4)
	if !testing.expect(t, snapshot_admission.valid) {return}
	desktop_texture := transmute(^sdl3.Texture)(uintptr(91))
	h.presentation_state.gsw_staging = {
		texture          = desktop_texture,
		width            = 640,
		height           = 480,
		stage_generation = 31,
	}
	desktop_staged := host_presentation_test_staged(&snapshot_admission, desktop_texture, 31)
	if !testing.expect(
		t,
		host_presentation_commit_gsw_snapshot_staged(&h, &snapshot_admission, desktop_staged),
	) {return}

	resident := host_presentation_test_local_resident(&h, 30)
	resident.clip_mode = .Windowed
	resident.clips = {}
	_ = contract.rect_set_append(&resident.clips, {0, 0, 20, 20})
	resident_admission := host_presentation_admit_gsw(&h, resident)
	if !testing.expect(t, resident_admission.valid) {return}
	host_presentation_test_install_surface(&h, resident_admission.gsw)
	if !testing.expect(
		t,
		host_presentation_commit_resident(
			&h,
			&resident_admission,
			host_presentation_test_physical(resident_admission.gsw),
		),
	) {return}
	selected := h.gpu_present
	active := h.presentation_state.selector.active

	update := host_presentation_test_snapshot(21)
	update.header.completion = {}
	update.header.dirty = {}
	_ = contract.rect_set_append(&update.header.dirty, {4, 4, 4, 4})
	refresh := host_presentation_admit_gsw(&h, update, 640 * 480 * 4)
	if !testing.expect(t, refresh.valid) {return}
	testing.expect(t, refresh.background_only)
	testing.expect_value(t, refresh.result.action, contract.Selector_Action.Refresh_Gsw)
	testing.expect_value(t, refresh.overlay_invalidated_regions, u64(1))
	h.presentation_state.texture_stage_generation = 32
	staged := Host_Presentation_Staged_Texture {
		valid                = true,
		kind                 = .Gsw_Snapshot,
		texture              = desktop_texture,
		width                = 640,
		height               = 480,
		stage_generation     = 32,
		lifecycle_generation = refresh.gsw.header.lifecycle_generation,
		admission_sequence   = refresh.gsw.header.sequence,
		in_place             = true,
		mutated              = true,
		resource_generation  = h.presentation_state.gsw_resource_generation,
	}
	if !testing.expect(t, host_presentation_commit_gsw_snapshot_staged(&h, &refresh, staged)) {
		return
	}
	testing.expect_value(t, h.presentation_state.selector.active, active)
	testing.expect_value(t, h.gpu_present, selected)
	testing.expect_value(t, h.presentation_state.gsw.clips.count, u32(4))
	testing.expect_value(t, h.presentation_metrics.overlay_invalidated_regions, u64(1))

	action := host_presentation_apply_invalidation(
		&h,
		host_presentation_test_invalidation(&h, .Gsw3d, .Surface_Destroyed),
	)
	testing.expect_value(t, action, contract.Selector_Action.Restore_Gsw)
	testing.expect_value(
		t,
		h.presentation_state.selector.active.source_kind,
		contract.Source_Kind.Gsw_Snapshot,
	)
	testing.expect_value(t, h.presentation_state.gsw_texture, desktop_texture)
	testing.expect_value(t, h.gpu_present, Host_Gpu_Present{})
}

@(test)
host_presentation_test_legacy_stage_token_rejects_cross_admission_and_dimensions :: proc(
	t: ^testing.T,
) {
	h: Host
	if !host_presentation_test_seed_legacy(t, &h) {return}
	h.tex = transmute(^sdl3.Texture)(uintptr(50))
	h.tex_width = 640
	h.tex_height = 480
	first := host_presentation_admit_legacy(&h, host_presentation_test_legacy(11))
	if !testing.expect(t, first.valid) {return}
	staged_texture := transmute(^sdl3.Texture)(uintptr(51))
	h.presentation_state.legacy_staging = {
		texture          = staged_texture,
		width            = 640,
		height           = 480,
		stage_generation = 20,
	}
	first_token := host_presentation_test_staged(&first, staged_texture, 20)
	second := host_presentation_admit_legacy(&h, host_presentation_test_legacy(12))
	if !testing.expect(t, second.valid) {return}
	full_before := h.presentation_metrics.legacy_full_updates
	testing.expect(t, !host_presentation_commit_legacy_staged(&h, &second, first_token))
	testing.expect_value(t, h.tex, transmute(^sdl3.Texture)(uintptr(50)))
	testing.expect_value(t, h.presentation_metrics.legacy_full_updates, full_before)

	second_token := host_presentation_test_staged(&second, staged_texture, 20, 320, 480)
	h.presentation_state.legacy_staging.width = 320
	testing.expect(t, !host_presentation_commit_legacy_staged(&h, &second, second_token))
	testing.expect_value(t, h.tex, transmute(^sdl3.Texture)(uintptr(50)))
}

@(test)
host_presentation_test_gsw_snapshot_stage_token_rejects_cross_admission :: proc(t: ^testing.T) {
	h: Host
	if !host_presentation_test_seed_legacy(t, &h) {return}
	first := host_presentation_admit_gsw(&h, host_presentation_test_snapshot(20), 640 * 480 * 4)
	if !testing.expect(t, first.valid) {return}
	selected := transmute(^sdl3.Texture)(uintptr(52))
	staged_texture := transmute(^sdl3.Texture)(uintptr(53))
	h.presentation_state.gsw_texture = selected
	h.presentation_state.gsw_texture_width = 640
	h.presentation_state.gsw_texture_height = 480
	h.presentation_state.gsw_staging = {
		texture          = staged_texture,
		width            = 640,
		height           = 480,
		stage_generation = 21,
	}
	first_token := host_presentation_test_staged(&first, staged_texture, 21)
	second := host_presentation_admit_gsw(&h, host_presentation_test_snapshot(21), 640 * 480 * 4)
	if !testing.expect(t, second.valid) {return}
	testing.expect(t, !host_presentation_commit_gsw_snapshot_staged(&h, &second, first_token))
	testing.expect_value(t, h.presentation_state.gsw_texture, selected)
}

@(test)
host_presentation_test_legacy_stage_token_cannot_replay_after_restart :: proc(t: ^testing.T) {
	h: Host
	if !host_presentation_test_seed_legacy(t, &h) {return}
	h.tex = transmute(^sdl3.Texture)(uintptr(54))
	h.tex_width = 640
	h.tex_height = 480
	old := host_presentation_admit_legacy(&h, host_presentation_test_legacy(11))
	if !testing.expect(t, old.valid) {return}
	staged_texture := transmute(^sdl3.Texture)(uintptr(55))
	h.presentation_state.legacy_staging = {
		texture          = staged_texture,
		width            = 640,
		height           = 480,
		stage_generation = 22,
	}
	old_token := host_presentation_test_staged(&old, staged_texture, 22)
	host_presentation_stop(&h)
	if !testing.expect(t, host_presentation_start(&h, 2)) {return}
	current := host_presentation_admit_legacy(&h, host_presentation_test_legacy(1, 2))
	if !testing.expect(t, current.valid) {return}
	testing.expect(t, !host_presentation_commit_legacy_staged(&h, &current, old_token))
	testing.expect_value(t, h.tex, transmute(^sdl3.Texture)(uintptr(54)))
}

@(test)
host_presentation_test_gsw_snapshot_stage_token_cannot_replay_after_restart :: proc(
	t: ^testing.T,
) {
	h: Host
	if !host_presentation_test_seed_legacy(t, &h) {return}
	old := host_presentation_admit_gsw(&h, host_presentation_test_snapshot(20), 640 * 480 * 4)
	if !testing.expect(t, old.valid) {return}
	selected := transmute(^sdl3.Texture)(uintptr(56))
	staged_texture := transmute(^sdl3.Texture)(uintptr(57))
	h.presentation_state.gsw_texture = selected
	h.presentation_state.gsw_texture_width = 640
	h.presentation_state.gsw_texture_height = 480
	h.presentation_state.gsw_staging = {
		texture          = staged_texture,
		width            = 640,
		height           = 480,
		stage_generation = 23,
	}
	old_token := host_presentation_test_staged(&old, staged_texture, 23)
	host_presentation_stop(&h)
	if !testing.expect(t, host_presentation_start(&h, 2)) {return}
	current := host_presentation_admit_gsw(
		&h,
		host_presentation_test_snapshot(1, 2),
		640 * 480 * 4,
	)
	if !testing.expect(t, current.valid) {return}
	testing.expect(t, !host_presentation_commit_gsw_snapshot_staged(&h, &current, old_token))
	testing.expect_value(t, h.presentation_state.gsw_texture, selected)
}

@(test)
host_presentation_test_stage_token_cannot_replay_when_lifecycle_value_is_reused :: proc(
	t: ^testing.T,
) {
	h: Host
	if !testing.expect(t, host_presentation_start(&h, 1)) {return}
	old := host_presentation_admit_legacy(&h, host_presentation_test_legacy(1))
	if !testing.expect(t, old.valid) {return}
	staged_texture := transmute(^sdl3.Texture)(uintptr(58))
	h.presentation_state.legacy_staging = {
		texture          = staged_texture,
		width            = 640,
		height           = 480,
		stage_generation = 24,
	}
	old_token := host_presentation_test_staged(&old, staged_texture, 24)

	host_presentation_stop(&h)
	if !testing.expect(t, host_presentation_start(&h, 1)) {return}
	testing.expect_value(t, h.presentation_state.legacy_staging.texture, staged_texture)
	testing.expect_value(t, h.presentation_state.legacy_staging.stage_generation, u64(0))
	current := host_presentation_admit_legacy(&h, host_presentation_test_legacy(1))
	if !testing.expect(t, current.valid) {return}
	testing.expect(t, !host_presentation_commit_legacy_staged(&h, &current, old_token))
	testing.expect(t, h.tex == nil)
}

@(test)
host_presentation_test_destroy_clears_visible_state_and_is_idempotent :: proc(t: ^testing.T) {
	h: Host
	h.presentation_state.accepting = true
	h.presentation_state.lifecycle = 9
	h.presentation_state.texture_stage_generation = 12
	h.presentation_state.legacy_shadow = new(Host_Presentation_Resource_Shadow)
	h.presentation_state.legacy_shadow.pixels = make([]u32, 4)
	h.presentation_state.gsw_shadow = new(Host_Presentation_Resource_Shadow)
	h.presentation_state.gsw_shadow.pixels = make([]u32, 4)
	h.gpu_present = {
		surface_id    = 23,
		canvas_width  = 640,
		canvas_height = 480,
	}
	h.has_frame = true

	host_presentation_destroy(&h)
	testing.expect_value(t, h.presentation_state, Host_Presentation_State{})
	testing.expect_value(t, h.gpu_present, Host_Gpu_Present{})
	testing.expect(t, !h.has_frame)

	host_presentation_destroy(&h)
	testing.expect_value(t, h.presentation_state, Host_Presentation_State{})
	testing.expect_value(t, h.gpu_present, Host_Gpu_Present{})
	testing.expect(t, !h.has_frame)
}

@(test)
host_presentation_test_invalidation_namespace_and_source_mode_are_exact :: proc(t: ^testing.T) {
	h: Host
	if !host_presentation_test_seed_resident(t, &h) {return}
	selector := h.presentation_state.selector
	committed := h.presentation_state.gsw
	physical := h.gpu_present

	collision := host_presentation_test_invalidation(&h, .Gsw2d, .Surface_Destroyed)
	action := host_presentation_apply_invalidation(&h, collision)
	testing.expect_value(t, action, contract.Selector_Action.Drop_Stale)
	testing.expect_value(t, h.presentation_state.selector, selector)
	testing.expect_value(t, h.presentation_state.gsw, committed)
	testing.expect_value(t, h.gpu_present, physical)
	testing.expect(t, h.has_frame)

	stale_mode := host_presentation_test_invalidation(&h, .Gsw3d, .Device_Reset)
	stale_mode.mode_generation = contract.generation_next(stale_mode.mode_generation)
	action = host_presentation_apply_invalidation(&h, stale_mode)
	testing.expect_value(t, action, contract.Selector_Action.Drop_Stale)
	testing.expect_value(t, h.presentation_state.selector, selector)
	testing.expect_value(t, h.presentation_state.gsw, committed)

	malformed := host_presentation_test_invalidation(&h, .Gsw3d, .Invalid)
	invalid := h.presentation_metrics.invalid_rejections
	action = host_presentation_apply_invalidation(&h, malformed)
	testing.expect_value(t, action, contract.Selector_Action.Reject_Invalid)
	testing.expect_value(t, h.presentation_state.selector, selector)
	testing.expect_value(t, h.presentation_state.gsw, committed)
	testing.expect_value(t, h.gpu_present, physical)
	testing.expect_value(t, h.presentation_metrics.invalid_rejections, invalid + 1)
}

@(test)
host_presentation_test_gsw3d_lifecycle_event_cannot_invalidate_gsw2d :: proc(t: ^testing.T) {
	h: Host
	if !host_presentation_test_seed_legacy(t, &h) {return}
	present := host_presentation_test_snapshot(20)
	admission := host_presentation_admit_gsw(&h, present, 640 * 480 * 4)
	if !testing.expect(t, admission.valid) {return}
	host_presentation_test_apply_gsw(&h, admission)
	selector := h.presentation_state.selector
	committed := h.presentation_state.gsw

	action := host_presentation_invalidate_active(&h, .Gsw3d, .Device_Reset)
	testing.expect_value(t, action, contract.Selector_Action.None)
	testing.expect_value(t, h.presentation_state.selector, selector)
	testing.expect_value(t, h.presentation_state.gsw, committed)
}

@(test)
host_presentation_test_gsw3d_adapter_tags_resident_identity_namespace :: proc(t: ^testing.T) {
	h: Host
	if !host_presentation_test_seed_legacy(t, &h) {return}
	h.gpu_surfaces[0] = {
		live = true,
		generation = 5,
		descriptor = {
			id = GSW3D_PROOF_TARGET_ID,
			width = 640,
			height = 480,
			format = .Bgra8_Unorm,
		},
		render_texture = transmute(^sdl3.Texture)(uintptr(9)),
	}
	present := Gsw3d_Proof_Present {
		surface_id = GSW3D_PROOF_TARGET_ID,
		source = {width = 640, height = 480},
		destination = {width = 640, height = 480},
		interval = 1,
		generation = 7,
		fence = 17,
	}
	testing.expect(t, host_gsw3d_proof_present(&h, &present))
	testing.expect_value(
		t,
		h.presentation_state.gsw.header.identity_namespace,
		contract.Identity_Namespace.Gsw3d,
	)
	testing.expect_value(
		t,
		h.presentation_state.selector.active.identity_namespace,
		contract.Identity_Namespace.Gsw3d,
	)
}
