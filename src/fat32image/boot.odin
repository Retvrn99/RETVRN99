// SPDX-License-Identifier: GPL-3.0-only
package fat32image

import "core:hash"
import "core:os"
import "core:slice"

VBR_DATA_LBA_OFFSET :: 0x1E0
VBR_CLUSTER_OFFSET :: 0x1E4
VBR_IO_SYS_LBA_OFFSET :: 0x1F0

Boot_Loader_Kind :: enum u8 {
	None,
	Current,
	Legacy,
}

@(private = "file")
boot_jump_recognized :: proc(vbr: []u8) -> bool {
	return len(vbr) == SECTOR_BYTES && vbr[0] == 0xEB && vbr[1] == 0x58 && vbr[2] == 0x90
}

@(private = "package")
boot_stub_recognized :: proc(vbr: []u8) -> bool {
	if !boot_jump_recognized(vbr) ||
	   vbr[90] != 0xCD ||
	   vbr[91] != 0x18 ||
	   vbr[510] != 0x55 ||
	   vbr[511] != 0xAA {return false}
	for octet in vbr[92:510] {if octet != 0 {return false}}
	return true
}

@(private = "package")
boot_loader_kind :: proc(vbr: []u8) -> Boot_Loader_Kind {
	if !boot_jump_recognized(vbr) || vbr[510] != 0x55 || vbr[511] != 0xAA {return .None}
	expected: [SECTOR_BYTES]u8
	copy(expected[:], VBR_BIN)
	current :=
		slice.equal(vbr[90:VBR_DATA_LBA_OFFSET], expected[90:VBR_DATA_LBA_OFFSET]) &&
		slice.equal(
			vbr[VBR_IO_SYS_LBA_OFFSET - 8:VBR_IO_SYS_LBA_OFFSET],
			expected[VBR_IO_SYS_LBA_OFFSET - 8:VBR_IO_SYS_LBA_OFFSET],
		) &&
		slice.equal(vbr[VBR_IO_SYS_LBA_OFFSET + 8:510], expected[VBR_IO_SYS_LBA_OFFSET + 8:510]) &&
		vbr[510] == 0x55 &&
		vbr[511] == 0xAA
	if current {return .Current}
	legacy :=
		hash.crc32(vbr[90:VBR_DATA_LBA_OFFSET]) == 0xF6CD_8E50 &&
		hash.crc32(vbr[VBR_IO_SYS_LBA_OFFSET - 8:VBR_IO_SYS_LBA_OFFSET]) == 0x8747_BAD1 &&
		hash.crc32(vbr[VBR_IO_SYS_LBA_OFFSET + 8:510]) == 0xB1C2_A1A3 &&
		vbr[510] == 0x55 &&
		vbr[511] == 0xAA
	return legacy ? .Legacy : .None
}

@(private = "package")
boot_loader_recognized :: proc(vbr: []u8) -> bool {
	return boot_loader_kind(vbr) != .None
}

@(private = "file")
boot_target_valid :: proc(vbr: []u8, geometry: ^Geometry, allow_empty: bool) -> bool {
	cluster := get_u32le(vbr, VBR_CLUSTER_OFFSET)
	io_sys_lba := get_u64le(vbr, VBR_IO_SYS_LBA_OFFSET)
	if cluster == 0 {return allow_empty && io_sys_lba == 0}
	if cluster < 2 || cluster >= geometry.cluster_count + 2 {return false}
	expected_lba :=
		u64(geometry.partition_lba) +
		u64(geometry.data_start) +
		u64(cluster - 2) * u64(geometry.sectors_per_cluster)
	partition_end := u64(geometry.partition_lba) + u64(geometry.partition_sectors)
	return(
		io_sys_lba == expected_lba &&
		io_sys_lba <= partition_end &&
		4 <= partition_end - io_sys_lba \
	)
}

@(private = "package")
boot_loader_valid_for_geometry :: proc(vbr: []u8, geometry: ^Geometry) -> bool {
	if geometry == nil || geometry.sectors_per_cluster < 4 {return false}
	kind := boot_loader_kind(vbr)
	if kind == .None {return false}
	expected_data_lba := u64(geometry.partition_lba) + u64(geometry.data_start)
	if expected_data_lba > 0xFFFF_FFFF ||
	   u64(get_u32le(vbr, VBR_DATA_LBA_OFFSET)) != expected_data_lba {
		return false
	}
	return boot_target_valid(vbr, geometry, kind == .Current)
}

@(private = "package")
boot_sector_valid_for_geometry :: proc(vbr: []u8, geometry: ^Geometry) -> bool {
	return boot_stub_recognized(vbr) || boot_loader_valid_for_geometry(vbr, geometry)
}

@(private = "package")
boot_sector_recognized :: proc(vbr: []u8) -> bool {
	return boot_stub_recognized(vbr) || boot_loader_recognized(vbr)
}

prepare_boot_loader_patch :: proc(
	image: ^Image,
	io_sys_lba: u64,
	io_sys_cluster: u32,
) -> (
	primary_lba, backup_lba: u64,
	primary_patch, backup_patch: [SECTOR_BYTES]u8,
	err: Image_Error,
) {
	if image == nil ||
	   image.closed ||
	   image.file == nil {err = error_make(.Closed, false, "hard-drive image is closed"); return}
	if image.mode !=
	   .Read_Write {err = error_make(.Read_Only, false, "hard-drive image is read-only"); return}
	if !image.info.enrolled || !image.info.retvrn99_format {
		err = error_make(
			.Boot_Code_Unsupported,
			false,
			"boot-loader patching requires a RETVRN99-formatted image",
		)
		return
	}
	primary, backup: [SECTOR_BYTES]u8
	primary_lba = u64(image.info.partition_lba)
	primary_offset, primary_ok := sector_offset(primary_lba)
	if !primary_ok || !read_exact_at(image.file, primary[:], primary_offset) {
		err = error_make(.IO, false, "cannot read the primary FAT32 boot sector")
		return
	}
	backup_relative := get_u16le(primary[:], 50)
	if backup_relative == 0 || backup_relative >= image.info.reserved_sectors {
		err = error_make(.Invalid_FAT32, false, "FAT32 backup boot-sector geometry is invalid")
		return
	}
	backup_lba = primary_lba + u64(backup_relative)
	backup_offset, backup_ok := sector_offset(backup_lba)
	if !backup_ok || !read_exact_at(image.file, backup[:], backup_offset) {
		err = error_make(.IO, false, "cannot read the backup FAT32 boot sector")
		return
	}
	if string(primary[3:11]) != "MSWIN4.1" ||
	   string(primary[71:82]) != "RETVRN99   " ||
	   !slice.equal(primary[11:90], backup[11:90]) ||
	   !boot_sector_valid_for_geometry(primary[:], &image.geometry) ||
	   !boot_sector_valid_for_geometry(backup[:], &image.geometry) {
		err = error_make(
			.Boot_Code_Unsupported,
			false,
			"FAT32 boot sectors do not contain RETVRN99 boot code",
		)
		return
	}
	spc := u64(primary[13])
	reserved := u64(get_u16le(primary[:], 14))
	fat_count := u64(primary[16])
	spf := u64(get_u32le(primary[:], 36))
	if spc < 4 ||
	   spc > 64 ||
	   reserved == 0 ||
	   fat_count != 2 ||
	   spf == 0 ||
	   reserved + fat_count * spf >= u64(image.info.partition_sectors) {
		err = error_make(
			.Invalid_FAT32,
			false,
			"FAT32 boot geometry changed while the image was open",
		)
		return
	}
	data_lba := primary_lba + reserved + fat_count * spf
	data_sectors := u64(image.info.partition_sectors) - reserved - fat_count * spf
	cluster_count := data_sectors / spc
	if io_sys_cluster < 2 || u64(io_sys_cluster) >= cluster_count + 2 {
		err = error_make(
			.Invalid_Boot_Target,
			false,
			"IO.SYS cluster is outside the FAT32 data area",
		)
		return
	}
	expected_lba := data_lba + (u64(io_sys_cluster) - 2) * spc
	partition_end := primary_lba + u64(image.info.partition_sectors)
	if io_sys_lba != expected_lba || io_sys_lba > partition_end || 4 > partition_end - io_sys_lba {
		err = error_make(
			.Invalid_Boot_Target,
			false,
			"IO.SYS LBA does not match its FAT32 cluster",
		)
		return
	}
	copy(primary_patch[:], VBR_BIN)
	copy(primary_patch[3:90], primary[3:90])
	put_u32le(primary_patch[:], VBR_DATA_LBA_OFFSET, u32(data_lba))
	put_u32le(primary_patch[:], VBR_CLUSTER_OFFSET, io_sys_cluster)
	put_u64le(primary_patch[:], VBR_IO_SYS_LBA_OFFSET, io_sys_lba)
	copy(backup_patch[:], primary_patch[:])
	return
}

prepare_boot_stub_restore :: proc(
	image: ^Image,
) -> (
	primary_lba, backup_lba: u64,
	primary_stub, backup_stub: [SECTOR_BYTES]u8,
	err: Image_Error,
) {
	if image == nil || image.closed || image.file == nil {
		err = error_make(.Closed, false, "hard-drive image is closed")
		return
	}
	if image.mode != .Read_Write {
		err = error_make(.Read_Only, false, "hard-drive image is read-only")
		return
	}
	if !image.info.enrolled || !image.info.retvrn99_format {
		err = error_make(
			.Boot_Code_Unsupported,
			false,
			"boot-loader restoration requires a RETVRN99-formatted image",
		)
		return
	}
	primary, backup: [SECTOR_BYTES]u8
	primary_lba = u64(image.info.partition_lba)
	primary_offset, primary_ok := sector_offset(primary_lba)
	if !primary_ok || !read_exact_at(image.file, primary[:], primary_offset) {
		err = error_make(.IO, false, "cannot read the primary FAT32 boot sector")
		return
	}
	backup_relative := get_u16le(primary[:], 50)
	if backup_relative == 0 || backup_relative >= image.info.reserved_sectors {
		err = error_make(.Invalid_FAT32, false, "FAT32 backup boot-sector geometry is invalid")
		return
	}
	backup_lba = primary_lba + u64(backup_relative)
	backup_offset, backup_ok := sector_offset(backup_lba)
	if !backup_ok || !read_exact_at(image.file, backup[:], backup_offset) {
		err = error_make(.IO, false, "cannot read the backup FAT32 boot sector")
		return
	}
	if string(primary[3:11]) != "MSWIN4.1" ||
	   string(primary[71:82]) != "RETVRN99   " ||
	   !slice.equal(primary[11:90], backup[11:90]) ||
	   !boot_sector_valid_for_geometry(primary[:], &image.geometry) ||
	   !boot_sector_valid_for_geometry(backup[:], &image.geometry) {
		err = error_make(
			.Boot_Code_Unsupported,
			false,
			"FAT32 boot sectors do not contain RETVRN99 boot code",
		)
		return
	}
	copy(primary_stub[:90], primary[:90])
	primary_stub[90] = 0xCD
	primary_stub[91] = 0x18
	primary_stub[510] = 0x55
	primary_stub[511] = 0xAA
	copy(backup_stub[:], primary_stub[:])
	return
}

@(private = "package")
recovery_boot_sector_write_valid :: proc(image: ^Image, lba: u64, data: []u8) -> bool {
	if image == nil ||
	   !image.recovery_grade ||
	   !image.info.retvrn99_format ||
	   len(data) != SECTOR_BYTES {
		return false
	}
	primary_lba := u64(image.geometry.partition_lba)
	backup_lba := primary_lba + u64(image.geometry.backup_vbr_sector)
	if lba != primary_lba && lba != backup_lba {return false}
	primary: [SECTOR_BYTES]u8
	primary_offset, primary_ok := sector_offset(primary_lba)
	if !primary_ok || !read_exact_at(image.file, primary[:], primary_offset) {
		return false
	}
	if !slice.equal(data[3:90], primary[3:90]) ||
	   !boot_sector_valid_for_geometry(data, &image.geometry) {
		return false
	}
	return true
}

@(private = "package")
edit_boot_sector_write_valid :: proc(image: ^Image, lba: u64, data: []u8) -> bool {
	if image == nil || len(data) != SECTOR_BYTES {return false}
	if recovery_boot_sector_write_valid(image, lba, data) {return true}
	if adoption_boot_sector_write_valid(image, lba, data) {return true}
	if boot_loader_recognized(data) {
		io_sys_lba := get_u64le(data, VBR_IO_SYS_LBA_OFFSET)
		io_sys_cluster := get_u32le(data, VBR_CLUSTER_OFFSET)
		primary_lba, backup_lba, primary, backup, patch_error := prepare_boot_loader_patch(
			image,
			io_sys_lba,
			io_sys_cluster,
		)
		if patch_error.code != .None {return false}
		if lba == primary_lba {return slice.equal(data, primary[:])}
		if lba == backup_lba {return slice.equal(data, backup[:])}
		return false
	}
	if boot_stub_recognized(data) {
		primary_lba, backup_lba, primary, backup, restore_error := prepare_boot_stub_restore(image)
		if restore_error.code != .None {return false}
		if lba == primary_lba {return slice.equal(data, primary[:])}
		if lba == backup_lba {return slice.equal(data, backup[:])}
	}
	return false
}

patch_boot_loader :: proc(image: ^Image, io_sys_lba: u64, io_sys_cluster: u32) -> Image_Error {
	primary_lba, backup_lba, primary, backup, patch_error := prepare_boot_loader_patch(
		image,
		io_sys_lba,
		io_sys_cluster,
	)
	if patch_error.code != .None {return patch_error}
	primary_offset, primary_ok := sector_offset(primary_lba)
	backup_offset, backup_ok := sector_offset(backup_lba)
	if !primary_ok ||
	   !backup_ok ||
	   !write_exact_at(image.file, backup[:], backup_offset) ||
	   !write_exact_at(image.file, primary[:], primary_offset) {
		return error_make(.IO, false, "cannot update both RETVRN99 FAT32 boot sectors")
	}
	if os.sync(image.file) != nil {
		return error_make(
			.Sync_Failed,
			false,
			"cannot durably synchronize the RETVRN99 boot-loader patch",
		)
	}
	return {}
}
