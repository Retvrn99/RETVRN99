// SPDX-License-Identifier: GPL-3.0-only
package machine

import hv "../hv"
import "core:log"
import "core:testing"
import "core:time"

// 800x600 in sixteen colours. Four bits per pixel is the only depth in the
// pinned table where a scan line length in pixels cannot always be honoured
// exactly, because eight pixels share a byte.
@(private = "file")
VBE_ROUND_MODE :: u16(0x0102)
// Not a multiple of eight, so the byte pitch has to round up and the pixel
// count the firmware reports back has to grow with it.
@(private = "file")
VBE_ROUND_REQUEST :: u16(1281)

@(private = "file")
VBE_R_SET_MODE :: 0
@(private = "file")
VBE_R_SET :: 2
@(private = "file")
VBE_R_GET :: 10

@(private = "file")
vbe_round_store :: proc(code: ^[dynamic]u8, offset: int) {
	for modrm, index in ([?]u8{0x06, 0x1E, 0x0E, 0x16}) {
		address := VGABIOS_PROBE_RESULT_BASE + offset + index * 2
		vgabios_probe_emit(code, 0x89, modrm, u8(address & 0xFF), u8(address >> 8))
	}
}

@(private = "file")
vbe_round_boot_floppy :: proc() -> ([]u8, bool) {
	code := make([dynamic]u8, 0, 512)
	defer delete(code)
	vgabios_probe_emit_prologue(&code)

	vgabios_probe_emit(&code, 0xB8, 0x02, 0x4F)
	vgabios_probe_emit(&code, 0xBB, u8(VBE_ROUND_MODE & 0xFF), u8(VBE_ROUND_MODE >> 8))
	vgabios_probe_emit(&code, 0xCD, 0x10)
	vbe_round_store(&code, VBE_R_SET_MODE)

	vgabios_probe_emit(&code, 0xB8, 0x06, 0x4F) // mov ax, 4f06h
	vgabios_probe_emit(&code, 0xBB, 0x00, 0x00) // mov bx, 0000h, set in pixels
	vgabios_probe_emit(&code, 0xB9, u8(VBE_ROUND_REQUEST & 0xFF), u8(VBE_ROUND_REQUEST >> 8))
	vgabios_probe_emit(&code, 0xCD, 0x10)
	vbe_round_store(&code, VBE_R_SET)

	vgabios_probe_emit(&code, 0xB8, 0x06, 0x4F)
	vgabios_probe_emit(&code, 0xBB, 0x01, 0x00) // mov bx, 0001h, get
	vgabios_probe_emit(&code, 0xCD, 0x10)
	vbe_round_store(&code, VBE_R_GET)

	vgabios_probe_emit_halt(&code)
	return vgabios_probe_image(code[:])
}

@(private = "file")
vbe_round_word :: proc(m: ^Machine, offset, register: int) -> u16 {
	base := VGABIOS_PROBE_RESULT_BASE + offset + register * 2
	return u16(m.vm.ram[base]) | u16(m.vm.ram[base + 1]) << 8
}

// VBE 2.0 4.9. A scan line length is requested in pixels and answered in both,
// and the answer is the achievable length rather than the requested one.
@(test)
test_machine_vbe_scanline_length_rounds_up_to_an_achievable_width :: proc(t: ^testing.T) {
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

	floppy, built := vbe_round_boot_floppy()
	if !testing.expect(t, built) {return}
	defer delete(floppy)
	if !vgabios_probe_run(t, m, floppy, 45 * time.Second) {return}

	testing.expect_value(t, vbe_round_word(m, VBE_R_SET_MODE, 0), u16(0x004F))
	set_ax := vbe_round_word(m, VBE_R_SET, 0)
	set_bytes := vbe_round_word(m, VBE_R_SET, 1)
	set_pixels := vbe_round_word(m, VBE_R_SET, 2)
	set_lines := vbe_round_word(m, VBE_R_SET, 3)
	log.infof(
		"4F06h set ax=%04X bytes=%d pixels=%d lines=%d",
		set_ax,
		set_bytes,
		set_pixels,
		set_lines,
	)
	testing.expect_value(t, set_ax, u16(0x004F))
	// 1281 pixels is 160.125 bytes, so the byte pitch rounds up and the pixel
	// count grows to match it.
	testing.expect_value(t, set_bytes, u16(161))
	testing.expect_value(t, set_pixels, u16(1288))
	testing.expect(t, set_lines > 0)

	// A later get answers with the achievable length, not the request.
	testing.expect_value(t, vbe_round_word(m, VBE_R_GET, 0), u16(0x004F))
	testing.expect_value(t, vbe_round_word(m, VBE_R_GET, 1), set_bytes)
	testing.expect_value(t, vbe_round_word(m, VBE_R_GET, 2), set_pixels)
	testing.expect_value(t, vbe_round_word(m, VBE_R_GET, 3), set_lines)
}
