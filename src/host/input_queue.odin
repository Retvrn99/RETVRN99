// SPDX-License-Identifier: GPL-3.0-only
package host

import sdl3 "vendor:sdl3"

// Held-key tracking follows IzarraVM commit d930de57acccbc6a70cda8cc5a603173bf23cd1c.
HOST_INPUT_CAPACITY :: 4096
HOST_INPUT_KEY_BYTES :: 6
HOST_KEY_IDS :: 512
HOST_INPUT_RELEASE_RESERVE :: HOST_KEY_IDS + 1
HOST_INPUT_NORMAL_CAPACITY :: HOST_INPUT_CAPACITY - HOST_INPUT_RELEASE_RESERVE

Host_Input_Kind :: enum {
	Key,
	Mouse_Motion,
	Mouse_Buttons,
	Mouse_Wheel,
}

Host_Input_Event :: struct {
	kind:     Host_Input_Kind,
	sequence: u64,
	key:      [HOST_INPUT_KEY_BYTES]u8,
	key_n:    u8,
	dx, dy:   i32,
	wheel:    i32,
	buttons:  u8,
	durable_release: bool,
}

Host_Input_Queue :: struct {
	events:         [HOST_INPUT_CAPACITY]Host_Input_Event,
	head:           int,
	count:          int,
	next_sequence:  u64,
	dropped_motion: u64,
	dropped_edges:  u64,
}

Host_Keyboard :: struct {
	held:       [HOST_KEY_IDS]bool,
	held_count: int,
}

host_input_last_index :: proc(q: ^Host_Input_Queue) -> int {
	return (q.head + q.count - 1) % HOST_INPUT_CAPACITY
}

host_input_saturating_add :: proc(a, b: i32) -> i32 {
	sum := i64(a) + i64(b)
	return i32(clamp(sum, i64(-2147483648), i64(2147483647)))
}

host_input_remove_logical :: proc(q: ^Host_Input_Queue, logical: int) {
	for i in logical ..< q.count - 1 {
		to := (q.head + i) % HOST_INPUT_CAPACITY
		from := (q.head + i + 1) % HOST_INPUT_CAPACITY
		q.events[to] = q.events[from]
	}
	q.count -= 1
}

host_input_remove_pending_mouse_release :: proc(q: ^Host_Input_Queue) {
	logical := q.count
	for logical > 0 {
		logical -= 1
		index := (q.head + logical) % HOST_INPUT_CAPACITY
		event := &q.events[index]
		if event.kind == .Mouse_Buttons && event.durable_release {
			host_input_remove_logical(q, logical)
			return
		}
	}
}

host_input_make_room :: proc(q: ^Host_Input_Queue, event: ^Host_Input_Event) -> bool {
	if q.count < HOST_INPUT_NORMAL_CAPACITY {return true}
	if event.kind != .Mouse_Motion {
		for i in 0 ..< q.count {
			idx := (q.head + i) % HOST_INPUT_CAPACITY
			if q.events[idx].kind == .Mouse_Motion {
				host_input_remove_logical(q, i)
				q.dropped_motion += 1
				return true
			}
		}
	}
	if event.durable_release {
		if q.count < HOST_INPUT_CAPACITY {return true}
		for i in 0 ..< q.count {
			idx := (q.head + i) % HOST_INPUT_CAPACITY
			if !q.events[idx].durable_release {
				host_input_remove_logical(q, i)
				q.dropped_edges += 1
				return true
			}
		}
	}
	if event.kind == .Mouse_Motion {
		q.dropped_motion += 1
	} else {
		q.dropped_edges += 1
	}
	return false
}

host_input_push :: proc(q: ^Host_Input_Queue, event: Host_Input_Event) -> bool {
	if q == nil {return false}
	if event.kind == .Mouse_Buttons &&
	   event.durable_release &&
	   q.count == HOST_INPUT_CAPACITY {
		host_input_remove_pending_mouse_release(q)
	}
	if event.kind == .Mouse_Motion && q.count > 0 {
		last := &q.events[host_input_last_index(q)]
		if last.kind == .Mouse_Motion && last.buttons == event.buttons {
			last.dx = host_input_saturating_add(last.dx, event.dx)
			last.dy = host_input_saturating_add(last.dy, event.dy)
			return true
		}
	}
	e := event
	if !host_input_make_room(q, &e) {return false}
	e.sequence = q.next_sequence
	q.next_sequence += 1
	tail := (q.head + q.count) % HOST_INPUT_CAPACITY
	q.events[tail] = e
	q.count += 1
	return true
}

host_input_push_motion :: proc(q: ^Host_Input_Queue, dx, dy: i32, buttons: u8) -> bool {
	if dx == 0 && dy == 0 {return true}
	return host_input_push(q, Host_Input_Event{
		kind = .Mouse_Motion,
		dx = dx,
		dy = dy,
		buttons = buttons,
	})
}

host_input_push_buttons :: proc(
	q: ^Host_Input_Queue,
	buttons: u8,
	durable_release: bool = false,
) -> bool {
	return host_input_push(q, Host_Input_Event{
		kind = .Mouse_Buttons,
		buttons = buttons,
		durable_release = durable_release,
	})
}

host_input_push_wheel :: proc(q: ^Host_Input_Queue, wheel: i32, buttons: u8) -> bool {
	if wheel == 0 {return true}
	return host_input_push(q, Host_Input_Event{
		kind = .Mouse_Wheel,
		wheel = wheel,
		buttons = buttons,
	})
}

host_input_pop :: proc(q: ^Host_Input_Queue) -> (Host_Input_Event, bool) {
	if q == nil || q.count == 0 {return {}, false}
	e := q.events[q.head]
	q.head = (q.head + 1) % HOST_INPUT_CAPACITY
	q.count -= 1
	return e, true
}

host_input_drain :: proc(q: ^Host_Input_Queue, out: []Host_Input_Event) -> int {
	n := min(len(out), q.count)
	for i in 0 ..< n {out[i], _ = host_input_pop(q)}
	return n
}

host_keyboard_id :: proc(code: u8, extended: bool) -> int {
	return int(code) | (extended ? 0x100 : 0)
}

host_keyboard_mark :: proc(k: ^Host_Keyboard, id: int, down: bool) -> bool {
	if id < 0 || id >= HOST_KEY_IDS {return false}
	if down {
		if k.held[id] {return false}
		k.held[id] = true
		k.held_count += 1
		return true
	}
	if !k.held[id] {return false}
	k.held[id] = false
	k.held_count -= 1
	return true
}

host_input_push_key :: proc(
	q: ^Host_Input_Queue,
	k: ^Host_Keyboard,
	scancode: sdl3.Scancode,
	down, repeat: bool,
) -> bool {
	if q == nil || k == nil || repeat {return false}
	bytes, n, code, extended, tracks_hold, ok := scancode_set1_event(scancode, down)
	if !ok {return false}
	if tracks_hold && !host_keyboard_mark(k, host_keyboard_id(code, extended), down) {return false}
	if n == 0 {return true}
	accepted := host_input_push(q, Host_Input_Event{
		kind = .Key,
		key = bytes,
		key_n = u8(n),
		durable_release = !down,
	})
	if !accepted && tracks_hold {_ = host_keyboard_mark(k, host_keyboard_id(code, extended), !down)}
	return accepted
}

host_input_release_held_keys :: proc(q: ^Host_Input_Queue, k: ^Host_Keyboard) -> int {
	if q == nil || k == nil {return 0}
	released := 0
	for id in 0 ..< HOST_KEY_IDS {
		if !k.held[id] {continue}
		code := u8(id & 0xFF)
		extended := id & 0x100 != 0
		bytes: [HOST_INPUT_KEY_BYTES]u8
		n := 1
		if id == host_keyboard_id(0x37, true) {
			bytes[0] = 0xE0
			bytes[1] = 0xB7
			bytes[2] = 0xE0
			bytes[3] = 0xAA
			n = 4
		} else if extended {
			bytes[0] = 0xE0
			bytes[1] = code | 0x80
			n = 2
		} else {
			bytes[0] = code | 0x80
		}
		if !host_input_push(q, Host_Input_Event{
			kind = .Key,
			key = bytes,
			key_n = u8(n),
			durable_release = true,
		}) {
			continue
		}
		k.held[id] = false
		k.held_count -= 1
		released += 1
	}
	return released
}

host_input_discard_after_stop :: proc(q: ^Host_Input_Queue, k: ^Host_Keyboard) {
	if q != nil {
		q.head = 0
		q.count = 0
	}
	if k != nil {
		k.held = {}
		k.held_count = 0
	}
}
