// SPDX-License-Identifier: GPL-3.0-only
package host

import contract "../presentation"
import vga "../vga"
import "core:hash"
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
			display_aspect = {2, 1},
			surface_extent = extent,
			canvas_extent = extent,
			source = full,
			destination = full,
		},
		surface = {1, 1},
		format = .Bgra_8888,
		display_aspect = {2, 1},
		surface_extent = extent,
		canvas_extent = extent,
		source = full,
		destination = full,
		dirty = contract.rect_set_full(extent),
		source_kind = .Legacy_Snapshot,
		ownership = .Mailbox_Descriptor,
	}
}

host_upload_test_capture_plan :: proc(
	header: contract.Header,
	coverage: vga.Scanout_Capture_Coverage,
) -> vga.Scanout_Capture_Plan {
	return {
		coverage           = coverage,
		required_ranges    = {count = 1, ranges = {0 = {0, 1}}},
		owner              = .Legacy,
		owner_generation   = header.lifecycle_generation,
		mode_generation    = header.mode_generation,
		surface_id         = header.surface.id,
		surface_generation = header.surface.generation,
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
host_presentation_capture_plan_coverage_is_authoritative :: proc(t: ^testing.T) {
	header := host_upload_test_header()
	pixels := make([]u32, 8)
	defer delete(pixels)
	frame := vga.Display_Frame {
		width          = 4,
		height         = 2,
		pixels         = pixels,
		dirty          = header.dirty,
		updated_pixels = 8,
	}
	capture := host_upload_test_capture_plan(header, .Full)
	full := host_presentation_upload_plan_from_capture(&frame, header, &capture)
	testing.expect(t, full.valid)
	testing.expect(t, full.full)
	testing.expect_value(t, full.rects, contract.rect_set_full(header.surface_extent))
	testing.expect_value(t, full.pixels, u64(8))

	capture.coverage = .Partial
	testing.expect(t, !host_presentation_upload_plan_from_capture(&frame, header, &capture).valid)

	header.dirty = {}
	_ = contract.rect_set_append(&header.dirty, {1, 0, 1, 1})
	frame.dirty = header.dirty
	frame.updated_pixels = 1
	capture = host_upload_test_capture_plan(header, .Partial)
	partial := host_presentation_upload_plan_from_capture(&frame, header, &capture)
	testing.expect(t, partial.valid)
	testing.expect(t, !partial.full)
	testing.expect_value(t, partial.rects, header.dirty)
	testing.expect_value(t, partial.pixels, u64(1))

	capture.coverage = .Full
	testing.expect(t, !host_presentation_upload_plan_from_capture(&frame, header, &capture).valid)
}

@(test)
host_presentation_capture_plan_rejects_identity_and_rectangle_mismatch :: proc(t: ^testing.T) {
	header := host_upload_test_header()
	pixels := make([]u32, 8)
	defer delete(pixels)
	header.dirty = {}
	_ = contract.rect_set_append(&header.dirty, {1, 0, 1, 1})
	frame := vga.Display_Frame {
		width          = 4,
		height         = 2,
		pixels         = pixels,
		dirty          = header.dirty,
		updated_pixels = 1,
	}
	capture := host_upload_test_capture_plan(header, .Partial)

	wrong_identity := capture
	wrong_identity.owner_generation += 1
	testing.expect(
		t,
		!host_presentation_upload_plan_from_capture(&frame, header, &wrong_identity).valid,
	)

	frame.dirty.rects[0] = {2, 0, 1, 1}
	testing.expect(t, !host_presentation_upload_plan_from_capture(&frame, header, &capture).valid)
	frame.dirty = header.dirty
	header.dirty.rects[0] = {4, 0, 1, 1}
	testing.expect(t, !host_presentation_upload_plan_from_capture(&frame, header, &capture).valid)
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

host_upload_test_fill_desktop_sentinel_17_33_64_48 :: proc(pixels: []u32, pitch: int) {
	if pitch < 81 || len(pixels) < pitch * 81 {return}
	for y in 0 ..< 48 {
		for x in 0 ..< 64 {
			red := u32((x * 17 + y * 3) & 0xFF)
			green := u32((x * 5 + y * 11) & 0xFF)
			blue := u32((x * 13 + y * 7) & 0xFF)
			pixels[(33 + y) * pitch + 17 + x] = 0xFF00_0000 | red << 16 | green << 8 | blue
		}
	}
	pixels[80 * pitch + 80] = 0xDDBF_84D3
}

host_upload_test_roi_crc32 :: proc(
	pixels: []u32,
	pitch: int,
	rect: contract.Rect,
) -> u32 {
	if pitch <= 0 ||
	   rect.width == 0 ||
	   rect.height == 0 ||
	   int(rect.x + rect.width) > pitch ||
	   int(rect.y + rect.height) > len(pixels) / pitch {return 0}
	bytes := make([]u8, int(rect.width) * int(rect.height) * size_of(u32))
	defer delete(bytes)
	offset := 0
	for y in int(rect.y) ..< int(rect.y + rect.height) {
		for x in int(rect.x) ..< int(rect.x + rect.width) {
			pixel := pixels[y * pitch + x]
			bytes[offset + 0] = u8(pixel)
			bytes[offset + 1] = u8(pixel >> 8)
			bytes[offset + 2] = u8(pixel >> 16)
			bytes[offset + 3] = u8(pixel >> 24)
			offset += 4
		}
	}
	return hash.crc32(bytes)
}

@(test)
host_presentation_legacy_capture_uses_source_generation_after_host_translation :: proc(
	t: ^testing.T,
) {
	h: Host
	if !testing.expect(t, host_presentation_start(&h, 1)) {return}
	defer {
		shadow := h.presentation_state.legacy_shadow
		if shadow != nil {
			if shadow.pixels != nil {delete(shadow.pixels)}
			free(shadow)
			h.presentation_state.legacy_shadow = nil
		}
	}
	key := host_presentation_test_mode_key(4, 2)
	initial := host_presentation_test_legacy(1, 1, key)
	initial.header.mode_generation = 7
	initial_admission := host_presentation_admit_legacy(&h, initial)
	if !testing.expect(t, initial_admission.valid) {return}
	testing.expect_value(t, initial_admission.source_mode_generation, u64(7))
	testing.expect(t, initial_admission.legacy.header.mode_generation != u64(7))

	pixels := make([]u32, 8)
	defer delete(pixels)
	for &pixel, index in pixels {pixel = u32(index + 1)}
	frame := vga.Display_Frame {
		width          = 4,
		height         = 2,
		pixels         = pixels,
		dirty          = initial.header.dirty,
		updated_pixels = 8,
	}
	probe := Host_Presentation_Upload_Failure_Probe {
		next_texture = transmute(^sdl3.Texture)(uintptr(120)),
	}
	ops := Host_Presentation_Upload_Ops {
		ctx             = &probe,
		create_texture  = host_presentation_upload_test_create,
		write_rect      = host_presentation_upload_test_write,
		destroy_texture = host_presentation_upload_test_destroy,
	}
	initial_capture := host_upload_test_capture_plan(initial.header, .Full)
	staged := host_presentation_stage_texture(
		&h,
		&h.presentation_state.legacy_staging,
		&frame,
		&initial_admission,
		&ops,
		&initial_capture,
	)
	if !testing.expect(t, staged.valid) {return}
	if !testing.expect(
		t,
		host_presentation_commit_legacy_staged(&h, &initial_admission, staged),
	) {return}
	testing.expect_value(t, h.presentation_state.legacy_source_mode_generation, u64(7))
	testing.expect_value(t, h.presentation_state.legacy_shadow.mode_generation, u64(7))

	partial := host_presentation_test_legacy(2, 1, key)
	partial.header.mode_generation = 7
	partial.header.dirty = {}
	_ = contract.rect_set_append(&partial.header.dirty, {1, 0, 1, 1})
	partial_admission := host_presentation_admit_legacy(&h, partial)
	if !testing.expect(t, partial_admission.valid) {return}
	testing.expect_value(t, partial_admission.source_mode_generation, u64(7))
	testing.expect(t, partial_admission.legacy.header.mode_generation != u64(7))
	pixels[1] = 100
	frame.dirty = partial.header.dirty
	frame.updated_pixels = 1
	partial_capture := host_upload_test_capture_plan(partial.header, .Partial)
	staged = host_presentation_stage_texture(
		&h,
		&h.presentation_state.legacy_staging,
		&frame,
		&partial_admission,
		&ops,
		&partial_capture,
	)
	testing.expect(t, staged.valid)
	testing.expect_value(t, staged.status, Host_Presentation_Stage_Status.Ready)
	testing.expect(t, staged.in_place)
	testing.expect_value(t, staged.upload_bytes, u64(4))
	testing.expect_value(t, h.presentation_state.legacy_shadow.pixels[1], u32(100))
}

@(test)
host_presentation_partial_without_shadow_requests_full_baseline :: proc(t: ^testing.T) {
	h: Host
	key := host_presentation_test_mode_key(4, 2)
	if !testing.expect(t, host_presentation_start(&h, 1)) {return}
	initial := host_presentation_test_legacy(1, 1, key)
	initial_admission := host_presentation_admit_legacy(&h, initial)
	if !testing.expect(t, initial_admission.valid) {return}
	host_presentation_test_apply_legacy(&h, initial_admission)
	defer {
		shadow := h.presentation_state.legacy_shadow
		if shadow != nil {
			if shadow.pixels != nil {delete(shadow.pixels)}
			free(shadow)
			h.presentation_state.legacy_shadow = nil
		}
	}

	partial := host_presentation_test_legacy(2, 1, key)
	partial.header.dirty = {}
	_ = contract.rect_set_append(&partial.header.dirty, {1, 0, 1, 1})
	partial_admission := host_presentation_admit_legacy(&h, partial)
	if !testing.expect(t, partial_admission.valid) {return}
	pixels := make([]u32, 8)
	defer delete(pixels)
	partial_frame := vga.Display_Frame {
		width          = 4,
		height         = 2,
		pixels         = pixels,
		dirty          = partial.header.dirty,
		updated_pixels = 1,
	}
	probe := Host_Presentation_Upload_Failure_Probe {
		next_texture = transmute(^sdl3.Texture)(uintptr(96)),
	}
	ops := Host_Presentation_Upload_Ops {
		ctx             = &probe,
		create_texture  = host_presentation_upload_test_create,
		write_rect      = host_presentation_upload_test_write,
		destroy_texture = host_presentation_upload_test_destroy,
	}
	stage_generation := h.presentation_state.texture_stage_generation
	partial_capture := host_upload_test_capture_plan(partial.header, .Partial)
	staged := host_presentation_stage_texture(
		&h,
		&h.presentation_state.legacy_staging,
		&partial_frame,
		&partial_admission,
		&ops,
		&partial_capture,
	)
	testing.expect(t, !staged.valid)
	testing.expect_value(t, staged.status, Host_Presentation_Stage_Status.Needs_Full_Baseline)
	testing.expect_value(t, staged.kind, Host_Presentation_Kind.Legacy)
	testing.expect_value(t, staged.lifecycle_generation, partial.header.lifecycle_generation)
	testing.expect_value(t, staged.admission_sequence, partial.header.sequence)
	testing.expect_value(t, h.presentation_state.texture_stage_generation, stage_generation)
	testing.expect_value(t, probe.creates, 0)
	testing.expect_value(t, probe.writes, 0)

	full := host_presentation_test_legacy(2, 1, key)
	full_admission := host_presentation_admit_legacy(&h, full)
	if !testing.expect(t, full_admission.valid) {return}
	full_frame := partial_frame
	full_frame.dirty = full.header.dirty
	full_frame.updated_pixels = 8
	full_capture := host_upload_test_capture_plan(full.header, .Full)
	recovered := host_presentation_stage_texture(
		&h,
		&h.presentation_state.legacy_staging,
		&full_frame,
		&full_admission,
		&ops,
		&full_capture,
	)
	testing.expect(t, recovered.valid)
	testing.expect_value(t, recovered.status, Host_Presentation_Stage_Status.Ready)
	testing.expect(t, h.presentation_state.legacy_shadow.valid)
	testing.expect(
		t,
		host_presentation_shadow_matches(
			h.presentation_state.legacy_shadow,
			.Legacy,
			full.header,
		),
	)
}

@(test)
host_presentation_restores_800x600_sentinel_roi_17_33_64_48_after_320x240_partial :: proc(
	t: ^testing.T,
) {
	h: Host
	if !testing.expect(t, host_presentation_start(&h, 1)) {return}
	defer {
		shadow := h.presentation_state.legacy_shadow
		if shadow != nil {
			if shadow.pixels != nil {delete(shadow.pixels)}
			free(shadow)
			h.presentation_state.legacy_shadow = nil
		}
	}
	probe := Host_Presentation_Upload_Failure_Probe {
		next_texture = transmute(^sdl3.Texture)(uintptr(110)),
	}
	ops := Host_Presentation_Upload_Ops {
		ctx             = &probe,
		create_texture  = host_presentation_upload_test_create,
		write_rect      = host_presentation_upload_test_write,
		destroy_texture = host_presentation_upload_test_destroy,
	}

	desktop_pixels := make([]u32, 800 * 600)
	defer delete(desktop_pixels)
	for &pixel, index in desktop_pixels {
		pixel = 0xFF00_0000 | u32(index)
	}
	host_upload_test_fill_desktop_sentinel_17_33_64_48(desktop_pixels, 800)
	sentinel := contract.Rect{17, 33, 64, 48}
	testing.expect_value(
		t,
		host_upload_test_roi_crc32(desktop_pixels, 800, sentinel),
		u32(0xF0D0_99D4),
	)

	desktop := host_presentation_test_legacy(
		1,
		1,
		host_presentation_test_mode_key(800, 600),
	)
	desktop_admission := host_presentation_admit_legacy(&h, desktop)
	if !testing.expect(t, desktop_admission.valid) {return}
	desktop_frame := vga.Display_Frame {
		width          = 800,
		height         = 600,
		pixels         = desktop_pixels,
		dirty          = desktop.header.dirty,
		updated_pixels = 800 * 600,
	}
	desktop_capture := host_upload_test_capture_plan(desktop.header, .Full)
	desktop_stage := host_presentation_stage_texture(
		&h,
		&h.presentation_state.legacy_staging,
		&desktop_frame,
		&desktop_admission,
		&ops,
		&desktop_capture,
	)
	if !testing.expect(t, desktop_stage.valid) {return}
	if !testing.expect(
		t,
		host_presentation_commit_legacy_staged(&h, &desktop_admission, desktop_stage),
	) {return}

	mode_x := host_presentation_test_legacy(
		2,
		1,
		host_presentation_test_mode_key(320, 240),
	)
	mode_x.header.mode_generation = 2
	mode_x.header.surface.generation = 2
	mode_x_admission := host_presentation_admit_legacy(&h, mode_x)
	if !testing.expect(t, mode_x_admission.valid) {return}
	mode_x_pixels := make([]u32, 320 * 240)
	defer delete(mode_x_pixels)
	for &pixel in mode_x_pixels {pixel = 0xFF44_5566}
	mode_x_frame := vga.Display_Frame {
		width          = 320,
		height         = 240,
		pixels         = mode_x_pixels,
		dirty          = mode_x.header.dirty,
		updated_pixels = 320 * 240,
	}
	probe.next_texture = transmute(^sdl3.Texture)(uintptr(111))
	mode_x_capture := host_upload_test_capture_plan(mode_x.header, .Full)
	mode_x_stage := host_presentation_stage_texture(
		&h,
		&h.presentation_state.legacy_staging,
		&mode_x_frame,
		&mode_x_admission,
		&ops,
		&mode_x_capture,
	)
	if !testing.expect(t, mode_x_stage.valid) {return}
	if !testing.expect(
		t,
		host_presentation_commit_legacy_staged(&h, &mode_x_admission, mode_x_stage),
	) {return}

	partial := host_presentation_test_legacy(
		3,
		1,
		host_presentation_test_mode_key(800, 600),
	)
	partial.header.mode_generation = 3
	partial.header.surface.generation = 3
	partial.header.dirty = {}
	_ = contract.rect_set_append(&partial.header.dirty, {17, 33, 1, 1})
	partial_admission := host_presentation_admit_legacy(&h, partial)
	if !testing.expect(t, partial_admission.valid) {return}
	partial_frame := desktop_frame
	partial_frame.dirty = partial.header.dirty
	partial_frame.updated_pixels = 1
	stage_generation := h.presentation_state.texture_stage_generation
	creates := probe.creates
	writes := probe.writes
	partial_capture := host_upload_test_capture_plan(partial.header, .Partial)
	partial_stage := host_presentation_stage_texture(
		&h,
		&h.presentation_state.legacy_staging,
		&partial_frame,
		&partial_admission,
		&ops,
		&partial_capture,
	)
	testing.expect(t, !partial_stage.valid)
	testing.expect_value(
		t,
		partial_stage.status,
		Host_Presentation_Stage_Status.Needs_Full_Baseline,
	)
	testing.expect_value(t, h.presentation_state.texture_stage_generation, stage_generation)
	testing.expect_value(t, probe.creates, creates)
	testing.expect_value(t, probe.writes, writes)

	recovery := host_presentation_test_legacy(
		4,
		1,
		host_presentation_test_mode_key(800, 600),
	)
	recovery.header.mode_generation = 3
	recovery.header.surface.generation = 3
	recovery_admission := host_presentation_admit_legacy(&h, recovery)
	if !testing.expect(t, recovery_admission.valid) {return}
	recovery_frame := desktop_frame
	recovery_frame.dirty = recovery.header.dirty
	recovery_frame.updated_pixels = 800 * 600
	probe.next_texture = transmute(^sdl3.Texture)(uintptr(112))
	recovery_capture := host_upload_test_capture_plan(recovery.header, .Full)
	recovered := host_presentation_stage_texture(
		&h,
		&h.presentation_state.legacy_staging,
		&recovery_frame,
		&recovery_admission,
		&ops,
		&recovery_capture,
	)
	if !testing.expect(t, recovered.valid) {return}
	testing.expect_value(t, recovered.status, Host_Presentation_Stage_Status.Ready)
	testing.expect_value(t, recovered.upload_bytes, u64(1_920_000))
	testing.expect_value(t, recovered.upload_regions, u64(1))
	if !testing.expect(
		t,
		host_presentation_commit_legacy_staged(&h, &recovery_admission, recovered),
	) {return}

	shadow := h.presentation_state.legacy_shadow
	if !testing.expect(t, shadow != nil && shadow.valid) {return}
	testing.expect_value(t, shadow.width, 800)
	testing.expect_value(t, shadow.height, 600)
	exact := len(shadow.pixels) == len(desktop_pixels)
	if exact {
		for pixel, index in shadow.pixels {
			if pixel != desktop_pixels[index] {
				exact = false
				break
			}
		}
	}
	testing.expect(t, exact)
	testing.expect_value(
		t,
		host_upload_test_roi_crc32(shadow.pixels, shadow.width, sentinel),
		u32(0xF0D0_99D4),
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
	capture_plan := host_upload_test_capture_plan(update.header, .Partial)

	staged := host_presentation_stage_texture(
		&h,
		&h.presentation_state.legacy_staging,
		&frame,
		&admission,
		&ops,
		&capture_plan,
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
		&capture_plan,
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
		&capture_plan,
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
	capture_plan := host_upload_test_capture_plan(update.header, .Partial)
	staged := host_presentation_stage_texture(
		&h,
		&h.presentation_state.legacy_staging,
		&frame,
		&admission,
		&ops,
		&capture_plan,
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
		&capture_plan,
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
