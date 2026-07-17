<!-- SPDX-License-Identifier: GPL-3.0-only -->

# ADR 0007: GSW3D Windows 98 guest smoke contract

## Status

Accepted

## Context

The GSW mini-VDD now exposes a guarded guest transport, but host-only tests do
not prove that a Windows 98 process can open the VxD, marshal its DIOC buffers,
submit the exact proof frame, and observe asynchronous fence completion. The
production renderer and Mesa ICD remain later gates.

## Decision

Build `gsw3d-smoke.exe` as a separate developer artifact with the pinned
MinGW32 compiler. It has a custom entry point, imports only `KERNEL32.dll`,
targets PE32 and Windows subsystem version 4.0, and links no CRT. Its source and
shared ABI are overlaid into an independent derived-source plan, so neither the
main VGA build plan nor its five-file install package depends on the tool.

The executable queries ABI version and capabilities, creates context 1, emits
the hash-locked proof profile as explicit little-endian words, defines surface
1 and vertex buffer 2, uploads the 60 vertex bytes, submits the 360-byte render
batch, and presents a 640x480 interval-one frame. Every nonzero fence is polled
with a ten-second bound. After a two-second visual hold it destroys both
resources and the context, then writes `GSW3D_SMOKE PASS` to standard output
and `GSW3D.LOG`.

Normal hosts report `GSW3D_SMOKE UNAVAILABLE` because production does not
advertise the guarded proof backend. A PASS proves the guest/VxD/host command
and fence path, not pixel correctness. Pixel acceptance still requires the
host proof readback or a reviewed screenshot from a licensed Windows 98 guest.

## Consequences

- The exact proof profile can be driven from a real Windows 98 process.
- Failed, unavailable, and passing runs leave deterministic text markers.
- Successful runs tear down their fixed IDs, allowing the smoke test to repeat
  without a guest restart.
- The executable is staged by acceptance tooling, never by the PnP display INF.
- Mesa generation, ICD registration, and a general production renderer remain
  separate gates.

## References

- [Guest smoke source](../../drivers/win98/guest-tools/gsw3d-smoke/main.c)
- [Guest transport ABI](../../drivers/win98/derived/shared/gsw3d_abi.h)
- [Guarded guest transport](0006-gsw3d-windows-98-guest-transport.md)
- [Exact host proof profile](../../src/vga/gsw3d_svga9_profile.odin)
