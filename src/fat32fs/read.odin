// SPDX-License-Identifier: GPL-3.0-only
package fat32fs

file_reader_begin :: proc(volume: ^Volume, path: string, offset: u64 = 0) -> (File_Reader, Error) {
	if volume == nil {return {}, error_make(.Invalid_Argument, "FAT volume is unavailable")}
	entry, is_root, resolve_error := resolve(volume, path)
	if resolve_error.code != .None {return {}, resolve_error}
	defer raw_entry_destroy(&entry)
	if is_root || entry.attributes & ATTR_DIRECTORY != 0 {
		return {}, error_make(.Is_Directory, "FAT path is a directory")
	}
	total := u64(entry.size)
	read_offset := min(offset, total)
	reader := File_Reader {
		volume         = volume,
		offset         = read_offset,
		total          = total,
		mutation_epoch = volume.mutation_epoch,
		active         = true,
	}
	if read_offset == total {return reader, {}}
	if entry.first_cluster < 2 {
		return {}, error_make(.Invalid_FAT, "non-empty file has no FAT chain")
	}
	cluster_bytes := u64(volume.info.sectors_per_cluster) * SECTOR_BYTES
	cluster_skip := read_offset / cluster_bytes
	reader.current_cluster = entry.first_cluster
	reader.cluster_offset = read_offset % cluster_bytes
	reader.visited = 1
	for skipped := u64(0); skipped < cluster_skip; skipped += 1 {
		if reader.visited >= volume.info.cluster_count {
			return {}, error_make(.Invalid_FAT, "file FAT chain contains a cycle")
		}
		next, end, next_error := chain_next(volume, reader.current_cluster)
		if next_error.code != .None {return {}, next_error}
		if end {return {}, error_make(.Invalid_FAT, "file FAT chain is shorter than its size")}
		reader.current_cluster = next
		reader.visited += 1
	}
	return reader, {}
}

file_reader_close :: proc(reader: ^File_Reader) {
	if reader == nil {return}
	reader^ = {}
}

@(private = "file")
file_reader_advance_cluster :: proc(reader: ^File_Reader) -> Error {
	volume := reader.volume
	if reader.visited >= volume.info.cluster_count {
		return error_make(.Invalid_FAT, "file FAT chain contains a cycle")
	}
	next, end, next_error := chain_next(volume, reader.current_cluster)
	if next_error.code != .None {return next_error}
	if end {return error_make(.Invalid_FAT, "file FAT chain is shorter than its size")}
	reader.current_cluster = next
	reader.cluster_offset = 0
	reader.visited += 1
	return {}
}

file_reader_read :: proc(reader: ^File_Reader, data: []u8) -> (int, Error) {
	if reader == nil || !reader.active || reader.volume == nil {
		return 0, error_make(.Invalid_Argument, "FAT file reader is not active")
	}
	if len(data) > MAX_FILE_TRANSFER_BYTES {
		return 0, error_make(.Out_Of_Range, "FAT file read exceeds the 128 KiB transfer bound")
	}
	volume := reader.volume
	if volume.mutation_epoch != reader.mutation_epoch {
		return 0, error_make(
			.Mutation_Conflict,
			"FAT volume changed while a file reader was active",
		)
	}
	wanted := int(min(u64(len(data)), reader.total - reader.offset))
	if wanted == 0 {return 0, {}}
	cluster_bytes := u64(volume.info.sectors_per_cluster) * SECTOR_BYTES
	written := 0
	sector: [SECTOR_BYTES]u8
	for written < wanted {
		if reader.cluster_offset == cluster_bytes {
			advance_error := file_reader_advance_cluster(reader)
			if advance_error.code != .None {return written, advance_error}
		}
		lba, lba_error := cluster_lba(volume, reader.current_cluster)
		if lba_error.code != .None {return written, lba_error}
		sector_index := reader.cluster_offset / SECTOR_BYTES
		within_sector := int(reader.cluster_offset % SECTOR_BYTES)
		available := min(
			u64(wanted - written),
			min(cluster_bytes - reader.cluster_offset, reader.total - reader.offset),
		)
		if within_sector == 0 && available >= SECTOR_BYTES {
			bulk := int(available / SECTOR_BYTES * SECTOR_BYTES)
			if !volume.device.read(volume.device.ctx, lba + sector_index, data[written:][:bulk]) {
				return written, error_make(.IO, "cannot read file data")
			}
			written += bulk
			reader.offset += u64(bulk)
			reader.cluster_offset += u64(bulk)
		} else {
			if !volume.device.read(volume.device.ctx, lba + sector_index, sector[:]) {
				return written, error_make(.IO, "cannot read file data")
			}
			count := min(SECTOR_BYTES - within_sector, int(available))
			copy(data[written:][:count], sector[within_sector:][:count])
			written += count
			reader.offset += u64(count)
			reader.cluster_offset += u64(count)
		}
		if volume.mutation_epoch != reader.mutation_epoch {
			return written, error_make(
				.Mutation_Conflict,
				"FAT volume changed while file data was read",
			)
		}
	}
	return written, {}
}

read_range :: proc(
	volume: ^Volume,
	path: string,
	offset, length: u64,
	allocator := context.allocator,
) -> (
	Read_Result,
	Error,
) {
	if volume == nil || length > u64(max(int)) {
		return {}, error_make(.Invalid_Argument, "FAT read request is too large")
	}
	reader, begin_error := file_reader_begin(volume, path, offset)
	if begin_error.code != .None {return {}, begin_error}
	defer file_reader_close(&reader)
	total := reader.total
	read_offset := reader.offset
	wanted := min(length, total - read_offset)
	result := Read_Result {
		offset = read_offset,
		total  = total,
		data   = make([]u8, int(wanted), allocator),
	}
	written := u64(0)
	for written < wanted {
		chunk := int(min(u64(MAX_FILE_TRANSFER_BYTES), wanted - written))
		count, read_error := file_reader_read(&reader, result.data[int(written):][:chunk])
		if read_error.code != .None || count != chunk {
			read_result_destroy(&result, allocator)
			if read_error.code != .None {return {}, read_error}
			return {}, error_make(.Invalid_FAT, "file FAT chain is shorter than its size")
		}
		written += u64(count)
	}
	return result, {}
}

read_tail :: proc(
	volume: ^Volume,
	path: string,
	length: u64,
	allocator := context.allocator,
) -> (
	Read_Result,
	Error,
) {
	info, stat_error := stat(volume, path)
	if stat_error.code != .None {return {}, stat_error}
	if !info.exists {return {}, error_make(.Not_Found, "FAT path does not exist")}
	if info.is_directory {return {}, error_make(.Is_Directory, "FAT path is a directory")}
	offset := info.size > length ? info.size - length : 0
	return read_range(volume, path, offset, length, allocator)
}
