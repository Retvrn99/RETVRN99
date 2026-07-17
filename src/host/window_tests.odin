// SPDX-License-Identifier: GPL-3.0-only
package host

import "core:testing"
import sdl3 "vendor:sdl3"

@(test)
host_test_gpu_backend_is_portable_vulkan :: proc(t: ^testing.T) {
	testing.expect_value(t, string(HOST_GPU_DRIVER), "vulkan")
}

@(test)
host_test_fullscreen_window_is_borderless_desktop_plus_one_pixel :: proc(t: ^testing.T) {
	bounds := sdl3.Rect{-1920, 0, 1920, 1080}
	testing.expect_value(t, fullscreen_window_rect(bounds), sdl3.Rect{-1920, 0, 1920, 1081})
}
