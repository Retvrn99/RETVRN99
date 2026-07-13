// SPDX-License-Identifier: GPL-3.0-only
package fat32

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:unicode/utf16"

// one parsed 32-byte short entry, plus its LFN name when present
Dir_Entry :: struct {
	short:   [11]u8,
	attr:    u8,
	cluster: u32,
	size:    u32,
	lfn:     string,
}

// diff old vs new content of one directory sector and mirror the changes
// onto the host filesystem; prefix holds the earlier sectors of the same
// cluster so an LFN chain straddling a sector boundary still resolves
decode_dir_write :: proc(v: ^Volume, dir: ^Node, prefix, old_sec, new_sec: []u8) -> bool {
	ta := context.temp_allocator
	carry: Lfn_State
	parse_dir_sector(prefix, &carry, ta) // entries discarded: only the LFN carry matters
	st_old, st_new := carry, carry
	olds := parse_dir_sector(old_sec, &st_old, ta)
	news := parse_dir_sector(new_sec, &st_new, ta)

	round_deletes := make([dynamic]^Node, ta)
	for &o in olds {
		if find_entry(news[:], o.short) != nil {
			continue
		}
		node := child_by_short(dir, o.short)
		if node == nil {
			volume_fail(v, fmt.tprintf("removed entry %s has no host node", short_to_name(o.short, ta)))
			return false
		}
		append(&round_deletes, node)
	}
	for &n in news {
		o := find_entry(olds[:], n.short)
		if o == nil {
			if !apply_create(v, dir, &n, &round_deletes) {
				return false
			}
		} else {
			if !apply_change(v, dir, o, &n) {
				return false
			}
		}
	}
	// a delete whose chain the guest already freed is final; one with a
	// live chain waits: it may be the first half of a rename or move
	for node in round_deletes {
		if pending_chain_freed(v, node) {
			if !apply_delete(v, node) {
				return false
			}
		} else {
			append(&v.journal.pending_deletes, Pending_Delete{node})
		}
	}
	return true
}

// apply deferred deletes whose FAT chain the guest has freed (a true
// delete); chains still allocated stay pending: a move may be in flight
volume_flush :: proc(v: ^Volume) -> bool {
	i := 0
	for i < len(v.journal.pending_deletes) {
		pd := v.journal.pending_deletes[i]
		if pending_chain_freed(v, pd.node) {
			ordered_remove(&v.journal.pending_deletes, i)
			if !apply_delete(v, pd.node) {
				return false
			}
		} else {
			i += 1
		}
	}
	return true
}

@(private = "file")
pending_chain_freed :: proc(v: ^Volume, node: ^Node) -> bool {
	if node.first_cluster == 0 {
		return true // nothing to match a rename against
	}
	return volume_fat_entry(v, node.first_cluster) & 0x0FFFFFFF == 0
}

@(private = "file")
DECODE_LFN_OFFS :: [13]int{1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30}

// LFN accumulation that survives a sector boundary
@(private = "file")
Lfn_State :: struct {
	units: [20 * 13]u16,
	max:   int,
	csum:  u8,
}

@(private = "file")
parse_dir_sector :: proc(sec: []u8, st: ^Lfn_State, allocator := context.allocator) -> [dynamic]Dir_Entry {
	entries := make([dynamic]Dir_Entry, allocator)
	for off := 0; off + 32 <= len(sec); off += 32 {
		e := sec[off:][:32]
		if e[0] == 0 {
			st.max = 0 // directory ends here: no carry past the terminator
			break
		}
		if e[0] == 0xE5 {
			st.max = 0
			continue
		}
		if e[11] & 0x3F == ATTR_LFN {
			seq := int(e[0] & 0x1F)
			if seq >= 1 && seq <= 20 {
				if e[0] & 0x40 != 0 {
					st.max = seq
					st.csum = e[13]
				}
				offs := DECODE_LFN_OFFS
				for o, i in offs {
					st.units[(seq - 1) * 13 + i] = u16(e[o]) | u16(e[o + 1]) << 8
				}
			}
			continue
		}
		if e[11] & 0x08 != 0 || e[0] == '.' {
			st.max = 0
			continue // volume label / dot entries
		}
		de: Dir_Entry
		copy(de.short[:], e[:11])
		de.attr = e[11]
		de.cluster = u32(de_rd16(e, 20)) << 16 | u32(de_rd16(e, 26))
		de.size = de_rd32(e, 28)
		if st.max > 0 && lfn_checksum(de.short) == st.csum {
			units := st.units[:st.max * 13]
			n := 0
			for n < len(units) && units[n] != 0 && units[n] != 0xFFFF {
				n += 1
			}
			buf := make([]u8, n * 4, allocator)
			m := utf16.decode_to_utf8(buf, units[:n])
			de.lfn = string(buf[:m])
		}
		st.max = 0
		append(&entries, de)
	}
	return entries
}

@(private = "file")
find_entry :: proc(entries: []Dir_Entry, short: [11]u8) -> ^Dir_Entry {
	for &e in entries {
		if e.short == short {
			return &e
		}
	}
	return nil
}

@(private = "file")
child_by_short :: proc(dir: ^Node, short: [11]u8) -> ^Node {
	for child in dir.children {
		if child.short == short {
			return child
		}
	}
	return nil
}

@(private = "file")
short_to_name :: proc(short: [11]u8, allocator := context.allocator) -> string {
	s := short
	base := strings.trim_right(string(s[0:8]), " ")
	ext := strings.trim_right(string(s[8:11]), " ")
	if ext == "" {
		return strings.clone(base, allocator)
	}
	return strings.concatenate({base, ".", ext}, allocator)
}

// a create whose first cluster matches a deferred delete is a rename
@(private = "file")
take_deleted_by_cluster :: proc(v: ^Volume, round: ^[dynamic]^Node, cluster: u32) -> ^Node {
	if cluster == 0 {
		return nil
	}
	for pd, i in v.journal.pending_deletes {
		if pd.node.first_cluster == cluster {
			node := pd.node
			ordered_remove(&v.journal.pending_deletes, i)
			return node
		}
	}
	for n, i in round^ {
		if n.first_cluster == cluster {
			ordered_remove(round, i)
			return n
		}
	}
	return nil
}

// adopt a guest FAT chain for node; dir clusters written before they
// joined the chain are promoted from orphan_data AND decoded, so entries
// in a grown directory cluster reach the host
@(private)
claim_chain :: proc(v: ^Volume, node: ^Node, first: u32) -> bool {
	if first == 0 {
		return true
	}
	chain, state := volume_chain_inspect(v, first, context.temp_allocator)
	if state != .Complete {
		if node.is_dir && state == .Incomplete {
			for pending in v.journal.pending_extends {
				if pending == node {return true}
			}
			append(&v.journal.pending_extends, node)
			return true
		}
		volume_fail(v, fmt.tprintf("bad FAT chain at cluster %d for %s", first, node.name))
		return false
	}
	geo := &v.alloc.geo
	node.cluster_len = u32(len(chain))
	for c, idx in chain {
		v.journal.claimed[c] = Claim{node, u32(idx)}
		if node.is_dir {
			if ob, ok := v.journal.orphan_data[c]; ok {
				delete_key(&v.journal.orphan_data, c)
				rel0 := geo.data_start + (c - 2) * SECTORS_PER_CLUSTER
				for s in u32(0) ..< SECTORS_PER_CLUSTER {
					if !write_dir_sector(v, node, rel0 + s, ob[int(s) * SECTOR:][:SECTOR]) {
						delete(ob, v.allocator)
						return false
					}
				}
				delete(ob, v.allocator)
			}
		}
	}
	return true
}

@(private = "file")
detach_child :: proc(node: ^Node) {
	if node.parent == nil {
		return
	}
	for child, i in node.parent.children {
		if child == node {
			ordered_remove(&node.parent.children, i)
			return
		}
	}
}

@(private = "file")
rebase_paths :: proc(v: ^Volume, node: ^Node) {
	for child in node.children {
		p, _ := filepath.join({node.host_path, child.name}, v.allocator)
		delete(child.host_path, v.allocator)
		child.host_path = p
		if child.is_dir {
			rebase_paths(v, child)
		}
	}
}

@(private = "file")
decode_new_node :: proc(v: ^Volume, dir: ^Node, name, path: string, e: ^Dir_Entry, is_dir: bool) -> ^Node {
	node := new(Node, v.allocator)
	node.name = strings.clone(name, v.allocator)
	node.host_path = strings.clone(path, v.allocator)
	node.is_dir = is_dir
	node.size = is_dir ? 0 : u64(e.size)
	node.first_cluster = e.cluster
	node.parent = dir
	node.short = e.short
	node.children = make([dynamic]^Node, v.allocator)
	append(&dir.children, node)
	return node
}

@(private = "file")
apply_create :: proc(v: ^Volume, dir: ^Node, e: ^Dir_Entry, round_deletes: ^[dynamic]^Node) -> bool {
	ta := context.temp_allocator
	name := e.lfn != "" ? e.lfn : short_to_name(e.short, ta)
	path, _ := filepath.join({dir.host_path, name}, ta)
	if node := take_deleted_by_cluster(v, round_deletes, e.cluster); node != nil {
		if rerr := os.rename(node.host_path, path); rerr != nil {
			volume_fail(v, fmt.tprintf("rename %s -> %s failed", node.host_path, path))
			return false
		}
		detach_child(node)
		node.parent = dir
		append(&dir.children, node)
		delete(node.name, v.allocator)
		delete(node.host_path, v.allocator)
		node.name = strings.clone(name, v.allocator)
		node.host_path = strings.clone(path, v.allocator)
		node.short = e.short
		if node.is_dir {
			rebase_paths(v, node)
			return true
		}
		if u64(e.size) != node.size {
			return apply_resize(v, node, e.size)
		}
		return true
	}
	if e.attr & ATTR_DIR != 0 {
		if merr := os.make_directory(path); merr != nil {
			volume_fail(v, fmt.tprintf("mkdir %s failed", path))
			return false
		}
		node := decode_new_node(v, dir, name, path, e, true)
		return claim_chain(v, node, e.cluster)
	}
	// new file: content comes from guest-written orphan clusters
	data := make([]u8, int(e.size), ta)
	node := decode_new_node(v, dir, name, path, e, false)
	if e.cluster != 0 {
		if !claim_chain(v, node, e.cluster) {
			return false
		}
		chain := volume_chain(v, e.cluster, ta)
		for c, idx in chain {
			ob, ok := v.journal.orphan_data[c]
			if !ok {
				continue
			}
			base := idx * CLUSTER_BYTES
			if base < int(e.size) {
				copy(data[base:], ob[:min(CLUSTER_BYTES, int(e.size) - base)])
			}
			// buffer fully covered by the host file now: release it
			if base + CLUSTER_BYTES <= int(e.size) {
				delete_key(&v.journal.orphan_data, c)
				delete(ob, v.allocator)
			}
		}
	}
	if werr := os.write_entire_file(path, data); werr != nil {
		volume_fail(v, fmt.tprintf("cannot create %s", path))
		return false
	}
	return true
}

@(private = "file")
apply_change :: proc(v: ^Volume, dir: ^Node, o, n: ^Dir_Entry) -> bool {
	if (o.attr ~ n.attr) & ATTR_DIR != 0 {
		volume_fail(v, fmt.tprintf("entry %s changed kind", short_to_name(n.short, context.temp_allocator)))
		return false
	}
	node := child_by_short(dir, n.short)
	if node == nil {
		volume_fail(v, fmt.tprintf("changed entry %s has no host node", short_to_name(n.short, context.temp_allocator)))
		return false
	}
	if o.cluster != n.cluster {
		if o.cluster != 0 && n.cluster != 0 {
			volume_fail(v, fmt.tprintf("first cluster of %s moved %d -> %d (defrag unsupported)", node.name, o.cluster, n.cluster))
			return false
		}
		if n.cluster == 0 { // truncate-to-zero: the standard DOS overwrite path
			if node.is_dir {
				volume_fail(v, fmt.tprintf("directory %s truncated to zero", node.name))
				return false
			}
			release_node_clusters(v, node)
			node.first_cluster = 0
			node.cluster_len = 0
		} else {
			node.first_cluster = n.cluster
			if !claim_chain(v, node, n.cluster) {
				return false
			}
		}
	}
	if !node.is_dir && u64(n.size) != node.size {
		return apply_resize(v, node, n.size)
	}
	return true
}

// truncate/extend the host file; grown range is filled from orphan
// clusters the guest already wrote (zeros elsewhere)
@(private = "file")
apply_resize :: proc(v: ^Volume, node: ^Node, new_size: u32) -> bool {
	old := i64(node.size)
	ns := i64(new_size)
	if ns == old {
		return true
	}
	f, oerr := os.open(node.host_path, {.Write})
	if oerr != nil {
		volume_fail(v, fmt.tprintf("cannot open %s for resize", node.host_path))
		return false
	}
	terr := os.truncate(f, ns)
	os.close(f)
	if terr != nil {
		volume_fail(v, fmt.tprintf("resize of %s failed", node.host_path))
		return false
	}
	node.size = u64(new_size)
	if ns < old || node.first_cluster == 0 {
		return true
	}
	chain := volume_chain(v, node.first_cluster, context.temp_allocator)
	for c, idx in chain {
		v.journal.claimed[c] = Claim{node, u32(idx)}
		base := i64(idx) * CLUSTER_BYTES
		ob, ok := v.journal.orphan_data[c]
		if !ok {
			continue // truncate already zero-filled the gap
		}
		lo := max(base, old)
		hi := min(base + CLUSTER_BYTES, ns)
		if lo < hi {
			if !host_write_at(v, node, ob[lo - base:hi - base], lo) {
				return false
			}
		}
		// buffer fully covered by the host file now: release it
		if base + CLUSTER_BYTES <= ns {
			delete_key(&v.journal.orphan_data, c)
			delete(ob, v.allocator)
		}
	}
	return true
}

// forget every cluster the node owned (the guest freed its chain)
@(private = "file")
release_node_clusters :: proc(v: ^Volume, node: ^Node) {
	for c in node.first_cluster ..< node.first_cluster + node.cluster_len {
		if int(c) < len(v.alloc.by_cluster) && v.alloc.by_cluster[c] == node {
			v.alloc.by_cluster[c] = nil
		}
	}
	stale := make([dynamic]u32, context.temp_allocator)
	for c, claim in v.journal.claimed {
		if claim.node == node {
			append(&stale, c)
		}
	}
	for c in stale {
		delete_key(&v.journal.claimed, c)
	}
}

// dirs must already be empty on the host or the delete fails loudly
@(private = "file")
apply_delete :: proc(v: ^Volume, node: ^Node) -> bool {
	if rerr := os.remove(node.host_path); rerr != nil {
		volume_fail(v, fmt.tprintf("cannot remove %s (directory not empty?)", node.host_path))
		return false
	}
	detach_child(node)
	release_node_clusters(v, node)
	for pending, i in v.journal.pending_extends {
		if pending == node {
			ordered_remove(&v.journal.pending_extends, i)
			break
		}
	}
	node_tree_destroy(node, v.allocator)
	return true
}

@(private = "file")
de_rd16 :: proc(b: []u8, off: int) -> u16 {
	return u16(b[off]) | u16(b[off + 1]) << 8
}

@(private = "file")
de_rd32 :: proc(b: []u8, off: int) -> u32 {
	return u32(b[off]) | u32(b[off + 1]) << 8 | u32(b[off + 2]) << 16 | u32(b[off + 3]) << 24
}
