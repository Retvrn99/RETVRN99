// SPDX-License-Identifier: GPL-3.0-only
package machine

import "core:log"
import "core:sync"
import "core:testing"
import "core:thread"
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
	ok := machine_init(&m, 64 * 1024 * 1024)
	defer machine_destroy(&m)
	if !testing.expect(t, ok) { return }

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
	ok := machine_init(&m, 64 * 1024 * 1024)
	defer machine_destroy(&m)
	if !testing.expect(t, ok) { return }
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

Cancel_Ctx :: struct {
	vm:   ^hv.Vm,
	stop: bool, // guarded by mu
	mu:   sync.Mutex,
}

// A guest that spins without exits (DOS int16 poll loop) only wakes on
// watchdog cancels ~100ms apart; the free-running PIT then has a tick
// pending at EVERY wake, and fixed 8259 priority would starve IRQ1 forever
// unless step() requests an interrupt window while more IRQs are pending.
@(test)
test_machine_irq_no_starvation :: proc(t: ^testing.T) {
	if !hv.available() {
		log.warn("WHPX not available")
		return
	}
	testing.set_fail_timeout(t, 30 * time.Second)
	m: Machine
	ok := machine_init(&m, 64 * 1024 * 1024)
	defer machine_destroy(&m)
	if !testing.expect(t, ok) { return }
	pic_setup(&m.pic)

	// IVT: vector 8 -> 0000:0500, vector 9 -> 0000:0520
	copy(m.vm.ram[0x20:], []u8{0x00, 0x05, 0x00, 0x00, 0x20, 0x05, 0x00, 0x00})
	// vec8 handler: EOI; iret
	copy(m.vm.ram[0x500:], []u8{0xB0, 0x20, 0xE6, 0x20, 0xCF})
	// vec9 handler: inc byte [0x510]; EOI; iret (marker proves delivery)
	copy(m.vm.ram[0x520:], []u8{0xFE, 0x06, 0x10, 0x05, 0xB0, 0x20, 0xE6, 0x20, 0xCF})
	// xor ax,ax; mov ds,ax; mov sp,0x7000; sti; spin: jmp spin
	copy(m.vm.ram[0x7C00:], []u8{0x31, 0xC0, 0x8E, 0xD8, 0xBC, 0x00, 0x70, 0xFB, 0xEB, 0xFE})
	hv.set_realmode_entry(&m.vm, 0, 0x7C00)

	cctx := Cancel_Ctx{vm = &m.vm}
	th := thread.create_and_start_with_poly_data(&cctx, proc(c: ^Cancel_Ctx) {
		for {
			time.sleep(100 * time.Millisecond)
			sync.lock(&c.mu)
			s := c.stop
			if !s { hv.cancel(c.vm) }
			sync.unlock(&c.mu)
			if s { return }
		}
	})
	defer {
		sync.lock(&cctx.mu)
		cctx.stop = true
		sync.unlock(&cctx.mu)
		thread.join(th)
	}

	pic_raise(&m.pic, 1)
	start := time.tick_now()
	delivered := false
	for time.duration_seconds(time.tick_since(start)) < 5 {
		if !step(&m) { break }
		if m.vm.ram[0x510] != 0 {
			delivered = true
			break
		}
	}
	testing.expect(t, delivered) // IRQ1 must not starve behind the PIT
	testing.expect(t, m.inj_count[0x08] > 0) // the timer really was competing
}

@(test)
test_machine_fdc_dma_read :: proc(t: ^testing.T) {
	// no WHPX needed: drives the FDC through the bus and the real 8237
	m: Machine
	bus_init(&m.bus)
	defer bus_destroy(&m.bus)
	pic_setup(&m.pic)
	machine_init_fdc(&m)
	m.vm.ram = make([]u8, 1024 * 1024)
	defer { delete(m.vm.ram); m.vm.ram = nil }

	img := make([]u8, disk.FLOPPY_144_SIZE)
	defer delete(img)
	for i in 0 ..< 512 { img[i] = u8(i * 3 + 1) }
	testing.expect(t, machine_mount_floppy(&m, img))
	defer machine_eject_floppy(&m)

	// DIR shows the media change from the mount
	testing.expect_value(t, bus_io_read(&m.bus, 0x3F7, 1), u32(0x80))

	// reset via DOR raises IRQ6 through machine glue
	bus_io_write(&m.bus, 0x3F2, 1, 0x08)
	bus_io_write(&m.bus, 0x3F2, 1, 0x1C)
	testing.expect(t, m.pic.master.irr & 0x40 != 0)

	sense :: proc(m: ^Machine) -> (st0, pcn: u8) {
		bus_io_write(&m.bus, 0x3F5, 1, 0x08)
		st0 = u8(bus_io_read(&m.bus, 0x3F5, 1))
		pcn = u8(bus_io_read(&m.bus, 0x3F5, 1))
		return
	}
	for _ in 0 ..< 4 { _, _ = sense(&m) }

	// RECALIBRATE then SENSE INTERRUPT: seek end at cylinder 0
	bus_io_write(&m.bus, 0x3F5, 1, 0x07)
	bus_io_write(&m.bus, 0x3F5, 1, 0x00)
	st0, pcn := sense(&m)
	testing.expect_value(t, st0, u8(0x20))
	testing.expect_value(t, pcn, u8(0x00))
	testing.expect_value(t, bus_io_read(&m.bus, 0x3F7, 1), u32(0x00)) // DSKCHG cleared

	// program DMA ch2: single mode, write to memory, 512 bytes at 0x1000
	dma_out(&m.dma, 0x0A, 0x06) // mask ch2
	dma_out(&m.dma, 0x0C, 0x00) // clear flip-flop
	dma_out(&m.dma, 0x0B, 0x46) // mode: single, write, ch2
	dma_out(&m.dma, 0x04, 0x00)
	dma_out(&m.dma, 0x04, 0x10) // addr 0x1000
	dma_out(&m.dma, 0x05, 0xFF)
	dma_out(&m.dma, 0x05, 0x01) // count 511 = 512 bytes
	dma_out(&m.dma, 0x81, 0x00) // page 0
	dma_out(&m.dma, 0x0A, 0x02) // unmask ch2

	// READ C0/H0/S1
	for b in ([]u8{0xE6, 0x00, 0, 0, 1, 2, 18, 0x1B, 0xFF}) {
		bus_io_write(&m.bus, 0x3F5, 1, u32(b))
	}
	testing.expect_value(t, bus_io_read(&m.bus, 0x3F4, 1), u32(0xD0))
	res: [7]u8
	for i in 0 ..< 7 { res[i] = u8(bus_io_read(&m.bus, 0x3F5, 1)) }
	testing.expect_value(t, res[0] & 0xC0, u8(0x00))

	ok := true
	for i in 0 ..< 512 {
		if m.vm.ram[0x1000 + i] != img[i] { ok = false; break }
	}
	testing.expect(t, ok)
	testing.expect_value(t, m.vm.ram[0x1000 + 512], u8(0)) // TC stopped the transfer
	testing.expect(t, !m.bus.frozen)
}

// Regression for the Win98 SE boot-disk stall: after the boot-sector read
// completes (TC), SeaBIOS reprograms DMA ch2 and issues the next READ without
// ever reading DMA status port 0x08. A sticky TC truncated every later
// multi-sector read to one sector while still reporting success.
@(test)
test_machine_fdc_dma_back_to_back :: proc(t: ^testing.T) {
	m: Machine
	bus_init(&m.bus)
	defer bus_destroy(&m.bus)
	pic_setup(&m.pic)
	machine_init_fdc(&m)
	m.vm.ram = make([]u8, 1024 * 1024)
	defer { delete(m.vm.ram); m.vm.ram = nil }

	img := make([]u8, disk.FLOPPY_144_SIZE)
	defer delete(img)
	for i in 0 ..< len(img) { img[i] = u8(i * 13 >> 3) }
	testing.expect(t, machine_mount_floppy(&m, img))
	defer machine_eject_floppy(&m)

	bus_io_write(&m.bus, 0x3F2, 1, 0x08)
	bus_io_write(&m.bus, 0x3F2, 1, 0x1C)
	for _ in 0 ..< 4 {
		bus_io_write(&m.bus, 0x3F5, 1, 0x08)
		_ = bus_io_read(&m.bus, 0x3F5, 1)
		_ = bus_io_read(&m.bus, 0x3F5, 1)
	}

	// programs ch2 the way SeaBIOS dma_floppy does, then runs one READ
	read :: proc(m: ^Machine, addr: u32, count: int, params: []u8) -> [7]u8 {
		dma_out(&m.dma, 0x0A, 0x06)
		dma_out(&m.dma, 0x0C, 0x00)
		dma_out(&m.dma, 0x04, u8(addr))
		dma_out(&m.dma, 0x04, u8(addr >> 8))
		dma_out(&m.dma, 0x0C, 0x00)
		dma_out(&m.dma, 0x05, u8(count - 1))
		dma_out(&m.dma, 0x05, u8((count - 1) >> 8))
		dma_out(&m.dma, 0x0B, 0x46)
		dma_out(&m.dma, 0x81, u8(addr >> 16))
		dma_out(&m.dma, 0x0A, 0x02)
		bus_io_write(&m.bus, 0x3F5, 1, 0xE6)
		for p in params { bus_io_write(&m.bus, 0x3F5, 1, u32(p)) }
		res: [7]u8
		for i in 0 ..< 7 { res[i] = u8(bus_io_read(&m.bus, 0x3F5, 1)) }
		return res
	}

	// boot sector, then the IO.SYS full-track read from the stall trace
	r1 := read(&m, 0x1000, 512, []u8{0x00, 0, 0, 1, 2, 1, 0x1B, 0xFF})
	testing.expect_value(t, r1[0] & 0xC0, u8(0x00))
	r2 := read(&m, 0x2000, 18 * 512, []u8{0x04, 50, 1, 1, 2, 18, 0x1B, 0xFF})
	testing.expect_value(t, r2[0] & 0xC0, u8(0x00))

	off, _ := disk.floppy_img_offset(50, 1, 1)
	ok := true
	for i in 0 ..< 18 * 512 {
		if m.vm.ram[0x2000 + i] != img[off + i] { ok = false; break }
	}
	testing.expect(t, ok)
	testing.expect(t, !m.bus.frozen)
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
