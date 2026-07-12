// SPDX-License-Identifier: GPL-3.0-only
package fat32

import "core:fmt"
import "core:os"

Journal :: struct {
	overlay:         map[u32][]u8, // relative LBA -> written sector (512B)
	shadow_fat:      map[u32]u32, // FAT entries modified by the guest
	// clusters written by the guest that belong to no node yet
	orphan_data:     map[u32][]u8, // cluster -> 4096B
	// guest-allocated clusters adopted by decode (may be non-contiguous)
	claimed:         map[u32]Claim,
	pending_deletes: [dynamic]Pending_Delete, // deferred one decode round
}

Claim :: struct {
	node:  ^Node,
	index: u32, // logical cluster index within the node
}

Pending_Delete :: struct {
	node: ^Node,
}

journal_init :: proc(j: ^Journal) {
	j.overlay = {}
	j.shadow_fat = {}
	j.orphan_data = {}
	j.claimed = {}
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
	chain := make([dynamic]u32, allocator)
	c := first
	for len(chain) <= int(v.alloc.geo.cluster_count) {
		if c < 2 || c >= v.alloc.geo.cluster_count + 2 {
			clear(&chain)
			return chain
		}
		append(&chain, c)
		next := volume_fat_entry(v, c) & 0x0FFFFFFF
		if next >= 0x0FFFFFF8 {
			return chain
		}
		c = next
	}
	clear(&chain)
	return chain
}

volume_write :: proc(v: ^Volume, lba: u64, buf: []u8) -> bool {
	if v.frozen {
		return false
	}
	n := len(buf) / SECTOR
	for i in 0 ..< n {
		if !write_sector(v, lba + u64(i), buf[i * SECTOR:][:SECTOR]) {
			return false
		}
	}
	return true
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
		overlay_put(v, rel, sec) // FSInfo and friends
		return true
	}
	if rel < geo.data_start {
		write_fat_sector(v, rel, sec)
		return true
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
		ob := orphan_ensure(v, cluster)
		copy(ob[int(soff) * SECTOR:][:SECTOR], sec)
		return true
	}
	if node.is_dir {
		snapshot_dir(v, node)
		return write_dir_sector(v, node, rel, sec)
	}
	return write_file_sector(v, node, cluster, cluster - node.first_cluster, soff, sec)
}

overlay_put :: proc(v: ^Volume, rel: u32, sec: []u8) {
	dst, ok := v.journal.overlay[rel]
	if !ok {
		dst = make([]u8, SECTOR)
		v.journal.overlay[rel] = dst
	}
	copy(dst, sec)
}

// record every entry whose guest value differs from the synthesized one
@(private = "file")
write_fat_sector :: proc(v: ^Volume, rel: u32, sec: []u8) {
	geo := &v.alloc.geo
	overlay_put(v, rel, sec)
	base := ((rel - geo.fat_start) % geo.sectors_per_fat) * 128
	for i in u32(0) ..< 128 {
		cluster := base + i
		raw := u32(sec[i * 4]) | u32(sec[i * 4 + 1]) << 8 | u32(sec[i * 4 + 2]) << 16 | u32(sec[i * 4 + 3]) << 24
		if raw & 0x0FFFFFFF != volume_fat_entry(v, cluster) & 0x0FFFFFFF {
			v.journal.shadow_fat[cluster] = raw
		}
	}
}

@(private = "file")
orphan_ensure :: proc(v: ^Volume, cluster: u32) -> []u8 {
	ob, ok := v.journal.orphan_data[cluster]
	if !ok {
		ob = make([]u8, CLUSTER_BYTES)
		v.journal.orphan_data[cluster] = ob
	}
	return ob
}

// in-size bytes land in the host file; the tail waits in orphan_data
// until a directory entry confirms the grown size
@(private = "file")
write_file_sector :: proc(v: ^Volume, node: ^Node, cluster: u32, index: u32, soff: u32, sec: []u8) -> bool {
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
		ob := orphan_ensure(v, cluster)
		copy(ob[int(soff) * SECTOR:][:SECTOR], sec)
	}
	return true
}

// freeze the synthesized content of a dir before its tree mutates
@(private = "file")
snapshot_dir :: proc(v: ^Volume, dir: ^Node) {
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
			if _, ok := v.journal.overlay[rel0 + s]; !ok {
				missing = true
			}
		}
		if !missing {
			continue
		}
		dir_cluster_data(&v.alloc, dir, ci, tmp[:])
		for s in u32(0) ..< SECTORS_PER_CLUSTER {
			if _, ok := v.journal.overlay[rel0 + s]; !ok {
				overlay_put(v, rel0 + s, tmp[int(s) * SECTOR:][:SECTOR])
			}
		}
	}
}

@(private = "file")
write_dir_sector :: proc(v: ^Volume, dir: ^Node, rel: u32, sec: []u8) -> bool {
	old: [SECTOR]u8
	if prev, ok := v.journal.overlay[rel]; ok {
		copy(old[:], prev)
	}
	overlay_put(v, rel, sec)
	return decode_dir_write(v, dir, old[:], sec)
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
