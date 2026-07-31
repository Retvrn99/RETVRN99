// SPDX-License-Identifier: GPL-3.0-only
package opticaldrive

import win32 "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention = "system")
foreign kernel32 {
	GetLogicalDrives :: proc() -> win32.DWORD ---
	GetDriveTypeW :: proc(root_path_name: win32.LPCWSTR) -> win32.UINT ---
}

DRIVE_CDROM :: 5
IOCTL_SCSI_PASS_THROUGH_DIRECT :: win32.DWORD(0x0004D014)
SCSI_IOCTL_DATA_IN :: u8(1)
SCSI_IOCTL_DATA_UNSPECIFIED :: u8(2)

Scsi_Pass_Through_Direct :: struct {
	length:               u16,
	scsi_status:          u8,
	path_id:              u8,
	target_id:            u8,
	lun:                  u8,
	cdb_length:           u8,
	sense_info_length:    u8,
	data_in:              u8,
	data_transfer_length: u32,
	time_out_value:       u32,
	data_buffer:          rawptr,
	sense_info_offset:    u32,
	cdb:                  [16]u8,
}

Scsi_Request :: struct {
	packet: Scsi_Pass_Through_Direct,
	sense:  [32]u8,
}

#assert(offset_of(Scsi_Pass_Through_Direct, data_buffer) == 24)
#assert(offset_of(Scsi_Pass_Through_Direct, cdb) == 36)

enumerate :: proc() -> [26]bool {
	result: [26]bool
	mask := GetLogicalDrives()
	for index in 0 ..< 26 {
		if mask & (win32.DWORD(1) << u32(index)) == 0 {continue}
		root := [4]u16{u16('A' + index), ':', '\\', 0}
		result[index] = GetDriveTypeW(cstring16(&root[0])) == DRIVE_CDROM
	}
	return result
}

open :: proc(drive: ^Drive, value: string) -> bool {
	if drive == nil {return false}
	close(drive)
	letter, ok := path_letter(value)
	if !ok {return false}
	device := [7]u16{'\\', '\\', '.', '\\', u16(letter), ':', 0}
	handle := win32.CreateFileW(
		cstring16(&device[0]),
		win32.GENERIC_READ | win32.GENERIC_WRITE,
		win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE,
		nil,
		win32.OPEN_EXISTING,
		0,
		nil,
	)
	if handle == win32.INVALID_HANDLE_VALUE {return false}
	drive.handle = uintptr(handle)
	drive.letter = letter
	return true
}

close :: proc(drive: ^Drive) {
	if drive == nil {return}
	if drive.handle != 0 && drive.handle != ~uintptr(0) {
		_ = win32.CloseHandle(win32.HANDLE(drive.handle))
	}
	drive^ = {}
}

is_open :: proc(drive: ^Drive) -> bool {
	return drive != nil && drive.handle != 0 && drive.handle != ~uintptr(0)
}

execute_read_only :: proc(drive: ^Drive, cdb: []u8, data: []u8) -> Command_Result {
	result: Command_Result
	if !is_open(drive) || len(cdb) == 0 || len(cdb) > 16 {return result}
	request: Scsi_Request
	request.packet.length = u16(size_of(Scsi_Pass_Through_Direct))
	request.packet.cdb_length = u8(len(cdb))
	request.packet.sense_info_length = u8(len(request.sense))
	request.packet.data_in = len(data) == 0 ? SCSI_IOCTL_DATA_UNSPECIFIED : SCSI_IOCTL_DATA_IN
	request.packet.data_transfer_length = u32(len(data))
	request.packet.time_out_value = 30
	if len(data) > 0 {request.packet.data_buffer = raw_data(data)}
	request.packet.sense_info_offset = u32(offset_of(Scsi_Request, sense))
	copy(request.packet.cdb[:], cdb)
	bytes: win32.DWORD
	result.ok = bool(
		win32.DeviceIoControl(
			win32.HANDLE(drive.handle),
			IOCTL_SCSI_PASS_THROUGH_DIRECT,
			&request,
			size_of(request),
			&request,
			size_of(request),
			&bytes,
			nil,
		),
	)
	result.scsi_status = request.packet.scsi_status
	result.transferred = int(min(request.packet.data_transfer_length, u32(len(data))))
	result.sense = request.sense
	result.sense_length = len(request.sense)
	return result
}
