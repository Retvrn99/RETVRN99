// SPDX-License-Identifier: GPL-3.0-only
package host

import "core:testing"

@(test)
host_presentation_test_external_state_is_authoritative_and_unbound_on_destroy :: proc(
	t: ^testing.T,
) {
	h: Host
	external: Host_Presentation_State
	if !testing.expect(t, host_presentation_bind(&h, &external)) {return}
	if !testing.expect(t, host_presentation_start(&h, 9)) {return}

	testing.expect(t, h.presentation_external == &external)
	testing.expect(t, external.accepting)
	testing.expect_value(t, external.lifecycle, u64(9))
	testing.expect_value(t, h.presentation_state, Host_Presentation_State{})

	host_presentation_stop(&h)
	testing.expect(t, !external.accepting)
	host_presentation_destroy(&h)
	testing.expect(t, h.presentation_external == nil)
	testing.expect_value(t, external, Host_Presentation_State{})
}
