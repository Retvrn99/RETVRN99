// SPDX-License-Identifier: GPL-3.0-only
package machine

PIT_HZ :: 1_193_182

Pit_Channel :: struct {
	reload:   u32, // 0 significa 65536
	count:    u32,
	latched:  bool,
	latch:    u16,
	rw_mode:  u8, // 1=lo, 2=hi, 3=lo/hi
	rw_phase: bool, // false=lo siguiente
	ns_acc:   u64,
}

Pit :: struct { ch: [3]Pit_Channel }

pit_reload :: proc(c: ^Pit_Channel) -> u32 { return c.reload == 0 ? 65536 : c.reload }

pit_out :: proc(p: ^Pit, port: u16, v: u8) {
	switch port {
	case 0x43:
		ch := (v >> 6) & 3
		if ch == 3 { return } // read-back: ignorado en M1
		rw := (v >> 4) & 3
		c := &p.ch[ch]
		if rw == 0 { c.latch = u16(c.count); c.latched = true; return }
		c.rw_mode = rw; c.rw_phase = false
	case 0x40, 0x41, 0x42:
		c := &p.ch[port - 0x40]
		switch c.rw_mode {
		case 1: c.reload = (c.reload & 0xFF00) | u32(v)
		case 2: c.reload = (c.reload & 0x00FF) | u32(v) << 8
		case 3:
			if !c.rw_phase { c.reload = (c.reload & 0xFF00) | u32(v) } else { c.reload = (c.reload & 0x00FF) | u32(v) << 8 }
			c.rw_phase = !c.rw_phase
			if c.rw_phase { return }
		}
		c.count = pit_reload(c)
	}
}

pit_in :: proc(p: ^Pit, port: u16) -> u8 {
	if port < 0x40 || port > 0x42 { return 0xFF }
	c := &p.ch[port - 0x40]
	v := c.latched ? c.latch : u16(c.count)
	if c.rw_mode == 2 { return u8(v >> 8) }
	if !c.rw_phase { c.rw_phase = true; return u8(v) }
	c.rw_phase = false; c.latched = false
	return u8(v >> 8)
}

// avanza el reloj; devuelve nº de disparos de IRQ0
pit_advance :: proc(p: ^Pit, ns: u64) -> int {
	c := &p.ch[0]
	c.ns_acc += ns
	ticks := c.ns_acc * PIT_HZ / 1_000_000_000
	c.ns_acc -= ticks * 1_000_000_000 / PIT_HZ
	fires := 0
	rl := u64(pit_reload(c))
	if ticks >= u64(c.count) {
		rem := ticks - u64(c.count)
		fires = 1 + int(rem / rl)
		c.count = u32(rl - rem % rl)
	} else {
		c.count -= u32(ticks)
	}
	return fires
}
