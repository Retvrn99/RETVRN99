// SPDX-License-Identifier: GPL-3.0-only
package profile

import "core:os"
import linux "core:sys/linux"

lock_process_live :: proc(pid: u32) -> bool {
	if pid == 0 || pid > 0x7FFF_FFFF {return false}
	if pid == u32(os.get_pid()) {return true}
	return linux.kill(linux.Pid(pid), linux.Signal(0)) != .ESRCH
}
