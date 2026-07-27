// SPDX-License-Identifier: GPL-3.0-only
package host

// Reproduces on the CPU what the window shows for a legacy frame, so a run with
// no renderer can still publish the composition rather than only the canvas the
// guest drew. The destination comes from `guest_canvas_rect`, the same
// arithmetic the real render path uses, so the border proportion and the aspect
// fit under test here are the ones that ship. Only the pixel copy is separate,
// and it samples nearest, which is what the renderer does at its default scale
// mode.

import "core:math"

HOST_COMPOSITE_MAX_PIXELS :: 4_000_000

host_composite_size :: proc(output_width, output_height: int) -> int {
	if output_width <= 0 || output_height <= 0 {return 0}
	if output_width > HOST_COMPOSITE_MAX_PIXELS / output_height {return 0}
	return output_width * output_height
}

// destination is filled entirely: the surround with the border colour and the
// canvas rectangle with the scaled image. Returns false rather than a partial
// composition when anything does not add up.
host_composite_guest_view :: proc(
	destination: []u32,
	output_width, output_height: int,
	canvas: []u32,
	canvas_width, canvas_height: int,
	border: Host_Border,
	overscan: u32,
) -> bool {
	needed := host_composite_size(output_width, output_height)
	if needed == 0 || len(destination) < needed {return false}
	if canvas_width <= 0 || canvas_height <= 0 {return false}
	if canvas_width > max(int) / canvas_height {return false}
	if len(canvas) < canvas_width * canvas_height {return false}

	for index in 0 ..< needed {destination[index] = overscan}

	// No chrome exists here, so the guest view is the whole output.
	rect := guest_canvas_rect(
		canvas_width,
		canvas_height,
		border,
		output_width,
		output_height,
		{},
	)
	left := clamp(int(math.round(rect.x)), 0, output_width)
	top := clamp(int(math.round(rect.y)), 0, output_height)
	right := clamp(left + int(math.round(rect.w)), left, output_width)
	bottom := clamp(top + int(math.round(rect.h)), top, output_height)
	width := right - left
	height := bottom - top
	if width <= 0 || height <= 0 {return true}

	for y in 0 ..< height {
		source_row := min(y * canvas_height / height, canvas_height - 1) * canvas_width
		destination_row := (top + y) * output_width + left
		for x in 0 ..< width {
			source_x := min(x * canvas_width / width, canvas_width - 1)
			destination[destination_row + x] = canvas[source_row + source_x]
		}
	}
	return true
}
