// SPDX-License-Identifier: GPL-3.0-only
package win98prep

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
test_normalize_msbatch_suppresses_component_dialog :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	template := "[Setup]\r\nExpress=1\r\nOptionalComponents=1\r\nNoPrompt2Boot=1\r\nNetwork=1\r\n\r\n[OptionalComponents]\r\nJuegos=0\r\n\r\n[Network]\r\nDisplay=0\r\n"
	normalized, ok := normalize_msbatch(template)
	testing.expect(t, ok)
	testing.expect(t, contains(normalized, "OptionalComponents=0\r\n"))
	testing.expect(t, !contains(normalized, "OptionalComponents=1"))
	testing.expect(t, contains(normalized, "Express=1\r\n"))
	testing.expect(t, contains(normalized, `ProductKey="RW9MG-QR4G3-2WRR9-TG7BH-33GXB"`))
	testing.expect(t, contains(normalized, "ShowEula=0\r\n"))
	testing.expect(t, contains(normalized, "EBD=0\r\n"))
	testing.expect(t, contains(normalized, "NoPrompt2Boot=1\r\n"))
	testing.expect(t, contains(normalized, "PenWinWarning=0\r\n"))
	testing.expect(t, contains(normalized, "ValidateNetCardResources=0\r\n"))
	testing.expect(t, contains(normalized, "[Install]\r\nAddReg=OPKInstall\r\n"))
	testing.expect(t, contains(normalized, "UpdateInis=RETVRN99BootOptions\r\n"))
	testing.expect(t, contains(normalized, "[OPKInstall]\r\n"))
	testing.expect(t, contains(normalized, "[RETVRN99BootOptions]\r\n"))
	testing.expect(t, contains(normalized, `%30%\MSDOS.SYS,Options,,"BootMenuDefault=1"`))
	testing.expect(t, contains(normalized, `"ProductId",,"12345-OEM-1234567-12345"`))
	testing.expect(t, contains(normalized, `"ProductKey",,"RW9MG-QR4G3-2WRR9-TG7BH-33GXB"`))
	testing.expect(t, contains(normalized, `"RegisteredOwner",,"RETVRN99 User"`))
	testing.expect(t, contains(normalized, `"RegisteredOrganization",,"RETVRN99"`))
	testing.expect(t, contains(normalized, "[OptionalComponents]\r\nJuegos=0\r\n"))
	delete(normalized)
}

@(test)
test_normalize_msbatch_adds_missing_component_setting :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	template := "[setup]\nExpress=1\n\n[NameAndOrg]\nName=User\n"
	normalized, ok := normalize_msbatch(template)
	testing.expect(t, ok)
	testing.expect(t, contains(normalized, "ShowEula=0\n"))
	testing.expect(t, contains(normalized, "NoPrompt2Boot=1\n"))
	testing.expect(t, contains(normalized, "PenWinWarning=0\n"))
	testing.expect(t, contains(normalized, "[NameAndOrg]\n"))
	testing.expect(t, contains(normalized, "[Network]\nComputerName=\"RETVRN99\"\n"))
	testing.expect(t, contains(normalized, "ValidateNetCardResources=0\n"))
	testing.expect(t, contains(normalized, "[Install]\nAddReg=OPKInstall\n"))
	testing.expect(t, contains(normalized, "UpdateInis=RETVRN99BootOptions\n"))
	testing.expect(t, contains(normalized, "[OPKInstall]\n"))
	testing.expect(t, contains(normalized, "[RETVRN99BootOptions]\n"))
	delete(normalized)
}

@(test)
test_normalize_msbatch_preserves_install_actions_and_replaces_opk_values :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	template := "[Setup]\r\nExpress=1\r\n\r\n[Install]\r\nAddReg=RegistrySettings\r\n\r\n[OPKInstall]\r\nHKLM,Old,Value,,Wrong\r\n\r\n[RegistrySettings]\r\nHKLM,Keep,Value,,Right\r\n"
	normalized, ok := normalize_msbatch(template)
	defer delete(normalized)
	testing.expect(t, ok)
	testing.expect(t, contains(normalized, "AddReg=RegistrySettings,OPKInstall\r\n"))
	testing.expect(t, contains(normalized, "[RegistrySettings]\r\nHKLM,Keep,Value,,Right\r\n"))
	testing.expect(t, !contains(normalized, "HKLM,Old,Value,,Wrong"))
	testing.expect(t, contains(normalized, `"ProductId",,"12345-OEM-1234567-12345"`))
}

@(test)
test_normalize_msbatch_preserves_install_directives_and_replaces_boot_options :: proc(
	t: ^testing.T,
) {
	context.allocator = context.temp_allocator
	template :=
		"[Setup]\r\nExpress=1\r\n\r\n" +
		"[Install]\r\nAddReg=RegistrySettings\r\nDelReg=OldSettings\r\n" +
		"UpdateInis=OEMBootOptions,OEMSystemOptions\r\nUpdateCfgSys=OEMConfig\r\n\r\n" +
		"[RETVRN99BootOptions]\r\n%30%\\MSDOS.SYS,Options,,\"BootMenuDefault=3\"\r\n" +
		"Obsolete=1\r\n\r\n[OEMBootOptions]\r\n%30%\\MSDOS.SYS,Options,,\"BootMulti=1\"\r\n"
	normalized, ok := normalize_msbatch(template)
	defer delete(normalized)
	testing.expect(t, ok)
	testing.expect(t, contains(normalized, "AddReg=RegistrySettings,OPKInstall\r\n"))
	testing.expect(t, contains(normalized, "DelReg=OldSettings\r\n"))
	testing.expect(
		t,
		contains(normalized, "UpdateInis=OEMBootOptions,OEMSystemOptions,RETVRN99BootOptions\r\n"),
	)
	testing.expect(t, contains(normalized, "UpdateCfgSys=OEMConfig\r\n"))
	testing.expect(
		t,
		contains(normalized, "[OEMBootOptions]\r\n%30%\\MSDOS.SYS,Options,,\"BootMulti=1\"\r\n"),
	)
	testing.expect(
		t,
		contains(
			normalized,
			"[RETVRN99BootOptions]\r\n%30%\\MSDOS.SYS,Options,,\"BootMenuDefault=1\"\r\n",
		),
	)
	testing.expect(t, !contains(normalized, "BootMenuDefault=3"))
	testing.expect(t, !contains(normalized, "Obsolete=1"))
}

@(test)
test_normalize_msbatch_boot_options_is_idempotent :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	template :=
		"[Setup]\nExpress=1\n\n[Install]\nUpdateINIs=OEMBootOptions\n\n" +
		"[RETVRN99BootOptions]\nOld=Value\n\n[OEMBootOptions]\nmsdos.sys,Options,,\"BootMulti=1\"\n"
	first, first_ok := normalize_msbatch(template)
	defer delete(first)
	testing.expect(t, first_ok)
	second, second_ok := normalize_msbatch(first)
	defer delete(second)
	testing.expect(t, second_ok)
	testing.expect_value(t, second, first)
}

@(test)
test_normalize_msbatch_replaces_oem_identity :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	template := "[Setup]\r\nProductKey=AAAAA-BBBBB-CCCCC-DDDDD-EEEEE\r\nOptionalComponents=1\r\nNoPrompt2Boot=1\r\nPenWinWarning=1\r\n\r\n[NameAndOrg]\r\nName=\"System Recovery\"\r\nOrg=\"Preferred Customer\"\r\n\r\n[Network]\r\nComputerName=RECOVERY\r\nWorkgroup=OEM\r\nDescription=\"System Recovery\"\r\n"
	normalized, ok := normalize_msbatch(template)
	defer delete(normalized)
	testing.expect(t, ok)
	testing.expect(t, !contains(normalized, "System Recovery"))
	testing.expect(t, !contains(normalized, "Preferred Customer"))
	testing.expect(t, !contains(normalized, "AAAAA-BBBBB-CCCCC-DDDDD-EEEEE"))
	testing.expect(t, contains(normalized, `ProductKey="RW9MG-QR4G3-2WRR9-TG7BH-33GXB"`))
	testing.expect(t, contains(normalized, `Name="RETVRN99 User"`))
	testing.expect(t, contains(normalized, `Org="RETVRN99"`))
	testing.expect(t, contains(normalized, `ComputerName="RETVRN99"`))
	testing.expect(t, contains(normalized, `Workgroup="WORKGROUP"`))
	testing.expect(t, contains(normalized, `Description="RETVRN99"`))
}

@(test)
test_normalize_msbatch_inserts_before_dos_eof :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	suffix := "\x1aOEM TRAILER \x80"
	template := "[Setup]\r\nOptionalComponents=1\r\nNoPrompt2Boot=1\r\nPenWinWarning=1\r\n\x1aOEM TRAILER \x80"
	normalized, ok := normalize_msbatch(template)
	defer delete(normalized)
	testing.expect(t, ok)
	eof := -1
	for index in 0 ..< len(normalized) {
		if normalized[index] == '\x1a' {
			eof = index
			break
		}
	}
	testing.expect(t, eof >= 0)
	if eof >= 0 {
		testing.expect(t, contains(normalized[:eof], "[NameAndOrg]"))
		testing.expect(t, contains(normalized[:eof], "[Network]"))
		testing.expect(t, contains(normalized[:eof], "[OPKInstall]"))
		testing.expect(t, contains(normalized[:eof], "[RETVRN99BootOptions]"))
		testing.expect(t, contains(normalized[:eof], "BootMenuDefault=1"))
		testing.expect_value(t, normalized[eof:], suffix)
	}
}

@(test)
test_normalize_msbatch_rejects_missing_setup_section :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	normalized, ok := normalize_msbatch("[NameAndOrg]\r\nName=User\r\n")
	testing.expect(t, !ok)
	testing.expect_value(t, normalized, "")
}

@(test)
test_msbatch_time_zone_uses_windows_98_names :: proc(t: ^testing.T) {
	zone, ok := msbatch_time_zone_from_host("Europe/Madrid")
	testing.expect(t, ok)
	testing.expect_value(t, zone, "Romance")
	zone, ok = msbatch_time_zone_from_host("Romance Standard Time")
	testing.expect(t, ok)
	testing.expect_value(t, zone, "Romance")
	_, ok = msbatch_time_zone_from_host("Antarctica/Troll")
	testing.expect(t, !ok)
}

@(test)
test_msbatch_desktop_probe_is_opt_in_and_language_independent :: proc(t: ^testing.T) {
	template := "[Setup]\r\nExpress=1\r\n"
	normal, ok := normalize_msbatch(template)
	testing.expect(t, ok)
	testing.expect(t, !contains(normal, "RETVRN99Acceptance"))
	delete(normal)
	probed, probed_ok := normalize_msbatch(template, true)
	testing.expect(t, probed_ok)
	testing.expect(
		t,
		contains(probed, `"RETVRN99Acceptance",,"COMMAND.COM /C C:\GSWSETUP\DESKTOP.BAT"`),
	)
	delete(probed)

	root, temp_error := os.temp_directory(context.temp_allocator)
	testing.expect(t, temp_error == nil)
	directory, directory_error := os.make_directory_temp(
		root,
		"retvrn99_desktop_probe_*",
		context.temp_allocator,
	)
	testing.expect(t, directory_error == nil)
	defer os.remove_all(directory)
	stale_marker, _ := filepath.join({directory, DESKTOP_MARKER_FILE}, context.temp_allocator)
	stale_enum, _ := filepath.join({directory, DESKTOP_ENUM_FILE}, context.temp_allocator)
	stale_dynamic_enum, _ := filepath.join(
		{directory, DESKTOP_DYNAMIC_ENUM_FILE},
		context.temp_allocator,
	)
	testing.expect(t, os.write_entire_file(stale_marker, "STALE") == nil)
	testing.expect(t, os.write_entire_file(stale_enum, "STALE") == nil)
	testing.expect(t, os.write_entire_file(stale_dynamic_enum, "STALE") == nil)
	testing.expect(t, desktop_probe_write(directory))
	_, marker_error := os.stat(stale_marker, context.temp_allocator)
	_, enum_error := os.stat(stale_enum, context.temp_allocator)
	_, dynamic_enum_error := os.stat(stale_dynamic_enum, context.temp_allocator)
	testing.expect(t, marker_error != nil)
	testing.expect(t, enum_error != nil)
	testing.expect(t, dynamic_enum_error != nil)
	path, _ := filepath.join({directory, DESKTOP_PROBE_FILE}, context.temp_allocator)
	payload, read_error := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, read_error == nil)
	testing.expect(
		t,
		contains(string(payload), "REGEDIT /E C:\\GSWSETUP\\ENUM.REG HKEY_LOCAL_MACHINE\\Enum"),
	)
	testing.expect(
		t,
		contains(
			string(payload),
			`REGEDIT /E C:\GSWSETUP\DYNENUM.REG "HKEY_DYN_DATA\Config Manager\Enum"`,
		),
	)
	static_check := strings.index(string(payload), "IF NOT EXIST C:\\GSWSETUP\\ENUM.REG")
	dynamic_check := strings.index(string(payload), "IF NOT EXIST C:\\GSWSETUP\\DYNENUM.REG")
	marker_write := strings.index(string(payload), "ECHO READY>C:\\GSWSETUP\\DESKTOP.OK")
	testing.expect(t, static_check >= 0 && dynamic_check > static_check && marker_write > dynamic_check)
	testing.expect(t, contains(string(payload), "ECHO READY>C:\\GSWSETUP\\DESKTOP.OK"))
}

@(test)
test_desktop_probe_rejects_stale_marker_cleanup_failure :: proc(t: ^testing.T) {
	root, temp_error := os.temp_directory(context.temp_allocator)
	testing.expect(t, temp_error == nil)
	directory, directory_error := os.make_directory_temp(
		root,
		"retvrn99_desktop_probe_cleanup_*",
		context.temp_allocator,
	)
	testing.expect(t, directory_error == nil)
	defer os.remove_all(directory)

	marker, _ := filepath.join({directory, DESKTOP_MARKER_FILE}, context.temp_allocator)
	marker_child, _ := filepath.join({marker, "BLOCK"}, context.temp_allocator)
	probe, _ := filepath.join({directory, DESKTOP_PROBE_FILE}, context.temp_allocator)
	testing.expect(t, os.make_directory(marker) == nil)
	testing.expect(t, os.write_entire_file(marker_child, "STALE") == nil)

	testing.expect(t, !desktop_probe_write(directory))
	marker_info, marker_error := os.lstat(marker, context.temp_allocator)
	_, probe_error := os.lstat(probe, context.temp_allocator)
	testing.expect(t, marker_error == nil)
	if marker_error == nil {os.file_info_delete(marker_info, context.temp_allocator)}
	testing.expect(t, probe_error == os.General_Error.Not_Exist)
}

@(test)
test_desktop_probe_rejects_stale_enum_cleanup_failure :: proc(t: ^testing.T) {
	root, temp_error := os.temp_directory(context.temp_allocator)
	testing.expect(t, temp_error == nil)
	directory, directory_error := os.make_directory_temp(
		root,
		"retvrn99_desktop_probe_cleanup_*",
		context.temp_allocator,
	)
	testing.expect(t, directory_error == nil)
	defer os.remove_all(directory)

	marker, _ := filepath.join({directory, DESKTOP_MARKER_FILE}, context.temp_allocator)
	enum_path, _ := filepath.join({directory, DESKTOP_ENUM_FILE}, context.temp_allocator)
	enum_child, _ := filepath.join({enum_path, "BLOCK"}, context.temp_allocator)
	probe, _ := filepath.join({directory, DESKTOP_PROBE_FILE}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(marker, "STALE") == nil)
	testing.expect(t, os.make_directory(enum_path) == nil)
	testing.expect(t, os.write_entire_file(enum_child, "STALE") == nil)

	testing.expect(t, !desktop_probe_write(directory))
	_, marker_error := os.lstat(marker, context.temp_allocator)
	enum_info, enum_error := os.lstat(enum_path, context.temp_allocator)
	_, probe_error := os.lstat(probe, context.temp_allocator)
	testing.expect(t, marker_error == os.General_Error.Not_Exist)
	testing.expect(t, enum_error == nil)
	if enum_error == nil {os.file_info_delete(enum_info, context.temp_allocator)}
	testing.expect(t, probe_error == os.General_Error.Not_Exist)
}
