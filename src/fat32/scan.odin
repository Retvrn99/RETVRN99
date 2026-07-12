// SPDX-License-Identifier: GPL-3.0-only
package fat32

import "base:runtime"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import "core:unicode"
import "core:unicode/utf8"

Node :: struct {
	name:          string, // host name (UTF-8)
	is_dir:        bool,
	size:          u64,
	host_path:     string, // absolute
	children:      [dynamic]^Node, // dirs only
	// allocation (filled by alloc)
	first_cluster: u32,
	cluster_len:   u32, // contiguous cluster count
	parent:        ^Node,
	mtime:         time.Time,
	short:         [11]u8, // 8.3 name, filled once the dir is guest-managed
}

scan_tree :: proc(root_path: string, allocator := context.allocator) -> ^Node {
	abs_path, err := os.get_absolute_path(root_path, allocator)
	if err != nil {
		return nil
	}
	info, serr := os.stat(abs_path, allocator)
	if serr != nil || info.type != .Directory {
		delete(abs_path, allocator)
		os.file_info_delete(info, allocator)
		return nil
	}
	mtime := info.modification_time
	os.file_info_delete(info, allocator)
	root := new(Node, allocator)
	root.is_dir = true
	root.host_path = abs_path
	root.mtime = mtime
	root.children = make([dynamic]^Node, allocator)
	scan_children(root, allocator)
	return root
}

@(private = "file")
scan_children :: proc(dir: ^Node, allocator: runtime.Allocator) {
	infos, err := os.read_all_directory_by_path(dir.host_path, allocator)
	if err != nil {
		return
	}
	defer os.file_info_slice_delete(infos, allocator)
	slice.sort_by(infos, name_less)
	for info in infos {
		if info.type != .Regular && info.type != .Directory {
			continue
		}
		child := new(Node, allocator)
		child.name = strings.clone(info.name, allocator)
		child.host_path = strings.clone(info.fullpath, allocator)
		child.is_dir = info.type == .Directory
		child.size = u64(info.size)
		child.mtime = info.modification_time
		child.parent = dir
		child.children = make([dynamic]^Node, allocator)
		append(&dir.children, child)
		if child.is_dir {
			scan_children(child, allocator)
		}
	}
}

node_tree_destroy :: proc(node: ^Node, allocator := context.allocator) {
	if node == nil {
		return
	}
	for child in node.children {
		node_tree_destroy(child, allocator)
	}
	delete(node.children)
	delete(node.name, allocator)
	delete(node.host_path, allocator)
	free(node, allocator)
}

// case-insensitive order for determinism across hosts
@(private = "file")
name_less :: proc(a, b: os.File_Info) -> bool {
	sa, sb := a.name, b.name
	for {
		if len(sb) == 0 {
			return false
		}
		if len(sa) == 0 {
			return true
		}
		ra, na := utf8.decode_rune_in_string(sa)
		rb, nb := utf8.decode_rune_in_string(sb)
		la, lb := unicode.to_lower(ra), unicode.to_lower(rb)
		if la != lb {
			return la < lb
		}
		sa, sb = sa[na:], sb[nb:]
	}
}
