// SPDX-License-Identifier: GPL-3.0-only
package disk

// Interfaz de dispositivo de bloques, sectores de 512 bytes
Block_Device :: struct {
	ctx:          rawptr,
	sector_count: u64,
	read:         proc(ctx: rawptr, lba: u64, buf: []u8) -> bool, // buf = n*512
	write:        proc(ctx: rawptr, lba: u64, buf: []u8) -> bool,
}
