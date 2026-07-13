// SPDX-License-Identifier: GPL-3.0-only
package machine

PS2_MOUSE_BUTTON_LEFT :: u8(1 << 0)
PS2_MOUSE_BUTTON_RIGHT :: u8(1 << 1)
PS2_MOUSE_BUTTON_MIDDLE :: u8(1 << 2)

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
	bytes: [4]u8,
	count: int,
}

Ps2_Mouse :: struct {
	mode:                Ps2_Mouse_Mode,
	expect:              Ps2_Mouse_Expect,
	reporting:           bool,
	scaling_2_to_1:      bool,
	resolution:          u8,
	sample_rate:         u8,
	buttons:             u8,
	last_packet_buttons: u8,
	pending_x:           i64,
	pending_y:           i64,
	last_tx:             u8,
	last_tx_valid:       bool,
}

ps2_mouse_init :: proc(m: ^Ps2_Mouse) {
	m^ = {}
	ps2_mouse_set_defaults(m)
}

ps2_mouse_set_defaults :: proc(m: ^Ps2_Mouse) {
	m.mode = .Stream
	m.expect = .None
	m.reporting = false
	m.scaling_2_to_1 = false
	m.resolution = 2
	m.sample_rate = 100
	m.pending_x = 0
	m.pending_y = 0
	m.last_packet_buttons = m.buttons
}

@(private = "file")
ps2_mouse_reply_1 :: proc(a: u8) -> Ps2_Mouse_Reply {
	r: Ps2_Mouse_Reply
	r.bytes[0] = a
	r.count = 1
	return r
}

@(private = "file")
ps2_mouse_reply_2 :: proc(a, b: u8) -> Ps2_Mouse_Reply {
	r: Ps2_Mouse_Reply
	r.bytes[0] = a
	r.bytes[1] = b
	r.count = 2
	return r
}

@(private = "file")
ps2_mouse_reply_3 :: proc(a, b, c: u8) -> Ps2_Mouse_Reply {
	r: Ps2_Mouse_Reply
	r.bytes[0] = a
	r.bytes[1] = b
	r.bytes[2] = c
	r.count = 3
	return r
}

@(private = "file")
ps2_mouse_reply_4 :: proc(a, b, c, d: u8) -> Ps2_Mouse_Reply {
	r: Ps2_Mouse_Reply
	r.bytes[0] = a
	r.bytes[1] = b
	r.bytes[2] = c
	r.bytes[3] = d
	r.count = 4
	return r
}

ps2_mouse_note_tx :: proc(m: ^Ps2_Mouse, value: u8) {
	m.last_tx = value
	m.last_tx_valid = true
}

ps2_mouse_command :: proc(m: ^Ps2_Mouse, command: u8) -> Ps2_Mouse_Reply {
	if m.expect != .None {
		switch m.expect {
		case .Sample_Rate:
			m.sample_rate = command
		case .Resolution:
			m.resolution = command & 3
		case .None:
		}
		m.expect = .None
		return ps2_mouse_reply_1(0xFA)
	}

	switch command {
	case 0xFF:
		buttons := m.buttons
		ps2_mouse_init(m)
		m.buttons = buttons
		m.last_packet_buttons = buttons
		return ps2_mouse_reply_3(0xFA, 0xAA, 0x00)
	case 0xF6:
		ps2_mouse_set_defaults(m)
		return ps2_mouse_reply_1(0xFA)
	case 0xF5:
		m.reporting = false
		m.pending_x = 0
		m.pending_y = 0
		m.last_packet_buttons = m.buttons
		return ps2_mouse_reply_1(0xFA)
	case 0xF4:
		m.reporting = true
		m.pending_x = 0
		m.pending_y = 0
		m.last_packet_buttons = m.buttons
		return ps2_mouse_reply_1(0xFA)
	case 0xF3:
		m.expect = .Sample_Rate
		return ps2_mouse_reply_1(0xFA)
	case 0xF2:
		return ps2_mouse_reply_2(0xFA, 0x00)
	case 0xF0:
		m.mode = .Remote
		return ps2_mouse_reply_1(0xFA)
	case 0xEA:
		m.mode = .Stream
		return ps2_mouse_reply_1(0xFA)
	case 0xEB:
		packet := ps2_mouse_packet(m)
		r: Ps2_Mouse_Reply
		r.bytes[0] = 0xFA
		r.bytes[1] = packet[0]
		r.bytes[2] = packet[1]
		r.bytes[3] = packet[2]
		r.count = 4
		return r
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

ps2_mouse_update :: proc(m: ^Ps2_Mouse, host_dx, host_dy: i32, buttons: u8) {
	m.buttons = buttons & 7
	if m.mode == .Stream && !m.reporting {
		m.pending_x = 0
		m.pending_y = 0
		m.last_packet_buttons = m.buttons
		return
	}
	m.pending_x += i64(host_dx)
	m.pending_y -= i64(host_dy)
}

ps2_mouse_has_data :: proc(m: ^Ps2_Mouse) -> bool {
	return m.pending_x != 0 || m.pending_y != 0 || m.buttons != m.last_packet_buttons
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
	case 0, 1:
		scaled = magnitude
	case 2:
		scaled = 1
	case 3:
		scaled = 3
	case 4:
		scaled = 6
	case 5:
		scaled = 9
	case:
		scaled = magnitude * 2
	}
	return negative ? -scaled : scaled
}

ps2_mouse_packet :: proc(m: ^Ps2_Mouse) -> [3]u8 {
	x := m.pending_x
	y := m.pending_y
	consume_all := m.scaling_2_to_1
	if m.scaling_2_to_1 {
		x = ps2_mouse_scale(x)
		y = ps2_mouse_scale(y)
	}

	x_overflow := x < -256 || x > 255
	y_overflow := y < -256 || y > 255
	x = clamp(x, i64(-256), i64(255))
	y = clamp(y, i64(-256), i64(255))

	packet: [3]u8
	packet[0] = 0x08 | (m.buttons & 7)
	if x < 0 {packet[0] |= 0x10}
	if y < 0 {packet[0] |= 0x20}
	if x_overflow {packet[0] |= 0x40}
	if y_overflow {packet[0] |= 0x80}
	packet[1] = u8(u64(x) & 0xFF)
	packet[2] = u8(u64(y) & 0xFF)

	if consume_all {
		m.pending_x = 0
		m.pending_y = 0
	} else {
		m.pending_x -= x
		m.pending_y -= y
	}
	m.last_packet_buttons = m.buttons
	return packet
}
