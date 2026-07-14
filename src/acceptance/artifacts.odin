// SPDX-License-Identifier: GPL-3.0-only
package acceptance

import "core:fmt"
import "core:os"
import "core:path/filepath"

ARTIFACT_TEXT_MAX_BYTES :: 256 * 1024
ARTIFACT_FRAME_MAX_PIXELS :: 2_000_000

Artifact_Diagnostic :: enum {
	None,
	Invalid_Path,
	Create_Directory_Failed,
	Path_Failed,
	Write_Failed,
}

artifact_write_bundle :: proc(
	directory: string,
	diagnostics: string,
	frame_pixels: []u32 = nil,
	frame_width: int = 0,
	frame_height: int = 0,
) -> Artifact_Diagnostic {
	if directory == "" {return .Invalid_Path}
	if os.make_directory_all(directory) != nil {return .Create_Directory_Failed}
	diagnostics_path, err := filepath.join({directory, "diagnostics.txt"})
	if err != nil {return .Path_Failed}
	defer delete(diagnostics_path)
	text_bytes := transmute([]u8)diagnostics
	text_bytes = text_bytes[:min(len(text_bytes), ARTIFACT_TEXT_MAX_BYTES)]
	if os.write_entire_file(diagnostics_path, text_bytes) != nil {return .Write_Failed}
	frame_path, path_err := filepath.join({directory, "final-frame.ppm"})
	if path_err != nil {return .Path_Failed}
	defer delete(frame_path)
	if frame_width <= 0 || frame_height <= 0 ||
	   frame_width > ARTIFACT_FRAME_MAX_PIXELS / frame_height {
		_ = os.remove(frame_path)
		return .None
	}
	pixel_count := frame_width * frame_height
	if pixel_count > ARTIFACT_FRAME_MAX_PIXELS || len(frame_pixels) < pixel_count {
		_ = os.remove(frame_path)
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
	if os.write_entire_file(frame_path, payload) != nil {return .Write_Failed}
	return .None
}
