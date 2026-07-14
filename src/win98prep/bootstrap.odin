// SPDX-License-Identifier: GPL-3.0-only
package win98prep

import profile "../profile"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

BOOTSTRAP_AUTOEXEC_NAME :: "AUTOEXEC.BAT"
BOOTSTRAP_AUTOEXEC_BACKUP_NAME :: "GSWAUTO.PRV"
BOOTSTRAP_AUTOEXEC_STAGING_NAME :: "GSWAUT.NXT"
BOOTSTRAP_AUTOEXEC :: "@REM RETVRN99 WINDOWS 98 BOOTSTRAP V1\r\n@ECHO OFF\r\nC:\\GSWSETUP.BAT\r\n"
BOOTSTRAP_RECOVERY_NAME :: "GSWBOOT.NXT"
BOOTSTRAP_RECOVERY_FRESH_HEADER :: "RETVRN99 WINDOWS 98 BOOTSTRAP RECOVERY V2 FRESH\r\n"
BOOTSTRAP_RECOVERY_EXISTING :: "RETVRN99 WINDOWS 98 BOOTSTRAP RECOVERY V1 EXISTING\r\n"

BOOTSTRAP_SYSTEM_NAMES :: [3]string{"IO.SYS", "MSDOS.SYS", "COMMAND.COM"}
BOOTSTRAP_SYSTEM_STAGING_NAMES :: [3]string{"GSWIO.NXT", "GSWMSD.NXT", "GSWCMD.NXT"}
BOOTSTRAP_FAT_NAMES :: [3]string{"IO      SYS", "MSDOS   SYS", "COMMAND COM"}

BOOTSTRAP_IMAGE_MAX_BYTES :: 4 * 1024 * 1024

Bootstrap_Diagnostic :: enum {
	None,
	Existing_DOS,
	Partial_DOS,
	Boot_Image_Required,
	Boot_Image_Open_Failed,
	Boot_Image_Invalid,
	Path_Failed,
	Staging_Collision,
	Autoexec_Backup_Collision,
	Recovery_Failed,
	Stage_Write_Failed,
	Commit_Failed,
	Rollback_Failed,
}

Bootstrap_Transaction_State :: enum {
	Inactive,
	Pending,
	Finalized,
	Rolled_Back,
	Rollback_Failed,
}

@(private)
Bootstrap_Fingerprint :: struct {
	size: u64,
	crc:  u32,
}

Bootstrap_Transaction :: struct {
	state:              Bootstrap_Transaction_State,
	system_installed:   [3]bool,
	system_fingerprint: [3]Bootstrap_Fingerprint,
	autoexec_installed: bool,
	autoexec_backed_up: bool,
	autoexec_reused:    bool,
	used_existing_dos:  bool,
}

@(private)
Bootstrap_Files :: struct {
	data: [3][]u8,
}

@(private)
bootstrap_files_destroy :: proc(files: ^Bootstrap_Files) {
	if files == nil {return}
	for &data in files.data {
		delete(data)
	}
	files^ = {}
}

bootstrap_install :: proc(
	c_drive, boot_image_path: string,
) -> (
	Bootstrap_Transaction,
	Bootstrap_Diagnostic,
) {
	return bootstrap_install_with_rename(c_drive, boot_image_path, os.rename)
}

bootstrap_finish :: proc(transaction: ^Bootstrap_Transaction, c_drive: string) -> bool {
	if transaction == nil {return false}
	if transaction.state == .Finalized {return true}
	if transaction.state != .Pending {return false}
	transaction.state = .Finalized
	paths, paths_ok := bootstrap_paths(c_drive)
	if !paths_ok {return false}
	defer bootstrap_paths_destroy(&paths)
	if !bootstrap_recovery_marker_remove(&paths) {return false}
	return true
}

bootstrap_rollback :: proc(transaction: ^Bootstrap_Transaction, c_drive: string) -> bool {
	return bootstrap_rollback_with_rename(transaction, c_drive, os.rename)
}

bootstrap_recover :: proc(c_drive: string) -> bool {
	return bootstrap_recover_with_rename(c_drive, os.rename)
}

bootstrap_recover_interrupted :: proc(c_drive: string) -> bool {
	return bootstrap_recover_mode_with_rename(c_drive, os.rename, false)
}

@(private)
Bootstrap_Rename_Proc :: #type proc(old_path, new_path: string) -> os.Error

@(private)
bootstrap_install_with_rename :: proc(
	c_drive, boot_image_path: string,
	rename_path: Bootstrap_Rename_Proc,
) -> (
	transaction: Bootstrap_Transaction,
	diagnostic: Bootstrap_Diagnostic,
) {
	if c_drive == "" || rename_path == nil {return {}, .Path_Failed}
	if !bootstrap_recover_with_rename(c_drive, rename_path) {return {}, .Recovery_Failed}

	paths, paths_ok := bootstrap_paths(c_drive)
	if !paths_ok {return {}, .Path_Failed}
	defer bootstrap_paths_destroy(&paths)

	io_exists := os.exists(paths.system[0])
	command_exists := os.exists(paths.system[2])
	if io_exists != command_exists {return {}, .Partial_DOS}
	need_system := !io_exists
	transaction.used_existing_dos = !need_system
	autoexec_reused :=
		os.exists(paths.autoexec) &&
		bootstrap_file_matches(paths.autoexec, bootstrap_fingerprint_string(BOOTSTRAP_AUTOEXEC))
	transaction.autoexec_reused = autoexec_reused

	if os.exists(paths.autoexec_backup) && !autoexec_reused {
		return {}, .Autoexec_Backup_Collision
	}
	for staging in paths.system_staging {
		if os.exists(staging) {return {}, .Staging_Collision}
	}
	if os.exists(paths.autoexec_staging) {return {}, .Staging_Collision}
	if os.exists(paths.recovery) {return {}, .Staging_Collision}

	files: Bootstrap_Files
	defer bootstrap_files_destroy(&files)
	if need_system {
		if boot_image_path == "" {return {}, .Boot_Image_Required}
		files, diagnostic = bootstrap_extract_fat12(boot_image_path)
		if diagnostic != .None {return {}, diagnostic}
		if os.exists(paths.system[1]) {
			delete(files.data[1])
			files.data[1] = nil
		} else if bootstrap_msdos_placeholder(files.data[1]) {
			delete(files.data[1])
			files.data[1] = make([]u8, len(profile.DOS_SEED_MSDOS_SYS))
			copy(files.data[1], profile.DOS_SEED_MSDOS_SYS)
		}
	}

	recovery_marker := BOOTSTRAP_RECOVERY_EXISTING
	if need_system {
		marker_ok: bool
		recovery_marker, marker_ok = bootstrap_recovery_fresh_marker(&files)
		if !marker_ok {return {}, .Boot_Image_Invalid}
	}
	if os.write_entire_file(paths.recovery, recovery_marker) != nil {
		return {}, .Stage_Write_Failed
	}
	staged_autoexec := false
	if !autoexec_reused {
		if os.write_entire_file(paths.autoexec_staging, BOOTSTRAP_AUTOEXEC) != nil {
			bootstrap_staging_cleanup(&paths, {}, false, true)
			return {}, .Stage_Write_Failed
		}
		staged_autoexec = true
	}
	staged_system: [3]bool
	for data, index in files.data {
		if len(data) == 0 {continue}
		if os.write_entire_file(paths.system_staging[index], data) != nil {
			bootstrap_staging_cleanup(&paths, staged_system, staged_autoexec, true)
			return {}, .Stage_Write_Failed
		}
		staged_system[index] = true
	}

	if os.exists(paths.autoexec) && !autoexec_reused {
		if rename_path(paths.autoexec, paths.autoexec_backup) != nil {
			bootstrap_staging_cleanup(&paths, staged_system, staged_autoexec, true)
			return {}, .Commit_Failed
		}
		transaction.autoexec_backed_up = true
	}

	transaction.state = .Pending
	for data, index in files.data {
		if len(data) == 0 {continue}
		if os.exists(paths.system[index]) ||
		   rename_path(paths.system_staging[index], paths.system[index]) != nil {
			if !bootstrap_failed_install_restore(
				&transaction,
				c_drive,
				&paths,
				staged_system,
				staged_autoexec,
				rename_path,
			) {
				return transaction, .Rollback_Failed
			}
			return {}, .Commit_Failed
		}
		staged_system[index] = false
		transaction.system_installed[index] = true
		transaction.system_fingerprint[index] = bootstrap_fingerprint(data)
	}

	if !autoexec_reused &&
	   (os.exists(paths.autoexec) || rename_path(paths.autoexec_staging, paths.autoexec) != nil) {
		if !bootstrap_failed_install_restore(
			&transaction,
			c_drive,
			&paths,
			staged_system,
			staged_autoexec,
			rename_path,
		) {
			return transaction, .Rollback_Failed
		}
		return {}, .Commit_Failed
	}
	if !autoexec_reused {
		staged_autoexec = false
		transaction.autoexec_installed = true
	}
	return transaction, need_system ? .None : .Existing_DOS
}

@(private)
Bootstrap_Paths :: struct {
	system:           [3]string,
	system_staging:   [3]string,
	autoexec:         string,
	autoexec_staging: string,
	autoexec_backup:  string,
	recovery:         string,
}

@(private)
Bootstrap_Recovery_Mode :: enum {
	Absent,
	Fresh,
	Existing,
	Invalid,
}

@(private)
Bootstrap_Recovery_Record :: struct {
	mode:               Bootstrap_Recovery_Mode,
	system_owned:       [3]bool,
	system_fingerprint: [3]Bootstrap_Fingerprint,
}

@(private)
bootstrap_paths :: proc(c_drive: string) -> (paths: Bootstrap_Paths, ok: bool) {
	err: os.Error
	for name, index in BOOTSTRAP_SYSTEM_NAMES {
		paths.system[index], err = filepath.join({c_drive, name})
		if err != nil {bootstrap_paths_destroy(&paths); return {}, false}
	}
	for name, index in BOOTSTRAP_SYSTEM_STAGING_NAMES {
		paths.system_staging[index], err = filepath.join({c_drive, name})
		if err != nil {bootstrap_paths_destroy(&paths); return {}, false}
	}
	paths.autoexec, err = filepath.join({c_drive, BOOTSTRAP_AUTOEXEC_NAME})
	if err != nil {bootstrap_paths_destroy(&paths); return {}, false}
	paths.autoexec_staging, err = filepath.join({c_drive, BOOTSTRAP_AUTOEXEC_STAGING_NAME})
	if err != nil {bootstrap_paths_destroy(&paths); return {}, false}
	paths.autoexec_backup, err = filepath.join({c_drive, BOOTSTRAP_AUTOEXEC_BACKUP_NAME})
	if err != nil {bootstrap_paths_destroy(&paths); return {}, false}
	paths.recovery, err = filepath.join({c_drive, BOOTSTRAP_RECOVERY_NAME})
	if err != nil {bootstrap_paths_destroy(&paths); return {}, false}
	return paths, true
}

@(private)
bootstrap_paths_destroy :: proc(paths: ^Bootstrap_Paths) {
	if paths == nil {return}
	for &path in paths.system {delete(path)}
	for &path in paths.system_staging {delete(path)}
	delete(paths.autoexec)
	delete(paths.autoexec_staging)
	delete(paths.autoexec_backup)
	delete(paths.recovery)
	paths^ = {}
}

@(private)
bootstrap_staging_cleanup :: proc(
	paths: ^Bootstrap_Paths,
	system: [3]bool,
	autoexec, recovery: bool,
) {
	if paths == nil {return}
	for staged, index in system {
		if staged {_ = os.remove(paths.system_staging[index])}
	}
	if autoexec {_ = os.remove(paths.autoexec_staging)}
	if recovery {_ = bootstrap_recovery_marker_remove(paths)}
}

@(private)
bootstrap_recovery_fresh_marker :: proc(files: ^Bootstrap_Files) -> (string, bool) {
	if files == nil || len(files.data[0]) == 0 || len(files.data[2]) == 0 {return "", false}
	values: [3]string
	for data, index in files.data {
		if len(data) == 0 {
			values[index] = "-"
			continue
		}
		fingerprint := bootstrap_fingerprint(data)
		values[index] = fmt.tprintf("%d:%08x", fingerprint.size, fingerprint.crc)
	}
	return fmt.tprintf(
			"%s%s=%s\r\n%s=%s\r\n%s=%s\r\n",
			BOOTSTRAP_RECOVERY_FRESH_HEADER,
			BOOTSTRAP_SYSTEM_NAMES[0],
			values[0],
			BOOTSTRAP_SYSTEM_NAMES[1],
			values[1],
			BOOTSTRAP_SYSTEM_NAMES[2],
			values[2],
		),
		true
}

@(private)
bootstrap_recovery_read :: proc(path: string) -> Bootstrap_Recovery_Record {
	if !os.exists(path) {return {mode = .Absent}}
	data, read_error := os.read_entire_file(path, context.temp_allocator)
	if read_error != nil {return {mode = .Invalid}}
	defer delete(data, context.temp_allocator)
	contents := string(data)
	if contents == BOOTSTRAP_RECOVERY_EXISTING {return {mode = .Existing}}
	if !strings.has_prefix(contents, BOOTSTRAP_RECOVERY_FRESH_HEADER) {
		return {mode = .Invalid}
	}

	record := Bootstrap_Recovery_Record {
		mode = .Fresh,
	}
	cursor := len(BOOTSTRAP_RECOVERY_FRESH_HEADER)
	for name, index in BOOTSTRAP_SYSTEM_NAMES {
		if cursor + len(name) + 1 > len(contents) ||
		   contents[cursor:cursor + len(name)] != name ||
		   contents[cursor + len(name)] != '=' {
			return {mode = .Invalid}
		}
		cursor += len(name) + 1
		line_end := strings.index(contents[cursor:], "\r\n")
		if line_end < 0 {return {mode = .Invalid}}
		value := contents[cursor:cursor + line_end]
		cursor += line_end + 2
		if value == "-" {continue}
		separator := strings.index(value, ":")
		if separator <= 0 ||
		   len(value) - separator - 1 != 8 ||
		   strings.index(value[separator + 1:], ":") >= 0 {
			return {mode = .Invalid}
		}
		size_consumed, crc_consumed := 0, 0
		size, size_ok := strconv.parse_u64_of_base(value[:separator], 10, &size_consumed)
		crc, crc_ok := strconv.parse_u64_of_base(value[separator + 1:], 16, &crc_consumed)
		if !size_ok ||
		   size_consumed != separator ||
		   size == 0 ||
		   size > BOOTSTRAP_IMAGE_MAX_BYTES ||
		   !crc_ok ||
		   crc_consumed != 8 ||
		   crc > 0xffff_ffff {
			return {mode = .Invalid}
		}
		record.system_owned[index] = true
		record.system_fingerprint[index] = {
			size = size,
			crc  = u32(crc),
		}
	}
	if cursor != len(contents) || !record.system_owned[0] || !record.system_owned[2] {
		return {mode = .Invalid}
	}
	return record
}

@(private)
bootstrap_recovery_mode :: proc(path: string) -> Bootstrap_Recovery_Mode {
	return bootstrap_recovery_read(path).mode
}

@(private)
bootstrap_recovery_marker_remove :: proc(paths: ^Bootstrap_Paths) -> bool {
	if paths == nil {return false}
	mode := bootstrap_recovery_mode(paths.recovery)
	if mode == .Invalid {return false}
	return mode == .Absent || os.remove(paths.recovery) == nil
}

@(private)
bootstrap_recover_with_rename :: proc(
	c_drive: string,
	rename_path: Bootstrap_Rename_Proc,
) -> bool {
	return bootstrap_recover_mode_with_rename(c_drive, rename_path, true)
}

@(private)
bootstrap_recover_mode_with_rename :: proc(
	c_drive: string,
	rename_path: Bootstrap_Rename_Proc,
	preserve_finalized: bool,
) -> bool {
	if c_drive == "" || rename_path == nil {return false}
	paths, paths_ok := bootstrap_paths(c_drive)
	if !paths_ok {return false}
	defer bootstrap_paths_destroy(&paths)

	autoexec_exists := os.exists(paths.autoexec)
	staging_exists := os.exists(paths.autoexec_staging)
	backup_exists := os.exists(paths.autoexec_backup)
	recovery := bootstrap_recovery_read(paths.recovery)
	recovery_mode := recovery.mode
	if recovery_mode == .Invalid {return false}
	recovery_owned := recovery_mode == .Fresh || recovery_mode == .Existing
	expected := bootstrap_fingerprint_string(BOOTSTRAP_AUTOEXEC)
	autoexec_owned := autoexec_exists && bootstrap_file_matches(paths.autoexec, expected)
	staging_owned := staging_exists && bootstrap_file_matches(paths.autoexec_staging, expected)
	if staging_exists && !staging_owned {return false}
	if backup_exists && (!autoexec_owned && !staging_owned && !recovery_owned) {return false}
	if backup_exists && autoexec_exists && !autoexec_owned {return false}

	has_system_staging := false
	system_staging_exists: [3]bool
	for path, index in paths.system_staging {
		system_staging_exists[index] = os.exists(path)
		has_system_staging = has_system_staging || system_staging_exists[index]
	}
	if recovery_mode == .Fresh {
		for exists, index in system_staging_exists {
			if exists &&
			   (!recovery.system_owned[index] ||
					   !bootstrap_file_matches(
							   paths.system_staging[index],
							   recovery.system_fingerprint[index],
						   )) {
				return false
			}
		}
		for path, index in paths.system {
			if os.exists(path) &&
			   recovery.system_owned[index] &&
			   !bootstrap_file_matches(path, recovery.system_fingerprint[index]) {
				return false
			}
		}
	} else if recovery_mode == .Existing && has_system_staging {
		return false
	}
	if preserve_finalized && recovery_mode == .Absent && autoexec_owned && !staging_exists {
		return !has_system_staging
	}
	if has_system_staging && !autoexec_owned && !staging_owned && !recovery_owned {return false}

	for exists, index in system_staging_exists {
		if exists && os.remove(paths.system_staging[index]) != nil {return false}
	}
	if recovery_mode == .Fresh {
		io_exists := os.exists(paths.system[0])
		command_exists := os.exists(paths.system[2])
		if io_exists != command_exists {
			if io_exists && os.remove(paths.system[0]) != nil {return false}
			if command_exists && os.remove(paths.system[2]) != nil {return false}
		}
	}

	if backup_exists {
		if autoexec_owned {
			if staging_owned {
				if os.remove(paths.autoexec) != nil {return false}
			} else if rename_path(paths.autoexec, paths.autoexec_staging) != nil {
				return false
			}
			staging_owned = true
		}
		if rename_path(paths.autoexec_backup, paths.autoexec) != nil {
			if !os.exists(paths.autoexec) && staging_owned {
				_ = rename_path(paths.autoexec_staging, paths.autoexec)
			}
			return false
		}
	} else if autoexec_owned && os.remove(paths.autoexec) != nil {
		return false
	}

	if staging_owned &&
	   os.exists(paths.autoexec_staging) &&
	   os.remove(paths.autoexec_staging) != nil {
		return false
	}
	return bootstrap_recovery_marker_remove(&paths)
}

@(private)
bootstrap_failed_install_restore :: proc(
	transaction: ^Bootstrap_Transaction,
	c_drive: string,
	paths: ^Bootstrap_Paths,
	staged_system: [3]bool,
	staged_autoexec: bool,
	rename_path: Bootstrap_Rename_Proc,
) -> bool {
	bootstrap_staging_cleanup(paths, staged_system, false, false)
	if !bootstrap_rollback_with_rename(transaction, c_drive, rename_path) {return false}
	if staged_autoexec {_ = os.remove(paths.autoexec_staging)}
	return true
}

@(private)
bootstrap_rollback_with_rename :: proc(
	transaction: ^Bootstrap_Transaction,
	c_drive: string,
	rename_path: Bootstrap_Rename_Proc,
) -> bool {
	if transaction == nil || rename_path == nil {return false}
	if transaction.state == .Rolled_Back {return true}
	if transaction.state != .Pending {return false}
	paths, paths_ok := bootstrap_paths(c_drive)
	if !paths_ok {
		transaction.state = .Rollback_Failed
		return false
	}
	defer bootstrap_paths_destroy(&paths)
	if bootstrap_recovery_mode(paths.recovery) == .Invalid {
		transaction.state = .Rollback_Failed
		return false
	}

	if transaction.autoexec_installed &&
	   !bootstrap_file_matches(paths.autoexec, bootstrap_fingerprint_string(BOOTSTRAP_AUTOEXEC)) {
		transaction.state = .Rollback_Failed
		return false
	}
	if transaction.autoexec_backed_up && !os.exists(paths.autoexec_backup) {
		transaction.state = .Rollback_Failed
		return false
	}
	for installed, index in transaction.system_installed {
		if installed &&
		   !bootstrap_file_matches(paths.system[index], transaction.system_fingerprint[index]) {
			transaction.state = .Rollback_Failed
			return false
		}
	}

	if transaction.autoexec_installed && os.remove(paths.autoexec) != nil {
		transaction.state = .Rollback_Failed
		return false
	}
	if transaction.autoexec_backed_up &&
	   rename_path(paths.autoexec_backup, paths.autoexec) != nil {
		transaction.state = .Rollback_Failed
		return false
	}
	for installed, index in transaction.system_installed {
		if installed && os.remove(paths.system[index]) != nil {
			transaction.state = .Rollback_Failed
			return false
		}
	}
	if !bootstrap_recovery_marker_remove(&paths) {
		transaction.state = .Rollback_Failed
		return false
	}
	transaction.state = .Rolled_Back
	return true
}

@(private)
bootstrap_fingerprint :: proc(data: []u8) -> Bootstrap_Fingerprint {
	crc := u32(0xffff_ffff)
	for byte in data {
		crc ~= u32(byte)
		for _ in 0 ..< 8 {
			mask := u32(0) - (crc & 1)
			crc = (crc >> 1) ~ (0xedb8_8320 & mask)
		}
	}
	return {size = u64(len(data)), crc = crc ~ 0xffff_ffff}
}

@(private)
bootstrap_fingerprint_string :: proc(data: string) -> Bootstrap_Fingerprint {
	return bootstrap_fingerprint(transmute([]u8)data)
}

@(private)
bootstrap_file_matches :: proc(path: string, expected: Bootstrap_Fingerprint) -> bool {
	data, read_error := os.read_entire_file(path, context.temp_allocator)
	if read_error != nil {return false}
	defer delete(data, context.temp_allocator)
	return bootstrap_fingerprint(data) == expected
}

@(private)
bootstrap_msdos_placeholder :: proc(data: []u8) -> bool {
	contents := string(data)
	return contents == "; \r\n" || contents == ";\r\n" || contents == "; \n" || contents == ";\n"
}

@(private)
bootstrap_extract_fat12 :: proc(
	path: string,
) -> (
	files: Bootstrap_Files,
	diagnostic: Bootstrap_Diagnostic,
) {
	info, stat_error := os.stat(path, context.temp_allocator)
	if stat_error != nil {return {}, .Boot_Image_Open_Failed}
	defer os.file_info_delete(info, context.temp_allocator)
	if info.type != .Regular || info.size < 512 || info.size > BOOTSTRAP_IMAGE_MAX_BYTES {
		return {}, .Boot_Image_Invalid
	}
	image, read_error := os.read_entire_file(path, context.allocator)
	if read_error != nil {return {}, .Boot_Image_Open_Failed}
	defer delete(image)

	bps := int(bootstrap_rd16(image, 11))
	sectors_per_cluster := int(image[13])
	reserved := int(bootstrap_rd16(image, 14))
	fat_count := int(image[16])
	root_entries := int(bootstrap_rd16(image, 17))
	total_sectors := int(bootstrap_rd16(image, 19))
	if total_sectors == 0 {total_sectors = int(bootstrap_rd32(image, 32))}
	sectors_per_fat := int(bootstrap_rd16(image, 22))
	if bps != 512 ||
	   sectors_per_cluster <= 0 ||
	   (sectors_per_cluster & (sectors_per_cluster - 1)) != 0 ||
	   reserved <= 0 ||
	   fat_count <= 0 ||
	   root_entries <= 0 ||
	   total_sectors <= 0 ||
	   sectors_per_fat <= 0 ||
	   image[510] != 0x55 ||
	   image[511] != 0xaa {
		return {}, .Boot_Image_Invalid
	}
	image_bytes := u64(total_sectors) * u64(bps)
	if image_bytes > u64(len(image)) {return {}, .Boot_Image_Invalid}
	root_sectors := (root_entries * 32 + bps - 1) / bps
	first_root_sector := reserved + fat_count * sectors_per_fat
	first_data_sector := first_root_sector + root_sectors
	if first_data_sector >= total_sectors {return {}, .Boot_Image_Invalid}
	cluster_count := (total_sectors - first_data_sector) / sectors_per_cluster
	if cluster_count <= 0 || cluster_count >= 4085 {return {}, .Boot_Image_Invalid}
	fat_offset := reserved * bps
	fat_bytes := sectors_per_fat * bps
	if fat_offset + fat_bytes > len(image) ||
	   fat_bytes < 3 ||
	   image[fat_offset] != image[21] ||
	   image[fat_offset + 1] != 0xff ||
	   image[fat_offset + 2] != 0xff {
		return {}, .Boot_Image_Invalid
	}
	root_offset := first_root_sector * bps
	root_bytes := root_entries * 32
	if root_offset + root_bytes > len(image) {return {}, .Boot_Image_Invalid}

	found: [3]bool
	for entry_index in 0 ..< root_entries {
		offset := root_offset + entry_index * 32
		first := image[offset]
		if first == 0 {break}
		if first == 0xe5 {continue}
		attributes := image[offset + 11]
		if (attributes & 0x0f) == 0x0f || (attributes & 0x18) != 0 {continue}
		name := string(image[offset:offset + 11])
		for wanted, file_index in BOOTSTRAP_FAT_NAMES {
			if name != wanted {continue}
			if found[file_index] {
				bootstrap_files_destroy(&files)
				return {}, .Boot_Image_Invalid
			}
			first_cluster := int(bootstrap_rd16(image, offset + 26))
			size := int(bootstrap_rd32(image, offset + 28))
			data, ok := bootstrap_fat12_file(
				image,
				fat_offset,
				fat_bytes,
				first_data_sector,
				sectors_per_cluster,
				cluster_count,
				first_cluster,
				size,
			)
			if !ok {
				bootstrap_files_destroy(&files)
				return {}, .Boot_Image_Invalid
			}
			files.data[file_index] = data
			found[file_index] = true
		}
	}
	for present in found {
		if !present {
			bootstrap_files_destroy(&files)
			return {}, .Boot_Image_Invalid
		}
	}
	return files, .None
}

@(private)
bootstrap_fat12_file :: proc(
	image: []u8,
	fat_offset, fat_bytes, first_data_sector, sectors_per_cluster, cluster_count: int,
	first_cluster, size: int,
) -> (
	[]u8,
	bool,
) {
	if size <= 0 || first_cluster < 2 || first_cluster >= cluster_count + 2 {return nil, false}
	data := make([]u8, size)
	visited := make([]bool, cluster_count + 2, context.temp_allocator)
	defer delete(visited, context.temp_allocator)
	cluster := first_cluster
	written := 0
	cluster_bytes := sectors_per_cluster * 512
	for written < size {
		if cluster < 2 || cluster >= cluster_count + 2 || visited[cluster] {
			delete(data)
			return nil, false
		}
		visited[cluster] = true
		data_sector := first_data_sector + (cluster - 2) * sectors_per_cluster
		offset := data_sector * 512
		amount := min(cluster_bytes, size - written)
		if offset < 0 || offset + amount > len(image) {
			delete(data)
			return nil, false
		}
		copy(data[written:written + amount], image[offset:offset + amount])
		written += amount
		next, ok := bootstrap_fat12_next(image, fat_offset, fat_bytes, cluster)
		if !ok {
			delete(data)
			return nil, false
		}
		if written == size {
			if next < 0xff8 {
				delete(data)
				return nil, false
			}
			break
		}
		if next >= 0xff8 {
			delete(data)
			return nil, false
		}
		cluster = next
	}
	return data, true
}

@(private)
bootstrap_fat12_next :: proc(image: []u8, fat_offset, fat_bytes, cluster: int) -> (int, bool) {
	entry_offset := cluster + cluster / 2
	if entry_offset < 0 ||
	   entry_offset + 1 >= fat_bytes ||
	   fat_offset + entry_offset + 1 >= len(image) {
		return 0, false
	}
	value := int(bootstrap_rd16(image, fat_offset + entry_offset))
	if (cluster & 1) != 0 {value >>= 4} else {value &= 0x0fff}
	if value == 0 || value == 1 || value == 0xff7 {return 0, false}
	return value, true
}

@(private)
bootstrap_rd16 :: proc(data: []u8, offset: int) -> u16 {
	if offset < 0 || offset + 2 > len(data) {return 0}
	return u16(data[offset]) | u16(data[offset + 1]) << 8
}

@(private)
bootstrap_rd32 :: proc(data: []u8, offset: int) -> u32 {
	if offset < 0 || offset + 4 > len(data) {return 0}
	return(
		u32(data[offset]) |
		u32(data[offset + 1]) << 8 |
		u32(data[offset + 2]) << 16 |
		u32(data[offset + 3]) << 24 \
	)
}
