// SPDX-License-Identifier: GPL-3.0-only
package fat32

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

OVERLAY_DIRECTORY :: ".retvrn99-journal"
OVERLAY_TEMP_PREFIX :: "retvrn99-fat32-"
OVERLAY_TEMP_SUFFIX :: ".overlay"
STREAM_TEMP_PREFIX :: "retvrn99-stream-"
STREAM_TEMP_SUFFIX :: ".tmp"

Sector_Overlay :: struct {
	file:              ^os.File,
	path:              string,
	present:           []u64,
	dirty:             []u64,
	orphan_clusters:   []u64,
	present_count:     u32,
	linked:            bool,
	healthy:           bool,
	logical_bytes:     u64,
	read_ops:          u64,
	read_bytes:        u64,
	write_ops:         u64,
	write_bytes:       u64,
}

Journal_Storage_Stats :: struct {
	present_sectors:        u32,
	dirty_sectors:          u32,
	orphan_clusters:        u32,
	// Fixed bitmap storage only. Dynamic map usage is reported as entry counts
	// because Odin does not expose the maps' allocated capacity in bytes.
	resident_metadata_bytes: u64,
	shadow_fat_entries:     u32,
	claimed_entries:        u32,
	backing_logical_bytes:  u64,
	backing_allocated_bytes: u64,
	backing_allocation_known: bool,
	backing_read_ops:       u64,
	backing_read_bytes:     u64,
	backing_write_ops:      u64,
	backing_write_bytes:    u64,
	streamed_guest_files:   u64,
	streamed_guest_bytes:   u64,
	healthy:                bool,
}

@(private = "file")
bitmap_words :: proc(bits: u32) -> int {
	return int((u64(bits) + 63) / 64)
}

@(private = "file")
bitmap_has :: proc(bits: []u64, index: u32) -> bool {
	word := int(index / 64)
	return word < len(bits) && bits[word] & (u64(1) << u64(index % 64)) != 0
}

@(private = "file")
bitmap_set :: proc(bits: []u64, index: u32) -> bool {
	word := int(index / 64)
	if word >= len(bits) {return false}
	mask := u64(1) << u64(index % 64)
	was_set := bits[word] & mask != 0
	bits[word] |= mask
	return !was_set
}

@(private = "file")
bitmap_clear :: proc(bits: []u64, index: u32) -> bool {
	word := int(index / 64)
	if word >= len(bits) {return false}
	mask := u64(1) << u64(index % 64)
	was_set := bits[word] & mask != 0
	bits[word] &~= mask
	return was_set
}

@(private = "file")
bitmap_count :: proc(bits: []u64) -> u32 {
	count: u32
	for word in bits {
		value := word
		for value != 0 {
			value &= value - 1
			count += 1
		}
	}
	return count
}

@(private = "file")
journal_temp_owner :: proc(name, prefix, suffix: string) -> (u32, bool) {
	if !strings.has_prefix(name, prefix) || !strings.has_suffix(name, suffix) {
		return 0, false
	}
	rest := name[len(prefix):]
	dash := strings.index_byte(rest, '-')
	if dash <= 0 {return 0, false}
	value, ok := strconv.parse_u64_of_base(rest[:dash], 10)
	if !ok || value > u64(0xFFFF_FFFF) {return 0, false}
	return u32(value), true
}

@(private)
journal_stale_temp :: proc(name: string) -> bool {
	pid, ok := journal_temp_owner(name, OVERLAY_TEMP_PREFIX, OVERLAY_TEMP_SUFFIX)
	if !ok {
		pid, ok = journal_temp_owner(name, STREAM_TEMP_PREFIX, STREAM_TEMP_SUFFIX)
	}
	return ok && !journal_process_is_live(pid)
}

overlay_init :: proc(
	o: ^Sector_Overlay,
	total_sectors, cluster_count: u32,
	root_path: string,
	allocator := context.allocator,
) -> bool {
	if o == nil || total_sectors == 0 {return false}
	o.present = make([]u64, bitmap_words(total_sectors), allocator)
	o.dirty = make([]u64, bitmap_words(total_sectors), allocator)
	o.orphan_clusters = make([]u64, bitmap_words(cluster_count + 2), allocator)
	o.healthy = true
	profile := filepath.dir(root_path)
	backing_dir, join_error := filepath.join(
		{profile, OVERLAY_DIRECTORY},
		context.temp_allocator,
	)
	if join_error != nil || os.make_directory_all(backing_dir) != nil {
		overlay_destroy(o, allocator)
		return false
	}
	overlay_scavenge_stale(backing_dir)
	pattern := fmt.tprintf(
		"%s%d-*%s",
		OVERLAY_TEMP_PREFIX,
		os.get_pid(),
		OVERLAY_TEMP_SUFFIX,
	)
	f, err := journal_create_temp_file(backing_dir, pattern)
	if err != nil {
		log.errorf("fat32: cannot create journal backing: %v", err)
		overlay_destroy(o, allocator)
		return false
	}
	o.file = f
	o.path = strings.clone(os.name(f), allocator)
	o.linked = true
	if !overlay_prepare_sparse(f) {
		log.errorf("fat32: cannot enable sparse storage for %s", o.path)
		overlay_destroy(o, allocator)
		return false
	}
	linked, path_safe := overlay_secure_backing_path(o.path)
	if !path_safe {
		log.errorf("fat32: cannot secure temporary journal path %s", o.path)
		overlay_destroy(o, allocator)
		return false
	}
	o.linked = linked
	return true
}

overlay_destroy :: proc(o: ^Sector_Overlay, allocator: runtime.Allocator) {
	if o == nil {return}
	if o.file != nil {
		if err := os.close(o.file); err != nil {
			log.warnf("fat32: cannot close journal backing %s: %v", o.path, err)
		}
		o.file = nil
	}
	if o.linked && o.path != "" {
		if err := overlay_remove_backing(o.path); err != nil && err != .Not_Exist {
			log.warnf("fat32: cannot remove journal backing %s: %v", o.path, err)
		}
	}
	delete(o.path, allocator)
	delete(o.present, allocator)
	delete(o.dirty, allocator)
	delete(o.orphan_clusters, allocator)
	o^ = {}
}

overlay_has :: proc(v: ^Volume, rel: u32) -> bool {
	return v != nil && bitmap_has(v.journal.overlay.present, rel)
}

overlay_dirty_has :: proc(v: ^Volume, rel: u32) -> bool {
	return v != nil && bitmap_has(v.journal.overlay.dirty, rel)
}

orphan_has :: proc(v: ^Volume, cluster: u32) -> bool {
	return v != nil && bitmap_has(v.journal.overlay.orphan_clusters, cluster)
}

@(private = "file")
overlay_io_fail :: proc(v: ^Volume, operation: string, rel: u32) {
	if v == nil {return}
	v.journal.overlay.healthy = false
	volume_fail(v, fmt.tprintf("FAT32 journal backing %s failed at relative LBA %d", operation, rel))
}

overlay_get :: proc(v: ^Volume, rel: u32, out: []u8) -> (present, ok: bool) {
	if v == nil || len(out) != SECTOR {return false, false}
	o := &v.journal.overlay
	if !bitmap_has(o.present, rel) {return false, true}
	if o.file == nil || !o.healthy {
		overlay_io_fail(v, "read", rel)
		return true, false
	}
	total := 0
	for total < SECTOR {
		n, err := os.read_at(o.file, out[total:], i64(rel) * SECTOR + i64(total))
		if n > 0 {total += n}
		if err != nil && err != .EOF || n == 0 {
			overlay_io_fail(v, "read", rel)
			return true, false
		}
	}
	o.read_ops += 1
	o.read_bytes += SECTOR
	return true, true
}

overlay_read_run :: proc(
	v: ^Volume,
	lba: u64,
	max_sectors: int,
	out: []u8,
) -> (count: int, handled, ok: bool) {
	if v == nil || max_sectors <= 0 || lba < PART_START_LBA {return 0, false, false}
	rel64 := lba - PART_START_LBA
	if rel64 >= u64(v.alloc.geo.total_sectors) {return 0, false, false}
	rel := u32(rel64)
	if !overlay_has(v, rel) {return 0, false, false}
	count = 1
	limit := min(max_sectors, int(v.alloc.geo.total_sectors - rel))
	for count < limit && overlay_has(v, rel + u32(count)) {count += 1}
	bytes := count * SECTOR
	o := &v.journal.overlay
	if o.file == nil || !o.healthy {
		overlay_io_fail(v, "read", rel)
		return count, true, false
	}
	total := 0
	for total < bytes {
		n, err := os.read_at(o.file, out[total:bytes], i64(rel) * SECTOR + i64(total))
		if n > 0 {total += n}
		if err != nil && err != .EOF || n == 0 {
			overlay_io_fail(v, "read", rel + u32(total / SECTOR))
			return count, true, false
		}
	}
	o.read_ops += 1
	o.read_bytes += u64(bytes)
	return count, true, true
}

overlay_put_run :: proc(v: ^Volume, rel: u32, data: []u8) -> bool {
	if v == nil || len(data) == 0 || len(data) % SECTOR != 0 {return false}
	count := len(data) / SECTOR
	if u64(rel) + u64(count) > u64(v.alloc.geo.total_sectors) {return false}
	o := &v.journal.overlay
	if o.file == nil || !o.healthy {
		overlay_io_fail(v, "write", rel)
		return false
	}
	total := 0
	for total < len(data) {
		n, err := os.write_at(o.file, data[total:], i64(rel) * SECTOR + i64(total))
		if n > 0 {total += n}
		if err != nil || n == 0 {
			overlay_io_fail(v, "write", rel + u32(total / SECTOR))
			return false
		}
	}
	for i in 0 ..< count {
		if bitmap_set(o.present, rel + u32(i)) {o.present_count += 1}
		_ = bitmap_set(o.dirty, rel + u32(i))
	}
	o.logical_bytes = max(o.logical_bytes, (u64(rel) + u64(count)) * SECTOR)
	o.write_ops += 1
	o.write_bytes += u64(len(data))
	return true
}

overlay_put :: proc(v: ^Volume, rel: u32, sec: []u8) -> bool {
	return overlay_put_run(v, rel, sec)
}

overlay_clear_chain_dirty :: proc(v: ^Volume, chain: []u32) {
	if v == nil {return}
	for cluster in chain {
		first := v.alloc.geo.data_start + (cluster - 2) * SECTORS_PER_CLUSTER
		for sector in u32(0) ..< SECTORS_PER_CLUSTER {
			_ = bitmap_clear(v.journal.overlay.dirty, first + sector)
		}
	}
}

overlay_clear_all_dirty :: proc(v: ^Volume) {
	if v == nil {return}
	for &word in v.journal.overlay.dirty {word = 0}
}

@(private = "file")
orphan_backing_offset :: proc(v: ^Volume, cluster: u32) -> u64 {
	overlay_bytes := u64(v.alloc.geo.total_sectors) * SECTOR
	return overlay_bytes + u64(cluster) * CLUSTER_BYTES
}

@(private = "file")
orphan_backing_write :: proc(v: ^Volume, cluster: u32, data: []u8, within: int = 0) -> bool {
	o := &v.journal.overlay
	if o.file == nil || !o.healthy {
		overlay_io_fail(v, "orphan write", v.alloc.geo.data_start + (cluster - 2) * SECTORS_PER_CLUSTER)
		return false
	}
	offset := orphan_backing_offset(v, cluster) + u64(within)
	total := 0
	for total < len(data) {
		n, err := os.write_at(o.file, data[total:], i64(offset) + i64(total))
		if n > 0 {total += n}
		if err != nil || n == 0 {
			overlay_io_fail(v, "orphan write", v.alloc.geo.data_start + (cluster - 2) * SECTORS_PER_CLUSTER)
			return false
		}
	}
	o.logical_bytes = max(o.logical_bytes, offset + u64(len(data)))
	o.write_ops += 1
	o.write_bytes += u64(len(data))
	return true
}

@(private = "file")
orphan_backing_read :: proc(v: ^Volume, cluster: u32, out: []u8) -> bool {
	o := &v.journal.overlay
	if o.file == nil || !o.healthy {
		overlay_io_fail(v, "orphan read", v.alloc.geo.data_start + (cluster - 2) * SECTORS_PER_CLUSTER)
		return false
	}
	offset := orphan_backing_offset(v, cluster)
	total := 0
	for total < len(out) {
		n, err := os.read_at(o.file, out[total:], i64(offset) + i64(total))
		if n > 0 {total += n}
		if err != nil && err != .EOF || n == 0 {
			overlay_io_fail(v, "orphan read", v.alloc.geo.data_start + (cluster - 2) * SECTORS_PER_CLUSTER)
			return false
		}
	}
	o.read_ops += 1
	o.read_bytes += u64(len(out))
	return true
}

orphan_write_sector :: proc(v: ^Volume, cluster, sector: u32, sec: []u8) -> bool {
	if v == nil || cluster < 2 || cluster >= v.alloc.geo.cluster_count + 2 ||
	   sector >= SECTORS_PER_CLUSTER || len(sec) != SECTOR {
		return false
	}
	if !orphan_has(v, cluster) {
		block: [CLUSTER_BYTES]u8
		copy(block[int(sector) * SECTOR:][:SECTOR], sec)
		if !orphan_backing_write(v, cluster, block[:]) {return false}
	} else if !orphan_backing_write(v, cluster, sec, int(sector) * SECTOR) {
		return false
	}
	_ = bitmap_set(v.journal.overlay.orphan_clusters, cluster)
	return true
}

orphan_read_cluster :: proc(v: ^Volume, cluster: u32, out: []u8) -> bool {
	if v == nil || len(out) != CLUSTER_BYTES || !orphan_has(v, cluster) {return false}
	return orphan_backing_read(v, cluster, out)
}

orphan_store_cluster :: proc(v: ^Volume, cluster: u32, data: []u8) -> bool {
	if v == nil || len(data) != CLUSTER_BYTES {return false}
	if !orphan_backing_write(v, cluster, data) {return false}
	_ = bitmap_set(v.journal.overlay.orphan_clusters, cluster)
	return true
}

orphan_unmark :: proc(v: ^Volume, cluster: u32) {
	if v != nil {_ = bitmap_clear(v.journal.overlay.orphan_clusters, cluster)}
}

// Re-publish a full orphan cluster whose disk payload survived a metadata
// transaction that temporarily cleared its orphan bit.
orphan_republish_cluster :: proc(v: ^Volume, cluster: u32) {
	if v == nil || cluster < 2 {return}
	_ = bitmap_set(v.journal.overlay.orphan_clusters, cluster)
}

orphan_clear :: proc(v: ^Volume, cluster: u32) {
	if v == nil {return}
	orphan_unmark(v, cluster)
}

volume_journal_storage_stats :: proc(v: ^Volume) -> Journal_Storage_Stats {
	if v == nil {return {}}
	o := &v.journal.overlay
	allocated, allocation_known := overlay_allocated_size(o.file)
	return Journal_Storage_Stats {
		present_sectors         = o.present_count,
		dirty_sectors           = bitmap_count(o.dirty),
		orphan_clusters         = bitmap_count(o.orphan_clusters),
		resident_metadata_bytes =
			u64(len(o.present) + len(o.dirty) + len(o.orphan_clusters)) * size_of(u64),
		shadow_fat_entries      = u32(len(v.journal.shadow_fat)),
		claimed_entries         = u32(len(v.journal.claimed)),
		backing_logical_bytes   = o.logical_bytes,
		backing_allocated_bytes = allocated,
		backing_allocation_known = allocation_known,
		backing_read_ops        = o.read_ops,
		backing_read_bytes      = o.read_bytes,
		backing_write_ops       = o.write_ops,
		backing_write_bytes     = o.write_bytes,
		streamed_guest_files    = v.journal.streamed_guest_files,
		streamed_guest_bytes    = v.journal.streamed_guest_bytes,
		healthy                 = o.healthy,
	}
}
