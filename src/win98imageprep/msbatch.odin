// SPDX-License-Identifier: GPL-3.0-only
package win98imageprep

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time/timezone"

Msbatch_Setting :: struct {
	section:         string,
	key:             string,
	value:           string,
	add_section:     bool,
	append_csv:      bool,
	append_csv_last: bool,
}

Msbatch_Regional_Settings :: struct {
	language: string,
	country:  string,
	locale:   string,
	keyboard: string,
}

MSBATCH_REGIONAL_SETTINGS := [?]Msbatch_Regional_Settings {
	{language = "es", country = "ES", locale = "L0C0A", keyboard = "KEYBOARD_0000040A"},
	{language = "es", country = "MX", locale = "L080A", keyboard = "KEYBOARD_0000080A"},
	{language = "en", country = "US", locale = "L0409", keyboard = "KEYBOARD_00000409"},
	{language = "en", country = "GB", locale = "L0809", keyboard = "KEYBOARD_00000809"},
	{language = "ko", country = "KR", locale = "L0412", keyboard = "KEYBOARD_00000412"},
}

DESKTOP_PROBE_FILE :: "DESKTOP.BAT"
DESKTOP_MARKER_FILE :: "DESKTOP.OK"
DESKTOP_ENUM_FILE :: "ENUM.REG"
DESKTOP_DYNAMIC_ENUM_FILE :: "DYNENUM.REG"
DESKTOP_DISK_PROBE_FILE :: "DMAPROBE.BIN"
DMA_SETUP_FILE :: "DMASETUP.BAT"
DMA_INF_PATCH_FILE :: "PATCHINF.VBS"
DMA_INF_PATCH_SCRIPT := #load("patchinf.vbs")
DESKTOP_ARM_FILE :: "ARM.BAT"
DESKTOP_POSTBOOT_FILE :: "POSTBOOT.REG"
DESKTOP_CLEAN_FILE :: "CLEAN.REG"
DESKTOP_PENDING_FILE :: "REBOOT.PND"
DESKTOP_ARM_CHECK_FILE :: "ARMCHK.REG"
DESKTOP_DMA_REGISTRY_FILE :: "DMA.REG"
DESKTOP_HDC_STATE_FILE :: "HDC.REG"
DESKTOP_HDC_ZERO_FILE :: "HDC0.REG"
DESKTOP_HDC_PRIMARY_FILE :: "HDC1.REG"
DESKTOP_HDC_SECONDARY_FILE :: "HDC2.REG"
DESKTOP_HDC_THREE_FILE :: "HDC3.REG"
DESKTOP_MF_PRIMARY_FILE :: "MFPRI.REG"
DESKTOP_MF_SECONDARY_FILE :: "MFSEC.REG"
DESKTOP_DMA_CHECK_FILE :: "DMACHK.TMP"
MSBATCH_BOOT_OPTIONS_SECTION :: "RETVRN99BootOptions"
MSBATCH_AUTOMATIC_REBOOT :: "1"

normalize_msbatch_file :: proc(
	path: string,
	desktop_probe := false,
	host_locale: Host_Locale = {},
) -> bool {
	template, read_error := os.read_entire_file(path, context.allocator)
	if read_error != nil {return false}
	defer delete(template)

	normalized, ok := normalize_msbatch(string(template), desktop_probe, host_locale)
	if !ok {return false}
	defer delete(normalized)
	return os.write_entire_file(path, normalized) == nil
}

normalize_msbatch :: proc(
	template: string,
	desktop_probe := false,
	host_locale: Host_Locale = {},
) -> (
	string,
	bool,
) {
	settings := [?]Msbatch_Setting {
		{section = "Setup", key = "Express", value = "1"},
		{section = "Setup", key = "ProductKey", value = `"RW9MG-QR4G3-2WRR9-TG7BH-33GXB"`},
		{section = "Setup", key = "EBD", value = "0"},
		{section = "Setup", key = "ShowEula", value = "0"},
		{section = "Setup", key = "ChangeDir", value = "0"},
		{section = "Setup", key = "OptionalComponents", value = "0"},
		{section = "Setup", key = "System", value = "0"},
		{section = "Setup", key = "CCP", value = "0"},
		{section = "Setup", key = "CleanBoot", value = "0"},
		{section = "Setup", key = "Display", value = "0"},
		{section = "Setup", key = "DevicePath", value = "0"},
		{section = "Setup", key = "NoDirWarn", value = "1"},
		{section = "Setup", key = "Uninstall", value = "0"},
		{section = "Setup", key = "NoPrompt2Boot", value = MSBATCH_AUTOMATIC_REBOOT},
		{section = "Setup", key = "PenWinWarning", value = "0"},
		{section = "NameAndOrg", key = "Name", value = `"RETVRN99 User"`, add_section = true},
		{section = "NameAndOrg", key = "Org", value = `"RETVRN99"`, add_section = true},
		{section = "Network", key = "ComputerName", value = `"RETVRN99"`, add_section = true},
		{section = "Network", key = "Workgroup", value = `"WORKGROUP"`, add_section = true},
		{section = "Network", key = "Description", value = `"RETVRN99"`, add_section = true},
		{section = "Network", key = "ValidateNetCardResources", value = "0", add_section = true},
		{
			section = "Install",
			key = "AddReg",
			value = "OPKInstall",
			add_section = true,
			append_csv_last = true,
		},
		{
			section = "Install",
			key = "UpdateInis",
			value = MSBATCH_BOOT_OPTIONS_SECTION,
			add_section = true,
			append_csv = true,
		},
	}
	current := strings.clone(template)
	for setting in settings {
		next, ok := msbatch_set_value(current, setting)
		delete(current)
		if !ok {return "", false}
		current = next
	}
	if region, region_ok := msbatch_regional_settings_from_host(host_locale); region_ok {
		regional_settings := [?]Msbatch_Setting {
			{section = "System", key = "Locale", value = region.locale, add_section = true},
			{
				section = "System",
				key = "SelectedKeyboard",
				value = region.keyboard,
				add_section = true,
			},
		}
		for setting in regional_settings {
			next, set_ok := msbatch_set_value(current, setting)
			delete(current)
			if !set_ok {return "", false}
			current = next
		}
	}
	if zone, zone_ok := msbatch_host_time_zone(); zone_ok {
		quoted, allocation_error := strings.concatenate([]string{`"`, zone, `"`})
		if allocation_error != nil {delete(current); return "", false}
		defer delete(quoted)
		setting := Msbatch_Setting {
			section = "Setup",
			key     = "TimeZone",
			value   = quoted,
		}
		next, set_ok := msbatch_set_value(current, setting)
		delete(current)
		if !set_ok {return "", false}
		current = next
	}
	next, opk_ok := msbatch_set_opk_install(current, desktop_probe)
	delete(current)
	if !opk_ok {return "", false}
	current = next
	boot_options, boot_options_ok := msbatch_set_boot_options(current)
	delete(current)
	if !boot_options_ok {return "", false}
	current = boot_options
	return current, true
}

@(private)
msbatch_regional_settings_from_host :: proc(
	host_locale: Host_Locale,
) -> (
	Msbatch_Regional_Settings,
	bool,
) {
	if host_locale.language == "" || host_locale.country == "" {return {}, false}
	for region in MSBATCH_REGIONAL_SETTINGS {
		if strings.equal_fold(host_locale.language, region.language) &&
		   strings.equal_fold(host_locale.country, region.country) {
			return region, true
		}
	}
	return {}, false
}

post_setup_write :: proc(directory: string, desktop_probe := false) -> bool {
	stale_names := [?]string {
		DESKTOP_MARKER_FILE,
		DESKTOP_ENUM_FILE,
		DESKTOP_DYNAMIC_ENUM_FILE,
		DESKTOP_DISK_PROBE_FILE,
		DESKTOP_PROBE_FILE,
		DMA_SETUP_FILE,
		DMA_INF_PATCH_FILE,
		DESKTOP_ARM_FILE,
		DESKTOP_POSTBOOT_FILE,
		DESKTOP_CLEAN_FILE,
		DESKTOP_PENDING_FILE,
		DESKTOP_ARM_CHECK_FILE,
		DESKTOP_DMA_REGISTRY_FILE,
		DESKTOP_HDC_STATE_FILE,
		DESKTOP_HDC_ZERO_FILE,
		DESKTOP_HDC_PRIMARY_FILE,
		DESKTOP_HDC_SECONDARY_FILE,
		DESKTOP_HDC_THREE_FILE,
		DESKTOP_MF_PRIMARY_FILE,
		DESKTOP_MF_SECONDARY_FILE,
		DESKTOP_DMA_CHECK_FILE,
	}
	for name in stale_names {
		stale, stale_error := filepath.join({directory, name}, context.temp_allocator)
		if stale_error != nil {return false}
		if !desktop_probe_remove_stale(stale) {return false}
	}
	desktop_text :=
		"@ECHO OFF\r\n" +
		"COPY /B C:\\WINDOWS\\WIN.COM C:\\GSWSETUP\\DMAPROBE.BIN >NUL\r\n" +
		"IF ERRORLEVEL 1 GOTO GSWCLEAN\r\n" +
		"FC /B C:\\WINDOWS\\WIN.COM C:\\GSWSETUP\\DMAPROBE.BIN >NUL\r\n" +
		"IF ERRORLEVEL 1 GOTO GSWCLEAN\r\n" +
		"COPY /B C:\\GSWSETUP\\DMAPROBE.BIN NUL >NUL\r\n" +
		"IF ERRORLEVEL 1 GOTO GSWCLEAN\r\n" +
		"DEL C:\\GSWSETUP\\DMAPROBE.BIN >NUL\r\n" +
		"IF EXIST C:\\GSWSETUP\\DMAPROBE.BIN GOTO GSWEND\r\n" +
		"REGEDIT /E C:\\GSWSETUP\\ENUM.REG HKEY_LOCAL_MACHINE\\Enum\r\n" +
		"REGEDIT /E C:\\GSWSETUP\\DYNENUM.REG \"HKEY_DYN_DATA\\Config Manager\\Enum\"\r\n" +
		"IF NOT EXIST C:\\GSWSETUP\\ENUM.REG GOTO GSWEND\r\n" +
		"IF NOT EXIST C:\\GSWSETUP\\DYNENUM.REG GOTO GSWEND\r\n" +
		"REGEDIT /S C:\\GSWSETUP\\CLEAN.REG\r\n" +
		"IF EXIST C:\\GSWSETUP\\ARMCHK.REG DEL C:\\GSWSETUP\\ARMCHK.REG >NUL\r\n" +
		"IF EXIST C:\\GSWSETUP\\ARMCHK.REG GOTO GSWCLEAN\r\n" +
		"REGEDIT /E C:\\GSWSETUP\\ARMCHK.REG \"HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows\\CurrentVersion\\RunServices\"\r\n" +
		"IF NOT EXIST C:\\GSWSETUP\\ARMCHK.REG GOTO GSWCLEAN\r\n" +
		"FIND /I \"RETVRN99AcceptanceArm\" C:\\GSWSETUP\\ARMCHK.REG >NUL\r\n" +
		"IF ERRORLEVEL 2 GOTO GSWCLEAN\r\n" +
		"IF NOT ERRORLEVEL 1 GOTO GSWCLEAN\r\n" +
		"DEL C:\\GSWSETUP\\ARMCHK.REG >NUL\r\n" +
		"IF EXIST C:\\GSWSETUP\\ARMCHK.REG GOTO GSWCLEAN\r\n" +
		"DEL C:\\GSWSETUP\\REBOOT.PND >NUL\r\n" +
		"IF EXIST C:\\GSWSETUP\\REBOOT.PND GOTO GSWCLEAN\r\n" +
		"ECHO READY>C:\\GSWSETUP\\DESKTOP.OK\r\n" +
		"GOTO GSWEND\r\n" +
		":GSWCLEAN\r\n" +
		"IF EXIST C:\\GSWSETUP\\DMAPROBE.BIN DEL C:\\GSWSETUP\\DMAPROBE.BIN >NUL\r\n" +
		":GSWEND\r\n"
	acceptance_gate := ""
	if desktop_probe {
		acceptance_gate =
			"IF EXIST C:\\GSWSETUP\\ARMCHK.REG DEL C:\\GSWSETUP\\ARMCHK.REG >NUL\r\n" +
			"IF EXIST C:\\GSWSETUP\\ARMCHK.REG GOTO GSWEND\r\n" +
			"REGEDIT /E C:\\GSWSETUP\\ARMCHK.REG \"HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows\\CurrentVersion\\RunServices\"\r\n" +
			"IF NOT EXIST C:\\GSWSETUP\\ARMCHK.REG GOTO GSWCLEAN\r\n" +
			"FIND /I \"RETVRN99AcceptanceArm\" C:\\GSWSETUP\\ARMCHK.REG >NUL\r\n" +
			"IF ERRORLEVEL 1 GOTO GSWCLEAN\r\n" +
			"IF EXIST C:\\GSWSETUP\\MFPRI.REG DEL C:\\GSWSETUP\\MFPRI.REG >NUL\r\n" +
			"IF EXIST C:\\GSWSETUP\\MFPRI.REG GOTO GSWCLEAN\r\n" +
			"IF EXIST C:\\GSWSETUP\\MFSEC.REG DEL C:\\GSWSETUP\\MFSEC.REG >NUL\r\n" +
			"IF EXIST C:\\GSWSETUP\\MFSEC.REG GOTO GSWCLEAN\r\n" +
			"REGEDIT /E C:\\GSWSETUP\\MFPRI.REG HKEY_LOCAL_MACHINE\\Enum\\MF\\CHILD0000\r\n" +
			"IF NOT EXIST C:\\GSWSETUP\\MFPRI.REG GOTO GSWCLEAN\r\n" +
			"FIND /I \"MF\\\\GOODPRIMARY\" C:\\GSWSETUP\\MFPRI.REG >NUL\r\n" +
			"IF ERRORLEVEL 1 GOTO GSWCLEAN\r\n" +
			"FIND /I \"hdc\\\\0001\" C:\\GSWSETUP\\MFPRI.REG >NUL\r\n" +
			"IF ERRORLEVEL 1 GOTO GSWCLEAN\r\n" +
			"REGEDIT /E C:\\GSWSETUP\\MFSEC.REG HKEY_LOCAL_MACHINE\\Enum\\MF\\CHILD0001\r\n" +
			"IF NOT EXIST C:\\GSWSETUP\\MFSEC.REG GOTO GSWCLEAN\r\n" +
			"FIND /I \"MF\\\\GOODSECONDARY\" C:\\GSWSETUP\\MFSEC.REG >NUL\r\n" +
			"IF ERRORLEVEL 1 GOTO GSWCLEAN\r\n" +
			"FIND /I \"hdc\\\\0002\" C:\\GSWSETUP\\MFSEC.REG >NUL\r\n" +
			"IF ERRORLEVEL 1 GOTO GSWCLEAN\r\n" +
			"REGEDIT /E C:\\GSWSETUP\\HDC.REG HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Services\\Class\\hdc\r\n" +
			"IF NOT EXIST C:\\GSWSETUP\\HDC.REG GOTO GSWCLEAN\r\n" +
			"FIND /I \"ESDI_506.pdr\" C:\\GSWSETUP\\HDC.REG >NUL\r\n" +
			"IF ERRORLEVEL 1 GOTO GSWCLEAN\r\n"
	}
	dma_activation :=
		"%windir%\\COMMAND\\CSCRIPT.EXE //Nologo C:\\GSWSETUP\\PATCHINF.VBS %windir%\\INF\\MSHDC.INF ESDI_AddReg %windir%\\INF\\DISKDRV.INF DiskReg\r\n" +
		"IF ERRORLEVEL 1 GOTO GSWCLEAN\r\n" +
		"FIND /I \"HKR,,IDEDMADrive0,3,01\" %windir%\\INF\\MSHDC.INF >NUL\r\n" +
		"IF ERRORLEVEL 1 GOTO GSWCLEAN\r\n" +
		"FIND /I \"HKR,,IDEDMADrive1,3,01\" %windir%\\INF\\MSHDC.INF >NUL\r\n" +
		"IF ERRORLEVEL 1 GOTO GSWCLEAN\r\n" +
		"FIND /I \"HKR,,IDEDMADrive2,3,01\" %windir%\\INF\\MSHDC.INF >NUL\r\n" +
		"IF ERRORLEVEL 1 GOTO GSWCLEAN\r\n" +
		"FIND /I \"HKR,,IDEDMADrive3,3,01\" %windir%\\INF\\MSHDC.INF >NUL\r\n" +
		"IF ERRORLEVEL 1 GOTO GSWCLEAN\r\n" +
		"FIND /I \"HKR,,IDEDMADrive0,3,01\" %windir%\\INF\\DISKDRV.INF >NUL\r\n" +
		"IF ERRORLEVEL 1 GOTO GSWCLEAN\r\n" +
		"FIND /I \"HKR,,IDEDMADrive1,3,01\" %windir%\\INF\\DISKDRV.INF >NUL\r\n" +
		"IF ERRORLEVEL 1 GOTO GSWCLEAN\r\n" +
		"FIND /I \"HKR,,IDEDMADrive2,3,01\" %windir%\\INF\\DISKDRV.INF >NUL\r\n" +
		"IF ERRORLEVEL 1 GOTO GSWCLEAN\r\n" +
		"FIND /I \"HKR,,IDEDMADrive3,3,01\" %windir%\\INF\\DISKDRV.INF >NUL\r\n" +
		"IF ERRORLEVEL 1 GOTO GSWCLEAN\r\n" +
		"REGEDIT /S C:\\GSWSETUP\\DMA.REG\r\n"
	acceptance_restart := ""
	if desktop_probe {
		acceptance_restart =
			"ECHO PENDING>C:\\GSWSETUP\\REBOOT.PND\r\n" +
			"IF NOT EXIST C:\\GSWSETUP\\REBOOT.PND GOTO GSWCLEAN\r\n" +
			"DEL C:\\GSWSETUP\\ARMCHK.REG >NUL\r\n"
	}
	dma_registry_checks := desktop_dma_registry_checks()
	defer delete(dma_registry_checks)
	reboot_text, reboot_allocation_error := strings.concatenate(
		[]string {
			"@ECHO OFF\r\n",
			acceptance_gate,
			dma_activation,
			dma_registry_checks,
			acceptance_restart,
			"RUNDLL32.EXE SHELL32.DLL,SHExitWindowsEx 6\r\n" +
			"GOTO GSWEND\r\n" +
			":GSWCLEAN\r\n" +
			"IF EXIST C:\\GSWSETUP\\ARMCHK.REG DEL C:\\GSWSETUP\\ARMCHK.REG >NUL\r\n" +
			"IF EXIST C:\\GSWSETUP\\DMACHK.TMP DEL C:\\GSWSETUP\\DMACHK.TMP >NUL\r\n" +
			"IF EXIST C:\\GSWSETUP\\REBOOT.PND DEL C:\\GSWSETUP\\REBOOT.PND >NUL\r\n" +
			":GSWEND\r\n",
		},
	)
	if reboot_allocation_error != nil {return false}
	defer delete(reboot_text)
	arm_text :=
		"@ECHO OFF\r\n" +
		"IF NOT EXIST C:\\GSWSETUP\\REBOOT.PND GOTO GSWEND\r\n" +
		"REGEDIT /S C:\\GSWSETUP\\POSTBOOT.REG\r\n" +
		":GSWEND\r\n"
	postboot_text :=
		"REGEDIT4\r\n\r\n" +
		"[HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce]\r\n" +
		`"RETVRN99Acceptance"="COMMAND.COM /C C:\\GSWSETUP\\DESKTOP.BAT"` +
		"\r\n"
	clean_text :=
		"REGEDIT4\r\n\r\n" +
		"[HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows\\CurrentVersion\\RunServices]\r\n" +
		`"RETVRN99AcceptanceArm"=-` +
		"\r\n"
	dma_text :=
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
		"\r\n"
	if !desktop_probe {
		return(
			desktop_probe_write_file(directory, DMA_SETUP_FILE, reboot_text) &&
			desktop_probe_write_crlf_file(
				directory,
				DMA_INF_PATCH_FILE,
				string(DMA_INF_PATCH_SCRIPT),
			) &&
			desktop_probe_write_file(directory, DESKTOP_DMA_REGISTRY_FILE, dma_text) \
		)
	}
	return(
		desktop_probe_write_file(directory, DESKTOP_PROBE_FILE, desktop_text) &&
		desktop_probe_write_file(directory, DMA_SETUP_FILE, reboot_text) &&
		desktop_probe_write_crlf_file(
			directory,
			DMA_INF_PATCH_FILE,
			string(DMA_INF_PATCH_SCRIPT),
		) &&
		desktop_probe_write_file(directory, DESKTOP_ARM_FILE, arm_text) &&
		desktop_probe_write_file(directory, DESKTOP_POSTBOOT_FILE, postboot_text) &&
		desktop_probe_write_file(directory, DESKTOP_CLEAN_FILE, clean_text) &&
		desktop_probe_write_file(directory, DESKTOP_DMA_REGISTRY_FILE, dma_text) \
	)
}

@(private)
desktop_dma_registry_checks :: proc() -> string {
	b := strings.builder_make(0, 6144)
	keys := [?]string{"0000", "0001", "0002", "0003"}
	files := [?]string{"HDC0.REG", "HDC1.REG", "HDC2.REG", "HDC3.REG"}
	drives := [?]string{"0", "1", "2", "3"}
	for file, index in files {
		strings.write_string(&b, "IF EXIST C:\\GSWSETUP\\")
		strings.write_string(&b, file)
		strings.write_string(&b, " DEL C:\\GSWSETUP\\")
		strings.write_string(&b, file)
		strings.write_string(&b, " >NUL\r\n")
		strings.write_string(&b, "IF EXIST C:\\GSWSETUP\\")
		strings.write_string(&b, file)
		strings.write_string(&b, " GOTO GSWCLEAN\r\n")
		strings.write_string(&b, "REGEDIT /E C:\\GSWSETUP\\")
		strings.write_string(&b, file)
		strings.write_string(
			&b,
			" HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Services\\Class\\hdc\\",
		)
		strings.write_string(&b, keys[index])
		strings.write_string(&b, "\r\n")
		strings.write_string(&b, "IF NOT EXIST C:\\GSWSETUP\\")
		strings.write_string(&b, file)
		strings.write_string(&b, " GOTO GSWCLEAN\r\n")
		for drive in drives {
			strings.write_string(&b, "FIND /I \"IDEDMADRIVE")
			strings.write_string(&b, drive)
			strings.write_string(&b, "\" C:\\GSWSETUP\\")
			strings.write_string(&b, file)
			strings.write_string(&b, " >C:\\GSWSETUP\\DMACHK.TMP\r\n")
			strings.write_string(&b, "IF ERRORLEVEL 1 GOTO GSWCLEAN\r\n")
			strings.write_string(&b, "FIND /I \"hex:01\" C:\\GSWSETUP\\DMACHK.TMP >NUL\r\n")
			strings.write_string(&b, "IF ERRORLEVEL 1 GOTO GSWCLEAN\r\n")
			strings.write_string(&b, "DEL C:\\GSWSETUP\\DMACHK.TMP >NUL\r\n")
			strings.write_string(&b, "IF EXIST C:\\GSWSETUP\\DMACHK.TMP GOTO GSWCLEAN\r\n")
		}
	}
	return strings.to_string(b)
}

@(private)
desktop_probe_write_file :: proc(directory, name, text: string) -> bool {
	path, path_error := filepath.join({directory, name}, context.temp_allocator)
	if path_error != nil {return false}
	defer delete(path, context.temp_allocator)
	return os.write_entire_file(path, text) == nil
}

@(private)
desktop_probe_write_crlf_file :: proc(directory, name, text: string) -> bool {
	b := strings.builder_make(0, len(text) + 64)
	index := 0
	for index < len(text) {
		if text[index] == '\r' {
			index += 1
			if index < len(text) && text[index] == '\n' {index += 1}
			strings.write_string(&b, "\r\n")
		} else if text[index] == '\n' {
			index += 1
			strings.write_string(&b, "\r\n")
		} else {
			strings.write_byte(&b, text[index])
			index += 1
		}
	}
	normalized := strings.to_string(b)
	defer delete(normalized)
	return desktop_probe_write_file(directory, name, normalized)
}

@(private)
desktop_probe_remove_stale :: proc(path: string) -> bool {
	info, stat_error := os.lstat(path, context.temp_allocator)
	if stat_error == os.General_Error.Not_Exist {return true}
	if stat_error != nil {return false}
	os.file_info_delete(info, context.temp_allocator)
	if os.remove(path) != nil {return false}

	remaining, remaining_error := os.lstat(path, context.temp_allocator)
	if remaining_error == nil {
		os.file_info_delete(remaining, context.temp_allocator)
		return false
	}
	return remaining_error == os.General_Error.Not_Exist
}

@(private)
msbatch_host_time_zone :: proc() -> (string, bool) {
	region, ok := timezone.region_load("local")
	if !ok {return "", false}
	if region == nil {return "GMT", true}
	defer timezone.region_destroy(region)
	return msbatch_time_zone_from_host(region.name)
}

@(private)
msbatch_time_zone_from_host :: proc(name: string) -> (string, bool) {
	switch name {
	case "Europe/Madrid",
	     "Europe/Paris",
	     "Europe/Brussels",
	     "Europe/Copenhagen",
	     "Romance Standard Time",
	     "Romance":
		return "Romance", true
	case "Europe/Berlin",
	     "Europe/Rome",
	     "Europe/Stockholm",
	     "Europe/Vienna",
	     "Europe/Amsterdam",
	     "W. Europe Standard Time",
	     "W. Europe":
		return "W. Europe", true
	case "Europe/London", "Europe/Lisbon", "GMT Standard Time", "GMT":
		return "GMT", true
	case "America/Los_Angeles", "Pacific Standard Time", "Pacific":
		return "Pacific", true
	case "America/Denver", "Mountain Standard Time", "Mountain":
		return "Mountain", true
	case "America/Chicago", "Central Standard Time", "Central":
		return "Central", true
	case "America/New_York", "Eastern Standard Time", "Eastern":
		return "Eastern", true
	case "Asia/Tokyo", "Tokyo Standard Time", "Tokyo":
		return "Tokyo", true
	case "Australia/Sydney", "AUS Eastern Standard Time", "Sydney":
		return "Sydney", true
	case "UTC", "Etc/UTC", "Etc/GMT":
		return "GMT", true
	}
	return "", false
}

@(private)
msbatch_set_value :: proc(template: string, setting: Msbatch_Setting) -> (string, bool) {
	b := strings.builder_make(0, len(template) + 32)
	active_template := template
	eof_suffix := ""
	for index in 0 ..< len(template) {
		if template[index] == '\x1a' {
			active_template = template[:index]
			eof_suffix = template[index:]
			break
		}
	}
	in_section := false
	found_section := false
	found_key := false
	line_ending := "\r\n"
	cursor := 0

	for cursor < len(active_template) {
		line_start := cursor
		for cursor < len(active_template) &&
		    active_template[cursor] != '\r' &&
		    active_template[cursor] != '\n' {
			cursor += 1
		}
		line_end := cursor
		if cursor < len(active_template) && active_template[cursor] == '\r' {cursor += 1}
		if cursor < len(active_template) && active_template[cursor] == '\n' {cursor += 1}
		ending := active_template[line_end:cursor]
		if len(ending) > 0 {line_ending = ending}
		line := active_template[line_start:line_end]
		trimmed := ascii_trim(line)

		if msbatch_section_line(trimmed) {
			if in_section && !found_key {
				msbatch_write_value(&b, setting)
				strings.write_string(&b, line_ending)
				found_key = true
			}
			in_section = msbatch_section_matches(trimmed, setting.section)
			found_section = found_section || in_section
		}

		if in_section && msbatch_key_line(trimmed, setting.key) {
			if setting.append_csv_last {
				msbatch_write_csv_last_value(&b, trimmed, setting)
			} else if setting.append_csv {
				msbatch_write_csv_value(&b, trimmed, setting)
			} else {
				msbatch_write_value(&b, setting)
			}
			strings.write_string(&b, ending)
			found_key = true
		} else {
			strings.write_string(&b, line)
			strings.write_string(&b, ending)
		}
	}

	if in_section && !found_key {
		if len(active_template) > 0 &&
		   active_template[len(active_template) - 1] != '\r' &&
		   active_template[len(active_template) - 1] != '\n' {
			strings.write_string(&b, line_ending)
		}
		msbatch_write_value(&b, setting)
		strings.write_string(&b, line_ending)
		found_key = true
	}

	if !found_section && setting.add_section {
		if len(active_template) > 0 &&
		   active_template[len(active_template) - 1] != '\r' &&
		   active_template[len(active_template) - 1] != '\n' {
			strings.write_string(&b, line_ending)
		}
		strings.write_string(&b, "[")
		strings.write_string(&b, setting.section)
		strings.write_string(&b, "]")
		strings.write_string(&b, line_ending)
		msbatch_write_value(&b, setting)
		strings.write_string(&b, line_ending)
		found_section = true
		found_key = true
	}

	if !found_section || !found_key {
		strings.builder_destroy(&b)
		return "", false
	}
	strings.write_string(&b, eof_suffix)
	return strings.to_string(b), true
}

@(private)
msbatch_write_value :: proc(b: ^strings.Builder, setting: Msbatch_Setting) {
	strings.write_string(b, setting.key)
	strings.write_string(b, "=")
	strings.write_string(b, setting.value)
}

@(private)
msbatch_write_csv_value :: proc(b: ^strings.Builder, line: string, setting: Msbatch_Setting) {
	equals := strings.index_byte(line, '=')
	existing := equals >= 0 ? ascii_trim(line[equals + 1:]) : ""
	strings.write_string(b, setting.key)
	strings.write_string(b, "=")
	strings.write_string(b, existing)
	if msbatch_csv_contains(existing, setting.value) {return}
	if existing != "" {strings.write_string(b, ",")}
	strings.write_string(b, setting.value)
}

@(private)
msbatch_write_csv_last_value :: proc(b: ^strings.Builder, line: string, setting: Msbatch_Setting) {
	equals := strings.index_byte(line, '=')
	existing := equals >= 0 ? ascii_trim(line[equals + 1:]) : ""
	strings.write_string(b, setting.key)
	strings.write_string(b, "=")
	written := false
	cursor := 0
	for cursor <= len(existing) {
		next := strings.index_byte(existing[cursor:], ',')
		end := next < 0 ? len(existing) : cursor + next
		value := ascii_trim(existing[cursor:end])
		if value != "" && !ascii_equal_fold(value, setting.value) {
			if written {strings.write_string(b, ",")}
			strings.write_string(b, value)
			written = true
		}
		if next < 0 {break}
		cursor = end + 1
	}
	if written {strings.write_string(b, ",")}
	strings.write_string(b, setting.value)
}

@(private)
msbatch_csv_contains :: proc(values, wanted: string) -> bool {
	cursor := 0
	for cursor <= len(values) {
		next := strings.index_byte(values[cursor:], ',')
		end := next < 0 ? len(values) : cursor + next
		if ascii_equal_fold(ascii_trim(values[cursor:end]), wanted) {return true}
		if next < 0 {break}
		cursor = end + 1
	}
	return false
}

@(private)
msbatch_set_opk_install :: proc(template: string, desktop_probe := false) -> (string, bool) {
	b := strings.builder_make(0, len(template) + 320)
	active_template := template
	eof_suffix := ""
	for index in 0 ..< len(template) {
		if template[index] == '\x1a' {
			active_template = template[:index]
			eof_suffix = template[index:]
			break
		}
	}
	found := false
	skipping := false
	line_ending := "\r\n"
	cursor := 0
	for cursor < len(active_template) {
		line_start := cursor
		for cursor < len(active_template) &&
		    active_template[cursor] != '\r' &&
		    active_template[cursor] != '\n' {
			cursor += 1
		}
		line_end := cursor
		if cursor < len(active_template) && active_template[cursor] == '\r' {cursor += 1}
		if cursor < len(active_template) && active_template[cursor] == '\n' {cursor += 1}
		ending := active_template[line_end:cursor]
		if ending != "" {line_ending = ending}
		line := active_template[line_start:line_end]
		trimmed := ascii_trim(line)
		if msbatch_section_line(trimmed) {
			if msbatch_section_matches(trimmed, "OPKInstall") {
				if !found {
					strings.write_string(&b, "[OPKInstall]")
					strings.write_string(&b, ending != "" ? ending : line_ending)
					msbatch_write_opk_install(&b, line_ending, desktop_probe)
					found = true
				}
				skipping = true
				continue
			}
			skipping = false
		}
		if skipping {continue}
		strings.write_string(&b, line)
		strings.write_string(&b, ending)
	}
	if !found {
		if len(active_template) > 0 &&
		   active_template[len(active_template) - 1] != '\r' &&
		   active_template[len(active_template) - 1] != '\n' {
			strings.write_string(&b, line_ending)
		}
		strings.write_string(&b, "[OPKInstall]")
		strings.write_string(&b, line_ending)
		msbatch_write_opk_install(&b, line_ending, desktop_probe)
	}
	strings.write_string(&b, eof_suffix)
	return strings.to_string(b), true
}

@(private)
msbatch_write_opk_install :: proc(
	b: ^strings.Builder,
	line_ending: string,
	desktop_probe := false,
) {
	lines := [?]string {
		`HKLM,"SOFTWARE\Microsoft\Windows\CurrentVersion","ProductId",,"12345-OEM-1234567-12345"`,
		`HKLM,"SOFTWARE\Microsoft\Windows\CurrentVersion","ProductKey",,"RW9MG-QR4G3-2WRR9-TG7BH-33GXB"`,
		`HKLM,"SOFTWARE\Microsoft\Windows\CurrentVersion","RegisteredOwner",,"RETVRN99 User"`,
		`HKLM,"SOFTWARE\Microsoft\Windows\CurrentVersion","RegisteredOrganization",,"RETVRN99"`,
		// OEM recovery templates can otherwise block the first desktop behind SRW.EXE.
		`HKLM,"SOFTWARE\Microsoft\Windows\CurrentVersion\Run","BatchReg1",0x00000004`,
	}
	for line in lines {
		strings.write_string(b, line)
		strings.write_string(b, line_ending)
	}
	strings.write_string(
		b,
		`HKLM,"Software\Microsoft\Windows\CurrentVersion\RunOnce","RETVRN99DMASetup",,"COMMAND.COM /C C:\GSWSETUP\DMASETUP.BAT"`,
	)
	strings.write_string(b, line_ending)
	if desktop_probe {
		strings.write_string(
			b,
			`HKLM,"Software\Microsoft\Windows\CurrentVersion\RunServices","RETVRN99AcceptanceArm",,"COMMAND.COM /C C:\GSWSETUP\ARM.BAT"`,
		)
		strings.write_string(b, line_ending)
	}
}

@(private)
msbatch_set_boot_options :: proc(template: string) -> (string, bool) {
	lines := [?]string{`%30%\MSDOS.SYS,Options,,"BootMenuDefault=1"`}
	return msbatch_replace_section(template, MSBATCH_BOOT_OPTIONS_SECTION, lines[:])
}

@(private)
msbatch_replace_section :: proc(template, section: string, lines: []string) -> (string, bool) {
	b := strings.builder_make(0, len(template) + 96)
	active_template := template
	eof_suffix := ""
	for index in 0 ..< len(template) {
		if template[index] == '\x1a' {
			active_template = template[:index]
			eof_suffix = template[index:]
			break
		}
	}
	found := false
	skipping := false
	line_ending := "\r\n"
	cursor := 0
	for cursor < len(active_template) {
		line_start := cursor
		for cursor < len(active_template) &&
		    active_template[cursor] != '\r' &&
		    active_template[cursor] != '\n' {
			cursor += 1
		}
		line_end := cursor
		if cursor < len(active_template) && active_template[cursor] == '\r' {cursor += 1}
		if cursor < len(active_template) && active_template[cursor] == '\n' {cursor += 1}
		ending := active_template[line_end:cursor]
		if ending != "" {line_ending = ending}
		line := active_template[line_start:line_end]
		trimmed := ascii_trim(line)
		if msbatch_section_line(trimmed) {
			if msbatch_section_matches(trimmed, section) {
				if !found {
					msbatch_write_section(&b, section, lines, ending != "" ? ending : line_ending)
					found = true
				}
				skipping = true
				continue
			}
			skipping = false
		}
		if skipping {continue}
		strings.write_string(&b, line)
		strings.write_string(&b, ending)
	}
	if !found {
		if len(active_template) > 0 &&
		   active_template[len(active_template) - 1] != '\r' &&
		   active_template[len(active_template) - 1] != '\n' {
			strings.write_string(&b, line_ending)
		}
		msbatch_write_section(&b, section, lines, line_ending)
	}
	strings.write_string(&b, eof_suffix)
	return strings.to_string(b), true
}

@(private)
msbatch_write_section :: proc(
	b: ^strings.Builder,
	section: string,
	lines: []string,
	line_ending: string,
) {
	strings.write_string(b, "[")
	strings.write_string(b, section)
	strings.write_string(b, "]")
	strings.write_string(b, line_ending)
	for line in lines {
		strings.write_string(b, line)
		strings.write_string(b, line_ending)
	}
}

@(private)
msbatch_section_line :: proc(line: string) -> bool {
	return len(line) >= 2 && line[0] == '[' && line[len(line) - 1] == ']'
}

@(private)
msbatch_section_matches :: proc(line, section: string) -> bool {
	if !msbatch_section_line(line) || len(line) != len(section) + 2 {return false}
	return ascii_equal_fold(line[1:len(line) - 1], section)
}

@(private)
msbatch_key_line :: proc(line, key: string) -> bool {
	if len(line) <= len(key) || !ascii_equal_fold(line[:len(key)], key) {return false}
	cursor := len(key)
	for cursor < len(line) && (line[cursor] == ' ' || line[cursor] == '\t') {cursor += 1}
	return cursor < len(line) && line[cursor] == '='
}

@(private)
ascii_trim :: proc(value: string) -> string {
	first := 0
	last := len(value)
	for first < last && (value[first] == ' ' || value[first] == '\t') {first += 1}
	for last > first && (value[last - 1] == ' ' || value[last - 1] == '\t') {last -= 1}
	return value[first:last]
}

@(private)
ascii_equal_fold :: proc(a, b: string) -> bool {
	if len(a) != len(b) {return false}
	for i in 0 ..< len(a) {
		ac := a[i]
		bc := b[i]
		if ac >= 'a' && ac <= 'z' {ac -= 'a' - 'A'}
		if bc >= 'a' && bc <= 'z' {bc -= 'a' - 'A'}
		if ac != bc {return false}
	}
	return true
}
