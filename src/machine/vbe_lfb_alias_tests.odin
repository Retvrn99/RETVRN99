// SPDX-License-Identifier: GPL-3.0-only
package machine

import hv "../hv"
import video "../vga"
import "core:log"
import "core:testing"
import "core:time"

// Result slots for the legacy linear-framebuffer alias probe.
@(private = "file")
LFB_ALIAS_SET_151 :: 0
@(private = "file")
LFB_ALIAS_READ_FIRST :: 2
@(private = "file")
LFB_ALIAS_READ_LAST :: 3

@(private = "file")
LFB_ALIAS_PATTERN := [?]u8{0x21, 0x51, 0x81, 0xB1}

// Scratch addresses for the descriptor table the probe builds.
@(private = "file")
LFB_ALIAS_GDT :: 0x0600
@(private = "file")
LFB_ALIAS_GDTR :: 0x0618

@(private = "file")
lfb_alias_emit_byte_store :: proc(code: ^[dynamic]u8, address: int, value: u8) {
	vgabios_probe_emit(code, 0xC6, 0x06, u8(address & 0xFF), u8(address >> 8), value)
}

// Loads a flat 4 GiB data limit into ES and returns to real mode with the
// cached descriptor still in force, which is what lets a real-mode probe reach
// the aperture above 1 MiB.
@(private = "file")
lfb_alias_emit_unreal_es :: proc(code: ^[dynamic]u8) {
	descriptor := [?]u8{0xFF, 0xFF, 0x00, 0x00, 0x00, 0x92, 0xCF, 0x00}
	for index in 0 ..< 8 {
		lfb_alias_emit_byte_store(code, LFB_ALIAS_GDT + index, 0)
	}
	for value, index in descriptor {
		lfb_alias_emit_byte_store(code, LFB_ALIAS_GDT + 8 + index, value)
	}
	lfb_alias_emit_byte_store(code, LFB_ALIAS_GDTR, 0x0F)
	lfb_alias_emit_byte_store(code, LFB_ALIAS_GDTR + 1, 0x00)
	lfb_alias_emit_byte_store(code, LFB_ALIAS_GDTR + 2, u8(LFB_ALIAS_GDT & 0xFF))
	lfb_alias_emit_byte_store(code, LFB_ALIAS_GDTR + 3, u8(LFB_ALIAS_GDT >> 8))
	lfb_alias_emit_byte_store(code, LFB_ALIAS_GDTR + 4, 0x00)
	lfb_alias_emit_byte_store(code, LFB_ALIAS_GDTR + 5, 0x00)

	vgabios_probe_emit(code, 0xFA) // cli
	vgabios_probe_emit(code, 0x0F, 0x01, 0x16, u8(LFB_ALIAS_GDTR & 0xFF), u8(LFB_ALIAS_GDTR >> 8)) // lgdt
	vgabios_probe_emit(code, 0x0F, 0x20, 0xC0) // mov eax, cr0
	vgabios_probe_emit(code, 0x0C, 0x01) // or al, 1
	vgabios_probe_emit(code, 0x0F, 0x22, 0xC0) // mov cr0, eax
	vgabios_probe_emit(code, 0xEB, 0x00) // jmp short $+2
	vgabios_probe_emit(code, 0xBB, 0x08, 0x00) // mov bx, 0008h
	vgabios_probe_emit(code, 0x8E, 0xC3) // mov es, bx
	vgabios_probe_emit(code, 0x24, 0xFE) // and al, 0feh
	vgabios_probe_emit(code, 0x0F, 0x22, 0xC0) // mov cr0, eax
	vgabios_probe_emit(code, 0xEB, 0x00) // jmp short $+2
	vgabios_probe_emit(code, 0x31, 0xDB) // xor bx, bx
	vgabios_probe_emit(code, 0x8E, 0xC3) // mov es, bx
}

@(private = "file")
lfb_alias_emit_load_edi :: proc(code: ^[dynamic]u8, address: u32) {
	vgabios_probe_emit(
		code,
		0x66,
		0xBF,
		u8(address & 0xFF),
		u8(address >> 8 & 0xFF),
		u8(address >> 16 & 0xFF),
		u8(address >> 24),
	)
}

@(private = "file")
lfb_alias_boot_floppy :: proc() -> ([]u8, bool) {
	code := make([dynamic]u8, 0, 512)
	defer delete(code)
	vgabios_probe_emit_prologue(&code)

	// D14 asks for the linear framebuffer at the advertised PhysBasePtr.
	vgabios_probe_emit(&code, 0xB8, 0x02, 0x4F) // mov ax, 4f02h
	vgabios_probe_emit(&code, 0xBB, 0x51, 0x41) // mov bx, 4151h
	vgabios_probe_emit(&code, 0xCD, 0x10) // int 10h
	vgabios_probe_emit(
		&code,
		0xA3,
		u8((VGABIOS_PROBE_RESULT_BASE + LFB_ALIAS_SET_151) & 0xFF),
		u8((VGABIOS_PROBE_RESULT_BASE + LFB_ALIAS_SET_151) >> 8),
	)

	lfb_alias_emit_unreal_es(&code)
	vgabios_probe_emit(&code, 0xFC) // cld
	lfb_alias_emit_load_edi(&code, u32(video.VBE_LFB_BASE))
	for value in LFB_ALIAS_PATTERN {
		vgabios_probe_emit(&code, 0xB0, value) // mov al, value
		vgabios_probe_emit(&code, 0x67, 0xAA) // a32 stosb
	}
	lfb_alias_emit_load_edi(&code, u32(video.VBE_LFB_BASE))
	vgabios_probe_emit(&code, 0x67, 0x26, 0x8A, 0x07) // a32 mov al, es:[edi]
	vgabios_probe_emit_store(&code, VGABIOS_PROBE_RESULT_BASE + LFB_ALIAS_READ_FIRST)
	lfb_alias_emit_load_edi(&code, u32(video.VBE_LFB_BASE) + u32(len(LFB_ALIAS_PATTERN)) - 1)
	vgabios_probe_emit(&code, 0x67, 0x26, 0x8A, 0x07) // a32 mov al, es:[edi]
	vgabios_probe_emit_store(&code, VGABIOS_PROBE_RESULT_BASE + LFB_ALIAS_READ_LAST)

	vgabios_probe_emit_halt(&code)
	return vgabios_probe_image(code[:])
}

// VBE 2.0 4.5 and the pinned mode table. The guest writes through the
// E0000000 the ModeInfoBlock advertises while the system firmware has the
// framebuffer BAR elsewhere, and the device must decode and render it: the
// fixed legacy aperture is an alias of the BAR, not its power-on address.
@(test)
test_machine_vbe_lfb_alias_decodes_after_bar_move :: proc(t: ^testing.T) {
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

	floppy, built := lfb_alias_boot_floppy()
	if !testing.expect(t, built) {return}
	defer delete(floppy)
	if !vgabios_probe_run(t, m, floppy, 45 * time.Second) {return}

	testing.expect_value(t, vbe_result_word(m, LFB_ALIAS_SET_151), u16(0x004F))

	// The contested state: the BAR has moved off the legacy aperture.
	aperture := video.vga_framebuffer_base(&m.vga)
	log.infof("framebuffer BAR %08X, legacy alias %08X", aperture, video.VBE_LFB_BASE)
	testing.expect(t, aperture != 0)
	testing.expect(t, aperture != video.VBE_LFB_BASE)

	alias_mapped := false
	for alias in m.vm.device_aliases {
		if alias.gpa == video.VBE_LFB_BASE && alias.size == u64(video.VRAM_SIZE) {
			alias_mapped = alias.mapped
		}
	}
	testing.expect(t, alias_mapped)

	// The guest read its own bytes back through the alias.
	testing.expect_value(t, vbe_result_byte(m, LFB_ALIAS_READ_FIRST), LFB_ALIAS_PATTERN[0])
	testing.expect_value(
		t,
		vbe_result_byte(m, LFB_ALIAS_READ_LAST),
		LFB_ALIAS_PATTERN[len(LFB_ALIAS_PATTERN) - 1],
	)

	// The writes landed in the framebuffer and the device renders them.
	backing := video.vga_vram(&m.vga)
	for value, index in LFB_ALIAS_PATTERN {
		testing.expect_value(t, backing[index], value)
	}
	frame := machine_display_frame(m)
	testing.expect_value(t, frame.kind, video.Display_Kind.Indexed_8)
	testing.expect_value(t, frame.width, 320)
	testing.expect_value(t, frame.height, 240)
	if !testing.expect(t, len(frame.pixels) >= 4) {return}
	testing.expect(t, frame.pixels[0] != frame.pixels[1])
	testing.expect(t, frame.pixels[1] != frame.pixels[2])
	testing.expect(t, frame.pixels[2] != frame.pixels[3])
}

@(private = "file")
vbe_result_word :: proc(m: ^Machine, offset: int) -> u16 {
	base := VGABIOS_PROBE_RESULT_BASE + offset
	return u16(m.vm.ram[base]) | u16(m.vm.ram[base + 1]) << 8
}

@(private = "file")
vbe_result_byte :: proc(m: ^Machine, offset: int) -> u8 {
	return m.vm.ram[VGABIOS_PROBE_RESULT_BASE + offset]
}
