// SPDX-License-Identifier: GPL-3.0-only
package fat32

import disk "../disk"
import "base:runtime"
import "core:log"
import "core:strings"

Volume :: struct {
	allocator:      runtime.Allocator,
	alloc:          Allocation,
	root_dir:       string,
	journal:        Journal,
	io_sys_lba:     u64, // absolute LBA of IO.SYS first sector, 0 if absent
	io_sys_cluster: u32, // first cluster of IO.SYS, 0 if absent
	frozen:         bool,
	on_fail:        proc(ctx: rawptr, msg: string),
	fail_ctx:       rawptr,
}

volume_open :: proc(path: string, volume_mb: u32) -> ^Volume {
	allocator := context.allocator
	root := scan_tree(path, allocator)
	if root == nil {
		return nil
	}
	geo := geometry_make(volume_mb)
	a := allocate(root, geo, allocator)
	if a.next_free > geo.cluster_count + 2 {
		allocation_destroy(&a, allocator)
		return nil // host tree does not fit the volume
	}
	v := new(Volume, allocator)
	v.allocator = allocator
	v.alloc = a
	v.root_dir = root.host_path
	journal_init(&v.journal, allocator)
	reconcile_seed(v)
	for child in root.children {
		if !child.is_dir && child.first_cluster != 0 && strings.equal_fold(child.name, "IO.SYS") {
			v.io_sys_lba = u64(PART_START_LBA) + u64(cluster_to_lba(&geo, child.first_cluster))
			v.io_sys_cluster = child.first_cluster
			break
		}
	}
	if v.io_sys_lba == 0 {
		log.errorf(
			"fat32: IO.SYS not found in %s; VBR keeps the int 18h stub and the guest cannot boot from C:",
			path,
		)
	}
	return v
}

volume_close :: proc(v: ^Volume) -> bool {
	if v == nil {return true}
	if !volume_reconcile(v) {return false}
	volume_discard(v)
	return true
}

// Explicitly abandons any staged guest writes retained after a failed close.
volume_discard :: proc(v: ^Volume) {
	if v == nil {return}
	allocator := v.allocator
	journal_destroy(&v.journal, allocator)
	allocation_destroy(&v.alloc, allocator)
	free(v, allocator)
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
			return volume_stage_write((^Volume)(ctx), lba, buf)
		},
		flush = proc(ctx: rawptr) -> bool {
			return volume_reconcile((^Volume)(ctx))
		},
	}
}
