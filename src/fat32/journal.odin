// SPDX-License-Identifier: GPL-3.0-only
package fat32

import "base:runtime"
import "core:fmt"
import "core:os"

Journal :: struct {
	overlay:         Sector_Overlay,
	shadow_fat:      map[u32]u32, // FAT entries modified by the guest
	mirrored:        map[Mirror_Key]Mirror_Entry,
	snapshotted:     map[^Node]bool,
	stale_clusters:  map[u32]bool, // detached live file chains awaiting FAT free
	// guest-allocated clusters adopted by decode (may be non-contiguous)
	claimed:         map[u32]Claim,
	pending_deletes: [dynamic]Pending_Delete, // deferred until the chain is freed
	pending_extends: [dynamic]^Node, // dirs with new or changed chains mid-update
	streamed_guest_files: u64,
	streamed_guest_bytes: u64,
}

Claim :: struct {
	node:  ^Node,
	index: u32, // logical cluster index within the node
}

Pending_Delete :: struct {
	node: ^Node,
}

Chain_State :: enum {
	Complete,
	Incomplete,
	Invalid,
}

journal_init :: proc(
	j: ^Journal,
	total_sectors, cluster_count: u32,
	root_path: string,
	allocator := context.allocator,
) -> bool {
	if !overlay_init(&j.overlay, total_sectors, cluster_count, root_path, allocator) {
		return false
	}
	j.shadow_fat = make(map[u32]u32, allocator)
	j.mirrored = make(map[Mirror_Key]Mirror_Entry, allocator)
	j.snapshotted = make(map[^Node]bool, allocator)
	j.stale_clusters = make(map[u32]bool, allocator)
	j.claimed = make(map[u32]Claim, allocator)
	j.pending_deletes = make([dynamic]Pending_Delete, allocator)
	j.pending_extends = make([dynamic]^Node, allocator)
	return true
}

journal_destroy :: proc(j: ^Journal, allocator: runtime.Allocator) {
	if j == nil {
		return
	}
	overlay_destroy(&j.overlay, allocator)
	for _, entry in j.mirrored {
		delete(entry.host_path, allocator)
	}
	delete(j.shadow_fat)
	delete(j.mirrored)
	delete(j.snapshotted)
	delete(j.stale_clusters)
	delete(j.claimed)
	delete(j.pending_deletes)
	delete(j.pending_extends)
	j^ = {}
}

// guest view of a FAT entry: shadow first, then synthesis
volume_fat_entry :: proc(v: ^Volume, cluster: u32) -> u32 {
	if e, ok := v.journal.shadow_fat[cluster]; ok {
		return e
	}
	return fat_entry(&v.alloc, cluster)
}

volume_fat_sector :: proc(v: ^Volume, index: u32, out: []u8) {
	for i in u32(0) ..< 128 {
		e := volume_fat_entry(v, index * 128 + i)
		off := int(i) * 4
		out[off] = u8(e)
		out[off + 1] = u8(e >> 8)
		out[off + 2] = u8(e >> 16)
		out[off + 3] = u8(e >> 24)
	}
}

// follow a guest FAT chain; empty on cycles or bad links
volume_chain :: proc(v: ^Volume, first: u32, allocator := context.allocator) -> [dynamic]u32 {
	chain, state := volume_chain_inspect(v, first, allocator)
	if state != .Complete {clear(&chain)}
	return chain
}

volume_chain_inspect :: proc(
	v: ^Volume,
	first: u32,
	allocator := context.allocator,
) -> (
	[dynamic]u32,
	Chain_State,
) {
	chain := make([dynamic]u32, allocator)
	c := first
	for len(chain) <= int(v.alloc.geo.cluster_count) {
		if c < 2 || c >= v.alloc.geo.cluster_count + 2 {
			return chain, .Invalid
		}
		append(&chain, c)
		next := volume_fat_entry(v, c) & 0x0FFFFFFF
		if next >= 0x0FFFFFF8 {
			return chain, .Complete
		}
		if next == 0 {return chain, .Incomplete}
		c = next
	}
	return chain, .Invalid
}

volume_write :: proc(v: ^Volume, lba: u64, buf: []u8) -> bool {
	if v.frozen {
		return false
	}
	if len(buf) % SECTOR != 0 {
		volume_fail(
			v,
			fmt.tprintf("protected system disk rejected an unaligned write at LBA %d", lba),
		)
		return false
	}
	n := len(buf) / SECTOR
	decisions := make([]Protected_Write_Decision, n, context.temp_allocator)
	for i in 0 ..< n {
		decisions[i] = protected_system_disk_write_policy(
			v,
			lba + u64(i),
			buf[i * SECTOR:][:SECTOR],
		)
		if decisions[i] == .Reject {
			return false
		}
	}
	for i in 0 ..< n {
		if decisions[i] == .Ignore {continue}
		if !write_sector(v, lba + u64(i), buf[i * SECTOR:][:SECTOR]) {
			return false
		}
	}
	return true
}

volume_stage_write :: proc(v: ^Volume, lba: u64, buf: []u8) -> bool {
	if v.frozen {
		return false
	}
	if len(buf) % SECTOR != 0 {
		volume_fail(
			v,
			fmt.tprintf("protected system disk rejected an unaligned write at LBA %d", lba),
		)
		return false
	}
	n := len(buf) / SECTOR
	decisions := make([]Protected_Write_Decision, n, context.temp_allocator)
	for i in 0 ..< n {
		decisions[i] = protected_system_disk_write_policy(
			v,
			lba + u64(i),
			buf[i * SECTOR:][:SECTOR],
		)
		if decisions[i] == .Reject {
			return false
		}
	}
	// Persist each uninterrupted span before publishing its FAT side effects.
	// IDE transfers commonly contain 64-128 sectors, so one pwrite still covers
	// the normal path without exposing metadata that the backing rejected.
	for i := 0; i < n; {
		if decisions[i] == .Ignore {
			i += 1
			continue
		}
		start := i
		for i < n && decisions[i] == .Allow {i += 1}
		rel := u32(lba + u64(start) - PART_START_LBA)
		if !overlay_put_run(v, rel, buf[start * SECTOR:i * SECTOR]) {return false}
		for sector in start ..< i {
			sector_rel := u32(lba + u64(sector) - PART_START_LBA)
			if sector_rel >= v.alloc.geo.fat_start && sector_rel < v.alloc.geo.data_start {
				if !stage_fat_sector(v, sector_rel, buf[sector * SECTOR:][:SECTOR]) {
					return false
				}
			}
		}
	}
	return true
}

@(private = "file")
stage_fat_sector :: proc(v: ^Volume, rel: u32, sec: []u8) -> bool {
	geo := &v.alloc.geo
	if rel >= geo.fat_start + geo.sectors_per_fat {
		return true
	}
	base := (rel - geo.fat_start) * 128
	for i in u32(0) ..< 128 {
		cluster := base + i
		old := volume_fat_entry(v, cluster) & 0x0FFFFFFF
		raw :=
			u32(sec[i * 4]) |
			u32(sec[i * 4 + 1]) << 8 |
			u32(sec[i * 4 + 2]) << 16 |
			u32(sec[i * 4 + 3]) << 24
		next := raw & 0x0FFFFFFF
		v.journal.shadow_fat[cluster] = raw
		if next != old {
			fat_note_dir_change(v, cluster, old, next)
		}
	}
	return extend_pending_dirs(v)
}

@(private = "file")
write_sector :: proc(v: ^Volume, lba: u64, sec: []u8) -> bool {
	geo := &v.alloc.geo
	if lba == 0 || lba < PART_START_LBA {
		volume_fail(v, fmt.tprintf("guest write to boot sector LBA %d", lba))
		return false
	}
	rel64 := lba - PART_START_LBA
	if rel64 >= u64(geo.total_sectors) {
		volume_fail(v, fmt.tprintf("guest write past the volume, LBA %d", lba))
		return false
	}
	rel := u32(rel64)
	if rel == 0 || rel == 6 {
		volume_fail(v, "guest write to the VBR")
		return false
	}
	if rel < geo.fat_start {
		return overlay_put(v, rel, sec) // validated FSInfo counters
	}
	if rel < geo.data_start {
		return write_fat_sector(v, rel, sec)
	}
	di := rel - geo.data_start
	cluster := di / SECTORS_PER_CLUSTER + 2
	soff := di % SECTORS_PER_CLUSTER
	if claim, ok := v.journal.claimed[cluster]; ok {
		if claim.node.is_dir {
			return write_dir_sector(v, claim.node, rel, sec)
		}
		return write_file_sector(v, claim.node, cluster, claim.index, soff, sec)
	}
	node := cluster < u32(len(v.alloc.by_cluster)) ? v.alloc.by_cluster[cluster] : nil
	if node == nil {
		return orphan_write_sector(v, cluster, soff, sec)
	}
	if node.is_dir {
		if !snapshot_dir(v, node) {return false}
		return write_dir_sector(v, node, rel, sec)
	}
	return write_file_sector(v, node, cluster, cluster - node.first_cluster, soff, sec)
}

// record every entry whose guest value differs from the synthesized one
@(private = "file")
write_fat_sector :: proc(v: ^Volume, rel: u32, sec: []u8) -> bool {
	geo := &v.alloc.geo
	if !overlay_put(v, rel, sec) {return false}
	base := ((rel - geo.fat_start) % geo.sectors_per_fat) * 128
	for i in u32(0) ..< 128 {
		cluster := base + i
		raw :=
			u32(sec[i * 4]) |
			u32(sec[i * 4 + 1]) << 8 |
			u32(sec[i * 4 + 2]) << 16 |
			u32(sec[i * 4 + 3]) << 24
		previous := volume_fat_entry(v, cluster) & 0x0FFFFFFF
		next := raw & 0x0FFFFFFF
		if next != previous {
			v.journal.shadow_fat[cluster] = raw
			orphan_note_fat_change(v, cluster, next)
			fat_note_dir_change(v, cluster, previous, next)
		}
	}
	if !extend_pending_dirs(v) {
		return false
	}
	// a freed chain is the commit point of a guest delete
	return volume_flush(v)
}

@(private = "file")
orphan_note_fat_change :: proc(v: ^Volume, cluster, next: u32) {
	delete_key(&v.journal.stale_clusters, cluster)
	if next != 0 {return}
	if orphan_has(v, cluster) {orphan_clear(v, cluster)}
}

// a FAT entry inside a directory's chain changed: the dir may have grown
@(private = "file")
fat_note_dir_change :: proc(v: ^Volume, cluster, previous, next: u32) {
	// A free cluster becoming allocated is a new owner, not growth of the
	// directory that synthesized this cluster before the guest freed it.
	if previous == 0 && next != 0 {
		return
	}
	node: ^Node
	if claim, ok := v.journal.claimed[cluster]; ok {
		node = claim.node
	} else if cluster < u32(len(v.alloc.by_cluster)) {
		node = v.alloc.by_cluster[cluster]
	}
	if node == nil || !node.is_dir {
		return
	}
	for d in v.journal.pending_extends {
		if d == node {
			return
		}
	}
	append(&v.journal.pending_extends, node)
}

// claim clusters newly linked into a directory's chain so entry writes
// there decode instead of landing silently in orphan_data
@(private = "file")
extend_pending_dirs :: proc(v: ^Volume) -> bool {
	i := 0
	for i < len(v.journal.pending_extends) {
		node := v.journal.pending_extends[i]
		if volume_fat_entry(v, node.first_cluster) & 0x0FFFFFFF == 0 {
			if node.cluster_len == 0 {
				i += 1 // new directory whose FAT chain is not committed yet
				continue
			}
			ordered_remove(&v.journal.pending_extends, i) // existing chain freed: a delete, not growth
			continue
		}
		chain, state := volume_chain_inspect(v, node.first_cluster, context.temp_allocator)
		if state == .Incomplete {
			i += 1 // chain mid-update: retry after the next FAT write
			continue
		}
		if state == .Invalid {
			volume_fail(
				v,
				fmt.tprintf("bad FAT chain at cluster %d for %s", node.first_cluster, node.name),
			)
			return false
		}
		if chain_adoption_needed(v, node, chain[:]) {
			if _, claimed := v.journal.claimed[node.first_cluster]; !claimed {
				if !snapshot_dir(v, node) {return false} // synthesized content must be diffable first
			}
			if !claim_chain(v, node, node.first_cluster) {
				return false
			}
		}
		ordered_remove(&v.journal.pending_extends, i)
	}
	return true
}

@(private)
chain_adoption_needed :: proc(v: ^Volume, node: ^Node, chain: []u32) -> bool {
	if len(chain) == 0 {
		return node.first_cluster != 0 || node.cluster_len != 0
	}
	if node.first_cluster != chain[0] {
		return true
	}
	if u32(len(chain)) != node.cluster_len {
		return true
	}
	for cluster, index in chain {
		if claim, ok := v.journal.claimed[cluster]; ok {
			if claim.node != node || claim.index != u32(index) {
				return true
			}
			continue
		}
		if cluster >= u32(len(v.alloc.by_cluster)) ||
		   v.alloc.by_cluster[cluster] != node ||
		   cluster < node.first_cluster ||
		   cluster - node.first_cluster != u32(index) {
			return true
		}
	}
	for cluster, claim in v.journal.claimed {
		if claim.node == node &&
		   (claim.index >= u32(len(chain)) || chain[claim.index] != cluster) {
			return true
		}
	}
	return false
}

// in-size bytes land in the host file; the tail waits in orphan_data
// until a directory entry confirms the grown size
@(private = "file")
write_file_sector :: proc(
	v: ^Volume,
	node: ^Node,
	cluster: u32,
	index: u32,
	soff: u32,
	sec: []u8,
) -> bool {
	off := i64(index) * CLUSTER_BYTES + i64(soff) * SECTOR
	in_size := i64(node.size) - off
	if in_size > SECTOR {
		in_size = SECTOR
	}
	if in_size > 0 {
		if !host_write_at(v, node, sec[:in_size], off) {
			return false
		}
	}
	if in_size < SECTOR {
		if !orphan_write_sector(v, cluster, soff, sec) {return false}
	}
	return true
}

// freeze the synthesized content of a dir before its tree mutates
@(private = "file")
snapshot_dir :: proc(v: ^Volume, dir: ^Node) -> bool {
	geo := &v.alloc.geo
	shorts := dir_short_names(dir, context.temp_allocator)
	for child, i in dir.children {
		if child.short == ([11]u8{}) {
			child.short = shorts[i]
		}
	}
	tmp: [CLUSTER_BYTES]u8
	for ci in u32(0) ..< dir.cluster_len {
		c := dir.first_cluster + ci
		rel0 := geo.data_start + (c - 2) * SECTORS_PER_CLUSTER
		missing := false
		for s in u32(0) ..< SECTORS_PER_CLUSTER {
			if !overlay_has(v, rel0 + s) {
				missing = true
			}
		}
		if !missing {
			continue
		}
		dir_cluster_data(&v.alloc, dir, ci, tmp[:])
		for s in u32(0) ..< SECTORS_PER_CLUSTER {
			if !overlay_has(v, rel0 + s) {
				if !overlay_put(v, rel0 + s, tmp[int(s) * SECTOR:][:SECTOR]) {return false}
			}
		}
	}
	return true
}

@(private)
write_dir_sector :: proc(v: ^Volume, dir: ^Node, rel: u32, sec: []u8) -> bool {
	// earlier sectors of the same cluster feed the LFN carry state, so a
	// name whose entries straddle a sector boundary still decodes
	soff := int((rel - v.alloc.geo.data_start) % SECTORS_PER_CLUSTER)
	prefix := make([]u8, soff * SECTOR, context.temp_allocator)
	for s in 0 ..< soff {
		_, ok := overlay_get(
			v,
			rel - u32(soff - s),
			prefix[s * SECTOR:][:SECTOR],
		)
		if !ok {return false}
	}
	old: [SECTOR]u8
	_, ok := overlay_get(v, rel, old[:])
	if !ok {return false}
	if !overlay_put(v, rel, sec) {return false}
	return decode_dir_write(v, dir, prefix, old[:], sec)
}

host_write_at :: proc(v: ^Volume, node: ^Node, data: []u8, offset: i64) -> bool {
	f, oerr := os.open(node.host_path, {.Write})
	if oerr != nil {
		volume_fail(v, fmt.tprintf("cannot open %s for writing", node.host_path))
		return false
	}
	defer os.close(f)
	total := 0
	for total < len(data) {
		n, werr := os.write_at(f, data[total:], offset + i64(total))
		if werr != nil {
			volume_fail(v, fmt.tprintf("write failed on %s", node.host_path))
			return false
		}
		total += n
	}
	return true
}
