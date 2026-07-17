// SPDX-License-Identifier: GPL-3.0-only
package disk

import "core:testing"

@(test)
ide_test_last_sector_is_addressable_but_crossing_end_is_rejected_before_io :: proc(t: ^testing.T) {
	ram: Ide_Test_Ram
	ide: Ide
	ide_test_setup(&ram, &ide)
	defer delete(ram.data)
	last_lba := u32(ide.bd.sector_count - 1)
	ram.data[int(last_lba) * IDE_SECTOR_SIZE] = 0xA7

	ide_test_set_lba28(&ide, last_lba, 1)
	ide_test_command(&ide, 0x20)
	testing.expect_value(t, ram.read_attempts, 1)
	testing.expect(t, ide_test_inb(&ide, 0x1F7) & IDE_STATUS_ERR == 0)
	testing.expect_value(t, u8(ide_test_inw(&ide, 0x1F0)), u8(0xA7))
	for _ in 1 ..< IDE_SECTOR_SIZE / 2 {_ = ide_test_inw(&ide, 0x1F0)}

	reads_before := ram.read_attempts
	ide_test_set_lba28(&ide, last_lba, 2)
	ide_test_command(&ide, 0x20)
	testing.expect_value(t, ram.read_attempts, reads_before)
	testing.expect(t, ide_test_inb(&ide, 0x1F7) & IDE_STATUS_ERR != 0)

	ide_test_set_lba28(&ide, u32(ide.bd.sector_count), 1)
	ide_test_command(&ide, 0x20)
	testing.expect_value(t, ram.read_attempts, reads_before)
	testing.expect(t, ide_test_inb(&ide, 0x1F7) & IDE_STATUS_ERR != 0)
}

@(test)
ide_test_zero_sector_count_means_256_and_still_obeys_the_end_boundary :: proc(t: ^testing.T) {
	ram: Ide_Test_Ram
	ide: Ide
	ide_test_setup(&ram, &ide)
	defer delete(ram.data)

	exact_start := u32(ide.bd.sector_count - IDE_DMA_MAX_SECTORS)
	ide_test_set_lba28(&ide, exact_start, 0)
	ide_test_command(&ide, 0x20)
	testing.expect_value(t, ram.read_attempts, 1)
	testing.expect_value(t, ram.last_read_bytes, IDE_DMA_MAX_BYTES)
	testing.expect(t, ide_test_inb(&ide, 0x1F7) & IDE_STATUS_ERR == 0)

	ram.read_attempts = 0
	ide_init(&ide, Block_Device {
		ctx          = &ram,
		sector_count = u64(len(ram.data) / IDE_SECTOR_SIZE),
		read         = ide_test_ram_read,
		write        = ide_test_ram_write,
		flush        = ide_test_ram_flush,
	})
	ide_test_set_lba28(&ide, exact_start + 1, 0)
	ide_test_command(&ide, 0x20)
	testing.expect_value(t, ram.read_attempts, 0)
	testing.expect(t, ide_test_inb(&ide, 0x1F7) & IDE_STATUS_ERR != 0)
}

@(test)
ide_test_zero_sector_count_dma_is_128k_and_obeys_the_end_boundary :: proc(t: ^testing.T) {
	ram: Ide_Test_Ram
	ide: Ide
	ide_test_setup(&ram, &ide)
	defer delete(ram.data)

	ide_test_outb(&ide, 0x1F1, 0x03)
	ide_test_outb(&ide, 0x1F2, 0x40 | IDE_UDMA_MODE)
	ide_test_command(&ide, 0xEF)
	exact_start := u32(ide.bd.sector_count - IDE_DMA_MAX_SECTORS)

	commands := [?]struct {
		command:   u8,
		direction: Bmide_Direction,
	}{
		{0xC8, .Device_To_Memory},
		{0xCA, .Memory_To_Device},
	}
	for command in commands {
		ide_test_set_lba28(&ide, exact_start, 0)
		ide_io_write(&ide, 0x1F7, 1, u32(command.command))
		request, pending := ide_bmide_request(&ide)
		testing.expect(t, pending)
		testing.expect_value(t, request.direction, command.direction)
		testing.expect_value(t, request.byte_count, u32(IDE_DMA_MAX_BYTES))

		ide_test_set_lba28(&ide, exact_start + 1, 0)
		ide_io_write(&ide, 0x1F7, 1, u32(command.command))
		_, pending = ide_bmide_request(&ide)
		testing.expect(t, !pending)
		testing.expect(t, ide_test_inb(&ide, 0x1F7) & IDE_STATUS_ERR != 0)
	}
}
