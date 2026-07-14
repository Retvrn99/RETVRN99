// SPDX-License-Identifier: GPL-3.0-only
package machine

import "core:testing"

cmos_test_read :: proc(c: ^Cmos, reg: u8) -> u8 {
	cmos_out(c, 0x70, reg)
	return cmos_in(c, 0x71)
}

cmos_test_write :: proc(c: ^Cmos, reg, value: u8) {
	cmos_out(c, 0x70, reg)
	cmos_out(c, 0x71, value)
}

@(test)
test_cmos :: proc(t: ^testing.T) {
	c: Cmos
	cmos_init(&c, 64 * 1024 * 1024)
	cmos_set_time(&c, 23, 59, 45)
	cmos_out(&c, 0x70, 0x94)
	testing.expect_value(t, cmos_in(&c, 0x70), u8(0x94))
	testing.expect(t, cmos_nmi_is_disabled(&c))
	testing.expect_value(t, cmos_in(&c, 0x71), u8(0x2D))
	testing.expect_value(t, cmos_test_read(&c, 0x00), u8(0x45))
	testing.expect_value(t, cmos_test_read(&c, 0x04), u8(0x23))
}

@(test)
test_cmos_periodic :: proc(t: ^testing.T) {
	c: Cmos
	cmos_init(&c, 64 * 1024 * 1024)
	cmos_test_write(&c, 0x0B, 0x42)
	testing.expect_value(t, cmos_advance(&c, 1_953_125), 1)
	testing.expect_value(t, cmos_test_read(&c, 0x0C), u8(0xC0))
	testing.expect_value(t, cmos_test_read(&c, 0x0C), u8(0))
	testing.expect_value(t, cmos_advance(&c, 976_562), 0)
	testing.expect_value(t, cmos_advance(&c, 1), 1)
	testing.expect_value(t, cmos_test_read(&c, 0x0C), u8(0xC0))
}

@(test)
test_cmos_periodic_raw_flag_without_enable :: proc(t: ^testing.T) {
	c: Cmos
	cmos_init(&c, 64 * 1024 * 1024)
	testing.expect_value(t, cmos_advance(&c, 976_563), 0)
	testing.expect(t, !cmos_irq_pending(&c))
	testing.expect_value(t, cmos_test_read(&c, 0x0C), u8(0x40))

	cmos_advance(&c, 976_563)
	cmos_test_write(&c, 0x0B, 0x42)
	testing.expect_value(t, cmos_advance(&c, 0), 1)
	testing.expect(t, cmos_irq_pending(&c))
}

@(test)
test_cmos_memory_sizes :: proc(t: ^testing.T) {
	c: Cmos
	cmos_init(&c, 64 * 1024 * 1024)
	testing.expect_value(t, cmos_test_read(&c, 0x30), u8(0x00))
	testing.expect_value(t, cmos_test_read(&c, 0x31), u8(0x3C))
	testing.expect_value(t, cmos_test_read(&c, 0x34), u8(0x00))
	testing.expect_value(t, cmos_test_read(&c, 0x35), u8(0x03))
	c2: Cmos
	cmos_init(&c2, 16 * 1024 * 1024)
	testing.expect_value(t, cmos_test_read(&c2, 0x34), u8(0))
	testing.expect_value(t, cmos_test_read(&c2, 0x35), u8(0))
	c3: Cmos
	cmos_init(&c3, 256 * 1024 * 1024)
	testing.expect_value(t, cmos_test_read(&c3, 0x30), u8(0x00))
	testing.expect_value(t, cmos_test_read(&c3, 0x31), u8(0x3C))
	testing.expect_value(t, cmos_test_read(&c3, 0x34), u8(0x00))
	testing.expect_value(t, cmos_test_read(&c3, 0x35), u8(0x0F))
}

@(test)
test_cmos_register_b_recomputes_irqf_and_rearms_edge :: proc(t: ^testing.T) {
	c: Cmos
	cmos_init(&c, 64 * 1024 * 1024)
	cmos_test_write(&c, 0x0B, 0x42)
	testing.expect_value(t, cmos_advance(&c, 976_563), 1)
	testing.expect(t, cmos_irq_pending(&c))
	testing.expect(t, c.ram[0x0C] & 0x40 != 0)

	cmos_test_write(&c, 0x0B, 0x02)
	testing.expect(t, !cmos_irq_pending(&c))
	testing.expect(t, c.ram[0x0C] & 0x40 != 0)
	testing.expect_value(t, cmos_advance(&c, 0), 0)

	cmos_test_write(&c, 0x0B, 0x42)
	testing.expect(t, cmos_irq_pending(&c))
	testing.expect_value(t, cmos_advance(&c, 0), 1)
	testing.expect_value(t, cmos_test_read(&c, 0x0C), u8(0xC0))
}

@(test)
test_cmos_nvram_roundtrip :: proc(t: ^testing.T) {
	c: Cmos
	cmos_init(&c, 64 * 1024 * 1024)
	cmos_test_write(&c, 0x3D, 0x23)
	cmos_test_write(&c, 0x0B, 0x42)
	saved := cmos_nvram_export(&c)

	restored: Cmos
	cmos_init(&restored, 16 * 1024 * 1024)
	testing.expect(t, cmos_nvram_import(&restored, saved[:], 16 * 1024 * 1024))
	testing.expect(t, cmos_last_import_checksum_was_valid(&restored))
	testing.expect_value(t, cmos_test_read(&restored, 0x3D), u8(0x23))
	testing.expect_value(t, cmos_test_read(&restored, 0x0B), u8(0x02))
	testing.expect_value(t, cmos_test_read(&restored, 0x35), u8(0))
}

@(test)
test_cmos_nvram_rejects_wrong_size :: proc(t: ^testing.T) {
	c: Cmos
	cmos_init(&c, 64 * 1024 * 1024)
	testing.expect(t, !cmos_nvram_import(&c, []u8{1, 2, 3}, 64 * 1024 * 1024))
}

@(test)
test_cmos_calendar_leap_day_and_month_rollover :: proc(t: ^testing.T) {
	c: Cmos
	cmos_init(&c, 64 * 1024 * 1024)
	cmos_set_datetime(&c, 2024, 2, 28, 4, 23, 59, 59)
	_ = cmos_advance(&c, CMOS_SECOND_NS)
	testing.expect_value(t, c.time.year, u16(2024))
	testing.expect_value(t, c.time.month, u8(2))
	testing.expect_value(t, c.time.day, u8(29))
	testing.expect_value(t, c.time.weekday, u8(5))
	_ = cmos_advance(&c, 86_400 * CMOS_SECOND_NS)
	testing.expect_value(t, c.time.month, u8(3))
	testing.expect_value(t, c.time.day, u8(1))
	testing.expect_value(t, c.time.weekday, u8(6))
}

@(test)
test_cmos_uip_window_and_deadline :: proc(t: ^testing.T) {
	c: Cmos
	cmos_init(&c, 64 * 1024 * 1024)
	cmos_test_write(&c, 0x0A, 0x20)
	testing.expect_value(t, cmos_next_deadline_ns(&c), CMOS_UIP_START_NS)
	_ = cmos_advance(&c, CMOS_UIP_START_NS - 1)
	testing.expect(t, cmos_test_read(&c, 0x0A) & 0x80 == 0)
	testing.expect_value(t, cmos_next_deadline_ns(&c), u64(1))
	_ = cmos_advance(&c, 1)
	testing.expect(t, cmos_test_read(&c, 0x0A) & 0x80 != 0)
	testing.expect_value(t, cmos_next_deadline_ns(&c), CMOS_UIP_NS)
	_ = cmos_advance(&c, CMOS_UIP_NS)
	testing.expect(t, cmos_test_read(&c, 0x0A) & 0x80 == 0)
	testing.expect_value(t, c.time.second, u8(1))
}

@(test)
test_cmos_update_interrupt :: proc(t: ^testing.T) {
	c: Cmos
	cmos_init(&c, 64 * 1024 * 1024)
	cmos_set_time(&c, 12, 0, 0)
	cmos_test_write(&c, 0x0B, 0x12)
	testing.expect_value(t, cmos_advance(&c, CMOS_SECOND_NS), 1)
	testing.expect(t, cmos_irq_pending(&c))
	testing.expect_value(t, cmos_test_read(&c, 0x0C), u8(0xD0))
	testing.expect(t, !cmos_irq_pending(&c))
}

@(test)
test_cmos_alarm_interrupt_and_wildcards :: proc(t: ^testing.T) {
	c: Cmos
	cmos_init(&c, 64 * 1024 * 1024)
	cmos_set_datetime(&c, 2026, 7, 14, 3, 12, 34, 58)
	cmos_test_write(&c, 0x01, 0x00)
	cmos_test_write(&c, 0x03, 0x35)
	cmos_test_write(&c, 0x05, 0x12)
	cmos_test_write(&c, 0x0B, 0x22)
	testing.expect_value(t, cmos_advance(&c, 2 * CMOS_SECOND_NS), 1)
	testing.expect_value(t, cmos_test_read(&c, 0x0C), u8(0xF0))

	cmos_test_write(&c, 0x01, 0xC0)
	cmos_test_write(&c, 0x03, 0xC0)
	cmos_test_write(&c, 0x05, 0xC0)
	testing.expect_value(t, cmos_advance(&c, CMOS_SECOND_NS), 1)
	testing.expect_value(t, cmos_test_read(&c, 0x0C), u8(0xF0))
}

@(test)
test_cmos_set_bit_inhibits_clock_updates :: proc(t: ^testing.T) {
	c: Cmos
	cmos_init(&c, 64 * 1024 * 1024)
	cmos_set_time(&c, 1, 2, 3)
	cmos_test_write(&c, 0x0B, 0x82)
	_ = cmos_advance(&c, 2 * CMOS_SECOND_NS)
	testing.expect_value(t, c.time.second, u8(3))
	testing.expect(t, cmos_test_read(&c, 0x0A) & 0x80 == 0)
	cmos_test_write(&c, 0x0B, 0x02)
	_ = cmos_advance(&c, CMOS_SECOND_NS)
	testing.expect_value(t, c.time.second, u8(4))
}

@(test)
test_cmos_binary_and_twelve_hour_formats :: proc(t: ^testing.T) {
	c: Cmos
	cmos_init(&c, 64 * 1024 * 1024)
	cmos_set_time(&c, 23, 0, 0)
	testing.expect_value(t, cmos_test_read(&c, 0x04), u8(0x23))
	cmos_test_write(&c, 0x0B, 0x06)
	testing.expect_value(t, cmos_test_read(&c, 0x04), u8(23))
	cmos_test_write(&c, 0x0B, 0x04)
	testing.expect_value(t, cmos_test_read(&c, 0x04), u8(0x8B))
	cmos_test_write(&c, 0x04, 0x89)
	testing.expect_value(t, c.time.hour, u8(21))
	cmos_test_write(&c, 0x0B, 0x06)
	testing.expect_value(t, cmos_test_read(&c, 0x04), u8(21))
	cmos_set_time(&c, 0, 0, 0)
	cmos_test_write(&c, 0x0B, 0x04)
	testing.expect_value(t, cmos_test_read(&c, 0x04), u8(12))
}

@(test)
test_cmos_century_and_year_writes :: proc(t: ^testing.T) {
	c: Cmos
	cmos_init(&c, 64 * 1024 * 1024)
	cmos_set_datetime(&c, 1999, 12, 31, 6, 0, 0, 0)
	cmos_test_write(&c, CMOS_CENTURY, 0x20)
	testing.expect_value(t, c.time.year, u16(2099))
	testing.expect_value(t, cmos_test_read(&c, CMOS_CENTURY_ALTERNATE), u8(0x20))
	cmos_test_write(&c, 0x09, 0x01)
	testing.expect_value(t, c.time.year, u16(2001))
}

@(test)
test_cmos_checksum_validation_and_repair :: proc(t: ^testing.T) {
	c: Cmos
	cmos_init(&c, 64 * 1024 * 1024)
	testing.expect(t, cmos_checksum_valid(&c))
	cmos_test_write(&c, 0x20, 0xA5)
	testing.expect(t, !cmos_checksum_valid(&c))
	cmos_refresh_checksum(&c)
	testing.expect(t, cmos_checksum_valid(&c))
	saved := cmos_nvram_export(&c)
	saved[0x21] = saved[0x21] ~ 1
	saved[0x0D] = 0

	restored: Cmos
	cmos_init(&restored, 64 * 1024 * 1024)
	testing.expect(t, cmos_nvram_import(&restored, saved[:], 64 * 1024 * 1024))
	testing.expect(t, !cmos_last_import_checksum_was_valid(&restored))
	testing.expect(t, cmos_checksum_valid(&restored))
	testing.expect_value(t, cmos_test_read(&restored, 0x0E), u8(0xC0))
	testing.expect_value(t, cmos_test_read(&restored, 0x21), saved[0x21])
}
