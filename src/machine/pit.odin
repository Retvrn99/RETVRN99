// SPDX-License-Identifier: GPL-3.0-only
package machine

PIT_HZ :: 1_193_182

Pit_Channel :: struct {
	reload:   u32, // 0 means 65536
	count:    u32,
	latched:  bool,
	latch:    u16,
	rw_mode:  u8, // 1=lo, 2=hi, 3=lo/hi
	rw_phase: bool, // false=lo next
	mode:     u8, // counting mode from the control word
	gate:     bool, // ch2 only: port 0x61 bit 0
	out:      bool, // OUT pin level
	ns_acc:   u64,
}

Pit :: struct {
	ch:         [3]Pit_Channel,
	port61_low: u8, // last written speaker/gate bits
	refresh:    bool, // bit 4 toggles on each port 0x61 read
}

pit_reload :: proc(c: ^Pit_Channel) -> u32 { return c.reload == 0 ? 65536 : c.reload }

pit_out :: proc(p: ^Pit, port: u16, v: u8) {
	switch port {
	case 0x43:
		ch := (v >> 6) & 3
		if ch == 3 { return } // read-back: ignored in M1
		rw := (v >> 4) & 3
		c := &p.ch[ch]
		if rw == 0 { c.latch = u16(c.count); c.latched = true; return }
		c.rw_mode = rw; c.rw_phase = false
		c.mode = (v >> 1) & 7
		c.out = c.mode != 0 // mode 0: OUT goes low on control-word write
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
		if c.mode == 0 { c.out = false } // reload restarts, OUT low until terminal count
	}
}

pit_in :: proc(p: ^Pit, port: u16) -> u8 {
	if port < 0x40 || port > 0x42 { return 0xFF }
	c := &p.ch[port - 0x40]
	v := c.latched ? c.latch : u16(c.count)
	if c.rw_mode == 1 { c.latched = false; return u8(v) } // LSB-only: never alternates
	if c.rw_mode == 2 { c.latched = false; return u8(v >> 8) } // MSB-only: one read completes
	if !c.rw_phase { c.rw_phase = true; return u8(v) }
	c.rw_phase = false; c.latched = false
	return u8(v >> 8)
}

@(private = "file")
pit_channel_ticks :: proc(c: ^Pit_Channel, ns: u64) -> u64 {
	c.ns_acc += ns
	ticks := c.ns_acc * PIT_HZ / 1_000_000_000
	c.ns_acc -= ticks * 1_000_000_000 / PIT_HZ
	return ticks
}

// advances the clock; returns number of IRQ0 fires
pit_advance :: proc(p: ^Pit, ns: u64) -> int {
	// ns * PIT_HZ overflows u64 past ~4.3 h, so a single advance is capped at 1 h
	ns := min(ns, u64(3_600_000_000_000))
	c := &p.ch[0]
	ticks := pit_channel_ticks(c, ns)
	fires := 0
	rl := u64(pit_reload(c))
	if ticks >= u64(c.count) {
		rem := ticks - u64(c.count)
		fires = 1 + int(rem / rl)
		c.count = u32(rl - rem % rl)
	} else {
		c.count -= u32(ticks)
	}
	// channel 2 counts only while its gate is high
	c2 := &p.ch[2]
	if c2.gate {
		t2 := pit_channel_ticks(c2, ns)
		if t2 >= u64(c2.count) {
			if c2.mode == 0 { c2.out = true } // terminal count: OUT goes high
			rl2 := u64(pit_reload(c2))
			c2.count = u32(rl2 - (t2 - u64(c2.count)) % rl2)
		} else {
			c2.count -= u32(t2)
		}
	}
	return fires
}

// port 0x61: bit5 = ch2 OUT, bit4 = refresh toggle, bits 1/0 = speaker/gate
pit_port61_read :: proc(p: ^Pit) -> u8 {
	p.refresh = !p.refresh
	v := p.port61_low & 0x03
	if p.refresh { v |= 0x10 }
	if p.ch[2].out { v |= 0x20 }
	return v
}

pit_port61_write :: proc(p: ^Pit, v: u8) {
	c := &p.ch[2]
	rising := v & 1 != 0 && !c.gate
	p.port61_low = v & 0x03
	c.gate = v & 1 != 0
	if rising && c.mode == 0 { // gate 0->1 restarts the mode-0 count
		c.count = pit_reload(c)
		c.out = false
	}
}
