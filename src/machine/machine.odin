// SPDX-License-Identifier: GPL-3.0-only
package machine

import disk "../disk"
import hosttime "../hosttime"
import hv "../hv"
import video "../vga"
import config "../vmconfig"
import "core:fmt"
import "core:log"
import "core:time"

// MMIO probe zones SeaBIOS touches with no device behind them
Mmio_Zone :: enum {
	Ioapic, // 0xFEC00000: IOAPIC probe
	Lapic, // 0xFEE00000: smp_scan LAPIC pokes
	Mmconfig, // 0xE0000000: PCIe mmconfig probe
	Pci_Window, // 0x80000000+: BAR / option-ROM signature reads (map_pcirom)
}

EXIT_HISTORY :: 32
IO_HISTORY :: 64
IDE_HISTORY :: 128

// forensics: one recorded port access
Io_Trace :: struct {
	port:  u16,
	write: bool,
	size:  u8,
	val:   u32,
}

// forensics: one IDE command with its addressing at issue time
Ide_Cmd_Trace :: struct {
	cmd:   u8,
	drive: u8,
	count: u8,
	lba:   u32,
}

Machine :: struct {
	bus:             Bus,
	pic:             Pic_Pair,
	pit:             Pit,
	cmos:            Cmos,
	kbd:             I8042,
	pci:             Pci,
	fwcfg:           Fwcfg,
	dma:             Dma,
	vga:             video.Vga,
	ide:             disk.Ide,
	atapi:           disk.Atapi,
	fdc:             disk.Fdc,
	has_disk:        bool,
	reset_requested: bool,
	reset_control:   u8,
	vm:              hv.Vm,
	governor:        hv.Governor,
	idle_waiter:     hosttime.Waiter,
	last_tick:       time.Tick,
	dbg_out:         [dynamic]u8, // SeaBIOS port 0x402 bytes; harness drains
	mmio_seen:       [Mmio_Zone]bool, // log tolerated zones only once
	exit_hist:       [EXIT_HISTORY]hv.Exit_Kind, // ring, exit_count % EXIT_HISTORY
	exit_count:      u64,
	io_hist:         [IO_HISTORY]Io_Trace, // ring, io_count % IO_HISTORY
	io_count:        u64,
	ide_hist:        [IDE_HISTORY]Io_Trace, // ring of IDE-port accesses only
	ide_count:       u64,
	cmd_hist:        [IDE_HISTORY]Ide_Cmd_Trace, // ring of IDE commands
	cmd_count:       u64,
	inj_count:       [256]u64, // injected IRQ vectors
}

machine_init :: proc(m: ^Machine, ram_size: int) -> bool {
	bus_init(&m.bus)
	if !hv.create(&m.vm, ram_size) {return false}
	if !hv.governor_init(&m.governor, &m.vm, .GSW_886) {
		hv.destroy(&m.vm)
		return false
	}
	hosttime.waiter_init(&m.idle_waiter)
	m.vm.io_ctx = m
	m.vm.io_read = machine_io_read
	m.vm.io_write = machine_io_write
	m.vm.mmio = machine_mmio

	cmos_init(&m.cmos, u64(ram_size))
	hh, mm, ss := time.clock_from_time(time.now())
	cmos_set_time(&m.cmos, u8(hh), u8(mm), u8(ss))
	i8042_init(&m.kbd, m, machine_irq1, machine_guest_reset)
	pci_init(&m.pci)
	fwcfg_init(&m.fwcfg, u64(ram_size))
	// SeaBIOS vgarom_setup memsets 0xC0000 and then deploys "vgaroms/"
	// romfiles: the SeaVGABIOS image must arrive through fw_cfg
	fwcfg_add_file(&m.fwcfg, "vgaroms/vgabios-stdvga.bin", VGABIOS_IMAGE, 0x0021)

	pic_h := Io_Handler {
		ctx   = m,
		read  = machine_pic_read,
		write = machine_pic_write,
	}
	bus_register(&m.bus, 0x20, 0x21, pic_h)
	bus_register(&m.bus, 0xA0, 0xA1, pic_h)

	pit_h := Io_Handler {
		ctx   = m,
		read  = machine_pit_read,
		write = machine_pit_write,
	}
	bus_register(&m.bus, 0x40, 0x43, pit_h)
	p61_h := Io_Handler {
		ctx   = m,
		read  = machine_port61_read,
		write = machine_port61_write,
	}
	bus_register(&m.bus, 0x61, 0x61, p61_h)

	cmos_h := Io_Handler {
		ctx   = m,
		read  = machine_cmos_read,
		write = machine_cmos_write,
	}
	bus_register(&m.bus, 0x70, 0x71, cmos_h)

	kbd_h := Io_Handler {
		ctx   = m,
		read  = machine_kbd_read,
		write = machine_kbd_write,
	}
	bus_register(&m.bus, 0x60, 0x60, kbd_h)
	bus_register(&m.bus, 0x64, 0x64, kbd_h)
	bus_register(&m.bus, 0x92, 0x92, kbd_h)

	dma_h := Io_Handler {
		ctx   = m,
		read  = machine_dma_read,
		write = machine_dma_write,
	}
	bus_register(&m.bus, 0x00, 0x0F, dma_h)
	bus_register(&m.bus, 0x81, 0x81, dma_h)

	pci_h := Io_Handler {
		ctx   = m,
		read  = machine_pci_read,
		write = machine_pci_write,
	}
	bus_register(&m.bus, 0xCF8, 0xCFF, pci_h)
	bus_register(&m.bus, 0xC000, 0xCFFF, pci_h)
	reset_h := Io_Handler {
		ctx   = m,
		read  = machine_reset_control_read,
		write = machine_reset_control_write,
	}
	bus_register(&m.bus, 0xCF9, 0xCF9, reset_h)

	fw_h := Io_Handler {
		ctx   = m,
		read  = machine_fwcfg_read,
		write = machine_fwcfg_write,
	}
	bus_register(&m.bus, 0x510, 0x511, fw_h)

	vga_h := Io_Handler {
		ctx   = m,
		read  = machine_vga_read,
		write = machine_vga_write,
	}
	bus_register(&m.bus, 0x3B0, 0x3DF, vga_h)

	dbg_h := Io_Handler {
		ctx   = m,
		read  = machine_dbg_read,
		write = machine_dbg_write,
	}
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
	machine_init_fdc(m)
	machine_init_atapi(m)
	bus_whitelist(&m.bus, 0x1CE, 0x1CF) // bochs dispi probe by SeaVGABIOS bochsvga_setup
	machine_whitelist_range(&m.bus, 0x378, 0x37A) // LPT1 probe by SeaBIOS lpt_setup; absent
	machine_whitelist_range(&m.bus, 0x278, 0x27A) // LPT2 probe by SeaBIOS lpt_setup; absent
	machine_whitelist_range(&m.bus, 0x3E8, 0x3EF) // COM3 probe by SeaBIOS serial_setup; absent
	machine_whitelist_range(&m.bus, 0x2E8, 0x2EF) // COM4 probe by SeaBIOS serial_setup; absent
	machine_whitelist_range(&m.bus, 0x2F2, 0x2F7) // IO.SYS boot probe: writes 0xFF here (tertiary FDC range); absent
	machine_whitelist_range(&m.bus, 0x6F2, 0x6F7) // same IO.SYS probe series, stride 0x400
	machine_whitelist_range(&m.bus, 0x1E8, 0x1EF) // IDE tertiary: Win98 boot-disk ATAPI driver probe; absent
	machine_whitelist_range(&m.bus, 0x168, 0x16F) // IDE quaternary, same driver probe series
	bus_whitelist(&m.bus, 0x36E, 0x36F) // IDE quaternary device control, same probe (tertiary's 0x3EE is inside the COM3 range above)
	// Adaptec/BusLogic ISA windows probed by the EBD SCSI drivers (BTDOSM/ASPI2DOS/ASPI4DOS); absent.
	// Registered handlers always beat the whitelist, so future devices in these ranges are unaffected.
	machine_whitelist_range(&m.bus, 0x100, 0x15F)
	machine_whitelist_range(&m.bus, 0x200, 0x25F)
	machine_whitelist_range(&m.bus, 0x300, 0x35F)
	bus_whitelist(&m.bus, 0xA79) // ISA PnP write-data, ASPI2DOS card isolation (address port 0x279 sits in the LPT2 range above)
	// ISA PnP read-data candidates: ASPI2DOS walks 0x20B, 0x22B, ... 0x3EB until isolation finds a card (it never will)
	for p := u16(0x20B); p <= 0x3EB; p += 0x20 {bus_whitelist(&m.bus, p)}
	m.last_tick = time.tick_now()
	return true
}

machine_destroy :: proc(m: ^Machine) {
	disk.fdc_eject_media(&m.fdc)
	disk.atapi_eject(&m.atapi)
	hosttime.waiter_destroy(&m.idle_waiter)
	hv.governor_destroy(&m.governor)
	hv.destroy(&m.vm)
	fwcfg_destroy(&m.fwcfg)
	bus_destroy(&m.bus)
	delete(m.dbg_out)
}

// moves the collected SeaBIOS debug bytes into sink and clears the buffer
machine_drain_dbg :: proc(m: ^Machine, sink: ^[dynamic]u8) {
	append(sink, ..m.dbg_out[:])
	clear(&m.dbg_out)
}

// stores the device and takes over the IDE ports whitelisted at init
machine_attach_disk :: proc(m: ^Machine, bd: disk.Block_Device) {
	disk.ide_init(&m.ide, bd)
	m.ide.irq_ctx = m
	m.ide.irq = machine_irq14
	m.has_disk = true
	h := Io_Handler {
		ctx   = m,
		read  = machine_ide_read,
		write = machine_ide_write,
	}
	bus_register(&m.bus, 0x1F0, 0x1F7, h)
	bus_register(&m.bus, 0x3F6, 0x3F6, h)
}

// registers the FDC on the bus and installs IRQ6 and the DMA ch2 glue
machine_init_fdc :: proc(m: ^Machine) {
	disk.fdc_init(&m.fdc)
	m.fdc.irq_ctx = m
	m.fdc.irq = machine_irq6
	m.fdc.dma_ctx = m
	m.fdc.dma_to_mem = machine_fdc_dma_to_mem
	m.fdc.dma_from_mem = machine_fdc_dma_from_mem
	m.fdc.dma_tc = machine_fdc_dma_tc
	h := Io_Handler {
		ctx   = m,
		read  = machine_fdc_read,
		write = machine_fdc_write,
	}
	bus_register(&m.bus, 0x3F0, 0x3F5, h) // 0x3F6 belongs to the IDE
	bus_register(&m.bus, 0x3F7, 0x3F7, h)
}

// hook for the GUI menu
machine_mount_floppy :: proc(m: ^Machine, img: []u8) -> bool {
	return disk.fdc_set_media(&m.fdc, img)
}

// hook for the GUI menu
machine_eject_floppy :: proc(m: ^Machine) {
	disk.fdc_eject_media(&m.fdc)
}

machine_set_cpu_mode :: proc(m: ^Machine, mode: config.Cpu_Mode) {
	hv.governor_set_mode(&m.governor, &m.vm, mode)
}

machine_init_atapi :: proc(m: ^Machine) {
	disk.atapi_init(&m.atapi)
	m.atapi.irq_ctx = m
	m.atapi.irq = machine_irq15
	h := Io_Handler {
		ctx   = m,
		read  = machine_atapi_read,
		write = machine_atapi_write,
	}
	bus_register(&m.bus, 0x170, 0x177, h)
	bus_register(&m.bus, 0x376, 0x376, h)
}

machine_mount_cdrom :: proc(m: ^Machine, path: string) -> bool {
	return disk.atapi_mount(&m.atapi, path)
}

machine_attach_cdrom :: proc(m: ^Machine, path: string) -> bool {
	return disk.atapi_attach(&m.atapi, path)
}

machine_eject_cdrom :: proc(m: ^Machine) {
	disk.atapi_eject(&m.atapi)
}

machine_cmos_export :: proc(m: ^Machine) -> [CMOS_NVRAM_SIZE]u8 {
	return cmos_nvram_export(&m.cmos)
}

machine_cmos_import :: proc(m: ^Machine, data: []u8) -> bool {
	return cmos_nvram_import(&m.cmos, data, u64(len(m.vm.ram)))
}

machine_reset_requested :: proc(m: ^Machine) -> bool {
	return m != nil && m.reset_requested
}

step :: proc(m: ^Machine) -> bool { 	// false = frozen/powered off
	now := time.tick_now()
	ns := u64(time.tick_diff(m.last_tick, now))
	m.last_tick = now
	for _ in 0 ..< pit_advance(&m.pit, ns) {pic_raise(&m.pic, 0)}
	for _ in 0 ..< cmos_advance(&m.cmos, ns) {pic_raise(&m.pic, 8)}
	if pic_has_pending(&m.pic) {
		if hv.can_inject(&m.vm) {
			if v, ok := pic_ack(&m.pic); ok {
				m.inj_count[v] += 1
				hv.inject_irq(&m.vm, v)
			}
			// more IRQs queued behind this one: exit as soon as the guest
			// can take the next one, or a no-exit guest starves them
			if pic_has_pending(&m.pic) {
				hv.request_irq_window(&m.vm, true)
			}
		} else {
			hv.request_irq_window(&m.vm, true)
		}
	}
	ex := hv.run(&m.vm)
	governor_ok := ex.kind != .Canceled || hv.governor_on_cancel(&m.governor, &m.vm)
	m.exit_hist[m.exit_count % EXIT_HISTORY] = ex.kind
	m.exit_count += 1
	if !governor_ok {
		bus_freeze(&m.bus, "GSW-886 runtime counters unavailable")
		return false
	}
	#partial switch ex.kind {
	case .Halt:
		// wait for the next IRQ without burning CPU
		hosttime.waiter_sleep(&m.idle_waiter, 200 * time.Microsecond)
	case .Failed:
		bus_freeze(&m.bus, ex.detail)
		return false
	}
	return !m.bus.frozen
}

@(private = "file")
machine_whitelist_range :: proc(b: ^Bus, first, last: u16) {
	for p := int(first); p <= int(last); p += 1 {bus_whitelist(b, u16(p))}
}

// --- hv <-> bus glue ---

@(private = "file")
machine_io_read :: proc(ctx: rawptr, port: u16, size: u8) -> u32 {
	m := (^Machine)(ctx)
	v := bus_io_read(&m.bus, port, size)
	t := Io_Trace {
		port  = port,
		write = false,
		size  = size,
		val   = v,
	}
	m.io_hist[m.io_count % IO_HISTORY] = t
	m.io_count += 1
	if port >= 0x1F0 && port <= 0x1F7 || port == 0x3F6 {
		m.ide_hist[m.ide_count % IDE_HISTORY] = t
		m.ide_count += 1
	}
	return v
}

@(private = "file")
machine_io_write :: proc(ctx: rawptr, port: u16, size: u8, val: u32) {
	m := (^Machine)(ctx)
	t := Io_Trace {
		port  = port,
		write = true,
		size  = size,
		val   = val,
	}
	m.io_hist[m.io_count % IO_HISTORY] = t
	m.io_count += 1
	if port >= 0x1F0 && port <= 0x1F7 || port == 0x3F6 {
		m.ide_hist[m.ide_count % IDE_HISTORY] = t
		m.ide_count += 1
	}
	if port == 0x1F7 {
		lba :=
			u32(m.ide.reg_lba_lo) |
			u32(m.ide.reg_lba_mid) << 8 |
			u32(m.ide.reg_lba_hi) << 16 |
			u32(m.ide.reg_drive & 0x0F) << 24
		m.cmd_hist[m.cmd_count % IDE_HISTORY] = Ide_Cmd_Trace {
			cmd   = u8(val),
			drive = m.ide.reg_drive,
			count = m.ide.reg_seccount,
			lba   = lba,
		}
		m.cmd_count += 1
	}
	bus_io_write(&m.bus, port, size, val)
}

// no MMIO devices exist yet: known probe zones read FF / swallow writes
// (logged once); anything else freezes loudly
@(private = "file")
machine_mmio :: proc(ctx: rawptr, gpa: u64, write: bool, data: []u8) {
	m := (^Machine)(ctx)
	if !write {
		for i in 0 ..< len(data) {data[i] = 0xFF}
	}
	zone, tolerated := machine_mmio_zone(gpa)
	if tolerated {
		if !m.mmio_seen[zone] {
			m.mmio_seen[zone] = true
			log.warnf(
				"tolerated MMIO probe (%v): %s gpa=0x%08x size=%d",
				zone,
				write ? "write" : "read",
				gpa,
				len(data),
			)
		}
		return
	}
	bus_freeze(
		&m.bus,
		fmt.tprintf("unknown MMIO %s gpa=0x%x size=%d", write ? "write" : "read", gpa, len(data)),
	)
}

@(private = "file")
machine_mmio_zone :: proc(gpa: u64) -> (Mmio_Zone, bool) {
	switch {
	case gpa >= 0xFEC0_0000 && gpa < 0xFEC0_1000:
		return .Ioapic, true
	case gpa >= 0xFEE0_0000 && gpa < 0xFEE0_1000:
		return .Lapic, true
	case gpa >= 0xE000_0000 && gpa < 0xF000_0000:
		return .Mmconfig, true
	case gpa >= 0x8000_0000 && gpa < 0xFEC0_0000:
		return .Pci_Window, true
	}
	return .Ioapic, false
}

// --- IRQ lines ---

@(private = "file")
machine_irq1 :: proc(ctx: rawptr) {
	m := (^Machine)(ctx)
	pic_raise(&m.pic, 1)
}

@(private = "file")
machine_irq6 :: proc(ctx: rawptr) {
	m := (^Machine)(ctx)
	pic_raise(&m.pic, 6)
}

@(private = "file")
machine_irq14 :: proc(ctx: rawptr) {
	m := (^Machine)(ctx)
	pic_raise(&m.pic, 14)
}

@(private = "file")
machine_irq15 :: proc(ctx: rawptr) {
	m := (^Machine)(ctx)
	pic_raise(&m.pic, 15)
}

// --- FDC / DMA channel 2 glue ---

@(private = "file")
machine_fdc_dma_to_mem :: proc(ctx: rawptr, data: []u8) {
	m := (^Machine)(ctx)
	dma_write_mem(&m.dma, 2, m.vm.ram, data)
}

@(private = "file")
machine_fdc_dma_from_mem :: proc(ctx: rawptr, buf: []u8) -> int {
	m := (^Machine)(ctx)
	tmp := dma_read_mem(&m.dma, 2, m.vm.ram, len(buf))
	defer delete(tmp)
	return copy(buf, tmp)
}

// channel 2 TC for the transfer in flight: the status bit is sticky until
// port 8 is read and SeaBIOS never reads it between transfers
@(private = "file")
machine_fdc_dma_tc :: proc(ctx: rawptr) -> bool {
	m := (^Machine)(ctx)
	return m.dma.ch[2].tc
}

@(private)
machine_guest_reset :: proc(ctx: rawptr) {
	m := (^Machine)(ctx)
	m.reset_requested = true
	bus_freeze(&m.bus, "guest requested reset")
}

// --- per-device adapters; multi-byte access splits into successive ports ---

@(private = "file")
machine_pic_read :: proc(ctx: rawptr, port: u16, size: u8) -> u32 {
	m := (^Machine)(ctx)
	v: u32 = 0
	for i in 0 ..< int(size) {v |= u32(pic_in(&m.pic, port + u16(i))) << (8 * uint(i))}
	return v
}

@(private = "file")
machine_pic_write :: proc(ctx: rawptr, port: u16, size: u8, val: u32) {
	m := (^Machine)(ctx)
	for i in 0 ..< int(size) {pic_out(&m.pic, port + u16(i), u8(val >> (8 * uint(i))))}
	// EOI with more IRQs queued: WHPX clears the window notification when it
	// delivers an injection, so re-arm it here (mid-run, guest still in the
	// handler) to get an exit at IRET instead of waiting for the vCPU pacer
	if m.vm.part != nil && pic_has_pending(&m.pic) {
		hv.request_irq_window(&m.vm, true)
	}
}

@(private = "file")
machine_pit_read :: proc(ctx: rawptr, port: u16, size: u8) -> u32 {
	m := (^Machine)(ctx)
	v: u32 = 0
	for i in 0 ..< int(size) {v |= u32(pit_in(&m.pit, port + u16(i))) << (8 * uint(i))}
	return v
}

@(private = "file")
machine_pit_write :: proc(ctx: rawptr, port: u16, size: u8, val: u32) {
	m := (^Machine)(ctx)
	for i in 0 ..< int(size) {pit_out(&m.pit, port + u16(i), u8(val >> (8 * uint(i))))}
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
	for i in 0 ..< int(size) {v |= u32(cmos_in(&m.cmos, port + u16(i))) << (8 * uint(i))}
	return v
}

@(private = "file")
machine_cmos_write :: proc(ctx: rawptr, port: u16, size: u8, val: u32) {
	m := (^Machine)(ctx)
	for i in 0 ..< int(size) {cmos_out(&m.cmos, port + u16(i), u8(val >> (8 * uint(i))))}
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
	for i in 0 ..< int(size) {v |= u32(dma_in(&m.dma, port + u16(i))) << (8 * uint(i))}
	return v
}

@(private = "file")
machine_dma_write :: proc(ctx: rawptr, port: u16, size: u8, val: u32) {
	m := (^Machine)(ctx)
	for i in 0 ..< int(size) {dma_out(&m.dma, port + u16(i), u8(val >> (8 * uint(i))))}
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

machine_reset_control_read :: proc(ctx: rawptr, port: u16, size: u8) -> u32 {
	m := (^Machine)(ctx)
	return u32(m.reset_control)
}

machine_reset_control_write :: proc(ctx: rawptr, port: u16, size: u8, val: u32) {
	if size != 1 {return}
	m := (^Machine)(ctx)
	m.reset_control = u8(val) & 0x02
	if val & 0x04 != 0 {machine_guest_reset(m)}
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
	for i in 0 ..< int(size) {v |= u32(video.vga_in(&m.vga, port + u16(i))) << (8 * uint(i))}
	return v
}

@(private = "file")
machine_vga_write :: proc(ctx: rawptr, port: u16, size: u8, val: u32) {
	m := (^Machine)(ctx)
	for i in 0 ..< int(size) {video.vga_out(&m.vga, port + u16(i), u8(val >> (8 * uint(i))))}
}

@(private = "file")
machine_fdc_read :: proc(ctx: rawptr, port: u16, size: u8) -> u32 {
	m := (^Machine)(ctx)
	v: u32 = 0
	for i in 0 ..< int(size) {v |= u32(disk.fdc_in(&m.fdc, port + u16(i))) << (8 * uint(i))}
	return v
}

@(private = "file")
machine_fdc_write :: proc(ctx: rawptr, port: u16, size: u8, val: u32) {
	m := (^Machine)(ctx)
	for i in 0 ..< int(size) {disk.fdc_out(&m.fdc, port + u16(i), u8(val >> (8 * uint(i))))}
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

@(private = "file")
machine_atapi_read :: proc(ctx: rawptr, port: u16, size: u8) -> u32 {
	m := (^Machine)(ctx)
	return disk.atapi_io_read(&m.atapi, port, size)
}

@(private = "file")
machine_atapi_write :: proc(ctx: rawptr, port: u16, size: u8, val: u32) {
	m := (^Machine)(ctx)
	disk.atapi_io_write(&m.atapi, port, size, val)
}

// SeaBIOS debug console: reads must return 0xE9 or SeaBIOS disables it
@(private = "file")
machine_dbg_read :: proc(ctx: rawptr, port: u16, size: u8) -> u32 {
	return 0xE9
}

@(private = "file")
machine_dbg_write :: proc(ctx: rawptr, port: u16, size: u8, val: u32) {
	m := (^Machine)(ctx)
	append(&m.dbg_out, u8(val))
}
