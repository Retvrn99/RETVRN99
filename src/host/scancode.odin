// SPDX-License-Identifier: GPL-3.0-only
package host

import sdl3 "vendor:sdl3"

// SDL scancode to set-1 scancode translation for the i8042.

Set1 :: struct {
	code: u8,
	ext:  bool, // 0xE0 prefix
}

scancode_to_set1 :: proc(sc: sdl3.Scancode) -> (s: Set1, ok: bool) {
	#partial switch sc {
	case .A: return {0x1E, false}, true
	case .B: return {0x30, false}, true
	case .C: return {0x2E, false}, true
	case .D: return {0x20, false}, true
	case .E: return {0x12, false}, true
	case .F: return {0x21, false}, true
	case .G: return {0x22, false}, true
	case .H: return {0x23, false}, true
	case .I: return {0x17, false}, true
	case .J: return {0x24, false}, true
	case .K: return {0x25, false}, true
	case .L: return {0x26, false}, true
	case .M: return {0x32, false}, true
	case .N: return {0x31, false}, true
	case .O: return {0x18, false}, true
	case .P: return {0x19, false}, true
	case .Q: return {0x10, false}, true
	case .R: return {0x13, false}, true
	case .S: return {0x1F, false}, true
	case .T: return {0x14, false}, true
	case .U: return {0x16, false}, true
	case .V: return {0x2F, false}, true
	case .W: return {0x11, false}, true
	case .X: return {0x2D, false}, true
	case .Y: return {0x15, false}, true
	case .Z: return {0x2C, false}, true
	case ._1: return {0x02, false}, true
	case ._2: return {0x03, false}, true
	case ._3: return {0x04, false}, true
	case ._4: return {0x05, false}, true
	case ._5: return {0x06, false}, true
	case ._6: return {0x07, false}, true
	case ._7: return {0x08, false}, true
	case ._8: return {0x09, false}, true
	case ._9: return {0x0A, false}, true
	case ._0: return {0x0B, false}, true
	case .RETURN: return {0x1C, false}, true
	case .ESCAPE: return {0x01, false}, true
	case .BACKSPACE: return {0x0E, false}, true
	case .TAB: return {0x0F, false}, true
	case .SPACE: return {0x39, false}, true
	case .MINUS: return {0x0C, false}, true
	case .EQUALS: return {0x0D, false}, true
	case .LEFTBRACKET: return {0x1A, false}, true
	case .RIGHTBRACKET: return {0x1B, false}, true
	case .BACKSLASH: return {0x2B, false}, true
	case .SEMICOLON: return {0x27, false}, true
	case .APOSTROPHE: return {0x28, false}, true
	case .GRAVE: return {0x29, false}, true
	case .COMMA: return {0x33, false}, true
	case .PERIOD: return {0x34, false}, true
	case .SLASH: return {0x35, false}, true
	case .CAPSLOCK: return {0x3A, false}, true
	case .F1: return {0x3B, false}, true
	case .F2: return {0x3C, false}, true
	case .F3: return {0x3D, false}, true
	case .F4: return {0x3E, false}, true
	case .F5: return {0x3F, false}, true
	case .F6: return {0x40, false}, true
	case .F7: return {0x41, false}, true
	case .F8: return {0x42, false}, true
	case .F9: return {0x43, false}, true
	case .F10: return {0x44, false}, true
	case .F11: return {0x57, false}, true
	case .F12: return {0x58, false}, true
	case .SCROLLLOCK: return {0x46, false}, true
	case .NUMLOCKCLEAR: return {0x45, false}, true
	case .LCTRL: return {0x1D, false}, true
	case .LSHIFT: return {0x2A, false}, true
	case .LALT: return {0x38, false}, true
	case .RSHIFT: return {0x36, false}, true
	case .RCTRL: return {0x1D, true}, true
	case .RALT: return {0x38, true}, true
	case .LGUI: return {0x5B, true}, true
	case .RGUI: return {0x5C, true}, true
	case .APPLICATION: return {0x5D, true}, true
	// teclado numérico
	case .KP_DIVIDE: return {0x35, true}, true
	case .KP_MULTIPLY: return {0x37, false}, true
	case .KP_MINUS: return {0x4A, false}, true
	case .KP_PLUS: return {0x4E, false}, true
	case .KP_ENTER: return {0x1C, true}, true
	case .KP_1: return {0x4F, false}, true
	case .KP_2: return {0x50, false}, true
	case .KP_3: return {0x51, false}, true
	case .KP_4: return {0x4B, false}, true
	case .KP_5: return {0x4C, false}, true
	case .KP_6: return {0x4D, false}, true
	case .KP_7: return {0x47, false}, true
	case .KP_8: return {0x48, false}, true
	case .KP_9: return {0x49, false}, true
	case .KP_0: return {0x52, false}, true
	case .KP_PERIOD: return {0x53, false}, true
	// navegación (extendidas)
	case .INSERT: return {0x52, true}, true
	case .HOME: return {0x47, true}, true
	case .PAGEUP: return {0x49, true}, true
	case .DELETE: return {0x53, true}, true
	case .END: return {0x4F, true}, true
	case .PAGEDOWN: return {0x51, true}, true
	case .RIGHT: return {0x4D, true}, true
	case .LEFT: return {0x4B, true}, true
	case .DOWN: return {0x50, true}, true
	case .UP: return {0x48, true}, true
	}
	return {}, false // PrintScreen/Pause y demás: sin mapear en M1
}

// bytes a encolar en el i8042: make o break (bit 7), prefijo E0 si extendida
set1_bytes :: proc(s: Set1, down: bool) -> (buf: [2]u8, n: int) {
	c := s.code
	if !down { c |= 0x80 }
	if s.ext {
		buf[0] = 0xE0
		buf[1] = c
		return buf, 2
	}
	buf[0] = c
	return buf, 1
}
