// SPDX-License-Identifier: GPL-3.0-only
package host

import vga "../vga"
import "core:time"
import sdl3 "vendor:sdl3"

host_gsw3d_proof_create_surface :: proc(ctx: rawptr, surface: Gsw3d_Proof_Surface) -> bool {
	h := (^Host)(ctx)
	if h == nil ||
	   surface.id != GSW3D_PROOF_TARGET_ID ||
	   surface.format != 1 ||
	   surface.width != GSW3D_PROOF_WIDTH ||
	   surface.height != GSW3D_PROOF_HEIGHT {return false}
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

host_gsw3d_proof_draw :: proc(ctx: rawptr, draw: ^Gsw3d_Proof_Draw) -> bool {
	h := (^Host)(ctx)
	if h == nil || draw == nil || draw.surface_id != GSW3D_PROOF_TARGET_ID {return false}
	target, format, width, height, ok := host_gpu_surface_render_target(h, draw.surface_id)
	if !ok || width != GSW3D_PROOF_WIDTH || height != GSW3D_PROOF_HEIGHT {return false}
	return gsw3d_triangle_render_sync(
		&h.gsw3d_triangle,
		target,
		format,
		width,
		height,
		&draw.vertices,
		host_gsw3d_proof_clear_color(draw.clear),
	)
}

host_gsw3d_proof_present :: proc(ctx: rawptr, present: ^Gsw3d_Proof_Present) -> bool {
	h := (^Host)(ctx)
	if h == nil || present == nil {return false}
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
			canvas_width = GSW3D_PROOF_WIDTH,
			canvas_height = GSW3D_PROOF_HEIGHT,
			interval = present.interval,
		},
	)
}

host_gsw3d_proof_reset :: proc(ctx: rawptr, generation: u64) -> bool {
	h := (^Host)(ctx)
	if h == nil {return false}
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
