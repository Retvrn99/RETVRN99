// SPDX-License-Identifier: GPL-3.0-only
package hv

import "core:log"
import "core:testing"

@(test)
test_whpx_realmode_blob :: proc(t: ^testing.T) {
	if !available() {
		log.warn("WHPX no disponible")
		return
	}
	vm: Vm
	testing.expect(t, create(&vm, 64 * 1024 * 1024))
	defer destroy(&vm)
	// mov ax, 0x1234; hlt   (en 0x0000:0x7C00)
	copy(vm.ram[0x7C00:], []u8{0xB8, 0x34, 0x12, 0xF4})
	set_realmode_entry(&vm, 0, 0x7C00)
	ex := run(&vm)
	testing.expect_value(t, ex.kind, Exit_Kind.Halt)
	testing.expect_value(t, u16(reg_rax(&vm)), u16(0x1234))
}
