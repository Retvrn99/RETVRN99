// SPDX-License-Identifier: GPL-3.0-only
package host

import contract "../presentation"
import "core:testing"
import sdl3 "vendor:sdl3"

host_download_test_active :: proc(header: contract.Header) -> contract.Active_Identity {
	return {
		kind = .Gsw,
		display_owner = .Gsw3d,
		sequence = header.sequence,
		lifecycle_generation = header.lifecycle_generation,
		mode_generation = header.mode_generation,
		identity_namespace = header.identity_namespace,
		device_generation = header.device_generation,
		surface = header.surface,
		source_kind = header.source_kind,
		ownership = header.ownership,
	}
}

host_download_test_request :: proc(
	present: contract.Gsw_Present,
) -> contract.Surface_Download_Request {
	header := present.header
	return {
		sequence = 40,
		lifecycle_generation = header.lifecycle_generation,
		mode_generation = header.mode_generation,
		mode_key = header.mode_key,
		identity_namespace = header.identity_namespace,
		device_generation = header.device_generation,
		surface = header.surface,
		format = header.format,
		rect = {1, 2, 2, 2},
		row_pitch = 12,
		byte_capacity = 20,
		completion = {41, header.device_generation},
	}
}

@(test)
host_download_test_tight_pack_and_publish_preserve_caller_padding :: proc(t: ^testing.T) {
	present := host_presentation_test_resident(30)
	request := host_download_test_request(present)
	layout, valid := gsw3d_debug_readback_layout(request.rect.width, request.rect.height)
	if !testing.expect(t, valid) {return}
	source := make([]u8, int(layout.byte_size))
	defer delete(source)
	for i in 0 ..< 8 {
		source[i] = u8(i + 1)
		source[int(layout.row_pitch) + i] = u8(i + 11)
	}
	prepared: [16]u8
	testing.expect(t, host_surface_download_pack_rows(prepared[:], source, request, layout))
	for i in 0 ..< 8 {testing.expect_value(t, prepared[i], source[i])}
	for i in 0 ..< 8 {
		testing.expect_value(t, prepared[8 + i], source[int(layout.row_pitch) + i])
	}

	destination: [20]u8
	for &value in destination {value = 0xCC}
	testing.expect(t, host_surface_download_publish_rows(destination[:], prepared[:], request))
	for i in 0 ..< 8 {testing.expect_value(t, destination[i], source[i])}
	for value in destination[8:12] {testing.expect_value(t, value, u8(0xCC))}
	for i in 0 ..< 8 {
		testing.expect_value(t, destination[12 + i], source[int(layout.row_pitch) + i])
	}

	malformed := layout
	malformed.byte_size = 4
	testing.expect(t, !host_surface_download_pack_rows(prepared[:], source, request, malformed))

	padded := request
	padded.row_pitch = max(u32)
	required, logical, capacity_valid := contract.surface_download_required_capacity(
		padded.rect,
		padded.row_pitch,
	)
	testing.expect(t, capacity_valid)
	testing.expect(t, required > u64(len(prepared)))
	testing.expect_value(t, logical, u64(len(prepared)))
	testing.expect(t, host_surface_download_pack_rows(prepared[:], source, padded, layout))
}

@(test)
host_download_test_context_rejects_replaced_or_destroyed_surface :: proc(t: ^testing.T) {
	present := host_presentation_test_resident(30)
	h := Host {
		presentation_state = {
			accepting = true,
			lifecycle = present.header.lifecycle_generation,
			selector = {active = host_download_test_active(present.header)},
			gsw = present,
		},
	}
	h.gpu_surfaces[0] = {
		live = true,
		generation = present.header.surface.generation,
		descriptor = {
			id = u32(present.header.surface.id),
			width = present.header.surface_extent.width,
			height = present.header.surface_extent.height,
			format = .Bgra8_Unorm,
		},
		gpu_texture = transmute(^sdl3.GPUTexture)(uintptr(1)),
	}
	request := host_download_test_request(present)
	_, surface, valid := host_surface_download_context(&h, request, request.byte_capacity)
	testing.expect(t, valid)
	testing.expect(t, surface == &h.gpu_surfaces[0])

	h.gpu_surfaces[0].generation += 1
	_, _, valid = host_surface_download_context(&h, request, request.byte_capacity)
	testing.expect(t, !valid)
	h.gpu_surfaces[0].generation = present.header.surface.generation
	h.gpu_surfaces[0].live = false
	_, _, valid = host_surface_download_context(&h, request, request.byte_capacity)
	testing.expect(t, !valid)
}

@(test)
host_download_test_completion_and_counters_advance_only_on_success :: proc(t: ^testing.T) {
	present := host_presentation_test_resident(30)
	request := host_download_test_request(present)
	h: Host
	testing.expect_value(
		t,
		host_surface_download_complete(&h, request, 0),
		contract.Surface_Download_Result{},
	)
	testing.expect_value(t, h.presentation_metrics, Host_Presentation_Metrics{})
	result := host_surface_download_complete(&h, request, 16)
	testing.expect_value(t, result.sequence, request.sequence)
	testing.expect_value(t, result.completion, request.completion)
	testing.expect_value(t, result.bytes, u64(16))
	testing.expect_value(t, h.presentation_metrics.readback_requests, u64(1))
	testing.expect_value(t, h.presentation_metrics.readback_bytes, u64(16))

	h.presentation_metrics.readback_requests = max(u64)
	h.presentation_metrics.readback_bytes = max(u64) - 1
	_ = host_surface_download_complete(&h, request, 16)
	testing.expect_value(t, h.presentation_metrics.readback_requests, max(u64))
	testing.expect_value(t, h.presentation_metrics.readback_bytes, max(u64))
}

@(test)
host_download_test_finalization_revalidates_before_exposing_bytes :: proc(t: ^testing.T) {
	present := host_presentation_test_resident(30)
	h := Host {
		presentation_state = {
			accepting = true,
			lifecycle = present.header.lifecycle_generation,
			selector = {active = host_download_test_active(present.header)},
			gsw = present,
		},
		gsw3d_proof_enabled = true,
	}
	texture := transmute(^sdl3.GPUTexture)(uintptr(1))
	h.gpu_surfaces[0] = {
		live = true,
		generation = present.header.surface.generation,
		descriptor = {
			id = u32(present.header.surface.id),
			width = present.header.surface_extent.width,
			height = present.header.surface_extent.height,
			format = .Bgra8_Unorm,
		},
		gpu_texture = texture,
	}
	h.gsw3d_backend.device_generation = present.header.device_generation
	h.gsw3d_executor.live = true
	h.gsw3d_executor.generation = present.header.device_generation
	h.gsw3d_triangle.live = true
	h.gsw3d_triangle.gpu = transmute(^sdl3.GPUDevice)(uintptr(2))
	request := host_download_test_request(present)
	destination: [20]u8
	prepared: [16]u8
	for &value in destination {value = 0xCC}
	for &value, i in prepared {value = u8(i + 1)}
	result := host_surface_download_finalize_current(
		&h,
		request,
		&h.gpu_surfaces[0],
		texture,
		destination[:],
		prepared[:],
	)
	testing.expect_value(t, result.sequence, request.sequence)
	testing.expect_value(t, h.presentation_metrics.readback_requests, u64(1))
	for i in 0 ..< 8 {testing.expect_value(t, destination[i], prepared[i])}
	for value in destination[8:12] {testing.expect_value(t, value, u8(0xCC))}
	for i in 0 ..< 8 {testing.expect_value(t, destination[12 + i], prepared[8 + i])}

	h.presentation_metrics = {}
	for &value in destination {value = 0xCC}
	h.gsw3d_backend.device_generation = contract.generation_next(h.gsw3d_backend.device_generation)
	result = host_surface_download_finalize_current(
		&h,
		request,
		&h.gpu_surfaces[0],
		texture,
		destination[:],
		prepared[:],
	)
	testing.expect_value(t, result, contract.Surface_Download_Result{})
	testing.expect_value(t, h.presentation_metrics, Host_Presentation_Metrics{})
	for value in destination {testing.expect_value(t, value, u8(0xCC))}
}
