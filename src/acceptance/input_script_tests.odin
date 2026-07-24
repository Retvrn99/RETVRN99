// SPDX-License-Identifier: GPL-3.0-only
package acceptance

import "core:testing"

@(test)
input_script_test_parses_timed_keyboard_and_mouse_actions :: proc(t: ^testing.T) {
	text := "# setup input\nwait 100\nkey tab\nafter-reset 1\nwait 50\nwait-frame 0x12345678\nwait-stable 250\nwait-change 300\nkey right\nmouse 4 -2 1\nbuttons 0\nwheel -1 0\nsnapshot frame.ppm\nsnapshot-memory ram.bin\n"
	script, diagnostic := input_script_parse(text)
	defer input_script_destroy(&script)
	testing.expect_value(t, diagnostic, Input_Script_Diagnostic.None)
	testing.expect_value(t, len(script.actions), 10)

	actions: [8]Input_Action
	testing.expect_value(t, input_script_drain(&script, 0, 99, 0, false, false, actions[:]), 0)
	n := input_script_drain(&script, 0, 100, 0, false, false, actions[:])
	testing.expect_value(t, n, 1)
	testing.expect_value(t, actions[0].kind, Input_Action_Kind.Key)
	testing.expect_value(t, actions[0].key_n, u8(2))
	testing.expect_value(t, actions[0].key[0], u8(0x0f))
	testing.expect_value(t, actions[0].key[1], u8(0x8f))

	testing.expect_value(t, input_script_drain(&script, 1, 49, 0, false, false, actions[:]), 0)
	testing.expect(t, !input_script_frame_due(&script, 1, 49))
	testing.expect(t, input_script_frame_due(&script, 1, 50))
	testing.expect_value(t, input_script_drain(&script, 1, 50, 0, false, false, actions[:]), 0)
	n = input_script_drain(&script, 1, 50, 0x12345678, false, false, actions[:])
	testing.expect_value(t, n, 0)
	stable_ms, require_change, visual_ok := input_script_visual_due(&script, 1, 50)
	testing.expect(t, visual_ok)
	testing.expect_value(t, stable_ms, i64(250))
	testing.expect(t, !require_change)
	n = input_script_drain(&script, 1, 50, 0, true, false, actions[:])
	testing.expect_value(t, n, 0)
	stable_ms, require_change, visual_ok = input_script_visual_due(&script, 1, 50)
	testing.expect(t, visual_ok)
	testing.expect_value(t, stable_ms, i64(300))
	testing.expect(t, require_change)
	n = input_script_drain(&script, 1, 50, 0, true, false, actions[:])
	testing.expect_value(t, n, 6)
	testing.expect_value(t, actions[0].key_n, u8(4))
	testing.expect_value(
		t,
		actions[0].key,
		[INPUT_SCRIPT_KEY_BYTES]u8{0xe0, 0x4d, 0xe0, 0xcd, 0, 0, 0, 0},
	)
	testing.expect_value(t, actions[1].dx, i32(4))
	testing.expect_value(t, actions[1].dy, i32(-2))
	testing.expect_value(t, actions[3].wheel, i32(-1))
	testing.expect_value(t, actions[4].path, "frame.ppm")
	testing.expect_value(t, actions[5].kind, Input_Action_Kind.Memory_Snapshot)
	testing.expect_value(t, actions[5].path, "ram.bin")
}

@(test)
input_script_test_rejects_invalid_commands :: proc(t: ^testing.T) {
	fixtures := []struct {
		text:       string,
		diagnostic: Input_Script_Diagnostic,
	} {
		{text = "key unknown", diagnostic = .Invalid_Key},
		{text = "wait -1", diagnostic = .Invalid_Number},
		{text = "after-reset 2\nafter-reset 1", diagnostic = .Invalid_Reset_Order},
		{text = "mouse 1 2 8", diagnostic = .Invalid_Number},
		{text = "mouse 2147483648 0 0", diagnostic = .Invalid_Number},
		{text = "mouse 0 -2147483649 0", diagnostic = .Invalid_Number},
		{text = "wheel 2147483648 0", diagnostic = .Invalid_Number},
		{text = "wheel -2147483649 0", diagnostic = .Invalid_Number},
		{text = "wait-frame nope", diagnostic = .Invalid_Number},
		{text = "wait-stable -1", diagnostic = .Invalid_Number},
		{text = "wait-change nope", diagnostic = .Invalid_Number},
		{text = "wait-memory 0x100 3 1", diagnostic = .Invalid_Number},
		{text = "wait-memory 0x100 1 nope", diagnostic = .Invalid_Number},
		{text = "wait-memory 0x100 1 0x100", diagnostic = .Invalid_Number},
		{text = "wait-memory 0x100 1 1 0x100", diagnostic = .Invalid_Number},
		{text = "wait-setup-page translated", diagnostic = .Invalid_Syntax},
		{text = "key-while-setup-page translated enter", diagnostic = .Invalid_Syntax},
		{text = "key-while-setup-page user unknown", diagnostic = .Invalid_Key},
		{text = "key-while-setup-page user enter 0", diagnostic = .Invalid_Number},
		{text = "type key!", diagnostic = .Invalid_Key},
		{text = "click", diagnostic = .Invalid_Syntax},
	}
	for fixture in fixtures {
		script, diagnostic := input_script_parse(fixture.text)
		input_script_destroy(&script)
		testing.expect_value(t, diagnostic, fixture.diagnostic)
	}
}

@(test)
input_script_test_waits_for_setup_page_state_at_cached_gpa :: proc(t: ^testing.T) {
	script, diagnostic := input_script_parse(
		"wait-setup-page user\nkey enter\nwait-setup-page eula\nkey enter\n",
	)
	defer input_script_destroy(&script)
	testing.expect_value(t, diagnostic, Input_Script_Diagnostic.None)
	memory := make([]u8, 64)
	defer delete(memory)
	copy(memory[20:], []u8{0x10, 0x01, 0x00, 0x00, 0xff, 0xff, 0x60, 0x03})
	testing.expect(t, input_script_memory_matches(&script, 0, 0, memory))
	testing.expect(t, script.setup_page_gpa_valid)
	testing.expect_value(t, script.setup_page_gpa, u64(20))
	actions: [1]Input_Action
	testing.expect_value(t, input_script_drain(&script, 0, 0, 0, false, true, actions[:]), 1)
	copy(memory[20:], []u8{0x10, 0x01, 0x01, 0x00, 0xff, 0xff, 0x60, 0x03})
	testing.expect(t, input_script_memory_matches(&script, 0, 0, memory))
	testing.expect_value(t, input_script_drain(&script, 0, 0, 0, false, true, actions[:]), 1)
}

@(test)
input_script_test_retries_key_only_while_setup_page_is_current :: proc(t: ^testing.T) {
	script, diagnostic := input_script_parse(
		"wait-setup-page user\nkey-while-setup-page user enter 1000\nwait-setup-page eula\n",
	)
	defer input_script_destroy(&script)
	testing.expect_value(t, diagnostic, Input_Script_Diagnostic.None)
	memory := make([]u8, 64)
	defer delete(memory)
	copy(memory[20:], []u8{0x10, 0x01, 0x00, 0x00, 0xff, 0xff, 0x60, 0x03})
	actions: [1]Input_Action
	testing.expect(t, input_script_memory_matches(&script, 0, 0, memory))
	testing.expect_value(t, input_script_drain(&script, 0, 0, 0, false, true, actions[:]), 0)
	testing.expect(t, input_script_memory_matches(&script, 0, 0, memory))
	testing.expect_value(t, input_script_drain(&script, 0, 0, 0, false, true, actions[:]), 1)
	testing.expect_value(t, actions[0].kind, Input_Action_Kind.Key_While_Setup_Page)
	testing.expect_value(t, script.cursor, 1)
	testing.expect_value(t, input_script_drain(&script, 0, 999, 0, false, false, actions[:]), 0)
	copy(memory[20:], []u8{0x10, 0x01, 0x01, 0x00, 0xff, 0xff, 0x60, 0x03})
	testing.expect(t, !input_script_memory_matches(&script, 0, 1_000, memory))
	testing.expect_value(t, input_script_drain(&script, 0, 1_000, 0, false, false, actions[:]), 0)
	testing.expect_value(t, script.cursor, 2)
	testing.expect(t, input_script_memory_matches(&script, 0, 1_000, memory))
	testing.expect_value(t, input_script_drain(&script, 0, 1_000, 0, false, true, actions[:]), 0)
	testing.expect_value(t, script.cursor, 3)
}

@(test)
input_script_test_setup_page_cache_recovers_when_state_moves :: proc(t: ^testing.T) {
	script, diagnostic := input_script_parse(
		"wait-setup-page user\nkey enter\nwait-setup-page eula\n",
	)
	defer input_script_destroy(&script)
	testing.expect_value(t, diagnostic, Input_Script_Diagnostic.None)
	memory := make([]u8, 96)
	defer delete(memory)
	copy(memory[20:], []u8{0x10, 0x01, 0x00, 0x00, 0xff, 0xff, 0x60, 0x03})
	testing.expect(t, input_script_memory_matches(&script, 0, 0, memory))
	actions: [1]Input_Action
	testing.expect_value(t, input_script_drain(&script, 0, 0, 0, false, true, actions[:]), 1)

	for &byte in memory[20:28] {byte = 0}
	copy(memory[64:], []u8{0x10, 0x01, 0x01, 0x00, 0xff, 0xff, 0x60, 0x03})
	testing.expect(t, input_script_memory_matches(&script, 0, 0, memory))
	testing.expect_value(t, script.setup_page_gpa, u64(64))
}

@(test)
input_script_test_setup_page_discovery_advances_in_bounded_chunks :: proc(t: ^testing.T) {
	script, diagnostic := input_script_parse("wait-setup-page user\n")
	defer input_script_destroy(&script)
	testing.expect_value(t, diagnostic, Input_Script_Diagnostic.None)
	memory := make([]u8, 8 * 1024 * 1024 + 64)
	defer delete(memory)
	copy(memory[len(memory) - 16:], []u8{0x10, 0x01, 0x00, 0x00, 0xff, 0xff, 0x60, 0x03})
	testing.expect(t, !input_script_memory_matches(&script, 0, 0, memory))
	testing.expect(t, script.setup_page_scan_cursor > 0)
	testing.expect(t, input_script_memory_matches(&script, 0, 0, memory))
}

@(test)
input_script_test_waits_for_masked_guest_memory :: proc(t: ^testing.T) {
	script, diagnostic := input_script_parse(
		"wait 10\nwait-memory 0x2 2 0x1230 0xfff0\nkey enter\n",
	)
	defer input_script_destroy(&script)
	testing.expect_value(t, diagnostic, Input_Script_Diagnostic.None)
	memory := []u8{0, 0, 0x3f, 0x12}
	testing.expect(t, !input_script_memory_matches(&script, 0, 9, memory))
	testing.expect(t, input_script_memory_matches(&script, 0, 10, memory))
	actions: [1]Input_Action
	testing.expect_value(t, input_script_drain(&script, 0, 10, 0, false, false, actions[:]), 0)
	testing.expect_value(t, input_script_drain(&script, 0, 10, 0, false, true, actions[:]), 1)
	testing.expect_value(t, actions[0].kind, Input_Action_Kind.Key)
}

@(test)
input_script_test_types_ascii_with_paced_key_actions :: proc(t: ^testing.T) {
	script, diagnostic := input_script_parse("wait 100\ntype A9-z\nkey enter\n")
	defer input_script_destroy(&script)
	testing.expect_value(t, diagnostic, Input_Script_Diagnostic.None)
	testing.expect_value(t, len(script.actions), 5)
	if len(script.actions) != 5 {return}
	testing.expect_value(t, script.actions[0].at_ms, i64(100))
	testing.expect_value(
		t,
		script.actions[0].key,
		[INPUT_SCRIPT_KEY_BYTES]u8{0x2a, 0x1e, 0x9e, 0xaa, 0, 0, 0, 0},
	)
	testing.expect_value(t, script.actions[1].at_ms, i64(150))
	testing.expect_value(t, script.actions[1].key_n, u8(2))
	testing.expect_value(t, script.actions[2].at_ms, i64(200))
	testing.expect_value(t, script.actions[3].at_ms, i64(250))
	testing.expect_value(t, script.actions[4].at_ms, i64(300))
}

@(test)
input_script_test_distinguishes_us_and_spanish_underscore_scans :: proc(t: ^testing.T) {
	script, diagnostic := input_script_parse("type _\nkey underscore-es\n")
	defer input_script_destroy(&script)
	testing.expect_value(t, diagnostic, Input_Script_Diagnostic.None)
	testing.expect_value(t, len(script.actions), 2)
	if len(script.actions) != 2 {return}
	testing.expect_value(
		t,
		script.actions[0].key,
		[INPUT_SCRIPT_KEY_BYTES]u8{0x2a, 0x0c, 0x8c, 0xaa, 0, 0, 0, 0},
	)
	testing.expect_value(
		t,
		script.actions[1].key,
		[INPUT_SCRIPT_KEY_BYTES]u8{0x2a, 0x35, 0xb5, 0xaa, 0, 0, 0, 0},
	)
}

@(test)
input_script_test_parses_ctrl_escape :: proc(t: ^testing.T) {
	script, diagnostic := input_script_parse("key ctrl-escape\n")
	defer input_script_destroy(&script)
	testing.expect_value(t, diagnostic, Input_Script_Diagnostic.None)
	testing.expect_value(t, len(script.actions), 1)
	if len(script.actions) > 0 {
		testing.expect_value(
			t,
			script.actions[0].key,
			[INPUT_SCRIPT_KEY_BYTES]u8{0x1d, 0x01, 0x81, 0x9d, 0, 0, 0, 0},
		)
	}
}

@(test)
input_script_test_parses_command_line_punctuation :: proc(t: ^testing.T) {
	script, diagnostic := input_script_parse(
		"key period\nkey comma\nkey space\nkey grave\nkey slash\nkey f12\nkey underscore-es\n",
	)
	defer input_script_destroy(&script)
	testing.expect_value(t, diagnostic, Input_Script_Diagnostic.None)
	testing.expect_value(t, len(script.actions), 7)
	if len(script.actions) != 7 {return}
	testing.expect_value(t, script.actions[0].key[0], u8(0x34))
	testing.expect_value(t, script.actions[1].key[0], u8(0x33))
	testing.expect_value(t, script.actions[2].key[0], u8(0x39))
	testing.expect_value(t, script.actions[3].key[0], u8(0x29))
	testing.expect_value(t, script.actions[4].key[0], u8(0x35))
	testing.expect_value(t, script.actions[5].key[0], u8(0x58))
	testing.expect_value(
		t,
		script.actions[6].key,
		[INPUT_SCRIPT_KEY_BYTES]u8{0x2a, 0x35, 0xb5, 0xaa, 0, 0, 0, 0},
	)
}

@(test)
input_script_test_parses_hardware_reset :: proc(t: ^testing.T) {
	script, diagnostic := input_script_parse("wait-memory 0x449 1 3\nreset\n")
	defer input_script_destroy(&script)
	testing.expect_value(t, diagnostic, Input_Script_Diagnostic.None)
	testing.expect_value(t, len(script.actions), 2)
	if len(script.actions) == 2 {
		testing.expect_value(t, script.actions[1].kind, Input_Action_Kind.Reset)
	}
}

@(test)
input_script_test_parses_headless_state_dump :: proc(t: ^testing.T) {
	script, diagnostic := input_script_parse("wait 10\ndump-state\n")
	defer input_script_destroy(&script)
	testing.expect_value(t, diagnostic, Input_Script_Diagnostic.None)
	testing.expect_value(t, len(script.actions), 1)
	if len(script.actions) == 1 {
		testing.expect_value(t, script.actions[0].kind, Input_Action_Kind.Dump_State)
		testing.expect_value(t, script.actions[0].at_ms, i64(10))
	}
}

@(test)
input_script_test_parses_ctrl_alt_delete_chord :: proc(t: ^testing.T) {
	script, diagnostic := input_script_parse("key ctrl-alt-delete\n")
	defer input_script_destroy(&script)
	testing.expect_value(t, diagnostic, Input_Script_Diagnostic.None)
	testing.expect_value(t, len(script.actions), 1)
	if len(script.actions) != 1 {return}
	testing.expect_value(t, script.actions[0].key_n, u8(8))
	testing.expect_value(
		t,
		script.actions[0].key,
		[INPUT_SCRIPT_KEY_BYTES]u8{0x1d, 0x38, 0xe0, 0x53, 0xe0, 0xd3, 0xb8, 0x9d},
	)
}

@(test)
input_script_test_barrier_delay_preserves_following_key_spacing :: proc(t: ^testing.T) {
	script, diagnostic := input_script_parse(
		"wait 100\nwait-stable 50\nkey tab\nwait 200\nkey enter\n",
	)
	defer input_script_destroy(&script)
	testing.expect_value(t, diagnostic, Input_Script_Diagnostic.None)
	actions: [2]Input_Action

	n := input_script_drain(&script, 0, 500, 0, true, false, actions[:])
	testing.expect_value(t, n, 1)
	testing.expect_value(t, actions[0].key[0], u8(0x0F))
	testing.expect_value(t, input_script_drain(&script, 0, 699, 0, false, false, actions[:]), 0)
	n = input_script_drain(&script, 0, 700, 0, false, false, actions[:])
	testing.expect_value(t, n, 1)
	testing.expect_value(t, actions[0].key[0], u8(0x1C))
}
