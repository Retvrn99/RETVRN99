// SPDX-License-Identifier: GPL-3.0-only
package fat32

import disk "../disk"

// Placeholder; Task 19 fills it with the write journal.
Journal :: struct {}

Volume :: struct {
	alloc:    Allocation,
	root_dir: string,
	journal:  Journal, // Task 19; empty for now
	frozen:   bool,
	on_fail:  proc(ctx: rawptr, msg: string),
	fail_ctx: rawptr,
}

volume_open :: proc(path: string, volume_mb: u32) -> ^Volume {
	root := scan_tree(path)
	if root == nil {
		return nil
	}
	geo := geometry_make(volume_mb)
	a := allocate(root, geo)
	if a.next_free > geo.cluster_count + 2 {
		return nil // host tree does not fit the volume
	}
	v := new(Volume)
	v.alloc = a
	v.root_dir = root.host_path
	return v
}

volume_block_device :: proc(v: ^Volume) -> disk.Block_Device {
	return disk.Block_Device {
		ctx = v,
		sector_count = u64(PART_START_LBA) + u64(v.alloc.geo.total_sectors),
		read = proc(ctx: rawptr, lba: u64, buf: []u8) -> bool {
			return volume_read((^Volume)(ctx), lba, buf)
		},
		write = proc(ctx: rawptr, lba: u64, buf: []u8) -> bool {
			return false // writes land with the Task 19 journal
		},
	}
}
