// SPDX-License-Identifier: GPL-3.0-only
package fat32

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:testing"
import "core:time"

// Shared fixture builder, reused by later synthesis tests. Caller removes the dir.
fat32_test_fixture :: proc(t: ^testing.T) -> string {
	base, terr := os.temp_directory(context.allocator)
	testing.expect(t, terr == nil)
	dir, _ := filepath.join({base, fmt.tprintf("mate98_fixture_%d", time.now()._nsec)})
	testing.expect(t, os.make_directory_all(dir) == nil)
	sub, _ := filepath.join({dir, "DOS"})
	testing.expect(t, os.make_directory(sub) == nil)

	io_sys := make([]u8, 5000)
	for i in 0 ..< len(io_sys) {
		io_sys[i] = u8(i)
	}
	p1, _ := filepath.join({dir, "IO.SYS"})
	p2, _ := filepath.join({dir, "COMMAND.COM"})
	p3, _ := filepath.join({dir, "DOS", "EDIT.HLP"})
	testing.expect(t, os.write_entire_file(p1, io_sys) == nil)
	testing.expect(t, os.write_entire_file(p2, make([]u8, 2000)) == nil)
	testing.expect(t, os.write_entire_file(p3, make([]u8, 100)) == nil)
	return dir
}

@(test)
fat32_test_scan_tree :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := fat32_test_fixture(t)
	defer os.remove_all(dir)

	root := scan_tree(dir)
	testing.expect(t, root != nil)
	if root == nil {
		return
	}
	testing.expect(t, root.is_dir)
	testing.expect(t, root.parent == nil)
	testing.expect(t, len(root.children) == 3)
	if len(root.children) != 3 {
		return
	}
	// sorted case-insensitively
	testing.expect(t, root.children[0].name == "COMMAND.COM")
	testing.expect(t, root.children[1].name == "DOS")
	testing.expect(t, root.children[2].name == "IO.SYS")
	testing.expect(t, root.children[1].is_dir)
	testing.expect(t, !root.children[2].is_dir)
	testing.expect(t, root.children[2].size == 5000)
	testing.expect(t, root.children[0].size == 2000)
	testing.expect(t, root.children[1].parent == root)
	testing.expect(t, len(root.children[1].children) == 1)
	if len(root.children[1].children) == 1 {
		hlp := root.children[1].children[0]
		testing.expect(t, hlp.name == "EDIT.HLP")
		testing.expect(t, hlp.size == 100)
		testing.expect(t, hlp.parent == root.children[1])
		testing.expect(t, filepath.is_abs(hlp.host_path))
	}
	testing.expect(t, filepath.is_abs(root.host_path))
	testing.expect(t, filepath.is_abs(root.children[2].host_path))
}

@(test)
fat32_test_allocate :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := fat32_test_fixture(t)
	defer os.remove_all(dir)

	root := scan_tree(dir)
	testing.expect(t, root != nil)
	if root == nil {
		return
	}
	geo := geometry_make(2048)
	a := allocate(root, geo)

	testing.expect(t, a.root == root)
	testing.expect(t, root.first_cluster == 2)
	testing.expect(t, root.cluster_len == 1)

	if len(root.children) != 3 {
		return
	}
	command := root.children[0]
	dos := root.children[1]
	io := root.children[2]

	// 5000-byte file spans 2 clusters
	testing.expect(t, io.cluster_len == 2)
	testing.expect(t, command.cluster_len == 1)
	testing.expect(t, dos.cluster_len == 1)

	// all allocations contiguous, non-overlapping, and round-tripping via by_cluster
	nodes := [dynamic]^Node{}
	defer delete(nodes)
	append(&nodes, root, dos, io, command)
	if len(dos.children) == 1 {
		append(&nodes, dos.children[0])
	}
	total := u32(0)
	for node in nodes {
		total += node.cluster_len
		testing.expect(t, node.first_cluster >= 2)
		for c in node.first_cluster ..< node.first_cluster + node.cluster_len {
			testing.expect(t, a.by_cluster[c] == node)
		}
	}
	testing.expect(t, a.next_free == 2 + total)
	// clusters outside the allocated range stay free
	testing.expect(t, a.by_cluster[a.next_free] == nil)
	testing.expect(t, len(a.by_cluster) == int(geo.cluster_count) + 2)
}

@(test)
fat32_test_allocate_empty_file :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	base, terr := os.temp_directory(context.allocator)
	testing.expect(t, terr == nil)
	dir, _ := filepath.join({base, fmt.tprintf("mate98_empty_%d", time.now()._nsec)})
	testing.expect(t, os.make_directory_all(dir) == nil)
	defer os.remove_all(dir)
	p, _ := filepath.join({dir, "NUL.TXT"})
	testing.expect(t, os.write_entire_file(p, []u8{}) == nil)

	root := scan_tree(dir)
	testing.expect(t, root != nil)
	if root == nil {
		return
	}
	geo := geometry_make(2048)
	a := allocate(root, geo)
	testing.expect(t, len(root.children) == 1)
	if len(root.children) == 1 {
		testing.expect(t, root.children[0].first_cluster == 0)
		testing.expect(t, root.children[0].cluster_len == 0)
	}
	testing.expect(t, a.next_free == 3) // only the root dir cluster
}
