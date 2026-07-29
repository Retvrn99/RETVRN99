// SPDX-License-Identifier: GPL-3.0-only
package vga

import "core:testing"

Vga_Irq_Test_Probe :: struct {
	asserts: int,
	lowers:  int,
	last:    bool,
}

vga_irq_test_callback :: proc(ctx: rawptr, asserted: bool) {
	probe := (^Vga_Irq_Test_Probe)(ctx)
	if asserted {
		probe.asserts += 1
	} else {
		probe.lowers += 1
	}
	probe.last = asserted
}

test_vga_init :: proc(t: ^testing.T, v: ^Vga) -> []u8 {
	backing := make([]u8, VRAM_SIZE)
	testing.expect(t, vga_init(v, backing))
	return backing
}

@(test)
vga_test_external_backing_lifecycle :: proc(t: ^testing.T) {
	v: Vga
	short := make([]u8, 4096)
	testing.expect(t, !vga_init(&v, short))
	delete(short)
	backing := test_vga_init(t, &v)
	backing[123] = 0x5A
	testing.expect_value(t, vga_vram(&v)[123], u8(0x5A))
	vga_destroy(&v)
	testing.expect_value(t, backing[123], u8(0x5A))
	delete(backing)
}

@(test)
vga_test_register_masks_and_crtc_protection :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)

	vga_out(&v, 0x3C4, 2)
	vga_out(&v, 0x3C5, 0xFF)
	testing.expect_value(t, v.seq[2], u8(0x0F))
	vga_out(&v, 0x3CE, 5)
	vga_out(&v, 0x3CF, 0xFF)
	testing.expect_value(t, v.gfx[5], u8(0x7B))

	old := v.crtc[0]
	vga_out(&v, 0x3D4, 0)
	vga_out(&v, 0x3D5, 0x12)
	testing.expect_value(t, v.crtc[0], old)
	vga_out(&v, 0x3D4, 0x11)
	vga_out(&v, 0x3D5, 0)
	vga_out(&v, 0x3D4, 0)
	vga_out(&v, 0x3D5, 0x12)
	testing.expect_value(t, v.crtc[0], u8(0x12))
}

@(test)
vga_test_mono_color_crtc_selection :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	vga_out(&v, 0x3B4, 7)
	testing.expect_value(t, v.crtc_ix, u8(0))
	vga_out(&v, 0x3C2, v.misc & ~u8(1))
	vga_out(&v, 0x3B4, 7)
	testing.expect_value(t, v.crtc_ix, u8(7))
	testing.expect_value(t, vga_in(&v, 0x3D4), u8(0xFF))
}

@(test)
vga_test_attribute_flip_flop_and_dac :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	vga_out(&v, 0x3C0, 3)
	vga_out(&v, 0x3C0, 0x7F)
	testing.expect_value(t, v.attr[3], u8(0x3F))
	// Palette Address Source blanks the display; it does not gate register
	// access. The shipped BIOS state restore writes 00h-0Fh with the bit set.
	vga_out(&v, 0x3C0, 0x20 | 3)
	testing.expect(t, v.video_on)
	vga_out(&v, 0x3C0, 0x12)
	testing.expect_value(t, v.attr[3], u8(0x12))
	testing.expect_value(t, vga_in(&v, 0x3C1), u8(0x12))
	vga_out(&v, 0x3C0, 3)
	testing.expect(t, !v.video_on)
	vga_out(&v, 0x3C0, 0x7F)
	testing.expect_value(t, v.attr[3], u8(0x3F))
	testing.expect_value(t, vga_in(&v, 0x3C1), u8(0x3F))
	_ = vga_in(&v, 0x3DA)
	vga_out(&v, 0x3C0, 4)
	testing.expect(t, v.attr_flip)
	_ = vga_in(&v, 0x3DA)
	testing.expect(t, !v.attr_flip)
	vga_out(&v, 0x3C0, 0x20 | 0x14)
	vga_out(&v, 0x3C0, 0xFF)
	testing.expect_value(t, v.attr[0x14], u8(0x0F))

	vga_out(&v, 0x3C8, 12)
	vga_out(&v, 0x3C9, 0xFF)
	vga_out(&v, 0x3C9, 2)
	vga_out(&v, 0x3C9, 3)
	testing.expect_value(t, v.dac[36], u8(0x3F))
	vga_out(&v, 0x3C7, 12)
	testing.expect_value(t, vga_in(&v, 0x3C9), u8(0x3F))
	testing.expect_value(t, vga_in(&v, 0x3C9), u8(2))
	testing.expect_value(t, vga_in(&v, 0x3C9), u8(3))
}

@(test)
vga_test_guest_activity_ignores_index_and_unchanged_register_writes :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	initial := v.guest_activity_generation
	vga_out(&v, 0x3C4, 1)
	testing.expect_value(t, v.guest_activity_generation, initial)
	vga_out(&v, 0x3C5, v.seq[1])
	testing.expect_value(t, v.guest_activity_generation, initial)
	vga_out(&v, 0x3C5, v.seq[1] ~ 1)
	testing.expect_value(t, v.guest_activity_generation, initial + 1)
	vga_io_write(&v, DISPI_PORT_INDEX, 2, DISPI_INDEX_XRES)
	testing.expect_value(t, v.guest_activity_generation, initial + 1)
}

@(test)
vga_test_absolute_timing_and_status :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	v.timing = Video_Timing {
		frame_period_ns = 1000,
		line_period_ns  = 100,
		total_lines     = 10,
		visible_lines   = 5,
		visible_dots    = 8,
		total_dots      = 10,
		hblank_start    = 8,
		hblank_end      = 10,
		vblank_start    = 5,
		vblank_end      = 10,
		retrace_start   = 6,
		retrace_end     = 8,
	}
	vga_sync_to(&v, 50)
	testing.expect_value(t, vga_in(&v, 0x3DA) & 0x09, u8(0))
	vga_sync_to(&v, 85)
	testing.expect_value(t, vga_in(&v, 0x3DA) & 0x09, u8(0x01))
	vga_sync_to(&v, 650)
	testing.expect_value(t, vga_in(&v, 0x3DA) & 0x09, u8(0x09))
	v.crtc[0x17] &~= 0x80
	testing.expect_value(t, vga_in(&v, 0x3DA) & 0x08, u8(0))
	vga_sync_to(&v, 2050)
	testing.expect_value(t, v.timing.generation, u64(2))
	vga_sync_to(&v, 2050)
	vga_sync_to(&v, 100)
	testing.expect_value(t, v.timing.generation, u64(2))
	testing.expect_value(t, v.timing.elapsed_ns, u64(2050))
}

@(test)
vga_test_public_crtc_reset_disables_status_retrace_signal :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	v.timing = Video_Timing {
		frame_period_ns = 1000,
		line_period_ns  = 100,
		total_lines     = 10,
		visible_lines   = 5,
		visible_dots    = 8,
		total_dots      = 10,
		vblank_start    = 5,
		vblank_end      = 10,
		retrace_start   = 6,
		retrace_end     = 8,
	}
	vga_sync_to(&v, 650)
	testing.expect_value(t, vga_in(&v, 0x3DA) & VGA_STATUS1_VERTICAL_RETRACE, u8(0x08))

	vga_out(&v, 0x3D4, 0x17)
	vga_out(&v, 0x3D5, v.crtc[0x17] &~ 0x80)
	testing.expect_value(t, vga_in(&v, 0x3DA) & VGA_STATUS1_VERTICAL_RETRACE, u8(0))
}

@(test)
vga_test_vertical_interrupt_latch_and_callback :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	v.timing = Video_Timing {
		frame_period_ns = 1000,
		line_period_ns  = 100,
		total_lines     = 10,
		visible_lines   = 5,
		visible_dots    = 8,
		total_dots      = 10,
		vblank_start    = 5,
		vblank_end      = 10,
		retrace_start   = 6,
		retrace_end     = 8,
	}
	v.crtc[0x11] = 0x10
	probe: Vga_Irq_Test_Probe
	vga_set_legacy_irq(&v, &probe, vga_irq_test_callback)

	vga_sync_to(&v, 550)
	testing.expect(t, v.vertical_interrupt_pending)
	testing.expect(t, vga_legacy_irq_line(&v))
	testing.expect_value(t, probe.asserts, 1)
	testing.expect_value(t, probe.last, true)
	testing.expect_value(t, vga_in(&v, 0x3C2) & 0x80, u8(0x80))

	vga_out(&v, 0x3D4, 0x11)
	vga_out(&v, 0x3D5, 0)
	testing.expect(t, !v.vertical_interrupt_pending)
	testing.expect(t, !vga_legacy_irq_line(&v))
	testing.expect_value(t, probe.lowers, 1)
	testing.expect_value(t, vga_in(&v, 0x3C2) & 0x80, u8(0))
	vga_sync_to(&v, 1550)
	testing.expect(t, !v.vertical_interrupt_pending)
	testing.expect_value(t, probe.asserts, 1)

	vga_out(&v, 0x3D4, 0x11)
	vga_out(&v, 0x3D5, 0x30)
	vga_sync_to(&v, 2550)
	testing.expect(t, !v.vertical_interrupt_pending)
	testing.expect(t, !vga_legacy_irq_line(&v))
	testing.expect_value(t, probe.asserts, 1)
}

@(test)
vga_test_default_crtc11_holds_vertical_interrupt_clear :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	v.timing = Video_Timing {
		frame_period_ns = 1000,
		line_period_ns  = 100,
		total_lines     = 10,
		visible_lines   = 5,
		visible_dots    = 8,
		total_dots      = 10,
		vblank_start    = 5,
		vblank_end      = 10,
		retrace_start   = 6,
		retrace_end     = 8,
	}
	testing.expect_value(t, v.crtc[0x11], u8(0x8E))
	vga_sync_to(&v, 550)
	testing.expect(t, !v.vertical_interrupt_pending)
	testing.expect(t, !vga_legacy_irq_line(&v))
	_, pending := vga_next_vertical_interrupt_ns(&v)
	testing.expect(t, !pending)
}
