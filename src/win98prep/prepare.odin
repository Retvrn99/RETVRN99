// SPDX-License-Identifier: GPL-3.0-only
package win98prep

import media "../win98media"
import profile "../profile"
import "core:fmt"
import "core:os"
import "core:path/filepath"

Diagnostic :: enum {
	None,
	Media_Rejected,
	Profile_Directory_Failed,
	Extract_Failed,
	Template_Failed,
	Guest_Copy_Failed,
	Commit_Failed,
	Launcher_Failed,
}

Report :: struct {
	media_info:       media.Media_Info,
	diagnostic:       Diagnostic,
	media_diagnostic: media.Diagnostic,
}

report_destroy :: proc(report: ^Report) {
	if report == nil {return}
	media.media_info_destroy(&report.media_info)
	report^ = {}
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
` \
	)
}

prepare :: proc(iso_path, install_root, c_drive: string) -> Report {
	report: Report
	report.media_info, report.media_diagnostic = media.inspect(iso_path)
	if report.media_diagnostic != .None {
		report.diagnostic = .Media_Rejected
		return report
	}

	if os.make_directory_all(install_root) != nil || os.make_directory_all(c_drive) != nil {
		report.diagnostic = .Profile_Directory_Failed
		return report
	}

	scratch_next, _ := filepath.join({install_root, "win98.next"}, context.temp_allocator)
	scratch_final, _ := filepath.join({install_root, "win98"}, context.temp_allocator)
	scratch_old, _ := filepath.join({install_root, "win98.old"}, context.temp_allocator)
	defer delete(scratch_next, context.temp_allocator)
	defer delete(scratch_final, context.temp_allocator)
	defer delete(scratch_old, context.temp_allocator)
	_ = os.remove_all(scratch_next)

	if extract_diagnostic := media.extract_win98(iso_path, scratch_next);
	   extract_diagnostic != .None {
		report.media_diagnostic = extract_diagnostic
		report.diagnostic = .Extract_Failed
		return report
	}
	defer _ = os.remove_all(scratch_next)

	template_path, _ := filepath.join({scratch_next, "MSBATCH.INF"}, context.temp_allocator)
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

	if !replace_path(scratch_next, scratch_final, scratch_old) {
		report.diagnostic = .Commit_Failed
		return report
	}

	guest_next, _ := filepath.join({c_drive, "GSWSETUP.next"}, context.temp_allocator)
	guest_final, _ := filepath.join({c_drive, "GSWSETUP"}, context.temp_allocator)
	guest_old, _ := filepath.join({c_drive, "GSWSETUP.old"}, context.temp_allocator)
	defer delete(guest_next, context.temp_allocator)
	defer delete(guest_final, context.temp_allocator)
	defer delete(guest_old, context.temp_allocator)
	_ = os.remove_all(guest_next)
	defer _ = os.remove_all(guest_next)
	if os.copy_directory_all(guest_next, scratch_final) != nil {
		report.diagnostic = .Guest_Copy_Failed
		return report
	}
	if !replace_path(guest_next, guest_final, guest_old) {
		report.diagnostic = .Commit_Failed
		return report
	}

	launcher_new, _ := filepath.join({c_drive, "GSWSETUP.NEW"}, context.temp_allocator)
	launcher, _ := filepath.join({c_drive, "GSWSETUP.BAT"}, context.temp_allocator)
	launcher_old, _ := filepath.join({c_drive, "GSWSETUP.OLD"}, context.temp_allocator)
	defer delete(launcher_new, context.temp_allocator)
	defer delete(launcher, context.temp_allocator)
	defer delete(launcher_old, context.temp_allocator)
	_ = os.remove_all(launcher_new)
	command := launcher_text(
		report.media_info.setup_executable,
		profile.dos_seed_is_managed(c_drive),
	)
	if os.write_entire_file(launcher_new, command) != nil {
		report.diagnostic = .Launcher_Failed
		return report
	}
	if !replace_path(launcher_new, launcher, launcher_old) {
		report.diagnostic = .Launcher_Failed
		return report
	}

	report.diagnostic = .None
	return report
}

@(private)
launcher_text :: proc(setup_executable: string, enable_boot_gui: bool) -> string {
	boot_options := ""
	if enable_boot_gui {
		boot_options = "ECHO [Options]>C:\\MSDOS.SYS\r\nECHO Logo=0>>C:\\MSDOS.SYS\r\nECHO BootGUI=1>>C:\\MSDOS.SYS\r\n"
	}
	return fmt.tprintf(
		"@ECHO OFF\r\n%sC:\r\nCD \\GSWSETUP\r\n%s MSBATCH.INF /IS /IQ /IM /IV\r\n",
		boot_options,
		setup_executable,
	)
}

@(private)
replace_path :: proc(next, current, backup: string) -> bool {
	_ = os.remove_all(backup)
	had_current := os.exists(current)
	if had_current && os.rename(current, backup) != nil {
		return false
	}
	if os.rename(next, current) != nil {
		if had_current {_ = os.rename(backup, current)}
		return false
	}
	if had_current {_ = os.remove_all(backup)}
	return true
}
