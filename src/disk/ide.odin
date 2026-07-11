// SPDX-License-Identifier: GPL-3.0-only
package disk

// Canal IDE primario (0x1F0-0x1F7, 0x3F6), solo maestro, PIO.

IDE_STATUS_ERR :: 0x01
IDE_STATUS_DRQ :: 0x08
IDE_STATUS_DRDY :: 0x40
IDE_STATUS_BSY :: 0x80

IDE_ERROR_ABRT :: 0x04

Ide_State :: enum {
	Idle,
	Data_In,
	Data_Out,
}

Ide :: struct {
	bd:           Block_Device,
	state:        Ide_State,
	buf:          [512]u8,
	buf_pos:      int,
	pending:      int, // sectores restantes de la transferencia
	lba:          u64,
	cmd:          u8,
	// registros
	reg_error:    u8,
	reg_features: u8,
	reg_seccount: u8,
	reg_lba_lo:   u8,
	reg_lba_mid:  u8,
	reg_lba_hi:   u8,
	reg_drive:    u8,
	reg_status:   u8,
	reg_ctrl:     u8,
	// IRQ14 al completar comandos
	irq:          proc(ctx: rawptr),
	irq_ctx:      rawptr,
}

ide_init :: proc(ide: ^Ide, bd: Block_Device) {
	ide.bd = bd
	ide.state = .Idle
	ide.reg_status = IDE_STATUS_DRDY
}

ide_io_read :: proc(ide: ^Ide, port: u16, size: u8) -> u32 {
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
	case 0x1F7, 0x3F6:
		return u32(ide.reg_status)
	}
	return 0xFF
}

ide_io_write :: proc(ide: ^Ide, port: u16, size: u8, val: u32) {
	switch port {
	case 0x1F0:
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
		ide_command(ide, u8(val))
	case 0x3F6:
		ide.reg_ctrl = u8(val)
	}
}

@(private = "file")
ide_raise_irq :: proc(ide: ^Ide) {
	if ide.reg_ctrl & 0x02 != 0 { return } // nIEN
	if ide.irq != nil { ide.irq(ide.irq_ctx) }
}

// bit6 del registro drive/head elige LBA28; si no, CHS con 16 cabezas / 63 spt
@(private = "file")
ide_current_lba :: proc(ide: ^Ide) -> u64 {
	if ide.reg_drive & 0x40 != 0 {
		return u64(ide.reg_lba_lo) |
			u64(ide.reg_lba_mid) << 8 |
			u64(ide.reg_lba_hi) << 16 |
			u64(ide.reg_drive & 0x0F) << 24
	}
	cyl := u64(ide.reg_lba_hi) << 8 | u64(ide.reg_lba_mid)
	head := u64(ide.reg_drive & 0x0F)
	sec := u64(ide.reg_lba_lo)
	if sec == 0 { sec = 1 }
	return (cyl * 16 + head) * 63 + sec - 1
}

@(private = "file")
ide_abort :: proc(ide: ^Ide) {
	ide.state = .Idle
	ide.reg_error = IDE_ERROR_ABRT
	ide.reg_status = IDE_STATUS_DRDY | IDE_STATUS_ERR
	ide_raise_irq(ide)
}

@(private = "file")
ide_load_sector :: proc(ide: ^Ide) -> bool {
	if ide.lba >= ide.bd.sector_count || !ide.bd.read(ide.bd.ctx, ide.lba, ide.buf[:]) {
		ide_abort(ide)
		return false
	}
	ide.buf_pos = 0
	return true
}

@(private = "file")
ide_command :: proc(ide: ^Ide, cmd: u8) {
	ide.cmd = cmd
	ide.reg_error = 0
	switch cmd {
	case 0xEC: // IDENTIFY
		ide_fill_identify(ide)
		ide.buf_pos = 0
		ide.pending = 1
		ide.state = .Data_In
		ide.reg_status = IDE_STATUS_DRDY | IDE_STATUS_DRQ
		ide_raise_irq(ide)
	case 0x20: // READ SECTORS
		ide.lba = ide_current_lba(ide)
		ide.pending = int(ide.reg_seccount)
		if ide.pending == 0 { ide.pending = 256 }
		if !ide_load_sector(ide) { return }
		ide.state = .Data_In
		ide.reg_status = IDE_STATUS_DRDY | IDE_STATUS_DRQ
		ide_raise_irq(ide)
	case 0x30: // WRITE SECTORS
		ide.lba = ide_current_lba(ide)
		ide.pending = int(ide.reg_seccount)
		if ide.pending == 0 { ide.pending = 256 }
		ide.buf_pos = 0
		ide.state = .Data_Out
		ide.reg_status = IDE_STATUS_DRDY | IDE_STATUS_DRQ
	case 0xEF, 0x40, 0xE7: // SET FEATURES / READ VERIFY / FLUSH
		ide.state = .Idle
		ide.reg_status = IDE_STATUS_DRDY
		ide_raise_irq(ide)
	case:
		ide_abort(ide)
	}
}

@(private = "file")
ide_data_read :: proc(ide: ^Ide, size: u8) -> u32 {
	if ide.state != .Data_In { return 0xFFFF }
	v: u32 = 0
	for i in 0 ..< int(size) {
		if ide.buf_pos >= 512 { break }
		v |= u32(ide.buf[ide.buf_pos]) << (8 * uint(i))
		ide.buf_pos += 1
	}
	if ide.buf_pos >= 512 {
		ide.pending -= 1
		ide.reg_seccount = u8(ide.pending)
		if ide.pending > 0 && ide.cmd == 0x20 {
			ide.lba += 1
			if ide_load_sector(ide) { ide_raise_irq(ide) }
		} else {
			ide.state = .Idle
			ide.reg_status = IDE_STATUS_DRDY
		}
	}
	return v
}

@(private = "file")
ide_data_write :: proc(ide: ^Ide, size: u8, val: u32) {
	if ide.state != .Data_Out { return }
	v := val
	for _ in 0 ..< int(size) {
		if ide.buf_pos >= 512 { break }
		ide.buf[ide.buf_pos] = u8(v)
		v >>= 8
		ide.buf_pos += 1
	}
	if ide.buf_pos >= 512 {
		if ide.lba >= ide.bd.sector_count || !ide.bd.write(ide.bd.ctx, ide.lba, ide.buf[:]) {
			ide_abort(ide)
			return
		}
		ide.pending -= 1
		ide.reg_seccount = u8(ide.pending)
		ide_raise_irq(ide)
		if ide.pending > 0 {
			ide.lba += 1
			ide.buf_pos = 0
		} else {
			ide.state = .Idle
			ide.reg_status = IDE_STATUS_DRDY
		}
	}
}

@(private = "file")
ide_put_word :: proc(buf: ^[512]u8, w: int, v: u16) {
	buf[w * 2] = u8(v)
	buf[w * 2 + 1] = u8(v >> 8)
}

@(private = "file")
ide_fill_identify :: proc(ide: ^Ide) {
	ide.buf = {}
	ide_put_word(&ide.buf, 0, 0x0040)
	ide_put_word(&ide.buf, 1, 16383) // cilindros
	ide_put_word(&ide.buf, 3, 16)    // cabezas
	ide_put_word(&ide.buf, 6, 63)    // sectores por pista
	ide_put_word(&ide.buf, 47, 0x8000)
	ide_put_word(&ide.buf, 49, 0x0200) // LBA soportado
	sectors := ide.bd.sector_count
	if sectors > 0x0FFF_FFFF { sectors = 0x0FFF_FFFF }
	ide_put_word(&ide.buf, 60, u16(sectors & 0xFFFF))
	ide_put_word(&ide.buf, 61, u16(sectors >> 16))
	// modelo en palabras 27-46, bytes intercambiados por palabra
	model := "MATE98 VDISK"
	for w in 0 ..< 20 {
		c0: u8 = 0x20
		c1: u8 = 0x20
		if 2 * w < len(model) { c0 = model[2 * w] }
		if 2 * w + 1 < len(model) { c1 = model[2 * w + 1] }
		ide_put_word(&ide.buf, 27 + w, u16(c0) << 8 | u16(c1))
	}
}
