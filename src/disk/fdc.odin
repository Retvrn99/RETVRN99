// SPDX-License-Identifier: GPL-3.0-only
package disk

// Subset of the 82077AA used by SeaBIOS (upstream src/hw/floppy.c,
// https://github.com/coreboot/seabios).
// Ports 0x3F0-0x3F5 and 0x3F7; READ/WRITE execution uses sector DMA transactions.

FDC_MASTER_CLOCK_HZ :: u64(6_600_000_000)

FDC_MSR_RQM :: 0x80
FDC_MSR_DIO :: 0x40
FDC_MSR_BUSY :: 0x10

FDC_DOR_RESET :: 0x04
FDC_DOR_IRQ :: 0x08

FDC_ST0_SEEK_END :: 0x20
FDC_ST0_ABNORMAL :: 0x40
FDC_ST0_INVALID :: 0x80
FDC_ST1_EOC :: 0x80
FDC_ST1_NO_DATA :: 0x04
FDC_ST1_MISSING_AM :: 0x01

FDC_VERSION_82077 :: 0x90

Fdc_Phase :: enum {
	Idle,
	Param,
	Exec,
	Result,
}

Fdc :: struct {
	img:          Floppy_Img,
	has_media:    bool,
	dskchg:       bool,
	dor:          u8,
	ccr:          u8,
	phase:        Fdc_Phase,
	cmd:          u8,
	params:       [8]u8,
	params_need:  int,
	params_got:   int,
	result:       [7]u8,
	result_len:   int,
	result_pos:   int,
	pcn:          u8,
	int_pending:  bool,
	int_st0:      u8,
	reset_sense:  int, // SENSE INTERRUPTs pending after reset (4-drive poll)
	now_tick:          u64,
	next_tick:         u64,
	deadline_pending:  bool,
	rw_write:          bool,
	rw_mt:             bool,
	rw_unit:           u8,
	rw_c, rw_h, rw_s:  int,
	rw_eot:            int,
	rw_pos:            int,
	rw_buf:            [FLOPPY_SECTOR]u8,
	// IRQ6 toward the PIC
	irq:          proc(ctx: rawptr),
	irq_ctx:      rawptr,
	// DMA channel 2: installed by machine to avoid importing that package
	dma_to_mem:   proc(ctx: rawptr, data: []u8) -> int,
	dma_from_mem: proc(ctx: rawptr, buf: []u8) -> int,
	dma_tc:       proc(ctx: rawptr) -> bool,
	dma_ctx:      rawptr,
}

fdc_init :: proc(f: ^Fdc) {
	f^ = {}
}

fdc_set_media :: proc(f: ^Fdc, raw: []u8) -> bool {
	if f.has_media { fdc_eject_media(f) }
	if !floppy_img_load(&f.img, raw) { return false }
	f.has_media = true
	f.dskchg = true
	return true
}

fdc_eject_media :: proc(f: ^Fdc) {
	if !f.has_media { return }
	f.deadline_pending = false
	if f.phase == .Exec {f.phase = .Idle}
	floppy_img_eject(&f.img)
	f.has_media = false
	f.dskchg = true
}

@(private = "file")
fdc_raise_irq :: proc(f: ^Fdc) {
	if f.dor & FDC_DOR_IRQ == 0 { return }
	if f.irq != nil { f.irq(f.irq_ctx) }
}

@(private = "file")
fdc_reset :: proc(f: ^Fdc) {
	f.deadline_pending = false
	f.phase = .Idle
	f.int_pending = false
	f.reset_sense = 4
	fdc_raise_irq(f)
}

fdc_out :: proc(f: ^Fdc, port: u16, v: u8) {
	switch port {
	case 0x3F2: // DOR
		old := f.dor
		f.dor = v
		if v & FDC_DOR_RESET == 0 {
			f.deadline_pending = false
			f.phase = .Idle
		} else if old & FDC_DOR_RESET == 0 {
			fdc_reset(f)
		}
	case 0x3F4: // DSR: bit7 = software reset, self-clearing
		if v & 0x80 != 0 && f.dor & FDC_DOR_RESET != 0 { fdc_reset(f) }
	case 0x3F5:
		fdc_fifo_write(f, v)
	case 0x3F7: // CCR: data rate
		f.ccr = v
	}
}

fdc_in :: proc(f: ^Fdc, port: u16) -> u8 {
	switch port {
	case 0x3F2:
		return f.dor
	case 0x3F4:
		return fdc_msr(f)
	case 0x3F5:
		return fdc_fifo_read(f)
	case 0x3F7: // DIR: bit7 = media change
		return f.dskchg ? 0x80 : 0x00
	}
	return 0xFF // SRA/SRB/TDR not modeled
}

@(private = "file")
fdc_msr :: proc(f: ^Fdc) -> u8 {
	if f.dor & FDC_DOR_RESET == 0 { return 0 }
	switch f.phase {
	case .Idle:
		return FDC_MSR_RQM
	case .Param:
		return FDC_MSR_RQM | FDC_MSR_BUSY
	case .Exec:
		return FDC_MSR_BUSY
	case .Result:
		return FDC_MSR_RQM | FDC_MSR_DIO | FDC_MSR_BUSY
	}
	return FDC_MSR_RQM
}

// parameter count; -1 = invalid command
@(private = "file")
fdc_param_count :: proc(cmd: u8) -> int {
	if cmd == 0x10 { return 0 } // VERSION takes no bit mask
	switch cmd & 0x1F {
	case 0x03: return 2 // SPECIFY
	case 0x07: return 1 // RECALIBRATE
	case 0x08: return 0 // SENSE INTERRUPT
	case 0x0F: return 2 // SEEK
	case 0x06: return 8 // READ (MT/MFM/SK masked off)
	case 0x05: return 8 // WRITE
	case 0x0A: return 1 // READ ID
	}
	return -1
}

@(private = "file")
fdc_fifo_write :: proc(f: ^Fdc, v: u8) {
	switch f.phase {
	case .Idle:
		f.cmd = v
		n := fdc_param_count(v)
		if n < 0 {
			fdc_finish_invalid(f)
			return
		}
		f.params_need = n
		f.params_got = 0
		if n == 0 {
			fdc_execute(f)
		} else {
			f.phase = .Param
		}
	case .Param:
		f.params[f.params_got] = v
		f.params_got += 1
		if f.params_got >= f.params_need { fdc_execute(f) }
	case .Exec, .Result: // out-of-phase write: ignored
	}
}

@(private = "file")
fdc_fifo_read :: proc(f: ^Fdc) -> u8 {
	if f.phase != .Result { return 0xFF }
	v := f.result[f.result_pos]
	f.result_pos += 1
	if f.result_pos >= f.result_len { f.phase = .Idle }
	return v
}

@(private = "file")
fdc_finish_invalid :: proc(f: ^Fdc) {
	f.result[0] = FDC_ST0_INVALID
	f.result_len = 1
	f.result_pos = 0
	f.phase = .Result
}

@(private = "file")
fdc_finish_result :: proc(f: ^Fdc, bytes: []u8, with_irq: bool) {
	copy(f.result[:], bytes)
	f.result_len = len(bytes)
	f.result_pos = 0
	f.phase = .Result
	if with_irq { fdc_raise_irq(f) }
}

@(private = "file")
fdc_execute :: proc(f: ^Fdc) {
	f.phase = .Exec
	switch {
	case f.cmd == 0x10: // VERSION
		fdc_finish_result(f, []u8{FDC_VERSION_82077}, false)
	case f.cmd & 0x1F == 0x03: // SPECIFY: timings ignored
		f.phase = .Idle
	case f.cmd & 0x1F == 0x07: // RECALIBRATE
		f.pcn = 0
		fdc_seek_done(f, f.params[0] & 3)
	case f.cmd & 0x1F == 0x0F: // SEEK
		f.pcn = f.params[1]
		fdc_seek_done(f, f.params[0] & 7)
	case f.cmd & 0x1F == 0x08: // SENSE INTERRUPT
		fdc_sense_interrupt(f)
	case f.cmd & 0x1F == 0x0A: // READ ID
		fdc_read_id(f)
	case f.cmd & 0x1F == 0x06: // READ
		fdc_rw(f, false)
	case f.cmd & 0x1F == 0x05: // WRITE
		fdc_rw(f, true)
	case:
		fdc_finish_invalid(f)
	}
}

// the step pulse clears DSKCHG when media is present
@(private = "file")
fdc_seek_done :: proc(f: ^Fdc, unit_head: u8) {
	if f.has_media { f.dskchg = false }
	f.int_st0 = FDC_ST0_SEEK_END | unit_head
	f.int_pending = true
	f.phase = .Idle
	fdc_raise_irq(f)
}

@(private = "file")
fdc_sense_interrupt :: proc(f: ^Fdc) {
	if f.reset_sense > 0 {
		unit := u8(4 - f.reset_sense)
		f.reset_sense -= 1
		fdc_finish_result(f, []u8{0xC0 | unit, 0}, false)
	} else if f.int_pending {
		f.int_pending = false
		fdc_finish_result(f, []u8{f.int_st0, f.pcn}, false)
	} else {
		fdc_finish_invalid(f)
	}
}

@(private = "file")
fdc_read_id :: proc(f: ^Fdc) {
	unit_head := f.params[0] & 7
	if !f.has_media {
		fdc_finish_result(f, []u8{
			FDC_ST0_ABNORMAL | unit_head, FDC_ST1_MISSING_AM, 0, 0, 0, 0, 0,
		}, true)
		return
	}
	head := (unit_head >> 2) & 1
	fdc_finish_result(f, []u8{unit_head, 0, 0, f.pcn, head, 1, 2}, true)
}

@(private = "file")
fdc_rw :: proc(f: ^Fdc, is_write: bool) {
	f.rw_unit = f.params[0] & 3
	f.rw_mt = f.cmd & 0x80 != 0
	f.rw_c = int(f.params[1])
	f.rw_h = int(f.params[2])
	f.rw_s = int(f.params[3])
	f.rw_eot = int(f.params[5])
	f.rw_write = is_write
	f.rw_pos = 0

	_, chs_ok := floppy_img_offset(f.rw_c, f.rw_h, f.rw_s)
	if !f.has_media || !chs_ok {
		fdc_finish_result(f, []u8{
			FDC_ST0_ABNORMAL | (f.params[0] & 7), FDC_ST1_NO_DATA, 0,
			f.params[1], f.params[2], f.params[3], f.params[4],
		}, true)
		return
	}
	if !fdc_prepare_sector(f) {return}
	fdc_schedule_unit(f)
}

@(private = "file")
fdc_schedule_unit :: proc(f: ^Fdc) {
	f.deadline_pending = true
	f.next_tick = f.now_tick + min(u64(1), ~u64(0) - f.now_tick)
}

@(private = "file")
fdc_prepare_sector :: proc(f: ^Fdc) -> bool {
	sec, ok := floppy_img_sector(&f.img, f.rw_c, f.rw_h, f.rw_s)
	if !ok {
		fdc_finish_result(f, []u8{
			FDC_ST0_ABNORMAL | u8(f.rw_h) << 2 | f.rw_unit,
			FDC_ST1_NO_DATA,
			0,
			u8(f.rw_c),
			u8(f.rw_h),
			u8(f.rw_s),
			f.params[4],
		}, true)
		return false
	}
	f.rw_pos = 0
	if f.rw_write {f.rw_buf = {}} else {copy(f.rw_buf[:], sec)}
	return true
}

@(private = "file")
fdc_finish_rw :: proc(f: ^Fdc, st0, st1: u8) {
	f.deadline_pending = false
	fdc_finish_result(f, []u8{
		st0 | u8(f.rw_h) << 2 | f.rw_unit,
		st1,
		0,
		u8(f.rw_c),
		u8(f.rw_h),
		u8(f.rw_s),
		f.params[4],
	}, true)
}

@(private = "file")
fdc_advance_chs :: proc(f: ^Fdc) -> (end_of_cylinder: bool) {
	if f.rw_s == f.rw_eot || f.rw_s >= FLOPPY_SPT {
		f.rw_s = 1
		if f.rw_mt && f.rw_h == 0 {
			f.rw_h = 1
		} else {
			if f.rw_mt {f.rw_h = 0}
			f.rw_c += 1
			return true
		}
	} else {
		f.rw_s += 1
	}
	return false
}

@(private = "file")
fdc_transfer_unit :: proc(f: ^Fdc) {
	transferred := 0
	if f.rw_write {
		if f.dma_from_mem != nil {
			transferred = f.dma_from_mem(f.dma_ctx, f.rw_buf[f.rw_pos:])
		}
	} else if f.dma_to_mem != nil {
		transferred = f.dma_to_mem(f.dma_ctx, f.rw_buf[f.rw_pos:])
	}
	if transferred <= 0 {
		fdc_schedule_unit(f)
		return
	}
	f.rw_pos += transferred
	if f.rw_pos < FLOPPY_SECTOR {
		if f.dma_tc != nil && f.dma_tc(f.dma_ctx) {fdc_finish_rw(f, 0, 0); return}
		fdc_schedule_unit(f)
		return
	}
	if f.rw_write {
		sec, ok := floppy_img_sector(&f.img, f.rw_c, f.rw_h, f.rw_s)
		if !ok {fdc_finish_rw(f, FDC_ST0_ABNORMAL, FDC_ST1_NO_DATA); return}
		copy(sec, f.rw_buf[:])
		f.img.dirty = true
	}
	tc := f.dma_tc != nil && f.dma_tc(f.dma_ctx)
	end_of_cylinder := fdc_advance_chs(f)
	if tc {fdc_finish_rw(f, 0, 0); return}
	if end_of_cylinder {fdc_finish_rw(f, FDC_ST0_ABNORMAL, FDC_ST1_EOC); return}
	if !fdc_prepare_sector(f) {return}
	fdc_schedule_unit(f)
}

fdc_next_deadline :: proc(f: ^Fdc) -> (u64, bool) {
	if f == nil || !f.deadline_pending {return 0, false}
	return f.next_tick, true
}

fdc_advance_to :: proc(f: ^Fdc, tick: u64) {
	if f == nil || tick < f.now_tick {return}
	for f.deadline_pending && f.next_tick <= tick {
		f.now_tick = f.next_tick
		f.deadline_pending = false
		fdc_transfer_unit(f)
	}
	f.now_tick = tick
}
