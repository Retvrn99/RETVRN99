// SPDX-License-Identifier: GPL-3.0-only
package win98prep

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
test_bootstrap_installs_fresh_dos_seed_and_one_shot_autoexec :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := bootstrap_test_directory(t)
	defer os.remove_all(root)
	c_drive, _ := filepath.join({root, "c_drive"})
	image_path, _ := filepath.join({root, "boot.img"})
	testing.expect(t, os.make_directory(c_drive) == nil)
	bootstrap_test_write_image(t, image_path, false)

	transaction, diagnostic := bootstrap_install(c_drive, image_path)
	testing.expect_value(t, diagnostic, Bootstrap_Diagnostic.None)
	testing.expect_value(t, transaction.state, Bootstrap_Transaction_State.Pending)
	testing.expect(t, !transaction.used_existing_dos)
	for installed in transaction.system_installed {testing.expect(t, installed)}
	testing.expect(t, transaction.autoexec_installed)
	testing.expect(t, !transaction.autoexec_backed_up)

	io := bootstrap_test_read(t, c_drive, "IO.SYS")
	defer delete(io)
	command := bootstrap_test_read(t, c_drive, "COMMAND.COM")
	defer delete(command)
	msdos := bootstrap_test_read(t, c_drive, "MSDOS.SYS")
	defer delete(msdos)
	autoexec := bootstrap_test_read(t, c_drive, "AUTOEXEC.BAT")
	defer delete(autoexec)
	testing.expect_value(t, len(io), 700)
	testing.expect_value(t, len(command), 600)
	testing.expect_value(t, io[0], u8(0x49))
	testing.expect_value(t, io[512], u8(0x69))
	testing.expect_value(t, command[0], u8(0x43))
	testing.expect_value(t, string(msdos), profile_seed_text_for_test())
	testing.expect_value(t, string(autoexec), BOOTSTRAP_AUTOEXEC)
	testing.expect(t, bootstrap_finish(&transaction, c_drive))
}

@(test)
test_bootstrap_existing_dos_preserves_system_files_and_backs_up_autoexec :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := bootstrap_test_directory(t)
	defer os.remove_all(root)
	c_drive, _ := filepath.join({root, "c_drive"})
	testing.expect(t, os.make_directory(c_drive) == nil)
	bootstrap_test_write(t, c_drive, "IO.SYS", "user io")
	bootstrap_test_write(t, c_drive, "MSDOS.SYS", "user msdos")
	bootstrap_test_write(t, c_drive, "COMMAND.COM", "user command")
	bootstrap_test_write(t, c_drive, "AUTOEXEC.BAT", "@ECHO USER\r\n")

	transaction, diagnostic := bootstrap_install(c_drive, "")
	testing.expect_value(t, diagnostic, Bootstrap_Diagnostic.Existing_DOS)
	testing.expect(t, transaction.used_existing_dos)
	for installed in transaction.system_installed {testing.expect(t, !installed)}
	testing.expect(t, transaction.autoexec_installed)
	testing.expect(t, transaction.autoexec_backed_up)
	backup := bootstrap_test_read(t, c_drive, BOOTSTRAP_AUTOEXEC_BACKUP_NAME)
	defer delete(backup)
	testing.expect_value(t, string(backup), "@ECHO USER\r\n")

	testing.expect(t, bootstrap_rollback(&transaction, c_drive))
	testing.expect_value(t, transaction.state, Bootstrap_Transaction_State.Rolled_Back)
	for name in BOOTSTRAP_SYSTEM_NAMES {
		contents := bootstrap_test_read(t, c_drive, name)
		delete(contents)
	}
	autoexec := bootstrap_test_read(t, c_drive, "AUTOEXEC.BAT")
	defer delete(autoexec)
	testing.expect_value(t, string(autoexec), "@ECHO USER\r\n")
	backup_path, _ := filepath.join({c_drive, BOOTSTRAP_AUTOEXEC_BACKUP_NAME})
	testing.expect(t, !os.exists(backup_path))
}

@(test)
test_bootstrap_partial_dos_fails_closed :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := bootstrap_test_directory(t)
	defer os.remove_all(root)
	c_drive, _ := filepath.join({root, "c_drive"})
	testing.expect(t, os.make_directory(c_drive) == nil)
	bootstrap_test_write(t, c_drive, "IO.SYS", "user io")
	bootstrap_test_write(t, c_drive, "AUTOEXEC.BAT", "user autoexec")

	transaction, diagnostic := bootstrap_install(c_drive, "missing.img")
	testing.expect_value(t, diagnostic, Bootstrap_Diagnostic.Partial_DOS)
	testing.expect_value(t, transaction.state, Bootstrap_Transaction_State.Inactive)
	io := bootstrap_test_read(t, c_drive, "IO.SYS")
	defer delete(io)
	autoexec := bootstrap_test_read(t, c_drive, "AUTOEXEC.BAT")
	defer delete(autoexec)
	testing.expect_value(t, string(io), "user io")
	testing.expect_value(t, string(autoexec), "user autoexec")
	command, _ := filepath.join({c_drive, "COMMAND.COM"})
	backup, _ := filepath.join({c_drive, BOOTSTRAP_AUTOEXEC_BACKUP_NAME})
	testing.expect(t, !os.exists(command))
	testing.expect(t, !os.exists(backup))
}

@(test)
test_bootstrap_fresh_profile_requires_user_boot_image :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := bootstrap_test_directory(t)
	defer os.remove_all(root)
	c_drive, _ := filepath.join({root, "c_drive"})
	testing.expect(t, os.make_directory(c_drive) == nil)
	transaction, diagnostic := bootstrap_install(c_drive, "")
	testing.expect_value(t, diagnostic, Bootstrap_Diagnostic.Boot_Image_Required)
	testing.expect_value(t, transaction.state, Bootstrap_Transaction_State.Inactive)
}

@(test)
test_bootstrap_rejects_malformed_fat_chain_without_writes :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := bootstrap_test_directory(t)
	defer os.remove_all(root)
	c_drive, _ := filepath.join({root, "c_drive"})
	image_path, _ := filepath.join({root, "bad.img"})
	testing.expect(t, os.make_directory(c_drive) == nil)
	bootstrap_test_write_image(t, image_path, true)
	transaction, diagnostic := bootstrap_install(c_drive, image_path)
	testing.expect_value(t, diagnostic, Bootstrap_Diagnostic.Boot_Image_Invalid)
	testing.expect_value(t, transaction.state, Bootstrap_Transaction_State.Inactive)
	entries, read_error := os.read_all_directory_by_path(c_drive, context.temp_allocator)
	defer {
		for info in entries {os.file_info_delete(info, context.temp_allocator)}
		delete(entries, context.temp_allocator)
	}
	testing.expect(t, read_error == nil)
	testing.expect_value(t, len(entries), 0)
}

@(test)
test_bootstrap_commit_failure_restores_autoexec_and_removes_seed :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := bootstrap_test_directory(t)
	defer os.remove_all(root)
	c_drive, _ := filepath.join({root, "c_drive"})
	image_path, _ := filepath.join({root, "boot.img"})
	testing.expect(t, os.make_directory(c_drive) == nil)
	bootstrap_test_write(t, c_drive, "AUTOEXEC.BAT", "@ECHO ORIGINAL\r\n")
	bootstrap_test_write_image(t, image_path, false)

	transaction, diagnostic := bootstrap_install_with_rename(
		c_drive,
		image_path,
		bootstrap_test_fail_command_commit,
	)
	testing.expect_value(t, diagnostic, Bootstrap_Diagnostic.Commit_Failed)
	testing.expect_value(t, transaction.state, Bootstrap_Transaction_State.Inactive)
	autoexec := bootstrap_test_read(t, c_drive, "AUTOEXEC.BAT")
	defer delete(autoexec)
	testing.expect_value(t, string(autoexec), "@ECHO ORIGINAL\r\n")
	for name in BOOTSTRAP_SYSTEM_NAMES {
		path, _ := filepath.join({c_drive, name})
		testing.expect(t, !os.exists(path))
	}
	backup, _ := filepath.join({c_drive, BOOTSTRAP_AUTOEXEC_BACKUP_NAME})
	testing.expect(t, !os.exists(backup))
}

@(test)
test_bootstrap_rollback_failure_retains_recovery_files :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := bootstrap_test_directory(t)
	defer os.remove_all(root)
	c_drive, _ := filepath.join({root, "c_drive"})
	image_path, _ := filepath.join({root, "boot.img"})
	testing.expect(t, os.make_directory(c_drive) == nil)
	bootstrap_test_write(t, c_drive, "AUTOEXEC.BAT", "@ECHO ORIGINAL\r\n")
	bootstrap_test_write_image(t, image_path, false)

	transaction, diagnostic := bootstrap_install_with_rename(
		c_drive,
		image_path,
		bootstrap_test_fail_command_and_autoexec_restore,
	)
	testing.expect_value(t, diagnostic, Bootstrap_Diagnostic.Rollback_Failed)
	testing.expect_value(t, transaction.state, Bootstrap_Transaction_State.Rollback_Failed)
	backup := bootstrap_test_read(t, c_drive, BOOTSTRAP_AUTOEXEC_BACKUP_NAME)
	defer delete(backup)
	testing.expect_value(t, string(backup), "@ECHO ORIGINAL\r\n")
	staging := bootstrap_test_read(t, c_drive, BOOTSTRAP_AUTOEXEC_STAGING_NAME)
	defer delete(staging)
	testing.expect_value(t, string(staging), BOOTSTRAP_AUTOEXEC)
	testing.expect(t, bootstrap_recover(c_drive))
	autoexec := bootstrap_test_read(t, c_drive, BOOTSTRAP_AUTOEXEC_NAME)
	defer delete(autoexec)
	testing.expect_value(t, string(autoexec), "@ECHO ORIGINAL\r\n")
	system_names := [2]string{BOOTSTRAP_SYSTEM_NAMES[0], BOOTSTRAP_SYSTEM_NAMES[2]}
	for name in system_names {
		path, _ := filepath.join({c_drive, name})
		testing.expect(t, !os.exists(path))
	}
	recovery, _ := filepath.join({c_drive, BOOTSTRAP_RECOVERY_NAME})
	testing.expect(t, !os.exists(recovery))
	retry, retry_diagnostic := bootstrap_install(c_drive, image_path)
	testing.expect_value(t, retry_diagnostic, Bootstrap_Diagnostic.None)
	testing.expect(t, bootstrap_rollback(&retry, c_drive))
}

@(test)
test_bootstrap_rollback_refuses_modified_owned_file :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := bootstrap_test_directory(t)
	defer os.remove_all(root)
	c_drive, _ := filepath.join({root, "c_drive"})
	image_path, _ := filepath.join({root, "boot.img"})
	testing.expect(t, os.make_directory(c_drive) == nil)
	bootstrap_test_write_image(t, image_path, false)
	transaction, diagnostic := bootstrap_install(c_drive, image_path)
	testing.expect_value(t, diagnostic, Bootstrap_Diagnostic.None)
	bootstrap_test_write(t, c_drive, "IO.SYS", "modified")
	testing.expect(t, !bootstrap_rollback(&transaction, c_drive))
	testing.expect_value(t, transaction.state, Bootstrap_Transaction_State.Rollback_Failed)
	io := bootstrap_test_read(t, c_drive, "IO.SYS")
	defer delete(io)
	testing.expect_value(t, string(io), "modified")
}

@(test)
test_bootstrap_preserves_preexisting_msdos_sys_in_fresh_seed :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := bootstrap_test_directory(t)
	defer os.remove_all(root)
	c_drive, _ := filepath.join({root, "c_drive"})
	image_path, _ := filepath.join({root, "boot.img"})
	testing.expect(t, os.make_directory(c_drive) == nil)
	bootstrap_test_write(t, c_drive, "MSDOS.SYS", "user options")
	bootstrap_test_write_image(t, image_path, false)
	transaction, diagnostic := bootstrap_install(c_drive, image_path)
	testing.expect_value(t, diagnostic, Bootstrap_Diagnostic.None)
	testing.expect(t, !transaction.system_installed[1])
	msdos := bootstrap_test_read(t, c_drive, "MSDOS.SYS")
	defer delete(msdos)
	testing.expect_value(t, string(msdos), "user options")
	testing.expect(t, bootstrap_rollback(&transaction, c_drive))
	msdos_path, _ := filepath.join({c_drive, "MSDOS.SYS"})
	testing.expect(t, os.exists(msdos_path))
}

@(test)
test_prepare_rollback_includes_pending_bootstrap :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := bootstrap_test_directory(t)
	defer os.remove_all(root)
	install_root, _ := filepath.join({root, "install"})
	c_drive, _ := filepath.join({root, "c_drive"})
	image_path, _ := filepath.join({root, "boot.img"})
	testing.expect(t, os.make_directory(install_root) == nil)
	testing.expect(t, os.make_directory(c_drive) == nil)
	bootstrap_test_write(t, c_drive, "AUTOEXEC.BAT", "@ECHO ORIGINAL\r\n")
	bootstrap_test_write_image(t, image_path, false)
	bootstrap, diagnostic := bootstrap_install(c_drive, image_path)
	testing.expect_value(t, diagnostic, Bootstrap_Diagnostic.None)

	report: Report
	preparation_transaction_init(&report.transaction, install_root, c_drive)
	report.transaction.bootstrap = bootstrap
	testing.expect(t, prepare_rollback(&report))
	testing.expect_value(t, report.transaction.state, Preparation_Transaction_State.Rolled_Back)
	testing.expect_value(
		t,
		report.transaction.bootstrap.state,
		Bootstrap_Transaction_State.Rolled_Back,
	)
	autoexec := bootstrap_test_read(t, c_drive, "AUTOEXEC.BAT")
	defer delete(autoexec)
	testing.expect_value(t, string(autoexec), "@ECHO ORIGINAL\r\n")
	for name in BOOTSTRAP_SYSTEM_NAMES {
		path, _ := filepath.join({c_drive, name})
		testing.expect(t, !os.exists(path))
	}
	report_destroy(&report)
}

@(test)
test_prepare_invalid_media_preserves_finalized_bootstrap_launcher :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := bootstrap_test_directory(t)
	defer os.remove_all(root)
	install_root, _ := filepath.join({root, "install"})
	c_drive, _ := filepath.join({root, "c_drive"})
	missing_iso, _ := filepath.join({root, "missing.iso"})
	testing.expect(t, os.make_directory(install_root) == nil)
	testing.expect(t, os.make_directory(c_drive) == nil)
	bootstrap_test_write(t, c_drive, "IO.SYS", "user io")
	bootstrap_test_write(t, c_drive, "MSDOS.SYS", "user msdos")
	bootstrap_test_write(t, c_drive, "COMMAND.COM", "user command")
	bootstrap_test_write(t, c_drive, "AUTOEXEC.BAT", "@ECHO ORIGINAL\r\n")

	transaction, diagnostic := bootstrap_install(c_drive, "")
	testing.expect_value(t, diagnostic, Bootstrap_Diagnostic.Existing_DOS)
	testing.expect(t, bootstrap_finish(&transaction, c_drive))

	report := prepare(missing_iso, install_root, c_drive)
	defer report_destroy(&report)
	testing.expect_value(t, report.diagnostic, Diagnostic.Media_Rejected)
	testing.expect_value(t, report.transaction.state, Preparation_Transaction_State.Inactive)
	autoexec := bootstrap_test_read(t, c_drive, BOOTSTRAP_AUTOEXEC_NAME)
	defer delete(autoexec)
	backup := bootstrap_test_read(t, c_drive, BOOTSTRAP_AUTOEXEC_BACKUP_NAME)
	defer delete(backup)
	testing.expect_value(t, string(autoexec), BOOTSTRAP_AUTOEXEC)
	testing.expect_value(t, string(backup), "@ECHO ORIGINAL\r\n")
}

@(test)
test_prepare_later_failure_preserves_reused_bootstrap_launcher :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := bootstrap_test_directory(t)
	defer os.remove_all(root)
	install_root, _ := filepath.join({root, "install"})
	c_drive, _ := filepath.join({root, "c_drive"})
	testing.expect(t, os.make_directory(install_root) == nil)
	testing.expect(t, os.make_directory(c_drive) == nil)
	bootstrap_test_write(t, c_drive, "IO.SYS", "user io")
	bootstrap_test_write(t, c_drive, "MSDOS.SYS", "user msdos")
	bootstrap_test_write(t, c_drive, "COMMAND.COM", "user command")
	bootstrap_test_write(t, c_drive, "AUTOEXEC.BAT", "@ECHO ORIGINAL\r\n")

	first, first_diagnostic := bootstrap_install(c_drive, "")
	testing.expect_value(t, first_diagnostic, Bootstrap_Diagnostic.Existing_DOS)
	testing.expect(t, bootstrap_finish(&first, c_drive))
	testing.expect(t, prepare_recover(install_root, c_drive))

	retry, retry_diagnostic := bootstrap_install(c_drive, "")
	testing.expect_value(t, retry_diagnostic, Bootstrap_Diagnostic.Existing_DOS)
	testing.expect(t, retry.autoexec_reused)
	testing.expect(t, !retry.autoexec_installed)
	testing.expect(t, !retry.autoexec_backed_up)

	report: Report
	preparation_transaction_init(&report.transaction, install_root, c_drive)
	report.transaction.bootstrap = retry
	report.diagnostic = .Extract_Failed
	paths, paths_ok := preparation_paths(&report.transaction)
	testing.expect(t, paths_ok)
	preparation_failure_finalize(&report, &paths)
	defer report_destroy(&report)
	testing.expect_value(t, report.transaction.state, Preparation_Transaction_State.Rolled_Back)
	testing.expect_value(
		t,
		report.transaction.bootstrap.state,
		Bootstrap_Transaction_State.Rolled_Back,
	)
	autoexec := bootstrap_test_read(t, c_drive, BOOTSTRAP_AUTOEXEC_NAME)
	defer delete(autoexec)
	backup := bootstrap_test_read(t, c_drive, BOOTSTRAP_AUTOEXEC_BACKUP_NAME)
	defer delete(backup)
	testing.expect_value(t, string(autoexec), BOOTSTRAP_AUTOEXEC)
	testing.expect_value(t, string(backup), "@ECHO ORIGINAL\r\n")
}

@(test)
test_bootstrap_recover_restores_preexisting_autoexec_after_crash :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := bootstrap_test_directory(t)
	defer os.remove_all(root)
	c_drive, _ := filepath.join({root, "c_drive"})
	testing.expect(t, os.make_directory(c_drive) == nil)
	bootstrap_test_write(t, c_drive, "IO.SYS", "user io")
	bootstrap_test_write(t, c_drive, "MSDOS.SYS", "user msdos")
	bootstrap_test_write(t, c_drive, "COMMAND.COM", "user command")
	bootstrap_test_write(t, c_drive, "AUTOEXEC.BAT", "@ECHO ORIGINAL\r\n")

	transaction, diagnostic := bootstrap_install(c_drive, "")
	testing.expect_value(t, diagnostic, Bootstrap_Diagnostic.Existing_DOS)
	testing.expect_value(t, transaction.state, Bootstrap_Transaction_State.Pending)
	testing.expect(t, bootstrap_recover(c_drive))
	autoexec := bootstrap_test_read(t, c_drive, BOOTSTRAP_AUTOEXEC_NAME)
	defer delete(autoexec)
	testing.expect_value(t, string(autoexec), "@ECHO ORIGINAL\r\n")
	backup, _ := filepath.join({c_drive, BOOTSTRAP_AUTOEXEC_BACKUP_NAME})
	staging, _ := filepath.join({c_drive, BOOTSTRAP_AUTOEXEC_STAGING_NAME})
	testing.expect(t, !os.exists(backup))
	testing.expect(t, !os.exists(staging))
}

@(test)
test_bootstrap_recover_keeps_fresh_seed_bootable_for_retry :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := bootstrap_test_directory(t)
	defer os.remove_all(root)
	c_drive, _ := filepath.join({root, "c_drive"})
	image_path, _ := filepath.join({root, "boot.img"})
	testing.expect(t, os.make_directory(c_drive) == nil)
	bootstrap_test_write_image(t, image_path, false)

	_, diagnostic := bootstrap_install(c_drive, image_path)
	testing.expect_value(t, diagnostic, Bootstrap_Diagnostic.None)
	testing.expect(t, bootstrap_recover(c_drive))
	autoexec, _ := filepath.join({c_drive, BOOTSTRAP_AUTOEXEC_NAME})
	testing.expect(t, !os.exists(autoexec))
	for name in BOOTSTRAP_SYSTEM_NAMES {
		path, _ := filepath.join({c_drive, name})
		testing.expect(t, os.exists(path))
	}

	retry, retry_diagnostic := bootstrap_install(c_drive, "")
	testing.expect_value(t, retry_diagnostic, Bootstrap_Diagnostic.Existing_DOS)
	testing.expect(t, retry.used_existing_dos)
	testing.expect(t, bootstrap_rollback(&retry, c_drive))
}

@(test)
test_bootstrap_fresh_recovery_removes_only_fingerprinted_partial_seed :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := bootstrap_test_directory(t)
	defer os.remove_all(root)
	c_drive, _ := filepath.join({root, "c_drive"})
	testing.expect(t, os.make_directory(c_drive) == nil)
	files: Bootstrap_Files
	files.data[0] = transmute([]u8)string("owned io")
	files.data[2] = transmute([]u8)string("owned command")
	marker, marker_ok := bootstrap_recovery_fresh_marker(&files)
	testing.expect(t, marker_ok)
	bootstrap_test_write(t, c_drive, BOOTSTRAP_RECOVERY_NAME, marker)
	bootstrap_test_write(t, c_drive, BOOTSTRAP_SYSTEM_NAMES[0], "owned io")
	bootstrap_test_write(t, c_drive, BOOTSTRAP_SYSTEM_STAGING_NAMES[2], "owned command")
	bootstrap_test_write(t, c_drive, BOOTSTRAP_AUTOEXEC_STAGING_NAME, BOOTSTRAP_AUTOEXEC)

	recovery_path, _ := filepath.join({c_drive, BOOTSTRAP_RECOVERY_NAME})
	recovery := bootstrap_recovery_read(recovery_path)
	testing.expect_value(t, recovery.mode, Bootstrap_Recovery_Mode.Fresh)
	testing.expect_value(
		t,
		recovery.system_fingerprint[0],
		bootstrap_fingerprint_string("owned io"),
	)
	testing.expect_value(
		t,
		recovery.system_fingerprint[2],
		bootstrap_fingerprint_string("owned command"),
	)
	testing.expect(t, bootstrap_recover(c_drive))
	removed_names := [?]string {
		BOOTSTRAP_RECOVERY_NAME,
		BOOTSTRAP_SYSTEM_NAMES[0],
		BOOTSTRAP_SYSTEM_STAGING_NAMES[2],
		BOOTSTRAP_AUTOEXEC_STAGING_NAME,
	}
	for name in removed_names {
		path, _ := filepath.join({c_drive, name})
		testing.expect(t, !os.exists(path))
	}
}

@(test)
test_bootstrap_fresh_recovery_refuses_modified_owned_system_files_atomically :: proc(
	t: ^testing.T,
) {
	context.allocator = context.temp_allocator
	root := bootstrap_test_directory(t)
	defer os.remove_all(root)
	case_names := [?]string{"changed_io", "changed_command"}
	changed_indexes := [?]int{0, 2}
	system_names := BOOTSTRAP_SYSTEM_NAMES
	system_staging_names := BOOTSTRAP_SYSTEM_STAGING_NAMES
	for case_name, case_index in case_names {
		c_drive, _ := filepath.join({root, case_name})
		testing.expect(t, os.make_directory(c_drive) == nil)
		files: Bootstrap_Files
		files.data[0] = transmute([]u8)string("owned io")
		files.data[2] = transmute([]u8)string("owned command")
		marker, marker_ok := bootstrap_recovery_fresh_marker(&files)
		testing.expect(t, marker_ok)
		bootstrap_test_write(t, c_drive, BOOTSTRAP_RECOVERY_NAME, marker)
		changed_index := changed_indexes[case_index]
		other_index := changed_index == 0 ? 2 : 0
		bootstrap_test_write(t, c_drive, system_names[changed_index], "user modified")
		other_contents := changed_index == 0 ? "owned command" : "owned io"
		bootstrap_test_write(t, c_drive, system_staging_names[other_index], other_contents)
		bootstrap_test_write(t, c_drive, BOOTSTRAP_AUTOEXEC_STAGING_NAME, BOOTSTRAP_AUTOEXEC)

		testing.expect(t, !bootstrap_recover(c_drive))
		changed := bootstrap_test_read(t, c_drive, system_names[changed_index])
		testing.expect_value(t, string(changed), "user modified")
		delete(changed)
		preserved_names := [?]string {
			BOOTSTRAP_RECOVERY_NAME,
			system_staging_names[other_index],
			BOOTSTRAP_AUTOEXEC_STAGING_NAME,
		}
		for name in preserved_names {
			path, _ := filepath.join({c_drive, name})
			testing.expect(t, os.exists(path))
		}
	}
}

@(test)
test_bootstrap_legacy_fresh_recovery_marker_fails_closed :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := bootstrap_test_directory(t)
	defer os.remove_all(root)
	c_drive, _ := filepath.join({root, "c_drive"})
	testing.expect(t, os.make_directory(c_drive) == nil)
	bootstrap_test_write(
		t,
		c_drive,
		BOOTSTRAP_RECOVERY_NAME,
		"RETVRN99 WINDOWS 98 BOOTSTRAP RECOVERY V1 FRESH\r\n",
	)
	bootstrap_test_write(t, c_drive, BOOTSTRAP_SYSTEM_NAMES[0], "ambiguous io")

	testing.expect(t, !bootstrap_recover(c_drive))
	io := bootstrap_test_read(t, c_drive, BOOTSTRAP_SYSTEM_NAMES[0])
	defer delete(io)
	testing.expect_value(t, string(io), "ambiguous io")
	recovery, _ := filepath.join({c_drive, BOOTSTRAP_RECOVERY_NAME})
	testing.expect(t, os.exists(recovery))
}

@(test)
test_bootstrap_recover_removes_owned_crash_staging :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := bootstrap_test_directory(t)
	defer os.remove_all(root)
	c_drive, _ := filepath.join({root, "c_drive"})
	testing.expect(t, os.make_directory(c_drive) == nil)
	bootstrap_test_write(t, c_drive, BOOTSTRAP_AUTOEXEC_STAGING_NAME, BOOTSTRAP_AUTOEXEC)
	bootstrap_test_write(t, c_drive, BOOTSTRAP_SYSTEM_STAGING_NAMES[0], "partial system seed")

	testing.expect(t, bootstrap_recover(c_drive))
	autoexec_staging, _ := filepath.join({c_drive, BOOTSTRAP_AUTOEXEC_STAGING_NAME})
	system_staging, _ := filepath.join({c_drive, BOOTSTRAP_SYSTEM_STAGING_NAMES[0]})
	testing.expect(t, !os.exists(autoexec_staging))
	testing.expect(t, !os.exists(system_staging))
}

@(test)
test_bootstrap_recover_refuses_ambiguous_system_staging :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := bootstrap_test_directory(t)
	defer os.remove_all(root)
	c_drive, _ := filepath.join({root, "c_drive"})
	testing.expect(t, os.make_directory(c_drive) == nil)
	bootstrap_test_write(t, c_drive, BOOTSTRAP_SYSTEM_STAGING_NAMES[0], "user collision")

	testing.expect(t, !bootstrap_recover(c_drive))
	staging := bootstrap_test_read(t, c_drive, BOOTSTRAP_SYSTEM_STAGING_NAMES[0])
	defer delete(staging)
	testing.expect_value(t, string(staging), "user collision")
}

@(test)
test_prepare_interrupted_recovery_discards_markerless_bootstrap_launcher :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := bootstrap_test_directory(t)
	defer os.remove_all(root)
	install_root, _ := filepath.join({root, "install"})
	c_drive, _ := filepath.join({root, "c_drive"})
	testing.expect(t, os.make_directory(install_root) == nil)
	testing.expect(t, os.make_directory(c_drive) == nil)
	bootstrap_test_write(t, c_drive, BOOTSTRAP_AUTOEXEC_NAME, BOOTSTRAP_AUTOEXEC)
	bootstrap_test_write(t, c_drive, BOOTSTRAP_AUTOEXEC_BACKUP_NAME, "@ECHO ORIGINAL\r\n")

	testing.expect(t, prepare_recover_interrupted(install_root, c_drive))
	autoexec := bootstrap_test_read(t, c_drive, BOOTSTRAP_AUTOEXEC_NAME)
	defer delete(autoexec)
	testing.expect_value(t, string(autoexec), "@ECHO ORIGINAL\r\n")
	backup, _ := filepath.join({c_drive, BOOTSTRAP_AUTOEXEC_BACKUP_NAME})
	testing.expect(t, !os.exists(backup))
}

@(private)
bootstrap_test_fail_command_commit :: proc(old_path, new_path: string) -> os.Error {
	if strings.has_suffix(old_path, "GSWCMD.NXT") {return os.General_Error.Invalid_Path}
	return os.rename(old_path, new_path)
}

@(private)
bootstrap_test_fail_command_and_autoexec_restore :: proc(old_path, new_path: string) -> os.Error {
	if strings.has_suffix(old_path, "GSWCMD.NXT") ||
	   strings.has_suffix(old_path, BOOTSTRAP_AUTOEXEC_BACKUP_NAME) {
		return os.General_Error.Invalid_Path
	}
	return os.rename(old_path, new_path)
}

@(private)
bootstrap_test_directory :: proc(t: ^testing.T) -> string {
	base, base_error := os.temp_directory(context.allocator)
	testing.expect(t, base_error == nil)
	dir, dir_error := os.make_directory_temp(base, "retvrn99_bootstrap_*", context.allocator)
	testing.expect(t, dir_error == nil)
	return dir
}

@(private)
bootstrap_test_write :: proc(t: ^testing.T, root, name, contents: string) {
	path, path_error := filepath.join({root, name})
	testing.expect(t, path_error == nil)
	defer delete(path)
	testing.expect(t, os.write_entire_file(path, contents) == nil)
}

@(private)
bootstrap_test_read :: proc(t: ^testing.T, root, name: string) -> []u8 {
	path, path_error := filepath.join({root, name})
	testing.expect(t, path_error == nil)
	defer delete(path)
	data, read_error := os.read_entire_file(path, context.allocator)
	testing.expect(t, read_error == nil)
	return data
}

@(private)
profile_seed_text_for_test :: proc() -> string {
	return "[Options]\r\nLogo=0\r\nBootGUI=0\r\n"
}

@(private)
bootstrap_test_write_image :: proc(t: ^testing.T, path: string, cyclic_io: bool) {
	image := make([]u8, 1_474_560, context.temp_allocator)
	defer delete(image, context.temp_allocator)
	image[0], image[1], image[2] = 0xeb, 0x3c, 0x90
	copy(image[3:11], "GSWBOOT ")
	bootstrap_test_put16(image, 11, 512)
	image[13] = 1
	bootstrap_test_put16(image, 14, 1)
	image[16] = 2
	bootstrap_test_put16(image, 17, 224)
	bootstrap_test_put16(image, 19, 2880)
	image[21] = 0xf0
	bootstrap_test_put16(image, 22, 9)
	bootstrap_test_put16(image, 24, 18)
	bootstrap_test_put16(image, 26, 2)
	image[510], image[511] = 0x55, 0xaa

	fat_offsets := [?]int{512, 512 + 9 * 512}
	for fat_offset in fat_offsets {
		image[fat_offset], image[fat_offset + 1], image[fat_offset + 2] = 0xf0, 0xff, 0xff
		bootstrap_test_fat12_set(image[fat_offset:fat_offset + 9 * 512], 2, cyclic_io ? 2 : 3)
		bootstrap_test_fat12_set(image[fat_offset:fat_offset + 9 * 512], 3, 0xfff)
		bootstrap_test_fat12_set(image[fat_offset:fat_offset + 9 * 512], 4, 0xfff)
		bootstrap_test_fat12_set(image[fat_offset:fat_offset + 9 * 512], 5, 6)
		bootstrap_test_fat12_set(image[fat_offset:fat_offset + 9 * 512], 6, 0xfff)
	}

	root_offset := 19 * 512
	bootstrap_test_root_entry(image[root_offset:], "IO      SYS", 0x06, 2, 700)
	bootstrap_test_root_entry(image[root_offset + 32:], "MSDOS   SYS", 0x06, 4, 4)
	bootstrap_test_root_entry(image[root_offset + 64:], "COMMAND COM", 0x20, 5, 600)
	data_offset := 33 * 512
	for &byte in image[data_offset:data_offset + 512] {byte = 0x49}
	for &byte in image[data_offset + 512:data_offset + 700] {byte = 0x69}
	copy(image[data_offset + 2 * 512:data_offset + 2 * 512 + 4], "; \r\n")
	for &byte in image[data_offset + 3 * 512:data_offset + 4 * 512] {byte = 0x43}
	for &byte in image[data_offset + 4 * 512:data_offset + 4 * 512 + 88] {byte = 0x63}
	testing.expect(t, os.write_entire_file(path, image) == nil)
}

@(private)
bootstrap_test_root_entry :: proc(
	entry: []u8,
	name: string,
	attributes: u8,
	cluster: u16,
	size: u32,
) {
	copy(entry[:11], name)
	entry[11] = attributes
	bootstrap_test_put16(entry, 26, cluster)
	bootstrap_test_put32(entry, 28, size)
}

@(private)
bootstrap_test_fat12_set :: proc(fat: []u8, cluster, value: int) {
	offset := cluster + cluster / 2
	if (cluster & 1) == 0 {
		fat[offset] = u8(value & 0xff)
		fat[offset + 1] = (fat[offset + 1] & 0xf0) | u8((value >> 8) & 0x0f)
	} else {
		fat[offset] = (fat[offset] & 0x0f) | u8((value << 4) & 0xf0)
		fat[offset + 1] = u8((value >> 4) & 0xff)
	}
}

@(private)
bootstrap_test_put16 :: proc(data: []u8, offset: int, value: u16) {
	data[offset] = u8(value)
	data[offset + 1] = u8(value >> 8)
}

@(private)
bootstrap_test_put32 :: proc(data: []u8, offset: int, value: u32) {
	data[offset] = u8(value)
	data[offset + 1] = u8(value >> 8)
	data[offset + 2] = u8(value >> 16)
	data[offset + 3] = u8(value >> 24)
}
