// SPDX-License-Identifier: GPL-3.0-only
package fat32fs

import disk "../disk"

SECTOR_BYTES :: 512
MAX_PAGE_ENTRIES :: 256
MAX_PATH_BYTES :: 1024
MAX_FILE_TRANSFER_BYTES :: 128 * 1024
FAT_CACHE_PAGE_BYTES :: 4 * 1024
FAT_CACHE_PAGE_SECTORS :: FAT_CACHE_PAGE_BYTES / SECTOR_BYTES
FAT_CACHE_SLOT_COUNT :: 8

Error_Code :: enum u16 {
	None,
	Invalid_Argument,
	Invalid_MBR,
	Invalid_VBR,
	Invalid_FAT,
	Invalid_Path,
	Not_Found,
	Not_Directory,
	Is_Directory,
	Out_Of_Range,
	IO,
	Name_Collision,
	No_Space,
	Read_Only,
	Mutation_Conflict,
	Internal,
}

MAX_ERROR_TEXT_BYTES :: 384

Error :: struct {
	code:              Error_Code,
	diagnostic:        [MAX_ERROR_TEXT_BYTES]u8,
	diagnostic_length: u16,
}

error_ok :: proc(err: ^Error) -> bool {
	return err == nil || err.code == .None
}

error_text :: proc(err: ^Error) -> string {
	if err == nil || err.diagnostic_length == 0 {return ""}
	return string(err.diagnostic[:int(err.diagnostic_length)])
}

Volume_Info :: struct {
	partition_lba:       u64,
	partition_sectors:   u64,
	sectors_per_cluster: u8,
	reserved_sectors:    u16,
	fat_count:           u8,
	sectors_per_fat:     u32,
	fat_lba:             u64,
	data_lba:            u64,
	root_cluster:        u32,
	cluster_count:       u32,
}

@(private = "package")
Fat_Cache_Slot :: struct {
	data:     [FAT_CACHE_PAGE_BYTES]u8,
	page:     u64,
	used:     int,
	last_use: u64,
	valid:    bool,
}

Volume :: struct {
	device:            disk.Block_Device,
	info:              Volume_Info,
	fat_cache:         [FAT_CACHE_SLOT_COUNT]Fat_Cache_Slot,
	fat_cache_clock:   u64,
	allocation_cursor: u32,
	mutation_epoch:    u64,
}

Entry :: struct {
	name:          string,
	short_name:    string,
	is_directory:  bool,
	is_read_only:  bool,
	is_hidden:     bool,
	is_system:     bool,
	first_cluster: u32,
	size:          u64,
	modified_date: u16,
	modified_time: u16,
}

entry_destroy :: proc(entry: ^Entry, allocator := context.allocator) {
	if entry == nil {return}
	delete(entry.name, allocator)
	delete(entry.short_name, allocator)
	entry^ = {}
}

Page :: struct {
	entries:     [dynamic]Entry,
	next_cursor: u64,
	has_more:    bool,
}

page_destroy :: proc(page: ^Page, allocator := context.allocator) {
	if page == nil {return}
	for &entry in page.entries {entry_destroy(&entry, allocator)}
	delete(page.entries)
	page^ = {}
}

Stat :: struct {
	exists:        bool,
	is_directory:  bool,
	is_read_only:  bool,
	is_hidden:     bool,
	is_system:     bool,
	first_cluster: u32,
	size:          u64,
	modified_date: u16,
	modified_time: u16,
}

Read_Result :: struct {
	offset: u64,
	total:  u64,
	data:   []u8,
}

File_Reader :: struct {
	volume:          ^Volume,
	current_cluster: u32,
	cluster_offset:  u64,
	offset:          u64,
	total:           u64,
	visited:         u32,
	mutation_epoch:  u64,
	active:          bool,
}

read_result_destroy :: proc(result: ^Read_Result, allocator := context.allocator) {
	if result == nil {return}
	delete(result.data, allocator)
	result^ = {}
}
