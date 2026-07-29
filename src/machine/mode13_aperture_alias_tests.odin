// SPDX-License-Identifier: GPL-3.0-only
package machine

import hv "../hv"
import video "../vga"
import "core:log"
import "core:testing"
import "core:time"

// Result slots for the mode 13h aperture probe.
@(private = "file")
MODE13_READ_FIRST :: 0
@(private = "file")
MODE13_READ_FAR :: 1

@(private = "file")
MODE13_PATTERN := [?]u8{0x21, 0x51, 0x81, 0xB1}

// Row 102, column 128 of the 320x200 surface: far enough into the window to land
// on a different 4 KiB page than the first four bytes.
@(private = "file")
MODE13_FAR_OFFSET :: 0x8000

@(private = "file")
MODE13_BLOCK_OFFSET :: 0x1000
@(private = "file")
MODE13_BLOCK_LENGTH :: 0x1000
@(private = "file")
MODE13_BLOCK_VALUE :: u8(0x7E)

// Two probes off one builder. The short one halts before INT 10h, which prices
// the text-mode firmware traffic that reaches the aperture during boot; the long
// one goes on to set mode 13h and store through A000h. The difference between
// their decoded-write counters is the whole cost of the mode 13h section.
@(private = "file")
mode13_boot_floppy :: proc(stop_before_mode_set: bool) -> ([]u8, bool) {
	code := make([dynamic]u8, 0, 512)
	defer delete(code)
	vgabios_probe_emit_prologue(&code)
	if stop_before_mode_set {
		vgabios_probe_emit_halt(&code)
		return vgabios_probe_image(code[:])
	}

	vgabios_probe_emit(&code, 0xB8, 0x13, 0x00) // mov ax, 0013h
	vgabios_probe_emit(&code, 0xCD, 0x10) // int 10h

	vgabios_probe_emit(&code, 0xB8, 0x00, 0xA0) // mov ax, 0a000h
	vgabios_probe_emit(&code, 0x8E, 0xC0) // mov es, ax
	vgabios_probe_emit(&code, 0xFC) // cld
	vgabios_probe_emit(&code, 0x31, 0xFF) // xor di, di
	for value in MODE13_PATTERN {
		vgabios_probe_emit(&code, 0xB0, value) // mov al, value
		vgabios_probe_emit(&code, 0xAA) // stosb
	}
	vgabios_probe_emit(&code, 0xBF, u8(MODE13_FAR_OFFSET & 0xFF), u8(MODE13_FAR_OFFSET >> 8))
	vgabios_probe_emit(&code, 0xB0, 0x5A) // mov al, 5ah
	vgabios_probe_emit(&code, 0xAA) // stosb

	// Plotting the way mode 13h software plots: one scalar store per pixel, which
	// is the case the hypervisor cannot batch into a single string emulation.
	vgabios_probe_emit(&code, 0xBF, u8(MODE13_BLOCK_OFFSET & 0xFF), u8(MODE13_BLOCK_OFFSET >> 8))
	vgabios_probe_emit(&code, 0xB9, u8(MODE13_BLOCK_LENGTH & 0xFF), u8(MODE13_BLOCK_LENGTH >> 8))
	vgabios_probe_emit(&code, 0xB0, MODE13_BLOCK_VALUE) // mov al, 7eh
	vgabios_probe_emit(&code, 0x26, 0x88, 0x05) // mov es:[di], al
	vgabios_probe_emit(&code, 0x47) // inc di
	vgabios_probe_emit(&code, 0xE2, 0xFA) // loop back to the store

	vgabios_probe_emit(&code, 0x31, 0xFF) // xor di, di
	vgabios_probe_emit(&code, 0x26, 0x8A, 0x05) // mov al, es:[di]
	vgabios_probe_emit_store(&code, VGABIOS_PROBE_RESULT_BASE + MODE13_READ_FIRST)
	vgabios_probe_emit(&code, 0xBF, u8(MODE13_FAR_OFFSET & 0xFF), u8(MODE13_FAR_OFFSET >> 8))
	vgabios_probe_emit(&code, 0x26, 0x8A, 0x05) // mov al, es:[di]
	vgabios_probe_emit_store(&code, VGABIOS_PROBE_RESULT_BASE + MODE13_READ_FAR)

	vgabios_probe_emit_halt(&code)
	return vgabios_probe_image(code[:])
}

@(private = "file")
mode13_run_probe :: proc(t: ^testing.T, m: ^Machine, stop_before_mode_set: bool) -> bool {
	if !testing.expect(t, machine_init(m, 64 * 1024 * 1024)) {return false}
	if !testing.expect(t, load_roms(&m.vm)) {return false}
	floppy, built := mode13_boot_floppy(stop_before_mode_set)
	if !testing.expect(t, built) {return false}
	defer delete(floppy)
	return vgabios_probe_run(t, m, floppy, 45 * time.Second)
}

// The chain 4 fast path end to end. A real-mode guest sets mode 13h through
// INT 10h and stores through A000h; by then the aperture is plain writable
// memory, so neither the firmware clear nor the guest's own block store reaches
// the decoder, and the bytes still land where the decoder would have put them
// and reach the rendered frame.
@(test)
test_machine_mode13_aperture_is_aliased_to_video_memory :: proc(t: ^testing.T) {
	if !hv.available() {
		log.warn("WHPX not available")
		return
	}
	testing.set_fail_timeout(t, 120 * time.Second)

	boot := new(Machine)
	defer free(boot)
	if !mode13_run_probe(t, boot, true) {machine_destroy(boot); return}
	boot_aperture_writes := boot.legacy_aperture_write_bytes
	boot_exits := boot.vm.physical_exit_count
	machine_destroy(boot)

	m := new(Machine)
	defer free(m)
	if !mode13_run_probe(t, m, false) {machine_destroy(m); return}
	defer machine_destroy(m)

	alias_mapped := false
	for alias in m.vm.device_aliases {
		if alias.gpa == video.LEGACY_APERTURE_BASE && alias.size == video.DISPI_BANK_SIZE {
			alias_mapped = alias.mapped
		}
	}
	testing.expect(t, alias_mapped)

	// The guest read its own bytes back through the aliased range.
	testing.expect_value(
		t,
		m.vm.ram[VGABIOS_PROBE_RESULT_BASE + MODE13_READ_FIRST],
		MODE13_PATTERN[0],
	)
	testing.expect_value(t, m.vm.ram[VGABIOS_PROBE_RESULT_BASE + MODE13_READ_FAR], u8(0x5A))

	// Chain 4 makes the aperture offset the backing offset, so the stores are
	// visible at exactly the index the decoder would have chosen.
	backing := video.vga_vram(&m.vga)
	for value, index in MODE13_PATTERN {
		testing.expect_value(t, backing[index], value)
	}
	testing.expect_value(t, backing[MODE13_FAR_OFFSET], u8(0x5A))
	testing.expect_value(t, backing[MODE13_BLOCK_OFFSET], MODE13_BLOCK_VALUE)
	testing.expect_value(
		t,
		backing[MODE13_BLOCK_OFFSET + MODE13_BLOCK_LENGTH - 1],
		MODE13_BLOCK_VALUE,
	)

	frame := machine_display_frame(m)
	testing.expect_value(t, frame.kind, video.Display_Kind.Indexed_8)
	testing.expect_value(t, frame.width, 320)
	testing.expect_value(t, frame.height, 200)
	if !testing.expect(t, len(frame.pixels) >= 4) {return}
	testing.expect(t, frame.pixels[0] != frame.pixels[1])
	testing.expect(t, frame.pixels[1] != frame.pixels[2])
	testing.expect(t, frame.pixels[2] != frame.pixels[3])
	testing.expect(t, frame.pixels[MODE13_FAR_OFFSET] != frame.pixels[MODE13_FAR_OFFSET + 1])

	// Damage arrived as alias dirty pages rather than as decoded writes.
	testing.expect(t, m.bank_alias_dirty_page_observations > 0)

	log.infof(
		"mode 13h aperture: decoded write bytes %d before the mode set and %d after, " +
		"physical exits %d then %d, alias dirty pages %d",
		boot_aperture_writes,
		m.legacy_aperture_write_bytes,
		boot_exits,
		m.vm.physical_exit_count,
		m.bank_alias_dirty_page_observations,
	)
	// The firmware clears 64 KiB through this window and the guest stores a
	// further 4 KiB. Not one of those bytes is decoded.
	testing.expect_value(t, m.legacy_aperture_write_bytes, boot_aperture_writes)
}
