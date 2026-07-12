// SPDX-License-Identifier: GPL-3.0-only
package fat32

import "core:fmt"
import "core:strings"
import "core:time"

ATTR_DIR: u8 : 0x10
ATTR_FILE: u8 : 0x20
ATTR_LFN: u8 : 0x0F

// UCS-2 char byte offsets inside a 32-byte LFN entry
@(private = "file")
LFN_OFFS :: [13]int{1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30}

// checksum over the 11-byte 8.3 name
lfn_checksum :: proc(short: [11]u8) -> u8 {
	sum := u8(0)
	for c in short {
		sum = ((sum & 1) << 7) + (sum >> 1) + c
	}
	return sum
}

// 8.3 name per child, in child order. Valid 8.3 names pass through first;
// the rest get a deterministic ~N tail bumped past every pass-through name
// and every earlier generated tail (a literal README~1.TXT later in the
// list must not collide with a generated README~1TXT).
dir_short_names :: proc(dir: ^Node, allocator := context.allocator) -> [][11]u8 {
	names := make([][11]u8, len(dir.children), allocator)
	for child, i in dir.children {
		if lfn_entry_count(child.name) == 0 {
			names[i] = pack_83(child.name)
		}
	}
	for child, i in dir.children {
		if lfn_entry_count(child.name) != 0 {
			names[i] = tail_name(child.name, names[:]) // own slot is still zeroed
		}
	}
	return names
}

// directory content for one cluster of the dir; out is zero padded
dir_cluster_data :: proc(a: ^Allocation, node: ^Node, cluster_index: u32, out: []u8) {
	full := build_dir_bytes(a, node, context.temp_allocator)
	for i in 0 ..< len(out) {
		out[i] = 0
	}
	start := int(cluster_index) * CLUSTER_BYTES
	if start < len(full) {
		copy(out, full[start:])
	}
}

@(private = "file")
build_dir_bytes :: proc(a: ^Allocation, node: ^Node, allocator := context.allocator) -> []u8 {
	buf := make([]u8, int(dir_size_bytes(node)), allocator)
	off := 0
	if node.parent != nil {
		dot := [11]u8{'.', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' '}
		dotdot := [11]u8{'.', '.', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' '}
		parent_cluster := node.parent.parent == nil ? 0 : node.parent.first_cluster
		put_short_entry(buf[off:], dot, ATTR_DIR, node.first_cluster, 0, node.mtime)
		off += 32
		put_short_entry(buf[off:], dotdot, ATTR_DIR, parent_cluster, 0, node.mtime)
		off += 32
	}
	shorts := dir_short_names(node, allocator)
	for child, i in node.children {
		nlfn := int(lfn_entry_count(child.name))
		if nlfn > 0 {
			csum := lfn_checksum(shorts[i])
			units := utf16_units(child.name, allocator)
			for s := nlfn; s >= 1; s -= 1 {
				put_lfn_entry(buf[off:], u8(s), s == nlfn, csum, units)
				off += 32
			}
		}
		attr := child.is_dir ? ATTR_DIR : ATTR_FILE
		size := child.is_dir ? u32(0) : u32(min(child.size, 0xFFFFFFFF))
		put_short_entry(buf[off:], shorts[i], attr, child.first_cluster, size, child.mtime)
		off += 32
	}
	return buf
}

@(private = "file")
put_short_entry :: proc(e: []u8, short: [11]u8, attr: u8, cluster: u32, size: u32, mtime: time.Time) {
	sh := short
	copy(e[:11], sh[:])
	e[11] = attr
	d, tm := fat_datetime(mtime)
	wr16(e, 14, tm) // creation = write time
	wr16(e, 16, d)
	wr16(e, 18, d) // last access date
	wr16(e, 20, u16(cluster >> 16))
	wr16(e, 22, tm)
	wr16(e, 24, d)
	wr16(e, 26, u16(cluster))
	wr32(e, 28, size)
}

@(private = "file")
put_lfn_entry :: proc(e: []u8, seq: u8, last: bool, csum: u8, units: []u16) {
	e[0] = seq | (last ? 0x40 : 0)
	e[11] = ATTR_LFN
	e[13] = csum
	base := int(seq - 1) * 13
	for off, i in LFN_OFFS {
		idx := base + i
		v: u16 = 0xFFFF
		if idx < len(units) {
			v = units[idx]
		} else if idx == len(units) {
			v = 0 // terminator when room remains
		}
		e[off] = u8(v)
		e[off + 1] = u8(v >> 8)
	}
}

@(private = "file")
utf16_units :: proc(s: string, allocator := context.allocator) -> []u16 {
	units := make([dynamic]u16, allocator)
	for r in s {
		if r > 0xFFFF {
			v := u32(r) - 0x10000
			append(&units, u16(0xD800 + (v >> 10)), u16(0xDC00 + (v & 0x3FF)))
		} else {
			append(&units, u16(r))
		}
	}
	return units[:]
}

// name is already valid 8.3: split and pad
@(private = "file")
pack_83 :: proc(name: string) -> (out: [11]u8) {
	for i in 0 ..< 11 {
		out[i] = ' '
	}
	base, ext := name, ""
	if dot := strings.last_index_byte(name, '.'); dot >= 0 {
		base, ext = name[:dot], name[dot + 1:]
	}
	copy(out[:8], base)
	copy(out[8:], ext)
	return
}

// generated short name: sanitized basis + ~N, N bumped past collisions
@(private = "file")
tail_name :: proc(name: string, used: [][11]u8) -> [11]u8 {
	base, blen, ext, elen := sanitize_83(name)
	for n := 1; ; n += 1 {
		cand: [11]u8
		for i in 0 ..< 11 {
			cand[i] = ' '
		}
		tail_buf: [8]u8
		tail := fmt.bprintf(tail_buf[:], "~%d", n)
		keep := min(blen, 8 - len(tail))
		if keep < 0 {
			keep = 0
		}
		copy(cand[:], base[:keep])
		copy(cand[keep:8], tail)
		copy(cand[8:], ext[:elen])
		collides := false
		for u in used {
			if u == cand {
				collides = true
				break
			}
		}
		if !collides {
			return cand
		}
	}
}

@(private = "file")
sanitize_83 :: proc(name: string) -> (base: [8]u8, blen: int, ext: [3]u8, elen: int) {
	bs, es := name, ""
	if dot := strings.last_index_byte(name, '.'); dot >= 0 {
		bs, es = name[:dot], name[dot + 1:]
	}
	for r in bs {
		if blen >= 8 {
			break
		}
		base[blen] = short_char(r)
		blen += 1
	}
	for r in es {
		if elen >= 3 {
			break
		}
		ext[elen] = short_char(r)
		elen += 1
	}
	return
}

// uppercase; anything not valid in 8.3 becomes '_'
@(private = "file")
short_char :: proc(r: rune) -> u8 {
	c := r
	if c >= 'a' && c <= 'z' {
		c -= 32
	}
	if c < 128 && short_char_ok(u8(c)) {
		return u8(c)
	}
	return '_'
}

@(private = "file")
short_char_ok :: proc(c: byte) -> bool {
	switch c {
	case 'A' ..= 'Z', '0' ..= '9':
		return true
	case '!', '#', '$', '%', '&', '\'', '(', ')', '-', '@', '^', '_', '`', '{', '}', '~':
		return true
	}
	return false
}

@(private = "file")
wr16 :: proc(b: []u8, off: int, v: u16) {
	b[off] = u8(v)
	b[off + 1] = u8(v >> 8)
}

@(private = "file")
wr32 :: proc(b: []u8, off: int, v: u32) {
	b[off] = u8(v)
	b[off + 1] = u8(v >> 8)
	b[off + 2] = u8(v >> 16)
	b[off + 3] = u8(v >> 24)
}

@(private = "file")
fat_datetime :: proc(t: time.Time) -> (date: u16, tm: u16) {
	y, mon, d := time.date(t)
	h, mi, s := time.clock_from_time(t)
	if y < 1980 {
		return 0x0021, 0 // 1980-01-01
	}
	if y > 2107 {
		y = 2107
	}
	date = u16((y - 1980) << 9 | int(mon) << 5 | d)
	tm = u16(h << 11 | mi << 5 | s / 2)
	return
}
