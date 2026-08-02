// SPDX-License-Identifier: GPL-3.0-only
package vga

Legacy_Aperture_Layout_Kind :: enum u8 {
	Unavailable,
	Indexed_Unchained,
}

Legacy_Aperture_Layout :: struct {
	kind:          Legacy_Aperture_Layout_Kind,
	width:         int,
	height:        int,
	pitch_bytes:   int,
	aperture_base: u64,
	aperture_size: u64,
}

vga_legacy_aperture_execution_layout :: proc(v: ^Vga) -> Legacy_Aperture_Layout {
	if v == nil || vga_vbe_enabled(v) {return {}}
	kind, width, height := display_geometry(v)
	pitch := int(v.crtc[0x13]) * 2
	if kind != .Indexed_8 || v.seq[4] & 0x0E != 0x06 || pitch <= 0 {
		return {}
	}

	aperture_base := LEGACY_APERTURE_BASE
	aperture_size := LEGACY_APERTURE_END - LEGACY_APERTURE_BASE
	switch (v.gfx[6] >> 2) & 3 {
	case 1:
		aperture_size = LEGACY_PLANE_SIZE
	case 2:
		aperture_base = 0xB0000
		aperture_size = 0x8000
	case 3:
		aperture_base = 0xB8000
		aperture_size = 0x8000
	}
	return {
		kind          = .Indexed_Unchained,
		width         = width,
		height        = height,
		pitch_bytes   = pitch,
		aperture_base = aperture_base,
		aperture_size = aperture_size,
	}
}
