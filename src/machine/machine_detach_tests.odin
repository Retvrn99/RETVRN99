// SPDX-License-Identifier: GPL-3.0-only
package machine

import disk "../disk"
import "core:testing"

Machine_Detach_Probe :: struct {
	flushes: int,
	succeed: bool,
}

@(test)
machine_detach_disk_test_flushes_once_and_drops_backing :: proc(t: ^testing.T) {
	probe := Machine_Detach_Probe {
		succeed = true,
	}
	m := new(Machine)
	defer free(m)
	m.has_disk = true
	m.ide.bd = disk.Block_Device {
		ctx = &probe,
		flush = proc(ctx: rawptr) -> bool {
			probe := (^Machine_Detach_Probe)(ctx)
			probe.flushes += 1
			return probe.succeed
		},
	}

	testing.expect(t, machine_detach_disk(m))
	testing.expect_value(t, probe.flushes, 1)
	testing.expect(t, !m.has_disk)
	testing.expect(t, m.ide.bd.ctx == nil)
	testing.expect(t, machine_detach_disk(m))
	testing.expect_value(t, probe.flushes, 1)
}

@(test)
machine_detach_disk_test_failed_checkpoint_retains_backing :: proc(t: ^testing.T) {
	probe: Machine_Detach_Probe
	m := new(Machine)
	defer free(m)
	m.has_disk = true
	m.ide.bd = disk.Block_Device {
		ctx = &probe,
		flush = proc(ctx: rawptr) -> bool {
			(^Machine_Detach_Probe)(ctx).flushes += 1
			return false
		},
	}

	testing.expect(t, !machine_detach_disk(m))
	testing.expect_value(t, probe.flushes, 1)
	testing.expect(t, m.has_disk)
	testing.expect_value(t, m.ide.bd.ctx, rawptr(&probe))
}
