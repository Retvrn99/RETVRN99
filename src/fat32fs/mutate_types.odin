// SPDX-License-Identifier: GPL-3.0-only
package fat32fs

MAX_LFN_UNITS :: 255
MAX_LFN_SLOTS :: (MAX_LFN_UNITS + 12) / 13
MAX_ENTRY_SLOTS :: MAX_LFN_SLOTS + 1

File_Writer :: struct {
	volume:          ^Volume,
	entry_lba:       u64,
	entry_offset:    u16,
	lfn_slots:       [MAX_LFN_SLOTS]Slot_Position,
	lfn_count:       int,
	first_cluster:   u32,
	current_cluster: u32,
	cluster_offset:  u64,
	written:         u64,
	expected:        u64,
	active:          bool,
}

@(private = "package")
Slot_Position :: struct {
	lba:    u64,
	offset: u16,
}

@(private = "package")
Entry_Location :: struct {
	raw:        Raw_Entry,
	short_slot: Slot_Position,
	lfn_slots:  [MAX_LFN_SLOTS]Slot_Position,
	lfn_count:  int,
}

@(private = "package")
entry_location_destroy :: proc(location: ^Entry_Location, allocator := context.allocator) {
	if location == nil {return}
	raw_entry_destroy(&location.raw, allocator)
	location^ = {}
}
