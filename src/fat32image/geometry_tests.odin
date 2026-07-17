// SPDX-License-Identifier: GPL-3.0-only
package fat32image

import "core:testing"

@(test)
fat32image_test_geometry_sizes_and_cluster_thresholds :: proc(t: ^testing.T) {
	cases := []struct {
		capacity: u32,
		spc:      u8,
	}{{1, 8}, {8, 16}, {16, 32}, {20, 32}, {32, 64}, {127, 64}}
	for item in cases {
		geometry, err := geometry_for_capacity(item.capacity)
		if !testing.expect_value(t, err.code, Error_Code.None) {continue}
		testing.expect_value(t, geometry.disk_sectors, u64(item.capacity) * (u64(1) << 21))
		testing.expect_value(t, geometry.partition_lba, u32(63))
		testing.expect_value(t, geometry.partition_sectors, u32(geometry.disk_sectors - 63))
		testing.expect_value(t, geometry.sectors_per_cluster, item.spc)
		testing.expect(t, geometry.cluster_count >= 65_525)
		testing.expect(
			t,
			u64(geometry.sectors_per_fat) * SECTOR_BYTES / 4 >= u64(geometry.cluster_count) + 2,
		)
		testing.expect(t, geometry.disk_sectors <= LBA28_SECTOR_LIMIT)
	}
}

@(test)
fat32image_test_geometry_rejects_capacity_outside_contract :: proc(t: ^testing.T) {
	_, below := geometry_for_capacity(0)
	_, above := geometry_for_capacity(128)
	testing.expect_value(t, below.code, Error_Code.Capacity_Out_Of_Range)
	testing.expect_value(t, above.code, Error_Code.Capacity_Out_Of_Range)
}
