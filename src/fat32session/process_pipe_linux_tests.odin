#+build linux

// SPDX-License-Identifier: GPL-3.0-only
package fat32session

import "core:os"
import "core:sys/posix"
import "core:testing"

@(test)
process_pipe_linux_test_parent_ends_are_close_on_exec :: proc(t: ^testing.T) {
	child_input, parent_request, input_error := os.pipe()
	if !testing.expect_value(t, input_error, os.Error(nil)) {return}
	defer os.close(child_input)
	defer os.close(parent_request)
	parent_response, child_output, output_error := os.pipe()
	if !testing.expect_value(t, output_error, os.Error(nil)) {return}
	defer os.close(parent_response)
	defer os.close(child_output)
	if !testing.expect(t, process_pipe_parent_ends_secure(parent_request, parent_response)) {
		return
	}
	parent_ends := [?]^os.File{parent_request, parent_response}
	for file in parent_ends {
		flags := posix.fcntl(posix.FD(os.fd(file)), .GETFD)
		testing.expect(t, flags >= 0)
		testing.expect(t, flags & posix.FD_CLOEXEC != 0)
	}
}
