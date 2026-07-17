// SPDX-License-Identifier: GPL-3.0-only
package fat32session

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:testing"

Completed_Close_Probe :: struct {
	close_calls:   int,
	destroy_calls: int,
}

Completed_Edit_Probe :: struct {
	operation_calls: int,
	destroy_calls:   int,
}

completed_close_probe_close :: proc(
	ctx: rawptr,
	_: Close_Mode,
) -> Session_Error {
	probe := (^Completed_Close_Probe)(ctx)
	probe.close_calls += 1
	return error_make(
		.Wal_IO,
		true,
		.Completed,
		7,
		7,
		"test companion cleanup warning",
	)
}

completed_close_probe_destroy :: proc(ctx: rawptr) {
	probe := (^Completed_Close_Probe)(ctx)
	probe.destroy_calls += 1
}

completed_edit_probe_error :: proc(probe: ^Completed_Edit_Probe) -> Session_Error {
	probe.operation_calls += 1
	return error_make(
		.Wal_IO,
		true,
		.Completed,
		0,
		0,
		"test Edit companion cleanup warning",
	)
}

completed_edit_probe_session :: proc(probe: ^Completed_Edit_Probe) -> ^Edit_Session {
	session := new(Edit_Session)
	session.ctx = probe
	session.operations = Edit_Operations {
		ready = proc(_: rawptr) -> bool {return true},
		step_apply = proc(ctx: rawptr) -> (Edit_Apply_Progress, Session_Error) {
			return {state = .Complete}, completed_edit_probe_error((^Completed_Edit_Probe)(ctx))
		},
		apply = proc(ctx: rawptr) -> Session_Error {
			return completed_edit_probe_error((^Completed_Edit_Probe)(ctx))
		},
		discard = proc(ctx: rawptr) -> Session_Error {
			return completed_edit_probe_error((^Completed_Edit_Probe)(ctx))
		},
		close_retain = proc(ctx: rawptr) -> Session_Error {
			return completed_edit_probe_error((^Completed_Edit_Probe)(ctx))
		},
		destroy = proc(ctx: rawptr) {
			probe := (^Completed_Edit_Probe)(ctx)
			probe.destroy_calls += 1
		},
	}
	return session
}

companion_test_add_cleanup_blocker :: proc(
	t: ^testing.T,
	image_path: string,
) -> bool {
	state_root, state_ok := companion_path(image_path, context.temp_allocator)
	if !testing.expect(t, state_ok) {return false}
	blocker, blocker_error := filepath.join(
		{state_root, "unowned-cleanup-blocker.bin"},
		context.temp_allocator,
	)
	return(
		testing.expect(t, blocker_error == nil) &&
		testing.expect_value(t, os.write_entire_file(blocker, "preserve me"), os.Error(nil)) \
	)
}

@(test)
companion_test_completed_commit_consumes_the_closed_session :: proc(t: ^testing.T) {
	probe: Completed_Close_Probe
	session := new(Machine_Session)
	session.ctx = &probe
	session.operations = Machine_Operations {
		close   = completed_close_probe_close,
		destroy = completed_close_probe_destroy,
	}
	err := close(session, .Commit)
	testing.expect_value(t, err.code, Error_Code.Wal_IO)
	testing.expect_value(t, err.outcome, Operation_Outcome.Completed)
	testing.expect_value(t, probe.close_calls, 1)
	testing.expect_value(t, probe.destroy_calls, 1)
}

@(test)
companion_test_completed_edit_operations_consume_the_closed_session :: proc(
	t: ^testing.T,
) {
	probe: Completed_Edit_Probe
	apply_error := edit_finish(completed_edit_probe_session(&probe), true)
	testing.expect_value(t, apply_error.outcome, Operation_Outcome.Completed)
	discard_error := edit_finish(completed_edit_probe_session(&probe), false)
	testing.expect_value(t, discard_error.outcome, Operation_Outcome.Completed)
	retain_error := edit_close_retain(completed_edit_probe_session(&probe))
	testing.expect_value(t, retain_error.outcome, Operation_Outcome.Completed)
	_, step_error := edit_step_apply(completed_edit_probe_session(&probe))
	testing.expect_value(t, step_error.outcome, Operation_Outcome.Completed)
	testing.expect_value(t, probe.operation_calls, 4)
	testing.expect_value(t, probe.destroy_calls, 4)
}

@(test)
companion_test_machine_and_edit_state_use_platform_concealment :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-companion-hidden-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	path, created := session_test_image(t, root, "hidden.img")
	if !created {return}

	machine, machine_error := open_in_process(path, "hidden-machine")
	if !testing.expect_value(t, machine_error.code, Error_Code.None) {return}
	state_root, state_ok := companion_path(path, context.temp_allocator)
	if !testing.expect(t, state_ok) {return}
	if !testing.expect(t, platform_companion_directory_hidden(state_root)) {return}
	if !testing.expect_value(t, close(machine, .Commit).code, Error_Code.None) {return}

	edit, edit_error := open_edit(path, "hidden-edit", 0, .In_Process)
	if !testing.expectf(
		t,
		edit_error.code == .None,
		"Edit open failed: %s",
		error_text(&edit_error),
	) {return}
	if !testing.expect(t, platform_companion_directory_hidden(state_root)) {return}
	testing.expect_value(t, edit_finish(edit, false).code, Error_Code.None)
}

@(test)
companion_test_in_process_cleanup_warning_closes_and_reopens_clean_image :: proc(
	t: ^testing.T,
) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-companion-completed-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	path, created := session_test_image(t, root, "completed.img")
	if !created {return}
	session, open_error := open_machine(path, "completed-in-process", .In_Process)
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
	if !companion_test_add_cleanup_blocker(t, path) {
		_ = close(session, .Retain)
		return
	}
	close_error := close(session, .Commit)
	testing.expect_value(t, close_error.code, Error_Code.Wal_IO)
	testing.expect_value(t, close_error.outcome, Operation_Outcome.Completed)
	validated, validation_error := validate_image(path, .In_Process)
	if !testing.expect_value(t, validation_error.code, Error_Code.None) {return}
	testing.expect(t, !validated.dirty)
	image_info_destroy(&validated)
	reopened, reopen_error := open_machine(path, "completed-in-process-reopen", .In_Process)
	if !testing.expect_value(t, reopen_error.code, Error_Code.None) {return}
	testing.expect_value(t, close(reopened, .Commit).code, Error_Code.None)
}

@(test)
companion_test_in_process_edit_cleanup_warning_consumes_apply_and_discard :: proc(
	t: ^testing.T,
) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-edit-completed-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	apply_modes := [?]bool{false, true}
	for apply_changes, index in apply_modes {
		path, created := session_test_image(t, root, apply_changes ? "apply.img" : "discard.img")
		if !created {return}
		session, open_error := open_edit(
			path,
			apply_changes ? "completed-apply" : "completed-discard",
			0,
			.In_Process,
		)
		if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
		if !testing.expect_value(t, edit_mkdir(session, "COMPLETED").code, Error_Code.None) {
			_ = edit_close_retain(session)
			return
		}
		if !companion_test_add_cleanup_blocker(t, path) {
			_ = edit_close_retain(session)
			return
		}
		finish_error := edit_finish(session, apply_changes)
		testing.expect_value(t, finish_error.code, Error_Code.Wal_IO)
		testing.expect_value(t, finish_error.outcome, Operation_Outcome.Completed)
		reopened, reopen_error := open_edit(
			path,
			fmt.tprintf("completed-verify-%d", index),
			0,
			.In_Process,
		)
		if !testing.expect_value(t, reopen_error.code, Error_Code.None) {return}
		info, stat_error := edit_stat(reopened, "COMPLETED")
		testing.expect_value(t, stat_error.code, Error_Code.None)
		testing.expect_value(t, info.exists, apply_changes)
		testing.expect_value(t, edit_finish(reopened, false).code, Error_Code.None)
	}
}
