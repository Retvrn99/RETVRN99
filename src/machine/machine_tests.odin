// SPDX-License-Identifier: GPL-3.0-only
package machine

import disk "../disk"
import hv "../hv"
import video "../vga"
import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

machine_test_iso :: proc(t: ^testing.T) -> string {
	base, err := os.temp_directory(context.temp_allocator)
	testing.expect(t, err == nil)
	path, _ := filepath.join(
		{base, fmt.tprintf("retvrn99_machine_cd_%d.iso", time.now()._nsec)},
		context.temp_allocator,
	)
	data := make([]u8, 20 * disk.CDROM_SECTOR_SIZE, context.temp_allocator)
	pvd := data[16 * disk.CDROM_SECTOR_SIZE:][:disk.CDROM_SECTOR_SIZE]
	pvd[0] = 1
	copy(pvd[1:6], "CD001")
	pvd[6] = 1
	testing.expect(t, os.write_entire_file(path, data) == nil)
	return path
}

machine_test_bd :: proc(backing: ^[]u8) -> disk.Block_Device {
	return disk.Block_Device {
		ctx = backing,
		sector_count = u64(len(backing^) / 512),
		read = proc(ctx: rawptr, lba: u64, buf: []u8) -> bool {
			b := (^[]u8)(ctx)^
			off := int(lba) * 512
			if off + len(buf) > len(b) {return false}
			copy(buf, b[off:off + len(buf)])
			return true
		},
		write = proc(ctx: rawptr, lba: u64, buf: []u8) -> bool {
			b := (^[]u8)(ctx)^
			off := int(lba) * 512
			if off + len(buf) > len(b) {return false}
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
	if !testing.expect(t, ok) {return}
	testing.expect(t, m.governor.mode == .GSW_886)

	seen: u32 = 0
	h := Io_Handler {
		ctx = &seen,
		read = proc(ctx: rawptr, port: u16, size: u8) -> u32 {return (^u32)(ctx)^},
		write = proc(ctx: rawptr, port: u16, size: u8, v: u32) {(^u32)(ctx)^ = v},
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
	if !testing.expect(t, ok) {return}
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
		if !step(&m) {break}
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
	if !testing.expect(t, ok) {return}
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

	cctx := Cancel_Ctx {
		vm = &m.vm,
	}
	th := thread.create_and_start_with_poly_data(&cctx, proc(c: ^Cancel_Ctx) {
		for {
			time.sleep(100 * time.Millisecond)
			sync.lock(&c.mu)
			s := c.stop
			if !s {hv.cancel(c.vm)}
			sync.unlock(&c.mu)
			if s {return}
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
		if !step(&m) {break}
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
	defer {delete(m.vm.ram); m.vm.ram = nil}

	img := make([]u8, disk.FLOPPY_144_SIZE)
	defer delete(img)
	for i in 0 ..< 512 {img[i] = u8(i * 3 + 1)}
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
	for _ in 0 ..< 4 {_, _ = sense(&m)}

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
	for i in 0 ..< 7 {res[i] = u8(bus_io_read(&m.bus, 0x3F5, 1))}
	testing.expect_value(t, res[0] & 0xC0, u8(0x00))

	ok := true
	for i in 0 ..< 512 {
		if m.vm.ram[0x1000 + i] != img[i] {ok = false; break}
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
	defer {delete(m.vm.ram); m.vm.ram = nil}

	img := make([]u8, disk.FLOPPY_144_SIZE)
	defer delete(img)
	for i in 0 ..< len(img) {img[i] = u8(i * 13 >> 3)}
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
		for p in params {bus_io_write(&m.bus, 0x3F5, 1, u32(p))}
		res: [7]u8
		for i in 0 ..< 7 {res[i] = u8(bus_io_read(&m.bus, 0x3F5, 1))}
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
		if m.vm.ram[0x2000 + i] != img[off + i] {ok = false; break}
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

@(test)
test_machine_mount_cdrom_secondary_ide :: proc(t: ^testing.T) {
	m: Machine
	bus_init(&m.bus)
	defer bus_destroy(&m.bus)
	pic_setup(&m.pic)
	machine_init_atapi(&m)

	path := machine_test_iso(t)
	defer os.remove(path)
	testing.expect(t, machine_mount_cdrom(&m, path))
	defer machine_eject_cdrom(&m)

	bus_io_write(&m.bus, 0x176, 1, 0xA0)
	bus_io_write(&m.bus, 0x177, 1, 0xA1)
	status := bus_io_read(&m.bus, 0x177, 1)
	testing.expect_value(t, status & disk.ATAPI_STATUS_DRQ, u32(disk.ATAPI_STATUS_DRQ))
	testing.expect_value(t, bus_io_read(&m.bus, 0x170, 2), u32(0x85C0))
	testing.expect(t, m.pic.slave.irr & 0x80 != 0)
	testing.expect(t, !m.bus.frozen)

	machine_eject_cdrom(&m)
	testing.expect(t, !disk.cdrom_image_present(&m.atapi.image))
}

@(test)
test_machine_guest_reset_is_distinct_from_freeze :: proc(t: ^testing.T) {
	prior_logger := context.logger
	quiet_logger := log.create_console_logger(.Fatal, {.Level})
	context.logger = quiet_logger
	defer {
		context.logger = prior_logger
		log.destroy_console_logger(quiet_logger)
	}
	m: Machine
	i8042_init(&m.kbd, &m, nil, nil, machine_guest_reset)
	testing.expect(t, !machine_reset_requested(&m))
	i8042_out(&m.kbd, 0x64, 0xFE)
	testing.expect(t, machine_reset_requested(&m))
	testing.expect(t, m.bus.frozen)
}

@(test)
test_machine_a20_controller_updates_hypervisor_mapping :: proc(t: ^testing.T) {
	if !hv.available() {
		log.warn("WHPX not available")
		return
	}
	m: Machine
	if !testing.expect(t, machine_init(&m, 64 * 1024 * 1024)) {return}
	defer machine_destroy(&m)

	m.vm.ram[0x500] = 0x11
	m.vm.ram[0x100500] = 0x22
	copy(m.vm.ram[0x7C00:], []u8{0xB8, 0xFF, 0xFF, 0x8E, 0xD8, 0xA0, 0x10, 0x05, 0xF4})

	testing.expect(t, m.kbd.a20 && m.vm.a20_enabled)
	hv.set_realmode_entry(&m.vm, 0, 0x7C00)
	testing.expect(t, step(&m))
	testing.expect_value(t, u8(hv.reg_rax(&m.vm)), u8(0x22))

	bus_io_write(&m.bus, 0x92, 1, 0x00)
	testing.expect(t, !m.kbd.a20 && m.vm.a20_enabled && !m.vm.a20_requested)
	hv.set_realmode_entry(&m.vm, 0, 0x7C00)
	testing.expect(t, step(&m))
	testing.expect(t, !m.vm.a20_enabled && !m.vm.a20_requested)
	testing.expect_value(t, u8(hv.reg_rax(&m.vm)), u8(0x11))

	bus_io_write(&m.bus, 0x64, 1, 0xD1)
	bus_io_write(&m.bus, 0x60, 1, 0x03)
	testing.expect(t, m.kbd.a20 && !m.vm.a20_enabled && m.vm.a20_requested)
	hv.set_realmode_entry(&m.vm, 0, 0x7C00)
	testing.expect(t, step(&m))
	testing.expect(t, m.vm.a20_enabled && m.vm.a20_requested)
	testing.expect_value(t, u8(hv.reg_rax(&m.vm)), u8(0x22))
}

Machine_A20_Probe :: struct {
	values: [3]u8,
	count:  int,
}

Machine_A20_Stress_Probe :: struct {
	count: int,
	valid: bool,
}

@(test)
test_machine_guest_a20_toggle_invalidates_active_mapping :: proc(t: ^testing.T) {
	if !hv.available() {
		log.warn("WHPX not available")
		return
	}
	m: Machine
	if !testing.expect(t, machine_init(&m, 64 * 1024 * 1024)) {return}
	defer machine_destroy(&m)

	probe: Machine_A20_Probe
	bus_register(&m.bus, 0x99, 0x99, Io_Handler {
		ctx = &probe,
		read = proc(ctx: rawptr, port: u16, size: u8) -> u32 {return 0xFF},
		write = proc(ctx: rawptr, port: u16, size: u8, value: u32) {
			p := (^Machine_A20_Probe)(ctx)
			if p.count < len(p.values) {
				p.values[p.count] = u8(value)
				p.count += 1
			}
		},
	})
	m.vm.ram[0x500] = 0x11
	m.vm.ram[0x100500] = 0x22
	// Read HMA, disable A20, read its wrap alias, re-enable, then read HMA again.
	copy(
		m.vm.ram[0x7C00:],
		[]u8{
			0xB8, 0xFF, 0xFF, 0x8E, 0xD8, 0xA0, 0x10, 0x05, 0xE6, 0x99,
			0x30, 0xC0, 0xE6, 0x92, 0xA0, 0x10, 0x05, 0xE6, 0x99,
			0xB0, 0x02, 0xE6, 0x92, 0xA0, 0x10, 0x05, 0xE6, 0x99, 0xF4,
		},
	)
	hv.set_realmode_entry(&m.vm, 0, 0x7C00)
	testing.expect(t, step(&m))
	testing.expect_value(t, probe.count, 3)
	testing.expect_value(t, probe.values, [3]u8{0x22, 0x11, 0x22})
}

@(test)
test_machine_guest_a20_toggle_stress_preserves_memory :: proc(t: ^testing.T) {
	if !hv.available() {
		log.warn("WHPX not available")
		return
	}
	m: Machine
	if !testing.expect(t, machine_init(&m, 64 * 1024 * 1024)) {return}
	defer machine_destroy(&m)

	probe := Machine_A20_Stress_Probe{valid = true}
	bus_register(&m.bus, 0x99, 0x99, Io_Handler {
		ctx = &probe,
		read = proc(ctx: rawptr, port: u16, size: u8) -> u32 {return 0xFF},
		write = proc(ctx: rawptr, port: u16, size: u8, value: u32) {
			p := (^Machine_A20_Stress_Probe)(ctx)
			want := p.count & 1 == 0 ? u8(0x22) : u8(0x11)
			p.valid = p.valid && u8(value) == want
			p.count += 1
		},
	})
	m.vm.ram[0x20] = 0xA5
	m.vm.ram[0x500] = 0x11
	m.vm.ram[0x800] = 0x5A
	m.vm.ram[0x100500] = 0x22
	copy(
		m.vm.ram[0x7C00:],
		[]u8{
			0xB8, 0xFF, 0xFF, 0x8E, 0xD8, 0xB9, 0x00, 0x01,
			0xA0, 0x10, 0x05, 0xE6, 0x99, 0x30, 0xC0, 0xE6, 0x92,
			0xA0, 0x10, 0x05, 0xE6, 0x99, 0xB0, 0x02, 0xE6, 0x92,
			0xE2, 0xEC, 0xF4,
		},
	)
	hv.set_realmode_entry(&m.vm, 0, 0x7C00)
	for _ in 0 ..< 100 {
		if !step(&m) || probe.count == 512 {break}
	}
	testing.expect_value(t, probe.count, 512)
	testing.expect(t, probe.valid)
	testing.expect(t, m.kbd.a20 && m.vm.a20_enabled)
	testing.expect_value(t, m.vm.ram[0x20], u8(0xA5))
	testing.expect_value(t, m.vm.ram[0x800], u8(0x5A))
}

@(test)
test_machine_hypervisor_reset_exit_requests_warm_cpu_reset :: proc(t: ^testing.T) {
	prior_logger := context.logger
	quiet_logger := log.create_console_logger(.Fatal, {.Level})
	context.logger = quiet_logger
	defer {
		context.logger = prior_logger
		log.destroy_console_logger(quiet_logger)
	}
	m: Machine
	testing.expect(t, !machine_handle_exit(&m, hv.Exit{kind = .Reset, detail = "triple fault"}))
	testing.expect(t, !machine_reset_requested(&m))
	testing.expect(t, machine_cpu_reset_pending(&m))
	testing.expect_value(t, machine_cpu_reset_reason(&m), "triple fault")
	testing.expect(t, !m.bus.frozen)
}

@(test)
test_machine_ps2_mouse_routes_irq12 :: proc(t: ^testing.T) {
	m: Machine
	pic_setup(&m.pic)
	i8042_init(&m.kbd, &m, nil, machine_irq12)
	i8042_out(&m.kbd, 0x64, 0x60); i8042_out(&m.kbd, 0x60, 0x02)
	i8042_out(&m.kbd, 0x64, 0xD4); i8042_out(&m.kbd, 0x60, 0xF2)
	testing.expect(t, m.pic.slave.irr & 0x10 != 0)
	testing.expect(t, m.pic.master.irr & 0x04 != 0)
}

@(test)
test_machine_reset_control_requests_guest_reset :: proc(t: ^testing.T) {
	prior_logger := context.logger
	quiet_logger := log.create_console_logger(.Fatal, {.Level})
	context.logger = quiet_logger
	defer {
		context.logger = prior_logger
		log.destroy_console_logger(quiet_logger)
	}
	m: Machine
	machine_reset_control_write(&m, 0xCF9, 1, 0x02)
	testing.expect_value(t, machine_reset_control_read(&m, 0xCF9, 1), u32(0x02))
	testing.expect(t, !machine_reset_requested(&m))
	machine_reset_control_write(&m, 0xCF9, 1, 0x06)
	testing.expect(t, machine_reset_requested(&m))
	testing.expect(t, m.bus.frozen)
}

@(test)
test_machine_master_clock_controls_all_device_time :: proc(t: ^testing.T) {
	backing := make([]u8, video.VRAM_SIZE)
	defer delete(backing)
	m: Machine
	if !testing.expect(t, video.vga_init(&m.vga, backing)) {return}
	defer video.vga_destroy(&m.vga)
	machine_advance_time_ns(&m, 1_000)
	testing.expect_value(t, m.vga.timing.elapsed_ns, u64(1_000))
	testing.expect_value(t, master_timeline_now(m.timeline), u64(6_600))

	time.sleep(time.Millisecond)
	_ = machine_display_frame(&m)
	testing.expect_value(t, m.vga.timing.elapsed_ns, u64(1_000))

	machine_clock_set_running(&m, true)
	time.sleep(time.Millisecond)
	_ = machine_text_snapshot(&m)
	testing.expect(t, m.vga.timing.elapsed_ns > 1_000)
	machine_clock_set_running(&m, false)
	frozen_time := m.vga.timing.elapsed_ns
	time.sleep(time.Millisecond)
	_ = machine_text_snapshot(&m)
	testing.expect_value(t, m.vga.timing.elapsed_ns, frozen_time)
}
