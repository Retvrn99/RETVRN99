// SPDX-License-Identifier: GPL-3.0-only
package host

import "core:testing"
import sdl3 "vendor:sdl3"

@(test)
host_gpu_surface_test_formats_and_budget_are_bounded :: proc(t: ^testing.T) {
	descriptor := Host_Gpu_Surface_Descriptor {
		id     = 7,
		width  = 1600,
		height = 1200,
		format = .Bgra8_Unorm,
	}
	format, bytes_per_pixel, known := host_gpu_surface_pixel_format(descriptor.format)
	testing.expect(t, known)
	testing.expect_value(t, format, sdl3.PixelFormat.BGRA32)
	testing.expect_value(t, bytes_per_pixel, u32(4))
	byte_size, valid := host_gpu_surface_byte_size(descriptor)
	testing.expect(t, valid)
	testing.expect_value(t, byte_size, u64(1600 * 1200 * 4))
	testing.expect(
		t,
		host_gpu_surface_can_allocate(HOST_GPU_SURFACE_BUDGET_BYTES - byte_size, descriptor),
	)
	testing.expect(
		t,
		!host_gpu_surface_can_allocate(HOST_GPU_SURFACE_BUDGET_BYTES - byte_size + 1, descriptor),
	)
	testing.expect(
		t,
		host_gpu_surface_can_replace(
			HOST_GPU_SURFACE_BUDGET_BYTES - byte_size,
			byte_size,
			descriptor,
		),
	)
	testing.expect(
		t,
		!host_gpu_surface_can_replace(HOST_GPU_SURFACE_BUDGET_BYTES, byte_size, descriptor),
	)
	testing.expect(t, !host_gpu_surface_can_replace(byte_size - 1, byte_size, descriptor))

	descriptor.id = 0
	_, valid = host_gpu_surface_byte_size(descriptor)
	testing.expect(t, !valid)
	descriptor.id = 7
	descriptor.width = HOST_GPU_SURFACE_MAX_DIMENSION + 1
	_, valid = host_gpu_surface_byte_size(descriptor)
	testing.expect(t, !valid)

	unsupported_formats := [?]Host_Gpu_Surface_Format {
		Host_Gpu_Surface_Format.Rgb565_Unorm,
		Host_Gpu_Surface_Format.Argb1555_Unorm,
		Host_Gpu_Surface_Format.Argb4444_Unorm,
	}
	for unsupported in unsupported_formats {
		descriptor.width = 640
		descriptor.format = unsupported
		_, valid = host_gpu_surface_byte_size(descriptor)
		testing.expect(t, !valid)
	}
}

@(test)
host_gpu_surface_test_present_rejects_overflow_and_out_of_range_rectangles :: proc(t: ^testing.T) {
	descriptor := Host_Gpu_Surface_Descriptor{9, 1920, 1200, .Bgra8_Unorm}
	present := Host_Gpu_Present {
		surface_id    = 9,
		source        = {0, 0, 1920, 1200},
		destination   = {0, 0, 1600, 1200},
		canvas_width  = 1600,
		canvas_height = 1200,
		interval      = 1,
	}
	testing.expect(t, host_gpu_present_valid(present, descriptor))

	present.source.x = 1919
	present.source.width = 2
	testing.expect(t, !host_gpu_present_valid(present, descriptor))
	present.source = {0xFFFF_FFFF, 0, 2, 1200}
	testing.expect(t, !host_gpu_present_valid(present, descriptor))
	present.source = {0, 0, 1920, 1200}
	present.destination.y = 1199
	present.destination.height = 2
	testing.expect(t, !host_gpu_present_valid(present, descriptor))
	present.destination = {0, 0, 1600, 1200}
	present.interval = 0
	testing.expect(t, !host_gpu_present_valid(present, descriptor))
	present.interval = 2
	testing.expect(t, !host_gpu_present_valid(present, descriptor))
}

@(test)
host_gpu_surface_test_destination_maps_inside_guest_view :: proc(t: ^testing.T) {
	present := Host_Gpu_Present {
		surface_id    = 1,
		source        = {0, 0, 640, 480},
		destination   = {160, 120, 320, 240},
		canvas_width  = 640,
		canvas_height = 480,
		interval      = HOST_GPU_PRESENT_INTERVAL,
	}
	destination := host_gpu_present_destination(sdl3.FRect{100, 50, 1280, 960}, present)
	testing.expect_value(t, destination, sdl3.FRect{420, 290, 640, 480})
}

@(test)
host_gpu_surface_test_present_selects_resident_texture_without_readback :: proc(t: ^testing.T) {
	h: Host
	h.gpu_surfaces[0] = {
		live           = true,
		descriptor     = {23, 1024, 768, .Bgra8_Unorm},
		render_texture = transmute(^sdl3.Texture)(uintptr(1)),
	}
	present := Host_Gpu_Present {
		surface_id    = 23,
		source        = {0, 0, 1024, 768},
		destination   = {0, 0, 1024, 768},
		canvas_width  = 1024,
		canvas_height = 768,
		interval      = HOST_GPU_PRESENT_INTERVAL,
	}
	testing.expect(t, host_gpu_surface_present(&h, present))
	testing.expect_value(t, h.gpu_present.surface_id, u32(23))
	testing.expect_value(t, h.gpu_direct_presents, u64(1))
	texture, source, has_source, selected := host_active_texture(&h)
	testing.expect(t, texture == h.gpu_surfaces[0].render_texture)
	testing.expect(t, has_source)
	testing.expect_value(t, source, sdl3.FRect{0, 0, 1024, 768})
	testing.expect(t, selected != nil)
}

@(test)
host_gpu_surface_test_selected_resident_generation_must_match_live_surface :: proc(t: ^testing.T) {
	h: Host
	h.gpu_surfaces[0] = {
		live           = true,
		generation     = 2,
		descriptor     = {23, 1024, 768, .Bgra8_Unorm},
		render_texture = transmute(^sdl3.Texture)(uintptr(1)),
	}
	h.gpu_present = {
		surface_id    = 23,
		source        = {0, 0, 1024, 768},
		destination   = {0, 0, 1024, 768},
		canvas_width  = 1024,
		canvas_height = 768,
		interval      = HOST_GPU_PRESENT_INTERVAL,
	}
	h.presentation_state.selector.active = {
		kind = .Gsw,
		display_owner = .Gsw3d,
		surface = {id = 23, generation = 1},
		source_kind = .Gsw_Resident,
		identity_namespace = .Gsw3d,
	}

	texture, _, has_source, selected := host_active_texture(&h)
	testing.expect(t, texture == nil)
	testing.expect(t, !has_source)
	testing.expect(t, selected == nil)

	h.presentation_state.selector.active.surface.generation = 2
	texture, _, has_source, selected = host_active_texture(&h)
	testing.expect(t, texture == h.gpu_surfaces[0].render_texture)
	testing.expect(t, has_source)
	testing.expect(t, selected != nil)
}

@(test)
host_gpu_surface_test_new_legacy_frame_takes_display_ownership :: proc(t: ^testing.T) {
	h: Host
	h.gpu_present = {
		surface_id    = 23,
		source        = {0, 0, 1024, 768},
		destination   = {0, 0, 1024, 768},
		canvas_width  = 1024,
		canvas_height = 768,
		interval      = HOST_GPU_PRESENT_INTERVAL,
	}
	h.aspect_width = 1024
	h.aspect_height = 768
	host_cpu_frame_metadata_publish(&h, 4, 3)
	testing.expect_value(t, h.gpu_present.surface_id, u32(0))
	testing.expect_value(t, h.aspect_width, 4)
	testing.expect_value(t, h.aspect_height, 3)
	testing.expect(t, h.has_frame)

	host_clear_frame(&h)
	testing.expect_value(t, h.gpu_present.surface_id, u32(0))
	testing.expect(t, !h.has_frame)
}
