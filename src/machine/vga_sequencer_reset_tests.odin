// SPDX-License-Identifier: GPL-3.0-only
package machine

import hv "../hv"
import video "../vga"
import "core:log"
import "core:testing"

@(test)
test_machine_vga_sequencer_reset_crosses_io_and_restores_scanout :: proc(t: ^testing.T) {
	if !hv.available() {
		log.warn("WHPX not available")
		return
	}
	m := new(Machine)
	defer free(m)
	if !testing.expect(t, machine_init(m, 64 * 1024 * 1024)) {return}
	defer machine_destroy(m)

	testing.expect(t, machine_io_write(m, 0xCF8, 4, 0x8000_1004))
	testing.expect(t, machine_io_write(m, 0xCFC, 2, 0x0007))
	testing.expect(t, machine_io_write(m, video.DISPI_PORT_INDEX, 2, video.DISPI_INDEX_XRES))
	testing.expect(t, machine_io_write(m, video.DISPI_PORT_DATA, 2, 1))
	testing.expect(t, machine_io_write(m, video.DISPI_PORT_INDEX, 2, video.DISPI_INDEX_YRES))
	testing.expect(t, machine_io_write(m, video.DISPI_PORT_DATA, 2, 1))
	testing.expect(t, machine_io_write(m, video.DISPI_PORT_INDEX, 2, video.DISPI_INDEX_BPP))
	testing.expect(t, machine_io_write(m, video.DISPI_PORT_DATA, 2, 32))
	testing.expect(t, machine_io_write(m, video.DISPI_PORT_INDEX, 2, video.DISPI_INDEX_ENABLE))
	testing.expect(
		t,
		machine_io_write(
			m,
			video.DISPI_PORT_DATA,
			2,
			u32(video.DISPI_ENABLED | video.DISPI_LFB_ENABLED),
		),
	)
	m.vga.vram[0], m.vga.vram[1], m.vga.vram[2], m.vga.vram[3] = 0x11, 0x22, 0x33, 0
	video.vga_note_content_change(&m.vga)
	baseline := machine_display_frame(m).pixels[0]
	testing.expect_value(t, baseline, u32(0xFF33_2211))

	testing.expect(t, machine_io_write(m, 0x3C4, 1, 0))
	testing.expect(t, machine_io_write(m, 0x3C5, 1, 1))
	readback, ok := machine_io_read(m, 0x3C5, 1)
	testing.expect(t, ok)
	testing.expect_value(t, readback, u32(1))
	testing.expect_value(t, machine_display_frame(m).pixels[0], u32(0xFF00_0000))

	testing.expect(t, machine_io_write(m, 0x3C5, 1, 3))
	testing.expect_value(t, machine_display_frame(m).pixels[0], baseline)
	testing.expect_value(t, m.platform.bus.unclassified_count, u64(0))
	testing.expect_value(t, m.platform.bus.unclassified_mmio_count, u64(0))
}
