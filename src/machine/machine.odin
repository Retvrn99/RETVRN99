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
IDE_KERNEL_PROBE_HISTORY :: 1024
MACHINE_GOVERNOR_QUANTUM_NS :: u64(1_000_000)
MACHINE_NO_WAKE_NS :: u64(86_400_000_000_000)
MACHINE_CDDA_PENDING_FRAMES :: disk.DISC_RAW_SECTOR_SIZE / size_of(sound.Audio_Frame) * 2

Wake_Schedule_Mode :: enum u8 {
	Disarm,
	One_Shot,
	Run_Guard,
}

Wake_Schedule_Proc :: proc(
	ctx: rawptr,
	delay_ns: u64,
	mode: Wake_Schedule_Mode,
	generation: u64,
) -> bool

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

Ide_Kernel_Probe_Trace :: struct {
	port:           u16,
	write:          bool,
	size:           u8,
	value:          u32,
	elements:       u32,
	repeats:        u32,
	protected_mode: bool,
	cpl:            u8,
	cs:             u16,
	linear:         u64,
}

Storage_Activity :: struct {
	floppy:     u64,
	hard_drive: u64,
	dvd_rom:    u64,
}

WIN9X_KERNEL_LINEAR_BASE :: u64(0xC000_0000)

Machine :: struct {
	using platform:                      Pc_At_Platform,
	pci:                                 Pci,
	fwcfg:                               Fwcfg,
	vga:                                 video.Vga,
	gsw_vga:                             video.Gsw_Vga,
	ide:                                 disk.Ide,
	atapi:                               disk.Atapi,
	bmide:                               disk.Bmide,
	primary_ide_kernel_dma_request:      bool,
	primary_ide_kernel_dma_transactions: u64,
	primary_ide_kernel_dma_bytes:        u64,
	audio:                               sound.Audio_Mixer,
	cdda_pending:                        [MACHINE_CDDA_PENDING_FRAMES]sound.Audio_Frame,
	cdda_pending_count:                  int,
	fdc:                                 disk.Fdc,
	test_device:                         Test_Device,
	test_device_enabled:                 bool,
	has_disk:                            bool,
	vm:                                  hv.Vm,
	governor:                            hv.Governor,
	cpu_mode:                            config.Cpu_Mode,
	idle_waiter:                         hosttime.Waiter,
	scheduler:                           Event_Scheduler,
	timeline:                            Master_Timeline,
	time_source:                         Master_Source_Phase,
	nanosecond_phase:                    Rate_Phase,
	active_tick:                         time.Tick,
	active_ns:                           u64,
	cmos_active_ns:                      u64,
	clock_running:                       bool,
	wake_ctx:                            rawptr,
	wake_schedule:                       Wake_Schedule_Proc,
	wake_deadline:                       u64,
	wake_scheduled:                      bool,
	wake_mode:                           Wake_Schedule_Mode,
	wake_generation:                     u64,
	wake_arms:                           u64,
	vcpu_running:                        bool,
	io_string_depth:                     u32,
	yield_requested:                     bool,
	governor_deadline:                   u64,
	device_advances:                     [SCHEDULED_DEVICE_COUNT]u64,
	device_sync_tick:                    [SCHEDULED_DEVICE_COUNT]u64,
	device_sync_valid:                   [SCHEDULED_DEVICE_COUNT]bool,
	diagnostic_tracing:                  bool,
	hardware_trace:                      ^Hardware_Trace,
	scanout_copies:                      u64,
	cpu_halted:                          bool,
	dbg_out:                             [dynamic]u8, // firmware debug ports 0x402 and 0x500
	mmio_seen:                           [Mmio_Zone]bool, // log tolerated zones only once
	exit_hist:                           [EXIT_HISTORY]hv.Exit_Kind, // ring, exit_count % EXIT_HISTORY
	exit_count:                          u64,
	io_hist:                             [IO_HISTORY]Io_Trace, // ring, io_count % IO_HISTORY
	io_count:                            u64,
	ide_hist:                            [IDE_HISTORY]Io_Trace, // ring of IDE-port accesses only
	ide_count:                           u64,
	cmd_hist:                            [IDE_HISTORY]Ide_Cmd_Trace, // ring of IDE commands
	cmd_count:                           u64,
	ide_kernel_probe_hist:               [IDE_KERNEL_PROBE_HISTORY]Ide_Kernel_Probe_Trace,
	ide_kernel_probe_count:              u64,
	ide_kernel_probe_total:              u64,
	ide_kernel_probe_started:            bool,
	pic_offer_queued:                    bool,
	pic_queued_offer:                    Pic_Interrupt_Token,
	pic_queue_count:                     u64,
	pic_delivery_count:                  u64,
	inj_count:                           [256]u64, // injected IRQ vectors
}

@(private = "file")
machine_record_ide_kernel_probe :: proc(
	m: ^Machine,
	port: u16,
	write: bool,
	size: u8,
	value: u32,
	elements: u32 = 1,
) {
	if m == nil || !m.bus.diagnostic_tracing {
		return
	}
	kernel_origin := machine_primary_ide_kernel_origin(m.vm.io_origin)
	if !m.ide_kernel_probe_started && !kernel_origin {return}
	if kernel_origin {m.ide_kernel_probe_started = true}
	m.ide_kernel_probe_total += 1
	if m.ide_kernel_probe_count > 0 {
		previous := &m.ide_kernel_probe_hist[m.ide_kernel_probe_count - 1]
		origin := m.vm.io_origin
		if previous.port == port &&
		   previous.write == write &&
		   previous.size == size &&
		   previous.value == value &&
		   previous.elements == elements &&
		   previous.protected_mode == origin.protected_mode &&
		   previous.cpl == origin.cpl &&
		   previous.cs == origin.cs &&
		   previous.linear == origin.linear &&
		   previous.repeats < max(u32) {
			previous.repeats += 1
			return
		}
	}
	if m.ide_kernel_probe_count >= IDE_KERNEL_PROBE_HISTORY {return}
	origin := m.vm.io_origin
	m.ide_kernel_probe_hist[m.ide_kernel_probe_count] = {
		port           = port,
		write          = write,
		size           = size,
		value          = value,
		elements       = elements,
		repeats        = 1,
		protected_mode = origin.protected_mode,
		cpl            = origin.cpl,
		cs             = origin.cs,
		linear         = origin.linear,
	}
	m.ide_kernel_probe_count += 1
}

machine_init :: proc(m: ^Machine, ram_size: int) -> bool {
	if m == nil || ram_size <= 0 {return false}
	initialized := false
	defer if !initialized {machine_destroy(m)}
	bus_init(&m.bus)
	if !hv.create(&m.vm, ram_size) {return false}
	if !hv.reserve_mmio(
		&m.vm,
		video.LEGACY_APERTURE_BASE,
		video.LEGACY_APERTURE_END - video.LEGACY_APERTURE_BASE,
	) {
		return false
	}
	vram, vram_ok := hv.map_device_memory(&m.vm, video.VBE_LFB_BASE, video.VRAM_SIZE)
	if !vram_ok || !video.vga_init(&m.vga, vram) {
		return false
	}
	video.vga_set_deferred_scanout(&m.vga, true)
	if !hv.governor_init(&m.governor, &m.vm, .GSW_886) {
		return false
	}
	video.gsw_vga_init(&m.gsw_vga, vram)
	video.gsw_vga_attach_scanout(&m.gsw_vga, &m.vga)
	video.gsw_vga_set_irq(&m.gsw_vga, m, machine_gsw_vga_irq)
	m.cpu_mode = .GSW_886
	event_scheduler_init(&m.scheduler)
	if !sound.audio_mixer_init(&m.audio) {
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
	m.vm.irq_ctx = m
	m.vm.irq_delivered = machine_irq_delivered
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
	machine_init_isa_pnp(m)

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
	reset_h := Io_Handler {
		ctx   = m,
		read  = machine_reset_control_read,
		write = machine_reset_control_write,
	}
	bus_register(&m.bus, 0xCF9, 0xCF9, reset_h)
	apm_power_h := Io_Handler {
		ctx   = m,
		read  = machine_apm_power_read,
		write = machine_apm_power_write,
	}
	bus_register(&m.bus, APM_POWER_OFF_PORT, APM_POWER_OFF_PORT, apm_power_h)

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
	if !machine_sync_pci_devices(m) {
		return false
	}
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
	machine_clock_set_running(m, true)
	initialized = true
	return true
}

machine_destroy :: proc(m: ^Machine) {
	if m == nil {return}
	_ = machine_detach_disk(m)
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
	if m.hardware_trace != nil {
		free(m.hardware_trace)
		m.hardware_trace = nil
	}
	m^ = {}
}

// moves the collected firmware debug bytes into sink and clears the buffer
machine_drain_dbg :: proc(m: ^Machine, sink: ^[dynamic]u8) {
	append(sink, ..m.dbg_out[:])
	clear(&m.dbg_out)
}

// stores the device and takes over the IDE ports whitelisted at init
machine_attach_disk :: proc(m: ^Machine, bd: disk.Block_Device) {
	disk.bmide_reset_channel(&m.bmide, 0)
	m.primary_ide_kernel_dma_request = false
	disk.ide_init(&m.ide, bd)
	cmos_set_primary_disk(&m.cmos, bd.sector_count)
	m.ide.irq_ctx = m
	m.ide.irq = machine_irq14
	m.has_disk = true
	if !machine_sync_pci_devices(m) {
		bus_freeze(&m.bus, "PCI IDE decode synchronization failed")
	}
	h := Io_Handler {
		ctx          = m,
		read         = machine_ide_read,
		write        = machine_ide_write,
		stream_read  = machine_ide_stream_read,
		stream_write = machine_ide_stream_write,
	}
	bus_register(&m.bus, 0x1F0, 0x1F7, h)
	bus_register(&m.bus, 0x3F6, 0x3F6, h)
}

machine_detach_disk :: proc(m: ^Machine) -> bool {
	if m == nil || !m.has_disk {return true}
	if !disk.ide_checkpoint(&m.ide) {return false}
	disk.bmide_reset_channel(&m.bmide, 0)
	m.primary_ide_kernel_dma_request = false
	m.ide.bd = {}
	m.has_disk = false
	cmos_set_primary_disk(&m.cmos, 0)
	return true
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
	_ = disk.bmide_set_drive_dma_capable(&m.bmide, 1, 0, true)
	m.atapi.irq_ctx = m
	m.atapi.irq = machine_irq15
	disk.atapi_set_cdda_output(&m.atapi, m, machine_cdda_frame)
	h := Io_Handler {
		ctx          = m,
		read         = machine_atapi_read,
		write        = machine_atapi_write,
		stream_read  = machine_atapi_stream_read,
		stream_write = machine_atapi_stream_write,
	}
	bus_register(&m.bus, 0x170, 0x177, h)
	bus_register(&m.bus, 0x376, 0x376, h)
}

machine_mount_cdrom :: proc(m: ^Machine, path: string) -> bool {
	disk.bmide_reset_channel(&m.bmide, 1)
	_ = disk.bmide_set_drive_dma_capable(&m.bmide, 1, 0, true)
	machine_audio_reset_cdda(m)
	return disk.atapi_mount(&m.atapi, path)
}

machine_attach_cdrom :: proc(m: ^Machine, path: string) -> bool {
	disk.bmide_reset_channel(&m.bmide, 1)
	_ = disk.bmide_set_drive_dma_capable(&m.bmide, 1, 0, true)
	machine_audio_reset_cdda(m)
	return disk.atapi_attach(&m.atapi, path)
}

machine_eject_cdrom :: proc(m: ^Machine) {
	disk.bmide_reset_channel(&m.bmide, 1)
	_ = disk.bmide_set_drive_dma_capable(&m.bmide, 1, 0, true)
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
	hypervisor_runs:                     u64,
	hypervisor_cancellations:            u64,
	timer_arms:                          u64,
	scheduler_dispatches:                u64,
	device_advances:                     u64,
	storage_transactions:                u64,
	storage_host_calls:                  u64,
	storage_bytes:                       u64,
	primary_ide_dma_transactions:        u64,
	primary_ide_dma_bytes:               u64,
	primary_ide_kernel_dma_transactions: u64,
	primary_ide_kernel_dma_bytes:        u64,
	audio_blocks:                        u64,
	scanout_copies:                      u64,
	full_frame_renders:                  u64,
	software_rendered_pixels:            u64,
}

machine_execution_counters :: proc(m: ^Machine) -> Machine_Execution_Counters {
	if m == nil {return {}}
	advances: u64
	for count in m.device_advances {advances += count}
	return {
		hypervisor_runs = m.vm.run_calls,
		hypervisor_cancellations = m.vm.run_cancellations,
		timer_arms = m.wake_arms,
		scheduler_dispatches = m.scheduler.dispatches,
		device_advances = advances,
		storage_transactions = m.bmide.transactions,
		storage_host_calls = m.bmide.host_calls,
		storage_bytes = m.bmide.bytes_moved,
		primary_ide_dma_transactions = m.bmide.channel_transactions[0],
		primary_ide_dma_bytes = m.bmide.channel_bytes_moved[0],
		primary_ide_kernel_dma_transactions = m.primary_ide_kernel_dma_transactions,
		primary_ide_kernel_dma_bytes = m.primary_ide_kernel_dma_bytes,
		audio_blocks = sound.audio_mixer_blocks_rendered(&m.audio),
		scanout_copies = m.scanout_copies,
		full_frame_renders = m.vga.full_frame_renders,
		software_rendered_pixels = m.vga.raster_pixels_rendered +
		m.gsw_vga.metrics.software_pixels,
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
		if m.has_disk {cmos_set_primary_disk(&m.cmos, m.ide.bd.sector_count)}
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

machine_reset_reason :: proc(m: ^Machine) -> string {
	return m != nil ? m.reset_reason : ""
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
	m.pic_offer_queued = false
	m.pic_queued_offer = {}
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
	machine_scheduler_refresh(m)
	machine_rearm_wake(m)
}

machine_set_diagnostic_tracing :: proc(m: ^Machine, enabled: bool) {
	if m == nil {return}
	m.diagnostic_tracing = enabled
	m.bus.diagnostic_tracing = enabled || m.bus.strict_io || m.bus.log_unclassified
}

machine_set_bus_diagnostic_tracing :: proc(m: ^Machine, enabled: bool) {
	if m == nil {return}
	m.bus.diagnostic_tracing =
		enabled || m.diagnostic_tracing || m.bus.strict_io || m.bus.log_unclassified
}

machine_mouse_wheel :: proc(m: ^Machine, wheel: i32, buttons: u8) {
	if m == nil {return}
	machine_sync_time(m)
	machine_sync_device(m, .I8042)
	i8042_mouse(&m.kbd, 0, 0, buttons)
	i8042_mouse_wheel(&m.kbd, wheel)
	machine_scheduler_refresh(m)
	machine_rearm_wake(m)
}

machine_key :: proc(m: ^Machine, scancode: u8) {
	if m == nil {return}
	machine_sync_time(m)
	machine_sync_device(m, .I8042)
	i8042_key(&m.kbd, scancode)
	machine_scheduler_refresh(m)
	machine_rearm_wake(m)
}

machine_key_sequence :: proc(m: ^Machine, scancodes: []u8) -> bool {
	if m == nil || len(scancodes) == 0 {return false}
	machine_sync_time(m)
	machine_sync_device(m, .I8042)
	scheduled := i8042_schedule_keys(&m.kbd, scancodes)
	if scheduled {machine_scheduler_refresh(m)}
	machine_rearm_wake(m)
	return scheduled
}

machine_clock_set_running :: proc(m: ^Machine, running: bool) {
	if m == nil {return}
	if m.clock_running && !running {machine_sync_time(m)}
	if !m.clock_running && running {
		now := time.now()
		year, month, day := time.date(now)
		hh, mm, ss := time.clock_from_time(now)
		weekday := int(time.weekday(now)) + 1
		cmos_set_datetime(
			&m.cmos,
			u16(year),
			u8(month),
			u8(day),
			u8(weekday),
			u8(hh),
			u8(mm),
			u8(ss),
		)
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
	if m.wake_schedule != nil && m.wake_scheduled {
		m.wake_generation += 1
		_ = m.wake_schedule(m.wake_ctx, 0, .Disarm, m.wake_generation)
	}
	m.wake_ctx = ctx
	m.wake_schedule = schedule
	m.wake_scheduled = false
	m.wake_mode = .Disarm
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
	if deadline_ns, ok := i8042_next_deadline(&m.kbd); ok {
		delta_ns := deadline_ns > m.active_ns ? deadline_ns - m.active_ns : 0
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
	if m.vcpu_running {
		if !pending ||
		   m.wake_scheduled && m.wake_mode == .Run_Guard && event.deadline >= m.wake_deadline {
			return
		}
		now := master_timeline_now(m.timeline)
		delta := event.deadline > now ? event.deadline - now : 1
		delay_ns := max(
			u64((u128(delta) * 1_000_000_000 + u128(MASTER_CLOCK_HZ - 1)) / u128(MASTER_CLOCK_HZ)),
			u64(1),
		)
		m.wake_generation += 1
		if !m.wake_schedule(m.wake_ctx, delay_ns, .Run_Guard, m.wake_generation) {
			m.wake_scheduled = false
			m.wake_mode = .Disarm
			m.wake_deadline = 0
			bus_freeze(&m.bus, "vCPU run-guard rearm failed")
			return
		}
		machine_trace_record(
			m,
			.Wake_Arm,
			u64(Wake_Schedule_Mode.Run_Guard),
			m.wake_generation,
			event.deadline,
		)
		m.wake_arms += 1
		m.wake_scheduled = true
		m.wake_mode = .Run_Guard
		m.wake_deadline = event.deadline
		return
	}
	if !pending {
		if m.wake_scheduled {
			m.wake_generation += 1
			_ = m.wake_schedule(m.wake_ctx, 0, .Disarm, m.wake_generation)
			machine_trace_record(m, .Wake_Disarm, u64(m.wake_mode), m.wake_generation)
		}
		m.wake_scheduled = false
		m.wake_mode = .Disarm
		m.wake_deadline = 0
		return
	}
	now := master_timeline_now(m.timeline)
	delta := event.deadline > now ? event.deadline - now : 1
	delay_ns := max(
		u64((u128(delta) * 1_000_000_000 + u128(MASTER_CLOCK_HZ - 1)) / u128(MASTER_CLOCK_HZ)),
		u64(1),
	)
	m.wake_generation += 1
	if !m.wake_schedule(m.wake_ctx, delay_ns, .One_Shot, m.wake_generation) {
		m.wake_scheduled = false
		m.wake_mode = .Disarm
		m.wake_deadline = 0
		bus_freeze(&m.bus, "vCPU wake scheduling failed")
		return
	}
	machine_trace_record(
		m,
		.Wake_Arm,
		u64(Wake_Schedule_Mode.One_Shot),
		m.wake_generation,
		event.deadline,
	)
	m.wake_arms += 1
	m.wake_scheduled = true
	m.wake_mode = .One_Shot
	m.wake_deadline = event.deadline
}

@(private = "package")
machine_arm_run_guard :: proc(m: ^Machine) -> bool {
	if m == nil {return false}
	if m.wake_schedule == nil {return true}
	event, pending := machine_next_wake_event(m)
	if !pending {
		m.wake_generation += 1
		_ = m.wake_schedule(m.wake_ctx, 0, .Disarm, m.wake_generation)
		machine_trace_record(m, .Wake_Disarm, u64(Wake_Schedule_Mode.Run_Guard), m.wake_generation)
		m.wake_scheduled = false
		m.wake_mode = .Disarm
		m.wake_deadline = 0
		return true
	}
	now := master_timeline_now(m.timeline)
	delta := event.deadline > now ? event.deadline - now : 1
	delay_ns := max(
		u64((u128(delta) * 1_000_000_000 + u128(MASTER_CLOCK_HZ - 1)) / u128(MASTER_CLOCK_HZ)),
		u64(1),
	)
	m.wake_generation += 1
	if !m.wake_schedule(m.wake_ctx, delay_ns, .Run_Guard, m.wake_generation) {
		m.wake_scheduled = false
		m.wake_mode = .Disarm
		m.wake_deadline = 0
		return false
	}
	machine_trace_record(
		m,
		.Wake_Arm,
		u64(Wake_Schedule_Mode.Run_Guard),
		m.wake_generation,
		event.deadline,
	)
	m.wake_arms += 1
	m.wake_scheduled = true
	m.wake_mode = .Run_Guard
	m.wake_deadline = event.deadline
	return true
}

@(private = "package")
machine_disarm_wake :: proc(m: ^Machine) {
	if m == nil || m.wake_schedule == nil {return}
	m.wake_generation += 1
	_ = m.wake_schedule(m.wake_ctx, 0, .Disarm, m.wake_generation)
	machine_trace_record(m, .Wake_Disarm, u64(m.wake_mode), m.wake_generation)
	m.wake_scheduled = false
	m.wake_mode = .Disarm
	m.wake_deadline = 0
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
		transactions_before := m.bmide.channel_transactions[0]
		bytes_before := m.bmide.channel_bytes_moved[0]
		_ = disk.bmide_advance_to(&m.bmide, now, machine_bmide_memory(m))
		machine_bmide_account_completion(m, transactions_before, bytes_before)
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

@(private = "package")
machine_trace_hv_exit :: proc(m: ^Machine, kind: hv.Exit_Kind, run_generation: u64) {
	machine_trace_record(m, .Hv_Exit, u64(kind), run_generation)
}

step :: proc(m: ^Machine) -> bool { 	// false = frozen/powered off
	if m == nil {return false}
	if m.bus.frozen {
		machine_trace_record(m, .Freeze)
		return false
	}
	if m.power_off_requested {return false}
	machine_sync_time(m)
	if m.reset_requested || m.power_off_requested {return false}
	queued := false
	deferred_pending_event := false
	if !m.pic_offer_queued && pic_has_pending(&m.pic) {
		if offer, offered := pic_interrupt_preview(&m.pic); offered {
			switch hv.try_inject_irq(&m.vm, offer.vector) {
			case .Injected:
				m.pic_offer_queued = true
				m.pic_queued_offer = offer
				m.pic_queue_count += 1
				machine_trace_record(
					m,
					.Pic_Queue,
					u64(offer.vector),
					u64(offer.master_irq) | u64(offer.slave_irq) << 8,
					u64(offer.kind),
				)
				queued = true
				hv.request_irq_window(&m.vm, false)
			case .Deferred:
				deferred_pending_event = m.vm.irq_deferred_pending_event
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
		if queued || deferred_pending_event {
			m.cpu_halted = false
		} else {
			machine_rearm_wake(m)
			delay_ns := machine_next_wake_ns(m)
			hosttime.waiter_sleep(&m.idle_waiter, time.Duration(max(delay_ns, u64(1))))
			machine_sync_time(m)
			return !m.bus.frozen
		}
	}
	m.vcpu_running = true
	if !machine_arm_run_guard(m) {
		m.vcpu_running = false
		bus_freeze(&m.bus, "vCPU run-guard scheduling failed")
		return false
	}
	run_generation := m.wake_generation
	ex := hv.run(&m.vm)
	m.vcpu_running = false
	machine_disarm_wake(m)
	machine_sync_time(m)
	machine_trace_hv_exit(m, ex.kind, run_generation)
	if m.reset_requested || m.power_off_requested {return false}
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
machine_irq_delivered :: proc(ctx: rawptr, vector: u8) -> bool {
	m := (^Machine)(ctx)
	if m == nil || !m.pic_offer_queued || m.pic_queued_offer.vector != vector {return false}
	offer := m.pic_queued_offer
	pic_interrupt_complete_queued(&m.pic, offer)
	m.pic_offer_queued = false
	m.pic_queued_offer = {}
	m.pic_delivery_count += 1
	m.inj_count[vector] += 1
	machine_trace_record(
		m,
		.Pic_Inject,
		u64(vector),
		u64(offer.master_irq) | u64(offer.slave_irq) << 8,
		u64(offer.kind),
	)
	machine_trace_record(
		m,
		.Pic_Delivery_State,
		u64(m.vm.irq_delivery_reason) | u64(m.vm.irq_delivery_cs) << 32,
		m.vm.irq_delivery_cs_base + m.vm.irq_delivery_rip,
		m.vm.irq_delivery_rflags,
	)
	if m.vm.part != nil {hv.request_irq_window(&m.vm, pic_has_pending(&m.pic))}
	return true
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

Machine_Ide_Io_Decode_Result :: enum u8 {
	Other,
	Decoded,
	Suppressed,
}

@(private = "file")
machine_io_access_in_range :: proc(port: u16, size: u8, first, last: u16) -> bool {
	if size != 1 && size != 2 && size != 4 {return false}
	return port >= first && u32(port) + u32(size) - 1 <= u32(last)
}

@(private = "file")
machine_io_access_overlaps :: proc(port: u16, size: u8, first, last: u16) -> bool {
	if size != 1 && size != 2 && size != 4 {return false}
	access_last := u32(port) + u32(size) - 1
	return u32(port) <= u32(last) && access_last >= u32(first)
}

@(private = "file")
machine_ide_bar_value :: proc(ide: ^Pci_Function, bar: int) -> u32 {
	if ide == nil || bar < 0 || bar >= 4 {return 0}
	offset := 0x10 + bar * 4
	return(
		u32(ide.cfg[offset]) |
		u32(ide.cfg[offset + 1]) << 8 |
		u32(ide.cfg[offset + 2]) << 16 |
		u32(ide.cfg[offset + 3]) << 24 \
	)
}

@(private = "file")
machine_ide_native_command_base :: proc(ide: ^Pci_Function, channel: int) -> (u16, bool) {
	bar := machine_ide_bar_value(ide, channel * 2)
	base := bar & 0xFFFF_FFFC
	if bar & 1 == 0 || base == 0 || base > 0x0000_FFF8 {return 0, false}
	return u16(base), true
}

@(private = "file")
machine_ide_native_control_port :: proc(ide: ^Pci_Function, channel: int) -> (u16, bool) {
	bar := machine_ide_bar_value(ide, channel * 2 + 1)
	base := bar & 0xFFFF_FFFC
	if bar & 1 == 0 || base == 0 || base > 0x0000_FFFD {return 0, false}
	return u16(base + 2), true
}

@(private = "package")
machine_ide_io_decode :: proc(
	m: ^Machine,
	port: u16,
	size: u8,
) -> (
	canonical_port: u16,
	result: Machine_Ide_Io_Decode_Result,
) {
	if m == nil || size != 1 && size != 2 && size != 4 {
		return port, .Other
	}
	if machine_io_access_overlaps(port, size, 0xCF8, 0xCFF) {
		return port, .Other
	}

	ide := &m.pci.functions[PCI_IDE_FUNCTION_INDEX]
	io_enabled := pci_ide_io_enabled(&m.pci)
	for channel in 0 ..< 2 {
		command_port := channel == 0 ? u16(0x1F0) : u16(0x170)
		control_port := channel == 0 ? u16(0x3F6) : u16(0x376)
		native_mask :=
			channel == 0 ? AMD756_IDE_PRIMARY_NATIVE_MODE : AMD756_IDE_SECONDARY_NATIVE_MODE
		native := ide.cfg[0x09] & native_mask != 0
		matched := false
		translated := port
		if native {
			if base, valid := machine_ide_native_command_base(ide, channel);
			   valid && machine_io_access_in_range(port, size, base, base + 7) {
				matched = true
				translated = command_port + (port - base)
			} else if control, control_valid := machine_ide_native_control_port(ide, channel);
			   control_valid && port == control && size == 1 {
				matched = true
				translated = control_port
			}
		} else if machine_io_access_in_range(port, size, command_port, command_port + 7) {
			matched = true
			translated = port
		} else if port == control_port && size == 1 {
			matched = true
			translated = port
		}
		if matched {
			if io_enabled && pci_ide_channel_enabled(&m.pci, channel) {
				return translated, .Decoded
			}
			return port, .Suppressed
		}
	}

	// The device handlers live at the compatibility ports. Do not let those
	// internal registrations leak through after a channel moves to native mode.
	if port >= 0x1F0 && port <= 0x1F7 ||
	   port == 0x3F6 ||
	   port >= 0x170 && port <= 0x177 ||
	   port == 0x376 {
		return port, .Suppressed
	}
	return port, .Other
}

@(private = "file")
machine_ide_open_value :: proc(size: u8) -> u32 {
	switch size {
	case 1:
		return 0xFF
	case 2:
		return 0xFFFF
	case 4:
		return 0xFFFF_FFFF
	}
	return 0xFFFF_FFFF
}

@(private = "package")
machine_io_read :: proc(ctx: rawptr, port: u16, size: u8) -> (u32, bool) {
	m := (^Machine)(ctx)
	machine_sync_time(m)
	bus_port, ide_decode := machine_ide_io_decode(m, port, size)
	bmide_offset: u8
	bmide_decoded := false
	if ide_decode == .Other {
		bmide_offset, bmide_decoded = pci_ide_bus_master_decode(&m.pci, port, size)
	}
	acknowledges_ide_irq :=
		ide_decode == .Decoded && bus_port == 0x01F7 && disk.ide_interrupt_pending(&m.ide)
	acknowledges_atapi_irq :=
		ide_decode == .Decoded && bus_port == 0x0177 && disk.atapi_interrupt_pending(&m.atapi)
	v: u32
	if bmide_decoded {
		machine_sync_device(m, .Bmide)
		v = disk.bmide_io_read(&m.bmide, bmide_offset, size)
	} else if ide_decode == .Suppressed {
		v = machine_ide_open_value(size)
	} else {
		v = bus_io_read(&m.bus, bus_port, size)
	}
	if acknowledges_ide_irq || acknowledges_atapi_irq {
		machine_trace_record(m, .Ide_Access, u64(port), u64(size), u64(v))
	} else if ide_decode != .Suppressed {
		if kind := hardware_trace_io_kind(bus_port, false, &m.isa_pnp); kind != .None {
			machine_trace_record(m, kind, u64(port), u64(size), u64(v))
		}
	}
	t := Io_Trace {
		port  = port,
		write = false,
		size  = size,
		val   = v,
	}
	if m.diagnostic_tracing {m.io_hist[m.io_count % IO_HISTORY] = t}
	m.io_count += 1
	if ide_decode == .Decoded {
		if m.bus.diagnostic_tracing {m.ide_hist[m.ide_count % IDE_HISTORY] = t}
		m.ide_count += 1
		machine_record_ide_kernel_probe(m, port, false, size, v)
	}
	machine_rearm_wake(m)
	return v, !m.bus.frozen && !m.reset_requested && !m.power_off_requested
}

@(private = "package")
machine_io_write :: proc(ctx: rawptr, port: u16, size: u8, val: u32) -> bool {
	m := (^Machine)(ctx)
	machine_sync_time(m)
	bus_port, ide_decode := machine_ide_io_decode(m, port, size)
	bmide_offset: u8
	bmide_decoded := false
	if ide_decode == .Other {
		bmide_offset, bmide_decoded = pci_ide_bus_master_decode(&m.pci, port, size)
	}
	t := Io_Trace {
		port  = port,
		write = true,
		size  = size,
		val   = val,
	}
	if m.diagnostic_tracing {m.io_hist[m.io_count % IO_HISTORY] = t}
	m.io_count += 1
	if ide_decode == .Decoded {
		if m.bus.diagnostic_tracing {m.ide_hist[m.ide_count % IDE_HISTORY] = t}
		m.ide_count += 1
		machine_record_ide_kernel_probe(m, port, true, size, val)
	}
	if ide_decode == .Decoded && bus_port == 0x1F7 {
		lba :=
			u32(m.ide.reg_lba_lo) |
			u32(m.ide.reg_lba_mid) << 8 |
			u32(m.ide.reg_lba_hi) << 16 |
			u32(m.ide.reg_drive & 0x0F) << 24
		if m.bus.diagnostic_tracing {m.cmd_hist[m.cmd_count % IDE_HISTORY] = Ide_Cmd_Trace {
				cmd   = u8(val),
				drive = m.ide.reg_drive,
				count = m.ide.reg_seccount,
				lba   = lba,
			}}
		m.cmd_count += 1
	}
	if ide_decode != .Suppressed {
		if kind := hardware_trace_io_kind(bus_port, true, &m.isa_pnp, val); kind != .None {
			machine_trace_record(m, kind, u64(port), u64(size), u64(val))
		}
	}
	if bmide_decoded {
		machine_sync_device(m, .Bmide)
		disk.bmide_io_write(&m.bmide, bmide_offset, size, val)
		machine_trace_record(m, .Bmide_Access, u64(bmide_offset), u64(size), u64(val))
		machine_bmide_synchronize(m)
	} else if ide_decode != .Suppressed {
		bus_io_write(&m.bus, bus_port, size, val)
	}
	machine_rearm_wake(m)
	return !m.bus.frozen && !m.reset_requested && !m.power_off_requested
}

@(private = "package")
machine_io_stream_read :: proc(
	ctx: rawptr,
	port: u16,
	size: u8,
	data: []u8,
) -> (
	completed: int,
	handled, ok: bool,
) {
	m := (^Machine)(ctx)
	if m.diagnostic_tracing {return 0, false, true}
	bus_port, ide_decode := machine_ide_io_decode(m, port, size)
	if ide_decode != .Decoded || bus_port != 0x1F0 && bus_port != 0x170 {
		return 0, false, true
	}
	completed, handled = bus_io_stream_read(&m.bus, bus_port, size, data)
	if handled && completed > 0 {
		value: u32
		for byte in 0 ..< min(int(size), len(data)) {
			value |= u32(data[byte]) << (8 * uint(byte))
		}
		machine_record_ide_kernel_probe(m, port, false, size, value, u32(completed))
	}
	return completed, handled, !m.bus.frozen && !m.reset_requested && !m.power_off_requested
}

@(private = "package")
machine_io_stream_write :: proc(
	ctx: rawptr,
	port: u16,
	size: u8,
	data: []u8,
) -> (
	completed: int,
	handled, ok: bool,
) {
	m := (^Machine)(ctx)
	if m.diagnostic_tracing {return 0, false, true}
	bus_port, ide_decode := machine_ide_io_decode(m, port, size)
	if ide_decode != .Decoded || bus_port != 0x1F0 && bus_port != 0x170 {
		return 0, false, true
	}
	completed, handled = bus_io_stream_write(&m.bus, bus_port, size, data)
	if handled && completed > 0 {
		value: u32
		for byte in 0 ..< min(int(size), len(data)) {
			value |= u32(data[byte]) << (8 * uint(byte))
		}
		machine_record_ide_kernel_probe(m, port, true, size, value, u32(completed))
	}
	return completed, handled, !m.bus.frozen && !m.reset_requested && !m.power_off_requested
}

machine_storage_activity :: proc(m: ^Machine) -> Storage_Activity {
	if m == nil {return {}}
	return {
		floppy = m.fdc.activity_generation,
		hard_drive = m.ide.activity_generation,
		dvd_rom = m.atapi.activity_generation,
	}
}

// VGA owns the legacy aperture; known probe zones read FF / swallow writes.
machine_mmio :: proc(ctx: rawptr, gpa: u64, write: bool, data: []u8) {
	m := (^Machine)(ctx)
	machine_sync_time(m)
	decoded_gpa := hv.cpu_physical_address(&m.vm, gpa)
	machine_trace_record(m, .Mmio_Access, decoded_gpa, u64(len(data)), write ? 1 : 0)
	if offset, decoded := video.gsw_vga_control_offset(&m.gsw_vga, decoded_gpa, len(data));
	   decoded {
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

@(private = "package")
machine_gsw_vga_irq :: proc(ctx: rawptr, asserted: bool) {
	m := (^Machine)(ctx)
	previous := pci_pirq_is_asserted(&m.pci, PCI_GSW_VGA_PIRQ)
	_ = pci_pirq_set_level(&m.pci, PCI_GSW_VGA_PIRQ, asserted)
	if previous != asserted {
		machine_trace_record(
			m,
			.Pirq,
			u64(PCI_GSW_VGA_PIRQ),
			asserted ? 1 : 0,
			u64(pci_pirq_active_irq_mask(&m.pci)),
		)
	}
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

@(private)
machine_io_should_yield :: proc(ctx: rawptr) -> bool {
	m := (^Machine)(ctx)
	requested := m.yield_requested || m.bus.frozen || m.reset_requested || m.power_off_requested
	m.yield_requested = false
	return requested
}

machine_bmide_memory_map :: proc(
	ctx: rawptr,
	address: u64,
	length: int,
	write: bool,
) -> (
	[]u8,
	bool,
) {
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
	_ = disk.bmide_take_irq(&m.bmide, 0)
	_ = disk.bmide_take_irq(&m.bmide, 1)
}

@(private = "file")
machine_bmide_account_completion :: proc(m: ^Machine, transactions_before, bytes_before: u64) {
	transactions_after := m.bmide.channel_transactions[0]
	if transactions_after > transactions_before {
		if m.primary_ide_kernel_dma_request {
			m.primary_ide_kernel_dma_transactions += transactions_after - transactions_before
			m.primary_ide_kernel_dma_bytes += m.bmide.channel_bytes_moved[0] - bytes_before
		}
		m.primary_ide_kernel_dma_request = false
	} else if !m.bmide.channels[0].request_pending && !m.bmide.channels[0].transfer.active {
		m.primary_ide_kernel_dma_request = false
	}
}

machine_primary_ide_kernel_origin :: proc(origin: hv.Io_Origin) -> bool {
	return(
		origin.valid &&
		origin.protected_mode &&
		origin.cpl == 0 &&
		origin.linear >= WIN9X_KERNEL_LINEAR_BASE &&
		origin.linear < u64(BIOS_HIGH_GPA) \
	)
}

machine_bmide_synchronize :: proc(m: ^Machine) {
	machine_sync_device(m, .Bmide)
	transactions_before := m.bmide.channel_transactions[0]
	bytes_before := m.bmide.channel_bytes_moved[0]
	disk.bmide_synchronize(&m.bmide, pci_ide_bus_master_enabled(&m.pci), machine_bmide_memory(m))
	machine_bmide_account_completion(m, transactions_before, bytes_before)
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
machine_sync_ide_irq_routes :: proc(m: ^Machine) {
	if m == nil {return}
	primary_native := pci_ide_channel_native(&m.pci, 0)
	secondary_native := pci_ide_channel_native(&m.pci, 1)
	primary_level := m.ide.irq_signaled && pci_ide_channel_enabled(&m.pci, 0)
	secondary_level := m.atapi.irq_signaled && pci_ide_channel_enabled(&m.pci, 1)
	pic_set_irq_level(&m.pic, 14, primary_level && !primary_native)
	pic_set_irq_level(&m.pic, 15, secondary_level && !secondary_native)
	native_level := primary_level && primary_native || secondary_level && secondary_native
	previous := pci_pirq_is_asserted(&m.pci, PCI_AMD756_IDE_PIRQ)
	_ = pci_pirq_set_level(&m.pci, PCI_AMD756_IDE_PIRQ, native_level)
	if previous != native_level {
		machine_trace_record(
			m,
			.Pirq,
			u64(PCI_AMD756_IDE_PIRQ),
			native_level ? 1 : 0,
			u64(pci_pirq_active_irq_mask(&m.pci)),
		)
	}
}

@(private = "package")
machine_irq14 :: proc(ctx: rawptr, asserted: bool) {
	m := (^Machine)(ctx)
	if asserted {disk.bmide_note_ide_irq(&m.bmide, 0)}
	machine_sync_ide_irq_routes(m)
	if asserted {m.yield_requested = true}
}

@(private = "package")
machine_irq15 :: proc(ctx: rawptr, asserted: bool) {
	m := (^Machine)(ctx)
	if asserted {disk.bmide_note_ide_irq(&m.bmide, 1)}
	machine_sync_ide_irq_routes(m)
	if asserted {m.yield_requested = true}
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
	machine_trace_record(m, .Reset_Request, u64(source))
	machine_record_reset(m, source)
	m.reset_requested = true
	m.reset_reason = fmt.tprintf("guest requested hardware reset (%s)", machine_reset_name(source))
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
machine_isa_pnp_restore_passive :: proc(m: ^Machine) {
	if !m.isa_pnp_passive_installed {return}
	port := m.isa_pnp_passive_port
	if m.bus.passive[int(port)] == u16(0x100) {m.bus.passive[int(port)] = 0}
	m.isa_pnp_passive_port = 0
	m.isa_pnp_passive_installed = false
}

@(private = "file")
machine_isa_pnp_sync_read_data :: proc(m: ^Machine) {
	port, programmed := isa_pnp_read_data_selection(&m.isa_pnp)
	if m.isa_pnp_passive_installed && programmed && port == m.isa_pnp_passive_port {return}
	machine_isa_pnp_restore_passive(m)
	if !programmed || m.bus.io[int(port)].read != nil || m.bus.passive[int(port)] != 0 {return}
	bus_register_passive(&m.bus, 0xFF, port)
	m.isa_pnp_passive_port = port
	m.isa_pnp_passive_installed = true
}

@(private = "file")
machine_isa_pnp_write :: proc(ctx: rawptr, port: u16, size: u8, val: u32) {
	m := (^Machine)(ctx)
	_ = isa_pnp_out(&m.isa_pnp, port, u8(val))
	machine_isa_pnp_sync_read_data(m)
}

@(private = "package")
machine_init_isa_pnp :: proc(m: ^Machine) {
	isa_pnp_init(&m.isa_pnp)
	m.isa_pnp_passive_port = 0
	m.isa_pnp_passive_installed = false
	address_h := Io_Handler {
		ctx   = m,
		read  = machine_lpt_read,
		write = machine_isa_pnp_write,
	}
	bus_register_byte_decomposed(&m.bus, ISA_PNP_ADDRESS_PORT, ISA_PNP_ADDRESS_PORT, address_h)
	write_data_h := Io_Handler {
		ctx   = m,
		write = machine_isa_pnp_write,
	}
	bus_register(&m.bus, ISA_PNP_WRITE_DATA_PORT, ISA_PNP_WRITE_DATA_PORT, write_data_h)
	bus_whitelist(&m.bus, ISA_PNP_WRITE_DATA_PORT)
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
	return pci_in(&m.pci, port, size)
}

@(private = "package")
machine_sync_pci_devices :: proc(m: ^Machine) -> bool {
	if m == nil {return false}
	ide_io := pci_ide_io_enabled(&m.pci)
	disk.ide_set_pci_decode(&m.ide, ide_io, pci_ide_channel_enabled(&m.pci, 0))
	disk.atapi_set_pci_decode(&m.atapi, ide_io, pci_ide_channel_enabled(&m.pci, 1))
	machine_sync_ide_irq_routes(m)

	vga_io := pci_gsw_vga_io_enabled(&m.pci)
	vga_memory := pci_gsw_vga_memory_enabled(&m.pci)
	control_base := pci_gsw_vga_control_base(&m.pci)
	framebuffer_base := pci_gsw_vga_framebuffer_base(&m.pci)
	framebuffer := video.vga_vram(&m.vga)
	if m.vm.part != nil &&
	   len(framebuffer) > 0 &&
	   !hv.set_device_memory_mapping(&m.vm, framebuffer, framebuffer_base, vga_memory) {
		return false
	}
	video.vga_set_pci_decode(&m.vga, vga_io, vga_memory, framebuffer_base)
	video.gsw_vga_set_pci_decode(&m.gsw_vga, vga_memory, control_base)
	return true
}

@(private = "package")
machine_pci_write :: proc(ctx: rawptr, port: u16, size: u8, val: u32) {
	m := (^Machine)(ctx)
	machine_sync_time(m)
	pci_out(&m.pci, port, size, val)
	if !machine_sync_pci_devices(m) {
		bus_freeze(&m.bus, "PCI device decode synchronization failed")
		return
	}
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

@(private = "package")
machine_ide_write :: proc(ctx: rawptr, port: u16, size: u8, val: u32) {
	m := (^Machine)(ctx)
	machine_sync_time(m)
	machine_sync_device(m, .Ide)
	primary_command := disk.ide_io_decoded(&m.ide) && port == 0x1F7 && m.ide.reg_drive & 0x10 == 0
	software_reset := disk.ide_io_decoded(&m.ide) && port == 0x3F6 && val & 0x04 != 0
	if primary_command || software_reset {
		disk.bmide_cancel_request(&m.bmide, 0)
		m.primary_ide_kernel_dma_request = false
	}
	if primary_command {
		command := u8(val)
		if command == 0xC8 || command == 0xC9 || command == 0xCA || command == 0xCB {
			m.primary_ide_kernel_dma_request = machine_primary_ide_kernel_origin(m.vm.io_origin)
		}
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

@(private = "package")
machine_atapi_write :: proc(ctx: rawptr, port: u16, size: u8, val: u32) {
	m := (^Machine)(ctx)
	machine_sync_time(m)
	machine_sync_device(m, .Atapi)
	cdda_generation := disk.atapi_cdda_generation(&m.atapi)
	trace_count := m.atapi.trace_count
	if disk.atapi_io_decoded(&m.atapi) &&
	   (port == 0x177 && m.atapi.reg_drive & 0x10 == 0 || port == 0x376 && val & 0x04 != 0) {
		disk.bmide_cancel_request(&m.bmide, 1)
	}
	disk.atapi_io_write(&m.atapi, port, size, val)
	machine_trace_atapi_packets(m, trace_count)
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

@(private = "package")
machine_atapi_stream_write :: proc(ctx: rawptr, port: u16, size: u8, data: []u8) -> int {
	if port != 0x170 || size == 0 {return 0}
	m := (^Machine)(ctx)
	machine_sync_device(m, .Atapi)
	cdda_generation := disk.atapi_cdda_generation(&m.atapi)
	trace_count := m.atapi.trace_count
	elements := len(data) / int(size)
	for element in 0 ..< elements {
		value: u32
		base := element * int(size)
		for byte in 0 ..< int(size) {value |= u32(data[base + byte]) << (8 * uint(byte))}
		disk.atapi_io_write(&m.atapi, port, size, value)
	}
	machine_trace_atapi_packets(m, trace_count)
	if disk.atapi_cdda_generation(&m.atapi) != cdda_generation {machine_audio_reset_cdda(m)}
	machine_bmide_submit_atapi(m)
	machine_rearm_wake(m)
	return elements
}

@(private = "file")
machine_trace_atapi_packets :: proc(m: ^Machine, previous_count: u64) {
	if m == nil || m.atapi.trace_count <= previous_count {return}
	first := max(
		previous_count,
		m.atapi.trace_count - min(m.atapi.trace_count, u64(disk.ATAPI_TRACE_HISTORY)),
	)
	for sequence in first ..< m.atapi.trace_count {
		entry := &m.atapi.trace_hist[sequence % disk.ATAPI_TRACE_HISTORY]
		result :=
			u64(entry.dispatch_status) |
			u64(entry.dispatch_error) << 8 |
			u64(entry.dispatch_key) << 16 |
			u64(entry.dispatch_asc) << 24 |
			u64(entry.dispatch_ascq) << 32
		machine_trace_record(
			m,
			.Atapi_Packet,
			u64(entry.packet[0]),
			u64(entry.phase_limit),
			result,
		)
	}
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
