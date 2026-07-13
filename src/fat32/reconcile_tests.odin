// SPDX-License-Identifier: GPL-3.0-only
package fat32

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

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
	overlay_count := len(v.journal.overlay)
	testing.expect(t, overlay_count >= 3)
	testing.expect(t, !volume_close(v))
	testing.expect_value(t, len(v.journal.overlay), overlay_count)
	testing.expect(t, !v.frozen)

	testing.expect(t, os.remove(blocked) == nil)
	testing.expect(t, volume_close(v))
	closed = true
	contents, read_error := os.read_entire_file(blocked, context.temp_allocator)
	testing.expect(t, read_error == nil)
	testing.expect_value(t, string(contents), "SAFE")
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
	overlay_count := len(v.journal.overlay)

	testing.expect(t, !reconcile_snapshot_base_file(v, node))
	testing.expect(t, fired)
	testing.expect(t, v.frozen)
	testing.expect(t, !v.journal.snapshotted[node])
	testing.expect_value(t, len(v.journal.overlay), overlay_count)
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
