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
	machine_test_setup_irq0(&m.pic, true)

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
	bus_register(&m.bus, 0x99, 0x99, Io_Handler{
		ctx = &seen,
		write = proc(ctx: rawptr, port: u16, size: u8, value: u32) {(^u32)(ctx)^ = value},
	})
	pit_out(&m.pit, 0x43, 0x34)
	pit_out(&m.pit, 0x40, 0x9C)
	pit_out(&m.pit, 0x40, 0x2E)
	hv.set_realmode_entry(&m.vm, 0, 0x7C00)

	if !testing.expect(t, step(m)) {return}
	testing.expect(t, m.cpu_halted)
	testing.expect_value(t, seen, u32(0))
	machine_advance_time_ns(m, 20_000_000)
	testing.expect(t, m.pic.master.irr & 0x01 != 0)
	if !testing.expect(t, step(m)) {return}
	testing.expect(t, m.cpu_halted)
	testing.expect_value(t, seen, u32(0))

	pic_out(&m.pic, 0x21, 0xFE)
	for _ in 0 ..< 10 {
		if !step(m) || seen == 0x42 {break}
	}
	testing.expect_value(t, seen, u32(0x42))
}
