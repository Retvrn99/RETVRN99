// SPDX-License-Identifier: GPL-3.0-only
package machine

import disk "../disk"
import "core:testing"

@(private = "file")
machine_ide_decode_test_init :: proc(m: ^Machine, backing: ^[]u8) {
	bus_init(&m.platform.bus)
	pci_init(&m.pci)
	disk.bmide_init(&m.bmide)
	machine_init_atapi(m)
	machine_attach_disk(m, machine_test_bd(backing))
	pci_handler := Io_Handler {
		ctx   = m,
		write = machine_pci_write,
	}
	bus_register(&m.platform.bus, 0xCF8, 0xCFF, pci_handler)
}

@(private = "file")
machine_ide_decode_test_write_config :: proc(m: ^Machine, reg: u8, size: u8, value: u32) -> bool {
	pci_out(&m.pci, 0xCF8, 4, 0x8000_3900 | u32(reg & 0xFC))
	pci_out(&m.pci, 0xCFC + u16(reg & 3), size, value)
	return machine_sync_pci_devices(m)
}

@(private = "file")
machine_ide_decode_test_configure_primary_native :: proc(
	m: ^Machine,
	command_bar, control_bar: u32,
	channels: u8 = AMD756_IDE_PRIMARY_CHANNEL_ENABLE,
	command: u16 = 0x0001,
) -> bool {
	return(
		machine_ide_decode_test_write_config(m, 0x09, 1, u32(AMD756_IDE_PRIMARY_NATIVE_MODE)) &&
		machine_ide_decode_test_write_config(m, 0x10, 4, command_bar) &&
		machine_ide_decode_test_write_config(m, 0x14, 4, control_bar) &&
		machine_ide_decode_test_write_config(m, 0x40, 1, u32(channels)) &&
		machine_ide_decode_test_write_config(m, 0x04, 2, u32(command)) \
	)
}

@(test)
machine_ide_decode_test_mixed_native_and_compatibility_channels :: proc(t: ^testing.T) {
	backing := make([]u8, 1024 * 1024)
	defer delete(backing)
	m := new(Machine)
	defer free(m)
	machine_ide_decode_test_init(m, &backing)
	defer bus_destroy(&m.platform.bus)
	if !testing.expect(
		t,
		machine_ide_decode_test_configure_primary_native(m, 0x0000_01E1, 0x0000_03E5, 0x03),
	) {
		return
	}

	testing.expect(t, machine_io_write(m, 0x1E2, 1, 0x34))
	testing.expect_value(t, m.ide.reg_seccount, u8(0x34))
	testing.expect(t, machine_io_write(m, 0x172, 1, 0x56))
	testing.expect_value(t, m.atapi.reg_seccount, u8(0x56))

	testing.expect(t, machine_io_write(m, 0x1F2, 1, 0x78))
	testing.expect_value(t, m.ide.reg_seccount, u8(0x34))
	value, ok := machine_io_read(m, 0x1F2, 1)
	testing.expect(t, ok)
	testing.expect_value(t, value, u32(0xFF))
}

@(test)
machine_ide_decode_test_native_control_uses_only_bar_base_plus_two :: proc(t: ^testing.T) {
	backing := make([]u8, 1024 * 1024)
	defer delete(backing)
	m := new(Machine)
	defer free(m)
	machine_ide_decode_test_init(m, &backing)
	defer bus_destroy(&m.platform.bus)
	if !testing.expect(
		t,
		machine_ide_decode_test_configure_primary_native(m, 0x0000_01E1, 0x0000_03E5),
	) {
		return
	}

	m.ide.reg_ctrl = 0
	ports := [?]u16{0x3E4, 0x3E5, 0x3E7, 0x3F6}
	for port in ports {
		testing.expect(t, machine_io_write(m, port, 1, 0x02))
		testing.expect_value(t, m.ide.reg_ctrl, u8(0))
	}
	testing.expect(t, machine_io_write(m, 0x3E6, 1, 0x02))
	testing.expect_value(t, m.ide.reg_ctrl, u8(0x02))
}

@(test)
machine_ide_decode_test_iose_and_channel_enable_gate_native_ports :: proc(t: ^testing.T) {
	backing := make([]u8, 1024 * 1024)
	defer delete(backing)
	m := new(Machine)
	defer free(m)
	machine_ide_decode_test_init(m, &backing)
	defer bus_destroy(&m.platform.bus)
	if !testing.expect(
		t,
		machine_ide_decode_test_configure_primary_native(m, 0x0000_01E1, 0x0000_03E5),
	) {
		return
	}

	m.ide.reg_seccount = 0x11
	testing.expect(t, machine_ide_decode_test_write_config(m, 0x04, 2, 0))
	testing.expect(t, machine_io_write(m, 0x1E2, 1, 0x22))
	testing.expect_value(t, m.ide.reg_seccount, u8(0x11))
	value, ok := machine_io_read(m, 0x1E2, 1)
	testing.expect(t, ok)
	testing.expect_value(t, value, u32(0xFF))

	testing.expect(t, machine_ide_decode_test_write_config(m, 0x04, 2, 1))
	testing.expect(t, machine_ide_decode_test_write_config(m, 0x40, 1, 0))
	testing.expect(t, machine_io_write(m, 0x1E2, 1, 0x33))
	testing.expect_value(t, m.ide.reg_seccount, u8(0x11))

	testing.expect(
		t,
		machine_ide_decode_test_write_config(m, 0x40, 1, u32(AMD756_IDE_PRIMARY_CHANNEL_ENABLE)),
	)
	testing.expect(t, machine_io_write(m, 0x1E2, 1, 0x44))
	testing.expect_value(t, m.ide.reg_seccount, u8(0x44))
}

@(test)
machine_ide_decode_test_rep_io_and_bus_trace_follow_native_bar :: proc(t: ^testing.T) {
	backing := make([]u8, 1024 * 1024)
	defer delete(backing)
	m := new(Machine)
	defer free(m)
	machine_ide_decode_test_init(m, &backing)
	defer bus_destroy(&m.platform.bus)
	if !testing.expect(
		t,
		machine_ide_decode_test_configure_primary_native(m, 0x0000_01E1, 0x0000_03E5),
	) {
		return
	}
	m.platform.bus.diagnostic_tracing = true

	data := [?]u8{0x11, 0x22, 0x33, 0x44}
	completed, handled, ok := machine_io_stream_write(m, 0x1E0, 2, data[:])
	testing.expect_value(t, completed, 2)
	testing.expect(t, handled)
	testing.expect(t, ok)

	read_data: [4]u8
	completed, handled, ok = machine_io_stream_read(m, 0x1E0, 2, read_data[:])
	testing.expect_value(t, completed, 2)
	testing.expect(t, handled)
	testing.expect(t, ok)

	completed, handled, ok = machine_io_stream_write(m, 0x1F0, 2, data[:])
	testing.expect_value(t, completed, 0)
	testing.expect(t, !handled)
	testing.expect(t, ok)

	testing.expect(t, machine_io_write(m, 0x1E2, 1, 0x5A))
	testing.expect_value(t, m.ide_count, u64(1))
	testing.expect_value(t, m.ide_hist[0].port, u16(0x1E2))
	testing.expect_value(t, m.ide_hist[0].val, u32(0x5A))
}

@(test)
machine_ide_decode_test_pci_config_ports_take_precedence :: proc(t: ^testing.T) {
	backing := make([]u8, 1024 * 1024)
	defer delete(backing)
	m := new(Machine)
	defer free(m)
	machine_ide_decode_test_init(m, &backing)
	defer bus_destroy(&m.platform.bus)
	if !testing.expect(
		t,
		machine_ide_decode_test_configure_primary_native(m, 0x0000_0CF9, 0x0000_03E5),
	) {
		return
	}

	m.ide.reg_lba_mid = 0x44
	testing.expect(t, machine_io_write(m, 0xCF8, 4, 0x8000_3940))
	testing.expect(t, machine_io_write(m, 0xCFC, 1, u32(AMD756_IDE_PRIMARY_CHANNEL_ENABLE)))
	testing.expect_value(t, m.ide.reg_lba_mid, u8(0x44))
}
