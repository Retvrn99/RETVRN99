// SPDX-License-Identifier: GPL-3.0-only
package machine

import disk "../disk"
import hv "../hv"
import video "../vga"
import "core:log"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

Vgabios_Test_Watchdog :: struct {
	vm:   ^hv.Vm,
	stop: bool,
	mu:   sync.Mutex,
}

@(private = "file")
vgabios_test_boot_floppy :: proc() -> []u8 {
	image := make([]u8, disk.FLOPPY_144_SIZE)
	probe := []u8 {
		0xFA, // cli
		0x31,
		0xC0, // xor ax, ax
		0x8E,
		0xD8, // mov ds, ax
		0x8E,
		0xC0, // mov es, ax
		0x8E,
		0xD0, // mov ss, ax
		0xBC,
		0x00,
		0x7C, // mov sp, 7c00h
		0xFB, // sti
		0xB8,
		0x92,
		0x00, // mov ax, 0092h (mode 12h, preserve memory)
		0xCD,
		0x10, // int 10h
		0xB4,
		0x0F, // mov ah, 0fh
		0xCD,
		0x10, // int 10h
		0xA2,
		0x00,
		0x05, // mov [0500h], al
		0xB8,
		0x0F,
		0x0C, // mov ax, 0c0fh
		0x31,
		0xDB, // xor bx, bx
		0xB9,
		0x10,
		0x00, // mov cx, 16
		0xBA,
		0x10,
		0x00, // mov dx, 16
		0xCD,
		0x10, // int 10h
		0xC7,
		0x06,
		0x00,
		0x06,
		0x56,
		0x42, // mov word [0600h], "VB"
		0xC7,
		0x06,
		0x02,
		0x06,
		0x45,
		0x32, // mov word [0602h], "E2"
		0xB8,
		0x00,
		0x4F, // mov ax, 4f00h
		0xBF,
		0x00,
		0x06, // mov di, 0600h
		0xCD,
		0x10, // int 10h
		0xA3,
		0x02,
		0x05, // mov [0502h], ax
		0xB8,
		0x02,
		0x4F, // mov ax, 4f02h
		0xBB,
		0x01,
		0x81, // mov bx, 8101h (640x480x8, banked, preserve memory)
		0xCD,
		0x10, // int 10h
		0xA3,
		0x04,
		0x05, // mov [0504h], ax
		0xB8,
		0x00,
		0xA0, // mov ax, a000h
		0x8E,
		0xC0, // mov es, ax
		0x31,
		0xFF, // xor di, di
		0xB8,
		0x0F,
		0x0F, // mov ax, 0f0fh
		0xB9,
		0x00,
		0x08, // mov cx, 0800h
		0xF3,
		0xAB, // rep stosw
		0x31,
		0xC0, // xor ax, ax
		0x8E,
		0xC0, // mov es, ax
		0xB8,
		0x15,
		0x4F, // mov ax, 4f15h
		0x31,
		0xDB, // xor bx, bx
		0x31,
		0xC9, // xor cx, cx
		0xCD,
		0x10, // int 10h
		0xA3,
		0x08,
		0x05, // mov [0508h], ax
		0x89,
		0x1E,
		0x0A,
		0x05, // mov [050Ah], bx
		0xB8,
		0x15,
		0x4F, // mov ax, 4f15h
		0xBB,
		0x01,
		0x00, // mov bx, 0001h
		0x31,
		0xC9, // xor cx, cx
		0x31,
		0xD2, // xor dx, dx
		0xBF,
		0x00,
		0x07, // mov di, 0700h
		0xCD,
		0x10, // int 10h
		0xA3,
		0x0C,
		0x05, // mov [050Ch], ax
		0xB8,
		0x02,
		0x4F, // mov ax, 4f02h
		0xBB,
		0x51,
		0x81, // mov bx, 8151h (320x240x8, banked, preserve memory)
		0xCD,
		0x10, // int 10h
		0xA3,
		0x0E,
		0x05, // mov [050Eh], ax
		0xC6,
		0x06,
		0x06,
		0x05,
		0xD7, // mov byte [0506h], d7h
		0xFA, // cli
		0xF4, // hlt
		0xEB,
		0xFD, // jmp hlt
	}
	copy(image, probe)
	image[510] = 0x55
	image[511] = 0xAA
	return image
}

@(private = "file")
vgabios_test_start_watchdog :: proc(w: ^Vgabios_Test_Watchdog) -> ^thread.Thread {
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
vgabios_test_stop_watchdog :: proc(w: ^Vgabios_Test_Watchdog, th: ^thread.Thread) {
	sync.lock(&w.mu)
	w.stop = true
	sync.unlock(&w.mu)
	thread.destroy(th)
}

@(test)
test_machine_boots_bochs_vgabios_and_sets_vbe_mode :: proc(t: ^testing.T) {
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

	floppy := vgabios_test_boot_floppy()
	defer delete(floppy)
	if !testing.expect(t, machine_mount_floppy(m, floppy)) {return}
	m.cmos.ram[0x3D] = 0x01
	fwcfg_add_file(&m.fwcfg, "etc/show-boot-menu", []u8{0, 0, 0, 0}, 0x0022)

	watchdog := Vgabios_Test_Watchdog {
		vm = &m.vm,
	}
	watchdog_thread := vgabios_test_start_watchdog(&watchdog)
	defer vgabios_test_stop_watchdog(&watchdog, watchdog_thread)

	romw_seen_enabled := false
	start := time.tick_now()
	for time.tick_since(start) < 15 * time.Second && m.vm.ram[0x0506] != 0xD7 {
		if !step(m) {break}
		romw_seen_enabled = romw_seen_enabled || pci_amd756_bios_write_enabled(&m.pci)
	}
	if m.vm.ram[0x0506] != 0xD7 {
		r := hv.get_regs(&m.vm)
		last_io := m.io_hist[(m.io_count - 1) % IO_HISTORY]
		log.errorf(
			"VGA BIOS probe timeout CS:IP=%04x:%04x DX=%04x CX=%08x last_io=%c[%04x]/%d=%x exits=%d",
			r.cs_sel,
			r.rip,
			u16(r.rdx),
			u32(r.rcx),
			last_io.write ? 'w' : 'r',
			last_io.port,
			last_io.size,
			last_io.val,
			m.exit_count,
		)
		for i in 0 ..< min(16, int(m.io_count)) {
			entry := m.io_hist[(m.io_count - u64(16) + u64(i)) % IO_HISTORY]
			log.errorf(
				"VGA BIOS recent I/O %d: %c[%04x]/%d=%x",
				i,
				entry.write ? 'w' : 'r',
				entry.port,
				entry.size,
				entry.val,
			)
		}
	}
	if !testing.expect_value(t, m.bus.freeze_msg, "") {return}
	if !testing.expect_value(t, m.vm.ram[0x0506], u8(0xD7)) {return}
	if !pci_firmware_validate_pir_contract(t, m.vm.ram) {return}
	testing.expect_value(t, romw_seen_enabled, false)
	testing.expect_value(t, pci_amd756_bios_write_enabled(&m.pci), false)
	pci_out(&m.pci, 0xCF8, 4, 0x8000_3840)
	testing.expect_value(
		t,
		pci_in(&m.pci, 0xCFF, 1) & u32(AMD756_ISA_HIGH_BIOS_128K_DECODE),
		u32(AMD756_ISA_HIGH_BIOS_128K_DECODE),
	)
	pci_out(&m.pci, 0xCF8, 4, 0x8000_103C)
	testing.expect_value(t, pci_in(&m.pci, 0xCFC, 1), u32(11))

	testing.expect_value(t, m.vm.ram[0x0500] & 0x7F, u8(0x12))
	testing.expect_value(t, u16(m.vm.ram[0x0502]) | u16(m.vm.ram[0x0503]) << 8, u16(0x004F))
	testing.expect_value(t, u16(m.vm.ram[0x0504]) | u16(m.vm.ram[0x0505]) << 8, u16(0x004F))
	ddc_caps_ax := u16(m.vm.ram[0x0508]) | u16(m.vm.ram[0x0509]) << 8
	ddc_caps_bx := u16(m.vm.ram[0x050A]) | u16(m.vm.ram[0x050B]) << 8
	ddc_read_ax := u16(m.vm.ram[0x050C]) | u16(m.vm.ram[0x050D]) << 8
	if ddc_read_ax != 0x004F {
		for i in 0 ..< min(IO_HISTORY, int(m.io_count)) {
			entry := m.io_hist[(m.io_count - u64(i + 1)) % IO_HISTORY]
			log.errorf(
				"VGA BIOS DDC recent I/O -%d: %c[%04x]/%d=%x",
				i + 1,
				entry.write ? 'w' : 'r',
				entry.port,
				entry.size,
				entry.val,
			)
		}
	}
	testing.expect_value(t, ddc_caps_ax, u16(0x004F))
	testing.expect_value(t, ddc_caps_bx, u16(0x0202))
	testing.expect_value(t, ddc_read_ax, u16(0x004F))
	testing.expect_value(t, u16(m.vm.ram[0x050E]) | u16(m.vm.ram[0x050F]) << 8, u16(0x004F))
	for value, i in video.VGA_EDID_BLOCK0 {
		testing.expect_value(t, m.vm.ram[0x0700 + i], value)
	}
	testing.expect_value(t, string(m.vm.ram[0x0600:0x0604]), "VESA")
	testing.expect_value(t, video.dispi_read_register(&m.vga, video.DISPI_INDEX_XRES), u16(320))
	testing.expect_value(t, video.dispi_read_register(&m.vga, video.DISPI_INDEX_YRES), u16(240))
	testing.expect_value(t, video.dispi_read_register(&m.vga, video.DISPI_INDEX_BPP), u16(8))
	testing.expect(t, video.vga_vbe_enabled(&m.vga))

	vram_nonzero := 0
	for byte in video.vga_vram(&m.vga)[:4096] {
		if byte != 0 {vram_nonzero += 1}
	}
	testing.expect(t, vram_nonzero > 0)

	video.vga_sync_to(&m.vga, m.vga.timing.elapsed_ns + 2 * video.VBE_FRAME_PERIOD_NS)
	frame := video.vga_display_frame(&m.vga)
	testing.expect_value(t, frame.kind, video.Display_Kind.Indexed_8)
	testing.expect_value(t, frame.width, 320)
	testing.expect_value(t, frame.height, 240)
	nonblack := 0
	for pixel in frame.pixels {
		if pixel != 0xFF000000 {nonblack += 1}
	}
	testing.expect(t, nonblack > 0)
}
