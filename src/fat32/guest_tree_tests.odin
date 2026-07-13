// SPDX-License-Identifier: GPL-3.0-only
package fat32

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
guest_tree_test_invalid_short_component_freezes_without_mutation :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {
		return
	}
	defer volume_discard(v)

	command := v.alloc.root.children[0]
	want, read_error := os.read_entire_file(command.host_path, context.temp_allocator)
	testing.expect(t, read_error == nil)
	root_lba := journal_test_data_lba(v, 2)
	sector := read_test_sector(t, v, root_lba)
	decode_test_put_entry(
		sector[:],
		0,
		`..\PWN  TXT`,
		ATTR_FILE,
		command.first_cluster,
		u32(command.size),
	)
	fired := false
	journal_test_arm_on_fail(v, &fired)

	testing.expect(t, volume_stage_write(v, root_lba, sector[:]))
	testing.expect(t, !volume_reconcile(v))
	testing.expect(t, fired)
	testing.expect(t, v.frozen)
	got, final_error := os.read_entire_file(command.host_path, context.temp_allocator)
	testing.expect(t, final_error == nil)
	testing.expect(t, string(got) == string(want))
}

@(test)
guest_tree_test_invalid_lfn_does_not_fall_back_to_short_name :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {
		return
	}
	defer volume_discard(v)

	short: [11]u8
	copy(short[:], "BADLFN~1TXT")
	root_lba := journal_test_data_lba(v, 2)
	sector := read_test_sector(t, v, root_lba)
	decode_test_put_lfn(sector[:], 96, 1, true, lfn_checksum(short), `..\ESCAPE.TXT`)
	decode_test_put_entry(sector[:], 128, "BADLFN~1TXT", ATTR_FILE, 0, 0)
	fired := false
	journal_test_arm_on_fail(v, &fired)

	testing.expect(t, volume_stage_write(v, root_lba, sector[:]))
	testing.expect(t, !volume_reconcile(v))
	testing.expect(t, fired)
	testing.expect(t, v.frozen)
	fallback, _ := filepath.join({dir, "BADLFN~1.TXT"})
	testing.expect(t, !os.exists(fallback))
	command, _ := filepath.join({dir, "COMMAND.COM"})
	testing.expect(t, os.exists(command))
}

@(test)
guest_tree_test_valid_lfn_does_not_hide_invalid_short_component :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {
		return
	}
	defer volume_discard(v)

	short: [11]u8
	copy(short[:], `BAD\NAMETXT`)
	root_lba := journal_test_data_lba(v, 2)
	sector := read_test_sector(t, v, root_lba)
	decode_test_put_lfn(sector[:], 96, 1, true, lfn_checksum(short), "SafeName.txt")
	decode_test_put_entry(sector[:], 128, `BAD\NAMETXT`, ATTR_FILE, 0, 0)
	fired := false
	journal_test_arm_on_fail(v, &fired)

	testing.expect(t, volume_stage_write(v, root_lba, sector[:]))
	testing.expect(t, !volume_reconcile(v))
	testing.expect(t, fired)
	testing.expect(t, v.frozen)
	safe_name, _ := filepath.join({dir, "SafeName.txt"})
	testing.expect(t, !os.exists(safe_name))
}

@(test)
guest_tree_test_reparse_ancestor_invalidates_scan :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {
		return
	}
	defer volume_discard(v)

	dos, _ := filepath.join({dir, "DOS"})
	outside := strings.concatenate({dir, "-outside"}, context.temp_allocator)
	defer os.remove_all(outside)
	testing.expect(t, os.make_directory(outside) == nil)
	if os.remove_all(dos) != nil {
		return
	}
	if os.symlink(outside, dos) != nil {
		_ = os.make_directory(dos)
		return
	}

	fired := false
	journal_test_arm_on_fail(v, &fired)
	testing.expect(t, !volume_reconcile(v))
	testing.expect(t, fired)
	testing.expect(t, v.frozen)
	probe, _ := filepath.join({outside, "EDIT.HLP"})
	testing.expect(t, !os.exists(probe))
}
