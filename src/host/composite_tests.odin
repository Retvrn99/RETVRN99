// SPDX-License-Identifier: GPL-3.0-only
package host

import "core:slice"
import "core:testing"

@(private = "file")
OVERSCAN :: u32(0xFF102030)

// Without a border the canvas fills its aspect fit exactly, so the composition
// is the letterboxed image and nothing else. This is the control: whatever the
// border does later, it has to differ from this.
@(test)
host_test_composite_without_a_border_is_the_plain_fit :: proc(t: ^testing.T) {
	canvas := []u32{0xFF010101, 0xFF020202, 0xFF030303, 0xFF040404}
	destination := make([]u32, 64 * 32)
	defer delete(destination)
	testing.expect(
		t,
		host_composite_guest_view(destination, 64, 32, canvas, 2, 2, 2, 2, {}, OVERSCAN),
	)

	// 2:2 into 64x32 is height limited, so the image is 32 wide and centred.
	testing.expect_value(t, destination[0], OVERSCAN)
	testing.expect_value(t, destination[16 * 64 + 32], canvas[3])
	testing.expect_value(t, destination[0 * 64 + 16], canvas[0])
	testing.expect_value(t, destination[16 * 64 + 16], canvas[2])
}

// A border on one side only moves the image toward the other side, which is the
// whole point: stock modes leave a leading border and no trailing one.
@(test)
host_test_composite_border_shifts_the_image :: proc(t: ^testing.T) {
	canvas := []u32{0xFF010101, 0xFF020202, 0xFF030303, 0xFF040404}
	plain := make([]u32, 64 * 32)
	defer delete(plain)
	bordered := make([]u32, 64 * 32)
	defer delete(bordered)
	testing.expect(t, host_composite_guest_view(plain, 64, 32, canvas, 2, 2, 2, 2, {}, OVERSCAN))
	testing.expect(
		t,
		host_composite_guest_view(
			bordered,
			64,
			32,
			canvas,
			2,
			2,
			2,
			2,
			{left = 1, right = 0, top = 0, bottom = 0},
			OVERSCAN,
		),
	)

	differences := 0
	for index in 0 ..< len(plain) {
		if plain[index] != bordered[index] {differences += 1}
	}
	testing.expect(t, differences > 0)

	// Every pixel outside the image is the border colour, both before and after.
	testing.expect_value(t, bordered[0], OVERSCAN)
	testing.expect_value(t, bordered[len(bordered) - 1], OVERSCAN)
}

// The destination is filled completely. A composition that left gaps would show
// whatever the buffer held from the previous capture.
@(test)
host_test_composite_fills_the_whole_destination :: proc(t: ^testing.T) {
	canvas := []u32{0xFF010101, 0xFF020202, 0xFF030303, 0xFF040404}
	destination := make([]u32, 40 * 24)
	defer delete(destination)
	for &pixel in destination {pixel = 0xDEADBEEF}
	testing.expect(
		t,
		host_composite_guest_view(
			destination,
			40,
			24,
			canvas,
			2,
			2,
			2,
			2,
			{left = 2, right = 1, top = 1, bottom = 3},
			OVERSCAN,
		),
	)
	for pixel in destination {testing.expect(t, pixel != 0xDEADBEEF)}
}

// Nothing that does not add up produces a partial image.
@(test)
host_test_composite_refuses_impossible_work :: proc(t: ^testing.T) {
	canvas := []u32{0xFF010101, 0xFF020202, 0xFF030303, 0xFF040404}
	destination := make([]u32, 16 * 16)
	defer delete(destination)
	// Destination too small for the stated output.
	testing.expect(
		t,
		!host_composite_guest_view(destination, 64, 32, canvas, 2, 2, 2, 2, {}, OVERSCAN),
	)
	// Canvas too small for its stated geometry.
	testing.expect(
		t,
		!host_composite_guest_view(destination, 16, 16, canvas, 4, 4, 4, 4, {}, OVERSCAN),
	)
	// Geometry that describes no image at all.
	testing.expect(
		t,
		!host_composite_guest_view(destination, 16, 16, canvas, 0, 2, 1, 1, {}, OVERSCAN),
	)
	testing.expect(
		t,
		!host_composite_guest_view(destination, 0, 16, canvas, 2, 2, 2, 2, {}, OVERSCAN),
	)
	testing.expect_value(t, host_composite_size(0, 10), 0)
	testing.expect_value(t, host_composite_size(4, 5), 20)
}

// The default window client area is what a capture is composed at, so it has to
// stay within the artifact writer's pixel cap.
@(test)
host_test_composite_default_size_is_within_the_artifact_cap :: proc(t: ^testing.T) {
	size := host_composite_size(WIN_W, WIN_H)
	testing.expect(t, size > 0)
	testing.expect(t, size <= 2_000_000)
}

@(test)
host_test_composite_uses_display_aspect_without_resizing_raw_canvas :: proc(t: ^testing.T) {
	canvas := []u32 {
		0xFF010101,
		0xFF020202,
		0xFF030303,
		0xFF040404,
		0xFF050505,
		0xFF060606,
		0xFF070707,
		0xFF080808,
	}
	destination := make([]u32, 16 * 16)
	defer delete(destination)
	testing.expect(
		t,
		host_composite_guest_view(destination, 16, 16, canvas, 4, 2, 4, 3, {}, OVERSCAN),
	)
	testing.expect_value(t, destination[1 * 16], OVERSCAN)
	testing.expect(t, destination[2 * 16] != OVERSCAN)
	testing.expect_value(t, canvas[0], u32(0xFF010101))
	testing.expect_value(t, len(canvas), 8)
}

@(test)
host_test_composite_uses_selected_scaler_without_overshoot :: proc(t: ^testing.T) {
	canvas := []u32{0xFF404040, 0xFFC0C0C0}
	sharp := make([]u32, 5 * 3)
	defer delete(sharp)
	linear := make([]u32, 5 * 3)
	defer delete(linear)
	nearest := make([]u32, 5 * 3)
	defer delete(nearest)
	cases := []struct {
		filter: Scaling_Filter,
		output: []u32,
	}{{.Sharp, sharp}, {.Linear, linear}, {.Nearest, nearest}}
	for test_case in cases {
		testing.expect(
			t,
			host_composite_guest_view(
				test_case.output,
				5,
				3,
				canvas,
				2,
				1,
				2,
				1,
				{},
				OVERSCAN,
				test_case.filter,
			),
		)
	}
	testing.expect(t, !slice.equal(sharp, linear))
	testing.expect(t, !slice.equal(sharp, nearest))
	testing.expect_value(t, sharp[0], canvas[0])
	testing.expect_value(t, sharp[4], canvas[1])
	for pixel in sharp {
		channel := pixel & 0xFF
		testing.expect(t, channel >= 0x40 && channel <= 0xC0)
	}
	for pixel in nearest {
		testing.expect(t, pixel == canvas[0] || pixel == canvas[1])
	}
}
