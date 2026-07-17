// SPDX-License-Identifier: GPL-3.0-only
package disk

import "core:testing"

// 1MB RAM backing for tests
Ide_Test_Ram :: struct {
	data:             []u8,
	reads:            int,
	read_attempts:    int,
	last_read_bytes:  int,
	writes:           int,
	write_attempts:   int,
	last_write_bytes: int,
	flushes:          int,
	irqs:             int,
	irq_deasserts:    int,
	irq_level:        bool,
	read_fail:        bool,
	write_fail:       bool,
	flush_fail:       bool,
}

ide_test_ram_read :: proc(ctx: rawptr, lba: u64, buf: []u8) -> bool {
	r := (^Ide_Test_Ram)(ctx)
	off := int(lba) * 512
	if off + len(buf) > len(r.data) {return false}
	r.read_attempts += 1
	r.last_read_bytes = len(buf)
	if r.read_fail {return false}
	copy(buf, r.data[off:off + len(buf)])
	r.reads += 1
	return true
}

ide_test_ram_write :: proc(ctx: rawptr, lba: u64, buf: []u8) -> bool {
	r := (^Ide_Test_Ram)(ctx)
	off := int(lba) * 512
	if off + len(buf) > len(r.data) {return false}
	r.write_attempts += 1
	r.last_write_bytes = len(buf)
	if r.write_fail {return false}
	copy(r.data[off:off + len(buf)], buf)
	r.writes += 1
	return true
}

ide_test_ram_flush :: proc(ctx: rawptr) -> bool {
	r := (^Ide_Test_Ram)(ctx)
	r.flushes += 1
	return !r.flush_fail
}

ide_test_setup :: proc(ram: ^Ide_Test_Ram, ide: ^Ide) {
	ram.data = make([]u8, 1024 * 1024)
	bd := Block_Device {
		ctx          = ram,
		sector_count = u64(len(ram.data) / 512),
		read         = ide_test_ram_read,
		write        = ide_test_ram_write,
		flush        = ide_test_ram_flush,
	}
	ide_init(ide, bd)
	ide.irq_ctx = ram
	ide.irq = proc(ctx: rawptr, asserted: bool) {
		ram := (^Ide_Test_Ram)(ctx)
		ram.irq_level = asserted
		if asserted {
			ram.irqs += 1
		} else {
			ram.irq_deasserts += 1
		}
	}
}

ide_test_outb :: proc(ide: ^Ide, port: u16, v: u8) {ide_io_write(ide, port, 1, u32(v))}
ide_test_outw :: proc(ide: ^Ide, port: u16, v: u16) {ide_io_write(ide, port, 2, u32(v))}
ide_test_inb :: proc(ide: ^Ide, port: u16) -> u8 {return u8(ide_io_read(ide, port, 1))}
ide_test_inw :: proc(ide: ^Ide, port: u16) -> u16 {return u16(ide_io_read(ide, port, 2))}

ide_test_advance_deadline :: proc(ide: ^Ide) -> bool {
	deadline, pending := ide_next_deadline(ide)
	if !pending {return false}
	ide_advance_to(ide, deadline)
	return true
}

ide_test_command :: proc(ide: ^Ide, command: u8) {
	ide_test_outb(ide, 0x1F7, command)
	_ = ide_test_advance_deadline(ide)
}

ide_test_set_lba28 :: proc(ide: ^Ide, lba: u32, count: u8) {
	ide_test_outb(ide, 0x1F2, count)
	ide_test_outb(ide, 0x1F3, u8(lba))
	ide_test_outb(ide, 0x1F4, u8(lba >> 8))
	ide_test_outb(ide, 0x1F5, u8(lba >> 16))
	ide_test_outb(ide, 0x1F6, 0xE0 | u8(lba >> 24) & 0x0F)
}

ide_test_set_multiple_mode :: proc(ide: ^Ide, count: u8) {
	ide_test_outb(ide, 0x1F2, count)
	ide_test_command(ide, 0xC6)
	_ = ide_test_inb(ide, 0x1F7)
}

ide_test_current_lba28 :: proc(ide: ^Ide) -> u32 {
	return(
		u32(ide.reg_lba_lo) |
		u32(ide.reg_lba_mid) << 8 |
		u32(ide.reg_lba_hi) << 16 |
		u32(ide.reg_drive & 0x0F) << 24 \
	)
}

@(test)
ide_test_identify :: proc(t: ^testing.T) {
	ram: Ide_Test_Ram
	ide: Ide
	ide_test_setup(&ram, &ide)
	defer delete(ram.data)

	ide_test_outb(&ide, 0x1F6, 0xA0)
	ide_test_command(&ide, 0xEC)
	testing.expect_value(t, ide.transfer_mode, IDE_DEFAULT_TRANSFER_MODE)

	st := ide_test_inb(&ide, 0x1F7)
	testing.expect_value(t, st, u8(IDE_STATUS_READY | IDE_STATUS_DRQ))

	words: [256]u16
	for i in 0 ..< 256 {words[i] = ide_test_inw(&ide, 0x1F0)}

	testing.expect_value(t, words[0], 0x0040)
	testing.expect_value(t, words[1], u16(2))
	testing.expect_value(t, words[3], u16(IDE_CHS_HEADS))
	testing.expect_value(t, words[6], u16(IDE_CHS_SECTORS_PER_TRACK))
	testing.expect_value(t, words[47], u16(0x8010))
	testing.expect(t, words[49] & 0x0100 != 0) // DMA supported
	testing.expect(t, words[49] & 0x0200 != 0) // LBA supported
	testing.expect(t, words[49] & 0x0800 != 0) // IORDY supported for PIO3/4
	testing.expect_value(t, words[50], u16(0x4000))
	testing.expect_value(t, words[51], u16(0x0200))
	testing.expect_value(t, words[53] & 0x0007, u16(0x0007))
	testing.expect_value(t, words[59], u16(0x0110))
	testing.expect_value(t, words[54], words[1])
	testing.expect_value(t, words[55], words[3])
	testing.expect_value(t, words[56], words[6])
	chs_sectors := u32(words[57]) | u32(words[58]) << 16
	testing.expect_value(t, chs_sectors, u32(2 * IDE_CHS_HEADS * IDE_CHS_SECTORS_PER_TRACK))
	testing.expect_value(t, words[63], u16(0x0007))
	testing.expect_value(t, words[64] & 0x0003, u16(0x0003))
	testing.expect_value(t, words[65], u16(120))
	testing.expect_value(t, words[66], u16(120))
	testing.expect_value(t, words[67], u16(120))
	testing.expect_value(t, words[68], u16(120))
	testing.expect_value(t, words[80], u16(0x003E))
	testing.expect_value(t, words[83], u16(0x5000))
	testing.expect_value(t, words[86], u16(0x5000))
	testing.expect_value(t, words[88], u16(0x001F))
	testing.expect_value(t, words[93], IDE_HARDWARE_RESET_RESULT)
	sectors := u32(words[60]) | (u32(words[61]) << 16)
	testing.expect_value(t, sectors, u32(2048))
	// ATA strings are byte-swapped within each word and space padded.
	testing.expect_value(t, words[10], u16('R') << 8 | u16('E'))
	testing.expect_value(t, words[19], u16('1') << 8 | u16(' '))
	testing.expect_value(t, words[23], u16('1') << 8 | u16('.'))
	testing.expect_value(t, words[27], u16('R') << 8 | u16('E'))
	testing.expect_value(t, words[28], u16('T') << 8 | u16('V'))

	st = ide_test_inb(&ide, 0x1F7)
	testing.expect_value(t, st, u8(IDE_STATUS_READY))
}

@(test)
ide_test_ready_states_satisfy_windows_98_esdi_probe :: proc(t: ^testing.T) {
	ram: Ide_Test_Ram
	ide: Ide
	ide_test_setup(&ram, &ide)
	defer delete(ram.data)
	ready_mask := u8(IDE_STATUS_DRDY | IDE_STATUS_DSC)
	testing.expect_value(t, ide_test_inb(&ide, 0x1F7) & ready_mask, ready_mask)
	ide_test_command(&ide, 0x40)
	testing.expect_value(t, ide_test_inb(&ide, 0x1F7) & ready_mask, ready_mask)
	ide_test_command(&ide, 0xEC)
	testing.expect_value(t, ide_test_inb(&ide, 0x1F7) & ready_mask, ready_mask)
}

@(test)
ide_test_identify_2gib_capacity_has_truthful_chs_and_exact_lba :: proc(t: ^testing.T) {
	ide: Ide
	sector_count := u64(4_194_367)
	ide_init(&ide, Block_Device{sector_count = sector_count})
	ide_test_command(&ide, 0xEC)
	words: [256]u16
	for i in 0 ..< 256 {words[i] = ide_test_inw(&ide, 0x1F0)}

	cylinders := u16(sector_count / (IDE_CHS_HEADS * IDE_CHS_SECTORS_PER_TRACK))
	testing.expect_value(t, cylinders, u16(4161))
	testing.expect_value(t, words[1], cylinders)
	testing.expect_value(t, words[54], cylinders)
	testing.expect_value(t, words[55], u16(IDE_CHS_HEADS))
	testing.expect_value(t, words[56], u16(IDE_CHS_SECTORS_PER_TRACK))
	chs_sectors := u32(words[57]) | u32(words[58]) << 16
	testing.expect_value(
		t,
		chs_sectors,
		u32(cylinders) * IDE_CHS_HEADS * IDE_CHS_SECTORS_PER_TRACK,
	)
	lba_sectors := u32(words[60]) | u32(words[61]) << 16
	testing.expect_value(t, lba_sectors, u32(sector_count))
}

@(test)
ide_test_set_features_selects_only_supported_dma_mode :: proc(t: ^testing.T) {
	ram: Ide_Test_Ram
	ide: Ide
	ide_test_setup(&ram, &ide)
	defer delete(ram.data)

	ide_test_outb(&ide, 0x1F1, 0x03)
	ide_test_outb(&ide, 0x1F2, 0x42)
	ide_test_command(&ide, 0xEF)
	testing.expect_value(t, ide.transfer_mode, u8(0x42))
	testing.expect_value(t, ide_transfer_mode_rate(ide.transfer_mode), u64(33_333_333))

	ide_test_command(&ide, 0xEC)
	words: [256]u16
	for i in 0 ..< 256 {words[i] = ide_test_inw(&ide, 0x1F0)}
	testing.expect_value(t, words[63], u16(0x0007))
	testing.expect_value(t, words[88], u16(0x041F))

	ide_test_outb(&ide, 0x1F1, 0x03)
	ide_test_outb(&ide, 0x1F2, 0x45)
	ide_test_outb(&ide, 0x1F7, 0xEF)
	testing.expect(t, ide_test_inb(&ide, 0x1F7) & IDE_STATUS_ERR != 0)
	testing.expect_value(t, ide_test_inb(&ide, 0x1F1), u8(IDE_ERROR_ABRT))
	testing.expect_value(t, ide.transfer_mode, u8(0x42))

	ide_test_outb(&ide, 0x3F6, 0x04)
	ide_test_outb(&ide, 0x3F6, 0x00)
	testing.expect_value(t, ide.transfer_mode, u8(0x42))
	ide_test_command(&ide, 0xEC)
	for i in 0 ..< 256 {words[i] = ide_test_inw(&ide, 0x1F0)}
	testing.expect_value(t, words[88], u16(0x041F))
	testing.expect_value(t, words[93], IDE_HARDWARE_RESET_RESULT)
}

@(test)
ide_test_set_features_aborts_unsupported_subcommands :: proc(t: ^testing.T) {
	ram: Ide_Test_Ram
	ide: Ide
	ide_test_setup(&ram, &ide)
	defer delete(ram.data)

	for subcommand in ([]u8{0x00, 0x02, 0xAA}) {
		ide_test_outb(&ide, 0x1F1, subcommand)
		ide_test_outb(&ide, 0x1F7, 0xEF)
		testing.expect_value(t, ide_test_inb(&ide, 0x1F1), u8(IDE_ERROR_ABRT))
		status := ide_test_inb(&ide, 0x1F7)
		testing.expect(t, status & IDE_STATUS_ERR != 0)
		testing.expect(t, status & (IDE_STATUS_BSY | IDE_STATUS_DRQ) == 0)
		testing.expect_value(t, ide.transfer_mode, IDE_DEFAULT_TRANSFER_MODE)
	}
}

@(test)
ide_test_set_multiple_mode_validates_identify_and_resets :: proc(t: ^testing.T) {
	ram: Ide_Test_Ram
	ide: Ide
	ide_test_setup(&ram, &ide)
	defer delete(ram.data)

	ide_test_set_multiple_mode(&ide, IDE_MULTIPLE_MAX_SECTORS)
	testing.expect_value(t, ide.multiple_sector_count, u8(IDE_MULTIPLE_MAX_SECTORS))

	ide_test_command(&ide, 0xEC)
	words: [256]u16
	for i in 0 ..< 256 {words[i] = ide_test_inw(&ide, 0x1F0)}
	testing.expect_value(t, words[47], u16(0x8010))
	testing.expect_value(t, words[59], u16(0x0110))

	ide_test_outb(&ide, 0x1F2, 3)
	ide_test_outb(&ide, 0x1F7, 0xC6)
	testing.expect(t, ide_test_inb(&ide, 0x1F7) & IDE_STATUS_ERR != 0)
	testing.expect_value(t, ide_test_inb(&ide, 0x1F1), u8(IDE_ERROR_ABRT))
	testing.expect_value(t, ide.multiple_sector_count, u8(IDE_MULTIPLE_MAX_SECTORS))

	ide_test_set_multiple_mode(&ide, 0)
	testing.expect_value(t, ide.multiple_sector_count, u8(0))
	ide_test_command(&ide, 0xEC)
	for i in 0 ..< 256 {words[i] = ide_test_inw(&ide, 0x1F0)}
	testing.expect_value(t, words[59], u16(0))
	ide_test_set_lba28(&ide, 4, 1)
	ide_test_outb(&ide, 0x1F7, 0xC4)
	testing.expect(t, ide_test_inb(&ide, 0x1F7) & IDE_STATUS_ERR != 0)

	ide_test_set_multiple_mode(&ide, IDE_MULTIPLE_MAX_SECTORS)
	ide_test_outb(&ide, 0x3F6, 0x04)
	ide_test_outb(&ide, 0x3F6, 0x00)
	testing.expect_value(t, ide.multiple_sector_count, u8(IDE_MULTIPLE_MAX_SECTORS))
	testing.expect_value(t, ide.reg_seccount, u8(1))
	ide_test_command(&ide, 0xEC)
	for i in 0 ..< 256 {words[i] = ide_test_inw(&ide, 0x1F0)}
	testing.expect_value(t, words[59], u16(0x0110))
}

@(test)
ide_test_read_multiple_uses_16_sector_irq_blocks :: proc(t: ^testing.T) {
	ram: Ide_Test_Ram
	ide: Ide
	ide_test_setup(&ram, &ide)
	defer delete(ram.data)
	start_lba := 32
	sector_count := 18
	for sector in 0 ..< sector_count {
		for word in 0 ..< IDE_SECTOR_SIZE / 2 {
			value := u16(sector << 8 | word & 0xFF)
			offset := (start_lba + sector) * IDE_SECTOR_SIZE + word * 2
			ram.data[offset] = u8(value)
			ram.data[offset + 1] = u8(value >> 8)
		}
	}

	ide_test_set_multiple_mode(&ide, IDE_MULTIPLE_MAX_SECTORS)
	ram.irqs = 0
	ram.irq_deasserts = 0
	ide_test_set_lba28(&ide, u32(start_lba), u8(sector_count))
	ide_test_outb(&ide, 0x1F7, 0xC4)
	first, pending := ide_next_deadline(&ide)
	if !testing.expect(t, pending) {return}
	ide_advance_to(&ide, first)
	testing.expect_value(t, ram.read_attempts, 1)
	testing.expect_value(t, ide.activity_generation, u64(1))
	testing.expect_value(t, ram.last_read_bytes, sector_count * IDE_SECTOR_SIZE)
	testing.expect_value(t, ram.irqs, 1)
	_ = ide_test_inb(&ide, 0x1F7)

	for sector in 0 ..< sector_count {
		for word in 0 ..< IDE_SECTOR_SIZE / 2 {
			expected := u16(sector << 8 | word & 0xFF)
			testing.expect_value(t, ide_test_inw(&ide, 0x1F0), expected)
		}
		if sector < IDE_MULTIPLE_MAX_SECTORS - 1 {
			_, block_pending := ide_next_deadline(&ide)
			testing.expect(t, !block_pending)
			testing.expect(t, ide_test_inb(&ide, 0x3F6) & IDE_STATUS_DRQ != 0)
		} else if sector == IDE_MULTIPLE_MAX_SECTORS - 1 {
			next, block_pending := ide_next_deadline(&ide)
			if !testing.expect(t, block_pending) {return}
			testing.expect_value(t, next - first, IDE_PIO_SECTOR_TICKS)
			testing.expect_value(t, ide_test_inb(&ide, 0x3F6), u8(IDE_STATUS_BSY))
			ide_advance_to(&ide, next)
			testing.expect_value(t, ram.irqs, 2)
			_ = ide_test_inb(&ide, 0x1F7)
		}
	}

	testing.expect_value(t, ram.read_attempts, 1)
	testing.expect_value(t, ram.irqs, 2)
	testing.expect_value(t, ide_test_inb(&ide, 0x1F2), u8(0))
	testing.expect_value(t, ide_test_current_lba28(&ide), u32(start_lba + sector_count))
	testing.expect(t, ide_test_inb(&ide, 0x1F7) & IDE_STATUS_DRQ == 0)
}

@(test)
ide_test_write_multiple_stages_blocks_and_commits_once :: proc(t: ^testing.T) {
	ram: Ide_Test_Ram
	ide: Ide
	ide_test_setup(&ram, &ide)
	defer delete(ram.data)
	start_lba := 64
	sector_count := 18

	ide_test_set_multiple_mode(&ide, IDE_MULTIPLE_MAX_SECTORS)
	ram.irqs = 0
	ram.irq_deasserts = 0
	ide_test_set_lba28(&ide, u32(start_lba), u8(sector_count))
	ide_test_outb(&ide, 0x1F7, 0xC5)
	first, pending := ide_next_deadline(&ide)
	if !testing.expect(t, pending) {return}
	ide_advance_to(&ide, first)
	testing.expect_value(t, ram.irqs, 0)
	testing.expect(t, ide_test_inb(&ide, 0x3F6) & IDE_STATUS_DRQ != 0)

	for sector in 0 ..< sector_count {
		for word in 0 ..< IDE_SECTOR_SIZE / 2 {
			ide_test_outw(&ide, 0x1F0, u16(sector << 8 | word & 0xFF))
		}
		testing.expect_value(t, ram.write_attempts, 0)
		if sector < IDE_MULTIPLE_MAX_SECTORS - 1 {
			_, block_pending := ide_next_deadline(&ide)
			testing.expect(t, !block_pending)
			testing.expect(t, ide_test_inb(&ide, 0x3F6) & IDE_STATUS_DRQ != 0)
		} else if sector == IDE_MULTIPLE_MAX_SECTORS - 1 {
			next, block_pending := ide_next_deadline(&ide)
			if !testing.expect(t, block_pending) {return}
			testing.expect_value(t, next - first, IDE_PIO_SECTOR_TICKS)
			ide_advance_to(&ide, next)
			testing.expect_value(t, ram.irqs, 1)
			_ = ide_test_inb(&ide, 0x1F7)
		}
	}

	commit, commit_pending := ide_next_deadline(&ide)
	if !testing.expect(t, commit_pending) {return}
	ide_advance_to(&ide, commit)
	testing.expect_value(t, ram.write_attempts, 1)
	testing.expect_value(t, ram.writes, 1)
	testing.expect_value(t, ide.activity_generation, u64(1))
	testing.expect_value(t, ram.last_write_bytes, sector_count * IDE_SECTOR_SIZE)
	testing.expect_value(t, ram.irqs, 2)
	for sector in 0 ..< sector_count {
		offset := (start_lba + sector) * IDE_SECTOR_SIZE
		testing.expect_value(t, ram.data[offset], u8(0))
		testing.expect_value(t, ram.data[offset + 1], u8(sector))
	}
	testing.expect_value(t, ide_test_current_lba28(&ide), u32(start_lba + sector_count))
	testing.expect_value(t, ide_test_inb(&ide, 0x1F2), u8(0))
}

@(test)
ide_test_pio_roundtrip :: proc(t: ^testing.T) {
	ram: Ide_Test_Ram
	ide: Ide
	ide_test_setup(&ram, &ide)
	defer delete(ram.data)

	irq_count := 0
	ide.irq_ctx = &irq_count
	ide.irq = proc(ctx: rawptr, asserted: bool) {
		if asserted {(^int)(ctx)^ += 1}
	}

	// WRITE SECTORS to LBA 3
	ide_test_set_lba28(&ide, 3, 1)
	ide_test_command(&ide, 0x30)

	st := ide_test_inb(&ide, 0x1F7)
	testing.expect(t, st & 0x80 == 0) // BSY clear
	testing.expect(t, st & 0x08 != 0) // DRQ requests data

	for i in 0 ..< 256 {ide_test_outw(&ide, 0x1F0, u16(i) ~ 0xBEEF)}
	testing.expect(t, ide_test_advance_deadline(&ide))

	st = ide_test_inb(&ide, 0x1F7)
	testing.expect(t, st & 0x08 == 0) // DRQ clear
	testing.expect(t, st & 0x40 != 0) // DRDY
	testing.expect(t, st & 0x01 == 0) // no error
	testing.expect(t, irq_count > 0)

	// RAM backing holds word 0 (0xBEEF) in little-endian
	testing.expect_value(t, ram.data[3 * 512], u8(0xEF))
	testing.expect_value(t, ram.data[3 * 512 + 1], u8(0xBE))
	testing.expect_value(t, ram.flushes, 0)
	testing.expect(t, ide.writeback_pending)

	// READ SECTORS from LBA 3
	ide_test_set_lba28(&ide, 3, 1)
	ide_test_command(&ide, 0x20)

	st = ide_test_inb(&ide, 0x1F7)
	testing.expect(t, st & 0x08 != 0) // DRQ offers data

	ok := true
	for i in 0 ..< 256 {
		if ide_test_inw(&ide, 0x1F0) != (u16(i) ~ 0xBEEF) {ok = false}
	}
	testing.expect(t, ok)

	st = ide_test_inb(&ide, 0x1F7)
	testing.expect(t, st & 0x08 == 0)
}

@(test)
ide_test_multisector_write_checkpoints_on_flush_cache :: proc(t: ^testing.T) {
	ram: Ide_Test_Ram
	ide: Ide
	ide_test_setup(&ram, &ide)
	defer delete(ram.data)

	ide_test_set_lba28(&ide, 7, 3)
	ide_test_command(&ide, 0x30)
	for sector in 0 ..< 3 {
		for word in 0 ..< 256 {
			ide_test_outw(&ide, 0x1F0, u16(sector << 12 | word))
		}
		testing.expect_value(t, ram.writes, 0)
		testing.expect_value(t, ram.flushes, 0)
		testing.expect(t, ide_test_advance_deadline(&ide))
	}

	testing.expect_value(t, ram.writes, 1)
	testing.expect_value(t, ram.write_attempts, 1)
	testing.expect_value(t, ram.last_write_bytes, 3 * IDE_SECTOR_SIZE)
	testing.expect_value(t, ram.flushes, 0)
	testing.expect(t, ide.writeback_pending)
	ide_test_command(&ide, 0xE7)
	testing.expect_value(t, ram.flushes, 1)
	testing.expect(t, !ide.writeback_pending)
	testing.expect_value(t, ide_test_inb(&ide, 0x1F2), u8(0))
	st := ide_test_inb(&ide, 0x1F7)
	testing.expect(t, st & IDE_STATUS_DRQ == 0)
	testing.expect(t, st & IDE_STATUS_ERR == 0)
}

@(test)
ide_test_flush_cache_completes_only_after_durable_flush :: proc(t: ^testing.T) {
	ram: Ide_Test_Ram
	ide: Ide
	ide_test_setup(&ram, &ide)
	defer delete(ram.data)

	ide_test_outb(&ide, 0x1F7, 0xE7)
	testing.expect_value(t, ide_test_inb(&ide, 0x3F6), u8(IDE_STATUS_BSY))
	testing.expect_value(t, ram.flushes, 0)
	testing.expect_value(t, ram.irqs, 0)
	testing.expect(t, ide_test_advance_deadline(&ide))
	testing.expect_value(t, ram.flushes, 1)
	testing.expect_value(t, ram.irqs, 1)
	testing.expect_value(t, ide_test_inb(&ide, 0x1F7), u8(IDE_STATUS_READY))
}

@(test)
ide_test_idle_writeback_failure_retries_without_poisoning_writes :: proc(t: ^testing.T) {
	ram: Ide_Test_Ram
	ide: Ide
	ide_test_setup(&ram, &ide)
	defer delete(ram.data)
	ram.flush_fail = true

	ide_test_set_lba28(&ide, 9, 1)
	ide_test_command(&ide, 0x30)
	for word in 0 ..< 256 {
		ide_test_outw(&ide, 0x1F0, u16(word))
	}
	testing.expect(t, ide_test_advance_deadline(&ide))

	testing.expect_value(t, ram.writes, 1)
	testing.expect_value(t, ram.flushes, 0)
	deadline, pending := ide_next_deadline(&ide)
	testing.expect(t, pending)
	testing.expect_value(t, deadline - ide.now_tick, IDE_WRITEBACK_IDLE_TICKS)
	ide_advance_to(&ide, deadline)
	testing.expect_value(t, ram.flushes, 1)
	testing.expect_value(t, ram.irqs, 1)
	testing.expect_value(t, ide.state, Ide_State.Idle)
	status := ide_test_inb(&ide, 0x1F7)
	testing.expect(t, status & IDE_STATUS_ERR == 0)
	testing.expect(t, status & IDE_STATUS_DRQ == 0)
	testing.expect(t, ide.writeback_pending)
	testing.expect(t, !ide.writeback_failed)
	retry_deadline, retry_pending := ide_next_deadline(&ide)
	testing.expect(t, retry_pending)
	testing.expect_value(t, retry_deadline - ide.now_tick, IDE_WRITEBACK_IDLE_TICKS)

	ide_test_set_lba28(&ide, 10, 1)
	ide_test_outb(&ide, 0x1F7, 0x30)
	testing.expect(t, ide_test_inb(&ide, 0x1F7) & IDE_STATUS_BSY != 0)
	testing.expect(t, ide_test_advance_deadline(&ide))
	for word in 0 ..< 256 {ide_test_outw(&ide, 0x1F0, u16(word + 1))}
	testing.expect(t, ide_test_advance_deadline(&ide))
	testing.expect_value(t, ram.writes, 2)
	testing.expect(t, ide_test_inb(&ide, 0x1F7) & IDE_STATUS_ERR == 0)

	ram.flush_fail = false
	retry_deadline, retry_pending = ide_next_deadline(&ide)
	testing.expect(t, retry_pending)
	ide_advance_to(&ide, retry_deadline)
	testing.expect_value(t, ram.flushes, 2)
	testing.expect(t, !ide.writeback_pending)
}

@(test)
ide_test_flush_durability_failure_aborts_command :: proc(t: ^testing.T) {
	ram: Ide_Test_Ram
	ide: Ide
	ide_test_setup(&ram, &ide)
	defer delete(ram.data)
	ram.flush_fail = true

	ide_test_command(&ide, 0xE7)

	testing.expect_value(t, ram.writes, 0)
	testing.expect_value(t, ram.flushes, 1)
	testing.expect_value(t, ram.irqs, 1)
	testing.expect_value(t, ide_test_inb(&ide, 0x1F1), u8(IDE_ERROR_ABRT))
	status := ide_test_inb(&ide, 0x1F7)
	testing.expect(t, status & IDE_STATUS_ERR != 0)
	testing.expect(t, status & IDE_STATUS_DRQ == 0)
}

@(test)
ide_test_multisector_read :: proc(t: ^testing.T) {
	ram: Ide_Test_Ram
	ide: Ide
	ide_test_setup(&ram, &ide)
	defer delete(ram.data)

	ram.data[5 * 512] = 0x55
	ram.data[6 * 512] = 0x66

	ide_test_set_lba28(&ide, 5, 2)
	ide_test_command(&ide, 0x20)

	buf: [512]u16
	for sector in 0 ..< 2 {
		for word in 0 ..< 256 {buf[sector * 256 + word] = ide_test_inw(&ide, 0x1F0)}
		if sector == 0 {testing.expect(t, ide_test_advance_deadline(&ide))}
	}

	testing.expect_value(t, u8(buf[0]), u8(0x55))
	testing.expect_value(t, u8(buf[256]), u8(0x66))
	st := ide_test_inb(&ide, 0x1F7)
	testing.expect(t, st & 0x08 == 0)
	testing.expect_value(t, ide_test_inb(&ide, 0x1F2), u8(0))
}

@(test)
ide_test_chs_read :: proc(t: ^testing.T) {
	ram: Ide_Test_Ram
	ide: Ide
	ide_test_setup(&ram, &ide)
	defer delete(ram.data)

	// CHS 0/1/1 with 16 heads and 63 spt = LBA 63
	ram.data[63 * 512] = 0x7A

	ide_test_outb(&ide, 0x1F2, 1)
	ide_test_outb(&ide, 0x1F3, 1) // sector 1
	ide_test_outb(&ide, 0x1F4, 0) // cylinder low
	ide_test_outb(&ide, 0x1F5, 0) // cylinder high
	ide_test_outb(&ide, 0x1F6, 0xA1) // head 1, no LBA bit
	ide_test_command(&ide, 0x20)

	w := ide_test_inw(&ide, 0x1F0)
	testing.expect_value(t, u8(w), u8(0x7A))
	for _ in 1 ..< 256 {_ = ide_test_inw(&ide, 0x1F0)}
	st := ide_test_inb(&ide, 0x1F7)
	testing.expect(t, st & 0x08 == 0)
}

@(test)
ide_test_nodata_commands :: proc(t: ^testing.T) {
	ram: Ide_Test_Ram
	ide: Ide
	ide_test_setup(&ram, &ide)
	defer delete(ram.data)

	ide_test_outb(&ide, 0x1F1, 0x03)
	ide_test_outb(&ide, 0x1F2, IDE_DEFAULT_TRANSFER_MODE)
	for cmd in ([]u8{0xEF, 0x40, 0xE7}) {
		ide_test_command(&ide, cmd)
		st := ide_test_inb(&ide, 0x1F7)
		testing.expect(t, st & 0x40 != 0) // DRDY
		testing.expect(t, st & 0x88 == 0) // neither BSY nor DRQ
	}
	testing.expect_value(t, ram.flushes, 1)
}

@(test)
ide_test_slave_not_present :: proc(t: ^testing.T) {
	ram: Ide_Test_Ram
	ide: Ide
	ide_test_setup(&ram, &ide)
	defer delete(ram.data)

	// Select the absent slave: every register reads back 0x00
	ide_test_outb(&ide, 0x1F6, 0xB0)
	testing.expect_value(t, ide_test_inb(&ide, 0x1F6), u8(0x00)) // dh readback fails
	testing.expect_value(t, ide_test_inb(&ide, 0x1F7), u8(0x00)) // status reads zero

	ide_test_outb(&ide, 0x1F2, 0x55)
	testing.expect_value(t, ide_test_inb(&ide, 0x1F2), u8(0x00))

	// Commands to the absent slave are ignored
	ide_test_command(&ide, 0xEC)
	testing.expect_value(t, ide_test_inb(&ide, 0x1F7), u8(0x00))

	// Reselect master: no leftover state, IDENTIFY still works
	ide_test_outb(&ide, 0x1F6, 0xA0)
	st := ide_test_inb(&ide, 0x1F7)
	testing.expect(t, st & 0x08 == 0) // ignored command left no DRQ

	ide_test_command(&ide, 0xEC)
	st = ide_test_inb(&ide, 0x1F7)
	testing.expect(t, st & 0x80 == 0) // BSY clear
	testing.expect(t, st & 0x08 != 0) // DRQ set
	testing.expect_value(t, ide_test_inw(&ide, 0x1F0), u16(0x0040))
}

@(test)
ide_test_software_reset_reselects_master_and_publishes_signature :: proc(t: ^testing.T) {
	ram: Ide_Test_Ram
	ide: Ide
	ide_test_setup(&ram, &ide)
	defer delete(ram.data)

	ide_test_outb(&ide, 0x1F6, 0xB0)
	testing.expect_value(t, ide_test_inb(&ide, 0x1F7), u8(0))
	ide_test_outb(&ide, 0x1F6, 0xA0)
	ide_test_outb(&ide, 0x1F7, 0xEC)
	testing.expect(t, ide_test_advance_deadline(&ide))
	testing.expect_value(t, ram.irqs, 1)
	testing.expect(t, ram.irq_level)
	ide_test_outb(&ide, 0x3F6, 0x04)
	testing.expect_value(t, ide.reg_status, u8(IDE_STATUS_BSY))
	testing.expect_value(t, ram.irq_deasserts, 1)
	testing.expect(t, !ram.irq_level)
	testing.expect(t, !ide_interrupt_pending(&ide))
	ide_test_outb(&ide, 0x3F6, 0x04)
	testing.expect_value(t, ram.irq_deasserts, 1)

	ide_test_outb(&ide, 0x3F6, 0)
	testing.expect_value(t, ide_test_inb(&ide, 0x1F6), u8(0xA0))
	testing.expect_value(t, ide_test_inb(&ide, 0x1F1), u8(1))
	testing.expect_value(t, ide_test_inb(&ide, 0x1F2), u8(1))
	testing.expect_value(t, ide_test_inb(&ide, 0x1F3), u8(1))
	testing.expect_value(t, ide_test_inb(&ide, 0x1F4), u8(0))
	testing.expect_value(t, ide_test_inb(&ide, 0x1F5), u8(0))
	testing.expect_value(t, ide_test_inb(&ide, 0x1F7), u8(IDE_STATUS_READY))
	testing.expect(t, !ide_interrupt_pending(&ide))
	testing.expect_value(t, ram.irqs, 1)
	testing.expect_value(t, ram.irq_deasserts, 1)
}

@(test)
ide_test_execute_device_diagnostic_is_broadcast_from_slave_selection :: proc(t: ^testing.T) {
	ram: Ide_Test_Ram
	ide: Ide
	ide_test_setup(&ram, &ide)
	defer delete(ram.data)

	ide_test_outb(&ide, 0x1F6, 0xB0)
	ide_test_outb(&ide, 0x1F7, 0x90)
	testing.expect_value(t, ide.reg_status, u8(IDE_STATUS_BSY))
	testing.expect(t, ide_test_advance_deadline(&ide))
	testing.expect_value(t, ide_test_inb(&ide, 0x1F6), u8(0xA0))
	testing.expect_value(t, ide_test_inb(&ide, 0x1F1), u8(1))
	testing.expect_value(t, ide_test_inb(&ide, 0x1F7), u8(IDE_STATUS_READY))
	testing.expect_value(t, ram.irqs, 1)
}

@(test)
ide_test_initialize_device_parameters_accepts_advertised_geometry :: proc(t: ^testing.T) {
	ram: Ide_Test_Ram
	ide: Ide
	ide_test_setup(&ram, &ide)
	defer delete(ram.data)

	ide_test_outb(&ide, 0x1F2, IDE_CHS_SECTORS_PER_TRACK)
	ide_test_outb(&ide, 0x1F6, 0xA0 | IDE_CHS_HEADS - 1)
	ide_test_outb(&ide, 0x1F7, 0x91)
	testing.expect_value(t, ide.reg_status, u8(IDE_STATUS_BSY))
	testing.expect(t, ide_test_advance_deadline(&ide))
	testing.expect(t, ide_test_inb(&ide, 0x1F7) & IDE_STATUS_ERR == 0)

	ide_test_outb(&ide, 0x1F2, IDE_CHS_SECTORS_PER_TRACK - 1)
	ide_test_outb(&ide, 0x1F7, 0x91)
	testing.expect(t, ide_test_inb(&ide, 0x1F7) & IDE_STATUS_ERR != 0)
}

@(test)
ide_test_dma_request_uses_udma_66_rate :: proc(t: ^testing.T) {
	ram: Ide_Test_Ram
	ide: Ide
	ide_test_setup(&ram, &ide)
	defer delete(ram.data)

	ide_test_outb(&ide, 0x1F1, 0x03)
	ide_test_outb(&ide, 0x1F2, 0x40 | IDE_UDMA_MODE)
	ide_test_command(&ide, 0xEF)
	ide_test_set_lba28(&ide, 1, 1)
	ide_io_write(&ide, 0x1F7, 1, 0xC8)
	request, pending := ide_bmide_request(&ide)
	if !testing.expect(t, pending) {return}
	testing.expect(
		t,
		request.device.begin(request.device.ctx, 0, request.direction, request.byte_count),
	)
	testing.expect_value(t, ide.activity_generation, u64(1))
	data: [IDE_SECTOR_SIZE]u8
	testing.expect(t, request.device.read(request.device.ctx, 0, 0, data[:]))
	testing.expect_value(t, ide.activity_generation, u64(1))
	testing.expect_value(t, IDE_UDMA_MODE, u8(4))
}

@(test)
ide_test_pio_read_phases_obey_deadlines :: proc(t: ^testing.T) {
	ram: Ide_Test_Ram
	ide: Ide
	ide_test_setup(&ram, &ide)
	defer delete(ram.data)
	ram.data[4 * IDE_SECTOR_SIZE] = 0x44
	ram.data[5 * IDE_SECTOR_SIZE] = 0x55

	ide_test_set_lba28(&ide, 4, 2)
	ide_test_outb(&ide, 0x1F7, 0x20)
	first, pending := ide_next_deadline(&ide)
	testing.expect(t, pending)
	testing.expect_value(t, first, IDE_COMMAND_LATENCY_TICKS)
	testing.expect_value(t, ram.reads, 0)
	testing.expect_value(t, ide.activity_generation, u64(0))
	testing.expect_value(t, ide_test_inb(&ide, 0x1F7), u8(IDE_STATUS_BSY))
	ide_advance_to(&ide, first - 1)
	testing.expect_value(t, ram.reads, 0)
	testing.expect(t, ide_test_inb(&ide, 0x1F7) & IDE_STATUS_DRQ == 0)
	ide_advance_to(&ide, first)
	testing.expect_value(t, ram.reads, 1)
	testing.expect(t, ide_test_inb(&ide, 0x1F7) & IDE_STATUS_DRQ != 0)
	testing.expect_value(t, u8(ide_test_inw(&ide, 0x1F0)), u8(0x44))
	for _ in 1 ..< 256 {_ = ide_test_inw(&ide, 0x1F0)}

	second, pending_second := ide_next_deadline(&ide)
	testing.expect(t, pending_second)
	testing.expect_value(t, second - first, IDE_PIO_SECTOR_TICKS)
	ide_advance_to(&ide, second - 1)
	testing.expect_value(t, ram.reads, 1)
	ide_advance_to(&ide, second)
	testing.expect_value(t, ram.reads, 1)
	testing.expect_value(t, u8(ide_test_inw(&ide, 0x1F0)), u8(0x55))
}

@(test)
ide_test_pio_256_sector_read_batches_backing_and_preserves_phases :: proc(t: ^testing.T) {
	ram: Ide_Test_Ram
	ide: Ide
	ide_test_setup(&ram, &ide)
	defer delete(ram.data)
	start_lba := 32
	for sector in 0 ..< IDE_DMA_MAX_SECTORS {
		offset := (start_lba + sector) * IDE_SECTOR_SIZE
		for word in 0 ..< IDE_SECTOR_SIZE / 2 {
			value := u16(sector) << 8 | u16(word & 0xFF)
			ram.data[offset + word * 2] = u8(value)
			ram.data[offset + word * 2 + 1] = u8(value >> 8)
		}
	}

	ide_test_set_lba28(&ide, u32(start_lba), 0)
	ide_test_outb(&ide, 0x1F7, 0x20)
	deadline, pending := ide_next_deadline(&ide)
	if !testing.expect(t, pending) {return}
	testing.expect_value(t, deadline, IDE_COMMAND_LATENCY_TICKS)
	testing.expect_value(t, ram.read_attempts, 0)
	ide_advance_to(&ide, deadline)
	testing.expect_value(t, ram.read_attempts, 1)
	testing.expect_value(t, ram.reads, 1)
	testing.expect_value(t, ram.last_read_bytes, IDE_DMA_MAX_BYTES)

	for sector in 0 ..< IDE_DMA_MAX_SECTORS {
		status := ide_test_inb(&ide, 0x1F7)
		testing.expect(t, status & IDE_STATUS_DRQ != 0)
		for word in 0 ..< IDE_SECTOR_SIZE / 2 {
			expected := u16(sector) << 8 | u16(word & 0xFF)
			testing.expect_value(t, ide_test_inw(&ide, 0x1F0), expected)
		}
		if sector + 1 < IDE_DMA_MAX_SECTORS {
			next, next_pending := ide_next_deadline(&ide)
			if !testing.expect(t, next_pending) {return}
			testing.expect_value(t, next - deadline, IDE_PIO_SECTOR_TICKS)
			ide_advance_to(&ide, next - 1)
			testing.expect_value(t, ram.read_attempts, 1)
			testing.expect(t, ide_test_inb(&ide, 0x3F6) & IDE_STATUS_DRQ == 0)
			ide_advance_to(&ide, next)
			deadline = next
		}
	}
	testing.expect_value(t, ram.read_attempts, 1)
	testing.expect_value(t, ram.irqs, IDE_DMA_MAX_SECTORS)
	testing.expect_value(t, ide_test_inb(&ide, 0x1F2), u8(0))
	testing.expect(t, ide_test_inb(&ide, 0x1F7) & IDE_STATUS_DRQ == 0)
}

@(test)
ide_test_pio_batched_read_failure_aborts_at_first_ready_deadline :: proc(t: ^testing.T) {
	ram: Ide_Test_Ram
	ide: Ide
	ide_test_setup(&ram, &ide)
	defer delete(ram.data)
	ram.read_fail = true

	ide_test_set_lba28(&ide, 17, 3)
	ide_test_outb(&ide, 0x1F7, 0x20)
	deadline, pending := ide_next_deadline(&ide)
	if !testing.expect(t, pending) {return}
	testing.expect_value(t, ram.read_attempts, 0)
	testing.expect_value(t, ide_test_inb(&ide, 0x3F6), u8(IDE_STATUS_BSY))
	ide_advance_to(&ide, deadline - 1)
	testing.expect_value(t, ram.read_attempts, 0)
	ide_advance_to(&ide, deadline)
	testing.expect_value(t, ram.read_attempts, 1)
	testing.expect_value(t, ram.last_read_bytes, 3 * IDE_SECTOR_SIZE)
	testing.expect_value(t, ram.reads, 0)
	testing.expect_value(t, ide.activity_generation, u64(0))
	testing.expect_value(t, ide_test_inb(&ide, 0x1F1), u8(IDE_ERROR_ABRT))
	status := ide_test_inb(&ide, 0x1F7)
	testing.expect(t, status & IDE_STATUS_ERR != 0)
	testing.expect(t, status & (IDE_STATUS_BSY | IDE_STATUS_DRQ) == 0)
	_, still_pending := ide_next_deadline(&ide)
	testing.expect(t, !still_pending)
}

@(test)
ide_test_multisector_write_rejection_has_no_partial_commit :: proc(t: ^testing.T) {
	ram: Ide_Test_Ram
	ide: Ide
	ide_test_setup(&ram, &ide)
	defer delete(ram.data)
	start := 11 * IDE_SECTOR_SIZE
	for &byte in ram.data[start:start + 3 * IDE_SECTOR_SIZE] {byte = 0xA5}
	ram.write_fail = true

	ide_test_set_lba28(&ide, 11, 3)
	ide_test_command(&ide, 0x30)
	for sector in 0 ..< 3 {
		for _ in 0 ..< 256 {ide_test_outw(&ide, 0x1F0, u16(sector + 1))}
		testing.expect(t, ide_test_advance_deadline(&ide))
	}

	testing.expect_value(t, ram.write_attempts, 1)
	testing.expect_value(t, ram.writes, 0)
	testing.expect_value(t, ide.activity_generation, u64(0))
	testing.expect_value(t, ram.last_write_bytes, 3 * IDE_SECTOR_SIZE)
	testing.expect_value(t, ram.data[start], u8(0xA5))
	testing.expect_value(t, ram.data[start + 2 * IDE_SECTOR_SIZE], u8(0xA5))
	testing.expect(t, ide_test_inb(&ide, 0x1F7) & IDE_STATUS_ERR != 0)
}

@(test)
ide_test_pci_decode_gates_taskfile_and_channel :: proc(t: ^testing.T) {
	ram: Ide_Test_Ram
	ide: Ide
	ide_test_setup(&ram, &ide)
	defer delete(ram.data)
	initial_sector_count := ide.reg_seccount

	ide_set_pci_decode(&ide, false, true)
	testing.expect_value(t, ide_io_read(&ide, 0x1F7, 1), u32(0xFF))
	ide_io_write(&ide, 0x1F2, 1, 0x55)
	testing.expect_value(t, ide.reg_seccount, initial_sector_count)

	ide_set_pci_decode(&ide, true, false)
	testing.expect_value(t, ide_io_read(&ide, 0x1F7, 1), u32(0xFF))
	ide_set_pci_decode(&ide, true, true)
	testing.expect_value(t, ide_io_read(&ide, 0x1F7, 1), u32(IDE_STATUS_READY))
}

@(test)
ide_test_irq_callback_tracks_nien_and_pci_decode_levels :: proc(t: ^testing.T) {
	ram: Ide_Test_Ram
	ide: Ide
	ide_test_setup(&ram, &ide)
	defer delete(ram.data)

	ide_test_outb(&ide, 0x1F7, 0xEC)
	testing.expect(t, ide_test_advance_deadline(&ide))
	testing.expect_value(t, ram.irqs, 1)
	testing.expect_value(t, ram.irq_deasserts, 0)
	testing.expect(t, ram.irq_level)
	testing.expect(t, ide_interrupt_pending(&ide))

	ide_test_outb(&ide, 0x3F6, 0x02)
	ide_test_outb(&ide, 0x3F6, 0x02)
	testing.expect_value(t, ram.irqs, 1)
	testing.expect_value(t, ram.irq_deasserts, 1)
	testing.expect(t, !ram.irq_level)
	testing.expect(t, ide_interrupt_pending(&ide))
	ide_test_outb(&ide, 0x3F6, 0)
	ide_test_outb(&ide, 0x3F6, 0)
	testing.expect_value(t, ram.irqs, 2)
	testing.expect_value(t, ram.irq_deasserts, 1)
	testing.expect(t, ram.irq_level)

	ide_set_pci_decode(&ide, false, true)
	ide_set_pci_decode(&ide, false, true)
	testing.expect_value(t, ram.irq_deasserts, 1)
	testing.expect(t, ram.irq_level)
	ide_set_pci_decode(&ide, true, false)
	testing.expect_value(t, ram.irqs, 2)
	testing.expect_value(t, ram.irq_deasserts, 2)
	ide_set_pci_decode(&ide, true, true)
	testing.expect_value(t, ram.irqs, 3)
	testing.expect(t, ram.irq_level)
	ide_set_pci_decode(&ide, true, false)
	testing.expect_value(t, ram.irq_deasserts, 3)
	ide_set_pci_decode(&ide, true, true)
	testing.expect_value(t, ram.irqs, 4)

	_ = ide_test_inb(&ide, 0x3F6)
	testing.expect_value(t, ram.irq_deasserts, 3)
	testing.expect(t, ide_interrupt_pending(&ide))
	_ = ide_test_inb(&ide, 0x1F7)
	testing.expect_value(t, ram.irq_deasserts, 4)
	testing.expect(t, !ram.irq_level)
	testing.expect(t, !ide_interrupt_pending(&ide))
	_ = ide_test_inb(&ide, 0x1F7)
	testing.expect_value(t, ram.irq_deasserts, 4)
}

@(test)
ide_test_dma_abort_reasserts_after_nien_clears :: proc(t: ^testing.T) {
	ram: Ide_Test_Ram
	ide: Ide
	ide_test_setup(&ram, &ide)
	defer delete(ram.data)

	ide.dma_pending = true
	ide_test_outb(&ide, 0x3F6, 0x02)
	request, pending := ide_bmide_request(&ide)
	if !testing.expect(t, pending && request.device.abort != nil) {return}
	request.device.abort(request.device.ctx, 0)
	testing.expect(t, ide_interrupt_pending(&ide))
	testing.expect_value(t, ram.irqs, 0)
	testing.expect_value(t, ram.irq_deasserts, 0)
	ide_test_outb(&ide, 0x3F6, 0)
	testing.expect_value(t, ram.irqs, 1)
	testing.expect(t, ram.irq_level)
	testing.expect(t, ide_interrupt_pending(&ide))
	_ = ide_test_inb(&ide, 0x1F7)
	testing.expect(t, !ide_interrupt_pending(&ide))
	testing.expect_value(t, ram.irq_deasserts, 1)
	testing.expect(t, !ram.irq_level)
}

@(test)
ide_test_status_acknowledges_irq_but_alt_status_does_not :: proc(t: ^testing.T) {
	ram: Ide_Test_Ram
	ide: Ide
	ide_test_setup(&ram, &ide)
	defer delete(ram.data)

	ide_test_outb(&ide, 0x1F6, 0xA0)
	ide_test_outb(&ide, 0x1F7, 0xEC)
	_ = ide_test_advance_deadline(&ide)
	testing.expect(t, ide_interrupt_pending(&ide))
	testing.expect_value(t, ram.irqs, 1)
	testing.expect(t, ram.irq_level)
	_ = ide_test_inb(&ide, 0x3F6)
	testing.expect(t, ide_interrupt_pending(&ide))
	testing.expect_value(t, ram.irq_deasserts, 0)
	_ = ide_test_inb(&ide, 0x1F7)
	testing.expect(t, !ide_interrupt_pending(&ide))
	testing.expect_value(t, ram.irq_deasserts, 1)
	testing.expect(t, !ram.irq_level)
}

@(test)
ide_test_pending_irq_is_reasserted_when_nien_clears :: proc(t: ^testing.T) {
	ram: Ide_Test_Ram
	ide: Ide
	ide_test_setup(&ram, &ide)
	defer delete(ram.data)

	ide_test_outb(&ide, 0x3F6, 0x02)
	ide_test_outb(&ide, 0x1F7, 0xEC)
	_ = ide_test_advance_deadline(&ide)
	testing.expect(t, ide_interrupt_pending(&ide))
	testing.expect_value(t, ram.irqs, 0)
	ide_test_outb(&ide, 0x3F6, 0x00)
	testing.expect_value(t, ram.irqs, 1)
	_ = ide_test_inb(&ide, 0x1F7)
	testing.expect(t, !ide_interrupt_pending(&ide))
}
