// SPDX-License-Identifier: GPL-3.0-only
package cabinetextract

import "base:runtime"
import "core:strings"
import win32 "core:sys/windows"

foreign import cabinet "system:Cabinet.lib"

FDI_MAX_CAB_PATH_BYTES :: 255
FDI_MAX_OPEN_PATH_BYTES :: 1023
FDI_FILE_MAGIC :: u64(0x5256_3939_4341_4246)
FDI_WRITE_ERROR :: u32(0xFFFF_FFFF)

FDI_Error :: enum i32 {
	None,
	Cabinet_Not_Found,
	Not_A_Cabinet,
	Unknown_Cabinet_Version,
	Corrupt_Cabinet,
	Alloc_Fail,
	Bad_Compression_Type,
	MDI_Fail,
	Target_File,
	Reserve_Mismatch,
	Wrong_Cabinet,
	User_Abort,
	EOF,
}

FDI_Notification_Type :: enum i32 {
	Cabinet_Info,
	Partial_File,
	Copy_File,
	Close_File_Info,
	Next_Cabinet,
	Enumerate,
}

FDI_ERF :: struct {
	operation: i32,
	type:      i32,
	has_error: win32.BOOL,
}

FDI_Notification :: struct {
	size:          i32,
	name_1:        cstring,
	name_2:        cstring,
	name_3:        cstring,
	user:          rawptr,
	file:          win32.INT_PTR,
	date:          u16,
	time:          u16,
	attributes:    u16,
	set_id:        u16,
	cabinet_index: u16,
	folder_index:  u16,
	error:         FDI_Error,
}

FDI_Alloc_Callback :: #type proc "c" (size: u32) -> rawptr
FDI_Free_Callback :: #type proc "c" (memory: rawptr)
FDI_Open_Callback :: #type proc "c" (path: cstring, flags, mode: i32) -> win32.INT_PTR
FDI_Read_Callback :: #type proc "c" (file: win32.INT_PTR, data: rawptr, size: u32) -> u32
FDI_Write_Callback :: #type proc "c" (file: win32.INT_PTR, data: rawptr, size: u32) -> u32
FDI_Close_Callback :: #type proc "c" (file: win32.INT_PTR) -> i32
FDI_Seek_Callback :: #type proc "c" (file: win32.INT_PTR, distance, origin: i32) -> i32
FDI_Notify_Callback :: #type proc "c" (
	notification_type: FDI_Notification_Type,
	notification: ^FDI_Notification,
) -> win32.INT_PTR

foreign cabinet {
	FDICreate :: proc(allocate: FDI_Alloc_Callback, free: FDI_Free_Callback, open: FDI_Open_Callback, read: FDI_Read_Callback, write: FDI_Write_Callback, close: FDI_Close_Callback, seek: FDI_Seek_Callback, cpu_type: i32, error: ^FDI_ERF) -> rawptr ---
	FDICopy :: proc(fdi_context: rawptr, cabinet_name, cabinet_path: cstring, flags: i32, notify: FDI_Notify_Callback, decrypt: rawptr, user: rawptr) -> win32.BOOL ---
	FDIDestroy :: proc(fdi_context: rawptr) -> win32.BOOL ---
}

FDI_File_Kind :: enum u8 {
	Cabinet,
	Target,
}

FDI_File :: struct {
	magic:         u64,
	kind:          FDI_File_Kind,
	handle:        win32.HANDLE,
	operation:     ^FDI_Operation,
	request_index: i32,
	max_bytes:     u64,
	written:       u64,
}

FDI_Request_State :: struct {
	created:       bool,
	completed:     bool,
	declared_size: u64,
}

FDI_Operation :: struct {
	setup_directory:      string,
	requests:             []Setup_Source_Extract_Request,
	request_states:       [MAX_SETUP_SOURCE_TARGETS]FDI_Request_State,
	diagnostic:           Setup_Source_Extract_Diagnostic,
	erf:                  FDI_ERF,
	setup_path:           [FDI_MAX_CAB_PATH_BYTES + 1]u8,
	setup_path_length:    int,
	current_cabinet:      [MAX_SETUP_SOURCE_NAME_BYTES + 1]u8,
	current_length:       int,
	allowed_next:         [MAX_SETUP_SOURCE_NAME_BYTES + 1]u8,
	allowed_next_length:  int,
	copy_next:            [MAX_SETUP_SOURCE_NAME_BYTES + 1]u8,
	copy_next_length:     int,
	copy_info_seen:       bool,
	copy_start_index:     u16,
	copy_last_info_index: u16,
	cabinet_info_count:   int,
	set_id:               u16,
	set_id_known:         bool,
	expected_index:       u16,
	expected_index_known: bool,
}

@(private = "file", thread_local)
fdi_active_operation: ^FDI_Operation

#assert(size_of(FDI_ERF) == 12)
#assert(size_of(FDI_Notification) == 64 || size_of(uintptr) == 4)

@(private)
fdi_set_failure :: proc(
	operation: ^FDI_Operation,
	code: Setup_Source_Extract_Code,
	request_index: i32 = -1,
	native_error: u32 = 0,
) {
	if operation == nil || operation.diagnostic.code != .None {return}
	operation.diagnostic = setup_source_diagnostic(code, request_index)
	operation.diagnostic.native_error = native_error
}

@(private)
fdi_cstring_bounded :: proc(value: cstring, maximum: int) -> (string, bool) {
	if value == nil || maximum <= 0 {return "", false}
	bytes := ([^]u8)(rawptr(value))
	for index in 0 ..< maximum {
		if bytes[index] == 0 {return string(bytes[:index]), true}
	}
	return "", false
}

@(private)
fdi_fixed_set :: proc(buffer: []u8, length: ^int, value: string) -> bool {
	if length == nil || len(value) >= len(buffer) {return false}
	for &byte in buffer {byte = 0}
	copy(buffer[:len(value)], transmute([]u8)value)
	length^ = len(value)
	return true
}

@(private)
fdi_fixed_string :: proc(buffer: []u8, length: int) -> string {
	if length <= 0 || length > len(buffer) {return ""}
	return string(buffer[:length])
}

@(private)
fdi_path_leaf :: proc(path: string) -> string {
	start := 0
	for byte, index in transmute([]u8)path {
		if byte == '/' || byte == '\\' {start = index + 1}
	}
	return path[start:]
}

@(private)
fdi_file_from_id :: proc(id: win32.INT_PTR) -> ^FDI_File {
	if id <= 0 {return nil}
	file := (^FDI_File)(uintptr(id))
	if file == nil || file.magic != FDI_FILE_MAGIC {return nil}
	return file
}

@(private)
fdi_file_close :: proc(file: ^FDI_File) -> bool {
	if file == nil || file.magic != FDI_FILE_MAGIC {return false}
	handle := file.handle
	file.magic = 0
	closed := bool(win32.CloseHandle(handle))
	freed := bool(win32.HeapFree(win32.GetProcessHeap(), 0, file))
	return closed && freed
}

@(private)
fdi_file_allocate :: proc(
	operation: ^FDI_Operation,
	kind: FDI_File_Kind,
	handle: win32.HANDLE,
	request_index: i32 = -1,
	max_bytes: u64 = 0,
) -> ^FDI_File {
	memory := win32.HeapAlloc(win32.GetProcessHeap(), win32.HEAP_ZERO_MEMORY, size_of(FDI_File))
	if memory == nil {
		fdi_set_failure(operation, .Internal, request_index)
		return nil
	}
	file := (^FDI_File)(memory)
	file^ = {
		magic         = FDI_FILE_MAGIC,
		kind          = kind,
		handle        = handle,
		operation     = operation,
		request_index = request_index,
		max_bytes     = max_bytes,
	}
	return file
}

@(private)
fdi_source_file_safe :: proc(handle: win32.HANDLE) -> bool {
	if handle == nil ||
	   handle == win32.INVALID_HANDLE_VALUE ||
	   win32.GetFileType(handle) != win32.FILE_TYPE_DISK {
		return false
	}
	info: win32.BY_HANDLE_FILE_INFORMATION
	return(
		bool(win32.GetFileInformationByHandle(handle, &info)) &&
		info.dwFileAttributes &
				(win32.FILE_ATTRIBUTE_DIRECTORY | win32.FILE_ATTRIBUTE_REPARSE_POINT) ==
			0 \
	)
}

@(private)
fdi_destination_file_safe :: proc(handle: win32.HANDLE) -> bool {
	return fdi_source_file_safe(handle)
}

@(private)
fdi_allocate_callback :: proc "c" (size: u32) -> rawptr {
	return win32.HeapAlloc(win32.GetProcessHeap(), 0, uint(size))
}

@(private)
fdi_free_callback :: proc "c" (memory: rawptr) {
	if memory != nil {_ = win32.HeapFree(win32.GetProcessHeap(), 0, memory)}
}

@(private)
fdi_open_callback :: proc "c" (path: cstring, flags, mode: i32) -> win32.INT_PTR {
	_ = flags
	_ = mode
	context = runtime.default_context()
	operation := fdi_active_operation
	if operation == nil {return -1}
	requested_path, bounded := fdi_cstring_bounded(path, FDI_MAX_OPEN_PATH_BYTES)
	if !bounded {
		fdi_set_failure(operation, .Unsafe_Cabinet_Name)
		return -1
	}
	leaf := fdi_path_leaf(requested_path)
	current := fdi_fixed_string(operation.current_cabinet[:], operation.current_length)
	allowed_next := fdi_fixed_string(operation.allowed_next[:], operation.allowed_next_length)
	if !setup_source_component_valid(leaf) ||
	   !strings.equal_fold(leaf, current) &&
		   (allowed_next == "" || !strings.equal_fold(leaf, allowed_next)) {
		fdi_set_failure(operation, .Unsafe_Cabinet_Name)
		return -1
	}
	full_path_buffer: [FDI_MAX_CAB_PATH_BYTES + MAX_SETUP_SOURCE_NAME_BYTES + 2]u8
	full_length := operation.setup_path_length + len(leaf)
	if full_length >= len(full_path_buffer) {
		fdi_set_failure(operation, .Unsafe_Cabinet_Name)
		return -1
	}
	copy(
		full_path_buffer[:operation.setup_path_length],
		operation.setup_path[:operation.setup_path_length],
	)
	copy(full_path_buffer[operation.setup_path_length:full_length], transmute([]u8)leaf)
	full_path := string(full_path_buffer[:full_length])
	wide := win32.utf8_to_utf16(full_path, context.temp_allocator)
	if len(wide) == 0 {
		fdi_set_failure(operation, .Cabinet_Open_Failed)
		return -1
	}
	handle := win32.CreateFileW(
		cstring16(raw_data(wide)),
		win32.GENERIC_READ,
		win32.FILE_SHARE_READ,
		nil,
		win32.OPEN_EXISTING,
		win32.FILE_ATTRIBUTE_NORMAL |
		win32.FILE_FLAG_SEQUENTIAL_SCAN |
		win32.FILE_FLAG_OPEN_REPARSE_POINT,
		nil,
	)
	if handle == win32.INVALID_HANDLE_VALUE {
		fdi_set_failure(operation, .Cabinet_Open_Failed, native_error = win32.GetLastError())
		return -1
	}
	if !fdi_source_file_safe(handle) {
		native_error := win32.GetLastError()
		_ = win32.CloseHandle(handle)
		fdi_set_failure(operation, .Cabinet_Open_Failed, native_error = native_error)
		return -1
	}
	file := fdi_file_allocate(operation, .Cabinet, handle)
	if file == nil {
		_ = win32.CloseHandle(handle)
		return -1
	}
	return win32.INT_PTR(uintptr(file))
}

@(private)
fdi_read_callback :: proc "c" (id: win32.INT_PTR, data: rawptr, size: u32) -> u32 {
	context = runtime.default_context()
	file := fdi_file_from_id(id)
	if file == nil || file.kind != .Cabinet || data == nil && size != 0 {return FDI_WRITE_ERROR}
	read: u32
	if !bool(win32.ReadFile(file.handle, data, size, &read, nil)) {
		fdi_set_failure(file.operation, .Cabinet_Open_Failed, native_error = win32.GetLastError())
		return FDI_WRITE_ERROR
	}
	return read
}

@(private)
fdi_write_callback :: proc "c" (id: win32.INT_PTR, data: rawptr, size: u32) -> u32 {
	context = runtime.default_context()
	file := fdi_file_from_id(id)
	if file == nil || file.kind != .Target || data == nil && size != 0 {return FDI_WRITE_ERROR}
	if u64(size) > file.max_bytes - min(file.written, file.max_bytes) {
		fdi_set_failure(file.operation, .Output_Limit_Exceeded, file.request_index)
		return FDI_WRITE_ERROR
	}
	written: u32
	if !bool(win32.WriteFile(file.handle, data, size, &written, nil)) || written != size {
		fdi_set_failure(
			file.operation,
			.Output_Write_Failed,
			file.request_index,
			win32.GetLastError(),
		)
		return FDI_WRITE_ERROR
	}
	file.written += u64(written)
	return written
}

@(private)
fdi_close_callback :: proc "c" (id: win32.INT_PTR) -> i32 {
	context = runtime.default_context()
	file := fdi_file_from_id(id)
	if file == nil {return -1}
	return fdi_file_close(file) ? 0 : -1
}

@(private)
fdi_seek_callback :: proc "c" (id: win32.INT_PTR, distance, origin: i32) -> i32 {
	context = runtime.default_context()
	file := fdi_file_from_id(id)
	if file == nil || file.kind != .Cabinet || origin < 0 || origin > 2 {return -1}
	position: win32.LARGE_INTEGER
	if !bool(
		   win32.SetFilePointerEx(
			   file.handle,
			   win32.LARGE_INTEGER(distance),
			   &position,
			   u32(origin),
		   ),
	   ) ||
	   position < 0 ||
	   position > win32.LARGE_INTEGER(max(i32)) {
		fdi_set_failure(file.operation, .Cabinet_Open_Failed, native_error = win32.GetLastError())
		return -1
	}
	return i32(position)
}

@(private)
fdi_member_name :: proc(notification: ^FDI_Notification) -> (string, bool) {
	if notification == nil {return "", false}
	return fdi_cstring_bounded(notification.name_1, MAX_SETUP_SOURCE_NAME_BYTES + 1)
}

@(private)
fdi_request_index :: proc(operation: ^FDI_Operation, name: string) -> int {
	if operation == nil {return -1}
	for request, index in operation.requests {
		if strings.equal_fold(name, request.source_name) {return index}
	}
	return -1
}

@(private)
fdi_create_target :: proc(
	operation: ^FDI_Operation,
	request_index: int,
	declared_size: u64,
) -> win32.INT_PTR {
	request := operation.requests[request_index]
	wide := win32.utf8_to_utf16(request.destination, context.temp_allocator)
	if len(wide) == 0 {
		fdi_set_failure(operation, .Destination_Open_Failed, i32(request_index))
		return -1
	}
	handle := win32.CreateFileW(
		cstring16(raw_data(wide)),
		win32.GENERIC_WRITE,
		0,
		nil,
		win32.CREATE_NEW,
		win32.FILE_ATTRIBUTE_NORMAL |
		win32.FILE_FLAG_SEQUENTIAL_SCAN |
		win32.FILE_FLAG_OPEN_REPARSE_POINT,
		nil,
	)
	if handle == win32.INVALID_HANDLE_VALUE {
		native_error := win32.GetLastError()
		code := Setup_Source_Extract_Code.Destination_Open_Failed
		if native_error == win32.ERROR_FILE_EXISTS || native_error == win32.ERROR_ALREADY_EXISTS {
			code = .Destination_Exists
		}
		fdi_set_failure(operation, code, i32(request_index), native_error)
		return -1
	}
	state := &operation.request_states[request_index]
	state.created = true
	if !fdi_destination_file_safe(handle) {
		native_error := win32.GetLastError()
		_ = win32.CloseHandle(handle)
		fdi_set_failure(operation, .Destination_Open_Failed, i32(request_index), native_error)
		return -1
	}
	file := fdi_file_allocate(
		operation,
		.Target,
		handle,
		i32(request_index),
		request.max_output_bytes,
	)
	if file == nil {
		_ = win32.CloseHandle(handle)
		return -1
	}
	state.declared_size = declared_size
	return win32.INT_PTR(uintptr(file))
}

@(private)
fdi_notify_cabinet_info :: proc(
	operation: ^FDI_Operation,
	notification: ^FDI_Notification,
) -> win32.INT_PTR {
	if operation == nil || notification == nil {return -1}
	if operation.cabinet_info_count >= MAX_SETUP_SOURCE_CABINETS {
		fdi_set_failure(operation, .Cabinet_Limit_Exceeded)
		return -1
	}
	operation.cabinet_info_count += 1
	next_name, bounded := fdi_cstring_bounded(notification.name_1, MAX_SETUP_SOURCE_NAME_BYTES + 1)
	if !bounded || next_name != "" && !setup_source_component_valid(next_name) {
		fdi_set_failure(operation, .Unsafe_Cabinet_Name)
		return -1
	}
	if operation.set_id_known && notification.set_id != operation.set_id {
		fdi_set_failure(operation, .Cabinet_Set_Mismatch)
		return -1
	}
	if operation.copy_info_seen {
		if operation.copy_last_info_index == max(u16) ||
		   notification.cabinet_index != operation.copy_last_info_index + 1 {
			fdi_set_failure(operation, .Cabinet_Set_Mismatch)
			return -1
		}
		operation.copy_last_info_index = notification.cabinet_index
	} else {
		operation.copy_info_seen = true
		if operation.expected_index_known &&
		   notification.cabinet_index != operation.expected_index {
			fdi_set_failure(operation, .Cabinet_Set_Mismatch)
			return -1
		}
		if !operation.set_id_known {
			operation.set_id = notification.set_id
			operation.set_id_known = true
		}
		operation.copy_start_index = notification.cabinet_index
		operation.copy_last_info_index = notification.cabinet_index
	}
	if !fdi_fixed_set(operation.copy_next[:], &operation.copy_next_length, next_name) {
		fdi_set_failure(operation, .Unsafe_Cabinet_Name)
		return -1
	}
	return 0
}

@(private)
fdi_notify_partial_file :: proc(
	operation: ^FDI_Operation,
	notification: ^FDI_Notification,
) -> win32.INT_PTR {
	name, bounded := fdi_member_name(notification)
	if !bounded || !setup_source_component_valid(name) {
		fdi_set_failure(operation, .Unsafe_Cabinet_Member)
		return -1
	}
	return 0
}

@(private)
fdi_notify_copy_file :: proc(
	operation: ^FDI_Operation,
	notification: ^FDI_Notification,
) -> win32.INT_PTR {
	name, bounded := fdi_member_name(notification)
	if !bounded || !setup_source_component_valid(name) {
		fdi_set_failure(operation, .Unsafe_Cabinet_Member)
		return -1
	}
	request_index := fdi_request_index(operation, name)
	if request_index < 0 {return 0}
	state := &operation.request_states[request_index]
	if state.created || state.completed {
		fdi_set_failure(operation, .Target_Duplicate, i32(request_index))
		return -1
	}
	if notification.size < 0 ||
	   u64(notification.size) > operation.requests[request_index].max_output_bytes {
		fdi_set_failure(operation, .Output_Limit_Exceeded, i32(request_index))
		return -1
	}
	return fdi_create_target(operation, request_index, u64(notification.size))
}

@(private)
fdi_notify_close_file :: proc(
	operation: ^FDI_Operation,
	notification: ^FDI_Notification,
) -> win32.INT_PTR {
	if operation == nil || notification == nil {return -1}
	file := fdi_file_from_id(notification.file)
	if file == nil ||
	   file.kind != .Target ||
	   file.operation != operation ||
	   file.request_index < 0 ||
	   int(file.request_index) >= len(operation.requests) {
		fdi_set_failure(operation, .Internal)
		return -1
	}
	request_index := int(file.request_index)
	state := &operation.request_states[request_index]
	name, bounded := fdi_member_name(notification)
	if !bounded || !strings.equal_fold(name, operation.requests[request_index].source_name) {
		_ = fdi_file_close(file)
		fdi_set_failure(operation, .Internal, i32(request_index))
		return -1
	}
	written := file.written
	closed := fdi_file_close(file)
	if !closed {
		fdi_set_failure(operation, .Output_Close_Failed, i32(request_index), win32.GetLastError())
		return -1
	}
	if written != state.declared_size {
		fdi_set_failure(operation, .Output_Size_Mismatch, i32(request_index))
		return -1
	}
	state.completed = true
	operation.diagnostic.extracted_count += 1
	return 1
}

@(private)
fdi_notify_next_cabinet :: proc(
	operation: ^FDI_Operation,
	notification: ^FDI_Notification,
) -> win32.INT_PTR {
	if operation == nil || notification == nil || notification.error != .None {
		if operation != nil {
			if notification == nil {
				fdi_set_failure(operation, .Internal)
			} else {
				fdi_set_failure(operation, fdi_error_code(notification.error))
				operation.diagnostic.cabinet_error = i32(notification.error)
			}
		}
		return -1
	}
	next_name, bounded := fdi_cstring_bounded(notification.name_1, MAX_SETUP_SOURCE_NAME_BYTES + 1)
	if !bounded ||
	   !setup_source_component_valid(next_name) ||
	   !fdi_fixed_set(operation.allowed_next[:], &operation.allowed_next_length, next_name) {
		fdi_set_failure(operation, .Unsafe_Cabinet_Name)
		return -1
	}
	if notification.name_3 == nil || operation.setup_path_length > FDI_MAX_CAB_PATH_BYTES {
		fdi_set_failure(operation, .Unsafe_Cabinet_Name)
		return -1
	}
	path := ([^]u8)(rawptr(notification.name_3))
	copy(path[:operation.setup_path_length], operation.setup_path[:operation.setup_path_length])
	path[operation.setup_path_length] = 0
	return 0
}

@(private)
fdi_notify_callback :: proc "c" (
	notification_type: FDI_Notification_Type,
	notification: ^FDI_Notification,
) -> win32.INT_PTR {
	context = runtime.default_context()
	operation := fdi_active_operation
	if operation == nil || notification == nil || notification.user != operation {return -1}
	switch notification_type {
	case .Cabinet_Info:
		return fdi_notify_cabinet_info(operation, notification)
	case .Partial_File:
		return fdi_notify_partial_file(operation, notification)
	case .Copy_File:
		return fdi_notify_copy_file(operation, notification)
	case .Close_File_Info:
		return fdi_notify_close_file(operation, notification)
	case .Next_Cabinet:
		return fdi_notify_next_cabinet(operation, notification)
	case .Enumerate:
		return 0
	}
	return 0
}

@(private)
fdi_error_code :: proc(error: FDI_Error) -> Setup_Source_Extract_Code {
	switch error {
	case .Cabinet_Not_Found:
		return .Cabinet_Open_Failed
	case .Not_A_Cabinet, .Unknown_Cabinet_Version:
		return .Cabinet_Invalid
	case .Corrupt_Cabinet, .MDI_Fail, .EOF:
		return .Cabinet_Corrupt
	case .Bad_Compression_Type:
		return .Cabinet_Compression_Unsupported
	case .Reserve_Mismatch, .Wrong_Cabinet:
		return .Cabinet_Set_Mismatch
	case .Target_File:
		return .Output_Write_Failed
	case .Alloc_Fail, .User_Abort, .None:
		return .Internal
	}
	return .Internal
}

@(private)
fdi_cleanup_outputs :: proc(operation: ^FDI_Operation) -> bool {
	if operation == nil {return false}
	clean := true
	for state, index in operation.request_states[:len(operation.requests)] {
		if !state.created {continue}
		wide := win32.utf8_to_utf16(operation.requests[index].destination, context.temp_allocator)
		if len(wide) == 0 || !bool(win32.DeleteFileW(cstring16(raw_data(wide)))) {clean = false}
	}
	return clean
}

@(private)
fdi_operation_fail :: proc(operation: ^FDI_Operation) -> Setup_Source_Extract_Diagnostic {
	if operation.diagnostic.code == .None {
		operation.diagnostic = setup_source_diagnostic(
			fdi_error_code(FDI_Error(operation.erf.operation)),
		)
	}
	operation.diagnostic.cabinet_error = operation.erf.operation
	operation.diagnostic.cleanup_failed = !fdi_cleanup_outputs(operation)
	return operation.diagnostic
}

@(private)
fdi_setup_path_initialize :: proc(operation: ^FDI_Operation, setup_directory: string) -> bool {
	if operation == nil || len(setup_directory) == 0 {return false}
	length := len(setup_directory)
	needs_separator := setup_directory[length - 1] != '\\' && setup_directory[length - 1] != '/'
	if needs_separator {length += 1}
	if length > FDI_MAX_CAB_PATH_BYTES {return false}
	copy(operation.setup_path[:len(setup_directory)], transmute([]u8)setup_directory)
	if needs_separator {operation.setup_path[length - 1] = '\\'}
	operation.setup_path_length = length
	return true
}

@(private)
fdi_all_targets_completed :: proc(operation: ^FDI_Operation) -> bool {
	if operation == nil {return false}
	for state in operation.request_states[:len(operation.requests)] {
		if !state.completed {return false}
	}
	return true
}

@(private)
fdi_visited_contains :: proc(
	visited: ^[MAX_SETUP_SOURCE_CABINETS][MAX_SETUP_SOURCE_NAME_BYTES + 1]u8,
	lengths: ^[MAX_SETUP_SOURCE_CABINETS]int,
	count: int,
	name: string,
) -> bool {
	for index in 0 ..< count {
		if strings.equal_fold(name, fdi_fixed_string(visited[index][:], lengths[index])) {
			return true
		}
	}
	return false
}

platform_setup_source_extract_files :: proc(
	setup_directory, first_cabinet: string,
	requests: []Setup_Source_Extract_Request,
) -> Setup_Source_Extract_Diagnostic {
	if fdi_active_operation != nil {
		return setup_source_diagnostic(.Concurrent_Extraction)
	}
	operation := FDI_Operation {
		setup_directory = setup_directory,
		requests        = requests,
		diagnostic      = setup_source_diagnostic(.None),
	}
	if !fdi_setup_path_initialize(&operation, setup_directory) ||
	   !fdi_fixed_set(operation.current_cabinet[:], &operation.current_length, first_cabinet) {
		return setup_source_diagnostic(.Invalid_Argument)
	}
	fdi_active_operation = &operation
	defer if fdi_active_operation == &operation {fdi_active_operation = nil}
	fdi_context := FDICreate(
		fdi_allocate_callback,
		fdi_free_callback,
		fdi_open_callback,
		fdi_read_callback,
		fdi_write_callback,
		fdi_close_callback,
		fdi_seek_callback,
		-1,
		&operation.erf,
	)
	if fdi_context == nil {
		diagnostic := setup_source_diagnostic(.FDI_Create_Failed)
		diagnostic.cabinet_error = operation.erf.operation
		return diagnostic
	}
	visited: [MAX_SETUP_SOURCE_CABINETS][MAX_SETUP_SOURCE_NAME_BYTES + 1]u8
	visited_lengths: [MAX_SETUP_SOURCE_CABINETS]int
	copy_failed := false
	for cabinet_number in 0 ..< MAX_SETUP_SOURCE_CABINETS {
		current := fdi_fixed_string(operation.current_cabinet[:], operation.current_length)
		if current == "" ||
		   fdi_visited_contains(&visited, &visited_lengths, cabinet_number, current) {
			fdi_set_failure(&operation, .Cabinet_Set_Mismatch)
			copy_failed = true
			break
		}
		_ = fdi_fixed_set(visited[cabinet_number][:], &visited_lengths[cabinet_number], current)
		operation.copy_info_seen = false
		operation.copy_next_length = 0
		operation.allowed_next_length = 0
		operation.erf = {}
		copied := bool(
			FDICopy(
				fdi_context,
				cstring(raw_data(operation.current_cabinet[:])),
				cstring(raw_data(operation.setup_path[:])),
				0,
				fdi_notify_callback,
				nil,
				&operation,
			),
		)
		operation.diagnostic.cabinet_count = u16(cabinet_number + 1)
		if !copied || operation.diagnostic.code != .None || !operation.copy_info_seen {
			if operation.diagnostic.code == .None && !operation.copy_info_seen {
				fdi_set_failure(&operation, .Cabinet_Invalid)
			}
			copy_failed = true
			break
		}
		if fdi_all_targets_completed(&operation) {break}
		next := fdi_fixed_string(operation.copy_next[:], operation.copy_next_length)
		if next == "" {break}
		if cabinet_number + 1 >= MAX_SETUP_SOURCE_CABINETS {
			fdi_set_failure(&operation, .Cabinet_Limit_Exceeded)
			copy_failed = true
			break
		}
		if operation.copy_last_info_index == max(u16) {
			fdi_set_failure(&operation, .Cabinet_Set_Mismatch)
			copy_failed = true
			break
		}
		operation.expected_index = operation.copy_last_info_index + 1
		operation.expected_index_known = true
		if !fdi_fixed_set(operation.current_cabinet[:], &operation.current_length, next) {
			fdi_set_failure(&operation, .Unsafe_Cabinet_Name)
			copy_failed = true
			break
		}
	}
	destroyed := bool(FDIDestroy(fdi_context))
	if copy_failed {
		return fdi_operation_fail(&operation)
	}
	if !destroyed {
		fdi_set_failure(&operation, .FDI_Destroy_Failed)
		return fdi_operation_fail(&operation)
	}
	for state, index in operation.request_states[:len(requests)] {
		if !state.completed {
			fdi_set_failure(&operation, .Target_Missing, i32(index))
			return fdi_operation_fail(&operation)
		}
	}
	return operation.diagnostic
}
