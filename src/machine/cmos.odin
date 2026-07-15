// SPDX-License-Identifier: GPL-3.0-only
package machine

// MC146818 algorithms adapted from IzarraVM commit
// d930de57acccbc6a70cda8cc5a603173bf23cd1c.

CMOS_NVRAM_SIZE :: 128
CMOS_SECOND_NS :: u64(1_000_000_000)
CMOS_UIP_NS :: u64(244_000)
CMOS_UIP_START_NS :: CMOS_SECOND_NS - CMOS_UIP_NS
CMOS_CHECKSUM_FIRST :: 0x10
CMOS_CHECKSUM_LAST :: 0x2D
CMOS_CHECKSUM_HIGH :: 0x2E
CMOS_CHECKSUM_LOW :: 0x2F
CMOS_CENTURY :: 0x32
CMOS_CENTURY_ALTERNATE :: 0x37
CMOS_BIOS_DISK_TRANSLATION :: 0x39
CMOS_BIOS_DISK_TRANSLATION_PRIMARY_MASK :: u8(0x03)
CMOS_BIOS_DISK_TRANSLATION_LARGE :: u8(0x02)

Cmos_Time :: struct {
	year:    u16,
	month:   u8,
	day:     u8,
	weekday: u8,
	hour:    u8,
	minute:  u8,
	second:  u8,
}

Cmos :: struct {
	ram:                        [CMOS_NVRAM_SIZE]u8,
	index:                      u8,
	nmi_disabled:               bool,
	time:                       Cmos_Time,
	second_phase_ns:            u64,
	periodic_phase:             u64,
	irq_edge_pending:           bool,
	last_import_checksum_valid: bool,
}

cmos_bcd :: proc(value: u8) -> u8 {
	return (value / 10) << 4 | value % 10
}

cmos_from_bcd :: proc(value: u8) -> u8 {
	return (value >> 4) * 10 + (value & 0x0F)
}

@(private = "file")
cmos_is_leap_year :: proc(year: u16) -> bool {
	return year % 4 == 0 && year % 100 != 0 || year % 400 == 0
}

@(private = "file")
cmos_days_in_month :: proc(year: u16, month: u8) -> u8 {
	days := [13]u8{0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}
	if month == 2 && cmos_is_leap_year(year) {return 29}
	if month < 1 || month > 12 {return 31}
	return days[month]
}

@(private = "file")
cmos_binary_mode :: proc(c: ^Cmos) -> bool {
	return c.ram[0x0B] & 0x04 != 0
}

@(private = "file")
cmos_24_hour_mode :: proc(c: ^Cmos) -> bool {
	return c.ram[0x0B] & 0x02 != 0
}

@(private = "file")
cmos_encode :: proc(c: ^Cmos, value: u8) -> u8 {
	return cmos_binary_mode(c) ? value : cmos_bcd(value)
}

@(private = "file")
cmos_decode :: proc(c: ^Cmos, value: u8) -> u8 {
	return cmos_binary_mode(c) ? value : cmos_from_bcd(value)
}

@(private = "file")
cmos_encode_hour :: proc(c: ^Cmos, hour: u8) -> u8 {
	if cmos_24_hour_mode(c) {return cmos_encode(c, hour)}
	pm := hour >= 12
	hour12 := hour % 12
	if hour12 == 0 {hour12 = 12}
	value := cmos_encode(c, hour12)
	if pm {value |= 0x80}
	return value
}

@(private = "file")
cmos_decode_hour :: proc(c: ^Cmos, value: u8) -> u8 {
	if cmos_24_hour_mode(c) {return min(cmos_decode(c, value & 0x7F), u8(23))}
	pm := value & 0x80 != 0
	hour := cmos_decode(c, value & 0x7F)
	if hour < 1 || hour > 12 {hour = 12}
	return hour % 12 + (pm ? 12 : 0)
}

@(private = "file")
cmos_write_time_registers :: proc(c: ^Cmos) {
	c.ram[0x00] = cmos_encode(c, c.time.second)
	c.ram[0x02] = cmos_encode(c, c.time.minute)
	c.ram[0x04] = cmos_encode_hour(c, c.time.hour)
	c.ram[0x06] = cmos_encode(c, c.time.weekday)
	c.ram[0x07] = cmos_encode(c, c.time.day)
	c.ram[0x08] = cmos_encode(c, c.time.month)
	c.ram[0x09] = cmos_encode(c, u8(c.time.year % 100))
	century := cmos_bcd(u8(c.time.year / 100))
	c.ram[CMOS_CENTURY] = century
	c.ram[CMOS_CENTURY_ALTERNATE] = century
}

@(private = "file")
cmos_clamp_day :: proc(c: ^Cmos) {
	c.time.day = min(max(c.time.day, u8(1)), cmos_days_in_month(c.time.year, c.time.month))
}

@(private = "file")
cmos_tick_seconds :: proc(c: ^Cmos, elapsed: u64) {
	if elapsed == 0 {return}
	second_total := u64(c.time.second) + elapsed
	c.time.second = u8(second_total % 60)
	minute_total := u64(c.time.minute) + second_total / 60
	c.time.minute = u8(minute_total % 60)
	hour_total := u64(c.time.hour) + minute_total / 60
	c.time.hour = u8(hour_total % 24)
	days := hour_total / 24
	if days > 0 {c.time.weekday = u8((u64(c.time.weekday - 1) + days) % 7 + 1)}
	for days > 0 {
		remaining := u64(cmos_days_in_month(c.time.year, c.time.month) - c.time.day + 1)
		if days < remaining {
			c.time.day += u8(days)
			days = 0
			break
		}
		days -= remaining
		c.time.day = 1
		if c.time.month == 12 {
			c.time.month = 1
			c.time.year += 1
		} else {
			c.time.month += 1
		}
	}
	cmos_write_time_registers(c)
}

@(private = "file")
cmos_periodic_rate_hz :: proc(c: ^Cmos) -> u64 {
	if c.ram[0x0A] & 0x70 != 0x20 {return 0}
	rate := c.ram[0x0A] & 0x0F
	switch rate {
	case 0:
		return 0
	case 1, 8:
		return 256
	case 2, 9:
		return 128
	}
	return u64(32_768) >> u64(rate - 1)
}

@(private = "file")
cmos_alarm_value_matches :: proc(c: ^Cmos, alarm, current: u8, hour: bool = false) -> bool {
	if alarm & 0xC0 == 0xC0 {return true}
	decoded := hour ? cmos_decode_hour(c, alarm) : cmos_decode(c, alarm)
	return decoded == current
}

@(private = "file")
cmos_alarm_matches :: proc(c: ^Cmos, hour, minute, second: u8) -> bool {
	return(
		cmos_alarm_value_matches(c, c.ram[0x01], second) &&
		cmos_alarm_value_matches(c, c.ram[0x03], minute) &&
		cmos_alarm_value_matches(c, c.ram[0x05], hour, true) \
	)
}

@(private = "file")
cmos_seconds_until_alarm :: proc(c: ^Cmos) -> (u64, bool) {
	now := u64(c.time.hour) * 3600 + u64(c.time.minute) * 60 + u64(c.time.second)
	for delta in u64(1) ..= 86_400 {
		then := (now + delta) % 86_400
		if cmos_alarm_matches(c, u8(then / 3600), u8(then / 60 % 60), u8(then % 60)) {
			return delta, true
		}
	}
	return 0, false
}

@(private = "file")
cmos_latch_flags :: proc(c: ^Cmos, flags: u8) {
	if flags == 0 {return}
	c.ram[0x0C] |= flags & 0x70
	cmos_recompute_irqf(c)
}

@(private = "file")
cmos_recompute_irqf :: proc(c: ^Cmos) {
	was_pending := c.ram[0x0C] & 0x80 != 0
	flags := c.ram[0x0C]
	enables := c.ram[0x0B]
	pending :=
		flags & 0x40 != 0 && enables & 0x40 != 0 ||
		flags & 0x20 != 0 && enables & 0x20 != 0 ||
		flags & 0x10 != 0 && enables & 0x10 != 0
	if pending {
		c.ram[0x0C] |= 0x80
		if !was_pending {c.irq_edge_pending = true}
	} else {
		c.ram[0x0C] &~= 0x80
		c.irq_edge_pending = false
	}
}

@(private = "file")
cmos_apply_machine_config :: proc(c: ^Cmos, ram_bytes: u64) {
	c.ram[0x10] = 0x40
	c.ram[0x12] = 0x00
	c.ram[0x14] = 0x2D
	c.ram[0x15] = 0x80
	c.ram[0x16] = 0x02
	ext_kb: u64
	if ram_bytes > 0x100000 {ext_kb = (ram_bytes - 0x100000) / 1024}
	ext_kb = min(ext_kb, u64(0x3C00))
	c.ram[0x17] = u8(ext_kb)
	c.ram[0x18] = u8(ext_kb >> 8)
	c.ram[0x30] = u8(ext_kb)
	c.ram[0x31] = u8(ext_kb >> 8)
	above16: u64
	if ram_bytes > 0x1000000 {above16 = (ram_bytes - 0x1000000) / 0x10000}
	above16 = min(above16, u64(0xFFFF))
	c.ram[0x34] = u8(above16)
	c.ram[0x35] = u8(above16 >> 8)
	c.ram[CMOS_BIOS_DISK_TRANSLATION] =
		(c.ram[CMOS_BIOS_DISK_TRANSLATION] & ~CMOS_BIOS_DISK_TRANSLATION_PRIMARY_MASK) |
		CMOS_BIOS_DISK_TRANSLATION_LARGE
}

cmos_checksum :: proc(c: ^Cmos) -> u16 {
	sum: u16
	for index in CMOS_CHECKSUM_FIRST ..= CMOS_CHECKSUM_LAST {sum += u16(c.ram[index])}
	return sum
}

cmos_checksum_valid :: proc(c: ^Cmos) -> bool {
	stored := u16(c.ram[CMOS_CHECKSUM_HIGH]) << 8 | u16(c.ram[CMOS_CHECKSUM_LOW])
	return stored == cmos_checksum(c)
}

cmos_refresh_checksum :: proc(c: ^Cmos) {
	sum := cmos_checksum(c)
	c.ram[CMOS_CHECKSUM_HIGH] = u8(sum >> 8)
	c.ram[CMOS_CHECKSUM_LOW] = u8(sum)
}

cmos_init :: proc(c: ^Cmos, ram_bytes: u64) {
	c^ = {
		time = {year = 2000, month = 1, day = 1, weekday = 7},
		last_import_checksum_valid = true,
	}
	c.ram[0x0A] = 0x26
	c.ram[0x0B] = 0x02
	c.ram[0x0D] = 0x80
	cmos_apply_machine_config(c, ram_bytes)
	cmos_write_time_registers(c)
	cmos_refresh_checksum(c)
}

cmos_nvram_export :: proc(c: ^Cmos) -> [CMOS_NVRAM_SIZE]u8 {
	return c.ram
}

cmos_nvram_import :: proc(c: ^Cmos, data: []u8, ram_bytes: u64) -> bool {
	if len(data) != CMOS_NVRAM_SIZE {return false}
	clock := c.time
	copy(c.ram[:], data)
	valid := cmos_checksum_valid(c)
	power_lost := c.ram[0x0D] & 0x80 == 0
	c.index = 0
	c.nmi_disabled = false
	c.second_phase_ns = 0
	c.periodic_phase = 0
	c.irq_edge_pending = false
	c.last_import_checksum_valid = valid
	c.time = clock
	c.ram[0x0A] = 0x26
	c.ram[0x0B] = 0x02
	c.ram[0x0C] = 0
	c.ram[0x0D] = 0x80
	c.ram[0x0E] = (!valid ? u8(0x40) : 0) | (power_lost ? u8(0x80) : 0)
	cmos_apply_machine_config(c, ram_bytes)
	cmos_write_time_registers(c)
	cmos_refresh_checksum(c)
	return true
}

cmos_set_datetime :: proc(c: ^Cmos, year: u16, month, day, weekday, hour, minute, second: u8) {
	c.time = {
		year    = max(year, u16(1)),
		month   = min(max(month, u8(1)), u8(12)),
		day     = max(day, u8(1)),
		weekday = min(max(weekday, u8(1)), u8(7)),
		hour    = min(hour, u8(23)),
		minute  = min(minute, u8(59)),
		second  = min(second, u8(59)),
	}
	cmos_clamp_day(c)
	c.second_phase_ns = 0
	cmos_write_time_registers(c)
}

cmos_set_time :: proc(c: ^Cmos, hour, minute, second: u8) {
	c.time.hour = min(hour, u8(23))
	c.time.minute = min(minute, u8(59))
	c.time.second = min(second, u8(59))
	c.second_phase_ns = 0
	cmos_write_time_registers(c)
}

cmos_advance :: proc(c: ^Cmos, elapsed_ns: u64) -> int {
	periodic_rate := cmos_periodic_rate_hz(c)
	if periodic_rate == 0 {
		c.periodic_phase = 0
	} else {
		total := u128(c.periodic_phase) + u128(elapsed_ns) * u128(periodic_rate)
		if total / u128(CMOS_SECOND_NS) > 0 {cmos_latch_flags(c, 0x40)}
		c.periodic_phase = u64(total % u128(CMOS_SECOND_NS))
	}
	second_total := u128(c.second_phase_ns) + u128(elapsed_ns)
	elapsed_seconds := u64(second_total / u128(CMOS_SECOND_NS))
	c.second_phase_ns = u64(second_total % u128(CMOS_SECOND_NS))
	if elapsed_seconds > 0 && c.ram[0x0B] & 0x80 == 0 {
		alarm_due := false
		if until, ok := cmos_seconds_until_alarm(c); ok {alarm_due = until <= elapsed_seconds}
		cmos_tick_seconds(c, elapsed_seconds)
		flags: u8 = 0x10
		if alarm_due {flags |= 0x20}
		cmos_latch_flags(c, flags)
	}
	if c.irq_edge_pending {c.irq_edge_pending = false; return 1}
	return 0
}

cmos_next_deadline_ns :: proc(c: ^Cmos) -> u64 {
	to_update := CMOS_SECOND_NS - c.second_phase_ns
	deadline := to_update
	if c.ram[0x0B] & 0x80 == 0 && c.second_phase_ns < CMOS_UIP_START_NS {
		deadline = min(deadline, CMOS_UIP_START_NS - c.second_phase_ns)
	}
	rate := cmos_periodic_rate_hz(c)
	if rate > 0 && c.ram[0x0C] & 0x40 == 0 {
		to_periodic := (CMOS_SECOND_NS - c.periodic_phase + rate - 1) / rate
		deadline = min(deadline, to_periodic)
	}
	return max(deadline, u64(1))
}

cmos_irq_pending :: proc(c: ^Cmos) -> bool {
	return c.ram[0x0C] & 0x80 != 0
}

cmos_nmi_is_disabled :: proc(c: ^Cmos) -> bool {
	return c.nmi_disabled
}

cmos_last_import_checksum_was_valid :: proc(c: ^Cmos) -> bool {
	return c.last_import_checksum_valid
}

@(private = "file")
cmos_uip :: proc(c: ^Cmos) -> bool {
	return c.ram[0x0B] & 0x80 == 0 && c.second_phase_ns >= CMOS_UIP_START_NS
}

@(private = "file")
cmos_write_register :: proc(c: ^Cmos, value: u8) {
	reg := c.index & 0x7F
	switch reg {
	case 0x00:
		c.time.second = min(cmos_decode(c, value), u8(59))
	case 0x02:
		c.time.minute = min(cmos_decode(c, value), u8(59))
	case 0x04:
		c.time.hour = cmos_decode_hour(c, value)
	case 0x06:
		c.time.weekday = min(max(cmos_decode(c, value), u8(1)), u8(7))
	case 0x07:
		c.time.day = max(cmos_decode(c, value), u8(1))
		cmos_clamp_day(c)
	case 0x08:
		c.time.month = min(max(cmos_decode(c, value), u8(1)), u8(12))
		cmos_clamp_day(c)
	case 0x09:
		century := c.time.year / 100 * 100
		c.time.year = century + u16(cmos_decode(c, value) % 100)
		cmos_clamp_day(c)
	case 0x01, 0x03, 0x05:
		c.ram[reg] = value
	case 0x0A:
		register_a := value & 0x7F
		if c.ram[0x0A] != register_a {c.periodic_phase = 0}
		c.ram[0x0A] = register_a
	case 0x0B:
		old_format := c.ram[0x0B] & 0x06
		c.ram[0x0B] = value
		if old_format != value & 0x06 {cmos_write_time_registers(c)}
		cmos_recompute_irqf(c)
	case 0x0C, 0x0D:
		return
	case CMOS_CENTURY, CMOS_CENTURY_ALTERNATE:
		century := cmos_from_bcd(value)
		c.time.year = u16(century) * 100 + c.time.year % 100
		c.ram[CMOS_CENTURY] = cmos_bcd(century)
		c.ram[CMOS_CENTURY_ALTERNATE] = c.ram[CMOS_CENTURY]
	case:
		c.ram[reg] = value
	}
	if reg <= 0x09 || reg == CMOS_CENTURY || reg == CMOS_CENTURY_ALTERNATE {
		cmos_write_time_registers(c)
	}
}

cmos_out :: proc(c: ^Cmos, port: u16, value: u8) {
	switch port {
	case 0x70:
		c.index = value & 0x7F
		c.nmi_disabled = value & 0x80 != 0
	case 0x71:
		cmos_write_register(c, value)
	}
}

cmos_in :: proc(c: ^Cmos, port: u16) -> u8 {
	if port == 0x70 {return c.index | (c.nmi_disabled ? 0x80 : 0)}
	if port != 0x71 {return 0xFF}
	if c.index == 0x0A {return c.ram[0x0A] & 0x7F | (cmos_uip(c) ? 0x80 : 0)}
	if c.index == 0x0C {
		value := c.ram[0x0C]
		c.ram[0x0C] = 0
		c.irq_edge_pending = false
		return value
	}
	return c.ram[c.index]
}
