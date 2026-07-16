// SPDX-License-Identifier: GPL-3.0-only
package fat32fs

import "core:strings"

MAX_MUTATION_CHUNK_BYTES :: 128 * 1024
MAX_RECURSION_DEPTH :: 64

@(private = "package")
resolve_directory_cluster :: proc(volume: ^Volume, path: string) -> (u32, Error) {
	entry, is_root, resolve_error := resolve(volume, path)
	if resolve_error.code != .None {return 0, resolve_error}
	defer raw_entry_destroy(&entry)
	if !is_root && entry.attributes & ATTR_DIRECTORY == 0 {
		return 0, error_make(.Not_Directory, "FAT path is not a directory")
	}
	return entry.first_cluster, {}
}

mkdir :: proc(volume: ^Volume, path: string) -> Error {
	if volume == nil {return error_make(.Invalid_Argument, "FAT volume is unavailable")}
	parent_path, name, path_error := split_parent(path)
	if path_error.code != .None {return path_error}
	defer delete(parent_path)
	defer delete(name)
	parent_cluster, parent_error := resolve_directory_cluster(volume, parent_path)
	if parent_error.code != .None {return parent_error}
	short, _, usable_short := pack_direct_short_name(name)
	if !usable_short {short = generated_short_name(name)}
	availability_error := directory_name_available(volume, parent_cluster, name, short)
	if availability_error.code != .None {return availability_error}
	cluster, allocation_error := allocate_cluster(volume)
	if allocation_error.code != .None {return allocation_error}
	lba, lba_error := cluster_lba(volume, cluster)
	if lba_error.code != .None {
		_ = free_chain(volume, cluster)
		return lba_error
	}
	sector: [SECTOR_BYTES]u8
	dot := [11]u8{'.', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' '}
	dotdot := [11]u8{'.', '.', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' '}
	dot_slot := make_short_slot(dot, ATTR_DIRECTORY, cluster, 0)
	dotdot_cluster := parent_cluster == volume.info.root_cluster ? u32(0) : parent_cluster
	dotdot_slot := make_short_slot(dotdot, ATTR_DIRECTORY, dotdot_cluster, 0)
	copy(sector[:32], dot_slot[:])
	copy(sector[32:64], dotdot_slot[:])
	if !volume.device.write(volume.device.ctx, lba, sector[:]) {
		_ = free_chain(volume, cluster)
		return error_make(.IO, "cannot initialize a FAT directory")
	}
	location, insert_error := insert_entry(
		volume,
		parent_cluster,
		name,
		ATTR_DIRECTORY,
		cluster,
		0,
	)
	entry_location_destroy(&location)
	if insert_error.code != .None {
		_ = free_chain(volume, cluster)
		return insert_error
	}
	return {}
}

file_begin :: proc(volume: ^Volume, path: string, size: u64) -> (File_Writer, Error) {
	if volume == nil || size > 0xFFFF_FFFF {
		return {}, error_make(.Invalid_Argument, "FAT file exceeds the 4 GiB FAT32 file-size limit")
	}
	parent_path, name, path_error := split_parent(path)
	if path_error.code != .None {return {}, path_error}
	defer delete(parent_path)
	defer delete(name)
	parent_cluster, parent_error := resolve_directory_cluster(volume, parent_path)
	if parent_error.code != .None {return {}, parent_error}
	location, insert_error := insert_entry(volume, parent_cluster, name, ATTR_ARCHIVE, 0, 0)
	if insert_error.code != .None {return {}, insert_error}
	writer := File_Writer {
		volume       = volume,
		entry_lba    = location.short_slot.lba,
		entry_offset = location.short_slot.offset,
		lfn_count    = location.lfn_count,
		expected     = size,
		active       = true,
	}
	for index in 0 ..< location.lfn_count {writer.lfn_slots[index] = location.lfn_slots[index]}
	entry_location_destroy(&location)
	return writer, {}
}

file_write :: proc(writer: ^File_Writer, data: []u8) -> Error {
	if writer == nil || !writer.active || writer.volume == nil {
		return error_make(.Invalid_Argument, "FAT file writer is not active")
	}
	if len(data) > MAX_MUTATION_CHUNK_BYTES || writer.written + u64(len(data)) > writer.expected {
		return error_make(
			.Out_Of_Range,
			"FAT file write exceeds its bounded request or declared size",
		)
	}
	volume := writer.volume
	cluster_bytes := u64(volume.info.sectors_per_cluster) * SECTOR_BYTES
	consumed := 0
	sector: [SECTOR_BYTES]u8
	for consumed < len(data) {
		if writer.current_cluster == 0 || writer.cluster_offset == cluster_bytes {
			cluster, allocation_error := allocate_cluster(volume)
			if allocation_error.code != .None {return allocation_error}
			if writer.current_cluster != 0 {
				link_error := set_fat_entry(volume, writer.current_cluster, cluster)
				if link_error.code != .None {
					_ = free_chain(volume, cluster)
					return link_error
				}
			}
			if writer.first_cluster == 0 {writer.first_cluster = cluster}
			writer.current_cluster = cluster
			writer.cluster_offset = 0
		}
		lba, lba_error := cluster_lba(volume, writer.current_cluster)
		if lba_error.code != .None {return lba_error}
		sector_index := writer.cluster_offset / SECTOR_BYTES
		within_sector := int(writer.cluster_offset % SECTOR_BYTES)
		sector_lba := lba + sector_index
		cluster_remaining := cluster_bytes - writer.cluster_offset
		data_remaining := len(data) - consumed
		if within_sector == 0 && data_remaining >= SECTOR_BYTES {
			bulk := int(min(u64(data_remaining), cluster_remaining) / SECTOR_BYTES * SECTOR_BYTES)
			if !volume.device.write(volume.device.ctx, sector_lba, data[consumed:][:bulk]) {
				return error_make(.IO, "cannot write FAT file data")
			}
			consumed += bulk
			writer.cluster_offset += u64(bulk)
			writer.written += u64(bulk)
			continue
		}
		if !volume.device.read(volume.device.ctx, sector_lba, sector[:]) {
			return error_make(.IO, "cannot read allocated FAT file data")
		}
		count := min(SECTOR_BYTES - within_sector, len(data) - consumed)
		copy(sector[within_sector:][:count], data[consumed:][:count])
		if !volume.device.write(volume.device.ctx, sector_lba, sector[:]) {
			return error_make(.IO, "cannot write FAT file data")
		}
		consumed += count
		writer.cluster_offset += u64(count)
		writer.written += u64(count)
	}
	return {}
}

file_finish :: proc(writer: ^File_Writer) -> Error {
	if writer == nil || !writer.active || writer.volume == nil {
		return error_make(.Invalid_Argument, "FAT file writer is not active")
	}
	if writer.written != writer.expected {
		return error_make(.Out_Of_Range, "FAT file writer has not received its declared size")
	}
	sector: [SECTOR_BYTES]u8
	if !writer.volume.device.read(writer.volume.device.ctx, writer.entry_lba, sector[:]) {
		return error_make(.IO, "cannot read the FAT file entry for commit")
	}
	offset := int(writer.entry_offset)
	put_u16le(sector[:], offset + 20, u16(writer.first_cluster >> 16))
	put_u16le(sector[:], offset + 26, u16(writer.first_cluster))
	put_u32le(sector[:], offset + 28, u32(writer.expected))
	date, clock := fat_datetime_now()
	put_u16le(sector[:], offset + 22, clock)
	put_u16le(sector[:], offset + 24, date)
	if !writer.volume.device.write(writer.volume.device.ctx, writer.entry_lba, sector[:]) {
		return error_make(.IO, "cannot commit the FAT file entry")
	}
	writer.active = false
	return {}
}

file_cancel :: proc(writer: ^File_Writer) -> Error {
	if writer == nil || !writer.active || writer.volume == nil {return {}}
	free_error := free_chain(writer.volume, writer.first_cluster)
	if free_error.code != .None {return free_error}
	for index in 0 ..< writer.lfn_count {
		delete_error := mark_slot_deleted(writer.volume, writer.lfn_slots[index])
		if delete_error.code != .None {return delete_error}
	}
	delete_error := mark_slot_deleted(
		writer.volume,
		Slot_Position{lba = writer.entry_lba, offset = writer.entry_offset},
	)
	if delete_error.code == .None {writer.active = false}
	return delete_error
}

rename :: proc(volume: ^Volume, source, destination: string) -> Error {
	if volume == nil {return error_make(.Invalid_Argument, "FAT volume is unavailable")}
	source_parent, source_name, source_error := split_parent(source)
	if source_error.code != .None {return source_error}
	defer delete(source_parent)
	defer delete(source_name)
	destination_parent, destination_name, destination_error := split_parent(destination)
	if destination_error.code != .None {return destination_error}
	defer delete(destination_parent)
	defer delete(destination_name)
	parent_cluster, parent_error := resolve_directory_cluster(volume, source_parent)
	if parent_error.code != .None {return parent_error}
	source_location, locate_error := locate_entry(volume, parent_cluster, source_name)
	if locate_error.code != .None {return locate_error}
	defer entry_location_destroy(&source_location)
	destination_parent_cluster, destination_parent_error := resolve_directory_cluster(
		volume,
		destination_parent,
	)
	if destination_parent_error.code != .None {return destination_parent_error}
	if source_location.raw.attributes & ATTR_DIRECTORY != 0 &&
	   (strings.equal_fold(source, destination_parent) ||
			   len(destination_parent) > len(source) &&
				   destination_parent[len(source)] == '/' &&
				   strings.equal_fold(destination_parent[:len(source)], source)) {
		return error_make(.Invalid_Path, "FAT directory cannot be moved into its own descendant")
	}
	destination_location, insert_error := insert_entry(
		volume,
		destination_parent_cluster,
		destination_name,
		source_location.raw.attributes,
		source_location.raw.first_cluster,
		source_location.raw.size,
	)
	entry_location_destroy(&destination_location)
	if insert_error.code != .None {return insert_error}
	if source_location.raw.attributes & ATTR_DIRECTORY != 0 &&
	   parent_cluster != destination_parent_cluster {
		parent_update_error := update_dotdot(
			volume,
			source_location.raw.first_cluster,
			destination_parent_cluster,
		)
		if parent_update_error.code != .None {return parent_update_error}
	}
	return delete_location(volume, &source_location)
}

remove_recursive :: proc(volume: ^Volume, path: string) -> Error {
	return remove_recursive_depth(volume, path, 0)
}

@(private = "package")
remove_recursive_depth :: proc(volume: ^Volume, path: string, depth: int) -> Error {
	if volume == nil {return error_make(.Invalid_Argument, "FAT volume is unavailable")}
	if depth >= MAX_RECURSION_DEPTH {
		return error_make(.Invalid_Path, "FAT directory recursion exceeds the safety bound")
	}
	parent_path, name, path_error := split_parent(path)
	if path_error.code != .None {return path_error}
	defer delete(parent_path)
	defer delete(name)
	parent_cluster, parent_error := resolve_directory_cluster(volume, parent_path)
	if parent_error.code != .None {return parent_error}
	location, locate_error := locate_entry(volume, parent_cluster, name)
	if locate_error.code != .None {return locate_error}
	defer entry_location_destroy(&location)
	if location.raw.attributes & ATTR_DIRECTORY != 0 {
		for {
			page, list_error := list(volume, path, 0, 1)
			if list_error.code != .None {return list_error}
			if len(page.entries) == 0 {
				page_destroy(&page)
				break
			}
			child_name := strings.clone(page.entries[0].name)
			page_destroy(&page)
			child_path := strings.concatenate({path, "/", child_name})
			delete(child_name)
			child_error := remove_recursive_depth(volume, child_path, depth + 1)
			delete(child_path)
			if child_error.code != .None {return child_error}
		}
	}
	free_error := free_chain(volume, location.raw.first_cluster)
	if free_error.code != .None {return free_error}
	return delete_location(volume, &location)
}
