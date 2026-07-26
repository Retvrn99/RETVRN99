// SPDX-License-Identifier: GPL-3.0-only
package machine

import hv "../hv"
import "core:log"
import "core:testing"
import "core:time"

// Banked 640x480x8 is the working mode for window and display control.
VBE_WINDOW_MODE :: 0x0101
VBE_WINDOW_WIDTH :: 640
VBE_WINDOW_HEIGHT :: 480
VBE_WIDENED_PIXELS :: 800
VBE_START_PIXEL :: 8
VBE_START_SCANLINE :: 16
VBE_WINDOW_POSITION :: 3

// Contiguous byte offsets from VGABIOS_PROBE_RESULT_BASE. A status record is
// AL then AH; a triple record adds BX, CX, and DX as little-endian words.
VBE_W_MODE :: 0
VBE_W_SCANLINE_GET :: 2
VBE_W_SCANLINE_SET :: 10
VBE_W_SCANLINE_REGET :: 18
VBE_W_START_SET :: 26
VBE_W_START_GET :: 28
VBE_W_WINDOW_SET :: 34
VBE_W_WINDOW_GET :: 36
VBE_W_SCANLINE_ODD :: 40
VBE_W_BOUNDS_SET :: 48
VBE_W_BOUNDS_GET :: 50

// Not a multiple of the mode width. At 8 bits per pixel every byte pitch is
// addressable, so this must be honoured exactly rather than rounded.
VBE_ODD_PIXELS :: 641
// Far beyond the addressable scan lines at any supported pitch.
VBE_OUT_OF_RANGE_SCANLINE :: 65000

// Stores AL then AH of the current result.
@(private = "file")
vbe_window_emit_status :: proc(code: ^[dynamic]u8, destination: int) {
	vgabios_probe_emit_store(code, destination)
	vgabios_probe_emit(code, 0x88, 0xE0) // mov al, ah
	vgabios_probe_emit_store(code, destination + 1)
}

// Copies a 16-bit register into AX and stores it little endian.
@(private = "file")
vbe_window_emit_word :: proc(code: ^[dynamic]u8, modrm: u8, destination: int) {
	vgabios_probe_emit(code, 0x89, modrm) // mov ax, reg
	vgabios_probe_emit_store(code, destination)
	vgabios_probe_emit(code, 0x88, 0xE0) // mov al, ah
	vgabios_probe_emit_store(code, destination + 1)
}

VBE_FROM_BX :: 0xD8
VBE_FROM_CX :: 0xC8
VBE_FROM_DX :: 0xD0

// Stores AL, AH, then the BX, CX, DX triple that 4F06h returns.
@(private = "file")
vbe_window_emit_triple :: proc(code: ^[dynamic]u8, destination: int) {
	vbe_window_emit_status(code, destination)
	vbe_window_emit_word(code, VBE_FROM_BX, destination + 2)
	vbe_window_emit_word(code, VBE_FROM_CX, destination + 4)
	vbe_window_emit_word(code, VBE_FROM_DX, destination + 6)
}

@(private = "file")
vbe_window_boot_floppy :: proc() -> ([]u8, bool) {
	code := make([dynamic]u8, 0, 512)
	defer delete(code)
	base := VGABIOS_PROBE_RESULT_BASE

	vgabios_probe_emit_prologue(&code)

	// Banked 101h so window control is meaningful.
	vgabios_probe_emit(&code, 0xBB, u8(VBE_WINDOW_MODE & 0xFF), u8(VBE_WINDOW_MODE >> 8)) // mov bx, mode
	vgabios_probe_emit(&code, 0xB8, 0x02, 0x4F) // mov ax, 4f02h
	vgabios_probe_emit(&code, 0xCD, 0x10) // int 10h
	vbe_window_emit_status(&code, base + VBE_W_MODE)

	// 4F06h BL=01h get current logical scan line length.
	vgabios_probe_emit(&code, 0xB8, 0x06, 0x4F) // mov ax, 4f06h
	vgabios_probe_emit(&code, 0xB3, 0x01) // mov bl, 1
	vgabios_probe_emit(&code, 0xCD, 0x10) // int 10h
	vbe_window_emit_triple(&code, base + VBE_W_SCANLINE_GET)

	// 4F06h BL=00h set the length in pixels.
	vgabios_probe_emit(&code, 0xB8, 0x06, 0x4F) // mov ax, 4f06h
	vgabios_probe_emit(&code, 0xB3, 0x00) // mov bl, 0
	vgabios_probe_emit(&code, 0xB9, u8(VBE_WIDENED_PIXELS & 0xFF), u8(VBE_WIDENED_PIXELS >> 8)) // mov cx, pixels
	vgabios_probe_emit(&code, 0xCD, 0x10) // int 10h
	vbe_window_emit_triple(&code, base + VBE_W_SCANLINE_SET)

	// Re-get so the change is proven to persist.
	vgabios_probe_emit(&code, 0xB8, 0x06, 0x4F) // mov ax, 4f06h
	vgabios_probe_emit(&code, 0xB3, 0x01) // mov bl, 1
	vgabios_probe_emit(&code, 0xCD, 0x10) // int 10h
	vbe_window_emit_triple(&code, base + VBE_W_SCANLINE_REGET)

	// 4F07h BL=00h set display start, then BL=01h read it back.
	vgabios_probe_emit(&code, 0xB8, 0x07, 0x4F) // mov ax, 4f07h
	vgabios_probe_emit(&code, 0xBB, 0x00, 0x00) // mov bx, 0
	vgabios_probe_emit(&code, 0xB9, u8(VBE_START_PIXEL & 0xFF), u8(VBE_START_PIXEL >> 8)) // mov cx, pixel
	vgabios_probe_emit(&code, 0xBA, u8(VBE_START_SCANLINE & 0xFF), u8(VBE_START_SCANLINE >> 8)) // mov dx, scanline
	vgabios_probe_emit(&code, 0xCD, 0x10) // int 10h
	vbe_window_emit_status(&code, base + VBE_W_START_SET)

	vgabios_probe_emit(&code, 0xB8, 0x07, 0x4F) // mov ax, 4f07h
	vgabios_probe_emit(&code, 0xBB, 0x01, 0x00) // mov bx, 1
	vgabios_probe_emit(&code, 0xCD, 0x10) // int 10h
	vbe_window_emit_status(&code, base + VBE_W_START_GET)
	vbe_window_emit_word(&code, VBE_FROM_CX, base + VBE_W_START_GET + 2)
	vbe_window_emit_word(&code, VBE_FROM_DX, base + VBE_W_START_GET + 4)

	// 4F05h BH=00h set window A, then BH=01h read it back.
	vgabios_probe_emit(&code, 0xB8, 0x05, 0x4F) // mov ax, 4f05h
	vgabios_probe_emit(&code, 0xBB, 0x00, 0x00) // mov bx, 0 (set, window A)
	vgabios_probe_emit(&code, 0xBA, u8(VBE_WINDOW_POSITION & 0xFF), u8(VBE_WINDOW_POSITION >> 8)) // mov dx, position
	vgabios_probe_emit(&code, 0xCD, 0x10) // int 10h
	vbe_window_emit_status(&code, base + VBE_W_WINDOW_SET)

	vgabios_probe_emit(&code, 0xB8, 0x05, 0x4F) // mov ax, 4f05h
	vgabios_probe_emit(&code, 0xBB, 0x00, 0x01) // mov bx, 0100h (get, window A)
	vgabios_probe_emit(&code, 0xCD, 0x10) // int 10h
	vbe_window_emit_status(&code, base + VBE_W_WINDOW_GET)
	vbe_window_emit_word(&code, VBE_FROM_DX, base + VBE_W_WINDOW_GET + 2)

	// A logical width that is not a multiple of the mode width.
	vgabios_probe_emit(&code, 0xB8, 0x06, 0x4F) // mov ax, 4f06h
	vgabios_probe_emit(&code, 0xB3, 0x00) // mov bl, 0
	vgabios_probe_emit(
		&code,
		0xB9,
		u8(VBE_ODD_PIXELS & 0xFF),
		u8(VBE_ODD_PIXELS >> 8),
	) // mov cx, 641
	vgabios_probe_emit(&code, 0xCD, 0x10) // int 10h
	vbe_window_emit_triple(&code, base + VBE_W_SCANLINE_ODD)

	// An out-of-range start must never leave the display pointing outside the
	// addressable area.
	vgabios_probe_emit(&code, 0xB8, 0x07, 0x4F) // mov ax, 4f07h
	vgabios_probe_emit(&code, 0xBB, 0x00, 0x00) // mov bx, 0
	vgabios_probe_emit(&code, 0xB9, 0x00, 0x00) // mov cx, 0
	vgabios_probe_emit(
		&code,
		0xBA,
		u8(VBE_OUT_OF_RANGE_SCANLINE & 0xFF),
		u8(VBE_OUT_OF_RANGE_SCANLINE >> 8),
	) // mov dx, out of range
	vgabios_probe_emit(&code, 0xCD, 0x10) // int 10h
	vbe_window_emit_status(&code, base + VBE_W_BOUNDS_SET)

	vgabios_probe_emit(&code, 0xB8, 0x07, 0x4F) // mov ax, 4f07h
	vgabios_probe_emit(&code, 0xBB, 0x01, 0x00) // mov bx, 1
	vgabios_probe_emit(&code, 0xCD, 0x10) // int 10h
	vbe_window_emit_status(&code, base + VBE_W_BOUNDS_GET)
	vbe_window_emit_word(&code, VBE_FROM_CX, base + VBE_W_BOUNDS_GET + 2)
	vbe_window_emit_word(&code, VBE_FROM_DX, base + VBE_W_BOUNDS_GET + 4)

	vgabios_probe_emit_halt(&code)
	return vgabios_probe_image(code[:])
}

@(private = "file")
vbe_window_word :: proc(m: ^Machine, offset: int) -> u16 {
	address := VGABIOS_PROBE_RESULT_BASE + offset
	return u16(m.vm.ram[address]) | u16(m.vm.ram[address + 1]) << 8
}

// Requires AL=4Fh and AH=00h at the given record.
@(private = "file")
vbe_window_expect_ok :: proc(t: ^testing.T, m: ^Machine, offset: int, what: string) {
	al := m.vm.ram[VGABIOS_PROBE_RESULT_BASE + offset]
	ah := m.vm.ram[VGABIOS_PROBE_RESULT_BASE + offset + 1]
	if al != 0x4F || ah != 0x00 {
		log.errorf("%s returned AL=%02X AH=%02X", what, al, ah)
	}
	testing.expect_value(t, al, u8(0x4F))
	testing.expect_value(t, ah, u8(0x00))
}

@(test)
test_machine_vbe_window_scanline_and_display_start :: proc(t: ^testing.T) {
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

	floppy, built := vbe_window_boot_floppy()
	if !testing.expect(t, built) {return}
	defer delete(floppy)
	if !vgabios_probe_run(t, m, floppy, 45 * time.Second) {return}

	vbe_window_expect_ok(t, m, VBE_W_MODE, "4F02h banked set")

	// 4F06h reports bytes per scan line in BX, pixels in CX, and the number of
	// addressable scan lines in DX.
	vbe_window_expect_ok(t, m, VBE_W_SCANLINE_GET, "4F06h get")
	testing.expect_value(t, vbe_window_word(m, VBE_W_SCANLINE_GET + 2), u16(VBE_WINDOW_WIDTH))
	testing.expect_value(t, vbe_window_word(m, VBE_W_SCANLINE_GET + 4), u16(VBE_WINDOW_WIDTH))
	testing.expect(t, vbe_window_word(m, VBE_W_SCANLINE_GET + 6) >= VBE_WINDOW_HEIGHT)

	vbe_window_expect_ok(t, m, VBE_W_SCANLINE_SET, "4F06h set")
	testing.expect_value(t, vbe_window_word(m, VBE_W_SCANLINE_SET + 2), u16(VBE_WIDENED_PIXELS))
	testing.expect_value(t, vbe_window_word(m, VBE_W_SCANLINE_SET + 4), u16(VBE_WIDENED_PIXELS))

	// The widened length must persist across a later query.
	vbe_window_expect_ok(t, m, VBE_W_SCANLINE_REGET, "4F06h re-get")
	testing.expect_value(t, vbe_window_word(m, VBE_W_SCANLINE_REGET + 2), u16(VBE_WIDENED_PIXELS))
	testing.expect_value(t, vbe_window_word(m, VBE_W_SCANLINE_REGET + 4), u16(VBE_WIDENED_PIXELS))
	// A wider logical line must reduce the addressable scan line count.
	testing.expect(
		t,
		vbe_window_word(m, VBE_W_SCANLINE_REGET + 6) <
		vbe_window_word(m, VBE_W_SCANLINE_GET + 6),
	)

	// 4F07h display start must round trip exactly.
	vbe_window_expect_ok(t, m, VBE_W_START_SET, "4F07h set")
	vbe_window_expect_ok(t, m, VBE_W_START_GET, "4F07h get")
	testing.expect_value(t, vbe_window_word(m, VBE_W_START_GET + 2), u16(VBE_START_PIXEL))
	testing.expect_value(t, vbe_window_word(m, VBE_W_START_GET + 4), u16(VBE_START_SCANLINE))

	// 4F05h window position must round trip exactly.
	vbe_window_expect_ok(t, m, VBE_W_WINDOW_SET, "4F05h set")
	vbe_window_expect_ok(t, m, VBE_W_WINDOW_GET, "4F05h get")
	testing.expect_value(t, vbe_window_word(m, VBE_W_WINDOW_GET + 2), u16(VBE_WINDOW_POSITION))

	// A width that is not a multiple of the mode width must still be honoured
	// exactly at 8 bits per pixel, where any byte pitch is addressable, and the
	// reported byte pitch must track it.
	vbe_window_expect_ok(t, m, VBE_W_SCANLINE_ODD, "4F06h odd width")
	odd_pixels := vbe_window_word(m, VBE_W_SCANLINE_ODD + 4)
	odd_bytes := vbe_window_word(m, VBE_W_SCANLINE_ODD + 2)
	testing.expect_value(t, odd_pixels, u16(VBE_ODD_PIXELS))
	testing.expect_value(t, odd_bytes, u16(VBE_ODD_PIXELS))

	// The out-of-range request must be rejected or clamped; either way the
	// resulting start must stay inside the addressable scan lines.
	addressable := vbe_window_word(m, VBE_W_SCANLINE_ODD + 6)
	resulting := vbe_window_word(m, VBE_W_BOUNDS_GET + 4)
	log.infof(
		"4F07h out-of-range request left scan line %d with %d addressable",
		resulting,
		addressable,
	)
	testing.expect(t, resulting < addressable)
	testing.expect(t, resulting != VBE_OUT_OF_RANGE_SCANLINE)
}
