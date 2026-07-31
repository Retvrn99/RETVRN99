// SPDX-License-Identifier: GPL-3.0-only
package host

import contract "../presentation"
import "core:sync"
import sdl3 "vendor:sdl3"

host_surface_download_context :: proc(
	h: ^Host,
	request: contract.Surface_Download_Request,
	destination_capacity: u64,
) -> (
	contract.Surface_Download_Context,
	^Host_Gpu_Surface,
	bool,
) {
	if h == nil ||
	   !host_presentation_state(h).accepting ||
	   host_presentation_state(h).selector.active.source_kind != .Gsw_Resident ||
	   host_presentation_state(h).gsw.header.sequence == 0 {return {}, nil, false}
	header := host_presentation_state(h).gsw.header
	if header.surface.id > u64(max(u32)) {return {}, nil, false}
	if !host_presentation_active_matches(host_presentation_state(h).selector.active, header) {
		return {}, nil, false
	}
	surface := host_gpu_surface_find(h, u32(header.surface.id))
	if surface == nil ||
	   surface.gpu_texture == nil ||
	   surface.generation != header.surface.generation ||
	   surface.descriptor.width != header.surface_extent.width ||
	   surface.descriptor.height != header.surface_extent.height {return {}, nil, false}
	pixel_format := contract.Pixel_Format.Invalid
	#partial switch surface.descriptor.format {
	case .Bgra8_Unorm:
		pixel_format = .Bgra_8888
	case .Rgba8_Unorm:
		pixel_format = .Rgba_8888
	case:
		return {}, nil, false
	}
	current := contract.Surface_Download_Context {
		lifecycle_generation = header.lifecycle_generation,
		mode_generation      = header.mode_generation,
		mode_key             = header.mode_key,
		identity_namespace   = header.identity_namespace,
		device_generation    = header.device_generation,
		surface              = header.surface,
		format               = pixel_format,
		surface_extent       = header.surface_extent,
		destination_capacity = destination_capacity,
	}
	return current, surface, contract.validate_surface_download(request, current) == .Valid
}

host_surface_download_pack_rows :: proc(
	destination, source: []u8,
	request: contract.Surface_Download_Request,
	layout: Gsw3d_Debug_Readback_Layout,
) -> bool {
	_, logical, valid := contract.surface_download_required_capacity(
		request.rect,
		request.row_pitch,
	)
	row_bytes := u64(request.rect.width) * 4
	source_rows := u64(request.rect.height - 1)
	if source_rows != 0 && u64(layout.row_pitch) > max(u64) / source_rows {return false}
	source_required := source_rows * u64(layout.row_pitch)
	if source_required > max(u64) - row_bytes {return false}
	source_required += row_bytes
	if !valid ||
	   logical != u64(len(destination)) ||
	   u64(layout.row_pitch) < row_bytes ||
	   source_required > u64(layout.byte_size) ||
	   source_required > u64(len(source)) ||
	   u64(layout.byte_size) > u64(len(source)) {return false}
	for y in 0 ..< int(request.rect.height) {
		destination_start := y * int(row_bytes)
		source_start := y * int(layout.row_pitch)
		copy(
			destination[destination_start:][:int(row_bytes)],
			source[source_start:][:int(row_bytes)],
		)
	}
	return true
}

host_surface_download_publish_rows :: proc(
	destination, prepared: []u8,
	request: contract.Surface_Download_Request,
) -> bool {
	required, logical, valid := contract.surface_download_required_capacity(
		request.rect,
		request.row_pitch,
	)
	row_bytes := u64(request.rect.width) * 4
	if !valid ||
	   required > u64(len(destination)) ||
	   logical != u64(len(prepared)) ||
	   row_bytes > u64(max(int)) {return false}
	for y in 0 ..< int(request.rect.height) {
		destination_start := y * int(request.row_pitch)
		prepared_start := y * int(row_bytes)
		copy(
			destination[destination_start:][:int(row_bytes)],
			prepared[prepared_start:][:int(row_bytes)],
		)
	}
	return true
}

host_surface_download_complete :: proc(
	h: ^Host,
	request: contract.Surface_Download_Request,
	logical_bytes: u64,
) -> contract.Surface_Download_Result {
	if h == nil || logical_bytes == 0 {return {}}
	host_presentation_metric_add(&h.presentation_metrics.readback_requests, 1)
	host_presentation_metric_add(&h.presentation_metrics.readback_bytes, logical_bytes)
	return {sequence = request.sequence, completion = request.completion, bytes = logical_bytes}
}

@(private = "file")
host_surface_download_still_current :: proc(
	h: ^Host,
	request: contract.Surface_Download_Request,
	surface: ^Host_Gpu_Surface,
	texture: ^sdl3.GPUTexture,
) -> bool {
	if h == nil || surface == nil || texture == nil {return false}
	current, found, valid := host_surface_download_context(h, request, request.byte_capacity)
	if !valid || found != surface || found.gpu_texture != texture {return false}
	sync.lock(&h.gsw3d_backend.mu)
	defer sync.unlock(&h.gsw3d_backend.mu)
	return(
		!h.gsw3d_backend.stopped &&
		!h.gsw3d_backend.cleanup_required &&
		h.gsw3d_backend.device_generation == current.device_generation &&
		h.gsw3d_executor.live &&
		h.gsw3d_executor.generation == current.device_generation \
	)
}

@(private = "package")
host_surface_download_finalize_current :: proc(
	h: ^Host,
	request: contract.Surface_Download_Request,
	surface: ^Host_Gpu_Surface,
	texture: ^sdl3.GPUTexture,
	destination, prepared: []u8,
) -> contract.Surface_Download_Result {
	required, logical_bytes, layout_valid := contract.surface_download_required_capacity(
		request.rect,
		request.row_pitch,
	)
	if h == nil ||
	   surface == nil ||
	   texture == nil ||
	   !layout_valid ||
	   required == 0 ||
	   required > u64(len(destination)) ||
	   logical_bytes == 0 ||
	   logical_bytes != u64(len(prepared)) ||
	   logical_bytes > u64(max(int)) {return {}}
	current, found, valid := host_surface_download_context(h, request, u64(len(destination)))
	if !valid || found != surface || found.gpu_texture != texture {return {}}
	sync.lock(&h.gsw3d_backend.mu)
	defer sync.unlock(&h.gsw3d_backend.mu)
	if h.gsw3d_backend.stopped ||
	   h.gsw3d_backend.cleanup_required ||
	   h.gsw3d_backend.device_generation != current.device_generation ||
	   !h.gsw3d_executor.live ||
	   h.gsw3d_executor.generation != current.device_generation ||
	   !h.gsw3d_proof_enabled ||
	   !h.gsw3d_triangle.live ||
	   h.gsw3d_triangle.gpu == nil ||
	   h.gsw3d_triangle.flight_count != 0 {return {}}
	if !host_surface_download_publish_rows(destination, prepared, request) {return {}}
	return host_surface_download_complete(h, request, logical_bytes)
}

host_surface_download :: proc(
	h: ^Host,
	request: contract.Surface_Download_Request,
	destination: []u8,
) -> contract.Surface_Download_Result {
	current, surface, valid := host_surface_download_context(h, request, u64(len(destination)))
	if !valid ||
	   h == nil ||
	   !sdl3.IsMainThread() ||
	   !h.gsw3d_proof_enabled ||
	   !h.gsw3d_triangle.live ||
	   h.gsw3d_triangle.gpu == nil ||
	   h.gsw3d_triangle.flight_count != 0 {return {}}
	sync.lock(&h.gsw3d_backend.mu)
	backend_current :=
		!h.gsw3d_backend.stopped &&
		!h.gsw3d_backend.cleanup_required &&
		h.gsw3d_backend.device_generation == current.device_generation &&
		h.gsw3d_executor.live &&
		h.gsw3d_executor.generation == current.device_generation
	sync.unlock(&h.gsw3d_backend.mu)
	if !backend_current {return {}}
	texture := surface.gpu_texture
	layout, layout_valid := gsw3d_debug_readback_layout(request.rect.width, request.rect.height)
	if !layout_valid {return {}}
	gpu := h.gsw3d_triangle.gpu
	download := sdl3.CreateGPUTransferBuffer(
		gpu,
		sdl3.GPUTransferBufferCreateInfo{usage = .DOWNLOAD, size = layout.byte_size},
	)
	if download == nil {return {}}
	defer sdl3.ReleaseGPUTransferBuffer(gpu, download)

	command_buffer := sdl3.AcquireGPUCommandBuffer(gpu)
	if command_buffer == nil {return {}}
	submitted := false
	defer if !submitted {_ = sdl3.CancelGPUCommandBuffer(command_buffer)}
	copy_pass := sdl3.BeginGPUCopyPass(command_buffer)
	if copy_pass == nil {return {}}
	sdl3.DownloadFromGPUTexture(
		copy_pass,
		sdl3.GPUTextureRegion {
			texture = texture,
			x = request.rect.x,
			y = request.rect.y,
			w = request.rect.width,
			h = request.rect.height,
			d = 1,
		},
		sdl3.GPUTextureTransferInfo {
			transfer_buffer = download,
			pixels_per_row = layout.pixels_per_row,
			rows_per_layer = request.rect.height,
		},
	)
	sdl3.EndGPUCopyPass(copy_pass)
	submitted = true
	fence := sdl3.SubmitGPUCommandBufferAndAcquireFence(command_buffer)
	if fence == nil {return {}}
	defer sdl3.ReleaseGPUFence(gpu, fence)
	fences := [1]^sdl3.GPUFence{fence}
	if !sdl3.WaitForGPUFences(gpu, true, raw_data(fences[:]), 1) {return {}}
	if !host_surface_download_still_current(h, request, surface, texture) {return {}}

	mapped := sdl3.MapGPUTransferBuffer(gpu, download, false)
	if mapped == nil {return {}}
	defer sdl3.UnmapGPUTransferBuffer(gpu, download)
	source := ([^]u8)(mapped)[:int(layout.byte_size)]
	_, logical_bytes, required_valid := contract.surface_download_required_capacity(
		request.rect,
		request.row_pitch,
	)
	if !required_valid || logical_bytes == 0 || logical_bytes > u64(max(int)) {return {}}
	prepared := make([]u8, int(logical_bytes))
	defer delete(prepared)
	if !host_surface_download_pack_rows(prepared, source, request, layout) {return {}}
	return host_surface_download_finalize_current(
		h,
		request,
		surface,
		texture,
		destination,
		prepared,
	)
}
