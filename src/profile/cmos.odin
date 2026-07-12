// SPDX-License-Identifier: GPL-3.0-only
package profile

import "core:os"

CMOS_SIZE :: 128

Cmos_Data :: [CMOS_SIZE]u8

Cmos_Diagnostic :: enum {
	None,
	Missing,
	Read_Failed,
	Malformed,
	Create_Directory_Failed,
	Temporary_Path_Failed,
	Write_Failed,
	Replace_Failed,
}

cmos_load :: proc(path: string) -> (Cmos_Data, Cmos_Diagnostic) {
	data, rerr := os.read_entire_file(path, context.allocator)
	if rerr != nil {
		if rerr == os.General_Error.Not_Exist {
			return {}, .Missing
		}
		return {}, .Read_Failed
	}
	defer delete(data)
	if len(data) != CMOS_SIZE {
		return {}, .Malformed
	}

	result: Cmos_Data
	copy(result[:], data)
	return result, .None
}

cmos_save :: proc(path: string, data: Cmos_Data) -> Cmos_Diagnostic {
	payload := data
	switch atomic_replace(path, payload[:], "cmos") {
	case .None: return .None
	case .Create_Directory_Failed: return .Create_Directory_Failed
	case .Temporary_Path_Failed: return .Temporary_Path_Failed
	case .Write_Failed: return .Write_Failed
	case .Replace_Failed: return .Replace_Failed
	}
	return .Write_Failed
}
