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
and contains a self-describing raw update rather than expanded host pixels.
Dirty descriptors declare their bounded valid source ranges; bytes outside those
ranges are not snapshot state. Video presentation retains the identity-checked
expanded baseline needed to apply them. The host Adapter
owns SDL resources. SDL creation, upload, and destruction occur only on the
main thread and never while the Video-presentation mutex is held.

`Video_Presentation` contains the two mailbox slots, lifecycle generation,
acknowledgements, committed identities, selector policy, expansion baseline,
telemetry, postmortem record, and Host presentation state. `Shared` contains
one `Video_Presentation`; GUI and VM callers use lifecycle, publication,
consumption, and value-snapshot operations without inspecting that state. The
Host Adapter stages uploads before the Module lock, performs only the
non-blocking activation swap during the current-generation commit, and retires
or destroys rejected resources after the lock is released. Host-only tests may
use the embedded fallback presentation state when no external Module state is
bound.

GSW-Sound owns legacy SB16/OPL3 and native PCM policy behind one time-ordered
Interface. Machine supplies guest-memory, DMA, interrupt, and final-mix
Adapters. PC Speaker and CDDA remain separate until final mixing. The native
PCI function remains hidden by default.

`Gsw_Sound` contains the private SB16, CT1745, OPL3, and native PCM state. It
selects DMA and IRQ resources, decides whether a DMA block can complete,
calculates exact block deadlines, orders DREQ transitions, owns mixer gains and
source activity, and publishes or releases completed frames. Its Adapters
provide value-only DMA snapshots, DMA transfers, DREQ changes, IRQ operations,
bounded guest-memory access, and completed-frame delivery. Machine may consume
only a value-copy `Gsw_Sound_Observation` for diagnostics and final mixing; it
does not inspect or mutate the device state. Native PCI decode and transport
transitions use the same Interface and do not change the default-hidden
capability decision.

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
