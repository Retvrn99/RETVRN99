// SPDX-License-Identifier: GPL-3.0-only
package main

import "core:testing"
import "core:time"
import host "host"
import "machine"
import contract "presentation"
import vga "vga"

Frame_Mailbox_Test_Current_Commit :: struct {
	calls:  int,
	result: bool,
}

frame_mailbox_test_current_commit :: proc(ctx: rawptr) -> bool {
	commit := (^Frame_Mailbox_Test_Current_Commit)(ctx)
	if commit == nil {return false}
	commit.calls += 1
	return commit.result
}

frame_mailbox_test_publish_generation :: proc(mailbox: ^Frame_Mailbox, generation: u64) -> bool {
	slot, reserved := frame_mailbox_begin(mailbox, generation)
	if !reserved {return false}
	slot.scanout.generation = generation
	return frame_mailbox_commit(mailbox, slot, true)
}

@(test)
frame_mailbox_test_legacy_ack_is_lifecycle_bound_and_single_use :: proc(t: ^testing.T) {
	mailbox: Frame_Mailbox
	defer frame_mailbox_destroy(&mailbox)
	lifecycle := frame_mailbox_lifecycle_generation(&mailbox)
	update := contract.Legacy_Frame_Update {
		header = {
			sequence = 7,
			lifecycle_generation = lifecycle,
			mode_generation = 3,
			surface = {id = 1, generation = 5},
		},
	}
	testing.expect(t, frame_mailbox_note_legacy_applied(&mailbox, update))
	testing.expect(t, frame_mailbox_legacy_was_committed(&mailbox, update))
	mutated := update
	mutated.full_reason = .External_Tracking
	testing.expect(t, !frame_mailbox_legacy_was_committed(&mailbox, mutated))
	ack, valid := frame_mailbox_take_legacy_ack(&mailbox)
	testing.expect(t, valid)
	testing.expect_value(t, ack.sequence, update.header.sequence)
	testing.expect_value(t, ack.mode_generation, update.header.mode_generation)
	testing.expect_value(t, ack.surface_generation, update.header.surface.generation)
	_, valid = frame_mailbox_take_legacy_ack(&mailbox)
	testing.expect(t, !valid)
	testing.expect(t, frame_mailbox_note_legacy_applied(&mailbox, update))
	frame_mailbox_reset(&mailbox)
	testing.expect(t, !frame_mailbox_legacy_was_committed(&mailbox, update))
	_, valid = frame_mailbox_take_legacy_ack(&mailbox)
	testing.expect(t, !valid)
	testing.expect(t, !frame_mailbox_note_legacy_applied(&mailbox, update))
}

@(test)
frame_mailbox_test_gsw_ack_is_lifecycle_bound_and_single_use :: proc(t: ^testing.T) {
	mailbox: Frame_Mailbox
	defer frame_mailbox_destroy(&mailbox)
	lifecycle := frame_mailbox_lifecycle_generation(&mailbox)
	present := contract.Gsw_Present {
		header = {
			sequence = 9,
			lifecycle_generation = lifecycle,
			device_generation = 4,
			surface = {id = 7, generation = 3},
		},
	}
	testing.expect(t, frame_mailbox_note_gsw_applied(&mailbox, present))
	testing.expect(t, frame_mailbox_gsw_was_committed(&mailbox, present))
	mutated := present
	mutated.source_pitch = 4
	testing.expect(t, !frame_mailbox_gsw_was_committed(&mailbox, mutated))
	ack, valid := frame_mailbox_take_gsw_ack(&mailbox)
	testing.expect(t, valid)
	testing.expect_value(t, ack.sequence, present.header.sequence)
	testing.expect_value(t, ack.device_generation, present.header.device_generation)
	testing.expect_value(t, ack.surface_id, present.header.surface.id)
	testing.expect_value(t, ack.surface_generation, present.header.surface.generation)
	_, valid = frame_mailbox_take_gsw_ack(&mailbox)
	testing.expect(t, !valid)
	testing.expect(t, frame_mailbox_note_gsw_applied(&mailbox, present))
	frame_mailbox_reset(&mailbox)
	testing.expect(t, !frame_mailbox_gsw_was_committed(&mailbox, present))
	_, valid = frame_mailbox_take_gsw_ack(&mailbox)
	testing.expect(t, !valid)
	testing.expect(t, !frame_mailbox_note_gsw_applied(&mailbox, present))
}

@(test)
frame_mailbox_test_legacy_failure_retries_identical_generation_without_clobber :: proc(
	t: ^testing.T,
) {
	mailbox: Frame_Mailbox
	defer frame_mailbox_destroy(&mailbox)
	lifecycle := frame_mailbox_lifecycle_generation(&mailbox)
	first, reserved := frame_mailbox_begin(&mailbox, 7)
	if !testing.expect(t, reserved) {return}
	first.scanout.generation = 7
	first.scanout.legacy_update.header = {
		sequence             = 7,
		lifecycle_generation = lifecycle,
	}
	if !testing.expect(t, frame_mailbox_commit(&mailbox, first, true)) {return}
	failed := frame_mailbox_acquire(&mailbox)
	if !testing.expect(t, failed == first) {return}
	testing.expect(t, frame_mailbox_retry_latest(&mailbox, failed))

	retry, retry_reserved := frame_mailbox_begin(&mailbox, 7)
	if !testing.expect(t, retry_reserved) {return}
	retry.scanout.generation = 7
	retry.scanout.legacy_update.header = first.scanout.legacy_update.header
	if !testing.expect(t, frame_mailbox_commit(&mailbox, retry, true)) {return}
	testing.expect(t, !frame_mailbox_retry_latest(&mailbox, failed))
	frame_mailbox_release(&mailbox, failed)
	republished := frame_mailbox_acquire(&mailbox)
	if !testing.expect(t, republished == retry) {return}
	frame_mailbox_release(&mailbox, republished)
}

@(test)
frame_mailbox_test_gsw_failure_retries_identical_generation_without_clobber :: proc(
	t: ^testing.T,
) {
	mailbox: Frame_Mailbox
	defer frame_mailbox_destroy(&mailbox)
	lifecycle := frame_mailbox_lifecycle_generation(&mailbox)
	first, reserved := frame_mailbox_begin(&mailbox, 9)
	if !testing.expect(t, reserved) {return}
	first.scanout.generation = 9
	first.scanout.gsw_presentation.present_valid = true
	first.scanout.gsw_presentation.present.header = {
		sequence             = 9,
		lifecycle_generation = lifecycle,
	}
	if !testing.expect(t, frame_mailbox_commit(&mailbox, first, true)) {return}
	failed := frame_mailbox_acquire(&mailbox)
	if !testing.expect(t, failed == first) {return}
	testing.expect(t, frame_mailbox_retry_latest(&mailbox, failed))

	retry, retry_reserved := frame_mailbox_begin(&mailbox, 9)
	if !testing.expect(t, retry_reserved) {return}
	retry.scanout.generation = 9
	retry.scanout.gsw_presentation.present_valid = true
	retry.scanout.gsw_presentation.present.header = first.scanout.gsw_presentation.present.header
	if !testing.expect(t, frame_mailbox_commit(&mailbox, retry, true)) {return}
	testing.expect(t, !frame_mailbox_retry_latest(&mailbox, failed))
	frame_mailbox_release(&mailbox, failed)
	republished := frame_mailbox_acquire(&mailbox)
	if !testing.expect(t, republished == retry) {return}
	frame_mailbox_release(&mailbox, republished)
}

@(test)
frame_mailbox_test_retry_cannot_clear_new_lifecycle_publication :: proc(t: ^testing.T) {
	mailbox: Frame_Mailbox
	defer frame_mailbox_destroy(&mailbox)
	if !testing.expect(t, frame_mailbox_test_publish_generation(&mailbox, 4)) {return}
	stale := frame_mailbox_acquire(&mailbox)
	if !testing.expect(t, stale != nil) {return}
	frame_mailbox_reset(&mailbox)
	if !testing.expect(t, frame_mailbox_test_publish_generation(&mailbox, 1)) {return}
	testing.expect(t, !frame_mailbox_retry_latest(&mailbox, stale))
	current := frame_mailbox_acquire(&mailbox)
	if !testing.expect(t, current != nil) {return}
	testing.expect_value(t, current.scanout.generation, u64(1))
	frame_mailbox_release(&mailbox, stale)
	frame_mailbox_release(&mailbox, current)
}

@(test)
frame_mailbox_test_capture_failure_retains_completed_legacy_copy :: proc(t: ^testing.T) {
	m := new(machine.Machine)
	defer free(m)
	if !testing.expect(t, machine.machine_init(m, 64 * 1024 * 1024)) {return}
	defer machine.machine_destroy(m)
	full := contract.Rect {
		width  = 2,
		height = 2,
	}
	dirty: contract.Rect_Set
	if !testing.expect(t, contract.rect_set_append(&dirty, full)) {return}
	mode_generation := m.vga.presentation_mode_clock.generation
	if mode_generation == 0 {mode_generation = 1}
	m.gsw_vga.presentation_state.active = {
		clip_mode = .Fullscreen,
		header = {
			sequence = contract.generation_next(vga.vga_presentation_sequence(&m.vga)),
			lifecycle_generation = 1,
			mode_generation = mode_generation,
			mode_key = {
				format = .Bgrx_8888,
				surface_extent = {2, 2},
				canvas_extent = {2, 2},
				source = full,
				destination = full,
			},
			identity_namespace = .Gsw2d,
			device_generation = m.gsw_vga.presentation_state.device_generation,
			surface = {id = 7, generation = 1},
			format = .Bgrx_8888,
			surface_extent = {2, 2},
			canvas_extent = {2, 2},
			source = full,
			destination = full,
			dirty = dirty,
			source_kind = .Gsw_Snapshot,
			ownership = .Vm_Framebuffer,
		},
		source_pitch = 8,
	}
	m.gsw_vga.presentation_state.active_valid = true
	m.gsw_vga.presentation_state.damage = {
		kind  = .Pixel_Memory,
		rects = dirty,
	}

	mailbox: Frame_Mailbox
	defer frame_mailbox_destroy(&mailbox)
	if !testing.expect(t, machine.machine_capture_scanout(m, &mailbox.slots[0].scanout, 1)) {
		return
	}
	gsw_bytes := mailbox.slots[0].scanout.gsw_presentation.bytes_copied
	if !testing.expect(t, gsw_bytes > 0) {return}
	legacy_bytes := mailbox.slots[0].scanout.bytes_copied - gsw_bytes
	if !testing.expect(t, legacy_bytes > 0) {return}
	mailbox.slots[0].scanout.copy_duration_ns = max(u64)
	mailbox.slots[0].scanout.gsw_presentation.copy_duration_ns = max(u64)
	m.gsw_vga.presentation_state.active.header.format = .Invalid
	frame_mailbox_graphics_telemetry_init(&mailbox, true)
	testing.expect(t, !frame_mailbox_publish_observed(&mailbox, m, 1, {}))

	epoch, found := graphics_telemetry_trace_epoch(&mailbox.telemetry, 0)
	if !testing.expect(t, found) {return}
	testing.expect_value(t, epoch.result, Graphics_Frame_Result.Capture_Failed)
	testing.expect_value(t, epoch.bytes_copied, u64(legacy_bytes))
	testing.expect_value(t, mailbox.telemetry.current.bytes_copied, epoch.bytes_copied)
	testing.expect_value(t, mailbox.telemetry.current.capture_failures, u64(1))
	testing.expect_value(t, mailbox.telemetry.current.presented, u64(0))
	testing.expect_value(t, mailbox.slots[0].scanout.bytes_copied, legacy_bytes)
	testing.expect_value(t, mailbox.slots[0].scanout.gsw_presentation.bytes_copied, 0)
	testing.expect_value(t, mailbox.slots[0].scanout.gsw_presentation.copy_duration_ns, u64(0))
	testing.expect(t, mailbox.slots[0].scanout.copy_duration_ns < max(u64))
	testing.expect(t, frame_mailbox_acquire(&mailbox) == nil)
}

@(test)
frame_mailbox_test_reader_never_reused_by_writer :: proc(t: ^testing.T) {
	mailbox: Frame_Mailbox
	defer frame_mailbox_destroy(&mailbox)
	testing.expect(t, frame_mailbox_test_publish_generation(&mailbox, 1))
	reading := frame_mailbox_acquire(&mailbox)
	if !testing.expect(t, reading != nil) {return}
	testing.expect_value(t, reading.scanout.generation, u64(1))

	testing.expect(t, frame_mailbox_test_publish_generation(&mailbox, 2))
	newest := frame_mailbox_acquire(&mailbox)
	if !testing.expect(t, newest != nil) {return}
	testing.expect(t, newest != reading)
	testing.expect_value(t, reading.state, Frame_Slot_State.Reading)
	testing.expect_value(t, newest.scanout.generation, u64(2))
	frame_mailbox_release(&mailbox, reading)
	frame_mailbox_release(&mailbox, newest)
}

@(test)
frame_mailbox_test_reset_accepts_restarted_generation :: proc(t: ^testing.T) {
	mailbox: Frame_Mailbox
	defer frame_mailbox_destroy(&mailbox)
	testing.expect(t, frame_mailbox_test_publish_generation(&mailbox, 10))
	frame_mailbox_reset(&mailbox)
	testing.expect(t, frame_mailbox_test_publish_generation(&mailbox, 0))
	slot := frame_mailbox_acquire(&mailbox)
	if !testing.expect(t, slot != nil) {return}
	testing.expect_value(t, slot.scanout.generation, u64(0))
	frame_mailbox_release(&mailbox, slot)
}

@(test)
frame_mailbox_test_ready_frames_coalesce_to_latest :: proc(t: ^testing.T) {
	mailbox: Frame_Mailbox
	defer frame_mailbox_destroy(&mailbox)
	testing.expect(t, frame_mailbox_test_publish_generation(&mailbox, 1))
	testing.expect(t, frame_mailbox_test_publish_generation(&mailbox, 2))
	newest := frame_mailbox_acquire(&mailbox)
	if !testing.expect(t, newest != nil) {return}
	testing.expect_value(t, newest.scanout.generation, u64(2))
	testing.expect(t, !frame_mailbox_test_publish_generation(&mailbox, 2))
	frame_mailbox_release(&mailbox, newest)
}

@(test)
frame_mailbox_test_epoch_is_monotonic_and_coalescing_is_traced :: proc(t: ^testing.T) {
	mailbox: Frame_Mailbox
	defer frame_mailbox_destroy(&mailbox)
	frame_mailbox_graphics_telemetry_init(&mailbox, true)
	producer_before := Graphics_Producer_Sample {
		valid                        = true,
		output_underrun_frames       = 5,
		output_underrun_events       = 2,
		native_pcm_starvation_frames = 3,
	}
	first, reserved := frame_mailbox_begin_at(&mailbox, 10, time.Tick{100}, producer_before)
	if !testing.expect(t, reserved) {return}
	first.scanout.generation = 10
	graphics_frame_epoch_capture_complete(&first.epoch, 256, time.Tick{120})
	testing.expect(t, frame_mailbox_commit(&mailbox, first, true))
	frame_mailbox_graphics_telemetry_note_input(&mailbox, 1, 25, 25, time.Tick{130})

	second: ^Frame_Slot
	producer_after := producer_before
	producer_after.output_underrun_frames = 7
	producer_after.output_underrun_events = 3
	producer_after.native_pcm_starvation_frames = 8
	second, reserved = frame_mailbox_begin_at(&mailbox, 11, time.Tick{200}, producer_after)
	if !testing.expect(t, reserved) {return}
	testing.expect_value(t, second.epoch.sequence, u64(2))
	testing.expect_value(t, second.epoch.scanout_generation, u64(11))
	testing.expect_value(t, second.epoch.input_events, u64(1))
	testing.expect_value(t, second.epoch.input_residence_ns, u64(25))
	testing.expect_value(t, second.epoch.producer.output_underrun_frames, u64(2))
	testing.expect_value(t, second.epoch.producer.output_underrun_events, u64(1))
	testing.expect_value(t, second.epoch.producer.native_pcm_starvation_frames, u64(5))
	coalesced, ok := graphics_telemetry_trace_epoch(&mailbox.telemetry, 0)
	if !testing.expect(t, ok) {return}
	testing.expect_value(t, coalesced.sequence, u64(1))
	testing.expect_value(t, coalesced.result, Graphics_Frame_Result.Coalesced)
	testing.expect_value(t, coalesced.bytes_copied, u64(256))
	_ = frame_mailbox_commit(&mailbox, second, false)
}

@(test)
frame_mailbox_test_coalescing_carries_oldest_input_to_eventual_present :: proc(t: ^testing.T) {
	mailbox: Frame_Mailbox
	defer frame_mailbox_destroy(&mailbox)
	frame_mailbox_graphics_telemetry_init(&mailbox, true)
	producer_before := Graphics_Producer_Sample {
		valid                  = true,
		session_generation     = 3,
		output_underrun_frames = 5,
	}
	producer_before.machine.gsw3d.device_generation = 4
	frame_mailbox_graphics_telemetry_note_input(&mailbox, 1, 20, 20, time.Tick{60}, time.Tick{50})
	first, reserved := frame_mailbox_begin_at(&mailbox, 10, time.Tick{100}, producer_before)
	if !testing.expect(t, reserved) {return}
	first.scanout.generation = 10
	testing.expect(t, frame_mailbox_commit(&mailbox, first, true))

	frame_mailbox_graphics_telemetry_note_input(
		&mailbox,
		1,
		30,
		30,
		time.Tick{140},
		time.Tick{125},
	)
	producer_after := producer_before
	producer_after.output_underrun_frames = 7
	second: ^Frame_Slot
	second, reserved = frame_mailbox_begin_at(&mailbox, 11, time.Tick{200}, producer_after)
	if !testing.expect(t, reserved) {return}
	testing.expect_value(t, second.epoch.input_events, u64(2))
	testing.expect_value(t, second.epoch.input_residence_ns, u64(50))
	testing.expect_value(t, second.epoch.max_input_residence_ns, u64(30))
	testing.expect_value(t, second.epoch.input_oldest_queued_at, time.Tick{50})
	testing.expect_value(t, second.epoch.producer.samples, u64(2))
	testing.expect_value(t, second.epoch.producer.session_generation, u64(3))
	testing.expect_value(t, second.epoch.producer.device_generation, u64(4))
	testing.expect_value(t, second.epoch.producer.output_underrun_frames, u64(2))
	coalesced, ok := graphics_telemetry_trace_epoch(&mailbox.telemetry, 0)
	if !testing.expect(t, ok) {return}
	testing.expect_value(t, coalesced.result, Graphics_Frame_Result.Coalesced)
	testing.expect_value(t, coalesced.input_events, u64(0))
	testing.expect_value(t, coalesced.producer, Graphics_Producer_Interval{})

	second.scanout.generation = 11
	testing.expect(t, frame_mailbox_commit(&mailbox, second, true))
	presented := frame_mailbox_acquire(&mailbox)
	if !testing.expect(t, presented == second) {return}
	graphics_frame_epoch_present_begin(&presented.epoch, time.Tick{290})
	result := frame_mailbox_graphics_epoch_complete_and_record(
		&mailbox,
		&presented.epoch,
		.Presented,
		time.Tick{300},
	)
	testing.expect_value(t, result, Graphics_Frame_Result.Presented)
	testing.expect_value(t, presented.epoch.input_to_present_ns, u64(250))
	testing.expect_value(t, mailbox.telemetry.current.input_to_present_ns, u64(250))
	testing.expect_value(t, mailbox.telemetry.current.input_to_present_samples, u64(1))
	correlation := frame_mailbox_graphics_input_correlation(&mailbox)
	testing.expect_value(t, correlation.events, u64(2))
	testing.expect_value(t, correlation.samples, u64(1))
	testing.expect_value(t, correlation.total_ns, u64(250))
	testing.expect_value(t, correlation.max_ns, u64(250))
	testing.expect_value(t, correlation.retained_samples, u64(1))
	testing.expect_value(t, correlation.retention_capacity, u64(4096))
	testing.expect_value(t, correlation.retention_dropped, u64(0))
	testing.expect(t, correlation.retention_enabled)
	testing.expect(t, !correlation.retention_overflowed)
	testing.expect(t, correlation.percentiles_valid)
	testing.expect_value(t, correlation.p50_ns, u64(250))
	testing.expect_value(t, correlation.p95_ns, u64(250))
	testing.expect_value(t, correlation.p99_ns, u64(250))
	frame_mailbox_release(&mailbox, presented)
}

@(test)
frame_mailbox_test_direct_epoch_takes_correlated_producer_and_host_work :: proc(t: ^testing.T) {
	mailbox: Frame_Mailbox
	defer frame_mailbox_destroy(&mailbox)
	producer_before := Graphics_Producer_Sample {
		valid                  = true,
		session_generation     = 3,
		output_underrun_frames = 2,
	}
	producer_before.machine.gsw3d.device_generation = 4
	producer_before.machine.gsw3d.queue_depth_current = 1
	graphics_telemetry_note_producer(&mailbox.telemetry, producer_before, time.Tick{10})
	host_before := host.Host_Gsw3d_Observability_Snapshot {
		device_generation = 4,
		direct_presents   = 8,
	}
	_ = frame_mailbox_graphics_telemetry_note_host_gpu(&mailbox, host_before, time.Tick{11})
	producer_after := producer_before
	producer_after.output_underrun_frames = 5
	legacy, reserved := frame_mailbox_begin_at(&mailbox, 7, time.Tick{20}, producer_after)
	if !testing.expect(t, reserved) {return}

	host_after := host_before
	host_after.device_generation = 5
	host_after.direct_presents = 9
	host_after.direct_present_active = true
	host_after.direct_present_surface_id = 23
	host_after.direct_present_canvas_width = 640
	host_after.direct_present_canvas_height = 480
	_ = frame_mailbox_graphics_telemetry_note_host_gpu(&mailbox, host_after, time.Tick{40})
	producer_direct := producer_after
	producer_direct.machine.gsw3d.device_generation = 6
	producer_direct.machine.gsw3d.queue_depth_current = 9
	producer_direct.output_underrun_frames = 7
	graphics_telemetry_note_producer(&mailbox.telemetry, producer_direct, time.Tick{41})
	direct := frame_mailbox_graphics_telemetry_begin_host_epoch(&mailbox, time.Tick{42})
	graphics_frame_epoch_transfer_correlation(&direct, &legacy.epoch)
	testing.expect_value(t, direct.source, Graphics_Frame_Source.Gsw3d)
	testing.expect_value(t, direct.producer.output_underrun_frames, u64(5))
	testing.expect_value(t, direct.producer.device_generation, u64(6))
	testing.expect_value(t, direct.producer.gsw3d_queue_depth_current, 9)
	testing.expect_value(t, direct.host_gpu.direct_present_commands, u64(1))
	testing.expect_value(t, direct.host_gpu.device_generation, u64(5))
	testing.expect_value(t, direct.host_gpu.direct_present_surface_id, u32(23))
	testing.expect_value(t, legacy.epoch.producer, Graphics_Producer_Interval{})
	testing.expect_value(t, legacy.epoch.host_gpu, Graphics_Host_Gpu_Interval{})
	_ = frame_mailbox_commit(&mailbox, legacy, false)
}

@(test)
frame_mailbox_test_reset_clears_pending_generation_attribution_and_baselines :: proc(
	t: ^testing.T,
) {
	mailbox: Frame_Mailbox
	defer frame_mailbox_destroy(&mailbox)
	producer := Graphics_Producer_Sample {
		valid                  = true,
		session_generation     = 9,
		output_underrun_frames = 12,
	}
	graphics_telemetry_note_producer(&mailbox.telemetry, producer, time.Tick{10})
	graphics_telemetry_note_input(&mailbox.telemetry, 1, 4, 4, time.Tick{11})
	_ = graphics_telemetry_note_host_gpu(
		&mailbox.telemetry,
		host.Host_Gsw3d_Observability_Snapshot{device_generation = 7, direct_presents = 3},
		time.Tick{12},
	)
	frame_mailbox_reset(&mailbox)
	testing.expect(t, !mailbox.telemetry.producer_sampled)
	testing.expect(t, mailbox.telemetry.host_gpu_sampled)
	testing.expect_value(t, mailbox.telemetry.pending_input_events, u64(0))
	testing.expect_value(t, mailbox.telemetry.pending_producer, Graphics_Producer_Interval{})
	testing.expect_value(t, mailbox.telemetry.pending_host_gpu, Graphics_Host_Gpu_Interval{})

	after_reset, reserved := frame_mailbox_begin_at(&mailbox, 1, time.Tick{20}, producer)
	if !testing.expect(t, reserved) {return}
	testing.expect_value(t, after_reset.epoch.producer.output_underrun_frames, u64(0))
	_ = frame_mailbox_commit(&mailbox, after_reset, false)
}

@(test)
frame_mailbox_test_reset_rejects_writer_reserved_before_reset :: proc(t: ^testing.T) {
	mailbox: Frame_Mailbox
	defer frame_mailbox_destroy(&mailbox)
	stale, reserved := frame_mailbox_begin_at(&mailbox, 4, time.Tick{10}, {})
	if !testing.expect(t, reserved) {return}
	stale.scanout.generation = 4
	local_epoch := stale.epoch
	frame_mailbox_reset(&mailbox)
	testing.expect(t, !frame_mailbox_graphics_epoch_current(&mailbox, &local_epoch))
	completed := local_epoch
	result := frame_mailbox_graphics_epoch_complete_and_record(
		&mailbox,
		&completed,
		.Compose_Failed,
		time.Tick{15},
	)
	testing.expect_value(t, result, Graphics_Frame_Result.Reset)
	testing.expect_value(t, completed.result, Graphics_Frame_Result.Reset)
	testing.expect(t, !frame_mailbox_commit(&mailbox, stale, true))
	testing.expect_value(t, stale.state, Frame_Slot_State.Free)
	observed := frame_mailbox_acquire(&mailbox)
	testing.expect(t, observed == nil)

	current := frame_mailbox_graphics_telemetry_begin_host_epoch(&mailbox, time.Tick{20})
	testing.expect(t, frame_mailbox_graphics_epoch_current(&mailbox, &current))
	testing.expect(t, current.lifecycle_generation != local_epoch.lifecycle_generation)
}

@(test)
frame_mailbox_test_current_commit_is_gated_by_lifecycle_lock :: proc(t: ^testing.T) {
	mailbox: Frame_Mailbox
	defer frame_mailbox_destroy(&mailbox)
	epoch := frame_mailbox_graphics_telemetry_begin_host_epoch(&mailbox, time.Tick{10})
	commit := Frame_Mailbox_Test_Current_Commit {
		result = true,
	}
	testing.expect_value(
		t,
		frame_mailbox_graphics_epoch_commit_current(
			&mailbox,
			&epoch,
			&commit,
			frame_mailbox_test_current_commit,
		),
		Frame_Mailbox_Current_Commit_Result.Committed,
	)
	testing.expect_value(t, commit.calls, 1)
	commit.result = false
	testing.expect_value(
		t,
		frame_mailbox_graphics_epoch_commit_current(
			&mailbox,
			&epoch,
			&commit,
			frame_mailbox_test_current_commit,
		),
		Frame_Mailbox_Current_Commit_Result.Rejected,
	)
	testing.expect_value(t, commit.calls, 2)

	frame_mailbox_reset(&mailbox)
	testing.expect_value(
		t,
		frame_mailbox_graphics_epoch_commit_current(
			&mailbox,
			&epoch,
			&commit,
			frame_mailbox_test_current_commit,
		),
		Frame_Mailbox_Current_Commit_Result.Stale,
	)
	testing.expect_value(t, commit.calls, 2)
}
