// SPDX-License-Identifier: GPL-3.0-only
package machine

import "core:testing"

// reads len(buf) bytes from the data port
fwcfg_test_read :: proc(f: ^Fwcfg, buf: []u8) {
	for i in 0 ..< len(buf) {
		buf[i] = u8(fwcfg_in(f, FWCFG_PORT_DATA, 1))
	}
}

fwcfg_get_be16 :: proc(b: []u8) -> u16 {
	return u16(b[0]) << 8 | u16(b[1])
}

fwcfg_get_be32 :: proc(b: []u8) -> u32 {
	return u32(b[0]) << 24 | u32(b[1]) << 16 | u32(b[2]) << 8 | u32(b[3])
}

fwcfg_get_le32 :: proc(b: []u8) -> u32 {
	v: u32
	for i in 0 ..< 4 { v |= u32(b[i]) << (8 * u32(i)) }
	return v
}

fwcfg_get_le64 :: proc(b: []u8) -> u64 {
	v: u64
	for i in 0 ..< 8 { v |= u64(b[i]) << (8 * u64(i)) }
	return v
}

@(test)
test_fwcfg_signature :: proc(t: ^testing.T) {
	f: Fwcfg
	fwcfg_init(&f, 64 * 1024 * 1024)
	defer fwcfg_destroy(&f)
	fwcfg_out(&f, FWCFG_PORT_SEL, 2, FWCFG_SIGNATURE)
	buf: [4]u8
	fwcfg_test_read(&f, buf[:])
	testing.expect_value(t, string(buf[:]), "QEMU")
}

@(test)
test_fwcfg_e820_via_file_dir :: proc(t: ^testing.T) {
	f: Fwcfg
	fwcfg_init(&f, 64 * 1024 * 1024)
	defer fwcfg_destroy(&f)

	// file directory: count u32 BE + 64-byte entries
	fwcfg_out(&f, FWCFG_PORT_SEL, 2, FWCFG_FILE_DIR)
	hdr: [4]u8
	fwcfg_test_read(&f, hdr[:])
	testing.expect_value(t, fwcfg_get_be32(hdr[:]), u32(1))

	entry: [64]u8
	fwcfg_test_read(&f, entry[:])
	size := fwcfg_get_be32(entry[0:4])
	sel := fwcfg_get_be16(entry[4:6])
	name := entry[8:]
	n := 0
	for n < len(name) && name[n] != 0 { n += 1 }
	testing.expect_value(t, string(name[:n]), "etc/e820")
	testing.expect_value(t, size, u32(40))
	testing.expect_value(t, sel, u16(FWCFG_E820))

	// select etc/e820 and verify the second entry
	fwcfg_out(&f, FWCFG_PORT_SEL, 2, u32(sel))
	e820: [40]u8
	fwcfg_test_read(&f, e820[:])
	testing.expect_value(t, fwcfg_get_le64(e820[20:28]), u64(0x100000))
	testing.expect_value(t, fwcfg_get_le64(e820[28:36]), u64(63 * 1024 * 1024))
	testing.expect_value(t, fwcfg_get_le32(e820[36:40]), u32(1))
}

@(test)
test_fwcfg_unknown_selector :: proc(t: ^testing.T) {
	f: Fwcfg
	fwcfg_init(&f, 64 * 1024 * 1024)
	defer fwcfg_destroy(&f)
	fwcfg_out(&f, FWCFG_PORT_SEL, 2, 0x1234)
	testing.expect_value(t, fwcfg_in(&f, FWCFG_PORT_DATA, 1), u32(0))
}
