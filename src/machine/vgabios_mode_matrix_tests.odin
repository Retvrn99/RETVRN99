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
MODE_MATRIX_RECORD_BYTES :: 21

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
	Crtc_Start_Horizontal_Blanking,
	Crtc_End_Horizontal_Blanking,
	Crtc_Start_Horizontal_Retrace,
	Crtc_End_Horizontal_Retrace,
	Crtc_Start_Vertical_Blanking,
	Crtc_End_Vertical_Blanking,
	Crtc_Overflow,
	Crtc_Maximum_Scan_Line,
	Seq_Clocking_Mode,
	Seq_Memory_Mode,
}

// CRT Controller indices captured per mode, in the order the record stores
// them after Misc_Output.
@(private = "file")
MODE_MATRIX_CRTC_INDICES := [?]u8{0x01, 0x12, 0x02, 0x03, 0x04, 0x05, 0x15, 0x16, 0x07, 0x09}

Mode_Matrix_Case :: struct {
	mode:                   u8,
	columns:                u8,
	rows_minus_one:         u8,
	character_height:       u8,
	misc_output:            u8,
	horizontal_display_end: u8,
	vertical_display_end:   u8,
	// Reconstructed from the Overflow and Maximum Scan Line registers.
	display_lines:          u16,
	maximum_scan_line:      u8,
	scan_double:            bool,
	nine_dot_characters:    bool,
	dot_clock_divide:       bool,
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
	{0x00, 40, 24, 16, 0x67, 39, 0x8F, 400, 15, false, true, true},
	{0x01, 40, 24, 16, 0x67, 39, 0x8F, 400, 15, false, true, true},
	{0x02, 80, 24, 16, 0x67, 79, 0x8F, 400, 15, false, true, false},
	{0x03, 80, 24, 16, 0x67, 79, 0x8F, 400, 15, false, true, false},
	{0x04, 40, 24, 8, 0x63, 39, 0x8F, 400, 1, true, false, true},
	{0x05, 40, 24, 8, 0x63, 39, 0x8F, 400, 1, true, false, true},
	{0x06, 80, 24, 8, 0x63, 79, 0x8F, 400, 1, true, false, false},
	{0x07, 80, 24, 16, 0x66, 79, 0x8F, 400, 15, false, true, false},
	{0x0D, 40, 24, 8, 0x63, 39, 0x8F, 400, 0, true, false, true},
	{0x0E, 80, 24, 8, 0x63, 79, 0x8F, 400, 0, true, false, false},
	{0x0F, 80, 24, 14, 0xA3, 79, 0x5D, 350, 0, false, false, false},
	{0x10, 80, 24, 14, 0xA3, 79, 0x5D, 350, 0, false, false, false},
	{0x11, 80, 29, 16, 0xE3, 79, 0xDF, 480, 0, false, false, false},
	{0x12, 80, 29, 16, 0xE3, 79, 0xDF, 480, 0, false, false, false},
	{0x13, 40, 24, 8, 0x63, 79, 0x8F, 400, 1, false, false, false},
}

// Builds a 16-bit real-mode boot sector that walks a mode table, sets each
// mode through INT 10h AH=00h, and records BIOS and public-port state.
@(private = "file")
mode_matrix_boot_floppy :: proc(cases: []Mode_Matrix_Case) -> ([]u8, bool) {
	code := make([dynamic]u8, 0, 512)
	defer delete(code)

	vgabios_probe_emit_prologue(&code)
	vgabios_probe_emit(&code, 0xBE, 0x00, 0x00) // mov si, table (patched)
	table_immediate := len(code) - 2
	vgabios_probe_emit(
		&code,
		0xBF,
		u8(VGABIOS_PROBE_RESULT_BASE & 0xFF),
		u8(VGABIOS_PROBE_RESULT_BASE >> 8),
	) // mov di, results

	loop_start := len(code)
	vgabios_probe_emit(&code, 0xAC) // lodsb
	vgabios_probe_emit(&code, 0x3C, 0xFF) // cmp al, 0ffh
	// The loop body outgrew the reach of a short branch, so a conditional
	// short jump skips a near jump instead.
	vgabios_probe_emit(&code, 0x75, 0x03) // jne past the near jump
	vgabios_probe_emit(&code, 0xE9, 0x00, 0x00) // jmp done (patched)
	done_displacement := len(code) - 2

	vgabios_probe_emit(&code, 0x88, 0xC3) // mov bl, al
	vgabios_probe_emit(&code, 0x56, 0x57) // push si / push di
	vgabios_probe_emit(&code, 0x30, 0xE4) // xor ah, ah
	vgabios_probe_emit(&code, 0xCD, 0x10) // int 10h
	vgabios_probe_emit(&code, 0x5F, 0x5E) // pop di / pop si
	vgabios_probe_emit(&code, 0x88, 0xD8) // mov al, bl
	vgabios_probe_emit(&code, 0xAA) // stosb requested mode

	vgabios_probe_emit(&code, 0x56, 0x57) // push si / push di
	vgabios_probe_emit(&code, 0xB4, 0x0F) // mov ah, 0fh
	vgabios_probe_emit(&code, 0xCD, 0x10) // int 10h
	vgabios_probe_emit(&code, 0x5F, 0x5E) // pop di / pop si
	vgabios_probe_emit(&code, 0x89, 0xC1) // mov cx, ax
	vgabios_probe_emit(&code, 0x88, 0xFA) // mov dl, bh
	vgabios_probe_emit(&code, 0x88, 0xC8, 0xAA) // mov al, cl / stosb
	vgabios_probe_emit(&code, 0x88, 0xE8, 0xAA) // mov al, ch / stosb
	vgabios_probe_emit(&code, 0x88, 0xD0, 0xAA) // mov al, dl / stosb

	vgabios_probe_emit(&code, 0xA0, 0x49, 0x04, 0xAA) // mov al, [0449h] / stosb
	vgabios_probe_emit(&code, 0xA0, 0x4A, 0x04, 0xAA) // mov al, [044Ah] / stosb
	vgabios_probe_emit(&code, 0xA0, 0x84, 0x04, 0xAA) // mov al, [0484h] / stosb
	vgabios_probe_emit(&code, 0xA0, 0x85, 0x04, 0xAA) // mov al, [0485h] / stosb

	vgabios_probe_emit(&code, 0xBA, 0xCC, 0x03) // mov dx, 03cch
	vgabios_probe_emit(&code, 0xEC, 0xAA) // in al, dx / stosb

	// The CRT Controller address follows Miscellaneous Output bit 0.
	vgabios_probe_emit(&code, 0xBA, 0xB4, 0x03) // mov dx, 03b4h
	vgabios_probe_emit(&code, 0x24, 0x01) // and al, 1
	vgabios_probe_emit(&code, 0xB4, 0x20) // mov ah, 20h
	vgabios_probe_emit(&code, 0xF6, 0xE4) // mul ah
	vgabios_probe_emit(&code, 0x01, 0xC2) // add dx, ax

	for index in MODE_MATRIX_CRTC_INDICES {
		vgabios_probe_emit(&code, 0xB0, index, 0xEE) // mov al, index / out dx, al
		vgabios_probe_emit(&code, 0x42, 0xEC, 0xAA) // inc dx / in al, dx / stosb
		vgabios_probe_emit(&code, 0x4A) // dec dx
	}

	// The Sequencer sits at a fixed address and needs none of the Miscellaneous
	// Output arithmetic above, so it is read after the CRT Controller sweep.
	vgabios_probe_emit(&code, 0xBA, 0xC4, 0x03) // mov dx, 03c4h
	for index in ([?]u8{0x01, 0x04}) {
		vgabios_probe_emit(&code, 0xB0, index, 0xEE) // mov al, index / out dx, al
		vgabios_probe_emit(&code, 0x42, 0xEC, 0xAA) // inc dx / in al, dx / stosb
		vgabios_probe_emit(&code, 0x4A) // dec dx
	}

	back := loop_start - (len(code) + 3)
	if back < -32768 {return nil, false}
	back16 := u16(i16(back))
	vgabios_probe_emit(&code, 0xE9, u8(back16 & 0xFF), u8(back16 >> 8)) // jmp loop_start

	forward := len(code) - (done_displacement + 2)
	if forward > 32767 {return nil, false}
	forward16 := u16(i16(forward))
	code[done_displacement] = u8(forward16 & 0xFF)
	code[done_displacement + 1] = u8(forward16 >> 8)

	vgabios_probe_emit_halt(&code)

	table := len(code)
	for entry in cases {
		if entry.mode == 0xFF {return nil, false}
		vgabios_probe_emit(&code, entry.mode)
	}
	vgabios_probe_emit(&code, 0xFF)

	linear := 0x7C00 + table
	code[table_immediate] = u8(linear & 0xFF)
	code[table_immediate + 1] = u8(linear >> 8)

	return vgabios_probe_image(code[:])
}

@(private = "file")
mode_matrix_field :: proc(m: ^Machine, index: int, field: Mode_Matrix_Field) -> u8 {
	return m.vm.ram[VGABIOS_PROBE_RESULT_BASE + index * MODE_MATRIX_RECORD_BYTES + int(field)]
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
	if !vgabios_probe_run(t, m, floppy, 45 * time.Second) {return}

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
			// Checked relationally below rather than against a table.
			.Crtc_Start_Horizontal_Blanking = 0,
			.Crtc_End_Horizontal_Blanking = 0,
			.Crtc_Start_Horizontal_Retrace = 0,
			.Crtc_End_Horizontal_Retrace = 0,
			.Crtc_Start_Vertical_Blanking = 0,
			.Crtc_End_Vertical_Blanking = 0,
			.Crtc_Overflow = 0,
			.Crtc_Maximum_Scan_Line = 0,
			.Seq_Clocking_Mode = 0,
			.Seq_Memory_Mode = 0,
		}
		for field in Mode_Matrix_Field {
			// Fields beyond the vertical display end carry relational rather
			// than tabulated expectations; they are checked below.
			if field > .Crtc_Vertical_Display_End {continue}
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

		// Reconstruct the ten-bit vertical fields. Overflow bit 1 and bit 6
		// carry Vertical Display Enable End bits 8 and 9; Overflow bit 3 and
		// Maximum Scan Line bit 5 carry Start Vertical Blanking bits 8 and 9.
		overflow := mode_matrix_field(m, index, .Crtc_Overflow)
		maximum := mode_matrix_field(m, index, .Crtc_Maximum_Scan_Line)
		display_end :=
			u16(mode_matrix_field(m, index, .Crtc_Vertical_Display_End)) |
			u16(overflow & 0x02) << 7 |
			u16(overflow & 0x40) << 3
		blank_start :=
			u16(mode_matrix_field(m, index, .Crtc_Start_Vertical_Blanking)) |
			u16(overflow & 0x08) << 5 |
			u16(maximum & 0x20) << 4
		testing.expect_value(t, display_end, entry.display_lines - 1)
		testing.expect_value(t, maximum & 0x1F, entry.maximum_scan_line)
		testing.expect_value(t, maximum & 0x80 != 0, entry.scan_double)
		// Vertical blanking begins after the display ends.
		testing.expect(t, blank_start > display_end)

		// Horizontal blanking begins after the display ends, and horizontal
		// retrace begins inside the blanking period.
		blanking := mode_matrix_field(m, index, .Crtc_Start_Horizontal_Blanking)
		retrace := mode_matrix_field(m, index, .Crtc_Start_Horizontal_Retrace)
		testing.expect(t, blanking > entry.horizontal_display_end)
		testing.expect(t, retrace >= blanking)
		// End Horizontal Blanking bit 7 is always set on VGA.
		testing.expect_value(
			t,
			mode_matrix_field(m, index, .Crtc_End_Horizontal_Blanking) & 0x80,
			u8(0x80),
		)

		clocking := mode_matrix_field(m, index, .Seq_Clocking_Mode)
		memory_mode := mode_matrix_field(m, index, .Seq_Memory_Mode)
		log.infof(
			"INT 10h mode %02Xh sequencer clocking=%02X memory=%02X",
			entry.mode,
			clocking,
			memory_mode,
		)
		testing.expect_value(t, clocking & 0x01 == 0, entry.nine_dot_characters)
		testing.expect_value(t, clocking & 0x08 != 0, entry.dot_clock_divide)
		// The serializer load-rate controls stay at their reset value in every
		// mode the firmware sets, which is why nothing consumes them.
		testing.expect_value(t, clocking & 0x14, u8(0))
		// A completed mode set never leaves the screen switched off.
		testing.expect_value(t, clocking & 0x20, u8(0))
		// Extended memory is enabled in every mode.
		testing.expect_value(t, memory_mode & 0x02, u8(0x02))
	}
}
