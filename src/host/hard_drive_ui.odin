// SPDX-License-Identifier: GPL-3.0-only
package host

import imgui "../../vendor_local/imgui"
import "core:fmt"
import "core:strings"

HARD_DRIVE_CREATE_DEFAULT_GIB :: i32(20)
HARD_DRIVE_CREATE_MIN_GIB :: i32(1)
HARD_DRIVE_CREATE_MAX_GIB :: i32(127)
HARD_DRIVE_UI_PATH_CAPACITY :: 32768
HARD_DRIVE_UI_NAME_CAPACITY :: 1024
HARD_DRIVE_BROWSER_SELECTION_CAPACITY :: 64

HARD_DRIVE_CREATE_TITLE :: "Create Hard Drive"
HARD_DRIVE_BROWSER_TITLE :: "Browse C drive"
HARD_DRIVE_CREATE_PATH_LABEL :: "Image location"
HARD_DRIVE_CREATE_SIZE_LABEL :: "Size (GiB)"
HARD_DRIVE_CREATE_BUTTON_LABEL :: "Create"
HARD_DRIVE_CREATE_FULL_BUTTON_LABEL :: "Create Full-Size Image"
HARD_DRIVE_IMPORT_FILES_LABEL :: "Import Files..."
HARD_DRIVE_IMPORT_FOLDER_LABEL :: "Import Folder..."
HARD_DRIVE_EXPORT_LABEL :: "Export..."
HARD_DRIVE_NEW_FOLDER_LABEL :: "New Folder..."
HARD_DRIVE_RENAME_LABEL :: "Rename..."
HARD_DRIVE_DELETE_LABEL :: "Delete..."
HARD_DRIVE_APPLY_LABEL :: "Apply"
HARD_DRIVE_DISCARD_LABEL :: "Discard..."

Hard_Drive_Native_Dialog_Kind :: enum {
	None,
	Open_File,
	Open_Files,
	Save_File,
	Select_Folder,
}

Hard_Drive_Dialog_Purpose :: enum {
	None,
	Select_Image,
	Create_Image_Path,
	Import_Files,
	Import_Folder,
	Export_Entry,
	Install_ISO,
	Quick_Install_ISO,
	Install_Boot_Floppy,
}

Hard_Drive_Dialog_Request :: struct {
	kind:           Hard_Drive_Native_Dialog_Kind,
	purpose:        Hard_Drive_Dialog_Purpose,
	title:          string,
	suggested_path: string,
	filter_name:    string,
	filter_pattern: string,
	allow_multiple: bool,
}

Hard_Drive_Dialog_Result :: struct {
	purpose:    Hard_Drive_Dialog_Purpose,
	accepted:   bool,
	failed:     bool,
	paths:      []string,
	diagnostic: string,
}

Hard_Drive_UI_Action_Kind :: enum {
	None,
	Request_Native_Dialog,
	Create_Image,
	Select_Created_Image,
	Navigate,
	Toggle_Tree_Node,
	Load_Tree_Page,
	Load_Page,
	Refresh,
	Import,
	Export,
	New_Folder,
	Rename,
	Delete,
	Apply,
	Discard,
	Cancel_Operation,
	Resolve_Conflict,
	Close,
	Cancel_Close,
}

Hard_Drive_Conflict_Resolution :: enum {
	None,
	Replace,
	Skip,
	Cancel,
}

Hard_Drive_UI_Action :: struct {
	kind:                  Hard_Drive_UI_Action_Kind,
	dialog:                Hard_Drive_Dialog_Request,
	path:                  string,
	paths:                 []string,
	name:                  string,
	entry_id:              u64,
	delete_snapshot:       Hard_Drive_Delete_Snapshot,
	page_index:            int,
	size_gib:              i32,
	allow_full_allocation: bool,
	recursive:             bool,
	close_after:           bool,
	conflict_resolution:   Hard_Drive_Conflict_Resolution,
	apply_to_all:          bool,
}

Hard_Drive_UI_Result_Kind :: enum {
	None,
	Busy,
	Sparse_Unsupported,
	Image_Created,
	Image_Created_Unselected,
	Cancelled,
	Directory_Page,
	Progress,
	Operation_Complete,
	Conflict,
	Error,
}

Hard_Drive_Create_Allocation :: enum {
	Unchecked,
	Sparse_Supported,
	Confirmation_Required,
}

Hard_Drive_Create_Model :: struct {
	visible:               bool,
	path:                  [HARD_DRIVE_UI_PATH_CAPACITY]u8,
	size_gib:              i32,
	allocation:            Hard_Drive_Create_Allocation,
	confirmation_path:     [HARD_DRIVE_UI_PATH_CAPACITY]u8,
	confirmation_size_gib: i32,
	busy:                  bool,
	progress:              f32,
	progress_message:      string,
	diagnostic:            string,
	created_unselected:    bool,
	cancellable:           bool,
}

Hard_Drive_Entry_Kind :: enum {
	File,
	Directory,
}

Hard_Drive_Delete_Snapshot :: struct {
	entry_ids:       [HARD_DRIVE_BROWSER_SELECTION_CAPACITY]u64,
	count:           int,
	file_count:      int,
	directory_count: int,
}

Hard_Drive_Breadcrumb :: struct {
	label: string,
	path:  string,
}

Hard_Drive_Tree_Node :: struct {
	id:           u64,
	name:         string,
	path:         string,
	depth:        int,
	has_children: bool,
	expanded:     bool,
	selected:     bool,
	load_more:    bool,
	page_index:   int,
}

Hard_Drive_Browser_Row :: struct {
	id:               u64,
	kind:             Hard_Drive_Entry_Kind,
	name:             string,
	path:             string,
	size:             u64,
	modified_text:    string,
	pending_deletion: bool,
}

Hard_Drive_Browser_Progress :: struct {
	active:      bool,
	completed:   u64,
	total:       u64,
	message:     string,
	cancellable: bool,
}

Hard_Drive_Browser_Prompt :: enum {
	None,
	New_Folder,
	Rename,
	Delete,
	Properties,
	Discard,
	Close_With_Changes,
}

Hard_Drive_Browser_Conflict :: struct {
	active:       bool,
	source_name:  string,
	target_name:  string,
	apply_to_all: bool,
}

Hard_Drive_Browser_Model :: struct {
	visible:                 bool,
	machine_running:         bool,
	read_only:               bool,
	current_path:            string,
	image_path:              string,
	breadcrumbs:             []Hard_Drive_Breadcrumb,
	tree_nodes:              []Hard_Drive_Tree_Node,
	rows:                    []Hard_Drive_Browser_Row,
	page_index:              int,
	page_count:              int,
	page_count_exact:        bool,
	total_entries:           u64,
	total_entries_exact:     bool,
	selected_entry_ids:      [HARD_DRIVE_BROWSER_SELECTION_CAPACITY]u64,
	selection_count:         int,
	pending_delete_count:    int,
	pending_changes:         int,
	progress:                Hard_Drive_Browser_Progress,
	diagnostic:              string,
	prompt:                  Hard_Drive_Browser_Prompt,
	prompt_open_requested:   bool,
	name_input:              [HARD_DRIVE_UI_NAME_CAPACITY]u8,
	conflict:                Hard_Drive_Browser_Conflict,
	conflict_open_requested: bool,
}

Hard_Drive_UI_Result :: struct {
	kind:                Hard_Drive_UI_Result_Kind,
	operation:           Hard_Drive_UI_Action_Kind,
	image_path:          string,
	current_path:        string,
	breadcrumbs:         []Hard_Drive_Breadcrumb,
	tree_nodes:          []Hard_Drive_Tree_Node,
	rows:                []Hard_Drive_Browser_Row,
	page_index:          int,
	page_count:          int,
	page_count_exact:    bool,
	total_entries:       u64,
	total_entries_exact: bool,
	pending_changes:     int,
	progress:            Hard_Drive_Browser_Progress,
	diagnostic:          string,
	conflict_source:     string,
	conflict_target:     string,
}

hard_drive_ui_buffer_set :: proc(buffer: []u8, value: string) -> bool {
	if len(buffer) == 0 || len(value) >= len(buffer) {return false}
	for &byte in buffer {byte = 0}
	copy(buffer, transmute([]u8)value)
	return true
}

hard_drive_ui_buffer_string :: proc(buffer: []u8) -> string {
	if len(buffer) == 0 {return ""}
	return string(cstring(&buffer[0]))
}

hard_drive_select_dialog_request :: proc(current_path: string = "") -> Hard_Drive_Dialog_Request {
	return Hard_Drive_Dialog_Request {
		kind = .Open_File,
		purpose = .Select_Image,
		title = "Select RETVRN99 hard drive",
		suggested_path = current_path,
		filter_name = "Disk images",
		filter_pattern = "img",
	}
}

hard_drive_create_dialog_request :: proc(
	model: ^Hard_Drive_Create_Model,
) -> Hard_Drive_Dialog_Request {
	suggested := ""
	if model != nil {suggested = hard_drive_ui_buffer_string(model.path[:])}
	return Hard_Drive_Dialog_Request {
		kind = .Save_File,
		purpose = .Create_Image_Path,
		title = "Create RETVRN99 hard drive",
		suggested_path = suggested,
		filter_name = "Disk images",
		filter_pattern = "img",
	}
}

hard_drive_create_open :: proc(model: ^Hard_Drive_Create_Model, default_path: string) -> bool {
	if model == nil {return false}
	model^ = {}
	model.visible = true
	model.size_gib = HARD_DRIVE_CREATE_DEFAULT_GIB
	return hard_drive_ui_buffer_set(model.path[:], default_path)
}

hard_drive_create_path :: proc(model: ^Hard_Drive_Create_Model) -> string {
	if model == nil {return ""}
	return hard_drive_ui_buffer_string(model.path[:])
}

hard_drive_create_confirmation_current :: proc(model: ^Hard_Drive_Create_Model) -> bool {
	return(
		model != nil &&
		model.allocation == .Confirmation_Required &&
		model.size_gib == model.confirmation_size_gib &&
		hard_drive_create_path(model) == hard_drive_ui_buffer_string(model.confirmation_path[:]) \
	)
}

hard_drive_create_invalidate_sparse_confirmation :: proc(model: ^Hard_Drive_Create_Model) {
	if model == nil ||
	   model.allocation != .Confirmation_Required ||
	   hard_drive_create_confirmation_current(model) {
		return
	}
	model.allocation = .Unchecked
	model.confirmation_size_gib = 0
	for &byte in model.confirmation_path {byte = 0}
	model.diagnostic = ""
}

hard_drive_create_accept_dialog :: proc(
	model: ^Hard_Drive_Create_Model,
	result: Hard_Drive_Dialog_Result,
) -> bool {
	if model == nil ||
	   !result.accepted ||
	   result.purpose != .Create_Image_Path ||
	   len(result.paths) != 1 {
		return false
	}
	if !hard_drive_ui_buffer_set(model.path[:], result.paths[0]) {return false}
	hard_drive_create_invalidate_sparse_confirmation(model)
	return true
}

hard_drive_create_size_valid :: proc(size_gib: i32) -> bool {
	return size_gib >= HARD_DRIVE_CREATE_MIN_GIB && size_gib <= HARD_DRIVE_CREATE_MAX_GIB
}

hard_drive_create_can_submit :: proc(model: ^Hard_Drive_Create_Model) -> bool {
	hard_drive_create_invalidate_sparse_confirmation(model)
	return(
		model != nil &&
		model.visible &&
		!model.busy &&
		!model.created_unselected &&
		len(hard_drive_create_path(model)) > 0 &&
		hard_drive_create_size_valid(model.size_gib) &&
		model.allocation != .Confirmation_Required \
	)
}

hard_drive_create_action :: proc(
	model: ^Hard_Drive_Create_Model,
	allow_full_allocation: bool = false,
) -> Hard_Drive_UI_Action {
	if model == nil || model.created_unselected {return {}}
	hard_drive_create_invalidate_sparse_confirmation(model)
	if allow_full_allocation {
		if !hard_drive_create_confirmation_current(model) || model.busy {return {}}
	} else if !hard_drive_create_can_submit(model) {
		return {}
	}
	return Hard_Drive_UI_Action {
		kind = .Create_Image,
		path = hard_drive_create_path(model),
		size_gib = model.size_gib,
		allow_full_allocation = allow_full_allocation,
	}
}

hard_drive_create_select_action :: proc(model: ^Hard_Drive_Create_Model) -> Hard_Drive_UI_Action {
	if model == nil || !model.visible || !model.created_unselected || model.busy {return {}}
	return {kind = .Select_Created_Image, path = hard_drive_create_path(model)}
}

hard_drive_create_accept_result :: proc(
	model: ^Hard_Drive_Create_Model,
	result: Hard_Drive_UI_Result,
) {
	if model == nil {return}
	switch result.kind {
	case .Busy:
		model.busy = true
		model.cancellable = result.progress.cancellable
		model.progress = 0
		model.progress_message = result.progress.message
		model.diagnostic = ""
	case .Progress:
		model.busy = true
		model.cancellable = result.progress.cancellable
		model.progress = hard_drive_browser_progress_fraction(result.progress)
		model.progress_message = result.progress.message
	case .Sparse_Unsupported:
		model.busy = false
		model.cancellable = false
		model.allocation = .Confirmation_Required
		_ = hard_drive_ui_buffer_set(model.confirmation_path[:], hard_drive_create_path(model))
		model.confirmation_size_gib = model.size_gib
		model.progress = 0
		model.progress_message = ""
		model.diagnostic = result.diagnostic
	case .Image_Created:
		model.busy = false
		model.cancellable = false
		model.visible = false
		model.created_unselected = false
		model.allocation = .Sparse_Supported
		model.progress = 1
		model.progress_message = ""
		model.diagnostic = ""
	case .Image_Created_Unselected:
		model.busy = false
		model.cancellable = false
		model.visible = true
		model.created_unselected = true
		model.progress = 1
		model.progress_message = ""
		model.diagnostic = result.diagnostic
	case .Cancelled:
		model.busy = false
		model.cancellable = false
		model.created_unselected = false
		model.progress = 0
		model.progress_message = ""
		model.diagnostic = result.diagnostic
	case .Error:
		model.busy = false
		model.cancellable = false
		model.progress_message = ""
		model.diagnostic = result.diagnostic
	case .None, .Directory_Page, .Operation_Complete, .Conflict:
	}
}

hard_drive_browser_init :: proc(model: ^Hard_Drive_Browser_Model) {
	if model == nil {return}
	model^ = {}
}

hard_drive_browser_clear_selection :: proc(model: ^Hard_Drive_Browser_Model) {
	if model == nil {return}
	for &entry_id in model.selected_entry_ids {entry_id = 0}
	model.selection_count = 0
}

hard_drive_browser_selection_contains :: proc(
	model: ^Hard_Drive_Browser_Model,
	entry_id: u64,
) -> bool {
	if model == nil || entry_id == 0 {return false}
	for index in 0 ..< model.selection_count {
		if model.selected_entry_ids[index] == entry_id {return true}
	}
	return false
}

hard_drive_browser_selection_set :: proc(
	model: ^Hard_Drive_Browser_Model,
	entry_id: u64,
	selected: bool,
) -> bool {
	if model == nil || entry_id == 0 {return false}
	found_index := -1
	for index in 0 ..< model.selection_count {
		if model.selected_entry_ids[index] == entry_id {
			found_index = index
			break
		}
	}
	if selected {
		if found_index >= 0 {return true}
		if model.selection_count >= HARD_DRIVE_BROWSER_SELECTION_CAPACITY {return false}
		model.selected_entry_ids[model.selection_count] = entry_id
		model.selection_count += 1
		return true
	}
	if found_index < 0 {return true}
	model.selection_count -= 1
	model.selected_entry_ids[found_index] = model.selected_entry_ids[model.selection_count]
	model.selected_entry_ids[model.selection_count] = 0
	return true
}

hard_drive_browser_select_only :: proc(model: ^Hard_Drive_Browser_Model, entry_id: u64) -> bool {
	hard_drive_browser_clear_selection(model)
	return hard_drive_browser_selection_set(model, entry_id, true)
}

hard_drive_browser_select_all :: proc(model: ^Hard_Drive_Browser_Model) {
	if model == nil {return}
	hard_drive_browser_clear_selection(model)
	for &row in model.rows {
		if row.pending_deletion {continue}
		if !hard_drive_browser_selection_set(model, row.id, true) {break}
	}
}

hard_drive_browser_selection_prune :: proc(model: ^Hard_Drive_Browser_Model) {
	if model == nil {return}
	for index := model.selection_count - 1; index >= 0; index -= 1 {
		entry_id := model.selected_entry_ids[index]
		keep := false
		for &row in model.rows {
			if row.id == entry_id && !row.pending_deletion {
				keep = true
				break
			}
		}
		if !keep {_ = hard_drive_browser_selection_set(model, entry_id, false)}
	}
}

hard_drive_browser_selection_apply_requests :: proc(
	model: ^Hard_Drive_Browser_Model,
	requests: ^imgui.MultiSelectIO,
) {
	if model == nil || requests == nil {return}
	request_data := transmute([^]imgui.SelectionRequest)requests.Requests.Data
	for request_index in 0 ..< int(requests.Requests.Size) {
		request := request_data[request_index]
		switch request.Type {
		case .SetAll:
			if request.Selected {
				hard_drive_browser_select_all(model)
			} else {
				hard_drive_browser_clear_selection(model)
			}
		case .SetRange:
			if len(model.rows) == 0 {continue}
			first := clamp(int(request.RangeFirstItem), 0, len(model.rows) - 1)
			last := clamp(int(request.RangeLastItem), 0, len(model.rows) - 1)
			if first > last {first, last = last, first}
			for index in first ..= last {
				row := &model.rows[index]
				if row.pending_deletion {continue}
				_ = hard_drive_browser_selection_set(model, row.id, request.Selected)
			}
		case .None:
		}
	}
	hard_drive_browser_selection_prune(model)
}

hard_drive_browser_selected_row :: proc(
	model: ^Hard_Drive_Browser_Model,
) -> (
	^Hard_Drive_Browser_Row,
	bool,
) {
	if model == nil || model.selection_count != 1 {return nil, false}
	entry_id := model.selected_entry_ids[0]
	for &row in model.rows {
		if row.id == entry_id && !row.pending_deletion {return &row, true}
	}
	return nil, false
}

hard_drive_browser_delete_snapshot :: proc(
	model: ^Hard_Drive_Browser_Model,
) -> (
	Hard_Drive_Delete_Snapshot,
	bool,
) {
	snapshot: Hard_Drive_Delete_Snapshot
	if model == nil || model.selection_count <= 0 {return snapshot, false}
	for &row in model.rows {
		if row.pending_deletion || !hard_drive_browser_selection_contains(model, row.id) {continue}
		if snapshot.count >= HARD_DRIVE_BROWSER_SELECTION_CAPACITY {return {}, false}
		snapshot.entry_ids[snapshot.count] = row.id
		snapshot.count += 1
		if row.kind == .Directory {
			snapshot.directory_count += 1
		} else {
			snapshot.file_count += 1
		}
	}
	return snapshot, snapshot.count == model.selection_count
}

hard_drive_browser_icon_role :: proc(row: ^Hard_Drive_Browser_Row, open := false) -> Ui_Icon_Role {
	if row == nil {return .Generic_File_16}
	if row.kind == .Directory {return open ? .Folder_Open_16 : .Folder_16}
	extension := ""
	for index := len(row.name) - 1; index >= 0; index -= 1 {
		if row.name[index] == '.' {
			extension = strings.to_lower(row.name[index + 1:], context.temp_allocator)
			break
		}
	}
	if extension == "txt" || extension == "ini" || extension == "log" {
		return .Text_File_16
	}
	if extension == "exe" ||
	   extension == "com" ||
	   extension == "dll" ||
	   extension == "sys" ||
	   extension == "bat" ||
	   extension == "cmd" ||
	   extension == "scr" {
		return .Executable_16
	}
	return .Generic_File_16
}

hard_drive_browser_can_mutate :: proc(model: ^Hard_Drive_Browser_Model) -> bool {
	return hard_drive_browser_can_browse(model) && !model.read_only
}

hard_drive_browser_can_browse :: proc(model: ^Hard_Drive_Browser_Model) -> bool {
	return model != nil && model.visible && !model.machine_running && !model.progress.active
}

hard_drive_browser_can_apply :: proc(model: ^Hard_Drive_Browser_Model) -> bool {
	return hard_drive_browser_can_mutate(model) && model.pending_changes > 0
}

hard_drive_browser_can_use_selection :: proc(model: ^Hard_Drive_Browser_Model) -> bool {
	return hard_drive_browser_can_mutate(model) && model.selection_count > 0
}

hard_drive_browser_can_use_single_selection :: proc(model: ^Hard_Drive_Browser_Model) -> bool {
	_, selected := hard_drive_browser_selected_row(model)
	return hard_drive_browser_can_mutate(model) && selected
}

hard_drive_browser_can_export :: proc(model: ^Hard_Drive_Browser_Model) -> bool {
	_, selected := hard_drive_browser_selected_row(model)
	return hard_drive_browser_can_browse(model) && selected
}

hard_drive_browser_pending_label :: proc(model: ^Hard_Drive_Browser_Model) -> cstring {
	if model == nil || model.pending_changes == 0 {return "No pending changes"}
	if model.pending_changes == 1 {return "1 pending change"}
	return fmt.ctprintf("%d pending changes", model.pending_changes)
}

hard_drive_browser_progress_fraction :: proc(progress: Hard_Drive_Browser_Progress) -> f32 {
	if !progress.active || progress.total == 0 {return 0}
	return clamp(f32(progress.completed) / f32(progress.total), f32(0), f32(1))
}

hard_drive_browser_begin_prompt :: proc(
	model: ^Hard_Drive_Browser_Model,
	prompt: Hard_Drive_Browser_Prompt,
) {
	if model == nil {return}
	model.prompt = prompt
	model.prompt_open_requested = true
	for &byte in model.name_input {byte = 0}
	if prompt == .Rename {
		if row, selected := hard_drive_browser_selected_row(model); selected {
			_ = hard_drive_ui_buffer_set(model.name_input[:], row.name)
		}
	}
}

hard_drive_browser_request_close :: proc(
	model: ^Hard_Drive_Browser_Model,
) -> Hard_Drive_UI_Action {
	if model == nil || !model.visible || model.progress.active {return {}}
	if model.pending_changes > 0 {
		hard_drive_browser_begin_prompt(model, .Close_With_Changes)
		return {}
	}
	return Hard_Drive_UI_Action{kind = .Close}
}

hard_drive_browser_show_conflict :: proc(
	model: ^Hard_Drive_Browser_Model,
	source_name, target_name: string,
) {
	if model == nil {return}
	model.conflict = Hard_Drive_Browser_Conflict {
		active      = true,
		source_name = source_name,
		target_name = target_name,
	}
	model.conflict_open_requested = true
}

hard_drive_browser_import_files_request :: proc() -> Hard_Drive_Dialog_Request {
	return Hard_Drive_Dialog_Request {
		kind = .Open_Files,
		purpose = .Import_Files,
		title = "Import files into C drive",
		allow_multiple = true,
	}
}

hard_drive_browser_import_folder_request :: proc() -> Hard_Drive_Dialog_Request {
	return Hard_Drive_Dialog_Request {
		kind = .Select_Folder,
		purpose = .Import_Folder,
		title = "Import folder into C drive",
	}
}

hard_drive_browser_export_request :: proc(
	model: ^Hard_Drive_Browser_Model,
) -> Hard_Drive_Dialog_Request {
	row, selected := hard_drive_browser_selected_row(model)
	if !selected {return {}}
	request := Hard_Drive_Dialog_Request {
		purpose        = .Export_Entry,
		title          = "Export from C drive",
		suggested_path = row.name,
	}
	request.kind = row.kind == .Directory ? .Select_Folder : .Save_File
	return request
}

hard_drive_browser_accept_dialog :: proc(
	model: ^Hard_Drive_Browser_Model,
	result: Hard_Drive_Dialog_Result,
) -> Hard_Drive_UI_Action {
	if model == nil || !result.accepted || len(result.paths) == 0 {
		return {}
	}
	switch result.purpose {
	case .Import_Files, .Import_Folder:
		if !hard_drive_browser_can_mutate(model) {return {}}
		return Hard_Drive_UI_Action{kind = .Import, paths = result.paths}
	case .Export_Entry:
		if !hard_drive_browser_can_export(model) {return {}}
		row, selected := hard_drive_browser_selected_row(model)
		if !selected || len(result.paths) != 1 {return {}}
		return Hard_Drive_UI_Action {
			kind = .Export,
			path = result.paths[0],
			entry_id = row.id,
			recursive = row.kind == .Directory,
		}
	case .None, .Select_Image, .Create_Image_Path, .Install_ISO, .Quick_Install_ISO,
	     .Install_Boot_Floppy:
	}
	return {}
}

hard_drive_browser_accept_drop :: proc(
	model: ^Hard_Drive_Browser_Model,
	paths: []string,
) -> Hard_Drive_UI_Action {
	return hard_drive_browser_accept_dialog(
		model,
		Hard_Drive_Dialog_Result {
			purpose = .Import_Files,
			accepted = len(paths) > 0,
			paths = paths,
		},
	)
}

hard_drive_browser_accept_result :: proc(
	model: ^Hard_Drive_Browser_Model,
	result: Hard_Drive_UI_Result,
) {
	if model == nil {return}
	switch result.kind {
	case .Directory_Page:
		model.current_path = result.current_path
		model.breadcrumbs = result.breadcrumbs
		model.tree_nodes = result.tree_nodes
		model.rows = result.rows
		model.page_index = max(0, result.page_index)
		model.page_count = max(1, result.page_count)
		model.page_count_exact = result.page_count_exact
		model.total_entries = result.total_entries
		model.total_entries_exact = result.total_entries_exact
		model.pending_changes = max(0, result.pending_changes)
		model.pending_delete_count = 0
		hard_drive_browser_clear_selection(model)
		model.progress = {}
		model.diagnostic = ""
	case .Busy, .Progress:
		model.progress = result.progress
		model.progress.active = true
		model.diagnostic = ""
	case .Operation_Complete:
		model.progress = {}
		model.pending_changes = max(0, result.pending_changes)
		model.diagnostic = ""
	case .Conflict:
		model.progress = {}
		hard_drive_browser_show_conflict(model, result.conflict_source, result.conflict_target)
	case .Error:
		model.progress = {}
		model.diagnostic = result.diagnostic
	case .None, .Sparse_Unsupported, .Image_Created, .Image_Created_Unselected, .Cancelled:
	}
}

hard_drive_create_draw :: proc(model: ^Hard_Drive_Create_Model) -> Hard_Drive_UI_Action {
	action: Hard_Drive_UI_Action
	if model == nil || !model.visible {return action}
	hard_drive_create_invalidate_sparse_confirmation(model)
	imgui.SetNextWindowSize({620, 0}, .FirstUseEver)
	window_open := model.visible
	if win98_begin_window(HARD_DRIVE_CREATE_TITLE, &window_open, {.AlwaysAutoResize, .NoCollapse}) {
		imgui.TextUnformatted("Create a sparse, MBR-partitioned FAT32 image.")
		imgui.BeginDisabled(model.busy || model.created_unselected)
		imgui.SetNextItemWidth(480)
		if imgui.InputText(
			HARD_DRIVE_CREATE_PATH_LABEL,
			cstring(&model.path[0]),
			uint(len(model.path)),
			{.ElideLeft},
		) {
			hard_drive_create_invalidate_sparse_confirmation(model)
		}
		imgui.SameLine()
		if imgui.Button("Browse...") {
			action = Hard_Drive_UI_Action {
				kind   = .Request_Native_Dialog,
				dialog = hard_drive_create_dialog_request(model),
			}
		}
		imgui.EndDisabled()

		imgui.BeginDisabled(model.busy || model.created_unselected)
		imgui.SetNextItemWidth(140)
		if imgui.InputInt(HARD_DRIVE_CREATE_SIZE_LABEL, &model.size_gib, 1, 8, {.CharsDecimal}) {
			hard_drive_create_invalidate_sparse_confirmation(model)
		}
		imgui.EndDisabled()
		imgui.TextDisabled("Whole GiB, from 1 through 127. The default is 20 GiB.")
		if !hard_drive_create_size_valid(model.size_gib) {
			imgui.TextUnformatted("Enter a whole size from 1 through 127 GiB.")
		}

		if model.allocation == .Confirmation_Required && !model.created_unselected {
			imgui.Separator()
			imgui.TextUnformatted("Sparse files are unavailable at this location.")
			imgui.Text(
				"Creating this image may allocate the full %d GiB immediately.",
				model.size_gib,
			)
			if imgui.Button(HARD_DRIVE_CREATE_FULL_BUTTON_LABEL) {
				action = hard_drive_create_action(model, true)
			}
		}

		if model.busy {
			imgui.Separator()
			progress := clamp(model.progress, f32(0), f32(1))
			overlay: cstring = nil
			if len(model.progress_message) > 0 {
				overlay = fmt.ctprintf("%s", model.progress_message)
			}
			imgui.ProgressBar(progress, {-1, 0}, overlay)
			if model.cancellable && imgui.Button("Cancel operation") {
				action = Hard_Drive_UI_Action {
					kind = .Cancel_Operation,
				}
			}
		}
		if len(model.diagnostic) > 0 {
			imgui.Separator()
			menu_text(model.diagnostic)
		}

		imgui.Separator()
		if model.created_unselected {
			if imgui.Button("Select Created Image") {
				action = hard_drive_create_select_action(model)
			}
		} else {
			imgui.BeginDisabled(!hard_drive_create_can_submit(model))
			if imgui.Button(HARD_DRIVE_CREATE_BUTTON_LABEL) {
				action = hard_drive_create_action(model)
			}
			imgui.EndDisabled()
		}
		imgui.SameLine()
		imgui.BeginDisabled(model.busy)
		if imgui.Button("Cancel") {model.visible = false}
		imgui.EndDisabled()
	}
	imgui.End()
	if !window_open && !model.busy {model.visible = false}
	return action
}

hard_drive_browser_draw :: proc(
	model: ^Hard_Drive_Browser_Model,
	icons: ^Ui_Icon_Textures = nil,
) -> Hard_Drive_UI_Action {
	action: Hard_Drive_UI_Action
	if model == nil || !model.visible {return action}
	imgui.SetNextWindowSize({1000, 680}, .FirstUseEver)
	window_open := model.visible
	if win98_begin_window(HARD_DRIVE_BROWSER_TITLE, &window_open, {.NoCollapse}) {
		if len(model.image_path) > 0 {
			imgui.Text("Image: %s", fmt.ctprintf("%s", model.image_path))
		}
		if model.machine_running {
			imgui.TextUnformatted("Browsing is unavailable while the machine is running.")
		}
		if model.read_only {
			imgui.TextUnformatted("This image is open read-only. Changes cannot be staged.")
		}

		hard_drive_browser_draw_toolbar(model, &action)
		imgui.Separator()
		hard_drive_browser_draw_breadcrumbs(model, &action)

		available := imgui.GetContentRegionAvail()
		content_height := max(f32(180), available.y - 92)
		if imgui.BeginChild("##hard-drive-tree", {240, content_height}, {.Borders, .ResizeX}) {
			hard_drive_browser_draw_tree(model, icons, &action)
		}
		imgui.EndChild()
		imgui.SameLine()
		if imgui.BeginChild("##hard-drive-rows", {0, content_height}, {.Borders}) {
			hard_drive_browser_draw_rows(model, icons, &action)
		}
		imgui.EndChild()

		hard_drive_browser_draw_status(model, &action)
		if len(model.diagnostic) > 0 {
			imgui.Separator()
			menu_text(model.diagnostic)
		}
		hard_drive_browser_draw_prompt(model, &action)
		hard_drive_browser_draw_conflict(model, &action)
	}
	imgui.End()
	if !window_open {
		model.visible = true
		close_action := hard_drive_browser_request_close(model)
		if close_action.kind != .None {action = close_action}
	}
	return action
}

hard_drive_browser_draw_toolbar :: proc(
	model: ^Hard_Drive_Browser_Model,
	action: ^Hard_Drive_UI_Action,
) {
	mutate := hard_drive_browser_can_mutate(model)
	selected := hard_drive_browser_can_use_selection(model)
	single_selected := hard_drive_browser_can_use_single_selection(model)
	exportable := hard_drive_browser_can_export(model)
	imgui.BeginDisabled(!mutate)
	if imgui.Button(HARD_DRIVE_IMPORT_FILES_LABEL) && action.kind == .None {
		action^ = Hard_Drive_UI_Action {
			kind   = .Request_Native_Dialog,
			dialog = hard_drive_browser_import_files_request(),
		}
	}
	imgui.SameLine()
	if imgui.Button(HARD_DRIVE_IMPORT_FOLDER_LABEL) && action.kind == .None {
		action^ = Hard_Drive_UI_Action {
			kind   = .Request_Native_Dialog,
			dialog = hard_drive_browser_import_folder_request(),
		}
	}
	imgui.EndDisabled()
	imgui.SameLine()
	imgui.BeginDisabled(!exportable)
	if imgui.Button(HARD_DRIVE_EXPORT_LABEL) && action.kind == .None {
		action^ = Hard_Drive_UI_Action {
			kind   = .Request_Native_Dialog,
			dialog = hard_drive_browser_export_request(model),
		}
	}
	imgui.EndDisabled()
	imgui.SameLine()
	imgui.BeginDisabled(!mutate)
	if imgui.Button(HARD_DRIVE_NEW_FOLDER_LABEL) {
		hard_drive_browser_begin_prompt(model, .New_Folder)
	}
	imgui.EndDisabled()
	imgui.SameLine()
	imgui.BeginDisabled(!single_selected)
	if imgui.Button(HARD_DRIVE_RENAME_LABEL) {
		hard_drive_browser_begin_prompt(model, .Rename)
	}
	imgui.EndDisabled()
	imgui.SameLine()
	imgui.BeginDisabled(!selected)
	if imgui.Button(HARD_DRIVE_DELETE_LABEL) {
		hard_drive_browser_begin_prompt(model, .Delete)
	}
	imgui.EndDisabled()
	imgui.SameLine()
	imgui.BeginDisabled(model.progress.active)
	if imgui.Button("Refresh") && action.kind == .None {
		action^ = Hard_Drive_UI_Action {
			kind = .Refresh,
		}
	}
	imgui.EndDisabled()
}

hard_drive_browser_draw_breadcrumbs :: proc(
	model: ^Hard_Drive_Browser_Model,
	action: ^Hard_Drive_UI_Action,
) {
	if len(model.breadcrumbs) == 0 {
		menu_text(model.current_path)
		return
	}
	for crumb, index in model.breadcrumbs {
		if index > 0 {
			imgui.SameLine()
			imgui.TextUnformatted(">")
			imgui.SameLine()
		}
		if imgui.SmallButton(fmt.ctprintf("%s##breadcrumb-%d", crumb.label, index)) &&
		   hard_drive_browser_can_browse(model) &&
		   action.kind == .None {
			action^ = Hard_Drive_UI_Action {
				kind = .Navigate,
				path = crumb.path,
			}
		}
	}
}

hard_drive_browser_draw_tree :: proc(
	model: ^Hard_Drive_Browser_Model,
	icons: ^Ui_Icon_Textures,
	action: ^Hard_Drive_UI_Action,
) {
	if len(model.tree_nodes) == 0 {
		imgui.TextDisabled("No folders")
		return
	}
	for node, index in model.tree_nodes {
		indent := f32(max(0, node.depth)) * 14
		if indent > 0 {imgui.Indent(indent)}
		imgui.PushIDInt(i32(index))
		if node.load_more {
			if imgui.SmallButton(fmt.ctprintf("%s", node.name)) &&
			   hard_drive_browser_can_browse(model) &&
			   action.kind == .None {
				action^ = Hard_Drive_UI_Action {
					kind       = .Load_Tree_Page,
					path       = node.path,
					page_index = node.page_index,
				}
			}
			imgui.PopID()
			if indent > 0 {imgui.Unindent(indent)}
			continue
		}
		if node.has_children {
			toggle: cstring = node.expanded ? "-" : "+"
			if imgui.SmallButton(toggle) &&
			   hard_drive_browser_can_browse(model) &&
			   action.kind == .None {
				action^ = Hard_Drive_UI_Action {
					kind     = .Toggle_Tree_Node,
					entry_id = node.id,
					path     = node.path,
				}
			}
			imgui.SameLine()
		}
		if icons != nil {
			role: Ui_Icon_Role = .Folder_16
			if node.depth == 0 {
				role = .Hard_Drive_16
			} else if node.expanded {
				role = .Folder_Open_16
			}
			icon := ui_icon_texture(icons, role)
			if icon.texture != nil {
				imgui.Image(win98_texture_ref(icon), {16, 16})
				imgui.SameLine()
			}
		}
		if node.selected {
			imgui.PushStyleColorImVec4(.Text, theme_color(THEME_LIGHT))
			imgui.PushStyleColorImVec4(.HeaderHovered, theme_color(THEME_NAVY))
			imgui.PushStyleColorImVec4(.HeaderActive, theme_color(THEME_NAVY))
		}
		selected_clicked := imgui.Selectable(
			fmt.ctprintf("%s", node.name),
			node.selected,
			{.SpanAllColumns},
		)
		if node.selected {imgui.PopStyleColor(3)}
		if selected_clicked &&
		   hard_drive_browser_can_browse(model) &&
		   action.kind == .None {
			action^ = Hard_Drive_UI_Action {
				kind     = .Navigate,
				entry_id = node.id,
				path     = node.path,
			}
		}
		imgui.PopID()
		if indent > 0 {imgui.Unindent(indent)}
	}
}

hard_drive_browser_draw_row_context_menu :: proc(
	model: ^Hard_Drive_Browser_Model,
	row: ^Hard_Drive_Browser_Row,
	action: ^Hard_Drive_UI_Action,
) {
	if model == nil || row == nil || action == nil {return}
	if !imgui.BeginPopupContextItem() {return}
	if !row.pending_deletion && !hard_drive_browser_selection_contains(model, row.id) {
		_ = hard_drive_browser_select_only(model, row.id)
	}
	single := model.selection_count == 1 && !row.pending_deletion
	browsable := hard_drive_browser_can_browse(model)
	mutable := hard_drive_browser_can_mutate(model)
	if imgui.MenuItem("Open", "Enter", false, single && row.kind == .Directory && browsable) &&
	   action.kind == .None {
		action^ = {
			kind     = .Navigate,
			entry_id = row.id,
			path     = row.path,
		}
	}
	if imgui.MenuItem(HARD_DRIVE_EXPORT_LABEL, nil, false, single && browsable) &&
	   action.kind == .None {
		action^ = {
			kind   = .Request_Native_Dialog,
			dialog = hard_drive_browser_export_request(model),
		}
	}
	if imgui.MenuItem(HARD_DRIVE_RENAME_LABEL, nil, false, single && mutable) {
		hard_drive_browser_begin_prompt(model, .Rename)
	}
	delete_label :=
		model.selection_count == 1 ? "Delete 1 Item..." : fmt.ctprintf("Delete %d Items...", model.selection_count)
	if imgui.MenuItem(delete_label, "Delete", false, model.selection_count > 0 && mutable) {
		hard_drive_browser_begin_prompt(model, .Delete)
	}
	if imgui.MenuItem("Properties", nil, false, single) {
		hard_drive_browser_begin_prompt(model, .Properties)
	}
	imgui.EndPopup()
}

hard_drive_browser_draw_background_context_menu :: proc(
	model: ^Hard_Drive_Browser_Model,
	action: ^Hard_Drive_UI_Action,
) {
	if model == nil ||
	   action == nil ||
	   !imgui.BeginPopupContextWindow(
			   "##hard-drive-background-menu",
			   imgui.PopupFlags(
				   imgui.PopupFlags_MouseButtonRight | imgui.PopupFlags_NoOpenOverItems,
			   ),
		   ) {
		return
	}
	mutable := hard_drive_browser_can_mutate(model)
	if imgui.MenuItem(HARD_DRIVE_IMPORT_FILES_LABEL, nil, false, mutable) && action.kind == .None {
		action^ = {
			kind   = .Request_Native_Dialog,
			dialog = hard_drive_browser_import_files_request(),
		}
	}
	if imgui.MenuItem(HARD_DRIVE_IMPORT_FOLDER_LABEL, nil, false, mutable) &&
	   action.kind == .None {
		action^ = {
			kind   = .Request_Native_Dialog,
			dialog = hard_drive_browser_import_folder_request(),
		}
	}
	if imgui.MenuItem(HARD_DRIVE_NEW_FOLDER_LABEL, nil, false, mutable) {
		hard_drive_browser_begin_prompt(model, .New_Folder)
	}
	if imgui.MenuItem("Refresh", nil, false, hard_drive_browser_can_browse(model)) &&
	   action.kind == .None {
		action.kind = .Refresh
	}
	if imgui.MenuItem("Select All", "Ctrl+A", false, len(model.rows) > 0) {
		hard_drive_browser_select_all(model)
	}
	imgui.EndPopup()
}

hard_drive_browser_draw_rows :: proc(
	model: ^Hard_Drive_Browser_Model,
	icons: ^Ui_Icon_Textures,
	action: ^Hard_Drive_UI_Action,
) {
	table_flags := imgui.TableFlags(
		imgui.TableFlags_RowBg |
		imgui.TableFlags_BordersInnerH |
		imgui.TableFlags_Resizable |
		imgui.TableFlags_ScrollY,
	)
	if imgui.BeginTable("##hard-drive-directory", 4, table_flags, {0, -34}) {
		imgui.TableSetupColumn("Name", {.WidthStretch})
		imgui.TableSetupColumn("Type", {.WidthFixed}, 90)
		imgui.TableSetupColumn("Size", {.WidthFixed}, 100)
		imgui.TableSetupColumn("Modified", {.WidthFixed}, 150)
		imgui.TableHeadersRow()
		selection_io := imgui.BeginMultiSelect(
			{.BoxSelect1d, .ClearOnClickVoid, .ClearOnEscape, .ScopeRect},
			i32(model.selection_count),
			i32(len(model.rows)),
		)
		hard_drive_browser_selection_apply_requests(model, selection_io)
		for &row, index in model.rows {
			imgui.TableNextRow()
			_ = imgui.TableSetColumnIndex(0)
			imgui.PushIDInt(i32(index))
			imgui.SetNextItemSelectionUserData(imgui.SelectionUserData(index))
			row_flags: imgui.SelectableFlags = {.SpanAllColumns, .AllowDoubleClick}
			if row.pending_deletion {row_flags += {.Disabled}}
			selected := hard_drive_browser_selection_contains(model, row.id)
			if selected {
				imgui.PushStyleColorImVec4(.HeaderHovered, theme_color(THEME_NAVY))
				imgui.PushStyleColorImVec4(.HeaderActive, theme_color(THEME_NAVY))
			}
			_ = imgui.Selectable(
				"##hard-drive-entry",
				selected,
				row_flags,
				{0, f32(THEME_FONT_PX + 5)},
			)
			if selected {imgui.PopStyleColor(2)}
			item_min := imgui.GetItemRectMin()
			item_max := imgui.GetItemRectMax()
			draw := imgui.GetWindowDrawList()
			text_x := item_min.x + 3
			if icons != nil {
				icon := ui_icon_texture(icons, hard_drive_browser_icon_role(&row))
				if icon.texture != nil {
					win98_draw_icon(draw, icon, {item_min.x + 2, item_min.y + 2}, 16)
					text_x = item_min.x + 22
				}
			}
			text_color := imgui.GetColorU32(.Text)
			if selected {text_color = win98_color(THEME_LIGHT)}
			if row.pending_deletion {text_color = imgui.GetColorU32(.TextDisabled)}
			display_name := fmt.ctprintf("%s", row.name)
			if row.pending_deletion {
				display_name = fmt.ctprintf("%s (Pending deletion)", row.name)
			}
			imgui.DrawList_AddText(
				draw,
				{text_x, item_min.y + (item_max.y - item_min.y - imgui.GetTextLineHeight()) * 0.5},
				text_color,
				display_name,
			)
			if row.kind == .Directory &&
			   !row.pending_deletion &&
			   hard_drive_browser_can_browse(model) &&
			   imgui.IsItemHovered() &&
			   imgui.IsMouseDoubleClicked(.Left) &&
			   action.kind == .None {
				action^ = {
					kind     = .Navigate,
					entry_id = row.id,
					path     = row.path,
				}
			}
			hard_drive_browser_draw_row_context_menu(model, &row, action)
			imgui.PopID()
			if selected {imgui.PushStyleColorImVec4(.Text, theme_color(THEME_LIGHT))}
			_ = imgui.TableSetColumnIndex(1)
			imgui.TextUnformatted(row.kind == .Directory ? "Folder" : "File")
			_ = imgui.TableSetColumnIndex(2)
			if row.kind == .File {imgui.Text("%s", hard_drive_browser_size_text(row.size))}
			_ = imgui.TableSetColumnIndex(3)
			menu_text(row.modified_text)
			if selected {imgui.PopStyleColor()}
		}
		selection_io = imgui.EndMultiSelect()
		hard_drive_browser_selection_apply_requests(model, selection_io)
		if imgui.IsWindowFocused() && action.kind == .None {
			if imgui.IsKeyPressed(.Delete, false) && hard_drive_browser_can_use_selection(model) {
				hard_drive_browser_begin_prompt(model, .Delete)
			} else if imgui.IsKeyPressed(.Enter, false) {
				if row, selected := hard_drive_browser_selected_row(model);
				   selected && row.kind == .Directory && hard_drive_browser_can_browse(model) {
					action^ = {
						kind     = .Navigate,
						entry_id = row.id,
						path     = row.path,
					}
				}
			}
		}
		hard_drive_browser_draw_background_context_menu(model, action)
		imgui.EndTable()
	}

	imgui.BeginDisabled(model.page_index <= 0 || !hard_drive_browser_can_browse(model))
	if imgui.Button("Previous") && action.kind == .None {
		action^ = Hard_Drive_UI_Action {
			kind       = .Load_Page,
			page_index = model.page_index - 1,
		}
	}
	imgui.EndDisabled()
	imgui.SameLine()
	page_count := max(1, model.page_count)
	if model.page_count_exact && model.total_entries_exact {
		imgui.Text(
			"Page %d of %d (%d entries)",
			model.page_index + 1,
			page_count,
			model.total_entries,
		)
	} else {
		imgui.Text("Page %d (%d+ entries)", model.page_index + 1, model.total_entries)
	}
	imgui.SameLine()
	imgui.BeginDisabled(
		model.page_index + 1 >= page_count || !hard_drive_browser_can_browse(model),
	)
	if imgui.Button("Next") && action.kind == .None {
		action^ = Hard_Drive_UI_Action {
			kind       = .Load_Page,
			page_index = model.page_index + 1,
		}
	}
	imgui.EndDisabled()
}

hard_drive_browser_draw_status :: proc(
	model: ^Hard_Drive_Browser_Model,
	action: ^Hard_Drive_UI_Action,
) {
	if model.progress.active {
		overlay: cstring = nil
		if len(model.progress.message) > 0 {overlay = fmt.ctprintf("%s", model.progress.message)}
		imgui.ProgressBar(hard_drive_browser_progress_fraction(model.progress), {-1, 0}, overlay)
		if model.progress.cancellable {
			imgui.SameLine()
			if imgui.Button("Cancel operation") && action.kind == .None {
				action^ = Hard_Drive_UI_Action {
					kind = .Cancel_Operation,
				}
			}
		}
	} else {
		if model.selection_count > 0 && model.pending_delete_count > 0 {
			imgui.Text(
				"%d selected; %d staged for deletion; %s",
				model.selection_count,
				model.pending_delete_count,
				hard_drive_browser_pending_label(model),
			)
		} else if model.selection_count > 0 {
			imgui.Text(
				"%d selected; %s",
				model.selection_count,
				hard_drive_browser_pending_label(model),
			)
		} else if model.pending_delete_count > 0 {
			imgui.Text(
				"%d staged for deletion; %s",
				model.pending_delete_count,
				hard_drive_browser_pending_label(model),
			)
		} else {
			imgui.TextUnformatted(hard_drive_browser_pending_label(model))
		}
	}
	imgui.SameLine()
	imgui.BeginDisabled(!hard_drive_browser_can_apply(model))
	if imgui.Button(HARD_DRIVE_APPLY_LABEL) && action.kind == .None {
		action^ = Hard_Drive_UI_Action {
			kind = .Apply,
		}
	}
	imgui.SameLine()
	if imgui.Button(HARD_DRIVE_DISCARD_LABEL) {
		hard_drive_browser_begin_prompt(model, .Discard)
	}
	imgui.EndDisabled()
	imgui.SameLine()
	imgui.BeginDisabled(model.progress.active)
	if imgui.Button("Close") && action.kind == .None {
		close_action := hard_drive_browser_request_close(model)
		if close_action.kind != .None {action^ = close_action}
	}
	imgui.EndDisabled()
}

hard_drive_browser_draw_prompt :: proc(
	model: ^Hard_Drive_Browser_Model,
	action: ^Hard_Drive_UI_Action,
) {
	if model.prompt == .None {return}
	popup_name := hard_drive_browser_prompt_name(model.prompt)
	if model.prompt_open_requested {
		imgui.OpenPopup(popup_name)
		model.prompt_open_requested = false
	}
	if !win98_begin_popup_modal(popup_name, nil, {.AlwaysAutoResize}) {return}
	switch model.prompt {
	case .New_Folder, .Rename:
		message: cstring = model.prompt == .New_Folder ? "New folder name" : "New name"
		imgui.SetNextItemWidth(360)
		_ = imgui.InputText(
			message,
			cstring(&model.name_input[0]),
			uint(len(model.name_input)),
			{.AutoSelectAll},
		)
		name := hard_drive_ui_buffer_string(model.name_input[:])
		imgui.BeginDisabled(len(name) == 0)
		if imgui.Button(model.prompt == .New_Folder ? "Create" : "Rename") {
			action.kind = model.prompt == .New_Folder ? .New_Folder : .Rename
			action.name = name
			if model.prompt == .Rename {
				if row, selected := hard_drive_browser_selected_row(model); selected {
					action.entry_id = row.id
				}
			}
			model.prompt = .None
			imgui.CloseCurrentPopup()
		}
		imgui.EndDisabled()
		imgui.SameLine()
		if imgui.Button("Cancel") {
			model.prompt = .None
			imgui.CloseCurrentPopup()
		}
	case .Delete:
		snapshot, valid := hard_drive_browser_delete_snapshot(model)
		if valid {
			if snapshot.count == 1 {
				if row, selected := hard_drive_browser_selected_row(model); selected {
					menu_text(fmt.tprintf("Delete %s from the staged C drive?", row.name))
				}
			} else {
				menu_text(
					fmt.tprintf(
						"Delete %d selected items from the staged C drive?",
						snapshot.count,
					),
				)
			}
			if snapshot.directory_count > 0 {
				menu_text("Selected folders and all of their contents will be removed.")
			}
			menu_text("The image is unchanged until you click Apply.")
			if imgui.Button("Delete") {
				action^ = {
					kind            = .Delete,
					delete_snapshot = snapshot,
				}
				model.prompt = .None
				imgui.CloseCurrentPopup()
			}
			imgui.SameLine()
		}
		if imgui.Button("Cancel") {
			model.prompt = .None
			imgui.CloseCurrentPopup()
		}
	case .Properties:
		if row, selected := hard_drive_browser_selected_row(model); selected {
			menu_text(row.name)
			menu_text(fmt.tprintf("Type: %s", row.kind == .Directory ? "Folder" : "File"))
			if row.kind == .File {
				menu_text(fmt.tprintf("Size: %s", hard_drive_browser_size_text(row.size)))
			}
			if len(row.modified_text) > 0 {
				menu_text(fmt.tprintf("Modified: %s", row.modified_text))
			}
			menu_text(fmt.tprintf("Path: C:\\%s", row.path))
		}
		if imgui.Button("OK") {
			model.prompt = .None
			imgui.CloseCurrentPopup()
		}
	case .Discard:
		menu_text("Discard every pending change and leave the image unchanged?")
		if imgui.Button("Discard") {
			action^ = Hard_Drive_UI_Action {
				kind = .Discard,
			}
			model.prompt = .None
			imgui.CloseCurrentPopup()
		}
		imgui.SameLine()
		if imgui.Button("Cancel") {
			model.prompt = .None
			imgui.CloseCurrentPopup()
		}
	case .Close_With_Changes:
		menu_text("There are pending changes. Apply or discard them before closing?")
		if imgui.Button("Apply") {
			action^ = Hard_Drive_UI_Action {
				kind        = .Apply,
				close_after = true,
			}
			model.prompt = .None
			imgui.CloseCurrentPopup()
		}
		imgui.SameLine()
		if imgui.Button("Discard") {
			action^ = Hard_Drive_UI_Action {
				kind        = .Discard,
				close_after = true,
			}
			model.prompt = .None
			imgui.CloseCurrentPopup()
		}
		imgui.SameLine()
		if imgui.Button("Cancel") {
			action.kind = .Cancel_Close
			model.prompt = .None
			imgui.CloseCurrentPopup()
		}
	case .None:
	}
	imgui.EndPopup()
}

hard_drive_browser_draw_conflict :: proc(
	model: ^Hard_Drive_Browser_Model,
	action: ^Hard_Drive_UI_Action,
) {
	if !model.conflict.active {return}
	if model.conflict_open_requested {
		imgui.OpenPopup("File conflict")
		model.conflict_open_requested = false
	}
	if !win98_begin_popup_modal("File conflict", nil, {.AlwaysAutoResize}) {return}
	menu_text(fmt.tprintf("%s already exists.", model.conflict.target_name))
	if len(model.conflict.source_name) > 0 {
		menu_text(fmt.tprintf("Incoming item: %s", model.conflict.source_name))
	}
	_ = imgui.Checkbox("Apply to all conflicts", &model.conflict.apply_to_all)
	resolutions := []Hard_Drive_Conflict_Resolution{.Replace, .Skip, .Cancel}
	for resolution, index in resolutions {
		if index > 0 {imgui.SameLine()}
		label: cstring =
			resolution == .Replace ? "Replace" : resolution == .Skip ? "Skip" : "Cancel"
		if imgui.Button(label) {
			action^ = Hard_Drive_UI_Action {
				kind                = .Resolve_Conflict,
				conflict_resolution = resolution,
				apply_to_all        = model.conflict.apply_to_all,
			}
			model.conflict.active = false
			imgui.CloseCurrentPopup()
		}
	}
	imgui.EndPopup()
}

hard_drive_browser_prompt_name :: proc(prompt: Hard_Drive_Browser_Prompt) -> cstring {
	switch prompt {
	case .New_Folder:
		return "New Folder"
	case .Rename:
		return "Rename"
	case .Delete:
		return "Delete Selected Items"
	case .Properties:
		return "Properties"
	case .Discard:
		return "Discard Changes"
	case .Close_With_Changes:
		return "Pending Changes"
	case .None:
		return "##no-hard-drive-prompt"
	}
	return "##no-hard-drive-prompt"
}

hard_drive_browser_size_text :: proc(size: u64) -> cstring {
	if size < 1024 {return fmt.ctprintf("%d B", size)}
	if size < 1024 * 1024 {return fmt.ctprintf("%.1f KiB", f64(size) / 1024)}
	if size < 1024 * 1024 * 1024 {return fmt.ctprintf("%.1f MiB", f64(size) / (1024 * 1024))}
	return fmt.ctprintf("%.1f GiB", f64(size) / (1024 * 1024 * 1024))
}
