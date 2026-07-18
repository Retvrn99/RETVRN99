// SPDX-License-Identifier: GPL-3.0-only
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "fat32session"
import "host"

hard_drive_controller_test_root :: proc(t: ^testing.T) -> (string, bool) {
	base, base_error := os.temp_directory(context.temp_allocator)
	if !testing.expect(t, base_error == nil) {return "", false}
	root, root_error := os.make_directory_temp(
		base,
		"retvrn99_hard_drive_controller_*",
		context.allocator,
	)
	return root, testing.expect(t, root_error == nil)
}

hard_drive_controller_test_find_row :: proc(
	controller: ^Hard_Drive_Controller,
	name: string,
) -> (^host.Hard_Drive_Browser_Row, bool) {
	for &row in controller.rows {
		if row.name == name {return &row, true}
	}
	return nil, false
}

hard_drive_controller_test_run :: proc(
	t: ^testing.T,
	controller: ^Hard_Drive_Controller,
) -> bool {
	for _ in 0 ..< 10000 {
		if controller.operation == .None {return true}
		hard_drive_controller_step(controller)
		if controller.model.diagnostic != "" {return false}
	}
	fmt.printfln(
		"controller stalled: operation=%v ready=%v progress=%v %d/%d cancellable=%v",
		controller.operation,
		hard_drive_controller_ready(controller),
		controller.model.progress.active,
		controller.model.progress.completed,
		controller.model.progress.total,
		controller.model.progress.cancellable,
	)
	return testing.expect(t, false)
}

@(test)
hard_drive_controller_test_typed_alias_collision_opens_conflict_prompt :: proc(t: ^testing.T) {
	err := fat32session.error_make(
		.Name_Collision,
		false,
		.Not_Started,
		0,
		0,
		"generated 8.3 alias collides with an existing entry",
	)
	testing.expect(t, hard_drive_controller_error_is_collision(&err))
}

@(test)
hard_drive_controller_test_formats_fat_local_timestamp :: proc(t: ^testing.T) {
	date := u16((2026 - 1980) << 9 | 7 << 5 | 16)
	clock := u16(3 << 11 | 4 << 5 | 3)
	testing.expect_value(
		t,
		hard_drive_controller_fat_timestamp(date, clock),
		"2026-07-16 03:04:06",
	)
	testing.expect_value(t, hard_drive_controller_fat_timestamp(0, 0), "")
}

Hard_Drive_Controller_Apply_Failure_State :: struct {
	apply_active: bool,
	retain_calls: int,
}

Hard_Drive_Controller_Completed_Edit_State :: struct {
	apply_active: bool,
	operation_calls: int,
	retain_calls: int,
	destroy_calls: int,
}

hard_drive_controller_completed_edit_session :: proc(
	state: ^Hard_Drive_Controller_Completed_Edit_State,
) -> ^fat32session.Edit_Session {
	session := new(fat32session.Edit_Session)
	session.ctx = state
	session.operations = fat32session.Edit_Operations {
		ready = proc(_: rawptr) -> bool {return true},
		begin_apply = proc(ctx: rawptr) -> (
			fat32session.Edit_Apply_Progress,
			fat32session.Session_Error,
		) {
			state := (^Hard_Drive_Controller_Completed_Edit_State)(ctx)
			state.apply_active = true
			return {state = .Ready, total_units = 1, cancellable = true}, {}
		},
		step_apply = proc(ctx: rawptr) -> (
			fat32session.Edit_Apply_Progress,
			fat32session.Session_Error,
		) {
			state := (^Hard_Drive_Controller_Completed_Edit_State)(ctx)
			state.operation_calls += 1
			return {state = .Complete, completed_units = 1, total_units = 1},
			       fat32session.error_make(
				       .Wal_IO,
				       true,
				       .Completed,
				       0,
				       0,
				       "injected completed Apply cleanup warning",
			       )
		},
		discard = proc(ctx: rawptr) -> fat32session.Session_Error {
			state := (^Hard_Drive_Controller_Completed_Edit_State)(ctx)
			state.operation_calls += 1
			return fat32session.error_make(
				.Wal_IO,
				true,
				.Completed,
				0,
				0,
				"injected completed Discard cleanup warning",
			)
		},
		close_retain = proc(ctx: rawptr) -> fat32session.Session_Error {
			state := (^Hard_Drive_Controller_Completed_Edit_State)(ctx)
			state.retain_calls += 1
			return {}
		},
		destroy = proc(ctx: rawptr) {
			state := (^Hard_Drive_Controller_Completed_Edit_State)(ctx)
			state.destroy_calls += 1
		},
	}
	return session
}

@(test)
hard_drive_controller_test_apply_failure_retains_evidence_and_blocks_start :: proc(
	t: ^testing.T,
) {
	state: Hard_Drive_Controller_Apply_Failure_State
	session := new(fat32session.Edit_Session)
	session.ctx = &state
	session.operations = fat32session.Edit_Operations {
		ready = proc(ctx: rawptr) -> bool {
			state := (^Hard_Drive_Controller_Apply_Failure_State)(ctx)
			return !state.apply_active
		},
		begin_apply = proc(ctx: rawptr) -> (
			fat32session.Edit_Apply_Progress,
			fat32session.Session_Error,
		) {
			state := (^Hard_Drive_Controller_Apply_Failure_State)(ctx)
			state.apply_active = true
			return {
				state       = .Ready,
				total_units = 64,
				cancellable = true,
			}, {}
		},
		step_apply = proc(ctx: rawptr) -> (
			fat32session.Edit_Apply_Progress,
			fat32session.Session_Error,
		) {
			return {}, fat32session.error_make(
				.Image_IO,
				false,
				.Retained,
				0,
				0,
				"injected durable Apply failure",
			)
		},
		close_retain = proc(ctx: rawptr) -> fat32session.Session_Error {
			state := (^Hard_Drive_Controller_Apply_Failure_State)(ctx)
			state.retain_calls += 1
			return {}
		},
	}
	controller: Hard_Drive_Controller
	hard_drive_controller_init(&controller, .In_Process)
	controller.session = session
	controller.model.visible = true
	controller.model.pending_changes = 1
	controller.pending_operations = 1

	testing.expect(t, hard_drive_controller_handle(&controller, {kind = .Apply}))
	hard_drive_controller_step(&controller)
	testing.expect(t, controller.model.progress.cancellable)
	hard_drive_controller_step(&controller)
	testing.expect_value(t, state.retain_calls, 1)
	testing.expect(t, controller.session == nil)
	testing.expect(t, controller.model.visible && controller.model.read_only)
	testing.expect(t, strings.contains(controller.model.diagnostic, "recovery evidence"))
	testing.expect(t, !hard_drive_controller_prepare_machine_start(&controller))
	testing.expect(t, hard_drive_controller_handle(&controller, {kind = .Close}))
	testing.expect(t, !controller.model.visible)
	hard_drive_controller_destroy(&controller)
}

@(test)
hard_drive_controller_test_completed_apply_and_discard_consume_sessions :: proc(
	t: ^testing.T,
) {
	apply_modes := [?]bool{true, false}
	for apply_changes in apply_modes {
		state: Hard_Drive_Controller_Completed_Edit_State
		controller: Hard_Drive_Controller
		hard_drive_controller_init(&controller, .In_Process)
		controller.session = hard_drive_controller_completed_edit_session(&state)
		controller.model.visible = true
		controller.model.pending_changes = 1
		controller.pending_operations = 1
		if apply_changes {
			testing.expect(t, hard_drive_controller_handle(&controller, {kind = .Apply}))
			hard_drive_controller_step(&controller)
			hard_drive_controller_step(&controller)
		} else {
			testing.expect(t, hard_drive_controller_handle(&controller, {kind = .Discard}))
		}
		testing.expect_value(t, state.operation_calls, 1)
		testing.expect_value(t, state.destroy_calls, 1)
		testing.expect_value(t, state.retain_calls, 0)
		testing.expect(t, controller.session == nil)
		testing.expect_value(t, controller.operation, Hard_Drive_Controller_Operation.None)
		testing.expect_value(t, controller.model.pending_changes, 0)
		testing.expect(t, controller.model.visible && controller.model.read_only)
		testing.expect(t, strings.contains(controller.model.diagnostic, "cleanup"))
		testing.expect(t, hard_drive_controller_handle(&controller, {kind = .Close}))
		testing.expect(t, !controller.model.visible)
		hard_drive_controller_destroy(&controller)
	}
}

@(test)
hard_drive_controller_test_stopped_open_pagination_apply_and_discard :: proc(t: ^testing.T) {
	root, ok := hard_drive_controller_test_root(t)
	if !ok {return}
	defer delete(root)
	defer os.remove_all(root)
	image_path := test_image_create(t, root, "controller.img")
	if image_path == "" {return}
	edit, open_error := fat32session.open_edit(
		image_path,
		"controller-page-fixture",
		0,
		.In_Process,
	)
	if !testing.expect(t, open_error.code == .None) {return}
	for index in 0 ..< HARD_DRIVE_BROWSER_PAGE_SIZE + 2 {
		mkdir_error := fat32session.edit_mkdir(edit, fmt.tprintf("D%07d", index))
		if !testing.expect(t, mkdir_error.code == .None) {
			_ = fat32session.edit_finish(edit, false)
			return
		}
	}
	if !testing.expect_value(t, fat32session.edit_finish(edit, true).code, fat32session.Error_Code.None) {
		return
	}

	controller: Hard_Drive_Controller
	hard_drive_controller_init(&controller, .In_Process)
	defer hard_drive_controller_destroy(&controller)
	testing.expect(t, !hard_drive_controller_open(&controller, image_path, true))
	if !testing.expect(t, hard_drive_controller_open(&controller, image_path)) {return}
	testing.expect_value(t, len(controller.rows), HARD_DRIVE_BROWSER_PAGE_SIZE)
	testing.expect_value(t, controller.model.page_count, 2)
	testing.expect(t, len(controller.model.breadcrumbs) == 1)
	testing.expect_value(t, controller.model.breadcrumbs[0].label, "C drive")
	more_index := -1
	first_folder_index := -1
	for node, index in controller.tree_nodes {
		if node.load_more {more_index = index}
		if node.path == "D0000000" {first_folder_index = index}
	}
	if testing.expect(t, more_index >= 0 && first_folder_index >= 0) {
		testing.expect(
			t,
			hard_drive_controller_handle(
				&controller,
				{kind = .Toggle_Tree_Node, path = "D0000000"},
			),
		)
		first_expanded := false
		for node in controller.tree_nodes {
			if node.path == "D0000000" {first_expanded = node.expanded}
		}
		testing.expect(t, first_expanded)
		testing.expect(
			t,
			hard_drive_controller_handle(
				&controller,
				{kind = .Load_Tree_Page, path = "", page_index = 1},
			),
		)
		last_folder_visible := false
		last_folder_name := fmt.tprintf("D%07d", HARD_DRIVE_BROWSER_PAGE_SIZE + 1)
		previous_page := -1
		for node in controller.tree_nodes {
			if node.path == last_folder_name {last_folder_visible = true}
			if node.load_more && node.name == "Previous folders..." {
				previous_page = node.page_index
			}
		}
		testing.expect(t, last_folder_visible)
		testing.expect_value(t, previous_page, 0)
		testing.expect(
			t,
			hard_drive_controller_handle(
				&controller,
				{kind = .Load_Tree_Page, path = "", page_index = previous_page},
			),
		)
		first_visible_again := false
		more_page := -1
		for node in controller.tree_nodes {
			if node.path == "D0000000" {first_visible_again = true}
			if node.load_more && node.name == "More folders..." {more_page = node.page_index}
		}
		testing.expect(t, first_visible_again)
		testing.expect_value(t, more_page, 1)
	}
	testing.expect(
		t,
		hard_drive_controller_handle(
			&controller,
			{kind = .Load_Page, page_index = 1},
		),
	)
	testing.expect_value(t, len(controller.rows), 2)

	testing.expect(
		t,
		hard_drive_controller_handle(
			&controller,
			{kind = .New_Folder, name = "Applied"},
		),
	)
	testing.expect(t, controller.model.pending_changes > 0)
	testing.expect(t, !hard_drive_controller_prepare_machine_start(&controller))
	testing.expect(
		t,
		hard_drive_controller_handle(&controller, {kind = .Apply}),
	)
	testing.expect_value(t, controller.operation, Hard_Drive_Controller_Operation.Apply)
	testing.expect(t, controller.model.progress.active && controller.model.progress.cancellable)
	testing.expect(
		t,
		hard_drive_controller_handle(&controller, {kind = .Cancel_Operation}),
	)
	testing.expect_value(t, controller.operation, Hard_Drive_Controller_Operation.None)
	testing.expect(t, !controller.model.progress.active)
	testing.expect(t, controller.model.pending_changes > 0)
	testing.expect(
		t,
		hard_drive_controller_handle(&controller, {kind = .Apply}),
	)
	hard_drive_controller_step(&controller)
	testing.expect(t, controller.model.progress.cancellable)
	if !testing.expect(t, hard_drive_controller_test_run(t, &controller)) {return}
	testing.expect(t, hard_drive_controller_ready(&controller))
	applied, stat_error := fat32session.edit_stat(controller.session, "Applied")
	testing.expect_value(t, stat_error.code, fat32session.Error_Code.None)
	testing.expect(t, applied.exists && applied.is_directory)

	testing.expect(
		t,
		hard_drive_controller_handle(
			&controller,
			{kind = .New_Folder, name = "Discarded"},
		),
	)
	testing.expect(
		t,
		hard_drive_controller_handle(
			&controller,
			{kind = .Discard, close_after = true},
		),
	)
	testing.expect(t, !controller.model.visible && controller.session == nil)
	if !testing.expect(t, hard_drive_controller_open(&controller, image_path)) {return}
	discarded, discarded_error := fat32session.edit_stat(controller.session, "Discarded")
	testing.expect_value(t, discarded_error.code, fat32session.Error_Code.None)
	testing.expect(t, !discarded.exists)
	_ = hard_drive_controller_handle(&controller, {kind = .Close})
}

@(test)
hard_drive_controller_test_process_adapter_opens_populated_root_with_bounded_pages :: proc(
	t: ^testing.T,
) {
	root, ok := hard_drive_controller_test_root(t)
	if !ok {return}
	defer delete(root)
	defer os.remove_all(root)
	image_path := test_image_create(t, root, "process-browser.img")
	if image_path == "" {return}
	edit, open_error := fat32session.open_edit(
		image_path,
		"process-browser-fixture",
		0,
		.In_Process,
	)
	if !testing.expect_value(t, open_error.code, fat32session.Error_Code.None) {return}
	entry_count := HARD_DRIVE_BROWSER_PAGE_SIZE + 2
	for index in 0 ..< entry_count {
		mkdir_error := fat32session.edit_mkdir(edit, fmt.tprintf("D%07d", index))
		if !testing.expect_value(t, mkdir_error.code, fat32session.Error_Code.None) {
			_ = fat32session.edit_finish(edit, false)
			return
		}
	}
	if !testing.expect_value(t, fat32session.edit_finish(edit, true).code, fat32session.Error_Code.None) {
		return
	}

	controller: Hard_Drive_Controller
	hard_drive_controller_init(&controller, .Process)
	defer hard_drive_controller_destroy(&controller)
	if !testing.expect(t, hard_drive_controller_open(&controller, image_path)) {
		fmt.printfln("process browser diagnostic: %s", controller.model.diagnostic)
		return
	}
	testing.expect_value(t, controller.model.diagnostic, "")
	testing.expect_value(t, len(controller.rows), HARD_DRIVE_BROWSER_PAGE_SIZE)
	testing.expect_value(t, controller.model.page_count, 2)
	more_tree_page := -1
	for node in controller.tree_nodes {
		if node.load_more && node.name == "More folders..." {
			more_tree_page = node.page_index
		}
	}
	if testing.expect_value(t, more_tree_page, 1) {
		testing.expect(
			t,
			hard_drive_controller_handle(
				&controller,
				{kind = .Load_Tree_Page, path = "", page_index = more_tree_page},
			),
		)
		last_tree_entry := false
		for node in controller.tree_nodes {
			if node.path == fmt.tprintf("D%07d", entry_count - 1) {last_tree_entry = true}
		}
		testing.expect(t, last_tree_entry)
	}
	testing.expect(
		t,
		hard_drive_controller_handle(&controller, {kind = .Load_Page, page_index = 1}),
	)
	testing.expect_value(t, len(controller.rows), 2)
	testing.expect(t, hard_drive_controller_handle(&controller, {kind = .Close}))
}

@(test)
hard_drive_controller_test_tree_continuation_beyond_page_32_is_bounded :: proc(t: ^testing.T) {
	if HARD_DRIVE_TREE_PAGE_SIZE > 4 {return}
	root, ok := hard_drive_controller_test_root(t)
	if !ok {return}
	defer delete(root)
	defer os.remove_all(root)
	image_path := test_image_create(t, root, "tree-continuation.img")
	if image_path == "" {return}
	edit, open_error := fat32session.open_edit(
		image_path,
		"tree-continuation-fixture",
		0,
		.In_Process,
	)
	if !testing.expect_value(t, open_error.code, fat32session.Error_Code.None) {return}
	count := 32 * HARD_DRIVE_TREE_PAGE_SIZE + 2
	for index in 0 ..< count {
		mkdir_error := fat32session.edit_mkdir(edit, fmt.tprintf("D%07d", index))
		if !testing.expect_value(t, mkdir_error.code, fat32session.Error_Code.None) {
			_ = fat32session.edit_finish(edit, false)
			return
		}
	}
	if !testing.expect_value(t, fat32session.edit_finish(edit, true).code, fat32session.Error_Code.None) {
		return
	}
	controller: Hard_Drive_Controller
	hard_drive_controller_init(&controller, .In_Process)
	defer hard_drive_controller_destroy(&controller)
	if !testing.expect(t, hard_drive_controller_open(&controller, image_path)) {return}
	for page_index in 0 ..= 32 {
		testing.expect(t, len(controller.tree_nodes) <= HARD_DRIVE_TREE_MAX_NODES)
		previous_found := page_index == 0
		more_page := -1
		for node in controller.tree_nodes {
			if node.load_more && node.name == "Previous folders..." {
				previous_found = node.page_index == page_index - 1
			}
			if node.load_more && node.name == "More folders..." {more_page = node.page_index}
		}
		if !testing.expect(t, previous_found) {return}
		if page_index == 32 {break}
		if !testing.expect_value(t, more_page, page_index + 1) {return}
		if !testing.expect(
			t,
			hard_drive_controller_handle(
				&controller,
				{kind = .Load_Tree_Page, path = "", page_index = more_page},
			),
		) {
			return
		}
	}
	last_visible := false
	for node in controller.tree_nodes {
		if node.path == fmt.tprintf("D%07d", count - 1) {last_visible = true}
	}
	testing.expect(t, last_visible)
	testing.expect(
		t,
		hard_drive_controller_handle(
			&controller,
			{kind = .Load_Tree_Page, path = "", page_index = 31},
		),
	)
	next_found := false
	for node in controller.tree_nodes {
		if node.load_more && node.name == "More folders..." && node.page_index == 32 {
			next_found = true
		}
	}
	testing.expect(t, next_found)
}

@(test)
hard_drive_controller_test_application_exit_cleanly_closes_no_change_edit :: proc(t: ^testing.T) {
	root, ok := hard_drive_controller_test_root(t)
	if !ok {return}
	defer delete(root)
	defer os.remove_all(root)
	image_path := test_image_create(t, root, "clean-exit.img")
	if image_path == "" {return}

	controller: Hard_Drive_Controller
	hard_drive_controller_init(&controller, .In_Process)
	defer hard_drive_controller_destroy(&controller)
	if !testing.expect(t, hard_drive_controller_open(&controller, image_path)) {return}

	testing.expect(t, hard_drive_controller_prepare_application_exit(&controller))
	testing.expect(t, controller.session == nil && !controller.model.visible)
	clean, clean_error := fat32session.validate_image(image_path, .In_Process)
	if testing.expect_value(t, clean_error.code, fat32session.Error_Code.None) {
		testing.expect(t, !clean.dirty)
	}
	fat32session.image_info_destroy(&clean)
}

@(test)
hard_drive_controller_test_import_conflict_cancel_and_recursive_export :: proc(t: ^testing.T) {
	root, ok := hard_drive_controller_test_root(t)
	if !ok {return}
	defer delete(root)
	defer os.remove_all(root)
	image_path := test_image_create(t, root, "browser.img")
	if image_path == "" {return}
	if !test_image_write_files(
		t,
		image_path,
		[]string{"Games", "Games/한국어"},
		[]Test_Image_File {
			{path = "README.TXT", data = "old"},
			{path = "Games/한국어/게임.txt", data = "payload"},
		},
	) {
		return
	}

	controller: Hard_Drive_Controller
	hard_drive_controller_init(&controller, .In_Process)
	defer hard_drive_controller_destroy(&controller)
	if !testing.expect(t, hard_drive_controller_open(&controller, image_path)) {return}
	host_source, _ := filepath.join({root, "README.TXT"}, context.temp_allocator)
	testing.expect_value(t, os.write_entire_file(host_source, "new"), os.Error(nil))
	testing.expect(
		t,
		hard_drive_controller_handle(
			&controller,
			{kind = .Import, paths = []string{host_source}},
		),
	)
	hard_drive_controller_step(&controller)
	testing.expect(t, controller.conflict_pending)
	testing.expect(
		t,
		hard_drive_controller_handle(
			&controller,
			{
				kind                = .Resolve_Conflict,
				conflict_resolution = .Replace,
				apply_to_all        = true,
			},
		),
	)
	if !testing.expect(t, hard_drive_controller_test_run(t, &controller)) {return}

	large_source, _ := filepath.join({root, "LARGE.BIN"}, context.temp_allocator)
	large := make([]u8, 3 * 128 * 1024, context.temp_allocator)
	for &byte, index in large {byte = u8(index)}
	testing.expect_value(t, os.write_entire_file(large_source, large), os.Error(nil))
	testing.expect(
		t,
		hard_drive_controller_handle(
			&controller,
			{kind = .Import, paths = []string{large_source}},
		),
	)
	hard_drive_controller_step(&controller)
	hard_drive_controller_step(&controller)
	testing.expect(t, controller.model.progress.active)
	hard_drive_controller_handle(&controller, {kind = .Cancel_Operation})
	testing.expect_value(t, controller.operation, Hard_Drive_Controller_Operation.None)
	testing.expect(t, !controller.model.progress.active)

	export_parent, _ := filepath.join({root, "export"}, context.temp_allocator)
	testing.expect_value(t, os.make_directory(export_parent), os.Error(nil))
	games, found := hard_drive_controller_test_find_row(&controller, "Games")
	if !testing.expect(t, found) {return}
	testing.expect(
		t,
		hard_drive_controller_handle(
			&controller,
			{
				kind      = .Export,
				path      = export_parent,
				entry_id  = games.id,
				recursive = true,
			},
		),
	)
	if !testing.expect(t, hard_drive_controller_test_run(t, &controller)) {return}
	exported, _ := filepath.join(
		{export_parent, "Games", "한국어", "게임.txt"},
		context.temp_allocator,
	)
	bytes, read_error := os.read_entire_file(exported, context.temp_allocator)
	testing.expect_value(t, read_error, os.Error(nil))
	testing.expect_value(t, string(bytes), "payload")

	testing.expect(t, hard_drive_controller_handle(&controller, {kind = .Apply}))
	if !testing.expect(t, hard_drive_controller_test_run(t, &controller)) {return}
	readme, readme_error := fat32session.edit_read(controller.session, "README.TXT", 0, 3)
	if testing.expect_value(t, readme_error.code, fat32session.Error_Code.None) {
		testing.expect_value(t, string(readme.data), "new")
		fat32session.edit_read_destroy(&readme)
	}
}
