// SPDX-License-Identifier: GPL-3.0-only
package fat32

import "core:os"
import "core:path/filepath"
import "core:strings"

Mirror_Key :: struct {
	parent_cluster: u32,
	short:          [11]u8,
}

Mirror_Entry :: struct {
	host_path:          string,
	first_cluster:      u32,
	size:               u32,
	is_dir:             bool,
	chain_identity:     u64,
	has_chain_identity: bool,
	fingerprint:        u64,
	has_fingerprint:    bool,
	base_node:          ^Node,
	guest_deleted:      bool,
}

Guest_Entry :: struct {
	key:               Mirror_Key,
	name:              string,
	host_path:         string,
	first_cluster:     u32,
	size:              u32,
	is_dir:            bool,
	valid:             bool,
	directory_touched: bool,
	data_touched:      bool,
	chain:             []u32,
	chain_complete:    bool,
}

Guest_Dir_Work :: struct {
	cluster: u32,
	path:    string,
}

Guest_Scan :: struct {
	entries:         [dynamic]Guest_Entry,
	scanned_dirs:    map[u32]bool,
	error:           Guest_Scan_Error,
	error_parent:    string,
	error_component: string,
}

Guest_Scan_Error :: enum {
	None,
	Root_Path,
	Invalid_Component,
	Escaping_Path,
	Reparse_Path,
}

guest_scan_init :: proc(allocator := context.allocator) -> Guest_Scan {
	return Guest_Scan {
		entries = make([dynamic]Guest_Entry, allocator),
		scanned_dirs = make(map[u32]bool, allocator),
	}
}

guest_scan_tree :: proc(v: ^Volume, allocator := context.allocator) -> Guest_Scan {
	scan := guest_scan_init(allocator)
	work := make([dynamic]Guest_Dir_Work, allocator)
	visited := make(map[u32]bool, allocator)
	root, root_error := filepath.abs(v.root_dir, allocator)
	if root_error != nil {
		scan.error = .Root_Path
		return scan
	}
	if !guest_path_reparse_safe(root, root, allocator) {
		scan.error = .Reparse_Path
		return scan
	}
	append(&work, Guest_Dir_Work{2, root})

	for len(work) > 0 {
		item := work[len(work) - 1]
		ordered_remove(&work, len(work) - 1)
		if visited[item.cluster] {
			continue
		}
		visited[item.cluster] = true

		chain, state := volume_chain_inspect(v, item.cluster, allocator)
		if state != .Complete {
			continue
		}
		bytes, ok := guest_read_chain(v, chain[:], allocator)
		if !ok {
			continue
		}
		unsafe_component, short_entries_safe := guest_directory_short_entries_safe(
			bytes,
			allocator,
		)
		if !short_entries_safe {
			scan.error = .Invalid_Component
			scan.error_parent = strings.clone(item.path, allocator)
			scan.error_component = unsafe_component
			return scan
		}
		scan.scanned_dirs[item.cluster] = true
		dir_touched := guest_chain_touched(v, chain[:])

		lfn: Lfn_State
		parsed := make([dynamic]Dir_Entry, allocator)
		for offset := 0; offset < len(bytes); offset += SECTOR {
			sector_entries := parse_dir_sector(bytes[offset:][:SECTOR], &lfn, allocator)
			append(&parsed, ..sector_entries[:])
		}
		for &parsed_entry in parsed {
			name, name_ok := guest_entry_name(&parsed_entry, allocator)
			if !name_ok {
				scan.error = .Invalid_Component
				scan.error_parent = strings.clone(item.path, allocator)
				if parsed_entry.lfn != "" {
					scan.error_component = strings.clone(parsed_entry.lfn, allocator)
				} else {
					scan.error_component = short_to_name(parsed_entry.short, allocator)
				}
				return scan
			}
			path, path_error := guest_safe_child_path(root, item.path, name, allocator)
			if path_error != .None {
				scan.error = path_error
				return scan
			}
			is_dir := parsed_entry.attr & ATTR_DIR != 0
			valid, data_touched, entry_chain, chain_complete := guest_entry_chain_state(
				v,
				parsed_entry.cluster,
				parsed_entry.size,
				is_dir,
				allocator,
			)
			entry := Guest_Entry {
				key               = Mirror_Key{item.cluster, parsed_entry.short},
				name              = name,
				host_path         = path,
				first_cluster     = parsed_entry.cluster,
				size              = parsed_entry.size,
				is_dir            = is_dir,
				valid             = valid,
				directory_touched = dir_touched,
				data_touched      = data_touched,
				chain             = entry_chain,
				chain_complete    = chain_complete,
			}
			append(&scan.entries, entry)
			if is_dir && valid && parsed_entry.cluster >= 2 {
				append(&work, Guest_Dir_Work{parsed_entry.cluster, path})
			}
		}
	}
	return scan
}

@(private = "file")
guest_entry_chain_state :: proc(
	v: ^Volume,
	first, size: u32,
	is_dir: bool,
	allocator := context.allocator,
) -> (
	valid, touched: bool,
	chain: []u32,
	complete: bool,
) {
	if first < 2 {
		return !is_dir && size == 0, false, nil, false
	}
	inspected, state := volume_chain_inspect(v, first, allocator)
	if state != .Complete {
		return false, guest_chain_touched(v, inspected[:]), inspected[:], false
	}
	if !is_dir && u64(size) > u64(len(inspected)) * u64(CLUSTER_BYTES) {
		return false, guest_chain_touched(v, inspected[:]), inspected[:], true
	}
	return true, guest_chain_touched(v, inspected[:]), inspected[:], true
}

@(private = "file")
guest_read_chain :: proc(
	v: ^Volume,
	chain: []u32,
	allocator := context.allocator,
) -> (
	[]u8,
	bool,
) {
	out := make([]u8, len(chain) * CLUSTER_BYTES, allocator)
	for cluster, index in chain {
		lba := u64(PART_START_LBA) + u64(cluster_to_lba(&v.alloc.geo, cluster))
		start := index * CLUSTER_BYTES
		if !volume_read(v, lba, out[start:][:CLUSTER_BYTES]) {
			delete(out, allocator)
			return nil, false
		}
	}
	return out, true
}

guest_chain_touched :: proc(v: ^Volume, chain: []u32) -> bool {
	for cluster in chain {
		first := v.alloc.geo.data_start + (cluster - 2) * SECTORS_PER_CLUSTER
		for sector in u32(0) ..< SECTORS_PER_CLUSTER {
			if overlay_dirty_has(v, first + sector) {
				return true
			}
		}
	}
	return false
}

@(private = "file")
guest_entry_name :: proc(entry: ^Dir_Entry, allocator := context.allocator) -> (string, bool) {
	short_name := short_to_name(entry.short, allocator)
	if !guest_component_safe(short_name) {
		delete(short_name, allocator)
		return "", false
	}
	if entry.lfn != "" {
		lfn_ok := guest_component_safe(entry.lfn)
		delete(short_name, allocator)
		return entry.lfn, lfn_ok
	}
	return short_name, true
}

@(private = "file")
guest_directory_short_entries_safe :: proc(
	bytes: []u8,
	allocator := context.allocator,
) -> (
	string,
	bool,
) {
	for offset := 0; offset + 32 <= len(bytes); offset += 32 {
		raw := bytes[offset:][:32]
		if raw[0] == 0 {
			return "", true
		}
		if raw[0] == 0xE5 || raw[11] & 0x3F == ATTR_LFN || raw[11] & 0x08 != 0 {
			continue
		}
		if raw[0] == '.' {
			dot := string(raw[:11]) == ".          " || string(raw[:11]) == "..         "
			if !dot || raw[11] & ATTR_DIR == 0 {
				return strings.clone(string(raw[:11]), allocator), false
			}
			continue
		}
		short: [11]u8
		copy(short[:], raw[:11])
		name := short_to_name(short, allocator)
		safe := guest_component_safe(name)
		if !safe {
			return name, false
		}
		delete(name, allocator)
	}
	return "", true
}

@(private = "file")
guest_component_safe :: proc(name: string) -> bool {
	if name == "" ||
	   name == "." ||
	   name == ".." ||
	   name[len(name) - 1] == '.' ||
	   name[len(name) - 1] == ' ' {
		return false
	}
	for byte in transmute([]u8)name {
		if byte < 0x20 {
			return false
		}
		switch byte {
		case '/', '\\', ':', '*', '?', '"', '<', '>', '|':
			return false
		}
	}
	base_end := strings.index_byte(name, '.')
	if base_end < 0 {
		base_end = len(name)
	}
	base := name[:base_end]
	reserved := [?]string {
		"CON",
		"PRN",
		"AUX",
		"NUL",
		"COM1",
		"COM2",
		"COM3",
		"COM4",
		"COM5",
		"COM6",
		"COM7",
		"COM8",
		"COM9",
		"LPT1",
		"LPT2",
		"LPT3",
		"LPT4",
		"LPT5",
		"LPT6",
		"LPT7",
		"LPT8",
		"LPT9",
	}
	for item in reserved {
		if strings.equal_fold(base, item) {
			return false
		}
	}
	return true
}

@(private = "file")
guest_safe_child_path :: proc(
	root, parent, name: string,
	allocator := context.allocator,
) -> (
	string,
	Guest_Scan_Error,
) {
	if !guest_component_safe(name) {
		return "", .Invalid_Component
	}
	joined, join_error := filepath.join({parent, name}, allocator)
	if join_error != nil {
		return "", .Escaping_Path
	}
	canonical, clean_error := filepath.clean(joined, allocator)
	delete(joined, allocator)
	if clean_error != nil || !guest_path_descendant(root, canonical, allocator) {
		delete(canonical, allocator)
		return "", .Escaping_Path
	}
	if !guest_path_reparse_safe(root, canonical, allocator) {
		delete(canonical, allocator)
		return "", .Reparse_Path
	}
	return canonical, .None
}

@(private = "file")
guest_path_descendant :: proc(root, path: string, allocator := context.allocator) -> bool {
	relative, relative_error := filepath.rel(root, path, allocator)
	if relative_error != .None {
		return false
	}
	defer delete(relative, allocator)
	if relative == "." || relative == ".." || filepath.is_abs(relative) {
		return false
	}
	return !(len(relative) > 2 && relative[:2] == ".." && filepath.is_separator(relative[2]))
}

@(private = "file")
guest_path_reparse_safe :: proc(root, path: string, allocator := context.allocator) -> bool {
	current := path
	for {
		info, stat_error := os.stat_do_not_follow_links(current, allocator)
		if stat_error == nil {
			is_link := info.type == .Symlink
			os.file_info_delete(info, allocator)
			if is_link {
				return false
			}
		} else if stat_error != os.General_Error.Not_Exist {
			return false
		}
		if current == root || (ODIN_OS == .Windows && strings.equal_fold(current, root)) {
			return true
		}
		parent := filepath.dir(current)
		if parent == current {
			return false
		}
		current = parent
	}
}
