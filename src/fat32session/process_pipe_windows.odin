// SPDX-License-Identifier: GPL-3.0-only
package fat32session

import "core:os"
import win32 "core:sys/windows"

HELPER_EXECUTABLE :: "retvrn99-fat32.exe"

process_pipe_create :: proc() -> (read, write: ^os.File, err: os.Error) {
	handles: [2]win32.HANDLE
	security := win32.SECURITY_ATTRIBUTES {
		nLength = size_of(win32.SECURITY_ATTRIBUTES),
		bInheritHandle = true,
	}
	buffer_bytes := u32(PROTOCOL_HEADER_BYTES + PROTOCOL_MAX_PAYLOAD)
	if !bool(win32.CreatePipe(&handles[0], &handles[1], &security, buffer_bytes)) {
		return os.pipe()
	}
	return os.new_file(uintptr(handles[0]), ""), os.new_file(uintptr(handles[1]), ""), nil
}

process_pipe_parent_ends_secure :: proc(request, response: ^os.File) -> bool {
	if request == nil || response == nil {return false}
	return bool(win32.SetHandleInformation(
		win32.HANDLE(os.fd(request)),
		win32.HANDLE_FLAG_INHERIT,
		0,
	)) && bool(win32.SetHandleInformation(
		win32.HANDLE(os.fd(response)),
		win32.HANDLE_FLAG_INHERIT,
		0,
	))
}
