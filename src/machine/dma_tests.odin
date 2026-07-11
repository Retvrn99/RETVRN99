// SPDX-License-Identifier: GPL-3.0-only
package machine

import "core:testing"

dma_setup :: proc(d: ^Dma) { // programa canal 2 vía puertos
	dma_out(d, 0x0C, 0)                            // limpiar flip-flop
	dma_out(d, 0x04, 0x34); dma_out(d, 0x04, 0x12) // dirección 0x1234
	dma_out(d, 0x81, 0x05)                         // página
	dma_out(d, 0x05, 0xFF); dma_out(d, 0x05, 0x01) // cuenta 511 (512 bytes)
	dma_out(d, 0x0B, 0x46)                         // modo: escritura, canal 2
	dma_out(d, 0x0A, 0x02)                         // desenmascarar canal 2
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
	testing.expect(t, dma_in(&d, 0x08) & 0x04 != 0) // TC canal 2
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
	testing.expect(t, dma_in(&d, 0x08) & 0x04 != 0) // TC canal 2
}
