<!-- SPDX-License-Identifier: GPL-3.0-only -->

# ADR 0010: Windows 98 graphics diagnostic contract

## Status

Accepted

## Context

Graphics development needs repeatable evidence about advertised display modes,
basic presentation, performance anomalies, and desktop restoration. The former
probe encoded one fixed 46-row plan, generated large per-call event logs, and
published guest-resident result files. That contract tested the implementation
order of one narrow 8-bpp scenario more strongly than it tested the graphics
interfaces exposed to software.

A game is useful later compatibility evidence, but game startup, input, audio,
and rendering behavior make it a poor owner of this diagnostic. The production
GSW-VGA driver and private GSW3D transport are also outside the evidence path:
using them would make a public-interface test circular.

## Decision

### Diagnostic Module and package Interface

The Graphics diagnostic is a standalone developer tool for a licensed Windows
98 guest. It is staged only in `C:\GSWGFX`, is not part of the GSW-VGA driver
package, and is never referenced by the display INF.

The package Interface contains exactly two files:

- `C:\GSWGFX\GSWGFX.EXE`, a Win32 controller.
- `C:\GSWGFX\GSWVBE.EXE`, a DOS protected-mode VGA and VBE companion with the
  DOS/32A extender bound into the executable.

The controller Module owns the sequence `enumerate`, `smoke`, `benchmark`,
`restore`, `summarize`, and `report`. Graphics behavior is isolated behind one
Adapter Seam. Adapters do not infer production capability and do not send
private GSW3D traffic.

### Graphics Adapters

The VGA BIOS Adapter tests modes `00h` through `07h` and `0Dh` through `13h`.
Text modes receive a functional smoke. Graphics modes receive a functional
smoke and benchmark.

The VBE Adapter enumerates the controller and mode records through BIOS calls
`4F00h` and `4F01h`. It exercises every usable advertised graphics mode through
`4F02h`, verifies the active mode through `4F03h`, and uses banked and linear
framebuffer paths when the mode advertises them. Mode-set requests preserve
display memory because the probe immediately writes and verifies its own
patterns; it does not rely on the BIOS bulk-clear path.

The GDI Adapter deduplicates exact `width/height/bpp/hz` tuples, tests and sets
each mode without updating the registry, reads the resulting mode back,
presents a DIB, and restores the original desktop.

The DirectDraw Adapter attempts DirectDraw 7 first and DirectDraw 4 as a
Windows 98 fallback, enumerates modes, uses an exact fullscreen flipping chain,
bounds surface-loss recovery, releases ownership, and restores the desktop.

The Direct3D Adapter attempts Direct3D 7 first and Direct3D 3 as a fallback. It
enumerates public HAL and HEL devices and renders a pretransformed colored
triangle. Missing Direct3D is an `UNAVAILABLE` diagnostic result, not a failed
run. The Adapter never substitutes private GSW3D commands.

Two fixed prebuilt patterns provide deterministic workloads. Packers support
8-, 15-, 16-, 24-, and 32-bpp destinations. CRC32 covers only active packed
pixels, excluding pitch padding.

### Profiles and benchmark Module

The default profile smokes every advertised usable mode. It benchmarks all BIOS
graphics modes and every advertised depth at 320x200, 320x240, 640x480,
800x600, and 1024x768 for VBE, GDI, and DirectDraw. It benchmarks the selected
Direct3D HAL and HEL devices at 640x480, 800x600, and 1024x768 in advertised
16- and 32-bpp modes.

`/exhaustive` benchmarks every usable mode. Direct3D uses every compatible
DirectDraw mode for the selected HAL and HEL devices.

`/self-test` verifies metrics, TSV formatting, pattern CRC, and report transport
without changing a display mode. `/host-report` requires the Guest test device
and host artifacts, publishes the report, draws the final summary after desktop
restoration, and issues semantic Exit. `/import-vbe` consumes a companion
handoff created before Windows starts instead of launching a DOS session from
Windows. `/gdi-only`, `/ddraw-only`, and `/d3d-only` retain the same Adapter
contract while isolating one Windows path for diagnostic reruns; without those
switches all three Windows Adapters run.
`/ddraw4` selects the public DirectDraw 4 compatibility path from creation time
instead of accepting DirectDraw 7 first.
`/bounded` runs the GDI Adapter but records DirectDraw and Direct3D as
`UNAVAILABLE` without entering those interfaces. This is the fail-closed guest
profile when the public DirectDraw entry points cannot be bounded by the
controller process. Any unavailable coverage makes the terminal result at
least `WARN`; it cannot become `PASS`.

Each benchmark warms up for 500 ms, then measures complete generation, copy,
and presentation cycles continuously for 3,000 ms without sleeping. The timer
uses `QueryPerformanceCounter` when it remains monotonic and falls back to an
extended monotonic `GetTickCount` source selected before measurement.

At most 65,536 frame durations are retained. Frames continue to be counted
after the sample array fills and the row records `SAMPLE_CAP`. Metrics are
integer `avg_fps_milli`, nearest-rank `p50_us`, `p95_us`, `max_us`, and slow
frame count. A slow frame exceeds `max(2 * p50, 33333 us)`.

A row is `WARN` when average FPS is below 20, or, with at least 60 samples, p95
exceeds twice p50 or slow frames exceed `max(3, 1% of samples)`. Warnings expose
performance anomalies but do not fail a completed run. Functional, readback,
restoration, timer, companion, or reporting errors do fail it.

### DOS companion handoff

By default, the controller launches `GSWVBE.EXE` before the Windows Adapters.
For guests where a full-screen DOS session cannot return safely to the Windows
desktop, the explicit `/import-vbe` path requires `GSWVBE.EXE` to run before
Windows starts. The companion's `/preboot` profile completes the VGA BIOS
checks, records VBE as `UNAVAILABLE` when VBE BIOS work cannot be isolated or
timed out safely, and always returns control to the boot sequence. The full VBE
matrix remains available outside that bounded boot profile. The companion
writes bounded canonical records to `C:\GSWGFX\VBE.TMP`. The controller parses
the file and deletes it only after successful parsing. Absence, malformed
content, or a companion failure remains a failed diagnostic. This file is a
local handoff, is never authoritative evidence, and is never extracted from the
disk image.

### Guest test device report Interface

Commands `CRC=1`, `Snapshot=2`, and `Exit=3` retain their meanings. The report
Interface adds:

- `BeginReport=4`
- `AppendReport=5`
- `CommitReport=6`
- `AbortReport=7`

For report commands, registers 0 through 29 hold up to 30 payload bytes,
register 30 holds the Append length from 1 through 30, and register 31 holds
host status. Status values are `0=unprocessed`, `1=ok`, `2=bad_state`,
`3=bad_length`, `4=overflow`, `5=artifacts_disabled`, and `6=host_io`.

The host collector exists only when both `--test-device` and `--artifacts` are
enabled. It accepts at most 256 KiB, receives bytes only after benchmarks, and
never accepts a guest-selected path. Commit publishes atomically and without
overwrite to `artifacts/gswgfx-result.tsv`. Abnormal finalization publishes a
nonempty incomplete stream without overwrite as
`artifacts/gswgfx-result.partial.tsv`.

Direct port access from a Win32 ring-3 process remains a live acceptance gate.
If it faults or cannot round-trip, the evidence is preserved and work stops for
a separate test-only VxD design. Reporting is not coupled to the display VxD.

### Canonical result Interface

The report is bounded 7-bit ASCII with CRLF line endings, no BOM, and contiguous
decimal sequence numbers. Its exact header is:

`schema sequence record adapter mode width height bpp hz path status api_code frames duration_ms avg_fps_milli p50_us p95_us max_us slow_frames tested failed warnings unavailable crc32 detail`

Fields are separated by one tab. Schema is `GSWGFX_RESULT_V2`; records are
`MODE` or terminal `RUN`; status is `PASS`, `WARN`, `UNAVAILABLE`, or `FAIL`.
API codes use `0x` plus eight uppercase hexadecimal digits. CRC32 uses eight
uppercase hexadecimal digits. Detail is a bounded machine token, not localized
prose. The terminal `RUN` row records aggregate tested, failed, warning, and
unavailable counts.

Overall process exit is zero for completed PASS or WARN runs, one for
functional, restoration, companion, or report failure, and two for
configuration or internal failure.

The final screen is drawn only after the original desktop is restored. It shows
overall status, Adapter counts, elapsed time, and the worst eight rows. The
controller does not issue Snapshot. Normal semantic Exit finalization captures
the screen.

### Reproducible build and staging

The Win32 executable retains the pinned MinGW lock and generic build pipeline.
The DOS executable uses the existing pinned Open Watcom lock, `wcl386`,
`wlink`, the DOS/32A binder, and the pinned extender input. Two clean private
builds must produce byte-identical outputs before output hashes are accepted.
The DOS/32A license and acknowledgment travel with the source and build record.

Offline staging keeps its existing path, reparse-point, alternate-stream,
profile-lock, sidecar-state, transactional import, collision, and hash checks.
The accepted package shape changes only from `GSWGFX.EXE + PLAN.TSV` to
`GSWGFX.EXE + GSWVBE.EXE`.

### Proof boundary

A passing diagnostic proves only the recorded public BIOS VGA, VBE, GDI,
DirectDraw, and available legacy Direct3D outcomes in the tested guest. It can
identify unusually low or inconsistent presentation rates and prove exact
desktop restoration for that run.

It does not prove production Direct3D acceleration, private GSW3D correctness,
game compatibility, input, audio, reference-host parity, or capability
readiness. Direct3D `UNAVAILABLE` is evidence of absence, not successful 3D
coverage. Guest reports cannot promote graphics capabilities.

Image editing, guest execution, driver staging, and live display-mode changes
require a separately approved disposable-clone gate. Failed evidence is
preserved and a failed gate is repaired before later gates proceed.

## Consequences

- Mode coverage follows advertised interfaces instead of one fixed plan.
- Performance evidence is compact and highlights anomalies without turning a
  warning into a functional failure.
- The authoritative report crosses a bounded fixed-path host Interface and no
  result image extraction is required.
- Build and staging security remain deeper than the diagnostic implementation
  and are retained.
- DOS/VBE and public Direct3D coverage become part of the diagnostic while the
  private production graphics ABI stays outside its proof boundary.

## References

- [Pinned MinGW32 toolchain](../../drivers/win98/mingw32-toolchain.lock.json)
- [Pinned Open Watcom toolchain](../../drivers/win98/toolchain.lock.json)
- [Windows 98 driver source and delivery lock](0004-windows-98-driver-source-and-delivery-lock.md)
- [GSW VGA v2 and guarded 3D transport](0005-gsw-vga-v2-and-guarded-3d-transport.md)
