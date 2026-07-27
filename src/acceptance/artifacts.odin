// SPDX-License-Identifier: GPL-3.0-only
package acceptance

import "core:fmt"
import "core:os"
import "core:path/filepath"

ARTIFACT_TEXT_MAX_BYTES :: 256 * 1024
ARTIFACT_HARDWARE_TRACE_MAX_BYTES :: 512 * 1024
ARTIFACT_FRAME_MAX_PIXELS :: 2_000_000

Artifact_Diagnostic :: enum {
	None,
	Invalid_Path,
	Create_Directory_Failed,
	Path_Failed,
	Write_Failed,
}

@(private = "file")
artifact_recent_text :: proc(bytes: []u8, maximum: int) -> []u8 {
	if maximum <= 0 {return nil}
	if len(bytes) <= maximum {return bytes}
	start := len(bytes) - maximum
	aligned := start
	for aligned < len(bytes) && bytes[aligned - 1] != '\n' {aligned += 1}
	if aligned == len(bytes) {aligned = start}
	return bytes[aligned:]
}

@(private = "file")
artifact_remove_if_present :: proc(path: string) -> bool {
	info, stat_error := os.lstat(path, context.temp_allocator)
	if stat_error == os.General_Error.Not_Exist {return true}
	if stat_error != nil {return false}
	os.file_info_delete(info, context.temp_allocator)
	if os.remove(path) != nil {return false}

	remaining, remaining_error := os.lstat(path, context.temp_allocator)
	if remaining_error == nil {
		os.file_info_delete(remaining, context.temp_allocator)
		return false
	}
	return remaining_error == os.General_Error.Not_Exist
}

artifact_write_bundle :: proc(
	directory: string,
	diagnostics: string,
	frame_pixels: []u32 = nil,
	frame_width: int = 0,
	frame_height: int = 0,
	hardware_trace: string = "",
) -> Artifact_Diagnostic {
	if directory == "" {return .Invalid_Path}
	if os.make_directory_all(directory) != nil {return .Create_Directory_Failed}
	diagnostics_path, err := filepath.join({directory, "diagnostics.txt"})
	if err != nil {return .Path_Failed}
	defer delete(diagnostics_path)
	text_bytes := transmute([]u8)diagnostics
	text_bytes = text_bytes[:min(len(text_bytes), ARTIFACT_TEXT_MAX_BYTES)]
	if os.write_entire_file(diagnostics_path, text_bytes) != nil {return .Write_Failed}
	hardware_trace_path, trace_path_error := filepath.join({directory, "hardware-trace.txt"})
	if trace_path_error != nil {return .Path_Failed}
	defer delete(hardware_trace_path)
	if hardware_trace == "" {
		if !artifact_remove_if_present(hardware_trace_path) {return .Write_Failed}
	} else {
		trace_bytes := transmute([]u8)hardware_trace
		trace_bytes = artifact_recent_text(trace_bytes, ARTIFACT_HARDWARE_TRACE_MAX_BYTES)
		if os.write_entire_file(hardware_trace_path, trace_bytes) != nil {return .Write_Failed}
	}
	frame_path, path_err := filepath.join({directory, "final-frame.ppm"})
	if path_err != nil {return .Path_Failed}
	defer delete(frame_path)
	return artifact_write_frame(frame_path, frame_pixels, frame_width, frame_height)
}

// A guest snapshot is a frame and nothing else. Routing it through the bundle
// would rewrite the diagnostics text and delete the hardware trace on every
// capture, and land every capture on the same file.
artifact_write_snapshot :: proc(
	directory: string,
	index: u8,
	frame_pixels: []u32,
	frame_width: int,
	frame_height: int,
) -> Artifact_Diagnostic {
	if directory == "" {return .Invalid_Path}
	if os.make_directory_all(directory) != nil {return .Create_Directory_Failed}
	name := fmt.tprintf("snapshot-%d.ppm", index)
	path, path_err := filepath.join({directory, name})
	if path_err != nil {return .Path_Failed}
	defer delete(path)
	return artifact_write_frame(path, frame_pixels, frame_width, frame_height)
}

// Geometry that cannot describe an image removes any stale file at the path
// rather than leaving a mismatched one behind, and is not itself a failure.
@(private = "file")
artifact_write_frame :: proc(
	path: string,
	frame_pixels: []u32,
	frame_width: int,
	frame_height: int,
) -> Artifact_Diagnostic {
	if frame_width <= 0 ||
	   frame_height <= 0 ||
	   frame_width > ARTIFACT_FRAME_MAX_PIXELS / frame_height {
		if !artifact_remove_if_present(path) {return .Write_Failed}
		return .None
	}
	pixel_count := frame_width * frame_height
	if pixel_count > ARTIFACT_FRAME_MAX_PIXELS || len(frame_pixels) < pixel_count {
		if !artifact_remove_if_present(path) {return .Write_Failed}
		return .None
	}
	header := fmt.tprintf("P6\n%d %d\n255\n", frame_width, frame_height)
	payload := make([]u8, len(header) + pixel_count * 3)
	defer delete(payload)
	copy(payload, header)
	offset := len(header)
	for pixel in frame_pixels[:pixel_count] {
		payload[offset] = u8(pixel >> 16)
		payload[offset + 1] = u8(pixel >> 8)
		payload[offset + 2] = u8(pixel)
		offset += 3
	}
	if os.write_entire_file(path, payload) != nil {return .Write_Failed}
	return .None
}
