// SPDX-License-Identifier: GPL-3.0-only
package host

import "core:testing"
import "core:time"

@(private = "file")
at_ms :: proc(milliseconds: i64) -> time.Tick {
	return {_nsec = milliseconds * 1_000_000}
}

// A capture exists as soon as the window has drawn, and after that the interval
// paces it. Without the first-frame rule a run shorter than one interval would
// produce no image at all.
@(test)
host_test_screenshot_interval_paces_captures :: proc(t: ^testing.T) {
	state := Host_Screenshot {
		path        = "shot.png",
		interval_ms = 1000,
	}
	testing.expect(t, host_screenshot_due(&state, at_ms(0)))

	state.captured = 1
	state.last = at_ms(0)
	testing.expect(t, !host_screenshot_due(&state, at_ms(999)))
	testing.expect(t, host_screenshot_due(&state, at_ms(1000)))
	testing.expect(t, host_screenshot_due(&state, at_ms(5000)))

	// A non-positive interval is every frame, which the caller may ask for.
	state.interval_ms = 0
	testing.expect(t, host_screenshot_due(&state, at_ms(1)))
}

// A failed first capture must not retry on every frame for the rest of the run,
// which is what would happen if only successes advanced the pacing.
@(test)
host_test_screenshot_failure_still_paces :: proc(t: ^testing.T) {
	state := Host_Screenshot {
		path        = "shot.png",
		interval_ms = 1000,
		failures    = 1,
		last        = at_ms(0),
	}
	testing.expect(t, !host_screenshot_due(&state, at_ms(999)))
	testing.expect(t, host_screenshot_due(&state, at_ms(1000)))
}

// No path is no work. The flag being absent must not cost a readback per frame.
@(test)
host_test_screenshot_without_a_path_is_never_due :: proc(t: ^testing.T) {
	state: Host_Screenshot
	testing.expect(t, !host_screenshot_due(&state, at_ms(0)))
	testing.expect(t, !host_screenshot_due(&state, at_ms(100_000)))
	testing.expect(t, !host_screenshot_due(nil, at_ms(0)))
}
