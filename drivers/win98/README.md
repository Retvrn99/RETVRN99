<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Windows 98 driver build and packaging

This directory contains the pinned source, toolchain, derivation, build, and
staging metadata for the GSW-VGA Windows 98 display package. Compiled payloads
remain external to Git and are produced only into a previously absent output
root.

## Immutable inputs

`upstream.lock.tsv` pins VMDisp9x and VMHAL9x, including their initialized
gitlinks, by exact origin and commit. The verifier performs no clone or fetch:

```powershell
.\scripts\verify-win98-driver-sources.ps1 -SourceRoot D:\src\retvrn99-win98
```

`toolchain.lock.json` pins the complete Open Watcom 1.9 archive and extraction.
`mingw32-toolchain.lock.json` pins the complete MinGW32 GCC 15.2.0 extraction.
Both locks cover every extracted file with the canonical tree digest, and each
build step selects its exact executable and environment from one lock.

```powershell
.\scripts\verify-win98-driver-toolchain.ps1 `
    -ToolchainRoot D:\src\retvrn99-win98\toolchains `
    -LockFile .\drivers\win98\toolchain.lock.json

.\scripts\verify-win98-driver-toolchain.ps1 `
    -ToolchainRoot D:\src\retvrn99-win98\toolchains `
    -LockFile .\drivers\win98\mingw32-toolchain.lock.json
```

The repository forces LF working-tree bytes for every raw-hashed JSON, TSV,
patch, overlay, and shared ABI input. The EOL regression creates fresh local
checkouts with `core.autocrlf=true` and `false`, compares the complete raw hash
closure, and runs ready derivation and build verification in both.

## Derived sources and build

`derived-source-plan.json` contains ready recipes for `vmdisp9x-gsw` and
`vmhal9x-gsw`. Each recipe names one immutable upstream, ordered patches pinned
by size and SHA-256, complete overlays pinned by tree digest, and the exact
combined output-tree descriptor. Preparation uses exact tracked Git blob
bytes, rejects dirty or mismatched sources and unsafe paths, and publishes only
after two matching scans.

`build-plan.json` schema 3 links the source plan, upstream lock, and both
toolchain locks by SHA-256. It runs the pinned tools with literal arguments,
restores inherited mixed-case environment variables, normalizes only the
Win16 version-date fields declared for `gswmini.drv`, validates every output,
and atomically publishes the completed two-recipe build.

```powershell
.\scripts\build-win98-driver-sources.ps1 `
    -SourceRoot D:\src\retvrn99-win98 `
    -ToolchainRoot D:\src\retvrn99-win98\toolchains `
    -OutputRoot D:\src\retvrn99-win98\proof\gsw-vga-a
```

The final package payloads are:

| Artifact | Bytes | SHA-256 |
|---|---:|---|
| `gswmini.drv` | 16,922 | `9748b9feeebfaa4b4597f63a17fd8699ddfa01bce1aba6fc8ecc8ec7542fb13d` |
| `gswmini.vxd` | 39,277 | `1bc520b7552c926ac62186efd70193352e54a74d47a8d02937fd8eac31986f3b` |
| `gswmini.inf` | 3,188 | `952c2a18697a363944879b64031872266505d34ac50fca7080663bfa54783dea` |
| `gswhal9x.dll` | 46,592 | `8668d85be8d2fc8b3d32253aa7e04c9104a2713494f9b309c2d4404f1ae12b38` |
| `gswdd32.dll` | 32,256 | `bfb72b4641e8e45e5ec90eb5c30e44aa4fac64fc37164c3429f428717d3964b4` |

The DLL identity is GSW-specific. `gswhal9x.dll` is the DirectDraw HAL and
`gswdd32.dll` is its narrow VxD bridge. The build does not produce or advertise
an OpenGL ICD, Direct3D driver, Mesa component, VESA helper, or tray utility.
The mini-VDD contains the capability-gated GSW3D guest transport, but it exposes
no usable 3D path unless the host explicitly advertises the guarded proof
backend.

GSW-VGA 0.2.0.5 also provides capability-gated screen and offscreen VRAM GDI
`BitBlt` acceleration for packed 8-, 16-, 24-, and 32-bit modes. Its private
pointer-free command supports all 256 ROP3 truth tables with solid or opaque
native-color 8x8 brushes. Unsupported surfaces, brushes, formats, and failed
submissions immediately return to the DIB Engine for that operation.
The synchronous GDI hot path uses a separately negotiated shared-memory
completion cookie, reducing successful submissions to one MMIO doorbell while
retaining the two-exit and generic fenced paths for older hosts.

Version 0.2.0.5 revalidates PCI BARs and decode state across ConfigMgr
re-enumeration, updates the existing Win16 framebuffer selector after a BAR
move, reconnects a resident Win16 driver to a dynamically reloaded mini-VDD,
and balances VDD mode-change notifications on every restore outcome. While
Windows owns high-resolution mode, the mini-VDD rejects BIOS standard and VBE
mode-set probes and swallows direct Bochs VBE register access. Mode 13h remains
available for fullscreen Win32 software renderers, and explicit VDD transitions
release the guard. The required V86 hook has checked installation and removal,
and a failed unhook rejects dynamic unload.

## GSW-Sound deferred native package

GSW-Sound is a separate, unavailable PnP package reserved for
`PCI\VEN_FFFE&DEV_0003`. Its VxD-first contract requires the complete
`GSWSOUND.INF`, `GSWSOUND.DRV`, and `GSWSOUND.VXD` set. This repository does
contain original source, reviewed hash-locked compatible Interface inputs, an
executable deterministic twin-build plan, exact linked-output hashes, mixer and
wave-loop support, and a ConfigMgr/VPICD interrupt path. The exact three-file
package is reproducible, but guest install/runtime proof failed and payload
inventory/manifest rows do not exist. The default machine now hides the native
PCI function under ADR 0009, so this package is a retained developer artifact,
not the active manual-test path. Native DirectSound discovery remains fail
closed.

The current manual Windows gate adds the inbox Creative SB16 driver as a
separate legacy device using I/O `220h` and `388h`, IRQ5, DMA1, and DMA5. Never
force that driver onto `FFFE:0003`; IRQ10 plus a 4 KiB memory range identifies
the wrong PCI devnode.

The [package contract](gsw-sound/README.md) records the implemented surface.
The [build and delivery plan](gsw-sound/draft-build-delivery-plan.md) records
the closed deterministic-build proof and remaining guest gates.
Neither document changes `payload_available`, the reviewed inventory, or
Guided Setup.

## Stageable package

`payload-inventory.schema.tsv` is the reviewed five-file destination set and
`payload-manifest.schema.tsv` binds each build output to its exact size and
hash. Staging requires the one INF and all four binaries, verifies both source
provenances again, rejects path and Windows 9x short-name collisions, copies
into private scratch, rehashes every copy, and publishes only the complete
package.

```powershell
.\scripts\invoke-win98-gsw-vga-pipeline.ps1 `
    -SourceRoot D:\src\retvrn99-win98 `
    -ToolchainRoot D:\src\retvrn99-win98\toolchains `
    -BuildOutputRoot D:\src\retvrn99-win98\build\gsw-vga `
    -StageOutputRoot D:\src\retvrn99-win98\stage\gsw-vga `
    -PayloadManifest .\drivers\win98\payload-manifest.schema.tsv
```

The INF copies the DRV, mini-VDD, HAL, and bridge into the Windows system
directory. DirectDraw is advertised by this exact GSW build only. The HAL and
VxD validate their ABI and framebuffer identity and fail closed on mismatch;
unsupported DirectDraw operations return to the runtime software path.

## Proof boundaries

- Deterministic build proof means two clean absent roots produced identical
  declared bytes from the locked inputs.
- Stageable package means the complete five-file PnP shape passed inventory,
  provenance, size, hash, and atomic-staging checks.
- Windows 98 runtime proof requires a licensed local guest fixture with the
  needed DirectX runtime. A successful build or stage is not runtime proof.

Guided Setup integration remains a separate acceptance boundary: the staged
package is not silently injected into user media, and the user's installation
media is never modified or redistributed.

## GSW3D guest smoke

The standalone Windows 98 proof client has a separate locked build closure and
does not change the five-file VGA package:

```powershell
.\scripts\invoke-win98-gsw3d-smoke-pipeline.ps1 `
    -SourceRoot D:\src\retvrn99-win98 `
    -ToolchainRoot D:\src\retvrn99-win98\toolchains `
    -OutputRoot D:\src\retvrn99-win98\proof\gsw3d-smoke
```

Run `gsw3d-smoke.exe` only inside a licensed Windows 98 guest with the GSW-VGA
driver active and the host started with the guarded proof backend. A passing
run writes `GSW3D_SMOKE PASS` to the console and `GSW3D.LOG`. Normal production
hosts return `GSW3D_SMOKE UNAVAILABLE`; the tool is not an OpenGL or Mesa
capability claim.
