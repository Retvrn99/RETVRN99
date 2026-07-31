// SPDX-License-Identifier: GPL-3.0-only
package machine

import "core:fmt"

PC_AT_RESET_HISTORY :: 32
APM_POWER_OFF_PORT :: u16(0xB004)
APM_POWER_OFF_VALUE :: u16(0x2000)

Reset_Provenance :: enum u8 {
	None,
	Kbc_Controller_Pulse,
	Kbc_Output_Port,
	Port_92,
	Pci_Cf9,
	Triple_Fault,
	Dos_Extender_Warm_Resume,
}

Reset_Record :: struct {
	source:        Reset_Provenance,
	master_tick:   u64,
	cmos_shutdown: u8,
}

Pc_At_Reset_State :: struct {
	reset_requested:   bool,
	reset_source:      Reset_Provenance,
	reset_reason:      string,
	reset_history:     [PC_AT_RESET_HISTORY]Reset_Record,
	reset_count:       u64,
	cpu_reset_pending: bool,
	cpu_reset_reason:  string,
	cpu_reset_cmos_0f: u8,
	cpu_reset_count:   u64,
	reset_control:     u8,
}

Pc_At_Power_State :: struct {
	power_off_requested: bool,
	power_off_reason:    string,
}

Pc_At_Device :: enum u8 {
	Pit,
	Uart1,
	Uart2,
	Lpt1,
	Lpt2,
	Dma,
	I8042,
	Cmos,
	Count,
}

Pc_At_Deadline_Basis :: enum u8 {
	Master_Tick,
	Relative_Nanoseconds,
}

Pc_At_Deadline :: struct {
	device:  Pc_At_Device,
	basis:   Pc_At_Deadline_Basis,
	value:   u64,
	pending: bool,
}

Pc_At_Advance_Result :: struct {
	device:          Pc_At_Device,
	pit_transitions: bool,
}

Pc_At_Event_Kind :: enum u8 {
	Shutdown_Marker,
	Apm_Write,
	Progress,
	Reset_Request,
}

Pc_At_Event :: struct {
	kind: Pc_At_Event_Kind,
	a:    u64,
	b:    u64,
	c:    u64,
}

Pc_At_Guest_Memory_Proc :: proc(ctx: rawptr) -> []u8
Pc_At_Apply_A20_Proc :: proc(ctx: rawptr, enabled: bool) -> bool
Pc_At_Freeze_Proc :: proc(ctx: rawptr, reason: string)
Pc_At_Master_Now_Proc :: proc(ctx: rawptr) -> u64
Pc_At_Master_Advance_Ns_Proc :: proc(ctx: rawptr, nanoseconds: u64)
Pc_At_Sync_Device_Proc :: proc(ctx: rawptr, device: Pc_At_Device)
Pc_At_Audio_Sync_Proc :: proc(ctx: rawptr)
Pc_At_Audio_Pit_Changed_Proc :: proc(ctx: rawptr)
Pc_At_Irq_Window_Proc :: proc(ctx: rawptr)
Pc_At_Event_Proc :: proc(ctx: rawptr, event: Pc_At_Event)

Pc_At_Adapters :: struct {
	ctx:                rawptr,
	guest_memory:       Pc_At_Guest_Memory_Proc,
	apply_a20:          Pc_At_Apply_A20_Proc,
	freeze:             Pc_At_Freeze_Proc,
	master_now:         Pc_At_Master_Now_Proc,
	master_advance_ns:  Pc_At_Master_Advance_Ns_Proc,
	sync_device:        Pc_At_Sync_Device_Proc,
	audio_sync:         Pc_At_Audio_Sync_Proc,
	audio_pit_changed:  Pc_At_Audio_Pit_Changed_Proc,
	request_irq_window: Pc_At_Irq_Window_Proc,
	event:              Pc_At_Event_Proc,
}

Pc_At_Platform :: struct {
	bus:       Bus,
	pic:       Pic_Pair,
	pit:       Pit,
	cmos:      Cmos,
	kbd:       I8042,
	dma:       Dma,
	serial1:   Uart_16450,
	serial2:   Uart_16450,
	parallel1: Lpt,
	parallel2: Lpt,
	isa_pnp:   Isa_Pnp,

	isa_pnp_passive_port:      u16,
	isa_pnp_passive_installed: bool,
	isa_delay:                 Isa_Delay,
	reset:                     Pc_At_Reset_State,
	power:                     Pc_At_Power_State,
	a20_enabled:               bool,
	cmos_active_ns:            u64,
	adapters:                  Pc_At_Adapters,
}

pc_at_platform_bus :: proc(platform: ^Pc_At_Platform) -> ^Bus {
	return platform == nil ? nil : &platform.bus
}

pc_at_platform_pic :: proc(platform: ^Pc_At_Platform) -> ^Pic_Pair {
	return platform == nil ? nil : &platform.pic
}

pc_at_platform_cmos :: proc(platform: ^Pc_At_Platform) -> ^Cmos {
	return platform == nil ? nil : &platform.cmos
}

pc_at_platform_dma :: proc(platform: ^Pc_At_Platform) -> ^Dma {
	return platform == nil ? nil : &platform.dma
}

pc_at_platform_emit :: proc(platform: ^Pc_At_Platform, event: Pc_At_Event) {
	if platform != nil && platform.adapters.event != nil {
		platform.adapters.event(platform.adapters.ctx, event)
	}
}

pc_at_platform_master_now :: proc(platform: ^Pc_At_Platform) -> u64 {
	if platform == nil || platform.adapters.master_now == nil {return 0}
	return platform.adapters.master_now(platform.adapters.ctx)
}

pc_at_platform_freeze :: proc(platform: ^Pc_At_Platform, reason: string) {
	if platform == nil {return}
	if platform.adapters.freeze != nil {
		platform.adapters.freeze(platform.adapters.ctx, reason)
	} else {
		bus_freeze(&platform.bus, reason)
	}
}

pc_at_platform_irq1 :: proc(ctx: rawptr) {
	platform := (^Pc_At_Platform)(ctx)
	if platform != nil {pic_raise(&platform.pic, 1)}
}

pc_at_platform_irq12 :: proc(ctx: rawptr) {
	platform := (^Pc_At_Platform)(ctx)
	if platform != nil {pic_raise(&platform.pic, 12)}
}

pc_at_platform_irq1_lower :: proc(ctx: rawptr) {
	platform := (^Pc_At_Platform)(ctx)
	if platform != nil {pic_lower(&platform.pic, 1)}
}

pc_at_platform_irq12_lower :: proc(ctx: rawptr) {
	platform := (^Pc_At_Platform)(ctx)
	if platform != nil {pic_lower(&platform.pic, 12)}
}

pc_at_platform_reset_name :: proc(source: Reset_Provenance) -> string {
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

pc_at_platform_record_reset :: proc(platform: ^Pc_At_Platform, source: Reset_Provenance) {
	if platform == nil {return}
	index := platform.reset.reset_count % PC_AT_RESET_HISTORY
	platform.reset.reset_history[index] = {
		source        = source,
		master_tick   = pc_at_platform_master_now(platform),
		cmos_shutdown = platform.cmos.ram[0x0F],
	}
	platform.reset.reset_count += 1
	platform.reset.reset_source = source
	pc_at_platform_emit(platform, {kind = .Reset_Request, a = u64(source)})
}

pc_at_platform_request_reset :: proc(platform: ^Pc_At_Platform, source: Reset_Provenance) {
	if platform == nil || platform.reset.reset_requested {return}
	pc_at_platform_record_reset(platform, source)
	platform.reset.reset_requested = true
	platform.reset.reset_reason = fmt.tprintf(
		"guest requested hardware reset (%s)",
		pc_at_platform_reset_name(source),
	)
}

pc_at_platform_guest_reset :: proc(ctx: rawptr) {
	platform := (^Pc_At_Platform)(ctx)
	if platform == nil {return}
	source: Reset_Provenance
	switch platform.kbd.reset_source {
	case .Controller_Pulse:
		source = .Kbc_Controller_Pulse
	case .Output_Port:
		source = .Kbc_Output_Port
	case .Fast_A20:
		source = .Port_92
	case .None:
		source = .Kbc_Controller_Pulse
	}
	pc_at_platform_request_reset(platform, source)
}

pc_at_platform_a20_control :: proc(ctx: rawptr, enabled: bool) -> bool {
	platform := (^Pc_At_Platform)(ctx)
	if platform == nil {return false}
	if platform.adapters.apply_a20 != nil &&
	   !platform.adapters.apply_a20(platform.adapters.ctx, enabled) {
		pc_at_platform_freeze(platform, "A20 mapping failed")
		return false
	}
	platform.a20_enabled = enabled
	return true
}

pc_at_platform_init :: proc(
	platform: ^Pc_At_Platform,
	ram_size: u64,
	adapters: Pc_At_Adapters,
) -> bool {
	if platform == nil || ram_size == 0 {return false}
	platform^ = {}
	platform.adapters = adapters
	bus_init(&platform.bus)
	pit_init(&platform.pit)
	cmos_init(&platform.cmos, ram_size)
	i8042_init(
		&platform.kbd,
		platform,
		pc_at_platform_irq1,
		pc_at_platform_irq12,
		pc_at_platform_guest_reset,
		pc_at_platform_a20_control,
	)
	i8042_set_irq_lower_callbacks(
		&platform.kbd,
		pc_at_platform_irq1_lower,
		pc_at_platform_irq12_lower,
	)
	uart_init_com1(&platform.serial1)
	uart_init_com2(&platform.serial2)
	lpt_init_lpt1(&platform.parallel1)
	lpt_init_lpt2(&platform.parallel2)
	dma_init(&platform.dma)
	isa_pnp_init(&platform.isa_pnp)
	platform.a20_enabled = true
	return true
}

pc_at_platform_destroy :: proc(platform: ^Pc_At_Platform) {
	if platform == nil {return}
	bus_destroy(&platform.bus)
	platform^ = {}
}

pc_at_platform_sync :: proc(platform: ^Pc_At_Platform, device: Pc_At_Device) {
	if platform != nil && platform.adapters.sync_device != nil {
		platform.adapters.sync_device(platform.adapters.ctx, device)
	}
}

pc_at_platform_audio_sync :: proc(platform: ^Pc_At_Platform) {
	if platform != nil && platform.adapters.audio_sync != nil {
		platform.adapters.audio_sync(platform.adapters.ctx)
	}
}

pc_at_platform_audio_pit_changed :: proc(platform: ^Pc_At_Platform) {
	if platform != nil && platform.adapters.audio_pit_changed != nil {
		platform.adapters.audio_pit_changed(platform.adapters.ctx)
	}
}

pc_at_platform_deadline :: proc(
	platform: ^Pc_At_Platform,
	device: Pc_At_Device,
	active_ns: u64,
) -> Pc_At_Deadline {
	result := Pc_At_Deadline{device = device}
	if platform == nil {return result}
	switch device {
	case .Pit:
		result.value, result.pending = pit_next_deadline(&platform.pit)
	case .Uart1:
		result.value, result.pending = uart_next_deadline(&platform.serial1)
	case .Uart2:
		result.value, result.pending = uart_next_deadline(&platform.serial2)
	case .Lpt1:
		result.value, result.pending = lpt_next_deadline(&platform.parallel1)
	case .Lpt2:
		result.value, result.pending = lpt_next_deadline(&platform.parallel2)
	case .Dma:
		result.value, result.pending = dma_next_deadline(&platform.dma)
	case .I8042:
		result.basis = .Relative_Nanoseconds
		if deadline, ok := i8042_next_deadline(&platform.kbd); ok {
			result.value = deadline > active_ns ? deadline - active_ns : 0
			result.pending = true
		}
	case .Cmos:
		result.basis = .Relative_Nanoseconds
		result.value = cmos_next_deadline_ns(&platform.cmos)
		result.pending = true
	case .Count:
	}
	return result
}

pc_at_platform_advance :: proc(
	platform: ^Pc_At_Platform,
	device: Pc_At_Device,
	active_ns: u64,
) -> Pc_At_Advance_Result {
	result := Pc_At_Advance_Result{device = device}
	if platform == nil {return result}
	now := pc_at_platform_master_now(platform)
	switch device {
	case .Pit:
		for _ in 0 ..< pit_advance_to(&platform.pit, now) {pic_raise(&platform.pic, 0)}
		result.pit_transitions = true
	case .Uart1:
		uart_advance_to(&platform.serial1, now)
		if uart_take_irq(&platform.serial1) {
			pic_raise(&platform.pic, uart_irq_number(&platform.serial1))
		}
	case .Uart2:
		uart_advance_to(&platform.serial2, now)
		if uart_take_irq(&platform.serial2) {
			pic_raise(&platform.pic, uart_irq_number(&platform.serial2))
		}
	case .Lpt1:
		lpt_advance_to(&platform.parallel1, now)
		if lpt_take_irq(&platform.parallel1) {
			pic_raise(&platform.pic, lpt_irq_number(&platform.parallel1))
		}
	case .Lpt2:
		lpt_advance_to(&platform.parallel2, now)
		if lpt_take_irq(&platform.parallel2) {
			pic_raise(&platform.pic, lpt_irq_number(&platform.parallel2))
		}
	case .Dma:
		memory: []u8
		if platform.adapters.guest_memory != nil {
			memory = platform.adapters.guest_memory(platform.adapters.ctx)
		}
		_ = dma_advance_to(&platform.dma, now, memory)
	case .I8042:
		i8042_advance_to(&platform.kbd, active_ns)
	case .Cmos:
		elapsed := active_ns - min(active_ns, platform.cmos_active_ns)
		for _ in 0 ..< cmos_advance(&platform.cmos, elapsed) {pic_raise(&platform.pic, 8)}
		platform.cmos_active_ns = active_ns
	case .Count:
	}
	return result
}

pc_at_platform_irq_raise :: proc(platform: ^Pc_At_Platform, irq: u8) {
	if platform != nil {pic_raise(&platform.pic, irq)}
}

pc_at_platform_irq_lower :: proc(platform: ^Pc_At_Platform, irq: u8) {
	if platform != nil {pic_lower(&platform.pic, irq)}
}

pc_at_platform_irq_level :: proc(platform: ^Pc_At_Platform, irq: u8, asserted: bool) {
	if platform != nil {pic_set_irq_level(&platform.pic, irq, asserted)}
}

pc_at_pic_read :: proc(ctx: rawptr, port: u16, size: u8) -> u32 {
	platform := (^Pc_At_Platform)(ctx)
	value: u32
	for i in 0 ..< int(size) {
		value |= u32(pic_in(&platform.pic, port + u16(i))) << (8 * uint(i))
	}
	return value
}

pc_at_pic_write :: proc(ctx: rawptr, port: u16, size: u8, value: u32) {
	platform := (^Pc_At_Platform)(ctx)
	for i in 0 ..< int(size) {
		pic_out(&platform.pic, port + u16(i), u8(value >> (8 * uint(i))))
	}
	if pic_has_pending(&platform.pic) && platform.adapters.request_irq_window != nil {
		platform.adapters.request_irq_window(platform.adapters.ctx)
	}
}

pc_at_pit_read :: proc(ctx: rawptr, port: u16, size: u8) -> u32 {
	platform := (^Pc_At_Platform)(ctx)
	pc_at_platform_audio_sync(platform)
	value: u32
	for i in 0 ..< int(size) {
		value |= u32(pit_in(&platform.pit, port + u16(i))) << (8 * uint(i))
	}
	return value
}

pc_at_pit_write :: proc(ctx: rawptr, port: u16, size: u8, value: u32) {
	platform := (^Pc_At_Platform)(ctx)
	pc_at_platform_audio_sync(platform)
	for i in 0 ..< int(size) {
		pit_out(&platform.pit, port + u16(i), u8(value >> (8 * uint(i))))
	}
	pc_at_platform_audio_pit_changed(platform)
}

pc_at_port61_read :: proc(ctx: rawptr, _: u16, _: u8) -> u32 {
	platform := (^Pc_At_Platform)(ctx)
	pc_at_platform_audio_sync(platform)
	return u32(pit_port61_read(&platform.pit))
}

pc_at_port61_write :: proc(ctx: rawptr, _: u16, _: u8, value: u32) {
	platform := (^Pc_At_Platform)(ctx)
	pc_at_platform_audio_sync(platform)
	pit_port61_write(&platform.pit, u8(value))
	pc_at_platform_audio_pit_changed(platform)
}

pc_at_uart_for_port :: proc(platform: ^Pc_At_Platform, port: u16) -> (^Uart_16450, Pc_At_Device) {
	if port >= UART_COM1_BASE && port <= UART_COM1_BASE + 7 {
		return &platform.serial1, .Uart1
	}
	return &platform.serial2, .Uart2
}

pc_at_uart_read :: proc(ctx: rawptr, port: u16, _: u8) -> u32 {
	platform := (^Pc_At_Platform)(ctx)
	uart, device := pc_at_uart_for_port(platform, port)
	pc_at_platform_sync(platform, device)
	value, _ := uart_in(uart, port)
	return u32(value)
}

pc_at_uart_write :: proc(ctx: rawptr, port: u16, _: u8, value: u32) {
	platform := (^Pc_At_Platform)(ctx)
	uart, device := pc_at_uart_for_port(platform, port)
	pc_at_platform_sync(platform, device)
	_ = uart_out(uart, port, u8(value))
	if uart_take_irq(uart) {pic_raise(&platform.pic, uart_irq_number(uart))}
}

pc_at_lpt_for_port :: proc(platform: ^Pc_At_Platform, port: u16) -> (^Lpt, Pc_At_Device) {
	if port >= LPT1_BASE && port <= LPT1_BASE + 2 {
		return &platform.parallel1, .Lpt1
	}
	return &platform.parallel2, .Lpt2
}

pc_at_lpt_read :: proc(ctx: rawptr, port: u16, _: u8) -> u32 {
	platform := (^Pc_At_Platform)(ctx)
	lpt, device := pc_at_lpt_for_port(platform, port)
	pc_at_platform_sync(platform, device)
	value, _ := lpt_in(lpt, port)
	return u32(value)
}

pc_at_lpt_write :: proc(ctx: rawptr, port: u16, _: u8, value: u32) {
	platform := (^Pc_At_Platform)(ctx)
	lpt, device := pc_at_lpt_for_port(platform, port)
	pc_at_platform_sync(platform, device)
	_ = lpt_out(lpt, port, u8(value))
}

pc_at_isa_pnp_restore_passive :: proc(platform: ^Pc_At_Platform) {
	if !platform.isa_pnp_passive_installed {return}
	port := platform.isa_pnp_passive_port
	if platform.bus.passive[int(port)] == u16(0x100) {platform.bus.passive[int(port)] = 0}
	platform.isa_pnp_passive_port = 0
	platform.isa_pnp_passive_installed = false
}

pc_at_isa_pnp_sync_read_data :: proc(platform: ^Pc_At_Platform) {
	port, programmed := isa_pnp_read_data_selection(&platform.isa_pnp)
	if platform.isa_pnp_passive_installed &&
	   programmed &&
	   port == platform.isa_pnp_passive_port {
		return
	}
	pc_at_isa_pnp_restore_passive(platform)
	if !programmed || platform.bus.io[int(port)].read != nil || platform.bus.passive[int(port)] != 0 {
		return
	}
	bus_register_passive(&platform.bus, 0xFF, port)
	platform.isa_pnp_passive_port = port
	platform.isa_pnp_passive_installed = true
}

pc_at_isa_pnp_write :: proc(ctx: rawptr, port: u16, _: u8, value: u32) {
	platform := (^Pc_At_Platform)(ctx)
	_ = isa_pnp_out(&platform.isa_pnp, port, u8(value))
	pc_at_isa_pnp_sync_read_data(platform)
}

pc_at_cmos_read :: proc(ctx: rawptr, port: u16, size: u8) -> u32 {
	platform := (^Pc_At_Platform)(ctx)
	pc_at_platform_sync(platform, .Cmos)
	value: u32
	for i in 0 ..< int(size) {
		value |= u32(cmos_in(&platform.cmos, port + u16(i))) << (8 * uint(i))
	}
	return value
}

pc_at_cmos_write :: proc(ctx: rawptr, port: u16, size: u8, value: u32) {
	platform := (^Pc_At_Platform)(ctx)
	pc_at_platform_sync(platform, .Cmos)
	for i in 0 ..< int(size) {
		cmos_out(&platform.cmos, port + u16(i), u8(value >> (8 * uint(i))))
	}
	for _ in 0 ..< cmos_advance(&platform.cmos, 0) {pic_raise(&platform.pic, 8)}
}

pc_at_kbd_read :: proc(ctx: rawptr, port: u16, _: u8) -> u32 {
	platform := (^Pc_At_Platform)(ctx)
	pc_at_platform_sync(platform, .I8042)
	return u32(i8042_in(&platform.kbd, port))
}

pc_at_kbd_write :: proc(ctx: rawptr, port: u16, _: u8, value: u32) {
	platform := (^Pc_At_Platform)(ctx)
	pc_at_platform_sync(platform, .I8042)
	i8042_out(&platform.kbd, port, u8(value))
}

pc_at_dma_read :: proc(ctx: rawptr, port: u16, size: u8) -> u32 {
	platform := (^Pc_At_Platform)(ctx)
	pc_at_platform_sync(platform, .Dma)
	value: u32
	for i in 0 ..< int(size) {
		value |= u32(dma_in(&platform.dma, port + u16(i))) << (8 * uint(i))
	}
	return value
}

pc_at_dma_write :: proc(ctx: rawptr, port: u16, size: u8, value: u32) {
	platform := (^Pc_At_Platform)(ctx)
	pc_at_platform_sync(platform, .Dma)
	for i in 0 ..< int(size) {
		dma_out(&platform.dma, port + u16(i), u8(value >> (8 * uint(i))))
	}
}

pc_at_port80_read :: proc(ctx: rawptr, _: u16, _: u8) -> u32 {
	platform := (^Pc_At_Platform)(ctx)
	value, elapsed_ns := isa_delay_read(&platform.isa_delay)
	if platform.adapters.master_advance_ns != nil {
		platform.adapters.master_advance_ns(platform.adapters.ctx, elapsed_ns)
	}
	return u32(value)
}

pc_at_port80_write :: proc(ctx: rawptr, _: u16, size: u8, value: u32) {
	platform := (^Pc_At_Platform)(ctx)
	if platform == nil || size == 0 {return}
	elapsed_ns := isa_delay_write(&platform.isa_delay, u8(value))
	if platform.adapters.master_advance_ns != nil {
		platform.adapters.master_advance_ns(platform.adapters.ctx, elapsed_ns)
	}
	pc_at_platform_emit(platform, {kind = .Shutdown_Marker, a = u64(u8(value))})
}

pc_at_reset_control_read :: proc(ctx: rawptr, _: u16, _: u8) -> u32 {
	return u32((^Pc_At_Platform)(ctx).reset.reset_control)
}

pc_at_reset_control_write :: proc(ctx: rawptr, _: u16, size: u8, value: u32) {
	if size != 1 {return}
	platform := (^Pc_At_Platform)(ctx)
	platform.reset.reset_control = u8(value) & 0x02
	if value & 0x04 != 0 {pc_at_platform_request_reset(platform, .Pci_Cf9)}
}

pc_at_apm_power_read :: proc(_: rawptr, _: u16, size: u8) -> u32 {
	if size == 0 || size > 4 {return 0xFFFF_FFFF}
	return 0
}

pc_at_platform_request_power_off :: proc(platform: ^Pc_At_Platform, reason: string) {
	if platform == nil || platform.power.power_off_requested {return}
	platform.power.power_off_requested = true
	platform.power.power_off_reason = reason
}

pc_at_apm_power_write :: proc(ctx: rawptr, port: u16, size: u8, value: u32) {
	if ctx == nil || port != APM_POWER_OFF_PORT {return}
	platform := (^Pc_At_Platform)(ctx)
	pc_at_platform_emit(platform, {kind = .Apm_Write, a = u64(size), b = u64(value)})
	if size < 2 || u16(value) != APM_POWER_OFF_VALUE {return}
	pc_at_platform_emit(platform, {kind = .Progress, a = u64(port), b = u64(value), c = 1})
	pc_at_platform_request_power_off(platform, "guest requested APM power off")
}

pc_at_whitelist_range :: proc(bus: ^Bus, first, last: u16) {
	for port := first; port <= last; port += 1 {
		bus_whitelist(bus, port)
		if port == last {break}
	}
}

pc_at_platform_install_fixed_io :: proc(platform: ^Pc_At_Platform) {
	if platform == nil {return}
	bus := &platform.bus
	bus_register(bus, 0x20, 0x21, {ctx = platform, read = pc_at_pic_read, write = pc_at_pic_write})
	bus_register(bus, 0xA0, 0xA1, {ctx = platform, read = pc_at_pic_read, write = pc_at_pic_write})
	bus_register(bus, 0x4D0, 0x4D1, {ctx = platform, read = pc_at_pic_read, write = pc_at_pic_write})
	bus_register(bus, 0x40, 0x43, {ctx = platform, read = pc_at_pit_read, write = pc_at_pit_write})
	bus_register(bus, 0x61, 0x61, {ctx = platform, read = pc_at_port61_read, write = pc_at_port61_write})
	bus_register_byte_decomposed(
		bus,
		UART_COM1_BASE,
		UART_COM1_BASE + 7,
		{ctx = platform, read = pc_at_uart_read, write = pc_at_uart_write},
	)
	bus_register_byte_decomposed(
		bus,
		UART_COM2_BASE,
		UART_COM2_BASE + 7,
		{ctx = platform, read = pc_at_uart_read, write = pc_at_uart_write},
	)
	bus_register_byte_decomposed(
		bus,
		LPT1_BASE,
		LPT1_BASE + 2,
		{ctx = platform, read = pc_at_lpt_read, write = pc_at_lpt_write},
	)
	bus_register_byte_decomposed(
		bus,
		LPT2_BASE,
		LPT2_BASE + 2,
		{ctx = platform, read = pc_at_lpt_read, write = pc_at_lpt_write},
	)
	bus_whitelist(bus, LPT1_BASE + LPT_ECR_OFFSET, LPT2_BASE + LPT_ECR_OFFSET)
	bus_whitelist(bus, LPT1_BASE + LPT_ALIAS_PROBE_OFFSET, LPT2_BASE + LPT_ALIAS_PROBE_OFFSET)
	bus_register_byte_decomposed(
		bus,
		ISA_PNP_ADDRESS_PORT,
		ISA_PNP_ADDRESS_PORT,
		{ctx = platform, read = pc_at_lpt_read, write = pc_at_isa_pnp_write},
	)
	bus_register(
		bus,
		ISA_PNP_WRITE_DATA_PORT,
		ISA_PNP_WRITE_DATA_PORT,
		{ctx = platform, write = pc_at_isa_pnp_write},
	)
	bus_whitelist(bus, ISA_PNP_WRITE_DATA_PORT)
	bus_register(bus, 0x70, 0x71, {ctx = platform, read = pc_at_cmos_read, write = pc_at_cmos_write})
	bus_register(bus, 0x60, 0x60, {ctx = platform, read = pc_at_kbd_read, write = pc_at_kbd_write})
	bus_register(bus, 0x64, 0x64, {ctx = platform, read = pc_at_kbd_read, write = pc_at_kbd_write})
	bus_register(bus, 0x92, 0x92, {ctx = platform, read = pc_at_kbd_read, write = pc_at_kbd_write})
	dma_handler := Io_Handler{ctx = platform, read = pc_at_dma_read, write = pc_at_dma_write}
	bus_register(bus, 0x00, 0x0F, dma_handler)
	for port := u16(0xC0); port <= 0xDE; port += 2 {bus_register(bus, port, port, dma_handler)}
	dma_page_ports := [?]u16 {
		0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88,
		0x89, 0x8A, 0x8B, 0x8C, 0x8D, 0x8E, 0x8F,
	}
	for port in dma_page_ports {
		bus_register(bus, port, port, dma_handler)
	}
	bus_register(bus, 0x80, 0x80, {ctx = platform, read = pc_at_port80_read, write = pc_at_port80_write})
	bus_register(bus, 0xCF9, 0xCF9, {ctx = platform, read = pc_at_reset_control_read, write = pc_at_reset_control_write})
	bus_register(bus, APM_POWER_OFF_PORT, APM_POWER_OFF_PORT, {ctx = platform, read = pc_at_apm_power_read, write = pc_at_apm_power_write})

	bus_whitelist(bus, 0x81, 0xED)
	bus_whitelist(bus, 0x421, 0x4A1)
	bus_whitelist(bus, 0x94, 0x102)
	pc_at_whitelist_range(bus, 0x3E8, 0x3EF)
	pc_at_whitelist_range(bus, 0x2E8, 0x2EF)
	pc_at_whitelist_range(bus, 0x2F2, 0x2F7)
	pc_at_whitelist_range(bus, 0x6F2, 0x6F7)
	pc_at_whitelist_range(bus, 0x1E8, 0x1EF)
	pc_at_whitelist_range(bus, 0x168, 0x16F)
	bus_whitelist(bus, 0x36E, 0x36F)
	pc_at_whitelist_range(bus, 0x130, 0x13F)
	pc_at_whitelist_range(bus, 0x180, 0x18F)
	pc_at_whitelist_range(bus, 0x200, 0x207)
	pc_at_whitelist_range(bus, 0x230, 0x23F)
	pc_at_whitelist_range(bus, 0x240, 0x24F)
	pc_at_whitelist_range(bus, 0x280, 0x29F)
	pc_at_whitelist_range(bus, 0x620, 0x623)
	pc_at_whitelist_range(bus, 0xA20, 0xA23)
	pc_at_whitelist_range(bus, 0xE20, 0xE23)
	pc_at_whitelist_range(bus, 0x300, 0x31F)
	pc_at_whitelist_range(bus, 0x330, 0x35F)
}
