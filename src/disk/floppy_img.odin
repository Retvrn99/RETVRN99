// SPDX-License-Identifier: GPL-3.0-only
package disk

import "core:log"

FLOPPY_144_SIZE :: 1_474_560
FLOPPY_CYLS :: 80
FLOPPY_HEADS :: 2
FLOPPY_SPT :: 18
FLOPPY_SECTOR :: 512

Floppy_Img :: struct {
	data:  []u8,
	dirty: bool,
}

// copies the .img into memory; 1.44M geometries only
floppy_img_load :: proc(fi: ^Floppy_Img, raw: []u8, allocator := context.allocator) -> bool {
	if len(raw) != FLOPPY_144_SIZE { return false }
	fi.data = make([]u8, FLOPPY_144_SIZE, allocator)
	copy(fi.data, raw)
	fi.dirty = false
	return true
}

// writes stay in memory only: persisting on eject is deferred until after M1
floppy_img_eject :: proc(fi: ^Floppy_Img) {
	if fi.dirty {
		log.warn("floppy ejected with unpersisted writes; discarding them")
	}
	delete(fi.data)
	fi^ = {}
}

floppy_img_offset :: proc(c, h, s: int) -> (off: int, ok: bool) {
	if c < 0 || c >= FLOPPY_CYLS || h < 0 || h >= FLOPPY_HEADS || s < 1 || s > FLOPPY_SPT {
		return 0, false
	}
	return ((c * FLOPPY_HEADS + h) * FLOPPY_SPT + s - 1) * FLOPPY_SECTOR, true
}

floppy_img_sector :: proc(fi: ^Floppy_Img, c, h, s: int) -> ([]u8, bool) {
	off, ok := floppy_img_offset(c, h, s)
	if !ok || fi.data == nil { return nil, false }
	return fi.data[off:off + FLOPPY_SECTOR], true
}
