<!-- SPDX-License-Identifier: GPL-3.0-only -->

# ADR 0006: GSW3D Windows 98 guest transport boundary

## Status

Accepted

## Context

The guarded host GSW3D queue has an opt-in exact-triangle renderer proof, but
the Windows 98 display VxD previously had no matching guest transport. Mesa9x's
accelerated path expects contexts, registered memory, command submission,
resource uploads, presentation, and fences. Advertising an OpenGL ICD before
those contracts and the general renderer exist would make a developer proof
look like a production graphics capability.

## Decision

The GSW mini-VDD owns a separate page-allocated 4 KiB GSW3D ring and a
physically contiguous 64 KiB staging region. A GPLv3-only shared C header fixes
the register, command, DIOC, and result layouts. Descriptors contain only fixed
width identifiers, guest-physical region addresses, sizes, and offsets; they
never contain ring-3 pointers. DIOC payload bytes are copied into staging only
after the caller's pages and permissions have been checked and locked.

Initialization requires the host to advertise SVGA9, direct present, and
resource upload together. Normal production runs therefore leave the guest 3D
transport unavailable. Context IDs are tracked in a bounded table. Batch and
upload sizes are capped by staging capacity, presents validate all rectangle
arithmetic and interval bits, and fence polling returns a snapshot rather than
blocking the VxD.

This change does not enable the display driver's OpenGL escape, register an
ICD, add Mesa to the five-file VGA package, or claim general Direct3D support.
The existing package shape remains unchanged; only the reviewed `gswmini.vxd`
bytes change.

Mesa remains a separate future build and component package. Its reproducible
closure must independently pin the source generators needed by Mesa9x,
including Python, Mako, Flex, and Bison, and must not make the VGA build depend
on that toolchain. A production accelerated ICD additionally requires a host
renderer wider than the exact-triangle proof profile.

## Consequences

- Guest and host now share a versioned, pointer-free 3D transport boundary.
- The transport fails closed in normal runs and cannot make OpenGL discoverable.
- The locked VGA source and binary closure includes the new VxD implementation
  while retaining the same five staged files.
- Mesa source generation, ICD registration, general rendering, and licensed
  Windows 98 runtime acceptance remain explicit later gates.

## References

- [Guarded host transport](../../src/vga/gsw3d.odin)
- [GSW3D shared ABI](../../drivers/win98/derived/shared/gsw3d_abi.h)
- [Guest transport](../../drivers/win98/derived/vmdisp9x-gsw/overlay/gsw3d_transport.c)
- [Guest DIOC boundary](../../drivers/win98/derived/vmdisp9x-gsw/overlay/gsw3d_ioctl.c)
- [Guarded 3D architecture](0005-gsw-vga-v2-and-guarded-3d-transport.md)
