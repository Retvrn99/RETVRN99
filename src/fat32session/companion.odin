// SPDX-License-Identifier: GPL-3.0-only
package fat32session

import companionio "../companionio"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:time"

Companion_Directory_Identity :: struct {
	valid:   bool,
	device:  u64,
	file_id: u128,
}

Companion_Boundary :: companionio.Directory

@(private = "package")
companion_boundary_open :: proc(
	path: string,
	allocator := context.allocator,
) -> (
	Companion_Boundary,
	bool,
) {
	directory, status := companionio.open_path(path, allocator = allocator)
	return directory, status == .None
}

@(private = "package")
companion_boundary_close :: proc(
	directory: ^Companion_Boundary,
	allocator := context.allocator,
) {
	companionio.close_directory(directory, allocator)
}

@(private = "package")
companion_boundary_file_open :: proc(
	directory: ^Companion_Boundary,
	name: string,
	flags: os.File_Flags,
) -> (
	^os.File,
	bool,
) {
	file, _, status := companionio.open_file(directory, name, flags)
	return file, status == .None
}

@(private = "package")
companion_boundary_file_probe :: proc(
	directory: ^Companion_Boundary,
	name: string,
) -> (
	exists, safe: bool,
	size: i64,
) {
	return companionio.probe_file(directory, name)
}

@(private = "package")
companion_boundary_sync :: proc(directory: ^Companion_Boundary) -> bool {
	return companionio.sync_directory(directory)
}

@(private = "package")
companion_boundary_child_file_probe :: proc(
	directory: ^Companion_Boundary,
	child_name, file_name: string,
) -> (
	exists, safe: bool,
) {
	child, status := companionio.open_child(
		directory,
		child_name,
		false,
		context.temp_allocator,
	)
	if status == .Missing {return false, true}
	if status != .None {return true, false}
	defer companion_boundary_close(&child, context.temp_allocator)
	exists, safe, _ = companionio.probe_file(&child, file_name)
	return
}

@(private = "file")
companion_remove_known_edit_tree :: proc(root: ^Companion_Boundary) -> bool {
	edit, status := companionio.open_child(root, "edit", false, context.temp_allocator)
	if status == .Missing {return true}
	if status != .None {return false}
	defer companion_boundary_close(&edit, context.temp_allocator)
	edit_names := [?]string{"overlay.bin", "presence.bin", "apply.intent", "edit.meta"}
	for name in edit_names {
		if !companionio.remove_file(&edit, name) {return false}
	}
	return companionio.retire_directory(root, &edit)
}

@(private = "package")
companion_remove_known_tree :: proc(
	root: ^Companion_Boundary,
	expected: Companion_Directory_Identity,
) -> bool {
	if root == nil || !root.open ||
	   !expected.valid ||
	   root.identity.device != expected.device ||
	   root.identity.file_id != expected.file_id {
		return false
	}
	if !companion_remove_known_edit_tree(root) {return false}
	root_names := [?]string {
		"state.a",
		"state.b",
		WAL_FILE,
		"edit-owner.a",
		"edit-owner.b",
		"adoption-vbr.evidence",
	}
	for name in root_names {
		if !companionio.remove_file(root, name) {return false}
	}
	return companionio.retire_directory(nil, root)
}

@(private = "file")
companion_directory_identity_equal :: proc(
	left, right: Companion_Directory_Identity,
) -> bool {
	return left.valid && right.valid && left.device == right.device && left.file_id == right.file_id
}

@(private = "package")
companion_directory_probe :: proc(path: string) -> (exists, safe: bool) {
	if path == "" {return false, false}
	info, stat_error := os.stat_do_not_follow_links(path, context.temp_allocator)
	if stat_error == .Not_Exist {return false, true}
	if stat_error != nil {return true, false}
	defer os.file_info_delete(info, context.temp_allocator)
	return true, info.type == .Directory && platform_companion_directory_valid(path)
}

@(private = "package")
companion_directory_sync :: proc(path: string) -> bool {
	return path != "" && platform_companion_directory_sync(path)
}

@(private = "package")
companion_directory_prepare :: proc(path: string, create: bool) -> bool {
	if path == "" {return false}
	existed, safe := companion_directory_probe(path)
	if existed && !safe {return false}
	if !existed {
		if !create || os.make_directory(path) != nil {return false}
	}
	if _, safe_after_create := companion_directory_probe(path); !safe_after_create {
		return false
	}
	if !platform_companion_directory_hide(path) {return false}
	if _, safe_after_hide := companion_directory_probe(path); !safe_after_hide {return false}
	if create && !existed {
		parent := filepath.dir(path)
		if !companion_directory_sync(path) || !companion_directory_sync(parent) {
			return false
		}
	}
	return true
}

@(private = "package")
companion_directory_remove :: proc(path: string) -> bool {
	exists, safe := companion_directory_probe(path)
	if !exists {return safe}
	if !safe {return false}
	original, original_ok := platform_companion_directory_identity(path)
	if !original_ok {return false}
	for attempt in 0 ..< 8 {
		quarantine := fmt.tprintf(
			"%s.retiring-%d-%d-%d",
			path,
			os.get_pid(),
			time.now()._nsec,
			attempt,
		)
		if quarantine_exists, _ := companion_directory_probe(quarantine); quarantine_exists {
			continue
		}
		if os.rename(path, quarantine) != nil {continue}
		moved_exists, moved_directory_safe := companion_directory_probe(quarantine)
		moved, moved_ok := platform_companion_directory_identity(quarantine)
		moved_safe :=
			moved_exists &&
			moved_directory_safe &&
			moved_ok &&
			companion_directory_identity_equal(original, moved)
		if !moved_safe {
			if original_exists, _ := companion_directory_probe(path); !original_exists {
				_ = os.rename(quarantine, path)
			}
			return false
		}
		boundary, boundary_ok := companion_boundary_open(quarantine, context.temp_allocator)
		if !boundary_ok {return false}
		defer companion_boundary_close(&boundary, context.temp_allocator)
		return companion_remove_known_tree(&boundary, original)
	}
	return false
}
