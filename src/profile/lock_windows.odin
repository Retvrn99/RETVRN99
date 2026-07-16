// SPDX-License-Identifier: GPL-3.0-only
package profile

import "core:os"
import win32 "core:sys/windows"

lock_process_live :: proc(pid: u32) -> bool {
	if pid == 0 {return false}
	if pid == u32(os.get_pid()) {return true}
	handle := win32.OpenProcess(win32.PROCESS_QUERY_LIMITED_INFORMATION, false, pid)
	if handle != nil {
		exit_code: win32.DWORD
		live := bool(win32.GetExitCodeProcess(handle, &exit_code)) && exit_code == 259
		_ = win32.CloseHandle(handle)
		return live
	}
	return win32.GetLastError() == win32.ERROR_ACCESS_DENIED
}
