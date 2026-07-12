// SPDX-License-Identifier: GPL-3.0-only
package fat32

import "core:os"
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
	failure2: Protection_Test_Failure
	protection_test_arm(v3, &failure2)
	reserved: [SECTOR]u8
	reserved[0] = 0xF6
	testing.expect(t, !volume_write(v3, PART_START_LBA + 2, reserved[:]))
	testing.expect(t, v3.frozen && failure2.useful)
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
	two: [SECTOR * 2]u8
	canonical_fsinfo := make_fsinfo()
	copy(two[:SECTOR], canonical_fsinfo[:])
	two[488] = 0x34
	two[SECTOR] = 0xF6
	testing.expect(t, !volume_write(v2, PART_START_LBA + 1, two[:]))
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
