// SPDX-License-Identifier: GPL-3.0-only
package machine

import disk "../disk"
import hv "../hv"
import video "../vga"
import "core:log"
import "core:testing"
import "core:time"

@(private = "file")
pci_machine_test_write_config :: proc(p: ^Pci, address: u32, size: u8, value: u32) {
	pci_out(p, 0xCF8, 4, address)
	pci_out(p, 0xCFC, size, value)
}

@(private = "file")
pci_machine_test_write_live_config :: proc(m: ^Machine, address: u32, size: u8, value: u32) {
	bus_io_write(&m.bus, 0xCF8, 4, address)
	bus_io_write(&m.bus, 0xCFC, size, value)
}

@(private = "file")
pci_machine_test_apply_mapping :: proc(t: ^testing.T, m: ^Machine) -> bool {
	m.vm.ram[0x7C00] = 0xF4
	hv.set_realmode_entry(&m.vm, 0, 0x7C00)
	return testing.expect_value(t, hv.run(&m.vm).kind, hv.Exit_Kind.Halt)
}

@(test)
test_machine_pci_sync_controls_storage_and_vga_decode :: proc(t: ^testing.T) {
	m := new(Machine)
	defer free(m)
	pci_init(&m.pci)
	disk.ide_init(&m.ide, {})
	disk.atapi_init(&m.atapi)
	video.gsw_vga_init(&m.gsw_vga, nil)

	testing.expect(t, machine_sync_pci_devices(m))
	testing.expect(t, !disk.ide_io_decoded(&m.ide))
	testing.expect(t, !disk.atapi_io_decoded(&m.atapi))
	testing.expect(t, !m.vga.pci_io_enabled)
	testing.expect(t, m.vga.pci_memory_enabled)
	testing.expect_value(t, video.vga_framebuffer_base(&m.vga), u64(GSW_VGA_FRAMEBUFFER_BAR))

	pci_machine_test_write_config(&m.pci, 0x8000_3940, 1, 0x03)
	pci_machine_test_write_config(&m.pci, 0x8000_3904, 2, 0x0001)
	testing.expect(t, machine_sync_pci_devices(m))
	testing.expect(t, disk.ide_io_decoded(&m.ide))
	testing.expect(t, disk.atapi_io_decoded(&m.atapi))

	pci_machine_test_write_config(&m.pci, 0x8000_3940, 1, u32(AMD756_IDE_PRIMARY_CHANNEL_ENABLE))
	testing.expect(t, machine_sync_pci_devices(m))
	testing.expect(t, disk.ide_io_decoded(&m.ide))
	testing.expect(t, !disk.atapi_io_decoded(&m.atapi))

	pci_machine_test_write_config(&m.pci, 0x8000_3940, 1, u32(AMD756_IDE_SECONDARY_CHANNEL_ENABLE))
	testing.expect(t, machine_sync_pci_devices(m))
	testing.expect(t, !disk.ide_io_decoded(&m.ide))
	testing.expect(t, disk.atapi_io_decoded(&m.atapi))

	pci_machine_test_write_config(&m.pci, 0x8000_3904, 2, 0x0004)
	testing.expect(t, machine_sync_pci_devices(m))
	testing.expect(t, !disk.ide_io_decoded(&m.ide))
	testing.expect(t, !disk.atapi_io_decoded(&m.atapi))

	pci_machine_test_write_config(&m.pci, 0x8000_1004, 2, 0x0007)
	pci_machine_test_write_config(&m.pci, 0x8000_1010, 4, 0xF200_0000)
	pci_machine_test_write_config(&m.pci, 0x8000_1014, 4, 0xD000_0000)
	testing.expect(t, machine_sync_pci_devices(m))
	testing.expect(t, m.vga.pci_io_enabled)
	testing.expect(t, m.vga.pci_memory_enabled)
	testing.expect_value(t, video.vga_framebuffer_base(&m.vga), u64(0xD000_0000))
	offset, decoded := video.gsw_vga_control_offset(&m.gsw_vga, 0xF200_000C, 4)
	testing.expect_value(t, offset, video.GSW_VGA_REG_STATUS)
	testing.expect(t, decoded)

	pci_machine_test_write_config(&m.pci, 0x8000_1004, 2, 0x0001)
	testing.expect(t, machine_sync_pci_devices(m))
	_, decoded = video.gsw_vga_control_offset(&m.gsw_vga, 0xF200_000C, 4)
	testing.expect(t, !decoded)
}

@(test)
test_machine_amd756_iden_gates_and_restores_storage_decode :: proc(t: ^testing.T) {
	m := new(Machine)
	defer free(m)
	pci_init(&m.pci)
	disk.ide_init(&m.ide, {})
	disk.atapi_init(&m.atapi)
	disk.bmide_init(&m.bmide)

	pci_machine_test_write_config(&m.pci, 0x8000_3940, 1, 0x03)
	pci_machine_test_write_config(&m.pci, 0x8000_3904, 2, 0x0005)
	testing.expect(t, machine_sync_pci_devices(m))
	testing.expect(t, disk.ide_io_decoded(&m.ide))
	testing.expect(t, disk.atapi_io_decoded(&m.atapi))
	testing.expect(t, pci_ide_bus_master_enabled(&m.pci))

	pci_machine_test_write_config(&m.pci, 0x8000_3848, 1, 0x03)
	testing.expect(t, machine_sync_pci_devices(m))
	testing.expect(t, !disk.ide_io_decoded(&m.ide))
	testing.expect(t, !disk.atapi_io_decoded(&m.atapi))
	testing.expect(t, !pci_ide_bus_master_enabled(&m.pci))

	pci_machine_test_write_config(&m.pci, 0x8000_3848, 1, 0x01)
	testing.expect(t, machine_sync_pci_devices(m))
	testing.expect(t, disk.ide_io_decoded(&m.ide))
	testing.expect(t, disk.atapi_io_decoded(&m.atapi))
	testing.expect(t, pci_ide_bus_master_enabled(&m.pci))
}

@(test)
test_machine_disabled_ide_channels_do_not_cancel_bmide_requests :: proc(t: ^testing.T) {
	m := new(Machine)
	defer free(m)
	pci_init(&m.pci)
	disk.ide_init(&m.ide, {})
	disk.atapi_init(&m.atapi)
	disk.bmide_init(&m.bmide)
	pci_machine_test_write_config(&m.pci, 0x8000_3940, 1, 0x03)
	pci_machine_test_write_config(&m.pci, 0x8000_3904, 2, 0x0084)
	if !testing.expect(t, machine_sync_pci_devices(m)) {return}
	testing.expect(t, !disk.ide_io_decoded(&m.ide))
	testing.expect(t, !disk.atapi_io_decoded(&m.atapi))

	m.device_sync_valid[int(Scheduled_Device.Ide)] = true
	m.device_sync_valid[int(Scheduled_Device.Atapi)] = true
	m.bmide.channels[0].request_pending = true
	m.bmide.channels[1].request_pending = true
	machine_ide_write(m, 0x1F7, 1, 0xEC)
	machine_atapi_write(m, 0x177, 1, 0xA1)
	testing.expect(t, m.bmide.channels[0].request_pending)
	testing.expect(t, m.bmide.channels[1].request_pending)

	machine_ide_write(m, 0x3F6, 1, 0x04)
	machine_atapi_write(m, 0x376, 1, 0x04)
	testing.expect(t, m.bmide.channels[0].request_pending)
	testing.expect(t, m.bmide.channels[1].request_pending)
}

@(test)
test_machine_gsw_control_mmio_follows_relocated_bar :: proc(t: ^testing.T) {
	m := new(Machine)
	defer free(m)
	bus_init(&m.bus)
	defer bus_destroy(&m.bus)
	m.vm.a20_enabled = true
	pci_init(&m.pci)
	video.gsw_vga_init(&m.gsw_vga, nil)

	pci_machine_test_write_config(&m.pci, 0x8000_1004, 2, 0x0007)
	pci_machine_test_write_config(&m.pci, 0x8000_1010, 4, 0xF200_0000)
	testing.expect(t, machine_sync_pci_devices(m))

	old_data := [4]u8{}
	machine_mmio(m, u64(GSW_VGA_CONTROL_BAR), false, old_data[:])
	testing.expect_value(t, old_data, [4]u8{0xFF, 0xFF, 0xFF, 0xFF})

	new_data := [4]u8{}
	machine_mmio(m, 0xF200_0000, false, new_data[:])
	value :=
		u32(new_data[0]) | u32(new_data[1]) << 8 | u32(new_data[2]) << 16 | u32(new_data[3]) << 24
	testing.expect_value(t, value, video.GSW_VGA_ID)
}

@(test)
test_machine_gsw_vga_inta_uses_pirqb :: proc(t: ^testing.T) {
	m := new(Machine)
	defer free(m)
	pci_init(&m.pci)
	machine_gsw_vga_irq(m, true)
	testing.expect(t, pci_pirq_is_asserted(&m.pci, PCI_PIRQ_B))
	testing.expect(t, !pci_pirq_is_asserted(&m.pci, PCI_PIRQ_A))
	testing.expect_value(t, pci_pirq_active_irq_mask(&m.pci), u16(1 << 11))
	machine_gsw_vga_irq(m, false)
	testing.expect_value(t, pci_pirq_active_irq_mask(&m.pci), u16(0))
}

@(test)
test_machine_hardware_trace_records_pirq_bmide_mmio_and_atapi_transitions :: proc(t: ^testing.T) {
	m := new(Machine)
	defer free(m)
	if !testing.expect(t, machine_set_hardware_trace(m, true)) {return}
	defer {
		trace := machine_hardware_trace_detach(m)
		if trace != nil {free(trace)}
	}
	pci_init(&m.pci)
	disk.bmide_init(&m.bmide)
	disk.atapi_init(&m.atapi)
	video.gsw_vga_init(&m.gsw_vga, nil)
	pci_machine_test_write_config(&m.pci, 0x8000_3940, 1, 0x03)
	pci_machine_test_write_config(&m.pci, 0x8000_3920, 4, 0x0000_C001)
	pci_machine_test_write_config(&m.pci, 0x8000_3904, 2, 0x0005)
	if !testing.expect(t, machine_sync_pci_devices(m)) {return}

	machine_gsw_vga_irq(m, true)
	machine_gsw_vga_irq(m, true)
	machine_gsw_vga_irq(m, false)
	testing.expect(t, machine_io_write(m, 0xC004, 4, 0x0012_3400))
	data: [4]u8
	machine_mmio(m, u64(GSW_VGA_CONTROL_BAR), false, data[:])
	machine_atapi_write(m, 0x174, 1, 0)
	machine_atapi_write(m, 0x175, 1, 8)
	machine_atapi_write(m, 0x177, 1, 0xA0)
	packet: [disk.ATAPI_PACKET_BYTES]u8
	testing.expect_value(
		t,
		machine_atapi_stream_write(m, 0x170, 2, packet[:]),
		disk.ATAPI_PACKET_BYTES / 2,
	)

	counts: [Hardware_Event_Kind]int
	for sequence in 0 ..< m.hardware_trace.retained_count {
		event := m.hardware_trace.events[sequence % HARDWARE_TRACE_CAPACITY]
		counts[event.kind] += 1
	}
	testing.expect_value(t, counts[.Pirq], 2)
	testing.expect_value(t, counts[.Bmide_Access], 1)
	testing.expect_value(t, counts[.Mmio_Access], 1)
	testing.expect_value(t, counts[.Atapi_Packet], 1)
}

@(test)
test_machine_gsw_framebuffer_mapping_follows_bar1_and_mse :: proc(t: ^testing.T) {
	if !hv.available() {
		log.warn("WHPX not available")
		return
	}
	testing.set_fail_timeout(t, 10 * time.Second)
	m := new(Machine)
	defer free(m)
	if !testing.expect(t, machine_init(m, 64 * 1024 * 1024)) {return}
	defer machine_destroy(m)
	machine_clock_set_running(m, false)

	if !testing.expect_value(t, len(m.vm.device_mappings), 1) {return}
	mapping := &m.vm.device_mappings[0]
	testing.expect_value(t, mapping.gpa, u64(GSW_VGA_FRAMEBUFFER_BAR))
	testing.expect(t, mapping.mapped && !mapping.request_pending)

	pci_machine_test_write_live_config(m, 0x8000_1014, 4, 0xD000_0000)
	testing.expect_value(t, video.vga_framebuffer_base(&m.vga), u64(0xD000_0000))
	testing.expect_value(t, mapping.gpa, u64(GSW_VGA_FRAMEBUFFER_BAR))
	testing.expect_value(t, mapping.requested_gpa, u64(0xD000_0000))
	testing.expect(t, mapping.request_pending)
	if !pci_machine_test_apply_mapping(t, m) {return}
	testing.expect_value(t, mapping.gpa, u64(0xD000_0000))
	testing.expect(t, mapping.mapped && !mapping.request_pending)

	pci_machine_test_write_live_config(m, 0x8000_1004, 2, 0x0004)
	testing.expect(t, !m.vga.pci_memory_enabled)
	testing.expect(t, mapping.request_pending && !mapping.requested_mapped)
	if !pci_machine_test_apply_mapping(t, m) {return}
	testing.expect(t, !mapping.mapped && !mapping.request_pending)

	pci_machine_test_write_live_config(m, 0x8000_1004, 2, 0x0006)
	testing.expect(t, m.vga.pci_memory_enabled)
	testing.expect(t, mapping.request_pending && mapping.requested_mapped)
	if !pci_machine_test_apply_mapping(t, m) {return}
	testing.expect_value(t, mapping.gpa, u64(0xD000_0000))
	testing.expect(t, mapping.mapped && !mapping.request_pending)
}
