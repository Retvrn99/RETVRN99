// SPDX-License-Identifier: GPL-3.0-only
package fat32image

import "core:os"
import "core:testing"

@(test)
fat32image_test_windows_98_zero_next_free_hint_is_accepted :: proc(t: ^testing.T) {
	directory, directory_ok := fat32image_test_directory(t)
	if !directory_ok {return}
	defer os.remove_all(directory)
	path, created, create_ok := fat32image_test_create(t, directory, "windows-fsinfo.img")
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
	put_u32le(primary[:], 488, image.geometry.cluster_count / 2)
	put_u32le(primary[:], 492, 0)
	put_u32le(backup[:], 488, image.geometry.cluster_count / 2)
	put_u32le(backup[:], 492, 0)
	testing.expect_value(t, block_write(image, primary_lba, primary[:]).code, Error_Code.None)
	testing.expect_value(t, block_write(image, backup_lba, backup[:]).code, Error_Code.None)
	testing.expect_value(t, close(image, .Clean).code, Error_Code.None)

	validated, validation_error := validate(path)
	if !testing.expect_value(t, validation_error.code, Error_Code.None) {return}
	defer info_destroy(&validated)
	testing.expect(t, !validated.dirty)
}

@(test)
fat32image_test_reserved_next_free_hint_one_remains_rejected :: proc(t: ^testing.T) {
	directory, directory_ok := fat32image_test_directory(t)
	if !directory_ok {return}
	defer os.remove_all(directory)
	path, created, create_ok := fat32image_test_create(t, directory, "invalid-fsinfo.img")
	if !create_ok {return}
	defer info_destroy(&created)
	image, open_error := open(path, .Read_Write)
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
	defer if image != nil {_ = close(image, .Retain)}
	primary_lba := u64(image.info.partition_lba) + u64(image.geometry.fsinfo_sector)
	primary: [SECTOR_BYTES]u8
	testing.expect_value(t, block_read(image, primary_lba, primary[:]).code, Error_Code.None)
	put_u32le(primary[:], 492, 1)
	testing.expect_value(
		t,
		block_write(image, primary_lba, primary[:]).code,
		Error_Code.Protected_Write,
	)
}
