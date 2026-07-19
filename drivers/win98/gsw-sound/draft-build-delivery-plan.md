<!-- SPDX-License-Identifier: GPL-3.0-only -->

# GSW-Sound build and delivery plan

## Status

The original source, reviewed Interface closure, deterministic build, and
three-file native package are complete. Guest installation and runtime proof
did not complete, and the normal guest persona now hides the native PCI
function under ADR 0009. Therefore `gsw-sound` must still return
`Package_Content_Unavailable`; the real payload inventory and manifest remain
unchanged.

This distinction is deliberate: reproducible driver binaries are retained as
developer evidence, but the native manual-install gate is paused and they are
not a proven or automatically delivered driver release.

## Closed source and build gates

- `interface-inputs.lock.json` pins the clean MIT-licensed `vmdisp9x` checkout
  at commit `718b3d51a1532fe1ba2e133cf76186f1a609d35e`, including the exact VMM,
  VPICD, ConfigMgr, and `fixlink` inputs. The minimal Win16 multimedia
  declarations are original GSW source reviewed against the hash-locked
  public-domain MinGW Interface reference. The MMDEVLDR device/service IDs,
  register ABI, and callback convention are reviewed against three hash-pinned
  Windows 95/98 DDK reference files; none of those files or any Microsoft DDK
  binary, library, or implementation is copied into the build.
- `gsw-sound-build-plan.json` locks all 26 build inputs, all provenance and
  verification scripts, and the complete expected outputs.
- `scripts/build-win98-gsw-sound.ps1` verifies both full toolchain trees and the
  Interface checkout, materializes only planned inputs into two private build
  trees, performs two warning-free Open Watcom 1.9 builds, normalizes the
  Win16 VERSIONINFO date and the VxD's ordinal-1 shared-data entry flag,
  compares complete bytes, and publishes to a previously absent output
  directory.
- The output directory contains exactly these files:

| File | Bytes | SHA-256 |
|---|---:|---|
| `GSWSOUND.INF` | 1,370 | `7f79a999e8200dde6d1d3aac0e31c4163c58f38b39b57249d4122529626fec53` |
| `GSWSOUND.DRV` | 12,104 | `b2fe52450982cf35129b474bfa84bacda2feecd4179e2d00f4fde8f07aa8bd7d` |
| `GSWSOUND.VXD` | 9,476 | `410bbaea37876d0c1edc9734f03c16c948ab51b8eeb866cd698ec682a644fb51` |

Pinned `wdump` verification proves that the DRV is an MZ/NE Windows 4.0
SINGLEDATA module exporting `WEP`, `DriverProc`, `wodMessage`, and `mxdMessage`
at ordinals 1 through 4. The VxD is an MZ/LE Win386 module exporting
`GSWSOUND_DDB` at ordinal 1 with the `EXPORTED | SHARED DATA` entry contract.
The VxD check additionally requires the MMDEVLDR registration service encoding
and rejects the former direct ConfigMgr registration encoding.

Revision `0.1.0.1` repaired the outer `PNP_NEW_DEVNODE` return ABI observed in
the first manual guest install, but the second guest test still produced
MMDEVLDR Code 2 and zero GSW-Sound WinMM endpoints. Revision `0.1.0.2`
addresses the loader ownership error: the main multimedia devnode is registered
through `MMDEVLDR_Register_Device_Driver`, using its cdecl callback and
carry-clear return contract, rather than directly through ConfigMgr. It also
seeds persistent start telemetry and the VxD advances it through PnP,
registration, resource, MMIO, allocation, bind, IRQ, and success checkpoints.
Revision `0.1.0.3` additionally matches both the DDK sample and Creative's
ES1371 VxD by recording but not rejecting the advisory `PNP_NEW_DEVNODE` EDX
load type. The replacement package still requires a fresh binding/runtime gate
if a later decision re-enables the native PCI function.

## Deferred native Windows 98 SE gate

If native PCI exposure is explicitly restored in a later slice, install from
the generated directory in a licensed Windows 98 SE guest and verify:

1. `PCI\VEN_FFFE&DEV_0003` binds without a warning.
2. The telemetry-aware `GSWSMOKE.EXE` reports `checkpoint=success` before
   enumeration, and Control Panel exposes GSW-Sound Wave and Master controls.
3. waveOut playback passes every advertised 8/16-bit, mono/stereo, and
   11,025/22,050/44,100/48,000 Hz combination, plus looping, break-loop,
   pause/restart, position, reset, and callbacks.
4. Stop/restart, cursor wrap, guest pause, reinstall, and emulator restart do
   not produce a catch-up burst or steady-state underrun.

Native DirectSound discovery intentionally remains fail closed in this slice;
it must not be advertised as proven by a waveOut test.

The active manual gate instead creates a separate legacy Creative SB16 device
using the Windows inbox driver. Its Resources page must show I/O `220h` and
`388h`, IRQ5, DMA1, and DMA5, with no memory range. That gate does not use this
three-file package.

## Delivery promotion still blocked

Only after the manual guest gate passes may a later change add the exact three
inventory/manifest rows, prove tamper and omission failures, and enable
deterministic `CUSTOM.INF` injection. `BLASTER=A220 I5 D1 H5 T6` configuration
for standalone DOS and Restart in MS-DOS mode remains behind its own guest
acceptance gate.

No gate permits a host restart or reboot. Guest resets/reboots and emulator
restarts are sufficient for Windows 98 acceptance.
