// SPDX-License-Identifier: GPL-3.0-only
package fat32image

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:testing"

@(test)
fat32image_test_backup_fsinfo_uses_bpb_relative_sector :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-fsinfo-address-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	path, path_error := filepath.join({root, "fsinfo.bin"}, context.temp_allocator)
	if !testing.expect(t, path_error == nil) {return}
	file, open_error := os.open(path, {.Read, .Write, .Create, .Excl, .Sync})
	if !testing.expect_value(t, open_error, os.Error(nil)) {return}
	defer os.close(file)
	if !testing.expect_value(t, os.truncate(file, 32 * SECTOR_BYTES), os.Error(nil)) {
		return
	}
	geometry := Geometry {
		partition_lba     = 3,
		reserved_sectors  = 16,
		cluster_count     = 1000,
		fsinfo_sector     = 2,
		backup_vbr_sector = 6,
	}
	fsinfo := make_fsinfo(&geometry)
	invalid: [SECTOR_BYTES]u8
	primary_lba := u64(geometry.partition_lba) + u64(geometry.fsinfo_sector)
	backup_lba :=
		u64(geometry.partition_lba) + u64(geometry.backup_vbr_sector) + u64(geometry.fsinfo_sector)
	old_fixed_lba := u64(geometry.partition_lba) + u64(geometry.backup_vbr_sector) + 1
	if !testing.expect(
		t,
		write_exact_at(file, fsinfo[:], i64(primary_lba * SECTOR_BYTES)) &&
		write_exact_at(file, invalid[:], i64(old_fixed_lba * SECTOR_BYTES)) &&
		write_exact_at(file, fsinfo[:], i64(backup_lba * SECTOR_BYTES)),
	) {
		return
	}
	primary, backup: [SECTOR_BYTES]u8
	testing.expect(t, read_fsinfo_pair(file, &geometry, primary[:], backup[:]))
	testing.expect(t, slice.equal(primary[:], fsinfo[:]))
	testing.expect(t, slice.equal(backup[:], fsinfo[:]))
}
