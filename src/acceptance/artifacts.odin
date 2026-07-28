// SPDX-License-Identifier: GPL-3.0-only
package acceptance

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import stbi "vendor:stb/image"

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
	frame_path, path_err := filepath.join({directory, "final-frame.png"})
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
	name := fmt.tprintf("snapshot-%d.png", index)
	path, path_err := filepath.join({directory, name})
	if path_err != nil {return .Path_Failed}
	defer delete(path)
	return artifact_write_frame(path, frame_pixels, frame_width, frame_height)
}

// The composition a guest asked for, which is the canvas placed and scaled the
// way the window would place it with the border painted around it.
artifact_write_composed :: proc(
	directory: string,
	index: u8,
	frame_pixels: []u32,
	frame_width: int,
	frame_height: int,
) -> Artifact_Diagnostic {
	if directory == "" {return .Invalid_Path}
	if os.make_directory_all(directory) != nil {return .Create_Directory_Failed}
	name := fmt.tprintf("composed-%d.png", index)
	path, path_err := filepath.join({directory, name})
	if path_err != nil {return .Path_Failed}
	defer delete(path)
	return artifact_write_frame(path, frame_pixels, frame_width, frame_height)
}

Artifact_Capture :: struct {
	kind:                     string,
	label:                    u8,
	time_ns:                  u64,
	canvas_width:             int,
	canvas_height:            int,
	left, right, top, bottom: u32,
	overscan:                 u32,
}

ARTIFACT_SERIAL_LOG :: "serial1.log"
ARTIFACT_CAPTURE_MANIFEST :: "captures.tsv"
ARTIFACT_CAPTURE_HEADER :: "kind\tlabel\ttime_ns\tcanvas_width\tcanvas_height\tborder_left\tborder_right\tborder_top\tborder_bottom\toverscan\n"

// One row per capture, so a run can be read without opening a single image and
// each image can be placed on the master timeline beside the hardware trace.
// Rewrites the whole file per row, which is fine for the tens of captures a
// guest test takes and would want revisiting for thousands.
// Appends whatever the guest has written to COM1 since the last drain. A guest
// driver's own debug channel is a byte stream rather than a sequence of events,
// so it survives the two things a breadcrumb through the test device cannot: it
// keeps its order when calls arrive faster than the host services them, and it
// carries values rather than labels.
artifact_append_serial :: proc(directory: string, bytes: []u8) -> Artifact_Diagnostic {
	if directory == "" {return .Invalid_Path}
	if len(bytes) == 0 {return .None}
	if os.make_directory_all(directory) != nil {return .Create_Directory_Failed}
	path, path_err := filepath.join({directory, ARTIFACT_SERIAL_LOG})
	if path_err != nil {return .Path_Failed}
	defer delete(path)
	existing, _ := os.read_entire_file(path, context.temp_allocator)
	payload := make([]u8, len(existing) + len(bytes), context.temp_allocator)
	copy(payload, existing)
	copy(payload[len(existing):], bytes)
	if os.write_entire_file(path, payload) != nil {return .Write_Failed}
	return .None
}

artifact_append_capture :: proc(
	directory: string,
	capture: Artifact_Capture,
) -> Artifact_Diagnostic {
	if directory == "" {return .Invalid_Path}
	if os.make_directory_all(directory) != nil {return .Create_Directory_Failed}
	path, path_err := filepath.join({directory, ARTIFACT_CAPTURE_MANIFEST})
	if path_err != nil {return .Path_Failed}
	defer delete(path)
	existing, _ := os.read_entire_file(path, context.temp_allocator)
	row := fmt.tprintf(
		"%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t0x%08X\n",
		capture.kind,
		capture.label,
		capture.time_ns,
		capture.canvas_width,
		capture.canvas_height,
		capture.left,
		capture.right,
		capture.top,
		capture.bottom,
		capture.overscan,
	)
	header := len(existing) == 0 ? ARTIFACT_CAPTURE_HEADER : ""
	payload := fmt.tprintf("%s%s%s", string(existing), header, row)
	if os.write_entire_file(path, transmute([]u8)payload) != nil {return .Write_Failed}
	return .None
}

// Geometry that cannot describe an image removes any stale file at the path
// rather than leaving a mismatched one behind, and is not itself a failure.
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
	payload := make([]u8, pixel_count * 3)
	defer delete(payload)
	offset := 0
	for pixel in frame_pixels[:pixel_count] {
		payload[offset] = u8(pixel >> 16)
		payload[offset + 1] = u8(pixel >> 8)
		payload[offset + 2] = u8(pixel)
		offset += 3
	}
	path_c := strings.clone_to_cstring(path, context.temp_allocator)
	written := stbi.write_png(
		path_c,
		i32(frame_width),
		i32(frame_height),
		3,
		raw_data(payload),
		i32(frame_width * 3),
	)
	if written == 0 {return .Write_Failed}
	return .None
}
