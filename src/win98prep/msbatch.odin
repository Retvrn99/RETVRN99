// SPDX-License-Identifier: GPL-3.0-only
package win98prep

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time/timezone"

Msbatch_Setting :: struct {
	section:     string,
	key:         string,
	value:       string,
	add_section: bool,
	append_csv:  bool,
}

DESKTOP_PROBE_FILE :: "DESKTOP.BAT"
DESKTOP_MARKER_FILE :: "DESKTOP.OK"
DESKTOP_ENUM_FILE :: "ENUM.REG"
DESKTOP_DYNAMIC_ENUM_FILE :: "DYNENUM.REG"
MSBATCH_BOOT_OPTIONS_SECTION :: "RETVRN99BootOptions"

normalize_msbatch_file :: proc(path: string, desktop_probe := false) -> bool {
	template, read_error := os.read_entire_file(path, context.allocator)
	if read_error != nil {return false}
	defer delete(template)

	normalized, ok := normalize_msbatch(string(template), desktop_probe)
	if !ok {return false}
	defer delete(normalized)
	return os.write_entire_file(path, normalized) == nil
}

normalize_msbatch :: proc(template: string, desktop_probe := false) -> (string, bool) {
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
		{section = "Setup", key = "NoPrompt2Boot", value = "1"},
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
			append_csv = true,
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

desktop_probe_write :: proc(directory: string) -> bool {
	stale_names := [?]string {
		DESKTOP_MARKER_FILE,
		DESKTOP_ENUM_FILE,
		DESKTOP_DYNAMIC_ENUM_FILE,
	}
	for name in stale_names {
		stale, stale_error := filepath.join({directory, name}, context.temp_allocator)
		if stale_error != nil {return false}
		if !desktop_probe_remove_stale(stale) {return false}
	}
	path, path_error := filepath.join({directory, DESKTOP_PROBE_FILE}, context.temp_allocator)
	if path_error != nil {return false}
	defer delete(path, context.temp_allocator)
	text :=
		"@ECHO OFF\r\n" +
		"REGEDIT /E C:\\GSWSETUP\\ENUM.REG HKEY_LOCAL_MACHINE\\Enum\r\n" +
		"REGEDIT /E C:\\GSWSETUP\\DYNENUM.REG \"HKEY_DYN_DATA\\Config Manager\\Enum\"\r\n" +
		"IF NOT EXIST C:\\GSWSETUP\\ENUM.REG GOTO GSWEND\r\n" +
		"IF NOT EXIST C:\\GSWSETUP\\DYNENUM.REG GOTO GSWEND\r\n" +
		"ECHO READY>C:\\GSWSETUP\\DESKTOP.OK\r\n" +
		":GSWEND\r\n"
	return os.write_entire_file(path, text) == nil
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
			if setting.append_csv {
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
	}
	for line in lines {
		strings.write_string(b, line)
		strings.write_string(b, line_ending)
	}
	if desktop_probe {
		strings.write_string(
			b,
			`HKLM,"Software\Microsoft\Windows\CurrentVersion\RunOnce","RETVRN99Acceptance",,"COMMAND.COM /C C:\GSWSETUP\DESKTOP.BAT"`,
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
