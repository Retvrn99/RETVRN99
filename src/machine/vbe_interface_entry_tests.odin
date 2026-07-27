// SPDX-License-Identifier: GPL-3.0-only
package machine

import hv "../hv"
import "core:log"
import "core:testing"
import "core:time"

@(private = "file")
VBE_ENTRY_MODE :: u16(0x0101)
// Scratch for the ModeInfoBlock the probe asks the firmware for.
@(private = "file")
VBE_ENTRY_INFO_BLOCK :: 0x0700

@(private = "file")
VBE_E_SET_MODE :: 0
@(private = "file")
VBE_E_MODE_INFO :: 2
@(private = "file")
VBE_E_WINDOW_GET :: 4
@(private = "file")
VBE_E_WINDOW_DX :: 6
@(private = "file")
VBE_E_PMI_AX :: 8
@(private = "file")
VBE_E_PMI_ES :: 10
@(private = "file")
VBE_E_PMI_DI :: 12
@(private = "file")
VBE_E_PMI_CX :: 14

@(private = "file")
VBE_ENTRY_WINDOW :: 5

// mov [imm16], reg16 for the three registers the probe records.
@(private = "file")
vbe_entry_store_word :: proc(code: ^[dynamic]u8, modrm: u8, offset: int) {
	address := VGABIOS_PROBE_RESULT_BASE + offset
	vgabios_probe_emit(code, 0x89, modrm, u8(address & 0xFF), u8(address >> 8))
}

@(private = "file")
VBE_ENTRY_TO_AX :: 0x06
@(private = "file")
VBE_ENTRY_TO_DX :: 0x16
@(private = "file")
VBE_ENTRY_TO_CX :: 0x0E
@(private = "file")
VBE_ENTRY_TO_DI :: 0x3E

@(private = "file")
vbe_entry_boot_floppy :: proc() -> ([]u8, bool) {
	code := make([dynamic]u8, 0, 512)
	defer delete(code)
	vgabios_probe_emit_prologue(&code)

	vgabios_probe_emit(&code, 0xB8, 0x02, 0x4F) // mov ax, 4f02h
	vgabios_probe_emit(&code, 0xBB, u8(VBE_ENTRY_MODE & 0xFF), u8(VBE_ENTRY_MODE >> 8))
	vgabios_probe_emit(&code, 0xCD, 0x10)
	vbe_entry_store_word(&code, VBE_ENTRY_TO_AX, VBE_E_SET_MODE)

	// The ModeInfoBlock carries WindowFuncPtr at offset 0Ch as a far pointer.
	vgabios_probe_emit(&code, 0xB8, 0x01, 0x4F) // mov ax, 4f01h
	vgabios_probe_emit(&code, 0xB9, u8(VBE_ENTRY_MODE & 0xFF), u8(VBE_ENTRY_MODE >> 8)) // mov cx, mode
	vgabios_probe_emit(
		&code,
		0xBF,
		u8(VBE_ENTRY_INFO_BLOCK & 0xFF),
		u8(VBE_ENTRY_INFO_BLOCK >> 8),
	) // mov di, block
	vgabios_probe_emit(&code, 0xCD, 0x10)
	vbe_entry_store_word(&code, VBE_ENTRY_TO_AX, VBE_E_MODE_INFO)

	// Call the entry directly, the way a driver that cached the pointer would:
	// BH selects set, BL selects window A, DX carries the window number.
	vgabios_probe_emit(&code, 0xBB, 0x00, 0x00) // mov bx, 0000h
	vgabios_probe_emit(&code, 0xBA, VBE_ENTRY_WINDOW, 0x00) // mov dx, window
	vgabios_probe_emit(
		&code,
		0xFF,
		0x1E,
		u8((VBE_ENTRY_INFO_BLOCK + 0x0C) & 0xFF),
		u8((VBE_ENTRY_INFO_BLOCK + 0x0C) >> 8),
	) // call far [block+0ch]

	// Then ask the firmware where the window is; it must agree.
	vgabios_probe_emit(&code, 0xB8, 0x05, 0x4F) // mov ax, 4f05h
	vgabios_probe_emit(&code, 0xBB, 0x00, 0x01) // mov bx, 0100h
	vgabios_probe_emit(&code, 0xCD, 0x10)
	vbe_entry_store_word(&code, VBE_ENTRY_TO_AX, VBE_E_WINDOW_GET)
	vbe_entry_store_word(&code, VBE_ENTRY_TO_DX, VBE_E_WINDOW_DX)

	// 4F0Ah BL=00h returns the protected-mode interface table in ES:DI with its
	// length in CX.
	vgabios_probe_emit(&code, 0xB8, 0x0A, 0x4F) // mov ax, 4f0ah
	vgabios_probe_emit(&code, 0xBB, 0x00, 0x00) // mov bx, 0000h
	vgabios_probe_emit(&code, 0xCD, 0x10)
	vbe_entry_store_word(&code, VBE_ENTRY_TO_AX, VBE_E_PMI_AX)
	vgabios_probe_emit(&code, 0x8C, 0xC0) // mov ax, es
	vgabios_probe_emit(&code, 0x31, 0xDB) // xor bx, bx
	vgabios_probe_emit(&code, 0x8E, 0xC3) // mov es, bx
	vbe_entry_store_word(&code, VBE_ENTRY_TO_AX, VBE_E_PMI_ES)
	vbe_entry_store_word(&code, VBE_ENTRY_TO_DI, VBE_E_PMI_DI)
	vbe_entry_store_word(&code, VBE_ENTRY_TO_CX, VBE_E_PMI_CX)

	vgabios_probe_emit_halt(&code)
	return vgabios_probe_image(code[:])
}

@(private = "file")
vbe_entry_word :: proc(m: ^Machine, offset: int) -> u16 {
	base := VGABIOS_PROBE_RESULT_BASE + offset
	return u16(m.vm.ram[base]) | u16(m.vm.ram[base + 1]) << 8
}

// VBE 2.0 4.8 and 4.13. Two entry points a driver reaches without going through
// INT 10h: the far pointer the ModeInfoBlock hands out for window control, and
// the protected-mode interface table.
@(test)
test_machine_vbe_window_entry_point_and_protected_mode_table :: proc(t: ^testing.T) {
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

	floppy, built := vbe_entry_boot_floppy()
	if !testing.expect(t, built) {return}
	defer delete(floppy)
	if !vgabios_probe_run(t, m, floppy, 45 * time.Second) {return}

	testing.expect_value(t, vbe_entry_word(m, VBE_E_SET_MODE), u16(0x004F))
	testing.expect_value(t, vbe_entry_word(m, VBE_E_MODE_INFO), u16(0x004F))

	// The far pointer has to be real, and calling it has to move the window the
	// firmware then reports.
	pointer_offset := u16(m.vm.ram[VBE_ENTRY_INFO_BLOCK + 0x0C]) |
		u16(m.vm.ram[VBE_ENTRY_INFO_BLOCK + 0x0D]) << 8
	pointer_segment := u16(m.vm.ram[VBE_ENTRY_INFO_BLOCK + 0x0E]) |
		u16(m.vm.ram[VBE_ENTRY_INFO_BLOCK + 0x0F]) << 8
	log.infof("WindowFuncPtr %04X:%04X", pointer_segment, pointer_offset)
	testing.expect(t, pointer_segment != 0)
	testing.expect_value(t, vbe_entry_word(m, VBE_E_WINDOW_GET), u16(0x004F))
	testing.expect_value(t, vbe_entry_word(m, VBE_E_WINDOW_DX), u16(VBE_ENTRY_WINDOW))

	// The protected-mode table's three entry offsets have to land inside it.
	testing.expect_value(t, vbe_entry_word(m, VBE_E_PMI_AX), u16(0x004F))
	table := int(vbe_entry_word(m, VBE_E_PMI_ES)) * 16 + int(vbe_entry_word(m, VBE_E_PMI_DI))
	length := int(vbe_entry_word(m, VBE_E_PMI_CX))
	log.infof("VBE protected mode table at %05X length %d", table, length)
	testing.expect(t, length >= 6)
	testing.expect(t, table > 0 && table + length <= len(m.vm.ram))
	for entry in 0 ..< 3 {
		offset := int(m.vm.ram[table + entry * 2]) | int(m.vm.ram[table + entry * 2 + 1]) << 8
		log.infof("VBE protected mode entry %d at +%04X", entry, offset)
		testing.expect(t, offset > 0)
		testing.expect(t, offset < length)
	}
}
