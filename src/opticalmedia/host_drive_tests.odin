// SPDX-License-Identifier: GPL-3.0-only
package opticalmedia

import opticaldrive "../opticaldrive"
import "core:testing"

Host_Optical_Drive_Test_State :: struct {
	execute_count: int,
	close_count:   int,
	last_opcode:   u8,
	last_length:   int,
	fail_open:     bool,
	fail_command:  bool,
}

host_optical_drive_test_open :: proc(
	ctx: rawptr,
	drive: ^opticaldrive.Drive,
	path: string,
) -> bool {
	state := (^Host_Optical_Drive_Test_State)(ctx)
	if state.fail_open {return false}
	letter, ok := opticaldrive.path_letter(path)
	if !ok {return false}
	drive.handle = 1
	drive.letter = letter
	return true
}

host_optical_drive_test_close :: proc(ctx: rawptr, drive: ^opticaldrive.Drive) {
	state := (^Host_Optical_Drive_Test_State)(ctx)
	if drive.handle != 0 {state.close_count += 1}
	drive^ = {}
}

host_optical_drive_test_is_open :: proc(_: rawptr, drive: ^opticaldrive.Drive) -> bool {
	return drive != nil && drive.handle != 0
}

host_optical_drive_test_execute :: proc(
	ctx: rawptr,
	_: ^opticaldrive.Drive,
	cdb: []u8,
	out: []u8,
) -> opticaldrive.Command_Result {
	state := (^Host_Optical_Drive_Test_State)(ctx)
	state.execute_count += 1
	state.last_opcode = cdb[0]
	state.last_length = len(out)
	if state.fail_command {
		result: opticaldrive.Command_Result
		result.sense_length = 14
		result.sense[2] = 0x05
		result.sense[12], result.sense[13] = 0x24, 0x01
		return result
	}
	for &byte, index in out {byte = u8(index)}
	return {ok = true, transferred = len(out)}
}

host_optical_drive_test_adapters :: proc(
	state: ^Host_Optical_Drive_Test_State,
) -> Host_Optical_Drive_Adapters {
	return {
		ctx = state,
		open = host_optical_drive_test_open,
		close = host_optical_drive_test_close,
		is_open = host_optical_drive_test_is_open,
		execute = host_optical_drive_test_execute,
	}
}

@(test)
host_optical_drive_test_rejects_write_format_and_data_out_before_adapter :: proc(t: ^testing.T) {
	state: Host_Optical_Drive_Test_State
	media: Optical_Media
	testing.expect(
		t,
		optical_media_set_host_adapters(&media, host_optical_drive_test_adapters(&state)),
	)
	testing.expect(t, optical_media_mount(&media, "hostcd://X:"))
	defer optical_media_destroy(&media)

	blocked := [5]u8{0x04, 0x15, 0x2A, 0x55, 0xAA}
	for opcode in blocked {
		cdb: [12]u8
		cdb[0] = opcode
		result := optical_media_execute_read_only_packet(&media, cdb[:], nil)
		testing.expect_value(t, result.status, Optical_Media_Packet_Status.Rejected)
	}
	testing.expect_value(t, state.execute_count, 0)

	toc: [12]u8
	toc[0], toc[7], toc[8] = 0x43, 0xFF, 0xFF
	out: [OPTICAL_MEDIA_MAX_PACKET_BYTES + 32]u8
	result := optical_media_execute_read_only_packet(&media, toc[:], out[:])
	testing.expect_value(t, result.status, Optical_Media_Packet_Status.Data)
	testing.expect_value(t, result.transferred, OPTICAL_MEDIA_MAX_PACKET_BYTES)
	testing.expect_value(t, state.execute_count, 1)
	testing.expect_value(t, state.last_opcode, u8(0x43))
	testing.expect_value(t, state.last_length, OPTICAL_MEDIA_MAX_PACKET_BYTES)
}

@(test)
host_optical_drive_test_failed_remount_retains_open_backing_and_translates_sense :: proc(
	t: ^testing.T,
) {
	state: Host_Optical_Drive_Test_State
	media: Optical_Media
	testing.expect(
		t,
		optical_media_set_host_adapters(&media, host_optical_drive_test_adapters(&state)),
	)
	testing.expect(t, optical_media_mount(&media, "hostcd://F:"))
	defer optical_media_destroy(&media)

	state.fail_open = true
	testing.expect(t, !optical_media_mount(&media, "hostcd://G:"))
	observation := optical_media_observe(&media)
	testing.expect(t, observation.present)
	testing.expect_value(t, observation.backing, Optical_Media_Backing.Host_Drive)
	testing.expect_value(t, state.close_count, 0)

	state.fail_open = false
	state.fail_command = true
	inquiry: [12]u8
	inquiry[0], inquiry[4] = 0x12, 36
	data: [36]u8
	result := optical_media_execute_read_only_packet(&media, inquiry[:], data[:])
	testing.expect_value(t, result.status, Optical_Media_Packet_Status.Check_Condition)
	testing.expect_value(t, result.sense, Optical_Media_Sense{key = 0x05, asc = 0x24, ascq = 0x01})
}
