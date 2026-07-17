// SPDX-License-Identifier: GPL-3.0-only
package fat32fs

import "core:slice"

root_short_entry_in_first_cluster :: proc(
	volume: ^Volume,
	short_name: [11]u8,
	expected_first_cluster: u32,
) -> (
	bool,
	Error,
) {
	if volume == nil || expected_first_cluster < 2 {
		return false, error_make(.Invalid_Argument, "FAT32 boot entry target is invalid")
	}
	lba, lba_error := cluster_lba(volume, volume.info.root_cluster)
	if lba_error.code != .None {return false, lba_error}
	wanted := short_name
	sector: [SECTOR_BYTES]u8
	for sector_index in 0 ..< int(volume.info.sectors_per_cluster) {
		if !volume.device.read(volume.device.ctx, lba + u64(sector_index), sector[:]) {
			return false, error_make(.IO, "cannot read the first FAT32 root-directory cluster")
		}
		for offset := 0; offset < SECTOR_BYTES; offset += 32 {
			slot := sector[offset:offset + 32]
			if slot[0] == 0 {return false, {}}
			if slot[0] == 0xe5 || slot[11] & 0x3f == ATTR_LFN || slot[11] & (ATTR_VOLUME | ATTR_DIRECTORY) != 0 {
				continue
			}
			if !slice.equal(slot[:11], wanted[:]) {continue}
			first_cluster := u32(get_u16le(slot, 20)) << 16 | u32(get_u16le(slot, 26))
			return first_cluster == expected_first_cluster, {}
		}
	}
	return false, {}
}
