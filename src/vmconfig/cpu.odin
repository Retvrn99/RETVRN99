// SPDX-License-Identifier: GPL-3.0-only
package vmconfig

Cpu_Mode :: enum {
	GSW_886,
	Turbo,
}

cpu_mode_name :: proc(mode: Cpu_Mode) -> string {
	switch mode {
	case .GSW_886:
		return "GSW-886"
	case .Turbo:
		return "Turbo"
	}
	return "Unknown"
}
