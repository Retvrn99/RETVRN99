// SPDX-License-Identifier: GPL-3.0-only
package machine

import sound "../audio"
import hv "../hv"
import "core:log"
import "core:testing"
import "core:time"

legacy_audio_test_out :: proc(m: ^Machine, port: u16, value: u8) -> bool {
	return machine_io_write(m, port, 1, u32(value))
}

legacy_audio_test_in :: proc(m: ^Machine, port: u16) -> u8 {
	value, _ := machine_io_read(m, port, 1)
	return u8(value)
}

@(test)
test_machine_sb16_dma_irq5_and_opl_timer_share_guest_audio_clock :: proc(t: ^testing.T) {
	if !hv.available() {
		log.warn("WHPX not available")
		return
	}
	testing.set_fail_timeout(t, 15 * time.Second)
	m := new(Machine)
	defer free(m)
	if !testing.expect(t, machine_init(m, 64 * 1024 * 1024)) {return}
	defer machine_destroy(m)

	// DSP reset/version probe through the installed 220h-22Fh bus handler.
	testing.expect(t, legacy_audio_test_out(m, 0x226, 1))
	testing.expect(t, legacy_audio_test_out(m, 0x226, 0))
	machine_advance_time_ns(m, 100_000)
	testing.expect_value(t, legacy_audio_test_in(m, 0x22E), u8(0x80))
	testing.expect_value(t, legacy_audio_test_in(m, 0x22A), u8(0xAA))
	testing.expect(t, legacy_audio_test_out(m, 0x22C, 0xE1))
	testing.expect_value(t, legacy_audio_test_in(m, 0x22A), u8(4))
	testing.expect_value(t, legacy_audio_test_in(m, 0x22A), u8(5))

	// Standard AdLib timer-1 detection through 388h/389h.
	testing.expect(t, legacy_audio_test_out(m, 0x388, 0x02))
	testing.expect(t, legacy_audio_test_out(m, 0x389, 0xFF))
	testing.expect(t, legacy_audio_test_out(m, 0x388, 0x04))
	testing.expect(t, legacy_audio_test_out(m, 0x389, 0x01))
	machine_advance_time_ns(m, 80_000)
	testing.expect_value(t, legacy_audio_test_in(m, 0x388), u8(0xC0))

	// Sound Blaster FM aliases expose both OPL3 address banks.
	testing.expect(t, legacy_audio_test_out(m, 0x220, 0x04))
	testing.expect(t, legacy_audio_test_out(m, 0x221, 0x80))
	testing.expect_value(t, legacy_audio_test_in(m, 0x220), u8(0))
	testing.expect(t, legacy_audio_test_out(m, 0x220, 0x02))
	testing.expect(t, legacy_audio_test_out(m, 0x221, 0xFF))
	testing.expect(t, legacy_audio_test_out(m, 0x220, 0x04))
	testing.expect(t, legacy_audio_test_out(m, 0x221, 0x01))
	machine_advance_time_ns(m, 80_000)
	testing.expect_value(t, legacy_audio_test_in(m, 0x220), u8(0xC0))
	testing.expect(t, legacy_audio_test_out(m, 0x222, 0x05))
	testing.expect(t, legacy_audio_test_out(m, 0x223, 0x01))
	opl3_hash_before := sound.gsw_sound_observation(&m.gsw_sound).opl3_register_fnv1a64
	testing.expect(t, legacy_audio_test_out(m, 0x222, 0x20))
	testing.expect(t, legacy_audio_test_out(m, 0x223, 0x55))
	testing.expect(
		t,
		sound.gsw_sound_observation(&m.gsw_sound).opl3_register_fnv1a64 != opl3_hash_before,
	)

	// DMA1, single-transfer, device reads memory. Channel 4 is the cascade.
	m.vm.ram[0x2000] = 0x00
	m.vm.ram[0x2001] = 0xFF
	testing.expect(t, legacy_audio_test_out(m, 0xD6, 0xC0))
	testing.expect(t, legacy_audio_test_out(m, 0xD4, 0x00))
	testing.expect(t, legacy_audio_test_out(m, 0x0A, 0x05))
	testing.expect(t, legacy_audio_test_out(m, 0x0C, 0x00))
	testing.expect(t, legacy_audio_test_out(m, 0x0B, 0x49))
	testing.expect(t, legacy_audio_test_out(m, 0x02, 0x00))
	testing.expect(t, legacy_audio_test_out(m, 0x02, 0x20))
	testing.expect(t, legacy_audio_test_out(m, 0x03, 0x01))
	testing.expect(t, legacy_audio_test_out(m, 0x03, 0x00))
	testing.expect(t, legacy_audio_test_out(m, 0x83, 0x00))
	testing.expect(t, legacy_audio_test_out(m, 0x0A, 0x01))
	offline: sound.Audio_Offline
	sound.audio_offline_init(&offline, machine_audio_output(m), true)
	offline.consumer.gain = sound.AUDIO_RAMP_FRAMES
	testing.expect(t, legacy_audio_test_out(m, 0x22C, 0x41))
	testing.expect(t, legacy_audio_test_out(m, 0x22C, 0xBB))
	testing.expect(t, legacy_audio_test_out(m, 0x22C, 0x80))
	testing.expect(t, legacy_audio_test_out(m, 0x22C, 0xC0))
	testing.expect(t, legacy_audio_test_out(m, 0x22C, 0x00))
	testing.expect(t, legacy_audio_test_out(m, 0x22C, 0x01))
	testing.expect(t, legacy_audio_test_out(m, 0x22C, 0x00))
	machine_advance_time_ns(m, 1_000_000)
	sound.audio_offline_consume(&offline, 48)
	testing.expect(t, sound.audio_offline_snapshot(&offline).non_silent_frames > 0)
	testing.expect_value(t, m.platform.dma.ch[1].transfer_cycles, u64(2))
	testing.expect(t, m.platform.pic.master.irr & 0x20 != 0)
	testing.expect(t, legacy_audio_test_out(m, 0x224, 0x82))
	testing.expect_value(t, legacy_audio_test_in(m, 0x225), u8(0x21))
	_ = legacy_audio_test_in(m, 0x22E)
	testing.expect_value(t, legacy_audio_test_in(m, 0x225), sound.CT1745_IRQ_IDENTITY)
}

@(test)
test_machine_sb16_16bit_dma5_word_channel_and_irq_ack :: proc(t: ^testing.T) {
	if !hv.available() {
		log.warn("WHPX not available")
		return
	}
	testing.set_fail_timeout(t, 15 * time.Second)
	m := new(Machine)
	defer free(m)
	if !testing.expect(t, machine_init(m, 64 * 1024 * 1024)) {return}
	defer machine_destroy(m)

	m.vm.ram[0x2200] = 0x00
	m.vm.ram[0x2201] = 0x80
	m.vm.ram[0x2202] = 0xFF
	m.vm.ram[0x2203] = 0x7F
	testing.expect(t, legacy_audio_test_out(m, 0xD8, 0))
	testing.expect(t, legacy_audio_test_out(m, 0xC4, 0x00))
	testing.expect(t, legacy_audio_test_out(m, 0xC4, 0x11))
	testing.expect(t, legacy_audio_test_out(m, 0xC6, 0x01))
	testing.expect(t, legacy_audio_test_out(m, 0xC6, 0x00))
	testing.expect(t, legacy_audio_test_out(m, 0x8B, 0x00))
	testing.expect(t, legacy_audio_test_out(m, 0xD6, 0x49))
	testing.expect(t, legacy_audio_test_out(m, 0xD4, 0x01))

	testing.expect(t, legacy_audio_test_out(m, 0x22C, 0x41))
	testing.expect(t, legacy_audio_test_out(m, 0x22C, 0xBB))
	testing.expect(t, legacy_audio_test_out(m, 0x22C, 0x80))
	testing.expect(t, legacy_audio_test_out(m, 0x22C, 0xB0))
	testing.expect(t, legacy_audio_test_out(m, 0x22C, 0x10))
	testing.expect(t, legacy_audio_test_out(m, 0x22C, 0x01))
	testing.expect(t, legacy_audio_test_out(m, 0x22C, 0x00))
	machine_advance_time_ns(m, 1_000_000)

	testing.expect_value(t, m.platform.dma.ch[5].transfer_cycles, u64(2))
	testing.expect(t, m.platform.pic.master.irr & 0x20 != 0)
	testing.expect(t, legacy_audio_test_out(m, 0x224, 0x82))
	testing.expect_value(t, legacy_audio_test_in(m, 0x225), u8(0x22))
	_ = legacy_audio_test_in(m, 0x22F)
	testing.expect_value(t, legacy_audio_test_in(m, 0x225), sound.CT1745_IRQ_IDENTITY)
}
