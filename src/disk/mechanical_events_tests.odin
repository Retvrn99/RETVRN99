// SPDX-License-Identifier: GPL-3.0-only
package disk

import "core:testing"

Disk_Mechanical_Test_Recorder :: struct {
	ide_count:   int,
	ide_lba:     u64,
	ide_sectors: u32,
	ide_write:   bool,
	fdc_kinds:   [8]Fdc_Mechanical_Event_Kind,
	fdc_tracks:  [8]u8,
	fdc_amounts: [8]u16,
	fdc_count:   int,
}

disk_mechanical_test_ide :: proc(
	ctx: rawptr,
	lba: u64,
	sectors: u32,
	is_write: bool,
) {
	recorder := (^Disk_Mechanical_Test_Recorder)(ctx)
	recorder.ide_count += 1
	recorder.ide_lba = lba
	recorder.ide_sectors = sectors
	recorder.ide_write = is_write
}

disk_mechanical_test_fdc :: proc(
	ctx: rawptr,
	kind: Fdc_Mechanical_Event_Kind,
	track: u8,
	amount: u16,
) {
	recorder := (^Disk_Mechanical_Test_Recorder)(ctx)
	if recorder.fdc_count >= len(recorder.fdc_kinds) {return}
	index := recorder.fdc_count
	recorder.fdc_kinds[index] = kind
	recorder.fdc_tracks[index] = track
	recorder.fdc_amounts[index] = amount
	recorder.fdc_count += 1
}

@(test)
test_ide_mechanical_event_follows_successful_media_access :: proc(t: ^testing.T) {
	ram: Ide_Test_Ram
	ide: Ide
	ide_test_setup(&ram, &ide)
	defer delete(ram.data)
	recorder: Disk_Mechanical_Test_Recorder
	ide_set_mechanical_access(&ide, &recorder, disk_mechanical_test_ide)

	ide_test_set_lba28(&ide, 31, 2)
	ide_test_command(&ide, 0x20)
	testing.expect_value(t, recorder.ide_count, 1)
	testing.expect_value(t, recorder.ide_lba, u64(31))
	testing.expect_value(t, recorder.ide_sectors, u32(2))
	testing.expect(t, !recorder.ide_write)

	ram.read_fail = true
	ide_test_set_lba28(&ide, 41, 1)
	ide_test_command(&ide, 0x20)
	testing.expect_value(t, recorder.ide_count, 1)
}

@(test)
test_fdc_mechanical_events_cover_motor_seek_and_transfer :: proc(t: ^testing.T) {
	f: Fdc
	dma: Fdc_Test_Dma
	irqs := 0
	fdc_test_setup(&f, &dma, &irqs)
	recorder: Disk_Mechanical_Test_Recorder
	fdc_set_mechanical_events(&f, &recorder, disk_mechanical_test_fdc)
	fdc_test_enable(&f)

	image := fdc_test_image()
	defer delete(image)
	testing.expect(t, fdc_set_media(&f, image))
	defer fdc_eject_media(&f)
	guest := make([]u8, FLOPPY_SECTOR)
	defer delete(guest)
	dma.ram = guest
	dma.limit = FLOPPY_SECTOR

	fdc_out(&f, 0x3F2, 0x1C)
	fdc_out(&f, 0x3F5, 0x0F)
	fdc_out(&f, 0x3F5, 0)
	fdc_out(&f, 0x3F5, 12)
	fdc_out(&f, 0x3F5, 0xE6)
	for parameter in ([]u8{0, 0, 0, 1, 2, 18, 0x1B, 0xFF}) {
		fdc_out(&f, 0x3F5, parameter)
	}
	fdc_test_run(&f)
	fdc_out(&f, 0x3F2, 0x0C)

	testing.expect_value(t, recorder.fdc_count, 4)
	testing.expect_value(t, recorder.fdc_kinds[0], Fdc_Mechanical_Event_Kind.Motor)
	testing.expect_value(t, recorder.fdc_amounts[0], u16(1))
	testing.expect_value(t, recorder.fdc_kinds[1], Fdc_Mechanical_Event_Kind.Seek)
	testing.expect_value(t, recorder.fdc_tracks[1], u8(12))
	testing.expect_value(t, recorder.fdc_amounts[1], u16(12))
	testing.expect_value(t, recorder.fdc_kinds[2], Fdc_Mechanical_Event_Kind.Transfer)
	testing.expect_value(t, recorder.fdc_amounts[2], u16(FLOPPY_SECTOR))
	testing.expect_value(t, recorder.fdc_kinds[3], Fdc_Mechanical_Event_Kind.Motor)
	testing.expect_value(t, recorder.fdc_amounts[3], u16(0))
}
