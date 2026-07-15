// SPDX-License-Identifier: GPL-3.0-only
package main

import "profile"
import "vmconfig"

install_runtime_cpu_mode :: proc(
	persona: vmconfig.Cpu_Mode,
	state: ^profile.Install_State,
) -> vmconfig.Cpu_Mode {
	if profile.install_state_active(state) {return .Turbo}
	return persona
}
