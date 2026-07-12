// SPDX-License-Identifier: GPL-3.0-only
package fat32

import "core:os"
import "core:slice"
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

scan_tree :: proc(root_path: string) -> ^Node {
	abs_path, err := os.get_absolute_path(root_path, context.allocator)
	if err != nil {
		return nil
	}
	info, serr := os.stat(abs_path, context.allocator)
	if serr != nil || info.type != .Directory {
		return nil
	}
	root := new(Node)
	root.is_dir = true
	root.host_path = abs_path
	root.mtime = info.modification_time
	scan_children(root)
	return root
}

@(private = "file")
scan_children :: proc(dir: ^Node) {
	infos, err := os.read_all_directory_by_path(dir.host_path, context.allocator)
	if err != nil {
		return
	}
	slice.sort_by(infos, name_less)
	for info in infos {
		if info.type != .Regular && info.type != .Directory {
			continue
		}
		child := new(Node)
		child.name = info.name
		child.host_path = info.fullpath
		child.is_dir = info.type == .Directory
		child.size = u64(info.size)
		child.mtime = info.modification_time
		child.parent = dir
		append(&dir.children, child)
		if child.is_dir {
			scan_children(child)
		}
	}
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
