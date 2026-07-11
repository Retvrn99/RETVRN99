// SPDX-License-Identifier: GPL-3.0-only
package vga

import "core:testing"

@(test)
vga_test_snapshot_cursor :: proc(t: ^testing.T) {
	v: Vga
	// cursor en offset 81 -> fila 1, columna 1
	vga_out(&v, 0x3D4, 0x0E)
	vga_out(&v, 0x3D5, 0x00)
	vga_out(&v, 0x3D4, 0x0F)
	vga_out(&v, 0x3D5, 81)
	ram := make([]u8, 1024*1024)
	defer delete(ram)
	ram[0xB8000] = 'H'
	ram[0xB8001] = 0x07
	s := vga_snapshot(&v, ram)
	testing.expect_value(t, s.cells[0], u16(0x0748))
	testing.expect_value(t, s.cursor_row, 1)
	testing.expect_value(t, s.cursor_col, 1)
	testing.expect(t, s.cursor_on)
}

@(test)
vga_test_status_toggle :: proc(t: ^testing.T) {
	v: Vga
	a := vga_in(&v, 0x3DA)
	b := vga_in(&v, 0x3DA)
	// lecturas alternas difieren en bit3|bit0 (retrazado vertical)
	testing.expect_value(t, (a ~ b) & 0x09, u8(0x09))
}
