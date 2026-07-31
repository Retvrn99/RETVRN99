// SPDX-License-Identifier: GPL-3.0-only
package main

import "acceptance"
import "core:sync"
import "host"

input_control_event_current :: proc(event: ^host.Host_Input_Event, generation: u64) -> bool {
	return event != nil &&
	       (event.control_generation == 0 || event.control_generation == generation)
}

input_control_note_reset_cancelled_locked :: proc(s: ^Shared) {
	if s == nil {return}
	s.input_control_stats.reset_cancelled = saturating_counter_add(
		s.input_control_stats.reset_cancelled,
		host.host_input_control_pending(&s.input),
	)
}

input_control_enqueue_shared :: proc(
	ctx: rawptr,
	action: acceptance.Input_Action,
	generation: u64,
) -> Input_Control_Enqueue_Result {
	s := cast(^Shared)ctx
	if s == nil || generation == 0 {return .Lifecycle_Changed}
	sync.lock(&s.mu)
	if !s.machine_running ||
	   s.input_generation_exhausted ||
	   s.input_generation != generation ||
	   s.frozen_msg != "" {
		sync.unlock(&s.mu)
		return .Lifecycle_Changed
	}
	if host.pause_active(&s.pause_state) {
		sync.unlock(&s.mu)
		return .Backpressure
	}
	accepted := false
	#partial switch action.kind {
	case .Key:
		keys := action.key
		accepted = host.host_input_push_key_sequence(
			&s.input,
			keys[:int(action.key_n)],
			generation,
		)
	case .Mouse_Move:
		accepted = host.host_input_push_control(
			&s.input,
			host.Host_Input_Event {
				kind = .Mouse_Motion,
				dx = action.dx,
				dy = action.dy,
				buttons = action.buttons,
				control_generation = generation,
			},
		)
	case .Mouse_Buttons:
		accepted = host.host_input_push_control(
			&s.input,
			host.Host_Input_Event {
				kind = .Mouse_Buttons,
				buttons = action.buttons,
				control_generation = generation,
			},
		)
	case .Mouse_Wheel:
		accepted = host.host_input_push_control(
			&s.input,
			host.Host_Input_Event {
				kind = .Mouse_Wheel,
				wheel = action.wheel,
				buttons = action.buttons,
				control_generation = generation,
			},
		)
	case:
	}
	if accepted {
		s.input_control_stats.queued = saturating_counter_add(s.input_control_stats.queued, 1)
	}
	sync.unlock(&s.mu)
	if accepted {vm_guard_kick(s.guard)}
	return accepted ? .Accepted : .Backpressure
}

input_control_release_mouse :: proc(control: ^Input_Control, s: ^Shared) {
	if control == nil || s == nil || control.buttons == 0 || control.generation == 0 {return}
	sync.lock(&s.mu)
	accepted :=
		s.machine_running &&
		!s.input_generation_exhausted &&
		s.input_generation == control.generation &&
		host.host_input_push_control_release(&s.input, control.generation)
	if accepted {
		s.input_control_stats.queued = saturating_counter_add(s.input_control_stats.queued, 1)
	}
	sync.unlock(&s.mu)
	if accepted {vm_guard_kick(s.guard)}
	control.buttons = 0
}
