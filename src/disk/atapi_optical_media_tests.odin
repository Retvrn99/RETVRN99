// SPDX-License-Identifier: GPL-3.0-only
package disk

import opticalmedia "../opticalmedia"
import "core:testing"

Atapi_Optical_Cdda_Sink :: struct {
	frames: int,
}

atapi_optical_fake_cdda :: proc(ctx: rawptr, _: []u8) {
	(^Atapi_Optical_Cdda_Sink)(ctx).frames += 1
}

atapi_optical_fake_data :: proc() -> opticalmedia.Optical_Media_Fake {
	return {
		observation = {
			present = true,
			media_class = .Compact_Disc,
			total_sectors = 8,
			track_count = 1,
			tracks = {0 = {number = 1, mode = .Mode1_2048, sector_count = 8}},
		},
	}
}

@(test)
atapi_optical_media_test_fake_sense_is_presented_to_guest :: proc(t: ^testing.T) {
	fake := atapi_optical_fake_data()
	fake.packet_result = {
		status = .Check_Condition,
		sense = {key = 0x02, asc = 0x3A, ascq = 0x01},
	}
	a: Atapi
	atapi_init(&a)
	testing.expect(
		t,
		opticalmedia.optical_media_attach_adapter(
			&a.media,
			opticalmedia.optical_media_fake_adapters(&fake, true),
		),
	)
	defer atapi_eject(&a)
	packet: [ATAPI_PACKET_BYTES]u8
	atapi_test_packet(&a, packet, 0)
	testing.expect_value(t, fake.packet_calls, u64(1))
	testing.expect(t, atapi_test_inb(&a, 0x177) & ATAPI_STATUS_ERR != 0)
	testing.expect_value(t, a.sense_key, u8(0x02))
	testing.expect_value(t, a.sense_asc, u8(0x3A))
	testing.expect_value(t, a.sense_ascq, u8(0x01))
}

@(test)
atapi_optical_media_test_fake_pio_and_bmide_reads_match :: proc(t: ^testing.T) {
	fake := atapi_optical_fake_data()
	data := make([]u8, 8 * DISC_DATA_SECTOR_SIZE, context.temp_allocator)
	for &byte, index in data {byte = u8(index * 7 + 3)}
	fake.data_sectors = data

	pio: Atapi
	atapi_init(&pio)
	testing.expect(
		t,
		opticalmedia.optical_media_attach_adapter(
			&pio.media,
			opticalmedia.optical_media_fake_adapters(&fake),
		),
	)
	defer atapi_eject(&pio)
	packet: [ATAPI_PACKET_BYTES]u8
	packet[0], packet[5], packet[8] = 0x28, 3, 1
	atapi_test_packet(&pio, packet)
	pio_data: [DISC_DATA_SECTOR_SIZE]u8
	atapi_test_read(&pio, pio_data[:])

	dma: Atapi
	atapi_init(&dma)
	testing.expect(
		t,
		opticalmedia.optical_media_attach_adapter(
			&dma.media,
			opticalmedia.optical_media_fake_adapters(&fake),
		),
	)
	defer atapi_eject(&dma)
	atapi_test_outb(&dma, 0x171, 1)
	atapi_test_packet(&dma, packet)
	request, pending := atapi_bmide_request(&dma)
	testing.expect(t, pending)
	testing.expect(
		t,
		request.device.begin(request.device.ctx, 1, .Device_To_Memory, DISC_DATA_SECTOR_SIZE),
	)
	dma_data: [DISC_DATA_SECTOR_SIZE]u8
	testing.expect(t, request.device.read(request.device.ctx, 1, 0, dma_data[:]))
	testing.expect(t, request.device.commit(request.device.ctx, 1))
	testing.expect_value(t, dma_data, pio_data)
}

@(test)
atapi_optical_media_test_fake_cdda_obeys_frame_deadlines :: proc(t: ^testing.T) {
	fake := atapi_optical_fake_data()
	fake.observation.tracks[0].mode = .Audio_2352
	fake.audio_frames = make([]u8, 8 * DISC_RAW_SECTOR_SIZE, context.temp_allocator)
	sink: Atapi_Optical_Cdda_Sink
	a: Atapi
	atapi_init(&a)
	testing.expect(
		t,
		opticalmedia.optical_media_attach_adapter(
			&a.media,
			opticalmedia.optical_media_fake_adapters(&fake),
		),
	)
	defer atapi_eject(&a)
	atapi_set_cdda_output(&a, &sink, atapi_optical_fake_cdda)
	play: [ATAPI_PACKET_BYTES]u8
	play[0], play[5], play[8] = 0x45, 1, 2
	atapi_test_packet(&a, play, 0)
	deadline, pending := atapi_next_deadline(&a)
	testing.expect(t, pending)
	atapi_advance_to(&a, deadline - 1)
	testing.expect_value(t, sink.frames, 0)
	atapi_advance_to(&a, deadline)
	testing.expect_value(t, sink.frames, 1)
	second: u64
	second, pending = atapi_next_deadline(&a)
	testing.expect(t, pending)
	testing.expect_value(t, second - deadline, ATAPI_CDDA_FRAME_TICKS)
}
