// SPDX-License-Identifier: GPL-3.0-only
package disk

BLOCK_FAILURE_DIAGNOSTIC_BYTES :: 192

Block_Operation :: enum u8 {
	None,
	Read,
	Write,
	Flush,
}

Block_Failure_Source :: enum u8 {
	None,
	Adapter_Validation,
	Transport,
	Helper,
	Protocol,
}

Block_Failure :: struct {
	valid:             bool,
	operation:         Block_Operation,
	source:            Block_Failure_Source,
	lba:               u64,
	byte_count:        u32,
	code:              u32,
	sequence:          u64,
	durable_sequence:  u64,
	diagnostic:        [BLOCK_FAILURE_DIAGNOSTIC_BYTES]u8,
	diagnostic_length: u16,
}

block_failure_make :: proc(
	operation: Block_Operation,
	source: Block_Failure_Source,
	lba: u64,
	byte_count, code: u32,
	sequence, durable_sequence: u64,
	diagnostic: string,
) -> Block_Failure {
	result := Block_Failure {
		valid            = true,
		operation        = operation,
		source           = source,
		lba              = lba,
		byte_count       = byte_count,
		code             = code,
		sequence         = sequence,
		durable_sequence = durable_sequence,
	}
	length := min(len(diagnostic), len(result.diagnostic))
	copy(result.diagnostic[:length], transmute([]u8)diagnostic[:length])
	result.diagnostic_length = u16(length)
	return result
}

block_failure_text :: proc(failure: ^Block_Failure) -> string {
	if failure == nil {return ""}
	length := min(int(failure.diagnostic_length), len(failure.diagnostic))
	return transmute(string)failure.diagnostic[:length]
}

// Block device interface, 512-byte sectors
Block_Device :: struct {
	ctx:          rawptr,
	sector_count: u64,
	read:         proc(ctx: rawptr, lba: u64, buf: []u8) -> bool, // buf = n*512
	write:        proc(ctx: rawptr, lba: u64, buf: []u8) -> bool,
	flush:        proc(ctx: rawptr) -> bool,
	failure:      proc(ctx: rawptr) -> Block_Failure,
}
