// SPDX-License-Identifier: GPL-3.0-only
package main

import "core:os"
import "core:path/filepath"

Install_Failed_Boot_Sentinel_Diagnostic :: enum {
	None,
	Invalid_Path,
	Stat_Failed,
	Not_Regular,
	Remove_Failed,
	Removal_Unproven,
}

install_failed_boot_sentinel_cleanup :: proc(
	c_drive: string,
	install_state_changed: bool,
) -> Install_Failed_Boot_Sentinel_Diagnostic {
	if !install_state_changed {return .None}
	if c_drive == "" {return .Invalid_Path}
	path, path_error := filepath.join(
		{c_drive, "WINDOWS", "WNBOOTNG.STS"},
		context.temp_allocator,
	)
	if path_error != nil {return .Invalid_Path}
	defer delete(path, context.temp_allocator)

	info, stat_error := os.lstat(path, context.temp_allocator)
	if stat_error == os.General_Error.Not_Exist {return .None}
	if stat_error != nil {return .Stat_Failed}
	file_type := info.type
	os.file_info_delete(info, context.temp_allocator)
	if file_type != .Regular {return .Not_Regular}
	if os.remove(path) != nil {return .Remove_Failed}

	removed_info, removed_error := os.lstat(path, context.temp_allocator)
	if removed_error == os.General_Error.Not_Exist {return .None}
	if removed_error == nil {os.file_info_delete(removed_info, context.temp_allocator)}
	return .Removal_Unproven
}
