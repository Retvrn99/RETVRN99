// SPDX-License-Identifier: GPL-3.0-only
package host

import imgui "../../vendor_local/imgui"
import "core:testing"

@(test)
hard_drive_ui_test_exact_labels_and_size_limits :: proc(t: ^testing.T) {
	testing.expect_value(t, string(HARD_DRIVE_CREATE_TITLE), "Create Hard Drive")
	testing.expect_value(t, string(HARD_DRIVE_BROWSER_TITLE), "Browse C drive")
	testing.expect_value(t, string(HARD_DRIVE_IMPORT_FILES_LABEL), "Import Files...")
	testing.expect_value(t, string(HARD_DRIVE_IMPORT_FOLDER_LABEL), "Import Folder...")
	testing.expect_value(t, string(HARD_DRIVE_EXPORT_LABEL), "Export...")
	testing.expect_value(t, string(HARD_DRIVE_NEW_FOLDER_LABEL), "New Folder...")
	testing.expect_value(t, string(HARD_DRIVE_RENAME_LABEL), "Rename...")
	testing.expect_value(t, string(HARD_DRIVE_DELETE_LABEL), "Delete...")
	testing.expect_value(t, string(HARD_DRIVE_APPLY_LABEL), "Apply")
	testing.expect_value(t, string(HARD_DRIVE_DISCARD_LABEL), "Discard...")
	testing.expect_value(t, HARD_DRIVE_CREATE_DEFAULT_GIB, i32(20))
	testing.expect(t, !hard_drive_create_size_valid(0))
	testing.expect(t, hard_drive_create_size_valid(1))
	testing.expect(t, hard_drive_create_size_valid(20))
	testing.expect(t, hard_drive_create_size_valid(127))
	testing.expect(t, !hard_drive_create_size_valid(128))
}

@(test)
hard_drive_ui_test_create_model_and_sparse_confirmation :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	model: Hard_Drive_Create_Model
	testing.expect(t, hard_drive_create_open(&model, `D:\images\c_drive.img`))
	testing.expect(t, model.visible)
	testing.expect_value(t, model.size_gib, i32(20))
	testing.expect_value(t, hard_drive_create_path(&model), `D:\images\c_drive.img`)
	testing.expect(t, hard_drive_create_can_submit(&model))

	action := hard_drive_create_action(&model)
	testing.expect_value(t, action.kind, Hard_Drive_UI_Action_Kind.Create_Image)
	testing.expect_value(t, action.path, `D:\images\c_drive.img`)
	testing.expect_value(t, action.size_gib, i32(20))
	testing.expect(t, !action.allow_full_allocation)

	model.size_gib = 128
	testing.expect(t, !hard_drive_create_can_submit(&model))
	testing.expect_value(t, hard_drive_create_action(&model).kind, Hard_Drive_UI_Action_Kind.None)
	model.size_gib = 20
	hard_drive_create_accept_result(
		&model,
		Hard_Drive_UI_Result{kind = .Sparse_Unsupported, diagnostic = "sparse files unsupported"},
	)
	testing.expect_value(t, model.allocation, Hard_Drive_Create_Allocation.Confirmation_Required)
	testing.expect(t, !hard_drive_create_can_submit(&model))
	testing.expect_value(t, hard_drive_create_action(&model).kind, Hard_Drive_UI_Action_Kind.None)

	full_action := hard_drive_create_action(&model, true)
	testing.expect_value(t, full_action.kind, Hard_Drive_UI_Action_Kind.Create_Image)
	testing.expect(t, full_action.allow_full_allocation)
	model.busy = true
	testing.expect_value(
		t,
		hard_drive_create_action(&model, true).kind,
		Hard_Drive_UI_Action_Kind.None,
	)
}

@(test)
hard_drive_ui_test_sparse_confirmation_is_bound_to_exact_path_and_size :: proc(t: ^testing.T) {
	model: Hard_Drive_Create_Model
	if !testing.expect(t, hard_drive_create_open(&model, `D:\images\first.img`)) {return}
	hard_drive_create_accept_result(
		&model,
		{kind = .Sparse_Unsupported, diagnostic = "full allocation required"},
	)
	testing.expect(t, hard_drive_create_confirmation_current(&model))

	unchanged := Hard_Drive_Dialog_Result {
		purpose  = .Create_Image_Path,
		accepted = true,
		paths    = []string{`D:\images\first.img`},
	}
	testing.expect(t, hard_drive_create_accept_dialog(&model, unchanged))
	testing.expect(t, hard_drive_create_confirmation_current(&model))

	changed := unchanged
	changed.paths = []string{`D:\images\second.img`}
	testing.expect(t, hard_drive_create_accept_dialog(&model, changed))
	testing.expect_value(t, model.allocation, Hard_Drive_Create_Allocation.Unchecked)
	testing.expect_value(t, model.diagnostic, "")
	path_action := hard_drive_create_action(&model)
	testing.expect_value(t, path_action.kind, Hard_Drive_UI_Action_Kind.Create_Image)
	testing.expect_value(t, path_action.path, `D:\images\second.img`)
	testing.expect(t, !path_action.allow_full_allocation)
	testing.expect_value(
		t,
		hard_drive_create_action(&model, true).kind,
		Hard_Drive_UI_Action_Kind.None,
	)

	hard_drive_create_accept_result(&model, {kind = .Sparse_Unsupported})
	model.size_gib = 21
	testing.expect(t, hard_drive_create_can_submit(&model))
	testing.expect_value(t, model.allocation, Hard_Drive_Create_Allocation.Unchecked)
	size_action := hard_drive_create_action(&model)
	testing.expect_value(t, size_action.kind, Hard_Drive_UI_Action_Kind.Create_Image)
	testing.expect_value(t, size_action.size_gib, i32(21))
	testing.expect(t, !size_action.allow_full_allocation)
}

@(test)
hard_drive_ui_test_create_result_progress_and_completion :: proc(t: ^testing.T) {
	model: Hard_Drive_Create_Model
	_ = hard_drive_create_open(&model, "c_drive.img")
	hard_drive_create_accept_result(
		&model,
		Hard_Drive_UI_Result {
			kind = .Progress,
			progress = {active = true, completed = 3, total = 4, message = "Formatting"},
		},
	)
	testing.expect(t, model.busy)
	testing.expect_value(t, model.progress, f32(0.75))
	testing.expect_value(t, model.progress_message, "Formatting")
	testing.expect(t, !model.cancellable)

	hard_drive_create_accept_result(
		&model,
		Hard_Drive_UI_Result {
			kind = .Image_Created_Unselected,
			diagnostic = "settings unavailable",
		},
	)
	testing.expect(t, model.visible)
	testing.expect(t, model.created_unselected)
	testing.expect(t, !hard_drive_create_can_submit(&model))
	select_action := hard_drive_create_select_action(&model)
	testing.expect_value(t, select_action.kind, Hard_Drive_UI_Action_Kind.Select_Created_Image)
	testing.expect_value(t, select_action.path, "c_drive.img")

	hard_drive_create_accept_result(&model, Hard_Drive_UI_Result{kind = .Image_Created})
	testing.expect(t, !model.visible)
	testing.expect(t, !model.busy)
	testing.expect_value(t, model.allocation, Hard_Drive_Create_Allocation.Sparse_Supported)
}

@(test)
hard_drive_ui_test_native_dialog_requests_and_create_result :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	select_request := hard_drive_select_dialog_request(`D:\images\current.img`)
	testing.expect_value(t, select_request.kind, Hard_Drive_Native_Dialog_Kind.Open_File)
	testing.expect_value(t, select_request.purpose, Hard_Drive_Dialog_Purpose.Select_Image)
	testing.expect_value(t, select_request.filter_pattern, "img")

	model: Hard_Drive_Create_Model
	_ = hard_drive_create_open(&model, `D:\images\c_drive.img`)
	create_request := hard_drive_create_dialog_request(&model)
	testing.expect_value(t, create_request.kind, Hard_Drive_Native_Dialog_Kind.Save_File)
	testing.expect_value(t, create_request.purpose, Hard_Drive_Dialog_Purpose.Create_Image_Path)
	testing.expect_value(t, create_request.suggested_path, `D:\images\c_drive.img`)
	testing.expect_value(t, create_request.filter_pattern, "img")

	selected := []string{`E:\VM disks\win98.img`}
	testing.expect(
		t,
		hard_drive_create_accept_dialog(
			&model,
			Hard_Drive_Dialog_Result {
				purpose = .Create_Image_Path,
				accepted = true,
				paths = selected,
			},
		),
	)
	testing.expect_value(t, hard_drive_create_path(&model), selected[0])
}

@(test)
hard_drive_ui_test_korean_names_fit_ui_buffers :: proc(t: ^testing.T) {
	buffer: [HARD_DRIVE_UI_NAME_CAPACITY]u8
	name := "새 폴더와 게임 파일"
	testing.expect(t, hard_drive_ui_buffer_set(buffer[:], name))
	testing.expect_value(t, hard_drive_ui_buffer_string(buffer[:]), name)

	tiny: [4]u8
	testing.expect(t, !hard_drive_ui_buffer_set(tiny[:], name))
}

@(test)
hard_drive_ui_test_browser_mutation_and_selection_gates :: proc(t: ^testing.T) {
	model: Hard_Drive_Browser_Model
	hard_drive_browser_init(&model)
	model.visible = true
	model.rows = []Hard_Drive_Browser_Row {
		{id = 7, kind = .File, name = "README.TXT", path = "/README.TXT", size = 12},
	}
	testing.expect_value(t, model.selection_count, 0)
	testing.expect(t, hard_drive_browser_can_mutate(&model))
	testing.expect(t, !hard_drive_browser_can_use_selection(&model))
	testing.expect(t, !hard_drive_browser_can_apply(&model))

	testing.expect(t, hard_drive_browser_selection_set(&model, 7, true))
	model.pending_changes = 2
	testing.expect(t, hard_drive_browser_can_use_selection(&model))
	testing.expect(t, hard_drive_browser_can_apply(&model))
	testing.expect_value(t, hard_drive_browser_pending_label(&model), cstring("2 pending changes"))

	model.machine_running = true
	testing.expect(t, !hard_drive_browser_can_mutate(&model))
	testing.expect(t, !hard_drive_browser_can_use_selection(&model))
	testing.expect(t, !hard_drive_browser_can_apply(&model))
	model.machine_running = false
	model.read_only = true
	testing.expect(t, !hard_drive_browser_can_mutate(&model))
	testing.expect(t, hard_drive_browser_can_browse(&model))
	testing.expect(t, hard_drive_browser_can_export(&model))
	model.read_only = false
	model.progress.active = true
	testing.expect(t, !hard_drive_browser_can_mutate(&model))
}

@(test)
hard_drive_ui_test_browser_picker_results_and_drag_drop :: proc(t: ^testing.T) {
	model: Hard_Drive_Browser_Model
	hard_drive_browser_init(&model)
	model.visible = true
	model.rows = []Hard_Drive_Browser_Row {
		{id = 11, kind = .File, name = "SAVE.DAT", path = "/SAVE.DAT"},
		{id = 12, kind = .Directory, name = "GAMES", path = "/GAMES"},
	}
	testing.expect(t, hard_drive_browser_selection_set(&model, 11, true))
	file_export := hard_drive_browser_export_request(&model)
	testing.expect_value(t, file_export.kind, Hard_Drive_Native_Dialog_Kind.Save_File)
	testing.expect_value(t, file_export.purpose, Hard_Drive_Dialog_Purpose.Export_Entry)

	export_paths := []string{`D:\exports\SAVE.DAT`}
	export_action := hard_drive_browser_accept_dialog(
		&model,
		Hard_Drive_Dialog_Result{purpose = .Export_Entry, accepted = true, paths = export_paths},
	)
	testing.expect_value(t, export_action.kind, Hard_Drive_UI_Action_Kind.Export)
	testing.expect_value(t, export_action.entry_id, u64(11))
	testing.expect(t, !export_action.recursive)

	testing.expect(t, hard_drive_browser_select_only(&model, 12))
	folder_export := hard_drive_browser_export_request(&model)
	testing.expect_value(t, folder_export.kind, Hard_Drive_Native_Dialog_Kind.Select_Folder)
	export_action = hard_drive_browser_accept_dialog(
		&model,
		Hard_Drive_Dialog_Result {
			purpose = .Export_Entry,
			accepted = true,
			paths = []string{`D:\exports`},
		},
	)
	testing.expect(t, export_action.recursive)

	imports := []string{`D:\host\한글.txt`, `D:\host\TOOLS`}
	import_action := hard_drive_browser_accept_drop(&model, imports)
	testing.expect_value(t, import_action.kind, Hard_Drive_UI_Action_Kind.Import)
	testing.expect_value(t, len(import_action.paths), 2)
	testing.expect_value(t, import_action.paths[0], imports[0])

	model.machine_running = true
	testing.expect_value(
		t,
		hard_drive_browser_accept_drop(&model, imports).kind,
		Hard_Drive_UI_Action_Kind.None,
	)
}

@(test)
hard_drive_ui_test_browser_close_prompt_rename_and_conflict :: proc(t: ^testing.T) {
	model: Hard_Drive_Browser_Model
	hard_drive_browser_init(&model)
	model.visible = true
	testing.expect_value(
		t,
		hard_drive_browser_request_close(&model).kind,
		Hard_Drive_UI_Action_Kind.Close,
	)

	model.pending_changes = 1
	testing.expect_value(
		t,
		hard_drive_browser_request_close(&model).kind,
		Hard_Drive_UI_Action_Kind.None,
	)
	testing.expect_value(t, model.prompt, Hard_Drive_Browser_Prompt.Close_With_Changes)
	testing.expect(t, model.prompt_open_requested)

	model.rows = []Hard_Drive_Browser_Row {
		{id = 99, kind = .File, name = "한글 이름.txt", path = "/한글 이름.txt"},
	}
	testing.expect(t, hard_drive_browser_selection_set(&model, 99, true))
	hard_drive_browser_begin_prompt(&model, .Rename)
	testing.expect_value(t, hard_drive_ui_buffer_string(model.name_input[:]), "한글 이름.txt")

	hard_drive_browser_show_conflict(&model, "incoming.txt", "existing.txt")
	testing.expect(t, model.conflict.active)
	testing.expect(t, model.conflict_open_requested)
	testing.expect_value(t, model.conflict.source_name, "incoming.txt")
	testing.expect_value(t, model.conflict.target_name, "existing.txt")
}

@(test)
hard_drive_ui_test_browser_typed_results_replace_page_and_bound_progress :: proc(t: ^testing.T) {
	model: Hard_Drive_Browser_Model
	hard_drive_browser_init(&model)
	model.visible = true
	rows := []Hard_Drive_Browser_Row {
		{id = 1, kind = .Directory, name = "WINDOWS", path = "/WINDOWS"},
	}
	hard_drive_browser_accept_result(
		&model,
		Hard_Drive_UI_Result {
			kind = .Directory_Page,
			current_path = "/",
			rows = rows,
			page_index = -4,
			page_count = 0,
			total_entries = 1,
			pending_changes = 3,
		},
	)
	testing.expect_value(t, model.current_path, "/")
	testing.expect_value(t, len(model.rows), 1)
	testing.expect_value(t, model.page_index, 0)
	testing.expect_value(t, model.page_count, 1)
	testing.expect_value(t, model.pending_changes, 3)
	testing.expect_value(t, model.selection_count, 0)

	progress := Hard_Drive_Browser_Progress {
		active    = true,
		completed = 25,
		total     = 100,
	}
	testing.expect_value(t, hard_drive_browser_progress_fraction(progress), f32(0.25))
	progress.completed = 150
	testing.expect_value(t, hard_drive_browser_progress_fraction(progress), f32(1))
	progress.total = 0
	testing.expect_value(t, hard_drive_browser_progress_fraction(progress), f32(0))

	hard_drive_browser_accept_result(
		&model,
		Hard_Drive_UI_Result{kind = .Operation_Complete, pending_changes = 0},
	)
	testing.expect(t, !model.progress.active)
	testing.expect_value(t, model.pending_changes, 0)
}

@(test)
hard_drive_ui_test_page_local_selection_uses_stable_entry_ids :: proc(t: ^testing.T) {
	model: Hard_Drive_Browser_Model
	hard_drive_browser_init(&model)
	model.visible = true
	model.rows = []Hard_Drive_Browser_Row {
		{id = 101, kind = .File, name = "ONE.TXT"},
		{id = 202, kind = .Directory, name = "GAMES"},
		{id = 303, kind = .File, name = "SETUP.EXE", pending_deletion = true},
	}
	testing.expect(t, hard_drive_browser_selection_set(&model, 202, true))
	testing.expect(t, hard_drive_browser_selection_set(&model, 101, true))
	testing.expect_value(t, model.selection_count, 2)
	testing.expect(t, hard_drive_browser_selection_contains(&model, 101))
	testing.expect(t, hard_drive_browser_selection_contains(&model, 202))

	snapshot, valid := hard_drive_browser_delete_snapshot(&model)
	testing.expect(t, valid)
	testing.expect_value(t, snapshot.count, 2)
	testing.expect_value(t, snapshot.file_count, 1)
	testing.expect_value(t, snapshot.directory_count, 1)

	hard_drive_browser_select_all(&model)
	testing.expect_value(t, model.selection_count, 2)
	testing.expect(t, !hard_drive_browser_selection_contains(&model, 303))
	model.rows[0].pending_deletion = true
	hard_drive_browser_selection_prune(&model)
	testing.expect_value(t, model.selection_count, 1)
	testing.expect(t, hard_drive_browser_selection_contains(&model, 202))

	hard_drive_browser_clear_selection(&model)
	testing.expect_value(t, model.selection_count, 0)
}

@(test)
hard_drive_ui_test_multi_select_requests_map_ranges_to_stable_ids :: proc(t: ^testing.T) {
	model: Hard_Drive_Browser_Model
	hard_drive_browser_init(&model)
	model.rows = []Hard_Drive_Browser_Row {
		{id = 10, name = "A"},
		{id = 20, name = "B"},
		{id = 30, name = "C", pending_deletion = true},
		{id = 40, name = "D"},
	}
	range_requests := [1]imgui.SelectionRequest {
		{Type = .SetRange, Selected = true, RangeFirstItem = 0, RangeLastItem = 3},
	}
	io := imgui.MultiSelectIO{}
	io.Requests.Data = &range_requests[0]
	io.Requests.Size = 1
	hard_drive_browser_selection_apply_requests(&model, &io)
	testing.expect_value(t, model.selection_count, 3)
	testing.expect(t, hard_drive_browser_selection_contains(&model, 10))
	testing.expect(t, hard_drive_browser_selection_contains(&model, 20))
	testing.expect(t, hard_drive_browser_selection_contains(&model, 40))

	all_requests := [1]imgui.SelectionRequest{{Type = .SetAll, Selected = false}}
	io.Requests.Data = &all_requests[0]
	hard_drive_browser_selection_apply_requests(&model, &io)
	testing.expect_value(t, model.selection_count, 0)
	all_requests[0].Selected = true
	hard_drive_browser_selection_apply_requests(&model, &io)
	testing.expect_value(t, model.selection_count, 3)
}

@(test)
hard_drive_ui_test_browser_icon_roles_are_pack_agnostic :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	folder := Hard_Drive_Browser_Row {
		kind = .Directory,
		name = "GAMES",
	}
	text_file := Hard_Drive_Browser_Row {
		kind = .File,
		name = "README.TXT",
	}
	executable := Hard_Drive_Browser_Row {
		kind = .File,
		name = "SETUP.ExE",
	}
	data := Hard_Drive_Browser_Row {
		kind = .File,
		name = "SAVE.DAT",
	}
	testing.expect_value(t, hard_drive_browser_icon_role(&folder), Ui_Icon_Role.Folder_16)
	testing.expect_value(
		t,
		hard_drive_browser_icon_role(&folder, true),
		Ui_Icon_Role.Folder_Open_16,
	)
	testing.expect_value(t, hard_drive_browser_icon_role(&text_file), Ui_Icon_Role.Text_File_16)
	testing.expect_value(t, hard_drive_browser_icon_role(&executable), Ui_Icon_Role.Executable_16)
	testing.expect_value(t, hard_drive_browser_icon_role(&data), Ui_Icon_Role.Generic_File_16)
}

@(test)
hard_drive_ui_test_size_metadata_text :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	testing.expect_value(t, hard_drive_browser_size_text(12), cstring("12 B"))
	testing.expect_value(t, hard_drive_browser_size_text(1024), cstring("1.0 KiB"))
	testing.expect_value(t, hard_drive_browser_size_text(1024 * 1024), cstring("1.0 MiB"))
	testing.expect_value(t, hard_drive_browser_size_text(1024 * 1024 * 1024), cstring("1.0 GiB"))
}
