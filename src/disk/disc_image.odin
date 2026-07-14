// SPDX-License-Identifier: GPL-3.0-only
package disk

import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

DISC_DATA_SECTOR_SIZE :: 2048
DISC_RAW_SECTOR_SIZE :: 2352
DISC_FRAMES_PER_SECOND :: 75
DISC_LEAD_IN_FRAMES :: 150
DISC_MAX_TRACKS :: 99
DISC_VALIDATE_CHUNK_FRAMES :: 256
DISC_CD_MAX_SECTORS :: 100 * 60 * DISC_FRAMES_PER_SECOND

Disc_Media_Class :: enum u8 {
	Auto,
	Compact_Disc,
	Dvd_Rom,
}

Disc_Track_Mode :: enum u8 {
	Mode1_2048,
	Mode1_2352,
	Audio_2352,
}

Disc_Track :: struct {
	number:       u8,
	mode:         Disc_Track_Mode,
	start_lba:    u32,
	sector_count: u32,
	file_offset:  u64,
}

Disc_Msf :: struct {
	minute: u8,
	second: u8,
	frame:  u8,
}

Disc_Image :: struct {
	file:          ^os.File,
	tracks:        [DISC_MAX_TRACKS]Disc_Track,
	track_count:   u8,
	total_sectors: u32,
	media_class:   Disc_Media_Class,
}

// Track parsing and sector layout are adapted from IzarraVM cdimage.rs,
// commit d930de57acccbc6a70cda8cc5a603173bf23cd1c.
disc_image_mount :: proc(image: ^Disc_Image, path: string) -> bool {
	return disc_image_mount_classified(image, path, .Auto)
}

disc_image_mount_classified :: proc(
	image: ^Disc_Image,
	path: string,
	media_class: Disc_Media_Class,
) -> bool {
	if image == nil || len(path) == 0 {
		return false
	}

	candidate: Disc_Image
	ok := false
	if strings.equal_fold(filepath.ext(path), ".cue") {
		ok = media_class != .Dvd_Rom && disc_image_mount_cue(&candidate, path)
	} else {
		ok = disc_image_mount_direct(&candidate, path, media_class)
	}
	if !ok {
		disc_image_eject(&candidate)
		return false
	}

	disc_image_eject(image)
	image^ = candidate
	return true
}

disc_image_eject :: proc(image: ^Disc_Image) {
	if image == nil {
		return
	}
	if image.file != nil {
		os.close(image.file)
	}
	image^ = {}
}

disc_image_present :: proc(image: ^Disc_Image) -> bool {
	return image != nil && image.file != nil && image.track_count > 0
}

disc_image_track_at_lba :: proc(image: ^Disc_Image, lba: u32) -> (^Disc_Track, bool) {
	if !disc_image_present(image) {
		return nil, false
	}
	for i in 0 ..< int(image.track_count) {
		track := &image.tracks[i]
		end := u64(track.start_lba) + u64(track.sector_count)
		if lba >= track.start_lba && u64(lba) < end {
			return track, true
		}
	}
	return nil, false
}

disc_image_read_data_sector :: proc(image: ^Disc_Image, lba: u32, out: []u8) -> bool {
	if len(out) != DISC_DATA_SECTOR_SIZE {
		return false
	}
	track, ok := disc_image_track_at_lba(image, lba)
	if !ok || track.mode == .Audio_2352 {
		return false
	}

	raw_size := disc_track_raw_size(track.mode)
	offset := track.file_offset + u64(lba - track.start_lba) * raw_size
	if track.mode == .Mode1_2352 {
		offset += 16
	}
	return disc_image_read_exact(image.file, offset, out)
}

disc_image_read_data_sectors :: proc(
	image: ^Disc_Image,
	lba, count: u32,
	out: []u8,
) -> bool {
	if count == 0 {return len(out) == 0}
	if u64(count) * DISC_DATA_SECTOR_SIZE != u64(len(out)) {return false}
	cursor := lba
	remaining := count
	written := 0
	for remaining > 0 {
		track, ok := disc_image_track_at_lba(image, cursor)
		if !ok || track.mode == .Audio_2352 {return false}
		track_end := u64(track.start_lba) + u64(track.sector_count)
		run := u32(min(track_end - u64(cursor), u64(remaining)))
		if run == 0 {return false}
		if track.mode == .Mode1_2048 {
			bytes := int(run) * DISC_DATA_SECTOR_SIZE
			offset := track.file_offset + u64(cursor - track.start_lba) * DISC_DATA_SECTOR_SIZE
			if !disc_image_read_exact(image.file, offset, out[written:written + bytes]) {return false}
			written += bytes
		} else {
			for index in 0 ..< run {
				sector := out[written:written + DISC_DATA_SECTOR_SIZE]
				if !disc_image_read_data_sector(image, cursor + index, sector) {return false}
				written += DISC_DATA_SECTOR_SIZE
			}
		}
		cursor += run
		remaining -= run
	}
	return true
}

disc_image_read_audio_frame :: proc(image: ^Disc_Image, lba: u32, out: []u8) -> bool {
	if len(out) != DISC_RAW_SECTOR_SIZE {
		return false
	}
	track, ok := disc_image_track_at_lba(image, lba)
	if !ok || track.mode != .Audio_2352 {
		return false
	}
	offset := track.file_offset + u64(lba - track.start_lba) * DISC_RAW_SECTOR_SIZE
	return disc_image_read_exact(image.file, offset, out)
}

disc_image_read_raw_sector :: proc(image: ^Disc_Image, lba: u32, out: []u8) -> bool {
	if len(out) != DISC_RAW_SECTOR_SIZE {return false}
	track, ok := disc_image_track_at_lba(image, lba)
	if !ok {return false}
	if track.mode != .Mode1_2048 {
		offset := track.file_offset + u64(lba - track.start_lba) * DISC_RAW_SECTOR_SIZE
		return disc_image_read_exact(image.file, offset, out)
	}
	for &byte in out {byte = 0}
	for i in 1 ..= 10 {out[i] = 0xFF}
	msf := disc_image_lba_to_msf(lba)
	out[12] = (msf.minute / 10) << 4 | msf.minute % 10
	out[13] = (msf.second / 10) << 4 | msf.second % 10
	out[14] = (msf.frame / 10) << 4 | msf.frame % 10
	out[15] = 1
	return disc_image_read_data_sector(image, lba, out[16:16 + DISC_DATA_SECTOR_SIZE])
}

disc_image_lba_to_msf :: proc(lba: u32) -> Disc_Msf {
	total := u64(lba) + DISC_LEAD_IN_FRAMES
	return Disc_Msf {
		minute = u8(total / (60 * DISC_FRAMES_PER_SECOND)),
		second = u8(total / DISC_FRAMES_PER_SECOND % 60),
		frame = u8(total % DISC_FRAMES_PER_SECOND),
	}
}

disc_image_msf_to_lba :: proc(msf: Disc_Msf) -> (u32, bool) {
	if msf.second >= 60 || msf.frame >= DISC_FRAMES_PER_SECOND {
		return 0, false
	}
	frames := (u32(msf.minute) * 60 + u32(msf.second)) * DISC_FRAMES_PER_SECOND + u32(msf.frame)
	if frames < DISC_LEAD_IN_FRAMES {
		return 0, true
	}
	return frames - DISC_LEAD_IN_FRAMES, true
}

@(private = "file")
disc_image_mount_direct :: proc(
	image: ^Disc_Image,
	path: string,
	media_class: Disc_Media_Class,
) -> bool {
	f, open_error := os.open(path, {.Read})
	if open_error != nil {
		return false
	}
	image.file = f

	size_i64, size_error := os.file_size(f)
	if size_error != nil || size_i64 <= 0 {
		return false
	}
	size := u64(size_i64)

	mode: Disc_Track_Mode
	sectors: u64
	if size % DISC_DATA_SECTOR_SIZE == 0 && disc_image_has_pvd(f, DISC_DATA_SECTOR_SIZE, 0) {
		mode = .Mode1_2048
		sectors = size / DISC_DATA_SECTOR_SIZE
	} else if size % DISC_RAW_SECTOR_SIZE == 0 &&
	   disc_image_has_pvd(f, DISC_RAW_SECTOR_SIZE, 16) &&
	   disc_image_validate_raw_mode1(f, size / DISC_RAW_SECTOR_SIZE) {
		mode = .Mode1_2352
		sectors = size / DISC_RAW_SECTOR_SIZE
	} else {
		return false
	}
	if sectors == 0 || sectors > u64(max(u32)) {
		return false
	}
	if mode == .Mode1_2352 {
		if media_class == .Dvd_Rom {return false}
		image.media_class = .Compact_Disc
	} else {
		switch media_class {
		case .Auto:
			image.media_class = sectors > DISC_CD_MAX_SECTORS ? .Dvd_Rom : .Compact_Disc
		case .Compact_Disc:
			if sectors > DISC_CD_MAX_SECTORS {return false}
			image.media_class = .Compact_Disc
		case .Dvd_Rom:
			image.media_class = .Dvd_Rom
		}
	}

	image.tracks[0] = Disc_Track {
		number       = 1,
		mode         = mode,
		start_lba    = 0,
		sector_count = u32(sectors),
	}
	image.track_count = 1
	image.total_sectors = u32(sectors)
	return true
}

Disc_Cue_Track :: struct {
	number:           u8,
	mode:             Disc_Track_Mode,
	start_frame:      u32,
	index_zero_frame: u32,
	has_index_zero:   bool,
}

Disc_Cue :: struct {
	file_name:   string,
	tracks:      [DISC_MAX_TRACKS]Disc_Cue_Track,
	track_count: int,
}

@(private = "file")
disc_image_mount_cue :: proc(image: ^Disc_Image, cue_path: string) -> bool {
	data, read_error := os.read_entire_file(cue_path, context.temp_allocator)
	if read_error != nil {
		return false
	}
	defer delete(data, context.temp_allocator)

	parsed, ok := disc_image_parse_cue(string(data))
	if !ok {
		return false
	}

	bin_path := parsed.file_name
	joined: string
	if !filepath.is_abs(bin_path) {
		joined, _ = filepath.join({filepath.dir(cue_path), bin_path}, context.temp_allocator)
		if len(joined) == 0 {
			return false
		}
		defer delete(joined, context.temp_allocator)
		bin_path = joined
	}

	f, open_error := os.open(bin_path, {.Read})
	if open_error != nil {
		return false
	}
	image.file = f
	size_i64, size_error := os.file_size(f)
	if size_error != nil || size_i64 <= 0 {
		return false
	}
	size := u64(size_i64)

	first := parsed.tracks[0]
	offset := u64(first.start_frame) * disc_track_raw_size(first.mode)
	if offset > size {return false}
	total: u64
	for i in 0 ..< parsed.track_count {
		entry := parsed.tracks[i]
		raw_size := disc_track_raw_size(entry.mode)
		sectors: u64
		if i + 1 < parsed.track_count {
			next := parsed.tracks[i + 1]
			end_frame := next.start_frame
			if next.has_index_zero {
				end_frame = next.index_zero_frame
			}
			if end_frame <= entry.start_frame || end_frame > next.start_frame {
				return false
			}
			sectors = u64(end_frame - entry.start_frame)
		} else {
			remaining := size - min(size, offset)
			if remaining == 0 || remaining % raw_size != 0 {
				return false
			}
			sectors = remaining / raw_size
		}

		span := sectors * raw_size
		if sectors == 0 || sectors > u64(max(u32)) || offset > size || span > size - offset {
			return false
		}
		end := u64(entry.start_frame) + sectors
		if end > u64(max(u32)) {
			return false
		}
		image.tracks[i] = Disc_Track {
			number       = entry.number,
			mode         = entry.mode,
			start_lba    = entry.start_frame,
			sector_count = u32(sectors),
			file_offset  = offset,
		}
		offset += span
		total = max(total, end)
		if i + 1 < parsed.track_count {
			next := parsed.tracks[i + 1]
			if next.has_index_zero {
				gap_frames := u64(next.start_frame - next.index_zero_frame)
				gap_bytes := gap_frames * disc_track_raw_size(next.mode)
				if gap_bytes > size - min(size, offset) {return false}
				offset += gap_bytes
			}
		}
	}
	if offset != size {
		return false
	}

	image.track_count = u8(parsed.track_count)
	image.total_sectors = u32(total)
	image.media_class = .Compact_Disc
	return true
}

@(private)
disc_image_parse_cue :: proc(text: string) -> (Disc_Cue, bool) {
	result: Disc_Cue
	pending: Disc_Cue_Track
	has_pending := false
	last_number := 0
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		pos := 0
		keyword, found := disc_cue_next_word(line, &pos)
		if !found {
			continue
		}

		if strings.equal_fold(keyword, "FILE") {
			if len(result.file_name) != 0 || result.track_count != 0 || has_pending {
				return {}, false
			}
			name, has_name := disc_cue_next_word(line, &pos)
			kind, has_kind := disc_cue_next_word(line, &pos)
			if !has_name || !has_kind || len(name) == 0 || !strings.equal_fold(kind, "BINARY") {
				return {}, false
			}
			result.file_name = name
		} else if strings.equal_fold(keyword, "TRACK") {
			if len(result.file_name) == 0 || has_pending || result.track_count >= DISC_MAX_TRACKS {
				return {}, false
			}
			number_text, has_number := disc_cue_next_word(line, &pos)
			mode_text, has_mode := disc_cue_next_word(line, &pos)
			number, number_ok := strconv.parse_int(number_text, 10)
			if !has_number ||
			   !has_mode ||
			   !number_ok ||
			   number != last_number + 1 ||
			   number > DISC_MAX_TRACKS {
				return {}, false
			}
			mode, mode_ok := disc_cue_track_mode(mode_text)
			if !mode_ok {
				return {}, false
			}
			pending = Disc_Cue_Track {
				number = u8(number),
				mode   = mode,
			}
			has_pending = true
			last_number = number
		} else if strings.equal_fold(keyword, "INDEX") {
			index_text, has_index := disc_cue_next_word(line, &pos)
			index, index_ok := strconv.parse_int(index_text, 10)
			if !has_index || !index_ok || (index != 0 && index != 1) {
				return {}, false
			}
			msf_text, has_msf := disc_cue_next_word(line, &pos)
			start, msf_ok := disc_cue_parse_msf(msf_text)
			if !has_pending || !has_msf || !msf_ok {
				return {}, false
			}
			if index == 0 {
				if pending.has_index_zero {return {}, false}
				pending.index_zero_frame = start
				pending.has_index_zero = true
				continue
			}
			if pending.has_index_zero && pending.index_zero_frame >= start {
				return {}, false
			}
			if result.track_count > 0 &&
			   start <= result.tracks[result.track_count - 1].start_frame {
				return {}, false
			}
			pending.start_frame = start
			result.tracks[result.track_count] = pending
			result.track_count += 1
			has_pending = false
		} else if strings.equal_fold(keyword, "PREGAP") ||
		          strings.equal_fold(keyword, "POSTGAP") {
			return {}, false
		}
	}
	if len(result.file_name) == 0 || result.track_count == 0 || has_pending {
		return {}, false
	}
	return result, true
}

@(private = "file")
disc_cue_next_word :: proc(line: string, pos: ^int) -> (string, bool) {
	for pos^ < len(line) && (line[pos^] == ' ' || line[pos^] == '\t' || line[pos^] == '\r') {
		pos^ += 1
	}
	if pos^ >= len(line) {
		return "", false
	}

	if line[pos^] == '"' {
		pos^ += 1
		start := pos^
		for pos^ < len(line) && line[pos^] != '"' {
			pos^ += 1
		}
		if pos^ >= len(line) {
			return "", false
		}
		word := line[start:pos^]
		pos^ += 1
		return word, true
	}

	start := pos^
	for pos^ < len(line) && line[pos^] != ' ' && line[pos^] != '\t' && line[pos^] != '\r' {
		pos^ += 1
	}
	return line[start:pos^], true
}

@(private = "file")
disc_cue_track_mode :: proc(text: string) -> (Disc_Track_Mode, bool) {
	if strings.equal_fold(text, "MODE1/2048") {
		return .Mode1_2048, true
	}
	if strings.equal_fold(text, "MODE1/2352") {
		return .Mode1_2352, true
	}
	if strings.equal_fold(text, "AUDIO") || strings.equal_fold(text, "AUDIO/2352") {
		return .Audio_2352, true
	}
	return .Mode1_2048, false
}

@(private = "file")
disc_cue_parse_msf :: proc(text: string) -> (u32, bool) {
	first := strings.index_byte(text, ':')
	if first <= 0 {
		return 0, false
	}
	second_relative := strings.index_byte(text[first + 1:], ':')
	if second_relative <= 0 {
		return 0, false
	}
	second := first + 1 + second_relative
	if second + 1 >= len(text) || strings.index_byte(text[second + 1:], ':') >= 0 {
		return 0, false
	}
	minute, minute_ok := strconv.parse_int(text[:first], 10)
	seconds, second_ok := strconv.parse_int(text[first + 1:second], 10)
	frames, frame_ok := strconv.parse_int(text[second + 1:], 10)
	if !minute_ok ||
	   !second_ok ||
	   !frame_ok ||
	   minute < 0 ||
	   seconds < 0 ||
	   seconds >= 60 ||
	   frames < 0 ||
	   frames >= DISC_FRAMES_PER_SECOND {
		return 0, false
	}
	total :=
		u64(minute) * 60 * DISC_FRAMES_PER_SECOND +
		u64(seconds) * DISC_FRAMES_PER_SECOND +
		u64(frames)
	if total > u64(max(u32)) {
		return 0, false
	}
	return u32(total), true
}

@(private = "file")
disc_track_raw_size :: proc(mode: Disc_Track_Mode) -> u64 {
	switch mode {
	case .Mode1_2048:
		return DISC_DATA_SECTOR_SIZE
	case .Mode1_2352, .Audio_2352:
		return DISC_RAW_SECTOR_SIZE
	}
	return 0
}

@(private = "file")
disc_image_has_pvd :: proc(f: ^os.File, raw_size, payload_offset: u64) -> bool {
	if f == nil {
		return false
	}
	pvd: [7]u8
	offset := u64(16) * raw_size + payload_offset
	return(
		disc_image_read_exact(f, offset, pvd[:]) &&
		pvd[0] == 1 &&
		string(pvd[1:6]) == "CD001" &&
		pvd[6] == 1 \
	)
}

@(private = "file")
disc_image_validate_raw_mode1 :: proc(f: ^os.File, sectors: u64) -> bool {
	if f == nil || sectors < 17 {
		return false
	}
	buffer := make([]u8, DISC_VALIDATE_CHUNK_FRAMES * DISC_RAW_SECTOR_SIZE, context.temp_allocator)
	defer delete(buffer, context.temp_allocator)
	for first: u64 = 0; first < sectors; {
		count := min(u64(DISC_VALIDATE_CHUNK_FRAMES), sectors - first)
		bytes := int(count) * DISC_RAW_SECTOR_SIZE
		if !disc_image_read_exact(f, first * DISC_RAW_SECTOR_SIZE, buffer[:bytes]) {
			return false
		}
		for i in 0 ..< int(count) {
			frame := buffer[i * DISC_RAW_SECTOR_SIZE:][:DISC_RAW_SECTOR_SIZE]
			if !disc_image_raw_mode1_header(frame) {
				return false
			}
		}
		first += count
	}
	return true
}

@(private = "file")
disc_image_raw_mode1_header :: proc(header: []u8) -> bool {
	if len(header) < 16 || header[0] != 0 || header[11] != 0 || header[15] != 1 {
		return false
	}
	for i in 1 ..= 10 {
		if header[i] != 0xFF {
			return false
		}
	}
	return true
}

@(private = "file")
disc_image_read_exact :: proc(f: ^os.File, offset: u64, out: []u8) -> bool {
	if f == nil || offset > u64(max(i64)) {
		return false
	}
	total := 0
	for total < len(out) {
		n, read_error := os.read_at(f, out[total:], i64(offset) + i64(total))
		if n > 0 {
			total += n
		}
		if total == len(out) {
			return true
		}
		if read_error != nil || n <= 0 {
			return false
		}
	}
	return true
}
