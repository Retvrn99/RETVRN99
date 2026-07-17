// SPDX-License-Identifier: GPL-3.0-only
package fat32session

import fat32image "../fat32image"
import "core:hash"
import "core:os"
import "core:testing"

@(test)
protocol_test_rejects_bad_version_and_bounded_length :: proc(t: ^testing.T) {
	reader, writer, pipe_error := os.pipe()
	if !testing.expect_value(t, pipe_error, os.Error(nil)) {return}
	defer os.close(reader)
	defer os.close(writer)
	header: [PROTOCOL_HEADER_BYTES]u8
	put_u32le(header[:], 0, PROTOCOL_MAGIC)
	put_u16le(header[:], 4, PROTOCOL_VERSION + 1)
	put_u16le(header[:], 6, u16(Protocol_Kind.Validate))
	put_u64le(header[:], 16, 1)
	put_u32le(header[:], 12, hash.crc32(header[:]))
	testing.expect(t, protocol_write_exact(writer, header[:]))
	_, version_error := protocol_read_frame(reader, context.allocator)
	testing.expect_value(t, version_error.code, Error_Code.Protocol_Mismatch)

	reader2, writer2, pipe_error2 := os.pipe()
	if !testing.expect_value(t, pipe_error2, os.Error(nil)) {return}
	defer os.close(reader2)
	defer os.close(writer2)
	header = {}
	put_u32le(header[:], 0, PROTOCOL_MAGIC)
	put_u16le(header[:], 4, PROTOCOL_VERSION)
	put_u16le(header[:], 6, u16(Protocol_Kind.Write))
	put_u32le(header[:], 8, PROTOCOL_MAX_PAYLOAD + 1)
	put_u64le(header[:], 16, 1)
	put_u32le(header[:], 12, hash.crc32(header[:]))
	testing.expect(t, protocol_write_exact(writer2, header[:]))
	_, length_error := protocol_read_frame(reader2, context.allocator)
	testing.expect_value(t, length_error.code, Error_Code.Protocol_Malformed)
}

@(test)
protocol_test_image_info_roundtrip_preserves_korean_path :: proc(t: ^testing.T) {
	info := Image_Info {
		path                = "D:/이미지/윈도우 98.img",
		sector_count        = 41_943_040,
		partition_lba       = 63,
		partition_sectors   = 41_942_977,
		sectors_per_cluster = 32,
		reserved_sectors    = 32,
		marker_sector       = 94,
		sparse              = true,
		enrolled            = true,
		dirty               = true,
	}
	for index in 0 ..< len(info.image_id) {info.image_id[index] = u8(index + 1)}
	payload := protocol_image_info_encode(&info, context.allocator)
	defer delete(payload)
	decoded, ok := protocol_image_info_decode(payload, context.allocator)
	if !testing.expect(t, ok) {return}
	defer fat32image.info_destroy(&decoded)
	testing.expect_value(t, decoded.path, info.path)
	testing.expect_value(t, decoded.image_id, info.image_id)
	testing.expect_value(t, decoded.sector_count, info.sector_count)
	testing.expect(t, decoded.sparse && decoded.enrolled && decoded.dirty)
}

@(test)
protocol_test_rejects_invalid_error_domains :: proc(t: ^testing.T) {
	payload := protocol_error_encode(
		error_make(.Image_IO, true, .Retained, 11, 7, "test"),
		context.allocator,
	)
	defer delete(payload)

	put_u16le(payload, 0, u16(Error_Code.Name_Collision) + 1)
	testing.expect_value(
		t,
		protocol_error_decode(payload).code,
		Error_Code.Protocol_Malformed,
	)
	put_u16le(payload, 0, u16(Error_Code.Image_IO))
	payload[2] = 2
	testing.expect_value(
		t,
		protocol_error_decode(payload).code,
		Error_Code.Protocol_Malformed,
	)
	payload[2] = 1
	payload[3] = u8(Operation_Outcome.Uncertain) + 1
	testing.expect_value(
		t,
		protocol_error_decode(payload).code,
		Error_Code.Protocol_Malformed,
	)
}

@(test)
protocol_test_rejects_invalid_barrier_domains :: proc(t: ^testing.T) {
	payload := protocol_barrier_encode(
		Barrier_Result {
			sequence         = 9,
			durable_sequence = 8,
			materialization  = .Materialized,
		},
	)
	payload[16] = u8(Materialization.Pending) + 1
	_, decoded := protocol_barrier_decode(payload[:])
	testing.expect(t, !decoded)

	_, reason_valid := protocol_barrier_reason_decode(u8(Barrier_Reason.Clean_Close) + 1)
	_, mode_valid := protocol_close_mode_decode(u8(Close_Mode.Retain) + 1)
	testing.expect(t, !reason_valid)
	testing.expect(t, !mode_valid)
}
