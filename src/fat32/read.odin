// SPDX-License-Identifier: GPL-3.0-only
package fat32

import "core:os"

// buf is n*512; every sector is synthesized on demand
volume_read :: proc(v: ^Volume, lba: u64, buf: []u8) -> bool {
	n := len(buf) / SECTOR
	for i in 0 ..< n {
		if !read_sector(v, lba + u64(i), buf[i * SECTOR:][:SECTOR]) {
			return false
		}
	}
	return true
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

// short reads (EOF inside the cluster) stay zero padded
@(private = "file")
read_file_sector :: proc(v: ^Volume, node: ^Node, cluster_index: u32, soff: u32, out: []u8) -> bool {
	offset := i64(cluster_index) * CLUSTER_BYTES + i64(soff) * SECTOR
	if offset >= i64(node.size) {
		return true
	}
	f, oerr := os.open(node.host_path)
	if oerr != nil {
		volume_fail(v, node.host_path)
		return false
	}
	defer os.close(f)
	total := 0
	for total < SECTOR {
		n, rerr := os.read_at(f, out[total:], offset + i64(total))
		if n > 0 {
			total += n
		}
		if rerr != nil || n == 0 {
			break // EOF padding is already zeroed
		}
	}
	return true
}
