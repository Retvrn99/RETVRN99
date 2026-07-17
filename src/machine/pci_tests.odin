// SPDX-License-Identifier: GPL-3.0-only
package machine

import "core:testing"

@(test)
pci_test_amd750_identity :: proc(t: ^testing.T) {
	p: Pci
	pci_init(&p)

	pci_out(&p, 0xCF8, 4, 0x8000_0000)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0x7006_1022))
	pci_out(&p, 0xCF8, 4, 0x8000_0008)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0x0600_0021))
	pci_out(&p, 0xCF8, 4, 0x8000_000C)
	testing.expect_value(t, (pci_in(&p, 0xCFC, 4) >> 16) & 0xFF, u32(0x80))
	// This supported subset has no AGP aperture or capability list.
	pci_out(&p, 0xCF8, 4, 0x8000_0004)
	testing.expect_value(t, pci_in(&p, 0xCFE, 2) & 0x0010, u32(0))
	pci_out(&p, 0xCF8, 4, 0x8000_0034)
	testing.expect_value(t, pci_in(&p, 0xCFC, 1), u32(0))

	// The AMD-751 has no Intel-style PAM registers. These bytes are not a
	// firmware shadow control surface and stay read-only in this model.
	pci_out(&p, 0xCF8, 4, 0x8000_0058)
	pci_out(&p, 0xCFD, 1, 0xFF)
	pci_out(&p, 0xCFF, 1, 0xFF)
	testing.expect_value(t, pci_in(&p, 0xCFD, 1), u32(0))
	testing.expect_value(t, pci_in(&p, 0xCFF, 1), u32(0))
}

@(test)
pci_test_amd756_isa_bridge_identity_and_reserved_registers :: proc(t: ^testing.T) {
	p: Pci
	pci_init(&p)

	pci_out(&p, 0xCF8, 4, 0x8000_3800) // 00:07.0
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0x7408_1022))
	pci_out(&p, 0xCF8, 4, 0x8000_3808)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0x0601_0001))
	pci_out(&p, 0xCF8, 4, 0x8000_380C)
	testing.expect_value(t, (pci_in(&p, 0xCFC, 4) >> 16) & 0xFF, u32(0x80))
	pci_out(&p, 0xCF8, 4, 0x8000_3848)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0x0084_0801))
	pci_out(&p, 0xCF8, 4, 0x8000_384C)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0x0300_0000))

	pci_out(&p, 0xCF8, 4, 0x8000_3840)
	pci_out(&p, 0xCFC, 4, 0xFFFF_FFFF)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0xFF00_A90B))
	pci_out(&p, 0xCF8, 4, 0x8000_3844)
	pci_out(&p, 0xCFC, 4, 0xFFFF_FFFF)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0xF001_7F00))
	pci_out(&p, 0xCF8, 4, 0x8000_3848)
	pci_out(&p, 0xCFC, 4, 0xFFFF_FFFF)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0x1F8F_4F8F))
	pci_out(&p, 0xCF8, 4, 0x8000_3860)
	pci_out(&p, 0xCFC, 4, 0xFFFF_FFFF)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0xFFF8_FFF8))
	pci_out(&p, 0xCF8, 4, 0x8000_3868)
	pci_out(&p, 0xCFC, 4, 0xFFFF_FFFF)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0xFFF8_0000))

	pci_out(&p, 0xCF8, 4, 0x8000_3848)
	pci_out(&p, 0xCFD, 1, 0x06)
	pci_out(&p, 0xCFD, 1, 0x00)
	testing.expect_value(t, pci_in(&p, 0xCFD, 1) & 0x06, u32(0x06))

	// PIRQ registers 56h/57h belong to the omitted PM function (740B), not
	// to the ISA bridge (7408). The whole 54h-5Fh range is reserved here.
	for offset := u32(0x54); offset <= 0x5C; offset += 4 {
		pci_out(&p, 0xCF8, 4, 0x8000_3800 | offset)
		pci_out(&p, 0xCFC, 4, 0xFFFF_FFFF)
		testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0))
	}
}

@(test)
pci_test_amd756_romw_defaults_clear_and_is_non_sticky :: proc(t: ^testing.T) {
	p: Pci
	pci_init(&p)
	pci_out(&p, 0xCF8, 4, 0x8000_3840)
	testing.expect_value(t, pci_in(&p, 0xCFC, 1) & u32(AMD756_ISA_ROM_WRITE_ENABLE), u32(0))
	pci_out(&p, 0xCFC, 1, u32(AMD756_ISA_ROM_WRITE_ENABLE))
	testing.expect_value(
		t,
		pci_in(&p, 0xCFC, 1) & u32(AMD756_ISA_ROM_WRITE_ENABLE),
		u32(AMD756_ISA_ROM_WRITE_ENABLE),
	)
	pci_out(&p, 0xCFC, 1, 0)
	testing.expect_value(t, pci_in(&p, 0xCFC, 1) & u32(AMD756_ISA_ROM_WRITE_ENABLE), u32(0))
}

@(test)
pci_test_amd756_iden_hides_and_restores_ide_function :: proc(t: ^testing.T) {
	p: Pci
	pci_init(&p)
	testing.expect(t, pci_amd756_ide_enabled(&p))

	pci_out(&p, 0xCF8, 4, 0x8000_3940)
	pci_out(&p, 0xCFC, 1, 0x03)
	pci_out(&p, 0xCF8, 4, 0x8000_3904)
	pci_out(&p, 0xCFC, 2, 0x0005)
	testing.expect(t, pci_ide_io_enabled(&p))
	testing.expect(t, pci_ide_bus_master_enabled(&p))
	testing.expect(t, pci_ide_channel_enabled(&p, 0))
	testing.expect(t, pci_ide_channel_enabled(&p, 1))
	_, valid := pci_ide_bus_master_io_base(&p)
	testing.expect(t, valid)

	pci_out(&p, 0xCF8, 4, 0x8000_3848)
	pci_out(&p, 0xCFC, 1, 0x03)
	testing.expect(t, !pci_amd756_ide_enabled(&p))
	pci_out(&p, 0xCF8, 4, 0x8000_3900)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0xFFFF_FFFF))
	pci_out(&p, 0xCF8, 1, 0xF2)
	pci_out(&p, 0xCFA, 1, 0)
	testing.expect_value(t, pci_in(&p, 0xC700, 4), u32(0xFFFF_FFFF))
	pci_out(&p, 0xCF8, 1, 0)
	testing.expect(t, !pci_ide_io_enabled(&p))
	testing.expect(t, !pci_ide_bus_master_enabled(&p))
	testing.expect(t, !pci_ide_channel_enabled(&p, 0))
	testing.expect(t, !pci_ide_channel_enabled(&p, 1))
	_, valid = pci_ide_bus_master_io_base(&p)
	testing.expect(t, !valid)
	_, claimed := pci_ide_bus_master_decode(&p, 0xCC00, 1)
	testing.expect(t, !claimed)

	pci_out(&p, 0xCF8, 4, 0x8000_3848)
	pci_out(&p, 0xCFC, 1, 0x01)
	testing.expect(t, pci_amd756_ide_enabled(&p))
	pci_out(&p, 0xCF8, 4, 0x8000_3900)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0x7409_1022))
	testing.expect(t, pci_ide_io_enabled(&p))
	testing.expect(t, pci_ide_bus_master_enabled(&p))
	testing.expect(t, pci_ide_channel_enabled(&p, 0))
	testing.expect(t, pci_ide_channel_enabled(&p, 1))
}

@(test)
pci_test_amd756_subsystem_programming_mirrors_read_only_header :: proc(t: ^testing.T) {
	p: Pci
	pci_init(&p)
	pci_out(&p, 0xCF8, 4, 0x8000_3850)
	pci_out(&p, 0xCFC, 4, 0xA1B2_C3D4)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0xA1B2_C3D4))
	pci_out(&p, 0xCF8, 4, 0x8000_382C)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0xA1B2_C3D4))
	pci_out(&p, 0xCFC, 4, 0)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0xA1B2_C3D4))

	pci_out(&p, 0xCF8, 4, 0x8000_3850)
	pci_out(&p, 0xCFD, 1, 0x5A)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0xA1B2_5AD4))
	pci_out(&p, 0xCF8, 4, 0x8000_382C)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0xA1B2_5AD4))
}

@(test)
pci_test_amd756_ide_identity_and_compatibility_mode :: proc(t: ^testing.T) {
	p: Pci
	pci_init(&p)

	pci_out(&p, 0xCF8, 4, 0x8000_3900) // 00:07.1
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0x7409_1022))
	pci_out(&p, 0xCF8, 4, 0x8000_3908)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0x0101_8A03))
	pci_out(&p, 0xCFD, 1, 0)
	testing.expect_value(t, pci_in(&p, 0xCFD, 1), u32(0x8A))
	pci_out(&p, 0xCFD, 1, 0xFF)
	testing.expect_value(t, pci_in(&p, 0xCFD, 1), u32(0x8F))
	pci_out(&p, 0xCFD, 1, 0)
	testing.expect_value(t, pci_in(&p, 0xCFD, 1), u32(0x8A))
	for offset := u32(0x10); offset <= 0x1C; offset += 4 {
		pci_out(&p, 0xCF8, 4, 0x8000_3900 | offset)
		pci_out(&p, 0xCFC, 4, 0xFFFF_FFFF)
		testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0))
	}
	pci_out(&p, 0xCF8, 4, 0x8000_3940)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0x0000_0008))
	pci_out(&p, 0xCF8, 4, 0x8000_3948)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0xA8A8_A8A8))
	pci_out(&p, 0xCF8, 4, 0x8000_394C)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0xFFFF_00FF))
	pci_out(&p, 0xCF8, 4, 0x8000_3950)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0x0303_0303))

	pci_out(&p, 0xCF8, 4, 0x8000_3940)
	pci_out(&p, 0xCFC, 4, 0xFFFF_FFFF)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0x0000_F00B))
	pci_out(&p, 0xCF8, 4, 0x8000_3944)
	pci_out(&p, 0xCFC, 4, 0xFFFF_FFFF)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0))
	pci_out(&p, 0xCF8, 4, 0x8000_3948)
	pci_out(&p, 0xCFC, 4, 0xFFFF_FFFF)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0xFFFF_FFFF))
	pci_out(&p, 0xCF8, 4, 0x8000_394C)
	pci_out(&p, 0xCFC, 4, 0x1122_3344)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0x1122_0044))
	pci_out(&p, 0xCF8, 4, 0x8000_3950)
	pci_out(&p, 0xCFC, 4, 0xA5A5_A5A5)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0x8585_8585))
}

@(test)
pci_test_amd756_ide_native_bars_are_latent_and_mode_visible :: proc(t: ^testing.T) {
	p: Pci
	pci_init(&p)

	// Compatibility-mode writes and probes do not disturb the latent defaults.
	pci_out(&p, 0xCF8, 4, 0x8000_3910)
	pci_out(&p, 0xCFC, 4, 0x0000_1234)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0))
	pci_out(&p, 0xCFC, 4, 0xFFFF_FFFF)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0))

	pci_out(&p, 0xCF8, 4, 0x8000_3908)
	pci_out(&p, 0xCFD, 1, u32(AMD756_IDE_PRIMARY_NATIVE_MODE))
	primary_offsets := [?]u32{0x10, 0x14}
	primary_defaults := [?]u32 {
		AMD756_IDE_PRIMARY_COMMAND_BAR_DEFAULT,
		AMD756_IDE_PRIMARY_CONTROL_BAR_DEFAULT,
	}
	primary_masks := [?]u32{0xFFFF_FFF9, 0xFFFF_FFFD}
	primary_writes := [?]u32{0x0000_1234, 0x0000_567B}
	primary_values := [?]u32{0x0000_1231, 0x0000_5679}
	for offset, index in primary_offsets {
		pci_out(&p, 0xCF8, 4, 0x8000_3900 | offset)
		testing.expect_value(t, pci_in(&p, 0xCFC, 4), primary_defaults[index])
		pci_out(&p, 0xCFC, 4, 0xFFFF_FFFF)
		testing.expect_value(t, pci_in(&p, 0xCFC, 4), primary_masks[index])
		pci_out(&p, 0xCFC, 4, primary_writes[index])
		testing.expect_value(t, pci_in(&p, 0xCFC, 4), primary_values[index])
	}

	// Hiding a probed BAR clears the probe but preserves its programmed base.
	pci_out(&p, 0xCF8, 4, 0x8000_3910)
	pci_out(&p, 0xCFC, 4, 0xFFFF_FFFF)
	pci_out(&p, 0xCF8, 4, 0x8000_3908)
	pci_out(&p, 0xCFD, 1, 0)
	for offset in primary_offsets {
		pci_out(&p, 0xCF8, 4, 0x8000_3900 | offset)
		testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0))
		pci_out(&p, 0xCFC, 4, 0xA5A5_A5A5)
		testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0))
	}
	pci_out(&p, 0xCF8, 4, 0x8000_3908)
	pci_out(&p, 0xCFD, 1, u32(AMD756_IDE_PRIMARY_NATIVE_MODE))
	for offset, index in primary_offsets {
		pci_out(&p, 0xCF8, 4, 0x8000_3900 | offset)
		testing.expect_value(t, pci_in(&p, 0xCFC, 4), primary_values[index])
	}

	// Secondary native mode independently exposes BAR2/BAR3 and hides BAR0/BAR1.
	pci_out(&p, 0xCF8, 4, 0x8000_3908)
	pci_out(&p, 0xCFD, 1, u32(AMD756_IDE_SECONDARY_NATIVE_MODE))
	for offset in primary_offsets {
		pci_out(&p, 0xCF8, 4, 0x8000_3900 | offset)
		testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0))
	}
	secondary_offsets := [?]u32{0x18, 0x1C}
	secondary_defaults := [?]u32 {
		AMD756_IDE_SECONDARY_COMMAND_BAR_DEFAULT,
		AMD756_IDE_SECONDARY_CONTROL_BAR_DEFAULT,
	}
	secondary_masks := [?]u32{0xFFFF_FFF9, 0xFFFF_FFFD}
	secondary_writes := [?]u32{0x0000_9ABC, 0x0000_DEF2}
	secondary_values := [?]u32{0x0000_9AB9, 0x0000_DEF1}
	for offset, index in secondary_offsets {
		pci_out(&p, 0xCF8, 4, 0x8000_3900 | offset)
		testing.expect_value(t, pci_in(&p, 0xCFC, 4), secondary_defaults[index])
		pci_out(&p, 0xCFC, 4, 0xFFFF_FFFF)
		testing.expect_value(t, pci_in(&p, 0xCFC, 4), secondary_masks[index])
		pci_out(&p, 0xCFC, 4, secondary_writes[index])
		testing.expect_value(t, pci_in(&p, 0xCFC, 4), secondary_values[index])
	}

	pci_out(&p, 0xCF8, 4, 0x8000_3908)
	pci_out(&p, 0xCFD, 1, u32(AMD756_IDE_PRIMARY_NATIVE_MODE | AMD756_IDE_SECONDARY_NATIVE_MODE))
	all_offsets := [?]u32{0x10, 0x14, 0x18, 0x1C}
	all_values := [?]u32{0x0000_1231, 0x0000_5679, 0x0000_9AB9, 0x0000_DEF1}
	for offset, index in all_offsets {
		pci_out(&p, 0xCF8, 4, 0x8000_3900 | offset)
		testing.expect_value(t, pci_in(&p, 0xCFC, 4), all_values[index])
	}
}

@(test)
pci_test_amd756_ide_interrupt_header_tracks_channel_modes :: proc(t: ^testing.T) {
	p: Pci
	pci_init(&p)

	pci_out(&p, 0xCF8, 4, 0x8000_393C)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0))
	pci_out(&p, 0xCFC, 4, 0xFFFF_FF0A)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0))

	pci_out(&p, 0xCF8, 4, 0x8000_3908)
	pci_out(&p, 0xCFD, 1, u32(AMD756_IDE_PRIMARY_NATIVE_MODE))
	pci_out(&p, 0xCF8, 4, 0x8000_393C)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0x0000_0100))
	pci_out(&p, 0xCFC, 1, 0x0A)
	pci_out(&p, 0xCFD, 1, 0xFF)
	pci_out(&p, 0xCFE, 2, 0xFFFF)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0x0000_010A))

	pci_out(&p, 0xCF8, 4, 0x8000_3908)
	pci_out(&p, 0xCFD, 1, u32(AMD756_IDE_SECONDARY_NATIVE_MODE))
	pci_out(&p, 0xCF8, 4, 0x8000_393C)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0x0000_010A))

	pci_out(&p, 0xCF8, 4, 0x8000_3908)
	pci_out(&p, 0xCFD, 1, 0)
	pci_out(&p, 0xCF8, 4, 0x8000_393C)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0))
	pci_out(&p, 0xCFC, 1, 0x0B)

	pci_out(&p, 0xCF8, 4, 0x8000_3908)
	pci_out(&p, 0xCFD, 1, u32(AMD756_IDE_PRIMARY_NATIVE_MODE | AMD756_IDE_SECONDARY_NATIVE_MODE))
	pci_out(&p, 0xCF8, 4, 0x8000_393C)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0x0000_010A))
}

@(test)
pci_test_amd756_channel_enable_bits_gate_channels_independently :: proc(t: ^testing.T) {
	p: Pci
	pci_init(&p)
	pci_out(&p, 0xCF8, 4, 0x8000_3940)

	testing.expect_value(t, pci_ide_channel_enabled(&p, 0), false)
	testing.expect_value(t, pci_ide_channel_enabled(&p, 1), false)
	testing.expect_value(t, pci_in(&p, 0xCFC, 1), u32(AMD756_IDE_CHANNEL_ENABLE_FIXED))

	pci_out(&p, 0xCFC, 1, u32(AMD756_IDE_PRIMARY_CHANNEL_ENABLE))
	testing.expect_value(t, pci_ide_channel_enabled(&p, 0), true)
	testing.expect_value(t, pci_ide_channel_enabled(&p, 1), false)
	testing.expect_value(
		t,
		pci_in(&p, 0xCFC, 1),
		u32(AMD756_IDE_CHANNEL_ENABLE_FIXED | AMD756_IDE_PRIMARY_CHANNEL_ENABLE),
	)

	pci_out(&p, 0xCFC, 1, u32(AMD756_IDE_SECONDARY_CHANNEL_ENABLE))
	testing.expect_value(t, pci_ide_channel_enabled(&p, 0), false)
	testing.expect_value(t, pci_ide_channel_enabled(&p, 1), true)
	testing.expect_value(
		t,
		pci_in(&p, 0xCFC, 1),
		u32(AMD756_IDE_CHANNEL_ENABLE_FIXED | AMD756_IDE_SECONDARY_CHANNEL_ENABLE),
	)
}

@(test)
pci_test_amd_command_register_masks :: proc(t: ^testing.T) {
	p: Pci
	pci_init(&p)

	pci_out(&p, 0xCF8, 4, 0x8000_0004)
	testing.expect_value(t, pci_in(&p, 0xCFC, 2), u32(0x0004))
	pci_out(&p, 0xCFC, 2, 0xFFFF)
	testing.expect_value(t, pci_in(&p, 0xCFC, 2), u32(0x0106))
	pci_out(&p, 0xCFC, 2, 0)
	testing.expect_value(t, pci_in(&p, 0xCFC, 2), u32(0x0004))

	pci_out(&p, 0xCF8, 4, 0x8000_3804)
	testing.expect_value(t, pci_in(&p, 0xCFC, 2), u32(0x000F))
	pci_out(&p, 0xCFC, 2, 0xFFFF)
	testing.expect_value(t, pci_in(&p, 0xCFC, 2), u32(0x000F))
	pci_out(&p, 0xCFC, 2, 0)
	testing.expect_value(t, pci_in(&p, 0xCFC, 2), u32(0x0007))

	pci_out(&p, 0xCF8, 4, 0x8000_3904)
	testing.expect_value(t, pci_in(&p, 0xCFC, 2), u32(0))
	pci_out(&p, 0xCFC, 2, 0xFFFF)
	testing.expect_value(t, pci_in(&p, 0xCFC, 2), u32(0x0005))
	pci_out(&p, 0xCFC, 2, 0)
	testing.expect_value(t, pci_in(&p, 0xCFC, 2), u32(0))
	pci_out(&p, 0xCFC, 2, 0xFFFA)
	testing.expect_value(t, pci_in(&p, 0xCFC, 2), u32(0))
}

@(test)
pci_test_amd_status_register_w1c :: proc(t: ^testing.T) {
	p: Pci
	pci_init(&p)

	p.functions[PCI_HOST_FUNCTION_INDEX].cfg[0x07] |= 0x78
	pci_out(&p, 0xCF8, 4, 0x8000_0004)
	testing.expect_value(t, pci_in(&p, 0xCFE, 2), u32(0x7A00))
	pci_out(&p, 0xCFE, 2, 0x2000)
	testing.expect_value(t, pci_in(&p, 0xCFE, 2), u32(0x5A00))
	pci_out(&p, 0xCFE, 2, 0xFFFF)
	testing.expect_value(t, pci_in(&p, 0xCFE, 2), u32(0x0200))

	p.functions[PCI_ISA_FUNCTION_INDEX].cfg[0x07] |= 0x30
	pci_out(&p, 0xCF8, 4, 0x8000_3804)
	testing.expect_value(t, pci_in(&p, 0xCFE, 2), u32(0x3200))
	pci_out(&p, 0xCFE, 2, 0xFFFF)
	testing.expect_value(t, pci_in(&p, 0xCFE, 2), u32(0x0200))

	p.functions[PCI_IDE_FUNCTION_INDEX].cfg[0x07] |= 0x30
	pci_out(&p, 0xCF8, 4, 0x8000_3904)
	testing.expect_value(t, pci_in(&p, 0xCFE, 2), u32(0x3200))
	pci_out(&p, 0xCFE, 2, 0xFFFF)
	testing.expect_value(t, pci_in(&p, 0xCFE, 2), u32(0x0200))
}

@(test)
pci_test_static_pirq_routing_and_slot_swizzle :: proc(t: ^testing.T) {
	p: Pci
	pci_init(&p)

	expected := [4]u8{10, 11, 10, 11}
	for pirq in u8(0) ..< PCI_PIRQ_COUNT {
		irq, routed := pci_pirq_route(&p, pirq)
		testing.expect_value(t, irq, expected[pirq])
		testing.expect_value(t, routed, true)
	}
	_, routed := pci_pirq_route(&p, PCI_PIRQ_COUNT)
	testing.expect_value(t, routed, false)

	pirq, valid := pci_slot_pirq(2, 1)
	testing.expect_value(t, pirq, PCI_GSW_VGA_PIRQ)
	testing.expect_value(t, valid, true)
	_, valid = pci_slot_pirq(0, 1)
	testing.expect_value(t, valid, false)
	_, valid = pci_slot_pirq(2, 0)
	testing.expect_value(t, valid, false)
}

@(test)
pci_test_amd756_ide_bus_master_bar :: proc(t: ^testing.T) {
	p: Pci
	pci_init(&p)
	pci_out(&p, 0xCF8, 4, 0x8000_3920)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), AMD756_IDE_BMIBA_DEFAULT)
	base, valid := pci_ide_bus_master_io_base(&p)
	testing.expect_value(t, base, u16(0xCC00))
	testing.expect_value(t, valid, true)
	testing.expect_value(t, pci_ide_io_enabled(&p), false)
	testing.expect_value(t, pci_ide_bus_master_enabled(&p), false)

	pci_out(&p, 0xCFC, 4, 0xFFFF_FFFF)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0xFFFF_FFF1))
	// A BAR size probe must not destroy the programmed base.
	base, valid = pci_ide_bus_master_io_base(&p)
	testing.expect_value(t, base, u16(0xCC00))
	testing.expect_value(t, valid, true)

	pci_out(&p, 0xCFC, 4, 0x0000_E007)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0x0000_E001))
	base, valid = pci_ide_bus_master_io_base(&p)
	testing.expect_value(t, base, u16(0xE000))
	testing.expect_value(t, valid, true)
	pci_out(&p, 0xCF8, 4, 0x8000_3904)
	pci_out(&p, 0xCFC, 2, 0x0001)
	pci_out(&p, 0xCF8, 4, 0x8000_3920)
	offset, claimed := pci_ide_bus_master_decode(&p, 0xE00F, 1)
	testing.expect_value(t, offset, u8(0x0F))
	testing.expect_value(t, claimed, true)
	_, claimed = pci_ide_bus_master_decode(&p, 0xE00F, 2)
	testing.expect_value(t, claimed, false)

	pci_out(&p, 0xCF8, 4, 0x8000_3904)
	pci_out(&p, 0xCFC, 2, 0x0004)
	testing.expect_value(t, pci_ide_io_enabled(&p), false)
	testing.expect_value(t, pci_ide_bus_master_enabled(&p), true)
	_, claimed = pci_ide_bus_master_decode(&p, 0xE000, 1)
	testing.expect_value(t, claimed, false)
	pci_out(&p, 0xCFC, 2, 0x0001)
	testing.expect_value(t, pci_ide_bus_master_enabled(&p), false)
	_, claimed = pci_ide_bus_master_decode(&p, 0xE000, 1)
	testing.expect_value(t, claimed, true)
}

@(test)
pci_test_gsw_vga_identity_bars_and_persona :: proc(t: ^testing.T) {
	p: Pci
	pci_init(&p)
	pci_out(&p, 0xCF8, 4, 0x8000_1000)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0x0002_FFFE))
	pci_out(&p, 0xCF8, 4, 0x8000_1008)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4) >> 16, u32(0x0300))
	pci_out(&p, 0xCF8, 4, 0x8000_1004)
	testing.expect_value(t, pci_in(&p, 0xCFC, 2), u32(0x0006))
	pci_out(&p, 0xCFC, 2, 0x0007)
	testing.expect_value(t, pci_in(&p, 0xCFC, 2), u32(0x0007))

	pci_out(&p, 0xCF8, 4, 0x8000_1010)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), GSW_VGA_CONTROL_BAR)
	pci_out(&p, 0xCFC, 4, 0xFFFF_FFFF)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0xFFFF_F000))
	pci_out(&p, 0xCFC, 4, 0xF234_5678)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0xF234_5000))

	pci_out(&p, 0xCF8, 4, 0x8000_1014)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), GSW_VGA_FRAMEBUFFER_BAR)
	pci_out(&p, 0xCFC, 4, 0xFFFF_FFFF)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0xFE00_0000))
	pci_out(&p, 0xCFC, 4, 0xD123_4567)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0xD000_0000))

	pci_out(&p, 0xCF8, 4, 0x8000_1040)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), GSW_VGA_CAPABILITY_SIGNATURE)
	pci_out(&p, 0xCF8, 4, 0x8000_1048)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(150) << 16 | 32)
	pci_out(&p, 0xCF8, 4, 0x8000_104C)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4) & 0x00FF_FFFF, u32(0x0003_0104))
}

@(test)
pci_test_identity_and_reserved_fields_are_read_only :: proc(t: ^testing.T) {
	p: Pci
	pci_init(&p)

	pci_out(&p, 0xCF8, 4, 0x8000_0000)
	pci_out(&p, 0xCFC, 4, 0)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0x7006_1022))
	pci_out(&p, 0xCF8, 4, 0x8000_0008)
	pci_out(&p, 0xCFC, 4, 0xFFFF_FFFF)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0x0600_0021))
	for offset := u32(0x10); offset <= 0x14; offset += 4 {
		pci_out(&p, 0xCF8, 4, 0x8000_0000 | offset)
		pci_out(&p, 0xCFC, 4, 0xFFFF_FFFF)
		testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0))
	}
	pci_out(&p, 0xCF8, 4, 0x8000_003C)
	pci_out(&p, 0xCFC, 4, 0xFFFF_FFFF)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0))

	pci_out(&p, 0xCF8, 4, 0x8000_3800)
	pci_out(&p, 0xCFC, 4, 0)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0x7408_1022))
}

@(test)
pci_test_config_address_hardwired_bits :: proc(t: ^testing.T) {
	p: Pci
	pci_init(&p)
	pci_out(&p, 0xCF8, 4, 0xFFFF_FFFF)
	testing.expect_value(t, pci_in(&p, 0xCF8, 4), u32(0x80FF_FFFC))
}

@(test)
pci_test_amd751_exposes_only_configuration_mechanism_1 :: proc(t: ^testing.T) {
	p: Pci
	pci_init(&p)
	pci_out(&p, 0xCF8, 4, 0x8000_3800)
	pci_out(&p, 0xCF8, 1, 0xF0)
	pci_out(&p, 0xCFA, 1, 0)
	testing.expect_value(t, pci_in(&p, 0xCF8, 4), u32(0x8000_3800))
	testing.expect_value(t, pci_in(&p, 0xCF8, 1), u32(0xFF))
	testing.expect_value(t, pci_in(&p, 0xCFA, 1), u32(0xFF))
	testing.expect_value(t, pci_in(&p, 0xC000, 4), u32(0xFFFF_FFFF))
}

@(test)
pci_test_config_data_access_does_not_wrap :: proc(t: ^testing.T) {
	p: Pci
	pci_init(&p)
	pci_out(&p, 0xCF8, 4, 0x8000_00FC)
	pci_out(&p, 0xCFF, 2, 0xABCD)
	testing.expect_value(t, pci_in(&p, 0xCFF, 1), u32(0))
	testing.expect_value(t, pci_in(&p, 0xCFF, 2), u32(0xFFFF))
	pci_out(&p, 0xCF8, 4, 0x8000_0000)
	testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0x7006_1022))
}

@(test)
pci_test_config_data_widths_are_little_endian :: proc(t: ^testing.T) {
	p: Pci
	pci_init(&p)
	pci_out(&p, 0xCF8, 4, 0x8000_0000)
	testing.expect_value(t, pci_in(&p, 0xCFC, 1), u32(0x22))
	testing.expect_value(t, pci_in(&p, 0xCFD, 1), u32(0x10))
	testing.expect_value(t, pci_in(&p, 0xCFE, 2), u32(0x7006))
}

@(test)
pci_test_config_data_rejects_unaligned_word_access :: proc(t: ^testing.T) {
	p: Pci
	pci_init(&p)
	pci_out(&p, 0xCF8, 4, 0x8000_000C)
	before := pci_in(&p, 0xCFD, 1)
	pci_out(&p, 0xCFD, 2, 0xAA55)
	testing.expect_value(t, pci_in(&p, 0xCFD, 1), before)
	testing.expect_value(t, pci_in(&p, 0xCFD, 2), u32(0xFFFF))
}

@(test)
pci_test_absent_functions_and_synthetic_chipset :: proc(t: ^testing.T) {
	p: Pci
	pci_init(&p)
	addresses := [?]u32 {
		0x8000_1800, // former synthetic GSW chipset at 00:03.0
		0x8000_3A00, // omitted AMD-756 USB at 00:07.2
		0x8000_3B00, // omitted AMD-756 PM at 00:07.3
		0x8000_2000, // absent device 4
	}
	for address in addresses {
		pci_out(&p, 0xCF8, 4, address)
		testing.expect_value(t, pci_in(&p, 0xCFC, 4), u32(0xFFFF_FFFF))
	}
}
