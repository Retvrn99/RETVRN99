// SPDX-License-Identifier: GPL-3.0-only
package fat32

import "core:os"
import "core:testing"

@(test)
volume_test_close_releases_owned_state :: proc(t: ^testing.T) {
	allocator := context.allocator
	context.allocator = context.temp_allocator
	dir := fat32_test_fixture(t)
	context.allocator = allocator
	defer os.remove_all(dir)

	v := volume_open(dir, 2048)
	testing.expect(t, v != nil)
	if v == nil {
		return
	}

	fsinfo := make_fsinfo()
	fsinfo[488] = 0x34
	testing.expect(t, volume_write(v, PART_START_LBA + 1, fsinfo[:]))

	cluster := v.alloc.next_free
	data: [SECTOR]u8
	data[0] = 0xA5
	testing.expect(t, volume_write(v, journal_test_data_lba(v, cluster), data[:]))
	v.journal.shadow_fat[cluster] = 0x0FFFFFFF
	v.journal.claimed[cluster] = Claim{v.alloc.root.children[0], 0}
	append(&v.journal.pending_deletes, Pending_Delete{v.alloc.root.children[0]})
	append(&v.journal.pending_extends, v.alloc.root)

	volume_close(v)
	volume_close(nil)
}
