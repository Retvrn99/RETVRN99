// SPDX-License-Identifier: GPL-3.0-only
package machine

import sound "../audio"
import "core:testing"

gsw_pcm_machine_test_mmio_write32 :: proc(m: ^Machine, base: u64, offset, value: u32) {
	data := [4]u8{u8(value), u8(value >> 8), u8(value >> 16), u8(value >> 24)}
	machine_mmio(m, base + u64(offset), true, data[:])
}

gsw_pcm_machine_test_mmio_read32 :: proc(m: ^Machine, base: u64, offset: u32) -> u32 {
	data: [4]u8
	machine_mmio(m, base + u64(offset), false, data[:])
	return u32(data[0]) | u32(data[1]) << 8 | u32(data[2]) << 16 | u32(data[3]) << 24
}

@(test)
gsw_pcm_machine_test_relocated_mmio_pull_and_shared_pirq :: proc(t: ^testing.T) {
	m := new(Machine)
	defer free(m)
	ram: [8192]u8
	m.vm.ram = ram[:]
	bus_init(&m.platform.bus)
	defer bus_destroy(&m.platform.bus)
	pic_setup(&m.platform.pic)
	// The normal guest persona deliberately hides the unproven native PCI
	// Adapter.  This integration test opts in so the reserved ABI remains
	// covered while the legacy SB16/OPL3 Adapter is tested in guests.
	pci_init(&m.pci, true)
	pci_connect_pic(&m.pci, &m.platform.pic)
	sound.gsw_sound_init(&m.gsw_sound)
	if !testing.expect(t, sound.audio_mixer_init(&m.audio)) {return}
	if !testing.expect(t, machine_sync_pci_devices(m)) {return}

	old_base := u64(GSW_SOUND_CONTROL_BAR)
	testing.expect_value(
		t,
		gsw_pcm_machine_test_mmio_read32(m, old_base, sound.GSW_PCM_REG_ID),
		sound.GSW_PCM_ID,
	)
	pci_out(&m.pci, 0xCF8, 4, 0x8000_1810)
	pci_out(&m.pci, 0xCFC, 4, 0xF200_0000)
	if !testing.expect(t, machine_sync_pci_devices(m)) {return}
	new_base := u64(0xF200_0000)
	testing.expect_value(
		t,
		gsw_pcm_machine_test_mmio_read32(m, new_base, sound.GSW_PCM_REG_ID),
		sound.GSW_PCM_ID,
	)

	ram[4096] = 0x34
	ram[4097] = 0x12
	ram[4098] = 0xDC
	ram[4099] = 0xFE
	gsw_pcm_machine_test_mmio_write32(m, new_base, sound.GSW_PCM_REG_RING_GPA_LOW, 4096)
	gsw_pcm_machine_test_mmio_write32(m, new_base, sound.GSW_PCM_REG_RING_SIZE, 4096)
	gsw_pcm_machine_test_mmio_write32(m, new_base, sound.GSW_PCM_REG_PERIOD_BYTES, 4)
	gsw_pcm_machine_test_mmio_write32(m, new_base, sound.GSW_PCM_REG_RING_TAIL, 4)
	gsw_pcm_machine_test_mmio_write32(
		m,
		new_base,
		sound.GSW_PCM_REG_IRQ_ENABLE,
		sound.GSW_PCM_IRQ_PERIOD,
	)
	// A START write changes the machine's earliest observable deadline.  It
	// must replace an active vCPU run guard immediately, not wait for a later
	// I/O exit or the governor quantum.
	wake_probe: Machine_String_IO_Wake_Probe
	m.wake_ctx = &wake_probe
	m.wake_schedule = machine_test_string_io_rearm
	m.vcpu_running = true
	gsw_pcm_machine_test_mmio_write32(
		m,
		new_base,
		sound.GSW_PCM_REG_CONTROL,
		sound.GSW_PCM_CONTROL_START,
	)
	testing.expect_value(t, wake_probe.run_guards, 1)
	testing.expect_value(t, wake_probe.last_mode, Wake_Schedule_Mode.Run_Guard)

	observation := sound.gsw_sound_observation(&m.gsw_sound)
	sample_deadline, sample_pending :=
		observation.native_sample_deadline, observation.native_sample_pending
	testing.expect(t, sample_pending)
	machine_audio_advance_gsw_to(m, sample_deadline)
	observation = sound.gsw_sound_observation(&m.gsw_sound)
	testing.expect_value(
		t,
		observation.native_frame,
		sound.Audio_Frame{left = 0x1234, right = -292},
	)
	testing.expect(t, pci_pirq_source_is_asserted(&m.pci, PCI_PIRQ_C, .Gsw_Sound))
	testing.expect_value(t, pci_pirq_active_irq_mask(&m.pci), u16(1 << 10))

	_ = pci_pirq_set_source_level(&m.pci, PCI_PIRQ_C, .Amd756_Ide, true)
	gsw_pcm_machine_test_mmio_write32(
		m,
		new_base,
		sound.GSW_PCM_REG_IRQ_STATUS,
		sound.GSW_PCM_IRQ_PERIOD,
	)
	testing.expect(t, !pci_pirq_source_is_asserted(&m.pci, PCI_PIRQ_C, .Gsw_Sound))
	testing.expect(t, pci_pirq_source_is_asserted(&m.pci, PCI_PIRQ_C, .Amd756_Ide))
	testing.expect(t, pci_pirq_is_asserted(&m.pci, PCI_PIRQ_C))
	_ = pci_pirq_set_source_level(&m.pci, PCI_PIRQ_C, .Amd756_Ide, false)
	testing.expect(t, !pci_pirq_is_asserted(&m.pci, PCI_PIRQ_C))
}
