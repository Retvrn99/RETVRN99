// SPDX-License-Identifier: GPL-3.0-only
package opticalmedia

Optical_Media_Fake :: struct {
	observation:   Optical_Media_Observation,
	data_sectors:  []u8,
	raw_sectors:   []u8,
	audio_frames:  []u8,
	packet_data:   []u8,
	packet_result: Optical_Media_Packet_Result,
	packet_calls:  u64,
	last_cdb:      [16]u8,
	last_cdb_len:  int,
}

optical_media_fake_adapters :: proc(
	fake: ^Optical_Media_Fake,
	packet_transport := false,
) -> Optical_Media_Adapters {
	if fake == nil {return {}}
	return {
		ctx = fake,
		observe = optical_media_fake_observe,
		track_at_lba = optical_media_fake_track_at_lba,
		read_data_sector = optical_media_fake_read_data_sector,
		read_raw_sector = optical_media_fake_read_raw_sector,
		read_audio_frame = optical_media_fake_read_audio_frame,
		execute_read_only = packet_transport ? optical_media_fake_execute_read_only : nil,
	}
}

@(private = "file")
optical_media_fake_observe :: proc(ctx: rawptr) -> Optical_Media_Observation {
	return (^Optical_Media_Fake)(ctx).observation
}

@(private = "file")
optical_media_fake_track_at_lba :: proc(ctx: rawptr, lba: u32) -> (Disc_Track, bool) {
	fake := (^Optical_Media_Fake)(ctx)
	for i in 0 ..< int(fake.observation.track_count) {
		track := fake.observation.tracks[i]
		if lba >= track.start_lba && u64(lba) < u64(track.start_lba) + u64(track.sector_count) {
			return track, true
		}
	}
	return {}, false
}

@(private = "file")
optical_media_fake_read_at :: proc(bytes: []u8, lba: u32, sector_size: int, out: []u8) -> bool {
	if sector_size <= 0 || len(out) != sector_size {return false}
	start := u64(lba) * u64(sector_size)
	if start > u64(len(bytes)) || u64(sector_size) > u64(len(bytes)) - start {return false}
	copy(out, bytes[int(start):int(start) + sector_size])
	return true
}

@(private = "file")
optical_media_fake_read_data_sector :: proc(ctx: rawptr, lba: u32, out: []u8) -> bool {
	return optical_media_fake_read_at(
		(^Optical_Media_Fake)(ctx).data_sectors,
		lba,
		DISC_DATA_SECTOR_SIZE,
		out,
	)
}

@(private = "file")
optical_media_fake_read_raw_sector :: proc(ctx: rawptr, lba: u32, out: []u8) -> bool {
	return optical_media_fake_read_at(
		(^Optical_Media_Fake)(ctx).raw_sectors,
		lba,
		DISC_RAW_SECTOR_SIZE,
		out,
	)
}

@(private = "file")
optical_media_fake_read_audio_frame :: proc(ctx: rawptr, lba: u32, out: []u8) -> bool {
	return optical_media_fake_read_at(
		(^Optical_Media_Fake)(ctx).audio_frames,
		lba,
		DISC_RAW_SECTOR_SIZE,
		out,
	)
}

@(private = "file")
optical_media_fake_execute_read_only :: proc(
	ctx: rawptr,
	cdb: []u8,
	out: []u8,
) -> Optical_Media_Packet_Result {
	fake := (^Optical_Media_Fake)(ctx)
	fake.packet_calls += 1
	fake.last_cdb = {}
	fake.last_cdb_len = min(len(cdb), len(fake.last_cdb))
	copy(fake.last_cdb[:], cdb[:fake.last_cdb_len])
	result := fake.packet_result
	if result.status == .Data {
		length := min(len(fake.packet_data), len(out))
		if result.transferred > 0 {length = min(length, result.transferred)}
		copy(out[:length], fake.packet_data[:length])
		result.transferred = length
	}
	return result
}
