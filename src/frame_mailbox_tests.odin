// SPDX-License-Identifier: GPL-3.0-only
package main

import "core:testing"
import "core:time"
import host "host"

frame_mailbox_test_publish_generation :: proc(mailbox: ^Frame_Mailbox, generation: u64) -> bool {
	slot, reserved := frame_mailbox_begin(mailbox, generation)
	if !reserved {return false}
	slot.scanout.generation = generation
	frame_mailbox_commit(mailbox, slot, true)
	return true
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
	frame_mailbox_commit(&mailbox, first, true)
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
	frame_mailbox_commit(&mailbox, second, false)
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
	frame_mailbox_graphics_telemetry_note_input(
		&mailbox,
		1,
		20,
		20,
		time.Tick{60},
		time.Tick{50},
	)
	first, reserved := frame_mailbox_begin_at(&mailbox, 10, time.Tick{100}, producer_before)
	if !testing.expect(t, reserved) {return}
	first.scanout.generation = 10
	frame_mailbox_commit(&mailbox, first, true)

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
	frame_mailbox_commit(&mailbox, second, true)
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
	frame_mailbox_commit(&mailbox, legacy, false)
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
	frame_mailbox_commit(&mailbox, after_reset, false)
}

@(test)
frame_mailbox_test_lifecycle_marks_writer_and_local_epoch_from_before_reset :: proc(
	t: ^testing.T,
) {
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
	frame_mailbox_commit(&mailbox, stale, true)
	testing.expect_value(t, stale.state, Frame_Slot_State.Ready)
	observed := frame_mailbox_acquire(&mailbox)
	if !testing.expect(t, observed == stale) {return}
	testing.expect(t, !frame_mailbox_graphics_epoch_current(&mailbox, &observed.epoch))
	frame_mailbox_release(&mailbox, observed)

	current := frame_mailbox_graphics_telemetry_begin_host_epoch(&mailbox, time.Tick{20})
	testing.expect(t, frame_mailbox_graphics_epoch_current(&mailbox, &current))
	testing.expect(t, current.lifecycle_generation != local_epoch.lifecycle_generation)
}
