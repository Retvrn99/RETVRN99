// SPDX-License-Identifier: GPL-3.0-only
package host

import "core:testing"
import "core:time"

@(test)
host_input_test_adjacent_motion_coalesces_only_with_matching_state :: proc(t: ^testing.T) {
	q: Host_Input_Queue
	testing.expect(t, host_input_push_motion(&q, 4, -3, MOUSE_LEFT))
	testing.expect(t, host_input_push_motion(&q, 6, 2, MOUSE_LEFT))
	testing.expect_value(t, q.count, 1)
	e, ok := host_input_pop(&q)
	testing.expect(t, ok)
	testing.expect_value(t, e.dx, i32(10))
	testing.expect_value(t, e.dy, i32(-1))

	_ = host_input_push_motion(&q, 1, 0, 0)
	_ = host_input_push_buttons(&q, MOUSE_LEFT)
	_ = host_input_push_motion(&q, 2, 0, MOUSE_LEFT)
	testing.expect_value(t, q.count, 3)
}

@(test)
host_input_test_edges_remain_ordered :: proc(t: ^testing.T) {
	q: Host_Input_Queue
	_ = host_input_push_buttons(&q, MOUSE_LEFT)
	_ = host_input_push_wheel(&q, -1, MOUSE_LEFT)
	_ = host_input_push_buttons(&q, 0)
	first, _ := host_input_pop(&q)
	second, _ := host_input_pop(&q)
	third, _ := host_input_pop(&q)
	testing.expect_value(t, first.kind, Host_Input_Kind.Mouse_Buttons)
	testing.expect_value(t, second.kind, Host_Input_Kind.Mouse_Wheel)
	testing.expect_value(t, third.kind, Host_Input_Kind.Mouse_Buttons)
	testing.expect_value(t, first.sequence, u64(0))
	testing.expect_value(t, second.sequence, u64(1))
	testing.expect_value(t, third.sequence, u64(2))
}

@(test)
host_input_test_edge_evicts_motion_when_full :: proc(t: ^testing.T) {
	q: Host_Input_Queue
	_ = host_input_push_motion(&q, 1, 0, 0)
	_ = host_input_push_buttons(&q, MOUSE_LEFT)
	for i in 2 ..< HOST_INPUT_NORMAL_CAPACITY {
		_ = host_input_push_wheel(&q, i32(i), 0)
	}
	testing.expect_value(t, q.count, HOST_INPUT_NORMAL_CAPACITY)
	testing.expect(t, host_input_push_buttons(&q, 0, true))
	testing.expect_value(t, q.count, HOST_INPUT_NORMAL_CAPACITY)
	testing.expect_value(t, q.dropped_motion, u64(1))
	first, _ := host_input_pop(&q)
	testing.expect_value(t, first.kind, Host_Input_Kind.Mouse_Buttons)
	testing.expect_value(t, first.buttons, MOUSE_LEFT)
	last: Host_Input_Event
	for q.count > 0 {last, _ = host_input_pop(&q)}
	testing.expect_value(t, last.kind, Host_Input_Kind.Mouse_Buttons)
	testing.expect_value(t, last.buttons, u8(0))
}

@(test)
host_input_test_key_and_button_releases_survive_edge_backlog :: proc(t: ^testing.T) {
	q: Host_Input_Queue
	k: Host_Keyboard
	testing.expect(t, host_input_push_key(&q, &k, .A, true, false))
	for i in 1 ..< HOST_INPUT_NORMAL_CAPACITY {
		testing.expect(t, host_input_push_wheel(&q, i32(i), MOUSE_LEFT))
	}
	testing.expect_value(t, q.count, HOST_INPUT_NORMAL_CAPACITY)
	testing.expect(t, !host_input_push_wheel(&q, 1, MOUSE_LEFT))
	testing.expect(t, host_input_push_key(&q, &k, .A, false, false))
	testing.expect_value(t, k.held_count, 0)
	testing.expect(t, host_input_push_buttons(&q, 0, true))
	testing.expect_value(t, q.count, HOST_INPUT_NORMAL_CAPACITY + 2)

	penultimate, last := Host_Input_Event{}, Host_Input_Event{}
	for q.count > 0 {
		penultimate = last
		last, _ = host_input_pop(&q)
	}
	testing.expect_value(t, penultimate.kind, Host_Input_Kind.Key)
	testing.expect(t, penultimate.durable_release)
	testing.expect_value(t, penultimate.key[0], u8(0x9E))
	testing.expect_value(t, last.kind, Host_Input_Kind.Mouse_Buttons)
	testing.expect(t, last.durable_release)
	testing.expect_value(t, last.buttons, u8(0))
}

@(test)
host_input_test_focus_release_uses_reserved_capacity :: proc(t: ^testing.T) {
	q: Host_Input_Queue
	k: Host_Keyboard
	testing.expect(t, host_input_push_key(&q, &k, .A, true, false))
	testing.expect(t, host_input_push_key(&q, &k, .LCTRL, true, false))
	for i in 2 ..< HOST_INPUT_NORMAL_CAPACITY {
		testing.expect(t, host_input_push_wheel(&q, i32(i), 0))
	}
	testing.expect_value(t, q.count, HOST_INPUT_NORMAL_CAPACITY)
	testing.expect_value(t, host_input_release_held_keys(&q, &k), 2)
	testing.expect_value(t, k.held_count, 0)
	testing.expect_value(t, q.count, HOST_INPUT_NORMAL_CAPACITY + 2)
}

@(test)
host_input_test_mouse_release_updates_full_edge_queue_authoritatively :: proc(t: ^testing.T) {
	q: Host_Input_Queue
	for i in 0 ..< HOST_INPUT_NORMAL_CAPACITY {
		testing.expect(t, host_input_push_wheel(&q, i32(i + 1), 0))
	}
	for i in 0 ..< HOST_KEY_IDS {
		event := Host_Input_Event {
			kind            = .Key,
			key_n           = 1,
			durable_release = true,
		}
		event.key[0] = u8(i)
		testing.expect(t, host_input_push(&q, event))
	}
	testing.expect(t, host_input_push_buttons(&q, MOUSE_LEFT, true))
	testing.expect_value(t, q.count, HOST_INPUT_CAPACITY)
	testing.expect(t, host_input_push_buttons(&q, 0, true))
	testing.expect_value(t, q.count, HOST_INPUT_CAPACITY)
	testing.expect_value(t, q.dropped_edges, u64(0))
	last := q.events[host_input_last_index(&q)]
	testing.expect(t, last.durable_release)
	testing.expect_value(t, last.kind, Host_Input_Kind.Mouse_Buttons)
	testing.expect_value(t, last.buttons, u8(0))
}

@(test)
host_input_test_drain_is_bounded :: proc(t: ^testing.T) {
	q: Host_Input_Queue
	for i in 0 ..< 10 {_ = host_input_push_wheel(&q, i32(i + 1), 0)}
	out: [4]Host_Input_Event
	n := host_input_drain(&q, out[:])
	testing.expect_value(t, n, 4)
	testing.expect_value(t, q.count, 6)
	testing.expect_value(t, out[3].wheel, i32(4))
}

@(test)
host_input_test_keyboard_ignores_host_repeat_and_releases_focus_state :: proc(t: ^testing.T) {
	q: Host_Input_Queue
	k: Host_Keyboard
	testing.expect(t, host_input_push_key(&q, &k, .A, true, false))
	testing.expect(t, !host_input_push_key(&q, &k, .A, true, true))
	testing.expect(t, !host_input_push_key(&q, &k, .A, true, false))
	testing.expect(t, host_input_push_key(&q, &k, .LCTRL, true, false))
	testing.expect_value(t, k.held_count, 2)
	testing.expect_value(t, host_input_release_held_keys(&q, &k), 2)
	testing.expect_value(t, k.held_count, 0)
	first, _ := host_input_pop(&q)
	second, _ := host_input_pop(&q)
	ctrl_break, _ := host_input_pop(&q)
	a_break, _ := host_input_pop(&q)
	testing.expect_value(t, first.key[0], u8(0x1E))
	testing.expect_value(t, second.key[0], u8(0x1D))
	testing.expect_value(t, a_break.key[0], u8(0x9E))
	testing.expect_value(t, ctrl_break.key[0], u8(0x9D))
	testing.expect(t, !host_input_push_key(&q, &k, .A, false, false))
	testing.expect_value(t, q.count, 0)
}

@(test)
host_input_test_machine_stop_discards_queue_without_break_codes :: proc(t: ^testing.T) {
	q: Host_Input_Queue
	k: Host_Keyboard
	testing.expect(t, host_input_push_key(&q, &k, .A, true, false))
	testing.expect(t, host_input_push_motion(&q, 10, -5, MOUSE_LEFT))
	sequence := q.next_sequence
	host_input_discard_after_stop(&q, &k)
	testing.expect_value(t, q.count, 0)
	testing.expect_value(t, q.head, 0)
	testing.expect_value(t, q.next_sequence, sequence)
	testing.expect_value(t, k.held_count, 0)
	for held in k.held {testing.expect(t, !held)}
}

@(test)
host_input_test_print_screen_and_pause_sequences :: proc(t: ^testing.T) {
	q: Host_Input_Queue
	k: Host_Keyboard
	_ = host_input_push_key(&q, &k, .PRINTSCREEN, true, false)
	_ = host_input_push_key(&q, &k, .PRINTSCREEN, false, false)
	_ = host_input_push_key(&q, &k, .PAUSE, true, false)
	_ = host_input_push_key(&q, &k, .PAUSE, false, false)
	testing.expect_value(t, q.count, 3)
	make, _ := host_input_pop(&q)
	brk, _ := host_input_pop(&q)
	pause, _ := host_input_pop(&q)
	testing.expect_value(t, make.key_n, u8(4))
	testing.expect_value(
		t,
		make.key,
		[HOST_INPUT_KEY_BYTES]u8{0xE0, 0x2A, 0xE0, 0x37, 0, 0, 0, 0},
	)
	testing.expect_value(
		t,
		brk.key,
		[HOST_INPUT_KEY_BYTES]u8{0xE0, 0xB7, 0xE0, 0xAA, 0, 0, 0, 0},
	)
	testing.expect_value(t, pause.key_n, u8(6))
	testing.expect_value(
		t,
		pause.key,
		[HOST_INPUT_KEY_BYTES]u8{0xE1, 0x1D, 0x45, 0xE1, 0x9D, 0xC5, 0, 0},
	)
}

@(test)
host_input_test_residence_is_monotonic_and_coalescing_keeps_oldest_tick :: proc(t: ^testing.T) {
	q: Host_Input_Queue
	first := Host_Input_Event {
		kind    = .Mouse_Motion,
		dx      = 3,
		buttons = MOUSE_LEFT,
	}
	second := Host_Input_Event {
		kind    = .Mouse_Motion,
		dx      = 4,
		buttons = MOUSE_LEFT,
	}
	testing.expect(t, host_input_push_at(&q, first, time.Tick{100}))
	testing.expect(t, host_input_push_at(&q, second, time.Tick{250}))
	testing.expect_value(t, q.count, 1)
	event, ok := host_input_pop(&q)
	if !testing.expect(t, ok) {return}
	testing.expect_value(t, event.dx, i32(7))
	testing.expect_value(t, event.queued_at, time.Tick{100})
	testing.expect_value(t, host_input_residence_ns(&event, time.Tick{400}), u64(300))
	testing.expect_value(t, host_input_residence_ns(&event, time.Tick{50}), u64(0))
}

@(test)
host_input_test_control_sequence_keeps_eight_byte_chord_atomic :: proc(t: ^testing.T) {
	q: Host_Input_Queue
	sequence := [8]u8{0x1D, 0x38, 0xE0, 0x53, 0xE0, 0xD3, 0xB8, 0x9D}
	testing.expect(t, host_input_push_key_sequence(&q, sequence[:], 7))
	testing.expect_value(t, q.count, 1)
	event, ok := host_input_pop(&q)
	if !testing.expect(t, ok) {return}
	testing.expect_value(t, event.key_n, u8(8))
	testing.expect_value(t, event.key, sequence)
	testing.expect_value(t, event.control_generation, u64(7))
}

@(test)
host_input_test_motion_does_not_coalesce_across_control_generation :: proc(t: ^testing.T) {
	q: Host_Input_Queue
	testing.expect(t, host_input_push_motion(&q, 3, 0, 0, 4))
	testing.expect(t, host_input_push_motion(&q, 5, 0, 0, 5))
	testing.expect_value(t, q.count, 2)
}

@(test)
host_input_test_control_motion_actions_remain_distinct :: proc(t: ^testing.T) {
	q: Host_Input_Queue
	testing.expect(
		t,
		host_input_push_control(
			&q,
			{kind = .Mouse_Motion, dx = 3, control_generation = 4},
		),
	)
	testing.expect(
		t,
		host_input_push_control(
			&q,
			{kind = .Mouse_Motion, dx = 5, control_generation = 4},
		),
	)
	testing.expect_value(t, q.count, 2)
	first, _ := host_input_pop(&q)
	second, _ := host_input_pop(&q)
	testing.expect_value(t, first.dx, i32(3))
	testing.expect_value(t, second.dx, i32(5))
}

@(test)
host_input_test_control_pending_counts_only_generation_tagged_events :: proc(t: ^testing.T) {
	q: Host_Input_Queue
	testing.expect(t, host_input_push_wheel(&q, 1, 0))
	testing.expect(t, host_input_push_wheel(&q, 1, 0, 4))
	testing.expect(t, host_input_push_key_sequence(&q, []u8{0x1c, 0x9c}, 4))
	testing.expect_value(t, host_input_control_pending(&q), u64(2))
	_, _ = host_input_pop(&q)
	testing.expect_value(t, host_input_control_pending(&q), u64(2))
	_, _ = host_input_pop(&q)
	testing.expect_value(t, host_input_control_pending(&q), u64(1))
	_, _ = host_input_pop(&q)
	testing.expect_value(t, host_input_control_pending(&q), u64(0))
}

@(test)
host_input_test_control_release_uses_reserve_without_evicting_control_input :: proc(
	t: ^testing.T,
) {
	q: Host_Input_Queue
	for i in 0 ..< HOST_INPUT_NORMAL_CAPACITY {
		testing.expect(
			t,
			host_input_push_control(
				&q,
				{kind = .Mouse_Motion, dx = i32(i + 1), control_generation = 9},
			),
		)
	}
	first := q.events[q.head]
	testing.expect(t, host_input_push_control_release(&q, 9))
	testing.expect_value(t, q.count, HOST_INPUT_NORMAL_CAPACITY + 1)
	testing.expect_value(t, q.events[q.head], first)
	testing.expect_value(t, q.dropped_motion, u64(0))
	testing.expect_value(t, q.dropped_edges, u64(0))
	last := q.events[host_input_last_index(&q)]
	testing.expect_value(t, last.kind, Host_Input_Kind.Mouse_Buttons)
	testing.expect_value(t, last.buttons, u8(0))
	testing.expect_value(t, last.control_generation, u64(9))
	testing.expect(t, last.durable_release)
}
