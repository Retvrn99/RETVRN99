// SPDX-License-Identifier: GPL-3.0-only
package vga

import "core:testing"

// Maximum Scan Line and scan doubling do not compose multiplicatively.
//
// In CGA-compatibility graphics modes the Maximum Scan Line field indexes the
// interleaved CGA banks rather than repeating scan lines, so modes 04h, 05h,
// and 06h are programmed with a maximum scan line of 1 and scan doubling on
// while still showing 200 source lines across 400 physical ones. Multiplying
// the two would halve those modes to 100 lines.
//
// The register combinations below are the ones the pinned VGABIOS actually
// programs, captured by `test_machine_vgabios_int10_mode_matrix`.
@(test)
vga_test_graphics_scan_factor_matches_firmware_combinations :: proc(t: ^testing.T) {
	Case :: struct {
		modes:            string,
		maximum_scan_line: u8,
		scan_double:      bool,
		factor:           int,
	}
	cases := [?]Case {
		// 04h, 05h, 06h: banked CGA graphics doubled to 400 lines.
		{"04h/05h/06h", 1, true, 2},
		// 0Dh, 0Eh: planar 200 line modes doubled to 400.
		{"0Dh/0Eh", 0, true, 2},
		// 13h: 200 source lines stretched by the maximum scan line instead.
		{"13h", 1, false, 2},
		// 0Fh, 10h, 11h, 12h: no stretching at all.
		{"0Fh/10h/11h/12h", 0, false, 1},
	}
	for entry in cases {
		v: Vga
		backing := test_vga_init(t, &v)
		defer delete(backing)
		defer vga_destroy(&v)
		v.crtc[0x09] = entry.maximum_scan_line | (entry.scan_double ? 0x80 : 0)
		actual := legacy_graphics_scan_factor(&v)
		if actual != entry.factor {
			testing.expectf(
				t,
				false,
				"modes %s with maximum scan line %d and doubling %v expected factor %d, got %d",
				entry.modes,
				entry.maximum_scan_line,
				entry.scan_double,
				entry.factor,
				actual,
			)
		}
	}
}
