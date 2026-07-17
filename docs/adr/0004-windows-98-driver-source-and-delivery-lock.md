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
fetch, or resolve a branch or tag.

`drivers/win98/build-plan.json` remains `blocked` until a reviewed plan names
hash-verified local toolchain executables, literal argument arrays, source
working directories, and exact output sizes and SHA-256 values. The build
script invokes executables directly rather than evaluating shell command
strings. It performs no network operation.

`drivers/win98/payload-inventory.schema.tsv` and
`drivers/win98/payload-manifest.schema.tsv` contain only staging schemas. There
are no inventory or payload rows. A future reviewed inventory must enumerate
the exact destination names and kinds for all four packages, including the PnP
INF and binary structure. The staging script requires a one-for-one manifest
match, bounds row and byte counts, rejects Windows 9x short-name collisions,
validates each source and staged copy, and atomically creates a previously
absent output directory. The tracked source and build metadata are not binaries
and are not install-ready packages.

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
- A missing checkout, dirty tree, wrong origin, toolchain hash mismatch,
  incomplete payload set, or output hash mismatch stops the workflow.
- Adding the first payload requires a reviewed build plan, a populated payload
  manifest, license notices, INF/content validation, and Setup integration.
- The plan preserves a lean RETVRN99-specific architecture while keeping useful
  Windows 9x compatibility knowledge traceable.

## References

- [Windows 98 setup driver bundles](0003-windows-98-setup-driver-bundles.md)
- [Pinned upstream source lock](../../drivers/win98/upstream.lock.tsv)
