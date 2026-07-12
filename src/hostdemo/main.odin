// SPDX-License-Identifier: GPL-3.0-only
package main

// Manual verification demo for Task 21: renders a fake text snapshot.
// Usage: hostdemo [-auto-close:N]  (N seconds; without it the window stays open)

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import sdl3 "vendor:sdl3"
import "../host"
import "../vga"

demo_snapshot :: proc() -> vga.Text_Snapshot {
	s: vga.Text_Snapshot
	for i in 0 ..< len(s.cells) {
		s.cells[i] = u16(' ') | 0x07 << 8
	}
	text := "RETVRN99"
	// white, yellow-on-blue, green, red bg, magenta bg, blink bit = bright bg
	attrs := [8]u8{0x0F, 0x1E, 0x2A, 0x4F, 0x5F, 0x9E, 0x0F, 0x1E}
	for i in 0 ..< len(text) {
		s.cells[2 * 80 + 4 + i] = u16(text[i]) | u16(attrs[i]) << 8
	}
	// box-drawing run exercises the 9th-column duplication
	for i in 0 ..< 20 {
		s.cells[4 * 80 + 4 + i] = u16(0xC4) | 0x0A << 8
	}
	s.cells[4 * 80 + 3] = u16(0xC3) | 0x0A << 8
	s.cells[4 * 80 + 24] = u16(0xB4) | 0x0A << 8
	s.cursor_row = 6
	s.cursor_col = 4
	s.cursor_on = true
	return s
}

main :: proc() {
	auto_close := -1
	for arg in os.args[1:] {
		if strings.has_prefix(arg, "-auto-close:") {
			auto_close, _ = strconv.parse_int(arg[len("-auto-close:"):])
		}
	}

	h: host.Host
	if !host.host_init(&h) {
		fmt.eprintfln("host_init failed: %s", sdl3.GetError())
		host.host_destroy(&h)
		os.exit(1)
	}

	snap := demo_snapshot()
	start := time.tick_now()
	running := true
	for running {
		ev: sdl3.Event
		for sdl3.PollEvent(&ev) {
			if ev.type == .QUIT {
				running = false
			}
		}
		host.render_text(&h, &snap)
		if auto_close >= 0 && time.duration_seconds(time.tick_since(start)) >= f64(auto_close) {
			running = false
		}
		time.sleep(16 * time.Millisecond)
	}
	host.host_destroy(&h)
	fmt.println("hostdemo: clean exit")
}
