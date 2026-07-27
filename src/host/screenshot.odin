// SPDX-License-Identifier: GPL-3.0-only
package host

// Writes what the window is actually showing, which is the only capture that
// includes work the host does outside the guest canvas: the scaled destination,
// the border painted around it, and the surrounding chrome. The guest canvas
// alone is already reachable through the console harness `--frame-dump` and the
// acceptance artifact bundle, and neither can show any of that.

import "core:os"
import "core:strings"
import "core:time"
import sdl3 "vendor:sdl3"
import stbi "vendor:stb/image"

HOST_SCREENSHOT_DEFAULT_INTERVAL_MS :: 1000

Host_Screenshot :: struct {
	path:        string,
	interval_ms: int,
	last:        time.Tick,
	captured:    u64,
	failures:    u64,
}

// The first frame is always due, so a capture exists as soon as the window has
// drawn anything. A non-positive interval captures every frame, which is useful
// for a short sequence and expensive for anything longer.
host_screenshot_due :: proc(state: ^Host_Screenshot, now: time.Tick) -> bool {
	if state == nil || state.path == "" {return false}
	if state.captured == 0 && state.failures == 0 {return true}
	if state.interval_ms <= 0 {return true}
	elapsed := time.duration_milliseconds(time.tick_diff(state.last, now))
	return elapsed >= f64(state.interval_ms)
}

// Reads the renderer's current target, so it must be called while the frame is
// still composed and before it is presented.
@(private = "file")
host_screenshot_write :: proc(h: ^Host, path: string) -> bool {
	if h == nil || h.ren == nil || path == "" {return false}
	surface := sdl3.RenderReadPixels(h.ren, nil)
	if surface == nil {return false}
	defer sdl3.DestroySurface(surface)
	rgba := sdl3.ConvertSurface(surface, .RGBA32)
	if rgba == nil {return false}
	defer sdl3.DestroySurface(rgba)
	if rgba.w <= 0 || rgba.h <= 0 || rgba.pixels == nil {return false}
	// A reader polling the file would otherwise see a partly written image, so
	// the encode lands beside the target and is moved onto it.
	partial := strings.concatenate({path, ".partial"}, context.temp_allocator)
	partial_c := strings.clone_to_cstring(partial, context.temp_allocator)
	if stbi.write_png(partial_c, rgba.w, rgba.h, 4, rgba.pixels, rgba.pitch) == 0 {return false}
	if os.exists(path) && os.remove(path) != nil {
		_ = os.remove(partial)
		return false
	}
	if os.rename(partial, path) != nil {
		_ = os.remove(partial)
		return false
	}
	return true
}

host_screenshot_capture :: proc(h: ^Host, state: ^Host_Screenshot, now: time.Tick) {
	if state == nil || !host_screenshot_due(state, now) {return}
	state.last = now
	if host_screenshot_write(h, state.path) {
		state.captured += 1
	} else {
		state.failures += 1
	}
}
