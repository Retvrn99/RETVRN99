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
			volume_fail(
				v,
				fmt.tprintf("removed entry %s has no host node", short_to_name(o.short, ta)),
			)
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
			if !apply_change(v, dir, o, &n, &round_deletes) {
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
	return volume_reconcile(v)
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
Lfn_State :: struct {
	units: [20 * 13]u16,
	max:   int,
	csum:  u8,
}

parse_dir_sector :: proc(
	sec: []u8,
	st: ^Lfn_State,
	allocator := context.allocator,
) -> [dynamic]Dir_Entry {
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

@(private = "file")
replacement_donor_available :: proc(
	v: ^Volume,
	round: ^[dynamic]^Node,
	node: ^Node,
	cluster: u32,
) -> bool {
	if node == nil || node.is_dir || node.first_cluster != cluster {return false}
	for pending in v.journal.pending_deletes {
		if pending.node == node {return true}
	}
	for deleted in round^ {
		if deleted == node {return true}
	}
	return false
}

@(private = "file")
consume_replacement_donor :: proc(v: ^Volume, round: ^[dynamic]^Node, donor: ^Node) -> bool {
	for pending, i in v.journal.pending_deletes {
		if pending.node == donor {
			ordered_remove(&v.journal.pending_deletes, i)
			return apply_delete(v, donor)
		}
	}
	for deleted, i in round^ {
		if deleted == donor {
			ordered_remove(round, i)
			return apply_delete(v, donor)
		}
	}
	volume_fail(v, fmt.tprintf("replacement donor %s is no longer pending deletion", donor.name))
	return false
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
	for c in chain {
		if claim, ok := v.journal.claimed[c]; ok && claim.node != node {
			volume_fail(
				v,
				fmt.tprintf("FAT chain cluster %d for %s is already claimed", c, node.name),
			)
			return false
		}
		if c < u32(len(v.alloc.by_cluster)) {
			owner := v.alloc.by_cluster[c]
			if owner != nil && owner != node {
				volume_fail(
					v,
					fmt.tprintf(
						"FAT chain cluster %d for %s belongs to %s",
						c,
						node.name,
						owner.name,
					),
				)
				return false
			}
		}
	}
	if node == v.alloc.root && !root_chain_detach_safe(v, node, chain[:]) {
		return false
	}
	geo := &v.alloc.geo
	release_node_clusters(v, node)
	node.first_cluster = first
	node.cluster_len = u32(len(chain))
	for c, idx in chain {
		delete_key(&v.journal.stale_clusters, c)
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
root_chain_detach_safe :: proc(v: ^Volume, root: ^Node, chain: []u32) -> bool {
	new_chain := make(map[u32]bool, context.temp_allocator)
	old_chain := make(map[u32]bool, context.temp_allocator)
	for cluster in chain {new_chain[cluster] = true}
	for owner, cluster in v.alloc.by_cluster {
		if owner == root {old_chain[u32(cluster)] = true}
	}
	for cluster, claim in v.journal.claimed {
		if claim.node == root {old_chain[cluster] = true}
	}
	for cluster in old_chain {
		if new_chain[cluster] {continue}
		block: [CLUSTER_BYTES]u8
		lba := u64(PART_START_LBA) + u64(cluster_to_lba(&v.alloc.geo, cluster))
		if !volume_read(v, lba, block[:]) {
			return false
		}
		for offset := 0; offset < len(block); offset += 32 {
			if block[offset] != 0 && block[offset] != 0xE5 {
				volume_fail(
					v,
					fmt.tprintf(
						"protected system disk rejected nonempty root chain truncation at cluster %d",
						cluster,
					),
				)
				return false
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
decode_new_node :: proc(
	v: ^Volume,
	dir: ^Node,
	name, path: string,
	e: ^Dir_Entry,
	is_dir: bool,
) -> ^Node {
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
apply_create :: proc(
	v: ^Volume,
	dir: ^Node,
	e: ^Dir_Entry,
	round_deletes: ^[dynamic]^Node,
) -> bool {
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
apply_change :: proc(
	v: ^Volume,
	dir: ^Node,
	o, n: ^Dir_Entry,
	round_deletes: ^[dynamic]^Node,
) -> bool {
	if (o.attr ~ n.attr) & ATTR_DIR != 0 {
		volume_fail(
			v,
			fmt.tprintf("entry %s changed kind", short_to_name(n.short, context.temp_allocator)),
		)
		return false
	}
	node := child_by_short(dir, n.short)
	if node == nil {
		volume_fail(
			v,
			fmt.tprintf(
				"changed entry %s has no host node",
				short_to_name(n.short, context.temp_allocator),
			),
		)
		return false
	}
	if o.cluster != n.cluster {
		if o.cluster != 0 && n.cluster != 0 {
			return apply_file_chain_replacement(
				v,
				node,
				o.cluster,
				n.cluster,
				n.size,
				round_deletes,
			)
		}
		// Truncate-to-zero is the standard DOS overwrite path.
		if n.cluster == 0 {
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

@(private = "file")
Replacement_Slack :: struct {
	cluster: u32,
	data:    []u8,
}

// Windows Setup may replace a file before or after freeing its old chain.
@(private = "file")
apply_file_chain_replacement :: proc(
	v: ^Volume,
	node: ^Node,
	old_first, new_first, new_size: u32,
	round_deletes: ^[dynamic]^Node,
) -> bool {
	if node.is_dir {
		volume_fail(v, fmt.tprintf("directory %s changed first cluster", node.name))
		return false
	}
	if node.first_cluster != old_first {
		volume_fail(
			v,
			fmt.tprintf(
				"first cluster of %s changed unexpectedly from %d before moving to %d",
				node.name,
				old_first,
				new_first,
			),
		)
		return false
	}
	old_live := volume_fat_entry(v, old_first) & 0x0FFFFFFF != 0
	old_chain, old_state := volume_chain_inspect(v, old_first, context.temp_allocator)
	if old_live && old_state != .Complete {
		volume_fail(
			v,
			fmt.tprintf(
				"old FAT chain at cluster %d for %s is not complete",
				old_first,
				node.name,
			),
		)
		return false
	}
	if !old_live {clear(&old_chain)}

	chain, state := volume_chain_inspect(v, new_first, context.temp_allocator)
	if state != .Complete {
		volume_fail(
			v,
			fmt.tprintf(
				"replacement FAT chain at cluster %d for %s is not complete",
				new_first,
				node.name,
			),
		)
		return false
	}
	if u64(new_size) > u64(len(chain)) * u64(CLUSTER_BYTES) {
		volume_fail(v, fmt.tprintf("replacement FAT chain for %s is too short", node.name))
		return false
	}

	new_clusters := make(map[u32]bool, context.temp_allocator)
	old_clusters := make(map[u32]bool, context.temp_allocator)
	for c in node.first_cluster ..< node.first_cluster + node.cluster_len {
		old_clusters[c] = true
	}
	for c, claim in v.journal.claimed {
		if claim.node == node {
			old_clusters[c] = true
		}
	}
	for c in old_chain {
		old_clusters[c] = true
		if claim, ok := v.journal.claimed[c]; ok && claim.node != node {
			volume_fail(
				v,
				fmt.tprintf("old chain cluster %d for %s is already claimed", c, node.name),
			)
			return false
		}
		if c < u32(len(v.alloc.by_cluster)) {
			owner := v.alloc.by_cluster[c]
			if owner != nil && owner != node {
				volume_fail(
					v,
					fmt.tprintf(
						"old chain cluster %d for %s belongs to %s",
						c,
						node.name,
						owner.name,
					),
				)
				return false
			}
		}
	}
	donor: ^Node
	for c in chain {
		new_clusters[c] = true
		owner: ^Node
		if claim, ok := v.journal.claimed[c]; ok {
			owner = claim.node
		}
		if owner == nil && c < u32(len(v.alloc.by_cluster)) {
			owner = v.alloc.by_cluster[c]
		}
		if owner == nil || owner == node {continue}
		if donor == nil && replacement_donor_available(v, round_deletes, owner, new_first) {
			donor = owner
		}
		if owner != donor {
			volume_fail(
				v,
				fmt.tprintf(
					"replacement chain cluster %d for %s belongs to live file %s at %d",
					c,
					node.name,
					owner.name,
					owner.first_cluster,
				),
			)
			return false
		}
	}

	temporary := fmt.tprintf("%s.retvrn99-%d-%d.tmp", node.host_path, os.get_pid(), new_first)
	defer _ = os.remove(temporary)
	f, oerr := os.open(temporary, {.Write, .Create, .Trunc})
	if oerr != nil {
		volume_fail(v, fmt.tprintf("cannot create replacement for %s", node.host_path))
		return false
	}
	file_open := true
	defer if file_open {_ = os.close(f)}

	slack := make([dynamic]Replacement_Slack, context.temp_allocator)
	stale_data := make([dynamic]Replacement_Slack, context.temp_allocator)
	committed := false
	defer if !committed {
		for s in slack {
			delete(s.data, v.allocator)
		}
		for s in stale_data {
			delete(s.data, v.allocator)
		}
	}

	written: i64
	block: [CLUSTER_BYTES]u8
	for c, index in chain {
		lba := u64(PART_START_LBA) + u64(cluster_to_lba(&v.alloc.geo, c))
		if !volume_read(v, lba, block[:]) {
			return false
		}
		base := u64(index) * u64(CLUSTER_BYTES)
		in_size := min(u64(CLUSTER_BYTES), u64(new_size) - min(base, u64(new_size)))
		if in_size > 0 {
			total := 0
			for total < int(in_size) {
				n, werr := os.write_at(f, block[total:int(in_size)], written + i64(total))
				if werr != nil || n == 0 {
					volume_fail(
						v,
						fmt.tprintf("cannot materialize replacement for %s", node.host_path),
					)
					return false
				}
				total += n
			}
			written += i64(in_size)
		}
		if in_size < u64(CLUSTER_BYTES) && replacement_has_data(block[int(in_size):]) {
			data := make([]u8, CLUSTER_BYTES, v.allocator)
			copy(data, block[:])
			append(&slack, Replacement_Slack{c, data})
		}
	}
	for c in old_chain {
		if new_clusters[c] {continue}
		lba := u64(PART_START_LBA) + u64(cluster_to_lba(&v.alloc.geo, c))
		if !volume_read(v, lba, block[:]) {return false}
		if replacement_has_data(block[:]) {
			data := make([]u8, CLUSTER_BYTES, v.allocator)
			copy(data, block[:])
			append(&stale_data, Replacement_Slack{c, data})
		}
	}
	if cerr := os.close(f); cerr != nil {
		file_open = false
		volume_fail(v, fmt.tprintf("cannot close replacement for %s", node.host_path))
		return false
	}
	file_open = false
	if rerr := os.rename(temporary, node.host_path); rerr != nil {
		volume_fail(v, fmt.tprintf("cannot install replacement for %s", node.host_path))
		return false
	}
	if donor != nil && !consume_replacement_donor(v, round_deletes, donor) {
		return false
	}

	for c in old_clusters {
		if data, ok := v.journal.orphan_data[c]; ok {
			delete(data, v.allocator)
			delete_key(&v.journal.orphan_data, c)
		}
		delete_key(&v.journal.stale_clusters, c)
	}
	for c in new_clusters {
		if data, ok := v.journal.orphan_data[c]; ok {
			delete(data, v.allocator)
			delete_key(&v.journal.orphan_data, c)
		}
		delete_key(&v.journal.stale_clusters, c)
	}
	for c in old_chain {
		v.journal.shadow_fat[c] = volume_fat_entry(v, c)
	}
	for c in chain {
		v.journal.shadow_fat[c] = volume_fat_entry(v, c)
	}
	release_node_clusters(v, node)
	node.first_cluster = new_first
	node.cluster_len = u32(len(chain))
	node.size = u64(new_size)
	for c, index in chain {
		v.journal.claimed[c] = Claim{node, u32(index)}
	}
	for s in slack {
		v.journal.orphan_data[s.cluster] = s.data
	}
	for c in old_chain {
		if !new_clusters[c] {v.journal.stale_clusters[c] = true}
	}
	for s in stale_data {
		v.journal.orphan_data[s.cluster] = s.data
	}
	committed = true
	return true
}

@(private = "file")
replacement_has_data :: proc(data: []u8) -> bool {
	for b in data {
		if b != 0 {return true}
	}
	return false
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
		delete_key(&v.journal.stale_clusters, c)
	}
	stale := make([dynamic]u32, context.temp_allocator)
	for c, claim in v.journal.claimed {
		if claim.node == node {
			append(&stale, c)
		}
	}
	for c in stale {
		delete_key(&v.journal.claimed, c)
		delete_key(&v.journal.stale_clusters, c)
	}
}

@(private)
managed_node_attached :: proc(root, target: ^Node) -> bool {
	if root == nil || target == nil {return false}
	if root == target {return true}
	for child in root.children {
		if managed_node_attached(child, target) {return true}
	}
	return false
}

@(private = "file")
managed_node_forget_mirrors :: proc(v: ^Volume, node: ^Node) {
	keys := make([dynamic]Mirror_Key, context.temp_allocator)
	for key, entry in v.journal.mirrored {
		if entry.base_node != nil && managed_node_attached(node, entry.base_node) {
			append(&keys, key)
		}
	}
	for key in keys {
		entry := v.journal.mirrored[key]
		delete(entry.host_path, v.allocator)
		delete_key(&v.journal.mirrored, key)
	}
}

@(private = "file")
managed_node_release_tree :: proc(v: ^Volume, node: ^Node) {
	for child in node.children {
		managed_node_release_tree(v, child)
	}
	release_node_clusters(v, node)
	delete_key(&v.journal.snapshotted, node)
	for index := len(v.journal.pending_deletes) - 1; index >= 0; index -= 1 {
		if v.journal.pending_deletes[index].node == node {
			ordered_remove(&v.journal.pending_deletes, index)
		}
	}
	for index := len(v.journal.pending_extends) - 1; index >= 0; index -= 1 {
		if v.journal.pending_extends[index] == node {
			ordered_remove(&v.journal.pending_extends, index)
		}
	}
}

@(private)
managed_node_destroy :: proc(v: ^Volume, node: ^Node) -> bool {
	if v == nil ||
	   node == nil ||
	   node == v.alloc.root ||
	   !managed_node_attached(v.alloc.root, node) {
		return false
	}
	managed_node_forget_mirrors(v, node)
	detach_child(node)
	managed_node_release_tree(v, node)
	node_tree_destroy(node, v.allocator)
	return true
}

@(private)
managed_node_adopt_chain :: proc(v: ^Volume, node: ^Node, first, size: u32, chain: []u32) {
	release_node_clusters(v, node)
	node.first_cluster = first
	node.cluster_len = u32(len(chain))
	node.size = u64(size)
	for cluster, index in chain {
		delete_key(&v.journal.stale_clusters, cluster)
		v.journal.claimed[cluster] = Claim{node, u32(index)}
	}
}

@(private)
managed_node_create :: proc(
	v: ^Volume,
	parent: ^Node,
	name, host_path: string,
	short: [11]u8,
	first, size: u32,
	is_dir: bool,
	chain: []u32,
) -> ^Node {
	if v == nil ||
	   parent == nil ||
	   !parent.is_dir ||
	   !managed_node_attached(v.alloc.root, parent) {
		return nil
	}
	node := new(Node, v.allocator)
	node.name = strings.clone(name, v.allocator)
	node.host_path = strings.clone(host_path, v.allocator)
	node.short = short
	node.first_cluster = first
	node.cluster_len = u32(len(chain))
	node.size = u64(size)
	node.is_dir = is_dir
	node.parent = parent
	node.children = make([dynamic]^Node, v.allocator)
	append(&parent.children, node)
	for cluster, index in chain {
		delete_key(&v.journal.stale_clusters, cluster)
		v.journal.claimed[cluster] = Claim{node, u32(index)}
	}
	return node
}

@(private)
managed_node_rebind :: proc(
	v: ^Volume,
	node, parent: ^Node,
	name, host_path: string,
	short: [11]u8,
	first, size: u32,
	is_dir: bool,
	chain: []u32,
) -> bool {
	if node == nil ||
	   parent == nil ||
	   node == v.alloc.root ||
	   node.is_dir != is_dir ||
	   !managed_node_attached(v.alloc.root, node) ||
	   !managed_node_attached(v.alloc.root, parent) ||
	   !parent.is_dir {
		return false
	}
	if node.parent != parent {
		detach_child(node)
		node.parent = parent
		append(&parent.children, node)
	}
	delete(node.name, v.allocator)
	delete(node.host_path, v.allocator)
	node.name = strings.clone(name, v.allocator)
	node.host_path = strings.clone(host_path, v.allocator)
	node.short = short
	managed_node_adopt_chain(v, node, first, size, chain)
	return true
}

// dirs must already be empty on the host or the delete fails loudly
@(private = "file")
apply_delete :: proc(v: ^Volume, node: ^Node) -> bool {
	if rerr := os.remove(node.host_path); rerr != nil {
		volume_fail(v, fmt.tprintf("cannot remove %s (directory not empty?)", node.host_path))
		return false
	}
	if !managed_node_destroy(v, node) {
		volume_fail(v, "deleted FAT32 node lost ownership before teardown")
		return false
	}
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
