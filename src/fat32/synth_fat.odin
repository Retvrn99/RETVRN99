// SPDX-License-Identifier: GPL-3.0-only
package fat32

// FAT sectors are pure functions of the allocation
fat_entry :: proc(a: ^Allocation, cluster: u32) -> u32 {
	if cluster == 0 {
		return 0x0FFFFFF8 // media
	}
	if cluster == 1 {
		return 0x0FFFFFFF
	}
	node := cluster < u32(len(a.by_cluster)) ? a.by_cluster[cluster] : nil
	if node == nil {
		return 0 // free
	}
	last := node.first_cluster + node.cluster_len - 1
	return cluster == last ? 0x0FFFFFFF : cluster + 1 // contiguous chain
}

// 128 little-endian entries per sector
fat_sector :: proc(a: ^Allocation, index: u32, out: []u8) {
	for i in u32(0) ..< 128 {
		e := fat_entry(a, index * 128 + i)
		off := int(i) * 4
		out[off] = u8(e)
		out[off + 1] = u8(e >> 8)
		out[off + 2] = u8(e >> 16)
		out[off + 3] = u8(e >> 24)
	}
}
