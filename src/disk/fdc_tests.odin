// SPDX-License-Identifier: GPL-3.0-only
package disk

import "core:testing"

// DMA falso: cuenta bytes y marca fin de cuenta al agotar el limite
Fdc_Test_Dma :: struct {
	ram:   []u8,
	pos:   int,
	limit: int,
}

fdc_test_to_mem :: proc(ctx: rawptr, data: []u8) {
	d := (^Fdc_Test_Dma)(ctx)
	n := copy(d.ram[d.pos:], data)
	d.pos += n
}

fdc_test_from_mem :: proc(ctx: rawptr, buf: []u8) -> int {
	d := (^Fdc_Test_Dma)(ctx)
	end := min(d.pos + len(buf), d.limit, len(d.ram))
	if end <= d.pos { return 0 }
	n := copy(buf, d.ram[d.pos:end])
	d.pos += n
	return n
}

fdc_test_tc :: proc(ctx: rawptr) -> bool {
	d := (^Fdc_Test_Dma)(ctx)
	return d.pos >= d.limit
}

fdc_test_setup :: proc(f: ^Fdc, d: ^Fdc_Test_Dma, irq_count: ^int) {
	fdc_init(f)
	f.irq_ctx = irq_count
	f.irq = proc(ctx: rawptr) { (^int)(ctx)^ += 1 }
	f.dma_ctx = d
	f.dma_to_mem = fdc_test_to_mem
	f.dma_from_mem = fdc_test_from_mem
	f.dma_tc = fdc_test_tc
}

fdc_test_image :: proc() -> []u8 {
	img := make([]u8, FLOPPY_144_SIZE)
	for i in 0 ..< 512 { img[i] = u8(i * 7) }
	img[9 * 512] = 0xA9 // C0/H1/S1 para lecturas fuera del primer sector
	return img
}

// reset por DOR y drenaje de los 4 SENSE INTERRUPT de sondeo
fdc_test_enable :: proc(f: ^Fdc) {
	fdc_out(f, 0x3F2, 0x08)
	fdc_out(f, 0x3F2, 0x0C)
	for _ in 0 ..< 4 {
		fdc_out(f, 0x3F5, 0x08)
		_ = fdc_in(f, 0x3F5)
		_ = fdc_in(f, 0x3F5)
	}
}

@(test)
fdc_test_msr_and_version :: proc(t: ^testing.T) {
	f: Fdc
	d: Fdc_Test_Dma
	irqs := 0
	fdc_test_setup(&f, &d, &irqs)

	// en reset: RQM apagado
	testing.expect_value(t, fdc_in(&f, 0x3F4), u8(0x00))

	fdc_test_enable(&f)
	testing.expect_value(t, fdc_in(&f, 0x3F4), u8(0x80)) // Idle: RQM

	fdc_out(&f, 0x3F5, 0x10) // VERSION
	testing.expect_value(t, fdc_in(&f, 0x3F4), u8(0xD0)) // Result: RQM|DIO|BUSY
	testing.expect_value(t, fdc_in(&f, 0x3F5), u8(0x90))
	testing.expect_value(t, fdc_in(&f, 0x3F4), u8(0x80)) // de vuelta a Idle
}

@(test)
fdc_test_reset_sense_sequence :: proc(t: ^testing.T) {
	f: Fdc
	d: Fdc_Test_Dma
	irqs := 0
	fdc_test_setup(&f, &d, &irqs)

	fdc_out(&f, 0x3F2, 0x08) // entra en reset, IRQ habilitado
	fdc_out(&f, 0x3F2, 0x0C) // sale de reset
	testing.expect_value(t, irqs, 1)

	// 4 SENSE INTERRUPT de sondeo: ST0 = 0xC0..0xC3, PCN = 0
	for unit in 0 ..< 4 {
		fdc_out(&f, 0x3F5, 0x08)
		testing.expect_value(t, fdc_in(&f, 0x3F4), u8(0xD0))
		testing.expect_value(t, fdc_in(&f, 0x3F5), u8(0xC0 + unit))
		testing.expect_value(t, fdc_in(&f, 0x3F5), u8(0x00))
	}

	// quinto SENSE sin interrupcion pendiente: comando invalido
	fdc_out(&f, 0x3F5, 0x08)
	testing.expect_value(t, fdc_in(&f, 0x3F5), u8(0x80))
	testing.expect_value(t, fdc_in(&f, 0x3F4), u8(0x80))
}

@(test)
fdc_test_recalibrate_sense :: proc(t: ^testing.T) {
	f: Fdc
	d: Fdc_Test_Dma
	irqs := 0
	fdc_test_setup(&f, &d, &irqs)
	fdc_test_enable(&f)
	irqs = 0

	fdc_out(&f, 0x3F5, 0x07) // RECALIBRATE
	testing.expect_value(t, fdc_in(&f, 0x3F4), u8(0x90)) // Param: RQM|BUSY
	fdc_out(&f, 0x3F5, 0x00) // unidad 0
	testing.expect_value(t, irqs, 1)
	testing.expect_value(t, fdc_in(&f, 0x3F4), u8(0x80)) // sin fase de resultado

	fdc_out(&f, 0x3F5, 0x08) // SENSE INTERRUPT
	testing.expect_value(t, fdc_in(&f, 0x3F5), u8(0x20)) // ST0: seek end
	testing.expect_value(t, fdc_in(&f, 0x3F5), u8(0x00)) // PCN 0
}

@(test)
fdc_test_seek_sense :: proc(t: ^testing.T) {
	f: Fdc
	d: Fdc_Test_Dma
	irqs := 0
	fdc_test_setup(&f, &d, &irqs)
	fdc_test_enable(&f)
	irqs = 0

	fdc_out(&f, 0x3F5, 0x0F) // SEEK
	fdc_out(&f, 0x3F5, 0x00) // unidad 0, cabeza 0
	fdc_out(&f, 0x3F5, 0x21) // NCN = 33
	testing.expect_value(t, irqs, 1)

	fdc_out(&f, 0x3F5, 0x08)
	testing.expect_value(t, fdc_in(&f, 0x3F5), u8(0x20))
	testing.expect_value(t, fdc_in(&f, 0x3F5), u8(0x21))
}

@(test)
fdc_test_read_first_sector :: proc(t: ^testing.T) {
	f: Fdc
	d: Fdc_Test_Dma
	irqs := 0
	fdc_test_setup(&f, &d, &irqs)
	img := fdc_test_image()
	defer delete(img)
	testing.expect(t, fdc_set_media(&f, img))
	defer fdc_eject_media(&f)
	fdc_test_enable(&f)

	guest := make([]u8, 4096)
	defer delete(guest)
	d.ram = guest
	d.pos = 0
	d.limit = 512
	irqs = 0

	// READ C0/H0/S1, EOT 18
	fdc_out(&f, 0x3F5, 0xE6)
	testing.expect_value(t, fdc_in(&f, 0x3F4), u8(0x90))
	for p in ([]u8{0x00, 0, 0, 1, 2, 18, 0x1B, 0xFF}) { fdc_out(&f, 0x3F5, p) }

	testing.expect_value(t, irqs, 1)
	testing.expect_value(t, fdc_in(&f, 0x3F4), u8(0xD0))

	res: [7]u8
	for i in 0 ..< 7 { res[i] = fdc_in(&f, 0x3F5) }
	testing.expect_value(t, res[0] & 0xC0, u8(0x00)) // terminacion normal
	testing.expect_value(t, res[1], u8(0x00))
	testing.expect_value(t, fdc_in(&f, 0x3F4), u8(0x80))

	ok := true
	for i in 0 ..< 512 {
		if guest[i] != img[i] { ok = false; break }
	}
	testing.expect(t, ok)
	testing.expect_value(t, d.pos, 512) // solo un sector: paro por fin de cuenta
}

@(test)
fdc_test_write_sector :: proc(t: ^testing.T) {
	f: Fdc
	d: Fdc_Test_Dma
	irqs := 0
	fdc_test_setup(&f, &d, &irqs)
	img := fdc_test_image()
	defer delete(img)
	testing.expect(t, fdc_set_media(&f, img))
	defer fdc_eject_media(&f)
	fdc_test_enable(&f)

	guest := make([]u8, 4096)
	defer delete(guest)
	for i in 0 ..< 512 { guest[i] = u8(255 - i % 251) }
	d.ram = guest
	d.pos = 0
	d.limit = 512

	testing.expect(t, !f.img.dirty)
	// WRITE C0/H0/S2
	fdc_out(&f, 0x3F5, 0xC5)
	for p in ([]u8{0x00, 0, 0, 2, 2, 18, 0x1B, 0xFF}) { fdc_out(&f, 0x3F5, p) }

	res: [7]u8
	for i in 0 ..< 7 { res[i] = fdc_in(&f, 0x3F5) }
	testing.expect_value(t, res[0] & 0xC0, u8(0x00))

	ok := true
	for i in 0 ..< 512 {
		if f.img.data[512 + i] != guest[i] { ok = false; break }
	}
	testing.expect(t, ok)
	testing.expect(t, f.img.dirty)
}

@(test)
fdc_test_read_id :: proc(t: ^testing.T) {
	f: Fdc
	d: Fdc_Test_Dma
	irqs := 0
	fdc_test_setup(&f, &d, &irqs)
	img := fdc_test_image()
	defer delete(img)
	testing.expect(t, fdc_set_media(&f, img))
	defer fdc_eject_media(&f)
	fdc_test_enable(&f)
	irqs = 0

	fdc_out(&f, 0x3F5, 0x4A) // READ ID, cabeza 0
	fdc_out(&f, 0x3F5, 0x00)
	testing.expect_value(t, irqs, 1)

	res: [7]u8
	for i in 0 ..< 7 { res[i] = fdc_in(&f, 0x3F5) }
	testing.expect_value(t, res[0] & 0xC0, u8(0x00))
	testing.expect_value(t, res[3], u8(0x00)) // C
	testing.expect_value(t, res[4], u8(0x00)) // H
	testing.expect_value(t, res[5], u8(0x01)) // R
	testing.expect_value(t, res[6], u8(0x02)) // N

	// sin medio: terminacion anormal
	fdc_eject_media(&f)
	fdc_out(&f, 0x3F5, 0x4A)
	fdc_out(&f, 0x3F5, 0x00)
	for i in 0 ..< 7 { res[i] = fdc_in(&f, 0x3F5) }
	testing.expect_value(t, res[0] & 0xC0, u8(0x40))
}

@(test)
fdc_test_media_change_bit :: proc(t: ^testing.T) {
	f: Fdc
	d: Fdc_Test_Dma
	irqs := 0
	fdc_test_setup(&f, &d, &irqs)
	fdc_test_enable(&f)

	testing.expect_value(t, fdc_in(&f, 0x3F7), u8(0x00)) // arranque sin medio

	img := fdc_test_image()
	defer delete(img)
	testing.expect(t, fdc_set_media(&f, img))
	testing.expect_value(t, fdc_in(&f, 0x3F7), u8(0x80)) // montar marca DSKCHG

	// el pulso de paso de RECALIBRATE con medio presente lo limpia
	fdc_out(&f, 0x3F5, 0x07)
	fdc_out(&f, 0x3F5, 0x00)
	testing.expect_value(t, fdc_in(&f, 0x3F7), u8(0x00))

	fdc_eject_media(&f)
	testing.expect_value(t, fdc_in(&f, 0x3F7), u8(0x80)) // expulsar lo vuelve a marcar
}

@(test)
fdc_test_invalid_command :: proc(t: ^testing.T) {
	f: Fdc
	d: Fdc_Test_Dma
	irqs := 0
	fdc_test_setup(&f, &d, &irqs)
	fdc_test_enable(&f)

	fdc_out(&f, 0x3F5, 0x18) // sin implementar
	testing.expect_value(t, fdc_in(&f, 0x3F4), u8(0xD0))
	testing.expect_value(t, fdc_in(&f, 0x3F5), u8(0x80))
	testing.expect_value(t, fdc_in(&f, 0x3F4), u8(0x80))
}

@(test)
fdc_test_image_size_check :: proc(t: ^testing.T) {
	f: Fdc
	fdc_init(&f)
	bad := make([]u8, 1000)
	defer delete(bad)
	testing.expect(t, !fdc_set_media(&f, bad))
	testing.expect(t, !f.has_media)
}
