// SPDX-License-Identifier: GPL-3.0-only
package disk

ide_schedule :: proc(ide: ^Ide, action: Ide_Deadline_Action, delay: u64) {
	ide.deadline_action = action
	ide.deadline_tick = ide.now_tick + min(delay, ~u64(0) - ide.now_tick)
}

ide_cancel_pio :: proc(ide: ^Ide) {
	ide.deadline_action = .None
	ide.deadline_tick = 0
	ide.pio_start_lba = 0
	ide.pio_staged_bytes = 0
	ide.pio_read_start_lba = 0
	ide.pio_read_sectors = 0
	ide.pio_read_loaded = false
	ide.pio_block_remaining = 0
}

@(private = "file")
ide_pio_block_sector_count :: proc(ide: ^Ide) -> int {
	if ide.cmd == 0xC4 || ide.cmd == 0xC5 {
		return min(ide.pending, int(ide.multiple_sector_count))
	}
	return min(ide.pending, 1)
}

ide_next_deadline :: proc(ide: ^Ide) -> (u64, bool) {
	if ide == nil {return 0, false}
	command_pending := ide.deadline_action != .None
	writeback_pending := ide.writeback_pending && ide.writeback_deadline_tick != 0
	if !command_pending {return ide.writeback_deadline_tick, writeback_pending}
	if !writeback_pending {return ide.deadline_tick, true}
	return min(ide.deadline_tick, ide.writeback_deadline_tick), true
}

@(private = "file")
ide_publish_data_in :: proc(ide: ^Ide) {
	ide.state = .Data_In
	ide.reg_status = IDE_STATUS_READY | IDE_STATUS_DRQ
	ide_raise_irq(ide)
}

@(private = "file")
ide_complete_write :: proc(ide: ^Ide) {
	if ide.pio_staged_bytes <= 0 ||
	   !ide.bd.write(ide.bd.ctx, ide.pio_start_lba, ide.dma_buf[:ide.pio_staged_bytes]) {
		ide_record_failure(ide, .Pio_Write, ide.pio_start_lba, ide.pio_staged_bytes)
		ide_abort(ide)
		return
	}
	ide.activity_generation += 1
	ide_note_writeback(ide)
	sectors := u64(ide.pio_staged_bytes / IDE_SECTOR_SIZE)
	ide_dma_set_taskfile_lba(ide, ide.pio_start_lba + sectors)
	ide.reg_seccount = 0
	ide.state = .Idle
	ide.reg_status = IDE_STATUS_READY
	ide.pio_start_lba = 0
	ide.pio_staged_bytes = 0
	ide_raise_irq(ide)
}

@(private = "file")
ide_service_deadline :: proc(ide: ^Ide, action: Ide_Deadline_Action) {
	switch action {
	case .Identify_Ready:
		ide_publish_data_in(ide)
	case .Read_Ready:
		ide.pio_block_remaining = ide_pio_block_sector_count(ide)
		if ide_load_sector(ide) {ide_publish_data_in(ide)}
	case .Write_Ready:
		ide.pio_block_remaining = ide_pio_block_sector_count(ide)
		ide.buf_pos = 0
		ide.state = .Data_Out
		ide.reg_status = IDE_STATUS_READY | IDE_STATUS_DRQ
		if ide.pio_staged_bytes > 0 {ide_raise_irq(ide)}
	case .Write_Commit:
		ide_complete_write(ide)
	case .Command_Complete:
		ide.state = .Idle
		ide.reg_status = IDE_STATUS_READY
		ide_raise_irq(ide)
	case .Diagnostic_Complete:
		ide.state = .Idle
		ide_reset_signature(ide)
		ide_raise_irq(ide)
	case .Flush_Complete:
		if !ide_checkpoint(ide) {ide_abort(ide); return}
		ide.state = .Idle
		ide.reg_status = IDE_STATUS_READY
		ide_raise_irq(ide)
	case .None:
	}
}

ide_advance_to :: proc(ide: ^Ide, tick: u64) {
	if ide == nil || tick < ide.now_tick {return}
	for {
		deadline, pending := ide_next_deadline(ide)
		if !pending || deadline > tick {break}
		ide.now_tick = deadline
		if ide.deadline_action != .None && ide.deadline_tick == deadline {
			action := ide.deadline_action
			ide.deadline_action = .None
			ide_service_deadline(ide, action)
		}
		if ide.writeback_pending && ide.writeback_deadline_tick == deadline {
			_ = ide_background_checkpoint(ide)
		}
	}
	ide.now_tick = tick
}
