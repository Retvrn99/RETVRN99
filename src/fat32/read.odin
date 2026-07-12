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
	switch rel {
	case 0, 6:
		vbr := make_vbr(geo, geo.total_sectors)
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
		fat_sector(&v.alloc, (rel - geo.fat_start) % geo.sectors_per_fat, out)
		return true
	}
	// data area: map the sector to its owning node
	di := rel - geo.data_start
	cluster := di / SECTORS_PER_CLUSTER + 2
	soff := di % SECTORS_PER_CLUSTER
	node := cluster < u32(len(v.alloc.by_cluster)) ? v.alloc.by_cluster[cluster] : nil
	if node == nil {
		return true // free cluster; journal overlay arrives in Task 19
	}
	if node.is_dir {
		tmp: [CLUSTER_BYTES]u8
		dir_cluster_data(&v.alloc, node, cluster - node.first_cluster, tmp[:])
		copy(out, tmp[int(soff) * SECTOR:][:SECTOR])
		return true
	}
	return read_file_sector(v, node, cluster, soff, out)
}

// short reads (EOF inside the cluster) stay zero padded
@(private = "file")
read_file_sector :: proc(v: ^Volume, node: ^Node, cluster: u32, soff: u32, out: []u8) -> bool {
	offset := i64(cluster - node.first_cluster) * CLUSTER_BYTES + i64(soff) * SECTOR
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

@(private = "file")
volume_fail :: proc(v: ^Volume, msg: string) {
	if v.on_fail != nil {
		v.on_fail(v.fail_ctx, msg)
	}
}
