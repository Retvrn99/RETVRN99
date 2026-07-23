// SPDX-License-Identifier: GPL-3.0-only
package host

import contract "../presentation"
import vga "../vga"
import "core:testing"
import sdl3 "vendor:sdl3"

Host_Presentation_Upload_Failure_Probe :: struct {
	writes:            int,
	successful_writes: int,
	fail_write:        int,
	creates:           int,
	next_texture:      ^sdl3.Texture,
	destroys:          int,
	destroyed:         ^sdl3.Texture,
}

host_presentation_upload_test_create :: proc(ctx: rawptr, width, height: int) -> ^sdl3.Texture {
	probe := (^Host_Presentation_Upload_Failure_Probe)(ctx)
	if probe == nil || width <= 0 || height <= 0 {return nil}
	probe.creates += 1
	return probe.next_texture
}

host_presentation_upload_test_write :: proc(
	ctx: rawptr,
	texture: ^sdl3.Texture,
	shadow: ^Host_Presentation_Resource_Shadow,
	rect: contract.Rect,
) -> bool {
	probe := (^Host_Presentation_Upload_Failure_Probe)(ctx)
	if probe == nil || texture == nil || shadow == nil || !shadow.valid || rect.width == 0 {
		return false
	}
	probe.writes += 1
	if probe.writes == probe.fail_write {return false}
	probe.successful_writes += 1
	return true
}

host_presentation_upload_test_destroy :: proc(ctx: rawptr, texture: ^sdl3.Texture) {
	probe := (^Host_Presentation_Upload_Failure_Probe)(ctx)
	if probe == nil {return}
	probe.destroys += 1
	probe.destroyed = texture
}

host_upload_test_header :: proc() -> contract.Header {
	extent := contract.Extent{4, 2}
	full := contract.Rect {
		width  = extent.width,
		height = extent.height,
	}
	return {
		sequence = 1,
		lifecycle_generation = 1,
		mode_generation = 1,
		mode_key = {
			format = .Bgra_8888,
			surface_extent = extent,
			canvas_extent = extent,
			source = full,
			destination = full,
		},
		surface = {1, 1},
		format = .Bgra_8888,
		surface_extent = extent,
		canvas_extent = extent,
		source = full,
		destination = full,
		dirty = contract.rect_set_full(extent),
		source_kind = .Legacy_Snapshot,
		ownership = .Mailbox_Descriptor,
	}
}

@(test)
host_presentation_upload_plan_accounts_disjoint_regions_exactly :: proc(t: ^testing.T) {
	header := host_upload_test_header()
	header.dirty = {}
	_ = contract.rect_set_append(&header.dirty, {0, 0, 1, 2})
	_ = contract.rect_set_append(&header.dirty, {3, 1, 1, 1})
	pixels := make([]u32, 8)
	defer delete(pixels)
	frame := vga.Display_Frame {
		width          = 4,
		height         = 2,
		pixels         = pixels,
		dirty          = header.dirty,
		updated_pixels = 3,
	}
	plan := host_presentation_upload_plan(&frame, header)
	testing.expect(t, plan.valid)
	testing.expect(t, !plan.full)
	testing.expect_value(t, plan.pixels, u64(3))
	testing.expect_value(t, plan.bytes, u64(12))
	testing.expect_value(t, plan.regions, u64(2))

	header.dirty.rects[contract.MAX_RECTS - 1] = {1, 1, 1, 1}
	testing.expect(t, !host_presentation_upload_plan(&frame, header).valid)
}

@(test)
host_presentation_upload_plan_rejects_mismatched_or_unaccounted_damage :: proc(t: ^testing.T) {
	header := host_upload_test_header()
	pixels := make([]u32, 8)
	defer delete(pixels)
	frame := vga.Display_Frame {
		width  = 4,
		height = 2,
		pixels = pixels,
	}

	testing.expect(t, !host_presentation_upload_plan(&frame, header).valid)
	frame.dirty = header.dirty
	testing.expect(t, !host_presentation_upload_plan(&frame, header).valid)
	frame.updated_pixels = 8
	full := host_presentation_upload_plan(&frame, header)
	testing.expect(t, full.valid)
	testing.expect(t, full.full)
	testing.expect_value(t, full.regions, u64(1))
	testing.expect_value(t, full.bytes, u64(32))

	frame.updated_pixels = 7
	testing.expect(t, !host_presentation_upload_plan(&frame, header).valid)
	frame.updated_pixels = 8
	frame.dirty.rects[0].width = 3
	testing.expect(t, !host_presentation_upload_plan(&frame, header).valid)
}

@(test)
host_presentation_shadow_merges_partial_pixels_and_rejects_stale_identity :: proc(t: ^testing.T) {
	header := host_upload_test_header()
	pixels := make([]u32, 8)
	defer delete(pixels)
	for &pixel, i in pixels {pixel = u32(i + 1)}
	frame := vga.Display_Frame {
		width          = 4,
		height         = 2,
		pixels         = pixels,
		dirty          = header.dirty,
		updated_pixels = 8,
	}
	full_plan := host_presentation_upload_plan(&frame, header)
	shadow: Host_Presentation_Resource_Shadow
	defer if shadow.pixels != nil {delete(shadow.pixels)}
	testing.expect(t, host_presentation_shadow_apply(&shadow, .Legacy, header, &frame, full_plan))

	header.sequence = 2
	header.dirty = {}
	_ = contract.rect_set_append(&header.dirty, {1, 0, 1, 1})
	_ = contract.rect_set_append(&header.dirty, {2, 1, 1, 1})
	frame.dirty = header.dirty
	frame.updated_pixels = 2
	frame.pixels[1] = 100
	frame.pixels[6] = 200
	partial_plan := host_presentation_upload_plan(&frame, header)
	testing.expect(
		t,
		host_presentation_shadow_apply(&shadow, .Legacy, header, &frame, partial_plan),
	)
	testing.expect_value(t, shadow.pixels[0], u32(1))
	testing.expect_value(t, shadow.pixels[1], u32(100))
	testing.expect_value(t, shadow.pixels[6], u32(200))
	testing.expect_value(t, shadow.pixels[7], u32(8))

	header.mode_generation = 2
	testing.expect(
		t,
		!host_presentation_shadow_apply(&shadow, .Legacy, header, &frame, partial_plan),
	)
}

@(test)
host_presentation_in_place_upload_failure_is_transactional :: proc(t: ^testing.T) {
	h: Host
	key := host_presentation_test_mode_key(4, 2)
	if !testing.expect(t, host_presentation_start(&h, 1)) {return}
	initial := host_presentation_test_legacy(1, 1, key)
	initial_admission := host_presentation_admit_legacy(&h, initial)
	if !testing.expect(t, initial_admission.valid) {return}
	host_presentation_test_apply_legacy(&h, initial_admission)

	texture := transmute(^sdl3.Texture)(uintptr(97))
	h.tex = texture
	h.tex_width = 4
	h.tex_height = 2
	h.presentation_state.legacy_resource_generation = 4
	h.presentation_state.legacy_shadow = new(Host_Presentation_Resource_Shadow)
	defer {
		shadow := h.presentation_state.legacy_shadow
		if shadow != nil {
			if shadow.pixels != nil {delete(shadow.pixels)}
			free(shadow)
			h.presentation_state.legacy_shadow = nil
		}
	}

	old_pixels := make([]u32, 8)
	defer delete(old_pixels)
	for &pixel, i in old_pixels {pixel = u32(i + 1)}
	old_frame := vga.Display_Frame {
		width          = 4,
		height         = 2,
		pixels         = old_pixels,
		dirty          = initial.header.dirty,
		updated_pixels = 8,
	}
	old_plan := host_presentation_upload_plan(&old_frame, initial.header)
	if !testing.expect(
		t,
		host_presentation_shadow_apply(
			h.presentation_state.legacy_shadow,
			.Legacy,
			initial_admission.legacy.header,
			&old_frame,
			old_plan,
		),
	) {return}

	update := host_presentation_test_legacy(2, 1, key)
	update.header.dirty = {}
	_ = contract.rect_set_append(&update.header.dirty, {0, 0, 1, 1})
	_ = contract.rect_set_append(&update.header.dirty, {3, 1, 1, 1})
	admission := host_presentation_admit_legacy(&h, update)
	if !testing.expect(t, admission.valid) {return}
	new_pixels := make([]u32, 8)
	defer delete(new_pixels)
	for &pixel, i in new_pixels {pixel = u32(100 + i)}
	frame := vga.Display_Frame {
		width          = 4,
		height         = 2,
		pixels         = new_pixels,
		dirty          = update.header.dirty,
		updated_pixels = 2,
	}
	probe := Host_Presentation_Upload_Failure_Probe {
		fail_write = 2,
	}
	ops := Host_Presentation_Upload_Ops {
		ctx             = &probe,
		create_texture  = host_presentation_upload_test_create,
		write_rect      = host_presentation_upload_test_write,
		destroy_texture = host_presentation_upload_test_destroy,
	}
	selected_sequence := h.presentation_state.sequence
	selected_legacy := h.presentation_state.legacy
	selected_selector := h.presentation_state.selector

	staged := host_presentation_stage_texture(
		&h,
		&h.presentation_state.legacy_staging,
		&frame,
		&admission,
		&ops,
	)
	testing.expect(t, !staged.valid)
	testing.expect(t, staged.in_place)
	testing.expect(t, staged.mutated)
	testing.expect_value(t, staged.upload_bytes, u64(4))
	testing.expect_value(t, staged.upload_regions, u64(1))
	testing.expect_value(t, probe.writes, 2)
	testing.expect_value(t, probe.successful_writes, 1)
	testing.expect_value(t, h.presentation_metrics.upload_bytes, u64(4))
	testing.expect_value(t, h.presentation_metrics.upload_regions, u64(1))
	testing.expect_value(t, h.presentation_state.legacy_shadow.pixels[0], u32(1))
	testing.expect_value(t, h.presentation_state.legacy_shadow.pixels[7], u32(8))

	testing.expect(t, !host_presentation_commit_legacy_staged(&h, &admission, staged))
	testing.expect_value(t, h.presentation_state.sequence, selected_sequence)
	testing.expect_value(t, h.presentation_state.legacy, selected_legacy)
	testing.expect_value(t, h.presentation_state.selector, selected_selector)
	testing.expect_value(t, h.tex, texture)
	testing.expect(t, h.has_frame)

	testing.expect(t, host_presentation_retire_mutated(&h, staged, &ops))
	testing.expect_value(t, probe.destroys, 1)
	testing.expect_value(t, probe.destroyed, texture)
	testing.expect(t, h.tex == nil)
	testing.expect(t, !h.has_frame)
	testing.expect(t, h.presentation_state.legacy_shadow.valid)
	testing.expect(
		t,
		host_presentation_shadow_matches(
			h.presentation_state.legacy_shadow,
			.Legacy,
			admission.legacy.header,
		),
	)
	testing.expect_value(t, h.presentation_metrics.resource_retirements, u64(1))
	testing.expect(t, !host_presentation_commit_legacy_staged(&h, &admission, staged))
	testing.expect_value(t, h.presentation_state.sequence, selected_sequence)

	probe.next_texture = transmute(^sdl3.Texture)(uintptr(98))
	probe.fail_write = 3
	failed_recreation := host_presentation_stage_texture(
		&h,
		&h.presentation_state.legacy_staging,
		&frame,
		&admission,
		&ops,
	)
	testing.expect(t, !failed_recreation.valid)
	testing.expect_value(t, probe.creates, 1)
	testing.expect_value(t, probe.writes, 3)
	testing.expect(t, h.presentation_state.legacy_shadow.valid)
	testing.expect_value(t, h.presentation_state.legacy_shadow.pixels[0], u32(100))
	testing.expect_value(t, h.presentation_state.legacy_shadow.pixels[7], u32(107))

	probe.next_texture = transmute(^sdl3.Texture)(uintptr(99))
	probe.fail_write = 0
	recovered := host_presentation_stage_texture(
		&h,
		&h.presentation_state.legacy_staging,
		&frame,
		&admission,
		&ops,
	)
	testing.expect(t, recovered.valid)
	testing.expect(t, recovered.texture_recreated)
	testing.expect_value(t, recovered.texture, probe.next_texture)
	testing.expect_value(t, recovered.upload_bytes, u64(32))
	testing.expect_value(t, recovered.upload_regions, u64(1))
	testing.expect_value(t, probe.creates, 2)
	testing.expect_value(t, probe.destroys, 2)
	testing.expect_value(t, probe.destroyed, transmute(^sdl3.Texture)(uintptr(98)))
}

@(test)
host_presentation_stale_in_place_upload_retains_reconstruction_shadow :: proc(t: ^testing.T) {
	h: Host
	key := host_presentation_test_mode_key(4, 2)
	if !testing.expect(t, host_presentation_start(&h, 1)) {return}
	initial := host_presentation_test_legacy(1, 1, key)
	initial_admission := host_presentation_admit_legacy(&h, initial)
	if !testing.expect(t, initial_admission.valid) {return}
	host_presentation_test_apply_legacy(&h, initial_admission)

	h.tex = transmute(^sdl3.Texture)(uintptr(100))
	h.tex_width = 4
	h.tex_height = 2
	h.presentation_state.legacy_resource_generation = 4
	h.presentation_state.legacy_shadow = new(Host_Presentation_Resource_Shadow)
	defer {
		shadow := h.presentation_state.legacy_shadow
		if shadow != nil {
			if shadow.pixels != nil {delete(shadow.pixels)}
			free(shadow)
			h.presentation_state.legacy_shadow = nil
		}
	}

	pixels := make([]u32, 8)
	defer delete(pixels)
	for &pixel, i in pixels {pixel = u32(i + 1)}
	initial_frame := vga.Display_Frame {
		width          = 4,
		height         = 2,
		pixels         = pixels,
		dirty          = initial.header.dirty,
		updated_pixels = 8,
	}
	initial_plan := host_presentation_upload_plan(&initial_frame, initial.header)
	if !testing.expect(
		t,
		host_presentation_shadow_apply(
			h.presentation_state.legacy_shadow,
			.Legacy,
			initial_admission.legacy.header,
			&initial_frame,
			initial_plan,
		),
	) {return}

	update := host_presentation_test_legacy(2, 1, key)
	update.header.dirty = {}
	_ = contract.rect_set_append(&update.header.dirty, {2, 0, 1, 1})
	admission := host_presentation_admit_legacy(&h, update)
	if !testing.expect(t, admission.valid) {return}
	pixels[2] = 55
	frame := vga.Display_Frame {
		width          = 4,
		height         = 2,
		pixels         = pixels,
		dirty          = update.header.dirty,
		updated_pixels = 1,
	}
	probe := Host_Presentation_Upload_Failure_Probe {
		next_texture = transmute(^sdl3.Texture)(uintptr(101)),
	}
	ops := Host_Presentation_Upload_Ops {
		ctx             = &probe,
		create_texture  = host_presentation_upload_test_create,
		write_rect      = host_presentation_upload_test_write,
		destroy_texture = host_presentation_upload_test_destroy,
	}
	staged := host_presentation_stage_texture(
		&h,
		&h.presentation_state.legacy_staging,
		&frame,
		&admission,
		&ops,
	)
	if !testing.expect(t, staged.valid) {return}
	if !testing.expect(t, host_presentation_retire_mutated(&h, staged, &ops)) {return}
	testing.expect(t, h.presentation_state.legacy_shadow.valid)
	testing.expect_value(t, h.presentation_state.legacy_shadow.pixels[2], u32(55))

	recovered := host_presentation_stage_texture(
		&h,
		&h.presentation_state.legacy_staging,
		&frame,
		&admission,
		&ops,
	)
	testing.expect(t, recovered.valid)
	testing.expect(t, recovered.texture_recreated)
	testing.expect_value(t, recovered.texture, probe.next_texture)
	testing.expect_value(t, recovered.upload_bytes, u64(32))
	testing.expect_value(t, recovered.upload_regions, u64(1))
}

@(test)
host_presentation_windowed_resident_hides_when_its_last_desktop_is_retired :: proc(t: ^testing.T) {
	h: Host
	if !host_presentation_test_seed_legacy(t, &h) {return}
	texture := transmute(^sdl3.Texture)(uintptr(98))
	h.tex = texture
	h.tex_width = 640
	h.tex_height = 480
	h.presentation_state.legacy_resource_generation = 6
	present := host_presentation_test_local_resident(&h, 20)
	present.clip_mode = .Windowed
	present.clips = {}
	_ = contract.rect_set_append(&present.clips, {1, 1, 8, 8})
	admission := host_presentation_admit_gsw(&h, present)
	if !testing.expect(t, admission.valid) {return}
	host_presentation_test_apply_gsw(&h, admission)
	probe: Host_Presentation_Upload_Failure_Probe
	ops := Host_Presentation_Upload_Ops {
		ctx             = &probe,
		write_rect      = host_presentation_upload_test_write,
		destroy_texture = host_presentation_upload_test_destroy,
	}
	staged := Host_Presentation_Staged_Texture {
		kind                = .Legacy,
		texture             = texture,
		in_place            = true,
		mutated             = true,
		resource_generation = 6,
	}
	testing.expect(t, host_presentation_retire_mutated(&h, staged, &ops))
	testing.expect(t, !h.has_frame)
	testing.expect_value(t, probe.destroyed, texture)
}
