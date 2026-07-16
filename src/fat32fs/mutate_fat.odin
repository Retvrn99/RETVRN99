// SPDX-License-Identifier: GPL-3.0-only
package fat32fs

import "core:strings"
import "core:time"

FAT_EOC :: u32(0x0FFF_FFFF)
ATTR_ARCHIVE :: u8(0x20)

@(private = "package")
invalidate_fsinfo :: proc(volume: ^Volume) -> Error {
	if volume == nil {return error_make(.Invalid_Argument, "FAT volume is unavailable")}
	vbr: [SECTOR_BYTES]u8
	if !volume.device.read(volume.device.ctx, volume.info.partition_lba, vbr[:]) {
		return error_make(.IO, "cannot read the FAT32 boot sector for FSInfo update")
	}
	fsinfo_sector := u64(get_u16le(vbr[:], 48))
	backup_boot := u64(get_u16le(vbr[:], 50))
	if fsinfo_sector == 0 ||
	   fsinfo_sector >= u64(volume.info.reserved_sectors) ||
	   backup_boot == 0 ||
	   backup_boot + fsinfo_sector >= u64(volume.info.reserved_sectors) {
		return error_make(.Invalid_VBR, "FAT32 FSInfo locations are invalid")
	}
	locations := [2]u64 {
		volume.info.partition_lba + fsinfo_sector,
		volume.info.partition_lba + backup_boot + fsinfo_sector,
	}
	for location in locations {
		sector: [SECTOR_BYTES]u8
		if !volume.device.read(volume.device.ctx, location, sector[:]) {
			return error_make(.IO, "cannot read a FAT32 FSInfo sector")
		}
		if get_u32le(sector[:], 0) != 0x4161_5252 ||
		   get_u32le(sector[:], 484) != 0x6141_7272 ||
		   get_u32le(sector[:], 508) != 0xAA55_0000 {
			return error_make(.Invalid_VBR, "FAT32 FSInfo signature is invalid")
		}
		put_u32le(sector[:], 488, 0xFFFF_FFFF)
		put_u32le(sector[:], 492, 0xFFFF_FFFF)
		if !volume.device.write(volume.device.ctx, location, sector[:]) {
			return error_make(.IO, "cannot update a FAT32 FSInfo sector")
		}
	}
	return {}
}

@(private = "package")
put_u16le :: proc(data: []u8, offset: int, value: u16) {
	data[offset] = u8(value)
	data[offset + 1] = u8(value >> 8)
}

@(private = "package")
put_u32le :: proc(data: []u8, offset: int, value: u32) {
	for index in 0 ..< 4 {data[offset + index] = u8(value >> u32(index * 8))}
}

@(private = "package")
set_fat_entry :: proc(volume: ^Volume, cluster, value: u32) -> Error {
	if volume == nil || cluster < 2 || cluster >= volume.info.cluster_count + 2 {
		return error_make(.Invalid_FAT, "cannot update a FAT entry outside the data region")
	}
	byte_offset := u64(cluster) * 4
	sector_index := byte_offset / SECTOR_BYTES
	within := int(byte_offset % SECTOR_BYTES)
	sector: [SECTOR_BYTES]u8
	cached_slot := fat_cache_invalidate(volume, sector_index)
	primary_value: u32
	wrote_copy := false
	for copy_index in 0 ..< int(volume.info.fat_count) {
		lba :=
			volume.info.fat_lba + u64(copy_index) * u64(volume.info.sectors_per_fat) + sector_index
		if !volume.device.read(volume.device.ctx, lba, sector[:]) {
			if wrote_copy {fat_mutation_committed(volume)}
			return error_make(.IO, "cannot read a FAT sector for update")
		}
		old := get_u32le(sector[:], within)
		updated := old & 0xF000_0000 | value & 0x0FFF_FFFF
		put_u32le(sector[:], within, updated)
		if !volume.device.write(volume.device.ctx, lba, sector[:]) {
			fat_mutation_committed(volume)
			return error_make(.IO, "cannot write a FAT sector")
		}
		wrote_copy = true
		if copy_index == 0 {primary_value = updated}
	}
	fat_mutation_committed(volume)
	fat_cache_revalidate_entry(volume, cached_slot, sector_index, within, primary_value)
	if value & 0x0FFF_FFFF == 0 &&
	   (volume.allocation_cursor < 2 || cluster < volume.allocation_cursor) {
		volume.allocation_cursor = cluster
	}
	return {}
}

@(private = "package")
zero_cluster :: proc(volume: ^Volume, cluster: u32) -> Error {
	lba, lba_error := cluster_lba(volume, cluster)
	if lba_error.code != .None {return lba_error}
	zero: [FAT_CACHE_PAGE_BYTES]u8
	sector_index := 0
	for sector_index < int(volume.info.sectors_per_cluster) {
		sector_count := min(
			FAT_CACHE_PAGE_SECTORS,
			int(volume.info.sectors_per_cluster) - sector_index,
		)
		if !volume.device.write(
			volume.device.ctx,
			lba + u64(sector_index),
			zero[:sector_count * SECTOR_BYTES],
		) {
			return error_make(.IO, "cannot clear an allocated FAT cluster")
		}
		sector_index += sector_count
	}
	return {}
}

@(private = "package")
allocate_cluster :: proc(volume: ^Volume) -> (u32, Error) {
	if volume == nil {return 0, error_make(.Invalid_Argument, "FAT volume is unavailable")}
	limit := volume.info.cluster_count + 2
	cluster := volume.allocation_cursor
	if cluster < 2 || cluster >= limit {cluster = 2}
	for scanned := u32(0); scanned < volume.info.cluster_count; scanned += 1 {
		value, read_error := fat_entry(volume, cluster)
		if read_error.code != .None {return 0, read_error}
		if value == 0 {
			set_error := set_fat_entry(volume, cluster, FAT_EOC)
			if set_error.code != .None {return 0, set_error}
			clear_error := zero_cluster(volume, cluster)
			if clear_error.code != .None {
				_ = set_fat_entry(volume, cluster, 0)
				return 0, clear_error
			}
			fsinfo_error := invalidate_fsinfo(volume)
			if fsinfo_error.code != .None {
				_ = set_fat_entry(volume, cluster, 0)
				return 0, fsinfo_error
			}
			volume.allocation_cursor = cluster + 1
			if volume.allocation_cursor >= limit {volume.allocation_cursor = 2}
			return cluster, {}
		}
		cluster += 1
		if cluster >= limit {cluster = 2}
	}
	return 0, error_make(.No_Space, "FAT32 image has no free clusters")
}

@(private = "package")
free_chain :: proc(volume: ^Volume, first_cluster: u32) -> Error {
	if first_cluster == 0 {return {}}
	cluster := first_cluster
	for visited in 0 ..< volume.info.cluster_count + 1 {
		_ = visited
		value, read_error := fat_entry(volume, cluster)
		if read_error.code != .None {return read_error}
		clear_error := set_fat_entry(volume, cluster, 0)
		if clear_error.code != .None {return clear_error}
		if value >= 0x0FFF_FFF8 {return invalidate_fsinfo(volume)}
		if value < 2 || value == 0x0FFF_FFF7 || value >= volume.info.cluster_count + 2 {
			return error_make(.Invalid_FAT, "cannot free an invalid FAT chain")
		}
		cluster = value
	}
	return error_make(.Invalid_FAT, "cannot free a cyclic FAT chain")
}

@(private = "package")
write_slot :: proc(volume: ^Volume, position: Slot_Position, slot: []u8) -> Error {
	if len(slot) != 32 || position.offset > SECTOR_BYTES - 32 || position.offset % 32 != 0 {
		return error_make(.Internal, "invalid FAT directory slot update")
	}
	sector: [SECTOR_BYTES]u8
	if !volume.device.read(volume.device.ctx, position.lba, sector[:]) {
		return error_make(.IO, "cannot read a FAT directory sector for update")
	}
	copy(sector[int(position.offset):][:32], slot)
	if !volume.device.write(volume.device.ctx, position.lba, sector[:]) {
		return error_make(.IO, "cannot write a FAT directory sector")
	}
	return {}
}

@(private = "package")
mark_slot_deleted :: proc(volume: ^Volume, position: Slot_Position) -> Error {
	sector: [SECTOR_BYTES]u8
	if !volume.device.read(volume.device.ctx, position.lba, sector[:]) {
		return error_make(.IO, "cannot read a FAT directory entry for deletion")
	}
	sector[int(position.offset)] = 0xE5
	if !volume.device.write(volume.device.ctx, position.lba, sector[:]) {
		return error_make(.IO, "cannot delete a FAT directory entry")
	}
	return {}
}

@(private = "package")
find_free_slots :: proc(
	volume: ^Volume,
	directory_cluster: u32,
	needed: int,
) -> (
	[MAX_ENTRY_SLOTS]Slot_Position,
	Error,
) {
	positions: [MAX_ENTRY_SLOTS]Slot_Position
	if needed < 1 || needed > MAX_ENTRY_SLOTS {
		return positions, error_make(.Internal, "invalid FAT directory entry span")
	}
	cluster := directory_cluster
	last_cluster := cluster
	run := 0
	sector: [SECTOR_BYTES]u8
	for visited in 0 ..< volume.info.cluster_count + 1 {
		_ = visited
		lba, lba_error := cluster_lba(volume, cluster)
		if lba_error.code != .None {return positions, lba_error}
		for sector_index in 0 ..< int(volume.info.sectors_per_cluster) {
			sector_lba := lba + u64(sector_index)
			if !volume.device.read(volume.device.ctx, sector_lba, sector[:]) {
				return positions, error_make(.IO, "cannot scan a FAT directory for free slots")
			}
			for offset := 0; offset < SECTOR_BYTES; offset += 32 {
				if sector[offset] == 0 || sector[offset] == 0xE5 {
					positions[run] = Slot_Position {
						lba    = sector_lba,
						offset = u16(offset),
					}
					run += 1
					if run == needed {return positions, {}}
				} else {
					run = 0
				}
			}
		}
		last_cluster = cluster
		next, end, next_error := chain_next(volume, cluster)
		if next_error.code != .None {return positions, next_error}
		if end {break}
		cluster = next
	}
	new_cluster, allocation_error := allocate_cluster(volume)
	if allocation_error.code != .None {return positions, allocation_error}
	link_error := set_fat_entry(volume, last_cluster, new_cluster)
	if link_error.code != .None {
		_ = set_fat_entry(volume, new_cluster, 0)
		return positions, link_error
	}
	lba, lba_error := cluster_lba(volume, new_cluster)
	if lba_error.code != .None {return positions, lba_error}
	for sector_index in 0 ..< int(volume.info.sectors_per_cluster) {
		for offset := 0; offset < SECTOR_BYTES && run < needed; offset += 32 {
			positions[run] = Slot_Position {
				lba    = lba + u64(sector_index),
				offset = u16(offset),
			}
			run += 1
		}
		if run == needed {return positions, {}}
	}
	return positions, error_make(.Internal, "FAT directory cluster cannot hold a directory entry")
}

@(private = "package")
fat_datetime_now :: proc() -> (date, clock: u16) {
	year, month, day := time.date(time.now())
	hour, minute, second := time.clock_from_time(time.now())
	year = clamp(year, 1980, 2107)
	date = u16((year - 1980) << 9 | int(month) << 5 | day)
	clock = u16(hour << 11 | minute << 5 | second / 2)
	return
}

@(private = "package")
make_short_slot :: proc(short: [11]u8, attributes: u8, cluster: u32, size: u32) -> [32]u8 {
	slot: [32]u8
	short_copy := short
	copy(slot[:11], short_copy[:])
	slot[11] = attributes
	date, clock := fat_datetime_now()
	put_u16le(slot[:], 14, clock)
	put_u16le(slot[:], 16, date)
	put_u16le(slot[:], 18, date)
	put_u16le(slot[:], 20, u16(cluster >> 16))
	put_u16le(slot[:], 22, clock)
	put_u16le(slot[:], 24, date)
	put_u16le(slot[:], 26, u16(cluster))
	put_u32le(slot[:], 28, size)
	return slot
}

@(private = "package")
make_lfn_slot :: proc(sequence: int, count: int, checksum: u8, units: []u16) -> [32]u8 {
	slot: [32]u8
	slot[0] = u8(sequence) | (sequence == count ? u8(0x40) : u8(0))
	slot[11] = ATTR_LFN
	slot[13] = checksum
	base := (sequence - 1) * 13
	for offset, index in LFN_OFFSETS {
		unit_index := base + index
		value: u16 = 0xFFFF
		if unit_index <
		   len(units) {value = units[unit_index]} else if unit_index == len(units) {value = 0}
		put_u16le(slot[:], offset, value)
	}
	return slot
}

@(private = "package")
insert_entry :: proc(
	volume: ^Volume,
	parent_cluster: u32,
	name: string,
	attributes: u8,
	first_cluster: u32,
	size: u32,
) -> (
	Entry_Location,
	Error,
) {
	short, direct, usable_short := pack_direct_short_name(name)
	if !usable_short {short = generated_short_name(name)}
	availability_error := directory_name_available(volume, parent_cluster, name, short)
	if availability_error.code != .None {return {}, availability_error}
	units := utf16_name_units(name, context.temp_allocator)
	lfn_count := direct ? 0 : (len(units) + 12) / 13
	positions, slots_error := find_free_slots(volume, parent_cluster, lfn_count + 1)
	if slots_error.code != .None {return {}, slots_error}
	checksum := lfn_checksum(short)
	for index in 0 ..< lfn_count {
		sequence := lfn_count - index
		slot := make_lfn_slot(sequence, lfn_count, checksum, units)
		write_error := write_slot(volume, positions[index], slot[:])
		if write_error.code != .None {return {}, write_error}
	}
	short_slot := make_short_slot(short, attributes, first_cluster, size)
	write_error := write_slot(volume, positions[lfn_count], short_slot[:])
	if write_error.code != .None {return {}, write_error}
	location := Entry_Location {
		raw = Raw_Entry {
			short = short,
			attributes = attributes,
			first_cluster = first_cluster,
			size = size,
			lfn = direct ? "" : strings.clone(name),
		},
		short_slot = positions[lfn_count],
		lfn_count = lfn_count,
	}
	for index in 0 ..< lfn_count {location.lfn_slots[index] = positions[index]}
	return location, {}
}

@(private = "package")
locate_entry :: proc(
	volume: ^Volume,
	parent_cluster: u32,
	name: string,
) -> (
	Entry_Location,
	Error,
) {
	location: Entry_Location
	cluster := parent_cluster
	lfn: Lfn_State
	pending: [MAX_LFN_SLOTS]Slot_Position
	pending_count := 0
	sector: [SECTOR_BYTES]u8
	for visited in 0 ..< volume.info.cluster_count + 1 {
		_ = visited
		lba, lba_error := cluster_lba(volume, cluster)
		if lba_error.code != .None {return {}, lba_error}
		for sector_index in 0 ..< int(volume.info.sectors_per_cluster) {
			sector_lba := lba + u64(sector_index)
			if !volume.device.read(volume.device.ctx, sector_lba, sector[:]) {
				return {}, error_make(.IO, "cannot scan a FAT directory entry")
			}
			for offset := 0; offset < SECTOR_BYTES; offset += 32 {
				slot := sector[offset:][:32]
				if slot[0] == 0 {return {}, error_make(.Not_Found, "FAT path does not exist")}
				position := Slot_Position {
					lba    = sector_lba,
					offset = u16(offset),
				}
				if slot[0] == 0xE5 {
					lfn = {}
					pending_count = 0
					continue
				}
				if slot[11] & 0x3F == ATTR_LFN {
					if pending_count < MAX_LFN_SLOTS {
						pending[pending_count] = position
						pending_count += 1
					} else {
						pending_count = 0
					}
					_, _, _ = parse_directory_slot(slot, &lfn)
					continue
				}
				raw, present, _ := parse_directory_slot(slot, &lfn)
				if present && entry_name_matches(&raw, name) {
					location.raw = raw
					raw.lfn = ""
					location.short_slot = position
					if len(location.raw.lfn) > 0 {
						location.lfn_count = pending_count
						for index in 0 ..< pending_count {location.lfn_slots[index] = pending[index]}
					}
					raw_entry_destroy(&raw)
					return location, {}
				}
				raw_entry_destroy(&raw)
				pending_count = 0
			}
		}
		next, end, next_error := chain_next(volume, cluster)
		if next_error.code != .None {return {}, next_error}
		if end {return {}, error_make(.Not_Found, "FAT path does not exist")}
		cluster = next
	}
	return {}, error_make(.Invalid_FAT, "FAT directory chain contains a cycle")
}

@(private = "package")
delete_location :: proc(volume: ^Volume, location: ^Entry_Location) -> Error {
	if location == nil {return error_make(.Invalid_Argument, "FAT entry location is unavailable")}
	for index in 0 ..< location.lfn_count {
		delete_error := mark_slot_deleted(volume, location.lfn_slots[index])
		if delete_error.code != .None {return delete_error}
	}
	return mark_slot_deleted(volume, location.short_slot)
}

@(private = "package")
update_dotdot :: proc(volume: ^Volume, directory_cluster, parent_cluster: u32) -> Error {
	lba, lba_error := cluster_lba(volume, directory_cluster)
	if lba_error.code != .None {return lba_error}
	sector: [SECTOR_BYTES]u8
	if !volume.device.read(volume.device.ctx, lba, sector[:]) {
		return error_make(.IO, "cannot read a moved FAT directory")
	}
	if sector[32] != '.' || sector[33] != '.' || sector[43] & ATTR_DIRECTORY == 0 {
		return error_make(.Invalid_FAT, "moved FAT directory has no valid parent entry")
	}
	stored_parent := parent_cluster == volume.info.root_cluster ? u32(0) : parent_cluster
	put_u16le(sector[:], 32 + 20, u16(stored_parent >> 16))
	put_u16le(sector[:], 32 + 26, u16(stored_parent))
	if !volume.device.write(volume.device.ctx, lba, sector[:]) {
		return error_make(.IO, "cannot update a moved FAT directory parent entry")
	}
	return {}
}
