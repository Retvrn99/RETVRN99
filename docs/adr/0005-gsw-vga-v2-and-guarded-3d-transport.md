<!-- SPDX-License-Identifier: GPL-3.0-only -->

# ADR 0005: GSW VGA v2 and guarded 3D transport

## Status

Accepted

## Context

GSW VGA v1 provides a small guest-memory ring and shared framebuffer, but
high-resolution Windows 98 games also need accelerated surface operations and a
path from a guest Mesa driver to host GPU resources. Implementing VMware's PCI,
FIFO, GMR, 2D, and vGPU10 contracts would add compatibility machinery RETVRN99
does not need. Accepting an unrestricted SVGA command stream would also expose
host parsers and allocations before the renderer can validate them.

## Decision

GSW VGA ABI v2 retains every v1 command and adds surface-offset presentation,
bounded stretch/color-key/ROP3 blits, and a separate GSW3D register and command
queue. Guest descriptors refer only to registered guest-physical regions and
numeric context or surface IDs. The transport copies command bytes before an
asynchronous worker can inspect them, bounds owned and queued memory, validates
all arithmetic and identifiers, and serializes reset and resource-lifetime
barriers with submitted work.

`GSW3D_PACKET_SVGA9` is the first packet grammar. It is a deliberately narrow
whitelist for the legacy surface, state, shader, draw, clear, copy, and transfer
commands needed by the future Mesa9x winsys. VMware PCI registers, FIFO/GMR
machinery, its 2D protocol, vGPU10, queries, readback, and unpinned DMA commands
are not implemented. A renderer must provide both transport-independent packet
validation and execution callbacks before the device advertises SVGA9 or direct
presentation.

The initial backend contract completes each work item synchronously on the
render worker, so the asynchronous-fence capability remains unadvertised.
Direct present is capped at two queued frames and carries only a surface ID,
source and destination rectangles, and interval. No 3D capability is visible in
production until a real host renderer is attached and passes the capability and
rendering tests.

Resource upload is a separate GSW descriptor rather than VMware guest-memory
DMA. It names an already-defined resource and a registered guest region, copies
the bounded source bytes at doorbell time, and carries only byte offsets to the
backend. Its capability is visible only when the backend supplies both the
upload callback and a pure format-size callback; the transport uses that sizing
contract to reject destination ranges outside the declared resource before any
host write. Direct-present intervals remain part of the v1 command and are
filtered through a backend-advertised interval mask. The SDL GPU host seam keeps
persistent color surfaces in a 256 MiB bounded table, atomically replaces reused
surface IDs, and wraps them for the existing 2D compositor, so direct
presentation does not require a framebuffer readback. Atomic replacement counts
both the old and new texture against the budget until the swap succeeds.

## Consequences

- Existing v1 guests remain compatible while v2 DirectDraw work can proceed.
- The SVGA9 grammar can reuse Mesa9x knowledge without committing the device to
  VMware hardware compatibility.
- A later native GSW packet generation can coexist with the frozen, tested
  SVGA9 subset.
- The bounded upload transport and no-readback SDL GPU surface/presentation
  seam are available without enabling production 3D capabilities.
- SDL surface lifecycle and presentation calls remain main-thread-only. A host
  backend must synchronously marshal GSW worker requests to the UI thread before
  any production 3D capability can be attached.
- SVGA9 rendering, shader translation, and guest drivers remain separate
  proof-gated deliveries.

## References

- [GSW VGA transport](../../src/vga/gsw.odin)
- [GSW 2D commands](../../src/vga/gsw2d.odin)
- [Guarded GSW3D queue](../../src/vga/gsw3d.odin)
- [Host-resident SDL GPU surfaces](../../src/host/gpu_surface.odin)
- [Windows 98 driver source lock](0004-windows-98-driver-source-and-delivery-lock.md)
