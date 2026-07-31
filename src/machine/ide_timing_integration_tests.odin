// SPDX-License-Identifier: GPL-3.0-only
package machine

import disk "../disk"
import "core:testing"

@(test)
test_machine_master_timeline_publishes_timed_ide_phase :: proc(t: ^testing.T) {
	m := new(Machine)
	defer free(m)
	if !testing.expect(t, machine_test_audio_timing_init(m)) {return}
	pic_setup(&m.platform.pic)
	backing := make([]u8, 1024 * 1024)
	defer delete(backing)
	disk.ide_init(&m.ide, machine_test_bd(&backing))
	m.ide.irq_ctx = m
	m.ide.irq = proc(ctx: rawptr, asserted: bool) {
	pc_at_platform_irq_level(&(^Machine)(ctx).platform, 14, asserted)
	}

	disk.ide_io_write(&m.ide, 0x1F6, 1, 0xE0)
	disk.ide_io_write(&m.ide, 0x1F7, 1, 0xEC)
	testing.expect_value(t, u8(disk.ide_io_read(&m.ide, 0x1F7, 1)), u8(disk.IDE_STATUS_BSY))
	machine_advance_time_ns(m, 99_999)
	testing.expect(t, disk.ide_io_read(&m.ide, 0x1F7, 1) & disk.IDE_STATUS_DRQ == 0)
	testing.expect(t, m.platform.pic.slave.irr & 0x40 == 0)
	machine_advance_time_ns(m, 1)
	testing.expect(t, disk.ide_io_read(&m.ide, 0x1F7, 1) & disk.IDE_STATUS_DRQ != 0)
	testing.expect(t, m.platform.pic.slave.irr & 0x40 != 0)
}
