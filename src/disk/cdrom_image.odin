// SPDX-License-Identifier: GPL-3.0-only
package disk

import "core:os"

CDROM_SECTOR_SIZE :: 2048

Cdrom_Image :: struct {
	file:        ^os.File,
	block_count: u32,
}

cdrom_image_mount :: proc(image: ^Cdrom_Image, path: string) -> bool {
	if image == nil {
		return false
	}
	f, oerr := os.open(path, {.Read})
	if oerr != nil {
		return false
	}
	size, serr := os.file_size(f)
	if serr != nil || size < 17 * CDROM_SECTOR_SIZE || size % CDROM_SECTOR_SIZE != 0 {
		os.close(f)
		return false
	}
	blocks := u64(size / CDROM_SECTOR_SIZE)
	if blocks > u64(max(u32)) {
		os.close(f)
		return false
	}
	pvd: [CDROM_SECTOR_SIZE]u8
	if !cdrom_image_read_file(f, 16, pvd[:]) || string(pvd[1:6]) != "CD001" || pvd[6] != 1 {
		os.close(f)
		return false
	}
	cdrom_image_eject(image)
	image.file = f
	image.block_count = u32(blocks)
	return true
}

cdrom_image_eject :: proc(image: ^Cdrom_Image) {
	if image == nil {
		return
	}
	if image.file != nil {
		os.close(image.file)
	}
	image^ = {}
}

cdrom_image_present :: proc(image: ^Cdrom_Image) -> bool {
	return image != nil && image.file != nil
}

cdrom_image_read :: proc(image: ^Cdrom_Image, lba: u32, out: []u8) -> bool {
	if !cdrom_image_present(image) || len(out) == 0 || len(out) % CDROM_SECTOR_SIZE != 0 {
		return false
	}
	blocks := u64(len(out) / CDROM_SECTOR_SIZE)
	if u64(lba) + blocks > u64(image.block_count) {
		return false
	}
	return cdrom_image_read_file(image.file, lba, out)
}

@(private = "file")
cdrom_image_read_file :: proc(f: ^os.File, lba: u32, out: []u8) -> bool {
	offset := i64(lba) * CDROM_SECTOR_SIZE
	total := 0
	for total < len(out) {
		n, err := os.read_at(f, out[total:], offset + i64(total))
		if n <= 0 || err != nil && total + n < len(out) {
			return false
		}
		total += n
	}
	return true
}
