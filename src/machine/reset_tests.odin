// SPDX-License-Identifier: GPL-3.0-only
package machine

import disk "../disk"
import hv "../hv"
import "core:log"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

Reset_Test_Watchdog :: struct {
	vm:   ^hv.Vm,
	stop: bool,
	mu:   sync.Mutex,
}

@(private = "file")
reset_test_floppy :: proc() -> []u8 {
	image := make([]u8, disk.FLOPPY_144_SIZE)
	probe := []u8 {
		0xFA, // cli
		0x31,
		0xC0, // xor ax, ax
		0x8E,
		0xD8, // mov ds, ax
		0x8E,
		0xD0, // mov ss, ax
		0xBC,
		0x00,
		0x7C, // mov sp, 7c00h
		0xC7,
		0x06,
		0x67,
		0x04,
		0x40,
		0x7C, // BDA resume offset
		0xC7,
		0x06,
		0x69,
		0x04,
		0x00,
		0x00, // BDA resume segment
		0xB0,
		0x0F,
		0xE6,
		0x70, // select CMOS shutdown status
		0xB0,
		0x0A,
		0xE6,
		0x71, // resume by far jump through 40:67
		0x0F,
		0x01,
		0x1E,
		0x30,
		0x7C, // lidt [7c30h]
		0xCC, // deliberate triple fault
		0xF4,
		0xEB,
		0xFD,
	}
	copy(image, probe)
	// Empty IDT descriptor at 0000:7c30.
	copy(
		image[0x40:],
		[]u8 {
			0xFA, // cli
			0x31,
			0xC0, // xor ax, ax
			0x8E,
			0xD8, // mov ds, ax
			0xC6,
			0x06,
			0x00,
			0x05,
			0xD7, // mov byte [0500h], d7h
			0xF4,
			0xEB,
			0xFD,
		},
	)
	image[510] = 0x55
	image[511] = 0xAA
	return image
}

@(private = "file")
reset_test_watchdog_start :: proc(w: ^Reset_Test_Watchdog) -> ^thread.Thread {
	return thread.create_and_start_with_poly_data(w, proc(ctx: ^Reset_Test_Watchdog) {
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
reset_test_watchdog_stop :: proc(w: ^Reset_Test_Watchdog, th: ^thread.Thread) {
	sync.lock(&w.mu)
	w.stop = true
	sync.unlock(&w.mu)
	thread.join(th)
}

@(test)
test_machine_seabios_resumes_after_dosx_triple_fault :: proc(t: ^testing.T) {
	if !hv.available() {
		log.warn("WHPX not available")
		return
	}
	testing.set_fail_timeout(t, 20 * time.Second)
	m: Machine
	if !testing.expect(t, machine_init(&m, 64 * 1024 * 1024)) {return}
	defer machine_destroy(&m)
	if !testing.expect(t, load_roms(&m.vm)) {return}

	floppy := reset_test_floppy()
	defer delete(floppy)
	if !testing.expect(t, machine_mount_floppy(&m, floppy)) {return}
	m.cmos.ram[0x3D] = 0x01
	fwcfg_add_file(&m.fwcfg, "etc/show-boot-menu", []u8{0, 0, 0, 0}, 0x0022)

	watchdog := Reset_Test_Watchdog {
		vm = &m.vm,
	}
	watchdog_thread := reset_test_watchdog_start(&watchdog)
	defer reset_test_watchdog_stop(&watchdog, watchdog_thread)

	start := time.tick_now()
	for time.tick_since(start) < 15 * time.Second && m.vm.ram[0x500] != 0xD7 {
		if step(&m) {continue}
		if !machine_cpu_reset_pending(&m) {break}
		sync.lock(&watchdog.mu)
		reset_ok := machine_cpu_reset(&m)
		sync.unlock(&watchdog.mu)
		if !testing.expect(t, reset_ok) {break}
	}

	testing.expect_value(t, m.bus.freeze_msg, "")
	testing.expect_value(t, m.cpu_reset_count, u64(1))
	testing.expect_value(t, m.cpu_reset_cmos_0f, u8(0x0A))
	testing.expect_value(t, m.cmos.ram[0x0F], u8(0))
	testing.expect_value(t, m.vm.ram[0x0467], u8(0x40))
	testing.expect_value(t, m.vm.ram[0x0468], u8(0x7C))
	testing.expect_value(t, m.vm.ram[0x0500], u8(0xD7))
}
