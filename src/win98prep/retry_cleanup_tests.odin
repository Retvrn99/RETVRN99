// SPDX-License-Identifier: GPL-3.0-only
package win98prep

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
test_retry_cleanup_archives_only_setup_artifacts :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := retry_cleanup_test_directory(t)
	defer os.remove_all(root)
	c_drive, install_root := retry_cleanup_test_roots(t, root)

	retry_cleanup_test_write(t, c_drive, "system.new", "system registry")
	retry_cleanup_test_write(t, c_drive, "USER.NEW", "user registry")
	retry_cleanup_test_write(t, c_drive, "SETUPLOG.TXT", "setup log")
	retry_cleanup_test_write(t, c_drive, "CONFIG.WIN", "config copy")
	retry_cleanup_test_write(t, c_drive, "SAVES.DAT", "user data")
	retry_cleanup_test_write(t, c_drive, "AUTOEXEC.BAT", "user boot file")

	windows_system := retry_cleanup_test_join(t, c_drive, "WINDOWS", "SYSTEM")
	testing.expect(t, os.make_directory_all(windows_system) == nil)
	program_files := retry_cleanup_test_join(t, c_drive, "ARCHIV~1")
	testing.expect(t, os.make_directory(program_files) == nil)
	wininst := retry_cleanup_test_join(t, c_drive, "WinInst12.401")
	testing.expect(t, os.make_directory(wininst) == nil)
	retry_cleanup_test_write(t, wininst, "PAYLOAD.BIN", "temporary setup payload")
	retry_cleanup_test_write(t, wininst, "WIN.COM", "setup scratch")
	retry_cleanup_test_write(t, wininst, "SYSTEM.DAT", "setup scratch registry")
	invalid_wininst := retry_cleanup_test_join(t, c_drive, "WININST.400")
	testing.expect(t, os.make_directory(invalid_wininst) == nil)

	report := retry_cleanup_archive(c_drive, install_root)
	defer retry_cleanup_report_destroy(&report)
	testing.expect_value(t, report.diagnostic, Retry_Cleanup_Diagnostic.None)
	testing.expect_value(t, report.found_count, 5)
	testing.expect_value(t, report.archived_count, 5)
	testing.expect(t, report.archive_path != "")

	retry_cleanup_test_expect_file(t, report.archive_path, "system.new", "system registry")
	retry_cleanup_test_expect_file(t, report.archive_path, "USER.NEW", "user registry")
	retry_cleanup_test_expect_file(t, report.archive_path, "SETUPLOG.TXT", "setup log")
	retry_cleanup_test_expect_file(t, report.archive_path, "CONFIG.WIN", "config copy")
	archived_payload := retry_cleanup_test_join(
		t,
		report.archive_path,
		"WinInst12.401",
		"PAYLOAD.BIN",
	)
	retry_cleanup_test_expect_contents(t, archived_payload, "temporary setup payload")

	testing.expect(t, os.exists(windows_system))
	testing.expect(t, os.exists(program_files))
	testing.expect(t, os.exists(invalid_wininst))
	retry_cleanup_test_expect_file(t, c_drive, "SAVES.DAT", "user data")
	retry_cleanup_test_expect_file(t, c_drive, "AUTOEXEC.BAT", "user boot file")
}

@(test)
test_retry_cleanup_refuses_existing_windows :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := retry_cleanup_test_directory(t)
	defer os.remove_all(root)
	c_drive, install_root := retry_cleanup_test_roots(t, root)
	windows := retry_cleanup_test_join(t, c_drive, "Windows")
	testing.expect(t, os.make_directory(windows) == nil)
	retry_cleanup_test_write(t, windows, "win.com", "installed")
	retry_cleanup_test_write(t, windows, "system.dat", "registry")
	retry_cleanup_test_write(t, c_drive, "SYSTEM.NEW", "must remain")

	report := retry_cleanup_archive(c_drive, install_root)
	defer retry_cleanup_report_destroy(&report)
	testing.expect_value(t, report.diagnostic, Retry_Cleanup_Diagnostic.Existing_Windows)
	testing.expect_value(t, report.found_count, 0)
	testing.expect_value(t, report.archived_count, 0)
	retry_cleanup_test_expect_file(t, c_drive, "SYSTEM.NEW", "must remain")
	recovery := retry_cleanup_test_join(t, install_root, "recovery")
	testing.expect(t, !os.exists(recovery))
}

@(test)
test_retry_cleanup_refuses_custom_win98_directory :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := retry_cleanup_test_directory(t)
	defer os.remove_all(root)
	c_drive, install_root := retry_cleanup_test_roots(t, root)
	win98 := retry_cleanup_test_join(t, c_drive, "WIN98")
	testing.expect(t, os.make_directory(win98) == nil)
	retry_cleanup_test_write(t, win98, "WIN.COM", "installed")
	retry_cleanup_test_write(t, win98, "SYSTEM.DAT", "registry")
	retry_cleanup_test_write(t, c_drive, "SYSTEM.NEW", "must remain")

	report := retry_cleanup_archive(c_drive, install_root)
	defer retry_cleanup_report_destroy(&report)
	testing.expect_value(t, report.diagnostic, Retry_Cleanup_Diagnostic.Existing_Windows)
	testing.expect_value(t, report.found_count, 0)
	testing.expect_value(t, report.archived_count, 0)
	retry_cleanup_test_expect_file(t, c_drive, "SYSTEM.NEW", "must remain")
	recovery := retry_cleanup_test_join(t, install_root, "recovery")
	testing.expect(t, !os.exists(recovery))
}

@(test)
test_retry_cleanup_recognizes_vmm32_as_installed_windows :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := retry_cleanup_test_directory(t)
	defer os.remove_all(root)
	c_drive, install_root := retry_cleanup_test_roots(t, root)
	system := retry_cleanup_test_join(t, c_drive, "WINDOWS", "SYSTEM")
	testing.expect(t, os.make_directory_all(system) == nil)
	retry_cleanup_test_write(t, system, "VMM32.VXD", "installed")
	windows := retry_cleanup_test_join(t, c_drive, "WINDOWS")
	retry_cleanup_test_write(t, windows, "WIN.COM", "installed")
	retry_cleanup_test_write(t, c_drive, "USER.NEW", "must remain")

	report := retry_cleanup_archive(c_drive, install_root)
	defer retry_cleanup_report_destroy(&report)
	testing.expect_value(t, report.diagnostic, Retry_Cleanup_Diagnostic.Existing_Windows)
	retry_cleanup_test_expect_file(t, c_drive, "USER.NEW", "must remain")
}

@(test)
test_retry_cleanup_single_marker_is_not_an_installation :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := retry_cleanup_test_directory(t)
	defer os.remove_all(root)
	c_drive, install_root := retry_cleanup_test_roots(t, root)
	tools := retry_cleanup_test_join(t, c_drive, "TOOLS")
	testing.expect(t, os.make_directory(tools) == nil)
	retry_cleanup_test_write(t, tools, "WIN.COM", "unrelated tool")
	retry_cleanup_test_write(t, tools, "SYSTEM.DAT", "")
	retry_cleanup_test_write(t, c_drive, "SYSTEM.NEW", "archive me")

	report := retry_cleanup_archive(c_drive, install_root)
	defer retry_cleanup_report_destroy(&report)
	testing.expect_value(t, report.diagnostic, Retry_Cleanup_Diagnostic.None)
	testing.expect_value(t, report.archived_count, 1)
	retry_cleanup_test_expect_file(t, report.archive_path, "SYSTEM.NEW", "archive me")
	retry_cleanup_test_expect_file(t, tools, "WIN.COM", "unrelated tool")
}

@(test)
test_retry_cleanup_unreadable_windir_is_an_inspection_failure :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := retry_cleanup_test_directory(t)
	defer os.remove_all(root)
	missing := retry_cleanup_test_join(t, root, "WIN98")
	infos := []os.File_Info{{name = "WIN98", fullpath = missing, type = .Directory}}

	installed, inspected := retry_cleanup_windows_installed(infos)
	testing.expect(t, !installed)
	testing.expect(t, !inspected)
}

@(test)
test_retry_cleanup_without_artifacts_creates_no_archive :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := retry_cleanup_test_directory(t)
	defer os.remove_all(root)
	c_drive, install_root := retry_cleanup_test_roots(t, root)
	retry_cleanup_test_write(t, c_drive, "README.TXT", "keep")

	report := retry_cleanup_archive(c_drive, install_root)
	defer retry_cleanup_report_destroy(&report)
	testing.expect_value(t, report.diagnostic, Retry_Cleanup_Diagnostic.None)
	testing.expect_value(t, report.found_count, 0)
	testing.expect_value(t, report.archived_count, 0)
	testing.expect_value(t, report.archive_path, "")
	recovery := retry_cleanup_test_join(t, install_root, "recovery")
	testing.expect(t, !os.exists(recovery))
}

@(test)
test_retry_cleanup_ignores_wrong_artifact_types :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := retry_cleanup_test_directory(t)
	defer os.remove_all(root)
	c_drive, install_root := retry_cleanup_test_roots(t, root)
	system_new := retry_cleanup_test_join(t, c_drive, "SYSTEM.NEW")
	testing.expect(t, os.make_directory(system_new) == nil)
	retry_cleanup_test_write(t, c_drive, "WININST0.400", "not a setup directory")

	report := retry_cleanup_archive(c_drive, install_root)
	defer retry_cleanup_report_destroy(&report)
	testing.expect_value(t, report.diagnostic, Retry_Cleanup_Diagnostic.None)
	testing.expect_value(t, report.found_count, 0)
	testing.expect(t, os.exists(system_new))
	retry_cleanup_test_expect_file(t, c_drive, "WININST0.400", "not a setup directory")
}

@(test)
test_retry_cleanup_never_replaces_an_archive :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := retry_cleanup_test_directory(t)
	defer os.remove_all(root)
	c_drive, install_root := retry_cleanup_test_roots(t, root)
	first := retry_cleanup_test_join(t, install_root, "recovery", "retry-000001")
	testing.expect(t, os.make_directory_all(first) == nil)
	retry_cleanup_test_write(t, first, "KEEP.TXT", "first archive")
	retry_cleanup_test_write(t, c_drive, "SYSTEM.NEW", "next archive")

	report := retry_cleanup_archive(c_drive, install_root)
	defer retry_cleanup_report_destroy(&report)
	testing.expect_value(t, report.diagnostic, Retry_Cleanup_Diagnostic.None)
	testing.expect(t, strings.has_suffix(report.archive_path, "retry-000002"))
	retry_cleanup_test_expect_file(t, first, "KEEP.TXT", "first archive")
	retry_cleanup_test_expect_file(t, report.archive_path, "SYSTEM.NEW", "next archive")
}

@(test)
test_retry_cleanup_rolls_back_a_commit_failure :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := retry_cleanup_test_directory(t)
	defer os.remove_all(root)
	c_drive, install_root := retry_cleanup_test_roots(t, root)
	retry_cleanup_test_write(t, c_drive, "SYSTEM.NEW", "restore me")

	report := retry_cleanup_archive_with_rename(
		c_drive,
		install_root,
		retry_cleanup_test_fail_commit,
	)
	defer retry_cleanup_report_destroy(&report)
	testing.expect_value(t, report.diagnostic, Retry_Cleanup_Diagnostic.Commit_Failed)
	testing.expect_value(t, report.archived_count, 0)
	testing.expect_value(t, report.archive_path, "")
	retry_cleanup_test_expect_file(t, c_drive, "SYSTEM.NEW", "restore me")
}

@(test)
test_retry_cleanup_rolls_back_a_move_failure :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := retry_cleanup_test_directory(t)
	defer os.remove_all(root)
	c_drive, install_root := retry_cleanup_test_roots(t, root)
	retry_cleanup_test_write(t, c_drive, "SYSTEM.NEW", "first")
	retry_cleanup_test_write(t, c_drive, "USER.NEW", "second")

	report := retry_cleanup_archive_with_rename(
		c_drive,
		install_root,
		retry_cleanup_test_fail_user_move,
	)
	defer retry_cleanup_report_destroy(&report)
	testing.expect_value(t, report.diagnostic, Retry_Cleanup_Diagnostic.Move_Failed)
	testing.expect_value(t, report.archived_count, 0)
	testing.expect_value(t, report.archive_path, "")
	retry_cleanup_test_expect_file(t, c_drive, "SYSTEM.NEW", "first")
	retry_cleanup_test_expect_file(t, c_drive, "USER.NEW", "second")
}

@(test)
test_retry_cleanup_keeps_a_failed_rollback_recoverable :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := retry_cleanup_test_directory(t)
	defer os.remove_all(root)
	c_drive, install_root := retry_cleanup_test_roots(t, root)
	retry_cleanup_test_write(t, c_drive, "SYSTEM.NEW", "first")
	retry_cleanup_test_write(t, c_drive, "USER.NEW", "second")

	report := retry_cleanup_archive_with_rename(
		c_drive,
		install_root,
		retry_cleanup_test_fail_move_and_rollback,
	)
	defer retry_cleanup_report_destroy(&report)
	testing.expect_value(t, report.diagnostic, Retry_Cleanup_Diagnostic.Rollback_Failed)
	testing.expect_value(t, report.archived_count, 1)
	testing.expect(t, report.archive_path != "")
	retry_cleanup_test_expect_file(t, report.archive_path, "SYSTEM.NEW", "first")
	retry_cleanup_test_expect_file(t, c_drive, "USER.NEW", "second")
}

@(private)
retry_cleanup_test_fail_commit :: proc(old_path, new_path: string) -> os.Error {
	if strings.has_suffix(old_path, ".next") {return os.General_Error.Invalid_Path}
	return os.rename(old_path, new_path)
}

@(private)
retry_cleanup_test_fail_user_move :: proc(old_path, new_path: string) -> os.Error {
	if strings.equal_fold(filepath.base(old_path), "USER.NEW") &&
	   !strings.contains(old_path, ".next") {
		return os.General_Error.Invalid_Path
	}
	return os.rename(old_path, new_path)
}

@(private)
retry_cleanup_test_fail_move_and_rollback :: proc(old_path, new_path: string) -> os.Error {
	name := filepath.base(old_path)
	if strings.equal_fold(name, "USER.NEW") && !strings.contains(old_path, ".next") {
		return os.General_Error.Invalid_Path
	}
	if strings.equal_fold(name, "SYSTEM.NEW") && strings.contains(old_path, ".next") {
		return os.General_Error.Invalid_Path
	}
	return os.rename(old_path, new_path)
}

@(private)
retry_cleanup_test_directory :: proc(t: ^testing.T) -> string {
	base, base_error := os.temp_directory(context.allocator)
	testing.expect(t, base_error == nil)
	dir, dir_error := os.make_directory_temp(base, "retvrn99_retry_cleanup_*", context.allocator)
	testing.expect(t, dir_error == nil)
	return dir
}

@(private)
retry_cleanup_test_roots :: proc(t: ^testing.T, root: string) -> (c_drive, install_root: string) {
	c_drive = retry_cleanup_test_join(t, root, "c_drive")
	install_root = retry_cleanup_test_join(t, root, "install")
	testing.expect(t, os.make_directory(c_drive) == nil)
	return
}

@(private)
retry_cleanup_test_join :: proc(t: ^testing.T, parts: ..string) -> string {
	path, path_error := filepath.join(parts, context.allocator)
	testing.expect(t, path_error == nil)
	return path
}

@(private)
retry_cleanup_test_write :: proc(t: ^testing.T, directory, name, contents: string) {
	path := retry_cleanup_test_join(t, directory, name)
	testing.expect(t, os.write_entire_file(path, contents) == nil)
}

@(private)
retry_cleanup_test_expect_file :: proc(t: ^testing.T, directory, name, contents: string) {
	path := retry_cleanup_test_join(t, directory, name)
	retry_cleanup_test_expect_contents(t, path, contents)
}

@(private)
retry_cleanup_test_expect_contents :: proc(t: ^testing.T, path, expected: string) {
	data, read_error := os.read_entire_file(path, context.allocator)
	testing.expect(t, read_error == nil)
	if read_error != nil {return}
	defer delete(data)
	testing.expect_value(t, string(data), expected)
}
