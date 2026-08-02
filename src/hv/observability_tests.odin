// SPDX-License-Identifier: GPL-3.0-only
package hv

import "core:testing"

@(test)
whpx_observability_test_exit_and_fallback_counters :: proc(t: ^testing.T) {
	vm: Vm
	whpx_note_physical_exit(&vm, .MemoryAccess)
	whpx_note_physical_exit(&vm, .X64IoPortAccess)
	whpx_note_physical_exit(&vm, .MemoryAccess)
	whpx_note_mmio_fallback(&vm, .Scalar_Load, .Attempt)
	whpx_note_mmio_fallback(&vm, .Scalar_Load, .Success)
	whpx_note_mmio_fallback(&vm, .Invalid, .Attempt)
	whpx_note_mmio_fallback(&vm, .Invalid, .Failure)
	legacy_aperture_execution_set_mode(&vm, .Scalar)
	vp: WHV_VP_EXIT_CONTEXT
	mmio := WHV_MEMORY_ACCESS_CONTEXT{Gpa = 0xA0000}
	_, _ = legacy_aperture_execution_step(&vm, &vp, &mmio)

	snapshot := whpx_graphics_observability(&vm)
	testing.expect_value(t, snapshot.physical_exit_count, u64(3))
	testing.expect_value(
		t,
		snapshot.physical_exit_reasons[int(Whpx_Physical_Exit_Reason.Memory_Access)],
		u64(2),
	)
	testing.expect_value(
		t,
		snapshot.physical_exit_reasons[int(Whpx_Physical_Exit_Reason.Io_Port_Access)],
		u64(1),
	)
	load := snapshot.mmio_fallback_by_kind[int(Whpx_Mmio_Kind.Scalar_Load)]
	testing.expect_value(t, load.attempts, u64(1))
	testing.expect_value(t, load.successes, u64(1))
	testing.expect_value(t, load.failures, u64(0))
	invalid := snapshot.mmio_fallback_by_kind[int(Whpx_Mmio_Kind.Invalid)]
	testing.expect_value(t, invalid.attempts, u64(1))
	testing.expect_value(t, invalid.successes, u64(0))
	testing.expect_value(t, invalid.failures, u64(1))
	testing.expect_value(t, snapshot.legacy_aperture_execution.mode, Legacy_Aperture_Execution_Mode.Scalar)
	testing.expect_value(t, snapshot.legacy_aperture_execution.memory_access_exits, u64(1))
	testing.expect_value(t, snapshot.legacy_aperture_execution.forwarded_exits, u64(1))
}
