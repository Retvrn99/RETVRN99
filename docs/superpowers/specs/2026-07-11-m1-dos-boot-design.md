# Mate98 — M1 Design: Boot MS-DOS 7.1 to C:\>

Date: 2026-07-11
Status: Approved design, pre-implementation

## Context

Mate98 is an HLE virtual machine targeting Windows 98 / MS-DOS 7.1, games-first.
Odin + SDL3 (Vulkan) + ImGui, Windows/Linux x86_64, AVX2 required, GPLv3-only.

Project-level decisions locked during brainstorming:

- **HLE strategy: driver-boundary HLE.** The CPU runs real x86 code faithfully;
  devices are paravirtual behind custom Win98 drivers in later milestones.
  "TNT2 Ultra / YMF724 parity" means capability parity, not register parity.
- **CPU (GSW-886): hardware-assisted virtualization.** WHPX on Windows, KVM on
  Linux (later), behind one hypervisor interface. No interpreter, no dynarec.
  The GSW-886 personality is CPUID strings plus a throttle governor that keeps
  the guest in a ~PIII-1GHz performance envelope. Cycle-exactness is a non-goal.
- **Milestone ladder:** M1 DOS prompt → M2 DOS games (VESA + audio) →
  M3 Win98 boots → M4 paravirtual drivers → M5 3D. Each milestone gets its own
  spec; this document covers M1 only.

## M1 Goal

The user places MS-DOS 7.1 system files (`IO.SYS`, `MSDOS.SYS`, `COMMAND.COM`)
into `~/.mate98/c_drive/`, launches Mate98 on Windows, and reaches an
interactive `C:\>` prompt with working keyboard input, rendered in an SDL3
window. Fallback boot path: a mounted floppy image (e.g. a Win98 startup disk).

### Out of scope for M1

Audio, CD-ROM, mouse, graphics modes (mode 13h / VESA), Windows 98, throttle
precision, Linux/KVM, window resizing/scaling options, savestates.

## Architecture

Five Odin packages with one seam each. Every source file carries the SPDX
GPL-3.0-only header; comments in Spanish, sparse; tests in `*_tests.odin`.

### `host` — shell and presentation

- SDL3 window, Vulkan swapchain, ImGui.
- **Fixed-size window, no resizing.** Guest video output (VGA text: 720×400)
  is drawn at exactly 2x (1440×800), window sized to content plus menu bar.
- ImGui main menu bar:
  - **Machine**: Reset, Power Off.
  - **Media**: Mount Floppy… (file dialog), Eject Floppy.
  - **Debug**: toggle panels — vCPU state, VM-exit stats, device log.
- Renders the text grid produced by `vga` using an embedded VGA font
  (public-domain / GPL-compatible bitmap font).
- Owns the main loop: pump SDL events → feed keyboard to `machine` →
  present frame. The VM runs on its own thread.

### `hv` — hypervisor abstraction

- Interface: create VM, map the 64MB guest RAM block, create/run vCPU,
  get/set registers, inject interrupts, return typed VM exits
  (port I/O, MMIO, HLT, unhandled).
- M1 backend: WHPX only. The interface is the KVM seam for later; no KVM
  code in M1.
- Coarse throttle stub: run/sleep duty cycle, default off at the DOS prompt.
  Real governor design belongs to M3.

### `machine` — chipset and run loop

- I/O port and MMIO dispatch tables (device registration, one owner per range).
- Devices: dual 8259 PIC, 8254 PIT, CMOS/RTC, i8042 PS/2 keyboard controller,
  A20 gate, reset control.
- Run loop: vCPU exit → dispatch to device → inject pending IRQs → resume.
- Unknown port policy: reads return 0xFF, writes ignored, **only** for ports on
  an explicit logged whitelist grown deliberately; anything else freezes the VM
  (see Error handling).

### `vga` — text mode only

- Standard VGA I/O ports (CRTC, attribute, sequencer subset) plus the `B8000`
  text buffer window.
- Output: 80×25 text grid (char + attribute) and cursor position, consumed
  by `host`.
- Int 10h services come from SeaVGABIOS, not from us.

### `disk` + `fat32` — storage

- **IDE controller, PIO only.** Primary master = virtual C: drive. SeaBIOS and
  DOS both drive it without extra code from us.
- **Floppy controller** for IMG images, boot fallback.
- **FAT32 synthesizer** (the one hard component of M1):
  - The host folder `~/.mate98/c_drive/` is the source of truth.
  - MBR, FAT32 VBR, FATs, and directory entries are synthesized on demand from
    the folder tree; file-data sector reads map straight to host file reads.
  - **Clean-room VBR boot code** written by us: locates `IO.SYS` via the
    synthesized FAT and loads it per DOS 7.1 boot protocol. No Microsoft boot
    sector bytes are shipped or copied.
  - **Writes**: journaled in an overlay, decoded back into host file
    operations (create/extend/truncate/rename/delete, directory-entry and FAT
    updates that correspond to ordinary file activity).
  - **Unsupported by design**: guest-side format, defrag, scandisk surface
    scans, or FAT surgery the decoder cannot map to file operations. These
    fail loudly (host log + ImGui notice), never silently corrupt. This is a
    product decision consistent with driver-boundary HLE.
  - Host-side folder mutation while the VM runs is undefined behavior in M1
    (documented; coherence strategy deferred).

### Firmware

Stock SeaBIOS + SeaVGABIOS binaries checked into the repo with license
attribution (both GPL-compatible: LGPLv3 / GPLv3). No custom BIOS work unless
a later milestone forces it.

## Data flow

```
SDL events → host → i8042 (machine) → IRQ1 → PIC → hv interrupt injection
vCPU exit (port/MMIO) → machine dispatch → device (vga/disk/pit/...) → resume
vga text grid → host renderer → 2x quad → Vulkan present
guest sector I/O → IDE → fat32 synth ↔ ~/.mate98/c_drive
```

## Error handling

- Any unhandled VM exit, unwhitelisted port, or FAT decode failure:
  **freeze the VM**, dump vCPU registers and recent exit history to the ImGui
  debug panel and the log. Never guess, never continue silently.
- FAT32 write-decode failures additionally identify the offending sector and
  the journal state, since these are the likeliest M1 bugs.

## Testing

- `fat32`: round-trip tests — synthesize from a fixture folder, parse the
  sectors back with an independent reader, compare trees; journal-decode tests
  mapping guest write sequences to expected host file operations. This package
  gets the densest coverage.
- `machine`: register-level unit tests for PIC (masking, EOI, priority),
  PIT (mode 2/3 counters), i8042 (scancode queue), dispatch tables.
- `vga`: text buffer + cursor register tests.
- Integration smoke test: boot with scripted keystrokes, scrape the text grid
  for `C:\>`. Requires WHPX, runs on dev machines, not CI-gated in M1.

## Milestone exit criteria

1. Cold boot from synthesized C: reaches interactive `C:\>`.
2. `DIR`, `TYPE`, `COPY`, `DEL`, `MD` against the synthesized disk behave and
   are reflected as host files.
3. Floppy-image boot works (Win98 startup disk reaches `A:\>`).
4. Menu: reset, power off, floppy mount/eject function.
5. All package tests pass; unsupported-FAT-operation path demonstrably fails
   loudly, not corruptly.
