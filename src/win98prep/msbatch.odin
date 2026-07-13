// SPDX-License-Identifier: GPL-3.0-only
package win98prep

import "core:os"
import "core:strings"

Msbatch_Setting :: struct {
	section:     string,
	key:         string,
	value:       string,
	add_section: bool,
}

normalize_msbatch_file :: proc(path: string) -> bool {
	template, read_error := os.read_entire_file(path, context.allocator)
	if read_error != nil {return false}
	defer delete(template)

	normalized, ok := normalize_msbatch(string(template))
	if !ok {return false}
	defer delete(normalized)
	return os.write_entire_file(path, normalized) == nil
}

normalize_msbatch :: proc(template: string) -> (string, bool) {
	settings := [?]Msbatch_Setting {
		{section = "Setup", key = "OptionalComponents", value = "0"},
		{section = "Setup", key = "NoPrompt2Boot", value = "0"},
		{section = "Setup", key = "PenWinWarning", value = "0"},
		{section = "NameAndOrg", key = "Name", value = `"RETVRN99 User"`, add_section = true},
		{section = "NameAndOrg", key = "Org", value = `"RETVRN99"`, add_section = true},
		{section = "Network", key = "ComputerName", value = `"RETVRN99"`, add_section = true},
		{section = "Network", key = "Workgroup", value = `"WORKGROUP"`, add_section = true},
		{section = "Network", key = "Description", value = `"RETVRN99"`, add_section = true},
		{section = "Network", key = "ValidateNetCardResources", value = "0", add_section = true},
	}
	current := strings.clone(template)
	for setting in settings {
		next, ok := msbatch_set_value(current, setting)
		delete(current)
		if !ok {return "", false}
		current = next
	}
	return current, true
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
		for cursor < len(active_template) && active_template[cursor] != '\r' && active_template[cursor] != '\n' {
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
			msbatch_write_value(&b, setting)
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
