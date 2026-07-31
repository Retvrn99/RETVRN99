// SPDX-License-Identifier: GPL-3.0-only
package profile

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

Profile_Lock_Race_Worker :: struct {
	root:       string,
	session_id: string,
	ready:      ^sync.Sema,
	start:      ^sync.Sema,
	done:       ^sync.Sema,
	lock:       Lock,
	diagnostic: Lock_Diagnostic,
}

profile_lock_race_worker :: proc(worker: ^Profile_Lock_Race_Worker) {
	sync.sema_post(worker.ready)
	sync.sema_wait(worker.start)
	worker.diagnostic = lock_acquire(&worker.lock, worker.root, worker.session_id)
	sync.sema_post(worker.done)
}

@(test)
profile_test_lock_rejects_second_owner_and_releases :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	base, _ := os.temp_directory(context.temp_allocator)
	root, _ := os.make_directory_temp(base, "retvrn99_profile_lock_*", context.temp_allocator)
	defer os.remove_all(root)
	first, second: Lock
	testing.expect_value(t, lock_acquire(&first, root, "first"), Lock_Diagnostic.None)
	path := strings.clone(first.path)
	defer delete(path)
	testing.expect_value(t, lock_acquire(&second, root, "second"), Lock_Diagnostic.Owned)
	// The refusal has to name the holder and the file it lives in.
	testing.expect_value(t, second.owner_pid, u32(os.get_pid()))
	testing.expect(t, strings.has_suffix(second.path, PROFILE_LOCK_FILE), second.path)
	lock_release(&second)
	third: Lock
	testing.expect_value(t, lock_acquire(&third, root, "third"), Lock_Diagnostic.Owned)
	lock_release(&third)
	lock_release(&first)
	testing.expect(t, !os.exists(path))
	testing.expect_value(t, lock_acquire(&second, root, "second"), Lock_Diagnostic.None)
	lock_release(&second)
}

@(test)
profile_test_lock_release_preserves_replacement_path :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	base, _ := os.temp_directory(context.temp_allocator)
	root, _ := os.make_directory_temp(base, "retvrn99_profile_replacement_*", context.temp_allocator)
	defer os.remove_all(root)
	lock: Lock
	testing.expect_value(t, lock_acquire(&lock, root, "owner"), Lock_Diagnostic.None)
	path := strings.clone(lock.path)
	defer delete(path)
	moved := strings.concatenate({path, ".moved"})
	defer delete(moved)
	testing.expect(t, os.rename(path, moved) == nil)
	testing.expect(t, os.write_entire_file(path, "replacement") == nil)
	lock_release(&lock)
	data, read_error := os.read_entire_file(path, context.temp_allocator)
	defer delete(data, context.temp_allocator)
	testing.expect(t, read_error == nil)
	testing.expect_value(t, string(data), "replacement")
}

@(test)
profile_test_native_guard_survives_record_detachment :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	base, _ := os.temp_directory(context.temp_allocator)
	root, _ := os.make_directory_temp(base, "retvrn99_profile_guard_*", context.temp_allocator)
	defer os.remove_all(root)
	first, second: Lock
	testing.expect_value(t, lock_acquire(&first, root, "first"), Lock_Diagnostic.None)
	moved := strings.concatenate({first.path, ".moved"})
	defer delete(moved)
	testing.expect(t, os.rename(first.path, moved) == nil)
	testing.expect_value(t, lock_acquire(&second, root, "second"), Lock_Diagnostic.Owned)
	lock_release(&second)
	lock_release(&first)
	third: Lock
	testing.expect_value(t, lock_acquire(&third, root, "third"), Lock_Diagnostic.None)
	lock_release(&third)
}

profile_lock_test_expect_one_owner :: proc(t: ^testing.T, root: string) {
	ready, start, done: sync.Sema
	workers := [2]Profile_Lock_Race_Worker {
		{root = root, session_id = "first", ready = &ready, start = &start, done = &done},
		{root = root, session_id = "second", ready = &ready, start = &start, done = &done},
	}
	threads := [2]^thread.Thread {
		thread.create_and_start_with_poly_data(&workers[0], profile_lock_race_worker),
		thread.create_and_start_with_poly_data(&workers[1], profile_lock_race_worker),
	}
	defer for worker in threads {thread.destroy(worker)}
	testing.expect(t, sync.sema_wait_with_timeout(&ready, time.Second))
	testing.expect(t, sync.sema_wait_with_timeout(&ready, time.Second))
	sync.sema_post(&start)
	sync.sema_post(&start)
	testing.expect(t, sync.sema_wait_with_timeout(&done, time.Second))
	testing.expect(t, sync.sema_wait_with_timeout(&done, time.Second))
	owners := 0
	blocked := 0
	for worker in &workers {
		if worker.diagnostic == .None {owners += 1}
		if worker.diagnostic == .Owned {blocked += 1}
	}
	testing.expect_value(t, owners, 1)
	testing.expect_value(t, blocked, 1)
	for index in 0 ..< len(workers) {lock_release(&workers[index].lock)}
}

@(test)
profile_test_lock_concurrent_acquisition_has_one_owner :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	base, _ := os.temp_directory(context.temp_allocator)
	root, _ := os.make_directory_temp(base, "retvrn99_profile_race_*", context.temp_allocator)
	defer os.remove_all(root)
	profile_lock_test_expect_one_owner(t, root)
}

@(test)
profile_test_lock_concurrent_stale_reclamation_has_one_owner :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	base, _ := os.temp_directory(context.temp_allocator)
	root, _ := os.make_directory_temp(base, "retvrn99_profile_stale_race_*", context.temp_allocator)
	defer os.remove_all(root)
	path, _ := filepath.join({root, PROFILE_LOCK_FILE}, context.temp_allocator)
	record := fmt.tprintf("%d\nstale\n1\n", os.get_pid())
	testing.expect(t, os.write_entire_file(path, record) == nil)
	profile_lock_test_expect_one_owner(t, root)
}

@(test)
profile_test_lock_records_owner_start_token :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	base, _ := os.temp_directory(context.temp_allocator)
	root, _ := os.make_directory_temp(base, "retvrn99_profile_owner_*", context.temp_allocator)
	defer os.remove_all(root)
	lock: Lock
	testing.expect_value(t, lock_acquire(&lock, root, "owner"), Lock_Diagnostic.None)
	owner := lock_owner(lock.path)
	testing.expect_value(t, owner.pid, u32(os.get_pid()))
	testing.expect(t, owner.start != 0, "no start token recorded for the owning process")
	lock_release(&lock)
}

@(test)
profile_test_lock_treats_recycled_pid_as_stale :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	base, _ := os.temp_directory(context.temp_allocator)
	root, _ := os.make_directory_temp(base, "retvrn99_profile_recycled_*", context.temp_allocator)
	defer os.remove_all(root)
	path, _ := filepath.join({root, PROFILE_LOCK_FILE}, context.temp_allocator)
	// A live pid whose recorded start token belongs to an incarnation that is
	// gone. This is what pid reuse looks like, and it must not lock us out.
	record := fmt.tprintf("%d\nrecycled\n1\n", os.get_pid())
	testing.expect(t, os.write_entire_file(path, record) == nil)
	lock: Lock
	testing.expect_value(t, lock_acquire(&lock, root, "replacement"), Lock_Diagnostic.None)
	lock_release(&lock)
}

@(test)
profile_test_lock_fails_closed_for_unknown_owner :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	base, _ := os.temp_directory(context.temp_allocator)
	root, _ := os.make_directory_temp(base, "retvrn99_profile_unknown_*", context.temp_allocator)
	defer os.remove_all(root)
	path, _ := filepath.join({root, PROFILE_LOCK_FILE}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(path, "incomplete") == nil)
	lock: Lock
	testing.expect_value(t, lock_acquire(&lock, root, "replacement"), Lock_Diagnostic.Owner_Unknown)
	lock_release(&lock)
	testing.expect(t, os.exists(path))
}

@(test)
profile_test_lock_fails_closed_for_live_legacy_owner :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	base, _ := os.temp_directory(context.temp_allocator)
	root, _ := os.make_directory_temp(base, "retvrn99_profile_legacy_*", context.temp_allocator)
	defer os.remove_all(root)
	path, _ := filepath.join({root, PROFILE_LOCK_FILE}, context.temp_allocator)
	record := fmt.tprintf("%d\nlegacy\n", os.get_pid())
	testing.expect(t, os.write_entire_file(path, record) == nil)
	lock: Lock
	testing.expect_value(t, lock_acquire(&lock, root, "replacement"), Lock_Diagnostic.Owned)
	lock_release(&lock)
	testing.expect(t, os.exists(path))
}

@(test)
profile_test_lock_rejects_failed_identity_capture_before_publication :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	base, _ := os.temp_directory(context.temp_allocator)
	root, _ := os.make_directory_temp(base, "retvrn99_profile_identity_*", context.temp_allocator)
	defer os.remove_all(root)
	lock: Lock
	testing.expect_value(
		t,
		lock_acquire_with_identity(&lock, root, "identity", u32(os.get_pid()), 0, false),
		Lock_Diagnostic.Identity_Failed,
	)
	path, _ := filepath.join({root, PROFILE_LOCK_FILE}, context.temp_allocator)
	testing.expect(t, !os.exists(path))
}

@(test)
profile_test_lock_preserves_stale_owner_record :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	base, _ := os.temp_directory(context.temp_allocator)
	root, _ := os.make_directory_temp(base, "retvrn99_profile_stale_*", context.temp_allocator)
	defer os.remove_all(root)
	path, _ := filepath.join({root, PROFILE_LOCK_FILE}, context.temp_allocator)
	record := fmt.tprintf("%d\nstale\n1\n", os.get_pid())
	testing.expect(t, os.write_entire_file(path, record) == nil)
	lock: Lock
	testing.expect_value(t, lock_acquire(&lock, root, "replacement"), Lock_Diagnostic.None)
	entries, read_error := os.read_all_directory_by_path(root, context.temp_allocator)
	if testing.expect(t, read_error == nil) {
		stale_found := false
		for entry in entries {
			if strings.has_prefix(entry.name, PROFILE_LOCK_FILE + ".stale.") {
				stale_found = true
				// The record is named from the owner pid and a nanosecond
				// reading and nothing else. Formatting a struct with a numeric
				// verb would leave the verb error text in the filename here.
				suffix := entry.name[len(PROFILE_LOCK_FILE + ".stale."):]
				plain := strings.count(suffix, ".") == 1
				for character in suffix {
					plain =
						plain &&
						(character == '.' ||
								character == '-' ||
								(character >= '0' && character <= '9'))
				}
				testing.expect(t, plain, entry.name)
			}
			os.file_info_delete(entry, context.temp_allocator)
		}
		testing.expect(t, stale_found)
	}
	lock_release(&lock)
}
