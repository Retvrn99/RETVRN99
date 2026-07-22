<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Original GSW Mesa support sources

This directory contains RETVRN99-owned source for the private GSW Mesa build.
It is a source-closure Module, not a build or delivery claim.

The Interface was derived only from permissively licensed Mesa 23.1.9
declarations and selected callers at
`29b9adb44bc5ea54dc53c02b5e4b49292c6cc04f`:

- `mesa-23.1.x/src/gallium/frontends/nine/nine_memory_helper.h`
- `mesa-23.1.x/src/gallium/frontends/nine/device9.c`
- `mesa-23.1.x/src/gallium/frontends/nine/surface9.c`
- `mesa-23.1.x/src/gallium/frontends/nine/texture9.c`
- `mesa-23.1.x/src/gallium/frontends/nine/cubetexture9.c`
- `mesa-23.1.x/src/gallium/drivers/svga/svga_screen.c`
- `mesa-23.1.x/src/mesa/main/context.c`
- `mesa-23.1.x/src/mesa/main/version.c`

`interface-inputs.lock.json` binds its schema, those eight ordered immutable
Git blobs, raw byte counts, SHA-256 digests, roles, and MIT license
expressions. It also binds the three build-consumable original files by bytes,
SHA-256, GPL-3.0-only license, and role.

`scripts/verify-win98-mesa-gsw-original-source.ps1` accepts only a clean
checkout at the canonical origin and pinned commit. It reads the eight allowed
Git blobs directly, checks the three local outputs, and repeats checkout,
input, output, and metadata verification at the final stability Seam. It never
reads either excluded implementation blob.

The GPL-2.0-only `win9x/nine/nine_memory_helper.c` and Oracle/VirtualBox
`include/git_sha1.h` implementations are excluded inputs. No text, structure,
or control flow from either implementation is used here.

`include/git_sha1.h` supplies immutable package and source identity macros.
It performs no repository probe and ignores ambient build-time definitions.

`src/nine_memory_helper.c` implements the existing Nine Interface with the
Windows process heap. Owned buffers are 64-byte aligned with at most 63 bytes
of padding, and allocation-size overflow is rejected before the heap call.
Allocations remain resident, so pointer release calls do not map, unmap, cache,
or copy memory. Owned parent allocations retain their storage until every
suballocation is released. The allocator lock makes the worker free path safe
and allocator destruction releases all remaining owned storage and metadata.

The external-pointer Interface supplies no byte extent. This Adapter rejects
negative or wrapping offsets, but the existing Nine caller remains responsible
for ensuring an external allocation is large enough for its calculated
surface layout.

The caller must quiesce its worker before allocator destruction. Pointer and
allocation handles become invalid immediately after their matching free or
allocator destruction.

`compile-plan.json` binds the canonical `guest-cpu-profile.json` Interface, its
policy verifier, the pinned MinGW32 toolchain, all four compile inputs,
forbidden graphics backends, and one normalized temporary i386 COFF descriptor.
The compiler command takes the exact ordered MinGW `cpu_flags` sequence from
that profile between compile-specific prefix and suffix flags. No reduced CPU
flag copy exists in this Module. The compile probe consumes both original
headers and rejects CX16, SSE4, and AVX macros.

The locked 4,066-byte COFF descriptor is the output of that canonical sequence.
It replaces the 4,046-byte exploratory result, which included an extra
`-mtune=generic` outside the guest CPU profile. With the extra tuning override
removed, `-march=i686` supplies the intended i686 tuning as well as the ISA.

`scripts/build-win98-mesa-gsw-original-source.ps1` verifies the clean Mesa
checkout and complete pinned toolchain, creates two private build roots, and
compiles only `src/nine_memory_helper.c`. Each Windows child receives a bounded
10-second timeout, a pinned-toolchain-only `PATH`, and inherited error modes
that suppress crash and missing-file dialogs. The verifier inspects rather than
executes each object, zeros only the COFF timestamp, requires byte-identical
normalized outputs, repeats every bound-file check, and removes both objects.

This narrow proof does not link a DLL or authorize a production build, staging,
guest installation, or capability advertisement. The reviewed source lock and
the separate 869-unit compiler closure now satisfy their build-profile evidence
gates, while the source-closure lock retains its original all-false authorities.
