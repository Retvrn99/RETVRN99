<!-- SPDX-License-Identifier: GPL-3.0-only -->

# ADR 0012: Carry mid-frame raster changes as a scan-line journal

## Status

Accepted

## Context

Software written for VGA changes registers while the beam is drawing. Palette
splits, per-scan-line display starts for parallax, smooth panning, and border
colour bars all depend on a register write taking effect partway down the
frame. RETVRN99 does not reproduce any of it.

The reason is structural rather than an oversight. `machine_init` calls
`vga_set_deferred_scanout` with `true` unconditionally, and under that flag
`scanout_sync` invalidates the raster and returns. A scanout descriptor carries
one `Scanout_State` register snapshot plus the raw VRAM range, and the host
expands pixels from it. One snapshot per frame cannot express a change that
happens partway through the frame, so the final register state wins and every
mid-frame write is discarded.

The machinery for the alternative already exists. `scanout_capture_through_time`
renders progressively against live register state, `vga_begin_raster_change` is
already called from every VGA port write and every VRAM write with a timestamp,
and both are covered by tests. Only the consumer is switched off. Turning it
back on would be correct by construction, but it moves pixel conversion onto
the VM thread for any frame containing a mid-frame write, which is precisely
what the deferred path exists to prevent.

## Decision

Mid-frame changes travel as an ordered journal on the scanout descriptor, and
the host applies each entry as its expansion passes the recorded scan line.
Pixel conversion stays off the VM thread.

A journal entry is a typed delta, not a raw port write and not a state
snapshot. Each entry records a scan line, a kind, an index, and a value. The
whitelist is the set of effects software actually changes mid-frame: DAC
entries, the display-start pair, byte and PEL panning, attribute palette
entries, the overscan colour, and the aperture or bank select. Replay is pure
state mutation, so host presentation gains no timing, damage, bank-alias, or
interrupt side effects.

Raw port replay through `vga_io_write` was rejected because it would pull
exactly those side effects into presentation. Splitting the register write path
into pure and impure halves was rejected as a larger refactor of production
code than the problem warrants today.

The journal is bounded per frame. On overflow the frame is marked truncated and
expands exactly as it does now, from the final register state, and an
observable counter records the event. The worst case is therefore today's
behaviour rather than an image that is neither old nor correct, and the cap is
measurable instead of silent.

Border extents are published as header metadata beside the overscan colour,
derived from the display-end and blank-start registers. The host paints a
border of that proportion around the scaled canvas. The pixel buffer keeps
carrying only the active image, so frame dimensions, text snapshots, and the
accepted GSWGFX baseline stay valid. Growing the canvas to hold real border
pixels was rejected because it would invalidate the frame CRCs in that
baseline for a visual result the metadata already achieves.

Proof is a device and host replay test: real port writes at timestamps inside
one frame, an assertion that the journal holds the expected scan-line-stamped
deltas, and an assertion that host replay produces the old palette above the
split and the new one below. A guest probe that programs a split from real mode
was rejected as a gate because guest-side raster timing is fragile and a flaky
gate is worse than none.

Work lands as vertical slices by effect. Palette splits go end to end first,
then display start and panning, then border extents, with a disposable-clone
GSWGFX run before the last slice to prove frames without journal entries are
unchanged.

## Consequences

The presentation `Header` and the scanout descriptor both grow. Descriptor
memory stays bounded because the journal has a fixed cap.

Frames with no mid-frame writes produce an empty journal and expand exactly as
they do today, so the common path is unchanged and the existing baseline
remains valid.

The whitelist must grow when a new effect turns out to matter. That is a
deliberate trade for a reviewable entry set and side-effect-free replay, and
the truncation counter gives an early signal when a workload exceeds the cap.

The existing VM-side raster path stays where it is. It is not the production
mechanism, but it remains the reference the journal is checked against and
should not be deleted.

ADR 0001 continues to govern the separation of guest persona from execution
policy; this decision concerns how a frame is described, not what the guest is
told about the hardware.

## Amendments

### The display-start pair leaves the whitelist

The whitelist above named the display-start pair as something software changes
mid-frame. Building the panning slice showed that it is not. CRT Controller 0Ch
and 0Dh load into the address counter at vertical retrace, so a write partway
down the frame cannot move the frame it lands in, and RETVRN99 already models
that with a pending value and a retrace latch. Journalling the pair would have
made expansion less faithful, not more.

Mid-frame vertical movement on this hardware comes from the line-compare split,
which is a register the frame is already expanded against, not from a mid-frame
start-address write. Horizontal movement comes from Attribute Controller 13h and
CRT Controller 08h, which do take effect where they are written and are
journalled.

`raster_journal_test_display_start_write_waits_for_vertical_retrace` pins both
halves through the public CRT Controller ports and the deferred descriptor path:
the current frame does not move and the next one does.

### The internal palette needs the Palette Address Source with it

Attribute 00h-0Fh cannot be reached while the Palette Address Source bit is set,
so software changing the internal palette mid-frame must clear that bit, write,
and set it again. Clearing it blanks the display. Journalling the palette write
on its own would therefore render a clean split the hardware never produces.

The bit travels as its own delta kind alongside the palette entries. Expansion
already blanks a row whose output is disabled, so replaying the bit produces the
blank band for free with no new rendering code. A dance completed inside one
scan line leaves no visible band, which is the common case; one held open across
scan lines blanks exactly the rows it covers.

### The overscan colour waits for border extents

The whitelist named the overscan colour, but a frame publishes one border colour
resolved once, and the active image never reads Attribute 11h. A mid-frame
overscan delta has nothing to change until the frame carries border extents, so
it is deferred into that slice rather than landing as a delta that replays into
no observable difference.

### Aperture and bank select leave the whitelist

Neither half survives contact with the expansion path. The bank registers are
carried on the descriptor but no scanout or address-generation code reads them;
they map guest processor access to the aperture, not scanout reads, so a
mid-frame bank change cannot alter an expanded frame. The aperture map select
does reach expansion, but only through `display_geometry`, where it participates
in choosing the frame kind. Replaying it would resize the frame partway through
the expansion loop, which is the same hazard that kept a general register delta
kind out of the design.

Three of the seven kinds this ADR originally whitelisted therefore do not
belong. The whitelist was written before the expansion path had been read
closely, and the remaining four are DAC entries, PEL panning, byte panning, and
the internal palette with its address-source bit.
