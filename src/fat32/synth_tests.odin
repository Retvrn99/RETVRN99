// SPDX-License-Identifier: GPL-3.0-only
package fat32

import "core:os"
import "core:testing"

synth_rd16 :: proc(b: []u8, off: int) -> u16 {
	return u16(b[off]) | u16(b[off + 1]) << 8
}

synth_rd32 :: proc(b: []u8, off: int) -> u32 {
	return u32(b[off]) | u32(b[off + 1]) << 8 | u32(b[off + 2]) << 16 | u32(b[off + 3]) << 24
}

// minimal 32-byte short-entry parser
synth_check_entry :: proc(t: ^testing.T, e: []u8, name: string, attr: u8, cluster: u32, size: u32, loc := #caller_location) {
	testing.expect(t, string(e[0:11]) == name, loc = loc)
	testing.expect_value(t, e[11], attr, loc = loc)
	got_cluster := u32(synth_rd16(e, 20)) << 16 | u32(synth_rd16(e, 26))
	testing.expect_value(t, got_cluster, cluster, loc = loc)
	testing.expect_value(t, synth_rd32(e, 28), size, loc = loc)
}

// decode the UCS-2 chars of one LFN entry (ASCII fixture names only)
synth_lfn_text :: proc(e: []u8, allocator := context.allocator) -> string {
	offs := [13]int{1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30}
	out := make([dynamic]u8, allocator)
	for off in offs {
		v := u16(e[off]) | u16(e[off + 1]) << 8
		if v == 0 || v == 0xFFFF {
			break
		}
		append(&out, u8(v))
	}
	return string(out[:])
}

@(test)
synth_test_fat_entry :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	node: Node
	node.first_cluster = 3
	node.cluster_len = 3
	a: Allocation
	a.by_cluster = make([]^Node, 16)
	for c in u32(3) ..< u32(6) {
		a.by_cluster[c] = &node
	}

	testing.expect_value(t, fat_entry(&a, 0), u32(0x0FFFFFF8)) // media
	testing.expect_value(t, fat_entry(&a, 1), u32(0x0FFFFFFF))
	testing.expect_value(t, fat_entry(&a, 2), u32(0)) // free
	testing.expect_value(t, fat_entry(&a, 3), u32(4))
	testing.expect_value(t, fat_entry(&a, 4), u32(5)) // middle of chain -> next
	testing.expect_value(t, fat_entry(&a, 5), u32(0x0FFFFFFF)) // last -> EOC
	testing.expect_value(t, fat_entry(&a, 9), u32(0))
	testing.expect_value(t, fat_entry(&a, 999), u32(0)) // beyond by_cluster -> free

	sec: [512]u8
	fat_sector(&a, 0, sec[:])
	testing.expect_value(t, synth_rd32(sec[:], 0), u32(0x0FFFFFF8))
	testing.expect_value(t, synth_rd32(sec[:], 4), u32(0x0FFFFFFF))
	testing.expect_value(t, synth_rd32(sec[:], 3 * 4), u32(4))
	testing.expect_value(t, synth_rd32(sec[:], 5 * 4), u32(0x0FFFFFFF))
	testing.expect_value(t, synth_rd32(sec[:], 6 * 4), u32(0))
}

@(test)
synth_test_names_lfn :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root: Node
	root.is_dir = true
	root.first_cluster = 2
	root.cluster_len = 1
	io: Node
	io.name = "IO.SYS"
	io.size = 5000
	io.first_cluster = 3
	io.cluster_len = 2
	io.parent = &root
	pf: Node
	pf.name = "Program Files"
	pf.is_dir = true
	pf.first_cluster = 5
	pf.cluster_len = 1
	pf.parent = &root
	append(&root.children, &io, &pf)

	a: Allocation
	buf: [CLUSTER_BYTES]u8
	dir_cluster_data(&a, &root, 0, buf[:])

	// entry 0: valid 8.3, no LFN
	synth_check_entry(t, buf[0:32], "IO      SYS", 0x20, 3, 5000)
	// entry 1: single LFN entry ("Program Files" is exactly 13 chars)
	testing.expect_value(t, buf[32], u8(0x41)) // seq 1 | last flag
	testing.expect_value(t, buf[32 + 11], u8(0x0F))
	testing.expect_value(t, synth_rd16(buf[:], 32 + 26), u16(0))
	testing.expect(t, synth_lfn_text(buf[32:64]) == "Program Files")
	// entry 2: generated short name with numeric tail
	synth_check_entry(t, buf[64:96], "PROGRA~1   ", 0x10, 5, 0)
	short: [11]u8
	copy(short[:], buf[64:75])
	testing.expect_value(t, buf[32 + 13], lfn_checksum(short))
	testing.expect_value(t, buf[96], u8(0)) // end of directory
}

@(test)
synth_test_name_collision :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root: Node
	root.is_dir = true
	d1: Node
	d1.name = "Program Data"
	d1.is_dir = true
	d1.parent = &root
	d2: Node
	d2.name = "Program Files"
	d2.is_dir = true
	d2.parent = &root
	append(&root.children, &d1, &d2)

	names := dir_short_names(&root)
	testing.expect(t, string(names[0][:]) == "PROGRA~1   ")
	testing.expect(t, string(names[1][:]) == "PROGRA~2   ")
}

@(test)
synth_test_root_dir_fixture :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := fat32_test_fixture(t)
	defer os.remove_all(dir)
	root := scan_tree(dir)
	testing.expect(t, root != nil)
	if root == nil {
		return
	}
	geo := geometry_make(2048)
	a := allocate(root, geo)

	buf: [CLUSTER_BYTES]u8
	dir_cluster_data(&a, root, 0, buf[:])

	command := root.children[0]
	dos := root.children[1]
	io := root.children[2]
	synth_check_entry(t, buf[0:32], "COMMAND COM", 0x20, command.first_cluster, 2000)
	synth_check_entry(t, buf[32:64], "DOS        ", 0x10, dos.first_cluster, 0)
	synth_check_entry(t, buf[64:96], "IO      SYS", 0x20, io.first_cluster, 5000)
	testing.expect(t, synth_rd16(buf[:], 24) != 0) // write date encoded from mtime
	testing.expect_value(t, buf[96], u8(0))

	// subdir gets . and .. first; .. cluster 0 because parent is root
	sub: [CLUSTER_BYTES]u8
	dir_cluster_data(&a, dos, 0, sub[:])
	synth_check_entry(t, sub[0:32], ".          ", 0x10, dos.first_cluster, 0)
	synth_check_entry(t, sub[32:64], "..         ", 0x10, 0, 0)
	hlp := dos.children[0]
	synth_check_entry(t, sub[64:96], "EDIT    HLP", 0x20, hlp.first_cluster, 100)

	// past the directory content: zeros
	dir_cluster_data(&a, root, 1, buf[:])
	testing.expect_value(t, buf[0], u8(0))
}
