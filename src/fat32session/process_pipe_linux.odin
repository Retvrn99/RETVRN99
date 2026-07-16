// SPDX-License-Identifier: GPL-3.0-only
package fat32session

import "core:os"
import "core:sys/linux"
import "core:sys/posix"

HELPER_EXECUTABLE :: "retvrn99-fat32"

process_pipe_create :: proc() -> (read, write: ^os.File, err: os.Error) {
	read, write, err = os.pipe()
	if err == nil {
		_, _ = linux.fcntl_setpipe_sz(
			linux.Fd(os.fd(read)),
			linux.F_SETPIPE_SZ,
			i32(PROTOCOL_HEADER_BYTES + PROTOCOL_MAX_PAYLOAD),
		)
	}
	return
}

process_pipe_parent_ends_secure :: proc(request, response: ^os.File) -> bool {
	if request == nil || response == nil {return false}
	request_fd := posix.FD(os.fd(request))
	response_fd := posix.FD(os.fd(response))
	request_flags := posix.fcntl(request_fd, .GETFD)
	response_flags := posix.fcntl(response_fd, .GETFD)
	if request_flags < 0 || response_flags < 0 {return false}
	return posix.fcntl(
		request_fd,
		.SETFD,
		request_flags | posix.FD_CLOEXEC,
	) >= 0 && posix.fcntl(
		response_fd,
		.SETFD,
		response_flags | posix.FD_CLOEXEC,
	) >= 0
}
