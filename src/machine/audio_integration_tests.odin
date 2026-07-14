// SPDX-License-Identifier: GPL-3.0-only
package machine

import sound "../audio"
import disk "../disk"
import "core:testing"

machine_test_audio_timing_init :: proc(m: ^Machine) -> bool {
	if !sound.audio_mixer_init(&m.audio) {return false}
	pit_init(&m.pit)
	cmos_init(&m.cmos, 64 * 1024 * 1024)
	i8042_init(&m.kbd, nil, nil)
	uart_init_com1(&m.serial1)
	uart_init_com2(&m.serial2)
	lpt_init_lpt1(&m.parallel1)
	lpt_init_lpt2(&m.parallel2)
	disk.atapi_init(&m.atapi)
	disk.bmide_init(&m.bmide)
	m.vga.timing.elapsed_ns = ~u64(0)
	pit_out(&m.pit, 0x43, 0xB6)
	pit_out(&m.pit, 0x42, 0xA9)
	pit_out(&m.pit, 0x42, 0x04)
	pit_port61_write(&m.pit, 0x03)
	pit_clear_channel2_transitions(&m.pit)
	_ = sound.audio_mixer_set_speaker_state(
		&m.audio,
		0,
		true,
		pit_channel_out(&m.pit, 2),
	)
	return true
}

@(test)
test_machine_master_deadline_partition_preserves_speaker_audio :: proc(t: ^testing.T) {
	coarse := new(Machine)
	partitioned := new(Machine)
	defer free(coarse)
	defer free(partitioned)
	if !testing.expect(t, machine_test_audio_timing_init(coarse)) {return}
	if !testing.expect(t, machine_test_audio_timing_init(partitioned)) {return}

	coarse_sink, partitioned_sink: sound.Audio_Offline
	sound.audio_offline_init(&coarse_sink, machine_audio_output(coarse))
	sound.audio_offline_init(&partitioned_sink, machine_audio_output(partitioned))
	machine_advance_time_ns(coarse, 100_000_000)
	for _ in 0 ..< 100 {machine_advance_time_ns(partitioned, 1_000_000)}
	sound.audio_offline_consume(&coarse_sink, 4_800)
	sound.audio_offline_consume(&partitioned_sink, 4_800)

	coarse_result := sound.audio_offline_snapshot(&coarse_sink)
	partitioned_result := sound.audio_offline_snapshot(&partitioned_sink)
	testing.expect_value(t, master_timeline_now(coarse.timeline), master_timeline_now(partitioned.timeline))
	testing.expect_value(t, coarse.active_ns, partitioned.active_ns)
	testing.expect_value(t, coarse_result, partitioned_result)
	testing.expect(t, coarse_result.non_silent_frames > 0)
}
