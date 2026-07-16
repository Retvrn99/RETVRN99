// SPDX-License-Identifier: GPL-3.0-only
package profile

import "core:os"
import "core:path/filepath"

PROFILE_DIRECTORY :: ".retvrn99"

Paths :: struct {
	root:          string,
	default_image: string,
	settings:      string,
	cmos:          string,
	install:       string,
	install_state: string,
}

paths_from_root :: proc(root: string, allocator := context.allocator) -> (Paths, os.Error) {
	clean_root, cerr := filepath.clean(root, allocator)
	if cerr != nil {
		return {}, os.Error(cerr)
	}

	paths := Paths {
		root = clean_root,
	}
	path: string
	path, cerr = filepath.join({paths.root, "c_drive.img"}, allocator)
	if cerr != nil {
		paths_destroy(&paths, allocator)
		return {}, os.Error(cerr)
	}
	paths.default_image = path
	path, cerr = filepath.join({paths.root, "settings.json"}, allocator)
	if cerr != nil {
		paths_destroy(&paths, allocator)
		return {}, os.Error(cerr)
	}
	paths.settings = path
	path, cerr = filepath.join({paths.root, "cmos.bin"}, allocator)
	if cerr != nil {
		paths_destroy(&paths, allocator)
		return {}, os.Error(cerr)
	}
	paths.cmos = path
	path, cerr = filepath.join({paths.root, "install"}, allocator)
	if cerr != nil {
		paths_destroy(&paths, allocator)
		return {}, os.Error(cerr)
	}
	paths.install = path
	path, cerr = filepath.join({paths.root, "install-state.json"}, allocator)
	if cerr != nil {
		paths_destroy(&paths, allocator)
		return {}, os.Error(cerr)
	}
	paths.install_state = path
	return paths, nil
}

paths_from_home :: proc(home: string, allocator := context.allocator) -> (Paths, os.Error) {
	root, rerr := filepath.join({home, PROFILE_DIRECTORY}, allocator)
	if rerr != nil {
		return {}, os.Error(rerr)
	}
	defer delete(root, allocator)
	return paths_from_root(root, allocator)
}

paths_default :: proc(allocator := context.allocator) -> (Paths, os.Error) {
	home, herr := os.user_home_dir(allocator)
	if herr != nil {
		return {}, herr
	}
	defer delete(home, allocator)
	return paths_from_home(home, allocator)
}

paths_destroy :: proc(paths: ^Paths, allocator := context.allocator) {
	if paths == nil {
		return
	}
	delete(paths.root, allocator)
	delete(paths.default_image, allocator)
	delete(paths.settings, allocator)
	delete(paths.cmos, allocator)
	delete(paths.install, allocator)
	delete(paths.install_state, allocator)
	paths^ = {}
}
