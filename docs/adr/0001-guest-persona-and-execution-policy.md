# ADR 0001: Separate guest persona from execution policy

## Status

Accepted

## Context

RETVRN99 presents a fixed late-1990s machine identity, but it is an HLE virtual
machine whose primary goal is fast game execution. Several device models had
started using the advertised hardware rates as host-side scheduling limits.
That made each additional timed device increase hypervisor cancellations and
whole-machine work.

## Decision

Guest persona values describe capability and identity only. PC133 memory,
UDMA/66 storage, 52x CD, 10x DVD, a 150 MHz graphics core, AGP 4x, and 32 MiB
of video memory must not cap host memory, storage, optical, or graphics work.

RTC, PIT, retrace, audio, and CDDA remain tied to VM-active host time because
their timing is observable behavior. Pausing freezes machine time without a
catch-up burst; RTC resamples host wall time after resume.

GSW-886 is the only execution mode that deliberately throttles CPU throughput.
Turbo has no periodic governor wake. Device work is host-limited in both modes.

## Consequences

- Advertised rates are centralized in the Guest persona Module.
- Device Interfaces carry operations and completion semantics, not bandwidth.
- Compatibility accuracy is selected automatically from guest behavior rather
  than exposed as per-device speed controls.
- Performance tests gate work amplification separately from guest-visible
  semantic results.
- Production scanout crosses the VM/renderer Seam as raw, generation-tagged
  descriptors so pixel conversion stays in the host presentation Adapter.
- Block DMA, ATAPI, and floppy data movement is transaction-oriented; persona
  rates remain visible metadata and do not create byte or sector pacing events.
