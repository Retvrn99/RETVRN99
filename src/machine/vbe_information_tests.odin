// SPDX-License-Identifier: GPL-3.0-only
package machine

import hv "../hv"
import video "../vga"
import "core:log"
import "core:testing"
import "core:time"

// Guest scratch used by the VBE probe.
VBE_CONTROLLER_BLOCK :: 0x0600
VBE_MODE_LIST :: 0x0800
VBE_MODE_LIST_END :: 0x0900
VBE_MODE_INFO_BASE :: 0x0900
VBE_MODE_INFO_STRIDE :: 0x0100

// VbeInfoBlock field offsets, VBE 2.0 section 4.3.
VBE_SIGNATURE_OFFSET :: 0x00
VBE_VERSION_OFFSET :: 0x04
VBE_CAPABILITIES_OFFSET :: 0x06
VBE_MODE_POINTER_OFFSET :: 0x0E
VBE_TOTAL_MEMORY_OFFSET :: 0x12

// ModeInfoBlock field offsets, VBE 2.0 section 4.4.
VBE_MODE_ATTRIBUTES_OFFSET :: 0x00
VBE_BYTES_PER_SCANLINE_OFFSET :: 0x10
VBE_X_RESOLUTION_OFFSET :: 0x12
VBE_Y_RESOLUTION_OFFSET :: 0x14
VBE_BITS_PER_PIXEL_OFFSET :: 0x19
VBE_MEMORY_MODEL_OFFSET :: 0x1B
VBE_PHYSICAL_BASE_OFFSET :: 0x28

VBE_ATTRIBUTE_SUPPORTED :: 0x0001
VBE_ATTRIBUTE_GRAPHICS :: 0x0010
VBE_ATTRIBUTE_LINEAR :: 0x0080
VBE_MEMORY_MODEL_PACKED :: 0x04
VBE_MEMORY_MODEL_DIRECT :: 0x06

VBE_LINEAR_FRAMEBUFFER :: 0xE000_0000
VBE_LINEAR_BIT :: 0x4000

// The mode set and read back through firmware.
VBE_TARGET_MODE :: 0x0101

Vbe_Mode_Case :: struct {
	mode:          u16,
	width:         u16,
	height:        u16,
	bits:          u8,
	memory_model:  u8,
}

@(private = "file")
VBE_MODE_CASES := [?]Vbe_Mode_Case {
	{0x0101, 640, 480, 8, VBE_MEMORY_MODEL_PACKED},
	{0x0111, 640, 480, 16, VBE_MEMORY_MODEL_DIRECT},
	{0x0150, 320, 200, 8, VBE_MEMORY_MODEL_PACKED},
	{0x0151, 320, 240, 8, VBE_MEMORY_MODEL_PACKED},
}

Vbe_Status_Field :: enum {
	Controller_Al,
	Controller_Ah,
	Set_Mode_Al,
	Set_Mode_Ah,
	Get_Mode_Al,
	Get_Mode_Ah,
	Get_Mode_Bl,
	Get_Mode_Bh,
}

VBE_MODE_STATUS_BASE :: VGABIOS_PROBE_RESULT_BASE + len(Vbe_Status_Field)

// Stores AL then AH of the current INT 10h result.
@(private = "file")
vbe_emit_store_status :: proc(code: ^[dynamic]u8, low, high: int) {
	vgabios_probe_emit_store(code, low)
	vgabios_probe_emit(code, 0x88, 0xE0) // mov al, ah
	vgabios_probe_emit_store(code, high)
}

@(private = "file")
vbe_information_boot_floppy :: proc() -> ([]u8, bool) {
	code := make([dynamic]u8, 0, 512)
	defer delete(code)

	vgabios_probe_emit_prologue(&code)

	// Request the VBE 2.0 controller block by pre-seeding the VBE2 signature.
	vgabios_probe_emit(&code, 0xC7, 0x06, u8(VBE_CONTROLLER_BLOCK & 0xFF), u8(VBE_CONTROLLER_BLOCK >> 8), 'V', 'B')
	vgabios_probe_emit(&code, 0xC7, 0x06, u8((VBE_CONTROLLER_BLOCK + 2) & 0xFF), u8((VBE_CONTROLLER_BLOCK + 2) >> 8), 'E', '2')
	vgabios_probe_emit(&code, 0xB8, 0x00, 0x4F) // mov ax, 4f00h
	vgabios_probe_emit(&code, 0xBF, u8(VBE_CONTROLLER_BLOCK & 0xFF), u8(VBE_CONTROLLER_BLOCK >> 8)) // mov di, block
	vgabios_probe_emit(&code, 0xCD, 0x10) // int 10h
	vbe_emit_store_status(
		&code,
		VGABIOS_PROBE_RESULT_BASE + int(Vbe_Status_Field.Controller_Al),
		VGABIOS_PROBE_RESULT_BASE + int(Vbe_Status_Field.Controller_Ah),
	)

	// Copy the far-pointed mode list into low memory so the test can read it
	// without depending on where the firmware published it.
	vgabios_probe_emit(&code, 0xA1, u8((VBE_CONTROLLER_BLOCK + VBE_MODE_POINTER_OFFSET + 2) & 0xFF), u8((VBE_CONTROLLER_BLOCK + VBE_MODE_POINTER_OFFSET + 2) >> 8)) // mov ax, [segment]
	vgabios_probe_emit(&code, 0x8E, 0xC0) // mov es, ax
	vgabios_probe_emit(&code, 0x8B, 0x36, u8((VBE_CONTROLLER_BLOCK + VBE_MODE_POINTER_OFFSET) & 0xFF), u8((VBE_CONTROLLER_BLOCK + VBE_MODE_POINTER_OFFSET) >> 8)) // mov si, [offset]
	vgabios_probe_emit(&code, 0xBF, u8(VBE_MODE_LIST & 0xFF), u8(VBE_MODE_LIST >> 8)) // mov di, list
	copy_start := len(code)
	vgabios_probe_emit(&code, 0x26, 0x8B, 0x04) // mov ax, es:[si]
	vgabios_probe_emit(&code, 0x83, 0xC6, 0x02) // add si, 2
	vgabios_probe_emit(&code, 0x89, 0x05) // mov [di], ax
	vgabios_probe_emit(&code, 0x83, 0xC7, 0x02) // add di, 2
	vgabios_probe_emit(&code, 0x3D, 0xFF, 0xFF) // cmp ax, 0ffffh
	vgabios_probe_emit(&code, 0x74, 0x06) // je past the bound check and its branch
	vgabios_probe_emit(&code, 0x81, 0xFF, u8(VBE_MODE_LIST_END & 0xFF), u8(VBE_MODE_LIST_END >> 8)) // cmp di, end
	back := copy_start - (len(code) + 2)
	if back < -128 {return nil, false}
	vgabios_probe_emit(&code, 0x72, u8(i8(back))) // jb copy_start

	vgabios_probe_emit(&code, 0x31, 0xC0) // xor ax, ax
	vgabios_probe_emit(&code, 0x8E, 0xC0) // mov es, ax

	// Per-mode information blocks.
	for entry, index in VBE_MODE_CASES {
		destination := VBE_MODE_INFO_BASE + index * VBE_MODE_INFO_STRIDE
		vgabios_probe_emit(&code, 0xB9, u8(entry.mode & 0xFF), u8(entry.mode >> 8)) // mov cx, mode
		vgabios_probe_emit(&code, 0xB8, 0x01, 0x4F) // mov ax, 4f01h
		vgabios_probe_emit(&code, 0xBF, u8(destination & 0xFF), u8(destination >> 8)) // mov di, dest
		vgabios_probe_emit(&code, 0xCD, 0x10) // int 10h
		vbe_emit_store_status(
			&code,
			VBE_MODE_STATUS_BASE + index * 2,
			VBE_MODE_STATUS_BASE + index * 2 + 1,
		)
	}

	// Set a linear framebuffer mode through firmware and read it back.
	vgabios_probe_emit(&code, 0xBB, u8(VBE_TARGET_MODE & 0xFF), u8((VBE_TARGET_MODE | VBE_LINEAR_BIT) >> 8)) // mov bx, mode | linear
	vgabios_probe_emit(&code, 0xB8, 0x02, 0x4F) // mov ax, 4f02h
	vgabios_probe_emit(&code, 0xCD, 0x10) // int 10h
	vbe_emit_store_status(
		&code,
		VGABIOS_PROBE_RESULT_BASE + int(Vbe_Status_Field.Set_Mode_Al),
		VGABIOS_PROBE_RESULT_BASE + int(Vbe_Status_Field.Set_Mode_Ah),
	)

	vgabios_probe_emit(&code, 0xB8, 0x03, 0x4F) // mov ax, 4f03h
	vgabios_probe_emit(&code, 0xCD, 0x10) // int 10h
	vbe_emit_store_status(
		&code,
		VGABIOS_PROBE_RESULT_BASE + int(Vbe_Status_Field.Get_Mode_Al),
		VGABIOS_PROBE_RESULT_BASE + int(Vbe_Status_Field.Get_Mode_Ah),
	)
	vgabios_probe_emit(&code, 0x88, 0xD8) // mov al, bl
	vgabios_probe_emit_store(&code, VGABIOS_PROBE_RESULT_BASE + int(Vbe_Status_Field.Get_Mode_Bl))
	vgabios_probe_emit(&code, 0x88, 0xF8) // mov al, bh
	vgabios_probe_emit_store(&code, VGABIOS_PROBE_RESULT_BASE + int(Vbe_Status_Field.Get_Mode_Bh))

	vgabios_probe_emit_halt(&code)
	return vgabios_probe_image(code[:])
}

@(private = "file")
vbe_word :: proc(m: ^Machine, address: int) -> u16 {
	return u16(m.vm.ram[address]) | u16(m.vm.ram[address + 1]) << 8
}

@(private = "file")
vbe_dword :: proc(m: ^Machine, address: int) -> u32 {
	return u32(vbe_word(m, address)) | u32(vbe_word(m, address + 2)) << 16
}

@(private = "file")
vbe_status :: proc(m: ^Machine, field: Vbe_Status_Field) -> u8 {
	return m.vm.ram[VGABIOS_PROBE_RESULT_BASE + int(field)]
}

@(test)
test_machine_vbe_controller_mode_information_and_round_trip :: proc(t: ^testing.T) {
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

	floppy, built := vbe_information_boot_floppy()
	if !testing.expect(t, built) {return}
	defer delete(floppy)
	if !vgabios_probe_run(t, m, floppy, 45 * time.Second) {return}

	// 4F00h controller information.
	testing.expect_value(t, vbe_status(m, .Controller_Al), u8(0x4F))
	testing.expect_value(t, vbe_status(m, .Controller_Ah), u8(0x00))
	signature := string(m.vm.ram[VBE_CONTROLLER_BLOCK:VBE_CONTROLLER_BLOCK + 4])
	testing.expect_value(t, signature, "VESA")
	version := vbe_word(m, VBE_CONTROLLER_BLOCK + VBE_VERSION_OFFSET)
	testing.expect(t, version >= 0x0200)
	// The firmware sources this from DISPI index 0Ah, so it must agree with the
	// persona exactly. This is the pinned-firmware half of the ID5 contract.
	total_memory := vbe_word(m, VBE_CONTROLLER_BLOCK + VBE_TOTAL_MEMORY_OFFSET)
	testing.expect_value(t, total_memory, u16(video.VRAM_SIZE / 65536))
	log.infof(
		"VBE %d.%d, %d KiB reported, capabilities %08X",
		version >> 8,
		version & 0xFF,
		u32(total_memory) * 64,
		vbe_dword(m, VBE_CONTROLLER_BLOCK + VBE_CAPABILITIES_OFFSET),
	)

	// The mode list must terminate and advertise every mode under test.
	terminated := false
	listed: map[u16]bool
	defer delete(listed)
	for address := VBE_MODE_LIST; address < VBE_MODE_LIST_END; address += 2 {
		value := vbe_word(m, address)
		if value == 0xFFFF {
			terminated = true
			break
		}
		listed[value] = true
	}
	testing.expect(t, terminated)
	for entry in VBE_MODE_CASES {
		if !testing.expect(t, entry.mode in listed) {
			log.errorf("mode %04Xh absent from the 4F00h mode list", entry.mode)
		}
	}

	// 4F01h per-mode information.
	for entry, index in VBE_MODE_CASES {
		block := VBE_MODE_INFO_BASE + index * VBE_MODE_INFO_STRIDE
		testing.expect_value(t, m.vm.ram[VBE_MODE_STATUS_BASE + index * 2], u8(0x4F))
		testing.expect_value(t, m.vm.ram[VBE_MODE_STATUS_BASE + index * 2 + 1], u8(0x00))
		attributes := vbe_word(m, block + VBE_MODE_ATTRIBUTES_OFFSET)
		if attributes & VBE_ATTRIBUTE_SUPPORTED == 0 {
			log.errorf("mode %04Xh reports unsupported attributes %04X", entry.mode, attributes)
		}
		testing.expect_value(t, attributes & VBE_ATTRIBUTE_SUPPORTED, u16(VBE_ATTRIBUTE_SUPPORTED))
		testing.expect_value(t, attributes & VBE_ATTRIBUTE_GRAPHICS, u16(VBE_ATTRIBUTE_GRAPHICS))
		testing.expect_value(t, attributes & VBE_ATTRIBUTE_LINEAR, u16(VBE_ATTRIBUTE_LINEAR))
		testing.expect_value(t, vbe_word(m, block + VBE_X_RESOLUTION_OFFSET), entry.width)
		testing.expect_value(t, vbe_word(m, block + VBE_Y_RESOLUTION_OFFSET), entry.height)
		testing.expect_value(t, m.vm.ram[block + VBE_BITS_PER_PIXEL_OFFSET], entry.bits)
		testing.expect_value(t, m.vm.ram[block + VBE_MEMORY_MODEL_OFFSET], entry.memory_model)
		// Every linear mode must publish the fixed legacy aperture.
		testing.expect_value(
			t,
			vbe_dword(m, block + VBE_PHYSICAL_BASE_OFFSET),
			u32(VBE_LINEAR_FRAMEBUFFER),
		)
		// Bytes per scanline must cover the advertised width.
		pitch := vbe_word(m, block + VBE_BYTES_PER_SCANLINE_OFFSET)
		testing.expect(t, int(pitch) >= int(entry.width) * int(entry.bits) / 8)
	}

	// 4F02h linear set followed by an exact 4F03h read back.
	testing.expect_value(t, vbe_status(m, .Set_Mode_Al), u8(0x4F))
	testing.expect_value(t, vbe_status(m, .Set_Mode_Ah), u8(0x00))
	testing.expect_value(t, vbe_status(m, .Get_Mode_Al), u8(0x4F))
	testing.expect_value(t, vbe_status(m, .Get_Mode_Ah), u8(0x00))
	// The pinned firmware masks the stored mode with 0x1FF before 4F03h reads
	// it, so the D14 linear and D15 preserve flags are deliberately dropped.
	// The mode number itself must round trip exactly.
	current := u16(vbe_status(m, .Get_Mode_Bl)) | u16(vbe_status(m, .Get_Mode_Bh)) << 8
	testing.expect_value(t, current, u16(VBE_TARGET_MODE))

	// The device must agree with the firmware round trip.
	testing.expect(t, video.vga_vbe_enabled(&m.vga))
	testing.expect_value(t, video.dispi_read_register(&m.vga, video.DISPI_INDEX_XRES), u16(640))
	testing.expect_value(t, video.dispi_read_register(&m.vga, video.DISPI_INDEX_YRES), u16(480))
	testing.expect_value(t, video.dispi_read_register(&m.vga, video.DISPI_INDEX_BPP), u16(8))
}
