// SPDX-License-Identifier: GPL-3.0-only
package main

import "core:time"
import "host"
import video "videopresentation"

graphics_presentation_event :: proc(
	presentation: ^video.Video_Presentation,
	adapter: ^video.Video_Presentation_Host_Adapter,
	event: ^video.Video_Presentation_Consume_Event,
) -> video.Graphics_Frame_Consumer_Result {
	return video.video_presentation_consume(
		presentation,
		adapter,
		false,
		nil,
		event,
	)
}

graphics_presentation_postmortem_state :: proc(
	presentation: ^video.Video_Presentation,
	adapter: ^video.Video_Presentation_Host_Adapter,
	state: video.Graphics_Postmortem_State,
) -> bool {
	result := graphics_presentation_event(
		presentation,
		adapter,
		&video.Video_Presentation_Consume_Event {
			kind = .Postmortem_State,
			postmortem_state = state,
		},
	)
	return result.event_applied
}

graphics_presentation_measured_state :: proc(
	presentation: ^video.Video_Presentation,
	adapter: ^video.Video_Presentation_Host_Adapter,
	session_generation: u64,
	guest_device_generation: u64,
	host_device_generation: u64,
	frame_generation: u64,
	host_stage: video.Graphics_Postmortem_Host_Stage,
) -> video.Graphics_Postmortem_State {
	result := graphics_presentation_event(
		presentation,
		adapter,
		&video.Video_Presentation_Consume_Event {
			kind = .Measured_State,
			postmortem_state = {session_generation = session_generation},
			guest_device_generation = guest_device_generation,
			host_device_generation = host_device_generation,
			frame_generation = frame_generation,
			host_stage = host_stage,
		},
	)
	return result.postmortem_state
}

graphics_presentation_postmortem_window :: proc(
	presentation: ^video.Video_Presentation,
	adapter: ^video.Video_Presentation_Host_Adapter,
	text: string,
	frame_generation: u64,
	window_provenance: video.Graphics_Postmortem_Provenance,
	vm_provenance: video.Graphics_Postmortem_Provenance,
) -> bool {
	result := graphics_presentation_event(
		presentation,
		adapter,
		&video.Video_Presentation_Consume_Event {
			kind = .Postmortem_Window,
			window_text = text,
			frame_generation = frame_generation,
			window_provenance = window_provenance,
			vm_provenance = vm_provenance,
		},
	)
	return result.event_applied
}

graphics_presentation_note_input :: proc(
	presentation: ^video.Video_Presentation,
	adapter: ^video.Video_Presentation_Host_Adapter,
	events, total_ns, max_ns: u64,
	now, oldest: time.Tick,
) {
	_ = graphics_presentation_event(
		presentation,
		adapter,
		&video.Video_Presentation_Consume_Event {
			kind = .Input,
			input_events = events,
			input_total_ns = total_ns,
			input_max_ns = max_ns,
			now = now,
			input_oldest = oldest,
		},
	)
}

graphics_presentation_note_gpu_drain :: proc(
	presentation: ^video.Video_Presentation,
	adapter: ^video.Video_Presentation_Host_Adapter,
	started, ended: time.Tick,
	executed, failed: int,
	budget: u64,
) {
	_ = graphics_presentation_event(
		presentation,
		adapter,
		&video.Video_Presentation_Consume_Event {
			kind = .Gpu_Drain,
			started = started,
			ended = ended,
			executed = executed,
			failed = failed,
			budget = budget,
		},
	)
}

graphics_presentation_note_host_gpu :: proc(
	presentation: ^video.Video_Presentation,
	adapter: ^video.Video_Presentation_Host_Adapter,
	snapshot: host.Host_Gsw3d_Observability_Snapshot,
	now: time.Tick,
) -> video.Graphics_Host_Gpu_Interval {
	return graphics_presentation_event(
		presentation,
		adapter,
		&video.Video_Presentation_Consume_Event {
			kind = .Host_Gpu,
			host_gpu = snapshot,
			now = now,
		},
	).host_gpu_interval
}

graphics_presentation_select_frame :: proc(
	presentation: ^video.Video_Presentation,
	adapter: ^video.Video_Presentation_Host_Adapter,
	epoch: ^video.Graphics_Frame_Epoch,
	pending: bool,
	drain: video.Graphics_Presentation_Drain_Observation,
) -> video.Graphics_Presentation_Selection {
	return graphics_presentation_event(
		presentation,
		adapter,
		&video.Video_Presentation_Consume_Event {
			kind = .Select,
			epoch = epoch,
			epoch_pending = pending,
			drain = drain,
		},
	).selection
}

graphics_presentation_epoch_current :: proc(
	presentation: ^video.Video_Presentation,
	adapter: ^video.Video_Presentation_Host_Adapter,
	epoch: ^video.Graphics_Frame_Epoch,
) -> bool {
	return graphics_presentation_event(
		presentation,
		adapter,
		&video.Video_Presentation_Consume_Event {kind = .Epoch_Current, epoch = epoch},
	).epoch_current
}

graphics_presentation_compose :: proc(
	presentation: ^video.Video_Presentation,
	adapter: ^video.Video_Presentation_Host_Adapter,
	epoch: ^video.Graphics_Frame_Epoch,
	started, ended: time.Tick,
) {
	_ = graphics_presentation_event(
		presentation,
		adapter,
		&video.Video_Presentation_Consume_Event {
			kind = .Compose,
			epoch = epoch,
			started = started,
			ended = ended,
		},
	)
}

graphics_presentation_present_begin :: proc(
	presentation: ^video.Video_Presentation,
	adapter: ^video.Video_Presentation_Host_Adapter,
	epoch: ^video.Graphics_Frame_Epoch,
	now: time.Tick,
) {
	_ = graphics_presentation_event(
		presentation,
		adapter,
		&video.Video_Presentation_Consume_Event {
			kind = .Present_Begin,
			epoch = epoch,
			now = now,
		},
	)
}

graphics_presentation_present_complete :: proc(
	presentation: ^video.Video_Presentation,
	adapter: ^video.Video_Presentation_Host_Adapter,
	started, ended: time.Tick,
) {
	_ = graphics_presentation_event(
		presentation,
		adapter,
		&video.Video_Presentation_Consume_Event {
			kind = .Present_Complete,
			started = started,
			ended = ended,
		},
	)
}

graphics_presentation_complete_epoch :: proc(
	presentation: ^video.Video_Presentation,
	adapter: ^video.Video_Presentation_Host_Adapter,
	epoch: ^video.Graphics_Frame_Epoch,
	result: video.Graphics_Frame_Result,
	now: time.Tick,
) -> video.Graphics_Frame_Result {
	return graphics_presentation_event(
		presentation,
		adapter,
		&video.Video_Presentation_Consume_Event {
			kind = .Complete_Epoch,
			epoch = epoch,
			result = result,
			now = now,
		},
	).completed_result
}

graphics_presentation_take_window :: proc(
	presentation: ^video.Video_Presentation,
	adapter: ^video.Video_Presentation_Host_Adapter,
	now: time.Tick,
) -> (video.Graphics_Telemetry_Window, string, bool, bool) {
	result := graphics_presentation_event(
		presentation,
		adapter,
		&video.Video_Presentation_Consume_Event {kind = .Telemetry_Window, now = now},
	)
	return result.telemetry_window,
		result.telemetry_window_text,
		result.telemetry_log_admitted,
		result.telemetry_window_ready
}
