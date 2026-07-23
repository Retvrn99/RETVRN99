// SPDX-License-Identifier: GPL-3.0-only
package presentation

Surface_Download_Request :: struct {
	sequence:             u64,
	lifecycle_generation: u64,
	mode_generation:      u64,
	mode_key:             Mode_Key,
	identity_namespace:   Identity_Namespace,
	device_generation:    u64,
	surface:              Surface_Identity,
	format:               Pixel_Format,
	rect:                 Rect,
	row_pitch:            u32,
	byte_capacity:        u64,
	completion:           Completion_Identity,
}

Surface_Download_Context :: struct {
	lifecycle_generation: u64,
	mode_generation:      u64,
	mode_key:             Mode_Key,
	identity_namespace:   Identity_Namespace,
	device_generation:    u64,
	surface:              Surface_Identity,
	format:               Pixel_Format,
	surface_extent:       Extent,
	destination_capacity: u64,
}

Surface_Download_Result :: struct {
	sequence:   u64,
	completion: Completion_Identity,
	bytes:      u64,
}

Surface_Download_Diagnostic :: enum u8 {
	Valid,
	Missing_Sequence,
	Stale_Lifecycle,
	Stale_Mode,
	Stale_Mode_Key,
	Invalid_Namespace,
	Stale_Device,
	Stale_Surface,
	Unsupported_Format,
	Stale_Format,
	Invalid_Rect,
	Rect_Out_Of_Bounds,
	Invalid_Row_Pitch,
	Size_Overflow,
	Invalid_Capacity,
	Invalid_Completion,
}

surface_download_required_capacity :: proc(rect: Rect, row_pitch: u32) -> (u64, u64, bool) {
	if !rect_valid_nonempty(rect) {return 0, 0, false}
	row_bytes := u64(rect.width) * 4
	if u64(row_pitch) < row_bytes {return 0, 0, false}
	rows := u64(rect.height - 1)
	if rows != 0 && u64(row_pitch) > max(u64) / rows {return 0, 0, false}
	required := rows * u64(row_pitch)
	if required > max(u64) - row_bytes {return 0, 0, false}
	logical := u64(rect.width) * u64(rect.height) * 4
	return required + row_bytes, logical, true
}

validate_surface_download :: proc(
	request: Surface_Download_Request,
	current: Surface_Download_Context,
) -> Surface_Download_Diagnostic {
	if request.sequence == 0 {return .Missing_Sequence}
	if request.lifecycle_generation == 0 ||
	   request.lifecycle_generation != current.lifecycle_generation {return .Stale_Lifecycle}
	if request.mode_generation == 0 ||
	   request.mode_generation != current.mode_generation {return .Stale_Mode}
	if !mode_key_equal(request.mode_key, current.mode_key) {return .Stale_Mode_Key}
	if request.identity_namespace != .Gsw3d || current.identity_namespace != .Gsw3d {
		return .Invalid_Namespace
	}
	if request.device_generation == 0 ||
	   request.device_generation != current.device_generation {return .Stale_Device}
	if request.surface.id == 0 ||
	   request.surface.generation == 0 ||
	   !surface_identity_equal(request.surface, current.surface) {return .Stale_Surface}
	if request.format != .Bgra_8888 && request.format != .Rgba_8888 {
		return .Unsupported_Format
	}
	if request.format != current.format {return .Stale_Format}
	if !rect_valid_nonempty(request.rect) {return .Invalid_Rect}
	if request.rect.x + request.rect.width > current.surface_extent.width ||
	   request.rect.y + request.rect.height > current.surface_extent.height {
		return .Rect_Out_Of_Bounds
	}
	row_bytes := u64(request.rect.width) * 4
	if u64(request.row_pitch) < row_bytes {return .Invalid_Row_Pitch}
	required, _, size_valid := surface_download_required_capacity(request.rect, request.row_pitch)
	if !size_valid {return .Size_Overflow}
	if request.byte_capacity == 0 ||
	   request.byte_capacity != current.destination_capacity ||
	   required > request.byte_capacity {return .Invalid_Capacity}
	if request.completion.value == 0 ||
	   request.completion.generation == 0 ||
	   request.completion.generation != request.device_generation {
		return .Invalid_Completion
	}
	return .Valid
}
