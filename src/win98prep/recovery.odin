// SPDX-License-Identifier: GPL-3.0-only
package win98prep

import "core:os"

prepare_recover :: proc(install_root, c_drive: string) -> bool {
	return prepare_recover_mode(install_root, c_drive, false)
}

prepare_recover_interrupted :: proc(install_root, c_drive: string) -> bool {
	return prepare_recover_mode(install_root, c_drive, true)
}

@(private)
prepare_recover_mode :: proc(install_root, c_drive: string, interrupted: bool) -> bool {
	if install_root == "" || c_drive == "" {return false}
	transaction := Preparation_Transaction {
		install_root = install_root,
		c_drive      = c_drive,
	}
	paths, paths_ok := preparation_paths(&transaction)
	if !paths_ok {return false}
	if !preparation_generations_owned(&paths) {return false}
	bootstrap_ok := false
	if interrupted {
		bootstrap_ok = bootstrap_recover_interrupted(c_drive)
	} else {
		bootstrap_ok = bootstrap_recover(c_drive)
	}
	if !bootstrap_ok {return false}
	if !owned_generation_recover(
		paths.launcher_next,
		paths.launcher_final,
		paths.launcher_backup,
		.Launcher,
	) {
		return false
	}
	if !owned_generation_recover(
		paths.payload_next,
		paths.payload_final,
		paths.payload_backup,
		.Payload,
	) {
		return false
	}
	return scratch_generation_recover(
		paths.scratch_next,
		paths.scratch_final,
		paths.scratch_backup,
	)
}

@(private)
preparation_generations_owned :: proc(paths: ^Preparation_Paths) -> bool {
	if paths == nil {return false}
	payload := [?]string{paths.payload_next, paths.payload_final, paths.payload_backup}
	for path in payload {
		if os.exists(path) && !owned_path(path, .Payload) {return false}
	}
	launcher := [?]string{paths.launcher_next, paths.launcher_final, paths.launcher_backup}
	for path in launcher {
		if os.exists(path) && !owned_path(path, .Launcher) {return false}
	}
	return true
}

@(private)
owned_generation_recover :: proc(next, current, backup: string, kind: Owned_Path_Kind) -> bool {
	if !os.exists(backup) {return remove_owned_path(next, kind)}

	if os.exists(current) {
		if os.exists(next) && !remove_owned_path(next, kind) {return false}
		if !rename_with_retry(current, next) {return false}
		if !rename_with_retry(backup, current) {
			_ = rename_with_retry(next, current)
			return false
		}
		return remove_owned_path(next, kind)
	}
	if !rename_with_retry(backup, current) {return false}
	return remove_owned_path(next, kind)
}

@(private)
scratch_generation_recover :: proc(next, current, backup: string) -> bool {
	if !os.exists(backup) {
		return !os.exists(next) || os.remove_all(next) == nil
	}
	if os.exists(current) {
		if os.exists(next) && os.remove_all(next) != nil {return false}
		if !rename_with_retry(current, next) {return false}
		if !rename_with_retry(backup, current) {
			_ = rename_with_retry(next, current)
			return false
		}
	} else if !rename_with_retry(backup, current) {
		return false
	}
	return !os.exists(next) || os.remove_all(next) == nil
}
