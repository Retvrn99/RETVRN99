// SPDX-License-Identifier: GPL-3.0-only
package fat32

import "core:fmt"

Protected_Write_Decision :: enum {
	Allow,
	Ignore,
	Reject,
}

protected_system_disk_write_policy :: proc(
	v: ^Volume,
	lba: u64,
	sec: []u8,
) -> Protected_Write_Decision {
	geo := &v.alloc.geo
	if lba == 0 {
		if protected_mbr_layout_compatible(geo, sec) {return .Ignore}
		volume_fail(v, "protected system disk rejected partition/MBR layout replacement")
		return .Reject
	}
	if lba < PART_START_LBA {
		volume_fail(
			v,
			fmt.tprintf("protected system disk rejected partition/MBR write at LBA %d", lba),
		)
		return .Reject
	}
	rel64 := lba - PART_START_LBA
	if rel64 >= u64(geo.total_sectors) {
		volume_fail(
			v,
			fmt.tprintf("protected system disk rejected out-of-range write at LBA %d", lba),
		)
		return .Reject
	}
	rel := u32(rel64)
	if rel == 0 || rel == 6 {
		if protected_vbr_layout_compatible(geo, sec) {return .Ignore}
		volume_fail(
			v,
			fmt.tprintf("protected system disk rejected volume layout write at LBA %d", lba),
		)
		return .Reject
	}
	if rel < geo.fat_start {
		if rel == 2 || rel == 8 {
			return .Ignore
		}
		if rel != 1 && rel != 7 {
			volume_fail(
				v,
				fmt.tprintf("protected system disk rejected reserved layout write at LBA %d", lba),
			)
			return .Reject
		}
		if !protected_fsinfo_write(sec) {
			volume_fail(
				v,
				fmt.tprintf(
					"protected system disk rejected FSInfo layout replacement at LBA %d",
					lba,
				),
			)
			return .Reject
		}
		return .Allow
	}
	if rel < geo.data_start {
		return protected_fat_write_policy(v, lba, rel, sec)
	}
	if protected_directory_layout_replacement(v, rel, sec) {
		volume_fail(
			v,
			fmt.tprintf(
				"protected system disk rejected directory layout replacement at LBA %d",
				lba,
			),
		)
		return .Reject
	}
	return .Allow
}

@(private = "file")
protected_mbr_layout_compatible :: proc(geo: ^Geometry, sec: []u8) -> bool {
	if len(sec) != SECTOR {return false}
	want := make_mbr(geo.total_sectors)
	for i in 446 ..< SECTOR {
		if sec[i] != want[i] {return false}
	}
	return true
}

@(private = "file")
protected_vbr_layout_compatible :: proc(geo: ^Geometry, sec: []u8) -> bool {
	if len(sec) != SECTOR || sec[510] != 0x55 || sec[511] != 0xAA {return false}
	want := make_vbr(geo, geo.total_sectors)
	for i in 11 ..< 64 {
		if sec[i] != want[i] {return false}
	}
	return true
}

@(private = "file")
protected_fsinfo_write :: proc(sec: []u8) -> bool {
	want := make_fsinfo()
	for i in 0 ..< SECTOR {
		if i >= 488 && i < 496 {
			continue
		}
		if sec[i] != want[i] {
			return false
		}
	}
	return true
}

@(private = "file")
protected_fat_write_policy :: proc(
	v: ^Volume,
	lba: u64,
	rel: u32,
	sec: []u8,
) -> Protected_Write_Decision {
	geo := &v.alloc.geo
	index := (rel - geo.fat_start) % geo.sectors_per_fat
	base := index * 128
	if base == 0 {
		media := protected_rd32(sec, 0) & 0x0FFFFFFF
		status := protected_rd32(sec, 4) & 0x0FFFFFFF
		root := protected_rd32(sec, 8) & 0x0FFFFFFF
		if media != 0x0FFFFFF8 ||
		   status & 0x03FFFFFF != 0x03FFFFFF ||
		   !protected_fat_link_valid(geo, root) {
			volume_fail(
				v,
				fmt.tprintf(
					"protected system disk rejected FAT layout replacement at LBA %d",
					lba,
				),
			)
			return .Reject
		}
	}
	return .Allow
}

@(private = "file")
protected_fat_link_valid :: proc(geo: ^Geometry, link: u32) -> bool {
	if link >= 0x0FFFFFF8 {
		return true
	}
	return link >= 2 && link < geo.cluster_count + 2
}

@(private = "file")
protected_cluster_owner :: proc(v: ^Volume, cluster: u32) -> ^Node {
	if claim, ok := v.journal.claimed[cluster]; ok {
		return claim.node
	}
	if cluster < u32(len(v.alloc.by_cluster)) {
		return v.alloc.by_cluster[cluster]
	}
	return nil
}

@(private = "file")
protected_directory_layout_replacement :: proc(v: ^Volume, rel: u32, sec: []u8) -> bool {
	geo := &v.alloc.geo
	di := rel - geo.data_start
	cluster := di / SECTORS_PER_CLUSTER + 2
	soff := di % SECTORS_PER_CLUSTER
	node := protected_cluster_owner(v, cluster)
	if node == nil || node != v.alloc.root || !protected_fresh_directory_sector(sec) {
		return false
	}
	old: [SECTOR]u8
	if overlay, overlay_ok := v.journal.overlay[rel]; overlay_ok {
		copy(old[:], overlay)
	} else {
		index: u32
		if claim, claim_ok := v.journal.claimed[cluster]; claim_ok {
			index = claim.index
		} else if cluster >= node.first_cluster &&
		   cluster < node.first_cluster + node.cluster_len {
			index = cluster - node.first_cluster
		} else {
			return false
		}
		tmp: [CLUSTER_BYTES]u8
		dir_cluster_data(&v.alloc, node, index, tmp[:])
		copy(old[:], tmp[int(soff) * SECTOR:][:SECTOR])
	}
	return protected_directory_sector_has_entries(old[:])
}

@(private = "file")
protected_fresh_directory_sector :: proc(sec: []u8) -> bool {
	for off := 0; off < SECTOR; off += 32 {
		if sec[off] == 0 {
			return true
		}
		if sec[off] == 0xE5 || sec[off + 11] != 0x08 {
			return false
		}
	}
	return true
}

@(private = "file")
protected_directory_sector_has_entries :: proc(sec: []u8) -> bool {
	for off := 0; off < SECTOR; off += 32 {
		if sec[off] == 0 {
			return false
		}
		if sec[off] != 0xE5 {
			return true
		}
	}
	return false
}

@(private = "file")
protected_rd32 :: proc(b: []u8, off: int) -> u32 {
	return u32(b[off]) | u32(b[off + 1]) << 8 | u32(b[off + 2]) << 16 | u32(b[off + 3]) << 24
}
