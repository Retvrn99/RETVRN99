// SPDX-License-Identifier: GPL-3.0-only
package presentation

import "core:testing"

download_test_request :: proc() -> (Surface_Download_Request, Surface_Download_Context) {
	key := Mode_Key {
		format         = .Bgra_8888,
		surface_extent = {640, 480},
		canvas_extent  = {640, 480},
		source         = {0, 0, 640, 480},
		destination    = {0, 0, 640, 480},
	}
	request := Surface_Download_Request {
		sequence             = 8,
		lifecycle_generation = 2,
		mode_generation      = 3,
		mode_key             = key,
		identity_namespace   = .Gsw3d,
		device_generation    = 4,
		surface              = {5, 6},
		format               = .Bgra_8888,
		rect                 = {10, 20, 3, 2},
		row_pitch            = 16,
		byte_capacity        = 28,
		completion           = {9, 4},
	}
	current := Surface_Download_Context {
		lifecycle_generation = request.lifecycle_generation,
		mode_generation      = request.mode_generation,
		mode_key             = key,
		identity_namespace   = request.identity_namespace,
		device_generation    = request.device_generation,
		surface              = request.surface,
		format               = request.format,
		surface_extent       = key.surface_extent,
		destination_capacity = request.byte_capacity,
	}
	return request, current
}

@(test)
download_test_validates_exact_region_pitch_capacity_and_completion :: proc(t: ^testing.T) {
	request, current := download_test_request()
	testing.expect_value(
		t,
		validate_surface_download(request, current),
		Surface_Download_Diagnostic.Valid,
	)
	required, logical, valid := surface_download_required_capacity(request.rect, request.row_pitch)
	testing.expect(t, valid)
	testing.expect_value(t, required, u64(28))
	testing.expect_value(t, logical, u64(24))

	request.row_pitch = 11
	testing.expect_value(
		t,
		validate_surface_download(request, current),
		Surface_Download_Diagnostic.Invalid_Row_Pitch,
	)
	request, current = download_test_request()
	request.byte_capacity -= 1
	testing.expect_value(
		t,
		validate_surface_download(request, current),
		Surface_Download_Diagnostic.Invalid_Capacity,
	)
	request, current = download_test_request()
	request.completion.generation += 1
	testing.expect_value(
		t,
		validate_surface_download(request, current),
		Surface_Download_Diagnostic.Invalid_Completion,
	)
}

@(test)
download_test_rejects_empty_overflow_out_of_bounds_and_stale_identity :: proc(t: ^testing.T) {
	request, current := download_test_request()
	request.rect.width = 0
	testing.expect_value(
		t,
		validate_surface_download(request, current),
		Surface_Download_Diagnostic.Invalid_Rect,
	)
	request, current = download_test_request()
	request.rect = {max(u32) - 1, 0, 4, 1}
	testing.expect_value(
		t,
		validate_surface_download(request, current),
		Surface_Download_Diagnostic.Invalid_Rect,
	)
	request, current = download_test_request()
	request.rect.x = 639
	testing.expect_value(
		t,
		validate_surface_download(request, current),
		Surface_Download_Diagnostic.Rect_Out_Of_Bounds,
	)
	request, current = download_test_request()
	current.surface.generation += 1
	testing.expect_value(
		t,
		validate_surface_download(request, current),
		Surface_Download_Diagnostic.Stale_Surface,
	)
	request, current = download_test_request()
	current.mode_generation += 1
	testing.expect_value(
		t,
		validate_surface_download(request, current),
		Surface_Download_Diagnostic.Stale_Mode,
	)
}
