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

## Consequences

- Existing v1 guests remain compatible while v2 DirectDraw work can proceed.
- The SVGA9 grammar can reuse Mesa9x knowledge without committing the device to
  VMware hardware compatibility.
- A later native GSW packet generation can coexist with the frozen, tested
  SVGA9 subset.
- Safe resource upload, a Vulkan-backed SDL GPU renderer, shader translation,
  and guest drivers remain separate proof-gated deliveries.

## References

- [GSW VGA transport](../../src/vga/gsw.odin)
- [GSW 2D commands](../../src/vga/gsw2d.odin)
- [Guarded GSW3D queue](../../src/vga/gsw3d.odin)
- [Windows 98 driver source lock](0004-windows-98-driver-source-and-delivery-lock.md)
