// SPDX-License-Identifier: GPL-3.0-only
package disk

import persona "../persona"

// Primary IDE channel (0x1F0-0x1F7, 0x3F6), master only.
// Bus-master DMA command handling is adapted from IzarraVM commit
// d930de57acccbc6a70cda8cc5a603173bf23cd1c.

IDE_STATUS_ERR :: 0x01
IDE_STATUS_DRQ :: 0x08
IDE_STATUS_DRDY :: 0x40
IDE_STATUS_BSY :: 0x80

IDE_ERROR_ABRT :: 0x04

IDE_SECTOR_SIZE :: 512
IDE_CHS_HEADS :: 16
IDE_CHS_SECTORS_PER_TRACK :: 63
IDE_CHS_MAX_CYLINDERS :: 16_383
IDE_DMA_MAX_SECTORS :: 256
IDE_DMA_MAX_BYTES :: IDE_SECTOR_SIZE * IDE_DMA_MAX_SECTORS
IDE_UDMA_MODE :: persona.GUEST_PERSONA.max_udma_mode
IDE_UDMA_BYTES_PER_SECOND :: [5]u64{16_700_000, 25_000_000, 33_333_333, 44_444_444, 66_666_667}
IDE_MWDMA_BYTES_PER_SECOND :: [3]u64{4_200_000, 13_300_000, 16_700_000}
IDE_MASTER_CLOCK_HZ :: u64(6_600_000_000)
IDE_COMMAND_LATENCY_TICKS :: IDE_MASTER_CLOCK_HZ / 10_000
IDE_WRITEBACK_IDLE_TICKS :: IDE_MASTER_CLOCK_HZ
IDE_PIO_BYTES_PER_SECOND :: u64(16_700_000)
IDE_PIO_SECTOR_TICKS :: u64(
	(u128(IDE_SECTOR_SIZE) * u128(IDE_MASTER_CLOCK_HZ) + u128(IDE_PIO_BYTES_PER_SECOND - 1)) /
	u128(IDE_PIO_BYTES_PER_SECOND),
)

Ide_State :: enum {
	Idle,
	Data_In,
	Data_Out,
}

Ide_Deadline_Action :: enum u8 {
	None,
	Identify_Ready,
	Read_Ready,
	Write_Ready,
	Write_Commit,
	Command_Complete,
	Diagnostic_Complete,
	Flush_Complete,
}

Ide :: struct {
	bd:                      Block_Device,
	state:                   Ide_State,
	buf:                     [512]u8,
	buf_pos:                 int,
	pending:                 int, // sectors remaining in the transfer
	lba:                     u64,
	cmd:                     u8,
	// registers
	reg_error:               u8,
	reg_features:            u8,
	reg_seccount:            u8,
	reg_lba_lo:              u8,
	reg_lba_mid:             u8,
	reg_lba_hi:              u8,
	reg_drive:               u8,
	reg_status:              u8,
	reg_ctrl:                u8,
	transfer_mode:           u8,
	io_space_enabled:        bool,
	channel_enabled:         bool,
	irq_pending:             bool,
	irq_signaled:            bool,
	// IRQ14 on command completion
	irq:                     proc(ctx: rawptr, asserted: bool),
	irq_ctx:                 rawptr,
	now_tick:                u64,
	deadline_tick:           u64,
	deadline_action:         Ide_Deadline_Action,
	writeback_deadline_tick: u64,
	writeback_pending:       bool,
	writeback_failed:        bool,
	pio_start_lba:           u64,
	pio_staged_bytes:        int,
	pio_read_start_lba:      u64,
	pio_read_sectors:        int,
	pio_read_loaded:         bool,
	// A full ATA command is staged before commit so protected folder-backed
	// writes remain one atomic Block_Device transaction.
	dma_pending:             bool,
	dma_submitted:           bool,
	dma_direction:           Bmide_Direction,
	dma_lba:                 u64,
	dma_sectors:             u32,
	dma_bytes:               int,
	dma_buf:                 [IDE_DMA_MAX_BYTES]u8,
}

ide_init :: proc(ide: ^Ide, bd: Block_Device) {
	ide^ = Ide {
		bd               = bd,
		transfer_mode    = 0x40 | IDE_UDMA_MODE,
		io_space_enabled = true,
		channel_enabled  = true,
	}
	ide_reset_signature(ide)
}

@(private = "package")
ide_reset_signature :: proc(ide: ^Ide) {
	ide_acknowledge_irq(ide)
	ide.reg_error = 1
	ide.reg_seccount = 1
	ide.reg_lba_lo = 1
	ide.reg_lba_mid = 0
	ide.reg_lba_hi = 0
	ide.reg_drive = 0xA0
	ide.reg_status = IDE_STATUS_DRDY
}

ide_set_pci_decode :: proc(ide: ^Ide, io_space_enabled, channel_enabled: bool) {
	if ide == nil {return}
	ide.io_space_enabled = io_space_enabled
	ide.channel_enabled = channel_enabled
	ide_update_irq(ide)
}

ide_io_decoded :: proc(ide: ^Ide) -> bool {
	return ide != nil && ide.io_space_enabled && ide.channel_enabled
}

@(private = "file")
ide_open_bus :: proc(size: u8) -> u32 {
	switch size {
	case 1:
		return 0xFF
	case 2:
		return 0xFFFF
	}
	return 0xFFFF_FFFF
}

@(private = "package")
ide_transfer_mode_rate :: proc(mode: u8) -> u64 {
	class := mode & 0xF8
	index := int(mode & 7)
	switch class {
	case 0x20:
		rates := IDE_MWDMA_BYTES_PER_SECOND
		if index < len(rates) {return rates[index]}
	case 0x40:
		rates := IDE_UDMA_BYTES_PER_SECOND
		if index < len(rates) {return rates[index]}
	}
	return 0
}

@(private = "file")
ide_transfer_mode_supported :: proc(mode: u8) -> bool {
	class := mode & 0xF8
	index := mode & 7
	if class == 0x00 {return index == 0}
	if class == 0x08 {return index <= 4}
	return ide_transfer_mode_rate(mode) != 0
}

// bit4 of drive/head register selects the absent slave: it reads as all zeros
@(private = "file")
ide_slave_selected :: proc(ide: ^Ide) -> bool {
	return ide.reg_drive & 0x10 != 0
}

ide_io_read :: proc(ide: ^Ide, port: u16, size: u8) -> u32 {
	if !ide_io_decoded(ide) {return ide_open_bus(size)}
	if ide_slave_selected(ide) {return 0}
	switch port {
	case 0x1F0:
		return ide_data_read(ide, size)
	case 0x1F1:
		return u32(ide.reg_error)
	case 0x1F2:
		return u32(ide.reg_seccount)
	case 0x1F3:
		return u32(ide.reg_lba_lo)
	case 0x1F4:
		return u32(ide.reg_lba_mid)
	case 0x1F5:
		return u32(ide.reg_lba_hi)
	case 0x1F6:
		return u32(ide.reg_drive)
	case 0x1F7:
		status := ide.reg_status
		ide_acknowledge_irq(ide)
		return u32(status)
	case 0x3F6:
		return u32(ide.reg_status)
	}
	return 0xFF
}

ide_io_write :: proc(ide: ^Ide, port: u16, size: u8, val: u32) {
	if !ide_io_decoded(ide) {return}
	switch port {
	case 0x1F0:
		if ide_slave_selected(ide) {return} 	// absent slave: ignore data
		ide_data_write(ide, size, val)
	case 0x1F1:
		ide.reg_features = u8(val)
	case 0x1F2:
		ide.reg_seccount = u8(val)
	case 0x1F3:
		ide.reg_lba_lo = u8(val)
	case 0x1F4:
		ide.reg_lba_mid = u8(val)
	case 0x1F5:
		ide.reg_lba_hi = u8(val)
	case 0x1F6:
		ide.reg_drive = u8(val)
	case 0x1F7:
		command := u8(val)
		if ide_slave_selected(ide) && command != 0x90 {return}
		ide_command(ide, command)
	case 0x3F6:
		old := ide.reg_ctrl
		ide.reg_ctrl = u8(val)
		if ide.reg_ctrl & 0x04 != 0 {
			ide_acknowledge_irq(ide)
			ide_cancel_pio(ide)
			ide_dma_clear(ide)
			ide.state = .Idle
			ide.reg_status = IDE_STATUS_BSY
		} else if old & 0x04 != 0 {
			ide_reset_signature(ide)
		}
		ide_update_irq(ide)
	}
}

ide_raise_irq :: proc(ide: ^Ide) {
	if ide == nil {return}
	ide.irq_pending = true
	ide_update_irq(ide)
}

@(private = "file")
ide_set_irq_signal :: proc(ide: ^Ide, asserted: bool) {
	if ide == nil || ide.irq_signaled == asserted {return}
	ide.irq_signaled = asserted
	if ide.irq != nil {ide.irq(ide.irq_ctx, asserted)}
}

@(private = "file")
ide_update_irq :: proc(ide: ^Ide) {
	if ide == nil {return}
	ide_set_irq_signal(ide, ide.irq_pending && ide_irq_enabled(ide))
}

ide_acknowledge_irq :: proc(ide: ^Ide) {
	if ide == nil {return}
	ide.irq_pending = false
	ide_update_irq(ide)
}

ide_interrupt_pending :: proc(ide: ^Ide) -> bool {
	return ide != nil && ide.irq_pending
}

// bit6 of drive/head register selects LBA28; otherwise legacy CHS
@(private = "file")
ide_current_lba :: proc(ide: ^Ide) -> u64 {
	if ide.reg_drive & 0x40 != 0 {
		return(
			u64(ide.reg_lba_lo) |
			u64(ide.reg_lba_mid) << 8 |
			u64(ide.reg_lba_hi) << 16 |
			u64(ide.reg_drive & 0x0F) << 24 \
		)
	}
	cyl := u64(ide.reg_lba_hi) << 8 | u64(ide.reg_lba_mid)
	head := u64(ide.reg_drive & 0x0F)
	sec := u64(ide.reg_lba_lo)
	if sec == 0 {sec = 1}
	return (cyl * IDE_CHS_HEADS + head) * IDE_CHS_SECTORS_PER_TRACK + sec - 1
}

ide_abort :: proc(ide: ^Ide) {
	ide_cancel_pio(ide)
	ide_dma_clear(ide)
	ide.state = .Idle
	ide.reg_error = IDE_ERROR_ABRT
	ide.reg_status = IDE_STATUS_DRDY | IDE_STATUS_ERR
	ide_raise_irq(ide)
}

ide_flush :: proc(ide: ^Ide) -> bool {
	return ide.bd.flush == nil || ide.bd.flush(ide.bd.ctx)
}

ide_checkpoint :: proc(ide: ^Ide) -> bool {
	if ide == nil {return true}
	if !ide_flush(ide) {
		ide.writeback_failed = true
		ide.writeback_deadline_tick = 0
		ide.reg_error = IDE_ERROR_ABRT
		ide.reg_status = IDE_STATUS_DRDY | IDE_STATUS_ERR
		return false
	}
	ide.writeback_pending = false
	ide.writeback_failed = false
	ide.writeback_deadline_tick = 0
	return true
}

ide_background_checkpoint :: proc(ide: ^Ide) -> bool {
	if ide == nil {return true}
	if ide_flush(ide) {
		ide.writeback_pending = false
		ide.writeback_failed = false
		ide.writeback_deadline_tick = 0
		return true
	}
	ide.writeback_deadline_tick =
		ide.now_tick + min(IDE_WRITEBACK_IDLE_TICKS, ~u64(0) - ide.now_tick)
	return false
}

@(private = "package")
ide_note_writeback :: proc(ide: ^Ide) {
	ide.writeback_pending = true
	ide.writeback_deadline_tick =
		ide.now_tick + min(IDE_WRITEBACK_IDLE_TICKS, ~u64(0) - ide.now_tick)
}

ide_load_sector :: proc(ide: ^Ide) -> bool {
	if ide.cmd != 0x20 || ide.pio_read_sectors <= 0 {
		ide_abort(ide)
		return false
	}
	if !ide.pio_read_loaded {
		byte_count := ide.pio_read_sectors * IDE_SECTOR_SIZE
		if byte_count > len(ide.dma_buf) ||
		   !ide.bd.read(ide.bd.ctx, ide.pio_read_start_lba, ide.dma_buf[:byte_count]) {
			ide_abort(ide)
			return false
		}
		ide.pio_read_loaded = true
	}
	sector := ide.pio_read_sectors - ide.pending
	if sector < 0 || sector >= ide.pio_read_sectors {
		ide_abort(ide)
		return false
	}
	offset := sector * IDE_SECTOR_SIZE
	copy(ide.buf[:], ide.dma_buf[offset:offset + IDE_SECTOR_SIZE])
	ide.buf_pos = 0
	return true
}

@(private = "file")
ide_command :: proc(ide: ^Ide, cmd: u8) {
	ide_acknowledge_irq(ide)
	ide_cancel_pio(ide)
	ide_dma_clear(ide)
	ide.cmd = cmd
	ide.reg_error = 0
	switch cmd {
	case 0xEC:
		// IDENTIFY
		ide_fill_identify(ide)
		ide.buf_pos = 0
		ide.pending = 1
		ide.state = .Idle
		ide.reg_status = IDE_STATUS_BSY
		ide_schedule(ide, .Identify_Ready, IDE_COMMAND_LATENCY_TICKS)
	case 0x20:
		// READ SECTORS
		ide.lba = ide_current_lba(ide)
		ide.pending = int(ide.reg_seccount)
		if ide.pending == 0 {ide.pending = 256}
		if ide.bd.read == nil ||
		   ide.lba > ide.bd.sector_count ||
		   u64(ide.pending) > ide.bd.sector_count - ide.lba {
			ide_abort(ide)
			return
		}
		ide.pio_read_start_lba = ide.lba
		ide.pio_read_sectors = ide.pending
		ide.pio_read_loaded = false
		ide.state = .Idle
		ide.reg_status = IDE_STATUS_BSY
		ide_schedule(ide, .Read_Ready, IDE_COMMAND_LATENCY_TICKS)
	case 0x30:
		// WRITE SECTORS
		if ide.writeback_failed {ide_abort(ide); return}
		ide.lba = ide_current_lba(ide)
		ide.pending = int(ide.reg_seccount)
		if ide.pending == 0 {ide.pending = 256}
		if ide.bd.write == nil ||
		   ide.lba > ide.bd.sector_count ||
		   u64(ide.pending) > ide.bd.sector_count - ide.lba {
			ide_abort(ide)
			return
		}
		ide.pio_start_lba = ide.lba
		ide.pio_staged_bytes = 0
		ide.buf_pos = 0
		ide.state = .Idle
		ide.reg_status = IDE_STATUS_BSY
		ide_schedule(ide, .Write_Ready, IDE_COMMAND_LATENCY_TICKS)
	case 0xC8, 0xC9:
		// READ DMA / READ DMA WITHOUT RETRY
		ide_begin_dma(ide, .Device_To_Memory)
	case 0xCA, 0xCB:
		// WRITE DMA / WRITE DMA WITHOUT RETRY
		if ide.writeback_failed {ide_abort(ide); return}
		ide_begin_dma(ide, .Memory_To_Device)
	case 0xEF:
		// SET FEATURES
		if ide.reg_features == 0x03 {
			if !ide_transfer_mode_supported(ide.reg_seccount) {
				ide_abort(ide)
				return
			}
			ide.transfer_mode = ide.reg_seccount
		}
		ide.state = .Idle
		ide.reg_status = IDE_STATUS_BSY
		ide_schedule(ide, .Command_Complete, IDE_COMMAND_LATENCY_TICKS)
	case 0x40:
		// READ VERIFY
		ide.state = .Idle
		ide.reg_status = IDE_STATUS_BSY
		ide_schedule(ide, .Command_Complete, IDE_COMMAND_LATENCY_TICKS)
	case 0x90:
		// EXECUTE DEVICE DIAGNOSTIC is broadcast across the channel.
		ide.state = .Idle
		ide.reg_status = IDE_STATUS_BSY
		ide_schedule(ide, .Diagnostic_Complete, IDE_COMMAND_LATENCY_TICKS)
	case 0x91:
		// INITIALIZE DEVICE PARAMETERS for the fixed 16/63 CHS geometry.
		if ide.reg_seccount != IDE_CHS_SECTORS_PER_TRACK ||
		   int(ide.reg_drive & 0x0F) + 1 != IDE_CHS_HEADS {
			ide_abort(ide)
			return
		}
		ide.state = .Idle
		ide.reg_status = IDE_STATUS_BSY
		ide_schedule(ide, .Command_Complete, IDE_COMMAND_LATENCY_TICKS)
	case 0xE7:
		// FLUSH CACHE
		ide.state = .Idle
		ide.reg_status = IDE_STATUS_BSY
		ide_schedule(ide, .Flush_Complete, IDE_COMMAND_LATENCY_TICKS)
	case:
		ide_abort(ide)
	}
}

@(private = "file")
ide_dma_clear :: proc(ide: ^Ide) {
	ide.dma_pending = false
	ide.dma_submitted = false
	ide.dma_direction = .Device_To_Memory
	ide.dma_lba = 0
	ide.dma_sectors = 0
	ide.dma_bytes = 0
}

@(private = "file")
ide_begin_dma :: proc(ide: ^Ide, direction: Bmide_Direction) {
	lba := ide_current_lba(ide)
	sectors := u32(ide.reg_seccount)
	if sectors == 0 {sectors = IDE_DMA_MAX_SECTORS}
	if ide.bd.read == nil ||
	   direction == .Memory_To_Device && ide.bd.write == nil ||
	   ide_transfer_mode_rate(ide.transfer_mode) == 0 ||
	   lba > ide.bd.sector_count ||
	   u64(sectors) > ide.bd.sector_count - lba {
		ide_abort(ide)
		return
	}
	ide.state = .Idle
	ide.dma_pending = true
	ide.dma_direction = direction
	ide.dma_lba = lba
	ide.dma_sectors = sectors
	ide.dma_bytes = int(sectors) * IDE_SECTOR_SIZE
	ide.reg_status = IDE_STATUS_BSY
}

ide_dma_set_taskfile_lba :: proc(ide: ^Ide, lba: u64) {
	if ide.reg_drive & 0x40 != 0 {
		ide.reg_lba_lo = u8(lba)
		ide.reg_lba_mid = u8(lba >> 8)
		ide.reg_lba_hi = u8(lba >> 16)
		ide.reg_drive = (ide.reg_drive & 0xF0) | u8(lba >> 24) & 0x0F
		return
	}
	sector := lba % 63 + 1
	track := lba / 63
	head := track % 16
	cylinder := track / 16
	ide.reg_lba_lo = u8(sector)
	ide.reg_lba_mid = u8(cylinder)
	ide.reg_lba_hi = u8(cylinder >> 8)
	ide.reg_drive = (ide.reg_drive & 0xF0) | u8(head)
}

@(private = "file")
ide_dma_begin_adapter :: proc(
	ctx: rawptr,
	channel: u8,
	direction: Bmide_Direction,
	byte_count: u32,
) -> bool {
	ide := (^Ide)(ctx)
	if channel != 0 ||
	   !ide.dma_pending ||
	   direction != ide.dma_direction ||
	   byte_count != u32(ide.dma_bytes) {
		return false
	}
	if direction == .Device_To_Memory {
		return ide.bd.read(ide.bd.ctx, ide.dma_lba, ide.dma_buf[:ide.dma_bytes])
	}
	return true
}

@(private = "file")
ide_dma_read_adapter :: proc(ctx: rawptr, channel: u8, offset: u32, data: []u8) -> bool {
	ide := (^Ide)(ctx)
	if channel != 0 ||
	   ide.dma_direction != .Device_To_Memory ||
	   offset > u32(ide.dma_bytes) ||
	   u32(len(data)) > u32(ide.dma_bytes) - offset {
		return false
	}
	copy(data, ide.dma_buf[int(offset):int(offset) + len(data)])
	return true
}

@(private = "file")
ide_dma_stage_write_adapter :: proc(ctx: rawptr, channel: u8, offset: u32, data: []u8) -> bool {
	ide := (^Ide)(ctx)
	if channel != 0 ||
	   ide.dma_direction != .Memory_To_Device ||
	   offset > u32(ide.dma_bytes) ||
	   u32(len(data)) > u32(ide.dma_bytes) - offset {
		return false
	}
	copy(ide.dma_buf[int(offset):int(offset) + len(data)], data)
	return true
}

@(private = "file")
ide_dma_commit_adapter :: proc(ctx: rawptr, channel: u8) -> bool {
	ide := (^Ide)(ctx)
	if channel != 0 || !ide.dma_pending {return false}
	if ide.dma_direction == .Memory_To_Device {
		if !ide.bd.write(ide.bd.ctx, ide.dma_lba, ide.dma_buf[:ide.dma_bytes]) {
			return false
		}
		ide_note_writeback(ide)
	}
	ide_dma_set_taskfile_lba(ide, ide.dma_lba + u64(ide.dma_sectors))
	ide.reg_seccount = 0
	ide.reg_error = 0
	ide.reg_status = IDE_STATUS_DRDY
	ide.state = .Idle
	ide_dma_clear(ide)
	ide_raise_irq(ide)
	return true
}

@(private = "file")
ide_dma_abort_adapter :: proc(ctx: rawptr, channel: u8) {
	ide := (^Ide)(ctx)
	if channel != 0 {return}
	ide_dma_clear(ide)
	ide.state = .Idle
	ide.reg_error = IDE_ERROR_ABRT
	ide.reg_status = IDE_STATUS_DRDY | IDE_STATUS_ERR
	ide_raise_irq(ide)
}

ide_bmide_request :: proc(ide: ^Ide) -> (Bmide_Request, bool) {
	if ide == nil || !ide.dma_pending || ide.dma_submitted {return {}, false}
	return Bmide_Request {
			direction = ide.dma_direction,
			byte_count = u32(ide.dma_bytes),
			device = {
				ctx = ide,
				begin = ide_dma_begin_adapter,
				read = ide_dma_read_adapter,
				stage_write = ide_dma_stage_write_adapter,
				commit = ide_dma_commit_adapter,
				abort = ide_dma_abort_adapter,
			},
		},
		true
}

ide_bmide_mark_submitted :: proc(ide: ^Ide) {
	if ide != nil && ide.dma_pending {ide.dma_submitted = true}
}

ide_bmide_pending :: proc(ide: ^Ide) -> bool {
	return ide != nil && ide.dma_pending
}

ide_irq_enabled :: proc(ide: ^Ide) -> bool {
	return(
		ide != nil &&
		ide.channel_enabled &&
		ide.reg_ctrl & 0x02 == 0 \
	)
}

@(private = "file")
ide_data_read :: proc(ide: ^Ide, size: u8) -> u32 {
	if ide.state != .Data_In {return 0xFFFF}
	v: u32 = 0
	for i in 0 ..< int(size) {
		if ide.buf_pos >= 512 {break}
		v |= u32(ide.buf[ide.buf_pos]) << (8 * uint(i))
		ide.buf_pos += 1
	}
	if ide.buf_pos >= 512 {
		ide.pending -= 1
		ide.reg_seccount = u8(ide.pending)
		if ide.pending > 0 && ide.cmd == 0x20 {
			ide.lba += 1
			ide.state = .Idle
			ide.reg_status = IDE_STATUS_BSY
			ide_schedule(ide, .Read_Ready, IDE_PIO_SECTOR_TICKS)
		} else {
			ide.state = .Idle
			ide.reg_status = IDE_STATUS_DRDY
			ide_dma_set_taskfile_lba(ide, ide.lba + 1)
		}
	}
	return v
}

@(private = "file")
ide_data_write :: proc(ide: ^Ide, size: u8, val: u32) {
	if ide.state != .Data_Out {return}
	v := val
	for _ in 0 ..< int(size) {
		if ide.buf_pos >= 512 {break}
		ide.dma_buf[ide.pio_staged_bytes + ide.buf_pos] = u8(v)
		v >>= 8
		ide.buf_pos += 1
	}
	if ide.buf_pos >= 512 {
		ide.pio_staged_bytes += IDE_SECTOR_SIZE
		ide.pending -= 1
		ide.reg_seccount = u8(ide.pending)
		ide.state = .Idle
		ide.reg_status = IDE_STATUS_BSY
		if ide.pending > 0 {
			ide.lba += 1
			ide.buf_pos = 0
			ide_schedule(ide, .Write_Ready, IDE_PIO_SECTOR_TICKS)
		} else {
			ide_schedule(ide, .Write_Commit, IDE_PIO_SECTOR_TICKS)
		}
	}
}

@(private = "file")
ide_put_word :: proc(buf: ^[512]u8, w: int, v: u16) {
	buf[w * 2] = u8(v)
	buf[w * 2 + 1] = u8(v >> 8)
}

@(private = "file")
ide_chs_cylinders :: proc(sector_count: u64) -> u16 {
	sectors_per_cylinder := u64(IDE_CHS_HEADS * IDE_CHS_SECTORS_PER_TRACK)
	cylinders := min(sector_count / sectors_per_cylinder, u64(IDE_CHS_MAX_CYLINDERS))
	return u16(cylinders)
}

@(private = "file")
ide_fill_identify :: proc(ide: ^Ide) {
	ide.buf = {}
	cylinders := ide_chs_cylinders(ide.bd.sector_count)
	ide_put_word(&ide.buf, 0, 0x0040)
	ide_put_word(&ide.buf, 1, cylinders)
	ide_put_word(&ide.buf, 3, IDE_CHS_HEADS)
	ide_put_word(&ide.buf, 6, IDE_CHS_SECTORS_PER_TRACK)
	ide_put_word(&ide.buf, 47, 0x8000)
	ide_put_word(&ide.buf, 49, 0x0F00) // DMA, LBA, and IORDY supported
	validity: u16 = 0x0006 // words 64-70 and 88 are valid
	if cylinders != 0 {
		validity |= 0x0001
		ide_put_word(&ide.buf, 54, cylinders)
		ide_put_word(&ide.buf, 55, IDE_CHS_HEADS)
		ide_put_word(&ide.buf, 56, IDE_CHS_SECTORS_PER_TRACK)
		chs_sectors := u32(cylinders) * IDE_CHS_HEADS * IDE_CHS_SECTORS_PER_TRACK
		ide_put_word(&ide.buf, 57, u16(chs_sectors))
		ide_put_word(&ide.buf, 58, u16(chs_sectors >> 16))
	}
	ide_put_word(&ide.buf, 53, validity)
	mwdma: u16 = 0x0007
	if ide.transfer_mode & 0xF8 == 0x20 {
		mwdma |= u16(1) << (8 + uint(ide.transfer_mode & 7))
	}
	ide_put_word(&ide.buf, 63, mwdma)
	ide_put_word(&ide.buf, 64, 0x0003) // PIO modes 3 and 4
	ide_put_word(&ide.buf, 65, 120)
	ide_put_word(&ide.buf, 66, 120)
	ide_put_word(&ide.buf, 67, 120)
	ide_put_word(&ide.buf, 68, 120)
	udma: u16 = u16((u32(1) << (IDE_UDMA_MODE + 1)) - 1)
	if ide.transfer_mode & 0xF8 == 0x40 {
		udma |= u16(1) << (8 + uint(ide.transfer_mode & 7))
	}
	ide_put_word(&ide.buf, 88, udma)
	sectors := ide.bd.sector_count
	if sectors > 0x0FFF_FFFF {sectors = 0x0FFF_FFFF}
	ide_put_word(&ide.buf, 60, u16(sectors & 0xFFFF))
	ide_put_word(&ide.buf, 61, u16(sectors >> 16))
	// model in words 27-46, bytes swapped per word
	model := "RETVRN99 VDISK"
	for w in 0 ..< 20 {
		c0: u8 = 0x20
		c1: u8 = 0x20
		if 2 * w < len(model) {c0 = model[2 * w]}
		if 2 * w + 1 < len(model) {c1 = model[2 * w + 1]}
		ide_put_word(&ide.buf, 27 + w, u16(c0) << 8 | u16(c1))
	}
}
