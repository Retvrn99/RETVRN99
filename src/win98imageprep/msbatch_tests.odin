// SPDX-License-Identifier: GPL-3.0-only
package win98imageprep

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(private = "file")
contains :: proc(haystack, needle: string) -> bool {
	return strings.contains(haystack, needle)
}

@(private = "file")
has_only_crlf :: proc(value: string) -> bool {
	for byte, index in value {
		if byte == '\n' && (index == 0 || value[index - 1] != '\r') {return false}
		if byte == '\r' && (index + 1 >= len(value) || value[index + 1] != '\n') {return false}
	}
	return true
}

@(private = "file")
read_desktop_probe_file :: proc(directory, name: string) -> (string, bool) {
	path, path_error := filepath.join({directory, name}, context.temp_allocator)
	if path_error != nil {return "", false}
	payload, read_error := os.read_entire_file(path, context.allocator)
	if read_error != nil {return "", false}
	return string(payload), true
}

@(test)
test_normalize_msbatch_suppresses_component_dialog :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	template := "[Setup]\r\nExpress=1\r\nOptionalComponents=1\r\nNoPrompt2Boot=0\r\nNetwork=1\r\n\r\n[OptionalComponents]\r\nJuegos=0\r\n\r\n[Network]\r\nDisplay=0\r\n"
	normalized, ok := normalize_msbatch(template)
	testing.expect(t, ok)
	testing.expect(t, contains(normalized, "OptionalComponents=0\r\n"))
	testing.expect(t, !contains(normalized, "OptionalComponents=1"))
	testing.expect(t, contains(normalized, "Express=1\r\n"))
	testing.expect(t, contains(normalized, `ProductKey="RW9MG-QR4G3-2WRR9-TG7BH-33GXB"`))
	testing.expect(t, contains(normalized, "ShowEula=0\r\n"))
	testing.expect(t, contains(normalized, "EBD=0\r\n"))
	testing.expect(t, contains(normalized, "NoPrompt2Boot=1\r\n"))
	testing.expect(t, !contains(normalized, "NoPrompt2Boot=0"))
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
	testing.expect(
		t,
		contains(
			normalized,
			`HKLM,"SOFTWARE\Microsoft\Windows\CurrentVersion\Run","BatchReg1",0x00000004`,
		),
	)
	testing.expect(t, contains(normalized, "[OptionalComponents]\r\nJuegos=0\r\n"))
	delete(normalized)
}

@(test)
test_normalize_msbatch_enables_automatic_setup_restarts :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	normalized, ok := normalize_msbatch("[Setup]\r\nNoPrompt2Boot=0\r\n")
	defer delete(normalized)
	testing.expect(t, ok)
	testing.expect(t, contains(normalized, "NoPrompt2Boot=1\r\n"))
	testing.expect(t, !contains(normalized, "NoPrompt2Boot=0"))
}

@(test)
test_normalize_msbatch_adds_missing_component_setting :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	template := "[setup]\nExpress=1\n\n[NameAndOrg]\nName=User\n"
	normalized, ok := normalize_msbatch(template)
	testing.expect(t, ok)
	testing.expect(t, contains(normalized, "ShowEula=0\n"))
	testing.expect(t, contains(normalized, "NoPrompt2Boot=1\n"))
	testing.expect(t, !contains(normalized, "NoPrompt2Boot=0"))
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
test_normalize_msbatch_removes_oem_recovery_after_other_registry_actions :: proc(t: ^testing.T) {
	template :=
		"[Setup]\r\nExpress=1\r\n\r\n" +
		"[Install]\r\nAddReg=OPKInstall,RegistrySettings\r\n\r\n" +
		"[RegistrySettings]\r\nHKLM,%KEY_RUN%,BatchReg1,,\"%11%\\srw.exe\"\r\n\r\n" +
		"[Strings]\r\nKEY_RUN=\"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run\"\r\n"
	normalized, ok := normalize_msbatch(template)
	defer delete(normalized)
	testing.expect(t, ok)
	testing.expect(t, contains(normalized, "AddReg=RegistrySettings,OPKInstall\r\n"))
	added := strings.index(normalized, `HKLM,%KEY_RUN%,BatchReg1,,"%11%\srw.exe"`)
	removed := strings.index(
		normalized,
		`HKLM,"SOFTWARE\Microsoft\Windows\CurrentVersion\Run","BatchReg1",0x00000004`,
	)
	testing.expect(t, added >= 0 && removed > added)
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
test_msbatch_regional_settings_map_supported_host_locales :: proc(t: ^testing.T) {
	tests := [?]struct {
		host:     Host_Locale,
		locale:   string,
		keyboard: string,
	} {
		{{language = "es", country = "ES"}, "L0C0A", "KEYBOARD_0000040A"},
		{{language = "es", country = "MX"}, "L080A", "KEYBOARD_0000080A"},
		{{language = "en", country = "US"}, "L0409", "KEYBOARD_00000409"},
		{{language = "en", country = "GB"}, "L0809", "KEYBOARD_00000809"},
		{{language = "ko", country = "KR"}, "L0412", "KEYBOARD_00000412"},
	}
	for test in tests {
		region, ok := msbatch_regional_settings_from_host(test.host)
		testing.expect(t, ok)
		testing.expect_value(t, region.locale, test.locale)
		testing.expect_value(t, region.keyboard, test.keyboard)
	}
	region, ok := msbatch_regional_settings_from_host({language = "ES", country = "es"})
	testing.expect(t, ok)
	testing.expect_value(t, region.locale, "L0C0A")
	testing.expect_value(t, region.keyboard, "KEYBOARD_0000040A")
}

@(test)
test_normalize_msbatch_uses_supported_host_region :: proc(t: ^testing.T) {
	template :=
		"[Setup]\r\nExpress=1\r\n\r\n[System]\r\n" +
		"Locale=L080A\r\nSelectedKeyboard=KEYBOARD_0000080A\r\n\x1aOEM TRAILER"
	normalized, ok := normalize_msbatch(template, false, {language = "es", country = "ES"})
	defer delete(normalized)
	testing.expect(t, ok)
	testing.expect(t, contains(normalized, "[System]\r\nLocale=L0C0A\r\n"))
	testing.expect(t, contains(normalized, "SelectedKeyboard=KEYBOARD_0000040A\r\n"))
	testing.expect(t, !contains(normalized, "Locale=L080A"))
	testing.expect(t, !contains(normalized, "KEYBOARD_0000080A"))
	testing.expect(t, strings.has_suffix(normalized, "\x1aOEM TRAILER"))

	second, second_ok := normalize_msbatch(normalized, false, {language = "es", country = "ES"})
	defer delete(second)
	testing.expect(t, second_ok)
	testing.expect_value(t, second, normalized)
}

@(test)
test_normalize_msbatch_preserves_source_region_for_unknown_or_missing_host :: proc(t: ^testing.T) {
	template :=
		"[Setup]\r\nExpress=1\r\n\r\n[System]\r\n" +
		"Locale=L080A\r\nSelectedKeyboard=KEYBOARD_0000080A\r\n"
	hosts := [?]Host_Locale{{}, {language = "es"}, {language = "zz", country = "ZZ"}}
	for host in hosts {
		normalized, ok := normalize_msbatch(template, false, host)
		testing.expect(t, ok)
		testing.expect(t, contains(normalized, "Locale=L080A\r\n"))
		testing.expect(t, contains(normalized, "SelectedKeyboard=KEYBOARD_0000080A\r\n"))
		delete(normalized)
	}
}

@(test)
test_msbatch_desktop_probe_is_opt_in_and_language_independent :: proc(t: ^testing.T) {
	template :=
		"[Setup]\r\nExpress=1\r\n\r\n" +
		"[Install]\r\nAddReg=RegistrySettings\r\n\r\n" +
		"[RegistrySettings]\r\n" +
		`HKLM,"Software\Microsoft\Windows\CurrentVersion\RunServices","KeepMe",,"KEEP.BAT"` +
		"\r\n"
	normal, ok := normalize_msbatch(template)
	testing.expect(t, ok)
	testing.expect(t, !contains(normal, "RETVRN99Acceptance"))
	testing.expect(
		t,
		contains(
			normal,
			`HKLM,"Software\Microsoft\Windows\CurrentVersion\RunOnce","RETVRN99DMASetup",,"COMMAND.COM /C C:\GSWSETUP\DMASETUP.BAT"`,
		),
	)
	testing.expect(t, contains(normal, `"KeepMe",,"KEEP.BAT"`))
	delete(normal)
	probed, probed_ok := normalize_msbatch(template, true)
	testing.expect(t, probed_ok)
	arm_value := `HKLM,"Software\Microsoft\Windows\CurrentVersion\RunServices","RETVRN99AcceptanceArm",,"COMMAND.COM /C C:\GSWSETUP\ARM.BAT"`
	dma_value := `HKLM,"Software\Microsoft\Windows\CurrentVersion\RunOnce","RETVRN99DMASetup",,"COMMAND.COM /C C:\GSWSETUP\DMASETUP.BAT"`
	recovery_cleanup := `HKLM,"SOFTWARE\Microsoft\Windows\CurrentVersion\Run","BatchReg1",0x00000004`
	cleanup_index := strings.index(probed, recovery_cleanup)
	dma_index := strings.index(probed, dma_value)
	arm_index := strings.index(probed, arm_value)
	testing.expect(t, cleanup_index >= 0 && dma_index > cleanup_index && arm_index > dma_index)
	testing.expect(t, contains(probed, `"KeepMe",,"KEEP.BAT"`))
	testing.expect(t, !contains(probed, `RunOnce","RETVRN99Acceptance",`))
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
	stale_disk_probe, _ := filepath.join(
		{directory, DESKTOP_DISK_PROBE_FILE},
		context.temp_allocator,
	)
	stale_pending, _ := filepath.join({directory, DESKTOP_PENDING_FILE}, context.temp_allocator)
	stale_arm_check, _ := filepath.join(
		{directory, DESKTOP_ARM_CHECK_FILE},
		context.temp_allocator,
	)
	stale_dma_registry, _ := filepath.join(
		{directory, DESKTOP_DMA_REGISTRY_FILE},
		context.temp_allocator,
	)
	stale_inf_patch, _ := filepath.join({directory, DMA_INF_PATCH_FILE}, context.temp_allocator)
	additional_stale_names := [?]string {
		DESKTOP_HDC_STATE_FILE,
		DESKTOP_HDC_ZERO_FILE,
		DESKTOP_HDC_PRIMARY_FILE,
		DESKTOP_HDC_SECONDARY_FILE,
		DESKTOP_HDC_THREE_FILE,
		DESKTOP_MF_PRIMARY_FILE,
		DESKTOP_MF_SECONDARY_FILE,
		DESKTOP_DMA_CHECK_FILE,
	}
	testing.expect(t, os.write_entire_file(stale_marker, "STALE") == nil)
	testing.expect(t, os.write_entire_file(stale_enum, "STALE") == nil)
	testing.expect(t, os.write_entire_file(stale_dynamic_enum, "STALE") == nil)
	testing.expect(t, os.write_entire_file(stale_disk_probe, "STALE") == nil)
	testing.expect(t, os.write_entire_file(stale_pending, "STALE") == nil)
	testing.expect(t, os.write_entire_file(stale_arm_check, "STALE") == nil)
	testing.expect(t, os.write_entire_file(stale_dma_registry, "STALE") == nil)
	testing.expect(t, os.write_entire_file(stale_inf_patch, "STALE") == nil)
	for name in additional_stale_names {
		path, path_error := filepath.join({directory, name}, context.temp_allocator)
		testing.expect(t, path_error == nil)
		testing.expect(t, os.write_entire_file(path, "STALE") == nil)
	}
	testing.expect(t, post_setup_write(directory, true))
	_, marker_error := os.stat(stale_marker, context.temp_allocator)
	_, enum_error := os.stat(stale_enum, context.temp_allocator)
	_, dynamic_enum_error := os.stat(stale_dynamic_enum, context.temp_allocator)
	_, disk_probe_error := os.stat(stale_disk_probe, context.temp_allocator)
	_, pending_error := os.stat(stale_pending, context.temp_allocator)
	_, arm_check_error := os.stat(stale_arm_check, context.temp_allocator)
	testing.expect(t, marker_error != nil)
	testing.expect(t, enum_error != nil)
	testing.expect(t, dynamic_enum_error != nil)
	testing.expect(t, disk_probe_error != nil)
	testing.expect(t, pending_error != nil)
	testing.expect(t, arm_check_error != nil)
	dma_registry, dma_registry_ok := read_desktop_probe_file(directory, DESKTOP_DMA_REGISTRY_FILE)
	defer delete(dma_registry)
	testing.expect(t, dma_registry_ok)
	testing.expect(t, !contains(dma_registry, "STALE"))
	inf_patch, inf_patch_ok := read_desktop_probe_file(directory, DMA_INF_PATCH_FILE)
	defer delete(inf_patch)
	testing.expect(t, inf_patch_ok)
	testing.expect(t, !contains(inf_patch, "STALE"))
	for name in additional_stale_names {
		path, path_error := filepath.join({directory, name}, context.temp_allocator)
		testing.expect(t, path_error == nil)
		_, stat_error := os.stat(path, context.temp_allocator)
		testing.expect(t, stat_error == os.General_Error.Not_Exist)
	}
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
	disk_copy := strings.index(
		string(payload),
		"COPY /B C:\\WINDOWS\\WIN.COM C:\\GSWSETUP\\DMAPROBE.BIN >NUL",
	)
	disk_compare := strings.index(
		string(payload),
		"FC /B C:\\WINDOWS\\WIN.COM C:\\GSWSETUP\\DMAPROBE.BIN >NUL",
	)
	disk_read := strings.index(string(payload), "COPY /B C:\\GSWSETUP\\DMAPROBE.BIN NUL >NUL")
	testing.expect(t, disk_copy >= 0 && disk_compare > disk_copy && disk_read > disk_compare)
	testing.expect(
		t,
		static_check > disk_read && dynamic_check > static_check && marker_write > dynamic_check,
	)
	testing.expect(t, contains(string(payload), "ECHO READY>C:\\GSWSETUP\\DESKTOP.OK"))
}

@(test)
test_desktop_probe_writes_two_boot_chain_with_crlf :: proc(t: ^testing.T) {
	root, temp_error := os.temp_directory(context.temp_allocator)
	testing.expect(t, temp_error == nil)
	directory, directory_error := os.make_directory_temp(
		root,
		"retvrn99_desktop_chain_*",
		context.temp_allocator,
	)
	testing.expect(t, directory_error == nil)
	defer os.remove_all(directory)
	testing.expect(t, post_setup_write(directory, true))

	desktop, desktop_ok := read_desktop_probe_file(directory, DESKTOP_PROBE_FILE)
	defer delete(desktop)
	reboot, reboot_ok := read_desktop_probe_file(directory, DMA_SETUP_FILE)
	defer delete(reboot)
	arm, arm_ok := read_desktop_probe_file(directory, DESKTOP_ARM_FILE)
	defer delete(arm)
	postboot, postboot_ok := read_desktop_probe_file(directory, DESKTOP_POSTBOOT_FILE)
	defer delete(postboot)
	clean, clean_ok := read_desktop_probe_file(directory, DESKTOP_CLEAN_FILE)
	defer delete(clean)
	dma_registry, dma_registry_ok := read_desktop_probe_file(directory, DESKTOP_DMA_REGISTRY_FILE)
	defer delete(dma_registry)
	inf_patch, inf_patch_ok := read_desktop_probe_file(directory, DMA_INF_PATCH_FILE)
	defer delete(inf_patch)
	testing.expect(
		t,
		desktop_ok &&
		reboot_ok &&
		arm_ok &&
		postboot_ok &&
		clean_ok &&
		dma_registry_ok &&
		inf_patch_ok,
	)
	testing.expect(t, has_only_crlf(desktop))
	testing.expect(t, has_only_crlf(reboot))
	testing.expect(t, has_only_crlf(arm))
	testing.expect(t, has_only_crlf(postboot))
	testing.expect(t, has_only_crlf(clean))
	testing.expect(t, has_only_crlf(dma_registry))
	testing.expect(t, has_only_crlf(inf_patch))
	testing.expect(t, contains(inf_patch, "' SPDX-License-Identifier: GPL-3.0-only\r\n"))
	testing.expect(t, contains(inf_patch, `output = output & "HKR,,IDEDMADrive"`))
	testing.expect(t, contains(inf_patch, "Function VerifyText(text, section)"))
	testing.expect(t, contains(inf_patch, "Function RecoverReplacement(path, section"))
	testing.expect(t, contains(inf_patch, `tempPath = path & ".R99TMP"`))
	testing.expect(t, contains(inf_patch, `backupPath = path & ".R99BAK"`))
	testing.expect_value(
		t,
		dma_registry,
		"REGEDIT4\r\n\r\n" +
		"[HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Services\\Class\\hdc\\0000]\r\n" +
		`"IDEDMADRIVE0"=hex:01` +
		"\r\n" +
		`"IDEDMADRIVE1"=hex:01` +
		"\r\n" +
		`"IDEDMADRIVE2"=hex:01` +
		"\r\n" +
		`"IDEDMADRIVE3"=hex:01` +
		"\r\n\r\n" +
		"[HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Services\\Class\\hdc\\0001]\r\n" +
		`"IDEDMADRIVE0"=hex:01` +
		"\r\n" +
		`"IDEDMADRIVE1"=hex:01` +
		"\r\n" +
		`"IDEDMADRIVE2"=hex:01` +
		"\r\n" +
		`"IDEDMADRIVE3"=hex:01` +
		"\r\n\r\n" +
		"[HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Services\\Class\\hdc\\0002]\r\n" +
		`"IDEDMADRIVE0"=hex:01` +
		"\r\n" +
		`"IDEDMADRIVE1"=hex:01` +
		"\r\n" +
		`"IDEDMADRIVE2"=hex:01` +
		"\r\n" +
		`"IDEDMADRIVE3"=hex:01` +
		"\r\n\r\n" +
		"[HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Services\\Class\\hdc\\0003]\r\n" +
		`"IDEDMADRIVE0"=hex:01` +
		"\r\n" +
		`"IDEDMADRIVE1"=hex:01` +
		"\r\n" +
		`"IDEDMADRIVE2"=hex:01` +
		"\r\n" +
		`"IDEDMADRIVE3"=hex:01` +
		"\r\n",
	)

	arm_gate := strings.index(arm, "IF NOT EXIST C:\\GSWSETUP\\REBOOT.PND GOTO GSWEND")
	arm_import := strings.index(arm, "REGEDIT /S C:\\GSWSETUP\\POSTBOOT.REG")
	testing.expect(t, arm_gate >= 0 && arm_import > arm_gate)
	testing.expect(
		t,
		contains(postboot, `"RETVRN99Acceptance"="COMMAND.COM /C C:\\GSWSETUP\\DESKTOP.BAT"`),
	)
	testing.expect_value(
		t,
		clean,
		"REGEDIT4\r\n\r\n" +
		"[HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows\\CurrentVersion\\RunServices]\r\n" +
		`"RETVRN99AcceptanceArm"=-` +
		"\r\n",
	)

	arm_export := strings.index(reboot, "REGEDIT /E C:\\GSWSETUP\\ARMCHK.REG")
	arm_verify := strings.index(reboot, `FIND /I "RETVRN99AcceptanceArm"`)
	primary_mapping_export := strings.index(
		reboot,
		"REGEDIT /E C:\\GSWSETUP\\MFPRI.REG HKEY_LOCAL_MACHINE\\Enum\\MF\\CHILD0000",
	)
	primary_mapping_verify := strings.index(reboot, `FIND /I "MF\\GOODPRIMARY"`)
	primary_driver_verify := strings.index(reboot, `FIND /I "hdc\\0001"`)
	secondary_mapping_export := strings.index(
		reboot,
		"REGEDIT /E C:\\GSWSETUP\\MFSEC.REG HKEY_LOCAL_MACHINE\\Enum\\MF\\CHILD0001",
	)
	secondary_mapping_verify := strings.index(reboot, `FIND /I "MF\\GOODSECONDARY"`)
	secondary_driver_verify := strings.index(reboot, `FIND /I "hdc\\0002"`)
	hdc_state_export := strings.index(
		reboot,
		"REGEDIT /E C:\\GSWSETUP\\HDC.REG HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Services\\Class\\hdc",
	)
	inf_patch_call := strings.index(
		reboot,
		"%windir%\\COMMAND\\CSCRIPT.EXE //Nologo C:\\GSWSETUP\\PATCHINF.VBS %windir%\\INF\\MSHDC.INF ESDI_AddReg %windir%\\INF\\DISKDRV.INF DiskReg",
	)
	mshdc_inf_verify := strings.index(
		reboot,
		`FIND /I "HKR,,IDEDMADrive3,3,01" %windir%\INF\MSHDC.INF`,
	)
	diskdrv_inf_verify := strings.index(
		reboot,
		`FIND /I "HKR,,IDEDMADrive3,3,01" %windir%\INF\DISKDRV.INF`,
	)
	dma_import := strings.index(reboot, "REGEDIT /S C:\\GSWSETUP\\DMA.REG")
	zero_hdc_export := strings.index(
		reboot,
		"REGEDIT /E C:\\GSWSETUP\\HDC0.REG HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Services\\Class\\hdc\\0000",
	)
	primary_hdc_export := strings.index(
		reboot,
		"REGEDIT /E C:\\GSWSETUP\\HDC1.REG HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Services\\Class\\hdc\\0001",
	)
	primary_dma_verify := strings.index(reboot, `FIND /I "IDEDMADRIVE0" C:\GSWSETUP\HDC1.REG`)
	secondary_hdc_export := strings.index(
		reboot,
		"REGEDIT /E C:\\GSWSETUP\\HDC2.REG HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Services\\Class\\hdc\\0002",
	)
	secondary_dma_verify := strings.index(reboot, `FIND /I "IDEDMADRIVE0" C:\GSWSETUP\HDC2.REG`)
	three_hdc_export := strings.index(
		reboot,
		"REGEDIT /E C:\\GSWSETUP\\HDC3.REG HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Services\\Class\\hdc\\0003",
	)
	three_dma_verify := strings.index(reboot, `FIND /I "IDEDMADRIVE3" C:\GSWSETUP\HDC3.REG`)
	pending_write := strings.index(reboot, "ECHO PENDING>C:\\GSWSETUP\\REBOOT.PND")
	reboot_call := strings.index(reboot, "RUNDLL32.EXE SHELL32.DLL,SHExitWindowsEx 6")
	testing.expect(
		t,
		arm_export >= 0 &&
		arm_verify > arm_export &&
		primary_mapping_export > arm_verify &&
		primary_mapping_verify > primary_mapping_export &&
		primary_driver_verify > primary_mapping_verify &&
		secondary_mapping_export > primary_driver_verify &&
		secondary_mapping_verify > secondary_mapping_export &&
		secondary_driver_verify > secondary_mapping_verify &&
		hdc_state_export > secondary_driver_verify &&
		inf_patch_call > hdc_state_export &&
		mshdc_inf_verify > inf_patch_call &&
		diskdrv_inf_verify > mshdc_inf_verify &&
		dma_import > diskdrv_inf_verify &&
		zero_hdc_export > dma_import &&
		primary_hdc_export > zero_hdc_export &&
		primary_dma_verify > primary_hdc_export &&
		secondary_hdc_export > primary_dma_verify &&
		secondary_dma_verify > secondary_hdc_export &&
		three_hdc_export > secondary_dma_verify &&
		three_dma_verify > three_hdc_export &&
		pending_write > three_dma_verify &&
		reboot_call > pending_write,
	)
	hdc_files := [?]string{"HDC0.REG", "HDC1.REG", "HDC2.REG", "HDC3.REG"}
	dma_drives := [?]string{"0", "1", "2", "3"}
	for file in hdc_files {
		for drive in dma_drives {
			needle, allocation_error := strings.concatenate(
				[]string{`FIND /I "IDEDMADRIVE`, drive, `" C:\GSWSETUP\`, file},
			)
			testing.expect(t, allocation_error == nil)
			testing.expect(t, strings.index(reboot, needle) > dma_import)
			delete(needle)
		}
	}

	combined, allocation_error := strings.concatenate(
		[]string{desktop, reboot, arm, postboot, clean, dma_registry},
	)
	testing.expect(t, allocation_error == nil)
	defer delete(combined)
	testing.expect(t, !contains(combined, "SHExitWindowsEx 2"))
	testing.expect(t, !contains(combined, "ExitWindowsExec"))
	testing.expect(t, !contains(combined, "WINSTART"))
}

@(test)
test_post_setup_stages_dma_activation_without_acceptance_probe :: proc(t: ^testing.T) {
	root, temp_error := os.temp_directory(context.temp_allocator)
	testing.expect(t, temp_error == nil)
	directory, directory_error := os.make_directory_temp(
		root,
		"retvrn99_dma_setup_*",
		context.temp_allocator,
	)
	testing.expect(t, directory_error == nil)
	defer os.remove_all(directory)
	testing.expect(t, post_setup_write(directory))

	dma_setup, dma_setup_ok := read_desktop_probe_file(directory, DMA_SETUP_FILE)
	defer delete(dma_setup)
	dma_registry, dma_registry_ok := read_desktop_probe_file(directory, DESKTOP_DMA_REGISTRY_FILE)
	defer delete(dma_registry)
	inf_patch, inf_patch_ok := read_desktop_probe_file(directory, DMA_INF_PATCH_FILE)
	defer delete(inf_patch)
	testing.expect(t, dma_setup_ok && dma_registry_ok && inf_patch_ok)
	testing.expect(t, has_only_crlf(dma_setup))
	testing.expect(t, has_only_crlf(dma_registry))
	testing.expect(t, has_only_crlf(inf_patch))
	testing.expect(t, !contains(dma_setup, "RETVRN99Acceptance"))
	testing.expect(t, !contains(dma_setup, "MF\\GOODPRIMARY"))
	testing.expect(t, !contains(dma_setup, "ECHO PENDING>C:\\GSWSETUP\\REBOOT.PND"))
	patch_call := strings.index(dma_setup, "%windir%\\COMMAND\\CSCRIPT.EXE //Nologo")
	inf_verify := strings.index(
		dma_setup,
		`FIND /I "HKR,,IDEDMADrive3,3,01" %windir%\INF\DISKDRV.INF`,
	)
	dma_import := strings.index(dma_setup, "REGEDIT /S C:\\GSWSETUP\\DMA.REG")
	registry_verify := strings.index(dma_setup, `FIND /I "IDEDMADRIVE3" C:\GSWSETUP\HDC3.REG`)
	restart := strings.index(dma_setup, "RUNDLL32.EXE SHELL32.DLL,SHExitWindowsEx 6")
	testing.expect(
		t,
		patch_call >= 0 &&
		inf_verify > patch_call &&
		dma_import > inf_verify &&
		registry_verify > dma_import &&
		restart > registry_verify,
	)

	acceptance_files := [?]string {
		DESKTOP_PROBE_FILE,
		DESKTOP_ARM_FILE,
		DESKTOP_POSTBOOT_FILE,
		DESKTOP_CLEAN_FILE,
	}
	for name in acceptance_files {
		path, path_error := filepath.join({directory, name}, context.temp_allocator)
		testing.expect(t, path_error == nil)
		_, stat_error := os.stat(path, context.temp_allocator)
		testing.expect(t, stat_error == os.General_Error.Not_Exist)
	}
}

@(test)
test_desktop_probe_cleans_arm_and_pending_before_ready :: proc(t: ^testing.T) {
	root, temp_error := os.temp_directory(context.temp_allocator)
	testing.expect(t, temp_error == nil)
	directory, directory_error := os.make_directory_temp(
		root,
		"retvrn99_desktop_cleanup_order_*",
		context.temp_allocator,
	)
	testing.expect(t, directory_error == nil)
	defer os.remove_all(directory)
	testing.expect(t, post_setup_write(directory, true))
	desktop, desktop_ok := read_desktop_probe_file(directory, DESKTOP_PROBE_FILE)
	defer delete(desktop)
	testing.expect(t, desktop_ok)

	clean_import := strings.index(desktop, "REGEDIT /S C:\\GSWSETUP\\CLEAN.REG")
	arm_absent := strings.index(desktop, `FIND /I "RETVRN99AcceptanceArm"`)
	pending_remove := strings.index(desktop, "DEL C:\\GSWSETUP\\REBOOT.PND >NUL")
	pending_verify := strings.index(desktop, "IF EXIST C:\\GSWSETUP\\REBOOT.PND GOTO GSWCLEAN")
	ready := strings.index(desktop, "ECHO READY>C:\\GSWSETUP\\DESKTOP.OK")
	testing.expect(
		t,
		clean_import >= 0 &&
		arm_absent > clean_import &&
		pending_remove > arm_absent &&
		pending_verify > pending_remove &&
		ready > pending_verify,
	)
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

	testing.expect(t, !post_setup_write(directory, true))
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

	testing.expect(t, !post_setup_write(directory, true))
	_, marker_error := os.lstat(marker, context.temp_allocator)
	enum_info, enum_error := os.lstat(enum_path, context.temp_allocator)
	_, probe_error := os.lstat(probe, context.temp_allocator)
	testing.expect(t, marker_error == os.General_Error.Not_Exist)
	testing.expect(t, enum_error == nil)
	if enum_error == nil {os.file_info_delete(enum_info, context.temp_allocator)}
	testing.expect(t, probe_error == os.General_Error.Not_Exist)
}
