<!-- SPDX-License-Identifier: GPL-3.0-only -->

# ADR 0004: Windows 98 driver source and delivery lock

## Status

Accepted

## Context

RETVRN99 targets high-resolution, high-frame-rate Windows 98 games without the
compatibility constraints of a general VMware product. Its guest display path
can still learn from the mature VMDisp9x, VMHAL9x, Mesa9x, SoftGPU, Wine9x,
vkd3d-shader, and VMware SVGA sources. Those projects use different licenses,
build systems, and old Windows driver toolchains. A moving branch, an
unreviewed compiler, or an unverified binary copied into Setup would make the
guest boundary neither reproducible nor auditable.

The repository contains reviewed GSW display, mini-VDD, DirectDraw HAL, bridge,
and INF adaptation sources. Compiled payloads remain external to Git. Source
selection, deterministic compilation, staging, and actual guest acceptance are
separate claims and must remain independently provable.

## Decision

`drivers/win98/upstream.lock.tsv` is the authoritative source-provenance lock.
Every entry names an HTTPS repository, a complete immutable Git commit, its
upstream license, and whether it is planned input or reference-only material.
The verifier accepts only clean local checkouts at those exact origins and
commits, including initialized and matching submodules. It does not clone,
fetch, or resolve a branch or tag. With no source selection it verifies the
whole lock. Build and staging workflows instead pass an exact, closed source
allowlist derived from the work they will perform, so an unavailable unrelated
planned or reference-only checkout cannot block a narrower package build.

`drivers/win98/toolchain.lock.json` pins the Open Watcom C/C++ 1.9 archive by
size, SHA-256, and MD5, then pins the complete extracted tree by a canonical
path, size, and per-file-hash digest. It also fixes the relative `WATCOM`,
`EDPATH`, `INCLUDE`, and `PATH` layout. The verifier rejects added, removed, or
modified extraction files and performs no install or network operation. The
archive and extraction remain external to the repository.

`drivers/win98/mingw32-toolchain.lock.json` applies the same full-tree lock to
the MinGW32 GCC 15.2.0 extraction used by VMHAL9x. Build-plan schema 3 binds
each tool executable and environment to its named lock rather than sharing a
global compiler environment.

The pinned vmdisp9x source builds with that extraction and its bundled
DDK-derived headers and `dibeng.lbc`; no separate Windows 98 DDK is required.
Two clean builds proved every VxD byte-stable. Open Watcom places the current
Unix time in each Win16 driver's `VS_FIXEDFILEINFO.dwFileDateLS`, so the bounded
NE-resource normalizer zeros only `dwFileDateMS` and `dwFileDateLS`. The four
corresponding normalized DRVs were byte-identical across both builds.

`drivers/win98/derived-source-plan.json` separates immutable upstream source
from RETVRN99 adaptations. A schema-2 ready recipe identifies one canonical
planned upstream, a disjoint output directory, ordered patches pinned by size
and SHA-256, complete overlay directories pinned by the canonical tree
descriptor, and the exact descriptor of the combined result. Preparation
materializes exact Git blob bytes, recursively expands only initialized
superproject-pinned gitlinks, and verifies provenance before and after. Each
patch explicitly names the regular text paths whose canonical CRLF bytes must
be converted to LF; undeclared blobs are unchanged, and unsafe, missing,
duplicate, reparse-point, NUL-containing, or isolated-CR inputs are rejected.
The preparer prevents unapproved overlay replacement, rejects overlapping
recipe destinations, scans each result again before publication, and
atomically creates a previously absent output root.

The plan may instead be `draft` solely to bootstrap the combined descriptor.
Draft recipes already require exact patch and overlay descriptors, but omit the
not-yet-known output descriptor. `-DescribeRecipe` builds the tree in bounded
private scratch, scans it twice, emits the candidate descriptor, and deletes
the tree. Draft mode cannot publish an output or be consumed by the builder.
`-DescribeTree` similarly emits a double-scanned descriptor for an existing
overlay without changing it.

`drivers/win98/build-plan.json` is `ready` for the paired VMDisp9x-derived
display driver and VMHAL9x-derived GSW DirectDraw HAL. The schema-3 plan pins
the ready derived-source plan, both toolchain locks, and upstream lock. The builder
snapshots those exact linked bytes before use and rejects an alternate
upstream-lock path. It names a hash-verified local toolchain executable, a
literal argument array, a derived-recipe working directory, one explicit
Win16 normalization operation, and exact adapted output sizes and SHA-256
values. Every DRV output must be normalized exactly once. A `build`-origin
output must be absent before its producing step, while a `derived`-origin
output must already match and remain unchanged.

The builder re-verifies both complete toolchains, prepares private derived
scratch, installs only the selected child environment, and launches pinned
`wmake.exe` or `mingw32-make.exe` with literal arguments. It restores inherited
mixed-case environment variables and never mutates the caller's PATH. It
validates every normalized output before atomic publication, performs no
network operation, and cannot consume a `reference-only` source row. The exact
declared payloads are:

- `gswmini.drv`: 14,732 bytes, `88a53d70230ad74e062dffcb1347619eef02c7bbe5dd07e242aea3ddbb8d75e2`.
- `gswmini.vxd`: 38,669 bytes, `fff33344a8ee01b6ca48546e9433c7bb1aae2247fb8a0d25c99ce8d3017572fe`.
- `gswmini.inf`: 3,188 bytes, `12f28bcb5df117a0e1175edf18aac38c2b05de3216a228e56e0814e9af00523f`.
- `gswhal9x.dll`: 46,592 bytes, `8668d85be8d2fc8b3d32253aa7e04c9104a2713494f9b309c2d4404f1ae12b38`.
- `gswdd32.dll`: 32,256 bytes, `bfb72b4641e8e45e5ec90eb5c30e44aa4fac64fc37164c3429f428717d3964b4`.

This proof covers deterministic derivation and compilation, not Windows 98
installation or device operation.

`drivers/win98/payload-inventory.schema.tsv` and
`drivers/win98/payload-manifest.schema.tsv` contain the reviewed closed
five-file `gsw-vga` destination set and its exact build hashes. The four reserved
package identities are independently stageable; availability of one package
does not imply availability of the other three. With no `-PackageId`, staging
selects every package declared by the reviewed inventory. An explicit
`-PackageId` list selects an exact subset and rejects empty, duplicate, unknown,
or inventory-undeclared IDs.

Every selected PnP package must have exactly one INF, at least one binary, at
most one catalog, and no RunOnce component. Every selected RunOnce package must
have at least one component and no INF or catalog. The payload manifest must
match every reviewed destination for the selected set one-for-one and cannot
add an unselected package. Staging still bounds row and byte counts, rejects
unsafe paths and Windows 9x short-name collisions, validates the exact size and
SHA-256 of each source and staged copy, and atomically creates a previously
absent output directory. The tracked source and build metadata are not binaries
and are not install-ready packages.

Package provenance is a closed mapping to lock `source_directory` values. GSW
VGA requires `vmdisp9x` and `vmhal9x`; GSW sound and the user-supplied DirectX
9 runtime have no upstream checkout requirement; GSW DX9 compatibility
requires `mesa9x` and `wine9x`. Staging resolves those directories to the
authoritative lock names and asks the source verifier to validate only that
deduplicated set. Every required mapping must resolve to exactly one `planned`
row; a `reference-only` row cannot authorize a package. Missing, ambiguous,
dirty, or mismatched required provenance still blocks staging.

The host-side delivery plan reserves these identities:

- GSW VGA is a PnP package for `PCI\VEN_FFFE&DEV_0002`.
- GSW sound is a PnP package for `PCI\VEN_FFFE&DEV_0003`.
- The user-supplied DirectX 9 runtime is a future RunOnce component at order
  100.
- The GSW DirectX compatibility component is a future RunOnce component at
  order 200.

PnP installation occurs during Windows Setup, so the sound and display drivers
precede the post-Setup component sequence. Within that future sequence, the
DirectX runtime precedes the compatibility layer so the runtime cannot replace
the final GSW compatibility files. No RunOnce command is emitted while those
payloads are unavailable.

The pinned VMDisp9x and VMHAL9x revisions have reviewed RETVRN99 adaptations,
bounded build proofs, and a closed stageable PnP package. Mesa9x and Wine9x
remain planned inputs subject to later license and adaptation review. SoftGPU, `libs/vkd3d-shader`, and the VMware
SVGA Device Developer Kit mirror are reference-only at this decision point.
Changing a disposition requires a separate review; a lock update alone does
not approve source copying or binary distribution.

## Consequences

- Source evaluation can proceed against stable revisions without importing
  binaries into the repository.
- The full compiler extraction, not only its launcher executable, is covered by
  a deterministic integrity check.
- A missing required checkout, dirty tree, wrong origin, toolchain hash
  mismatch, incomplete selected package, inventory mismatch, or output hash
  mismatch stops the workflow; an unrelated absent checkout does not block a
  scoped build or staging operation.
- The GSW-VGA payload is stageable only as the complete DRV, VxD, INF, HAL,
  and bridge set; removing or changing any member closes staging.
- Draft descriptors and failed or unstaged builds do not create a package
  claim. A stageable package still does not prove Device Manager, DirectDraw,
  dxdiag, mode switching, or performance inside a licensed Windows 98 guest.
- The plan preserves a lean RETVRN99-specific architecture while keeping useful
  Windows 9x compatibility knowledge traceable.

## References

- [Windows 98 setup driver bundles](0003-windows-98-setup-driver-bundles.md)
- [Pinned upstream source lock](../../drivers/win98/upstream.lock.tsv)
