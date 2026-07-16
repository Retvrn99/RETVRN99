// SPDX-License-Identifier: GPL-3.0-only
package win98media

import "base:runtime"

Diagnostic :: enum {
	None,
	Image_Open_Failed,
	Image_Read_Failed,
	Invalid_ISO9660,
	Unsupported_ISO9660,
	Malformed_Directory,
	Unsafe_ISO_Path,
	WIN98_Directory_Missing,
	Not_Windows_98_SE,
	Setup_Executable_Missing,
	Setup_Executable_Ambiguous,
	Destination_Exists,
	Create_Directory_Failed,
	Create_File_Failed,
	Write_Failed,
	Template_Missing,
	Malformed_El_Torito,
	El_Torito_Read_Failed,
}

Media_Info :: struct {
	volume_identifier:        string,
	setup_executable:         string,
	has_msbatch_template:     bool,
	logical_block_size:       u32,
	win98_file_count:         u32,
	win98_total_bytes:        u64,
	has_embedded_boot_floppy: bool,
	allocator:                runtime.Allocator,
}

media_info_destroy :: proc(info: ^Media_Info) {
	if info == nil {
		return
	}
	delete(info.volume_identifier, info.allocator)
	delete(info.setup_executable, info.allocator)
	info^ = {}
}
