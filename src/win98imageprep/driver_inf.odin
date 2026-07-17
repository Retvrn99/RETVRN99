// SPDX-License-Identifier: GPL-3.0-only
package win98imageprep

import "core:strings"

DRIVER_DMA_VALUE_COUNT :: 4

Driver_INF_Diagnostic :: enum u8 {
	None,
	Too_Large,
	Section_Missing,
	Section_Ambiguous,
	Verification_Failed,
}

driver_inf_patch_dma_defaults :: proc(text, section: string) -> (string, Driver_INF_Diagnostic) {
	if len(text) > int(DRIVER_INF_MAX_BYTES) {return "", .Too_Large}
	active := text
	eof_suffix := ""
	for byte, index in text {
		if byte == '\x1a' {
			active = text[:index]
			eof_suffix = text[index:]
			break
		}
	}
	file_ending := driver_inf_detect_line_ending(active)
	section_ending := file_ending
	active_ended := driver_inf_ends_with_line_ending(active)
	b := strings.builder_make(0, len(text) + 160)
	written := false
	output_ended := false
	in_section := false
	section_count := 0
	cursor := 0
	for {
		line, ending, ok := driver_inf_next_line(active, &cursor)
		if !ok {break}
		name, is_section := driver_inf_section_name(line)
		if is_section {
			if in_section {
				driver_inf_write_dma_defaults(&b, section_ending, true, &written, &output_ended)
			}
			in_section = ascii_equal_fold(name, section)
			if in_section {
				section_count += 1
				if section_count > 1 {
					strings.builder_destroy(&b)
					return "", .Section_Ambiguous
				}
				if ending != "" {section_ending = ending}
			}
			strings.write_string(&b, line)
			strings.write_string(&b, ending)
			written = true
			output_ended = ending != ""
		} else if !in_section || driver_inf_dma_index(line) < 0 {
			strings.write_string(&b, line)
			strings.write_string(&b, ending)
			written = true
			output_ended = ending != ""
		}
	}
	if section_count == 0 {
		strings.builder_destroy(&b)
		return "", .Section_Missing
	}
	if in_section {
		driver_inf_write_dma_defaults(&b, section_ending, active_ended, &written, &output_ended)
	}
	strings.write_string(&b, eof_suffix)
	patched := strings.to_string(b)
	if !driver_inf_dma_defaults_valid(patched, section) {
		delete(patched)
		return "", .Verification_Failed
	}
	return patched, .None
}

driver_inf_dma_defaults_valid :: proc(text, section: string) -> bool {
	active := text
	for byte, index in text {
		if byte == '\x1a' {
			active = text[:index]
			break
		}
	}
	counts: [DRIVER_DMA_VALUE_COUNT]int
	in_section := false
	section_count := 0
	cursor := 0
	for {
		line, _, ok := driver_inf_next_line(active, &cursor)
		if !ok {break}
		name, is_section := driver_inf_section_name(line)
		if is_section {
			in_section = ascii_equal_fold(name, section)
			if in_section {section_count += 1}
			continue
		}
		if !in_section {continue}
		index := driver_inf_dma_index(line)
		if index < 0 {continue}
		compact_buffer: [512]u8
		compact, compact_ok := driver_inf_compact_line(line, &compact_buffer)
		if !compact_ok {return false}
		expected := driver_inf_dma_line(index)
		if !ascii_equal_fold(compact, expected) {return false}
		counts[index] += 1
	}
	if section_count != 1 {return false}
	for count in counts {
		if count != 1 {return false}
	}
	return true
}

@(private)
driver_inf_write_dma_defaults :: proc(
	b: ^strings.Builder,
	line_ending: string,
	trailing_ending: bool,
	written, output_ended: ^bool,
) {
	if written^ && !output_ended^ {strings.write_string(b, line_ending)}
	for index in 0 ..< DRIVER_DMA_VALUE_COUNT {
		strings.write_string(b, driver_inf_dma_line(index))
		if index + 1 < DRIVER_DMA_VALUE_COUNT || trailing_ending {
			strings.write_string(b, line_ending)
		}
	}
	written^ = true
	output_ended^ = trailing_ending
}

@(private)
driver_inf_dma_line :: proc(index: int) -> string {
	switch index {
	case 0:
		return "HKR,,IDEDMADrive0,3,01"
	case 1:
		return "HKR,,IDEDMADrive1,3,01"
	case 2:
		return "HKR,,IDEDMADrive2,3,01"
	case 3:
		return "HKR,,IDEDMADrive3,3,01"
	case:
		return ""
	}
}

@(private)
driver_inf_dma_index :: proc(line: string) -> int {
	buffer: [512]u8
	compact, ok := driver_inf_compact_line(line, &buffer)
	if !ok {return -1}
	prefix := "HKR,,IDEDMADrive"
	if len(compact) < len(prefix) + 2 ||
	   !ascii_equal_fold(compact[:len(prefix)], prefix) ||
	   compact[len(prefix) + 1] != ',' {
		return -1
	}
	digit := compact[len(prefix)]
	return digit >= '0' && digit < '0' + DRIVER_DMA_VALUE_COUNT ? int(digit - '0') : -1
}

@(private)
driver_inf_compact_line :: proc(line: string, buffer: ^[512]u8) -> (string, bool) {
	if buffer == nil {return "", false}
	active := line
	if semicolon := strings.index_byte(active, ';'); semicolon >= 0 {
		active = active[:semicolon]
	}
	count := 0
	for index in 0 ..< len(active) {
		byte := active[index]
		if byte == ' ' || byte == '\t' {continue}
		if count >= len(buffer^) {return "", false}
		buffer[count] = byte
		count += 1
	}
	return string(buffer[:count]), true
}

@(private)
driver_inf_section_name :: proc(line: string) -> (string, bool) {
	trimmed := ascii_trim(line)
	if len(trimmed) < 3 || trimmed[0] != '[' || trimmed[len(trimmed) - 1] != ']' {
		return "", false
	}
	name := ascii_trim(trimmed[1:len(trimmed) - 1])
	return name, name != ""
}

@(private)
driver_inf_next_line :: proc(text: string, cursor: ^int) -> (string, string, bool) {
	if cursor == nil || cursor^ >= len(text) {return "", "", false}
	start := cursor^
	for cursor^ < len(text) && text[cursor^] != '\r' && text[cursor^] != '\n' {
		cursor^ += 1
	}
	end := cursor^
	if cursor^ < len(text) && text[cursor^] == '\r' {cursor^ += 1}
	if cursor^ < len(text) && text[cursor^] == '\n' {cursor^ += 1}
	return text[start:end], text[end:cursor^], true
}

@(private)
driver_inf_detect_line_ending :: proc(text: string) -> string {
	cursor := 0
	for {
		_, ending, ok := driver_inf_next_line(text, &cursor)
		if !ok {break}
		if ending != "" {return ending}
	}
	return "\r\n"
}

@(private)
driver_inf_ends_with_line_ending :: proc(text: string) -> bool {
	return len(text) > 0 && (text[len(text) - 1] == '\r' || text[len(text) - 1] == '\n')
}
