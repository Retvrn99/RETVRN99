// SPDX-License-Identifier: GPL-3.0-only
package machine

import sound "../audio"
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
MACHINE_GOVERNOR_QUANTUM_NS :: u64(1_000_000)
MACHINE_NO_WAKE_NS :: u64(86_400_000_000_000)
MACHINE_CDDA_PENDING_FRAMES :: disk.DISC_RAW_SECTOR_SIZE / size_of(sound.Audio_Frame) * 2

Wake_Schedule_Proc :: proc(ctx: rawptr, delay_ns: u64, pending: bool)

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
	using platform:      Pc_At_Platform,
	pci:                 Pci,
	fwcfg:               Fwcfg,
	vga:                 video.Vga,
	gsw_vga:             video.Gsw_Vga,
	ide:                 disk.Ide,
	atapi:               disk.Atapi,
	bmide:               disk.Bmide,
	audio:               sound.Audio_Mixer,
	cdda_pending:        [MACHINE_CDDA_PENDING_FRAMES]sound.Audio_Frame,
	cdda_pending_count:  int,
	fdc:                 disk.Fdc,
	test_device:         Test_Device,
	test_device_enabled: bool,
	has_disk:            bool,
	vm:                  hv.Vm,
	governor:            hv.Governor,
	cpu_mode:            config.Cpu_Mode,
	idle_waiter:         hosttime.Waiter,
	scheduler:           Event_Scheduler,
	timeline:            Master_Timeline,
	time_source:         Master_Source_Phase,
	nanosecond_phase:    Rate_Phase,
	active_tick:         time.Tick,
	active_ns:           u64,
	cmos_active_ns:      u64,
	clock_running:       bool,
	wake_ctx:            rawptr,
	wake_schedule:       Wake_Schedule_Proc,
	wake_deadline:       u64,
	wake_scheduled:      bool,
	wake_arms:           u64,
	io_string_depth:     u32,
	yield_requested:     bool,
	governor_deadline:   u64,
	device_advances:     [SCHEDULED_DEVICE_COUNT]u64,
	device_sync_tick:    [SCHEDULED_DEVICE_COUNT]u64,
	device_sync_valid:   [SCHEDULED_DEVICE_COUNT]bool,
	diagnostic_tracing:  bool,
	scanout_copies:      u64,
	cpu_halted:          bool,
	dbg_out:             [dynamic]u8, // firmware debug ports 0x402 and 0x500
	mmio_seen:           [Mmio_Zone]bool, // log tolerated zones only once
	exit_hist:           [EXIT_HISTORY]hv.Exit_Kind, // ring, exit_count % EXIT_HISTORY
	exit_count:          u64,
	io_hist:             [IO_HISTORY]Io_Trace, // ring, io_count % IO_HISTORY
	io_count:            u64,
	ide_hist:            [IDE_HISTORY]Io_Trace, // ring of IDE-port accesses only
	ide_count:           u64,
	cmd_hist:            [IDE_HISTORY]Ide_Cmd_Trace, // ring of IDE commands
	cmd_count:           u64,
	inj_count:           [256]u64, // injected IRQ vectors
}

machine_init :: proc(m: ^Machine, ram_size: int) -> bool {
	bus_init(&m.bus)
	if !hv.create(&m.vm, ram_size) {return false}
	if !hv.reserve_mmio(
		&m.vm,
		video.LEGACY_APERTURE_BASE,
		video.LEGACY_APERTURE_END - video.LEGACY_APERTURE_BASE,
	) {
		hv.destroy(&m.vm)
		return false
	}
	vram, vram_ok := hv.map_device_memory(&m.vm, video.VBE_LFB_BASE, video.VRAM_SIZE)
	if !vram_ok || !video.vga_init(&m.vga, vram) {
		hv.destroy(&m.vm)
		return false
	}
	video.vga_set_deferred_scanout(&m.vga, true)
	if !hv.governor_init(&m.governor, &m.vm, .GSW_886) {
		video.vga_destroy(&m.vga)
		hv.destroy(&m.vm)
		return false
	}
	video.gsw_vga_init(&m.gsw_vga, vram)
	video.gsw_vga_attach_scanout(&m.gsw_vga, &m.vga)
	video.gsw_vga_set_irq(&m.gsw_vga, m, machine_gsw_vga_irq)
	m.cpu_mode = .GSW_886
	event_scheduler_init(&m.scheduler)
	if !sound.audio_mixer_init(&m.audio) {
		video.vga_destroy(&m.vga)
		hv.destroy(&m.vm)
		return false
	}
	hosttime.waiter_init(&m.idle_waiter)
	m.vm.io_ctx = m
	m.vm.io_read = machine_io_read
	m.vm.io_write = machine_io_write
	m.vm.io_stream_read = machine_io_stream_read
	m.vm.io_stream_write = machine_io_stream_write
	m.vm.io_string_budget = machine_io_string_budget
	m.vm.io_string_begin = machine_io_string_begin
	m.vm.io_string_end = machine_io_string_end
	m.vm.io_should_yield = machine_io_should_yield
	m.vm.mmio = machine_mmio

	cmos_init(&m.cmos, u64(ram_size))
	now := time.now()
	year, month, day := time.date(now)
	hh, mm, ss := time.clock_from_time(now)
	weekday := int(time.weekday(now)) + 1
	cmos_set_datetime(&m.cmos, u16(year), u8(month), u8(day), u8(weekday), u8(hh), u8(mm), u8(ss))
	i8042_init(&m.kbd, m, machine_irq1, machine_irq12, machine_guest_reset, machine_a20_control)
	i8042_set_irq_lower_callbacks(&m.kbd, machine_irq1_lower, machine_irq12_lower)
	uart_init_com1(&m.serial1)
	uart_init_com2(&m.serial2)
	lpt_init_lpt1(&m.parallel1)
	lpt_init_lpt2(&m.parallel2)
	dma_init(&m.dma)
	pci_init(&m.pci)
	pci_connect_pic(&m.pci, &m.pic)
	disk.bmide_init(&m.bmide)
	fwcfg_init(&m.fwcfg, u64(ram_size))
	// SeaBIOS vgarom_setup memsets 0xC0000 and then deploys "vgaroms/"
	// romfiles: the Bochs VGABIOS image must arrive through fw_cfg
	fwcfg_add_file(&m.fwcfg, "vgaroms/vgabios.bin", VGABIOS_IMAGE, 0x0021)

	pic_h := Io_Handler {
		ctx   = m,
		read  = machine_pic_read,
		write = machine_pic_write,
	}
	bus_register(&m.bus, 0x20, 0x21, pic_h)
	bus_register(&m.bus, 0xA0, 0xA1, pic_h)
	bus_register(&m.bus, 0x4D0, 0x4D1, pic_h)

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

	serial_h := Io_Handler {
		ctx   = m,
		read  = machine_uart_read,
		write = machine_uart_write,
	}
	bus_register_byte_decomposed(&m.bus, UART_COM1_BASE, UART_COM1_BASE + 7, serial_h)
	bus_register_byte_decomposed(&m.bus, UART_COM2_BASE, UART_COM2_BASE + 7, serial_h)

	parallel_h := Io_Handler {
		ctx   = m,
		read  = machine_lpt_read,
		write = machine_lpt_write,
	}
	bus_register_byte_decomposed(&m.bus, LPT1_BASE, LPT1_BASE + 2, parallel_h)
	bus_register_byte_decomposed(&m.bus, LPT2_BASE, LPT2_BASE + 2, parallel_h)

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
	for port := u16(0xC0); port <= 0xDE; port += 2 {
		bus_register(&m.bus, port, port, dma_h)
	}
	dma_page_ports := [?]u16 {
		0x81,
		0x82,
		0x83,
		0x84,
		0x85,
		0x86,
		0x87,
		0x88,
		0x89,
		0x8A,
		0x8B,
		0x8C,
		0x8D,
		0x8E,
		0x8F,
	}
	for port in dma_page_ports {
		bus_register(&m.bus, port, port, dma_h)
	}

	delay_h := Io_Handler {
		ctx   = m,
		read  = machine_isa_delay_read,
		write = machine_isa_delay_write,
	}
	bus_register(&m.bus, 0x80, 0x80, delay_h)

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
	bus_register(&m.bus, video.DISPI_PORT_INDEX, video.DISPI_PORT_DATA, vga_h)

	dbg_h := Io_Handler {
		ctx   = m,
		read  = machine_dbg_read,
		write = machine_dbg_write,
	}
	bus_register(&m.bus, 0x402, 0x402, dbg_h)
	bus_register(&m.bus, 0x500, 0x500, dbg_h)

	// deliberate whitelist: probed but not modeled yet
	bus_whitelist(&m.bus, 0x80, 0xED) // POST + delay
	machine_whitelist_range(&m.bus, 0x1F0, 0x1F7) // IDE until machine_attach_disk
	bus_whitelist(&m.bus, 0x3F6)
	machine_init_fdc(m)
	machine_init_atapi(m)
	machine_whitelist_range(&m.bus, 0x3E8, 0x3EF) // COM3 probe by SeaBIOS serial_setup; absent
	machine_whitelist_range(&m.bus, 0x2E8, 0x2EF) // COM4 probe by SeaBIOS serial_setup; absent
	machine_whitelist_range(&m.bus, 0x2F2, 0x2F7) // IO.SYS boot probe: writes 0xFF here (tertiary FDC range); absent
	machine_whitelist_range(&m.bus, 0x6F2, 0x6F7) // same IO.SYS probe series, stride 0x400
	machine_whitelist_range(&m.bus, 0x1E8, 0x1EF) // IDE tertiary: Win98 boot-disk ATAPI driver probe; absent
	machine_whitelist_range(&m.bus, 0x168, 0x16F) // IDE quaternary, same driver probe series
	bus_whitelist(&m.bus, 0x36E, 0x36F) // IDE quaternary device control, same probe (tertiary's 0x3EE is inside the COM3 range above)
	// Known-absent ISA game, sound, SCSI, and network adapter probe windows.
	machine_whitelist_range(&m.bus, 0x130, 0x13F)
	machine_whitelist_range(&m.bus, 0x200, 0x207)
	machine_whitelist_range(&m.bus, 0x220, 0x22F)
	machine_whitelist_range(&m.bus, 0x230, 0x23F)
	machine_whitelist_range(&m.bus, 0x240, 0x24F)
	machine_whitelist_range(&m.bus, 0x280, 0x29F)
	machine_whitelist_range(&m.bus, 0x300, 0x31F)
	machine_whitelist_range(&m.bus, 0x330, 0x35F)
	machine_whitelist_range(&m.bus, 0x388, 0x38B)
	bus_whitelist(&m.bus, 0xA79) // ISA PnP write-data, ASPI2DOS card isolation (address port 0x279 sits in the LPT2 range above)
	// ISA PnP read-data candidates: ASPI2DOS walks 0x20B, 0x22B, ... 0x3EB until isolation finds a card (it never will)
	for p := u16(0x20B); p <= 0x3EB; p += 0x20 {bus_whitelist(&m.bus, p)}
	machine_clock_set_running(m, true)
	return true
}

machine_destroy :: proc(m: ^Machine) {
	_ = disk.ide_checkpoint(&m.ide)
	machine_clock_set_running(m, false)
	disk.bmide_reset_channel(&m.bmide, 0)
	disk.bmide_reset_channel(&m.bmide, 1)
	disk.fdc_eject_media(&m.fdc)
	disk.atapi_eject(&m.atapi)
	hosttime.waiter_destroy(&m.idle_waiter)
	hv.governor_destroy(&m.governor)
	video.vga_destroy(&m.vga)
	hv.destroy(&m.vm)
	fwcfg_destroy(&m.fwcfg)
	bus_destroy(&m.bus)
	delete(m.dbg_out)
}

// moves the collected firmware debug bytes into sink and clears the buffer
machine_drain_dbg :: proc(m: ^Machine, sink: ^[dynamic]u8) {
	append(sink, ..m.dbg_out[:])
	clear(&m.dbg_out)
}

// stores the device and takes over the IDE ports whitelisted at init
machine_attach_disk :: proc(m: ^Machine, bd: disk.Block_Device) {
	disk.bmide_reset_channel(&m.bmide, 0)
	disk.ide_init(&m.ide, bd)
	m.ide.irq_ctx = m
	m.ide.irq = machine_irq14
	m.has_disk = true
	h := Io_Handler {
		ctx   = m,
		read  = machine_ide_read,
		write = machine_ide_write,
		stream_read = machine_ide_stream_read,
		stream_write = machine_ide_stream_write,
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
	if m == nil {return}
	m.cpu_mode = mode
	hv.governor_set_mode(&m.governor, &m.vm, mode)
	if mode == .GSW_886 {
		now := master_timeline_now(m.timeline)
		quantum := MASTER_CLOCK_HZ * MACHINE_GOVERNOR_QUANTUM_NS / NANOSECOND_HZ
		m.governor_deadline = now + min(quantum, ~u64(0) - now)
	} else {
		m.governor_deadline = 0
	}
	machine_scheduler_refresh(m)
	machine_rearm_wake(m)
}

machine_init_atapi :: proc(m: ^Machine) {
	disk.atapi_init(&m.atapi)
	m.atapi.irq_ctx = m
	m.atapi.irq = machine_irq15
	disk.atapi_set_cdda_output(&m.atapi, m, machine_cdda_frame)
	h := Io_Handler {
		ctx   = m,
		read  = machine_atapi_read,
		write = machine_atapi_write,
		stream_read = machine_atapi_stream_read,
		stream_write = machine_atapi_stream_write,
	}
	bus_register(&m.bus, 0x170, 0x177, h)
	bus_register(&m.bus, 0x376, 0x376, h)
}

machine_mount_cdrom :: proc(m: ^Machine, path: string) -> bool {
	disk.bmide_reset_channel(&m.bmide, 1)
	machine_audio_reset_cdda(m)
	return disk.atapi_mount(&m.atapi, path)
}

machine_attach_cdrom :: proc(m: ^Machine, path: string) -> bool {
	disk.bmide_reset_channel(&m.bmide, 1)
	machine_audio_reset_cdda(m)
	return disk.atapi_attach(&m.atapi, path)
}

machine_eject_cdrom :: proc(m: ^Machine) {
	disk.bmide_reset_channel(&m.bmide, 1)
	disk.atapi_eject(&m.atapi)
	machine_audio_reset_cdda(m)
}

machine_enable_test_device :: proc(m: ^Machine) {
	if m == nil || m.test_device_enabled {return}
	h := Io_Handler {
		ctx   = m,
		read  = machine_test_device_read,
		write = machine_test_device_write,
	}
	bus_register_byte_decomposed(&m.bus, TEST_DEVICE_INDEX_PORT, TEST_DEVICE_COMMAND_PORT, h)
	m.test_device_enabled = true
}

machine_test_device_take_command :: proc(m: ^Machine) -> Test_Device_Command {
	if m == nil || !m.test_device_enabled {return .None}
	return test_device_take_command(&m.test_device)
}

machine_test_device_frame_crc :: proc(m: ^Machine) -> u32 {
	if m == nil || !m.test_device_enabled {return 0}
	frame := machine_display_frame(m)
	crc := test_device_frame_crc(frame, test_device_rect(&m.test_device))
	test_device_set_crc(&m.test_device, crc)
	return crc
}

machine_test_device_exit_code :: proc(m: ^Machine) -> u8 {
	if m == nil || !m.test_device_enabled {return 0}
	return test_device_exit_code(&m.test_device)
}

machine_audio_output :: proc(m: ^Machine) -> ^sound.Audio_Output {
	if m == nil {return nil}
	return sound.audio_mixer_output(&m.audio)
}

machine_audio_metrics :: proc(m: ^Machine) -> sound.Audio_Metrics_Snapshot {
	if m == nil {return {}}
	return sound.audio_output_metrics(sound.audio_mixer_output(&m.audio))
}

Machine_Execution_Counters :: struct {
	hypervisor_runs:          u64,
	hypervisor_cancellations: u64,
	timer_arms:               u64,
	scheduler_dispatches:     u64,
	device_advances:          u64,
	storage_transactions:     u64,
	storage_host_calls:       u64,
	storage_bytes:            u64,
	audio_blocks:             u64,
	scanout_copies:           u64,
	full_frame_renders:       u64,
	software_rendered_pixels: u64,
}

machine_execution_counters :: proc(m: ^Machine) -> Machine_Execution_Counters {
	if m == nil {return {}}
	advances: u64
	for count in m.device_advances {advances += count}
	return {
		hypervisor_runs          = m.vm.run_calls,
		hypervisor_cancellations = m.vm.run_cancellations,
		timer_arms               = m.wake_arms,
		scheduler_dispatches     = m.scheduler.dispatches,
		device_advances          = advances,
		storage_transactions     = m.bmide.transactions,
		storage_host_calls       = m.bmide.host_calls,
		storage_bytes            = m.bmide.bytes_moved,
		audio_blocks             = sound.audio_mixer_blocks_rendered(&m.audio),
		scanout_copies           = m.scanout_copies,
		full_frame_renders       = m.vga.full_frame_renders,
		software_rendered_pixels = m.vga.raster_pixels_rendered + m.gsw_vga.metrics.software_pixels,
	}
}

machine_note_scanout_copy :: proc(m: ^Machine) {
	if m != nil {m.scanout_copies += 1}
}

machine_cmos_export :: proc(m: ^Machine) -> [CMOS_NVRAM_SIZE]u8 {
	return cmos_nvram_export(&m.cmos)
}

machine_cmos_import :: proc(m: ^Machine, data: []u8) -> bool {
	ok := cmos_nvram_import(&m.cmos, data, u64(len(m.vm.ram)))
	if ok {
		m.cmos_active_ns = m.active_ns
		m.device_sync_valid[int(Scheduled_Device.Cmos)] = false
	}
	return ok
}

machine_reset_requested :: proc(m: ^Machine) -> bool {
	return m != nil && m.reset_requested
}

machine_reset_provenance :: proc(m: ^Machine) -> Reset_Provenance {
	return m != nil ? m.reset_source : .None
}

machine_reset_record_count :: proc(m: ^Machine) -> int {
	return m != nil ? int(min(m.reset_count, u64(PC_AT_RESET_HISTORY))) : 0
}

machine_reset_record :: proc(m: ^Machine, index: int) -> (Reset_Record, bool) {
	count := machine_reset_record_count(m)
	if index < 0 || index >= count {return {}, false}
	oldest := m.reset_count - u64(count)
	return m.reset_history[(oldest + u64(index)) % PC_AT_RESET_HISTORY], true
}

machine_cpu_reset_pending :: proc(m: ^Machine) -> bool {
	return m != nil && m.cpu_reset_pending
}

machine_cpu_reset_reason :: proc(m: ^Machine) -> string {
	return m != nil ? m.cpu_reset_reason : ""
}

machine_cpu_reset :: proc(m: ^Machine) -> bool {
	if m == nil || !m.cpu_reset_pending {return false}
	reason := m.cpu_reset_reason
	if !hv.reset_cpu(&m.vm) {
		bus_freeze(&m.bus, fmt.tprintf("CPU reset failed after %s", reason))
		return false
	}
	m.cpu_reset_pending = false
	m.cpu_reset_reason = ""
	m.cpu_halted = false
	m.cpu_reset_count += 1
	hv.governor_rebase(&m.governor, &m.vm)
	m.active_tick = time.tick_now()
	return true
}

machine_mouse :: proc(m: ^Machine, dx, dy: i32, buttons: u8) {
	if m == nil {return}
	machine_sync_time(m)
	machine_sync_device(m, .I8042)
	i8042_mouse(&m.kbd, dx, dy, buttons)
	machine_rearm_wake(m)
}

machine_set_diagnostic_tracing :: proc(m: ^Machine, enabled: bool) {
	if m == nil {return}
	m.diagnostic_tracing = enabled
	m.bus.diagnostic_tracing = enabled || m.bus.strict_io || m.bus.log_unclassified
}

machine_mouse_wheel :: proc(m: ^Machine, wheel: i32, buttons: u8) {
	if m == nil {return}
	machine_sync_time(m)
	machine_sync_device(m, .I8042)
	i8042_mouse(&m.kbd, 0, 0, buttons)
	i8042_mouse_wheel(&m.kbd, wheel)
	machine_rearm_wake(m)
}

machine_key :: proc(m: ^Machine, scancode: u8) {
	if m == nil {return}
	machine_sync_time(m)
	machine_sync_device(m, .I8042)
	i8042_key(&m.kbd, scancode)
	machine_rearm_wake(m)
}

machine_clock_set_running :: proc(m: ^Machine, running: bool) {
	if m == nil {return}
	if m.clock_running && !running {machine_sync_time(m)}
	if !m.clock_running && running {
		now := time.now()
		year, month, day := time.date(now)
		hh, mm, ss := time.clock_from_time(now)
		weekday := int(time.weekday(now)) + 1
		cmos_set_datetime(&m.cmos, u16(year), u8(month), u8(day), u8(weekday), u8(hh), u8(mm), u8(ss))
		m.cmos_active_ns = m.active_ns
		m.device_sync_valid[int(Scheduled_Device.Cmos)] = false
	}
	if m.vm.part != nil && !hv.set_time_running(&m.vm, running) {
		bus_freeze(
			&m.bus,
			running ? "failed to resume partition time" : "failed to suspend partition time",
		)
		return
	}
	m.clock_running = running
	m.active_tick = time.tick_now()
}

machine_set_wake_adapter :: proc(m: ^Machine, ctx: rawptr, schedule: Wake_Schedule_Proc) {
	if m == nil {return}
	m.wake_ctx = ctx
	m.wake_schedule = schedule
	m.wake_scheduled = false
	machine_rearm_wake(m)
}

@(private = "file")
machine_next_wake_event :: proc(m: ^Machine) -> (Scheduled_Event, bool) {
	if m == nil {return {}, false}
	machine_scheduler_refresh(m)
	return event_scheduler_next(&m.scheduler)
}

machine_next_wake_ns :: proc(m: ^Machine) -> u64 {
	if m == nil {return MACHINE_NO_WAKE_NS}
	now := master_timeline_now(m.timeline)
	event, pending := machine_next_wake_event(m)
	if !pending {return MACHINE_NO_WAKE_NS}
	delta := event.deadline > now ? event.deadline - now : 1
	return max(
		u64((u128(delta) * 1_000_000_000 + u128(MASTER_CLOCK_HZ - 1)) / u128(MASTER_CLOCK_HZ)),
		u64(1),
	)
}

@(private = "file")
machine_scheduler_set :: proc(
	m: ^Machine,
	device: Scheduled_Device,
	deadline: u64,
	pending: bool,
) {
	if pending {event_scheduler_set(&m.scheduler, device, deadline)} else {event_scheduler_clear(&m.scheduler, device)}
}

@(private = "file")
machine_relative_ns_deadline :: proc(m: ^Machine, delta_ns: u64) -> u64 {
	now := master_timeline_now(m.timeline)
	delta, running := rate_phase_ticks_until(m.nanosecond_phase, delta_ns, NANOSECOND_HZ)
	if !running {return ~u64(0)}
	return now + min(max(delta, u64(1)), ~u64(0) - now)
}

@(private = "package")
machine_scheduler_refresh :: proc(m: ^Machine) {
	if m == nil {return}
	if !m.scheduler.initialized {event_scheduler_init(&m.scheduler)}
	deadline, pending := pit_next_deadline(&m.pit)
	machine_scheduler_set(m, .Pit, deadline, pending)
	deadline, pending = uart_next_deadline(&m.serial1)
	machine_scheduler_set(m, .Uart1, deadline, pending)
	deadline, pending = uart_next_deadline(&m.serial2)
	machine_scheduler_set(m, .Uart2, deadline, pending)
	deadline, pending = lpt_next_deadline(&m.parallel1)
	machine_scheduler_set(m, .Lpt1, deadline, pending)
	deadline, pending = lpt_next_deadline(&m.parallel2)
	machine_scheduler_set(m, .Lpt2, deadline, pending)
	deadline, pending = dma_next_deadline(&m.dma)
	machine_scheduler_set(m, .Dma, deadline, pending)
	deadline, pending = disk.fdc_next_deadline(&m.fdc)
	machine_scheduler_set(m, .Fdc, deadline, pending)
	deadline, pending = disk.ide_next_deadline(&m.ide)
	machine_scheduler_set(m, .Ide, deadline, pending)
	deadline, pending = disk.atapi_next_deadline(&m.atapi)
	machine_scheduler_set(m, .Atapi, deadline, pending)
	deadline, pending = disk.bmide_next_deadline(&m.bmide)
	machine_scheduler_set(m, .Bmide, deadline, pending)
	if delta_ns, ok := i8042_next_deadline_ns(&m.kbd); ok {
		machine_scheduler_set(m, .I8042, machine_relative_ns_deadline(m, delta_ns), true)
	} else {
		machine_scheduler_set(m, .I8042, 0, false)
	}
	machine_scheduler_set(
		m,
		.Cmos,
		machine_relative_ns_deadline(m, cmos_next_deadline_ns(&m.cmos)),
		true,
	)
	deadline, pending = sound.audio_mixer_next_deadline_tick(&m.audio)
	machine_scheduler_set(m, .Audio, deadline, pending)
	if m.cpu_mode == .GSW_886 {
		now := master_timeline_now(m.timeline)
		quantum := MASTER_CLOCK_HZ * MACHINE_GOVERNOR_QUANTUM_NS / NANOSECOND_HZ
		if m.governor_deadline == 0 {
			m.governor_deadline = now + min(quantum, ~u64(0) - now)
		}
		machine_scheduler_set(m, .Governor, m.governor_deadline, true)
	} else {
		machine_scheduler_set(m, .Governor, 0, false)
	}
}

machine_rearm_wake :: proc(m: ^Machine) {
	if m == nil || m.io_string_depth != 0 || m.wake_schedule == nil {return}
	event, pending := machine_next_wake_event(m)
	if !pending {
		if m.wake_scheduled {m.wake_schedule(m.wake_ctx, 0, false)}
		m.wake_scheduled = false
		m.wake_deadline = 0
		return
	}
	if m.wake_scheduled && m.wake_deadline == event.deadline {return}
	now := master_timeline_now(m.timeline)
	delta := event.deadline > now ? event.deadline - now : 1
	delay_ns := max(
		u64((u128(delta) * 1_000_000_000 + u128(MASTER_CLOCK_HZ - 1)) / u128(MASTER_CLOCK_HZ)),
		u64(1),
	)
	m.wake_schedule(m.wake_ctx, delay_ns, true)
	m.wake_arms += 1
	m.wake_scheduled = true
	m.wake_deadline = event.deadline
}

@(private = "file")
machine_io_string_budget :: proc(ctx: rawptr) -> u64 {
	m := (^Machine)(ctx)
	deadline_ns := machine_next_wake_ns(m)
	if deadline_ns <= 10_000 {return 1}
	if deadline_ns <= 100_000 {return 64}
	if deadline_ns <= 1_000_000 {return 512}
	return 4096
}

@(private = "package")
machine_io_string_begin :: proc(ctx: rawptr) {
	m := (^Machine)(ctx)
	if m.io_string_depth == 0 {machine_sync_time(m)}
	m.io_string_depth += 1
}

@(private = "package")
machine_io_string_end :: proc(ctx: rawptr) {
	m := (^Machine)(ctx)
	assert(m.io_string_depth > 0)
	m.io_string_depth -= 1
	if m.io_string_depth == 0 {
		machine_sync_time(m)
		machine_rearm_wake(m)
	}
}

@(private = "file")
machine_master_deadline :: proc(m: ^Machine, target: u64) -> u64 {
	now := master_timeline_now(m.timeline)
	machine_scheduler_refresh(m)
	if event, pending := event_scheduler_next(&m.scheduler); pending {
		return min(target, max(event.deadline, now + min(u64(1), ~u64(0) - now)))
	}
	return target
}

@(private = "file")
machine_advance_devices_to :: proc(m: ^Machine, target_tick: u64) {
	elapsed_ticks := master_timeline_advance_to(&m.timeline, target_tick)
	elapsed_ns := master_ticks_to_nanoseconds(&m.nanosecond_phase, elapsed_ticks)
	m.active_ns += elapsed_ns
	now := master_timeline_now(m.timeline)
	for {
		event, due := event_scheduler_take_due(&m.scheduler, now)
		if !due {break}
		machine_advance_device(m, event.device)
		machine_scheduler_refresh(m)
	}
}

@(private = "file")
machine_advance_device :: proc(m: ^Machine, device: Scheduled_Device) {
	now := master_timeline_now(m.timeline)
	m.device_advances[int(device)] += 1
	switch device {
	case .Pit:
		for _ in 0 ..< pit_advance_to(&m.pit, now) {pic_raise(&m.pic, 0)}
		machine_audio_apply_pit_transitions(m)
	case .Uart1:
		uart_advance_to(&m.serial1, now)
		if uart_take_irq(&m.serial1) {pic_raise(&m.pic, uart_irq_number(&m.serial1))}
	case .Uart2:
		uart_advance_to(&m.serial2, now)
		if uart_take_irq(&m.serial2) {pic_raise(&m.pic, uart_irq_number(&m.serial2))}
	case .Lpt1:
		lpt_advance_to(&m.parallel1, now)
		if lpt_take_irq(&m.parallel1) {pic_raise(&m.pic, lpt_irq_number(&m.parallel1))}
	case .Lpt2:
		lpt_advance_to(&m.parallel2, now)
		if lpt_take_irq(&m.parallel2) {pic_raise(&m.pic, lpt_irq_number(&m.parallel2))}
	case .Dma:
		_ = dma_advance_to(&m.dma, now, m.vm.ram)
	case .Fdc:
		disk.fdc_advance_to(&m.fdc, now)
	case .Ide:
		disk.ide_advance_to(&m.ide, now)
	case .Atapi:
		disk.atapi_advance_to(&m.atapi, now)
	case .Bmide:
		_ = disk.bmide_advance_to(&m.bmide, now, machine_bmide_memory(m))
		machine_bmide_poll_irqs(m)
	case .I8042:
		i8042_advance_to(&m.kbd, m.active_ns)
	case .Cmos:
		elapsed := m.active_ns - min(m.active_ns, m.cmos_active_ns)
		for _ in 0 ..< cmos_advance(&m.cmos, elapsed) {pic_raise(&m.pic, 8)}
		m.cmos_active_ns = m.active_ns
	case .Audio:
		machine_audio_advance_to(m, now)
	case .Governor:
		quantum := MASTER_CLOCK_HZ * MACHINE_GOVERNOR_QUANTUM_NS / NANOSECOND_HZ
		m.governor_deadline = now + min(quantum, ~u64(0) - now)
	case .Count:
	}
	if device != .Count {
		m.device_sync_tick[int(device)] = now
		m.device_sync_valid[int(device)] = true
	}
}

@(private = "file")
machine_sync_device :: proc(m: ^Machine, device: Scheduled_Device) {
	index := int(device)
	now := master_timeline_now(m.timeline)
	if m.device_sync_valid[index] && m.device_sync_tick[index] == now {return}
	machine_advance_device(m, device)
	machine_scheduler_refresh(m)
}

machine_advance_time_ns :: proc(m: ^Machine, nanoseconds: u64) {
	if m == nil || nanoseconds == 0 {return}
	master_ticks := master_source_advance_nanoseconds(&m.time_source, nanoseconds)
	if master_ticks == 0 {return}
	now := master_timeline_now(m.timeline)
	target := now + min(master_ticks, ~u64(0) - now)
	machine_scheduler_refresh(m)
	for now < target {
		machine_advance_devices_to(m, machine_master_deadline(m, target))
		now = master_timeline_now(m.timeline)
	}
}

machine_sync_time :: proc(m: ^Machine) {
	if m == nil || !m.clock_running || m.io_string_depth > 0 {return}
	now := time.tick_now()
	elapsed := max(time.Duration(0), time.tick_diff(m.active_tick, now))
	m.active_tick = now
	machine_advance_time_ns(m, u64(elapsed))
}

step :: proc(m: ^Machine) -> bool { 	// false = frozen/powered off
	machine_sync_time(m)
	injected := false
	if pic_has_pending(&m.pic) {
		if offer, offered := pic_interrupt_preview(&m.pic); offered {
			switch hv.try_inject_irq(&m.vm, offer.vector) {
			case .Injected:
				if !pic_interrupt_commit(&m.pic, offer) {
					bus_freeze(&m.bus, "PIC offer changed after interrupt injection")
					return false
				}
				m.inj_count[offer.vector] += 1
				injected = true
				if pic_has_pending(&m.pic) {hv.request_irq_window(&m.vm, true)}
			case .Deferred:
				hv.request_irq_window(&m.vm, true)
			case .Failed:
				bus_freeze(&m.bus, "WHPX interrupt injection failed")
				return false
			}
		} else {
			hv.request_irq_window(&m.vm, true)
		}
	}
	if m.cpu_halted {
		if injected {
			m.cpu_halted = false
		} else {
			machine_rearm_wake(m)
			delay_ns := machine_next_wake_ns(m)
			hosttime.waiter_sleep(&m.idle_waiter, time.Duration(max(delay_ns, u64(1))))
			machine_sync_time(m)
			return !m.bus.frozen
		}
	}
	machine_rearm_wake(m)
	ex := hv.run(&m.vm)
	if ex.kind == .Canceled {m.wake_scheduled = false}
	machine_sync_time(m)
	governor_ok := ex.kind != .Canceled || hv.governor_on_cancel(&m.governor, &m.vm)
	m.exit_hist[m.exit_count % EXIT_HISTORY] = ex.kind
	m.exit_count += 1
	if !governor_ok {
		bus_freeze(&m.bus, "GSW-886 runtime counters unavailable")
		return false
	}
	return machine_handle_exit(m, ex)
}

@(private)
machine_handle_exit :: proc(m: ^Machine, ex: hv.Exit) -> bool {
	#partial switch ex.kind {
	case .Halt:
		m.cpu_halted = true
	case .Reset:
		source :=
			m.cmos.ram[0x0F] == 0x0A ? Reset_Provenance.Dos_Extender_Warm_Resume : Reset_Provenance.Triple_Fault
		machine_record_reset(m, source)
		m.cpu_reset_pending = true
		m.cpu_reset_reason = ex.detail
		m.cpu_reset_cmos_0f = m.cmos.ram[0x0F]
		return false
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
machine_io_read :: proc(ctx: rawptr, port: u16, size: u8) -> (u32, bool) {
	m := (^Machine)(ctx)
	machine_sync_time(m)
	v := bus_io_read(&m.bus, port, size)
	t := Io_Trace {
		port  = port,
		write = false,
		size  = size,
		val   = v,
	}
	if m.diagnostic_tracing {m.io_hist[m.io_count % IO_HISTORY] = t}
	m.io_count += 1
	if port >= 0x1F0 && port <= 0x1F7 || port == 0x3F6 {
		if m.diagnostic_tracing {m.ide_hist[m.ide_count % IDE_HISTORY] = t}
		m.ide_count += 1
	}
	machine_rearm_wake(m)
	return v, !m.bus.frozen
}

@(private = "file")
machine_io_write :: proc(ctx: rawptr, port: u16, size: u8, val: u32) -> bool {
	m := (^Machine)(ctx)
	machine_sync_time(m)
	t := Io_Trace {
		port  = port,
		write = true,
		size  = size,
		val   = val,
	}
	if m.diagnostic_tracing {m.io_hist[m.io_count % IO_HISTORY] = t}
	m.io_count += 1
	if port >= 0x1F0 && port <= 0x1F7 || port == 0x3F6 {
		if m.diagnostic_tracing {m.ide_hist[m.ide_count % IDE_HISTORY] = t}
		m.ide_count += 1
	}
	if port == 0x1F7 {
		lba :=
			u32(m.ide.reg_lba_lo) |
			u32(m.ide.reg_lba_mid) << 8 |
			u32(m.ide.reg_lba_hi) << 16 |
			u32(m.ide.reg_drive & 0x0F) << 24
		if m.diagnostic_tracing {m.cmd_hist[m.cmd_count % IDE_HISTORY] = Ide_Cmd_Trace {
			cmd   = u8(val),
			drive = m.ide.reg_drive,
			count = m.ide.reg_seccount,
			lba   = lba,
		}}
		m.cmd_count += 1
	}
	bus_io_write(&m.bus, port, size, val)
	machine_rearm_wake(m)
	return !m.bus.frozen
}

@(private = "file")
machine_io_stream_read :: proc(
	ctx: rawptr,
	port: u16,
	size: u8,
	data: []u8,
) -> (completed: int, handled, ok: bool) {
	m := (^Machine)(ctx)
	if m.diagnostic_tracing {return 0, false, true}
	if port != 0x1F0 && port != 0x170 {return 0, false, true}
	completed, handled = bus_io_stream_read(&m.bus, port, size, data)
	return completed, handled, !m.bus.frozen
}

@(private = "file")
machine_io_stream_write :: proc(
	ctx: rawptr,
	port: u16,
	size: u8,
	data: []u8,
) -> (completed: int, handled, ok: bool) {
	m := (^Machine)(ctx)
	if m.diagnostic_tracing {return 0, false, true}
	if port != 0x1F0 && port != 0x170 {return 0, false, true}
	completed, handled = bus_io_stream_write(&m.bus, port, size, data)
	return completed, handled, !m.bus.frozen
}

// VGA owns the legacy aperture; known probe zones read FF / swallow writes.
machine_mmio :: proc(ctx: rawptr, gpa: u64, write: bool, data: []u8) {
	m := (^Machine)(ctx)
	machine_sync_time(m)
	decoded_gpa := hv.cpu_physical_address(&m.vm, gpa)
	if decoded_gpa >= video.GSW_VGA_CONTROL_BASE &&
	   decoded_gpa + u64(len(data)) <= video.GSW_VGA_CONTROL_BASE + video.GSW_VGA_CONTROL_SIZE &&
	   pci_gsw_vga_memory_enabled(&m.pci) {
		offset := u32(decoded_gpa - video.GSW_VGA_CONTROL_BASE)
		if write {
			video.gsw_vga_mmio_write(&m.gsw_vga, offset, data, m.vm.ram)
		} else {
			video.gsw_vga_mmio_read(&m.gsw_vga, offset, data)
		}
		return
	}
	if decoded_gpa >= video.LEGACY_APERTURE_BASE &&
	   decoded_gpa + u64(len(data)) <= video.LEGACY_APERTURE_END {
		for byte, i in data {
			if write {
				_ = video.vga_mmio_write(&m.vga, decoded_gpa + u64(i), 1, u32(byte))
			} else if value, ok := video.vga_mmio_read(&m.vga, decoded_gpa + u64(i), 1); ok {
				data[i] = u8(value)
			} else {
				data[i] = 0xFF
			}
		}
		machine_rearm_wake(m)
		return
	}
	if !write {
		for i in 0 ..< len(data) {data[i] = 0xFF}
	}
	zone, tolerated := machine_mmio_zone(decoded_gpa)
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
	bus_record_unclassified_mmio(
		&m.bus,
		Unclassified_Mmio{gpa = decoded_gpa, write = write, size = u32(len(data))},
	)
	if m.bus.strict_io {
		bus_freeze(
			&m.bus,
			fmt.tprintf(
				"unclassified MMIO %s gpa=0x%x size=%d",
				write ? "write" : "read",
				gpa,
				len(data),
			),
		)
	}
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
machine_gsw_vga_irq :: proc(ctx: rawptr, asserted: bool) {
	m := (^Machine)(ctx)
	_ = pci_pirq_set_level(&m.pci, 0, asserted)
	if asserted {m.yield_requested = true}
}

@(private = "file")
machine_irq1 :: proc(ctx: rawptr) {
	m := (^Machine)(ctx)
	pic_set_irq_level(&m.pic, 1, true)
}

@(private = "file")
machine_test_device_read :: proc(ctx: rawptr, port: u16, size: u8) -> u32 {
	m := (^Machine)(ctx)
	value, handled := test_device_read(&m.test_device, port)
	return handled ? u32(value) : u32(0xFF)
}

@(private = "file")
machine_test_device_write :: proc(ctx: rawptr, port: u16, size: u8, value: u32) {
	m := (^Machine)(ctx)
	_ = test_device_write(&m.test_device, port, u8(value))
}

@(private = "file")
machine_irq1_lower :: proc(ctx: rawptr) {
	m := (^Machine)(ctx)
	pic_set_irq_level(&m.pic, 1, false)
}

@(private)
machine_irq12 :: proc(ctx: rawptr) {
	m := (^Machine)(ctx)
	pic_set_irq_level(&m.pic, 12, true)
}

@(private = "file")
machine_irq12_lower :: proc(ctx: rawptr) {
	m := (^Machine)(ctx)
	pic_set_irq_level(&m.pic, 12, false)
}

@(private = "file")
machine_irq6 :: proc(ctx: rawptr) {
	m := (^Machine)(ctx)
	pic_raise(&m.pic, 6)
}

machine_bmide_memory_read :: proc(ctx: rawptr, address: u64, data: []u8) -> bool {
	m := (^Machine)(ctx)
	return hv.physical_ram_read(&m.vm, address, data)
}

machine_bmide_memory_write :: proc(ctx: rawptr, address: u64, data: []u8) -> bool {
	m := (^Machine)(ctx)
	return hv.physical_ram_write(&m.vm, address, data)
}

@(private = "file")
machine_io_should_yield :: proc(ctx: rawptr) -> bool {
	m := (^Machine)(ctx)
	requested := m.yield_requested
	m.yield_requested = false
	return requested
}

machine_bmide_memory_map :: proc(
	ctx: rawptr,
	address: u64,
	length: int,
	write: bool,
) -> ([]u8, bool) {
	m := (^Machine)(ctx)
	if length < 0 || address > u64(len(m.vm.ram)) || u64(length) > u64(len(m.vm.ram)) - address {
		return nil, false
	}
	return m.vm.ram[int(address):int(address) + length], true
}

machine_bmide_memory :: proc(m: ^Machine) -> disk.Bmide_Memory_Adapter {
	return {
		ctx = m,
		size = hv.physical_ram_size(&m.vm),
		read = machine_bmide_memory_read,
		write = machine_bmide_memory_write,
		direct = machine_bmide_memory_map,
	}
}

machine_bmide_poll_irqs :: proc(m: ^Machine) {
	if disk.bmide_take_irq(&m.bmide, 0) && disk.ide_irq_enabled(&m.ide) {
		pic_raise(&m.pic, 14)
		m.yield_requested = true
	}
	if disk.bmide_take_irq(&m.bmide, 1) && disk.atapi_irq_enabled(&m.atapi) {
		pic_raise(&m.pic, 15)
		m.yield_requested = true
	}
}

machine_bmide_synchronize :: proc(m: ^Machine) {
	disk.bmide_synchronize(&m.bmide, pci_ide_bus_master_enabled(&m.pci), machine_bmide_memory(m))
	machine_bmide_poll_irqs(m)
}

machine_bmide_submit_ide :: proc(m: ^Machine) {
	if request, pending := disk.ide_bmide_request(&m.ide); pending {
		if disk.bmide_submit_request(&m.bmide, 0, request) {
			disk.ide_bmide_mark_submitted(&m.ide)
		}
	}
	machine_bmide_synchronize(m)
}

machine_bmide_submit_atapi :: proc(m: ^Machine) {
	if request, pending := disk.atapi_bmide_request(&m.atapi); pending {
		if disk.bmide_submit_request(&m.bmide, 1, request) {
			disk.atapi_bmide_mark_submitted(&m.atapi)
		}
	}
	machine_bmide_synchronize(m)
}

@(private = "file")
machine_audio_reset_cdda :: proc(m: ^Machine) {
	if m == nil {return}
	m.cdda_pending_count = 0
	sound.audio_mixer_reset_cdda(&m.audio)
}

@(private = "file")
machine_audio_drain_cdda :: proc(m: ^Machine) {
	if m.cdda_pending_count == 0 {return}
	consumed := sound.audio_mixer_queue_cdda(&m.audio, m.cdda_pending[:m.cdda_pending_count])
	if consumed <= 0 {return}
	remaining := m.cdda_pending_count - consumed
	copy(m.cdda_pending[:remaining], m.cdda_pending[consumed:m.cdda_pending_count])
	m.cdda_pending_count = remaining
}

@(private = "file")
machine_cdda_frame :: proc(ctx: rawptr, pcm: []u8) {
	m := (^Machine)(ctx)
	if m == nil || len(pcm) != disk.DISC_RAW_SECTOR_SIZE {return}
	machine_audio_drain_cdda(m)
	frames: [disk.DISC_RAW_SECTOR_SIZE / 4]sound.Audio_Frame
	for i in 0 ..< len(frames) {
		offset := i * 4
		frames[i] = {
			left  = i16(u16(pcm[offset]) | u16(pcm[offset + 1]) << 8),
			right = i16(u16(pcm[offset + 2]) | u16(pcm[offset + 3]) << 8),
		}
	}
	consumed := sound.audio_mixer_queue_cdda(&m.audio, frames[:])
	remaining := len(frames) - consumed
	if remaining == 0 {return}
	if m.cdda_pending_count + remaining > len(m.cdda_pending) {
		bus_freeze(&m.bus, "CDDA source queue overflow")
		return
	}
	copy(m.cdda_pending[m.cdda_pending_count:m.cdda_pending_count + remaining], frames[consumed:])
	m.cdda_pending_count += remaining
}

@(private = "file")
machine_audio_apply_pit_transitions :: proc(m: ^Machine) {
	enabled := m.pit.port61_low & 0x02 != 0
	for transition in pit_channel2_transition_slice(&m.pit) {
		_ = sound.audio_mixer_set_speaker_state(
			&m.audio,
			transition.master_tick,
			enabled,
			transition.level,
		)
	}
	pit_clear_channel2_transitions(&m.pit)
}

@(private = "file")
machine_audio_advance_to :: proc(m: ^Machine, tick: u64) {
	machine_audio_apply_pit_transitions(m)
	machine_audio_drain_cdda(m)
	_ = sound.audio_mixer_advance_to(&m.audio, tick)
}

@(private = "file")
machine_irq14 :: proc(ctx: rawptr) {
	m := (^Machine)(ctx)
	disk.bmide_note_ide_irq(&m.bmide, 0)
	pic_raise(&m.pic, 14)
}

@(private = "file")
machine_irq15 :: proc(ctx: rawptr) {
	m := (^Machine)(ctx)
	disk.bmide_note_ide_irq(&m.bmide, 1)
	pic_raise(&m.pic, 15)
}

// --- FDC / DMA channel 2 glue ---

@(private = "file")
machine_fdc_dma_to_mem :: proc(ctx: rawptr, data: []u8) -> int {
	m := (^Machine)(ctx)
	dma_set_hardware_request(&m.dma, 2, true)
	defer dma_set_hardware_request(&m.dma, 2, false)
	return dma_transfer_to_memory(&m.dma, 2, m.vm.ram, data)
}

@(private = "file")
machine_fdc_dma_from_mem :: proc(ctx: rawptr, buf: []u8) -> int {
	m := (^Machine)(ctx)
	dma_set_hardware_request(&m.dma, 2, true)
	defer dma_set_hardware_request(&m.dma, 2, false)
	return dma_transfer_from_memory(&m.dma, 2, m.vm.ram, buf)
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
	source: Reset_Provenance
	switch m.kbd.reset_source {
	case .Controller_Pulse:
		source = .Kbc_Controller_Pulse
	case .Output_Port:
		source = .Kbc_Output_Port
	case .Fast_A20:
		source = .Port_92
	case .None:
		source = .Kbc_Controller_Pulse
	}
	machine_request_reset(m, source)
}

@(private = "file")
machine_reset_name :: proc(source: Reset_Provenance) -> string {
	switch source {
	case .Kbc_Controller_Pulse:
		return "i8042 pulse"
	case .Kbc_Output_Port:
		return "i8042 output port"
	case .Port_92:
		return "port 92"
	case .Pci_Cf9:
		return "PCI reset control"
	case .Triple_Fault:
		return "triple fault"
	case .Dos_Extender_Warm_Resume:
		return "DOS extender warm resume"
	case .None:
		return "unspecified"
	}
	return "unspecified"
}

@(private = "file")
machine_record_reset :: proc(m: ^Machine, source: Reset_Provenance) {
	index := m.reset_count % PC_AT_RESET_HISTORY
	m.reset_history[index] = {
		source        = source,
		master_tick   = master_timeline_now(m.timeline),
		cmos_shutdown = m.cmos.ram[0x0F],
	}
	m.reset_count += 1
	m.reset_source = source
}

@(private = "file")
machine_request_reset :: proc(m: ^Machine, source: Reset_Provenance) {
	if m == nil || m.reset_requested {return}
	machine_record_reset(m, source)
	m.reset_requested = true
	bus_freeze(
		&m.bus,
		fmt.tprintf("guest requested hardware reset (%s)", machine_reset_name(source)),
	)
}

@(private = "file")
machine_a20_control :: proc(ctx: rawptr, enabled: bool) -> bool {
	m := (^Machine)(ctx)
	if hv.set_a20(&m.vm, enabled) {return true}
	bus_freeze(&m.bus, "A20 mapping failed")
	return false
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
	machine_sync_device(m, .Pit)
	v: u32 = 0
	for i in 0 ..< int(size) {v |= u32(pit_in(&m.pit, port + u16(i))) << (8 * uint(i))}
	return v
}

@(private = "file")
machine_pit_write :: proc(ctx: rawptr, port: u16, size: u8, val: u32) {
	m := (^Machine)(ctx)
	machine_sync_device(m, .Pit)
	for i in 0 ..< int(size) {pit_out(&m.pit, port + u16(i), u8(val >> (8 * uint(i))))}
	machine_audio_apply_pit_transitions(m)
	_ = sound.audio_mixer_set_speaker_state(
		&m.audio,
		master_timeline_now(m.timeline),
		m.pit.port61_low & 0x02 != 0,
		pit_channel_out(&m.pit, 2),
	)
}

@(private = "file")
machine_port61_read :: proc(ctx: rawptr, port: u16, size: u8) -> u32 {
	m := (^Machine)(ctx)
	machine_sync_device(m, .Pit)
	return u32(pit_port61_read(&m.pit))
}

@(private = "file")
machine_port61_write :: proc(ctx: rawptr, port: u16, size: u8, val: u32) {
	m := (^Machine)(ctx)
	machine_sync_device(m, .Pit)
	pit_port61_write(&m.pit, u8(val))
	machine_audio_apply_pit_transitions(m)
	_ = sound.audio_mixer_set_speaker_state(
		&m.audio,
		master_timeline_now(m.timeline),
		m.pit.port61_low & 0x02 != 0,
		pit_channel_out(&m.pit, 2),
	)
}

@(private = "file")
machine_uart_for_port :: proc(m: ^Machine, port: u16) -> ^Uart_16450 {
	return port >= UART_COM1_BASE && port <= UART_COM1_BASE + 7 ? &m.serial1 : &m.serial2
}

@(private = "file")
machine_uart_read :: proc(ctx: rawptr, port: u16, size: u8) -> u32 {
	m := (^Machine)(ctx)
	u := machine_uart_for_port(m, port)
	machine_sync_device(m, port >= UART_COM1_BASE && port <= UART_COM1_BASE + 7 ? .Uart1 : .Uart2)
	value, _ := uart_in(u, port)
	return u32(value)
}

@(private = "file")
machine_uart_write :: proc(ctx: rawptr, port: u16, size: u8, val: u32) {
	m := (^Machine)(ctx)
	u := machine_uart_for_port(m, port)
	machine_sync_device(m, port >= UART_COM1_BASE && port <= UART_COM1_BASE + 7 ? .Uart1 : .Uart2)
	_ = uart_out(u, port, u8(val))
	if uart_take_irq(u) {pic_raise(&m.pic, uart_irq_number(u))}
}

@(private = "file")
machine_lpt_for_port :: proc(m: ^Machine, port: u16) -> ^Lpt {
	return port >= LPT1_BASE && port <= LPT1_BASE + 2 ? &m.parallel1 : &m.parallel2
}

@(private = "file")
machine_lpt_read :: proc(ctx: rawptr, port: u16, size: u8) -> u32 {
	m := (^Machine)(ctx)
	lpt := machine_lpt_for_port(m, port)
	machine_sync_device(m, port >= LPT1_BASE && port <= LPT1_BASE + 2 ? .Lpt1 : .Lpt2)
	value, _ := lpt_in(lpt, port)
	return u32(value)
}

@(private = "file")
machine_lpt_write :: proc(ctx: rawptr, port: u16, size: u8, val: u32) {
	m := (^Machine)(ctx)
	lpt := machine_lpt_for_port(m, port)
	machine_sync_device(m, port >= LPT1_BASE && port <= LPT1_BASE + 2 ? .Lpt1 : .Lpt2)
	_ = lpt_out(lpt, port, u8(val))
}

@(private = "file")
machine_cmos_read :: proc(ctx: rawptr, port: u16, size: u8) -> u32 {
	m := (^Machine)(ctx)
	machine_sync_device(m, .Cmos)
	v: u32 = 0
	for i in 0 ..< int(size) {v |= u32(cmos_in(&m.cmos, port + u16(i))) << (8 * uint(i))}
	return v
}

@(private = "file")
machine_cmos_write :: proc(ctx: rawptr, port: u16, size: u8, val: u32) {
	m := (^Machine)(ctx)
	machine_sync_device(m, .Cmos)
	for i in 0 ..< int(size) {cmos_out(&m.cmos, port + u16(i), u8(val >> (8 * uint(i))))}
	for _ in 0 ..< cmos_advance(&m.cmos, 0) {pic_raise(&m.pic, 8)}
}

@(private = "file")
machine_kbd_read :: proc(ctx: rawptr, port: u16, size: u8) -> u32 {
	m := (^Machine)(ctx)
	machine_sync_device(m, .I8042)
	return u32(i8042_in(&m.kbd, port))
}

@(private = "file")
machine_kbd_write :: proc(ctx: rawptr, port: u16, size: u8, val: u32) {
	m := (^Machine)(ctx)
	machine_sync_device(m, .I8042)
	i8042_out(&m.kbd, port, u8(val))
}

@(private = "file")
machine_dma_read :: proc(ctx: rawptr, port: u16, size: u8) -> u32 {
	m := (^Machine)(ctx)
	machine_sync_device(m, .Dma)
	v: u32 = 0
	for i in 0 ..< int(size) {v |= u32(dma_in(&m.dma, port + u16(i))) << (8 * uint(i))}
	return v
}

@(private = "file")
machine_dma_write :: proc(ctx: rawptr, port: u16, size: u8, val: u32) {
	m := (^Machine)(ctx)
	machine_sync_device(m, .Dma)
	for i in 0 ..< int(size) {dma_out(&m.dma, port + u16(i), u8(val >> (8 * uint(i))))}
}

@(private = "file")
machine_isa_delay_read :: proc(ctx: rawptr, port: u16, size: u8) -> u32 {
	m := (^Machine)(ctx)
	value, elapsed_ns := isa_delay_read(&m.isa_delay)
	machine_advance_time_ns(m, elapsed_ns)
	return u32(value)
}

@(private = "file")
machine_isa_delay_write :: proc(ctx: rawptr, port: u16, size: u8, val: u32) {
	m := (^Machine)(ctx)
	elapsed_ns := isa_delay_write(&m.isa_delay, u8(val))
	machine_advance_time_ns(m, elapsed_ns)
}

@(private = "file")
machine_pci_read :: proc(ctx: rawptr, port: u16, size: u8) -> u32 {
	m := (^Machine)(ctx)
	machine_sync_time(m)
	if offset, claimed := pci_ide_bus_master_decode(&m.pci, port, size); claimed {
		machine_sync_device(m, .Bmide)
		return disk.bmide_io_read(&m.bmide, offset, size)
	}
	return pci_in(&m.pci, port, size)
}

@(private = "file")
machine_pci_write :: proc(ctx: rawptr, port: u16, size: u8, val: u32) {
	m := (^Machine)(ctx)
	machine_sync_time(m)
	if offset, claimed := pci_ide_bus_master_decode(&m.pci, port, size); claimed {
		machine_sync_device(m, .Bmide)
		disk.bmide_io_write(&m.bmide, offset, size, val)
		machine_bmide_synchronize(m)
		machine_rearm_wake(m)
		return
	}
	pci_out(&m.pci, port, size, val)
	machine_bmide_synchronize(m)
	machine_rearm_wake(m)
}

machine_reset_control_read :: proc(ctx: rawptr, port: u16, size: u8) -> u32 {
	m := (^Machine)(ctx)
	return u32(m.reset_control)
}

machine_reset_control_write :: proc(ctx: rawptr, port: u16, size: u8, val: u32) {
	if size != 1 {return}
	m := (^Machine)(ctx)
	m.reset_control = u8(val) & 0x02
	if val & 0x04 != 0 {machine_request_reset(m, .Pci_Cf9)}
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
	machine_vga_sync(m)
	return video.vga_io_read(&m.vga, port, size)
}

@(private = "file")
machine_vga_write :: proc(ctx: rawptr, port: u16, size: u8, val: u32) {
	m := (^Machine)(ctx)
	machine_sync_time(m)
	video.vga_begin_raster_change(&m.vga, m.active_ns)
	video.vga_io_write(&m.vga, port, size, val)
}

@(private = "file")
machine_vga_sync :: proc(m: ^Machine) {
	machine_sync_time(m)
	video.vga_sync_to(&m.vga, m.active_ns)
}

machine_display_frame :: proc(m: ^Machine) -> ^video.Display_Frame {
	machine_vga_sync(m)
	return video.vga_display_frame(&m.vga)
}

machine_capture_scanout :: proc(m: ^Machine, descriptor: ^video.Scanout_Descriptor) -> bool {
	if m == nil || descriptor == nil {return false}
	machine_vga_sync(m)
	return video.scanout_descriptor_capture(descriptor, &m.vga)
}

machine_scanout_generation :: proc(m: ^Machine) -> u64 {
	if m == nil {return 0}
	machine_vga_sync(m)
	return m.vga.content_generation
}

machine_text_snapshot :: proc(m: ^Machine) -> video.Text_Snapshot {
	machine_vga_sync(m)
	return video.vga_text_snapshot(&m.vga)
}

@(private = "file")
machine_fdc_read :: proc(ctx: rawptr, port: u16, size: u8) -> u32 {
	m := (^Machine)(ctx)
	machine_sync_device(m, .Fdc)
	v: u32 = 0
	for i in 0 ..< int(size) {v |= u32(disk.fdc_in(&m.fdc, port + u16(i))) << (8 * uint(i))}
	return v
}

@(private = "file")
machine_fdc_write :: proc(ctx: rawptr, port: u16, size: u8, val: u32) {
	m := (^Machine)(ctx)
	machine_sync_device(m, .Fdc)
	for i in 0 ..< int(size) {disk.fdc_out(&m.fdc, port + u16(i), u8(val >> (8 * uint(i))))}
}

@(private = "file")
machine_ide_read :: proc(ctx: rawptr, port: u16, size: u8) -> u32 {
	m := (^Machine)(ctx)
	machine_sync_time(m)
	machine_sync_device(m, .Ide)
	return disk.ide_io_read(&m.ide, port, size)
}

@(private = "file")
machine_ide_write :: proc(ctx: rawptr, port: u16, size: u8, val: u32) {
	m := (^Machine)(ctx)
	machine_sync_time(m)
	machine_sync_device(m, .Ide)
	if port == 0x1F7 || port == 0x3F6 && val & 0x04 != 0 {
		disk.bmide_cancel_request(&m.bmide, 0)
	}
	disk.ide_io_write(&m.ide, port, size, val)
	machine_bmide_submit_ide(m)
	machine_rearm_wake(m)
}

@(private = "file")
machine_ide_stream_read :: proc(ctx: rawptr, port: u16, size: u8, data: []u8) -> int {
	if port != 0x1F0 || size == 0 {return 0}
	m := (^Machine)(ctx)
	machine_sync_device(m, .Ide)
	elements := len(data) / int(size)
	for element in 0 ..< elements {
		value := disk.ide_io_read(&m.ide, port, size)
		base := element * int(size)
		for byte in 0 ..< int(size) {data[base + byte] = u8(value >> (8 * uint(byte)))}
	}
	return elements
}

@(private = "file")
machine_ide_stream_write :: proc(ctx: rawptr, port: u16, size: u8, data: []u8) -> int {
	if port != 0x1F0 || size == 0 {return 0}
	m := (^Machine)(ctx)
	machine_sync_device(m, .Ide)
	elements := len(data) / int(size)
	for element in 0 ..< elements {
		value: u32
		base := element * int(size)
		for byte in 0 ..< int(size) {value |= u32(data[base + byte]) << (8 * uint(byte))}
		disk.ide_io_write(&m.ide, port, size, value)
	}
	return elements
}

@(private = "file")
machine_atapi_read :: proc(ctx: rawptr, port: u16, size: u8) -> u32 {
	m := (^Machine)(ctx)
	machine_sync_time(m)
	machine_sync_device(m, .Atapi)
	return disk.atapi_io_read(&m.atapi, port, size)
}

@(private = "file")
machine_atapi_write :: proc(ctx: rawptr, port: u16, size: u8, val: u32) {
	m := (^Machine)(ctx)
	machine_sync_time(m)
	machine_sync_device(m, .Atapi)
	cdda_generation := disk.atapi_cdda_generation(&m.atapi)
	if port == 0x177 || port == 0x376 && val & 0x04 != 0 {
		disk.bmide_cancel_request(&m.bmide, 1)
	}
	disk.atapi_io_write(&m.atapi, port, size, val)
	if disk.atapi_cdda_generation(&m.atapi) != cdda_generation {machine_audio_reset_cdda(m)}
	machine_bmide_submit_atapi(m)
	machine_rearm_wake(m)
}

@(private = "file")
machine_atapi_stream_read :: proc(ctx: rawptr, port: u16, size: u8, data: []u8) -> int {
	if port != 0x170 || size == 0 {return 0}
	m := (^Machine)(ctx)
	machine_sync_device(m, .Atapi)
	elements := len(data) / int(size)
	for element in 0 ..< elements {
		value := disk.atapi_io_read(&m.atapi, port, size)
		base := element * int(size)
		for byte in 0 ..< int(size) {data[base + byte] = u8(value >> (8 * uint(byte)))}
	}
	return elements
}

@(private = "file")
machine_atapi_stream_write :: proc(ctx: rawptr, port: u16, size: u8, data: []u8) -> int {
	if port != 0x170 || size == 0 {return 0}
	m := (^Machine)(ctx)
	machine_sync_device(m, .Atapi)
	elements := len(data) / int(size)
	for element in 0 ..< elements {
		value: u32
		base := element * int(size)
		for byte in 0 ..< int(size) {value |= u32(data[base + byte]) << (8 * uint(byte))}
		disk.atapi_io_write(&m.atapi, port, size, value)
	}
	return elements
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
