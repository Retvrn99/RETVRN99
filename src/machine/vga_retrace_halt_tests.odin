// SPDX-License-Identifier: GPL-3.0-only
package machine

import hv "../hv"
import video "../vga"
import "core:log"
import "core:testing"
import "core:time"

// Mode 12h timing programmed through the public VGA ports: a 525 line raster
// whose vertical retrace starts at line 490. Only the registers the raster clock
// derives from are written, and CRT Controller 11h goes first because bit 7 of
// it write protects 00h through 07h.
@(private = "file")
vga_retrace_halt_program_mode :: proc(v: ^video.Vga) {
	video.vga_out(v, 0x3C2, 0xE3)
	video.vga_out(v, 0x3C4, 0x01)
	video.vga_out(v, 0x3C5, 0x01)
	crtc := [][2]u8 {
		{0x11, 0x0C},
		{0x00, 0x5F},
		{0x01, 0x4F},
		{0x06, 0x0B},
		{0x07, 0x3E},
		{0x09, 0x40},
		{0x10, 0xEA},
		{0x12, 0xDF},
		{0x15, 0xE7},
		{0x16, 0x04},
		{0x17, 0xE3},
	}
	for pair in crtc {
		video.vga_out(v, 0x3D4, pair[0])
		video.vga_out(v, 0x3D5, pair[1])
	}
}

@(private = "file")
vga_retrace_halt_setup_irq9 :: proc(pic: ^Pic_Pair) {
	pic_out(pic, 0x20, 0x11)
	pic_out(pic, 0xA0, 0x11)
	pic_out(pic, 0x21, 0x08)
	pic_out(pic, 0xA1, 0x70)
	pic_out(pic, 0x21, 0x04)
	pic_out(pic, 0xA1, 0x02)
	pic_out(pic, 0x21, 0x01)
	pic_out(pic, 0xA1, 0x01)
	pic_out(pic, 0x21, 0xFB)
	pic_out(pic, 0xA1, 0xFD)
}

// IBM 2-69. A guest that arms the vertical interrupt and halts has nothing else
// to wake it: no timer is running and the only deadline in the machine is the
// retrace start CRT Controller 10h names. The halted vCPU must still come back
// when the beam reaches that line.
@(test)
test_machine_halted_guest_wakes_on_vga_vertical_retrace :: proc(t: ^testing.T) {
	if !hv.available() {
		log.warn("WHPX not available")
		return
	}
	testing.set_fail_timeout(t, 20 * time.Second)
	m := new(Machine)
	defer free(m)
	if !testing.expect(t, machine_init(m, 64 * 1024 * 1024)) {return}
	defer machine_destroy(m)
	pci_out(&m.pci, 0xCF8, 4, 0x8000_1004)
	pci_out(&m.pci, 0xCFC, 2, 0x0003)
	testing.expect(t, machine_sync_pci_devices(m))
	if !testing.expect(t, m.vga.pci_io_enabled) {return}
	vga_retrace_halt_program_mode(&m.vga)
	testing.expect_value(t, m.vga.timing.total_lines, 525)
	testing.expect_value(t, m.vga.timing.retrace_start, 490)
	vga_retrace_halt_setup_irq9(&m.pic)

	// IRQ9 takes vector 71h through the AT redirect.
	copy(m.vm.ram[0x1C4:], []u8{0x00, 0x05, 0x00, 0x00})
	copy(m.vm.ram[0x500:], []u8 {
		0xFE, 0x06, 0x40, 0x05, // inc byte [0540h]
		0xBA, 0xD4, 0x03, // mov dx, 3d4h
		0xB0, 0x11, // mov al, 11h
		0xEE, // out dx, al
		0x42, // inc dx
		0xB0, 0x0C, // mov al, 0ch
		0xEE, // out dx, al
		0xB0, 0x20, // mov al, 20h
		0xE6, 0xA0, // out 0a0h, al
		0xB0, 0x20, // mov al, 20h
		0xE6, 0x20, // out 20h, al
		0xCF, // iret
	})
	copy(m.vm.ram[0x7C00:], []u8 {
		0xFA, // cli
		0x31, 0xC0, // xor ax, ax
		0x8E, 0xD8, // mov ds, ax
		0x8E, 0xD0, // mov ss, ax
		0xBC, 0x00, 0x70, // mov sp, 7000h
		0xBA, 0xD4, 0x03, // mov dx, 3d4h
		0xB0, 0x11, // mov al, 11h
		0xEE, // out dx, al
		0x42, // inc dx
		0xB0, 0x1C, // mov al, 1ch
		0xEE, // out dx, al
		0xFB, // sti
		0xF4, // hlt
		0xB0, 0x42, // mov al, 42h
		0xE6, 0x99, // out 99h, al
		0xF4, // hlt
	})
	seen: u32
	bus_register(&m.bus, 0x99, 0x99, Io_Handler {
		ctx = &seen,
		write = proc(ctx: rawptr, port: u16, size: u8, value: u32) {(^u32)(ctx)^ = value},
	})
	hv.set_realmode_entry(&m.vm, 0, 0x7C00)

	if !testing.expect(t, step(m)) {return}
	if !testing.expect(t, m.cpu_halted) {return}
	testing.expect_value(t, seen, u32(0))
	testing.expect(t, m.vga.crtc[0x11] & 0x10 != 0)

	start := time.tick_now()
	for time.tick_since(start) < 10 * time.Second && seen == 0 {
		if !step(m) {break}
	}
	testing.expect_value(t, m.vm.ram[0x540], u8(1))
	testing.expect_value(t, seen, u32(0x42))
	testing.expect_value(t, m.inj_count[0x71], u64(1))
	testing.expect(t, !m.vga.vertical_interrupt_pending)
}
