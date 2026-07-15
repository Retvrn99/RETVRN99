// SPDX-License-Identifier: GPL-3.0-only
package disk

import persona "../persona"

// ATAPI bus-master DMA command handling is adapted from IzarraVM commit
// d930de57acccbc6a70cda8cc5a603173bf23cd1c.

ATAPI_STATUS_ERR  :: 0x01
ATAPI_STATUS_DRQ  :: 0x08
ATAPI_STATUS_DRDY :: 0x40
ATAPI_STATUS_BSY  :: 0x80

ATAPI_ERROR_ABRT :: 0x04

ATAPI_PACKET_BYTES :: 12
ATAPI_TRACE_HISTORY :: 64
ATAPI_MASTER_CLOCK_HZ :: u64(6_600_000_000)
ATAPI_CD_DATA_SECTORS_PER_SECOND :: DISC_FRAMES_PER_SECOND * u64(persona.GUEST_PERSONA.cd_speed)
ATAPI_DVD_DATA_BYTES_PER_SECOND :: u64(13_850_000)
ATAPI_CD_SPEED_KBPS :: u16(7_987)
ATAPI_DVD_SPEED_KBPS :: u16(13_850)
ATAPI_CDDA_FRAME_TICKS :: ATAPI_MASTER_CLOCK_HZ / DISC_FRAMES_PER_SECOND

Atapi_Packet_Trace :: struct {
	packet:          [ATAPI_PACKET_BYTES]u8,
	phase_limit:     int,
	dispatch_status: u8,
	dispatch_error:  u8,
	dispatch_key:    u8,
	dispatch_asc:    u8,
	dispatch_ascq:   u8,
}

Atapi_State :: enum {
	Idle,
	Packet_Out,
	Data_In,
	Data_Out,
}

Atapi_Data_Kind :: enum {
	None,
	Identify,
	Reply,
	Blocks,
}

Atapi_Cdda_State :: enum u8 {
	Stopped,
	Playing,
	Paused,
	Complete,
}

Atapi_Cdda_Frame_Proc :: proc(ctx: rawptr, pcm: []u8)

Atapi :: struct {
	image: Disc_Image,
	state: Atapi_State,
	data_kind: Atapi_Data_Kind,
	buf: [DISC_RAW_SECTOR_SIZE]u8,
	buf_len: int,
	buf_pos: int,
	phase_end: int,
	phase_limit: int,
	packet: [ATAPI_PACKET_BYTES]u8,
	packet_pos: int,
	trace_hist: [ATAPI_TRACE_HISTORY]Atapi_Packet_Trace,
	trace_count: u64,
	read_lba: u32,
	read_blocks: u32,
	read_raw: bool,
	read_cd_selection: u8,
	read_sector_size: int,
	data_pending: bool,
	data_ready_tick: u64,
	now_tick: u64,
	data_out_remaining:       int,
	data_out_phase_remaining: int,
	cdda_state: Atapi_Cdda_State,
	cdda_lba: u32,
	cdda_end_lba: u32,
	cdda_next_tick: u64,
	cdda_frame: Atapi_Cdda_Frame_Proc,
	cdda_ctx: rawptr,
	cdda_frames_played: u64,
	cdda_generation: u64,
	media_changed: bool,
	sense_key: u8,
	sense_asc: u8,
	sense_ascq: u8,
	reg_error: u8,
	reg_features: u8,
	reg_seccount: u8,
	reg_lba_lo: u8,
	reg_lba_mid: u8,
	reg_lba_hi: u8,
	reg_drive: u8,
	reg_status: u8,
	reg_ctrl: u8,
	io_space_enabled: bool,
	channel_enabled:  bool,
	irq_pending:      bool,
	irq_signaled:     bool,
	irq: proc(ctx: rawptr, asserted: bool),
	irq_ctx: rawptr,
	dma_pending: bool,
	dma_submitted: bool,
	dma_lba: u32,
	dma_blocks: u32,
	dma_raw: bool,
	dma_cd_selection: u8,
	dma_sector_size: int,
	dma_byte_count: u32,
	dma_cache: [DISC_RAW_SECTOR_SIZE]u8,
	dma_cache_lba: u32,
	dma_cache_valid: bool,
}

atapi_init :: proc(a: ^Atapi) {
	a.io_space_enabled = true
	a.channel_enabled = true
	atapi_reset_signature(a)
}

atapi_set_pci_decode :: proc(a: ^Atapi, io_space_enabled, channel_enabled: bool) {
	if a == nil {return}
	a.io_space_enabled = io_space_enabled
	a.channel_enabled = channel_enabled
	atapi_update_irq(a)
}

atapi_io_decoded :: proc(a: ^Atapi) -> bool {
	return a != nil && a.io_space_enabled && a.channel_enabled
}

@(private = "file")
atapi_open_bus :: proc(size: u8) -> u32 {
	switch size {
	case 1: return 0xFF
	case 2: return 0xFFFF
	}
	return 0xFFFF_FFFF
}

atapi_set_cdda_output :: proc(a: ^Atapi, ctx: rawptr, frame: Atapi_Cdda_Frame_Proc) {
	if a == nil {return}
	a.cdda_ctx = ctx
	a.cdda_frame = frame
}

atapi_cdda_generation :: proc(a: ^Atapi) -> u64 {
	return a != nil ? a.cdda_generation : 0
}

atapi_next_deadline :: proc(a: ^Atapi) -> (u64, bool) {
	if a == nil {return 0, false}
	deadline: u64
	pending := false
	if a.data_pending {
		deadline, pending = a.data_ready_tick, true
	}
	if a.cdda_state == .Playing && (!pending || a.cdda_next_tick < deadline) {
		deadline, pending = a.cdda_next_tick, true
	}
	return deadline, pending
}

atapi_advance_to :: proc(a: ^Atapi, tick: u64) {
	if a == nil || tick < a.now_tick {return}
	for {
		deadline, pending := atapi_next_deadline(a)
		if !pending || deadline > tick {break}
		a.now_tick = deadline
		if a.data_pending && a.data_ready_tick == deadline {
			atapi_publish_read_sector(a)
		}
		if a.cdda_state == .Playing && a.cdda_next_tick == deadline {
			atapi_emit_cdda_frame(a)
		}
	}
	a.now_tick = tick
}

atapi_mount :: proc(a: ^Atapi, path: string) -> bool {
	return atapi_mount_classified(a, path, .Auto)
}

atapi_mount_classified :: proc(a: ^Atapi, path: string, media_class: Disc_Media_Class) -> bool {
	changed := a != nil && (a.media_changed || disc_image_present(&a.image))
	return atapi_set_media(a, path, changed, media_class)
}

atapi_attach :: proc(a: ^Atapi, path: string) -> bool {
	return atapi_attach_classified(a, path, .Auto)
}

atapi_attach_classified :: proc(a: ^Atapi, path: string, media_class: Disc_Media_Class) -> bool {
	return atapi_set_media(a, path, false, media_class)
}

@(private = "file")
atapi_set_media :: proc(
	a: ^Atapi,
	path: string,
	changed: bool,
	media_class: Disc_Media_Class,
) -> bool {
	if a == nil {
		return false
	}
	if !disc_image_mount_classified(&a.image, path, media_class) {
		return false
	}
	atapi_cancel_transfer(a)
	atapi_stop_audio(a, .Stopped)
	a.media_changed = changed
	a.sense_key, a.sense_asc, a.sense_ascq = 0, 0, 0
	a.reg_status = ATAPI_STATUS_DRDY
	return true
}

atapi_eject :: proc(a: ^Atapi) {
	if a == nil {
		return
	}
	disc_image_eject(&a.image)
	atapi_cancel_transfer(a)
	atapi_stop_audio(a, .Stopped)
	a.media_changed = true
	a.sense_key, a.sense_asc, a.sense_ascq = 0x02, 0x3A, 0
	a.reg_status = ATAPI_STATUS_DRDY
}

@(private = "file")
atapi_slave_selected :: proc(a: ^Atapi) -> bool {
	return a.reg_drive & 0x10 != 0
}

atapi_io_read :: proc(a: ^Atapi, port: u16, size: u8) -> u32 {
	if !atapi_io_decoded(a) {return atapi_open_bus(size)}
	if atapi_slave_selected(a) {
		return 0
	}
	switch port {
	case 0x170:
		return atapi_data_read(a, size)
	case 0x171:
		return u32(a.reg_error)
	case 0x172:
		return u32(a.reg_seccount)
	case 0x173:
		return u32(a.reg_lba_lo)
	case 0x174:
		return u32(a.reg_lba_mid)
	case 0x175:
		return u32(a.reg_lba_hi)
	case 0x176:
		return u32(a.reg_drive)
	case 0x177:
		status := a.reg_status
		atapi_acknowledge_irq(a)
		return u32(status)
	case 0x376:
		return u32(a.reg_status)
	}
	return 0xFF
}

atapi_io_write :: proc(a: ^Atapi, port: u16, size: u8, val: u32) {
	if !atapi_io_decoded(a) {return}
	switch port {
	case 0x170:
		if !atapi_slave_selected(a) {
			atapi_data_write(a, size, val)
		}
	case 0x171:
		a.reg_features = u8(val)
	case 0x172:
		a.reg_seccount = u8(val)
	case 0x173:
		a.reg_lba_lo = u8(val)
	case 0x174:
		a.reg_lba_mid = u8(val)
	case 0x175:
		a.reg_lba_hi = u8(val)
	case 0x176:
		a.reg_drive = u8(val)
	case 0x177:
		if !atapi_slave_selected(a) {
			atapi_command(a, u8(val))
		}
	case 0x376:
		old := a.reg_ctrl
		a.reg_ctrl = u8(val)
		if a.reg_ctrl & 0x04 != 0 {
			atapi_acknowledge_irq(a)
			atapi_cancel_transfer(a)
			a.reg_status = ATAPI_STATUS_BSY
		} else if old & 0x04 != 0 {
			atapi_reset_signature(a)
		}
		atapi_update_irq(a)
	}
}

@(private = "file")
atapi_raise_irq :: proc(a: ^Atapi) {
	if a == nil {return}
	a.irq_pending = true
	atapi_update_irq(a)
}

@(private = "file")
atapi_set_irq_signal :: proc(a: ^Atapi, asserted: bool) {
	if a == nil || a.irq_signaled == asserted {return}
	a.irq_signaled = asserted
	if a.irq != nil {a.irq(a.irq_ctx, asserted)}
}

@(private = "file")
atapi_update_irq :: proc(a: ^Atapi) {
	if a == nil {return}
	atapi_set_irq_signal(a, a.irq_pending && atapi_irq_enabled(a))
}

atapi_acknowledge_irq :: proc(a: ^Atapi) {
	if a == nil {return}
	a.irq_pending = false
	atapi_update_irq(a)
}

atapi_interrupt_pending :: proc(a: ^Atapi) -> bool {
	return a != nil && a.irq_pending
}

@(private = "file")
atapi_reset_signature :: proc(a: ^Atapi) {
	atapi_acknowledge_irq(a)
	atapi_cancel_transfer(a)
	atapi_stop_audio(a, .Stopped)
	a.reg_error = 1
	a.reg_seccount = 1
	a.reg_lba_lo = 1
	a.reg_lba_mid = 0x14
	a.reg_lba_hi = 0xEB
	a.reg_drive = 0xA0
	a.reg_status = 0
}

@(private = "file")
atapi_cancel_transfer :: proc(a: ^Atapi) {
	a.state = .Idle
	a.data_kind = .None
	a.buf_len = 0
	a.buf_pos = 0
	a.phase_end = 0
	a.phase_limit = 0
	a.packet_pos = 0
	a.read_lba = 0
	a.read_blocks = 0
	a.read_raw = false
	a.read_cd_selection = 0
	a.read_sector_size = 0
	a.data_pending = false
	a.data_ready_tick = 0
	a.data_out_remaining = 0
	a.data_out_phase_remaining = 0
	a.dma_pending = false
	a.dma_submitted = false
	a.dma_lba = 0
	a.dma_blocks = 0
	a.dma_raw = false
	a.dma_cd_selection = 0
	a.dma_sector_size = 0
	a.dma_byte_count = 0
	a.dma_cache_lba = 0
	a.dma_cache_valid = false
}

@(private = "file")
atapi_command :: proc(a: ^Atapi, cmd: u8) {
	atapi_acknowledge_irq(a)
	a.reg_error = 0
	switch cmd {
	case 0xA0:
		if a.reg_features & 0x02 != 0 {
			atapi_cancel_transfer(a)
			a.reg_error = ATAPI_ERROR_ABRT
			a.reg_status = ATAPI_STATUS_DRDY | ATAPI_STATUS_ERR
			atapi_raise_irq(a)
			return
		}
		a.packet = {}
		a.packet_pos = 0
		a.phase_limit = int(u16(a.reg_lba_mid) | u16(a.reg_lba_hi) << 8)
		if a.phase_limit == 0 {
			a.phase_limit = 0x10000
		}
		a.state = .Packet_Out
		a.reg_seccount = 0x01
		a.reg_status = ATAPI_STATUS_DRDY | ATAPI_STATUS_DRQ
	case 0xA1:
		atapi_fill_identify(a)
		a.data_kind = .Identify
		a.phase_limit = 512
		atapi_start_data(a, 512)
	case 0x08:
		atapi_reset_signature(a)
		atapi_raise_irq(a)
	case 0x90:
		atapi_reset_signature(a)
	case 0xEF:
		atapi_complete(a)
	case:
		atapi_cancel_transfer(a)
		a.reg_error = ATAPI_ERROR_ABRT
		a.reg_status = ATAPI_STATUS_DRDY | ATAPI_STATUS_ERR
		atapi_raise_irq(a)
	}
}

@(private = "file")
atapi_data_write :: proc(a: ^Atapi, size: u8, val: u32) {
	if a.state == .Data_Out {
		count := min(min(a.data_out_remaining, a.data_out_phase_remaining), int(size))
		a.data_out_remaining -= count
		a.data_out_phase_remaining -= count
		if a.data_out_phase_remaining == 0 {
			if a.data_out_remaining == 0 {
				atapi_complete(a)
			} else {
				atapi_start_data_out_phase(a)
			}
		}
		return
	}
	if a.state != .Packet_Out {
		return
	}
	v := val
	for _ in 0 ..< int(size) {
		if a.packet_pos < ATAPI_PACKET_BYTES {
			a.packet[a.packet_pos] = u8(v)
			a.packet_pos += 1
		}
		v >>= 8
	}
	if a.packet_pos == ATAPI_PACKET_BYTES {
		a.state = .Idle
		atapi_packet_command(a)
	}
}

@(private = "file")
atapi_data_read :: proc(a: ^Atapi, size: u8) -> u32 {
	if a.state != .Data_In {
		return 0xFFFF_FFFF >> (32 - 8 * u32(size))
	}
	v: u32
	for i in 0 ..< int(size) {
		if a.buf_pos < a.phase_end {
			v |= u32(a.buf[a.buf_pos]) << (8 * uint(i))
			a.buf_pos += 1
		}
	}
	if a.buf_pos >= a.phase_end {
		atapi_advance_data(a)
	}
	return v
}

@(private = "file")
atapi_start_data :: proc(a: ^Atapi, length: int) {
	if length <= 0 {
		atapi_complete(a)
		return
	}
	a.buf_len = min(length, len(a.buf))
	a.buf_pos = 0
	a.state = .Data_In
	atapi_start_phase(a)
}

@(private = "file")
atapi_start_phase :: proc(a: ^Atapi) {
	remaining := a.buf_len - a.buf_pos
	count := min(remaining, a.phase_limit)
	a.phase_end = a.buf_pos + count
	a.reg_lba_mid = u8(count)
	a.reg_lba_hi = u8(count >> 8)
	a.reg_seccount = 0x02
	a.reg_status = ATAPI_STATUS_DRDY | ATAPI_STATUS_DRQ
	atapi_raise_irq(a)
}

@(private = "file")
atapi_advance_data :: proc(a: ^Atapi) {
	if a.buf_pos < a.buf_len {
		atapi_start_phase(a)
		return
	}
	if a.data_kind == .Blocks && a.read_blocks > 1 {
		a.read_lba += 1
		a.read_blocks -= 1
		atapi_schedule_read_sector(a)
		return
	}
	atapi_complete(a)
}

@(private = "file")
atapi_complete :: proc(a: ^Atapi) {
	atapi_set_complete_state(a)
	atapi_raise_irq(a)
}

@(private = "file")
atapi_set_complete_state :: proc(a: ^Atapi) {
	atapi_cancel_transfer(a)
	a.reg_error = 0
	a.reg_seccount = 0x03
	a.reg_lba_mid = 0
	a.reg_lba_hi = 0
	a.reg_status = ATAPI_STATUS_DRDY
}

@(private = "file")
atapi_check_condition :: proc(a: ^Atapi, key, asc, ascq: u8) {
	atapi_set_check_condition_state(a, key, asc, ascq)
	atapi_raise_irq(a)
}

@(private = "file")
atapi_set_check_condition_state :: proc(a: ^Atapi, key, asc, ascq: u8) {
	atapi_cancel_transfer(a)
	a.sense_key, a.sense_asc, a.sense_ascq = key, asc, ascq
	a.reg_error = key << 4
	a.reg_seccount = 0x03
	a.reg_lba_mid = 0
	a.reg_lba_hi = 0
	a.reg_status = ATAPI_STATUS_DRDY | ATAPI_STATUS_ERR
}

@(private = "file")
atapi_media_attention :: proc(a: ^Atapi) -> bool {
	if a.media_changed {
		a.media_changed = false
		atapi_check_condition(a, 0x06, 0x28, 0)
		return true
	}
	return false
}

@(private = "file")
atapi_media_ready :: proc(a: ^Atapi) -> bool {
	if atapi_media_attention(a) {return false}
	if !disc_image_present(&a.image) {
		atapi_check_condition(a, 0x02, 0x3A, 0)
		return false
	}
	return true
}

@(private = "file")
atapi_packet_command :: proc(a: ^Atapi) {
	trace := &a.trace_hist[a.trace_count % ATAPI_TRACE_HISTORY]
	trace^ = Atapi_Packet_Trace {
		packet      = a.packet,
		phase_limit = a.phase_limit,
	}
	a.trace_count += 1
	defer {
		trace.dispatch_status = a.reg_status
		trace.dispatch_error = a.reg_error
		trace.dispatch_key = a.sense_key
		trace.dispatch_asc = a.sense_asc
		trace.dispatch_ascq = a.sense_ascq
	}
	switch a.packet[0] {
	case 0x00:
		if atapi_media_ready(a) {
			atapi_complete(a)
		}
	case 0x03:
		atapi_request_sense(a)
	case 0x12:
		atapi_inquiry(a)
	case 0x1A:
		if !atapi_media_attention(a) {
			atapi_mode_sense_6(a)
		}
	case 0x15:
		atapi_mode_select(a, int(a.packet[4]))
	case 0x1B, 0x1E:
		atapi_complete(a)
	case 0x25:
		if atapi_media_ready(a) {
			atapi_read_capacity(a)
		}
	case 0x28:
		if atapi_media_ready(a) {
			atapi_read_blocks(a, atapi_be32(a.packet[2:6]), u32(atapi_be16(a.packet[7:9])))
		}
	case 0x2B:
		if atapi_media_ready(a) {
			lba := atapi_be32(a.packet[2:6])
			if lba >= a.image.total_sectors {
				atapi_check_condition(a, 0x05, 0x21, 0)
			} else {
				atapi_complete(a)
			}
		}
	case 0x44:
		if atapi_media_ready(a) {atapi_read_header(a)}
	case 0x45:
		if atapi_media_ready(a) {
			atapi_play_audio(a, atapi_be32(a.packet[2:6]), u32(atapi_be16(a.packet[7:9])))
		}
	case 0x47:
		if atapi_media_ready(a) {atapi_play_audio_msf(a)}
	case 0x4B:
		atapi_pause_resume(a, a.packet[8] & 1 != 0)
	case 0x4E:
		atapi_stop_audio(a, .Stopped)
		atapi_complete(a)
	case 0x42:
		if atapi_media_ready(a) {
			atapi_read_subchannel(a)
		}
	case 0x43:
		if atapi_media_ready(a) {
			atapi_read_toc(a)
		}
	case 0x46:
		atapi_get_configuration(a)
	case 0x5A:
		if !atapi_media_attention(a) {
			atapi_mode_sense_10(a)
		}
	case 0x55:
		atapi_mode_select(a, int(atapi_be16(a.packet[7:9])))
	case 0xA8:
		if atapi_media_ready(a) {
			atapi_read_blocks(a, atapi_be32(a.packet[2:6]), atapi_be32(a.packet[6:10]))
		}
	case 0xAD:
		if atapi_media_ready(a) {atapi_read_dvd_structure(a)}
	case 0xBE:
		if atapi_media_ready(a) {atapi_read_cd(a)}
	case:
		atapi_check_condition(a, 0x05, 0x20, 0)
	}
}

@(private = "file")
atapi_request_sense :: proc(a: ^Atapi) {
	a.buf = {}
	a.buf[0] = 0x70
	a.buf[2] = a.sense_key
	a.buf[7] = 10
	a.buf[12] = a.sense_asc
	a.buf[13] = a.sense_ascq
	length := min(int(a.packet[4]), 18)
	a.sense_key, a.sense_asc, a.sense_ascq = 0, 0, 0
	a.data_kind = .Reply
	atapi_start_data(a, length)
}

@(private = "file")
atapi_inquiry :: proc(a: ^Atapi) {
	a.buf = {}
	a.buf[0] = 0x05
	a.buf[1] = 0x80
	a.buf[2] = 0x02
	a.buf[3] = 0x02
	a.buf[4] = 31
	copy(a.buf[8:16], "GSW     ")
	copy(a.buf[16:32], "GSW-DVD/CD 10/52")
	copy(a.buf[32:36], "1.0 ")
	a.data_kind = .Reply
	atapi_start_data(a, min(int(a.packet[4]), 36))
}

@(private = "file")
atapi_read_capacity :: proc(a: ^Atapi) {
	a.buf = {}
	last := a.image.total_sectors - 1
	atapi_put_be32(a.buf[:], 0, last)
	atapi_put_be32(a.buf[:], 4, CDROM_SECTOR_SIZE)
	a.data_kind = .Reply
	atapi_start_data(a, 8)
}

@(private = "file")
atapi_read_blocks :: proc(a: ^Atapi, lba, count: u32) {
	if count == 0 {
		atapi_complete(a)
		return
	}
	if u64(lba) + u64(count) > u64(a.image.total_sectors) {
		atapi_check_condition(a, 0x05, 0x21, 0)
		return
	}
	a.read_lba = lba
	a.read_blocks = count
	a.read_raw = false
	a.read_cd_selection = 0
	a.read_sector_size = DISC_DATA_SECTOR_SIZE
	a.data_kind = .Blocks
	if a.reg_features & 0x01 != 0 {
		atapi_begin_dma_read(a, lba, count, false, DISC_DATA_SECTOR_SIZE, 0)
	} else {
		atapi_schedule_read_sector(a)
	}
}

@(private = "file")
atapi_schedule_read_sector :: proc(a: ^Atapi) {
	a.state = .Idle
	a.buf_len = 0
	a.buf_pos = 0
	a.phase_end = 0
	a.data_pending = true
	a.data_ready_tick = a.now_tick
	a.reg_status = ATAPI_STATUS_BSY
	atapi_publish_read_sector(a)
}

@(private = "file")
atapi_publish_read_sector :: proc(a: ^Atapi) {
	if !a.data_pending {return}
	a.data_pending = false
	ok := false
	if a.read_cd_selection != 0 {
		ok = atapi_read_cd_sector(&a.image, a.read_lba, a.read_cd_selection, a.buf[:a.read_sector_size])
	} else if a.read_raw {
		ok = disc_image_read_raw_sector(&a.image, a.read_lba, a.buf[:DISC_RAW_SECTOR_SIZE])
	} else {
		ok = disc_image_read_data_sector(&a.image, a.read_lba, a.buf[:DISC_DATA_SECTOR_SIZE])
	}
	if !ok {
		atapi_check_condition(a, 0x03, 0x11, 0)
		return
	}
	a.buf_len = a.read_sector_size
	a.buf_pos = 0
	a.state = .Data_In
	atapi_start_phase(a)
}

@(private = "file")
atapi_mode_select :: proc(a: ^Atapi, length: int) {
	if length <= 0 {
		atapi_complete(a)
		return
	}
	a.state = .Data_Out
	a.data_kind = .Reply
	a.data_out_remaining = length
	atapi_start_data_out_phase(a)
}

@(private = "file")
atapi_start_data_out_phase :: proc(a: ^Atapi) {
	count := min(a.data_out_remaining, a.phase_limit)
	a.data_out_phase_remaining = count
	a.reg_lba_mid = u8(count)
	a.reg_lba_hi = u8(count >> 8)
	a.reg_seccount = 0
	a.reg_status = ATAPI_STATUS_DRDY | ATAPI_STATUS_DRQ
	atapi_raise_irq(a)
}

@(private = "file")
Atapi_Read_Cd_Layout :: struct {
	sector_size: int,
	audio:       bool,
	sync:        bool,
	header:      bool,
	user_data:   bool,
	edc_ecc:     bool,
}

@(private = "file")
atapi_read_cd_layout :: proc(
	mode: Disc_Track_Mode,
	expected_type, selection: u8,
) -> (Atapi_Read_Cd_Layout, bool) {
	audio := mode == .Audio_2352
	switch expected_type {
	case 0:
	case 1:
		if !audio {return {}, false}
	case 2:
		if audio {return {}, false}
	case:
		return {}, false
	}

	if audio {
		if selection & ~u8(0x10) != 0 {return {}, false}
		return Atapi_Read_Cd_Layout {
			sector_size = selection & 0x10 != 0 ? DISC_RAW_SECTOR_SIZE : 0,
			audio       = true,
			user_data   = selection & 0x10 != 0,
		}, true
	}

	header_code := (selection >> 5) & 3
	if header_code == 2 {return {}, false}
	layout := Atapi_Read_Cd_Layout {
		sync      = selection & 0x80 != 0,
		header    = header_code == 1 || header_code == 3,
		user_data = selection & 0x10 != 0,
		edc_ecc   = selection & 0x08 != 0,
	}
	if layout.sync {layout.sector_size += 12}
	if layout.header {layout.sector_size += 4}
	if layout.user_data {layout.sector_size += DISC_DATA_SECTOR_SIZE}
	if layout.edc_ecc {
		layout.sector_size += DISC_RAW_SECTOR_SIZE - 16 - DISC_DATA_SECTOR_SIZE
	}
	return layout, true
}

@(private = "file")
atapi_read_cd_span_layout :: proc(
	image: ^Disc_Image,
	lba, count: u32,
	expected_type, selection: u8,
) -> (Atapi_Read_Cd_Layout, bool) {
	cursor := lba
	remaining := count
	result: Atapi_Read_Cd_Layout
	has_result := false
	for remaining > 0 {
		track, found := disc_image_track_at_lba(image, cursor)
		if !found {return {}, false}
		layout, supported := atapi_read_cd_layout(track.mode, expected_type, selection)
		if !supported || has_result && layout.sector_size != result.sector_size {
			return {}, false
		}
		if !has_result {
			result = layout
			has_result = true
		}
		track_end := u64(track.start_lba) + u64(track.sector_count)
		available := u32(min(track_end - u64(cursor), u64(remaining)))
		if available == 0 {return {}, false}
		cursor += available
		remaining -= available
	}
	return result, has_result
}

@(private = "file")
atapi_read_cd_sector :: proc(
	image: ^Disc_Image,
	lba: u32,
	selection: u8,
	out: []u8,
) -> bool {
	track, found := disc_image_track_at_lba(image, lba)
	if !found {return false}
	layout, supported := atapi_read_cd_layout(track.mode, 0, selection)
	if !supported || len(out) != layout.sector_size {return false}
	raw: [DISC_RAW_SECTOR_SIZE]u8
	if !disc_image_read_raw_sector(image, lba, raw[:]) {return false}
	if layout.audio {
		copy(out, raw[:])
		return true
	}
	position := 0
	if layout.sync {
		copy(out[position:position + 12], raw[:12])
		position += 12
	}
	if layout.header {
		copy(out[position:position + 4], raw[12:16])
		position += 4
	}
	if layout.user_data {
		copy(
			out[position:position + DISC_DATA_SECTOR_SIZE],
			raw[16:16 + DISC_DATA_SECTOR_SIZE],
		)
		position += DISC_DATA_SECTOR_SIZE
	}
	if layout.edc_ecc {
		copy(out[position:], raw[16 + DISC_DATA_SECTOR_SIZE:])
	}
	return true
}

@(private = "file")
atapi_read_cd :: proc(a: ^Atapi) {
	lba := atapi_be32(a.packet[2:6])
	count := u32(a.packet[6]) << 16 | u32(a.packet[7]) << 8 | u32(a.packet[8])
	selection := a.packet[9]
	if a.image.media_class != .Compact_Disc || selection & 0x07 != 0 || a.packet[10] != 0 {
		atapi_check_condition(a, 0x05, 0x24, 0)
		return
	}
	if count == 0 {
		atapi_complete(a)
		return
	}
	if u64(lba) + u64(count) > u64(a.image.total_sectors) {
		atapi_check_condition(a, 0x05, 0x21, 0)
		return
	}
	expected_type := (a.packet[1] >> 2) & 7
	layout, supported := atapi_read_cd_span_layout(
		&a.image,
		lba,
		count,
		expected_type,
		selection,
	)
	if !supported {
		atapi_check_condition(a, 0x05, 0x24, 0)
		return
	}
	if layout.sector_size == 0 {
		atapi_complete(a)
		return
	}
	a.read_lba = lba
	a.read_blocks = count
	a.read_raw = true
	a.read_cd_selection = selection
	a.read_sector_size = layout.sector_size
	a.data_kind = .Blocks
	if a.reg_features & 0x01 != 0 {
		atapi_begin_dma_read(a, lba, count, true, layout.sector_size, selection)
	} else {
		atapi_schedule_read_sector(a)
	}
}

@(private = "file")
atapi_begin_dma_read :: proc(
	a: ^Atapi,
	lba, blocks: u32,
	raw: bool,
	sector_size: int,
	selection: u8,
) {
	byte_count := u64(blocks) * u64(sector_size)
	if blocks == 0 || sector_size <= 0 || byte_count > u64(~u32(0)) {
		atapi_check_condition(a, 0x05, 0x24, 0)
		return
	}
	a.state = .Idle
	a.data_pending = false
	a.dma_pending = true
	a.dma_submitted = false
	a.dma_lba = lba
	a.dma_blocks = blocks
	a.dma_raw = raw
	a.dma_cd_selection = selection
	a.dma_sector_size = sector_size
	a.dma_byte_count = u32(byte_count)
	a.dma_cache_valid = false
	a.reg_status = ATAPI_STATUS_BSY
}

@(private = "file")
atapi_dma_begin_adapter :: proc(
	ctx: rawptr,
	channel: u8,
	direction: Bmide_Direction,
	byte_count: u32,
) -> bool {
	a := (^Atapi)(ctx)
	return(
		channel == 1 &&
		direction == .Device_To_Memory &&
		a.dma_pending &&
		byte_count == a.dma_byte_count &&
		disc_image_present(&a.image) \
	)
}

@(private = "file")
atapi_dma_load_cache :: proc(a: ^Atapi, lba: u32) -> bool {
	if a.dma_cache_valid && a.dma_cache_lba == lba {return true}
	ok := false
	if a.dma_cd_selection != 0 {
		ok = atapi_read_cd_sector(
			&a.image,
			lba,
			a.dma_cd_selection,
			a.dma_cache[:a.dma_sector_size],
		)
	} else if a.dma_raw {
		ok = disc_image_read_raw_sector(&a.image, lba, a.dma_cache[:DISC_RAW_SECTOR_SIZE])
	} else {
		ok = disc_image_read_data_sector(&a.image, lba, a.dma_cache[:DISC_DATA_SECTOR_SIZE])
	}
	if !ok {return false}
	a.dma_cache_lba = lba
	a.dma_cache_valid = true
	return true
}

@(private = "file")
atapi_dma_read_adapter :: proc(
	ctx: rawptr,
	channel: u8,
	offset: u32,
	data: []u8,
) -> bool {
	a := (^Atapi)(ctx)
	if channel != 1 || !a.dma_pending || a.dma_sector_size <= 0 ||
	   offset > a.dma_byte_count || u32(len(data)) > a.dma_byte_count - offset {
		return false
	}
	if !a.dma_raw && a.dma_cd_selection == 0 &&
	   offset % u32(DISC_DATA_SECTOR_SIZE) == 0 &&
	   len(data) % DISC_DATA_SECTOR_SIZE == 0 {
		lba := a.dma_lba + offset / u32(DISC_DATA_SECTOR_SIZE)
		return disc_image_read_data_sectors(
			&a.image,
			lba,
			u32(len(data) / DISC_DATA_SECTOR_SIZE),
			data,
		)
	}
	written := 0
	for written < len(data) {
		absolute := u64(offset) + u64(written)
		sector_index := absolute / u64(a.dma_sector_size)
		sector_offset := int(absolute % u64(a.dma_sector_size))
		lba := a.dma_lba + u32(sector_index)
		if !atapi_dma_load_cache(a, lba) {return false}
		part := min(len(data) - written, a.dma_sector_size - sector_offset)
		copy(data[written:written + part], a.dma_cache[sector_offset:sector_offset + part])
		written += part
	}
	return true
}

@(private = "file")
atapi_dma_commit_adapter :: proc(ctx: rawptr, channel: u8) -> bool {
	a := (^Atapi)(ctx)
	if channel != 1 || !a.dma_pending {return false}
	atapi_set_complete_state(a)
	atapi_raise_irq(a)
	return true
}

@(private = "file")
atapi_dma_abort_adapter :: proc(ctx: rawptr, channel: u8) {
	if channel != 1 {return}
	a := (^Atapi)(ctx)
	atapi_set_check_condition_state(a, 0x03, 0x11, 0)
	atapi_raise_irq(a)
}

atapi_bmide_request :: proc(a: ^Atapi) -> (Bmide_Request, bool) {
	if a == nil || !a.dma_pending || a.dma_submitted {return {}, false}
	return Bmide_Request {
		direction        = .Device_To_Memory,
		byte_count       = a.dma_byte_count,
		device           = {
			ctx    = a,
			begin  = atapi_dma_begin_adapter,
			read   = atapi_dma_read_adapter,
			commit = atapi_dma_commit_adapter,
			abort  = atapi_dma_abort_adapter,
		},
	}, true
}

atapi_bmide_mark_submitted :: proc(a: ^Atapi) {
	if a != nil && a.dma_pending {a.dma_submitted = true}
}

atapi_bmide_pending :: proc(a: ^Atapi) -> bool {
	return a != nil && a.dma_pending
}

atapi_irq_enabled :: proc(a: ^Atapi) -> bool {
	return(
		a != nil &&
		a.channel_enabled &&
		a.reg_ctrl & 0x02 == 0 \
	)
}

@(private = "file")
atapi_read_header :: proc(a: ^Atapi) {
	lba := atapi_be32(a.packet[2:6])
	track, ok := disc_image_track_at_lba(&a.image, lba)
	if !ok {
		atapi_check_condition(a, 0x05, 0x21, 0)
		return
	}
	a.buf = {}
	a.buf[0] = track.mode == .Audio_2352 ? 0 : 1
	if a.packet[1] & 0x02 != 0 {
		atapi_put_msf(a.buf[:], 4, lba)
	} else {
		atapi_put_be32(a.buf[:], 4, lba)
	}
	allocation := int(atapi_be16(a.packet[7:9]))
	a.data_kind = .Reply
	atapi_start_data(a, min(allocation, 8))
}

@(private = "file")
atapi_play_audio_msf :: proc(a: ^Atapi) {
	start, start_ok := disc_image_msf_to_lba(Disc_Msf {
		minute = a.packet[3], second = a.packet[4], frame = a.packet[5],
	})
	end, end_ok := disc_image_msf_to_lba(Disc_Msf {
		minute = a.packet[6], second = a.packet[7], frame = a.packet[8],
	})
	if !start_ok || !end_ok || end < start {
		atapi_check_condition(a, 0x05, 0x24, 0)
		return
	}
	atapi_play_audio(a, start, end - start)
}

@(private = "file")
atapi_play_audio :: proc(a: ^Atapi, lba, count: u32) {
	if count == 0 {
		atapi_stop_audio(a, .Complete)
		atapi_complete(a)
		return
	}
	if u64(lba) + u64(count) > u64(a.image.total_sectors) {
		atapi_check_condition(a, 0x05, 0x21, 0)
		return
	}
	for sector in lba ..< lba + count {
		track, ok := disc_image_track_at_lba(&a.image, sector)
		if !ok || track.mode != .Audio_2352 {
			atapi_check_condition(a, 0x05, 0x64, 0)
			return
		}
	}
	a.cdda_state = .Playing
	a.cdda_generation += 1
	a.cdda_lba = lba
	a.cdda_end_lba = lba + count
	a.cdda_next_tick = a.now_tick + ATAPI_CDDA_FRAME_TICKS
	atapi_complete(a)
}

@(private = "file")
atapi_pause_resume :: proc(a: ^Atapi, resume: bool) {
	if resume {
		if a.cdda_state == .Paused {
			a.cdda_state = .Playing
			a.cdda_next_tick = a.now_tick + ATAPI_CDDA_FRAME_TICKS
		}
	} else if a.cdda_state == .Playing {
		a.cdda_state = .Paused
	}
	atapi_complete(a)
}

@(private = "file")
atapi_stop_audio :: proc(a: ^Atapi, state: Atapi_Cdda_State) {
	a.cdda_generation += 1
	a.cdda_state = state
	a.cdda_next_tick = 0
}

@(private = "file")
atapi_emit_cdda_frame :: proc(a: ^Atapi) {
	if a.cdda_state != .Playing {return}
	if a.cdda_lba >= a.cdda_end_lba {
		atapi_stop_audio(a, .Complete)
		return
	}
	pcm: [DISC_RAW_SECTOR_SIZE]u8
	if !disc_image_read_audio_frame(&a.image, a.cdda_lba, pcm[:]) {
		atapi_stop_audio(a, .Stopped)
		return
	}
	if a.cdda_frame != nil {a.cdda_frame(a.cdda_ctx, pcm[:])}
	a.cdda_lba += 1
	a.cdda_frames_played += 1
	if a.cdda_lba >= a.cdda_end_lba {
		atapi_stop_audio(a, .Complete)
	} else {
		a.cdda_next_tick += ATAPI_CDDA_FRAME_TICKS
	}
}

@(private = "file")
atapi_read_toc :: proc(a: ^Atapi) {
	format := a.packet[2] & 0x0F
	legacy_format := a.packet[9] >> 6
	if format == 0 && legacy_format != 0 {
		format = legacy_format
	}
	allocation := int(atapi_be16(a.packet[7:9]))
	if format == 1 {
		a.buf = {}
		atapi_put_be16(a.buf[:], 0, 10)
		a.buf[2], a.buf[3] = 1, 1
		first := &a.image.tracks[0]
		a.buf[5], a.buf[6] = atapi_track_control(first), first.number
		if a.packet[1] & 0x02 != 0 {
			atapi_put_msf(a.buf[:], 8, first.start_lba)
		} else {
			atapi_put_be32(a.buf[:], 8, first.start_lba)
		}
		a.data_kind = .Reply
		atapi_start_data(a, min(allocation, 12))
		return
	}
	if format != 0 && format != 2 {
		atapi_check_condition(a, 0x05, 0x24, 0)
		return
	}
	if format == 2 {
		atapi_read_full_toc(a, allocation)
		return
	}
	a.buf = {}
	first_number := a.image.tracks[0].number
	last_number := a.image.tracks[int(a.image.track_count) - 1].number
	a.buf[2], a.buf[3] = first_number, last_number
	start_track := a.packet[6]
	if start_track == 0 {start_track = first_number}
	offset := 4
	if start_track != 0xAA {
		for i in 0 ..< int(a.image.track_count) {
			track := &a.image.tracks[i]
			if track.number < start_track {continue}
			a.buf[offset + 1] = atapi_track_control(track)
			a.buf[offset + 2] = track.number
			if a.packet[1] & 0x02 != 0 {
				atapi_put_msf(a.buf[:], offset + 4, track.start_lba)
			} else {
				atapi_put_be32(a.buf[:], offset + 4, track.start_lba)
			}
			offset += 8
		}
	}
	last := &a.image.tracks[int(a.image.track_count) - 1]
	a.buf[offset + 1] = atapi_track_control(last)
	a.buf[offset + 2] = 0xAA
	if a.packet[1] & 0x02 != 0 {
		atapi_put_msf(a.buf[:], offset + 4, a.image.total_sectors)
	} else {
		atapi_put_be32(a.buf[:], offset + 4, a.image.total_sectors)
	}
	offset += 8
	atapi_put_be16(a.buf[:], 0, u16(offset - 2))
	a.data_kind = .Reply
	atapi_start_data(a, min(allocation, offset))
}

@(private = "file")
atapi_track_control :: proc(track: ^Disc_Track) -> u8 {
	return track.mode == .Audio_2352 ? 0x10 : 0x14
}

@(private = "file")
atapi_read_full_toc :: proc(a: ^Atapi, allocation: int) {
	a.buf = {}
	a.buf[2], a.buf[3] = 1, 1
	offset := 4
	first := a.image.tracks[0].number
	last := a.image.tracks[int(a.image.track_count) - 1].number
	points := [3]u8{0xA0, 0xA1, 0xA2}
	for point in points {
		a.buf[offset + 1] = 0x14
		a.buf[offset + 2] = 1
		a.buf[offset + 3] = point
		if point == 0xA0 {a.buf[offset + 8] = first}
		if point == 0xA1 {a.buf[offset + 8] = last}
		if point == 0xA2 {
			msf := disc_image_lba_to_msf(a.image.total_sectors)
			a.buf[offset + 8], a.buf[offset + 9], a.buf[offset + 10] = msf.minute, msf.second, msf.frame
		}
		offset += 11
	}
	for i in 0 ..< int(a.image.track_count) {
		track := &a.image.tracks[i]
		msf := disc_image_lba_to_msf(track.start_lba)
		a.buf[offset + 1] = atapi_track_control(track)
		a.buf[offset + 2] = 1
		a.buf[offset + 3] = track.number
		a.buf[offset + 8], a.buf[offset + 9], a.buf[offset + 10] = msf.minute, msf.second, msf.frame
		offset += 11
	}
	atapi_put_be16(a.buf[:], 0, u16(offset - 2))
	a.data_kind = .Reply
	atapi_start_data(a, min(allocation, offset))
}

@(private = "file")
atapi_read_subchannel :: proc(a: ^Atapi) {
	a.buf = {}
	switch a.cdda_state {
	case .Playing: a.buf[1] = 0x11
	case .Paused: a.buf[1] = 0x12
	case .Complete: a.buf[1] = 0x13
	case .Stopped: a.buf[1] = 0x15
	}
	allocation := int(atapi_be16(a.packet[7:9]))
	length := 4
	if a.packet[2] & 0x40 != 0 {
		if a.packet[3] != 1 {
			atapi_check_condition(a, 0x05, 0x24, 0)
			return
		}
		lba := a.cdda_lba
		track, ok := disc_image_track_at_lba(&a.image, lba)
		if !ok {track = &a.image.tracks[0]; lba = track.start_lba}
		a.buf[3] = 12
		a.buf[4] = 1
		a.buf[5] = atapi_track_control(track)
		a.buf[6], a.buf[7] = track.number, 1
		relative := lba - min(lba, track.start_lba)
		if a.packet[1] & 0x02 != 0 {
			atapi_put_msf(a.buf[:], 8, lba)
			atapi_put_msf_relative(a.buf[:], 12, relative)
		} else {
			atapi_put_be32(a.buf[:], 8, lba)
			atapi_put_be32(a.buf[:], 12, relative)
		}
		length = 16
	}
	a.data_kind = .Reply
	atapi_start_data(a, min(allocation, length))
}

@(private = "file")
atapi_configuration_add_feature :: proc(
	a: ^Atapi,
	offset: int,
	code: u16,
	current: bool,
	data: []u8,
) -> int {
	atapi_put_be16(a.buf[:], offset, code)
	a.buf[offset + 2] = 0x02 | (current ? u8(1) : 0)
	a.buf[offset + 3] = u8(len(data))
	copy(a.buf[offset + 4:], data)
	return offset + 4 + len(data)
}

@(private = "file")
atapi_configuration_wanted :: proc(code, starting: u16, request_type: u8, current: bool) -> bool {
	if code < starting {return false}
	if request_type == 2 {return code == starting}
	if request_type == 1 {return current}
	return true
}

@(private = "file")
atapi_get_configuration :: proc(a: ^Atapi) {
	request_type := a.packet[1] & 3
	if request_type == 3 {
		atapi_check_condition(a, 0x05, 0x24, 0)
		return
	}
	starting := atapi_be16(a.packet[2:4])
	allocation := int(atapi_be16(a.packet[7:9]))
	a.buf = {}
	current_profile: u16
	if disc_image_present(&a.image) {
		current_profile = a.image.media_class == .Dvd_Rom ? u16(0x0010) : u16(0x0008)
	}
	atapi_put_be16(a.buf[:], 6, current_profile)
	offset := 8

	profile_data: [8]u8
	atapi_put_be16(profile_data[:], 0, 0x0008)
	profile_data[2] = current_profile == 0x0008 ? 1 : 0
	atapi_put_be16(profile_data[:], 4, 0x0010)
	profile_data[6] = current_profile == 0x0010 ? 1 : 0
	if atapi_configuration_wanted(0x0000, starting, request_type, true) {
		offset = atapi_configuration_add_feature(a, offset, 0x0000, true, profile_data[:])
	}
	core_data := [4]u8{0, 0, 0, 1}
	if atapi_configuration_wanted(0x0001, starting, request_type, true) {
		offset = atapi_configuration_add_feature(a, offset, 0x0001, true, core_data[:])
	}
	removable_data := [4]u8{0x29, 0, 0, 0}
	if atapi_configuration_wanted(0x0003, starting, request_type, true) {
		offset = atapi_configuration_add_feature(a, offset, 0x0003, true, removable_data[:])
	}
	random_data: [8]u8
	atapi_put_be32(random_data[:], 0, DISC_DATA_SECTOR_SIZE)
	random_data[4] = 0
	random_data[5] = 1
	random_current := current_profile != 0
	if atapi_configuration_wanted(0x0010, starting, request_type, random_current) {
		offset = atapi_configuration_add_feature(a, offset, 0x0010, random_current, random_data[:])
	}
	read_data: [4]u8
	cd_current := current_profile == 0x0008
	if atapi_configuration_wanted(0x001E, starting, request_type, cd_current) {
		offset = atapi_configuration_add_feature(a, offset, 0x001E, cd_current, read_data[:])
	}
	dvd_current := current_profile == 0x0010
	if atapi_configuration_wanted(0x001F, starting, request_type, dvd_current) {
		offset = atapi_configuration_add_feature(a, offset, 0x001F, dvd_current, read_data[:])
	}
	atapi_put_be32(a.buf[:], 0, u32(offset - 4))
	a.data_kind = .Reply
	atapi_start_data(a, min(allocation, offset))
}

@(private = "file")
atapi_put_be24 :: proc(data: []u8, offset: int, value: u32) {
	data[offset] = u8(value >> 16)
	data[offset + 1] = u8(value >> 8)
	data[offset + 2] = u8(value)
}

@(private = "file")
atapi_read_dvd_structure :: proc(a: ^Atapi) {
	if a.image.media_class != .Dvd_Rom {
		atapi_check_condition(a, 0x05, 0x30, 0x02)
		return
	}
	allocation := int(atapi_be16(a.packet[8:10]))
	a.buf = {}
	length := 0
	switch a.packet[7] {
	case 0x00:
		atapi_put_be16(a.buf[:], 0, 18)
		a.buf[4] = 0x01
		a.buf[5] = 0x0F
		a.buf[6] = 0x01
		start_sector := u32(0x030000)
		end_sector := start_sector + max(a.image.total_sectors, u32(1)) - 1
		atapi_put_be24(a.buf[:], 9, start_sector)
		atapi_put_be24(a.buf[:], 12, end_sector)
		atapi_put_be24(a.buf[:], 15, end_sector)
		length = 20
	case 0x01:
		atapi_put_be16(a.buf[:], 0, 6)
		a.buf[5] = 0xFF
		length = 8
	case 0xFF:
		atapi_put_be16(a.buf[:], 0, 10)
		a.buf[4] = 0x00
		a.buf[5] = 0x40
		a.buf[8] = 0x01
		a.buf[9] = 0x40
		length = 12
	case:
		atapi_check_condition(a, 0x05, 0x24, 0)
		return
	}
	a.data_kind = .Reply
	atapi_start_data(a, min(allocation, length))
}

@(private = "file")
atapi_mode_sense_6 :: proc(a: ^Atapi) {
	a.buf = {}
	a.buf[0] = 3
	allocation := int(a.packet[4])
	a.data_kind = .Reply
	atapi_start_data(a, min(allocation, 4))
}

@(private = "file")
atapi_mode_sense_10 :: proc(a: ^Atapi) {
	page_control := a.packet[2] >> 6
	page := a.packet[2] & 0x3F
	if page_control != 0 || page != 0x2A {
		a.buf = {}
		atapi_put_be16(a.buf[:], 0, 6)
		allocation := int(atapi_be16(a.packet[7:9]))
		a.data_kind = .Reply
		atapi_start_data(a, min(allocation, 8))
		return
	}
	a.buf = {}
	atapi_put_be16(a.buf[:], 0, 26)
	a.buf[2] = 0x01 if disc_image_present(&a.image) else 0x70
	a.buf[8] = 0x2A
	a.buf[9] = 18
	a.buf[14] = 0x20
	atapi_put_be16(a.buf[:], 16, ATAPI_DVD_SPEED_KBPS)
	atapi_put_be16(a.buf[:], 20, 2)
	current_speed := ATAPI_CD_SPEED_KBPS
	if a.image.media_class == .Dvd_Rom {current_speed = ATAPI_DVD_SPEED_KBPS}
	atapi_put_be16(a.buf[:], 22, current_speed)
	allocation := int(atapi_be16(a.packet[7:9]))
	a.data_kind = .Reply
	atapi_start_data(a, min(allocation, 28))
}

@(private = "file")
atapi_fill_identify :: proc(a: ^Atapi) {
	a.buf = {}
	atapi_put_word(a.buf[:], 0, 0x85C0)
	atapi_put_word(a.buf[:], 49, 0x0B00)
	atapi_put_word(a.buf[:], 53, 0x0003)
	atapi_put_word(a.buf[:], 63, 0x0407)
	atapi_put_word(a.buf[:], 64, 0x0003)
	atapi_put_word(a.buf[:], 80, 0x0010)
	model := "GSW DVD/CD 10X/52X"
	for w in 0 ..< 20 {
		c0: u8 = 0x20
		c1: u8 = 0x20
		if 2 * w < len(model) {
			c0 = model[2 * w]
		}
		if 2 * w + 1 < len(model) {
			c1 = model[2 * w + 1]
		}
		atapi_put_word(a.buf[:], 27 + w, u16(c0) << 8 | u16(c1))
	}
}

@(private = "file")
atapi_put_word :: proc(buf: []u8, word: int, value: u16) {
	buf[word * 2] = u8(value)
	buf[word * 2 + 1] = u8(value >> 8)
}

@(private = "file")
atapi_be16 :: proc(data: []u8) -> u16 {
	return u16(data[0]) << 8 | u16(data[1])
}

@(private = "file")
atapi_be32 :: proc(data: []u8) -> u32 {
	return u32(data[0]) << 24 | u32(data[1]) << 16 | u32(data[2]) << 8 | u32(data[3])
}

@(private = "file")
atapi_put_be16 :: proc(data: []u8, offset: int, value: u16) {
	data[offset] = u8(value >> 8)
	data[offset + 1] = u8(value)
}

@(private = "file")
atapi_put_be32 :: proc(data: []u8, offset: int, value: u32) {
	data[offset] = u8(value >> 24)
	data[offset + 1] = u8(value >> 16)
	data[offset + 2] = u8(value >> 8)
	data[offset + 3] = u8(value)
}

@(private = "file")
atapi_put_msf :: proc(data: []u8, offset: int, lba: u32) {
	frames := lba + 150
	data[offset] = 0
	data[offset + 1] = u8(frames / (60 * 75))
	data[offset + 2] = u8(frames / 75 % 60)
	data[offset + 3] = u8(frames % 75)
}

@(private = "file")
atapi_put_msf_relative :: proc(data: []u8, offset: int, frames: u32) {
	data[offset] = 0
	data[offset + 1] = u8(frames / (60 * 75))
	data[offset + 2] = u8(frames / 75 % 60)
	data[offset + 3] = u8(frames % 75)
}
