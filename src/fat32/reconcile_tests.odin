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
reconcile_test_planned_detach_prepares_before_exact_commit :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {return}
	defer volume_discard(v)

	command := reconcile_test_child_named(v.alloc.root, "COMMAND.COM")
	dos := reconcile_test_child_named(v.alloc.root, "DOS")
	edit := reconcile_test_child_named(dos, "EDIT.HLP")
	if !testing.expect(t, command != nil && dos != nil && edit != nil) {return}
	command_chain := volume_chain(v, command.first_cluster, context.temp_allocator)
	if !testing.expect(t, len(command_chain) == 1) {return}
	old_edit := edit.first_cluster
	new_edit := v.alloc.next_free
	reconcile_test_stage_fat_set(t, v, new_edit, 0x0FFF_FFFF)
	reconcile_test_stage_fat_set(t, v, command_chain[0], old_edit)
	if v.frozen {return}
	v.journal.claimed[new_edit] = Claim{edit, 0}
	planned := make(map[^Node]Reconcile_Planned_Chain, context.temp_allocator)
	edit_key := Mirror_Key{dos.first_cluster, edit.short}
	planned_chain := [1]u32{new_edit}
	old_clusters := make(map[u32]bool, context.temp_allocator)
	new_clusters := make(map[u32]bool, context.temp_allocator)
	old_clusters[old_edit] = true
	new_clusters[new_edit] = true
	planned[edit] = Reconcile_Planned_Chain {
		key          = edit_key,
		chain        = planned_chain[:],
		old_clusters = old_clusters,
		new_clusters = new_clusters,
	}
	incoming := [2]u32{command_chain[0], old_edit}

	preflight, valid := reconcile_file_chain_owners_preflight(
		v,
		command,
		command.name,
		incoming[:],
		planned,
		context.temp_allocator,
	)
	testing.expect(t, valid)
	if !valid {return}
	testing.expect_value(t, len(preflight.planned_detaches), 1)
	testing.expect(t, v.alloc.by_cluster[old_edit] == edit)
	testing.expect(t, reconcile_ownership_preflight_prepare(v, &preflight))
	testing.expect(t, !v.journal.snapshotted[edit])
	testing.expect(t, v.alloc.by_cluster[old_edit] == edit)
	testing.expect(t, overlay_has(v, u32(journal_test_data_lba(v, old_edit) - PART_START_LBA)))
	testing.expect(t, !overlay_has(v, u32(journal_test_data_lba(v, new_edit) - PART_START_LBA)))
	new_claim, new_claimed := v.journal.claimed[new_edit]
	testing.expect(t, new_claimed)
	if new_claimed {testing.expect(t, new_claim.node == edit)}

	testing.expect(t, reconcile_planned_detaches_apply(v, preflight.planned_detaches[:]))
	testing.expect(t, v.alloc.by_cluster[old_edit] == nil)
	new_claim, new_claimed = v.journal.claimed[new_edit]
	testing.expect(t, new_claimed)
	if new_claimed {testing.expect(t, new_claim.node == edit)}
}

@(test)
reconcile_test_snapshot_preserves_guest_visible_orphan_tail :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {return}
	defer volume_discard(v)

	dos := reconcile_test_child_named(v.alloc.root, "DOS")
	edit := reconcile_test_child_named(dos, "EDIT.HLP")
	if !testing.expect(t, edit != nil) {return}
	sector: [SECTOR]u8
	for &byte, index in sector {byte = u8(index * 19 + 7)}
	lba := journal_test_data_lba(v, edit.first_cluster)
	testing.expect(t, volume_write(v, lba, sector[:]))
	testing.expect(t, orphan_has(v, edit.first_cluster))
	testing.expect(t, reconcile_snapshot_base_file(v, edit))
	testing.expect(t, v.journal.snapshotted[edit])

	got: [SECTOR]u8
	testing.expect(t, volume_read(v, lba, got[:]))
	testing.expect(t, got == sector)
	testing.expect(t, overlay_has(v, u32(lba - PART_START_LBA)))
}

@(test)
reconcile_test_snapshot_batches_contiguous_backing_reads :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {return}
	defer volume_discard(v)

	io := reconcile_test_child_named(v.alloc.root, "IO.SYS")
	if !testing.expect(t, io != nil) {return}
	chain := volume_chain(v, io.first_cluster, context.temp_allocator)
	if !testing.expect(t, len(chain) == 2 && chain[1] == chain[0] + 1) {return}
	staged: [SECTOR]u8
	for &byte, index in staged {byte = u8(index * 31 + 9)}
	for cluster in chain {
		first_lba := journal_test_data_lba(v, cluster)
		for sector in 0 ..< SECTORS_PER_CLUSTER {
			if sector % 2 == 0 {
				testing.expect(t, volume_stage_write(v, first_lba + u64(sector), staged[:]))
			}
		}
	}
	before := v.backing_read_opens

	testing.expect(t, reconcile_snapshot_base_file(v, io))
	testing.expect_value(t, v.backing_read_opens - before, u64(1))
	for cluster in chain {
		first_rel := v.alloc.geo.data_start + (cluster - 2) * SECTORS_PER_CLUSTER
		for sector in u32(0) ..< SECTORS_PER_CLUSTER {
			testing.expect(t, overlay_has(v, first_rel + sector))
		}
	}
	got: [SECTOR]u8
	testing.expect(t, volume_read(v, journal_test_data_lba(v, chain[0]), got[:]))
	testing.expect(t, got == staged)
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
	closed := false
	defer if !closed {volume_discard(v)}

	old_node := reconcile_test_child_named(v.alloc.root, "COMMAND.COM")
	if !testing.expect(t, old_node != nil) {return}
	old_cluster := old_node.first_cluster
	old_path := strings.clone(old_node.host_path, context.temp_allocator)
	new_path, _ := filepath.join({dir, "REUSED.TXT"})
	stale_head := v.alloc.next_free
	reused_tail := stale_head + 1
	v.journal.shadow_fat[stale_head] = reused_tail
	v.journal.shadow_fat[reused_tail] = 0x0FFF_FFFF
	stale_path, _ := filepath.join({dir, "DETACH2.BIN"})
	testing.expect(t, os.write_entire_file(stale_path, "stale") == nil)
	stale_short: [11]u8
	copy(stale_short[:], "DETACH2 BIN")
	stale_chain := [2]u32{stale_head, reused_tail}
	stale := managed_node_create(
		v,
		v.alloc.root,
		"DETACH2.BIN",
		stale_path,
		stale_short,
		stale_head,
		5,
		false,
		stale_chain[:],
	)
	if !testing.expect(t, stale != nil) {return}
	v.alloc.by_cluster[stale_head] = stale
	v.alloc.by_cluster[reused_tail] = stale
	stale_key := Mirror_Key{v.alloc.root.first_cluster, stale_short}
	v.journal.mirrored[stale_key] = Mirror_Entry {
		host_path     = strings.clone(stale_path, v.allocator),
		first_cluster = stale_head,
		size          = 5,
		base_node     = stale,
	}

	replacement := make([]u8, CLUSTER_BYTES + 100, context.temp_allocator)
	for &byte, index in replacement {byte = u8(index * 29 + 17)}
	// A prior retry may already have installed the new file while retaining the
	// old mirror. Reconciliation must adopt it, not attempt an impossible move.
	testing.expect(t, os.write_entire_file(new_path, replacement) == nil)

	reconcile_test_stage_fat_set(t, v, stale_head, 0x0FFF_FFFF)
	if v.frozen {return}
	reconcile_test_stage_fat_set(t, v, old_cluster, reused_tail)
	if v.frozen {return}
	cluster: [CLUSTER_BYTES]u8
	copy(cluster[:], replacement[:CLUSTER_BYTES])
	testing.expect(t, volume_stage_write(v, journal_test_data_lba(v, old_cluster), cluster[:]))
	tail: [CLUSTER_BYTES]u8
	copy(tail[:], replacement[CLUSTER_BYTES:])
	testing.expect(t, volume_stage_write(v, journal_test_data_lba(v, reused_tail), tail[:]))
	root_lba := journal_test_data_lba(v, v.alloc.root.first_cluster)
	root_sector := read_test_sector(t, v, root_lba)
	copy(root_sector[128:160], root_sector[96:128])
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
	new_chain := volume_chain(v, new_node.first_cluster, context.temp_allocator)
	if testing.expect(t, len(new_chain) == 2) {
		testing.expect_value(t, new_chain[1], reused_tail)
	}
	tail_claim, tail_claimed := v.journal.claimed[reused_tail]
	testing.expect(t, tail_claimed)
	if tail_claimed {testing.expect(t, tail_claim.node == new_node)}
	testing.expect(t, v.alloc.by_cluster[reused_tail] == nil)
	testing.expect_value(t, stale.cluster_len, u32(1))
	new_key := Mirror_Key{v.alloc.root.first_cluster, new_node.short}
	stored, mirrored := v.journal.mirrored[new_key]
	testing.expect(t, mirrored)
	if mirrored {testing.expect(t, stored.base_node == new_node)}

	before := volume_journal_storage_stats(v)
	testing.expect(t, volume_reconcile(v))
	after := volume_journal_storage_stats(v)
	testing.expect_value(t, after.streamed_guest_files, before.streamed_guest_files)
	testing.expect_value(t, after.dirty_sectors, u32(0))

	if !volume_close(v) {
		testing.expect(t, false)
		return
	}
	closed = true
	v2 := volume_open(dir, 2048)
	if !testing.expect(t, v2 != nil) {return}
	defer volume_discard(v2)
	reopened := reconcile_test_child_named(v2.alloc.root, "REUSED.TXT")
	if !testing.expect(t, reopened != nil) {return}
	testing.expect_value(t, reopened.size, u64(len(replacement)))
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
reconcile_test_donor_removal_failure_retries_before_target_commit :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		context.allocator = context.temp_allocator
		dir, v := decode_test_open(t)
		defer os.remove_all(dir)
		if v == nil {return}
		defer volume_discard(v)

		command := v.alloc.root.children[0]
		dos := v.alloc.root.children[1]
		donor := dos.children[0]
		old_command_cluster := command.first_cluster
		donor_cluster := donor.first_cluster
		command_key := Mirror_Key{v.alloc.root.first_cluster, command.short}
		donor_key := Mirror_Key{dos.first_cluster, donor.short}
		donor_path := strings.clone(donor.host_path, context.temp_allocator)
		want, read_error := os.read_entire_file(donor_path, context.temp_allocator)
		if !testing.expect(t, read_error == nil) {return}
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

		held, open_error := os.open(donor_path)
		if !testing.expect(t, open_error == nil) {return}
		defer if held != nil {_ = os.close(held)}
		testing.expect(t, !volume_reconcile(v))
		testing.expect(t, !v.frozen)
		target, target_ok := v.journal.mirrored[command_key]
		_, donor_ok := v.journal.mirrored[donor_key]
		testing.expect(t, target_ok && donor_ok)
		if target_ok {testing.expect_value(t, target.first_cluster, old_command_cluster)}
		testing.expect(t, volume_journal_storage_stats(v).dirty_sectors > 0)
		testing.expect(t, os.close(held) == nil)
		held = nil

		testing.expect(t, volume_reconcile(v))
		testing.expect(t, !v.frozen)
		testing.expect_value(t, command.first_cluster, donor_cluster)
		_, donor_ok = v.journal.mirrored[donor_key]
		testing.expect(t, !donor_ok)
		target, target_ok = v.journal.mirrored[command_key]
		testing.expect(t, target_ok)
		if target_ok {testing.expect(t, target.base_node == command)}
	}
}

@(test)
reconcile_test_donor_replacement_reclaims_detached_tail :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {return}
	closed := false
	defer if !closed {volume_discard(v)}

	command := reconcile_test_child_named(v.alloc.root, "COMMAND.COM")
	dos := reconcile_test_child_named(v.alloc.root, "DOS")
	donor := reconcile_test_child_named(dos, "EDIT.HLP")
	if !testing.expect(t, command != nil && dos != nil && donor != nil) {return}
	donor_path := strings.clone(donor.host_path, context.temp_allocator)
	donor_bytes, donor_error := os.read_entire_file(donor_path, context.temp_allocator)
	if !testing.expect(t, donor_error == nil) {return}
	donor_chain := volume_chain(v, donor.first_cluster, context.temp_allocator)
	if !testing.expect(t, len(donor_chain) > 0) {return}

	stale_head := v.alloc.next_free
	reused_tail := stale_head + 1
	v.journal.shadow_fat[stale_head] = reused_tail
	v.journal.shadow_fat[reused_tail] = 0x0FFF_FFFF
	stale_path, _ := filepath.join({dir, "DETACHED.BIN"})
	testing.expect(t, os.write_entire_file(stale_path, "stale") == nil)
	stale_short: [11]u8
	copy(stale_short[:], "DETACHEDBIN")
	stale_chain := [2]u32{stale_head, reused_tail}
	stale := managed_node_create(
		v,
		v.alloc.root,
		"DETACHED.BIN",
		stale_path,
		stale_short,
		stale_head,
		5,
		false,
		stale_chain[:],
	)
	if !testing.expect(t, stale != nil) {return}
	v.alloc.by_cluster[stale_head] = stale
	v.alloc.by_cluster[reused_tail] = stale
	stale_key := Mirror_Key{v.alloc.root.first_cluster, stale_short}
	v.journal.mirrored[stale_key] = Mirror_Entry {
		host_path     = strings.clone(stale_path, v.allocator),
		first_cluster = stale_head,
		size          = 5,
		base_node     = stale,
	}

	reconcile_test_stage_fat_set(t, v, stale_head, 0x0FFF_FFFF)
	if v.frozen {return}
	reconcile_test_stage_fat_set(t, v, donor_chain[len(donor_chain) - 1], reused_tail)
	if v.frozen {return}
	tail_data: [CLUSTER_BYTES]u8
	for &byte, index in tail_data {byte = u8(index * 17 + 3)}
	testing.expect(t, volume_stage_write(v, journal_test_data_lba(v, reused_tail), tail_data[:]))
	if v.frozen {return}
	root_lba := journal_test_data_lba(v, v.alloc.root.first_cluster)
	root_sector := read_test_sector(t, v, root_lba)
	new_size := u32(len(donor_chain) * CLUSTER_BYTES + 100)
	decode_test_put_entry(
		root_sector[:],
		0,
		"COMMAND COM",
		ATTR_FILE,
		donor.first_cluster,
		new_size,
	)
	testing.expect(t, volume_stage_write(v, root_lba, root_sector[:]))
	dos_lba := journal_test_data_lba(v, dos.first_cluster)
	dos_sector := read_test_sector(t, v, dos_lba)
	donor_offset := reconcile_test_entry_offset(dos_sector[:], donor.short)
	if !testing.expect(t, donor_offset >= 0) {return}
	dos_sector[donor_offset] = 0xE5
	testing.expect(t, volume_stage_write(v, dos_lba, dos_sector[:]))
	if v.frozen {return}
	tail_claim, tail_claimed := v.journal.claimed[reused_tail]
	testing.expect(t, tail_claimed)
	if tail_claimed {testing.expect(t, tail_claim.node == stale)}
	testing.expect(t, v.alloc.by_cluster[reused_tail] == stale)

	testing.expect(t, volume_reconcile(v))
	testing.expect(t, !v.frozen)
	testing.expect_value(t, command.first_cluster, donor.first_cluster)
	testing.expect_value(t, command.size, u64(new_size))
	command_chain := volume_chain(v, command.first_cluster, context.temp_allocator)
	if testing.expect(t, len(command_chain) == len(donor_chain) + 1) {
		testing.expect_value(t, command_chain[len(command_chain) - 1], reused_tail)
	}
	tail_claim, tail_claimed = v.journal.claimed[reused_tail]
	testing.expect(t, tail_claimed)
	if tail_claimed {testing.expect(t, tail_claim.node == command)}
	testing.expect(t, v.alloc.by_cluster[reused_tail] == nil)
	testing.expect_value(t, stale.cluster_len, u32(1))
	testing.expect(t, !os.exists(donor_path))
	want := make([]u8, int(new_size), context.temp_allocator)
	copy(want, donor_bytes)
	copy(want[len(donor_chain) * CLUSTER_BYTES:], tail_data[:100])
	contents, read_error := os.read_entire_file(command.host_path, context.temp_allocator)
	testing.expect(t, read_error == nil)
	if read_error == nil {testing.expect(t, string(contents) == string(want))}
	testing.expect(t, volume_reconcile(v))

	if !volume_close(v) {
		testing.expect(t, false)
		return
	}
	closed = true
	v2 := volume_open(dir, 2048)
	if !testing.expect(t, v2 != nil) {return}
	defer volume_discard(v2)
	reopened := reconcile_test_child_named(v2.alloc.root, "COMMAND.COM")
	if !testing.expect(t, reopened != nil) {return}
	reopened_chain := volume_chain(v2, reopened.first_cluster, context.temp_allocator)
	testing.expect(t, len(reopened_chain) == len(donor_chain) + 1)
	testing.expect_value(t, reopened.size, u64(new_size))
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
reconcile_test_directory_growth_reclaims_fat_freed_owner :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {return}
	defer volume_discard(v)

	dos := reconcile_test_child_named(v.alloc.root, "DOS")
	if !testing.expect(t, dos != nil) {return}
	dos_chain := volume_chain(v, dos.first_cluster, context.temp_allocator)
	if !testing.expect(t, len(dos_chain) > 0) {return}
	stale_head := v.alloc.next_free
	reused_tail := stale_head + 1
	v.journal.shadow_fat[stale_head] = reused_tail
	v.journal.shadow_fat[reused_tail] = 0x0FFF_FFFF
	stale_path, _ := filepath.join({dir, "STALE.BIN"})
	testing.expect(t, os.write_entire_file(stale_path, "stale") == nil)
	stale_short: [11]u8
	copy(stale_short[:], "STALE   BIN")
	stale_chain := [2]u32{stale_head, reused_tail}
	stale := managed_node_create(
		v,
		v.alloc.root,
		"STALE.BIN",
		stale_path,
		stale_short,
		stale_head,
		5,
		false,
		stale_chain[:],
	)
	if !testing.expect(t, stale != nil) {return}
	stale_key := Mirror_Key{v.alloc.root.first_cluster, stale_short}
	v.journal.mirrored[stale_key] = Mirror_Entry {
		host_path     = strings.clone(stale_path, v.allocator),
		first_cluster = stale_head,
		size          = 5,
		base_node     = stale,
	}

	reconcile_test_stage_fat_set(t, v, stale_head, 0)
	testing.expect(t, !v.frozen)
	reconcile_test_stage_fat_set(t, v, dos_chain[len(dos_chain) - 1], reused_tail)
	testing.expect(t, !v.frozen)
	tail_claim, tail_claimed := v.journal.claimed[reused_tail]
	testing.expect(t, tail_claimed)
	if tail_claimed {testing.expect(t, tail_claim.node == dos)}
	_, stale_head_claimed := v.journal.claimed[stale_head]
	testing.expect(t, !stale_head_claimed)
	testing.expect(t, managed_node_attached(v.alloc.root, stale))
	testing.expect(t, os.exists(stale_path))
	stored, mirrored := v.journal.mirrored[stale_key]
	testing.expect(t, mirrored)
	if mirrored {testing.expect(t, stored.base_node == stale)}
}

@(test)
reconcile_test_directory_growth_reclaims_detached_tail :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {return}
	defer volume_discard(v)

	dos := reconcile_test_child_named(v.alloc.root, "DOS")
	if !testing.expect(t, dos != nil) {return}
	dos_chain := volume_chain(v, dos.first_cluster, context.temp_allocator)
	if !testing.expect(t, len(dos_chain) > 0) {return}
	stale_head := v.alloc.next_free
	reused_tail := stale_head + 1
	v.journal.shadow_fat[stale_head] = reused_tail
	v.journal.shadow_fat[reused_tail] = 0x0FFF_FFFF
	stale_path, _ := filepath.join({dir, "DETACHED.BIN"})
	testing.expect(t, os.write_entire_file(stale_path, "stale") == nil)
	stale_short: [11]u8
	copy(stale_short[:], "DETACHEDBIN")
	stale_chain := [2]u32{stale_head, reused_tail}
	stale := managed_node_create(
		v,
		v.alloc.root,
		"DETACHED.BIN",
		stale_path,
		stale_short,
		stale_head,
		5,
		false,
		stale_chain[:],
	)
	if !testing.expect(t, stale != nil) {return}
	stale_key := Mirror_Key{v.alloc.root.first_cluster, stale_short}
	v.journal.mirrored[stale_key] = Mirror_Entry {
		host_path     = strings.clone(stale_path, v.allocator),
		first_cluster = stale_head,
		size          = 5,
		base_node     = stale,
	}

	reconcile_test_stage_fat_set(t, v, stale_head, 0x0FFF_FFFF)
	testing.expect(t, !v.frozen)
	reconcile_test_stage_fat_set(t, v, dos_chain[len(dos_chain) - 1], reused_tail)
	testing.expect(t, !v.frozen)
	head_claim, head_claimed := v.journal.claimed[stale_head]
	tail_claim, tail_claimed := v.journal.claimed[reused_tail]
	testing.expect(t, head_claimed && tail_claimed)
	if head_claimed {testing.expect(t, head_claim.node == stale)}
	if tail_claimed {testing.expect(t, tail_claim.node == dos)}
	testing.expect(t, volume_reconcile(v))
	testing.expect(t, !v.frozen)
	stored, mirrored := v.journal.mirrored[stale_key]
	testing.expect(t, mirrored)
	if mirrored {testing.expect(t, stored.base_node == stale)}
	testing.expect_value(t, stale.cluster_len, u32(1))
}

@(test)
reconcile_test_live_owner_blocks_directory_growth_transactionally :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {return}
	defer volume_discard(v)

	dos := reconcile_test_child_named(v.alloc.root, "DOS")
	if !testing.expect(t, dos != nil) {return}
	dos_chain := volume_chain(v, dos.first_cluster, context.temp_allocator)
	if !testing.expect(t, len(dos_chain) > 0) {return}
	freed_head := v.alloc.next_free
	freed_tail := freed_head + 1
	live_head := freed_head + 2
	live_tail := freed_head + 3
	v.journal.shadow_fat[freed_head] = freed_tail
	v.journal.shadow_fat[freed_tail] = 0x0FFF_FFFF
	v.journal.shadow_fat[live_head] = live_tail
	v.journal.shadow_fat[live_tail] = 0x0FFF_FFFF
	freed_path, _ := filepath.join({dir, "FREED.BIN"})
	live_path, _ := filepath.join({dir, "LIVE.BIN"})
	testing.expect(t, os.write_entire_file(freed_path, "freed") == nil)
	testing.expect(t, os.write_entire_file(live_path, "live") == nil)
	freed_short: [11]u8
	live_short: [11]u8
	copy(freed_short[:], "FREED   BIN")
	copy(live_short[:], "LIVE    BIN")
	freed_chain := [2]u32{freed_head, freed_tail}
	live_chain := [2]u32{live_head, live_tail}
	freed := managed_node_create(
		v,
		v.alloc.root,
		"FREED.BIN",
		freed_path,
		freed_short,
		freed_head,
		5,
		false,
		freed_chain[:],
	)
	live := managed_node_create(
		v,
		v.alloc.root,
		"LIVE.BIN",
		live_path,
		live_short,
		live_head,
		4,
		false,
		live_chain[:],
	)
	if !testing.expect(t, freed != nil && live != nil) {return}
	reconcile_test_stage_fat_set(t, v, freed_head, 0)
	if v.frozen {return}
	reconcile_test_stage_fat_set(t, v, freed_tail, live_tail)
	if v.frozen {return}

	last := dos_chain[len(dos_chain) - 1]
	lba := journal_test_fat_lba(v, last)
	sector := read_test_sector(t, v, lba)
	reconcile_test_fat_sector_set(sector[:], last, freed_tail)
	testing.expect(t, !volume_stage_write(v, lba, sector[:]))
	testing.expect(t, v.frozen)
	freed_claim, freed_claimed := v.journal.claimed[freed_tail]
	live_claim, live_claimed := v.journal.claimed[live_tail]
	testing.expect(t, freed_claimed && live_claimed)
	if freed_claimed {testing.expect(t, freed_claim.node == freed)}
	if live_claimed {testing.expect(t, live_claim.node == live)}
}

@(test)
reconcile_test_same_sector_reclaims_detached_synthesized_tail :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {return}
	defer volume_discard(v)

	dos := reconcile_test_child_named(v.alloc.root, "DOS")
	io := reconcile_test_child_named(v.alloc.root, "IO.SYS")
	if !testing.expect(t, dos != nil && io != nil) {return}
	dos_chain := volume_chain(v, dos.first_cluster, context.temp_allocator)
	io_chain := volume_chain(v, io.first_cluster, context.temp_allocator)
	if !testing.expect(t, len(dos_chain) > 0 && len(io_chain) == 2) {return}
	dos_last := dos_chain[len(dos_chain) - 1]
	reused_tail := io_chain[1]
	lba := journal_test_fat_lba(v, dos_last)
	if !testing.expect_value(t, journal_test_fat_lba(v, io.first_cluster), lba) {return}
	sector := read_test_sector(t, v, lba)
	reconcile_test_fat_sector_set(sector[:], dos_last, reused_tail)
	reconcile_test_fat_sector_set(sector[:], io.first_cluster, 0x0FFF_FFFF)

	testing.expect(t, volume_stage_write(v, lba, sector[:]))
	testing.expect(t, !v.frozen)
	tail_claim, tail_claimed := v.journal.claimed[reused_tail]
	testing.expect(t, tail_claimed)
	if tail_claimed {testing.expect(t, tail_claim.node == dos)}
	testing.expect(t, v.alloc.by_cluster[reused_tail] == nil)
	testing.expect(t, v.alloc.by_cluster[io.first_cluster] == io)
	testing.expect(t, managed_node_attached(v.alloc.root, io))
}

@(test)
reconcile_test_earlier_file_adopts_old_head_after_later_owner_moves :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {return}
	closed := false
	defer if !closed {volume_discard(v)}

	command := reconcile_test_child_named(v.alloc.root, "COMMAND.COM")
	dos := reconcile_test_child_named(v.alloc.root, "DOS")
	edit := reconcile_test_child_named(dos, "EDIT.HLP")
	if !testing.expect(t, command != nil && dos != nil && edit != nil) {return}
	command_node := command
	edit_node := edit
	command_chain := volume_chain(v, command.first_cluster, context.temp_allocator)
	edit_chain := volume_chain(v, edit.first_cluster, context.temp_allocator)
	if !testing.expect(t, len(command_chain) == 1 && len(edit_chain) == 1) {return}
	old_command := command.first_cluster
	old_edit := edit.first_cluster
	new_edit := v.alloc.next_free
	command_key := Mirror_Key{v.alloc.root.first_cluster, command.short}
	edit_key := Mirror_Key{dos.first_cluster, edit.short}

	reconcile_test_stage_fat_set(t, v, new_edit, 0x0FFF_FFFF)
	reconcile_test_stage_fat_set(t, v, old_command, old_edit)
	if v.frozen {return}
	tail: [CLUSTER_BYTES]u8
	for &byte, index in tail {byte = u8(index * 23 + 5)}
	replacement: [CLUSTER_BYTES]u8
	for &byte, index in replacement {byte = u8(index * 29 + 11)}
	testing.expect(t, volume_stage_write(v, journal_test_data_lba(v, old_edit), tail[:]))
	testing.expect(t, volume_stage_write(v, journal_test_data_lba(v, new_edit), replacement[:]))

	new_command_size := u32(CLUSTER_BYTES + 100)
	root_lba := journal_test_data_lba(v, v.alloc.root.first_cluster)
	root_sector := read_test_sector(t, v, root_lba)
	command_offset := reconcile_test_entry_offset(root_sector[:], command.short)
	if !testing.expect(t, command_offset >= 0) {return}
	decode_test_put_entry(
		root_sector[:],
		command_offset,
		"COMMAND COM",
		ATTR_FILE,
		old_command,
		new_command_size,
	)
	testing.expect(t, volume_stage_write(v, root_lba, root_sector[:]))
	dos_lba := journal_test_data_lba(v, dos.first_cluster)
	dos_sector := read_test_sector(t, v, dos_lba)
	edit_offset := reconcile_test_entry_offset(dos_sector[:], edit.short)
	if !testing.expect(t, edit_offset >= 0) {return}
	decode_test_put_entry(
		dos_sector[:],
		edit_offset,
		"EDIT    HLP",
		ATTR_FILE,
		new_edit,
		u32(edit.size),
	)
	testing.expect(t, volume_stage_write(v, dos_lba, dos_sector[:]))
	testing.expect_value(t, edit.first_cluster, old_edit)
	if v.frozen {return}

	testing.expect(t, volume_reconcile(v))
	testing.expect(t, !v.frozen)
	testing.expect(t, command == command_node && edit == edit_node)
	testing.expect_value(t, command.first_cluster, old_command)
	testing.expect_value(t, command.size, u64(new_command_size))
	testing.expect_value(t, edit.first_cluster, new_edit)
	command_chain = volume_chain(v, command.first_cluster, context.temp_allocator)
	edit_chain = volume_chain(v, edit.first_cluster, context.temp_allocator)
	if testing.expect(t, len(command_chain) == 2) {
		testing.expect_value(t, command_chain[1], old_edit)
	}
	testing.expect(t, len(edit_chain) == 1)
	command_claim, command_claimed := v.journal.claimed[old_edit]
	edit_claim, edit_claimed := v.journal.claimed[new_edit]
	testing.expect(t, command_claimed && edit_claimed)
	if command_claimed {testing.expect(t, command_claim.node == command)}
	if edit_claimed {testing.expect(t, edit_claim.node == edit)}
	testing.expect(t, v.alloc.by_cluster[old_edit] == nil)
	testing.expect(t, v.alloc.by_cluster[new_edit] == nil)
	command_mirror, command_mirrored := v.journal.mirrored[command_key]
	edit_mirror, edit_mirrored := v.journal.mirrored[edit_key]
	testing.expect(t, command_mirrored && edit_mirrored)
	if command_mirrored {
		testing.expect(t, command_mirror.base_node == command_node)
		testing.expect_value(t, command_mirror.size, new_command_size)
	}
	if edit_mirrored {
		testing.expect(t, edit_mirror.base_node == edit_node)
		testing.expect_value(t, edit_mirror.first_cluster, new_edit)
	}

	command_host, command_error := os.read_entire_file(command.host_path, context.temp_allocator)
	edit_host, edit_error := os.read_entire_file(edit.host_path, context.temp_allocator)
	testing.expect(t, command_error == nil && edit_error == nil)
	if command_error == nil && testing.expect_value(t, len(command_host), int(new_command_size)) {
		testing.expect(t, string(command_host[CLUSTER_BYTES:]) == string(tail[:100]))
	}
	if edit_error == nil && testing.expect_value(t, len(edit_host), int(edit.size)) {
		testing.expect(t, string(edit_host) == string(replacement[:len(edit_host)]))
	}
	before_retry := volume_journal_storage_stats(v)
	testing.expect(t, volume_reconcile(v))
	after_retry := volume_journal_storage_stats(v)
	testing.expect_value(t, after_retry.streamed_guest_files, before_retry.streamed_guest_files)
	testing.expect_value(t, after_retry.streamed_guest_bytes, before_retry.streamed_guest_bytes)
	testing.expect_value(t, after_retry.dirty_sectors, u32(0))

	if !volume_close(v) {
		testing.expect(t, false)
		return
	}
	closed = true
	v2 := volume_open(dir, 2048)
	if !testing.expect(t, v2 != nil) {return}
	defer volume_discard(v2)
	reopened_command := reconcile_test_child_named(v2.alloc.root, "COMMAND.COM")
	reopened_dos := reconcile_test_child_named(v2.alloc.root, "DOS")
	reopened_edit := reconcile_test_child_named(reopened_dos, "EDIT.HLP")
	if !testing.expect(t, reopened_command != nil && reopened_edit != nil) {return}
	testing.expect_value(t, reopened_command.size, u64(new_command_size))
	testing.expect_value(t, reopened_edit.size, u64(100))
	testing.expect(t, len(volume_chain(v2, reopened_command.first_cluster, context.temp_allocator)) == 2)
	testing.expect(t, len(volume_chain(v2, reopened_edit.first_cluster, context.temp_allocator)) == 1)
}

@(test)
reconcile_test_later_file_adopts_old_head_after_earlier_owner_moves :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {return}
	defer volume_discard(v)

	command := reconcile_test_child_named(v.alloc.root, "COMMAND.COM")
	io := reconcile_test_child_named(v.alloc.root, "IO.SYS")
	if !testing.expect(t, command != nil && io != nil) {return}
	command_contents, command_error := os.read_entire_file(command.host_path, context.temp_allocator)
	if !testing.expect(t, command_error == nil) {return}
	old_command := command.first_cluster
	new_command := v.alloc.next_free
	reconcile_test_stage_fat_set(t, v, new_command, 0x0FFF_FFFF)
	if v.frozen {return}
	new_block: [CLUSTER_BYTES]u8
	copy(new_block[:], command_contents)
	testing.expect(t, volume_stage_write(v, journal_test_data_lba(v, new_command), new_block[:]))

	root_lba := journal_test_data_lba(v, v.alloc.root.first_cluster)
	root_sector := read_test_sector(t, v, root_lba)
	command_offset := reconcile_test_entry_offset(root_sector[:], command.short)
	io_offset := reconcile_test_entry_offset(root_sector[:], io.short)
	if !testing.expect(t, command_offset >= 0 && io_offset > command_offset) {return}
	decode_test_put_entry(
		root_sector[:],
		command_offset,
		"COMMAND COM",
		ATTR_FILE,
		new_command,
		u32(len(command_contents)),
	)
	decode_test_put_entry(
		root_sector[:],
		io_offset,
		"IO      SYS",
		ATTR_FILE,
		old_command,
		u32(len(command_contents)),
	)
	testing.expect(t, volume_stage_write(v, root_lba, root_sector[:]))
	if v.frozen {return}

	testing.expect(t, volume_reconcile(v))
	testing.expect(t, !v.frozen)
	testing.expect_value(t, command.first_cluster, new_command)
	testing.expect_value(t, io.first_cluster, old_command)
	testing.expect(t, v.journal.snapshotted[command])
	command_host, command_host_error := os.read_entire_file(command.host_path, context.temp_allocator)
	io_host, io_host_error := os.read_entire_file(io.host_path, context.temp_allocator)
	testing.expect(t, command_host_error == nil && io_host_error == nil)
	if command_host_error == nil {
		testing.expect(t, string(command_host) == string(command_contents))
	}
	if io_host_error == nil {
		testing.expect(t, string(io_host) == string(command_contents))
	}
	before_retry := volume_journal_storage_stats(v)
	testing.expect(t, volume_reconcile(v))
	after_retry := volume_journal_storage_stats(v)
	testing.expect_value(t, after_retry.streamed_guest_files, before_retry.streamed_guest_files)
	testing.expect_value(t, after_retry.streamed_guest_bytes, before_retry.streamed_guest_bytes)
}

@(test)
reconcile_test_invalid_planned_destination_blocks_earlier_handoff :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {return}
	defer volume_discard(v)

	command := reconcile_test_child_named(v.alloc.root, "COMMAND.COM")
	dos := reconcile_test_child_named(v.alloc.root, "DOS")
	edit := reconcile_test_child_named(dos, "EDIT.HLP")
	io := reconcile_test_child_named(v.alloc.root, "IO.SYS")
	if !testing.expect(t, command != nil && dos != nil && edit != nil && io != nil) {return}
	command_contents, command_error := os.read_entire_file(command.host_path, context.temp_allocator)
	edit_contents, edit_error := os.read_entire_file(edit.host_path, context.temp_allocator)
	io_contents, io_error := os.read_entire_file(io.host_path, context.temp_allocator)
	if !testing.expect(t, command_error == nil && edit_error == nil && io_error == nil) {return}
	old_command := command.first_cluster
	old_edit := edit.first_cluster
	new_edit := v.alloc.next_free

	reconcile_test_stage_fat_set(t, v, new_edit, io.first_cluster)
	reconcile_test_stage_fat_set(t, v, old_command, old_edit)
	if v.frozen {return}
	root_lba := journal_test_data_lba(v, v.alloc.root.first_cluster)
	root_sector := read_test_sector(t, v, root_lba)
	command_offset := reconcile_test_entry_offset(root_sector[:], command.short)
	if !testing.expect(t, command_offset >= 0) {return}
	decode_test_put_entry(
		root_sector[:],
		command_offset,
		"COMMAND COM",
		ATTR_FILE,
		old_command,
		u32(CLUSTER_BYTES + 100),
	)
	testing.expect(t, volume_stage_write(v, root_lba, root_sector[:]))
	dos_lba := journal_test_data_lba(v, dos.first_cluster)
	dos_sector := read_test_sector(t, v, dos_lba)
	edit_offset := reconcile_test_entry_offset(dos_sector[:], edit.short)
	if !testing.expect(t, edit_offset >= 0) {return}
	decode_test_put_entry(
		dos_sector[:],
		edit_offset,
		"EDIT    HLP",
		ATTR_FILE,
		new_edit,
		u32(edit.size),
	)
	testing.expect(t, volume_stage_write(v, dos_lba, dos_sector[:]))
	if v.frozen {return}

	testing.expect(t, !volume_reconcile(v))
	testing.expect(t, v.frozen)
	got_command, got_command_error := os.read_entire_file(command.host_path, context.temp_allocator)
	got_edit, got_edit_error := os.read_entire_file(edit.host_path, context.temp_allocator)
	got_io, got_io_error := os.read_entire_file(io.host_path, context.temp_allocator)
	testing.expect(t, got_command_error == nil && got_edit_error == nil && got_io_error == nil)
	if got_command_error == nil {testing.expect(t, string(got_command) == string(command_contents))}
	if got_edit_error == nil {testing.expect(t, string(got_edit) == string(edit_contents))}
	if got_io_error == nil {testing.expect(t, string(got_io) == string(io_contents))}
	testing.expect_value(t, command.first_cluster, old_command)
	testing.expect_value(t, edit.first_cluster, old_edit)
	testing.expect(t, v.alloc.by_cluster[old_edit] == edit)
}

@(private = "file")
reconcile_test_shared_live_tail_case :: proc(t: ^testing.T, oversized: bool) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {return}
	defer volume_discard(v)

	command := reconcile_test_child_named(v.alloc.root, "COMMAND.COM")
	dos := reconcile_test_child_named(v.alloc.root, "DOS")
	edit := reconcile_test_child_named(dos, "EDIT.HLP")
	io := reconcile_test_child_named(v.alloc.root, "IO.SYS")
	if !testing.expect(t, command != nil && dos != nil && edit != nil && io != nil) {return}
	command_contents, command_error := os.read_entire_file(command.host_path, context.temp_allocator)
	edit_contents, edit_error := os.read_entire_file(edit.host_path, context.temp_allocator)
	io_contents, io_error := os.read_entire_file(io.host_path, context.temp_allocator)
	if !testing.expect(t, command_error == nil && edit_error == nil && io_error == nil) {return}
	old_command := command.first_cluster
	old_edit := edit.first_cluster
	new_edit := v.alloc.next_free
	shared_tail := new_edit + 1
	io_chain := volume_chain(v, io.first_cluster, context.temp_allocator)
	if !testing.expect(t, len(io_chain) == 2) {return}

	reconcile_test_stage_fat_set(t, v, new_edit, shared_tail)
	reconcile_test_stage_fat_set(t, v, io_chain[len(io_chain) - 1], shared_tail)
	reconcile_test_stage_fat_set(t, v, shared_tail, 0x0FFF_FFFF)
	reconcile_test_stage_fat_set(t, v, old_command, old_edit)
	if v.frozen {return}
	root_lba := journal_test_data_lba(v, v.alloc.root.first_cluster)
	root_sector := read_test_sector(t, v, root_lba)
	command_offset := reconcile_test_entry_offset(root_sector[:], command.short)
	if !testing.expect(t, command_offset >= 0) {return}
	decode_test_put_entry(
		root_sector[:],
		command_offset,
		"COMMAND COM",
		ATTR_FILE,
		old_command,
		u32(CLUSTER_BYTES + 100),
	)
	if oversized {
		io_offset := reconcile_test_entry_offset(root_sector[:], io.short)
		if !testing.expect(t, io_offset >= 0) {return}
		decode_test_put_entry(
			root_sector[:],
			io_offset,
			"IO      SYS",
			ATTR_FILE,
			io.first_cluster,
			u32((len(io_chain) + 2) * CLUSTER_BYTES),
		)
	}
	testing.expect(t, volume_stage_write(v, root_lba, root_sector[:]))
	dos_lba := journal_test_data_lba(v, dos.first_cluster)
	dos_sector := read_test_sector(t, v, dos_lba)
	edit_offset := reconcile_test_entry_offset(dos_sector[:], edit.short)
	if !testing.expect(t, edit_offset >= 0) {return}
	decode_test_put_entry(
		dos_sector[:],
		edit_offset,
		"EDIT    HLP",
		ATTR_FILE,
		new_edit,
		u32(edit.size),
	)
	testing.expect(t, volume_stage_write(v, dos_lba, dos_sector[:]))
	if v.frozen {return}

	testing.expect(t, !volume_reconcile(v))
	testing.expect(t, v.frozen)
	got_command, got_command_error := os.read_entire_file(command.host_path, context.temp_allocator)
	got_edit, got_edit_error := os.read_entire_file(edit.host_path, context.temp_allocator)
	got_io, got_io_error := os.read_entire_file(io.host_path, context.temp_allocator)
	testing.expect(t, got_command_error == nil && got_edit_error == nil && got_io_error == nil)
	if got_command_error == nil {testing.expect(t, string(got_command) == string(command_contents))}
	if got_edit_error == nil {testing.expect(t, string(got_edit) == string(edit_contents))}
	if got_io_error == nil {testing.expect(t, string(got_io) == string(io_contents))}
	testing.expect_value(t, command.first_cluster, old_command)
	testing.expect_value(t, edit.first_cluster, old_edit)
	testing.expect(t, v.alloc.by_cluster[old_edit] == edit)
}

@(test)
reconcile_test_shared_live_tail_blocks_earlier_handoff :: proc(t: ^testing.T) {
	reconcile_test_shared_live_tail_case(t, false)
}

@(test)
reconcile_test_shared_oversized_tail_blocks_earlier_handoff :: proc(t: ^testing.T) {
	reconcile_test_shared_live_tail_case(t, true)
}

@(test)
reconcile_test_moved_live_owner_still_blocks_shared_old_head :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {return}
	defer volume_discard(v)

	command := reconcile_test_child_named(v.alloc.root, "COMMAND.COM")
	dos := reconcile_test_child_named(v.alloc.root, "DOS")
	edit := reconcile_test_child_named(dos, "EDIT.HLP")
	if !testing.expect(t, command != nil && dos != nil && edit != nil) {return}
	command_host, command_error := os.read_entire_file(command.host_path, context.temp_allocator)
	edit_host, edit_error := os.read_entire_file(edit.host_path, context.temp_allocator)
	if !testing.expect(t, command_error == nil && edit_error == nil) {return}
	old_command := command.first_cluster
	old_command_size := command.size
	old_edit := edit.first_cluster
	old_edit_size := edit.size
	new_edit := v.alloc.next_free
	command_key := Mirror_Key{v.alloc.root.first_cluster, command.short}
	edit_key := Mirror_Key{dos.first_cluster, edit.short}
	command_mirror := v.journal.mirrored[command_key]
	edit_mirror := v.journal.mirrored[edit_key]

	reconcile_test_stage_fat_set(t, v, new_edit, old_edit)
	reconcile_test_stage_fat_set(t, v, old_command, old_edit)
	if v.frozen {return}
	root_lba := journal_test_data_lba(v, v.alloc.root.first_cluster)
	root_sector := read_test_sector(t, v, root_lba)
	command_offset := reconcile_test_entry_offset(root_sector[:], command.short)
	if !testing.expect(t, command_offset >= 0) {return}
	decode_test_put_entry(
		root_sector[:],
		command_offset,
		"COMMAND COM",
		ATTR_FILE,
		old_command,
		u32(CLUSTER_BYTES + 100),
	)
	testing.expect(t, volume_stage_write(v, root_lba, root_sector[:]))
	dos_lba := journal_test_data_lba(v, dos.first_cluster)
	dos_sector := read_test_sector(t, v, dos_lba)
	edit_offset := reconcile_test_entry_offset(dos_sector[:], edit.short)
	if !testing.expect(t, edit_offset >= 0) {return}
	decode_test_put_entry(
		dos_sector[:],
		edit_offset,
		"EDIT    HLP",
		ATTR_FILE,
		new_edit,
		u32(edit.size),
	)
	testing.expect(t, volume_stage_write(v, dos_lba, dos_sector[:]))
	if v.frozen {return}

	testing.expect(t, !volume_reconcile(v))
	testing.expect(t, v.frozen)
	got_command, got_command_error := os.read_entire_file(command.host_path, context.temp_allocator)
	got_edit, got_edit_error := os.read_entire_file(edit.host_path, context.temp_allocator)
	testing.expect(t, got_command_error == nil && got_edit_error == nil)
	if got_command_error == nil {testing.expect(t, string(got_command) == string(command_host))}
	if got_edit_error == nil {testing.expect(t, string(got_edit) == string(edit_host))}
	testing.expect_value(t, command.first_cluster, old_command)
	testing.expect_value(t, command.size, old_command_size)
	testing.expect_value(t, edit.first_cluster, old_edit)
	testing.expect_value(t, edit.size, old_edit_size)
	testing.expect(t, v.alloc.by_cluster[old_edit] == edit)
	if claim, claimed := v.journal.claimed[old_edit]; claimed {
		testing.expect(t, claim.node == edit)
	}
	current_command_mirror := v.journal.mirrored[command_key]
	current_edit_mirror := v.journal.mirrored[edit_key]
	testing.expect_value(t, current_command_mirror.first_cluster, command_mirror.first_cluster)
	testing.expect_value(t, current_command_mirror.size, command_mirror.size)
	testing.expect(t, current_command_mirror.base_node == command_mirror.base_node)
	testing.expect_value(t, current_edit_mirror.first_cluster, edit_mirror.first_cluster)
	testing.expect_value(t, current_edit_mirror.size, edit_mirror.size)
	testing.expect(t, current_edit_mirror.base_node == edit_mirror.base_node)
	testing.expect(t, volume_journal_storage_stats(v).dirty_sectors > 0)
}

@(test)
reconcile_test_live_tail_overlap_cannot_be_stolen_during_reconcile :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {return}
	defer volume_discard(v)

	command := reconcile_test_child_named(v.alloc.root, "COMMAND.COM")
	io := reconcile_test_child_named(v.alloc.root, "IO.SYS")
	if !testing.expect(t, command != nil && io != nil) {return}
	want, read_error := os.read_entire_file(command.host_path, context.temp_allocator)
	if !testing.expect(t, read_error == nil) {return}
	command_chain := volume_chain(v, command.first_cluster, context.temp_allocator)
	if !testing.expect(t, len(command_chain) > 0) {return}
	reconcile_test_stage_fat_set(t, v, command_chain[len(command_chain) - 1], io.first_cluster)
	if v.frozen {return}
	root_lba := journal_test_data_lba(v, v.alloc.root.first_cluster)
	root_sector := read_test_sector(t, v, root_lba)
	decode_test_put_entry(
		root_sector[:],
		0,
		"COMMAND COM",
		ATTR_FILE,
		command.first_cluster,
		u32(CLUSTER_BYTES + 100),
	)
	testing.expect(t, volume_stage_write(v, root_lba, root_sector[:]))
	if v.frozen {return}

	testing.expect(t, !volume_reconcile(v))
	testing.expect(t, v.frozen)
	got, got_error := os.read_entire_file(command.host_path, context.temp_allocator)
	testing.expect(t, got_error == nil)
	testing.expect(t, string(got) == string(want))
	_, stolen := v.journal.claimed[io.first_cluster]
	testing.expect(t, !stolen)
	testing.expect(t, v.alloc.by_cluster[io.first_cluster] == io)
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
	reconcile_test_fat_sector_set(sector[:], cluster, value)
	testing.expect(t, volume_stage_write(v, lba, sector[:]))
}

@(private)
reconcile_test_fat_sector_set :: proc(sector: []u8, cluster, value: u32) {
	offset := int(cluster % 128) * 4
	sector[offset] = u8(value)
	sector[offset + 1] = u8(value >> 8)
	sector[offset + 2] = u8(value >> 16)
	sector[offset + 3] = u8(value >> 24)
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
