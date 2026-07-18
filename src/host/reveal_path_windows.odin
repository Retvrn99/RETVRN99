// SPDX-License-Identifier: GPL-3.0-only
#+build windows
package host

import "core:fmt"
import win32 "core:sys/windows"

host_reveal_path :: proc(path: string) -> bool {
	if len(path) == 0 {return false}
	executable := win32.utf8_to_utf16("explorer.exe")
	parameters := win32.utf8_to_utf16(fmt.tprintf("/select,\"%s\"", path))
	if len(executable) == 0 || len(parameters) == 0 {return false}
	result := win32.ShellExecuteW(
		nil,
		nil,
		win32.LPCWSTR(raw_data(executable)),
		win32.LPCWSTR(raw_data(parameters)),
		nil,
		win32.SW_SHOWNORMAL,
	)
	return uintptr(result) > 32
}
