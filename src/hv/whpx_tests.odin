// SPDX-License-Identifier: GPL-3.0-only
package hv

import "core:log"
import "core:testing"
import "core:time"

@(test)
test_whpx_realmode_blob :: proc(t: ^testing.T) {
	if !available() {
		log.warn("WHPX not available")
		return
	}
	vm: Vm
	testing.expect(t, create(&vm, 64 * 1024 * 1024))
	defer destroy(&vm)
	// mov ax, 0x1234; hlt   (at 0x0000:0x7C00)
	copy(vm.ram[0x7C00:], []u8{0xB8, 0x34, 0x12, 0xF4})
	set_realmode_entry(&vm, 0, 0x7C00)
	ex := run(&vm)
	testing.expect_value(t, ex.kind, Exit_Kind.Halt)
	testing.expect_value(t, u16(reg_rax(&vm)), u16(0x1234))
}

// SDK 10.0.26100 C_ASSERT values (WinHvPlatformDefs.h)
@(test)
test_whpx_struct_sizes :: proc(t: ^testing.T) {
	testing.expect_value(t, size_of(WHV_X64_IO_PORT_ACCESS_CONTEXT), 96)
	testing.expect_value(t, size_of(WHV_MEMORY_ACCESS_CONTEXT), 40)
	testing.expect_value(t, size_of(WHV_VP_EXIT_CONTEXT), 40)
	testing.expect_value(t, size_of(WHV_RUN_VP_EXIT_CONTEXT), 224)
	testing.expect_value(t, size_of(WHV_REGISTER_VALUE), 16)
	testing.expect_value(t, size_of(WHV_X64_SEGMENT_REGISTER), 16)
}

@(test)
test_whpx_io_exit_budget :: proc(t: ^testing.T) {
	if !available() {
		log.warn("WHPX not available")
		return
	}
	testing.set_fail_timeout(t, 10 * time.Second)
	vm: Vm
	testing.expect(t, create(&vm, 64 * 1024 * 1024))
	defer destroy(&vm)
	// mov dx, 0x80; l: in al, dx; jmp l   (guest polls a port forever)
	copy(vm.ram[0x7C00:], []u8{0xBA, 0x80, 0x00, 0xEC, 0xEB, 0xFD})
	set_realmode_entry(&vm, 0, 0x7C00)
	ex := run(&vm)
	testing.expect_value(t, ex.kind, Exit_Kind.Io)
}

@(test)
test_whpx_can_inject_interrupt_shadow :: proc(t: ^testing.T) {
	if !available() {
		log.warn("WHPX not available")
		return
	}
	vm: Vm
	testing.expect(t, create(&vm, 64 * 1024 * 1024))
	defer destroy(&vm)

	// RFLAGS.IF set, nothing pending -> injectable
	name := WHV_REGISTER_NAME.Rflags
	val: WHV_REGISTER_VALUE
	val.Reg64 = 0x202
	testing.expect(t, WHvSetVirtualProcessorRegisters(vm.part, 0, &name, 1, &val) >= 0)
	testing.expect(t, can_inject(&vm))

	// interrupt shadow set -> not injectable
	name = .InterruptState
	val.Reg64 = 0x1 // InterruptShadow (bit 0)
	testing.expect(t, WHvSetVirtualProcessorRegisters(vm.part, 0, &name, 1, &val) >= 0)
	testing.expect(t, !can_inject(&vm))

}
