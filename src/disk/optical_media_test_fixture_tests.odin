// SPDX-License-Identifier: GPL-3.0-only
package disk

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:testing"
import "core:time"

disc_image_test_path :: proc(name: string) -> string {
	base, _ := os.temp_directory(context.temp_allocator)
	path, _ := filepath.join(
		{base, fmt.tprintf("retvrn99_disc_%d_%s", time.now()._nsec, name)},
		context.temp_allocator,
	)
	return path
}

cdrom_test_iso :: proc(t: ^testing.T) -> string {
	path := disc_image_test_path("atapi.iso")
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
