// SPDX-License-Identifier: GPL-3.0-only
package fat32

import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
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

Reconcile_Replacement :: struct {
	old_key:     Mirror_Key,
	entry:       Mirror_Entry,
	prepared:    string,
	fingerprint: u64,
}

Reconcile_Identity :: enum {
	Match,
	Reused,
	Unavailable,
}

@(private = "file")
reconcile_entry_backing_path :: proc(entry: Mirror_Entry) -> string {
	if entry.base_node != nil {return entry.base_node.host_path}
	return entry.host_path
}

@(private = "file")
reconcile_same_path :: proc(left, right: string) -> bool {
	if left == right {return true}
	when ODIN_OS == .Windows {return strings.equal_fold(left, right)}
	return false
}

@(private = "file")
reconcile_mirror_rebase_tree :: proc(v: ^Volume, root: ^Node) {
	keys := make([dynamic]Mirror_Key, context.temp_allocator)
	defer delete(keys)
	for key, entry in v.journal.mirrored {
		if entry.base_node != nil && reconcile_node_descends_from(entry.base_node, root) {
			append(&keys, key)
		}
	}
	for key in keys {
		entry, ok := v.journal.mirrored[key]
		if !ok || entry.base_node == nil || !reconcile_node_descends_from(entry.base_node, root) {
			continue
		}
		new_path := strings.clone(entry.base_node.host_path, v.allocator)
		delete(entry.host_path, v.allocator)
		entry.host_path = new_path
		v.journal.mirrored[key] = entry
	}
}

@(private = "file")
reconcile_rebase_backing_nodes :: proc(v: ^Volume, node: ^Node, path: string) -> bool {
	if node == nil {return true}
	for child in node.children {
		child_path, path_error := filepath.join(
			{path, filepath.base(child.host_path)},
			context.temp_allocator,
		)
		if path_error != nil {return false}
		child_ok := reconcile_rebase_backing_nodes(v, child, child_path)
		delete(child_path, context.temp_allocator)
		if !child_ok {
			return false
		}
	}
	delete(node.host_path, v.allocator)
	node.host_path = strings.clone(path, v.allocator)
	return true
}

@(private = "file")
reconcile_rebase_backing_tree :: proc(v: ^Volume, node: ^Node, path: string) -> bool {
	if node == nil {return true}
	if !reconcile_rebase_backing_nodes(v, node, path) {return false}
	reconcile_mirror_rebase_tree(v, node)
	return true
}

@(private = "file")
reconcile_move_backing :: proc(v: ^Volume, entry: ^Mirror_Entry, destination: string) -> bool {
	source := reconcile_entry_backing_path(entry^)
	if reconcile_same_path(source, destination) {
		if !os.exists(source) {return false}
		if entry.base_node != nil && entry.base_node.host_path != destination {
			return reconcile_rebase_backing_tree(v, entry.base_node, destination)
		}
		return true
	}
	if !os.exists(source) || os.exists(destination) {return false}
	if os.rename(source, destination) != nil {return false}
	return reconcile_rebase_backing_tree(v, entry.base_node, destination)
}

@(private = "file")
reconcile_chain_identity_add :: proc(identity: u64, cluster: u32) -> u64 {
	result := identity
	for shift in 0 ..< 4 {
		result = (result ~ u64(u8(cluster >> u32(shift * 8)))) * FINGERPRINT_PRIME
	}
	return result
}

@(private = "file")
reconcile_chain_identity :: proc(chain: []u32) -> u64 {
	identity := FINGERPRINT_OFFSET
	for cluster in chain {identity = reconcile_chain_identity_add(identity, cluster)}
	return reconcile_chain_identity_add(identity, u32(len(chain)))
}

@(private = "file")
reconcile_contiguous_chain_identity :: proc(first, count: u32) -> u64 {
	identity := FINGERPRINT_OFFSET
	for index in u32(0) ..< count {
		identity = reconcile_chain_identity_add(identity, first + index)
	}
	return reconcile_chain_identity_add(identity, count)
}

@(private = "file")
reconcile_node_descends_from :: proc(node, ancestor: ^Node) -> bool {
	for current := node; current != nil; current = current.parent {
		if current == ancestor {return true}
	}
	return false
}

@(private = "file")
reconcile_node_depth :: proc(node: ^Node) -> int {
	depth := 0
	for current := node; current != nil; current = current.parent {depth += 1}
	return depth
}

@(private)
reconcile_chain_issue :: proc(
	v: ^Volume,
	path: string,
	state: Chain_State,
	cluster: u32,
	is_dir: bool,
) {
	kind := is_dir ? "directory" : "file"
	message := fmt.tprintf(
		"FAT32 %s %s has a %v chain at cluster %d",
		kind,
		path,
		state,
		cluster,
	)
	if state == .Incomplete {
		log.warnf("fat32: holding reconcile: %s", message)
	} else {
		volume_fail(v, message)
	}
}

reconcile_seed :: proc(v: ^Volume) {
	reconcile_seed_dir(v, v.alloc.root)
}

@(private = "file")
reconcile_mark_guest_deleted :: proc(
	v: ^Volume,
	key: Mirror_Key,
	entry: Mirror_Entry,
) -> Mirror_Entry {
	if entry.guest_deleted {
		return entry
	}
	stored := entry
	stored.guest_deleted = true
	if stored.base_node != nil {
		release_node_clusters(v, stored.base_node)
		for index := len(v.journal.pending_deletes) - 1; index >= 0; index -= 1 {
			if v.journal.pending_deletes[index].node == stored.base_node {
				ordered_remove(&v.journal.pending_deletes, index)
			}
		}
		for index := len(v.journal.pending_extends) - 1; index >= 0; index -= 1 {
			if v.journal.pending_extends[index] == stored.base_node {
				ordered_remove(&v.journal.pending_extends, index)
			}
		}
	}
	v.journal.mirrored[key] = stored
	return stored
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
			chain_identity = reconcile_contiguous_chain_identity(
				child.first_cluster,
				child.cluster_len,
			),
			has_chain_identity = true,
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
		volume_fail(
			v,
			fmt.tprintf(
				"unsafe FAT32 guest path (%v): parent=%s component=%q",
				scan.error,
				scan.error_parent,
				scan.error_component,
			),
		)
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
	replacements := make(map[Mirror_Key]Reconcile_Replacement, ta)
	handled := make(map[Mirror_Key]bool, ta)
	blocked_keys := make(map[Mirror_Key]bool, ta)
	blocked_directory_clusters := make(map[u32]bool, ta)
	blocked_roots := make([dynamic]^Node, ta)
	prepared_cleanup := make([dynamic]string, ta)
	defer for path in prepared_cleanup {
		if path != "" {_ = os.remove(path)}
	}

	for key, mirrored in v.journal.mirrored {
		if mirrored.guest_deleted {
			append(&deletes, Reconcile_Delete{key, mirrored})
			if info := by_key[key]; info.count > 0 {
				host_failed = true
				blocked_keys[key] = true
				if info.count == 1 {
					live := &scan.entries[info.index]
					if live.is_dir && live.first_cluster >= 2 {
						blocked_directory_clusters[live.first_cluster] = true
					}
				}
			}
			continue
		}
		if info := by_key[key]; info.count > 0 {
			if info.count == 1 {
				live := &scan.entries[info.index]
				backing_path := reconcile_entry_backing_path(mirrored)
				if backing_path != live.host_path {
					if mirrored.is_dir || live.is_dir {
						identity := reconcile_directory_identity(mirrored, live, &scan)
						if identity != .Match {
							log.warnf(
								"fat32: holding directory identity reuse %s -> %s",
								backing_path,
								live.host_path,
							)
							host_failed = true
							blocked_keys[live.key] = true
							if live.first_cluster >= 2 {
								blocked_directory_clusters[live.first_cluster] = true
							}
							if mirrored.base_node != nil {append(&blocked_roots, mirrored.base_node)}
						}
					} else if mirrored.first_cluster != live.first_cluster {
						identity, prepared, fingerprint := reconcile_file_identity(
							v,
							mirrored,
							live,
							ta,
						)
						if prepared != "" {append(&prepared_cleanup, prepared)}
						switch identity {
						case .Reused:
							replacements[live.key] = Reconcile_Replacement {
								old_key     = key,
								entry       = mirrored,
								prepared    = prepared,
								fingerprint = fingerprint,
							}
							handled[live.key] = true
						case .Unavailable:
							log.warnf(
								"fat32: holding ambiguous file identity %s -> %s",
								backing_path,
								live.host_path,
							)
							host_failed = true
							blocked_keys[live.key] = true
						case .Match:
						}
					}
				}
			}
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
				handled[live.key] = true
				if live.is_dir {
					identity := reconcile_directory_identity(mirrored, live, &scan)
					if identity == .Match {
						append(&renames, Reconcile_Rename{key, live.key, mirrored, live.host_path})
						handled[live.key] = true
					} else {
						log.warnf(
							"fat32: holding directory identity reuse %s -> %s",
							reconcile_entry_backing_path(mirrored),
							live.host_path,
						)
						host_failed = true
						blocked_keys[live.key] = true
						blocked_directory_clusters[live.first_cluster] = true
						if mirrored.base_node != nil {append(&blocked_roots, mirrored.base_node)}
					}
				} else {
					identity, prepared, fingerprint := reconcile_file_identity(
						v,
						mirrored,
						live,
						ta,
					)
					if prepared != "" {append(&prepared_cleanup, prepared)}
					switch identity {
					case .Match:
						append(&renames, Reconcile_Rename{key, live.key, mirrored, live.host_path})
						handled[live.key] = true
					case .Reused:
						replacements[live.key] = Reconcile_Replacement {
							old_key     = key,
							entry       = mirrored,
							prepared    = prepared,
							fingerprint = fingerprint,
						}
						handled[live.key] = true
					case .Unavailable:
						log.warnf(
							"fat32: holding ambiguous file identity %s -> %s",
							reconcile_entry_backing_path(mirrored),
							live.host_path,
						)
						host_failed = true
						blocked_keys[live.key] = true
					}
				}
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
	for &action in deletes {
		if action.entry.guest_deleted {continue}
		action.entry = reconcile_mark_guest_deleted(v, action.key, action.entry)
	}

	changed := true
	for changed {
		changed = false
		for live in scan.entries {
			if blocked_keys[live.key] || !blocked_directory_clusters[live.key.parent_cluster] {
				continue
			}
			blocked_keys[live.key] = true
			if live.is_dir && live.first_cluster >= 2 {
				blocked_directory_clusters[live.first_cluster] = true
			}
			changed = true
		}
	}
	for key in replacements {
		if blocked_keys[key] {delete_key(&replacements, key)}
	}

	slice.sort_by(renames[:], proc(a, b: Reconcile_Rename) -> bool {
		return reconcile_node_depth(a.entry.base_node) < reconcile_node_depth(b.entry.base_node)
	})
	for action in renames {
		if blocked_keys[action.new_key] || reconcile_node_blocked(action.entry.base_node, blocked_roots[:]) {
			continue
		}
		entry, entry_exists := v.journal.mirrored[action.old_key]
		if !entry_exists {
			volume_fail(v, "FAT32 rename lost its mirror identity")
			return false
		}
		source_path := strings.clone(reconcile_entry_backing_path(entry), ta)
		if !reconcile_move_backing(v, &entry, action.new_path) {
			log.warnf(
				"fat32: holding rename %s -> %s",
				source_path,
				action.new_path,
			)
			host_failed = true
			blocked_keys[action.new_key] = true
			delete_key(&handled, action.new_key)
			continue
		}
		entry = v.journal.mirrored[action.old_key]
		reconcile_mirror_remove(v, action.old_key)
		entry.host_path = ""
		reconcile_mirror_store(v, action.new_key, entry, action.new_path)
		if entry.base_node != nil {
			live_info := by_key[action.new_key]
			if live_info.count == 1 {
				live := &scan.entries[live_info.index]
				parent := reconcile_node_for_cluster(v, live.key.parent_cluster)
				if !managed_node_update_identity(
					v,
					entry.base_node,
					parent,
					live.name,
					live.host_path,
					live.key.short,
					live.is_dir,
				) {
					volume_fail(v, "FAT32 rename ownership update failed")
					return false
				}
			}
		}
	}

	deleting := make(map[Mirror_Key]bool, ta)
	blocked_deletes := make(map[Mirror_Key]bool, ta)
	delete_roots := make([dynamic]Reconcile_Delete, ta)
	held_delete_roots := make([dynamic]^Node, ta)
	forced_retirement_roots := make([dynamic]^Node, ta)
	for action in deletes {
		deleting[action.key] = true
		if action.entry.is_dir {append(&delete_roots, action)}
	}
	for root in delete_roots {
		if root.entry.base_node == nil {continue}
		retiring_reused_tree := root.entry.guest_deleted && by_key[root.key].count > 0
		if retiring_reused_tree {append(&forced_retirement_roots, root.entry.base_node)}
		blocked := false
		for key, entry in v.journal.mirrored {
			if entry.base_node == nil ||
			   entry.base_node == root.entry.base_node ||
			   !reconcile_node_descends_from(entry.base_node, root.entry.base_node) {
				continue
			}
			if entry.guest_deleted || retiring_reused_tree {continue}
			key_live := by_key[key].count > 0
			cluster_live := entry.first_cluster >= 2 && by_cluster[entry.first_cluster].count > 0
			if key_live || cluster_live {
				blocked = true
				break
			}
		}
		if blocked {
			log.warnf(
				"fat32: holding directory delete %s: live descendant",
				reconcile_entry_backing_path(root.entry),
			)
			host_failed = true
			blocked_deletes[root.key] = true
			append(&held_delete_roots, root.entry.base_node)
			continue
		}
		for key, entry in v.journal.mirrored {
			if deleting[key] ||
			   entry.base_node == nil ||
			   entry.base_node == root.entry.base_node ||
			   !reconcile_node_descends_from(entry.base_node, root.entry.base_node) {
				continue
			}
			append(&deletes, Reconcile_Delete{key, entry})
			deleting[key] = true
		}
	}
	slice.sort_by(deletes[:], proc(a, b: Reconcile_Delete) -> bool {
		if a.entry.is_dir != b.entry.is_dir {return !a.entry.is_dir}
		if !a.entry.is_dir {return false}
		return reconcile_node_depth(a.entry.base_node) > reconcile_node_depth(b.entry.base_node)
	})
	for action in deletes {
		if v.frozen {return false}
		if blocked_deletes[action.key] {continue}
		entry, entry_exists := v.journal.mirrored[action.key]
		if !entry_exists {continue}
		forced_retirement := reconcile_node_blocked(entry.base_node, forced_retirement_roots[:])
		if !forced_retirement && reconcile_node_blocked(entry.base_node, blocked_roots[:]) {continue}
		if entry.base_node != nil {
			if entry.base_node == v.alloc.root ||
			   !managed_node_attached(v.alloc.root, entry.base_node) ||
			   entry.base_node.is_dir != entry.is_dir {
				volume_fail(v, "FAT32 delete lost its base-node ownership")
				host_failed = true
				continue
			}
		}
		backing_path := reconcile_entry_backing_path(entry)
		err := os.remove(backing_path)
		if err != nil && os.exists(backing_path) {
			log.warnf("fat32: holding delete %s: %v", backing_path, err)
			host_failed = true
			continue
		}
		if entry.base_node != nil {
			if !managed_node_destroy(v, entry.base_node) {
				volume_fail(v, "FAT32 delete ownership teardown failed")
				host_failed = true
			}
		} else {
			reconcile_mirror_remove(v, action.key)
		}
	}

	for &live in scan.entries {
		if v.frozen {return false}
		if blocked_keys[live.key] ||
		   !live.is_dir ||
		   !live.valid ||
		   by_key[live.key].count != 1 ||
		   by_cluster[live.first_cluster].count != 1 {
			continue
		}
		entry, exists := v.journal.mirrored[live.key]
		owner := entry.base_node
		if owner != nil && (!managed_node_attached(v.alloc.root, owner) || !owner.is_dir) {
			volume_fail(
				v,
				fmt.tprintf("FAT32 directory %s has an invalid mirror owner", live.host_path),
			)
			host_failed = true
			continue
		}
		parent := reconcile_node_for_cluster(v, live.key.parent_cluster)
		if parent == nil || !parent.is_dir {
			volume_fail(
				v,
				fmt.tprintf(
					"FAT32 directory %s has no owner for parent cluster %d",
					live.host_path,
					live.key.parent_cluster,
				),
			)
			host_failed = true
			continue
		}
		chain, chain_state := volume_chain_inspect(v, live.first_cluster, ta)
		if chain_state != .Complete {
			reconcile_chain_issue(v, live.host_path, chain_state, live.first_cluster, true)
			host_failed = true
			continue
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
			source_path := strings.clone(reconcile_entry_backing_path(entry), ta)
			if !reconcile_move_backing(v, &entry, live.host_path) {
				log.warnf(
					"fat32: holding directory rename %s -> %s",
					source_path,
					live.host_path,
				)
				host_failed = true
				continue
			}
			entry = v.journal.mirrored[live.key]
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
		if owner != nil && chain_adoption_needed(v, owner, chain[:]) {
			if !claim_chain(v, owner, live.first_cluster) {
				host_failed = true
				continue
			}
		}
		identity_changed :=
			owner != nil &&
			(owner.parent != parent ||
				owner.name != live.name ||
				owner.host_path != live.host_path ||
				owner.short != live.key.short)
		if identity_changed &&
		   !managed_node_update_identity(
			   v,
			   owner,
			   parent,
			   live.name,
			   live.host_path,
			   live.key.short,
			   true,
		   ) {
			volume_fail(
				v,
				fmt.tprintf("FAT32 directory identity update failed for %s", live.host_path),
			)
			host_failed = true
			continue
		}
		if owner == nil {
			volume_fail(
				v,
				fmt.tprintf("FAT32 directory ownership update failed for %s", live.host_path),
			)
			host_failed = true
			continue
		}
		owner.size = 0
		entry.base_node = owner
		reconcile_mirror_store(v, live.key, entry, live.host_path)
	}

	donor_targets := make(map[Mirror_Key]bool, ta)
	donor_target_owners := make(map[Mirror_Key]^Node, ta)
	for donor in donors {
		donor_targets[donor.target_key] = true
		donor_target_owners[donor.target_key] = donor.entry.base_node
	}
	donor_target_updates := make(map[Mirror_Key]Mirror_Entry, ta)
	materialized := make(map[Mirror_Key]bool, ta)
	for &live in scan.entries {
		if v.frozen {return false}
		if blocked_keys[live.key] ||
		   live.is_dir ||
		   !live.valid ||
		   by_key[live.key].count != 1 ||
		   (live.first_cluster >= 2 && by_cluster[live.first_cluster].count != 1) {
			continue
		}
		replacement, replacing := replacements[live.key]
		entry, exists := v.journal.mirrored[live.key]
		if replacing {
			old_entry, old_exists := v.journal.mirrored[replacement.old_key]
			if !old_exists || old_entry.is_dir || old_entry.base_node != replacement.entry.base_node {
				volume_fail(v, "FAT32 reused file lost its mirror ownership")
				host_failed = true
				continue
			}
			entry = Mirror_Entry{}
			exists = false
		}
		if exists && entry.is_dir {
			continue
		}
		chain, chain_state := volume_chain_inspect(v, live.first_cluster, ta)
		parent := reconcile_node_for_cluster(v, live.key.parent_cluster)
		if live.first_cluster >= 2 && chain_state != .Complete {
			reconcile_chain_issue(v, live.host_path, chain_state, live.first_cluster, false)
			host_failed = true
			continue
		}
		if parent == nil || !parent.is_dir {
			volume_fail(
				v,
				fmt.tprintf(
					"FAT32 file %s has no owner for parent cluster %d",
					live.host_path,
					live.key.parent_cluster,
				),
			)
			host_failed = true
			continue
		}
		if entry.base_node != nil &&
		   (!managed_node_attached(v.alloc.root, entry.base_node) || entry.base_node.is_dir) {
			volume_fail(
				v,
				fmt.tprintf("FAT32 file %s has an invalid mirror owner", live.host_path),
			)
			host_failed = true
			continue
		}
		if !replacing && exists && entry.host_path != live.host_path {
			source_path := strings.clone(reconcile_entry_backing_path(entry), ta)
			if !reconcile_move_backing(v, &entry, live.host_path) {
				log.warnf(
					"fat32: holding file rename %s -> %s",
					source_path,
					live.host_path,
				)
				host_failed = true
				continue
			}
			entry = v.journal.mirrored[live.key]
			reconcile_mirror_store(v, live.key, entry, live.host_path)
			entry = v.journal.mirrored[live.key]
		}

		chain_identity := reconcile_chain_identity(chain[:])
		metadata_changed :=
			!exists ||
			entry.first_cluster != live.first_cluster ||
			entry.size != live.size ||
			!entry.has_chain_identity ||
			entry.chain_identity != chain_identity
		if !metadata_changed && !live.data_touched {
			continue
		}
		ownership_valid := false
		if donor_targets[live.key] {
			ownership_valid = reconcile_transfer_chain_owners_valid(
				v,
				chain[:],
				entry.base_node,
				donor_target_owners[live.key],
			)
		} else if replacing {
			ownership_valid = reconcile_transfer_chain_owners_valid(
				v,
				chain[:],
				nil,
				replacement.entry.base_node,
			)
		} else {
			preflight_owner := entry.base_node
			if preflight_owner == nil {
				candidate := reconcile_node_for_cluster(v, live.first_cluster)
				if reconcile_node_blocked(candidate, held_delete_roots[:]) {
					host_failed = true
					continue
				}
				if candidate != nil &&
				   candidate != parent &&
				   !candidate.is_dir &&
				   managed_node_attached(v.alloc.root, candidate) &&
				   candidate.host_path == live.host_path {
					preflight_owner = candidate
				}
			}
			ownership_valid = claim_chain_owners_valid(
				v,
				preflight_owner,
				live.name,
				chain[:],
			)
		}
		if !ownership_valid {
			if !v.frozen {
				volume_fail(v, "FAT32 file chain overlaps a live owner")
			}
			host_failed = true
			continue
		}
		prepared := replacement.prepared
		fingerprint := replacement.fingerprint
		if !replacing {
			stream_error: Guest_Stream_Error
			prepared, fingerprint, stream_error = guest_prepare_file(
				v,
				live.host_path,
				chain[:],
				live.size,
				.Guest_View,
				ta,
			)
			if stream_error != .None {
				log.warnf("fat32: cannot stream guest file %s (%v)", live.host_path, stream_error)
				host_failed = true
				continue
			}
		}
		if exists && entry.has_fingerprint && entry.fingerprint == fingerprint {
			guest_prepared_discard(prepared, ta)
			entry.first_cluster = live.first_cluster
			entry.size = live.size
			entry.chain_identity = chain_identity
			entry.has_chain_identity = true
			if donor_targets[live.key] {
				donor_target_updates[live.key] = entry
				materialized[live.key] = true
				continue
			}
			if !reconcile_bind_live_node(v, &entry, &live, parent, chain[:]) {
				volume_fail(v, "FAT32 unchanged file ownership update failed")
				host_failed = true
				continue
			}
			reconcile_mirror_store(v, live.key, entry, live.host_path)
			materialized[live.key] = true
			overlay_clear_chain_dirty(v, chain[:])
			continue
		}
		if exists && entry.base_node != nil && !reconcile_snapshot_base_file(v, entry.base_node) {
			guest_prepared_discard(prepared, ta)
			host_failed = true
			continue
		}
		install_prepared := true
		if replacing && os.exists(live.host_path) {
			existing_fingerprint, existing_ok := host_file_fingerprint(live.host_path, live.size)
			if existing_ok && existing_fingerprint == fingerprint {
				_ = os.remove(prepared)
				install_prepared = false
			} else if !reconcile_same_path(
				reconcile_entry_backing_path(replacement.entry),
				live.host_path,
			) {
				log.warnf("fat32: holding reused file at occupied path %s", live.host_path)
				host_failed = true
				continue
			}
		}
		if install_prepared && !guest_prepared_install(prepared, live.host_path) {
			log.warnf("fat32: cannot install temporary file for %s", live.host_path)
			if !replacing {guest_prepared_discard(prepared, ta)}
			host_failed = true
			continue
		}
		if replacing {
			old_entry := v.journal.mirrored[replacement.old_key]
			old_path := reconcile_entry_backing_path(old_entry)
			if !reconcile_same_path(old_path, live.host_path) {
				if remove_error := os.remove(old_path);
				   remove_error != nil && os.exists(old_path) {
					log.warnf("fat32: holding reused file retirement %s: %v", old_path, remove_error)
					host_failed = true
					continue
				}
			}
			reconcile_shadow_chain(v, chain[:])
			if old_entry.base_node != nil {
				if !managed_node_destroy(v, old_entry.base_node) {
					volume_fail(v, "FAT32 reused file ownership teardown failed")
					host_failed = true
					continue
				}
			} else {
				reconcile_mirror_remove(v, replacement.old_key)
			}
			delete_key(&replacements, live.key)
		}
		if !replacing {delete(prepared, ta)}
		entry.first_cluster = live.first_cluster
		entry.size = live.size
		entry.is_dir = false
		entry.chain_identity = chain_identity
		entry.has_chain_identity = true
		entry.fingerprint = fingerprint
		entry.has_fingerprint = true
		if donor_targets[live.key] {
			donor_target_updates[live.key] = entry
			materialized[live.key] = true
			continue
		}
		if !reconcile_bind_live_node(v, &entry, &live, parent, chain[:]) {
			volume_fail(v, "FAT32 file ownership update failed")
			host_failed = true
			continue
		}
		reconcile_mirror_store(v, live.key, entry, live.host_path)
		materialized[live.key] = true
		overlay_clear_chain_dirty(v, chain[:])
	}

	for donor in donors {
		if v.frozen {return false}
		if blocked_keys[donor.target_key] ||
		   reconcile_node_blocked(donor.entry.base_node, blocked_roots[:]) ||
		   !materialized[donor.target_key] {
			continue
		}
		donor_entry, donor_ok := v.journal.mirrored[donor.key]
		current_target, target_ok := v.journal.mirrored[donor.target_key]
		target, update_ok := donor_target_updates[donor.target_key]
		live_info := by_key[donor.target_key]
		if !donor_ok || !target_ok || !update_ok || live_info.count != 1 {
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
		donor_node := donor_entry.base_node
		target_node := current_target.base_node
		target.base_node = target_node
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
		if !reconcile_transfer_chain_owners_valid(v, chain[:], target_node, donor_node) {
			volume_fail(v, "FAT32 replacement target chain overlaps a live owner")
			host_failed = true
			continue
		}
		owner := target_node
		if owner == nil {owner = donor_node}
		parent := reconcile_node_for_cluster(v, live.key.parent_cluster)
		if parent == nil || !parent.is_dir {
			volume_fail(v, "FAT32 replacement parent ownership is unavailable")
			host_failed = true
			continue
		}
		donor_path := reconcile_entry_backing_path(donor_entry)
		target_path := reconcile_entry_backing_path(target)
		if donor_path != target_path {
			if err := os.remove(donor_path);
			   err != nil && os.exists(donor_path) {
				log.warnf("fat32: holding replacement donor %s: %v", donor_path, err)
				host_failed = true
				continue
			}
		}
		reconcile_shadow_chain(v, chain[:])
		if donor_node != nil && donor_node != owner {
			if !managed_node_destroy(v, donor_node) {
				volume_fail(v, "FAT32 replacement donor teardown failed")
				host_failed = true
				continue
			}
		} else {
			reconcile_mirror_remove(v, donor.key)
		}
		created_owner := false
		if owner == nil {
			owner = managed_node_create(
				v,
				parent,
				live.name,
				live.host_path,
				live.key.short,
				0,
				live.size,
				false,
				nil,
			)
			created_owner = owner != nil
		}
		if owner == nil ||
		   !managed_node_update_identity(
				   v,
				   owner,
				   parent,
				   live.name,
				   live.host_path,
				   live.key.short,
				   false,
			   ) ||
			   !managed_node_adopt_chain(
				   v,
				   owner,
				   live.first_cluster,
				   live.size,
				   chain[:],
			   ) {
			if created_owner {_ = managed_node_destroy(v, owner)}
			volume_fail(v, "FAT32 replacement target ownership update failed")
			host_failed = true
			continue
		}
		target.base_node = owner
		reconcile_mirror_store(v, donor.target_key, target, live.host_path)
		overlay_clear_chain_dirty(v, chain[:])
	}
	if !host_failed {overlay_clear_all_dirty(v)}
	return !host_failed
}

@(private = "file")
reconcile_shadow_chain :: proc(v: ^Volume, chain: []u32) {
	for cluster, index in chain {
		next := index + 1 < len(chain) ? chain[index + 1] : u32(0x0FFF_FFFF)
		v.journal.shadow_fat[cluster] = next
	}
}

@(private = "file")
reconcile_transfer_chain_owners_valid :: proc(
	v: ^Volume,
	chain: []u32,
	target, donor: ^Node,
) -> bool {
	for cluster in chain {
		if claim, ok := v.journal.claimed[cluster]; ok &&
		   claim.node != target && claim.node != donor {
			reclaimable, _ := owner_cluster_reclaimable(v, claim.node, cluster)
			if !reclaimable {return false}
		}
		if cluster < u32(len(v.alloc.by_cluster)) {
			owner := v.alloc.by_cluster[cluster]
			if owner != nil && owner != target && owner != donor {
				reclaimable, _ := owner_cluster_reclaimable(v, owner, cluster)
				if !reclaimable {return false}
			}
		}
	}
	return true
}

@(private = "file")
reconcile_node_blocked :: proc(node: ^Node, roots: []^Node) -> bool {
	for root in roots {
		if root != nil && reconcile_node_descends_from(node, root) {return true}
	}
	return false
}

@(private = "file")
reconcile_directory_identity :: proc(
	mirrored: Mirror_Entry,
	live: ^Guest_Entry,
	scan: ^Guest_Scan,
) -> Reconcile_Identity {
	owner := mirrored.base_node
	if owner == nil || !owner.is_dir || live == nil || !live.is_dir || !live.valid {
		return .Unavailable
	}
	if mirrored.first_cluster != live.first_cluster {return .Reused}

	live_children := 0
	for candidate in scan.entries {
		if candidate.key.parent_cluster == live.first_cluster {live_children += 1}
	}
	if live_children != len(owner.children) {return .Reused}
	for child in owner.children {
		matched := false
		for candidate in scan.entries {
			if candidate.key.parent_cluster == live.first_cluster &&
			   candidate.first_cluster == child.first_cluster &&
			   candidate.is_dir == child.is_dir {
				matched = true
				break
			}
		}
		if !matched {return .Reused}
	}
	return .Match
}

@(private = "file")
reconcile_file_identity :: proc(
	v: ^Volume,
	mirrored: Mirror_Entry,
	live: ^Guest_Entry,
	allocator := context.allocator,
) -> (
	identity: Reconcile_Identity,
	prepared: string,
	fingerprint: u64,
) {
	if live == nil || live.is_dir || !live.valid || mirrored.is_dir {
		return .Unavailable, "", 0
	}
	if !os.exists(reconcile_entry_backing_path(mirrored)) {
		return .Unavailable, "", 0
	}
	chain, chain_state := volume_chain_inspect(v, live.first_cluster, allocator)
	if live.first_cluster >= 2 && chain_state != .Complete {
		return .Unavailable, "", 0
	}
	if mirrored.first_cluster == live.first_cluster && mirrored.size == live.size {
		guest_fingerprint, guest_ok := guest_file_fingerprint(v, chain[:], live.size)
		if !guest_ok {return .Unavailable, "", 0}
		host_fingerprint, host_ok := host_file_fingerprint(
			reconcile_entry_backing_path(mirrored),
			mirrored.size,
		)
		if !host_ok {return .Unavailable, "", 0}
		if host_fingerprint == guest_fingerprint {
			return .Match, "", guest_fingerprint
		}
	}
	stream_error: Guest_Stream_Error
	prepared, fingerprint, stream_error = guest_prepare_file(
		v,
		live.host_path,
		chain[:],
		live.size,
		.Guest_View,
		allocator,
	)
	if stream_error != .None {return .Unavailable, "", 0}
	return .Reused, prepared, fingerprint
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
	   owner.host_path == live.host_path &&
	   !chain_adoption_needed(v, owner, chain) {
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
				chain,
			) {
				return false
			}
		} else {
			owner = managed_node_create(
				v,
				parent,
				live.name,
				live.host_path,
				live.key.short,
				0,
				live.size,
				false,
				nil,
			)
			if owner != nil &&
			   !managed_node_adopt_chain(v, owner, live.first_cluster, live.size, chain) {
				_ = managed_node_destroy(v, owner)
				return false
			}
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
			if overlay_has(v, rel) {
				continue
			}
			block: [SECTOR]u8
			offset := i64(cluster_index) * CLUSTER_BYTES + i64(sector) * SECTOR
			expected := int(clamp(i64(node.size) - offset, i64(0), i64(SECTOR)))
			if !backing_read_exact(v, f, node.host_path, block[:expected], offset) {
				return false
			}
			if !overlay_put(v, rel, block[:]) {return false}
		}
	}
	v.journal.snapshotted[node] = true
	return true
}
