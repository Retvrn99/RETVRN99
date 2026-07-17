// SPDX-License-Identifier: GPL-3.0-only
package win98imageprep

import "core:os"
import "core:strings"
import linux "core:sys/linux"

@(private = "package")
tlb_platform_path_is_safe_regular :: proc(path: string) -> bool {
	cpath, path_error := strings.clone_to_cstring(path, context.temp_allocator)
	if path_error != nil {return false}
	stat: linux.Stat
	return linux.lstat(cpath, &stat) == .NONE && linux.S_ISREG(stat.mode)
}

@(private = "package")
tlb_platform_file_identity :: proc(file: ^os.File) -> (TLB_File_Identity, bool) {
	if file == nil {return {}, false}
	stat: linux.Stat
	if linux.fstat(linux.Fd(os.fd(file)), &stat) != .NONE || !linux.S_ISREG(stat.mode) {
		return {}, false
	}
	return {device = u64(stat.dev), file_id = u128(stat.ino)}, true
}

@(private = "package")
tlb_platform_publish_no_replace :: proc(
	source, destination: string,
) -> TLB_Publication_Status {
	from, from_error := strings.clone_to_cstring(source, context.temp_allocator)
	to, to_error := strings.clone_to_cstring(destination, context.temp_allocator)
	if from_error != nil || to_error != nil {return .Failed}
	rename_error := linux.renameat2(linux.AT_FDCWD, from, linux.AT_FDCWD, to, {.NOREPLACE})
	if rename_error == .NONE {return .Published}
	if rename_error == .EEXIST {return .Conflict}
	if rename_error != .ENOSYS {return .Failed}
	link_error := linux.link(from, to)
	if link_error == .EEXIST {return .Conflict}
	if link_error != .NONE {return .Failed}
	_ = linux.unlink(from)
	return .Published
}
