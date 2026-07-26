// SPDX-License-Identifier: GPL-3.0-only
package machine

import hv "../hv"
import video "../vga"
import "core:log"
import "core:testing"
import "core:time"

// INT 10h AH=11h AL=30h reports CX and DL for the font currently on screen,
// not for the block requested in BH. Only the returned ES:BP pointer varies
// per block, so the query records the pointer offset and the matrix asserts
// that the three ROM fonts resolve to distinct addresses.
Font_Info_Field :: enum {
	On_Screen_Bytes,
	On_Screen_Rows_Minus_One,
	Pointer_Low,
	Pointer_High,
}

FONT_INFO_BLOCKS :: 3
FONT_INFO_RECORD_BYTES :: len(Font_Info_Field)

// ROM font blocks selected through BH.
@(private = "file")
FONT_INFO_BLOCK_IDS := [FONT_INFO_BLOCKS]u8{0x02, 0x03, 0x06}

// One INT 10h AH=11h load-with-recalculate call and the geometry it must leave.
Font_Load_Case :: struct {
	subfunction:      u8,
	rows_minus_one:   u8,
	character_height: u8,
	maximum_scan_line: u8,
}

FONT_LOAD_BASE :: VGABIOS_PROBE_RESULT_BASE + FONT_INFO_BLOCKS * FONT_INFO_RECORD_BYTES
FONT_LOAD_RECORD_BYTES :: 3

// Tail record for the 350 scan line 43-row case.
FONT_43_ROW_BASE :: FONT_LOAD_BASE + len(FONT_LOAD_CASES) * FONT_LOAD_RECORD_BYTES

Font_43_Row_Field :: enum {
	Scan_Line_Status,
	Rows_Minus_One,
	Character_Height,
}

// Mode 03h is a 400 scan line text mode, so the loaded character height
// divides into 50, 28, and 25 rows.
@(private = "file")
FONT_LOAD_CASES := [?]Font_Load_Case {
	{0x12, 49, 8, 7}, // load ROM 8x8 and recalculate
	{0x11, 27, 14, 13}, // load ROM 8x14 and recalculate
	{0x14, 24, 16, 15}, // load ROM 8x16 and recalculate
	{0x12, 49, 8, 7}, // return to 8x8 so the snapshot proof sees 50 rows
}

@(private = "file")
font_services_boot_floppy :: proc() -> ([]u8, bool) {
	code := make([dynamic]u8, 0, 512)
	defer delete(code)

	vgabios_probe_emit_prologue(&code)
	vgabios_probe_emit(&code, 0xB8, 0x03, 0x00) // mov ax, 0003h
	vgabios_probe_emit(&code, 0xCD, 0x10) // int 10h

	// AH=11h AL=30h clobbers ES:BP, which is safe here because every store is
	// DS relative.
	for block, index in FONT_INFO_BLOCK_IDS {
		record := VGABIOS_PROBE_RESULT_BASE + index * FONT_INFO_RECORD_BYTES
		vgabios_probe_emit(&code, 0xB8, 0x30, 0x11) // mov ax, 1130h
		vgabios_probe_emit(&code, 0xB7, block) // mov bh, block
		vgabios_probe_emit(&code, 0xCD, 0x10) // int 10h
		vgabios_probe_emit(&code, 0x88, 0xC8) // mov al, cl
		vgabios_probe_emit_store(&code, record + int(Font_Info_Field.On_Screen_Bytes))
		vgabios_probe_emit(&code, 0x88, 0xD0) // mov al, dl
		vgabios_probe_emit_store(&code, record + int(Font_Info_Field.On_Screen_Rows_Minus_One))
		vgabios_probe_emit(&code, 0x89, 0xE8) // mov ax, bp
		vgabios_probe_emit_store(&code, record + int(Font_Info_Field.Pointer_Low))
		vgabios_probe_emit(&code, 0x88, 0xE0) // mov al, ah
		vgabios_probe_emit_store(&code, record + int(Font_Info_Field.Pointer_High))
	}

	for entry, index in FONT_LOAD_CASES {
		record := FONT_LOAD_BASE + index * FONT_LOAD_RECORD_BYTES
		vgabios_probe_emit(&code, 0xB8, entry.subfunction, 0x11) // mov ax, 11xxh
		vgabios_probe_emit(&code, 0x30, 0xDB) // xor bl, bl
		vgabios_probe_emit(&code, 0xCD, 0x10) // int 10h
		vgabios_probe_emit_load(&code, 0x0484) // BDA rows-1
		vgabios_probe_emit_store(&code, record)
		vgabios_probe_emit_load(&code, 0x0485) // BDA character height
		vgabios_probe_emit_store(&code, record + 1)
		vgabios_probe_emit_read_crtc(&code, 0x09) // maximum scan line
		vgabios_probe_emit_store(&code, record + 2)
	}

	// Select 350 scan lines, re-set mode 03h to apply it, then load the 8x8
	// font so the classic 43-row text geometry appears.
	vgabios_probe_emit(&code, 0xB8, 0x01, 0x12) // mov ax, 1201h
	vgabios_probe_emit(&code, 0xB3, 0x30) // mov bl, 30h
	vgabios_probe_emit(&code, 0xCD, 0x10) // int 10h
	vgabios_probe_emit_store(&code, FONT_43_ROW_BASE + int(Font_43_Row_Field.Scan_Line_Status))
	vgabios_probe_emit(&code, 0xB8, 0x03, 0x00) // mov ax, 0003h
	vgabios_probe_emit(&code, 0xCD, 0x10) // int 10h
	vgabios_probe_emit(&code, 0xB8, 0x12, 0x11) // mov ax, 1112h
	vgabios_probe_emit(&code, 0x30, 0xDB) // xor bl, bl
	vgabios_probe_emit(&code, 0xCD, 0x10) // int 10h
	vgabios_probe_emit_load(&code, 0x0484)
	vgabios_probe_emit_store(&code, FONT_43_ROW_BASE + int(Font_43_Row_Field.Rows_Minus_One))
	vgabios_probe_emit_load(&code, 0x0485)
	vgabios_probe_emit_store(&code, FONT_43_ROW_BASE + int(Font_43_Row_Field.Character_Height))

	vgabios_probe_emit_halt(&code)
	return vgabios_probe_image(code[:])
}

@(test)
test_machine_vgabios_int10_font_services :: proc(t: ^testing.T) {
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

	floppy, built := font_services_boot_floppy()
	if !testing.expect(t, built) {return}
	defer delete(floppy)
	if !vgabios_probe_run(t, m, floppy, 45 * time.Second) {return}

	info := proc(m: ^Machine, block: int, field: Font_Info_Field) -> u8 {
		return m.vm.ram[VGABIOS_PROBE_RESULT_BASE + block * FONT_INFO_RECORD_BYTES + int(field)]
	}
	pointers: [FONT_INFO_BLOCKS]u16
	for block in 0 ..< FONT_INFO_BLOCKS {
		// Mode 03h is still on its 8x16 font, so every query reports the same
		// on-screen geometry regardless of the block requested in BH.
		testing.expect_value(t, info(m, block, .On_Screen_Bytes), u8(16))
		testing.expect_value(t, info(m, block, .On_Screen_Rows_Minus_One), u8(24))
		pointers[block] =
			u16(info(m, block, .Pointer_Low)) | u16(info(m, block, .Pointer_High)) << 8
	}
	// BH must select genuinely different ROM fonts.
	log.infof(
		"AH=11h AL=30h font offsets 8x14=%04X 8x8=%04X 8x16=%04X",
		pointers[0],
		pointers[1],
		pointers[2],
	)
	testing.expect(t, pointers[0] != pointers[1])
	testing.expect(t, pointers[1] != pointers[2])
	testing.expect(t, pointers[0] != pointers[2])

	for entry, index in FONT_LOAD_CASES {
		record := FONT_LOAD_BASE + index * FONT_LOAD_RECORD_BYTES
		rows := m.vm.ram[record]
		height := m.vm.ram[record + 1]
		maximum := m.vm.ram[record + 2] & 0x1F
		if rows != entry.rows_minus_one ||
		   height != entry.character_height ||
		   maximum != entry.maximum_scan_line {
			log.errorf(
				"AH=11h AL=%02Xh expected rows-1=%d height=%d max_scan=%d got rows-1=%d height=%d max_scan=%d",
				entry.subfunction,
				entry.rows_minus_one,
				entry.character_height,
				entry.maximum_scan_line,
				rows,
				height,
				maximum,
			)
		}
		testing.expect_value(t, rows, entry.rows_minus_one)
		testing.expect_value(t, height, entry.character_height)
		testing.expect_value(t, maximum, entry.maximum_scan_line)
	}

	// 350 scan lines with the 8x8 font is the classic 43-row text geometry.
	row43 := proc(m: ^Machine, field: Font_43_Row_Field) -> u8 {
		return m.vm.ram[FONT_43_ROW_BASE + int(field)]
	}
	testing.expect_value(t, row43(m, .Scan_Line_Status), u8(0x12))
	testing.expect_value(t, row43(m, .Rows_Minus_One), u8(42))
	testing.expect_value(t, row43(m, .Character_Height), u8(8))

	// The probe ends in that geometry, so the host visible text snapshot must
	// report the recalculated 80x43 shape rather than the mode default.
	snapshot := machine_text_snapshot(m)
	testing.expect_value(t, video.text_snapshot_columns(&snapshot), 80)
	testing.expect_value(t, video.text_snapshot_rows(&snapshot), 43)
}
