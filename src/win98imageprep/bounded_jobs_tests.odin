// SPDX-License-Identifier: GPL-3.0-only
package win98imageprep

import fat32session "../fat32session"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:testing"

Bounded_Progress_Capture :: struct {
	import_updates:             u64,
	remove_updates:             u64,
	apply_updates:              u64,
	last_remove_items:          u64,
	max_remove_item_delta:      u64,
	cancel_remove_after:        u64,
	cancel_apply_ready:         bool,
	cancel_apply_irreversible:  bool,
	saw_apply_cancellable:      bool,
	saw_apply_irreversible:     bool,
	saw_apply_complete:         bool,
	saw_cancelled:              bool,
}

bounded_progress_capture :: proc(
	ctx: rawptr,
	progress: Progress_Update,
) -> Progress_Action {
	capture := (^Bounded_Progress_Capture)(ctx)
	if capture == nil {return .Continue}
	if progress.state == .Cancelled {capture.saw_cancelled = true}
	switch progress.phase {
	case .Import:
		capture.import_updates += 1
	case .Remove:
		capture.remove_updates += 1
		if progress.items_completed >= capture.last_remove_items {
			delta := progress.items_completed - capture.last_remove_items
			capture.max_remove_item_delta = max(capture.max_remove_item_delta, delta)
		}
		capture.last_remove_items = progress.items_completed
		if progress.cancellable &&
		   capture.cancel_remove_after > 0 &&
		   progress.items_completed >= capture.cancel_remove_after {
			return .Cancel
		}
	case .Apply:
		capture.apply_updates += 1
		if progress.cancellable {capture.saw_apply_cancellable = true}
		if !progress.cancellable && progress.state != .Complete {
			capture.saw_apply_irreversible = true
		}
		if progress.state == .Complete {capture.saw_apply_complete = true}
		if capture.cancel_apply_ready &&
		   progress.state == .Pending &&
		   progress.cancellable {
			return .Cancel
		}
		if capture.cancel_apply_irreversible && !progress.cancellable {
			return .Cancel
		}
	}
	return .Continue
}

bounded_progress_hook :: proc(capture: ^Bounded_Progress_Capture) -> Progress_Hook {
	return {ctx = capture, update = bounded_progress_capture}
}

bounded_test_run_job :: proc(
	t: ^testing.T,
	session: ^fat32session.Edit_Session,
) -> bool {
	for {
		progress, step_error := fat32session.edit_job_step(session)
		if !testing.expect_value(t, step_error.code, fat32session.Error_Code.None) {return false}
		if progress.state == .Complete {return true}
		if !testing.expect(
			t,
			progress.state == .Pending || progress.state == .Running,
		) {return false}
	}
}

bounded_test_seed_owned_tree :: proc(
	t: ^testing.T,
	environment: ^Prep_Test_Environment,
	file_count: int,
) -> bool {
	if !prep_test_seed_dos(t, environment, len(BOOTSTRAP_SYSTEM_NAMES)) {return false}
	host_tree, path_error := filepath.join(
		{environment.root, "old-setup-tree"},
		context.temp_allocator,
	)
	if !testing.expect(t, path_error == nil) ||
	   !testing.expect_value(t, os.make_directory_all(host_tree), os.Error(nil)) {
		return false
	}
	marker_path, marker_error := filepath.join(
		{host_tree, PAYLOAD_MARKER_NAME},
		context.temp_allocator,
	)
	if !testing.expect(t, marker_error == nil) ||
	   !testing.expect_value(t, os.write_entire_file(marker_path, PAYLOAD_MARKER), os.Error(nil)) {
		return false
	}
	for index in 0 ..< file_count {
		path, file_error := filepath.join(
			{host_tree, fmt.tprintf("OLD%04d.TMP", index)},
			context.temp_allocator,
		)
		if !testing.expect(t, file_error == nil) ||
		   !testing.expect_value(t, os.write_entire_file(path, "obsolete"), os.Error(nil)) {
			return false
		}
	}
	session, open_error := fat32session.open_edit(
		environment.image_path,
		"win98-bounded-old-tree",
		0,
		.In_Process,
	)
	if !testing.expect_value(t, open_error.code, fat32session.Error_Code.None) {return false}
	defer if session != nil {_ = fat32session.edit_close_retain(session)}
	begin_error := fat32session.edit_begin_import_tree(session, host_tree, PAYLOAD_PATH)
	if !testing.expect_value(t, begin_error.code, fat32session.Error_Code.None) ||
	   !bounded_test_run_job(t, session) {
		return false
	}
	apply_error := fat32session.edit_finish(session, true)
	session = nil
	return testing.expect_value(t, apply_error.code, fat32session.Error_Code.None)
}

bounded_test_expect_path :: proc(
	t: ^testing.T,
	environment: ^Prep_Test_Environment,
	session_id, path: string,
	want: bool,
) {
	session, open_error := fat32session.open_edit(
		environment.image_path,
		session_id,
		0,
		.In_Process,
	)
	if !testing.expect_value(t, open_error.code, fat32session.Error_Code.None) {return}
	stat, stat_error := fat32session.edit_stat(session, path)
	testing.expect_value(t, stat_error.code, fat32session.Error_Code.None)
	testing.expect_value(t, stat.exists, want)
	testing.expect_value(
		t,
		fat32session.edit_finish(session, false).code,
		fat32session.Error_Code.None,
	)
}

@(test)
prepare_test_large_owned_tree_removal_is_bounded_and_reports_progress :: proc(t: ^testing.T) {
	file_count :: 256
	environment, environment_ok := prep_test_environment(
		t,
		{embedded_boot = true, setup_name = "INSTALAR"},
	)
	if !environment_ok {return}
	defer prep_test_environment_destroy(&environment)
	if !bounded_test_seed_owned_tree(t, &environment, file_count) {return}
	capture: Bounded_Progress_Capture
	request := prep_test_prepare_request(&environment)
	request.progress = bounded_progress_hook(&capture)
	result, prep_error := prepare(request, .In_Process)
	defer prepare_result_destroy(&result)
	if !testing.expect_value(t, prep_error.code, Error_Code.None) {return}
	testing.expect(t, capture.remove_updates > file_count)
	testing.expect_value(t, capture.max_remove_item_delta, u64(1))
	testing.expect(t, capture.import_updates > 0)
	testing.expect(t, capture.saw_apply_cancellable)
	testing.expect(t, capture.saw_apply_irreversible)
	testing.expect(t, capture.saw_apply_complete)
	bounded_test_expect_path(
		t,
		&environment,
		"win98-bounded-large-verify",
		PAYLOAD_PATH + "/OLD0000.TMP",
		false,
	)
}

@(test)
prepare_test_progress_cancel_during_recursive_delete_discards_every_step :: proc(
	t: ^testing.T,
) {
	environment, environment_ok := prep_test_environment(
		t,
		{embedded_boot = true, setup_name = "INSTALAR"},
	)
	if !environment_ok {return}
	defer prep_test_environment_destroy(&environment)
	if !bounded_test_seed_owned_tree(t, &environment, 32) {return}
	capture := Bounded_Progress_Capture{cancel_remove_after = 5}
	request := prep_test_prepare_request(&environment)
	request.progress = bounded_progress_hook(&capture)
	result, prep_error := prepare(request, .In_Process)
	prepare_result_destroy(&result)
	testing.expect_value(t, prep_error.code, Error_Code.Cancelled)
	testing.expect(t, capture.saw_cancelled)
	testing.expect_value(t, capture.max_remove_item_delta, u64(1))
	bounded_test_expect_path(
		t,
		&environment,
		"win98-bounded-cancel-delete-verify",
		PAYLOAD_PATH + "/OLD0000.TMP",
		true,
	)
	bounded_test_expect_path(
		t,
		&environment,
		"win98-bounded-cancel-owner-verify",
		OWNER_FILE_NAME,
		false,
	)
}

@(test)
prepare_test_progress_cancel_before_apply_intent_does_not_persist_binding :: proc(
	t: ^testing.T,
) {
	environment, environment_ok := prep_test_environment(
		t,
		{embedded_boot = true, setup_name = "INSTALAR"},
	)
	if !environment_ok {return}
	defer prep_test_environment_destroy(&environment)
	capture := Bounded_Progress_Capture{cancel_apply_ready = true}
	binding := Prep_Test_Binding_Capture{accept = true}
	request := prep_test_prepare_request(&environment)
	request.progress = bounded_progress_hook(&capture)
	request.binding_hook = {ctx = &binding, persist = prep_test_binding_persist}
	result, prep_error := prepare(request, .In_Process)
	prepare_result_destroy(&result)
	testing.expect_value(t, prep_error.code, Error_Code.Cancelled)
	testing.expect(t, capture.saw_apply_cancellable && capture.saw_cancelled)
	testing.expect(t, !binding.called)
	prep_test_expect_unprepared(t, &environment)
}

@(test)
prepare_test_progress_cancel_after_irrevocable_gate_finishes_the_apply :: proc(
	t: ^testing.T,
) {
	environment, environment_ok := prep_test_environment(
		t,
		{embedded_boot = true, setup_name = "INSTALAR"},
	)
	if !environment_ok {return}
	defer prep_test_environment_destroy(&environment)
	capture := Bounded_Progress_Capture{cancel_apply_irreversible = true}
	binding := Prep_Test_Binding_Capture{accept = true}
	request := prep_test_prepare_request(&environment)
	request.progress = bounded_progress_hook(&capture)
	request.binding_hook = {ctx = &binding, persist = prep_test_binding_persist}
	result, prep_error := prepare(request, .In_Process)
	defer prepare_result_destroy(&result)
	if !testing.expect_value(t, prep_error.code, Error_Code.None) {return}
	testing.expect(t, binding.called)
	testing.expect(t, capture.saw_apply_irreversible)
	testing.expect(t, capture.saw_apply_complete)
	testing.expect(t, !capture.saw_cancelled)
}

@(test)
abandon_test_progress_cancel_during_removal_discards_the_partial_tree :: proc(
	t: ^testing.T,
) {
	environment, environment_ok := prep_test_environment(
		t,
		{embedded_boot = true, setup_name = "INSTALAR"},
	)
	if !environment_ok {return}
	defer prep_test_environment_destroy(&environment)
	prepared, prep_error := prepare(prep_test_prepare_request(&environment), .In_Process)
	if !testing.expect_value(t, prep_error.code, Error_Code.None) {
		prepare_result_destroy(&prepared)
		return
	}
	transaction_id := prepared.edit_transaction_id
	prepare_result_destroy(&prepared)
	capture := Bounded_Progress_Capture{cancel_remove_after = 2}
	_, abandon_error := abandon(
		{
			image_path                 = environment.image_path,
			edit_session_id            = "win98-bounded-abandon-remove",
			preparation_transaction_id = transaction_id,
			progress                   = bounded_progress_hook(&capture),
		},
		.In_Process,
	)
	testing.expect_value(t, abandon_error.code, Error_Code.Cancelled)
	testing.expect(t, capture.saw_cancelled)
	bounded_test_expect_path(
		t,
		&environment,
		"win98-bounded-abandon-remove-verify",
		OWNER_FILE_NAME,
		true,
	)
}

@(test)
abandon_test_progress_cancel_before_apply_discards_all_staged_removals :: proc(
	t: ^testing.T,
) {
	environment, environment_ok := prep_test_environment(
		t,
		{embedded_boot = true, setup_name = "INSTALAR"},
	)
	if !environment_ok {return}
	defer prep_test_environment_destroy(&environment)
	prepared, prep_error := prepare(prep_test_prepare_request(&environment), .In_Process)
	if !testing.expect_value(t, prep_error.code, Error_Code.None) {
		prepare_result_destroy(&prepared)
		return
	}
	transaction_id := prepared.edit_transaction_id
	prepare_result_destroy(&prepared)
	capture := Bounded_Progress_Capture{cancel_apply_ready = true}
	_, abandon_error := abandon(
		{
			image_path                 = environment.image_path,
			edit_session_id            = "win98-bounded-abandon-apply",
			preparation_transaction_id = transaction_id,
			progress                   = bounded_progress_hook(&capture),
		},
		.In_Process,
	)
	testing.expect_value(t, abandon_error.code, Error_Code.Cancelled)
	testing.expect(t, capture.saw_apply_cancellable && capture.saw_cancelled)
	bounded_test_expect_path(
		t,
		&environment,
		"win98-bounded-abandon-apply-verify",
		OWNER_FILE_NAME,
		true,
	)
}

Bounded_Completed_Probe :: struct {
	destroy_calls: int,
}

bounded_completed_session :: proc(probe: ^Bounded_Completed_Probe) -> ^fat32session.Edit_Session {
	session := new(fat32session.Edit_Session)
	session.ctx = probe
	session.operations = fat32session.Edit_Operations {
		ready = proc(_: rawptr) -> bool {return true},
		begin_apply = proc(_: rawptr) -> (
			fat32session.Edit_Apply_Progress,
			fat32session.Session_Error,
		) {
			return {state = .Ready, total_units = 1, total_sectors = 1, cancellable = true}, {}
		},
		step_apply = proc(_: rawptr) -> (
			fat32session.Edit_Apply_Progress,
			fat32session.Session_Error,
		) {
			return {
				state = .Complete,
				completed_units = 1,
				total_units = 1,
				applied_sectors = 1,
				total_sectors = 1,
			}, fat32session.error_make(
				.Wal_IO,
				true,
				.Completed,
				0,
				0,
				"test completed cleanup warning",
			)
		},
		cancel_apply = proc(_: rawptr) -> fat32session.Session_Error {return {}},
		destroy = proc(ctx: rawptr) {
			value := (^Bounded_Completed_Probe)(ctx)
			value.destroy_calls += 1
		},
	}
	return session
}

@(test)
prepare_test_bounded_apply_consumes_completed_cleanup_warning_once :: proc(t: ^testing.T) {
	probe: Bounded_Completed_Probe
	session := bounded_completed_session(&probe)
	capture: Bounded_Progress_Capture
	apply_error := edit_apply_run(
		&session,
		{},
		bounded_progress_hook(&capture),
		.Before_Apply,
		"test Apply warning",
	)
	testing.expect_value(t, apply_error.code, Error_Code.Apply_Failed)
	testing.expect_value(
		t,
		apply_error.session_error.outcome,
		fat32session.Operation_Outcome.Completed,
	)
	testing.expect(t, session == nil)
	testing.expect_value(t, probe.destroy_calls, 1)
	testing.expect(t, capture.saw_apply_complete)
}
