// SPDX-License-Identifier: GPL-3.0-only
package win98media

import "base:runtime"
import "core:os"
import "core:strings"

ISO_BLOCK_SIZE       :: 2048
MAX_DIRECTORY_BYTES :: 16 * 1024 * 1024
MAX_TREE_DEPTH       :: 32
MAX_TREE_ENTRIES     :: 100_000

Iso_Record :: struct {
	extent: u32,
	size:   u32,
	is_dir: bool,
}

Iso_Entry :: struct {
	name:   string,
	record: Iso_Record,
}

Iso_Image :: struct {
	file:              ^os.File,
	block_size:        u32,
	volume_blocks:     u32,
	file_bytes:        u64,
	root:              Iso_Record,
	volume_identifier: [32]u8,
	volume_id_len:     int,
}

iso_image_close :: proc(image: ^Iso_Image) {
	if image.file != nil {
		_ = os.close(image.file)
	}
	image^ = {}
}

iso_u16_le :: proc(data: []u8) -> u16 {
	return u16(data[0]) | u16(data[1]) << 8
}

iso_u16_be :: proc(data: []u8) -> u16 {
	return u16(data[0]) << 8 | u16(data[1])
}

iso_u32_le :: proc(data: []u8) -> u32 {
	return u32(data[0]) | u32(data[1]) << 8 | u32(data[2]) << 16 | u32(data[3]) << 24
}

iso_u32_be :: proc(data: []u8) -> u32 {
	return u32(data[0]) << 24 | u32(data[1]) << 16 | u32(data[2]) << 8 | u32(data[3])
}

iso_read_exact :: proc(file: ^os.File, data: []u8, offset: u64) -> bool {
	if offset > u64(max(i64)) {
		return false
	}
	total := 0
	for total < len(data) {
		n, err := os.read_at(file, data[total:], i64(offset) + i64(total))
		if n > 0 {
			total += n
		}
		if err != nil && total < len(data) {
			return false
		}
		if n == 0 {
			return false
		}
	}
	return true
}

iso_record_bounds_valid :: proc(image: ^Iso_Image, record: Iso_Record) -> bool {
	start := u64(record.extent) * u64(image.block_size)
	end := start + u64(record.size)
	volume_bytes := u64(image.volume_blocks) * u64(image.block_size)
	return end >= start && end <= volume_bytes && end <= image.file_bytes
}

iso_parse_record :: proc(data: []u8) -> (Iso_Record, string, bool) {
	if len(data) < 34 || int(data[0]) > len(data) || data[0] < 34 {
		return {}, "", false
	}
	record_len := int(data[0])
	name_len := int(data[32])
	if 33 + name_len > record_len || name_len == 0 {
		return {}, "", false
	}
	extent_le := iso_u32_le(data[2:6])
	extent_be := iso_u32_be(data[6:10])
	size_le := iso_u32_le(data[10:14])
	size_be := iso_u32_be(data[14:18])
	if extent_le != extent_be || size_le != size_be || data[26] != 0 || data[27] != 0 {
		return {}, "", false
	}
	if (data[25] & 0x80) != 0 {
		return {}, "", false
	}
	extent := extent_le + u32(data[1])
	if extent < extent_le {
		return {}, "", false
	}
	return Iso_Record{extent = extent, size = size_le, is_dir = (data[25] & 2) != 0}, string(data[33:33 + name_len]), true
}

iso_open :: proc(path: string) -> (Iso_Image, Diagnostic) {
	image: Iso_Image
	file, open_err := os.open(path)
	if open_err != nil {
		return {}, .Image_Open_Failed
	}
	image.file = file
	info, stat_err := os.fstat(file, context.temp_allocator)
	if stat_err != nil || info.size < ISO_BLOCK_SIZE * 18 {
		iso_image_close(&image)
		return {}, .Invalid_ISO9660
	}
	image.file_bytes = u64(info.size)

	pvd: [ISO_BLOCK_SIZE]u8
	found := false
	for sector in 16 ..< 80 {
		if !iso_read_exact(file, pvd[:], u64(sector * ISO_BLOCK_SIZE)) {
			iso_image_close(&image)
			return {}, .Image_Read_Failed
		}
		if string(pvd[1:6]) != "CD001" || pvd[6] != 1 {
			iso_image_close(&image)
			return {}, .Invalid_ISO9660
		}
		if pvd[0] == 1 {
			found = true
			break
		}
		if pvd[0] == 255 {
			break
		}
	}
	if !found {
		iso_image_close(&image)
		return {}, .Invalid_ISO9660
	}

	blocks_le := iso_u32_le(pvd[80:84])
	blocks_be := iso_u32_be(pvd[84:88])
	block_le := iso_u16_le(pvd[128:130])
	block_be := iso_u16_be(pvd[130:132])
	if blocks_le == 0 || blocks_le != blocks_be || block_le != block_be {
		iso_image_close(&image)
		return {}, .Invalid_ISO9660
	}
	if block_le != ISO_BLOCK_SIZE {
		iso_image_close(&image)
		return {}, .Unsupported_ISO9660
	}
	image.block_size = u32(block_le)
	image.volume_blocks = blocks_le
	if u64(blocks_le) * u64(block_le) > image.file_bytes {
		iso_image_close(&image)
		return {}, .Invalid_ISO9660
	}
	root, _, root_ok := iso_parse_record(pvd[156:])
	if !root_ok || !root.is_dir || !iso_record_bounds_valid(&image, root) {
		iso_image_close(&image)
		return {}, .Invalid_ISO9660
	}
	image.root = root
	copy(image.volume_identifier[:], pvd[40:72])
	image.volume_id_len = 32
	for image.volume_id_len > 0 && image.volume_identifier[image.volume_id_len - 1] == ' ' {
		image.volume_id_len -= 1
	}
	return image, .None
}

iso_component_safe :: proc(name: string) -> bool {
	if len(name) == 0 || name == "." || name == ".." || name[len(name) - 1] == '.' || name[len(name) - 1] == ' ' {
		return false
	}
	for i in 0 ..< len(name) {
		ch := name[i]
		if ch < 0x20 || ch >= 0x7F || strings.index_byte(`/\:*?"<>|`, ch) >= 0 {
			return false
		}
	}
	base_end := strings.index_byte(name, '.')
	if base_end < 0 {
		base_end = len(name)
	}
	base := name[:base_end]
	reserved := [?]string{"CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"}
	for item in reserved {
		if strings.equal_fold(base, item) {
			return false
		}
	}
	return true
}

iso_normalize_name :: proc(raw: string) -> (string, bool) {
	name := raw
	if semi := strings.index_byte(name, ';'); semi >= 0 {
		if semi == 0 || semi + 1 == len(name) {
			return "", false
		}
		for ch in name[semi + 1:] {
			if ch < '0' || ch > '9' {
				return "", false
			}
		}
		name = name[:semi]
	}
	return name, iso_component_safe(name)
}

iso_directory_read :: proc(image: ^Iso_Image, directory: Iso_Record, allocator: runtime.Allocator) -> ([]Iso_Entry, Diagnostic) {
	if !directory.is_dir || directory.size > MAX_DIRECTORY_BYTES || !iso_record_bounds_valid(image, directory) {
		return nil, .Malformed_Directory
	}
	data := make([]u8, int(directory.size), allocator)
	defer delete(data, allocator)
	if !iso_read_exact(image.file, data, u64(directory.extent) * u64(image.block_size)) {
		return nil, .Image_Read_Failed
	}
	entries := make([dynamic]Iso_Entry, allocator)
	pos := 0
	for pos < len(data) {
		if data[pos] == 0 {
			pos = ((pos / int(image.block_size)) + 1) * int(image.block_size)
			continue
		}
		record_len := int(data[pos])
		if record_len < 34 || pos + record_len > len(data) {
			iso_entries_destroy(entries[:], allocator)
			return nil, .Malformed_Directory
		}
		record, raw_name, ok := iso_parse_record(data[pos:pos + record_len])
		if !ok || !iso_record_bounds_valid(image, record) {
			iso_entries_destroy(entries[:], allocator)
			return nil, .Malformed_Directory
		}
		pos += record_len
		if len(raw_name) == 1 && (raw_name[0] == 0 || raw_name[0] == 1) {
			continue
		}
		name, safe := iso_normalize_name(raw_name)
		if !safe {
			iso_entries_destroy(entries[:], allocator)
			return nil, .Unsafe_ISO_Path
		}
		for existing in entries {
			if strings.equal_fold(existing.name, name) {
				iso_entries_destroy(entries[:], allocator)
				return nil, .Unsafe_ISO_Path
			}
		}
		append(&entries, Iso_Entry{name = strings.clone(name, allocator), record = record})
		if len(entries) > MAX_TREE_ENTRIES {
			iso_entries_destroy(entries[:], allocator)
			return nil, .Malformed_Directory
		}
	}
	return entries[:], .None
}

iso_entries_destroy :: proc(entries: []Iso_Entry, allocator: runtime.Allocator) {
	for entry in entries {
		delete(entry.name, allocator)
	}
	delete(entries, allocator)
}

iso_find :: proc(entries: []Iso_Entry, name: string) -> (^Iso_Entry, bool) {
	for &entry in entries {
		if strings.equal_fold(entry.name, name) {
			return &entry, true
		}
	}
	return nil, false
}

iso_file_contains :: proc(image: ^Iso_Image, record: Iso_Record, needle: string) -> (bool, Diagnostic) {
	if record.is_dir || !iso_record_bounds_valid(image, record) {
		return false, .Malformed_Directory
	}
	buffer: [64 * 1024]u8
	matched := 0
	offset := u64(record.extent) * u64(image.block_size)
	remaining := u64(record.size)
	for remaining > 0 {
		amount := int(min(remaining, u64(len(buffer))))
		if !iso_read_exact(image.file, buffer[:amount], offset) {
			return false, .Image_Read_Failed
		}
		for ch in buffer[:amount] {
			if ch == needle[matched] {
				matched += 1
				if matched == len(needle) {
					return true, .None
				}
			} else {
				matched = 1 if ch == needle[0] else 0
			}
		}
		offset += u64(amount)
		remaining -= u64(amount)
	}
	return false, .None
}
