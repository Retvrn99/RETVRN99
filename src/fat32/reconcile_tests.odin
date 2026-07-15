// SPDX-License-Identifier: GPL-3.0-only
package fat32

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
reconcile_test_incomplete_chain_is_retryable_but_invalid_chain_freezes :: proc(t: ^testing.T) {
	v: Volume
	reconcile_chain_issue(&v, "BOOTLOG.PRV", .Incomplete, 12, false)
	testing.expect(t, !v.frozen)
	reconcile_chain_issue(&v, "BOOTLOG.PRV", .Invalid, 12, false)
	testing.expect(t, v.frozen)
}

@(test)
reconcile_test_duplicate_chain_is_held :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {return}
	defer volume_discard(v)
	command := v.alloc.root.children[0]
	io := v.alloc.root.children[2]
	want, _ := os.read_entire_file(command.host_path, context.temp_allocator)
	root_lba := journal_test_data_lba(v, 2)
	sector := read_test_sector(t, v, root_lba)
	decode_test_put_entry(sector[:], 0, "COMMAND COM", ATTR_FILE, io.first_cluster, u32(io.size))

	testing.expect(t, volume_stage_write(v, root_lba, sector[:]))
	testing.expect(t, volume_reconcile(v))
	testing.expect(t, !v.frozen)
	got, err := os.read_entire_file(command.host_path, context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect(t, string(got) == string(want))
}

@(test)
reconcile_test_dirty_generation_streams_only_newly_touched_file :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {return}
	defer volume_discard(v)
	command := reconcile_test_child_named(v.alloc.root, "COMMAND.COM")
	io := reconcile_test_child_named(v.alloc.root, "IO.SYS")
	if !testing.expect(t, command != nil && io != nil) {return}

	command_sector: [SECTOR]u8
	for &byte in command_sector {byte = 0x31}
	command_lba := journal_test_data_lba(v, command.first_cluster)
	testing.expect(t, volume_stage_write(v, command_lba, command_sector[:]))
	before := volume_journal_storage_stats(v)
	testing.expect(t, volume_reconcile(v))
	first := volume_journal_storage_stats(v)
	testing.expect_value(t, first.streamed_guest_bytes - before.streamed_guest_bytes, command.size)
	testing.expect(t, first.present_sectors > 0)
	testing.expect_value(t, first.dirty_sectors, u32(0))
	testing.expect(t, read_test_sector(t, v, command_lba) == command_sector)

	testing.expect(t, volume_reconcile(v))
	second := volume_journal_storage_stats(v)
	testing.expect_value(t, second.streamed_guest_bytes, first.streamed_guest_bytes)
	testing.expect_value(t, second.streamed_guest_files, first.streamed_guest_files)
	testing.expect(t, read_test_sector(t, v, command_lba) == command_sector)

	io_sector: [SECTOR]u8
	for &byte in io_sector {byte = 0x42}
	testing.expect(t, volume_stage_write(v, journal_test_data_lba(v, io.first_cluster), io_sector[:]))
	testing.expect(t, volume_reconcile(v))
	third := volume_journal_storage_stats(v)
	testing.expect_value(t, third.streamed_guest_bytes - second.streamed_guest_bytes, io.size)
	testing.expect_value(t, third.streamed_guest_files - second.streamed_guest_files, u64(1))
	testing.expect(t, read_test_sector(t, v, command_lba) == command_sector)
}

@(test)
reconcile_test_clean_overlay_adopted_by_internal_chain_change_is_materialized :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {return}
	closed := false
	defer if !closed {volume_discard(v)}

	io := reconcile_test_child_named(v.alloc.root, "IO.SYS")
	if !testing.expect(t, io != nil) {return}
	old_chain := volume_chain(v, io.first_cluster, context.temp_allocator)
	if !testing.expect(t, len(old_chain) >= 2) {return}
	new_cluster := v.alloc.next_free
	new_lba := journal_test_data_lba(v, new_cluster)
	new_rel := u32(new_lba - PART_START_LBA)
	replacement: [CLUSTER_BYTES]u8
	for &byte, index in replacement {byte = u8(index * 13 + 7)}

	// A controller flush may land data before the FAT transaction that owns it.
	testing.expect(t, volume_stage_write(v, new_lba, replacement[:]))
	testing.expect(t, overlay_dirty_has(v, new_rel))
	testing.expect(t, volume_reconcile(v))
	testing.expect(t, overlay_has(v, new_rel))
	testing.expect(t, !overlay_dirty_has(v, new_rel))

	// Keep the directory entry's first cluster and size unchanged while replacing
	// the second link. Chain identity must still force host materialization.
	reconcile_test_stage_fat_set(t, v, old_chain[0], new_cluster)
	reconcile_test_stage_fat_set(t, v, new_cluster, 0x0FFF_FFFF)
	reconcile_test_stage_fat_set(t, v, old_chain[1], 0)
	testing.expect(t, volume_reconcile(v))
	testing.expect(t, !v.frozen)

	host, host_error := os.read_entire_file(io.host_path, context.temp_allocator)
	testing.expect(t, host_error == nil)
	testing.expect_value(t, len(host), int(io.size))
	tail_bytes := len(host) - CLUSTER_BYTES
	if tail_bytes > 0 {
		testing.expect(
			t,
			string(host[CLUSTER_BYTES:]) == string(replacement[:tail_bytes]),
		)
	}
	guest: [CLUSTER_BYTES]u8
	testing.expect(t, volume_read(v, new_lba, guest[:]))
	testing.expect(t, guest == replacement)

	if !volume_close(v) {
		testing.expect(t, false)
		return
	}
	closed = true
	v2 := volume_open(dir, 2048)
	if !testing.expect(t, v2 != nil) {return}
	defer volume_discard(v2)
	reopened := reconcile_test_child_named(v2.alloc.root, "IO.SYS")
	if !testing.expect(t, reopened != nil) {return}
	reopened_chain := volume_chain(v2, reopened.first_cluster, context.temp_allocator)
	if !testing.expect(t, len(reopened_chain) >= 2) {return}
	reopened_tail: [CLUSTER_BYTES]u8
	testing.expect(
		t,
		volume_read(v2, journal_test_data_lba(v2, reopened_chain[1]), reopened_tail[:]),
	)
	if tail_bytes > 0 {
		testing.expect(
			t,
			string(reopened_tail[:tail_bytes]) == string(replacement[:tail_bytes]),
		)
	}
}

@(test)
reconcile_test_deleted_donor_replaces_existing_file :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {return}
	defer volume_discard(v)
	command := v.alloc.root.children[0]
	io := v.alloc.root.children[2]
	io_path := strings.clone(io.host_path, context.temp_allocator)
	want, _ := os.read_entire_file(io.host_path, context.temp_allocator)
	root_lba := journal_test_data_lba(v, 2)
	sector := read_test_sector(t, v, root_lba)
	decode_test_put_entry(sector[:], 0, "COMMAND COM", ATTR_FILE, io.first_cluster, u32(io.size))
	sector[64] = 0xE5

	testing.expect(t, volume_stage_write(v, root_lba, sector[:]))
	testing.expect(t, volume_reconcile(v))
	testing.expect(t, !v.frozen)
	got, err := os.read_entire_file(command.host_path, context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect(t, string(got) == string(want))
	testing.expect(t, !os.exists(io_path))
	guest := make([]u8, ((len(want) + SECTOR - 1) / SECTOR) * SECTOR, context.temp_allocator)
	testing.expect(t, volume_read(v, journal_test_data_lba(v, io.first_cluster), guest))
	testing.expect(t, string(guest[:len(want)]) == string(want))
}

@(test)
reconcile_test_failed_close_retains_overlay_for_retry :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {return}
	closed := false
	defer if !closed {volume_discard(v)}

	cluster := v.alloc.next_free
	fat_lba := journal_test_fat_lba(v, cluster)
	fat_sector := read_test_sector(t, v, fat_lba)
	fat_offset := int(cluster % 128) * 4
	fat_sector[fat_offset] = 0xFF
	fat_sector[fat_offset + 1] = 0xFF
	fat_sector[fat_offset + 2] = 0xFF
	fat_sector[fat_offset + 3] = 0x0F
	testing.expect(t, volume_stage_write(v, fat_lba, fat_sector[:]))

	data_lba := journal_test_data_lba(v, cluster)
	data: [SECTOR]u8
	copy(data[:], "SAFE")
	testing.expect(t, volume_stage_write(v, data_lba, data[:]))
	root_lba := journal_test_data_lba(v, 2)
	root_sector := read_test_sector(t, v, root_lba)
	decode_test_put_entry(root_sector[:], 96, "BLOCKED TXT", ATTR_FILE, cluster, 4)
	testing.expect(t, volume_stage_write(v, root_lba, root_sector[:]))

	blocked, _ := filepath.join({dir, "BLOCKED.TXT"})
	testing.expect(t, os.make_directory(blocked) == nil)
	overlay_count := volume_journal_storage_stats(v).present_sectors
	testing.expect(t, overlay_count >= 3)
	testing.expect(t, !volume_close(v))
	testing.expect_value(t, volume_journal_storage_stats(v).present_sectors, overlay_count)
	testing.expect(t, !v.frozen)

	testing.expect(t, os.remove(blocked) == nil)
	testing.expect(t, volume_close(v))
	closed = true
	contents, read_error := os.read_entire_file(blocked, context.temp_allocator)
	testing.expect(t, read_error == nil)
	testing.expect_value(t, string(contents), "SAFE")
}

@(test)
reconcile_test_deleted_directory_removes_unreachable_tree_bottom_up :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := fat32_test_fixture(t)
	defer os.remove_all(dir)
	wininst, _ := filepath.join({dir, "WININST0.400"})
	pluspack, _ := filepath.join({wininst, "PLUSPACK"})
	file, _ := filepath.join({wininst, "SETUPX.DLL"})
	nested, _ := filepath.join({pluspack, "PLUS.INF"})
	testing.expect(t, os.make_directory_all(pluspack) == nil)
	testing.expect(t, os.write_entire_file(file, "setup") == nil)
	testing.expect(t, os.write_entire_file(nested, "plus") == nil)

	v := volume_open(dir, 2048)
	if !testing.expect(t, v != nil) {return}
	closed := false
	defer if !closed {volume_discard(v)}
	owner := reconcile_test_child_named(v.alloc.root, "WININST0.400")
	if !testing.expect(t, owner != nil) {return}

	root_lba := journal_test_data_lba(v, v.alloc.root.first_cluster)
	root_sector := read_test_sector(t, v, root_lba)
	root_sector[96] = 0xE5
	testing.expect(t, volume_stage_write(v, root_lba, root_sector[:]))
	reconcile_test_stage_fat_set(t, v, owner.first_cluster, 0)

	testing.expect(t, volume_reconcile(v))
	testing.expect(t, !v.frozen)
	testing.expect(t, !os.exists(wininst))
	testing.expect(t, volume_close(v))
	closed = true
}

@(test)
reconcile_test_nested_rename_moves_parents_before_descendants :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := filepath.join({base, "retvrn99_nested_rename"})
	defer os.remove_all(dir)
	old_parent, _ := filepath.join({dir, "PARENT~1"})
	old_child, _ := filepath.join({old_parent, "CHILD~1"})
	old_file, _ := filepath.join({old_child, "FILE.TXT"})
	io_sys, _ := filepath.join({dir, "IO.SYS"})
	testing.expect(t, os.make_directory_all(old_child) == nil)
	testing.expect(t, os.write_entire_file(old_file, "nested") == nil)
	testing.expect(t, os.write_entire_file(io_sys, "boot") == nil)

	v := volume_open(dir, 2048)
	if !testing.expect(t, v != nil) {return}
	defer volume_discard(v)
	parent := reconcile_test_child_named(v.alloc.root, "PARENT~1")
	if !testing.expect(t, parent != nil) {return}
	child := reconcile_test_child_named(parent, "CHILD~1")
	if !testing.expect(t, child != nil) {return}
	file := reconcile_test_child_named(child, "FILE.TXT")
	if !testing.expect(t, file != nil) {return}

	parent_short := [11]u8{'P','A','R','E','N','T','~','2',' ',' ',' '}
	root_sector := read_test_sector(t, v, journal_test_data_lba(v, v.alloc.root.first_cluster))
	parent_offset := reconcile_test_entry_offset(root_sector[:], parent.short)
	if !testing.expect(t, parent_offset >= 0) {return}
	decode_test_put_lfn(root_sector[:], parent_offset, 1, true, lfn_checksum(parent_short), "Parent Long")
	decode_test_put_entry(root_sector[:], parent_offset + 32, "PARENT~2   ", ATTR_DIR, parent.first_cluster, 0)
	testing.expect(t, volume_stage_write(v, journal_test_data_lba(v, v.alloc.root.first_cluster), root_sector[:]))

	child_short := [11]u8{'C','H','I','L','D','~','2',' ',' ',' ',' '}
	parent_sector := read_test_sector(t, v, journal_test_data_lba(v, parent.first_cluster))
	child_offset := reconcile_test_entry_offset(parent_sector[:], child.short)
	if !testing.expect(t, child_offset >= 0) {return}
	decode_test_put_lfn(parent_sector[:], child_offset, 1, true, lfn_checksum(child_short), "Child Long")
	decode_test_put_entry(parent_sector[:], child_offset + 32, "CHILD~2    ", ATTR_DIR, child.first_cluster, 0)
	testing.expect(t, volume_stage_write(v, journal_test_data_lba(v, parent.first_cluster), parent_sector[:]))

	file_short := [11]u8{'R','E','N','A','M','~','1',' ','T','X','T'}
	child_sector := read_test_sector(t, v, journal_test_data_lba(v, child.first_cluster))
	file_offset := reconcile_test_entry_offset(child_sector[:], file.short)
	if !testing.expect(t, file_offset >= 0) {return}
	decode_test_put_lfn(child_sector[:], file_offset, 1, true, lfn_checksum(file_short), "Renamed.txt")
	decode_test_put_entry(child_sector[:], file_offset + 32, "RENAM~1 TXT", ATTR_FILE, file.first_cluster, u32(file.size))
	testing.expect(t, volume_stage_write(v, journal_test_data_lba(v, child.first_cluster), child_sector[:]))

	testing.expect(t, volume_reconcile(v))
	testing.expect(t, !v.frozen)
	new_file, _ := filepath.join({dir, "Parent Long", "Child Long", "Renamed.txt"})
	contents, read_error := os.read_entire_file(new_file, context.temp_allocator)
	testing.expect(t, read_error == nil)
	testing.expect_value(t, string(contents), "nested")
	testing.expect_value(t, parent.name, "Parent Long")
	testing.expect_value(t, child.name, "Child Long")
	testing.expect_value(t, file.name, "Renamed.txt")
}

@(test)
reconcile_test_nested_lfn_localization_keeps_backing_paths_live :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := filepath.join({base, "retvrn99_nested_lfn_localization"})
	defer os.remove_all(dir)
	old_parent, _ := filepath.join({dir, "PARENT~1"})
	old_child, _ := filepath.join({old_parent, "CHILD~1"})
	old_file, _ := filepath.join({old_child, "PRETTY~1.TXT"})
	io_sys, _ := filepath.join({dir, "IO.SYS"})
	testing.expect(t, os.make_directory_all(old_child) == nil)
	testing.expect(t, os.write_entire_file(old_file, "nested backing") == nil)
	testing.expect(t, os.write_entire_file(io_sys, "boot") == nil)

	v := volume_open(dir, 2048)
	if !testing.expect(t, v != nil) {return}
	closed := false
	defer if !closed {volume_discard(v)}
	parent := reconcile_test_child_named(v.alloc.root, "PARENT~1")
	if !testing.expect(t, parent != nil) {return}
	child := reconcile_test_child_named(parent, "CHILD~1")
	if !testing.expect(t, child != nil) {return}
	file := reconcile_test_child_named(child, "PRETTY~1.TXT")
	if !testing.expect(t, file != nil) {return}

	root_sector := read_test_sector(t, v, journal_test_data_lba(v, v.alloc.root.first_cluster))
	parent_offset := reconcile_test_entry_offset(root_sector[:], parent.short)
	if !testing.expect(t, parent_offset >= 0) {return}
	decode_test_put_lfn(root_sector[:], parent_offset, 1, true, lfn_checksum(parent.short), "Parent Long")
	decode_test_put_entry(root_sector[:], parent_offset + 32, "PARENT~1   ", ATTR_DIR, parent.first_cluster, 0)
	testing.expect(t, volume_stage_write(v, journal_test_data_lba(v, v.alloc.root.first_cluster), root_sector[:]))

	parent_sector := read_test_sector(t, v, journal_test_data_lba(v, parent.first_cluster))
	child_offset := reconcile_test_entry_offset(parent_sector[:], child.short)
	if !testing.expect(t, child_offset >= 0) {return}
	decode_test_put_lfn(parent_sector[:], child_offset, 1, true, lfn_checksum(child.short), "Child Long")
	decode_test_put_entry(parent_sector[:], child_offset + 32, "CHILD~1    ", ATTR_DIR, child.first_cluster, 0)
	testing.expect(t, volume_stage_write(v, journal_test_data_lba(v, parent.first_cluster), parent_sector[:]))

	child_sector := read_test_sector(t, v, journal_test_data_lba(v, child.first_cluster))
	file_offset := reconcile_test_entry_offset(child_sector[:], file.short)
	if !testing.expect(t, file_offset >= 0) {return}
	decode_test_put_lfn(child_sector[:], file_offset, 1, true, lfn_checksum(file.short), "Pretty.txt")
	decode_test_put_entry(
		child_sector[:],
		file_offset + 32,
		"PRETTY~1TXT",
		ATTR_FILE,
		file.first_cluster,
		u32(file.size),
	)
	testing.expect(t, volume_stage_write(v, journal_test_data_lba(v, child.first_cluster), child_sector[:]))

	file_sector := read_test_sector(t, v, journal_test_data_lba(v, file.first_cluster))
	file_sector[0] = 'N'
	testing.expect(t, volume_stage_write(v, journal_test_data_lba(v, file.first_cluster), file_sector[:]))
	testing.expect(t, volume_reconcile(v))
	testing.expect(t, !v.frozen)

	new_parent, _ := filepath.join({dir, "Parent Long"})
	new_child, _ := filepath.join({new_parent, "Child Long"})
	new_file, _ := filepath.join({new_child, "Pretty.txt"})
	contents, read_error := os.read_entire_file(new_file, context.temp_allocator)
	testing.expect(t, read_error == nil)
	if read_error == nil {
		testing.expect_value(t, string(contents), "Nested backing")
	}
	testing.expect(t, !reconcile_test_host_has_entry(dir, "PARENT~1"))
	testing.expect(t, !reconcile_test_host_has_entry(new_parent, "CHILD~1"))
	testing.expect(t, !reconcile_test_host_has_entry(new_child, "PRETTY~1.TXT"))
	testing.expect(t, os.exists(new_parent) && os.exists(new_child) && os.exists(new_file))
	testing.expect_value(t, parent.host_path, new_parent)
	testing.expect_value(t, child.host_path, new_child)
	testing.expect_value(t, file.host_path, new_file)
	parent_key := Mirror_Key{v.alloc.root.first_cluster, parent.short}
	child_key := Mirror_Key{parent.first_cluster, child.short}
	file_key := Mirror_Key{child.first_cluster, file.short}
	parent_mirror, parent_mirrored := v.journal.mirrored[parent_key]
	child_mirror, child_mirrored := v.journal.mirrored[child_key]
	file_mirror, file_mirrored := v.journal.mirrored[file_key]
	testing.expect(t, parent_mirrored && child_mirrored && file_mirrored)
	if parent_mirrored {
		testing.expect(t, parent_mirror.base_node == parent)
		testing.expect_value(t, parent_mirror.host_path, parent.host_path)
	}
	if child_mirrored {
		testing.expect(t, child_mirror.base_node == child)
		testing.expect_value(t, child_mirror.host_path, child.host_path)
	}
	if file_mirrored {
		testing.expect(t, file_mirror.base_node == file)
		testing.expect_value(t, file_mirror.host_path, file.host_path)
	}

	first := volume_journal_storage_stats(v)
	testing.expect(t, volume_reconcile(v))
	second := volume_journal_storage_stats(v)
	testing.expect_value(t, second.streamed_guest_files, first.streamed_guest_files)
	testing.expect_value(t, second.streamed_guest_bytes, first.streamed_guest_bytes)
	testing.expect_value(t, second.dirty_sectors, u32(0))
	testing.expect_value(t, parent.host_path, new_parent)
	testing.expect_value(t, child.host_path, new_child)
	testing.expect_value(t, file.host_path, new_file)

	if !testing.expect(t, volume_close(v)) {return}
	closed = true
	v2 := volume_open(dir, 2048)
	if !testing.expect(t, v2 != nil) {return}
	defer volume_discard(v2)
	reopened_parent := reconcile_test_child_named(v2.alloc.root, "Parent Long")
	if !testing.expect(t, reopened_parent != nil) {return}
	reopened_child := reconcile_test_child_named(reopened_parent, "Child Long")
	if !testing.expect(t, reopened_child != nil) {return}
	reopened_file := reconcile_test_child_named(reopened_child, "Pretty.txt")
	if !testing.expect(t, reopened_file != nil) {return}
	testing.expect_value(t, reopened_parent.host_path, new_parent)
	testing.expect_value(t, reopened_child.host_path, new_child)
	testing.expect_value(t, reopened_file.host_path, new_file)
	reopened_key := Mirror_Key{reopened_child.first_cluster, reopened_file.short}
	reopened_mirror, reopened_mirrored := v2.journal.mirrored[reopened_key]
	testing.expect(t, reopened_mirrored)
	if reopened_mirrored {
		testing.expect(t, reopened_mirror.base_node == reopened_file)
		testing.expect_value(t, reopened_mirror.host_path, reopened_file.host_path)
	}
	testing.expect(t, !reconcile_test_host_has_entry(dir, "PARENT~1"))
	testing.expect(t, !reconcile_test_host_has_entry(new_parent, "CHILD~1"))
	testing.expect(t, !reconcile_test_host_has_entry(new_child, "PRETTY~1.TXT"))
	contents, read_error = os.read_entire_file(reopened_file.host_path, context.temp_allocator)
	testing.expect(t, read_error == nil)
	if read_error == nil {testing.expect_value(t, string(contents), "Nested backing")}
}

@(test)
reconcile_test_missing_alias_source_keeps_retryable_backing_identity :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := filepath.join({base, "retvrn99_missing_alias_retry"})
	defer os.remove_all(dir)
	old_file, _ := filepath.join({dir, "ZZFILE~1.TXT"})
	io_sys, _ := filepath.join({dir, "IO.SYS"})
	testing.expect(t, os.make_directory_all(dir) == nil)
	testing.expect(t, os.write_entire_file(old_file, "payload") == nil)
	testing.expect(t, os.write_entire_file(io_sys, "boot") == nil)

	v := volume_open(dir, 2048)
	if !testing.expect(t, v != nil) {return}
	defer volume_discard(v)
	file := reconcile_test_child_named(v.alloc.root, "ZZFILE~1.TXT")
	if !testing.expect(t, file != nil) {return}
	key := Mirror_Key{v.alloc.root.first_cluster, file.short}

	root_lba := journal_test_data_lba(v, v.alloc.root.first_cluster)
	root_sector := read_test_sector(t, v, root_lba)
	file_offset := reconcile_test_entry_offset(root_sector[:], file.short)
	if !testing.expect(t, file_offset >= 0) {return}
	decode_test_put_lfn(root_sector[:], file_offset, 1, true, lfn_checksum(file.short), "Localized.txt")
	decode_test_put_entry(
		root_sector[:],
		file_offset + 32,
		"ZZFILE~1TXT",
		ATTR_FILE,
		file.first_cluster,
		u32(file.size),
	)
	testing.expect(t, volume_stage_write(v, root_lba, root_sector[:]))
	testing.expect(t, os.remove(old_file) == nil)

	testing.expect(t, !volume_reconcile(v))
	testing.expect(t, !v.frozen)
	new_file, _ := filepath.join({dir, "Localized.txt"})
	testing.expect(t, !os.exists(new_file))
	testing.expect_value(t, file.host_path, old_file)
	stored, mirrored := v.journal.mirrored[key]
	testing.expect(t, mirrored)
	if mirrored {testing.expect_value(t, stored.host_path, old_file)}
	testing.expect(t, volume_journal_storage_stats(v).dirty_sectors > 0)

	testing.expect(t, os.write_entire_file(old_file, "payload") == nil)
	testing.expect(t, volume_reconcile(v))
	testing.expect(t, !v.frozen)
	contents, read_error := os.read_entire_file(new_file, context.temp_allocator)
	testing.expect(t, read_error == nil)
	if read_error == nil {testing.expect_value(t, string(contents), "payload")}
	testing.expect_value(t, file.host_path, new_file)
	testing.expect_value(t, volume_journal_storage_stats(v).dirty_sectors, u32(0))
}

@(private = "file")
reconcile_test_entry_offset :: proc(bytes: []u8, short: [11]u8) -> int {
	for offset := 0; offset + 32 <= len(bytes); offset += 32 {
		if bytes[offset] == 0 {break}
		matches := true
		for i in 0 ..< len(short) {
			if bytes[offset + i] != short[i] {matches = false; break}
		}
		if matches {return offset}
	}
	return -1
}

@(test)
reconcile_test_snapshot_short_read_freezes_without_losing_original :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {return}
	defer volume_discard(v)
	node := v.alloc.root.children[0]
	backup, original := read_test_preserve_backing(t, node.host_path)
	defer read_test_restore_backing(t, node.host_path, backup, original)
	testing.expect(t, os.write_entire_file(node.host_path, "X") == nil)
	fired := false
	journal_test_arm_on_fail(v, &fired)
	overlay_count := volume_journal_storage_stats(v).present_sectors

	testing.expect(t, !reconcile_snapshot_base_file(v, node))
	testing.expect(t, fired)
	testing.expect(t, v.frozen)
	testing.expect(t, !v.journal.snapshotted[node])
	testing.expect_value(t, volume_journal_storage_stats(v).present_sectors, overlay_count)
}

@(test)
reconcile_test_scan_read_failure_prevents_host_mutation :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {return}
	defer volume_discard(v)
	command := v.alloc.root.children[0]
	dos := v.alloc.root.children[1]
	testing.expect_value(t, command.name, "COMMAND.COM")
	testing.expect_value(t, dos.name, "DOS")
	old_is_dir, old_size := dos.is_dir, dos.size
	defer {
		dos.is_dir = old_is_dir
		dos.size = old_size
	}

	root_lba := journal_test_data_lba(v, 2)
	sector := read_test_sector(t, v, root_lba)
	sector[0] = 0xE5
	decode_test_put_entry(
		sector[:],
		96,
		"RENAMED COM",
		ATTR_FILE,
		command.first_cluster,
		u32(command.size),
	)
	testing.expect(t, volume_stage_write(v, root_lba, sector[:]))
	dos.is_dir = false
	dos.size = SECTOR
	fired := false
	journal_test_arm_on_fail(v, &fired)
	old_path, _ := filepath.join({dir, "COMMAND.COM"})
	new_path, _ := filepath.join({dir, "RENAMED.COM"})

	testing.expect(t, !volume_reconcile(v))
	testing.expect(t, fired)
	testing.expect(t, v.frozen)
	testing.expect(t, os.exists(old_path))
	testing.expect(t, !os.exists(new_path))
}

@(test)
reconcile_test_plain_delete_releases_cluster_for_reuse :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {return}
	closed := false
	defer if !closed {volume_discard(v)}

	command := v.alloc.root.children[0]
	old_node := command
	old_cluster := command.first_cluster
	old_key := Mirror_Key{v.alloc.root.first_cluster, command.short}
	old_path := strings.clone(command.host_path, context.temp_allocator)
	root_lba := journal_test_data_lba(v, v.alloc.root.first_cluster)
	root_sector := read_test_sector(t, v, root_lba)
	root_sector[0] = 0xE5
	testing.expect(t, volume_stage_write(v, root_lba, root_sector[:]))
	reconcile_test_stage_fat_set(t, v, old_cluster, 0)

	testing.expect(t, volume_reconcile(v))
	testing.expect(t, !v.frozen)
	testing.expect(t, !os.exists(old_path))
	testing.expect(t, !managed_node_attached(v.alloc.root, old_node))
	testing.expect(t, v.alloc.by_cluster[old_cluster] == nil)
	_, old_claimed := v.journal.claimed[old_cluster]
	_, old_mirrored := v.journal.mirrored[old_key]
	testing.expect(t, !old_claimed)
	testing.expect(t, !old_mirrored)
	testing.expect(t, !v.journal.stale_clusters[old_cluster])

	reconcile_test_stage_fat_set(t, v, old_cluster, 0x0FFF_FFFF)
	initial: [SECTOR]u8
	for &byte in initial {byte = 0x31}
	testing.expect(t, volume_stage_write(v, journal_test_data_lba(v, old_cluster), initial[:]))
	root_sector = read_test_sector(t, v, root_lba)
	decode_test_put_entry(root_sector[:], 0, "REUSED  TXT", ATTR_FILE, old_cluster, SECTOR)
	testing.expect(t, volume_stage_write(v, root_lba, root_sector[:]))

	testing.expect(t, volume_reconcile(v))
	testing.expect(t, !v.frozen)
	reused_path, _ := filepath.join({dir, "REUSED.TXT"})
	host, host_error := os.read_entire_file(reused_path, context.temp_allocator)
	testing.expect(t, host_error == nil)
	testing.expect_value(t, len(host), SECTOR)
	if len(host) == SECTOR {
		testing.expect(t, string(host) == string(initial[:]))
	}
	reused := reconcile_test_child_named(v.alloc.root, "REUSED.TXT")
	testing.expect(t, reused != nil)
	if reused == nil {return}
	testing.expect_value(t, reused.first_cluster, old_cluster)
	testing.expect(t, managed_node_attached(v.alloc.root, reused))
	claim, claimed := v.journal.claimed[old_cluster]
	testing.expect(t, claimed)
	if claimed {testing.expect(t, claim.node == reused)}

	updated: [SECTOR]u8
	for &byte in updated {byte = 0xA5}
	testing.expect(t, volume_write(v, journal_test_data_lba(v, old_cluster), updated[:]))
	host, host_error = os.read_entire_file(reused_path, context.temp_allocator)
	testing.expect(t, host_error == nil)
	if len(host) == SECTOR {
		testing.expect(t, string(host) == string(updated[:]))
	}
	staged: [SECTOR]u8
	for &byte in staged {byte = 0x5A}
	testing.expect(t, volume_stage_write(v, journal_test_data_lba(v, old_cluster), staged[:]))
	testing.expect(t, volume_reconcile(v))
	guest: [SECTOR]u8
	testing.expect(t, volume_read(v, journal_test_data_lba(v, old_cluster), guest[:]))
	testing.expect(t, string(guest[:]) == string(staged[:]))

	if !volume_close(v) {
		testing.expect(t, false)
		return
	}
	closed = true
	v2 := volume_open(dir, 2048)
	testing.expect(t, v2 != nil)
	if v2 == nil {return}
	defer volume_discard(v2)
	reopened := reconcile_test_child_named(v2.alloc.root, "REUSED.TXT")
	testing.expect(t, reopened != nil)
	if reopened == nil {return}
	reopened_guest: [SECTOR]u8
	testing.expect(
		t,
		volume_read(v2, journal_test_data_lba(v2, reopened.first_cluster), reopened_guest[:]),
	)
	testing.expect(t, string(reopened_guest[:]) == string(staged[:]))
}

@(test)
reconcile_test_same_cluster_reuse_is_not_a_rename :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {return}
	defer volume_discard(v)

	old_node := reconcile_test_child_named(v.alloc.root, "COMMAND.COM")
	if !testing.expect(t, old_node != nil) {return}
	old_cluster := old_node.first_cluster
	old_path := strings.clone(old_node.host_path, context.temp_allocator)
	new_path, _ := filepath.join({dir, "REUSED.TXT"})
	replacement := make([]u8, int(old_node.size), context.temp_allocator)
	for &byte, index in replacement {byte = u8(index * 29 + 17)}
	// A prior retry may already have installed the new file while retaining the
	// old mirror. Reconciliation must adopt it, not attempt an impossible move.
	testing.expect(t, os.write_entire_file(new_path, replacement) == nil)

	cluster: [CLUSTER_BYTES]u8
	copy(cluster[:], replacement)
	testing.expect(t, volume_stage_write(v, journal_test_data_lba(v, old_cluster), cluster[:]))
	root_lba := journal_test_data_lba(v, v.alloc.root.first_cluster)
	root_sector := read_test_sector(t, v, root_lba)
	root_sector[0] = 0xE5
	decode_test_put_entry(
		root_sector[:],
		96,
		"REUSED  TXT",
		ATTR_FILE,
		old_cluster,
		u32(len(replacement)),
	)
	testing.expect(t, volume_stage_write(v, root_lba, root_sector[:]))

	testing.expect(t, volume_reconcile(v))
	testing.expect(t, !v.frozen)
	testing.expect(t, !os.exists(old_path))
	contents, read_error := os.read_entire_file(new_path, context.temp_allocator)
	testing.expect(t, read_error == nil)
	if read_error == nil {testing.expect(t, string(contents) == string(replacement))}
	testing.expect(t, !managed_node_attached(v.alloc.root, old_node))
	new_node := reconcile_test_child_named(v.alloc.root, "REUSED.TXT")
	if !testing.expect(t, new_node != nil) {return}
	testing.expect(t, new_node != old_node)
	testing.expect_value(t, new_node.first_cluster, old_cluster)
	new_key := Mirror_Key{v.alloc.root.first_cluster, new_node.short}
	stored, mirrored := v.journal.mirrored[new_key]
	testing.expect(t, mirrored)
	if mirrored {testing.expect(t, stored.base_node == new_node)}

	before := volume_journal_storage_stats(v)
	testing.expect(t, volume_reconcile(v))
	after := volume_journal_storage_stats(v)
	testing.expect_value(t, after.streamed_guest_files, before.streamed_guest_files)
	testing.expect_value(t, after.dirty_sectors, u32(0))
}

@(test)
reconcile_test_same_path_accepts_reused_directory_entry_identity :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {return}
	defer volume_discard(v)

	old_node := reconcile_test_child_named(v.alloc.root, "COMMAND.COM")
	if !testing.expect(t, old_node != nil) {return}
	old_cluster := old_node.first_cluster
	old_key := Mirror_Key{v.alloc.root.first_cluster, old_node.short}
	path := strings.clone(old_node.host_path, context.temp_allocator)
	replacement := make([]u8, int(old_node.size), context.temp_allocator)
	for &byte, index in replacement {byte = u8(index * 31 + 9)}

	cluster: [CLUSTER_BYTES]u8
	copy(cluster[:], replacement)
	testing.expect(t, volume_stage_write(v, journal_test_data_lba(v, old_cluster), cluster[:]))
	root_lba := journal_test_data_lba(v, v.alloc.root.first_cluster)
	root_sector := read_test_sector(t, v, root_lba)
	root_sector[0] = 0xE5
	new_short: [11]u8
	copy(new_short[:], "COMMAN~1COM")
	decode_test_put_lfn(
		root_sector[:],
		96,
		1,
		true,
		lfn_checksum(new_short),
		"COMMAND.COM",
	)
	decode_test_put_entry(
		root_sector[:],
		128,
		"COMMAN~1COM",
		ATTR_FILE,
		old_cluster,
		u32(len(replacement)),
	)
	testing.expect(t, volume_stage_write(v, root_lba, root_sector[:]))

	testing.expect(t, volume_reconcile(v))
	testing.expect(t, !v.frozen)
	contents, read_error := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, read_error == nil)
	if read_error == nil {testing.expect(t, string(contents) == string(replacement))}
	_, old_mirrored := v.journal.mirrored[old_key]
	testing.expect(t, !old_mirrored)
	new_key := Mirror_Key{v.alloc.root.first_cluster, new_short}
	stored, new_mirrored := v.journal.mirrored[new_key]
	testing.expect(t, new_mirrored)
	if new_mirrored {
		testing.expect_value(t, stored.host_path, path)
		testing.expect_value(t, stored.first_cluster, old_cluster)
	}
	testing.expect_value(t, volume_journal_storage_stats(v).dirty_sectors, u32(0))
}

@(test)
reconcile_test_free_to_allocated_fat_transition_does_not_grow_stale_directory :: proc(
	t: ^testing.T,
) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {return}
	defer volume_discard(v)

	dos := reconcile_test_child_named(v.alloc.root, "DOS")
	command := reconcile_test_child_named(v.alloc.root, "COMMAND.COM")
	if !testing.expect(t, dos != nil && command != nil) {return}
	stale_cluster := dos.first_cluster

	reconcile_test_stage_fat_set(t, v, stale_cluster, 0)
	testing.expect_value(t, volume_fat_entry(v, stale_cluster) & 0x0FFF_FFFF, u32(0))
	testing.expect(t, v.alloc.by_cluster[stale_cluster] == dos)

	// The guest may immediately reuse the freed cluster. Its new FAT link must
	// not be interpreted as growth of the still-retained host directory node.
	reconcile_test_stage_fat_set(t, v, stale_cluster, command.first_cluster)
	testing.expect(t, !v.frozen)
	for pending in v.journal.pending_extends {
		testing.expect(t, pending != dos)
	}
	testing.expect(t, v.alloc.by_cluster[stale_cluster] == dos)
}

@(test)
reconcile_test_held_directory_delete_retires_before_same_key_cluster_reuse :: proc(
	t: ^testing.T,
) {
	context.allocator = context.temp_allocator
	dir := fat32_test_fixture(t)
	defer os.remove_all(dir)
	old_child_path, _ := filepath.join({dir, "DOS", "EDIT.HLP"})
	moved_payload := "moved child survives"
	testing.expect(t, os.write_entire_file(old_child_path, moved_payload) == nil)
	v := volume_open(dir, 2048)
	if !testing.expect(t, v != nil) {return}
	defer volume_discard(v)

	dos := reconcile_test_child_named(v.alloc.root, "DOS")
	edit := reconcile_test_child_named(dos, "EDIT.HLP")
	if !testing.expect(t, dos != nil && edit != nil) {return}
	old_dos_path := strings.clone(dos.host_path, context.temp_allocator)
	old_dos_cluster := dos.first_cluster
	dos_key := Mirror_Key{v.alloc.root.first_cluster, dos.short}
	moved_path, _ := filepath.join({dir, "MOVED.HLP"})
	testing.expect(t, os.make_directory(moved_path) == nil)

	dos_lba := journal_test_data_lba(v, old_dos_cluster)
	dos_sector := read_test_sector(t, v, dos_lba)
	edit_offset := reconcile_test_entry_offset(dos_sector[:], edit.short)
	if !testing.expect(t, edit_offset >= 0) {return}
	dos_sector[edit_offset] = 0xE5
	testing.expect(t, volume_stage_write(v, dos_lba, dos_sector[:]))

	root_lba := journal_test_data_lba(v, v.alloc.root.first_cluster)
	root_sector := read_test_sector(t, v, root_lba)
	dos_offset := reconcile_test_entry_offset(root_sector[:], dos.short)
	if !testing.expect(t, dos_offset >= 0) {return}
	decode_test_put_entry(
		root_sector[:],
		dos_offset,
		"MOVED   HLP",
		ATTR_FILE,
		edit.first_cluster,
		u32(edit.size),
	)
	testing.expect(t, volume_stage_write(v, root_lba, root_sector[:]))
	reconcile_test_stage_fat_set(t, v, old_dos_cluster, 0)

	// The occupied destination holds the descendant move, so the old DOS host
	// directory cannot yet be removed. Its FAT ownership must still be released.
	testing.expect(t, !volume_reconcile(v))
	testing.expect(t, !v.frozen)
	retiring, retiring_ok := v.journal.mirrored[dos_key]
	testing.expect(t, retiring_ok)
	if retiring_ok {testing.expect(t, retiring.guest_deleted)}
	testing.expect(t, os.exists(old_dos_path) && os.exists(old_child_path))
	testing.expect(t, v.alloc.by_cluster[old_dos_cluster] == nil)
	_, old_claimed := v.journal.claimed[old_dos_cluster]
	testing.expect(t, !old_claimed)

	// Reuse the cluster and the DOS key for a new directory tree while the old
	// host path is still awaiting retirement.
	fresh_cluster := v.alloc.next_free
	reconcile_test_stage_fat_set(t, v, old_dos_cluster, 0x0FFF_FFFF)
	reconcile_test_stage_fat_set(t, v, fresh_cluster, 0x0FFF_FFFF)
	fresh_payload := "fresh reused data"
	fresh_sector: [SECTOR]u8
	copy(fresh_sector[:], fresh_payload)
	testing.expect(t, volume_stage_write(v, journal_test_data_lba(v, fresh_cluster), fresh_sector[:]))
	reused_dir: [SECTOR]u8
	decode_test_put_entry(reused_dir[:], 0, ".          ", ATTR_DIR, old_dos_cluster, 0)
	decode_test_put_entry(
		reused_dir[:],
		32,
		"..         ",
		ATTR_DIR,
		v.alloc.root.first_cluster,
		0,
	)
	decode_test_put_entry(
		reused_dir[:],
		64,
		"FRESH   TXT",
		ATTR_FILE,
		fresh_cluster,
		u32(len(fresh_payload)),
	)
	testing.expect(t, volume_stage_write(v, dos_lba, reused_dir[:]))
	root_sector = read_test_sector(t, v, root_lba)
	decode_test_put_entry(root_sector[:], 96, "DOS        ", ATTR_DIR, old_dos_cluster, 0)
	testing.expect(t, volume_stage_write(v, root_lba, root_sector[:]))
	testing.expect(t, os.remove(moved_path) == nil)

	// First retire the old same-key tree. The new DOS tree stays blocked and the
	// sparse journal remains dirty so a following reconcile can materialize it.
	testing.expect(t, !volume_reconcile(v))
	testing.expect(t, !v.frozen)
	testing.expect(t, !os.exists(old_dos_path))
	testing.expect(t, !managed_node_attached(v.alloc.root, dos))
	testing.expect(t, os.exists(moved_path))
	testing.expect(t, !os.exists(old_child_path))
	testing.expect(t, managed_node_attached(v.alloc.root, edit))
	testing.expect(t, edit.parent == v.alloc.root)
	moved_contents, moved_error := os.read_entire_file(moved_path, context.temp_allocator)
	testing.expect(t, moved_error == nil)
	if moved_error == nil {testing.expect_value(t, string(moved_contents), moved_payload)}
	_, still_retiring := v.journal.mirrored[dos_key]
	testing.expect(t, !still_retiring)
	testing.expect(t, volume_journal_storage_stats(v).dirty_sectors > 0)

	testing.expect(t, volume_reconcile(v))
	testing.expect(t, !v.frozen)
	new_dos := reconcile_test_child_named(v.alloc.root, "DOS")
	if !testing.expect(t, new_dos != nil && new_dos != dos) {return}
	testing.expect_value(t, new_dos.first_cluster, old_dos_cluster)
	new_mirror, new_mirrored := v.journal.mirrored[dos_key]
	testing.expect(t, new_mirrored)
	if new_mirrored {
		testing.expect(t, !new_mirror.guest_deleted)
		testing.expect(t, new_mirror.base_node == new_dos)
	}
	fresh_path, _ := filepath.join({dir, "DOS", "FRESH.TXT"})
	fresh_contents, fresh_error := os.read_entire_file(fresh_path, context.temp_allocator)
	testing.expect(t, fresh_error == nil)
	if fresh_error == nil {testing.expect_value(t, string(fresh_contents), fresh_payload)}
	testing.expect_value(t, volume_journal_storage_stats(v).dirty_sectors, u32(0))
}

@(test)
reconcile_test_reused_directory_cluster_blocks_old_tree_mutation :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {return}
	defer volume_discard(v)

	dos := reconcile_test_child_named(v.alloc.root, "DOS")
	if !testing.expect(t, dos != nil) {return}
	edit := reconcile_test_child_named(dos, "EDIT.HLP")
	if !testing.expect(t, edit != nil) {return}
	dos_path := strings.clone(dos.host_path, context.temp_allocator)
	edit_path := strings.clone(edit.host_path, context.temp_allocator)
	edit_contents, edit_error := os.read_entire_file(edit_path, context.temp_allocator)
	if !testing.expect(t, edit_error == nil) {return}

	fresh_cluster := v.alloc.next_free
	reconcile_test_stage_fat_set(t, v, edit.first_cluster, 0)
	reconcile_test_stage_fat_set(t, v, fresh_cluster, 0x0FFF_FFFF)
	fresh: [SECTOR]u8
	for &byte, index in fresh {byte = u8(index * 11 + 3)}
	testing.expect(t, volume_stage_write(v, journal_test_data_lba(v, fresh_cluster), fresh[:]))

	directory: [SECTOR]u8
	decode_test_put_entry(directory[:], 0, ".          ", ATTR_DIR, dos.first_cluster, 0)
	decode_test_put_entry(directory[:], 32, "..         ", ATTR_DIR, v.alloc.root.first_cluster, 0)
	decode_test_put_entry(directory[:], 64, "FRESH   TXT", ATTR_FILE, fresh_cluster, SECTOR)
	testing.expect(t, volume_stage_write(v, journal_test_data_lba(v, dos.first_cluster), directory[:]))

	root_lba := journal_test_data_lba(v, v.alloc.root.first_cluster)
	root_sector := read_test_sector(t, v, root_lba)
	dos_offset := reconcile_test_entry_offset(root_sector[:], dos.short)
	if !testing.expect(t, dos_offset >= 0) {return}
	decode_test_put_entry(root_sector[:], dos_offset, "NEWDIR     ", ATTR_DIR, dos.first_cluster, 0)
	testing.expect(t, volume_stage_write(v, root_lba, root_sector[:]))

	testing.expect(t, !volume_reconcile(v))
	testing.expect(t, !v.frozen)
	testing.expect(t, os.exists(dos_path) && os.exists(edit_path))
	contents, read_error := os.read_entire_file(edit_path, context.temp_allocator)
	testing.expect(t, read_error == nil)
	if read_error == nil {testing.expect(t, string(contents) == string(edit_contents))}
	new_path, _ := filepath.join({dir, "NEWDIR"})
	testing.expect(t, !os.exists(new_path))
	testing.expect(t, managed_node_attached(v.alloc.root, dos))
	testing.expect(t, managed_node_attached(v.alloc.root, edit))
	testing.expect(t, volume_journal_storage_stats(v).dirty_sectors > 0)
}

@(test)
reconcile_test_donor_replacement_transfers_cluster_ownership :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {return}
	closed := false
	defer if !closed {volume_discard(v)}

	command := v.alloc.root.children[0]
	dos := v.alloc.root.children[1]
	edit := dos.children[0]
	command_node := command
	donor_node := edit
	donor_cluster := edit.first_cluster
	old_command_cluster := command.first_cluster
	command_key := Mirror_Key{v.alloc.root.first_cluster, command.short}
	donor_key := Mirror_Key{dos.first_cluster, edit.short}
	command_path := strings.clone(command.host_path, context.temp_allocator)
	donor_path := strings.clone(edit.host_path, context.temp_allocator)
	want, want_error := os.read_entire_file(edit.host_path, context.temp_allocator)
	testing.expect(t, want_error == nil)
	root_lba := journal_test_data_lba(v, v.alloc.root.first_cluster)
	root_sector := read_test_sector(t, v, root_lba)
	decode_test_put_entry(
		root_sector[:],
		0,
		"COMMAND COM",
		ATTR_FILE,
		donor_cluster,
		u32(len(want)),
	)
	testing.expect(t, volume_stage_write(v, root_lba, root_sector[:]))
	dos_lba := journal_test_data_lba(v, dos.first_cluster)
	dos_sector := read_test_sector(t, v, dos_lba)
	dos_sector[64] = 0xE5
	testing.expect(t, volume_stage_write(v, dos_lba, dos_sector[:]))

	testing.expect(t, volume_reconcile(v))
	testing.expect(t, !v.frozen)
	testing.expect(t, !os.exists(donor_path))
	testing.expect(t, !managed_node_attached(v.alloc.root, donor_node))
	testing.expect(t, managed_node_attached(v.alloc.root, command_node))
	testing.expect_value(t, command_node.first_cluster, donor_cluster)
	testing.expect(t, v.alloc.by_cluster[old_command_cluster] == nil)
	_, donor_mirrored := v.journal.mirrored[donor_key]
	testing.expect(t, !donor_mirrored)
	target, target_mirrored := v.journal.mirrored[command_key]
	testing.expect(t, target_mirrored)
	if target_mirrored {testing.expect(t, target.base_node == command_node)}
	claim, claimed := v.journal.claimed[donor_cluster]
	testing.expect(t, claimed)
	if claimed {testing.expect(t, claim.node == command_node)}
	host, host_error := os.read_entire_file(command_path, context.temp_allocator)
	testing.expect(t, host_error == nil)
	testing.expect(t, string(host) == string(want))

	updated: [SECTOR]u8
	for index in 0 ..< len(want) {updated[index] = 0x6D}
	testing.expect(t, volume_write(v, journal_test_data_lba(v, donor_cluster), updated[:]))
	guest: [SECTOR]u8
	testing.expect(t, volume_read(v, journal_test_data_lba(v, donor_cluster), guest[:]))
	testing.expect(t, string(guest[:]) == string(updated[:]))
	host, host_error = os.read_entire_file(command_path, context.temp_allocator)
	testing.expect(t, host_error == nil)
	if len(host) == len(want) {
		testing.expect(t, string(host) == string(updated[:len(want)]))
	}

	if !volume_close(v) {
		testing.expect(t, false)
		return
	}
	closed = true
	v2 := volume_open(dir, 2048)
	testing.expect(t, v2 != nil)
	if v2 == nil {return}
	defer volume_discard(v2)
	reopened := reconcile_test_child_named(v2.alloc.root, "COMMAND.COM")
	testing.expect(t, reopened != nil)
	if reopened == nil {return}
	reopened_guest: [SECTOR]u8
	testing.expect(
		t,
		volume_read(v2, journal_test_data_lba(v2, reopened.first_cluster), reopened_guest[:]),
	)
	testing.expect(t, string(reopened_guest[:]) == string(updated[:]))
}

@(test)
reconcile_test_wininst_directory_owner_adopts_chain :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {return}
	defer volume_discard(v)

	dir_cluster := v.alloc.next_free
	file_cluster := dir_cluster + 1
	root_lba := journal_test_data_lba(v, v.alloc.root.first_cluster)
	root_sector := read_test_sector(t, v, root_lba)
	host_dir, _ := filepath.join({dir, "WININST0.400"})
	testing.expect(t, os.make_directory(host_dir) == nil)
	dir_short: [11]u8
	copy(dir_short[:], "WININST0400")
	owner_short: [11]u8
	copy(owner_short[:], "STALE      ")
	owner := managed_node_create(
		v,
		v.alloc.root,
		"STALE",
		host_dir,
		owner_short,
		dir_cluster,
		0,
		true,
		nil,
	)
	testing.expect(t, owner != nil)
	if owner == nil {return}
	key := Mirror_Key{v.alloc.root.first_cluster, dir_short}
	v.journal.mirrored[key] = Mirror_Entry {
		host_path     = strings.clone(host_dir, v.allocator),
		first_cluster = dir_cluster,
		is_dir        = true,
		base_node     = owner,
	}

	decode_test_put_entry(root_sector[:], 96, "WININST0400", ATTR_DIR, dir_cluster, 0)
	testing.expect(t, volume_stage_write(v, root_lba, root_sector[:]))
	dir_sector: [SECTOR]u8
	decode_test_put_entry(dir_sector[:], 0, ".          ", ATTR_DIR, dir_cluster, 0)
	decode_test_put_entry(dir_sector[:], 32, "..         ", ATTR_DIR, 0, 0)
	decode_test_put_entry(dir_sector[:], 64, "DELTEMP COM", ATTR_FILE, file_cluster, 496)
	testing.expect(t, volume_stage_write(v, journal_test_data_lba(v, dir_cluster), dir_sector[:]))
	payload: [SECTOR]u8
	for &byte, index in payload {
		byte = u8(index * 37 + 11)
	}
	testing.expect(t, volume_stage_write(v, journal_test_data_lba(v, file_cluster), payload[:]))
	reconcile_test_stage_fat_set(t, v, dir_cluster, 0x0FFF_FFFF)
	reconcile_test_stage_fat_set(t, v, file_cluster, 0x0FFF_FFFF)

	testing.expect(t, volume_reconcile(v))
	testing.expect(t, !v.frozen)
	testing.expect_value(t, owner.cluster_len, u32(1))
	testing.expect_value(t, owner.name, "WININST0.400")
	testing.expect_value(t, owner.short, dir_short)
	testing.expect(t, owner.parent == v.alloc.root)
	dir_claim, dir_claimed := v.journal.claimed[dir_cluster]
	testing.expect(t, dir_claimed)
	if dir_claimed {testing.expect(t, dir_claim.node == owner)}
	host_file, _ := filepath.join({host_dir, "DELTEMP.COM"})
	contents, read_error := os.read_entire_file(host_file, context.temp_allocator)
	testing.expect(t, read_error == nil)
	testing.expect_value(t, len(contents), 496)
	if len(contents) == 496 {
		testing.expect(t, string(contents) == string(payload[:496]))
	}
	child := reconcile_test_child_named(owner, "DELTEMP.COM")
	testing.expect(t, child != nil)
	file_claim, file_claimed := v.journal.claimed[file_cluster]
	testing.expect(t, file_claimed)
	if file_claimed {testing.expect(t, file_claim.node == child)}
	guest: [SECTOR]u8
	testing.expect(t, volume_read(v, journal_test_data_lba(v, file_cluster), guest[:]))
	testing.expect(t, string(guest[:496]) == string(payload[:496]))
	testing.expect(t, volume_reconcile(v))
	stored, mirrored := v.journal.mirrored[key]
	testing.expect(t, mirrored)
	if mirrored {testing.expect(t, stored.base_node == owner)}
}

@(test)
reconcile_test_seeded_directory_keeps_synthesized_chain :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {return}
	defer volume_discard(v)
	dos := reconcile_test_child_named(v.alloc.root, "DOS")
	testing.expect(t, dos != nil)
	if dos == nil {return}
	first := dos.first_cluster
	before := volume_fat_entry(v, first)
	_, claimed_before := v.journal.claimed[first]
	testing.expect(t, !claimed_before)
	testing.expect(t, v.alloc.by_cluster[first] == dos)

	testing.expect(t, volume_reconcile(v))

	_, claimed_after := v.journal.claimed[first]
	testing.expect(t, !claimed_after)
	testing.expect(t, v.alloc.by_cluster[first] == dos)
	testing.expect_value(t, volume_fat_entry(v, first), before)
}

@(private)
reconcile_test_stage_fat_set :: proc(t: ^testing.T, v: ^Volume, cluster, value: u32) {
	lba := journal_test_fat_lba(v, cluster)
	sector := read_test_sector(t, v, lba)
	offset := int(cluster % 128) * 4
	sector[offset] = u8(value)
	sector[offset + 1] = u8(value >> 8)
	sector[offset + 2] = u8(value >> 16)
	sector[offset + 3] = u8(value >> 24)
	testing.expect(t, volume_stage_write(v, lba, sector[:]))
}

@(private)
reconcile_test_child_named :: proc(parent: ^Node, name: string) -> ^Node {
	if parent == nil {return nil}
	for child in parent.children {
		if child.name == name {return child}
	}
	return nil
}

@(private)
reconcile_test_host_has_entry :: proc(dir, name: string) -> bool {
	infos, read_error := os.read_all_directory_by_path(dir, context.temp_allocator)
	if read_error != nil {return false}
	defer os.file_info_slice_delete(infos, context.temp_allocator)
	for info in infos {
		if strings.equal_fold(info.name, name) {return true}
	}
	return false
}
