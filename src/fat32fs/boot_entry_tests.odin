// SPDX-License-Identifier: GPL-3.0-only
package fat32fs

import disk "../disk"
import "core:testing"

Boot_Entry_Test_Device :: struct {
	sectors: [2][SECTOR_BYTES]u8,
}

@(private = "file")
boot_entry_test_read :: proc(ctx: rawptr, lba: u64, data: []u8) -> bool {
	device := (^Boot_Entry_Test_Device)(ctx)
	if device == nil || lba >= len(device.sectors) || len(data) != SECTOR_BYTES {return false}
	copy(data, device.sectors[lba][:])
	return true
}

@(private = "file")
boot_entry_test_volume :: proc(device: ^Boot_Entry_Test_Device) -> Volume {
	return {
		device = disk.Block_Device {
			ctx          = device,
			sector_count = len(device.sectors),
			read         = boot_entry_test_read,
		},
		info = {
			data_lba            = 0,
			root_cluster        = 2,
			cluster_count       = 2,
			sectors_per_cluster = 1,
		},
	}
}

@(private = "file")
boot_entry_test_write_io :: proc(sector: []u8, first_cluster: u32) {
	copy(sector[:11], "IO      SYS")
	sector[11] = ATTR_SYSTEM
	put_u16le(sector, 20, u16(first_cluster >> 16))
	put_u16le(sector, 26, u16(first_cluster))
}

@(test)
fat32fs_boot_entry_test_requires_exact_entry_in_first_root_cluster :: proc(t: ^testing.T) {
	wanted := [11]u8{'I', 'O', ' ', ' ', ' ', ' ', ' ', ' ', 'S', 'Y', 'S'}
	first: Boot_Entry_Test_Device
	boot_entry_test_write_io(first.sectors[0][:], 5)
	first_volume := boot_entry_test_volume(&first)
	present, first_error := root_short_entry_in_first_cluster(&first_volume, wanted, 5)
	if !testing.expect_value(t, first_error.code, Error_Code.None) {return}
	testing.expect(t, present)
	later: Boot_Entry_Test_Device
	for offset := 0; offset < SECTOR_BYTES; offset += 32 {later.sectors[0][offset] = 0xe5}
	boot_entry_test_write_io(later.sectors[1][:], 5)
	later_volume := boot_entry_test_volume(&later)
	later_present, later_error := root_short_entry_in_first_cluster(&later_volume, wanted, 5)
	if !testing.expect_value(t, later_error.code, Error_Code.None) {return}
	testing.expect(t, !later_present)
}
