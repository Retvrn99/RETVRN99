// SPDX-License-Identifier: GPL-3.0-only
package hv

import "core:log"
import "core:testing"
import "core:time"
import config "../vmconfig"

@(test)
test_whpx_guest_runtime_excludes_sticky_cancel :: proc(t: ^testing.T) {
	if !available() {
		log.warn("WHPX not available")
		return
	}
	testing.set_fail_timeout(t, 5 * time.Second)
	vm: Vm
	if !testing.expect(t, create(&vm, 64 * 1024 * 1024)) { return }
	defer destroy(&vm)
	// mov ecx,1000000; loop $; hlt
	copy(vm.ram[0x7C00:], []u8{0x66, 0xB9, 0x40, 0x42, 0x0F, 0x00, 0x67, 0xE2, 0xFD, 0xF4})
	set_realmode_entry(&vm, 0, 0x7C00)

	before, ok := guest_runtime_ns(&vm)
	if !testing.expect(t, ok) { return }
	cancel(&vm)
	if !testing.expect_value(t, run(&vm).kind, Exit_Kind.Canceled) { return }
	after_sticky: u64
	after_sticky, ok = guest_runtime_ns(&vm)
	if !testing.expect(t, ok) { return }
	testing.expect(t, after_sticky - before <= 100_000)

	if !testing.expect_value(t, run(&vm).kind, Exit_Kind.Halt) { return }
	after_run: u64
	after_run, ok = guest_runtime_ns(&vm)
	if !testing.expect(t, ok) { return }
	testing.expect(t, after_run > after_sticky)

	governor: Governor
	if !testing.expect(t, governor_init(&governor, &vm, .Turbo)) { return }
	defer governor_destroy(&governor)
	governor.balance_ns = 123_456
	governor_set_mode(&governor, &vm, .GSW_886)
	testing.expect_value(t, governor.mode, config.Cpu_Mode.GSW_886)
	testing.expect_value(t, governor.balance_ns, i64(0))
	testing.expect(t, governor.primed)
	governor.balance_ns = 123_456
	governor_set_mode(&governor, &vm, .Turbo)
	testing.expect_value(t, governor.mode, config.Cpu_Mode.Turbo)
	testing.expect_value(t, governor.balance_ns, i64(0))
}
