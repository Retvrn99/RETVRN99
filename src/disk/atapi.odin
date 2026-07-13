// SPDX-License-Identifier: GPL-3.0-only
package disk

ATAPI_STATUS_ERR  :: 0x01
ATAPI_STATUS_DRQ  :: 0x08
ATAPI_STATUS_DRDY :: 0x40
ATAPI_STATUS_BSY  :: 0x80

ATAPI_ERROR_ABRT :: 0x04

ATAPI_PACKET_BYTES :: 12
ATAPI_TRACE_HISTORY :: 64

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
}

Atapi_Data_Kind :: enum {
	None,
	Identify,
	Reply,
	Blocks,
}

Atapi :: struct {
	image: Cdrom_Image,
	state: Atapi_State,
	data_kind: Atapi_Data_Kind,
	buf: [CDROM_SECTOR_SIZE]u8,
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
	irq: proc(ctx: rawptr),
	irq_ctx: rawptr,
}

atapi_init :: proc(a: ^Atapi) {
	atapi_reset_signature(a)
}

atapi_mount :: proc(a: ^Atapi, path: string) -> bool {
	changed := a != nil && (a.media_changed || cdrom_image_present(&a.image))
	return atapi_set_media(a, path, changed)
}

atapi_attach :: proc(a: ^Atapi, path: string) -> bool {
	return atapi_set_media(a, path, false)
}

@(private = "file")
atapi_set_media :: proc(a: ^Atapi, path: string, changed: bool) -> bool {
	if a == nil {
		return false
	}
	if !cdrom_image_mount(&a.image, path) {
		return false
	}
	atapi_cancel_transfer(a)
	a.media_changed = changed
	a.sense_key, a.sense_asc, a.sense_ascq = 0, 0, 0
	a.reg_status = ATAPI_STATUS_DRDY
	return true
}

atapi_eject :: proc(a: ^Atapi) {
	if a == nil {
		return
	}
	cdrom_image_eject(&a.image)
	atapi_cancel_transfer(a)
	a.media_changed = true
	a.sense_key, a.sense_asc, a.sense_ascq = 0x02, 0x3A, 0
	a.reg_status = ATAPI_STATUS_DRDY
}

@(private = "file")
atapi_slave_selected :: proc(a: ^Atapi) -> bool {
	return a.reg_drive & 0x10 != 0
}

atapi_io_read :: proc(a: ^Atapi, port: u16, size: u8) -> u32 {
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
	case 0x177, 0x376:
		return u32(a.reg_status)
	}
	return 0xFF
}

atapi_io_write :: proc(a: ^Atapi, port: u16, size: u8, val: u32) {
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
			atapi_cancel_transfer(a)
			a.reg_status = ATAPI_STATUS_BSY
		} else if old & 0x04 != 0 {
			atapi_reset_signature(a)
		}
	}
}

@(private = "file")
atapi_raise_irq :: proc(a: ^Atapi) {
	if a.reg_ctrl & 0x02 == 0 && a.irq != nil {
		a.irq(a.irq_ctx)
	}
}

@(private = "file")
atapi_reset_signature :: proc(a: ^Atapi) {
	atapi_cancel_transfer(a)
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
}

@(private = "file")
atapi_command :: proc(a: ^Atapi, cmd: u8) {
	a.reg_error = 0
	switch cmd {
	case 0xA0:
		if a.reg_features & 0x03 != 0 {
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
		if !cdrom_image_read(&a.image, a.read_lba, a.buf[:]) {
			atapi_check_condition(a, 0x03, 0x11, 0)
			return
		}
		a.buf_len = CDROM_SECTOR_SIZE
		a.buf_pos = 0
		atapi_start_phase(a)
		return
	}
	atapi_complete(a)
}

@(private = "file")
atapi_complete :: proc(a: ^Atapi) {
	atapi_cancel_transfer(a)
	a.reg_error = 0
	a.reg_seccount = 0x03
	a.reg_lba_mid = 0
	a.reg_lba_hi = 0
	a.reg_status = ATAPI_STATUS_DRDY
	atapi_raise_irq(a)
}

@(private = "file")
atapi_check_condition :: proc(a: ^Atapi, key, asc, ascq: u8) {
	atapi_cancel_transfer(a)
	a.sense_key, a.sense_asc, a.sense_ascq = key, asc, ascq
	a.reg_error = key << 4
	a.reg_seccount = 0x03
	a.reg_lba_mid = 0
	a.reg_lba_hi = 0
	a.reg_status = ATAPI_STATUS_DRDY | ATAPI_STATUS_ERR
	atapi_raise_irq(a)
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
	if !cdrom_image_present(&a.image) {
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
			if lba >= a.image.block_count {
				atapi_check_condition(a, 0x05, 0x21, 0)
			} else {
				atapi_complete(a)
			}
		}
	case 0x42:
		if atapi_media_ready(a) {
			atapi_read_subchannel(a)
		}
	case 0x43:
		if atapi_media_ready(a) {
			atapi_read_toc(a)
		}
	case 0x5A:
		if !atapi_media_attention(a) {
			atapi_mode_sense_10(a)
		}
	case 0xA8:
		if atapi_media_ready(a) {
			atapi_read_blocks(a, atapi_be32(a.packet[2:6]), atapi_be32(a.packet[6:10]))
		}
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
	copy(a.buf[16:32], "GSW-CDROM       ")
	copy(a.buf[32:36], "1.0 ")
	a.data_kind = .Reply
	atapi_start_data(a, min(int(a.packet[4]), 36))
}

@(private = "file")
atapi_read_capacity :: proc(a: ^Atapi) {
	a.buf = {}
	last := a.image.block_count - 1
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
	if u64(lba) + u64(count) > u64(a.image.block_count) {
		atapi_check_condition(a, 0x05, 0x21, 0)
		return
	}
	if !cdrom_image_read(&a.image, lba, a.buf[:]) {
		atapi_check_condition(a, 0x03, 0x11, 0)
		return
	}
	a.read_lba = lba
	a.read_blocks = count
	a.data_kind = .Blocks
	atapi_start_data(a, CDROM_SECTOR_SIZE)
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
		a.buf[5], a.buf[6] = 0x14, 1
		if a.packet[1] & 0x02 != 0 {
			atapi_put_msf(a.buf[:], 8, 0)
		} else {
			atapi_put_be32(a.buf[:], 8, 0)
		}
		a.data_kind = .Reply
		atapi_start_data(a, min(allocation, 12))
		return
	}
	if format != 0 {
		atapi_check_condition(a, 0x05, 0x24, 0)
		return
	}
	a.buf = {}
	atapi_put_be16(a.buf[:], 0, 18)
	a.buf[2], a.buf[3] = 1, 1
	a.buf[5], a.buf[6] = 0x14, 1
	a.buf[13], a.buf[14] = 0x16, 0xAA
	if a.packet[1] & 0x02 != 0 {
		atapi_put_msf(a.buf[:], 8, 0)
		atapi_put_msf(a.buf[:], 16, a.image.block_count)
	} else {
		atapi_put_be32(a.buf[:], 8, 0)
		atapi_put_be32(a.buf[:], 16, a.image.block_count)
	}
	a.data_kind = .Reply
	atapi_start_data(a, min(allocation, 20))
}

@(private = "file")
atapi_read_subchannel :: proc(a: ^Atapi) {
	if a.packet[2] & 0x40 != 0 {
		atapi_check_condition(a, 0x05, 0x24, 0)
		return
	}
	a.buf = {}
	a.buf[1] = 0x15
	allocation := int(atapi_be16(a.packet[7:9]))
	a.data_kind = .Reply
	atapi_start_data(a, min(allocation, 4))
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
	a.buf[2] = 0x01 if cdrom_image_present(&a.image) else 0x70
	a.buf[8] = 0x2A
	a.buf[9] = 18
	a.buf[14] = 0x20
	atapi_put_be16(a.buf[:], 16, 9173)
	atapi_put_be16(a.buf[:], 20, 2)
	atapi_put_be16(a.buf[:], 22, 9173)
	allocation := int(atapi_be16(a.packet[7:9]))
	a.data_kind = .Reply
	atapi_start_data(a, min(allocation, 28))
}

@(private = "file")
atapi_fill_identify :: proc(a: ^Atapi) {
	a.buf = {}
	atapi_put_word(&a.buf, 0, 0x85C0)
	atapi_put_word(&a.buf, 49, 0x0A00)
	atapi_put_word(&a.buf, 53, 0x0003)
	atapi_put_word(&a.buf, 64, 0x0003)
	atapi_put_word(&a.buf, 80, 0x0010)
	model := "GSW-CDROM 52X"
	for w in 0 ..< 20 {
		c0: u8 = 0x20
		c1: u8 = 0x20
		if 2 * w < len(model) {
			c0 = model[2 * w]
		}
		if 2 * w + 1 < len(model) {
			c1 = model[2 * w + 1]
		}
		atapi_put_word(&a.buf, 27 + w, u16(c0) << 8 | u16(c1))
	}
}

@(private = "file")
atapi_put_word :: proc(buf: ^[CDROM_SECTOR_SIZE]u8, word: int, value: u16) {
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
