// SPDX-License-Identifier: GPL-3.0-only
package win98imageprep

import "base:runtime"
import "core:strings"

Driver_Custom_INF_Diagnostic :: enum u8 {
	None,
	Invalid_Manifest,
	Package_Collision,
	Hardware_ID_Collision,
	Filename_Collision,
	Duplicate_Section,
	Owned_Content_Collision,
	Allocation_Failed,
}

Driver_Custom_INF_Entry :: struct {
	package_id:      string,
	inf_name:        string,
	precopy_section: string,
	install_section: string,
	inf_section:     string,
	precopy_ref:     string,
	base_ref:        string,
	install_copy:    string,
	precopy_dest:    string,
	inf_dest:        string,
}

Driver_Custom_INF_State :: struct {
	precopy_refs:   int,
	base_refs:      int,
	precopy_dests:  int,
	inf_dests:      int,
	precopy_header: bool,
	precopy_lines:  int,
	install_header: bool,
	install_lines:  int,
	inf_header:     bool,
	inf_lines:      int,
}

driver_custom_inf_merge :: proc(
	existing: string,
	manifests: []Driver_Package_Manifest,
) -> (
	string,
	Driver_Custom_INF_Diagnostic,
) {
	entries, diagnostic := driver_custom_entries(manifests)
	if diagnostic != .None {return "", diagnostic}
	defer driver_custom_entries_destroy(entries)
	already_applied, scan_diagnostic := driver_custom_inf_scan(existing, entries)
	if scan_diagnostic != .None {return "", scan_diagnostic}

	current := strings.clone(existing)
	if current == "" {
		delete(current)
		current = strings.clone(
			";\r\n; CUSTOM.INF\r\n;\r\n\r\n" +
			"[Version]\r\n" +
			"Signature=\"$CHICAGO$\"\r\n" +
			"SetupClass=BASE\r\n" +
			"LayoutFile=layout.inf,layout1.inf,layout2.inf\r\n\r\n" +
			"[SourceDisksNames]\r\n" +
			"101=\"Custom INF Precopy files\",,0\r\n\r\n" +
			"[SourceDisksFiles]\r\n\r\n" +
			"[DestinationDirs]\r\n\r\n" +
			"[Strings]\r\n",
		)
	}
	precopy_lines := make([]string, len(entries), context.temp_allocator)
	base_lines := make([]string, len(entries), context.temp_allocator)
	for entry, index in entries {
		precopy_lines[index] = entry.precopy_ref
		base_lines[index] = entry.base_ref
	}
	version_lines := [?]string {
		"Signature=\"$CHICAGO$\"",
		"SetupClass=BASE",
		"LayoutFile=layout.inf,layout1.inf,layout2.inf",
	}
	next, ok := driver_custom_append_section_lines(current, "Version", version_lines[:])
	delete(current)
	if !ok {return "", .Owned_Content_Collision}
	current = next
	source_names := [?]string{`101="Custom INF Precopy files",,0`}
	next, ok = driver_custom_append_section_lines(current, "SourceDisksNames", source_names[:])
	delete(current)
	if !ok {return "", .Owned_Content_Collision}
	current = next
	next, ok = driver_custom_append_section_lines(current, "SourceDisksFiles", nil)
	delete(current)
	if !ok {return "", .Owned_Content_Collision}
	current = next
	destination_lines := make([]string, len(entries) * 2, context.temp_allocator)
	for entry, index in entries {
		destination_lines[index * 2] = entry.precopy_dest
		destination_lines[index * 2 + 1] = entry.inf_dest
	}
	next, ok = driver_custom_append_section_lines(current, "DestinationDirs", destination_lines)
	delete(current)
	if !ok {return "", .Owned_Content_Collision}
	current = next
	next, ok = driver_custom_append_section_lines(current, "CUSTOM_PRECOPY", precopy_lines)
	delete(current)
	if !ok {return "", .Owned_Content_Collision}
	current = next
	next, ok = driver_custom_append_section_lines(current, "BaseWinOptions", base_lines)
	delete(current)
	if !ok {return "", .Owned_Content_Collision}
	current = next
	next, ok = driver_custom_append_section_lines(current, "Strings", nil)
	delete(current)
	if !ok {return "", .Owned_Content_Collision}
	current = next
	if already_applied {
		if applied, verify_diagnostic := driver_custom_inf_scan(current, entries);
		   verify_diagnostic != .None || !applied {
			delete(current)
			return "", verify_diagnostic != .None ? verify_diagnostic : .Owned_Content_Collision
		}
		return current, .None
	}
	next, ok = driver_custom_append_owned_sections(current, entries)
	delete(current)
	if !ok {return "", .Allocation_Failed}
	if applied, verify_diagnostic := driver_custom_inf_scan(next, entries);
	   verify_diagnostic != .None || !applied {
		delete(next)
		return "", verify_diagnostic != .None ? verify_diagnostic : .Owned_Content_Collision
	}
	return next, .None
}

@(private)
driver_custom_entries :: proc(
	manifests: []Driver_Package_Manifest,
) -> (
	[]Driver_Custom_INF_Entry,
	Driver_Custom_INF_Diagnostic,
) {
	if len(manifests) == 0 || len(manifests) > DRIVER_PACKAGE_MAX_FILES {
		return nil, .Invalid_Manifest
	}
	for manifest, index in manifests {
		if manifest.mode != .PnP_Driver || driver_manifest_validate(manifest) != .None {
			return nil, .Invalid_Manifest
		}
		for prior in 0 ..< index {
			other := manifests[prior]
			if strings.equal_fold(manifest.package_id, other.package_id) {
				return nil, .Package_Collision
			}
			for hardware_id in manifest.hardware_ids {
				for other_id in other.hardware_ids {
					if strings.equal_fold(hardware_id, other_id) {
						return nil, .Hardware_ID_Collision
					}
				}
			}
			for file in manifest.files {
				for other_file in other.files {
					if strings.equal_fold(file.destination_name, other_file.destination_name) ||
					   driver_destination_alias(file.destination_name) ==
						   driver_destination_alias(other_file.destination_name) {
						return nil, .Filename_Collision
					}
				}
			}
		}
	}
	entries := make([]Driver_Custom_INF_Entry, len(manifests))
	for manifest, index in manifests {
		inf_name := ""
		for file in manifest.files {
			if file.kind == .INF {inf_name = file.destination_name; break}
		}
		entry, ok := driver_custom_entry_make(manifest.package_id, inf_name)
		if !ok {
			driver_custom_entries_destroy(entries)
			return nil, .Allocation_Failed
		}
		entries[index] = entry
	}
	for index in 1 ..< len(entries) {
		cursor := index
		for cursor > 0 &&
		    driver_ascii_less_fold(entries[cursor].inf_name, entries[cursor - 1].inf_name) {
			entries[cursor], entries[cursor - 1] = entries[cursor - 1], entries[cursor]
			cursor -= 1
		}
	}
	return entries, .None
}

@(private)
driver_custom_entry_make :: proc(package_id, inf_name: string) -> (Driver_Custom_INF_Entry, bool) {
	entry := Driver_Custom_INF_Entry {
		package_id = package_id,
		inf_name   = inf_name,
	}
	allocation_error: runtime.Allocator_Error
	entry.precopy_section, allocation_error = strings.concatenate(
		[]string{"RETVRN99.", package_id, ".PreCopy"},
	)
	if allocation_error == nil {
		entry.install_section, allocation_error = strings.concatenate(
			[]string{"RETVRN99.", package_id, ".Install"},
		)
	}
	if allocation_error == nil {
		entry.inf_section, allocation_error = strings.concatenate(
			[]string{"RETVRN99.", package_id, ".INF.Files"},
		)
	}
	if allocation_error == nil {
		entry.precopy_ref, allocation_error = strings.concatenate(
			[]string{"CopyFiles=", entry.precopy_section},
		)
	}
	if allocation_error == nil {entry.base_ref = strings.clone(entry.install_section)}
	if allocation_error == nil {
		entry.install_copy, allocation_error = strings.concatenate(
			[]string{"CopyFiles=", entry.inf_section},
		)
	}
	if allocation_error == nil {
		entry.precopy_dest, allocation_error = strings.concatenate(
			[]string{entry.precopy_section, "=2"},
		)
	}
	if allocation_error == nil {
		entry.inf_dest, allocation_error = strings.concatenate([]string{entry.inf_section, "=17"})
	}
	if allocation_error != nil {
		driver_custom_entry_destroy(&entry)
		return {}, false
	}
	return entry, true
}

@(private)
driver_custom_entry_destroy :: proc(entry: ^Driver_Custom_INF_Entry) {
	if entry == nil {return}
	delete(entry.precopy_section)
	delete(entry.install_section)
	delete(entry.inf_section)
	delete(entry.precopy_ref)
	delete(entry.base_ref)
	delete(entry.install_copy)
	delete(entry.precopy_dest)
	delete(entry.inf_dest)
	entry^ = {}
}

@(private)
driver_custom_entries_destroy :: proc(entries: []Driver_Custom_INF_Entry) {
	for &entry in entries {driver_custom_entry_destroy(&entry)}
	delete(entries)
}

@(private)
driver_custom_inf_scan :: proc(
	text: string,
	entries: []Driver_Custom_INF_Entry,
) -> (
	bool,
	Driver_Custom_INF_Diagnostic,
) {
	active := text
	for byte, index in text {
		if byte == '\x1a' {active = text[:index]; break}
	}
	states := make([]Driver_Custom_INF_State, len(entries), context.temp_allocator)
	sections := make([dynamic]string, context.temp_allocator)
	current_kind := -1
	current_entry := -1
	cursor := 0
	for {
		line, _, ok := driver_inf_next_line(active, &cursor)
		if !ok {break}
		if name, is_section := driver_inf_section_name(line); is_section {
			for prior in sections {
				if strings.equal_fold(prior, name) {return false, .Duplicate_Section}
			}
			append(&sections, name)
			current_kind = -1
			current_entry = -1
			if strings.equal_fold(name, "CUSTOM_PRECOPY") {
				current_kind = 0
			} else if strings.equal_fold(name, "BaseWinOptions") {
				current_kind = 1
			} else if strings.equal_fold(name, "DestinationDirs") {
				current_kind = 5
			} else {
				for entry, index in entries {
					if strings.equal_fold(name, entry.precopy_section) {
						current_kind, current_entry = 2, index
						states[index].precopy_header = true
						break
					} else if strings.equal_fold(name, entry.install_section) {
						current_kind, current_entry = 3, index
						states[index].install_header = true
						break
					} else if strings.equal_fold(name, entry.inf_section) {
						current_kind, current_entry = 4, index
						states[index].inf_header = true
						break
					}
				}
				if current_kind < 0 && driver_ascii_contains_fold(name, "RETVRN99.") {
					return false, .Owned_Content_Collision
				}
			}
			continue
		}
		meaningful := driver_custom_meaningful_line(line)
		if meaningful == "" {continue}
		switch current_kind {
		case 0, 1, 5:
			matched := false
			for entry, index in entries {
				expected :=
					current_kind == 0 ? entry.precopy_ref : current_kind == 1 ? entry.base_ref : entry.precopy_dest
				if ascii_equal_fold(meaningful, expected) {
					if current_kind ==
					   0 {states[index].precopy_refs += 1} else if current_kind == 1 {states[index].base_refs += 1} else {states[index].precopy_dests += 1}
					matched = true
					break
				}
				if current_kind == 5 && ascii_equal_fold(meaningful, entry.inf_dest) {
					states[index].inf_dests += 1
					matched = true
					break
				}
			}
			if !matched && driver_ascii_contains_fold(meaningful, "RETVRN99.") {
				return false, .Owned_Content_Collision
			}
		case 2, 3, 4:
			entry := entries[current_entry]
			expected :=
				current_kind == 2 ? entry.inf_name : current_kind == 3 ? entry.install_copy : entry.inf_name
			if !ascii_equal_fold(meaningful, expected) {
				return false, .Owned_Content_Collision
			}
			if current_kind ==
			   2 {states[current_entry].precopy_lines += 1} else if current_kind == 3 {states[current_entry].install_lines += 1} else {states[current_entry].inf_lines += 1}
		case -1:
			if driver_ascii_contains_fold(meaningful, "RETVRN99.") {
				return false, .Owned_Content_Collision
			}
		}
	}
	all_present := true
	any_present := false
	for state in states {
		present :=
			state.precopy_refs != 0 ||
			state.base_refs != 0 ||
			state.precopy_dests != 0 ||
			state.inf_dests != 0 ||
			state.precopy_header ||
			state.install_header ||
			state.inf_header
		complete :=
			state.precopy_refs == 1 &&
			state.base_refs == 1 &&
			state.precopy_dests == 1 &&
			state.inf_dests == 1 &&
			state.precopy_header &&
			state.precopy_lines == 1 &&
			state.install_header &&
			state.install_lines == 1 &&
			state.inf_header &&
			state.inf_lines == 1
		if present && !complete {return false, .Owned_Content_Collision}
		any_present = any_present || present
		all_present = all_present && complete
	}
	if any_present && !all_present {return false, .Owned_Content_Collision}
	return all_present, .None
}

@(private)
driver_custom_append_section_lines :: proc(
	text, section: string,
	lines: []string,
) -> (
	string,
	bool,
) {
	active, suffix := driver_custom_active_and_suffix(text)
	line_ending := driver_inf_detect_line_ending(active)
	needed := make([]bool, len(lines), context.temp_allocator)
	for &value in needed {value = true}
	scan_in_section := false
	scan_cursor := 0
	for {
		line, _, scan_ok := driver_inf_next_line(active, &scan_cursor)
		if !scan_ok {break}
		if name, is_section := driver_inf_section_name(line); is_section {
			scan_in_section = ascii_equal_fold(name, section)
			continue
		}
		if !scan_in_section {continue}
		meaningful := driver_custom_meaningful_line(line)
		if meaningful == "" {continue}
		for expected, index in lines {
			if ascii_equal_fold(meaningful, expected) {
				if !needed[index] {return "", false}
				needed[index] = false
			} else if driver_custom_keys_equal(meaningful, expected) {
				return "", false
			}
		}
	}
	missing := make([dynamic]string, context.temp_allocator)
	for expected, index in lines {
		if needed[index] {append(&missing, expected)}
	}
	b := strings.builder_make(0, len(text) + len(lines) * 80 + 32)
	found := false
	in_section := false
	cursor := 0
	for {
		line, ending, ok := driver_inf_next_line(active, &cursor)
		if !ok {break}
		if name, is_section := driver_inf_section_name(line); is_section {
			if in_section {driver_custom_write_lines(&b, missing[:], line_ending)}
			in_section = ascii_equal_fold(name, section)
			found = found || in_section
		}
		strings.write_string(&b, line)
		strings.write_string(&b, ending)
	}
	if in_section && len(missing) > 0 {
		driver_custom_ensure_line_ending(&b, active, line_ending)
		driver_custom_write_lines(&b, missing[:], line_ending)
	}
	if !found {
		driver_custom_ensure_line_ending(&b, active, line_ending)
		strings.write_string(&b, "[")
		strings.write_string(&b, section)
		strings.write_string(&b, "]")
		strings.write_string(&b, line_ending)
		driver_custom_write_lines(&b, missing[:], line_ending)
	}
	strings.write_string(&b, suffix)
	return strings.to_string(b), true
}

@(private)
driver_custom_keys_equal :: proc(left, right: string) -> bool {
	left_equals := strings.index_byte(left, '=')
	right_equals := strings.index_byte(right, '=')
	if left_equals <= 0 || right_equals <= 0 {return false}
	left_key := ascii_trim(left[:left_equals])
	right_key := ascii_trim(right[:right_equals])
	if ascii_equal_fold(right_key, "CopyFiles") {return false}
	return ascii_equal_fold(left_key, right_key)
}

@(private)
driver_custom_append_owned_sections :: proc(
	text: string,
	entries: []Driver_Custom_INF_Entry,
) -> (
	string,
	bool,
) {
	active, suffix := driver_custom_active_and_suffix(text)
	line_ending := driver_inf_detect_line_ending(active)
	b := strings.builder_make(0, len(text) + len(entries) * 320)
	strings.write_string(&b, active)
	driver_custom_ensure_line_ending(&b, active, line_ending)
	strings.write_string(&b, line_ending)
	for entry, index in entries {
		driver_custom_write_section(&b, entry.precopy_section, entry.inf_name, line_ending)
		strings.write_string(&b, line_ending)
		driver_custom_write_section(&b, entry.install_section, entry.install_copy, line_ending)
		strings.write_string(&b, line_ending)
		driver_custom_write_section(&b, entry.inf_section, entry.inf_name, line_ending)
		if index + 1 < len(entries) {strings.write_string(&b, line_ending)}
	}
	strings.write_string(&b, suffix)
	return strings.to_string(b), true
}

@(private)
driver_custom_write_section :: proc(b: ^strings.Builder, section, line, line_ending: string) {
	strings.write_string(b, "[")
	strings.write_string(b, section)
	strings.write_string(b, "]")
	strings.write_string(b, line_ending)
	strings.write_string(b, line)
	strings.write_string(b, line_ending)
}

@(private)
driver_custom_write_lines :: proc(b: ^strings.Builder, lines: []string, line_ending: string) {
	for line in lines {
		strings.write_string(b, line)
		strings.write_string(b, line_ending)
	}
}

@(private)
driver_custom_ensure_line_ending :: proc(b: ^strings.Builder, active, line_ending: string) {
	if len(active) > 0 && !driver_inf_ends_with_line_ending(active) {
		strings.write_string(b, line_ending)
	}
}

@(private)
driver_custom_active_and_suffix :: proc(text: string) -> (string, string) {
	for byte, index in text {
		if byte == '\x1a' {return text[:index], text[index:]}
	}
	return text, ""
}

@(private)
driver_custom_meaningful_line :: proc(line: string) -> string {
	active := line
	if semicolon := strings.index_byte(active, ';'); semicolon >= 0 {
		active = active[:semicolon]
	}
	return ascii_trim(active)
}

@(private)
driver_ascii_contains_fold :: proc(haystack, needle: string) -> bool {
	if len(needle) == 0 {return true}
	if len(needle) > len(haystack) {return false}
	for start in 0 ..= len(haystack) - len(needle) {
		if ascii_equal_fold(haystack[start:start + len(needle)], needle) {return true}
	}
	return false
}
