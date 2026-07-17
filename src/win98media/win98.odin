// SPDX-License-Identifier: GPL-3.0-only
package win98media

import "base:runtime"
import "core:os"
import "core:path/filepath"
import "core:strings"

Detected_Media :: struct {
	win98:             Iso_Record,
	setup:             Iso_Record,
	setup_name:        string,
	msbatch:           Iso_Record,
	has_msbatch:       bool,
	win98_file_count:  u32,
	win98_total_bytes: u64,
	allocator:         runtime.Allocator,
}

detected_destroy :: proc(media: ^Detected_Media) {
	delete(media.setup_name, media.allocator)
	media^ = {}
}

iso_extension_equal :: proc(name, extension: string) -> bool {
	if len(name) < len(extension) {
		return false
	}
	return strings.equal_fold(name[len(name) - len(extension):], extension)
}

iso_setup_candidate :: proc(entries: []Iso_Entry, entry: Iso_Entry) -> bool {
	if entry.record.is_dir || !iso_extension_equal(entry.name, ".EXE") {
		return false
	}
	stem := entry.name[:len(entry.name) - 4]
	for other in entries {
		if other.record.is_dir || !iso_extension_equal(other.name, ".TXT") {
			continue
		}
		if strings.equal_fold(stem, other.name[:len(other.name) - 4]) {
			return true
		}
	}
	return false
}

Tree_Stats_Context :: struct {
	image:     ^Iso_Image,
	allocator: runtime.Allocator,
	visited:   [dynamic]u64,
	count:     u32,
	total:     u64,
}

iso_tree_stats_walk :: proc(
	ctx: ^Tree_Stats_Context,
	record: Iso_Record,
	depth: int,
) -> Diagnostic {
	if depth > MAX_TREE_DEPTH {
		return .Malformed_Directory
	}
	key := u64(record.extent) << 32 | u64(record.size)
	for prior in ctx.visited {
		if prior == key {
			return .Malformed_Directory
		}
	}
	append(&ctx.visited, key)
	entries, diagnostic := iso_directory_read(ctx.image, record, ctx.allocator)
	if diagnostic != .None {
		return diagnostic
	}
	defer iso_entries_destroy(entries, ctx.allocator)
	for entry in entries {
		if entry.record.is_dir {
			if child_diagnostic := iso_tree_stats_walk(ctx, entry.record, depth + 1);
			   child_diagnostic != .None {
				return child_diagnostic
			}
		} else {
			ctx.count += 1
			ctx.total += u64(entry.record.size)
			if ctx.count > MAX_TREE_ENTRIES {
				return .Malformed_Directory
			}
		}
	}
	return .None
}

iso_tree_stats :: proc(
	image: ^Iso_Image,
	root: Iso_Record,
	allocator: runtime.Allocator,
) -> (
	u32,
	u64,
	Diagnostic,
) {
	ctx := Tree_Stats_Context {
		image     = image,
		allocator = allocator,
	}
	ctx.visited = make([dynamic]u64, allocator)
	defer delete(ctx.visited)
	diagnostic := iso_tree_stats_walk(&ctx, root, 0)
	return ctx.count, ctx.total, diagnostic
}

detect_win98 :: proc(
	image: ^Iso_Image,
	allocator: runtime.Allocator,
) -> (
	Detected_Media,
	Diagnostic,
) {
	media := Detected_Media {
		allocator = allocator,
	}
	root_entries, root_diagnostic := iso_directory_read(image, image.root, allocator)
	if root_diagnostic != .None {
		return {}, root_diagnostic
	}
	defer iso_entries_destroy(root_entries, allocator)
	win98_entry, found_win98 := iso_find(root_entries, "WIN98")
	if !found_win98 || !win98_entry.record.is_dir {
		return {}, .WIN98_Directory_Missing
	}
	media.win98 = win98_entry.record

	entries, directory_diagnostic := iso_directory_read(image, media.win98, allocator)
	if directory_diagnostic != .None {
		return {}, directory_diagnostic
	}
	defer iso_entries_destroy(entries, allocator)
	required := [?]string {
		"PRECOPY1.CAB",
		"PRECOPY2.CAB",
		"BASE4.CAB",
		"OEMSETUP.EXE",
		"OEMSETUP.BIN",
	}
	for name in required {
		entry, ok := iso_find(entries, name)
		if !ok || entry.record.is_dir {
			return {}, .Not_Windows_98_SE
		}
	}

	candidates := 0
	for entry in entries {
		if iso_setup_candidate(entries, entry) {
			candidates += 1
			media.setup = entry.record
			delete(media.setup_name, allocator)
			media.setup_name = strings.clone(entry.name, allocator)
		}
	}
	if candidates == 0 {
		detected_destroy(&media)
		return {}, .Setup_Executable_Missing
	}
	if candidates != 1 {
		detected_destroy(&media)
		return {}, .Setup_Executable_Ambiguous
	}
	is_se, marker_diagnostic := iso_file_contains(image, media.setup, "4.10.2222")
	if marker_diagnostic != .None {
		detected_destroy(&media)
		return {}, marker_diagnostic
	}
	if !is_se {
		detected_destroy(&media)
		return {}, .Not_Windows_98_SE
	}

	media.win98_file_count, media.win98_total_bytes, directory_diagnostic = iso_tree_stats(
		image,
		media.win98,
		allocator,
	)
	if directory_diagnostic != .None {
		detected_destroy(&media)
		return {}, directory_diagnostic
	}
	if tools, has_tools := iso_find(root_entries, "TOOLS"); has_tools && tools.record.is_dir {
		tools_entries, tools_diagnostic := iso_directory_read(image, tools.record, allocator)
		if tools_diagnostic != .None {
			detected_destroy(&media)
			return {}, tools_diagnostic
		}
		defer iso_entries_destroy(tools_entries, allocator)
		if sysrec, has_sysrec := iso_find(tools_entries, "SYSREC");
		   has_sysrec && sysrec.record.is_dir {
			sysrec_entries, sysrec_diagnostic := iso_directory_read(
				image,
				sysrec.record,
				allocator,
			)
			if sysrec_diagnostic != .None {
				detected_destroy(&media)
				return {}, sysrec_diagnostic
			}
			defer iso_entries_destroy(sysrec_entries, allocator)
			if template, has_template := iso_find(sysrec_entries, "MSBATCH.INF");
			   has_template && !template.record.is_dir {
				media.msbatch = template.record
				media.has_msbatch = true
			}
		}
	}
	return media, .None
}

boot_floppy_inspection_result :: proc(
	diagnostic: Boot_Floppy_Diagnostic,
) -> (
	embedded: bool,
	media_diagnostic: Diagnostic,
) {
	switch diagnostic {
	case .None:
		return true, .None
	case .Absent, .Unsupported:
		return false, .None
	case .Image_Read_Failed:
		return false, .El_Torito_Read_Failed
	case .Malformed:
		return false, .Malformed_El_Torito
	case .Destination_Exists, .Create_File_Failed, .Write_Failed:
		return false, .Malformed_El_Torito
	}
	return false, .Malformed_El_Torito
}

inspect :: proc(path: string, allocator := context.allocator) -> (Media_Info, Diagnostic) {
	image, diagnostic := iso_open(path)
	if diagnostic != .None {
		return {}, diagnostic
	}
	defer iso_image_close(&image)
	detected, detect_diagnostic := detect_win98(&image, context.temp_allocator)
	if detect_diagnostic != .None {
		return {}, detect_diagnostic
	}
	defer detected_destroy(&detected)
	_, boot_diagnostic := iso_boot_floppy_find(&image)
	has_embedded_boot_floppy, boot_media_diagnostic := boot_floppy_inspection_result(
		boot_diagnostic,
	)
	if boot_media_diagnostic != .None {return {}, boot_media_diagnostic}
	info := Media_Info {
		volume_identifier        = strings.clone(
			string(image.volume_identifier[:image.volume_id_len]),
			allocator,
		),
		setup_executable         = strings.clone(detected.setup_name, allocator),
		has_msbatch_template     = detected.has_msbatch,
		logical_block_size       = image.block_size,
		win98_file_count         = detected.win98_file_count,
		win98_total_bytes        = detected.win98_total_bytes,
		has_embedded_boot_floppy = has_embedded_boot_floppy,
		allocator                = allocator,
	}
	return info, .None
}

iso_copy_file :: proc(image: ^Iso_Image, record: Iso_Record, destination: string) -> Diagnostic {
	out, create_error := os.open(destination, {.Write, .Create, .Excl})
	if create_error != nil {
		return .Create_File_Failed
	}
	remove_on_failure := true
	defer {
		if out != nil {
			_ = os.close(out)
		}
		if remove_on_failure {
			_ = os.remove(destination)
		}
	}
	buffer: [64 * 1024]u8
	offset := u64(record.extent) * u64(image.block_size)
	remaining := u64(record.size)
	for remaining > 0 {
		amount := int(min(remaining, u64(len(buffer))))
		if !iso_read_exact(image.file, buffer[:amount], offset) {
			return .Image_Read_Failed
		}
		written, write_error := os.write(out, buffer[:amount])
		if write_error != nil || written != amount {
			return .Write_Failed
		}
		offset += u64(amount)
		remaining -= u64(amount)
	}
	if close_error := os.close(out); close_error != nil {
		out = nil
		return .Write_Failed
	}
	out = nil
	remove_on_failure = false
	return .None
}

iso_safe_child :: proc(
	root, parent, name: string,
	allocator: runtime.Allocator,
) -> (
	string,
	bool,
) {
	if !iso_component_safe(name) {
		return "", false
	}
	path, join_error := filepath.join({parent, name}, allocator)
	if join_error != nil {
		return "", false
	}
	relative, relative_error := filepath.rel(root, path, allocator)
	escapes :=
		relative == ".." ||
		(len(relative) > 2 && relative[:2] == ".." && filepath.is_separator(relative[2]))
	if relative_error != nil || escapes || filepath.is_abs(relative) {
		delete(path, allocator)
		delete(relative, allocator)
		return "", false
	}
	delete(relative, allocator)
	return path, true
}

Extract_Context :: struct {
	image:     ^Iso_Image,
	root:      string,
	allocator: runtime.Allocator,
	visited:   [dynamic]u64,
}

extract_directory_walk :: proc(
	ctx: ^Extract_Context,
	record: Iso_Record,
	path: string,
	depth: int,
) -> Diagnostic {
	if depth > MAX_TREE_DEPTH {
		return .Malformed_Directory
	}
	key := u64(record.extent) << 32 | u64(record.size)
	for prior in ctx.visited {
		if prior == key {
			return .Malformed_Directory
		}
	}
	append(&ctx.visited, key)
	entries, diagnostic := iso_directory_read(ctx.image, record, ctx.allocator)
	if diagnostic != .None {
		return diagnostic
	}
	defer iso_entries_destroy(entries, ctx.allocator)
	for entry in entries {
		target, safe := iso_safe_child(ctx.root, path, entry.name, ctx.allocator)
		if !safe {
			return .Unsafe_ISO_Path
		}
		if entry.record.is_dir {
			if make_error := os.make_directory(target); make_error != nil {
				delete(target, ctx.allocator)
				return .Create_Directory_Failed
			}
			child_diagnostic := extract_directory_walk(ctx, entry.record, target, depth + 1)
			delete(target, ctx.allocator)
			if child_diagnostic != .None {
				return child_diagnostic
			}
		} else {
			file_diagnostic := iso_copy_file(ctx.image, entry.record, target)
			delete(target, ctx.allocator)
			if file_diagnostic != .None {
				return file_diagnostic
			}
		}
	}
	return .None
}

extract_directory :: proc(
	image: ^Iso_Image,
	source: Iso_Record,
	root, destination: string,
	allocator: runtime.Allocator,
) -> Diagnostic {
	ctx := Extract_Context {
		image     = image,
		root      = root,
		allocator = allocator,
	}
	ctx.visited = make([dynamic]u64, allocator)
	defer delete(ctx.visited)
	return extract_directory_walk(&ctx, source, destination, 0)
}

extract_win98 :: proc(path, staging_directory: string) -> Diagnostic {
	if _, stat_error := os.lstat(staging_directory, context.temp_allocator); stat_error == nil {
		return .Destination_Exists
	} else if stat_error != os.General_Error.Not_Exist {
		return .Create_Directory_Failed
	}
	image, diagnostic := iso_open(path)
	if diagnostic != .None {
		return diagnostic
	}
	defer iso_image_close(&image)
	detected, detect_diagnostic := detect_win98(&image, context.temp_allocator)
	if detect_diagnostic != .None {
		return detect_diagnostic
	}
	defer detected_destroy(&detected)
	if make_error := os.make_directory_all(staging_directory); make_error != nil {
		return .Create_Directory_Failed
	}
	extract_diagnostic := extract_directory(
		&image,
		detected.win98,
		staging_directory,
		staging_directory,
		context.temp_allocator,
	)
	if extract_diagnostic != .None {
		_ = os.remove_all(staging_directory)
	}
	return extract_diagnostic
}

extract_msbatch_template :: proc(path, destination: string) -> Diagnostic {
	image, diagnostic := iso_open(path)
	if diagnostic != .None {
		return diagnostic
	}
	defer iso_image_close(&image)
	detected, detect_diagnostic := detect_win98(&image, context.temp_allocator)
	if detect_diagnostic != .None {
		return detect_diagnostic
	}
	defer detected_destroy(&detected)
	if !detected.has_msbatch {
		return .Template_Missing
	}
	parent := filepath.dir(destination)
	if make_error := os.make_directory_all(parent); make_error != nil {
		return .Create_Directory_Failed
	}
	return iso_copy_file(&image, detected.msbatch, destination)
}
