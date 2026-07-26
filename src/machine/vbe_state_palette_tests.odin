// SPDX-License-Identifier: GPL-3.0-only
package machine

import hv "../hv"
import "core:log"
import "core:testing"
import "core:time"

VBE_STATE_MODE :: 0x0101
VBE_STATE_BUFFER_SEGMENT :: 0x2000
VBE_STATE_COMPONENTS :: 0x0007

// Guest scratch for the 4F09h palette tables.
VBE_PALETTE_SOURCE :: 0x0A00
VBE_PALETTE_READBACK :: 0x0B00
VBE_PALETTE_RESTORED :: 0x0C00
VBE_PALETTE_RETRACE :: 0x0D00
VBE_PALETTE_FIRST :: 16
VBE_PALETTE_COUNT :: 2

// Two entries in 4F09h order: blue, green, red, alignment. Values stay inside
// the six-bit DAC range.
VBE_PALETTE_BYTES := [8]u8{0x11, 0x22, 0x33, 0x00, 0x04, 0x15, 0x26, 0x00}

// A second, distinct pair written through the BL=80h retrace request.
VBE_PALETTE_RETRACE_BYTES := [8]u8{0x2A, 0x1F, 0x05, 0x00, 0x3F, 0x00, 0x11, 0x00}

VBE_DAC_STANDARD_BITS :: 6
VBE_DAC_WIDE_BITS :: 8

Vbe_State_Field :: enum {
	Dac_Get_Al,
	Dac_Get_Ah,
	Dac_Get_Bh,
	Dac_Wide_Al,
	Dac_Wide_Ah,
	Dac_Wide_Bh,
	Dac_Wide_Readback_Bh,
	Dac_Restore_Al,
	Dac_Restore_Ah,
	Dac_Restore_Readback_Bh,
	Palette_Set_Al,
	Palette_Set_Ah,
	Palette_Get_Al,
	Palette_Get_Ah,
	Size_Al,
	Size_Ah,
	Size_Blocks_Low,
	Size_Blocks_High,
	Save_Al,
	Save_Ah,
	Restore_Al,
	Restore_Ah,
	Palette_Reget_Al,
	Palette_Reget_Ah,
	Palette_Retrace_Al,
	Palette_Retrace_Ah,
	Palette_Retrace_Get_Al,
	Palette_Retrace_Get_Ah,
}

@(private = "file")
vbe_state_at :: proc(field: Vbe_State_Field) -> int {
	return VGABIOS_PROBE_RESULT_BASE + int(field)
}

// Stores AL then AH of the current result.
@(private = "file")
vbe_state_emit_status :: proc(code: ^[dynamic]u8, low, high: Vbe_State_Field) {
	vgabios_probe_emit_store(code, vbe_state_at(low))
	vgabios_probe_emit(code, 0x88, 0xE0) // mov al, ah
	vgabios_probe_emit_store(code, vbe_state_at(high))
}

// mov word [address], value
@(private = "file")
vbe_state_emit_word :: proc(code: ^[dynamic]u8, address: int, value: u16) {
	vgabios_probe_emit(
		code,
		0xC7,
		0x06,
		u8(address & 0xFF),
		u8(address >> 8),
		u8(value & 0xFF),
		u8(value >> 8),
	)
}

// AX=4F09h with BL, CX entries from DX, table at ES:DI.
@(private = "file")
vbe_state_emit_palette :: proc(code: ^[dynamic]u8, subfunction: u8, table: int) {
	vgabios_probe_emit(code, 0xB8, 0x09, 0x4F) // mov ax, 4f09h
	vgabios_probe_emit(code, 0xB3, subfunction) // mov bl, subfunction
	vgabios_probe_emit(code, 0xB9, VBE_PALETTE_COUNT, 0x00) // mov cx, count
	vgabios_probe_emit(code, 0xBA, VBE_PALETTE_FIRST, 0x00) // mov dx, first
	vgabios_probe_emit(code, 0xBF, u8(table & 0xFF), u8(table >> 8)) // mov di, table
	vgabios_probe_emit(code, 0xCD, 0x10) // int 10h
}

@(private = "file")
vbe_state_boot_floppy :: proc() -> ([]u8, bool) {
	code := make([dynamic]u8, 0, 512)
	defer delete(code)

	vgabios_probe_emit_prologue(&code)

	vgabios_probe_emit(&code, 0xBB, u8(VBE_STATE_MODE & 0xFF), u8(VBE_STATE_MODE >> 8)) // mov bx, mode
	vgabios_probe_emit(&code, 0xB8, 0x02, 0x4F) // mov ax, 4f02h
	vgabios_probe_emit(&code, 0xCD, 0x10) // int 10h

	// 4F08h BL=01h get the current DAC width.
	vgabios_probe_emit(&code, 0xB8, 0x08, 0x4F) // mov ax, 4f08h
	vgabios_probe_emit(&code, 0xB3, 0x01) // mov bl, 1
	vgabios_probe_emit(&code, 0xCD, 0x10) // int 10h
	vbe_state_emit_status(&code, .Dac_Get_Al, .Dac_Get_Ah)
	vgabios_probe_emit(&code, 0x88, 0xF8) // mov al, bh
	vgabios_probe_emit_store(&code, vbe_state_at(.Dac_Get_Bh))

	// 4F08h BL=00h widen to eight bits, then read it back.
	vgabios_probe_emit(&code, 0xB8, 0x08, 0x4F) // mov ax, 4f08h
	vgabios_probe_emit(&code, 0xB3, 0x00) // mov bl, 0
	vgabios_probe_emit(&code, 0xB7, VBE_DAC_WIDE_BITS) // mov bh, 8
	vgabios_probe_emit(&code, 0xCD, 0x10) // int 10h
	vbe_state_emit_status(&code, .Dac_Wide_Al, .Dac_Wide_Ah)
	vgabios_probe_emit(&code, 0x88, 0xF8) // mov al, bh
	vgabios_probe_emit_store(&code, vbe_state_at(.Dac_Wide_Bh))

	vgabios_probe_emit(&code, 0xB8, 0x08, 0x4F) // mov ax, 4f08h
	vgabios_probe_emit(&code, 0xB3, 0x01) // mov bl, 1
	vgabios_probe_emit(&code, 0xCD, 0x10) // int 10h
	vgabios_probe_emit(&code, 0x88, 0xF8) // mov al, bh
	vgabios_probe_emit_store(&code, vbe_state_at(.Dac_Wide_Readback_Bh))

	// Return to six bits so the palette entries below stay in range.
	vgabios_probe_emit(&code, 0xB8, 0x08, 0x4F) // mov ax, 4f08h
	vgabios_probe_emit(&code, 0xB3, 0x00) // mov bl, 0
	vgabios_probe_emit(&code, 0xB7, VBE_DAC_STANDARD_BITS) // mov bh, 6
	vgabios_probe_emit(&code, 0xCD, 0x10) // int 10h
	vbe_state_emit_status(&code, .Dac_Restore_Al, .Dac_Restore_Ah)

	vgabios_probe_emit(&code, 0xB8, 0x08, 0x4F) // mov ax, 4f08h
	vgabios_probe_emit(&code, 0xB3, 0x01) // mov bl, 1
	vgabios_probe_emit(&code, 0xCD, 0x10) // int 10h
	vgabios_probe_emit(&code, 0x88, 0xF8) // mov al, bh
	vgabios_probe_emit_store(&code, vbe_state_at(.Dac_Restore_Readback_Bh))

	// Publish the source palette, write it, and read it straight back.
	for index in 0 ..< 4 {
		value :=
			u16(VBE_PALETTE_BYTES[index * 2]) | u16(VBE_PALETTE_BYTES[index * 2 + 1]) << 8
		vbe_state_emit_word(&code, VBE_PALETTE_SOURCE + index * 2, value)
	}
	vbe_state_emit_palette(&code, 0x00, VBE_PALETTE_SOURCE)
	vbe_state_emit_status(&code, .Palette_Set_Al, .Palette_Set_Ah)
	vbe_state_emit_palette(&code, 0x01, VBE_PALETTE_READBACK)
	vbe_state_emit_status(&code, .Palette_Get_Al, .Palette_Get_Ah)

	// 4F04h DL=00h size, DL=01h save.
	vgabios_probe_emit(&code, 0xB8, 0x04, 0x4F) // mov ax, 4f04h
	vgabios_probe_emit(&code, 0xB2, 0x00) // mov dl, 0
	vgabios_probe_emit(
		&code,
		0xB9,
		u8(VBE_STATE_COMPONENTS & 0xFF),
		u8(VBE_STATE_COMPONENTS >> 8),
	) // mov cx, components
	vgabios_probe_emit(&code, 0xCD, 0x10) // int 10h
	vbe_state_emit_status(&code, .Size_Al, .Size_Ah)
	vgabios_probe_emit(&code, 0x88, 0xD8) // mov al, bl
	vgabios_probe_emit_store(&code, vbe_state_at(.Size_Blocks_Low))
	vgabios_probe_emit(&code, 0x88, 0xF8) // mov al, bh
	vgabios_probe_emit_store(&code, vbe_state_at(.Size_Blocks_High))

	vgabios_probe_emit(
		&code,
		0xB8,
		u8(VBE_STATE_BUFFER_SEGMENT & 0xFF),
		u8(VBE_STATE_BUFFER_SEGMENT >> 8),
	) // mov ax, segment
	vgabios_probe_emit(&code, 0x8E, 0xC0) // mov es, ax
	vgabios_probe_emit(&code, 0x31, 0xDB) // xor bx, bx
	vgabios_probe_emit(&code, 0xB8, 0x04, 0x4F) // mov ax, 4f04h
	vgabios_probe_emit(&code, 0xB2, 0x01) // mov dl, 1
	vgabios_probe_emit(
		&code,
		0xB9,
		u8(VBE_STATE_COMPONENTS & 0xFF),
		u8(VBE_STATE_COMPONENTS >> 8),
	) // mov cx, components
	vgabios_probe_emit(&code, 0xCD, 0x10) // int 10h
	vbe_state_emit_status(&code, .Save_Al, .Save_Ah)
	vgabios_probe_emit(&code, 0x31, 0xC0) // xor ax, ax
	vgabios_probe_emit(&code, 0x8E, 0xC0) // mov es, ax

	// Overwrite the entries so the restore has something to undo.
	for index in 0 ..< 4 {
		vbe_state_emit_word(&code, VBE_PALETTE_SOURCE + index * 2, 0)
	}
	vbe_state_emit_palette(&code, 0x00, VBE_PALETTE_SOURCE)

	// 4F04h DL=02h restore, then read the palette again.
	vgabios_probe_emit(
		&code,
		0xB8,
		u8(VBE_STATE_BUFFER_SEGMENT & 0xFF),
		u8(VBE_STATE_BUFFER_SEGMENT >> 8),
	) // mov ax, segment
	vgabios_probe_emit(&code, 0x8E, 0xC0) // mov es, ax
	vgabios_probe_emit(&code, 0x31, 0xDB) // xor bx, bx
	vgabios_probe_emit(&code, 0xB8, 0x04, 0x4F) // mov ax, 4f04h
	vgabios_probe_emit(&code, 0xB2, 0x02) // mov dl, 2
	vgabios_probe_emit(
		&code,
		0xB9,
		u8(VBE_STATE_COMPONENTS & 0xFF),
		u8(VBE_STATE_COMPONENTS >> 8),
	) // mov cx, components
	vgabios_probe_emit(&code, 0xCD, 0x10) // int 10h
	vbe_state_emit_status(&code, .Restore_Al, .Restore_Ah)
	vgabios_probe_emit(&code, 0x31, 0xC0) // xor ax, ax
	vgabios_probe_emit(&code, 0x8E, 0xC0) // mov es, ax

	vbe_state_emit_palette(&code, 0x01, VBE_PALETTE_RESTORED)
	vbe_state_emit_status(&code, .Palette_Reget_Al, .Palette_Reget_Ah)

	// 4F09h BL=80h writes the palette during vertical retrace.
	for index in 0 ..< 4 {
		value :=
			u16(VBE_PALETTE_RETRACE_BYTES[index * 2]) |
			u16(VBE_PALETTE_RETRACE_BYTES[index * 2 + 1]) << 8
		vbe_state_emit_word(&code, VBE_PALETTE_SOURCE + index * 2, value)
	}
	vbe_state_emit_palette(&code, 0x80, VBE_PALETTE_SOURCE)
	vbe_state_emit_status(&code, .Palette_Retrace_Al, .Palette_Retrace_Ah)
	vbe_state_emit_palette(&code, 0x01, VBE_PALETTE_RETRACE)
	vbe_state_emit_status(&code, .Palette_Retrace_Get_Al, .Palette_Retrace_Get_Ah)

	vgabios_probe_emit_halt(&code)
	return vgabios_probe_image(code[:])
}

@(private = "file")
vbe_state_field :: proc(m: ^Machine, field: Vbe_State_Field) -> u8 {
	return m.vm.ram[vbe_state_at(field)]
}

@(test)
test_machine_vbe_state_and_palette_round_trip :: proc(t: ^testing.T) {
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

	floppy, built := vbe_state_boot_floppy()
	if !testing.expect(t, built) {return}
	defer delete(floppy)
	if !vgabios_probe_run(t, m, floppy, 45 * time.Second) {return}

	// 4F08h DAC palette width.
	testing.expect_value(t, vbe_state_field(m, .Dac_Get_Al), u8(0x4F))
	testing.expect_value(t, vbe_state_field(m, .Dac_Get_Ah), u8(0x00))
	testing.expect_value(t, vbe_state_field(m, .Dac_Get_Bh), u8(VBE_DAC_STANDARD_BITS))
	testing.expect_value(t, vbe_state_field(m, .Dac_Wide_Al), u8(0x4F))
	testing.expect_value(t, vbe_state_field(m, .Dac_Wide_Ah), u8(0x00))
	testing.expect_value(t, vbe_state_field(m, .Dac_Wide_Bh), u8(VBE_DAC_WIDE_BITS))
	testing.expect_value(t, vbe_state_field(m, .Dac_Wide_Readback_Bh), u8(VBE_DAC_WIDE_BITS))
	testing.expect_value(t, vbe_state_field(m, .Dac_Restore_Al), u8(0x4F))
	testing.expect_value(t, vbe_state_field(m, .Dac_Restore_Ah), u8(0x00))
	testing.expect_value(
		t,
		vbe_state_field(m, .Dac_Restore_Readback_Bh),
		u8(VBE_DAC_STANDARD_BITS),
	)

	// 4F09h palette data must round trip exactly.
	testing.expect_value(t, vbe_state_field(m, .Palette_Set_Al), u8(0x4F))
	testing.expect_value(t, vbe_state_field(m, .Palette_Set_Ah), u8(0x00))
	testing.expect_value(t, vbe_state_field(m, .Palette_Get_Al), u8(0x4F))
	testing.expect_value(t, vbe_state_field(m, .Palette_Get_Ah), u8(0x00))
	for value, index in VBE_PALETTE_BYTES {
		testing.expect_value(t, m.vm.ram[VBE_PALETTE_READBACK + index], value)
	}

	// 4F04h save and restore.
	testing.expect_value(t, vbe_state_field(m, .Size_Al), u8(0x4F))
	testing.expect_value(t, vbe_state_field(m, .Size_Ah), u8(0x00))
	blocks :=
		u16(vbe_state_field(m, .Size_Blocks_Low)) |
		u16(vbe_state_field(m, .Size_Blocks_High)) << 8
	testing.expect(t, blocks > 0)
	log.infof("4F04h reports %d blocks of 64 bytes", blocks)
	testing.expect_value(t, vbe_state_field(m, .Save_Al), u8(0x4F))
	testing.expect_value(t, vbe_state_field(m, .Save_Ah), u8(0x00))
	testing.expect_value(t, vbe_state_field(m, .Restore_Al), u8(0x4F))
	testing.expect_value(t, vbe_state_field(m, .Restore_Ah), u8(0x00))

	// The restore must bring the overwritten palette entries back.
	testing.expect_value(t, vbe_state_field(m, .Palette_Reget_Al), u8(0x4F))
	testing.expect_value(t, vbe_state_field(m, .Palette_Reget_Ah), u8(0x00))
	for value, index in VBE_PALETTE_BYTES {
		testing.expect_value(t, m.vm.ram[VBE_PALETTE_RESTORED + index], value)
	}

	// The BL=80h retrace request must apply the palette like the immediate form.
	testing.expect_value(t, vbe_state_field(m, .Palette_Retrace_Al), u8(0x4F))
	testing.expect_value(t, vbe_state_field(m, .Palette_Retrace_Ah), u8(0x00))
	testing.expect_value(t, vbe_state_field(m, .Palette_Retrace_Get_Al), u8(0x4F))
	testing.expect_value(t, vbe_state_field(m, .Palette_Retrace_Get_Ah), u8(0x00))
	for value, index in VBE_PALETTE_RETRACE_BYTES {
		testing.expect_value(t, m.vm.ram[VBE_PALETTE_RETRACE + index], value)
	}
}
