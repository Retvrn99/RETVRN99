// SPDX-License-Identifier: GPL-3.0-only
package main

import "acceptance"
import "core:testing"
import "core:time"
import "host"

Input_Control_Test_Sink :: struct {
	actions:      [16]acceptance.Input_Action,
	count:        int,
	backpressure: int,
	generation:   u64,
}

input_control_test_enqueue :: proc(
	ctx: rawptr,
	action: acceptance.Input_Action,
	generation: u64,
) -> Input_Control_Enqueue_Result {
	sink := cast(^Input_Control_Test_Sink)ctx
	if sink == nil {return .Lifecycle_Changed}
	if sink.backpressure > 0 {
		sink.backpressure -= 1
		return .Backpressure
	}
	if sink.count >= len(sink.actions) {return .Backpressure}
	sink.actions[sink.count] = action
	sink.count += 1
	sink.generation = generation
	return .Accepted
}

@(test)
input_control_test_validates_bounded_input_only_script :: proc(t: ^testing.T) {
	script, parse_diagnostic := acceptance.input_script_parse(
		"key ctrl-alt-delete\nmouse 4 -2 1\nbuttons 0\nwheel -1 0\n",
	)
	defer acceptance.input_script_destroy(&script)
	testing.expect_value(t, parse_diagnostic, acceptance.Input_Script_Diagnostic.None)
	testing.expect_value(t, input_control_validate(&script), Input_Control_Diagnostic.None)

	reset_script, _ := acceptance.input_script_parse("reset\n")
	defer acceptance.input_script_destroy(&reset_script)
	testing.expect_value(
		t,
		input_control_validate(&reset_script),
		Input_Control_Diagnostic.Unsupported_Action,
	)

	held_script, _ := acceptance.input_script_parse("buttons 1\n")
	defer acceptance.input_script_destroy(&held_script)
	testing.expect_value(
		t,
		input_control_validate(&held_script),
		Input_Control_Diagnostic.Mouse_Buttons_Held,
	)

	implicit_release, _ := acceptance.input_script_parse("mouse 0 0 1\nmouse 0 0 0\n")
	defer acceptance.input_script_destroy(&implicit_release)
	testing.expect_value(
		t,
		input_control_validate(&implicit_release),
		Input_Control_Diagnostic.Mouse_Buttons_Held,
	)
}

@(test)
input_control_test_backpressure_does_not_advance_action :: proc(t: ^testing.T) {
	script, _ := acceptance.input_script_parse("key enter\n")
	control: Input_Control
	defer input_control_destroy(&control)
	testing.expect_value(t, input_control_adopt(&control, &script), Input_Control_Diagnostic.None)
	sink := Input_Control_Test_Sink{backpressure = 1}
	now := time.Tick{1_000}
	machine_state := Input_Control_Machine_State{running = true, generation = 9}
	testing.expect_value(
		t,
		input_control_tick(&control, machine_state, now, input_control_test_enqueue, &sink),
		Input_Control_State.Running,
	)
	testing.expect_value(t, control.script.cursor, 0)
	testing.expect_value(t, sink.count, 0)
	testing.expect_value(
		t,
		input_control_tick(
			&control,
			machine_state,
			time.tick_add(now, time.Millisecond),
			input_control_test_enqueue,
			&sink,
		),
		Input_Control_State.Completed,
	)
	testing.expect_value(t, control.script.cursor, 1)
	testing.expect_value(t, sink.count, 1)
	testing.expect_value(t, sink.generation, u64(9))
}

@(test)
input_control_test_pause_stops_script_clock_without_resume_burst :: proc(t: ^testing.T) {
	script, _ := acceptance.input_script_parse("wait 100\nkey enter\n")
	control: Input_Control
	defer input_control_destroy(&control)
	_ = input_control_adopt(&control, &script)
	sink: Input_Control_Test_Sink
	start := time.Tick{10_000}
	running := Input_Control_Machine_State{running = true, generation = 2}
	_ = input_control_tick(&control, running, start, input_control_test_enqueue, &sink)
	paused := running
	paused.paused = true
	_ = input_control_tick(
		&control,
		paused,
		time.tick_add(start, 50 * time.Millisecond),
		input_control_test_enqueue,
		&sink,
	)
	resume := time.tick_add(start, 5 * time.Second)
	_ = input_control_tick(&control, running, resume, input_control_test_enqueue, &sink)
	_ = input_control_tick(
		&control,
		running,
		time.tick_add(resume, 49 * time.Millisecond),
		input_control_test_enqueue,
		&sink,
	)
	testing.expect_value(t, sink.count, 0)
	_ = input_control_tick(
		&control,
		running,
		time.tick_add(resume, 50 * time.Millisecond),
		input_control_test_enqueue,
		&sink,
	)
	testing.expect_value(t, sink.count, 1)
}

@(test)
input_control_test_generation_change_cancels_pending_actions :: proc(t: ^testing.T) {
	script, _ := acceptance.input_script_parse("wait 100\nkey enter\n")
	control: Input_Control
	defer input_control_destroy(&control)
	_ = input_control_adopt(&control, &script)
	sink: Input_Control_Test_Sink
	start := time.Tick{1_000}
	_ = input_control_tick(
		&control,
		{running = true, generation = 4},
		start,
		input_control_test_enqueue,
		&sink,
	)
	state := input_control_tick(
		&control,
		{running = true, generation = 5},
		time.tick_add(start, 200 * time.Millisecond),
		input_control_test_enqueue,
		&sink,
	)
	testing.expect_value(t, state, Input_Control_State.Failed)
	testing.expect_value(t, control.failure, Input_Control_Failure.Lifecycle_Changed)
	testing.expect_value(t, sink.count, 0)
}

@(test)
input_control_test_freeze_cancels_while_waiting_for_start :: proc(t: ^testing.T) {
	script, _ := acceptance.input_script_parse("key enter\n")
	control: Input_Control
	defer input_control_destroy(&control)
	_ = input_control_adopt(&control, &script)
	sink: Input_Control_Test_Sink
	state := input_control_tick(
		&control,
		{frozen = true},
		time.Tick{1_000},
		input_control_test_enqueue,
		&sink,
	)
	testing.expect_value(t, state, Input_Control_State.Failed)
	testing.expect_value(t, control.failure, Input_Control_Failure.Frozen)
	testing.expect_value(t, sink.count, 0)
}

@(test)
input_control_test_shared_enqueue_retries_full_queue_and_tags_generation :: proc(t: ^testing.T) {
	shared := new(Shared)
	defer free(shared)
	shared.machine_running = true
	shared.input_generation = 3
	for i in 0 ..< host.HOST_INPUT_NORMAL_CAPACITY {
		testing.expect(t, host.host_input_push_wheel(&shared.input, i32(i + 1), 0))
	}
	shared.input.events[shared.input.head].kind = .Mouse_Motion
	action := acceptance.Input_Action{kind = .Key, key_n = 2}
	action.key[0] = 0x1C
	action.key[1] = 0x9C
	testing.expect_value(
		t,
		input_control_enqueue_shared(shared, action, 3),
		Input_Control_Enqueue_Result.Backpressure,
	)
	testing.expect_value(t, shared.input.count, host.HOST_INPUT_NORMAL_CAPACITY)
	testing.expect_value(t, shared.input.dropped_motion, u64(0))
	_, _ = host.host_input_pop(&shared.input)
	testing.expect_value(
		t,
		input_control_enqueue_shared(shared, action, 3),
		Input_Control_Enqueue_Result.Accepted,
	)
	last := shared.input.events[(shared.input.head + shared.input.count - 1) % host.HOST_INPUT_CAPACITY]
	testing.expect_value(t, last.control_generation, u64(3))
	testing.expect_value(t, last.key_n, u8(2))
}

@(test)
input_control_test_machine_lifecycle_advances_generation_fail_closed :: proc(t: ^testing.T) {
	shared := new(Shared)
	defer free(shared)
	publish_machine_running(shared, true)
	testing.expect_value(t, shared.input_generation, u64(1))
	publish_machine_running(shared, false)
	testing.expect_value(t, shared.input_generation, u64(2))
	shared.machine_running = true
	shared.input_generation = max(u64)
	_ = host.host_input_push_wheel(&shared.input, 1, 0)
	publish_machine_running(shared, false)
	testing.expect(t, shared.input_generation_exhausted)
	testing.expect_value(t, shared.input.count, 0)
}

@(test)
input_control_test_machine_reinitialize_invalidates_queued_control :: proc(t: ^testing.T) {
	shared := new(Shared)
	defer free(shared)
	shared.machine_running = true
	shared.input_generation = 12
	testing.expect(t, host.host_input_push_wheel(&shared.input, 1, 0, 12))
	publish_machine_reinitializing(shared)
	testing.expect(t, !shared.machine_running)
	testing.expect_value(t, shared.input_generation, u64(13))
	event, ok := host.host_input_pop(&shared.input)
	if !testing.expect(t, ok) {return}
	testing.expect(t, !input_control_event_current(&event, shared.input_generation))
}

@(test)
input_control_test_event_generation_rejects_only_stale_control :: proc(t: ^testing.T) {
	physical := host.Host_Input_Event{kind = .Key}
	current := host.Host_Input_Event{kind = .Key, control_generation = 6}
	stale := host.Host_Input_Event{kind = .Key, control_generation = 5}
	testing.expect(t, input_control_event_current(&physical, 6))
	testing.expect(t, input_control_event_current(&current, 6))
	testing.expect(t, !input_control_event_current(&stale, 6))
}
