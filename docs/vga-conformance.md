<!-- SPDX-License-Identifier: GPL-3.0-only -->

# VGA conformance matrix

This matrix defines RETVRN99's pre-3D legacy-video contract. A row is
`Conformant` only when the production Interface implements the documented
behavior and an executable test crosses that Interface. Direct assignment to
internal register arrays is useful implementation coverage, but is not enough
to close a port, BIOS, or MMIO contract.

The milestone is complete when every in-target row is `Conformant`. `Partial`
and `Missing` rows are work items. `Out of target` rows are deliberate limits,
not implicit capability claims.

## Normative references

- IBM, *Video Subsystem Technical Reference*, VGA Function, preliminary draft,
  May 1992. Register pages 2-41 through 2-111 and programming considerations
  pages 2-97 through 2-103.
- IBM, *Personal System/2 and Personal Computer BIOS Interface Technical
  Reference*, second edition, May 1988. INT 10h video services.
- VESA, *VBE Core Functions Standard 2.0*, revision 1.1.
- Bochs VGABIOS commit `6563908`, including `vbe_display_api.txt` and the mode
  table built into RETVRN99.

## General and sequencer registers

| Contract | Reference | Status | Implementation | Executable proof |
| --- | --- | --- | --- | --- |
| Miscellaneous Output 3C2h/3CCh: I/O select, RAM enable, clock select, sync polarity, reserved bits | IBM 2-42 to 2-43 | Conformant | `src/vga/ports.odin`, `src/vga/timing.odin` | `test_vga_io_decode_follows_misc_output` and `test_machine_vgabios_int10_mode_matrix` cover I/O select and per-mode clock and sync polarity across five firmware values. `vga_test_misc_reserved_bits_and_feature_control_round_trip` requires the register to behave as the latch it is: the reserved bit and the odd/even page select read back through 3CCh exactly as written and disturb no timing, while the clock select beside them changes the line period. `test_machine_vgabios_video_enable_and_eight_bit_dac` proves the firmware drives RAM enable from INT 10h AH=12h BL=32h |
| Input Status 0 3C2h: switch sense and pending CRT interrupt | IBM 2-44 | Conformant | `src/vga/legacy_beam.odin`, `src/vga/timing.odin` | `vga_test_status0_switch_sense_and_retrace`, `vga_test_vertical_interrupt_latch_and_callback` |
| Input Status 1 3BAh/3DAh: display enable, vertical retrace, Attribute flip-flop reset | IBM 2-45 | Conformant | `src/vga/legacy_beam.odin`, `src/vga/timing.odin`, `src/vga/ports.odin` | The blank and retrace windows are asserted at chosen beam positions by the CRT Controller 03h, 05h, 10h, 11h and 16h rows. `vga_test_status_port_address_select_and_flip_flop_reset` moves the port between 3DAh and 3BAh with Miscellaneous Output bit 0, requires the undecoded address to read FFh, and requires a read to reset the Attribute flip-flop so the next 3C0h write is taken as an index |
| Feature Control 3BAh/3DAh and 3CAh reserved behavior | IBM 2-46 | Conformant | `src/vga/ports.odin` retains the two undocumented bits, drops the rest, and decodes the write at whichever address Miscellaneous Output bit 0 selects | `vga_test_misc_reserved_bits_and_feature_control_round_trip` writes FFh and requires 3CAh to read 03h, then requires the inactive address to be ignored in both directions |
| Video Subsystem Enable 3C3h decode behavior | IBM 2-46 and INT 10h AH=12h BL=32h | Conformant | `src/vga/legacy_control.odin` | `vga_test_misc_reserved_bits_and_feature_control_round_trip` requires 3C3h to gate output in both directions without moving the raster. The pinned firmware does not use 3C3h for AH=12h BL=32h at all: it moves Miscellaneous Output bit 1, which `test_machine_vgabios_video_enable_and_eight_bit_dac` requires in both directions against a 1212h return, and `vga_test_aperture_windows_bound_the_legacy_decode` requires that bit to close the aperture |
| Sequencer 00h synchronous/asynchronous reset | IBM 2-48 | Conformant | `src/vga/ports.odin`, `src/vga/scanout.odin` | `vga_test_sequencer_reset_public_port_matrix_preserves_state`, `vga_test_sequencer_reset_and_screen_off_are_independent`, `vga_test_sequencer_reset_drives_damage_generation_and_descriptor_restore`, `test_machine_vga_sequencer_reset_crosses_io_and_restores_scanout` |
| Sequencer 01h clocking mode: 8/9 dots, shift load, dot-clock divide, shift-4, screen off | IBM 2-49 to 2-50 | Conformant | `src/vga/timing.odin` takes the character width and the divider; `src/vga/scanout.odin` takes screen off | `vga_test_sequencer_clocking_mode_drives_width_clock_and_screen_off` drives all three through 3C4h/3C5h and requires the dot count, the line period, and both the rendered output and Input Status 1 to follow. `test_machine_vgabios_int10_mode_matrix` reads the register back after every firmware mode set and pins the character width and the divider per mode. The two serializer load-rate controls are an explicit exclusion below, and the same test requires the firmware to leave them at their reset value in all fifteen modes |
| Sequencer 02h map mask | IBM 2-51 | Conformant | `src/vga/memory.odin` | `src/vga/memory_tests.odin` map-mask cases |
| Sequencer 03h character map select | IBM 2-52 to 2-53 | Conformant | `src/vga/scanout.odin` | `test_vga_text_uses_selected_character_maps` |
| Sequencer 04h extended memory, odd/even disable, chain-4 | IBM 2-54 | Conformant | `src/vga/memory.odin` routes both chain-4 and odd/even | `vga_test_sequencer_memory_mode_routes_writes_through_the_ports` drives the register through 3C5h and reads the planes back for chain-4, for the map-mask path with chaining off, and for odd/even paired with the Graphics 06h chain bit. Extended-memory gating is an explicit exclusion below; `test_machine_vgabios_int10_mode_matrix` requires the firmware to enable it in all fifteen modes |

## CRT Controller registers

The cursor is driven from a latch rather than a range compare: it sets at
Cursor Start and clears at Cursor End or at the last scan line of the character
cell. An end below the start therefore runs to the bottom of the cell. An
earlier note here claimed such a range should hide the cursor; that was an
unverified assumption and the implementation wrapped into the top of the cell
instead. Neither matched the reference, and both are corrected.

| Register contract | Reference | Status | Implementation | Executable proof |
| --- | --- | --- | --- | --- |
| 00h Horizontal Total | IBM 2-56 | Conformant | `src/vga/timing.odin` | Timing total tests |
| 01h Horizontal Display Enable End | IBM 2-57 | Conformant | `src/vga/timing.odin`, `src/vga/scanout.odin` | Mode geometry tests |
| 02h Start Horizontal Blanking | IBM 2-57 | Conformant | `src/vga/timing.odin`, `src/vga/legacy_beam.odin` | Status 1 blank-window tests plus `test_machine_vgabios_int10_mode_matrix`, which reads the register back per mode and requires blanking to begin after the display ends |
| 03h End Horizontal Blanking and display-enable skew | IBM 2-58 | Conformant | `src/vga/timing.odin`, `src/vga/legacy_beam.odin` | `vga_test_display_enable_follows_the_horizontal_blank_window` drives 03h through 3D4h/3D5h, requires the write to be dropped while 11h bit 7 protects it, then places the beam either side of both the stock and the moved blank end and reads Input Status 1 bit 0 at each dot. `test_machine_vgabios_int10_mode_matrix` requires bit 7 set in every mode. The display-enable skew field is an explicit exclusion below |
| 04h Start Horizontal Retrace | IBM 2-59 | Conformant | `src/vga/timing.odin`, `src/vga/legacy_beam.odin` | `vga_test_horizontal_retrace_window_follows_crtc_04h_and_05h` drives the register through the ports and requires the derived retrace window to start where it names, including the case where the end wraps past the horizontal total. `test_machine_vgabios_int10_mode_matrix` proves the register is programmed inside the blanking period in every mode. The signal the window describes is an explicit exclusion below |
| 05h End Horizontal Retrace, delay, and blank bit 5 | IBM 2-60 | Conformant | `src/vga/timing.odin`, `src/vga/legacy_beam.odin` | `vga_test_end_horizontal_blanking_bit_5_lives_in_crtc_05h` drops bit 7, which takes the reconstructed blank end below its start, and requires Input Status 1 to report blanking through the end of the line and the left border extent to fall to zero. `vga_test_horizontal_retrace_window_follows_crtc_04h_and_05h` requires the delay field to move both retrace edges by whole characters and the end field to wrap. The delay and end fields describe the horizontal retrace signal excluded below; the blank-end bit they sit beside is proven through Input Status 1 |
| 06h Vertical Total | IBM 2-61 | Conformant | `src/vga/timing.odin` | Timing total tests |
| 07h Overflow fields and protected line-compare exception | IBM 2-62 | Conformant | Geometry, blanking, and protection fields exist | `test_machine_vgabios_int10_mode_matrix` reads Overflow back per mode and uses bits 1, 3, and 6 to reconstruct the ten-bit vertical display end and blanking start against known 350, 400, and 480 line geometry. `vga_test_line_compare_bits_reach_the_split_through_the_ports` writes the register through 3D5h while 11h bit 7 protects it and requires bit 4 alone to change, in both directions, while a neighbouring protected register does not move |
| 08h Preset Row Scan and byte panning | IBM 2-63 | Conformant | `src/vga/legacy_addressing.odin` | `src/vga/legacy_addressing_tests.odin` |
| 09h Maximum Scan Line, double scan, line compare, vertical blank bit 9 | IBM 2-64 | Conformant | Blanking bit participates; the scan factor combines the two fields with a maximum rather than a product, which is correct because Maximum Scan Line indexes the interleaved banks in CGA-compatibility graphics modes | `test_machine_vgabios_int10_mode_matrix` proves the register is programmed correctly per mode, and `vga_test_graphics_scan_factor_matches_firmware_combinations` pins the derived factor for every combination the firmware programs. An earlier note called the missing multiplication a defect; multiplying would halve modes 04h, 05h, and 06h to 100 lines. `vga_test_scan_factor_follows_crtc_09h_through_the_ports` drives the register through 3D5h and requires the expanded height to follow each field and their maximum, and `vga_test_line_compare_bits_reach_the_split_through_the_ports` carries bit 9 into a split that repeats the first row of memory |
| 0Ah Cursor Start and cursor off | IBM 2-65 | Conformant | `src/vga/scanout.odin` | `vga_test_text_cursor_start_and_end_matrix`, `vga_test_text_cursor_off_bit_overrides_range` |
| 0Bh Cursor End and cursor skew | IBM 2-66 | Conformant | `src/vga/scanout.odin` | `vga_test_text_cursor_start_and_end_matrix`, `vga_test_text_cursor_skew_shifts_the_addressed_cell` |
| 0Ch/0Dh Start Address and vertical-retrace latch | IBM 2-67 and 2-99 | Conformant | `src/vga/ports.odin` holds the pair pending and `src/vga/scanout.odin` latches it when the retrace boundary is crossed, including under deferred scanout | `raster_journal_test_display_start_write_waits_for_vertical_retrace` writes the pair through the public CRT Controller ports partway down a frame and requires the expanded image not to move, then requires it to move once the retrace boundary is passed. `test_machine_scheduler_latches_vga_start_address_at_retrace` writes the pair through the ports with no guest running at all, requires a quarter frame of scheduler time to leave it pending, and requires the latch once the advance crosses the retrace line |
| 0Eh/0Fh Cursor Location | IBM 2-68 | Conformant | `src/vga/scanout.odin` | Cursor location tests |
| 10h Vertical Retrace Start | IBM 2-69 | Conformant | `src/vga/timing.odin`, `src/vga/legacy_beam.odin`, `src/machine/machine.odin` | `vga_test_vertical_retrace_signal_follows_crtc_10h_and_11h` places the beam either side of the retrace start and reads Input Status 1 bit 3, before and after moving the register, with bit 8 supplied by Overflow. `test_machine_halted_guest_wakes_on_vga_vertical_retrace` arms the interrupt from real-mode guest code, halts with no other deadline in the machine, and requires the vCPU to resume through vector 71h. `vga_test_vertical_interrupt_latch_and_callback` and the IRQ2 source tests cover the latch |
| 11h Vertical Retrace End, protection, IRQ enable and clear | IBM 2-69 to 2-70 | Conformant | `src/vga/ports.odin`, `src/vga/legacy_beam.odin`, `src/machine/pic.odin` | `vga_test_vertical_retrace_signal_follows_crtc_10h_and_11h` requires the low nibble to end the signal at the line it names and to wrap past sixteen lines when it falls below the start's own nibble; `vga_test_display_enable_follows_the_horizontal_blank_window` requires bit 7 to drop a write to 00h through 07h. Latch, default-clear, AT IRQ2-to-IRQ9 redirect, and level-triggered clear proofs cover the interrupt bits |
| 12h Vertical Display Enable End | IBM 2-71 | Conformant | `src/vga/timing.odin` | Mode geometry tests |
| 13h Offset | IBM 2-71 | Conformant | `src/vga/legacy_addressing.odin` | Pitch/address tests |
| 14h Underline Location, count-by-4, doubleword mode | IBM 2-72 | Conformant | `src/vga/scanout.odin` draws the text underline on the scan line bits 0-4 name, and `src/vga/legacy_addressing.odin` consumes count-by-4 and doubleword | `vga_test_underline_lands_on_the_row_crtc_14h_names` drives the register through 3D4h/3D5h, moves the line, and requires bits 5 and 6 not to move it; `vga_test_underline_is_absent_outside_its_attribute_and_mode` bounds it to the one attribute and to monochrome emulation. `vga_test_display_address_modes_follow_crtc_14h_and_17h` closes the addressing half at the ports: it drives count-by-four and doubleword through 3D5h against a seeded plane and requires the exact pixels each address transform selects |
| 15h Start Vertical Blanking | IBM 2-73 | Conformant | `src/vga/timing.odin`, `src/vga/legacy_beam.odin` | Status and IRQ timing use the programmed start, and `test_machine_vgabios_int10_mode_matrix` reconstructs the ten-bit value per mode from Overflow and Maximum Scan Line and requires it to follow the display end |
| 16h End Vertical Blanking | IBM 2-73 | Conformant | `src/vga/timing.odin`, `src/vga/legacy_beam.odin` | `vga_test_display_enable_follows_the_vertical_blank_window` drives the register through 3D4h/3D5h and reads Input Status 1 bit 0 either side of the end line for all three cases the eight-bit field produces against a nine-bit start: no wrap, one wrap, and a wrap past the vertical total that blanks the rest of the frame. `test_machine_vgabios_int10_mode_matrix` captures the register per mode |
| 17h reset, word/byte mode, address wrap, count-by-2, row-scan select | IBM 2-74 to 2-76 | Conformant | `src/vga/legacy_addressing.odin` maps the address, and the horizontal-row clock in bit 2 now halves the row scan factor beside `src/vga/legacy_beam.odin`, which gates the retrace signal on the bit 7 reset | `vga_test_display_address_modes_follow_crtc_14h_and_17h` covers word, byte and count-by-two, `vga_test_address_wrap_bit_selects_which_address_bit_rotates` covers bit 5 against a latched start address large enough to reach both candidate bits, `vga_test_row_scan_select_substitutes_the_interleave_bits` covers bits 0 and 1, `vga_test_horizontal_retrace_select_halves_the_row_clock` covers bit 2, and `vga_test_public_crtc_reset_disables_status_retrace_signal` covers bit 7. No stock BIOS mode programs bit 2 |
| 18h Line Compare and split screen | IBM 2-77 and 2-102 | Conformant | `src/vga/legacy_addressing.odin` | Split and panning tests |

## Graphics Controller, Attribute Controller, and DAC

| Contract | Reference | Status | Implementation | Executable proof |
| --- | --- | --- | --- | --- |
| Graphics 00h Set/Reset | IBM 2-79 | Conformant | `src/vga/memory.odin` | Write-mode tests |
| Graphics 01h Enable Set/Reset | IBM 2-80 | Conformant | `src/vga/memory.odin` | Write-mode tests |
| Graphics 02h Color Compare | IBM 2-81 | Conformant | `src/vga/memory.odin` | Read-mode-1 tests |
| Graphics 03h Data Rotate and logical operation | IBM 2-82 | Conformant | `src/vga/memory.odin` | Rotate/ROP tests |
| Graphics 04h Read Map Select | IBM 2-83 | Conformant | `src/vga/memory.odin` | Read-map tests |
| Graphics 05h write modes 0-3, read modes, odd/even, shift modes | IBM 2-84 to 2-85 | Conformant | `src/vga/memory.odin`, `src/vga/scanout.odin` | Memory and scanout tests |
| Graphics 06h graphics/text select, chain odd/even, aperture map | IBM 2-86 | Conformant | `src/vga/memory.odin` | Aperture-map tests |
| Graphics 07h Color Don't Care | IBM 2-87 | Conformant | `src/vga/memory.odin` | Read-mode-1 tests |
| Graphics 08h Bit Mask | IBM 2-88 | Conformant | `src/vga/memory.odin` | Write-mode tests |
| Attribute address/data flip-flop and Palette Address Source | IBM 2-89 to 2-90 | Conformant | `src/vga/ports.odin` carries the one flip-flop that 3C0h alternates and a read of Input Status 1 clears, and records bit 5 of an index write as the Palette Address Source | The bit selects whether the CPU or the video hardware drives the internal palette address, so holding it clear hands the address to the CPU and blanks the display for as long as it is held; it does not block access to the registers. `vga_test_attribute_flip_flop_and_dac` walks the flip-flop through 3C0h and 3DAh and requires a write to 00h-0Fh to land, and a read of 3C1h to return it, with the bit set as well as clear. The reference BIOS settles the question: `rest_actl_loop` in `vendor_local/vgabios/vgabios/vgabios.c`, the INT 10h AH=1Ch state restore, writes indices 00h-13h with `or al, #0x20`, so a restore that could not reach the palette with the bit set would silently drop all sixteen entries. `test_machine_vgabios_int10_state_save_restore_round_trips_the_palette` proves that path end to end on the shipped firmware. The blanking half is on the row below |
| Attribute 00h-0Fh internal palette | IBM 2-90 to 2-91 | Conformant | `src/vga/ports.odin` stores and returns the sixteen entries whatever the Palette Address Source says, because that bit blanks the display rather than gating the port, `src/vga/scanout.odin` resolves the index through colour select, and `src/vga/raster_journal.odin` carries mid-frame changes with that bit | `raster_journal_test_attribute_palette_split_replays_below_the_split` and `raster_journal_test_palette_source_blanks_the_rows_it_is_held_off_for` prove the mid-frame replay and the blank band the source bit forces while the CPU holds the address; `vga_test_color_select_supplies_the_high_dac_index_bits` pins the resolved DAC index at exactly C1h by requiring only that entry to restore the colour; `vga_test_internal_palette_is_bypassed_in_256_color_mode` proves the palette is not consulted when Attribute 10h bit 6 is set |
| Attribute 10h mode control: graphics, mono, line graphics, blink, PEL width, pan compatibility | IBM 2-92 to 2-93 | Conformant | `src/vga/scanout.odin` consumes graphics select, monochrome emulation, line graphics, blink, and PEL width, and `src/vga/legacy_addressing.odin` the pan compatibility reset below the split | `vga_test_palette_bits_45_are_replaced_when_mode_control_bit_7_is_set` proves bit 7 discards palette bits 4 and 5 in favour of colour select, and `vga_test_internal_palette_is_bypassed_in_256_color_mode` proves the bit 6 PEL width path. `vga_test_monochrome_emulation_replaces_the_attribute_colors` sets and clears bit 1 through the Attribute Controller port and requires the same attribute byte to resolve to a different palette index either side, `vga_test_monochrome_attribute_forms` pins all thirteen distinguishable attribute forms, and `vga_test_monochrome_blink_carries_the_underline` proves bit 3 blink still resolves foreground into background under monochrome reading |
| Attribute 11h overscan color | IBM 2-94 | Conformant | `src/vga/scanout.odin` resolves it through the palette and DAC onto the frame and the legacy presentation header; `src/host/render.odin` paints the surround with it | `vga_test_overscan_color_follows_attribute_11h_through_public_ports`, `vga_test_overscan_is_black_while_output_is_disabled`, `vga_test_overscan_uses_cga_color_select_in_cga_modes`, `vga_test_legacy_frame_header_publishes_the_overscan_color` |
| Attribute 12h color plane enable and status mux | IBM 2-94 | Conformant | `src/vga/scanout.odin` masks planes out of the index before the palette is consulted, and `vga_status_mux_bits` now resolves text cells beside the planar and 256-colour paths | `vga_test_color_plane_enable_masks_the_index_before_the_palette` drives the register through the public port and requires a pixel lit only in a disabled plane to fall to colour zero while its neighbour holds. `vga_test_status_multiplexer_reports_text_pixels` walks all four multiplexer selections through 3C0h and reads the pair back from Input Status 1 for a lit and an unlit text pixel, and requires blanking to report nothing. The select bits used to be masked out of the register on write, so no software could reach them |
| Attribute 13h horizontal PEL panning | IBM 2-95 | Conformant | `src/vga/legacy_addressing.odin` counts the register in dot clocks, so the text and planar paths take the whole value and the 256-colour path takes half of it | `vga_test_indexed_pel_pan_shifts_by_half_the_programmed_value` proves 2h, 4h, and 6h move one, two, and three pixels in mode 13h and that an odd value lands with the even value below it; `vga_test_planar_pel_pan_shifts_by_the_whole_programmed_value` proves the 16-colour path still shifts by the full value; `vga_test_text_pel_pan_shifts_by_dots_and_ignores_eight_on_nine_dot_cells` covers the text path including the nine-dot exception where a value of 8 shifts nothing. The mode X CRC pin moved once and records why |
| Attribute 14h color select | IBM 2-96 | Conformant | `src/vga/scanout.odin` | Palette-selection tests |
| DAC mask, state, read/write index, 6-bit components and auto-increment | IBM 2-104 to 2-107 | Conformant | `src/vga/ports.odin` | DAC tests in `src/vga/vga_tests.odin` and VBE tests |
| VBE 8-bit DAC extension | Bochs ID3 and VBE functions 08h/09h | Conformant | `src/vga/ports.odin` truncates a palette write to six bits unless the DISPI 8-bit flag is set | `test_machine_vgabios_video_enable_and_eight_bit_dac` asks the firmware for eight bits through 4F08h, reads the width back, and requires FFh, 80h and 3Fh to survive a round trip through 3C8h/3C9h; asking for six bits back truncates the same three writes to 3Fh, 00h and 3Fh |

## Memory and scanout behavior

| Contract | Reference | Status | Implementation | Executable proof |
| --- | --- | --- | --- | --- |
| A0000h/B0000h/B8000h aperture selection and decode disable | IBM 2-24 to 2-38 and 2-86 | Conformant | `src/vga/memory.odin` | Aperture-map and PCI decode tests |
| Plane latches and read modes 0/1 | IBM 2-35 to 2-40 | Conformant | `src/vga/memory.odin` | Latch/read-mode tests |
| Write modes 0-3 | IBM 2-35 to 2-40 and 2-85 | Conformant | `src/vga/memory.odin` | Write-mode matrix |
| Chain-4 and odd/even addressing combinations | IBM 2-24 to 2-34 and 2-54 | Conformant | `src/vga/memory.odin` routes both directions | `vga_test_chain4_and_odd_even_route_reads_and_writes` drives the Sequencer and Graphics chain bits through their ports and reads the planes back for chain-4, for odd/even paired with the read map, and for the unchained linear case. `vga_test_aperture_windows_bound_the_legacy_decode` walks all four Graphics 06h windows, requires the first and last byte of each to decode and the bytes either side not to, and requires Miscellaneous Output bit 1 to gate the lot |
| Multi-byte aperture transactions preserve byte-cycle VGA semantics | IBM memory data flow | Conformant | `src/vga/memory.odin`, `src/machine/machine.odin` | `vga_test_aperture_slice_access_is_one_visible_transaction`, `test_machine_vga_legacy_aperture_batches_mmio_transaction` |
| CGA 16 KiB page/address wrapping | IBM CGA compatibility modes | Conformant | `src/vga/scanout.odin` bounds the persona's display counter to one 16 KiB page in both the graphics and the text fetch | `vga_test_cga_graphics_wraps_inside_its_page` and `vga_test_cga_text_wraps_inside_its_page` enter the persona through 3D8h, write both sides of the page boundary through the aperture, and move the start address through the 6845 registers until the counter wraps. The text case also pins the glyph to the top of its cell: register 8 of a 6845 selects interlace, and reading it as a VGA preset row scan used to push every CGA text row two scan lines down |
| Text modes 40/80 columns and 25/43/50 rows | IBM BIOS modes and font services | Conformant | `src/vga/scanout.odin`, `src/host/render.odin` | `vga_test_text_snapshot_variable_geometry`, `host_test_render_snapshot_uses_snapshot_geometry` |
| Text underline, monochrome attributes, blink, line graphics, and cursor shape | IBM 2-15 to 2-17 and CRTC/Attribute sections | Conformant | `src/vga/scanout.odin` carries monochrome attributes, the underline they drive, blink, line graphics, and cursor shape | Monochrome attributes and the underline are proven by the tests on the Attribute 10h and CRT Controller 14h rows, blink by `vga_test_monochrome_blink_carries_the_underline`, and cursor shape by the 0Ah and 0Bh rows. `vga_test_line_graphics_duplicates_the_eighth_dot` covers line graphics: it programs the enable through 3C0h and requires the ninth dot to follow the eighth for a character inside C0h-DFh, to fall back to the background once the enable is cleared, and never to duplicate for a character outside the range |
| Planar 16-color scanout | IBM modes 0Dh-12h | Conformant | `src/vga/scanout.odin` | Mode and planar scanout tests |
| Chain-4 256-color mode 13h scanout | IBM mode 13h | Conformant | `src/vga/scanout.odin` | Full-size mode 13h test |
| Unchained 256-color Mode X scanout | IBM register model plus documented compatible programming | Conformant | `src/vga/scanout.odin` and `src/vga/legacy_addressing.odin` | `vga_test_mode_x_320x240_is_reached_through_the_ports` starts from BIOS mode 13h and performs the whole switch through Miscellaneous Output, Sequencer 04h and the CRT Controller ports, then plots through the Map Mask and the A0000h aperture: four adjacent pixels resolve to four planes, the fifth returns to plane 0, and the last pixel of row 239 pins the eighty-byte pitch and the doubled 480-line timing together. `vga_test_mode_13h_chaining_differs_from_mode_x` runs the same plots without the switch and requires a different image, so the proof cannot pass on addressing that would have worked chained. `vga_test_mode_x_generalized_scanout_crc` and `vga_test_mode_x_scanout` remain as the register-level pins |
| Start address, byte pan, PEL pan, and line-compare split | IBM 2-95 and 2-102 to 2-103 | Conformant | Core paths exist across `src/vga/legacy_addressing.odin` and `src/vga/scanout.odin` | `vga_test_split_screen_combines_byte_pan_and_pel_pan` programs the split, the byte pan, the PEL pan and the pan-reset bit through four different public ports and requires exact pixels for a row above the split and a row below it, then requires the rows below to take both pans once the reset bit is cleared. The deferred and mid-frame halves are on the raster journal row |
| Horizontal/vertical overscan and blank output | IBM 2-13 and 2-57 to 2-73 | Conformant | `src/vga/scanout.odin` resolves the border colour through the palette and DAC and derives the four border extents from the blanking registers; both travel on the legacy presentation header and `src/host/render.odin` scales the canvas inside a border of that proportion. Output-disable blanks the border with the image. The pixel buffer still carries only the active image, which ADR 0012 chose deliberately so accepted frame CRCs stay valid | `vga_test_border_extents_come_from_display_end_and_blank_start` pins all four sides of mode 12h against the raster registers, `vga_test_border_extents_are_published_in_image_pixels` proves the dot-clock to pixel ratio in 256-colour mode through a port-programmed blank start, `vga_test_legacy_frame_header_publishes_border_extents` proves the header carries them beside the colour with the canvas unchanged, and `host_test_border_extents_shrink_the_guest_canvas` proves the host inset. The overscan-colour proofs listed against Attribute 11h cover the colour and its blanking |
| Scanline-ordered register, palette, and aperture changes | IBM programming considerations | Conformant | `src/vga/raster_journal.odin` carries a bounded scan-line journal of typed deltas on the descriptor and host expansion replays it. DAC entries, Attribute Controller 13h PEL panning, CRT Controller 08h preset row and byte panning, and the Attribute 00h-0Fh internal palette with its Palette Address Source bit are all recorded. Three kinds the ADR originally whitelisted are excluded with reasons recorded in its amendments: the display-start pair latches at vertical retrace, and aperture and bank select are either invisible to expansion or a frame-geometry input. A fourth, the overscan colour, is an explicit exclusion below. Border extents themselves now ship, on the row above | `raster_journal_test_palette_splits_replay_above_and_below_the_split` drives two splits through the public DAC ports at timestamps inside one frame and proves three colour bands from a single palette index; `raster_journal_test_pel_pan_split_shifts_only_the_rows_below_it` and `raster_journal_test_byte_pan_split_moves_only_the_rows_below_it` do the same for the two panning registers. Siblings prove a frame without mid-frame writes carries an empty journal and expands byte-identically, and that overflow marks the frame truncated, counts it in `raster_journal_truncations`, and falls back to expansion from the final register state. The VM-side raster path stays in the tree as the reference and remains switched off in production |
| Descriptor contains only explicit raw scanout state | ADR 0001 and `CONTEXT.md` | Conformant | `src/vga/scanout_descriptor.odin` | `scanout_descriptor_test_uses_explicit_state_without_source_vga_lifetime` |

## BIOS mode contracts

`test_machine_vgabios_int10_mode_matrix` boots the pinned Bochs VGABIOS on the
production machine and walks every mode below through a real-mode probe. For
each mode it asserts the mode echoed by INT 10h AH=0Fh, the reported column
count and active page, the BIOS Data Area mode, columns, row count, and
character height, and the Miscellaneous Output and CRT Controller display-end
registers read back through public ports.

BIOS text columns and CRT Controller character clocks are separate contracts and
are asserted separately: mode 13h reports 40 columns while programming 80
character clocks.

`test_machine_vgabios_int10_font_services` drives AH=11h through the same
harness. It asserts that AL=30h reports the on-screen font geometry rather than
the requested block, that BH selects distinct ROM font addresses, and that
AL=11h, AL=12h, and AL=14h recalculate to 28, 50, and 25 rows. Combined with
the 350 scan line select it also reaches the 43-row geometry, and the host text
snapshot is asserted to follow at 80x43.

`test_machine_vgabios_int10_state_save_restore_round_trip` drives AH=1Ch. It
sizes the state buffer, marks a DAC entry, saves, changes mode and overwrites
the entry, restores, and then requires the DAC entry, the BIOS data area mode,
and the CRT Controller geometry to all return to their saved values.

| INT 10h mode | Expected contract | Status | Executable proof |
| --- | --- | --- | --- |
| 00h, 01h | 40-column color text | Conformant | `test_machine_vgabios_int10_mode_matrix` |
| 02h, 03h | 80-column color text | Conformant | `test_machine_vgabios_int10_mode_matrix` |
| 04h, 05h | 320x200 CGA-compatible 4-color | Conformant | `test_machine_vgabios_int10_mode_matrix` |
| 06h | 640x200 CGA-compatible monochrome | Conformant | `test_machine_vgabios_int10_mode_matrix` |
| 07h | 80-column monochrome text | Conformant | `test_machine_vgabios_int10_mode_matrix` covers the 3B4h monochrome CRTC address |
| 0Dh | 320x200x16 planar | Conformant | `test_machine_vgabios_int10_mode_matrix` |
| 0Eh | 640x200x16 planar | Conformant | `test_machine_vgabios_int10_mode_matrix` |
| 0Fh | 640x350 monochrome planar | Conformant | `test_machine_vgabios_int10_mode_matrix` |
| 10h | 640x350x16 planar | Conformant | `test_machine_vgabios_int10_mode_matrix` |
| 11h | 640x480 monochrome planar | Conformant | `test_machine_vgabios_int10_mode_matrix` |
| 12h | 640x480x16 planar | Conformant | `test_machine_vgabios_int10_mode_matrix` plus `test_machine_boots_bochs_vgabios_and_sets_vbe_mode` |
| 13h | 320x200x256 chain-4 | Conformant | `test_machine_vgabios_int10_mode_matrix` plus the full-size mode 13h scanout test |
| Font services supporting 8x8 and 8x16 43/50-row text | IBM INT 10h AH=11h | Conformant | `test_machine_vgabios_int10_font_services` |
| Save/restore VGA hardware, BIOS, DAC, and register state | IBM INT 10h AH=1Ch | Conformant | `test_machine_vgabios_int10_state_save_restore_round_trip` |

## VBE 2.0 and Bochs DISPI

DISPI models `X_OFFSET` and `Y_OFFSET` as the origin of the visible screen part
within a larger virtual screen, so a display start is only valid while
`x_offset + XRes` fits the virtual width. Two consequences are intentional and
covered by `vga_test_dispi_virtual_pitch_and_offsets`: narrowing the logical
scan line length clamps any existing offset into the new window, and an offset
that no longer fits is rejected outright.

INT 10h 4F07h reports success unconditionally because the pinned firmware never
checks the DISPI write result, so a rejected pixel offset still returns
AL=4Fh with AH=00h. Order matters when testing this: set the logical scan line
length before the display start, as guests do.

| Contract | Reference | Status | Implementation | Executable proof |
| --- | --- | --- | --- | --- |
| 4F00h controller information and mode-list termination | VBE 2.0 4.3 | Conformant | Pinned VGABIOS | `test_machine_vbe_controller_mode_information_and_round_trip` checks the VESA signature, version, memory, capabilities, and a terminated mode list |
| 4F01h mode information | VBE 2.0 4.4 | Conformant | Pinned VGABIOS and DISPI capability reads | `test_machine_vbe_controller_mode_information_and_round_trip` asserts attributes, geometry, depth, memory model, pitch, and physical base across packed and direct colour modes |
| 4F02h set mode, banked/LFB and clear/preserve | VBE 2.0 4.5 | Conformant | `src/vga/vbe.odin` and pinned VGABIOS | Banked 101h and 151h proofs exist, and `test_machine_vbe_controller_mode_information_and_round_trip` proves a firmware linear set that the device agrees with. `test_machine_vbe_mode_set_clear_and_preserve` closes the D15 matrix: the same mode set twice without D15 clears display memory between the two, and with D15 it keeps what the guest wrote |
| 4F03h return exact current mode and flags | VBE 2.0 4.6 | Conformant | Pinned VGABIOS | `test_machine_vbe_controller_mode_information_and_round_trip` proves the mode number round-trips exactly. The D14 and D15 flags are an explicit exclusion below |
| 4F04h save/restore state | VBE 2.0 4.7 | Conformant | Pinned VGABIOS | `test_machine_vbe_state_and_palette_round_trip` sizes the buffer, saves, overwrites palette entries, restores, and requires the saved entries back |
| 4F05h display window control and direct entry | VBE 2.0 4.8 | Conformant | DISPI bank register | `test_machine_vbe_window_scanline_and_display_start` proves the BH=00h/01h window set and get round-trip, and `test_machine_vbe_window_entry_point_and_protected_mode_table` far-calls the `WindowFuncPtr` the ModeInfoBlock hands out and requires 4F05h to report the window that call moved |
| 4F06h logical scanline length and achievable-width adjustment | VBE 2.0 4.9 | Conformant | `src/vga/vbe.odin` adjusts virtual width and clamps offsets | `test_machine_vbe_window_scanline_and_display_start` proves get, set in pixels, persistence, byte pitch tracking, and the recomputed addressable scan line count; `test_machine_vbe_scanline_length_rounds_up_to_an_achievable_width` closes the rounding path in mode 102h, where eight pixels share a byte: 1281 pixels is not achievable, so the width is raised to 1288 and the firmware answers 161 bytes. The device used to store the odd width as asked, which left the firmware's flooring pitch arithmetic a byte short of the layout `dispi_pitch` produces |
| 4F07h display start, including retrace request | VBE 2.0 4.10 | Conformant | DISPI offsets | `test_machine_vbe_window_scanline_and_display_start` proves the immediate BL=00h and the BL=80h retrace request both round-trip through BL=01h, and that an out-of-range scan line is rejected without mutating the current start |
| 4F08h DAC palette format | VBE 2.0 4.11 | Conformant | DISPI 8-bit DAC flag | `test_machine_vbe_state_and_palette_round_trip` proves the six to eight to six bit round-trip through BL=00h and BL=01h |
| 4F09h palette data | VBE 2.0 4.12 | Conformant | VGA DAC ports through firmware | `test_machine_vbe_state_and_palette_round_trip` proves the BL=00h set, the BL=01h read back, and the BL=80h retrace request |
| 4F0Ah protected-mode interface | VBE 2.0 4.13 | Conformant | Pinned VGABIOS | `test_machine_vbe_window_entry_point_and_protected_mode_table` requires the call to return a table with a usable length and all three of the window, display-start and palette entry offsets landing inside it. The entries are position-independent real-mode code the firmware also reaches through 4F05h, which the same test calls directly |
| 4F15h DDC capabilities and EDID block 0 | VBE supplemental DDC and pinned VGABIOS | Conformant | `src/vga/ddc.odin`, pinned VGABIOS | `vga_test_ddc2_reads_checksum_valid_edid`, `test_machine_boots_bochs_vgabios_and_sets_vbe_mode` |
| DISPI ID0 feature set | Bochs B0C0 | Conformant | `src/vga/vbe.odin` | `vga_test_dispi_id_gates_features_and_bpp_zero` |
| DISPI ID1 virtual geometry and offsets | Bochs B0C1 | Conformant | `src/vga/vbe.odin` | `vga_test_dispi_id_gates_features_and_bpp_zero`, `vga_test_dispi_virtual_pitch_and_offsets` |
| DISPI ID2 BPP values, BPP zero compatibility, LFB and no-clear | Bochs B0C2 | Conformant | `src/vga/vbe.odin` | `vga_test_dispi_id_gates_features_and_bpp_zero` |
| DISPI ID3 GETCAPS and 8-bit DAC | Bochs B0C3 | Conformant | `src/vga/vbe.odin` | `vga_test_dispi_width_and_capabilities`, `vga_test_dispi_id_gates_features_and_bpp_zero` |
| DISPI ID0 to ID5 feature ladder and identifier range | Bochs B0C0 to B0C5 | Conformant | `src/vga/vbe.odin` | `vga_test_dispi_feature_ladder_follows_selected_id`, `vga_test_dispi_id_range_is_bounded` |
| DISPI index 0Ah memory-size register | Bochs B0C5 | Conformant | `src/vga/vbe.odin` reports the persona aperture | `vga_test_dispi_memory_size_is_reported_at_every_id`, `vga_test_dispi_memory_size_register_rejects_writes`, and the pinned-firmware total in `test_machine_vbe_controller_mode_information_and_round_trip` |
| Mode 150h 320x200x8 banked and LFB | Pinned Bochs mode table | Conformant | Pinned VGABIOS, `src/vga/vbe.odin`, `src/machine/machine.odin` legacy alias | `test_machine_vbe_mode_set_clear_and_preserve` sets the mode from the firmware, writes through the banked window and requires the device to render the four bytes it wrote. `test_machine_vbe_linear_framebuffer_modes` sets it with D14 and reads PhysBasePtr back. The LFB write side shares the fixed aperture the row below proves |
| Mode 151h 320x240x8 banked and LFB | Pinned Bochs mode table | Conformant | Pinned VGABIOS, `src/vga/vbe.odin`, `src/machine/machine.odin` legacy alias | Real firmware banked read/write/render proof exists, and `test_machine_vbe_linear_framebuffer_modes` requires the firmware to come up with the LFB flag set and to advertise `VBE_LFB_BASE` in PhysBasePtr. `test_machine_vbe_lfb_alias_decodes_after_bar_move` closes the LFB half from the guest side: a real-mode probe enters unreal mode, writes through the advertised E0000000 while the system firmware has the BAR at F8000000, reads its own bytes back through the alias, and the device renders them. The fixed aperture is a dirty-tracked alias of the framebuffer, so PhysBasePtr is honest wherever the BAR moves |

## Roadmap

The order the remaining `Partial` rows are being worked in. Each entry names the
rows it closes, so this section is a view of the matrix rather than a second
source of truth. An entry disappears when its rows read `Conformant` or when the
row records a deliberate limit instead.

Nothing remains. The VGA core, GDI and DirectDraw are all done, and the one
open routing question has been decided twice: first recorded as a limit, then
reversed when it turned out to break real software. DOS-era VBE programs map
the PhysBasePtr the ModeInfoBlock advertises and write every pixel through it,
so with the BAR at F8000000 those writes fell into the tolerated mmconfig probe
zone: a black screen at one MemoryAccess exit per store. E0000000 is now a
fixed dirty-tracked alias of the framebuffer for the machine's whole life, no
boot ever touched that range for mmconfig probing in any measured run, and the
remaining E4000000 through F0000000 span keeps its tolerated-probe behavior.
Modes 150h and 151h are `Conformant` with a guest-side unreal-mode proof.

GDI and DirectDraw conformance is carried by the GSWGFX guest suite rather than
by this matrix; see `AGENTS.md` for the gate and its expected counts. Both pass
as of 2026-07-28, and both are now inside the accepted profile rather than
beside it: the profile runs `/no-d3d`, which enters GDI and DirectDraw and
records only Direct3D `UNAVAILABLE`.

- **GDI passes at every advertised mode, including 320x240x8.** That pair was
  absent because GDI offers a mode only if the display driver's class key
  carries it, and the gate image was installed with an INF predating
  `MODES\8\320,240`. An earlier attempt to import the key was read as hanging
  the guest; it had not. The registry file used for it carried single
  backslashes in the launcher's `Run` value, so the value imported as
  `C:GSWGFXGSWGFX.EXE` and the probe never started. Importing the same key from
  a file derived by byte replacement from a known-good original works, and the
  pair now smokes and benchmarks. The shipping INF already carries the mode, so
  a freshly installed guest never needed the repair.
- **DirectDraw took three defects in RETVRN99's own guest bridge.** All three
  were found by giving the guest a voice through `serial1.log` and reading what
  it printed, after several attempts to reason about it from the outside had to
  be withdrawn. The IOCTL handler refused any buffer at or above 80000000h as
  "not ring 3", where VWIN32 legitimately places them, so every request came
  back as ERROR_INVALID_FUNCTION. The bridge load then compared a framebuffer
  identity the display driver has not published on the first pass, refusing the
  bridge permanently. Last, `gswdd32.dll` loads per process while the HAL keeps
  its state in the shared arena, so a module handle and entry points cached by
  one process were being called from another. All three are fixed.
- **DirectDraw now proves more than the flip chain.** Every enumerated mode also
  runs a `BLT_FILL` row: a whole-surface colour fill, a sub-rectangle fill in a
  second colour, a surface Blt of that rectangle to a third position, and a
  locked readback of four points that must show fill, fill, blit and background
  in the right places. That reaches the HAL's colour fill and Blt entries, which
  no test at any layer touched before. It checks behaviour rather than which
  layer produced it: DirectDraw may satisfy either call from the HEL.

## Explicit exclusions

| Contract | Status | Reason |
| --- | --- | --- |
| External auxiliary VGA clock input and analog extension connector | Out of target | No emulated external video source; deterministic fallback is documented and tested |
| Dot-cycle memory contention, snow, and electrical signal integrity | Out of target | Milestone targets software-visible scanline timing |
| Standalone Hercules hardware | Out of target | VGA monochrome compatibility mode is in target; Hercules registers are not |
| Clone-specific undocumented VGA/SVGA quirks | Out of target | IBM VGA and pinned Bochs contracts are normative |
| VBE 3.0 custom CRTC timings | Out of target | Legacy firmware contract is VBE 2.0 |
| Bochs per-identifier video memory ceilings, 8 MiB at ID4 and 16 MiB at ID5 | Out of target | DISPI identifiers gate capability, never capacity. The full persona aperture is exposed at every level and index 0Ah reports the true size, one level earlier than Bochs exposed it. See ADR 0011 |
| Display-enable skew, CRT Controller 03h bits 5 and 6 | Out of target | Presentation has no character-clock pipeline for the skew to delay, and no firmware mode programs a nonzero value: every mode in `test_bochs_legacy_mode` and in the firmware matrix programs 03h as 82h or 90h |
| The horizontal retrace signal itself | Out of target | VGA publishes no horizontal-retrace bit; Input Status 1 carries display enable, which is the blanking interval the retrace sits inside. The window 04h and 05h describe is derived and asserted, but there is nothing on the adapter that could consume it |
| Mid-frame overscan colour changes | Out of target | The border ships as header metadata the host paints rather than as expanded pixels, so a mid-frame border colour would need a published band list and a second replay of the palette state that resolves it. The border extents themselves ship, and every other whitelisted delta kind is replayed |
| VBE 4F03h D14 and D15 mode flags | Out of target | The pinned firmware masks the stored mode with 1FFh before returning it, so the linear-framebuffer and preserve-memory flags cannot come back. Reachable only by changing the firmware, which is pinned by hash |
| Sequencer 01h serializer load rate, bits 2 and 4 | Out of target | Presentation is scanline ordered and has no serializer to reload, so the load rate has nothing to act on. `test_machine_vgabios_int10_mode_matrix` requires both bits to stay at their reset value across every firmware mode set |
| Sequencer 04h extended-memory gating, bit 1 | Out of target | The same principle as ADR 0011: a capability bit never shrinks capacity. Clearing it on real hardware hides everything above 64 KiB, and honouring that could only take memory away from a guest. `test_machine_vgabios_int10_mode_matrix` requires the firmware to enable it in every mode, so no supported path depends on the restriction |
| DirectDraw, Direct3D, or OpenGL acceleration changes | Out of target | Existing GSW-VGA 2D and guarded 3D Interfaces remain unchanged |
| PCIe mmconfig probe tolerance below `E4000000` | Out of target | The fixed legacy framebuffer alias claims E0000000 through E4000000, so a probe there now reads framebuffer bytes rather than FFh. No measured boot ever touched the range: SeaBIOS publishes no MCFG and the zone log stayed empty across every retained run. The rest of the zone, E4000000 through F0000000, keeps its tolerated-probe behavior unchanged |
