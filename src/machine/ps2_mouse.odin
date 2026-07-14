// SPDX-License-Identifier: GPL-3.0-only
package machine

// PS/2 behavior adapted from IzarraVM commit d930de57acccbc6a70cda8cc5a603173bf23cd1c.

PS2_MOUSE_BUTTON_LEFT   :: u8(1 << 0)
PS2_MOUSE_BUTTON_RIGHT  :: u8(1 << 1)
PS2_MOUSE_BUTTON_MIDDLE :: u8(1 << 2)
PS2_MOUSE_EVENT_CAPACITY :: 256

Ps2_Mouse_Mode :: enum u8 {
	Stream,
	Remote,
}

Ps2_Mouse_Expect :: enum u8 {
	None,
	Sample_Rate,
	Resolution,
}

Ps2_Mouse_Reply :: struct {
	bytes: [8]u8,
	count: int,
}

Ps2_Mouse_Packet :: struct {
	bytes: [4]u8,
	count: int,
}

Ps2_Mouse_Event :: struct {
	x, y, wheel: i64,
	buttons:     u8,
}

Ps2_Mouse :: struct {
	mode:                Ps2_Mouse_Mode,
	expect:              Ps2_Mouse_Expect,
	reporting:           bool,
	scaling_2_to_1:      bool,
	resolution:          u8,
	sample_rate:         u8,
	device_id:           u8,
	rate_history:        [3]u8,
	buttons:             u8,
	last_packet_buttons: u8,
	pending_x:           i64,
	pending_y:           i64,
	pending_wheel:       i64,
	events:              [PS2_MOUSE_EVENT_CAPACITY]Ps2_Mouse_Event,
	event_head:          int,
	event_count:         int,
	dropped_edges:       u64,
	sample_wait_ns:      u64,
	sample_scheduled:    bool,
	last_tx:             u8,
	last_tx_valid:       bool,
}

ps2_mouse_init :: proc(m: ^Ps2_Mouse) {
	m^ = {}
	ps2_mouse_set_defaults(m)
}

@(private = "file")
ps2_mouse_clear_motion :: proc(m: ^Ps2_Mouse) {
	m.pending_x = 0
	m.pending_y = 0
	m.pending_wheel = 0
	m.event_head = 0
	m.event_count = 0
	m.sample_wait_ns = 0
	m.sample_scheduled = false
	m.last_packet_buttons = m.buttons
}

ps2_mouse_set_defaults :: proc(m: ^Ps2_Mouse) {
	m.mode = .Stream
	m.expect = .None
	m.reporting = false
	m.scaling_2_to_1 = false
	m.resolution = 2
	m.sample_rate = 100
	m.device_id = 0
	m.rate_history = {}
	ps2_mouse_clear_motion(m)
}

@(private = "file")
ps2_mouse_reply_1 :: proc(a: u8) -> Ps2_Mouse_Reply {
	reply: Ps2_Mouse_Reply
	reply.bytes[0] = a
	reply.count = 1
	return reply
}

@(private = "file")
ps2_mouse_reply_2 :: proc(a, b: u8) -> Ps2_Mouse_Reply {
	reply := ps2_mouse_reply_1(a)
	reply.bytes[1] = b
	reply.count = 2
	return reply
}

@(private = "file")
ps2_mouse_reply_3 :: proc(a, b, c: u8) -> Ps2_Mouse_Reply {
	reply := ps2_mouse_reply_2(a, b)
	reply.bytes[2] = c
	reply.count = 3
	return reply
}

@(private = "file")
ps2_mouse_reply_4 :: proc(a, b, c, d: u8) -> Ps2_Mouse_Reply {
	reply := ps2_mouse_reply_3(a, b, c)
	reply.bytes[3] = d
	reply.count = 4
	return reply
}

ps2_mouse_note_tx :: proc(m: ^Ps2_Mouse, value: u8) {
	m.last_tx = value
	m.last_tx_valid = true
}

@(private = "file")
ps2_mouse_set_sample_rate :: proc(m: ^Ps2_Mouse, rate: u8) {
	m.sample_rate = max(rate, u8(1))
	m.rate_history = {m.rate_history[1], m.rate_history[2], rate}
	magic := [3]u8{200, 100, 80}
	if m.rate_history == magic {m.device_id = 3}
}

ps2_mouse_sample_interval_ns :: proc(m: ^Ps2_Mouse) -> u64 {
	return (1_000_000_000 + u64(m.sample_rate) - 1) / u64(max(m.sample_rate, u8(1)))
}

@(private = "file")
ps2_mouse_schedule_sample :: proc(m: ^Ps2_Mouse) {
	if m.mode != .Stream || !m.reporting || !ps2_mouse_has_data(m) || m.sample_scheduled {return}
	m.sample_wait_ns = ps2_mouse_sample_interval_ns(m)
	m.sample_scheduled = true
}

ps2_mouse_next_deadline_ns :: proc(m: ^Ps2_Mouse) -> (u64, bool) {
	return m.sample_wait_ns, m.sample_scheduled
}

ps2_mouse_advance :: proc(m: ^Ps2_Mouse, ns: u64) -> bool {
	if !m.sample_scheduled {return false}
	if ns < m.sample_wait_ns {
		m.sample_wait_ns -= ns
		return false
	}
	m.sample_wait_ns = 0
	m.sample_scheduled = false
	return true
}

ps2_mouse_command :: proc(m: ^Ps2_Mouse, command: u8) -> Ps2_Mouse_Reply {
	if m.expect != .None {
		switch m.expect {
		case .Sample_Rate:
			ps2_mouse_set_sample_rate(m, command)
		case .Resolution:
			m.resolution = command & 3
		case .None:
		}
		m.expect = .None
		ps2_mouse_schedule_sample(m)
		return ps2_mouse_reply_1(0xFA)
	}

	switch command {
	case 0xFF:
		buttons := m.buttons
		ps2_mouse_set_defaults(m)
		m.buttons = buttons
		m.last_packet_buttons = buttons
		return ps2_mouse_reply_3(0xFA, 0xAA, 0x00)
	case 0xF6:
		ps2_mouse_set_defaults(m)
		return ps2_mouse_reply_1(0xFA)
	case 0xF5:
		m.reporting = false
		ps2_mouse_clear_motion(m)
		return ps2_mouse_reply_1(0xFA)
	case 0xF4:
		m.reporting = true
		ps2_mouse_clear_motion(m)
		return ps2_mouse_reply_1(0xFA)
	case 0xF3:
		m.expect = .Sample_Rate
		return ps2_mouse_reply_1(0xFA)
	case 0xF2:
		return ps2_mouse_reply_2(0xFA, m.device_id)
	case 0xF0:
		m.mode = .Remote
		m.sample_scheduled = false
		return ps2_mouse_reply_1(0xFA)
	case 0xEA:
		m.mode = .Stream
		ps2_mouse_schedule_sample(m)
		return ps2_mouse_reply_1(0xFA)
	case 0xEB:
		packet := ps2_mouse_take_packet(m)
		reply: Ps2_Mouse_Reply
		reply.bytes[0] = 0xFA
		copy(reply.bytes[1:], packet.bytes[:packet.count])
		reply.count = packet.count + 1
		return reply
	case 0xE9:
		status := m.buttons & 7
		if m.mode == .Remote {status |= 0x40}
		if m.reporting {status |= 0x20}
		if m.scaling_2_to_1 {status |= 0x10}
		return ps2_mouse_reply_4(0xFA, status, m.resolution, m.sample_rate)
	case 0xE8:
		m.expect = .Resolution
		return ps2_mouse_reply_1(0xFA)
	case 0xE7:
		m.scaling_2_to_1 = true
		return ps2_mouse_reply_1(0xFA)
	case 0xE6:
		m.scaling_2_to_1 = false
		return ps2_mouse_reply_1(0xFA)
	case 0xFE:
		return ps2_mouse_reply_1(m.last_tx_valid ? m.last_tx : 0xFE)
	case:
		return ps2_mouse_reply_1(0xFE)
	}
}

@(private = "file")
ps2_mouse_push_event :: proc(m: ^Ps2_Mouse, event: Ps2_Mouse_Event) -> bool {
	if m.event_count == len(m.events) {
		m.dropped_edges += 1
		return false
	}
	index := (m.event_head + m.event_count) % len(m.events)
	m.events[index] = event
	m.event_count += 1
	return true
}

ps2_mouse_update_wheel :: proc(m: ^Ps2_Mouse, host_dx, host_dy, wheel: i32, buttons: u8) {
	new_buttons := buttons & 7
	if m.mode == .Stream && !m.reporting {
		m.buttons = new_buttons
		ps2_mouse_clear_motion(m)
		return
	}
	m.pending_x += i64(host_dx)
	m.pending_y -= i64(host_dy)
	if m.device_id == 3 {m.pending_wheel += i64(wheel)}
	if new_buttons != m.buttons {
		queued := ps2_mouse_push_event(m, Ps2_Mouse_Event{
			x = m.pending_x,
			y = m.pending_y,
			wheel = m.pending_wheel,
			buttons = new_buttons,
		})
		if queued {
			m.pending_x = 0
			m.pending_y = 0
			m.pending_wheel = 0
		}
		m.buttons = new_buttons
	}
	ps2_mouse_schedule_sample(m)
}

ps2_mouse_update :: proc(m: ^Ps2_Mouse, host_dx, host_dy: i32, buttons: u8) {
	ps2_mouse_update_wheel(m, host_dx, host_dy, 0, buttons)
}

ps2_mouse_has_data :: proc(m: ^Ps2_Mouse) -> bool {
	return m.event_count > 0 || m.pending_x != 0 || m.pending_y != 0 || m.pending_wheel != 0 || m.buttons != m.last_packet_buttons
}

ps2_mouse_stream_ready :: proc(m: ^Ps2_Mouse) -> bool {
	return m.mode == .Stream && m.reporting && ps2_mouse_has_data(m)
}

@(private = "file")
ps2_mouse_scale :: proc(value: i64) -> i64 {
	negative := value < 0
	magnitude := negative ? -value : value
	scaled := magnitude
	switch magnitude {
	case 0, 1: scaled = magnitude
	case 2: scaled = 1
	case 3: scaled = 3
	case 4: scaled = 6
	case 5: scaled = 9
	case: scaled = magnitude * 2
	}
	return negative ? -scaled : scaled
}

@(private = "file")
ps2_mouse_source :: proc(m: ^Ps2_Mouse) -> (^i64, ^i64, ^i64, u8, bool) {
	if m.event_count > 0 {
		event := &m.events[m.event_head]
		return &event.x, &event.y, &event.wheel, event.buttons, true
	}
	return &m.pending_x, &m.pending_y, &m.pending_wheel, m.buttons, false
}

ps2_mouse_take_packet :: proc(m: ^Ps2_Mouse) -> Ps2_Mouse_Packet {
	m.sample_scheduled = false
	m.sample_wait_ns = 0
	x_ptr, y_ptr, wheel_ptr, buttons, from_event := ps2_mouse_source(m)
	raw_x, raw_y, raw_wheel := x_ptr^, y_ptr^, wheel_ptr^
	x, y := raw_x, raw_y
	if m.scaling_2_to_1 {
		x = ps2_mouse_scale(x)
		y = ps2_mouse_scale(y)
	}

	x_overflow := x < -256 || x > 255
	y_overflow := y < -256 || y > 255
	x = clamp(x, i64(-256), i64(255))
	y = clamp(y, i64(-256), i64(255))
	wheel := clamp(raw_wheel, i64(-8), i64(7))

	packet: Ps2_Mouse_Packet
	packet.count = m.device_id == 3 ? 4 : 3
	packet.bytes[0] = 0x08 | (buttons & 7)
	if x < 0 {packet.bytes[0] |= 0x10}
	if y < 0 {packet.bytes[0] |= 0x20}
	if x_overflow {packet.bytes[0] |= 0x40}
	if y_overflow {packet.bytes[0] |= 0x80}
	packet.bytes[1] = u8(u64(x) & 0xFF)
	packet.bytes[2] = u8(u64(y) & 0xFF)
	if packet.count == 4 {packet.bytes[3] = u8(u64(wheel) & 0x0F)}

	if m.scaling_2_to_1 {
		x_ptr^ = 0
		y_ptr^ = 0
	} else {
		x_ptr^ -= x
		y_ptr^ -= y
	}
	if packet.count == 4 {wheel_ptr^ -= wheel} else {wheel_ptr^ = 0}
	m.last_packet_buttons = buttons

	if from_event && x_ptr^ == 0 && y_ptr^ == 0 && wheel_ptr^ == 0 {
		m.event_head = (m.event_head + 1) % len(m.events)
		m.event_count -= 1
	}
	ps2_mouse_schedule_sample(m)
	return packet
}

ps2_mouse_packet :: proc(m: ^Ps2_Mouse) -> [3]u8 {
	packet := ps2_mouse_take_packet(m)
	return {packet.bytes[0], packet.bytes[1], packet.bytes[2]}
}
