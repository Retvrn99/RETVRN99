// SPDX-License-Identifier: GPL-3.0-only
package profile

import "core:os"
import "core:path/filepath"

DOS_SEED_MSDOS_SYS :: "[Options]\r\nLogo=0\r\nBootGUI=0\r\n"

Dos_Seed_Diagnostic :: enum {
	Missing,
	Preserved,
	Updated,
	Path_Failed,
	Read_Failed,
	Create_Directory_Failed,
	Temporary_Path_Failed,
	Write_Failed,
	Replace_Failed,
}

dos_seed_prepare :: proc(c_drive: string) -> Dos_Seed_Diagnostic {
	path, path_error := filepath.join({c_drive, "MSDOS.SYS"})
	if path_error != nil { return .Path_Failed }
	defer delete(path)

	data, read_error := os.read_entire_file(path, context.allocator)
	if read_error != nil {
		if read_error == os.General_Error.Not_Exist { return .Missing }
		return .Read_Failed
	}
	defer delete(data)
	if !dos_seed_placeholder(data) { return .Preserved }

	payload: string = DOS_SEED_MSDOS_SYS
	switch atomic_replace(path, transmute([]u8)payload, "msdos") {
	case .None: return .Updated
	case .Create_Directory_Failed: return .Create_Directory_Failed
	case .Temporary_Path_Failed: return .Temporary_Path_Failed
	case .Write_Failed: return .Write_Failed
	case .Replace_Failed: return .Replace_Failed
	}
	return .Write_Failed
}

dos_seed_is_managed :: proc(c_drive: string) -> bool {
	path, path_error := filepath.join({c_drive, "MSDOS.SYS"})
	if path_error != nil { return false }
	defer delete(path)
	data, read_error := os.read_entire_file(path, context.allocator)
	if read_error != nil { return false }
	defer delete(data)
	return string(data) == DOS_SEED_MSDOS_SYS
}

@(private = "file")
dos_seed_placeholder :: proc(data: []u8) -> bool {
	contents := string(data)
	return contents == "; \r\n" || contents == ";\r\n" || contents == "; \n" || contents == ";\n" ||
	       contents == "[Options]\r\nLogo=0\r\n"
}
