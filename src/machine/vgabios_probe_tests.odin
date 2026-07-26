// SPDX-License-Identifier: GPL-3.0-only
package machine

import disk "../disk"
import hv "../hv"
import "core:log"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

// Shared scaffolding for real-mode VGA BIOS probes. A probe is a boot sector
// that drives INT 10h, records results into low memory, and halts after
// storing the sentinel.
VGABIOS_PROBE_SENTINEL_ADDRESS :: 0x0500
VGABIOS_PROBE_SENTINEL :: 0xD7
VGABIOS_PROBE_RESULT_BASE :: 0x0520
VGABIOS_PROBE_CODE_LIMIT :: 510

vgabios_probe_emit :: proc(code: ^[dynamic]u8, bytes: ..u8) {
	for value in bytes {append(code, value)}
}

// Emits the sentinel store and halt loop that every probe ends with.
vgabios_probe_emit_halt :: proc(code: ^[dynamic]u8) {
	vgabios_probe_emit(
		code,
		0xC6,
		0x06,
		u8(VGABIOS_PROBE_SENTINEL_ADDRESS & 0xFF),
		u8(VGABIOS_PROBE_SENTINEL_ADDRESS >> 8),
		VGABIOS_PROBE_SENTINEL,
	) // mov byte [0500h], 0d7h
	vgabios_probe_emit(code, 0xFA, 0xF4, 0xEB, 0xFD) // cli / hlt / jmp hlt
}

// Emits the standard flat real-mode entry used by every probe.
vgabios_probe_emit_prologue :: proc(code: ^[dynamic]u8) {
	vgabios_probe_emit(code, 0xFA) // cli
	vgabios_probe_emit(code, 0x31, 0xC0) // xor ax, ax
	vgabios_probe_emit(code, 0x8E, 0xD8) // mov ds, ax
	vgabios_probe_emit(code, 0x8E, 0xC0) // mov es, ax
	vgabios_probe_emit(code, 0x8E, 0xD0) // mov ss, ax
	vgabios_probe_emit(code, 0xBC, 0x00, 0x7C) // mov sp, 7c00h
	vgabios_probe_emit(code, 0xFB) // sti
}

// mov [imm16], al
vgabios_probe_emit_store :: proc(code: ^[dynamic]u8, address: int) {
	vgabios_probe_emit(code, 0xA2, u8(address & 0xFF), u8(address >> 8))
}

// mov al, [imm16]
vgabios_probe_emit_load :: proc(code: ^[dynamic]u8, address: int) {
	vgabios_probe_emit(code, 0xA0, u8(address & 0xFF), u8(address >> 8))
}

// Reads one indexed CRT Controller register at the colour address into AL.
vgabios_probe_emit_read_crtc :: proc(code: ^[dynamic]u8, index: u8) {
	vgabios_probe_emit(code, 0xBA, 0xD4, 0x03) // mov dx, 03d4h
	vgabios_probe_emit(code, 0xB0, index) // mov al, index
	vgabios_probe_emit(code, 0xEE) // out dx, al
	vgabios_probe_emit(code, 0x42) // inc dx
	vgabios_probe_emit(code, 0xEC) // in al, dx
}

vgabios_probe_image :: proc(code: []u8) -> ([]u8, bool) {
	if len(code) > VGABIOS_PROBE_CODE_LIMIT {return nil, false}
	image := make([]u8, disk.FLOPPY_144_SIZE)
	copy(image, code)
	image[510] = 0x55
	image[511] = 0xAA
	return image, true
}

@(private = "file")
vgabios_probe_start_watchdog :: proc(w: ^Vgabios_Test_Watchdog) -> ^thread.Thread {
	return thread.create_and_start_with_poly_data(w, proc(ctx: ^Vgabios_Test_Watchdog) {
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
vgabios_probe_stop_watchdog :: proc(w: ^Vgabios_Test_Watchdog, th: ^thread.Thread) {
	sync.lock(&w.mu)
	w.stop = true
	sync.unlock(&w.mu)
	thread.destroy(th)
}

// Boots the probe image on an initialised Machine and runs until the probe
// stores its sentinel or the bound expires.
vgabios_probe_run :: proc(
	t: ^testing.T,
	m: ^Machine,
	image: []u8,
	timeout: time.Duration,
) -> bool {
	if !testing.expect(t, machine_mount_floppy(m, image)) {return false}
	m.cmos.ram[0x3D] = 0x01
	fwcfg_add_file(&m.fwcfg, "etc/show-boot-menu", []u8{0, 0, 0, 0}, 0x0022)

	watchdog := Vgabios_Test_Watchdog {
		vm = &m.vm,
	}
	watchdog_thread := vgabios_probe_start_watchdog(&watchdog)
	defer vgabios_probe_stop_watchdog(&watchdog, watchdog_thread)

	start := time.tick_now()
	for time.tick_since(start) < timeout &&
	    m.vm.ram[VGABIOS_PROBE_SENTINEL_ADDRESS] != VGABIOS_PROBE_SENTINEL {
		if !step(m) {break}
	}
	if m.vm.ram[VGABIOS_PROBE_SENTINEL_ADDRESS] != VGABIOS_PROBE_SENTINEL {
		r := hv.get_regs(&m.vm)
		log.errorf(
			"VGA BIOS probe timeout CS:IP=%04x:%04x exits=%d",
			r.cs_sel,
			r.rip,
			m.exit_count,
		)
	}
	if !testing.expect_value(t, m.bus.freeze_msg, "") {return false}
	return testing.expect_value(
		t,
		m.vm.ram[VGABIOS_PROBE_SENTINEL_ADDRESS],
		u8(VGABIOS_PROBE_SENTINEL),
	)
}
