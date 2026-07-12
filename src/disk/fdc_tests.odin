// SPDX-License-Identifier: GPL-3.0-only
package disk

import "core:testing"

// fake DMA: counts bytes and flags terminal count when the limit runs out
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
	img[9 * 512] = 0xA9 // C0/H1/S1 for reads beyond the first sector
	return img
}

// reset via DOR and drain of the 4 polling SENSE INTERRUPTs
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

	// in reset: RQM off
	testing.expect_value(t, fdc_in(&f, 0x3F4), u8(0x00))

	fdc_test_enable(&f)
	testing.expect_value(t, fdc_in(&f, 0x3F4), u8(0x80)) // Idle: RQM

	fdc_out(&f, 0x3F5, 0x10) // VERSION
	testing.expect_value(t, fdc_in(&f, 0x3F4), u8(0xD0)) // Result: RQM|DIO|BUSY
	testing.expect_value(t, fdc_in(&f, 0x3F5), u8(0x90))
	testing.expect_value(t, fdc_in(&f, 0x3F4), u8(0x80)) // back to Idle
}

@(test)
fdc_test_reset_sense_sequence :: proc(t: ^testing.T) {
	f: Fdc
	d: Fdc_Test_Dma
	irqs := 0
	fdc_test_setup(&f, &d, &irqs)

	fdc_out(&f, 0x3F2, 0x08) // enter reset, IRQ enabled
	fdc_out(&f, 0x3F2, 0x0C) // leave reset
	testing.expect_value(t, irqs, 1)

	// 4 polling SENSE INTERRUPTs: ST0 = 0xC0..0xC3, PCN = 0
	for unit in 0 ..< 4 {
		fdc_out(&f, 0x3F5, 0x08)
		testing.expect_value(t, fdc_in(&f, 0x3F4), u8(0xD0))
		testing.expect_value(t, fdc_in(&f, 0x3F5), u8(0xC0 + unit))
		testing.expect_value(t, fdc_in(&f, 0x3F5), u8(0x00))
	}

	// fifth SENSE with no interrupt pending: invalid command
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
	fdc_out(&f, 0x3F5, 0x00) // drive 0
	testing.expect_value(t, irqs, 1)
	testing.expect_value(t, fdc_in(&f, 0x3F4), u8(0x80)) // no result phase

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
	fdc_out(&f, 0x3F5, 0x00) // drive 0, head 0
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
	testing.expect_value(t, res[0] & 0xC0, u8(0x00)) // normal termination
	testing.expect_value(t, res[1], u8(0x00))
	testing.expect_value(t, fdc_in(&f, 0x3F4), u8(0x80))

	ok := true
	for i in 0 ..< 512 {
		if guest[i] != img[i] { ok = false; break }
	}
	testing.expect(t, ok)
	testing.expect_value(t, d.pos, 512) // one sector only: stopped by terminal count
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

	fdc_out(&f, 0x3F5, 0x4A) // READ ID, head 0
	fdc_out(&f, 0x3F5, 0x00)
	testing.expect_value(t, irqs, 1)

	res: [7]u8
	for i in 0 ..< 7 { res[i] = fdc_in(&f, 0x3F5) }
	testing.expect_value(t, res[0] & 0xC0, u8(0x00))
	testing.expect_value(t, res[3], u8(0x00)) // C
	testing.expect_value(t, res[4], u8(0x00)) // H
	testing.expect_value(t, res[5], u8(0x01)) // R
	testing.expect_value(t, res[6], u8(0x02)) // N

	// no media: abnormal termination
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

	testing.expect_value(t, fdc_in(&f, 0x3F7), u8(0x00)) // startup with no media

	img := fdc_test_image()
	defer delete(img)
	testing.expect(t, fdc_set_media(&f, img))
	testing.expect_value(t, fdc_in(&f, 0x3F7), u8(0x80)) // mounting sets DSKCHG

	// the RECALIBRATE step pulse with media present clears it
	fdc_out(&f, 0x3F5, 0x07)
	fdc_out(&f, 0x3F5, 0x00)
	testing.expect_value(t, fdc_in(&f, 0x3F7), u8(0x00))

	fdc_eject_media(&f)
	testing.expect_value(t, fdc_in(&f, 0x3F7), u8(0x80)) // ejecting sets it again
}

@(test)
fdc_test_invalid_command :: proc(t: ^testing.T) {
	f: Fdc
	d: Fdc_Test_Dma
	irqs := 0
	fdc_test_setup(&f, &d, &irqs)
	fdc_test_enable(&f)

	fdc_out(&f, 0x3F5, 0x18) // unimplemented
	testing.expect_value(t, fdc_in(&f, 0x3F4), u8(0xD0))
	testing.expect_value(t, fdc_in(&f, 0x3F5), u8(0x80))
	testing.expect_value(t, fdc_in(&f, 0x3F4), u8(0x80))
}

// Exact SeaBIOS floppy.c sequence for the INT 13 boot-sector read: enable via
// DOR + 4-drive poll, RECALIBRATE + SENSE INTERRUPT, READ ID media sense at
// rate 0, SPECIFY, then READ 0xE6 (MT|MFM|SK) C0/H0/S1 EOT 1 over DMA ch2.
// With media it must succeed end to end; on an empty drive the media sense
// must fail abnormally, which SeaBIOS reports as "could not read the boot
// disk" (the symptom when a GUI Reset dropped the mounted image).
@(test)
fdc_test_seabios_boot_read_sequence :: proc(t: ^testing.T) {
	f: Fdc
	d: Fdc_Test_Dma
	irqs := 0
	fdc_test_setup(&f, &d, &irqs)
	img := fdc_test_image()
	defer delete(img)
	testing.expect(t, fdc_set_media(&f, img))
	defer fdc_eject_media(&f)

	seabios_boot_read :: proc(t: ^testing.T, f: ^Fdc, d: ^Fdc_Test_Dma, irqs: ^int) -> (st0: u8, data_ok: bool) {
		// floppy_enable_controller: DOR reset edge with IRQ enabled
		fdc_out(f, 0x3F2, 0x08)
		fdc_out(f, 0x3F2, 0x0C)
		testing.expect(t, irqs^ >= 1) // reset interrupt reaches the PIC
		for _ in 0 ..< 4 { // drive poll: 4x SENSE INTERRUPT
			fdc_out(f, 0x3F5, 0x08)
			_ = fdc_in(f, 0x3F5)
			_ = fdc_in(f, 0x3F5)
		}
		// floppy_drive_pio: motor A on, drive 0 selected
		fdc_out(f, 0x3F2, 0x1C)
		// floppy_drive_recal: RECALIBRATE + CHECKIRQ
		irqs^ = 0
		fdc_out(f, 0x3F5, 0x07)
		fdc_out(f, 0x3F5, 0x00)
		testing.expect_value(t, irqs^, 1)
		fdc_out(f, 0x3F5, 0x08)
		testing.expect_value(t, fdc_in(f, 0x3F5) & 0xC0, u8(0x00)) // ST0 seek end
		testing.expect_value(t, fdc_in(f, 0x3F5), u8(0x00)) // PCN 0
		// floppy_media_sense -> floppy_drive_readid: rate to CCR, READ ID head 0
		fdc_out(f, 0x3F7, 0x00)
		fdc_out(f, 0x3F5, 0x4A)
		fdc_out(f, 0x3F5, 0x00)
		id: [7]u8
		for i in 0 ..< 7 { id[i] = fdc_in(f, 0x3F5) }
		if id[0] & 0xC0 != 0 { return id[0], false } // media sense failed
		// floppy_drive_specify: SPECIFY 0xAF 0x02, no result phase
		fdc_out(f, 0x3F5, 0x03)
		fdc_out(f, 0x3F5, 0xAF)
		fdc_out(f, 0x3F5, 0x02)
		testing.expect_value(t, fdc_in(f, 0x3F4), u8(0x80)) // back to Idle
		// floppy_read of the boot sector: READ MT|MFM|SK, C0/H0/S1, EOT 1
		irqs^ = 0
		fdc_out(f, 0x3F5, 0xE6)
		for p in ([]u8{0x00, 0x00, 0x00, 0x01, 0x02, 0x01, 0x1B, 0xFF}) {
			fdc_out(f, 0x3F5, p)
		}
		testing.expect_value(t, irqs^, 1)
		res: [7]u8
		for i in 0 ..< 7 { res[i] = fdc_in(f, 0x3F5) }
		testing.expect_value(t, fdc_in(f, 0x3F4), u8(0x80)) // result frame is 7 bytes
		return res[0], d.pos == 512
	}

	guest := make([]u8, 4096)
	defer delete(guest)
	d.ram = guest
	d.pos = 0
	d.limit = 512

	st0, data_ok := seabios_boot_read(t, &f, &d, &irqs)
	testing.expect_value(t, st0 & 0xC0, u8(0x00))
	testing.expect(t, data_ok)
	ok := true
	for i in 0 ..< 512 {
		if guest[i] != img[i] { ok = false; break }
	}
	testing.expect(t, ok)

	// empty drive (what a Reset used to leave behind): sequence must fail
	// abnormally instead of succeeding or hanging
	fdc_eject_media(&f)
	d.pos = 0
	st0, data_ok = seabios_boot_read(t, &f, &d, &irqs)
	testing.expect_value(t, st0 & 0xC0, u8(0x40)) // abnormal termination
	testing.expect(t, !data_ok)
}

// image with every byte derived from its offset, for multi-sector checks
fdc_test_image_full :: proc() -> []u8 {
	img := make([]u8, FLOPPY_144_SIZE)
	for i in 0 ..< len(img) { img[i] = u8(i * 31 >> 4) }
	return img
}

fdc_test_expect_sectors :: proc(t: ^testing.T, guest, img: []u8, c, h, s, n: int) {
	off, _ := floppy_img_offset(c, h, s)
	ok := true
	for i in 0 ..< n * FLOPPY_SECTOR {
		if guest[i] != img[off + i] { ok = false; break }
	}
	testing.expect(t, ok)
}

// Win98 IO.SYS pattern via SeaBIOS: full-track READ e6 C50/H1/S1 EOT 18.
// All 18 sectors must reach memory and the result frame must hold the next
// address after the MT head-1 EOT wrap: C+1, H 0, R 1 (82077AA result table).
@(test)
fdc_test_read_full_track :: proc(t: ^testing.T) {
	f: Fdc
	d: Fdc_Test_Dma
	irqs := 0
	fdc_test_setup(&f, &d, &irqs)
	img := fdc_test_image_full()
	defer delete(img)
	testing.expect(t, fdc_set_media(&f, img))
	defer fdc_eject_media(&f)
	fdc_test_enable(&f)

	guest := make([]u8, 32 * 1024)
	defer delete(guest)
	d.ram = guest
	d.pos = 0
	d.limit = 18 * 512

	fdc_out(&f, 0x3F5, 0xE6)
	for p in ([]u8{0x04, 50, 1, 1, 2, 18, 0x1B, 0xFF}) { fdc_out(&f, 0x3F5, p) }

	res: [7]u8
	for i in 0 ..< 7 { res[i] = fdc_in(&f, 0x3F5) }
	testing.expect_value(t, res[0] & 0xC0, u8(0x00))
	testing.expect_value(t, res[3], u8(51)) // C: next cylinder
	testing.expect_value(t, res[4], u8(0))  // H: back to head 0
	testing.expect_value(t, res[5], u8(1))  // R: sector 1
	testing.expect_value(t, d.pos, 18 * 512)
	fdc_test_expect_sectors(t, guest, img, 50, 1, 1, 18)
}

// READ that spans the end of head 0 with MT: continue at head 1 sector 1 of
// the same cylinder (SeaBIOS passes EOT = sector+count-1, here 20 > SPT).
@(test)
fdc_test_read_mt_head_wrap :: proc(t: ^testing.T) {
	f: Fdc
	d: Fdc_Test_Dma
	irqs := 0
	fdc_test_setup(&f, &d, &irqs)
	img := fdc_test_image_full()
	defer delete(img)
	testing.expect(t, fdc_set_media(&f, img))
	defer fdc_eject_media(&f)
	fdc_test_enable(&f)

	guest := make([]u8, 32 * 1024)
	defer delete(guest)
	d.ram = guest
	d.pos = 0
	d.limit = 4 * 512

	// C0/H0/S17 .. C0/H1/S2
	fdc_out(&f, 0x3F5, 0xE6)
	for p in ([]u8{0x00, 0, 0, 17, 2, 20, 0x1B, 0xFF}) { fdc_out(&f, 0x3F5, p) }

	res: [7]u8
	for i in 0 ..< 7 { res[i] = fdc_in(&f, 0x3F5) }
	testing.expect_value(t, res[0] & 0xC0, u8(0x00))
	testing.expect_value(t, res[3], u8(0)) // C unchanged
	testing.expect_value(t, res[4], u8(1)) // H: wrapped to head 1
	testing.expect_value(t, res[5], u8(3)) // R: next sector
	testing.expect_value(t, d.pos, 4 * 512)
	fdc_test_expect_sectors(t, guest, img, 0, 0, 17, 2)
	off, _ := floppy_img_offset(0, 1, 1)
	ok := true
	for i in 0 ..< 2 * 512 {
		if guest[2 * 512 + i] != img[off + i] { ok = false; break }
	}
	testing.expect(t, ok)
}

// EOT reached on head 1 with DMA count still open: end of cylinder, abnormal
// termination with ST1 EN (0x80) instead of an implied cylinder seek.
@(test)
fdc_test_read_end_of_cylinder :: proc(t: ^testing.T) {
	f: Fdc
	d: Fdc_Test_Dma
	irqs := 0
	fdc_test_setup(&f, &d, &irqs)
	img := fdc_test_image_full()
	defer delete(img)
	testing.expect(t, fdc_set_media(&f, img))
	defer fdc_eject_media(&f)
	fdc_test_enable(&f)

	guest := make([]u8, 32 * 1024)
	defer delete(guest)
	d.ram = guest
	d.pos = 0
	d.limit = 8 * 512 // more than the track can supply

	fdc_out(&f, 0x3F5, 0xE6)
	for p in ([]u8{0x04, 3, 1, 18, 2, 18, 0x1B, 0xFF}) { fdc_out(&f, 0x3F5, p) }

	res: [7]u8
	for i in 0 ..< 7 { res[i] = fdc_in(&f, 0x3F5) }
	testing.expect_value(t, res[0] & 0xC0, u8(0x40)) // abnormal
	testing.expect_value(t, res[1] & 0x80, u8(0x80)) // ST1 EN
	testing.expect_value(t, d.pos, 512) // the one sector still transferred
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
