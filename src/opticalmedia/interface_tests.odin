// SPDX-License-Identifier: GPL-3.0-only
package opticalmedia

import "core:testing"

@(test)
optical_media_test_in_memory_adapter_owns_capacity_tracks_and_reads :: proc(t: ^testing.T) {
	data := make([]u8, 4 * DISC_DATA_SECTOR_SIZE, context.temp_allocator)
	data[2 * DISC_DATA_SECTOR_SIZE] = 0x22
	data[2 * DISC_DATA_SECTOR_SIZE + 17] = 0x33
	fake := Optical_Media_Fake {
		observation = {
			present = true,
			media_class = .Compact_Disc,
			total_sectors = 4,
			track_count = 1,
			tracks = {0 = {number = 1, mode = .Mode1_2048, sector_count = 4}},
		},
		data_sectors = data,
	}
	media: Optical_Media
	testing.expect(t, optical_media_attach_adapter(&media, optical_media_fake_adapters(&fake)))
	defer optical_media_destroy(&media)
	observation := optical_media_observe(&media)
	testing.expect_value(t, observation.total_sectors, u32(4))
	testing.expect_value(t, observation.tracks[0].mode, Disc_Track_Mode.Mode1_2048)
	sector: [DISC_DATA_SECTOR_SIZE]u8
	testing.expect(t, optical_media_read_data_sector(&media, 2, sector[:]))
	testing.expect_value(t, sector[0], u8(0x22))
	testing.expect_value(t, sector[17], u8(0x33))
	testing.expect(t, !optical_media_mount(&media, "missing-image.iso"))
	testing.expect(t, optical_media_read_data_sector(&media, 2, sector[:]))
}
