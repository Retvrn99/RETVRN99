// SPDX-License-Identifier: GPL-3.0-only
package fat32image

import "core:os"
import "core:path/filepath"
import "core:testing"

fat32image_test_directory :: proc(t: ^testing.T) -> (string, bool) {
	directory, err := os.make_directory_temp("", "retvrn99-fat32image-*", context.temp_allocator)
	return directory, testing.expect_value(t, err, os.Error(nil))
}

fat32image_test_create :: proc(
	t: ^testing.T,
	directory, name: string,
) -> (
	string,
	Image_Info,
	bool,
) {
	path, path_error := filepath.join({directory, name}, context.temp_allocator)
	if !testing.expect(t, path_error == nil) {return "", {}, false}
	info, create_error := create({path = path, capacity_gib = 1})
	if !testing.expect_value(t, create_error.code, Error_Code.None) {return path, info, false}
	return path, info, true
}

@(test)
fat32image_test_create_validate_sparse_and_block_io :: proc(t: ^testing.T) {
	directory, directory_ok := fat32image_test_directory(t)
	if !directory_ok {return}
	defer os.remove_all(directory)
	path, created, create_ok := fat32image_test_create(t, directory, "drive.img")
	if !create_ok {return}
	defer info_destroy(&created)
	testing.expect_value(t, created.sector_count, u64(1) << 21)
	testing.expect_value(t, created.partition_lba, u32(63))
	testing.expect_value(t, created.partition_sectors, u32((u64(1) << 21) - 63))
	testing.expect_value(t, created.sectors_per_cluster, u8(8))
	testing.expect_value(t, created.marker_sector, u32(94))
	testing.expect(t, created.enrolled)
	testing.expect(t, created.retvrn99_format)
	testing.expect(t, !created.dirty)
	testing.expect(t, created.sparse)
	file, file_error := os.open(path, {.Read})
	if !testing.expect_value(t, file_error, os.Error(nil)) {return}
	logical_size, size_error := os.file_size(file)
	allocated, allocated_ok := platform_image_allocated_bytes(file)
	_ = os.close(file)
	testing.expect_value(t, size_error, os.Error(nil))
	testing.expect_value(t, logical_size, i64(1) << 30)
	testing.expect(t, allocated_ok)
	testing.expect(t, allocated < u64(logical_size) / 100)
	image, open_error := open(path, .Read_Write)
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
	testing.expect(t, backing_identity_matches(image))
	testing.expect(t, !image.info.dirty)
	second, second_error := open(path, .Read_Write)
	testing.expect_value(t, second_error.code, Error_Code.Locked)
	if second != nil {_ = close(second, .Retain)}
	vbr: [SECTOR_BYTES]u8
	testing.expect_value(
		t,
		block_read(image, u64(image.info.partition_lba), vbr[:]).code,
		Error_Code.None,
	)
	testing.expect_value(t, get_u16le(vbr[:], 11), u16(SECTOR_BYTES))
	testing.expect_value(t, vbr[13], u8(8))
	compatible_vbr := vbr
	compatible_vbr[0] = compatible_vbr[0] ~ 0x5A
	compatible_vbr[100] = compatible_vbr[100] ~ 0xA5
	ignored, compatible_error := validate_write(
		image,
		u64(image.info.partition_lba),
		compatible_vbr[:],
	)
	testing.expect(t, ignored)
	testing.expect_value(t, compatible_error.code, Error_Code.None)
	incompatible_vbr := compatible_vbr
	incompatible_vbr[13] = incompatible_vbr[13] == 1 ? 2 : 1
	incompatible_ignored, incompatible_error := validate_write(
		image,
		u64(image.info.partition_lba),
		incompatible_vbr[:],
	)
	testing.expect(t, !incompatible_ignored)
	testing.expect_value(t, incompatible_error.code, Error_Code.Protected_Write)
	spf := get_u32le(vbr[:], 36)
	data_lba := u64(image.info.partition_lba) + u64(image.info.reserved_sectors) + 2 * u64(spf)
	payload: [SECTOR_BYTES]u8
	for index in 0 ..< len(payload) {payload[index] = u8(index)}
	testing.expect_value(t, block_write(image, 0, payload[:]).code, Error_Code.Protected_Write)
	testing.expect_value(
		t,
		block_write(image, u64(image.info.partition_lba) + u64(image.info.reserved_sectors) - 1, payload[:]).code,
		Error_Code.Protected_Write,
	)
	testing.expect_value(t, block_write(image, data_lba, payload[:]).code, Error_Code.None)
	first_fat_lba := u64(image.info.partition_lba) + u64(image.info.reserved_sectors)
	zero_fat: [SECTOR_BYTES]u8
	testing.expect_value(
		t,
		block_write(image, first_fat_lba, zero_fat[:]).code,
		Error_Code.Protected_Write,
	)
	last_lba := image.info.sector_count - 1
	testing.expect_value(t, block_write(image, last_lba, payload[:]).code, Error_Code.None)
	readback: [SECTOR_BYTES]u8
	testing.expect_value(t, block_read(image, data_lba, readback[:]).code, Error_Code.None)
	testing.expect_value(t, string(readback[:]), string(payload[:]))
	testing.expect_value(
		t,
		block_read(image, image.info.sector_count, readback[:]).code,
		Error_Code.Out_Of_Range,
	)
	misaligned: [SECTOR_BYTES + 1]u8
	testing.expect_value(t, block_read(image, 1, misaligned[:]).code, Error_Code.Invalid_Argument)
	device := block_device(image)
	testing.expect_value(t, device.sector_count, image.info.sector_count)
	testing.expect(t, device.flush(device.ctx))
	if !testing.expect_value(t, close(image, .Clean).code, Error_Code.None) {return}
	validated, validation_error := validate(path)
	if !testing.expect_value(t, validation_error.code, Error_Code.None) {return}
	defer info_destroy(&validated)
	testing.expect(t, validated.enrolled)
	testing.expect(t, !validated.dirty)
}

@(test)
fat32image_test_retain_preserves_dirty_marker_and_clean_close_clears_it :: proc(t: ^testing.T) {
	directory, directory_ok := fat32image_test_directory(t)
	if !directory_ok {return}
	defer os.remove_all(directory)
	path, created, create_ok := fat32image_test_create(t, directory, "dirty.img")
	if !create_ok {return}
	defer info_destroy(&created)
	image, open_error := open(path, .Read_Write)
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
	testing.expect_value(t, close(image, .Retain).code, Error_Code.None)
	dirty_info, dirty_error := validate(path)
	if !testing.expect_value(t, dirty_error.code, Error_Code.None) {return}
	testing.expect(t, dirty_info.dirty)
	info_destroy(&dirty_info)
	recovered, recovered_error := open(path, .Read_Write)
	if !testing.expect_value(t, recovered_error.code, Error_Code.None) {return}
	testing.expect(t, recovered.info.dirty)
	testing.expect_value(t, close(recovered, .Clean).code, Error_Code.None)
	clean_info, clean_error := validate(path)
	if !testing.expect_value(t, clean_error.code, Error_Code.None) {return}
	defer info_destroy(&clean_info)
	testing.expect(t, !clean_info.dirty)
	read_only, read_only_error := open(path, .Read_Only)
	if !testing.expect_value(t, read_only_error.code, Error_Code.None) {return}
	payload: [SECTOR_BYTES]u8
	testing.expect_value(
		t,
		block_write(read_only, u64(read_only.info.partition_lba) + u64(read_only.info.reserved_sectors), payload[:]).code,
		Error_Code.Read_Only,
	)
	testing.expect_value(t, close(read_only, .Clean).code, Error_Code.None)
}

@(test)
fat32image_test_compatible_unmarked_image_is_enrolled_on_writable_open :: proc(t: ^testing.T) {
	directory, directory_ok := fat32image_test_directory(t)
	if !directory_ok {return}
	defer os.remove_all(directory)
	path, created, create_ok := fat32image_test_create(t, directory, "enroll.img")
	if !create_ok {return}
	marker_sector := created.marker_sector
	defer info_destroy(&created)
	file, file_error := os.open(path, {.Read, .Write})
	if !testing.expect_value(t, file_error, os.Error(nil)) {return}
	zero: [SECTOR_BYTES]u8
	offset, _ := sector_offset(u64(marker_sector))
	testing.expect(t, write_exact_at(file, zero[:], offset))
	testing.expect_value(t, os.sync(file), os.Error(nil))
	_ = os.close(file)
	unmarked, validation_error := validate(path)
	if !testing.expect_value(t, validation_error.code, Error_Code.None) {return}
	testing.expect(t, !unmarked.enrolled)
	testing.expect_value(t, unmarked.marker_sector, marker_sector)
	info_destroy(&unmarked)
	image, open_error := open(path, .Read_Write)
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
	testing.expect(t, image.info.enrolled)
	testing.expect_value(t, image.info.marker_sector, marker_sector)
	testing.expect_value(t, patch_boot_loader(image, 1, 2).code, Error_Code.Boot_Code_Unsupported)
	testing.expect_value(t, close(image, .Clean).code, Error_Code.None)
	enrolled, enrolled_error := validate(path)
	if !testing.expect_value(t, enrolled_error.code, Error_Code.None) {return}
	defer info_destroy(&enrolled)
	testing.expect(t, enrolled.enrolled)
	nonzero := false
	for octet in enrolled.image_id {nonzero = nonzero || octet != 0}
	testing.expect(t, nonzero)
}

@(test)
fat32image_test_owner_boot_patch_updates_both_vbrs_and_survives_validation :: proc(t: ^testing.T) {
	directory, directory_ok := fat32image_test_directory(t)
	if !directory_ok {return}
	defer os.remove_all(directory)
	path, created, create_ok := fat32image_test_create(t, directory, "boot.img")
	if !create_ok {return}
	defer info_destroy(&created)
	image, open_error := open(path, .Read_Write)
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
	primary: [SECTOR_BYTES]u8
	testing.expect_value(
		t,
		block_read(image, u64(image.info.partition_lba), primary[:]).code,
		Error_Code.None,
	)
	spf := u64(get_u32le(primary[:], 36))
	data_lba :=
		u64(image.info.partition_lba) + u64(image.info.reserved_sectors) + u64(primary[16]) * spf
	io_cluster := u32(3)
	io_lba := data_lba + u64(primary[13])
	testing.expect_value(
		t,
		patch_boot_loader(image, io_lba + 1, io_cluster).code,
		Error_Code.Invalid_Boot_Target,
	)
	testing.expect_value(t, patch_boot_loader(image, io_lba, io_cluster).code, Error_Code.None)
	testing.expect_value(
		t,
		block_write(image, u64(image.info.partition_lba), primary[:]).code,
		Error_Code.Protected_Write,
	)
	backup: [SECTOR_BYTES]u8
	backup_lba := u64(image.info.partition_lba) + u64(get_u16le(primary[:], 50))
	testing.expect_value(
		t,
		block_read(image, u64(image.info.partition_lba), primary[:]).code,
		Error_Code.None,
	)
	testing.expect_value(t, block_read(image, backup_lba, backup[:]).code, Error_Code.None)
	testing.expect_value(t, get_u32le(primary[:], VBR_DATA_LBA_OFFSET), u32(data_lba))
	testing.expect_value(t, get_u32le(primary[:], VBR_CLUSTER_OFFSET), io_cluster)
	testing.expect_value(t, get_u64le(primary[:], VBR_IO_SYS_LBA_OFFSET), io_lba)
	testing.expect_value(t, string(primary[:]), string(backup[:]))
	testing.expect_value(t, close(image, .Clean).code, Error_Code.None)
	validated, validation_error := validate(path)
	if !testing.expect_value(t, validation_error.code, Error_Code.None) {return}
	defer info_destroy(&validated)
	testing.expect(t, validated.retvrn99_format)
	testing.expect(t, !validated.dirty)
}

@(test)
fat32image_test_editor_accepts_coalesced_vbr_and_valid_fsinfo_run :: proc(t: ^testing.T) {
	directory, directory_ok := fat32image_test_directory(t)
	if !directory_ok {return}
	defer os.remove_all(directory)
	path, created, create_ok := fat32image_test_create(t, directory, "coalesced-vbr.img")
	if !create_ok {return}
	defer info_destroy(&created)
	image, open_error := open(path, .Read_Write)
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
	primary_lba := u64(image.info.partition_lba)
	stub: [SECTOR_BYTES]u8
	testing.expect_value(t, block_read(image, primary_lba, stub[:]).code, Error_Code.None)
	data_lba :=
		primary_lba +
		u64(image.info.reserved_sectors) +
		u64(stub[16]) * u64(get_u32le(stub[:], 36))
	io_cluster := u32(3)
	io_lba := data_lba + u64(stub[13])
	patch_lba, backup_lba, patch, backup_patch, patch_error :=
		prepare_boot_loader_patch(image, io_lba, io_cluster)
	if !testing.expect_value(t, patch_error.code, Error_Code.None) {return}
	fsinfo: [SECTOR_BYTES]u8
	testing.expect_value(t, block_read(image, patch_lba + 1, fsinfo[:]).code, Error_Code.None)
	run: [2 * SECTOR_BYTES]u8
	copy(run[:SECTOR_BYTES], patch[:])
	copy(run[SECTOR_BYTES:], fsinfo[:])
	testing.expect_value(t, edit_block_write(image, patch_lba, run[:]).code, Error_Code.None)
	testing.expect_value(
		t,
		edit_block_write(image, backup_lba, backup_patch[:]).code,
		Error_Code.None,
	)
	readback: [SECTOR_BYTES]u8
	testing.expect_value(t, block_read(image, patch_lba, readback[:]).code, Error_Code.None)
	testing.expect_value(t, readback, patch)
	testing.expect_value(t, close(image, .Clean).code, Error_Code.None)
}

@(test)
fat32image_test_invalid_marker_and_truncated_image_fail_closed :: proc(t: ^testing.T) {
	directory, directory_ok := fat32image_test_directory(t)
	if !directory_ok {return}
	defer os.remove_all(directory)
	marker_path, marker_info, marker_ok := fat32image_test_create(t, directory, "marker.img")
	if !marker_ok {return}
	marker_lba := marker_info.marker_sector
	defer info_destroy(&marker_info)
	file, file_error := os.open(marker_path, {.Read, .Write})
	if !testing.expect_value(t, file_error, os.Error(nil)) {return}
	marker: [SECTOR_BYTES]u8
	offset, _ := sector_offset(u64(marker_lba))
	testing.expect(t, read_exact_at(file, marker[:], offset))
	marker[80] = marker[80] ~ 1
	testing.expect(t, write_exact_at(file, marker[:], offset))
	testing.expect_value(t, os.sync(file), os.Error(nil))
	_ = os.close(file)
	_, marker_error := validate(marker_path)
	testing.expect_value(t, marker_error.code, Error_Code.Marker_Invalid)
	truncated_path, truncated_info, truncated_ok := fat32image_test_create(
		t,
		directory,
		"truncated.img",
	)
	if !truncated_ok {return}
	defer info_destroy(&truncated_info)
	truncated, truncated_open_error := os.open(truncated_path, {.Read, .Write})
	if !testing.expect_value(t, truncated_open_error, os.Error(nil)) {return}
	size, _ := os.file_size(truncated)
	testing.expect_value(t, os.truncate(truncated, size - SECTOR_BYTES), os.Error(nil))
	_ = os.close(truncated)
	_, truncated_error := validate(truncated_path)
	testing.expect(t, truncated_error.code != .None)
}

@(test)
fat32image_test_create_never_overwrites_existing_image :: proc(t: ^testing.T) {
	directory, directory_ok := fat32image_test_directory(t)
	if !directory_ok {return}
	defer os.remove_all(directory)
	path, created, create_ok := fat32image_test_create(t, directory, "한국어.img")
	if !create_ok {return}
	defer info_destroy(&created)
	file, file_error := os.open(path, {.Read})
	if !testing.expect_value(t, file_error, os.Error(nil)) {return}
	before: [SECTOR_BYTES]u8
	testing.expect(t, read_exact_at(file, before[:], 0))
	_ = os.close(file)
	_, duplicate_error := create({path = path, capacity_gib = 1, allow_full_allocation = true})
	testing.expect_value(t, duplicate_error.code, Error_Code.Already_Exists)
	file, file_error = os.open(path, {.Read})
	if !testing.expect_value(t, file_error, os.Error(nil)) {return}
	after: [SECTOR_BYTES]u8
	testing.expect(t, read_exact_at(file, after[:], 0))
	_ = os.close(file)
	testing.expect_value(t, string(after[:]), string(before[:]))
}

@(test)
fat32image_test_fat_mirror_corruption_and_missing_path_fail_closed :: proc(t: ^testing.T) {
	directory, directory_ok := fat32image_test_directory(t)
	if !directory_ok {return}
	defer os.remove_all(directory)
	missing, _ := filepath.join({directory, "missing.img"}, context.temp_allocator)
	_, missing_error := validate(missing)
	testing.expect_value(t, missing_error.code, Error_Code.Not_Found)
	path, created, create_ok := fat32image_test_create(t, directory, "fat-corrupt.img")
	if !create_ok {return}
	defer info_destroy(&created)
	file, file_error := os.open(path, {.Read, .Write})
	if !testing.expect_value(t, file_error, os.Error(nil)) {return}
	vbr: [SECTOR_BYTES]u8
	vbr_offset, _ := sector_offset(u64(created.partition_lba))
	testing.expect(t, read_exact_at(file, vbr[:], vbr_offset))
	second_fat_lba :=
		u64(created.partition_lba) + u64(created.reserved_sectors) + u64(get_u32le(vbr[:], 36))
	fat: [SECTOR_BYTES]u8
	fat_offset, _ := sector_offset(second_fat_lba + 1)
	testing.expect(t, read_exact_at(file, fat[:], fat_offset))
	fat[100] = fat[100] ~ 1
	testing.expect(t, write_exact_at(file, fat[:], fat_offset))
	testing.expect_value(t, os.sync(file), os.Error(nil))
	_ = os.close(file)
	_, corrupt_error := validate(path)
	testing.expect_value(t, corrupt_error.code, Error_Code.Invalid_FAT32)
}

@(test)
fat32image_test_guest_and_editor_fsinfo_updates_preserve_reserved_layout :: proc(t: ^testing.T) {
	directory, directory_ok := fat32image_test_directory(t)
	if !directory_ok {return}
	defer os.remove_all(directory)
	path, created, create_ok := fat32image_test_create(t, directory, "fsinfo.img")
	if !create_ok {return}
	defer info_destroy(&created)
	image, open_error := open(path, .Read_Write)
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
	partition := u64(image.info.partition_lba)
	primary_lba := partition + u64(image.geometry.fsinfo_sector)
	backup_lba :=
		partition + u64(image.geometry.backup_vbr_sector) + u64(image.geometry.fsinfo_sector)
	primary, backup: [SECTOR_BYTES]u8
	testing.expect_value(t, block_read(image, primary_lba, primary[:]).code, Error_Code.None)
	testing.expect_value(t, block_read(image, backup_lba, backup[:]).code, Error_Code.None)
	put_u32le(primary[:], 488, 0xFFFF_FFFF)
	put_u32le(primary[:], 492, 0xFFFF_FFFF)
	testing.expect_value(t, block_write(image, primary_lba, primary[:]).code, Error_Code.None)
	testing.expect_value(t, check_filesystem(image).code, Error_Code.Invalid_FAT32)
	invalid := primary
	invalid[100] = 1
	testing.expect_value(
		t,
		block_write(image, primary_lba, invalid[:]).code,
		Error_Code.Protected_Write,
	)
	put_u32le(backup[:], 488, 0xFFFF_FFFF)
	put_u32le(backup[:], 492, 0xFFFF_FFFF)
	testing.expect_value(t, edit_block_write(image, backup_lba, backup[:]).code, Error_Code.None)
	edit_device := edit_block_device(image)
	data_lba := partition + u64(image.geometry.data_start) + u64(image.info.sectors_per_cluster)
	payload: [SECTOR_BYTES]u8
	payload[0] = 0xA5
	testing.expect(t, edit_device.write(edit_device.ctx, data_lba, payload[:]))
	testing.expect(
		t,
		!edit_device.write(edit_device.ctx, u64(image.info.marker_sector), payload[:]),
	)
	testing.expect(t, edit_device.flush(edit_device.ctx))
	testing.expect_value(t, close(image, .Clean).code, Error_Code.None)
	validated, validation_error := validate(path)
	if !testing.expect_value(t, validation_error.code, Error_Code.None) {return}
	defer info_destroy(&validated)
	testing.expect(t, !validated.dirty)
}

@(test)
fat32image_test_valid_external_fsinfo_divergence_normalizes_on_writable_open :: proc(
	t: ^testing.T,
) {
	directory, directory_ok := fat32image_test_directory(t)
	if !directory_ok {return}
	defer os.remove_all(directory)
	path, created, create_ok := fat32image_test_create(t, directory, "external-fsinfo.img")
	if !create_ok {return}
	partition := u64(created.partition_lba)
	defer info_destroy(&created)

	file, file_error := os.open(path, {.Read, .Write})
	if !testing.expect_value(t, file_error, os.Error(nil)) {return}
	vbr, primary: [SECTOR_BYTES]u8
	vbr_offset, _ := sector_offset(partition)
	testing.expect(t, read_exact_at(file, vbr[:], vbr_offset))
	primary_lba := partition + u64(get_u16le(vbr[:], 48))
	primary_offset, _ := sector_offset(primary_lba)
	testing.expect(t, read_exact_at(file, primary[:], primary_offset))
	put_u32le(primary[:], 488, 1234)
	put_u32le(primary[:], 492, 10)
	testing.expect(t, write_exact_at(file, primary[:], primary_offset))
	testing.expect_value(t, os.sync(file), os.Error(nil))
	_ = os.close(file)

	external, external_error := validate(path)
	if !testing.expect_value(t, external_error.code, Error_Code.None) {return}
	testing.expect(t, !external.dirty)
	info_destroy(&external)
	image, open_error := open(path, .Read_Write)
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
	testing.expect_value(t, check_filesystem(image).code, Error_Code.None)
	testing.expect_value(t, close(image, .Clean).code, Error_Code.None)
	validated, validation_error := validate(path)
	if !testing.expect_value(t, validation_error.code, Error_Code.None) {return}
	defer info_destroy(&validated)
	testing.expect(t, !validated.dirty)
}

@(test)
fat32image_test_dirty_image_opens_for_recovery_but_cannot_close_clean_while_invalid :: proc(
	t: ^testing.T,
) {
	directory, directory_ok := fat32image_test_directory(t)
	if !directory_ok {return}
	defer os.remove_all(directory)
	path, created, create_ok := fat32image_test_create(t, directory, "recover-invalid.img")
	if !create_ok {return}
	defer info_destroy(&created)
	image, open_error := open(path, .Read_Write)
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
	second_fat_lba :=
		u64(image.info.partition_lba) +
		u64(image.info.reserved_sectors) +
		u64(image.geometry.sectors_per_fat)
	fat: [SECTOR_BYTES]u8
	testing.expect_value(t, block_read(image, second_fat_lba, fat[:]).code, Error_Code.None)
	fat[8] = fat[8] ~ 1
	testing.expect_value(t, edit_block_write(image, second_fat_lba, fat[:]).code, Error_Code.None)
	testing.expect_value(t, close(image, .Retain).code, Error_Code.None)
	recovery, recovery_error := open(path, .Read_Write)
	if !testing.expect_value(t, recovery_error.code, Error_Code.None) {return}
	testing.expect(t, recovery.info.dirty)
	testing.expect_value(t, check_filesystem(recovery).code, Error_Code.Invalid_FAT32)
	testing.expect_value(t, close(recovery, .Clean).code, Error_Code.Invalid_FAT32)
	testing.expect_value(t, close(recovery, .Retain).code, Error_Code.None)
}

@(test)
fat32image_test_recovery_conservatively_merges_fat_status_bits :: proc(t: ^testing.T) {
	directory, directory_ok := fat32image_test_directory(t)
	if !directory_ok {return}
	defer os.remove_all(directory)
	path, created, create_ok := fat32image_test_create(t, directory, "recover-fat-status.img")
	if !create_ok {return}
	defer info_destroy(&created)
	image, open_error := open(path, .Read_Write)
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
	first_fat_lba := u64(image.info.partition_lba) + u64(image.info.reserved_sectors)
	second_fat_lba := first_fat_lba + u64(image.geometry.sectors_per_fat)
	first, second: [SECTOR_BYTES]u8
	testing.expect_value(t, block_read(image, first_fat_lba, first[:]).code, Error_Code.None)
	testing.expect_value(t, block_read(image, second_fat_lba, second[:]).code, Error_Code.None)
	put_u32le(first[:], 4, get_u32le(first[:], 4) & ~u32(0x0400_0000))
	testing.expect_value(t, block_write(image, first_fat_lba, first[:]).code, Error_Code.None)
	testing.expect_value(t, close(image, .Retain).code, Error_Code.None)

	recovery, recovery_error := open_staged(path, true)
	if !testing.expect_value(t, recovery_error.code, Error_Code.None) {return}
	testing.expect_value(t, activate(recovery).code, Error_Code.None)
	testing.expect_value(t, check_filesystem(recovery).code, Error_Code.Invalid_FAT32)
	testing.expect_value(t, complete_recovery(recovery).code, Error_Code.None)
	testing.expect_value(t, block_read(recovery, first_fat_lba, first[:]).code, Error_Code.None)
	testing.expect_value(t, block_read(recovery, second_fat_lba, second[:]).code, Error_Code.None)
	testing.expect_value(t, string(first[:]), string(second[:]))
	testing.expect_value(
		t,
		get_u32le(first[:], 4) & FAT_ENTRY1_STATUS_MASK,
		u32(0x0800_0000),
	)
	testing.expect_value(t, close(recovery, .Clean).code, Error_Code.None)
}

@(test)
fat32image_test_recovery_status_merge_is_bidirectional_idempotent_and_narrow :: proc(t: ^testing.T) {
	directory, directory_ok := fat32image_test_directory(t)
	if !directory_ok {return}
	defer os.remove_all(directory)
	cases := [?]struct {
		name:          string,
		clear_mask:    u32,
		second_mirror: bool,
		allowed:       bool,
	} {
		{"fat1-clean.img", 0x0800_0000, false, true},
		{"fat2-hard.img", 0x0400_0000, true, true},
		{"fat2-both.img", FAT_ENTRY1_STATUS_MASK, true, true},
		{"fat1-nonstatus.img", 0x0200_0000, false, false},
	}
	for item in cases {
		path, created, create_ok := fat32image_test_create(t, directory, item.name)
		if !create_ok {continue}
		image, open_error := open(path, .Read_Write)
		if !testing.expect_value(t, open_error.code, Error_Code.None) {
			info_destroy(&created)
			continue
		}
		first_fat_lba := u64(image.info.partition_lba) + u64(image.info.reserved_sectors)
		second_fat_lba := first_fat_lba + u64(image.geometry.sectors_per_fat)
		target_lba := item.second_mirror ? second_fat_lba : first_fat_lba
		sector: [SECTOR_BYTES]u8
		testing.expect_value(t, block_read(image, target_lba, sector[:]).code, Error_Code.None)
		original_status := get_u32le(sector[:], 4)
		put_u32le(sector[:], 4, original_status & ~item.clear_mask)
		if item.allowed {
			testing.expect_value(t, block_write(image, target_lba, sector[:]).code, Error_Code.None)
		} else {
			target_offset, offset_ok := sector_offset(target_lba)
			testing.expect(t, offset_ok && write_exact_at(image.file, sector[:], target_offset))
		}
		testing.expect_value(t, close(image, .Retain).code, Error_Code.None)

		recovery, recovery_error := open_staged(path, true)
		if !testing.expect_value(t, recovery_error.code, Error_Code.None) {
			info_destroy(&created)
			continue
		}
		testing.expect_value(t, activate(recovery).code, Error_Code.None)
		result := complete_recovery(recovery)
		if item.allowed {
			testing.expect_value(t, result.code, Error_Code.None)
			testing.expect_value(t, complete_recovery(recovery).code, Error_Code.None)
			first, second: [SECTOR_BYTES]u8
			testing.expect_value(t, block_read(recovery, first_fat_lba, first[:]).code, Error_Code.None)
			testing.expect_value(t, block_read(recovery, second_fat_lba, second[:]).code, Error_Code.None)
			testing.expect_value(t, string(first[:]), string(second[:]))
			testing.expect_value(
				t,
				get_u32le(first[:], 4) & FAT_ENTRY1_STATUS_MASK,
				(original_status & ~item.clear_mask) & FAT_ENTRY1_STATUS_MASK,
			)
			testing.expect_value(t, close(recovery, .Clean).code, Error_Code.None)
		} else {
			testing.expect_value(t, result.code, Error_Code.Invalid_FAT32)
			testing.expect_value(t, close(recovery, .Retain).code, Error_Code.None)
		}
		info_destroy(&created)
	}
}
