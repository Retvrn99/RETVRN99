<!-- SPDX-License-Identifier: GPL-3.0-only -->

# GSW-Sound Windows 98 SE package contract

## Current status

This directory contains the original GPL-3.0-only source for a buildable
Windows 98 SE VxD-first playback Adapter. Its reviewed Interface inputs,
deterministic Open Watcom 1.9 plan, twin-build proof, exact output hashes, and
binary-format checks are closed. The generated `INF + DRV + VXD` package is
ready for manual guest installation.

Installation and audible runtime behavior have not yet been proven in a
Windows 98 SE guest. Consequently `gsw-sound` remains unavailable in the host
delivery plan, has no real payload inventory/manifest rows, and is not injected
by Guided Setup.

Driver revision `0.1.0.2` addressed the second loader failure found by manual
testing. The INF delegates multimedia loading to `MMDEVLDR.VXD`, so the VxD
registers its five-argument configuration callback through
`MMDEVLDR_Register_Device_Driver` and returns from that callback with the DDK's
required carry-clear convention. Revision `0.1.0.3` additionally treats the
`PNP_NEW_DEVNODE` EDX load type as advisory, as the DDK multimedia sample
permits, rather than rejecting an otherwise valid devnode before registration.
Revision `0.1.0.1` fixed the outer `PNP_NEW_DEVNODE` return but incorrectly
registered the main devnode directly with ConfigMgr; Windows therefore still
reported MMDEVLDR Code 2 and exposed no wave or mixer endpoint.

The INF and VxD also maintain a best-effort startup checkpoint under
`HKLM\Software\RETVRN99\GSW-Sound`. The matching `GSWSMOKE.EXE` prints the
checkpoint before WinMM enumeration, distinguishing loader, resource, MMIO,
allocation, transport, and IRQ failures. A clean `0.1.0.3` guest retest is still
required before any installation or playback claim is promoted.

## Device and package

The native Adapter binds the Media-class PCI device
`PCI\VEN_FFFE&DEV_0003`. It serves the same logical GSW-Sound Module that
exposes fixed SB16/OPL3 resources to DOS. PC Speaker remains a separate Module.

The manual package is valid only when all three files are present:

| File | Responsibility | Implemented source state |
|---|---|---|
| `GSWSOUND.INF` | `$CHICAGO$` Media-class PnP binding and exact DRV/VxD registration. | Binds only `PCI\VEN_FFFE&DEV_0003`; advertises wave and mixer, not WDM, MIDI, capture, or recording. |
| `GSWSOUND.DRV` | Win16 waveOut and mixer Interface. | Queued playback, supported-format validation, callbacks, loops/break-loop, pause/restart, position, reset, and Wave/Master volume controls. Native DirectSound queries fail closed. |
| `GSWSOUND.VXD` | MMDEVLDR/ConfigMgr/VPICD PCI ownership, locked cyclic-ring management, protected-mode calls, cursor, interrupt acknowledgement, and startup telemetry. | Registers through the multimedia devloader, uses allocated PnP resources and a shareable level-triggered IRQ path, and validates MMIO identity, guest buffers, and transport state before access. |

The Adapter is playback-only. It supports unsigned 8-bit and signed 16-bit
little-endian mono/stereo PCM at 11,025, 22,050, 44,100, and 48,000 Hz. It
advertises no capture, Windows MIDI/FM, hardware secondary mixing,
DirectSound3D, EAX, or recording. DirectSound secondary buffers remain a future
software-mixing/driver acceptance slice.

## Deterministic build

The build uses only original GSW source plus the compatible, reviewed inputs
in `interface-inputs.lock.json`. Run the wrapper with the pinned source and
toolchain roots and a previously absent output directory:

```powershell
pwsh scripts/build-win98-gsw-sound.ps1 `
  -SourceRoot <win98-source-root> `
  -ToolchainRoot <win98-toolchain-root> `
  -OutputRoot <absent-output-directory>
```

`gsw-sound-build-plan.json` locks the complete build and these outputs:

| File | Bytes | SHA-256 |
|---|---:|---|
| `GSWSOUND.INF` | 1,370 | `7f79a999e8200dde6d1d3aac0e31c4163c58f38b39b57249d4122529626fec53` |
| `GSWSOUND.DRV` | 12,104 | `b2fe52450982cf35129b474bfa84bacda2feecd4179e2d00f4fde8f07aa8bd7d` |
| `GSWSOUND.VXD` | 9,476 | `410bbaea37876d0c1edc9734f03c16c948ab51b8eeb866cd698ec682a644fb51` |

The wrapper verifies pinned provenance, builds twice in separate private
trees, normalizes the bounded Win16 VERSIONINFO date and the VxD's ordinal-1
shared-data entry flag, compares complete bytes, verifies NE/LE format and
exports with pinned `wdump`, and publishes exactly the three files above.
The binary boundary also proves that the VxD contains the MMDEVLDR registration
service call and no longer contains the obsolete direct ConfigMgr registration
call.

## Installation and DOS configuration

Manual installation into a licensed Windows 98 SE guest is the current gate.
Point Device Manager's Have Disk flow at the generated directory, then exercise
the Wave and Master controls and all supported waveOut formats. Use the matching
telemetry-aware `GSWSMOKE.EXE` and preserve `GSWSOUND.LOG` on any failure. Guided Setup
injection remains disabled until binding, playback, reset, reinstall, and
guest-pause behavior pass.

Only after those gates may installation idempotently establish
`BLASTER=A220 I5 D1 H5 T6` for standalone DOS and Restart in MS-DOS mode.

See [ADR 0008](../../../docs/adr/0008-gsw-sound-vxd-first-audio-architecture.md)
for the PCI/timing Interfaces and the
[build and delivery plan](draft-build-delivery-plan.md) for the remaining
promotion gates.
