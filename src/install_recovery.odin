// SPDX-License-Identifier: GPL-3.0-only
package main

import "profile"
import "win98prep"

install_state_boot_allowed :: proc(state: ^profile.Install_State) -> bool {
	return state != nil && state.phase != .Preparing
}

install_interrupted_preparation_recover :: proc(
	paths: ^profile.Paths,
	state: ^profile.Install_State,
) -> (
	interrupted, recovered: bool,
) {
	if state == nil || state.phase != .Preparing {return false, true}
	if paths == nil {return true, false}
	return true, win98prep.prepare_recover_interrupted(paths.install, paths.c_drive)
}
