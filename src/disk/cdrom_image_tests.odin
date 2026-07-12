// SPDX-License-Identifier: GPL-3.0-only
package disk

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"

cdrom_test_iso :: proc(t: ^testing.T) -> string {
	base, err := os.temp_directory(context.temp_allocator)
	testing.expect(t, err == nil)
	path, _ := filepath.join(
		{base, fmt.tprintf("retvrn99_cdrom_%d.iso", time.now()._nsec)},
		context.temp_allocator,
	)
	data := make([]u8, 24 * CDROM_SECTOR_SIZE, context.temp_allocator)
	pvd := data[16 * CDROM_SECTOR_SIZE:][:CDROM_SECTOR_SIZE]
	pvd[0] = 1
	copy(pvd[1:6], "CD001")
	pvd[6] = 1
	for block in 17 ..< 24 {
		data[block * CDROM_SECTOR_SIZE] = u8(block)
		data[block * CDROM_SECTOR_SIZE + 1] = u8(block + 1)
	}
	testing.expect(t, os.write_entire_file(path, data) == nil)
	return path
}

@(test)
cdrom_image_test_mount_read_and_atomic_reject :: proc(t: ^testing.T) {
	path := cdrom_test_iso(t)
	defer os.remove(path)
	image: Cdrom_Image
	testing.expect(t, cdrom_image_mount(&image, path))
	defer cdrom_image_eject(&image)
	testing.expect_value(t, image.block_count, u32(24))

	sector: [CDROM_SECTOR_SIZE]u8
	testing.expect(t, cdrom_image_read(&image, 18, sector[:]))
	testing.expect_value(t, sector[0], u8(18))
	testing.expect(t, !cdrom_image_read(&image, 24, sector[:]))

	bad_path := strings.concatenate({path, ".bad"}, context.temp_allocator)
	defer os.remove(bad_path)
	testing.expect(t, os.write_entire_file(bad_path, make([]u8, 17 * CDROM_SECTOR_SIZE, context.temp_allocator)) == nil)
	testing.expect(t, !cdrom_image_mount(&image, bad_path))
	testing.expect(t, cdrom_image_read(&image, 18, sector[:]))
}

@(test)
cdrom_image_test_nil_and_alignment_rejected :: proc(t: ^testing.T) {
	image: Cdrom_Image
	buf: [CDROM_SECTOR_SIZE - 1]u8
	testing.expect(t, !cdrom_image_mount(nil, "missing.iso"))
	testing.expect(t, !cdrom_image_read(&image, 0, buf[:]))
	cdrom_image_eject(nil)
}
