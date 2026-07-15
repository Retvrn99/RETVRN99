// SPDX-License-Identifier: GPL-3.0-only
package win98prep

import profile "../profile"
import media "../win98media"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

PAYLOAD_STAGING_NAME :: "GSWSETUP.NXT"
PAYLOAD_FINAL_NAME :: "GSWSETUP"
PAYLOAD_BACKUP_NAME :: "GSWSETUP.PRV"
LAUNCHER_STAGING_NAME :: "GSWSETUP.NEW"
LAUNCHER_FINAL_NAME :: "GSWSETUP.BAT"
LAUNCHER_BACKUP_NAME :: "GSWSETUP.BAK"
PAYLOAD_MARKER_NAME :: "RETVRN99.OWN"
PAYLOAD_MARKER :: "RETVRN99 WINDOWS 98 SETUP PAYLOAD V1\r\n"
LAUNCHER_MARKER :: "@REM RETVRN99 WINDOWS 98 SETUP LAUNCHER V1\r\n"

Prepare_Options :: struct {
	desktop_probe:        bool,
	hardware_diagnostics: bool,
}

Diagnostic :: enum {
	None,
	Media_Rejected,
	Profile_Directory_Failed,
	Extract_Failed,
	Template_Failed,
	Guest_Copy_Failed,
	Commit_Failed,
	Launcher_Failed,
	Bootstrap_Failed,
	Recovery_Failed,
	Existing_Windows,
	Retry_Cleanup_Failed,
	Rollback_Failed,
}

Preparation_Transaction_State :: enum {
	Inactive,
	Pending,
	Finalized,
	Rolled_Back,
	Rollback_Failed,
}

Preparation_Transaction :: struct {
	state:              Preparation_Transaction_State,
	install_root:       string,
	c_drive:            string,
	scratch_committed:  bool,
	retry_archived:     bool,
	payload_committed:  bool,
	launcher_committed: bool,
	bootstrap:          Bootstrap_Transaction,
}

Report :: struct {
	media_info:           media.Media_Info,
	diagnostic:           Diagnostic,
	media_diagnostic:     media.Diagnostic,
	bootstrap_diagnostic: Bootstrap_Diagnostic,
	retry_cleanup:        Retry_Cleanup_Report,
	transaction:          Preparation_Transaction,
}

report_destroy :: proc(report: ^Report) {
	if report == nil {return}
	if report.transaction.state == .Pending {_ = prepare_rollback(report)}
	media.media_info_destroy(&report.media_info)
	retry_cleanup_report_destroy(&report.retry_cleanup)
	delete(report.transaction.install_root)
	delete(report.transaction.c_drive)
	report^ = {}
}

@(private)
Preparation_Paths :: struct {
	scratch_next:    string,
	scratch_final:   string,
	scratch_backup:  string,
	payload_next:    string,
	payload_final:   string,
	payload_backup:  string,
	launcher_next:   string,
	launcher_final:  string,
	launcher_backup: string,
}

@(private)
preparation_transaction_init :: proc(
	transaction: ^Preparation_Transaction,
	install_root, c_drive: string,
) {
	transaction^ = Preparation_Transaction {
		state        = .Pending,
		install_root = strings.clone(install_root),
		c_drive      = strings.clone(c_drive),
	}
}

@(private)
preparation_paths :: proc(transaction: ^Preparation_Transaction) -> (Preparation_Paths, bool) {
	if transaction == nil || transaction.install_root == "" || transaction.c_drive == "" {
		return {}, false
	}
	paths: Preparation_Paths
	err: os.Error
	paths.scratch_next, err = filepath.join(
		{transaction.install_root, "win98.next"},
		context.temp_allocator,
	)
	if err != nil {return {}, false}
	paths.scratch_final, err = filepath.join(
		{transaction.install_root, "win98"},
		context.temp_allocator,
	)
	if err != nil {return {}, false}
	paths.scratch_backup, err = filepath.join(
		{transaction.install_root, "win98.old"},
		context.temp_allocator,
	)
	if err != nil {return {}, false}
	paths.payload_next, err = filepath.join(
		{transaction.c_drive, PAYLOAD_STAGING_NAME},
		context.temp_allocator,
	)
	if err != nil {return {}, false}
	paths.payload_final, err = filepath.join(
		{transaction.c_drive, PAYLOAD_FINAL_NAME},
		context.temp_allocator,
	)
	if err != nil {return {}, false}
	paths.payload_backup, err = filepath.join(
		{transaction.c_drive, PAYLOAD_BACKUP_NAME},
		context.temp_allocator,
	)
	if err != nil {return {}, false}
	paths.launcher_next, err = filepath.join(
		{transaction.c_drive, LAUNCHER_STAGING_NAME},
		context.temp_allocator,
	)
	if err != nil {return {}, false}
	paths.launcher_final, err = filepath.join(
		{transaction.c_drive, LAUNCHER_FINAL_NAME},
		context.temp_allocator,
	)
	if err != nil {return {}, false}
	paths.launcher_backup, err = filepath.join(
		{transaction.c_drive, LAUNCHER_BACKUP_NAME},
		context.temp_allocator,
	)
	return paths, err == nil
}

prepare_finish :: proc(report: ^Report) -> bool {
	if report == nil {return false}
	if report.transaction.state == .Finalized {return true}
	if report.transaction.state != .Pending {return false}
	paths, paths_ok := preparation_paths(&report.transaction)
	if !paths_ok {return false}
	report.transaction.state = .Finalized
	ok := true
	if report.transaction.bootstrap.state == .Pending &&
	   !bootstrap_finish(&report.transaction.bootstrap, report.transaction.c_drive) {
		ok = false
	}

	if report.transaction.launcher_committed {
		transaction := owned_commit_from_paths(
			paths.launcher_next,
			paths.launcher_final,
			paths.launcher_backup,
			.Launcher,
		)
		if !owned_commit_finish(&transaction) {ok = false}
	}
	if report.transaction.payload_committed {
		transaction := owned_commit_from_paths(
			paths.payload_next,
			paths.payload_final,
			paths.payload_backup,
			.Payload,
		)
		if !owned_commit_finish(&transaction) {ok = false}
	}
	if report.transaction.scratch_committed {
		transaction := path_commit_from_paths(
			paths.scratch_next,
			paths.scratch_final,
			paths.scratch_backup,
		)
		if !path_commit_finish(&transaction) {ok = false}
	}
	return ok
}

prepare_rollback :: proc(report: ^Report) -> bool {
	return prepare_rollback_with_rename(report, rename_with_retry)
}

@(private)
prepare_rollback_with_rename :: proc(report: ^Report, rename_path: Owned_Rename_Proc) -> bool {
	if report == nil {return false}
	if report.transaction.state == .Rolled_Back {return true}
	if report.transaction.state != .Pending {return false}
	paths, paths_ok := preparation_paths(&report.transaction)
	if !paths_ok {
		report.transaction.state = .Rollback_Failed
		return false
	}

	launcher: Owned_Commit
	launcher_restored := false
	if report.transaction.bootstrap.state == .Pending &&
	   !bootstrap_rollback_with_rename(
			   &report.transaction.bootstrap,
			   report.transaction.c_drive,
			   bootstrap_rename_with_retry,
		   ) {
		report.transaction.state = .Rollback_Failed
		report.diagnostic = .Rollback_Failed
		return false
	}
	if report.transaction.launcher_committed {
		launcher = owned_commit_from_paths(
			paths.launcher_next,
			paths.launcher_final,
			paths.launcher_backup,
			.Launcher,
		)
		if !owned_commit_restore(&launcher, rename_path) {
			report.transaction.state = .Rollback_Failed
			report.diagnostic = .Rollback_Failed
			return false
		}
		launcher_restored = true
	}

	payload: Owned_Commit
	payload_restored := false
	if report.transaction.payload_committed {
		payload = owned_commit_from_paths(
			paths.payload_next,
			paths.payload_final,
			paths.payload_backup,
			.Payload,
		)
		if !owned_commit_restore(&payload, rename_path) {
			report.transaction.state = .Rollback_Failed
			report.diagnostic = .Rollback_Failed
			return false
		}
		payload_restored = true
	}

	scratch: Path_Commit
	scratch_restored := false
	if report.transaction.scratch_committed {
		scratch = path_commit_from_paths(
			paths.scratch_next,
			paths.scratch_final,
			paths.scratch_backup,
		)
		if !path_commit_restore(&scratch, rename_path) {
			report.transaction.state = .Rollback_Failed
			report.diagnostic = .Rollback_Failed
			return false
		}
		scratch_restored = true
	}

	if report.transaction.retry_archived &&
	   !retry_cleanup_restore(&report.retry_cleanup, report.transaction.c_drive) {
		report.transaction.state = .Rollback_Failed
		report.diagnostic = .Rollback_Failed
		return false
	}

	report.transaction.state = .Rolled_Back
	// Destructive cleanup starts only after every restore has succeeded.
	if launcher_restored {_ = owned_commit_rollback_cleanup(&launcher)}
	if payload_restored {_ = owned_commit_rollback_cleanup(&payload)}
	if scratch_restored {_ = path_commit_rollback_cleanup(&scratch)}
	return true
}

fallback_msbatch :: proc() -> string {
	return(
		`[BatchSetup]
Version=3.0 (32-bit)

[Version]
Signature="$CHICAGO$"
LayoutFile=layout.inf

[Setup]
Express=1
InstallDir="C:\WINDOWS"
InstallType=3
EBD=0
ShowEula=0
ChangeDir=0
Uninstall=0
NoPrompt2Boot=1
OptionalComponents=0
PenWinWarning=0

[NameAndOrg]
Name="RET VRN 99 User"
Org="RET VRN 99"
Display=0

[Network]
ComputerName="RETVRN99"
Workgroup="WORKGROUP"
Description="RET VRN 99"
Display=0
ValidateNetCardResources=0
` \
	)
}

prepare :: proc(
	iso_path, install_root, c_drive: string,
	boot_image_path := "",
	options: Prepare_Options = {},
) -> Report {
	report: Report
	if os.make_directory_all(install_root) != nil || os.make_directory_all(c_drive) != nil {
		report.diagnostic = .Profile_Directory_Failed
		return report
	}
	if !prepare_recover(install_root, c_drive) {
		report.diagnostic = .Recovery_Failed
		return report
	}
	report.media_info, report.media_diagnostic = media.inspect(iso_path)
	if report.media_diagnostic != .None {
		report.diagnostic = .Media_Rejected
		return report
	}
	preparation_transaction_init(&report.transaction, install_root, c_drive)
	paths, paths_ok := preparation_paths(&report.transaction)
	if !paths_ok {
		report.diagnostic = .Profile_Directory_Failed
		if !prepare_rollback(&report) {report.diagnostic = .Rollback_Failed}
		return report
	}
	defer preparation_failure_finalize(&report, &paths)
	bootstrap, bootstrap_diagnostic := bootstrap_install_with_rename(
		c_drive,
		boot_image_path,
		bootstrap_rename_with_retry,
	)
	report.bootstrap_diagnostic = bootstrap_diagnostic
	report.transaction.bootstrap = bootstrap
	if bootstrap_diagnostic == .Rollback_Failed {
		report.transaction.state = .Rollback_Failed
		report.diagnostic = .Rollback_Failed
		return report
	}
	if bootstrap_diagnostic != .None && bootstrap_diagnostic != .Existing_DOS {
		report.diagnostic = .Bootstrap_Failed
		return report
	}

	_ = os.remove_all(paths.scratch_next)

	if extract_diagnostic := media.extract_win98(iso_path, paths.scratch_next);
	   extract_diagnostic != .None {
		report.media_diagnostic = extract_diagnostic
		report.diagnostic = .Extract_Failed
		return report
	}
	template_path, _ := filepath.join({paths.scratch_next, "MSBATCH.INF"}, context.temp_allocator)
	defer delete(template_path, context.temp_allocator)
	template_diagnostic := media.extract_msbatch_template(iso_path, template_path)
	if template_diagnostic == .Template_Missing {
		if os.write_entire_file(template_path, fallback_msbatch()) != nil {
			report.diagnostic = .Template_Failed
			return report
		}
	} else if template_diagnostic != .None {
		report.media_diagnostic = template_diagnostic
		report.diagnostic = .Template_Failed
		return report
	}
	if !normalize_msbatch_file(template_path, options.desktop_probe) {
		report.diagnostic = .Template_Failed
		return report
	}
	if options.desktop_probe && !desktop_probe_write(paths.scratch_next) {
		report.diagnostic = .Template_Failed
		return report
	}

	scratch_commit, scratch_ok := path_commit_start(
		paths.scratch_next,
		paths.scratch_final,
		paths.scratch_backup,
		rename_with_retry,
	)
	if !preparation_apply_scratch_commit_result(&report, &scratch_commit, scratch_ok) {
		return report
	}

	if !owned_install_paths_safe(
		paths.payload_next,
		paths.payload_final,
		paths.payload_backup,
		paths.launcher_next,
		paths.launcher_final,
		paths.launcher_backup,
	) {
		report.diagnostic = .Commit_Failed
		return report
	}

	report.retry_cleanup = retry_cleanup_archive(c_drive, install_root)
	report.transaction.retry_archived =
		report.retry_cleanup.archived_count > 0 && report.retry_cleanup.archive_path != ""
	if report.retry_cleanup.diagnostic == .Existing_Windows {
		report.diagnostic = .Existing_Windows
		return report
	}
	if report.retry_cleanup.diagnostic != .None {
		report.diagnostic = .Retry_Cleanup_Failed
		return report
	}

	if !prepare_owned_payload_staging(paths.payload_next) {
		report.diagnostic = .Guest_Copy_Failed
		return report
	}
	if !copy_directory_tree(paths.payload_next, paths.scratch_final) {
		report.diagnostic = .Guest_Copy_Failed
		return report
	}
	if !owned_path(paths.payload_next, .Payload) {
		report.diagnostic = .Guest_Copy_Failed
		return report
	}
	command := launcher_text(
		report.media_info.setup_executable,
		profile.dos_seed_is_managed(c_drive),
		true,
		options.hardware_diagnostics,
	)
	if !write_owned_launcher_staging(paths.launcher_next, command) {
		report.diagnostic = .Launcher_Failed
		return report
	}
	payload_commit, launcher_commit, commit_result := owned_install_commit_start(
		paths.payload_next,
		paths.payload_final,
		paths.payload_backup,
		paths.launcher_next,
		paths.launcher_final,
		paths.launcher_backup,
		rename_with_retry,
	)
	if !preparation_apply_owned_commit_result(
		&report,
		&payload_commit,
		&launcher_commit,
		commit_result,
	) {
		return report
	}
	return report
}

@(private)
bootstrap_rename_with_retry :: proc(old_path, new_path: string) -> os.Error {
	if rename_with_retry(old_path, new_path) {return nil}
	return os.General_Error.Invalid_Path
}

@(private)
preparation_failure_finalize :: proc(report: ^Report, paths: ^Preparation_Paths) {
	if report == nil || paths == nil || report.diagnostic == .None {return}
	if report.transaction.state == .Pending && !prepare_rollback(report) {
		report.diagnostic = .Rollback_Failed
	}
	if report.transaction.state == .Rollback_Failed {return}
	_ = os.remove_all(paths.scratch_next)
	_ = remove_owned_path(paths.payload_next, .Payload)
	_ = remove_owned_path(paths.launcher_next, .Launcher)
}

@(private)
preparation_apply_scratch_commit_result :: proc(
	report: ^Report,
	transaction: ^Path_Commit,
	ok: bool,
) -> bool {
	if report == nil || transaction == nil {return false}
	if ok {
		report.transaction.scratch_committed = transaction.committed
		return true
	}
	if transaction.rollback_failed {
		report.transaction.state = .Rollback_Failed
		report.diagnostic = .Rollback_Failed
	} else {
		report.diagnostic = .Commit_Failed
	}
	return false
}

@(private)
preparation_apply_owned_commit_result :: proc(
	report: ^Report,
	payload, launcher: ^Owned_Commit,
	result: Owned_Install_Result,
) -> bool {
	if report == nil || payload == nil || launcher == nil {return false}
	report.transaction.payload_committed = payload.committed
	report.transaction.launcher_committed = launcher.committed
	switch result {
	case .Payload_Failed:
		report.diagnostic = .Commit_Failed
		return false
	case .Launcher_Failed:
		report.diagnostic = .Launcher_Failed
		return false
	case .Rollback_Failed:
		report.transaction.state = .Rollback_Failed
		report.diagnostic = .Rollback_Failed
		return false
	case .Success:
		report.diagnostic = .None
		return true
	}
	return false
}

@(private)
launcher_text :: proc(
	setup_executable: string,
	enable_boot_gui: bool,
	restore_autoexec := false,
	hardware_diagnostics := false,
) -> string {
	boot_options := ""
	if enable_boot_gui {
		boot_options = "ECHO [Options]>C:\\MSDOS.SYS\r\nECHO Logo=0>>C:\\MSDOS.SYS\r\nECHO BootGUI=1>>C:\\MSDOS.SYS\r\n"
	}
	autoexec_restore := ""
	if restore_autoexec {
		autoexec_restore =
			"IF EXIST C:\\GSWAUTO.PRV GOTO GSWAR\r\n" +
			"DEL C:\\AUTOEXEC.BAT >NUL\r\n" +
			"IF EXIST C:\\AUTOEXEC.BAT GOTO GSWAE\r\n" +
			"GOTO GSWAGO\r\n" +
			":GSWAR\r\n" +
			"DEL C:\\AUTOEXEC.BAT >NUL\r\n" +
			"IF EXIST C:\\AUTOEXEC.BAT GOTO GSWAE\r\n" +
			"REN C:\\GSWAUTO.PRV AUTOEXEC.BAT\r\n" +
			"IF EXIST C:\\GSWAUTO.PRV GOTO GSWAE\r\n" +
			"IF NOT EXIST C:\\AUTOEXEC.BAT GOTO GSWAE\r\n" +
			"GOTO GSWAGO\r\n" +
			":GSWAE\r\n" +
			"ECHO Cannot restore C:\\AUTOEXEC.BAT; Setup was not started.\r\n" +
			"GOTO GSWEND\r\n" +
			":GSWAGO\r\n"
	}
	detection_options := hardware_diagnostics ? " /P G=3;L=3;P" : ""
	return fmt.tprintf(
		"%s@ECHO OFF\r\n%s%sC:\r\nCD \\GSWSETUP\r\n%s MSBATCH.INF /C /IS /IQ /IM /IV%s\r\n:GSWEND\r\n",
		LAUNCHER_MARKER,
		autoexec_restore,
		boot_options,
		setup_executable,
		detection_options,
	)
}

@(private)
Owned_Path_Kind :: enum {
	Payload,
	Launcher,
}

@(private)
Owned_Rename_Proc :: #type proc(old_path, new_path: string) -> bool

@(private)
Owned_Commit :: struct {
	next:            string,
	current:         string,
	backup:          string,
	kind:            Owned_Path_Kind,
	had_current:     bool,
	committed:       bool,
	rollback_failed: bool,
}

@(private)
Owned_Install_Result :: enum {
	Success,
	Payload_Failed,
	Launcher_Failed,
	Rollback_Failed,
}

@(private)
owned_install_paths_safe :: proc(
	payload_next, payload_current, payload_backup: string,
	launcher_next, launcher_current, launcher_backup: string,
) -> bool {
	return(
		owned_path_available(payload_next, .Payload) &&
		owned_path_available(payload_current, .Payload) &&
		owned_path_available(payload_backup, .Payload) &&
		owned_path_available(launcher_next, .Launcher) &&
		owned_path_available(launcher_current, .Launcher) &&
		owned_path_available(launcher_backup, .Launcher) \
	)
}

@(private)
owned_path_available :: proc(path: string, kind: Owned_Path_Kind) -> bool {
	return !os.exists(path) || owned_path(path, kind)
}

@(private)
owned_path :: proc(path: string, kind: Owned_Path_Kind) -> bool {
	switch kind {
	case .Payload:
		marker_path, path_error := filepath.join(
			{path, PAYLOAD_MARKER_NAME},
			context.temp_allocator,
		)
		if path_error != nil {return false}
		defer delete(marker_path, context.temp_allocator)
		marker, read_error := os.read_entire_file(marker_path, context.temp_allocator)
		if read_error != nil {return false}
		defer delete(marker, context.temp_allocator)
		return string(marker) == PAYLOAD_MARKER
	case .Launcher:
		launcher, read_error := os.read_entire_file(path, context.temp_allocator)
		if read_error != nil {return false}
		defer delete(launcher, context.temp_allocator)
		return strings.has_prefix(string(launcher), LAUNCHER_MARKER)
	}
	return false
}

@(private)
remove_owned_path :: proc(path: string, kind: Owned_Path_Kind) -> bool {
	if !os.exists(path) {return true}
	if !owned_path(path, kind) {return false}
	switch kind {
	case .Payload:
		return os.remove_all(path) == nil
	case .Launcher:
		return os.remove(path) == nil
	}
	return false
}

@(private)
prepare_owned_payload_staging :: proc(path: string) -> bool {
	if !owned_path_available(path, .Payload) {return false}
	if os.exists(path) && !remove_owned_path(path, .Payload) {return false}
	if os.make_directory(path) != nil {return false}
	marker_path, path_error := filepath.join({path, PAYLOAD_MARKER_NAME}, context.temp_allocator)
	if path_error != nil {return false}
	defer delete(marker_path, context.temp_allocator)
	return os.write_entire_file(marker_path, PAYLOAD_MARKER) == nil
}

@(private)
write_owned_launcher_staging :: proc(path, launcher: string) -> bool {
	if !owned_path_available(path, .Launcher) {return false}
	if os.exists(path) && !remove_owned_path(path, .Launcher) {return false}
	return(
		strings.has_prefix(launcher, LAUNCHER_MARKER) &&
		os.write_entire_file(path, launcher) == nil \
	)
}

@(private)
owned_install_commit :: proc(
	payload_next, payload_current, payload_backup: string,
	launcher_next, launcher_current, launcher_backup: string,
	rename_path: Owned_Rename_Proc,
) -> Owned_Install_Result {
	payload, launcher, result := owned_install_commit_start(
		payload_next,
		payload_current,
		payload_backup,
		launcher_next,
		launcher_current,
		launcher_backup,
		rename_path,
	)
	if result != .Success {return result}
	_ = owned_commit_finish(&launcher)
	_ = owned_commit_finish(&payload)
	return .Success
}

@(private)
owned_install_commit_start :: proc(
	payload_next, payload_current, payload_backup: string,
	launcher_next, launcher_current, launcher_backup: string,
	rename_path: Owned_Rename_Proc,
) -> (
	payload, launcher: Owned_Commit,
	result: Owned_Install_Result,
) {
	payload_ok: bool
	payload, payload_ok = owned_commit_start(
		payload_next,
		payload_current,
		payload_backup,
		.Payload,
		rename_path,
	)
	if !payload_ok {
		if payload.rollback_failed {return payload, launcher, .Rollback_Failed}
		return payload, launcher, .Payload_Failed
	}

	launcher_ok: bool
	launcher, launcher_ok = owned_commit_start(
		launcher_next,
		launcher_current,
		launcher_backup,
		.Launcher,
		rename_path,
	)
	if !launcher_ok {
		if launcher.rollback_failed {return payload, launcher, .Rollback_Failed}
		if !owned_commit_rollback(&payload, rename_path) {
			return payload, launcher, .Rollback_Failed
		}
		_ = remove_owned_path(launcher_next, .Launcher)
		return payload, launcher, .Launcher_Failed
	}
	return payload, launcher, .Success
}

@(private)
owned_commit_start :: proc(
	next, current, backup: string,
	kind: Owned_Path_Kind,
	rename_path: Owned_Rename_Proc,
) -> (
	transaction: Owned_Commit,
	ok: bool,
) {
	transaction = Owned_Commit {
		next    = next,
		current = current,
		backup  = backup,
		kind    = kind,
	}
	if !owned_path(next, kind) ||
	   !owned_path_available(current, kind) ||
	   !owned_path_available(backup, kind) {
		return transaction, false
	}
	if os.exists(backup) && !remove_owned_path(backup, kind) {
		return transaction, false
	}
	transaction.had_current = os.exists(current)
	if transaction.had_current && !rename_path(current, backup) {
		return transaction, false
	}
	if !rename_path(next, current) {
		if transaction.had_current && !rename_path(backup, current) {
			transaction.rollback_failed = true
		}
		return transaction, false
	}
	transaction.committed = true
	return transaction, true
}

@(private)
owned_commit_from_paths :: proc(
	next, current, backup: string,
	kind: Owned_Path_Kind,
) -> Owned_Commit {
	return Owned_Commit {
		next = next,
		current = current,
		backup = backup,
		kind = kind,
		had_current = os.exists(backup),
		committed = true,
	}
}

@(private)
owned_commit_rollback :: proc(transaction: ^Owned_Commit, rename_path: Owned_Rename_Proc) -> bool {
	if transaction == nil || !transaction.committed {return true}
	if !owned_commit_restore(transaction, rename_path) {return false}
	return owned_commit_rollback_cleanup(transaction)
}

@(private)
owned_commit_restore :: proc(transaction: ^Owned_Commit, rename_path: Owned_Rename_Proc) -> bool {
	if transaction == nil || !transaction.committed {return true}
	if !owned_path(transaction.current, transaction.kind) {return false}
	if os.exists(transaction.next) {return false}
	if !transaction.had_current {
		if !rename_path(transaction.current, transaction.next) {return false}
		transaction.committed = false
		return true
	}
	if !owned_path(transaction.backup, transaction.kind) ||
	   !rename_path(transaction.current, transaction.next) {
		return false
	}
	if !rename_path(transaction.backup, transaction.current) {
		_ = rename_path(transaction.next, transaction.current)
		return false
	}
	transaction.committed = false
	return true
}

@(private)
owned_commit_rollback_cleanup :: proc(transaction: ^Owned_Commit) -> bool {
	if transaction == nil {return false}
	return remove_owned_path(transaction.next, transaction.kind)
}

@(private)
owned_commit_finish :: proc(transaction: ^Owned_Commit) -> bool {
	if transaction == nil || !transaction.committed || !transaction.had_current {return true}
	return remove_owned_path(transaction.backup, transaction.kind)
}

@(private)
Path_Commit :: struct {
	next:            string,
	current:         string,
	backup:          string,
	had_current:     bool,
	committed:       bool,
	rollback_failed: bool,
}

@(private)
path_commit_start :: proc(
	next, current, backup: string,
	rename_path: Owned_Rename_Proc,
) -> (
	transaction: Path_Commit,
	ok: bool,
) {
	transaction = Path_Commit {
		next    = next,
		current = current,
		backup  = backup,
	}
	if os.exists(backup) && os.remove_all(backup) != nil {return transaction, false}
	transaction.had_current = os.exists(current)
	if transaction.had_current && !rename_path(current, backup) {return transaction, false}
	if !rename_path(next, current) {
		if transaction.had_current && !rename_path(backup, current) {
			transaction.rollback_failed = true
		}
		return transaction, false
	}
	transaction.committed = true
	return transaction, true
}

@(private)
path_commit_from_paths :: proc(next, current, backup: string) -> Path_Commit {
	return Path_Commit {
		next = next,
		current = current,
		backup = backup,
		had_current = os.exists(backup),
		committed = true,
	}
}

@(private)
path_commit_rollback :: proc(transaction: ^Path_Commit, rename_path: Owned_Rename_Proc) -> bool {
	if transaction == nil || !transaction.committed {return true}
	if !path_commit_restore(transaction, rename_path) {return false}
	return path_commit_rollback_cleanup(transaction)
}

@(private)
path_commit_restore :: proc(transaction: ^Path_Commit, rename_path: Owned_Rename_Proc) -> bool {
	if transaction == nil || !transaction.committed {return true}
	if !os.exists(transaction.current) {return false}
	if os.exists(transaction.next) {return false}
	if !transaction.had_current {
		if !rename_path(transaction.current, transaction.next) {return false}
		transaction.committed = false
		return true
	}
	if !os.exists(transaction.backup) || !rename_path(transaction.current, transaction.next) {
		return false
	}
	if !rename_path(transaction.backup, transaction.current) {
		_ = rename_path(transaction.next, transaction.current)
		return false
	}
	transaction.committed = false
	return true
}

@(private)
path_commit_rollback_cleanup :: proc(transaction: ^Path_Commit) -> bool {
	if transaction == nil {return false}
	if !os.exists(transaction.next) {return true}
	return os.remove_all(transaction.next) == nil
}

@(private)
path_commit_finish :: proc(transaction: ^Path_Commit) -> bool {
	if transaction == nil || !transaction.committed || !transaction.had_current {return true}
	return os.remove_all(transaction.backup) == nil
}

@(private)
replace_path :: proc(next, current, backup: string) -> bool {
	transaction, ok := path_commit_start(next, current, backup, rename_with_retry)
	if !ok {return false}
	return path_commit_finish(&transaction)
}

@(private)
rename_with_retry :: proc(old_path, new_path: string) -> bool {
	for attempt in 0 ..< 20 {
		if os.rename(old_path, new_path) == nil {return true}
		if attempt < 19 {time.sleep(25 * time.Millisecond)}
	}
	return false
}
