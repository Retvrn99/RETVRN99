// SPDX-License-Identifier: GPL-3.0-only
package videopresentation

import host "../host"
import machine "../machine"
import profile "../profile"
import "core:time"

Video_Presentation_Config :: struct {
	trace_enabled: bool,
	postmortem:    Graphics_Postmortem_Config,
}

Video_Presentation_Init_Result :: struct {
	initialized:          bool,
	postmortem_diagnostic: Graphics_Postmortem_Init_Diagnostic,
}

Video_Presentation_Destroy_Result :: struct {
	postmortem_enabled:    bool,
	postmortem_diagnostic: profile.Graphics_Postmortem_Save_Diagnostic,
}

Video_Presentation_Consume_Event_Kind :: enum u8 {
	None,
	Measured_State,
	Postmortem_State,
	Postmortem_Window,
	Input,
	Gpu_Drain,
	Host_Gpu,
	Select,
	Epoch_Current,
	Compose,
	Present_Begin,
	Present_Complete,
	Complete_Epoch,
	Telemetry_Window,
}

Video_Presentation_Consume_Event :: struct {
	kind:              Video_Presentation_Consume_Event_Kind,
	postmortem_state:  Graphics_Postmortem_State,
	guest_device_generation: u64,
	host_device_generation:  u64,
	host_stage:              Graphics_Postmortem_Host_Stage,
	window_text:       string,
	frame_generation:  u64,
	window_provenance: Graphics_Postmortem_Provenance,
	vm_provenance:     Graphics_Postmortem_Provenance,
	now:               time.Tick,
	started:           time.Tick,
	ended:             time.Tick,
	executed:          int,
	failed:            int,
	budget:            u64,
	host_gpu:          host.Host_Gsw3d_Observability_Snapshot,
	epoch:             ^Graphics_Frame_Epoch,
	epoch_pending:     bool,
	drain:             Graphics_Presentation_Drain_Observation,
	result:            Graphics_Frame_Result,
	input_events:      u64,
	input_total_ns:    u64,
	input_max_ns:      u64,
	input_oldest:      time.Tick,
}

Video_Presentation_Telemetry_Snapshot :: struct {
	telemetry:   Graphics_Telemetry_Snapshot,
	correlation: Graphics_Input_Correlation,
	trace_text:  string,
}

video_presentation_init :: proc(
	video: ^Video_Presentation,
	config: Video_Presentation_Config = {},
) -> Video_Presentation_Init_Result {
	if video == nil {return {}}
	video^ = {}
	frame_mailbox_graphics_telemetry_init(video, config.trace_enabled)
	diagnostic := graphics_postmortem_init(&video.postmortem, config.postmortem)
	if diagnostic != .None {
		frame_mailbox_destroy(video)
		return {postmortem_diagnostic = diagnostic}
	}
	return {initialized = true}
}

video_presentation_destroy :: proc(
	video: ^Video_Presentation,
) -> Video_Presentation_Destroy_Result {
	if video == nil {return {}}
	enabled := graphics_postmortem_status(&video.postmortem).enabled
	diagnostic := graphics_postmortem_destroy(&video.postmortem)
	frame_mailbox_destroy(video)
	return {
		postmortem_enabled = enabled,
		postmortem_diagnostic = diagnostic,
	}
}

video_presentation_start :: proc(
	video: ^Video_Presentation,
	adapter: ^Video_Presentation_Host_Adapter,
) -> bool {
	if video == nil ||
	   adapter == nil ||
	   adapter.start == nil ||
	   (adapter.target != nil &&
		   !host.host_presentation_bind(adapter.target, &video.host_state)) {
		return false
	}
	return adapter.start(adapter.ctx, frame_mailbox_lifecycle_generation(video))
}

video_presentation_reset :: proc(
	video: ^Video_Presentation,
	adapter: ^Video_Presentation_Host_Adapter = nil,
) {
	if video == nil {return}
	frame_mailbox_reset(video)
	if adapter != nil && adapter.clear != nil {adapter.clear(adapter.ctx)}
}

video_presentation_stop :: proc(
	video: ^Video_Presentation,
	adapter: ^Video_Presentation_Host_Adapter = nil,
) {
	if video == nil {return}
	frame_mailbox_reset(video)
	if adapter != nil && adapter.stop != nil {adapter.stop(adapter.ctx)}
	if adapter != nil && adapter.clear != nil {adapter.clear(adapter.ctx)}
}

video_presentation_publish_observed :: proc(
	video: ^Video_Presentation,
	source: ^machine.Machine,
	session_generation: u64,
	vm: Graphics_Vm_Execution_Sample,
) -> bool {
	return frame_mailbox_publish_observed(
		video,
		source,
		session_generation,
		vm,
		&video.postmortem,
	)
}

video_presentation_consume :: proc(
	video: ^Video_Presentation,
	adapter: ^Video_Presentation_Host_Adapter,
	trace_enabled: bool,
	last_vm_checkpoint: ^time.Tick,
	event: ^Video_Presentation_Consume_Event = nil,
) -> Graphics_Frame_Consumer_Result {
	if video == nil {return {}}
	if event != nil {
		applied := false
		switch event.kind {
		case .Measured_State:
			return {
				event_applied = true,
				postmortem_state = graphics_postmortem_measured_state(
					event.postmortem_state.session_generation,
					event.guest_device_generation,
					event.host_device_generation,
					event.frame_generation,
					event.host_stage,
				),
				postmortem_state_valid = true,
			}
		case .Postmortem_State:
			applied = graphics_postmortem_publish_state(
				&video.postmortem,
				event.postmortem_state,
			) == .None
		case .Postmortem_Window:
			applied = graphics_postmortem_publish_window(
				&video.postmortem,
				event.window_text,
				event.frame_generation,
				event.window_provenance,
				event.vm_provenance,
			) == .None
		case .Input:
			frame_mailbox_graphics_telemetry_note_input(
				video,
				event.input_events,
				event.input_total_ns,
				event.input_max_ns,
				event.now,
				event.input_oldest,
			)
			applied = true
		case .Gpu_Drain:
			frame_mailbox_graphics_telemetry_note_gpu_drain(
				video,
				event.started,
				event.ended,
				event.executed,
				event.failed,
				event.budget,
			)
			applied = true
		case .Host_Gpu:
			interval := frame_mailbox_graphics_telemetry_note_host_gpu(
				video,
				event.host_gpu,
				event.now,
			)
			return {event_applied = true, host_gpu_interval = interval}
		case .Select:
			selection := graphics_presentation_select(
				video,
				event.epoch^,
				event.epoch_pending,
				event.drain,
			)
			return {event_applied = true, selection = selection}
		case .Epoch_Current:
			return {
				event_applied = true,
				epoch_current = frame_mailbox_graphics_epoch_current(video, event.epoch),
			}
		case .Compose:
			frame_mailbox_graphics_telemetry_note_compose(video, event.started, event.ended)
			if event.epoch != nil {graphics_frame_epoch_compose(event.epoch, event.started, event.ended)}
			applied = true
		case .Present_Begin:
			if event.epoch != nil {graphics_frame_epoch_present_begin(event.epoch, event.now)}
			applied = true
		case .Present_Complete:
			frame_mailbox_graphics_telemetry_note_present(video, event.started, event.ended)
			applied = true
		case .Complete_Epoch:
			completed := frame_mailbox_graphics_epoch_complete_and_record(
				video,
				event.epoch,
				event.result,
				event.now,
			)
			return {event_applied = true, completed_result = completed}
		case .Telemetry_Window:
			window, ready := frame_mailbox_graphics_telemetry_take_window(video, event.now)
			if !ready {return {event_applied = true}}
			window_text := graphics_telemetry_window_text(window)
			return {
				event_applied = true,
				telemetry_window = window,
				telemetry_window_ready = true,
				telemetry_window_text = window_text,
				telemetry_log_admitted = graphics_telemetry_aggregate_log_admit(
					&video.aggregate_logs,
				),
			}
		case .None:
		}
		return {event_applied = applied}
	}
	if adapter == nil {return {}}
	return graphics_frame_consume_with_adapter(
		video,
		adapter,
		trace_enabled,
		last_vm_checkpoint,
		nil,
	)
}

video_presentation_telemetry_snapshot :: proc(
	video: ^Video_Presentation,
	include_trace: bool = false,
) -> Video_Presentation_Telemetry_Snapshot {
	trace: string
	if include_trace {trace = frame_mailbox_graphics_trace_text(video)}
	return {
		telemetry = frame_mailbox_graphics_telemetry_snapshot(video, time.tick_now()),
		correlation = frame_mailbox_graphics_input_correlation(video),
		trace_text = trace,
	}
}

video_presentation_postmortem_snapshot :: proc(
	video: ^Video_Presentation,
) -> Graphics_Postmortem_Snapshot {
	return graphics_postmortem_snapshot(&video.postmortem)
}

@(private = "package")
graphics_presentation_sync_lifecycle :: proc(
	target: ^host.Host,
	video: ^Video_Presentation,
	machine_running: bool,
) -> bool {
	if !machine_running {return false}
	adapter := video_presentation_host_adapter(target)
	return video_presentation_start(video, &adapter)
}
