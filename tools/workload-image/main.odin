// SPDX-License-Identifier: GPL-3.0-only
package main

import fat32session "../../src/fat32session"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

STAGING_DIRECTORY :: "R99STAGE"
OBSERVATION_BYTES :: 16 * 1024 * 1024

main :: proc() {
	code := workload_image_main(os.args[1:])
	if code != 0 {os.exit(code)}
}

workload_image_main :: proc(args: []string) -> int {
	if len(args) == 3 && args[0] == "create" {
		capacity_gib, parse_ok := parse_capacity_gib(args[2])
		if !parse_ok {
			fmt.eprintln("capacity must be a whole number from 1 through 127 GiB")
			return 2
		}
		return create_blank_image(args[1], capacity_gib)
	}
	if len(args) == 3 && args[0] == "stage" {
		return stage_image(args[1], args[2])
	}
	if len(args) == 2 && args[0] == "refresh-boot" {
		return refresh_boot_loader(args[1])
	}
	if len(args) == 4 && args[0] == "observe" {
		return observe_file(args[1], args[2], args[3])
	}
	fmt.eprintln("usage: retvrn99-workload-image create IMAGE CAPACITY_GIB")
	fmt.eprintln("       retvrn99-workload-image stage IMAGE HOST_TREE")
	fmt.eprintln("       retvrn99-workload-image refresh-boot IMAGE")
	fmt.eprintln("       retvrn99-workload-image observe IMAGE GUEST_PATH HOST_FILE")
	return 2
}

parse_capacity_gib :: proc(text: string) -> (u32, bool) {
	if len(text) == 0 {return 0, false}
	value: u32
	for byte in text {
		if byte < '0' || byte > '9' {return 0, false}
		digit := u32(byte - '0')
		if value > (127 - digit) / 10 {return 0, false}
		value = value * 10 + digit
	}
	return value, value >= 1 && value <= 127
}

create_blank_image :: proc(image_path: string, capacity_gib: u32) -> int {
	info, create_error := fat32session.create_image(
		fat32session.Create_Image_Request {
			path                  = image_path,
			capacity_gib          = capacity_gib,
			allow_full_allocation = false,
		},
		.Process,
	)
	if create_error.code != .None {
		return report_session_error("cannot create hard-drive image", create_error)
	}
	fat32session.image_info_destroy(&info)
	return 0
}

refresh_boot_loader :: proc(image_path: string) -> int {
	session, open_error := fat32session.open_edit(
		image_path,
		"workload-image-refresh-boot",
		0,
		.Process,
	)
	if open_error.code != .None {
		return report_session_error("cannot open hard-drive Edit session", open_error)
	}
	finished := false
	defer if !finished {_ = fat32session.edit_close_retain(session)}
	io, stat_error := fat32session.edit_stat(session, "IO.SYS")
	if stat_error.code != .None {
		return report_session_error("cannot inspect IO.SYS", stat_error)
	}
	if !io.exists || io.is_directory || io.first_cluster < 2 {
		fmt.eprintln("hard-drive image has no bootable IO.SYS")
		return 1
	}
	_, patch_error := fat32session.edit_patch_boot_loader(session, io.first_cluster)
	if patch_error.code != .None {
		return report_session_error("cannot refresh FAT32 boot loader", patch_error)
	}
	finish_error := fat32session.edit_finish(session, true)
	if finish_error.code != .None {
		return report_session_error("cannot apply FAT32 boot loader", finish_error)
	}
	finished = true
	return 0
}

report_session_error :: proc(action: string, err: fat32session.Session_Error) -> int {
	owned_error := err
	fmt.eprintfln("%s: %s", action, fat32session.error_text(&owned_error))
	return 1
}

run_edit_job :: proc(session: ^fat32session.Edit_Session) -> fat32session.Session_Error {
	for {
		progress, step_error := fat32session.edit_job_step(session)
		if step_error.code != .None {return step_error}
		switch progress.state {
		case .Complete:
			return {}
		case .Cancelled, .Failed:
			return fat32session.error_make(
				.Internal,
				false,
				.Not_Started,
				0,
				0,
				"workload image import did not complete",
			)
		case .Pending, .Running:
		}
	}
}

stage_image :: proc(image_path, host_tree: string) -> int {
	info, create_error := fat32session.create_image(
		fat32session.Create_Image_Request {
			path                  = image_path,
			capacity_gib          = 1,
			allow_full_allocation = false,
		},
		.Process,
	)
	if create_error.code != .None {return report_session_error("cannot create workload image", create_error)}
	fat32session.image_info_destroy(&info)

	session, open_error := fat32session.open_edit(
		image_path,
		"workload-gate-stage",
		0,
		.Process,
	)
	if open_error.code != .None {return report_session_error("cannot open workload image", open_error)}
	finish_attempted := false
	defer if session != nil {
		if finish_attempted {
			_ = fat32session.edit_close_retain(session)
		} else {
			_ = fat32session.edit_finish(session, false)
		}
	}

	begin_error := fat32session.edit_begin_import_tree(session, host_tree, STAGING_DIRECTORY)
	if begin_error.code != .None {return report_session_error("cannot begin workload import", begin_error)}
	if job_error := run_edit_job(session); job_error.code != .None {
		return report_session_error("cannot import workload tree", job_error)
	}

	names := make([dynamic]string, 0, 32)
	defer {
		for name in names {delete(name)}
		delete(names)
	}
	cursor: u64
	for {
		page, list_error := fat32session.edit_list(session, STAGING_DIRECTORY, cursor, 64)
		if list_error.code != .None {return report_session_error("cannot list staged workload", list_error)}
		for entry in page.entries {append(&names, strings.clone(entry.name))}
		has_more := page.has_more
		next_cursor := page.next_cursor
		fat32session.edit_page_destroy(&page)
		if !has_more {break}
		cursor = next_cursor
	}
	for name in names {
		source := strings.concatenate({STAGING_DIRECTORY, "/", name}, context.temp_allocator)
		rename_error := fat32session.edit_rename(session, source, name)
		if rename_error.code != .None {return report_session_error("cannot publish staged workload", rename_error)}
	}
	remove_error := fat32session.edit_remove_recursive(session, STAGING_DIRECTORY)
	if remove_error.code != .None {return report_session_error("cannot retire workload staging directory", remove_error)}

	io, stat_error := fat32session.edit_stat(session, "IO.SYS")
	if stat_error.code != .None {return report_session_error("cannot inspect staged IO.SYS", stat_error)}
	if !io.exists || io.is_directory || io.first_cluster < 2 {
		fmt.eprintln("staged IO.SYS is not a bootable FAT file")
		return 1
	}
	_, patch_error := fat32session.edit_patch_boot_loader(session, io.first_cluster)
	if patch_error.code != .None {return report_session_error("cannot patch workload boot loader", patch_error)}

	finish_attempted = true
	apply_error := fat32session.edit_finish(session, true)
	if apply_error.code != .None {return report_session_error("cannot apply workload image", apply_error)}
	session = nil
	return 0
}

observe_file :: proc(image_path, guest_path, host_path: string) -> int {
	session, open_error := fat32session.open_machine(
		image_path,
		"workload-gate-observe",
		.Process,
	)
	if open_error.code != .None {return report_session_error("cannot open workload image", open_error)}
	closed := false
	defer if !closed {_ = fat32session.close(session, .Retain)}

	batch, observe_error := fat32session.observe(
		session,
		[]fat32session.Probe {
			{kind = .Stat, path = guest_path},
			{kind = .Read_Tail, path = guest_path, length = OBSERVATION_BYTES},
		},
	)
	defer fat32session.observation_batch_destroy(&batch)
	if observe_error.code != .None {return report_session_error("cannot observe workload result", observe_error)}
	if batch.pending {
		fmt.eprintln("workload result observation is pending")
		return 1
	}
	if len(batch.items) != 2 || batch.items[0].type == .Missing {
		close_error := fat32session.close(session, .Commit)
		closed = close_error.code == .None
		if close_error.code != .None {return report_session_error("cannot close workload image", close_error)}
		return 3
	}
	if batch.items[0].type != .Regular || batch.items[1].type != .Regular {
		fmt.eprintln("workload result is not a regular FAT file")
		return 1
	}
	parent := filepath.dir(host_path)
	if parent != "." && os.make_directory_all(parent) != nil {
		fmt.eprintln("cannot create workload observation directory")
		return 1
	}
	if write_error := os.write_entire_file(host_path, batch.items[1].data); write_error != nil {
		fmt.eprintfln("cannot write workload observation: %v", write_error)
		return 1
	}
	close_error := fat32session.close(session, .Commit)
	closed = close_error.code == .None
	if close_error.code != .None {return report_session_error("cannot close workload image", close_error)}
	return 0
}
