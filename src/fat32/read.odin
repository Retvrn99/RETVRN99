// SPDX-License-Identifier: GPL-3.0-only
package fat32

import "core:fmt"
import "core:os"

// buf is n*512; every sector is synthesized on demand
volume_read :: proc(v: ^Volume, lba: u64, buf: []u8) -> bool {
	if v == nil || len(buf) % SECTOR != 0 {return false}
	n := len(buf) / SECTOR
	for i := 0; i < n; {
		if count, handled, ok := read_file_run(v, lba + u64(i), n - i, buf[i * SECTOR:]); handled {
			if !ok {return false}
			i += count
			continue
		}
		if !read_sector(v, lba + u64(i), buf[i * SECTOR:][:SECTOR]) {
			return false
		}
		i += 1
	}
	return true
}

@(private = "file")
read_file_mapping :: proc(v: ^Volume, lba: u64) -> (^Node, u32, u32, u32, bool) {
	geo := &v.alloc.geo
	if lba < PART_START_LBA {return nil, 0, 0, 0, false}
	rel64 := lba - PART_START_LBA
	if rel64 >= u64(geo.total_sectors) {return nil, 0, 0, 0, false}
	rel := u32(rel64)
	if rel < geo.data_start {return nil, 0, 0, rel, false}
	if _, overlaid := v.journal.overlay[rel]; overlaid {return nil, 0, 0, rel, false}
	di := rel - geo.data_start
	cluster := di / SECTORS_PER_CLUSTER + 2
	soff := di % SECTORS_PER_CLUSTER
	if _, orphaned := v.journal.orphan_data[cluster]; orphaned {return nil, 0, 0, rel, false}
	node: ^Node
	index: u32
	if claim, ok := v.journal.claimed[cluster]; ok {
		node, index = claim.node, claim.index
	} else if cluster < u32(len(v.alloc.by_cluster)) && v.alloc.by_cluster[cluster] != nil {
		node = v.alloc.by_cluster[cluster]
		index = cluster - node.first_cluster
	}
	if node == nil || node.is_dir {return nil, 0, 0, rel, false}
	return node, index, soff, rel, true
}

@(private = "file")
read_file_run :: proc(
	v: ^Volume,
	lba: u64,
	max_sectors: int,
	out: []u8,
) -> (count: int, handled: bool, ok: bool) {
	node, cluster_index, sector_offset, _, mapped := read_file_mapping(v, lba)
	if !mapped || max_sectors <= 0 {return 0, false, false}
	start_offset := u64(cluster_index) * CLUSTER_BYTES + u64(sector_offset) * SECTOR
	count = 1
	for count < max_sectors {
		candidate, next_cluster, next_sector, _, next_mapped := read_file_mapping(v, lba + u64(count))
		if !next_mapped || candidate != node {break}
		next_offset := u64(next_cluster) * CLUSTER_BYTES + u64(next_sector) * SECTOR
		if next_offset != start_offset + u64(count * SECTOR) {break}
		count += 1
	}
	destination := out[:count * SECTOR]
	for &byte in destination {byte = 0}
	if start_offset >= node.size {return count, true, true}
	expected := int(min(u64(len(destination)), node.size - start_offset))
	f, oerr := os.open(node.host_path)
	if oerr != nil {
		volume_fail(v, fmt.tprintf("cannot open backing file %s for reading", node.host_path))
		return count, true, false
	}
	v.backing_read_opens += 1
	defer os.close(f)
	if !backing_read_exact(v, f, node.host_path, destination[:expected], i64(start_offset)) {
		return count, true, false
	}
	v.backing_read_bytes += u64(expected)
	return count, true, true
}

@(private = "file")
read_sector :: proc(v: ^Volume, lba: u64, out: []u8) -> bool {
	for i in 0 ..< SECTOR {
		out[i] = 0
	}
	geo := &v.alloc.geo
	if lba == 0 {
		mbr := make_mbr(geo.total_sectors)
		copy(out, mbr[:])
		return true
	}
	if lba < PART_START_LBA {
		return true // gap before the partition
	}
	rel64 := lba - PART_START_LBA
	if rel64 >= u64(geo.total_sectors) {
		return true
	}
	rel := u32(rel64)
	// guest-written sectors win over synthesis
	if sec, ok := v.journal.overlay[rel]; ok {
		copy(out, sec)
		return true
	}
	switch rel {
	case 0, 6:
		vbr := make_vbr(geo, geo.total_sectors, v.io_sys_lba, v.io_sys_cluster)
		copy(out, vbr[:])
		return true
	case 1, 7:
		fi := make_fsinfo()
		copy(out, fi[:])
		return true
	}
	if rel < geo.fat_start {
		return true // rest of the reserved area
	}
	if rel < geo.data_start {
		volume_fat_sector(v, (rel - geo.fat_start) % geo.sectors_per_fat, out)
		return true
	}
	// data area: map the sector to its owning node
	di := rel - geo.data_start
	cluster := di / SECTORS_PER_CLUSTER + 2
	soff := di % SECTORS_PER_CLUSTER
	node: ^Node
	index: u32
	if claim, ok := v.journal.claimed[cluster]; ok {
		node, index = claim.node, claim.index
	} else if cluster < u32(len(v.alloc.by_cluster)) && v.alloc.by_cluster[cluster] != nil {
		node = v.alloc.by_cluster[cluster]
		index = cluster - node.first_cluster
	}
	if node == nil {
		if ob, ok := v.journal.orphan_data[cluster]; ok {
			copy(out, ob[int(soff) * SECTOR:][:SECTOR])
		}
		return true
	}
	if node.is_dir {
		// guest-managed dir sectors live in the overlay (already checked)
		if _, claimed := v.journal.claimed[cluster]; !claimed {
			tmp: [CLUSTER_BYTES]u8
			dir_cluster_data(&v.alloc, node, index, tmp[:])
			copy(out, tmp[int(soff) * SECTOR:][:SECTOR])
		}
		return true
	}
	if !read_file_sector(v, node, index, soff, out) {
		return false
	}
	// bytes past EOF the guest already wrote but the dir entry has not confirmed
	if ob, ok := v.journal.orphan_data[cluster]; ok {
		off := u64(index) * CLUSTER_BYTES + u64(soff) * SECTOR
		for i in 0 ..< SECTOR {
			if off + u64(i) >= node.size {
				out[i] = ob[int(soff) * SECTOR + i]
			}
		}
	}
	return true
}

// Bytes beyond the advertised file size stay zero padded.
@(private = "file")
read_file_sector :: proc(
	v: ^Volume,
	node: ^Node,
	cluster_index: u32,
	soff: u32,
	out: []u8,
) -> bool {
	offset := i64(cluster_index) * CLUSTER_BYTES + i64(soff) * SECTOR
	if offset >= i64(node.size) {
		return true
	}
	f, oerr := os.open(node.host_path)
	if oerr != nil {
		volume_fail(v, fmt.tprintf("cannot open backing file %s for reading", node.host_path))
		return false
	}
	v.backing_read_opens += 1
	defer os.close(f)
	expected := int(min(i64(SECTOR), i64(node.size) - offset))
	ok := backing_read_exact(v, f, node.host_path, out[:expected], offset)
	if ok {v.backing_read_bytes += u64(expected)}
	return ok
}

@(private)
backing_read_exact :: proc(v: ^Volume, f: ^os.File, path: string, out: []u8, offset: i64) -> bool {
	total := 0
	for total < len(out) {
		n, rerr := os.read_at(f, out[total:], offset + i64(total))
		if n > 0 {total += n}
		if rerr != nil && rerr != .EOF {
			volume_fail(
				v,
				fmt.tprintf(
					"backing read failed for %s at byte %d (%v)",
					path,
					offset + i64(total),
					rerr,
				),
			)
			return false
		}
		if total < len(out) && (rerr == .EOF || n == 0) {
			volume_fail(
				v,
				fmt.tprintf(
					"backing file %s ended at byte %d before its advertised size",
					path,
					offset + i64(total),
				),
			)
			return false
		}
	}
	return true
}
