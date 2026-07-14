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
}

ide_next_deadline :: proc(ide: ^Ide) -> (u64, bool) {
	if ide == nil || ide.deadline_action == .None {return 0, false}
	return ide.deadline_tick, true
}

@(private = "file")
ide_publish_data_in :: proc(ide: ^Ide) {
	ide.state = .Data_In
	ide.reg_status = IDE_STATUS_DRDY | IDE_STATUS_DRQ
	ide_raise_irq(ide)
}

@(private = "file")
ide_complete_write :: proc(ide: ^Ide) {
	if ide.pio_staged_bytes <= 0 ||
	   !ide.bd.write(ide.bd.ctx, ide.pio_start_lba, ide.dma_buf[:ide.pio_staged_bytes]) ||
	   !ide_flush(ide) {
		ide_abort(ide)
		return
	}
	sectors := u64(ide.pio_staged_bytes / IDE_SECTOR_SIZE)
	ide_dma_set_taskfile_lba(ide, ide.pio_start_lba + sectors)
	ide.reg_seccount = 0
	ide.state = .Idle
	ide.reg_status = IDE_STATUS_DRDY
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
		if ide_load_sector(ide) {ide_publish_data_in(ide)}
	case .Write_Ready:
		ide.buf_pos = 0
		ide.state = .Data_Out
		ide.reg_status = IDE_STATUS_DRDY | IDE_STATUS_DRQ
		if ide.pio_staged_bytes > 0 {ide_raise_irq(ide)}
	case .Write_Commit:
		ide_complete_write(ide)
	case .Command_Complete:
		ide.state = .Idle
		ide.reg_status = IDE_STATUS_DRDY
		ide_raise_irq(ide)
	case .Flush_Complete:
		if !ide_flush(ide) {ide_abort(ide); return}
		ide.state = .Idle
		ide.reg_status = IDE_STATUS_DRDY
		ide_raise_irq(ide)
	case .None:
	}
}

ide_advance_to :: proc(ide: ^Ide, tick: u64) {
	if ide == nil || tick < ide.now_tick {return}
	for ide.deadline_action != .None && ide.deadline_tick <= tick {
		ide.now_tick = ide.deadline_tick
		action := ide.deadline_action
		ide.deadline_action = .None
		ide_service_deadline(ide, action)
	}
	ide.now_tick = tick
}
