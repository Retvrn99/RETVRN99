// SPDX-License-Identifier: GPL-3.0-only
package main

import "core:time"

Graphics_Presentation_Drain_Observation :: struct {
	started:  time.Tick,
	ended:    time.Tick,
	executed: int,
	failed:   int,
	budget:   u64,
	host_gpu: Graphics_Host_Gpu_Interval,
}

Graphics_Presentation_Selection :: struct {
	active_epoch:   Graphics_Frame_Epoch,
	active:         bool,
	terminal_epoch: Graphics_Frame_Epoch,
	has_terminal:   bool,
}

@(private = "file")
graphics_presentation_host_work_observed :: proc(
	observation: Graphics_Presentation_Drain_Observation,
) -> bool {
	g := observation.host_gpu
	return(
		observation.executed > 0 ||
		observation.failed > 0 ||
		observation.budget > 0 ||
		g.sdl_gpu_fence_submissions > 0 ||
		g.sdl_gpu_fence_completions > 0 ||
		g.sdl_gpu_fence_capacity_waits > 0 ||
		g.generation_changes > 0 \
	)
}

graphics_presentation_select :: proc(
	mailbox: ^Frame_Mailbox,
	legacy_epoch: Graphics_Frame_Epoch,
	legacy_active: bool,
	observation: Graphics_Presentation_Drain_Observation,
) -> Graphics_Presentation_Selection {
	if mailbox == nil {return {}}
	result := Graphics_Presentation_Selection {
		active_epoch = legacy_epoch,
		active       = legacy_active,
	}
	g := observation.host_gpu
	direct_ready := g.direct_present_commands > 0 && g.direct_present_active
	direct_reset := g.direct_present_commands > 0 && !g.direct_present_active
	direct_deactivated :=
		g.direct_present_commands == 0 &&
		g.direct_present_deactivations > 0 &&
		!g.direct_present_active
	if direct_deactivated {
		terminal := result.active_epoch
		terminal_was_active := result.active && terminal.source == .Gsw3d
		if !terminal_was_active {
			terminal = frame_mailbox_graphics_telemetry_begin_host_epoch(
				mailbox,
				observation.started,
			)
			terminal.kind = .Xrgb_8888
		}
		frame_mailbox_graphics_telemetry_attach_pending_host_gpu(mailbox, &terminal)
		graphics_frame_epoch_gpu_drain(
			&terminal,
			observation.started,
			observation.ended,
			observation.executed,
			observation.failed,
			observation.budget,
		)
		_ = frame_mailbox_graphics_epoch_complete_and_record(
			mailbox,
			&terminal,
			.Reset,
			observation.ended,
		)
		result.terminal_epoch = terminal
		result.has_terminal = true
		if terminal_was_active {
			result.active_epoch = terminal
			result.active = false
		}
		return result
	}
	if direct_ready || direct_reset {
		direct := frame_mailbox_graphics_telemetry_begin_host_epoch(mailbox, observation.started)
		direct.kind = .Xrgb_8888
		direct.width = int(g.direct_present_canvas_width)
		direct.height = int(g.direct_present_canvas_height)
		if result.active {
			graphics_frame_epoch_transfer_correlation(&direct, &result.active_epoch)
			_ = frame_mailbox_graphics_epoch_complete_and_record(
				mailbox,
				&result.active_epoch,
				direct_ready ? .Superseded : .Reset,
				observation.ended,
			)
		}
		result.active_epoch = direct
		result.active = direct_ready
		if direct_reset {
			graphics_frame_epoch_gpu_drain(
				&result.active_epoch,
				observation.started,
				observation.ended,
				observation.executed,
				observation.failed,
				observation.budget,
			)
			_ = frame_mailbox_graphics_epoch_complete_and_record(
				mailbox,
				&result.active_epoch,
				.Reset,
				observation.ended,
			)
			result.terminal_epoch = result.active_epoch
			result.has_terminal = true
		}
	}
	if result.active {
		frame_mailbox_graphics_telemetry_attach_pending_host_gpu(mailbox, &result.active_epoch)
		graphics_frame_epoch_gpu_drain(
			&result.active_epoch,
			observation.started,
			observation.ended,
			observation.executed,
			observation.failed,
			observation.budget,
		)
		return result
	}
	if !result.has_terminal && graphics_presentation_host_work_observed(observation) {
		work := frame_mailbox_graphics_telemetry_begin_host_epoch(mailbox, observation.started)
		graphics_frame_epoch_gpu_drain(
			&work,
			observation.started,
			observation.ended,
			observation.executed,
			observation.failed,
			observation.budget,
		)
		_ = frame_mailbox_graphics_epoch_complete_and_record(
			mailbox,
			&work,
			.Gpu_Work,
			observation.ended,
		)
		result.terminal_epoch = work
		result.has_terminal = true
	}
	return result
}
