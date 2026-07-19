<!-- SPDX-License-Identifier: GPL-3.0-only -->

# ADR 0009: Default Windows 98 sound path uses legacy SB16

## Status

Accepted. This supersedes ADR 0008 only where it made the native GSW-Sound
PCI function the default Windows 98 path. The shared audio Module, timing
model, native PCM ABI, and VxD-first design remain retained work.

## Context

The original `GSWSOUND.INF + DRV + VXD` package reached deterministic linked
builds, but repeated Windows 98 SE tests did not produce a working multimedia
device. A later experiment selected the inbox Creative SB16 driver through
**Update Driver** on that same device node. Device Manager then displayed a
Creative model name, but its Resources page still contained IRQ10 and the
4 KiB `FE001000-FE001FFF` PCI MMIO window assigned to `FFFE:0003`.

That was not a legacy Sound Blaster installation. Updating a PCI node's driver
does not transform its bus resources into ISA I/O, IRQ, and DMA resources. The
inbox SB16 driver therefore could not find a DSP at `220h` and reported Code
24. Keeping the unproven PCI function visible also makes the same mistaken
binding easy to repeat.

RETVRN99 already exposes the legacy hardware independently of the PCI
Adapter. Its DSP and mixer use `220h-22Fh`, OPL3 uses `388h-38Bh` and the Sound
Blaster FM aliases, and the fixed interrupt and DMA resources are IRQ5, DMA1,
and DMA5.

## Decision

The normal guest persona does not enumerate `PCI\VEN_FFFE&DEV_0003`.
Configuration reads for `00:03.0` return the absent-device value, and its MMIO
and bus-master decoders remain disabled. Production machine initialization
uses this default-off profile.

The native PCM implementation and the reserved `FFFE:0003` identity are not
deleted. Focused host tests explicitly expose the function to retain identity,
BAR, malformed-access, cyclic-buffer, interrupt, and shared-PIRQ coverage. The
firmware's reserved slot-3 `$PIR` entry may remain because it describes a
possible route and does not enumerate a PCI function.

The next Windows 98 SE acceptance path is the inbox Creative SB16 driver bound
to a separately added legacy device. It must never be installed by updating a
PCI device node. The manual gate is:

1. Remove the stale Code-24 Creative-named PCI node and reboot the guest.
2. Confirm that no PCI multimedia device reappears.
3. Use **Add New Hardware**, manually select the sound-device class, Creative,
   and **Sound Blaster 16 or AWE-32 or compatible**.
4. Select a resource configuration containing I/O `220h-22Fh` and
   `388h-38Bh`, IRQ5, DMA1, and DMA5, with no memory range.
5. Prefer the no-MPU configuration because GSW-Sound v1 does not implement
   MPU-401. A reserved `330h-331h` range is not evidence of a working MIDI
   endpoint.

This is a manual binding gate, not an automatic Plug and Play claim. A later
slice may complete the machine's ISA PnP card model and expose a compatible
logical-device ID. Until then, Device Manager presence, Wave playback, OPL/FM,
DOS mode, IRQ/DMA behavior, and audible game behavior remain separate proof
gates.

The reproducible native VxD package remains a deferred developer artifact.
It is not injected, is not available in the payload inventory, and cannot be
promoted while its PCI function is hidden in the normal persona. Re-enabling
native PCI delivery requires a later decision and fresh licensed-guest proof;
the emulator-side ABI does not need to change.

## Consequences

- Windows can no longer bind an inbox ISA SB16 driver to the GSW-Sound PCI BAR
  in the default machine.
- DOS and Windows real-DOS-mode software retain the same fixed SB16/OPL3
  hardware path.
- The manual Windows driver test now exercises the legacy implementation the
  driver expects, but still depends on the user creating the legacy device.
- The native PCI/VxD work stays covered without being confused with working
  guest delivery.
- Automatic inbox-driver discovery and MPU-401 remain deferred.

## References

- [VxD-first GSW-Sound architecture](0008-gsw-sound-vxd-first-audio-architecture.md)
- [Windows 98 driver source and delivery lock](0004-windows-98-driver-source-and-delivery-lock.md)
- [GSW-Sound package contract](../../drivers/win98/gsw-sound/README.md)
