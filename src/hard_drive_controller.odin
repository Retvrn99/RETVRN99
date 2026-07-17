// SPDX-License-Identifier: GPL-3.0-only
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "fat32session"
import "host"
import "securehost"

HARD_DRIVE_BROWSER_PAGE_SIZE :: fat32session.EDIT_PAGE_ENTRY_LIMIT
HARD_DRIVE_EXPORT_MAX_DEPTH :: 64
HARD_DRIVE_TREE_MAX_DEPTH :: 64
HARD_DRIVE_TREE_PAGE_SIZE :: min(
	max(1, #config(HARD_DRIVE_TREE_PAGE_SIZE, fat32session.EDIT_PAGE_ENTRY_LIMIT)),
	fat32session.EDIT_PAGE_ENTRY_LIMIT,
)
HARD_DRIVE_TREE_MAX_NODES ::
	(HARD_DRIVE_TREE_MAX_DEPTH + 1) * (HARD_DRIVE_TREE_PAGE_SIZE + 2) + 1

Hard_Drive_Controller_Operation :: enum u8 {
	None,
	Import,
	Export_File,
	Export_Tree,
	Delete,
	Apply,
}

Hard_Drive_Import_Item :: struct {
	host_path:  string,
	guest_path: string,
	directory:  bool,
}

Hard_Drive_Export_Frame :: struct {
	guest_path: string,
	host_path:  string,
	cursor:     u64,
	directory:  securehost.Directory,
}

Hard_Drive_Tree_State :: struct {
	path:       string,
	page_index: int,
}

Hard_Drive_Controller :: struct {
	adapter:               fat32session.Adapter_Kind,
	session:               ^fat32session.Edit_Session,
	model:                 host.Hard_Drive_Browser_Model,
	image_path:            string,
	current_path:          string,
	diagnostic:            string,
	progress_message:      string,
	conflict_source:       string,
	conflict_target:       string,
	page_index:            int,
	pending_operations:    int,
	session_serial:        u64,
	operation:             Hard_Drive_Controller_Operation,
	job_active:            bool,
	imports:               [dynamic]Hard_Drive_Import_Item,
	import_index:          int,
	conflict_pending:      bool,
	conflict_resolution:   host.Hard_Drive_Conflict_Resolution,
	conflict_apply_to_all: bool,
	export_frames:         [HARD_DRIVE_EXPORT_MAX_DEPTH]Hard_Drive_Export_Frame,
	export_depth:          int,
	export_root:           string,
	close_after_finish:    bool,
	apply_step_armed:      bool,
	apply_cancellable:     bool,
	apply_failed:          bool,
	tree_state:            [dynamic]Hard_Drive_Tree_State,
	breadcrumbs:           [dynamic]host.Hard_Drive_Breadcrumb,
	tree_nodes:            [dynamic]host.Hard_Drive_Tree_Node,
	rows:                  [dynamic]host.Hard_Drive_Browser_Row,
}

hard_drive_controller_init :: proc(
	controller: ^Hard_Drive_Controller,
	adapter := fat32session.DEFAULT_ADAPTER,
) {
	if controller == nil {return}
	controller^ = {}
	controller.adapter = adapter
	host.hard_drive_browser_init(&controller.model)
}

hard_drive_controller_ready :: proc(controller: ^Hard_Drive_Controller) -> bool {
	return controller != nil && fat32session.edit_ready(controller.session)
}

hard_drive_controller_is_open :: proc(controller: ^Hard_Drive_Controller) -> bool {
	return controller != nil && controller.model.visible
}

hard_drive_controller_set_diagnostic :: proc(
	controller: ^Hard_Drive_Controller,
	diagnostic: string,
) {
	if controller == nil {return}
	delete(controller.diagnostic)
	controller.diagnostic = strings.clone(diagnostic)
	controller.model.diagnostic = controller.diagnostic
}

hard_drive_controller_clear_progress :: proc(controller: ^Hard_Drive_Controller) {
	if controller == nil {return}
	delete(controller.progress_message)
	controller.progress_message = ""
	controller.model.progress = {}
}

hard_drive_controller_set_progress :: proc(
	controller: ^Hard_Drive_Controller,
	message: string,
	completed, total: u64,
	cancellable := true,
) {
	if controller == nil {return}
	owned_message := strings.clone(message)
	delete(controller.progress_message)
	controller.progress_message = owned_message
	controller.model.progress = {
		active      = true,
		completed   = completed,
		total       = total,
		message     = controller.progress_message,
		cancellable = cancellable,
	}
}

hard_drive_controller_clear_tree_nodes :: proc(controller: ^Hard_Drive_Controller) {
	if controller == nil {return}
	for &node in controller.tree_nodes {
		delete(node.name)
		delete(node.path)
	}
	delete(controller.tree_nodes)
	controller.tree_nodes = nil
	controller.model.tree_nodes = nil
}

hard_drive_controller_clear_view :: proc(controller: ^Hard_Drive_Controller) {
	if controller == nil {return}
	for &crumb in controller.breadcrumbs {
		delete(crumb.label)
		delete(crumb.path)
	}
	delete(controller.breadcrumbs)
	controller.breadcrumbs = nil
	hard_drive_controller_clear_tree_nodes(controller)
	for &row in controller.rows {
		delete(row.name)
		delete(row.path)
		delete(row.modified_text)
	}
	delete(controller.rows)
	controller.rows = nil
	controller.model.breadcrumbs = nil
	controller.model.rows = nil
}

hard_drive_controller_clear_tree_state :: proc(controller: ^Hard_Drive_Controller) {
	if controller == nil {return}
	for &state in controller.tree_state {delete(state.path)}
	delete(controller.tree_state)
	controller.tree_state = nil
}

hard_drive_controller_clear_conflict :: proc(controller: ^Hard_Drive_Controller) {
	if controller == nil {return}
	delete(controller.conflict_source)
	delete(controller.conflict_target)
	controller.conflict_source = ""
	controller.conflict_target = ""
	controller.conflict_pending = false
	controller.model.conflict = {}
}

hard_drive_controller_clear_imports :: proc(controller: ^Hard_Drive_Controller) {
	if controller == nil {return}
	for &item in controller.imports {
		delete(item.host_path)
		delete(item.guest_path)
	}
	delete(controller.imports)
	controller.imports = nil
	controller.import_index = 0
	controller.conflict_resolution = .None
	controller.conflict_apply_to_all = false
	hard_drive_controller_clear_conflict(controller)
}

hard_drive_controller_export_frame_destroy :: proc(frame: ^Hard_Drive_Export_Frame) {
	if frame == nil {return}
	securehost.close_directory(&frame.directory)
	delete(frame.guest_path)
	delete(frame.host_path)
	frame^ = {}
}

hard_drive_controller_clear_export :: proc(
	controller: ^Hard_Drive_Controller,
) {
	if controller == nil {return}
	for index in 0 ..< controller.export_depth {
		hard_drive_controller_export_frame_destroy(&controller.export_frames[index])
	}
	controller.export_depth = 0
	delete(controller.export_root)
	controller.export_root = ""
}

hard_drive_controller_close_retain :: proc(controller: ^Hard_Drive_Controller) {
	if controller == nil || controller.session == nil {return}
	_ = fat32session.edit_close_retain(controller.session)
	controller.session = nil
}

hard_drive_controller_destroy :: proc(controller: ^Hard_Drive_Controller) {
	if controller == nil {return}
	if controller.job_active && controller.session != nil {
		_ = fat32session.edit_job_cancel(controller.session)
		controller.job_active = false
	}
	if controller.operation == .Apply && controller.apply_cancellable && controller.session != nil {
		_ = fat32session.edit_cancel_apply(controller.session)
	}
	hard_drive_controller_close_retain(controller)
	hard_drive_controller_clear_imports(controller)
	hard_drive_controller_clear_export(controller)
	hard_drive_controller_clear_view(controller)
	hard_drive_controller_clear_tree_state(controller)
	hard_drive_controller_clear_progress(controller)
	delete(controller.image_path)
	delete(controller.current_path)
	delete(controller.diagnostic)
	controller^ = {}
}

hard_drive_controller_session_id :: proc(controller: ^Hard_Drive_Controller) -> string {
	controller.session_serial += 1
	return strings.clone(
		fmt.tprintf("browser-%d-%d-%d", os.get_pid(), time.tick_now(), controller.session_serial),
	)
}

hard_drive_controller_open_session :: proc(controller: ^Hard_Drive_Controller) -> bool {
	if controller == nil || controller.image_path == "" {return false}
	session_id := hard_drive_controller_session_id(controller)
	defer delete(session_id)
	session, open_error := fat32session.open_edit(
		controller.image_path,
		session_id,
		0,
		controller.adapter,
	)
	if open_error.code != .None {
		hard_drive_controller_set_diagnostic(controller, fat32session.error_text(&open_error))
		controller.model.read_only = true
		return false
	}
	controller.session = session
	controller.model.read_only = false
	if fat32session.edit_changed_sector_count(session) > 0 {
		controller.pending_operations = max(controller.pending_operations, 1)
	}
	return true
}

hard_drive_controller_open :: proc(
	controller: ^Hard_Drive_Controller,
	image_path: string,
	machine_running := false,
) -> bool {
	if controller == nil || image_path == "" || machine_running {return false}
	if controller.session != nil {
		hard_drive_controller_close_retain(controller)
	}
	hard_drive_controller_clear_imports(controller)
	hard_drive_controller_clear_export(controller)
	hard_drive_controller_clear_view(controller)
	hard_drive_controller_clear_tree_state(controller)
	append(
		&controller.tree_state,
		Hard_Drive_Tree_State{path = strings.clone(""), page_index = 0},
	)
	hard_drive_controller_clear_progress(controller)
	delete(controller.image_path)
	controller.image_path = strings.clone(image_path)
	delete(controller.current_path)
	controller.current_path = strings.clone("")
	controller.page_index = 0
	controller.pending_operations = 0
	controller.operation = .None
	controller.job_active = false
	controller.apply_step_armed = false
	controller.apply_cancellable = false
	controller.apply_failed = false
	controller.model.visible = true
	controller.model.machine_running = false
	controller.model.image_path = controller.image_path
	controller.model.current_path = controller.current_path
	controller.model.selected_index = -1
	hard_drive_controller_set_diagnostic(controller, "")
	if !hard_drive_controller_open_session(controller) {return false}
	return hard_drive_controller_refresh(controller, "", 0)
}

hard_drive_controller_path_id :: proc(path: string, directory := false) -> u64 {
	hash := u64(14695981039346656037)
	for byte in transmute([]u8)path {
		hash = (hash ~ u64(byte)) * 1099511628211
	}
	if directory {hash = (hash ~ 0xFF) * 1099511628211}
	if hash == 0 {return 1}
	return hash
}

hard_drive_controller_guest_join :: proc(parent, name: string) -> string {
	if parent == "" {return strings.clone(name)}
	return strings.concatenate({parent, "/", name})
}

hard_drive_controller_guest_name_safe :: proc(name: string) -> bool {
	return(
		name != "" &&
		name != "." &&
		name != ".." &&
		!strings.contains(name, "/") &&
		!strings.contains(name, "\\") &&
		!strings.contains(name, "\x00") \
	)
}

hard_drive_controller_build_breadcrumbs :: proc(controller: ^Hard_Drive_Controller) {
	append(
		&controller.breadcrumbs,
		host.Hard_Drive_Breadcrumb{label = strings.clone("C drive"), path = strings.clone("")},
	)
	if controller.current_path == "" {return}
	components := strings.split(controller.current_path, "/", context.temp_allocator)
	path := ""
	for component in components {
		next := hard_drive_controller_guest_join(path, component)
		append(
			&controller.breadcrumbs,
			host.Hard_Drive_Breadcrumb {
				label = strings.clone(component),
				path = strings.clone(next),
			},
		)
		delete(path)
		path = next
	}
	delete(path)
}

hard_drive_controller_tree_state_index :: proc(
	controller: ^Hard_Drive_Controller,
	path: string,
) -> int {
	if controller == nil {return -1}
	for state, index in controller.tree_state {
		if state.path == path {return index}
	}
	return -1
}

hard_drive_controller_tree_expand :: proc(
	controller: ^Hard_Drive_Controller,
	path: string,
) {
	if controller == nil || hard_drive_controller_tree_state_index(controller, path) >= 0 {return}
	prefix := path == "" ? "" : fmt.tprintf("%s/", path)
	for index := len(controller.tree_state) - 1; index >= 0; index -= 1 {
		candidate := controller.tree_state[index].path
		candidate_prefix := candidate == "" ? "" : fmt.tprintf("%s/", candidate)
		candidate_is_ancestor := candidate == "" || candidate == path ||
			strings.has_prefix(path, candidate_prefix)
		path_is_ancestor := path == "" || strings.has_prefix(candidate, prefix)
		if candidate_is_ancestor || path_is_ancestor {continue}
		delete(controller.tree_state[index].path)
		unordered_remove(&controller.tree_state, index)
	}
	append(
		&controller.tree_state,
		Hard_Drive_Tree_State{path = strings.clone(path), page_index = 0},
	)
}

hard_drive_controller_tree_collapse :: proc(
	controller: ^Hard_Drive_Controller,
	path: string,
) {
	if controller == nil {return}
	prefix := path == "" ? "" : fmt.tprintf("%s/", path)
	for index := len(controller.tree_state) - 1; index >= 0; index -= 1 {
		candidate := controller.tree_state[index].path
		remove := candidate == path
		if path != "" && strings.has_prefix(candidate, prefix) {remove = true}
		if path == "" {remove = true}
		if !remove {continue}
		delete(controller.tree_state[index].path)
		unordered_remove(&controller.tree_state, index)
	}
}

hard_drive_controller_tree_reveal :: proc(
	controller: ^Hard_Drive_Controller,
	path: string,
) {
	if path == "" {return}
	hard_drive_controller_tree_expand(controller, "")
	components := strings.split(path, "/", context.temp_allocator)
	ancestor := ""
	for component, index in components {
		if index == len(components) - 1 {break}
		next := hard_drive_controller_guest_join(ancestor, component)
		hard_drive_controller_tree_expand(controller, next)
		delete(ancestor)
		ancestor = next
	}
	delete(ancestor)
}

hard_drive_controller_build_tree_branch :: proc(
	controller: ^Hard_Drive_Controller,
	path, name: string,
	depth: int,
) -> bool {
	if controller == nil {return false}
	if depth > HARD_DRIVE_TREE_MAX_DEPTH {return true}
	if len(controller.tree_nodes) >= HARD_DRIVE_TREE_MAX_NODES {
		hard_drive_controller_set_diagnostic(
			controller,
			"The bounded folder-tree view could not represent the current expansion.",
		)
		return false
	}
	state_index := hard_drive_controller_tree_state_index(controller, path)
	expanded := state_index >= 0
	append(
		&controller.tree_nodes,
		host.Hard_Drive_Tree_Node {
			id           = hard_drive_controller_path_id(path, true),
			name         = strings.clone(name),
			path         = strings.clone(path),
			depth        = depth,
			has_children = true,
			expanded     = expanded,
			selected     = controller.current_path == path,
		},
	)
	if !expanded {return true}
	page_index := max(0, controller.tree_state[state_index].page_index)
	if page_index > 0 {
		append(
			&controller.tree_nodes,
			host.Hard_Drive_Tree_Node {
				id         = hard_drive_controller_path_id(fmt.tprintf("%s#%d", path, page_index - 1)),
				name       = strings.clone("Previous folders..."),
				path       = strings.clone(path),
				depth      = depth + 1,
				load_more  = true,
				page_index = page_index - 1,
			},
		)
	}
	page, list_error := fat32session.edit_list(
		controller.session,
		path,
		u64(page_index) * u64(HARD_DRIVE_TREE_PAGE_SIZE),
		HARD_DRIVE_TREE_PAGE_SIZE,
	)
	if list_error.code != .None {
		hard_drive_controller_set_diagnostic(controller, fat32session.error_text(&list_error))
		return false
	}
	for entry in page.entries {
		if !entry.is_directory {continue}
		child_path := hard_drive_controller_guest_join(path, entry.name)
		if !hard_drive_controller_build_tree_branch(
			controller,
			child_path,
			entry.name,
			depth + 1,
		) {
			delete(child_path)
			fat32session.edit_page_destroy(&page)
			return false
		}
		delete(child_path)
	}
	has_more := page.has_more
	fat32session.edit_page_destroy(&page)
	if has_more {
		append(
			&controller.tree_nodes,
			host.Hard_Drive_Tree_Node {
				id         = hard_drive_controller_path_id(fmt.tprintf("%s#%d", path, page_index + 1)),
				name       = strings.clone("More folders..."),
				path       = strings.clone(path),
				depth      = depth + 1,
				load_more  = true,
				page_index = page_index + 1,
			},
		)
	}
	return true
}

hard_drive_controller_build_tree :: proc(controller: ^Hard_Drive_Controller) -> bool {
	if controller == nil {return false}
	hard_drive_controller_tree_reveal(controller, controller.current_path)
	return hard_drive_controller_build_tree_branch(controller, "", "C drive", 0)
}

hard_drive_controller_refresh :: proc(
	controller: ^Hard_Drive_Controller,
	path: string,
	page_index: int,
) -> bool {
	if !hard_drive_controller_ready(controller) || controller.job_active {return false}
	selected_page := max(0, page_index)
	cursor := u64(selected_page) * u64(HARD_DRIVE_BROWSER_PAGE_SIZE)
	page, list_error := fat32session.edit_list(
		controller.session,
		path,
		cursor,
		HARD_DRIVE_BROWSER_PAGE_SIZE,
	)
	if list_error.code != .None {
		hard_drive_controller_set_diagnostic(controller, fat32session.error_text(&list_error))
		return false
	}
	defer fat32session.edit_page_destroy(&page)
	if len(page.entries) == 0 && selected_page > 0 {
		return hard_drive_controller_refresh(controller, path, selected_page - 1)
	}
	hard_drive_controller_clear_view(controller)
	delete(controller.current_path)
	controller.current_path = strings.clone(path)
	controller.page_index = selected_page
	hard_drive_controller_build_breadcrumbs(controller)
	if !hard_drive_controller_build_tree(controller) {return false}
	for entry in page.entries {
		entry_path := hard_drive_controller_guest_join(path, entry.name)
		append(
			&controller.rows,
			host.Hard_Drive_Browser_Row {
				id = hard_drive_controller_path_id(entry_path, entry.is_directory),
				kind = entry.is_directory ? .Directory : .File,
				name = strings.clone(entry.name),
				path = entry_path,
				size = entry.size,
				modified_text = strings.clone(
					hard_drive_controller_fat_timestamp(entry.modified_date, entry.modified_time),
				),
			},
		)
	}
	total_lower_bound := cursor + u64(len(page.entries))
	if page.has_more {total_lower_bound += 1}
	controller.model.current_path = controller.current_path
	controller.model.breadcrumbs = controller.breadcrumbs[:]
	controller.model.tree_nodes = controller.tree_nodes[:]
	controller.model.rows = controller.rows[:]
	controller.model.page_index = selected_page
	controller.model.page_count = selected_page + 1 + (page.has_more ? 1 : 0)
	controller.model.page_count_exact = !page.has_more
	controller.model.total_entries = total_lower_bound
	controller.model.total_entries_exact = !page.has_more
	controller.model.selected_index = -1
	controller.model.pending_changes = max(
		controller.pending_operations,
		fat32session.edit_changed_sector_count(controller.session) > 0 ? 1 : 0,
	)
	hard_drive_controller_clear_progress(controller)
	hard_drive_controller_set_diagnostic(controller, "")
	return true
}

hard_drive_controller_fat_timestamp :: proc(date, clock: u16) -> string {
	if date == 0 {return ""}
	year := 1980 + int(date >> 9)
	month := int(date >> 5 & 0x0F)
	day := int(date & 0x1F)
	hour := int(clock >> 11)
	minute := int(clock >> 5 & 0x3F)
	second := int(clock & 0x1F) * 2
	if month < 1 || month > 12 || day < 1 || day > 31 || hour > 23 || minute > 59 || second > 59 {
		return ""
	}
	return fmt.tprintf("%04d-%02d-%02d %02d:%02d:%02d", year, month, day, hour, minute, second)
}

hard_drive_controller_find_row :: proc(
	controller: ^Hard_Drive_Controller,
	entry_id: u64,
) -> (
	^host.Hard_Drive_Browser_Row,
	bool,
) {
	if controller == nil {return nil, false}
	for &row in controller.rows {
		if row.id == entry_id {return &row, true}
	}
	return nil, false
}

hard_drive_controller_note_change :: proc(controller: ^Hard_Drive_Controller) {
	if controller == nil {return}
	controller.pending_operations += 1
	controller.model.pending_changes = controller.pending_operations
}

hard_drive_controller_error_is_collision :: proc(err: ^fat32session.Session_Error) -> bool {
	if err == nil {return false}
	if err.code == .Name_Collision {return true}
	if err.code != .Invalid_Argument {return false}
	text := fat32session.error_text(err)
	return strings.contains(text, "collid") || strings.contains(text, "already exists")
}

hard_drive_controller_show_conflict :: proc(
	controller: ^Hard_Drive_Controller,
	source, target: string,
) {
	hard_drive_controller_clear_conflict(controller)
	controller.conflict_source = strings.clone(source)
	controller.conflict_target = strings.clone(target)
	controller.conflict_pending = true
	host.hard_drive_browser_show_conflict(
		&controller.model,
		controller.conflict_source,
		controller.conflict_target,
	)
	hard_drive_controller_clear_progress(controller)
}

hard_drive_controller_enqueue_imports :: proc(
	controller: ^Hard_Drive_Controller,
	paths: []string,
) -> bool {
	if !hard_drive_controller_ready(controller) ||
	   controller.operation != .None ||
	   len(paths) == 0 {
		return false
	}
	hard_drive_controller_clear_imports(controller)
	for path in paths {
		info, stat_error := os.stat_do_not_follow_links(path, context.temp_allocator)
		if stat_error != nil || (info.type != .Regular && info.type != .Directory) {
			if stat_error == nil {os.file_info_delete(info, context.temp_allocator)}
			hard_drive_controller_set_diagnostic(
				controller,
				"Import accepts only regular files and folders without reparse points.",
			)
			hard_drive_controller_clear_imports(controller)
			return false
		}
		directory := info.type == .Directory
		os.file_info_delete(info, context.temp_allocator)
		name := filepath.base(path)
		guest_path := hard_drive_controller_guest_join(controller.current_path, name)
		append(
			&controller.imports,
			Hard_Drive_Import_Item {
				host_path = strings.clone(path),
				guest_path = guest_path,
				directory = directory,
			},
		)
	}
	controller.operation = .Import
	controller.import_index = 0
	hard_drive_controller_set_progress(controller, "Preparing import", 0, u64(len(paths)))
	return true
}

hard_drive_controller_import_complete :: proc(controller: ^Hard_Drive_Controller) {
	controller.operation = .None
	controller.job_active = false
	hard_drive_controller_clear_imports(controller)
	hard_drive_controller_clear_progress(controller)
	_ = hard_drive_controller_refresh(controller, controller.current_path, controller.page_index)
}

hard_drive_controller_import_start_next :: proc(controller: ^Hard_Drive_Controller) {
	if controller == nil ||
	   controller.operation != .Import ||
	   controller.job_active ||
	   controller.conflict_pending {
		return
	}
	if controller.import_index >= len(controller.imports) {
		hard_drive_controller_import_complete(controller)
		return
	}
	item := &controller.imports[controller.import_index]
	info, stat_error := fat32session.edit_stat(controller.session, item.guest_path)
	if stat_error.code != .None {
		hard_drive_controller_set_diagnostic(controller, fat32session.error_text(&stat_error))
		controller.operation = .None
		hard_drive_controller_clear_imports(controller)
		hard_drive_controller_clear_progress(controller)
		return
	}
	resolution := host.Hard_Drive_Conflict_Resolution.None
	if info.exists {
		if controller.conflict_apply_to_all {
			resolution = controller.conflict_resolution
		} else {
			hard_drive_controller_show_conflict(
				controller,
				filepath.base(item.host_path),
				filepath.base(item.guest_path),
			)
			return
		}
	}
	if resolution == .Skip {
		controller.import_index += 1
		return
	}
	if resolution == .Cancel {
		controller.operation = .None
		hard_drive_controller_clear_imports(controller)
		hard_drive_controller_clear_progress(controller)
		return
	}
	replace := resolution == .Replace
	begin_error: fat32session.Session_Error
	if item.directory {
		begin_error = fat32session.edit_begin_import_tree(
			controller.session,
			item.host_path,
			item.guest_path,
			replace,
		)
	} else {
		begin_error = fat32session.edit_begin_import_file(
			controller.session,
			item.host_path,
			item.guest_path,
			replace,
		)
	}
	if begin_error.code != .None {
		if hard_drive_controller_error_is_collision(&begin_error) {
			hard_drive_controller_show_conflict(
				controller,
				filepath.base(item.host_path),
				filepath.base(item.guest_path),
			)
			return
		}
		hard_drive_controller_set_diagnostic(controller, fat32session.error_text(&begin_error))
		controller.operation = .None
		hard_drive_controller_clear_imports(controller)
		hard_drive_controller_clear_progress(controller)
		return
	}
	controller.job_active = true
	hard_drive_controller_set_progress(
		controller,
		fmt.tprintf(
			"Importing %d of %d: %s",
			controller.import_index + 1,
			len(controller.imports),
			filepath.base(item.host_path),
		),
		0,
		1,
	)
}

hard_drive_controller_begin_export :: proc(
	controller: ^Hard_Drive_Controller,
	row: ^host.Hard_Drive_Browser_Row,
	destination: string,
) -> bool {
	if !hard_drive_controller_ready(controller) ||
	   row == nil ||
	   destination == "" ||
	   controller.operation != .None {
		return false
	}
	if row.kind == .File {
		err := fat32session.edit_begin_export_file(controller.session, row.path, destination)
		if err.code != .None {
			hard_drive_controller_set_diagnostic(controller, fat32session.error_text(&err))
			return false
		}
		controller.operation = .Export_File
		controller.job_active = true
		hard_drive_controller_set_progress(
			controller,
			fmt.tprintf("Exporting %s", row.name),
			0,
			row.size,
		)
		return true
	}
	if !hard_drive_controller_guest_name_safe(row.name) {
		hard_drive_controller_set_diagnostic(
			controller,
			"The FAT folder name is unsafe to export.",
		)
		return false
	}
	root, join_error := filepath.join({destination, row.name})
	if join_error != nil {
		delete(root)
		hard_drive_controller_set_diagnostic(
			controller,
			"Export destination is invalid.",
		)
		return false
	}
	parent, parent_ok := securehost.open_directory(destination)
	if !parent_ok {
		delete(root)
		hard_drive_controller_set_diagnostic(
			controller,
			"Export destination crosses a reparse point or cannot be opened safely.",
		)
		return false
	}
	root_directory, create_ok := securehost.create_directory(&parent, row.name)
	securehost.close_directory(&parent)
	if !create_ok {
		delete(root)
		hard_drive_controller_set_diagnostic(
			controller,
			"Export destination already exists or cannot be created safely.",
		)
		return false
	}
	controller.export_root = strings.clone(root)
	controller.export_frames[0] = {
		guest_path = strings.clone(row.path),
		host_path  = root,
		directory  = root_directory,
	}
	controller.export_depth = 1
	controller.operation = .Export_Tree
	hard_drive_controller_set_progress(controller, fmt.tprintf("Exporting %s", row.name), 0, 0)
	return true
}

hard_drive_controller_export_tree_step :: proc(controller: ^Hard_Drive_Controller) {
	if controller == nil || controller.operation != .Export_Tree || controller.job_active {return}
	if controller.export_depth == 0 {
		controller.operation = .None
		hard_drive_controller_clear_export(controller)
		hard_drive_controller_clear_progress(controller)
		hard_drive_controller_set_diagnostic(controller, "")
		return
	}
	frame := &controller.export_frames[controller.export_depth - 1]
	page, list_error := fat32session.edit_list(
		controller.session,
		frame.guest_path,
		frame.cursor,
		1,
	)
	if list_error.code != .None {
		hard_drive_controller_set_diagnostic(controller, fat32session.error_text(&list_error))
		controller.operation = .None
		hard_drive_controller_clear_export(controller)
		hard_drive_controller_clear_progress(controller)
		return
	}
	defer fat32session.edit_page_destroy(&page)
	if len(page.entries) == 0 {
		hard_drive_controller_export_frame_destroy(frame)
		controller.export_depth -= 1
		return
	}
	entry := &page.entries[0]
	frame.cursor = page.next_cursor
	if !hard_drive_controller_guest_name_safe(entry.name) {
		hard_drive_controller_set_diagnostic(controller, "The FAT entry name is unsafe to export.")
		controller.operation = .None
		hard_drive_controller_clear_export(controller)
		hard_drive_controller_clear_progress(controller)
		return
	}
	guest_child := hard_drive_controller_guest_join(frame.guest_path, entry.name)
	host_child, join_error := filepath.join({frame.host_path, entry.name})
	if join_error != nil {
		delete(guest_child)
		hard_drive_controller_set_diagnostic(controller, "Cannot construct an export path.")
		controller.operation = .None
		hard_drive_controller_clear_export(controller)
		hard_drive_controller_clear_progress(controller)
		return
	}
	if entry.is_directory {
		if controller.export_depth >= HARD_DRIVE_EXPORT_MAX_DEPTH {
			delete(guest_child)
			delete(host_child)
			hard_drive_controller_set_diagnostic(
				controller,
				"Cannot create a bounded export directory.",
			)
			controller.operation = .None
			hard_drive_controller_clear_export(controller)
			hard_drive_controller_clear_progress(controller)
			return
		}
		child_directory, create_ok := securehost.create_directory(&frame.directory, entry.name)
		if !create_ok {
			delete(guest_child)
			delete(host_child)
			hard_drive_controller_set_diagnostic(
				controller,
				"Export path changed, crosses a reparse point, or already exists.",
			)
			controller.operation = .None
			hard_drive_controller_clear_export(controller)
			hard_drive_controller_clear_progress(controller)
			return
		}
		controller.export_frames[controller.export_depth] = {
			guest_path = guest_child,
			host_path  = host_child,
			directory  = child_directory,
		}
		controller.export_depth += 1
		return
	}
	begin_error := fat32session.edit_begin_export_file(controller.session, guest_child, host_child)
	delete(guest_child)
	delete(host_child)
	if begin_error.code != .None {
		hard_drive_controller_set_diagnostic(controller, fat32session.error_text(&begin_error))
		controller.operation = .None
		hard_drive_controller_clear_export(controller)
		hard_drive_controller_clear_progress(controller)
		return
	}
	controller.job_active = true
}

hard_drive_controller_step_job :: proc(controller: ^Hard_Drive_Controller) {
	progress, step_error := fat32session.edit_job_step(controller.session)
	if step_error.code != .None {
		_ = fat32session.edit_job_cancel(controller.session)
		controller.job_active = false
		if controller.operation == .Delete && progress.items_completed > 0 {
			hard_drive_controller_note_change(controller)
		}
		hard_drive_controller_set_diagnostic(controller, fat32session.error_text(&step_error))
		if controller.operation == .Export_Tree {
			hard_drive_controller_clear_export(controller)
		}
		if controller.operation == .Import {hard_drive_controller_clear_imports(controller)}
		controller.operation = .None
		hard_drive_controller_clear_progress(controller)
		return
	}
	message := controller.progress_message
	if controller.operation == .Import && controller.import_index < len(controller.imports) {
		item := &controller.imports[controller.import_index]
		message = fmt.tprintf(
			"Importing %d of %d: %s",
			controller.import_index + 1,
			len(controller.imports),
			filepath.base(item.host_path),
		)
	}
	completed := progress.completed_bytes
	total := progress.total_bytes
	if controller.operation == .Delete {
		message = "Deleting C-drive contents"
		completed = progress.items_completed
		total = 0
	}
	hard_drive_controller_set_progress(
		controller,
		message,
		completed,
		total,
	)
	if progress.state != .Complete {return}
	controller.job_active = false
	switch controller.operation {
	case .Import:
		hard_drive_controller_note_change(controller)
		controller.import_index += 1
	case .Export_File:
		controller.operation = .None
		hard_drive_controller_clear_progress(controller)
		hard_drive_controller_set_diagnostic(controller, "")
	case .Export_Tree:
		hard_drive_controller_set_progress(controller, "Exporting folder", 0, 0)
	case .Delete:
		hard_drive_controller_note_change(controller)
		controller.operation = .None
		hard_drive_controller_clear_progress(controller)
		hard_drive_controller_set_diagnostic(controller, "")
		_ = hard_drive_controller_refresh(
			controller,
			controller.current_path,
			controller.page_index,
		)
	case .None, .Apply:
	}
}

hard_drive_controller_step :: proc(controller: ^Hard_Drive_Controller) {
	if controller == nil || controller.model.machine_running {return}
	if controller.operation == .Apply {
		hard_drive_controller_step_apply(controller)
		return
	}
	if !hard_drive_controller_ready(controller) {return}
	if controller.job_active {
		hard_drive_controller_step_job(controller)
		return
	}
	switch controller.operation {
	case .Import:
		hard_drive_controller_import_start_next(controller)
	case .Export_Tree:
		hard_drive_controller_export_tree_step(controller)
	case .None, .Export_File, .Delete, .Apply:
	}
}

hard_drive_controller_cancel_operation :: proc(controller: ^Hard_Drive_Controller) {
	if controller == nil || controller.operation == .None {return}
	if controller.operation == .Apply {
		if !controller.apply_cancellable || controller.session == nil {
			hard_drive_controller_set_diagnostic(
				controller,
				"Apply is already durable and can no longer be cancelled.",
			)
			return
		}
		cancel_error := fat32session.edit_cancel_apply(controller.session)
		if cancel_error.code != .None {
			hard_drive_controller_set_diagnostic(
				controller,
				fat32session.error_text(&cancel_error),
			)
			return
		}
		controller.operation = .None
		controller.apply_step_armed = false
		controller.apply_cancellable = false
		controller.close_after_finish = false
		hard_drive_controller_clear_progress(controller)
		_ = hard_drive_controller_refresh(
			controller,
			controller.current_path,
			controller.page_index,
		)
		return
	}
	if controller.job_active && controller.session != nil {
		delete_changed := controller.operation == .Delete && controller.model.progress.completed > 0
		_ = fat32session.edit_job_cancel(controller.session)
		controller.job_active = false
		if delete_changed {hard_drive_controller_note_change(controller)}
	}
	if controller.operation == .Import {hard_drive_controller_clear_imports(controller)}
	export_cancelled := controller.operation == .Export_Tree
	if export_cancelled {hard_drive_controller_clear_export(controller)}
	controller.operation = .None
	hard_drive_controller_clear_progress(controller)
	if hard_drive_controller_ready(controller) {
		_ = hard_drive_controller_refresh(
			controller,
			controller.current_path,
			controller.page_index,
		)
	}
	if export_cancelled {
		hard_drive_controller_set_diagnostic(
			controller,
			"Recursive export cancelled. A partial destination folder may remain.",
		)
	}
}

hard_drive_controller_set_apply_progress :: proc(
	controller: ^Hard_Drive_Controller,
	progress: fat32session.Edit_Apply_Progress,
) {
	if controller == nil {return}
	message := "Applying C-drive changes"
	if progress.state == .Ready {message = "Ready to apply C-drive changes"}
	hard_drive_controller_set_progress(
		controller,
		message,
		progress.completed_units,
		progress.total_units,
		progress.cancellable,
	)
	controller.apply_cancellable = progress.cancellable
}

hard_drive_controller_begin_apply :: proc(
	controller: ^Hard_Drive_Controller,
	close_after: bool,
) -> bool {
	if !hard_drive_controller_ready(controller) ||
	   controller.operation != .None ||
	   controller.model.pending_changes <= 0 {
		return false
	}
	progress, begin_error := fat32session.edit_begin_apply(controller.session)
	if begin_error.code != .None {
		hard_drive_controller_set_diagnostic(controller, fat32session.error_text(&begin_error))
		return false
	}
	controller.operation = .Apply
	controller.close_after_finish = close_after
	controller.apply_step_armed = false
	controller.apply_failed = false
	hard_drive_controller_set_apply_progress(controller, progress)
	hard_drive_controller_set_diagnostic(controller, "")
	return true
}

hard_drive_controller_apply_failure :: proc(
	controller: ^Hard_Drive_Controller,
	err: ^fat32session.Session_Error,
) {
	if controller == nil {return}
	if err != nil && err.outcome == .Completed {
		controller.session = nil
		controller.operation = .None
		controller.apply_step_armed = false
		controller.apply_cancellable = false
		controller.apply_failed = false
		controller.pending_operations = 0
		controller.model.pending_changes = 0
		controller.model.read_only = true
		hard_drive_controller_clear_progress(controller)
		hard_drive_controller_set_diagnostic(
			controller,
			fmt.tprintf(
				"C-drive changes completed, but companion cleanup needs attention: %s",
				fat32session.error_text(err),
			),
		)
		if controller.close_after_finish {controller.model.visible = false}
		controller.close_after_finish = false
		return
	}
	diagnostic := strings.clone(
		fmt.tprintf(
			"Apply failed; recovery evidence was retained: %s",
			fat32session.error_text(err),
		),
	)
	if controller.session != nil {
		_ = fat32session.edit_close_retain(controller.session)
		controller.session = nil
	}
	controller.operation = .None
	controller.apply_step_armed = false
	controller.apply_cancellable = false
	controller.apply_failed = true
	controller.close_after_finish = false
	controller.pending_operations = 0
	controller.model.pending_changes = 0
	controller.model.read_only = true
	hard_drive_controller_clear_progress(controller)
	hard_drive_controller_set_diagnostic(controller, diagnostic)
	delete(diagnostic)
}

hard_drive_controller_apply_complete :: proc(controller: ^Hard_Drive_Controller) {
	if controller == nil || controller.session == nil {return}
	close_after := controller.close_after_finish
	path := strings.clone(controller.current_path)
	page_index := controller.page_index
	fat32session.edit_release_completed(controller.session)
	controller.session = nil
	controller.operation = .None
	controller.apply_step_armed = false
	controller.apply_cancellable = false
	controller.close_after_finish = false
	controller.pending_operations = 0
	controller.model.pending_changes = 0
	hard_drive_controller_clear_progress(controller)
	if close_after {
		controller.model.visible = false
		delete(path)
		return
	}
	if hard_drive_controller_open_session(controller) {
		_ = hard_drive_controller_refresh(controller, path, page_index)
	} else {
		controller.model.read_only = true
	}
	delete(path)
}

hard_drive_controller_step_apply :: proc(controller: ^Hard_Drive_Controller) {
	if controller == nil || controller.operation != .Apply || controller.session == nil {return}
	if !controller.apply_step_armed {
		controller.apply_step_armed = true
		return
	}
	progress, step_error := fat32session.edit_step_apply(controller.session)
	if step_error.code != .None {
		hard_drive_controller_apply_failure(controller, &step_error)
		return
	}
	hard_drive_controller_set_apply_progress(controller, progress)
	if progress.state == .Complete {hard_drive_controller_apply_complete(controller)}
}

hard_drive_controller_rebuild_tree :: proc(controller: ^Hard_Drive_Controller) -> bool {
	if !hard_drive_controller_ready(controller) || controller.operation != .None {return false}
	hard_drive_controller_clear_tree_nodes(controller)
	if !hard_drive_controller_build_tree(controller) {return false}
	controller.model.tree_nodes = controller.tree_nodes[:]
	return true
}

hard_drive_controller_toggle_tree :: proc(
	controller: ^Hard_Drive_Controller,
	path: string,
) -> bool {
	if hard_drive_controller_tree_state_index(controller, path) >= 0 {
		hard_drive_controller_tree_collapse(controller, path)
	} else {
		hard_drive_controller_tree_expand(controller, path)
	}
	return hard_drive_controller_rebuild_tree(controller)
}

hard_drive_controller_load_tree_page :: proc(
	controller: ^Hard_Drive_Controller,
	path: string,
	page_index: int,
) -> bool {
	state_index := hard_drive_controller_tree_state_index(controller, path)
	if state_index < 0 || page_index < 0 ||
	   u64(page_index) > max(u64) / u64(HARD_DRIVE_TREE_PAGE_SIZE) {
		return false
	}
	prefix := path == "" ? "" : fmt.tprintf("%s/", path)
	for index := len(controller.tree_state) - 1; index >= 0; index -= 1 {
		candidate := controller.tree_state[index].path
		if candidate == path {continue}
		if path == "" || strings.has_prefix(candidate, prefix) {
			delete(controller.tree_state[index].path)
			unordered_remove(&controller.tree_state, index)
		}
	}
	state_index = hard_drive_controller_tree_state_index(controller, path)
	controller.tree_state[state_index].page_index = page_index
	return hard_drive_controller_rebuild_tree(controller)
}

hard_drive_controller_finish :: proc(
	controller: ^Hard_Drive_Controller,
	apply_changes, close_after: bool,
) -> bool {
	if apply_changes {return hard_drive_controller_begin_apply(controller, close_after)}
	if !hard_drive_controller_ready(controller) || controller.operation != .None {return false}
	path := strings.clone(controller.image_path)
	current := strings.clone(controller.current_path)
	page_index := controller.page_index
	finish_error := fat32session.edit_finish(controller.session, apply_changes)
	if finish_error.code != .None {
		if finish_error.outcome == .Completed {
			controller.session = nil
			controller.pending_operations = 0
			controller.model.pending_changes = 0
			controller.model.read_only = true
			hard_drive_controller_set_diagnostic(
				controller,
				fmt.tprintf(
					"C-drive operation completed, but companion cleanup needs attention: %s",
					fat32session.error_text(&finish_error),
				),
			)
			if close_after {controller.model.visible = false}
			delete(path)
			delete(current)
			return true
		}
		delete(path)
		delete(current)
		hard_drive_controller_set_diagnostic(controller, fat32session.error_text(&finish_error))
		return false
	}
	controller.session = nil
	controller.pending_operations = 0
	controller.model.pending_changes = 0
	if close_after {
		controller.model.visible = false
		delete(path)
		delete(current)
		return true
	}
	if !hard_drive_controller_open_session(controller) {
		controller.model.visible = false
		delete(path)
		delete(current)
		return false
	}
	_ = hard_drive_controller_refresh(controller, current, page_index)
	delete(path)
	delete(current)
	return true
}

hard_drive_controller_close :: proc(controller: ^Hard_Drive_Controller) -> bool {
	if controller == nil {return true}
	if controller.session == nil {
		controller.model.visible = false
		return true
	}
	if controller.model.pending_changes > 0 || controller.operation != .None {return false}
	return hard_drive_controller_finish(controller, false, true)
}

hard_drive_controller_prepare_machine_start :: proc(controller: ^Hard_Drive_Controller) -> bool {
	if controller == nil {return true}
	if controller.session == nil {
		if controller.model.visible {
			hard_drive_controller_set_diagnostic(
				controller,
				"Close this C-drive window before starting the machine.",
			)
			return false
		}
		return true
	}
	if controller.operation != .None || controller.model.pending_changes > 0 {
		hard_drive_controller_set_diagnostic(
			controller,
			"Apply or discard pending C-drive changes before starting the machine.",
		)
		if controller.operation == .None &&
		   controller.model.prompt != .Close_With_Changes {
			host.hard_drive_browser_begin_prompt(&controller.model, .Close_With_Changes)
		}
		return false
	}
	return hard_drive_controller_close(controller)
}

hard_drive_controller_prepare_application_exit :: proc(
	controller: ^Hard_Drive_Controller,
) -> bool {
	if controller == nil {return true}
	if controller.session == nil {
		controller.model.visible = false
		return true
	}
	if controller.operation != .None {return false}
	return hard_drive_controller_prepare_machine_start(controller)
}

hard_drive_controller_resolve_conflict :: proc(
	controller: ^Hard_Drive_Controller,
	resolution: host.Hard_Drive_Conflict_Resolution,
	apply_to_all: bool,
) {
	if controller == nil ||
	   !controller.conflict_pending ||
	   controller.operation != .Import {return}
	hard_drive_controller_clear_conflict(controller)
	if resolution == .Cancel {
		controller.operation = .None
		hard_drive_controller_clear_imports(controller)
		hard_drive_controller_clear_progress(controller)
		return
	}
	if apply_to_all {
		controller.conflict_apply_to_all = true
		controller.conflict_resolution = resolution
	}
	if resolution == .Skip {
		controller.import_index += 1
		return
	}
	controller.conflict_resolution = .Replace
	controller.conflict_apply_to_all = apply_to_all
	item := &controller.imports[controller.import_index]
	if item.directory {
		err := fat32session.edit_begin_import_tree(
			controller.session,
			item.host_path,
			item.guest_path,
			true,
		)
		if err.code != .None {
			hard_drive_controller_set_diagnostic(controller, fat32session.error_text(&err))
			controller.operation = .None
			hard_drive_controller_clear_imports(controller)
			hard_drive_controller_clear_progress(controller)
			return
		}
	} else {
		err := fat32session.edit_begin_import_file(
			controller.session,
			item.host_path,
			item.guest_path,
			true,
		)
		if err.code != .None {
			hard_drive_controller_set_diagnostic(controller, fat32session.error_text(&err))
			controller.operation = .None
			hard_drive_controller_clear_imports(controller)
			hard_drive_controller_clear_progress(controller)
			return
		}
	}
	controller.job_active = true
}

hard_drive_controller_handle :: proc(
	controller: ^Hard_Drive_Controller,
	action: host.Hard_Drive_UI_Action,
) -> bool {
	if controller == nil || controller.model.machine_running {return false}
	switch action.kind {
	case .Navigate:
		return hard_drive_controller_refresh(controller, action.path, 0)
	case .Toggle_Tree_Node:
		return hard_drive_controller_toggle_tree(controller, action.path)
	case .Load_Tree_Page:
		return hard_drive_controller_load_tree_page(controller, action.path, action.page_index)
	case .Load_Page:
		return hard_drive_controller_refresh(
			controller,
			controller.current_path,
			action.page_index,
		)
	case .Refresh:
		return hard_drive_controller_refresh(
			controller,
			controller.current_path,
			controller.page_index,
		)
	case .Import:
		return hard_drive_controller_enqueue_imports(controller, action.paths)
	case .Export:
		row, found := hard_drive_controller_find_row(controller, action.entry_id)
		return found && hard_drive_controller_begin_export(controller, row, action.path)
	case .New_Folder:
		path := hard_drive_controller_guest_join(controller.current_path, action.name)
		defer delete(path)
		err := fat32session.edit_mkdir(controller.session, path)
		if err.code != .None {
			hard_drive_controller_set_diagnostic(controller, fat32session.error_text(&err))
			return false
		}
		hard_drive_controller_note_change(controller)
		return hard_drive_controller_refresh(
			controller,
			controller.current_path,
			controller.page_index,
		)
	case .Rename:
		row, found := hard_drive_controller_find_row(controller, action.entry_id)
		if !found {return false}
		destination := hard_drive_controller_guest_join(controller.current_path, action.name)
		defer delete(destination)
		err := fat32session.edit_rename(controller.session, row.path, destination)
		if err.code != .None {
			hard_drive_controller_set_diagnostic(controller, fat32session.error_text(&err))
			return false
		}
		hard_drive_controller_note_change(controller)
		return hard_drive_controller_refresh(
			controller,
			controller.current_path,
			controller.page_index,
		)
	case .Delete:
		row, found := hard_drive_controller_find_row(controller, action.entry_id)
		if !found || controller.operation != .None {return false}
		err := fat32session.edit_begin_remove_recursive(controller.session, row.path)
		if err.code != .None {
			hard_drive_controller_set_diagnostic(controller, fat32session.error_text(&err))
			return false
		}
		controller.operation = .Delete
		controller.job_active = true
		hard_drive_controller_set_progress(controller, "Deleting C-drive contents", 0, 0)
		return true
	case .Apply:
		return hard_drive_controller_begin_apply(controller, action.close_after)
	case .Discard:
		return hard_drive_controller_finish(controller, false, action.close_after)
	case .Cancel_Operation:
		hard_drive_controller_cancel_operation(controller)
		return true
	case .Resolve_Conflict:
		hard_drive_controller_resolve_conflict(
			controller,
			action.conflict_resolution,
			action.apply_to_all,
		)
		return true
	case .Close:
		return hard_drive_controller_close(controller)
	case .None, .Request_Native_Dialog, .Create_Image, .Select_Created_Image, .Cancel_Close:
	}
	return false
}
