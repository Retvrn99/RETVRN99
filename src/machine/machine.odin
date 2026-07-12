// SPDX-License-Identifier: GPL-3.0-only
package machine

import "core:log"
import "core:time"
import disk "../disk"
import hv "../hv"
import video "../vga"

Machine :: struct {
	bus:       Bus,
	pic:       Pic_Pair,
	pit:       Pit,
	cmos:      Cmos,
	kbd:       I8042,
	pci:       Pci,
	fwcfg:     Fwcfg,
	dma:       Dma,
	vga:       video.Vga,
	ide:       disk.Ide,
	has_disk:  bool,
	vm:        hv.Vm,
	last_tick: time.Tick,
	dbg_buf:   [256]u8, // SeaBIOS port 0x402 line buffer
	dbg_len:   int,
}

machine_init :: proc(m: ^Machine, ram_size: int) -> bool {
	bus_init(&m.bus)
	if !hv.create(&m.vm, ram_size) { return false }
	m.vm.io_ctx = m
	m.vm.io_read = machine_io_read
	m.vm.io_write = machine_io_write

	cmos_init(&m.cmos, u64(ram_size))
	hh, mm, ss := time.clock_from_time(time.now())
	cmos_set_time(&m.cmos, u8(hh), u8(mm), u8(ss))
	i8042_init(&m.kbd, m, machine_irq1, machine_guest_reset)
	pci_init(&m.pci)
	fwcfg_init(&m.fwcfg, u64(ram_size))

	pic_h := Io_Handler{ctx = m, read = machine_pic_read, write = machine_pic_write}
	bus_register(&m.bus, 0x20, 0x21, pic_h)
	bus_register(&m.bus, 0xA0, 0xA1, pic_h)

	pit_h := Io_Handler{ctx = m, read = machine_pit_read, write = machine_pit_write}
	bus_register(&m.bus, 0x40, 0x43, pit_h)
	p61_h := Io_Handler{ctx = m, read = machine_port61_read, write = machine_port61_write}
	bus_register(&m.bus, 0x61, 0x61, p61_h)

	cmos_h := Io_Handler{ctx = m, read = machine_cmos_read, write = machine_cmos_write}
	bus_register(&m.bus, 0x70, 0x71, cmos_h)

	kbd_h := Io_Handler{ctx = m, read = machine_kbd_read, write = machine_kbd_write}
	bus_register(&m.bus, 0x60, 0x60, kbd_h)
	bus_register(&m.bus, 0x64, 0x64, kbd_h)
	bus_register(&m.bus, 0x92, 0x92, kbd_h)

	dma_h := Io_Handler{ctx = m, read = machine_dma_read, write = machine_dma_write}
	bus_register(&m.bus, 0x00, 0x0F, dma_h)
	bus_register(&m.bus, 0x81, 0x81, dma_h)

	pci_h := Io_Handler{ctx = m, read = machine_pci_read, write = machine_pci_write}
	bus_register(&m.bus, 0xCF8, 0xCFF, pci_h)

	fw_h := Io_Handler{ctx = m, read = machine_fwcfg_read, write = machine_fwcfg_write}
	bus_register(&m.bus, 0x510, 0x511, fw_h)

	vga_h := Io_Handler{ctx = m, read = machine_vga_read, write = machine_vga_write}
	bus_register(&m.bus, 0x3B0, 0x3DF, vga_h)

	dbg_h := Io_Handler{ctx = m, read = machine_dbg_read, write = machine_dbg_write}
	bus_register(&m.bus, 0x402, 0x402, dbg_h)

	// deliberate whitelist: probed but not modeled yet
	bus_whitelist(&m.bus, 0x80, 0xED) // POST + delay
	machine_whitelist_range(&m.bus, 0x1F0, 0x1F7) // IDE until machine_attach_disk
	bus_whitelist(&m.bus, 0x3F6)
	machine_whitelist_range(&m.bus, 0x2F8, 0x2FF) // UARTs absent
	machine_whitelist_range(&m.bus, 0x3F8, 0x3FF)
	machine_whitelist_range(&m.bus, 0xC0, 0xDF) // master DMA + cascade
	machine_whitelist_range(&m.bus, 0x88, 0x8F) // DMA page registers
	bus_whitelist(&m.bus, 0x4D0, 0x4D1) // ELCR
	machine_whitelist_range(&m.bus, 0x3F0, 0x3F5) // FDC until Task 24
	bus_whitelist(&m.bus, 0x3F7)

	m.last_tick = time.tick_now()
	return true
}

machine_destroy :: proc(m: ^Machine) {
	hv.destroy(&m.vm)
	fwcfg_destroy(&m.fwcfg)
	bus_destroy(&m.bus)
}

// stores the device and takes over the IDE ports whitelisted at init
machine_attach_disk :: proc(m: ^Machine, bd: disk.Block_Device) {
	disk.ide_init(&m.ide, bd)
	m.ide.irq_ctx = m
	m.ide.irq = machine_irq14
	m.has_disk = true
	h := Io_Handler{ctx = m, read = machine_ide_read, write = machine_ide_write}
	bus_register(&m.bus, 0x1F0, 0x1F7, h)
	bus_register(&m.bus, 0x3F6, 0x3F6, h)
}

step :: proc(m: ^Machine) -> bool { // false = frozen/powered off
	now := time.tick_now()
	ns := u64(time.tick_diff(m.last_tick, now))
	m.last_tick = now
	for _ in 0 ..< pit_advance(&m.pit, ns) { pic_raise(&m.pic, 0) }
	if pic_has_pending(&m.pic) {
		if hv.can_inject(&m.vm) {
			if v, ok := pic_ack(&m.pic); ok { hv.inject_irq(&m.vm, v) }
		} else {
			hv.request_irq_window(&m.vm, true)
		}
	}
	ex := hv.run(&m.vm)
	#partial switch ex.kind {
	case .Halt: // wait for the next IRQ without burning CPU
		time.sleep(200 * time.Microsecond)
	case .Failed:
		bus_freeze(&m.bus, ex.detail)
		return false
	}
	return !m.bus.frozen
}

@(private = "file")
machine_whitelist_range :: proc(b: ^Bus, first, last: u16) {
	for p := int(first); p <= int(last); p += 1 { bus_whitelist(b, u16(p)) }
}

// --- hv <-> bus glue ---

@(private = "file")
machine_io_read :: proc(ctx: rawptr, port: u16, size: u8) -> u32 {
	m := (^Machine)(ctx)
	return bus_io_read(&m.bus, port, size)
}

@(private = "file")
machine_io_write :: proc(ctx: rawptr, port: u16, size: u8, val: u32) {
	m := (^Machine)(ctx)
	bus_io_write(&m.bus, port, size, val)
}

// --- IRQ lines ---

@(private = "file")
machine_irq1 :: proc(ctx: rawptr) {
	m := (^Machine)(ctx)
	pic_raise(&m.pic, 1)
}

@(private = "file")
machine_irq14 :: proc(ctx: rawptr) {
	m := (^Machine)(ctx)
	pic_raise(&m.pic, 14)
}

@(private = "file")
machine_guest_reset :: proc(ctx: rawptr) {
	m := (^Machine)(ctx)
	bus_freeze(&m.bus, "guest requested reset")
}

// --- per-device adapters; multi-byte access splits into successive ports ---

@(private = "file")
machine_pic_read :: proc(ctx: rawptr, port: u16, size: u8) -> u32 {
	m := (^Machine)(ctx)
	v: u32 = 0
	for i in 0 ..< int(size) { v |= u32(pic_in(&m.pic, port + u16(i))) << (8 * uint(i)) }
	return v
}

@(private = "file")
machine_pic_write :: proc(ctx: rawptr, port: u16, size: u8, val: u32) {
	m := (^Machine)(ctx)
	for i in 0 ..< int(size) { pic_out(&m.pic, port + u16(i), u8(val >> (8 * uint(i)))) }
}

@(private = "file")
machine_pit_read :: proc(ctx: rawptr, port: u16, size: u8) -> u32 {
	m := (^Machine)(ctx)
	v: u32 = 0
	for i in 0 ..< int(size) { v |= u32(pit_in(&m.pit, port + u16(i))) << (8 * uint(i)) }
	return v
}

@(private = "file")
machine_pit_write :: proc(ctx: rawptr, port: u16, size: u8, val: u32) {
	m := (^Machine)(ctx)
	for i in 0 ..< int(size) { pit_out(&m.pit, port + u16(i), u8(val >> (8 * uint(i)))) }
}

@(private = "file")
machine_port61_read :: proc(ctx: rawptr, port: u16, size: u8) -> u32 {
	m := (^Machine)(ctx)
	return u32(pit_port61_read(&m.pit))
}

@(private = "file")
machine_port61_write :: proc(ctx: rawptr, port: u16, size: u8, val: u32) {
	m := (^Machine)(ctx)
	pit_port61_write(&m.pit, u8(val))
}

@(private = "file")
machine_cmos_read :: proc(ctx: rawptr, port: u16, size: u8) -> u32 {
	m := (^Machine)(ctx)
	v: u32 = 0
	for i in 0 ..< int(size) { v |= u32(cmos_in(&m.cmos, port + u16(i))) << (8 * uint(i)) }
	return v
}

@(private = "file")
machine_cmos_write :: proc(ctx: rawptr, port: u16, size: u8, val: u32) {
	m := (^Machine)(ctx)
	for i in 0 ..< int(size) { cmos_out(&m.cmos, port + u16(i), u8(val >> (8 * uint(i)))) }
}

@(private = "file")
machine_kbd_read :: proc(ctx: rawptr, port: u16, size: u8) -> u32 {
	m := (^Machine)(ctx)
	return u32(i8042_in(&m.kbd, port))
}

@(private = "file")
machine_kbd_write :: proc(ctx: rawptr, port: u16, size: u8, val: u32) {
	m := (^Machine)(ctx)
	i8042_out(&m.kbd, port, u8(val))
}

@(private = "file")
machine_dma_read :: proc(ctx: rawptr, port: u16, size: u8) -> u32 {
	m := (^Machine)(ctx)
	v: u32 = 0
	for i in 0 ..< int(size) { v |= u32(dma_in(&m.dma, port + u16(i))) << (8 * uint(i)) }
	return v
}

@(private = "file")
machine_dma_write :: proc(ctx: rawptr, port: u16, size: u8, val: u32) {
	m := (^Machine)(ctx)
	for i in 0 ..< int(size) { dma_out(&m.dma, port + u16(i), u8(val >> (8 * uint(i)))) }
}

@(private = "file")
machine_pci_read :: proc(ctx: rawptr, port: u16, size: u8) -> u32 {
	m := (^Machine)(ctx)
	return pci_in(&m.pci, port, size)
}

@(private = "file")
machine_pci_write :: proc(ctx: rawptr, port: u16, size: u8, val: u32) {
	m := (^Machine)(ctx)
	pci_out(&m.pci, port, size, val)
}

@(private = "file")
machine_fwcfg_read :: proc(ctx: rawptr, port: u16, size: u8) -> u32 {
	m := (^Machine)(ctx)
	return fwcfg_in(&m.fwcfg, port, size)
}

@(private = "file")
machine_fwcfg_write :: proc(ctx: rawptr, port: u16, size: u8, val: u32) {
	m := (^Machine)(ctx)
	fwcfg_out(&m.fwcfg, port, size, val)
}

@(private = "file")
machine_vga_read :: proc(ctx: rawptr, port: u16, size: u8) -> u32 {
	m := (^Machine)(ctx)
	v: u32 = 0
	for i in 0 ..< int(size) { v |= u32(video.vga_in(&m.vga, port + u16(i))) << (8 * uint(i)) }
	return v
}

@(private = "file")
machine_vga_write :: proc(ctx: rawptr, port: u16, size: u8, val: u32) {
	m := (^Machine)(ctx)
	for i in 0 ..< int(size) { video.vga_out(&m.vga, port + u16(i), u8(val >> (8 * uint(i)))) }
}

@(private = "file")
machine_ide_read :: proc(ctx: rawptr, port: u16, size: u8) -> u32 {
	m := (^Machine)(ctx)
	return disk.ide_io_read(&m.ide, port, size)
}

@(private = "file")
machine_ide_write :: proc(ctx: rawptr, port: u16, size: u8, val: u32) {
	m := (^Machine)(ctx)
	disk.ide_io_write(&m.ide, port, size, val)
}

// SeaBIOS debug console: reads must return 0xE9 or SeaBIOS disables it
@(private = "file")
machine_dbg_read :: proc(ctx: rawptr, port: u16, size: u8) -> u32 {
	return 0xE9
}

@(private = "file")
machine_dbg_write :: proc(ctx: rawptr, port: u16, size: u8, val: u32) {
	m := (^Machine)(ctx)
	c := u8(val)
	if c == '\n' || m.dbg_len == len(m.dbg_buf) {
		log.infof("seabios: %s", string(m.dbg_buf[:m.dbg_len]))
		m.dbg_len = 0
		if c == '\n' { return }
	}
	if c != '\r' {
		m.dbg_buf[m.dbg_len] = c
		m.dbg_len += 1
	}
}
