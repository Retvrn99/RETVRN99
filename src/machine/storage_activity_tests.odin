// SPDX-License-Identifier: GPL-3.0-only
package machine

import "core:testing"

@(test)
machine_test_storage_activity_snapshot_maps_device_generations :: proc(t: ^testing.T) {
	m := new(Machine)
	defer free(m)
	m.fdc.activity_generation = 3
	m.ide.activity_generation = 5
	m.atapi.activity_generation = 7

	activity := machine_storage_activity(m)
	testing.expect_value(t, activity.floppy, u64(3))
	testing.expect_value(t, activity.hard_drive, u64(5))
	testing.expect_value(t, activity.dvd_rom, u64(7))
	testing.expect_value(t, machine_storage_activity(nil), Storage_Activity{})
}
