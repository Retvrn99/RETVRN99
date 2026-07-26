<!-- SPDX-License-Identifier: GPL-3.0-only -->

# ADR 0011: DISPI feature levels gate capability, not video memory

## Status

Accepted

## Context

Bochs ties each DISPI identifier to a video memory size. `B0C4` is documented as
"VBE video memory increased to 8 MB" and `B0C5` as "increased to 16 MB. Video
memory size stored in new register `VBE_DISPI_INDEX_VIDEO_MEMORY_64K`", whose
worked example is 256, meaning 16 MiB.

RETVRN99 advertises more video memory than either level describes, and the
guest can select any identifier from `B0C0` to `B0C5` at runtime. Three
questions followed from that. Whether the selected identifier should cap the
memory the device exposes. What index `0Ah` should report when the guest has
selected a level below `B0C5`, where the register did not historically exist.
And what the persona's video memory size should actually be.

The previous behaviour gated index `0Ah` on `B0C5` and returned `0xFFFF` below
it. A guest that read the register without first checking the identifier would
compute `0xFFFF` multiplied by 64 KiB, roughly 4 GiB of video memory. The
pinned VGABIOS reads index `0Ah` through `dispi_get_memory_64k` without
checking the identifier, so this register is load bearing rather than
decorative: it is the source of the total memory that INT 10h 4F00h reports.

The earlier 32 MiB figure came from naming the persona after an Nvidia TNT2
Ultra 32, a card chosen by release date rather than by capability. The intended
target is closer to a DirectX 9.0c class adapter, for which 32 MiB is
unrepresentative.

## Decision

DISPI identifiers gate capability, never capacity. Selecting a lower level
withdraws features such as the linear framebuffer, the 8-bit DAC, and 32 KiB
bank granularity, but never reduces the video memory the device exposes or the
range a guest may address.

Index `0Ah` is readable at every identifier and always reports the true size.
This exposes the register one level earlier than Bochs did. The deviation is
additive, it cannot mislead a guest, and it removes the only path by which a
guest could read an implausible size from open bus. Index `0Bh` DDC remains
gated at `B0C5`, because DDC is a capability rather than a description of
capacity.

The Bochs per-identifier memory ceilings of 8 MiB at `B0C4` and 16 MiB at
`B0C5` are deliberately not implemented. RETVRN99 exposes its full persona
aperture at every level.

Guest video memory is 64 MiB. The persona no longer names a specific graphics
card, because the model number carried a memory figure that contradicted the
persona and implied a generation the project does not claim.

## Consequences

The framebuffer BAR advertises 64 MiB and the PCI capability reports 64, which
the Windows 98 GSW-VGA driver reads at initialisation to size its aperture. No
driver change is required, because the driver already discovers video memory
from PCI configuration rather than assuming a size.

`VBE_DISPI_INDEX_VIRT_HEIGHT` is a 16-bit register, so at 64 MiB any pitch of
1024 bytes or less yields more addressable scan lines than the register can
express and the reported value saturates at 65535. Saturation under-reports and
is therefore safe. Bochs has the same ceiling; it is a property of the protocol
rather than of this implementation.

The conformance matrix records the identifier ladder and the memory size
register as contracts RETVRN99 implements, and records the per-identifier
memory ceilings as a deliberate exclusion.

ADR 0001 continues to govern the separation of guest persona from execution
policy. Only its illustrative video memory figure changes.
