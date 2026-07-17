// SPDX-License-Identifier: GPL-3.0-only
package vga

import persona "../persona"

GSW_VGA_CONTROL_BASE :: u64(0xF100_0000)
GSW_VGA_CONTROL_SIZE :: u64(0x1000)
GSW_VGA_INTERFACE_VERSION :: u32(2)
GSW_VGA_RING_MIN_SIZE :: u32(256)
GSW_VGA_RING_MAX_SIZE :: u32(1024 * 1024)
GSW_VGA_COMMAND_VERSION :: u16(1)
GSW_VGA_COMMAND_VERSION_2 :: u16(2)
GSW_VGA_MAX_SOFTWARE_PIXELS :: u64(4096 * 2160)
GSW_VGA_MAX_COMMANDS_PER_DOORBELL :: 1024

GSW_VGA_REG_ID :: u32(0x00)
GSW_VGA_REG_VERSION :: u32(0x04)
GSW_VGA_REG_CAPABILITIES :: u32(0x08)
GSW_VGA_REG_STATUS :: u32(0x0C)
GSW_VGA_REG_RING_GPA_LOW :: u32(0x10)
GSW_VGA_REG_RING_GPA_HIGH :: u32(0x14)
GSW_VGA_REG_RING_SIZE :: u32(0x18)
GSW_VGA_REG_RING_HEAD :: u32(0x1C)
GSW_VGA_REG_RING_TAIL :: u32(0x20)
GSW_VGA_REG_DOORBELL :: u32(0x24)
GSW_VGA_REG_IRQ_ENABLE :: u32(0x28)
GSW_VGA_REG_IRQ_STATUS :: u32(0x2C)
GSW_VGA_REG_FENCE_LOW :: u32(0x30)
GSW_VGA_REG_FENCE_HIGH :: u32(0x34)

GSW_VGA_ID :: u32(0x5647_5347)
GSW_VGA_CAP_2D :: u32(1 << 0)
GSW_VGA_CAP_FENCE_IRQ :: u32(1 << 1)
GSW_VGA_CAP_SURFACE_OFFSET :: u32(1 << 2)
GSW_VGA_CAP_BLT_V2 :: u32(1 << 3)
GSW_CAP_3D_SVGA9 :: u32(1 << 8)
GSW_CAP_DIRECT_PRESENT :: u32(1 << 9)
GSW_CAP_ASYNC_FENCES :: u32(1 << 10)
GSW_CAP_RESOURCE_UPLOAD :: u32(1 << 11)
GSW_VGA_STATUS_READY :: u32(1 << 0)
GSW_VGA_STATUS_ERROR :: u32(1 << 1)
GSW_VGA_IRQ_2D :: u32(1 << 0)
GSW_VGA_IRQ_3D :: u32(1 << 1)

Gsw_Vga_Opcode :: enum u16 {
	Set_Mode    = 1,
	Present     = 2,
	Fill        = 3,
	Copy        = 4,
	Set_Palette = 5,
	Blt         = 6,
}

Gsw_Pixel_Format :: enum u32 {
	Indexed_8 = 1,
	Rgb_555   = 2,
	Rgb_565   = 3,
	Rgb_888   = 4,
	Xrgb_8888 = 5,
}

Gsw_Vga_Metrics :: struct {
	commands:        u64,
	malformed:       u64,
	presents:        u64,
	fills:           u64,
	copies:          u64,
	palette_updates: u64,
	blits:           u64,
	software_pixels: u64,
}

Gsw_Vga :: struct {
	framebuffer:          []u8,
	scanout:              ^Vga,
	memory_space_enabled: bool,
	control_base:         u64,
	ring_gpa:             u64,
	ring_size:            u32,
	ring_head:            u32,
	ring_tail:            u32,
	status:               u32,
	capabilities:         u32,
	irq_enable:           u32,
	irq_status:           u32,
	completed_fence:      u64,
	width:                u32,
	height:               u32,
	pitch:                u32,
	format:               Gsw_Pixel_Format,
	present_generation:   u64,
	irq_ctx:              rawptr,
	irq:                  proc(ctx: rawptr, asserted: bool),
	metrics:              Gsw_Vga_Metrics,
	three_d:              Gsw3d,
}

gsw_vga_init :: proc(g: ^Gsw_Vga, framebuffer: []u8) {
	g^ = {
		framebuffer          = framebuffer,
		memory_space_enabled = true,
		control_base         = GSW_VGA_CONTROL_BASE,
		status               = GSW_VGA_STATUS_READY,
		capabilities         = GSW_VGA_CAP_2D | GSW_VGA_CAP_FENCE_IRQ | GSW_VGA_CAP_SURFACE_OFFSET | GSW_VGA_CAP_BLT_V2,
	}
	gsw3d_init(&g.three_d)
}

gsw_vga_destroy :: proc(g: ^Gsw_Vga) {
	if g == nil {return}
	gsw3d_destroy(&g.three_d)
	g^ = {}
}

gsw_vga_set_pci_decode :: proc(g: ^Gsw_Vga, memory_space_enabled: bool, control_base: u64) {
	if g == nil {return}
	g.memory_space_enabled = memory_space_enabled
	g.control_base = control_base
}

gsw_vga_control_offset :: proc(g: ^Gsw_Vga, gpa: u64, size: int) -> (u32, bool) {
	if g == nil ||
	   !g.memory_space_enabled ||
	   size < 0 ||
	   gpa < g.control_base ||
	   u64(size) > GSW_VGA_CONTROL_SIZE ||
	   gpa - g.control_base > GSW_VGA_CONTROL_SIZE - u64(size) {
		return 0, false
	}
	return u32(gpa - g.control_base), true
}

gsw_vga_set_irq :: proc(g: ^Gsw_Vga, ctx: rawptr, irq: proc(ctx: rawptr, asserted: bool)) {
	g.irq_ctx = ctx
	g.irq = irq
}

gsw_vga_attach_scanout :: proc(g: ^Gsw_Vga, scanout: ^Vga) {
	if g != nil {g.scanout = scanout}
}

@(private = "package")
gsw_rd16 :: proc(data: []u8, offset: int) -> u16 {
	return u16(data[offset]) | u16(data[offset + 1]) << 8
}

@(private = "package")
gsw_rd32 :: proc(data: []u8, offset: int) -> u32 {
	return(
		u32(data[offset]) |
		u32(data[offset + 1]) << 8 |
		u32(data[offset + 2]) << 16 |
		u32(data[offset + 3]) << 24 \
	)
}

@(private = "package")
gsw_rd64 :: proc(data: []u8, offset: int) -> u64 {
	return u64(gsw_rd32(data, offset)) | u64(gsw_rd32(data, offset + 4)) << 32
}

@(private = "package")
gsw_format_bytes :: proc(format: Gsw_Pixel_Format) -> int {
	switch format {
	case .Indexed_8:
		return 1
	case .Rgb_555, .Rgb_565:
		return 2
	case .Rgb_888:
		return 3
	case .Xrgb_8888:
		return 4
	}
	return 0
}

@(private = "file")
gsw_ring_valid :: proc(g: ^Gsw_Vga, ram: []u8) -> bool {
	return(
		g.ring_size >= GSW_VGA_RING_MIN_SIZE &&
		g.ring_size <= GSW_VGA_RING_MAX_SIZE &&
		g.ring_size & (g.ring_size - 1) == 0 &&
		g.ring_head < g.ring_size &&
		g.ring_tail < g.ring_size &&
		g.ring_gpa <= u64(len(ram)) &&
		u64(g.ring_size) <= u64(len(ram)) - g.ring_gpa \
	)
}

@(private = "file")
gsw_ring_available :: proc(g: ^Gsw_Vga) -> u32 {
	return(
		g.ring_tail >= g.ring_head ? g.ring_tail - g.ring_head : g.ring_size - g.ring_head + g.ring_tail \
	)
}

@(private = "file")
gsw_ring_read :: proc(g: ^Gsw_Vga, ram: []u8, offset: u32, out: []u8) {
	first := min(len(out), int(g.ring_size - offset))
	start := int(g.ring_gpa + u64(offset))
	copy(out[:first], ram[start:start + first])
	if first < len(out) {
		base := int(g.ring_gpa)
		copy(out[first:], ram[base:base + len(out) - first])
	}
}

@(private = "file")
gsw_vga_fail :: proc(g: ^Gsw_Vga) {
	g.status |= GSW_VGA_STATUS_ERROR
	g.metrics.malformed += 1
}

@(private = "file")
gsw_vga_pixel :: proc(destination: []u8, format: Gsw_Pixel_Format, color: u32) {
	switch format {
	case .Indexed_8:
		destination[0] = u8(color)
	case .Rgb_555, .Rgb_565:
		destination[0] = u8(color)
		destination[1] = u8(color >> 8)
	case .Rgb_888:
		destination[0] = u8(color)
		destination[1] = u8(color >> 8)
		destination[2] = u8(color >> 16)
	case .Xrgb_8888:
		destination[0] = u8(color)
		destination[1] = u8(color >> 8)
		destination[2] = u8(color >> 16)
		destination[3] = u8(color >> 24)
	}
}

@(private = "file")
gsw_vga_execute :: proc(g: ^Gsw_Vga, command: []u8, version: u16) -> bool {
	opcode := Gsw_Vga_Opcode(gsw_rd16(command, 0))
	switch opcode {
	case .Set_Mode:
		if len(command) != 32 {return false}
		width := gsw_rd32(command, 16)
		height := gsw_rd32(command, 20)
		pitch := gsw_rd32(command, 24)
		format := Gsw_Pixel_Format(gsw_rd32(command, 28))
		bytes := gsw_format_bytes(format)
		_, valid := gsw_surface_rect(len(g.framebuffer), 0, pitch, 0, 0, width, height, bytes)
		if !valid || width > DISPI_MAX_XRES || height > DISPI_MAX_YRES {return false}
		g.width, g.height, g.pitch, g.format = width, height, pitch, format
	case .Present:
		offset, width, height, pitch, format := u32(0), g.width, g.height, g.pitch, g.format
		if version == GSW_VGA_COMMAND_VERSION {
			if len(command) != 16 {return false}
		} else {
			if len(command) != 40 || gsw_rd32(command, 36) != 0 {return false}
			offset = gsw_rd32(command, 16)
			width = gsw_rd32(command, 20)
			height = gsw_rd32(command, 24)
			pitch = gsw_rd32(command, 28)
			format = Gsw_Pixel_Format(gsw_rd32(command, 32))
		}
		if g.scanout != nil &&
		   !vga_gsw_present_surface(g.scanout, offset, width, height, pitch, format) {
			return false
		}
		g.width, g.height, g.pitch, g.format = width, height, pitch, format
		g.present_generation += 1
		g.metrics.presents += 1
	case .Fill:
		if len(command) != 40 {return false}
		offset := gsw_rd32(command, 16)
		pitch := gsw_rd32(command, 20)
		width := gsw_rd32(command, 24)
		height := gsw_rd32(command, 28)
		color := gsw_rd32(command, 32)
		format := Gsw_Pixel_Format(gsw_rd32(command, 36))
		bytes := gsw_format_bytes(format)
		_, valid := gsw_surface_rect(len(g.framebuffer), offset, pitch, 0, 0, width, height, bytes)
		if !valid || u64(width) * u64(height) > GSW_VGA_MAX_SOFTWARE_PIXELS {return false}
		for y in 0 ..< int(height) {
			row := int(offset) + y * int(pitch)
			for x in 0 ..< int(width) {
				pixel := row + x * bytes
				gsw_vga_pixel(g.framebuffer[pixel:pixel + bytes], format, color)
			}
		}
		g.metrics.fills += 1
		g.metrics.software_pixels += u64(width) * u64(height)
	case .Copy:
		if len(command) != 44 {return false}
		source := gsw_rd32(command, 16)
		destination := gsw_rd32(command, 20)
		source_pitch := gsw_rd32(command, 24)
		destination_pitch := gsw_rd32(command, 28)
		width := gsw_rd32(command, 32)
		height := gsw_rd32(command, 36)
		bytes := gsw_format_bytes(Gsw_Pixel_Format(gsw_rd32(command, 40)))
		row_bytes := u64(width) * u64(bytes)
		_, source_ok := gsw_surface_rect(
			len(g.framebuffer),
			source,
			source_pitch,
			0,
			0,
			width,
			height,
			bytes,
		)
		_, destination_ok := gsw_surface_rect(
			len(g.framebuffer),
			destination,
			destination_pitch,
			0,
			0,
			width,
			height,
			bytes,
		)
		if !source_ok ||
		   !destination_ok ||
		   u64(width) * u64(height) > GSW_VGA_MAX_SOFTWARE_PIXELS {return false}
		snapshot := make([]u8, int(row_bytes * u64(height)))
		defer delete(snapshot)
		for y in 0 ..< int(height) {
			src := int(source) + y * int(source_pitch)
			row := y * int(row_bytes)
			copy(snapshot[row:row + int(row_bytes)], g.framebuffer[src:src + int(row_bytes)])
		}
		for y in 0 ..< int(height) {
			dst := int(destination) + y * int(destination_pitch)
			row := y * int(row_bytes)
			copy(g.framebuffer[dst:dst + int(row_bytes)], snapshot[row:row + int(row_bytes)])
		}
		g.metrics.copies += 1
		g.metrics.software_pixels += u64(width) * u64(height)
	case .Set_Palette:
		if len(command) < 24 {return false}
		start := gsw_rd32(command, 16)
		count := gsw_rd32(command, 20)
		if count == 0 ||
		   start >= 256 ||
		   count > 256 - start ||
		   len(command) != 24 + int(count) * 4 {
			return false
		}
		if g.scanout != nil {
			for i in 0 ..< int(count) {
				color := gsw_rd32(command, 24 + i * 4)
				index := (int(start) + i) * 3
				g.scanout.dac[index + 0] = u8(color >> 16) >> 2
				g.scanout.dac[index + 1] = u8(color >> 8) >> 2
				g.scanout.dac[index + 2] = u8(color) >> 2
			}
			vga_note_content_change(g.scanout)
		}
		g.metrics.palette_updates += u64(count)
	case .Blt:
		if version != GSW_VGA_COMMAND_VERSION_2 || !gsw_vga_execute_blt(g, command) {return false}
	case:
		return false
	}
	return true
}

gsw_vga_process :: proc(g: ^Gsw_Vga, ram: []u8) {
	if !gsw_ring_valid(g, ram) {gsw_vga_fail(g); return}
	processed := 0
	for gsw_ring_available(g) > 0 {
		if processed >= GSW_VGA_MAX_COMMANDS_PER_DOORBELL {gsw_vga_fail(g); return}
		available := gsw_ring_available(g)
		if available < 16 {gsw_vga_fail(g); return}
		header: [16]u8
		gsw_ring_read(g, ram, g.ring_head, header[:])
		version := gsw_rd16(header[:], 2)
		length := gsw_rd32(header[:], 4)
		if version != GSW_VGA_COMMAND_VERSION && version != GSW_VGA_COMMAND_VERSION_2 ||
		   length < 16 ||
		   length & 3 != 0 ||
		   length > available ||
		   length > g.ring_size {gsw_vga_fail(g); return}
		command := make([]u8, int(length))
		gsw_ring_read(g, ram, g.ring_head, command)
		executed := gsw_vga_execute(g, command, version)
		fence := gsw_rd64(command, 8)
		delete(command)
		if !executed {gsw_vga_fail(g); return}
		g.metrics.commands += 1
		processed += 1
		g.completed_fence = fence
		g.ring_head = (g.ring_head + length) & (g.ring_size - 1)
		if g.completed_fence != 0 {
			g.irq_status |= GSW_VGA_IRQ_2D
			gsw_vga_sync_irq(g)
		}
	}
}

@(private = "package")
gsw_vga_sync_irq :: proc(g: ^Gsw_Vga) {
	if g != nil && g.irq != nil {g.irq(g.irq_ctx, g.irq_status & g.irq_enable != 0)}
}

gsw_vga_poll :: proc(g: ^Gsw_Vga) {
	if g == nil {return}
	if gsw3d_poll(&g.three_d) {
		g.irq_status |= GSW_VGA_IRQ_3D
		gsw_vga_sync_irq(g)
	}
}

@(private = "file")
gsw_vga_register_read :: proc(g: ^Gsw_Vga, offset: u32) -> u32 {
	switch offset {
	case GSW_VGA_REG_ID:
		return GSW_VGA_ID
	case GSW_VGA_REG_VERSION:
		return GSW_VGA_INTERFACE_VERSION
	case GSW_VGA_REG_CAPABILITIES:
		return g.capabilities
	case GSW_VGA_REG_STATUS:
		return g.status
	case GSW_VGA_REG_RING_GPA_LOW:
		return u32(g.ring_gpa)
	case GSW_VGA_REG_RING_GPA_HIGH:
		return u32(g.ring_gpa >> 32)
	case GSW_VGA_REG_RING_SIZE:
		return g.ring_size
	case GSW_VGA_REG_RING_HEAD:
		return g.ring_head
	case GSW_VGA_REG_RING_TAIL:
		return g.ring_tail
	case GSW_VGA_REG_IRQ_ENABLE:
		return g.irq_enable
	case GSW_VGA_REG_IRQ_STATUS:
		return g.irq_status
	case GSW_VGA_REG_FENCE_LOW:
		return u32(g.completed_fence)
	case GSW_VGA_REG_FENCE_HIGH:
		return u32(g.completed_fence >> 32)
	}
	if value, handled := gsw3d_register_read(&g.three_d, offset); handled {return value}
	return 0
}

gsw_vga_mmio_read :: proc(g: ^Gsw_Vga, offset: u32, data: []u8) {
	gsw_vga_poll(g)
	for &byte, i in data {
		register := (offset + u32(i)) &~ u32(3)
		shift := ((offset + u32(i)) & 3) * 8
		byte = u8(gsw_vga_register_read(g, register) >> shift)
	}
}

gsw_vga_mmio_write :: proc(g: ^Gsw_Vga, offset: u32, data: []u8, ram: []u8) {
	if len(data) != 4 || offset & 3 != 0 {gsw_vga_fail(g); return}
	value := gsw_rd32(data, 0)
	if handled := gsw3d_register_write(&g.three_d, offset, value, ram); handled {
		if offset == GSW3D_REG_STATUS && value & GSW3D_STATUS_RESET != 0 {
			g.irq_status &~= GSW_VGA_IRQ_3D
			gsw_vga_sync_irq(g)
		}
		gsw_vga_poll(g)
		return
	}
	switch offset {
	case GSW_VGA_REG_RING_GPA_LOW:
		g.ring_gpa = g.ring_gpa & 0xFFFF_FFFF_0000_0000 | u64(value)
	case GSW_VGA_REG_RING_GPA_HIGH:
		g.ring_gpa = g.ring_gpa & 0x0000_0000_FFFF_FFFF | u64(value) << 32
	case GSW_VGA_REG_RING_SIZE:
		g.ring_size = value
	case GSW_VGA_REG_RING_HEAD:
		g.ring_head = value
	case GSW_VGA_REG_RING_TAIL:
		g.ring_tail = value
	case GSW_VGA_REG_DOORBELL:
		gsw_vga_process(g, ram)
	case GSW_VGA_REG_IRQ_ENABLE:
		g.irq_enable = value & (GSW_VGA_IRQ_2D | GSW_VGA_IRQ_3D)
		gsw_vga_sync_irq(g)
	case GSW_VGA_REG_IRQ_STATUS:
		g.irq_status &~= value
		gsw_vga_sync_irq(g)
	case GSW_VGA_REG_STATUS:
		g.status &~= value & GSW_VGA_STATUS_ERROR
	}
}

gsw_vga_persona :: proc() -> (vram_mib, core_mhz, agp_multiplier: u32) {
	return u32(
		persona.GUEST_PERSONA.vram_bytes / (1024 * 1024),
	), u32(persona.GUEST_PERSONA.graphics_core_mhz), u32(persona.GUEST_PERSONA.graphics_agp_rate)
}
