// SPDX-License-Identifier: GPL-3.0-only
package main

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "profile"

@(test)
media_persistence_test_missing_only_reconciliation :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root, root_error := os.temp_directory(context.temp_allocator)
	testing.expect(t, root_error == nil)
	dir, dir_error := os.make_directory_temp(root, "retvrn99_media_*", context.temp_allocator)
	testing.expect(t, dir_error == nil)
	defer os.remove_all(dir)
	existing, _ := filepath.join({dir, "disk.img"}, context.temp_allocator)
	missing, _ := filepath.join({dir, "missing.iso"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(existing, "image") == nil)
	settings := profile.settings_default()
	defer profile.settings_destroy(&settings)
	settings.floppy_path = strings.clone(existing)
	settings.cdrom_path = strings.clone(missing)
	testing.expect_value(t, media_settings_reconcile_missing(&settings, .Floppy), Media_Path_Status.Present)
	testing.expect_value(t, settings.floppy_path, existing)
	testing.expect_value(t, media_settings_reconcile_missing(&settings, .Cdrom), Media_Path_Status.Missing)
	testing.expect_value(t, settings.cdrom_path, "")
}

@(test)
media_persistence_test_only_successful_user_results_change_settings :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	shared: Shared
	settings := profile.settings_default()
	defer profile.settings_destroy(&settings)
	seen: u64

	media_state_publish_result(&shared, .Cdrom, false, false, "", "bad.iso", "unreadable", true)
	failed := media_state_snapshot(&shared, .Cdrom, context.temp_allocator)
	testing.expect(t, !media_settings_consume(&settings, .Cdrom, &failed, &seen))
	testing.expect_value(t, settings.cdrom_path, "")

	media_state_publish_result(&shared, .Cdrom, true, true, "good.iso", "", "", true)
	mounted := media_state_snapshot(&shared, .Cdrom, context.temp_allocator)
	testing.expect(t, media_settings_consume(&settings, .Cdrom, &mounted, &seen))
	testing.expect_value(t, settings.cdrom_path, "good.iso")

	media_state_publish_result(&shared, .Cdrom, true, true, "install.iso", "", "", false)
	override := media_state_snapshot(&shared, .Cdrom, context.temp_allocator)
	testing.expect(t, !media_settings_consume(&settings, .Cdrom, &override, &seen))
	testing.expect_value(t, settings.cdrom_path, "good.iso")
	shared_media_destroy(&shared)
}

@(test)
media_persistence_test_failed_replacement_preserves_actual_mount :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	shared: Shared
	media_state_publish_result(&shared, .Floppy, true, true, "first.img", "", "", true)
	media_state_publish_result(&shared, .Floppy, false, false, "", "second.img", "invalid", true)
	state := media_state_snapshot(&shared, .Floppy, context.temp_allocator)
	testing.expect(t, state.mounted)
	testing.expect_value(t, state.actual_path, "first.img")
	testing.expect_value(t, state.requested_path, "second.img")
	testing.expect(t, !state.unavailable)
	shared_media_destroy(&shared)
}

@(test)
media_persistence_test_existing_invalid_cd_is_not_supported :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root, root_error := os.temp_directory(context.temp_allocator)
	testing.expect(t, root_error == nil)
	dir, dir_error := os.make_directory_temp(root, "retvrn99_cdrom_*", context.temp_allocator)
	testing.expect(t, dir_error == nil)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "not-a-disc.iso"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(path, "not a supported image") == nil)
	testing.expect(t, !cdrom_path_supported(path))
}
