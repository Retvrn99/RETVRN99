// SPDX-License-Identifier: GPL-3.0-only
package machine

import disk "../disk"
import hv "../hv"
import "core:log"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

Apm_Firmware_Test_Watchdog :: struct {
	vm:   ^hv.Vm,
	stop: bool,
	mu:   sync.Mutex,
}

@(private = "file")
apm_firmware_test_boot_floppy :: proc() -> []u8 {
	image := make([]u8, disk.FLOPPY_144_SIZE)
	probe := []u8 {
		0xFA,             // cli
		0x31, 0xC0,       // xor ax, ax
		0x8E, 0xD8,       // mov ds, ax
		0x8E, 0xC0,       // mov es, ax
		0x8E, 0xD0,       // mov ss, ax
		0xBC, 0x00, 0x7C, // mov sp, 7c00h
		0xFB,             // sti

		0xB8, 0x00, 0x53, // mov ax, 5300h
		0x31, 0xDB,       // xor bx, bx
		0xCD, 0x15,       // int 15h
		0x9C,             // pushf
		0x8F, 0x06, 0x00, 0x05, // pop word [0500h]
		0xA3, 0x02, 0x05,       // mov [0502h], ax
		0x89, 0x1E, 0x04, 0x05, // mov [0504h], bx
		0x89, 0x0E, 0x06, 0x05, // mov [0506h], cx

		0xB8, 0x01, 0x53, // mov ax, 5301h
		0x31, 0xDB,       // xor bx, bx
		0xCD, 0x15,       // int 15h
		0x9C,             // pushf
		0x8F, 0x06, 0x08, 0x05, // pop word [0508h]

		0xB8, 0x0E, 0x53, // mov ax, 530eh
		0x31, 0xDB,       // xor bx, bx
		0xB9, 0x02, 0x01, // mov cx, 0102h
		0xCD, 0x15,       // int 15h
		0x9C,             // pushf
		0x8F, 0x06, 0x0A, 0x05, // pop word [050ah]
		0xA3, 0x0C, 0x05,       // mov [050ch], ax

		0xC6, 0x06, 0x0E, 0x05, 0xD7, // mov byte [050eh], d7h
		0xB8, 0x07, 0x53,             // mov ax, 5307h
		0xBB, 0x01, 0x00,             // mov bx, 0001h
		0xB9, 0x03, 0x00,             // mov cx, 0003h
		0xCD, 0x15,                   // int 15h

		0xC6, 0x06, 0x0F, 0x05, 0xEF, // mov byte [050fh], efh
		0xFA,                         // cli
		0xF4,                         // hlt
		0xEB, 0xFD,                   // jmp hlt
	}
	copy(image, probe)
	image[510] = 0x55
	image[511] = 0xAA
	return image
}

@(private = "file")
apm_firmware_test_start_watchdog :: proc(w: ^Apm_Firmware_Test_Watchdog) -> ^thread.Thread {
	return thread.create_and_start_with_poly_data(w, proc(ctx: ^Apm_Firmware_Test_Watchdog) {
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
apm_firmware_test_stop_watchdog :: proc(w: ^Apm_Firmware_Test_Watchdog, th: ^thread.Thread) {
	sync.lock(&w.mu)
	w.stop = true
	sync.unlock(&w.mu)
	thread.destroy(th)
}

@(private = "file")
apm_firmware_test_word :: proc(ram: []u8, address: int) -> u16 {
	return u16(ram[address]) | u16(ram[address + 1]) << 8
}

@(test)
test_machine_seabios_apm_requests_power_off :: proc(t: ^testing.T) {
	if !hv.available() {
		log.warn("WHPX not available")
		return
	}
	testing.set_fail_timeout(t, 20 * time.Second)
	m := new(Machine)
	defer free(m)
	if !testing.expect(t, machine_init(m, 64 * 1024 * 1024)) {return}
	defer machine_destroy(m)
	machine_set_diagnostic_tracing(m, true)
	if !testing.expect(t, load_roms(&m.vm)) {return}

	floppy := apm_firmware_test_boot_floppy()
	defer delete(floppy)
	if !testing.expect(t, machine_mount_floppy(m, floppy)) {return}
	m.platform.cmos.ram[0x3D] = 0x01
	fwcfg_add_file(&m.fwcfg, "etc/show-boot-menu", []u8{0, 0, 0, 0}, 0x0022)

	watchdog := Apm_Firmware_Test_Watchdog {
		vm = &m.vm,
	}
	watchdog_thread := apm_firmware_test_start_watchdog(&watchdog)
	defer apm_firmware_test_stop_watchdog(&watchdog, watchdog_thread)

	start := time.tick_now()
	for time.tick_since(start) < 15 * time.Second && !machine_power_off_requested(m) {
		if !step(m) {break}
	}

	if !machine_power_off_requested(m) {
		r := hv.get_regs(&m.vm)
		log.errorf(
			"SeaBIOS APM probe timeout CS:IP=%04x:%04x AX=%04x BX=%04x CX=%04x exits=%d",
			r.cs_sel,
			r.rip,
			u16(r.rax),
			u16(r.rbx),
			u16(r.rcx),
			m.exit_count,
		)
	}

	if !testing.expect_value(t, m.platform.bus.freeze_msg, "") {return}
	if !testing.expect(t, machine_power_off_requested(m)) {return}
	testing.expect_value(t, machine_power_off_reason(m), "guest requested APM power off")
	testing.expect_value(t, m.vm.ram[0x050E], u8(0xD7))
	testing.expect_value(t, m.vm.ram[0x050F], u8(0))
	testing.expect_value(t, apm_firmware_test_word(m.vm.ram, 0x0500) & 1, u16(0))
	testing.expect_value(t, apm_firmware_test_word(m.vm.ram, 0x0502), u16(0x0102))
	testing.expect_value(t, apm_firmware_test_word(m.vm.ram, 0x0504), u16(0x504D))
	testing.expect_value(t, apm_firmware_test_word(m.vm.ram, 0x0506), u16(0x0003))
	testing.expect_value(t, apm_firmware_test_word(m.vm.ram, 0x0508) & 1, u16(0))
	testing.expect_value(t, apm_firmware_test_word(m.vm.ram, 0x050A) & 1, u16(0))
	testing.expect_value(t, apm_firmware_test_word(m.vm.ram, 0x050C), u16(0x0102))

	last_io := m.io_hist[(m.io_count - 1) % IO_HISTORY]
	testing.expect_value(t, last_io.port, APM_POWER_OFF_PORT)
	testing.expect_value(t, last_io.write, true)
	testing.expect_value(t, last_io.size, u8(2))
	testing.expect_value(t, last_io.val, u32(APM_POWER_OFF_VALUE))
}
