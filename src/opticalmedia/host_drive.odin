// SPDX-License-Identifier: GPL-3.0-only
package opticalmedia

import opticaldrive "../opticaldrive"

OPTICAL_MEDIA_MAX_PACKET_BYTES :: 2448

Host_Optical_Drive_Open_Proc :: proc(ctx: rawptr, drive: ^opticaldrive.Drive, path: string) -> bool
Host_Optical_Drive_Close_Proc :: proc(ctx: rawptr, drive: ^opticaldrive.Drive)
Host_Optical_Drive_Open_State_Proc :: proc(ctx: rawptr, drive: ^opticaldrive.Drive) -> bool
Host_Optical_Drive_Execute_Proc :: proc(
	ctx: rawptr,
	drive: ^opticaldrive.Drive,
	cdb: []u8,
	out: []u8,
) -> opticaldrive.Command_Result

Host_Optical_Drive_Adapters :: struct {
	ctx:     rawptr,
	open:    Host_Optical_Drive_Open_Proc,
	close:   Host_Optical_Drive_Close_Proc,
	is_open: Host_Optical_Drive_Open_State_Proc,
	execute: Host_Optical_Drive_Execute_Proc,
}

@(private)
Host_Optical_Drive :: struct {
	drive:    opticaldrive.Drive,
	adapters: Host_Optical_Drive_Adapters,
}

host_optical_drive_is_path :: proc(path: string) -> bool {
	return opticaldrive.is_path(path)
}

@(private = "file")
host_optical_drive_default_open :: proc(
	_: rawptr,
	drive: ^opticaldrive.Drive,
	path: string,
) -> bool {
	return opticaldrive.open(drive, path)
}

@(private = "file")
host_optical_drive_default_close :: proc(_: rawptr, drive: ^opticaldrive.Drive) {
	opticaldrive.close(drive)
}

@(private = "file")
host_optical_drive_default_is_open :: proc(_: rawptr, drive: ^opticaldrive.Drive) -> bool {
	return opticaldrive.is_open(drive)
}

@(private = "file")
host_optical_drive_default_execute :: proc(
	_: rawptr,
	drive: ^opticaldrive.Drive,
	cdb: []u8,
	out: []u8,
) -> opticaldrive.Command_Result {
	return opticaldrive.execute_read_only(drive, cdb, out)
}

@(private = "file")
host_optical_drive_adapters :: proc(
	adapters: Host_Optical_Drive_Adapters,
) -> Host_Optical_Drive_Adapters {
	result := adapters
	if result.open == nil {result.open = host_optical_drive_default_open}
	if result.close == nil {result.close = host_optical_drive_default_close}
	if result.is_open == nil {result.is_open = host_optical_drive_default_is_open}
	if result.execute == nil {result.execute = host_optical_drive_default_execute}
	return result
}

host_optical_drive_open :: proc(
	host: ^Host_Optical_Drive,
	path: string,
	adapters: Host_Optical_Drive_Adapters,
) -> bool {
	if host == nil || !host_optical_drive_is_path(path) {return false}
	candidate: Host_Optical_Drive
	candidate.adapters = host_optical_drive_adapters(adapters)
	if !candidate.adapters.open(candidate.adapters.ctx, &candidate.drive, path) {return false}
	host_optical_drive_close(host)
	host^ = candidate
	return true
}

host_optical_drive_close :: proc(host: ^Host_Optical_Drive) {
	if host == nil {return}
	if host.adapters.close != nil {host.adapters.close(host.adapters.ctx, &host.drive)}
	host^ = {}
}

host_optical_drive_is_open :: proc(host: ^Host_Optical_Drive) -> bool {
	return(
		host != nil &&
		host.adapters.is_open != nil &&
		host.adapters.is_open(host.adapters.ctx, &host.drive) \
	)
}

@(private)
host_optical_drive_read_opcode :: proc(opcode: u8) -> bool {
	return opcode == 0x28 || opcode == 0xA8 || opcode == 0xBE
}

@(private)
host_optical_drive_packet_allowed :: proc(opcode: u8) -> bool {
	switch opcode {
	case 0x00,
	     0x03,
	     0x12,
	     0x1A,
	     0x1E,
	     0x25,
	     0x28,
	     0x2B,
	     0x42,
	     0x43,
	     0x44,
	     0x45,
	     0x46,
	     0x47,
	     0x4B,
	     0x4E,
	     0x5A,
	     0xA8,
	     0xAD,
	     0xBE:
		return true
	}
	return false
}

@(private = "file")
host_optical_drive_allocation_length :: proc(cdb: []u8) -> int {
	if len(cdb) < 12 {return 0}
	switch cdb[0] {
	case 0x03, 0x12, 0x1A:
		return int(cdb[4])
	case 0x25:
		return 8
	case 0x42, 0x43, 0x44, 0x46, 0x5A:
		return int(u16(cdb[7]) << 8 | u16(cdb[8]))
	case 0xAD:
		return int(u16(cdb[8]) << 8 | u16(cdb[9]))
	}
	return 0
}

@(private = "file")
host_optical_drive_translate :: proc(
	result: opticaldrive.Command_Result,
) -> Optical_Media_Packet_Result {
	if result.ok && result.scsi_status == 0 {
		status := result.transferred > 0 ? Optical_Media_Packet_Status.Data : .Complete
		return {status = status, transferred = result.transferred}
	}
	sense := Optical_Media_Sense {
		key = 0x04,
		asc = 0x44,
	}
	if result.sense_length >= 14 {
		sense.key = result.sense[2] & 0x0F
		sense.asc = result.sense[12]
		sense.ascq = result.sense[13]
	}
	return {status = .Check_Condition, sense = sense}
}

host_optical_drive_execute_read_only :: proc(
	host: ^Host_Optical_Drive,
	cdb: []u8,
	out: []u8,
) -> Optical_Media_Packet_Result {
	if host == nil || len(cdb) == 0 || !host_optical_drive_packet_allowed(cdb[0]) {
		return {status = .Rejected}
	}
	if host_optical_drive_read_opcode(cdb[0]) {return {status = .Rejected}}
	length := min(
		host_optical_drive_allocation_length(cdb),
		len(out),
		OPTICAL_MEDIA_MAX_PACKET_BYTES,
	)
	result := host.adapters.execute(host.adapters.ctx, &host.drive, cdb, out[:length])
	return host_optical_drive_translate(result)
}

host_optical_drive_execute_read :: proc(
	host: ^Host_Optical_Drive,
	cdb: []u8,
	out: []u8,
) -> Optical_Media_Packet_Result {
	if host == nil ||
	   len(cdb) == 0 ||
	   !host_optical_drive_read_opcode(cdb[0]) ||
	   len(out) == 0 ||
	   len(out) > OPTICAL_MEDIA_MAX_PACKET_BYTES {
		return {status = .Rejected}
	}
	result := host.adapters.execute(host.adapters.ctx, &host.drive, cdb, out)
	return host_optical_drive_translate(result)
}

@(private)
host_optical_drive_set_read_sector :: proc(cdb: []u8, lba: u32) {
	if len(cdb) < 12 {return}
	cdb[2], cdb[3], cdb[4], cdb[5] = u8(lba >> 24), u8(lba >> 16), u8(lba >> 8), u8(lba)
	switch cdb[0] {
	case 0x28:
		cdb[7], cdb[8] = 0, 1
	case 0xA8:
		cdb[6], cdb[7], cdb[8], cdb[9] = 0, 0, 0, 1
	case 0xBE:
		cdb[6], cdb[7], cdb[8] = 0, 0, 1
	}
}
