// SPDX-License-Identifier: GPL-3.0-only
package machine

import disk "../disk"
import hv "../hv"
import "core:log"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

// The probe records one fixed-size record per INT 10h mode into low memory.
MODE_MATRIX_RESULT_BASE :: 0x0520
MODE_MATRIX_RECORD_BYTES :: 11
MODE_MATRIX_SENTINEL_ADDRESS :: 0x0500
MODE_MATRIX_SENTINEL :: 0xD7

Mode_Matrix_Field :: enum {
	Requested_Mode,
	Current_Mode,
	Columns,
	Active_Page,
	Bda_Mode,
	Bda_Columns,
	Bda_Rows_Minus_One,
	Bda_Character_Height,
	Misc_Output,
	Crtc_Horizontal_Display_End,
	Crtc_Vertical_Display_End,
}

Mode_Matrix_Case :: struct {
	mode:                   u8,
	columns:                u8,
	rows_minus_one:         u8,
	character_height:       u8,
	misc_output:            u8,
	horizontal_display_end: u8,
	vertical_display_end:   u8,
}

// Expected state after a real VGABIOS mode set. Column counts, row counts, and
// character heights follow the IBM BIOS contract; Miscellaneous Output and CRT
// Controller geometry follow the pinned Bochs VGABIOS mode table.
//
// Only mode 07h drives Miscellaneous Output bit 0 low and therefore addresses
// the CRT Controller at 3B4h. Mode 0Fh is monochrome in attribute handling but
// still a colour-adapter mode at 3D4h.
//
// Horizontal display end counts character clocks, not BIOS text columns. Mode
// 13h reports 40 columns while programming 80 character clocks, so the two
// contracts are asserted separately.
@(private = "file")
MODE_MATRIX_CASES := [?]Mode_Matrix_Case {
	{0x00, 40, 24, 16, 0x67, 39, 0x8F},
	{0x01, 40, 24, 16, 0x67, 39, 0x8F},
	{0x02, 80, 24, 16, 0x67, 79, 0x8F},
	{0x03, 80, 24, 16, 0x67, 79, 0x8F},
	{0x04, 40, 24, 8, 0x63, 39, 0x8F},
	{0x05, 40, 24, 8, 0x63, 39, 0x8F},
	{0x06, 80, 24, 8, 0x63, 79, 0x8F},
	{0x07, 80, 24, 16, 0x66, 79, 0x8F},
	{0x0D, 40, 24, 8, 0x63, 39, 0x8F},
	{0x0E, 80, 24, 8, 0x63, 79, 0x8F},
	{0x0F, 80, 24, 14, 0xA3, 79, 0x5D},
	{0x10, 80, 24, 14, 0xA3, 79, 0x5D},
	{0x11, 80, 29, 16, 0xE3, 79, 0xDF},
	{0x12, 80, 29, 16, 0xE3, 79, 0xDF},
	{0x13, 40, 24, 8, 0x63, 79, 0x8F},
}

@(private = "file")
mode_matrix_emit :: proc(code: ^[dynamic]u8, bytes: ..u8) {
	for value in bytes {append(code, value)}
}

// Builds a 16-bit real-mode boot sector that walks a mode table, sets each
// mode through INT 10h AH=00h, and records BIOS and public-port state.
@(private = "file")
mode_matrix_boot_floppy :: proc(cases: []Mode_Matrix_Case) -> ([]u8, bool) {
	code := make([dynamic]u8, 0, 512)
	defer delete(code)

	mode_matrix_emit(&code, 0xFA) // cli
	mode_matrix_emit(&code, 0x31, 0xC0) // xor ax, ax
	mode_matrix_emit(&code, 0x8E, 0xD8) // mov ds, ax
	mode_matrix_emit(&code, 0x8E, 0xC0) // mov es, ax
	mode_matrix_emit(&code, 0x8E, 0xD0) // mov ss, ax
	mode_matrix_emit(&code, 0xBC, 0x00, 0x7C) // mov sp, 7c00h
	mode_matrix_emit(&code, 0xFB) // sti
	mode_matrix_emit(&code, 0xBE, 0x00, 0x00) // mov si, table (patched)
	table_immediate := len(code) - 2
	mode_matrix_emit(
		&code,
		0xBF,
		u8(MODE_MATRIX_RESULT_BASE & 0xFF),
		u8(MODE_MATRIX_RESULT_BASE >> 8),
	) // mov di, results

	loop_start := len(code)
	mode_matrix_emit(&code, 0xAC) // lodsb
	mode_matrix_emit(&code, 0x3C, 0xFF) // cmp al, 0ffh
	mode_matrix_emit(&code, 0x74, 0x00) // je done (patched)
	done_displacement := len(code) - 1

	mode_matrix_emit(&code, 0x88, 0xC3) // mov bl, al
	mode_matrix_emit(&code, 0x56, 0x57) // push si / push di
	mode_matrix_emit(&code, 0x30, 0xE4) // xor ah, ah
	mode_matrix_emit(&code, 0xCD, 0x10) // int 10h
	mode_matrix_emit(&code, 0x5F, 0x5E) // pop di / pop si
	mode_matrix_emit(&code, 0x88, 0xD8) // mov al, bl
	mode_matrix_emit(&code, 0xAA) // stosb requested mode

	mode_matrix_emit(&code, 0x56, 0x57) // push si / push di
	mode_matrix_emit(&code, 0xB4, 0x0F) // mov ah, 0fh
	mode_matrix_emit(&code, 0xCD, 0x10) // int 10h
	mode_matrix_emit(&code, 0x5F, 0x5E) // pop di / pop si
	mode_matrix_emit(&code, 0x89, 0xC1) // mov cx, ax
	mode_matrix_emit(&code, 0x88, 0xFA) // mov dl, bh
	mode_matrix_emit(&code, 0x88, 0xC8, 0xAA) // mov al, cl / stosb
	mode_matrix_emit(&code, 0x88, 0xE8, 0xAA) // mov al, ch / stosb
	mode_matrix_emit(&code, 0x88, 0xD0, 0xAA) // mov al, dl / stosb

	mode_matrix_emit(&code, 0xA0, 0x49, 0x04, 0xAA) // mov al, [0449h] / stosb
	mode_matrix_emit(&code, 0xA0, 0x4A, 0x04, 0xAA) // mov al, [044Ah] / stosb
	mode_matrix_emit(&code, 0xA0, 0x84, 0x04, 0xAA) // mov al, [0484h] / stosb
	mode_matrix_emit(&code, 0xA0, 0x85, 0x04, 0xAA) // mov al, [0485h] / stosb

	mode_matrix_emit(&code, 0xBA, 0xCC, 0x03) // mov dx, 03cch
	mode_matrix_emit(&code, 0xEC, 0xAA) // in al, dx / stosb

	// The CRT Controller address follows Miscellaneous Output bit 0.
	mode_matrix_emit(&code, 0xBA, 0xB4, 0x03) // mov dx, 03b4h
	mode_matrix_emit(&code, 0x24, 0x01) // and al, 1
	mode_matrix_emit(&code, 0xB4, 0x20) // mov ah, 20h
	mode_matrix_emit(&code, 0xF6, 0xE4) // mul ah
	mode_matrix_emit(&code, 0x01, 0xC2) // add dx, ax

	mode_matrix_emit(&code, 0xB0, 0x01, 0xEE) // mov al, 1 / out dx, al
	mode_matrix_emit(&code, 0x42, 0xEC, 0xAA) // inc dx / in al, dx / stosb
	mode_matrix_emit(&code, 0x4A) // dec dx
	mode_matrix_emit(&code, 0xB0, 0x12, 0xEE) // mov al, 12h / out dx, al
	mode_matrix_emit(&code, 0x42, 0xEC, 0xAA) // inc dx / in al, dx / stosb

	back := loop_start - (len(code) + 2)
	if back < -128 {return nil, false}
	mode_matrix_emit(&code, 0xEB, u8(i8(back))) // jmp loop_start

	forward := len(code) - (done_displacement + 1)
	if forward > 127 {return nil, false}
	code[done_displacement] = u8(i8(forward))

	mode_matrix_emit(
		&code,
		0xC6,
		0x06,
		u8(MODE_MATRIX_SENTINEL_ADDRESS & 0xFF),
		u8(MODE_MATRIX_SENTINEL_ADDRESS >> 8),
		MODE_MATRIX_SENTINEL,
	) // mov byte [0500h], 0d7h
	mode_matrix_emit(&code, 0xFA, 0xF4, 0xEB, 0xFD) // cli / hlt / jmp hlt

	table := len(code)
	for entry in cases {
		if entry.mode == 0xFF {return nil, false}
		mode_matrix_emit(&code, entry.mode)
	}
	mode_matrix_emit(&code, 0xFF)

	linear := 0x7C00 + table
	code[table_immediate] = u8(linear & 0xFF)
	code[table_immediate + 1] = u8(linear >> 8)

	if len(code) > 510 {return nil, false}

	image := make([]u8, disk.FLOPPY_144_SIZE)
	copy(image, code[:])
	image[510] = 0x55
	image[511] = 0xAA
	return image, true
}

@(private = "file")
mode_matrix_start_watchdog :: proc(w: ^Vgabios_Test_Watchdog) -> ^thread.Thread {
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
mode_matrix_stop_watchdog :: proc(w: ^Vgabios_Test_Watchdog, th: ^thread.Thread) {
	sync.lock(&w.mu)
	w.stop = true
	sync.unlock(&w.mu)
	thread.destroy(th)
}

@(private = "file")
mode_matrix_field :: proc(m: ^Machine, index: int, field: Mode_Matrix_Field) -> u8 {
	return m.vm.ram[MODE_MATRIX_RESULT_BASE + index * MODE_MATRIX_RECORD_BYTES + int(field)]
}

@(test)
test_machine_vgabios_int10_mode_matrix :: proc(t: ^testing.T) {
	if !hv.available() {
		log.warn("WHPX not available")
		return
	}
	testing.set_fail_timeout(t, 60 * time.Second)
	cases := MODE_MATRIX_CASES[:]
	m := new(Machine)
	defer free(m)
	if !testing.expect(t, machine_init(m, 64 * 1024 * 1024)) {return}
	defer machine_destroy(m)
	machine_set_diagnostic_tracing(m, true)
	if !testing.expect(t, load_roms(&m.vm)) {return}

	floppy, built := mode_matrix_boot_floppy(cases)
	if !testing.expect(t, built) {return}
	defer delete(floppy)
	if !testing.expect(t, machine_mount_floppy(m, floppy)) {return}
	m.cmos.ram[0x3D] = 0x01
	fwcfg_add_file(&m.fwcfg, "etc/show-boot-menu", []u8{0, 0, 0, 0}, 0x0022)

	watchdog := Vgabios_Test_Watchdog {
		vm = &m.vm,
	}
	watchdog_thread := mode_matrix_start_watchdog(&watchdog)
	defer mode_matrix_stop_watchdog(&watchdog, watchdog_thread)

	start := time.tick_now()
	for time.tick_since(start) < 45 * time.Second &&
	    m.vm.ram[MODE_MATRIX_SENTINEL_ADDRESS] != MODE_MATRIX_SENTINEL {
		if !step(m) {break}
	}
	if m.vm.ram[MODE_MATRIX_SENTINEL_ADDRESS] != MODE_MATRIX_SENTINEL {
		r := hv.get_regs(&m.vm)
		log.errorf(
			"VGA BIOS mode matrix timeout CS:IP=%04x:%04x exits=%d",
			r.cs_sel,
			r.rip,
			m.exit_count,
		)
	}
	if !testing.expect_value(t, m.bus.freeze_msg, "") {return}
	if !testing.expect_value(
		t,
		m.vm.ram[MODE_MATRIX_SENTINEL_ADDRESS],
		u8(MODE_MATRIX_SENTINEL),
	) {return}

	for entry, index in cases {
		expected := [Mode_Matrix_Field]u8 {
			.Requested_Mode              = entry.mode,
			.Current_Mode                = entry.mode,
			.Columns                     = entry.columns,
			.Active_Page                 = 0,
			.Bda_Mode                    = entry.mode,
			.Bda_Columns                 = entry.columns,
			.Bda_Rows_Minus_One          = entry.rows_minus_one,
			.Bda_Character_Height        = entry.character_height,
			.Misc_Output                 = entry.misc_output,
			.Crtc_Horizontal_Display_End = entry.horizontal_display_end,
			.Crtc_Vertical_Display_End   = entry.vertical_display_end,
		}
		for field in Mode_Matrix_Field {
			actual := mode_matrix_field(m, index, field)
			// INT 10h AH=0Fh and the BDA report the mode without the
			// preserve-memory flag.
			if field == .Current_Mode || field == .Bda_Mode {actual &= 0x7F}
			if actual == expected[field] {continue}
			log.errorf(
				"INT 10h mode %02Xh field %v expected %02X got %02X",
				entry.mode,
				field,
				expected[field],
				actual,
			)
			testing.expect_value(t, actual, expected[field])
		}
	}
}
