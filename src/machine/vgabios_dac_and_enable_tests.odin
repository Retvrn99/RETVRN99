// SPDX-License-Identifier: GPL-3.0-only
package machine

import hv "../hv"
import "core:log"
import "core:testing"
import "core:time"

// Result slots for the probe below, all relative to VGABIOS_PROBE_RESULT_BASE.
@(private = "file")
Dac_Probe_Slot :: enum int {
	Enable_Before = 0,
	Enable_Off    = 1,
	Enable_On     = 2,
	Set_Eight_Ax  = 3,
	Get_Ax        = 5,
	Get_Bx        = 7,
	Eight_Red     = 9,
	Eight_Green   = 10,
	Eight_Blue    = 11,
	Set_Six_Ax    = 12,
	Six_Red       = 14,
	Six_Green     = 15,
	Six_Blue      = 16,
	Enable_Status = 17,
}

@(private = "file")
dac_probe_address :: proc(slot: Dac_Probe_Slot) -> int {
	return VGABIOS_PROBE_RESULT_BASE + int(slot)
}

// mov [imm16], ax
@(private = "file")
dac_probe_store_ax :: proc(code: ^[dynamic]u8, slot: Dac_Probe_Slot) {
	address := dac_probe_address(slot)
	vgabios_probe_emit(code, 0xA3, u8(address & 0xFF), u8(address >> 8))
}

// Writes one DAC entry with values the 6-bit path would have to truncate, then
// reads the same entry back through 3C7h/3C9h.
@(private = "file")
dac_probe_round_trip :: proc(code: ^[dynamic]u8, index: u8, first: Dac_Probe_Slot) {
	vgabios_probe_emit(code, 0xBA, 0xC8, 0x03) // mov dx, 03c8h
	vgabios_probe_emit(code, 0xB0, index, 0xEE) // mov al, index / out dx, al
	vgabios_probe_emit(code, 0xBA, 0xC9, 0x03) // mov dx, 03c9h
	for value in ([?]u8{0xFF, 0x80, 0x3F}) {
		vgabios_probe_emit(code, 0xB0, value, 0xEE) // mov al, value / out dx, al
	}
	vgabios_probe_emit(code, 0xBA, 0xC7, 0x03) // mov dx, 03c7h
	vgabios_probe_emit(code, 0xB0, index, 0xEE) // mov al, index / out dx, al
	vgabios_probe_emit(code, 0xBA, 0xC9, 0x03) // mov dx, 03c9h
	for offset in 0 ..< 3 {
		vgabios_probe_emit(code, 0xEC) // in al, dx
		vgabios_probe_emit_store(code, dac_probe_address(first) + offset)
	}
}

@(private = "file")
dac_probe_boot_floppy :: proc() -> ([]u8, bool) {
	code := make([dynamic]u8, 0, 512)
	defer delete(code)
	vgabios_probe_emit_prologue(&code)

	// A mode set first, so the BIOS state the enable call touches is defined.
	vgabios_probe_emit(&code, 0xB8, 0x12, 0x00, 0xCD, 0x10) // mov ax, 0012h / int 10h

	// The pinned firmware implements INT 10h AH=12h BL=32h by moving
	// Miscellaneous Output bit 1, the RAM enable, rather than by touching 3C3h.
	// AL=1 disables video addressing and AL=0 enables it.
	vgabios_probe_emit(&code, 0xBA, 0xCC, 0x03, 0xEC) // mov dx, 03cch / in al, dx
	vgabios_probe_emit_store(&code, dac_probe_address(.Enable_Before))
	vgabios_probe_emit(&code, 0xB8, 0x01, 0x12, 0xB3, 0x32, 0xCD, 0x10)
	dac_probe_store_ax(&code, .Enable_Status)
	vgabios_probe_emit(&code, 0xBA, 0xCC, 0x03, 0xEC)
	vgabios_probe_emit_store(&code, dac_probe_address(.Enable_Off))
	vgabios_probe_emit(&code, 0xB8, 0x00, 0x12, 0xB3, 0x32, 0xCD, 0x10)
	vgabios_probe_emit(&code, 0xBA, 0xCC, 0x03, 0xEC)
	vgabios_probe_emit_store(&code, dac_probe_address(.Enable_On))

	// VBE 4F08h BL=00h sets the DAC width, BL=01h reads it back.
	vgabios_probe_emit(&code, 0xB8, 0x08, 0x4F, 0xBB, 0x00, 0x08, 0xCD, 0x10)
	dac_probe_store_ax(&code, .Set_Eight_Ax)
	vgabios_probe_emit(&code, 0xB8, 0x08, 0x4F, 0xBB, 0x01, 0x00, 0xCD, 0x10)
	dac_probe_store_ax(&code, .Get_Ax)
	address := dac_probe_address(.Get_Bx)
	vgabios_probe_emit(&code, 0x89, 0x1E, u8(address & 0xFF), u8(address >> 8)) // mov [imm16], bx
	dac_probe_round_trip(&code, 0x01, .Eight_Red)

	vgabios_probe_emit(&code, 0xB8, 0x08, 0x4F, 0xBB, 0x00, 0x06, 0xCD, 0x10)
	dac_probe_store_ax(&code, .Set_Six_Ax)
	dac_probe_round_trip(&code, 0x02, .Six_Red)

	vgabios_probe_emit_halt(&code)
	return vgabios_probe_image(code[:])
}

@(private = "file")
dac_probe_result :: proc(m: ^Machine, slot: Dac_Probe_Slot) -> u8 {
	return m.vm.ram[dac_probe_address(slot)]
}

@(private = "file")
dac_probe_word :: proc(m: ^Machine, slot: Dac_Probe_Slot) -> u16 {
	return u16(dac_probe_result(m, slot)) | u16(m.vm.ram[dac_probe_address(slot) + 1]) << 8
}

// IBM 2-46 and VBE 2.0 function 4F08h. Two firmware-gated behaviours that no
// device-level test can reach: the BIOS video enable call, and the 8-bit DAC
// extension, which only stops truncating a palette entry to six bits once the
// firmware has been asked for eight.
@(test)
test_machine_vgabios_video_enable_and_eight_bit_dac :: proc(t: ^testing.T) {
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

	floppy, built := dac_probe_boot_floppy()
	if !testing.expect(t, built) {return}
	defer delete(floppy)
	if !vgabios_probe_run(t, m, floppy, 45 * time.Second) {return}

	// The call answers 1212h and moves the RAM enable in both directions.
	testing.expect_value(t, dac_probe_word(m, .Enable_Status), u16(0x1212))
	testing.expect_value(t, dac_probe_result(m, .Enable_Before) & 0x02, u8(0x02))
	testing.expect_value(t, dac_probe_result(m, .Enable_Off) & 0x02, u8(0))
	testing.expect_value(t, dac_probe_result(m, .Enable_On) & 0x02, u8(0x02))

	testing.expect_value(t, dac_probe_word(m, .Set_Eight_Ax), u16(0x004F))
	testing.expect_value(t, dac_probe_word(m, .Get_Ax), u16(0x004F))
	testing.expect_value(t, dac_probe_word(m, .Get_Bx) >> 8, u16(8))
	testing.expect_value(t, dac_probe_result(m, .Eight_Red), u8(0xFF))
	testing.expect_value(t, dac_probe_result(m, .Eight_Green), u8(0x80))
	testing.expect_value(t, dac_probe_result(m, .Eight_Blue), u8(0x3F))

	// Back at six bits the same writes lose their top two bits.
	testing.expect_value(t, dac_probe_word(m, .Set_Six_Ax), u16(0x004F))
	testing.expect_value(t, dac_probe_result(m, .Six_Red), u8(0x3F))
	testing.expect_value(t, dac_probe_result(m, .Six_Green), u8(0x00))
	testing.expect_value(t, dac_probe_result(m, .Six_Blue), u8(0x3F))
}
