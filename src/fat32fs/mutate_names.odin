// SPDX-License-Identifier: GPL-3.0-only
package fat32fs

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

validate_name :: proc(name: string) -> Error {
	if name == "" ||
	   name == "." ||
	   name == ".." ||
	   len(name) > MAX_PATH_BYTES ||
	   !utf8.valid_string(name) {
		return error_make(.Invalid_Path, "FAT name is empty, reserved, or invalid UTF-8")
	}
	last := name[len(name) - 1]
	if last == '.' || last == ' ' {
		return error_make(.Invalid_Path, "FAT name cannot end with a dot or space")
	}
	units := 0
	for value in name {
		if value < 32 ||
		   value == '"' ||
		   value == '*' ||
		   value == '/' ||
		   value == ':' ||
		   value == '<' ||
		   value == '>' ||
		   value == '?' ||
		   value == '\\' ||
		   value == '|' {
			return error_make(.Invalid_Path, "FAT name contains a forbidden character")
		}
		units += value > 0xFFFF ? 2 : 1
		if units > MAX_LFN_UNITS {
			return error_make(.Invalid_Path, "FAT long name exceeds 255 UTF-16 code units")
		}
	}
	base := name
	if dot := strings.index_byte(base, '.'); dot >= 0 {base = base[:dot]}
	upper := strings.to_upper(base, context.temp_allocator)
	defer delete(upper, context.temp_allocator)
	if upper == "CON" ||
	   upper == "PRN" ||
	   upper == "AUX" ||
	   upper == "NUL" ||
	   len(upper) == 4 &&
		   (strings.has_prefix(upper, "COM") || strings.has_prefix(upper, "LPT")) &&
		   upper[3] >= '1' &&
		   upper[3] <= '9' {
		return error_make(.Invalid_Path, "FAT name uses a reserved DOS device name")
	}
	return {}
}

@(private = "package")
split_parent :: proc(
	path: string,
	allocator := context.allocator,
) -> (
	parent, name: string,
	err: Error,
) {
	components, path_error := path_components(path, allocator)
	if path_error.code != .None {return "", "", path_error}
	defer delete(components, allocator)
	if len(components) ==
	   0 {return "", "", error_make(.Invalid_Path, "the FAT root cannot be changed")}
	name = strings.clone(components[len(components) - 1], allocator)
	if len(components) == 1 {
		err = validate_name(name)
		if err.code != .None {
			delete(name, allocator)
			return "", "", err
		}
		return "", name, {}
	}
	parent = strings.join(components[:len(components) - 1], "/", allocator)
	err = validate_name(name)
	if err.code != .None {
		delete(parent, allocator)
		delete(name, allocator)
		return "", "", err
	}
	return
}

@(private = "package")
short_character_ok :: proc(value: u8) -> bool {
	switch value {
	case 'A' ..= 'Z', '0' ..= '9':
		return true
	case '!', '#', '$', '%', '&', '\'', '(', ')', '-', '@', '^', '_', '`', '{', '}', '~':
		return true
	}
	return false
}

@(private = "package")
uppercase_short_character :: proc(value: rune) -> u8 {
	upper := value
	if upper >= 'a' && upper <= 'z' {upper -= 32}
	if upper < 128 && short_character_ok(u8(upper)) {return u8(upper)}
	return '_'
}

@(private = "package")
pack_direct_short_name :: proc(name: string) -> (result: [11]u8, direct, usable: bool) {
	for index in 0 ..< 11 {result[index] = ' '}
	base, extension := name, ""
	if dot := strings.last_index_byte(name, '.'); dot >= 0 {
		if strings.index_byte(name[:dot], '.') >= 0 {return {}, false, false}
		base, extension = name[:dot], name[dot + 1:]
	}
	if len(base) < 1 || len(base) > 8 || len(extension) > 3 {return {}, false, false}
	direct = true
	for value, index in base {
		if value >= 128 {return {}, false, false}
		upper := uppercase_short_character(value)
		if upper == '_' && value != '_' {return {}, false, false}
		if value >= 'a' && value <= 'z' {direct = false}
		if !short_character_ok(upper) {
			return {}, false, false
		}
		result[index] = upper
	}
	for value, index in extension {
		if value >= 128 {return {}, false, false}
		upper := uppercase_short_character(value)
		if upper == '_' && value != '_' {return {}, false, false}
		if value >= 'a' && value <= 'z' {direct = false}
		if !short_character_ok(upper) {
			return {}, false, false
		}
		result[8 + index] = upper
	}
	return result, direct, true
}

@(private = "package")
generated_short_name :: proc(name: string) -> [11]u8 {
	result: [11]u8
	for index in 0 ..< 11 {result[index] = ' '}
	base, extension := name, ""
	if dot := strings.last_index_byte(name, '.'); dot >= 0 {
		base, extension = name[:dot], name[dot + 1:]
	}
	written := 0
	for value in base {
		if written >= 6 {break}
		result[written] = uppercase_short_character(value)
		written += 1
	}
	if written == 0 {result[0] = '_'; written = 1}
	result[written] = '~'
	result[written + 1] = '1'
	written = 0
	for value in extension {
		if written >= 3 {break}
		result[8 + written] = uppercase_short_character(value)
		written += 1
	}
	return result
}

@(private = "package")
utf16_name_units :: proc(name: string, allocator := context.allocator) -> []u16 {
	result := make([dynamic]u16, 0, min(len(name), MAX_LFN_UNITS), allocator)
	for value in name {
		if value > 0xFFFF {
			pair := u32(value) - 0x10000
			append(&result, u16(0xD800 + (pair >> 10)), u16(0xDC00 + (pair & 0x3FF)))
		} else {
			append(&result, u16(value))
		}
	}
	return result[:]
}

@(private = "package")
directory_name_available :: proc(
	volume: ^Volume,
	directory_cluster: u32,
	name: string,
	short: [11]u8,
) -> Error {
	state := Name_Availability_State {
		name  = name,
		short = short,
	}
	scan_error := scan_directory(
		volume,
		directory_cluster,
		proc(raw: ^Raw_Entry, _: u64, ctx: rawptr) -> bool {
			check := (^Name_Availability_State)(ctx)
			if entry_name_matches(raw, check.name) || raw.short == check.short {
				check.collision = true
				return false
			}
			return true
		},
		&state,
	)
	if scan_error.code != .None {return scan_error}
	if state.collision {
		return error_make(
			.Name_Collision,
			fmt.tprintf("FAT name or 8.3 alias collides with an existing entry: %s", name),
		)
	}
	return {}
}

@(private = "file")
Name_Availability_State :: struct {
	name:      string,
	short:     [11]u8,
	collision: bool,
}

name_collision_path :: proc(
	volume: ^Volume,
	path: string,
	allocator := context.allocator,
) -> (
	string,
	bool,
	Error,
) {
	if volume == nil {return "", false, error_make(.Invalid_Argument, "FAT volume is unavailable")}
	parent, name, path_error := split_parent(path, allocator)
	if path_error.code != .None {return "", false, path_error}
	defer delete(parent, allocator)
	defer delete(name, allocator)
	parent_cluster, parent_error := resolve_directory_cluster(volume, parent)
	if parent_error.code != .None {return "", false, parent_error}
	short, _, usable_short := pack_direct_short_name(name)
	if !usable_short {short = generated_short_name(name)}
	state := Name_Collision_State {
		name      = name,
		short     = short,
		allocator = allocator,
	}
	scan_error := scan_directory(
		volume,
		parent_cluster,
		proc(raw: ^Raw_Entry, _: u64, ctx: rawptr) -> bool {
			collision := (^Name_Collision_State)(ctx)
			if !entry_name_matches(raw, collision.name) && raw.short != collision.short {
				return true
			}
			if len(raw.lfn) > 0 {
				collision.actual = strings.clone(raw.lfn, collision.allocator)
			} else {
				collision.actual = short_name(raw.short, collision.allocator)
			}
			return false
		},
		&state,
	)
	if scan_error.code != .None {
		delete(state.actual, allocator)
		return "", false, scan_error
	}
	if state.actual == "" {return "", false, {}}
	if parent == "" {return state.actual, true, {}}
	result := strings.concatenate({parent, "/", state.actual}, allocator)
	delete(state.actual, allocator)
	return result, true, {}
}

@(private = "file")
Name_Collision_State :: struct {
	name:      string,
	short:     [11]u8,
	actual:    string,
	allocator: runtime.Allocator,
}
