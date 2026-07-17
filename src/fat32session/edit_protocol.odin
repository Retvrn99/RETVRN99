// SPDX-License-Identifier: GPL-3.0-only
package fat32session

import fat32edit "../fat32edit"
import fat32fs "../fat32fs"
import "base:runtime"
import "core:strings"

PROTOCOL_EDIT_MAX_GUEST_PATH_BYTES :: fat32fs.MAX_PATH_BYTES
PROTOCOL_EDIT_MAX_HOST_PATH_BYTES :: 32 * 1024
PROTOCOL_EDIT_MAX_SESSION_ID_BYTES :: 1024
PROTOCOL_EDIT_MAX_PAGE_ENTRIES :: EDIT_PAGE_ENTRY_LIMIT
PROTOCOL_EDIT_PAGE_HEADER_BYTES :: 16
PROTOCOL_EDIT_ENTRY_HEADER_BYTES :: 24
PROTOCOL_EDIT_STAT_BYTES :: 24
PROTOCOL_EDIT_READ_HEADER_BYTES :: 16
PROTOCOL_EDIT_JOB_BYTES :: 40
PROTOCOL_EDIT_APPLY_BYTES :: 40

@(private = "package")
protocol_edit_path_encode :: proc(
	path: string,
	maximum: int,
	allocator: runtime.Allocator,
) -> []u8 {
	if len(path) > maximum || len(path) + 4 > PROTOCOL_MAX_PAYLOAD {return nil}
	payload := make([]u8, 4 + len(path), allocator)
	put_u32le(payload, 0, u32(len(path)))
	copy(payload[4:], transmute([]u8)path)
	return payload
}

@(private = "package")
protocol_edit_path_decode :: proc(
	payload: []u8,
	maximum: int,
	allow_empty := false,
) -> (
	string,
	bool,
) {
	if len(payload) < 4 {return "", false}
	length := int(get_u32le(payload, 0))
	if length < 0 ||
	   length > maximum ||
	   4 + length != len(payload) ||
	   !allow_empty && length == 0 {
		return "", false
	}
	return string(payload[4:]), true
}

@(private = "package")
protocol_edit_path_pair_encode :: proc(
	first, second: string,
	flags: u32,
	first_maximum, second_maximum: int,
	allocator: runtime.Allocator,
) -> []u8 {
	if len(first) == 0 ||
	   len(second) == 0 ||
	   len(first) > first_maximum ||
	   len(second) > second_maximum ||
	   len(first) > max(int) - len(second) - 12 ||
	   12 + len(first) + len(second) > PROTOCOL_MAX_PAYLOAD {
		return nil
	}
	payload := make([]u8, 12 + len(first) + len(second), allocator)
	put_u32le(payload, 0, u32(len(first)))
	put_u32le(payload, 4, u32(len(second)))
	put_u32le(payload, 8, flags)
	copy(payload[12:], transmute([]u8)first)
	copy(payload[12 + len(first):], transmute([]u8)second)
	return payload
}

@(private = "package")
protocol_edit_path_pair_decode :: proc(
	payload: []u8,
	first_maximum, second_maximum: int,
) -> (
	first, second: string,
	flags: u32,
	ok: bool,
) {
	if len(payload) < 12 {return}
	first_length := int(get_u32le(payload, 0))
	second_length := int(get_u32le(payload, 4))
	if first_length <= 0 ||
	   second_length <= 0 ||
	   first_length > first_maximum ||
	   second_length > second_maximum ||
	   first_length > len(payload) - 12 ||
	   second_length != len(payload) - 12 - first_length {
		return
	}
	first = string(payload[12:12 + first_length])
	second = string(payload[12 + first_length:])
	flags = get_u32le(payload, 8)
	ok = true
	return
}

@(private = "package")
protocol_edit_entry_flags :: proc(entry: ^fat32fs.Entry) -> u8 {
	if entry == nil {return 0}
	flags: u8
	if entry.is_directory {flags |= 1 << 0}
	if entry.is_read_only {flags |= 1 << 1}
	if entry.is_hidden {flags |= 1 << 2}
	if entry.is_system {flags |= 1 << 3}
	return flags
}

@(private = "package")
protocol_edit_page_encode :: proc(page: ^Edit_Page, allocator: runtime.Allocator) -> ([]u8, bool) {
	if page == nil || len(page.entries) > PROTOCOL_EDIT_MAX_PAGE_ENTRIES {return nil, false}
	total := PROTOCOL_EDIT_PAGE_HEADER_BYTES
	for &entry in page.entries {
		if len(entry.name) > PROTOCOL_EDIT_MAX_GUEST_PATH_BYTES ||
		   len(entry.short_name) > 12 ||
		   total >
			   PROTOCOL_MAX_PAYLOAD -
				   PROTOCOL_EDIT_ENTRY_HEADER_BYTES -
				   len(entry.name) -
				   len(entry.short_name) {
			return nil, false
		}
		total += PROTOCOL_EDIT_ENTRY_HEADER_BYTES + len(entry.name) + len(entry.short_name)
	}
	payload := make([]u8, total, allocator)
	put_u64le(payload, 0, page.next_cursor)
	payload[8] = page.has_more ? 1 : 0
	put_u16le(payload, 10, u16(len(page.entries)))
	offset := PROTOCOL_EDIT_PAGE_HEADER_BYTES
	for &entry in page.entries {
		payload[offset] = protocol_edit_entry_flags(&entry)
		put_u32le(payload, offset + 4, entry.first_cluster)
		put_u64le(payload, offset + 8, entry.size)
		put_u16le(payload, offset + 16, u16(len(entry.name)))
		put_u16le(payload, offset + 18, u16(len(entry.short_name)))
		put_u16le(payload, offset + 20, entry.modified_date)
		put_u16le(payload, offset + 22, entry.modified_time)
		copy(payload[offset + PROTOCOL_EDIT_ENTRY_HEADER_BYTES:], transmute([]u8)entry.name)
		copy(
			payload[offset + PROTOCOL_EDIT_ENTRY_HEADER_BYTES + len(entry.name):],
			transmute([]u8)entry.short_name,
		)
		offset += PROTOCOL_EDIT_ENTRY_HEADER_BYTES + len(entry.name) + len(entry.short_name)
	}
	return payload, true
}

@(private = "package")
protocol_edit_page_decode :: proc(
	payload: []u8,
	allocator: runtime.Allocator,
) -> (
	Edit_Page,
	bool,
) {
	if len(payload) < PROTOCOL_EDIT_PAGE_HEADER_BYTES {return {}, false}
	count := int(get_u16le(payload, 10))
	if count < 0 || count > PROTOCOL_EDIT_MAX_PAGE_ENTRIES {return {}, false}
	page := Edit_Page {
		entries     = make([dynamic]fat32fs.Entry, 0, count, allocator),
		next_cursor = get_u64le(payload, 0),
		has_more    = payload[8] != 0,
	}
	offset := PROTOCOL_EDIT_PAGE_HEADER_BYTES
	for _ in 0 ..< count {
		if offset > len(payload) - PROTOCOL_EDIT_ENTRY_HEADER_BYTES {
			edit_page_destroy(&page, allocator)
			return {}, false
		}
		name_length := int(get_u16le(payload, offset + 16))
		short_length := int(get_u16le(payload, offset + 18))
		entry_bytes := PROTOCOL_EDIT_ENTRY_HEADER_BYTES + name_length + short_length
		if name_length <= 0 ||
		   name_length > PROTOCOL_EDIT_MAX_GUEST_PATH_BYTES ||
		   short_length <= 0 ||
		   short_length > 12 ||
		   entry_bytes > len(payload) - offset {
			edit_page_destroy(&page, allocator)
			return {}, false
		}
		flags := payload[offset]
		name_start := offset + PROTOCOL_EDIT_ENTRY_HEADER_BYTES
		append(
			&page.entries,
			fat32fs.Entry {
				name = strings.clone(
					string(payload[name_start:name_start + name_length]),
					allocator,
				),
				short_name = strings.clone(
					string(
						payload[name_start + name_length:name_start + name_length + short_length],
					),
					allocator,
				),
				is_directory = flags & (1 << 0) != 0,
				is_read_only = flags & (1 << 1) != 0,
				is_hidden = flags & (1 << 2) != 0,
				is_system = flags & (1 << 3) != 0,
				first_cluster = get_u32le(payload, offset + 4),
				size = get_u64le(payload, offset + 8),
				modified_date = get_u16le(payload, offset + 20),
				modified_time = get_u16le(payload, offset + 22),
			},
		)
		offset += entry_bytes
	}
	if offset != len(payload) {
		edit_page_destroy(&page, allocator)
		return {}, false
	}
	return page, true
}

@(private = "package")
protocol_edit_stat_encode :: proc(info: Edit_Stat) -> (payload: [PROTOCOL_EDIT_STAT_BYTES]u8) {
	payload[0] = info.exists ? 1 : 0
	if info.is_directory {payload[1] |= 1 << 0}
	if info.is_read_only {payload[1] |= 1 << 1}
	if info.is_hidden {payload[1] |= 1 << 2}
	if info.is_system {payload[1] |= 1 << 3}
	put_u32le(payload[:], 4, info.first_cluster)
	put_u64le(payload[:], 8, info.size)
	put_u16le(payload[:], 16, info.modified_date)
	put_u16le(payload[:], 18, info.modified_time)
	return
}

@(private = "package")
protocol_edit_stat_decode :: proc(payload: []u8) -> (Edit_Stat, bool) {
	if len(payload) != PROTOCOL_EDIT_STAT_BYTES {return {}, false}
	flags := payload[1]
	return Edit_Stat {
			exists = payload[0] != 0,
			is_directory = flags & (1 << 0) != 0,
			is_read_only = flags & (1 << 1) != 0,
			is_hidden = flags & (1 << 2) != 0,
			is_system = flags & (1 << 3) != 0,
			first_cluster = get_u32le(payload, 4),
			size = get_u64le(payload, 8),
			modified_date = get_u16le(payload, 16),
			modified_time = get_u16le(payload, 18),
		},
		true
}

@(private = "package")
protocol_edit_read_encode :: proc(
	result: ^Edit_Read_Result,
	allocator: runtime.Allocator,
) -> (
	[]u8,
	bool,
) {
	if result == nil || len(result.data) > MAX_BLOCK_BYTES {return nil, false}
	payload := make([]u8, PROTOCOL_EDIT_READ_HEADER_BYTES + len(result.data), allocator)
	put_u64le(payload, 0, result.offset)
	put_u64le(payload, 8, result.total)
	copy(payload[PROTOCOL_EDIT_READ_HEADER_BYTES:], result.data)
	return payload, true
}

@(private = "package")
protocol_edit_read_decode :: proc(
	payload: []u8,
	allocator: runtime.Allocator,
) -> (
	Edit_Read_Result,
	bool,
) {
	if len(payload) < PROTOCOL_EDIT_READ_HEADER_BYTES ||
	   len(payload) - PROTOCOL_EDIT_READ_HEADER_BYTES > MAX_BLOCK_BYTES {
		return {}, false
	}
	result := Edit_Read_Result {
		offset = get_u64le(payload, 0),
		total  = get_u64le(payload, 8),
		data   = make([]u8, len(payload) - PROTOCOL_EDIT_READ_HEADER_BYTES, allocator),
	}
	copy(result.data, payload[PROTOCOL_EDIT_READ_HEADER_BYTES:])
	return result, true
}

@(private = "package")
protocol_edit_job_encode :: proc(
	progress: Edit_Job_Progress,
	changed: u64,
) -> (
	payload: [PROTOCOL_EDIT_JOB_BYTES]u8,
) {
	payload[0] = u8(progress.state)
	put_u64le(payload[:], 8, progress.completed_bytes)
	put_u64le(payload[:], 16, progress.total_bytes)
	put_u64le(payload[:], 24, progress.items_completed)
	put_u64le(payload[:], 32, changed)
	return
}

@(private = "package")
protocol_edit_job_decode :: proc(payload: []u8) -> (Edit_Job_Progress, u64, bool) {
	if len(payload) != PROTOCOL_EDIT_JOB_BYTES || payload[0] > u8(fat32edit.Job_State.Failed) {
		return {}, 0, false
	}
	return Edit_Job_Progress {
			state = Edit_Job_State(payload[0]),
			completed_bytes = get_u64le(payload, 8),
			total_bytes = get_u64le(payload, 16),
			items_completed = get_u64le(payload, 24),
		},
		get_u64le(payload, 32),
		true
}

@(private = "package")
protocol_edit_apply_encode :: proc(progress: Edit_Apply_Progress) -> (
	payload: [PROTOCOL_EDIT_APPLY_BYTES]u8,
) {
	payload[0] = u8(progress.state)
	if progress.cancellable {payload[1] = 1}
	put_u64le(payload[:], 8, progress.completed_units)
	put_u64le(payload[:], 16, progress.total_units)
	put_u64le(payload[:], 24, progress.applied_sectors)
	put_u64le(payload[:], 32, progress.total_sectors)
	return
}

@(private = "package")
protocol_edit_apply_decode :: proc(payload: []u8) -> (Edit_Apply_Progress, bool) {
	if len(payload) != PROTOCOL_EDIT_APPLY_BYTES ||
	   payload[0] > u8(fat32edit.Apply_Job_State.Failed) || payload[1] > 1 {
		return {}, false
	}
	return Edit_Apply_Progress {
		state           = Edit_Apply_State(payload[0]),
		completed_units = get_u64le(payload, 8),
		total_units     = get_u64le(payload, 16),
		applied_sectors = get_u64le(payload, 24),
		total_sectors   = get_u64le(payload, 32),
		cancellable     = payload[1] == 1,
	}, true
}
