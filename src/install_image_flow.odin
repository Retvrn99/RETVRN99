// SPDX-License-Identifier: GPL-3.0-only
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"
import "fat32session"
import "profile"
import "win98imageprep"

Install_Image_Flow_Result :: struct {
	preparation:   win98imageprep.Prepare_Result,
	error:         win98imageprep.Error,
	state_retained: bool,
}

Install_Prepare_Status :: struct {
	running:    bool,
	generation: u64,
	succeeded:  bool,
	message:    string,
}

install_prepare_status_queue :: proc(shared: ^Shared) {
	if shared == nil {return}
	sync.lock(&shared.mu)
	defer sync.unlock(&shared.mu)
	shared.install_prepare_running = false
	shared.install_prepare_cancel_requested = false
	shared.install_prepare_succeeded = false
	delete(shared.install_prepare_message)
	shared.install_prepare_message = strings.clone("Waiting to prepare the hard drive")
}

install_prepare_status_begin :: proc(shared: ^Shared) -> u64 {
	if shared == nil {return 0}
	sync.lock(&shared.mu)
	defer sync.unlock(&shared.mu)
	shared.install_prepare_running = true
	shared.install_prepare_succeeded = false
	delete(shared.install_prepare_message)
	shared.install_prepare_message = strings.clone("Validating installation media and hard drive")
	return shared.install_prepare_generation
}

install_prepare_status_finish :: proc(shared: ^Shared, succeeded: bool, message: string) {
	if shared == nil {return}
	sync.lock(&shared.mu)
	defer sync.unlock(&shared.mu)
	shared.install_prepare_running = false
	shared.install_prepare_succeeded = succeeded
	shared.install_prepare_generation += 1
	delete(shared.install_prepare_message)
	shared.install_prepare_message = strings.clone(message)
}

install_prepare_status_snapshot :: proc(shared: ^Shared) -> Install_Prepare_Status {
	if shared == nil {return {}}
	sync.lock(&shared.mu)
	defer sync.unlock(&shared.mu)
	return {
		running    = shared.install_prepare_running,
		generation = shared.install_prepare_generation,
		succeeded  = shared.install_prepare_succeeded,
		message    = strings.clone(shared.install_prepare_message, context.temp_allocator),
	}
}

install_prepare_cancel_request :: proc(shared: ^Shared) {
	if shared == nil {return}
	sync.lock(&shared.mu)
	shared.install_prepare_cancel_requested = true
	sync.unlock(&shared.mu)
}

install_prepare_cancel_check :: proc(ctx: rawptr, point: win98imageprep.Cancel_Point) -> bool {
	shared := (^Shared)(ctx)
	if shared == nil {return false}
	message := "Preparing Windows 98 files"
	switch point {
	case .Media_Inspected:
		message = "Installation media validated"
	case .Edit_Opened:
		message = "Hard-drive edit transaction opened"
	case .Boot_Seed_Staged:
		message = "DOS boot files staged"
	case .Setup_Extracted:
		message = "Windows 98 Setup extracted"
	case .DOS_Imported:
		message = "DOS boot files imported"
	case .Payload_Imported:
		message = "Windows 98 Setup imported"
	case .Launcher_Imported:
		message = "Setup launcher imported"
	case .Boot_Loader_Staged:
		message = "Boot loader prepared"
	case .Before_Apply:
		message = "Applying the image transaction"
	case .Abandon_Removing:
		message = "Removing RETVRN99-owned installation files"
	case .Abandon_Before_Apply:
		message = "Applying Windows 98 installation abandonment"
	}
	sync.lock(&shared.mu)
	delete(shared.install_prepare_message)
	shared.install_prepare_message = strings.clone(message)
	cancelled := shared.install_prepare_cancel_requested
	sync.unlock(&shared.mu)
	return cancelled
}

install_image_flow_result_destroy :: proc(result: ^Install_Image_Flow_Result) {
	if result == nil {return}
	win98imageprep.prepare_result_destroy(&result.preparation)
	result^ = {}
}

Install_Image_Binding_Context :: struct {
	paths:            ^profile.Paths,
	state:            ^profile.Install_State,
	candidate:        ^profile.Install_State,
	image_path:       string,
	deferred_binding: bool,
	persisted:        bool,
}

install_image_binding_persist :: proc(
	ctx: rawptr,
	binding: win98imageprep.Preparation_Binding,
) -> bool {
	value := (^Install_Image_Binding_Context)(ctx)
	if value == nil || value.paths == nil || value.state == nil {return false}
	if value.deferred_binding {
		if value.candidate == nil || binding.edit_transaction_id == 0 {return false}
		value.candidate.image_identity = profile.Install_Image_Identity(binding.image_identity)
		if profile.install_state_verify_binding(
			value.candidate,
			value.image_path,
			profile.Install_Image_Identity(binding.image_identity),
			binding.edit_transaction_id,
		) != .None {
			return false
		}
		if profile.install_state_save(value.paths.install_state, value.candidate) != .None {
			return false
		}
		install_image_state_move(value.state, value.candidate)
		value.persisted = true
		return true
	}
	if profile.install_state_verify_binding(
		value.state,
		value.image_path,
		profile.Install_Image_Identity(binding.image_identity),
		binding.edit_transaction_id,
	) != .None {
		return false
	}
	if profile.install_state_save(value.paths.install_state, value.state) != .None {
		return false
	}
	value.persisted = true
	return true
}

install_image_transaction_id :: proc() -> u64 {
	result := u64(time.now()._nsec) ~ u64(os.get_pid()) << 32
	return result != 0 ? result : 1
}

install_image_state_move :: proc(
	destination, source: ^profile.Install_State,
) {
	if destination == nil || source == nil || destination == source {return}
	profile.install_state_destroy(destination)
	destination^ = source^
	source^ = {}
}

install_image_state_paths_equal :: proc(left, right: string) -> bool {
	when ODIN_OS == .Windows {
		return strings.equal_fold(left, right)
	} else {
		return left == right
	}
}

install_image_candidate :: proc(
	media_path, image_path: string,
	image_identity: profile.Install_Image_Identity,
	transaction_id: u64,
	cmos: []u8,
	has_cmos: bool,
	previous: ^profile.Install_State,
) -> profile.Install_State {
	candidate := install_state_candidate(media_path, cmos, has_cmos, previous)
	delete(candidate.image_path)
	candidate.image_path = strings.clone(image_path)
	candidate.image_identity = image_identity
	candidate.edit_transaction_id = transaction_id
	return candidate
}

install_image_prepare :: proc(
	paths: ^profile.Paths,
	state: ^profile.Install_State,
	image_path, media_path, boot_image_path: string,
	cmos: []u8,
	has_cmos: bool,
	options: win98imageprep.Prepare_Options,
	cancellation: win98imageprep.Cancellation = {},
	adapter := fat32session.DEFAULT_ADAPTER,
) -> Install_Image_Flow_Result {
	flow: Install_Image_Flow_Result
	if paths == nil || state == nil || image_path == "" || media_path == "" {
		flow.error = win98imageprep.error_make(
			.Invalid_Argument,
			"image-backed Windows 98 preparation requires Profile, image, and media",
		)
		return flow
	}
	previous := install_state_clone(state)
	defer profile.install_state_destroy(&previous)
	image, image_error := fat32session.validate_image(image_path, adapter)
	if image_error.code != .None {
		flow.error = win98imageprep.error_make(.Image_Rejected, "hard-drive image validation failed")
		flow.error.session_error = image_error
		return flow
	}
	defer fat32session.image_info_destroy(&image)
	if image.dirty && !profile.install_state_active(state) {
		flow.error = win98imageprep.error_make(
			.Recovery_Failed,
			"a dirty hard-drive image requires its existing bound installation state",
		)
		flow.state_retained = true
		return flow
	}
	deferred_binding := !image.enrolled
	transaction_id := install_image_transaction_id()
	if profile.install_state_active(state) {
		if state.phase != .Preparing || !profile.install_state_bound(state) ||
		   !install_image_state_paths_equal(state.image_path, image_path) ||
		   state.image_identity != profile.Install_Image_Identity(image.image_id) ||
		   state.source_path != media_path {
			flow.error = win98imageprep.error_make(
				.Binding_Failed,
				"an active Windows 98 installation is bound to different media or storage",
			)
			flow.state_retained = true
			return flow
		}
		transaction_id = state.edit_transaction_id
	}
	candidate := install_image_candidate(
		media_path,
		image_path,
		profile.Install_Image_Identity(image.image_id),
		transaction_id,
		cmos,
		has_cmos,
		state,
	)
	defer profile.install_state_destroy(&candidate)
	if !deferred_binding {
		if profile.install_state_save(paths.install_state, &candidate) != .None {
			flow.error = win98imageprep.error_make(
				.Binding_Failed,
				"cannot persist image-bound Windows 98 preparation state",
			)
			return flow
		}
		install_image_state_move(state, &candidate)
	}
	binding_context := Install_Image_Binding_Context {
		paths            = paths,
		state            = state,
		candidate        = &candidate,
		image_path       = image_path,
		deferred_binding = deferred_binding,
	}
	session_id := fmt.tprintf("install-%d-%d", os.get_pid(), transaction_id)
	flow.preparation, flow.error = win98imageprep.prepare(
		win98imageprep.Prepare_Request {
			image_path               = image_path,
			iso_path                 = media_path,
			boot_floppy_path         = boot_image_path,
			scratch_parent           = paths.install,
			edit_session_id          = session_id,
			requested_transaction_id = transaction_id,
			options                  = options,
			cancellation             = cancellation,
			binding_hook = {
				ctx     = &binding_context,
				persist = install_image_binding_persist,
			},
		},
		adapter,
	)
	if flow.error.code == .None {
		if !profile.install_state_bound(state) {
			flow.error = win98imageprep.error_make(
				.Binding_Failed,
				"the prepared image did not establish its durable installation binding",
			)
			flow.state_retained = true
			return flow
		}
		state.phase = .Launch_Pending
		if profile.install_state_save(paths.install_state, state) == .None {return flow}
		state.phase = .Preparing
		flow.error = win98imageprep.error_make(
			.Binding_Failed,
			"the prepared image is durable, but its launch state could not be persisted",
		)
		flow.state_retained = true
		return flow
	}
	if binding_context.persisted {
		flow.state_retained = true
		return flow
	}

	checked, checked_error := fat32session.validate_image(image_path, adapter)
	clean := checked_error.code == .None && !checked.dirty
	if deferred_binding && checked_error.code == .None && checked.dirty && checked.enrolled {
		candidate.image_identity = profile.Install_Image_Identity(checked.image_id)
		if profile.install_state_verify_binding(
			&candidate,
			image_path,
			candidate.image_identity,
			transaction_id,
		) == .None && profile.install_state_save(paths.install_state, &candidate) == .None {
			install_image_state_move(state, &candidate)
		}
	}
	fat32session.image_info_destroy(&checked)
	if clean && profile.install_state_save(paths.install_state, &previous) == .None {
		install_image_state_move(state, &previous)
		return flow
	}
	flow.state_retained = true
	return flow
}

install_image_abandon :: proc(
	paths: ^profile.Paths,
	state: ^profile.Install_State,
	adapter := fat32session.DEFAULT_ADAPTER,
) -> win98imageprep.Error {
	if paths == nil || state == nil || !profile.install_state_active(state) ||
	   !profile.install_state_bound(state) {
		return win98imageprep.error_make(
			.Invalid_Argument,
			"there is no image-bound Windows 98 installation to abandon",
		)
	}
	session_id := fmt.tprintf("abandon-%d-%d", os.get_pid(), state.edit_transaction_id)
	_, abandon_error := win98imageprep.abandon(
		win98imageprep.Abandon_Request {
			image_path                 = state.image_path,
			edit_session_id            = session_id,
			preparation_transaction_id = state.edit_transaction_id,
			allow_consumed_content     = state.phase == .Setup_Running,
		},
		adapter,
	)
	return abandon_error
}
