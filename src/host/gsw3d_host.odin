// SPDX-License-Identifier: GPL-3.0-only
package host

import vga "../vga"
import "core:time"
import sdl3 "vendor:sdl3"

host_gsw3d_proof_create_surface :: proc(ctx: rawptr, surface: Gsw3d_Proof_Surface) -> bool {
	h := (^Host)(ctx)
	if h == nil ||
	   surface.id != GSW3D_PROOF_TARGET_ID ||
	   surface.format != vga.GSW3D_SVGA9_PROFILE_TARGET_FORMAT ||
	   !vga.gsw3d_svga9_profile_extent_valid(surface.width, surface.height) {return false}
	return host_gpu_surface_create(
		h,
		{id = surface.id, width = surface.width, height = surface.height, format = .Bgra8_Unorm},
	)
}

host_gsw3d_proof_destroy_surface :: proc(ctx: rawptr, surface_id: u32) -> bool {
	h := (^Host)(ctx)
	return(
		h != nil &&
		surface_id == GSW3D_PROOF_TARGET_ID &&
		host_gpu_surface_destroy(h, surface_id) \
	)
}

@(private = "file")
host_gsw3d_proof_clear_color :: proc(color: u32) -> sdl3.FColor {
	to_float :: proc(value: u32) -> f32 {return f32(value & 0xff) / 255.0}
	return {to_float(color >> 16), to_float(color >> 8), to_float(color), to_float(color >> 24)}
}

@(private = "file")
host_gsw3d_proof_publish_completions :: proc(
	h: ^Host,
	completed: []Gsw3d_Triangle_Completion,
) -> bool {
	if h == nil {return false}
	for completion in completed {
		if !gsw3d_proof_backend_complete(&h.gsw3d_backend, completion) {return false}
	}
	return true
}

@(private = "file")
host_gsw3d_proof_poll_gpu :: proc(h: ^Host) -> bool {
	if h == nil {return false}
	completed: [GSW3D_TRIANGLE_MAX_FRAMES_IN_FLIGHT]Gsw3d_Triangle_Completion
	count, ok := gsw3d_triangle_poll(&h.gsw3d_triangle, completed[:])
	return ok && host_gsw3d_proof_publish_completions(h, completed[:count])
}

host_gsw3d_proof_draw :: proc(ctx: rawptr, draw: ^Gsw3d_Proof_Draw) -> (u64, bool) {
	h := (^Host)(ctx)
	if h == nil ||
	   draw == nil ||
	   draw.surface_id != GSW3D_PROOF_TARGET_ID ||
	   draw.generation == 0 ||
	   !host_gsw3d_proof_poll_gpu(h) {return 0, false}
	if h.gsw3d_triangle.flight_count >= GSW3D_TRIANGLE_MAX_FRAMES_IN_FLIGHT {
		completion, publish, waited := gsw3d_triangle_wait_oldest(&h.gsw3d_triangle)
		if !waited || (publish && !gsw3d_proof_backend_complete(&h.gsw3d_backend, completion)) {
			return 0, false
		}
	}
	target, format, width, height, ok := host_gpu_surface_render_target(h, draw.surface_id)
	if !ok ||
	   width != draw.width ||
	   height != draw.height ||
	   !vga.gsw3d_svga9_profile_extent_valid(width, height) {return 0, false}
	return gsw3d_triangle_render_async(
		&h.gsw3d_triangle,
		target,
		format,
		width,
		height,
		&draw.vertices,
		draw.generation,
		host_gsw3d_proof_clear_color(draw.clear),
	)
}

host_gsw3d_proof_present :: proc(ctx: rawptr, present: ^Gsw3d_Proof_Present) -> bool {
	h := (^Host)(ctx)
	if h == nil ||
	   present == nil ||
	   present.surface_id != GSW3D_PROOF_TARGET_ID ||
	   present.interval != 1 ||
	   present.source.x != 0 ||
	   present.source.y != 0 ||
	   present.destination.x != 0 ||
	   present.destination.y != 0 ||
	   present.source.width != present.destination.width ||
	   present.source.height != present.destination.height ||
	   !vga.gsw3d_svga9_profile_extent_valid(
			   present.destination.width,
			   present.destination.height,
		   ) {return false}
	return host_gpu_surface_present(
		h,
		{
			surface_id = present.surface_id,
			source = {
				present.source.x,
				present.source.y,
				present.source.width,
				present.source.height,
			},
			destination = {
				present.destination.x,
				present.destination.y,
				present.destination.width,
				present.destination.height,
			},
			canvas_width = present.destination.width,
			canvas_height = present.destination.height,
			interval = present.interval,
		},
	)
}

host_gsw3d_proof_reset :: proc(ctx: rawptr, generation: u64) -> bool {
	h := (^Host)(ctx)
	if h == nil {return false}
	gsw3d_triangle_discard_other_generations(&h.gsw3d_triangle, generation)
	if host_gpu_surface_texture(h, GSW3D_PROOF_TARGET_ID) != nil &&
	   !host_gpu_surface_destroy(h, GSW3D_PROOF_TARGET_ID) {return false}
	if h.gpu_present.surface_id == GSW3D_PROOF_TARGET_ID {h.gpu_present = {}}
	h.has_frame = false
	return true
}

host_gsw3d_proof_enable :: proc(h: ^Host) -> bool {
	if h == nil || h.gpu == nil || h.gsw3d_proof_enabled {return false}
	if !gsw3d_triangle_renderer_init(&h.gsw3d_triangle, h.gpu) {return false}
	if !gsw3d_proof_executor_init(
		&h.gsw3d_executor,
		{
			ctx = h,
			create_surface = host_gsw3d_proof_create_surface,
			destroy_surface = host_gsw3d_proof_destroy_surface,
			draw = host_gsw3d_proof_draw,
			present = host_gsw3d_proof_present,
			reset = host_gsw3d_proof_reset,
		},
	) {
		gsw3d_triangle_renderer_destroy(&h.gsw3d_triangle)
		return false
	}
	h.gsw3d_proof_enabled = true
	return true
}

host_gsw3d_proof_machine_backend :: proc(h: ^Host) -> (vga.Gsw3d_Backend, bool) {
	if h == nil ||
	   !h.gsw3d_proof_enabled ||
	   !gsw3d_proof_backend_init(&h.gsw3d_backend, &h.gsw3d_bridge) {return {}, false}
	return gsw3d_proof_backend_descriptor(&h.gsw3d_backend), true
}

host_gsw3d_proof_drain :: proc(h: ^Host) -> Gsw3d_Bridge_Drain_Result {
	if h == nil || !h.gsw3d_proof_enabled {return {}}
	if !host_gsw3d_proof_poll_gpu(h) {return {failed = 1}}
	return gsw3d_proof_backend_drain(
		&h.gsw3d_backend,
		&h.gsw3d_executor,
		{
			max_requests = 8,
			max_budget = GSW3D_PROOF_MAX_BRIDGE_BUDGET,
			followup_wait = 100 * time.Microsecond,
		},
	)
}
