// SPDX-License-Identifier: GPL-3.0-only
package fat32edit

import fat32fs "../fat32fs"
import fat32image "../fat32image"
import "core:os"
import "core:path/filepath"
import "core:testing"

Apply_Test_Sink :: struct {
	image:           ^fat32image.Image,
	writes:          u64,
	maximum_bytes:   int,
	written_sectors: u64,
}

@(private = "file")
apply_test_sink_write :: proc(ctx: rawptr, lba: u64, data: []u8) -> bool {
	sink := (^Apply_Test_Sink)(ctx)
	if sink == nil || sink.image == nil {return false}
	sink.writes += 1
	sink.maximum_bytes = max(sink.maximum_bytes, len(data))
	sink.written_sectors += u64(len(data) / SECTOR_BYTES)
	return fat32image.edit_block_write(sink.image, lba, data).code == .None
}

@(private = "file")
apply_test_sink_flush :: proc(ctx: rawptr) -> bool {
	sink := (^Apply_Test_Sink)(ctx)
	return sink != nil &&
	       sink.image != nil &&
	       fat32image.sync(sink.image).code == .None
}

@(private = "file")
apply_test_open :: proc(t: ^testing.T) -> (
	directory, state: string,
	image: ^fat32image.Image,
	session: Edit_Session,
	sink: ^Apply_Test_Sink,
	ok: bool,
) {
	directory_value, directory_error := os.make_directory_temp(
		"",
		"retvrn99-fat32edit-apply-step-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, directory_error, os.Error(nil)) {return}
	directory = directory_value
	path, path_error := filepath.join({directory, "drive.img"}, context.temp_allocator)
	if !testing.expect(t, path_error == nil) {return}
	state, path_error = filepath.join(
		{directory, ".drive.img.retvrn99-fat32"},
		context.temp_allocator,
	)
	if !testing.expect(t, path_error == nil) {return}
	created, create_error := fat32image.create({path = path, capacity_gib = 1})
	if !testing.expect_value(t, create_error.code, fat32image.Error_Code.None) {return}
	fat32image.info_destroy(&created)
	image, create_error = fat32image.open(path, .Read_Write)
	if !testing.expect_value(t, create_error.code, fat32image.Error_Code.None) {return}
	sink = new(Apply_Test_Sink)
	sink.image = image
	base := fat32image.block_device(image)
	session_value, edit_error := open(
		base,
		state,
		0,
		{ctx = sink, write = apply_test_sink_write, flush = apply_test_sink_flush},
	)
	if !testing.expect_value(t, edit_error.code, Error_Code.None) {return}
	session = session_value
	ok = true
	return
}

@(test)
fat32edit_apply_step_test_is_bounded_and_cancel_is_pre_intent_only :: proc(t: ^testing.T) {
	directory, state, image, session, sink, ok := apply_test_open(t)
	if !ok {return}
	defer os.remove_all(directory)
	defer free(sink)
	defer if session.impl != nil {_ = close_retain(&session)}
	defer if image != nil {_ = fat32image.close(image, .Retain)}
	if !testing.expect_value(t, mkdir(&session, "STEPPED").code, Error_Code.None) {return}
	dirty := changed_sector_count(&session)
	if !testing.expect(t, dirty > 0) {return}
	transaction := transaction_id(&session)
	job, begin_error := begin_apply(&session)
	if !testing.expect_value(t, begin_error.code, Error_Code.None) {return}
	progress := apply_progress(&job)
	testing.expect_value(t, progress.state, Apply_Job_State.Ready)
	testing.expect(t, progress.cancellable)
	testing.expect_value(t, progress.total_sectors, dirty)
	testing.expect_value(t, apply_cancel(&job).code, Error_Code.Cancelled)
	apply_job_destroy(&job)
	testing.expect(t, has_changes(&session))
	job, begin_error = begin_apply(&session)
	if !testing.expect_value(t, begin_error.code, Error_Code.None) {return}
	defer apply_job_destroy(&job)
	step_error: Edit_Error
	progress, step_error = apply_step(&job)
	if !testing.expect_value(t, step_error.code, Error_Code.None) {return}
	testing.expect_value(t, progress.state, Apply_Job_State.Applying)
	testing.expect(t, !progress.cancellable)
	testing.expect_value(t, apply_cancel(&job).code, Error_Code.Invalid_State)
	previous_units := progress.completed_units
	steps := 1
	for progress.state != .Complete {
		progress, step_error = apply_step(&job)
		if !testing.expect_value(t, step_error.code, Error_Code.None) {return}
		testing.expect(
			t,
			progress.completed_units - previous_units <= u64(MAX_TRANSFER_BYTES * 8),
		)
		previous_units = progress.completed_units
		steps += 1
	}
	testing.expect(t, steps > 2)
	testing.expect_value(t, progress.applied_sectors, dirty)
	testing.expect_value(t, sink.written_sectors, dirty)
	testing.expect(t, sink.writes > 0)
	testing.expect(t, sink.maximum_bytes <= MAX_TRANSFER_BYTES)
	testing.expect_value(t, retire_applied(state, transaction).code, Error_Code.None)
	volume, volume_error := fat32fs.open(fat32image.block_device(image))
	if !testing.expect_value(t, volume_error.code, fat32fs.Error_Code.None) {return}
	info, stat_error := fat32fs.stat(&volume, "STEPPED")
	testing.expect_value(t, stat_error.code, fat32fs.Error_Code.None)
	testing.expect(t, info.exists && info.is_directory)
	testing.expect_value(t, fat32image.close(image, .Clean).code, fat32image.Error_Code.None)
	image = nil
}

@(test)
fat32edit_apply_step_test_interruption_replays_complete_intent :: proc(t: ^testing.T) {
	directory, state, image, session, sink, ok := apply_test_open(t)
	if !ok {return}
	defer os.remove_all(directory)
	defer free(sink)
	defer if session.impl != nil {_ = close_retain(&session)}
	defer if image != nil {_ = fat32image.close(image, .Retain)}
	if !testing.expect_value(t, mkdir(&session, "RECOVERED").code, Error_Code.None) {return}
	job, begin_error := begin_apply(&session)
	if !testing.expect_value(t, begin_error.code, Error_Code.None) {return}
	progress, step_error := apply_step(&job)
	if !testing.expect_value(t, step_error.code, Error_Code.None) {return}
	testing.expect_value(t, progress.state, Apply_Job_State.Applying)
	progress, step_error = apply_step(&job)
	if !testing.expect_value(t, step_error.code, Error_Code.None) {return}
	testing.expect(t, progress.applied_sectors > 0)
	apply_job_destroy(&job)
	testing.expect_value(t, close_retain(&session).code, Error_Code.None)
	base := fat32image.block_device(image)
	owner := fat32image.edit_block_device(image)
	recovered, recover_error := open(
		base,
		state,
		0,
		{ctx = owner.ctx, write = owner.write, flush = owner.flush},
	)
	if !testing.expect_value(t, recover_error.code, Error_Code.None) {return}
	info, stat_error := stat(&recovered, "RECOVERED")
	testing.expect_value(t, stat_error.code, Error_Code.None)
	testing.expect(t, info.exists && info.is_directory)
	testing.expect_value(t, discard(&recovered).code, Error_Code.None)
	testing.expect_value(t, fat32image.close(image, .Clean).code, fat32image.Error_Code.None)
	image = nil
}
