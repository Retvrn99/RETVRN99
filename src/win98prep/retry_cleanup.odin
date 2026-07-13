// SPDX-License-Identifier: GPL-3.0-only
package win98prep

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

Retry_Cleanup_Diagnostic :: enum {
	None,
	C_Drive_Read_Failed,
	Windows_Inspection_Failed,
	Existing_Windows,
	Path_Failed,
	Recovery_Create_Failed,
	Archive_Create_Failed,
	Move_Failed,
	Commit_Failed,
	Rollback_Failed,
}

Retry_Cleanup_Report :: struct {
	diagnostic:     Retry_Cleanup_Diagnostic,
	found_count:    int,
	archived_count: int,
	archive_path:   string,
}

retry_cleanup_report_destroy :: proc(
	report: ^Retry_Cleanup_Report,
	allocator := context.allocator,
) {
	if report == nil {return}
	delete(report.archive_path, allocator)
	report^ = {}
}

retry_cleanup_archive :: proc(c_drive, install_root: string) -> Retry_Cleanup_Report {
	return retry_cleanup_archive_with_rename(c_drive, install_root, os.rename)
}

retry_cleanup_restore :: proc(report: ^Retry_Cleanup_Report, c_drive: string) -> bool {
	if report == nil || report.archived_count == 0 {return true}
	if !retry_cleanup_restore_with_rename(report, c_drive, os.rename) {return false}
	report.archived_count = 0
	delete(report.archive_path)
	report.archive_path = ""
	return true
}

@(private)
Retry_Cleanup_Rename_Proc :: #type proc(old_path, new_path: string) -> os.Error

@(private)
Retry_Cleanup_Artifact :: struct {
	name:        string,
	source_path: string,
}

@(private)
Retry_Cleanup_Move :: struct {
	source_path:      string,
	destination_path: string,
}

@(private)
retry_cleanup_restore_with_rename :: proc(
	report: ^Retry_Cleanup_Report,
	c_drive: string,
	rename_path: Retry_Cleanup_Rename_Proc,
) -> bool {
	if report == nil || report.archive_path == "" || c_drive == "" {return false}
	archive_infos, archive_error := os.read_all_directory_by_path(
		report.archive_path,
		context.temp_allocator,
	)
	if archive_error != nil {return false}
	defer os.file_info_slice_delete(archive_infos, context.temp_allocator)
	if len(archive_infos) != report.archived_count {return false}

	moves := make([dynamic]Retry_Cleanup_Move, context.temp_allocator)
	for &info in archive_infos {
		if !retry_cleanup_artifact(info.name, info.type) {return false}
		destination, destination_error := filepath.join(
			{c_drive, info.name},
			context.temp_allocator,
		)
		if destination_error != nil || os.exists(destination) {return false}
		append(&moves, Retry_Cleanup_Move{info.fullpath, destination})
	}
	slice.sort_by(moves[:], proc(a, b: Retry_Cleanup_Move) -> bool {
		return a.source_path < b.source_path
	})

	moved := 0
	for &move in moves {
		if rename_path(move.source_path, move.destination_path) != nil {
			_ = retry_cleanup_rollback(moves[:moved], rename_path)
			return false
		}
		moved += 1
	}
	if os.remove(report.archive_path) != nil {
		_ = retry_cleanup_rollback(moves[:moved], rename_path)
		return false
	}
	_ = os.remove(filepath.dir(report.archive_path))
	return true
}

@(private)
retry_cleanup_archive_with_rename :: proc(
	c_drive, install_root: string,
	rename_path: Retry_Cleanup_Rename_Proc,
) -> Retry_Cleanup_Report {
	report: Retry_Cleanup_Report
	root_infos, root_error := os.read_all_directory_by_path(c_drive, context.temp_allocator)
	if root_error != nil {
		report.diagnostic = .C_Drive_Read_Failed
		return report
	}
	defer os.file_info_slice_delete(root_infos, context.temp_allocator)

	installed, inspected := retry_cleanup_windows_installed(root_infos)
	if !inspected {
		report.diagnostic = .Windows_Inspection_Failed
		return report
	}
	if installed {
		report.diagnostic = .Existing_Windows
		return report
	}

	artifacts := make([dynamic]Retry_Cleanup_Artifact, context.temp_allocator)
	for &info in root_infos {
		if !retry_cleanup_artifact(info.name, info.type) {continue}
		append(&artifacts, Retry_Cleanup_Artifact{info.name, info.fullpath})
	}
	slice.sort_by(artifacts[:], retry_cleanup_artifact_less)
	report.found_count = len(artifacts)
	if len(artifacts) == 0 {return report}

	recovery_root, path_error := filepath.join({install_root, "recovery"}, context.temp_allocator)
	if path_error != nil {
		report.diagnostic = .Path_Failed
		return report
	}
	if os.make_directory_all(recovery_root) != nil {
		report.diagnostic = .Recovery_Create_Failed
		return report
	}

	staging_path, final_path, reserved := retry_cleanup_reserve_archive(recovery_root)
	if !reserved {
		report.diagnostic = .Archive_Create_Failed
		return report
	}

	moves := make([dynamic]Retry_Cleanup_Move, context.temp_allocator)
	for artifact in artifacts {
		destination, destination_error := filepath.join(
			{staging_path, artifact.name},
			context.temp_allocator,
		)
		if destination_error != nil {
			_ = os.remove(staging_path)
			report.diagnostic = .Path_Failed
			return report
		}
		append(&moves, Retry_Cleanup_Move{artifact.source_path, destination})
	}

	moved := 0
	for &move in moves {
		if rename_path(move.source_path, move.destination_path) != nil {
			stranded := retry_cleanup_rollback(moves[:moved], rename_path)
			if stranded > 0 {
				report.diagnostic = .Rollback_Failed
				report.archived_count = stranded
				report.archive_path = strings.clone(staging_path)
				return report
			}
			_ = os.remove(staging_path)
			report.diagnostic = .Move_Failed
			return report
		}
		moved += 1
	}

	if rename_path(staging_path, final_path) != nil {
		stranded := retry_cleanup_rollback(moves[:moved], rename_path)
		if stranded > 0 {
			report.diagnostic = .Rollback_Failed
			report.archived_count = stranded
			report.archive_path = strings.clone(staging_path)
			return report
		}
		_ = os.remove(staging_path)
		report.diagnostic = .Commit_Failed
		return report
	}

	report.archived_count = len(moves)
	report.archive_path = strings.clone(final_path)
	return report
}

@(private)
retry_cleanup_windows_installed :: proc(
	root_infos: []os.File_Info,
) -> (
	installed, inspected: bool,
) {
	for &info in root_infos {
		if info.type != .Directory || retry_cleanup_wininst_name(info.name) {continue}
		windir_infos, windir_error := os.read_all_directory_by_path(
			info.fullpath,
			context.temp_allocator,
		)
		if windir_error != nil {return false, false}
		markers: Retry_Cleanup_Windows_Markers
		for &windir_info in windir_infos {
			if windir_info.type == .Regular && windir_info.size > 0 {
				switch {
				case strings.equal_fold(windir_info.name, "WIN.COM"):
					markers.win_com = true
				case strings.equal_fold(windir_info.name, "SYSTEM.DAT"):
					markers.system_dat = true
				case strings.equal_fold(windir_info.name, "USER.DAT"):
					markers.user_dat = true
				}
			}
			if !strings.equal_fold(windir_info.name, "SYSTEM") || windir_info.type != .Directory {
				continue
			}
			system_infos, system_error := os.read_all_directory_by_path(
				windir_info.fullpath,
				context.temp_allocator,
			)
			if system_error != nil {
				os.file_info_slice_delete(windir_infos, context.temp_allocator)
				return false, false
			}
			for &system_info in system_infos {
				if system_info.type == .Regular &&
				   system_info.size > 0 &&
				   strings.equal_fold(system_info.name, "VMM32.VXD") {
					markers.vmm32_vxd = true
					break
				}
			}
			os.file_info_slice_delete(system_infos, context.temp_allocator)
		}
		os.file_info_slice_delete(windir_infos, context.temp_allocator)
		if retry_cleanup_windows_marker_count(markers) >= 2 {return true, true}
	}
	return false, true
}

@(private)
Retry_Cleanup_Windows_Markers :: struct {
	win_com:    bool,
	system_dat: bool,
	user_dat:   bool,
	vmm32_vxd:  bool,
}

@(private)
retry_cleanup_windows_marker_count :: proc(markers: Retry_Cleanup_Windows_Markers) -> int {
	count := 0
	if markers.win_com {count += 1}
	if markers.system_dat {count += 1}
	if markers.user_dat {count += 1}
	if markers.vmm32_vxd {count += 1}
	return count
}

@(private)
retry_cleanup_artifact :: proc(name: string, file_type: os.File_Type) -> bool {
	if file_type == .Directory {return retry_cleanup_wininst_name(name)}
	if file_type != .Regular {return false}
	for candidate in RETRY_CLEANUP_FILES {
		if strings.equal_fold(name, candidate) {return true}
	}
	return false
}

@(private)
RETRY_CLEANUP_FILES :: [?]string {
	"SYSTEM.NEW",
	"USER.NEW",
	"SETUPLOG.TXT",
	"SETUPLOG.OLD",
	"NETLOG.TXT",
	"DETLOG.TXT",
	"DETCRASH.LOG",
	"BOOTLOG.TXT",
	"BOOTLOG.PRV",
	"SUHDLOG.DAT",
	"WINBOOT.INI",
	"WINBOOT.SYS",
	"WINBOOT.~!~",
	"AUTOEXEC.WIN",
	"CONFIG.WIN",
}

@(private)
retry_cleanup_wininst_name :: proc(name: string) -> bool {
	if len(name) < len("WININST0.000") || !strings.equal_fold(name[:7], "WININST") {
		return false
	}
	dot := len(name) - 4
	if dot <= 7 || name[dot] != '.' {return false}
	for byte in transmute([]u8)name[7:dot] {
		if byte < '0' || byte > '9' {return false}
	}
	for byte in transmute([]u8)name[dot + 1:] {
		if byte < '0' || byte > '9' {return false}
	}
	return true
}

@(private)
retry_cleanup_artifact_less :: proc(a, b: Retry_Cleanup_Artifact) -> bool {
	return a.name < b.name
}

@(private)
retry_cleanup_reserve_archive :: proc(
	recovery_root: string,
) -> (
	staging_path, final_path: string,
	ok: bool,
) {
	for slot in 1 ..= 999999 {
		base := fmt.tprintf("retry-%06d", slot)
		final, final_error := filepath.join({recovery_root, base}, context.temp_allocator)
		if final_error != nil {return "", "", false}
		staging_name := fmt.tprintf("%s.next", base)
		staging, staging_error := filepath.join(
			{recovery_root, staging_name},
			context.temp_allocator,
		)
		if staging_error != nil {return "", "", false}
		if os.exists(final) || os.exists(staging) {continue}
		if directory_error := os.make_directory(staging); directory_error != nil {
			if directory_error == os.General_Error.Exist {continue}
			return "", "", false
		}
		return staging, final, true
	}
	return "", "", false
}

@(private)
retry_cleanup_rollback :: proc(
	moves: []Retry_Cleanup_Move,
	rename_path: Retry_Cleanup_Rename_Proc,
) -> (
	stranded: int,
) {
	for index := len(moves) - 1; index >= 0; index -= 1 {
		move := &moves[index]
		if rename_path(move.destination_path, move.source_path) != nil {stranded += 1}
	}
	return
}
