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
| Miscellaneous Output 3C2h/3CCh: I/O select, RAM enable, clock select, sync polarity, reserved bits | IBM 2-42 to 2-43 | Partial | `src/vga/ports.odin`, `src/vga/timing.odin` | `test_vga_io_decode_follows_misc_output` and `test_machine_vgabios_int10_mode_matrix` cover I/O select and per-mode clock and sync polarity across five firmware values; reserved-bit tests remain |
| Input Status 0 3C2h: switch sense and pending CRT interrupt | IBM 2-44 | Conformant | `src/vga/legacy_beam.odin`, `src/vga/timing.odin` | `vga_test_status0_switch_sense_and_retrace`, `vga_test_vertical_interrupt_latch_and_callback` |
| Input Status 1 3BAh/3DAh: display enable, vertical retrace, Attribute flip-flop reset | IBM 2-45 | Partial | `src/vga/legacy_beam.odin`, `src/vga/timing.odin`, `src/vga/ports.odin` | Absolute timing and public CRTC reset tests cover blank/retrace; full CGA/MDA matrix remains |
| Feature Control 3BAh/3DAh and 3CAh reserved behavior | IBM 2-46 | Partial | `src/vga/ports.odin` retains two undocumented bits | Reserved read/write test required |
| Video Subsystem Enable 3C3h decode behavior | IBM 2-46 and INT 10h AH=12h BL=32h | Partial | `src/vga/legacy_control.odin` | BIOS disable/enable integration test required |
| Sequencer 00h synchronous/asynchronous reset | IBM 2-48 | Conformant | `src/vga/ports.odin`, `src/vga/scanout.odin` | `vga_test_sequencer_reset_public_port_matrix_preserves_state`, `vga_test_sequencer_reset_and_screen_off_are_independent`, `vga_test_sequencer_reset_drives_damage_generation_and_descriptor_restore`, `test_machine_vga_sequencer_reset_crosses_io_and_restores_scanout` |
| Sequencer 01h clocking mode: 8/9 dots, shift load, dot-clock divide, shift-4, screen off | IBM 2-49 to 2-50 | Partial | Dot width, divide, and screen off exist; serializer load controls are inert | Serializer and screen-off tests required |
| Sequencer 02h map mask | IBM 2-51 | Conformant | `src/vga/memory.odin` | `src/vga/memory_tests.odin` map-mask cases |
| Sequencer 03h character map select | IBM 2-52 to 2-53 | Conformant | `src/vga/scanout.odin` | `test_vga_text_uses_selected_character_maps` |
| Sequencer 04h extended memory, odd/even disable, chain-4 | IBM 2-54 | Partial | Odd/even and chain-4 exist; extended-memory gating is inert | Addressing matrix expansion required |

## CRT Controller registers

| Register contract | Reference | Status | Implementation | Executable proof |
| --- | --- | --- | --- | --- |
| 00h Horizontal Total | IBM 2-56 | Conformant | `src/vga/timing.odin` | Timing total tests |
| 01h Horizontal Display Enable End | IBM 2-57 | Conformant | `src/vga/timing.odin`, `src/vga/scanout.odin` | Mode geometry tests |
| 02h Start Horizontal Blanking | IBM 2-57 | Partial | `src/vga/timing.odin`, `src/vga/legacy_beam.odin` | Status 1 blank-window tests exist; per-mode public-port matrix remains |
| 03h End Horizontal Blanking and display-enable skew | IBM 2-58 | Partial | `src/vga/timing.odin`, `src/vga/legacy_beam.odin` | Wrapped blank-end exists; display-enable skew remains out of proof |
| 04h Start Horizontal Retrace | IBM 2-59 | Partial | `src/vga/timing.odin`, `src/vga/legacy_beam.odin` | Status 1 vertical-retrace proof exists; horizontal-retrace proof remains |
| 05h End Horizontal Retrace, delay, and blank bit 5 | IBM 2-60 | Partial | `src/vga/timing.odin`, `src/vga/legacy_beam.odin` | Wrapped retrace exists; blank-bit proof remains |
| 06h Vertical Total | IBM 2-61 | Conformant | `src/vga/timing.odin` | Timing total tests |
| 07h Overflow fields and protected line-compare exception | IBM 2-62 | Partial | Geometry, blanking, and protection fields exist | Public-port overflow/protection matrix remains |
| 08h Preset Row Scan and byte panning | IBM 2-63 | Conformant | `src/vga/legacy_addressing.odin` | `src/vga/legacy_addressing_tests.odin` |
| 09h Maximum Scan Line, double scan, line compare, vertical blank bit 9 | IBM 2-64 | Partial | Blanking bit participates; maximum scan and double scan are not multiplied | Combined scan-factor test required |
| 0Ah Cursor Start and cursor off | IBM 2-65 | Partial | Cursor off exists; shape edge cases need correction | Text cursor matrix required |
| 0Bh Cursor End and cursor skew | IBM 2-66 | Partial | End-before-start incorrectly wraps instead of hiding | Text cursor matrix required |
| 0Ch/0Dh Start Address and vertical-retrace latch | IBM 2-67 and 2-99 | Partial | Pending/retrace latch exists; scheduler and mid-frame proof are incomplete | Start-latch and deferred scanout tests required |
| 0Eh/0Fh Cursor Location | IBM 2-68 | Conformant | `src/vga/scanout.odin` | Cursor location tests |
| 10h Vertical Retrace Start | IBM 2-69 | Partial | `src/vga/timing.odin`, `src/vga/legacy_beam.odin`, `src/machine/machine.odin` | `vga_test_vertical_interrupt_latch_and_callback` and IRQ2 source tests exist; halted-guest proof remains |
| 11h Vertical Retrace End, protection, IRQ enable and clear | IBM 2-69 to 2-70 | Partial | `src/vga/ports.odin`, `src/vga/legacy_beam.odin`, `src/machine/pic.odin` | Latch, default-clear, AT IRQ2-to-IRQ9 redirect, and level-triggered clear proofs exist; wrapped-end matrix remains |
| 12h Vertical Display Enable End | IBM 2-71 | Conformant | `src/vga/timing.odin` | Mode geometry tests |
| 13h Offset | IBM 2-71 | Conformant | `src/vga/legacy_addressing.odin` | Pitch/address tests |
| 14h Underline Location, count-by-4, doubleword mode | IBM 2-72 | Partial | Address bits exist; text underline is absent | Underline and addressing tests required |
| 15h Start Vertical Blanking | IBM 2-73 | Partial | `src/vga/timing.odin`, `src/vga/legacy_beam.odin` | Status/IRQ timing uses programmed vblank start; public-port matrix remains |
| 16h End Vertical Blanking | IBM 2-73 | Partial | `src/vga/timing.odin`, `src/vga/legacy_beam.odin` | Wrapped blank-end exists; per-mode proof remains |
| 17h reset, word/byte mode, address wrap, count-by-2, row-scan select | IBM 2-74 to 2-76 | Partial | Address mapping exists; reset and horizontal-row clock behavior are absent | Address and reset tests required |
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
| Attribute address/data flip-flop and IPAS palette gating | IBM 2-89 to 2-90 | Conformant | `src/vga/ports.odin` | `vga_test_attribute_flip_flop_and_dac` |
| Attribute 00h-0Fh internal palette | IBM 2-90 to 2-91 | Partial | Palette and color-select path exist; access gating and some 256-color semantics are incomplete | Palette path tests required |
| Attribute 10h mode control: graphics, mono, line graphics, blink, PEL width, pan compatibility | IBM 2-92 to 2-93 | Partial | Several fields are consumed; monochrome and 256-color distinctions are incomplete | Text, indexed, and split tests required |
| Attribute 11h overscan color | IBM 2-94 | Missing | Stored but never scanned out | Border test required |
| Attribute 12h color plane enable and status mux | IBM 2-94 | Partial | Plane masking exists; status mux coverage is incomplete outside graphics modes | Plane and status tests required |
| Attribute 13h horizontal PEL panning | IBM 2-95 | Partial | Text/planar path exists; mode 13h value mapping is incorrect | Mode 13h and Mode X pan tests required |
| Attribute 14h color select | IBM 2-96 | Conformant | `src/vga/scanout.odin` | Palette-selection tests |
| DAC mask, state, read/write index, 6-bit components and auto-increment | IBM 2-104 to 2-107 | Conformant | `src/vga/ports.odin` | DAC tests in `src/vga/vga_tests.odin` and VBE tests |
| VBE 8-bit DAC extension | Bochs ID3 and VBE functions 08h/09h | Partial | Device flag exists; full firmware proof is absent | VGABIOS DAC integration test required |

## Memory and scanout behavior

| Contract | Reference | Status | Implementation | Executable proof |
| --- | --- | --- | --- | --- |
| A0000h/B0000h/B8000h aperture selection and decode disable | IBM 2-24 to 2-38 and 2-86 | Conformant | `src/vga/memory.odin` | Aperture-map and PCI decode tests |
| Plane latches and read modes 0/1 | IBM 2-35 to 2-40 | Conformant | `src/vga/memory.odin` | Latch/read-mode tests |
| Write modes 0-3 | IBM 2-35 to 2-40 and 2-85 | Conformant | `src/vga/memory.odin` | Write-mode matrix |
| Chain-4 and odd/even addressing combinations | IBM 2-24 to 2-34 and 2-54 | Partial | Main combinations exist; exhaustive boundary/wrap matrix is incomplete | Expanded transaction tests required |
| Multi-byte aperture transactions preserve byte-cycle VGA semantics | IBM memory data flow | Conformant | `src/vga/memory.odin`, `src/machine/machine.odin` | `vga_test_aperture_slice_access_is_one_visible_transaction`, `test_machine_vga_legacy_aperture_batches_mmio_transaction` |
| CGA 16 KiB page/address wrapping | IBM CGA compatibility modes | Partial | Dedicated CGA persona exists; full wrap matrix is unproven | Public-port CGA tests required |
| Text modes 40/80 columns and 25/43/50 rows | IBM BIOS modes and font services | Conformant | `src/vga/scanout.odin`, `src/host/render.odin` | `vga_test_text_snapshot_variable_geometry`, `host_test_render_snapshot_uses_snapshot_geometry` |
| Text underline, monochrome attributes, blink, line graphics, and cursor shape | IBM 2-15 to 2-17 and CRTC/Attribute sections | Partial | Blink and line graphics partly exist; underline/mono/cursor edge behavior is incomplete | Text conformance matrix required |
| Planar 16-color scanout | IBM modes 0Dh-12h | Conformant | `src/vga/scanout.odin` | Mode and planar scanout tests |
| Chain-4 256-color mode 13h scanout | IBM mode 13h | Conformant | `src/vga/scanout.odin` | Full-size mode 13h test |
| Unchained 256-color Mode X scanout | IBM register model plus documented compatible programming | Partial | Implementation and synthetic tests exist; real 320x240 tuple is unproven | Port-programmed 320x240 test required |
| Start address, byte pan, PEL pan, and line-compare split | IBM 2-95 and 2-102 to 2-103 | Partial | Core paths exist; mode-specific and deferred proofs are incomplete | Combined public-port tests required |
| Horizontal/vertical overscan and blank output | IBM 2-13 and 2-57 to 2-73 | Missing | Active image only | Border/blank frame tests required |
| Scanline-ordered register, palette, and aperture changes | IBM programming considerations | Missing | Deferred production path discards raster changes | Descriptor journal tests required |
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
| 4F02h set mode, banked/LFB and clear/preserve | VBE 2.0 4.5 | Partial | `src/vga/vbe.odin` and pinned VGABIOS | Banked 101h and 151h proofs exist, and `test_machine_vbe_controller_mode_information_and_round_trip` proves a firmware linear set that the device agrees with; the clear/preserve D15 matrix remains |
| 4F03h return exact current mode and flags | VBE 2.0 4.6 | Partial | Pinned VGABIOS | `test_machine_vbe_controller_mode_information_and_round_trip` proves the mode number round-trips exactly; the pinned firmware masks the stored mode with 0x1FF, so the D14 and D15 flags are never returned and that half of the contract is unreachable without a firmware change |
| 4F04h save/restore state | VBE 2.0 4.7 | Partial | Pinned VGABIOS | Query/save/mutate/restore test required |
| 4F05h display window control and direct entry | VBE 2.0 4.8 | Partial | DISPI bank register | `test_machine_vbe_window_scanline_and_display_start` proves the BH=00h/01h window set and get round-trip; the `WindowFuncPtr` direct far-call entry remains untested |
| 4F06h logical scanline length and achievable-width adjustment | VBE 2.0 4.9 | Partial | `src/vga/vbe.odin` adjusts virtual width and clamps offsets | `test_machine_vbe_window_scanline_and_display_start` proves get, set in pixels, persistence, byte pitch tracking, and the recomputed addressable scan line count; the rounding path is still unexercised because every byte pitch is achievable at 8 bits per pixel, so it needs a mode whose pitch is forced to align |
| 4F07h display start, including retrace request | VBE 2.0 4.10 | Conformant | DISPI offsets | `test_machine_vbe_window_scanline_and_display_start` proves the immediate BL=00h and the BL=80h retrace request both round-trip through BL=01h, and that an out-of-range scan line is rejected without mutating the current start |
| 4F08h DAC palette format | VBE 2.0 4.11 | Partial | DISPI 8-bit DAC flag | 6/8-bit round-trip test required |
| 4F09h palette data | VBE 2.0 4.12 | Partial | VGA DAC ports through firmware | Set/get and retrace-request tests required |
| 4F0Ah protected-mode interface | VBE 2.0 4.13 | Partial | Pinned VGABIOS | Table and callable window/display/palette entry tests required |
| 4F15h DDC capabilities and EDID block 0 | VBE supplemental DDC and pinned VGABIOS | Conformant | `src/vga/ddc.odin`, pinned VGABIOS | `vga_test_ddc2_reads_checksum_valid_edid`, `test_machine_boots_bochs_vgabios_and_sets_vbe_mode` |
| DISPI ID0 feature set | Bochs B0C0 | Conformant | `src/vga/vbe.odin` | `vga_test_dispi_id_gates_features_and_bpp_zero` |
| DISPI ID1 virtual geometry and offsets | Bochs B0C1 | Conformant | `src/vga/vbe.odin` | `vga_test_dispi_id_gates_features_and_bpp_zero`, `vga_test_dispi_virtual_pitch_and_offsets` |
| DISPI ID2 BPP values, BPP zero compatibility, LFB and no-clear | Bochs B0C2 | Conformant | `src/vga/vbe.odin` | `vga_test_dispi_id_gates_features_and_bpp_zero` |
| DISPI ID3 GETCAPS and 8-bit DAC | Bochs B0C3 | Conformant | `src/vga/vbe.odin` | `vga_test_dispi_width_and_capabilities`, `vga_test_dispi_id_gates_features_and_bpp_zero` |
| DISPI ID4 8 MiB memory contract | Bochs B0C4 | Partial | Device exposes the shared 32 MiB VRAM regardless selected ID | Version/memory test and documented compatibility policy required |
| DISPI ID5 16 MiB plus memory-size register | Bochs B0C5 | Partial | Device reports 32 MiB through index 0Ah | Pinned-firmware compatibility test required |
| Mode 150h 320x200x8 banked and LFB | Pinned Bochs mode table | Partial | Mode exists | Real firmware read/write/render test required |
| Mode 151h 320x240x8 banked and LFB | Pinned Bochs mode table | Partial | Pinned VGABIOS and `src/vga/vbe.odin` | Real firmware banked read/write/render proof exists; LFB firmware proof remains |

## Explicit exclusions

| Contract | Status | Reason |
| --- | --- | --- |
| External auxiliary VGA clock input and analog extension connector | Out of target | No emulated external video source; deterministic fallback is documented and tested |
| Dot-cycle memory contention, snow, and electrical signal integrity | Out of target | Milestone targets software-visible scanline timing |
| Standalone Hercules hardware | Out of target | VGA monochrome compatibility mode is in target; Hercules registers are not |
| Clone-specific undocumented VGA/SVGA quirks | Out of target | IBM VGA and pinned Bochs contracts are normative |
| VBE 3.0 custom CRTC timings | Out of target | Legacy firmware contract is VBE 2.0 |
| DirectDraw, Direct3D, or OpenGL acceleration changes | Out of target | Existing GSW-VGA 2D and guarded 3D Interfaces remain unchanged |
