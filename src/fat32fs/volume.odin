// SPDX-License-Identifier: GPL-3.0-only
package fat32fs

import disk "../disk"

@(private = "package")
fat_cache_touch :: proc(volume: ^Volume, slot: ^Fat_Cache_Slot) {
	volume.fat_cache_clock += 1
	if volume.fat_cache_clock == 0 {
		volume.fat_cache_clock = 1
		for &candidate in volume.fat_cache {
			if candidate.valid {candidate.last_use = 1}
		}
	}
	slot.last_use = volume.fat_cache_clock
}

@(private = "package")
fat_cache_find :: proc(volume: ^Volume, page: u64) -> ^Fat_Cache_Slot {
	if volume == nil {return nil}
	for &slot in volume.fat_cache {
		if slot.valid && slot.page == page {
			fat_cache_touch(volume, &slot)
			return &slot
		}
	}
	return nil
}

@(private = "package")
fat_cache_load :: proc(volume: ^Volume, sector_index: u64) -> (^Fat_Cache_Slot, Error) {
	if volume == nil || sector_index >= u64(volume.info.sectors_per_fat) {
		return nil, error_make(.Invalid_FAT, "FAT sector is outside the volume")
	}
	page := sector_index / FAT_CACHE_PAGE_SECTORS
	if cached := fat_cache_find(volume, page); cached != nil {return cached, {}}
	victim := &volume.fat_cache[0]
	for &slot in volume.fat_cache {
		if !slot.valid {
			victim = &slot
			break
		}
		if slot.last_use < victim.last_use {victim = &slot}
	}
	first_sector := page * FAT_CACHE_PAGE_SECTORS
	sector_count := min(
		u64(FAT_CACHE_PAGE_SECTORS),
		u64(volume.info.sectors_per_fat) - first_sector,
	)
	used := int(sector_count * SECTOR_BYTES)
	victim.valid = false
	if !volume.device.read(
		volume.device.ctx,
		volume.info.fat_lba + first_sector,
		victim.data[:used],
	) {
		return nil, error_make(.IO, "cannot read a FAT cache page")
	}
	victim.page = page
	victim.used = used
	victim.valid = true
	fat_cache_touch(volume, victim)
	return victim, {}
}

@(private = "package")
fat_cache_invalidate :: proc(volume: ^Volume, sector_index: u64) -> int {
	if volume == nil {return -1}
	page := sector_index / FAT_CACHE_PAGE_SECTORS
	for &slot, index in volume.fat_cache {
		if slot.valid && slot.page == page {
			slot.valid = false
			return index
		}
	}
	return -1
}

@(private = "package")
fat_cache_revalidate_entry :: proc(
	volume: ^Volume,
	slot_index: int,
	sector_index: u64,
	within_sector: int,
	value: u32,
) {
	if volume == nil || slot_index < 0 || slot_index >= FAT_CACHE_SLOT_COUNT {return}
	slot := &volume.fat_cache[slot_index]
	page := sector_index / FAT_CACHE_PAGE_SECTORS
	page_offset := int((sector_index % FAT_CACHE_PAGE_SECTORS) * SECTOR_BYTES) + within_sector
	if slot.page != page || page_offset < 0 || page_offset + 4 > slot.used {return}
	put_u32le(slot.data[:], page_offset, value)
	slot.valid = true
	fat_cache_touch(volume, slot)
}

@(private = "package")
fat_mutation_committed :: proc(volume: ^Volume) {
	if volume == nil {return}
	volume.mutation_epoch += 1
	if volume.mutation_epoch == 0 {volume.mutation_epoch = 1}
}

open :: proc(device: disk.Block_Device) -> (Volume, Error) {
	if device.ctx == nil || device.read == nil || device.sector_count == 0 {
		return {}, error_make(.Invalid_Argument, "FAT32 block device is unavailable")
	}
	mbr: [SECTOR_BYTES]u8
	if !device.read(device.ctx, 0, mbr[:]) {
		return {}, error_make(.IO, "cannot read the image MBR")
	}
	if mbr[510] != 0x55 || mbr[511] != 0xAA {
		return {}, error_make(.Invalid_MBR, "image MBR signature is invalid")
	}
	partition: []u8
	for index in 0 ..< 4 {
		entry := mbr[446 + index * 16:][:16]
		if entry[4] == 0x0B || entry[4] == 0x0C {
			if partition != nil {
				return {}, error_make(.Invalid_MBR, "image has more than one FAT32 partition")
			}
			partition = entry
		}
	}
	if partition == nil {return {}, error_make(.Invalid_MBR, "image has no FAT32 partition")}
	partition_lba := u64(get_u32le(partition, 8))
	partition_sectors := u64(get_u32le(partition, 12))
	if partition_lba == 0 ||
	   partition_sectors == 0 ||
	   partition_lba >= device.sector_count ||
	   partition_sectors > device.sector_count - partition_lba {
		return {}, error_make(.Invalid_MBR, "FAT32 partition is outside the image")
	}
	vbr: [SECTOR_BYTES]u8
	if !device.read(device.ctx, partition_lba, vbr[:]) {
		return {}, error_make(.IO, "cannot read the FAT32 boot sector")
	}
	if vbr[510] != 0x55 || vbr[511] != 0xAA || get_u16le(vbr[:], 11) != SECTOR_BYTES {
		return {}, error_make(.Invalid_VBR, "FAT32 boot sector is invalid")
	}
	sectors_per_cluster := vbr[13]
	if sectors_per_cluster == 0 ||
	   sectors_per_cluster & (sectors_per_cluster - 1) != 0 ||
	   sectors_per_cluster > 128 {
		return {}, error_make(.Invalid_VBR, "FAT32 cluster size is invalid")
	}
	reserved := get_u16le(vbr[:], 14)
	fat_count := vbr[16]
	sectors_per_fat := get_u32le(vbr[:], 36)
	root_cluster := get_u32le(vbr[:], 44)
	total_sectors := u64(get_u32le(vbr[:], 32))
	if total_sectors == 0 {total_sectors = u64(get_u16le(vbr[:], 19))}
	if reserved < 2 ||
	   fat_count == 0 ||
	   sectors_per_fat == 0 ||
	   root_cluster < 2 ||
	   total_sectors == 0 ||
	   total_sectors > partition_sectors {
		return {}, error_make(.Invalid_VBR, "FAT32 geometry is inconsistent")
	}
	metadata := u64(reserved) + u64(fat_count) * u64(sectors_per_fat)
	if metadata >= total_sectors {
		return {}, error_make(.Invalid_VBR, "FAT32 data region is empty")
	}
	cluster_count64 := (total_sectors - metadata) / u64(sectors_per_cluster)
	if cluster_count64 < 65525 ||
	   cluster_count64 > u64(max(u32)) - 2 ||
	   u64(root_cluster) >= cluster_count64 + 2 {
		return {}, error_make(.Invalid_FAT, "partition does not contain a valid FAT32 cluster range")
	}
	info := Volume_Info {
		partition_lba       = partition_lba,
		partition_sectors   = total_sectors,
		sectors_per_cluster = sectors_per_cluster,
		reserved_sectors    = reserved,
		fat_count           = fat_count,
		sectors_per_fat     = sectors_per_fat,
		fat_lba             = partition_lba + u64(reserved),
		data_lba            = partition_lba + metadata,
		root_cluster        = root_cluster,
		cluster_count       = u32(cluster_count64),
	}
	allocation_cursor := u32(2)
	fsinfo_sector := u64(get_u16le(vbr[:], 48))
	if fsinfo_sector > 0 && fsinfo_sector < u64(reserved) {
		fsinfo: [SECTOR_BYTES]u8
		if device.read(device.ctx, partition_lba + fsinfo_sector, fsinfo[:]) &&
		   get_u32le(fsinfo[:], 0) == 0x4161_5252 &&
		   get_u32le(fsinfo[:], 484) == 0x6141_7272 &&
		   get_u32le(fsinfo[:], 508) == 0xAA55_0000 {
			next_free := get_u32le(fsinfo[:], 492)
			if next_free >= 2 && next_free < info.cluster_count + 2 {
				allocation_cursor = next_free
			}
		}
	}
	volume := Volume {
		device            = device,
		info              = info,
		allocation_cursor = allocation_cursor,
	}
	root_next, fat_error := fat_entry(&volume, root_cluster)
	if fat_error.code != .None {return {}, fat_error}
	if root_next == 0 || root_next == 0x0FFF_FFF7 {
		return {}, error_make(.Invalid_FAT, "FAT32 root directory chain is invalid")
	}
	return volume, {}
}

@(private = "package")
fat_entry :: proc(volume: ^Volume, cluster: u32) -> (u32, Error) {
	if volume == nil || cluster >= volume.info.cluster_count + 2 {
		return 0, error_make(.Invalid_FAT, "FAT cluster is outside the volume")
	}
	byte_offset := u64(cluster) * 4
	sector_index := byte_offset / SECTOR_BYTES
	sector_offset := int(byte_offset % SECTOR_BYTES)
	slot, cache_error := fat_cache_load(volume, sector_index)
	if cache_error.code != .None {return 0, cache_error}
	page_offset := int((sector_index % FAT_CACHE_PAGE_SECTORS) * SECTOR_BYTES) + sector_offset
	if page_offset + 4 > slot.used {
		return 0, error_make(.Invalid_FAT, "FAT entry crosses the valid cache page")
	}
	return get_u32le(slot.data[:], page_offset) & 0x0FFF_FFFF, {}
}

@(private = "package")
cluster_lba :: proc(volume: ^Volume, cluster: u32) -> (u64, Error) {
	if volume == nil || cluster < 2 || cluster >= volume.info.cluster_count + 2 {
		return 0, error_make(.Invalid_FAT, "cluster is outside the FAT32 data region")
	}
	return volume.info.data_lba + u64(cluster - 2) * u64(volume.info.sectors_per_cluster), {}
}

@(private = "package")
chain_next :: proc(volume: ^Volume, cluster: u32) -> (next: u32, end: bool, err: Error) {
	value, read_error := fat_entry(volume, cluster)
	if read_error.code != .None {return 0, false, read_error}
	if value >= 0x0FFF_FFF8 {return 0, true, {}}
	if value < 2 || value == 0x0FFF_FFF7 || value >= volume.info.cluster_count + 2 {
		return 0, false, error_make(.Invalid_FAT, "file has an invalid FAT chain")
	}
	return value, false, {}
}
