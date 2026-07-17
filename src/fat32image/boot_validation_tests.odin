// SPDX-License-Identifier: GPL-3.0-only
package fat32image

import "core:os"
import "core:slice"
import "core:testing"

LEGACY_FIXED_VBR_BIN :: #load("testdata/legacy_fixed_vbr.bin")

Boot_Test_Corruption :: enum {
	Jump,
	Data_LBA,
	Backup_Code,
}

@(private = "file")
boot_test_read_pair :: proc(
	file: ^os.File,
	partition_lba: u64,
	primary, backup: []u8,
) -> bool {
	primary_offset, primary_ok := sector_offset(partition_lba)
	if !primary_ok || !read_exact_at(file, primary, primary_offset) {return false}
	backup_lba := partition_lba + u64(get_u16le(primary, 50))
	backup_offset, backup_ok := sector_offset(backup_lba)
	return backup_ok && read_exact_at(file, backup, backup_offset)
}

@(private = "file")
boot_test_write_pair :: proc(
	file: ^os.File,
	partition_lba: u64,
	primary, backup: []u8,
) -> bool {
	primary_offset, primary_ok := sector_offset(partition_lba)
	backup_lba := partition_lba + u64(get_u16le(primary, 50))
	backup_offset, backup_ok := sector_offset(backup_lba)
	return(
		primary_ok &&
		backup_ok &&
		write_exact_at(file, backup, backup_offset) &&
		write_exact_at(file, primary, primary_offset) &&
		os.sync(file) == nil \
	)
}

@(private = "file")
boot_test_create_patched :: proc(
	t: ^testing.T,
	directory, name: string,
) -> (
	string,
	Image_Info,
	bool,
) {
	path, created, create_ok := fat32image_test_create(t, directory, name)
	if !create_ok {return path, created, false}
	image, open_error := open(path, .Read_Write)
	if !testing.expect_value(t, open_error.code, Error_Code.None) {
		return path, created, false
	}
	data_lba := u64(image.geometry.partition_lba) + u64(image.geometry.data_start)
	cluster := u32(3)
	io_sys_lba := data_lba + u64(image.geometry.sectors_per_cluster)
	patch_error := patch_boot_loader(image, io_sys_lba, cluster)
	if !testing.expect_value(t, patch_error.code, Error_Code.None) {
		_ = close(image, .Retain)
		return path, created, false
	}
	if !testing.expect_value(t, close(image, .Clean).code, Error_Code.None) {
		return path, created, false
	}
	return path, created, true
}

@(test)
fat32image_boot_test_jump_data_lba_and_backup_code_corruption_fail_closed :: proc(
	t: ^testing.T,
) {
	directory, directory_ok := fat32image_test_directory(t)
	if !directory_ok {return}
	defer os.remove_all(directory)
	cases := [?]struct {
		name:       string,
		corruption: Boot_Test_Corruption,
		expected:   Error_Code,
	} {
		{"jump.img", .Jump, .Marker_Invalid},
		{"data-lba.img", .Data_LBA, .Marker_Invalid},
		{"backup-code.img", .Backup_Code, .Invalid_FAT32},
	}
	for item in cases {
		path, created, create_ok := boot_test_create_patched(t, directory, item.name)
		if !create_ok {
			info_destroy(&created)
			continue
		}
		partition_lba := u64(created.partition_lba)
		file, file_error := os.open(path, {.Read, .Write})
		if !testing.expect_value(t, file_error, os.Error(nil)) {
			info_destroy(&created)
			continue
		}
		primary, backup: [SECTOR_BYTES]u8
		if testing.expect(t, boot_test_read_pair(file, partition_lba, primary[:], backup[:])) {
			switch item.corruption {
			case .Jump:
				primary[0] = primary[0] ~ 1
				backup[0] = backup[0] ~ 1
			case .Data_LBA:
				put_u32le(
					primary[:],
					VBR_DATA_LBA_OFFSET,
					get_u32le(primary[:], VBR_DATA_LBA_OFFSET) + 1,
				)
				copy(backup[:], primary[:])
			case .Backup_Code:
				backup[100] = backup[100] ~ 1
			}
			testing.expect(t, boot_test_write_pair(file, partition_lba, primary[:], backup[:]))
		}
		_ = os.close(file)
		_, validation_error := validate(path)
		testing.expect_value(t, validation_error.code, item.expected)
		info_destroy(&created)
	}
}

@(test)
fat32image_boot_test_recovery_rejects_noncanonical_loader_and_mismatched_twins :: proc(
	t: ^testing.T,
) {
	directory, directory_ok := fat32image_test_directory(t)
	if !directory_ok {return}
	defer os.remove_all(directory)
	path, created, create_ok := boot_test_create_patched(t, directory, "recovery.img")
	if !create_ok {return}
	defer info_destroy(&created)
	image, open_error := open(path, .Read_Write)
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
	testing.expect_value(t, close(image, .Retain).code, Error_Code.None)
	recovery, recovery_error := open_staged(path, true)
	if !testing.expect_value(t, recovery_error.code, Error_Code.None) {return}
	primary, backup: [SECTOR_BYTES]u8
	partition_lba := u64(recovery.geometry.partition_lba)
	if !testing.expect(
		t,
		boot_test_read_pair(recovery.file, partition_lba, primary[:], backup[:]),
	) {
		_ = close(recovery, .Retain)
		return
	}
	testing.expect(t, recovery_boot_sector_write_valid(recovery, partition_lba, primary[:]))
	bad_jump := primary
	bad_jump[0] = bad_jump[0] ~ 1
	testing.expect(t, !recovery_boot_sector_write_valid(recovery, partition_lba, bad_jump[:]))
	bad_data_lba := primary
	put_u32le(
		bad_data_lba[:],
		VBR_DATA_LBA_OFFSET,
		get_u32le(bad_data_lba[:], VBR_DATA_LBA_OFFSET) + 1,
	)
	testing.expect(t, !recovery_boot_sector_write_valid(recovery, partition_lba, bad_data_lba[:]))
	backup[100] = backup[100] ~ 1
	testing.expect(t, boot_test_write_pair(recovery.file, partition_lba, primary[:], backup[:]))
	testing.expect_value(t, complete_recovery(recovery).code, Error_Code.Invalid_FAT32)
	testing.expect_value(t, close(recovery, .Retain).code, Error_Code.None)
}

@(test)
fat32image_boot_test_legacy_fixed_target_loader_migrates_to_current_twin_vbrs :: proc(
	t: ^testing.T,
) {
	directory, directory_ok := fat32image_test_directory(t)
	if !directory_ok {return}
	defer os.remove_all(directory)
	path, created, create_ok := fat32image_test_create(t, directory, "legacy.img")
	if !create_ok {return}
	defer info_destroy(&created)
	file, file_error := os.open(path, {.Read, .Write})
	if !testing.expect_value(t, file_error, os.Error(nil)) {return}
	primary, backup: [SECTOR_BYTES]u8
	partition_lba := u64(created.partition_lba)
	if !testing.expect(t, boot_test_read_pair(file, partition_lba, primary[:], backup[:])) {
		_ = os.close(file)
		return
	}
	legacy: [SECTOR_BYTES]u8
	copy(legacy[:], LEGACY_FIXED_VBR_BIN)
	copy(legacy[3:90], primary[3:90])
	data_lba :=
		partition_lba +
		u64(created.reserved_sectors) +
		u64(primary[16]) * u64(get_u32le(primary[:], 36))
	cluster := u32(3)
	io_sys_lba := data_lba + u64(created.sectors_per_cluster)
	put_u32le(legacy[:], VBR_DATA_LBA_OFFSET, u32(data_lba))
	put_u32le(legacy[:], VBR_CLUSTER_OFFSET, cluster)
	put_u64le(legacy[:], VBR_IO_SYS_LBA_OFFSET, io_sys_lba)
	copy(backup[:], legacy[:])
	testing.expect_value(t, boot_loader_kind(legacy[:]), Boot_Loader_Kind.Legacy)
	testing.expect(t, boot_test_write_pair(file, partition_lba, legacy[:], backup[:]))
	_ = os.close(file)
	legacy_info, legacy_error := validate(path)
	if !testing.expect_value(t, legacy_error.code, Error_Code.None) {return}
	info_destroy(&legacy_info)
	image, open_error := open(path, .Read_Write)
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
	testing.expect_value(
		t,
		patch_boot_loader(image, io_sys_lba, cluster).code,
		Error_Code.None,
	)
	testing.expect_value(t, close(image, .Clean).code, Error_Code.None)
	file, file_error = os.open(path, {.Read})
	if !testing.expect_value(t, file_error, os.Error(nil)) {return}
	current_primary, current_backup: [SECTOR_BYTES]u8
	testing.expect(
		t,
		boot_test_read_pair(file, partition_lba, current_primary[:], current_backup[:]),
	)
	_ = os.close(file)
	testing.expect_value(t, boot_loader_kind(current_primary[:]), Boot_Loader_Kind.Current)
	testing.expect(t, slice.equal(current_primary[:], current_backup[:]))
	testing.expect_value(t, get_u32le(current_primary[:], VBR_DATA_LBA_OFFSET), u32(data_lba))
	validated, validation_error := validate(path)
	if !testing.expect_value(t, validation_error.code, Error_Code.None) {return}
	info_destroy(&validated)
}
