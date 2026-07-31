// SPDX-License-Identifier: GPL-3.0-only
package machine

import hv "../hv"
import video "../vga"
import "core:log"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

// Bare-probe harness conventions selectively adapted from IzarraVM commit
// d930de57acccbc6a70cda8cc5a603173bf23cd1c test fixtures.

@(rodata)
GUEST_PROBE_AUDIO_LEGACY := #load("../../assets/probes/audio_legacy.bin")
@(rodata)
GUEST_PROBE_HLT_PIT_IRQ := #load("../../assets/probes/hlt_pit_irq.bin")
@(rodata)
GUEST_PROBE_REP_IRQ_PROGRESS := #load("../../assets/probes/rep_irq_progress.bin")
@(rodata)
GUEST_PROBE_PAGING_AD := #load("../../assets/probes/paging_ad.bin")
@(rodata)
GUEST_PROBE_VGA_CLEAR_PIT := #load("../../assets/probes/vga_clear_pit.bin")
@(rodata)
GUEST_PROBE_VGA_COPY_PAGING := #load("../../assets/probes/vga_copy_paging.bin")
@(rodata)
GUEST_PROBE_VGA_SCALAR_MMIO := #load("../../assets/probes/vga_scalar_mmio.bin")

GUEST_PROBE_LOAD_ADDRESS :: 0x7C00
GUEST_PROBE_STEP_NS :: u64(2_000_000)
GUEST_PROBE_MASTER_LIMIT :: 30 * MASTER_CLOCK_HZ

Guest_Probe_Watchdog :: struct {
	vm:   ^hv.Vm,
	stop: bool,
	mu:   sync.Mutex,
}

@(test)
test_guest_probe_legacy_audio_crosses_real_mode_io_dma_and_irq :: proc(t: ^testing.T) {
	if !hv.available() {
		log.warn("WHPX not available; skipping legacy-audio guest probe")
		return
	}
	testing.set_fail_timeout(t, 20 * time.Second)
	m := new(Machine)
	defer free(m)
	if !guest_probe_prepare(t, m, GUEST_PROBE_AUDIO_LEGACY) {return}
	defer machine_destroy(m)

	if !testing.expect(t, guest_probe_run(m, 12 * time.Second)) {return}
	testing.expect_value(t, m.vm.ram[0x0500], u8(0xA5))
	testing.expect_value(t, m.vm.ram[0x0501], u8(0xC0))
	testing.expect_value(t, m.vm.ram[0x0502], u8(4))
	testing.expect_value(t, m.vm.ram[0x0503], u8(5))
	testing.expect(t, m.vm.ram[0x0504] > 0)
	testing.expect(t, m.vm.ram[0x0505] > 0)
	testing.expect_value(t, m.vm.ram[0x0506] & 0xE0, u8(0))
	testing.expect_value(t, m.vm.ram[0x0507] & 0xE0, u8(0xC0))
	testing.expect(t, dma_at_terminal_count(&m.platform.dma, 1))
	testing.expect(t, dma_at_terminal_count(&m.platform.dma, 5))
	observability := machine_audio_observability(m)
	testing.expect(t, observability.pc_speaker.nonzero_frames > 0)
	testing.expect(t, observability.opl3.nonzero_frames > 0)
	testing.expect(t, observability.sb16.nonzero_frames > 0)
	testing.expect(t, observability.sb16_irq_events >= 2)
	testing.expect_value(t, observability.speaker_late_edges, u64(0))
	testing.expect_value(t, observability.speaker_overflow_edges, u64(0))
}

@(private = "file")
guest_probe_start_watchdog :: proc(watchdog: ^Guest_Probe_Watchdog) -> ^thread.Thread {
	return thread.create_and_start_with_poly_data(watchdog, proc(ctx: ^Guest_Probe_Watchdog) {
		for {
			time.sleep(2 * time.Millisecond)
			sync.lock(&ctx.mu)
			stop := ctx.stop
			if !stop {hv.cancel(ctx.vm)}
			sync.unlock(&ctx.mu)
			if stop {return}
		}
	})
}

@(private = "file")
guest_probe_stop_watchdog :: proc(
	watchdog: ^Guest_Probe_Watchdog,
	watchdog_thread: ^thread.Thread,
) {
	sync.lock(&watchdog.mu)
	watchdog.stop = true
	sync.unlock(&watchdog.mu)
	thread.destroy(watchdog_thread)
}

@(private = "file")
guest_probe_prepare :: proc(t: ^testing.T, m: ^Machine, image: []u8) -> bool {
	if !testing.expect(t, len(image) > 0) {return false}
	if !testing.expect(t, GUEST_PROBE_LOAD_ADDRESS + len(image) <= 64 * 1024 * 1024) {return false}
	if !testing.expect(t, machine_init(m, 64 * 1024 * 1024)) {return false}
	// Bare probes skip firmware, so establish the PCI VGA decode state that
	// SeaBIOS normally programs before invoking a VGA option ROM.
	bus_io_write(&m.platform.bus, 0xCF8, 4, 0x8000_1004)
	bus_io_write(&m.platform.bus, 0xCFC, 2, 0x0007)
	machine_enable_test_device(m)
	copy(m.vm.ram[GUEST_PROBE_LOAD_ADDRESS:], image)
	hv.set_realmode_entry(&m.vm, 0, GUEST_PROBE_LOAD_ADDRESS)
	return true
}

@(private = "file")
guest_probe_run :: proc(m: ^Machine, wall_limit: time.Duration) -> bool {
	watchdog := Guest_Probe_Watchdog {
		vm = &m.vm,
	}
	watchdog_thread := guest_probe_start_watchdog(&watchdog)
	defer guest_probe_stop_watchdog(&watchdog, watchdog_thread)

	wall_start := time.tick_now()
	master_start := master_timeline_now(m.timeline)
	for time.tick_since(wall_start) < wall_limit &&
	    master_timeline_now(m.timeline) - master_start < GUEST_PROBE_MASTER_LIMIT {
		step_ok := step(m)
		command := machine_test_device_take_command(m)
		if command == .Exit {
			exit_code := machine_test_device_exit_code(m)
			if exit_code != 0 {
				log.errorf(
					"guest probe reported exit=%d irq20=%d result=%08x/%08x/%08x",
					exit_code,
					m.inj_count[0x20],
					guest_probe_u32(m.vm.ram, 0x0500),
					guest_probe_u32(m.vm.ram, 0x0504),
					guest_probe_u32(m.vm.ram, 0x0508),
				)
			}
			return exit_code == 0
		}
		if !step_ok {
			break
		}
		machine_advance_time_ns(m, GUEST_PROBE_STEP_NS)
	}

	regs := hv.get_regs(&m.vm)
	log.errorf(
		"guest probe failed exit=%d frozen=%v reason=%s CS:IP=%04x:%08x master=%d exits=%d",
		machine_test_device_exit_code(m),
		m.platform.bus.frozen,
		m.platform.bus.freeze_msg,
		regs.cs_sel,
		regs.rip,
		master_timeline_now(m.timeline) - master_start,
		m.exit_count,
	)
	return false
}

@(private = "file")
guest_probe_u16 :: proc(memory: []u8, address: int) -> u16 {
	return u16(memory[address]) | u16(memory[address + 1]) << 8
}

@(private = "file")
guest_probe_u32 :: proc(memory: []u8, address: int) -> u32 {
	return(
		u32(memory[address]) |
		u32(memory[address + 1]) << 8 |
		u32(memory[address + 2]) << 16 |
		u32(memory[address + 3]) << 24 \
	)
}

@(private = "file")
guest_probe_rep_string_budget :: proc(ctx: rawptr) -> u64 {
	return 64
}

@(private = "file")
guest_probe_full_rep_string_budget :: proc(ctx: rawptr) -> u64 {
	return 4096
}

@(test)
test_guest_probe_hlt_wakes_for_pit_irq_and_returns_through_iret :: proc(t: ^testing.T) {
	if !hv.available() {
		log.warn("WHPX not available; skipping HLT/PIT guest probe")
		return
	}
	testing.set_fail_timeout(t, 20 * time.Second)
	m := new(Machine)
	defer free(m)
	if !guest_probe_prepare(t, m, GUEST_PROBE_HLT_PIT_IRQ) {return}
	defer machine_destroy(m)

	if !testing.expect(t, guest_probe_run(m, 12 * time.Second)) {return}
	testing.expect(t, guest_probe_u16(m.vm.ram, 0x0500) > 0)
	testing.expect_value(t, m.vm.ram[0x0502], u8(0xA5))
	testing.expect(t, m.inj_count[0x20] > 0)
}

@(test)
test_guest_probe_irq_interrupts_chunked_rep_io_without_losing_progress :: proc(t: ^testing.T) {
	if !hv.available() {
		log.warn("WHPX not available; skipping REP-I/O guest probe")
		return
	}
	testing.set_fail_timeout(t, 20 * time.Second)
	m := new(Machine)
	defer free(m)
	if !guest_probe_prepare(t, m, GUEST_PROBE_REP_IRQ_PROGRESS) {return}
	defer machine_destroy(m)
	m.vm.io_string_budget = guest_probe_rep_string_budget

	if !testing.expect(t, guest_probe_run(m, 12 * time.Second)) {return}
	testing.expect(t, guest_probe_u32(m.vm.ram, 0x0500) > 0)
	testing.expect_value(t, guest_probe_u32(m.vm.ram, 0x0504), u32(0x0012_1000))
	testing.expect_value(t, guest_probe_u32(m.vm.ram, 0x0508), u32(0))
	testing.expect(t, m.inj_count[0x20] > 0)
}

@(test)
test_guest_probe_paging_sets_pde_and_pte_accessed_dirty_bits :: proc(t: ^testing.T) {
	if !hv.available() {
		log.warn("WHPX not available; skipping paging A/D guest probe")
		return
	}
	testing.set_fail_timeout(t, 20 * time.Second)
	m := new(Machine)
	defer free(m)
	if !guest_probe_prepare(t, m, GUEST_PROBE_PAGING_AD) {return}
	defer machine_destroy(m)

	if !testing.expect(t, guest_probe_run(m, 12 * time.Second)) {return}
	pde := guest_probe_u32(m.vm.ram, 0x0009_0000)
	read_pte := guest_probe_u32(m.vm.ram, 0x0009_1800)
	write_pte := guest_probe_u32(m.vm.ram, 0x0009_1804)
	testing.expect(t, pde & 0x20 != 0)
	testing.expect_value(t, read_pte & 0x60, u32(0x20))
	testing.expect_value(t, write_pte & 0x60, u32(0x60))
	testing.expect_value(t, guest_probe_u32(m.vm.ram, 0x0020_1000), u32(0xA55A_39C3))
}

@(test)
test_guest_probe_pit_irq_survives_repeated_vga_aperture_clears :: proc(t: ^testing.T) {
	if !hv.available() {
		log.warn("WHPX not available; skipping VGA/PIT guest probe")
		return
	}
	testing.set_fail_timeout(t, 30 * time.Second)
	m := new(Machine)
	defer free(m)
	if !guest_probe_prepare(t, m, GUEST_PROBE_VGA_CLEAR_PIT) {return}
	defer machine_destroy(m)

	if !testing.expect(t, guest_probe_run(m, 20 * time.Second)) {return}
	testing.expect(t, guest_probe_u16(m.vm.ram, 0x0500) > 0)
	testing.expect(t, m.inj_count[0x20] > 0)
	nonzero := 0
	for value in video.vga_vram(&m.vga)[:64 * 1024] {
		if value != 0 {nonzero += 1}
	}
	testing.expect(t, nonzero > 0)
}

@(test)
test_guest_probe_paged_rep_movsd_copies_to_vga_aperture :: proc(t: ^testing.T) {
	if !hv.available() {
		log.warn("WHPX not available; skipping paged VGA copy guest probe")
		return
	}
	testing.set_fail_timeout(t, 20 * time.Second)
	m := new(Machine)
	defer free(m)
	if !guest_probe_prepare(t, m, GUEST_PROBE_VGA_COPY_PAGING) {return}
	defer machine_destroy(m)
	m.vm.io_string_budget = guest_probe_full_rep_string_budget

	if !testing.expect(t, guest_probe_run(m, 12 * time.Second)) {return}
	testing.expect_value(t, m.vm.mmio_string_fallbacks, u64(201))
	testing.expect_value(t, m.vm.mmio_string_chunks, u64(213))
	testing.expect_value(t, m.vm.mmio_string_elements, u64(16080))
	for value in video.vga_vram(&m.vga)[:64000] {
		testing.expect_value(t, value, u8(0xA5))
	}
	for value in m.vm.ram[0x30000:0x30140] {
		testing.expect_value(t, value, u8(0xA5))
	}
}

@(test)
test_guest_probe_scalar_winquake_mmio_forms :: proc(t: ^testing.T) {
	if !hv.available() {
		log.warn("WHPX not available; skipping scalar VGA MMIO guest probe")
		return
	}
	testing.set_fail_timeout(t, 20 * time.Second)
	m := new(Machine)
	defer free(m)
	if !guest_probe_prepare(t, m, GUEST_PROBE_VGA_SCALAR_MMIO) {return}
	defer machine_destroy(m)

	if !testing.expect(t, guest_probe_run(m, 12 * time.Second)) {return}
	testing.expect_value(t, guest_probe_u32(m.vm.ram, 0x0500), u32(1))
	testing.expect(t, m.vm.mmio_scalar_fallbacks > 0)
	for value in video.vga_vram(&m.vga)[0x8000:0x8004] {
		testing.expect_value(t, value, u8(0xA5))
	}
}
