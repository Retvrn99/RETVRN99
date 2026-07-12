// SPDX-License-Identifier: GPL-3.0-only
package fat32

import "core:os"
import "core:path/filepath"
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
	sec: [SECTOR]u8
	copy(sec[:], "RRaA") // FSInfo update
	lba := u64(PART_START_LBA) + 1
	testing.expect(t, volume_write(v, lba, sec[:]))
	back := read_test_sector(t, v, lba)
	testing.expect(t, back == sec)
	testing.expect(t, !v.frozen)
}
