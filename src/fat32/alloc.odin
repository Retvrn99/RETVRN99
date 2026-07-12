// SPDX-License-Identifier: GPL-3.0-only
package fat32

import "base:runtime"
import "core:strings"

CLUSTER_BYTES :: SECTOR * SECTORS_PER_CLUSTER

Allocation :: struct {
	root:       ^Node,
	geo:        Geometry,
	by_cluster: []^Node, // cluster number -> owning node (dense)
	next_free:  u32, // first free cluster after synthesis
}

// Order: cluster 2 = root; then DFS: each dir, then its files.
allocate :: proc(root: ^Node, geo: Geometry, allocator := context.allocator) -> Allocation {
	a := Allocation {
		root = root,
		geo  = geo,
	}
	// indexed directly by cluster number; valid data clusters are 2..cluster_count+1
	a.by_cluster = make([]^Node, int(geo.cluster_count) + 2, allocator)
	a.next_free = 2
	assign(&a, root, u64(dir_size_bytes(root)))
	alloc_dir(&a, root)
	return a
}

allocation_destroy :: proc(a: ^Allocation, allocator: runtime.Allocator) {
	if a == nil {
		return
	}
	delete(a.by_cluster, allocator)
	node_tree_destroy(a.root, allocator)
	a^ = {}
}

@(private = "file")
alloc_dir :: proc(a: ^Allocation, dir: ^Node) {
	for child in dir.children {
		if child.is_dir {
			assign(a, child, u64(dir_size_bytes(child)))
			alloc_dir(a, child)
		}
	}
	for child in dir.children {
		if !child.is_dir {
			assign(a, child, child.size)
		}
	}
}

@(private = "file")
assign :: proc(a: ^Allocation, node: ^Node, nbytes: u64) {
	n := u32((nbytes + CLUSTER_BYTES - 1) / CLUSTER_BYTES)
	if n == 0 {
		node.first_cluster = 0
		node.cluster_len = 0
		return
	}
	node.first_cluster = a.next_free
	node.cluster_len = n
	for c in node.first_cluster ..< node.first_cluster + n {
		a.by_cluster[c] = node
	}
	a.next_free += n
}

// Directory byte size rounded up to a whole cluster; consumed by the
// directory synthesis (synth_dir) too:
// 32 x (2 dot entries if non-root + per child: 1 short entry + LFN entries).
dir_size_bytes :: proc(node: ^Node) -> u32 {
	entries := u32(0)
	if node.parent != nil {
		entries += 2 // . and ..
	}
	for child in node.children {
		entries += 1 + lfn_entry_count(child.name)
	}
	bytes := entries * 32
	clusters := (bytes + CLUSTER_BYTES - 1) / CLUSTER_BYTES
	if clusters == 0 {
		clusters = 1
	}
	return clusters * CLUSTER_BYTES
}

// LFN entries needed for a name; names already valid 8.3 get none
lfn_entry_count :: proc(name: string) -> u32 {
	if is_valid_83(name) {
		return 0
	}
	units := u32(0)
	for r in name {
		units += 2 if r > 0xFFFF else 1
	}
	return (units + 12) / 13
}

@(private = "file")
is_valid_83 :: proc(name: string) -> bool {
	base, ext := name, ""
	if dot := strings.last_index_byte(name, '.'); dot >= 0 {
		base, ext = name[:dot], name[dot + 1:]
	}
	if len(base) == 0 || len(base) > 8 || len(ext) > 3 {
		return false
	}
	for i in 0 ..< len(base) {
		if !valid_83_char(base[i]) {
			return false
		}
	}
	for i in 0 ..< len(ext) {
		if !valid_83_char(ext[i]) {
			return false
		}
	}
	return true
}

@(private = "file")
valid_83_char :: proc(c: byte) -> bool {
	switch c {
	case 'A' ..= 'Z', '0' ..= '9':
		return true
	case '!', '#', '$', '%', '&', '\'', '(', ')', '-', '@', '^', '_', '`', '{', '}', '~':
		return true
	}
	return false
}
