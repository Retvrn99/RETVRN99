// SPDX-License-Identifier: GPL-3.0-only
package fat32edit

import "core:os"

@(private = "package")
overlay_load_bitmap_page :: proc(impl: ^Edit_Impl, byte_offset: u64) -> bool {
	page := byte_offset / BITMAP_CACHE_BYTES
	if impl.bitmap_cache_valid && impl.bitmap_cache_page == page {return true}
	if !overlay_flush_bitmap_cache(impl) {return false}
	start := page * BITMAP_CACHE_BYTES
	used := int(min(u64(BITMAP_CACHE_BYTES), impl.bitmap_bytes - start))
	for index in 0 ..< BITMAP_CACHE_BYTES {impl.bitmap_cache[index] = 0}
	if used > 0 &&
	   !read_exact_at(impl.bitmap_file, impl.bitmap_cache[:used], i64(start)) {return false}
	impl.bitmap_cache_page = page
	impl.bitmap_cache_used = used
	impl.bitmap_cache_valid = true
	impl.bitmap_cache_dirty = false
	return true
}

@(private = "package")
overlay_flush_bitmap_cache :: proc(impl: ^Edit_Impl) -> bool {
	if impl == nil || !impl.bitmap_cache_valid || !impl.bitmap_cache_dirty {return true}
	start := impl.bitmap_cache_page * BITMAP_CACHE_BYTES
	if !write_exact_at(impl.bitmap_file, impl.bitmap_cache[:impl.bitmap_cache_used], i64(start)) {
		return false
	}
	impl.bitmap_cache_dirty = false
	return true
}

@(private = "package")
overlay_sector_present :: proc(impl: ^Edit_Impl, lba: u64) -> (bool, bool) {
	byte_offset := lba / 8
	if !overlay_load_bitmap_page(impl, byte_offset) {return false, false}
	within := int(byte_offset - impl.bitmap_cache_page * BITMAP_CACHE_BYTES)
	return impl.bitmap_cache[within] & (u8(1) << u8(lba & 7)) != 0, true
}

@(private = "package")
overlay_mark_sector :: proc(impl: ^Edit_Impl, lba: u64) -> bool {
	byte_offset := lba / 8
	if !overlay_load_bitmap_page(impl, byte_offset) {return false}
	within := int(byte_offset - impl.bitmap_cache_page * BITMAP_CACHE_BYTES)
	mask := u8(1) << u8(lba & 7)
	if impl.bitmap_cache[within] & mask == 0 {
		impl.bitmap_cache[within] |= mask
		impl.bitmap_cache_dirty = true
		impl.dirty_sectors += 1
	}
	return true
}

@(private = "package")
overlay_read :: proc(ctx: rawptr, lba: u64, data: []u8) -> bool {
	impl := (^Edit_Impl)(ctx)
	if impl == nil || impl.closed || len(data) == 0 || len(data) % SECTOR_BYTES != 0 {return false}
	count := u64(len(data) / SECTOR_BYTES)
	if lba >= impl.base.sector_count || count > impl.base.sector_count - lba {return false}
	for index in 0 ..< int(count) {
		sector_lba := lba + u64(index)
		present, ok := overlay_sector_present(impl, sector_lba)
		if !ok {return false}
		sector := data[index * SECTOR_BYTES:][:SECTOR_BYTES]
		if present {
			if !read_exact_at(
				impl.overlay_file,
				sector,
				i64(sector_lba * SECTOR_BYTES),
			) {return false}
		} else if !impl.base.read(impl.base.ctx, sector_lba, sector) {
			return false
		}
	}
	return true
}

@(private = "package")
overlay_write :: proc(ctx: rawptr, lba: u64, data: []u8) -> bool {
	impl := (^Edit_Impl)(ctx)
	if impl == nil || impl.closed || len(data) == 0 || len(data) % SECTOR_BYTES != 0 {return false}
	count := u64(len(data) / SECTOR_BYTES)
	if lba >= impl.base.sector_count || count > impl.base.sector_count - lba {return false}
	for index in 0 ..< int(count) {
		sector_lba := lba + u64(index)
		sector := data[index * SECTOR_BYTES:][:SECTOR_BYTES]
		if !write_exact_at(impl.overlay_file, sector, i64(sector_lba * SECTOR_BYTES)) ||
		   !overlay_mark_sector(impl, sector_lba) {
			return false
		}
	}
	return true
}

@(private = "package")
overlay_flush :: proc(ctx: rawptr) -> bool {
	impl := (^Edit_Impl)(ctx)
	if impl == nil || impl.closed || !overlay_flush_bitmap_cache(impl) {return false}
	return os.sync(impl.overlay_file) == nil && os.sync(impl.bitmap_file) == nil
}

@(private = "package")
overlay_count_dirty :: proc(impl: ^Edit_Impl) -> bool {
	impl.dirty_sectors = 0
	buffer: [BITMAP_CACHE_BYTES]u8
	for offset := u64(0); offset < impl.bitmap_bytes; offset += BITMAP_CACHE_BYTES {
		used := int(min(u64(BITMAP_CACHE_BYTES), impl.bitmap_bytes - offset))
		if !read_exact_at(impl.bitmap_file, buffer[:used], i64(offset)) {return false}
		for value in buffer[:used] {
			bits := value
			for bits != 0 {
				impl.dirty_sectors += 1
				bits &= bits - 1
			}
		}
	}
	return true
}
