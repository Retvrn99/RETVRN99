// SPDX-License-Identifier: GPL-3.0-only
package machine

import "core:strings"
import "core:testing"

Pc_At_Test_Context :: struct {
	memory:             [256]u8,
	master_tick:        u64,
	advanced_ns:        u64,
	a20_applied:        bool,
	a20_apply_ok:       bool,
	freeze_reason:      string,
	irq_window_requests: u64,
	events:             [16]Pc_At_Event,
	event_count:        int,
}

pc_at_test_guest_memory :: proc(ctx: rawptr) -> []u8 {
	return (^Pc_At_Test_Context)(ctx).memory[:]
}

pc_at_test_apply_a20 :: proc(ctx: rawptr, enabled: bool) -> bool {
	test_ctx := (^Pc_At_Test_Context)(ctx)
	test_ctx.a20_applied = enabled
	return test_ctx.a20_apply_ok
}

pc_at_test_freeze :: proc(ctx: rawptr, reason: string) {
	(^Pc_At_Test_Context)(ctx).freeze_reason = reason
}

pc_at_test_master_now :: proc(ctx: rawptr) -> u64 {
	return (^Pc_At_Test_Context)(ctx).master_tick
}

pc_at_test_master_advance :: proc(ctx: rawptr, nanoseconds: u64) {
	(^Pc_At_Test_Context)(ctx).advanced_ns += nanoseconds
}

pc_at_test_irq_window :: proc(ctx: rawptr) {
	(^Pc_At_Test_Context)(ctx).irq_window_requests += 1
}

pc_at_test_event :: proc(ctx: rawptr, event: Pc_At_Event) {
	test_ctx := (^Pc_At_Test_Context)(ctx)
	if test_ctx.event_count >= len(test_ctx.events) {return}
	test_ctx.events[test_ctx.event_count] = event
	test_ctx.event_count += 1
}

pc_at_test_adapters :: proc(ctx: ^Pc_At_Test_Context) -> Pc_At_Adapters {
	return {
		ctx                = ctx,
		guest_memory       = pc_at_test_guest_memory,
		apply_a20          = pc_at_test_apply_a20,
		freeze             = pc_at_test_freeze,
		master_now         = pc_at_test_master_now,
		master_advance_ns  = pc_at_test_master_advance,
		request_irq_window = pc_at_test_irq_window,
		event              = pc_at_test_event,
	}
}

pc_at_test_init :: proc(platform: ^Pc_At_Platform, ctx: ^Pc_At_Test_Context) {
	ctx.a20_apply_ok = true
	assert(pc_at_platform_init(platform, 64 * 1024 * 1024, pc_at_test_adapters(ctx)))
	pc_at_platform_install_fixed_io(platform)
}

@(test)
test_pc_at_platform_owns_fixed_hardware_without_machine_promotion :: proc(t: ^testing.T) {
	m := new(Machine)
	defer free(m)
	testing.expect_value(t, offset_of(Machine, platform), uintptr(0))
	testing.expect(t, pc_at_platform_bus(&m.platform) == &m.platform.bus)
	testing.expect(t, pc_at_platform_pic(&m.platform) == &m.platform.pic)
	testing.expect(t, pc_at_platform_cmos(&m.platform) == &m.platform.cmos)
	testing.expect(t, pc_at_platform_dma(&m.platform) == &m.platform.dma)
}

@(test)
test_pc_at_platform_installs_only_the_fixed_motherboard_map :: proc(t: ^testing.T) {
	platform: Pc_At_Platform
	ctx: Pc_At_Test_Context
	pc_at_test_init(&platform, &ctx)
	defer pc_at_platform_destroy(&platform)

	platform_ports := [?]u16 {
		0x00, 0x20, 0x40, 0x60, 0x70, 0x80, 0x92, 0xA0, 0x2F8, 0x3F8,
		0x4D0, 0xCF9, APM_POWER_OFF_PORT,
	}
	for port in platform_ports {
		testing.expect(t, platform.bus.io[int(port)].ctx == &platform)
	}
	non_platform_ports := [?]u16 {0x1F0, 0x220, 0x3C0, 0x402, 0x500, 0x510, 0xCF8}
	for port in non_platform_ports {
		testing.expect(t, platform.bus.io[int(port)].read == nil)
		testing.expect(t, platform.bus.io[int(port)].write == nil)
	}
}

@(test)
test_pc_at_platform_port80_composes_post_delay_and_shutdown_marker :: proc(t: ^testing.T) {
	platform: Pc_At_Platform
	ctx: Pc_At_Test_Context
	pc_at_test_init(&platform, &ctx)
	defer pc_at_platform_destroy(&platform)

	bus_io_write(&platform.bus, 0x80, 1, 0xD5)
	testing.expect_value(t, platform.isa_delay.value, u8(0xD5))
	testing.expect_value(t, platform.isa_delay.access_count, u64(1))
	testing.expect_value(t, ctx.advanced_ns, ISA_IO_DELAY_NS)
	testing.expect_value(t, ctx.event_count, 1)
	testing.expect_value(t, ctx.events[0].kind, Pc_At_Event_Kind.Shutdown_Marker)
	testing.expect_value(t, ctx.events[0].a, u64(0xD5))
	testing.expect_value(t, bus_io_read(&platform.bus, 0x80, 1), u32(0xD5))
	testing.expect_value(t, platform.isa_delay.access_count, u64(2))
	testing.expect_value(t, ctx.advanced_ns, 2 * ISA_IO_DELAY_NS)
}

@(test)
test_pc_at_platform_a20_adapter_fails_closed_without_changing_latch :: proc(t: ^testing.T) {
	platform: Pc_At_Platform
	ctx := Pc_At_Test_Context{a20_apply_ok = false}
	testing.expect(t, pc_at_platform_init(&platform, 64 * 1024 * 1024, pc_at_test_adapters(&ctx)))
	defer pc_at_platform_destroy(&platform)

	testing.expect(t, !pc_at_platform_a20_control(&platform, false))
	testing.expect(t, platform.a20_enabled)
	testing.expect(t, strings.contains(ctx.freeze_reason, "A20 mapping failed"))
}

@(test)
test_pc_at_platform_records_reset_provenance_on_master_timeline :: proc(t: ^testing.T) {
	platform: Pc_At_Platform
	ctx := Pc_At_Test_Context{master_tick = 1234}
	testing.expect(t, pc_at_platform_init(&platform, 64 * 1024 * 1024, pc_at_test_adapters(&ctx)))
	defer pc_at_platform_destroy(&platform)
	platform.cmos.ram[0x0F] = 0x0A

	pc_at_platform_request_reset(&platform, .Pci_Cf9)
	testing.expect(t, platform.reset.reset_requested)
	testing.expect_value(t, platform.reset.reset_source, Reset_Provenance.Pci_Cf9)
	testing.expect_value(t, platform.reset.reset_count, u64(1))
	testing.expect_value(t, platform.reset.reset_history[0].master_tick, u64(1234))
	testing.expect_value(t, platform.reset.reset_history[0].cmos_shutdown, u8(0x0A))
	testing.expect(t, strings.contains(platform.reset.reset_reason, "PCI reset control"))
}

@(test)
test_pc_at_platform_exposes_typed_deadlines_and_advancement :: proc(t: ^testing.T) {
	platform: Pc_At_Platform
	ctx := Pc_At_Test_Context{master_tick = 100}
	testing.expect(t, pc_at_platform_init(&platform, 64 * 1024 * 1024, pc_at_test_adapters(&ctx)))
	defer pc_at_platform_destroy(&platform)

	cmos_deadline := pc_at_platform_deadline(&platform, .Cmos, 0)
	testing.expect(t, cmos_deadline.pending)
	testing.expect_value(t, cmos_deadline.basis, Pc_At_Deadline_Basis.Relative_Nanoseconds)
	dma_deadline := pc_at_platform_deadline(&platform, .Dma, 0)
	testing.expect_value(t, dma_deadline.basis, Pc_At_Deadline_Basis.Master_Tick)
	result := pc_at_platform_advance(&platform, .Pit, 0)
	testing.expect_value(t, result.device, Pc_At_Device.Pit)
	testing.expect(t, result.pit_transitions)
}

@(test)
test_pc_at_platform_passive_probes_remain_open_bus_under_strict_io :: proc(t: ^testing.T) {
	platform: Pc_At_Platform
	ctx: Pc_At_Test_Context
	pc_at_test_init(&platform, &ctx)
	defer pc_at_platform_destroy(&platform)
	bus_set_strict_io(&platform.bus, true)

	probe_ports := [?]u16 {0x130, 0x200, 0x280, 0x3E8, 0x6F2, 0xA20}
	for port in probe_ports {
		testing.expect_value(t, bus_io_read(&platform.bus, port, 1), u32(0xFF))
	}
	testing.expect(t, !platform.bus.frozen)
}
