// SPDX-License-Identifier: GPL-3.0-only
package fat32fs

import "base:runtime"
import "core:strings"
import "core:unicode/utf16"

ATTR_READ_ONLY :: u8(0x01)
ATTR_HIDDEN :: u8(0x02)
ATTR_SYSTEM :: u8(0x04)
ATTR_VOLUME :: u8(0x08)
ATTR_DIRECTORY :: u8(0x10)
ATTR_LFN :: u8(0x0F)
LFN_OFFSETS :: [13]int{1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30}

@(private = "package")
Raw_Entry :: struct {
	short:         [11]u8,
	attributes:    u8,
	first_cluster: u32,
	size:          u32,
	modified_date: u16,
	modified_time: u16,
	lfn:           string,
}

@(private = "package")
raw_entry_destroy :: proc(entry: ^Raw_Entry, allocator := context.allocator) {
	if entry == nil {return}
	delete(entry.lfn, allocator)
	entry^ = {}
}

@(private = "package")
Lfn_State :: struct {
	units:    [20 * 13]u16,
	max:      int,
	checksum: u8,
}

@(private = "package")
lfn_checksum :: proc(short: [11]u8) -> u8 {
	result: u8
	for value in short {result = ((result & 1) << 7) + (result >> 1) + value}
	return result
}

@(private = "package")
short_name :: proc(value: [11]u8, allocator := context.allocator) -> string {
	copy_value := value
	base := strings.trim_right(string(copy_value[:8]), " ")
	extension := strings.trim_right(string(copy_value[8:]), " ")
	if len(extension) == 0 {return strings.clone(base, allocator)}
	return strings.concatenate({base, ".", extension}, allocator)
}

@(private = "package")
parse_directory_slot :: proc(
	slot: []u8,
	lfn: ^Lfn_State,
	allocator := context.allocator,
) -> (
	entry: Raw_Entry,
	present, ended: bool,
) {
	if slot[0] == 0 {
		lfn^ = {}
		return {}, false, true
	}
	if slot[0] == 0xE5 {
		lfn^ = {}
		return {}, false, false
	}
	if slot[11] & 0x3F == ATTR_LFN {
		sequence := int(slot[0] & 0x1F)
		if sequence < 1 || sequence > 20 {
			lfn^ = {}
			return {}, false, false
		}
		if slot[0] & 0x40 != 0 {
			lfn^ = {}
			lfn.max = sequence
			lfn.checksum = slot[13]
		}
		if lfn.max == 0 || sequence > lfn.max {
			lfn^ = {}
			return {}, false, false
		}
		for offset, index in LFN_OFFSETS {
			lfn.units[(sequence - 1) * 13 + index] = get_u16le(slot, offset)
		}
		return {}, false, false
	}
	copy(entry.short[:], slot[:11])
	entry.attributes = slot[11]
	entry.first_cluster = u32(get_u16le(slot, 20)) << 16 | u32(get_u16le(slot, 26))
	entry.size = get_u32le(slot, 28)
	entry.modified_time = get_u16le(slot, 22)
	entry.modified_date = get_u16le(slot, 24)
	if lfn.max > 0 && lfn_checksum(entry.short) == lfn.checksum {
		units := lfn.units[:lfn.max * 13]
		count := 0
		for count < len(units) && units[count] != 0 && units[count] != 0xFFFF {count += 1}
		bytes := make([]u8, count * 4, allocator)
		written := utf16.decode_to_utf8(bytes, units[:count])
		entry.lfn = string(bytes[:written])
	}
	lfn^ = {}
	if entry.attributes & ATTR_VOLUME != 0 || entry.short[0] == '.' {
		raw_entry_destroy(&entry, allocator)
		return {}, false, false
	}
	return entry, true, false
}

@(private = "package")
entry_name_matches :: proc(
	entry: ^Raw_Entry,
	name: string,
	allocator := context.allocator,
) -> bool {
	if entry == nil {return false}
	if len(entry.lfn) > 0 && strings.equal_fold(entry.lfn, name) {return true}
	short := short_name(entry.short, allocator)
	defer delete(short, allocator)
	return strings.equal_fold(short, name)
}

@(private = "package")
entry_copy :: proc(raw: ^Raw_Entry, allocator := context.allocator) -> Entry {
	short := short_name(raw.short, allocator)
	name := strings.clone(short, allocator)
	if len(raw.lfn) > 0 {
		delete(name, allocator)
		name = strings.clone(raw.lfn, allocator)
	}
	return Entry {
		name = name,
		short_name = short,
		is_directory = raw.attributes & ATTR_DIRECTORY != 0,
		is_read_only = raw.attributes & ATTR_READ_ONLY != 0,
		is_hidden = raw.attributes & ATTR_HIDDEN != 0,
		is_system = raw.attributes & ATTR_SYSTEM != 0,
		first_cluster = raw.first_cluster,
		size = u64(raw.size),
		modified_date = raw.modified_date,
		modified_time = raw.modified_time,
	}
}

@(private = "package")
path_components :: proc(path: string, allocator := context.allocator) -> ([]string, Error) {
	if len(path) > MAX_PATH_BYTES ||
	   strings.contains(path, "\\") ||
	   strings.has_prefix(path, "/") {
		return nil, error_make(.Invalid_Path, "FAT path must be relative and use slash separators")
	}
	if path == "" || path == "." {return make([]string, 0, allocator), {}}
	raw := strings.split(path, "/", allocator)
	for component in raw {
		if component == "" || component == "." || component == ".." {
			delete(raw, allocator)
			return nil, error_make(
				.Invalid_Path,
				"FAT path contains traversal or an empty component",
			)
		}
	}
	return raw, {}
}

@(private = "package")
find_child :: proc(volume: ^Volume, directory_cluster: u32, name: string) -> (Raw_Entry, Error) {
	state := Find_State {
		name = name,
	}
	err := scan_directory(
		volume,
		directory_cluster,
		proc(raw: ^Raw_Entry, _: u64, ctx: rawptr) -> bool {
			find := (^Find_State)(ctx)
			if entry_name_matches(raw, find.name) {
				find.result = raw^
				raw.lfn = ""
				return false
			}
			return true
		},
		&state,
	)
	if err.code != .None {return {}, err}
	if state.result.short == {} {return {}, error_make(.Not_Found, "FAT path does not exist")}
	return state.result, {}
}

@(private = "file")
Find_State :: struct {
	name:   string,
	result: Raw_Entry,
}

@(private = "package")
resolve :: proc(volume: ^Volume, path: string) -> (Raw_Entry, bool, Error) {
	components, path_error := path_components(path, context.temp_allocator)
	if path_error.code != .None {return {}, false, path_error}
	if len(components) == 0 {
		return Raw_Entry {
			attributes = ATTR_DIRECTORY,
			first_cluster = volume.info.root_cluster,
		}, true, {}
	}
	cluster := volume.info.root_cluster
	for component, index in components {
		entry, find_error := find_child(volume, cluster, component)
		if find_error.code != .None {return {}, false, find_error}
		if index + 1 < len(components) && entry.attributes & ATTR_DIRECTORY == 0 {
			raw_entry_destroy(&entry)
			return {}, false, error_make(.Not_Directory, "FAT path crosses a regular file")
		}
		if index + 1 == len(components) {return entry, false, {}}
		cluster = entry.first_cluster
		raw_entry_destroy(&entry)
	}
	return {}, false, error_make(.Internal, "FAT path resolution failed")
}

@(private = "package")
Directory_Visitor :: proc(raw: ^Raw_Entry, ordinal: u64, ctx: rawptr) -> bool

@(private = "package")
scan_directory :: proc(
	volume: ^Volume,
	first_cluster: u32,
	visitor: Directory_Visitor,
	ctx: rawptr,
) -> Error {
	if volume == nil ||
	   first_cluster < 2 {return error_make(.Invalid_FAT, "directory has no FAT chain")}
	cluster := first_cluster
	visited: u32
	ordinal: u64
	lfn: Lfn_State
	sector: [SECTOR_BYTES]u8
	for {
		if visited > volume.info.cluster_count {
			return error_make(.Invalid_FAT, "directory FAT chain contains a cycle")
		}
		lba, lba_error := cluster_lba(volume, cluster)
		if lba_error.code != .None {return lba_error}
		for sector_index in 0 ..< int(volume.info.sectors_per_cluster) {
			if !volume.device.read(volume.device.ctx, lba + u64(sector_index), sector[:]) {
				return error_make(.IO, "cannot read a FAT32 directory sector")
			}
			for offset := 0; offset < SECTOR_BYTES; offset += 32 {
				raw, present, ended := parse_directory_slot(sector[offset:][:32], &lfn)
				if ended {return {}}
				if !present {continue}
				keep_going := visitor == nil || visitor(&raw, ordinal, ctx)
				ordinal += 1
				raw_entry_destroy(&raw)
				if !keep_going {return {}}
			}
		}
		visited += 1
		next, end, next_error := chain_next(volume, cluster)
		if next_error.code != .None {return next_error}
		if end {return {}}
		cluster = next
	}
}

list :: proc(
	volume: ^Volume,
	path: string,
	cursor: u64,
	limit: int,
	allocator := context.allocator,
) -> (
	Page,
	Error,
) {
	if volume == nil || limit <= 0 || limit > MAX_PAGE_ENTRIES {
		return {}, error_make(.Invalid_Argument, "directory page size is outside its bound")
	}
	directory, _, resolve_error := resolve(volume, path)
	if resolve_error.code != .None {return {}, resolve_error}
	defer raw_entry_destroy(&directory)
	if directory.attributes & ATTR_DIRECTORY == 0 {
		return {}, error_make(.Not_Directory, "FAT path is not a directory")
	}
	page := Page {
		entries = make([dynamic]Entry, 0, limit, allocator),
	}
	state := List_State {
		cursor    = cursor,
		limit     = limit,
		page      = &page,
		allocator = allocator,
	}
	scan_error := scan_directory(volume, directory.first_cluster, list_visit, &state)
	if scan_error.code != .None {
		page_destroy(&page, allocator)
		return {}, scan_error
	}
	return page, {}
}

@(private = "file")
List_State :: struct {
	cursor:    u64,
	limit:     int,
	page:      ^Page,
	allocator: runtime.Allocator,
}

@(private = "file")
list_visit :: proc(raw: ^Raw_Entry, ordinal: u64, ctx: rawptr) -> bool {
	state := (^List_State)(ctx)
	if ordinal < state.cursor {return true}
	if len(state.page.entries) >= state.limit {
		state.page.has_more = true
		state.page.next_cursor = ordinal
		return false
	}
	append(&state.page.entries, entry_copy(raw, state.allocator))
	state.page.next_cursor = ordinal + 1
	return true
}

stat :: proc(volume: ^Volume, path: string) -> (Stat, Error) {
	entry, is_root, resolve_error := resolve(volume, path)
	if resolve_error.code == .Not_Found {return {}, {}}
	if resolve_error.code != .None {return {}, resolve_error}
	defer raw_entry_destroy(&entry)
	return Stat {
		exists = true,
		is_directory = is_root || entry.attributes & ATTR_DIRECTORY != 0,
		is_read_only = entry.attributes & ATTR_READ_ONLY != 0,
		is_hidden = entry.attributes & ATTR_HIDDEN != 0,
		is_system = entry.attributes & ATTR_SYSTEM != 0,
		first_cluster = entry.first_cluster,
		size = u64(entry.size),
		modified_date = entry.modified_date,
		modified_time = entry.modified_time,
	}, {}
}
