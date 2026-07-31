// SPDX-License-Identifier: GPL-3.0-only
package machine

import hv "../hv"
import "core:log"
import "core:testing"
import "core:time"

machine_test_setup_irq0 :: proc(pic: ^Pic_Pair, masked: bool) {
	pic_out(pic, 0x20, 0x11)
	pic_out(pic, 0xA0, 0x11)
	pic_out(pic, 0x21, 0x08)
	pic_out(pic, 0xA1, 0x70)
	pic_out(pic, 0x21, 0x04)
	pic_out(pic, 0xA1, 0x02)
	pic_out(pic, 0x21, 0x01)
	pic_out(pic, 0xA1, 0x01)
	pic_out(pic, 0x21, masked ? 0xFF : 0xFE)
	pic_out(pic, 0xA1, 0xFF)
}

@(test)
test_machine_hlt_waits_for_deliverable_latched_pit_irq :: proc(t: ^testing.T) {
	if !hv.available() {
		log.warn("WHPX not available")
		return
	}
	testing.set_fail_timeout(t, 10 * time.Second)
	m := new(Machine)
	defer free(m)
	if !testing.expect(t, machine_init(m, 64 * 1024 * 1024)) {return}
	defer machine_destroy(m)
	machine_test_setup_irq0(&m.platform.pic, true)

	copy(m.vm.ram[0x20:], []u8{0x00, 0x05, 0x00, 0x00})
	copy(m.vm.ram[0x500:], []u8{0x50, 0xB0, 0x20, 0xE6, 0x20, 0x58, 0xCF})
	copy(m.vm.ram[0x7C00:], []u8{
		0xBC, 0x00, 0x70,
		0xFB,
		0xF4,
		0xB0, 0x42,
		0xE6, 0x99,
		0xF4,
	})
	seen: u32
	bus_register(&m.platform.bus, 0x99, 0x99, Io_Handler{
		ctx = &seen,
		write = proc(ctx: rawptr, port: u16, size: u8, value: u32) {(^u32)(ctx)^ = value},
	})
	pit_out(&m.platform.pit, 0x43, 0x34)
	pit_out(&m.platform.pit, 0x40, 0x9C)
	pit_out(&m.platform.pit, 0x40, 0x2E)
	hv.set_realmode_entry(&m.vm, 0, 0x7C00)

	if !testing.expect(t, step(m)) {return}
	testing.expect(t, m.cpu_halted)
	testing.expect_value(t, seen, u32(0))
	machine_advance_time_ns(m, 20_000_000)
	testing.expect(t, m.platform.pic.master.irr & 0x01 != 0)
	if !testing.expect(t, step(m)) {return}
	testing.expect(t, m.cpu_halted)
	testing.expect_value(t, seen, u32(0))

	pic_out(&m.platform.pic, 0x21, 0xFE)
	for _ in 0 ..< 10 {
		if !step(m) || seen == 0x42 {break}
	}
	testing.expect_value(t, seen, u32(0x42))
}

@(test)
test_machine_halted_pending_event_drains_before_pic_irq :: proc(t: ^testing.T) {
	if !hv.available() {
		log.warn("WHPX not available")
		return
	}
	testing.set_fail_timeout(t, 10 * time.Second)
	m := new(Machine)
	defer free(m)
	if !testing.expect(t, machine_init(m, 64 * 1024 * 1024)) {return}
	defer machine_destroy(m)
	machine_test_setup_irq0(&m.platform.pic, true)

	copy(m.vm.ram[0x18:], []u8{0x00, 0x05, 0x00, 0x00})
	copy(m.vm.ram[0x20:], []u8{0x20, 0x05, 0x00, 0x00})
	copy(m.vm.ram[0x500:], []u8{0xFE, 0x06, 0x40, 0x05, 0xCF})
	copy(m.vm.ram[0x520:], []u8{
		0xFE, 0x06, 0x41, 0x05,
		0xB0, 0x20,
		0xE6, 0x20,
		0xCF,
	})
	copy(m.vm.ram[0x7C00:], []u8{
		0x31, 0xC0,
		0x8E, 0xD8,
		0x8E, 0xD0,
		0xBC, 0x00, 0x70,
		0xFB,
		0xF4,
		0xF4,
	})
	hv.set_realmode_entry(&m.vm, 0, 0x7C00)

	if !testing.expect(t, step(m)) {return}
	if !testing.expect(t, m.cpu_halted) {return}

	pending_name := hv.WHV_REGISTER_NAME.PendingEvent
	pending: hv.WHV_REGISTER_VALUE
	pending.Reg128[0] = u64(1) | u64(6) << 16
	if !testing.expect(
		t,
		hv.WHvSetVirtualProcessorRegisters(m.vm.part, 0, &pending_name, 1, &pending) >= 0,
	) {
		return
	}
	pic_raise(&m.platform.pic, 0)
	pic_out(&m.platform.pic, 0x21, 0xFE)

	if !testing.expect(t, step(m)) {return}
	testing.expect_value(t, m.vm.ram[0x540], u8(1))
	testing.expect_value(t, m.vm.ram[0x541], u8(0))
	testing.expect(t, m.vm.irq_pending_event_deferrals > 0)

	for _ in 0 ..< 10 {
		if m.vm.ram[0x541] != 0 || !step(m) {break}
	}
	testing.expect_value(t, m.vm.ram[0x540], u8(1))
	testing.expect_value(t, m.vm.ram[0x541], u8(1))
	testing.expect_value(t, m.inj_count[0x08], u64(1))
}
