// SPDX-License-Identifier: GPL-3.0-only
package videopresentation

import host "../host"
import machine "../machine"
import presentation "../presentation"
import vga "../vga"
import "core:hash"
import "core:testing"
import "core:time"
import sdl3 "vendor:sdl3"

Graphics_Frame_Consumer_Test_Stage_Probe :: struct {
	mailbox:         ^Frame_Mailbox,
	order:           [4]host.Host_Presentation_Kind,
	order_count:     int,
	next_texture:    uintptr,
	fail_kind:       host.Host_Presentation_Kind,
	needs_full_kind: host.Host_Presentation_Kind,
	reset_on_legacy: bool,
	pixels:          [1]u32,
	legacy_frame:    vga.Display_Frame,
	gsw_frame:       vga.Display_Frame,
}

graphics_frame_consumer_test_expand_legacy :: proc(
	ctx: rawptr,
	descriptor: ^vga.Scanout_Descriptor,
) -> ^vga.Display_Frame {
	probe := (^Graphics_Frame_Consumer_Test_Stage_Probe)(ctx)
	if probe == nil || descriptor == nil {return nil}
	probe.pixels[0] = 0xFF112233
	probe.legacy_frame = {
		kind           = .Xrgb_8888,
		width          = 1,
		height         = 1,
		pixels         = probe.pixels[:],
		dirty          = descriptor.legacy_update.header.dirty,
		updated_pixels = 1,
	}
	return &probe.legacy_frame
}

graphics_frame_consumer_test_expand_gsw :: proc(
	ctx: rawptr,
	descriptor: ^vga.Scanout_Descriptor,
) -> ^vga.Display_Frame {
	probe := (^Graphics_Frame_Consumer_Test_Stage_Probe)(ctx)
	if probe == nil || descriptor == nil {return nil}
	probe.pixels[0] = 0xFF665544
	probe.gsw_frame = {
		kind           = .Xrgb_8888,
		width          = 1,
		height         = 1,
		pixels         = probe.pixels[:],
		dirty          = descriptor.gsw_presentation.present.header.dirty,
		updated_pixels = 1,
	}
	return &probe.gsw_frame
}

graphics_frame_consumer_test_stage :: proc(
	ctx: rawptr,
	target: ^host.Host,
	admission: ^host.Host_Presentation_Admission,
	frame: ^vga.Display_Frame,
	capture_plan: ^vga.Scanout_Capture_Plan,
) -> host.Host_Presentation_Staged_Texture {
	probe := (^Graphics_Frame_Consumer_Test_Stage_Probe)(ctx)
	if probe == nil || target == nil || admission == nil || frame == nil {return {}}
	if probe.order_count < len(probe.order) {
		probe.order[probe.order_count] = admission.kind
		probe.order_count += 1
	}
	if admission.kind == .Legacy && probe.reset_on_legacy {
		frame_mailbox_reset(probe.mailbox)
		return {}
	}
	if admission.kind == probe.needs_full_kind {
		header := admission.kind == .Legacy ? admission.legacy.header : admission.gsw.header
		return {
			status               = .Needs_Full_Baseline,
			kind                 = admission.kind,
			lifecycle_generation = header.lifecycle_generation,
			admission_sequence   = header.sequence,
		}
	}
	if admission.kind == probe.fail_kind {return {}}
	probe.next_texture += 1
	texture := transmute(^sdl3.Texture)(probe.next_texture)
	header := admission.kind == .Legacy ? admission.legacy.header : admission.gsw.header
	stage_generation := presentation.generation_next(
		target.presentation_state.texture_stage_generation,
	)
	target.presentation_state.texture_stage_generation = stage_generation
	slot := &target.presentation_state.legacy_staging
	if admission.kind != .Legacy {slot = &target.presentation_state.gsw_staging}
	slot^ = {
		texture          = texture,
		width            = int(header.surface_extent.width),
		height           = int(header.surface_extent.height),
		stage_generation = stage_generation,
	}
	return {
		valid = true,
		kind = admission.kind,
		texture = texture,
		width = slot.width,
		height = slot.height,
		stage_generation = stage_generation,
		lifecycle_generation = header.lifecycle_generation,
		admission_sequence = header.sequence,
	}
}

graphics_frame_consumer_test_legacy_update :: proc(
	sequence, lifecycle: u64,
	extent: presentation.Extent = {1, 1},
	surface_generation: u64 = 1,
) -> presentation.Legacy_Frame_Update {
	full := presentation.Rect {
		width  = extent.width,
		height = extent.height,
	}
	return {
		damage_kind = .Pixel_Memory,
		header = {
			sequence = sequence,
			lifecycle_generation = lifecycle,
			mode_generation = 1,
			mode_key = {
				format = .Bgra_8888,
				display_aspect = presentation.aspect_ratio_make(extent.width, extent.height),
				surface_extent = extent,
				canvas_extent = extent,
				source = full,
				destination = full,
			},
			surface = {1, surface_generation},
			format = .Bgra_8888,
			display_aspect = presentation.aspect_ratio_make(extent.width, extent.height),
			surface_extent = extent,
			canvas_extent = extent,
			source = full,
			destination = full,
			dirty = presentation.rect_set_full(extent),
			source_kind = .Legacy_Snapshot,
			ownership = .Mailbox_Descriptor,
		},
	}
}

graphics_frame_consumer_test_gsw_present :: proc(
	sequence, lifecycle, mode_generation: u64,
) -> presentation.Gsw_Present {
	extent := presentation.Extent{1, 1}
	full := presentation.Rect {
		width  = 1,
		height = 1,
	}
	return {
		clip_mode = .Fullscreen,
		source_pitch = 4,
		header = {
			sequence = sequence,
			lifecycle_generation = lifecycle,
			mode_generation = mode_generation,
			mode_key = {
				format = .Bgrx_8888,
				display_aspect = {1, 1},
				surface_extent = extent,
				canvas_extent = extent,
				source = full,
				destination = full,
			},
			identity_namespace = .Gsw2d,
			device_generation = 1,
			surface = {2, 1},
			format = .Bgrx_8888,
			display_aspect = {1, 1},
			surface_extent = extent,
			canvas_extent = extent,
			source = full,
			destination = full,
			dirty = presentation.rect_set_full(extent),
			source_kind = .Gsw_Snapshot,
			ownership = .Mailbox_Surface,
		},
	}
}

graphics_frame_consumer_test_prepare_combined :: proc(
	slot: ^Frame_Slot,
	lifecycle: u64,
	gsw_sequence, legacy_sequence: u64,
) {
	if slot == nil {return}
	slot.scanout.generation = legacy_sequence
	if presentation.generation_order(gsw_sequence, legacy_sequence) == .Newer {
		slot.scanout.generation = gsw_sequence
	}
	slot.scanout.legacy_update = graphics_frame_consumer_test_legacy_update(
		legacy_sequence,
		lifecycle,
	)
	slot.scanout.legacy_update.header.mode_generation = 2
	slot.scanout.legacy_update.header.surface.generation = 2
	slot.scanout.vram = make([]u8, 1)
	gsw := &slot.scanout.gsw_presentation
	gsw.present = graphics_frame_consumer_test_gsw_present(gsw_sequence, lifecycle, 2)
	gsw.present_valid = true
	gsw.damage_kind = .Pixel_Memory
	gsw.source = make([]u8, 4)
	gsw.source[0] = 0x44
	gsw.source[1] = 0x55
	gsw.source[2] = 0x66
	gsw.source[3] = 0xFF
}

graphics_frame_consumer_test_seed_legacy :: proc(
	t: ^testing.T,
	target: ^host.Host,
	lifecycle: u64,
	probe: ^Graphics_Frame_Consumer_Test_Stage_Probe,
	extent: presentation.Extent = {1, 1},
) -> bool {
	initial := graphics_frame_consumer_test_legacy_update(8, lifecycle, extent)
	admission := host.host_presentation_admit_legacy(target, initial)
	if !testing.expect(t, admission.valid) {return false}
	pixels := make([]u32, int(extent.width) * int(extent.height))
	defer delete(pixels)
	pixels[0] = 0xFF000000
	frame := vga.Display_Frame {
		kind           = .Xrgb_8888,
		width          = int(extent.width),
		height         = int(extent.height),
		pixels         = pixels,
		dirty          = initial.header.dirty,
		updated_pixels = u64(len(pixels)),
	}
	staged := graphics_frame_consumer_test_stage(probe, target, &admission, &frame, nil)
	if !testing.expect(t, staged.valid) {return false}
	if !testing.expect(
		t,
		host.host_presentation_commit_legacy_staged(target, &admission, staged),
	) {
		return false
	}
	probe.order_count = 0
	probe.order = {}
	return true
}

@(test)
graphics_frame_consumer_test_restorations_promote_the_selected_source :: proc(t: ^testing.T) {
	legacy, restored := graphics_gsw_restoration_source(.Restore_Legacy)
	testing.expect(t, restored)
	testing.expect_value(t, legacy, Graphics_Frame_Source.Legacy_Scanout)

	gsw, gsw_restored := graphics_gsw_restoration_source(.Restore_Gsw)
	testing.expect(t, gsw_restored)
	testing.expect_value(t, gsw, Graphics_Frame_Source.Gsw2d)

	_, clear_restored := graphics_gsw_restoration_source(presentation.Selector_Action.Clear)
	testing.expect(t, !clear_restored)
}

@(test)
graphics_frame_consumer_test_sequence_order_places_older_gsw_first :: proc(t: ^testing.T) {
	descriptor_sequence := u64(21)
	mailbox: Frame_Mailbox
	defer frame_mailbox_destroy(&mailbox)
	descriptor, reserved := frame_mailbox_begin(&mailbox, descriptor_sequence)
	if !testing.expect(t, reserved) {return}
	descriptor.scanout.legacy_update.header.sequence = 21
	descriptor.scanout.gsw_presentation.present_valid = true
	descriptor.scanout.gsw_presentation.present.header.sequence = 20
	testing.expect_value(
		t,
		graphics_frame_consumer_record_order(&descriptor.scanout),
		Graphics_Frame_Record_Order.Gsw_First,
	)
	descriptor.scanout.gsw_presentation.present.header.sequence = 22
	testing.expect_value(
		t,
		graphics_frame_consumer_record_order(&descriptor.scanout),
		Graphics_Frame_Record_Order.Legacy_First,
	)
	_ = frame_mailbox_commit(&mailbox, descriptor, false)
}

@(test)
graphics_frame_consumer_test_single_source_and_zero_sequence_order_is_stable :: proc(
	t: ^testing.T,
) {
	descriptor: vga.Scanout_Descriptor
	testing.expect_value(
		t,
		graphics_frame_consumer_record_order(&descriptor),
		Graphics_Frame_Record_Order.Single,
	)
	descriptor.gsw_presentation.present_valid = true
	descriptor.gsw_presentation.present.header.sequence = 9
	testing.expect_value(
		t,
		graphics_frame_consumer_record_order(&descriptor),
		Graphics_Frame_Record_Order.Single,
	)
	descriptor.legacy_update.header.sequence = 8
	descriptor.gsw_presentation.present.header.sequence = 0
	testing.expect_value(
		t,
		graphics_frame_consumer_record_order(&descriptor),
		Graphics_Frame_Record_Order.Invalid,
	)
}

@(test)
graphics_frame_consumer_test_single_legacy_commits_and_acks_only_legacy :: proc(t: ^testing.T) {
	video := new(Video_Presentation)
	defer {
		frame_mailbox_destroy(video)
		free(video)
	}
	lifecycle := frame_mailbox_lifecycle_generation(video)
	target: host.Host
	if !testing.expect(t, host.host_presentation_start(&target, lifecycle)) {return}
	defer host.host_presentation_stop(&target)
	probe := Graphics_Frame_Consumer_Test_Stage_Probe {
		mailbox      = video,
		next_texture = 50,
	}
	ops := Graphics_Frame_Consumer_Ops {
		ctx           = &probe,
		expand_legacy = graphics_frame_consumer_test_expand_legacy,
		expand_gsw    = graphics_frame_consumer_test_expand_gsw,
		stage         = graphics_frame_consumer_test_stage,
	}
	slot, reserved := frame_mailbox_begin(video, 10)
	if !testing.expect(t, reserved) {return}
	graphics_frame_consumer_test_prepare_combined(slot, lifecycle, 11, 10)
	slot.scanout.gsw_presentation.present_valid = false
	slot.scanout.generation = 10
	if !testing.expect(t, frame_mailbox_commit(video, slot, true)) {return}
	checkpoint: time.Tick
	consumed := graphics_frame_consume(video, &target, false, &checkpoint, &ops)
	testing.expect(t, consumed.graphics_epoch_pending)
	testing.expect_value(t, consumed.graphics_epoch.source, Graphics_Frame_Source.Legacy_Scanout)
	testing.expect_value(t, probe.order_count, 1)
	testing.expect_value(t, probe.order[0], host.Host_Presentation_Kind.Legacy)
	testing.expect_value(
		t,
		target.presentation_state.selector.active.kind,
		presentation.Active_Kind.Legacy,
	)
	legacy_ack, legacy_ack_valid := frame_mailbox_take_legacy_ack(video)
	_, gsw_ack_valid := frame_mailbox_take_gsw_ack(video)
	testing.expect(t, legacy_ack_valid)
	testing.expect_value(t, legacy_ack.sequence, u64(10))
	testing.expect(t, !gsw_ack_valid)
}

@(test)
graphics_frame_consumer_test_single_gsw_commits_and_acks_only_gsw :: proc(t: ^testing.T) {
	video := new(Video_Presentation)
	defer {
		frame_mailbox_destroy(video)
		free(video)
	}
	lifecycle := frame_mailbox_lifecycle_generation(video)
	target: host.Host
	if !testing.expect(t, host.host_presentation_start(&target, lifecycle)) {return}
	defer host.host_presentation_stop(&target)
	probe := Graphics_Frame_Consumer_Test_Stage_Probe {
		mailbox      = video,
		next_texture = 75,
	}
	ops := Graphics_Frame_Consumer_Ops {
		ctx           = &probe,
		expand_legacy = graphics_frame_consumer_test_expand_legacy,
		expand_gsw    = graphics_frame_consumer_test_expand_gsw,
		stage         = graphics_frame_consumer_test_stage,
	}
	slot, reserved := frame_mailbox_begin(video, 10)
	if !testing.expect(t, reserved) {return}
	graphics_frame_consumer_test_prepare_combined(slot, lifecycle, 10, 0)
	slot.scanout.generation = 10
	if !testing.expect(t, frame_mailbox_commit(video, slot, true)) {return}
	checkpoint: time.Tick
	consumed := graphics_frame_consume(video, &target, false, &checkpoint, &ops)
	testing.expect(t, consumed.graphics_epoch_pending)
	testing.expect_value(t, consumed.graphics_epoch.source, Graphics_Frame_Source.Gsw2d)
	testing.expect_value(t, probe.order_count, 1)
	testing.expect_value(t, probe.order[0], host.Host_Presentation_Kind.Gsw_Snapshot)
	testing.expect_value(
		t,
		target.presentation_state.selector.active.kind,
		presentation.Active_Kind.Gsw,
	)
	gsw_ack, gsw_ack_valid := frame_mailbox_take_gsw_ack(video)
	_, legacy_ack_valid := frame_mailbox_take_legacy_ack(video)
	testing.expect(t, gsw_ack_valid)
	testing.expect_value(t, gsw_ack.sequence, u64(10))
	testing.expect(t, !legacy_ack_valid)
}

graphics_frame_consumer_test_reject_invalid_pair_order :: proc(
	t: ^testing.T,
	legacy_sequence, gsw_sequence: u64,
) {
	video := new(Video_Presentation)
	defer {
		frame_mailbox_destroy(video)
		free(video)
	}
	lifecycle := frame_mailbox_lifecycle_generation(video)
	target: host.Host
	if !testing.expect(t, host.host_presentation_start(&target, lifecycle)) {return}
	defer host.host_presentation_stop(&target)
	slot, reserved := frame_mailbox_begin(video, legacy_sequence)
	if !testing.expect(t, reserved) {return}
	slot.scanout.generation = legacy_sequence
	slot.scanout.legacy_update.header.sequence = legacy_sequence
	slot.scanout.gsw_presentation.present_valid = true
	slot.scanout.gsw_presentation.present.header.sequence = gsw_sequence
	if !testing.expect(t, frame_mailbox_commit(video, slot, true)) {return}
	checkpoint: time.Tick
	consumed := graphics_frame_consume(video, &target, false, &checkpoint)
	testing.expect(t, !consumed.graphics_epoch_pending)
	testing.expect_value(t, target.presentation_state.sequence, u64(0))
	_, legacy_ack_valid := frame_mailbox_take_legacy_ack(video)
	_, gsw_ack_valid := frame_mailbox_take_gsw_ack(video)
	testing.expect(t, !legacy_ack_valid)
	testing.expect(t, !gsw_ack_valid)
}

@(test)
graphics_frame_consumer_test_equal_pair_sequences_fail_closed :: proc(t: ^testing.T) {
	graphics_frame_consumer_test_reject_invalid_pair_order(t, 7, 7)
}

@(test)
graphics_frame_consumer_test_ambiguous_pair_sequences_fail_closed :: proc(t: ^testing.T) {
	graphics_frame_consumer_test_reject_invalid_pair_order(
		t,
		1,
		1 + presentation.GENERATION_HALF_RANGE,
	)
}

@(test)
graphics_frame_consumer_test_legacy_render_failure_allows_identical_republish :: proc(
	t: ^testing.T,
) {
	video := new(Video_Presentation)
	defer {
		frame_mailbox_destroy(video)
		free(video)
	}
	lifecycle := frame_mailbox_lifecycle_generation(video)
	target: host.Host
	if !testing.expect(t, host.host_presentation_start(&target, lifecycle)) {return}
	defer host.host_presentation_stop(&target)
	slot, reserved := frame_mailbox_begin(video, 7)
	if !testing.expect(t, reserved) {return}
	slot.scanout.generation = 7
	slot.scanout.legacy_update = graphics_frame_consumer_test_legacy_update(7, lifecycle)
	if !testing.expect(t, frame_mailbox_commit(video, slot, true)) {return}
	checkpoint: time.Tick
	consumed := graphics_frame_consume(video, &target, false, &checkpoint)
	testing.expect(t, !consumed.graphics_epoch_pending)
	_, ack_valid := frame_mailbox_take_legacy_ack(video)
	testing.expect(t, !ack_valid)

	retry, retry_reserved := frame_mailbox_begin(video, 7)
	if !testing.expect(t, retry_reserved) {return}
	_ = frame_mailbox_commit(video, retry, false)
}

@(test)
graphics_frame_consumer_test_older_gsw_failure_blocks_later_legacy_and_acks_neither :: proc(
	t: ^testing.T,
) {
	video := new(Video_Presentation)
	defer {
		frame_mailbox_destroy(video)
		free(video)
	}
	lifecycle := frame_mailbox_lifecycle_generation(video)
	target: host.Host
	if !testing.expect(t, host.host_presentation_start(&target, lifecycle)) {return}
	defer host.host_presentation_stop(&target)
	slot, reserved := frame_mailbox_begin(video, 11)
	if !testing.expect(t, reserved) {return}
	slot.scanout.generation = 11
	slot.scanout.legacy_update = graphics_frame_consumer_test_legacy_update(11, lifecycle)
	slot.scanout.gsw_presentation.present_valid = true
	slot.scanout.gsw_presentation.present.header = {
		sequence             = 10,
		lifecycle_generation = lifecycle,
	}
	if !testing.expect(t, frame_mailbox_commit(video, slot, true)) {return}
	checkpoint: time.Tick
	consumed := graphics_frame_consume(video, &target, false, &checkpoint)
	testing.expect(t, !consumed.graphics_epoch_pending)
	testing.expect_value(t, target.presentation_state.sequence, u64(0))
	_, legacy_ack_valid := frame_mailbox_take_legacy_ack(video)
	_, gsw_ack_valid := frame_mailbox_take_gsw_ack(video)
	testing.expect(t, !legacy_ack_valid)
	testing.expect(t, !gsw_ack_valid)

	_, retry_reserved := frame_mailbox_begin(video, 11)
	testing.expect(t, !retry_reserved)
}

@(test)
graphics_frame_consumer_test_gsw_then_hidden_legacy_commits_and_acks_in_order :: proc(
	t: ^testing.T,
) {
	video := new(Video_Presentation)
	defer {
		frame_mailbox_destroy(video)
		free(video)
	}
	lifecycle := frame_mailbox_lifecycle_generation(video)
	target: host.Host
	if !testing.expect(t, host.host_presentation_start(&target, lifecycle)) {return}
	defer host.host_presentation_stop(&target)
	probe := Graphics_Frame_Consumer_Test_Stage_Probe {
		mailbox      = video,
		next_texture = 100,
	}
	if !graphics_frame_consumer_test_seed_legacy(t, &target, lifecycle, &probe, {2, 2}) {return}
	ops := Graphics_Frame_Consumer_Ops {
		ctx           = &probe,
		expand_legacy = graphics_frame_consumer_test_expand_legacy,
		expand_gsw    = graphics_frame_consumer_test_expand_gsw,
		stage         = graphics_frame_consumer_test_stage,
	}
	slot, reserved := frame_mailbox_begin(video, 11)
	if !testing.expect(t, reserved) {return}
	graphics_frame_consumer_test_prepare_combined(slot, lifecycle, 10, 11)
	if !testing.expect(t, frame_mailbox_commit(video, slot, true)) {return}
	checkpoint: time.Tick
	consumed := graphics_frame_consume(video, &target, false, &checkpoint, &ops)
	testing.expect(t, consumed.graphics_epoch_pending)
	testing.expect_value(t, consumed.graphics_epoch.source, Graphics_Frame_Source.Gsw2d)
	testing.expect_value(t, consumed.graphics_epoch.kind, vga.Display_Kind.Xrgb_8888)
	testing.expect_value(t, consumed.graphics_epoch.render_work_samples, u64(2))
	testing.expect_value(t, consumed.graphics_epoch.rendered_pixels, u64(2))
	testing.expect_value(t, probe.order_count, 2)
	testing.expect_value(t, probe.order[0], host.Host_Presentation_Kind.Gsw_Snapshot)
	testing.expect_value(t, probe.order[1], host.Host_Presentation_Kind.Legacy)
	testing.expect_value(
		t,
		target.presentation_state.selector.active.kind,
		presentation.Active_Kind.Gsw,
	)
	testing.expect_value(t, target.presentation_state.last_vga_sequence, u64(11))
	gsw_ack, gsw_ack_valid := frame_mailbox_take_gsw_ack(video)
	legacy_ack, legacy_ack_valid := frame_mailbox_take_legacy_ack(video)
	testing.expect(t, gsw_ack_valid)
	testing.expect(t, legacy_ack_valid)
	testing.expect_value(t, gsw_ack.sequence, u64(10))
	testing.expect_value(t, legacy_ack.sequence, u64(11))
}

@(test)
graphics_frame_consumer_test_first_gsw_stage_failure_blocks_legacy_and_retries :: proc(
	t: ^testing.T,
) {
	video := new(Video_Presentation)
	defer {
		frame_mailbox_destroy(video)
		free(video)
	}
	lifecycle := frame_mailbox_lifecycle_generation(video)
	target: host.Host
	if !testing.expect(t, host.host_presentation_start(&target, lifecycle)) {return}
	defer host.host_presentation_stop(&target)
	probe := Graphics_Frame_Consumer_Test_Stage_Probe {
		mailbox      = video,
		next_texture = 200,
	}
	if !graphics_frame_consumer_test_seed_legacy(t, &target, lifecycle, &probe) {return}
	probe.fail_kind = .Gsw_Snapshot
	ops := Graphics_Frame_Consumer_Ops {
		ctx           = &probe,
		expand_legacy = graphics_frame_consumer_test_expand_legacy,
		expand_gsw    = graphics_frame_consumer_test_expand_gsw,
		stage         = graphics_frame_consumer_test_stage,
	}
	slot, reserved := frame_mailbox_begin(video, 11)
	if !testing.expect(t, reserved) {return}
	graphics_frame_consumer_test_prepare_combined(slot, lifecycle, 10, 11)
	if !testing.expect(t, frame_mailbox_commit(video, slot, true)) {return}
	checkpoint: time.Tick
	consumed := graphics_frame_consume(video, &target, false, &checkpoint, &ops)
	testing.expect(t, !consumed.graphics_epoch_pending)
	testing.expect_value(t, probe.order_count, 1)
	testing.expect_value(t, probe.order[0], host.Host_Presentation_Kind.Gsw_Snapshot)
	testing.expect_value(
		t,
		target.presentation_state.selector.active.kind,
		presentation.Active_Kind.Legacy,
	)
	_, legacy_ack_valid := frame_mailbox_take_legacy_ack(video)
	_, gsw_ack_valid := frame_mailbox_take_gsw_ack(video)
	testing.expect(t, !legacy_ack_valid)
	testing.expect(t, !gsw_ack_valid)
	retry, retry_reserved := frame_mailbox_begin(video, 11)
	if !testing.expect(t, retry_reserved) {return}
	_ = frame_mailbox_commit(video, retry, false)
}

@(test)
graphics_frame_consumer_test_legacy_then_gsw_commits_and_acks_in_order :: proc(t: ^testing.T) {
	video := new(Video_Presentation)
	defer {
		frame_mailbox_destroy(video)
		free(video)
	}
	lifecycle := frame_mailbox_lifecycle_generation(video)
	target: host.Host
	if !testing.expect(t, host.host_presentation_start(&target, lifecycle)) {return}
	defer host.host_presentation_stop(&target)
	probe := Graphics_Frame_Consumer_Test_Stage_Probe {
		mailbox      = video,
		next_texture = 250,
	}
	if !graphics_frame_consumer_test_seed_legacy(t, &target, lifecycle, &probe) {return}
	ops := Graphics_Frame_Consumer_Ops {
		ctx           = &probe,
		expand_legacy = graphics_frame_consumer_test_expand_legacy,
		expand_gsw    = graphics_frame_consumer_test_expand_gsw,
		stage         = graphics_frame_consumer_test_stage,
	}
	slot, reserved := frame_mailbox_begin(video, 11)
	if !testing.expect(t, reserved) {return}
	graphics_frame_consumer_test_prepare_combined(slot, lifecycle, 11, 10)
	slot.scanout.legacy_update.header.mode_generation = 1
	if !testing.expect(t, frame_mailbox_commit(video, slot, true)) {return}
	checkpoint: time.Tick
	consumed := graphics_frame_consume(video, &target, false, &checkpoint, &ops)
	testing.expect(t, consumed.graphics_epoch_pending)
	testing.expect_value(t, consumed.graphics_epoch.source, Graphics_Frame_Source.Gsw2d)
	testing.expect_value(t, probe.order_count, 2)
	testing.expect_value(t, probe.order[0], host.Host_Presentation_Kind.Legacy)
	testing.expect_value(t, probe.order[1], host.Host_Presentation_Kind.Gsw_Snapshot)
	testing.expect_value(
		t,
		target.presentation_state.selector.active.kind,
		presentation.Active_Kind.Gsw,
	)
	legacy_ack, legacy_ack_valid := frame_mailbox_take_legacy_ack(video)
	gsw_ack, gsw_ack_valid := frame_mailbox_take_gsw_ack(video)
	testing.expect(t, legacy_ack_valid)
	testing.expect(t, gsw_ack_valid)
	testing.expect_value(t, legacy_ack.sequence, u64(10))
	testing.expect_value(t, gsw_ack.sequence, u64(11))
}

@(test)
graphics_frame_consumer_test_first_legacy_stage_failure_blocks_gsw_and_retries :: proc(
	t: ^testing.T,
) {
	video := new(Video_Presentation)
	defer {
		frame_mailbox_destroy(video)
		free(video)
	}
	lifecycle := frame_mailbox_lifecycle_generation(video)
	target: host.Host
	if !testing.expect(t, host.host_presentation_start(&target, lifecycle)) {return}
	defer host.host_presentation_stop(&target)
	probe := Graphics_Frame_Consumer_Test_Stage_Probe {
		mailbox      = video,
		next_texture = 275,
	}
	if !graphics_frame_consumer_test_seed_legacy(t, &target, lifecycle, &probe) {return}
	probe.fail_kind = .Legacy
	ops := Graphics_Frame_Consumer_Ops {
		ctx           = &probe,
		expand_legacy = graphics_frame_consumer_test_expand_legacy,
		expand_gsw    = graphics_frame_consumer_test_expand_gsw,
		stage         = graphics_frame_consumer_test_stage,
	}
	slot, reserved := frame_mailbox_begin(video, 11)
	if !testing.expect(t, reserved) {return}
	graphics_frame_consumer_test_prepare_combined(slot, lifecycle, 11, 10)
	slot.scanout.legacy_update.header.mode_generation = 1
	if !testing.expect(t, frame_mailbox_commit(video, slot, true)) {return}
	checkpoint: time.Tick
	consumed := graphics_frame_consume(video, &target, false, &checkpoint, &ops)
	testing.expect(t, !consumed.graphics_epoch_pending)
	testing.expect_value(t, probe.order_count, 1)
	testing.expect_value(t, probe.order[0], host.Host_Presentation_Kind.Legacy)
	testing.expect_value(
		t,
		target.presentation_state.selector.active.kind,
		presentation.Active_Kind.Legacy,
	)
	_, legacy_ack_valid := frame_mailbox_take_legacy_ack(video)
	_, gsw_ack_valid := frame_mailbox_take_gsw_ack(video)
	testing.expect(t, !legacy_ack_valid)
	testing.expect(t, !gsw_ack_valid)
	retry, retry_reserved := frame_mailbox_begin(video, 11)
	if !testing.expect(t, retry_reserved) {return}
	_ = frame_mailbox_commit(video, retry, false)
}

Graphics_Frame_Consumer_Recovery_Probe :: struct {
	recovered_pixels:      []u32,
	next_texture:          uintptr,
	require_full:          bool,
	needs_full:            int,
	recovery_pending:      bool,
	recovery_full_count:   int,
	recovery_upload_bytes: u64,
	recovery_plan:         vga.Scanout_Capture_Plan,
	plan_fault:            bool,
}

graphics_frame_consumer_recovery_plan_valid :: proc(
	plan: ^vga.Scanout_Capture_Plan,
	update: presentation.Legacy_Frame_Update,
	source_mode_generation: u64,
) -> bool {
	if plan == nil {return false}
	return(
		plan.owner == .Legacy &&
		plan.observed_owner == .Legacy &&
		plan.owner_generation == update.header.lifecycle_generation &&
		plan.mode_generation == source_mode_generation &&
		plan.surface_id == update.header.surface.id &&
		plan.surface_generation == update.header.surface.generation &&
		plan.full_reason == update.full_reason &&
		plan.required_ranges.count != 0 \
	)
}

graphics_frame_consumer_recovery_stage :: proc(
	ctx: rawptr,
	target: ^host.Host,
	admission: ^host.Host_Presentation_Admission,
	frame: ^vga.Display_Frame,
	capture_plan: ^vga.Scanout_Capture_Plan,
) -> host.Host_Presentation_Staged_Texture {
	probe := (^Graphics_Frame_Consumer_Recovery_Probe)(ctx)
	if probe == nil ||
	   target == nil ||
	   admission == nil ||
	   frame == nil ||
	   admission.kind != .Legacy {return {}}
	update := admission.legacy
	header := update.header
	if !graphics_frame_consumer_recovery_plan_valid(
		capture_plan,
		update,
		admission.source_mode_generation,
	) {
		probe.plan_fault = true
		return {}
	}
	if frame.width != int(header.surface_extent.width) ||
	   frame.height != int(header.surface_extent.height) ||
	   frame.width <= 0 ||
	   frame.height <= 0 ||
	   frame.width > max(int) / frame.height {
		probe.plan_fault = true
		return {}
	}
	if len(frame.pixels) < frame.width * frame.height {
		probe.plan_fault = true
		return {}
	}
	if !presentation.rect_set_equal(frame.dirty, header.dirty) {
		probe.plan_fault = true
		return {}
	}
	full := capture_plan.coverage == .Full
	partial := capture_plan.coverage == .Partial
	header_full := presentation.rect_set_equal(
		header.dirty,
		presentation.rect_set_full(header.surface_extent),
	)
	if (!full && !partial) || full != header_full {
		probe.plan_fault = true
		return {}
	}
	if partial && probe.require_full {
		probe.needs_full += 1
		probe.recovery_pending = true
		return {
			status               = .Needs_Full_Baseline,
			kind                 = .Legacy,
			lifecycle_generation = header.lifecycle_generation,
			admission_sequence   = header.sequence,
		}
	}

	upload_pixels: u64
	if full {
		upload_pixels = u64(frame.width * frame.height)
	} else {
		for rect_index in 0 ..< int(header.dirty.count) {
			rect := header.dirty.rects[rect_index]
			upload_pixels += u64(rect.width) * u64(rect.height)
		}
	}
	if frame.updated_pixels != upload_pixels {
		probe.plan_fault = true
		return {}
	}
	upload_bytes := upload_pixels * size_of(u32)
	if full && probe.recovery_pending {
		probe.recovery_pending = false
		probe.recovery_full_count += 1
		probe.recovery_upload_bytes = upload_bytes
		probe.recovery_plan = capture_plan^
		needed := frame.width * frame.height
		probe.recovered_pixels = make([]u32, needed)
		copy(probe.recovered_pixels, frame.pixels[:needed])
	}

	probe.next_texture += 1
	texture := transmute(^sdl3.Texture)(probe.next_texture)
	stage_generation := presentation.generation_next(
		target.presentation_state.texture_stage_generation,
	)
	target.presentation_state.texture_stage_generation = stage_generation
	target.presentation_state.legacy_staging = {
		texture          = texture,
		width            = frame.width,
		height           = frame.height,
		stage_generation = stage_generation,
	}
	return {
		valid                = true,
		status               = .Ready,
		kind                 = .Legacy,
		texture              = texture,
		width                = frame.width,
		height               = frame.height,
		stage_generation     = stage_generation,
		lifecycle_generation = header.lifecycle_generation,
		admission_sequence   = header.sequence,
		upload_bytes         = upload_bytes,
		upload_regions       = u64(header.dirty.count),
	}
}

graphics_frame_consumer_recovery_fill_sentinel :: proc(pixels: []u32, pitch: int) {
	if pitch != 800 || len(pixels) != 800 * 600 {return}
	for &pixel, index in pixels {pixel = 0xFF00_0000 | u32(index)}
	for y in 0 ..< 48 {
		for x in 0 ..< 64 {
			red := u32((x * 17 + y * 3) & 0xFF)
			green := u32((x * 5 + y * 11) & 0xFF)
			blue := u32((x * 13 + y * 7) & 0xFF)
			pixels[(33 + y) * pitch + 17 + x] =
				0xFF00_0000 | red << 16 | green << 8 | blue
		}
	}
	crc_patch := [5]u32{0x45, 0x4C, 0x9C, 0x7F, 0}
	for blue, index in crc_patch {
		pixel := &pixels[80 * pitch + 76 + index]
		pixel^ = pixel^ & 0xFFFF_FF00 | blue
	}
}

graphics_frame_consumer_recovery_store_vram :: proc(target: ^vga.Vga, pixels: []u32) -> bool {
	if target == nil || len(target.vram) < len(pixels) * size_of(u32) {return false}
	for pixel, index in pixels {
		offset := index * size_of(u32)
		target.vram[offset + 0] = u8(pixel)
		target.vram[offset + 1] = u8(pixel >> 8)
		target.vram[offset + 2] = u8(pixel >> 16)
		target.vram[offset + 3] = 0
	}
	return true
}

graphics_frame_consumer_recovery_roi_crc32 :: proc(
	pixels: []u32,
	pitch: int,
	rect: presentation.Rect,
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

graphics_frame_consumer_recovery_consume_and_ack :: proc(
	t: ^testing.T,
	video: ^Video_Presentation,
	target: ^host.Host,
	source: ^vga.Vga,
	ops: ^Graphics_Frame_Consumer_Ops,
) -> bool {
	checkpoint: time.Tick
	consumed := graphics_frame_consume(video, target, false, &checkpoint, ops)
	if !testing.expect(t, consumed.graphics_epoch_pending) {return false}
	epoch := consumed.graphics_epoch
	_ = frame_mailbox_graphics_epoch_complete_and_record(
		video,
		&epoch,
		.Gpu_Work,
		time.tick_now(),
	)
	ack, valid := frame_mailbox_take_legacy_ack(video)
	if !testing.expect(t, valid) {return false}
	return testing.expect(
		t,
		vga.vga_damage_acknowledge_identity(
			source,
			ack.sequence,
			ack.mode_generation,
			ack.surface_id,
			ack.surface_generation,
		),
	)
}

@(test)
graphics_frame_consumer_test_exact_legacy_restoration_recovers_full_baseline :: proc(
	t: ^testing.T,
) {
	m := new(machine.Machine)
	defer free(m)
	backing := make([]u8, vga.VRAM_SIZE)
	defer delete(backing)
	if !testing.expect(t, vga.vga_init(&m.vga, backing)) {return}
	defer vga.vga_destroy(&m.vga)

	video := new(Video_Presentation)
	defer {
		frame_mailbox_destroy(video)
		free(video)
	}
	lifecycle := frame_mailbox_lifecycle_generation(video)
	frame_mailbox_graphics_telemetry_init(video, true)
	target: host.Host
	if !testing.expect(t, host.host_presentation_start(&target, lifecycle)) {return}
	defer host.host_presentation_stop(&target)
	probe := Graphics_Frame_Consumer_Recovery_Probe {next_texture = 400}
	defer if probe.recovered_pixels != nil {delete(probe.recovered_pixels)}
	ops := Graphics_Frame_Consumer_Ops {
		ctx   = &probe,
		stage = graphics_frame_consumer_recovery_stage,
	}

	expected := make([]u32, 800 * 600)
	defer delete(expected)
	graphics_frame_consumer_recovery_fill_sentinel(expected, 800)
	sentinel := presentation.Rect{17, 33, 64, 48}
	if !testing.expect_value(
		t,
		graphics_frame_consumer_recovery_roi_crc32(expected, 800, sentinel),
		u32(0xF0D0_99D4),
	) {return}
	frame_mailbox_test_set_vbe_mode(&m.vga, 800, 600, 32)
	if !testing.expect(t, graphics_frame_consumer_recovery_store_vram(&m.vga, expected)) {
		return
	}
	vga.vga_note_content_change(&m.vga)
	desktop, published := frame_mailbox_test_publish_legacy(
		video,
		&m.vga,
		vga.vga_presentation_sequence(&m.vga),
	)
	if !testing.expect(t, published) {return}
	testing.expect_value(t, desktop.scanout.capture_plan.coverage, vga.Scanout_Capture_Coverage.Full)
	if !graphics_frame_consumer_recovery_consume_and_ack(t, video, &target, &m.vga, &ops) {
		return
	}

	frame_mailbox_test_set_vbe_mode(&m.vga, 320, 240, 32)
	mode_x, mode_x_published := frame_mailbox_test_publish_legacy(
		video,
		&m.vga,
		vga.vga_presentation_sequence(&m.vga),
	)
	if !testing.expect(t, mode_x_published) {return}
	testing.expect_value(t, mode_x.scanout.capture_plan.coverage, vga.Scanout_Capture_Coverage.Full)
	if !graphics_frame_consumer_recovery_consume_and_ack(t, video, &target, &m.vga, &ops) {
		return
	}

	frame_mailbox_test_set_vbe_mode(&m.vga, 800, 600, 32)
	return_slot, return_published := frame_mailbox_test_publish_legacy(
		video,
		&m.vga,
		vga.vga_presentation_sequence(&m.vga),
	)
	if !testing.expect(t, return_published) {return}
	returned := frame_mailbox_acquire(video)
	if !testing.expect(t, returned == return_slot) {return}
	returned_frame := graphics_frame_expand_legacy_result(video, &returned.scanout, nil).frame
	if !testing.expect(t, returned_frame != nil) {return}
	testing.expect_value(t, returned_frame.width, 800)
	testing.expect_value(t, returned_frame.height, 600)
	return_update := returned.scanout.legacy_update
	if !testing.expect(
		t,
		vga.vga_damage_acknowledge_identity(
			&m.vga,
			return_update.header.sequence,
			return_update.header.mode_generation,
			return_update.header.surface.id,
			return_update.header.surface.generation,
		),
	) {return}
	_ = frame_mailbox_graphics_epoch_complete_and_record(
		video,
		&returned.epoch,
		.Superseded,
		time.tick_now(),
	)
	frame_mailbox_release(video, returned)

	pixel_index := 100 * 800 + 100
	byte_offset := pixel_index * size_of(u32)
	if !testing.expect(
		t,
		vga.vga_mmio_write(&m.vga, m.vga.framebuffer_base + u64(byte_offset), 1, 0xA5),
	) {return}
	expected[pixel_index] = expected[pixel_index] & 0xFFFF_FF00 | 0xA5
	partial, partial_published := frame_mailbox_test_publish_legacy(
		video,
		&m.vga,
		vga.vga_presentation_sequence(&m.vga),
	)
	if !testing.expect(t, partial_published) {return}
	partial_plan := partial.scanout.capture_plan
	testing.expect_value(t, partial_plan.coverage, vga.Scanout_Capture_Coverage.Partial)
	testing.expect_value(t, partial_plan.owner, presentation.Display_Owner.Legacy)
	testing.expect_value(t, partial_plan.observed_owner, presentation.Display_Owner.Legacy)
	testing.expect_value(
		t,
		partial.scanout.legacy_update.header.dirty.rects[0],
		presentation.Rect{100, 100, 1, 1},
	)
	probe.require_full = true
	checkpoint: time.Tick
	partial_result := graphics_frame_consume(video, &target, false, &checkpoint, &ops)
	testing.expect(t, !partial_result.graphics_epoch_pending)
	testing.expect_value(t, partial.epoch.result, Graphics_Frame_Result.Superseded)
	testing.expect_value(t, probe.needs_full, 1)
	testing.expect(t, video.legacy_baseline.valid)
	testing.expect_value(t, video.legacy_baseline.owner_generation, lifecycle)
	testing.expect_value(t, video.telemetry.current.upload_failures, u64(0))

	if !testing.expect(t, frame_mailbox_apply_legacy_full_baseline(video, m)) {return}
	recovery, recovery_published := frame_mailbox_test_publish_legacy(
		video,
		&m.vga,
		vga.vga_presentation_sequence(&m.vga),
	)
	if !testing.expect(t, recovery_published) {return}
	recovery_plan := recovery.scanout.capture_plan
	recovery_update := recovery.scanout.legacy_update
	testing.expect_value(t, recovery_plan.coverage, vga.Scanout_Capture_Coverage.Full)
	testing.expect_value(
		t,
		recovery_plan.full_reason,
		presentation.Damage_Full_Reason.External_Tracking,
	)
	testing.expect_value(t, recovery_plan.owner_generation, recovery_update.header.lifecycle_generation)
	testing.expect_value(t, recovery_plan.mode_generation, recovery_update.header.mode_generation)
	testing.expect_value(t, recovery_plan.surface_id, recovery_update.header.surface.id)
	testing.expect_value(
		t,
		recovery_plan.surface_generation,
		recovery_update.header.surface.generation,
	)
	testing.expect_value(t, recovery_plan.required_ranges.count, u32(1))
	testing.expect_value(
		t,
		recovery_plan.required_ranges.ranges[0],
		vga.Vga_Damage_Range{0, 1_920_000},
	)
	testing.expect_value(t, recovery.scanout.bytes_copied, 1_920_000)
	if !graphics_frame_consumer_recovery_consume_and_ack(t, video, &target, &m.vga, &ops) {
		return
	}

	testing.expect(t, !probe.plan_fault)
	testing.expect_value(t, probe.needs_full, 1)
	testing.expect_value(t, probe.recovery_full_count, 1)
	testing.expect_value(t, probe.recovery_upload_bytes, u64(1_920_000))
	testing.expect(t, probe.recovery_plan == recovery_plan)
	testing.expect(t, !video.legacy_baseline.valid)
	testing.expect_value(t, video.telemetry.current.upload_failures, u64(0))
	exact := len(probe.recovered_pixels) == len(expected)
	if exact {
		for pixel, index in probe.recovered_pixels {
			if pixel != expected[index] {
				exact = false
				break
			}
		}
	}
	testing.expect(t, exact)
	testing.expect_value(
		t,
		graphics_frame_consumer_recovery_roi_crc32(probe.recovered_pixels, 800, sentinel),
		u32(0xF0D0_99D4),
	)
}

@(test)
graphics_frame_consumer_test_missing_legacy_shadow_requests_one_full_baseline :: proc(
	t: ^testing.T,
) {
	video := new(Video_Presentation)
	defer {
		frame_mailbox_destroy(video)
		free(video)
	}
	lifecycle := frame_mailbox_lifecycle_generation(video)
	target: host.Host
	if !testing.expect(t, host.host_presentation_start(&target, lifecycle)) {return}
	defer host.host_presentation_stop(&target)
	probe := Graphics_Frame_Consumer_Test_Stage_Probe {
		mailbox         = video,
		next_texture    = 290,
		needs_full_kind = .Legacy,
	}
	ops := Graphics_Frame_Consumer_Ops {
		ctx           = &probe,
		expand_legacy = graphics_frame_consumer_test_expand_legacy,
		stage         = graphics_frame_consumer_test_stage,
	}
	partial, reserved := frame_mailbox_begin(video, 10)
	if !testing.expect(t, reserved) {return}
	partial.scanout.generation = 10
	partial.scanout.legacy_update = graphics_frame_consumer_test_legacy_update(10, lifecycle)
	partial.scanout.capture_plan = {
		coverage           = .Partial,
		owner              = .Legacy,
		owner_generation   = lifecycle,
		mode_generation    = partial.scanout.legacy_update.header.mode_generation,
		surface_id         = partial.scanout.legacy_update.header.surface.id,
		surface_generation = partial.scanout.legacy_update.header.surface.generation,
	}
	if !testing.expect(t, frame_mailbox_commit(video, partial, true)) {return}
	checkpoint: time.Tick
	consumed := graphics_frame_consume(video, &target, false, &checkpoint, &ops)
	testing.expect(t, !consumed.graphics_epoch_pending)
	testing.expect_value(t, partial.epoch.result, Graphics_Frame_Result.Superseded)
	_, legacy_ack_valid := frame_mailbox_take_legacy_ack(video)
	testing.expect(t, !legacy_ack_valid)
	request := frame_mailbox_test_baseline_snapshot(video)
	if !testing.expect(t, request.valid) {return}
	testing.expect(t, !request.issued)
	testing.expect_value(t, request.mode_generation, u64(1))

	probe.needs_full_kind = .Invalid
	full, full_reserved := frame_mailbox_begin(video, 11)
	if !testing.expect(t, full_reserved) {return}
	full.scanout.generation = 11
	full.scanout.legacy_update = graphics_frame_consumer_test_legacy_update(11, lifecycle)
	full.scanout.capture_plan = partial.scanout.capture_plan
	full.scanout.capture_plan.coverage = .Full
	if !testing.expect(t, frame_mailbox_commit(video, full, true)) {return}
	recovered := graphics_frame_consume(video, &target, false, &checkpoint, &ops)
	testing.expect(t, recovered.graphics_epoch_pending)
	testing.expect(t, !frame_mailbox_test_baseline_snapshot(video).valid)
	ack, ack_valid := frame_mailbox_take_legacy_ack(video)
	testing.expect(t, ack_valid)
	testing.expect_value(t, ack.sequence, u64(11))
}

@(test)
graphics_frame_consumer_test_reset_after_gsw_commit_clears_pending_epoch_and_acks :: proc(
	t: ^testing.T,
) {
	video := new(Video_Presentation)
	defer {
		frame_mailbox_destroy(video)
		free(video)
	}
	lifecycle := frame_mailbox_lifecycle_generation(video)
	target: host.Host
	if !testing.expect(t, host.host_presentation_start(&target, lifecycle)) {return}
	defer host.host_presentation_stop(&target)
	probe := Graphics_Frame_Consumer_Test_Stage_Probe {
		mailbox      = video,
		next_texture = 300,
	}
	if !graphics_frame_consumer_test_seed_legacy(t, &target, lifecycle, &probe) {return}
	probe.reset_on_legacy = true
	ops := Graphics_Frame_Consumer_Ops {
		ctx           = &probe,
		expand_legacy = graphics_frame_consumer_test_expand_legacy,
		expand_gsw    = graphics_frame_consumer_test_expand_gsw,
		stage         = graphics_frame_consumer_test_stage,
	}
	slot, reserved := frame_mailbox_begin(video, 11)
	if !testing.expect(t, reserved) {return}
	graphics_frame_consumer_test_prepare_combined(slot, lifecycle, 10, 11)
	if !testing.expect(t, frame_mailbox_commit(video, slot, true)) {return}
	checkpoint: time.Tick
	consumed := graphics_frame_consume(video, &target, false, &checkpoint, &ops)
	testing.expect(t, !consumed.graphics_epoch_pending)
	testing.expect_value(t, probe.order_count, 2)
	_, legacy_ack_valid := frame_mailbox_take_legacy_ack(video)
	_, gsw_ack_valid := frame_mailbox_take_gsw_ack(video)
	testing.expect(t, !legacy_ack_valid)
	testing.expect(t, !gsw_ack_valid)
}

@(test)
graphics_frame_consumer_test_exact_stale_gsw_duplicate_requeues_ack :: proc(t: ^testing.T) {
	video := new(Video_Presentation)
	defer {
		frame_mailbox_destroy(video)
		free(video)
	}
	lifecycle := frame_mailbox_lifecycle_generation(video)
	present := graphics_frame_consumer_test_gsw_present(10, lifecycle, 2)
	if !testing.expect(t, frame_mailbox_note_gsw_applied(video, present)) {return}
	_, pending := frame_mailbox_take_gsw_ack(video)
	if !testing.expect(t, pending) {return}
	target: host.Host
	if !testing.expect(t, host.host_presentation_start(&target, lifecycle)) {return}
	defer host.host_presentation_stop(&target)
	target.presentation_state.last_vga_sequence = 10
	probe := Graphics_Frame_Consumer_Test_Stage_Probe {
		mailbox   = video,
		fail_kind = .Legacy,
	}
	ops := Graphics_Frame_Consumer_Ops {
		ctx           = &probe,
		expand_legacy = graphics_frame_consumer_test_expand_legacy,
		expand_gsw    = graphics_frame_consumer_test_expand_gsw,
		stage         = graphics_frame_consumer_test_stage,
	}
	slot, reserved := frame_mailbox_begin(video, 11)
	if !testing.expect(t, reserved) {return}
	graphics_frame_consumer_test_prepare_combined(slot, lifecycle, 10, 11)
	if !testing.expect(t, frame_mailbox_commit(video, slot, true)) {return}
	checkpoint: time.Tick
	_ = graphics_frame_consume(video, &target, false, &checkpoint, &ops)
	reissued, reissued_valid := frame_mailbox_take_gsw_ack(video)
	testing.expect(t, reissued_valid)
	testing.expect_value(t, reissued.sequence, u64(10))
}

@(test)
graphics_frame_consumer_test_single_exact_stale_gsw_duplicate_is_superseded :: proc(
	t: ^testing.T,
) {
	video := new(Video_Presentation)
	defer {
		frame_mailbox_destroy(video)
		free(video)
	}
	lifecycle := frame_mailbox_lifecycle_generation(video)
	present := graphics_frame_consumer_test_gsw_present(10, lifecycle, 2)
	if !testing.expect(t, frame_mailbox_note_gsw_applied(video, present)) {return}
	_, pending := frame_mailbox_take_gsw_ack(video)
	if !testing.expect(t, pending) {return}
	target: host.Host
	if !testing.expect(t, host.host_presentation_start(&target, lifecycle)) {return}
	defer host.host_presentation_stop(&target)
	target.presentation_state.last_vga_sequence = 10
	slot, reserved := frame_mailbox_begin(video, 10)
	if !testing.expect(t, reserved) {return}
	slot.scanout.generation = 10
	slot.scanout.gsw_presentation.present = present
	slot.scanout.gsw_presentation.present_valid = true
	slot.scanout.gsw_presentation.source = make([]u8, 4)
	if !testing.expect(t, frame_mailbox_commit(video, slot, true)) {return}
	checkpoint: time.Tick
	consumed := graphics_frame_consume(video, &target, false, &checkpoint)
	testing.expect(t, !consumed.graphics_epoch_pending)
	testing.expect_value(t, slot.epoch.result, Graphics_Frame_Result.Superseded)
	reissued, reissued_valid := frame_mailbox_take_gsw_ack(video)
	testing.expect(t, reissued_valid)
	testing.expect_value(t, reissued.sequence, u64(10))
}

@(test)
graphics_frame_consumer_test_closed_host_does_not_skip_exact_committed_gsw :: proc(t: ^testing.T) {
	video := new(Video_Presentation)
	defer {
		frame_mailbox_destroy(video)
		free(video)
	}
	lifecycle := frame_mailbox_lifecycle_generation(video)
	present := graphics_frame_consumer_test_gsw_present(10, lifecycle, 2)
	if !testing.expect(t, frame_mailbox_note_gsw_applied(video, present)) {return}
	_, pending := frame_mailbox_take_gsw_ack(video)
	if !testing.expect(t, pending) {return}
	target: host.Host
	slot, reserved := frame_mailbox_begin(video, 11)
	if !testing.expect(t, reserved) {return}
	graphics_frame_consumer_test_prepare_combined(slot, lifecycle, 10, 11)
	if !testing.expect(t, frame_mailbox_commit(video, slot, true)) {return}
	checkpoint: time.Tick
	consumed := graphics_frame_consume(video, &target, false, &checkpoint)
	testing.expect(t, !consumed.graphics_epoch_pending)
	testing.expect_value(t, target.presentation_state.sequence, u64(0))
	testing.expect_value(t, slot.epoch.result, Graphics_Frame_Result.Render_Failed)
	_, legacy_ack_valid := frame_mailbox_take_legacy_ack(video)
	_, gsw_ack_valid := frame_mailbox_take_gsw_ack(video)
	testing.expect(t, !legacy_ack_valid)
	testing.expect(t, !gsw_ack_valid)
	_, retry_reserved := frame_mailbox_begin(video, 11)
	testing.expect(t, !retry_reserved)
}

@(test)
graphics_frame_consumer_test_wrong_host_lifecycle_does_not_skip_exact_committed_gsw :: proc(
	t: ^testing.T,
) {
	video := new(Video_Presentation)
	defer {
		frame_mailbox_destroy(video)
		free(video)
	}
	lifecycle := frame_mailbox_lifecycle_generation(video)
	present := graphics_frame_consumer_test_gsw_present(10, lifecycle, 2)
	if !testing.expect(t, frame_mailbox_note_gsw_applied(video, present)) {return}
	_, pending := frame_mailbox_take_gsw_ack(video)
	if !testing.expect(t, pending) {return}
	target: host.Host
	if !testing.expect(t, host.host_presentation_start(&target, lifecycle + 1)) {return}
	defer host.host_presentation_stop(&target)
	slot, reserved := frame_mailbox_begin(video, 11)
	if !testing.expect(t, reserved) {return}
	graphics_frame_consumer_test_prepare_combined(slot, lifecycle, 10, 11)
	if !testing.expect(t, frame_mailbox_commit(video, slot, true)) {return}
	checkpoint: time.Tick
	consumed := graphics_frame_consume(video, &target, false, &checkpoint)
	testing.expect(t, !consumed.graphics_epoch_pending)
	testing.expect_value(t, slot.epoch.result, Graphics_Frame_Result.Render_Failed)
	_, gsw_ack_valid := frame_mailbox_take_gsw_ack(video)
	testing.expect(t, !gsw_ack_valid)
}
