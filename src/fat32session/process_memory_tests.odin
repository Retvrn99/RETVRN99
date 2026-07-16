#+build windows
// SPDX-License-Identifier: GPL-3.0-only
package fat32session

import fat32image "../fat32image"
import "core:os"
import "core:path/filepath"
import "core:testing"
import win32 "core:sys/windows"

foreign import fat32_session_psapi "system:Psapi.lib"

Process_Memory_Counters :: struct {
	cb:                           win32.DWORD,
	page_fault_count:             win32.DWORD,
	peak_working_set_size:        uintptr,
	working_set_size:             uintptr,
	quota_peak_paged_pool_usage:  uintptr,
	quota_paged_pool_usage:       uintptr,
	quota_peak_nonpaged_usage:    uintptr,
	quota_nonpaged_usage:         uintptr,
	pagefile_usage:               uintptr,
	peak_pagefile_usage:          uintptr,
	private_usage:                uintptr,
}

@(default_calling_convention = "system")
foreign fat32_session_psapi {
	GetProcessMemoryInfo :: proc(
		process: win32.HANDLE,
		counters: ^Process_Memory_Counters,
		cb: win32.DWORD,
	) -> win32.BOOL ---
}

@(private = "file")
process_private_bytes :: proc(pid: int) -> (u64, bool) {
	handle := win32.OpenProcess(
		win32.PROCESS_QUERY_INFORMATION | win32.PROCESS_VM_READ,
		false,
		u32(pid),
	)
	if handle == nil {return 0, false}
	defer win32.CloseHandle(handle)
	counters := Process_Memory_Counters{cb = size_of(Process_Memory_Counters)}
	if !bool(GetProcessMemoryInfo(handle, &counters, counters.cb)) {return 0, false}
	return u64(counters.private_usage), true
}

@(private = "file")
process_memory_image :: proc(
	t: ^testing.T,
	root, name: string,
	capacity_gib: u32,
) -> (string, bool) {
	path, path_error := filepath.join({root, name}, context.temp_allocator)
	if !testing.expect(t, path_error == nil) {return "", false}
	info, create_error := create_image(
		{path = path, capacity_gib = capacity_gib},
		.In_Process,
	)
	if !testing.expect_value(t, create_error.code, Error_Code.None) {return "", false}
	image_info_destroy(&info)
	return path, true
}

@(private = "file")
process_memory_open_and_warm :: proc(
	t: ^testing.T,
	path, id: string,
) -> (^Machine_Session, u64, bool) {
	session, open_error := open_machine(path, id, .Process)
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return nil, 0, false}
	device := block_device(session)
	buffer: [MAX_BLOCK_BYTES]u8
	lba := device.sector_count - u64(len(buffer) / fat32image.SECTOR_BYTES)
	for _ in 0 ..< 32 {
		if !testing.expect(t, device.read(device.ctx, lba, buffer[:])) {
			_ = close(session, .Retain)
			return nil, 0, false
		}
	}
	impl := (^Process_Implementation)(session.ctx)
	private_bytes, measured := process_private_bytes(impl.process.pid)
	if !testing.expect(t, measured) {
		_ = close(session, .Retain)
		return nil, 0, false
	}
	return session, private_bytes, true
}

@(test)
process_adapter_test_memory_is_bounded_and_independent_of_image_size :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-process-memory-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	small_path, small_created := process_memory_image(t, root, "small.img", 1)
	large_path, large_created := process_memory_image(t, root, "large.img", 127)
	if !small_created || !large_created {return}
	small, small_bytes, small_ok := process_memory_open_and_warm(t, small_path, "memory-small")
	if !small_ok {return}
	if !testing.expect_value(t, close(small, .Commit).code, Error_Code.None) {return}
	large, large_bytes, large_ok := process_memory_open_and_warm(t, large_path, "memory-large")
	if !large_ok {return}
	defer if large != nil {_ = close(large, .Retain)}
	image_size_allowance :: u64(32 * 1024 * 1024)
	testing.expectf(
		t,
		large_bytes <= small_bytes + image_size_allowance,
		"127 GiB helper private memory %d exceeds 1 GiB helper memory %d by more than %d bytes",
		large_bytes,
		small_bytes,
		image_size_allowance,
	)
	device := block_device(large)
	buffer: [MAX_BLOCK_BYTES]u8
	lba := device.sector_count - u64(len(buffer) / fat32image.SECTOR_BYTES)
	for _ in 0 ..< 1024 {
		if !testing.expect(t, device.read(device.ctx, lba, buffer[:])) {return}
	}
	impl := (^Process_Implementation)(large.ctx)
	after, after_ok := process_private_bytes(impl.process.pid)
	if !testing.expect(t, after_ok) {return}
	churn_allowance :: u64(16 * 1024 * 1024)
	testing.expectf(
		t,
		after <= large_bytes + churn_allowance,
		"helper private memory grew from %d to %d bytes during bounded read churn",
		large_bytes,
		after,
	)
	if testing.expect_value(t, close(large, .Commit).code, Error_Code.None) {large = nil}
}
