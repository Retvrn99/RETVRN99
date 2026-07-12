// SPDX-License-Identifier: GPL-3.0-only
package machine

import "core:log"
import "core:testing"
import "core:time"
import disk "../disk"
import hv "../hv"

machine_test_bd :: proc(backing: ^[]u8) -> disk.Block_Device {
	return disk.Block_Device{
		ctx = backing,
		sector_count = u64(len(backing^) / 512),
		read = proc(ctx: rawptr, lba: u64, buf: []u8) -> bool {
			b := (^[]u8)(ctx)^
			off := int(lba) * 512
			if off + len(buf) > len(b) { return false }
			copy(buf, b[off:off + len(buf)])
			return true
		},
		write = proc(ctx: rawptr, lba: u64, buf: []u8) -> bool {
			b := (^[]u8)(ctx)^
			off := int(lba) * 512
			if off + len(buf) > len(b) { return false }
			copy(b[off:off + len(buf)], buf)
			return true
		},
	}
}

@(test)
test_machine_port_echo :: proc(t: ^testing.T) {
	if !hv.available() {
		log.warn("WHPX not available")
		return
	}
	testing.set_fail_timeout(t, 10 * time.Second)
	m: Machine
	testing.expect(t, machine_init(&m, 64 * 1024 * 1024))
	defer machine_destroy(&m)

	seen: u32 = 0
	h := Io_Handler{
		ctx = &seen,
		read = proc(ctx: rawptr, port: u16, size: u8) -> u32 { return (^u32)(ctx)^ },
		write = proc(ctx: rawptr, port: u16, size: u8, v: u32) { (^u32)(ctx)^ = v },
	}
	bus_register(&m.bus, 0x99, 0x99, h)

	// mov al, 0x42; out 0x99, al; hlt
	copy(m.vm.ram[0x7C00:], []u8{0xB0, 0x42, 0xE6, 0x99, 0xF4})
	hv.set_realmode_entry(&m.vm, 0, 0x7C00)

	testing.expect(t, step(&m))
	testing.expect_value(t, seen, u32(0x42))
	// reaching HLT past the OUT means the emulator advanced RIP
	testing.expect(t, !m.bus.frozen)
}

@(test)
test_machine_irq_delivery :: proc(t: ^testing.T) {
	if !hv.available() {
		log.warn("WHPX not available")
		return
	}
	testing.set_fail_timeout(t, 10 * time.Second)
	m: Machine
	testing.expect(t, machine_init(&m, 64 * 1024 * 1024))
	defer machine_destroy(&m)
	pic_setup(&m.pic) // master base 0x08, everything unmasked

	// IVT vector 8 -> 0000:0500
	copy(m.vm.ram[0x20:], []u8{0x00, 0x05, 0x00, 0x00})
	// handler: inc byte [0x0510]; iret  (marker proves delivery via the IVT)
	copy(m.vm.ram[0x500:], []u8{0xFE, 0x06, 0x10, 0x05, 0xCF})
	// mov sp, 0x7000; sti; hlt; mov ax, 0xBEEF; hlt
	copy(m.vm.ram[0x7C00:], []u8{0xBC, 0x00, 0x70, 0xFB, 0xF4, 0xB8, 0xEF, 0xBE, 0xF4})
	hv.set_realmode_entry(&m.vm, 0, 0x7C00)

	pic_raise(&m.pic, 0)
	delivered := false
	for _ in 0 ..< 100 {
		if !step(&m) { break }
		if m.vm.ram[0x510] != 0 && u16(hv.reg_rax(&m.vm)) == 0xBEEF {
			delivered = true
			break
		}
	}
	testing.expect(t, delivered)
	testing.expect_value(t, m.vm.ram[0x510], u8(1))
	testing.expect(t, m.pic.master.isr & 0x01 != 0) // IRQ0 acked, in service
}

@(test)
test_machine_attach_disk :: proc(t: ^testing.T) {
	// no WHPX needed: drives the IDE through the bus directly
	m: Machine
	bus_init(&m.bus)
	defer bus_destroy(&m.bus)
	pic_setup(&m.pic)
	backing := make([]u8, 1024 * 1024)
	defer delete(backing)
	machine_attach_disk(&m, machine_test_bd(&backing))

	// IDENTIFY via the port protocol
	bus_io_write(&m.bus, 0x1F6, 1, 0xE0)
	bus_io_write(&m.bus, 0x1F7, 1, 0xEC)
	st := bus_io_read(&m.bus, 0x1F7, 1)
	testing.expect_value(t, st & 0x08, u32(0x08)) // DRQ
	w0 := bus_io_read(&m.bus, 0x1F0, 2)
	testing.expect_value(t, w0, u32(0x0040))
	testing.expect(t, m.pic.slave.irr & 0x40 != 0) // IRQ14 through machine glue
	testing.expect(t, !m.bus.frozen)
}
