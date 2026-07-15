// SPDX-License-Identifier: GPL-3.0-only
package fat32

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

GUEST_STREAM_BYTES :: 64 * 1024
FINGERPRINT_OFFSET :: u64(0xCBF29CE484222325)
FINGERPRINT_PRIME :: u64(0x100000001B3)

Guest_Stream_Error :: enum {
	None,
	Create,
	Read,
	Write,
	Close,
}

Guest_Stream_Source :: enum {
	Guest_View,
	Orphan_Clusters,
}

guest_fingerprint_add :: proc(hash: u64, data: []u8) -> u64 {
	value := hash
	for byte in data {value = (value ~ u64(byte)) * FINGERPRINT_PRIME}
	return value
}

host_file_fingerprint :: proc(path: string, expected_size: u32) -> (u64, bool) {
	file, open_error := os.open(path, {.Read})
	if open_error != nil {return 0, false}
	defer os.close(file)
	size, size_error := os.file_size(file)
	if size_error != nil || size != i64(expected_size) {return 0, false}

	buffer: [GUEST_STREAM_BYTES]u8
	fingerprint := FINGERPRINT_OFFSET
	offset: i64
	for offset < size {
		wanted := int(min(i64(len(buffer)), size - offset))
		total := 0
		for total < wanted {
			count, read_error := os.read_at(file, buffer[total:wanted], offset + i64(total))
			if count > 0 {total += count}
			if read_error != nil && read_error != .EOF {return 0, false}
			if total < wanted && (read_error == .EOF || count == 0) {return 0, false}
		}
		fingerprint = guest_fingerprint_add(fingerprint, buffer[:wanted])
		offset += i64(wanted)
	}
	return fingerprint, true
}

guest_file_fingerprint :: proc(v: ^Volume, chain: []u32, size: u32) -> (u64, bool) {
	if u64(size) > u64(len(chain)) * CLUSTER_BYTES {return 0, false}
	remaining := u64(size)
	fingerprint := FINGERPRINT_OFFSET
	block: [CLUSTER_BYTES]u8
	for cluster in chain {
		if remaining == 0 {break}
		lba := u64(PART_START_LBA) + u64(cluster_to_lba(&v.alloc.geo, cluster))
		if !volume_read(v, lba, block[:]) {return 0, false}
		used := int(min(remaining, u64(CLUSTER_BYTES)))
		fingerprint = guest_fingerprint_add(fingerprint, block[:used])
		remaining -= u64(used)
	}
	return fingerprint, remaining == 0
}

@(private = "file")
guest_stream_write_all :: proc(file: ^os.File, data: []u8) -> bool {
	total := 0
	for total < len(data) {
		n, err := os.write(file, data[total:])
		if n > 0 {total += n}
		if err != nil || n == 0 {return false}
	}
	return true
}

// Materialize exactly `size` guest bytes into the profile-local journal.
// The returned path belongs to `allocator`; no file payload survives in RAM.
guest_prepare_file :: proc(
	v: ^Volume,
	destination: string,
	chain: []u32,
	size: u32,
	source: Guest_Stream_Source = .Guest_View,
	allocator := context.allocator,
) -> (
	temporary: string,
	fingerprint: u64,
	error: Guest_Stream_Error,
) {
	if u64(size) > u64(len(chain)) * CLUSTER_BYTES {
		return "", 0, .Read
	}
	profile := filepath.dir(v.root_dir)
	journal_dir, path_error := filepath.join(
		{profile, OVERLAY_DIRECTORY},
		context.temp_allocator,
	)
	if path_error != nil || os.make_directory_all(journal_dir) != nil {
		return "", 0, .Create
	}
	pattern := fmt.tprintf(
		"%s%d-*%s",
		STREAM_TEMP_PREFIX,
		os.get_pid(),
		STREAM_TEMP_SUFFIX,
	)
	file, create_error := journal_create_temp_file(journal_dir, pattern)
	if create_error != nil {return "", 0, .Create}
	temporary = strings.clone(os.name(file), allocator)
	closed := false
	success := false
	defer if !success {
		if !closed {_ = os.close(file)}
		_ = os.remove(temporary)
		delete(temporary, allocator)
		temporary = ""
	}

	buffer: [GUEST_STREAM_BYTES]u8
	remaining := u64(size)
	fingerprint = FINGERPRINT_OFFSET
	chain_index := 0
	for remaining > 0 && chain_index < len(chain) {
		clusters := min(
			GUEST_STREAM_BYTES / CLUSTER_BYTES,
			int((remaining + CLUSTER_BYTES - 1) / CLUSTER_BYTES),
			len(chain) - chain_index,
		)
		if source == .Orphan_Clusters {
			for offset in 0 ..< clusters {
				cluster := chain[chain_index + offset]
				block := buffer[offset * CLUSTER_BYTES:][:CLUSTER_BYTES]
				for &byte in block {byte = 0}
				if orphan_has(v, cluster) && !orphan_read_cluster(v, cluster, block) {
					return "", 0, .Read
				}
			}
		} else {
			// Stop at a non-contiguous FAT link so one read never crosses into an
			// unrelated physical cluster.
			for clusters > 1 &&
			    chain[chain_index + clusters - 1] != chain[chain_index] + u32(clusters - 1) {
				clusters -= 1
			}
			lba := u64(PART_START_LBA) +
				u64(cluster_to_lba(&v.alloc.geo, chain[chain_index]))
			if !volume_read(v, lba, buffer[:clusters * CLUSTER_BYTES]) {
				return "", 0, .Read
			}
		}
		used := int(min(remaining, u64(clusters * CLUSTER_BYTES)))
		fingerprint = guest_fingerprint_add(fingerprint, buffer[:used])
		if !guest_stream_write_all(file, buffer[:used]) {return "", 0, .Write}
		remaining -= u64(used)
		chain_index += clusters
	}
	if remaining != 0 {return "", 0, .Read}
	if close_error := os.close(file); close_error != nil {
		closed = true
		return "", 0, .Close
	}
	closed = true
	v.journal.streamed_guest_files += 1
	v.journal.streamed_guest_bytes += u64(size)
	success = true
	return temporary, fingerprint, .None
}

guest_prepared_discard :: proc(path: string, allocator: runtime.Allocator) {
	if path == "" {return}
	_ = os.remove(path)
	delete(path, allocator)
}

guest_prepared_install :: proc(temporary, destination: string) -> bool {
	return os.rename(temporary, destination) == nil
}
