// SPDX-License-Identifier: GPL-3.0-only
package fat32

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:testing"

// write a 32-byte short entry into a directory sector buffer
decode_test_put_entry :: proc(
	sec: []u8,
	off: int,
	name: string,
	attr: u8,
	cluster: u32,
	size: u32,
) {
	e := sec[off:][:32]
	for i in 0 ..< 32 {
		e[i] = 0
	}
	copy(e[:11], name)
	e[11] = attr
	e[20] = u8(cluster >> 16)
	e[21] = u8(cluster >> 24)
	e[26] = u8(cluster)
	e[27] = u8(cluster >> 8)
	e[28] = u8(size)
	e[29] = u8(size >> 8)
	e[30] = u8(size >> 16)
	e[31] = u8(size >> 24)
}

// mark a guest FAT entry through the port-level write path
decode_test_fat_set :: proc(t: ^testing.T, v: ^Volume, cluster: u32, val: u32) {
	lba := journal_test_fat_lba(v, cluster)
	sec := read_test_sector(t, v, lba)
	off := int(cluster % 128) * 4
	sec[off] = u8(val)
	sec[off + 1] = u8(val >> 8)
	sec[off + 2] = u8(val >> 16)
	sec[off + 3] = u8(val >> 24)
	testing.expect(t, volume_write(v, lba, sec[:]))
}

decode_test_open :: proc(t: ^testing.T) -> (dir: string, v: ^Volume) {
	dir = fat32_test_fixture(t)
	v = volume_open(dir, 2048)
	testing.expect(t, v != nil)
	return
}

@(test)
decode_test_create_file :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {
		return
	}
	fc := v.alloc.next_free
	// guest sequence: FAT chain, data cluster, then the dir entry
	decode_test_fat_set(t, v, fc, 0x0FFFFFFF)
	data: [SECTOR]u8
	copy(data[:], "HELLO12345")
	testing.expect(t, volume_write(v, journal_test_data_lba(v, fc), data[:]))
	root_lba := journal_test_data_lba(v, 2)
	sec := read_test_sector(t, v, root_lba)
	decode_test_put_entry(sec[:], 96, "HELLO   TXT", ATTR_FILE, fc, 10)
	testing.expect(t, volume_write(v, root_lba, sec[:]))

	p, _ := filepath.join({dir, "HELLO.TXT"})
	host, herr := os.read_entire_file(p, context.allocator)
	testing.expect(t, herr == nil)
	testing.expect(t, string(host) == "HELLO12345")
	testing.expect(t, !v.frozen)
}

@(test)
decode_test_delete_file :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {
		return
	}
	p, _ := filepath.join({dir, "IO.SYS"})
	testing.expect(t, os.exists(p))

	io := v.alloc.root.children[2] // IO.SYS, clusters 6-7
	root_lba := journal_test_data_lba(v, 2)
	sec := read_test_sector(t, v, root_lba)
	testing.expect(t, string(sec[64:75]) == "IO      SYS")
	sec[64] = 0xE5
	testing.expect(t, volume_write(v, root_lba, sec[:]))
	// chain still allocated: the E5 may be the first half of a move
	testing.expect(t, os.exists(p))
	testing.expect(t, volume_flush(v))
	testing.expect(t, os.exists(p))
	// freeing the chain commits the delete
	fc := io.first_cluster
	decode_test_fat_set(t, v, fc + 1, 0)
	decode_test_fat_set(t, v, fc, 0)
	testing.expect(t, !os.exists(p))
	testing.expect(t, !v.frozen)
	testing.expect_value(t, len(v.alloc.root.children), 2)
}

@(test)
decode_test_grow_file :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {
		return
	}
	command := v.alloc.root.children[0] // COMMAND.COM, 2000 bytes
	sec: [SECTOR]u8
	for i in 0 ..< SECTOR {
		sec[i] = 0xAB
	}
	// data past EOF first, then the dir entry confirms size 2100
	testing.expect(t, volume_write(v, journal_test_data_lba(v, command.first_cluster) + 3, sec[:]))
	testing.expect(t, orphan_has(v, command.first_cluster))
	root_lba := journal_test_data_lba(v, 2)
	dsec := read_test_sector(t, v, root_lba)
	testing.expect(t, string(dsec[0:11]) == "COMMAND COM")
	dsec[28] = u8(2100 & 0xFF)
	dsec[29] = u8(2100 >> 8)
	testing.expect(t, volume_write(v, root_lba, dsec[:]))

	host, herr := os.read_entire_file(command.host_path, context.allocator)
	testing.expect(t, herr == nil)
	testing.expect_value(t, len(host), 2100)
	testing.expect_value(t, host[1536], u8(0xAB))
	testing.expect_value(t, host[1999], u8(0xAB))
	testing.expect_value(t, host[2000], u8(0xAB)) // flushed orphan tail
	testing.expect_value(t, host[2047], u8(0xAB))
	testing.expect_value(t, host[2048], u8(0)) // beyond the written sector
	testing.expect_value(t, command.size, u64(2100))
	testing.expect(t, !v.frozen)
}

@(test)
decode_test_rename_file :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {
		return
	}
	command := v.alloc.root.children[0]
	original, _ := os.read_entire_file(command.host_path, context.allocator)

	// delete + create with the same first cluster in one write
	root_lba := journal_test_data_lba(v, 2)
	sec := read_test_sector(t, v, root_lba)
	testing.expect(t, string(sec[0:11]) == "COMMAND COM")
	sec[0] = 0xE5
	decode_test_put_entry(
		sec[:],
		96,
		"RENAMED COM",
		ATTR_FILE,
		command.first_cluster,
		u32(command.size),
	)
	testing.expect(t, volume_write(v, root_lba, sec[:]))
	testing.expect(t, volume_flush(v))

	old_p, _ := filepath.join({dir, "COMMAND.COM"})
	new_p, _ := filepath.join({dir, "RENAMED.COM"})
	testing.expect(t, !os.exists(old_p))
	renamed, herr := os.read_entire_file(new_p, context.allocator)
	testing.expect(t, herr == nil)
	testing.expect(t, string(renamed) == string(original)) // content preserved
	testing.expect(t, command.name == "RENAMED.COM")
	testing.expect(t, !v.frozen)
}

@(test)
decode_test_defrag_freezes :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {
		return
	}
	fired := false
	journal_test_arm_on_fail(v, &fired)

	// move IO.SYS's first cluster: unmappable, must freeze
	root_lba := journal_test_data_lba(v, 2)
	sec := read_test_sector(t, v, root_lba)
	testing.expect(t, string(sec[64:75]) == "IO      SYS")
	nc := v.alloc.next_free
	sec[64 + 26] = u8(nc)
	sec[64 + 27] = u8(nc >> 8)
	sec[64 + 20] = u8(nc >> 16)
	sec[64 + 21] = u8(nc >> 24)
	testing.expect(t, !volume_write(v, root_lba, sec[:]))
	testing.expect(t, fired)
	testing.expect(t, v.frozen)

	// writes stay frozen, reads keep working
	other: [SECTOR]u8
	testing.expect(t, !volume_write(v, u64(PART_START_LBA) + 2, other[:]))
	mbr := read_test_sector(t, v, 0)
	testing.expect_value(t, mbr[510], u8(0x55))
	p, _ := filepath.join({dir, "IO.SYS"})
	testing.expect(t, os.exists(p)) // host untouched
}

@(test)
decode_test_setup_replaces_freed_file_chain :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := fat32_test_fixture(t)
	defer os.remove_all(dir)
	install, _ := filepath.join({dir, "WININST0.400"})
	lz_path, _ := filepath.join({install, "LZEXPAND.DLL"})
	testing.expect(t, os.make_directory(install) == nil)
	old_data := make([]u8, 9936)
	for &b in old_data {b = 0x5A}
	testing.expect(t, os.write_entire_file(lz_path, old_data) == nil)

	v := volume_open(dir, 2048)
	testing.expect(t, v != nil)
	if v == nil {return}
	defer volume_discard(v)
	install_node: ^Node
	for child in v.alloc.root.children {
		if child.name == "WININST0.400" {install_node = child}
	}
	testing.expect(t, install_node != nil)
	if install_node == nil || len(install_node.children) != 1 {return}
	lz := install_node.children[0]
	testing.expect_value(t, lz.size, u64(9936))
	old_first, old_len := lz.first_cluster, lz.cluster_len

	decode_test_fat_set(t, v, old_first, 0)
	new_first: u32 = 33219
	new_clusters: u32 = 6
	for i in u32(0) ..< new_clusters {
		next := i + 1 == new_clusters ? u32(0x0FFFFFFF) : new_first + i + 1
		decode_test_fat_set(t, v, new_first + i, next)
		data: [CLUSTER_BYTES]u8
		for &b in data {b = u8(0x30 + i)}
		testing.expect(t, volume_write(v, journal_test_data_lba(v, new_first + i), data[:]))
	}

	dir_lba := journal_test_data_lba(v, install_node.first_cluster)
	sec := read_test_sector(t, v, dir_lba)
	testing.expect(t, string(sec[64:75]) == "LZEXPANDDLL")
	new_size: u32 = 23696
	decode_test_put_entry(sec[:], 64, "LZEXPANDDLL", ATTR_FILE, new_first, new_size)
	testing.expect(t, volume_write(v, dir_lba, sec[:]))
	testing.expect(t, !v.frozen)
	testing.expect_value(t, lz.first_cluster, new_first)
	testing.expect_value(t, lz.cluster_len, new_clusters)
	testing.expect_value(t, lz.size, u64(new_size))
	for i in u32(0) ..< old_len {
		testing.expect(t, v.alloc.by_cluster[old_first + i] == nil)
	}
	for i in u32(0) ..< new_clusters {
		claim, ok := v.journal.claimed[new_first + i]
		testing.expect(t, ok && claim.node == lz && claim.index == i)
	}

	host, herr := os.read_entire_file(lz_path, context.temp_allocator)
	testing.expect(t, herr == nil)
	testing.expect_value(t, len(host), int(new_size))
	for i in u32(0) ..< new_clusters {
		base := int(i * CLUSTER_BYTES)
		if base >= len(host) {break}
		testing.expect_value(t, host[base], u8(0x30 + i))
		testing.expect_value(t, host[min(base + CLUSTER_BYTES, len(host)) - 1], u8(0x30 + i))
	}
	for i in u32(0) ..< new_clusters - 1 {
		testing.expect(t, !orphan_has(v, new_first + i))
	}
	testing.expect(t, orphan_has(v, new_first + new_clusters - 1))
	tail := read_test_sector(t, v, journal_test_data_lba(v, new_first + new_clusters - 1) + 7)
	testing.expect_value(t, tail[511], u8(0x35))
}

@(test)
decode_test_directory_entry_first_file_replacement :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {return}
	defer volume_discard(v)
	new_first := v.alloc.next_free
	old_first := new_first + 1
	decode_test_fat_set(t, v, old_first, 0x0FFFFFFF)
	old_data: [CLUSTER_BYTES]u8
	for &b in old_data {b = 0xA1}
	testing.expect(t, volume_write(v, journal_test_data_lba(v, old_first), old_data[:]))
	root_lba := journal_test_data_lba(v, 2)
	sec := read_test_sector(t, v, root_lba)
	decode_test_put_entry(sec[:], 96, "SUWARN  BAT", ATTR_FILE, old_first, 2000)
	testing.expect(t, volume_write(v, root_lba, sec[:]))
	suwarn := v.alloc.root.children[len(v.alloc.root.children) - 1]
	testing.expect(t, suwarn.name == "SUWARN.BAT")
	testing.expect(t, v.journal.claimed[old_first].node == suwarn)

	decode_test_fat_set(t, v, new_first, 0x0FFFFFFF)
	new_data: [CLUSTER_BYTES]u8
	for &b in new_data {b = 0xB2}
	testing.expect(t, volume_write(v, journal_test_data_lba(v, new_first), new_data[:]))
	decode_test_put_entry(sec[:], 96, "SUWARN  BAT", ATTR_FILE, new_first, u32(suwarn.size))
	testing.expect(t, volume_write(v, root_lba, sec[:]))

	testing.expect(t, !v.frozen)
	testing.expect(t, volume_fat_entry(v, old_first) & 0x0FFFFFFF >= 0x0FFFFFF8)
	testing.expect(t, v.alloc.by_cluster[old_first] == nil)
	_, old_claimed := v.journal.claimed[old_first]
	testing.expect(t, !old_claimed)
	testing.expect(t, v.journal.stale_clusters[old_first])
	stale := make([]u8, CLUSTER_BYTES)
	testing.expect(t, volume_read(v, journal_test_data_lba(v, old_first), stale))
	for b in stale {testing.expect_value(t, b, u8(0xA1))}
	host, herr := os.read_entire_file(suwarn.host_path, context.temp_allocator)
	testing.expect(t, herr == nil)
	testing.expect_value(t, len(host), int(suwarn.size))
	for b in host {testing.expect_value(t, b, u8(0xB2))}

	decode_test_fat_set(t, v, old_first, 0)
	testing.expect_value(t, volume_fat_entry(v, old_first) & 0x0FFFFFFF, u32(0))
	testing.expect(t, !v.journal.stale_clusters[old_first])
	testing.expect(t, !orphan_has(v, old_first))
	cleared := read_test_sector(t, v, journal_test_data_lba(v, old_first))
	testing.expect(t, read_test_all_zero(cleared[:]))
}

@(test)
decode_test_replacement_can_reuse_its_freed_tail :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {return}
	defer volume_discard(v)
	io := v.alloc.root.children[2]
	original, _ := os.read_entire_file(io.host_path, context.temp_allocator)
	old_first := io.first_cluster
	old_tail := old_first + 1
	decode_test_fat_set(t, v, old_first, 0)

	new_first := v.alloc.next_free
	decode_test_fat_set(t, v, new_first, old_tail)
	data: [CLUSTER_BYTES]u8
	for &b in data {b = 0xA6}
	testing.expect(t, volume_write(v, journal_test_data_lba(v, new_first), data[:]))
	root_lba := journal_test_data_lba(v, 2)
	sec := read_test_sector(t, v, root_lba)
	decode_test_put_entry(sec[:], 64, "IO      SYS", ATTR_FILE, new_first, CLUSTER_BYTES * 2)
	testing.expect(t, volume_write(v, root_lba, sec[:]))

	testing.expect(t, !v.frozen)
	result, rerr := os.read_entire_file(io.host_path, context.temp_allocator)
	testing.expect(t, rerr == nil)
	testing.expect_value(t, len(result), CLUSTER_BYTES * 2)
	testing.expect_value(t, result[0], u8(0xA6))
	testing.expect_value(t, result[CLUSTER_BYTES - 1], u8(0xA6))
	testing.expect(
		t,
		string(result[CLUSTER_BYTES:CLUSTER_BYTES + 904]) == string(original[CLUSTER_BYTES:]),
	)
	for b in result[CLUSTER_BYTES + 904:] {
		testing.expect_value(t, b, u8(0))
	}
	testing.expect(t, v.journal.claimed[new_first] == Claim{io, 0})
	testing.expect(t, v.journal.claimed[old_tail] == Claim{io, 1})
	chain, state := volume_chain_inspect(v, new_first, context.temp_allocator)
	testing.expect_value(t, state, Chain_State.Complete)
	testing.expect_value(t, len(chain), 2)
	if len(chain) == 2 {
		testing.expect_value(t, chain[0], new_first)
		testing.expect_value(t, chain[1], old_tail)
	}
}

@(test)
decode_test_directory_chain_replacement_freezes :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {return}
	defer volume_discard(v)
	dos := v.alloc.root.children[1]
	decode_test_fat_set(t, v, dos.first_cluster, 0)
	new_first := v.alloc.next_free
	decode_test_fat_set(t, v, new_first, 0x0FFFFFFF)
	root_lba := journal_test_data_lba(v, 2)
	sec := read_test_sector(t, v, root_lba)
	decode_test_put_entry(sec[:], 32, "DOS        ", ATTR_DIR, new_first, 0)
	testing.expect(t, !volume_write(v, root_lba, sec[:]))
	testing.expect(t, v.frozen)
	testing.expect(t, os.exists(dos.host_path))
}

@(test)
decode_test_invalid_replacement_chain_freezes :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {return}
	defer volume_discard(v)
	command := v.alloc.root.children[0]
	decode_test_fat_set(t, v, command.first_cluster, 0)
	new_first := v.alloc.next_free
	decode_test_fat_set(t, v, new_first, 0x0FFFFFF7)
	root_lba := journal_test_data_lba(v, 2)
	sec := read_test_sector(t, v, root_lba)
	decode_test_put_entry(sec[:], 0, "COMMAND COM", ATTR_FILE, new_first, u32(command.size))
	testing.expect(t, !volume_write(v, root_lba, sec[:]))
	testing.expect(t, v.frozen)
}

@(test)
decode_test_conflicting_replacement_chain_freezes :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {return}
	defer volume_discard(v)
	command := v.alloc.root.children[0]
	io := v.alloc.root.children[2]
	want, _ := os.read_entire_file(command.host_path, context.temp_allocator)
	root_lba := journal_test_data_lba(v, 2)
	sec := read_test_sector(t, v, root_lba)
	decode_test_put_entry(sec[:], 0, "COMMAND COM", ATTR_FILE, io.first_cluster, u32(command.size))
	testing.expect(t, !volume_write(v, root_lba, sec[:]))
	testing.expect(t, v.frozen)
	got, gerr := os.read_entire_file(command.host_path, context.temp_allocator)
	testing.expect(t, gerr == nil && string(got) == string(want))
}

@(test)
decode_test_mkdir :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {
		return
	}
	fc := v.alloc.next_free
	decode_test_fat_set(t, v, fc, 0x0FFFFFFF)
	// MD writes the dot cluster before the parent entry
	dots: [SECTOR]u8
	decode_test_put_entry(dots[:], 0, ".          ", ATTR_DIR, fc, 0)
	decode_test_put_entry(dots[:], 32, "..         ", ATTR_DIR, 0, 0)
	testing.expect(t, volume_write(v, journal_test_data_lba(v, fc), dots[:]))
	root_lba := journal_test_data_lba(v, 2)
	sec := read_test_sector(t, v, root_lba)
	decode_test_put_entry(sec[:], 96, "SUBDIR     ", ATTR_DIR, fc, 0)
	testing.expect(t, volume_write(v, root_lba, sec[:]))

	p, _ := filepath.join({dir, "SUBDIR"})
	info, serr := os.stat(p, context.allocator)
	testing.expect(t, serr == nil)
	testing.expect(t, info.type == .Directory)
	testing.expect(t, !v.frozen)

	// the dot sector reads back and later writes decode against the new dir
	back := read_test_sector(t, v, journal_test_data_lba(v, fc))
	testing.expect(t, back == dots)
	// create a file inside SUBDIR via a dir-cluster write
	fc2 := v.alloc.next_free + 1 // fc is taken by SUBDIR
	decode_test_fat_set(t, v, fc2, 0x0FFFFFFF)
	data: [SECTOR]u8
	copy(data[:], "NESTED")
	testing.expect(t, volume_write(v, journal_test_data_lba(v, fc2), data[:]))
	sub := back
	decode_test_put_entry(sub[:], 64, "INNER   TXT", ATTR_FILE, fc2, 6)
	testing.expect(t, volume_write(v, journal_test_data_lba(v, fc), sub[:]))
	ip, _ := filepath.join({p, "INNER.TXT"})
	inner, ierr := os.read_entire_file(ip, context.allocator)
	testing.expect(t, ierr == nil)
	testing.expect(t, string(inner) == "NESTED")
}

@(test)
decode_test_mkdir_waits_for_cross_sector_fat_chain :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {
		return
	}

	first := u32(130)
	tail := u32(260)
	decode_test_fat_set(t, v, first, tail)

	dots: [SECTOR]u8
	decode_test_put_entry(dots[:], 0, ".          ", ATTR_DIR, first, 0)
	decode_test_put_entry(dots[:], 32, "..         ", ATTR_DIR, 0, 0)
	testing.expect(t, volume_write(v, journal_test_data_lba(v, first), dots[:]))

	root_lba := journal_test_data_lba(v, 2)
	root: [SECTOR]u8
	testing.expect(t, volume_read(v, root_lba, root[:]))
	decode_test_put_entry(root[:], 96, "WININST0400", ATTR_DIR, first, 0)
	testing.expect(t, volume_write(v, root_lba, root[:]))
	testing.expect(t, !v.frozen)
	testing.expect_value(t, len(v.journal.pending_extends), 1)

	node := v.alloc.root.children[len(v.alloc.root.children) - 1]
	testing.expect(t, node.name == "WININST0.400")
	testing.expect_value(t, node.cluster_len, u32(0))
	testing.expect(t, os.exists(node.host_path))

	decode_test_fat_set(t, v, tail, 0x0FFFFFFF)
	testing.expect(t, !v.frozen)
	testing.expect_value(t, len(v.journal.pending_extends), 0)
	testing.expect_value(t, node.cluster_len, u32(2))
	testing.expect(t, v.journal.claimed[first].node == node)
	testing.expect(t, v.journal.claimed[tail].node == node)
	testing.expect(t, !orphan_has(v, first))
	back := read_test_sector(t, v, journal_test_data_lba(v, first))
	testing.expect(t, back == dots)
}

@(test)
decode_test_mkdir_waits_for_first_fat_entry :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {
		return
	}

	first := u32(130)
	dots: [SECTOR]u8
	decode_test_put_entry(dots[:], 0, ".          ", ATTR_DIR, first, 0)
	decode_test_put_entry(dots[:], 32, "..         ", ATTR_DIR, 0, 0)
	testing.expect(t, volume_write(v, journal_test_data_lba(v, first), dots[:]))

	root_lba := journal_test_data_lba(v, 2)
	root := read_test_sector(t, v, root_lba)
	decode_test_put_entry(root[:], 96, "WININST0400", ATTR_DIR, first, 0)
	testing.expect(t, volume_write(v, root_lba, root[:]))
	testing.expect(t, !v.frozen)
	testing.expect_value(t, len(v.journal.pending_extends), 1)

	node := v.alloc.root.children[len(v.alloc.root.children) - 1]
	testing.expect_value(t, node.cluster_len, u32(0))
	testing.expect(t, orphan_has(v, first))
	decode_test_fat_set(t, v, first, 0x0FFFFFFF)

	testing.expect(t, !v.frozen)
	testing.expect_value(t, len(v.journal.pending_extends), 0)
	testing.expect_value(t, node.cluster_len, u32(1))
	testing.expect(t, v.journal.claimed[first].node == node)
	testing.expect(t, !orphan_has(v, first))
	back := read_test_sector(t, v, journal_test_data_lba(v, first))
	testing.expect(t, back == dots)
}

@(test)
decode_test_delete_pending_dir_before_fat_allocation :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {
		return
	}

	first := u32(130)
	root_lba := journal_test_data_lba(v, 2)
	root := read_test_sector(t, v, root_lba)
	decode_test_put_entry(root[:], 96, "WININST0400", ATTR_DIR, first, 0)
	testing.expect(t, volume_write(v, root_lba, root[:]))
	testing.expect_value(t, len(v.journal.pending_extends), 1)

	node := v.alloc.root.children[len(v.alloc.root.children) - 1]
	testing.expect(t, v.journal.pending_extends[0] == node)
	host_path, _ := filepath.join({dir, "WININST0.400"})
	root[96] = 0xE5
	testing.expect(t, volume_write(v, root_lba, root[:]))
	testing.expect(t, !v.frozen)
	testing.expect_value(t, len(v.journal.pending_extends), 0)
	testing.expect(t, !os.exists(host_path))

	decode_test_fat_set(t, v, first, 0x0FFFFFFF)
	testing.expect(t, !v.frozen)
	testing.expect_value(t, len(v.journal.pending_extends), 0)
}

// build one LFN entry (ASCII names only)
decode_test_put_lfn :: proc(sec: []u8, off: int, seq: u8, last: bool, csum: u8, name: string) {
	e := sec[off:][:32]
	for i in 0 ..< 32 {
		e[i] = 0
	}
	e[0] = seq | (last ? 0x40 : 0)
	e[11] = ATTR_LFN
	e[13] = csum
	offs := [13]int{1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30}
	base := int(seq - 1) * 13
	for o, i in offs {
		u: u16 = 0xFFFF
		if base + i < len(name) {
			u = u16(name[base + i])
		} else if base + i == len(name) {
			u = 0
		}
		e[o] = u8(u)
		e[o + 1] = u8(u >> 8)
	}
}

// COPY /Y-style overwrite: free the chain, zero cluster+size in the dir
// entry (must NOT freeze), then recreate content in a fresh chain
@(test)
decode_test_truncate_overwrite :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {
		return
	}
	command := v.alloc.root.children[0] // COMMAND.COM, 2000 bytes
	fc := command.first_cluster

	decode_test_fat_set(t, v, fc, 0)
	root_lba := journal_test_data_lba(v, 2)
	sec := read_test_sector(t, v, root_lba)
	testing.expect(t, string(sec[0:11]) == "COMMAND COM")
	sec[20] = 0; sec[21] = 0; sec[26] = 0; sec[27] = 0 // first cluster = 0
	sec[28] = 0; sec[29] = 0; sec[30] = 0; sec[31] = 0 // size = 0
	testing.expect(t, volume_write(v, root_lba, sec[:]))
	testing.expect(t, !v.frozen)
	host, herr := os.read_entire_file(command.host_path, context.allocator)
	testing.expect(t, herr == nil)
	testing.expect_value(t, len(host), 0)
	testing.expect_value(t, command.first_cluster, u32(0))

	// re-populate: new chain, data, then the entry confirms cluster+size
	nc := v.alloc.next_free
	decode_test_fat_set(t, v, nc, 0x0FFFFFFF)
	data: [SECTOR]u8
	copy(data[:], "OVERWRITTEN")
	testing.expect(t, volume_write(v, journal_test_data_lba(v, nc), data[:]))
	sec[20] = u8(nc >> 16); sec[21] = u8(nc >> 24)
	sec[26] = u8(nc); sec[27] = u8(nc >> 8)
	sec[28] = 11
	testing.expect(t, volume_write(v, root_lba, sec[:]))
	testing.expect(t, !v.frozen)
	host2, herr2 := os.read_entire_file(command.host_path, context.allocator)
	testing.expect(t, herr2 == nil)
	testing.expect(t, string(host2) == "OVERWRITTEN")
}

// cross-directory move: E5 in one round, an unrelated dir write in
// between, create with the same first cluster later; the host file must
// be renamed, never deleted
@(test)
decode_test_move_across_dirs :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {
		return
	}
	command := v.alloc.root.children[0]
	dos := v.alloc.root.children[1]
	original, _ := os.read_entire_file(command.host_path, context.allocator)

	// round 1: source entry E5
	root_lba := journal_test_data_lba(v, 2)
	sec := read_test_sector(t, v, root_lba)
	testing.expect(t, string(sec[0:11]) == "COMMAND COM")
	sec[0] = 0xE5
	testing.expect(t, volume_write(v, root_lba, sec[:]))
	old_p, _ := filepath.join({dir, "COMMAND.COM"})
	testing.expect(t, os.exists(old_p))

	// round 2: an intervening write that decodes no create
	testing.expect(t, volume_write(v, root_lba, sec[:]))
	testing.expect(t, os.exists(old_p)) // chain still allocated: no delete

	// round 3: the entry reappears in DOS with the same first cluster
	dos_lba := journal_test_data_lba(v, dos.first_cluster)
	dsec := read_test_sector(t, v, dos_lba)
	decode_test_put_entry(
		dsec[:],
		96,
		"COMMAND COM",
		ATTR_FILE,
		command.first_cluster,
		u32(command.size),
	)
	testing.expect(t, volume_write(v, dos_lba, dsec[:]))

	testing.expect(t, !v.frozen)
	testing.expect(t, !os.exists(old_p))
	new_p, _ := filepath.join({dir, "DOS", "COMMAND.COM"})
	moved, herr := os.read_entire_file(new_p, context.allocator)
	testing.expect(t, herr == nil)
	testing.expect(t, string(moved) == string(original))
}

// DOS grows a directory by linking a fresh cluster into its FAT chain;
// entries written there must decode (FAT link first, then dir data)
@(test)
decode_test_dir_grow_fat_first :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {
		return
	}
	nc := v.alloc.next_free
	fc := nc + 1
	decode_test_fat_set(t, v, nc, 0x0FFFFFFF) // new tail cluster: EOC
	decode_test_fat_set(t, v, 2, nc) // root now chains 2 -> nc
	// file chain and content, then its entry inside the grown cluster
	decode_test_fat_set(t, v, fc, 0x0FFFFFFF)
	data: [SECTOR]u8
	copy(data[:], "GROWN")
	testing.expect(t, volume_write(v, journal_test_data_lba(v, fc), data[:]))
	gsec: [SECTOR]u8
	decode_test_put_entry(gsec[:], 0, "GROWN   TXT", ATTR_FILE, fc, 5)
	testing.expect(t, volume_write(v, journal_test_data_lba(v, nc), gsec[:]))

	testing.expect(t, !v.frozen)
	p, _ := filepath.join({dir, "GROWN.TXT"})
	host, herr := os.read_entire_file(p, context.allocator)
	testing.expect(t, herr == nil)
	testing.expect(t, string(host) == "GROWN")
}

// same growth, but the guest writes the entries before linking the FAT:
// the orphaned cluster must be adopted and decoded at link time
@(test)
decode_test_dir_grow_data_first :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {
		return
	}
	nc := v.alloc.next_free
	fc := nc + 1
	decode_test_fat_set(t, v, fc, 0x0FFFFFFF)
	data: [SECTOR]u8
	copy(data[:], "GROWN")
	testing.expect(t, volume_write(v, journal_test_data_lba(v, fc), data[:]))
	// dir entries land while the cluster is still an orphan
	gsec: [SECTOR]u8
	decode_test_put_entry(gsec[:], 0, "GROWN   TXT", ATTR_FILE, fc, 5)
	testing.expect(t, volume_write(v, journal_test_data_lba(v, nc), gsec[:]))
	testing.expect(t, orphan_has(v, nc))
	p, _ := filepath.join({dir, "GROWN.TXT"})
	testing.expect(t, !os.exists(p)) // not reachable from any dir yet
	// FAT link: adopt the cluster and decode its entries
	decode_test_fat_set(t, v, nc, 0x0FFFFFFF)
	decode_test_fat_set(t, v, 2, nc)

	testing.expect(t, !v.frozen)
	testing.expect(t, !orphan_has(v, nc))
	testing.expect(t, overlay_has(v, u32(journal_test_data_lba(v, nc) - PART_START_LBA)))
	host, herr := os.read_entire_file(p, context.allocator)
	testing.expect(t, herr == nil)
	testing.expect(t, string(host) == "GROWN")
}

// LFN create fully inside one sector: the host file gets the long name
@(test)
decode_test_lfn_create :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {
		return
	}
	fc := v.alloc.next_free
	decode_test_fat_set(t, v, fc, 0x0FFFFFFF)
	data: [SECTOR]u8
	copy(data[:], "LONGNAME")
	testing.expect(t, volume_write(v, journal_test_data_lba(v, fc), data[:]))

	name := "LongFileName.txt"
	short: [11]u8
	copy(short[:], "LONGFI~1TXT")
	csum := lfn_checksum(short)
	root_lba := journal_test_data_lba(v, 2)
	sec := read_test_sector(t, v, root_lba)
	decode_test_put_lfn(sec[:], 96, 2, true, csum, name)
	decode_test_put_lfn(sec[:], 128, 1, false, csum, name)
	decode_test_put_entry(sec[:], 160, "LONGFI~1TXT", ATTR_FILE, fc, 8)
	testing.expect(t, volume_write(v, root_lba, sec[:]))

	testing.expect(t, !v.frozen)
	p, _ := filepath.join({dir, "LongFileName.txt"})
	host, herr := os.read_entire_file(p, context.allocator)
	testing.expect(t, herr == nil)
	testing.expect(t, string(host) == "LONGNAME")
}

// LFN entries at the end of one sector, short entry at the start of the
// next: the long name must survive the boundary
@(test)
decode_test_lfn_straddle :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {
		return
	}
	fc := v.alloc.next_free
	decode_test_fat_set(t, v, fc, 0x0FFFFFFF)
	data: [SECTOR]u8
	copy(data[:], "STRADDLE")
	testing.expect(t, volume_write(v, journal_test_data_lba(v, fc), data[:]))

	name := "LongFileName.txt"
	short: [11]u8
	copy(short[:], "LONGFI~1TXT")
	csum := lfn_checksum(short)
	root_lba := journal_test_data_lba(v, 2)
	sec := read_test_sector(t, v, root_lba)
	// fill sector 0 up to the LFN pair so no terminator precedes it
	fill := 0
	for off := 96; off < SECTOR - 64; off += 32 {
		decode_test_put_entry(sec[:], off, fmt.tprintf("FILL%04d   ", fill), ATTR_FILE, 0, 0)
		fill += 1
	}
	decode_test_put_lfn(sec[:], SECTOR - 64, 2, true, csum, name)
	decode_test_put_lfn(sec[:], SECTOR - 32, 1, false, csum, name)
	testing.expect(t, volume_write(v, root_lba, sec[:]))
	// short entry begins the next sector
	sec2 := read_test_sector(t, v, root_lba + 1)
	decode_test_put_entry(sec2[:], 0, "LONGFI~1TXT", ATTR_FILE, fc, 8)
	testing.expect(t, volume_write(v, root_lba + 1, sec2[:]))

	testing.expect(t, !v.frozen)
	p, _ := filepath.join({dir, "LongFileName.txt"})
	host, herr := os.read_entire_file(p, context.allocator)
	testing.expect(t, herr == nil)
	testing.expect(t, string(host) == "STRADDLE")
}

// content of a fully confirmed create must not stay pinned in orphan_data
@(test)
decode_test_orphan_released :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {
		return
	}
	fc := v.alloc.next_free
	decode_test_fat_set(t, v, fc, 0x0FFFFFFF)
	data: [CLUSTER_BYTES]u8
	for i in 0 ..< CLUSTER_BYTES {
		data[i] = u8(i)
	}
	testing.expect(t, volume_write(v, journal_test_data_lba(v, fc), data[:]))
	testing.expect(t, orphan_has(v, fc))
	root_lba := journal_test_data_lba(v, 2)
	sec := read_test_sector(t, v, root_lba)
	decode_test_put_entry(sec[:], 96, "BIG     BIN", ATTR_FILE, fc, CLUSTER_BYTES)
	testing.expect(t, volume_write(v, root_lba, sec[:]))

	testing.expect(t, !orphan_has(v, fc)) // flushed to the host
	p, _ := filepath.join({dir, "BIG.BIN"})
	host, herr := os.read_entire_file(p, context.allocator)
	testing.expect(t, herr == nil)
	testing.expect_value(t, len(host), CLUSTER_BYTES)
	testing.expect_value(t, host[4095], u8(0xFF))
}
