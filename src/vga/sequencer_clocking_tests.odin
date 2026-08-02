// SPDX-License-Identifier: GPL-3.0-only
package vga

import "core:testing"

@(private = "file")
seq_out :: proc(v: ^Vga, index, value: u8) {
	vga_out(v, 0x3C4, index)
	vga_out(v, 0x3C5, value)
	vga_note_content_change(v)
}

// IBM 2-49 to 2-50. Character width, the dot-clock divider, and screen off all
// live in Sequencer 01h and all three are reachable from 3C4h/3C5h.
@(test)
vga_test_sequencer_clocking_mode_drives_width_clock_and_screen_off :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_bochs_legacy_mode(&v, 0x12)
	testing.expect_value(t, v.timing.visible_dots, 640)
	line_ns := v.timing.line_period_ns

	// Nine dot characters widen every character clock by one dot.
	seq_out(&v, 0x01, 0x00)
	testing.expect_value(t, v.timing.visible_dots, 720)
	testing.expect_value(t, v.timing.total_dots, 900)

	seq_out(&v, 0x01, 0x01)
	testing.expect_value(t, v.timing.visible_dots, 640)
	testing.expect_value(t, v.timing.line_period_ns, line_ns)

	// The divider halves the pixel clock, which stretches the line rather than
	// changing how many dots it holds.
	seq_out(&v, 0x01, 0x09)
	testing.expect_value(t, v.timing.total_dots, 800)
	testing.expect_value(t, v.timing.line_period_ns, u64(800) * 1_000_000_000 / (25_175_000 / 2))
	seq_out(&v, 0x01, 0x01)

	// Screen off blanks the output without disturbing the raster underneath it.
	testing.expect(t, video_output_enabled(&v))
	seq_out(&v, 0x01, 0x21)
	testing.expect(t, !video_output_enabled(&v))
	testing.expect_value(t, v.timing.visible_dots, 640)
	testing.expect_value(t, vga_in(&v, 0x3DA) & VGA_STATUS1_DISPLAY_DISABLED, u8(0x01))
	testing.expect_value(t, v.crtc[0x11] & 0x80, u8(0x80))

	seq_out(&v, 0x01, 0x01)
	testing.expect(t, video_output_enabled(&v))
	testing.expect_value(t, vga_in(&v, 0x3DA) & VGA_STATUS1_DISPLAY_DISABLED, u8(0))
}

// IBM 2-54. Odd/even and chain-4 both reroute the CPU's view of the planes and
// both are programmed through the same register the extended-memory bit lives
// in, so this drives all three from 3C5h and reads the planes back.
@(test)
vga_test_sequencer_memory_mode_routes_writes_through_the_ports :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_bochs_legacy_mode(&v, 0x13)
	vga_out(&v, 0x3CE, 0x05)
	vga_out(&v, 0x3CF, 0x40)
	vga_out(&v, 0x3CE, 0x06)
	vga_out(&v, 0x3CF, 0x05)
	seq_out(&v, 0x02, 0x0F)

	// Chain 4 sends consecutive host bytes to consecutive planes.
	seq_out(&v, 0x04, 0x0E)
	for offset in 0 ..< 4 {_ = vga_memory_write_byte(&v, u64(0xA0000 + offset), 0xA0 + u8(offset))}
	for plane in 0 ..< 4 {
		testing.expect_value(t, plane_byte(&v, plane, 0), 0xA0 + u8(plane))
	}

	// Without it the map mask decides, so one host byte reaches every plane.
	seq_out(&v, 0x04, 0x06)
	_ = vga_memory_write_byte(&v, 0xA0004, 0x5A)
	for plane in 0 ..< 4 {
		testing.expect_value(t, plane_byte(&v, plane, 4), u8(0x5A))
	}

	// Odd/even pairs the planes by the address bit instead, and it takes the
	// Graphics 06h chain bit beside the Sequencer one.
	seq_out(&v, 0x04, 0x02)
	vga_out(&v, 0x3CE, 0x06)
	vga_out(&v, 0x3CF, 0x07)
	_ = vga_memory_write_byte(&v, 0xA0010, 0x11)
	_ = vga_memory_write_byte(&v, 0xA0011, 0x22)
	// A0 picks the plane pair and a higher-order bit takes its place in the
	// address, so both host bytes land at plane offset 0x10 rather than half it.
	testing.expect_value(t, plane_byte(&v, 0, 0x10), u8(0x11))
	testing.expect_value(t, plane_byte(&v, 1, 0x10), u8(0x22))
	testing.expect_value(t, plane_byte(&v, 2, 0x10), u8(0x11))
	testing.expect_value(t, plane_byte(&v, 3, 0x10), u8(0x22))
}
