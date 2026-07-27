// SPDX-License-Identifier: GPL-3.0-only
package machine

import hv "../hv"
import video "../vga"
import "core:log"
import "core:testing"
import "core:time"

// 320x200x8 from the pinned Bochs mode table.
@(private = "file")
VBE_FLAGS_MODE :: u16(0x0150)

// Contiguous byte offsets from VGABIOS_PROBE_RESULT_BASE.
@(private = "file")
VBE_F_SET_CLEAR :: 0
@(private = "file")
VBE_F_READ_WRITTEN :: 2
@(private = "file")
VBE_F_SET_AGAIN :: 3
@(private = "file")
VBE_F_READ_CLEARED :: 5
@(private = "file")
VBE_F_SET_PRESERVE :: 6
@(private = "file")
VBE_F_READ_PRESERVED :: 8

@(private = "file")
VBE_FLAGS_PATTERN := [?]u8{0x11, 0x22, 0x33, 0x44}

@(private = "file")
vbe_flags_emit_set_mode :: proc(code: ^[dynamic]u8, mode: u16, destination: int) {
	vgabios_probe_emit(code, 0xB8, 0x02, 0x4F) // mov ax, 4f02h
	vgabios_probe_emit(code, 0xBB, u8(mode & 0xFF), u8(mode >> 8)) // mov bx, mode
	vgabios_probe_emit(code, 0xCD, 0x10) // int 10h
	vgabios_probe_emit(code, 0xA3, u8(destination & 0xFF), u8(destination >> 8)) // mov [imm16], ax
}

// The banked window is at A000h in every mode this probe sets.
@(private = "file")
vbe_flags_emit_write_pattern :: proc(code: ^[dynamic]u8) {
	vgabios_probe_emit(code, 0xB8, 0x00, 0xA0, 0x8E, 0xC0) // mov ax, 0a000h / mov es, ax
	vgabios_probe_emit(code, 0x31, 0xFF) // xor di, di
	for value in VBE_FLAGS_PATTERN {
		vgabios_probe_emit(code, 0xB0, value, 0xAA) // mov al, value / stosb
	}
}

@(private = "file")
vbe_flags_emit_read_first :: proc(code: ^[dynamic]u8, destination: int) {
	vgabios_probe_emit(code, 0xB8, 0x00, 0xA0, 0x8E, 0xC0) // mov ax, 0a000h / mov es, ax
	vgabios_probe_emit(code, 0x26, 0xA0, 0x00, 0x00) // mov al, es:[0000]
	vgabios_probe_emit_store(code, destination)
}

@(private = "file")
vbe_flags_boot_floppy :: proc() -> ([]u8, bool) {
	code := make([dynamic]u8, 0, 512)
	defer delete(code)
	vgabios_probe_emit_prologue(&code)

	vbe_flags_emit_set_mode(&code, VBE_FLAGS_MODE, VGABIOS_PROBE_RESULT_BASE + VBE_F_SET_CLEAR)
	vbe_flags_emit_write_pattern(&code)
	vbe_flags_emit_read_first(&code, VGABIOS_PROBE_RESULT_BASE + VBE_F_READ_WRITTEN)

	// The same mode again without D15 clears display memory.
	vbe_flags_emit_set_mode(&code, VBE_FLAGS_MODE, VGABIOS_PROBE_RESULT_BASE + VBE_F_SET_AGAIN)
	vbe_flags_emit_read_first(&code, VGABIOS_PROBE_RESULT_BASE + VBE_F_READ_CLEARED)

	// With D15 it keeps what is there, which is also how the frame is left for
	// the device-side assertions.
	vbe_flags_emit_write_pattern(&code)
	vbe_flags_emit_set_mode(
		&code,
		VBE_FLAGS_MODE | 0x8000,
		VGABIOS_PROBE_RESULT_BASE + VBE_F_SET_PRESERVE,
	)
	vbe_flags_emit_read_first(&code, VGABIOS_PROBE_RESULT_BASE + VBE_F_READ_PRESERVED)

	vgabios_probe_emit_halt(&code)
	return vgabios_probe_image(code[:])
}

@(private = "file")
vbe_flags_byte :: proc(m: ^Machine, offset: int) -> u8 {
	return m.vm.ram[VGABIOS_PROBE_RESULT_BASE + offset]
}

@(private = "file")
vbe_flags_word :: proc(m: ^Machine, offset: int) -> u16 {
	return u16(vbe_flags_byte(m, offset)) | u16(vbe_flags_byte(m, offset + 1)) << 8
}

// VBE 2.0 4.5 and the pinned Bochs mode table. D15 of the mode number decides
// whether a mode set clears display memory, and 150h is the 320x200x8 banked
// mode whose firmware read/write/render path had no proof.
@(test)
test_machine_vbe_mode_set_clear_and_preserve :: proc(t: ^testing.T) {
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

	floppy, built := vbe_flags_boot_floppy()
	if !testing.expect(t, built) {return}
	defer delete(floppy)
	if !vgabios_probe_run(t, m, floppy, 45 * time.Second) {return}

	testing.expect_value(t, vbe_flags_word(m, VBE_F_SET_CLEAR), u16(0x004F))
	testing.expect_value(t, vbe_flags_word(m, VBE_F_SET_AGAIN), u16(0x004F))
	testing.expect_value(t, vbe_flags_word(m, VBE_F_SET_PRESERVE), u16(0x004F))
	testing.expect_value(t, vbe_flags_byte(m, VBE_F_READ_WRITTEN), VBE_FLAGS_PATTERN[0])
	testing.expect_value(t, vbe_flags_byte(m, VBE_F_READ_CLEARED), u8(0))
	testing.expect_value(t, vbe_flags_byte(m, VBE_F_READ_PRESERVED), VBE_FLAGS_PATTERN[0])

	// The device agrees about the geometry and renders what the guest wrote.
	video.vga_sync_to(&m.vga, m.vga.timing.elapsed_ns + 2 * video.VBE_FRAME_PERIOD_NS)
	frame := video.vga_display_frame(&m.vga)
	testing.expect_value(t, frame.kind, video.Display_Kind.Indexed_8)
	testing.expect_value(t, frame.width, 320)
	testing.expect_value(t, frame.height, 200)
	if !testing.expect(t, len(frame.pixels) >= 320 * 200) {return}
	testing.expect(t, frame.pixels[0] != frame.pixels[1])
	testing.expect(t, frame.pixels[1] != frame.pixels[2])
	testing.expect(t, frame.pixels[2] != frame.pixels[3])
	testing.expect(t, frame.pixels[3] != frame.pixels[4])
}

// Result slots for the linear framebuffer probe.
@(private = "file")
VBE_L_SET_150 :: 0
@(private = "file")
VBE_L_SET_151 :: 2
@(private = "file")
VBE_L_INFO :: 4
@(private = "file")
VBE_L_INFO_BLOCK :: 0x0700

@(private = "file")
vbe_lfb_boot_floppy :: proc() -> ([]u8, bool) {
	code := make([dynamic]u8, 0, 512)
	defer delete(code)
	vgabios_probe_emit_prologue(&code)

	// D14 asks for the linear framebuffer.
	vbe_flags_emit_set_mode(&code, 0x4150, VGABIOS_PROBE_RESULT_BASE + VBE_L_SET_150)
	vbe_flags_emit_set_mode(&code, 0x4151, VGABIOS_PROBE_RESULT_BASE + VBE_L_SET_151)

	vgabios_probe_emit(&code, 0xB8, 0x01, 0x4F) // mov ax, 4f01h
	vgabios_probe_emit(&code, 0xB9, 0x51, 0x41) // mov cx, 4151h
	vgabios_probe_emit(&code, 0xBF, u8(VBE_L_INFO_BLOCK & 0xFF), u8(VBE_L_INFO_BLOCK >> 8))
	vgabios_probe_emit(&code, 0xCD, 0x10)
	vgabios_probe_emit(
		&code,
		0xA3,
		u8((VGABIOS_PROBE_RESULT_BASE + VBE_L_INFO) & 0xFF),
		u8((VGABIOS_PROBE_RESULT_BASE + VBE_L_INFO) >> 8),
	)

	vgabios_probe_emit_halt(&code)
	return vgabios_probe_image(code[:])
}

// VBE 2.0 4.5 and the pinned mode table. Both 320-wide modes have to come up
// with the linear framebuffer at the address the ModeInfoBlock advertises, which
// is the one address the legacy alias and the GSW-VGA BAR share.
@(test)
test_machine_vbe_linear_framebuffer_modes :: proc(t: ^testing.T) {
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

	floppy, built := vbe_lfb_boot_floppy()
	if !testing.expect(t, built) {return}
	defer delete(floppy)
	if !vgabios_probe_run(t, m, floppy, 45 * time.Second) {return}

	testing.expect_value(t, vbe_flags_word(m, VBE_L_SET_150), u16(0x004F))
	testing.expect_value(t, vbe_flags_word(m, VBE_L_SET_151), u16(0x004F))
	testing.expect_value(t, vbe_flags_word(m, VBE_L_INFO), u16(0x004F))

	// PhysBasePtr sits at offset 28h of the ModeInfoBlock.
	base: u64
	for index in 0 ..< 4 {
		base |= u64(m.vm.ram[VBE_L_INFO_BLOCK + 0x28 + index]) << uint(index * 8)
	}
	log.infof(
		"VBE PhysBasePtr %08X, framebuffer BAR %08X",
		base,
		video.vga_framebuffer_base(&m.vga),
	)
	testing.expect_value(t, base, video.VBE_LFB_BASE)
	testing.expect(t, video.vga_vbe_lfb_enabled(&m.vga))

	// A real-mode probe cannot reach a 32-bit address, so the write side is
	// driven through the framebuffer the way a protected-mode driver reaches it:
	// at the BAR the system firmware programmed, which is where the aperture
	// decodes once it has moved off its power-on alias.
	aperture := video.vga_framebuffer_base(&m.vga)
	for index in 0 ..< 4 {
		testing.expect(
			t,
			video.vga_mmio_write(&m.vga, aperture + u64(index), 1, u32(0x21 + index * 0x30)),
		)
	}
	video.vga_sync_to(&m.vga, m.vga.timing.elapsed_ns + 2 * video.VBE_FRAME_PERIOD_NS)
	frame := video.vga_display_frame(&m.vga)
	testing.expect_value(t, frame.kind, video.Display_Kind.Indexed_8)
	testing.expect_value(t, frame.width, 320)
	testing.expect_value(t, frame.height, 240)
	if !testing.expect(t, len(frame.pixels) >= 4) {return}
	testing.expect(t, frame.pixels[0] != frame.pixels[1])
	testing.expect(t, frame.pixels[1] != frame.pixels[2])
	testing.expect(t, frame.pixels[2] != frame.pixels[3])
}
