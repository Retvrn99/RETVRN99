// SPDX-License-Identifier: GPL-3.0-only
package fat32

import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"

Guest_Index_Info :: struct {
	index: int,
	count: int,
}

Reconcile_Rename :: struct {
	old_key:  Mirror_Key,
	new_key:  Mirror_Key,
	entry:    Mirror_Entry,
	new_path: string,
}

Reconcile_Delete :: struct {
	key:   Mirror_Key,
	entry: Mirror_Entry,
}

Reconcile_Donor :: struct {
	key:        Mirror_Key,
	entry:      Mirror_Entry,
	target_key: Mirror_Key,
}

reconcile_seed :: proc(v: ^Volume) {
	reconcile_seed_dir(v, v.alloc.root)
}

@(private = "file")
reconcile_seed_dir :: proc(v: ^Volume, dir: ^Node) {
	shorts := dir_short_names(dir, context.temp_allocator)
	for child, index in dir.children {
		child.short = shorts[index]
		key := Mirror_Key{dir.first_cluster, child.short}
		v.journal.mirrored[key] = Mirror_Entry {
			host_path     = strings.clone(child.host_path, v.allocator),
			first_cluster = child.first_cluster,
			size          = u32(min(child.size, u64(0xFFFF_FFFF))),
			is_dir        = child.is_dir,
			base_node     = child,
		}
		if child.is_dir {
			reconcile_seed_dir(v, child)
		}
	}
}

volume_reconcile :: proc(v: ^Volume) -> bool {
	if v == nil || v.frozen {
		return false
	}
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, v.allocator, v.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	ta := mem.dynamic_arena_allocator(&arena)
	scan := guest_scan_tree(v, ta)
	if v.frozen {return false}
	if scan.error != .None {
		volume_fail(v, fmt.tprintf("unsafe FAT32 guest path (%v)", scan.error))
		return false
	}
	host_failed := false
	by_key := make(map[Mirror_Key]Guest_Index_Info, ta)
	by_cluster := make(map[u32]Guest_Index_Info, ta)
	for entry, index in scan.entries {
		key_info := by_key[entry.key]
		if key_info.count == 0 {key_info.index = index}
		key_info.count += 1
		by_key[entry.key] = key_info
		if entry.first_cluster >= 2 {
			cluster_info := by_cluster[entry.first_cluster]
			if cluster_info.count == 0 {cluster_info.index = index}
			cluster_info.count += 1
			by_cluster[entry.first_cluster] = cluster_info
		}
	}

	renames := make([dynamic]Reconcile_Rename, ta)
	deletes := make([dynamic]Reconcile_Delete, ta)
	donors := make([dynamic]Reconcile_Donor, ta)
	handled := make(map[Mirror_Key]bool, ta)

	for key, mirrored in v.journal.mirrored {
		if info := by_key[key]; info.count > 0 {
			continue
		}
		if !scan.scanned_dirs[key.parent_cluster] {
			continue
		}
		claim := by_cluster[mirrored.first_cluster]
		if mirrored.first_cluster >= 2 && claim.count == 1 {
			live := &scan.entries[claim.index]
			target, target_exists := v.journal.mirrored[live.key]
			if live.is_dir == mirrored.is_dir && !target_exists && !handled[live.key] {
				append(&renames, Reconcile_Rename{key, live.key, mirrored, live.host_path})
				handled[live.key] = true
				continue
			}
			if !mirrored.is_dir &&
			   target_exists &&
			   !target.is_dir &&
			   target.first_cluster != mirrored.first_cluster {
				append(&donors, Reconcile_Donor{key, mirrored, live.key})
				continue
			}
		}
		freed :=
			mirrored.first_cluster < 2 ||
			volume_fat_entry(v, mirrored.first_cluster) & 0x0FFF_FFFF == 0
		if freed && claim.count == 0 {
			append(&deletes, Reconcile_Delete{key, mirrored})
		}
	}

	for action in renames {
		if action.entry.host_path != action.new_path {
			old_exists := os.exists(action.entry.host_path)
			new_exists := os.exists(action.new_path)
			already_applied :=
				!old_exists &&
				new_exists &&
				action.entry.base_node != nil &&
				action.entry.base_node.host_path == action.new_path
			if old_exists && !new_exists {
				if err := os.rename(action.entry.host_path, action.new_path); err == nil {
					already_applied = true
				}
			}
			if !already_applied {
				log.warnf(
					"fat32: holding rename %s -> %s",
					action.entry.host_path,
					action.new_path,
				)
				host_failed = true
				delete_key(&handled, action.new_key)
				continue
			}
		}
		entry := action.entry
		delete_key(&v.journal.mirrored, action.old_key)
		delete(entry.host_path, v.allocator)
		entry.host_path = strings.clone(action.new_path, v.allocator)
		v.journal.mirrored[action.new_key] = entry
		if entry.base_node != nil {
			reconcile_rebase_node(v, entry.base_node, action.new_path)
		}
	}

	delete_kinds := [2]bool{false, true}
	for want_dir in delete_kinds {
		for action in deletes {
			if action.entry.is_dir != want_dir {
				continue
			}
			if action.entry.base_node != nil {
				if action.entry.base_node == v.alloc.root ||
				   !managed_node_attached(v.alloc.root, action.entry.base_node) ||
				   action.entry.base_node.is_dir != action.entry.is_dir {
					volume_fail(v, "FAT32 delete lost its base-node ownership")
					host_failed = true
					continue
				}
			}
			err := os.remove(action.entry.host_path)
			if err != nil && os.exists(action.entry.host_path) {
				log.warnf("fat32: holding delete %s: %v", action.entry.host_path, err)
				host_failed = true
				continue
			}
			if action.entry.base_node != nil {
				if !managed_node_destroy(v, action.entry.base_node) {
					volume_fail(v, "FAT32 delete ownership teardown failed")
					host_failed = true
				}
			} else {
				reconcile_mirror_remove(v, action.key)
			}
		}
	}

	for &live in scan.entries {
		if !live.is_dir ||
		   !live.valid ||
		   by_key[live.key].count != 1 ||
		   by_cluster[live.first_cluster].count != 1 {
			continue
		}
		entry, exists := v.journal.mirrored[live.key]
		owner := entry.base_node
		if owner != nil && (!managed_node_attached(v.alloc.root, owner) || !owner.is_dir) {
			volume_fail(v, "FAT32 directory ownership cannot be reconciled")
			host_failed = true
			continue
		}
		parent: ^Node
		chain: [dynamic]u32
		if owner == nil {
			parent = reconcile_node_for_cluster(v, live.key.parent_cluster)
			chain, chain_state := volume_chain_inspect(v, live.first_cluster, ta)
			if chain_state != .Complete || parent == nil || !parent.is_dir {
				volume_fail(v, "FAT32 directory ownership cannot be reconciled")
				host_failed = true
				continue
			}
		}
		if !exists {
			if os.make_directory_all(live.host_path) != nil {
				log.warnf("fat32: holding directory create %s", live.host_path)
				host_failed = true
				continue
			}
			entry = Mirror_Entry {
				is_dir = true,
			}
		} else if entry.host_path != live.host_path {
			if os.exists(entry.host_path) && !os.exists(live.host_path) {
				if err := os.rename(entry.host_path, live.host_path); err != nil {
					log.warnf(
						"fat32: holding directory rename %s -> %s: %v",
						entry.host_path,
						live.host_path,
						err,
					)
					host_failed = true
					continue
				}
			}
			if entry.base_node != nil {
				reconcile_rebase_node(v, entry.base_node, live.host_path)
			}
		}
		entry.first_cluster = live.first_cluster
		entry.size = 0
		entry.is_dir = true
		if owner == nil {
			candidate := reconcile_node_for_cluster(v, live.first_cluster)
			if candidate != nil &&
			   candidate != parent &&
			   candidate.is_dir &&
			   managed_node_attached(v.alloc.root, candidate) &&
			   candidate.host_path == live.host_path {
				owner = candidate
			} else {
				owner = managed_node_create(
					v,
					parent,
					live.name,
					live.host_path,
					live.key.short,
					live.first_cluster,
					0,
					true,
					chain[:],
				)
			}
		}
		if owner == nil {
			volume_fail(v, "FAT32 directory ownership update failed")
			host_failed = true
			continue
		}
		entry.base_node = owner
		reconcile_mirror_store(v, live.key, entry, live.host_path)
	}

	materialized := make(map[Mirror_Key]bool, ta)
	for &live in scan.entries {
		if live.is_dir ||
		   !live.valid ||
		   by_key[live.key].count != 1 ||
		   (live.first_cluster >= 2 && by_cluster[live.first_cluster].count != 1) {
			continue
		}
		entry, exists := v.journal.mirrored[live.key]
		if exists && entry.is_dir {
			continue
		}
		chain, chain_state := volume_chain_inspect(v, live.first_cluster, ta)
		parent := reconcile_node_for_cluster(v, live.key.parent_cluster)
		if (live.first_cluster >= 2 && chain_state != .Complete) ||
		   parent == nil ||
		   !parent.is_dir ||
		   entry.base_node != nil &&
			   (!managed_node_attached(v.alloc.root, entry.base_node) || entry.base_node.is_dir) {
			volume_fail(v, "FAT32 file ownership cannot be reconciled")
			host_failed = true
			continue
		}
		if exists && entry.host_path != live.host_path {
			if os.exists(entry.host_path) && !os.exists(live.host_path) {
				if err := os.rename(entry.host_path, live.host_path); err != nil {
					log.warnf(
						"fat32: holding file rename %s -> %s: %v",
						entry.host_path,
						live.host_path,
						err,
					)
					host_failed = true
					continue
				}
			}
			if entry.base_node != nil {
				reconcile_rebase_node(v, entry.base_node, live.host_path)
			}
			reconcile_mirror_store(v, live.key, entry, live.host_path)
			entry = v.journal.mirrored[live.key]
		}

		metadata_changed :=
			!exists || entry.first_cluster != live.first_cluster || entry.size != live.size
		if !metadata_changed && !live.data_touched {
			continue
		}
		data, ok := guest_read_file(v, live.first_cluster, live.size, v.allocator)
		if !ok {
			host_failed = true
			continue
		}
		fingerprint := reconcile_fingerprint(data)
		if exists && entry.has_fingerprint && entry.fingerprint == fingerprint {
			delete(data, v.allocator)
			entry.first_cluster = live.first_cluster
			entry.size = live.size
			if !reconcile_bind_live_node(v, &entry, &live, parent, chain[:]) {
				volume_fail(v, "FAT32 unchanged file ownership update failed")
				host_failed = true
				continue
			}
			reconcile_mirror_store(v, live.key, entry, live.host_path)
			materialized[live.key] = true
			continue
		}
		if exists && entry.base_node != nil && !reconcile_snapshot_base_file(v, entry.base_node) {
			delete(data, v.allocator)
			host_failed = true
			continue
		}
		if !reconcile_atomic_write(live.host_path, data) {
			delete(data, v.allocator)
			host_failed = true
			continue
		}
		delete(data, v.allocator)
		entry.first_cluster = live.first_cluster
		entry.size = live.size
		entry.is_dir = false
		entry.fingerprint = fingerprint
		entry.has_fingerprint = true
		if !reconcile_bind_live_node(v, &entry, &live, parent, chain[:]) {
			volume_fail(v, "FAT32 file ownership update failed")
			host_failed = true
			continue
		}
		reconcile_mirror_store(v, live.key, entry, live.host_path)
		materialized[live.key] = true
	}

	for donor in donors {
		if !materialized[donor.target_key] {
			continue
		}
		target, target_ok := v.journal.mirrored[donor.target_key]
		live_info := by_key[donor.target_key]
		if !target_ok || live_info.count != 1 {
			volume_fail(v, "FAT32 replacement target lost its mirror ownership")
			host_failed = true
			continue
		}
		live := &scan.entries[live_info.index]
		chain, chain_state := volume_chain_inspect(v, live.first_cluster, ta)
		if chain_state != .Complete {
			volume_fail(v, "FAT32 replacement target chain became invalid")
			host_failed = true
			continue
		}
		donor_node := donor.entry.base_node
		target_node := target.base_node
		donor_invalid :=
			donor_node != nil &&
			(donor_node == v.alloc.root ||
					!managed_node_attached(v.alloc.root, donor_node) ||
					donor_node.is_dir)
		target_invalid :=
			target_node != nil &&
			(target_node == v.alloc.root ||
					!managed_node_attached(v.alloc.root, target_node) ||
					target_node.is_dir)
		if donor_invalid || target_invalid {
			volume_fail(v, "FAT32 replacement lost its base-node ownership")
			host_failed = true
			continue
		}
		owner := target_node
		if owner == nil {owner = donor_node}
		parent: ^Node
		if owner != nil {
			parent = reconcile_node_for_cluster(v, live.key.parent_cluster)
			if parent == nil || !parent.is_dir {
				volume_fail(v, "FAT32 replacement parent ownership is unavailable")
				host_failed = true
				continue
			}
		}
		if donor.entry.host_path != target.host_path {
			if err := os.remove(donor.entry.host_path);
			   err != nil && os.exists(donor.entry.host_path) {
				log.warnf("fat32: holding replacement donor %s: %v", donor.entry.host_path, err)
				host_failed = true
				continue
			}
		}
		if donor_node != nil && donor_node != owner {
			if !managed_node_destroy(v, donor_node) {
				volume_fail(v, "FAT32 replacement donor teardown failed")
				host_failed = true
				continue
			}
		} else {
			reconcile_mirror_remove(v, donor.key)
		}
		if owner != nil {
			if !managed_node_rebind(
				v,
				owner,
				parent,
				live.name,
				live.host_path,
				live.key.short,
				live.first_cluster,
				live.size,
				false,
				chain[:],
			) {
				volume_fail(v, "FAT32 replacement target ownership update failed")
				host_failed = true
				continue
			}
			target.base_node = owner
			target.first_cluster = live.first_cluster
			target.size = live.size
			v.journal.mirrored[donor.target_key] = target
		}
	}
	return !host_failed
}

@(private = "file")
reconcile_mirror_store :: proc(v: ^Volume, key: Mirror_Key, entry: Mirror_Entry, path: string) {
	new_path := strings.clone(path, v.allocator)
	if old, ok := v.journal.mirrored[key]; ok {
		delete(old.host_path, v.allocator)
	}
	stored := entry
	stored.host_path = new_path
	v.journal.mirrored[key] = stored
}

@(private = "file")
reconcile_mirror_remove :: proc(v: ^Volume, key: Mirror_Key) {
	if entry, ok := v.journal.mirrored[key]; ok {
		delete(entry.host_path, v.allocator)
		delete_key(&v.journal.mirrored, key)
	}
}

@(private = "file")
reconcile_node_for_cluster :: proc(v: ^Volume, cluster: u32) -> ^Node {
	if v == nil || v.alloc.root == nil {return nil}
	if cluster == v.alloc.root.first_cluster {return v.alloc.root}
	if claim, ok := v.journal.claimed[cluster]; ok {return claim.node}
	if cluster < u32(len(v.alloc.by_cluster)) {return v.alloc.by_cluster[cluster]}
	return nil
}

@(private = "file")
reconcile_bind_live_node :: proc(
	v: ^Volume,
	entry: ^Mirror_Entry,
	live: ^Guest_Entry,
	parent: ^Node,
	chain: []u32,
) -> bool {
	owner := entry.base_node
	if owner != nil &&
	   owner.parent == parent &&
	   !owner.is_dir &&
	   owner.first_cluster == live.first_cluster &&
	   owner.size == u64(live.size) &&
	   owner.host_path == live.host_path {
		return true
	}
	if owner == nil {
		candidate := reconcile_node_for_cluster(v, live.first_cluster)
		if candidate != nil &&
		   candidate != parent &&
		   !candidate.is_dir &&
		   managed_node_attached(v.alloc.root, candidate) &&
		   candidate.host_path == live.host_path {
			owner = candidate
		} else {
			owner = managed_node_create(
				v,
				parent,
				live.name,
				live.host_path,
				live.key.short,
				live.first_cluster,
				live.size,
				false,
				chain,
			)
		}
	} else if !managed_node_rebind(
		v,
		owner,
		parent,
		live.name,
		live.host_path,
		live.key.short,
		live.first_cluster,
		live.size,
		false,
		chain,
	) {
		return false
	}
	if owner == nil {return false}
	entry.base_node = owner
	return true
}

@(private = "file")
reconcile_rebase_node :: proc(v: ^Volume, node: ^Node, path: string) {
	delete(node.host_path, v.allocator)
	node.host_path = strings.clone(path, v.allocator)
	if !node.is_dir {
		return
	}
	for child in node.children {
		child_path, _ := filepath.join({path, child.name}, context.temp_allocator)
		reconcile_rebase_node(v, child, child_path)
	}
}

@(private)
reconcile_snapshot_base_file :: proc(v: ^Volume, node: ^Node) -> bool {
	if node == nil || node.is_dir || node.first_cluster < 2 || v.journal.snapshotted[node] {
		return true
	}
	f, open_error := os.open(node.host_path)
	if open_error != nil {
		volume_fail(v, fmt.tprintf("cannot open backing file %s for snapshot", node.host_path))
		return false
	}
	defer os.close(f)
	for cluster_index in u32(0) ..< node.cluster_len {
		cluster := node.first_cluster + cluster_index
		first_rel := v.alloc.geo.data_start + (cluster - 2) * SECTORS_PER_CLUSTER
		for sector in u32(0) ..< SECTORS_PER_CLUSTER {
			rel := first_rel + sector
			if _, exists := v.journal.overlay[rel]; exists {
				continue
			}
			block: [SECTOR]u8
			offset := i64(cluster_index) * CLUSTER_BYTES + i64(sector) * SECTOR
			expected := int(clamp(i64(node.size) - offset, i64(0), i64(SECTOR)))
			if !backing_read_exact(v, f, node.host_path, block[:expected], offset) {
				return false
			}
			overlay_put(v, rel, block[:])
		}
	}
	v.journal.snapshotted[node] = true
	return true
}

@(private = "file")
reconcile_atomic_write :: proc(path: string, data: []u8) -> bool {
	temporary := fmt.tprintf("%s.retvrn99-%d.tmp", path, os.get_pid())
	defer _ = os.remove(temporary)
	f, open_error := os.open(temporary, {.Write, .Create, .Trunc})
	if open_error != nil {
		log.warnf("fat32: cannot create temporary file for %s", path)
		return false
	}
	closed := false
	defer if !closed {os.close(f)}
	total := 0
	for total < len(data) {
		n, write_error := os.write(f, data[total:])
		if write_error != nil || n == 0 {
			log.warnf("fat32: cannot write temporary file for %s", path)
			return false
		}
		total += n
	}
	if close_error := os.close(f); close_error != nil {
		closed = true
		log.warnf("fat32: cannot close temporary file for %s", path)
		return false
	}
	closed = true
	if rename_error := os.rename(temporary, path); rename_error != nil {
		log.warnf("fat32: cannot install temporary file for %s", path)
		return false
	}
	return true
}

@(private = "file")
reconcile_fingerprint :: proc(data: []u8) -> u64 {
	hash: u64 = 0xCBF29CE484222325
	for byte in data {
		hash = (hash ~ u64(byte)) * 0x100000001B3
	}
	return hash
}
