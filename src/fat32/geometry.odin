// SPDX-License-Identifier: GPL-3.0-only
package fat32

SECTOR :: 512
SECTORS_PER_CLUSTER :: 8 // clusters de 4K
PART_START_LBA :: 2048
RESERVED_SECTORS :: 32
NUM_FATS :: 2

Geometry :: struct {
	total_sectors:   u32, // de la partición
	sectors_per_fat: u32,
	fat_start:       u32, // relativo a partición
	data_start:      u32,
	cluster_count:   u32,
}

geometry_make :: proc(volume_mb: u32) -> Geometry {
	total := volume_mb * 2048 // sectores
	// iterar: clusters ≈ (total - reservado - 2*fat) / spc
	spf := u32(0)
	for {
		data := total - RESERVED_SECTORS - NUM_FATS * spf
		clusters := data / SECTORS_PER_CLUSTER
		need := (clusters + 2) * 4 // 4 bytes por entrada
		need_sectors := (need + SECTOR - 1) / SECTOR
		if need_sectors <= spf { break }
		spf = need_sectors
	}
	g := Geometry{total_sectors = total, sectors_per_fat = spf}
	g.fat_start = RESERVED_SECTORS
	g.data_start = RESERVED_SECTORS + NUM_FATS * spf
	g.cluster_count = (total - g.data_start) / SECTORS_PER_CLUSTER
	return g
}

cluster_to_lba :: proc(g: ^Geometry, cluster: u32) -> u32 {
	return g.data_start + (cluster - 2) * SECTORS_PER_CLUSTER
}

@(private = "file")
put16 :: proc(b: []u8, off: int, v: u16) {
	b[off] = u8(v)
	b[off + 1] = u8(v >> 8)
}

@(private = "file")
put32 :: proc(b: []u8, off: int, v: u32) {
	b[off] = u8(v)
	b[off + 1] = u8(v >> 8)
	b[off + 2] = u8(v >> 16)
	b[off + 3] = u8(v >> 24)
}

// MBR: una partición 0x0C arrancable en PART_START_LBA
make_mbr :: proc(total_sectors: u32) -> (mbr: [512]u8) {
	e := mbr[446:]
	e[0] = 0x80 // arrancable
	e[1] = 0xFE // CHS ficticio (solo LBA)
	e[2] = 0xFF
	e[3] = 0xFF
	e[4] = 0x0C // FAT32 LBA
	e[5] = 0xFE
	e[6] = 0xFF
	e[7] = 0xFF
	put32(e, 8, PART_START_LBA)
	put32(e, 12, total_sectors)
	mbr[510] = 0x55
	mbr[511] = 0xAA
	return
}

// VBR: salto + BPB FAT32; código de arranque llega en Task 18 (stub int 18h)
make_vbr :: proc(g: ^Geometry, total: u32) -> (vbr: [512]u8) {
	vbr[0] = 0xEB
	vbr[1] = 0x58
	vbr[2] = 0x90
	copy(vbr[3:11], "MSWIN4.1")
	put16(vbr[:], 11, SECTOR)
	vbr[13] = SECTORS_PER_CLUSTER
	put16(vbr[:], 14, RESERVED_SECTORS)
	vbr[16] = NUM_FATS
	vbr[21] = 0xF8 // media
	put16(vbr[:], 24, 63) // sectores/pista
	put16(vbr[:], 26, 16) // cabezas
	put32(vbr[:], 28, PART_START_LBA) // ocultos
	put32(vbr[:], 32, total)
	put32(vbr[:], 36, g.sectors_per_fat)
	put32(vbr[:], 44, 2) // cluster raíz
	put16(vbr[:], 48, 1) // sector fsinfo
	put16(vbr[:], 50, 6) // copia de arranque
	vbr[64] = 0x80 // unidad
	vbr[66] = 0x29 // firma ext
	put32(vbr[:], 67, 0x19980625) // serie
	copy(vbr[71:82], "MATE98     ")
	copy(vbr[82:90], "FAT32   ")
	vbr[90] = 0xCD // int 18h
	vbr[91] = 0x18
	vbr[510] = 0x55
	vbr[511] = 0xAA
	return
}

make_fsinfo :: proc() -> (fi: [512]u8) {
	put32(fi[:], 0, 0x41615252)
	put32(fi[:], 484, 0x61417272)
	put32(fi[:], 488, 0xFFFFFFFF) // libres desconocidos
	put32(fi[:], 492, 0xFFFFFFFF) // siguiente libre desconocido
	fi[510] = 0x55
	fi[511] = 0xAA
	return
}
