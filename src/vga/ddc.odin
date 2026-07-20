// SPDX-License-Identifier: GPL-3.0-only
package vga

Ddc_Phase :: enum u8 {
	Idle,
	Address,
	Offset,
	Ack,
	Read,
	Read_Ack,
}

@(rodata)
VGA_EDID_BLOCK0 := [128]u8 {
	0x00,
	0xFF,
	0xFF,
	0xFF,
	0xFF,
	0xFF,
	0xFF,
	0x00,
	0x1E,
	0x77,
	0x01,
	0x47,
	0x20,
	0x07,
	0x26,
	0x20,
	0x01,
	0x24,
	0x01,
	0x03,
	0x0E,
	0x20,
	0x18,
	0x78,
	0x0A,
	0xEE,
	0x91,
	0xA3,
	0x54,
	0x4C,
	0x99,
	0x26,
	0x0F,
	0x50,
	0x54,
	0x21,
	0x08,
	0x00,
	0x01,
	0x01,
	0x01,
	0x01,
	0x01,
	0x01,
	0x01,
	0x01,
	0x01,
	0x01,
	0x01,
	0x01,
	0x01,
	0x01,
	0x01,
	0x64,
	0x19,
	0x00,
	0x40,
	0x41,
	0x00,
	0x26,
	0x30,
	0x18,
	0x88,
	0x36,
	0x00,
	0x40,
	0xF0,
	0x10,
	0x00,
	0x00,
	0x18,
	0x00,
	0x00,
	0x00,
	0xFD,
	0x00,
	0x32,
	0x4B,
	0x1E,
	0x50,
	0x11,
	0x00,
	0x0A,
	0x20,
	0x20,
	0x20,
	0x20,
	0x20,
	0x20,
	0x00,
	0x00,
	0x00,
	0xFC,
	0x00,
	0x47,
	0x53,
	0x57,
	0x2D,
	0x56,
	0x47,
	0x41,
	0x0A,
	0x20,
	0x20,
	0x20,
	0x20,
	0x20,
	0x00,
	0x00,
	0x00,
	0xFF,
	0x00,
	0x52,
	0x45,
	0x54,
	0x56,
	0x52,
	0x4E,
	0x39,
	0x39,
	0x0A,
	0x20,
	0x20,
	0x20,
	0x20,
	0x20,
	0x00,
	0x7C,
}

DDC_ADDRESS :: u8(0x50)

@(private = "package")
ddc_reset :: proc(v: ^Vga) {
	if v == nil {return}
	v.ddc_host_scl_release = true
	v.ddc_host_sda_release = true
	v.ddc_drive_sda_low = false
	v.ddc_phase = .Idle
	v.ddc_after_ack_phase = .Idle
	v.ddc_bit_count = 0
	v.ddc_shift = 0
	v.ddc_offset = 0
	v.ddc_read_byte = 0
	v.ddc_read_bit = 0
	v.ddc_master_ack = false
}

@(private = "file")
ddc_line_scl :: proc(v: ^Vga) -> bool {
	return v.ddc_host_scl_release
}

@(private = "file")
ddc_line_sda :: proc(v: ^Vga) -> bool {
	return v.ddc_host_sda_release && !v.ddc_drive_sda_low
}

@(private = "file")
ddc_prepare_read_byte :: proc(v: ^Vga) {
	v.ddc_read_byte = VGA_EDID_BLOCK0[int(v.ddc_offset) % len(VGA_EDID_BLOCK0)]
	v.ddc_read_bit = 7
	v.ddc_drive_sda_low = v.ddc_read_byte & (u8(1) << 7) == 0
}

@(private = "file")
ddc_next_read_bit :: proc(v: ^Vga) {
	if v.ddc_read_bit <= 0 {
		v.ddc_phase = .Read_Ack
		v.ddc_drive_sda_low = false
		return
	}
	v.ddc_read_bit -= 1
	v.ddc_drive_sda_low = v.ddc_read_byte & (u8(1) << uint(v.ddc_read_bit)) == 0
}

@(private = "file")
ddc_begin_start :: proc(v: ^Vga) {
	v.ddc_drive_sda_low = false
	v.ddc_phase = .Address
	v.ddc_after_ack_phase = .Idle
	v.ddc_bit_count = 0
	v.ddc_shift = 0
}

@(private = "file")
ddc_finish_stop :: proc(v: ^Vga) {
	v.ddc_drive_sda_low = false
	v.ddc_phase = .Idle
	v.ddc_after_ack_phase = .Idle
	v.ddc_bit_count = 0
	v.ddc_shift = 0
}

@(private = "file")
ddc_ack_then :: proc(v: ^Vga, next: Ddc_Phase) {
	v.ddc_phase = .Ack
	v.ddc_after_ack_phase = next
	v.ddc_bit_count = 8
	v.ddc_drive_sda_low = false
}

@(private = "file")
ddc_nack :: proc(v: ^Vga) {
	v.ddc_phase = .Idle
	v.ddc_after_ack_phase = .Idle
	v.ddc_bit_count = 0
	v.ddc_drive_sda_low = false
}

@(private = "file")
ddc_host_byte_complete :: proc(v: ^Vga) {
	#partial switch v.ddc_phase {
	case .Address:
		address := v.ddc_shift >> 1
		read := v.ddc_shift & 1 != 0
		if address != DDC_ADDRESS {
			ddc_nack(v)
		} else if read {
			ddc_ack_then(v, .Read)
		} else {
			ddc_ack_then(v, .Offset)
		}
	case .Offset:
		v.ddc_offset = v.ddc_shift
		ddc_ack_then(v, .Idle)
	}
	v.ddc_shift = 0
}

@(private = "file")
ddc_sample_host_bit :: proc(v: ^Vga, high: bool) {
	v.ddc_shift = (v.ddc_shift << 1) | (high ? u8(1) : u8(0))
	v.ddc_bit_count += 1
	if v.ddc_bit_count >= 8 {ddc_host_byte_complete(v)}
}

@(private = "file")
ddc_scl_rise :: proc(v: ^Vga, sda: bool) {
	#partial switch v.ddc_phase {
	case .Address, .Offset:
		ddc_sample_host_bit(v, sda)
	case .Read_Ack:
		v.ddc_master_ack = !sda
	}
}

@(private = "file")
ddc_scl_fall :: proc(v: ^Vga) {
	#partial switch v.ddc_phase {
	case .Ack:
		if v.ddc_bit_count != 0 {
			v.ddc_bit_count = 0
			v.ddc_drive_sda_low = true
			return
		}
		v.ddc_drive_sda_low = false
		v.ddc_phase = v.ddc_after_ack_phase
		if v.ddc_phase == .Read {ddc_prepare_read_byte(v)}
	case .Read:
		ddc_next_read_bit(v)
	case .Read_Ack:
		if v.ddc_master_ack {
			v.ddc_offset += 1
			v.ddc_phase = .Read
			ddc_prepare_read_byte(v)
		} else {
			ddc_finish_stop(v)
		}
	}
}

@(private = "package")
ddc_write_register :: proc(v: ^Vga, value: u16) -> bool {
	if v == nil {return false}
	old_scl := ddc_line_scl(v)
	old_sda := ddc_line_sda(v)
	v.ddc_host_scl_release = value & 0x01 != 0
	v.ddc_host_sda_release = value & 0x02 != 0
	new_scl := ddc_line_scl(v)
	new_sda := ddc_line_sda(v)
	if old_scl && old_sda && !new_sda {ddc_begin_start(v)}
	if old_scl && !old_sda && new_sda {ddc_finish_stop(v)}
	if !old_scl && new_scl {ddc_scl_rise(v, new_sda)}
	if old_scl && !new_scl {ddc_scl_fall(v)}
	return true
}

@(private = "package")
ddc_read_register :: proc(v: ^Vga) -> u16 {
	if v == nil {return 0}
	value := u16(0x80)
	if v.ddc_host_scl_release {value |= 0x01}
	if v.ddc_host_sda_release {value |= 0x02}
	if ddc_line_scl(v) {value |= 0x04}
	if ddc_line_sda(v) {value |= 0x08}
	return value
}

ddc_edid_checksum_valid :: proc() -> bool {
	sum: u8
	for value in VGA_EDID_BLOCK0 {sum += value}
	return sum == 0
}
