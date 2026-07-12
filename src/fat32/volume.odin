// SPDX-License-Identifier: GPL-3.0-only
package fat32

import "core:log"
import "core:strings"
import disk "../disk"

Volume :: struct {
	alloc:      Allocation,
	root_dir:   string,
	journal:    Journal,
	io_sys_lba: u64, // absolute LBA of IO.SYS first sector, 0 if absent
	frozen:     bool,
	on_fail:    proc(ctx: rawptr, msg: string),
	fail_ctx:   rawptr,
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
	journal_init(&v.journal)
	for child in root.children {
		if !child.is_dir && child.first_cluster != 0 && strings.equal_fold(child.name, "IO.SYS") {
			v.io_sys_lba = u64(PART_START_LBA) + u64(cluster_to_lba(&geo, child.first_cluster))
			break
		}
	}
	if v.io_sys_lba == 0 {
		log.errorf("fat32: IO.SYS not found in %s; VBR keeps the int 18h stub and the guest cannot boot from C:", path)
	}
	return v
}

// freeze writes and notify the host; reads keep working
volume_fail :: proc(v: ^Volume, msg: string) {
	v.frozen = true
	if v.on_fail != nil {
		v.on_fail(v.fail_ctx, msg)
	}
}

volume_block_device :: proc(v: ^Volume) -> disk.Block_Device {
	return disk.Block_Device {
		ctx = v,
		sector_count = u64(PART_START_LBA) + u64(v.alloc.geo.total_sectors),
		read = proc(ctx: rawptr, lba: u64, buf: []u8) -> bool {
			return volume_read((^Volume)(ctx), lba, buf)
		},
		write = proc(ctx: rawptr, lba: u64, buf: []u8) -> bool {
			return volume_write((^Volume)(ctx), lba, buf)
		},
	}
}
