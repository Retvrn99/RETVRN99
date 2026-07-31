// SPDX-License-Identifier: GPL-3.0-only
package opticalmedia

Optical_Media_Backing :: enum u8 {
	None,
	Image,
	Host_Drive,
	Adapter,
}

Optical_Media_Observation :: struct {
	backing:       Optical_Media_Backing,
	present:       bool,
	media_class:   Disc_Media_Class,
	total_sectors: u32,
	tracks:        [DISC_MAX_TRACKS]Disc_Track,
	track_count:   u8,
}

Optical_Media_Sense :: struct {
	key:  u8,
	asc:  u8,
	ascq: u8,
}

Optical_Media_Packet_Status :: enum u8 {
	Not_Handled,
	Complete,
	Data,
	Check_Condition,
	Rejected,
}

Optical_Media_Packet_Result :: struct {
	status:      Optical_Media_Packet_Status,
	transferred: int,
	sense:       Optical_Media_Sense,
}

Optical_Media_Observe_Proc :: proc(ctx: rawptr) -> Optical_Media_Observation
Optical_Media_Track_Proc :: proc(ctx: rawptr, lba: u32) -> (Disc_Track, bool)
Optical_Media_Read_Proc :: proc(ctx: rawptr, lba: u32, out: []u8) -> bool
Optical_Media_Packet_Proc :: proc(ctx: rawptr, cdb: []u8, out: []u8) -> Optical_Media_Packet_Result

Optical_Media_Adapters :: struct {
	ctx:               rawptr,
	observe:           Optical_Media_Observe_Proc,
	track_at_lba:      Optical_Media_Track_Proc,
	read_data_sector:  Optical_Media_Read_Proc,
	read_raw_sector:   Optical_Media_Read_Proc,
	read_audio_frame:  Optical_Media_Read_Proc,
	execute_read_only: Optical_Media_Packet_Proc,
}

@(private)
Optical_Media_State :: struct {
	backing:            Optical_Media_Backing,
	image:              Disc_Image,
	host:               Host_Optical_Drive,
	adapters:           Optical_Media_Adapters,
	host_adapters:      Host_Optical_Drive_Adapters,
	packet_read_cdb:    [16]u8,
	packet_read_length: int,
}

Optical_Media :: struct {
	state: Optical_Media_State,
}

optical_media_init :: proc(media: ^Optical_Media) {
	if media != nil {media^ = {}}
}

optical_media_destroy :: proc(media: ^Optical_Media) {
	if media == nil {return}
	switch media.state.backing {
	case .Image:
		disc_image_eject(&media.state.image)
	case .Host_Drive:
		host_optical_drive_close(&media.state.host)
	case .None, .Adapter:
	}
	host_adapters := media.state.host_adapters
	media^ = {}
	media.state.host_adapters = host_adapters
}

optical_media_set_host_adapters :: proc(
	media: ^Optical_Media,
	adapters: Host_Optical_Drive_Adapters,
) -> bool {
	if media == nil || optical_media_present(media) {return false}
	media.state.host_adapters = adapters
	return true
}

optical_media_mount :: proc(media: ^Optical_Media, path: string) -> bool {
	return optical_media_mount_classified(media, path, .Auto)
}

optical_media_mount_classified :: proc(
	media: ^Optical_Media,
	path: string,
	media_class: Disc_Media_Class,
) -> bool {
	if media == nil || len(path) == 0 {return false}
	candidate: Optical_Media
	candidate.state.host_adapters = media.state.host_adapters
	if host_optical_drive_is_path(path) {
		if !host_optical_drive_open(&candidate.state.host, path, candidate.state.host_adapters) {
			return false
		}
		candidate.state.backing = .Host_Drive
	} else {
		if !disc_image_mount_classified(&candidate.state.image, path, media_class) {
			return false
		}
		candidate.state.backing = .Image
	}
	optical_media_destroy(media)
	media^ = candidate
	return true
}

optical_media_attach_adapter :: proc(
	media: ^Optical_Media,
	adapters: Optical_Media_Adapters,
) -> bool {
	if media == nil || adapters.observe == nil {return false}
	observation := adapters.observe(adapters.ctx)
	if !optical_media_observation_valid(observation) {return false}
	candidate: Optical_Media
	candidate.state.backing = .Adapter
	candidate.state.adapters = adapters
	candidate.state.host_adapters = media.state.host_adapters
	optical_media_destroy(media)
	media^ = candidate
	return true
}

optical_media_eject :: proc(media: ^Optical_Media) {
	optical_media_destroy(media)
}

optical_media_present :: proc(media: ^Optical_Media) -> bool {
	return optical_media_observe(media).present
}

optical_media_observe :: proc(media: ^Optical_Media) -> Optical_Media_Observation {
	if media == nil {return {}}
	switch media.state.backing {
	case .Image:
		image := &media.state.image
		if !disc_image_present(image) {return {}}
		result := Optical_Media_Observation {
			backing       = .Image,
			present       = true,
			media_class   = image.media_class,
			total_sectors = image.total_sectors,
			track_count   = image.track_count,
		}
		copy(result.tracks[:], image.tracks[:])
		return result
	case .Host_Drive:
		return Optical_Media_Observation {
			backing = .Host_Drive,
			present = host_optical_drive_is_open(&media.state.host),
		}
	case .Adapter:
		adapters := &media.state.adapters
		if adapters.observe == nil {return {}}
		result := adapters.observe(adapters.ctx)
		if !optical_media_observation_valid(result) {return {}}
		result.backing = .Adapter
		return result
	case .None:
		return {}
	}
	return {}
}

optical_media_track_at_lba :: proc(media: ^Optical_Media, lba: u32) -> (Disc_Track, bool) {
	if media == nil {return {}, false}
	switch media.state.backing {
	case .Image:
		track, ok := disc_image_track_at_lba(&media.state.image, lba)
		return ok ? track^ : Disc_Track{}, ok
	case .Adapter:
		adapters := &media.state.adapters
		if adapters.track_at_lba != nil {return adapters.track_at_lba(adapters.ctx, lba)}
	case .None, .Host_Drive:
	}
	return {}, false
}

optical_media_read_data_sector :: proc(media: ^Optical_Media, lba: u32, out: []u8) -> bool {
	if media == nil {return false}
	switch media.state.backing {
	case .Image:
		return disc_image_read_data_sector(&media.state.image, lba, out)
	case .Adapter:
		adapters := &media.state.adapters
		return(
			adapters.read_data_sector != nil &&
			adapters.read_data_sector(adapters.ctx, lba, out) \
		)
	case .None, .Host_Drive:
	}
	return false
}

optical_media_read_data_sectors :: proc(
	media: ^Optical_Media,
	lba, count: u32,
	out: []u8,
) -> bool {
	if media == nil || u64(count) * DISC_DATA_SECTOR_SIZE != u64(len(out)) {return false}
	if media.state.backing == .Image {
		return disc_image_read_data_sectors(&media.state.image, lba, count, out)
	}
	for index in 0 ..< count {
		start := int(index) * DISC_DATA_SECTOR_SIZE
		if !optical_media_read_data_sector(
			media,
			lba + index,
			out[start:start + DISC_DATA_SECTOR_SIZE],
		) {return false}
	}
	return true
}

optical_media_read_raw_sector :: proc(media: ^Optical_Media, lba: u32, out: []u8) -> bool {
	if media == nil {return false}
	switch media.state.backing {
	case .Image:
		return disc_image_read_raw_sector(&media.state.image, lba, out)
	case .Adapter:
		adapters := &media.state.adapters
		return adapters.read_raw_sector != nil && adapters.read_raw_sector(adapters.ctx, lba, out)
	case .None, .Host_Drive:
	}
	return false
}

optical_media_read_audio_frame :: proc(media: ^Optical_Media, lba: u32, out: []u8) -> bool {
	if media == nil {return false}
	switch media.state.backing {
	case .Image:
		return disc_image_read_audio_frame(&media.state.image, lba, out)
	case .Adapter:
		adapters := &media.state.adapters
		return(
			adapters.read_audio_frame != nil &&
			adapters.read_audio_frame(adapters.ctx, lba, out) \
		)
	case .None, .Host_Drive:
	}
	return false
}

optical_media_lba_to_msf :: proc(lba: u32) -> Disc_Msf {
	return disc_image_lba_to_msf(lba)
}

optical_media_msf_to_lba :: proc(msf: Disc_Msf) -> (u32, bool) {
	return disc_image_msf_to_lba(msf)
}

optical_media_has_packet_transport :: proc(media: ^Optical_Media) -> bool {
	if media == nil {return false}
	if media.state.backing == .Host_Drive {
		return host_optical_drive_is_open(&media.state.host)
	}
	return media.state.backing == .Adapter && media.state.adapters.execute_read_only != nil
}

optical_media_execute_read_only_packet :: proc(
	media: ^Optical_Media,
	cdb: []u8,
	out: []u8,
) -> Optical_Media_Packet_Result {
	if media == nil {return {status = .Not_Handled}}
	switch media.state.backing {
	case .Host_Drive:
		return host_optical_drive_execute_read_only(&media.state.host, cdb, out)
	case .Adapter:
		adapters := &media.state.adapters
		if adapters.execute_read_only != nil {
			return adapters.execute_read_only(adapters.ctx, cdb, out)
		}
	case .None, .Image:
	}
	return {status = .Not_Handled}
}

optical_media_begin_packet_read :: proc(
	media: ^Optical_Media,
	cdb: []u8,
	lba: u32,
	out: []u8,
) -> Optical_Media_Packet_Result {
	if media == nil ||
	   len(cdb) == 0 ||
	   len(cdb) > len(media.state.packet_read_cdb) ||
	   !host_optical_drive_read_opcode(cdb[0]) {
		return {status = .Rejected}
	}
	media.state.packet_read_cdb = {}
	copy(media.state.packet_read_cdb[:], cdb)
	media.state.packet_read_length = len(cdb)
	return optical_media_read_packet_sector(media, lba, out)
}

optical_media_read_packet_sector :: proc(
	media: ^Optical_Media,
	lba: u32,
	out: []u8,
) -> Optical_Media_Packet_Result {
	if media == nil || media.state.packet_read_length <= 0 {return {status = .Rejected}}
	cdb := media.state.packet_read_cdb
	host_optical_drive_set_read_sector(cdb[:media.state.packet_read_length], lba)
	switch media.state.backing {
	case .Host_Drive:
		return host_optical_drive_execute_read(
			&media.state.host,
			cdb[:media.state.packet_read_length],
			out,
		)
	case .Adapter:
		adapters := &media.state.adapters
		if adapters.execute_read_only != nil {
			return adapters.execute_read_only(
				adapters.ctx,
				cdb[:media.state.packet_read_length],
				out,
			)
		}
	case .None, .Image:
	}
	return {status = .Not_Handled}
}

@(private = "file")
optical_media_observation_valid :: proc(observation: Optical_Media_Observation) -> bool {
	if !observation.present {return false}
	if observation.total_sectors == 0 ||
	   observation.track_count == 0 ||
	   observation.track_count > DISC_MAX_TRACKS {return false}
	for i in 0 ..< int(observation.track_count) {
		track := observation.tracks[i]
		if track.number == 0 ||
		   track.sector_count == 0 ||
		   u64(track.start_lba) + u64(track.sector_count) > u64(observation.total_sectors) {
			return false
		}
	}
	return true
}
