// SPDX-License-Identifier: GPL-3.0-only
package machine

import "core:testing"

dma_setup :: proc(d: ^Dma) { // programs channel 2 via ports
	dma_out(d, 0x0C, 0)                            // clear flip-flop
	dma_out(d, 0x04, 0x34); dma_out(d, 0x04, 0x12) // address 0x1234
	dma_out(d, 0x81, 0x05)                         // page
	dma_out(d, 0x05, 0xFF); dma_out(d, 0x05, 0x01) // count 511 (512 bytes)
	dma_out(d, 0x0B, 0x46)                         // mode: write, channel 2
	dma_out(d, 0x0A, 0x02)                         // unmask channel 2
}

@(test)
test_dma_ch2_write_mem :: proc(t: ^testing.T) {
	d: Dma
	dma_setup(&d)
	ram := make([]u8, 1 << 20)
	defer delete(ram)
	data: [512]u8
	for i in 0 ..< 512 { data[i] = u8(i) }
	dma_write_mem(&d, 2, ram, data[:])
	testing.expect_value(t, ram[0x51234], u8(0))
	testing.expect_value(t, ram[0x51234 + 511], u8(255))
	testing.expect(t, dma_in(&d, 0x08) & 0x04 != 0) // channel 2 TC
}

// SeaBIOS never reads port 0x08 between floppy transfers: the device-visible
// TC must re-arm when the channel count is reprogrammed, while the status
// register bit stays sticky until read (8237 spec).
@(test)
test_dma_ch2_tc_rearm :: proc(t: ^testing.T) {
	d: Dma
	dma_setup(&d)
	ram := make([]u8, 1 << 20)
	defer delete(ram)
	data: [512]u8
	dma_write_mem(&d, 2, ram, data[:])
	testing.expect(t, d.ch[2].tc)

	dma_setup(&d) // next transfer programmed without touching port 0x08
	testing.expect(t, !d.ch[2].tc)
	testing.expect(t, dma_in(&d, 0x08) & 0x04 != 0) // sticky until this read

	dma_write_mem(&d, 2, ram, data[:])
	testing.expect(t, d.ch[2].tc)
	testing.expect(t, dma_in(&d, 0x08) & 0x04 != 0)
}

@(test)
test_dma_ch2_read_mem :: proc(t: ^testing.T) {
	d: Dma
	dma_setup(&d)
	ram := make([]u8, 1 << 20)
	defer delete(ram)
	for i in 0 ..< 512 { ram[0x51234 + i] = u8(i) }
	out := dma_read_mem(&d, 2, ram, 512)
	defer delete(out)
	testing.expect_value(t, len(out), 512)
	testing.expect_value(t, out[0], u8(0))
	testing.expect_value(t, out[511], u8(255))
	testing.expect(t, dma_in(&d, 0x08) & 0x04 != 0) // channel 2 TC
}
