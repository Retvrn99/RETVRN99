// SPDX-License-Identifier: GPL-3.0-only
package fat32image

import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

@(private = "file")
fat32image_adoption_test_image :: proc(
	t: ^testing.T,
	sectors_per_cluster: u8,
) -> (
	^Image,
	string,
	[SECTOR_BYTES]u8,
	bool,
) {
	file, create_error := os.create_temp_file("", "retvrn99-adoption-vbr-*")
	if !testing.expect_value(t, create_error, os.Error(nil)) {return nil, "", {}, false}
	path := strings.clone(os.name(file))
	if !testing.expect_value(t, os.truncate(file, 8 * SECTOR_BYTES), os.Error(nil)) {
		_ = os.close(file)
		_ = os.remove(path)
		delete(path)
		return nil, "", {}, false
	}
	source: [SECTOR_BYTES]u8
	source[0], source[1], source[2] = 0xeb, 0x58, 0x90
	copy(source[3:11], "MSDOS5.0")
	put_u16le(source[:], 11, SECTOR_BYTES)
	source[13] = sectors_per_cluster
	put_u16le(source[:], 14, 8)
	source[16] = 2
	source[21] = 0xf8
	put_u32le(source[:], 32, 1_000_000)
	put_u32le(source[:], 36, 1_024)
	put_u32le(source[:], 44, 2)
	put_u16le(source[:], 48, 1)
	put_u16le(source[:], 50, 6)
	source[64] = 0x80
	source[66] = 0x29
	copy(source[71:82], "NO NAME    ")
	copy(source[82:90], "FAT32   ")
	source[90], source[91] = 0xfa, 0xf4
	source[510], source[511] = 0x55, 0xaa
	if !write_exact_at(file, source[:], 0) ||
	   !write_exact_at(file, source[:], 6 * SECTOR_BYTES) {
		_ = os.close(file)
		_ = os.remove(path)
		delete(path)
		return nil, "", source, false
	}
	image := new(Image)
	image.file = file
	image.mode = .Read_Write
	image.info = {
		image_id            = {
			0x52,
			0x45,
			0x54,
			0x56,
			0x52,
			0x4e,
			0x49,
			0x44,
			0x31,
			0x32,
			0x33,
			0x34,
			0x35,
			0x36,
			0x37,
			0x38,
		},
		sector_count        = 8,
		partition_lba       = 0,
		partition_sectors   = 1_000_000,
		sectors_per_cluster = sectors_per_cluster,
		reserved_sectors    = 8,
		enrolled            = true,
	}
	image.geometry = {
		disk_sectors        = 8,
		partition_lba       = 0,
		partition_sectors   = 1_000_000,
		sectors_per_cluster = sectors_per_cluster,
		reserved_sectors    = 8,
		fat_count           = 2,
		sectors_per_fat     = 1_024,
		data_start          = 2_056,
		cluster_count       = 120_000,
		fsinfo_sector       = 1,
		backup_vbr_sector   = 6,
	}
	return image, path, source, true
}

@(private = "file")
fat32image_adoption_test_destroy :: proc(image: ^Image, path: string) {
	if image != nil {
		if image.file != nil {_ = os.close(image.file)}
		free(image)
	}
	if path != "" {
		_ = os.remove(path)
		delete(path)
	}
}

@(test)
fat32image_adoption_test_rejects_cluster_smaller_than_loader_transfer :: proc(t: ^testing.T) {
	image, path, _, image_ok := fat32image_adoption_test_image(t, 2)
	if !image_ok {return}
	defer fat32image_adoption_test_destroy(image, path)
	_, adoption_error := prepare_adoption_boot_pair(image)
	testing.expect_value(t, adoption_error.code, Error_Code.Boot_Code_Unsupported)
}

@(test)
fat32image_adoption_test_emits_current_twin_vbrs_with_preserved_bpb_and_data_lba :: proc(t: ^testing.T) {
	image, path, source, image_ok := fat32image_adoption_test_image(t, 8)
	if !image_ok {return}
	defer fat32image_adoption_test_destroy(image, path)
	pair, adoption_error := prepare_adoption_boot_pair(image)
	if !testing.expect_value(t, adoption_error.code, Error_Code.None) {return}
	testing.expect_value(t, pair.primary_lba, u64(0))
	testing.expect_value(t, pair.backup_lba, u64(6))
	testing.expect_value(t, pair.adopted_backup, pair.adopted_primary)
	testing.expect(t, slice.equal(pair.adopted_primary[11:67], source[11:67]))
	testing.expect(t, boot_loader_recognized(pair.adopted_primary[:]))
	testing.expect_value(
		t,
		get_u32le(pair.adopted_primary[:], VBR_DATA_LBA_OFFSET),
		image.geometry.partition_lba + image.geometry.data_start,
	)
}
