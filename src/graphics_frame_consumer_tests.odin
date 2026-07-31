// SPDX-License-Identifier: GPL-3.0-only
package main

import "core:testing"
import "core:time"
import "host"
import presentation "presentation"
import sdl3 "vendor:sdl3"
import "vga"

Graphics_Frame_Consumer_Test_Stage_Probe :: struct {
	mailbox:         ^Frame_Mailbox,
	order:           [4]host.Host_Presentation_Kind,
	order_count:     int,
	next_texture:    uintptr,
	fail_kind:       host.Host_Presentation_Kind,
	reset_on_legacy: bool,
}

graphics_frame_consumer_test_stage :: proc(
	ctx: rawptr,
	target: ^host.Host,
	admission: ^host.Host_Presentation_Admission,
	frame: ^vga.Display_Frame,
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
				surface_extent = extent,
				canvas_extent = extent,
				source = full,
				destination = full,
			},
			surface = {1, surface_generation},
			format = .Bgra_8888,
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
				surface_extent = extent,
				canvas_extent = extent,
				source = full,
				destination = full,
			},
			identity_namespace = .Gsw2d,
			device_generation = 1,
			surface = {2, 1},
			format = .Bgrx_8888,
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
	slot.scanout.frame_pixels = make([]u32, 1)
	slot.scanout.frame_pixels[0] = 0xFF112233
	slot.scanout.preconverted = true
	slot.scanout.frame = {
		kind           = .Xrgb_8888,
		width          = 1,
		height         = 1,
		pixels         = slot.scanout.frame_pixels,
		dirty          = slot.scanout.legacy_update.header.dirty,
		updated_pixels = 1,
	}
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
	staged := graphics_frame_consumer_test_stage(probe, target, &admission, &frame)
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
graphics_frame_consumer_test_single_legacy_commits_and_acks_only_legacy :: proc(
	t: ^testing.T,
) {
	shared := new(Shared)
	defer {
		frame_mailbox_destroy(&shared.frames)
		free(shared)
	}
	lifecycle := frame_mailbox_lifecycle_generation(&shared.frames)
	target: host.Host
	if !testing.expect(t, host.host_presentation_start(&target, lifecycle)) {return}
	defer host.host_presentation_stop(&target)
	probe := Graphics_Frame_Consumer_Test_Stage_Probe {
		mailbox      = &shared.frames,
		next_texture = 50,
	}
	ops := Graphics_Frame_Consumer_Ops {
		ctx   = &probe,
		stage = graphics_frame_consumer_test_stage,
	}
	slot, reserved := frame_mailbox_begin(&shared.frames, 10)
	if !testing.expect(t, reserved) {return}
	graphics_frame_consumer_test_prepare_combined(slot, lifecycle, 11, 10)
	slot.scanout.gsw_presentation.present_valid = false
	slot.scanout.generation = 10
	if !testing.expect(t, frame_mailbox_commit(&shared.frames, slot, true)) {return}
	checkpoint: time.Tick
	consumed := graphics_frame_consume(shared, &target, false, &checkpoint, &ops)
	testing.expect(t, consumed.graphics_epoch_pending)
	testing.expect_value(t, consumed.graphics_epoch.source, Graphics_Frame_Source.Legacy_Scanout)
	testing.expect_value(t, probe.order_count, 1)
	testing.expect_value(t, probe.order[0], host.Host_Presentation_Kind.Legacy)
	testing.expect_value(
		t,
		target.presentation_state.selector.active.kind,
		presentation.Active_Kind.Legacy,
	)
	legacy_ack, legacy_ack_valid := frame_mailbox_take_legacy_ack(&shared.frames)
	_, gsw_ack_valid := frame_mailbox_take_gsw_ack(&shared.frames)
	testing.expect(t, legacy_ack_valid)
	testing.expect_value(t, legacy_ack.sequence, u64(10))
	testing.expect(t, !gsw_ack_valid)
}

@(test)
graphics_frame_consumer_test_single_gsw_commits_and_acks_only_gsw :: proc(t: ^testing.T) {
	shared := new(Shared)
	defer {
		frame_mailbox_destroy(&shared.frames)
		free(shared)
	}
	lifecycle := frame_mailbox_lifecycle_generation(&shared.frames)
	target: host.Host
	if !testing.expect(t, host.host_presentation_start(&target, lifecycle)) {return}
	defer host.host_presentation_stop(&target)
	probe := Graphics_Frame_Consumer_Test_Stage_Probe {
		mailbox      = &shared.frames,
		next_texture = 75,
	}
	ops := Graphics_Frame_Consumer_Ops {
		ctx   = &probe,
		stage = graphics_frame_consumer_test_stage,
	}
	slot, reserved := frame_mailbox_begin(&shared.frames, 10)
	if !testing.expect(t, reserved) {return}
	graphics_frame_consumer_test_prepare_combined(slot, lifecycle, 10, 0)
	slot.scanout.generation = 10
	if !testing.expect(t, frame_mailbox_commit(&shared.frames, slot, true)) {return}
	checkpoint: time.Tick
	consumed := graphics_frame_consume(shared, &target, false, &checkpoint, &ops)
	testing.expect(t, consumed.graphics_epoch_pending)
	testing.expect_value(t, consumed.graphics_epoch.source, Graphics_Frame_Source.Gsw2d)
	testing.expect_value(t, probe.order_count, 1)
	testing.expect_value(t, probe.order[0], host.Host_Presentation_Kind.Gsw_Snapshot)
	testing.expect_value(
		t,
		target.presentation_state.selector.active.kind,
		presentation.Active_Kind.Gsw,
	)
	gsw_ack, gsw_ack_valid := frame_mailbox_take_gsw_ack(&shared.frames)
	_, legacy_ack_valid := frame_mailbox_take_legacy_ack(&shared.frames)
	testing.expect(t, gsw_ack_valid)
	testing.expect_value(t, gsw_ack.sequence, u64(10))
	testing.expect(t, !legacy_ack_valid)
}

graphics_frame_consumer_test_reject_invalid_pair_order :: proc(
	t: ^testing.T,
	legacy_sequence, gsw_sequence: u64,
) {
	shared := new(Shared)
	defer {
		frame_mailbox_destroy(&shared.frames)
		free(shared)
	}
	lifecycle := frame_mailbox_lifecycle_generation(&shared.frames)
	target: host.Host
	if !testing.expect(t, host.host_presentation_start(&target, lifecycle)) {return}
	defer host.host_presentation_stop(&target)
	slot, reserved := frame_mailbox_begin(&shared.frames, legacy_sequence)
	if !testing.expect(t, reserved) {return}
	slot.scanout.generation = legacy_sequence
	slot.scanout.legacy_update.header.sequence = legacy_sequence
	slot.scanout.gsw_presentation.present_valid = true
	slot.scanout.gsw_presentation.present.header.sequence = gsw_sequence
	if !testing.expect(t, frame_mailbox_commit(&shared.frames, slot, true)) {return}
	checkpoint: time.Tick
	consumed := graphics_frame_consume(shared, &target, false, &checkpoint)
	testing.expect(t, !consumed.graphics_epoch_pending)
	testing.expect_value(t, target.presentation_state.sequence, u64(0))
	_, legacy_ack_valid := frame_mailbox_take_legacy_ack(&shared.frames)
	_, gsw_ack_valid := frame_mailbox_take_gsw_ack(&shared.frames)
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
	shared := new(Shared)
	defer {
		frame_mailbox_destroy(&shared.frames)
		free(shared)
	}
	lifecycle := frame_mailbox_lifecycle_generation(&shared.frames)
	target: host.Host
	if !testing.expect(t, host.host_presentation_start(&target, lifecycle)) {return}
	defer host.host_presentation_stop(&target)
	slot, reserved := frame_mailbox_begin(&shared.frames, 7)
	if !testing.expect(t, reserved) {return}
	slot.scanout.generation = 7
	slot.scanout.legacy_update = graphics_frame_consumer_test_legacy_update(7, lifecycle)
	if !testing.expect(t, frame_mailbox_commit(&shared.frames, slot, true)) {return}
	checkpoint: time.Tick
	consumed := graphics_frame_consume(shared, &target, false, &checkpoint)
	testing.expect(t, !consumed.graphics_epoch_pending)
	_, ack_valid := frame_mailbox_take_legacy_ack(&shared.frames)
	testing.expect(t, !ack_valid)

	retry, retry_reserved := frame_mailbox_begin(&shared.frames, 7)
	if !testing.expect(t, retry_reserved) {return}
	_ = frame_mailbox_commit(&shared.frames, retry, false)
}

@(test)
graphics_frame_consumer_test_older_gsw_failure_blocks_later_legacy_and_acks_neither :: proc(
	t: ^testing.T,
) {
	shared := new(Shared)
	defer {
		frame_mailbox_destroy(&shared.frames)
		free(shared)
	}
	lifecycle := frame_mailbox_lifecycle_generation(&shared.frames)
	target: host.Host
	if !testing.expect(t, host.host_presentation_start(&target, lifecycle)) {return}
	defer host.host_presentation_stop(&target)
	slot, reserved := frame_mailbox_begin(&shared.frames, 11)
	if !testing.expect(t, reserved) {return}
	slot.scanout.generation = 11
	slot.scanout.legacy_update = graphics_frame_consumer_test_legacy_update(11, lifecycle)
	slot.scanout.gsw_presentation.present_valid = true
	slot.scanout.gsw_presentation.present.header = {
		sequence             = 10,
		lifecycle_generation = lifecycle,
	}
	if !testing.expect(t, frame_mailbox_commit(&shared.frames, slot, true)) {return}
	checkpoint: time.Tick
	consumed := graphics_frame_consume(shared, &target, false, &checkpoint)
	testing.expect(t, !consumed.graphics_epoch_pending)
	testing.expect_value(t, target.presentation_state.sequence, u64(0))
	_, legacy_ack_valid := frame_mailbox_take_legacy_ack(&shared.frames)
	_, gsw_ack_valid := frame_mailbox_take_gsw_ack(&shared.frames)
	testing.expect(t, !legacy_ack_valid)
	testing.expect(t, !gsw_ack_valid)

	_, retry_reserved := frame_mailbox_begin(&shared.frames, 11)
	testing.expect(t, !retry_reserved)
}

@(test)
graphics_frame_consumer_test_gsw_then_hidden_legacy_commits_and_acks_in_order :: proc(
	t: ^testing.T,
) {
	shared := new(Shared)
	defer {
		frame_mailbox_destroy(&shared.frames)
		free(shared)
	}
	lifecycle := frame_mailbox_lifecycle_generation(&shared.frames)
	target: host.Host
	if !testing.expect(t, host.host_presentation_start(&target, lifecycle)) {return}
	defer host.host_presentation_stop(&target)
	probe := Graphics_Frame_Consumer_Test_Stage_Probe {
		mailbox      = &shared.frames,
		next_texture = 100,
	}
	if !graphics_frame_consumer_test_seed_legacy(
		t,
		&target,
		lifecycle,
		&probe,
		{2, 2},
	) {return}
	ops := Graphics_Frame_Consumer_Ops {
		ctx   = &probe,
		stage = graphics_frame_consumer_test_stage,
	}
	slot, reserved := frame_mailbox_begin(&shared.frames, 11)
	if !testing.expect(t, reserved) {return}
	graphics_frame_consumer_test_prepare_combined(slot, lifecycle, 10, 11)
	slot.scanout.frame.kind = .Rgb_565
	if !testing.expect(t, frame_mailbox_commit(&shared.frames, slot, true)) {return}
	checkpoint: time.Tick
	consumed := graphics_frame_consume(shared, &target, false, &checkpoint, &ops)
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
	gsw_ack, gsw_ack_valid := frame_mailbox_take_gsw_ack(&shared.frames)
	legacy_ack, legacy_ack_valid := frame_mailbox_take_legacy_ack(&shared.frames)
	testing.expect(t, gsw_ack_valid)
	testing.expect(t, legacy_ack_valid)
	testing.expect_value(t, gsw_ack.sequence, u64(10))
	testing.expect_value(t, legacy_ack.sequence, u64(11))
}

@(test)
graphics_frame_consumer_test_first_gsw_stage_failure_blocks_legacy_and_retries :: proc(
	t: ^testing.T,
) {
	shared := new(Shared)
	defer {
		frame_mailbox_destroy(&shared.frames)
		free(shared)
	}
	lifecycle := frame_mailbox_lifecycle_generation(&shared.frames)
	target: host.Host
	if !testing.expect(t, host.host_presentation_start(&target, lifecycle)) {return}
	defer host.host_presentation_stop(&target)
	probe := Graphics_Frame_Consumer_Test_Stage_Probe {
		mailbox      = &shared.frames,
		next_texture = 200,
	}
	if !graphics_frame_consumer_test_seed_legacy(t, &target, lifecycle, &probe) {return}
	probe.fail_kind = .Gsw_Snapshot
	ops := Graphics_Frame_Consumer_Ops {
		ctx   = &probe,
		stage = graphics_frame_consumer_test_stage,
	}
	slot, reserved := frame_mailbox_begin(&shared.frames, 11)
	if !testing.expect(t, reserved) {return}
	graphics_frame_consumer_test_prepare_combined(slot, lifecycle, 10, 11)
	if !testing.expect(t, frame_mailbox_commit(&shared.frames, slot, true)) {return}
	checkpoint: time.Tick
	consumed := graphics_frame_consume(shared, &target, false, &checkpoint, &ops)
	testing.expect(t, !consumed.graphics_epoch_pending)
	testing.expect_value(t, probe.order_count, 1)
	testing.expect_value(t, probe.order[0], host.Host_Presentation_Kind.Gsw_Snapshot)
	testing.expect_value(
		t,
		target.presentation_state.selector.active.kind,
		presentation.Active_Kind.Legacy,
	)
	_, legacy_ack_valid := frame_mailbox_take_legacy_ack(&shared.frames)
	_, gsw_ack_valid := frame_mailbox_take_gsw_ack(&shared.frames)
	testing.expect(t, !legacy_ack_valid)
	testing.expect(t, !gsw_ack_valid)
	retry, retry_reserved := frame_mailbox_begin(&shared.frames, 11)
	if !testing.expect(t, retry_reserved) {return}
	_ = frame_mailbox_commit(&shared.frames, retry, false)
}

@(test)
graphics_frame_consumer_test_legacy_then_gsw_commits_and_acks_in_order :: proc(t: ^testing.T) {
	shared := new(Shared)
	defer {
		frame_mailbox_destroy(&shared.frames)
		free(shared)
	}
	lifecycle := frame_mailbox_lifecycle_generation(&shared.frames)
	target: host.Host
	if !testing.expect(t, host.host_presentation_start(&target, lifecycle)) {return}
	defer host.host_presentation_stop(&target)
	probe := Graphics_Frame_Consumer_Test_Stage_Probe {
		mailbox      = &shared.frames,
		next_texture = 250,
	}
	if !graphics_frame_consumer_test_seed_legacy(t, &target, lifecycle, &probe) {return}
	ops := Graphics_Frame_Consumer_Ops {
		ctx   = &probe,
		stage = graphics_frame_consumer_test_stage,
	}
	slot, reserved := frame_mailbox_begin(&shared.frames, 11)
	if !testing.expect(t, reserved) {return}
	graphics_frame_consumer_test_prepare_combined(slot, lifecycle, 11, 10)
	slot.scanout.legacy_update.header.mode_generation = 1
	if !testing.expect(t, frame_mailbox_commit(&shared.frames, slot, true)) {return}
	checkpoint: time.Tick
	consumed := graphics_frame_consume(shared, &target, false, &checkpoint, &ops)
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
	legacy_ack, legacy_ack_valid := frame_mailbox_take_legacy_ack(&shared.frames)
	gsw_ack, gsw_ack_valid := frame_mailbox_take_gsw_ack(&shared.frames)
	testing.expect(t, legacy_ack_valid)
	testing.expect(t, gsw_ack_valid)
	testing.expect_value(t, legacy_ack.sequence, u64(10))
	testing.expect_value(t, gsw_ack.sequence, u64(11))
}

@(test)
graphics_frame_consumer_test_first_legacy_stage_failure_blocks_gsw_and_retries :: proc(
	t: ^testing.T,
) {
	shared := new(Shared)
	defer {
		frame_mailbox_destroy(&shared.frames)
		free(shared)
	}
	lifecycle := frame_mailbox_lifecycle_generation(&shared.frames)
	target: host.Host
	if !testing.expect(t, host.host_presentation_start(&target, lifecycle)) {return}
	defer host.host_presentation_stop(&target)
	probe := Graphics_Frame_Consumer_Test_Stage_Probe {
		mailbox      = &shared.frames,
		next_texture = 275,
	}
	if !graphics_frame_consumer_test_seed_legacy(t, &target, lifecycle, &probe) {return}
	probe.fail_kind = .Legacy
	ops := Graphics_Frame_Consumer_Ops {
		ctx   = &probe,
		stage = graphics_frame_consumer_test_stage,
	}
	slot, reserved := frame_mailbox_begin(&shared.frames, 11)
	if !testing.expect(t, reserved) {return}
	graphics_frame_consumer_test_prepare_combined(slot, lifecycle, 11, 10)
	slot.scanout.legacy_update.header.mode_generation = 1
	if !testing.expect(t, frame_mailbox_commit(&shared.frames, slot, true)) {return}
	checkpoint: time.Tick
	consumed := graphics_frame_consume(shared, &target, false, &checkpoint, &ops)
	testing.expect(t, !consumed.graphics_epoch_pending)
	testing.expect_value(t, probe.order_count, 1)
	testing.expect_value(t, probe.order[0], host.Host_Presentation_Kind.Legacy)
	testing.expect_value(
		t,
		target.presentation_state.selector.active.kind,
		presentation.Active_Kind.Legacy,
	)
	_, legacy_ack_valid := frame_mailbox_take_legacy_ack(&shared.frames)
	_, gsw_ack_valid := frame_mailbox_take_gsw_ack(&shared.frames)
	testing.expect(t, !legacy_ack_valid)
	testing.expect(t, !gsw_ack_valid)
	retry, retry_reserved := frame_mailbox_begin(&shared.frames, 11)
	if !testing.expect(t, retry_reserved) {return}
	_ = frame_mailbox_commit(&shared.frames, retry, false)
}

@(test)
graphics_frame_consumer_test_reset_after_gsw_commit_clears_pending_epoch_and_acks :: proc(
	t: ^testing.T,
) {
	shared := new(Shared)
	defer {
		frame_mailbox_destroy(&shared.frames)
		free(shared)
	}
	lifecycle := frame_mailbox_lifecycle_generation(&shared.frames)
	target: host.Host
	if !testing.expect(t, host.host_presentation_start(&target, lifecycle)) {return}
	defer host.host_presentation_stop(&target)
	probe := Graphics_Frame_Consumer_Test_Stage_Probe {
		mailbox      = &shared.frames,
		next_texture = 300,
	}
	if !graphics_frame_consumer_test_seed_legacy(t, &target, lifecycle, &probe) {return}
	probe.reset_on_legacy = true
	ops := Graphics_Frame_Consumer_Ops {
		ctx   = &probe,
		stage = graphics_frame_consumer_test_stage,
	}
	slot, reserved := frame_mailbox_begin(&shared.frames, 11)
	if !testing.expect(t, reserved) {return}
	graphics_frame_consumer_test_prepare_combined(slot, lifecycle, 10, 11)
	if !testing.expect(t, frame_mailbox_commit(&shared.frames, slot, true)) {return}
	checkpoint: time.Tick
	consumed := graphics_frame_consume(shared, &target, false, &checkpoint, &ops)
	testing.expect(t, !consumed.graphics_epoch_pending)
	testing.expect_value(t, probe.order_count, 2)
	_, legacy_ack_valid := frame_mailbox_take_legacy_ack(&shared.frames)
	_, gsw_ack_valid := frame_mailbox_take_gsw_ack(&shared.frames)
	testing.expect(t, !legacy_ack_valid)
	testing.expect(t, !gsw_ack_valid)
}

@(test)
graphics_frame_consumer_test_exact_stale_gsw_duplicate_requeues_ack :: proc(t: ^testing.T) {
	shared := new(Shared)
	defer {
		frame_mailbox_destroy(&shared.frames)
		free(shared)
	}
	lifecycle := frame_mailbox_lifecycle_generation(&shared.frames)
	present := graphics_frame_consumer_test_gsw_present(10, lifecycle, 2)
	if !testing.expect(t, frame_mailbox_note_gsw_applied(&shared.frames, present)) {return}
	_, pending := frame_mailbox_take_gsw_ack(&shared.frames)
	if !testing.expect(t, pending) {return}
	target: host.Host
	if !testing.expect(t, host.host_presentation_start(&target, lifecycle)) {return}
	defer host.host_presentation_stop(&target)
	target.presentation_state.last_vga_sequence = 10
	probe := Graphics_Frame_Consumer_Test_Stage_Probe {
		mailbox   = &shared.frames,
		fail_kind = .Legacy,
	}
	ops := Graphics_Frame_Consumer_Ops {
		ctx   = &probe,
		stage = graphics_frame_consumer_test_stage,
	}
	slot, reserved := frame_mailbox_begin(&shared.frames, 11)
	if !testing.expect(t, reserved) {return}
	graphics_frame_consumer_test_prepare_combined(slot, lifecycle, 10, 11)
	if !testing.expect(t, frame_mailbox_commit(&shared.frames, slot, true)) {return}
	checkpoint: time.Tick
	_ = graphics_frame_consume(shared, &target, false, &checkpoint, &ops)
	reissued, reissued_valid := frame_mailbox_take_gsw_ack(&shared.frames)
	testing.expect(t, reissued_valid)
	testing.expect_value(t, reissued.sequence, u64(10))
}

@(test)
graphics_frame_consumer_test_single_exact_stale_gsw_duplicate_is_superseded :: proc(
	t: ^testing.T,
) {
	shared := new(Shared)
	defer {
		frame_mailbox_destroy(&shared.frames)
		free(shared)
	}
	lifecycle := frame_mailbox_lifecycle_generation(&shared.frames)
	present := graphics_frame_consumer_test_gsw_present(10, lifecycle, 2)
	if !testing.expect(t, frame_mailbox_note_gsw_applied(&shared.frames, present)) {return}
	_, pending := frame_mailbox_take_gsw_ack(&shared.frames)
	if !testing.expect(t, pending) {return}
	target: host.Host
	if !testing.expect(t, host.host_presentation_start(&target, lifecycle)) {return}
	defer host.host_presentation_stop(&target)
	target.presentation_state.last_vga_sequence = 10
	slot, reserved := frame_mailbox_begin(&shared.frames, 10)
	if !testing.expect(t, reserved) {return}
	slot.scanout.generation = 10
	slot.scanout.gsw_presentation.present = present
	slot.scanout.gsw_presentation.present_valid = true
	slot.scanout.gsw_presentation.source = make([]u8, 4)
	if !testing.expect(t, frame_mailbox_commit(&shared.frames, slot, true)) {return}
	checkpoint: time.Tick
	consumed := graphics_frame_consume(shared, &target, false, &checkpoint)
	testing.expect(t, !consumed.graphics_epoch_pending)
	testing.expect_value(t, slot.epoch.result, Graphics_Frame_Result.Superseded)
	reissued, reissued_valid := frame_mailbox_take_gsw_ack(&shared.frames)
	testing.expect(t, reissued_valid)
	testing.expect_value(t, reissued.sequence, u64(10))
}

@(test)
graphics_frame_consumer_test_closed_host_does_not_skip_exact_committed_gsw :: proc(t: ^testing.T) {
	shared := new(Shared)
	defer {
		frame_mailbox_destroy(&shared.frames)
		free(shared)
	}
	lifecycle := frame_mailbox_lifecycle_generation(&shared.frames)
	present := graphics_frame_consumer_test_gsw_present(10, lifecycle, 2)
	if !testing.expect(t, frame_mailbox_note_gsw_applied(&shared.frames, present)) {return}
	_, pending := frame_mailbox_take_gsw_ack(&shared.frames)
	if !testing.expect(t, pending) {return}
	target: host.Host
	slot, reserved := frame_mailbox_begin(&shared.frames, 11)
	if !testing.expect(t, reserved) {return}
	graphics_frame_consumer_test_prepare_combined(slot, lifecycle, 10, 11)
	if !testing.expect(t, frame_mailbox_commit(&shared.frames, slot, true)) {return}
	checkpoint: time.Tick
	consumed := graphics_frame_consume(shared, &target, false, &checkpoint)
	testing.expect(t, !consumed.graphics_epoch_pending)
	testing.expect_value(t, target.presentation_state.sequence, u64(0))
	testing.expect_value(t, slot.epoch.result, Graphics_Frame_Result.Render_Failed)
	_, legacy_ack_valid := frame_mailbox_take_legacy_ack(&shared.frames)
	_, gsw_ack_valid := frame_mailbox_take_gsw_ack(&shared.frames)
	testing.expect(t, !legacy_ack_valid)
	testing.expect(t, !gsw_ack_valid)
	_, retry_reserved := frame_mailbox_begin(&shared.frames, 11)
	testing.expect(t, !retry_reserved)
}

@(test)
graphics_frame_consumer_test_wrong_host_lifecycle_does_not_skip_exact_committed_gsw :: proc(
	t: ^testing.T,
) {
	shared := new(Shared)
	defer {
		frame_mailbox_destroy(&shared.frames)
		free(shared)
	}
	lifecycle := frame_mailbox_lifecycle_generation(&shared.frames)
	present := graphics_frame_consumer_test_gsw_present(10, lifecycle, 2)
	if !testing.expect(t, frame_mailbox_note_gsw_applied(&shared.frames, present)) {return}
	_, pending := frame_mailbox_take_gsw_ack(&shared.frames)
	if !testing.expect(t, pending) {return}
	target: host.Host
	if !testing.expect(t, host.host_presentation_start(&target, lifecycle + 1)) {return}
	defer host.host_presentation_stop(&target)
	slot, reserved := frame_mailbox_begin(&shared.frames, 11)
	if !testing.expect(t, reserved) {return}
	graphics_frame_consumer_test_prepare_combined(slot, lifecycle, 10, 11)
	if !testing.expect(t, frame_mailbox_commit(&shared.frames, slot, true)) {return}
	checkpoint: time.Tick
	consumed := graphics_frame_consume(shared, &target, false, &checkpoint)
	testing.expect(t, !consumed.graphics_epoch_pending)
	testing.expect_value(t, slot.epoch.result, Graphics_Frame_Result.Render_Failed)
	_, gsw_ack_valid := frame_mailbox_take_gsw_ack(&shared.frames)
	testing.expect(t, !gsw_ack_valid)
}
