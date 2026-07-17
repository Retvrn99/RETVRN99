// SPDX-License-Identifier: GPL-3.0-only
package cabinetextract

import "core:path/filepath"
import "core:strings"

MAX_SETUP_SOURCE_TARGETS :: 64
MAX_SETUP_SOURCE_CABINETS :: 64
MAX_SETUP_SOURCE_NAME_BYTES :: 255
MAX_SETUP_SOURCE_FILE_BYTES :: u64(128 * 1024 * 1024)
MAX_SETUP_SOURCE_TOTAL_BYTES :: u64(512 * 1024 * 1024)

Setup_Source_Extract_Request :: struct {
	source_name:      string,
	destination:      string,
	max_output_bytes: u64,
}

Setup_Source_Extract_Code :: enum u16 {
	None,
	Unsupported,
	Invalid_Argument,
	Too_Many_Targets,
	Unsafe_Source_Name,
	Unsafe_Cabinet_Name,
	Unsafe_Destination,
	Duplicate_Target_Request,
	Invalid_Output_Limit,
	Concurrent_Extraction,
	FDI_Create_Failed,
	FDI_Destroy_Failed,
	Cabinet_Open_Failed,
	Cabinet_Invalid,
	Cabinet_Corrupt,
	Cabinet_Compression_Unsupported,
	Cabinet_Set_Mismatch,
	Cabinet_Limit_Exceeded,
	Unsafe_Cabinet_Member,
	Destination_Exists,
	Destination_Open_Failed,
	Output_Limit_Exceeded,
	Output_Write_Failed,
	Output_Size_Mismatch,
	Output_Close_Failed,
	Target_Duplicate,
	Target_Missing,
	Internal,
}

Setup_Source_Extract_Diagnostic :: struct {
	code:            Setup_Source_Extract_Code,
	request_index:   i32,
	native_error:    u32,
	cabinet_error:   i32,
	extracted_count: u16,
	cabinet_count:   u16,
	cleanup_failed:  bool,
}

setup_source_extract_files :: proc(
	setup_directory, first_cabinet: string,
	requests: []Setup_Source_Extract_Request,
) -> Setup_Source_Extract_Diagnostic {
	diagnostic := setup_source_extract_validate(setup_directory, first_cabinet, requests)
	if diagnostic.code != .None {return diagnostic}
	return platform_setup_source_extract_files(setup_directory, first_cabinet, requests)
}

@(private)
setup_source_extract_validate :: proc(
	setup_directory, first_cabinet: string,
	requests: []Setup_Source_Extract_Request,
) -> Setup_Source_Extract_Diagnostic {
	if setup_directory == "" ||
	   !filepath.is_abs(setup_directory) ||
	   setup_source_path_has_dot_component(setup_directory) {
		return setup_source_diagnostic(.Invalid_Argument)
	}
	if !setup_source_component_valid(first_cabinet) {
		return setup_source_diagnostic(.Unsafe_Cabinet_Name)
	}
	if len(requests) == 0 {return setup_source_diagnostic(.Invalid_Argument)}
	if len(requests) > MAX_SETUP_SOURCE_TARGETS {
		return setup_source_diagnostic(.Too_Many_Targets)
	}
	total_output_bytes: u64
	for request, index in requests {
		if !setup_source_component_valid(request.source_name) {
			return setup_source_diagnostic(.Unsafe_Source_Name, i32(index))
		}
		if request.destination == "" ||
		   !filepath.is_abs(request.destination) ||
		   setup_source_path_has_dot_component(request.destination) ||
		   !setup_source_component_valid(filepath.base(request.destination)) ||
		   setup_source_path_has_extra_colon(request.destination) {
			return setup_source_diagnostic(.Unsafe_Destination, i32(index))
		}
		if request.max_output_bytes == 0 ||
		   request.max_output_bytes > MAX_SETUP_SOURCE_FILE_BYTES ||
		   total_output_bytes > MAX_SETUP_SOURCE_TOTAL_BYTES - request.max_output_bytes {
			return setup_source_diagnostic(.Invalid_Output_Limit, i32(index))
		}
		total_output_bytes += request.max_output_bytes
		for prior in 0 ..< index {
			if strings.equal_fold(request.source_name, requests[prior].source_name) ||
			   strings.equal_fold(request.destination, requests[prior].destination) {
				return setup_source_diagnostic(.Duplicate_Target_Request, i32(index))
			}
		}
	}
	return setup_source_diagnostic(.None)
}

@(private)
setup_source_diagnostic :: proc(
	code: Setup_Source_Extract_Code,
	request_index: i32 = -1,
) -> Setup_Source_Extract_Diagnostic {
	return {code = code, request_index = request_index}
}

@(private)
setup_source_component_valid :: proc(value: string) -> bool {
	if len(value) == 0 ||
	   len(value) > MAX_SETUP_SOURCE_NAME_BYTES ||
	   value == "." ||
	   value == ".." ||
	   value[len(value) - 1] == '.' ||
	   value[len(value) - 1] == ' ' {
		return false
	}
	for byte in transmute([]u8)value {
		if byte < 0x20 || strings.index_byte(`/\\:*?"<>|`, byte) >= 0 {return false}
	}
	return true
}

@(private)
setup_source_path_has_dot_component :: proc(path: string) -> bool {
	component_start := 0
	for byte, index in transmute([]u8)path {
		if byte != '/' && byte != '\\' {continue}
		component := path[component_start:index]
		if component == "." || component == ".." {return true}
		component_start = index + 1
	}
	component := path[component_start:]
	return component == "." || component == ".."
}

@(private)
setup_source_path_has_extra_colon :: proc(path: string) -> bool {
	for byte, index in transmute([]u8)path {
		if byte == ':' && index != 1 {return true}
	}
	return false
}
