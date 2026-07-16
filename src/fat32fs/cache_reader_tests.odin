// SPDX-License-Identifier: GPL-3.0-only
package fat32fs

import disk "../disk"
import "core:testing"

CACHE_TEST_FAT_SECTORS :: 80
CACHE_TEST_FAT_ENTRIES :: CACHE_TEST_FAT_SECTORS * (SECTOR_BYTES / 4)

Cache_Test_Device :: struct {
	primary:             [CACHE_TEST_FAT_ENTRIES]u32,
	mirror:              [CACHE_TEST_FAT_ENTRIES]u32,
	sector_count:        u64,
	partition_lba:       u64,
	partition_sectors:   u32,
	sectors_per_cluster: u8,
	reserved_sectors:    u16,
	fat_count:           u8,
	sectors_per_fat:     u32,
	fat_lba:             u64,
	fsinfo_next:         u32,
	read_calls:          u64,
	write_calls:         u64,
	first_fat_read_lba:  u64,
	last_read_bytes:     int,
	fail_mirror_write:   bool,
	provide_boot:        bool,
}

@(private = "file")
cache_test_fat_value :: proc(device: ^Cache_Test_Device, copy_index: int, cluster: int) -> u32 {
	if cluster < 0 || cluster >= CACHE_TEST_FAT_ENTRIES {return FAT_EOC}
	return copy_index == 0 ? device.primary[cluster] : device.mirror[cluster]
}

@(private = "file")
cache_test_fill_sector :: proc(device: ^Cache_Test_Device, lba: u64, sector: []u8) {
	for &value in sector {value = 0}
	if device.provide_boot && lba == 0 {
		entry := sector[446:][:16]
		entry[4] = 0x0C
		put_u32le(entry, 8, u32(device.partition_lba))
		put_u32le(entry, 12, device.partition_sectors)
		sector[510] = 0x55
		sector[511] = 0xAA
		return
	}
	if lba == device.partition_lba {
		put_u16le(sector, 11, SECTOR_BYTES)
		sector[13] = device.sectors_per_cluster
		put_u16le(sector, 14, device.reserved_sectors)
		sector[16] = device.fat_count
		put_u32le(sector, 32, device.partition_sectors)
		put_u32le(sector, 36, device.sectors_per_fat)
		put_u32le(sector, 44, 2)
		put_u16le(sector, 48, 1)
		put_u16le(sector, 50, 6)
		sector[510] = 0x55
		sector[511] = 0xAA
		return
	}
	if lba == device.partition_lba + 1 || lba == device.partition_lba + 7 {
		put_u32le(sector, 0, 0x4161_5252)
		put_u32le(sector, 484, 0x6141_7272)
		put_u32le(sector, 488, 0xFFFF_FFFF)
		put_u32le(sector, 492, device.fsinfo_next)
		put_u32le(sector, 508, 0xAA55_0000)
		return
	}
	copy_index := -1
	sector_index: u64
	if lba >= device.fat_lba && lba < device.fat_lba + u64(device.sectors_per_fat) {
		copy_index = 0
		sector_index = lba - device.fat_lba
	} else if lba >= device.fat_lba + u64(device.sectors_per_fat) &&
	   lba < device.fat_lba + u64(device.sectors_per_fat) * 2 {
		copy_index = 1
		sector_index = lba - device.fat_lba - u64(device.sectors_per_fat)
	}
	if copy_index < 0 {return}
	base := int(sector_index) * (SECTOR_BYTES / 4)
	for entry_index in 0 ..< SECTOR_BYTES / 4 {
		put_u32le(
			sector,
			entry_index * 4,
			cache_test_fat_value(device, copy_index, base + entry_index),
		)
	}
}

@(private = "file")
cache_test_read :: proc(ctx: rawptr, lba: u64, data: []u8) -> bool {
	device := (^Cache_Test_Device)(ctx)
	if device == nil || len(data) == 0 || len(data) % SECTOR_BYTES != 0 {return false}
	count := u64(len(data) / SECTOR_BYTES)
	if lba >= device.sector_count || count > device.sector_count - lba {return false}
	device.read_calls += 1
	device.last_read_bytes = len(data)
	if lba >= device.fat_lba &&
	   lba < device.fat_lba + u64(device.sectors_per_fat) &&
	   device.first_fat_read_lba == 0 {
		device.first_fat_read_lba = lba
	}
	for index in 0 ..< int(count) {
		cache_test_fill_sector(
			device,
			lba + u64(index),
			data[index * SECTOR_BYTES:][:SECTOR_BYTES],
		)
	}
	return true
}

@(private = "file")
cache_test_write :: proc(ctx: rawptr, lba: u64, data: []u8) -> bool {
	device := (^Cache_Test_Device)(ctx)
	if device == nil || len(data) == 0 || len(data) % SECTOR_BYTES != 0 {return false}
	count := u64(len(data) / SECTOR_BYTES)
	if lba >= device.sector_count || count > device.sector_count - lba {return false}
	device.write_calls += 1
	for index in 0 ..< int(count) {
		sector_lba := lba + u64(index)
		copy_index := -1
		sector_index: u64
		if sector_lba >= device.fat_lba &&
		   sector_lba < device.fat_lba + u64(device.sectors_per_fat) {
			copy_index = 0
			sector_index = sector_lba - device.fat_lba
		} else if sector_lba >= device.fat_lba + u64(device.sectors_per_fat) &&
		   sector_lba < device.fat_lba + u64(device.sectors_per_fat) * 2 {
			if device.fail_mirror_write {return false}
			copy_index = 1
			sector_index = sector_lba - device.fat_lba - u64(device.sectors_per_fat)
		}
		if copy_index < 0 {continue}
		base := int(sector_index) * (SECTOR_BYTES / 4)
		sector := data[index * SECTOR_BYTES:][:SECTOR_BYTES]
		for entry_index in 0 ..< SECTOR_BYTES / 4 {
			cluster := base + entry_index
			if cluster >= CACHE_TEST_FAT_ENTRIES {break}
			if copy_index == 0 {
				device.primary[cluster] = get_u32le(sector, entry_index * 4)
			} else {
				device.mirror[cluster] = get_u32le(sector, entry_index * 4)
			}
		}
	}
	return true
}

@(private = "file")
cache_test_device_init :: proc(device: ^Cache_Test_Device) {
	device^ = {
		sector_count        = 1 << 20,
		partition_lba       = 1,
		partition_sectors   = (1 << 20) - 1,
		sectors_per_cluster = 1,
		reserved_sectors    = 32,
		fat_count           = 2,
		sectors_per_fat     = CACHE_TEST_FAT_SECTORS,
		fat_lba             = 100,
		fsinfo_next         = 2,
	}
	for &value in device.primary {value = FAT_EOC}
	for &value in device.mirror {value = FAT_EOC}
}

@(private = "file")
cache_test_volume :: proc(
	device: ^Cache_Test_Device,
	fat_sectors := u32(CACHE_TEST_FAT_SECTORS),
) -> Volume {
	device.sectors_per_fat = fat_sectors
	return {
		device = disk.Block_Device {
			ctx = device,
			sector_count = device.sector_count,
			read = cache_test_read,
			write = cache_test_write,
		},
		info = {
			partition_lba = device.partition_lba,
			partition_sectors = u64(device.partition_sectors),
			sectors_per_cluster = device.sectors_per_cluster,
			reserved_sectors = device.reserved_sectors,
			fat_count = device.fat_count,
			sectors_per_fat = fat_sectors,
			fat_lba = device.fat_lba,
			data_lba = 1000,
			root_cluster = 2,
			cluster_count = min(
				u32(CACHE_TEST_FAT_ENTRIES - 2),
				fat_sectors * (SECTOR_BYTES / 4) - 2,
			),
		},
		allocation_cursor = 2,
	}
}

@(test)
fat32fs_cache_test_is_fixed_lru_and_bounds_the_partial_final_page :: proc(t: ^testing.T) {
	device := new(Cache_Test_Device)
	defer free(device)
	cache_test_device_init(device)
	volume := cache_test_volume(device)
	for page in 0 ..< FAT_CACHE_SLOT_COUNT {
		cluster := u32(page * FAT_CACHE_PAGE_BYTES / 4 + 2)
		_, read_error := fat_entry(&volume, cluster)
		if !testing.expect_value(t, read_error.code, Error_Code.None) {return}
	}
	testing.expect_value(t, device.read_calls, u64(FAT_CACHE_SLOT_COUNT))
	_, first_hit_error := fat_entry(&volume, 2)
	testing.expect_value(t, first_hit_error.code, Error_Code.None)
	testing.expect_value(t, device.read_calls, u64(FAT_CACHE_SLOT_COUNT))
	_, ninth_error := fat_entry(&volume, u32(FAT_CACHE_SLOT_COUNT * FAT_CACHE_PAGE_BYTES / 4 + 2))
	testing.expect_value(t, ninth_error.code, Error_Code.None)
	_, evicted_error := fat_entry(&volume, u32(FAT_CACHE_PAGE_BYTES / 4 + 2))
	testing.expect_value(t, evicted_error.code, Error_Code.None)
	testing.expect_value(t, device.read_calls, u64(FAT_CACHE_SLOT_COUNT + 2))

	partial_device := new(Cache_Test_Device)
	defer free(partial_device)
	cache_test_device_init(partial_device)
	partial := cache_test_volume(partial_device, 10)
	_, partial_error := fat_entry(&partial, u32(9 * (SECTOR_BYTES / 4)))
	testing.expect_value(t, partial_error.code, Error_Code.None)
	testing.expect_value(t, partial_device.last_read_bytes, 2 * SECTOR_BYTES)
	testing.expect(t, size_of(Volume) < 40 * 1024)
}

@(test)
fat32fs_cache_test_mirror_update_never_serves_a_stale_entry :: proc(t: ^testing.T) {
	device := new(Cache_Test_Device)
	defer free(device)
	cache_test_device_init(device)
	volume := cache_test_volume(device)
	cluster := u32(1300)
	_, load_error := fat_entry(&volume, cluster)
	if !testing.expect_value(t, load_error.code, Error_Code.None) {return}
	reads_before := device.read_calls
	mutation_before := volume.mutation_epoch
	set_error := set_fat_entry(&volume, cluster, 0x12345)
	if !testing.expect_value(t, set_error.code, Error_Code.None) {return}
	testing.expect_value(t, volume.mutation_epoch, mutation_before + 1)
	testing.expect_value(t, device.primary[cluster] & 0x0FFF_FFFF, u32(0x12345))
	testing.expect_value(t, device.mirror[cluster] & 0x0FFF_FFFF, u32(0x12345))
	value, cached_error := fat_entry(&volume, cluster)
	testing.expect_value(t, cached_error.code, Error_Code.None)
	testing.expect_value(t, value, u32(0x12345))
	testing.expect_value(t, device.read_calls, reads_before + 2)

	failed_cluster := cluster + 1
	_, failed_load_error := fat_entry(&volume, failed_cluster)
	if !testing.expect_value(t, failed_load_error.code, Error_Code.None) {return}
	device.fail_mirror_write = true
	failed_reads_before := device.read_calls
	failed_epoch := volume.mutation_epoch
	failed_error := set_fat_entry(&volume, failed_cluster, 0x54321)
	testing.expect_value(t, failed_error.code, Error_Code.IO)
	testing.expect_value(t, volume.mutation_epoch, failed_epoch + 1)
	device.fail_mirror_write = false
	failed_value, reload_error := fat_entry(&volume, failed_cluster)
	testing.expect_value(t, reload_error.code, Error_Code.None)
	testing.expect_value(t, failed_value, u32(0x54321))
	testing.expect_value(t, device.read_calls, failed_reads_before + 3)
}

@(test)
fat32fs_allocation_test_uses_fsinfo_cursor_wrap_and_freed_low_watermark :: proc(t: ^testing.T) {
	device := new(Cache_Test_Device)
	defer free(device)
	cache_test_device_init(device)
	device.sectors_per_cluster = 32
	device.primary[5000] = 0
	device.mirror[5000] = 0
	device.primary[5001] = 0
	device.mirror[5001] = 0
	volume := cache_test_volume(device)
	volume.allocation_cursor = 5000
	first, first_error := allocate_cluster(&volume)
	if !testing.expect_value(t, first_error.code, Error_Code.None) {return}
	testing.expect_value(t, first, u32(5000))
	testing.expect_value(t, volume.allocation_cursor, u32(5001))
	testing.expect_value(t, device.write_calls, u64(8))
	testing.expect_value(
		t,
		device.first_fat_read_lba,
		device.fat_lba +
		u64(5000 * 4 / SECTOR_BYTES / FAT_CACHE_PAGE_SECTORS * FAT_CACHE_PAGE_SECTORS),
	)
	second, second_error := allocate_cluster(&volume)
	if !testing.expect_value(t, second_error.code, Error_Code.None) {return}
	testing.expect_value(t, second, u32(5001))
	free_error := free_chain(&volume, first)
	if !testing.expect_value(t, free_error.code, Error_Code.None) {return}
	testing.expect_value(t, volume.allocation_cursor, first)
	reused, reused_error := allocate_cluster(&volume)
	testing.expect_value(t, reused_error.code, Error_Code.None)
	testing.expect_value(t, reused, first)
}

@(test)
fat32fs_open_test_uses_valid_fsinfo_next_free_without_trusting_image_size :: proc(t: ^testing.T) {
	device := new(Cache_Test_Device)
	defer free(device)
	cache_test_device_init(device)
	device.provide_boot = true
	device.partition_lba = 63
	device.partition_sectors = 1 << 20
	device.sector_count = device.partition_lba + u64(device.partition_sectors)
	device.sectors_per_cluster = 8
	device.sectors_per_fat = 1024
	device.fat_lba = device.partition_lba + u64(device.reserved_sectors)
	device.fsinfo_next = 5000
	volume, open_error := open(
		disk.Block_Device {
			ctx = device,
			sector_count = device.sector_count,
			read = cache_test_read,
			write = cache_test_write,
		},
	)
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
	testing.expect_value(t, volume.allocation_cursor, u32(5000))
}

READER_TEST_FILE_BYTES :: u64(40 * 1024 * 1024)
READER_TEST_CLUSTER_SECTORS :: u8(8)
READER_TEST_FIRST_CLUSTER :: u32(3)

Reader_Test_Device :: struct {
	sector_count:        u64,
	fat_lba:             u64,
	sectors_per_fat:     u32,
	data_lba:            u64,
	read_calls:          u64,
	fat_read_calls:      u64,
	data_read_calls:     u64,
	max_data_read_bytes: int,
}

@(private = "file")
reader_test_read :: proc(ctx: rawptr, lba: u64, data: []u8) -> bool {
	device := (^Reader_Test_Device)(ctx)
	if device == nil || len(data) == 0 || len(data) % SECTOR_BYTES != 0 {return false}
	count := u64(len(data) / SECTOR_BYTES)
	if lba >= device.sector_count || count > device.sector_count - lba {return false}
	device.read_calls += 1
	for &value in data {value = 0}
	if lba >= device.fat_lba && lba + count <= device.fat_lba + u64(device.sectors_per_fat) {
		device.fat_read_calls += 1
		first_entry := (lba - device.fat_lba) * (SECTOR_BYTES / 4)
		file_clusters := u32(
			READER_TEST_FILE_BYTES / (u64(READER_TEST_CLUSTER_SECTORS) * SECTOR_BYTES),
		)
		last_cluster := READER_TEST_FIRST_CLUSTER + file_clusters - 1
		for entry_index in 0 ..< len(data) / 4 {
			cluster := u32(first_entry) + u32(entry_index)
			value := FAT_EOC
			if cluster >= READER_TEST_FIRST_CLUSTER && cluster < last_cluster {value = cluster + 1}
			put_u32le(data, entry_index * 4, value)
		}
		return true
	}
	device.data_read_calls += 1
	device.max_data_read_bytes = max(device.max_data_read_bytes, len(data))
	root_lba := device.data_lba
	if lba == root_lba {
		copy(data[:11], "LARGE   BIN")
		data[11] = ATTR_ARCHIVE
		put_u16le(data, 20, u16(READER_TEST_FIRST_CLUSTER >> 16))
		put_u16le(data, 26, u16(READER_TEST_FIRST_CLUSTER))
		put_u32le(data, 28, u32(READER_TEST_FILE_BYTES))
		return true
	}
	for &value, index in data {value = u8((lba + u64(index)) & 0xFF)}
	return true
}

@(private = "file")
reader_test_volume :: proc(device: ^Reader_Test_Device) -> Volume {
	device^ = {
		sector_count    = 40 * 1024 * 1024,
		fat_lba         = 100,
		sectors_per_fat = 16 * 1024,
		data_lba        = 100000,
	}
	return {
		device = disk.Block_Device {
			ctx = device,
			sector_count = device.sector_count,
			read = reader_test_read,
		},
		info = {
			sectors_per_cluster = READER_TEST_CLUSTER_SECTORS,
			fat_count = 2,
			sectors_per_fat = device.sectors_per_fat,
			fat_lba = device.fat_lba,
			data_lba = device.data_lba,
			root_cluster = 2,
			cluster_count = 1 << 20,
		},
	}
}

@(test)
fat32fs_file_reader_test_streams_a_declared_large_file_with_bounded_linear_io :: proc(
	t: ^testing.T,
) {
	device := new(Reader_Test_Device)
	defer free(device)
	volume := reader_test_volume(device)
	reader, begin_error := file_reader_begin(&volume, "LARGE.BIN")
	if !testing.expect_value(t, begin_error.code, Error_Code.None) {return}
	defer file_reader_close(&reader)
	buffer := make([]u8, MAX_FILE_TRANSFER_BYTES)
	defer delete(buffer)
	steps := 0
	for reader.offset < reader.total {
		count, read_error := file_reader_read(&reader, buffer)
		if !testing.expect_value(t, read_error.code, Error_Code.None) {return}
		if !testing.expect(t, count > 0 && count <= MAX_FILE_TRANSFER_BYTES) {return}
		steps += 1
	}
	testing.expect_value(t, reader.total, READER_TEST_FILE_BYTES)
	testing.expect_value(t, reader.offset, READER_TEST_FILE_BYTES)
	testing.expect_value(t, steps, int(READER_TEST_FILE_BYTES / MAX_FILE_TRANSFER_BYTES))
	testing.expect_value(t, device.fat_read_calls, u64(11))
	testing.expect_value(
		t,
		device.max_data_read_bytes,
		int(READER_TEST_CLUSTER_SECTORS) * SECTOR_BYTES,
	)
	testing.expect(t, device.sector_count * SECTOR_BYTES > READER_TEST_FILE_BYTES * 400)

	conflict_reader, conflict_error := file_reader_begin(&volume, "LARGE.BIN")
	if !testing.expect_value(t, conflict_error.code, Error_Code.None) {return}
	defer file_reader_close(&conflict_reader)
	count, first_error := file_reader_read(&conflict_reader, buffer[:SECTOR_BYTES])
	if !testing.expect_value(t, first_error.code, Error_Code.None) ||
	   !testing.expect_value(t, count, SECTOR_BYTES) {return}
	fat_mutation_committed(&volume)
	_, changed_error := file_reader_read(&conflict_reader, buffer[:SECTOR_BYTES])
	testing.expect_value(t, changed_error.code, Error_Code.Mutation_Conflict)
}
