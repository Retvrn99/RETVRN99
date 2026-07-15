// SPDX-License-Identifier: GPL-3.0-only
package fat32

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

journal_test_fat_lba :: proc(v: ^Volume, cluster: u32, copy_n: u32 = 0) -> u64 {
	geo := &v.alloc.geo
	return u64(PART_START_LBA) + u64(geo.fat_start + copy_n * geo.sectors_per_fat + cluster / 128)
}

journal_test_data_lba :: proc(v: ^Volume, cluster: u32) -> u64 {
	return u64(PART_START_LBA) + u64(cluster_to_lba(&v.alloc.geo, cluster))
}

journal_test_arm_on_fail :: proc(v: ^Volume, fired: ^bool) {
	v.fail_ctx = fired
	v.on_fail = proc(ctx: rawptr, msg: string) {
		(^bool)(ctx)^ = true
	}
}

@(test)
journal_test_shadow_fat :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := fat32_test_fixture(t)
	defer os.remove_all(dir)
	v := volume_open(dir, 2048)
	testing.expect(t, v != nil)
	if v == nil {
		return
	}
	fc := v.alloc.next_free
	testing.expect_value(t, volume_fat_entry(v, fc), u32(0)) // free before

	lba := journal_test_fat_lba(v, fc)
	sec := read_test_sector(t, v, lba)
	off := int(fc % 128) * 4
	sec[off] = 0xFF
	sec[off + 1] = 0xFF
	sec[off + 2] = 0xFF
	sec[off + 3] = 0x0F
	testing.expect(t, volume_write(v, lba, sec[:]))

	// fat_entry consults the shadow now
	testing.expect_value(t, volume_fat_entry(v, fc), u32(0x0FFFFFFF))
	// the written sector reads back verbatim
	back := read_test_sector(t, v, lba)
	testing.expect(t, back == sec)
	// the second FAT copy reflects the same entry
	back2 := read_test_sector(t, v, journal_test_fat_lba(v, fc, 1))
	testing.expect_value(t, synth_rd32(back2[:], off), u32(0x0FFFFFFF))
	// untouched entries keep their synthesized values
	testing.expect_value(t, synth_rd32(back[:], 0), u32(0x0FFFFFF8))
}

@(test)
journal_test_owned_data_write :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := fat32_test_fixture(t)
	defer os.remove_all(dir)
	v := volume_open(dir, 2048)
	testing.expect(t, v != nil)
	if v == nil {
		return
	}
	command := v.alloc.root.children[0] // COMMAND.COM, 2000 bytes
	testing.expect(t, command.name == "COMMAND.COM")

	sec: [SECTOR]u8
	for i in 0 ..< SECTOR {
		sec[i] = 0x5C
	}
	testing.expect(t, volume_write(v, journal_test_data_lba(v, command.first_cluster), sec[:]))

	host, herr := os.read_entire_file(command.host_path, context.allocator)
	testing.expect(t, herr == nil)
	testing.expect_value(t, len(host), 2000)
	for i in 0 ..< SECTOR {
		testing.expect_value(t, host[i], u8(0x5C))
	}
	testing.expect_value(t, host[SECTOR], u8(0)) // rest untouched
}

@(test)
journal_test_boot_write_freezes :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := fat32_test_fixture(t)
	defer os.remove_all(dir)
	v := volume_open(dir, 2048)
	testing.expect(t, v != nil)
	if v == nil {
		return
	}
	fired := false
	journal_test_arm_on_fail(v, &fired)

	sec: [SECTOR]u8
	testing.expect(t, !volume_write(v, 0, sec[:])) // MBR
	testing.expect(t, fired)
	testing.expect(t, v.frozen)
	// further writes rejected, reads keep working
	testing.expect(t, !volume_write(v, u64(PART_START_LBA) + 2, sec[:]))
	mbr := read_test_sector(t, v, 0)
	testing.expect_value(t, mbr[510], u8(0x55))

	// a fresh volume freezes on VBR writes too
	v2 := volume_open(dir, 2048)
	fired2 := false
	journal_test_arm_on_fail(v2, &fired2)
	testing.expect(t, !volume_write(v2, u64(PART_START_LBA), sec[:]))
	testing.expect(t, fired2)
	testing.expect(t, v2.frozen)
}

@(test)
journal_test_orphan_cluster :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := fat32_test_fixture(t)
	defer os.remove_all(dir)
	v := volume_open(dir, 2048)
	testing.expect(t, v != nil)
	if v == nil {
		return
	}
	fc := v.alloc.next_free
	lba := journal_test_data_lba(v, fc)

	sec: [SECTOR]u8
	for i in 0 ..< SECTOR {
		sec[i] = u8(i)
	}
	testing.expect(t, volume_write(v, lba + 3, sec[:])) // mid-cluster sector

	back := read_test_sector(t, v, lba + 3)
	testing.expect(t, back == sec)
	other := read_test_sector(t, v, lba) // untouched sector stays zero
	testing.expect(t, read_test_all_zero(other[:]))
	// no host file appeared for it
	entries, rerr := os.read_all_directory_by_path(dir, context.allocator)
	testing.expect(t, rerr == nil)
	testing.expect_value(t, len(entries), 3)
}

@(test)
journal_test_stale_cluster_reallocation_and_free :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := fat32_test_fixture(t)
	defer os.remove_all(dir)
	v := volume_open(dir, 2048)
	if v == nil {return}
	defer volume_discard(v)
	cluster := v.alloc.next_free
	v.journal.shadow_fat[cluster] = 0x0FFFFFFF
	v.journal.stale_clusters[cluster] = true
	data: [CLUSTER_BYTES]u8
	data[0] = 0xA5
	testing.expect(t, orphan_store_cluster(v, cluster, data[:]))

	decode_test_fat_set(t, v, cluster, 0x0FFFFFF8)
	testing.expect(t, !v.journal.stale_clusters[cluster])
	back: [CLUSTER_BYTES]u8
	testing.expect(t, orphan_read_cluster(v, cluster, back[:]))
	testing.expect_value(t, back[0], u8(0xA5))
	decode_test_fat_set(t, v, cluster, 0)
	testing.expect(t, !orphan_has(v, cluster))
}

@(test)
journal_test_grow_tail_parked :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := fat32_test_fixture(t)
	defer os.remove_all(dir)
	v := volume_open(dir, 2048)
	testing.expect(t, v != nil)
	if v == nil {
		return
	}
	command := v.alloc.root.children[0] // 2000 bytes -> EOF inside sector 3
	sec: [SECTOR]u8
	for i in 0 ..< SECTOR {
		sec[i] = 0xAB
	}
	lba := journal_test_data_lba(v, command.first_cluster)
	testing.expect(t, volume_write(v, lba + 3, sec[:]))

	// host got only the in-size prefix (1536..2000)
	host, _ := os.read_entire_file(command.host_path, context.allocator)
	testing.expect_value(t, len(host), 2000)
	testing.expect_value(t, host[1536], u8(0xAB))
	testing.expect_value(t, host[1999], u8(0xAB))
	// the tail waits in orphan_data and shows through reads
	back := read_test_sector(t, v, lba + 3)
	testing.expect(t, back == sec)
	p, _ := filepath.join({dir, "COMMAND.COM"})
	testing.expect(t, p == command.host_path)
}

@(test)
journal_test_reserved_overlay :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := fat32_test_fixture(t)
	defer os.remove_all(dir)
	v := volume_open(dir, 2048)
	testing.expect(t, v != nil)
	if v == nil {
		return
	}
	sec := make_fsinfo()
	sec[488] = 0x34
	sec[489] = 0x12
	sec[492] = 0x78
	sec[493] = 0x56
	lba := u64(PART_START_LBA) + 1
	testing.expect(t, volume_write(v, lba, sec[:]))
	back := read_test_sector(t, v, lba)
	testing.expect(t, back == sec)
	testing.expect(t, !v.frozen)
}

@(test)
journal_test_overlay_and_orphan_layers_keep_independent_precedence :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := fat32_test_fixture(t)
	defer os.remove_all(dir)
	v := volume_open(dir, 2048)
	if !testing.expect(t, v != nil) {return}
	defer volume_discard(v)
	cluster := v.alloc.next_free
	lba := journal_test_data_lba(v, cluster)
	rel := u32(lba - PART_START_LBA)

	overlay_sector: [SECTOR]u8
	overlay_sector[0] = 0x11
	orphan_sector: [SECTOR]u8
	orphan_sector[0] = 0x22
	testing.expect(t, volume_stage_write(v, lba, overlay_sector[:]))
	testing.expect(t, orphan_write_sector(v, cluster, 0, orphan_sector[:]))
	testing.expect(t, overlay_has(v, rel) && orphan_has(v, cluster))
	back := read_test_sector(t, v, lba)
	testing.expect(t, back == overlay_sector)

	orphan_clear(v, cluster)
	testing.expect(t, overlay_has(v, rel) && !orphan_has(v, cluster))
	back = read_test_sector(t, v, lba)
	testing.expect(t, back == overlay_sector)

	other := cluster + 1
	other_lba := journal_test_data_lba(v, other)
	testing.expect(t, orphan_write_sector(v, other, 0, orphan_sector[:]))
	testing.expect(t, read_test_sector(t, v, other_lba) == orphan_sector)
	orphan_clear(v, other)
	cleared := read_test_sector(t, v, other_lba)
	testing.expect(t, read_test_all_zero(cleared[:]))
}

@(test)
journal_test_large_stage_write_has_fixed_resident_state_and_batched_io :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := fat32_test_fixture(t)
	defer os.remove_all(dir)
	v := volume_open(dir, 2048)
	if !testing.expect(t, v != nil) {return}
	defer volume_discard(v)

	sector_count := 16 * 1024
	start_cluster := v.alloc.next_free + 1024
	lba := journal_test_data_lba(v, start_cluster)
	data := make([]u8, sector_count * SECTOR, context.temp_allocator)
	for &byte, index in data {byte = u8(index * 37 + 11)}
	before := volume_journal_storage_stats(v)
	testing.expect(t, volume_stage_write(v, lba, data))
	after := volume_journal_storage_stats(v)
	testing.expect_value(t, after.resident_metadata_bytes, before.resident_metadata_bytes)
	testing.expect_value(t, after.present_sectors, u32(sector_count))
	testing.expect_value(t, after.dirty_sectors, u32(sector_count))
	testing.expect_value(t, after.backing_write_ops - before.backing_write_ops, u64(1))
	testing.expect_value(t, after.backing_write_bytes - before.backing_write_bytes, u64(len(data)))

	back := make([]u8, len(data), context.temp_allocator)
	testing.expect(t, volume_read(v, lba, back))
	reread := volume_journal_storage_stats(v)
	testing.expect_value(t, reread.backing_read_ops - after.backing_read_ops, u64(1))
	testing.expect(t, string(back) == string(data))

	for &byte in data {byte = ~byte}
	testing.expect(t, volume_stage_write(v, lba, data))
	overwritten := volume_journal_storage_stats(v)
	testing.expect_value(t, overwritten.present_sectors, u32(sector_count))
	testing.expect_value(t, overwritten.resident_metadata_bytes, before.resident_metadata_bytes)
	testing.expect_value(t, overwritten.backing_write_ops - reread.backing_write_ops, u64(1))
	testing.expect(t, volume_read(v, lba, back))
	testing.expect(t, string(back) == string(data))
}

@(test)
journal_test_high_lba_write_is_physically_sparse :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := fat32_test_fixture(t)
	defer os.remove_all(dir)
	v := volume_open(dir, 2048)
	if !testing.expect(t, v != nil) {return}
	defer volume_discard(v)

	last_rel := v.alloc.geo.total_sectors - 1
	sector: [SECTOR]u8
	sector[0] = 0xA5
	testing.expect(t, volume_stage_write(v, u64(PART_START_LBA) + u64(last_rel), sector[:]))
	stats := volume_journal_storage_stats(v)
	testing.expect_value(t, stats.backing_logical_bytes, u64(v.alloc.geo.total_sectors) * SECTOR)
	when ODIN_OS == .Windows {
		testing.expect(t, stats.backing_allocation_known)
		testing.expect(t, stats.backing_allocated_bytes < 1024 * 1024)
	}
}

@(test)
journal_test_backing_failure_freezes_and_destroy_cleans_path :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := fat32_test_fixture(t)
	defer os.remove_all(dir)
	v := volume_open(dir, 2048)
	if !testing.expect(t, v != nil) {return}
	path := strings.clone(v.journal.overlay.path, context.temp_allocator)
	linked := v.journal.overlay.linked
	if linked {testing.expect(t, os.exists(path))}

	testing.expect(t, os.close(v.journal.overlay.file) == nil)
	v.journal.overlay.file = nil
	fired := false
	journal_test_arm_on_fail(v, &fired)
	sector: [SECTOR]u8
	sector[0] = 0x5A
	testing.expect(t, !volume_stage_write(v, journal_test_data_lba(v, v.alloc.next_free), sector[:]))
	testing.expect(t, fired && v.frozen)
	testing.expect(t, !volume_journal_storage_stats(v).healthy)
	testing.expect_value(t, volume_journal_storage_stats(v).present_sectors, u32(0))
	volume_discard(v)
	testing.expect(t, !os.exists(path))
}

@(test)
journal_test_backing_failure_does_not_publish_fat_side_effects :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := fat32_test_fixture(t)
	defer os.remove_all(dir)
	v := volume_open(dir, 2048)
	if !testing.expect(t, v != nil) {return}
	defer volume_discard(v)
	cluster := v.alloc.next_free
	original := volume_fat_entry(v, cluster)
	fat_lba := journal_test_fat_lba(v, cluster)
	sector := read_test_sector(t, v, fat_lba)
	offset := int(cluster % 128) * 4
	sector[offset] = 0xFF
	sector[offset + 1] = 0xFF
	sector[offset + 2] = 0xFF
	sector[offset + 3] = 0x0F

	testing.expect(t, os.close(v.journal.overlay.file) == nil)
	v.journal.overlay.file = nil
	fired := false
	journal_test_arm_on_fail(v, &fired)
	testing.expect(t, !volume_stage_write(v, fat_lba, sector[:]))
	testing.expect(t, fired && v.frozen)
	testing.expect_value(t, volume_fat_entry(v, cluster), original)
	_, shadowed := v.journal.shadow_fat[cluster]
	testing.expect(t, !shadowed)
}

@(test)
journal_test_crash_scavenger_preserves_live_windows_backing :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		context.allocator = context.temp_allocator
		dir := fat32_test_fixture(t)
		defer os.remove_all(dir)
		temp, _ := os.temp_directory(context.temp_allocator)
		journal_dir, _ := filepath.join(
			{temp, OVERLAY_DIRECTORY},
			context.temp_allocator,
		)
		testing.expect(t, os.make_directory_all(journal_dir) == nil)
		stale, _ := filepath.join(
			{journal_dir, "retvrn99-fat32-0-abandoned.overlay"},
			context.temp_allocator,
		)
		testing.expect(t, os.write_entire_file(stale, "stale") == nil)
		v1 := volume_open(dir, 2048)
		if !testing.expect(t, v1 != nil) {return}
		testing.expect(t, !os.exists(stale))
		live := strings.clone(v1.journal.overlay.path, context.temp_allocator)
		testing.expect(t, os.exists(live))
		v2 := volume_open(dir, 2048)
		if !testing.expect(t, v2 != nil) {
			volume_discard(v1)
			return
		}
		// v2 scavenges again, but v1's non-delete-shared handle proves it live.
		testing.expect(t, os.exists(live))
		volume_discard(v2)
		volume_discard(v1)
		testing.expect(t, !os.exists(live))
	}
}

@(test)
journal_test_stream_scavenger_removes_dead_owner_and_preserves_live_owner :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := fat32_test_fixture(t)
	defer os.remove_all(dir)
	v := volume_open(dir, 2048)
	if !testing.expect(t, v != nil) {return}
	defer volume_discard(v)
	journal_dir, path_error := filepath.join(
		{filepath.dir(dir), OVERLAY_DIRECTORY},
		context.temp_allocator,
	)
	testing.expect(t, path_error == nil)
	testing.expect(t, os.make_directory_all(journal_dir) == nil)
	stale, _ := filepath.join(
		{journal_dir, STREAM_TEMP_PREFIX + "0-abandoned" + STREAM_TEMP_SUFFIX},
		context.temp_allocator,
	)
	live, _ := filepath.join(
		{
			journal_dir,
			fmt.tprintf(
				"%s%d-live%s",
				STREAM_TEMP_PREFIX,
				os.get_pid(),
				STREAM_TEMP_SUFFIX,
			),
		},
		context.temp_allocator,
	)
	testing.expect(t, os.write_entire_file(stale, "stale") == nil)
	testing.expect(t, os.write_entire_file(live, "live") == nil)

	overlay_scavenge_stale(journal_dir)
	testing.expect(t, !os.exists(stale))
	testing.expect(t, os.exists(live))
	testing.expect(t, os.remove(live) == nil)
}

@(test)
journal_test_prepared_stream_is_outside_guest_tree_and_installs_atomically :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := fat32_test_fixture(t)
	defer os.remove_all(dir)
	v := volume_open(dir, 2048)
	if !testing.expect(t, v != nil) {return}
	defer volume_discard(v)
	io := reconcile_test_child_named(v.alloc.root, "IO.SYS")
	if !testing.expect(t, io != nil) {return}
	chain := volume_chain(v, io.first_cluster, context.temp_allocator)
	target, target_error := filepath.join({dir, "ATOMIC.BIN"}, context.temp_allocator)
	testing.expect(t, target_error == nil)
	testing.expect(t, os.write_entire_file(target, "old") == nil)
	want, read_error := os.read_entire_file(io.host_path, context.temp_allocator)
	testing.expect(t, read_error == nil)

	prepared, _, stream_error := guest_prepare_file(
		v,
		target,
		chain[:],
		u32(io.size),
		.Guest_View,
		context.temp_allocator,
	)
	if !testing.expect(t, stream_error == .None) {return}
	journal_dir, _ := filepath.join(
		{filepath.dir(dir), OVERLAY_DIRECTORY},
		context.temp_allocator,
	)
	testing.expect_value(t, filepath.dir(prepared), journal_dir)
	guest_prefix := strings.concatenate(
		{dir, os.Path_Separator_String},
		context.temp_allocator,
	)
	testing.expect(t, !strings.has_prefix(prepared, guest_prefix))
	testing.expect(t, os.exists(prepared))
	testing.expect(t, guest_prepared_install(prepared, target))
	delete(prepared, context.temp_allocator)
	got, install_read_error := os.read_entire_file(target, context.temp_allocator)
	testing.expect(t, install_read_error == nil)
	testing.expect(t, string(got) == string(want))
}
