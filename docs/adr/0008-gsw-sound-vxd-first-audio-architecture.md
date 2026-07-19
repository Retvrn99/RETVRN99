<!-- SPDX-License-Identifier: GPL-3.0-only -->

# ADR 0008: VxD-first GSW-Sound architecture

## Status

Accepted for the shared audio Module, timing model, native PCM ABI, and
VxD-first Adapter design. [ADR 0009](0009-default-windows-98-sound-path.md)
supersedes default exposure of the native PCI function and makes a separately
installed inbox legacy SB16 driver the next Windows 98 acceptance path.

## Context

RETVRN99 exposes fixed Sound Blaster 16 and OPL3-compatible DOS resources, but
their presence is not yet proof of correct audible output. Audio sample clocks
and PC-speaker transitions currently create timing and work-amplification
risks. The existing OPL3 synthesis Implementation is worth preserving while
its machine scheduling is replaced.

Windows 98 SE also needs a native playback path that does not make modern
games traverse the legacy DSP and ISA DMA Interface. The repository reserves
`PCI\VEN_FFFE&DEV_0003` for `gsw-sound`. At this decision point, an original
guest-source bootstrap defined the complete three-file package but did not yet
have reviewed DDK Interface closure, linked binaries, reproducible build,
payload inventory, or runtime proof. The source/build gates later closed, but
guest binding did not; ADR 0009 records the resulting default-off pivot.
Earlier fixtures named only an INF and VxD even though a Windows 9x wave driver
needs a complete VxD-first package.

## Decision

### Modules and timing

One deep GSW-Sound Module owns legacy SB16/OPL3 behavior and native PCM
playback behind one time-ordered Interface. Two Adapters sit at that Seam:

- the legacy Adapter exposes Sound Blaster-compatible I/O at `220h`, IRQ5,
  DMA1 and DMA5, with OPL3 at `388h` and the Sound Blaster FM aliases;
- the native Adapter exposes the GSW-Sound PCI PCM Interface to Windows 98 SE.

PC Speaker remains a separate Module. It consumes PIT channel-2 transitions
and joins GSW-Sound and CDDA only at the final audio-mixing Interface.

At guest-visible tick `T`, the machine advances PIT through `T`, delivers
ordered channel-2 transitions and IRQ0, advances PC Speaker and GSW-Sound,
publishes completed audio and interrupts, and only then performs the guest I/O
operation. The external scheduler uses a 1 ms render quantum plus exact
guest-observable deadlines. Ordinary speaker edges, OPL samples, and SB16 PCM
samples are internal Implementation details and do not create hypervisor
wakeups. Pausing freezes VM-active audio time without a catch-up burst.

OPL3 retains the existing operators, envelopes, waveforms, stereo, rhythm, and
four-operator synthesis. A rational phase accumulator drives its native
49,716 Hz clock, while exact timer overflows remain externally observable.
The shared output Module mixes deterministically at 48 kHz stereo with 64-bit
accumulation, explicit source gains, headroom, and one final saturation step.

### Native PCI Interface

When explicitly exposed for developer coverage, GSW-Sound is PCI function
`00:03.0`, vendor/device `FFFE:0003`, revision 1, class/subclass `04/01`, with
one 4 KiB MMIO BAR and level-triggered INTA. The normal guest persona now hides
this function under ADR 0009 while retaining the ABI and focused tests.
Shared PCI interrupt routing must count assertions by source so IDE and sound
cannot clear each other's routed interrupt.

ABI v1 uses 32-bit little-endian registers at four-byte intervals: `GSW1`
identity `00h`, version `04h`, capabilities `08h`, status `0Ch`, control `10h`,
sample rate `14h`, PCM format `18h`, ring GPA low/high `1Ch`/`20h`, ring bytes
`24h`, device head `28h`, committed tail `2Ch`, period bytes `30h`, IRQ enable
`34h`, write-one-to-clear IRQ status `38h`, and played-byte position low/high
`3Ch`/`40h`. ABI v1 also implements read-only underrun count `44h`, invalid-
access count `48h`, available bytes `4Ch`, and Q16.16 master gain `50h` as
bounded diagnostic/control extensions. It accepts unsigned 8-bit or signed
16-bit little-endian mono/stereo PCM at 11,025, 22,050, 44,100, or 48,000 Hz.

The ring is contiguous guest memory, has a 16-byte-aligned guest-physical base,
is 4 KiB through 256 KiB, frame-aligned and power-of-two sized, and has at least
two periods. The driver default is a
256-frame period and a ring of at least four periods, rounded up to the 4 KiB
ABI minimum; low-byte-width formats therefore contain more than four periods.
Invalid formats, sizes, alignment, wrap arithmetic, or
guest addresses set `BAD_CONFIG` before guest memory is read. Period and
underrun interrupts are distinct. Reset clears cursors and status and ramps
the output to silence. Guest memory is consumed only on the machine thread;
the host audio callback drains completed PCM and never parses guest memory.

### Windows 98 SE Adapter and package

The first native guest Adapter is VxD-based and playback-only. Its complete
package shape is:

- `GSWSOUND.INF`: `$CHICAGO$` Media-class PnP installation for
  `PCI\VEN_FFFE&DEV_0003`;
- `GSWSOUND.DRV`: Win16 waveOut/mixer behavior and DirectSound discovery;
- `GSWSOUND.VXD`: PCI resources, locked cyclic-buffer management, play cursor,
  period completion, and interrupt handling.

The VxD model is selected for RETVRN99's games-first target because Windows 9x
DirectSound can work close to the primary DMA buffer and primary format. The
WDM path normally adds KMixer unless a driver provides hardware buffers. This
decision accepts the VxD model's tighter waveOut/DirectSound sharing constraints
and keeps both paths behind the same driver Interface.

DirectSound may use the hardware primary buffer; secondary buffers remain
software mixed by the Windows runtime. The Adapter does not advertise capture,
Windows MIDI/FM, hardware secondary mixing, DirectSound3D, EAX, or recording.
A future WDM Adapter may use the same PCI Interface, but it is not part of this
decision or the first package.

The checked-in source is a bootstrap toward that Adapter, not proof that these
targets are implemented. It currently provides single-open waveOut transport
through a 1 ms polling pump and minimal mixer discovery. It explicitly rejects
native DirectSound queries and wave loops, and its VxD glue has not closed a
reviewed PnP-resource or interrupt-hook path. Those paths must remain
unadvertised until the corresponding source, binary, and guest gates pass.

The guest driver must be original RETVRN99 work. Open Watcom 1.9 and every
required DDK Interface input must be hash-locked before a ready build exists.
The DRV and VxD may receive only reviewed, bounded normalization of proven
nondeterministic metadata. Two clean absent-root builds must produce identical
bytes before exact sizes and hashes can enter the payload manifest.

### Proof and delivery

Documentation claims are fail-closed and independently gated for legacy DOS,
PC Speaker, OPL3, native PCI playback, driver installation, and game behavior.
The real payload inventory remains unchanged until all three package files
exist with reviewed provenance and exact hashes. A stageable package still
does not prove Windows operation.

Proof records source-indexed produced and nonzero frames, starvation, clipping,
speaker edges, late or overflowed transitions, IRQs, scheduler wakeups, and
deterministic capture hashes. Simultaneous OPL3 and 48 kHz SB16 playback must
remain at one render wake per millisecond plus exact observable events. PC
Speaker tone tests, an OPL3 register-log corpus, cold-DOS and real-DOS-mode
probes, and native Windows playback are separate gates.

Manual installation and licensed Windows 98 SE runtime acceptance precede
Guided Setup injection. Only after those gates pass may installation
idempotently configure `BLASTER=A220 I5 D1 H5 T6` for standalone DOS and
Restart in MS-DOS mode. Host shutdown or reboot is never part of acceptance.

## Consequences

- One time-ordered Interface concentrates audio correctness and scheduler work,
  improving Locality without changing the OPL3 synthesis character.
- DOS software retains fixed legacy resources. Native Windows playback may
  later avoid legacy DSP and ISA DMA overhead, but its PCI Adapter is not
  exposed in the normal guest persona while the inbox legacy path is tested.
- The PCI Interface is independent of the VxD Adapter, leaving a real Seam for
  a later WDM Adapter without expanding ABI v1.
- `gsw-sound` remains unavailable. Later work closed the reviewed source and
  deterministic build gates, but not inventory, default hardware exposure,
  installation, or runtime proof.
- The inbox Creative SB16 driver must bind to a separately added legacy device,
  never to the reserved PCI identity; ADR 0009 defines that manual gate.
- Recording, Windows MIDI/FM, MPU-401, CSP, DirectSound3D, EAX, and hardware
  secondary buffers remain outside the initial implementation.

## References

- [Separate guest persona from execution policy](0001-guest-persona-and-execution-policy.md)
- [Windows 98 Setup driver bundles](0003-windows-98-setup-driver-bundles.md)
- [Windows 98 driver source and delivery lock](0004-windows-98-driver-source-and-delivery-lock.md)
- [GSW-Sound package contract](../../drivers/win98/gsw-sound/README.md)
- [GSW-Sound draft build and delivery plan](../../drivers/win98/gsw-sound/draft-build-delivery-plan.md)
- [Default Windows 98 sound path](0009-default-windows-98-sound-path.md)
- [Microsoft DirectSound driver models](https://learn.microsoft.com/en-us/previous-versions/windows/desktop/bb318679%28v%3Dvs.85%29)
