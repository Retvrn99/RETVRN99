<!-- SPDX-License-Identifier: GPL-3.0-only -->

# ADR 0013: Concentrate runtime policy in deep domain Modules

## Status

Accepted

## Context

Several runtime concepts have value types or partial Modules but still require
callers to coordinate their state and failure ordering. Video presentation is
split among the frame mailbox, the graphics frame consumer, host presentation,
and VGA expansion. GSW-Sound owns the guest audio devices while Machine still
selects their DMA, interrupt, mixing, and observation policy. GUI and console
VM lifetimes duplicate boot and reset ordering. PC/AT storage is embedded in
Machine while its fixed port map and advancement policy remain there. ATAPI
owns both guest protocol and concrete optical backing.

Those seams are shallow. Deleting any one of them redistributes the same
ordering and error handling across its callers, so tests must understand the
Implementation rather than exercise one durable Interface.

## Decision

RETVRN99 deepens five domain Modules in dependency order.

Video presentation is the sole owner of descriptor admission, ordering,
expansion, staging transactions, selection, commit, retirement,
acknowledgement, retry, lifecycle invalidation, telemetry, postmortem state,
and last-good restoration. A Scanout descriptor is immutable after publication
and contains raw source state rather than expanded host pixels. The host Adapter
owns SDL resources. SDL creation, upload, and destruction occur only on the
main thread and never while the Video-presentation mutex is held.

GSW-Sound owns legacy SB16/OPL3 and native PCM policy behind one time-ordered
Interface. Machine supplies guest-memory, DMA, interrupt, and final-mix
Adapters. PC Speaker and CDDA remain separate until final mixing. The native
PCI function remains hidden by default.

VM lifetime owns one Machine, its image-service Machine session, VM guard, host
audio, retained CMOS and hardware trace, mounted media, and install boot
mutation. GUI and console use the same Interface. Profile locking stays outside
because it governs the process-wide Profile.

The PC/AT platform owns the legacy motherboard devices, fixed port map, reset,
power, A20 latch state, passive probes, and platform-device advancement.
Machine retains the global scheduler and non-platform devices. Port `80h` has
one composed handler: every access applies ISA delay and POST-code behavior,
and writes also feed shutdown-marker diagnostics.

Optical media owns concrete image and Host-optical-drive backing. ATAPI owns
only guest packet protocol, register state, transfer timing, sense presentation,
and CDDA cadence. The Host optical drive Adapter rejects every non-whitelisted
or data-out command before calling the operating system.

Each Module exposes one narrow Interface. Production and in-memory test
Adapters make each external seam real. Tests assert observable ordering and
outcomes through those Interfaces rather than retaining tests of replaced
shallow orchestration.

## Consequences

The work lands as independently green steps. Characterization tests precede
each ownership move, and every step preserves the public Guest persona and
guest-visible timing unless another ADR explicitly changes them.

Source, build, guest-runtime, audible, and physical-device evidence remain
distinct. No refactor enables a hidden capability, advertises private 3D,
activates native GSW-Sound, or weakens a fail-closed gate.

The Modules may contain internal seams for deterministic tests, but callers do
not receive low-level device state merely to make tests convenient. The public
Interface is the test surface.
