// SPDX-License-Identifier: GPL-3.0-only
package machine

import sound "../audio"
import disk "../disk"
import "core:testing"

Mechanical_Event_Test_Sink :: struct {
	events: [8]sound.Mechanical_Event,
	count:  int,
}

mechanical_event_test_emit :: proc(ctx: rawptr, event: sound.Mechanical_Event) {
	sink := (^Mechanical_Event_Test_Sink)(ctx)
	if sink == nil || sink.count >= len(sink.events) {return}
	sink.events[sink.count] = event
	sink.count += 1
}

@(test)
test_machine_maps_storage_mechanical_events :: proc(t: ^testing.T) {
	m := new(Machine)
	defer free(m)
	recorder: Mechanical_Event_Test_Sink
	machine_set_mechanical_event_sink(m, {
		ctx = &recorder,
		emit = mechanical_event_test_emit,
	})
	testing.expect(t, m.ide.mechanical_access != nil)
	testing.expect(t, m.fdc.mechanical_event != nil)

	machine_ide_mechanical_access(m, 0x1234, 16, true)
	machine_fdc_mechanical_event(m, disk.Fdc_Mechanical_Event_Kind.Motor, 3, 1)
	machine_fdc_mechanical_event(m, disk.Fdc_Mechanical_Event_Kind.Seek, 17, 5)
	machine_fdc_mechanical_event(m, disk.Fdc_Mechanical_Event_Kind.Transfer, 17, 512)

	testing.expect_value(t, recorder.count, 4)
	testing.expect_value(t, recorder.events[0].kind, sound.Mechanical_Event_Kind.Hard_Drive_Access)
	testing.expect_value(t, recorder.events[0].position, u32(0x1234))
	testing.expect_value(t, recorder.events[0].amount, u16(16))
	testing.expect(t, recorder.events[0].write)
	testing.expect_value(t, recorder.events[1].kind, sound.Mechanical_Event_Kind.Floppy_Motor)
	testing.expect_value(t, recorder.events[2].kind, sound.Mechanical_Event_Kind.Floppy_Seek)
	testing.expect_value(t, recorder.events[3].kind, sound.Mechanical_Event_Kind.Floppy_Transfer)
}
