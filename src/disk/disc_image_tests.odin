// SPDX-License-Identifier: GPL-3.0-only
package disk

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:testing"
import "core:time"

disc_image_test_path :: proc(name: string) -> string {
	base, _ := os.temp_directory(context.temp_allocator)
	path, _ := filepath.join(
		{base, fmt.tprintf("retvrn99_disc_%d_%s", time.now()._nsec, name)},
		context.temp_allocator,
	)
	return path
}

disc_image_test_iso_bytes :: proc(sectors := 24) -> []u8 {
	data := make([]u8, sectors * DISC_DATA_SECTOR_SIZE, context.temp_allocator)
	pvd := data[16 * DISC_DATA_SECTOR_SIZE:][:DISC_DATA_SECTOR_SIZE]
	pvd[0] = 1
	copy(pvd[1:6], "CD001")
	pvd[6] = 1
	return data
}

disc_image_test_raw_header :: proc(frame: []u8) {
	frame[0] = 0
	for i in 1 ..= 10 {
		frame[i] = 0xFF
	}
	frame[11] = 0
	frame[15] = 1
}

@(test)
disc_image_test_iso_mount_tracks_reads_and_msf :: proc(t: ^testing.T) {
	path := disc_image_test_path("plain.iso")
	defer os.remove(path)
	data := disc_image_test_iso_bytes()
	data[18 * DISC_DATA_SECTOR_SIZE] = 0xA5
	data[18 * DISC_DATA_SECTOR_SIZE + 2047] = 0x5A
	testing.expect(t, os.write_entire_file(path, data) == nil)

	image: Disc_Image
	testing.expect(t, disc_image_mount(&image, path))
	defer disc_image_eject(&image)
	testing.expect_value(t, image.track_count, u8(1))
	testing.expect_value(t, image.total_sectors, u32(24))
	testing.expect_value(t, image.tracks[0].mode, Disc_Track_Mode.Mode1_2048)
	testing.expect_value(t, image.media_class, Disc_Media_Class.Compact_Disc)

	sector: [DISC_DATA_SECTOR_SIZE]u8
	testing.expect(t, disc_image_read_data_sector(&image, 18, sector[:]))
	testing.expect_value(t, sector[0], u8(0xA5))
	testing.expect_value(t, sector[2047], u8(0x5A))
	testing.expect(t, !disc_image_read_data_sector(&image, 24, sector[:]))

	msf := disc_image_lba_to_msf(0)
	testing.expect_value(t, msf, Disc_Msf{minute = 0, second = 2, frame = 0})
	lba, ok := disc_image_msf_to_lba(disc_image_lba_to_msf(12_345))
	testing.expect(t, ok)
	testing.expect_value(t, lba, u32(12_345))
	_, ok = disc_image_msf_to_lba(Disc_Msf{second = 60})
	testing.expect(t, !ok)
}

@(test)
disc_image_test_explicit_dvd_class_for_ambiguous_iso :: proc(t: ^testing.T) {
	path := disc_image_test_path("small dvd.iso")
	defer os.remove(path)
	testing.expect(t, os.write_entire_file(path, disc_image_test_iso_bytes()) == nil)

	image: Disc_Image
	testing.expect(t, disc_image_mount_classified(&image, path, .Dvd_Rom))
	defer disc_image_eject(&image)
	testing.expect_value(t, image.media_class, Disc_Media_Class.Dvd_Rom)
}

@(test)
disc_image_test_dvd_class_rejects_cd_raw_layout :: proc(t: ^testing.T) {
	path := disc_image_test_path("raw compact disc.bin")
	defer os.remove(path)
	data := make([]u8, 24 * DISC_RAW_SECTOR_SIZE, context.temp_allocator)
	for lba in 0 ..< 24 {disc_image_test_raw_header(data[lba * DISC_RAW_SECTOR_SIZE:])}
	pvd := data[16 * DISC_RAW_SECTOR_SIZE + 16:]
	pvd[0] = 1
	copy(pvd[1:6], "CD001")
	pvd[6] = 1
	testing.expect(t, os.write_entire_file(path, data) == nil)

	image: Disc_Image
	testing.expect(t, !disc_image_mount_classified(&image, path, .Dvd_Rom))
	testing.expect(t, !disc_image_present(&image))
}

@(test)
disc_image_test_direct_mode1_2352_detection_and_unwrap :: proc(t: ^testing.T) {
	path := disc_image_test_path("raw.bin")
	defer os.remove(path)
	data := make([]u8, 24 * DISC_RAW_SECTOR_SIZE, context.temp_allocator)
	for lba in 0 ..< 24 {
		frame := data[lba * DISC_RAW_SECTOR_SIZE:][:DISC_RAW_SECTOR_SIZE]
		disc_image_test_raw_header(frame)
	}
	pvd := data[16 * DISC_RAW_SECTOR_SIZE + 16:]
	pvd[0] = 1
	copy(pvd[1:6], "CD001")
	pvd[6] = 1
	data[19 * DISC_RAW_SECTOR_SIZE + 16] = 0x19
	data[19 * DISC_RAW_SECTOR_SIZE + 16 + 2047] = 0x91
	testing.expect(t, os.write_entire_file(path, data) == nil)

	image: Disc_Image
	testing.expect(t, disc_image_mount(&image, path))
	defer disc_image_eject(&image)
	testing.expect_value(t, image.tracks[0].mode, Disc_Track_Mode.Mode1_2352)
	sector: [DISC_DATA_SECTOR_SIZE]u8
	testing.expect(t, disc_image_read_data_sector(&image, 19, sector[:]))
	testing.expect_value(t, sector[0], u8(0x19))
	testing.expect_value(t, sector[2047], u8(0x91))

	audio: [DISC_RAW_SECTOR_SIZE]u8
	testing.expect(t, !disc_image_read_audio_frame(&image, 19, audio[:]))
}

@(test)
disc_image_test_cue_mixed_mode_track_table_and_reads :: proc(t: ^testing.T) {
	bin_path := disc_image_test_path("mixed image.bin")
	cue_path := disc_image_test_path("mixed.cue")
	defer os.remove(bin_path)
	defer os.remove(cue_path)

	bin := make([]u8, 2 * DISC_DATA_SECTOR_SIZE + 5 * DISC_RAW_SECTOR_SIZE, context.temp_allocator)
	bin[DISC_DATA_SECTOR_SIZE] = 0x11
	mode1_offset := 2 * DISC_DATA_SECTOR_SIZE
	bin[mode1_offset + 16] = 0x22
	bin[mode1_offset + DISC_RAW_SECTOR_SIZE + 16] = 0x23
	audio_offset := mode1_offset + 2 * DISC_RAW_SECTOR_SIZE
	bin[audio_offset] = 0x33
	bin[audio_offset + 2 * DISC_RAW_SECTOR_SIZE + 2351] = 0x35
	testing.expect(t, os.write_entire_file(bin_path, bin) == nil)

	cue := fmt.tprintf(
		"FILE \"%s\" BINARY\nTRACK 01 MODE1/2048\nINDEX 01 00:00:00\nTRACK 02 MODE1/2352\nINDEX 01 00:00:02\nTRACK 03 AUDIO\nINDEX 01 00:00:04\n",
		filepath.base(bin_path),
	)
	testing.expect(t, os.write_entire_file(cue_path, transmute([]u8)cue) == nil)

	image: Disc_Image
	testing.expect(t, disc_image_mount(&image, cue_path))
	defer disc_image_eject(&image)
	testing.expect_value(t, image.track_count, u8(3))
	testing.expect_value(t, image.total_sectors, u32(7))
	testing.expect_value(t, image.tracks[1].file_offset, u64(2 * DISC_DATA_SECTOR_SIZE))
	testing.expect_value(
		t,
		image.tracks[2].file_offset,
		u64(2 * DISC_DATA_SECTOR_SIZE + 2 * DISC_RAW_SECTOR_SIZE),
	)

	sector: [DISC_DATA_SECTOR_SIZE]u8
	testing.expect(t, disc_image_read_data_sector(&image, 1, sector[:]))
	testing.expect_value(t, sector[0], u8(0x11))
	testing.expect(t, disc_image_read_data_sector(&image, 2, sector[:]))
	testing.expect_value(t, sector[0], u8(0x22))
	testing.expect(t, !disc_image_read_data_sector(&image, 4, sector[:]))

	audio: [DISC_RAW_SECTOR_SIZE]u8
	testing.expect(t, disc_image_read_audio_frame(&image, 4, audio[:]))
	testing.expect_value(t, audio[0], u8(0x33))
	testing.expect(t, disc_image_read_audio_frame(&image, 6, audio[:]))
	testing.expect_value(t, audio[2351], u8(0x35))
	testing.expect(t, !disc_image_read_audio_frame(&image, 3, audio[:]))
}

@(test)
disc_image_test_malformed_mount_is_atomic :: proc(t: ^testing.T) {
	iso_path := disc_image_test_path("atomic.iso")
	bin_path := disc_image_test_path("bad.bin")
	cue_path := disc_image_test_path("bad.cue")
	defer os.remove(iso_path)
	defer os.remove(bin_path)
	defer os.remove(cue_path)

	iso := disc_image_test_iso_bytes()
	iso[20 * DISC_DATA_SECTOR_SIZE] = 0xC7
	testing.expect(t, os.write_entire_file(iso_path, iso) == nil)
	testing.expect(
		t,
		os.write_entire_file(
			bin_path,
			make([]u8, DISC_RAW_SECTOR_SIZE + 1, context.temp_allocator),
		) ==
		nil,
	)
	bad_cue := fmt.tprintf(
		"FILE \"%s\" BINARY\nTRACK 01 AUDIO\nINDEX 01 00:00:00\n",
		filepath.base(bin_path),
	)
	testing.expect(t, os.write_entire_file(cue_path, transmute([]u8)bad_cue) == nil)

	image: Disc_Image
	testing.expect(t, disc_image_mount(&image, iso_path))
	defer disc_image_eject(&image)
	testing.expect(t, !disc_image_mount(&image, cue_path))
	testing.expect_value(t, image.track_count, u8(1))
	testing.expect_value(t, image.tracks[0].mode, Disc_Track_Mode.Mode1_2048)
	sector: [DISC_DATA_SECTOR_SIZE]u8
	testing.expect(t, disc_image_read_data_sector(&image, 20, sector[:]))
	testing.expect_value(t, sector[0], u8(0xC7))

	malformed_path := disc_image_test_path("random.bin")
	defer os.remove(malformed_path)
	testing.expect(
		t,
		os.write_entire_file(
			malformed_path,
			make([]u8, 24 * DISC_RAW_SECTOR_SIZE, context.temp_allocator),
		) ==
		nil,
	)
	testing.expect(t, !disc_image_mount(&image, malformed_path))
	testing.expect(t, disc_image_read_data_sector(&image, 20, sector[:]))
}

@(test)
disc_image_test_cue_nonzero_first_index_sets_file_offset :: proc(t: ^testing.T) {
	bin_path := disc_image_test_path("offset.bin")
	cue_path := disc_image_test_path("offset.cue")
	defer os.remove(bin_path)
	defer os.remove(cue_path)
	bin := make([]u8, 4 * DISC_DATA_SECTOR_SIZE, context.temp_allocator)
	bin[2 * DISC_DATA_SECTOR_SIZE] = 0x62
	bin[3 * DISC_DATA_SECTOR_SIZE] = 0x63
	testing.expect(t, os.write_entire_file(bin_path, bin) == nil)
	cue := fmt.tprintf(
		"FILE \"%s\" BINARY\nTRACK 01 MODE1/2048\nINDEX 01 00:00:02\n",
		filepath.base(bin_path),
	)
	testing.expect(t, os.write_entire_file(cue_path, transmute([]u8)cue) == nil)

	image: Disc_Image
	testing.expect(t, disc_image_mount(&image, cue_path))
	defer disc_image_eject(&image)
	testing.expect_value(t, image.tracks[0].start_lba, u32(2))
	testing.expect_value(t, image.tracks[0].file_offset, u64(2 * DISC_DATA_SECTOR_SIZE))
	testing.expect_value(t, image.tracks[0].sector_count, u32(2))
	sector: [DISC_DATA_SECTOR_SIZE]u8
	testing.expect(t, !disc_image_read_data_sector(&image, 0, sector[:]))
	testing.expect(t, disc_image_read_data_sector(&image, 2, sector[:]))
	testing.expect_value(t, sector[0], u8(0x62))
}

@(test)
disc_image_test_cue_index_zero_keeps_stored_pregap_out_of_tracks :: proc(t: ^testing.T) {
	bin_path := disc_image_test_path("index-zero.bin")
	cue_path := disc_image_test_path("index-zero.cue")
	defer os.remove(bin_path)
	defer os.remove(cue_path)
	bin := make(
		[]u8,
		2 * DISC_DATA_SECTOR_SIZE + 2 * DISC_RAW_SECTOR_SIZE,
		context.temp_allocator,
	)
	bin[2 * DISC_DATA_SECTOR_SIZE] = 0xE0
	audio_offset := 2 * DISC_DATA_SECTOR_SIZE + DISC_RAW_SECTOR_SIZE
	bin[audio_offset] = 0xA3
	testing.expect(t, os.write_entire_file(bin_path, bin) == nil)
	cue := fmt.tprintf(
		"FILE \"%s\" BINARY\nTRACK 01 MODE1/2048\nINDEX 01 00:00:00\nTRACK 02 AUDIO\nINDEX 00 00:00:02\nINDEX 01 00:00:03\n",
		filepath.base(bin_path),
	)
	testing.expect(t, os.write_entire_file(cue_path, transmute([]u8)cue) == nil)

	image: Disc_Image
	testing.expect(t, disc_image_mount(&image, cue_path))
	defer disc_image_eject(&image)
	testing.expect_value(t, image.tracks[0].sector_count, u32(2))
	testing.expect_value(t, image.tracks[1].start_lba, u32(3))
	testing.expect_value(t, image.tracks[1].file_offset, u64(audio_offset))
	_, gap_present := disc_image_track_at_lba(&image, 2)
	testing.expect(t, !gap_present)
	audio: [DISC_RAW_SECTOR_SIZE]u8
	testing.expect(t, disc_image_read_audio_frame(&image, 3, audio[:]))
	testing.expect_value(t, audio[0], u8(0xA3))
}

@(test)
disc_image_test_cue_rejects_invalid_layouts :: proc(t: ^testing.T) {
	_, ok := disc_image_parse_cue(
		"FILE \"x.bin\" BINARY\nTRACK 01 MODE2/2352\nINDEX 01 00:00:00\n",
	)
	testing.expect(t, !ok)
	_, ok = disc_image_parse_cue(
		"FILE \"x.bin\" BINARY\nTRACK 01 AUDIO\nINDEX 01 00:01:00\nTRACK 02 AUDIO\nINDEX 01 00:00:00\n",
	)
	testing.expect(t, !ok)
	_, ok = disc_image_parse_cue(
		"FILE \"a.bin\" BINARY\nFILE \"b.bin\" BINARY\nTRACK 01 AUDIO\nINDEX 01 00:00:00\n",
	)
	testing.expect(t, !ok)
	_, ok = disc_image_parse_cue("FILE \"x.bin\" BINARY\nTRACK 01 AUDIO\nINDEX 01 00:60:00\n")
	testing.expect(t, !ok)
	_, ok = disc_image_parse_cue(
		"FILE \"x.bin\" BINARY\nTRACK 01 AUDIO\nPREGAP 00:02:00\nINDEX 01 00:00:00\n",
	)
	testing.expect(t, !ok)
	_, ok = disc_image_parse_cue(
		"FILE \"x.bin\" BINARY\nTRACK 01 AUDIO\nINDEX 00 00:00:02\nINDEX 01 00:00:01\n",
	)
	testing.expect(t, !ok)
	_, ok = disc_image_parse_cue(
		"FILE \"x.bin\" BINARY\nTRACK 01 AUDIO\nINDEX 02 00:00:00\n",
	)
	testing.expect(t, !ok)
}
