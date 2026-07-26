// SPDX-License-Identifier: GPL-3.0-only
package machine

import hv "../hv"
import "core:log"
import "core:testing"
import "core:time"

// INT 10h AH=1Ch save and restore state, with CX selecting hardware, BIOS data
// area, and DAC components.
STATE_SAVE_COMPONENTS :: 0x0007
STATE_SAVE_BUFFER_SEGMENT :: 0x2000
STATE_SAVE_DAC_INDEX :: 5

// The marked palette entry survives the round trip; the mutation between save
// and restore must not.
STATE_SAVE_MARK_RED :: 0x15
STATE_SAVE_MARK_GREEN :: 0x2A
STATE_SAVE_MARK_BLUE :: 0x3F

State_Save_Field :: enum {
	Size_Status,
	Size_Blocks_Low,
	Size_Blocks_High,
	Save_Status,
	Mutated_Red,
	Mutated_Green,
	Mutated_Blue,
	Restore_Status,
	Restored_Red,
	Restored_Green,
	Restored_Blue,
	Restored_Bda_Mode,
	Restored_Crtc_Vertical_Display_End,
}

// Writes one DAC entry through the public write index and data ports.
@(private = "file")
state_save_emit_write_dac :: proc(code: ^[dynamic]u8, index, red, green, blue: u8) {
	vgabios_probe_emit(code, 0xBA, 0xC8, 0x03) // mov dx, 03c8h
	vgabios_probe_emit(code, 0xB0, index) // mov al, index
	vgabios_probe_emit(code, 0xEE) // out dx, al
	vgabios_probe_emit(code, 0x42) // inc dx
	vgabios_probe_emit(code, 0xB0, red, 0xEE) // mov al, red / out dx, al
	vgabios_probe_emit(code, 0xB0, green, 0xEE) // mov al, green / out dx, al
	vgabios_probe_emit(code, 0xB0, blue, 0xEE) // mov al, blue / out dx, al
}

// Reads one DAC entry through the public read index and data ports.
@(private = "file")
state_save_emit_read_dac :: proc(code: ^[dynamic]u8, index: u8, destination: int) {
	vgabios_probe_emit(code, 0xBA, 0xC7, 0x03) // mov dx, 03c7h
	vgabios_probe_emit(code, 0xB0, index) // mov al, index
	vgabios_probe_emit(code, 0xEE) // out dx, al
	vgabios_probe_emit(code, 0xBA, 0xC9, 0x03) // mov dx, 03c9h
	for component in 0 ..< 3 {
		vgabios_probe_emit(code, 0xEC) // in al, dx
		vgabios_probe_emit_store(code, destination + component)
	}
}

// mov es, STATE_SAVE_BUFFER_SEGMENT / xor bx, bx / mov ax, 1Cxxh / mov cx, components / int 10h
@(private = "file")
state_save_emit_call :: proc(code: ^[dynamic]u8, subfunction: u8, destination: int) {
	vgabios_probe_emit(
		code,
		0xB8,
		u8(STATE_SAVE_BUFFER_SEGMENT & 0xFF),
		u8(STATE_SAVE_BUFFER_SEGMENT >> 8),
	) // mov ax, segment
	vgabios_probe_emit(code, 0x8E, 0xC0) // mov es, ax
	vgabios_probe_emit(code, 0x31, 0xDB) // xor bx, bx
	vgabios_probe_emit(code, 0xB8, subfunction, 0x1C) // mov ax, 1Cxxh
	vgabios_probe_emit(
		code,
		0xB9,
		u8(STATE_SAVE_COMPONENTS & 0xFF),
		u8(STATE_SAVE_COMPONENTS >> 8),
	) // mov cx, components
	vgabios_probe_emit(code, 0xCD, 0x10) // int 10h
	vgabios_probe_emit_store(code, destination)
}

@(private = "file")
state_save_result :: proc(field: State_Save_Field) -> int {
	return VGABIOS_PROBE_RESULT_BASE + int(field)
}

@(private = "file")
state_save_boot_floppy :: proc() -> ([]u8, bool) {
	code := make([dynamic]u8, 0, 512)
	defer delete(code)

	vgabios_probe_emit_prologue(&code)
	vgabios_probe_emit(&code, 0xB8, 0x03, 0x00) // mov ax, 0003h
	vgabios_probe_emit(&code, 0xCD, 0x10) // int 10h

	// Mark a palette entry, then ask how large the state buffer must be.
	state_save_emit_write_dac(
		&code,
		STATE_SAVE_DAC_INDEX,
		STATE_SAVE_MARK_RED,
		STATE_SAVE_MARK_GREEN,
		STATE_SAVE_MARK_BLUE,
	)
	vgabios_probe_emit(&code, 0xB8, 0x00, 0x1C) // mov ax, 1c00h
	vgabios_probe_emit(
		&code,
		0xB9,
		u8(STATE_SAVE_COMPONENTS & 0xFF),
		u8(STATE_SAVE_COMPONENTS >> 8),
	) // mov cx, components
	vgabios_probe_emit(&code, 0xCD, 0x10) // int 10h
	vgabios_probe_emit_store(&code, state_save_result(.Size_Status))
	vgabios_probe_emit(&code, 0x88, 0xD8) // mov al, bl
	vgabios_probe_emit_store(&code, state_save_result(.Size_Blocks_Low))
	vgabios_probe_emit(&code, 0x88, 0xF8) // mov al, bh
	vgabios_probe_emit_store(&code, state_save_result(.Size_Blocks_High))

	state_save_emit_call(&code, 0x01, state_save_result(.Save_Status))

	// Change the mode first, then overwrite the marked entry, so the mutation
	// is not itself undone by the mode set reloading a default palette.
	vgabios_probe_emit(&code, 0xB8, 0x13, 0x00) // mov ax, 0013h
	vgabios_probe_emit(&code, 0xCD, 0x10) // int 10h
	state_save_emit_write_dac(&code, STATE_SAVE_DAC_INDEX, 0, 0, 0)
	state_save_emit_read_dac(&code, STATE_SAVE_DAC_INDEX, state_save_result(.Mutated_Red))

	state_save_emit_call(&code, 0x02, state_save_result(.Restore_Status))

	state_save_emit_read_dac(&code, STATE_SAVE_DAC_INDEX, state_save_result(.Restored_Red))
	vgabios_probe_emit_load(&code, 0x0449)
	vgabios_probe_emit_store(&code, state_save_result(.Restored_Bda_Mode))
	vgabios_probe_emit_read_crtc(&code, 0x12)
	vgabios_probe_emit_store(&code, state_save_result(.Restored_Crtc_Vertical_Display_End))

	vgabios_probe_emit_halt(&code)
	return vgabios_probe_image(code[:])
}

@(test)
test_machine_vgabios_int10_state_save_restore_round_trip :: proc(t: ^testing.T) {
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

	floppy, built := state_save_boot_floppy()
	if !testing.expect(t, built) {return}
	defer delete(floppy)
	if !vgabios_probe_run(t, m, floppy, 45 * time.Second) {return}

	field := proc(m: ^Machine, f: State_Save_Field) -> u8 {
		return m.vm.ram[VGABIOS_PROBE_RESULT_BASE + int(f)]
	}

	// All three subfunctions must report the AH=1Ch supported status.
	testing.expect_value(t, field(m, .Size_Status), u8(0x1C))
	testing.expect_value(t, field(m, .Save_Status), u8(0x1C))
	testing.expect_value(t, field(m, .Restore_Status), u8(0x1C))

	blocks := u16(field(m, .Size_Blocks_Low)) | u16(field(m, .Size_Blocks_High)) << 8
	testing.expect(t, blocks > 0)
	log.infof("AH=1Ch reports %d blocks of 64 bytes", blocks)

	// The mutation between save and restore must be observable.
	testing.expect_value(t, field(m, .Mutated_Red), u8(0))
	testing.expect_value(t, field(m, .Mutated_Green), u8(0))
	testing.expect_value(t, field(m, .Mutated_Blue), u8(0))

	// Restore must bring back the DAC entry, the BIOS data area mode, and the
	// CRT Controller geometry that were live at save time.
	testing.expect_value(t, field(m, .Restored_Red), u8(STATE_SAVE_MARK_RED))
	testing.expect_value(t, field(m, .Restored_Green), u8(STATE_SAVE_MARK_GREEN))
	testing.expect_value(t, field(m, .Restored_Blue), u8(STATE_SAVE_MARK_BLUE))
	testing.expect_value(t, field(m, .Restored_Bda_Mode) & 0x7F, u8(0x03))
	testing.expect_value(t, field(m, .Restored_Crtc_Vertical_Display_End), u8(0x8F))
}
