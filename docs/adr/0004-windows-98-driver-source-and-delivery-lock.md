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

The repository does not yet contain a reviewed GSW display or sound INF, a
Windows 98 driver binary, a DirectX 9 redistributable, or a compatibility-layer
payload. Source selection and delivery ordering must therefore be representable
without making an install-ready claim.

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

The pinned vmdisp9x source builds with that extraction and its bundled
DDK-derived headers and `dibeng.lbc`; no separate Windows 98 DDK is required.
Two clean builds proved every VxD byte-stable. Open Watcom places the current
Unix time in each Win16 driver's `VS_FIXEDFILEINFO.dwFileDateLS`, so the bounded
NE-resource normalizer zeros only `dwFileDateMS` and `dwFileDateLS`. The four
corresponding normalized DRVs were byte-identical across both builds.

`drivers/win98/build-plan.json` nevertheless remains `blocked` until a reviewed
plan names hash-verified local toolchain executables, literal argument arrays,
canonical planned source working directories, the GSW-derived source recipe,
the explicit Win16 normalization operation, and exact adapted output sizes and
SHA-256 values. The build script invokes executables directly rather than
evaluating shell command strings. It performs no network operation and cannot
consume a `reference-only` source row.

`drivers/win98/payload-inventory.schema.tsv` and
`drivers/win98/payload-manifest.schema.tsv` contain only staging schemas. There
are no inventory or payload rows. A future reviewed inventory must enumerate
the exact destination names and kinds for each package that is available,
including the PnP INF and binary structure where applicable. The four reserved
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

VMDisp9x, VMHAL9x, Mesa9x, and Wine9x are planned inputs subject to later
license and adaptation review. SoftGPU, `libs/vkd3d-shader`, and the VMware
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
- Adding the first payload requires a reviewed build plan, a populated payload
  manifest, license notices, INF/content validation, and Setup integration.
- The plan preserves a lean RETVRN99-specific architecture while keeping useful
  Windows 9x compatibility knowledge traceable.

## References

- [Windows 98 setup driver bundles](0003-windows-98-setup-driver-bundles.md)
- [Pinned upstream source lock](../../drivers/win98/upstream.lock.tsv)
