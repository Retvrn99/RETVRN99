// SPDX-License-Identifier: GPL-3.0-only
package machine

import hv "../hv"
import video "../vga"
import "core:log"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

LEGACY_VGA_PHASE_ADDRESS :: 0x0501
LEGACY_VGA_ACK_ADDRESS :: 0x0502
LEGACY_VGA_RETURN_BASE :: 0x0520
LEGACY_VGA_RETURN_BDA_BASE :: LEGACY_VGA_RETURN_BASE + 10

Legacy_Vga_Probe_Watchdog :: struct {
	vm:   ^hv.Vm,
	stop: bool,
	mu:   sync.Mutex,
}

Legacy_Mode_X_Case :: struct {
	width:  int,
	height: int,
	misc:   u8,
}

@(private = "file")
LEGACY_MODE_X_CASES := [?]Legacy_Mode_X_Case {
	{320, 200, 0x63},
	{320, 240, 0xE3},
	{320, 350, 0xA3},
	{320, 400, 0x63},
	{320, 480, 0xE3},
	{360, 200, 0x67},
	{360, 240, 0xE7},
	{360, 350, 0xA7},
	{360, 400, 0x67},
	{360, 480, 0xE7},
}

@(private = "file")
legacy_mode_x_crtc :: proc(entry: Legacy_Mode_X_Case) -> [25]u8 {
	crtc := [25]u8 {
		0x5F, 0x4F, 0x50, 0x82, 0x54, 0x80,
		0xBF, 0x1F, 0x00, 0x41, 0x00, 0x00, 0x00,
		0x00, 0x00, 0x00, 0x9C, 0x8E, 0x8F, 0x28,
		0x00, 0x96, 0xB9, 0xE3, 0xFF,
	}
	if entry.width == 360 {
		crtc[0], crtc[1], crtc[2] = 0x6B, 0x59, 0x5A
		crtc[3], crtc[4], crtc[5] = 0x8E, 0x5E, 0x8A
	}
	switch entry.height {
	case 200:
		crtc[6], crtc[7], crtc[9] = 0xBF, 0x1F, 0x41
		crtc[0x10], crtc[0x11], crtc[0x12] = 0x9C, 0x8E, 0x8F
		crtc[0x15], crtc[0x16] = 0x96, 0xB9
	case 240:
		crtc[6], crtc[7], crtc[9] = 0x0D, 0x3E, 0x41
		crtc[0x10], crtc[0x11], crtc[0x12] = 0xEA, 0xAC, 0xDF
		crtc[0x15], crtc[0x16] = 0xE7, 0x06
	case 350:
		crtc[6], crtc[7], crtc[9] = 0xBF, 0x1F, 0x40
		crtc[0x10], crtc[0x11], crtc[0x12] = 0x83, 0x85, 0x5D
		crtc[0x15], crtc[0x16] = 0x63, 0xBA
	case 400:
		crtc[6], crtc[7], crtc[9] = 0xBF, 0x1F, 0x40
		crtc[0x10], crtc[0x11], crtc[0x12] = 0x9C, 0x8E, 0x8F
		crtc[0x15], crtc[0x16] = 0x96, 0xB9
	case 480:
		crtc[6], crtc[7], crtc[9] = 0x0D, 0x3E, 0x40
		crtc[0x10], crtc[0x11], crtc[0x12] = 0xEA, 0xAC, 0xDF
		crtc[0x15], crtc[0x16] = 0xE7, 0x06
	}
	crtc[0x13] = u8(entry.width / 8)
	return crtc
}

@(private = "file")
legacy_mode_x_boot_floppy :: proc(cases: []Legacy_Mode_X_Case) -> ([]u8, bool) {
	code := make([dynamic]u8, 0, 512)
	defer delete(code)

	vgabios_probe_emit_prologue(&code)
	vgabios_probe_emit(&code, 0xBE, 0x00, 0x00) // mov si, table (patched)
	table_immediate := len(code) - 2
	vgabios_probe_emit(
		&code,
		0xBD,
		u8(LEGACY_VGA_RETURN_BASE & 0xFF),
		u8(LEGACY_VGA_RETURN_BASE >> 8),
	) // mov bp, return receipts

	loop_start := len(code)
	vgabios_probe_emit(&code, 0x80, 0x3C, 0xFF) // cmp byte [si], 0ffh
	vgabios_probe_emit(&code, 0x75, 0x03) // jne past the near jump
	vgabios_probe_emit(&code, 0xE9, 0x00, 0x00) // jmp done (patched)
	done_displacement := len(code) - 2

	vgabios_probe_emit(&code, 0x56, 0x55) // push si / push bp
	vgabios_probe_emit(&code, 0xB8, 0x13, 0x00, 0xCD, 0x10) // mode 13h
	vgabios_probe_emit(&code, 0x5D, 0x5E) // pop bp / pop si

	vgabios_probe_emit(&code, 0xAC) // lodsb (Miscellaneous Output)
	vgabios_probe_emit(&code, 0xBA, 0xC2, 0x03, 0xEE) // out 03c2h, al
	vgabios_probe_emit(&code, 0xBA, 0xC4, 0x03) // mov dx, 03c4h
	vgabios_probe_emit(&code, 0xB8, 0x00, 0x01, 0xEF) // synchronous reset
	vgabios_probe_emit(&code, 0xB8, 0x04, 0x06, 0xEF) // unchain and disable odd/even
	vgabios_probe_emit(&code, 0xB8, 0x00, 0x03, 0xEF) // restart sequencer

	vgabios_probe_emit(&code, 0xBA, 0xD4, 0x03) // mov dx, 03d4h
	vgabios_probe_emit(&code, 0xB8, 0x11, 0x0C, 0xEF) // unlock CRT Controller 00h-07h
	vgabios_probe_emit(&code, 0x31, 0xDB) // xor bx, bx
	vgabios_probe_emit(&code, 0xB9, 0x19, 0x00) // mov cx, 25
	crtc_loop := len(code)
	vgabios_probe_emit(&code, 0xAC) // lodsb
	vgabios_probe_emit(&code, 0x88, 0xC4) // mov ah, al
	vgabios_probe_emit(&code, 0x88, 0xD8) // mov al, bl
	vgabios_probe_emit(&code, 0xEF) // out dx, ax
	vgabios_probe_emit(&code, 0xFE, 0xC3) // inc bl
	vgabios_probe_emit(&code, 0xE2, u8(i8(crtc_loop - (len(code) + 2)))) // loop

	vgabios_probe_emit(&code, 0xAD, 0x89, 0xC7) // lodsw / mov di, ax
	vgabios_probe_emit(&code, 0xB8, 0x00, 0xA0, 0x8E, 0xC0) // es = a000h
	vgabios_probe_emit(&code, 0xBA, 0xC4, 0x03) // mov dx, 03c4h
	for plane in 0 ..< 4 {
		mask := u8(1) << uint(plane)
		vgabios_probe_emit(&code, 0xB8, 0x02, mask, 0xEF) // map one plane
		vgabios_probe_emit(&code, 0xB0, u8(plane + 1))
		vgabios_probe_emit(&code, 0x26, 0xA2, 0x00, 0x00) // mov es:[0], al
	}
	vgabios_probe_emit(&code, 0xB0, 0x05, 0x26, 0x88, 0x05) // last pixel in plane 3
	vgabios_probe_emit(&code, 0x31, 0xC0, 0x8E, 0xC0) // es = 0

	vgabios_probe_emit(
		&code,
		0xFE,
		0x06,
		u8(LEGACY_VGA_PHASE_ADDRESS & 0xFF),
		u8(LEGACY_VGA_PHASE_ADDRESS >> 8),
	) // inc byte [phase]
	wait_start := len(code)
	vgabios_probe_emit(
		&code,
		0xA0,
		u8(LEGACY_VGA_PHASE_ADDRESS & 0xFF),
		u8(LEGACY_VGA_PHASE_ADDRESS >> 8),
	) // mov al, [phase]
	vgabios_probe_emit(
		&code,
		0x3A,
		0x06,
		u8(LEGACY_VGA_ACK_ADDRESS & 0xFF),
		u8(LEGACY_VGA_ACK_ADDRESS >> 8),
	) // cmp al, [ack]
	vgabios_probe_emit(&code, 0x75, u8(i8(wait_start - (len(code) + 2)))) // jne wait

	vgabios_probe_emit(&code, 0x56, 0x55) // push si / push bp
	vgabios_probe_emit(&code, 0xB8, 0x03, 0x00, 0xCD, 0x10) // mode 3h
	vgabios_probe_emit(&code, 0xB4, 0x0F, 0xCD, 0x10) // get current mode
	vgabios_probe_emit(&code, 0x5D, 0x5E) // pop bp / pop si
	vgabios_probe_emit(&code, 0x88, 0x46, 0x00) // mov [bp], al
	vgabios_probe_emit(&code, 0xA0, 0x49, 0x04) // mov al, [0449h]
	vgabios_probe_emit(&code, 0x88, 0x46, 0x0A) // mov [bp+10], al
	vgabios_probe_emit(&code, 0x45) // inc bp

	back := loop_start - (len(code) + 3)
	back16 := u16(i16(back))
	vgabios_probe_emit(&code, 0xE9, u8(back16 & 0xFF), u8(back16 >> 8))

	forward := len(code) - (done_displacement + 2)
	forward16 := u16(i16(forward))
	code[done_displacement] = u8(forward16 & 0xFF)
	code[done_displacement + 1] = u8(forward16 >> 8)
	vgabios_probe_emit_halt(&code)

	table := len(code)
	for entry in cases {
		vgabios_probe_emit(&code, entry.misc)
		crtc := legacy_mode_x_crtc(entry)
		for value in crtc {vgabios_probe_emit(&code, value)}
		last := u16(entry.width / 4 * entry.height - 1)
		vgabios_probe_emit(&code, u8(last & 0xFF), u8(last >> 8))
	}
	vgabios_probe_emit(&code, 0xFF)

	linear := 0x7C00 + table
	code[table_immediate] = u8(linear & 0xFF)
	code[table_immediate + 1] = u8(linear >> 8)
	return vgabios_probe_image(code[:])
}

@(private = "file")
legacy_vga_probe_start_watchdog :: proc(w: ^Legacy_Vga_Probe_Watchdog) -> ^thread.Thread {
	return thread.create_and_start_with_poly_data(w, proc(ctx: ^Legacy_Vga_Probe_Watchdog) {
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
legacy_vga_probe_stop_watchdog :: proc(w: ^Legacy_Vga_Probe_Watchdog, th: ^thread.Thread) {
	sync.lock(&w.mu)
	w.stop = true
	sync.unlock(&w.mu)
	thread.destroy(th)
}

@(private = "file")
legacy_vga_probe_run_mode_x :: proc(
	t: ^testing.T,
	m: ^Machine,
	image: []u8,
	cases: []Legacy_Mode_X_Case,
	timeout: time.Duration,
	presentation_mismatch: ^bool,
) -> bool {
	if !testing.expect(t, machine_mount_floppy(m, image)) {return false}
	m.platform.cmos.ram[0x3D] = 0x01
	fwcfg_add_file(&m.fwcfg, "etc/show-boot-menu", []u8{0, 0, 0, 0}, 0x0022)

	watchdog := Legacy_Vga_Probe_Watchdog {vm = &m.vm}
	watchdog_thread := legacy_vga_probe_start_watchdog(&watchdog)
	defer legacy_vga_probe_stop_watchdog(&watchdog, watchdog_thread)

	phase: u8
	start := time.tick_now()
	for time.tick_since(start) < timeout &&
	    m.vm.ram[VGABIOS_PROBE_SENTINEL_ADDRESS] != VGABIOS_PROBE_SENTINEL {
		if !step(m) {break}
		next := m.vm.ram[LEGACY_VGA_PHASE_ADDRESS]
		if next == phase {continue}
		if !testing.expect_value(t, next, phase + 1) {return false}
		index := int(next - 1)
		if !testing.expect(t, index < len(cases)) {return false}
		entry := cases[index]
		frame := video.vga_display_frame(&m.vga)
		if frame.kind != .Indexed_8 || frame.width != entry.width || frame.height != entry.height {
			if presentation_mismatch != nil {presentation_mismatch^ = true}
			log.errorf(
				"Mode X %dx%d produced %v %dx%d",
				entry.width,
				entry.height,
				frame.kind,
				frame.width,
				frame.height,
			)
		}
		testing.expect_value(t, frame.kind, video.Display_Kind.Indexed_8)
		testing.expect_value(t, frame.width, entry.width)
		testing.expect_value(t, frame.height, entry.height)
		testing.expect_value(t, m.vga.seq[4] & 0x0E, u8(0x06))
		testing.expect_value(t, m.vga.crtc[0x01], u8(entry.width / 4 - 1))
		testing.expect_value(t, m.vga.crtc[0x13], u8(entry.width / 8))
		visible_lines := entry.height
		if entry.height == 200 || entry.height == 240 {visible_lines *= 2}
		testing.expect_value(t, m.vga.timing.visible_lines, visible_lines)

		if len(frame.pixels) == entry.width * entry.height {
			for x in 0 ..< 4 {
				for earlier in 0 ..< x {
					testing.expect(t, frame.pixels[x] != frame.pixels[earlier])
				}
			}
			last := frame.pixels[len(frame.pixels) - 1]
			testing.expect(t, last != frame.pixels[0])
		} else {
			testing.expect_value(t, len(frame.pixels), entry.width * entry.height)
		}
		m.vm.ram[LEGACY_VGA_ACK_ADDRESS] = next
		phase = next
	}
	if m.vm.ram[VGABIOS_PROBE_SENTINEL_ADDRESS] != VGABIOS_PROBE_SENTINEL {
		r := hv.get_regs(&m.vm)
		log.errorf(
			"legacy VGA probe timeout phase=%d CS:IP=%04x:%04x exits=%d",
			phase,
			r.cs_sel,
			r.rip,
			m.exit_count,
		)
	}
	if !testing.expect_value(t, m.platform.bus.freeze_msg, "") {return false}
	if !testing.expect_value(t, phase, u8(len(cases))) {return false}
	return testing.expect_value(
		t,
		m.vm.ram[VGABIOS_PROBE_SENTINEL_ADDRESS],
		u8(VGABIOS_PROBE_SENTINEL),
	)
}

@(test)
test_machine_public_port_mode_x_geometry_matrix_returns_to_mode_3 :: proc(t: ^testing.T) {
	if !hv.available() {
		log.warn("WHPX not available")
		return
	}
	testing.set_fail_timeout(t, 90 * time.Second)
	m := new(Machine)
	defer free(m)
	if !testing.expect(t, machine_init(m, 64 * 1024 * 1024)) {return}
	defer machine_destroy(m)
	machine_set_diagnostic_tracing(m, true)
	if !testing.expect(t, load_roms(&m.vm)) {return}

	cases := LEGACY_MODE_X_CASES[:]
	floppy, built := legacy_mode_x_boot_floppy(cases)
	if !testing.expect(t, built) {return}
	defer delete(floppy)
	presentation_mismatch := false
	if !legacy_vga_probe_run_mode_x(
		t,
		m,
		floppy,
		cases,
		60 * time.Second,
		&presentation_mismatch,
	) {return}

	for _, index in cases {
		current := m.vm.ram[LEGACY_VGA_RETURN_BASE + index] & 0x7F
		bda := m.vm.ram[LEGACY_VGA_RETURN_BDA_BASE + index] & 0x7F
		if current != 0x03 || bda != 0x03 {
			log.errorf("Mode X case %d returned current=%02x BDA=%02x", index, current, bda)
		}
		testing.expect_value(t, current, u8(0x03))
		testing.expect_value(t, bda, u8(0x03))
	}
	frame := video.vga_display_frame(&m.vga)
	if frame.kind != .Text {presentation_mismatch = true}
	testing.expect(t, !presentation_mismatch)
	testing.expect_value(t, frame.kind, video.Display_Kind.Text)
}

Legacy_Reserved_Field :: enum {
	Current_Mode,
	Columns,
	Active_Page,
	Bda_Mode,
	Misc_Output,
	Crtc_Horizontal_Display_End,
	Crtc_Vertical_Display_End,
	Seq_Memory_Mode,
}

LEGACY_RESERVED_RECORD_BYTES :: int(len(Legacy_Reserved_Field))

@(private = "file")
legacy_reserved_emit_capture :: proc(code: ^[dynamic]u8, destination: int) {
	vgabios_probe_emit(code, 0xB4, 0x0F, 0xCD, 0x10) // get current mode
	vgabios_probe_emit_store(code, destination + int(Legacy_Reserved_Field.Current_Mode))
	vgabios_probe_emit(code, 0x88, 0xE0)
	vgabios_probe_emit_store(code, destination + int(Legacy_Reserved_Field.Columns))
	vgabios_probe_emit(code, 0x88, 0xF8)
	vgabios_probe_emit_store(code, destination + int(Legacy_Reserved_Field.Active_Page))
	vgabios_probe_emit_load(code, 0x0449)
	vgabios_probe_emit_store(code, destination + int(Legacy_Reserved_Field.Bda_Mode))
	vgabios_probe_emit(code, 0xBA, 0xCC, 0x03, 0xEC)
	vgabios_probe_emit_store(code, destination + int(Legacy_Reserved_Field.Misc_Output))
	vgabios_probe_emit_read_crtc(code, 0x01)
	vgabios_probe_emit_store(code, destination + int(Legacy_Reserved_Field.Crtc_Horizontal_Display_End))
	vgabios_probe_emit_read_crtc(code, 0x12)
	vgabios_probe_emit_store(code, destination + int(Legacy_Reserved_Field.Crtc_Vertical_Display_End))
	vgabios_probe_emit(code, 0xBA, 0xC4, 0x03, 0xB0, 0x04, 0xEE, 0x42, 0xEC)
	vgabios_probe_emit_store(code, destination + int(Legacy_Reserved_Field.Seq_Memory_Mode))
}

@(private = "file")
legacy_reserved_boot_floppy :: proc() -> ([]u8, bool) {
	code := make([dynamic]u8, 0, 512)
	defer delete(code)
	vgabios_probe_emit_prologue(&code)
	vgabios_probe_emit(&code, 0xB8, 0x03, 0x00, 0xCD, 0x10)
	legacy_reserved_emit_capture(&code, LEGACY_VGA_RETURN_BASE)
	for mode in u8(0x08) ..= u8(0x0C) {
		vgabios_probe_emit(&code, 0xB8, 0x03, 0x00, 0xCD, 0x10)
		vgabios_probe_emit(&code, 0xB8, mode, 0x00, 0xCD, 0x10)
		destination :=
			LEGACY_VGA_RETURN_BASE + (int(mode) - 0x08 + 1) * LEGACY_RESERVED_RECORD_BYTES
		legacy_reserved_emit_capture(&code, destination)
	}
	vgabios_probe_emit(&code, 0xB8, 0x03, 0x00, 0xCD, 0x10)
	vgabios_probe_emit_halt(&code)
	return vgabios_probe_image(code[:])
}

@(test)
test_machine_vgabios_reserved_modes_leave_mode_3_unchanged :: proc(t: ^testing.T) {
	if !hv.available() {
		log.warn("WHPX not available")
		return
	}
	testing.set_fail_timeout(t, 60 * time.Second)
	m := new(Machine)
	defer free(m)
	if !testing.expect(t, machine_init(m, 64 * 1024 * 1024)) {return}
	defer machine_destroy(m)
	machine_set_diagnostic_tracing(m, true)
	if !testing.expect(t, load_roms(&m.vm)) {return}

	floppy, built := legacy_reserved_boot_floppy()
	if !testing.expect(t, built) {return}
	defer delete(floppy)
	if !vgabios_probe_run(t, m, floppy, 45 * time.Second) {return}

	baseline := m.vm.ram[
		LEGACY_VGA_RETURN_BASE:LEGACY_VGA_RETURN_BASE + LEGACY_RESERVED_RECORD_BYTES
	]
	testing.expect_value(t, baseline[int(Legacy_Reserved_Field.Current_Mode)] & 0x7F, u8(0x03))
	testing.expect_value(t, baseline[int(Legacy_Reserved_Field.Columns)], u8(80))
	testing.expect_value(t, baseline[int(Legacy_Reserved_Field.Active_Page)], u8(0))
	testing.expect_value(t, baseline[int(Legacy_Reserved_Field.Bda_Mode)] & 0x7F, u8(0x03))
	for mode in 0x08 ..= 0x0C {
		base := LEGACY_VGA_RETURN_BASE + (mode - 0x08 + 1) * LEGACY_RESERVED_RECORD_BYTES
		for field in Legacy_Reserved_Field {
			actual := m.vm.ram[base + int(field)]
			expected := baseline[int(field)]
			if field == .Current_Mode || field == .Bda_Mode {
				actual &= 0x7F
				expected &= 0x7F
			}
			if actual != expected {
				log.errorf(
					"reserved INT 10h mode %02Xh changed %v from %02X to %02X",
					mode,
					field,
					expected,
					actual,
				)
			}
			testing.expect_value(t, actual, expected)
		}
	}
}
