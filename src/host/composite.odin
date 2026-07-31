// SPDX-License-Identifier: GPL-3.0-only
package host

// Reproduces on the CPU what the window shows for a legacy frame, so a run with
// no renderer can still publish the composition rather than only the canvas the
// guest drew. The destination comes from `guest_canvas_rect`, the same
// arithmetic the real render path uses, so the border proportion, aspect fit,
// and neutral scaling filter under test here are the ones that ship.

import "core:math"

HOST_COMPOSITE_MAX_PIXELS :: 4_000_000

host_composite_size :: proc(output_width, output_height: int) -> int {
	if output_width <= 0 || output_height <= 0 {return 0}
	if output_width > HOST_COMPOSITE_MAX_PIXELS / output_height {return 0}
	return output_width * output_height
}

@(private = "file")
host_composite_lerp_pixel :: proc(a, b: u32, amount: f32) -> u32 {
	t := clamp(amount, f32(0), f32(1))
	result: u32
	for byte in 0 ..< 4 {
		shift := u32(byte * 8)
		left := f32(a >> shift & 0xFF)
		right := f32(b >> shift & 0xFF)
		channel := u32(clamp(int(math.round(left + (right - left) * t)), 0, 255))
		result |= channel << shift
	}
	return result
}

@(private = "file")
host_composite_bilinear_sample :: proc(canvas: []u32, width, height: int, u, v: f32) -> u32 {
	x := clamp(u, f32(0), f32(1)) * f32(width) - 0.5
	y := clamp(v, f32(0), f32(1)) * f32(height) - 0.5
	raw_x0 := int(math.floor(x))
	raw_y0 := int(math.floor(y))
	tx := x - f32(raw_x0)
	ty := y - f32(raw_y0)
	x0 := clamp(raw_x0, 0, width - 1)
	y0 := clamp(raw_y0, 0, height - 1)
	x1 := clamp(raw_x0 + 1, 0, width - 1)
	y1 := clamp(raw_y0 + 1, 0, height - 1)
	top := host_composite_lerp_pixel(canvas[y0 * width + x0], canvas[y0 * width + x1], tx)
	bottom := host_composite_lerp_pixel(canvas[y1 * width + x0], canvas[y1 * width + x1], tx)
	return host_composite_lerp_pixel(top, bottom, ty)
}

@(private = "file")
host_composite_sharp_uv :: proc(uv: f32, source_size: int, output_scale: f32) -> f32 {
	prescale := max(math.floor(output_scale), f32(1))
	texel := uv * f32(source_size)
	whole := math.floor(texel)
	center_distance := texel - whole - 0.5
	region := 0.5 - 0.5 / prescale
	fraction := (center_distance - clamp(center_distance, -region, region)) * prescale + 0.5
	return (whole + fraction) / f32(source_size)
}

@(private = "file")
host_composite_sample :: proc(
	canvas: []u32,
	width, height: int,
	u, v: f32,
	output_scale_x, output_scale_y: f32,
	filter: Scaling_Filter,
) -> u32 {
	if filter == .Nearest {
		x := min(int(u * f32(width)), width - 1)
		y := min(int(v * f32(height)), height - 1)
		return canvas[y * width + x]
	}
	sample_u, sample_v := u, v
	if filter == .Sharp {
		sample_u = host_composite_sharp_uv(u, width, output_scale_x)
		sample_v = host_composite_sharp_uv(v, height, output_scale_y)
	}
	return host_composite_bilinear_sample(canvas, width, height, sample_u, sample_v)
}

// destination is filled entirely: the surround with the border colour and the
// canvas rectangle with the scaled image. Returns false rather than a partial
// composition when anything does not add up.
host_composite_guest_view :: proc(
	destination: []u32,
	output_width, output_height: int,
	canvas: []u32,
	canvas_width, canvas_height: int,
	aspect_width, aspect_height: int,
	border: Host_Border,
	overscan: u32,
	scaling_filter: Scaling_Filter = .Sharp,
) -> bool {
	needed := host_composite_size(output_width, output_height)
	if needed == 0 || len(destination) < needed {return false}
	if canvas_width <= 0 || canvas_height <= 0 {return false}
	if aspect_width <= 0 || aspect_height <= 0 {return false}
	if canvas_width > max(int) / canvas_height {return false}
	if len(canvas) < canvas_width * canvas_height {return false}

	for index in 0 ..< needed {destination[index] = overscan}

	// No chrome exists here, so the guest view is the whole output.
	rect := guest_canvas_rect(
		aspect_width,
		aspect_height,
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
	geometry := Host_Scaling_Geometry {
		texture_extent = {u32(canvas_width), u32(canvas_height)},
		canvas_extent  = {u32(canvas_width), u32(canvas_height)},
		source         = {0, 0, u32(canvas_width), u32(canvas_height)},
		destination    = {0, 0, u32(canvas_width), u32(canvas_height)},
		canvas_output  = {0, 0, f32(width), f32(height)},
	}
	output_scale_x, output_scale_y := host_scaling_effective_output_scale(geometry)

	for y in 0 ..< height {
		destination_row := (top + y) * output_width + left
		for x in 0 ..< width {
			u := (f32(x) + 0.5) / f32(width)
			v := (f32(y) + 0.5) / f32(height)
			destination[destination_row + x] = host_composite_sample(
				canvas,
				canvas_width,
				canvas_height,
				u,
				v,
				output_scale_x,
				output_scale_y,
				scaling_filter,
			)
		}
	}
	return true
}
