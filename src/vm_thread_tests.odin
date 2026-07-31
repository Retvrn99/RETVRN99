// SPDX-License-Identifier: GPL-3.0-only
package main

import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"
import "fat32session"
import "profile"

@(test)
gui_vm_thread_test_guest_power_off_stops_machine_without_closing_gui :: proc(t: ^testing.T) {
	shared := Shared {
		running         = true,
		machine_running = true,
		frozen_msg      = "old freeze",
	}
	defer vm_log_destroy(&shared)

	gui_guest_power_off_complete(&shared, "guest requested APM power off")

	testing.expect(t, shared.running)
	testing.expect(t, !shared.machine_running)
	testing.expect_value(t, shared.frozen_msg, "")
	if !testing.expect_value(t, len(shared.log_lines), 1) {return}
	testing.expect_value(
		t,
		shared.log_lines[0],
		"machine: stopped (guest requested APM power off)",
	)
}

@(test)
gui_vm_thread_test_freeze_diagnostic_survives_publisher_temp_allocator_reset :: proc(
	t: ^testing.T,
) {
	shared: Shared
	defer vm_log_destroy(&shared)
	message := fmt.tprintf("disk recovery failed at checkpoint %d", 414)
	publish_freeze(&shared, message, "EIP=12345678")
	free_all(context.temp_allocator)
	testing.expect_value(t, shared.frozen_msg, "disk recovery failed at checkpoint 414")
	testing.expect_value(t, shared.regs_text, "EIP=12345678")
}

@(test)
gui_vm_thread_test_guided_install_uses_automatic_desktop_probe :: proc(t: ^testing.T) {
	options := guided_install_prepare_options({language = "es", country = "ES"})
	testing.expect(t, options.desktop_probe)
	testing.expect(t, !options.hardware_diagnostics)
	testing.expect_value(t, options.host_locale.language, "es")
	testing.expect_value(t, options.host_locale.country, "ES")
}

@(test)
gui_vm_thread_test_install_completion_poll_requires_running_post_reset_setup :: proc(
	t: ^testing.T,
) {
	start := time.tick_now()
	due := time.tick_add(start, GUI_INSTALL_COMPLETION_POLL_INTERVAL)
	state := profile.Install_State {
		phase       = .Setup_Running,
		reset_count = 1,
	}
	testing.expect(t, gui_install_completion_poll_due(&state, true, false, true, start, due))
	testing.expect(t, !gui_install_completion_poll_due(&state, false, false, true, start, due))
	testing.expect(t, !gui_install_completion_poll_due(&state, true, true, true, start, due))
	testing.expect(t, !gui_install_completion_poll_due(&state, true, false, false, start, due))
	testing.expect(
		t,
		!gui_install_completion_poll_due(
			&state,
			true,
			false,
			true,
			start,
			time.tick_add(start, GUI_INSTALL_COMPLETION_POLL_INTERVAL - time.Nanosecond),
		),
	)
	state.reset_count = 0
	testing.expect(t, !gui_install_completion_poll_due(&state, true, false, true, start, due))
	state.phase = .Launch_Pending
	state.reset_count = 1
	testing.expect(t, !gui_install_completion_poll_due(&state, true, false, true, start, due))
}

@(test)
gui_vm_thread_test_completion_marker_is_observed_without_acceptance_enumeration :: proc(
	t: ^testing.T,
) {
	root := install_test_directory(t)
	defer delete(root)
	defer os.remove_all(root)
	image_path := test_image_create(t, root, "gui-completion.img")
	if image_path == "" {return}
	if !test_image_write_files(
		t,
		image_path,
		[]string{"GSWSETUP"},
		[]Test_Image_File{{path = "GSWSETUP/DESKTOP.OK", data = "READY\r\n"}},
	) {
		return
	}
	session, open_error := fat32session.open_machine(
		image_path,
		"gui-completion-marker",
		.In_Process,
	)
	if !testing.expect_value(t, open_error.code, fat32session.Error_Code.None) {return}
	defer fat32session.close(session, .Retain)
	testing.expect(t, gui_install_completion_marker_exists_session(session))
	testing.expect_value(
		t,
		fat32session.close(session, .Commit).code,
		fat32session.Error_Code.None,
	)
	session = nil
}
