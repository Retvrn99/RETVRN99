// SPDX-License-Identifier: GPL-3.0-only
package machine

import disk "../disk"
import hv "../hv"
import contract "../presentation"
import video "../vga"
import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
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

machine_test_run_fdc :: proc(m: ^Machine) {
	for {
		deadline, pending := disk.fdc_next_deadline(&m.fdc)
		if !pending {return}
		disk.fdc_advance_to(&m.fdc, deadline)
	}
}

Machine_String_IO_Wake_Probe :: struct {
	rearms:         int,
	run_guards:     int,
	disarms:        int,
	last_delay_ns:  u64,
	last_mode:      Wake_Schedule_Mode,
	generation:     u64,
	fail_run_guard: bool,
}

machine_test_string_io_rearm :: proc(
	ctx: rawptr,
	delay_ns: u64,
	mode: Wake_Schedule_Mode,
	generation: u64,
) -> bool {
	probe := (^Machine_String_IO_Wake_Probe)(ctx)
	probe.last_delay_ns = delay_ns
	probe.last_mode = mode
	probe.generation = generation
	switch mode {
	case .One_Shot:
		probe.rearms += 1
	case .Run_Guard:
		probe.run_guards += 1
	case .Disarm:
		probe.disarms += 1
	}
	return mode != .Run_Guard || !probe.fail_run_guard
}

@(test)
test_machine_failed_initialization_cleans_resources_and_destroy_is_idempotent :: proc(
	t: ^testing.T,
) {
	if !hv.available() {
		log.warn("WHPX not available")
		return
	}
	m := new(Machine)
	defer free(m)
	testing.expect(t, !machine_init(m, 512 * 1024))
	testing.expect(t, m.vm.part == nil)
	testing.expect_value(t, len(m.vm.ram), 0)
	testing.expect_value(t, len(m.vm.device_mappings), 0)
	testing.expect_value(t, len(m.platform.bus.io), 0)
	testing.expect_value(t, len(m.platform.bus.passive), 0)
	testing.expect_value(t, len(m.vga.frame_pixels), 0)
	testing.expect_value(t, m.governor.host_hz, u64(0))
	machine_destroy(m)
	machine_destroy(m)
	testing.expect(t, m.vm.part == nil)
	testing.expect_value(t, len(m.platform.bus.io), 0)
}

@(test)
test_machine_hypervisor_create_failure_cleans_bus_and_destroy_is_idempotent :: proc(
	t: ^testing.T,
) {
	if !hv.available() {
		log.warn("WHPX not available")
		return
	}
	m := new(Machine)
	defer free(m)
	testing.expect(t, !machine_init(m, max(int)))
	testing.expect(t, m.vm.part == nil)
	testing.expect_value(t, len(m.vm.ram), 0)
	testing.expect_value(t, len(m.platform.bus.io), 0)
	testing.expect_value(t, len(m.platform.bus.passive), 0)
	machine_destroy(m)
	machine_destroy(m)
	testing.expect(t, m.vm.part == nil)
	testing.expect_value(t, len(m.platform.bus.io), 0)
}

@(test)
test_machine_port_echo :: proc(t: ^testing.T) {
	if !hv.available() {
		log.warn("WHPX not available")
		return
	}
	testing.set_fail_timeout(t, 10 * time.Second)
	m := new(Machine)
	defer free(m)
	ok := machine_init(m, 64 * 1024 * 1024)
	defer machine_destroy(m)
	if !testing.expect(t, ok) {return}
	testing.expect(t, m.governor.mode == .GSW_886)

	seen: u32 = 0
	h := Io_Handler {
		ctx = &seen,
		read = proc(ctx: rawptr, port: u16, size: u8) -> u32 {return (^u32)(ctx)^},
		write = proc(ctx: rawptr, port: u16, size: u8, v: u32) {(^u32)(ctx)^ = v},
	}
	bus_register(&m.platform.bus, 0x99, 0x99, h)

	// mov al, 0x42; out 0x99, al; hlt
	copy(m.vm.ram[0x7C00:], []u8{0xB0, 0x42, 0xE6, 0x99, 0xF4})
	hv.set_realmode_entry(&m.vm, 0, 0x7C00)

	testing.expect(t, step(m))
	testing.expect_value(t, seen, u32(0x42))
	// reaching HLT past the OUT means the emulator advanced RIP
	testing.expect(t, !m.platform.bus.frozen)
}

@(test)
test_machine_irq_delivery :: proc(t: ^testing.T) {
	if !hv.available() {
		log.warn("WHPX not available")
		return
	}
	testing.set_fail_timeout(t, 10 * time.Second)
	m := new(Machine)
	defer free(m)
	ok := machine_init(m, 64 * 1024 * 1024)
	defer machine_destroy(m)
	if !testing.expect(t, ok) {return}
	pic_setup(&m.platform.pic) // master base 0x08, everything unmasked

	// IVT vector 8 -> 0000:0500
	copy(m.vm.ram[0x20:], []u8{0x00, 0x05, 0x00, 0x00})
	// handler: inc byte [0x0510]; iret  (marker proves delivery via the IVT)
	copy(m.vm.ram[0x500:], []u8{0xFE, 0x06, 0x10, 0x05, 0xCF})
	// mov sp, 0x7000; sti; hlt; mov ax, 0xBEEF; hlt
	copy(m.vm.ram[0x7C00:], []u8{0xBC, 0x00, 0x70, 0xFB, 0xF4, 0xB8, 0xEF, 0xBE, 0xF4})
	hv.set_realmode_entry(&m.vm, 0, 0x7C00)

	pic_raise(&m.platform.pic, 0)
	delivered := false
	for _ in 0 ..< 100 {
		if !step(m) {break}
		if m.vm.ram[0x510] != 0 && u16(hv.reg_rax(&m.vm)) == 0xBEEF {
			delivered = true
			break
		}
	}
	testing.expect(t, delivered)
	testing.expect_value(t, m.vm.ram[0x510], u8(1))
	testing.expect(t, m.platform.pic.master.isr & 0x01 != 0) // IRQ0 acked, in service
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
	m := new(Machine)
	defer free(m)
	ok := machine_init(m, 64 * 1024 * 1024)
	defer machine_destroy(m)
	if !testing.expect(t, ok) {return}
	pic_setup(&m.platform.pic)

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
		thread.destroy(th)
	}

	pit_out(&m.platform.pit, 0x43, 0x36)
	pit_out(&m.platform.pit, 0x40, 0xE8)
	pit_out(&m.platform.pit, 0x40, 0x03)
	machine_advance_time_ns(m, 1_000_000)
	pic_raise(&m.platform.pic, 1)
	start := time.tick_now()
	delivered := false
	for time.duration_seconds(time.tick_since(start)) < 5 {
		if !step(m) {break}
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
	m := new(Machine)
	defer free(m)
	bus_init(&m.platform.bus)
	defer bus_destroy(&m.platform.bus)
	pic_setup(&m.platform.pic)
	machine_init_fdc(m)
	m.vm.ram = make([]u8, 1024 * 1024)
	defer {delete(m.vm.ram); m.vm.ram = nil}

	img := make([]u8, disk.FLOPPY_144_SIZE)
	defer delete(img)
	for i in 0 ..< 512 {img[i] = u8(i * 3 + 1)}
	testing.expect(t, machine_mount_floppy(m, img))
	defer machine_eject_floppy(m)

	// DIR shows the media change from the mount
	testing.expect_value(t, bus_io_read(&m.platform.bus, 0x3F7, 1), u32(0x80))

	// reset via DOR raises IRQ6 through machine glue
	bus_io_write(&m.platform.bus, 0x3F2, 1, 0x08)
	bus_io_write(&m.platform.bus, 0x3F2, 1, 0x1C)
	testing.expect(t, m.platform.pic.master.irr & 0x40 != 0)

	sense :: proc(m: ^Machine) -> (st0, pcn: u8) {
		bus_io_write(&m.platform.bus, 0x3F5, 1, 0x08)
		st0 = u8(bus_io_read(&m.platform.bus, 0x3F5, 1))
		pcn = u8(bus_io_read(&m.platform.bus, 0x3F5, 1))
		return
	}
	for _ in 0 ..< 4 {_, _ = sense(m)}

	// RECALIBRATE then SENSE INTERRUPT: seek end at cylinder 0
	bus_io_write(&m.platform.bus, 0x3F5, 1, 0x07)
	bus_io_write(&m.platform.bus, 0x3F5, 1, 0x00)
	st0, pcn := sense(m)
	testing.expect_value(t, st0, u8(0x20))
	testing.expect_value(t, pcn, u8(0x00))
	testing.expect_value(t, bus_io_read(&m.platform.bus, 0x3F7, 1), u32(0x00)) // DSKCHG cleared

	// program DMA ch2: single mode, write to memory, 512 bytes at 0x1000
	dma_out(&m.platform.dma, 0xD6, 0xC0) // channel 4 cascades the 8-bit controller
	dma_out(&m.platform.dma, 0xD4, 0x00)
	dma_out(&m.platform.dma, 0x0A, 0x06) // mask ch2
	dma_out(&m.platform.dma, 0x0C, 0x00) // clear flip-flop
	dma_out(&m.platform.dma, 0x0B, 0x46) // mode: single, write, ch2
	dma_out(&m.platform.dma, 0x04, 0x00)
	dma_out(&m.platform.dma, 0x04, 0x10) // addr 0x1000
	dma_out(&m.platform.dma, 0x05, 0xFF)
	dma_out(&m.platform.dma, 0x05, 0x01) // count 511 = 512 bytes
	dma_out(&m.platform.dma, 0x81, 0x00) // page 0
	dma_out(&m.platform.dma, 0x0A, 0x02) // unmask ch2

	// READ C0/H0/S1
	for b in ([]u8{0xE6, 0x00, 0, 0, 1, 2, 18, 0x1B, 0xFF}) {
		bus_io_write(&m.platform.bus, 0x3F5, 1, u32(b))
	}
	machine_test_run_fdc(m)
	testing.expect_value(t, bus_io_read(&m.platform.bus, 0x3F4, 1), u32(0xD0))
	res: [7]u8
	for i in 0 ..< 7 {res[i] = u8(bus_io_read(&m.platform.bus, 0x3F5, 1))}
	testing.expect_value(t, res[0] & 0xC0, u8(0x00))

	ok := true
	for i in 0 ..< 512 {
		if m.vm.ram[0x1000 + i] != img[i] {ok = false; break}
	}
	testing.expect(t, ok)
	testing.expect_value(t, m.vm.ram[0x1000 + 512], u8(0)) // TC stopped the transfer
	testing.expect(t, !m.platform.bus.frozen)
}

// Regression for the Win98 SE boot-disk stall: after the boot-sector read
// completes (TC), SeaBIOS reprograms DMA ch2 and issues the next READ without
// ever reading DMA status port 0x08. A sticky TC truncated every later
// multi-sector read to one sector while still reporting success.
@(test)
test_machine_fdc_dma_back_to_back :: proc(t: ^testing.T) {
	m := new(Machine)
	defer free(m)
	bus_init(&m.platform.bus)
	defer bus_destroy(&m.platform.bus)
	pic_setup(&m.platform.pic)
	machine_init_fdc(m)
	m.vm.ram = make([]u8, 1024 * 1024)
	defer {delete(m.vm.ram); m.vm.ram = nil}

	img := make([]u8, disk.FLOPPY_144_SIZE)
	defer delete(img)
	for i in 0 ..< len(img) {img[i] = u8(i * 13 >> 3)}
	testing.expect(t, machine_mount_floppy(m, img))
	defer machine_eject_floppy(m)

	bus_io_write(&m.platform.bus, 0x3F2, 1, 0x08)
	bus_io_write(&m.platform.bus, 0x3F2, 1, 0x1C)
	for _ in 0 ..< 4 {
		bus_io_write(&m.platform.bus, 0x3F5, 1, 0x08)
		_ = bus_io_read(&m.platform.bus, 0x3F5, 1)
		_ = bus_io_read(&m.platform.bus, 0x3F5, 1)
	}
	dma_out(&m.platform.dma, 0xD6, 0xC0)
	dma_out(&m.platform.dma, 0xD4, 0x00)

	// programs ch2 the way SeaBIOS dma_floppy does, then runs one READ
	read :: proc(m: ^Machine, addr: u32, count: int, params: []u8) -> [7]u8 {
		dma_out(&m.platform.dma, 0x0A, 0x06)
		dma_out(&m.platform.dma, 0x0C, 0x00)
		dma_out(&m.platform.dma, 0x04, u8(addr))
		dma_out(&m.platform.dma, 0x04, u8(addr >> 8))
		dma_out(&m.platform.dma, 0x0C, 0x00)
		dma_out(&m.platform.dma, 0x05, u8(count - 1))
		dma_out(&m.platform.dma, 0x05, u8((count - 1) >> 8))
		dma_out(&m.platform.dma, 0x0B, 0x46)
		dma_out(&m.platform.dma, 0x81, u8(addr >> 16))
		dma_out(&m.platform.dma, 0x0A, 0x02)
		bus_io_write(&m.platform.bus, 0x3F5, 1, 0xE6)
		for p in params {bus_io_write(&m.platform.bus, 0x3F5, 1, u32(p))}
		machine_test_run_fdc(m)
		res: [7]u8
		for i in 0 ..< 7 {res[i] = u8(bus_io_read(&m.platform.bus, 0x3F5, 1))}
		return res
	}

	// boot sector, then the IO.SYS full-track read from the stall trace
	r1 := read(m, 0x1000, 512, []u8{0x00, 0, 0, 1, 2, 1, 0x1B, 0xFF})
	testing.expect_value(t, r1[0] & 0xC0, u8(0x00))
	r2 := read(m, 0x2000, 18 * 512, []u8{0x04, 50, 1, 1, 2, 18, 0x1B, 0xFF})
	testing.expect_value(t, r2[0] & 0xC0, u8(0x00))

	off, _ := disk.floppy_img_offset(50, 1, 1)
	ok := true
	for i in 0 ..< 18 * 512 {
		if m.vm.ram[0x2000 + i] != img[off + i] {ok = false; break}
	}
	testing.expect(t, ok)
	testing.expect(t, !m.platform.bus.frozen)
}

@(test)
test_machine_attach_disk :: proc(t: ^testing.T) {
	// no WHPX needed: drives the IDE through the bus directly
	m := new(Machine)
	defer free(m)
	bus_init(&m.platform.bus)
	defer bus_destroy(&m.platform.bus)
	pic_setup(&m.platform.pic)
	pci_init(&m.pci)
	pci_out(&m.pci, 0xCF8, 4, 0x8000_3940)
	pci_out(&m.pci, 0xCFC, 1, u32(AMD756_IDE_PRIMARY_CHANNEL_ENABLE))
	pci_out(&m.pci, 0xCF8, 4, 0x8000_3904)
	pci_out(&m.pci, 0xCFC, 2, 0x0001)
	backing := make([]u8, 1024 * 1024)
	defer delete(backing)
	machine_attach_disk(m, machine_test_bd(&backing))

	// IDENTIFY via the port protocol
	bus_io_write(&m.platform.bus, 0x1F6, 1, 0xE0)
	bus_io_write(&m.platform.bus, 0x1F7, 1, 0xEC)
	st := bus_io_read(&m.platform.bus, 0x1F7, 1)
	testing.expect_value(t, st, u32(disk.IDE_STATUS_BSY))
	deadline, pending := disk.ide_next_deadline(&m.ide)
	testing.expect(t, pending)
	disk.ide_advance_to(&m.ide, deadline)
	st = bus_io_read(&m.platform.bus, 0x1F7, 1)
	testing.expect_value(t, st & 0x08, u32(0x08)) // DRQ
	w0 := bus_io_read(&m.platform.bus, 0x1F0, 2)
	testing.expect_value(t, w0, u32(0x0040))
	testing.expect(t, m.platform.pic.slave.irr & 0x40 != 0) // IRQ14 through machine glue
	testing.expect(t, !m.platform.bus.frozen)
}

@(test)
test_machine_mount_cdrom_secondary_ide :: proc(t: ^testing.T) {
	m := new(Machine)
	defer free(m)
	bus_init(&m.platform.bus)
	defer bus_destroy(&m.platform.bus)
	pic_setup(&m.platform.pic)
	pci_init(&m.pci)
	pci_connect_pic(&m.pci, &m.platform.pic)
	machine_init_atapi(m)
	m.pci.functions[PCI_IDE_FUNCTION_INDEX].cfg[0x04] = 1
	m.pci.functions[PCI_IDE_FUNCTION_INDEX].cfg[0x40] |=
		AMD756_IDE_PRIMARY_CHANNEL_ENABLE | AMD756_IDE_SECONDARY_CHANNEL_ENABLE
	testing.expect(t, machine_sync_pci_devices(m))

	path := machine_test_iso(t)
	defer os.remove(path)
	testing.expect(t, machine_mount_cdrom(m, path))
	defer machine_eject_cdrom(m)

	bus_io_write(&m.platform.bus, 0x176, 1, 0xA0)
	bus_io_write(&m.platform.bus, 0x177, 1, 0xA1)
	status := bus_io_read(&m.platform.bus, 0x177, 1)
	testing.expect_value(t, status & disk.ATAPI_STATUS_DRQ, u32(disk.ATAPI_STATUS_DRQ))
	testing.expect_value(t, bus_io_read(&m.platform.bus, 0x170, 2), u32(0x85C0))
	testing.expect(t, m.platform.pic.slave.irr & 0x80 != 0)
	testing.expect(t, !m.platform.bus.frozen)

	machine_eject_cdrom(m)
	testing.expect(t, !disk.disc_image_present(&m.atapi.image))
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
	m := new(Machine)
	defer free(m)
	i8042_init(&m.platform.kbd, m, nil, nil, machine_guest_reset)
	testing.expect(t, !machine_reset_requested(m))
	i8042_out(&m.platform.kbd, 0x64, 0xFE)
	testing.expect(t, !machine_reset_requested(m))
	i8042_advance(&m.platform.kbd, I8042_CONTROLLER_INPUT_NS)
	testing.expect(t, machine_reset_requested(m))
	testing.expect_value(t, machine_reset_provenance(m), Reset_Provenance.Kbc_Controller_Pulse)
	record, recorded := machine_reset_record(m, 0)
	testing.expect(t, recorded)
	testing.expect_value(t, record.source, Reset_Provenance.Kbc_Controller_Pulse)
	testing.expect(t, !m.platform.bus.frozen)
	testing.expect_value(
		t,
		machine_reset_reason(m),
		"guest requested hardware reset (i8042 pulse)",
	)
}

@(test)
test_machine_a20_controller_updates_hypervisor_mapping :: proc(t: ^testing.T) {
	if !hv.available() {
		log.warn("WHPX not available")
		return
	}
	m := new(Machine)
	defer free(m)
	if !testing.expect(t, machine_init(m, 64 * 1024 * 1024)) {return}
	defer machine_destroy(m)

	m.vm.ram[0x500] = 0x11
	m.vm.ram[0x100500] = 0x22
	copy(m.vm.ram[0x7C00:], []u8{0xB8, 0xFF, 0xFF, 0x8E, 0xD8, 0xA0, 0x10, 0x05, 0xF4})

	testing.expect(t, m.platform.kbd.a20 && !m.platform.kbd.a20_kbc && m.platform.kbd.a20_fast && m.vm.a20_enabled)
	hv.set_realmode_entry(&m.vm, 0, 0x7C00)
	testing.expect(t, step(m))
	testing.expect_value(t, u8(hv.reg_rax(&m.vm)), u8(0x22))

	bus_io_write(&m.platform.bus, 0x92, 1, 0x00)
	testing.expect(
		t,
		!m.platform.kbd.a20 && !m.platform.kbd.a20_kbc && !m.platform.kbd.a20_fast && m.vm.a20_enabled && !m.vm.a20_requested,
	)
	hv.set_realmode_entry(&m.vm, 0, 0x7C00)
	m.cpu_halted = false
	testing.expect(t, step(m))
	testing.expect(t, !m.vm.a20_enabled && !m.vm.a20_requested)
	testing.expect_value(t, u8(hv.reg_rax(&m.vm)), u8(0x11))

	bus_io_write(&m.platform.bus, 0x64, 1, 0xD1)
	i8042_advance(&m.platform.kbd, I8042_CONTROLLER_INPUT_NS)
	bus_io_write(&m.platform.bus, 0x60, 1, 0x03)
	i8042_advance(&m.platform.kbd, I8042_CONTROLLER_INPUT_NS)
	testing.expect(
		t,
		m.platform.kbd.a20 && m.platform.kbd.a20_kbc && !m.platform.kbd.a20_fast && !m.vm.a20_enabled && m.vm.a20_requested,
	)
	hv.set_realmode_entry(&m.vm, 0, 0x7C00)
	m.cpu_halted = false
	testing.expect(t, step(m))
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
	m := new(Machine)
	defer free(m)
	if !testing.expect(t, machine_init(m, 64 * 1024 * 1024)) {return}
	defer machine_destroy(m)

	probe: Machine_A20_Probe
	bus_register(&m.platform.bus, 0x99, 0x99, Io_Handler {
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
		[]u8 {
			0xB8,
			0xFF,
			0xFF,
			0x8E,
			0xD8,
			0xA0,
			0x10,
			0x05,
			0xE6,
			0x99,
			0x30,
			0xC0,
			0xE6,
			0x92,
			0xA0,
			0x10,
			0x05,
			0xE6,
			0x99,
			0xB0,
			0x02,
			0xE6,
			0x92,
			0xA0,
			0x10,
			0x05,
			0xE6,
			0x99,
			0xF4,
		},
	)
	hv.set_realmode_entry(&m.vm, 0, 0x7C00)
	testing.expect(t, step(m))
	testing.expect_value(t, probe.count, 3)
	testing.expect_value(t, probe.values, [3]u8{0x22, 0x11, 0x22})
}

@(test)
test_machine_guest_a20_toggle_stress_preserves_memory :: proc(t: ^testing.T) {
	if !hv.available() {
		log.warn("WHPX not available")
		return
	}
	m := new(Machine)
	defer free(m)
	if !testing.expect(t, machine_init(m, 256 * 1024 * 1024)) {return}
	defer machine_destroy(m)

	probe := Machine_A20_Stress_Probe {
		valid = true,
	}
	bus_register(&m.platform.bus, 0x99, 0x99, Io_Handler {
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
		[]u8 {
			0xB8,
			0xFF,
			0xFF,
			0x8E,
			0xD8,
			0xB9,
			0x00,
			0x01,
			0xA0,
			0x10,
			0x05,
			0xE6,
			0x99,
			0x30,
			0xC0,
			0xE6,
			0x92,
			0xA0,
			0x10,
			0x05,
			0xE6,
			0x99,
			0xB0,
			0x02,
			0xE6,
			0x92,
			0xE2,
			0xEC,
			0xF4,
		},
	)
	hv.set_realmode_entry(&m.vm, 0, 0x7C00)
	for _ in 0 ..< 100 {
		if !step(m) || probe.count == 512 {break}
	}
	testing.expect_value(t, probe.count, 512)
	testing.expect(t, probe.valid)
	testing.expect(t, m.platform.kbd.a20 && m.vm.a20_enabled)
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
	m := new(Machine)
	defer free(m)
	testing.expect(t, !machine_handle_exit(m, hv.Exit{kind = .Reset, detail = "triple fault"}))
	testing.expect(t, !machine_reset_requested(m))
	testing.expect(t, machine_cpu_reset_pending(m))
	testing.expect_value(t, machine_cpu_reset_reason(m), "triple fault")
	testing.expect(t, !m.platform.bus.frozen)
}

@(test)
test_machine_ps2_mouse_routes_irq12 :: proc(t: ^testing.T) {
	m := new(Machine)
	defer free(m)
	pic_setup(&m.platform.pic)
	i8042_init(&m.platform.kbd, m, nil, machine_irq12)
	i8042_out(&m.platform.kbd, 0x64, 0x60)
	i8042_advance(&m.platform.kbd, I8042_CONTROLLER_INPUT_NS)
	i8042_out(&m.platform.kbd, 0x60, 0x02)
	i8042_advance(&m.platform.kbd, I8042_CONTROLLER_INPUT_NS)
	i8042_out(&m.platform.kbd, 0x64, 0xD4)
	i8042_advance(&m.platform.kbd, I8042_CONTROLLER_INPUT_NS)
	i8042_out(&m.platform.kbd, 0x60, 0xF2)
	i8042_advance(&m.platform.kbd, I8042_CONTROLLER_INPUT_NS + I8042_DEVICE_BYTE_NS)
	testing.expect(t, m.platform.pic.slave.irr & 0x10 != 0)
	testing.expect(t, m.platform.pic.master.irr & 0x04 != 0)
}

@(test)
test_machine_scheduled_host_key_rearms_headless_device_deadline :: proc(t: ^testing.T) {
	if !hv.available() {
		log.warn("WHPX not available")
		return
	}
	testing.set_fail_timeout(t, 10 * time.Second)
	m := new(Machine)
	defer free(m)
	if !testing.expect(t, machine_init(m, 64 * 1024 * 1024)) {return}
	defer machine_destroy(m)

	keys := [2]u8{0x1C, 0x9C}
	testing.expect(t, machine_key_sequence(m, keys[:]))
	position := m.scheduler.positions[int(Scheduled_Device.I8042)]
	testing.expect(t, position >= 0)
	if position >= 0 {
		testing.expect_value(t, m.scheduler.heap[position].device, Scheduled_Device.I8042)
		testing.expect(t, m.scheduler.heap[position].deadline > master_timeline_now(m.timeline))
	}
	time.sleep(20 * time.Millisecond)
	machine_sync_time(m)
	diagnostic := i8042_diagnostics(&m.platform.kbd)
	testing.expect_value(t, diagnostic.scheduled_key_bytes, 0)
	testing.expect(t, diagnostic.output_full)
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
	m := new(Machine)
	defer free(m)
	machine_reset_control_write(m, 0xCF9, 1, 0x02)
	testing.expect_value(t, machine_reset_control_read(m, 0xCF9, 1), u32(0x02))
	testing.expect(t, !machine_reset_requested(m))
	machine_reset_control_write(m, 0xCF9, 1, 0x06)
	testing.expect(t, machine_reset_requested(m))
	testing.expect_value(t, machine_reset_provenance(m), Reset_Provenance.Pci_Cf9)
	testing.expect(t, !m.platform.bus.frozen)
	testing.expect_value(
		t,
		machine_reset_reason(m),
		"guest requested hardware reset (PCI reset control)",
	)
}

@(test)
test_machine_guest_cf9_reset_stops_without_freezing :: proc(t: ^testing.T) {
	if !hv.available() {
		log.warn("WHPX not available")
		return
	}
	m := new(Machine)
	defer free(m)
	if !testing.expect(t, machine_init(m, 64 * 1024 * 1024)) {return}
	defer machine_destroy(m)

	copy(m.vm.ram[0x7C00:], []u8{0xBA, 0xF9, 0x0C, 0xB0, 0x02, 0xEE, 0xB0, 0x06, 0xEE, 0xF4})
	hv.set_realmode_entry(&m.vm, 0, 0x7C00)
	testing.expect(t, !step(m))
	testing.expect(t, machine_reset_requested(m))
	testing.expect_value(t, machine_reset_provenance(m), Reset_Provenance.Pci_Cf9)
	testing.expect(t, !m.platform.bus.frozen)
}

@(test)
test_machine_port92_reset_has_independent_provenance :: proc(t: ^testing.T) {
	prior_logger := context.logger
	quiet_logger := log.create_console_logger(.Fatal, {.Level})
	context.logger = quiet_logger
	defer {
		context.logger = prior_logger
		log.destroy_console_logger(quiet_logger)
	}
	m := new(Machine)
	defer free(m)
	i8042_init(&m.platform.kbd, m, nil, nil, machine_guest_reset)
	i8042_out(&m.platform.kbd, 0x92, 0x03)
	testing.expect(t, machine_reset_requested(m))
	testing.expect_value(t, machine_reset_provenance(m), Reset_Provenance.Port_92)
	testing.expect(t, !m.platform.bus.frozen)
}

@(test)
test_machine_master_clock_controls_all_device_time :: proc(t: ^testing.T) {
	backing := make([]u8, video.VRAM_SIZE)
	defer delete(backing)
	m := new(Machine)
	defer free(m)
	if !testing.expect(t, video.vga_init(&m.vga, backing)) {return}
	defer video.vga_destroy(&m.vga)
	machine_advance_time_ns(m, 1_000)
	testing.expect_value(t, m.vga.timing.elapsed_ns, u64(0))
	testing.expect_value(t, master_timeline_now(m.timeline), u64(6_600))

	time.sleep(time.Millisecond)
	_ = machine_display_frame(m)
	testing.expect_value(t, m.vga.timing.elapsed_ns, u64(1_000))

	machine_clock_set_running(m, true)
	time.sleep(time.Millisecond)
	_ = machine_text_snapshot(m)
	testing.expect(t, m.vga.timing.elapsed_ns > 1_000)
	machine_clock_set_running(m, false)
	_ = machine_text_snapshot(m)
	frozen_time := m.vga.timing.elapsed_ns
	time.sleep(time.Millisecond)
	_ = machine_text_snapshot(m)
	testing.expect_value(t, m.vga.timing.elapsed_ns, frozen_time)
}

@(test)
test_machine_string_io_batches_time_sync_and_wake_rearm :: proc(t: ^testing.T) {
	backing := make([]u8, video.VRAM_SIZE)
	defer delete(backing)
	m := new(Machine)
	defer free(m)
	if !testing.expect(t, video.vga_init(&m.vga, backing)) {return}
	defer video.vga_destroy(&m.vga)
	probe: Machine_String_IO_Wake_Probe
	m.wake_ctx = &probe
	m.wake_schedule = machine_test_string_io_rearm
	m.clock_running = true
	m.active_tick = time.tick_now()

	machine_io_string_begin(m)
	start := master_timeline_now(m.timeline)
	time.sleep(time.Millisecond)
	for _ in 0 ..< 4 {
		machine_sync_time(m)
		machine_rearm_wake(m)
	}
	testing.expect_value(t, master_timeline_now(m.timeline), start)
	testing.expect_value(t, probe.rearms, 0)

	machine_io_string_begin(m)
	machine_sync_time(m)
	machine_rearm_wake(m)
	machine_io_string_end(m)
	testing.expect_value(t, m.io_string_depth, u32(1))
	testing.expect_value(t, master_timeline_now(m.timeline), start)
	testing.expect_value(t, probe.rearms, 0)

	machine_io_string_end(m)
	testing.expect_value(t, m.io_string_depth, u32(0))
	testing.expect(t, master_timeline_now(m.timeline) > start)
	testing.expect_value(t, probe.rearms, 1)
}

@(test)
test_machine_vga_legacy_aperture_batches_mmio_transaction :: proc(t: ^testing.T) {
	backing := make([]u8, video.VRAM_SIZE)
	defer delete(backing)
	m := new(Machine)
	defer free(m)
	if !testing.expect(t, video.vga_init(&m.vga, backing)) {return}
	defer video.vga_destroy(&m.vga)
	video.gsw_vga_init(&m.gsw_vga, backing)
	defer video.gsw_vga_destroy(&m.gsw_vga)
	video.gsw_vga_attach_scanout(&m.gsw_vga, &m.vga)
	m.vga.seq[2] = 0x0F
	m.vga.seq[4] = 0x0E
	m.vga.gfx[5] = 0
	m.vga.gfx[6] = 0x05
	m.vga.gfx[8] = 0xFF
	initial_content := m.vga.content_generation
	gsw_sequence := m.gsw_vga.presentation_state.sequence
	data := [4]u8{0x41, 0x42, 0x43, 0x44}

	machine_mmio(m, 0xA0010, true, data[:])
	testing.expect_value(t, m.legacy_aperture_write_bytes, u64(4))
	testing.expect_value(t, m.legacy_aperture_read_bytes, u64(0))
	testing.expect_value(t, m.vga.content_generation, initial_content + 1)
	testing.expect_value(t, m.gsw_vga.presentation_state.sequence, gsw_sequence)
	for p in 0 ..< 4 {
		testing.expect_value(t, video.vga_vram(&m.vga)[0x10 + p], data[p])
	}

	readback: [4]u8
	machine_mmio(m, 0xA0010, false, readback[:])
	testing.expect_value(t, m.legacy_aperture_write_bytes, u64(4))
	testing.expect_value(t, m.legacy_aperture_read_bytes, u64(4))
	testing.expect_value(t, readback, data)
	testing.expect_value(t, m.vga.content_generation, initial_content + 1)
}

@(test)
test_machine_vga_legacy_aperture_pairs_active_gsw_before_legacy :: proc(t: ^testing.T) {
	backing := make([]u8, video.VRAM_SIZE)
	defer delete(backing)
	ram := make([]u8, 1024)
	defer delete(ram)
	m := new(Machine)
	defer free(m)
	m.vm.ram = ram
	if !testing.expect(t, video.vga_init(&m.vga, backing)) {return}
	defer video.vga_destroy(&m.vga)
	video.gsw_vga_init(&m.gsw_vga, backing)
	defer video.gsw_vga_destroy(&m.gsw_vga)
	video.gsw_vga_attach_scanout(&m.gsw_vga, &m.vga)
	m.gsw_vga.ring_gpa = 128
	m.gsw_vga.ring_size = 256
	m.vga.seq[2] = 0x0F
	m.vga.seq[4] = 0x0E
	m.vga.gfx[5] = 0
	m.vga.gfx[6] = 0x05
	m.vga.gfx[8] = 0xFF
	prime := [1]u8{0x11}
	machine_mmio(m, 0xA0020, true, prime[:])
	present := ram[128:168]
	values := [?]struct {
		offset: int,
		size:   int,
		value:  u64,
	}{
		{0, 2, u64(video.Gsw_Vga_Opcode.Present)},
		{2, 2, u64(video.GSW_VGA_COMMAND_VERSION_2)},
		{4, 4, 40},
		{8, 8, 1},
		{16, 4, 0},
		{20, 4, 4},
		{24, 4, 2},
		{28, 4, 16},
		{32, 4, u64(video.Gsw_Pixel_Format.Xrgb_8888)},
	}
	for field in values {
		for byte in 0 ..< field.size {
			present[field.offset + byte] = u8(field.value >> uint(byte * 8))
		}
	}
	m.gsw_vga.ring_tail = 40
	video.gsw_vga_process(&m.gsw_vga, m.vm.ram)
	if !testing.expect(t, m.gsw_vga.status & video.GSW_VGA_STATUS_ERROR == 0) {return}
	initial := video.gsw_vga_presentation_snapshot(&m.gsw_vga)
	if !testing.expect(t, initial.active_valid) {return}
	if !testing.expect(t, machine_acknowledge_gsw_scanout(m, initial.active)) {return}
	sequence := video.vga_presentation_sequence(&m.vga)
	data := [4]u8{0x41, 0x42, 0x43, 0x44}

	machine_mmio(m, 0xA0010, true, data[:])
	descriptor: video.Scanout_Descriptor
	defer video.scanout_descriptor_destroy(&descriptor)
	if !testing.expect(t, machine_capture_scanout(m, &descriptor, 1)) {return}
	gsw := descriptor.gsw_presentation
	legacy := descriptor.legacy_update
	testing.expect(t, gsw.present_valid)
	testing.expect_value(t, gsw.present.header.sequence, sequence + 1)
	testing.expect_value(t, legacy.header.sequence, sequence + 2)
	testing.expect_value(
		t,
		gsw.full_reason,
		contract.Damage_Full_Reason.External_Tracking,
	)
	testing.expect_value(t, gsw.present.header.dirty, contract.rect_set_full({4, 2}))
	testing.expect_value(
		t,
		gsw.present.header.lifecycle_generation,
		initial.active.header.lifecycle_generation,
	)
	testing.expect_value(t, gsw.present.header.mode_generation, initial.active.header.mode_generation)
	testing.expect_value(t, legacy.header.mode_generation, gsw.present.header.mode_generation)
	testing.expect_value(t, gsw.present.header.surface, initial.active.header.surface)
}

@(test)
test_machine_vga_vertical_interrupt_uses_at_irq9_redirect :: proc(t: ^testing.T) {
	backing := make([]u8, video.VRAM_SIZE)
	defer delete(backing)
	m := new(Machine)
	defer free(m)
	pic_setup(&m.platform.pic)
	if !testing.expect(t, video.vga_init(&m.vga, backing)) {return}
	defer video.vga_destroy(&m.vga)
	video.vga_set_legacy_irq(&m.vga, m, machine_vga_legacy_irq)
	m.vga.timing = video.Video_Timing {
		frame_period_ns = 1000,
		line_period_ns  = 100,
		total_lines     = 10,
		visible_lines   = 5,
		visible_dots    = 8,
		total_dots      = 10,
		vblank_start    = 5,
		vblank_end      = 10,
		retrace_start   = 6,
		retrace_end     = 8,
	}
	m.vga.crtc[0x11] = 0x10

	video.vga_sync_to(&m.vga, 550)
	source_bit := u8(1) << u8(Pic_Irq_Source.Vga_Retrace)
	testing.expect(t, m.platform.pic.source_asserted[9] & source_bit != 0)
	testing.expect(t, m.yield_requested)
	testing.expect(t, pic_has_pending(&m.platform.pic))
	vector, ok := pic_ack(&m.platform.pic)
	testing.expect(t, ok)
	testing.expect_value(t, vector, u8(0x71))

	video.vga_out(&m.vga, 0x3D4, 0x11)
	video.vga_out(&m.vga, 0x3D5, 0)
	testing.expect(t, m.platform.pic.source_asserted[9] & source_bit == 0)
}

@(test)
test_machine_vga_irq9_level_mode_clears_after_spurious_cascade :: proc(t: ^testing.T) {
	backing := make([]u8, video.VRAM_SIZE)
	defer delete(backing)
	m := new(Machine)
	defer free(m)
	pic_setup(&m.platform.pic)
	pic_out(&m.platform.pic, 0x4D1, 0x02)
	if !testing.expect(t, video.vga_init(&m.vga, backing)) {return}
	defer video.vga_destroy(&m.vga)
	video.vga_set_legacy_irq(&m.vga, m, machine_vga_legacy_irq)
	m.vga.timing = video.Video_Timing {
		frame_period_ns = 1000,
		line_period_ns  = 100,
		total_lines     = 10,
		visible_lines   = 5,
		visible_dots    = 8,
		total_dots      = 10,
		vblank_start    = 5,
		vblank_end      = 10,
		retrace_start   = 6,
		retrace_end     = 8,
	}
	m.vga.crtc[0x11] = 0x10

	video.vga_sync_to(&m.vga, 550)
	vector, ok := pic_ack(&m.platform.pic)
	testing.expect(t, ok)
	testing.expect_value(t, vector, u8(0x71))
	pic_out(&m.platform.pic, 0xA0, 0x61)
	pic_out(&m.platform.pic, 0x20, 0x62)
	testing.expect(t, pic_has_pending(&m.platform.pic))

	video.vga_out(&m.vga, 0x3D4, 0x11)
	video.vga_out(&m.vga, 0x3D5, 0)
	testing.expect_value(t, m.platform.pic.slave.irr & 0x02, u8(0))
	testing.expect_value(t, m.platform.pic.source_asserted[9], u8(0))
	vector, ok = pic_ack(&m.platform.pic)
	testing.expect(t, ok)
	testing.expect_value(t, vector, u8(0x77))
	pic_out(&m.platform.pic, 0x20, 0x62)
	testing.expect(t, !pic_has_pending(&m.platform.pic))
}

@(test)
test_machine_one_shot_rearms_same_deadline_and_run_guard_disarms_after_run :: proc(t: ^testing.T) {
	m := new(Machine)
	defer free(m)
	if !testing.expect(t, machine_set_hardware_trace(m, true)) {return}
	defer {
		trace := machine_hardware_trace_detach(m)
		if trace != nil {free(trace)}
	}
	pit_init(&m.platform.pit)
	probe: Machine_String_IO_Wake_Probe
	m.wake_ctx = &probe
	m.wake_schedule = machine_test_string_io_rearm

	machine_rearm_wake(m)
	if !testing.expect_value(t, probe.rearms, 1) {return}
	first_generation := probe.generation
	machine_rearm_wake(m)
	testing.expect_value(t, probe.rearms, 2)
	second_generation := probe.generation
	testing.expect(t, second_generation > first_generation)
	if !testing.expect(t, machine_hardware_trace_count(m) >= 2) {return}
	wake_arm :=
		m.hardware_trace.events[(machine_hardware_trace_count(m) - 1) % HARDWARE_TRACE_CAPACITY]
	testing.expect_value(t, wake_arm.kind, Hardware_Event_Kind.Wake_Arm)
	testing.expect_value(t, wake_arm.a, u64(Wake_Schedule_Mode.One_Shot))
	testing.expect_value(t, wake_arm.b, second_generation)

	m.vcpu_running = true
	testing.expect(t, machine_arm_run_guard(m))
	testing.expect_value(t, probe.run_guards, 1)
	testing.expect_value(t, probe.last_mode, Wake_Schedule_Mode.Run_Guard)
	testing.expect(t, probe.generation > second_generation)
	guard_generation := probe.generation

	m.vcpu_running = false
	machine_disarm_wake(m)
	testing.expect_value(t, probe.disarms, 1)
	testing.expect_value(t, probe.last_mode, Wake_Schedule_Mode.Disarm)
	testing.expect(t, probe.generation > guard_generation)
	testing.expect(t, !m.wake_scheduled)
}

@(test)
test_machine_active_run_guard_rearms_for_earlier_pit_deadline :: proc(t: ^testing.T) {
	m := new(Machine)
	defer free(m)
	pit_init(&m.platform.pit)
	m.cpu_mode = .Turbo
	probe: Machine_String_IO_Wake_Probe
	m.wake_ctx = &probe
	m.wake_schedule = machine_test_string_io_rearm
	m.vcpu_running = true

	if !testing.expect(t, machine_arm_run_guard(m)) {return}
	if !testing.expect_value(t, probe.run_guards, 1) {return}
	original_deadline := m.wake_deadline
	original_generation := m.wake_generation
	original_delay := probe.last_delay_ns

	pit_out(&m.platform.pit, 0x43, 0x34)
	pit_out(&m.platform.pit, 0x40, 2)
	pit_out(&m.platform.pit, 0x40, 0)
	machine_rearm_wake(m)

	testing.expect_value(t, probe.run_guards, 2)
	testing.expect_value(t, probe.last_mode, Wake_Schedule_Mode.Run_Guard)
	testing.expect(t, m.wake_deadline < original_deadline)
	testing.expect(t, probe.last_delay_ns < original_delay)
	testing.expect(t, m.wake_generation > original_generation)
	rearmed_generation := m.wake_generation
	machine_rearm_wake(m)
	testing.expect_value(t, probe.run_guards, 2)
	testing.expect_value(t, m.wake_generation, rearmed_generation)
}

@(test)
test_machine_running_without_guard_arms_pending_deadline :: proc(t: ^testing.T) {
	m := new(Machine)
	defer free(m)
	pit_init(&m.platform.pit)
	probe: Machine_String_IO_Wake_Probe
	m.wake_ctx = &probe
	m.wake_schedule = machine_test_string_io_rearm
	m.vcpu_running = true

	testing.expect(t, !m.wake_scheduled)
	machine_rearm_wake(m)
	testing.expect_value(t, probe.run_guards, 1)
	testing.expect_value(t, probe.last_mode, Wake_Schedule_Mode.Run_Guard)
	testing.expect(t, m.wake_scheduled)
	testing.expect_value(t, m.wake_mode, Wake_Schedule_Mode.Run_Guard)
	testing.expect(t, m.wake_generation > 0)
}

@(test)
test_machine_run_guard_arm_failure_aborts_before_hypervisor_run :: proc(t: ^testing.T) {
	m := new(Machine)
	defer free(m)
	pit_init(&m.platform.pit)
	probe := Machine_String_IO_Wake_Probe {
		fail_run_guard = true,
	}
	m.wake_ctx = &probe
	m.wake_schedule = machine_test_string_io_rearm
	before := m.vm.run_calls

	testing.expect(t, !machine_arm_run_guard(m))
	testing.expect_value(t, m.vm.run_calls, before)
	testing.expect_value(t, probe.run_guards, 1)
	testing.expect(t, !m.platform.bus.frozen)
	testing.expect(t, !m.wake_scheduled)
}

@(test)
test_machine_failed_string_io_run_guard_rearm_forces_whpx_yield :: proc(t: ^testing.T) {
	prior_logger := context.logger
	quiet_logger := log.create_console_logger(.Fatal, {.Level})
	context.logger = quiet_logger
	defer {
		context.logger = prior_logger
		log.destroy_console_logger(quiet_logger)
	}
	m := new(Machine)
	defer free(m)
	pit_init(&m.platform.pit)
	m.cpu_mode = .Turbo
	probe: Machine_String_IO_Wake_Probe
	m.wake_ctx = &probe
	m.wake_schedule = machine_test_string_io_rearm
	m.vcpu_running = true
	if !testing.expect(t, machine_arm_run_guard(m)) {return}

	probe.fail_run_guard = true
	machine_io_string_begin(m)
	pit_out(&m.platform.pit, 0x43, 0x34)
	pit_out(&m.platform.pit, 0x40, 2)
	pit_out(&m.platform.pit, 0x40, 0)
	machine_io_string_end(m)

	testing.expect(t, m.platform.bus.frozen)
	testing.expect(t, strings.contains(m.platform.bus.freeze_msg, "run-guard rearm failed"))
	testing.expect(t, machine_io_should_yield(m))
	m.platform.bus.frozen = false
	m.platform.reset.reset_requested = true
	testing.expect(t, machine_io_should_yield(m))
	m.platform.reset.reset_requested = false
	m.platform.power.power_off_requested = true
	testing.expect(t, machine_io_should_yield(m))
}

@(test)
test_machine_pause_suspends_master_timeline_and_tsc :: proc(t: ^testing.T) {
	if !hv.available() {
		log.warn("WHPX not available")
		return
	}
	testing.set_fail_timeout(t, 10 * time.Second)
	m := new(Machine)
	defer free(m)
	if !testing.expect(t, machine_init(m, 64 * 1024 * 1024)) {return}
	defer machine_destroy(m)

	machine_clock_set_running(m, false)
	paused_tick := master_timeline_now(m.timeline)
	name := hv.WHV_REGISTER_NAME.Tsc
	before: hv.WHV_REGISTER_VALUE
	if !testing.expect(
		t,
		hv.WHvGetVirtualProcessorRegisters(m.vm.part, 0, &name, 1, &before) >= 0,
	) {return}
	time.sleep(5 * time.Millisecond)
	machine_sync_time(m)
	after: hv.WHV_REGISTER_VALUE
	if !testing.expect(
		t,
		hv.WHvGetVirtualProcessorRegisters(m.vm.part, 0, &name, 1, &after) >= 0,
	) {return}
	testing.expect_value(t, master_timeline_now(m.timeline), paused_tick)
	testing.expect_value(t, after.Reg64, before.Reg64)

	machine_clock_set_running(m, true)
	time.sleep(time.Millisecond)
	machine_sync_time(m)
	resumed: hv.WHV_REGISTER_VALUE
	if !testing.expect(
		t,
		hv.WHvGetVirtualProcessorRegisters(m.vm.part, 0, &name, 1, &resumed) >= 0,
	) {return}
	testing.expect(t, master_timeline_now(m.timeline) > paused_tick)
	testing.expect(t, resumed.Reg64 > after.Reg64)
}
