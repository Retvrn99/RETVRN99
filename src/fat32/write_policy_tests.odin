// SPDX-License-Identifier: GPL-3.0-only
package fat32

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

Protection_Test_Failure :: struct {
	fired:  bool,
	useful: bool,
}

protection_test_arm :: proc(v: ^Volume, failure: ^Protection_Test_Failure) {
	v.fail_ctx = failure
	v.on_fail = proc(ctx: rawptr, msg: string) {
		f := (^Protection_Test_Failure)(ctx)
		f.fired = true
		f.useful = strings.contains(msg, "protected system disk rejected")
	}
}

protection_test_host_unchanged :: proc(
	t: ^testing.T,
	node: ^Node,
	want: []u8,
	loc := #caller_location,
) {
	got, err := os.read_entire_file(node.host_path, context.temp_allocator)
	testing.expect(t, err == nil, loc = loc)
	testing.expect(t, string(got) == string(want), loc = loc)
}

protection_test_put32 :: proc(b: []u8, off: int, value: u32) {
	b[off] = u8(value)
	b[off + 1] = u8(value >> 8)
	b[off + 2] = u8(value >> 16)
	b[off + 3] = u8(value >> 24)
}

protection_test_stage_fat_set :: proc(t: ^testing.T, v: ^Volume, cluster, value: u32) -> bool {
	lba := journal_test_fat_lba(v, cluster)
	sector := read_test_sector(t, v, lba)
	protection_test_put32(sector[:], int(cluster % 128) * 4, value)
	return volume_stage_write(v, lba, sector[:])
}

protection_test_stage_fat_pair :: proc(
	t: ^testing.T,
	v: ^Volume,
	first_cluster, first_value, second_cluster, second_value: u32,
) -> bool {
	first_entry_lba := journal_test_fat_lba(v, first_cluster)
	second_entry_lba := journal_test_fat_lba(v, second_cluster)
	start_lba := min(first_entry_lba, second_entry_lba)
	end_lba := max(first_entry_lba, second_entry_lba)
	sectors := make([]u8, int(end_lba - start_lba + 1) * SECTOR, context.temp_allocator)
	testing.expect(t, volume_read(v, start_lba, sectors))
	first_offset := int(first_entry_lba - start_lba) * SECTOR + int(first_cluster % 128) * 4
	second_offset := int(second_entry_lba - start_lba) * SECTOR + int(second_cluster % 128) * 4
	protection_test_put32(sectors, first_offset, first_value)
	protection_test_put32(sectors, second_offset, second_value)
	return volume_stage_write(v, start_lba, sectors)
}

protection_test_add_long_root_files :: proc(t: ^testing.T, dir: string, count: int) {
	padding := "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz"
	for i in 0 ..< count {
		name := fmt.tprintf("TAIL%02d-%s.TXT", i, padding)
		path, path_error := filepath.join({dir, name}, context.temp_allocator)
		testing.expect(t, path_error == nil)
		data := [5]u8{'T', 'A', 'I', 'L', u8(i)}
		testing.expect(t, os.write_entire_file(path, data[:]) == nil)
	}
}

@(test)
protection_test_fdisk_mbr_write :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := fat32_test_fixture(t)
	defer os.remove_all(dir)
	v := volume_open(dir, 2048)
	testing.expect(t, v != nil)
	if v == nil {
		return
	}
	command := v.alloc.root.children[0]
	want, _ := os.read_entire_file(command.host_path, context.temp_allocator)
	failure: Protection_Test_Failure
	protection_test_arm(v, &failure)

	mbr := make_mbr(v.alloc.geo.total_sectors)
	mbr[446 + 4] = 0x06
	testing.expect(t, !volume_write(v, 0, mbr[:]))
	testing.expect(t, v.frozen && failure.fired && failure.useful)
	protection_test_host_unchanged(t, command, want)
}

@(test)
protection_test_compatible_boot_code_is_ignored_but_layout_is_protected :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := fat32_test_fixture(t)
	defer os.remove_all(dir)

	v := volume_open(dir, 2048)
	original_mbr := read_test_sector(t, v, 0)
	compatible_mbr := make_mbr(v.alloc.geo.total_sectors)
	compatible_mbr[0] = 0xFA
	compatible_mbr[440] = 0x98
	testing.expect(t, volume_write(v, 0, compatible_mbr[:]))
	testing.expect(t, !v.frozen)
	testing.expect(t, read_test_sector(t, v, 0) == original_mbr)

	original := read_test_sector(t, v, PART_START_LBA)
	compatible := make_vbr(&v.alloc.geo, v.alloc.geo.total_sectors)
	copy(compatible[3:11], "MSWIN4.1")
	compatible[90] = 0x90
	testing.expect(t, volume_write(v, PART_START_LBA, compatible[:]))
	testing.expect(t, !v.frozen)
	testing.expect(t, read_test_sector(t, v, PART_START_LBA) == original)

	v2 := volume_open(dir, 2048)
	failure: Protection_Test_Failure
	protection_test_arm(v2, &failure)
	changed_layout := make_vbr(&v2.alloc.geo, v2.alloc.geo.total_sectors)
	changed_layout[13] = changed_layout[13] * 2
	testing.expect(t, !volume_write(v2, PART_START_LBA, changed_layout[:]))
	testing.expect(t, v2.frozen && failure.useful)

	v3 := volume_open(dir, 2048)
	reserved_boot: [SECTOR]u8
	reserved_boot[0] = 0xF6
	original_reserved := read_test_sector(t, v3, PART_START_LBA + 2)
	testing.expect(t, volume_write(v3, PART_START_LBA + 2, reserved_boot[:]))
	testing.expect(t, !v3.frozen)
	testing.expect(t, read_test_sector(t, v3, PART_START_LBA + 2) == original_reserved)

	v4 := volume_open(dir, 2048)
	failure2: Protection_Test_Failure
	protection_test_arm(v4, &failure2)
	reserved_layout: [SECTOR]u8
	reserved_layout[0] = 0xF6
	testing.expect(t, !volume_write(v4, PART_START_LBA + 3, reserved_layout[:]))
	testing.expect(t, v4.frozen && failure2.useful)
}

protection_test_add_root_files :: proc(t: ^testing.T, dir: string, count: int) {
	for i in 0 ..< count {
		name := fmt.tprintf("F%07d.BIN", i)
		path, path_error := filepath.join({dir, name}, context.temp_allocator)
		testing.expect(t, path_error == nil)
		data := [1]u8{u8(i)}
		testing.expect(t, os.write_entire_file(path, data[:]) == nil)
	}
}

@(test)
protection_test_format_fat_and_root_writes_preserve_files :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := fat32_test_fixture(t)
	defer os.remove_all(dir)

	v := volume_open(dir, 2048)
	command := v.alloc.root.children[0]
	want, _ := os.read_entire_file(command.host_path, context.temp_allocator)
	failure: Protection_Test_Failure
	protection_test_arm(v, &failure)
	fat: [SECTOR]u8
	protection_test_put32(fat[:], 0, 0x0FFFFFF8)
	protection_test_put32(fat[:], 4, 0x0FFFFFFF)
	protection_test_put32(fat[:], 8, 0x00000000)
	testing.expect(t, !volume_write(v, journal_test_fat_lba(v, 0), fat[:]))
	testing.expect(t, v.frozen && failure.useful)
	protection_test_host_unchanged(t, command, want)

	v2 := volume_open(dir, 2048)
	command2 := v2.alloc.root.children[0]
	failure2: Protection_Test_Failure
	protection_test_arm(v2, &failure2)
	fresh_root: [SECTOR]u8
	testing.expect(t, !volume_write(v2, journal_test_data_lba(v2, 2), fresh_root[:]))
	testing.expect(t, v2.frozen && failure2.useful)
	protection_test_host_unchanged(t, command2, want)

	v3 := volume_open(dir, 2048)
	command3 := v3.alloc.root.children[0]
	failure3: Protection_Test_Failure
	protection_test_arm(v3, &failure3)
	labeled_root: [SECTOR]u8
	copy(labeled_root[:11], "SYSTEM     ")
	labeled_root[11] = 0x08
	testing.expect(t, !volume_write(v3, journal_test_data_lba(v3, 2), labeled_root[:]))
	testing.expect(t, v3.frozen && failure3.useful)
	protection_test_host_unchanged(t, command3, want)
}

@(test)
protection_test_format_later_root_sector_is_rejected_after_fat_free :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := fat32_test_fixture(t)
	defer os.remove_all(dir)
	protection_test_add_root_files(t, dir, 20)

	v := volume_open(dir, 2048)
	testing.expect(t, v != nil)
	if v == nil {
		return
	}
	target: ^Node
	target_index := -1
	for child, index in v.alloc.root.children {
		if index >= 16 && index < 32 && !child.is_dir && child.first_cluster >= 2 {
			target = child
			target_index = index
			break
		}
	}
	testing.expect(t, target != nil)
	if target == nil {
		return
	}
	target_path := strings.clone(target.host_path, context.temp_allocator)
	fat_lba := journal_test_fat_lba(v, target.first_cluster)
	fat := read_test_sector(t, v, fat_lba)
	protection_test_put32(fat[:], int(target.first_cluster % 128) * 4, 0)
	testing.expect(t, volume_write(v, fat_lba, fat[:]))
	testing.expect(t, os.exists(target_path))

	failure: Protection_Test_Failure
	protection_test_arm(v, &failure)
	fresh: [SECTOR]u8
	root_lba := journal_test_data_lba(v, v.alloc.root.first_cluster)
	root_sector := u64(target_index / (SECTOR / 32))
	testing.expect(t, root_sector > 0)
	testing.expect(t, !volume_write(v, root_lba + root_sector, fresh[:]))
	testing.expect(t, v.frozen && failure.useful)
	testing.expect(t, os.exists(target_path))
}

@(test)
protection_test_staged_last_root_entry_delete_is_allowed :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := fat32_test_fixture(t)
	defer os.remove_all(dir)
	protection_test_add_root_files(t, dir, 14)

	v := volume_open(dir, 2048)
	testing.expect(t, v != nil)
	if v == nil {return}
	closed := false
	defer if !closed {volume_discard(v)}
	root := v.alloc.root
	testing.expect_value(t, len(root.children), 17)
	if len(root.children) != 17 {return}
	target := root.children[16]
	target_path := strings.clone(target.host_path, context.temp_allocator)
	root_lba := journal_test_data_lba(v, root.first_cluster)
	sector_lba := root_lba + 1
	sector := read_test_sector(t, v, sector_lba)
	testing.expect(t, sector[0] != 0 && sector[0] != 0xE5)
	testing.expect_value(t, sector[32], u8(0))

	for cluster in target.first_cluster ..< target.first_cluster + target.cluster_len {
		testing.expect(t, protection_test_stage_fat_set(t, v, cluster, 0))
	}
	sector[0] = 0xE5
	testing.expect(t, volume_stage_write(v, sector_lba, sector[:]))
	testing.expect(t, !v.frozen)
	testing.expect(t, volume_reconcile(v))
	testing.expect(t, !os.exists(target_path))
	if !volume_close(v) {
		testing.expect(t, false)
		return
	}
	closed = true
}

@(test)
protection_test_format_later_root_cluster_is_rejected :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := fat32_test_fixture(t)
	defer os.remove_all(dir)
	protection_test_add_root_files(t, dir, 130)

	v := volume_open(dir, 2048)
	testing.expect(t, v != nil)
	if v == nil {
		return
	}
	testing.expect(t, v.alloc.root.cluster_len > 1)
	if v.alloc.root.cluster_len <= 1 {
		return
	}
	failure: Protection_Test_Failure
	protection_test_arm(v, &failure)
	fresh: [SECTOR]u8
	second_cluster := v.alloc.root.first_cluster + 1
	testing.expect(t, !volume_write(v, journal_test_data_lba(v, second_cluster), fresh[:]))
	testing.expect(t, v.frozen && failure.useful)
	last := v.alloc.root.children[len(v.alloc.root.children) - 1]
	testing.expect(t, os.exists(last.host_path))
}

@(test)
protection_test_staged_root_growth_stays_protected_after_fat_free :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := fat32_test_fixture(t)
	defer os.remove_all(dir)
	v := volume_open(dir, 2048)
	testing.expect(t, v != nil)
	if v == nil {return}
	discarded := false
	defer if !discarded {volume_discard(v)}

	root := v.alloc.root
	testing.expect_value(t, root.cluster_len, u32(1))
	if root.cluster_len != 1 {return}
	command := root.children[0]
	command_path := strings.clone(command.host_path, context.temp_allocator)
	want, read_error := os.read_entire_file(command_path, context.temp_allocator)
	testing.expect(t, read_error == nil)
	new_root_cluster := v.alloc.next_free

	// The first half of a cross-write FAT update is incomplete, not corrupt.
	testing.expect(t, protection_test_stage_fat_set(t, v, root.first_cluster, new_root_cluster))
	testing.expect(t, !v.frozen)
	testing.expect_value(t, len(v.journal.pending_extends), 1)
	_, claimed_early := v.journal.claimed[new_root_cluster]
	testing.expect(t, !claimed_early)

	testing.expect(t, protection_test_stage_fat_set(t, v, new_root_cluster, 0x0FFFFFFF))
	testing.expect(t, !v.frozen)
	claim, claimed := v.journal.claimed[new_root_cluster]
	testing.expect(t, claimed)
	if claimed {
		testing.expect(t, claim.node == root)
		testing.expect_value(t, claim.index, u32(1))
	}
	testing.expect_value(t, root.cluster_len, u32(2))
	testing.expect_value(t, len(v.journal.pending_extends), 0)

	file_cluster := new_root_cluster + 1
	testing.expect(t, protection_test_stage_fat_set(t, v, file_cluster, 0x0FFFFFFF))
	file_data: [SECTOR]u8
	copy(file_data[:], "GROWN")
	testing.expect(t, volume_stage_write(v, journal_test_data_lba(v, file_cluster), file_data[:]))
	occupied: [SECTOR]u8
	decode_test_put_entry(occupied[:], 0, "GROWN   TXT", ATTR_FILE, file_cluster, 5)
	new_root_lba := journal_test_data_lba(v, new_root_cluster)
	testing.expect(t, volume_stage_write(v, new_root_lba, occupied[:]))
	testing.expect(t, !v.frozen)
	testing.expect(t, volume_reconcile(v))
	materialized_path, path_error := filepath.join({dir, "GROWN.TXT"}, context.temp_allocator)
	testing.expect(t, path_error == nil)
	materialized, materialized_error := os.read_entire_file(
		materialized_path,
		context.temp_allocator,
	)
	testing.expect(t, materialized_error == nil)
	testing.expect_value(t, string(materialized), "GROWN")

	// FORMAT commonly frees the FAT first, then installs a zeroed root with a label.
	testing.expect(t, protection_test_stage_fat_set(t, v, new_root_cluster, 0))
	testing.expect(t, !v.frozen)
	retained_claim, retained := v.journal.claimed[new_root_cluster]
	testing.expect(t, retained)
	if retained {testing.expect(t, retained_claim.node == root)}

	failure: Protection_Test_Failure
	protection_test_arm(v, &failure)
	formatted: [SECTOR]u8
	copy(formatted[:11], "NO NAME    ")
	formatted[11] = 0x08
	testing.expect(t, !volume_stage_write(v, new_root_lba, formatted[:]))
	testing.expect(t, v.frozen && failure.fired && failure.useful)
	protection_test_host_unchanged(t, command, want)
	materialized, materialized_error = os.read_entire_file(
		materialized_path,
		context.temp_allocator,
	)
	testing.expect(t, materialized_error == nil)
	testing.expect_value(t, string(materialized), "GROWN")

	testing.expect(t, !volume_close(v))
	volume_discard(v)
	discarded = true
	v2 := volume_open(dir, 2048)
	testing.expect(t, v2 != nil)
	if v2 == nil {return}
	reopened, reopen_error := os.read_entire_file(command_path, context.temp_allocator)
	testing.expect(t, reopen_error == nil)
	testing.expect(t, string(reopened) == string(want))
	reopened_grown, grown_error := os.read_entire_file(materialized_path, context.temp_allocator)
	testing.expect(t, grown_error == nil)
	testing.expect_value(t, string(reopened_grown), "GROWN")
	testing.expect(t, volume_close(v2))
}

@(test)
protection_test_staged_root_growth_rejects_owned_cluster :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := fat32_test_fixture(t)
	defer os.remove_all(dir)
	v := volume_open(dir, 2048)
	testing.expect(t, v != nil)
	if v == nil {return}
	defer volume_discard(v)
	root := v.alloc.root
	occupied := root.children[1]
	want, read_error := os.read_entire_file(root.children[0].host_path, context.temp_allocator)
	testing.expect(t, read_error == nil)
	fired := false
	journal_test_arm_on_fail(v, &fired)

	testing.expect(
		t,
		!protection_test_stage_fat_set(t, v, root.first_cluster, occupied.first_cluster),
	)
	testing.expect(t, v.frozen && fired)
	protection_test_host_unchanged(t, root.children[0], want)
}

@(test)
protection_test_staged_root_tail_can_be_reused_after_complete_shrink :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := fat32_test_fixture(t)
	defer os.remove_all(dir)
	v := volume_open(dir, 2048)
	testing.expect(t, v != nil)
	if v == nil {return}
	closed := false
	defer if !closed {volume_discard(v)}

	root := v.alloc.root
	tail := v.alloc.next_free
	testing.expect(t, protection_test_stage_fat_set(t, v, tail, 0x0FFFFFFF))
	testing.expect(t, protection_test_stage_fat_set(t, v, root.first_cluster, tail))
	grown_claim, grown := v.journal.claimed[tail]
	testing.expect(t, grown)
	if grown {testing.expect(t, grown_claim.node == root)}
	testing.expect_value(t, root.cluster_len, u32(2))

	// Ending the root at its first cluster is a complete shrink, so the old tail is reusable.
	testing.expect(t, protection_test_stage_fat_set(t, v, root.first_cluster, 0x0FFFFFFF))
	testing.expect(t, !v.frozen)
	testing.expect_value(t, root.cluster_len, u32(1))
	_, still_claimed := v.journal.claimed[tail]
	testing.expect(t, !still_claimed)
	testing.expect(t, v.alloc.by_cluster[tail] == nil)

	data: [SECTOR]u8
	copy(data[:], "REUSE")
	testing.expect(t, volume_stage_write(v, journal_test_data_lba(v, tail), data[:]))
	root_lba := journal_test_data_lba(v, root.first_cluster)
	root_sector := read_test_sector(t, v, root_lba)
	decode_test_put_entry(root_sector[:], 96, "REUSED  TXT", ATTR_FILE, tail, 5)
	testing.expect(t, volume_stage_write(v, root_lba, root_sector[:]))
	testing.expect(t, volume_reconcile(v))

	owner, owned := v.journal.claimed[tail]
	testing.expect(t, owned)
	if owned {
		testing.expect(t, owner.node != root)
		testing.expect(t, !owner.node.is_dir)
	}
	guest: [SECTOR]u8
	testing.expect(t, volume_read(v, journal_test_data_lba(v, tail), guest[:]))
	testing.expect_value(t, string(guest[:5]), "REUSE")
	reused_path, path_error := filepath.join({dir, "REUSED.TXT"}, context.temp_allocator)
	testing.expect(t, path_error == nil)
	host, host_error := os.read_entire_file(reused_path, context.temp_allocator)
	testing.expect(t, host_error == nil)
	testing.expect_value(t, string(host), "REUSE")

	if !volume_close(v) {
		testing.expect(t, false)
		return
	}
	closed = true
	v2 := volume_open(dir, 2048)
	testing.expect(t, v2 != nil)
	if v2 == nil {return}
	reopened, reopen_error := os.read_entire_file(reused_path, context.temp_allocator)
	testing.expect(t, reopen_error == nil)
	testing.expect_value(t, string(reopened), "REUSE")
	testing.expect(t, volume_close(v2))
}

@(test)
protection_test_staged_synthesized_root_truncation_preserves_tail_file :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := fat32_test_fixture(t)
	defer os.remove_all(dir)
	protection_test_add_long_root_files(t, dir, 14)
	v := volume_open(dir, 2048)
	testing.expect(t, v != nil)
	if v == nil {return}
	discarded := false
	defer if !discarded {volume_discard(v)}

	root := v.alloc.root
	testing.expect(t, root.cluster_len > 1)
	if root.cluster_len <= 1 {return}
	entry_index: u32
	target: ^Node
	for child in root.children {
		if entry_index >= CLUSTER_BYTES / 32 {
			target = child
			break
		}
		entry_index += 1 + lfn_entry_count(child.name)
	}
	testing.expect(t, target != nil)
	if target == nil {return}
	target_path := strings.clone(target.host_path, context.temp_allocator)
	want, read_error := os.read_entire_file(target_path, context.temp_allocator)
	testing.expect(t, read_error == nil)
	failure: Protection_Test_Failure
	protection_test_arm(v, &failure)

	testing.expect(
		t,
		!protection_test_stage_fat_pair(
			t,
			v,
			root.first_cluster,
			0x0FFFFFFF,
			target.first_cluster,
			0,
		),
	)
	testing.expect(t, v.frozen && failure.fired && failure.useful)
	protection_test_host_unchanged(t, target, want)
	testing.expect(t, !volume_close(v))
	volume_discard(v)
	discarded = true

	v2 := volume_open(dir, 2048)
	testing.expect(t, v2 != nil)
	if v2 == nil {return}
	reopened, reopen_error := os.read_entire_file(target_path, context.temp_allocator)
	testing.expect(t, reopen_error == nil)
	testing.expect(t, string(reopened) == string(want))
	testing.expect(t, volume_close(v2))
}

@(test)
protection_test_staged_grown_root_truncation_preserves_tail_file :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := fat32_test_fixture(t)
	defer os.remove_all(dir)
	v := volume_open(dir, 2048)
	testing.expect(t, v != nil)
	if v == nil {return}
	discarded := false
	defer if !discarded {volume_discard(v)}

	root := v.alloc.root
	tail := v.alloc.next_free
	file_cluster := tail + 1
	testing.expect(t, protection_test_stage_fat_set(t, v, tail, 0x0FFFFFFF))
	testing.expect(t, protection_test_stage_fat_set(t, v, root.first_cluster, tail))
	testing.expect(t, protection_test_stage_fat_set(t, v, file_cluster, 0x0FFFFFFF))
	data: [SECTOR]u8
	copy(data[:], "GROWN")
	testing.expect(t, volume_stage_write(v, journal_test_data_lba(v, file_cluster), data[:]))
	tail_sector: [SECTOR]u8
	decode_test_put_entry(tail_sector[:], 0, "GROWN   TXT", ATTR_FILE, file_cluster, 5)
	testing.expect(t, volume_stage_write(v, journal_test_data_lba(v, tail), tail_sector[:]))
	testing.expect(t, volume_reconcile(v))
	grown_path, path_error := filepath.join({dir, "GROWN.TXT"}, context.temp_allocator)
	testing.expect(t, path_error == nil)
	host, host_error := os.read_entire_file(grown_path, context.temp_allocator)
	testing.expect(t, host_error == nil)
	testing.expect_value(t, string(host), "GROWN")
	failure: Protection_Test_Failure
	protection_test_arm(v, &failure)

	testing.expect(
		t,
		!protection_test_stage_fat_pair(t, v, root.first_cluster, 0x0FFFFFFF, file_cluster, 0),
	)
	testing.expect(t, v.frozen && failure.fired && failure.useful)
	host, host_error = os.read_entire_file(grown_path, context.temp_allocator)
	testing.expect(t, host_error == nil)
	testing.expect_value(t, string(host), "GROWN")
	testing.expect(t, !volume_close(v))
	volume_discard(v)
	discarded = true

	v2 := volume_open(dir, 2048)
	testing.expect(t, v2 != nil)
	if v2 == nil {return}
	reopened, reopen_error := os.read_entire_file(grown_path, context.temp_allocator)
	testing.expect(t, reopen_error == nil)
	testing.expect_value(t, string(reopened), "GROWN")
	testing.expect(t, volume_close(v2))
}

@(test)
protection_test_preflight_and_normal_writes :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := fat32_test_fixture(t)
	defer os.remove_all(dir)
	v := volume_open(dir, 2048)
	testing.expect(t, v != nil)
	if v == nil {
		return
	}

	fsinfo := make_fsinfo()
	fsinfo[488] = 0x12
	testing.expect(t, volume_write(v, PART_START_LBA + 1, fsinfo[:]))
	command := v.alloc.root.children[0]
	data: [SECTOR]u8
	for i in 0 ..< SECTOR {
		data[i] = 0xA5
	}
	testing.expect(t, volume_write(v, journal_test_data_lba(v, command.first_cluster), data[:]))
	got, _ := os.read_entire_file(command.host_path, context.temp_allocator)
	testing.expect(t, string(got[:SECTOR]) == string(data[:]))
	testing.expect(t, !v.frozen)

	v2 := volume_open(dir, 2048)
	three: [SECTOR * 3]u8
	canonical_fsinfo := make_fsinfo()
	copy(three[:SECTOR], canonical_fsinfo[:])
	three[488] = 0x34
	three[SECTOR * 2] = 0xF6
	testing.expect(t, !volume_write(v2, PART_START_LBA + 1, three[:]))
	testing.expect(t, v2.frozen)
	testing.expect_value(t, len(v2.journal.overlay), 0)
}

@(test)
protection_test_fat_first_multi_file_delete_is_allowed :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := fat32_test_fixture(t)
	defer os.remove_all(dir)
	v := volume_open(dir, 2048)
	testing.expect(t, v != nil)
	if v == nil {
		return
	}
	command := v.alloc.root.children[0]
	io := v.alloc.root.children[2]
	command_path := command.host_path
	io_path := io.host_path
	root_lba := journal_test_data_lba(v, 2)
	root := read_test_sector(t, v, root_lba)

	fat_lba := journal_test_fat_lba(v, command.first_cluster)
	fat := read_test_sector(t, v, fat_lba)
	for cluster in command.first_cluster ..< command.first_cluster + command.cluster_len {
		protection_test_put32(fat[:], int(cluster % 128) * 4, 0)
	}
	for cluster in io.first_cluster ..< io.first_cluster + io.cluster_len {
		protection_test_put32(fat[:], int(cluster % 128) * 4, 0)
	}
	testing.expect(t, volume_write(v, fat_lba, fat[:]))
	testing.expect(t, os.exists(command_path))
	testing.expect(t, os.exists(io_path))

	root[0] = 0xE5
	root[64] = 0xE5
	testing.expect(t, volume_write(v, root_lba, root[:]))
	testing.expect(t, !os.exists(command_path))
	testing.expect(t, !os.exists(io_path))
	testing.expect(t, !v.frozen)
}
