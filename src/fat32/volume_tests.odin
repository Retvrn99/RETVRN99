// SPDX-License-Identifier: GPL-3.0-only
package fat32

import "core:os"
import "core:testing"

Volume_Fail_Test :: struct {
	count:         int,
	first_message: bool,
}

@(test)
volume_test_failure_notification_is_one_shot :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, v := decode_test_open(t)
	defer os.remove_all(dir)
	if v == nil {return}
	defer volume_discard(v)
	failure: Volume_Fail_Test
	v.fail_ctx = &failure
	v.on_fail = proc(ctx: rawptr, msg: string) {
		state := (^Volume_Fail_Test)(ctx)
		state.count += 1
		state.first_message = msg == "first failure"
	}

	volume_fail(v, "first failure")
	volume_fail(v, "secondary failure")

	testing.expect(t, v.frozen)
	testing.expect_value(t, failure.count, 1)
	testing.expect(t, failure.first_message)
}

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

	testing.expect(t, volume_close(v))
	testing.expect(t, volume_close(nil))
}
