// SPDX-License-Identifier: GPL-3.0-only
package win98prep

import profile "../profile"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
test_replace_path_commits_complete_directory :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := install_test_directory(t)
	defer os.remove_all(root)
	current, _ := filepath.join({root, "current"})
	next, _ := filepath.join({root, "next"})
	backup, _ := filepath.join({root, "backup"})
	_ = os.make_directory(current)
	_ = os.make_directory(next)
	old_file, _ := filepath.join({current, "old.txt"})
	new_file, _ := filepath.join({next, "new.txt"})
	_ = os.write_entire_file(old_file, "old")
	_ = os.write_entire_file(new_file, "new")

	testing.expect(t, replace_path(next, current, backup))
	testing.expect(t, !os.exists(old_file))
	committed, _ := filepath.join({current, "new.txt"})
	testing.expect(t, os.exists(committed))
	testing.expect(t, !os.exists(next))
	testing.expect(t, !os.exists(backup))
}

@(test)
test_fallback_batch_is_language_neutral :: proc(t: ^testing.T) {
	batch := fallback_msbatch()
	testing.expect(t, len(batch) > 0)
	testing.expect(t, contains(batch, `Signature="$CHICAGO$"`))
	testing.expect(t, contains(batch, `InstallDir="C:\WINDOWS"`))
	normalized, ok := normalize_msbatch(batch)
	testing.expect(t, ok)
	testing.expect(t, contains(normalized, "OptionalComponents=0"))
	delete(normalized)
}

@(test)
test_launcher_restores_gui_boot_only_for_managed_dos_seed :: proc(t: ^testing.T) {
	managed := launcher_text("INSTALAR.EXE", true)
	testing.expect(t, strings.has_prefix(managed, LAUNCHER_MARKER))
	testing.expect(t, contains(managed, "ECHO BootGUI=1>>C:\\MSDOS.SYS"))
	testing.expect(t, contains(managed, "INSTALAR.EXE MSBATCH.INF"))
	custom := launcher_text("SETUP.EXE", false)
	testing.expect(t, !contains(custom, "BootGUI=1"))
}

@(test)
test_launcher_restores_one_shot_autoexec_before_setup :: proc(t: ^testing.T) {
	launcher := launcher_text("INSTALAR.EXE", true, true)
	testing.expect(t, contains(launcher, "IF EXIST C:\\GSWAUTO.PRV GOTO GSWAR"))
	testing.expect(t, contains(launcher, "DEL C:\\AUTOEXEC.BAT >NUL"))
	testing.expect(t, contains(launcher, "REN C:\\GSWAUTO.PRV AUTOEXEC.BAT"))
	testing.expect(t, contains(launcher, "IF EXIST C:\\GSWAUTO.PRV GOTO GSWAE"))
	testing.expect(t, contains(launcher, "IF NOT EXIST C:\\AUTOEXEC.BAT GOTO GSWAE"))
	restore := strings.index(launcher, "REN C:\\GSWAUTO.PRV AUTOEXEC.BAT")
	setup := strings.index(launcher, "INSTALAR.EXE MSBATCH.INF")
	testing.expect(t, restore >= 0 && setup > restore)
}

@(test)
test_payload_copy_releases_source_directory_handles :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := install_test_directory(t)
	defer os.remove_all(root)
	source, _ := filepath.join({root, "source"})
	destination, _ := filepath.join({root, "destination"})
	nested, _ := filepath.join({source, "nested"})
	leaf, _ := filepath.join({nested, "SETUP.CAB"})
	copy, _ := filepath.join({destination, "nested", "SETUP.CAB"})
	moved, _ := filepath.join({root, "source.moved"})
	testing.expect(t, os.make_directory_all(nested) == nil)
	testing.expect(t, os.make_directory(destination) == nil)
	testing.expect(t, os.write_entire_file(leaf, "cab payload") == nil)

	testing.expect(t, copy_directory_tree(destination, source))
	testing.expect(t, os.exists(copy))
	testing.expect(t, os.rename(source, moved) == nil)
	testing.expect(t, os.remove_all(moved) == nil)
}

@(test)
test_prepare_recover_restores_interrupted_generations :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := install_test_directory(t)
	defer os.remove_all(root)
	install_root, _ := filepath.join({root, "install"})
	c_drive, _ := filepath.join({root, "c_drive"})
	testing.expect(t, os.make_directory(install_root) == nil)
	testing.expect(t, os.make_directory(c_drive) == nil)
	transaction := Preparation_Transaction {
		install_root = install_root,
		c_drive      = c_drive,
	}
	paths, paths_ok := preparation_paths(&transaction)
	testing.expect(t, paths_ok)

	testing.expect(t, os.make_directory(paths.scratch_final) == nil)
	testing.expect(t, os.make_directory(paths.scratch_next) == nil)
	old_scratch, _ := filepath.join({paths.scratch_final, "OLD.CAB"})
	new_scratch, _ := filepath.join({paths.scratch_next, "NEW.CAB"})
	testing.expect(t, os.write_entire_file(old_scratch, "old") == nil)
	testing.expect(t, os.write_entire_file(new_scratch, "new") == nil)
	_, scratch_ok := path_commit_start(
		paths.scratch_next,
		paths.scratch_final,
		paths.scratch_backup,
		rename_with_retry,
	)
	testing.expect(t, scratch_ok)

	owned_test_payload(t, paths.payload_final, "old.txt")
	owned_test_payload(t, paths.payload_next, "new.txt")
	owned_test_launcher(t, paths.launcher_final, "OLD.EXE")
	owned_test_launcher(t, paths.launcher_next, "NEW.EXE")
	_, _, result := owned_install_commit_start(
		paths.payload_next,
		paths.payload_final,
		paths.payload_backup,
		paths.launcher_next,
		paths.launcher_final,
		paths.launcher_backup,
		rename_with_retry,
	)
	testing.expect_value(t, result, Owned_Install_Result.Success)

	testing.expect(t, prepare_recover(install_root, c_drive))
	old_payload, _ := filepath.join({paths.payload_final, "old.txt"})
	new_payload, _ := filepath.join({paths.payload_final, "new.txt"})
	testing.expect(t, os.exists(old_payload))
	testing.expect(t, !os.exists(new_payload))
	launcher := owned_test_read(t, paths.launcher_final)
	defer delete(launcher)
	testing.expect(t, contains(launcher, "OLD.EXE"))
	testing.expect(t, os.exists(old_scratch))
	testing.expect(t, !os.exists(new_scratch))
	testing.expect(t, !os.exists(paths.payload_next))
	testing.expect(t, !os.exists(paths.payload_backup))
	testing.expect(t, !os.exists(paths.launcher_next))
	testing.expect(t, !os.exists(paths.launcher_backup))
	testing.expect(t, !os.exists(paths.scratch_next))
	testing.expect(t, !os.exists(paths.scratch_backup))
}

@(test)
test_prepare_recover_removes_only_owned_partial_staging :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := install_test_directory(t)
	defer os.remove_all(root)
	install_root, _ := filepath.join({root, "install"})
	c_drive, _ := filepath.join({root, "c_drive"})
	testing.expect(t, os.make_directory(install_root) == nil)
	testing.expect(t, os.make_directory(c_drive) == nil)
	transaction := Preparation_Transaction {
		install_root = install_root,
		c_drive      = c_drive,
	}
	paths, paths_ok := preparation_paths(&transaction)
	testing.expect(t, paths_ok)

	testing.expect(t, os.make_directory(paths.scratch_next) == nil)
	owned_test_payload(t, paths.payload_next, "partial.txt")
	owned_test_launcher(t, paths.launcher_next, "SETUP.EXE")
	testing.expect(t, prepare_recover(install_root, c_drive))
	testing.expect(t, !os.exists(paths.scratch_next))
	testing.expect(t, !os.exists(paths.payload_next))
	testing.expect(t, !os.exists(paths.launcher_next))
}

@(test)
test_prepare_recover_preserves_unmarked_collision :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := install_test_directory(t)
	defer os.remove_all(root)
	install_root, _ := filepath.join({root, "install"})
	c_drive, _ := filepath.join({root, "c_drive"})
	testing.expect(t, os.make_directory(install_root) == nil)
	testing.expect(t, os.make_directory(c_drive) == nil)
	transaction := Preparation_Transaction {
		install_root = install_root,
		c_drive      = c_drive,
	}
	paths, paths_ok := preparation_paths(&transaction)
	testing.expect(t, paths_ok)
	testing.expect(t, os.make_directory(paths.payload_next) == nil)
	sentinel, _ := filepath.join({paths.payload_next, "USER.TXT"})
	testing.expect(t, os.write_entire_file(sentinel, "preserve") == nil)

	testing.expect(t, !prepare_recover(install_root, c_drive))
	contents := owned_test_read(t, sentinel)
	defer delete(contents)
	testing.expect_value(t, contents, "preserve")
}

@(test)
test_prepare_retry_recovers_prior_staging_before_media_validation :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := install_test_directory(t)
	defer os.remove_all(root)
	install_root, _ := filepath.join({root, "install"})
	c_drive, _ := filepath.join({root, "c_drive"})
	testing.expect(t, os.make_directory(install_root) == nil)
	testing.expect(t, os.make_directory(c_drive) == nil)
	transaction := Preparation_Transaction {
		install_root = install_root,
		c_drive      = c_drive,
	}
	paths, paths_ok := preparation_paths(&transaction)
	testing.expect(t, paths_ok)
	owned_test_payload(t, paths.payload_next, "partial.txt")

	report := prepare("missing.iso", install_root, c_drive)
	defer report_destroy(&report)
	testing.expect_value(t, report.diagnostic, Diagnostic.Media_Rejected)
	testing.expect(t, !os.exists(paths.payload_next))
}

@(test)
test_owned_payload_staging_refuses_unmarked_collision :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := install_test_directory(t)
	defer os.remove_all(root)
	staging, _ := filepath.join({root, PAYLOAD_STAGING_NAME})
	sentinel, _ := filepath.join({staging, "USER.TXT"})
	testing.expect(t, os.make_directory(staging) == nil)
	testing.expect(t, os.write_entire_file(sentinel, "user data") == nil)

	testing.expect(t, !prepare_owned_payload_staging(staging))
	testing.expect(t, os.exists(sentinel))
}

@(test)
test_owned_launcher_staging_refuses_unmarked_collision :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := install_test_directory(t)
	defer os.remove_all(root)
	staging, _ := filepath.join({root, LAUNCHER_STAGING_NAME})
	testing.expect(t, os.write_entire_file(staging, "@ECHO USER FILE\r\n") == nil)

	testing.expect(t, !write_owned_launcher_staging(staging, launcher_text("SETUP.EXE", false)))
	contents := owned_test_read(t, staging)
	defer delete(contents)
	testing.expect_value(t, contents, "@ECHO USER FILE\r\n")
}

@(test)
test_owned_install_paths_refuse_unmarked_final_and_backup_collisions :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := install_test_directory(t)
	defer os.remove_all(root)
	payload_next, payload_current, payload_backup, launcher_next, launcher_current, launcher_backup :=
		owned_test_paths(root)
	defer delete(payload_next)
	defer delete(payload_current)
	defer delete(payload_backup)
	defer delete(launcher_next)
	defer delete(launcher_current)
	defer delete(launcher_backup)

	testing.expect(t, os.make_directory(payload_current) == nil)
	testing.expect(
		t,
		!owned_install_paths_safe(
			payload_next,
			payload_current,
			payload_backup,
			launcher_next,
			launcher_current,
			launcher_backup,
		),
	)
	_ = os.remove(payload_current)
	testing.expect(t, os.make_directory(payload_backup) == nil)
	testing.expect(
		t,
		!owned_install_paths_safe(
			payload_next,
			payload_current,
			payload_backup,
			launcher_next,
			launcher_current,
			launcher_backup,
		),
	)
	_ = os.remove(payload_backup)
	testing.expect(t, os.write_entire_file(launcher_current, "@ECHO USER FILE\r\n") == nil)
	testing.expect(
		t,
		!owned_install_paths_safe(
			payload_next,
			payload_current,
			payload_backup,
			launcher_next,
			launcher_current,
			launcher_backup,
		),
	)
	_ = os.remove(launcher_current)
	testing.expect(t, os.write_entire_file(launcher_backup, "@ECHO USER BACKUP\r\n") == nil)
	testing.expect(
		t,
		!owned_install_paths_safe(
			payload_next,
			payload_current,
			payload_backup,
			launcher_next,
			launcher_current,
			launcher_backup,
		),
	)
}

@(test)
test_owned_generation_names_are_case_insensitively_distinct :: proc(t: ^testing.T) {
	names := [?]string {
		PAYLOAD_STAGING_NAME,
		PAYLOAD_FINAL_NAME,
		PAYLOAD_BACKUP_NAME,
		LAUNCHER_STAGING_NAME,
		LAUNCHER_FINAL_NAME,
		LAUNCHER_BACKUP_NAME,
	}
	for left in 0 ..< len(names) {
		for right in left + 1 ..< len(names) {
			testing.expect(t, !ascii_equal_fold(names[left], names[right]))
		}
	}
}

@(test)
test_owned_install_rolls_back_payload_when_launcher_commit_fails :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := install_test_directory(t)
	defer os.remove_all(root)
	payload_next, payload_current, payload_backup, launcher_next, launcher_current, launcher_backup :=
		owned_test_paths(root)
	defer delete(payload_next)
	defer delete(payload_current)
	defer delete(payload_backup)
	defer delete(launcher_next)
	defer delete(launcher_current)
	defer delete(launcher_backup)

	owned_test_payload(t, payload_current, "old.txt")
	owned_test_payload(t, payload_next, "new.txt")
	owned_test_launcher(t, launcher_current, "OLD.EXE")
	owned_test_launcher(t, launcher_next, "NEW.EXE")

	result := owned_install_commit(
		payload_next,
		payload_current,
		payload_backup,
		launcher_next,
		launcher_current,
		launcher_backup,
		owned_test_fail_launcher_commit,
	)
	testing.expect_value(t, result, Owned_Install_Result.Launcher_Failed)
	old_payload, _ := filepath.join({payload_current, "old.txt"})
	new_payload, _ := filepath.join({payload_current, "new.txt"})
	testing.expect(t, os.exists(old_payload))
	testing.expect(t, !os.exists(new_payload))
	testing.expect(t, !os.exists(payload_next))
	testing.expect(t, !os.exists(payload_backup))
	launcher_contents := owned_test_read(t, launcher_current)
	defer delete(launcher_contents)
	testing.expect(t, contains(launcher_contents, "OLD.EXE"))
	testing.expect(t, !os.exists(launcher_next))
	testing.expect(t, !os.exists(launcher_backup))
}

@(test)
test_owned_install_replaces_marked_payload_and_launcher :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := install_test_directory(t)
	defer os.remove_all(root)
	payload_next, payload_current, payload_backup, launcher_next, launcher_current, launcher_backup :=
		owned_test_paths(root)
	defer delete(payload_next)
	defer delete(payload_current)
	defer delete(payload_backup)
	defer delete(launcher_next)
	defer delete(launcher_current)
	defer delete(launcher_backup)

	owned_test_payload(t, payload_current, "old.txt")
	owned_test_payload(t, payload_next, "new.txt")
	owned_test_launcher(t, launcher_current, "OLD.EXE")
	owned_test_launcher(t, launcher_next, "NEW.EXE")

	result := owned_install_commit(
		payload_next,
		payload_current,
		payload_backup,
		launcher_next,
		launcher_current,
		launcher_backup,
		rename_with_retry,
	)
	testing.expect_value(t, result, Owned_Install_Result.Success)
	new_payload, _ := filepath.join({payload_current, "new.txt"})
	old_payload, _ := filepath.join({payload_current, "old.txt"})
	testing.expect(t, os.exists(new_payload))
	testing.expect(t, !os.exists(old_payload))
	testing.expect(t, !os.exists(payload_backup))
	launcher_contents := owned_test_read(t, launcher_current)
	defer delete(launcher_contents)
	testing.expect(t, contains(launcher_contents, "NEW.EXE"))
	testing.expect(t, !os.exists(launcher_backup))
}

@(test)
test_preparation_state_rejection_restores_previous_generation :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := install_test_directory(t)
	defer os.remove_all(root)
	install_root, _ := filepath.join({root, "install"})
	c_drive, _ := filepath.join({root, "c_drive"})
	testing.expect(t, os.make_directory(install_root) == nil)
	testing.expect(t, os.make_directory(c_drive) == nil)

	report: Report
	preparation_transaction_init(&report.transaction, install_root, c_drive)
	defer report_destroy(&report)
	paths, paths_ok := preparation_paths(&report.transaction)
	testing.expect(t, paths_ok)
	testing.expect(t, os.make_directory(paths.scratch_final) == nil)
	testing.expect(t, os.make_directory(paths.scratch_next) == nil)
	old_scratch, _ := filepath.join({paths.scratch_final, "OLD.CAB"})
	new_scratch, _ := filepath.join({paths.scratch_next, "NEW.CAB"})
	testing.expect(t, os.write_entire_file(old_scratch, "old") == nil)
	testing.expect(t, os.write_entire_file(new_scratch, "new") == nil)
	_, scratch_ok := path_commit_start(
		paths.scratch_next,
		paths.scratch_final,
		paths.scratch_backup,
		rename_with_retry,
	)
	testing.expect(t, scratch_ok)
	report.transaction.scratch_committed = scratch_ok

	setup_artifact, _ := filepath.join({c_drive, "SYSTEM.NEW"})
	testing.expect(t, os.write_entire_file(setup_artifact, "registry") == nil)
	report.retry_cleanup = retry_cleanup_archive(c_drive, install_root)
	report.transaction.retry_archived = report.retry_cleanup.archived_count > 0
	archive_path := strings.clone(report.retry_cleanup.archive_path)
	defer delete(archive_path)

	owned_test_payload(t, paths.payload_final, "old.txt")
	owned_test_payload(t, paths.payload_next, "new.txt")
	owned_test_launcher(t, paths.launcher_final, "OLD.EXE")
	owned_test_launcher(t, paths.launcher_next, "NEW.EXE")
	payload, launcher, result := owned_install_commit_start(
		paths.payload_next,
		paths.payload_final,
		paths.payload_backup,
		paths.launcher_next,
		paths.launcher_final,
		paths.launcher_backup,
		rename_with_retry,
	)
	testing.expect_value(t, result, Owned_Install_Result.Success)
	report.transaction.payload_committed = payload.committed
	report.transaction.launcher_committed = launcher.committed

	state_path, _ := filepath.join({root, "install-state.json"})
	preparing_state := profile.Install_State {
		phase       = .Preparing,
		source_path = "WIN98SE.ISO",
	}
	testing.expect_value(
		t,
		profile.install_state_save(state_path, &preparing_state),
		profile.Install_State_Diagnostic.None,
	)
	rejected_state := profile.Install_State {
		phase = .Launch_Pending,
	}
	testing.expect_value(
		t,
		profile.install_state_save(state_path, &rejected_state),
		profile.Install_State_Diagnostic.Invalid_State,
	)
	testing.expect(t, prepare_rollback(&report))
	testing.expect_value(t, report.transaction.state, Preparation_Transaction_State.Rolled_Back)
	loaded_state, state_diagnostic := profile.install_state_load(state_path)
	defer profile.install_state_destroy(&loaded_state)
	testing.expect_value(t, state_diagnostic, profile.Install_State_Diagnostic.None)
	testing.expect_value(t, loaded_state.phase, profile.Install_Phase.Preparing)
	testing.expect(t, os.exists(old_scratch))
	testing.expect(t, !os.exists(new_scratch))
	old_payload, _ := filepath.join({paths.payload_final, "old.txt"})
	new_payload, _ := filepath.join({paths.payload_final, "new.txt"})
	testing.expect(t, os.exists(old_payload))
	testing.expect(t, !os.exists(new_payload))
	launcher_contents := owned_test_read(t, paths.launcher_final)
	defer delete(launcher_contents)
	testing.expect(t, contains(launcher_contents, "OLD.EXE"))
	testing.expect(t, !os.exists(paths.payload_backup))
	testing.expect(t, !os.exists(paths.launcher_backup))
	testing.expect(t, os.exists(setup_artifact))
	testing.expect(t, !os.exists(archive_path))
}

@(test)
test_preparation_rollback_failure_retains_both_owned_generations :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := install_test_directory(t)
	defer os.remove_all(root)
	install_root, _ := filepath.join({root, "install"})
	c_drive, _ := filepath.join({root, "c_drive"})
	testing.expect(t, os.make_directory(install_root) == nil)
	testing.expect(t, os.make_directory(c_drive) == nil)

	report: Report
	preparation_transaction_init(&report.transaction, install_root, c_drive)
	defer report_destroy(&report)
	paths, paths_ok := preparation_paths(&report.transaction)
	testing.expect(t, paths_ok)
	owned_test_payload(t, paths.payload_final, "old.txt")
	owned_test_payload(t, paths.payload_next, "new.txt")
	payload, payload_ok := owned_commit_start(
		paths.payload_next,
		paths.payload_final,
		paths.payload_backup,
		.Payload,
		rename_with_retry,
	)
	testing.expect(t, payload_ok)
	report.transaction.payload_committed = payload.committed
	testing.expect(t, prepare_owned_payload_staging(paths.payload_next))

	testing.expect(t, !prepare_rollback(&report))
	testing.expect_value(
		t,
		report.transaction.state,
		Preparation_Transaction_State.Rollback_Failed,
	)
	old_payload, _ := filepath.join({paths.payload_backup, "old.txt"})
	new_payload, _ := filepath.join({paths.payload_final, "new.txt"})
	testing.expect(t, os.exists(old_payload))
	testing.expect(t, os.exists(new_payload))
	testing.expect(t, owned_path(paths.payload_backup, .Payload))
	testing.expect(t, owned_path(paths.payload_final, .Payload))
}

@(test)
test_preparation_late_rollback_failure_retains_all_owned_generations :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := install_test_directory(t)
	defer os.remove_all(root)
	install_root, _ := filepath.join({root, "install"})
	c_drive, _ := filepath.join({root, "c_drive"})
	testing.expect(t, os.make_directory(install_root) == nil)
	testing.expect(t, os.make_directory(c_drive) == nil)

	report: Report
	preparation_transaction_init(&report.transaction, install_root, c_drive)
	defer report_destroy(&report)
	paths, paths_ok := preparation_paths(&report.transaction)
	testing.expect(t, paths_ok)
	owned_test_payload(t, paths.payload_final, "old.txt")
	owned_test_payload(t, paths.payload_next, "new.txt")
	owned_test_launcher(t, paths.launcher_final, "OLD.EXE")
	owned_test_launcher(t, paths.launcher_next, "NEW.EXE")
	payload, launcher, result := owned_install_commit_start(
		paths.payload_next,
		paths.payload_final,
		paths.payload_backup,
		paths.launcher_next,
		paths.launcher_final,
		paths.launcher_backup,
		rename_with_retry,
	)
	testing.expect_value(t, result, Owned_Install_Result.Success)
	report.transaction.payload_committed = payload.committed
	report.transaction.launcher_committed = launcher.committed

	testing.expect(
		t,
		!prepare_rollback_with_rename(&report, owned_test_fail_payload_restore_after_launcher),
	)
	testing.expect_value(t, report.diagnostic, Diagnostic.Rollback_Failed)
	testing.expect_value(
		t,
		report.transaction.state,
		Preparation_Transaction_State.Rollback_Failed,
	)

	launcher_current := owned_test_read(t, paths.launcher_final)
	defer delete(launcher_current)
	launcher_next := owned_test_read(t, paths.launcher_next)
	defer delete(launcher_next)
	testing.expect(t, contains(launcher_current, "OLD.EXE"))
	testing.expect(t, contains(launcher_next, "NEW.EXE"))
	payload_old, _ := filepath.join({paths.payload_backup, "old.txt"})
	payload_new, _ := filepath.join({paths.payload_final, "new.txt"})
	testing.expect(t, os.exists(payload_old))
	testing.expect(t, os.exists(payload_new))
	testing.expect(t, owned_path(paths.payload_backup, .Payload))
	testing.expect(t, owned_path(paths.payload_final, .Payload))
}

@(test)
test_preparation_scratch_restore_failure_retains_recovery_generations :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := install_test_directory(t)
	defer os.remove_all(root)
	install_root, _ := filepath.join({root, "install"})
	c_drive, _ := filepath.join({root, "c_drive"})
	testing.expect(t, os.make_directory(install_root) == nil)
	testing.expect(t, os.make_directory(c_drive) == nil)

	report: Report
	preparation_transaction_init(&report.transaction, install_root, c_drive)
	paths, paths_ok := preparation_paths(&report.transaction)
	testing.expect(t, paths_ok)
	testing.expect(t, os.make_directory(paths.scratch_final) == nil)
	testing.expect(t, os.make_directory(paths.scratch_next) == nil)
	old_file, _ := filepath.join({paths.scratch_final, "OLD.CAB"})
	new_file, _ := filepath.join({paths.scratch_next, "NEW.CAB"})
	testing.expect(t, os.write_entire_file(old_file, "old") == nil)
	testing.expect(t, os.write_entire_file(new_file, "new") == nil)

	transaction, commit_ok := path_commit_start(
		paths.scratch_next,
		paths.scratch_final,
		paths.scratch_backup,
		owned_test_fail_scratch_commit_and_restore,
	)
	testing.expect(t, !commit_ok)
	testing.expect(t, transaction.rollback_failed)
	testing.expect(t, !preparation_apply_scratch_commit_result(&report, &transaction, commit_ok))
	testing.expect_value(t, report.diagnostic, Diagnostic.Rollback_Failed)
	testing.expect_value(
		t,
		report.transaction.state,
		Preparation_Transaction_State.Rollback_Failed,
	)
	preparation_failure_finalize(&report, &paths)
	testing.expect(t, !os.exists(paths.scratch_final))
	testing.expect(t, os.exists(paths.scratch_next))
	testing.expect(t, os.exists(paths.scratch_backup))
	testing.expect(t, os.exists(new_file))
	old_backup_file, _ := filepath.join({paths.scratch_backup, "OLD.CAB"})
	testing.expect(t, os.exists(old_backup_file))

	report_destroy(&report)
	testing.expect(t, os.exists(paths.scratch_next))
	testing.expect(t, os.exists(paths.scratch_backup))
	testing.expect(t, os.exists(new_file))
	testing.expect(t, os.exists(old_backup_file))
}

@(test)
test_preparation_owned_commit_rollback_failure_retains_every_generation :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := install_test_directory(t)
	defer os.remove_all(root)
	install_root, _ := filepath.join({root, "install"})
	c_drive, _ := filepath.join({root, "c_drive"})
	testing.expect(t, os.make_directory(install_root) == nil)
	testing.expect(t, os.make_directory(c_drive) == nil)

	report: Report
	preparation_transaction_init(&report.transaction, install_root, c_drive)
	paths, paths_ok := preparation_paths(&report.transaction)
	testing.expect(t, paths_ok)
	scratch_generations := [3]string{paths.scratch_next, paths.scratch_final, paths.scratch_backup}
	for path in scratch_generations {
		testing.expect(t, os.make_directory(path) == nil)
		marker, _ := filepath.join({path, "GENERATION.TXT"})
		testing.expect(t, os.write_entire_file(marker, path) == nil)
	}
	report.transaction.scratch_committed = true

	archive_path, _ := filepath.join({install_root, "recovery-retained"})
	testing.expect(t, os.make_directory(archive_path) == nil)
	archive_marker, _ := filepath.join({archive_path, "SYSTEM.NEW"})
	testing.expect(t, os.write_entire_file(archive_marker, "registry") == nil)
	report.retry_cleanup.archive_path = strings.clone(archive_path)
	report.retry_cleanup.archived_count = 1
	report.transaction.retry_archived = true

	owned_test_payload(t, paths.payload_final, "old.txt")
	owned_test_payload(t, paths.payload_next, "new.txt")
	owned_test_launcher(t, paths.launcher_final, "OLD.EXE")
	owned_test_launcher(t, paths.launcher_next, "NEW.EXE")
	payload, launcher, result := owned_install_commit_start(
		paths.payload_next,
		paths.payload_final,
		paths.payload_backup,
		paths.launcher_next,
		paths.launcher_final,
		paths.launcher_backup,
		owned_test_fail_launcher_commit_and_restore,
	)
	testing.expect_value(t, result, Owned_Install_Result.Rollback_Failed)
	testing.expect(t, payload.committed)
	testing.expect(t, launcher.rollback_failed)
	testing.expect(t, !preparation_apply_owned_commit_result(&report, &payload, &launcher, result))
	testing.expect_value(t, report.diagnostic, Diagnostic.Rollback_Failed)
	testing.expect_value(
		t,
		report.transaction.state,
		Preparation_Transaction_State.Rollback_Failed,
	)
	preparation_failure_finalize(&report, &paths)

	for path in scratch_generations {
		testing.expect(t, os.exists(path))
	}
	testing.expect(t, owned_path(paths.payload_final, .Payload))
	testing.expect(t, owned_path(paths.payload_backup, .Payload))
	testing.expect(t, owned_path(paths.launcher_next, .Launcher))
	testing.expect(t, owned_path(paths.launcher_backup, .Launcher))
	testing.expect(t, !os.exists(paths.launcher_final))
	testing.expect(t, os.exists(archive_marker))

	report_destroy(&report)
	for path in scratch_generations {
		testing.expect(t, os.exists(path))
	}
	testing.expect(t, owned_path(paths.payload_final, .Payload))
	testing.expect(t, owned_path(paths.payload_backup, .Payload))
	testing.expect(t, owned_path(paths.launcher_next, .Launcher))
	testing.expect(t, owned_path(paths.launcher_backup, .Launcher))
	testing.expect(t, os.exists(archive_marker))
}

@(test)
test_preparation_finish_keeps_new_generation_after_report_destroy :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := install_test_directory(t)
	defer os.remove_all(root)
	install_root, _ := filepath.join({root, "install"})
	c_drive, _ := filepath.join({root, "c_drive"})
	testing.expect(t, os.make_directory(install_root) == nil)
	testing.expect(t, os.make_directory(c_drive) == nil)

	report: Report
	preparation_transaction_init(&report.transaction, install_root, c_drive)
	paths, paths_ok := preparation_paths(&report.transaction)
	testing.expect(t, paths_ok)
	owned_test_payload(t, paths.payload_final, "old.txt")
	owned_test_payload(t, paths.payload_next, "new.txt")
	payload, payload_ok := owned_commit_start(
		paths.payload_next,
		paths.payload_final,
		paths.payload_backup,
		.Payload,
		rename_with_retry,
	)
	testing.expect(t, payload_ok)
	report.transaction.payload_committed = payload.committed
	testing.expect(t, prepare_finish(&report))
	report_destroy(&report)

	old_payload, _ := filepath.join({c_drive, PAYLOAD_FINAL_NAME, "old.txt"})
	new_payload, _ := filepath.join({c_drive, PAYLOAD_FINAL_NAME, "new.txt"})
	backup, _ := filepath.join({c_drive, PAYLOAD_BACKUP_NAME})
	testing.expect(t, !os.exists(old_payload))
	testing.expect(t, os.exists(new_payload))
	testing.expect(t, !os.exists(backup))
}

@(private)
install_test_directory :: proc(t: ^testing.T) -> string {
	base, base_error := os.temp_directory(context.allocator)
	testing.expect(t, base_error == nil)
	dir, dir_error := os.make_directory_temp(base, "retvrn99_win98install_*", context.allocator)
	testing.expect(t, dir_error == nil)
	return dir
}

@(private)
owned_test_paths :: proc(
	root: string,
) -> (
	payload_next,
	payload_current,
	payload_backup,
	launcher_next,
	launcher_current,
	launcher_backup: string,
) {
	payload_next, _ = filepath.join({root, PAYLOAD_STAGING_NAME})
	payload_current, _ = filepath.join({root, PAYLOAD_FINAL_NAME})
	payload_backup, _ = filepath.join({root, PAYLOAD_BACKUP_NAME})
	launcher_next, _ = filepath.join({root, LAUNCHER_STAGING_NAME})
	launcher_current, _ = filepath.join({root, LAUNCHER_FINAL_NAME})
	launcher_backup, _ = filepath.join({root, LAUNCHER_BACKUP_NAME})
	return
}

@(private)
owned_test_payload :: proc(t: ^testing.T, path, filename: string) {
	testing.expect(t, prepare_owned_payload_staging(path))
	file, _ := filepath.join({path, filename})
	defer delete(file)
	testing.expect(t, os.write_entire_file(file, filename) == nil)
}

@(private)
owned_test_launcher :: proc(t: ^testing.T, path, executable: string) {
	testing.expect(t, write_owned_launcher_staging(path, launcher_text(executable, false)))
}

@(private)
owned_test_fail_launcher_commit :: proc(old_path, new_path: string) -> bool {
	if strings.has_suffix(old_path, LAUNCHER_STAGING_NAME) &&
	   strings.has_suffix(new_path, LAUNCHER_FINAL_NAME) {
		return false
	}
	return os.rename(old_path, new_path) == nil
}

@(private)
owned_test_fail_launcher_commit_and_restore :: proc(old_path, new_path: string) -> bool {
	launcher_commit :=
		strings.has_suffix(old_path, LAUNCHER_STAGING_NAME) &&
		strings.has_suffix(new_path, LAUNCHER_FINAL_NAME)
	launcher_restore :=
		strings.has_suffix(old_path, LAUNCHER_BACKUP_NAME) &&
		strings.has_suffix(new_path, LAUNCHER_FINAL_NAME)
	if launcher_commit || launcher_restore {return false}
	return os.rename(old_path, new_path) == nil
}

@(private)
owned_test_fail_payload_restore_after_launcher :: proc(old_path, new_path: string) -> bool {
	if strings.has_suffix(old_path, PAYLOAD_FINAL_NAME) &&
	   strings.has_suffix(new_path, PAYLOAD_STAGING_NAME) {
		return false
	}
	return os.rename(old_path, new_path) == nil
}

@(private)
owned_test_fail_scratch_commit_and_restore :: proc(old_path, new_path: string) -> bool {
	commit := strings.has_suffix(old_path, "win98.next") && strings.has_suffix(new_path, "win98")
	restore := strings.has_suffix(old_path, "win98.old") && strings.has_suffix(new_path, "win98")
	if commit || restore {return false}
	return os.rename(old_path, new_path) == nil
}

@(private)
owned_test_read :: proc(t: ^testing.T, path: string) -> string {
	contents, read_error := os.read_entire_file(path, context.allocator)
	testing.expect(t, read_error == nil)
	return string(contents)
}

@(private)
contains :: proc(haystack, needle: string) -> bool {
	if len(needle) == 0 {return true}
	if len(needle) > len(haystack) {return false}
	for i in 0 ..= len(haystack) - len(needle) {
		if haystack[i:i + len(needle)] == needle {return true}
	}
	return false
}
